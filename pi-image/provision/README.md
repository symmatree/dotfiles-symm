# provision -- per-unit identity injection

The built images are generic and secret-free: no login (the vendor `pi` account is
`!`-locked), no SSH host keys, no WiFi. This directory turns one into a specific device
at flash time, touching **only the FAT boot partition** -- so the flashing host needs no
btrfs support, no WSL, and no block-device passthrough (coordinator#96).

| file | what |
|------|------|
| `firstrun.sh.template` | the script rpi-imager drops on the FAT partition; placeholders `__LIKE_THIS__` |
| `fleet.env.example` | fleet-constant values. Copy to `fleet.env` (gitignored) and fill in. **Secrets.** |
| `Flash-Card.ps1` | Windows: render + flash one card |

## Use

Once, per machine:

```powershell
Copy-Item fleet.env.example fleet.env   # then fill it in
```

Get the image from the `build-pi-image` run's artifacts and **extract the zip**. GitHub
wraps every artifact in a zip, so what lands in your browser is
`campod-pi-btrfs-img.zip` (~494 MB) containing `campod-pi-<YYYYMMDD>.img.xz` -- the
artifact name carries no date, the file inside does (`build-image.sh` stamps it). Point
the script at the inner `.img.xz`; rpi-imager reads `.xz` directly but not one that is
still nested in a zip.

Then per card, from an **elevated** PowerShell:

```powershell
Get-Disk | Format-Table Number, FriendlyName, Size, BusType
.\Flash-Card.ps1 -Hostname pod-sw -Disk 2 -Image $HOME\Downloads\campod-pi-20260908.img.xz
```

`-Disk` takes the `Get-Disk` number (or a full `\\.\PhysicalDriveN`). That number is not
stable across sessions and the failure mode is erasing the wrong drive, so the script
re-resolves it, prints the make / size / bus type of the disk it is about to erase, and
makes you retype the number. `-Force` skips the prompt.

### Hostnames

Compass points, nose as north (coordinator#227). Four units today:

    pod-ne   pod-se   pod-sw   pod-nw

The scheme subdivides -- `ne` splits into `nne` + `ene` per
[`rekon10/arm-pods.md`](https://github.com/symmatree/coordinator/blob/main/docs/rekon10/arm-pods.md)
-- so an arm that later carries a second camera does not force renaming the first.

The hostname is the **only** per-unit value in this flow; everything else in `fleet.env`
is fleet-constant. The coordinator repo's `roles/pod` derives each unit's gadget-net MAC
addresses from it at bootstrap (`02:` + five bytes of `sha256("campod-dev:" + hostname)`,
and `campod-host:` for the other end), so nothing here has to carry them -- but it does
mean a hostname change moves the addresses, consistently on both ends.

### Running it from a WSL mount

`\\wsl.localhost\...` is a UNC path, which Windows puts in a remote zone by construction,
so `RemoteSigned` refuses the script. `Unblock-File` does not help -- there is no
mark-of-the-web tag to strip; the zone comes from the path. Bypass it per invocation
rather than copying the script to a local drive, so what you run stays a checkout you can
`git pull`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Flash-Card.ps1 -Hostname pod-sw -Disk 2 -Image $HOME\Downloads\campod-pi-20260908.img.xz
```

The image does not need to sit next to the script -- leave it where the browser put it.

`rpi-imager`'s CLI hardcodes `init_format = systemd` for any local file
(`src/cli.cpp`), so `--first-run-script` reaches the same code path the GUI wizard uses,
with no custom-repository JSON. The GUI cannot do this: it offers no customization for a
locally-selected image (`src/wizard/OSSelectionStep.qml`: *"For custom images,
customization is not supported"*).

## Why the template is not a verbatim Imager script

It was harvested from a real Imager wizard run (a *Raspberry Pi OS (Legacy, 64-bit) Lite*
flash -- the Legacy entries are Bookworm and declare `init_format: systemd`; the current
non-Legacy entries are Trixie and declare `cloudinit-rpi`, which this image cannot
consume). The vendor's `else` fallback branches were then removed. They fire only when
`/usr/lib/raspberrypi-sys-mods/imager_custom` is absent, which on this image it never is
-- and the WiFi fallback is not merely dead but **wrong for Bookworm**: it writes
`/etc/wpa_supplicant/wpa_supplicant.conf`, which NetworkManager (the Bookworm network
stack) does not read. Keeping it would have doubled the number of places the WiFi PSK
appears for no reachable benefit.

## Known difference from a GUI flash

The GUI also appends `cfg80211.ieee80211_regdom=<CC>` to `cmdline.txt`; the CLI path does
not (`imagewriter.cpp` sets it from wizard settings only). Assessed as no practical
impact: `imager_custom set_wlan` is passed the country and calls
`raspi-config nonint do_wifi_country`, which sets the regulatory domain persistently, and
the radio is not used until the post-`firstrun.sh` reboot -- by which point it is set.
The Zero 2 W is 2.4 GHz only, so the channels the default regdom would restrict are not
in play either. **Not tested on hardware.**

## Handling of secrets

`fleet.env` is gitignored and holds the only real secret in the flow: the WiFi PSK. The
SSH key is a **public** key, the hostname is not secret, and with key-only auth the
password hash protects an account that has no reachable password login. Nothing here is
baked into the image, so the image itself stays publishable.

A rendered `firstrun.sh` **does** contain the PSK and the password hash. `Flash-Card.ps1`
writes it to a temp file and deletes it in a `finally` block. If you harvest a fresh one
from the Imager GUI, note that an unmodified Imager script contains the PSK **twice** --
once in the `imager_custom set_wlan` call and again in the `wpa_supplicant.conf` heredoc
in the fallback branch.
