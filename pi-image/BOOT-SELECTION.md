# Choosing what the firmware boots, on the hardware we actually have

The flasher (`flasher-init.sh`, `initramfs-flash.gz`, `tryboot.txt`) needs the board to boot
something other than the normal rootfs, exactly once, so p2 can be rewritten underneath.
It was built on `tryboot`. **`tryboot` is inert on the Zero 2 W.** The partition selector
is not, and that is the mechanism to build on.

Measured 2026-09-19 on `campod-se` -- Pi Zero 2 W Rev 1.0, kernel `6.18.50+rpt-rpi-v8`,
firmware `Sep 7 2026`, running `campod-pi-20260918.img` built from `2bc2aec`. Everything in
the tables below was observed on that unit; inferences are labelled as such.

## The result, in one table

| layer | verdict | how it was established |
|---|---|---|
| systemd accepts the reboot argument | **works** | `/run/systemd/reboot-param` appears, 10 bytes |
| kernel notifier sends the tryboot flag | **works** (by inspection) | `drivers/firmware/raspberrypi.c`, no model gate |
| firmware accepts + stores the flag | **works** | `SET_REBOOT_FLAGS` succeeds, read-back `0x00000001` |
| firmware acts on the flag | **does not** | flag clears, `tryboot.txt` unused, normal boot |
| firmware honours a partition number | **works** | `reboot '1'` -> `partition=0x1`, `rsts` `0x20`->`0x21` |

`reboot '0 tryboot'` was issued three times. `/boot/firmware/flash/result.txt` was never
written and the board booted the normal system every time.

## Why `tryboot` fails, and why it is not our bug

Two different kernel paths read the reboot argument, and they split it:

- `drivers/watchdog/bcm2835_wdt.c` parses `"%lu"` off the front and encodes it into the
  `PM_RSTS` partition bits (bits 0, 2, 4, 6, 8, 10). Its own comment says it allows "extra
  arguments separated by spaces after the partition number" -- and then discards them.
  **The word `tryboot` never reaches `PM_RSTS`.**
- `drivers/firmware/raspberrypi.c` registers a reboot notifier at `core_initcall` that does
  `strstr(data, " tryboot")` and, on a match, sends `RPI_FIRMWARE_SET_REBOOT_FLAGS` (tag
  `0x00038064`) over the VideoCore mailbox. There is no model gate on this.

So the flag travels by mailbox, not by register. Querying the firmware directly, read-only:

```
GET_REBOOT_FLAGS (0x30064):  0x80000000 ... 0x80000004  0x00000000   exit=0
GET_THROTTLED    (0x30046):  0x80000000 ... 0x80000004  0x00000000   exit=0   <- known-good control
bogus tag        (0x300ff):  0x00000000 ... 0x00000004  ioctl failed exit=255 <- what unsupported looks like
```

The tag is implemented. Setting it by hand, bypassing our invocation path entirely:

```
before:  GET -> 0x00000000
SET 1:        0x80000000 / 0x80000004  success
after:   GET -> 0x00000001              <- the firmware stores it
```

A plain `reboot` with the flag armed then produced a normal boot, no `result.txt`, and the
flag cleared. **The firmware stores the tryboot flag and does not act on it.** Whether
`start.elf` reads it and ignores it, or whether it is stored somewhere the reset does not
preserve, is not determined from the device -- and does not change the outcome. The kernel
source hints at the latter: *"N.B. The firmware mechanism for storing reboot flags may vary
on different Raspberry Pi models."*

Nothing in this image, these scripts, or the flasher is responsible. Setting the flag by
hand reproduces the failure with our code out of the loop.

## What does work: the partition selector

`reboot '1'` -- selecting the partition the board already boots, so nothing could go wrong:

```
partition   0x00000001     <- 0x00000000 on every other boot
rsts        0x00000021     <- 0x00000020 on every other boot
```

`rsts` bit 0 set is exactly `(partition & BIT(0))` from `__bcm2835_restart()`. The number
travels userspace -> kernel -> `PM_RSTS` -> firmware, and the firmware reports it back in
`/proc/device-tree/chosen/bootloader/partition`.

This matches the documented primitive. `config.txt` docs, on `boot_partition=`:
*"Specifies the partition number for booting unless the partition number was already
specified as a parameter to the `reboot` command."*

So in `reboot '0 tryboot'` the `0` was always working -- it selected partition 0, the
default. Only the word `tryboot` was inert.

