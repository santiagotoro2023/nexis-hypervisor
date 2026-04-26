#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# 1. Downloads the official Debian netinst ISO from cdimage.debian.org
# 2. Injects preseed.cfg into the installer's initrd (cpio-prepend method
#    from the Debian wiki) so it applies automatically on every boot entry
# 3. Patches GRUB (UEFI) and syslinux (BIOS) menus:
#      - Adds nomodeset  (prevents nouveau GPU hang on NVIDIA hardware)
#      - Renames entries to "NeXiS Hypervisor vX.Y.Z"
# 4. Adds /nexis/ directory with install.sh and service files
# 5. Produces a valid hybrid ISO (BIOS + UEFI) using xorriso
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
DEBIAN_BASE="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "run as root"
apt-get install -yq xorriso cpio gzip curl 2>/dev/null | tail -1

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Download ───────────────────────────────────────────────────────────────

DEBIAN_ISO="$WORK_DIR/debian-netinst.iso"
if [[ ! -f "$DEBIAN_ISO" ]]; then
    _print "Finding current Debian netinst filename…"
    FNAME=$(curl -fsSL "${DEBIAN_BASE}/SHA256SUMS" \
        | grep -oP 'debian-[\d.]++-amd64-netinst\.iso' | head -1)
    [[ -z "$FNAME" ]] && _err "Could not find Debian ISO in SHA256SUMS"
    _print "Downloading $FNAME …"
    curl -fL --progress-bar "${DEBIAN_BASE}/${FNAME}" -o "$DEBIAN_ISO"
    _ok "$FNAME ($(du -h "$DEBIAN_ISO" | cut -f1))"
fi

# ── 2. Extract ISO ────────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
_print "Extracting ISO…"
rm -rf "$ISO_SRC" && mkdir -p "$ISO_SRC"
xorriso -osirrox on -indev "$DEBIAN_ISO" -extract / "$ISO_SRC/" 2>/dev/null
chmod -R u+w "$ISO_SRC"
_ok "Extracted to $ISO_SRC"

# ── 3. Build /nexis/ directory (accessible as /cdrom/nexis/ during install) ───

NEXIS_DIR="$ISO_SRC/nexis"
mkdir -p "$NEXIS_DIR"

cp "$REPO_DIR/install.sh"         "$NEXIS_DIR/"
cp "$SCRIPT_DIR/firstboot-tui.py" "$NEXIS_DIR/"

cat > "$NEXIS_DIR/nexis-install.service" << 'EOF'
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
EOF

cat > "$NEXIS_DIR/nexis-firstboot.service" << 'EOF'
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
EOF

# ── 4. Write preseed.cfg ──────────────────────────────────────────────────────

cat > "$NEXIS_DIR/preseed.cfg" << 'EOF'
# NeXiS Hypervisor preseed — minimal, non-intrusive
#
# Only pre-selects keyboard (Swiss German) and timezone.
# Every other installer question appears and works normally.
# The installer asks about language, disk, root password, user, packages, etc.

# Swiss German keyboard — pre-selected, user can still change it
d-i keyboard-configuration/xkb-keymap select ch
d-i keyboard-configuration/layoutcode string ch

# Switzerland timezone — pre-selected
d-i clock-setup/utc boolean true
d-i time/zone string Europe/Zurich

# After the user finishes the installation, copy NeXiS scripts into the
# installed system. These set up the hypervisor stack on first boot.
d-i preseed/late_command string \
    mkdir -p /target/opt /target/usr/local/bin /target/etc/systemd/system ; \
    cp /cdrom/nexis/install.sh /target/opt/nexis-install.sh ; \
    cp /cdrom/nexis/firstboot-tui.py /target/usr/local/bin/nexis-firstboot ; \
    chmod +x /target/opt/nexis-install.sh /target/usr/local/bin/nexis-firstboot ; \
    cp /cdrom/nexis/nexis-install.service /target/etc/systemd/system/ ; \
    cp /cdrom/nexis/nexis-firstboot.service /target/etc/systemd/system/ ; \
    in-target systemctl enable nexis-install.service nexis-firstboot.service
EOF

# ── 5. Patch GRUB config (UEFI boot) ─────────────────────────────────────────
# preseed loaded via file= kernel parameter — the installer still asks ALL
# questions interactively; only the values listed in preseed.cfg are pre-filled.
# No preseed in initrd (that causes auto-mode and skipped screens).

