#!/bin/sh
# NeXiS Hypervisor — Interactive Installer (Alpine Linux)
# Pure shell TUI — no external packages needed. Runs immediately at boot.
set -e

# Silence kernel messages on this console so PCIe/PCI noise doesn't flood the UI.
# Errors still go to /tmp/nexis-install.log via fd3.
dmesg -n 1 2>/dev/null || true

OR='\033[1;33m'   # bright yellow  → orange on VGA console
DIM='\033[2m'
RST='\033[0m'
RED='\033[1;31m'
GRN='\033[1;32m'

LOG=/tmp/nexis-install.log
exec 3>>"$LOG"   # fd3 = log file; stderr stays on screen so errors are visible

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
      /______\      Alpine Linux Edition

LOGO
    printf '%b' "$RST"
    _sep
    printf '\n'
}

_confirm() {
    # $1 = prompt
    printf '%b%s%b [y/N] ' "$OR" "$1" "$RST"
    read -r ANS
    case "$ANS" in [yY]*) return 0;; *) return 1;; esac
}

# ── Ensure apk repositories and network ──────────────────────────────────────
{
    printf 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/main\n'
    printf 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/community\n'
} > /etc/apk/repositories

# Load NIC kernel modules
for _mod in virtio_net virtio_pci e1000 e1000e r8169 8139too vmxnet3 \
            bnx2 tg3 igb ixgbe mlx5_core be2net pcnet32; do
    modprobe "$_mod" 2>/dev/null || true
done

# On Alpine, mdev -s rescans sysfs so the kernel registers new devices in
# /sys/class/net. Without this, VMware/bare-metal NICs can stay invisible
# even after their module loads.
mdev -s 2>/dev/null || true

# Poll for any non-loopback interface to appear (up to 15 s)
_waited=0
while [ $_waited -lt 15 ]; do
    _nifaces=$(ip -o link show 2>/dev/null | grep -vc 'LOOPBACK')
    [ "$_nifaces" -gt 0 ] && break
    sleep 1; _waited=$((_waited + 1))
done

# Bring up every non-loopback interface and attempt DHCP
for _iface in $(ip -o link show 2>/dev/null | grep -v 'LOOPBACK' | awk -F': ' '{print $2}'); do
    ip link set "$_iface" up 2>/dev/null || true
    udhcpc -i "$_iface" -n -q -t 5 2>/dev/null || true
done

# If we got any network, pull kbd-bkeymaps NOW — before the keyboard prompt —
# so loadkmap is guaranteed to have .bmap.gz files regardless of apkovl state.
if ip route get 1.1.1.1 >/dev/null 2>&1; then
    apk update -q 2>/dev/null || true
    apk add -q kbd-bkeymaps 2>/dev/null || true
fi

# ── Welcome ───────────────────────────────────────────────────────────────────
_header
_dim "  Installation will:"
_dim "  1. Partition the selected disk"
_dim "  2. Install Alpine Linux"
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
_dim "  [3]  Swiss German       [8]  Spanish (ES)"
_dim "  [4]  German (DE)       [9]  Italian (IT)"
_dim "  [5]  Swiss French      [0]  Portuguese (PT)"
printf '\n'
_ask "  Select [1-9,0, default=1]: "
read -r KB_NUM

case "$KB_NUM" in
    2) KB="sg"; KB_DIR="sg" ;;
    3) KB="sg"; KB_DIR="sg" ;;
    4) KB="de"; KB_DIR="de" ;;
    5) KB="sf"; KB_DIR="sf" ;;
    6) KB="fr"; KB_DIR="fr" ;;
    7) KB="uk"; KB_DIR="uk" ;;
    8) KB="es"; KB_DIR="es" ;;
    9) KB="it"; KB_DIR="it" ;;
    0) KB="pt"; KB_DIR="pt" ;;
    *) KB="us"; KB_DIR="us" ;;
esac

# Apply keyboard NOW so password entry is correct.
# BusyBox loadkmap reads .bmap.gz directly (gzip support built in) — no zcat needed.
_kb_applied=0
for _bmap in \
    "/usr/share/bkeymaps/${KB_DIR}/${KB}.bmap.gz" \
    "/usr/share/bkeymaps/${KB_DIR}/${KB}-latin1.bmap.gz" \
    "/usr/share/bkeymaps/${KB_DIR}/${KB_DIR}.bmap.gz" \
    "/usr/share/bkeymaps/${KB_DIR}/${KB}.bmap" \
    "/usr/share/bkeymaps/${KB}.bmap.gz"
