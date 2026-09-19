# From a git repo to a card in a Pi

Orientation for whoever owns the disk image next. This is **where things are and why**,
not an argument for the design. [README.md](README.md) is the build mechanics; this is the
shape around it, and the layer boundaries you will otherwise rediscover by breaking them.

The management layer above this -- how config gets deployed and stays deployed once the card
is in the Pi -- is
[`coordinator/docs/deployment-model.md`](https://github.com/symmatree/coordinator/blob/main/docs/deployment-model.md).
This doc ends where that one starts.

## The pipeline

```
git push
  -> .github/workflows/build-pi-image.yaml        matrix: coordinator, campod, pocketterm
     -> pi-image/build-image.sh <role>            on ubuntu-24.04-arm, as root
        -> downloads the pinned vendor image, sha-verified
        -> re-lays its rootfs into btrfs subvolumes (assemble-btrfs.sh)
        -> fixes up the boot config, writes the manifest, regenerates the initramfs
     -> uploads <role>-pi-<date>.img as an artifact          (Actions zips it)
  -> pi-image/provision/Flash-Card.ps1                       on Windows, elevated
     -> renders user-data.template with fleet.env + the hostname
     -> hands both to rpi-imager's CLI, which writes the card
  -> first boot: cloud-init reads the seed off the FAT partition and personalises
  -> convergence: ansible-playbook host/ansible/site.yaml, driven from another machine
```

The image is **generic and secret-free**. Identity arrives at flash time; configuration
arrives at converge time. Nothing in the repo contains a PSK.

### Why convert rather than build from scratch

`build-image.sh` takes the official Raspberry Pi OS Lite image and only re-lays its rootfs.
It does not debootstrap. The vendor's kernel, firmware, `raspberrypi-sys-mods` and
HAT/overlay glue are already correct, so the only new variable is the btrfs-subvolume root.
An mmdebstrap-from-scratch path is sketched in README.md and does not exist.

### The base is a cross-repo pin

`RPIOS_URL` + `RPIOS_SHA256` pin an exact vendor image. **The suite is not local to this
repo**: the campod camera container installs libcamera from the same Pi archive suite, so
`containers/campod-camera`'s `RPI_SUITE` moves in the same window or the two skew.
(coordinator#219 is the revert that established this; coordinator#238 is the Trixie move.)

## The card

MBR, two partitions, fixed disk identifier `0xc0dec0de` so PARTUUIDs are identical across
every card built from one image.

| | | |
|---|---|---|
| **p1** | FAT32, 1536 MiB | firmware, kernels, overlays, `config.txt`, `cmdline.txt`, **both initramfs files**, the cloud-init seed, and ~1.4 GB of staging room for a re-flash image (coordinator#312) |
| **p2** | btrfs, rest of the card | `@ @usr @var @home @data @scratch @snapshots` |

Boot content is ~76 MiB. The rest of p1 is deliberate headroom, and **p1 cannot be resized
in place** — p2 starts immediately after it, so changing `BOOT_MB` costs every device a
full reflash.

`grow-rootfs.service` expands p2 to fill the card on every boot, idempotently. The vendor
has its own first-boot resize, armed by a bare `resize` token in `cmdline.txt`; we strip
that token, because it also randomises the MBR disk identifier and would race ours.

## Which layer owns what

This is the part to read before changing anything.

### The image owns

Everything that must be true **before userspace**, or that should not be rewritten on a
running device.

- **Device tree** — `config.txt`. Per-role via `roles/<role>/config.append.txt` (appended)
  and `CONFIG_REMOVE` in `roles/<role>.env` (vendor lines commented out). Overlays are read
  by the firmware at boot; nothing in userspace substitutes for them.
- **Kernel command line** — `cmdline.txt`, via `CMDLINE_REMOVE`/`CMDLINE_APPEND`.
- **The initramfs** — btrfs must be in it or the root will not mount. Also where
  `/etc/modprobe.d` blacklists have to land, because coldplug happens before the rootfs is up.
- **Partition geometry**, the subvolume graph, and the fstab.
- **Fleet-wide system facts** that should hold however a card was personalised: passwordless
  sudo, swap off, scheduled-maintenance timers masked, packages purged.
- **`/etc/fleet-image`** — the manifest, in the shared vocabulary (coordinator#326).
- **The flasher** — `initramfs-flash.gz`, `tryboot.txt`, `cmdline-flash.txt` on p1. The
  tryboot door into it does not open on a Zero 2 W; the partition selector does.
  [BOOT-SELECTION.md](BOOT-SELECTION.md) has the measurements and the replacement design.

### Provisioning owns (flash time, per unit)

`provision/user-data.template` rendered by `Flash-Card.ps1`. Hostname, the uid-1000 account
with its SSH key and password hash, sshd, and WiFi. Written onto the FAT partition; cloud-init
reads it on first boot from a NoCloud datasource the vendor already points at
`/boot/firmware`.

The only per-unit value is the hostname. Everything else in `fleet.env` is fleet-constant.

### Ansible owns (converge time)

`coordinator/host/ansible`. Module **loading**, the container stack, the checkout, the
gadget network, metrics, power resilience. Driven from another machine over SSH; a freshly
flashed card needs nothing installed first.

The line with the payload side: containers and capture are theirs; kernel, drivers,
filesystem and network plumbing are the image/ansible side.

## Traps

Each of these has cost a card or a debugging session. They are load-bearing, not style.

**`apt-get purge` cascades.** `raspi-config Depends: alsa-utils`, and
`raspberrypi-sys-mods Depends: raspi-config`. Purging one Debian package took provisioning
and the radio with it and produced a card that booted and never joined WiFi. The build now
**simulates the purge** and fails if the removal set is larger than the list, and asserts
afterwards that `raspi-config`, `imager_custom`, `userconf` and `rfkill` are still present.
An absence check cannot notice a missing dependency; both directions are needed.

**Do not `autoremove`.** It took 42 packages beyond the list. Pi-archive packages are marked
manual at build time so a later autoremove cannot take them.

**`update-initramfs -u`, not `-c`.** The vendor image ships a prebuilt `/boot/initrd.img-*`
and `-c` declines to overwrite it — the build would report success while shipping a
btrfs-less initramfs. The build asserts btrfs is actually inside each one.

**btrfs mount options are per-filesystem.** Only the first mounted subvolume's take effect,
and `/` is mounted from the initramfs before fstab is read. `nodatacow` on a later fstab line
is silently discarded; use `chattr +C` on the directory. Same for `compress`.

**`/boot/firmware` is FAT on a card in a vehicle that loses power without warning.** Nothing
writes it during normal operation. A deliberate operator-initiated write on the ground —
staging a re-flash image — is the case that rule protects, not the case it forbids.

**The manifest is three formats at once.** `/etc/fleet-image` is simultaneously valid TOML,
sourceable shell, and a systemd `EnvironmentFile`. No whitespace around `=`, values always
double-quoted, no `$` in a value. The build parses it both ways after writing it.

## The integration test for this code

The image's customisations are fragile relative to the OS under them, and most of them
work by dropping a file somewhere that some *other* tool is supposed to notice. When one
stops being noticed, nothing reports it: a directive sits in `config.txt` with no device
behind it, a blacklist never reaches the initramfs, `@data` mounts somewhere captures are
not written. The failures are remote and silent, which is the whole reason for a check.

```bash
pi-image/run-claims-check.sh campod-se           # probe + check, one step
pi-image/run-claims-check.sh pi@10.0.5.237 -i ~/.ssh/key
```

Run it after changing something you are worried about. The probe is piped over SSH and
read from stdin — nothing is installed on the device, nothing is written, and the JSON is
kept so two runs can be diffed, which is the point before and after a suite bump.

**It is sentinels, not a golden copy.** One purged package proves the purge ran; restating
the whole list proves nothing about the mechanism and turns every deliberate edit into a
failure. What earns a check is a mechanism that is fragile, or that depends on two things
agreeing, and whose failure is silent. Test until fear turns into boredom, then stop.

**Expectations live in `check-claims.py`, written down independently** — not read out of
`build-image.sh`. A test that derives its expectations from the code under test cannot
fail when that code is wrong: drop half of `PURGE` and a checker that greps `PURGE` still
passes. When the build changes and the expectations do not, the run fails and a person
decides whether the change was intended. That is the signal, the same as any unit test.

Two consequences worth knowing when reading a report. A card older than a claim will fail
it — that is "this card predates this expectation", and the image's gitsha is in the
header so you can see it. And `UNKNOWN` never counts as a failure: an unprivileged probe
cannot stat inside `/etc/sudoers.d`, and reporting that as "absent" would be a check that
lies.

Ideally this would run on merge against a VM or a spare Pi with automated flashing. That
does not exist yet, so it is run by hand.

## Testing without hardware

Most of this is checkable offline, and the habit is worth keeping.

- `test-config-remove.sh` — the `config.txt` filter, pure text, runs anywhere.
- `test-assemble.sh` — the subvolume assembly, needs a btrfs kernel and root.
  `verify-in-vm.sh` runs it in a throwaway KVM guest.
- The vendor image itself answers most "does Trixie still ship X" questions in seconds:
  download it, split the partitions, read the ext4 with `debugfs` and the FAT with a small
  reader. No root, no loop devices. The vendor also publishes an SBOM next to each image.
- The `.deb` control files answer "what does this package depend on", which is the question
  behind the worst bug in this list.

## What has never been exercised

Parts of this ship on every card and have never run on hardware. What they are, how to
exercise each one, and what each outcome means live in
[coordinator#339](https://github.com/symmatree/coordinator/issues/339), so the list burns
down in the tracker rather than by editing this file.

Read it before assuming something here works because it is in the image.

The first item on that list has been run: **tryboot does not work on the Zero 2 W**, the
firmware stores the flag and ignores it, and the failure is not ours —
[BOOT-SELECTION.md](BOOT-SELECTION.md). The partition selector on the same board is
honoured, which is both the way in for the flasher and the route to rewriting p1 and p2
in one pass.
