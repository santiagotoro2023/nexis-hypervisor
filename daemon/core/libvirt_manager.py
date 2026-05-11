"""
libvirt wrapper for QEMU/KVM virtual machine management.
All domain operations go through this module.
"""
from __future__ import annotations

import os
import re
import subprocess
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Any

try:
    import libvirt
    _LIBVIRT = True
except ImportError:
    _LIBVIRT = False
    libvirt = None  # type: ignore

_CONN: Any = None

# libvirt domain state codes:
#   0 = VIR_DOMAIN_NOSTATE
#   1 = VIR_DOMAIN_RUNNING
#   2 = VIR_DOMAIN_BLOCKED   (on hypervisor resource)
#   3 = VIR_DOMAIN_PAUSED
#   4 = VIR_DOMAIN_SHUTDOWN  (graceful shutdown in progress)
#   5 = VIR_DOMAIN_SHUTOFF   (fully stopped / newly defined)
#   6 = VIR_DOMAIN_CRASHED
#   7 = VIR_DOMAIN_PMSUSPENDED
STATE_MAP = {
    0: 'unknown',
    1: 'running',
    2: 'running',   # blocked — still consuming CPU, treat as running
    3: 'paused',
    4: 'stopped',   # shutdown (graceful shutdown in progress)
    5: 'stopped',   # shutoff  (fully off — this is the normal post-define state)
    6: 'crashed',
    7: 'paused',    # pmsuspended
}


def _conn():
    global _CONN
    if not _LIBVIRT:
        raise RuntimeError('libvirt-python not installed')
    try:
        alive = _CONN is not None and _CONN.isAlive() == 1
    except Exception:
        alive = False
    if not alive:
        _CONN = libvirt.open('qemu:///system')
    return _CONN


