#!/usr/bin/env bash
#
# build-rockchip.sh -- convert the published Armbian image for a Radxa Zero 3W
# (vendor kernel) into the fleet btrfs-subvolume layout and emit a flashable
# .img. The Rockchip counterpart of build-image.sh, which execs this for a role
# with BOARD=radxa-zero3. Plan and sources: RADXA-ZERO3.md.
#
# As with the Pi build, the vendor image is taken as-is -- loader, kernel,
# device tree and boot script -- and only re-laid:
#
#   vendor: GPT, idbloader at sector 64, U-Boot FIT at 16384, ONE ext4 partition
#           at 32768 holding / with /boot as a directory
#   ours:   the same loader bytes, p1 FAT /boot, p2 btrfs in the fleet subvolume
#           graph
#
# U-Boot reads FAT and ext4 and not btrfs (measured: the string "btrfs" is not in
# the loader), which is why /boot is its own partition here rather than a
# directory of the root.
#
# WHERE THIS RUNS: as build-image.sh -- an arm64 host with a btrfs-capable kernel
# (CI: ubuntu-24.04-arm), as root. The rootfs is chrooted natively.
#
# Usage:
#   sudo ./build-rockchip.sh ROLE [OUT_IMG]
#
# shellcheck disable=SC2015  # a few benign `cond && act || true` cleanup idioms
set -euo pipefail

# ---- pinned upstream image ---------------------------------------------------
# Armbian 26.8.1, trixie, minimal, vendor kernel 6.1.115-vendor-rk35xx. The sha
# is the one Armbian publishes beside the image (.sha). To bump: URL and sha
# together, then re-check KVER and the overlay names below against the new
# image.
ARMBIAN_URL="https://dl.armbian.com/radxa-zero3/archive/Armbian_26.8.1_Radxa-zero3_trixie_vendor_6.1.115_minimal.img.xz"
ARMBIAN_SHA256="e78de9cb4b2d8ff1710c65c509d08faef1ba88c07fc3276b9dd637597e8234e8"
# The kernel that image carries. Its headers ship in the image (the WiFi DKMS
# needs them), which is what lets the IMX708 module be built here.
KVER="6.1.115-vendor-rk35xx"
# The board's device tree in that image (armbianEnv.txt fdtfile=).
FDTFILE="rockchip/rk3566-radxa-zero3.dtb"

# ---- IMX708 sensor driver ----------------------------------------------------
# In Armbian's vendor kernel tree (armbian/linux-rockchip#457, merged
# 2026-03-25 into rk-6.1-rkr5.1) but not enabled in the published image:
# `# CONFIG_VIDEO_IMX708 is not set`. Built here as one out-of-tree module
# against the image's own headers. The commit is the merge on that branch, the
# last one to touch the file; the sha pins the file itself.
IMX708_URL="https://raw.githubusercontent.com/armbian/linux-rockchip/ecbcd280793665594bffc5f9d07a0d673c3e41ad/drivers/media/i2c/imx708.c"
IMX708_SHA256="bfc17a23f88f2157ec9078d39f47492b71320c0939ba1dab1ee04d700bf714d5"

# ---- paths and role ----------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/.build"

ROLE="${1:?usage: build-rockchip.sh ROLE [OUT_IMG]}"
ROLE_ENV="$HERE/roles/$ROLE.env"
[ -f "$ROLE_ENV" ] || {
	echo "unknown role '$ROLE' (no $ROLE_ENV)" >&2
	exit 1
}
# shellcheck source=/dev/null
. "$ROLE_ENV"
[ "${BOARD:-}" = radxa-zero3 ] || {
	echo "role '$ROLE' is BOARD='${BOARD:-}', not radxa-zero3" >&2
	exit 1
}
DATA_MOUNT="${DATA_MOUNT:?roles/$ROLE.env must set DATA_MOUNT}"
METADATA="${METADATA:-single}"
APT_INSTALL="${APT_INSTALL:-}"
USER_OVERLAYS="${USER_OVERLAYS:-}"
VENDOR_OVERLAYS="${VENDOR_OVERLAYS:-}"
EXTRAARGS="${EXTRAARGS:-}"
BOOT_MOUNT=/boot
export DATA_MOUNT METADATA BOOT_MOUNT # consumed by assemble-btrfs.sh

