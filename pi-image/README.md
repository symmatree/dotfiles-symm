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
| `DATA_MOUNT` (where `@data` mounts) | `/var/lib/coordinator` (captures) | `/var/lib/campod` (captures) | `/var/lib/store` (bulk store → NAS) |
| `METADATA` (`mkfs.btrfs -m`) | `single` (SD) | `single` (SD) | `dup` (NVMe) |
| `CONFIG_APPEND` | `roles/coordinator/config.append.txt` (FC UART, I2C) | `roles/campod/config.append.txt` (serial console, dwc2, SPI) | `roles/pocketterm/config.append.txt` (display/kbd/PCIe) |
| `CMDLINE_REMOVE` / `CMDLINE_APPEND` (kernel cmdline: glob-matched removals, then appends) | `console=serial0,*` removed — the FC owns that UART | serial console moved **last** so `/dev/console` is the UART; `quiet` dropped | — |
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
| `assemble-btrfs.sh` | lay a populated rootfs into the layout: `mkfs.btrfs -m single`, create `@ @usr @var @home @data @scratch @snapshots`, populate each from the right rootfs slice, `chattr +C` docker + `@scratch` (nodatacow cannot be a per-subvolume mount option), write `/etc/fstab` + emit the cmdline fragment | **done, verified** |
| `test-assemble.sh` | local proof: dummy rootfs -> loopback image -> assemble -> mount per the generated fstab -> assert (all seven subvols, exclusive split, `ro`-`/usr` + `remount,rw` *of the assembled fstab* — note the **booted** `/usr` comes up `rw`, see [#96](https://github.com/symmatree/coordinator/issues/96), `@data` nesting under `/var`, docker + `@scratch` `+C`). Needs a btrfs-capable kernel + `sudo`. | done |
| `verify-in-vm.sh` | run `test-assemble.sh` inside a throwaway KVM guest -- for hosts whose kernel lacks btrfs (e.g. the Talos notebook host). | done |
| `build-image.sh` | **convert path.** Download+verify the pinned official RPi OS Lite Trixie arm64 image, extract its rootfs + boot partition, natively chroot the arm64 rootfs to regenerate the initramfs **with btrfs**, build a fresh MBR image (FAT `bootfs` p1 + btrfs p2 via `assemble-btrfs.sh`), write the image manifest, fix up `cmdline.txt`/`config.txt`. arm64 + btrfs kernel only (CI: `ubuntu-24.04-arm`). | **boots on hardware** |
| `provision/` | per-unit identity at flash time -- cloud-init `user-data` template + `Flash-Card.ps1`. FAT-partition only, so the flashing host needs no btrfs/WSL. | done |
| `.github/workflows/build-pi-image.yaml` | run `build-image.sh` -> upload the compressed `.img` on `ubuntu-24.04-arm`, per role. | done |
| mmdebstrap rootfs config + genimage | the scratch build path | **TODO** |

Pinned upstream: `2026-09-15-raspios-trixie-arm64-lite.img.xz` (sha256 `cdf4f3bf...27e5`), the
current Lite arm64 release. Bump URL+date+sha together in `build-image.sh` -- and move
`containers/campod-camera`'s `RPI_SUITE` in the same window, since the container installs
libcamera from the same Pi archive suite as the host.

## Status -- boots on all three roles

The image boots on every role's hardware, from SD in each case: `coordinator` on a Pi 4B,
`campod` on a Zero 2 W, `pocketterm` on a Pi 5 (then cloned to NVMe). `@` and `@usr` both mount,
`initramfs8` / `initramfs_2712` load under `auto_initramfs=1`, and per-unit provisioning runs on
the first boot. That clears the gate coordinator#96 carried.

Not built: the `mmdebstrap` from-scratch path. The convert path is what exists.

There is no automated boot test, and `-M virt` qemu is not the way to add one -- the Raspberry Pi
downstream kernel does not initialise virtio on that synthetic platform, so no root disk appears.
If a gate is ever wanted, `raspi4b`-machine qemu is the direction.

The read-only `/usr` pillar is enforced on both SD units as of 2026-09-12 (`ro` in the mount
options, writes refused), which contradicts coordinator#202 -- see that issue.

## Flash it

Download the `<role>-pi-btrfs-img` artifact from a `build-pi-image` run. Actions always
serves artifacts as a zip, so what lands is `<role>-pi-btrfs-img.zip` -- containing a **raw
`.img`**, which means rpi-imager can be pointed at the downloaded zip directly. No unwrap.

```bash
# Raspberry Pi Imager: "Use custom" -> select the downloaded .zip.
# Or, having unzipped it, from a shell:
sudo dd if=<role>-pi-<date>.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Per-unit identity (hostname, user, SSH key, WiFi) is injected at flash time -- see
[`provision/`](provision/).

### Partition geometry

`BOOT_MB=1536`, `SLACK_MB=1536`. The FAT partition is oversized on purpose: boot content is
~76 MiB, and the rest is staging room for a compressed image during a touchless re-flash
([coordinator#312](https://github.com/symmatree/coordinator/issues/312)), which streams
`unzip | dd` out of p1 onto p2. It cannot be resized in place -- p2 starts immediately after
p1 -- so a change here costs every device a full reflash.

The image ships `root=PARTUUID=<btrfs p2> rootfstype=btrfs rootflags=subvol=@` and `auto_initramfs=1`.
If it does not come up, the boot config (cmdline/initramfs) is where to iterate -- the filesystem
itself is verified.

### Headless first boot

The image is generic and secret-free: it has **no login** (the vendor `pi` account is
`!`-locked in `/etc/shadow`), no SSH host keys, and no WiFi. Identity is injected per unit
after the flash, touching **only the FAT partition** (coordinator#96).

The vehicle is cloud-init, which the image ships with a NoCloud datasource already pointed
at the boot partition (`seedfrom: file:///boot/firmware`, and
`RequiresMountsFor=/boot/firmware` on `cloud-init-main.service`). `Flash-Card.ps1` renders
[`provision/user-data.template`](provision/) and rpi-imager writes it, plus a generated
`meta-data`, onto the FAT partition. One boot, no script, no initramfs fixup, no
`cmdline.txt` surgery of ours.

It sets the hostname, creates the account with its SSH key and password hash, enables
`ssh.service`, and writes WiFi as a NetworkManager keyfile. SSH host keys come from
`regenerate_ssh_host_keys.service`, enabled in the base image. Passwordless sudo comes from
`/etc/sudoers.d/010_pi-nopasswd`, which the base no longer ships and `build-image.sh`
installs.

WiFi is **not** supplied as cloud-init `network-config`: that renders through netplan, and
`/etc/cloud/cloud.cfg` still lists a `netplan_nm_patch` module the package no longer
contains. See [`provision/README.md`](provision/README.md) for the detail and for why
`cloud-init status` reports `degraded` on every card regardless.

## Run the test

```bash
# host with a btrfs-capable kernel:
sudo pi-image/test-assemble.sh

# host WITHOUT btrfs (runs the test in a KVM guest; needs qemu-system-x86 + /dev/kvm +
# a cloud image at pi-image/.vm/jammy.img):
pi-image/verify-in-vm.sh
```
