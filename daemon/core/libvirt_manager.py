"""
libvirt wrapper for QEMU/KVM virtual machine management.
All domain operations go through this module.
"""
from __future__ import annotations
import xml.etree.ElementTree as ET
from typing import Any

try:
    import libvirt
    _LIBVIRT = True
except ImportError:
    _LIBVIRT = False
    libvirt = None  # type: ignore

_CONN: Any = None

STATE_MAP = {
    0: 'unknown',
    1: 'running',
    2: 'paused',
    3: 'stopped',   # shutting down
    4: 'stopped',   # shut off
    5: 'crashed',
    6: 'paused',    # pmsuspended
}


def _conn():
    global _CONN
    if not _LIBVIRT:
        raise RuntimeError('libvirt-python not installed')
    if _CONN is None or _CONN.isAlive() == 0:
        _CONN = libvirt.open('qemu:///system')
    return _CONN


def list_vms() -> list[dict]:
    c = _conn()
    result = []
    for dom in c.listAllDomains():
        result.append(_domain_info(dom))
    return result


def get_vm(vm_id: str) -> dict:
    dom = _find(vm_id)
    return _domain_info(dom)


def _find(vm_id: str):
    c = _conn()
    try:
        return c.lookupByUUIDString(vm_id)
    except Exception:
        try:
            return c.lookupByName(vm_id)
        except Exception:
            raise ValueError(f'Instance not found: {vm_id}')