do
    [ -f "$_bmap" ] || continue
    loadkmap < "$_bmap" 2>/dev/null && _kb_applied=1 && break
done
if [ "$_kb_applied" -eq 0 ]; then
    timeout 2 loadkeys "$KB" >/dev/null 2>&1 && _kb_applied=1 || true
fi
if [ "$_kb_applied" -eq 1 ]; then
    _ok "Keyboard: $KB — active now"
else
    _ok "Keyboard: $KB — will apply on installed system"
    _dim "  (Live session stays US — type passwords consistently)"
fi

# ── Hostname ──────────────────────────────────────────────────────────────────
_header
_print "  HOSTNAME"
printf '\n'
_dim "  Enter the hostname for this hypervisor node."
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
_dim "  This password secures direct console and SSH access."
printf '\n'

while true; do
    _ask "  Password (min 8 chars): "
    stty -echo
    read -r P1
    stty echo
    printf '\n'
    [ "${#P1}" -lt 8 ] && { _err "Password too short."; continue; }
    _ask "  Confirm password:       "
    stty -echo
    read -r P2
    stty echo
    printf '\n'
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

IDX=0
DISK_LIST=""
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

IDX=0
for d in $DISK_LIST; do
    IDX=$((IDX+1))
    [ "$IDX" -eq "$DISK_NUM" ] && { DISK="$d"; break; }
done
[ -z "$DISK" ] && DISK=$(echo "$DISK_LIST" | awk '{print $1}')

# Partition naming
if printf '%s' "$DISK" | grep -qE '(nvme|mmcblk)'; then
    EFI="${DISK}p1"; ROOT="${DISK}p2"
else
    EFI="${DISK}1";  ROOT="${DISK}2"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
_header
_print "  INSTALLATION SUMMARY"
printf '\n'
printf '%b  %-16s%b  %s\n' "$DIM" "Disk" "$RST" "$DISK"
printf '%b  %-16s%b  %s\n' "$DIM" "Hostname" "$RST" "$HNAME"
printf '%b  %-16s%b  %s\n' "$DIM" "Keyboard" "$RST" "$KB"
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

step 1 "Configuring network..."
# ip -o link show lists kernel-registered interfaces reliably (no mdev dependency)
_ifaces=$(ip -o link show 2>/dev/null | grep -v 'LOOPBACK' | awk -F': ' '{print $2}' | tr '\n' ' ')
_dim "  Detected interfaces: ${_ifaces:-none}"

# Retry DHCP on each interface, up to 60 s
_tries=0
_got_ip=0
while [ $_got_ip -eq 0 ] && [ $_tries -lt 20 ]; do
    for _iface in $(ip -o link show 2>/dev/null | grep -v 'LOOPBACK' | awk -F': ' '{print $2}'); do
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
    _err "DHCP failed on all interfaces."
    _dim "  Your NIC may need firmware not included in this ISO."
    _dim "  Options:"
    printf '%b  [1]%b Retry DHCP\n' "$OR" "$RST"
    printf '%b  [2]%b Configure static IP\n' "$OR" "$RST"
    printf '%b  [3]%b Skip networking (no package install — advanced)\n' "$OR" "$RST"
    printf '\n'
    _ask "  Choice [1]: "
    read -r _NET_CHOICE
    case "${_NET_CHOICE:-1}" in
        2)
            _ask "  IP address (e.g. 192.168.1.50): "; read -r _IP
            _ask "  Netmask (e.g. 255.255.255.0):  "; read -r _MASK
            _ask "  Gateway:                        "; read -r _GW
            _ask "  Interface [$(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}' | head -1)]: "
            read -r _IFACE
            _IFACE="${_IFACE:-$(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}' | head -1)}"
            ip addr add "${_IP}/${_MASK}" dev "$_IFACE" 2>/dev/null || true
            ip route add default via "$_GW" 2>/dev/null || true
            printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
            ;;
        3) _dim "  Skipping network — continuing without package installation."; sleep 2 ;;
        *) # Retry
            for _iface in $(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}'); do
                udhcpc -i "$_iface" -q 2>/dev/null || true
            done ;;
    esac
fi

_IP_CURRENT=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "none")
_ok "Network: IP = ${_IP_CURRENT}"

apk update >>"$LOG" 2>&1 || { _err "Cannot reach package repo. Log: $LOG"; sleep 5; }
apk add --quiet parted e2fsprogs dosfstools util-linux >>"$LOG" 2>&1 || true

step 2 "Confirming network..."
_ok "Network ready — proceeding with installation"

