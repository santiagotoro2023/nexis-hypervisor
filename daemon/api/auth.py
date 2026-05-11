"""
NeXiS Hypervisor — Authentication
All authentication is delegated to the paired NeXiS Controller via SSO.
Local fallback user provides emergency access only.
"""
import hashlib
import json
import secrets
import socket
import ssl
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

import config
import db

router = APIRouter()

_SESSION_TTL_DAYS = 90


# ── Helpers ────────────────────────────────────────────────────────────────────────────────

def _hash(pw: str) -> str:
    return hashlib.sha256(pw.encode()).hexdigest()


def _create_session(username: str) -> str:
    token = secrets.token_hex(32)
    now = datetime.now(timezone.utc)
    expires_at = (now + timedelta(days=_SESSION_TTL_DAYS)).isoformat()
    db.conn().execute(
        'INSERT INTO sessions (token, username, created_at, expires_at) VALUES (?,?,?,?)',
        (token, username, now.isoformat(), expires_at),
    )
    db.conn().commit()
    return token


def _ctrl_login(controller_url: str, username: str, password: str) -> str:
    """Authenticate against the Controller; returns the Controller-issued token."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    payload = json.dumps({'username': username, 'password': password}).encode()
    req = urllib.request.Request(
        f'{controller_url}/api/auth/login',
        data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
            data = json.loads(resp.read())
            token = data.get('token') or data.get('access_token')
            if not token:
                raise HTTPException(401, 'Controller did not return a token.')
            return token
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise HTTPException(401, f'Controller rejected credentials: {body[:120]}')
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(502, f'Cannot reach controller at {controller_url}: {e}')


def _ctrl_register(controller_url: str, ctrl_token: str) -> str | None:
    """
    Register this hypervisor node with the Controller (best-effort).
    Returns the api_token the Controller generated for calling back to us, or None.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    hostname = config.get('hostname', socket.gethostname())
    payload = json.dumps({
        'name': f'NeXiS Hypervisor ({hostname})',
        'url': f'https://{hostname}:{config.PORT}',
        'type': 'hypervisor',
    }).encode()
    for path in ['/api/hyp/nodes/register', '/api/devices/register']:
        req = urllib.request.Request(
            f'{controller_url}{path}',
            data=payload,
            headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {ctrl_token}'},
            method='POST',
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
                data = json.loads(resp.read())
                return data.get('api_token')
        except Exception:
            continue
    return None


def _sso_validate(username: str, password: str) -> str | None:
    """
    Validate credentials against the paired Controller.
    Returns a local session token on success, None if controller is unreachable.
    """
    row = db.conn().execute(
        'SELECT controller_url, sso_enabled FROM nexis_pairing WHERE id=1'
    ).fetchone()
    if not row or not row['sso_enabled']:
        return None
    try:
        _ctrl_login(row['controller_url'], username, password)
        return _create_session(username)
    except HTTPException:
        raise
    except Exception:
        return None


def _local_check(username: str, password: str) -> bool:
    row = db.conn().execute(
        'SELECT hash FROM local_users WHERE username=?', (username,)
    ).fetchone()
    if not row:
        return False
    return secrets.compare_digest(_hash(password), row['hash'])


# ── Models ────────────────────────────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str


class SetupRequest(BaseModel):
    controller_url: str
    username: str
    password: str


# ── Routes ────────────────────────────────────────────────────────────────────────────────

@router.get('/status')
def status():
    setup_done = bool(config.get('setup_complete'))
    paired = bool(db.conn().execute('SELECT 1 FROM nexis_pairing WHERE id=1').fetchone())
    return {'setup_done': setup_done, 'sso_paired': paired}


@router.post('/setup')
def setup(req: SetupRequest):
    """
    Connect this node to a NeXiS Controller.
    Validates credentials against the Controller, stores the pairing, and
    returns a session token. Called once by the setup wizard.
    """
    if config.get('setup_complete'):
        raise HTTPException(400, 'Node already configured.')

    url = req.controller_url.strip().rstrip('/')
    if not url:
        raise HTTPException(400, 'Controller URL is required.')

    # Authenticate against Controller — raises 401/502 on failure
    ctrl_token = _ctrl_login(url, req.username, req.password)

    # Register this node (non-fatal); get the api_token the Controller will use
    controller_api_token = _ctrl_register(url, ctrl_token) or ''

    # Persist pairing
    now = datetime.now(timezone.utc).isoformat()
    db.conn().execute(
        '''INSERT OR REPLACE INTO nexis_pairing
           (id, controller_url, controller_token, controller_api_token, sso_enabled, paired_at)
           VALUES (1, ?, ?, ?, 1, ?)''',
        (url, ctrl_token, controller_api_token, now),
    )
    db.conn().commit()

    config.set_val('setup_complete', True)
    config.set_val('controller_url', url)

    token = _create_session(req.username)
    db.log_action('setup', f'Node connected to {url} by {req.username}')
    return {'token': token, 'username': req.username}


@router.post('/setup/complete')
def setup_complete():
    config.set_val('setup_complete', True)
    return {'ok': True}


@router.post('/login')
def login(req: LoginRequest):
    username = req.username.strip()
    if not username:
        raise HTTPException(400, 'Username required.')

    # 1. Try Controller SSO
    paired = db.conn().execute('SELECT controller_url FROM nexis_pairing WHERE id=1').fetchone()
    if paired:
        try:
            _ctrl_login(paired['controller_url'], username, req.password)
            token = _create_session(username)
            db.log_action('login', f'{username} via Controller SSO')
            return {'token': token, 'username': username}
        except HTTPException as e:
            if e.status_code == 401:
                raise HTTPException(401, 'Invalid username or password.')
            # Controller unreachable — fall through to local

    # 2. Local fallback (emergency access only)
    if _local_check(username, req.password):
        row = db.conn().execute('SELECT role FROM local_users WHERE username=?', (username,)).fetchone()
        token = _create_session(username)
        db.log_action('login', f'{username} via local fallback')
        return {'token': token, 'username': username, 'role': row['role'] if row else 'user'}

    raise HTTPException(401, 'Invalid username or password.')


@router.post('/logout')
def logout(request: Request):
    auth_header = request.headers.get('Authorization', '')
    if auth_header.startswith('Bearer '):
        token = auth_header[7:]
        db.conn().execute('DELETE FROM sessions WHERE token = ?', (token,))
        db.conn().commit()
    return {'ok': True}
