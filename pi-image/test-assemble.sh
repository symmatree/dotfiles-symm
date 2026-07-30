#!/usr/bin/env bash
#
# test-assemble.sh -- local, hardware-free proof of the coordinator btrfs
# subvolume assembly. Builds a dummy rootfs, a ~1.5 GB loopback image, runs
# assemble-btrfs.sh, then mounts the result PER THE GENERATED FSTAB and verifies:
#   - all six subvolumes exist
#   - files land in the right subvol
#   - /usr is mounted ro, and `mount -o remount,rw /usr` works
#   - @data nests correctly under /var
#   - the fstab + cmdline artifacts are correct
#
# Run: sudo ./test-assemble.sh   (needs losetup + mkfs.btrfs)
#
# shellcheck disable=SC2015  # intentional `cond && pass || fail` assertion idiom (both just echo)
# shellcheck disable=SC2317  # cleanup() is reached indirectly via `trap ... EXIT`
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
ROOTFS="$WORK/rootfs"
IMG="$WORK/coord.img"
MNT="$WORK/mnt"
OUT="$WORK/out"
FAIL=0

pass() { echo "PASS: $*"; }
fail() {
	echo "FAIL: $*"
	FAIL=1
}

# ---- cleanup: unmount everything under $MNT (deepest first), detach loops ----
cleanup() {
	# unmount in reverse-depth order so nested mounts release cleanly
	if [ -d "$MNT" ]; then
		for m in $(findmnt -rno TARGET | grep "^$MNT" | awk '{ print length, $0 }' |
			sort -rn | cut -d' ' -f2-); do
			umount "$m" 2>/dev/null || true
		done
	fi
	losetup -j "$IMG" 2>/dev/null | cut -d: -f1 | while read -r l; do
		losetup -d "$l" 2>/dev/null || true
	done
	rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. build a dummy rootfs -------------------------------------------------
echo "### building dummy rootfs at $ROOTFS"
mkdir -p "$ROOTFS"/{usr/bin,var/lib/coordinator,var/log,home/pi,etc,bin}
echo "i am /usr/bin/hello" >"$ROOTFS/usr/bin/hello"
echo "i am /bin/sh-ish" >"$ROOTFS/bin/toybox"
echo "coordinator=on" >"$ROOTFS/etc/coordinator.conf"
echo "MARKER root-etc" >"$ROOTFS/etc/marker"
echo "capture-0001.mcap placeholder" >"$ROOTFS/var/lib/coordinator/capture-0001"
echo "MARKER data" >"$ROOTFS/var/lib/coordinator/marker"
echo "some log line" >"$ROOTFS/var/log/boot.log"
echo "MARKER var" >"$ROOTFS/var/marker"
echo "MARKER home" >"$ROOTFS/home/pi/marker"
echo "MARKER usr" >"$ROOTFS/usr/marker"

# ---- 2. make a ~1.5 GB loopback image ---------------------------------------
echo "### creating 1.5 GB sparse image at $IMG"
truncate -s 1536M "$IMG"

# ---- 3. run the assembly ----------------------------------------------------
echo "### running assemble-btrfs.sh"
mkdir -p "$OUT"
"$HERE/assemble-btrfs.sh" "$ROOTFS" "$IMG" "$OUT"

# ---- 4. mount the result per the generated fstab ----------------------------
# We can't just `mount -a` (that would use the host's /etc/fstab), so we replay
# the generated fstab's btrfs lines against a fresh loop device, rewriting the
# targets under $MNT. This exercises the exact options + subvol= the image ships.
echo "### mounting result under $MNT per generated fstab"
LOOP="$(losetup --find --show "$IMG")"
mkdir -p "$MNT"

# Replay every btrfs line from the generated fstab, in file order (so /var
# precedes /var/lib/coordinator). tmpfs/vfat lines are validated separately.
while read -r _src tgt fstype opts _dump _pass; do
	[ "$fstype" = "btrfs" ] || continue
	dest="$MNT$tgt"
	mkdir -p "$dest"
	mount -t btrfs -o "$opts" "$LOOP" "$dest"
	echo "  mounted $opts -> $dest"
done <"$OUT/fstab.generated"

echo "### findmnt view"
findmnt -R "$MNT" || true

# ---- 5. assertions ----------------------------------------------------------
echo "### assertions"

# 5a. all six subvolumes present
SUBVOLS="$(btrfs subvolume list "$MNT" | awk '{print $NF}' | sort | tr '\n' ' ')"
echo "  subvols found: $SUBVOLS"
for want in @ @usr @var @home @data @snapshots; do
	case " $SUBVOLS " in
	*" $want "*) pass "subvolume $want exists" ;;
	*) fail "subvolume $want MISSING" ;;
	esac
done

# 5b. files landed in the right subvol (checked via the mounted tree)
[ -f "$MNT/usr/bin/hello" ] && pass "/usr/bin/hello in @usr" || fail "/usr/bin/hello missing"
[ -f "$MNT/etc/coordinator.conf" ] && pass "/etc/... in @" || fail "/etc/coordinator.conf missing"
[ -f "$MNT/bin/toybox" ] && pass "/bin/toybox in @" || fail "/bin/toybox missing"
[ -f "$MNT/home/pi/marker" ] && pass "/home/pi/marker in @home" || fail "/home marker missing"
[ -f "$MNT/var/log/boot.log" ] && pass "/var/log in @var" || fail "/var/log missing"
[ -f "$MNT/var/lib/coordinator/capture-0001" ] && pass "capture in @data" || fail "capture missing"

