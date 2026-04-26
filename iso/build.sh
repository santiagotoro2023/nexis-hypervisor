#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Strategy: download official Debian netinst ISO, patch only the specific
# files that need changing using xorriso -indev/-outdev (preserves every
# boot record from the original ISO byte-for-byte), inject preseed into
# initrd via cpio-prepend so NeXiS services are set up after installation.
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

# ── 1. Download Debian netinst ────────────────────────────────────────────────

DEBIAN_ISO="$WORK_DIR/debian-netinst.iso"
if [[ ! -f "$DEBIAN_ISO" ]]; then
    _print "Finding Debian ISO filename…"
    FNAME=$(curl -fsSL "${DEBIAN_BASE}/SHA256SUMS" \
        | grep -oP 'debian-[\d.]+-amd64-netinst\.iso' | head -1)
    [[ -z "$FNAME" ]] && _err "Could not find Debian ISO in SHA256SUMS"
    _print "Downloading $FNAME…"
    curl -fL "${DEBIAN_BASE}/${FNAME}" -o "$DEBIAN_ISO"
    _ok "$FNAME ($(du -h "$DEBIAN_ISO" | cut -f1))"
fi

# ── 2. Extract initrd so we can patch it ─────────────────────────────────────

_print "Extracting initrd…"
xorriso -osirrox on -indev "$DEBIAN_ISO" \
    -extract install.amd/initrd.gz "$WORK_DIR/initrd.gz" 2>/dev/null
_ok "initrd extracted"

# ── 3. Inject preseed into initrd (cpio-prepend) ─────────────────────────────
# Prepend a tiny cpio containing ONLY the late_command preseed.
# The installer asks every question normally; late_command runs at the end.

mkdir -p "$WORK_DIR/cpio-root"
cat > "$WORK_DIR/cpio-root/preseed.cfg" << 'PRESEED'
d-i preseed/late_command string \
    mkdir -p /target/opt /target/usr/local/bin /target/etc/systemd/system ; \
    cp /cdrom/nexis/install.sh          /target/opt/nexis-install.sh ; \
    cp /cdrom/nexis/firstboot-tui.py    /target/usr/local/bin/nexis-firstboot ; \
    chmod +x /target/opt/nexis-install.sh /target/usr/local/bin/nexis-firstboot ; \
    cp /cdrom/nexis/nexis-install.service   /target/etc/systemd/system/ ; \
    cp /cdrom/nexis/nexis-firstboot.service /target/etc/systemd/system/ ; \
    in-target systemctl enable nexis-install.service nexis-firstboot.service
PRESEED

(cd "$WORK_DIR/cpio-root" && echo preseed.cfg | cpio -o -H newc 2>/dev/null) \
    > "$WORK_DIR/preseed.cpio"
cat "$WORK_DIR/preseed.cpio" "$WORK_DIR/initrd.gz" > "$WORK_DIR/initrd-patched.gz"
_ok "Preseed injected into initrd"

# ── 4. Write patched GRUB config (UEFI boot) ─────────────────────────────────

cat > "$WORK_DIR/grub.cfg" << EOF
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
    linux  /install.amd/vmlinuz nomodeset ---
    initrd /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor ${VERSION}  [graphical]" {
    linux  /install.amd/vmlinuz DEBIAN_FRONTEND=gtk nomodeset ---
    initrd /install.amd/initrd.gz
}
menuentry "Standard Debian install (no NeXiS)" {
    linux  /install.amd/vmlinuz nomodeset ---
    initrd /install.amd/initrd.gz
}
EOF

# ── 5. Write patched syslinux txt.cfg (BIOS boot) ────────────────────────────

cat > "$WORK_DIR/txt.cfg" << EOF
default install
label install
    menu label Install NeXiS Hypervisor ${VERSION}
    kernel /install.amd/vmlinuz
    append nomodeset initrd=/install.amd/initrd.gz ---
label installgui
    menu label Install NeXiS Hypervisor ${VERSION}  [graphical]
    kernel /install.amd/vmlinuz
    append DEBIAN_FRONTEND=gtk nomodeset initrd=/install.amd/initrd.gz ---
label vanilla
    menu label Standard Debian install (no NeXiS)
    kernel /install.amd/vmlinuz
    append nomodeset initrd=/install.amd/initrd.gz ---
EOF

# ── 6. Build /nexis/ directory ────────────────────────────────────────────────

NEXIS_STAGE="$WORK_DIR/nexis"
mkdir -p "$NEXIS_STAGE"
cp "$REPO_DIR/install.sh"         "$NEXIS_STAGE/"
cp "$SCRIPT_DIR/firstboot-tui.py" "$NEXIS_STAGE/"

cat > "$NEXIS_STAGE/nexis-install.service" << 'EOF'
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

cat > "$NEXIS_STAGE/nexis-firstboot.service" << 'EOF'
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

# ── 7. Patch ISO with xorriso -indev/-outdev ──────────────────────────────────
# This mode reads the original Debian ISO and writes a new one, updating only
# the files we specify. Every boot record (MBR, EFI, El Torito) is preserved
# exactly — no risk of corrupting the boot setup that already works in Debian.

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
_print "Patching ISO…"

xorriso \
    -indev  "$DEBIAN_ISO" \
    -outdev "$FINAL" \
    -return_with SORRY 0 \
    -boot_image any keep \
    -volid  "NEXIS_HV_${VERSION//./_}" \
    -update "$WORK_DIR/initrd-patched.gz"  /install.amd/initrd.gz \
    -update "$WORK_DIR/grub.cfg"           /boot/grub/grub.cfg \
    -update "$WORK_DIR/txt.cfg"            /isolinux/txt.cfg \
    -map    "$NEXIS_STAGE"                 /nexis \
    -commit

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"
_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_ok "SHA256: $SHA"
_print "Write: dd if=$(basename "$FINAL") of=/dev/sdX bs=4M status=progress && sync"
