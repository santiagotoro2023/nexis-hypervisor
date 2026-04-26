#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Strategy: download Debian 12 (bookworm) netinst, add a single NeXiS boot
# entry with auto=true priority=critical, and a complete preseed that drives
# the Debian installer fully automatically. No live system. No custom UI.
# No framebuffer. No X11. The Debian text installer runs headlessly, which
# works on literally any hardware including NVIDIA machines.
#
# User experience:
#   Boot → NeXiS GRUB menu (8 s timeout) → installation runs automatically
#   (~15 min, progress shown as text) → reboot → firstboot TUI → web UI
#
# Must run as root in a Debian/Ubuntu environment.
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/.work"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

DEBIAN_BASE="https://cdimage.debian.org/debian-cd/current-oldstable/amd64/iso-cd"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "run as root"
apt-get install -yq xorriso python3 curl 2>/dev/null | tail -1
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# ── 1. Download Debian 12 netinst ─────────────────────────────────────────────

DEBIAN_ISO="$WORK_DIR/debian-netinst.iso"
if [[ ! -f "$DEBIAN_ISO" ]]; then
    _print "Finding Debian 12 netinst filename…"
    FNAME=$(curl -sSL "${DEBIAN_BASE}/SHA256SUMS" \
        | grep -oP 'debian-12[\d.]+-amd64-netinst\.iso' | head -1)
    [[ -z "$FNAME" ]] && _err "Could not find Debian 12 ISO at $DEBIAN_BASE"
    _print "Downloading $FNAME…"
    curl -fL "${DEBIAN_BASE}/${FNAME}" -o "$DEBIAN_ISO"
    _ok "$FNAME ($(du -h "$DEBIAN_ISO" | cut -f1))"
fi

# ── 2. Extract ISO ────────────────────────────────────────────────────────────

ISO_SRC="$WORK_DIR/iso-src"
_print "Extracting ISO…"
rm -rf "$ISO_SRC" && mkdir -p "$ISO_SRC"
xorriso -osirrox on -indev "$DEBIAN_ISO" -extract / "$ISO_SRC/" 2>/dev/null
chmod -R u+w "$ISO_SRC"

# Verify the installer kernel exists
[[ -f "$ISO_SRC/install.amd/vmlinuz" ]] \
    || _err "Installer kernel not found — unexpected ISO structure"
_ok "Extracted"

# ── 3. Write preseed ──────────────────────────────────────────────────────────
# auto=true priority=critical is passed as a kernel parameter.
# The installer runs completely headlessly. The ONLY question it might ask
# is disk selection if multiple disks are detected — in basic VGA text mode,
# which always works regardless of GPU.

mkdir -p "$ISO_SRC/nexis"

# Root password hash for "Asdf1234!" — same default as NeXiS web UI
ROOT_HASH=$(python3 -c \
    "import crypt; print(crypt.crypt('Asdf1234!', crypt.mksalt(crypt.METHOD_SHA512)))" \
    2>/dev/null || echo "")

cat > "$ISO_SRC/nexis/preseed.cfg" << PRESEED
# NeXiS Hypervisor preseed — fully automated installation
# Kernel parameter: auto=true priority=critical
# This drives the Debian installer headlessly without any interactive screens.

d-i debian-installer/locale            string  en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select  us
d-i netcfg/choose_interface            select  auto
d-i netcfg/get_hostname                string  nexis-node
d-i netcfg/get_domain                  string  local
d-i netcfg/wireless_wep                string
d-i mirror/country                     string  manual
d-i mirror/http/hostname               string  deb.debian.org
d-i mirror/http/directory              string  /debian
d-i mirror/http/proxy                  string
d-i clock-setup/utc                    boolean true
d-i time/zone                          string  UTC
d-i clock-setup/ntp                    boolean true

# Erase the entire disk and use LVM. The installer picks the disk
# automatically on single-disk systems; asks in text mode if multiple.
d-i partman-auto/method                string  lvm
d-i partman-auto-lvm/guided_size       string  max
d-i partman-auto/choose_recipe         select  atomic
d-i partman/confirm_write_new_label    boolean true
d-i partman/choose_partition           select  finish
d-i partman/confirm                    boolean true
d-i partman/confirm_nooverwrite        boolean true

