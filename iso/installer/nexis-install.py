#!/usr/bin/env python3
"""
NeXiS Hypervisor — Installation Program
Proxmox/ESXi-style interactive bare-metal installer.

Runs from the live boot environment. Guides the user through:
  disk selection → hostname → credentials → installation → reboot
"""
import curses
import subprocess
import json
import os
import sys
import re
import time
import threading
from pathlib import Path

ORANGE = None
WHITE  = None
DIM    = None
GREEN  = None
RED    = None

TARGET     = '/mnt/nexis-target'
NEXIS_REPO = 'https://github.com/santiagotoro2023/nexis-hypervisor'


# ── Hardware detection ─────────────────────────────────────────────────────────

def _run(*cmd, capture=True):
    r = subprocess.run(list(cmd), capture_output=capture, text=True)
    return r.stdout.strip() if capture else r.returncode == 0

def get_disks():
    try:
        r = subprocess.run(
            ['lsblk', '-d', '-o', 'NAME,SIZE,MODEL,TYPE', '--json', '--nodeps'],
            capture_output=True, text=True
        )
        devices = json.loads(r.stdout).get('blockdevices', [])
        out = []
        for d in devices:
            name = d.get('name', '')
            if d.get('type') in ('rom', 'loop') or name.startswith('loop'):
                continue
            out.append({
                'dev':   f'/dev/{name}',
                'size':  (d.get('size') or '?').strip(),
                'model': (d.get('model') or 'Unknown Device').strip()[:36],
            })
        return out or [{'dev': '/dev/sda', 'size': '?', 'model': 'Unknown Device'}]
    except Exception:
        return [{'dev': '/dev/sda', 'size': '?', 'model': 'Unknown Device'}]

def _part(disk, n):
    sep = 'p' if ('nvme' in disk or 'mmcblk' in disk) else ''
    return f'{disk}{sep}{n}'


# ── Installation ───────────────────────────────────────────────────────────────

_install_log   = []
_install_step  = (0, 1, '')
_install_done  = False
_install_error = None
_install_lock  = threading.Lock()


def _log(line):
    with _install_lock:
        _install_log.append(line[:72])
        if len(_install_log) > 200:
            _install_log.pop(0)

def _step(i, total, label):
    global _install_step
    with _install_lock:
        _install_step = (i, total, label)
    _log(f'[{i+1}/{total}] {label}')

