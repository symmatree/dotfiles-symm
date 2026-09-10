#!/usr/bin/env bash
#
# build-image.sh -- convert the official Raspberry Pi OS Lite (Bookworm, arm64)
# image into the coordinator btrfs-subvolume layout and emit a flashable .img.
#
# This is the "convert" pipeline (as opposed to the mmdebstrap "build from
# scratch" path sketched in README.md): rather than debootstrap a rootfs, we
# take the vendor image as-is (kernel, firmware, raspberrypi-sys-mods, all the
# HAT/overlay glue already correct) and only re-lay its rootfs into our
# @ @usr @var @home @data @snapshots subvolumes via assemble-btrfs.sh, then fix
# up the boot config so the Pi mounts a btrfs-subvol root.
#
# WHERE THIS RUNS: an arm64 host with a btrfs-capable kernel (CI:
# ubuntu-24.04-arm). It CANNOT run on the x86 Talos notebook (no btrfs, no arm).
# Because the runner is arm64 and the RPi userland is arm64, we can chroot the
# extracted rootfs NATIVELY (no qemu-user) to regenerate the initramfs -- that
# is what lets us add the btrfs module to the initramfs offline (see step 5).
#
# Root/loop/mount/mkfs are all required, so run as root (CI: sudo).
#
# Usage:
#   sudo ./build-image.sh [ROLE] [OUT_IMG]
#     ROLE     device role -> pi-image/roles/<ROLE>.env  (default: coordinator)
#     OUT_IMG  final image path (default: pi-image/.build/<ROLE>-pi-<date>.img)
#
# shellcheck disable=SC2015  # a few benign `cond && act || true` cleanup idioms
set -euo pipefail

# ---- pinned upstream image ---------------------------------------------------
# Latest Raspberry Pi OS Lite arm64 *Bookworm* release. (2025-10 onward the
# vendor moved raspios to Trixie; 2025-05-13 is the last Bookworm Lite.) Pinned
# by URL + sha256 so a rebuild is reproducible and a swapped-out upstream is
# caught. To bump: change all three of URL/date/sha together.
#
# ---- BUMPING THE SUITE IS A CROSS-REPO CHANGE, NOT A LOCAL ONE ----------------
# This pin is the fleet's OS suite, and the coordinator repo's containers track
# it. coordinator#214 bumped the camera container (then containers/pod-camera,
# renamed to containers/campod-camera in coordinator#228) to trixie on the
# reasoning that "the host Pi OS is trixie" -- true of what the vendor currently
# ships, false of what this file pins -- creating a host/container suite
# mismatch; reverted in coordinator#219. If this pin moves,
# containers/campod-camera's RPI_SUITE has to move in the same window.
#
# Two things recorded from that revert for whoever eventually moves to Trixie.
# Both are coordinator#219's findings; they are NOT at the same evidence grade,
# so treat them differently:
#
#   - REPRODUCED. Trixie's apt verifies signatures with Sequoia (sqv), whose
#     policy has rejected SHA-1 since 2026-02-01. The raw
#     archive.raspberrypi.com/debian/raspberrypi.gpg.key carries digest algo 2
#     (SHA-1) self-signatures, so the Pi archive reads as UNSIGNED. Confirmed by
#     reproducing the build failure on an arm64 CI runner --
#       "Signing key on CF8A1AF5... is not bound ... SHA1 is not considered
#        secure since 2026-02-01"
#     -- and then by diffing the key packets: raspberrypi-archive-keyring
#     2025.1+rpt1 ships the same fingerprint with digest algo 10 (SHA-512).
#     The dangerous part is the presentation: an unsigned-repo failure here
#     surfaces looking like a network fault, not a trust failure.
#
#   - READ, NOT RUN. Bookworm is not holding anything back: its Pi archive has
#     libcamera 0.5.2 per the archive's Packages index, and the
#     ExposureTimeMode/AnalogueGainMode split landed in 0.4. Nobody has executed
#     that combination to confirm it.
# ------------------------------------------------------------------------------
RPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz"
RPIOS_SHA256="62d025b9bc7ca0e1facfec74ae56ac13978b6745c58177f081d39fbb8041ed45"

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
# roles/<role>.env is SOURCED by bash, so any value containing a space must be
# quoted -- `VAR=a b` assigns "a" and then tries to run `b` as a command, which
# under set -e kills the build during sourcing, before any of this runs.
# Order matters for console=: the kernel sends printk to every console= device,
# but userspace /dev/console is the LAST one -- which is where systemd writes its
# status output. So whichever console is listed last is the one that shows you a
# failing boot.
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
		mkfs.vfat mkfs.btrfs blkid sfdisk chroot unzip; do
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
# 2c. write the image manifest into the rootfs
#     A card cannot otherwise say which image it came from: the build stamps a
#     date into the FILENAME and nothing into the rootfs. That makes the image
#     the one layer a running unit can't report -- apt, git and docker can each
#     compute their own staleness, the image can't (coordinator#96).
#
#     Three touchpoints, all deliberately tiny:
#       /etc/fleet-image                  the canonical key=value record
#       /etc/issue.d/20-fleet-image.issue shown pre-login on console AND serial
#       fleet-image-id.service            one line into the journal each boot,
#                                         so logs can be tied to what produced them
#
#     Nothing here may change after first boot, and no field is derivable from
#     another -- a build date was dropped because IMAGE already carries it and two
#     fields that can disagree are worse than one. A manifest that can drift from
#     reality is worse than none, because it will be believed.
# =============================================================================
write_manifest() {
	local img base src
	img="$(basename "${OUT_IMG%.img}").img.xz" # the artifact name, as published
	base="$(basename "$RPIOS_URL")"            # carries the suite -- bookworm vs trixie
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

	# One line per boot into the journal, so any log or capture collected from
	# this unit can be tied back to the image that produced it. Lives in
	# /etc/systemd/system, not /usr/lib, so it stays inside the @ subvolume and
	# does not depend on @usr being writable.
	#
	# EnvironmentFile rather than `sh -c '. /etc/fleet-image; echo ...'`: systemd
	# expands $VAR in ExecStart ITSELF, before any shell sees it, so the inline
	# form would have logged a line of empty values. Letting systemd read the
	# manifest as an environment file makes the expansion correct and drops the
	# shell entirely.
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
}

