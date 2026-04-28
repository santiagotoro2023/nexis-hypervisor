#!/bin/bash
# NeXiS Hypervisor — Debian first-boot installer
# Runs once on first boot via nexis-install.service.
# Primary path: download + install the latest .deb from GitHub releases.
# Fallback path: git clone + Python venv (no npm build required).

LOG=/var/log/nexis-install.log
INSTALL_DIR="/opt/nexis-hypervisor"
SENTINEL="/opt/nexis-hypervisor/.installed"
REPO="santiagotoro2023/nexis-hypervisor"

exec >> "$LOG" 2>&1

_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"; }
_log "=== NeXiS Hypervisor first-boot installation ==="

export DEBIAN_FRONTEND=noninteractive

# ── 1. Wait for network (up to 90 s) ─────────────────────────────────────────

_log "Waiting for network..."
_w=0
while ! ip route get 1.1.1.1 >/dev/null 2>&1; do
    [ $_w -ge 90 ] && { _log "WARNING: no network after 90s — continuing offline"; break; }
    sleep 3; _w=$((_w + 3))
done
_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "?.?.?.?")
_log "Network: $_IP"

# ── 2. System packages ────────────────────────────────────────────────────────

_log "Installing system packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils \
    libvirt-daemon-system libvirt-clients \
    lxc \
    novnc \
    python3 python3-pip python3-venv python3-libvirt \
    git curl jq \
    bridge-utils \
    nftables \
    ca-certificates \
    python3-dev pkg-config libvirt-dev

# ── 3. Enable virtualisation ──────────────────────────────────────────────────

_log "Enabling libvirtd and nftables..."
systemctl enable  libvirtd  2>/dev/null || true
systemctl start   libvirtd  2>/dev/null || true
systemctl enable  nftables  2>/dev/null || true

# ── 4. Install NeXiS daemon (deb preferred, git fallback) ────────────────────

_log "Checking GitHub for latest release .deb..."
REL=$(curl -fsSL --max-time 20 \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)
DEB_URL=$(printf '%s' "$REL" | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin).get('assets', []):
        if a['name'].endswith('.deb'):
            print(a['browser_download_url']); break
except: pass
" 2>/dev/null || true)

if [ -n "$DEB_URL" ]; then
    _log "Installing from release: $(basename "$DEB_URL")"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fsSL --max-time 300 "$DEB_URL" -o "$tmpdir/nexis.deb"
    dpkg -i "$tmpdir/nexis.deb"
    _log "Package installed from GitHub release"
else
    _log "No release .deb found — falling back to git clone"
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" pull --quiet || true
    else
        git clone --quiet --depth 1 "https://github.com/${REPO}" "$INSTALL_DIR"
    fi

    _log "Setting up Python venv..."
    python3 -m venv --system-site-packages "$INSTALL_DIR/venv"
    "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install --quiet \
        -r "$INSTALL_DIR/daemon/requirements.txt" 2>/dev/null \
    || "$INSTALL_DIR/venv/bin/pip" install --quiet \
        -r "$INSTALL_DIR/daemon/requirements.txt" --ignore-installed libvirt-python \
    || true

    _log "Installing nexis-hypervisor systemd service..."
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
    systemctl daemon-reload
    systemctl enable nexis-hypervisor
fi

# ── 5. Data directory ─────────────────────────────────────────────────────────

mkdir -p /etc/nexis-hypervisor
chmod 700 /etc/nexis-hypervisor

# ── 6. Firewall — accept SSH + web UI, drop everything else ──────────────────

_log "Configuring nftables firewall..."
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/nexis.nft << 'NFT'
table inet nexis {
    chain input {
        type filter hook input priority 0;
        ct state established,related accept
        iifname lo accept
        tcp dport { 22, 8443 } accept
        drop
    }
}
NFT
systemctl restart nftables 2>/dev/null || true

# ── 7. Start daemon ───────────────────────────────────────────────────────────

_log "Starting NeXiS Hypervisor daemon..."
systemctl start nexis-hypervisor 2>/dev/null || true

# ── 8. Mark installation complete (sentinel) ──────────────────────────────────
# Written last so a partial run is detected and retried on next boot.

mkdir -p "$(dirname "$SENTINEL")"
touch "$SENTINEL"

_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "?.?.?.?")
_log "=== Installation complete === Web UI: https://${_IP}:8443"
_log "Default login: creator / Asdf1234!"