BASE_URL="$ARMBIAN_URL" # named in /etc/fleet-image by image-common.sh
DL="$BUILD/$(basename "$ARMBIAN_URL")"
SRC_IMG="${DL%.xz}"
ROOTFS="$BUILD/rootfs"
BOOTSTAGE="$BUILD/bootfs" # /boot, moved out of the rootfs and onto p1
LOADER="$BUILD/loader.bin"
OUT_IMG="${2:-$BUILD/${ROLE}-radxa-$(date +%Y%m%d).img}"

# Partition geometry. The loader occupies sectors 64..32767 (16 MiB), so p1
# starts at 32768, where the vendor's root partition does.
#
# BOOT_MB: Armbian's own FAT /boot size (partitioning.sh). Boot content is the
# kernel, two initramfs forms and every rk35xx dtb and overlay. There is no
# re-flash staging on this board yet (coordinator#312 is Pi-shaped), so no
# headroom is reserved for it.
LOADER_FIRST=64
P1_START=32768
BOOT_MB=512
SLACK_MB=1536

# Fixed GPT GUIDs, so PARTUUIDs are identical across every card built from one
# image -- the GPT form of the Pi's fixed MBR id 0xc0dec0de.
DISK_GUID="c0dec0de-0000-4000-8000-000000000000"
P1_GUID="c0dec0de-0000-4000-8000-000000000001"
P2_GUID="c0dec0de-0000-4000-8000-000000000002"

require_tools() {
	local miss=0 t
	for t in xz curl sha256sum losetup mount umount rsync sgdisk dd \
		mkfs.vfat mkfs.btrfs blkid chroot chattr lsattr dtc fdtoverlay fdtget; do
		command -v "$t" >/dev/null 2>&1 || {
			echo "missing tool: $t" >&2
			miss=1
		}
	done
	[ "$miss" -eq 0 ] || exit 1
}

# Shared with build-image.sh: root check, mount/loop tracking and cleanup,
# grow-rootfs, the manifest, sudoers and the module blacklist.
# shellcheck source=pi-image/image-common.sh
. "$HERE/image-common.sh"

# =============================================================================
# 1. fetch + verify + decompress the vendor image
# =============================================================================
fetch_source() {
	mkdir -p "$BUILD"
	if [ ! -f "$DL" ]; then
		echo "== downloading $ARMBIAN_URL =="
		curl -fL --retry 3 -o "$DL" "$ARMBIAN_URL"
	fi
	echo "== verifying sha256 =="
	echo "$ARMBIAN_SHA256  $DL" | sha256sum -c -
	if [ ! -f "$SRC_IMG" ]; then
		echo "== decompressing =="
		xz -dk -T0 "$DL"
	fi
}

# =============================================================================
# 2. split the vendor image: loader bytes, and the rootfs
# =============================================================================
extract_source() {
	echo "== loader: sectors $LOADER_FIRST..$((P1_START - 1)) =="
	dd if="$SRC_IMG" of="$LOADER" bs=512 skip="$LOADER_FIRST" \
		count="$((P1_START - LOADER_FIRST))" status=none
	# The idbloader's magic. A different layout upstream fails here, not on a card.
	[ "$(head -c 4 "$LOADER")" = RKNS ] || {
		echo "!! no RKNS idbloader at sector $LOADER_FIRST -- vendor layout changed" >&2
		exit 1
	}
	echo "   RKNS at sector $LOADER_FIRST"

	echo "== loop-attaching vendor image =="
	SRC_LOOP="$(losetup --find --show -P "$SRC_IMG")"
	wait_for_partitions "$SRC_LOOP" 1
	local start
	start="$(cat "/sys/class/block/$(basename "$SRC_LOOP")p1/start")"
	[ "$start" -eq "$P1_START" ] || {
		echo "!! vendor root starts at sector $start, expected $P1_START" >&2
		exit 1
	}

	local sroot="$BUILD/src-root"
	mkdir -p "$sroot" "$ROOTFS"
	mount -o ro "${SRC_LOOP}p1" "$sroot"
	track_mount "$sroot"
	echo "== rsync vendor rootfs -> $ROOTFS =="
	rsync -aHAX --numeric-ids "$sroot"/ "$ROOTFS"/
	umount "$sroot" && MOUNTS=("${MOUNTS[@]/$sroot/}")
	losetup -d "$SRC_LOOP"
	SRC_LOOP=""

	[ -d "$ROOTFS/usr/src/linux-headers-$KVER" ] || {
		echo "!! no headers for $KVER in the image -- KVER is stale" >&2
		exit 1
	}
	[ -f "$ROOTFS/boot/dtb/$FDTFILE" ] || {
		echo "!! no $FDTFILE in the image" >&2
		exit 1
	}
}

