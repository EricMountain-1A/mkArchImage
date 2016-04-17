#!/bin/bash
set -euo pipefail

readonly disk_size=3G
readonly disk_image="Arch-Cloud-$(date +%Y%m%d).qcow2"
readonly wip_disk_image="Arch-Cloud-WIP.qcow2"
readonly disk_device=/dev/nbd0

readonly packages_to_skip=(
    cryptsetup
    device-mapper
    dhcpcd
    e2fsprogs
    jfsutils
    lvm2
    mdadm
    nano
    netctl
    pcmciautils
    perl
    reiserfsprogs
    s-nail
    systemd-sysvcompat
    vi
    xfsprogs
)

readonly packages_to_add=(
    systemd
    btrfs-progs
    grub
    openssh
    python2-requests
    cloud-init
    qemu-guest-agent
    sudo
    vim
    dmidecode
)

function log {
    tput bold
    printf "$1\n"
    tput sgr0
}

log "Loading nbd module..."
modprobe nbd max_part=63

log "Creating mount point..."
readonly disk_mount="$(mktemp -d)"

function cleanup {
    log "Cleanup..."
    set +e
    umount -R "$disk_mount"
    rmdir "$disk_mount"
    qemu-nbd -d "$disk_device"
    rm -f "$wip_disk_image"
    set -e
}
trap cleanup EXIT

log "Creating the Arch disk..."
qemu-img create -f qcow2 "$wip_disk_image" $disk_size
qemu-nbd -c "$disk_device" "$wip_disk_image"
mkfs.btrfs -L "Arch Linux" -m single "$disk_device"
mount "$disk_device" "$disk_mount"
btrfs subvolume create "$disk_mount"/home
btrfs subvolume create "$disk_mount"/var

log "Installing the system..."
readonly base_packages=($(pacman -Sg base | cut -d' ' -f2))
readonly packages_to_install="$(comm -23 <(IFS=$'\n'; sort <<<"${base_packages[*]}") <(IFS=$'\n'; sort <<<"${packages_to_skip[*]}")) ${packages_to_add[@]}"
pacstrap -c "$disk_mount" $packages_to_install
readonly disk_uuid="$(blkid -s UUID -o value "$disk_device")"
genfstab -U -p "$disk_mount" | sed "s|$disk_device|UUID=$disk_uuid|g; /swap/d" >> "$disk_mount"/etc/fstab
sed -i 's|^GRUB_CMDLINE_LINUX=".*|GRUB_CMDLINE_LINUX="init=/usr/lib/systemd/systemd console=ttyS0,115200n8 console=tty1"|;
        s|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=0|' "$disk_mount"/etc/default/grub
arch-chroot "$disk_mount" grub-install --recheck --target=i386-pc "$disk_device"
arch-chroot "$disk_mount" grub-mkconfig | sed "s|$disk_device|UUID=$disk_uuid|g" > "$disk_mount"/boot/grub/grub.cfg
sed -i '/^HOOKS=/s/autodetect//' "$disk_mount"/etc/mkinitcpio.conf
arch-chroot "$disk_mount" mkinitcpio -p linux
arch-chroot "$disk_mount" systemctl enable btrfs-scrub@-.timer
arch-chroot "$disk_mount" systemctl enable fstrim.timer
arch-chroot "$disk_mount" systemctl enable systemd-networkd
arch-chroot "$disk_mount" systemctl enable systemd-resolved
rm "$disk_mount"/etc/resolv.conf
ln -s ../run/systemd/resolve/resolv.conf "$disk_mount"/etc/resolv.conf
sed -i 's/\<dns\>/resolve/' "$disk_mount"/etc/nsswitch.conf
cat >"$disk_mount"/etc/systemd/network/wired.network <<EOF
[Match]
Name=en*

[Network]
DHCP=ipv4
EOF
arch-chroot "$disk_mount" systemctl enable systemd-timesyncd.service
arch-chroot "$disk_mount" systemctl enable sshd.socket
sed -i 's/ - ubuntu-init-switch/#  - ubuntu-init-switch/;
        s/ - update_etc_hosts/#  - update_etc_hosts/;
        s/ - rsyslog/#  - rsyslog/;
        s/ - emit_upstart/#  - emit_upstart/;
        s/ - grub-dpkg/#  - grub-dpkg/;
        s/ - apt-pipelining/#  - apt-pipelining/;
        s/ - apt-configure/#  - apt-configure/;
        s/groups: .*/groups: [wheel]/;
        s/distro: .*/distro: arch/;' "$disk_mount"/etc/cloud/cloud.cfg
arch-chroot "$disk_mount" systemctl enable cloud-init-local.service
arch-chroot "$disk_mount" systemctl enable cloud-init.service
arch-chroot "$disk_mount" systemctl enable cloud-config.service
arch-chroot "$disk_mount" systemctl enable cloud-final.service
arch-chroot "$disk_mount" systemctl enable qemu-ga.service

umount -R "$disk_mount"
qemu-nbd -d "$disk_device"
mv "$wip_disk_image" "$disk_image"
