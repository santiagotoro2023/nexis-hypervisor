"""
LXC container management via subprocess (lxc-* CLI tools).
"""
from __future__ import annotations
import subprocess
import json
import os


def _run(*args: str, check=True) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), check=check, capture_output=True, text=True)


def _state(name: str) -> str:
    try:
        r = _run('lxc-info', '-n', name, '-s', check=False)
        for line in r.stdout.splitlines():
            if line.startswith('State:'):
                raw = line.split(':', 1)[1].strip().upper()
                return {'RUNNING': 'running', 'STOPPED': 'stopped', 'FROZEN': 'paused'}.get(raw, 'unknown')
    except Exception:
        pass
    return 'unknown'


def _ip(name: str) -> str | None:
    try:
        r = _run('lxc-info', '-n', name, '-i', check=False)
        for line in r.stdout.splitlines():
            if line.startswith('IP:'):
                return line.split(':', 1)[1].strip()
    except Exception:
        pass
    return None


def list_containers() -> list[dict]:
    try:
        r = _run('lxc-ls', '--fancy', '--fancy-format', 'name,state,ipv4,groups', check=False)
        result = []
        lines = r.stdout.strip().splitlines()
        for line in lines[1:]:  # skip header
            parts = line.split()
            if not parts:
                continue
            name = parts[0]
            result.append(_container_info(name))
        return result
    except Exception:
        return []


def _container_info(name: str) -> dict:
    config_path = f'/var/lib/lxc/{name}/config'
    vcpus = 1
    memory_mb = 512
    disk_gb = 8
    template = 'unknown'

    if os.path.exists(config_path):
        with open(config_path) as f:
            for line in f:
                if 'lxc.cgroup.cpuset.cpus' in line:
                    cpus = line.split('=', 1)[1].strip()
                    vcpus = len(cpus.split(','))
                elif 'lxc.cgroup.memory.limit_in_bytes' in line:
                    val = line.split('=', 1)[1].strip()
                    memory_mb = int(val) // (1024 * 1024)
                elif '# Template used to create this container:' in line:
                    template = line.split(':', 1)[1].strip()

    return {
        'id': name,
        'name': name,
        'status': _state(name),
        'vcpus': vcpus,
        'memory_mb': memory_mb,
        'disk_gb': disk_gb,
        'template': template,
        'ip': _ip(name),
    }


def get_container(name: str) -> dict:
    if not os.path.exists(f'/var/lib/lxc/{name}'):
        raise ValueError(f'Container not found: {name}')
    return _container_info(name)


def list_templates() -> list[str]:
    templates = []
    template_dir = '/usr/share/lxc/templates'
    if os.path.exists(template_dir):
        for f in os.listdir(template_dir):
            if f.startswith('lxc-'):
                templates.append(f[4:])
    return sorted(templates) or ['debian', 'ubuntu', 'alpine']


_TEMPLATE_MAP = {
    'debian': ('debian', 'bookworm'),
    'debian-12': ('debian', 'bookworm'),
    'ubuntu': ('ubuntu', 'jammy'),
    'ubuntu-22.04': ('ubuntu', 'jammy'),
    'ubuntu-24.04': ('ubuntu', 'noble'),
    'alpine': ('alpine', '3.20'),
    'alpine-3.20': ('alpine', '3.20'),
}


def create_container(name: str, template: str, vcpus: int,
                     memory_mb: int, disk_gb: int, password: str):
    distro, release = _TEMPLATE_MAP.get(template.lower(), ('debian', 'bookworm'))
    _run('lxc-create', '-n', name, '-t', 'download', '--', '-d', distro, '-r', release, '-a', 'amd64')

    config_path = f'/var/lib/lxc/{name}/config'
    with open(config_path, 'a') as f:
        f.write(f'\nlxc.cgroup.memory.limit_in_bytes = {memory_mb * 1024 * 1024}\n')
        f.write(f'lxc.cgroup.cpuset.cpus = {",".join(str(i) for i in range(vcpus))}\n')

    if password:
        _run('lxc-start', '-n', name)
        _run('lxc-attach', '-n', name, '--', 'sh', '-c', f'echo "root:{password}" | chpasswd', check=False)
        _run('lxc-stop', '-n', name)


def start_container(name: str):
    _run('lxc-start', '-n', name)


def stop_container(name: str):
    _run('lxc-stop', '-n', name)


def restart_container(name: str):
    _run('lxc-stop', '-n', name, check=False)
    _run('lxc-start', '-n', name)


def delete_container(name: str):
    _run('lxc-stop', '-n', name, check=False)
    _run('lxc-destroy', '-n', name)