step 3 "Partitioning $DISK..."
run parted -s "$DISK" mklabel gpt
run parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
run parted -s "$DISK" set 1 esp on
run parted -s "$DISK" mkpart root ext4 513MiB 100%
run mkfs.fat -F32 -n EFI "$EFI"
run mkfs.ext4 -F -L nexis-root "$ROOT"

step 4 "Mounting target..."
mkdir -p /mnt
run mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
run mount "$EFI" /mnt/boot/efi

step 5 "Installing Alpine Linux (downloading base system)..."
mkdir -p /mnt/etc/apk
printf 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/main\nhttps://dl-cdn.alpinelinux.org/alpine/latest-stable/community\n' \
    > /mnt/etc/apk/repositories

apk --root /mnt --initdb add --quiet \
    alpine-base linux-lts linux-firmware openrc \
    grub grub-efi efibootmgr openssh chrony \
    kbd-bkeymaps kmod python3 py3-pip curl git sudo \
    >>"$LOG" 2>&1 || { _err "Package install failed — check internet. Log: $LOG"; sleep 10; exit 1; }

step 6 "Configuring system..."
printf '%s\n' "$HNAME" > /mnt/etc/hostname
printf '127.0.0.1\t%s\n127.0.1.1\t%s\n' "$HNAME" "$HNAME" >> /mnt/etc/hosts
printf 'root:%s\n' "$ROOT_PASS" | chpasswd -R /mnt >&3 2>&3

ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
EFI_UUID=$(blkid  -s UUID -o value "$EFI")
printf 'UUID=%s\t/\t\text4\tnoatime,errors=remount-ro\t0\t1\n' "$ROOT_UUID" > /mnt/etc/fstab
printf 'UUID=%s\t/boot/efi\tvfat\tumask=0077\t0\t2\n' "$EFI_UUID" >> /mnt/etc/fstab

# Detect the live NIC name so the installed system uses the right interface.
_primary_iface=$(ip -o link show 2>/dev/null | grep -v LOOPBACK | awk -F': ' '{print $2}' | head -1)
_primary_iface="${_primary_iface:-eth0}"

{
    printf 'auto lo\niface lo inet loopback\n\n'
    printf 'auto %s\niface %s inet dhcp\n' "$_primary_iface" "$_primary_iface"
    [ "$_primary_iface" != "eth0" ] && printf '\nauto eth0\niface eth0 inet dhcp\n'
} > /mnt/etc/network/interfaces
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf

chroot /mnt setup-timezone -z UTC >&3 2>&3 || true
chroot /mnt ssh-keygen -A >&3 2>&3 || true
chroot /mnt rc-update add sshd default >&3 2>&3 || true
chroot /mnt rc-update add networking default >&3 2>&3 || true
chroot /mnt rc-update add chronyd default >&3 2>&3 || true
# hwclock hangs indefinitely on kernel 6.18+ (VMware ESXi + bare-metal) because
# /dev/rtc0 is not ready when sysinit runs. Alpine puts hwclock in sysinit, not
# boot, so rc-update del hwclock boot silently does nothing. Remove the symlinks
# directly from every runlevel to guarantee it never runs.
rm -f /mnt/etc/runlevels/sysinit/hwclock
rm -f /mnt/etc/runlevels/boot/hwclock
rm -f /mnt/etc/runlevels/default/hwclock

# Keyboard: Alpine uses the 'loadkmap' OpenRC service (from busybox-openrc,
# included in alpine-base). Config is a full path to the .bmap.gz file.
# 'keymaps' is the kbd/systemd name — wrong for Alpine.
mkdir -p /mnt/etc/conf.d
printf 'KEYMAP=/usr/share/bkeymaps/%s/%s.bmap.gz\n' "$KB_DIR" "$KB" > /mnt/etc/conf.d/loadkmap
chroot /mnt rc-update add loadkmap boot >&3 2>&3 || true

[ -n "$CTRL" ] && {
    mkdir -p /mnt/etc/nexis-hypervisor
    printf '{"pending_controller_url": "%s"}\n' "$CTRL" > /mnt/etc/nexis-hypervisor/config.json
}

# Set GRUB defaults so Alpine's initramfs loads NIC modules before networking.
# modules= is read by Alpine's initramfs init; this ensures e1000/virtio are
# available before OpenRC tries to bring up the network interface.
mkdir -p /mnt/etc/default
cat > /mnt/etc/default/grub << 'GRUBEOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="NeXiS Hypervisor"
GRUB_CMDLINE_LINUX_DEFAULT="modules=e1000,e1000e,r8169,igb,vmxnet3,virtio_net,virtio_pci quiet"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUBEOF

