import asyncio
import json
import shutil
import socket
import subprocess
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

import config

router = APIRouter()

_INSTALL_DIR = Path('/opt/nexis-hypervisor')
_VERSION_FILE = _INSTALL_DIR / 'VERSION'


def _version() -> str:
    try:
        return _VERSION_FILE.read_text().strip().lstrip('v')
    except Exception:
        return '0.0.0'


class HostnameRequest(BaseModel):
    hostname: str


# ── System info ───────────────────────────────────────────────────────────────

@router.get('/info')
def info():
    return {
        'hostname': socket.gethostname(),
        'version': _version(),
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


# ── Update ────────────────────────────────────────────────────────────────────

@router.get('/update/check')
def update_check():
    """Fetch origin and report how many commits HEAD is behind."""
    try:
        subprocess.run(
            ['git', '-C', str(_INSTALL_DIR), 'fetch', 'origin', 'main'],
            capture_output=True, timeout=15,
        )
        behind = int(subprocess.run(
            ['git', '-C', str(_INSTALL_DIR), 'rev-list', 'HEAD..origin/main', '--count'],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip() or '0')
        current = subprocess.run(
            ['git', '-C', str(_INSTALL_DIR), 'rev-parse', '--short', 'HEAD'],
            capture_output=True, text=True,
        ).stdout.strip()
        latest = subprocess.run(
            ['git', '-C', str(_INSTALL_DIR), 'rev-parse', '--short', 'origin/main'],
            capture_output=True, text=True,
        ).stdout.strip()
        return {
            'up_to_date': behind == 0,
            'commits_behind': behind,
            'current_commit': current,
            'latest_commit': latest,
            'version': _version(),
        }
    except Exception as e:
        raise HTTPException(500, str(e))


@router.post('/update')
async def system_update():
    """
    Pull latest code, reinstall Python deps, rebuild the web UI, then restart
    the service. Streams progress as text/event-stream (SSE).

    After the final event the daemon restarts itself — the client should poll
    /api/auth/status until the server is back.
    """
    async def _stream():
        queue: asyncio.Queue[str | None] = asyncio.Queue()

        def ev(step: str, msg: str, ok: bool = True) -> str:
            return f'data: {json.dumps({"step": step, "msg": msg, "ok": ok})}\n\n'

        async def run(step: str, *cmd: str, cwd: str | None = None) -> int:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=cwd,
            )
            assert proc.stdout
            async for raw in proc.stdout:
                line = raw.decode().rstrip()
                if line:
                    await queue.put(ev(step, line))
            return await proc.wait()

        async def pipeline():
            await queue.put(ev('start', 'Update sequence initiated.'))

            # 1. git pull (reset local build artefacts first so they never block)
            await queue.put(ev('git', '→ Pulling latest code from origin/main...'))
            await run('git', 'git', '-C', str(_INSTALL_DIR),
                      'reset', '--hard', 'HEAD')
            rc = await run('git', 'git', '-C', str(_INSTALL_DIR),
                           'pull', '--ff-only', 'origin', 'main')
            if rc != 0:
                await queue.put(ev('git', 'git pull failed — is the branch ahead of origin?', ok=False))
                await queue.put(None)
                return

            # 2. pip install
            pip = str(_INSTALL_DIR / 'venv' / 'bin' / 'pip')
            req = str(_INSTALL_DIR / 'daemon' / 'requirements.txt')
            await queue.put(ev('pip', '→ Updating Python packages...'))
            await run('pip', pip, 'install', '-q', '--upgrade', '-r', req)

            # 3. rebuild web UI (skip if npm not present — pre-built dist stays)
            web_dir = str(_INSTALL_DIR / 'web')
            if shutil.which('npm'):
                await queue.put(ev('npm', '→ Rebuilding web interface...'))
                await run('npm', 'npm', 'ci', '--silent', cwd=web_dir)
                await run('npm', 'npm', 'run', 'build', '--silent', cwd=web_dir)
            else:
                await queue.put(ev('npm', '  npm not found — skipping web rebuild, existing dist retained.'))

            await queue.put(ev('done', '→ Restarting service — reconnect in a few seconds.'))
            asyncio.create_task(_restart_after_delay())
            await queue.put(None)

        task = asyncio.create_task(pipeline())
        while True:
            item = await queue.get()
            if item is None:
                break
            yield item
        await task

    return StreamingResponse(_stream(), media_type='text/event-stream',
                             headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})


async def _restart_after_delay():
    await asyncio.sleep(1.5)
    subprocess.Popen(['systemctl', 'restart', 'nexis-hypervisor-daemon'])
