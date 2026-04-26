#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Produces a bootable ISO with:
#   - Custom GRUB boot menu  (NeXiS branding, installer-only)
#   - Calamares graphical installer  (dark bg, #F87200 orange, logo)
#   - Pre-installed NeXiS Hypervisor stack  (unpackfs — no downloads during install)
#   - Post-install firstboot TUI  (network / hostname / controller config)
#
# The web UI dist and daemon are copied from the CI checkout — no network
# access or nodejs/npm needed inside the chroot.
#
# Must run as root inside a Debian Bookworm environment (privileged container).
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/.build"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

_print() { printf '\033[38;5;208m[nexis-iso]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "ISO build must run as root."
command -v lb &>/dev/null || apt-get install -yq live-build 2>/dev/null

_print "NeXiS Hypervisor ${VERSION} — Building Calamares Installation ISO..."
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ── live-build base config ────────────────────────────────────────────────────

lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --apt-recommends false \
    --iso-application "NeXiS Hypervisor ${VERSION}" \
    --iso-volume "${ISO_VOLUME}"

# ── Package list ──────────────────────────────────────────────────────────────

mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
# Virtualisation
qemu-kvm
libvirt-daemon-system
libvirt-clients
lxc
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
# System
bridge-utils
nftables
openssh-server
curl
git
jq
htop
vim-tiny
sudo
ca-certificates
parted
# Calamares graphical installer
calamares
calamares-settings-debian
# Minimal X11 + window manager (removed from installed system post-install)
xorg
openbox
xinit
xterm
hsetroot
# SVG → PNG conversion for logo
librsvg2-bin
# Font
fonts-jetbrains-mono
EOF

# ── Stage NeXiS files via includes.chroot (no network in chroot) ─────────────
# The CI checkout already has daemon/ and web/dist/ ready.

NEXIS_CHROOT="config/includes.chroot/opt/nexis-hypervisor"
mkdir -p "${NEXIS_CHROOT}/web"
cp -r "$REPO_DIR/daemon"                "${NEXIS_CHROOT}/"
cp -r "$REPO_DIR/web/dist"             "${NEXIS_CHROOT}/web/"
cp    "$REPO_DIR/nexis-hypervisor.service" "${NEXIS_CHROOT}/"

# ── Stage systemd service
mkdir -p config/includes.chroot/etc/systemd/system
cp "$REPO_DIR/nexis-hypervisor.service" \
   config/includes.chroot/etc/systemd/system/nexis-hypervisor.service

# ── Stage firstboot TUI
mkdir -p config/includes.chroot/usr/local/bin
cp "$SCRIPT_DIR/firstboot-tui.py" \
   config/includes.chroot/usr/local/bin/nexis-firstboot
chmod +x config/includes.chroot/usr/local/bin/nexis-firstboot

# ── Stage Calamares branding + config
mkdir -p config/includes.chroot/usr/share/calamares/branding/nexis
cp "$SCRIPT_DIR/calamares/branding/nexis/"* \
   config/includes.chroot/usr/share/calamares/branding/nexis/

mkdir -p config/includes.chroot/etc/calamares/modules
cp "$SCRIPT_DIR/calamares/settings.conf" \
   config/includes.chroot/etc/calamares/settings.conf
cp "$SCRIPT_DIR/calamares/modules/"*.conf \
   config/includes.chroot/etc/calamares/modules/ 2>/dev/null || true

# ── Chroot hook: pip install + systemd services + Calamares auto-launch ───────

mkdir -p config/hooks/live
cat > config/hooks/live/0100-nexis-setup.hook.chroot << 'HOOK'
#!/usr/bin/env bash
set -euo pipefail

NEXIS_DIR="/opt/nexis-hypervisor"
NEXIS_DATA="/etc/nexis-hypervisor"

# Python venv + deps (no network for source/web — already staged)
echo "[nexis] Setting up Python environment..."
python3 -m venv "$NEXIS_DIR/venv"
"$NEXIS_DIR/venv/bin/pip" install -q --upgrade pip
"$NEXIS_DIR/venv/bin/pip" install -q -r "$NEXIS_DIR/daemon/requirements.txt"

# Data directory
mkdir -p "$NEXIS_DATA"
chmod 700 "$NEXIS_DATA"

# Enable NeXiS daemon
systemctl enable nexis-hypervisor 2>/dev/null || true

# Firstboot TUI service
cat > /etc/systemd/system/nexis-firstboot.service << 'SVC'
[Unit]
Description=NeXiS Hypervisor First-Boot Configuration
After=multi-user.target
ConditionPathExists=!/etc/nexis-hypervisor/.firstboot-done

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/nexis-firstboot
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
SVC
systemctl enable nexis-firstboot 2>/dev/null || true
systemctl enable libvirtd ssh 2>/dev/null || true

echo "[nexis] Converting SVG logo to PNG..."
if command -v rsvg-convert &>/dev/null; then
    rsvg-convert -w 128 -h 128 \
        /usr/share/calamares/branding/nexis/logo.svg \
        -o /usr/share/calamares/branding/nexis/logo.png
else
    # Fallback: generate a minimal orange/dark PNG via python3
    python3 - << 'PYEOF'
import struct, zlib
def _png(w, h, rows):
    def ch(t, d):
        c = zlib.crc32(t + d) & 0xffffffff
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', c)
    raw = b''.join(b'\x00' + r for r in rows)
    return (b'\x89PNG\r\n\x1a\n'
            + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(raw, 9))
            + ch(b'IEND', b''))
