#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder v1.3.1
#
# Minimal Debian live system → auto-starts whiptail installer on TTY1.
# modprobe.blacklist=nouveau: prevents NVIDIA firmware errors.
# text: forces text console, no display manager.
# Systemd service replaces getty on TTY1 with the installer.
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/.build"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"
KPARAMS="boot=live nomodeset text console=tty0 modprobe.blacklist=nouveau"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "run as root"
command -v lb &>/dev/null || apt-get install -yq live-build 2>/dev/null

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ── live-build config ─────────────────────────────────────────────────────────

lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --debian-installer false \
    --apt-recommends false \
    --bootappend-live "$KPARAMS" \
    --iso-application "NeXiS Hypervisor ${VERSION}" \
    --iso-volume "$ISO_VOLUME"

# ── Package list ──────────────────────────────────────────────────────────────

mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
whiptail
debootstrap
parted
gdisk
dosfstools
e2fsprogs
util-linux
curl
ca-certificates
iproute2
dhcpcd5
python3
grub-pc-bin
grub-efi-amd64-bin
EOF

# ── Stage files ───────────────────────────────────────────────────────────────

mkdir -p config/includes.chroot/usr/local/bin
mkdir -p config/includes.chroot/opt/nexis-installer
mkdir -p config/includes.chroot/etc/systemd/system

cp "$SCRIPT_DIR/installer/nexis-install.sh" \
   config/includes.chroot/usr/local/bin/nexis-install
chmod +x config/includes.chroot/usr/local/bin/nexis-install

cp "$REPO_DIR/install.sh"         config/includes.chroot/opt/nexis-installer/
cp "$SCRIPT_DIR/firstboot-tui.py" config/includes.chroot/opt/nexis-installer/

# ── Systemd service: installer runs directly on TTY1 ─────────────────────────
# This is more reliable than .bash_profile — it starts before any getty
# and takes over the console immediately.

cat > config/includes.chroot/etc/systemd/system/nexis-installer.service << 'EOF'
[Unit]
Description=NeXiS Hypervisor Installer
After=systemd-user-sessions.service plymouth-quit-wait.service
After=rc-local.service
Before=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=idle
ExecStart=/usr/local/bin/nexis-install
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── Chroot hook: enable the installer service ─────────────────────────────────

mkdir -p config/hooks/live
cat > config/hooks/live/0100-enable-installer.hook.chroot << 'HOOK'
#!/bin/bash
systemctl enable nexis-installer.service
HOOK
chmod +x config/hooks/live/0100-enable-installer.hook.chroot

# ── Binary hook: patch ALL boot menus ────────────────────────────────────────
# Patches every grub.cfg and syslinux live.cfg that live-build creates.

mkdir -p config/hooks/normal
cat > config/hooks/normal/9900-nexis-menus.hook.binary << HOOKEOF
#!/usr/bin/env bash
KPARAMS="${KPARAMS}"
VERSION="${VERSION}"

# Patch every grub.cfg
while IFS= read -r -d '' f; do
    cat > "\$f" << GRUB
set default=0
set timeout=8
menuentry "Install NeXiS Hypervisor \${VERSION}" {
    linux  /live/vmlinuz \${KPARAMS} ---
    initrd /live/initrd.img
}
GRUB
    echo "[nexis] patched \$f"
done < <(find binary -name "grub.cfg" -print0 2>/dev/null)

# Patch every syslinux live.cfg
while IFS= read -r -d '' f; do
    cat > "\$f" << SYSLINUX
label live-amd64
    menu label Install NeXiS Hypervisor \${VERSION}
    linux /live/vmlinuz
    append initrd=/live/initrd.img \${KPARAMS} ---
SYSLINUX
    echo "[nexis] patched \$f"
done < <(find binary -name "live.cfg" -print0 2>/dev/null)

# Patch isolinux.cfg title
while IFS= read -r -d '' f; do
    sed -i "s/menu title.*/menu title NeXiS Hypervisor \${VERSION}/" "\$f" 2>/dev/null || true
    echo "[nexis] title patched \$f"
done < <(find binary -name "isolinux.cfg" -print0 2>/dev/null)

exit 0
HOOKEOF
chmod +x config/hooks/normal/9900-nexis-menus.hook.binary

# ── Build ─────────────────────────────────────────────────────────────────────

_print "Building live ISO..."
lb build 2>&1 | tee "$OUTPUT_DIR/build.log"

ISO=$(find "$BUILD_DIR" -maxdepth 1 -name "*.iso" | head -1)
[[ -z "$ISO" ]] && _err "ISO not found."

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
mv "$ISO" "$FINAL"
SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO: $FINAL  ($(du -h "$FINAL" | cut -f1))"
_ok "SHA256: $SHA"
