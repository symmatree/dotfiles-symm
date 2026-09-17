#!/bin/bash
#
# grow-rootfs -- make the btrfs root fill the card it was flashed onto.
#
# Installed into the image at /usr/local/sbin/grow-rootfs and run by
# grow-rootfs.service on every boot. It is a no-op once the partition already
# reaches the end of the disk, so it costs a few reads per boot and survives the
# card being cloned onto a larger one.
#
# WHY THIS EXISTS. A flashed image is only as large as it was built, so the rest
# of the card stays unpartitioned until something grows it -- and btrfs near
# ENOSPC starts refusing writes that `df` says should fit.
#
# Raspberry Pi OS has its own first-boot resize, armed by a bare `resize` token
# in cmdline.txt that build-image.sh strips (see the note there). This runs on
# EVERY boot instead of only the first: a few reads, in exchange for growing a
# card cloned onto a larger one, or one whose root was rewritten in place by a
# staged re-flash (coordinator#310), with no cmdline surgery.
#
# btrfs grows ONLINE, so there is no two-stage dance and no reboot.
set -euo pipefail

log() { echo "grow-rootfs: $*"; }

# findmnt --nofsroot is load-bearing: without it btrfs returns /dev/mmcblk0p2[/@]
# and every downstream tool chokes on the subvolume suffix.
part="$(findmnt -n -o SOURCE --nofsroot /)"
[ -b "$part" ] || {
	log "root source '$part' is not a block device; nothing to do"
	exit 0
}

pname="${part#/dev/}"
disk="$(lsblk -no pkname "$part" | head -n1)"
[ -n "$disk" ] || {
	log "cannot determine parent disk of $part"
	exit 1
}
pnum="$(cat "/sys/class/block/$pname/partition")"

disk_sectors="$(cat "/sys/block/$disk/size")"
part_start="$(cat "/sys/class/block/$pname/start")"
part_sectors="$(cat "/sys/class/block/$pname/size")"
slack=$((disk_sectors - (part_start + part_sectors)))

# 64 MiB of tolerance: alignment and the MBR leave a little unusable tail, and we
# do not want to rewrite the partition table every boot to chase a few sectors.
if [ "$slack" -lt 131072 ]; then
	log "already fills /dev/$disk ($((part_sectors / 2048)) MiB, $((slack / 2048)) MiB slack) -- nothing to do"
	exit 0
fi

log "growing ${part} (p${pnum}) to fill /dev/$disk -- $((slack / 2048)) MiB unpartitioned"

# sfdisk, not parted. `parted -s` does NOT answer its own "Partition is being
# used. Are you sure you want to continue?" -- it prints the warning and exits 1.
# sfdisk takes its input as a script by design, so there is no prompt: ",+" keeps
# the start and extends to the end of the disk. It also leaves the MBR disk
# identifier alone, which matters because cmdline.txt pins root=PARTUUID.
#
#   --no-reread       do not re-read the table afterwards; that ioctl fails while
#                     a partition on the disk is mounted
#   --no-tell-kernel  do not ask the kernel to update, for the same reason --
#                     partx below does it for the one partition instead
printf ',+\n' | sfdisk --no-reread --no-tell-kernel -N "$pnum" "/dev/$disk"
partx -u --nr "$pnum" "/dev/$disk"
btrfs filesystem resize max /
log "done: $(findmnt -n -o SIZE /) root"
