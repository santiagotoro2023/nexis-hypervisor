#!/bin/bash
# NeXiS Hypervisor — Debian first-boot package installer
# Runs once via nexis-install.service on first boot.
# Installs QEMU/KVM, LXC, libvirt, Python stack, and the NeXiS daemon + web UI.
set -e
LOG=/var/log/nexis-install.log

_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" | tee -a "$LOG"; }
_run() { "$@" >> "$LOG" 2>&1; }

_log "=== NeXiS Hypervisor Installation ==="
_log "Debian 12 base detected — using apt"

export DEBIAN_FRONTEND=noninteractive

# ── 1. System packages ────────────────────────────────────────────────────────

_log "Installing virtualisation packages..."
_run apt-get update -qq
_run apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils \
    libvirt-daemon-system libvirt-clients \
    lxc \
    novnc \
    python3 python3-pip python3-venv python3-libvirt \
    nodejs npm \
    git curl jq \
    bridge-utils \
    nftables \
    ca-certificates \
    build-essential \
    python3-dev \
    pkg-config \
    libvirt-dev

# ── 2. Enable and start virtualisation ───────────────────────────────────────

_log "Enabling libvirt..."
_run systemctl enable  libvirtd  || true
_run systemctl start   libvirtd  || true
_run systemctl enable  nftables  || true

# ── 3. Clone NeXiS Hypervisor ────────────────────────────────────────────────

INSTALL_DIR="/opt/nexis-hypervisor"
_log "Fetching NeXiS Hypervisor source..."
if [ -d "$INSTALL_DIR/.git" ]; then
    _run git -C "$INSTALL_DIR" pull --quiet
else
    _run git clone --quiet --depth 1 \
        https://github.com/santiagotoro2023/nexis-hypervisor \
        "$INSTALL_DIR"
fi

# ── 4. Python venv + daemon dependencies ─────────────────────────────────────

_log "Setting up Python environment..."
python3 -m venv --system-site-packages "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet \
    -r "$INSTALL_DIR/daemon/requirements.txt" \
    --ignore-installed libvirt-python || \
"$INSTALL_DIR/venv/bin/pip" install --quiet \
    -r "$INSTALL_DIR/daemon/requirements.txt"

# ── 5. Build web UI ──────────────────────────────────────────────────────────

_log "Building web interface..."
( cd "$INSTALL_DIR/web" && npm install --silent && npm run build --silent ) >> "$LOG" 2>&1

# ── 6. Data directory ─────────────────────────────────────────────────────────

_log "Creating data directory..."
mkdir -p /etc/nexis-hypervisor
chmod 700 /etc/nexis-hypervisor

# ── 7. systemd service for the NeXiS daemon ──────────────────────────────────

_log "Installing NeXiS daemon service..."
cat > /etc/systemd/system/nexis-hypervisor.service << 'SVC'
[Unit]
Description=NeXiS Hypervisor Daemon
After=network-online.target libvirtd.service
Wants=network-online.target
Requires=libvirtd.service

[Service]
Type=simple
WorkingDirectory=/opt/nexis-hypervisor/daemon
ExecStart=/opt/nexis-hypervisor/venv/bin/python3 /opt/nexis-hypervisor/daemon/main.py
Restart=on-failure
RestartSec=5
Environment=NEXIS_DATA=/etc/nexis-hypervisor
Environment=NEXIS_PORT=8443
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC
_run systemctl daemon-reload
_run systemctl enable nexis-hypervisor

# ── 8. Firewall — allow ports 22 and 8443 ────────────────────────────────────

_log "Configuring nftables firewall..."
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/nexis.nft << 'NFT'
table inet nexis {
    chain input {
        type filter hook input priority 0;
        ct state established,related accept
        iifname lo accept
        tcp dport {22, 8443} accept
        drop
    }
}
NFT
_run systemctl restart nftables || true

# ── 9. NeXiS management shell ─────────────────────────────────────────────────

_log "Installing NeXiS management shell..."
SHELL_SRC=""
for p in \
    /media/cdrom/nexis/nexis-shell.py \
    /media/usb/nexis/nexis-shell.py \
    /opt/nexis-hypervisor/iso/nexis-shell.py
do
    [ -f "$p" ] && { SHELL_SRC="$p"; break; }
done

if [ -n "$SHELL_SRC" ]; then
    cp "$SHELL_SRC" /usr/local/bin/nexis-shell
else
    curl -fsSL \
        https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/iso/nexis-shell.py \
        -o /usr/local/bin/nexis-shell >> "$LOG" 2>&1 || true
fi
chmod +x /usr/local/bin/nexis-shell
ln -sf /usr/local/bin/nexis-shell /usr/local/bin/nexis

_log "NeXiS shell installed"

# ── 10. Start daemon ──────────────────────────────────────────────────────────

_log "Starting NeXiS Hypervisor daemon..."
_run systemctl start nexis-hypervisor || true

IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "?.?.?.?")
_log "=== Installation complete ==="
_log "Web UI: https://${IP}:8443"
_log "Default login: creator / Asdf1234!"
