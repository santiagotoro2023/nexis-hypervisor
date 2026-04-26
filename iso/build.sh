#!/usr/bin/env bash
# NeXiS Hypervisor — Debian 12 ISO Builder
# Produces a bootable ISO with a custom themed installer TUI (Proxmox/ESXi style).
# Must run as root inside a Debian Bookworm environment (privileged container in CI).
set -euo pipefail

VERSION="${NEXIS_VERSION:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/.build"
ISO_VOLUME="NEXIS_HV_${VERSION//./_}"

_print() { printf '\033[38;5;208m[nexis-iso]\033[0m %s\n' "$1"; }
_ok()    { printf '\033[38;5;46m  ✓\033[0m %s\n' "$1"; }
_err()   { printf '\033[38;5;196m  ✗\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && _err "ISO build must run as root."
command -v lb &>/dev/null || apt-get install -yq live-build 2>/dev/null

_print "NeXiS Hypervisor ${VERSION} — Building Installation ISO..."
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ── live-build configuration ─────────────────────────────────────────────────

lb config \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --apt-recommends false \
    --iso-application "NeXiS Hypervisor ${VERSION}" \
    --iso-volume "${ISO_VOLUME}"

# ── Package list (live environment only — minimal for running the installer) ──

mkdir -p config/package-lists
cat > config/package-lists/nexis.list.chroot << 'EOF'
# Runtime needed by the installer TUI
python3
python3-pip
# Disk utilities used by the installer
parted
debootstrap
gdisk
dosfstools
e2fsprogs
# Network
curl
ca-certificates
git
# Misc
jq
EOF

# ── Preseed (not used for the live installer but kept for reference) ───────────

mkdir -p config/preseed
cp "$SCRIPT_DIR/config/preseed.cfg" config/preseed/nexis.cfg

# ── Include installer TUI ─────────────────────────────────────────────────────

mkdir -p config/includes.chroot/usr/local/bin
cp "$SCRIPT_DIR/installer/nexis-install.py" \
   config/includes.chroot/usr/local/bin/nexis-install
chmod +x config/includes.chroot/usr/local/bin/nexis-install

# Also include the firstboot TUI so the installer can copy it to the target disk
mkdir -p config/includes.chroot/opt/nexis-installer
cp "$SCRIPT_DIR/firstboot-tui.py" config/includes.chroot/opt/nexis-installer/firstboot-tui.py

# ── Auto-launch installer on first TTY ───────────────────────────────────────
# Override getty@tty1 so the installer TUI appears immediately on boot,
# exactly like Proxmox / ESXi — no login prompt, straight into the wizard.

mkdir -p config/includes.chroot/etc/systemd/system

# Drop-in that replaces the login prompt on tty1 with the NeXiS installer
mkdir -p config/includes.chroot/etc/systemd/system/getty@tty1.service.d
cat > config/includes.chroot/etc/systemd/system/getty@tty1.service.d/nexis-installer.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/python3 /usr/local/bin/nexis-install
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Environment=TERM=linux
EOF

# ── GRUB theme hook (binary stage) ───────────────────────────────────────────
# Injects the NeXiS color scheme and title into the live-boot GRUB menu.

mkdir -p config/hooks/normal
cat > config/hooks/normal/9900-nexis-grub.hook.binary << 'HOOKEOF'
#!/usr/bin/env bash
set -euo pipefail

# Install NeXiS GRUB theme
THEME_DIR="binary/boot/grub/themes/nexis"
mkdir -p "$THEME_DIR"

cat > "$THEME_DIR/theme.txt" << 'THEME'
# NeXiS Hypervisor GRUB Theme
title-text: ""
desktop-color: "#080807"
terminal-font: "Fixed Regular 12"

+ label {
    top = 3%; left = 0%; width = 100%; height = 6%
    text = "NeXiS Hypervisor"
    color = "#F87200"; font = "Fixed Bold 20"; align = "center"
}
+ label {
    top = 10%; left = 0%; width = 100%; height = 4%
    text = "Neural Execution and Cross-device Inference System"
    color = "#887766"; font = "Fixed Regular 10"; align = "center"
}
+ boot_menu {
    left = 12%; width = 76%; top = 22%; height = 52%
    item_color = "#C4B898"
    selected_item_color = "#F87200"
    item_height = 18; item_padding = 6; item_spacing = 2
    icon_width = 0; icon_height = 0
}
+ progress_bar {
    id = "__timeout__"
    left = 12%; width = 76%; top = 78%; height = 2%
    fg_color = "#F87200"; bg_color = "#1A1A12"; border_color = "#2A2A1A"
}
+ label {
    id = "__timeout__"
    top = 82%; left = 0%; width = 100%; height = 4%
    text = "Booting in %d seconds..."
    color = "#2A2A1A"; font = "Fixed Regular 10"; align = "center"
}
+ label {
    top = 93%; left = 0%; width = 100%; height = 4%
    text = "Enter: install   e: edit entry   c: GRUB console"
    color = "#2A2A1A"; font = "Fixed Regular 10"; align = "center"
}
THEME

# Inject theme + colors into the generated GRUB config
if [[ -f binary/boot/grub/grub.cfg ]]; then
    PATCH=$(mktemp)
    cat > "$PATCH" << 'GRUB'
# NeXiS Hypervisor Boot Configuration
insmod all_video
insmod gfxterm
insmod gfxmenu
set gfxpayload=keep

if loadfont /boot/grub/fonts/unicode.pf2; then
    terminal_output gfxterm
fi

set theme=/boot/grub/themes/nexis/theme.txt
load_env

# Fallback console colors if gfxterm fails
set color_normal=white/black
set color_highlight=yellow/black
set menu_color_normal=white/black
set menu_color_highlight=yellow/black

GRUB
    cat binary/boot/grub/grub.cfg >> "$PATCH"
    mv "$PATCH" binary/boot/grub/grub.cfg
fi

# Apply same theme to EFI GRUB if present
if [[ -f binary/EFI/boot/grub.cfg ]]; then
    PATCH=$(mktemp)
    cat > "$PATCH" << 'GRUB'
insmod all_video
insmod gfxterm
insmod gfxmenu
set gfxpayload=keep
if loadfont /boot/grub/fonts/unicode.pf2; then terminal_output gfxterm; fi
set theme=/boot/grub/themes/nexis/theme.txt
set color_normal=white/black
set color_highlight=yellow/black
set menu_color_normal=white/black
set menu_color_highlight=yellow/black

GRUB
    cat binary/EFI/boot/grub.cfg >> "$PATCH"
    mv "$PATCH" binary/EFI/boot/grub.cfg
fi
HOOKEOF
chmod +x config/hooks/normal/9900-nexis-grub.hook.binary

# ── GRUB menu title hook ───────────────────────────────────────────────────────
# Rename menu entries from default live-build labels to NeXiS labels.

cat > config/hooks/normal/9901-nexis-menu.hook.binary << HOOKEOF
#!/usr/bin/env bash
# Replace default Debian menu labels with NeXiS branding
if [[ -f binary/boot/grub/grub.cfg ]]; then
    sed -i \
        -e 's/Debian GNU\/Linux/NeXiS Hypervisor ${VERSION}/g' \
        -e 's/Live system/Install NeXiS Hypervisor/g' \
        -e 's/menuentry "Debian/menuentry "NeXiS/g' \
        binary/boot/grub/grub.cfg || true
fi
HOOKEOF
chmod +x config/hooks/normal/9901-nexis-menu.hook.binary

# ── Build ─────────────────────────────────────────────────────────────────────

_print "Running live-build (this takes several minutes)..."
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
