"""
NeXiS Hypervisor — Cluster Management
Proxmox-style multi-node clustering: nodes register, heartbeat, and share state.
"""
import json
import ssl
import secrets
import urllib.request
import urllib.error
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import db

router = APIRouter()


# ── Models ────────────────────────────────────────────────────────────────────

class JoinRequest(BaseModel):
    name: str
    url: str
    role: str = 'worker'   # 'primary' | 'worker'

class HeartbeatRequest(BaseModel):
    node_id: str
    status: dict  # cpu, mem, vms, containers, etc.


# ── Helpers ───────────────────────────────────────────────────────────────────

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _proxy_get(url: str) -> dict:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(url, context=ctx, timeout=6) as resp:
        return json.loads(resp.read())


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get('/nodes')
def list_nodes():
    """List all nodes in the cluster (self + remote)."""
    rows = db.conn().execute(
        'SELECT node_id, name, url, role, joined_at, last_seen FROM cluster_nodes'
    ).fetchall()
    return {'nodes': [dict(r) for r in rows]}


@router.post('/nodes/join')
def join_node(req: JoinRequest):
    """Register a new node in the cluster."""
    node_id = secrets.token_hex(8)
    now = _now()
    try:
        db.conn().execute(
            '''INSERT INTO cluster_nodes (node_id, name, url, role, joined_at, last_seen)
               VALUES (?,?,?,?,?,?)''',
            (node_id, req.name, req.url.rstrip('/'), req.role, now, now),
        )
        db.conn().commit()
    except Exception as exc:
        raise HTTPException(400, str(exc))
    db.log_action('cluster_join', f'{req.name} joined as {req.role}')
    return {'ok': True, 'node_id': node_id}


@router.delete('/nodes/{node_id}')
def remove_node(node_id: str):
    """Remove a node from the cluster."""
    c = db.conn()
    c.execute('DELETE FROM cluster_nodes WHERE node_id=?', (node_id,))
    c.commit()
    return {'ok': True}


@router.post('/nodes/heartbeat')
def heartbeat(req: HeartbeatRequest):
    """Node heartbeat — updates last_seen and live status."""
    db.conn().execute(
        'UPDATE cluster_nodes SET last_seen=? WHERE node_id=?',
        (_now(), req.node_id),
    )
    db.conn().commit()
    return {'ok': True}


@router.get('/nodes/{node_id}/vms')
def node_vms(node_id: str):
    """Proxy: fetch VM list from a remote cluster node."""
    row = db.conn().execute(
        'SELECT url FROM cluster_nodes WHERE node_id=?', (node_id,)
    ).fetchone()
    if not row:
        raise HTTPException(404, 'Node not found.')
    try:
        return _proxy_get(f"{row['url']}/api/vms")
    except Exception as exc:
        raise HTTPException(502, f'Could not reach node: {exc}')


@router.get('/nodes/{node_id}/containers')
def node_containers(node_id: str):
    """Proxy: fetch container list from a remote cluster node."""
    row = db.conn().execute(
        'SELECT url FROM cluster_nodes WHERE node_id=?', (node_id,)
    ).fetchone()
    if not row:
        raise HTTPException(404, 'Node not found.')
    try:
        return _proxy_get(f"{row['url']}/api/containers")
    except Exception as exc:
        raise HTTPException(502, f'Could not reach node: {exc}')


@router.get('/nodes/{node_id}/metrics')
def node_metrics(node_id: str):
    """Proxy: fetch live metrics from a remote cluster node."""
    row = db.conn().execute(
        'SELECT url FROM cluster_nodes WHERE node_id=?', (node_id,)
    ).fetchone()
    if not row:
        raise HTTPException(404, 'Node not found.')
    try:
        return _proxy_get(f"{row['url']}/api/metrics/current")
    except Exception as exc:
        raise HTTPException(502, f'Could not reach node: {exc}')


@router.get('/summary')
def cluster_summary():
    """Aggregated cluster summary: total VMs, CTs, nodes online."""
    nodes = db.conn().execute(
        'SELECT node_id, name, url, role, last_seen FROM cluster_nodes'
    ).fetchall()
    return {
        'node_count': len(nodes),
        'nodes': [dict(n) for n in nodes],
    }
