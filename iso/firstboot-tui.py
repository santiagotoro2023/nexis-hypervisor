#!/usr/bin/env python3
"""
NeXiS Hypervisor — First-Boot Terminal Configuration
ESXi-style interactive configuration menu shown after installation.
Sets hostname, network (static IP or DHCP), NeXiS Controller URL,
and displays the access URL for the web UI.
"""
import curses
import subprocess
import json
import os
import sys
import re
from pathlib import Path

DATA_DIR   = Path('/etc/nexis-hypervisor')
CONFIG_FILE = DATA_DIR / 'config.json'
DONE_FILE  = DATA_DIR / '.firstboot-done'

ORANGE = None   # colour pair index — assigned in main()
WHITE  = None
DIM    = None
GREEN  = None
RED    = None


# ── Utilities ─────────────────────────────────────────────────────────────────

def _run(*cmd, capture=True):
    r = subprocess.run(list(cmd), capture_output=capture, text=True)
    return r.stdout.strip() if capture else r.returncode == 0

def _get_ip():
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except Exception:
        return '?.?.?.?'

def _get_hostname():
    return _run('hostname') or 'nexis-hv'

def _get_interfaces():
    try:
        out = _run('ip', '-o', 'link', 'show')
        ifaces = []
        for line in out.splitlines():
            m = re.match(r'\d+:\s+(\S+):', line)
            if m and m.group(1) not in ('lo',):
                ifaces.append(m.group(1))
        return ifaces or ['eth0']
    except Exception:
        return ['eth0']

def _set_hostname(name):
    _run('hostnamectl', 'set-hostname', name)

def _apply_static_ip(iface, ip, prefix, gateway, dns):
    conf = f"""[Match]
Name={iface}

[Network]
Address={ip}/{prefix}
Gateway={gateway}
DNS={dns}
"""
    path = f'/etc/systemd/network/10-nexis-{iface}.network'
    Path(path).write_text(conf)
    _run('systemctl', 'enable', 'systemd-networkd', capture=False)
    _run('systemctl', 'restart', 'systemd-networkd', capture=False)

def _save_config(controller_url=''):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    cfg = {}
    if CONFIG_FILE.exists():
        try:
            cfg = json.loads(CONFIG_FILE.read_text())
        except Exception:
            pass
    if controller_url:
        cfg['pending_controller_url'] = controller_url
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))


# ── Drawing helpers ───────────────────────────────────────────────────────────

