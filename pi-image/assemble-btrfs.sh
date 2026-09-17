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
#   mkfs.btrfs -m $METADATA  (single on SD, dup on NVMe -- per-medium knob)
#   create @ @usr @var @home @data @scratch @snapshots
#   populate each subvol from the right slice of $ROOTFS
#   create the mountpoint dirs the fstab needs (incl. @data's nest under @var)
#   chattr +C on @var/lib/docker and @scratch  (nodatacow; see below)
#   write /etc/fstab into @  (@data mounts at $DATA_MOUNT)
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

# ---- role knobs (env; defaults = coordinator) -------------------------------
# The subvolume graph is shared fleet-wide (coordinator#96 "one btrfs layout,
# per-role knobs"); only these differ between roles/media:
#   DATA_MOUNT  where the @data subvol mounts (coordinator: /var/lib/coordinator,
#               pocketterm: /var/lib/store). Must live under /var (it nests in @var).
#   METADATA    mkfs.btrfs metadata profile: single on SD, dup on NVMe.
DATA_MOUNT="${DATA_MOUNT:-/var/lib/coordinator}"
METADATA="${METADATA:-single}"
case "$DATA_MOUNT" in
/var/*) DATA_UNDER_VAR="${DATA_MOUNT#/var}" ;; # e.g. /lib/coordinator, /lib/store
*)
	echo "DATA_MOUNT must be under /var (got '$DATA_MOUNT')" >&2
	exit 1
	;;
esac

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

echo "== mkfs.btrfs -m $METADATA on $DEV =="
mkfs.btrfs -f -m "$METADATA" -L rootfs "$DEV" >/dev/null

# ---- create subvolumes on the top-level -------------------------------------
# Every subvolume lives directly under subvolid=5; the mount policy (which subvol
# lands where) is expressed purely in fstab, not in the on-disk nesting.
mount -o subvolid=5 "$DEV" "$TOP"

for sv in @ @usr @var @home @data @scratch @snapshots; do
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

echo "== populate @var (excluding ${DATA_UNDER_VAR}, which is @data) =="
[ -d "$ROOTFS/var" ] && "${RS[@]}" --exclude="${DATA_UNDER_VAR}/***" \
	"$ROOTFS/var"/ "$TOP/@var"/

echo "== populate @data from $DATA_MOUNT (if present in the rootfs) =="
[ -d "$ROOTFS$DATA_MOUNT" ] &&
	"${RS[@]}" "$ROOTFS$DATA_MOUNT"/ "$TOP/@data"/

# @scratch is ephemeral (WAL/sim); it ships empty and is never populated, which
# is also what lets chattr +C below cover everything that will ever live in it.

# ---- create the mountpoint directories the fstab needs ----------------------
# A subvol mounted at /X needs the dir /X to exist in whatever subvol owns that
# path. @usr/@var/@home/.snapshots/boot/firmware/tmp are all children of @.
echo "== create mountpoints in @ =="
mkdir -p "$TOP/@"/{usr,var,home,tmp,scratch,boot/firmware,.snapshots}

# @data mounts under /var (e.g. /var/lib/coordinator or /var/lib/store), i.e.
# INSIDE @var -- so its mountpoint dir must exist in @var, not @. Same for
# docker's data-root.
echo "== create nested mountpoints in @var =="
mkdir -p "$TOP/@var${DATA_UNDER_VAR}"
mkdir -p "$TOP/@var"/lib/docker

# ---- nodatacow, via the inode flag ------------------------------------------
# Per-directory with chattr +C, NOT a mount option. btrfs(5): "Most mount options
# apply to the whole filesystem and only options in the first mounted subvolume
# will take effect [...] you can't set per-subvolume nodatacow". / is mounted from
# the initramfs before fstab is read, so @ is always the first mounted subvolume
# and a nodatacow on any later line is discarded with no error and no warning.
#
# +C is inherited by files created afterwards and does not convert existing ones,
# so it only means anything on an empty directory. Both of these are empty here.
#
#   @var/lib/docker  overlay2 does its own CoW; btrfs CoW underneath multiplies
#                    write amplification badly
#   @scratch         exists to BE the write-heavy append-and-overwrite area
#                    (WAL/sim), which is the pattern CoW is worst at
echo "== chattr +C @var/lib/docker, @scratch =="
chattr +C "$TOP/@var/lib/docker"
chattr +C "$TOP/@scratch"

# Read it back: a flag that silently did not take is the exact failure this
# replaces, so do not just announce it.
for d in "$TOP/@var/lib/docker" "$TOP/@scratch"; do
	attrs="$(lsattr -d "$d" | awk '{print $1}')"
	case "$attrs" in
	*C*) echo "   ${d#"$TOP"/}: $attrs" ;;
	*)
		echo "!! chattr +C did not take on ${d#"$TOP"/} (lsattr: $attrs)" >&2
		exit 1
		;;
	esac
done

# ---- write /etc/fstab into @ ------------------------------------------------
# One btrfs filesystem => one UUID shared by every subvol; the subvol= option is
# what differentiates the mounts. Order matters for `mount -a`: /var before the
# @data mount ($DATA_MOUNT) so the nest point exists first.
UUID="$(blkid -o value -s UUID "$DEV")"
FSTAB="$TOP/@/etc/fstab"
mkdir -p "$TOP/@/etc"

# /boot/firmware is keyed by PARTUUID in the real image (unique to this disk, so a
# stray stock 'bootfs'-labelled SD can never be mounted here). Falls back to
# LABEL=bootfs only on the hardware-free test-assemble path (no FAT partition).
BOOTFS_SPEC="${BOOT_PARTUUID:+PARTUUID=$BOOT_PARTUUID}"
BOOTFS_SPEC="${BOOTFS_SPEC:-LABEL=bootfs}"

echo "== write /etc/fstab (UUID=$UUID, boot=$BOOTFS_SPEC) =="
{
	echo "# fleet btrfs subvolume layout (coordinator#96 / #41)"
	echo "# generated by assemble-btrfs.sh -- one btrfs FS, subvols differentiate mounts"
	# btrfs is self-consistent (CoW) and is not fsck'd at boot, so the pass field is 0
	# on every btrfs line (the ext4-style 1/2 passes don't apply).
	#
	# Nothing btrfs-specific here beyond subvol=. Those options are per-filesystem
	# and only the FIRST mounted subvolume's take effect (btrfs(5)) -- always @,
	# mounted from the initramfs before fstab is read -- so anything set on a later
	# line is silently discarded, and a mixed set makes two units from one build
	# behave differently. nodatacow is done with chattr +C above for that reason;
	# compression is off, and if it ever returns it goes on EVERY line.
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/" "btrfs" "noatime,subvol=@"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/usr" "btrfs" "noatime,ro,subvol=@usr"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/var" "btrfs" "noatime,subvol=@var"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/home" "btrfs" "noatime,subvol=@home"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "$DATA_MOUNT" "btrfs" "noatime,subvol=@data"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/scratch" "btrfs" "noatime,subvol=@scratch"
	printf 'UUID=%s  %-22s  %-5s  %s  0 0\n' "$UUID" "/.snapshots" "btrfs" "noatime,subvol=@snapshots"
	# FAT firmware partition -- fstab line only for the spike (no FAT part here).
	# Real image keys this by PARTUUID (BOOTFS_SPEC) so no stray 'bootfs' card mounts here.
	#
	# NO nofail, matching the vendor image's own fstab. systemd.mount(5): a local
	# mount gains "a Before= dependency on local-fs.target unless one or more mount
	# options among nofail, x-systemd.wanted-by=, and x-systemd.required-by= is
	# set" -- so nofail would drop boot-firmware.mount out of the ordering that
	# everything reading /boot/firmware depends on. The cost of omitting it is that
	# an unmountable FAT partition stops the boot, which is correct here: the
	# firmware already read that partition to reach the kernel.
	printf '%-42s  %-22s  %-5s  %s  0 2\n' "$BOOTFS_SPEC" "/boot/firmware" "vfat" "defaults"
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
