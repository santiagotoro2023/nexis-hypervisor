#!/usr/bin/env python3
"""
NeXiS Hypervisor — Management Shell
Runs on TTY1 after installation. Debian 12 / systemd.
"""
import curses
import subprocess
import os
import time
import socket
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

SERVICES = [
    ('nexis-hypervisor', 'NeXiS Daemon'),
    ('libvirtd',         'QEMU/KVM'),
    ('ssh',              'SSH Server'),
    ('systemd-networkd', 'Networking'),
    ('chrony',           'NTP Sync'),
    ('nftables',         'Firewall'),
]


# ── System helpers ─────────────────────────────────────────────────────────────

def _run(*cmd):
    try:
        return subprocess.check_output(list(cmd), stderr=subprocess.DEVNULL,
                                       text=True).strip()
    except Exception:
        return ''

def _run_rc(*cmd):
    try:
        r = subprocess.run(list(cmd), capture_output=True, text=True)
        return r.returncode, (r.stdout + r.stderr).strip()
    except Exception as e:
        return 1, str(e)

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
        idle = b[3] - a[3]; total = sum(b) - sum(a)
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
                       if l.strip() and not l.strip().startswith('Id') and '---' not in l]))

def _get_containers():
    out = _run('lxc-ls', '--running')
    return len(out.split()) if out else 0

def _svc_active(unit):
    return _run('systemctl', 'is-active', unit) == 'active'

def _svc_enabled(unit):
    return _run('systemctl', 'is-enabled', unit) in ('enabled', 'static')

def _get_nexis_status():
    return 'ONLINE' if _svc_active('nexis-hypervisor') else 'OFFLINE'

