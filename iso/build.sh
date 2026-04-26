#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Downloads the official Debian 12 netinst ISO and patches it in-place
# using xorriso's native mode. Preserves all boot records (MBR + EFI)
# without any extract/repack. Works in both BIOS and UEFI.
#
# Key: nomodeset on all kernel entries prevents nouveau from loading,
# which avoids the firmware-error hang on NVIDIA hardware.
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"
DEBIAN_BASE="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

_print() { printf '\033[38;5;208m[nexis-iso]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "Must run as root."
command -v xorriso &>/dev/null || apt-get install -yq xorriso 2>/dev/null
command -v curl    &>/dev/null || apt-get install -yq curl    2>/dev/null

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Download Debian 12 netinst ─────────────────────────────────────────────

DEBIAN_ISO="${WORK_DIR}/debian-netinst.iso"
if [[ ! -f "$DEBIAN_ISO" ]]; then
    _print "Finding current Debian 12 netinst filename..."
    DEBIAN_FNAME=$(curl -fsSL "${DEBIAN_BASE}/SHA256SUMS" \
        | grep -o 'debian-[0-9][0-9.]*-amd64-netinst\.iso' | head -1)
    [[ -z "$DEBIAN_FNAME" ]] && _err "Could not determine Debian ISO filename from SHA256SUMS"
    _print "Downloading ${DEBIAN_FNAME}..."
    curl -fL --progress-bar "${DEBIAN_BASE}/${DEBIAN_FNAME}" -o "$DEBIAN_ISO"
    _ok "Downloaded: $(du -h "$DEBIAN_ISO" | cut -f1)"
else
    _ok "Debian ISO cached: $DEBIAN_ISO"
fi

# ── 2. Create patch files ─────────────────────────────────────────────────────

# GRUB config — UEFI boot
# nomodeset stops the kernel from loading GPU drivers (fixes nouveau hang)
cat > "$WORK_DIR/grub.cfg" << 'EOF'
# NeXiS Hypervisor Boot Configuration
set timeout=8
set default=0
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor" {
    linux   /install.amd/vmlinuz auto=true file=/cdrom/nexis/preseed.cfg vga=788 nomodeset quiet ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor  [graphical]" {
    linux   /install.amd/vmlinuz auto=true file=/cdrom/nexis/preseed.cfg vga=788 DEBIAN_FRONTEND=gtk nomodeset quiet ---
    initrd  /install.amd/initrd.gz
}
menuentry "Install NeXiS Hypervisor  [expert]" {
    linux   /install.amd/vmlinuz priority=low nomodeset vga=788 ---
    initrd  /install.amd/initrd.gz
}
EOF

# Syslinux menu entries — BIOS boot (txt.cfg)
cat > "$WORK_DIR/txt.cfg" << 'EOF'
default nexis-install
label nexis-install
    menu label Install NeXiS Hypervisor
    kernel /install.amd/vmlinuz
    append auto=true file=/cdrom/nexis/preseed.cfg vga=788 nomodeset initrd=/install.amd/initrd.gz quiet ---
label nexis-graphical
    menu label Install NeXiS Hypervisor  [graphical]
    kernel /install.amd/vmlinuz
    append auto=true file=/cdrom/nexis/preseed.cfg vga=788 DEBIAN_FRONTEND=gtk nomodeset initrd=/install.amd/initrd.gz quiet ---
label nexis-expert
    menu label Install NeXiS Hypervisor  [expert]
    kernel /install.amd/vmlinuz
    append priority=low nomodeset vga=788 initrd=/install.amd/initrd.gz ---
EOF

# Syslinux color theme — BIOS boot (stdmenu.cfg)
# #AARRGGBB format: FF = fully opaque
cat > "$WORK_DIR/stdmenu.cfg" << 'EOF'
menu color screen       37;40 #ffc4b898 #ff080807 std
menu color border       37;40 #ff2a2a1a #ff080807 std
menu color title        1;37;40 #fff87200 #ff080807 std
menu color sel          7;37;40 #ff000000 #fff87200 std
menu color unsel        37;40 #ffc4b898 #ff0d0d0a std
menu color hotsel       1;7;37;40 #ff000000 #fff87200 std
menu color hotkey       1;37;40 #fff87200 #ff080807 std
menu color tabmsg       37;40 #ff887766 #ff080807 std
menu color timeout_msg  37;40 #ff2a2a1a #ff080807 std
menu color timeout      1;37;40 #fff87200 #ff080807 std
menu color disabled     37;40 #ff2a2a1a #ff080807 std
menu color scrollbar    37;40 #ff2a2a1a #ff080807 std
EOF

# Syslinux menu title (menu.cfg)
cat > "$WORK_DIR/menu.cfg" << 'EOF'
menu hshift 13
menu width 49
include stdmenu.cfg
menu title NeXiS Hypervisor
include txt.cfg
EOF

# ── 3. Build the /nexis/ directory ────────────────────────────────────────────

mkdir -p "$WORK_DIR/nexis"
cp "$REPO_DIR/install.sh"         "$WORK_DIR/nexis/"
cp "$SCRIPT_DIR/firstboot-tui.py" "$WORK_DIR/nexis/"

cat > "$WORK_DIR/nexis/preseed.cfg" << 'EOF'
# NeXiS Hypervisor preseed
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
EOF

cat > "$WORK_DIR/nexis/nexis-install.service" << 'EOF'
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

cat > "$WORK_DIR/nexis/nexis-firstboot.service" << 'EOF'
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

# ── 4. Patch ISO with xorriso ─────────────────────────────────────────────────
# Native xorriso mode: -indev reads the original, -outdev writes the result.
# -boot_image any keep preserves ALL boot records (MBR hybrid + EFI) exactly.
# -update replaces existing ISO files with our patched versions.
# -map adds the new /nexis/ directory.
# No extract/repack needed — zero risk of corrupted boot records.

FINAL="${OUTPUT_DIR}/nexis-hypervisor-${VERSION}-amd64.iso"
_print "Patching ISO (preserving boot records)..."

xorriso \
    -indev  "$DEBIAN_ISO" \
    -outdev "$FINAL" \
    -return_with SORRY 0 \
    -boot_image any keep \
    -volid  "$ISO_VOLUME" \
    -update "$WORK_DIR/grub.cfg"    /boot/grub/grub.cfg \
    -update "$WORK_DIR/txt.cfg"     /isolinux/txt.cfg \
    -update "$WORK_DIR/stdmenu.cfg" /isolinux/stdmenu.cfg \
    -update "$WORK_DIR/menu.cfg"    /isolinux/menu.cfg \
    -map    "$WORK_DIR/nexis"       /nexis \
    -commit

SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO: $FINAL"
_ok "Size: $(du -h "$FINAL" | cut -f1)"
_ok "SHA256: $SHA"
_print "Write to USB: dd if='$FINAL' of=/dev/sdX bs=4M status=progress"
