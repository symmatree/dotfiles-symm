# provision -- per-unit identity injection

The built images are generic and secret-free: no login (the vendor `pi` account is
`!`-locked), no SSH host keys, no WiFi. This directory turns one into a specific device
at flash time, touching **only the FAT boot partition** -- so the flashing host needs no
btrfs support, no WSL, and no block-device passthrough (coordinator#96).

| file | what |
|------|------|
| `firstrun.sh.template` | the script rpi-imager drops on the FAT partition; placeholders `__LIKE_THIS__` |
| `pods.env.example` | fleet-constant values. Copy to `pods.env` (gitignored) and fill in. **Secrets.** |
| `Flash-Pod.ps1` | Windows: render + flash one card |

## Use

Once, per machine:

```powershell
Copy-Item pods.env.example pods.env   # then fill it in
```

Then per card, from an **elevated** PowerShell:

```powershell
Get-Disk | Format-Table Number, FriendlyName, Size, BusType   # find the card, CHECK THE SIZE
.\Flash-Pod.ps1 -PodName z-left-rear -Disk \\.\PhysicalDrive2 -Image .\pod-pi-20260906.img.xz
```

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

`pods.env` is gitignored and holds the only real secret in the flow: the WiFi PSK. The
SSH key is a **public** key, the hostname is not secret, and with key-only auth the
password hash protects an account that has no reachable password login. Nothing here is
baked into the image, so the image itself stays publishable.

A rendered `firstrun.sh` **does** contain the PSK and the password hash. `Flash-Pod.ps1`
writes it to a temp file and deletes it in a `finally` block. If you harvest a fresh one
from the Imager GUI, note that an unmodified Imager script contains the PSK **twice** --
once in the `imager_custom set_wlan` call and again in the `wpa_supplicant.conf` heredoc
in the fallback branch.