def _get_uptime():
    try:
        secs = float(open('/proc/uptime').read().split()[0])
        h, m = int(secs // 3600), int((secs % 3600) // 60)
        return f'{h}h {m}m'
    except Exception:
        return '?'

def _minibar(used, total, width=16):
    if total == 0:
        return '[' + '-' * width + ']'
    filled = int(min(1.0, used / total) * width)
    return '[' + '#' * filled + '-' * (width - filled) + ']'


# ── Drawing helpers ────────────────────────────────────────────────────────────

def _safe(win, y, x, s, attr=0):
    try:
        win.addstr(y, x, str(s), attr)
    except curses.error:
        pass

def _hline(win, y, W, ch='─'):
    _safe(win, y, 2, ch * max(0, W - 4), curses.color_pair(DIM))

def _border(win, title=''):
    win.box()
    if title:
        _, w = win.getmaxyx()
        label = f'  {title}  '
        _safe(win, 0, max(2, (w - len(label)) // 2), label,
              curses.color_pair(ORANGE) | curses.A_BOLD)


# ── Secret input (char-by-char, ESC cancels) ───────────────────────────────────

def _read_secret(win, y, x, maxlen=64):
    """Return typed string, or None if ESC pressed."""
    buf = []
    curses.curs_set(1)
    win.move(y, x)
    win.refresh()
    while True:
        ch = win.getch()
        if ch == 27:
            curses.curs_set(0)
            return None
        elif ch in (10, 13):
            curses.curs_set(0)
            return ''.join(buf)
        elif ch in (127, curses.KEY_BACKSPACE, 8):
            if buf:
                buf.pop()
                _safe(win, y, x + len(buf), ' ', curses.color_pair(WHITE))
                win.move(y, x + len(buf))
                win.refresh()
        elif 32 <= ch < 127 and len(buf) < maxlen:
            buf.append(chr(ch))
            _safe(win, y, x + len(buf) - 1, '*', curses.color_pair(WHITE))
            win.move(y, x + len(buf))
            win.refresh()


# ── Screens ────────────────────────────────────────────────────────────────────

def screen_node_info(stdscr, H, W):
    ip         = _get_ip()
    hostname   = _run('hostname') or 'nexis-node'
    cpu        = _get_cpu()
    mu, mt     = _get_mem()
    du, dt, dp = _get_disk()
    vms        = _get_vms()
    cts        = _get_containers()
    nexis      = _get_nexis_status()
    uptime     = _get_uptime()
    kernel     = _run('uname', '-r')

    win_h, win_w = 20, 64
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _border(win, 'NODE INFORMATION')

    rows = [
        ('HOSTNAME',          hostname),
        ('IP ADDRESS',        ip),
        ('WEB INTERFACE',     f'https://{ip}:8443'),
        ('UPTIME',            uptime),
        ('KERNEL',            kernel),
        ('CPU',               f'{cpu}%  {_minibar(cpu, 100)}'),
        ('MEMORY',            f'{mu}/{mt} MB  {_minibar(mu, mt)}'),
        ('DISK',              f'{du}/{dt} GB ({dp}%)  {_minibar(du, dt)}'),
        ('VMs ACTIVE',        str(vms)),
        ('CONTAINERS ACTIVE', str(cts)),
        ('NEXIS DAEMON',      nexis),
    ]
    for i, (k, v) in enumerate(rows):
        _safe(win, 2 + i, 3, f'{k:<22}', curses.color_pair(DIM))
        col = GREEN if v == 'ONLINE' else (RED if v == 'OFFLINE' else WHITE)
        _safe(win, 2 + i, 26, v, curses.color_pair(col))

    _safe(win, win_h - 2, 3, 'Press any key to return...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_network(stdscr, H, W):
    ip    = _get_ip()
    addrs = _run('ip', '-o', 'addr', 'show').splitlines()

    win_h, win_w = 18, 68
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    _border(win, 'NETWORK CONFIGURATION')
    _safe(win, 2, 3, f'Management IP:  {ip}', curses.color_pair(ORANGE) | curses.A_BOLD)
    _safe(win, 3, 3, '─' * (win_w - 6), curses.color_pair(DIM))
    _safe(win, 4, 3, f'{"INTERFACE":<14}  {"ADDRESS":<24}  SCOPE', curses.color_pair(DIM))

    row = 5
    for line in addrs[:10]:
        parts = line.split()
        if len(parts) >= 4:
            iface = parts[1].rstrip(':')
            addr  = parts[3]
            scope = parts[-1] if len(parts) > 4 else ''
            _safe(win, row, 3, f'{iface:<14}  {addr:<24}  {scope[:14]}',
                  curses.color_pair(WHITE))
            row += 1
        if row >= win_h - 3:
            break

    _safe(win, win_h - 2, 3, 'Press any key to return...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_services(stdscr, H, W):
    sel = 0
    msg = ''
    msg_col = DIM

    while True:
        n = len(SERVICES)
        win_h = n + 10
        win_w = 66
        win = curses.newwin(win_h, win_w, max(0, (H - win_h) // 2), max(0, (W - win_w) // 2))
        win.erase()
        _border(win, 'NEXIS SERVICES')
        win.keypad(True)

        _safe(win, 1, 3, f'  {"SERVICE":<20}  {"STATUS":<10}  BOOT',
              curses.color_pair(DIM))
        _safe(win, 2, 3, '─' * (win_w - 6), curses.color_pair(DIM))

        for i, (unit, label) in enumerate(SERVICES):
            active  = _svc_active(unit)
            enabled = _svc_enabled(unit)
            is_sel  = (i == sel)
            rev     = curses.A_REVERSE if is_sel else 0
            sta_col = GREEN if active else RED
            en_col  = GREEN if enabled else RED
            dot     = '●' if active else '○'
            sta     = 'ACTIVE  ' if active else 'INACTIVE'
            en_str  = 'AUTO' if enabled else 'OFF '

            _safe(win, 3 + i, 3,  dot,             curses.color_pair(sta_col) | rev)
            _safe(win, 3 + i, 5,  f'{label:<20}',  curses.color_pair(WHITE)   | rev)
            _safe(win, 3 + i, 26, f'{sta:<10}',    curses.color_pair(sta_col) | rev)
            _safe(win, 3 + i, 37, f'{en_str}',     curses.color_pair(en_col)  | rev)

        sep = 3 + n + 1
        _safe(win, sep,     3, '─' * (win_w - 6),                       curses.color_pair(DIM))
        _safe(win, sep + 1, 3, '[S] Start  [T] Stop  [R] Restart',      curses.color_pair(ORANGE) | curses.A_BOLD)
        _safe(win, sep + 2, 3, '[E] Enable at boot  [D] Disable',       curses.color_pair(ORANGE) | curses.A_BOLD)
        _safe(win, sep + 3, 3, '↑↓ navigate   ESC / Q  back',           curses.color_pair(DIM))

        if msg:
            _safe(win, sep + 4, 3, f'▸ {msg[:win_w-7]}', curses.color_pair(msg_col))

        win.refresh()
        k = win.getch()
        msg = ''

        if k in (27, ord('q'), ord('Q')):
            break
        elif k == curses.KEY_UP:
            sel = (sel - 1) % n
        elif k == curses.KEY_DOWN:
            sel = (sel + 1) % n
        else:
            unit = SERVICES[sel][0]
            if k in (ord('s'), ord('S')):
                rc, out = _run_rc('systemctl', 'start', unit)
                msg = f'start {unit}: {"ok" if rc == 0 else out[:48]}'
                msg_col = GREEN if rc == 0 else RED
            elif k in (ord('t'), ord('T')):
                rc, out = _run_rc('systemctl', 'stop', unit)
                msg = f'stop {unit}: {"ok" if rc == 0 else out[:48]}'
                msg_col = GREEN if rc == 0 else RED
            elif k in (ord('r'), ord('R')):
                rc, out = _run_rc('systemctl', 'restart', unit)
                msg = f'restart {unit}: {"ok" if rc == 0 else out[:48]}'
                msg_col = GREEN if rc == 0 else RED
            elif k in (ord('e'), ord('E')):
                rc, out = _run_rc('systemctl', 'enable', unit)
                msg = f'enable {unit}: {"ok" if rc == 0 else out[:48]}'
                msg_col = GREEN if rc == 0 else RED
            elif k in (ord('d'), ord('D')):
                rc, out = _run_rc('systemctl', 'disable', unit)
                msg = f'disable {unit}: {"ok" if rc == 0 else out[:48]}'
                msg_col = GREEN if rc == 0 else RED


def screen_logs(stdscr, H, W):
    log_files = [
        '/var/log/nexis-hypervisor.log',
        '/var/log/nexis-install.log',
        '/var/log/syslog',
    ]

    while True:
        win_h = H - 4
        win_w = W - 4
        win = curses.newwin(win_h, win_w, 2, 2)
        win.keypad(True)
        _border(win, 'SYSTEM LOGS')

        log_content = []
        for lf in log_files:
            p = Path(lf)
            if p.exists():
                log_content.append(f'─── {lf} ───')
                log_content.extend(p.read_text(errors='replace').splitlines()[-40:])
                log_content.append('')

        offset  = max(0, len(log_content) - (win_h - 3))
        visible = log_content[offset:][:win_h - 3]
        for i, line in enumerate(visible):
            _safe(win, 1 + i, 1, line[:win_w - 2], curses.color_pair(DIM))

        _safe(win, win_h - 1, 3, 'R: refresh   ESC / Q: back', curses.color_pair(DIM))
        win.refresh()
        k = win.getch()
        if k not in (ord('r'), ord('R')):
            break


def screen_password(stdscr, H, W):
    win_h, win_w = 13, 56
    win = curses.newwin(win_h, win_w, (H - win_h) // 2, (W - win_w) // 2)
    win.keypad(True)

    while True:
        win.erase()
        _border(win, 'CHANGE ROOT PASSWORD')
        _safe(win, 2, 3, 'Min 8 characters.  ESC to cancel.',
              curses.color_pair(DIM))
        _safe(win, 4, 3, 'New password:     ', curses.color_pair(WHITE))
        _safe(win, 4, 21, ' ' * 24, curses.color_pair(WHITE))
        _safe(win, 5, 3, 'Confirm:          ', curses.color_pair(WHITE))
        _safe(win, 5, 21, ' ' * 24, curses.color_pair(WHITE))
        _safe(win, 7, 3, ' ' * (win_w - 6), 0)
        win.refresh()

        pw1 = _read_secret(win, 4, 21)
        if pw1 is None:
            return

        pw2 = _read_secret(win, 5, 21)
        if pw2 is None:
            return

        if len(pw1) < 8:
            _safe(win, 7, 3, 'Password must be at least 8 characters.',
                  curses.color_pair(RED))
            _safe(win, win_h - 2, 3, 'Press any key...', curses.color_pair(DIM))
            win.refresh(); win.getch()
            continue

        if pw1 != pw2:
            _safe(win, 7, 3, 'Passwords do not match.                 ',
                  curses.color_pair(RED))
            _safe(win, win_h - 2, 3, 'Press any key...', curses.color_pair(DIM))
            win.refresh(); win.getch()
            continue

        try:
            proc = subprocess.run(['chpasswd'], input=f'root:{pw1}\n',
                                  capture_output=True, text=True)
            if proc.returncode == 0:
                _safe(win, 7, 3, 'Password updated successfully.          ',
                      curses.color_pair(GREEN))
            else:
                _safe(win, 7, 3, f'Failed: {proc.stderr.strip()[:46]}',
                      curses.color_pair(RED))
        except Exception as e:
            _safe(win, 7, 3, f'Error: {str(e)[:48]}', curses.color_pair(RED))

        _safe(win, win_h - 2, 3, 'Press any key...', curses.color_pair(DIM))
        win.refresh(); win.getch()
        return


def screen_update(stdscr, H, W):
    win_h = H - 4
    win_w = W - 6
    win = curses.newwin(win_h, win_w, 2, 3)
    win.keypad(True)
    _border(win, 'SYSTEM UPDATE')
    _safe(win, 2, 3, 'Connecting to GitHub...', curses.color_pair(DIM))
    win.refresh()

    lines = []
    row = 3
    rc = 1
    try:
        proc = subprocess.Popen(
            ['nexis-update'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        for line in proc.stdout:
            line = line.rstrip()
            lines.append(line)
            if row < win_h - 4:
                col = GREEN if '  ok' in line else (RED if '  err' in line else DIM)
                _safe(win, row, 3, line[:win_w - 7], curses.color_pair(col))
                row += 1
            else:
                # Scroll: shift lines up, redraw
                for i in range(3, win_h - 4):
                    win.move(i, 3)
                    win.clrtoeol()
                visible = lines[-(win_h - 7):]
                for i, l in enumerate(visible):
                    col = GREEN if '  ok' in l else (RED if '  err' in l else DIM)
                    _safe(win, 3 + i, 3, l[:win_w - 7], curses.color_pair(col))
            win.refresh()
        proc.wait()
        rc = proc.returncode
    except FileNotFoundError:
        _safe(win, row, 3, 'nexis-update not found at /usr/local/bin/nexis-update',
              curses.color_pair(RED))
        row += 1

    result_col = GREEN if rc == 0 else RED
    result_msg = 'Update finished successfully.' if rc == 0 else f'Update failed (exit {rc}).'
    _safe(win, min(row + 1, win_h - 4), 3, result_msg,
          curses.color_pair(result_col) | curses.A_BOLD)
    _safe(win, win_h - 2, 3, 'Press any key to return...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_confirm_reboot(stdscr, H, W):
    win = curses.newwin(5, 40, H // 2 - 2, W // 2 - 20)
    win.keypad(True)
    _border(win, 'CONFIRM REBOOT')
    _safe(win, 2, 3, 'Reboot the system now?   [Y] / [N]',
          curses.color_pair(ORANGE))
    win.refresh()
    k = win.getch()
    if k in (ord('y'), ord('Y')):
        os.system('reboot')


# ── Main loop ──────────────────────────────────────────────────────────────────

def main(stdscr):
    global ORANGE, WHITE, DIM, GREEN, RED

    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, curses.COLOR_WHITE,  -1)
    curses.init_pair(3, (curses.COLOR_BLACK + 8) if curses.COLORS >= 16
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
        ('U', 'UPDATE SYSTEM'),
        ('R', 'REBOOT'),
        ('0', 'ACCESS LINUX SHELL'),
    ]

    while True:
        stdscr.erase()
        H, W = stdscr.getmaxyx()

        # ── Logo + title ──────────────────────────────────────────────────────
        lx = 4
        for i, line in enumerate(LOGO):
            _safe(stdscr, 1 + i, lx, line, curses.color_pair(ORANGE) | curses.A_BOLD)
        tx = lx + len(LOGO[0]) + 2
        _safe(stdscr, 2, tx, 'N e X i S   H y p e r v i s o r',
              curses.color_pair(ORANGE) | curses.A_BOLD)
        _safe(stdscr, 3, tx, 'Neural Execution and Cross-device Inference System',
              curses.color_pair(DIM))

        sep_y = 6
        _hline(stdscr, sep_y, W)

        # ── Status ────────────────────────────────────────────────────────────
        phrase     = _PHRASES[phrase_idx % len(_PHRASES)]
        ip         = _get_ip()
        hn         = _run('hostname') or 'nexis-node'
        mu, mt     = _get_mem()
        du, dt, dp = _get_disk()
        vms        = _get_vms()
        cts        = _get_containers()
        nexis      = _get_nexis_status()
        uptime     = _get_uptime()

        sy = sep_y + 1
        _safe(stdscr, sy,     2, phrase,                    curses.color_pair(ORANGE))
        _safe(stdscr, sy,     W - len(hn) - 8, f'NODE: {hn}', curses.color_pair(DIM))
        _safe(stdscr, sy + 1, 2,
              f'IP: {ip}   MEM: {mu}/{mt} MB {_minibar(mu,mt,12)}'
              f'   DISK: {du}/{dt} GB {_minibar(du,dt,12)}   UP: {uptime}',
              curses.color_pair(DIM))
        ncol = GREEN if nexis == 'ONLINE' else RED
        _safe(stdscr, sy + 2, 2,  'NEXIS: ',  curses.color_pair(DIM))
        _safe(stdscr, sy + 2, 9,  f'{nexis}', curses.color_pair(ncol) | curses.A_BOLD)
        _safe(stdscr, sy + 2, 9 + len(nexis),
              f'   ·   {vms} VM{"S" if vms != 1 else ""}   ·   '
              f'{cts} CONTAINER{"S" if cts != 1 else ""}',
              curses.color_pair(WHITE))
        _hline(stdscr, sy + 3, W)

        # ── Menu (left column) ────────────────────────────────────────────────
        my = sy + 5
        for key, label in items:
            _safe(stdscr, my, 4,  f'[{key}]', curses.color_pair(ORANGE) | curses.A_BOLD)
            _safe(stdscr, my, 9,  label,       curses.color_pair(WHITE))
            my += 1

        # ── Service sidebar (right column) ────────────────────────────────────
        sx = max(W // 2, 44)
        _safe(stdscr, sy + 4, sx, '  SERVICE STATUS', curses.color_pair(DIM) | curses.A_BOLD)
        _safe(stdscr, sy + 5, sx, '  ' + '─' * 28,   curses.color_pair(DIM))
        for i, (unit, label) in enumerate(SERVICES):
            active = _svc_active(unit)
            dot    = '●' if active else '○'
            col    = GREEN if active else RED
            sta    = 'ACTIVE  ' if active else 'INACTIVE'
            _safe(stdscr, sy + 6 + i, sx,      f'  {dot}', curses.color_pair(col))
            _safe(stdscr, sy + 6 + i, sx + 4,  f'{label:<18}', curses.color_pair(WHITE))
            _safe(stdscr, sy + 6 + i, sx + 23, sta,            curses.color_pair(col))

        # ── Footer ────────────────────────────────────────────────────────────
        _hline(stdscr, H - 2, W)
        url = f'https://{ip}:8443'
        _safe(stdscr, H - 1, 2, url, curses.color_pair(ORANGE))

        stdscr.refresh()
        stdscr.timeout(15000)
        k = stdscr.getch()

        if   k == ord('1'): screen_node_info(stdscr, H, W)
        elif k == ord('2'): screen_network(stdscr, H, W)
        elif k == ord('3'): screen_services(stdscr, H, W)
        elif k == ord('4'): screen_logs(stdscr, H, W)
        elif k == ord('5'): screen_password(stdscr, H, W)
        elif k in (ord('u'), ord('U')): screen_update(stdscr, H, W)
        elif k in (ord('r'), ord('R')): screen_confirm_reboot(stdscr, H, W)
        elif k == ord('0'): break
        elif k == -1: phrase_idx += 1


if __name__ == '__main__':
    import subprocess
    os.environ.setdefault('TERM', 'linux')
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
    print('\033[38;5;208m')
    print('  THE EYE BLINKS.')
    print('  You have exited the NeXiS shell.')
    print("  Type 'nexis' to return.")
    print('\033[0m')
