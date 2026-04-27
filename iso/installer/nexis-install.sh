#!/bin/sh
# NeXiS Hypervisor — Interactive Installer (Alpine Linux)
# Runs on the Alpine live system via getty on tty1.
# Asks keyboard / hostname / root password / NeXiS Controller URL,
# then automates the rest: partition, install Alpine, configure, GRUB.
set -e

export TERM=linux
LOG=/tmp/nexis-install.log
TITLE="NeXiS Hypervisor"

# ── Ensure networking ─────────────────────────────────────────────────────────
if ! ip route show default 2>/dev/null | grep -q default; then
    ip link set eth0 up 2>/dev/null || true
    udhcpc -i eth0 -t 10 -q 2>/dev/null || true
fi

# ── Install whiptail and disk tools ──────────────────────────────────────────
apk add --quiet newt parted e2fsprogs dosfstools blkid 2>>"$LOG" || true

# ── TUI helpers ───────────────────────────────────────────────────────────────
msg()  { whiptail --title "$TITLE" --msgbox  "$1" 12 66 3>&1 1>&2 2>&3; }
info() { whiptail --title "$TITLE" --infobox "$1" 8 66; }
ask()  { whiptail --title "$TITLE" --inputbox "$1" 10 66 "${2:-}" 3>&1 1>&2 2>&3; }
pass() { whiptail --title "$TITLE" --passwordbox "$1" 10 66 3>&1 1>&2 2>&3; }
yn()   { whiptail --title "$TITLE" --yesno "$1" 12 66; }
step() { info "[$1/8] $2"; echo "$(date '+%H:%M:%S') [$1/8] $2" >>"$LOG"; }
run()  { "$@" >>"$LOG" 2>&1; }

# ── Welcome ───────────────────────────────────────────────────────────────────
clear
printf '\033[38;5;208m'
cat << 'LOGO'

    /\
   /  \
  / () \      NeXiS Hypervisor
 /______\     Alpine Linux Edition

LOGO
printf '\033[0m'
sleep 2

msg "Welcome to NeXiS Hypervisor Installation.

Powered by Alpine Linux — lightweight, fast, secure.

You will be asked for:
  • Keyboard layout
  • Hostname
  • Root password
  • NeXiS Controller URL (optional)

Internet connection is required.
ALL DATA on the selected disk will be permanently erased."

# ── 1. Keyboard layout ────────────────────────────────────────────────────────
KB=$(whiptail --title "$TITLE" --menu "Select keyboard layout:" 20 60 10 \
    "us"    "English (US)" \
    "de"    "German (DE)" \
    "ch"    "Swiss (default)" \
    "de_CH" "Swiss German" \
    "fr"    "French (FR)" \
    "fr_CH" "Swiss French" \
    "gb"    "English (UK)" \
    "es"    "Spanish (ES)" \
    "it"    "Italian (IT)" \
    "pt"    "Portuguese (PT)" \
    3>&1 1>&2 2>&3) || KB="us"

