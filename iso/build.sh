#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
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

# ── 1. Download official Debian netinst ISO ───────────────────────────────────

DEBIAN_ISO="$WORK_DIR/debian-netinst.iso"
if [[ ! -f "$DEBIAN_ISO" ]]; then
    _print "Finding Debian netinst filename…"
    FNAME=$(curl -fsSL "${DEBIAN_BASE}/SHA256SUMS" \
        | grep -oP 'debian-[\d.]+-amd64-netinst\.iso' | head -1)
    [[ -z "$FNAME" ]] && _err "Could not find Debian ISO in SHA256SUMS"
    _print "Downloading $FNAME …"
    curl -fL "${DEBIAN_BASE}/${FNAME}" -o "$DEBIAN_ISO"
    _ok "$FNAME"
fi

# ── 2. Extract ISO ────────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
_print "Extracting…"
rm -rf "$ISO_SRC" && mkdir -p "$ISO_SRC"
xorriso -osirrox on -indev "$DEBIAN_ISO" -extract / "$ISO_SRC/" 2>/dev/null
chmod -R u+w "$ISO_SRC"

# ── 3. Add /nexis/ with NeXiS scripts ────────────────────────────────────────

mkdir -p "$ISO_SRC/nexis"
cp "$REPO_DIR/install.sh"         "$ISO_SRC/nexis/"
cp "$SCRIPT_DIR/firstboot-tui.py" "$ISO_SRC/nexis/"

cat > "$ISO_SRC/nexis/nexis-install.service" << 'EOF'
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

cat > "$ISO_SRC/nexis/nexis-firstboot.service" << 'EOF'
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

# ── 4. Inject preseed into initrd (cpio-prepend, late_command only) ───────────
# Only the late_command is preseeded — the installer asks EVERY question
# interactively. No keyboard, no timezone, no partitioning pre-selected.
# The cpio-prepend puts preseed.cfg at the root of the initrd; the Debian
# installer finds it automatically without needing file= or auto= parameters.

cat > "$WORK_DIR/preseed.cfg" << 'EOF'
# NeXiS Hypervisor preseed — late_command only, nothing pre-selected.
# The installer asks every single question interactively.
d-i preseed/late_command string \
    mkdir -p /target/opt /target/usr/local/bin /target/etc/systemd/system ; \
    cp /cdrom/nexis/install.sh /target/opt/nexis-install.sh ; \
    cp /cdrom/nexis/firstboot-tui.py /target/usr/local/bin/nexis-firstboot ; \
    chmod +x /target/opt/nexis-install.sh /target/usr/local/bin/nexis-firstboot ; \
    cp /cdrom/nexis/nexis-install.service /target/etc/systemd/system/ ; \
    cp /cdrom/nexis/nexis-firstboot.service /target/etc/systemd/system/ ; \
    in-target systemctl enable nexis-install.service nexis-firstboot.service
EOF

INITRD="$ISO_SRC/install.amd/initrd.gz"
[[ -f "$INITRD" ]] || _err "initrd not found at install.amd/initrd.gz"

INJECT="$WORK_DIR/initrd-inject"
rm -rf "$INJECT" && mkdir -p "$INJECT"
cp "$WORK_DIR/preseed.cfg" "$INJECT/preseed.cfg"
(cd "$INJECT" && echo preseed.cfg | cpio -o -H newc 2>/dev/null) \
    > "$WORK_DIR/preseed.cpio"
cat "$WORK_DIR/preseed.cpio" "$INITRD" > "$WORK_DIR/initrd-new.gz"
cp "$WORK_DIR/initrd-new.gz" "$INITRD"
_ok "Preseed (late_command only) injected into initrd"

# ── 5. GRUB config — UEFI ────────────────────────────────────────────────────
# timeout_style=menu  → always show the menu, never auto-boot silently
# timeout=30          → 30-second countdown (press any key to stop)
# nomodeset           → stop nouveau crashing on NVIDIA (firmware not needed)
# NO nofb             → keep EFI framebuffer so the screen shows content

GRUB_CFG="$ISO_SRC/boot/grub/grub.cfg"
[[ -f "$GRUB_CFG" ]] && cat > "$GRUB_CFG" << EOF
# NeXiS Hypervisor ${VERSION}
insmod all_video
set timeout_style=menu
set default=0
set timeout=30
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor ${VERSION}" {
    linux   /install.amd/vmlinuz nomodeset consoleblank=0 ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor ${VERSION}  [graphical]" {
    linux   /install.amd/vmlinuz DEBIAN_FRONTEND=gtk nomodeset consoleblank=0 ---
    initrd  /install.amd/initrd.gz
}
menuentry "Vanilla Debian install (no NeXiS)" {
    linux   /install.amd/vmlinuz nomodeset consoleblank=0 ---
    initrd  /install.amd/initrd.gz
}
EOF
_ok "GRUB config written"

EFI_CFG="$ISO_SRC/EFI/boot/grub.cfg"
[[ -f "$EFI_CFG" ]] && cp "$GRUB_CFG" "$EFI_CFG"

# ── 6. Syslinux — BIOS ───────────────────────────────────────────────────────

TXT_CFG="$ISO_SRC/isolinux/txt.cfg"
[[ -f "$TXT_CFG" ]] && cat > "$TXT_CFG" << EOF
default install
label install
    menu label Install NeXiS Hypervisor ${VERSION}
    kernel /install.amd/vmlinuz
    append nomodeset consoleblank=0 initrd=/install.amd/initrd.gz ---
label installgui
    menu label Install NeXiS Hypervisor ${VERSION}  [graphical]
    kernel /install.amd/vmlinuz
    append DEBIAN_FRONTEND=gtk nomodeset consoleblank=0 initrd=/install.amd/initrd.gz ---
label vanilla
    menu label Vanilla Debian install (no NeXiS)
    kernel /install.amd/vmlinuz
    append nomodeset consoleblank=0 initrd=/install.amd/initrd.gz ---
EOF

GTK_CFG="$ISO_SRC/isolinux/gtk.cfg"
[[ -f "$GTK_CFG" ]] && cp "$TXT_CFG" "$GTK_CFG"

STDMENU="$ISO_SRC/isolinux/stdmenu.cfg"
[[ -f "$STDMENU" ]] && cat > "$STDMENU" << 'EOF'
menu color title    1;37;40 #fff87200 #ff080807 std
menu color sel      7;37;40 #ff000000 #fff87200 std
menu color unsel    37;40   #ffc4b898 #ff080807 std
menu color border   37;40   #ff2a2a1a #ff080807 std
menu color hotkey   1;37;40 #fff87200 #ff080807 std
menu color tabmsg   37;40   #ff887766 #ff080807 std
EOF

MENU_CFG="$ISO_SRC/isolinux/menu.cfg"
[[ -f "$MENU_CFG" ]] && \
    sed -i "s/^menu title.*/menu title NeXiS Hypervisor ${VERSION}/" "$MENU_CFG"

# Increase syslinux timeout (unit = 1/10 sec; 300 = 30 seconds)
ISOLINUX_CFG="$ISO_SRC/isolinux/isolinux.cfg"
[[ -f "$ISOLINUX_CFG" ]] && \
    sed -i 's/^timeout.*/timeout 300/' "$ISOLINUX_CFG" || true

_ok "Syslinux config written"

# ── 7. Repack ─────────────────────────────────────────────────────────────────

_print "Repacking ISO…"
dd if="$DEBIAN_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

xorriso -as mkisofs \
    -r -V "$ISO_VOLUME" \
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
_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_print "Write: dd if=$(basename "$FINAL") of=/dev/sdX bs=4M status=progress"
