import os
import shutil
from pathlib import Path

import aiofiles
from fastapi import APIRouter, HTTPException, UploadFile, File

import config

router = APIRouter()

ISO_DIR = Path(os.environ.get('NEXIS_ISO_DIR', '/var/lib/libvirt/images'))


def _pool_info(path: str, name: str) -> dict:
    try:
        usage = shutil.disk_usage(path)
        return {
            'name': name,
            'path': path,
            'capacity_gb': round(usage.total / 1024 ** 3, 1),
            'used_gb': round(usage.used / 1024 ** 3, 1),
            'available_gb': round(usage.free / 1024 ** 3, 1),
            'type': 'local',
            'active': True,
        }
    except Exception:
        return {
            'name': name, 'path': path,
            'capacity_gb': 0, 'used_gb': 0, 'available_gb': 0,
            'type': 'local', 'active': False,
        }


@router.get('/pools')
def list_pools():
    pools = [_pool_info(str(ISO_DIR), 'default')]
    # Add ZFS if available
    zfs_path = '/tank'
    if os.path.exists(zfs_path):
        pools.append(_pool_info(zfs_path, 'zfs-tank'))
    return pools


@router.get('/isos')
def list_isos_for_vm():
    """Compact list for the VM create form."""
    try:
        isos = [f for f in os.listdir(str(ISO_DIR)) if f.endswith('.iso')]
        return {'isos': sorted(isos)}
    except Exception:
        return {'isos': []}


@router.get('/isos/list')
def list_isos():
    """Full list for the storage page."""
    try:
        result = []
        for f in os.listdir(str(ISO_DIR)):
            if not f.endswith('.iso'):
                continue
            path = ISO_DIR / f
            result.append({
                'name': f,
                'size_mb': round(path.stat().st_size / (1024 * 1024), 1),
                'path': str(path),
            })
        return sorted(result, key=lambda x: x['name'])
    except Exception:
        return []


@router.post('/isos/upload')
async def upload_iso(file: UploadFile = File(...)):
    if not file.filename or not file.filename.endswith('.iso'):
        raise HTTPException(400, 'Only .iso files are accepted.')
    dest = ISO_DIR / file.filename
    async with aiofiles.open(str(dest), 'wb') as f:
        while chunk := await file.read(1024 * 1024):
            await f.write(chunk)
    return {'ok': True, 'name': file.filename}


@router.delete('/isos/{name}')
def delete_iso(name: str):
    if '/' in name or '..' in name:
        raise HTTPException(400, 'Invalid filename.')
    path = ISO_DIR / name
    if not path.exists():
        raise HTTPException(404, 'File not found.')
    path.unlink()
    return {'ok': True}
