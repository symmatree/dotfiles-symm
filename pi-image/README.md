# pi-image -- btrfs SD image build (coordinator + fleet)

The versioned, repeatable image-build pipeline for the power-loss-tolerant **btrfs subvolume** SD
layout (coordinator [#96](https://github.com/symmatree/coordinator/issues/96) / #41). It produces a
flashable `.img` per device role, carrying the subvolume layout a stock Raspberry Pi Imager flash
can't.

**Canonical design** (the subvolume layout, mount policy, and the power-loss rationale) lives in the
coordinator repo's `docs/power-loss-filesystem.md`. This README is the **build mechanics** only --
it does not restate the design.

## Two build paths

- **convert** (`build-image.sh`, **v1, CI-driven**) -- take the *official* Raspberry Pi OS Lite
  image as-is (kernel, firmware, `raspberrypi-sys-mods`, HAT/overlay glue all already correct) and
  only re-lay its rootfs into our subvolumes via `assemble-btrfs.sh`, then fix up the boot config.
  Lowest-risk first cut: nothing about the vendor userland changes.
- **build-from-scratch** (mmdebstrap, *future*) -- a 2026-07-30 spike found `rpi-image-gen` builds a
  **single** btrfs root (+ `-m single`) natively but has **no subvolume support** (genimage
  populates the top-level subvolume; the fstab is hardcoded `defaults`). Our `@` / `@usr`-ro /
  `@var` / `@home` / `@data` layout can't be expressed there, so the eventual scratch build is
  **mmdebstrap** arm64 rootfs -> `assemble-btrfs.sh` -> **genimage**.

## Roles

One shared btrfs subvolume graph; per-role **knobs** (coordinator
[#96](https://github.com/symmatree/coordinator/issues/96) "one layout, per-role
knobs"). `build-image.sh <role>` sources `roles/<role>.env`:

| knob | `coordinator` | `campod` | `pocketterm` |
|------|---------------|-------|--------------|
| hardware | Pi 4B / SD | Zero 2 W / SD | Pi 5 / NVMe |
| `DATA_MOUNT` (where `@data` mounts) | `/var/lib/coordinator` (captures) | `/var/lib/pod` (captures) | `/var/lib/store` (bulk store → NAS) |
| `METADATA` (`mkfs.btrfs -m`) | `single` (SD) | `single` (SD) | `dup` (NVMe) |
| `CONFIG_APPEND` | — | `roles/campod/config.append.txt` (serial console, dwc2) | `roles/pocketterm/config.append.txt` (display/kbd/PCIe) |
| `OVERLAY_ZIP_URL` | — | — | Waveshare 3.5" panel `.dtbo` (sha-pinned) |

The subvolumes (`@ @usr @var @home @data @scratch @snapshots`), ro-`/usr`, and the
btrfs-in-initramfs regen are **identical across roles**.

> [!NOTE]
> ⚠️ **`ro`-`/usr` is not actually enforced as built** — the fstab (`/usr … ro`) and the assembly are
> correct, but at boot `/usr` comes up `rw`: `@usr` shares the root btrfs *superblock*, so when
> `systemd-remount-fs` remounts `/` rw the read-only flag on `/usr` is dropped, and a live `/usr` can't
> be remounted `ro` ("busy"). Tracked as an open design question in coordinator
> [#96](https://github.com/symmatree/coordinator/issues/96); full evidence in
> `facts/topics/power-unstable-pi.md` → "Reality check".

Add a role by dropping a
new `roles/<name>.env` and adding it to the matrix in `build-pi-image.yaml`.

## Pieces

| file | what | status |
|------|------|--------|
| `assemble-btrfs.sh` | lay a populated rootfs into the layout: `mkfs.btrfs -m single`, create `@ @usr @var @home @data @scratch @snapshots`, populate each from the right rootfs slice, `chattr +C` docker, write `/etc/fstab` + emit the cmdline fragment | **done, verified** |
| `test-assemble.sh` | local proof: dummy rootfs -> loopback image -> assemble -> mount per the generated fstab -> assert (all seven subvols, exclusive split, `ro`-`/usr` + `remount,rw` *of the assembled fstab* — note the **booted** `/usr` comes up `rw`, see [#96](https://github.com/symmatree/coordinator/issues/96), `@data` nesting under `/var`, docker `+C`). Needs a btrfs-capable kernel + `sudo`. | done |
| `verify-in-vm.sh` | run `test-assemble.sh` inside a throwaway KVM guest -- for hosts whose kernel lacks btrfs (e.g. the Talos notebook host). | done |
| `build-image.sh` | **convert path.** Download+verify the pinned official RPi OS Lite Bookworm arm64 image, extract its rootfs + boot partition, natively chroot the arm64 rootfs to regenerate the initramfs **with btrfs**, build a fresh MBR image (FAT `bootfs` p1 + btrfs p2 via `assemble-btrfs.sh`), fix up `cmdline.txt`/`config.txt`. arm64 + btrfs kernel only (CI: `ubuntu-24.04-arm`). | **v1, unproven boot** |
| `boot-test.sh` | best-effort smoke test: pull kernel+initramfs from the built image, boot `qemu-system-aarch64 -M virt` with the image as a virtio disk, grep serial for a btrfs-root login/pivot. Non-fatal in v1 (`STRICT=1` to gate). | **v1** |
| `.github/workflows/build-pi-image.yaml` | run `build-image.sh` -> `boot-test.sh` -> upload the compressed `.img` (+ serial log) on `ubuntu-24.04-arm`. | **v1** |
| mmdebstrap rootfs config + genimage | the scratch build path | **TODO** |

Pinned upstream: `2025-05-13-raspios-bookworm-arm64-lite.img.xz`
(sha256 `62d025b9...ed45`) -- the last *Bookworm* Lite arm64 release (2025-10 onward raspios is
Trixie). Bump URL+date+sha together in `build-image.sh`.

## Status -- built end-to-end; boot unproven, the card is the gate

The subvolume **assembly is verified**, and `build-pi-image.yaml` now **builds a real convert image
end-to-end** in CI: download+verify -> native-chroot initramfs regen with btrfs -> `assemble-btrfs.sh`
-> package -> compress -> artifact. **Latest image:** `datasets/images/coordinator-pi-<YYYYMMDD>.img.xz`
on the NAS (a CI build artifact -- regenerable, not source-controlled).

**Boot is NOT yet proven, and the qemu `-M virt` boot-test cannot prove it.** The initramfs comes up
btrfs-capable, but the Raspberry Pi *downstream* kernel does not initialise virtio on the synthetic
`-M virt` platform, so no root disk appears (`/dev/vdaX does not exist`) -- an **emulation limitation,
not an image fault**. Conclusive validation needs `raspi4b`-machine qemu (finicky) or, simplest, a
**spare SD card on real hardware**, with the current ext4 card kept as instant rollback. That card
flash is the real gate. (The initramfs crux `build-image.sh` handles: RPi OS boots initramfs-less
and ships btrfs as a *module*, so it sets `auto_initramfs=1`, adds `btrfs` to the initramfs, installs
`btrfs-progs`, and regenerates the initramfs in a native arm64 chroot with `MODULES=most`.)

## Flash it

```bash
# Raspberry Pi Imager: "Use custom" -> select the .img.xz directly (it reads xz).
# Or from a shell:
xzcat <role>-pi-<date>.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

The image ships `root=PARTUUID=<btrfs p2> rootfstype=btrfs rootflags=subvol=@` and `auto_initramfs=1`.
If it does not come up, the boot config (cmdline/initramfs) is where to iterate -- the filesystem
itself is verified.

### Headless first boot

The image is generic and secret-free: it has **no login** (the vendor `pi` account is
`!`-locked in `/etc/shadow`), no SSH host keys, and no WiFi. Identity is injected per unit
after the flash, touching **only the FAT partition** (coordinator#96).

The vehicle is the vendor's own mechanism, which this image keeps working:

1. A `firstrun.sh` is written to the FAT partition and
   ` systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target`
   is appended to `cmdline.txt`.
2. The initramfs script `imager_fixup` (from `raspberrypi-sys-mods`, present in the pinned
   base and carried into our regenerated initramfs) reads `/boot/firmware` out of the root
   fs's `/etc/fstab`, mounts it rw, and rewrites `/boot/` -> `/boot/firmware/` in both
   `cmdline.txt` and the script's self-cleanup tail. It resolves our `PARTUUID=` spec fine.
3. systemd runs the script: hostname -> SSH keys -> `userconf` rename (`usermod -m`, so
   `~/.ssh` follows the home dir) -> `imager_custom set_wlan` (writes a NetworkManager
   keyfile) -> self-delete -> reboot.

This does **not** depend on `init=/usr/lib/raspberrypi-sys-mods/firstboot`, which
`build-image.sh` strips (it runs `resize2fs`, which is meaningless on btrfs). `systemd.run=`
is a systemd feature. Consequences of stripping it: `custom.toml` is **not** applied on this
image (that is the `firstboot` script's job), and SSH host keys come from
`regenerate_ssh_host_keys.service` instead (enabled in the base image, so still covered).

Bookworm has no `wpa_supplicant.conf`-on-boot-partition path any more -- WiFi is a
NetworkManager keyfile on the *root* filesystem -- so `firstrun.sh` is the only FAT-only way
to preconfigure WiFi. `userconf.txt` and an empty `ssh` file still work for the user account
and sshd, but cannot carry WiFi.

## Run the test

```bash
# host with a btrfs-capable kernel:
sudo pi-image/test-assemble.sh

# host WITHOUT btrfs (runs the test in a KVM guest; needs qemu-system-x86 + /dev/kvm +
# a cloud image at pi-image/.vm/jammy.img):
pi-image/verify-in-vm.sh
```
