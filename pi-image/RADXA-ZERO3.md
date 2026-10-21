# rampod: Radxa Zero 3W camera pod, plan

A plan for adding **rampod**, a role that does a campod's job on a Radxa Zero 3W (RK3566,
2 GB). The name is Seth's, 2026-10-21, to keep it distinct from the Pi Zero 2 W campods. The
first rampod carries a USB3 camera, the FLIR Blackfly S BFS-U3-244S8M-C. Later rampods are
expected to carry cheaper camera modules (for the vertical ring, since more Pi Zero 2 Ws are
not available), so the camera is a per-unit fact, not a property of the role. Written
2026-10-21, before any board has arrived. Nothing here has run on hardware.

Every fact is labelled. **Read** means a source was opened and the line is cited.
**Measured** means bytes were parsed: the published Armbian images were downloaded,
checksum-verified and inspected offline, and nothing from them was executed. **Inferred** is
reasoning. **Open** is a question nobody has answered yet. Treat the labels as the content.

## The shape, in one paragraph

Take the published Armbian trixie minimal image on the mainline (`current`) kernel and convert
it the way `build-image.sh` converts Raspberry Pi OS. Keep the vendor's loader bytes and
kernel. Re-lay the root into the same btrfs subvolume graph. Put `/boot` on a FAT partition so
the flash-time cloud-init seed works unchanged. Then converge with the same playbooks, behind
a hardware knob. The pod's physical wiring stays as it is, except for the camera's power. A
rampod has one ADXL345, on CS0.

## What the hardware gives us

