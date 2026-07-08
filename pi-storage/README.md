# pi-storage

Power-safe storage provisioning for the Symmatree Raspberry Pi fleet (PocketTerm35
"pipboy", the rekon10 coordinator, the Pi Zero 2 W pods). Implements the btrfs
subvolume layout from the `power-unstable-pi` design pattern (in the private `facts`
vault: `topics/power-unstable-pi.md`), tracked in
[symmatree/tiles #599](https://github.com/symmatree/tiles/issues/599).

## `nvme-btrfs-layout.yml`

Partitions and formats a drive with the shared btrfs layout. **Format only** -- it
does not copy the OS, change `BOOT_ORDER`, or remove the SD, so it is safe to run
from the live SD system while the drive is still blank/secondary.

```
p1  FAT32  bootfs   -> /boot/firmware   (firmware needs FAT; mount RO in normal use)
p2  btrfs  rootfs:
      @          -> /               CoW + checksums + zstd
      @home      -> /home           CoW + checksums + zstd   (precious data)
      @log       -> /var/log        CoW + zstd               (excluded from root snapshots)
      @docker    -> /var/lib/docker nodatacow                (CoW-on-CoW footgun)
      @scratch   -> /scratch        nodatacow                (ephemeral; never snapshotted)
      @snapshots -> /.snapshots
```

Run on the target Pi (destructive to `ssd_device`, default `/dev/nvme0n1`):

```bash
sudo ansible-playbook pi-storage/nvme-btrfs-layout.yml -e ssd_confirm=WIPE
```

- Guarded: refuses without `ssd_confirm=WIPE`, and refuses if the target hosts `/`
  or is mounted.
- Idempotent: does not re-partition or re-`mkfs` an already-formatted drive;
  subvolumes are create-if-absent. To force a clean redo, `wipefs -a` the drive first.
- Builtin modules only (no collection dependency); needs `ansible`, `parted`,
  `dosfstools`, `btrfs-progs`, `e2fsprogs` (`chattr`) on the host.
- Writes the intended `/etc/fstab` to `NVME-FSTAB.txt` on the new root for the later
  cutover; it is a reference artifact and is **not** installed.

### Not done here (later, on-site)

Copying the OS onto `@`, wiring `/boot/firmware` + `cmdline.txt`, and flipping
`BOOT_ORDER` to NVMe-first with the SD kept as rescue. Also deferred: the read-only
base + conditional-overlay + "bake" initramfs mechanism.
