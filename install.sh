#!/usr/bin/env bash
# Nexis Hypervisor — Direct installer for Debian 12 (Bookworm)
# Run as root: curl -sSL <url>/install.sh | sudo bash
set -euo pipefail

VERSION="1.0.0"
INSTALL_DIR="/opt/nexis-hypervisor"
DATA_DIR="/etc/nexis-hypervisor"
REPO="https://github.com/santiagotoro2023/nexis-hypervisor"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then _err "This installer must be run as root."; fi
if ! grep -q 'bookworm\|12' /etc/os-release 2>/dev/null; then
    _print "Warning: This installer is designed for Debian 12. Proceeding anyway."
fi

_print "Nexis Hypervisor ${VERSION} — Installation Sequence"
echo ""

# ── 1. System packages ──────────────────────────────────────────────────────
_print "Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -yq \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    lxc \
    python3 python3-pip python3-venv python3-dev \
    libvirt-dev pkg-config build-essential \
    novnc websockify \
    curl git jq \
    2>/dev/null
_ok "System packages installed"

# ── 2. Enable libvirt ────────────────────────────────────────────────────────
systemctl enable --now libvirtd 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true
virsh net-start default 2>/dev/null || true
_ok "Virtualisation layer active"

# ── 3. Clone / update repo ───────────────────────────────────────────────────
_print "Fetching Nexis Hypervisor ${VERSION}..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" pull --quiet
else
    git clone --quiet --depth 1 "$REPO" "$INSTALL_DIR"
fi
_ok "Source fetched"

# ── 4. Python venv + dependencies ───────────────────────────────────────────
_print "Setting up Python environment..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/daemon/requirements.txt"
_ok "Python environment ready"

# ── 5. Build web UI ──────────────────────────────────────────────────────────
_print "Building web interface..."
if command -v node &>/dev/null; then
    cd "$INSTALL_DIR/web"
    npm install --silent
    npm run build --silent
    _ok "Web interface built"
else
    _print "Node.js not found — installing via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - -s -- -y 2>/dev/null
    apt-get install -yq nodejs 2>/dev/null
    cd "$INSTALL_DIR/web"
    npm install --silent
    npm run build --silent
    _ok "Web interface built"
fi

# ── 6. Data directory ────────────────────────────────────────────────────────
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
_ok "Data directory created at $DATA_DIR"

# ── 7. systemd service ───────────────────────────────────────────────────────
_print "Installing systemd service..."
cp "$INSTALL_DIR/nexis-hypervisor.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable nexis-hypervisor
systemctl restart nexis-hypervisor
_ok "Service installed and started"

# ── 8. Firewall ──────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    ufw allow 8443/tcp comment 'Nexis Hypervisor' 2>/dev/null || true
    _ok "Firewall rule added (port 8443)"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
_print "Installation complete."
echo ""
printf '\033[38;5;208m  Access URL:\033[0m  https://%s:8443\n' "$HOST_IP"
printf '\033[38;5;208m  First run:\033[0m   Complete the setup wizard in your browser.\n'
printf '\033[38;5;208m  Logs:\033[0m        journalctl -u nexis-hypervisor -f\n'
echo ""
