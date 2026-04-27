#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder (Alpine Linux edition)
#
# Downloads Alpine Linux standard ISO, modifies the initramfs to auto-start
# our interactive whiptail installer, patches the boot menu, repacks.
#
# Boot:    GRUB/syslinux → Alpine live (nomodeset, no GPU needed)
# Install: whiptail TUI → keyboard / hostname / password / controller URL
#          → apk install Alpine to disk → NeXiS services → reboot
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "run as root"
apt-get install -yq xorriso cpio gzip curl 2>/dev/null | tail -1
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Download Alpine standard ISO ──────────────────────────────────────────

ALPINE_ISO="$WORK_DIR/alpine.iso"
if [[ ! -f "$ALPINE_ISO" ]]; then
    _print "Finding Alpine ISO filename…"
    FNAME=$(curl -sSL "${ALPINE_MIRROR}/" \
        | grep -oP 'alpine-standard-[\d.]+-x86_64\.iso' | head -1 || true)
    [[ -z "$FNAME" ]] && _err "Could not find Alpine ISO at $ALPINE_MIRROR"
    _print "Downloading $FNAME…"
    curl -fL "${ALPINE_MIRROR}/${FNAME}" -o "$ALPINE_ISO"
    _ok "$FNAME ($(du -h "$ALPINE_ISO" | cut -f1))"
fi

# ── 2. Extract ISO ────────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
_print "Extracting ISO…"
rm -rf "$ISO_SRC" && mkdir -p "$ISO_SRC"
xorriso -osirrox on -indev "$ALPINE_ISO" -extract / "$ISO_SRC/" 2>/dev/null
chmod -R u+w "$ISO_SRC"
_ok "Extracted"

# ── 3. Alpine overlay (apkovl) — the correct way to customise Alpine live ─────
#
# Alpine applies localhost.apkovl.tar.gz from the boot device before getty
# starts. This overlays files onto the running system automatically.
# No initramfs extraction or repacking needed.

APKOVL_DIR="$WORK_DIR/apkovl"
rm -rf "$APKOVL_DIR" && mkdir -p "$APKOVL_DIR"

# /etc/inittab — auto-login root on tty1 so our installer fires immediately
mkdir -p "$APKOVL_DIR/etc"
cat > "$APKOVL_DIR/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty1::respawn:/sbin/getty -a root -L 0 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6
::shutdown:/sbin/openrc shutdown
EOF

# /root/.profile — exec installer when root logs in on tty1
mkdir -p "$APKOVL_DIR/root"
cat > "$APKOVL_DIR/root/.profile" << 'EOF'
export TERM=linux
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -x /usr/local/bin/nexis-install ]; then
    exec /usr/local/bin/nexis-install
fi
EOF

# /usr/local/bin/nexis-install — the installer (available immediately at boot)
mkdir -p "$APKOVL_DIR/usr/local/bin"
cp "$SCRIPT_DIR/installer/nexis-install.sh" "$APKOVL_DIR/usr/local/bin/nexis-install"
chmod +x "$APKOVL_DIR/usr/local/bin/nexis-install"

# /opt/nexis-installer — support files the installer copies to the target disk
mkdir -p "$APKOVL_DIR/opt/nexis-installer"
cp "$SCRIPT_DIR/installer/nexis-install-alpine.sh" "$APKOVL_DIR/opt/nexis-installer/install.sh"
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$APKOVL_DIR/opt/nexis-installer/"
cp "$SCRIPT_DIR/nexis-shell.py"                    "$APKOVL_DIR/opt/nexis-installer/"

# Pack the overlay (Alpine expects HOSTNAME.apkovl.tar.gz; default hostname = localhost)
_print "Building apkovl overlay…"
( cd "$APKOVL_DIR" && tar czf "$WORK_DIR/localhost.apkovl.tar.gz" . )
cp "$WORK_DIR/localhost.apkovl.tar.gz" "$ISO_SRC/"
_ok "apkovl: $(du -h "$ISO_SRC/localhost.apkovl.tar.gz" | cut -f1)  (applied by Alpine before getty)"

