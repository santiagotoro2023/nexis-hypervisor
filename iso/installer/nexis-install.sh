#!/bin/sh
# NeXiS Hypervisor — Interactive Installer
# Runs in the Alpine live session. Installs Debian 12 to the target disk.
set -e

dmesg -n 1 2>/dev/null || true

OR='\033[1;33m'
DIM='\033[2m'
RST='\033[0m'
RED='\033[1;31m'
GRN='\033[1;32m'

LOG=/tmp/nexis-install.log
exec 3>>"$LOG"

_print() { printf '%b%s%b\n' "$OR" "$1" "$RST"; }
_dim()   { printf '%b%s%b\n' "$DIM" "$1" "$RST"; }
_ok()    { printf '%b  ok%b  %s\n' "$GRN" "$RST" "$1"; }
_err()   { printf '%b  err%b %s\n' "$RED" "$RST" "$1"; }
_ask()   { printf '%b%s%b ' "$OR" "$1" "$RST"; }
_sep()   { printf '%b%s%b\n' "$DIM" "──────────────────────────────────────────────────────────" "$RST"; }

_header() {
    clear
    printf '%b' "$OR"
    cat << 'LOGO'

         /\
        /  \
       / () \       NeXiS Hypervisor
      /______\      Debian 12 Edition

LOGO
    printf '%b' "$RST"
    _sep
    printf '\n'
}

_confirm() {
    printf '%b%s%b [y/N] ' "$OR" "$1" "$RST"
    read -r ANS
    case "$ANS" in [yY]*) return 0;; *) return 1;; esac
}

# ── Bootstrap APK repos and network ──────────────────────────────────────────

{
    printf 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/main\n'
    printf 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/community\n'
} > /etc/apk/repositories

for _mod in virtio_net virtio_pci e1000 e1000e r8169 8139too vmxnet3 \
            bnx2 tg3 igb ixgbe mlx5_core be2net pcnet32; do
    modprobe "$_mod" 2>/dev/null || true
done
mdev -s 2>/dev/null || true

_waited=0
while [ $_waited -lt 15 ]; do
    _nifaces=$(ip -o link show 2>/dev/null | grep -vc 'LOOPBACK')
    [ "$_nifaces" -gt 0 ] && break
    sleep 1; _waited=$((_waited + 1))
done

for _iface in $(ip -o link show 2>/dev/null | grep -v 'LOOPBACK' | awk -F': ' '{print $2}'); do
    ip link set "$_iface" up 2>/dev/null || true
    udhcpc -i "$_iface" -n -q -t 5 2>/dev/null || true
done

if ip route get 1.1.1.1 >/dev/null 2>&1; then
    apk update -q 2>/dev/null || true
    apk add -q kbd-bkeymaps 2>/dev/null || true
fi

# ── Welcome ───────────────────────────────────────────────────────────────────

_header
_dim "  Installation will:"
_dim "  1. Partition the selected disk"
_dim "  2. Install Debian 12 (Bookworm)"
_dim "  3. Configure NeXiS Hypervisor on first boot"
printf '\n'
_dim "  Internet connection required."
_dim "  ALL DATA on the selected disk will be erased."
printf '\n'
_ask "  Press Enter to begin, or Ctrl-C to abort."
read -r _

# ── Keyboard layout ───────────────────────────────────────────────────────────

_header
_print "  KEYBOARD LAYOUT"
printf '\n'
_dim "  [1]  English (US)      [6]  French (FR)"
_dim "  [2]  Swiss (CH)        [7]  English (UK)"
_dim "  [3]  Swiss German      [8]  Spanish (ES)"
_dim "  [4]  German (DE)       [9]  Italian (IT)"
_dim "  [5]  Swiss French      [0]  Portuguese (PT)"
printf '\n'
_ask "  Select [1-9,0, default=1]: "
read -r KB_NUM

