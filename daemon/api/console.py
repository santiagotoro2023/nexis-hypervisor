"""
WebSocket proxies:
  - VMs: WebSocket → TCP → local VNC port (noVNC-compatible)
  - Containers: WebSocket ↔ lxc-attach PTY (xterm.js-compatible)
  - Nodes: WebSocket ↔ SSH PTY via asyncssh (xterm.js-compatible)
"""
import asyncio
import os
import pty
import shutil
import struct
import fcntl
import termios
import json
from urllib.parse import urlparse

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
        await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m VM not found\r\n')
        await ws.close(code=1011)
        return

    # VNC port may be -1 right after VM start; retry briefly
    vnc_port = vm.get('vnc_port')
    if not vnc_port:
        for _ in range(10):
            await asyncio.sleep(0.4)
            try:
                vm = lv.get_vm(vm_id)
                vnc_port = vm.get('vnc_port')
                if vnc_port:
                    break
            except Exception:
                pass

    if not vnc_port:
        await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m VNC not available — is the VM running?\r\n')
        await ws.close(code=1011)
        return

    try:
        reader, writer = await asyncio.open_connection('127.0.0.1', vnc_port)
    except Exception as e:
        await ws.send_text(f'\r\n\x1b[1;31m[nexis]\x1b[0m Cannot connect to VNC ({e})\r\n')
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
    try:
        writer.close()
    except Exception:
        pass


@router.websocket('/containers/{ct_id}/shell')
async def container_shell(ws: WebSocket, ct_id: str):
    await ws.accept()

    lxc_attach = shutil.which('lxc-attach') or '/usr/bin/lxc-attach'
    if not os.path.exists(lxc_attach):
        await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m lxc-attach not found — is lxc installed?\r\n')
        await ws.close(code=1011)
        return

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
    try:
        proc = await asyncio.create_subprocess_exec(
            lxc_attach, '-n', ct_id, '--', '/bin/sh', '-c', shell_cmd,
            stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            close_fds=True,
            env=env,
        )
    except Exception as e:
        os.close(slave_fd)
        os.close(master_fd)
        await ws.send_text(f'\r\n\x1b[1;31m[nexis]\x1b[0m Failed to attach: {e}\r\n')
        await ws.close(code=1011)
        return

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
        try:
            while True:
                msg = await ws.receive()
                if 'bytes' in msg:
                    os.write(master_fd, msg['bytes'])
                elif 'text' in msg:
                    try:
                        cmd = json.loads(msg['text'])
                        if cmd.get('type') == 'resize':
                            cols = cmd.get('cols', 80)
                            rows = cmd.get('rows', 24)
                            size = struct.pack('HHHH', rows, cols, 0, 0)
                            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, size)
                    except Exception:
                        os.write(master_fd, msg['text'].encode())
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


@router.websocket('/nodes/{node_id}/shell')
async def node_shell(ws: WebSocket, node_id: str):
    await ws.accept()

    try:
        import db
        row = db.conn().execute(
            'SELECT url FROM cluster_nodes WHERE node_id=?', (node_id,)
        ).fetchone()
        if not row:
            await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m Node not found\r\n')
            await ws.close(code=1011)
            return
        host = urlparse(row['url']).hostname or ''
    except Exception as e:
        await ws.send_text(f'\r\n\x1b[1;31m[nexis]\x1b[0m DB error: {e}\r\n')
        await ws.close(code=1011)
        return

    try:
        raw = await asyncio.wait_for(ws.receive_text(), timeout=20)
        creds = json.loads(raw)
        user = creds.get('user', 'root')
        password = creds.get('password', '')
        port = int(creds.get('port', 22))
        cols = int(creds.get('cols', 220))
        rows_t = int(creds.get('rows', 50))
    except Exception as e:
        await ws.send_text(f'\r\n\x1b[1;31m[nexis]\x1b[0m Bad credentials message: {e}\r\n')
        await ws.close(code=1011)
        return

    try:
        import asyncssh
    except ImportError:
        await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m asyncssh not installed — run pip install asyncssh\r\n')
        await ws.close(code=1011)
        return

    connect_kwargs: dict = {
        'host': host,
        'port': port,
        'username': user,
        'known_hosts': None,
        'connect_timeout': 10,
    }
    if password:
        connect_kwargs['password'] = password
    else:
        connect_kwargs['client_keys'] = ['/root/.ssh/id_rsa', '/root/.ssh/id_ed25519']

    try:
        async with asyncssh.connect(**connect_kwargs) as conn:
            async with conn.create_process(
                term_type='xterm-256color',
                term_size=(cols, rows_t),
            ) as proc:
                await ws.send_text(
                    f'\x1b[1;33m[nexis]\x1b[0m Connected to {user}@{host}:{port}\r\n'
                )

                async def ssh_to_ws():
                    try:
                        async for data in proc.stdout:
                            await ws.send_bytes(data.encode() if isinstance(data, str) else data)
                    except Exception:
                        pass

                async def ws_to_ssh():
                    try:
                        while True:
                            msg = await ws.receive()
                            if 'bytes' in msg:
                                proc.stdin.write(msg['bytes'].decode(errors='replace'))
                            elif 'text' in msg:
                                try:
                                    cmd = json.loads(msg['text'])
                                    if cmd.get('type') == 'resize':
                                        proc.change_terminal_size(
                                            int(cmd.get('cols', 220)),
                                            int(cmd.get('rows', 50)),
                                        )
                                except Exception:
                                    proc.stdin.write(msg['text'])
                    except (WebSocketDisconnect, Exception):
                        pass

                t1 = asyncio.create_task(ssh_to_ws())
                t2 = asyncio.create_task(ws_to_ssh())
                await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
                for t in [t1, t2]:
                    t.cancel()
    except asyncssh.PermissionDenied:
        try:
            await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m Permission denied — wrong credentials\r\n')
            await ws.close()
        except Exception:
            pass
    except asyncssh.ConnectionLost:
        try:
            await ws.send_text('\r\n\x1b[1;31m[nexis]\x1b[0m Connection lost\r\n')
            await ws.close()
        except Exception:
            pass
    except Exception as e:
        try:
            await ws.send_text(f'\r\n\x1b[1;31m[nexis]\x1b[0m SSH error: {e}\r\n')
            await ws.close()
        except Exception:
            pass
