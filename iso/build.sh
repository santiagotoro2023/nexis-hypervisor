#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Downloads Alpine Linux extended ISO, injects the NeXiS installer via apkovl,
# patches boot menu. The installer itself installs Debian 12 to the target disk.
#
# Boot:    GRUB/syslinux → Alpine live (network + hardware drivers included)
# Install: NeXiS TUI → debootstrap Debian 12 → systemd services → reboot
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# ── 1. Download Alpine extended ISO ──────────────────────────────────────────

ALPINE_ISO="$WORK_DIR/alpine.iso"
if [[ ! -f "$ALPINE_ISO" ]]; then
    _print "Finding Alpine ISO filename..."
    FNAME=$(curl -sSL "${ALPINE_MIRROR}/" \
        | grep -oP 'alpine-extended-[\d.]+-x86_64\.iso' | head -1 || true)
    [[ -z "$FNAME" ]] && _err "Could not find Alpine ISO at $ALPINE_MIRROR"
    _print "Downloading $FNAME..."
    curl -fL "${ALPINE_MIRROR}/${FNAME}" -o "$ALPINE_ISO"
    _ok "$FNAME ($(du -h "$ALPINE_ISO" | cut -f1))"
fi

# ── 2. Extract ISO ────────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
_print "Extracting ISO..."
rm -rf "$ISO_SRC" && mkdir -p "$ISO_SRC"
xorriso -osirrox on -indev "$ALPINE_ISO" -extract / "$ISO_SRC/" 2>/dev/null
chmod -R u+w "$ISO_SRC"
_ok "Extracted"

# ── 3. Build apkovl overlay ───────────────────────────────────────────────────
# Alpine applies localhost.apkovl.tar.gz from the boot device before getty
# starts, overlaying files onto the running live system.

APKOVL_DIR="$WORK_DIR/apkovl"
rm -rf "$APKOVL_DIR" && mkdir -p "$APKOVL_DIR"

mkdir -p "$APKOVL_DIR/etc"
cat > "$APKOVL_DIR/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty1::respawn:/sbin/getty -n -l /usr/local/bin/nexis-install 0 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6
::shutdown:/sbin/openrc shutdown
EOF

mkdir -p "$APKOVL_DIR/root"
cat > "$APKOVL_DIR/root/.profile" << 'EOF'
export TERM=linux
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -x /usr/local/bin/nexis-install ]; then
    exec /usr/local/bin/nexis-install
fi
EOF

mkdir -p "$APKOVL_DIR/usr/local/bin"
cp "$SCRIPT_DIR/installer/nexis-install.sh" "$APKOVL_DIR/usr/local/bin/nexis-install"
chmod +x "$APKOVL_DIR/usr/local/bin/nexis-install"

mkdir -p "$APKOVL_DIR/opt/nexis-installer"
cp "$SCRIPT_DIR/installer/nexis-install-debian.sh" "$APKOVL_DIR/opt/nexis-installer/install.sh"
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$APKOVL_DIR/opt/nexis-installer/"
cp "$SCRIPT_DIR/nexis-shell.py"                    "$APKOVL_DIR/opt/nexis-installer/"

# Bundle keyboard bmap files (bonus — installer also fetches via apk if needed)
_print "Bundling keyboard bmap files..."
_BMAP_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64"
BMAP_PKG=$(curl -fsSL "${_BMAP_BASE}/" 2>/dev/null \
    | grep -oE 'kbd-bkeymaps-[^"]+\.apk' | head -1 || true)
if [[ -n "$BMAP_PKG" ]]; then
    curl -fsSL "${_BMAP_BASE}/${BMAP_PKG}" -o "$WORK_DIR/kbd-bkeymaps.apk" 2>/dev/null || true
    if [[ -f "$WORK_DIR/kbd-bkeymaps.apk" ]]; then
        mkdir -p "$APKOVL_DIR/usr/share/bkeymaps"
        tar xzf "$WORK_DIR/kbd-bkeymaps.apk" -C "$APKOVL_DIR" 2>/dev/null || true
        _COUNT=$(find "$APKOVL_DIR/usr/share/bkeymaps" -name '*.bmap.gz' 2>/dev/null | wc -l)
        [[ $_COUNT -gt 0 ]] && _ok "Bundled $_COUNT keyboard layouts" \
            || _ok "kbd-bkeymaps extracted but empty — will fetch at install time"
    else
        _ok "kbd-bkeymaps download failed — will fetch at install time"
    fi
else
    _ok "kbd-bkeymaps not on CDN — will fetch at install time"
fi

_print "Packing apkovl..."
( cd "$APKOVL_DIR" && tar czf "$WORK_DIR/localhost.apkovl.tar.gz" . )
cp "$WORK_DIR/localhost.apkovl.tar.gz" "$ISO_SRC/"
_ok "apkovl: $(du -h "$ISO_SRC/localhost.apkovl.tar.gz" | cut -f1)"

# ── 4. Stage /nexis/ on ISO ───────────────────────────────────────────────────

mkdir -p "$ISO_SRC/nexis"
cp "$SCRIPT_DIR/installer/nexis-install-debian.sh" "$ISO_SRC/nexis/install.sh"
cp "$SCRIPT_DIR/firstboot-tui.py"                  "$ISO_SRC/nexis/"
cp "$SCRIPT_DIR/nexis-shell.py"                    "$ISO_SRC/nexis/"
_ok "/nexis/ staged on ISO"

# ── 5. GRUB config (UEFI) ────────────────────────────────────────────────────

KPARAMS="modules=loop,squashfs,sd-mod,usb-storage,virtio_pci,virtio_net,virtio_blk,e1000,e1000e,r8169,8139too,igb,vmxnet3,pcnet32,ahci,nvme nomodeset quiet alpine_dev=autodetect"

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

# ── 6. Syslinux config (BIOS) ─────────────────────────────────────────────────

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

# ── 7. Repack ISO ─────────────────────────────────────────────────────────────

_print "Repacking ISO..."
FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"

dd if="$ALPINE_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

BIOS_BIN=""
for b in \
    "$ISO_SRC/syslinux/isolinux.bin" \
    "$ISO_SRC/boot/syslinux/isolinux.bin" \
    "$ISO_SRC/syslinux/syslinux.bin"
do
    [[ -f "$b" ]] && { BIOS_BIN="${b#$ISO_SRC/}"; break; }
done

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
    xorriso -as mkisofs \
        -r -V "$ISO_VOLUME" -o "$FINAL" -J --joliet-long \
        -eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot \
        "$ISO_SRC/"
else
    xorriso -as mkisofs -r -V "$ISO_VOLUME" -o "$FINAL" -J "$ISO_SRC/"
fi

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"
_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_ok "SHA256: $SHA"
