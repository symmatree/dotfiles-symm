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
#
# BOOT_MB is sized to stage a compressed image for a touchless re-flash
# (coordinator#312), not for boot content -- boot content is 75.6 MiB across 435
# files, measured on a built campod artifact. The rest is staging: the flasher
# streams `unzip | dd` out of p1 onto p2, so p1 only has to hold the zip, and one
# at a time. 1536 - 76 leaves ~1460 MiB against an 809 MiB artifact.
#
# THIS SIZE CANNOT BE CHANGED IN PLACE. p2 begins right after p1, so growing p1
# means rewriting the whole card. Every device pays one full reflash to adopt it,
# which is why it rides the same flash as a suite change rather than arriving on
# its own.
BOOT_MB=1536  # FAT32 /boot/firmware + staging for coordinator#312
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
		mkfs.vfat mkfs.btrfs blkid sfdisk chroot unzip chattr lsattr cpio; do
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
	# CONFIG_REMOVE: role-declared globs whose matching config.txt directives get
	# commented out. Runs before CONFIG_APPEND so it only ever sees vendor lines.
	# The matcher is config-remove.sh, covered by test-config-remove.sh.
	#
	# A pattern matching nothing exits non-zero, and that is fatal here: it means a
	# directive the role wanted gone is still live, which is silent on the card.
	if [ -n "${CONFIG_REMOVE:-}" ]; then
		echo "== disable role-removed config.txt directives ($ROLE) =="
		# shellcheck disable=SC2086  # word-splitting the pattern list is intended
		CONFIG_REMOVE_LABEL="build-image.sh ($ROLE)" \
			"$HERE/config-remove.sh" "$BOOTSTAGE/config.txt" $CONFIG_REMOVE
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
#     A card otherwise cannot say what it is (coordinator#96), and the ground
#     platform reads this to show what each machine is running (coordinator#326).
#
#       /etc/fleet-image                   the manifest
#       /etc/issue.d/20-fleet-image.issue  shown pre-login on console and serial
#       fleet-image-id.service             one line per boot into the journal
#
#     FORMAT. A flat table of double-quoted strings, which is simultaneously
#     valid TOML, a sourceable shell file, and a systemd EnvironmentFile -- so
#     Python, Go and JS get a real parser instead of hand-rolled splitting, and
#     EnvironmentFile= keeps working. Two rules make that true:
#
#       no whitespace around =   TOML permits K = "v" and so does every non-shell
#                                parser, but `source` reads it as a command and
#                                fails with `K: command not found`.
#       values always quoted     and containing no $, since sourcing expands it.
#
#     VOCABULARY. The four ORG_OPENCONTAINERS_* keys are the controlled set the
#     UI understands semantically: it links the source, resolves the revision
#     against the ref, and shows the PR a sha came from. They are named for the
#     OCI annotations so a disk image and a container image answer in one
#     vocabulary. Anything else is artifact-specific, needs no agreement, and is
#     displayed verbatim.
#
#     Build date is deliberately NOT identity: two identical artifacts can carry
#     different dates and two different ones can share a date. FLEET_IMAGE holds
#     the artifact name, which happens to contain a date, as a diagnostic.
# =============================================================================
write_manifest() {
	local img base rev source ref
	img="$(basename "$OUT_IMG")"
	base="$(basename "$RPIOS_URL")"
	rev="${GITHUB_SHA:-$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)}"
	# Fully qualified -- refs/heads/main, refs/tags/v1.2.3 -- so nothing downstream has
	# to guess whether a bare name is a branch or a tag, or whether a release tag carries
	# a `v` its version does not. GITHUB_REF is already this; symbolic-ref is the local
	# equivalent and is empty on a detached HEAD, which `unknown` then covers.
	ref="${GITHUB_REF:-$(git -C "$HERE" symbolic-ref -q HEAD 2>/dev/null || echo unknown)}"
	[ -n "$ref" ] || ref=unknown

	# A browsable URL, because the UI links it. Actions gives it directly;
	# otherwise derive it from the remote, which may be SSH form.
	if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
		source="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
	else
		source="$(git -C "$HERE" remote get-url origin 2>/dev/null || echo unknown)"
		source="${source%.git}"
		source="${source/git@github.com:/https://github.com/}"
	fi

	echo "== write /etc/fleet-image =="
	mkdir -p "$ROOTFS/etc/issue.d" "$ROOTFS/etc/systemd/system/multi-user.target.wants"
	cat >"$ROOTFS/etc/fleet-image" <<-EOF
		# Written by dotfiles-symm pi-image/build-image.sh at build time.
		# Immutable: describes the image this card was flashed from, not current state.
		# Valid TOML, sourceable shell, and a systemd EnvironmentFile -- keep it that
		# way: no spaces around =, values always quoted, no \$ in a value.
		ORG_OPENCONTAINERS_IMAGE_SOURCE="$source"
		ORG_OPENCONTAINERS_IMAGE_REVISION="$rev"
		FLEET_SOURCE_REF="$ref"
		FLEET_ROLE="$ROLE"
		FLEET_IMAGE="$img"
		FLEET_BASE="$base"
	EOF
	cat "$ROOTFS/etc/fleet-image"

	# Prove the format rather than trust it: the build host has python3, and a
	# manifest that stops being TOML is silent until something downstream fails.
	python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' \
		"$ROOTFS/etc/fleet-image"
	# shellcheck disable=SC1090,SC1091  # sourcing what we just generated is the test
	(set -a && . "$ROOTFS/etc/fleet-image")
	echo "   parses as TOML and sources as shell"

	# Pre-login banner. issue.d is a drop-in dir (raspberrypi-sys-mods already
	# ships IP.issue there), so this survives base-files updates -- appending to
	# /etc/issue would not.
	printf 'image: %s (%s %s)\n' "$img" "$ref" "${rev:0:12}" \
		>"$ROOTFS/etc/issue.d/20-fleet-image.issue"

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
		ExecStart=/bin/echo "fleet-image: ${FLEET_IMAGE} role=${FLEET_ROLE} ref=${FLEET_SOURCE_REF} revision=${ORG_OPENCONTAINERS_IMAGE_REVISION} base=${FLEET_BASE}"

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
# 2e. passwordless sudo. Convergence drives ansible with `become: true` and no
#     become password, so without this every play hangs at a sudo prompt on a
#     connection with no tty. In the image, so it holds however a card was
#     personalised.
#
#     Keep the vendor's filename: userconf-pi rewrites exactly this path when it
#     renames the account.
# =============================================================================
install_sudoers() {
	echo "== install /etc/sudoers.d/010_pi-nopasswd =="
	local sd="$ROOTFS/etc/sudoers.d/010_pi-nopasswd"
	mkdir -p "$ROOTFS/etc/sudoers.d"
	# A file, not a stow symlink: sudo validates the ownership of the target.
	cat >"$sd" <<-'EOF'
		pi ALL=(ALL) NOPASSWD: ALL
	EOF
	chown root:root "$sd"
	chmod 0440 "$sd"
	chroot "$ROOTFS" /usr/sbin/visudo -cf /etc/sudoers.d/010_pi-nopasswd
}

# =============================================================================
# 2f. flasher boot path
#     Re-image p2 without pulling the card (coordinator#312). You cannot
#     overwrite the filesystem you are running from, so something else has to be
#     running: an initramfs whose /init never pivots to a real root. The whole
#     system lives in RAM and nothing holds p2 open.
#
#     Selected by TRYBOOT. `reboot '0 tryboot'` boots tryboot.txt instead of
#     config.txt EXACTLY ONCE; if the board does not come up, a power cycle falls
#     back to config.txt. The rollback for the boot step is the firmware's.
#
#     IT DOES THE REAL WRITE -- see flasher-init.sh, which is its /init. The
#     guards are on the inputs rather than on the action, and a fresh card with
#     nothing staged is a report-and-reboot no-op.
#
#     The image is streamed `unzip | dd`, so p1 holds the 809 MiB zip and never
#     the 4.8 GB raw form, which is why BOOT_MB is sized the way it is.
# =============================================================================
FLASH_DIR=flash # staged image lives at /boot/firmware/$FLASH_DIR/image.{zip,sha256}

install_flasher_boot() {
	echo "== build flasher initramfs + tryboot.txt =="

	# busybox-static comes out of the chroot apt pass, which has already torn its
	# binds down by now -- so this step is host-side: copy the binary, build the
	# cpio, write the configs.
	local fdir="$BUILD/flasher"
	rm -rf "$fdir"
	mkdir -p "$fdir"/{bin,proc,sys,dev,mnt}
	[ -x "$ROOTFS/usr/bin/busybox" ] || {
		echo "!! busybox-static did not land in the rootfs" >&2
		exit 1
	}
	cp "$ROOTFS/usr/bin/busybox" "$fdir/bin/busybox"

	sed -e "s|@FLASH_DIR@|$FLASH_DIR|g" "$HERE/flasher-init.sh" >"$fdir/init"
	chmod 0755 "$fdir/init"

	(cd "$fdir" && find . | cpio -o -H newc --quiet | gzip -9) >"$BOOTSTAGE/initramfs-flash.gz"

	# No root= at all: with an initramfs present and no root device named, the
	# kernel runs /init from the cpio and never looks for a real root.
	echo "console=serial0,115200 console=tty1 panic=30" >"$BOOTSTAGE/cmdline-flash.txt"

	# tryboot.txt is a full config, not an overlay -- the firmware reads one or the
	# other. Start from the real config so the board comes up the same way (UART,
	# overlays, arm_boost), then point it at the flasher.
	{
		cat "$BOOTSTAGE/config.txt"
		echo ""
		echo "# --- flasher boot, reached only by: reboot '0 tryboot' ---"
		echo "initramfs initramfs-flash.gz followkernel"
		echo "cmdline=cmdline-flash.txt"
		echo "auto_initramfs=0"
	} >"$BOOTSTAGE/tryboot.txt"

	# The staging directory ships empty, so the bench side has somewhere to put
	# the image without having to create it on a read-only-ish boot partition.
	mkdir -p "$BOOTSTAGE/$FLASH_DIR"

	ls -l "$BOOTSTAGE/initramfs-flash.gz" "$BOOTSTAGE/tryboot.txt" "$BOOTSTAGE/cmdline-flash.txt"
	echo "== tryboot.txt tail: =="
	tail -n 5 "$BOOTSTAGE/tryboot.txt"
}

# =============================================================================
# 2g. no swap. An appliance that cannot fit in its RAM should fail visibly, and
#     rpi-swap's default writeback file lands on the SD card. swap.conf(5).
# =============================================================================
install_no_swap() {
	echo "== disable swap (rpi-swap Mechanism=none) =="
	mkdir -p "$ROOTFS/etc/rpi/swap.conf.d"
	cat >"$ROOTFS/etc/rpi/swap.conf.d/10-no-swap.conf" <<-'EOF'
		[Main]
		Mechanism=none
	EOF
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
	# WHAT IS SELECTED HERE, since the list is not an audit of the image's 633
	# packages. The criterion is things that LOAD, in three forms:
	#
	#   a unit that starts at boot
	#   a library mapped into other processes
	#   a kernel module (resident, unswappable, unreclaimable -- the worst of the
	#     three; that is what CONFIG_REMOVE in the role files is for, not this list)
	#
	# because the cost is pages resident or faulted in, not bytes on disk. A package
	# shipping a binary nobody executes is not a candidate; there are hundreds of
	# those and removing them buys nothing.
	#
	# Purge rather than mask, because a masked unit still has its binary and
	# libraries on disk and a failed start still maps them.
	#
	# Read off a booted campod (systemctl list-unit-files --state=enabled, and
	# list-units --state=running), so this is what the image actually starts:
	#
	#   RUNNING at boot, no consumer here:
	#     avahi-daemon  mDNS. The fleet resolves through real DNS
	#                   (local.symmatree.com); mDNS is unreliable across the
	#                   broadcast domains this fleet spans.
	#     cron          no jobs here. Note this does NOT cover the systemd timers --
	#                   those are masked separately below.
	#     udisks2       removable-media automounting.
	#   ENABLED, starts and finds nothing:
	#     bluez         dtoverlay=disable-bt means there is no adapter to attach to.
	#                   bluez-firmware stays: it is files, and removing it buys
	#                   nothing the criterion cares about.
	#   MAPPED into other processes rather than started:
	#     libnss-mdns   an NSS module, loaded by anything that resolves a name.
	#
	# NOT removed, because they never met the criterion and one of them was load
	# bearing: alsa-utils, man-db and bluez-firmware are disk, not things that
	# load. alsa-utils in particular cannot be purged at all --
	#
	#   raspi-config          Depends: ... alsa-utils ...
	#   raspberrypi-sys-mods  Depends: raspi-config
	#                         Recommends: rfkill, userconf-pi
	#
	# -- so taking it drags out raspi-config, raspberrypi-sys-mods, userconf-pi and
	# raspberrypi-net-mods, which is provisioning and the radio. It cost a card.
	#
	# NOT removed:
	#   console-setup, keyboard-configuration  these DO start at boot and would
	#           otherwise qualify, but cloud-init's keyboard module drives them and
	#           user-data sets a keymap. Removing them means removing that too.
	#   e2fsprogs  Priority: required. Its scrub units are masked below instead --
	#           ext4 scrubbing on a btrfs root.
	#   apparmor   Docker confines containers with it.
	#   polkitd    NetworkManager depends on it, and it is running.
	#   wpa_supplicant  NetworkManager's 802.11 backend, running.
	#   rpi-eeprom  no EEPROM on a Zero 2 W, but the coordinator and pocketterm
	#           need it to update their bootloaders.
	#
	# Not -qq: the log should show what came out.
	# A heredoc rather than -c '...', so the script can contain single quotes.
	chroot "$ROOTFS" /bin/bash -euo pipefail -s <<'CHROOT'
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq btrfs-progs busybox-static
		PURGE="avahi-daemon libnss-mdns bluez udisks2 cron"

		# GUARD 1: protect what we need from a later autoremove, rather than relying
		# on nobody running one. The mark travels with the image, so it also covers
		# the autoremove on host/ansible/roles/bootstrap's dist_upgrade path -- which
		# is where that role does the same thing, for the same reason.
		#
		# Only packages currently marked AUTO, which is exactly the at-risk set;
		# autoremove never touches a manual one. Marking only what is at risk avoids
		# pinning half the system and defeating autoremove entirely.
		#
		# Order is load-bearing: mark while the archive index is still on disk.
		idx=$(ls /var/lib/apt/lists/*raspberrypi*_Packages 2>/dev/null | head -1) || idx=""
		if [ -z "$idx" ]; then
			echo "!! no Raspberry Pi archive index -- cannot protect its packages" >&2
			exit 1
		fi
		at_risk=$(comm -12 \
			<(apt-mark showauto | sort -u) \
			<(awk '/^Package: /{print $2}' "$idx" | sort -u))
		if [ -n "$at_risk" ]; then
			echo "== marking Pi-archive packages manual (autoremove-proof) =="
			apt-mark manual $at_risk | tail -1
		fi

		# GUARD 2: ask apt what the purge would do, before it does it. "Unneeded" is
		# a property of the dependency closure, not of intuition: raspi-config Depends
		# alsa-utils, so purging alsa-utils takes raspi-config, raspberrypi-sys-mods
		# and userconf-pi with it -- which is what cost a card. Marks do not help
		# there; they govern autoremove, not reverse-dependency removal. Only asking
		# does, and asking is what makes an aggressive list safe to hold.
		echo "== simulating purge =="
		would_remove=$(apt-get purge -s -y $PURGE | awk '/^Remv /{print $2}' | sort -u)
		requested=$(printf '%s\n' $PURGE | sort -u)
		extra=$(comm -13 <(echo "$requested") <(echo "$would_remove"))
		if [ -n "$extra" ]; then
			echo "!! purge would also remove packages that were not requested:" >&2
			echo "$extra" | sed 's/^/     /' >&2
			echo "   something in PURGE is a dependency of one of those." >&2
			exit 1
		fi
		echo "   removal set matches the list exactly"

		# Not -qq: the log should show what came out.
		apt-get purge -y $PURGE

		# No autoremove here. Guard 1 makes one safe, but its removal set is
		# unbounded and guard 2 does not cover it, so it is left to the converge --
		# where the same marks apply.
		# Nothing runs on a schedule. coordinator#282 masks these on a converged
		# device; doing it here as well closes the window between flash and first
		# converge, on a card whose timers would otherwise fire with Persistent=true
		# and catch up every missed window at once. Same list as that role, so the
		# two cannot drift -- add there and here together. Masking a unit whose
		# package is absent is legal and keeps the decision made.
		#
		# systemd-tmpfiles-clean.timer is deliberately NOT masked: it is the only
		# thing enforcing /tmp cleanup, and /tmp is a tmpfs here.
		systemctl mask \
			apt-daily.timer apt-daily-upgrade.timer \
			man-db.timer dpkg-db-backup.timer logrotate.timer \
			e2scrub_all.timer fstrim.timer
		# Not a timer, so not in that list: ext4 scrubbing on a btrfs root.
		systemctl mask e2scrub_reap.service
		update-initramfs -u -k all
CHROOT

	# Prove the purge. A leftover means apt kept something assumed gone.
	echo "== purge check: these must not exist =="
	local leftover=0 f
	for f in usr/sbin/avahi-daemon usr/bin/bluetoothctl usr/sbin/cron \
		usr/lib/systemd/system/udisks2.service; do
		if [ -e "$ROOTFS/$f" ]; then
			echo "   STILL PRESENT: /$f"
			leftover=1
		fi
	done
	[ "$leftover" -eq 0 ] && echo "   none present -- purge clean"

	# And the other direction, which the check above structurally cannot see: an
	# absence test never notices something that should still be THERE. These are
	# the Pi-archive pieces provisioning and the radio depend on, and they are
	# what autoremove took when it was still in this step.
	echo "== survival check: these must still exist =="
	local missing=0
	for f in usr/bin/raspi-config usr/lib/raspberrypi-sys-mods/imager_custom \
		usr/lib/userconf-pi/userconf usr/sbin/rfkill; do
		if [ -e "$ROOTFS/$f" ]; then
			echo "   present: /$f"
		else
			echo "!! MISSING: /$f -- provisioning or WiFi will not work" >&2
			missing=1
		fi
	done
	[ "$missing" -eq 0 ] || exit 1
	echo "== packages remaining: $(chroot "$ROOTFS" dpkg-query -f '.\n' -W 2>/dev/null | wc -l) =="

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
	install_no_swap
	regenerate_initramfs
	install_flasher_boot
	build_target
	report
}

main "$@"
