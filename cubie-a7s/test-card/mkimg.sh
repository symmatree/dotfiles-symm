#!/bin/bash
set -euo pipefail
R=/mnt/a7s
W=/home/radxa/imgwork
# 1. SSH key + key-only login + passwordless sudo
install -d -m700 -o 1000 -g 1000 $R/home/a7s/.ssh
install -m600 -o 1000 -g 1000 $W/cubie_ed25519.pub $R/home/a7s/.ssh/authorized_keys
chroot $R usermod -p '*' a7s
chroot $R chage -d "$(date -u +%F)" a7s
echo "a7s ALL=(ALL) NOPASSWD:ALL" >$R/etc/sudoers.d/90-a7s-tiles-test
chmod 0440 $R/etc/sudoers.d/90-a7s-tiles-test
chroot $R visudo -cf /etc/sudoers.d/90-a7s-tiles-test
# 2. MAC pin (keeps 99-default.link naming policy)
cat >$R/etc/systemd/network/10-cubie-mac.link <<EOF
# tiles test card: fixed MAC (the board MAC under the Radxa image) so DHCP is stable.
[Match]
OriginalName=eth0

[Link]
MACAddress=40:fe:0d:00:08:03
NamePolicy=keep kernel database onboard slot path
AlternativeNamesPolicy=database onboard slot path mac
EOF
# 3. Talos kernel as a second, non-default label
install -m0644 $W/Image-talos $R/boot/Image-6.18.58-talos
install -m0644 $W/sun60i-a733-cubie-a7s-talos.dtb $R/boot/sun60i-a733-cubie-a7s-6.18.58-talos.dtb
zstd -dc $W/modules-6.18.58-talos.tar.zst | tar -C $R/usr/lib/modules -xf - --no-same-owner
chroot $R depmod 6.18.58-talos
cat >>$R/boot/extlinux/extlinux.conf <<EOF
# tiles test: Talos kernel (siderolabs/pkgs f4bda77 + DockSeed series). Not default.
label talos
    kernel /boot/Image-6.18.58-talos
    fdt /boot/sun60i-a733-cubie-a7s-6.18.58-talos.dtb
    append root=PARTUUID=a7530001-01 rootwait rw console=ttyS0,115200 earlycon consoleblank=0 watchdog.open_timeout=60
EOF
echo "--- check"
awk -F: '/^a7s:/{print "pwfield="$2" lastchg="$3" max="$5}' $R/etc/shadow
ls -la $R/home/a7s/.ssh
grep -v '^#' $R/boot/extlinux/extlinux.conf
ls -ld $R/usr/lib/modules/*
ls -l $R/usr/lib/modules/6.18.58-talos/modules.dep
ls -l $R/boot