**One-shot falls out for free.** `__bcm2835_restart()` clears the partition bits and writes
them fresh on every restart, so an argument-less reboot -- or a power cycle -- returns to
the default. That is the same guarantee tryboot was chosen for, from a mechanism this
silicon implements.

## What other projects do, and why it agrees

Both established A/B-update projects for this board avoid tryboot, which is corroboration
rather than coincidence:

- **[rugix](https://rugix.org/docs/bakery/devices/raspberry-pi/)**: *"For other models than
  Pi 5, Pi 4, Pi 400, and CM 4, you must use the `rpi-uboot` target."* Pi 3 and Pi Zero 2
  are *"in principle supported but untested"*, and the U-Boot flow is flagged experimental
  and cannot update the Pi firmware. It does not claim tryboot on a Zero 2 W.
- **[Nerves](https://github.com/nerves-project/nerves_system_rpi0_2)**: ships
  `cmdline-a.txt` / `cmdline-b.txt` and switches slots by `fat_write(${AUTOBOOT_PART_OFFSET},
  "autoboot.txt")` -- a boot-partition selector written into a dedicated FAT partition, with
  `validate` / `revert` / `prevent-revert` bookkeeping in a U-Boot-format env block used as
  a metadata store. No tryboot.

Both are solving "pick a different boot set at reboot time". That is what the partition
selector does natively here.

## The consequence worth more than the flasher

The flasher writes p2 only, and coordinator#312 records that a coordinated change to *both*
partitions needs a card. That constraint is an artifact of where the running code came from:
booted normally you are on p2 and streaming out of p1; booted into the flasher from p1, p1 is
still the source.

Boot from a **third partition** and both constraints go away. The firmware reads `config.txt`,
kernel and initramfs from that partition, the initramfs runs in RAM, nothing is mounted --
p1 and p2 are both just block devices. Stage the bytes on p3 and either or both can be
written in one pass.

That completes the loop with no card pulls anywhere:

| partition | rewritable from |
|---|---|
| p3 (the flasher) | the normal system -- you are not running from it |
| p1 and p2 | p3 -- you are not running from them |

Packaging the two halves separately is what makes it useful: a `config.txt` change becomes a
small p1 write instead of re-shipping an 800 MB rootfs, and `/etc/fleet-image` can carry the
halves as independently versioned things, which is the vocabulary coordinator#326 already
wants.

Reading a partition at boot does not prevent rewriting it afterwards -- the firmware loads
what it needs into memory and hands off. We already rely on this: `flasher-init.sh` mounts p1
read-write and writes `result.txt` to it, from an initramfs the firmware loaded out of that
same partition.

## Open

- **Does the selected partition need its own `start.elf` / `fixup.dat`**, or does the firmware
  keep reading those from the first partition? Answerable from the boot-flow docs plus one
  build. It is not a design fork: copy them in unconditionally and the cost of being wrong is
  ~40 MB on a 29 GB card.
- **Does the Pi 4B coordinator behave differently?** It has an EEPROM bootloader, which is
  where tryboot is documented to live, so tryboot may well work there. Untested -- it holds
  the FC link, so it is not a casual reboot.

## Dead ends, recorded so they are not re-run

Each of these was chased on hardware and is **not** the problem:

- **`PM_RSTS` compared between a plain reboot and `reboot '0 tryboot'`.** Identical (`0x20`
  both times) -- because the tryboot flag never goes through that register. The comparison
  cannot detect tryboot and proves nothing about it.
- **Missing kernel modules in the flasher initramfs.** It ships busybox and nothing else, but
  `vfat`, `fat`, `nls_cp437`, `nls_ascii` and the `bcm2835` MMC drivers are all in
  `modules.builtin`, and the running system mounts p1 with exactly those built-in defaults
  (`codepage=437,iocharset=ascii`). The flasher could mount p1 if it ever ran.
- **Reading the journal for the shutdown handoff.** journald stops before `systemd-shutdown`
  calls `reboot(2)`, so the messages naming the argument have nowhere to go. Boot `-1` ends
  at `Stopping systemd-journal-flush`. Instrument `/run/systemd/reboot-param` before shutdown
  instead; it is written at invocation and readable for the ~10 s before the box goes down.
- **Boot timing as evidence of whether the flasher ran.** A busybox RAM boot plus the 10 s
  `finish()` sleep fits inside the observed 77-85 s window, so timing does not separate
  "never booted the flasher" from "booted it and it failed early". `result.txt` does.
