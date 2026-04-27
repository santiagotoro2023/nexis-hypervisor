#!/usr/bin/env python3
"""
NeXiS Hypervisor — Management Shell
Runs on TTY1 after installation. Replaces the bare Linux prompt.
Dark background, orange accents. Clinical, precise, slightly ominous.
"""
import curses
import subprocess
import os
import sys
import time
import socket
import threading
from pathlib import Path

ORANGE = 1
WHITE  = 2
DIM    = 3
GREEN  = 4
RED    = 5

LOGO = [
    "         /\\         ",
    "        /  \\        ",
    "       / () \\       ",
    "      /______\\      ",
]

_PHRASES = [
    "THE EYE IS OPEN.",
    "ALL SYSTEMS NOMINAL.",
    "NEURAL EXECUTION LAYER ACTIVE.",
    "OBSERVER ONLINE. STANDING BY.",
    "COMPUTATIONAL RESOURCES ALLOCATED.",
    "INTEGRITY VERIFICATION COMPLETE.",
    "AWAITING INPUT.",
    "PROCESSES RUNNING WITHIN PARAMETERS.",
]


# ── System data ────────────────────────────────────────────────────────────────

def _run(*cmd):
    try:
        return subprocess.check_output(
            list(cmd), stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ''

def _get_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except Exception:
        return '?.?.?.?'

def _get_cpu():
    def _read():
        with open('/proc/stat') as f:
            return list(map(int, f.readline().split()[1:]))
    try:
        a = _read(); time.sleep(0.15); b = _read()
        idle  = b[3] - a[3]
        total = sum(b) - sum(a)
        return max(0, int(100 * (1 - idle / total))) if total else 0
    except Exception:
        return 0

def _get_mem():
    try:
        d = {}
        for line in open('/proc/meminfo'):
            k, v = line.split(':', 1)
            d[k.strip()] = int(v.split()[0])
        total = d['MemTotal'] // 1024
        avail = d.get('MemAvailable', d.get('MemFree', 0)) // 1024
        return total - avail, total
    except Exception:
        return 0, 0

def _get_disk():
    try:
        s = os.statvfs('/')
        total = s.f_blocks * s.f_frsize // (1024 ** 3)
        free  = s.f_bavail * s.f_frsize // (1024 ** 3)
        used  = total - free
        pct   = int(100 * used / total) if total else 0
        return used, total, pct
    except Exception:
        return 0, 0, 0

def _get_vms():
    out = _run('virsh', 'list', '--state-running')
    return max(0, len([l for l in out.splitlines()
                       if l.strip() and not l.strip().startswith('Id') and '---' not in l]) - 0)

def _get_containers():
    out = _run('lxc-ls', '--running')
    return len(out.split()) if out else 0

def _get_nexis_status():
    out = _run('rc-service', 'nexis-hypervisor', 'status')
    return 'ONLINE' if 'started' in out.lower() else 'OFFLINE'

def _get_uptime():
    try:
        secs = float(open('/proc/uptime').read().split()[0])
        h, m = int(secs // 3600), int((secs % 3600) // 60)
        return f'{h}h {m}m'
    except Exception:
        return '?'


# ── Drawing helpers ────────────────────────────────────────────────────────────

def _safe(win, y, x, s, attr=0):
    try:
        win.addstr(y, x, s, attr)
    except curses.error:
        pass

def _hline(win, y, W, ch='─'):
    _safe(win, y, 2, ch * max(0, W - 4), curses.color_pair(DIM))

def _border(win, title=''):
    win.box()
    if title:
        h, w = win.getmaxyx()
        label = f'  {title}  '
        _safe(win, 0, max(2, (w - len(label)) // 2), label,
              curses.color_pair(ORANGE) | curses.A_BOLD)


# ── Sub-screens ────────────────────────────────────────────────────────────────

def screen_node_info(stdscr, H, W):
    ip       = _get_ip()
    hostname = _run('hostname') or 'nexis-node'
    cpu      = _get_cpu()
    mu, mt   = _get_mem()
    du, dt, dp = _get_disk()
    vms      = _get_vms()
    cts      = _get_containers()
    nexis    = _get_nexis_status()
    uptime   = _get_uptime()
    kernel   = _run('uname', '-r')

    win_h, win_w = 20, 60
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _border(win, 'NODE INFORMATION')

    rows = [
        ('HOSTNAME',         hostname),
        ('IP ADDRESS',       ip),
        ('WEB INTERFACE',    f'https://{ip}:8443'),
        ('UPTIME',           uptime),
        ('KERNEL',           kernel),
        ('CPU UTILISATION',  f'{cpu}%'),
        ('MEMORY',           f'{mu} / {mt} MB'),
        ('DISK',             f'{du} / {dt} GB  ({dp}%)'),
        ('VMs ACTIVE',       str(vms)),
        ('CONTAINERS ACTIVE',str(cts)),
        ('NEXIS DAEMON',     nexis),
    ]

    for i, (k, v) in enumerate(rows):
        _safe(win, 2 + i, 3,  f'{k:<22}', curses.color_pair(DIM))
        colour = GREEN if v in ('ONLINE',) else (RED if v == 'OFFLINE' else WHITE)
        _safe(win, 2 + i, 26, v, curses.color_pair(colour))

    _safe(win, win_h - 2, 3, 'Press any key...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_network(stdscr, H, W):
    ip = _get_ip()
    ifaces = _run('ip', '-o', 'link', 'show').splitlines()
    addrs  = _run('ip', '-o', 'addr', 'show').splitlines()

    win_h, win_w = 16, 64
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _border(win, 'NETWORK CONFIGURATION')
    _safe(win, 2, 3, f'Management IP: {ip}', curses.color_pair(ORANGE) | curses.A_BOLD)
    _safe(win, 3, 3, '─' * (win_w - 6), curses.color_pair(DIM))

    row = 4
    for line in addrs[:8]:
        parts = line.split()
        if len(parts) >= 4:
            iface = parts[1].rstrip(':')
            addr  = parts[3]
            _safe(win, row, 3, f'{iface:<12}  {addr}', curses.color_pair(WHITE))
            row += 1
        if row >= win_h - 3:
            break

    _safe(win, win_h - 2, 3, 'Press any key...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_services(stdscr, H, W):
    services = ['nexis-hypervisor', 'libvirtd', 'sshd', 'nftables', 'networking']

    win_h, win_w = 14, 52
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _border(win, 'NEXIS SERVICES')

    for i, svc in enumerate(services):
        out = _run('rc-service', svc, 'status')
        ok  = 'started' in out.lower() or 'running' in out.lower()
        dot = '●' if ok else '○'
        col = GREEN if ok else RED
        sta = 'ONLINE' if ok else 'OFFLINE'
        _safe(win, 2 + i, 3, dot, curses.color_pair(col))
        _safe(win, 2 + i, 5, f'{svc:<24}', curses.color_pair(WHITE))
        _safe(win, 2 + i, 30, sta, curses.color_pair(col))

    _safe(win, win_h - 3, 3, 'R: restart NeXiS daemon   any key: back',
          curses.color_pair(DIM))
    win.refresh()
    k = win.getch()
    if k == ord('r') or k == ord('R'):
        _safe(win, win_h - 2, 3, 'Restarting...            ', curses.color_pair(DIM))
        win.refresh()
        _run('rc-service', 'nexis-hypervisor', 'restart')
        time.sleep(2)


def screen_logs(stdscr, H, W):
    log_files = [
        '/var/log/nexis-hypervisor.log',
        '/var/log/nexis-install.log',
    ]

    win_h = H - 8
    win_w = W - 6
    win = curses.newwin(win_h, win_w, 4, 3)
    _border(win, 'SYSTEM LOGS')

    log_content = []
    for lf in log_files:
        p = Path(lf)
        if p.exists():
            log_content.append(f'=== {lf} ===')
            lines = p.read_text().splitlines()
            log_content.extend(lines[-50:])
            log_content.append('')

    offset = max(0, len(log_content) - (win_h - 3))
    visible = log_content[offset:][:win_h - 3]

    for i, line in enumerate(visible):
        _safe(win, 1 + i, 1, line[:win_w - 2], curses.color_pair(DIM))

    _safe(win, win_h - 1, 3, 'Any key to return...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_password(stdscr, H, W):
    win_h, win_w = 12, 52
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)

    while True:
        win.erase()
        _border(win, 'CHANGE PASSWORD')
        _safe(win, 2, 3, 'Set a new root password.', curses.color_pair(DIM))

        curses.echo()
        curses.curs_set(1)
        _safe(win, 4, 3, 'New password:     ', curses.color_pair(WHITE))
        win.refresh()
        curses.noecho()
        pw1 = ''
        try:
            pw1 = win.getstr(4, 18, 20).decode('utf-8', 'replace').strip()
        except Exception:
            break

        _safe(win, 5, 3, 'Confirm password: ', curses.color_pair(WHITE))
        win.refresh()
        curses.noecho()
        pw2 = ''
        try:
            pw2 = win.getstr(5, 18, 20).decode('utf-8', 'replace').strip()
        except Exception:
            break
        curses.curs_set(0)

        if len(pw1) < 8:
            _safe(win, 7, 3, 'Password must be at least 8 characters.',
                  curses.color_pair(RED))
            win.refresh()
            win.getch()
            continue

        if pw1 != pw2:
            _safe(win, 7, 3, 'Passwords do not match.',
                  curses.color_pair(RED))
            win.refresh()
            win.getch()
            continue

        try:
            proc = subprocess.run(
                ['chpasswd'], input=f'root:{pw1}\n',
                capture_output=True, text=True)
            if proc.returncode == 0:
                _safe(win, 7, 3, 'Password updated.',
                      curses.color_pair(GREEN))
            else:
                _safe(win, 7, 3, 'Failed to update password.',
                      curses.color_pair(RED))
        except Exception:
            _safe(win, 7, 3, 'Error changing password.',
                  curses.color_pair(RED))

        win.refresh()
        win.getch()
        break


# ── Main loop ──────────────────────────────────────────────────────────────────

def main(stdscr):
    global ORANGE, WHITE, DIM, GREEN, RED

    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, curses.COLOR_WHITE,  -1)
    curses.init_pair(3, curses.COLOR_BLACK + 8 if curses.COLORS >= 16
                     else curses.COLOR_BLACK, -1)
    curses.init_pair(4, curses.COLOR_GREEN, -1)
    curses.init_pair(5, curses.COLOR_RED,   -1)

    ORANGE = 1; WHITE = 2; DIM = 3; GREEN = 4; RED = 5

    curses.curs_set(0)
    curses.cbreak()
    stdscr.keypad(True)

    phrase_idx = 0
    items = [
        ('1', 'NODE INFORMATION'),
        ('2', 'NETWORK CONFIGURATION'),
        ('3', 'NEXIS SERVICES'),
        ('4', 'SYSTEM LOGS'),
        ('5', 'CHANGE PASSWORD'),
        ('0', 'ACCESS LINUX SHELL'),
    ]

    while True:
        stdscr.erase()
        H, W = stdscr.getmaxyx()

        # ── Logo ──────────────────────────────────────────────────────────────
        logo_x = max(0, (W - len(LOGO[0])) // 2)
        for i, line in enumerate(LOGO):
            _safe(stdscr, 1 + i, logo_x, line,
                  curses.color_pair(ORANGE) | curses.A_BOLD)

        title = 'N e X i S   H y p e r v i s o r'
        _safe(stdscr, 2, max(0, logo_x + len(LOGO[0]) + 2), title,
              curses.color_pair(ORANGE) | curses.A_BOLD)
        subtitle = 'Neural Execution and Cross-device Inference System'
        _safe(stdscr, 3, max(0, logo_x + len(LOGO[0]) + 2), subtitle,
              curses.color_pair(DIM))

        sep_y = 1 + len(LOGO) + 1
        _hline(stdscr, sep_y, W)

        # ── Status ────────────────────────────────────────────────────────────
        phrase  = _PHRASES[phrase_idx % len(_PHRASES)]
        ip      = _get_ip()
        hn      = _run('hostname') or 'nexis-node'
        mu, mt  = _get_mem()
        du, dt, dp = _get_disk()
        vms     = _get_vms()
        cts     = _get_containers()
        nexis   = _get_nexis_status()
        uptime  = _get_uptime()

        sy = sep_y + 1
        _safe(stdscr, sy,     2, phrase, curses.color_pair(ORANGE))
        _safe(stdscr, sy,     W - len(hn) - 8, f'NODE: {hn}',
              curses.color_pair(DIM))
        _safe(stdscr, sy + 1, 2,
              f'IP: {ip}   MEM: {mu}/{mt} MB   DISK: {du}/{dt} GB ({dp}%)   UP: {uptime}',
              curses.color_pair(DIM))
        nexis_col = GREEN if nexis == 'ONLINE' else RED
        _safe(stdscr, sy + 2, 2, f'NEXIS DAEMON: ', curses.color_pair(DIM))
        _safe(stdscr, sy + 2, 16, nexis, curses.color_pair(nexis_col) | curses.A_BOLD)
        _safe(stdscr, sy + 2, 16 + len(nexis),
              f'   ·   {vms} VM{"S" if vms != 1 else ""} ACTIVE   ·   '
              f'{cts} CONTAINER{"S" if cts != 1 else ""} ACTIVE',
              curses.color_pair(WHITE))
        _hline(stdscr, sy + 3, W)

        # ── Menu ──────────────────────────────────────────────────────────────
        my = sy + 5
        for key, label in items:
            _safe(stdscr, my, 6,  f'[{key}]',
                  curses.color_pair(ORANGE) | curses.A_BOLD)
            _safe(stdscr, my, 11, label, curses.color_pair(WHITE))
            my += 1

        # ── Web UI URL ────────────────────────────────────────────────────────
        url_y = sy + 5 + len(items) + 1
        _hline(stdscr, url_y, W)
        url = f'https://{ip}:8443'
        msg = f'Web Interface  →  {url}'
        _safe(stdscr, url_y + 1, max(2, (W - len(msg)) // 2), msg,
              curses.color_pair(ORANGE))

        stdscr.refresh()
        stdscr.timeout(20000)
        k = stdscr.getch()

        if k == ord('1'):   screen_node_info(stdscr, H, W)
        elif k == ord('2'): screen_network(stdscr, H, W)
        elif k == ord('3'): screen_services(stdscr, H, W)
        elif k == ord('4'): screen_logs(stdscr, H, W)
        elif k == ord('5'): screen_password(stdscr, H, W)
        elif k == ord('0'): break
        elif k == -1:       phrase_idx += 1  # rotate phrase on timeout


if __name__ == '__main__':
    os.environ.setdefault('TERM', 'linux')
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass

    # Dropped to shell
    print('\033[38;5;208m')
    print('  THE EYE BLINKS.')
    print('  You have exited the NeXiS shell.')
    print("  Type 'nexis' to return.")
    print('\033[0m')
