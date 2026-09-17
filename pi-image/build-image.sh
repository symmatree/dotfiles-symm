#!/usr/bin/env bash
#
# build-image.sh -- convert the official Raspberry Pi OS Lite (Trixie, arm64)
# image into the coordinator btrfs-subvolume layout and emit a flashable .img.
#
# The vendor image is taken as-is -- kernel, firmware, raspberrypi-sys-mods and
# the HAT/overlay glue are already correct -- and only its rootfs is re-laid into
# the @ @usr @var @home @data @scratch @snapshots subvolumes by assemble-btrfs.sh,
# after which the boot config is fixed up to mount a btrfs-subvol root.
#
# WHERE THIS RUNS: an arm64 host with a btrfs-capable kernel (CI:
# ubuntu-24.04-arm), as root -- loop, mount and mkfs are all required. arm64
# matters because the RPi userland is arm64: the rootfs can be chrooted NATIVELY,
# with no qemu-user, which is what makes the offline initramfs rebuild possible.
#
# Usage:
#   sudo ./build-image.sh [ROLE] [OUT_IMG]
#     ROLE     device role -> pi-image/roles/<ROLE>.env  (default: coordinator)
#     OUT_IMG  final image path (default: pi-image/.build/<ROLE>-pi-<date>.img)
#
# shellcheck disable=SC2015  # a few benign `cond && act || true` cleanup idioms
set -euo pipefail

# ---- pinned upstream image ---------------------------------------------------
# The current Raspberry Pi OS Lite arm64 release. Pinned by URL + sha256 so a
# rebuild is reproducible and a swapped-out upstream is caught. To bump: change
# URL, date and sha together.
#
# THE SUITE IS A CROSS-REPO PIN. The camera runs in a container that installs
# libcamera from the same Pi archive suite as the host, so the two have to match.
# If this moves, containers/campod-camera's RPI_SUITE moves in the same window
# (coordinator#219).
RPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-09-15/2026-09-15-raspios-trixie-arm64-lite.img.xz"
RPIOS_SHA256="cdf4f3bfac35ae947b46e4e767f935453810549779ac3290e05a6754aee627e5"

# ---- paths -------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/.build" # scratch + artifacts (gitignored)

# ---- role selection ----------------------------------------------------------
# ROLE picks pi-image/roles/<ROLE>.env, which sets the per-role knobs: DATA_MOUNT,
# METADATA, and optionally CONFIG_APPEND + OVERLAY_ZIP_URL/OVERLAY_ZIP_SHA256. The
# btrfs subvolume graph is shared across roles (coordinator#96); only these knobs
# differ. Defaults to coordinator so existing no-arg callers are unchanged.
ROLE="${1:-coordinator}"
ROLE_ENV="$HERE/roles/$ROLE.env"
[ -f "$ROLE_ENV" ] || {
	echo "unknown role '$ROLE' (no $ROLE_ENV)" >&2
	exit 1
}
# shellcheck source=/dev/null
. "$ROLE_ENV"
DATA_MOUNT="${DATA_MOUNT:-/var/lib/coordinator}"
METADATA="${METADATA:-single}"
# Roles own their kernel command line, so /boot/firmware is written by the image
# rather than edited on the running device.
#   CMDLINE_REMOVE  space-separated GLOB patterns; any matching token is dropped
#   CMDLINE_APPEND  tokens added at the end, AFTER the btrfs root flags
# roles/<role>.env is SOURCED by bash, so a value containing a space must be
# quoted: `VAR=a b` assigns "a" and then runs `b`, which under set -e kills the
# build during sourcing.
CMDLINE_REMOVE="${CMDLINE_REMOVE:-}"
CMDLINE_APPEND="${CMDLINE_APPEND:-}"
export DATA_MOUNT METADATA # consumed by assemble-btrfs.sh

DL="$BUILD/$(basename "$RPIOS_URL")"
SRC_IMG="${DL%.xz}"       # decompressed vendor image
ROOTFS="$BUILD/rootfs"    # vendor rootfs extracted here
BOOTSTAGE="$BUILD/bootfs" # vendor /boot/firmware staged + fixed up here
OUT_IMG="${2:-$BUILD/${ROLE}-pi-$(date +%Y%m%d).img}"