W = H = 128
OR = bytes([0xF8, 0x72, 0x00])
DK = bytes([0x08, 0x08, 0x07])
rows = []
for y in range(H):
    row = bytearray()
    for x in range(W):
        cx, cy = x - W//2, y - H//2
        # triangle: inside if above the two sides
        in_tri = (y > H*0.15 and y < H*0.85
                  and abs(cx) < (y - H*0.15) * 0.65)
        # eye circle
        in_eye = (cx*cx + (cy - H*0.15)*(cy - H*0.15)) < (H*0.14)**2
        if in_tri or in_eye:
            row += OR
        else:
            row += DK
    rows.append(bytes(row))
open('/usr/share/calamares/branding/nexis/logo.png', 'wb').write(_png(W, H, rows))
PYEOF
fi
cp /usr/share/calamares/branding/nexis/logo.png \
   /usr/share/calamares/branding/nexis/welcome.png

# Auto-login root on TTY1 → startx → openbox → Calamares
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/calamares.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

cat >> /root/.profile << 'PROFILE'
if [ -z "${DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    exec startx /root/.xinitrc -- :0 vt1
fi
PROFILE

cat > /root/.xinitrc << 'XINITRC'
#!/bin/sh
xsetroot -solid '#080807'
hsetroot -solid '#080807' 2>/dev/null || true
openbox &
sleep 0.6
exec calamares
XINITRC
chmod +x /root/.xinitrc

echo "[nexis] Setup complete."
HOOK
chmod +x config/hooks/live/0100-nexis-setup.hook.chroot

# ── GRUB theme (binary hook) ──────────────────────────────────────────────────

mkdir -p config/hooks/normal
cat > config/hooks/normal/9900-nexis-grub.hook.binary << 'HOOKEOF'
#!/usr/bin/env bash
set -euo pipefail

write_grub_cfg() {
cat << 'GRUB'
# NeXiS Hypervisor Boot Configuration
set timeout=8
set default=0

set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor" {
    linux   /live/vmlinuz boot=live components quiet splash
    initrd  /live/initrd.img
}

menuentry "Install NeXiS Hypervisor  [safe graphics]" {
    linux   /live/vmlinuz boot=live components nomodeset quiet splash
    initrd  /live/initrd.img
}

menuentry "Boot from existing OS" {
    set root=(hd0)
    chainloader +1
}
GRUB
}

[[ -f binary/boot/grub/grub.cfg ]] && write_grub_cfg > binary/boot/grub/grub.cfg
[[ -f binary/EFI/boot/grub.cfg  ]] && write_grub_cfg > binary/EFI/boot/grub.cfg
HOOKEOF
chmod +x config/hooks/normal/9900-nexis-grub.hook.binary

# ── Build ─────────────────────────────────────────────────────────────────────

_print "Running live-build (this takes several minutes)..."
lb build 2>&1 | tee "$OUTPUT_DIR/build.log"

ISO=$(find "$BUILD_DIR" -maxdepth 1 -name "*.iso" | head -1)
[[ -z "$ISO" ]] && _err "ISO not found after build."

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
mv "$ISO" "$FINAL"
SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO: $FINAL"
_ok "SHA256: $SHA"
_print "Write to USB: dd if='$FINAL' of=/dev/sdX bs=4M status=progress"
