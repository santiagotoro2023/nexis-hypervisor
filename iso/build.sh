#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Produces a bootable ISO using the standard Debian installer (d-i netinst).
# No Calamares, no X11, no GPU driver requirements — works on any hardware.
#
# Boot flow:
#   GRUB (NeXiS-branded, dark/orange) → standard Debian installer (text + graphical)
#   → late_command copies NeXiS stack → reboot → nexis-install.service → web UI
#
# Must run as root inside a Debian Bookworm environment (privileged container).
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/.build"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

_print() { printf '\033[38;5;208m[nexis-iso]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "ISO build must run as root."
command -v lb &>/dev/null || apt-get install -yq live-build 2>/dev/null

_print "NeXiS Hypervisor ${VERSION} — Building ISO (standard Debian installer)..."
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ── live-build config ─────────────────────────────────────────────────────────
# --debian-installer netinst: includes the standard Debian d-i at /install.amd/
# The live squashfs is kept minimal — users go straight to the installer.

lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --debian-installer netinst \
    --apt-recommends false \
    --iso-application "NeXiS Hypervisor ${VERSION}" \
    --iso-volume "${ISO_VOLUME}"

# ── Minimal live-system package list ─────────────────────────────────────────
# The live system is not presented to the user — only the installer is.

mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
ca-certificates
EOF

# ── NeXiS files on the ISO binary ────────────────────────────────────────────
# Placed at /nexis/ on the ISO root → accessible as /cdrom/nexis/ during d-i.
# late_command copies them into the installed system without any internet access.

mkdir -p config/includes.binary/nexis

# Preseed — loaded by the installer via GRUB kernel parameter
cat > config/includes.binary/nexis/preseed.cfg << 'PRESEED'
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
PRESEED

# Install script and firstboot TUI (copied to /target by late_command)
cp "$REPO_DIR/install.sh"         config/includes.binary/nexis/
cp "$SCRIPT_DIR/firstboot-tui.py" config/includes.binary/nexis/

# Systemd service: installs NeXiS stack on first boot (requires internet)
cat > config/includes.binary/nexis/nexis-install.service << 'SVC'
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

# Systemd service: firstboot TUI for network/hostname/controller config
cat > config/includes.binary/nexis/nexis-firstboot.service << 'SVC'
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

# ── GRUB binary hook — NeXiS-branded installer-only menu ─────────────────────
# Replaces live-build's generated grub.cfg (which has Live/Installer/etc entries)
# with a clean NeXiS menu pointing at the d-i kernel at /install.amd/.
# Preseed is loaded automatically via auto=true file=/cdrom/nexis/preseed.cfg.

mkdir -p config/hooks/normal
cat > config/hooks/normal/9900-nexis-grub.hook.binary << 'HOOKEOF'
#!/usr/bin/env bash
# No set -e — must not fail even if no grub.cfg exists.

NEXIS_GRUB='# NeXiS Hypervisor Boot Configuration
set timeout=8
set default=0

# GRUB standard colors (yellow = closest to #F87200 orange)
set color_normal=light-gray/black
set color_highlight=yellow/black
set menu_color_normal=light-gray/black
set menu_color_highlight=yellow/black

menuentry "Install NeXiS Hypervisor" {
    linux   /install.amd/vmlinuz auto=true file=/cdrom/nexis/preseed.cfg vga=788 quiet ---
    initrd  /install.amd/initrd.gz
}

menuentry "Install NeXiS Hypervisor  [graphical]" {
    linux   /install.amd/vmlinuz auto=true file=/cdrom/nexis/preseed.cfg vga=788 video=vesa:ywrap,mtrr DEBIAN_FRONTEND=gtk quiet ---
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
'

found=0
while IFS= read -r -d '' cfg; do
    printf '%s' "$NEXIS_GRUB" > "$cfg"
    echo "[nexis] Patched GRUB: $cfg"
    found=$((found + 1))
done < <(find binary -name 'grub.cfg' -print0 2>/dev/null)
echo "[nexis] Patched $found GRUB config(s)."
exit 0
HOOKEOF
chmod +x config/hooks/normal/9900-nexis-grub.hook.binary

# ── Build ─────────────────────────────────────────────────────────────────────

_print "Running live-build..."
lb build 2>&1 | tee "$OUTPUT_DIR/build.log"

ISO=$(find "$BUILD_DIR" -maxdepth 1 -name "*.iso" | head -1)
[[ -z "$ISO" ]] && _err "ISO not found after build."

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
mv "$ISO" "$FINAL"
SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO: $FINAL"
_ok "SHA256: $SHA"
_print "Write to USB: dd if='$FINAL' of=/dev/sdX bs=4M status=progress"