# ── 4. Stage /nexis/ on ISO (accessible as /media/cdrom/nexis/ or similar) ───

mkdir -p "$ISO_SRC/nexis"
cp "$SCRIPT_DIR/installer/nexis-install-alpine.sh" "$ISO_SRC/nexis/install.sh"
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$ISO_SRC/nexis/"
cp "$SCRIPT_DIR/nexis-shell.py"                    "$ISO_SRC/nexis/"
_ok "/nexis/ staged on ISO"

# ── 7. GRUB config (UEFI) — single entry, NeXiS branding ────────────────────
# Keep Alpine's required kernel params (modules= alpine_dev=) for USB boot.
# Add nomodeset to prevent nouveau crashing on NVIDIA hardware.

KPARAMS="modules=loop,squashfs,sd-mod,usb-storage quiet nomodeset console=tty1 alpine_dev=autodetect"

for grub_cfg in \
    "$ISO_SRC/boot/grub/grub.cfg" \
    "$ISO_SRC/EFI/boot/grub.cfg"
do
    [[ -f "$grub_cfg" ]] || continue
    cat > "$grub_cfg" << EOF
# NeXiS Hypervisor ${VERSION}
set default=0
set timeout=5
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor ${VERSION}" {
    linux  /boot/vmlinuz-lts ${KPARAMS}
    initrd /boot/initramfs-lts
}
EOF
    _ok "GRUB: $grub_cfg"
done

# ── 8. Syslinux config (BIOS) — single entry ─────────────────────────────────

for syslinux_cfg in \
    "$ISO_SRC/syslinux/syslinux.cfg" \
    "$ISO_SRC/boot/syslinux/syslinux.cfg"
do
    [[ -f "$syslinux_cfg" ]] || continue
    cat > "$syslinux_cfg" << EOF
DEFAULT nexis
LABEL nexis
    MENU LABEL Install NeXiS Hypervisor ${VERSION}
    LINUX /boot/vmlinuz-lts
    INITRD /boot/initramfs-lts
    APPEND ${KPARAMS}
TIMEOUT 50
EOF
    _ok "syslinux: $syslinux_cfg"
done

# ── 9. Repack ISO ─────────────────────────────────────────────────────────────

_print "Repacking ISO…"
FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"

# Extract MBR from original Alpine ISO for hybrid BIOS boot
dd if="$ALPINE_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

# Locate BIOS boot binary (isolinux.bin or syslinux.bin)
BIOS_BIN=""
for b in \
    "$ISO_SRC/syslinux/isolinux.bin" \
    "$ISO_SRC/boot/syslinux/isolinux.bin" \
    "$ISO_SRC/syslinux/syslinux.bin"
do
    [[ -f "$b" ]] && { BIOS_BIN="${b#$ISO_SRC/}"; break; }
done

# EFI image
EFI_IMG=""
for e in "$ISO_SRC/boot/grub/efi.img" "$ISO_SRC/efi.img"; do
    [[ -f "$e" ]] && { EFI_IMG="${e#$ISO_SRC/}"; break; }
done

if [[ -n "$BIOS_BIN" && -n "$EFI_IMG" ]]; then
    BOOTCAT="${BIOS_BIN%/*}/boot.cat"
    xorriso -as mkisofs \
        -r -V "$ISO_VOLUME" -o "$FINAL" -J --joliet-long \
        -isohybrid-mbr "$WORK_DIR/mbr.bin" -partition_offset 16 \
        -c "$BOOTCAT" \
        -b "$BIOS_BIN" -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e "$EFI_IMG" -no-emul-boot -isohybrid-gpt-basdat \
        "$ISO_SRC/"
elif [[ -n "$EFI_IMG" ]]; then
    # EFI only
    xorriso -as mkisofs \
        -r -V "$ISO_VOLUME" -o "$FINAL" -J --joliet-long \
        -eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot \
        "$ISO_SRC/"
else
    # Fallback: plain ISO
    xorriso -as mkisofs -r -V "$ISO_VOLUME" -o "$FINAL" -J "$ISO_SRC/"
fi

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"
_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_ok "SHA256: $SHA"