def _qcow2_virtual_size(path: str) -> int:
    """Read virtual disk size from the qcow2 header (offset 24, 8 bytes big-endian)."""
    try:
        with open(path, 'rb') as f:
            f.seek(24)
            return int.from_bytes(f.read(8), 'big')
    except Exception:
        return 0


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

    # Virtual disk size from qcow2 header — not compressed on-disk size
    disk_gb = 0
    for disk in xml.findall('.//disk[@type="file"][@device="disk"]'):
        src = disk.find('source')
        if src is not None:
            path = src.get('file', '')
            virtual_bytes = _qcow2_virtual_size(path)
            if virtual_bytes > 0:
                disk_gb = max(disk_gb, virtual_bytes // (1024 ** 3))

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


_BUS_DEV_MAP = {
    'virtio': ('vd', 'virtio'),
    'sata':   ('sd', 'sata'),
    'ide':    ('hd', 'ide'),
    'scsi':   ('sd', 'scsi'),
}


def _disk_xml(idx: int, disk: dict, disk_path: str) -> str:
    bus_key = disk.get('bus', 'virtio')
    dev_prefix, bus_name = _BUS_DEV_MAP.get(bus_key, ('vd', 'virtio'))
    dev = f'{dev_prefix}{chr(97 + idx)}'
    fmt = disk.get('format', 'qcow2')
    return (
        f"    <disk type='file' device='disk'>\n"
        f"      <driver name='qemu' type='{fmt}' cache='none' discard='unmap'/>\n"
        f"      <source file='{disk_path}'/>\n"
        f"      <target dev='{dev}' bus='{bus_name}'/>\n"
        f"    </disk>"
    )


def _nic_xml(idx: int, nic: dict) -> str:
    network = nic.get('network', 'default')
    model = nic.get('model', 'virtio')
    if network == 'default':
        src = "<source network='default'/>"
        typ = 'network'
    else:
        src = f"<source bridge='{network}'/>"
        typ = 'bridge'
    return (
        f"    <interface type='{typ}'>\n"
        f"      <model type='{model}'/>\n"
        f"      {src}\n"
        f"    </interface>"
    )


def create_vm(name: str, vcpus: int = 2, memory_mb: int = 2048,
              disk_gb: int = 20, os_iso: str | None = None, guest_os: str = 'linux',
              network: str = 'default', sockets: int = 1, cores: int = 2,
              threads: int = 1, disks: list | None = None, nics: list | None = None,
              machine: str = 'q35', cpu_mode: str = 'host-model',
              display: str = 'vnc', video: str = 'qxl',
              boot_order: list | None = None, enable_kvm: bool = True,
              balloon: bool = True) -> dict:
    c = _conn()

    if disks is None:
        disks = [{'size_gb': disk_gb, 'bus': 'virtio', 'format': 'qcow2'}]
    if nics is None:
        nics = [{'network': network, 'model': 'virtio'}]
    if boot_order is None:
        boot_order = ['cdrom', 'hd']

    os.makedirs('/var/lib/libvirt/images', exist_ok=True)

    disk_xmls = []
    for idx, disk in enumerate(disks):
        disk_path = f'/var/lib/libvirt/images/{name}-disk{idx}.qcow2'
        size_gb = disk.get('size_gb', 20)
        fmt = disk.get('format', 'qcow2')
        subprocess.run(
            ['qemu-img', 'create', '-f', fmt, disk_path, f'{size_gb}G'],
            check=True, capture_output=True,
        )
        disk_xmls.append(_disk_xml(idx, disk, disk_path))

    iso_block = ''
    if os_iso:
        iso_path = os_iso if os.path.isabs(os_iso) else f'/var/lib/libvirt/images/{os_iso}'
        if os.path.exists(iso_path):
            iso_block = (
                f"    <disk type='file' device='cdrom'>\n"
                f"      <driver name='qemu' type='raw'/>\n"
                f"      <source file='{iso_path}'/>\n"
                f"      <target dev='sdc' bus='sata'/>\n"
                f"      <readonly/>\n"
                f"    </disk>"
            )

    nic_xmls = [_nic_xml(i, n) for i, n in enumerate(nics)]
    boot_xml = ''.join(f"<boot dev='{b}'/>" for b in boot_order)
    domain_type = 'kvm' if enable_kvm else 'qemu'
    total_vcpus = sockets * cores * threads

    display_xml = ''
    if display == 'vnc':
        display_xml = "    <graphics type='vnc' port='-1' listen='127.0.0.1'/>"
    elif display == 'spice':
        display_xml = "    <graphics type='spice' autoport='yes' listen='127.0.0.1'/>"

    video_xml = f"    <video><model type='{video}'/></video>"
    balloon_xml = "    <memballoon model='virtio'/>" if balloon else "    <memballoon model='none'/>"

    xml = f"""<domain type='{domain_type}'>
  <name>{name}</name>
  <memory unit='MiB'>{memory_mb}</memory>
  <currentMemory unit='MiB'>{memory_mb}</currentMemory>
  <vcpu placement='static'>{total_vcpus}</vcpu>
  <os>
    <type arch='x86_64' machine='{machine}'>hvm</type>
    {boot_xml}
  </os>
  <features><acpi/><apic/><vmport state='off'/></features>
  <cpu mode='{cpu_mode}'>
    <topology sockets='{sockets}' cores='{cores}' threads='{threads}'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
{chr(10).join(disk_xmls)}
{iso_block}
{chr(10).join(nic_xmls)}
{display_xml}
{video_xml}
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
{balloon_xml}
  </devices>
</domain>"""

    dom = c.defineXML(xml)
    return _domain_info(dom)


def suspend_vm(vm_id: str):
    _find(vm_id).suspend()


def resume_vm(vm_id: str):
    _find(vm_id).resume()


def reset_vm(vm_id: str):
    _find(vm_id).reset()


def get_hardware(vm_id: str) -> dict:
    dom = _find(vm_id)
    xml = ET.fromstring(dom.XMLDesc())

    vcpus = int(xml.findtext('vcpu') or '1')
    memory_kb = int(xml.findtext('memory') or '0')

    cpu_el = xml.find('cpu/topology')
    topology = {
        'sockets': int(cpu_el.get('sockets', '1')) if cpu_el is not None else 1,
        'cores':   int(cpu_el.get('cores', '1'))   if cpu_el is not None else vcpus,
        'threads': int(cpu_el.get('threads', '1')) if cpu_el is not None else 1,
    }

    disks = []
    for d in xml.findall('.//disk[@type="file"]'):
        src = d.find('source')
        tgt = d.find('target')
        drv = d.find('driver')
        disks.append({
            'device': d.get('device', 'disk'),
            'path':   src.get('file', '') if src is not None else '',
            'dev':    tgt.get('dev', '') if tgt is not None else '',
            'bus':    tgt.get('bus', '') if tgt is not None else '',
            'format': drv.get('type', 'qcow2') if drv is not None else 'qcow2',
        })

    nics = []
    for iface in xml.findall('.//interface'):
        src = iface.find('source')
        model = iface.find('model')
        mac = iface.find('mac')
        nics.append({
            'type':    iface.get('type', ''),
            'network': src.get('network', src.get('bridge', '')) if src is not None else '',
            'model':   model.get('type', '') if model is not None else '',
            'mac':     mac.get('address', '') if mac is not None else '',
        })

    graphics = []
    for g in xml.findall('.//graphics'):
        graphics.append({'type': g.get('type'), 'port': g.get('port'), 'autoport': g.get('autoport')})

    video = []
    for v in xml.findall('.//video/model'):
        video.append({'type': v.get('type', '')})

    return {
        'vcpus': vcpus,
        'memory_mb': memory_kb // 1024,
        'topology': topology,
        'disks': disks,
        'nics': nics,
        'graphics': graphics,
        'video': video,
    }


def edit_hardware(vm_id: str, changes: dict) -> dict:
    dom = _find(vm_id)
    state_code, _ = dom.state()
    live = state_code == 1  # VIR_DOMAIN_RUNNING

    if 'vcpus' in changes:
        vcpus = int(changes['vcpus'])
        flags = getattr(libvirt, 'VIR_DOMAIN_AFFECT_CONFIG', 2)
        if live:
            flags |= getattr(libvirt, 'VIR_DOMAIN_AFFECT_LIVE', 1)
        dom.setVcpusFlags(vcpus, flags)

    if 'memory_mb' in changes:
        mem_kb = int(changes['memory_mb']) * 1024
        flags = getattr(libvirt, 'VIR_DOMAIN_AFFECT_CONFIG', 2)
        if live:
            flags |= getattr(libvirt, 'VIR_DOMAIN_AFFECT_LIVE', 1)
        dom.setMemoryFlags(mem_kb, flags)

    if 'add_disk' in changes:
        disk = changes['add_disk']
        xml = ET.fromstring(dom.XMLDesc())
        existing = xml.findall('.//disk[@type="file"][@device="disk"]')
        idx = len(existing)
        disk_path = f'/var/lib/libvirt/images/{dom.name()}-disk{idx}.qcow2'
        subprocess.run(
            ['qemu-img', 'create', '-f', disk.get('format', 'qcow2'),
             disk_path, f"{disk.get('size_gb', 20)}G"],
            check=True, capture_output=True,
        )
        flags = getattr(libvirt, 'VIR_DOMAIN_AFFECT_CONFIG', 2)
        if live:
            flags |= getattr(libvirt, 'VIR_DOMAIN_AFFECT_LIVE', 1)
        dom.attachDeviceFlags(_disk_xml(idx, disk, disk_path), flags)

    if 'add_nic' in changes:
        nic = changes['add_nic']
        xml = ET.fromstring(dom.XMLDesc())
        idx = len(xml.findall('.//interface'))
        flags = getattr(libvirt, 'VIR_DOMAIN_AFFECT_CONFIG', 2)
        if live:
            flags |= getattr(libvirt, 'VIR_DOMAIN_AFFECT_LIVE', 1)
        dom.attachDeviceFlags(_nic_xml(idx, nic), flags)

    return get_hardware(vm_id)


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
    xml = ET.fromstring(dom.XMLDesc())
    for disk in xml.findall('.//disk[@type="file"][@device="disk"]'):
        src = disk.find('source')
        if src is not None:
            try:
                os.remove(src.get('file', ''))
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
        created = datetime.fromtimestamp(int(created_str), timezone.utc).isoformat()
        result.append({'name': snap.getName(), 'created': created})
    return result


def create_snapshot(vm_id: str, name: str):
    dom = _find(vm_id)
    dom.snapshotCreateXML(f'<domainsnapshot><name>{name}</name></domainsnapshot>')


def restore_snapshot(vm_id: str, snap_name: str):
    dom = _find(vm_id)
    dom.revertToSnapshot(dom.snapshotLookupByName(snap_name))


def delete_snapshot(vm_id: str, snap_name: str):
    dom = _find(vm_id)
    dom.snapshotLookupByName(snap_name).delete()


# ── Clone ────────────────────────────────────────────────────────────────────────────────────

def clone_vm(vm_id: str, new_name: str) -> dict:
    dom = _find(vm_id)
    xml_str = dom.XMLDesc()
    xml = ET.fromstring(xml_str)

    # Collect every data disk: old_path -> new_path
    disk_map: dict[str, str] = {}
    for idx, disk in enumerate(xml.findall('.//disk[@type="file"][@device="disk"]')):
        src = disk.find('source')
        if src is None:
            continue
        old_path = src.get('file', '')
        if not old_path:
            continue
        ext = os.path.splitext(old_path)[1] or '.qcow2'
        disk_map[old_path] = f'/var/lib/libvirt/images/{new_name}-disk{idx}{ext}'

    if not disk_map:
        raise ValueError('Source VM has no disk images')

    for old_path, new_path in disk_map.items():
        subprocess.run(
            ['qemu-img', 'convert', '-f', 'qcow2', '-O', 'qcow2', old_path, new_path],
            check=True, capture_output=True,
        )

    xml_str = re.sub(r'<uuid>[^<]*</uuid>', f'<uuid>{uuid.uuid4()}</uuid>', xml_str)
    xml_str = re.sub(r'<name>[^<]*</name>', f'<name>{new_name}</name>', xml_str, count=1)
    for old_path, new_path in disk_map.items():
        xml_str = xml_str.replace(old_path, new_path)
    xml_str = re.sub(r"port='-?\d+'", "port='-1'", xml_str)
    xml_str = re.sub(r"<mac address='[^']*'/>", '', xml_str)

    return _domain_info(_conn().defineXML(xml_str))


# ── Backup ───────────────────────────────────────────────────────────────────────────────────────

_BACKUP_DIR = '/var/lib/nexis/backups'


def backup_vm(vm_id: str) -> dict:
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

    return {'path': dst, 'size_bytes': os.path.getsize(dst), 'name': os.path.basename(dst)}


def list_backups() -> list[dict]:
    if not os.path.isdir(_BACKUP_DIR):
        return []
    result = []
    for fname in sorted(os.listdir(_BACKUP_DIR)):
        if not fname.endswith('.qcow2'):
            continue
        path = os.path.join(_BACKUP_DIR, fname)
        try:
            size = os.path.getsize(path)
            created = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).isoformat()
        except Exception:
            size, created = 0, ''
        result.append({'name': fname, 'path': path, 'size_bytes': size, 'created': created})
    return result


# ── Migrate ────────────────────────────────────────────────────────────────────────────────────

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


# ── Templates ───────────────────────────────────────────────────────────────────────────────────────

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
