#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Produces a bootable ISO with:
#   - Custom GRUB boot menu  (NeXiS branding, dark/orange, installer only)
#   - Calamares graphical installer  (fully themed: dark bg, #F87200 orange, logo)
#   - Pre-installed NeXiS Hypervisor stack  (copied to disk via unpackfs)
#   - Post-install firstboot TUI  (network / hostname / controller config)
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
# No debian-installer — Calamares handles everything.
# The live squashfs IS the installed system (unpackfs copies it verbatim).

lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --apt-recommends false \
    --iso-application "NeXiS Hypervisor ${VERSION}" \
    --iso-volume "${ISO_VOLUME}"

# ── Package list ──────────────────────────────────────────────────────────────
# Everything in the live system ends up on the installed disk via unpackfs.

mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
# ── Virtualisation ─────────────────────────────────────────────────────────
qemu-kvm
libvirt-daemon-system
libvirt-clients
lxc
# ── Web interface ──────────────────────────────────────────────────────────
novnc
websockify
# ── Python ────────────────────────────────────────────────────────────────
python3
python3-pip
python3-venv
python3-dev
libvirt-dev
pkg-config
build-essential
# ── System ────────────────────────────────────────────────────────────────
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
# ── Calamares installer ───────────────────────────────────────────────────
calamares
calamares-settings-debian
# ── Minimal X11 + window manager for installer ────────────────────────────
xorg
openbox
xinit
xterm
hsetroot
# ── Font (JetBrains Mono via nerd-fonts-jetbrains-mono or ttf-jetbrains-mono)
fonts-jetbrains-mono
EOF

# ── Chroot hook: build NeXiS and configure live environment ──────────────────

mkdir -p config/hooks/live
cat > config/hooks/live/0100-nexis-build.hook.chroot << 'HOOK'
#!/usr/bin/env bash
set -euo pipefail

NEXIS_DIR="/opt/nexis-hypervisor"
NEXIS_DATA="/etc/nexis-hypervisor"

echo "[nexis] Cloning NeXiS Hypervisor..."
git clone --quiet --depth 1 \
    https://github.com/santiagotoro2023/nexis-hypervisor \
    "$NEXIS_DIR"

echo "[nexis] Building Python environment..."
python3 -m venv "$NEXIS_DIR/venv"
"$NEXIS_DIR/venv/bin/pip" install -q --upgrade pip
"$NEXIS_DIR/venv/bin/pip" install -q -r "$NEXIS_DIR/daemon/requirements.txt"

echo "[nexis] Building web UI..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - -s -- -y 2>/dev/null
apt-get install -yq nodejs 2>/dev/null
cd "$NEXIS_DIR/web" && npm install --silent && npm run build --silent
echo "[nexis] Web UI built."

# ── Data directory
mkdir -p "$NEXIS_DATA"
chmod 700 "$NEXIS_DATA"

# ── NeXiS systemd service
cp "$NEXIS_DIR/nexis-hypervisor.service" /etc/systemd/system/
systemctl enable nexis-hypervisor 2>/dev/null || true

# ── Firstboot TUI service (runs after installation, before web UI)
cp /tmp/nexis-firstboot-tui.py /usr/local/bin/nexis-firstboot
chmod +x /usr/local/bin/nexis-firstboot

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

echo "[nexis] NeXiS stack installed and enabled."
HOOK
chmod +x config/hooks/live/0100-nexis-build.hook.chroot

# ── Copy firstboot TUI into chroot via includes ──────────────────────────────

mkdir -p config/includes.chroot/tmp
cp "$SCRIPT_DIR/firstboot-tui.py" config/includes.chroot/tmp/nexis-firstboot-tui.py

# ── Chroot hook: install Calamares branding and configure auto-launch ─────────

