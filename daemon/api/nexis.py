"""
Nexis Controller integration:
  - Pairing (exchange token with controller)
  - Status feed push (background task)
  - Command relay (natural language → hypervisor action)
"""
import asyncio
import json
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter, HTTPException, BackgroundTasks
from pydantic import BaseModel

import config
import db
from core.metrics_collector import collect as collect_metrics

router = APIRouter()

_feed_task: asyncio.Task | None = None


class PairRequest(BaseModel):
    url: str
    password: str


class CommandRequest(BaseModel):
    command: str


def _get_pairing() -> dict | None:
    row = db.conn().execute('SELECT * FROM nexis_pairing WHERE id = 1').fetchone()
    return dict(row) if row else None


async def _push_status():
    """Background task: push host metrics to nexis-controller every 30s."""
    while True:
        try:
            pairing = _get_pairing()
            if pairing:
                metrics = collect_metrics()
                payload = {
                    'device_id': 'nexis-hypervisor',
                    'type': 'hypervisor',
                    'status': {
                        'cpu_percent': metrics['cpu_percent'],
                        'memory_percent': metrics['memory_percent'],
                        'vm_count': metrics['vm_count'],
                        'vm_running': metrics['vm_running'],
                        'container_count': metrics['container_count'],
                        'container_running': metrics['container_running'],
                        'hostname': metrics['hostname'],
                    },
                }
                async with httpx.AsyncClient(verify=False, timeout=10) as client:
                    await client.post(
                        f"{pairing['controller_url']}/api/devices/status",
                        json=payload,
                        headers={'Authorization': f"Bearer {pairing['controller_token']}"},
                    )
                db.conn().execute(
                    'UPDATE nexis_pairing SET last_sync = ? WHERE id = 1',
                    (datetime.now(timezone.utc).isoformat(),),
                )
                db.conn().commit()
        except Exception:
            pass
        await asyncio.sleep(30)


@router.on_event('startup')  # type: ignore[attr-defined]
async def startup():
    global _feed_task
    if _get_pairing():
        _feed_task = asyncio.create_task(_push_status())


@router.get('/status')
def status():
    pairing = _get_pairing()
    if not pairing:
        return {'paired': False, 'status_feed_active': False}
    return {
        'paired': True,
        'controller_url': pairing['controller_url'],
        'controller_name': pairing.get('controller_name'),
        'last_ping': pairing.get('last_ping'),
        'last_sync': pairing.get('last_sync'),
        'status_feed_active': _feed_task is not None and not _feed_task.done(),
    }


@router.post('/pair')
async def pair(req: PairRequest, background: BackgroundTasks):
    global _feed_task

    # Authenticate with controller
    async with httpx.AsyncClient(verify=False, timeout=10) as client:
        try:
            resp = await client.post(
                f'{req.url.rstrip("/")}/api/auth/login',
                json={'password': req.password},
            )
            resp.raise_for_status()
            token = resp.json()['token']
        except Exception as e:
            raise HTTPException(400, f'Unable to reach controller: {e}')

        # Get controller name
        try:
            info = await client.get(f'{req.url.rstrip("/")}/api/system/info',
                                    headers={'Authorization': f'Bearer {token}'})
            name = info.json().get('hostname', 'nexis-controller')
        except Exception:
            name = 'nexis-controller'

    # Register hypervisor as a device on the controller
    try:
        async with httpx.AsyncClient(verify=False, timeout=10) as client:
            await client.post(
                f'{req.url.rstrip("/")}/api/devices/register',
                json={
                    'device_id': 'nexis-hypervisor',
                    'type': 'hypervisor',
                    'name': f'Nexis Hypervisor ({config.get("hostname", "node")})',
                    'url': f'https://{config.get("hostname", "localhost")}:{config.PORT}',
                },
                headers={'Authorization': f'Bearer {token}'},
            )
    except Exception:
        pass

    now = datetime.now(timezone.utc).isoformat()
    db.conn().execute(
        '''INSERT OR REPLACE INTO nexis_pairing
           (id, controller_url, controller_token, controller_name, paired_at)
           VALUES (1, ?, ?, ?, ?)''',
        (req.url.rstrip('/'), token, name, now),
    )
    db.conn().commit()
    db.log_action('nexis.pair', req.url)

    if _feed_task is None or _feed_task.done():
        _feed_task = asyncio.create_task(_push_status())

    return {'ok': True}