step 7 "Installing bootloader..."
chroot /mnt grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi --bootloader-id=NeXiS --recheck >&3 2>&3 \
    || { _err "GRUB install failed. Log: $LOG"; exit 1; }
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg >&3 2>&3

step 8 "Setting up NeXiS services..."
# Find ISO media
MEDIA=""
for m in /media/cdrom /media/usb /run/media/*; do
    [ -f "$m/nexis/install.sh" ] && { MEDIA="$m"; break; }
done

mkdir -p /mnt/opt /mnt/usr/local/bin

if [ -n "$MEDIA" ]; then
    cp "$MEDIA/nexis/install.sh"        /mnt/opt/nexis-install.sh
    cp "$MEDIA/nexis/firstboot-tui.py"  /mnt/usr/local/bin/nexis-firstboot
    cp "$MEDIA/nexis/nexis-shell.py"    /mnt/usr/local/bin/nexis-shell
else
    cp /opt/nexis-installer/install.sh        /mnt/opt/nexis-install.sh        2>/dev/null || true
    cp /opt/nexis-installer/firstboot-tui.py  /mnt/usr/local/bin/nexis-firstboot 2>/dev/null || true
    cp /opt/nexis-installer/nexis-shell.py    /mnt/usr/local/bin/nexis-shell     2>/dev/null || true
fi
chmod +x /mnt/opt/nexis-install.sh /mnt/usr/local/bin/nexis-firstboot \
          /mnt/usr/local/bin/nexis-shell 2>/dev/null || true
ln -sf /usr/local/bin/nexis-shell /mnt/usr/local/bin/nexis 2>/dev/null || true

# nexis-install OpenRC service
cat > /mnt/etc/init.d/nexis-install << 'SVC'
#!/sbin/openrc-run
name="nexis-install"
description="NeXiS Hypervisor installation"
depend() { need net; after net; }
start() {
    [ -d /opt/nexis-hypervisor ] && return 0
    ebegin "Installing NeXiS Hypervisor"
    /bin/sh /opt/nexis-install.sh > /var/log/nexis-install.log 2>&1
    eend $?
}
SVC
chmod +x /mnt/etc/init.d/nexis-install
chroot /mnt rc-update add nexis-install default >&3 2>&3

# nexis-firstboot OpenRC service
cat > /mnt/etc/init.d/nexis-firstboot << 'SVC'
#!/sbin/openrc-run
name="nexis-firstboot"
description="NeXiS first-boot configuration"
depend() { need nexis-install; after nexis-install; }
start() {
    [ -f /etc/nexis-hypervisor/.firstboot-done ] && return 0
    ebegin "NeXiS first-boot configuration"
    /usr/bin/python3 /usr/local/bin/nexis-firstboot </dev/tty1 >/dev/tty1 2>&1
    eend $?
}
SVC
chmod +x /mnt/etc/init.d/nexis-firstboot
chroot /mnt rc-update add nexis-firstboot default >&3 2>&3

# NeXiS shell on console (tty1 auto-login → nexis-shell)
grep -q '^tty1::' /mnt/etc/inittab 2>/dev/null && \
    sed -i 's|^tty1::.*|tty1::respawn:/sbin/getty -n -l /usr/local/bin/nexis-shell-launcher 0 tty1|' \
    /mnt/etc/inittab

cat > /mnt/usr/local/bin/nexis-shell-launcher << 'LAUNCHER'
#!/bin/sh
export TERM=linux
/usr/local/bin/nexis-shell
printf '\n\033[1;33m  THE EYE BLINKS. Type nexis to return.\033[0m\n'
exec /bin/sh
LAUNCHER
chmod +x /mnt/usr/local/bin/nexis-shell-launcher

# Unmount
umount /mnt/boot/efi 2>/dev/null || true
umount /mnt          2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
_header
printf '%b  INSTALLATION COMPLETE\n\n%b' "$OR" "$RST"
printf '%b  %-16s%b  %s\n' "$DIM" "Installed to" "$RST" "$DISK"
printf '%b  %-16s%b  %s\n' "$DIM" "First boot" "$RST" "NeXiS stack installs automatically"
printf '%b  %-16s%b  %s\n' "$DIM" "Web UI" "$RST" "https://<ip>:8443"
printf '%b  %-16s%b  %s\n' "$DIM" "Default login" "$RST" "creator / Asdf1234!"
printf '\n'
_dim "  Remove the installation media."
printf '\n'
_ask "  Press Enter to reboot."
read -r _
reboot
