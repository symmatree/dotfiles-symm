#!/usr/bin/env bash
#
# assemble-btrfs.sh -- lay a populated rootfs directory into a btrfs image/device
# using the coordinator SD subvolume layout (coordinator#96 / #41).
#
# This is the "assembly" step: in the real pipeline $ROOTFS comes from mmdebstrap
# (a Debian arm64 rootfs with Pi kernel/firmware dropped in); for the spike it is
# any populated directory tree. Filesystem ops here are arch-independent, so this
# runs+tests fine on an x86 host.
#
# Usage:
#   sudo ./assemble-btrfs.sh <ROOTFS_DIR> <TARGET_IMG_OR_DEV> [OUT_DIR]
#
#   ROOTFS_DIR  populated source tree (has /usr /var /home /etc /bin ... under it)
#   TARGET      a regular file (image) OR a block device; gets mkfs'd (DESTRUCTIVE)
#   OUT_DIR     where to drop side artifacts (cmdline fragment, fstab copy).
#               defaults to the directory containing TARGET.
#
# What it does:
#   mkfs.btrfs -m single  (SD write-amp: single metadata, no DUP)
#   create @ @usr @var @home @data @snapshots
#   populate each subvol from the right slice of $ROOTFS
#   create the mountpoint dirs the fstab needs (incl. @data's nest under @var)
#   chattr +C on @var/lib/docker  (CoW-on-CoW footgun for docker's overlay2)
#   write /etc/fstab into @
#   emit the kernel cmdline fragment to $OUT_DIR/cmdline.fragment
#
# shellcheck disable=SC2015  # cleanup uses the benign `cond && act || true` idiom
set -euo pipefail

# ---- args --------------------------------------------------------------------
ROOTFS="${1:?usage: assemble-btrfs.sh ROOTFS TARGET [OUT_DIR]}"
TARGET="${2:?usage: assemble-btrfs.sh ROOTFS TARGET [OUT_DIR]}"
OUT_DIR="${3:-$(dirname "$TARGET")}"

[ -d "$ROOTFS" ] || {
	echo "ROOTFS '$ROOTFS' is not a directory" >&2
	exit 1
}
mkdir -p "$OUT_DIR"

# ---- resolve TARGET to a block device ---------------------------------------
# mkfs/mount/blkid want a device. If TARGET is a regular file, back it with a
# loop device; if it is already a block device, use it directly.
LOOP=""            # set iff we attached a loop device we must detach
TOP="$(mktemp -d)" # temp mount of the btrfs top-level (subvolid=5)

