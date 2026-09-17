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
	# CONFIG_REMOVE: comment out vendor config.txt directives this role does not
	# want. Appending cannot undo them -- there is no "dtoverlay=none", and a second
	# dtoverlay line loads a second overlay rather than replacing the first. Only
	# dtparam has last-wins semantics, and not reliably across sections.
	#
	# Commented rather than deleted so the card still shows what the vendor shipped
	# and that its absence was a decision.
	if [ -n "${CONFIG_REMOVE:-}" ]; then
		echo "== disable role-removed config.txt directives ($ROLE) =="
		local cfg="$BOOTSTAGE/config.txt" tmp="$BUILD/config.txt.filtered"
		local line pat hit matched=""
		: >"$tmp"
		while IFS= read -r line || [ -n "$line" ]; do
			hit=0
			case "$line" in
			\#* | '') ;;
			*)
				for pat in $CONFIG_REMOVE; do
					# shellcheck disable=SC2254  # glob match is the point
					case "$line" in
					$pat)
						hit=1
						matched="$matched $pat"
						break
						;;
					esac
				done
				;;
			esac
			if [ "$hit" -eq 1 ]; then
				printf '# disabled by build-image.sh (%s): %s\n' "$ROLE" "$line" >>"$tmp"
				echo "   disabled: $line"
			else
				printf '%s\n' "$line" >>"$tmp"
			fi
		done <"$cfg"
		mv "$tmp" "$cfg"

		# A pattern that matched nothing is a typo or a vendor change, and would
		# otherwise be invisible -- the directive stays enabled and the build says
		# nothing. Warn rather than fail: a role may legitimately list a directive
		# that only some base images carry.
		for pat in $CONFIG_REMOVE; do
			case "$matched" in
			*"$pat"*) ;;
			*) echo "   !! CONFIG_REMOVE pattern matched nothing: $pat" ;;
			esac
		done
	fi

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
#     stays unpartitioned until something grows it. See grow-rootfs.sh for why
#     neither vendor mechanism survives into this image.
# =============================================================================
install_grow_rootfs() {
	echo "== install /usr/local/sbin/grow-rootfs + unit =="
	install -D -m 0755 "$HERE/grow-rootfs.sh" "$ROOTFS/usr/local/sbin/grow-rootfs"

	# Unit in /etc/systemd/system, not /usr/lib, so it lives in @ and does not
	# depend on @usr being writable. Ordered before multi-user.target: the
	# provisioning boot never reaches that target, so this first runs on the boot
	# after firstrun.sh -- before anything that writes at volume.
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
# 2d. /boot/firstrun.sh -> firmware/firstrun.sh
#     THE FIRST-BOOT FIX. rpi-imager appends
#       systemd.run=/boot/firstrun.sh
#     to cmdline.txt at flash time and writes the script to the FAT partition,
#     which Bookworm mounts at /boot/FIRMWARE. The vendor squares that circle with
#     an initramfs script (raspberrypi-sys-mods' imager_fixup) that rewrites
#     cmdline.txt to /boot/firmware/firstrun.sh -- but that rewrite lands on the
#     CARD, for the NEXT boot. The kernel has already read this boot's cmdline.
#
#     On a stock card that is fine, because boot 1 is consumed by
#     init=/usr/lib/raspberrypi-sys-mods/firstboot: systemd is not PID 1, so
#     systemd.run is inert, and firstboot reboots into the corrected cmdline.
#
#     We strip that init= (it randomises the MBR disk identifier, which would
#     break this image's pinned root=PARTUUID), so boot 1 IS the systemd boot and
#     it execs a path that does not exist. The unit fails to
#     START, and systemd-run-generator's default FailureAction=exit powers the
#     board off -- which presents as a dead unit, not an error. Boot 2 then works,
#     because imager_fixup fixed the cmdline during boot 1.
#
#     A relative symlink makes boot 1 resolve. It costs nothing when no firstrun.sh
#     is present (a dangling symlink nothing reads) and nothing after provisioning,
#     when firstrun.sh deletes itself.
# =============================================================================
link_firstrun_compat() {
	echo "== symlink /boot/firstrun.sh -> firmware/firstrun.sh (boot-1 exec path) =="
	ln -sfn firmware/firstrun.sh "$ROOTFS/boot/firstrun.sh"
	ls -l "$ROOTFS/boot/firstrun.sh"
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
	img="$(basename "$OUT_IMG")"    # the artifact name, as published (raw .img since #47)
	base="$(basename "$RPIOS_URL")" # carries the suite -- bookworm vs trixie
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

	ls -l "$ROOTFS/etc/issue.d/20-fleet-image.issue" \
		"$ROOTFS/etc/systemd/system/fleet-image-id.service" \
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
	#
	# resize2fs_once is masked in the same pass. It is an RPi OS LSB service that
	# grows the root filesystem on first boot: it resolves the root device via
	# findmnt, which on btrfs yields subvolume notation (/dev/mmcblk0p2[/@]), and
	# hands that to resize2fs -- an ext2/3/4 tool that could not grow btrfs even if
	# the path parsed. It cannot succeed on this image, so it leaves a permanently
	# failed unit on every card, and a `systemctl --failed` that is never clean is
	# one nobody reads.
	#
	# dphys-swapfile is masked for a different reason: it works, and we do not want
	# what it does. RPi OS ships it enabled with CONF_SWAPSIZE=512, so every card
	# gets a half-gigabyte swapfile at /var/swap -- which on this layout lands on the
	# @var btrfs subvolume, i.e. on the SD card, i.e. on the one medium this whole
	# design exists to write to as little as possible.
	#
	# Measured on campod-se before this change: 512 MiB of swap configured and
	# ~117 MiB of it in use, with dockerd (29 MiB), containerd (16 MiB) and the
	# capture process (33 MiB) paged out onto the card. That is sustained SD write
	# and read traffic in the iowait path of a device whose job is to capture data
	# at 1 Hz, on a vehicle that loses power without warning.
	#
	# An appliance that cannot fit in its RAM should fail visibly, not silently
	# trade latency and flash wear for the appearance of working. If demand really
	# exceeds 512 MB, that is a decision to take deliberately -- shrink the demand,
	# or change the hardware -- not one to have made for us by a vendor default.
	chroot "$ROOTFS" /bin/bash -eu -c '
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq btrfs-progs

		# PURGE, not disable. A masked unit still has its binary and libraries on
		# disk, and a failed start still maps them, faults them in, and leaves those
		# pages on the LRU competing with everything else. On a 417 MiB box whose
		# measured failure mode is page-cache thrash -- workingset_refault_file at
		# ~6000 pages/s during the camera import -- pages that are never loaded are
		# worth more than seconds of boot time. Gone also cannot have side effects
		# and takes its dependency surface with it.
		#
		# Everything here was checked as present in the pinned base image and as
		# having no consumer on this fleet:
		#   modemmanager      no cellular modem, and it PROBES tty devices on
		#                     appearance -- a hazard on a campod whose UART is the
		#                     debug console and worse on a coordinator whose UART is
		#                     the FC link
		#   avahi-daemon      mDNS; the fleet resolves through real DNS
		#   libnss-mdns       the nsswitch half of the same thing
		#   triggerhappy      hotkey daemon for physical keyboards
		#   bluez pi-bluetooth bluez-firmware
		#                     dtoverlay=disable-bt means the bluetooth/btbcm/hci_uart
		#                     modules are not even loaded (verified via lsmod)
		#   alsa-utils        no audio is used
		#   udisks2           removable-media automounting
		#   pigpio pigpiod    the accel reader talks to spidev directly
		#   nfs-common rpcbind  nothing mounts NFS
		#   console-setup keyboard-configuration  headless
		#   cron              its timers are masked (coordinator#282); the daemon is
		#                     a separate thing and has no jobs here
		#   man-db            man pages on an appliance
		#
		# NOT purged, deliberately:
		#   e2fsprogs   Debian Priority: required. The e2scrub units are masked
		#               elsewhere instead.
		#   apparmor    Docker ships AppArmor profiles and confines containers with
		#               them. Removing it changes confinement, which is not a
		#               startup-footprint question.
		#   polkitd     NetworkManager depends on it.
		#   dphys-swapfile  masked, not purged, on purpose: the unit is what makes
		#               swap the silent default, but the BINARY is a deliberate hatch
		#               (dphys-swapfile setup/swapon) for the case where an in-place
		#               apt genuinely needs headroom.
		#   rpi-eeprom  role-specific. The Zero 2 W has no EEPROM, but the
		#               coordinator (Pi 4B) and pocketterm (Pi 5) do, and this is how
		#               their bootloaders get updated. Fleet-wide purge would remove
		#               that.
		#
		# Not -qq: the log should show what actually came out, not that we tried.
		apt-get purge -y \
			modemmanager \
			avahi-daemon libnss-mdns \
			triggerhappy \
			bluez pi-bluetooth bluez-firmware \
			alsa-utils \
			udisks2 \
			pigpio pigpiod \
			nfs-common rpcbind \
			console-setup console-setup-linux keyboard-configuration \
			cron \
			man-db
		apt-get autoremove --purge -y

		systemctl mask resize2fs_once.service
		systemctl mask dphys-swapfile.service
		update-initramfs -c -k all
	'

	# The swapfile itself, if the vendor rootfs carried one. Masking the service
	# stops it being recreated or activated; this reclaims the space it already
	# occupies. /var/swap on campod-se is dated 2025-05-12 -- the day before the
	# pinned base image was released -- so it predates our build rather than being
	# created on first boot.
	if [ -e "$ROOTFS/var/swap" ]; then
		echo "== removing inherited swapfile: $(du -h "$ROOTFS/var/swap" | cut -f1) =="
		rm -f "$ROOTFS/var/swap"
	else
		echo "== no /var/swap in the rootfs (nothing to remove) =="
	fi

	# Prove it rather than announce it: both units masked means a symlink to
	# /dev/null, and no swap entry anywhere in fstab.
	echo "== swap/resize units after masking: =="
	ls -l "$ROOTFS/etc/systemd/system/resize2fs_once.service" \
		"$ROOTFS/etc/systemd/system/dphys-swapfile.service"
	echo "== fstab swap entries (expect none): =="
	grep -c swap "$ROOTFS/etc/fstab" || true

	# Prove the purge rather than trust it: these are the things whose absence is
	# the point. A leftover here means apt kept something we assumed was gone.
	echo "== purge check: binaries and units that should NOT exist =="
	local leftover=0 f
	for f in usr/sbin/ModemManager usr/sbin/avahi-daemon usr/sbin/thd \
		usr/bin/bluetoothctl usr/bin/pigpiod usr/sbin/rpcbind usr/bin/man \
		usr/sbin/cron usr/lib/systemd/system/udisks2.service; do
		if [ -e "$ROOTFS/$f" ]; then
			echo "   STILL PRESENT: /$f"
			leftover=1
		fi
	done
	[ "$leftover" -eq 0 ] && echo "   none present -- purge clean"
	echo "== packages remaining: $(chroot "$ROOTFS" dpkg-query -f '.\n' -W 2>/dev/null | wc -l) =="

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
	#   - drop init=/usr/lib/... entries. Two live in the vendor cmdline and both
	#     must go, for DIFFERENT reasons:
	#       raspberrypi-sys-mods/firstboot -- does NOT resize (verified against
	#         20250930~bookworm: it regenerates SSH host keys, applies custom.toml,
	#         and RANDOMISES the MBR disk identifier). That last part is why it
	#         cannot run here: this image pins root=PARTUUID=c0dec0de-02.
	#       raspi-config/init_resize.sh -- grows the partition, then hands off to
	#         resize2fs. Replaced by grow-rootfs, which does it online for btrfs.
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
		init=/usr/lib/raspberrypi-sys-mods/*) : ;; # see note above
		init=/usr/lib/raspi-config/*) : ;;         # ditto
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
	link_firstrun_compat
	install_grow_rootfs
	write_manifest
	regenerate_initramfs
	build_target
	report
}

main "$@"
