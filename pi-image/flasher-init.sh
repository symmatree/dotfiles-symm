#!/bin/busybox sh
#
# /init of the flasher initramfs. PID 1 of a RAM-only system, reached only by
# `reboot '0 tryboot'`. Installed into initramfs-flash.gz by build-image.sh.
#
# It re-images p2 from an image staged on p1 (coordinator#312). Nothing pivots to
# a real root, so nothing holds p2 open and it can be rewritten underneath.
#
# IT DOES THE REAL WRITE. The guards are on the inputs, not on the action: it
# proceeds only when a staged image is present, its sha256 matches, and the
# partition table parses -- and stops without writing if any of those fail. A
# fresh card has no staged image, so tryboot there is a report-and-reboot no-op.
# The worst case is a card that has to be pulled and written from a reader, which
# is the process this replaces.
#
# P2 ONLY. p1 carries the kernel, firmware and config.txt and is writable from
# the booted system as ordinary files, so the halves are updated separately and
# ping-ponged. A rootfs from one suite under a kernel from another will not come
# up: the bench side updates p1 first, reboots, then flashes p2 through here.
#
# @FLASH_DIR@ is substituted at build time.
#
# shellcheck shell=sh
# shellcheck disable=SC2317  # everything after finish() is reachable; it reboots

/bin/busybox --install -s /bin
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null

DISK_PART1=/dev/mmcblk0p1
PART=/dev/mmcblk0p2
STAGE=/mnt/@FLASH_DIR@

say() {
	echo ""
	echo "=== $* ==="
}

# Every exit goes through here: record the outcome where the bench side can read
# it on the next boot, then reboot. tryboot is one-shot, so the next boot is the
# normal system whatever happened here.
finish() {
	echo ""
	echo "RESULT: $1"
	if [ -d "$STAGE" ]; then
		echo "$1" >"$STAGE/result.txt" 2>/dev/null
		sync
	fi
	umount /mnt 2>/dev/null
	sync
	echo "rebooting in 10s"
	sleep 10
	reboot -f
	sleep 60
}

# p2's MBR entry is at 446 + 16; bytes 8..11 are its LBA start and 12..15 its
# length, both little-endian. Read from the STREAMED image rather than assumed
# from this build's BOOT_MB, so an image with a different layout still lands.
le32() {
	# shellcheck disable=SC2046,SC2086  # word-splitting od's bytes is the point
	set -- $(dd if=/tmp/mbr bs=1 skip="$1" count=4 2>/dev/null | od -An -tx1)
	echo $((0x$4$3$2$1))
}

echo ""
echo "##############################################"
echo "##  FLASHER -- tryboot reached RAM userspace ##"
echo "##############################################"
say "memory"
head -2 /proc/meminfo
say "partitions"
cat /proc/partitions

# The property the whole approach depends on. If anything mounted the root,
# writing it would corrupt a live filesystem.
if grep -q "$PART" /proc/mounts; then
	finish "ABORT: $PART is mounted; refusing to write"
fi

mount -t vfat "$DISK_PART1" /mnt || finish "ABORT: cannot mount p1"

[ -f "$STAGE/image.zip" ] || finish "NOOP: no staged image at @FLASH_DIR@/image.zip"
[ -f "$STAGE/image.sha256" ] || finish "ABORT: image.zip present but image.sha256 missing"

say "staged image"
ls -l "$STAGE"
df -h /mnt | tail -1

# Verify before writing, not after. A truncated transfer is the likely failure
# and it is silent -- unzip would happily produce a short rootfs.
say "verifying sha256 (reads the whole zip)"
want="$(cut -d' ' -f1 <"$STAGE/image.sha256")"
have="$(sha256sum "$STAGE/image.zip" | cut -d' ' -f1)"
echo "  want $want"
echo "  have $have"
if [ -z "$want" ] || [ "$want" != "$have" ]; then
	finish "ABORT: sha256 mismatch; nothing written"
fi

# The staged artifact is a WHOLE-DISK image (MBR, p1, p2) used as Actions serves
# it, so the p2 payload has to be located inside the stream.
mkfifo /tmp/stream
unzip -p "$STAGE/image.zip" >/tmp/stream &
exec 3</tmp/stream

dd bs=512 count=1 of=/tmp/mbr <&3 2>/dev/null
[ -s /tmp/mbr ] || finish "ABORT: could not read a sector from the image"

img_start="$(le32 462)"
img_count="$(le32 466)"
say "partition table from the staged image"
echo "  p2 start sector $img_start, $((img_count / 2048)) MiB"
[ "$img_start" -gt 0 ] 2>/dev/null || finish "ABORT: p2 start sector unreadable ($img_start)"

# It has to fit the partition that exists on this card. The card's p2 is normally
# larger, having been grown to fill the medium; grow-rootfs expands the new btrfs
# into the remainder on the next boot.
have_sectors="$(cat /sys/class/block/mmcblk0p2/size)"
echo "  this card's p2: $((have_sectors / 2048)) MiB"
[ "$img_count" -le "$have_sectors" ] || finish "ABORT: image p2 exceeds this card's p2"

say "writing p2 -- do not power off"
# The MBR sector is already consumed, so discard start-1 more, then stream the
# rest onto the partition.
dd bs=512 count=$((img_start - 1)) of=/dev/null <&3 2>/dev/null
if dd bs=1M of="$PART" conv=fsync <&3; then
	sync
	finish "OK: p2 written from image.zip ($want)"
else
	finish "FAIL: dd failed part-way; p2 is INCOMPLETE, pull the card"
fi
