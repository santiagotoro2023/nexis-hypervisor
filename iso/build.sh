#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder (Debian 12)
#
# Builds a bootable Debian 12 live ISO with our TUI installer.
# Runs on ubuntu-latest with sudo — full capabilities, no container limits.
#
# Boot:    GRUB (BIOS+UEFI) → Debian live → nexis-install TUI
# Install: debootstrap Debian 12 → systemd → NeXiS services → reboot
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "must run as root"

ROOTFS_MOUNTS_DONE=0
_cleanup() {
    if [[ $ROOTFS_MOUNTS_DONE -eq 1 ]]; then
        local rf="$WORK_DIR/rootfs"
        umount "$rf/dev/pts" 2>/dev/null || true
        umount "$rf/dev"     2>/dev/null || true
        umount "$rf/run"     2>/dev/null || true
        umount "$rf/sys"     2>/dev/null || true
        umount "$rf/proc"    2>/dev/null || true
    fi
}
trap _cleanup EXIT

_print "Installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive

# On ubuntu-latest, unattended-upgrades often holds the dpkg lock at startup.
# Wait up to 5 minutes for it to release before running apt-get.
_lock_wait=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock     >/dev/null 2>&1; do
    _lock_wait=$((_lock_wait + 1))
    [[ $_lock_wait -gt 60 ]] && _err "dpkg/apt lock held for >5 min — giving up"
    sleep 5
done

apt-get update -q
apt-get install -y --no-install-recommends \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub-common \
    mtools \
    ca-certificates

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Bootstrap Debian 12 ───────────────────────────────────────────────────

ROOTFS="$WORK_DIR/rootfs"
_print "Bootstrapping Debian 12 (bookworm)..."
if [[ ! -f "$ROOTFS/usr/bin/dpkg" ]]; then
    # --no-check-gpg avoids GPG key failures on non-Debian build hosts
    debootstrap --arch=amd64 --variant=minbase --no-check-gpg \
        bookworm "$ROOTFS" http://deb.debian.org/debian
fi
_ok "Base: $(du -sh "$ROOTFS" | cut -f1)"

# ── 2. Bind-mount for chroot ──────────────────────────────────────────────────
# ubuntu-latest runner has full root + all capabilities — mount works fine.

_print "Preparing chroot..."
mkdir -p "$ROOTFS"/{proc,sys,dev,run}
mount -t proc   proc     "$ROOTFS/proc"
mount -t sysfs  sysfs    "$ROOTFS/sys"
mount --bind    /dev     "$ROOTFS/dev"
mount --bind    /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
mount --bind    /run     "$ROOTFS/run"
ROOTFS_MOUNTS_DONE=1

# Prevent dpkg postinst from trying to start services during install
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

# ── 3. Install live system packages ──────────────────────────────────────────
# live-boot MUST come before linux-image so update-initramfs picks up its hooks.

_print "Installing live system packages..."
chroot "$ROOTFS" /bin/bash << 'CHROOTEOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# live-boot must be installed before linux-image so update-initramfs picks up live hooks
apt-get install -y --no-install-recommends live-boot
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
    ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF
_ok "Packages: $(du -sh "$ROOTFS" | cut -f1)"

# ── 4. Configure live system ──────────────────────────────────────────────────

_print "Configuring live system..."

echo "nexis-installer" > "$ROOTFS/etc/hostname"

cat > "$ROOTFS/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main
EOF

chroot "$ROOTFS" passwd -d root 2>/dev/null || true
rm -f "$ROOTFS/usr/sbin/policy-rc.d"

# systemd-networkd: DHCP on all Ethernet (any interface name — e1000, virtio, vmxnet3…)
mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" << 'EOF'
[Match]
Type=ether

[Network]
DHCP=yes
EOF
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null || true

# Auto-login root on tty1 → installer fires immediately
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

cat > "$ROOTFS/root/.bash_profile" << 'EOF'
export TERM=linux
[ "$(tty)" = "/dev/tty1" ] && exec /usr/local/bin/nexis-install
EOF
chmod 600 "$ROOTFS/root/.bash_profile"

cat > "$ROOTFS/etc/sysctl.d/10-quiet.conf" << 'EOF'
kernel.printk = 3 3 3 3
EOF

mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/opt/nexis-installer"
cp "$SCRIPT_DIR/installer/nexis-install.sh"        "$ROOTFS/usr/local/bin/nexis-install"
chmod +x "$ROOTFS/usr/local/bin/nexis-install"

cp "$SCRIPT_DIR/installer/nexis-install-debian.sh" "$ROOTFS/opt/nexis-installer/install.sh"  2>/dev/null || true
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$ROOTFS/opt/nexis-installer/"             2>/dev/null || true
cp "$SCRIPT_DIR/nexis-shell.py"                    "$ROOTFS/opt/nexis-installer/"             2>/dev/null || true
cp "$SCRIPT_DIR/nexis-update.sh"                   "$ROOTFS/opt/nexis-installer/nexis-update" 2>/dev/null || true

_ok "Live system configured"

# ── 5. Unmount chroot ─────────────────────────────────────────────────────────

umount "$ROOTFS/dev/pts" 2>/dev/null || true
umount "$ROOTFS/dev"     2>/dev/null || true
umount "$ROOTFS/run"     2>/dev/null || true
umount "$ROOTFS/sys"     2>/dev/null || true
umount "$ROOTFS/proc"    2>/dev/null || true
ROOTFS_MOUNTS_DONE=0

# ── 6. Build squashfs ─────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
mkdir -p "$ISO_SRC/live"

_print "Building squashfs..."
mksquashfs "$ROOTFS" "$ISO_SRC/live/filesystem.squashfs" -comp xz -e boot
_ok "squashfs: $(du -h "$ISO_SRC/live/filesystem.squashfs" | cut -f1)"

VMLINUZ=$(find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*'    | sort | tail -1)
INITRD=$(find  "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' | sort | tail -1)
[[ -f "$VMLINUZ" ]] || _err "vmlinuz not found — linux-image install failed"
[[ -f "$INITRD"  ]] || _err "initrd not found — update-initramfs failed"
cp "$VMLINUZ" "$ISO_SRC/live/vmlinuz"
cp "$INITRD"  "$ISO_SRC/live/initrd.img"
_ok "Kernel: $(basename "$VMLINUZ")"
_ok "Initrd: $(basename "$INITRD")"

# ── 7. Stage /nexis/ on ISO ───────────────────────────────────────────────────

mkdir -p "$ISO_SRC/nexis"
cp "$SCRIPT_DIR/installer/nexis-install-debian.sh" "$ISO_SRC/nexis/install.sh"  2>/dev/null || true
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$ISO_SRC/nexis/"            2>/dev/null || true
cp "$SCRIPT_DIR/nexis-shell.py"                    "$ISO_SRC/nexis/"            2>/dev/null || true
cp "$SCRIPT_DIR/nexis-update.sh"                   "$ISO_SRC/nexis/nexis-update" 2>/dev/null || true
_ok "/nexis/ staged"

# ── 8. GRUB config ────────────────────────────────────────────────────────────

mkdir -p "$ISO_SRC/boot/grub"
cat > "$ISO_SRC/boot/grub/grub.cfg" << EOF
# NeXiS Hypervisor ${VERSION}
# Force VGA text console — prevents "no suitable video mode" on VMware/UEFI
terminal_input  console
terminal_output console
# Keep display in text mode during kernel handoff (avoids second video-mode error)
set gfxpayload=text
set default=0
set timeout=5
# VGA palette: brown = dark orange, yellow = bright orange-ish
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=brown/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor ${VERSION}" {
    linux  /live/vmlinuz boot=live components quiet
    initrd /live/initrd.img
}
EOF
_ok "GRUB config written"

# ── 9. Build ISO ──────────────────────────────────────────────────────────────

# Copy GRUB platform modules from rootfs so grub-mkrescue can find them.
# This avoids installing grub-efi-amd64-bin/grub-pc-bin on the host.
_print "Staging GRUB modules from rootfs..."
mkdir -p /usr/lib/grub
for _plat in x86_64-efi i386-pc; do
    [[ -d "$ROOTFS/usr/lib/grub/$_plat" ]] && \
        cp -r "$ROOTFS/usr/lib/grub/$_plat" /usr/lib/grub/ || true
done
_ok "GRUB modules: $(ls /usr/lib/grub/)"

_print "Building ISO..."
FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
grub-mkrescue -o "$FINAL" "$ISO_SRC"

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"
_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_ok "SHA256: $SHA"
