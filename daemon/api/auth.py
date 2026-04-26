"""
NeXiS Hypervisor — Authentication
SSO flow: validate credentials against the paired NeXiS Controller.
Fallback: validate against the local users table when no controller is paired.
"""
import secrets
import hashlib
import ssl
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import config
import db

router = APIRouter()


def _hash(pw: str) -> str:
    return hashlib.sha256(pw.encode()).hexdigest()


def _create_token(username: str) -> str:
    token = secrets.token_hex(32)
    db.conn().execute(
        'INSERT INTO sessions (token, username, created_at) VALUES (?, ?, ?)',
        (token, username, datetime.now(timezone.utc).isoformat()),
    )
    db.conn().commit()
    return token


def _local_check(username: str, password: str) -> bool:
    row = db.conn().execute(
        'SELECT hash FROM local_users WHERE username=?', (username,)
    ).fetchone()
    if not row:
        return False
    return secrets.compare_digest(_hash(password), row['hash'])


def _sso_validate(username: str, password: str) -> dict | None:
    """
    Ask the paired NeXiS Controller to validate credentials.
    Returns {'username', 'role', 'token'} on success, None on failure/unreachable.
    """
    row = db.conn().execute(
        'SELECT controller_url, sso_enabled FROM nexis_pairing WHERE id=1'
    ).fetchone()
    if not row or not row['sso_enabled']:
        return None

    url = row['controller_url'].rstrip('/') + '/api/sso/validate'
    payload = json.dumps({'username': username, 'password': password}).encode()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        req = urllib.request.Request(
            url, data=payload,
            headers={'Content-Type': 'application/json'},
            method='POST',
        )
        with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
            data = json.loads(resp.read())
            if data.get('valid'):
                return data
    except Exception:
        pass
    return None


class LoginRequest(BaseModel):
    username: str
    password: str


class SetupRequest(BaseModel):
    username: str
    password: str
    controller_url: str = ''


@router.get('/status')
def status():
    setup_done = bool(config.get('setup_complete'))
    paired = bool(db.conn().execute(
        'SELECT 1 FROM nexis_pairing WHERE id=1'
    ).fetchone())
    return {'setup_done': setup_done, 'sso_paired': paired}


@router.post('/setup')
def setup(req: SetupRequest):
    """
    Called by the setup wizard to link this node to a NeXiS Controller.
    Validates the credentials against the controller and stores the pairing.
    """
    if config.get('setup_complete'):
        raise HTTPException(400, 'Node already configured.')
    if len(req.password) < 8:
        raise HTTPException(400, 'Password must be at least 8 characters.')

    # If controller URL provided in request, save it before checking
    if req.controller_url:
        config.set_val('pending_controller_url', req.controller_url.rstrip('/'))

    # Try SSO first if a controller URL was stored during wizard step
    controller_url = config.get('pending_controller_url', '')
    if controller_url:
        result = _sso_validate(req.username, req.password)
        if not result:
            raise HTTPException(401, 'Could not authenticate against the NeXiS Controller.')
    else:
        # No controller — set up local user
        if not _local_check(req.username, req.password):
            raise HTTPException(401, 'Invalid credentials.')

    config.set_val('setup_complete', True)
    token = _create_token(req.username)
    db.log_action('setup', f'Node configured by {req.username}')
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

    # 1. Try SSO via paired controller
    sso = _sso_validate(username, req.password)
    if sso:
        token = _create_token(username)
        db.log_action('login', f'{username} via SSO')
        return {'token': token, 'username': username, 'role': sso.get('role', 'user')}

    # 2. Fall back to local user table
    if _local_check(username, req.password):
        row = db.conn().execute(
            'SELECT role FROM local_users WHERE username=?', (username,)
        ).fetchone()
        token = _create_token(username)
        db.log_action('login', f'{username} via local auth')
        return {'token': token, 'username': username, 'role': row['role'] if row else 'user'}

    raise HTTPException(401, 'Invalid username or password.')


@router.post('/logout')
def logout():
    return {'ok': True}
