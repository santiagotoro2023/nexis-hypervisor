#!/usr/bin/env bash
# NeXiS Hypervisor — Installer
# Supported: Debian 12 (Bookworm) · x86_64 · root required
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/install-nexis-hypervisor.sh | sudo bash
#   — or —
#   git clone https://github.com/santiagotoro2023/nexis-hypervisor && sudo bash nexis-hypervisor/install-nexis-hypervisor.sh
set -euo pipefail

INSTALL_DIR="/opt/nexis-hypervisor"
DATA_DIR="/etc/nexis-hypervisor"
REPO="https://github.com/santiagotoro2023/nexis-hypervisor"
SERVICE="nexis-hypervisor-daemon"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m     ✓\033[0m %s\n'   "$1"; }
_err()   { printf '\033[38;5;196m     ✗\033[0m %s\n'  "$1" >&2; exit 1; }
_sep()   { printf '\033[38;5;237m%s\033[0m\n' "────────────────────────────────────────"; }

[[ $EUID -ne 0 ]] && _err "Run as root (sudo bash install-nexis-hypervisor.sh)"
grep -qi 'bookworm\|debian.*12\|12.*debian' /etc/os-release 2>/dev/null \
    || _print "Warning: designed for Debian 12. Proceeding anyway."

printf '\033[38;5;208m\n  NeXiS Hypervisor — Installation\033[0m\n\n'
_sep

# ── 1. System packages ────────────────────────────────────────────────────────
_print "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -yq \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    lxc \
    python3 python3-pip python3-venv python3-dev \
    libvirt-dev pkg-config build-essential \
    novnc websockify \
    curl git \
    2>/dev/null
_ok "System packages installed"

# ── 2. Virtualisation layer ───────────────────────────────────────────────────
_print "Starting virtualisation layer..."
systemctl enable --now libvirtd 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true
virsh net-start default     2>/dev/null || true
_ok "libvirtd active"

# ── 3. Source ─────────────────────────────────────────────────────────────────
_print "Fetching source..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" pull --quiet
    _ok "Repository updated"
else
    git clone --quiet --depth 1 "$REPO" "$INSTALL_DIR"
    _ok "Repository cloned"
fi

# ── 4. Python environment ─────────────────────────────────────────────────────
_print "Setting up Python environment..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/daemon/requirements.txt"
_ok "Python environment ready"

# ── 5. Web interface ──────────────────────────────────────────────────────────
_print "Building web interface..."
if ! command -v node &>/dev/null; then
    _print "Node.js not found — installing via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null
    apt-get install -yq nodejs 2>/dev/null
fi
( cd "$INSTALL_DIR/web" && npm ci --silent && npm run build --silent )
_ok "Web interface built"

# ── 6. Data directory ─────────────────────────────────────────────────────────
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
_ok "Data directory: $DATA_DIR"

# ── 7. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    ufw allow 8443/tcp comment 'NeXiS Hypervisor' 2>/dev/null || true
    _ok "Firewall: port 8443 permitted"
fi

# ── 8. Systemd service ────────────────────────────────────────────────────────
_print "Installing service..."
# Migrate from old unit name if present
systemctl stop nexis-hypervisor 2>/dev/null    || true
systemctl disable nexis-hypervisor 2>/dev/null  || true
rm -f /etc/systemd/system/nexis-hypervisor.service

cp "$INSTALL_DIR/nexis-hypervisor-daemon.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
_ok "Service started: $SERVICE"

# ── Done ──────────────────────────────────────────────────────────────────────
HOST_IP=$(hostname -I | awk '{print $1}')
_sep
printf '\n'
printf '\033[38;5;208m  Access:\033[0m        https://%s:8443\n'  "$HOST_IP"
printf '\033[38;5;208m  First login:\033[0m   creator / Asdf1234!  ← change immediately\n'
printf '\033[38;5;208m  Logs:\033[0m          journalctl -u %s -f\n' "$SERVICE"
printf '\n'
