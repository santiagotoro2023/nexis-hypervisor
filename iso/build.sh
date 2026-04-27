#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder (Debian 12 edition)
#
# Builds a bootable Debian 12 live ISO that auto-launches our TUI installer.
# Boot: GRUB (BIOS+UEFI) → Debian live → nexis-install TUI
# Install: debootstrap Debian 12 to disk → NeXiS services → reboot
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "run as root"

_print "Installing build dependencies..."
apt-get update -qq
apt-get install -yq \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub-common \
    grub-efi-amd64-bin \
    grub-pc-bin \
    mtools \
    2>/dev/null | tail -1

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Bootstrap minimal Debian 12 ───────────────────────────────────────────

ROOTFS="$WORK_DIR/rootfs"
_print "Bootstrapping Debian 12 (bookworm)..."
if [[ ! -f "$ROOTFS/usr/bin/dpkg" ]]; then
    debootstrap --arch=amd64 --variant=minbase bookworm "$ROOTFS" \
        http://deb.debian.org/debian
fi
_ok "Base: $(du -sh "$ROOTFS" | cut -f1)"

# ── 2. Install live system packages ──────────────────────────────────────────
# live-boot MUST be installed before linux-image so update-initramfs includes it.

_print "Installing live system packages..."
chroot "$ROOTFS" /bin/bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends live-boot 2>/dev/null | tail -1
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    systemd systemd-sysv \
    whiptail \
    parted \
    dosfstools e2fsprogs \
    iproute2 \
    dhcpcd5 \
    grub-efi-amd64-bin grub-pc-bin \
    efibootmgr \
    curl \
    debootstrap \
    kbd \
    python3 \
    kmod \
    pciutils \
    util-linux \
    ca-certificates \
    2>/dev/null | tail -1
apt-get clean
rm -rf /var/lib/apt/lists/*
"
_ok "Packages installed: $(du -sh "$ROOTFS" | cut -f1)"

# ── 3. Configure live system ──────────────────────────────────────────────────

_print "Configuring live system..."

echo "nexis-installer" > "$ROOTFS/etc/hostname"

# APT sources used by the installer when debootstrapping the target disk
cat > "$ROOTFS/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main
EOF

# No root password in live session
chroot "$ROOTFS" passwd -d root 2>/dev/null || true

# systemd-networkd: DHCP on all Ethernet interfaces automatically (covers
# e1000, virtio_net, vmxnet3, r8169 — whatever udev names them)
mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" << 'EOF'
[Match]
Type=ether

[Network]
DHCP=yes
EOF
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null || true

# Auto-login root on tty1 so the installer fires immediately
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

# Root profile launches installer on tty1
cat > "$ROOTFS/root/.bash_profile" << 'EOF'
export TERM=linux
[ "$(tty)" = "/dev/tty1" ] && exec /usr/local/bin/nexis-install
EOF
chmod 600 "$ROOTFS/root/.bash_profile"

# Suppress kernel noise during install TUI
cat > "$ROOTFS/etc/sysctl.d/10-quiet.conf" << 'EOF'
kernel.printk = 3 3 3 3
EOF

# Installer and support files
mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/opt/nexis-installer"
cp "$SCRIPT_DIR/installer/nexis-install.sh"        "$ROOTFS/usr/local/bin/nexis-install"
chmod +x "$ROOTFS/usr/local/bin/nexis-install"

cp "$SCRIPT_DIR/installer/nexis-install-debian.sh" "$ROOTFS/opt/nexis-installer/install.sh"  2>/dev/null || true
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$ROOTFS/opt/nexis-installer/"             2>/dev/null || true
cp "$SCRIPT_DIR/nexis-shell.py"                    "$ROOTFS/opt/nexis-installer/"             2>/dev/null || true

_ok "Live system configured"

# ── 4. Build squashfs ─────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
mkdir -p "$ISO_SRC/live"

_print "Building squashfs (this takes a few minutes)..."
mksquashfs "$ROOTFS" "$ISO_SRC/live/filesystem.squashfs" \
    -comp lz4 -Xhc \
    -e boot \
    2>/dev/null
_ok "squashfs: $(du -h "$ISO_SRC/live/filesystem.squashfs" | cut -f1)"

# Kernel and initrd go on the ISO directly; bootloader loads them before squashfs
VMLINUZ=$(ls "$ROOTFS/boot/vmlinuz-"*    | sort | tail -1)
INITRD=$(ls  "$ROOTFS/boot/initrd.img-"* | sort | tail -1)
cp "$VMLINUZ" "$ISO_SRC/live/vmlinuz"
cp "$INITRD"  "$ISO_SRC/live/initrd.img"
_ok "Kernel: $(basename "$VMLINUZ")"
_ok "Initrd: $(basename "$INITRD")"

# ── 5. Stage /nexis/ on ISO ───────────────────────────────────────────────────

mkdir -p "$ISO_SRC/nexis"
cp "$SCRIPT_DIR/installer/nexis-install-debian.sh" "$ISO_SRC/nexis/install.sh"  2>/dev/null || true
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$ISO_SRC/nexis/"            2>/dev/null || true
cp "$SCRIPT_DIR/nexis-shell.py"                    "$ISO_SRC/nexis/"            2>/dev/null || true
_ok "/nexis/ staged on ISO"

# ── 6. GRUB config ────────────────────────────────────────────────────────────

mkdir -p "$ISO_SRC/boot/grub"
cat > "$ISO_SRC/boot/grub/grub.cfg" << EOF
# NeXiS Hypervisor ${VERSION}
set default=0
set timeout=5
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor ${VERSION}" {
    linux  /live/vmlinuz boot=live components nomodeset quiet
    initrd /live/initrd.img
}
EOF
_ok "GRUB config written"

# ── 7. Build ISO (BIOS + UEFI via grub-mkrescue) ─────────────────────────────

_print "Building ISO..."
FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"

grub-mkrescue -o "$FINAL" "$ISO_SRC" -- \
    -r -V "$ISO_VOLUME" -J --joliet-long 2>/dev/null

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"
_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_ok "SHA256: $SHA"