**Two USB-C ports, one per job.** Read: Radxa's hardware doc
([hardware-interface.md:107](https://github.com/radxa-docs/docs/blob/main/i18n/en/docusaurus-plugin-content-docs/current/zero/zero3/hardware-design/hardware-interface.md))
says "USB-C 1 (USB 2.0 OTG, supports power and OTG) and USB-C 2 (USB 3.0 HOST). The board is
powered via the USB-C 1 port." So one lead to the coordinator's hub carries power and the
gadget link, as on the Zero 2 W.

**Both controllers are DWC3, and the OTG one is high-speed only.** Read, mainline
`arch/arm64/boot/dts/rockchip/`:

| node | mode | PHY | source |
|---|---|---|---|
| `usb@fcc00000` | `otg` | `usb2phy0_otg` only, `maximum-speed = "high-speed"` | `rk356x-base.dtsi:265-273`, `rk3566-base.dtsi:26-31` |
| `usb@fd000000` | `host` | `usb2phy0_host` + `combphy1` USB3 | `rk356x-base.dtsi:281-291` |

Both are enabled in `rk3566-radxa-zero-3.dtsi:495-501`. That corrects
`coordinator/docs/os-and-driver-handoff.md`, which says the OTG port is dwc2-family. The gadget
link stays at 480 Mbit/s, the class the Zero 2 W already runs at. Inferred: the mapping of each
connector to a controller follows from the PHY types, and it has not been checked against the
schematic, because dl.radxa.com refused connections. Inferred: `combphy1` is shared only with
`sata1`, which the board leaves disabled, so USB-C 2 should run at SuperSpeed.

**The header keeps the Pi's physical pins for almost everything.** Read: mainline
`gpio-line-names` (`rk3566-radxa-zero-3.dtsi:108-177`) and Radxa's pinout agree.

| function | Pi Zero 2 W today | Zero 3W | same physical pin |
|---|---|---|---|
| serial console | 8 / 10 | 8 / 10, UART2_M0, **1500000** baud | yes |
| SPI MOSI / MISO / SCLK | 19 / 21 / 23 | 19 / 21 / 23, SPI3_M1 | yes |
| SPI CS0 | 24 | 24, SPI3_CS0_M1 | yes |
| SPI CS1 (second ADXL345 on a campod) | 26 | **26 is not connected** | **no** |
| PPS | 37, GPIO26 | 37, `GPIO1_A4` | yes |

The M1 CS1 signal is `GPIO4_D1` (`rk3568-pinctrl.dtsi:2415-2419`), which is not on the header.
A rampod carries one ADXL345 (Seth, 2026-10-21), on CS0, so CS1 is not used. A second
accelerometer later would need `cs-gpios` on a free header GPIO (inferred).

**Watchdog:** `watchdog@fe600000`, `snps,dw-wdt`, no `status` property, so it is enabled
(read, `rk356x-base.dtsi:1377-1383`). **RTC:** the RK817 PMIC registers an `rk808-rtc` (read).
Open: whether it has battery backup. The schematic was not reachable, and the pods take time
from the coordinator either way.

## Cameras other than the FLIR

Later rampods are expected to carry a cheap camera module; which one is not chosen. The kernel
decides which kinds work. Measured from the two images' `/boot/config-*`:

| | vendor 6.1.115 | current 6.18.44 |
|---|---|---|
| `USB_VIDEO_CLASS` (UVC) | y | m |
| `VIDEO_ROCKCHIP_CIF` (MIPI capture) | y | absent |
| `VIDEO_ROCKCHIP_ISP` (Rockchip ISP) | y | absent |
| `VIDEO_ROCKCHIP_ISP1` (mainline rkisp1) | unset | absent |
| CSI D-PHY | `PHY_ROCKCHIP_CSI2_DPHY` y | `PHY_ROCKCHIP_INNO_CSIDPHY` m |
| `VIDEO_OV5647`, `VIDEO_IMX219` sensor drivers | y, y | m, m |

Measured: the `current` image's `rk3566-radxa-zero-3w.dtb` has no camera, CSI, ISP or VICAP
nodes; its only MIPI D-PHYs are the two DSI ones, both disabled. Inferred: on `current`, a
USB (UVC) module works with what is built, and a MIPI CSI module does not -- the sensor and
D-PHY drivers are there but no capture or ISP driver is, so a MIPI module means either the
vendor kernel or kernel and device-tree work on mainline. A UVC module also needs none of the FLIR's usbfs or udev setup below; it is a V4L2
device.

## The FLIR camera

Read, [FLIR spec page](http://softwareservices.flir.com/BFS-U3-244S8/latest/Model/spec.html):

- Sony IMX540, mono, 5320 x 4600 pixels.
- 15 fps at full resolution, against a 380 MB/s link limit.
- 240 MB of on-camera buffer.
- Power: **8-24 V via GPIO or 5 V via USB, 4.2 W maximum.**

Inferred arithmetic: a full frame is 24.5 MB at Mono8 and 36.7 MB at Mono12p.

**Power is the first constraint.** 4.2 W at 5 V is about 840 mA. Read, from a search snippet of
a mirrored Radxa datasheet only (the PDF did not extract): the USB-C 2 host port is "constrained
to a maximum electrical current of 500mA". A
[forum user](https://forum.radxa.com/t/radxa-zero-3e-increase-500ma-for-usb3/26956) could not
raise it. FLIR's
[ARM note](https://www.teledynevisionsolutions.com/support/support-center/application-note/iis/using-spinnaker-on-arm-and-embedded-systems/)
lists insufficient bus power as a known failure. Inferred: the camera gets its own supply on
VAUX (Hirose pin 1, 8-24 V). That is flight-hardware's call, and so is whether its draw then
comes off the coordinator's hub at all.

**The USB3 port has a reported kernel defect.** Read,
[Armbian forum, Aug-Nov 2025](https://forum.armbian.com/topic/54531-usb3-port-issues-on-radxa-zero-3-armbian-vs-vendor-builds-usb-hub-fails-upside-down-speed-bug/):

- Type-C plug orientation decides whether the link enumerates at 480M or 5000M, on every
  kernel branch.
- An unpowered hub fails on 6.12/6.16 and works on vendor 6.1.
- One user reports that four DWC3 quirk properties fix it on 6.17/6.18. Nothing has been merged
  upstream.

The camera plugs in directly, so the hub half may not apply. The orientation half does.
`lsusb -t` names the speed, so it is the first thing to check on the bench.

**Camera software, as it touches this layer.** Both stacks reach the camera through usbfs via
libusb and need no kernel module (read). The OS-side requirements are the same either way:

- **`usbcore.usbfs_memory_mb`.** The default is 16 (read, `drivers/usb/core/devio.c`). FLIR
  recommends 1000
  ([usbfs note](https://www.teledynevisionsolutions.com/support/support-center/application-note/iis/understanding-usbfs-on-linux/)).
  Inferred: it is a cap, not a reservation; what is actually used is buffer count times frame
  size, so the number belongs on the kernel command line from the image and the buffer count
  belongs to the payload.
- **A udev rule** for vendor `1e10` (Point Grey / FLIR), so an unprivileged or containerised
  reader can open the device.

Which library to use is flight-platform's decision. Its OS consequences:

- **Aravis** is LGPL. Debian trixie ships 0.8.34 (`libaravis-0.8-0`, `gir1.2-aravis-0.8`,
  `aravis-tools-cli`), installable from the same archive as everything else, and Python reaches
  it through GObject introspection (read). The Debian package ships no udev rule; upstream's
  `aravis.rules` matches the USB3 Vision interface class (read).
- **Spinnaker** publishes arm64 builds for Ubuntu 20.04, 22.04 and 24.04 only (read). The
  downloads are login-gated. Its redistribution terms and an arm64 PySpin wheel were not found.
  Inferred: it would live in an Ubuntu-based container rather than on the Debian host.

**What it means for the card.** Inferred: one Mono8 frame per second is 24.5 MB/s of writes,
against 1.6 MB/s measured for today's campod capture and the 19 MB/s import that drove a
Zero 2 W card to 92% utilisation. Whether frames are compressed before they land is the
payload's choice; the write rate is the number this layer has to plan the filesystem around.

## The OS image

**Base: Armbian 26.8.1, trixie, minimal, `current` kernel 6.18.44, 2026-08-12** (read, the
Armbian archive). Measured from that image and the trixie vendor-kernel image: both boot
mainline U-Boot 2025.10, because the board config switches every branch to it.

**Kernel choice: `current`, not `vendor`.**

- The board's device tree is mainline since v6.11 (read).
- The overlays we will write target mainline node names. The vendor tree's names differ, and
  so does its spidev compatible: `rockchip,spidev`, which mainline `spidev.c` does not match
  (read).
- The vendor kernel's console defaults to `ttyFIQ0` (read).
- Against that, the hub half of the USB3 defect is mainline-only (read).

The modules we depend on are present in both. Measured from `/boot/config-*`:

| | vendor 6.1.115 | current 6.18.44 |
|---|---|---|
| `BTRFS_FS` | m | m |
| `PPS_CLIENT_GPIO` | m | m |
| `USB_DWC3`, `_DUAL_ROLE` | y, y | y, y |
| `USB_ETH` (g_ether) | m | m |
| `USB_CONFIGFS_ECM` / `_NCM` | y / y | y / y |
| `USB_XHCI_HCD` | y | y |
| `SPI_ROCKCHIP` / `SPI_SPIDEV` | y / y | y / m |
| `RTC_DRV_DS3232` (covers DS3234) | unset | m |
| `PSI` | y | y |
| `DW_WATCHDOG` | y | y |
| `CMA_SIZE_MBYTES` | 16 | 128 (both images pass `cma=256M`) |

**WiFi:** AIC8800 over SDIO. The `radxa-aic8800` extension installs Radxa's
`aic8800-sdio-dkms` 5.0+git20260123, and both images carry modules built for their kernel
(measured), so it works on `current` too. Inferred: with the kernel frozen in the image, DKMS
is a build-time compile rather than a moving part on the device.

### What the conversion has to do

The Pi conversion is `build-image.sh` plus `assemble-btrfs.sh`. Measured: the Armbian image is
GPT with one ext4 partition at sector 32768, `/boot` a directory on it, and the loader in the
gap before it (idbloader `RKNS` at sector 64, U-Boot FIT at 16384). Measured: the stock U-Boot
contains `fatload` and `ext4load` and the string `btrfs` zero times.

1. **Copy sectors 64 through 32767 verbatim, then write GPT.** `parted mklabel msdos` and the
   fixed MBR id do not carry over. GPT partition GUIDs can be set explicitly, which keeps
   PARTUUIDs identical across cards (inferred, `sgdisk --partition-guid`).
2. **p1: FAT `/boot`, holding `boot.scr`, `armbianEnv.txt`, kernel, initrd, dtbs, overlays and
   the cloud-init seed.** U-Boot can read it (measured). Armbian supports FAT `/boot` itself:
   its kernel package copies instead of symlinking when `/boot` is vfat (read,
   `lib/functions/compilation/kernel-debs.sh:165-180`), and its cloud-init extension forces
   `BOOTFS_TYPE=fat` and reads NoCloud from that partition (read,
   `extensions/cloud-init/cloud-init.sh`). The conversion copies `/boot` with symlinks
   dereferenced. Armbian sizes FAT `/boot` at 512 MiB for two kernel branches (read,
   `partitioning.sh:93-98`).
3. **p2: btrfs, `assemble-btrfs.sh` unchanged.** The initramfs needs btrfs, which is a module
   on both kernels (measured). `armbianEnv.txt` takes `rootdev=PARTUUID=...`,
   `rootfstype=btrfs`, and `rootflags=subvol=@` via `extraargs` (read, `boot-rk35xx.cmd:62`).
4. **Device tree:** our own `.dtso`, compiled at build and listed in `user_overlays=`. It
   carries spi3 on the M1 pins with CS0 and one spidev, `pps-gpio` on `&gpio1 RK_PA4`
   with the falling edge, and `dr_mode = "peripheral"` on `usb@fcc00000` (mainline removed that
   from the board in v6.12, read). No published overlay fits: Armbian's spi3 overlay keeps the
   M0 pins, and Radxa's uses vendor names (read).
5. **Kernel command line,** via `extraargs`: `usbcore.usbfs_memory_mb=`, and the console
   stays `ttyS2,1500000`. No `psi=1`: both kernels are `CONFIG_PSI=y` with
   `CONFIG_PSI_DEFAULT_DISABLED` unset (measured), so `/proc/pressure` is there by default,
   unlike on the Pi kernel.
6. **cloud-init:** install it, since Armbian minimal has none (measured), and disable
   `armbian-firstrun` the way the extension does. Open: whether `Flash-Card.ps1`'s rpi-imager
   path writes the seed onto a non-Pi image's FAT partition, or whether this role needs its own
   seed writer.
7. **Remove what an appliance should not run.** Measured enabled on the current image:
   - `armbian-ramlog` (`/var/log` on a 50 MiB RAM disk) and `armbian-zram-config`;
   - `armbian-hardware-monitor`, `-optimize` and `-led-state`;
   - timers `apt-daily`, `apt-daily-upgrade`, `man-db`, `fstrim`, `logrotate`,
     `dpkg-db-backup`, `e2scrub` and `fake-hwclock-save`;
   - cron jobs `armbian-updates`, `armbian-truncate-logs` and `armbian-check-battery`;
   - the motd scripts.
8. **Credentials and host keys.** Measured: root's password is `1234`, sshd has
   `PermitRootLogin yes`, and the image ships pre-generated SSH host keys dated 2026-08-01,
   which `armbian-firstrun` regenerates. **Disabling firstrun without regenerating host keys
   some other way gives every card the same host key.** The conversion locks root, turns root
   SSH off, deletes the host keys, and generates them on first boot.
9. **Networking:** the image is netplan + systemd-networkd + systemd-resolved, with no
   NetworkManager (measured). The gadget profile, the WiFi keyfile and pod-link's radio control
   (`WirelessEnabled` over D-Bus, `docs/pod-bus.md`) all assume NetworkManager. Inferred: the
   conversion installs NetworkManager and removes netplan, so the network layer matches the Pi
   roles rather than gaining a second implementation.
10. **Packages:** the same `APT_INSTALL` as the campod role. The FLIR's usbfs and udev
    settings (above) are per-camera, so they belong to the converge for the unit that has
    that camera rather than to every rampod image. `btrfs-progs` is already present
    (measured). This role has no
    `raspi-config` cascade to guard, but the purge simulation carries over as is.

### What carries over, and what does not

Carries over: `assemble-btrfs.sh`, `grow-rootfs.sh`, the `/etc/fleet-image` manifest, the
purge-simulate and mark-manual guards, the timer masks, swap off, and passwordless sudo. Of the
21 claim checks, the subvolume, mount, manifest, purge, timer, swap, sudo and grow checks apply
unchanged. The `config.txt`, `cmdline.txt`, `gpu-split` and `/boot/firmware` checks need
Rockchip equivalents: an `armbianEnv.txt`-in-force check, an overlay-applied check against
`/proc/device-tree`, and the UDC check pointed at `fcc00000.usb`.

Does not apply: `gpu_mem`, the CMA arithmetic for picamera2 buffers, the module blacklist's
contents, and tryboot. Inferred: U-Boot gives this board real slot selection, so coordinator#372
is easier here than on the Zero 2 W, not harder.

In the converge (coordinator `host/ansible`), the Pi-shaped parts are in `campod-hardware`,
`bootstrap`, `power-resilience` and the chrony PPS units. rampod is its own role name, but the
gadget network, MAC derivation, chrony client and payload plumbing stay shared code, with the
board difference as a knob rather than a copy. Read: the MAC derivation hashes the hostname
(`provision/README.md`), so it does not depend on the `campod-` prefix.

## Sequence

**Now, with no board (de-risking):**

1. Add `roles/rampod.env` and a Rockchip branch of `build-image.sh` that does steps 1-10,
   and build it in CI on `ubuntu-24.04-arm` next to the Pi roles. Everything up to booting is
   checkable offline: GPT, loader bytes, btrfs in the initramfs, `armbianEnv.txt`, the overlay
   compiling and applying with `fdtoverlay` against the board dtb.
2. Write the `.dtso` and test it with `fdtoverlay` plus `dtc -I dtb` read-back.
3. Extend `probe-claims.py` / `check-claims.py` with the Rockchip checks above.

**When a board arrives:**

1. Boot the stock Armbian image once, on the serial console at 1500000 baud, and record
   `lsusb -t`, `dmesg` and `/proc/meminfo` as a baseline before any of our changes.
2. Boot our image. Check that cloud-init personalises it and the claim checker passes.
3. Bring the gadget link up against the coordinator.
4. Camera on a bench supply: `lsusb -t` speed in both plug orientations, then
   `arv-camera-test` or SpinView for throughput.
5. PPS and the ADXL345 on CS0.
6. Converge with the board knob.

## Decisions that are not this layer's

- **Camera power** (VAUX supply, and the 500 mA limit on USB-C 2): flight-hardware.
- **Aravis or Spinnaker,** and pixel format and compression, which set the write rate:
  flight-platform.
- **Which camera module the later rampods carry, USB or MIPI:** open. The kernel table under
  "Cameras other than the FLIR" is what this layer contributes to it.
- **rampod hostnames and bus topics:** the name is settled; the hostname scheme and topic
  names are not written down yet.
