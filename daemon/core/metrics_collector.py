"""
Host metrics via psutil. Returns a dict compatible with the frontend HostMetrics type.
"""
from __future__ import annotations
import time
import psutil
import platform
import socket


_prev_net = psutil.net_io_counters()
_prev_time = time.monotonic()


def collect() -> dict:
    global _prev_net, _prev_time

    cpu = psutil.cpu_percent(interval=None)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    now = time.monotonic()
    net = psutil.net_io_counters()

    elapsed = now - _prev_time or 1
    sent_mbps = (net.bytes_sent - _prev_net.bytes_sent) * 8 / elapsed / 1_000_000
    recv_mbps = (net.bytes_recv - _prev_net.bytes_recv) * 8 / elapsed / 1_000_000
    _prev_net = net
    _prev_time = now

    # VM + container counts
    vm_count = vm_running = ct_count = ct_running = 0
    try:
        from core import libvirt_manager
        vms = libvirt_manager.list_vms()
        vm_count = len(vms)
        vm_running = sum(1 for v in vms if v['status'] == 'running')
    except Exception:
        pass
    try:
        from core import lxc_manager
        cts = lxc_manager.list_containers()
        ct_count = len(cts)
        ct_running = sum(1 for c in cts if c['status'] == 'running')
    except Exception:
        pass

    cpu_model = 'Unknown'
    try:
        with open('/proc/cpuinfo') as f:
            for line in f:
                if line.startswith('model name'):
                    cpu_model = line.split(':', 1)[1].strip()
                    break
    except Exception:
        cpu_model = platform.processor()

    load = psutil.getloadavg()

    return {
        'cpu_percent': round(cpu, 1),
        'memory_used_gb': round(mem.used / 1024 ** 3, 2),
        'memory_total_gb': round(mem.total / 1024 ** 3, 2),
        'memory_percent': round(mem.percent, 1),
        'disk_used_gb': round(disk.used / 1024 ** 3, 2),
        'disk_total_gb': round(disk.total / 1024 ** 3, 2),
        'disk_percent': round(disk.percent, 1),
        'net_sent_mbps': round(sent_mbps, 2),
        'net_recv_mbps': round(recv_mbps, 2),
        'uptime_seconds': int(time.time() - psutil.boot_time()),
        'hostname': socket.gethostname(),
        'cpu_model': cpu_model,
        'vm_count': vm_count,
        'container_count': ct_count,
        'vm_running': vm_running,
        'container_running': ct_running,
        'load_avg': [round(l, 2) for l in load],
    }
