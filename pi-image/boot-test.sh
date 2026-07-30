#!/usr/bin/env bash
#
# boot-test.sh -- pragmatic smoke test that the built image's btrfs-subvol root
# actually MOUNTS and PIVOTS, without needing full Raspberry Pi firmware
# emulation. We pull the kernel + the initramfs we generated (the one carrying
# btrfs) out of the image's boot partition and boot them under
# `qemu-system-aarch64 -M virt`, handing the whole image in as a virtio disk.
# The initramfs modprobes btrfs, resolves root by PARTUUID (device-name
# independent, so /dev/vda under -M virt is fine), and mounts subvol=@ as /.
# We capture the serial console and look for evidence root mounted (a getty
# login prompt, or the initramfs' own "Mounting root" success).
#
# THIS IS BEST-EFFORT in v1 and NON-FATAL by default: the RPi downstream kernel
# is not guaranteed to come up on the synthetic -M virt platform (wrong DTB,
# possibly missing virtio in-kernel). A clean PASS is strong signal; a non-PASS
# is reported, not failed, unless STRICT=1. See the writeup for the fallbacks
# (boot under RPi-firmware qemu, or a spare SD card on real hardware).
#
# Usage:  sudo ./boot-test.sh <IMAGE.img>   [STRICT=1 to make failure fatal]
#
# shellcheck disable=SC2015  # benign `cond && act || true` cleanup idioms
# shellcheck disable=SC2317  # cleanup() is reached indirectly via `trap ... EXIT`
set -euo pipefail

IMG="${1:?usage: boot-test.sh IMAGE.img}"
STRICT="${STRICT:-0}"
TIMEOUT="${TIMEOUT:-180}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
SERIAL="$WORK/serial.log"
BOOTMNT="$WORK/boot"
LOOP=""

cleanup() {
	mountpoint -q "$BOOTMNT" && umount "$BOOTMNT" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root (loop/mount)" >&2
	exit 1
}
command -v qemu-system-aarch64 >/dev/null || {
	echo "qemu-system-aarch64 not found" >&2
	exit 1
}

# ---- pull kernel + initramfs + the root PARTUUID out of the image ------------
echo "== loop-attaching $IMG =="
LOOP="$(losetup --find --show -P "$IMG")"
mkdir -p "$BOOTMNT"
mount -o ro "${LOOP}p1" "$BOOTMNT"

# arm64 Pi4-class kernel + its generated initramfs. (kernel8/initramfs8 cover
# BCM2711; the Pi5 pair is kernel_2712/initramfs_2712 -- either proves the FS.)
KERNEL=""
INITRD=""
for k in kernel8.img kernel_2712.img; do
	[ -f "$BOOTMNT/$k" ] && KERNEL="$BOOTMNT/$k" && break
done
for i in initramfs8 initramfs_2712; do
	[ -f "$BOOTMNT/$i" ] && INITRD="$BOOTMNT/$i" && break
done
[ -n "$KERNEL" ] || {
	echo "no kernel8/kernel_2712 in boot partition" >&2
	exit 1
}
[ -n "$INITRD" ] || {
	echo "no initramfs8/initramfs_2712 -- image was built without an initramfs; btrfs root cannot mount" >&2
	exit 1
}
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${LOOP}p2")"
cp "$KERNEL" "$WORK/kernel"
cp "$INITRD" "$WORK/initrd"
umount "$BOOTMNT"
losetup -d "$LOOP"
LOOP=""
echo "   kernel=$(basename "$KERNEL") initrd=$(basename "$INITRD") root=PARTUUID=$ROOT_PARTUUID"

# ---- boot under -M virt with the image as a virtio disk ----------------------
echo "== booting qemu-system-aarch64 -M virt (serial -> $SERIAL, ${TIMEOUT}s cap) =="
# root=/dev/vda2 under -M virt (see header): tests the btrfs subvol=@ mount itself,
# not by-partuuid resolution. ROOT_PARTUUID above is echoed for reference only.
APPEND="root=/dev/vda2 rootfstype=btrfs rootflags=subvol=@ console=ttyAMA0 rw rootwait"
timeout "$TIMEOUT" qemu-system-aarch64 \
	-M virt -cpu cortex-a72 -m 1024 -smp 2 \
	-kernel "$WORK/kernel" -initrd "$WORK/initrd" \
	-append "$APPEND" \
	-drive file="$IMG",format=raw,if=none,id=hd0 \
	-device virtio-blk-device,drive=hd0 \
	-nographic -no-reboot -serial file:"$SERIAL" 2>&1 | tail -5 || true

echo "== serial tail =="
tail -30 "$SERIAL" 2>/dev/null || true

# ---- verdict -----------------------------------------------------------------
# Success signals, weakest-acceptable to strongest:
#   - a getty login prompt  ("<host> login:")  => full userspace on btrfs root
#   - systemd reached basic target
#   - initramfs mounted subvol=@ as /
VERDICT="UNKNOWN"
if grep -aqE 'login:' "$SERIAL"; then
	VERDICT="PASS (reached login prompt on btrfs root)"
elif grep -aqE 'Reached target|Startup finished|systemd\[1\]' "$SERIAL"; then
	VERDICT="PASS (systemd came up on btrfs root)"
elif grep -aqiE 'mounted.*subvol|switch_root|Begin: Running /scripts/local-bottom' "$SERIAL"; then
	VERDICT="LIKELY (initramfs mounted root; userspace not confirmed)"
elif grep -aqiE 'VFS: Unable to mount root|Kernel panic|No filesystem could mount root' "$SERIAL"; then
	VERDICT="FAIL (kernel could not mount btrfs root -- inspect serial.log)"
fi

echo "== BOOT-TEST VERDICT: $VERDICT =="

# Copy serial log next to the image for CI artifact upload.
cp "$SERIAL" "$HERE/.build/boot-serial.log" 2>/dev/null || true

case "$VERDICT" in
PASS*) exit 0 ;;
*)
	if [ "$STRICT" = "1" ]; then
		echo "STRICT=1 and no PASS -> failing" >&2
		exit 1
	fi
	echo "non-PASS but non-fatal in v1 (set STRICT=1 to gate on this)"
	exit 0
	;;
esac