def _domain_info(dom) -> dict:
    state_code, _ = dom.state()
    status = STATE_MAP.get(state_code, 'unknown')

    xml = ET.fromstring(dom.XMLDesc())
    vcpus = int(xml.findtext('vcpu') or '1')
    memory_kb = int(xml.findtext('memory') or '0')
    os_type = xml.find('os/type')
    os_str = os_type.get('arch', 'unknown') if os_type is not None else 'unknown'

    disk_gb = 0
    for disk in xml.findall('.//disk[@type="file"][@device="disk"]'):
        src = disk.find('source')
        if src is not None:
            path = src.get('file', '')
            try:
                import os
                disk_gb = max(disk_gb, os.path.getsize(path) // (1024 ** 3))
            except Exception:
                pass

    info = {
        'id': dom.UUIDString(),
        'name': dom.name(),
        'status': status,
        'vcpus': vcpus,
        'memory_mb': memory_kb // 1024,
        'disk_gb': disk_gb,
        'os': os_str,
        'ip': None,
        'vnc_port': None,
        'cpu_percent': None,
        'memory_percent': None,
    }

    # VNC port
    for graphics in xml.findall('.//graphics[@type="vnc"]'):
        port = graphics.get('port')
        if port and port != '-1':
            info['vnc_port'] = int(port)

    # Live CPU stats (only if running)
    if status == 'running':
        try:
            stats = dom.getCPUStats(True)
            if stats:
                info['cpu_percent'] = round(stats[0].get('cpu_time', 0) / 1e9, 1)
        except Exception:
            pass
        try:
            mem_stats = dom.memoryStats()
            total = mem_stats.get('actual', 0)
            avail = mem_stats.get('available', total)
            if total > 0:
                info['memory_percent'] = round((1 - avail / total) * 100, 1)
        except Exception:
            pass

    return info


def create_vm(name: str, vcpus: int, memory_mb: int, disk_gb: int,
              os_iso: str | None, os: str, network: str) -> dict:
    import os as _os
    import subprocess

    c = _conn()
    disk_path = f'/var/lib/libvirt/images/{name}.qcow2'

    # Create disk image
    subprocess.run(
        ['qemu-img', 'create', '-f', 'qcow2', disk_path, f'{disk_gb}G'],
        check=True, capture_output=True,
    )

    iso_block = ''
    if os_iso:
        iso_path = f'/var/lib/libvirt/images/{os_iso}'
        if _os.path.exists(iso_path):
            iso_block = f"""
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='{iso_path}'/>
      <target dev='hda' bus='ide'/>
      <readonly/>
    </disk>"""

    net_block = f"<source network='{network}'/>" if network == 'default' \
        else f"<source bridge='{network}'/>"
    net_type = 'network' if network == 'default' else 'bridge'

    xml = f"""<domain type='kvm'>
  <name>{name}</name>
  <memory unit='MiB'>{memory_mb}</memory>
  <vcpu>{vcpus}</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='cdrom'/><boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <cpu mode='host-model'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{disk_path}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    {iso_block}
    <interface type='{net_type}'>
      <model type='virtio'/>
      {net_block}
    </interface>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <video><model type='vga'/></video>
    <console type='pty'/>
  </devices>
</domain>"""

    dom = c.defineXML(xml)
    return _domain_info(dom)


def start_vm(vm_id: str):
    _find(vm_id).create()


def stop_vm(vm_id: str):
    _find(vm_id).shutdown()


def force_stop_vm(vm_id: str):
    _find(vm_id).destroy()


def reboot_vm(vm_id: str):
    _find(vm_id).reboot()


def delete_vm(vm_id: str):
    dom = _find(vm_id)
    # Remove disk images
    xml = ET.fromstring(dom.XMLDesc())
    for disk in xml.findall('.//disk[@type="file"][@device="disk"]'):
        src = disk.find('source')
        if src is not None:
            path = src.get('file', '')
            try:
                import os
                os.remove(path)
            except Exception:
                pass
    try:
        dom.destroy()
    except Exception:
        pass
    dom.undefineFlags(
        getattr(libvirt, 'VIR_DOMAIN_UNDEFINE_MANAGED_SAVE', 1) |
        getattr(libvirt, 'VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA', 2)
    )


def list_snapshots(vm_id: str) -> list[dict]:
    dom = _find(vm_id)
    result = []
    for snap in dom.listAllSnapshots():
        xml = ET.fromstring(snap.getXMLDesc())
        created_str = xml.findtext('creationTime') or '0'
        from datetime import datetime, timezone
        created = datetime.fromtimestamp(int(created_str), timezone.utc).isoformat()
        result.append({'name': snap.getName(), 'created': created})
    return result


def create_snapshot(vm_id: str, name: str):
    dom = _find(vm_id)
    xml = f"<domainsnapshot><name>{name}</name></domainsnapshot>"
    dom.snapshotCreateXML(xml)


def restore_snapshot(vm_id: str, snap_name: str):
    dom = _find(vm_id)
    snap = dom.snapshotLookupByName(snap_name)
    dom.revertToSnapshot(snap)


def delete_snapshot(vm_id: str, snap_name: str):
    dom = _find(vm_id)
    snap = dom.snapshotLookupByName(snap_name)
    snap.delete()


# ── Clone ─────────────────────────────────────────────────────────────────────

def clone_vm(vm_id: str, new_name: str) -> dict:
    import os, subprocess, uuid, re

    dom = _find(vm_id)
    xml_str = dom.XMLDesc()
    xml = ET.fromstring(xml_str)

    src_disk = None
    for disk in xml.findall('.//disk[@type="file"][@device="disk"]'):
        src = disk.find('source')
        if src is not None:
            src_disk = src.get('file', '')
            break
    if not src_disk:
        raise ValueError('Source VM has no disk image')

    dst_disk = f'/var/lib/libvirt/images/{new_name}.qcow2'
    subprocess.run(
        ['qemu-img', 'convert', '-f', 'qcow2', '-O', 'qcow2', src_disk, dst_disk],
        check=True, capture_output=True,
    )

    new_uuid = str(uuid.uuid4())
    xml_str = re.sub(r'<uuid>[^<]*</uuid>', f'<uuid>{new_uuid}</uuid>', xml_str)
    xml_str = re.sub(r'<name>[^<]*</name>', f'<name>{new_name}</name>', xml_str, count=1)
    xml_str = xml_str.replace(src_disk, dst_disk)
    xml_str = re.sub(r"port='-?\d+'", "port='-1'", xml_str)
    xml_str = re.sub(r"<mac address='[^']*'/>", '', xml_str)

    new_dom = _conn().defineXML(xml_str)
    return _domain_info(new_dom)


# ── Backup ────────────────────────────────────────────────────────────────────

_BACKUP_DIR = '/var/lib/nexis/backups'


def backup_vm(vm_id: str) -> dict:
    import os, subprocess
    from datetime import datetime, timezone

    dom = _find(vm_id)
    xml = ET.fromstring(dom.XMLDesc())

    src_disk = None
    for disk in xml.findall('.//disk[@type="file"][@device="disk"]'):
        src = disk.find('source')
        if src is not None:
            src_disk = src.get('file', '')
            break
    if not src_disk:
        raise ValueError('VM has no disk image')

    os.makedirs(_BACKUP_DIR, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')
    dst = f'{_BACKUP_DIR}/{dom.name()}_{ts}.qcow2'

    subprocess.run(
        ['qemu-img', 'convert', '-c', '-f', 'qcow2', '-O', 'qcow2', src_disk, dst],
        check=True, capture_output=True,
    )
    with open(f'{dst}.xml', 'w') as f:
        f.write(dom.XMLDesc())

    size = os.path.getsize(dst)
    return {'path': dst, 'size_bytes': size, 'name': os.path.basename(dst)}


def list_backups() -> list[dict]:
    import os
    if not os.path.isdir(_BACKUP_DIR):
        return []
    result = []
    for fname in sorted(os.listdir(_BACKUP_DIR)):
        if not fname.endswith('.qcow2'):
            continue
        path = os.path.join(_BACKUP_DIR, fname)
        try:
            size = os.path.getsize(path)
            mtime = os.path.getmtime(path)
            from datetime import datetime, timezone
            created = datetime.fromtimestamp(mtime, timezone.utc).isoformat()
        except Exception:
            size, created = 0, ''
        result.append({'name': fname, 'path': path, 'size_bytes': size, 'created': created})
    return result


# ── Migrate ───────────────────────────────────────────────────────────────────

def migrate_vm(vm_id: str, target_uri: str, live: bool = True) -> None:
    if not _LIBVIRT:
        raise RuntimeError('libvirt-python not installed')

    dom = _find(vm_id)
    flags = 0
    if live:
        flags |= getattr(libvirt, 'VIR_MIGRATE_LIVE', 1)
    flags |= getattr(libvirt, 'VIR_MIGRATE_PERSIST_DEST', 8)
    flags |= getattr(libvirt, 'VIR_MIGRATE_UNDEFINE_SOURCE', 16)

    dest_conn = libvirt.open(target_uri)
    try:
        dom.migrate(dest_conn, flags, None, None, 0)
    finally:
        dest_conn.close()


# ── Templates ─────────────────────────────────────────────────────────────────

def set_template_flag(vm_id: str, is_template: bool) -> None:
    import db
    c = db.conn()
    c.execute(
        'INSERT INTO vm_metadata (vm_id, is_template) VALUES (?, ?)'
        ' ON CONFLICT(vm_id) DO UPDATE SET is_template=excluded.is_template',
        (vm_id, 1 if is_template else 0),
    )
    c.commit()


def list_templates() -> list[dict]:
    import db
    rows = db.conn().execute(
        'SELECT vm_id FROM vm_metadata WHERE is_template=1'
    ).fetchall()
    template_ids = {r['vm_id'] for r in rows}
    result = []
    try:
        for vm in list_vms():
            if vm['id'] in template_ids:
                result.append({**vm, 'is_template': True})
    except Exception:
        pass
    return result