def _run_log(*cmd, cwd=None, env=None):
    kw = dict(stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if cwd:  kw['cwd']  = cwd
    if env:  kw['env']  = env
    proc = subprocess.Popen(list(cmd), **kw)
    for line in proc.stdout:
        _log(line.rstrip())
    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(f'{cmd[0]} exited with code {proc.returncode}')


def install_thread(disk, hostname, root_pw, controller_url):
    global _install_done, _install_error
    try:
        steps = [
            ('Partitioning disk',       lambda: _partition(disk)),
            ('Formatting filesystems',  lambda: _format(disk)),
            ('Mounting target',         lambda: _mount(disk)),
            ('Bootstrapping Debian 12', lambda: _debootstrap()),
            ('Configuring base system', lambda: _configure(disk, hostname, root_pw, controller_url)),
            ('Installing packages',     lambda: _packages()),
            ('Fetching NeXiS',          lambda: _nexis()),
            ('Installing bootloader',   lambda: _grub(disk)),
            ('Cleaning up',             lambda: _cleanup()),
        ]
        for i, (label, fn) in enumerate(steps):
            _step(i, len(steps), label)
            fn()
        with _install_lock:
            _install_done = True
    except Exception as exc:
        with _install_lock:
            _install_error = str(exc)


def _partition(disk):
    _log(f'  Target disk: {disk}')
    subprocess.run(['parted', '-s', disk, 'mklabel', 'gpt'],              check=True)
    subprocess.run(['parted', '-s', disk, 'mkpart', 'ESP',  'fat32', '1MiB',   '513MiB'], check=True)
    subprocess.run(['parted', '-s', disk, 'set', '1', 'esp', 'on'],       check=True)
    subprocess.run(['parted', '-s', disk, 'mkpart', 'root', 'ext4',  '513MiB', '100%'],   check=True)
    _log('  Partitioned: 512 MiB EFI + remainder root')


def _format(disk):
    subprocess.run(['mkfs.fat', '-F32', '-n', 'NEXIS_EFI',  _part(disk, 1)], check=True)
    subprocess.run(['mkfs.ext4', '-F', '-L', 'nexis-root', _part(disk, 2)], check=True)
    _log('  Formatted EFI (FAT32) and root (ext4)')


def _mount(disk):
    os.makedirs(TARGET, exist_ok=True)
    subprocess.run(['mount', _part(disk, 2), TARGET], check=True)
    os.makedirs(f'{TARGET}/boot/efi', exist_ok=True)
    subprocess.run(['mount', _part(disk, 1), f'{TARGET}/boot/efi'], check=True)
    _log(f'  Mounted at {TARGET}')


def _debootstrap():
    _run_log(
        'debootstrap', '--arch=amd64',
        '--include=linux-image-amd64,grub-efi-amd64,efibootmgr,systemd-sysv,'
        'locales,ca-certificates,curl,openssh-server',
        'bookworm', TARGET, 'https://deb.debian.org/debian'
    )


def _configure(disk, hostname, root_pw, controller_url):
    import crypt

    # fstab
    root_uuid = _run('blkid', '-s', 'UUID', '-o', 'value', _part(disk, 2))
    efi_uuid  = _run('blkid', '-s', 'UUID', '-o', 'value', _part(disk, 1))
    Path(f'{TARGET}/etc/fstab').write_text(
        f'UUID={root_uuid}  /          ext4  errors=remount-ro  0  1\n'
        f'UUID={efi_uuid}   /boot/efi  vfat  umask=0077         0  2\n'
    )

    # hostname
    Path(f'{TARGET}/etc/hostname').write_text(f'{hostname}\n')
    Path(f'{TARGET}/etc/hosts').write_text(
        f'127.0.0.1   localhost\n127.0.1.1   {hostname}\n'
        '::1         localhost ip6-localhost ip6-loopback\n'
    )

    # root password
    hashed = crypt.crypt(root_pw, crypt.mksalt(crypt.METHOD_SHA512))
    subprocess.run(['chpasswd', '-R', TARGET, '-e'],
                   input=f'root:{hashed}\n', text=True, check=True)

    # apt sources
    Path(f'{TARGET}/etc/apt/sources.list').write_text(
        'deb https://deb.debian.org/debian bookworm main contrib non-free-firmware\n'
        'deb https://security.debian.org/debian-security bookworm-security main contrib\n'
        'deb https://deb.debian.org/debian bookworm-updates main contrib\n'
    )

    # controller URL pre-config
    if controller_url:
        cfg_dir = Path(f'{TARGET}/etc/nexis-hypervisor')
        cfg_dir.mkdir(parents=True, exist_ok=True)
        (cfg_dir / 'config.json').write_text(
            json.dumps({'pending_controller_url': controller_url.rstrip('/')}, indent=2)
        )

    # bind mounts for chroot operations
    for d in ('proc', 'sys', 'dev', 'dev/pts'):
        mp = f'{TARGET}/{d}'
        os.makedirs(mp, exist_ok=True)
        subprocess.run(['mount', '--bind', f'/{d}', mp], capture_output=True)

    _log(f'  Hostname: {hostname}, password set, sources configured')


def _packages():
    env = {**os.environ, 'DEBIAN_FRONTEND': 'noninteractive', 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'}
    pkgs = [
        'qemu-kvm', 'libvirt-daemon-system', 'libvirt-clients',
        'lxc', 'novnc', 'websockify',
        'python3', 'python3-pip', 'python3-venv', 'python3-dev',
        'libvirt-dev', 'pkg-config', 'build-essential',
        'bridge-utils', 'nftables', 'sudo',
        'curl', 'git', 'jq', 'htop', 'vim-tiny',
        'parted', 'lsblk',
    ]
    _run_log(
        'chroot', TARGET, 'apt-get', 'update', '-qq',
        env=env
    )
    _run_log(
        'chroot', TARGET, 'apt-get', 'install', '-yq',
        '--no-install-recommends', *pkgs,
        env=env
    )


def _nexis():
    env = {**os.environ, 'DEBIAN_FRONTEND': 'noninteractive', 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'}
    install_dir = '/opt/nexis-hypervisor'

    _run_log(
        'chroot', TARGET, 'git', 'clone', '--quiet', '--depth', '1',
        NEXIS_REPO, install_dir,
        env=env
    )
    _run_log(
        'chroot', TARGET, 'python3', '-m', 'venv', f'{install_dir}/venv',
        env=env
    )
    _run_log(
        'chroot', TARGET,
        f'{install_dir}/venv/bin/pip', 'install', '-q', '--upgrade', 'pip',
        env=env
    )
    _run_log(
        'chroot', TARGET,
        f'{install_dir}/venv/bin/pip', 'install', '-q',
        '-r', f'{install_dir}/daemon/requirements.txt',
        env=env
    )

    # Install npm + build web UI
    _run_log(
        'chroot', TARGET, 'bash', '-c',
        'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - -s -- -y 2>/dev/null'
        ' && apt-get install -yq nodejs 2>/dev/null'
        f' && cd {install_dir}/web && npm install --silent && npm run build --silent',
        env=env
    )

    # Data dir
    os.makedirs(f'{TARGET}/etc/nexis-hypervisor', exist_ok=True)

    # Copy firstboot TUI
    src = Path('/opt/nexis-installer/firstboot-tui.py')
    dst = Path(f'{TARGET}/usr/local/bin/nexis-firstboot')
    if src.exists():
        dst.write_bytes(src.read_bytes())
        dst.chmod(0o755)

    # Systemd units
    svc_src = Path(f'{TARGET}{install_dir}/nexis-hypervisor.service')
    svc_dst = Path(f'{TARGET}/etc/systemd/system/nexis-hypervisor.service')
    if svc_src.exists():
        svc_dst.write_bytes(svc_src.read_bytes())

    Path(f'{TARGET}/etc/systemd/system/nexis-firstboot.service').write_text(
        '[Unit]\n'
        'Description=NeXiS Hypervisor First-Boot Configuration\n'
        'After=multi-user.target\n'
        'ConditionPathExists=!/etc/nexis-hypervisor/.firstboot-done\n\n'
        '[Service]\n'
        'Type=simple\n'
        'ExecStart=/usr/bin/python3 /usr/local/bin/nexis-firstboot\n'
        'StandardInput=tty\nTTYPath=/dev/tty1\nTTYReset=yes\nTTYVHangup=yes\n\n'
        '[Install]\nWantedBy=multi-user.target\n'
    )

    subprocess.run(
        ['chroot', TARGET, 'systemctl', 'enable',
         'nexis-hypervisor', 'nexis-firstboot', 'libvirtd', 'ssh'],
        env=env, capture_output=True
    )
    _log('  NeXiS daemon and services enabled')


def _grub(disk):
    env = {**os.environ, 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'}
    subprocess.run(
        ['chroot', TARGET, 'grub-install',
         '--target=x86_64-efi', '--efi-directory=/boot/efi',
         '--bootloader-id=NeXiS', '--recheck'],
        env=env, check=True, capture_output=True
    )
    Path(f'{TARGET}/etc/default/grub').write_text(
        'GRUB_DEFAULT=0\n'
        'GRUB_TIMEOUT=3\n'
        'GRUB_DISTRIBUTOR="NeXiS Hypervisor"\n'
        'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n'
        'GRUB_CMDLINE_LINUX=""\n'
        'GRUB_TERMINAL=console\n'
        'GRUB_COLOR_NORMAL="white/black"\n'
        'GRUB_COLOR_HIGHLIGHT="yellow/black"\n'
        'GRUB_MENU_PICTURE=""\n'
    )
    subprocess.run(
        ['chroot', TARGET, 'update-grub'],
        env=env, check=True, capture_output=True
    )
    _log('  GRUB installed and configured')


def _cleanup():
    for mp in ('dev/pts', 'dev', 'sys', 'proc', 'boot/efi', ''):
        path = f'{TARGET}/{mp}' if mp else TARGET
        subprocess.run(['umount', '-lf', path], capture_output=True)
    _log('  Filesystems unmounted')


# ── Drawing helpers ────────────────────────────────────────────────────────────

def _clear(stdscr):
    stdscr.erase()

def _border(win, title=''):
    win.box()
    if title:
        h, w = win.getmaxyx()
        label = f'  {title}  '
        x = max(2, (w - len(label)) // 2)
        try:
            win.addstr(0, x, label, curses.color_pair(ORANGE) | curses.A_BOLD)
        except curses.error:
            pass

def _logo(stdscr, y, x):
    lines = [
        '      /\\       ',
        '     /  \\      ',
        '    / () \\     ',
        '   /______\\    ',
    ]
    for i, ln in enumerate(lines):
        try:
            stdscr.addstr(y + i, x, ln, curses.color_pair(ORANGE) | curses.A_BOLD)
        except curses.error:
            pass

def _hdr(stdscr, H, W):
    try:
        stdscr.addstr(1, (W - 17) // 2,
                      'NeXiS Hypervisor',
                      curses.color_pair(ORANGE) | curses.A_BOLD)
        stdscr.addstr(2, (W - 50) // 2,
                      'Neural Execution and Cross-device Inference System',
                      curses.color_pair(DIM))
        stdscr.addstr(3, (W - 36) // 2,
                      '─' * 36, curses.color_pair(DIM))
    except curses.error:
        pass

def _footer(stdscr, H, W, msg='Arrow keys: navigate   Enter: select   Q: quit'):
    try:
        stdscr.addstr(H - 2, (W - len(msg)) // 2, msg, curses.color_pair(DIM))
    except curses.error:
        pass

def _step_bar(stdscr, H, W, steps, current):
    labels = ['DISK', 'HOST', 'AUTH', 'CONFIRM', 'INSTALL', 'DONE']
    total  = len(labels)
    slot   = max(8, W // total)
    y      = 5
    for i, lbl in enumerate(labels):
        attr = curses.color_pair(ORANGE) | curses.A_BOLD if i == current else curses.color_pair(DIM)
        prefix = '● ' if i == current else ('✓ ' if i < current else '○ ')
        try:
            stdscr.addstr(y, 2 + i * slot, prefix + lbl, attr)
        except curses.error:
            pass

def _input_field(win, y, x, width, label, default='', secret=False, hint=''):
    label_s = f'{label}: '
    try:
        win.addstr(y, x, label_s, curses.color_pair(WHITE))
        if hint:
            win.addstr(y, x + len(label_s) + width + 2, hint, curses.color_pair(DIM))
    except curses.error:
        pass
    curses.echo()
    curses.curs_set(1)
    try:
        win.addstr(y, x + len(label_s), ' ' * width)
        win.move(y, x + len(label_s))
    except curses.error:
        pass
    if default:
        try:
            win.addstr(y, x + len(label_s), default, curses.color_pair(DIM))
        except curses.error:
            pass
    win.refresh()
    if secret:
        curses.noecho()
    val = ''
    try:
        raw = win.getstr(y, x + len(label_s), width)
        val = raw.decode('utf-8', 'replace').strip()
    except Exception:
        pass
    curses.noecho()
    curses.curs_set(0)
    return val or default


# ── Screens ────────────────────────────────────────────────────────────────────

def screen_welcome(stdscr, H, W):
    while True:
        _clear(stdscr)
        _hdr(stdscr, H, W)
        _step_bar(stdscr, H, W, 6, 0)
        _logo(stdscr, (H - 10) // 2, (W - 16) // 2)

        cy = (H - 10) // 2 + 6
        try:
            stdscr.addstr(cy,     (W - 34) // 2,
                          'NeXiS Hypervisor Installation',
                          curses.color_pair(WHITE) | curses.A_BOLD)
            stdscr.addstr(cy + 2, (W - 60) // 2,
                          'This wizard will install NeXiS Hypervisor on this machine.',
                          curses.color_pair(DIM))
            stdscr.addstr(cy + 3, (W - 62) // 2,
                          'All data on the selected disk will be erased. Proceed with care.',
                          curses.color_pair(RED))
            stdscr.addstr(cy + 5, (W - 38) // 2,
                          'Press  Enter  to begin installation.',
                          curses.color_pair(WHITE))
            stdscr.addstr(cy + 6, (W - 38) // 2,
                          'Press  Q      to quit to shell.',
                          curses.color_pair(DIM))
        except curses.error:
            pass

        _footer(stdscr, H, W, 'Enter: begin installation   Q: quit to shell')
        stdscr.refresh()
        k = stdscr.getch()
        if k in (10, 13):
            return True
        if k in (ord('q'), ord('Q')):
            return False


def screen_disk(stdscr, H, W, disks):
    selected = 0
    while True:
        _clear(stdscr)
        _hdr(stdscr, H, W)
        _step_bar(stdscr, H, W, 6, 1)

        win_h = min(len(disks) + 6, H - 12)
        win_w = 60
        win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
        _border(win, 'Select Installation Target')
        try:
            win.addstr(2, 2,
                       'Select the disk to install NeXiS Hypervisor on.',
                       curses.color_pair(DIM))
            win.addstr(3, 2,
                       'ALL DATA ON THE SELECTED DISK WILL BE ERASED.',
                       curses.color_pair(RED) | curses.A_BOLD)
        except curses.error:
            pass

        for i, d in enumerate(disks):
            attr = curses.color_pair(ORANGE) | curses.A_BOLD if i == selected else curses.color_pair(WHITE)
            prefix = '  >  ' if i == selected else '     '
            label  = f'{d["dev"]}  {d["size"]:>8}  {d["model"]}'
            try:
                win.addstr(5 + i, 2, prefix + label, attr)
            except curses.error:
                pass
        win.refresh()
        _footer(stdscr, H, W, 'Up/Down: navigate   Enter: select disk   Q: back')
        stdscr.refresh()

        k = stdscr.getch()
        if k == curses.KEY_UP   and selected > 0:              selected -= 1
        elif k == curses.KEY_DOWN and selected < len(disks)-1: selected += 1
        elif k in (10, 13):
            return disks[selected]['dev']
        elif k in (ord('q'), ord('Q')):
            return None


def screen_hostname(stdscr, H, W):
    win_h, win_w = 10, 56
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _clear(stdscr)
    _hdr(stdscr, H, W)
    _step_bar(stdscr, H, W, 6, 2)
    _border(win, 'Node Identity')
    try:
        win.addstr(2, 2, 'Set the hostname for this hypervisor node.', curses.color_pair(DIM))
        win.addstr(3, 2, 'Example: nexis-node-01, hv-lab, gpu-server', curses.color_pair(DIM))
    except curses.error:
        pass
    hostname = _input_field(win, 5, 2, 32, 'Hostname', 'nexis-node-01')
    win.addstr(7, 2, 'Press any key...', curses.color_pair(DIM))
    win.refresh()
    _footer(stdscr, H, W)
    stdscr.refresh()
    return re.sub(r'[^a-zA-Z0-9\-]', '-', hostname).strip('-') or 'nexis-node'


def screen_credentials(stdscr, H, W):
    win_h, win_w = 14, 64
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _clear(stdscr)
    _hdr(stdscr, H, W)
    _step_bar(stdscr, H, W, 6, 3)

    while True:
        win.erase()
        _border(win, 'Authentication')
        try:
            win.addstr(2, 2,
                       'Set the root password and optional Controller URL.',
                       curses.color_pair(DIM))
        except curses.error:
            pass

        pw1 = _input_field(win, 4, 2, 28, 'Root password       ', secret=True)
        pw2 = _input_field(win, 5, 2, 28, 'Confirm password    ', secret=True)
        url = _input_field(win, 7, 2, 40, 'Controller URL      ',
                           'https://192.168.1.x:8443',
                           hint='(optional)')

        if pw1 != pw2:
            try:
                win.addstr(9, 2, 'Passwords do not match. Try again.', curses.color_pair(RED))
            except curses.error:
                pass
            win.refresh()
            stdscr.getch()
            continue

        if len(pw1) < 8:
            try:
                win.addstr(9, 2, 'Password must be at least 8 characters.', curses.color_pair(RED))
            except curses.error:
                pass
            win.refresh()
            stdscr.getch()
            continue

        ctrl = '' if url == 'https://192.168.1.x:8443' else url.strip()
        return pw1, ctrl


def screen_confirm(stdscr, H, W, disk, hostname, controller_url):
    win_h, win_w = 16, 62
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    while True:
        _clear(stdscr)
        _hdr(stdscr, H, W)
        _step_bar(stdscr, H, W, 6, 4)
        win.erase()
        _border(win, 'Confirm Installation')
        try:
            win.addstr(2, 2, 'Installation summary:', curses.color_pair(WHITE) | curses.A_BOLD)
            win.addstr(4, 4, f'Target disk  :  {disk}', curses.color_pair(WHITE))
            win.addstr(5, 4, f'Hostname     :  {hostname}', curses.color_pair(WHITE))
            win.addstr(6, 4, f'Controller   :  {controller_url or "(local auth only)"}',
                       curses.color_pair(WHITE))
            win.addstr(8, 2, '! ALL DATA ON THE TARGET DISK WILL BE PERMANENTLY ERASED !',
                       curses.color_pair(RED) | curses.A_BOLD)
            win.addstr(10, 2, 'Continue?', curses.color_pair(WHITE))
            win.addstr(11, 4, '[Y]  Yes, erase disk and install', curses.color_pair(ORANGE) | curses.A_BOLD)
            win.addstr(12, 4, '[N]  No, go back', curses.color_pair(DIM))
        except curses.error:
            pass
        win.refresh()
        _footer(stdscr, H, W, 'Y: install   N: go back')
        stdscr.refresh()
        k = stdscr.getch()
        if k in (ord('y'), ord('Y')):
            return True
        if k in (ord('n'), ord('N'), 27):
            return False


def screen_installing(stdscr, H, W, disk, hostname, root_pw, controller_url):
    global _install_log, _install_step, _install_done, _install_error

    _install_log   = []
    _install_step  = (0, 9, 'Starting...')
    _install_done  = False
    _install_error = None

    t = threading.Thread(
        target=install_thread,
        args=(disk, hostname, root_pw, controller_url),
        daemon=True
    )
    t.start()

    log_h = H - 18
    log_w = W - 8
    log_win = curses.newwin(log_h, log_w, 15, 4)

    while True:
        with _install_lock:
            step_i, step_total, step_label = _install_step
            done  = _install_done
            error = _install_error
            lines = list(_install_log)

        _clear(stdscr)
        _hdr(stdscr, H, W)
        _step_bar(stdscr, H, W, 6, 5)

        # Progress bar
        bar_w  = W - 20
        filled = int(bar_w * step_i / max(step_total, 1))
        pct    = int(100 * step_i / max(step_total, 1))
        bar    = '█' * filled + '░' * (bar_w - filled)
        try:
            stdscr.addstr(7,  4, f'Step {step_i}/{step_total}: {step_label}',
                          curses.color_pair(WHITE) | curses.A_BOLD)
            stdscr.addstr(8,  4, f'[{bar}] {pct}%', curses.color_pair(ORANGE))
            stdscr.addstr(10, 4, 'Installation log:', curses.color_pair(DIM))
        except curses.error:
            pass

        # Scrolling log
        log_win.erase()
        log_win.box()
        visible = lines[-(log_h - 2):]
        for i, ln in enumerate(visible):
            try:
                log_win.addstr(i + 1, 1, ln[:log_w - 2], curses.color_pair(DIM))
            except curses.error:
                pass
        log_win.refresh()

        if error:
            try:
                stdscr.addstr(H - 4, 4,
                              f'ERROR: {error}',
                              curses.color_pair(RED) | curses.A_BOLD)
                stdscr.addstr(H - 3, 4,
                              'Press any key to exit to shell.',
                              curses.color_pair(DIM))
            except curses.error:
                pass
            stdscr.refresh()
            stdscr.getch()
            return False

        if done:
            return True

        stdscr.refresh()
        curses.napms(500)


def screen_done(stdscr, H, W, hostname):
    ip = '?.?.?.?'
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        pass

    win_h, win_w = 16, 62
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _clear(stdscr)
    _hdr(stdscr, H, W)
    _step_bar(stdscr, H, W, 6, 6)
    win.erase()
    _border(win, 'Installation Complete')
    try:
        win.addstr(2, 2,  'NeXiS Hypervisor has been installed successfully.',
                   curses.color_pair(GREEN) | curses.A_BOLD)
        win.addstr(4, 2,  f'Hostname  :  {hostname}',      curses.color_pair(WHITE))
        win.addstr(5, 2,  f'Web UI    :  https://{ip}:8443',
                   curses.color_pair(ORANGE) | curses.A_BOLD)
        win.addstr(7, 2,  'Default credentials (first boot):', curses.color_pair(DIM))
        win.addstr(8, 4,  'Username  :  creator',           curses.color_pair(WHITE))
        win.addstr(9, 4,  'Password  :  Asdf1234!',         curses.color_pair(WHITE))
        win.addstr(11, 2, 'On reboot, a configuration TUI will launch.',
                   curses.color_pair(DIM))
        win.addstr(12, 2, 'Set network, hostname, and controller URL there.',
                   curses.color_pair(DIM))
        win.addstr(14, 2, 'Press Enter to reboot.', curses.color_pair(WHITE))
    except curses.error:
        pass
    win.refresh()
    _footer(stdscr, H, W, 'Enter: reboot now')
    stdscr.refresh()
    while stdscr.getch() not in (10, 13):
        pass
    subprocess.run(['reboot'])


# ── Main ───────────────────────────────────────────────────────────────────────

def main(stdscr):
    global ORANGE, WHITE, DIM, GREEN, RED

    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, curses.COLOR_WHITE,  -1)
    curses.init_pair(3, curses.COLOR_BLACK + 8 if curses.COLORS >= 16 else curses.COLOR_BLACK, -1)
    curses.init_pair(4, curses.COLOR_GREEN,  -1)
    curses.init_pair(5, curses.COLOR_RED,    -1)

    ORANGE = 1; WHITE = 2; DIM = 3; GREEN = 4; RED = 5
    curses.curs_set(0)
    curses.cbreak()
    stdscr.keypad(True)

    H, W = stdscr.getmaxyx()

    if not screen_welcome(stdscr, H, W):
        return

    disks = get_disks()
    disk  = screen_disk(stdscr, H, W, disks)
    if not disk:
        return

    hostname = screen_hostname(stdscr, H, W)

    root_pw, controller_url = screen_credentials(stdscr, H, W)

    if not screen_confirm(stdscr, H, W, disk, hostname, controller_url):
        return

    H, W = stdscr.getmaxyx()
    ok = screen_installing(stdscr, H, W, disk, hostname, root_pw, controller_url)
    if ok:
        screen_done(stdscr, H, W, hostname)


if __name__ == '__main__':
    if os.geteuid() != 0:
        print('NeXiS installer must run as root.', file=sys.stderr)
        sys.exit(1)
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
