#!/usr/bin/env bash
# NeXiS Hypervisor — Interactive Installer
# Runs on the live system. Uses whiptail for menus.
set -euo pipefail

LOG=/tmp/nexis-install.log
TARGET=/mnt/nexis-target
TITLE="NeXiS Hypervisor"

msg()  { whiptail --title "$TITLE" --msgbox  "$1" 12 66; }
err()  { whiptail --title "Error"  --msgbox  "Error: $1\n\nSee $LOG for details." 12 66; exit 1; }
ask()  { whiptail --title "$TITLE" --inputbox "$1" 10 66 "${2:-}" 3>&1 1>&2 2>&3; }
pass() { whiptail --title "$TITLE" --passwordbox "$1" 10 66 3>&1 1>&2 2>&3; }
info() { whiptail --title "$TITLE" --infobox "$1" 8 66; }
yn()   { whiptail --title "$TITLE" --yesno "$1" 12 66; }

run()  { "$@" >>"$LOG" 2>&1; }

# ── Welcome ───────────────────────────────────────────────────────────────────
clear
msg "Welcome to NeXiS Hypervisor Installation.

This will:
  1. Partition the disk you select
  2. Install Debian as the base system
  3. Set up NeXiS Hypervisor on first boot

Internet connection is required.
All data on the selected disk will be erased."

# ── Disk ─────────────────────────────────────────────────────────────────────
MENU_ITEMS=()
while read -r name size model; do
    MENU_ITEMS+=("/dev/$name" "$size  $model")
done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings | grep -v loop)

[[ ${#MENU_ITEMS[@]} -eq 0 ]] && err "No disks detected."

DISK=$(whiptail --title "Select Disk" \
    --menu "Choose the installation disk.\nWARNING: everything on it will be erased." \
    20 70 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 0

# Partition suffix (nvme/mmcblk use p1/p2)
if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
    EFI="${DISK}p1"; ROOT="${DISK}p2"
else
    EFI="${DISK}1";  ROOT="${DISK}2"
fi

# ── Hostname ──────────────────────────────────────────────────────────────────
HNAME=$(ask "Hostname for this hypervisor node:" "nexis-node-01") || exit 0
HNAME=$(echo "$HNAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[[ -z "$HNAME" ]] && HNAME="nexis-node"

# ── Root password ─────────────────────────────────────────────────────────────
while true; do
    P1=$(pass "Root password (min 8 chars):") || exit 0
    [[ ${#P1} -lt 8 ]] && { msg "Password must be at least 8 characters."; continue; }
    P2=$(pass "Confirm root password:") || exit 0
    [[ "$P1" == "$P2" ]] && break
    msg "Passwords do not match. Try again."
done
ROOT_PASS="$P1"

# ── Controller URL ────────────────────────────────────────────────────────────
CTRL=$(ask "NeXiS Controller URL for SSO (leave blank to skip):" "") || CTRL=""

# ── Confirm ───────────────────────────────────────────────────────────────────
yn "Ready to install.\n
  Disk:        $DISK
  Hostname:    $HNAME
  Controller:  ${CTRL:-none}

ALL DATA ON $DISK WILL BE ERASED.
Continue?" || exit 0

# ── Installation ──────────────────────────────────────────────────────────────

step() { info "[$1] $2"; echo "$(date '+%H:%M:%S') [$1] $2" >>"$LOG"; }

step "1/8" "Partitioning $DISK..."
run parted -s "$DISK" mklabel gpt
run parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
run parted -s "$DISK" set 1 esp on
run parted -s "$DISK" mkpart root ext4 513MiB 100%
sleep 1

step "2/8" "Formatting filesystems..."
run mkfs.fat -F32 -n EFI    "$EFI"
run mkfs.ext4 -F  -L nexis  "$ROOT"

step "3/8" "Mounting target..."
mkdir -p "$TARGET"
run mount "$ROOT" "$TARGET"
mkdir -p "$TARGET/boot/efi"
run mount "$EFI"  "$TARGET/boot/efi"

step "4/8" "Installing Debian base (this takes several minutes)..."
run debootstrap \
    --arch=amd64 \
    --include=linux-image-amd64,systemd-sysv,locales,ca-certificates,openssh-server,sudo,grub-efi-amd64,grub-pc-bin \
    bookworm "$TARGET" https://deb.debian.org/debian \
    || err "debootstrap failed — check internet connection."

step "5/8" "Configuring system..."

# fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
EFI_UUID=$(blkid  -s UUID -o value "$EFI")
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0  1
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077         0  2
EOF

echo "$HNAME" > "$TARGET/etc/hostname"
printf "127.0.0.1\tlocalhost\n127.0.1.1\t$HNAME\n" >> "$TARGET/etc/hosts"

# Root password
echo "root:$ROOT_PASS" | chpasswd -R "$TARGET"

# Apt sources
cat > "$TARGET/etc/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian bookworm main contrib non-free-firmware
deb https://security.debian.org/debian-security bookworm-security main
EOF

# Controller URL
if [[ -n "$CTRL" ]]; then
    mkdir -p "$TARGET/etc/nexis-hypervisor"
    printf '{"pending_controller_url": "%s"}\n' "$CTRL" \
        > "$TARGET/etc/nexis-hypervisor/config.json"
fi

step "6/8" "Installing packages..."
for d in proc sys dev dev/pts; do
    mkdir -p "$TARGET/$d"
    mount --bind "/$d" "$TARGET/$d" 2>>"$LOG" || true
done
DEBIAN_FRONTEND=noninteractive run chroot "$TARGET" apt-get install -yq \
    curl git python3 python3-pip python3-venv libvirt-dev pkg-config build-essential \
    || true   # non-fatal — NeXiS install.sh will retry

step "7/8" "Installing GRUB bootloader..."
run chroot "$TARGET" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=NeXiS \
    --recheck \
    || err "GRUB install failed"
run chroot "$TARGET" update-grub

step "8/8" "Setting up NeXiS services..."
cp /opt/nexis-installer/install.sh          "$TARGET/opt/nexis-install.sh"
cp /opt/nexis-installer/firstboot-tui.py    "$TARGET/usr/local/bin/nexis-firstboot"
chmod +x "$TARGET/opt/nexis-install.sh" "$TARGET/usr/local/bin/nexis-firstboot"

cat > "$TARGET/etc/systemd/system/nexis-install.service" <<'SVC'
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

cat > "$TARGET/etc/systemd/system/nexis-firstboot.service" <<'SVC'
[Unit]
Description=NeXiS First-Boot Configuration
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

run chroot "$TARGET" systemctl enable nexis-install.service nexis-firstboot.service ssh

# Unmount
for d in dev/pts dev sys proc boot/efi ''; do
    umount -lf "$TARGET/${d}" 2>/dev/null || true
done

# ── Done ──────────────────────────────────────────────────────────────────────
msg "Installation complete!

NeXiS Hypervisor has been installed to $DISK.

On first boot:
  - NeXiS stack installs automatically (internet required)
  - Configuration TUI runs for network/controller setup
  - Web UI available at https://<ip>:8443

Default login: creator / Asdf1234!

Remove the USB drive, then press OK to reboot."

reboot