# ── 2. Hostname ───────────────────────────────────────────────────────────────
HNAME=$(ask "Hostname for this hypervisor node:" "nexis-node-01") || exit 0
HNAME=$(printf '%s' "$HNAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[ -z "$HNAME" ] && HNAME="nexis-node"

# ── 3. Root password ──────────────────────────────────────────────────────────
while true; do
    P1=$(pass "Root password (minimum 8 characters):") || exit 0
    [ "${#P1}" -lt 8 ] && { msg "Password must be at least 8 characters."; continue; }
    P2=$(pass "Confirm root password:") || exit 0
    [ "$P1" = "$P2" ] && break
    msg "Passwords do not match. Please try again."
done
ROOT_PASS="$P1"

# ── 4. NeXiS Controller URL ───────────────────────────────────────────────────
CTRL=$(ask "NeXiS Controller URL for SSO (optional — leave blank to skip):" \
    "") || CTRL=""
[ "$CTRL" = "https://192.168.1.x:8443" ] && CTRL=""

# ── 5. Disk selection ─────────────────────────────────────────────────────────
DISK_ARGS=""
for d in /dev/sd? /dev/vd? /dev/nvme?n?; do
    [ -b "$d" ] || continue
    SIZE=$(lsblk -d -o SIZE --noheadings "$d" 2>/dev/null | xargs || echo "?")
    MODEL=$(lsblk -d -o MODEL --noheadings "$d" 2>/dev/null | xargs || echo "Unknown")
    DISK_ARGS="$DISK_ARGS $d \"${SIZE}  ${MODEL}\""
done
[ -z "$DISK_ARGS" ] && { msg "No disks found."; exit 1; }

DISK=$(eval whiptail --title '"$TITLE"' \
    --menu '"Select installation disk.\nWARNING: all data will be erased."' \
    20 70 10 $DISK_ARGS \
    3>&1 1>&2 2>&3) || exit 0

# Partition naming (NVMe/MMC use p1/p2 suffix)
if printf '%s' "$DISK" | grep -qE '(nvme|mmcblk)'; then
    EFI="${DISK}p1"; ROOT="${DISK}p2"
else
    EFI="${DISK}1";  ROOT="${DISK}2"
fi

# ── 6. Confirm ────────────────────────────────────────────────────────────────
yn "Ready to install.

  Disk:        $DISK
  Hostname:    $HNAME
  Keyboard:    $KB
  Controller:  ${CTRL:-none (local auth)}

ALL DATA ON $DISK WILL BE PERMANENTLY ERASED.
This cannot be undone. Continue?" || exit 0

# ── 7. Install ────────────────────────────────────────────────────────────────

step 1 "Setting up keyboard…"
setup-keymap "$KB" "$KB" >>"$LOG" 2>&1 || true

step 2 "Partitioning $DISK…"
run parted -s "$DISK" mklabel gpt
run parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
run parted -s "$DISK" set 1 esp on
run parted -s "$DISK" mkpart root ext4 513MiB 100%
run mkfs.fat -F32 -n EFI "$EFI"
run mkfs.ext4 -F -L nexis-root "$ROOT"

step 3 "Mounting target…"
mkdir -p /mnt
run mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
run mount "$EFI" /mnt/boot/efi

step 4 "Installing Alpine base system (downloading, please wait)…"
mkdir -p /mnt/etc/apk
cp /etc/apk/repositories /mnt/etc/apk/repositories

apk --root /mnt --initdb add --quiet \
    alpine-base \
    linux-lts \
    linux-firmware-none \
    openrc \
    grub \
    grub-efi \
    efibootmgr \
    openssh \
    python3 \
    py3-pip \
    curl \
    git \
    sudo \
    util-linux \
    >>"$LOG" 2>&1 || { msg "Package install failed — check internet. Log: $LOG"; exit 1; }

step 5 "Configuring system…"
# Hostname
printf '%s\n' "$HNAME" > /mnt/etc/hostname
printf '127.0.0.1\t%s\n127.0.1.1\t%s\n' "$HNAME" "$HNAME" >> /mnt/etc/hosts

# Root password
printf 'root:%s\n' "$ROOT_PASS" | chpasswd -R /mnt >>"$LOG" 2>&1

# fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
EFI_UUID=$(blkid  -s UUID -o value "$EFI")
cat > /mnt/etc/fstab << EOF
UUID=$ROOT_UUID  /          ext4  noatime,errors=remount-ro  0  1
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077                 0  2
EOF

# Network — DHCP via OpenRC/ifupdown
cat > /mnt/etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

# DNS
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf

# Timezone
chroot /mnt setup-timezone -z UTC >>"$LOG" 2>&1 || true

# SSH — generate host keys and enable
chroot /mnt ssh-keygen -A >>"$LOG" 2>&1 || true
chroot /mnt rc-update add sshd default >>"$LOG" 2>&1 || true
chroot /mnt rc-update add networking default >>"$LOG" 2>&1 || true

# Controller URL
if [ -n "$CTRL" ]; then
    mkdir -p /mnt/etc/nexis-hypervisor
    printf '{"pending_controller_url": "%s"}\n' "$CTRL" \
        > /mnt/etc/nexis-hypervisor/config.json
fi

step 6 "Installing GRUB bootloader…"
chroot /mnt grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=NeXiS \
    --recheck >>"$LOG" 2>&1 \
    || { msg "GRUB install failed. Log: $LOG"; exit 1; }
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg >>"$LOG" 2>&1

step 7 "Copying NeXiS setup scripts…"

# Find media mount point
MEDIA=""
for m in /media/cdrom /media/usb /run/media/*; do
    [ -f "$m/nexis/install.sh" ] && { MEDIA="$m"; break; }
done

if [ -n "$MEDIA" ]; then
    mkdir -p /mnt/opt
    cp "$MEDIA/nexis/install.sh"        /mnt/opt/nexis-install.sh
    cp "$MEDIA/nexis/firstboot-tui.py"  /mnt/usr/local/bin/nexis-firstboot
else
    # Fallback: grab install script from GitHub
    curl -fsSL https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/iso/installer/nexis-install-alpine.sh \
        -o /mnt/opt/nexis-install.sh >>"$LOG" 2>&1 || true
    cp /opt/nexis-installer/firstboot-tui.py /mnt/usr/local/bin/nexis-firstboot 2>/dev/null || true
fi
chmod +x /mnt/opt/nexis-install.sh /mnt/usr/local/bin/nexis-firstboot 2>/dev/null || true

# OpenRC service: install NeXiS on first boot
cat > /mnt/etc/init.d/nexis-install << 'SVC'
#!/sbin/openrc-run
name="nexis-install"
description="NeXiS Hypervisor installation"
depend() { need net; after net; }
start() {
    [ -d /opt/nexis-hypervisor ] && return 0
    ebegin "Installing NeXiS Hypervisor (see /var/log/nexis-install.log)"
    /bin/sh /opt/nexis-install.sh > /var/log/nexis-install.log 2>&1
    eend $?
}
SVC
chmod +x /mnt/etc/init.d/nexis-install
chroot /mnt rc-update add nexis-install default >>"$LOG" 2>&1

# OpenRC service: firstboot TUI for network/controller config
cat > /mnt/etc/init.d/nexis-firstboot << 'SVC'
#!/sbin/openrc-run
name="nexis-firstboot"
description="NeXiS first-boot configuration TUI"
depend() { need nexis-install; after nexis-install; }
start() {
    [ -f /etc/nexis-hypervisor/.firstboot-done ] && return 0
    ebegin "Starting NeXiS first-boot configuration"
    /usr/bin/python3 /usr/local/bin/nexis-firstboot </dev/tty1 >/dev/tty1 2>&1
    eend $?
}
SVC
chmod +x /mnt/etc/init.d/nexis-firstboot
chroot /mnt rc-update add nexis-firstboot default >>"$LOG" 2>&1

step 8 "Finalising…"
umount /mnt/boot/efi 2>/dev/null || true
umount /mnt          2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
msg "Installation complete!

NeXiS Hypervisor has been installed to $DISK.

On first boot:
  • NeXiS stack installs automatically (~5 min, needs internet)
  • Configuration TUI runs for network / controller setup
  • Web UI at https://<ip>:8443
  • Default login: creator / Asdf1234!

Remove the USB drive, then press OK to reboot."

reboot
