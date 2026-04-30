"""
WebSocket proxies:
  - VMs: WebSocket → TCP → local VNC port (noVNC-compatible)
  - Containers: WebSocket ↔ lxc-attach PTY (xterm.js-compatible)
"""
import asyncio
import os
import pty
import struct
import fcntl
import termios

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from core import libvirt_manager as lv

router = APIRouter()

CHUNK = 4096


@router.websocket('/vms/{vm_id}/console')
async def vm_console(ws: WebSocket, vm_id: str):
    await ws.accept()
    try:
        vm = lv.get_vm(vm_id)
    except Exception:
        await ws.close(code=1011)
        return

    vnc_port = vm.get('vnc_port')
    if not vnc_port:
        await ws.close(code=1011)
        return

    try:
        reader, writer = await asyncio.open_connection('127.0.0.1', vnc_port)
    except Exception:
        await ws.close(code=1011)
        return

    async def tcp_to_ws():
        try:
            while True:
                data = await reader.read(CHUNK)
                if not data:
                    break
                await ws.send_bytes(data)
        except Exception:
            pass

    async def ws_to_tcp():
        try:
            while True:
                data = await ws.receive_bytes()
                writer.write(data)
                await writer.drain()
        except WebSocketDisconnect:
            pass
        except Exception:
            pass

    tcp_task = asyncio.create_task(tcp_to_ws())
    ws_task = asyncio.create_task(ws_to_tcp())
    done, pending = await asyncio.wait(
        [tcp_task, ws_task], return_when=asyncio.FIRST_COMPLETED
    )
    for t in pending:
        t.cancel()
    writer.close()


@router.websocket('/containers/{ct_id}/shell')
async def container_shell(ws: WebSocket, ct_id: str):
    await ws.accept()

    master_fd, slave_fd = pty.openpty()

    shell_cmd = (
        'if [ -x /bin/bash ]; then exec /bin/bash -i -l; '
        'elif [ -x /usr/bin/bash ]; then exec /usr/bin/bash -i -l; '
        'else exec /bin/sh -i; fi'
    )
    env = {
        **os.environ,
        'TERM': 'xterm-256color',
        'HOME': '/root',
        'USER': 'root',
        'LANG': 'en_US.UTF-8',
        'PS1': r'\[\e[38;5;208m\]\u@\h\[\e[0m\]:\[\e[38;5;33m\]\w\[\e[0m\]\$ ',
    }
    proc = await asyncio.create_subprocess_exec(
        'lxc-attach', '-n', ct_id, '--', '/bin/sh', '-c', shell_cmd,
        stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
        close_fds=True,
        env=env,
    )
    os.close(slave_fd)

    loop = asyncio.get_event_loop()

    async def pty_to_ws():
        try:
            while True:
                data = await loop.run_in_executor(None, os.read, master_fd, CHUNK)
                if not data:
                    break
                await ws.send_bytes(data)
        except Exception:
            pass

    async def ws_to_pty():
        import json as _json
        try:
            while True:
                msg = await ws.receive()
                raw = msg.get('bytes')
                txt = msg.get('text')
                if raw is not None:
                    os.write(master_fd, raw)
                elif txt is not None:
                    try:
                        cmd = _json.loads(txt)
                        if cmd.get('type') == 'resize':
                            cols = cmd.get('cols', 80)
                            rows = cmd.get('rows', 24)
                            size = struct.pack('HHHH', rows, cols, 0, 0)
                            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, size)
                    except (_json.JSONDecodeError, KeyError):
                        os.write(master_fd, txt.encode())
        except WebSocketDisconnect:
            pass
        except Exception:
            pass

    t1 = asyncio.create_task(pty_to_ws())
    t2 = asyncio.create_task(ws_to_pty())
    await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for t in [t1, t2]:
        t.cancel()
    try:
        os.close(master_fd)
    except OSError:
        pass
    try:
        proc.terminate()
        await asyncio.wait_for(proc.wait(), timeout=3)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