# =============================================================================
# 3. device-tree overlays
#    Compile ours, then apply them -- with the vendor overlays the role lists --
#    to the board's dtb exactly as U-Boot will, and read the result back. An
#    overlay that does not apply makes boot.cmd fall back to the bare dtb, which
#    boots and silently has no PPS, no gadget and no camera.
# =============================================================================
install_overlays() {
	echo "== compile role overlays: $USER_OVERLAYS =="
	local o src dtbo vendor_dtbos=() user_dtbos=()
	mkdir -p "$ROOTFS/boot/overlay-user"
	for o in $USER_OVERLAYS; do
		src="$HERE/roles/$ROLE/$o.dtso"
		dtbo="$ROOTFS/boot/overlay-user/$o.dtbo"
		[ -f "$src" ] || {
			echo "!! USER_OVERLAYS names $o but there is no $src" >&2
			exit 1
		}
		dtc -@ -q -I dts -O dtb -o "$dtbo" "$src"
		user_dtbos+=("$dtbo")
	done
	for o in $VENDOR_OVERLAYS; do
		dtbo="$ROOTFS/boot/dtb/rockchip/overlay/$o.dtbo"
		[ -f "$dtbo" ] || {
			echo "!! VENDOR_OVERLAYS names $o but the image has no $dtbo" >&2
			exit 1
		}
		vendor_dtbos+=("$dtbo")
	done
	ls -l "${user_dtbos[@]}"

	# boot.cmd applies overlays= first, then user_overlays=; same order here.
	local applied="$BUILD/applied.dtb"
	fdtoverlay -i "$ROOTFS/boot/dtb/$FDTFILE" -o "$applied" \
		"${vendor_dtbos[@]}" "${user_dtbos[@]}"
	echo "   all overlays apply to $FDTFILE"

	# Read back what each overlay is for, so a renamed node upstream fails here.
	local want got path prop
	while read -r path prop want; do
		got="$(fdtget -t s "$applied" "$path" "$prop" 2>/dev/null || echo '<absent>')"
		if [ "$got" = "$want" ]; then
			echo "   $path $prop = $got"
		else
			echo "!! $path $prop = $got, expected $want" >&2
			exit 1
		fi
	done <<-'EOF'
		/usbdrd/usb@fcc00000 dr_mode peripheral
		/fiq-debugger status disabled
		/pps compatible pps-gpio
		/spi@fe640000 status okay
	EOF
	case " $USER_OVERLAYS " in
	*" rampod-imx708 "*)
		got="$(fdtget -t s "$applied" /i2c@fe5b0000/camera-imx708@1a compatible)"
		[ "$got" = sony,imx708 ] || {
			echo "!! IMX708 node not in the applied tree" >&2
			exit 1
		}
		echo "   /i2c@fe5b0000/camera-imx708@1a compatible = $got"
		;;
	esac
}

# =============================================================================
# 4. armbianEnv.txt -- the board's whole boot configuration, read by boot.scr.
#    Written whole rather than edited, so what the card boots with is this list
#    and nothing inherited. The root PARTUUID is fixed (P2_GUID), so this can be
#    written before the target exists.
#
#    console=display: no serial console= token (Seth, 2026-10-21). With the FIQ
#    debugger also off in the rampod overlay, no kernel driver owns UART2. The
#    loader still prints there before Linux.
# =============================================================================
write_armbian_env() {
	echo "== write /boot/armbianEnv.txt =="
	cat >"$ROOTFS/boot/armbianEnv.txt" <<-EOF
		verbosity=1
		bootlogo=false
		console=display
		overlay_prefix=rk35xx
		fdtfile=$FDTFILE
		rootdev=PARTUUID=$P2_GUID
		rootfstype=btrfs
		overlays=$VENDOR_OVERLAYS
		user_overlays=$USER_OVERLAYS
		extraargs=rootflags=subvol=@ $EXTRAARGS
	EOF
	cat "$ROOTFS/boot/armbianEnv.txt"
}

