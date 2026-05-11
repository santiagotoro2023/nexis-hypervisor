"""
NeXiS Hypervisor — Cluster Management
Multi-node clustering: nodes register, heartbeat, and aggregate state.
When connected to a NeXiS Controller, peer hypervisors are auto-discovered
from the controller's /api/hyp/nodes registry.
"""
import json
import ssl
import secrets
import urllib.request
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

import db

router = APIRouter()


# ── Models ─────────────────────────────────────────────────────────────────────────

class JoinRequest(BaseModel):
    name: str
    url: str
    role: str = 'worker'
    api_token: str = ''


class HeartbeatRequest(BaseModel):
    node_id: str
    status: dict


class MigrateRequest(BaseModel):
    vm_id: str
    target_uri: str


# ── Helpers ─────────────────────────────────────────────────────────────────────────

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _proxy_get(url: str, token: str = '') -> dict | list:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    headers = {}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
        return json.loads(resp.read())


def _proxy_post(url: str, body: dict, token: str = '') -> dict:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    data = json.dumps(body).encode()
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(url, data=data, headers=headers, method='POST')
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        return json.loads(resp.read())


def _get_node(node_id: str) -> dict:
    row = db.conn().execute(
        'SELECT node_id, name, url, role, api_token, joined_at, last_seen FROM cluster_nodes WHERE node_id=?',
        (node_id,),
    ).fetchone()
    if not row:
        raise HTTPException(404, 'Node not found.')
    return dict(row)


def _get_controller_peers() -> list[dict]:
    """
    Fetch the list of all hypervisor nodes registered with the same
    NeXiS Controller this node is paired to.
    Returns a list of peer dicts with at least {url, name, api_token}.
    Excludes this node itself (matched by our own registered URL).
    """
    import socket
    import config as cfg

    pairing = db.conn().execute(
        'SELECT controller_url, controller_token, controller_api_token FROM nexis_pairing WHERE id=1'
    ).fetchone()
    if not pairing:
        return []

    controller_url = pairing['controller_url']
    ctrl_token = pairing['controller_token']

    # Determine our own URL so we can exclude ourselves from the peer list
    own_hostname = cfg.get('hostname', socket.gethostname())
    own_url = f'https://{own_hostname}:{cfg.PORT}'

    try:
        nodes_data = _proxy_get(f'{controller_url}/api/hyp/nodes', ctrl_token)
    except Exception:
        return []

    peers = []
    # The controller may return a list directly or a dict with a 'nodes' key
    if isinstance(nodes_data, list):
        node_list = nodes_data
    elif isinstance(nodes_data, dict):
        node_list = nodes_data.get('nodes', nodes_data.get('items', []))
    else:
        return []

    for node in node_list:
        node_url = (node.get('url') or '').rstrip('/')
        if not node_url:
            continue
        # Skip ourselves
        if node_url.rstrip('/') == own_url.rstrip('/'):
            continue
        peers.append({
            'name': node.get('name', node_url),
            'url': node_url,
            'api_token': node.get('api_token', pairing['controller_api_token'] or ''),
            'node_id': node.get('id') or node.get('node_id') or node_url,
        })

    return peers


# ── Node management ─────────────────────────────────────────────────────

@router.get('/nodes')
def list_nodes():
    rows = db.conn().execute(
        'SELECT node_id, name, url, role, joined_at, last_seen FROM cluster_nodes'
    ).fetchall()
    return {'nodes': [dict(r) for r in rows]}


@router.post('/nodes/join')
def join_node(req: JoinRequest):
    node_id = secrets.token_hex(8)
    now = _now()
    try:
        db.conn().execute(
            'INSERT INTO cluster_nodes (node_id, name, url, role, api_token, joined_at, last_seen) VALUES (?,?,?,?,?,?,?)',
            (node_id, req.name, req.url.rstrip('/'), req.role, req.api_token, now, now),
        )
        db.conn().commit()
    except Exception as e:
        raise HTTPException(400, str(e))
    db.log_action('cluster.join', f'{req.name} ({req.role})')
    return {'ok': True, 'node_id': node_id}


@router.delete('/nodes/{node_id}')
def remove_node(node_id: str):
    db.conn().execute('DELETE FROM cluster_nodes WHERE node_id=?', (node_id,))
    db.conn().commit()
    return {'ok': True}


@router.post('/nodes/heartbeat')
def heartbeat(req: HeartbeatRequest):
    db.conn().execute(
        'UPDATE cluster_nodes SET last_seen=? WHERE node_id=?', (_now(), req.node_id)
    )
    db.conn().commit()
    return {'ok': True}


# ── Peers (auto-discovered from Controller) ────────────────────────────────

@router.get('/peers')
def get_peers():
    """
    Return all other hypervisor nodes registered with the same NeXiS Controller.
    This enables automatic cluster formation without manual node registration.
    """
    peers = _get_controller_peers()
    return {'peers': peers, 'count': len(peers)}


# ── Live VM Migration ─────────────────────────────────────────────────────

@router.post('/migrate')
def migrate_vm_endpoint(req: MigrateRequest):
    """
    Live-migrate a VM to another hypervisor.
    Uses virsh migrate with --live --persistent --undefinesource flags.
    The target_uri should be a libvirt connection URI, e.g.:
      qemu+ssh://root@192.168.1.x/system
      qemu+tls://192.168.1.x/system
    """
    from core.libvirt_manager import migrate_vm
    try:
        result = migrate_vm(req.vm_id, req.target_uri)
    except RuntimeError as e:
        raise HTTPException(500, str(e))
    except ValueError as e:
        raise HTTPException(404, str(e))
    db.log_action('cluster.migrate', req.vm_id, source=req.target_uri)
    return result


