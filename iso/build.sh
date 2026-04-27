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

# ── 3. Find initramfs ─────────────────────────────────────────────────────────

INITRAMFS=""
for candidate in \
    "$ISO_SRC/boot/initramfs-lts" \
    "$ISO_SRC/boot/initramfs" \
    "$ISO_SRC/boot/initrd-lts"
do
    [[ -f "$candidate" ]] && { INITRAMFS="$candidate"; break; }
done
[[ -z "$INITRAMFS" ]] && _err "initramfs not found in Alpine ISO"
_ok "initramfs: $INITRAMFS"

# ── 4. Extract and patch initramfs ────────────────────────────────────────────

INITRD_DIR="$WORK_DIR/initrd-root"
_print "Extracting initramfs…"
rm -rf "$INITRD_DIR" && mkdir -p "$INITRD_DIR"
( cd "$INITRD_DIR" && zcat "$INITRAMFS" | cpio -id --quiet 2>/dev/null )
_ok "initramfs extracted ($(find "$INITRD_DIR" | wc -l) entries)"

# Stage installer script
mkdir -p "$INITRD_DIR/usr/local/bin" "$INITRD_DIR/opt/nexis-installer"
cp "$SCRIPT_DIR/installer/nexis-install.sh" "$INITRD_DIR/usr/local/bin/nexis-install"
chmod +x "$INITRD_DIR/usr/local/bin/nexis-install"
cp "$SCRIPT_DIR/installer/nexis-install-alpine.sh" "$INITRD_DIR/opt/nexis-installer/install.sh"
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$INITRD_DIR/opt/nexis-installer/"
_ok "Installer staged"

# Auto-login root on tty1, then .profile launches the installer.
# -a root: BusyBox getty auto-login flag (more reliable than -l for our use).
if [[ -f "$INITRD_DIR/etc/inittab" ]]; then
    # Replace the tty1 line with auto-login
    sed -i 's|^tty1::.*|tty1::respawn:/sbin/getty -a root -L 0 tty1|' \
        "$INITRD_DIR/etc/inittab"
    _ok "inittab: auto-login root on tty1"
fi

# Root .profile: exec installer when on tty1
mkdir -p "$INITRD_DIR/root"
cat > "$INITRD_DIR/root/.profile" << 'PROFILE'
export TERM=linux
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -x /usr/local/bin/nexis-install ]; then
    exec /usr/local/bin/nexis-install
fi
PROFILE
_ok ".profile: installer auto-start on tty1"

# ── 5. Repack initramfs ───────────────────────────────────────────────────────

_print "Repacking initramfs…"
( cd "$INITRD_DIR" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$WORK_DIR/initramfs-new.gz"
cp "$WORK_DIR/initramfs-new.gz" "$INITRAMFS"
_ok "initramfs repacked ($(du -h "$INITRAMFS" | cut -f1))"

# ── 6. Stage /nexis/ on ISO (accessible as /media/cdrom/nexis/ from live) ────

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
