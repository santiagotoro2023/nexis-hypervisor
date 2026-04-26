import secrets
import hashlib
from datetime import datetime, timezone

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import config
import db

router = APIRouter()


def _hash(pw: str) -> str:
    return hashlib.sha256(pw.encode()).hexdigest()


def _create_token() -> str:
    token = secrets.token_hex(32)
    db.conn().execute(
        'INSERT INTO sessions (token, created_at) VALUES (?, ?)',
        (token, datetime.now(timezone.utc).isoformat()),
    )
    db.conn().commit()
    return token


class LoginRequest(BaseModel):
    password: str


class SetupRequest(BaseModel):
    password: str


@router.get('/status')
def status():
    return {'setup_done': bool(config.get('password_hash'))}


@router.post('/setup')
def setup(req: SetupRequest):
    if config.get('password_hash'):
        raise HTTPException(400, 'System already initialised.')
    if len(req.password) < 8:
        raise HTTPException(400, 'Access code must be at least 8 characters.')
    config.set_val('password_hash', _hash(req.password))
    token = _create_token()
    db.log_action('setup', 'Initial configuration completed')
    return {'token': token}


@router.post('/setup/complete')
def setup_complete():
    config.set_val('setup_complete', True)
    return {'ok': True}


@router.post('/login')
def login(req: LoginRequest):
    stored = config.get('password_hash')
    if not stored or _hash(req.password) != stored:
        raise HTTPException(401, 'Invalid credentials.')
    token = _create_token()
    db.log_action('login')
    return {'token': token}


@router.post('/logout')
def logout():
    return {'ok': True}