cat > config/hooks/live/0200-calamares-setup.hook.chroot << 'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# ── Install NeXiS branding into Calamares
BRAND_DST="/usr/share/calamares/branding/nexis"
mkdir -p "$BRAND_DST"
cp /tmp/nexis-branding/* "$BRAND_DST/"

# Convert SVG logo to PNG (try rsvg-convert, then inkscape, then python3)
if command -v rsvg-convert &>/dev/null; then
    rsvg-convert -w 128 -h 128 "$BRAND_DST/logo.svg" -o "$BRAND_DST/logo.png"
elif command -v inkscape &>/dev/null; then
    inkscape --export-filename="$BRAND_DST/logo.png" \
             --export-width=128 --export-height=128 \
             "$BRAND_DST/logo.svg" 2>/dev/null
else
    # Fallback: generate a minimal 128x128 orange square PNG via python3
    python3 - << 'PYEOF'
import struct, zlib
def png(w, h, rows):
    def chunk(t, d):
        c = zlib.crc32(t+d) & 0xffffffff
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', c)
    raw = b''.join(b'\x00' + r for r in rows)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB',w,h,8,2,0,0,0)) + \
           chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
W=H=128
orange=(0xF8,0x72,0x00); dark=(0x08,0x08,0x07)
rows=[bytes(sum([[*orange] if (20<=x<=108 and 20<=y<=108) else [*dark] for x in range(W)],[]))
      for y in range(H)]
open('/usr/share/calamares/branding/nexis/logo.png','wb').write(png(W,H,rows))
PYEOF
fi

# Welcome background: same dark solid colour
cp "$BRAND_DST/logo.png" "$BRAND_DST/welcome.png"

# ── Apply the NeXiS QSS stylesheet as the Calamares global style
mkdir -p /etc/calamares
cp /tmp/nexis-calamares-settings.conf /etc/calamares/settings.conf
mkdir -p /etc/calamares/modules
cp /tmp/nexis-calamares-modules/* /etc/calamares/modules/ 2>/dev/null || true

# ── Auto-launch: root auto-login → startx → openbox → calamares
# Override getty@tty1 for root auto-login
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/calamares.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Root's login shell starts X if on TTY1
cat >> /root/.profile << 'PROFILE'
# NeXiS live installer auto-start
if [ -z "${DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    exec startx /root/.xinitrc -- :0 vt1
fi
PROFILE

# .xinitrc: dark background → openbox → Calamares
cat > /root/.xinitrc << 'XINITRC'
#!/bin/sh
# NeXiS installer X session
xsetroot -solid '#080807'
hsetroot -solid '#080807' 2>/dev/null || true
openbox &
sleep 0.6
exec calamares
XINITRC
chmod +x /root/.xinitrc

echo "[nexis] Calamares configured."
HOOK
chmod +x config/hooks/live/0200-calamares-setup.hook.chroot

# ── Copy Calamares branding and config via includes ───────────────────────────

mkdir -p config/includes.chroot/tmp/nexis-branding
cp "$SCRIPT_DIR/calamares/branding/nexis/"* \
   config/includes.chroot/tmp/nexis-branding/

cp "$SCRIPT_DIR/calamares/settings.conf" \
   config/includes.chroot/tmp/nexis-calamares-settings.conf

mkdir -p config/includes.chroot/tmp/nexis-calamares-modules
cp "$SCRIPT_DIR/calamares/modules/"*.conf \
   config/includes.chroot/tmp/nexis-calamares-modules/ 2>/dev/null || true

# ── GRUB theme (binary hook) ──────────────────────────────────────────────────
# Runs after the binary stage — rewrites grub.cfg with NeXiS branding
# and removes the "Live system" entries, showing only the installer.

mkdir -p config/hooks/normal
cat > config/hooks/normal/9900-nexis-grub.hook.binary << 'HOOKEOF'
#!/usr/bin/env bash
set -euo pipefail

write_grub_cfg() {
cat << 'GRUB'
# NeXiS Hypervisor Boot Configuration
set timeout=8
set default=0

# Color scheme  (GRUB standard colors — yellow is closest to #F87200 orange)
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
