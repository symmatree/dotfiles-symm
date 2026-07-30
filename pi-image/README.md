# pi-image -- btrfs SD image build (coordinator + fleet)

The versioned, repeatable image-build pipeline for the power-loss-tolerant **btrfs subvolume** SD
layout (coordinator [#96](https://github.com/symmatree/coordinator/issues/96) / #41). It produces a
flashable `.img` per device role, carrying the subvolume layout a stock Raspberry Pi Imager flash
can't.

**Canonical design** (the subvolume layout, mount policy, and the power-loss rationale) lives in the
coordinator repo's `docs/power-loss-filesystem.md`. This README is the **build mechanics** only --
it does not restate the design.

## Why mmdebstrap-in-CI (not rpi-image-gen)

A 2026-07-30 spike found `rpi-image-gen` builds a **single** btrfs root (+ `-m single`) natively but
has **no subvolume support** (its genimage step populates the top-level subvolume; the generated
fstab is hardcoded `defaults`). Our `@` / `@usr`-ro / `@var` / `@home` / `@data` layout can't be
expressed there. So the build is: **mmdebstrap** arm64 rootfs -> `assemble-btrfs.sh` lays it into the
subvolumes and writes the fstab + cmdline -> **genimage** packages the `.img`.

## Pieces

| file | what | status |
|------|------|--------|
| `assemble-btrfs.sh` | lay a populated rootfs into the layout: `mkfs.btrfs -m single`, create `@ @usr @var @home @data @snapshots`, populate each from the right rootfs slice, `chattr +C` docker, write `/etc/fstab` + emit the cmdline fragment | **done, verified** |
| `test-assemble.sh` | local proof: dummy rootfs -> loopback image -> assemble -> mount per the generated fstab -> assert (all six subvols, exclusive split, `ro`-`/usr` + `remount,rw`, `@data` nesting under `/var`, docker `+C`). Needs a btrfs-capable kernel + `sudo`. | done |
| `verify-in-vm.sh` | run `test-assemble.sh` inside a throwaway KVM guest -- for hosts whose kernel lacks btrfs (e.g. the Talos notebook host). | done |
| mmdebstrap rootfs config | build the arm64 Debian rootfs + Pi kernel/firmware, per role | **TODO** |
| genimage config + CI | FAT `/boot/firmware` partition + wrap into a flashable per-role `.img`, in CI | **TODO** |

## Status -- the one open gate

The subvolume **assembly is verified**: every `test-assemble.sh` check passes in a real btrfs kernel.
The remaining unknown is whether a Pi actually **boots** from a btrfs-subvolume root on the stock
initramfs (mounts `subvol=@` and pivots) -- proven by building a real `.img` and booting it under
`qemu-system-aarch64` (RPi firmware) or on a **spare** SD card, with the current ext4 card kept as
instant rollback. Everything up to that (rootfs, packaging) is hardware-free.

## Run the test

```bash
# host with a btrfs-capable kernel:
sudo pi-image/test-assemble.sh

# host WITHOUT btrfs (runs the test in a KVM guest; needs qemu-system-x86 + /dev/kvm +
# a cloud image at pi-image/.vm/jammy.img):
pi-image/verify-in-vm.sh
```
