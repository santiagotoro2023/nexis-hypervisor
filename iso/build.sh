#!/usr/bin/env bash
# NeXiS Hypervisor — ISO Builder
#
# Approach: minimal Debian live system (text-only, no X11) that auto-runs
# a whiptail shell installer. No Debian netinst remastering. No framebuffer
# complications. Works on any hardware including NVIDIA.
#
# Boot: GRUB → live kernel (nomodeset) → VGA text console → installer
# Install: whiptail menus → debootstrap Debian → configure → NeXiS services
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/.build"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

_print() { printf '\033[38;5;208m[nexis]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ok\033[0m %s\n'    "$1"; }
_err()   { printf '\033[38;5;196m  err\033[0m %s\n'  "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "run as root"
command -v lb &>/dev/null || apt-get install -yq live-build 2>/dev/null

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ── live-build config ─────────────────────────────────────────────────────────
# No Debian installer — our shell script IS the installer.
# nomodeset: stops nouveau from loading (NVIDIA hardware safe).
# console=tty0: ensures kernel output goes to the physical display.

lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --debian-installer false \
    --apt-recommends false \
    --bootappend-live "boot=live nomodeset console=tty0 consoleblank=0" \
    --iso-application "NeXiS Hypervisor ${VERSION}" \
    --iso-volume "${ISO_VOLUME}"

# ── Package list ──────────────────────────────────────────────────────────────
# Minimal set — everything the installer script needs to do its job.

mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
# Disk tools
parted
gdisk
dosfstools
e2fsprogs
util-linux
# Debian installer
debootstrap
# Terminal UI
whiptail
# Network
curl
ca-certificates
iproute2
dhcpcd5
# Python (for firstboot TUI)
python3
# Misc
git
EOF

# ── Stage installer files via includes.chroot ─────────────────────────────────

mkdir -p config/includes.chroot/usr/local/bin
mkdir -p config/includes.chroot/opt/nexis-installer

cp "$SCRIPT_DIR/installer/nexis-install.sh" \
   config/includes.chroot/usr/local/bin/nexis-install
chmod +x config/includes.chroot/usr/local/bin/nexis-install

cp "$REPO_DIR/install.sh"         config/includes.chroot/opt/nexis-installer/
cp "$SCRIPT_DIR/firstboot-tui.py" config/includes.chroot/opt/nexis-installer/

# ── Auto-run installer on TTY1 ────────────────────────────────────────────────
# Override getty to autologin as root, then start the installer immediately.

mkdir -p config/includes.chroot/etc/systemd/system/getty@tty1.service.d
cat > config/includes.chroot/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

mkdir -p config/includes.chroot/root
cat > config/includes.chroot/root/.bash_profile << 'EOF'
# Auto-start installer on TTY1
if [[ "$(tty)" == "/dev/tty1" ]] && [[ -x /usr/local/bin/nexis-install ]]; then
    clear
    exec /usr/local/bin/nexis-install
fi
EOF

# ── GRUB boot menu (binary hook) ──────────────────────────────────────────────
# Replace the default Debian live menu with a single NeXiS entry.
# nomodeset is in --bootappend-live but we also set it explicitly here.

mkdir -p config/hooks/normal
cat > config/hooks/normal/9900-nexis-grub.hook.binary << 'HOOKEOF'
#!/usr/bin/env bash
GRUB_CONTENT='set default=0
set timeout=8

menuentry "Install NeXiS Hypervisor" {
    linux  /live/vmlinuz boot=live nomodeset console=tty0 consoleblank=0 ---
    initrd /live/initrd.img
}
'
for cfg in binary/boot/grub/grub.cfg binary/EFI/boot/grub.cfg; do
    [[ -f "$cfg" ]] && printf '%s' "$GRUB_CONTENT" > "$cfg"
done
exit 0
HOOKEOF
chmod +x config/hooks/normal/9900-nexis-grub.hook.binary

# ── Build ─────────────────────────────────────────────────────────────────────

_print "Building live system (takes a few minutes)..."
lb build 2>&1 | tee "$OUTPUT_DIR/build.log"

ISO=$(find "$BUILD_DIR" -maxdepth 1 -name "*.iso" | head -1)
[[ -z "$ISO" ]] && _err "ISO not found after build."

FINAL="$OUTPUT_DIR/nexis-hypervisor-${VERSION}-amd64.iso"
mv "$ISO" "$FINAL"
SHA=$(sha256sum "$FINAL" | awk '{print $1}')
echo "$SHA  nexis-hypervisor-${VERSION}-amd64.iso" > "$OUTPUT_DIR/SHA256SUMS"

_ok "ISO: $FINAL"
_ok "Size: $(du -h "$FINAL" | cut -f1)"
_ok "SHA256: $SHA"
_print "Write: dd if=$(basename "$FINAL") of=/dev/sdX bs=4M status=progress && sync"
