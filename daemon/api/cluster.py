"""
NeXiS Hypervisor — Cluster Management
Multi-node clustering: nodes register, heartbeat, and aggregate state.
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


# ── Models ────────────────────────────────────────────────────────────────────

class JoinRequest(BaseModel):
    name: str
    url: str
    role: str = 'worker'
    api_token: str = ''


class HeartbeatRequest(BaseModel):
    node_id: str
    status: dict


# ── Helpers ───────────────────────────────────────────────────────────────────

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


# ── Node management ───────────────────────────────────────────────────────────

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


# ── Cluster-wide aggregate views ──────────────────────────────────────────────

@router.get('/vms')
def cluster_vms():
    """All VMs across every node — local + remote."""
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

    # Remote nodes
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


# ── Per-node proxy routes ─────────────────────────────────────────────────────

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
    return {'node_count': len(nodes), 'nodes': [dict(n) for n in nodes]}
