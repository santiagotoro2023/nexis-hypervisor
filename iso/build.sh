#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Remaster the official Debian 12 netinst ISO with NeXiS branding.
# No live-build, no live system, no GPU driver issues.
# Works in BIOS (syslinux, orange theme) and UEFI (GRUB, orange theme).
#
# Boot flow:
#   USB/DVD → NeXiS-branded boot menu → standard Debian installer (d-i)
#   → preseed auto-fills defaults → late_command drops NeXiS scripts
#   → first reboot → nexis-install.service runs install.sh → web UI ready
#
# Requires: xorriso, curl (run as root in Debian/Ubuntu)
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

# Official Debian 12 netinst (amd64) — the installer only, no live system
DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12-netinst.iso"

_print() { printf '\033[38;5;208m[nexis-iso]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "Must run as root."
for cmd in xorriso curl; do
    command -v "$cmd" &>/dev/null || apt-get install -yq "$cmd" 2>/dev/null
done

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Download Debian 12 netinst ISO ─────────────────────────────────────────

DEBIAN_ISO="${WORK_DIR}/debian-netinst.iso"
if [[ ! -f "$DEBIAN_ISO" ]]; then
    _print "Downloading Debian 12 netinst ISO..."
    curl -fL --progress-bar "$DEBIAN_ISO_URL" -o "$DEBIAN_ISO"
    _ok "Downloaded: $(du -h "$DEBIAN_ISO" | cut -f1)"
else
    _ok "Debian ISO already cached: $DEBIAN_ISO"
fi

# ── 2. Extract ISO ────────────────────────────────────────────────────────────

ISO_SRC="${WORK_DIR}/iso-src"
_print "Extracting ISO..."
rm -rf "$ISO_SRC"
mkdir -p "$ISO_SRC"
xorriso -osirrox on -indev "$DEBIAN_ISO" -extract / "$ISO_SRC/" 2>/dev/null
chmod -R u+w "$ISO_SRC"
_ok "Extracted"

# ── 3. Add NeXiS scripts to /nexis/ on the ISO ────────────────────────────────
# Accessible during d-i as /cdrom/nexis/

mkdir -p "$ISO_SRC/nexis"

cp "$REPO_DIR/install.sh"         "$ISO_SRC/nexis/"
cp "$SCRIPT_DIR/firstboot-tui.py" "$ISO_SRC/nexis/"

cat > "$ISO_SRC/nexis/nexis-install.service" << 'SVC'
[Unit]
Description=NeXiS Hypervisor Installation
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/nexis-hypervisor

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/nexis-install.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

cat > "$ISO_SRC/nexis/nexis-firstboot.service" << 'SVC'
[Unit]
Description=NeXiS Hypervisor First-Boot Configuration
After=nexis-install.service
Wants=nexis-install.service
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

# ── 4. Preseed ────────────────────────────────────────────────────────────────

cat > "$ISO_SRC/nexis/preseed.cfg" << 'PRESEED'
# NeXiS Hypervisor preseed — auto-fills installer defaults
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string nexis-node
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i clock-setup/ntp boolean true
d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl git python3 python3-pip python3-venv ca-certificates
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default
d-i preseed/late_command string \
    mkdir -p /target/opt /target/usr/local/bin /target/etc/systemd/system ; \
    cp /cdrom/nexis/install.sh /target/opt/nexis-install.sh ; \
    cp /cdrom/nexis/firstboot-tui.py /target/usr/local/bin/nexis-firstboot ; \
    chmod +x /target/opt/nexis-install.sh /target/usr/local/bin/nexis-firstboot ; \
    cp /cdrom/nexis/nexis-install.service /target/etc/systemd/system/ ; \
    cp /cdrom/nexis/nexis-firstboot.service /target/etc/systemd/system/ ; \
    in-target systemctl enable nexis-install.service nexis-firstboot.service
d-i finish-install/reboot_in_progress note
PRESEED

# ── 5. GRUB config — UEFI boot ────────────────────────────────────────────────
# GRUB is used when booting in UEFI mode.

for grub_cfg in \
    "$ISO_SRC/boot/grub/grub.cfg" \
    "$ISO_SRC/EFI/boot/grub.cfg" \
    "$ISO_SRC/boot/grub/x86_64-efi/grub.cfg"
do
    [[ -f "$grub_cfg" ]] || continue
    cat > "$grub_cfg" << 'GRUB'
# NeXiS Hypervisor Boot Configuration
set timeout=8
set default=0

# GRUB text colors (yellow = closest GRUB standard color to #F87200 orange)
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor" {
    linux   /install.amd/vmlinuz auto=true file=/cdrom/nexis/preseed.cfg vga=788 quiet ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor  [graphical]" {
    linux   /install.amd/vmlinuz auto=true file=/cdrom/nexis/preseed.cfg vga=788 DEBIAN_FRONTEND=gtk quiet ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor  [expert / manual]" {
    linux   /install.amd/vmlinuz priority=low vga=788 ---
    initrd  /install.amd/initrd.gz
}
menuentry "Boot from existing OS" {
    set root=(hd0)
    chainloader +1
}
GRUB
    _ok "Patched GRUB: $grub_cfg"