# Partition geometry of the target image.
BOOT_MB=512   # FAT32 /boot/firmware
SLACK_MB=1536 # free space on top of the rootfs footprint

require_root() {
	[ "$(id -u)" -eq 0 ] || {
		echo "must run as root (loop/mount/mkfs)" >&2
		exit 1
	}
}

require_tools() {
	local miss=0 t
	for t in xz curl sha256sum losetup mount umount rsync parted \
		mkfs.vfat mkfs.btrfs blkid sfdisk chroot unzip chattr lsattr; do
		command -v "$t" >/dev/null 2>&1 || {
			echo "missing tool: $t" >&2
			miss=1
		}
	done
	[ "$miss" -eq 0 ] || exit 1
}

# ---- global cleanup ----------------------------------------------------------
# Track everything we attach/mount and release it deepest-first on EXIT.
SRC_LOOP=""
DST_LOOP=""
declare -a MOUNTS=() # mountpoints, in mount order; unmounted in reverse

track_mount() { MOUNTS+=("$1"); }

cleanup() {
	local i
	for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
		mountpoint -q "${MOUNTS[i]}" && umount -R "${MOUNTS[i]}" 2>/dev/null || true
	done
	[ -n "$DST_LOOP" ] && losetup -d "$DST_LOOP" 2>/dev/null || true
	[ -n "$SRC_LOOP" ] && losetup -d "$SRC_LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# losetup -P asks the KERNEL to re-read the partition table, but the /dev/loopNpM
# device nodes are created asynchronously by udev. Using them on the next line is
# a race; when it is lost the next command fails with a confusing ENOENT on the
# partition device.
wait_for_partitions() {
	local dev="$1" want="$2" i p missing
	udevadm settle --timeout=30 >/dev/null 2>&1 || true
	for ((i = 0; i < 100; i++)); do
		missing=0
		for ((p = 1; p <= want; p++)); do
			[ -b "${dev}p${p}" ] || missing=1
		done
		[ "$missing" -eq 0 ] && return 0
		sleep 0.1
	done
	echo "!! partition nodes for $dev never appeared after 10s" >&2
	ls -l "${dev}"* >&2 2>&1 || true
	return 1
}

# =============================================================================
# 1. fetch + verify + decompress the vendor image
# =============================================================================
fetch_source() {
	mkdir -p "$BUILD"
	if [ ! -f "$DL" ]; then
		echo "== downloading $RPIOS_URL =="
		curl -fL --retry 3 -o "$DL" "$RPIOS_URL"
	fi
	echo "== verifying sha256 =="
	echo "$RPIOS_SHA256  $DL" | sha256sum -c -
	if [ ! -f "$SRC_IMG" ]; then
		echo "== decompressing =="
		xz -dk -T0 "$DL"
	fi
}

# =============================================================================
# 2. loop-attach the vendor image and split rootfs / bootfs out of it
#    Vendor layout: p1 = FAT32 /boot/firmware, p2 = ext4 root.
# =============================================================================
extract_source() {
	echo "== loop-attaching vendor image =="
	SRC_LOOP="$(losetup --find --show -P "$SRC_IMG")"
	echo "   $SRC_LOOP (p1=${SRC_LOOP}p1 boot, p2=${SRC_LOOP}p2 root)"
	wait_for_partitions "$SRC_LOOP" 2

	local sroot="$BUILD/src-root" sboot="$BUILD/src-boot"
	mkdir -p "$sroot" "$sboot" "$ROOTFS" "$BOOTSTAGE"

	mount -o ro "${SRC_LOOP}p2" "$sroot"
	track_mount "$sroot"
	mount -o ro "${SRC_LOOP}p1" "$sboot"
	track_mount "$sboot"

	echo "== rsync vendor rootfs -> $ROOTFS =="
	# --numeric-ids so uid/gid survive; the mounted /boot/firmware is a separate
	# fs so it is not descended into (rsync without -x still won't cross into it
	# because we copy from $sroot where firmware is just an empty mountpoint).
	rsync -aHAX --numeric-ids "$sroot"/ "$ROOTFS"/

	echo "== copy vendor /boot/firmware -> $BOOTSTAGE (staged for fixups) =="
	rsync -aHAX --numeric-ids "$sboot"/ "$BOOTSTAGE"/

	umount "$sboot" && MOUNTS=("${MOUNTS[@]/$sboot/}")
	umount "$sroot" && MOUNTS=("${MOUNTS[@]/$sroot/}")
	losetup -d "$SRC_LOOP"
	SRC_LOOP=""
}

# =============================================================================
# 2b. apply role-specific boot config: append config.txt lines and install any
#     device-tree overlays (e.g. the PocketTerm panel). No-op for coordinator.
#     Runs on the staged $BOOTSTAGE before the initramfs regen reads config.txt.
# =============================================================================
apply_role_bootfs() {
	if [ -n "${CONFIG_APPEND:-}" ]; then
		local ca="$HERE/$CONFIG_APPEND"
		[ -f "$ca" ] || {
			echo "CONFIG_APPEND not found: $ca" >&2
			exit 1
		}
		echo "== append role config.txt ($ROLE) <- $CONFIG_APPEND =="
		{
			printf '\n'
			cat "$ca"
		} >>"$BOOTSTAGE/config.txt"

		# Print the directives as they now sit in config.txt, with the section
		# header that governs them. An appended line that landed inside a [cm4] or
		# [cm5] section is silently inert on other models, and nothing else in the
		# build would notice.
		echo "-- config.txt now ends with (directives only) --"
		grep -vE '^\s*(#|$)' "$BOOTSTAGE/config.txt" | tail -n 12
	fi

	if [ -n "${OVERLAY_ZIP_URL:-}" ]; then
		: "${OVERLAY_ZIP_SHA256:?OVERLAY_ZIP_SHA256 required alongside OVERLAY_ZIP_URL}"
		echo "== fetch + verify device-tree overlays: $OVERLAY_ZIP_URL =="
		local zip="$BUILD/role-overlays.zip" ex="$BUILD/role-overlays"
		curl -fL --retry 3 -o "$zip" "$OVERLAY_ZIP_URL"
		echo "$OVERLAY_ZIP_SHA256  $zip" | sha256sum -c -
		rm -rf "$ex"
		mkdir -p "$ex" "$BOOTSTAGE/overlays"
		unzip -oq "$zip" -d "$ex"
		echo "== install *.dtbo -> bootfs/overlays =="
		find "$ex" -name '*.dtbo' -exec cp -v {} "$BOOTSTAGE/overlays/" \;
	fi
}

# =============================================================================
# 2c-bis. install grow-rootfs
#     A flashed image is only as large as it was built, so the rest of the card
#     stays unpartitioned until something grows it. See grow-rootfs.sh.
# =============================================================================
install_grow_rootfs() {
	echo "== install /usr/local/sbin/grow-rootfs + unit =="
	install -D -m 0755 "$HERE/grow-rootfs.sh" "$ROOTFS/usr/local/sbin/grow-rootfs"

	# Unit in /etc/systemd/system, not /usr/lib, so it lives in @ and does not
	# depend on @usr being writable. Ordered before multi-user.target so the card
	# is full-size before anything that writes at volume starts.
	mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
	cat >"$ROOTFS/etc/systemd/system/grow-rootfs.service" <<-'EOF'
		[Unit]
		Description=Grow the btrfs root to fill the card
		DefaultDependencies=no
		After=local-fs.target
		Before=multi-user.target shutdown.target
		Conflicts=shutdown.target

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		ExecStart=/usr/local/sbin/grow-rootfs

		[Install]
		WantedBy=multi-user.target
	EOF
	ln -sf ../grow-rootfs.service \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/grow-rootfs.service"

	# Show what landed rather than only that we tried. A step that announces
	# itself but does not prove itself looks identical in the log whether it
	# worked or not.
	ls -l "$ROOTFS/usr/local/sbin/grow-rootfs" \
		"$ROOTFS/etc/systemd/system/grow-rootfs.service" \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/grow-rootfs.service"
}

# =============================================================================
# 2c. write the image manifest into the rootfs
#     A card otherwise cannot say which image it came from: the date is in the
#     artifact filename and nothing lands in the rootfs (coordinator#96).
#
#       /etc/fleet-image                   the canonical key=value record
#       /etc/issue.d/20-fleet-image.issue  shown pre-login on console and serial
#       fleet-image-id.service             one line per boot into the journal
#
#     Every field is fixed at build time and none is derivable from another, so
#     the manifest cannot drift from what it describes.
# =============================================================================
write_manifest() {
	local img base src
	img="$(basename "$OUT_IMG")"    # the artifact name, as published (raw .img since #47)
	base="$(basename "$RPIOS_URL")" # carries the suite and release date
	src="${GITHUB_SHA:-$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)}"

	echo "== write /etc/fleet-image =="
	mkdir -p "$ROOTFS/etc/issue.d" "$ROOTFS/etc/systemd/system/multi-user.target.wants"
	cat >"$ROOTFS/etc/fleet-image" <<-EOF
		# Written by dotfiles-symm pi-image/build-image.sh at build time.
		# Immutable: describes the image this card was flashed from, not current state.
		IMAGE=$img
		ROLE=$ROLE
		SOURCE=$src
		BASE=$base
	EOF
	cat "$ROOTFS/etc/fleet-image"

	# Pre-login banner. issue.d is a drop-in dir (raspberrypi-sys-mods already
	# ships IP.issue there), so this survives base-files updates -- appending to
	# /etc/issue would not.
	printf 'image: %s (%s)\n' "$img" "${src:0:12}" >"$ROOTFS/etc/issue.d/20-fleet-image.issue"

	# One line per boot, so a log or capture can be tied to the image that
	# produced it. In /etc/systemd/system, not /usr/lib, so it lives in @ and does
	# not need @usr writable.
	#
	# EnvironmentFile, not `sh -c '. /etc/fleet-image; echo ...'`: systemd expands
	# $VAR in ExecStart itself, before any shell would see it.
	cat >"$ROOTFS/etc/systemd/system/fleet-image-id.service" <<-'EOF'
		[Unit]
		Description=Log the image this system was flashed from

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		EnvironmentFile=/etc/fleet-image
		ExecStart=/bin/echo "fleet-image: ${IMAGE} role=${ROLE} source=${SOURCE} base=${BASE}"

		[Install]
		WantedBy=multi-user.target
	EOF
	ln -sf ../fleet-image-id.service \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/fleet-image-id.service"

	ls -l "$ROOTFS/etc/issue.d/20-fleet-image.issue" \
		"$ROOTFS/etc/systemd/system/fleet-image-id.service" \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/fleet-image-id.service"
}

# =============================================================================
# 2e. passwordless sudo for the uid-1000 account
#     The base image carries no sudoers drop-in for `pi`. Convergence drives
#     ansible over SSH with `become: true` and no become password, so without
#     this every play stops at a sudo prompt on a connection with no tty -- a
#     hang, not an auth error. In the image rather than in provisioning, so it
#     holds however a card was personalised.
#
#     The filename is the vendor's because userconf-pi's `userconf` rewrites
#     exactly this path when it renames the account.
#
#     Inert as built: `pi` is `!`-locked with /usr/sbin/nologin until
#     provisioning enables the account.
# =============================================================================
install_sudoers() {
	echo "== install /etc/sudoers.d/010_pi-nopasswd =="
	# A real file, not a symlink: sudo validates the ownership of a symlink's
	# TARGET and refuses the rule if it does not like what it finds.
	local sd="$ROOTFS/etc/sudoers.d/010_pi-nopasswd"
	mkdir -p "$ROOTFS/etc/sudoers.d"
	cat >"$sd" <<-'EOF'
		pi ALL=(ALL) NOPASSWD: ALL
	EOF
	chown root:root "$sd"
	chmod 0440 "$sd"

	# Validate with the TARGET's sudo. A sudoers file that does not parse disables
	# sudo entirely, and the first thing to notice is a device in the field that
	# cannot get root.
	chroot "$ROOTFS" /usr/sbin/visudo -cf /etc/sudoers.d/010_pi-nopasswd
	ls -l "$sd"
}

# =============================================================================
# 3. regenerate the initramfs WITH btrfs, natively, via chroot
#    THE CRUX. The stock kernel has btrfs as a *module*, so a btrfs root needs an
#    initramfs that carries and modprobes btrfs before it can mount /. The vendor
#    ships an initramfs, but not one with btrfs in it: add btrfs to the module
#    list, install btrfs-progs (which ships the initramfs btrfs hook), rebuild.
#    auto_initramfs=1 in the vendor config.txt is what makes the bootloader load
#    the resulting initramfs8 / initramfs_2712.
# =============================================================================
regenerate_initramfs() {
	echo "== chroot: add btrfs to initramfs and rebuild =="

	# Bind the staged boot dir where the kernel/auto_initramfs hooks expect it,
	# so the generated initramfs lands in $BOOTSTAGE (our future p1).
	mount --bind "$BOOTSTAGE" "$ROOTFS/boot/firmware"
	track_mount "$ROOTFS/boot/firmware"
	for m in proc sys dev dev/pts; do
		mount --bind "/$m" "$ROOTFS/$m"
		track_mount "$ROOTFS/$m"
	done
	# Give apt working DNS inside the chroot.
	cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf" || true

	# initramfs module list: one module per line (initramfs-tools resolves deps).
	echo "btrfs" >>"$ROOTFS/etc/initramfs-tools/modules"

	# mkinitramfs's default MODULES=dep introspects the RUNNING root device to pick
	# modules, which fails in a chroot ("failed to determine device for /") and
	# aborts the btrfs-progs install trigger. MODULES=most bundles a broad set
	# instead. Must be set BEFORE the apt install, which fires update-initramfs via
	# that trigger.
	echo "MODULES=most" >"$ROOTFS/etc/initramfs-tools/conf.d/coordinator-modules"

	# auto_initramfs=1 is already in the vendor config.txt, and update-initramfs's
	# hook reads it to decide whether to emit the firmware-named initramfs at all.
	# Assert rather than append: if a future base drops it, the board boots with no
	# initramfs, no btrfs module, and no root -- and nothing else here would notice.
	grep -q '^auto_initramfs=1' "$BOOTSTAGE/config.txt" || {
		echo "!! base config.txt has no auto_initramfs=1 -- initramfs would not be loaded" >&2
		exit 1
	}

	# btrfs-progs provides `btrfs` and the initramfs hook that pulls the module in.
	# Not in RPi OS Lite, so this needs network.
	#
	# update-initramfs -u, NOT -c: the base image already has a
	# /boot/initrd.img-<kver> for both kernels, and -c declines to overwrite an
	# existing one -- which would ship the vendor's btrfs-less initramfs, and a
	# card that cannot find its root, with the build reporting success.
	chroot "$ROOTFS" /bin/bash -eu -c '
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq btrfs-progs
		update-initramfs -u -k all
	'

	# An initramfs FILE in bootfs proves nothing -- the base ships two. Check for
	# the module itself.
	echo "== initramfs artifacts now in bootfs: =="
	shopt -s nullglob
	local initrds=("$BOOTSTAGE"/initramfs*)
	shopt -u nullglob
	[ "${#initrds[@]}" -gt 0 ] || {
		echo "!! no initramfs* in bootfs -- boot WILL fail" >&2
		exit 1
	}
	ls -l "${initrds[@]}"

	# lsinitramfs from inside the chroot: the target's own initramfs-tools, and
	# whatever compression it used on the module (.ko.xz today).
	local ird
	for ird in "${initrds[@]}"; do
		if chroot "$ROOTFS" lsinitramfs "/boot/firmware/${ird##*/}" | grep -q '/btrfs\.ko'; then
			echo "   ${ird##*/}: carries btrfs"
		else
			echo "!! ${ird##*/} has NO btrfs module -- boot WILL fail" >&2
			exit 1
		fi
	done

	# tear the chroot binds down now (deepest-first) before we touch the rootfs.
	for m in dev/pts dev sys proc boot/firmware; do
		umount "$ROOTFS/$m" 2>/dev/null || true
		MOUNTS=("${MOUNTS[@]/$ROOTFS\/$m/}")
	done
}

# =============================================================================
# 4. build the target image: partition, FAT boot, btrfs via assemble-btrfs.sh
# =============================================================================
build_target() {
	# Size = boot + rootfs footprint + slack, rounded up to a whole MiB.
	local used_mb total_mb
	used_mb="$(du -sm --apparent-size "$ROOTFS" | cut -f1)"
	total_mb=$((BOOT_MB + used_mb + SLACK_MB))
	echo "== target image: ${total_mb} MiB (boot ${BOOT_MB} + rootfs ${used_mb} + slack ${SLACK_MB}) =="
	rm -f "$OUT_IMG"
	truncate -s "${total_mb}M" "$OUT_IMG"

	# MBR: p1 FAT32 (primary, lba) then p2 filling the rest. A fixed MBR disk id
	# makes the PARTUUIDs deterministic across rebuilds (root=PARTUUID in cmdline).
	echo "== partitioning (MBR) =="
	parted -s "$OUT_IMG" \
		mklabel msdos \
		mkpart primary fat32 4MiB "$((4 + BOOT_MB))MiB" \
		mkpart primary "$((4 + BOOT_MB))MiB" 100% \
		set 1 lba on
	# Stamp a stable disk identifier (-> PARTUUID prefix). 'c0dec0de' is a marker.
	sfdisk --disk-id "$OUT_IMG" 0xc0dec0de

	echo "== loop-attaching target =="
	DST_LOOP="$(losetup --find --show -P "$OUT_IMG")"
	local p1="${DST_LOOP}p1" p2="${DST_LOOP}p2"
	echo "   $DST_LOOP (p1=$p1 boot, p2=$p2 root)"
	wait_for_partitions "$DST_LOOP" 2

	# p1: FAT32 labelled 'bootfs' (kept for humans). The real image's fstab mounts
	# /boot/firmware by PARTUUID, not this label, so a stray 'bootfs' card can't mount here.
	echo "== mkfs.vfat -F32 -n bootfs $p1 =="
	mkfs.vfat -F 32 -n bootfs "$p1" >/dev/null

	# Resolve the PARTUUIDs we now need for the cmdline fixup.
	local boot_partuuid root_partuuid
	boot_partuuid="$(blkid -s PARTUUID -o value "$p1")"
	root_partuuid="$(blkid -s PARTUUID -o value "$p2")"
	echo "   boot PARTUUID=$boot_partuuid  root PARTUUID=$root_partuuid"

	# Fix up the staged boot config BEFORE we copy it onto p1.
	fixup_bootconfig "$root_partuuid"

	# Copy the (fixed-up) boot partition contents onto the new FAT p1.
	echo "== copy bootfs -> $p1 =="
	local nboot="$BUILD/n-boot"
	mkdir -p "$nboot"
	mount "$p1" "$nboot"
	track_mount "$nboot"
	rsync -aHX "$BOOTSTAGE"/ "$nboot"/
	umount "$nboot" && MOUNTS=("${MOUNTS[@]/$nboot/}")

	# p2: hand off to assemble-btrfs.sh -- mkfs.btrfs, create the seven subvols,
	# populate from $ROOTFS, write @/etc/fstab, drop cmdline.fragment and
	# fstab.generated into $BUILD for reference.
	#
	# /boot/firmware is keyed off THIS disk's PARTUUID, so a stray stock
	# 'bootfs'-labelled card can never be mounted there.
	export BOOT_PARTUUID="$boot_partuuid"
	echo "== assemble-btrfs.sh $ROOTFS $p2 =="
	"$HERE/assemble-btrfs.sh" "$ROOTFS" "$p2" "$BUILD"

	losetup -d "$DST_LOOP"
	DST_LOOP=""
}

# =============================================================================
# 5. cmdline.txt / config.txt fixups
#    cmdline: point root= at the new btrfs partition by PARTUUID and add the
#    btrfs root flags; drop the ext4/fsck/resize bits that don't apply.
#    config: auto_initramfs already handled in step 3.
# =============================================================================
fixup_bootconfig() {
	local root_partuuid="$1"
	local cmd="$BOOTSTAGE/cmdline.txt"
	[ -f "$cmd" ] || {
		echo "no $cmd" >&2
		exit 1
	}

	echo "== cmdline.txt BEFORE:"
	cat "$cmd"

	# cmdline.txt is a single space-separated line. Rewrite it token-by-token so
	# we are robust to whatever exact set the vendor shipped:
	#   - replace root=...            -> root=PARTUUID=<new p2>
	#   - drop rootfstype=ext4        (we append rootfstype=btrfs)
	#   - drop fsck.repair=...        (btrfs is not fsck'd at boot)
	#   - drop the bare `resize` token: it arms two raspberrypi-sys-mods initramfs
	#     scripts, which ship inside our image because we regenerate the initramfs
	#     with that package installed --
	#       local-premount/resize_early  parted resizepart 2 to fill the disk
	#       local-bottom/set_partuuid    new MBR disk id from /dev/hwrng, sed'd
	#                                    through /etc/fstab and cmdline.txt
	#     grow-rootfs already grows the card, so this is a second mechanism racing
	#     it. Dropping it also keeps PARTUUIDs identical across cards built from
	#     one image, which is what makes a staged re-flash addressable
	#     (coordinator#310).
	#   - drop anything matching the role's CMDLINE_REMOVE globs
	# then append the btrfs root flags, then the role's CMDLINE_APPEND tokens.
	local out=() tok pat drop
	# shellcheck disable=SC2013  # single-line file; word-splitting is intended
	for tok in $(cat "$cmd"); do
		# Role-supplied removals first, so a role can drop a token the generic
		# rules would keep -- e.g. moving the serial console to the end of the
		# line, or taking it off a UART the flight controller needs.
		drop=0
		for pat in $CMDLINE_REMOVE; do
			# shellcheck disable=SC2254  # $pat is intentionally a glob
			case "$tok" in
			$pat)
				drop=1
				break
				;;
			esac
		done
		if [ "$drop" -eq 1 ]; then
			echo "   (role CMDLINE_REMOVE dropped: $tok)"
			continue
		fi
		case "$tok" in
		root=*) out+=("root=PARTUUID=$root_partuuid") ;;
		rootfstype=*) : ;; # replaced below
		fsck.repair=*) : ;;
		resize) : ;; # see note above
		*) out+=("$tok") ;;
		esac
	done
	out+=("rootfstype=btrfs" "rootflags=subvol=@")
	# Role additions go last. Anything provisioning appends at flash time lands
	# after these, which does not disturb the relative order of console= tokens.
	for tok in $CMDLINE_APPEND; do out+=("$tok"); done
	printf '%s ' "${out[@]}" | sed 's/ $//' >"$cmd"
	printf '\n' >>"$cmd"

	echo "== cmdline.txt AFTER:"
	cat "$cmd"
	echo "== config.txt btrfs-relevant lines:"
	grep -nE 'auto_initramfs|initramfs' "$BOOTSTAGE/config.txt" || true
}

# =============================================================================
# 6. report
# =============================================================================
report() {
	echo
	echo "======================================================================"
	echo "built: $OUT_IMG"
	ls -lh "$OUT_IMG"
	echo "---- sfdisk -d ----"
	sfdisk -d "$OUT_IMG"
	echo "---- generated fstab (from assemble) ----"
	cat "$BUILD/fstab.generated" 2>/dev/null || true
	echo "======================================================================"
}

main() {
	require_root
	require_tools
	fetch_source
	extract_source
	apply_role_bootfs
	install_grow_rootfs
	write_manifest
	install_sudoers
	regenerate_initramfs
	build_target
	report
}

main "$@"
