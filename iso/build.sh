#!/usr/bin/env bash
# Nexis Hypervisor — Debian 12 ISO builder
# Requires: live-build, xorriso, syslinux-utils (run on Debian/Ubuntu)
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/.build"

_print() { printf '\033[38;5;208m[nexis-iso]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then _err "ISO build must be run as root (or in Docker)."; fi

command -v lb &>/dev/null || apt-get install -yq live-build 2>/dev/null

_print "Building Nexis Hypervisor ${VERSION} ISO..."
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ── Configure live-build ─────────────────────────────────────────────────────
lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --debian-installer live \
    --debian-installer-gui false \
    --apt-recommends false \
    --memtest none \
    --iso-application "Nexis Hypervisor ${VERSION}" \
    --iso-volume "NEXIS-HV-${VERSION}"

# ── Package list ─────────────────────────────────────────────────────────────
mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
# Virtualisation
qemu-kvm
libvirt-daemon-system
libvirt-clients
lxc
lxc-templates
# Web interface
novnc
websockify
# Python
python3
python3-pip
python3-venv
python3-dev
libvirt-dev
pkg-config
build-essential
# Networking
bridge-utils
nftables
# System utilities
curl
git
jq
htop
vim-tiny
sudo
openssh-server
ca-certificates
EOF

# ── Preseed ───────────────────────────────────────────────────────────────────
mkdir -p config/preseed
cp "$SCRIPT_DIR/config/preseed.cfg" config/preseed/nexis.cfg

# ── Build hooks ───────────────────────────────────────────────────────────────
mkdir -p config/hooks/live
cp "$SCRIPT_DIR/config/hooks/"*.hook.chroot config/hooks/live/ 2>/dev/null || true

# ── Copy installer scripts ────────────────────────────────────────────────────
mkdir -p config/includes.chroot/opt/nexis-installer
cp "$SCRIPT_DIR/../install.sh" config/includes.chroot/opt/nexis-installer/
chmod +x config/includes.chroot/opt/nexis-installer/install.sh

# ── First-boot service ────────────────────────────────────────────────────────
mkdir -p config/includes.chroot/etc/systemd/system
cat > config/includes.chroot/etc/systemd/system/nexis-firstboot.service << 'EOF'
[Unit]
Description=Nexis Hypervisor First Boot Installation
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/etc/nexis-hypervisor/.installed

[Service]
Type=oneshot
ExecStart=/opt/nexis-installer/install.sh
ExecStartPost=/usr/bin/touch /etc/nexis-hypervisor/.installed
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

mkdir -p config/hooks/live
cat > config/hooks/live/9999-enable-firstboot.hook.chroot << 'EOF'
#!/bin/sh
systemctl enable nexis-firstboot.service
EOF
chmod +x config/hooks/live/9999-enable-firstboot.hook.chroot

# ── Build ─────────────────────────────────────────────────────────────────────
_print "Running live-build (this takes a while)..."
lb build 2>&1 | tee "$OUTPUT_DIR/build.log"

# Find the built ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" | head -1)
if [[ -z "$ISO" ]]; then _err "ISO not found after build."; fi

mv "$ISO" "$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
SHA=$(sha256sum "$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO built: $OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
_ok "SHA256: $SHA"
_print "Done. Write to USB: dd if=nexis-hypervisor-${VERSION}-amd64.iso of=/dev/sdX bs=4M status=progress"