cleanup() {
	mountpoint -q "$TOP" && umount "$TOP" || true
	rmdir "$TOP" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

if [ -b "$TARGET" ]; then
	DEV="$TARGET"
else
	LOOP="$(losetup --find --show "$TARGET")"
	DEV="$LOOP"
fi

echo "== mkfs.btrfs -m single on $DEV =="
mkfs.btrfs -f -m single -L rootfs "$DEV" >/dev/null

# ---- create subvolumes on the top-level -------------------------------------
# Every subvolume lives directly under subvolid=5; the mount policy (which subvol
# lands where) is expressed purely in fstab, not in the on-disk nesting.
mount -o subvolid=5 "$DEV" "$TOP"

for sv in @ @usr @var @home @data @snapshots; do
	echo "== btrfs subvolume create $sv =="
	btrfs subvolume create "$TOP/$sv" >/dev/null
done

# ---- populate each subvolume from the right slice of $ROOTFS ----------------
# Split rule:
#   /usr                 -> @usr
#   /home                -> @home
#   /var/lib/coordinator -> @data   (captures/config; NOT in @var)
#   /var  (minus that)   -> @var
#   everything else      -> @
# rsync -aHAX preserves perms/owners/hardlinks/ACLs/xattrs like a real rootfs copy.
RS=(rsync -aHAX --numeric-ids)

echo "== populate @ (root minus /usr /var /home) =="
"${RS[@]}" --exclude='/usr/***' --exclude='/var/***' --exclude='/home/***' \
	"$ROOTFS"/ "$TOP/@"/

echo "== populate @usr =="
[ -d "$ROOTFS/usr" ] && "${RS[@]}" "$ROOTFS/usr"/ "$TOP/@usr"/

echo "== populate @home =="
[ -d "$ROOTFS/home" ] && "${RS[@]}" "$ROOTFS/home"/ "$TOP/@home"/

echo "== populate @var (excluding lib/coordinator, which is @data) =="
[ -d "$ROOTFS/var" ] && "${RS[@]}" --exclude='/lib/coordinator/***' \
	"$ROOTFS/var"/ "$TOP/@var"/

echo "== populate @data from /var/lib/coordinator =="
[ -d "$ROOTFS/var/lib/coordinator" ] &&
	"${RS[@]}" "$ROOTFS/var/lib/coordinator"/ "$TOP/@data"/

# ---- create the mountpoint directories the fstab needs ----------------------
# A subvol mounted at /X needs the dir /X to exist in whatever subvol owns that
# path. @usr/@var/@home/.snapshots/boot/firmware/tmp are all children of @.
echo "== create mountpoints in @ =="
mkdir -p "$TOP/@"/{usr,var,home,tmp,boot/firmware,.snapshots}

# @data mounts at /var/lib/coordinator, i.e. INSIDE @var. So its mountpoint dir
# must exist in @var, not @. Same for docker's data-root.
echo "== create nested mountpoints in @var =="
mkdir -p "$TOP/@var"/lib/coordinator
mkdir -p "$TOP/@var"/lib/docker

# ---- chattr +C on docker's data-root (CoW-on-CoW footgun) -------------------
# docker overlay2 does its own CoW; layering btrfs CoW under it multiplies write
# amplification badly. +C on the (empty) dir makes new files nodatacow.
echo "== chattr +C @var/lib/docker =="
chattr +C "$TOP/@var/lib/docker"

# ---- write /etc/fstab into @ ------------------------------------------------
# One btrfs filesystem => one UUID shared by every subvol; the subvol= option is
# what differentiates the mounts. Order matters for `mount -a`: /var before
# /var/lib/coordinator so the nest point exists first.
UUID="$(blkid -o value -s UUID "$DEV")"
FSTAB="$TOP/@/etc/fstab"
mkdir -p "$TOP/@/etc"

echo "== write /etc/fstab (UUID=$UUID) =="
{
	echo "# coordinator SD btrfs subvolume layout (coordinator#96 / #41)"
	echo "# generated by assemble-btrfs.sh -- one btrfs FS, subvols differentiate mounts"
	# btrfs is self-consistent (CoW) and is not fsck'd at boot, so the pass field is 0
	# on every btrfs line (the ext4-style 1/2 passes don't apply).
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/" "btrfs" "noatime,compress=zstd,subvol=@"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/usr" "btrfs" "noatime,ro,subvol=@usr"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/var" "btrfs" "noatime,compress=zstd,subvol=@var"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/home" "btrfs" "noatime,compress=zstd,subvol=@home"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/var/lib/coordinator" "btrfs" "noatime,compress=zstd,subvol=@data"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/.snapshots" "btrfs" "noatime,subvol=@snapshots"
	# FAT firmware partition -- fstab line only for the spike (no FAT part here).
	# In the real image this is the boot partition's UUID/label, mounted ro.
	printf '%-42s  %-22s  %-5s  %s  0 2\n' "LABEL=bootfs" "/boot/firmware" "vfat" "ro,nofail"
	printf '%-42s  %-22s  %-5s  %s  0 0\n' "tmpfs" "/tmp" "tmpfs" "defaults,noatime,nosuid,nodev"
} >"$FSTAB"

cp "$FSTAB" "$OUT_DIR/fstab.generated"

# ---- emit the kernel cmdline fragment ---------------------------------------
# The image's /boot/firmware/cmdline.txt needs these so the Pi mounts @ as root.
# No real boot partition in the spike, so we drop it as a side artifact.
CMDLINE="$OUT_DIR/cmdline.fragment"
echo "rootfstype=btrfs rootflags=subvol=@" >"$CMDLINE"
echo "== wrote cmdline fragment -> $CMDLINE =="

# ---- show what we built -----------------------------------------------------
echo "== btrfs subvolume list =="
btrfs subvolume list "$TOP"

umount "$TOP"
echo "== assembly complete =="