# KB      = loadkmap/bmap name for the live session
# KB_XKB  = XKB layout for the installed Debian system
# KB_VAR  = XKB variant (empty unless needed)
case "$KB_NUM" in
    2) KB="sg";        KB_DIR="sg"; KB_XKB="ch"; KB_VAR="" ;;
    3) KB="sg";        KB_DIR="sg"; KB_XKB="ch"; KB_VAR="" ;;
    4) KB="de";        KB_DIR="de"; KB_XKB="de"; KB_VAR="" ;;
    5) KB="sf";        KB_DIR="sf"; KB_XKB="ch"; KB_VAR="fr" ;;
    6) KB="fr";        KB_DIR="fr"; KB_XKB="fr"; KB_VAR="" ;;
    7) KB="uk";        KB_DIR="uk"; KB_XKB="gb"; KB_VAR="" ;;
    8) KB="es";        KB_DIR="es"; KB_XKB="es"; KB_VAR="" ;;
    9) KB="it";        KB_DIR="it"; KB_XKB="it"; KB_VAR="" ;;
    0) KB="pt";        KB_DIR="pt"; KB_XKB="pt"; KB_VAR="" ;;
    *) KB="us";        KB_DIR="us"; KB_XKB="us"; KB_VAR="" ;;
esac

_kb_applied=0
for _bmap in \
    "/usr/share/bkeymaps/${KB_DIR}/${KB}.bmap.gz" \
    "/usr/share/bkeymaps/${KB_DIR}/${KB}-latin1.bmap.gz" \
    "/usr/share/bkeymaps/${KB_DIR}/${KB_DIR}.bmap.gz" \
    "/usr/share/bkeymaps/${KB}.bmap.gz"
do
    [ -f "$_bmap" ] || continue
    loadkmap < "$_bmap" 2>/dev/null && _kb_applied=1 && break
done
[ "$_kb_applied" -eq 1 ] \
    && _ok "Keyboard: $KB — active now" \
    || _ok "Keyboard: $KB_XKB — will apply on installed system"

# ── Hostname ──────────────────────────────────────────────────────────────────