# =============================================================================
# 3. regenerate the initramfs WITH btrfs, natively, via chroot
#    THE CRUX. RPi OS boots with NO initramfs by default and the stock kernel
#    has btrfs as a *module*, so a btrfs root needs an initramfs that carries
#    (and modprobes) btrfs before it can mount /. We add btrfs to the initramfs
#    module list, install btrfs-progs (ships the initramfs btrfs hook), and run
#    update-initramfs. auto_initramfs=1 (set in step 6) makes the bootloader
#    load the resulting initramfs8 / initramfs_2712 automatically.
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

	# mkinitramfs's default MODULES=dep introspects the *running* root device to
	# choose modules -- which fails inside a chroot ("failed to determine device
	# for /"), aborting the btrfs-progs install trigger. MODULES=most bypasses that
	# by bundling a broad module set (which covers btrfs); the right choice for
	# an offline/chroot image build. Must be set BEFORE the apt install below, since
	# installing btrfs-progs fires update-initramfs via its dpkg trigger.
	echo "MODULES=most" >"$ROOTFS/etc/initramfs-tools/conf.d/coordinator-modules"

	# auto_initramfs must already be on for update-initramfs's hook to emit the
	# firmware-named initramfs; step 6 writes it, but set it now so the hook that
	# runs inside this chroot sees it too.
	if ! grep -q '^auto_initramfs=1' "$BOOTSTAGE/config.txt"; then
		printf '\n# btrfs root needs an initramfs to modprobe btrfs before mount\nauto_initramfs=1\n' \
			>>"$BOOTSTAGE/config.txt"
	fi

	# btrfs-progs provides `btrfs` + the initramfs hook that pulls the module in.
	# RPi OS Lite does not ship it by default, so install it (needs network).
	chroot "$ROOTFS" /bin/bash -eu -c '
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq btrfs-progs
		update-initramfs -c -k all
	'

	# Confirm an initramfs was actually produced (glob, not ls|grep).
	echo "== initramfs artifacts now in bootfs: =="
	shopt -s nullglob
	local initrds=("$BOOTSTAGE"/initramfs*)
	shopt -u nullglob
	[ "${#initrds[@]}" -gt 0 ] || {
		echo "!! no initramfs* produced -- boot WILL fail; see writeup" >&2
		exit 1
	}
	ls -l "${initrds[@]}"

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

	# p2: hand off to the already-verified subvolume assembly. It mkfs.btrfs's
	# the device, creates the seven subvols, populates them from $ROOTFS, writes
	# @/etc/fstab (/boot/firmware keyed by PARTUUID) and drops cmdline.fragment +
	# fstab.generated into $BUILD for reference.
	# assemble keys /boot/firmware off this PARTUUID (unique to this disk) so a
	# stray stock 'bootfs'-labelled card can never be mounted there.
	export BOOT_PARTUUID="$boot_partuuid"
	echo "== assemble-btrfs.sh $ROOTFS $p2 =="
	"$HERE/assemble-btrfs.sh" "$ROOTFS" "$p2" "$BUILD"

	losetup -d "$DST_LOOP"
	DST_LOOP=""
}

# =============================================================================
# 5. cmdline.txt / config.txt fixups
#    cmdline: point root= at the new btrfs partition by PARTUUID and add the
#    btrfs root flags; drop the ext4/fsck/firstboot bits that don't apply.
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
	#   - drop init=...sys-mods...    (firstboot/resize expects ext4 -> would fail)
	#   - drop init_resize / resize2fs bits for the same reason
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
		init=/usr/lib/raspberrypi-sys-mods/*) : ;;
		init_resize*) : ;;
		*) out+=("$tok") ;;
		esac
	done
	out+=("rootfstype=btrfs" "rootflags=subvol=@")
	# Role additions go last. rpi-imager later appends its own systemd.run=
	# tokens after these when a card is provisioned, which does not disturb the
	# relative order of any console= arguments.
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
	write_manifest
	regenerate_initramfs
	build_target
	report
}

main "$@"
