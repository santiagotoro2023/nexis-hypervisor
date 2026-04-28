from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import db
from core import libvirt_manager as lv

router = APIRouter()


from typing import List, Optional


class DiskSpec(BaseModel):
    size_gb: int = 20
    bus: str = 'virtio'       # virtio | sata | ide | scsi
    format: str = 'qcow2'     # qcow2 | raw


class NicSpec(BaseModel):
    network: str = 'default'  # 'default' (NAT) or bridge name
    model: str = 'virtio'     # virtio | e1000 | rtl8139


class CreateVM(BaseModel):
    name: str
    vcpus: int = 2
    sockets: int = 1
    cores: int = 2
    threads: int = 1
    memory_mb: int = 2048
    # Legacy single-disk field kept for compatibility
    disk_gb: int = 20
    disks: List[DiskSpec] = []
    nics: List[NicSpec] = []
    os: str = 'linux'
    os_iso: Optional[str] = None
    network: str = 'default'  # legacy, first NIC network
    machine: str = 'q35'
    cpu_mode: str = 'host-model'
    display: str = 'vnc'       # vnc | spice
    video: str = 'qxl'         # qxl | vga | virtio
    boot_order: List[str] = ['cdrom', 'hd']
    enable_kvm: bool = True
    balloon: bool = True


class HardwareEditRequest(BaseModel):
    vcpus: Optional[int] = None
    memory_mb: Optional[int] = None
    add_disk: Optional[DiskSpec] = None
    add_nic: Optional[NicSpec] = None


class SnapshotRequest(BaseModel):
    name: str


class CloneRequest(BaseModel):
    name: str


class MigrateRequest(BaseModel):
    target_uri: str
    live: bool = True


# ── Static collection routes (must precede /{vm_id}) ─────────────────────────

@router.get('')
def list_vms():
    try:
        return lv.list_vms()
    except Exception as e:
        raise HTTPException(503, str(e))


@router.post('')
def create_vm(req: CreateVM):
    try:
        # Merge legacy disk_gb into disks list
        disks = req.disks if req.disks else [DiskSpec(size_gb=req.disk_gb)]
        nics = req.nics if req.nics else [NicSpec(network=req.network)]
        vm = lv.create_vm(
            name=req.name, vcpus=req.vcpus, sockets=req.sockets,
            cores=req.cores, threads=req.threads, memory_mb=req.memory_mb,
            disks=[d.model_dump() for d in disks],
            nics=[n.model_dump() for n in nics],
            os_iso=req.os_iso, os=req.os, machine=req.machine,
            cpu_mode=req.cpu_mode, display=req.display, video=req.video,
            boot_order=req.boot_order, enable_kvm=req.enable_kvm,
            balloon=req.balloon,
        )
        db.log_action('vm.create', req.name)
        return vm
    except Exception as e:
        raise HTTPException(400, str(e))


@router.get('/templates')
def list_templates():
    try:
        return lv.list_templates()
    except Exception as e:
        raise HTTPException(503, str(e))


@router.get('/backups')
def list_backups():
    try:
        return lv.list_backups()
    except Exception as e:
        raise HTTPException(503, str(e))


# ── Single VM routes ──────────────────────────────────────────────────────────

@router.get('/{vm_id}')
def get_vm(vm_id: str):
    try:
        return lv.get_vm(vm_id)
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(503, str(e))


@router.post('/{vm_id}/start')
def start_vm(vm_id: str):
    try:
        lv.start_vm(vm_id)
        db.log_action('vm.start', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/stop')
def stop_vm(vm_id: str):
    try:
        lv.stop_vm(vm_id)
        db.log_action('vm.stop', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/force-stop')
def force_stop_vm(vm_id: str):
    try:
        lv.force_stop_vm(vm_id)
        db.log_action('vm.force-stop', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/suspend')
def suspend_vm(vm_id: str):
    try:
        lv.suspend_vm(vm_id)
        db.log_action('vm.suspend', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/resume')
def resume_vm(vm_id: str):
    try:
        lv.resume_vm(vm_id)
        db.log_action('vm.resume', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/reset')
def reset_vm(vm_id: str):
    try:
        lv.reset_vm(vm_id)
        db.log_action('vm.reset', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.patch('/{vm_id}/hardware')
def edit_hardware(vm_id: str, req: HardwareEditRequest):
    try:
        result = lv.edit_hardware(vm_id, req.model_dump(exclude_none=True))
        db.log_action('vm.hardware.edit', vm_id)
        return result
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(400, str(e))


@router.get('/{vm_id}/hardware')
def get_hardware(vm_id: str):
    try:
        return lv.get_hardware(vm_id)
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(503, str(e))


@router.post('/{vm_id}/reboot')
def reboot_vm(vm_id: str):
    try:
        lv.reboot_vm(vm_id)
        db.log_action('vm.reboot', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.delete('/{vm_id}')
def delete_vm(vm_id: str):
    try:
        lv.delete_vm(vm_id)
        db.log_action('vm.delete', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/clone')
def clone_vm(vm_id: str, req: CloneRequest):
    try:
        vm = lv.clone_vm(vm_id, req.name)
        db.log_action('vm.clone', f'{vm_id}->{req.name}')
        return vm
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/template')
def mark_template(vm_id: str):
    try:
        lv.get_vm(vm_id)
        lv.set_template_flag(vm_id, True)
        db.log_action('vm.template.set', vm_id)
        return {'ok': True}
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(400, str(e))


@router.delete('/{vm_id}/template')
def unmark_template(vm_id: str):
    try:
        lv.set_template_flag(vm_id, False)
        db.log_action('vm.template.unset', vm_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/backup')
def backup_vm(vm_id: str):
    try:
        result = lv.backup_vm(vm_id)
        db.log_action('vm.backup', vm_id)
        return result
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/migrate')
def migrate_vm(vm_id: str, req: MigrateRequest):
    try:
        lv.migrate_vm(vm_id, req.target_uri, req.live)
        db.log_action('vm.migrate', f'{vm_id}->{req.target_uri}')
        return {'ok': True}
    except ValueError as e:
        raise HTTPException(404, str(e))
    except Exception as e:
        raise HTTPException(400, str(e))


# ── Snapshots ─────────────────────────────────────────────────────────────────

@router.get('/{vm_id}/snapshots')
def list_snapshots(vm_id: str):
    try:
        return lv.list_snapshots(vm_id)
    except Exception as e:
        raise HTTPException(503, str(e))


@router.post('/{vm_id}/snapshots')
def create_snapshot(vm_id: str, req: SnapshotRequest):
    try:
        lv.create_snapshot(vm_id, req.name)
        db.log_action('vm.snapshot', f'{vm_id}:{req.name}')
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{vm_id}/snapshots/{snap_name}/restore')
def restore_snapshot(vm_id: str, snap_name: str):
    try:
        lv.restore_snapshot(vm_id, snap_name)
        db.log_action('vm.snapshot.restore', f'{vm_id}:{snap_name}')
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.delete('/{vm_id}/snapshots/{snap_name}')
def delete_snapshot(vm_id: str, snap_name: str):
    try:
        lv.delete_snapshot(vm_id, snap_name)
        db.log_action('vm.snapshot.delete', f'{vm_id}:{snap_name}')
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))