# =============================================================================
# 4b. device permissions and the WiFi country, the two things Raspberry Pi OS
#     ships and Armbian does not.
# =============================================================================

# Raspberry Pi OS puts /dev/spidev*, /dev/i2c-* and /dev/gpiochip* in the spi,
# i2c and gpio groups (raspberrypi-sys-mods, 99-com.rules). Armbian has neither
# the groups nor the rules, so the nodes are root-only and the pi account's
# group list does nothing. The payload runs privileged and does not need this;
# a person on the bench does. The lines are Pi OS's own, minus its legacy
# sysfs-gpio chgrp.
install_device_rules() {
	echo "== udev rules: spi, i2c, gpio groups =="
	mkdir -p "$ROOTFS/etc/udev/rules.d"
	cat >"$ROOTFS/etc/udev/rules.d/99-fleet-devices.rules" <<-'EOF'
		# Written by dotfiles-symm pi-image/build-rockchip.sh, after Raspberry Pi
		# OS's 99-com.rules.
		SUBSYSTEM=="i2c-dev", GROUP="i2c", MODE="0660"
		SUBSYSTEM=="spidev", GROUP="spi", MODE="0660"
		SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
	EOF
}

# What raspi-config nonint do_wifi_country does on a Pi, for this board:
# cfg80211.ieee80211_regdom on the kernel command line (armbianEnv.txt's
# extraargs here, cmdline.txt there) so it holds from boot, and iw reg set for
# the running kernel. user-data calls it once, at first boot, in place of
# raspi-config, which Armbian does not have.
install_wifi_country() {
	echo "== /usr/local/sbin/wifi-country =="
	install -D -m 0755 /dev/stdin "$ROOTFS/usr/local/sbin/wifi-country" <<-'EOF'
		#!/bin/sh
		# Set the WiFi regulatory domain: wifi-country <ISO 3166 alpha-2>.
		# Written by dotfiles-symm pi-image/build-rockchip.sh.
		set -eu
		cc="$1"
		grep -q "^${cc}[[:space:]]" /usr/share/zoneinfo/iso3166.tab || {
			echo "wifi-country: $cc is not an ISO 3166 alpha-2 code" >&2
			exit 1
		}
		sed -i -E \
			-e '/^extraargs=/s/ cfg80211\.ieee80211_regdom=[^ ]*//' \
			-e "/^extraargs=/s/\$/ cfg80211.ieee80211_regdom=$cc/" \
			/boot/armbianEnv.txt
		iw reg set "$cc"
	EOF
}

