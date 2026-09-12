#!/bin/bash
#
# grow-rootfs -- make the btrfs root fill the card it was flashed onto.
#
# Installed into the image at /usr/local/sbin/grow-rootfs and run by
# grow-rootfs.service on every boot. It is a no-op once the partition already
# reaches the end of the disk, so it costs a few reads per boot and survives the
# card being cloned onto a larger one.
#
# WHY THIS EXISTS. A flashed image is only as large as it was built (~3.6 GiB),
# so the rest of the card is unpartitioned until something grows it. Raspberry Pi
# OS does that in two stages and this image has neither:
#
#   partition   init=/usr/lib/raspi-config/init_resize.sh -- our cmdline carries
#               no init= at all, so it never runs.
#   filesystem  resize2fs_once.service -- it is `resize2fs $(findmnt / -o source
#               -n)`, which on btrfs yields subvolume notation (/dev/mmcblk0p2[/@])
#               and is the wrong tool besides. Masked at build time.
#
# Left unreplaced that stranded both deployed units at ~3 GiB of a 32 GB card,
# with the coordinator at 1 MiB unallocated -- btrfs near ENOSPC before anything
# was installed, which is where it starts failing writes that `df` says should fit.
#
# No two-stage dance and no reboot: btrfs grows ONLINE. The vendor's split exists
# only because resize2fs cannot grow a mounted ext4 root.
set -euo pipefail

log() { echo "grow-rootfs: $*"; }

# findmnt --nofsroot is load-bearing: without it btrfs returns /dev/mmcblk0p2[/@]
# and every downstream tool chokes on the subvolume suffix. That is the exact
# defect that made resize2fs_once fail on every card.
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
parted -s "/dev/$disk" resizepart "$pnum" 100%
# The kernel will not re-read the table of a disk with a mounted partition, so
# update just this partition's size in place. Disk + --nr rather than passing the
# partition device, which is the unambiguous form.
partx -u --nr "$pnum" "/dev/$disk"
btrfs filesystem resize max /
log "done: $(findmnt -n -o SIZE /) root"