# ── Cluster-wide aggregate views ─────────────────────────────────────────────

@router.get('/vms')
def cluster_vms():
    """All VMs across every node — local + registered cluster nodes + controller peers."""
    import socket
    local_name = db.conn().execute("SELECT value FROM config WHERE key='hostname'").fetchone()
    local_hostname = local_name['value'] if local_name else socket.gethostname()

    # Local VMs
    result = []
    try:
        from core import libvirt_manager as lv
        for vm in lv.list_vms():
            result.append({**vm, 'node_id': 'local', 'node_name': local_hostname})
    except Exception:
        pass

    # Manually registered cluster nodes
    nodes = db.conn().execute(
        'SELECT node_id, name, url, api_token FROM cluster_nodes'
    ).fetchall()
    for node in nodes:
        try:
            vms = _proxy_get(f"{node['url']}/api/vms", node['api_token'] or '')
            if isinstance(vms, list):
                for vm in vms:
                    result.append({**vm, 'node_id': node['node_id'], 'node_name': node['name']})
        except Exception:
            pass

    # Controller-discovered peer hypervisors (auto-clustering)
    seen_urls = {node['url'].rstrip('/') for node in nodes}
    for peer in _get_controller_peers():
        peer_url = peer['url'].rstrip('/')
        if peer_url in seen_urls:
            continue  # already counted above
        try:
            vms = _proxy_get(f'{peer_url}/api/vms', peer['api_token'] or '')
            if isinstance(vms, list):
                for vm in vms:
                    result.append({**vm, 'node_id': peer['node_id'], 'node_name': peer['name']})
        except Exception:
            pass

    return result


@router.get('/containers')
def cluster_containers():
    """All containers across every node."""
    import socket
    local_name = db.conn().execute("SELECT value FROM config WHERE key='hostname'").fetchone()
    local_hostname = local_name['value'] if local_name else socket.gethostname()

    result = []
    try:
        from core import lxc_manager as lxc
        for ct in lxc.list_containers():
            result.append({**ct, 'node_id': 'local', 'node_name': local_hostname})
    except Exception:
        pass

    nodes = db.conn().execute(
        'SELECT node_id, name, url, api_token FROM cluster_nodes'
    ).fetchall()
    for node in nodes:
        try:
            cts = _proxy_get(f"{node['url']}/api/containers", node['api_token'] or '')
            if isinstance(cts, list):
                for ct in cts:
                    result.append({**ct, 'node_id': node['node_id'], 'node_name': node['name']})
        except Exception:
            pass

    return result


@router.get('/isos')
def cluster_isos():
    """All ISOs across every node."""
    import socket
    local_name = db.conn().execute("SELECT value FROM config WHERE key='hostname'").fetchone()
    local_hostname = local_name['value'] if local_name else socket.gethostname()

    result = []
    try:
        from api.storage import list_isos
        for iso in list_isos():
            result.append({**iso, 'node_id': 'local', 'node_name': local_hostname})
    except Exception:
        pass

    nodes = db.conn().execute(
        'SELECT node_id, name, url, api_token FROM cluster_nodes'
    ).fetchall()
    for node in nodes:
        try:
            isos = _proxy_get(f"{node['url']}/api/storage/isos/list", node['api_token'] or '')
            if isinstance(isos, list):
                for iso in isos:
                    result.append({**iso, 'node_id': node['node_id'], 'node_name': node['name']})
        except Exception:
            pass

    return result


# ── Per-node proxy routes ────────────────────────────────────────────────────────

@router.get('/nodes/{node_id}/vms')
def node_vms(node_id: str):
    node = _get_node(node_id)
    try:
        return _proxy_get(f"{node['url']}/api/vms", node['api_token'])
    except Exception as e:
        raise HTTPException(502, f'Node unreachable: {e}')


@router.get('/nodes/{node_id}/containers')
def node_containers(node_id: str):
    node = _get_node(node_id)
    try:
        return _proxy_get(f"{node['url']}/api/containers", node['api_token'])
    except Exception as e:
        raise HTTPException(502, f'Node unreachable: {e}')


@router.get('/nodes/{node_id}/metrics')
def node_metrics(node_id: str):
    node = _get_node(node_id)
    try:
        return _proxy_get(f"{node['url']}/api/metrics/current", node['api_token'])
    except Exception as e:
        raise HTTPException(502, f'Node unreachable: {e}')


@router.post('/nodes/{node_id}/vms/{vm_id}/{action}')
def node_vm_action(node_id: str, vm_id: str, action: str):
    node = _get_node(node_id)
    try:
        return _proxy_post(f"{node['url']}/api/vms/{vm_id}/{action}", {}, node['api_token'])
    except Exception as e:
        raise HTTPException(502, f'Node unreachable: {e}')


@router.get('/summary')
def cluster_summary():
    nodes = db.conn().execute(
        'SELECT node_id, name, url, role, last_seen FROM cluster_nodes'
    ).fetchall()
    peers = _get_controller_peers()
    return {
        'node_count': len(nodes),
        'peer_count': len(peers),
        'nodes': [dict(n) for n in nodes],
        'peers': peers,
    }
