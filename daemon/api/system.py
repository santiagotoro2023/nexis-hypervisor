import socket
import subprocess

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import config

router = APIRouter()


class HostnameRequest(BaseModel):
    hostname: str


@router.get('/info')
def info():
    return {
        'hostname': socket.gethostname(),
        'version': '1.0.0',
        'build': 'NX-HV',
    }


@router.post('/hostname')
def set_hostname(req: HostnameRequest):
    name = req.hostname.strip()
    if not name or '/' in name or ' ' in name:
        raise HTTPException(400, 'Invalid hostname.')
    try:
        subprocess.run(['hostnamectl', 'set-hostname', name], check=True, capture_output=True)
        config.set_val('hostname', name)
    except Exception as e:
        raise HTTPException(500, str(e))
    return {'ok': True, 'hostname': name}
