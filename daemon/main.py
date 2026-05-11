"""
NeXiS Hypervisor Daemon
Entry point: TLS setup, auth middleware, route mounting, static file serving.
"""
import os
import ssl
import ipaddress
import secrets
from datetime import datetime, timezone
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

import config
import db
from api import auth, vms, containers, storage, network, metrics, console, nexis, system, cluster
from core.metrics_collector import collect as _collect_metrics

config.load()
db.init()

app = FastAPI(title='NeXiS Hypervisor', version='1.0.0', docs_url='/api/docs', redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=['*'],
    allow_credentials=False,  # Bearer tokens don't use cookies; True + '*' is invalid per CORS spec
    allow_methods=['*'],
    allow_headers=['*'],
)


@app.middleware('http')
async def auth_middleware(request: Request, call_next):
    public_paths = {
        '/api/auth/login', '/api/auth/setup', '/api/auth/status',
        '/api/auth/setup/complete',
    }
    path = request.url.path

    # Allow static assets and public API paths
    if not path.startswith('/api/') or path in public_paths:
        return await call_next(request)

    # WebSocket console: token via query param
    token = None
    if path.startswith('/api/vms/') and path.endswith('/console'):
        token = request.query_params.get('token')
    elif path.startswith('/api/containers/') and path.endswith('/shell'):
        token = request.query_params.get('token')

    if not token:
        auth_header = request.headers.get('Authorization', '')
        if auth_header.startswith('Bearer '):
            token = auth_header[7:]

    if not token or not _valid_token(token):
        return Response('{"detail":"Unauthorized"}', status_code=401, media_type='application/json')

    return await call_next(request)


def _valid_token(token: str) -> bool:
    row = db.conn().execute(
        'SELECT expires_at FROM sessions WHERE token = ?', (token,)
    ).fetchone()
    if not row:
        return False
    expires_at = row['expires_at']
    if expires_at and expires_at < datetime.now(timezone.utc).isoformat():
        db.conn().execute('DELETE FROM sessions WHERE token = ?', (token,))
        db.conn().commit()
        return False
    return True


# Mount API routers
app.include_router(auth.router,       prefix='/api/auth',       tags=['auth'])
app.include_router(vms.router,        prefix='/api/vms',        tags=['vms'])
app.include_router(containers.router, prefix='/api/containers', tags=['containers'])
app.include_router(storage.router,    prefix='/api/storage',    tags=['storage'])
app.include_router(network.router,    prefix='/api/network',    tags=['network'])
app.include_router(metrics.router,    prefix='/api/metrics',    tags=['metrics'])
app.include_router(console.router,    prefix='/api',            tags=['console'])
app.include_router(nexis.router,      prefix='/api/nexis',      tags=['nexis'])
app.include_router(system.router,     prefix='/api/system',     tags=['system'])
app.include_router(cluster.router,    prefix='/api/cluster',    tags=['cluster'])


@app.get('/api/status')
def api_status():
    """Metrics snapshot for the NeXiS Controller — returns host + VM/container stats."""
    m = _collect_metrics()
    return {
        'cpu_percent':    m['cpu_percent'],
        'mem_percent':    m['memory_percent'],
        'disk_percent':   m['disk_percent'],
        'vms_total':      m['vm_count'],
        'vms_running':    m['vm_running'],
        'cts_total':      m['container_count'],
        'cts_running':    m['container_running'],
        'hostname':       m['hostname'],
        'uptime_seconds': m.get('uptime_seconds', 0),
        'mem_used_gb':    m.get('memory_used_gb', 0),
        'mem_total_gb':   m.get('memory_total_gb', 0),
        'disk_used_gb':   m.get('disk_used_gb', 0),
        'disk_total_gb':  m.get('disk_total_gb', 0),
        'net_sent_mbps':  m.get('net_sent_mbps', 0),
        'net_recv_mbps':  m.get('net_recv_mbps', 0),
    }


# Serve built frontend
web_dist = config.WEB_DIR
if web_dist.exists():
    novnc_dir = Path('/usr/share/novnc')
    if novnc_dir.exists():
        app.mount('/novnc', StaticFiles(directory=str(novnc_dir)), name='novnc')
    app.mount('/assets', StaticFiles(directory=str(web_dist / 'assets')), name='assets')

    @app.get('/{full_path:path}')
    async def spa(full_path: str):
        index = web_dist / 'index.html'
        file = web_dist / full_path
        if file.exists() and file.is_file():
            return FileResponse(str(file))
        return FileResponse(str(index))


def _ensure_tls():
    if config.CERT_FILE.exists() and config.KEY_FILE.exists():
        return
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    import datetime

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'nexis-hypervisor')])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.now(datetime.timezone.utc))
        .not_valid_after(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=3650))
        .add_extension(x509.SubjectAlternativeName([
            x509.DNSName('localhost'),
            x509.IPAddress(ipaddress.IPv4Address('127.0.0.1')),
        ]), critical=False)
        .sign(key, hashes.SHA256())
    )
    config.KEY_FILE.write_bytes(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
    config.CERT_FILE.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    print('[nexis] TLS certificate generated.')


if __name__ == '__main__':
    _ensure_tls()
    ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_ctx.load_cert_chain(str(config.CERT_FILE), str(config.KEY_FILE))

    print(f'[nexis] Hypervisor daemon starting on https://{config.HOST}:{config.PORT}')
    uvicorn.run(
        'main:app',
        host=config.HOST,
        port=config.PORT,
        ssl_certfile=str(config.CERT_FILE),
        ssl_keyfile=str(config.KEY_FILE),
        log_level='warning',
    )
