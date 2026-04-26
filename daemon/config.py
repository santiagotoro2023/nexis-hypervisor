import json
import os
from pathlib import Path

BASE_DIR = Path(__file__).parent
DATA_DIR = Path(os.environ.get('NEXIS_DATA', BASE_DIR))

CONFIG_FILE = DATA_DIR / 'config.json'
DB_FILE = DATA_DIR / 'nexis-hypervisor.db'
CERT_FILE = DATA_DIR / 'cert.pem'
KEY_FILE = DATA_DIR / 'key.pem'
ISO_DIR = Path(os.environ.get('NEXIS_ISO_DIR', '/var/lib/libvirt/images'))
WEB_DIR = BASE_DIR.parent / 'web' / 'dist'

HOST = os.environ.get('NEXIS_HOST', '0.0.0.0')
PORT = int(os.environ.get('NEXIS_PORT', '8443'))

_cfg: dict = {}


def load():
    global _cfg
    if CONFIG_FILE.exists():
        _cfg = json.loads(CONFIG_FILE.read_text())


def save():
    CONFIG_FILE.write_text(json.dumps(_cfg, indent=2))


def get(key: str, default=None):
    return _cfg.get(key, default)


def set_val(key: str, value):
    _cfg[key] = value
    save()