# 5c. the split is EXCLUSIVE -- /usr must NOT have leaked into @
if mount -o subvolid=5 "$LOOP" "$MNT/.snapshots" 2>/dev/null; then :; fi # noop guard
# check @ subvol directly: mount @ alone at a scratch point and confirm /usr empty
SCRATCH="$WORK/scratch-at"
mkdir -p "$SCRATCH"
mount -t btrfs -o "subvol=@" "$LOOP" "$SCRATCH"
if [ -z "$(ls -A "$SCRATCH/usr" 2>/dev/null)" ]; then
	pass "@/usr is an empty mountpoint (usr did not leak into @)"
else
	fail "@/usr is NOT empty -- usr content leaked into @: $(ls -A "$SCRATCH/usr")"
fi
# and @var must NOT contain lib/coordinator payload (it went to @data)
if [ -z "$(ls -A "$SCRATCH" 2>/dev/null)" ]; then :; fi
umount "$SCRATCH"
mount -t btrfs -o "subvol=@var" "$LOOP" "$SCRATCH"
if [ ! -f "$SCRATCH/lib/coordinator/capture-0001" ]; then
	pass "@var/lib/coordinator is bare mountpoint (data did not leak into @var)"
else
	fail "@var contains coordinator payload -- should be in @data only"
fi
umount "$SCRATCH"
rmdir "$SCRATCH"

# 5d. /usr is mounted ro, and remount,rw works
USR_OPTS="$(findmnt -rno OPTIONS "$MNT/usr")"
case ",$USR_OPTS," in *,ro,*) pass "/usr mounted ro (opts: $USR_OPTS)" ;; *) fail "/usr NOT ro (opts: $USR_OPTS)" ;; esac
if touch "$MNT/usr/should-fail" 2>/dev/null; then
	fail "wrote to ro /usr -- should have been refused"
	rm -f "$MNT/usr/should-fail"
else
	pass "write to ro /usr refused as expected"
fi
if mount -o remount,rw "$MNT/usr" 2>/dev/null && touch "$MNT/usr/maint-ok"; then
	pass "remount,rw /usr succeeded and write worked (maintenance path)"
	rm -f "$MNT/usr/maint-ok"
	mount -o remount,ro "$MNT/usr"
else
	fail "remount,rw /usr failed"
fi

# 5e. @data nests correctly under /var (it is a distinct mount)
DATA_SRC="$(findmnt -rno SOURCE "$MNT/var/lib/coordinator")"
if echo "$DATA_SRC" | grep -q 'subvol=/@data\|\[/@data\]'; then
	pass "/var/lib/coordinator is the @data subvol ($DATA_SRC)"
else
	# findmnt renders btrfs source as dev[/@data]; accept any form that names @data
	case "$DATA_SRC" in *@data*) pass "/var/lib/coordinator is @data ($DATA_SRC)" ;;
	*) fail "/var/lib/coordinator not @data ($DATA_SRC)" ;; esac
fi

# 5f. fstab content sanity
FS="$OUT/fstab.generated"
grep -q 'subvol=@usr' "$FS" && grep -q ',ro,' <(grep '@usr' "$FS") && pass "fstab: /usr has ro,subvol=@usr" || fail "fstab: /usr ro line wrong"
grep -q 'subvol=@data' "$FS" && pass "fstab: @data present" || fail "fstab: @data line missing"
# /var must precede /var/lib/coordinator in file order
if [ "$(grep -n 'subvol=@var\b' "$FS" | head -1 | cut -d: -f1)" -lt \
	"$(grep -n 'subvol=@data' "$FS" | head -1 | cut -d: -f1)" ]; then
	pass "fstab: /var ordered before /var/lib/coordinator"
else
	fail "fstab: /var must come before /var/lib/coordinator"
fi

# 5g. cmdline fragment
CM="$(cat "$OUT/cmdline.fragment")"
[ "$CM" = "rootfstype=btrfs rootflags=subvol=@" ] && pass "cmdline fragment correct: $CM" || fail "cmdline wrong: $CM"

# 5h. docker data-root is nodatacow (chattr +C took)
mount -t btrfs -o "subvol=@var" "$MNT/.snapshots" 2>/dev/null || mkdir -p "$WORK/varmnt"
mount -t btrfs -o "subvol=@var" "$LOOP" "$WORK/varmnt" 2>/dev/null && {
	ATTRS="$(lsattr -d "$WORK/varmnt/lib/docker" 2>/dev/null | awk '{print $1}')"
	case "$ATTRS" in *C*) pass "@var/lib/docker is nodatacow (lsattr: $ATTRS)" ;; *) fail "docker dir not +C (lsattr: $ATTRS)" ;; esac
	umount "$WORK/varmnt"
}

echo
echo "### generated fstab:"
cat "$OUT/fstab.generated"
echo
if [ "$FAIL" -eq 0 ]; then echo "### ALL CHECKS PASSED"; else echo "### SOME CHECKS FAILED"; fi
exit "$FAIL"