_header
_print "  HOSTNAME"
printf '\n'
_ask "  Hostname [nexis-node-01]: "
read -r HNAME
HNAME=$(printf '%s' "${HNAME:-nexis-node-01}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[ -z "$HNAME" ] && HNAME="nexis-node"
_ok "Hostname: $HNAME"

# ── Root password ─────────────────────────────────────────────────────────────

_header
_print "  ROOT PASSWORD"
printf '\n'
while true; do
    _ask "  Password (min 8 chars): "
    stty -echo; read -r P1; stty echo; printf '\n'
    [ "${#P1}" -lt 8 ] && { _err "Password too short."; continue; }
    _ask "  Confirm password:       "
    stty -echo; read -r P2; stty echo; printf '\n'
    [ "$P1" = "$P2" ] && break
    _err "Passwords do not match."
done
ROOT_PASS="$P1"
_ok "Password set"

# ── NeXiS Controller URL ──────────────────────────────────────────────────────

_header
_print "  NEXIS CONTROLLER (optional)"
printf '\n'
_dim "  Enter your NeXiS Controller URL for SSO across all devices."
_dim "  Leave blank to use local authentication only."
printf '\n'
_ask "  Controller URL [skip]: "
read -r CTRL

# ── Disk selection ────────────────────────────────────────────────────────────

_header
_print "  SELECT INSTALLATION DISK"
printf '\n'
_dim "  WARNING: all data on the selected disk will be permanently erased."
printf '\n'

IDX=0; DISK_LIST=""
for d in /dev/sd? /dev/vd? /dev/nvme?n? /dev/mmcblk?; do
    [ -b "$d" ] || continue
    IDX=$((IDX+1))
    SIZE=$(lsblk -d -o SIZE --noheadings "$d" 2>/dev/null | tr -d ' ')
    MODEL=$(lsblk -d -o MODEL --noheadings "$d" 2>/dev/null | tr -d ' ')
    printf '%b  [%d]%b  %-12s  %-8s  %s\n' "$OR" "$IDX" "$RST" "$d" "$SIZE" "$MODEL"
    DISK_LIST="$DISK_LIST $d"
done

[ "$IDX" -eq 0 ] && { _err "No disks found."; exit 1; }
printf '\n'
_ask "  Select disk number [1]: "
read -r DISK_NUM
DISK_NUM="${DISK_NUM:-1}"

IDX=0; DISK=""
for d in $DISK_LIST; do
    IDX=$((IDX+1))
    [ "$IDX" -eq "$DISK_NUM" ] && { DISK="$d"; break; }
done
[ -z "$DISK" ] && DISK=$(echo "$DISK_LIST" | awk '{print $1}')

if printf '%s' "$DISK" | grep -qE '(nvme|mmcblk)'; then
    EFI="${DISK}p1"; ROOT="${DISK}p2"
else
    EFI="${DISK}1";  ROOT="${DISK}2"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────

_header
_print "  INSTALLATION SUMMARY"
printf '\n'
printf '%b  %-16s%b  %s\n' "$DIM" "Disk"       "$RST" "$DISK"
printf '%b  %-16s%b  %s\n' "$DIM" "OS"         "$RST" "Debian 12 (Bookworm)"
printf '%b  %-16s%b  %s\n' "$DIM" "Hostname"   "$RST" "$HNAME"
printf '%b  %-16s%b  %s\n' "$DIM" "Keyboard"   "$RST" "$KB_XKB"
printf '%b  %-16s%b  %s\n' "$DIM" "Controller" "$RST" "${CTRL:-none (local auth)}"
printf '\n'
_dim "  ALL DATA ON $DISK WILL BE PERMANENTLY ERASED."
printf '\n'
_confirm "  Proceed with installation?" || { _dim "  Aborted."; exit 0; }

# ── Install ───────────────────────────────────────────────────────────────────

_header
_print "  INSTALLING — DO NOT POWER OFF"
printf '\n'

step() { printf '%b  [%s/8]%b  %s\n' "$OR" "$1" "$RST" "$2"; }
run()  { "$@" >>"$LOG" 2>&1; }

# ── Step 1: Network ───────────────────────────────────────────────────────────

step 1 "Configuring network..."
_ifaces=$(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}' | tr '\n' ' ')
_dim "  Detected interfaces: ${_ifaces:-none}"

_tries=0; _got_ip=0
while [ $_got_ip -eq 0 ] && [ $_tries -lt 20 ]; do
    for _iface in $(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}'); do
        ip link set "$_iface" up 2>/dev/null || true
        udhcpc -i "$_iface" -n -q 2>/dev/null && _got_ip=1 && break
    done
    [ $_got_ip -eq 1 ] && break
    _tries=$((_tries + 1))
    printf '%b  Waiting for DHCP... (%ds)%b\r' "$DIM" "$((_tries * 3))" "$RST"
    sleep 3
done

if [ $_got_ip -eq 0 ]; then
    printf '\n'
    _err "DHCP failed. Options:"
    printf '%b  [1]%b Retry\n' "$OR" "$RST"
    printf '%b  [2]%b Static IP\n' "$OR" "$RST"
    _ask "  Choice [1]: "; read -r _NET_CHOICE
    case "${_NET_CHOICE:-1}" in
        2)
            _ask "  IP/prefix (e.g. 192.168.1.50/24): "; read -r _CIDR
            _ask "  Gateway:                            "; read -r _GW
            _IFACE=$(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}' | head -1)
            ip addr add "$_CIDR" dev "$_IFACE" 2>/dev/null || true
            ip link set "$_IFACE" up 2>/dev/null || true
            ip route add default via "$_GW" 2>/dev/null || true
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
            ;;
        *) for _iface in $(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}'); do
               udhcpc -i "$_iface" -q 2>/dev/null || true; done ;;
    esac
fi

_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' || echo "none")
_ok "Network: ${_IP}"

# Install tools needed for partitioning and Debian bootstrap
apk update >>"$LOG" 2>&1 || true
apk add --quiet parted e2fsprogs dosfstools util-linux debootstrap >>"$LOG" 2>&1 \
    || { _err "Cannot install tools. Log: $LOG"; sleep 5; }

# ── Step 2: Partition ─────────────────────────────────────────────────────────

step 2 "Partitioning $DISK..."
run parted -s "$DISK" mklabel gpt
run parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
run parted -s "$DISK" set 1 esp on
run parted -s "$DISK" mkpart root ext4 513MiB 100%
run mkfs.fat -F32 -n EFI "$EFI"
run mkfs.ext4 -F -L nexis-root "$ROOT"