done

# ── 6. Syslinux/isolinux config — BIOS boot ───────────────────────────────────
# Syslinux is used when booting in legacy BIOS mode.
# vesamenu.c32 supports #AARRGGBB colors — we use full NeXiS orange.

ISOCFG="$ISO_SRC/isolinux"
[[ -d "$ISOCFG" ]] || { _ok "No isolinux dir — BIOS boot not configured (UEFI only)"; }

if [[ -d "$ISOCFG" ]]; then

cat > "$ISOCFG/isolinux.cfg" << 'ISOCFG_CONTENT'
# NeXiS Hypervisor — BIOS Boot Menu
UI vesamenu.c32
DEFAULT nexis-install
PROMPT 0
TIMEOUT 80

MENU TITLE NeXiS Hypervisor
MENU BACKGROUND /isolinux/splash.png

# NeXiS color scheme — dark background, orange accent
MENU COLOR screen      37;40  #ffc4b898 #ff080807 std
MENU COLOR border      37;40  #ff2a2a1a #ff080807 std
MENU COLOR title       1;37;40 #fff87200 #ff080807 std
MENU COLOR sel         7;37;40 #ff000000 #fff87200 std
MENU COLOR unsel       37;40  #ffc4b898 #ff0d0d0a std
MENU COLOR hotsel      1;37;40 #fff87200 #ff080807 std
MENU COLOR hotkey      1;37;40 #fff87200 #ff080807 std
MENU COLOR help        37;40  #ff887766 #ff080807 std
MENU COLOR timeout_msg 37;40  #ff2a2a1a #ff080807 std
MENU COLOR timeout     1;37;40 #fff87200 #ff080807 std
MENU COLOR tabmsg      37;40  #ff2a2a1a #ff080807 std
MENU COLOR cmdmark     1;37;40 #fff87200 #ff080807 std
MENU COLOR cmdline     37;40  #ffc4b898 #ff080807 std
MENU COLOR scrollbar   37;40  #ff2a2a1a #ff080807 std

LABEL nexis-install
  MENU LABEL Install NeXiS Hypervisor
  KERNEL /install.amd/vmlinuz
  APPEND auto=true file=/cdrom/nexis/preseed.cfg vga=788 initrd=/install.amd/initrd.gz quiet ---

LABEL nexis-graphical
  MENU LABEL Install NeXiS Hypervisor  [graphical]
  KERNEL /install.amd/vmlinuz
  APPEND auto=true file=/cdrom/nexis/preseed.cfg vga=788 DEBIAN_FRONTEND=gtk initrd=/install.amd/initrd.gz quiet ---

LABEL nexis-expert
  MENU LABEL Install NeXiS Hypervisor  [expert / manual]
  KERNEL /install.amd/vmlinuz
  APPEND priority=low vga=788 initrd=/install.amd/initrd.gz ---
ISOCFG_CONTENT

    # Generate a minimal splash: dark PNG (vesamenu.c32 needs one or shows white)
    # Use python3 to create a 640x480 dark PNG
    python3 - << 'PYEOF'
import struct, zlib
def _png(w, h, rows):
    def ch(t, d):
        c = zlib.crc32(t + d) & 0xffffffff
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', c)
    raw = b''.join(b'\x00' + r for r in rows)
    return (b'\x89PNG\r\n\x1a\n'
            + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(raw, 1))
            + ch(b'IEND', b''))
W, H = 640, 480
dark = bytes([0x08, 0x08, 0x07])
rows = [dark * W for _ in range(H)]
open('/tmp/nexis-iso-splash.png', 'wb').write(_png(W, H, rows))
PYEOF
    cp /tmp/nexis-iso-splash.png "$ISOCFG/splash.png" 2>/dev/null || true
    _ok "Patched syslinux: $ISOCFG/isolinux.cfg"

fi

# ── 7. Repack ISO ─────────────────────────────────────────────────────────────
# Preserve the original MBR boot record and EFI image from the Debian ISO.

FINAL="${OUTPUT_DIR}/nexis-hypervisor-${VERSION}-amd64.iso"
_print "Repacking ISO..."

# Extract the MBR boot record (first 432 bytes) from the original ISO
dd if="$DEBIAN_ISO" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" 2>/dev/null

# Find the EFI system partition image
EFI_IMG=""
for p in "$ISO_SRC/boot/grub/efi.img" "$ISO_SRC/EFI/boot/bootx64.efi"; do
    [[ -f "$p" ]] && { EFI_IMG="$p"; break; }
done

xorriso -as mkisofs \
    -r \
    -V "${ISO_VOLUME}" \
    -o "$FINAL" \
    -J --joliet-long \
    -isohybrid-mbr "${WORK_DIR}/isohdpfx.bin" \
    -partition_offset 16 \
    -A "NeXiS Hypervisor ${VERSION}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_SRC/" \
    2>&1 | grep -v "^xorriso" || true

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO: $FINAL"
_ok "Size: $(du -h "$FINAL" | cut -f1)"
_ok "SHA256: $SHA"
_print "Write to USB: dd if='$FINAL' of=/dev/sdX bs=4M status=progress"
