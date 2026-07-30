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

## Pieces

| file | what | status |
|------|------|--------|
| `assemble-btrfs.sh` | lay a populated rootfs into the layout: `mkfs.btrfs -m single`, create `@ @usr @var @home @data @snapshots`, populate each from the right rootfs slice, `chattr +C` docker, write `/etc/fstab` + emit the cmdline fragment | **done, verified** |
| `test-assemble.sh` | local proof: dummy rootfs -> loopback image -> assemble -> mount per the generated fstab -> assert (all six subvols, exclusive split, `ro`-`/usr` + `remount,rw`, `@data` nesting under `/var`, docker `+C`). Needs a btrfs-capable kernel + `sudo`. | done |
| `verify-in-vm.sh` | run `test-assemble.sh` inside a throwaway KVM guest -- for hosts whose kernel lacks btrfs (e.g. the Talos notebook host). | done |
| `build-image.sh` | **convert path.** Download+verify the pinned official RPi OS Lite Bookworm arm64 image, extract its rootfs + boot partition, natively chroot the arm64 rootfs to regenerate the initramfs **with btrfs**, build a fresh MBR image (FAT `bootfs` p1 + btrfs p2 via `assemble-btrfs.sh`), fix up `cmdline.txt`/`config.txt`. arm64 + btrfs kernel only (CI: `ubuntu-24.04-arm`). | **v1, unproven boot** |
| `boot-test.sh` | best-effort smoke test: pull kernel+initramfs from the built image, boot `qemu-system-aarch64 -M virt` with the image as a virtio disk, grep serial for a btrfs-root login/pivot. Non-fatal in v1 (`STRICT=1` to gate). | **v1** |
| `.github/workflows/build-pi-image.yaml` | run `build-image.sh` -> `boot-test.sh` -> upload the compressed `.img` (+ serial log) on `ubuntu-24.04-arm`. | **v1** |
| mmdebstrap rootfs config + genimage | the scratch build path | **TODO** |

Pinned upstream: `2025-05-13-raspios-bookworm-arm64-lite.img.xz`
(sha256 `62d025b9...ed45`) -- the last *Bookworm* Lite arm64 release (2025-10 onward raspios is
Trixie). Bump URL+date+sha together in `build-image.sh`.

## Status -- the open gate

The subvolume **assembly is verified**; `build-image.sh` now packages a real convert image, but
whether a Pi actually **boots** from the btrfs-subvol root is **not yet proven**. The crux is the
initramfs: RPi OS boots with **no initramfs** by default and its kernel has btrfs as a *module*, so
`build-image.sh` sets `auto_initramfs=1`, adds `btrfs` to `/etc/initramfs-tools/modules`, installs
`btrfs-progs`, and regenerates the initramfs in a native arm64 chroot. `boot-test.sh` under
`-M virt` is the CI gate; the strong proof is still a **spare** SD card on real hardware (RPi
firmware), current ext4 card kept as instant rollback.

## Run the test

```bash
# host with a btrfs-capable kernel:
sudo pi-image/test-assemble.sh

# host WITHOUT btrfs (runs the test in a KVM guest; needs qemu-system-x86 + /dev/kvm +
# a cloud image at pi-image/.vm/jammy.img):
pi-image/verify-in-vm.sh
```