# =============================================================================
# 5. the chroot pass: packages, the IMX708 module, the appliance cleanup, and
#    an initramfs that can mount a btrfs root.
# =============================================================================
chroot_pass() {
	echo "== chroot pass =="
	for m in proc sys dev dev/pts; do
		mount --bind "/$m" "$ROOTFS/$m"
		track_mount "$ROOTFS/$m"
	done
	# Armbian's resolv.conf is a systemd-resolved symlink that dangles in a chroot.
	local resolv_saved=""
	if [ -L "$ROOTFS/etc/resolv.conf" ]; then
		resolv_saved="$(readlink "$ROOTFS/etc/resolv.conf")"
		rm "$ROOTFS/etc/resolv.conf"
	fi
	cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

	# The driver source, fetched host-side and verified before it is compiled.
	local msrc="$ROOTFS/usr/src/rampod-imx708"
	rm -rf "$msrc"
	mkdir -p "$msrc"
	curl -fL --retry 3 -o "$msrc/imx708.c" "$IMX708_URL"
	echo "$IMX708_SHA256  $msrc/imx708.c" | sha256sum -c -
	echo 'obj-m += imx708.o' >"$msrc/Makefile"

	echo "btrfs" >>"$ROOTFS/etc/initramfs-tools/modules"
	# As in build-image.sh: MODULES=dep inspects the running root, which in a
	# chroot is the build host's.
	echo "MODULES=most" >"$ROOTFS/etc/initramfs-tools/conf.d/fleet-modules"

	chroot "$ROOTFS" /bin/bash -euo pipefail -s "$APT_INSTALL" "$KVER" <<'CHROOT'
		export DEBIAN_FRONTEND=noninteractive
		kver="$2"
		apt-get update -qq

		if [ -n "${1:-}" ]; then
			echo "== installing the role's packages: $1 =="
			# shellcheck disable=SC2086  # word-splitting the package list is intended
			apt-get install -y -qq --no-install-recommends $1
		fi

		# -- IMX708: one module against the image's own kernel headers. gcc and
		#    make are already in the image (Armbian builds its WiFi driver with
		#    DKMS), so nothing is installed for this.
		echo "== build imx708.ko for $kver =="
		make -C "/usr/src/linux-headers-$kver" M=/usr/src/rampod-imx708 modules
		install -D -m 0644 /usr/src/rampod-imx708/imx708.ko \
			"/lib/modules/$kver/updates/imx708.ko"
		depmod -a "$kver"
		vm="$(modinfo -F vermagic "/lib/modules/$kver/updates/imx708.ko")"
		echo "   vermagic: $vm"
		case "$vm" in
		"$kver "*) ;;
		*)
			echo "!! imx708.ko vermagic '$vm' does not match $kver" >&2
			exit 1
			;;
		esac
		# The OF alias is what autoloads it when the overlay's node appears.
		modinfo -F alias "/lib/modules/$kver/updates/imx708.ko" | grep 'sony,imx708'
		rm -rf /usr/src/rampod-imx708

		# -- Network: NetworkManager, not netplan + networkd. The gadget profile,
		#    the WiFi keyfile and pod-link's radio control all assume it, as on
		#    the Pi roles. Armbian's one netplan file DHCPs every interface,
		#    which would race NM for usb0 and wlan0.
		rm -f /etc/netplan/*.yaml
		systemctl disable systemd-networkd.service systemd-networkd.socket \
			systemd-networkd-wait-online.service 2>/dev/null || true
		systemctl enable NetworkManager.service

		# -- Armbian's first-boot and runtime services, none of which an
		#    appliance wants:
		#      armbian-firstrun     regenerates host keys and arms the interactive
		#                           first-login wizard; cloud-init does the first
		#                           and the second does not apply
		#      armbian-ramlog       /var/log on a RAM disk, synced to the card
		#      armbian-zram-config  compressed swap; no swap here
		#      armbian-hardware-*, -led-state, -resize-filesystem
		#                           tuning, LED state, and an ext4 resize of a
		#                           partition that is now btrfs (grow-rootfs does it)
		#    Masked, not purged: they ship in the board-support package, which
		#    also carries the boot script and the kernel's install hooks.
		systemctl mask armbian-firstrun.service armbian-ramlog.service \
			armbian-zram-config.service armbian-hardware-monitor.service \
			armbian-hardware-optimize.service armbian-led-state.service \
			armbian-resize-filesystem.service
		# The interactive first-login wizard keys off this file.
		rm -f /root/.not_logged_in_yet

		# -- The groups 99-fleet-devices.rules names, present before the first
		#    boot's coldplug rather than created by cloud-init after it.
		groupadd -f --system spi
		groupadd -f --system i2c
		groupadd -f --system gpio

		# -- The timer list from the coordinator repo's
		#    host/ansible/roles/no-scheduled-maintenance (see build-image.sh),
		#    plus fake-hwclock's save timer, which writes the card on a schedule.
		systemctl mask \
			apt-daily.timer apt-daily-upgrade.timer \
			man-db.timer dpkg-db-backup.timer logrotate.timer \
			e2scrub_all.timer fstrim.timer systemd-tmpfiles-clean.timer \
			fake-hwclock-save.timer
		systemctl mask e2scrub_reap.service
		# Armbian's cron jobs (armbian-updates, -truncate-logs, -check-battery).
		systemctl mask cron.service

		# -- Credentials. The image ships root with a password and root SSH on,
		#    and every card would share its pre-generated host keys. Lock root,
		#    turn root SSH off, and delete the keys: cloud-init's ssh module
		#    generates fresh ones on first boot.
		passwd -l root
		sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
		grep -qx 'PermitRootLogin no' /etc/ssh/sshd_config
		rm -f /etc/ssh/ssh_host_*

		update-initramfs -u -k "$kver"
CHROOT

	rm -f "$ROOTFS/etc/resolv.conf"
	[ -n "$resolv_saved" ] && ln -s "$resolv_saved" "$ROOTFS/etc/resolv.conf"

	for m in dev/pts dev sys proc; do
		umount "$ROOTFS/$m" 2>/dev/null || true
		MOUNTS=("${MOUNTS[@]/$ROOTFS\/$m/}")
	done

	# U-Boot loads uInitrd, not initrd.img: Armbian's post-update hook wraps one
	# into the other. Check the file boot.cmd loads, and that it is fresh.
	echo "== initramfs check =="
	local ird="$ROOTFS/boot/initrd.img-$KVER" uird="$ROOTFS/boot/uInitrd-$KVER"
	ls -l "$ird" "$uird"
	[ "$uird" -nt "$ROOTFS/boot/vmlinuz-$KVER" ] || {
		echo "!! uInitrd-$KVER was not regenerated" >&2
		exit 1
	}
	if chroot "$ROOTFS" lsinitramfs "/boot/initrd.img-$KVER" | grep -q '/btrfs\.ko'; then
		echo "   initrd.img-$KVER carries btrfs"
	else
		echo "!! initrd.img-$KVER has NO btrfs module -- boot WILL fail" >&2
		exit 1
	fi
}

# =============================================================================
# 6. cloud-init: NoCloud from the FAT partition, as on the Pi roles.
#    The seed (user-data, meta-data) sits at the root of p1, which mounts at
#    /boot. No network config from cloud-init: WiFi is a NetworkManager keyfile
#    that user-data writes (see provision/user-data.template).
# =============================================================================
install_cloud_init_config() {
	echo "== cloud-init config =="
	mkdir -p "$ROOTFS/etc/cloud/cloud.cfg.d"
	cat >"$ROOTFS/etc/cloud/cloud.cfg.d/99_rampod.cfg" <<-'EOF'
		# Written by dotfiles-symm pi-image/build-rockchip.sh.
		datasource_list: [NoCloud, None]
		datasource:
		  NoCloud:
		    seedfrom: file:///boot/
		network:
		  config: disabled
		# user-data names the account with a singular `user:`, which merges over
		# this default. The groups are the ones the payload needs; cloud-init
		# creates any the image lacks.
		system_info:
		  default_user:
		    name: pi
		    lock_passwd: true
		    groups: [adm, dialout, sudo, video, plugdev, netdev, users, spi, i2c, gpio]
		    shell: /bin/bash
	EOF
	# Read the seed only once /boot is mounted.
	local u
	for u in cloud-init-local cloud-init-main cloud-init; do
		mkdir -p "$ROOTFS/etc/systemd/system/$u.service.d"
		printf '[Unit]\nRequiresMountsFor=/boot\n' \
			>"$ROOTFS/etc/systemd/system/$u.service.d/10-boot.conf"
	done
	# The image's python, which cloud-init brought python3-yaml into.
	chroot "$ROOTFS" python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \
		/etc/cloud/cloud.cfg.d/99_rampod.cfg
	echo "   99_rampod.cfg parses"
}

# =============================================================================
# 7. move /boot out of the rootfs. Symlinks are dereferenced, because FAT has
#    none: Image, uInitrd and dtb are links in the vendor tree, and boot.cmd
#    loads them by those names.
# =============================================================================
stage_boot() {
	echo "== stage /boot for p1 =="
	rm -rf "$BOOTSTAGE"
	mkdir -p "$BOOTSTAGE"
	rsync -rtL "$ROOTFS/boot"/ "$BOOTSTAGE"/
	find "$ROOTFS/boot" -mindepth 1 -delete
	local f
	for f in boot.scr armbianEnv.txt Image uInitrd "dtb/$FDTFILE"; do
		[ -f "$BOOTSTAGE/$f" ] || {
			echo "!! $f missing from staged /boot" >&2
			exit 1
		}
	done
	du -sh "$BOOTSTAGE"
}

# =============================================================================
# 8. build the target: GPT, loader bytes, FAT p1, btrfs p2
# =============================================================================
build_target() {
	local used_mb total_mb
	used_mb="$(du -sm --apparent-size "$ROOTFS" | cut -f1)"
	total_mb=$((P1_START / 2048 + BOOT_MB + used_mb + SLACK_MB))
	echo "== target image: ${total_mb} MiB (loader 16 + boot ${BOOT_MB} + rootfs ${used_mb} + slack ${SLACK_MB}) =="
	rm -f "$OUT_IMG"
	truncate -s "${total_mb}M" "$OUT_IMG"

	# p1 carries the legacy-BIOS-bootable attribute (bit 2): U-Boot's distro boot
	# scans partitions marked bootable, and falls back to p1 alone without one.
	echo "== partitioning (GPT) =="
	sgdisk -o -U "$DISK_GUID" \
		-n "1:$P1_START:+${BOOT_MB}M" -t 1:0700 -c 1:bootfs -u "1:$P1_GUID" -A 1:set:2 \
		-n 2:0:0 -t 2:8300 -c 2:rootfs -u "2:$P2_GUID" \
		"$OUT_IMG"

	# After the table: GPT occupies sectors 0-33 and the end of the disk, so the
	# loader at 64 is untouched by it.
	echo "== write loader at sector $LOADER_FIRST =="
	dd if="$LOADER" of="$OUT_IMG" bs=512 seek="$LOADER_FIRST" conv=notrunc status=none

	DST_LOOP="$(losetup --find --show -P "$OUT_IMG")"
	local p1="${DST_LOOP}p1" p2="${DST_LOOP}p2"
	wait_for_partitions "$DST_LOOP" 2

	echo "== mkfs.vfat -F32 -n bootfs $p1 =="
	mkfs.vfat -F 32 -n bootfs "$p1" >/dev/null
	local nboot="$BUILD/n-boot"
	mkdir -p "$nboot"
	mount "$p1" "$nboot"
	track_mount "$nboot"
	rsync -rt "$BOOTSTAGE"/ "$nboot"/
	umount "$nboot" && MOUNTS=("${MOUNTS[@]/$nboot/}")

	export BOOT_PARTUUID="$P1_GUID"
	echo "== assemble-btrfs.sh $ROOTFS $p2 =="
	"$HERE/assemble-btrfs.sh" "$ROOTFS" "$p2" "$BUILD"

	# The PARTUUIDs armbianEnv.txt and fstab name are the ones on the disk.
	local got
	got="$(blkid -s PARTUUID -o value "$p2")"
	[ "$got" = "$P2_GUID" ] || {
		echo "!! p2 PARTUUID $got, armbianEnv.txt says $P2_GUID" >&2
		exit 1
	}
	got="$(blkid -s PARTUUID -o value "$p1")"
	[ "$got" = "$P1_GUID" ] || {
		echo "!! p1 PARTUUID $got, fstab says $P1_GUID" >&2
		exit 1
	}

	losetup -d "$DST_LOOP"
	DST_LOOP=""
}

report() {
	echo
	echo "======================================================================"
	echo "built: $OUT_IMG"
	ls -lh "$OUT_IMG"
	sgdisk -p "$OUT_IMG"
	echo "loader magic at sector $LOADER_FIRST: $(dd if="$OUT_IMG" bs=512 skip="$LOADER_FIRST" count=1 status=none | head -c 4)"
	echo "---- generated fstab (from assemble) ----"
	cat "$BUILD/fstab.generated" 2>/dev/null || true
	echo "======================================================================"
}

main() {
	require_root
	require_tools
	fetch_source
	extract_source
	install_overlays
	write_armbian_env
	install_grow_rootfs
	write_manifest
	install_sudoers
	install_module_blacklist
	install_device_rules
	install_wifi_country
	chroot_pass
	install_cloud_init_config
	stage_boot
	build_target
	report
}

main "$@"
