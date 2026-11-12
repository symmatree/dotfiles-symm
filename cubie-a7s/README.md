# cubie-a7s -- Talos on the Radxa Cubie A7S

Build inputs for running Talos on the Radxa Cubie A7S (Allwinner A733). The board,
the boot chain, measurements and the provenance of each build are in fables:
[`Tiles/Cubie A7S.md`](https://github.com/symmatree/fables/blob/main/Tiles/Cubie%20A7S.md)
and `Tiles/Cubie A7S build and boot chain.md`. Built binaries live in
`datasets/cubie-a7s/`, not here.

Everything builds natively on an arm64 host with docker and buildx (a
`docker-container` builder: `docker buildx create --name local --use`).

## Kernel (`talos-kernel/`)

Talos's own kernel build, [siderolabs/pkgs](https://github.com/siderolabs/pkgs) at the
commit the Talos release uses (`f4bda77` for 1.14.5), with two inputs replaced:

- `kernel/build/patches/`: Talos's patches plus DockSeed's
  [a7s-linux-lts](https://github.com/DockSeed/a7s-linux-lts) series, renamed to sort
  after Talos's by `stage-patches.sh <a7s-linux-lts checkout> <outdir>`.
- `kernel/build/config-arm64`: `config-arm64` here, which is Talos's file plus
  `a733-cubie-a7s.fragment`, made by `make-config.sh`.

`apply-series.sh` applies a `series` file at fuzz 0 and reports exact / offset / fail
per patch, for checking the series against a new kernel version.

```sh
cd pkgs
make local-kernel PLATFORM=linux/arm64 DEST=_out/kernel PROGRESS=plain
```

On an 8 GB board the BTF step (`pahole -j8`) needs more than RAM plus zram; build r1
ran with an 8 GiB swapfile added.

## Overlay (`talos-overlay/`)

A Talos overlay modeled on [siderolabs/sbc-allwinner](https://github.com/siderolabs/sbc-allwinner)'s
`pine64` installer. The installer writes `u-boot-sunxi-with-spl.bin` at 128 KiB (the
A733 boot ROM reads sector 256), copies the board dtb to `/dtb/allwinner/` on the EFI
partition (one of the paths U-Boot's EFI scan loads `fdtfile` from), sets the kernel
arguments, and starts the partitions at 16 MiB. `profiles/cubie_a7s.yaml` selects GRUB,
as Sidero's `pine64` profile does.

The image needs two artifacts that are not committed:

| Path in the build context | Source |
|---|---|
| `artifacts/arm64/u-boot/cubie_a7s/u-boot-sunxi-with-spl.bin` | [DockSeed a733-bootchain](https://github.com/DockSeed/a733-bootchain), via `a7s-build`'s bootchain stage |
| `artifacts/arm64/dtb/allwinner/sun60i-a733-cubie-a7s.dtb` | the kernel build's `dtb/allwinner/` |

```sh
cd talos-overlay
docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
  --output type=oci,dest=../cubie-overlay-oci,tar=false .
```

## Talos image (`talos-image/`)

The kernel build's output becomes the kernel image Talos's build takes, with no
recompile:

```sh
mkdir kimg && tar -I zstd -xf kernel.tar.zst -C kimg   # kernel/{boot,dtb,usr,...}
printf 'FROM scratch\nCOPY kernel/ /\n' > kimg/Dockerfile
docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
  --output type=oci,dest=$HOME/cubie-kernel-oci,tar=false kimg
```

The initramfs comes from an unmodified [siderolabs/talos](https://github.com/siderolabs/talos)
checkout at the release tag, with that image passed in as a named build context:

```sh
make initramfs PLATFORM=linux/arm64 PKG_KERNEL=cubie-kernel PROGRESS=plain \
  TARGET_ARGS="--build-context cubie-kernel=oci-layout://$HOME/cubie-kernel-oci@<manifest digest>"
```

Only the modules in Talos's `hack/modules-arm64.txt` go into the initramfs; the
Cubie's ethernet modules are on it, its USB hub and USB-C controller modules are not.

The disk image is Sidero's imager for the same release. `profile.yaml` expects
`/work/vmlinuz` (the kernel build's `boot/vmlinuz`), `/work/initramfs-arm64.xz` and
`/work/cubie-overlay-oci`:

```sh
docker run --rm -i --privileged -v /dev:/dev -v $HOME/imgwork:/work:ro -v $HOME/imgout:/out \
  ghcr.io/siderolabs/imager:v1.14.5 - < profile.yaml
```

The output, `metal-arm64.raw.xz`, is flashed to the card as-is.

Each board's image also carries its address, since the board's MAC is random per boot
and there is no DHCP reservation (tiles `docs/bare-metal-nodes.md#cubie-a7s-static-address`).
Add to `profile.yaml`, with the board's address and name:

```yaml
customization:
  extraKernelArgs:
    - net.ifnames=0
    - ip=<ip>::10.0.0.1:255.255.0.0:<name>:eth0:off:10.0.99.1::10.0.99.1
```

`set-node.py` makes another board's image from one that already has the argument,
without the imager: it rewrites the address and hostname in grub.cfg in place,
padded to the same length, and refuses an address or name longer than the source's.

```sh
xz -dc talos-image-v1.14.5-r1-cubie-1/metal-arm64.raw.xz > cubie-1.raw
./set-node.py cubie-1.raw marino.raw 10.0.128.15 marino
```

## Debian test card (`test-card/`)

`mkimg.sh` turns DockSeed's `a7s-trixie-minimal` image into a card that boots the Talos
kernel under Debian: SSH key login for `a7s`, a fixed MAC, and the Talos kernel as a
second extlinux label. It runs as root against the image's root partition mounted at
`/mnt/a7s`. `a7s-boot-good-nvmem.conf` is the drop-in that lets DockSeed's
boot-counter service clear the counter without `/dev/mem`.