@router.post('/unpair')
def unpair():
    global _feed_task
    if _feed_task:
        _feed_task.cancel()
        _feed_task = None
    db.conn().execute('DELETE FROM nexis_pairing WHERE id = 1')
    db.conn().commit()
    db.log_action('nexis.unpair')
    return {'ok': True}


@router.post('/command')
async def command(req: CommandRequest):
    """
    Interpret a natural language command from the controller and execute it.
    Returns the action taken and a plain-language response.
    """
    cmd = req.command.lower().strip()

    # Simple intent matching — no external dependencies
    from core import libvirt_manager as lv, lxc_manager as lxc

    def _find_vm_by_name(term: str):
        try:
            for vm in lv.list_vms():
                if term in vm['name'].lower():
                    return vm
        except Exception:
            pass
        return None

    def _find_ct_by_name(term: str):
        try:
            for ct in lxc.list_containers():
                if term in ct['name'].lower():
                    return ct
        except Exception:
            pass
        return None

    words = cmd.split()

    if 'list' in words or 'status' in words or 'show' in words:
        try:
            vms = lv.list_vms()
            cts = lxc.list_containers()
            summary = (
                f"{len(vms)} virtual instance(s), {sum(1 for v in vms if v['status']=='running')} active. "
                f"{len(cts)} container(s), {sum(1 for c in cts if c['status']=='running')} active."
            )
            return {'success': True, 'response': summary, 'action_taken': 'STATUS_QUERY'}
        except Exception as e:
            return {'success': False, 'response': str(e)}

    for action_word, fn_map in [
        ({'start', 'activate', 'boot', 'launch'}, 'start'),
        ({'stop', 'shutdown', 'terminate', 'halt'}, 'stop'),
        ({'reboot', 'restart', 'reset'}, 'reboot'),
    ]:
        if any(w in action_word for w in words):
            # Try to identify the target
            remaining = [w for w in words if w not in action_word and len(w) > 2]
            for term in remaining:
                vm = _find_vm_by_name(term)
                if vm:
                    try:
                        if fn_map == 'start':
                            lv.start_vm(vm['id'])
                        elif fn_map == 'stop':
                            lv.stop_vm(vm['id'])
                        elif fn_map == 'reboot':
                            lv.reboot_vm(vm['id'])
                        action = fn_map.upper()
                        db.log_action(f'nexis.cmd.vm.{fn_map}', vm['name'], source='controller')
                        return {
                            'success': True,
                            'response': f"Instance '{vm['name']}' {fn_map} command issued.",
                            'action_taken': f'VM_{action}',
                        }
                    except Exception as e:
                        return {'success': False, 'response': str(e)}
                ct = _find_ct_by_name(term)
                if ct:
                    try:
                        if fn_map == 'start':
                            lxc.start_container(ct['id'])
                        elif fn_map == 'stop':
                            lxc.stop_container(ct['id'])
                        elif fn_map == 'reboot':
                            lxc.restart_container(ct['id'])
                        action = fn_map.upper()
                        db.log_action(f'nexis.cmd.ct.{fn_map}', ct['name'], source='controller')
                        return {
                            'success': True,
                            'response': f"Container '{ct['name']}' {fn_map} command issued.",
                            'action_taken': f'CT_{action}',
                        }
                    except Exception as e:
                        return {'success': False, 'response': str(e)}

    if 'snapshot' in words:
        remaining = [w for w in words if w not in ('snapshot', 'take', 'create', 'of') and len(w) > 2]
        for term in remaining:
            vm = _find_vm_by_name(term)
            if vm:
                snap_name = f'auto-{datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")}'
                try:
                    lv.create_snapshot(vm['id'], snap_name)
                    return {
                        'success': True,
                        'response': f"Snapshot '{snap_name}' created for instance '{vm['name']}'.",
                        'action_taken': 'VM_SNAPSHOT',
                    }
                except Exception as e:
                    return {'success': False, 'response': str(e)}

    return {
        'success': False,
        'response': 'Command not understood. Try: list, start <name>, stop <name>, reboot <name>, snapshot <name>.',
        'action_taken': None,
    }
