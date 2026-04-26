import subprocess
import xml.etree.ElementTree as ET

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter()


def _virsh(*args: str) -> str:
    r = subprocess.run(['virsh', *args], capture_output=True, text=True)
    return r.stdout.strip()


def _net_info(name: str) -> dict:
    try:
        xml_str = _virsh('net-dumpxml', name)
        xml = ET.fromstring(xml_str)
        fwd = xml.find('forward')
        ip_el = xml.find('ip')
        bridge_el = xml.find('bridge')

        return {
            'name': name,
            'ip': ip_el.get('address') if ip_el is not None else None,
            'mac': None,
            'interfaces': [],
            'active': 'active' in _virsh('net-info', name),
            'forward_mode': fwd.get('mode', 'isolated') if fwd is not None else 'isolated',
        }
    except Exception:
        return {'name': name, 'ip': None, 'mac': None, 'interfaces': [], 'active': False, 'forward_mode': 'unknown'}


@router.get('/bridges')
def list_bridges():
    output = _virsh('net-list', '--all', '--name')
    names = [n.strip() for n in output.splitlines() if n.strip()]
    return [_net_info(n) for n in names]


class CreateBridge(BaseModel):
    name: str


@router.post('/bridges')
def create_bridge(req: CreateBridge):
    xml = f"""<network>
  <name>{req.name}</name>
  <forward mode='nat'/>
  <bridge name='{req.name}' stp='on' delay='0'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.100.2' end='192.168.100.254'/></dhcp>
  </ip>
</network>"""
    import tempfile, os
    with tempfile.NamedTemporaryFile(suffix='.xml', mode='w', delete=False) as f:
        f.write(xml)
        tmp = f.name
    try:
        subprocess.run(['virsh', 'net-define', tmp], check=True, capture_output=True)
        subprocess.run(['virsh', 'net-start', req.name], check=True, capture_output=True)
        subprocess.run(['virsh', 'net-autostart', req.name], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        raise HTTPException(400, e.stderr.decode() if e.stderr else str(e))
    finally:
        os.unlink(tmp)
    return _net_info(req.name)


@router.delete('/bridges/{name}')
def delete_bridge(name: str):
    if name == 'default':
        raise HTTPException(400, 'The default network cannot be removed.')
    try:
        subprocess.run(['virsh', 'net-destroy', name], capture_output=True)
        subprocess.run(['virsh', 'net-undefine', name], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        raise HTTPException(400, str(e))
    return {'ok': True}
