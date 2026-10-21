# rampod: Radxa Zero 3W camera pod, plan

A plan for adding **rampod**, a role that does a campod's job on a Radxa Zero 3W (RK3566,
2 GB). The name is Seth's, 2026-10-21, to keep it distinct from the Pi Zero 2 W campods. The
first rampod carries a USB3 camera, the FLIR Blackfly S BFS-U3-244S8M-C. Later rampods carry
Pi-style MIPI ribbon-cable modules (most likely Arducam IMX708; Seth has several kinds and may
try more than one), for the vertical ring, since more Pi Zero 2 Ws are not available. So the
camera is a per-unit fact, not a property of the role. Written 2026-10-21, before any board
has arrived. Nothing here has run on hardware.

Every fact is labelled. **Read** means a source was opened and the line is cited.
**Measured** means bytes were parsed: the published Armbian images were downloaded,
checksum-verified and inspected offline, and nothing from them was executed. **Inferred** is
reasoning. **Open** is a question nobody has answered yet. Treat the labels as the content.

## The shape, in one paragraph

Take the published Armbian trixie minimal image on the **vendor** kernel (Rockchip's 6.1 BSP)
and convert it the way `build-image.sh` converts Raspberry Pi OS. Keep the vendor's loader
bytes. Re-lay the root into the same btrfs subvolume graph. Put `/boot` on a FAT partition so
the flash-time cloud-init seed works unchanged. Then converge with the same playbooks, behind
a hardware knob. The requirements are the gadget network, PPS and the camera; the rest is
settled as it comes up. The pod's physical wiring stays as it is, except for the FLIR's
power. A rampod has one ADXL345, on CS0.

## Kernel: vendor

Seth, 2026-10-21: the vendor kernel, at least until it causes a problem. The reason is the
cameras. Measured from the two published images' `/boot/config-*`:

| | vendor 6.1.115 | current (mainline) 6.18.44 |
|---|---|---|
| `VIDEO_ROCKCHIP_CIF` (MIPI capture) | y | absent |
| `VIDEO_ROCKCHIP_ISP` (Rockchip ISP) | y | absent |
| `VIDEO_IMX708` | **not set** | absent |
| `VIDEO_IMX219`, `VIDEO_OV5647` | y, y | m, m |
| `USB_VIDEO_CLASS` (UVC) | y | m |

Mainline has sensor drivers but no capture or ISP driver for this chip, so no MIPI module
works on it. The vendor kernel has both, and the board's camera pipeline is in its device tree
(below). It also avoids the mainline-only half of the USB3 defect described under the FLIR.
The cost: it is Rockchip's 6.1 tree, so its device-tree node names and spidev compatible
(`rockchip,spidev`) are vendor-shaped, and upstream fixes reach it later (inferred).

The other things this layer depends on are built in vendor 6.1.115 (measured):

| option | vendor 6.1.115 |
|---|---|
| `BTRFS_FS` | m |
| `PPS_CLIENT_GPIO` | m |
| `USB_DWC3`, `_DUAL_ROLE` | y, y |
| `USB_ETH` (g_ether) | m |
| `USB_CONFIGFS_ECM` / `_NCM` | y / y |
| `USB_XHCI_HCD` | y |
| `SPI_ROCKCHIP` / `SPI_SPIDEV` | y / y |
| `PSI` (`PSI_DEFAULT_DISABLED` unset) | y |
| `DW_WATCHDOG` | y |
| `CMA_SIZE_MBYTES` | 16 (`armbianEnv.txt` passes `cma=256M`) |

**IMX708 needs a build.** Read: the driver (`drivers/media/i2c/imx708.c`, plus the `dw9807`
focus-motor regulator) was merged into Armbian's vendor branch `rk-6.1-rkr5.1` on 2026-03-25
([armbian/linux-rockchip#457](https://github.com/armbian/linux-rockchip/pull/457)). Measured:
the published image has it `# CONFIG_VIDEO_IMX708 is not set`. So the image has to carry
either a kernel built with it on, or that one module built against the image's kernel. Open:
which; both happen in CI.

## What the hardware gives us

**Two USB-C ports, one per job.** Read: Radxa's hardware doc
([hardware-interface.md:107](https://github.com/radxa-docs/docs/blob/main/i18n/en/docusaurus-plugin-content-docs/current/zero/zero3/hardware-design/hardware-interface.md))
says "USB-C 1 (USB 2.0 OTG, supports power and OTG) and USB-C 2 (USB 3.0 HOST). The board is
powered via the USB-C 1 port." So one lead to the coordinator's hub carries power and the
gadget link, as on the Zero 2 W.

**Both controllers are DWC3, and the OTG one is high-speed only.** Measured, the vendor
image's `rk3566-radxa-zero3.dtb`:

| node | `dr_mode` | PHYs | other |
|---|---|---|---|
| `/usbdrd/usb@fcc00000` | `otg` | `usb2-phy` | `maximum-speed = "high-speed"`, `extcon` set |
| `/usbhost/usb@fd000000` | `host` | `usb2-phy`, `usb3-phy` | |

Mainline's tree agrees (read, `rk356x-base.dtsi:265-291`, `rk3566-base.dtsi:26-31`). That
corrects `coordinator/docs/os-and-driver-handoff.md`, which says the OTG port is dwc2-family.
The gadget link stays at 480 Mbit/s, the class the Zero 2 W already runs at. Inferred: the
mapping of each connector to a controller follows from the PHY types; it has not been checked
against the schematic, because dl.radxa.com refused connections.

**The header keeps the Pi's physical pins.** Read: mainline `gpio-line-names`
(`rk3566-radxa-zero-3.dtsi:108-177`) and Radxa's pinout agree.

| function | Pi Zero 2 W today | Zero 3W | same physical pin |
|---|---|---|---|
| serial console | 8 / 10 | 8 / 10, UART2_M0, **1500000** baud | yes |
| SPI MOSI / MISO / SCLK | 19 / 21 / 23 | 19 / 21 / 23, SPI3_M1 | yes |
| SPI CS0 (the ADXL345) | 24 | 24, SPI3_CS0_M1 | yes |
| SPI CS1 | 26 | **26 is not connected** | **no** |
| PPS | 37, GPIO26 | 37, `GPIO1_A4` | yes |

A rampod carries one ADXL345 (Seth, 2026-10-21), on CS0, so the missing CS1 is not used.

**Camera connector.** Read, the same Radxa doc: "one 4-lane MIPI CSI interface with a 22-Pin,
0.5mm pitch FPC connector", with the camera's I2C on `I2C2_M1`. The Arducam / Pi Camera
modules have the 15-pin connector, so they need a 15-to-22-pin cable of the kind sold for the
Pi Zero. That the pinout is Pi-compatible comes only from a camera vendor's wiki seen through a
search summary, not from Radxa (unverified).

**Watchdog:** `watchdog@fe600000`, `snps,dw-wdt`, no `status` property in the vendor dtb, so
it is enabled (measured). **RTC:** the RK817 PMIC registers an `rk808-rtc` (read). The pods
have no DS3234.

## The MIPI cameras

Measured, the vendor dtb: the camera pipeline is present and disabled, for an overlay to turn
on -- `mipi-csi2`, `csi2-dphy0..2`, `rkcif@fdfe0000` with `rkcif_mipi_lvds`, and
`rkisp@fdff0000` with `rkisp-vir0/1`.

Measured, the vendor image's overlays: `radxa-zero3-rpi-camera-v1.3` (OV5647) and
`radxa-zero3-rpi-camera-v2` (IMX219) ship for this board. There is none for IMX708 on this
board; `recomputer-rk3576-devkit-cam0-rpi-v3` and the rk3588 equivalents ("Raspberry Pi Camera
v3 (IMX708) pipeline") ship for other Rockchip boards. Inferred: an IMX708 overlay for this
board is the zero3 IMX219 overlay with the sensor node taken from one of those.

Read, a [Radxa forum thread](https://forum.radxa.com/t/imx290-imx519-imx708-imx477-on-zero-3w/31353),
Aug-Sep 2026, on a Zero 3W:

- IMX708 at 1920x1080 / 60 fps and 1536x864 / 120 fps; "max window size of 4080x2568".
- Autofocus is reported both working and missing in the same post.
- IMX519 and IMX477 also reported working; IMX290 working after a cable change.
- Image quality comes from Rockchip's ISP tuning (`rkaiq` IQ files, one per sensor); the
  poster's were made for the Rock 5B/5C.

Inferred: none of this is libcamera / picamera2, which today's campod `capture.py` is built
on, so the capture code does not carry over as is. The replacement is flight-platform's.

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
  kernel branch, vendor included.
- An unpowered hub fails on mainline 6.12/6.16 and works on vendor 6.1.

The camera plugs in directly. The orientation half applies; `lsusb -t` names the speed, so it
is the first thing to check on the bench.

**Camera software, as it touches this layer.** Both stacks reach the camera through usbfs via
libusb and need no kernel module (read). The OS-side requirements are the same either way:

- **`usbcore.usbfs_memory_mb`.** The default is 16 (read, `drivers/usb/core/devio.c`). FLIR
  recommends 1000
  ([usbfs note](https://www.teledynevisionsolutions.com/support/support-center/application-note/iis/understanding-usbfs-on-linux/)).
  Inferred: it is a cap, not a reservation; what is actually used is buffer count times frame
  size.
- **A udev rule** for vendor `1e10` (Point Grey / FLIR), so an unprivileged or containerised
  reader can open the device.

Both are per-camera, so they belong to the converge for the unit that has the FLIR, not to
every rampod image.

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

**Base: Armbian 26.8.1, trixie, minimal, vendor kernel 6.1.115-vendor-rk35xx** (measured:
`/etc/armbian-release` `VERSION=26.8.1`, `BOARD=radxa-zero3`; `/boot` dated 2026-08-12). It
boots mainline U-Boot 2025.10 (measured, the loader's version string), as the `current` image
does, because the board config switches every branch to it. The device tree is
`rockchip/rk3566-radxa-zero3.dtb` (measured, `fdtfile=` in `armbianEnv.txt`).

**WiFi:** AIC8800 over SDIO. The `radxa-aic8800` extension installs Radxa's
`aic8800-sdio-dkms` 5.0+git20260123, and the image carries modules built for its kernel
(measured). Inferred: with the kernel frozen in the image, DKMS is a build-time compile rather
than a moving part on the device.

### What the conversion has to do

The Pi conversion is `build-image.sh` plus `assemble-btrfs.sh`. Measured: the Armbian image is
GPT with one ext4 partition (`rootfs`) at sector 32768, `/boot` a directory on it, and the
loader in the gap before it (idbloader `RKNS` at sector 64, U-Boot FIT at 16384). Measured: the
stock U-Boot contains `fatload` and `ext4load` and the string `btrfs` zero times.

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
   (measured). `armbianEnv.txt` takes `rootdev=PARTUUID=...`, `rootfstype=btrfs`, and
   `rootflags=subvol=@` via `extraargs` (measured, the image's `boot.cmd:40`).
4. **Device tree, through `armbianEnv.txt`.** Measured, the image's `boot.cmd:50-62`:
   `overlays=` loads `dtb/rockchip/overlay/<prefix>-<name>.dtbo` and falls back to
   `<name>.dtbo`; `user_overlays=` loads `overlay-user/<name>.dtbo`. So:
   - **SPI:** the shipped `rk3568-spi3-m1-cs0-spidev` (measured: its metadata lists
     `radxa,zero3`, pins `GPIO4_C2`/`C3`/`C5`/`C6`, and a `rockchip,spidev` node on CS0).
   - **Camera:** a per-unit overlay. The shipped `radxa-zero3-rpi-camera-v2` /
     `-v1.3` for IMX219 / OV5647; our own for IMX708.
   - **Our own `.dtso`** in `user_overlays=`: `pps-gpio` on `GPIO1_A4` with the falling edge,
     and `dr_mode = "peripheral"` on `usb@fcc00000`. Inferred: the vendor dtb's `otg` with
     `extcon` would leave the role to cable detection, and the Pi campods pin it to
     peripheral.
5. **Kernel command line,** via `extraargs`: root, and `cma=256M` kept. No `psi=1`: PSI is on
   by default (measured). Console: `boot.cmd` sets `console=ttyS2,1500000` (measured,
   line 29), but the dtb has `fiq-debugger` enabled and `serial@fe660000` (UART2) disabled
   (measured). Open: which device carries the console on this kernel -- `ttyFIQ0` or `ttyS2`;
   the image also ships `rk3568-uart2-m0` and `rk3568-fiq-debugger-uart2m0` overlays. Settled
   on the bench.
6. **cloud-init:** install it, since the image has none (measured), and disable
   `armbian-firstrun` the way the extension does. Open: whether `Flash-Card.ps1`'s rpi-imager
   path writes the seed onto a non-Pi image's FAT partition, or whether this role needs its own
   seed writer.
7. **Remove what an appliance should not run.** Measured enabled on the vendor image:
   - `armbian-ramlog` (`/var/log` on a RAM disk) and `armbian-zram-config`;
   - `armbian-hardware-monitor`, `-optimize`, `-led-state` and `-resize-filesystem`;
   - timers `apt-daily`, `apt-daily-upgrade`, `man-db`, `fstrim`, `logrotate`,
     `dpkg-db-backup`, `e2scrub_all` and `fake-hwclock-save`;
   - cron jobs `armbian-updates`, `armbian-truncate-logs` and `armbian-check-battery`;
   - the motd scripts (measured on the `current` image).
8. **Credentials and host keys.** Measured: root has a password (`1234` on the `current`
   image; the vendor image's hash is present and was not cracked), sshd has
   `PermitRootLogin yes`, and the image ships six pre-generated SSH host key files, which
   `armbian-firstrun` regenerates. **Disabling firstrun without regenerating host keys some
   other way gives every card the same host key.** The conversion locks root, turns root SSH
   off, deletes the host keys, and generates them on first boot.
9. **Networking:** the image is netplan (`10-dhcp-all-interfaces.yaml`) + systemd-networkd,
   with no NetworkManager (measured). The gadget profile, the WiFi keyfile and pod-link's radio
   control (`WirelessEnabled` over D-Bus, `docs/pod-bus.md`) all assume NetworkManager.
   Inferred: the conversion installs NetworkManager and removes netplan, so the network layer
   matches the Pi roles rather than gaining a second implementation.
10. **Packages:** the same `APT_INSTALL` as the campod role. `btrfs-progs` is already present
    (measured). This role has no `raspi-config` cascade to guard, but the purge simulation
    carries over as is.
11. **IMX708:** the kernel or module build above.

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

1. Add `roles/rampod.env` and a Rockchip branch of `build-image.sh` that does steps 1-11,
   and build it in CI on `ubuntu-24.04-arm` next to the Pi roles. Everything up to booting is
   checkable offline: GPT, loader bytes, btrfs in the initramfs, `armbianEnv.txt`, the IMX708
   module present, the overlays applying with `fdtoverlay` against `rk3566-radxa-zero3.dtb`.
2. Write the `.dtso` and the IMX708 overlay, and test them with `fdtoverlay` plus `dtc -I dtb`
   read-back.
3. Extend `probe-claims.py` / `check-claims.py` with the Rockchip checks above.

**When a board arrives,** in the order of the requirements:

1. Boot the stock Armbian vendor image once on the serial console at 1500000 baud, and record
   which console device answers, `lsusb -t`, `dmesg` and `/proc/meminfo` as a baseline before
   any of our changes.
2. Boot our image. Check that cloud-init personalises it and the claim checker passes.
3. Bring the gadget link up against the coordinator.
4. PPS on pin 37, then the ADXL345 on CS0.
5. Camera: a MIPI module on its overlay (`media-ctl -p`, a raw frame through `rkcif`); the
   FLIR on a bench supply (`lsusb -t` speed in both plug orientations, then `arv-camera-test`
   or SpinView for throughput).
6. Converge with the board knob.

## Decisions that are not this layer's

- **FLIR power** (VAUX supply, and the 500 mA limit on USB-C 2): flight-hardware.
- **Capture software** for both camera kinds (Aravis or Spinnaker for the FLIR; the Rockchip
  ISP path for the MIPI modules), and pixel format and compression, which set the write rate:
  flight-platform.
- **Which MIPI modules the later rampods carry:** Seth, by trying them. Each one is a sensor
  driver that the vendor kernel builds or not (the table above) plus an overlay.
- **rampod hostnames and bus topics:** the name is settled; the hostname scheme and topic
  names are not written down yet.