# ── Step 3: Mount ─────────────────────────────────────────────────────────────

step 3 "Mounting target..."
mkdir -p /mnt
run mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
run mount "$EFI" /mnt/boot/efi

# ── Step 4: Debootstrap ───────────────────────────────────────────────────────

step 4 "Installing Debian 12 base system (downloading ~300MB)..."
debootstrap --arch=amd64 bookworm /mnt http://deb.debian.org/debian \
    >>"$LOG" 2>&1 \
    || { _err "debootstrap failed. Log: $LOG"; sleep 10; exit 1; }

# ── Step 5: Install packages ──────────────────────────────────────────────────

step 5 "Installing packages (kernel, bootloader, services)..."

# Bind-mount for chroot (works fine from Alpine live — full root access)
mount -t proc   proc  /mnt/proc
mount -t sysfs  sysfs /mnt/sys
mount --bind    /dev  /mnt/dev
mount --bind    /run  /mnt/run

# Prevent service starts during install
printf '#!/bin/sh\nexit 101\n' > /mnt/usr/sbin/policy-rc.d
chmod +x /mnt/usr/sbin/policy-rc.d

cat > /mnt/etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main
EOF

# Write keyboard config BEFORE installing keyboard-configuration (avoids prompts)
mkdir -p /mnt/etc/default
cat > /mnt/etc/default/keyboard << EOF
XKBMODEL="pc105"
XKBLAYOUT="${KB_XKB}"
XKBVARIANT="${KB_VAR}"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get update -qq >>"$LOG" 2>&1

DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    grub-efi-amd64 \
    efibootmgr \
    openssh-server \
    chrony \
    python3 python3-pip \
    curl git sudo \
    iproute2 \
    e2fsprogs dosfstools \
    kbd console-setup keyboard-configuration \
    kmod \
    ca-certificates \
    >>"$LOG" 2>&1 \
    || { _err "Package install failed. Log: $LOG"; sleep 10; exit 1; }

rm -f /mnt/usr/sbin/policy-rc.d

# ── Step 6: Configure system ──────────────────────────────────────────────────

step 6 "Configuring system..."

printf '%s\n' "$HNAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   ${HNAME}
::1         localhost ip6-localhost ip6-loopback
EOF

printf 'root:%s\n' "$ROOT_PASS" | chpasswd -R /mnt >>"$LOG" 2>&3

ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
EFI_UUID=$(blkid  -s UUID -o value "$EFI")
cat > /mnt/etc/fstab << EOF
UUID=${ROOT_UUID}  /         ext4  noatime,errors=remount-ro  0  1
UUID=${EFI_UUID}   /boot/efi vfat  umask=0077                 0  2
EOF

# systemd-networkd: DHCP on all Ethernet regardless of udev-assigned name
mkdir -p /mnt/etc/systemd/network
cat > /mnt/etc/systemd/network/20-dhcp.network << 'EOF'
[Match]
Type=ether

[Network]
DHCP=yes
EOF

chroot /mnt systemctl enable systemd-networkd >>"$LOG" 2>&1 || true
chroot /mnt systemctl enable systemd-resolved >>"$LOG" 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true

chroot /mnt systemctl enable ssh    >>"$LOG" 2>&1 || true
chroot /mnt systemctl enable chrony >>"$LOG" 2>&1 || true

chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime >>"$LOG" 2>&1 || true
DEBIAN_FRONTEND=noninteractive chroot /mnt dpkg-reconfigure -f noninteractive tzdata >>"$LOG" 2>&1 || true
chroot /mnt ssh-keygen -A >>"$LOG" 2>&1 || true

[ -n "$CTRL" ] && {
    mkdir -p /mnt/etc/nexis-hypervisor
    printf '{"pending_controller_url": "%s"}\n' "$CTRL" > /mnt/etc/nexis-hypervisor/config.json
}

# ── Step 7: Bootloader ────────────────────────────────────────────────────────

step 7 "Installing GRUB..."
cat > /mnt/etc/default/grub << 'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="NeXiS Hypervisor"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
EOF