GRUB_CFG="$ISO_SRC/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
    cat > "$GRUB_CFG" << EOF
# NeXiS Hypervisor ${VERSION}
set default=0
set timeout=8
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor ${VERSION}" {
    linux   /install.amd/vmlinuz nomodeset file=/cdrom/nexis/preseed.cfg ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor ${VERSION}  [graphical]" {
    linux   /install.amd/vmlinuz DEBIAN_FRONTEND=gtk nomodeset file=/cdrom/nexis/preseed.cfg ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor ${VERSION}  [no preseed / standard Debian]" {
    linux   /install.amd/vmlinuz nomodeset ---
    initrd  /install.amd/initrd.gz
}
EOF
    _ok "GRUB config patched"
fi

EFI_CFG="$ISO_SRC/EFI/boot/grub.cfg"
[[ -f "$EFI_CFG" ]] && cp "$GRUB_CFG" "$EFI_CFG"

# ── 6. Patch syslinux/isolinux config (BIOS boot) ────────────────────────────

TXT_CFG="$ISO_SRC/isolinux/txt.cfg"
if [[ -f "$TXT_CFG" ]]; then
    cat > "$TXT_CFG" << EOF
default install
label install
    menu label Install NeXiS Hypervisor ${VERSION}
    kernel /install.amd/vmlinuz
    append nomodeset file=/cdrom/nexis/preseed.cfg initrd=/install.amd/initrd.gz ---
label installgui
    menu label Install NeXiS Hypervisor ${VERSION}  [graphical]
    kernel /install.amd/vmlinuz
    append DEBIAN_FRONTEND=gtk nomodeset file=/cdrom/nexis/preseed.cfg initrd=/install.amd/initrd.gz ---
label standard
    menu label Install NeXiS Hypervisor ${VERSION}  [no preseed / standard Debian]
    kernel /install.amd/vmlinuz
    append nomodeset initrd=/install.amd/initrd.gz ---
EOF
    _ok "syslinux txt.cfg patched"
fi

# gtk.cfg — graphical installer entries (if present)
GTK_CFG="$ISO_SRC/isolinux/gtk.cfg"
[[ -f "$GTK_CFG" ]] && cp "$TXT_CFG" "$GTK_CFG"

# stdmenu.cfg — colors
STDMENU="$ISO_SRC/isolinux/stdmenu.cfg"
if [[ -f "$STDMENU" ]]; then
    cat > "$STDMENU" << 'EOF'
menu color title    1;37;40 #fff87200 #ff080807 std
menu color sel      7;37;40 #ff000000 #fff87200 std
menu color unsel    37;40   #ffc4b898 #ff080807 std
menu color border   37;40   #ff2a2a1a #ff080807 std
menu color hotkey   1;37;40 #fff87200 #ff080807 std
menu color tabmsg   37;40   #ff887766 #ff080807 std
EOF
    _ok "syslinux colors patched"
fi

# menu.cfg — title
MENU_CFG="$ISO_SRC/isolinux/menu.cfg"
if [[ -f "$MENU_CFG" ]]; then
    sed -i "s/^menu title.*/menu title NeXiS Hypervisor ${VERSION}/" "$MENU_CFG"
    _ok "syslinux title patched"
fi

# ── 8. Repack ISO ─────────────────────────────────────────────────────────────
# Extract the MBR bootstrap record (first 432 bytes) from the original Debian
# ISO — this is needed to make the USB stick bootable in legacy BIOS mode.

_print "Building ISO…"
dd if="$DEBIAN_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

# Find EFI image location — Debian stores it as part of the boot catalog
EFI_IMG="$ISO_SRC/boot/grub/efi.img"
[[ -f "$EFI_IMG" ]] || _err "EFI image not found: $EFI_IMG"

xorriso -as mkisofs \
    -r \
    -V "$ISO_VOLUME" \
    -o "$FINAL" \
    -J -joliet-long \
    -isohybrid-mbr "$WORK_DIR/mbr.bin" \
    -partition_offset 16 \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
        -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_SRC/"

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"
_ok "ISO: $FINAL"
_ok "Size: $(du -h "$FINAL" | cut -f1)"
_ok "SHA256: $SHA"
_print "Write to USB:  dd if=$(basename "$FINAL") of=/dev/sdX bs=4M status=progress"