# Root account — password "Asdf1234!" (same as NeXiS web UI default)
# The firstboot TUI can be used to change this.
d-i passwd/root-login                  boolean true
d-i passwd/root-password-crypted       password ${ROOT_HASH:-\$6\$rounds=656000\$placeholder\$placeholder}
d-i passwd/make-user                   boolean false

tasksel tasksel/first                  multiselect standard, ssh-server
d-i pkgsel/include                     string  \
    curl git python3 python3-pip python3-venv ca-certificates

d-i grub-installer/only_debian         boolean true
d-i grub-installer/bootdev             string  default

# After installation: copy NeXiS setup scripts into the installed system.
d-i preseed/late_command               string  \
    mkdir -p /target/opt /target/usr/local/bin /target/etc/systemd/system ; \
    cp /cdrom/nexis/install.sh          /target/opt/nexis-install.sh       ; \
    cp /cdrom/nexis/firstboot-tui.py    /target/usr/local/bin/nexis-firstboot ; \
    chmod +x /target/opt/nexis-install.sh /target/usr/local/bin/nexis-firstboot ; \
    cp /cdrom/nexis/nexis-install.service   /target/etc/systemd/system/    ; \
    cp /cdrom/nexis/nexis-firstboot.service /target/etc/systemd/system/    ; \
    in-target systemctl enable nexis-install.service nexis-firstboot.service ssh

d-i finish-install/reboot_in_progress  note
PRESEED

# ── 4. Copy NeXiS scripts onto ISO ───────────────────────────────────────────

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

# ── 5. GRUB config — UEFI ────────────────────────────────────────────────────
# Two entries: NeXiS (default, auto-installs) and plain Debian (manual).
# nomodeset: prevents nouveau loading on NVIDIA hardware.
# auto=true priority=critical: runs installer headlessly.
# quiet: suppresses kernel noise; installer output still shows.

KPARAMS_AUTO="auto=true priority=critical file=/cdrom/nexis/preseed.cfg nomodeset quiet"
KPARAMS_MANUAL="nomodeset"

for grub_cfg in \
    "$ISO_SRC/boot/grub/grub.cfg" \
    "$ISO_SRC/EFI/boot/grub.cfg"
do
    [[ -f "$grub_cfg" ]] || continue
    cat > "$grub_cfg" << EOF
# NeXiS Hypervisor ${VERSION}
set default=0
set timeout=8
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor ${VERSION}" {
    linux   /install.amd/vmlinuz ${KPARAMS_AUTO} ---
    initrd  /install.amd/initrd.gz
}
menuentry "Debian installer  [manual — no preseed]" {
    linux   /install.amd/vmlinuz ${KPARAMS_MANUAL} ---
    initrd  /install.amd/initrd.gz
}
EOF
    _ok "GRUB: $grub_cfg"
done

# ── 6. Syslinux config — BIOS ─────────────────────────────────────────────────
# txt.cfg: menu entries used in BIOS text mode

TXT_CFG="$ISO_SRC/isolinux/txt.cfg"
if [[ -f "$TXT_CFG" ]]; then
    cat > "$TXT_CFG" << EOF
default nexis
label nexis
    menu label Install NeXiS Hypervisor ${VERSION}
    kernel /install.amd/vmlinuz
    append ${KPARAMS_AUTO} initrd=/install.amd/initrd.gz ---
label manual
    menu label Debian installer  [manual]
    kernel /install.amd/vmlinuz
    append ${KPARAMS_MANUAL} initrd=/install.amd/initrd.gz ---
EOF
    _ok "syslinux: $TXT_CFG"
fi

# menu.cfg: title
MENU_CFG="$ISO_SRC/isolinux/menu.cfg"
[[ -f "$MENU_CFG" ]] && \
    sed -i "s/^menu title.*/menu title NeXiS Hypervisor ${VERSION}/" "$MENU_CFG"

# ── 7. Repack ─────────────────────────────────────────────────────────────────

_print "Repacking ISO…"
dd if="$DEBIAN_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"

xorriso -as mkisofs \
    -r \
    -V "$ISO_VOLUME" \
    -o "$FINAL" \
    -J --joliet-long \
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
_print "Write: dd if=$(basename "$FINAL") of=/dev/sdX bs=4M status=progress && sync"
_print "Boot: select 'Install NeXiS Hypervisor' — installation runs automatically (~15 min)"
