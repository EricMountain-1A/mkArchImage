#!/bin/bash
set -euo pipefail

readonly packages_to_skip=(
    cryptsetup
    device-mapper
    dhcpcd
    e2fsprogs
    inetutils
    iputils
    jfsutils
    licenses
    linux
    logrotate
    lvm2
    man-db
    man-pages
    mdadm
    nano
    netctl
    pciutils
    pcmciautils
    perl
    reiserfsprogs
    s-nail
    systemd-sysvcompat
    texinfo
    usbutils
    xfsprogs
)

readonly packages_to_add=(
    systemd
)

readonly base_packages=($(pacman -Sg base | cut -d' ' -f2))
readonly packages_to_install="$(comm -23 <(IFS=$'\n'; sort <<<"${base_packages[*]}") <(IFS=$'\n'; sort <<<"${packages_to_skip[*]}")) ${packages_to_add[@]}"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 image_name"
    exit 1
fi

readonly root_dir="/var/lib/machines/$1"

hash pacstrap || pacman -S --noconfirm arch-install-scripts
btrfs subvolume create "$root_dir"
pacstrap -c -d "$root_dir" $packages_to_install --hookdir /no_hook
arch-chroot "$root_dir" systemctl enable systemd-networkd
arch-chroot "$root_dir" systemctl enable systemd-resolved
rm "$root_dir/etc/resolv.conf"
ln -s ../run/systemd/resolve/resolv.conf "$root_dir/etc/resolv.conf"
sed -i 's/\<dns\>/resolve/' "$root_dir"/etc/nsswitch.conf
machinectl read-only "$1" true
