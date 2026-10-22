# shellcheck shell=bash
#
# image-common.sh -- the steps every image build shares, whatever the board.
# Sourced by build-image.sh (Raspberry Pi) and build-rockchip.sh (Radxa), never run.
#
# The caller sets, before sourcing or before calling:
#   HERE      pi-image/
#   ROOTFS    the rootfs being built
#   ROLE      the role name
#   OUT_IMG   the final image path (its basename goes in the manifest)
#   BASE_URL  the pinned vendor image this one is converted from
#   MODULE_BLACKLIST  optional, from roles/<role>.env
#
# shellcheck disable=SC2015  # a few benign `cond && act || true` cleanup idioms

require_root() {
	[ "$(id -u)" -eq 0 ] || {
		echo "must run as root (loop/mount/mkfs)" >&2
		exit 1
	}
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
	base="$(basename "$BASE_URL")"
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
# 2f-bis. per-role module blacklist
#     A driver we do not want running should not be running -- not because of
#     the memory, but because an appliance in flight should execute nothing it
#     does not need.
#
#     This has to be in the IMAGE rather than applied later by ansible. The
#     initramfs carries MODULES=most (see step 3) and udev coldplugs from it, so
#     by the time the rootfs is up the modules are already loaded. modprobe.d is
#     copied into the initramfs at build time, so blacklisting here catches both.
#     Applying it on a running device would instead mean regenerating the
#     initramfs, which writes /boot/firmware.
# =============================================================================
install_module_blacklist() {
	[ -n "${MODULE_BLACKLIST:-}" ] || return 0
	echo "== blacklist modules ($ROLE) =="
	mkdir -p "$ROOTFS/etc/modprobe.d"
	{
		echo "# Written by dotfiles-symm pi-image/build-image.sh for role $ROLE."
		echo "# Baked in before update-initramfs so it applies to coldplug too."
		for m in $MODULE_BLACKLIST; do
			# blacklist stops alias-based autoload; install /bin/false stops an
			# explicit modprobe as well, including one from inside the initramfs.
			echo "blacklist $m"
			echo "install $m /bin/false"
		done
	} >"$ROOTFS/etc/modprobe.d/$ROLE-blacklist.conf"
	cat "$ROOTFS/etc/modprobe.d/$ROLE-blacklist.conf"
}
