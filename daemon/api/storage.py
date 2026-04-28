import asyncio
import json
import os
import secrets
import shutil
import ssl
import threading
import urllib.request
from pathlib import Path

import aiofiles
from fastapi import APIRouter, HTTPException, UploadFile, File
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

import config
import db

router = APIRouter()

ISO_DIR = config.ISO_DIR

# ── ISO Catalog ───────────────────────────────────────────────────────────────

ISO_CATALOG = [
    {'id': 'ubuntu-24.04-server',  'name': 'Ubuntu Server 24.04 LTS', 'version': '24.04',   'category': 'Linux',   'size_gb': 2.7,  'url': 'https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso',                               'filename': 'ubuntu-24.04.2-live-server-amd64.iso'},
    {'id': 'ubuntu-22.04-server',  'name': 'Ubuntu Server 22.04 LTS', 'version': '22.04',   'category': 'Linux',   'size_gb': 1.8,  'url': 'https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso',                               'filename': 'ubuntu-22.04.5-live-server-amd64.iso'},
    {'id': 'debian-12-netinst',    'name': 'Debian 12 (Bookworm)',    'version': '12',       'category': 'Linux',   'size_gb': 0.6,  'url': 'https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.10.0-amd64-netinst.iso',            'filename': 'debian-12.10.0-amd64-netinst.iso'},
    {'id': 'alpine-3.21',          'name': 'Alpine Linux 3.21',       'version': '3.21',     'category': 'Linux',   'size_gb': 0.2,  'url': 'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-standard-3.21.0-x86_64.iso',         'filename': 'alpine-standard-3.21.0-x86_64.iso'},
    {'id': 'fedora-41-server',     'name': 'Fedora Server 41',        'version': '41',       'category': 'Linux',   'size_gb': 2.2,  'url': 'https://download.fedoraproject.org/pub/fedora/linux/releases/41/Server/x86_64/iso/Fedora-Server-netinstall-x86_64-41-1.4.iso', 'filename': 'Fedora-Server-netinstall-x86_64-41-1.4.iso'},
    {'id': 'rocky-9-minimal',      'name': 'Rocky Linux 9 Minimal',   'version': '9.5',      'category': 'Linux',   'size_gb': 1.5,  'url': 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.5-x86_64-minimal.iso',                  'filename': 'Rocky-9.5-x86_64-minimal.iso'},
    {'id': 'arch-latest',          'name': 'Arch Linux',              'version': 'rolling',  'category': 'Linux',   'size_gb': 1.1,  'url': 'https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso',                                      'filename': 'archlinux-x86_64.iso'},
    {'id': 'freebsd-14.2',         'name': 'FreeBSD 14.2',            'version': '14.2',     'category': 'BSD',     'size_gb': 1.1,  'url': 'https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/14.2/FreeBSD-14.2-RELEASE-amd64-disc1.iso', 'filename': 'FreeBSD-14.2-RELEASE-amd64-disc1.iso'},
    {'id': 'opnsense-25',          'name': 'OPNsense 25.1',           'version': '25.1',     'category': 'Network', 'size_gb': 1.0,  'url': 'https://mirror.ams1.nl.leaseweb.net/opnsense/releases/25.1/OPNsense-25.1-dvd-amd64.iso.bz2',            'filename': 'OPNsense-25.1-dvd-amd64.iso.bz2'},
    {'id': 'truenas-scale',        'name': 'TrueNAS SCALE',           'version': '24.10',    'category': 'Storage', 'size_gb': 2.5,  'url': 'https://download.sys.truenas.net/TrueNAS-SCALE-ElectricEel/24.10.2/TrueNAS-SCALE-24.10.2.iso',           'filename': 'TrueNAS-SCALE-24.10.2.iso'},
]


class FetchRequest(BaseModel):
    url: str
    filename: str = ''


class AddPoolRequest(BaseModel):
    name: str
    type: str = 'local'   # 'local' | 'nfs'
    path: str
    server: str = ''       # NFS only: server address
    share: str = ''        # NFS only: exported share path
    options: str = ''      # extra mount options


# ── Storage pools ─────────────────────────────────────────────────────────────

def _pool_disk_info(path: str) -> dict:
    try:
        usage = shutil.disk_usage(path)
        return {
            'capacity_gb': round(usage.total / 1024 ** 3, 1),
            'used_gb': round(usage.used / 1024 ** 3, 1),
            'available_gb': round(usage.free / 1024 ** 3, 1),
            'active': True,
        }
    except Exception:
        return {'capacity_gb': 0, 'used_gb': 0, 'available_gb': 0, 'active': False}


def _builtin_pools() -> list[dict]:
    pools = [{'id': 'default', 'name': 'default', 'type': 'local', 'path': str(ISO_DIR), 'builtin': True, **_pool_disk_info(str(ISO_DIR))}]
    for extra in [('/tank', 'zfs-tank'), ('/data', 'data')]:
        if os.path.exists(extra[0]):
            pools.append({'id': extra[1], 'name': extra[1], 'type': 'local', 'path': extra[0], 'builtin': True, **_pool_disk_info(extra[0])})
    return pools


def _db_pools() -> list[dict]:
    rows = db.conn().execute(
        'SELECT id, name, type, path, options FROM storage_pools'
    ).fetchall()
    result = []
    for r in rows:
        p = dict(r)
        p['builtin'] = False
        p.update(_pool_disk_info(p['path']))
        result.append(p)
    return result


@router.get('/pools')
def list_pools():
    return _builtin_pools() + _db_pools()


@router.post('/pools')
def add_pool(req: AddPoolRequest):
    name = req.name.strip()
    if not name or '/' in name or '..' in name:
        raise HTTPException(400, 'Invalid pool name.')

    if req.type == 'nfs':
        if not req.server or not req.share:
            raise HTTPException(400, 'NFS pools require server and share.')
        mount_point = f'/mnt/nexis-pools/{name}'
        os.makedirs(mount_point, exist_ok=True)
        import subprocess
        opts = req.options or 'defaults'
        result = subprocess.run(
            ['mount', '-t', 'nfs', '-o', opts, f'{req.server}:{req.share}', mount_point],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            os.rmdir(mount_point)
            raise HTTPException(500, f'NFS mount failed: {result.stderr.strip()}')
        path = mount_point
    elif req.type == 'local':
        path = req.path.strip()
        if not path:
            raise HTTPException(400, 'Path is required for local pools.')
        os.makedirs(path, exist_ok=True)
    else:
        raise HTTPException(400, f'Unknown pool type: {req.type}')

    pool_id = secrets.token_hex(6)
    opts_json = json.dumps({'server': req.server, 'share': req.share, 'options': req.options})
    try:
        db.conn().execute(
            'INSERT INTO storage_pools (id, name, type, path, options) VALUES (?,?,?,?,?)',
            (pool_id, name, req.type, path, opts_json),
        )
        db.conn().commit()
    except Exception as e:
        raise HTTPException(400, str(e))

    db.log_action('storage.pool.add', f'{req.type}:{name}')
    return {'ok': True, 'id': pool_id, 'name': name, 'path': path}


@router.delete('/pools/{pool_id}')
def remove_pool(pool_id: str):
    row = db.conn().execute(
        'SELECT name, type, path FROM storage_pools WHERE id=?', (pool_id,)
    ).fetchone()
    if not row:
        raise HTTPException(404, 'Pool not found.')

    if row['type'] == 'nfs':
        import subprocess
        subprocess.run(['umount', row['path']], capture_output=True)
        try:
            os.rmdir(row['path'])
        except Exception:
            pass

    db.conn().execute('DELETE FROM storage_pools WHERE id=?', (pool_id,))
    db.conn().commit()
    db.log_action('storage.pool.remove', row['name'])
    return {'ok': True}


# ── ISO management ────────────────────────────────────────────────────────────

def _downloaded_isos() -> set[str]:
    try:
        return {f for f in os.listdir(str(ISO_DIR)) if f.endswith('.iso')}
    except Exception:
        return set()


@router.get('/catalog')
def list_catalog():
    downloaded = _downloaded_isos()
    result = []
    for item in ISO_CATALOG:
        result.append({**item, 'downloaded': item['filename'] in downloaded})
    return result


@router.get('/isos')
def list_isos_compact():
    try:
        return {'isos': sorted(f for f in os.listdir(str(ISO_DIR)) if f.endswith('.iso'))}
    except Exception:
        return {'isos': []}


@router.get('/isos/list')
def list_isos():
    try:
        result = []
        for f in sorted(os.listdir(str(ISO_DIR))):
            if not f.endswith('.iso'):
                continue
            path = ISO_DIR / f
            result.append({'name': f, 'size_mb': round(path.stat().st_size / (1024 * 1024), 1), 'path': str(path)})
        return result
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
    db.log_action('storage.iso.upload', file.filename)
    return {'ok': True, 'name': file.filename}


@router.post('/isos/fetch')
async def fetch_iso(req: FetchRequest):
    """Stream-download an ISO from a URL; sends SSE progress events."""
    if not req.url.startswith('http'):
        raise HTTPException(400, 'URL must start with http/https.')

    filename = req.filename.strip() or req.url.split('/')[-1].split('?')[0]
    if not filename.endswith('.iso'):
        filename += '.iso'
    dest = ISO_DIR / filename

    async def _stream():
        queue: asyncio.Queue[str | None] = asyncio.Queue()
        loop = asyncio.get_event_loop()

        def _ev(d: dict) -> str:
            return f'data: {json.dumps(d)}\n\n'

        def do_download():
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            try:
                req_obj = urllib.request.Request(
                    req.url,
                    headers={'User-Agent': 'nexis-hypervisor/1.0'},
                )
                with urllib.request.urlopen(req_obj, context=ctx, timeout=30) as resp:
                    total = int(resp.headers.get('Content-Length', 0))
                    downloaded = 0
                    with open(str(dest), 'wb') as f:
                        while True:
                            chunk = resp.read(256 * 1024)
                            if not chunk:
                                break
                            f.write(chunk)
                            downloaded += len(chunk)
                            pct = round(downloaded / total * 100) if total else 0
                            asyncio.run_coroutine_threadsafe(
                                queue.put(_ev({'progress': pct, 'downloaded_mb': round(downloaded / 1024 / 1024, 1), 'total_mb': round(total / 1024 / 1024, 1)})),
                                loop,
                            )
                asyncio.run_coroutine_threadsafe(
                    queue.put(_ev({'done': True, 'name': filename})),
                    loop,
                )
            except Exception as e:
                asyncio.run_coroutine_threadsafe(
                    queue.put(_ev({'error': str(e)})),
                    loop,
                )
            asyncio.run_coroutine_threadsafe(queue.put(None), loop)

        thread = threading.Thread(target=do_download, daemon=True)
        thread.start()

        while True:
            item = await queue.get()
            if item is None:
                break
            yield item

    return StreamingResponse(_stream(), media_type='text/event-stream',
                             headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})


@router.get('/browse')
def browse_storage(path: str = ''):
    """Browse files within any configured storage pool path."""
    all_paths = [str(ISO_DIR)] + [p['path'] for p in _builtin_pools() + _db_pools()]

    if not path:
        path = str(ISO_DIR)

    real = os.path.realpath(path)
    if not any(real.startswith(os.path.realpath(p)) for p in all_paths):
        raise HTTPException(403, 'Path is outside allowed storage pools.')

    if not os.path.isdir(real):
        raise HTTPException(404, 'Directory not found.')

    entries = []
    try:
        for entry in sorted(os.scandir(real), key=lambda e: (not e.is_dir(), e.name.lower())):
            stat = entry.stat(follow_symlinks=False)
            from datetime import datetime, timezone
            entries.append({
                'name': entry.name,
                'type': 'directory' if entry.is_dir() else 'file',
                'size_bytes': stat.st_size,
                'modified': datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(),
            })
    except PermissionError:
        raise HTTPException(403, 'Permission denied.')

    parent = str(Path(real).parent) if real != '/' else None
    if parent and not any(parent.startswith(os.path.realpath(p)) for p in all_paths):
        parent = None

    return {'path': real, 'parent': parent, 'entries': entries}


@router.delete('/isos/{name}')
def delete_iso(name: str):
    if '/' in name or '..' in name:
        raise HTTPException(400, 'Invalid filename.')
    path = ISO_DIR / name
    if not path.exists():
        raise HTTPException(404, 'File not found.')
    path.unlink()
    db.log_action('storage.iso.delete', name)
    return {'ok': True}