chroot /mnt grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi --bootloader-id=NeXiS --recheck \
    >>"$LOG" 2>&1 \
    || { _err "GRUB install failed. Log: $LOG"; exit 1; }
chroot /mnt update-grub >>"$LOG" 2>&1

# ── Step 8: NeXiS services ────────────────────────────────────────────────────

step 8 "Setting up NeXiS services..."

MEDIA=""
for m in /media/cdrom /media/usb /run/media/*; do
    [ -f "$m/nexis/install.sh" ] && { MEDIA="$m"; break; }
done

mkdir -p /mnt/opt /mnt/usr/local/bin

if [ -n "$MEDIA" ]; then
    cp "$MEDIA/nexis/install.sh"       /mnt/opt/nexis-install.sh
    cp "$MEDIA/nexis/firstboot-tui.py" /mnt/usr/local/bin/nexis-firstboot
    cp "$MEDIA/nexis/nexis-shell.py"   /mnt/usr/local/bin/nexis-shell
else
    cp /opt/nexis-installer/install.sh        /mnt/opt/nexis-install.sh        2>/dev/null || true
    cp /opt/nexis-installer/firstboot-tui.py  /mnt/usr/local/bin/nexis-firstboot 2>/dev/null || true
    cp /opt/nexis-installer/nexis-shell.py    /mnt/usr/local/bin/nexis-shell     2>/dev/null || true
fi
chmod +x /mnt/opt/nexis-install.sh /mnt/usr/local/bin/nexis-firstboot \
          /mnt/usr/local/bin/nexis-shell 2>/dev/null || true
ln -sf /usr/local/bin/nexis-shell /mnt/usr/local/bin/nexis 2>/dev/null || true

cat > /mnt/etc/systemd/system/nexis-install.service << 'SVC'
[Unit]
Description=NeXiS Hypervisor Installation
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/nexis-hypervisor

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/nexis-install.sh
StandardOutput=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

cat > /mnt/etc/systemd/system/nexis-firstboot.service << 'SVC'
[Unit]
Description=NeXiS First-Boot Configuration
After=nexis-install.service
Requires=nexis-install.service
ConditionPathExists=!/etc/nexis-hypervisor/.firstboot-done

[Service]
Type=idle
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
ExecStart=/usr/bin/python3 /usr/local/bin/nexis-firstboot

[Install]
WantedBy=multi-user.target
SVC

chroot /mnt systemctl enable nexis-install   >>"$LOG" 2>&1 || true
chroot /mnt systemctl enable nexis-firstboot >>"$LOG" 2>&1 || true

# tty1 auto-login root → nexis-shell
mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d
cat > /mnt/etc/systemd/system/getty@tty1.service.d/nexis.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

cat > /mnt/root/.bash_profile << 'PROFILE'
export TERM=linux
alias nexis='/usr/local/bin/nexis-shell'
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -x /usr/local/bin/nexis-shell ]; then
    /usr/local/bin/nexis-shell
    printf '\n\033[1;33m  Returned to Linux shell. Type nexis to re-enter.\033[0m\n'
fi
PROFILE

# Unmount in reverse order
umount /mnt/run      2>/dev/null || true
umount /mnt/dev      2>/dev/null || true
umount /mnt/sys      2>/dev/null || true
umount /mnt/proc     2>/dev/null || true
umount /mnt/boot/efi 2>/dev/null || true
umount /mnt          2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────

_header
printf '%b  INSTALLATION COMPLETE\n\n%b' "$OR" "$RST"
printf '%b  %-18s%b  %s\n' "$DIM" "Installed to"  "$RST" "$DISK"
printf '%b  %-18s%b  %s\n' "$DIM" "OS"            "$RST" "Debian 12 Bookworm"
printf '%b  %-18s%b  %s\n' "$DIM" "First boot"    "$RST" "NeXiS stack installs automatically"
printf '%b  %-18s%b  %s\n' "$DIM" "Web UI"        "$RST" "https://<ip>:8443"
printf '%b  %-18s%b  %s\n' "$DIM" "Default login" "$RST" "creator / Asdf1234!"
printf '\n'
_dim "  Remove the installation media."
printf '\n'
_ask "  Press Enter to reboot."
read -r _
reboot