def _border(win, title=''):
    win.box()
    if title:
        h, w = win.getmaxyx()
        label = f'  {title}  '
        win.addstr(0, max(2, (w - len(label)) // 2), label,
                   curses.color_pair(ORANGE) | curses.A_BOLD)

def _logo(stdscr, y, x):
    lines = [
        '    /\\     ',
        '   /  \\    ',
        '  / () \\   ',
        ' /______\\  ',
    ]
    for i, line in enumerate(lines):
        stdscr.addstr(y + i, x, line, curses.color_pair(ORANGE))

def _header(stdscr, W):
    stdscr.addstr(1, (W - 34) // 2,
                  'NeXiS Hypervisor  ·  Initial Configuration',
                  curses.color_pair(ORANGE) | curses.A_BOLD)
    stdscr.addstr(2, (W - 42) // 2,
                  'Neural Execution and Cross-device Inference System',
                  curses.color_pair(DIM))

def _footer(stdscr, H, W, msg='Tab/Enter: select   Esc: back   Q: reboot'):
    stdscr.addstr(H - 2, (W - len(msg)) // 2, msg, curses.color_pair(DIM))


# ── Input field ───────────────────────────────────────────────────────────────

def _input_field(win, y, x, width, label, default='', secret=False):
    win.addstr(y, x, f'{label}: ', curses.color_pair(WHITE))
    curses.echo()
    curses.curs_set(1)
    win.addstr(y, x + len(label) + 2, ' ' * width)
    win.move(y, x + len(label) + 2)
    val = ''
    if default:
        win.addstr(y, x + len(label) + 2, default, curses.color_pair(DIM))
    win.refresh()
    if secret:
        curses.noecho()
    try:
        raw = win.getstr(y, x + len(label) + 2, width)
        val = raw.decode('utf-8', 'replace').strip()
    except Exception:
        val = ''
    curses.noecho()
    curses.curs_set(0)
    return val or default


# ── Menu ──────────────────────────────────────────────────────────────────────

def _menu(win, items, current=0):
    h, w = win.getmaxyx()
    for i, item in enumerate(items):
        attr = curses.color_pair(ORANGE) | curses.A_BOLD if i == current else curses.color_pair(WHITE)
        prefix = '  >  ' if i == current else '     '
        win.addstr(2 + i, 2, prefix + item + ' ' * (w - len(item) - 7), attr)
    win.refresh()


# ── Screens ───────────────────────────────────────────────────────────────────

def screen_network(stdscr, H, W):
    win = curses.newwin(18, 60, (H - 18) // 2, (W - 60) // 2)
    _border(win, 'Network Configuration')
    ifaces = _get_interfaces()

    win.addstr(2, 2, 'Interface:', curses.color_pair(WHITE))
    for i, ifc in enumerate(ifaces):
        win.addstr(2 + i, 14, ifc, curses.color_pair(ORANGE) if i == 0 else curses.color_pair(DIM))
    iface = ifaces[0] if ifaces else 'eth0'

    win.addstr(4, 2, 'Mode:', curses.color_pair(WHITE))
    items = ['DHCP (automatic)', 'Static IP']
    selected = 0
    while True:
        for i, item in enumerate(items):
            attr = curses.color_pair(ORANGE) | curses.A_BOLD if i == selected else curses.color_pair(WHITE)
            win.addstr(5 + i, 4, ('* ' if i == selected else '  ') + item, attr)
        win.refresh()
        k = win.getch()
        if k == curses.KEY_UP and selected > 0:
            selected -= 1
        elif k == curses.KEY_DOWN and selected < len(items) - 1:
            selected += 1
        elif k in (10, 13, ord(' ')):
            break
        elif k == 27:
            return

    if selected == 1:
        ip  = _input_field(win, 8,  2, 20, 'IP Address   ', '192.168.1.10')
        pfx = _input_field(win, 9,  2, 4,  'Prefix length', '24')
        gw  = _input_field(win, 10, 2, 20, 'Gateway      ', '192.168.1.1')
        dns = _input_field(win, 11, 2, 20, 'DNS          ', '1.1.1.1')
        win.addstr(13, 2, 'Applying...', curses.color_pair(DIM))
        win.refresh()
        _apply_static_ip(iface, ip, pfx, gw, dns)
        win.addstr(13, 2, 'Static IP configured.         ', curses.color_pair(GREEN))
    else:
        win.addstr(8, 2, 'Using DHCP — no changes made.', curses.color_pair(DIM))
    win.addstr(15, 2, 'Press any key to continue...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_hostname(stdscr, H, W):
    win = curses.newwin(10, 50, (H - 10) // 2, (W - 50) // 2)
    _border(win, 'Hostname')
    current = _get_hostname()
    win.addstr(2, 2, f'Current: {current}', curses.color_pair(DIM))
    name = _input_field(win, 4, 2, 30, 'New hostname', current)
    if name and name != current:
        _set_hostname(name)
        win.addstr(6, 2, f'Hostname set to: {name}', curses.color_pair(GREEN))
    else:
        win.addstr(6, 2, 'No change.', curses.color_pair(DIM))
    win.addstr(8, 2, 'Press any key...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_controller(stdscr, H, W):
    win = curses.newwin(12, 60, (H - 12) // 2, (W - 60) // 2)
    _border(win, 'NeXiS Controller URL')
    win.addstr(2, 2,
               'Enter the URL of your NeXiS Controller.', curses.color_pair(DIM))
    win.addstr(3, 2,
               'The hypervisor will use it for SSO login.', curses.color_pair(DIM))
    url = _input_field(win, 5, 2, 40, 'Controller URL',
                       'https://192.168.1.x:8443')
    if url and url != 'https://192.168.1.x:8443':
        _save_config(controller_url=url)
        win.addstr(7, 2, 'URL saved.', curses.color_pair(GREEN))
    else:
        win.addstr(7, 2, 'Skipped.', curses.color_pair(DIM))
    win.addstr(9, 2, 'Press any key...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


def screen_info(stdscr, H, W):
    ip = _get_ip()
    hostname = _get_hostname()
    url = f'https://{ip}:8443'
    win = curses.newwin(14, 62, (H - 14) // 2, (W - 62) // 2)
    _border(win, 'Node Information')
    win.addstr(2,  2, f'Hostname : {hostname}',     curses.color_pair(WHITE))
    win.addstr(3,  2, f'IP       : {ip}',           curses.color_pair(WHITE))
    win.addstr(4,  2, f'Web UI   : {url}',          curses.color_pair(ORANGE) | curses.A_BOLD)
    win.addstr(6,  2, 'Default credentials:', curses.color_pair(DIM))
    win.addstr(7,  2, '  Username : creator',       curses.color_pair(WHITE))
    win.addstr(8,  2, '  Password : Asdf1234!',     curses.color_pair(WHITE))
    win.addstr(10, 2, 'Change password after first login.', curses.color_pair(DIM))
    win.addstr(12, 2, 'Press any key...', curses.color_pair(DIM))
    win.refresh()
    win.getch()


# ── Main loop ─────────────────────────────────────────────────────────────────

def main(stdscr):
    global ORANGE, WHITE, DIM, GREEN, RED

    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_YELLOW, -1)   # ORANGE (closest available)
    curses.init_pair(2, curses.COLOR_WHITE,  -1)   # WHITE
    curses.init_pair(3, curses.COLOR_BLACK + 8 if curses.COLORS >= 16 else curses.COLOR_BLACK, -1)  # DIM
    curses.init_pair(4, curses.COLOR_GREEN,  -1)   # GREEN
    curses.init_pair(5, curses.COLOR_RED,    -1)   # RED

    ORANGE = 1; WHITE = 2; DIM = 3; GREEN = 4; RED = 5
    curses.curs_set(0)
    curses.cbreak()
    stdscr.keypad(True)
    stdscr.clear()

    items = [
        'System Information',
        'Configure Network',
        'Set Hostname',
        'Set NeXiS Controller URL',
        'Reboot',
        'Exit to Shell',
    ]
    current = 0

    while True:
        H, W = stdscr.getmaxyx()
        stdscr.clear()

        # Header
        _header(stdscr, W)
        stdscr.addstr(3, (W - 36) // 2,
                      '─' * 36, curses.color_pair(DIM))

        # Menu box
        menu_h, menu_w = len(items) + 4, 44
        menu_y = (H - menu_h) // 2
        menu_x = (W - menu_w) // 2
        menu_win = curses.newwin(menu_h, menu_w, menu_y, menu_x)
        _border(menu_win, 'Main Menu')
        _menu(menu_win, items, current)

        # Status bar
        ip = _get_ip()
        stdscr.addstr(H - 3, 2,
                      f'Node IP: {ip}  |  Web UI: https://{ip}:8443',
                      curses.color_pair(DIM))
        _footer(stdscr, H, W)
        stdscr.refresh()

        k = stdscr.getch()
        if k == curses.KEY_UP and current > 0:
            current -= 1
        elif k == curses.KEY_DOWN and current < len(items) - 1:
            current += 1
        elif k in (10, 13):
            if current == 0:
                screen_info(stdscr, H, W)
            elif current == 1:
                screen_network(stdscr, H, W)
            elif current == 2:
                screen_hostname(stdscr, H, W)
            elif current == 3:
                screen_controller(stdscr, H, W)
            elif current == 4:
                subprocess.run(['reboot'])
                break
            elif current == 5:
                DONE_FILE.touch()
                break
        elif k in (ord('q'), ord('Q')):
            DONE_FILE.touch()
            break


if __name__ == '__main__':
    if os.geteuid() != 0:
        print('NeXiS first-boot TUI must run as root.', file=sys.stderr)
        sys.exit(1)
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
