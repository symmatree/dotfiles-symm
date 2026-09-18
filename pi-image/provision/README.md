# provision -- per-unit identity injection

The built images are generic and secret-free: no login (the vendor `pi` account is
`!`-locked), no SSH host keys, no WiFi. This directory turns one into a specific device
at flash time, touching **only the FAT boot partition** -- so the flashing host needs no
btrfs support, no WSL, and no block-device passthrough (coordinator#96).

| file | what |
|------|------|
| `user-data.template` | the cloud-config rpi-imager drops on the FAT partition; placeholders `__LIKE_THIS__` |
| `fleet.env.example` | fleet-constant values. Copy to `fleet.env` (gitignored) and fill in. **Secrets.** |
| `Flash-Card.ps1` | Windows: render + flash one card |

## Use

Once, per machine:

```powershell
Copy-Item fleet.env.example fleet.env   # then fill it in
```

Get the image from the `build-pi-image` run's artifacts. GitHub always serves artifacts as
a zip, so what lands is `campod-pi-btrfs-img.zip` -- but it contains a **raw `.img`**, and
rpi-imager reads `.zip` natively, so **point `-Image` at the downloaded zip**. No unwrap.

(The artifact name carries no date; the `.img` inside does, stamped by `build-image.sh`.)

Then per card, from an **elevated** PowerShell:

```powershell
Get-Disk | Format-Table Number, FriendlyName, Size, BusType
.\Flash-Card.ps1 -Hostname campod-sw -Disk 2 -Image $HOME\Downloads\campod-pi-btrfs-img.zip
```

`-Disk` takes the `Get-Disk` number (or a full `\\.\PhysicalDriveN`). That number is not
stable across sessions and the failure mode is erasing the wrong drive, so the script
re-resolves it, prints the make / size / bus type of the disk it is about to erase, and
makes you retype the number. `-Force` skips the prompt.

### Hostnames

Compass points, nose as north (coordinator#227). Four units today:

    campod-ne   campod-se   campod-sw   campod-nw

`campod-`, not `pod-`: a bare "pod" is hopelessly overloaded here -- it is a Kubernetes
noun, it is this repo's ansible role name, and `rekon10/arm-pods.md` also uses it for the
physical arm enclosure that holds one or two of these hosts. Three meanings, none of them
the machine you are naming.

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
powershell -ExecutionPolicy Bypass -File .\Flash-Card.ps1 -Hostname campod-sw -Disk 2 -Image $HOME\Downloads\campod-pi-btrfs-img.zip
```

The image does not need to sit next to the script -- leave it where the browser put it.

`rpi-imager`'s CLI picks the customisation path from which flags are present
(`src/cli.cpp`): `initFormat = (cloudinit-userdata empty && cloudinit-networkconfig empty)
? "systemd" : "cloudinit"`, so `--cloudinit-userdata` selects cloud-init for a locally
selected image with no custom-repository JSON. The GUI cannot do this: it offers no customization for a
locally-selected image (`src/wizard/OSSelectionStep.qml`: *"For custom images,
customization is not supported"*).

## How it works, and the two things it deliberately does not do

The image ships cloud-init with a NoCloud datasource pointed at the boot partition
(`/etc/cloud/cloud.cfg.d/99_raspberry-pi.cfg`: `seedfrom: file:///boot/firmware`), and
`cloud-init-main.service` carries `RequiresMountsFor=/boot/firmware`, so it is ordered
after the PARTUUID-keyed mount. Dropping `user-data` on the FAT partition is the whole
mechanism -- no script, no initramfs fixup, no `cmdline.txt` surgery.

`meta-data` is required for NoCloud to recognise the seed, but there is no template for it
here: rpi-imager writes its own, with an instance-id unique per imaging, and adds
`ds=nocloud;i=<id>` to `cmdline.txt` so the datasource cache survives a reboot.

**No `network-config`.** WiFi is a NetworkManager keyfile written by `write_files`.
cloud-init renders `network-config` through netplan, and that path has a live defect --
`/etc/cloud/cloud.cfg` lists `netplan_nm_patch` in `cloud_final_modules` while
`cc_netplan_nm_patch.py` is not in the package, removed in `25.2-1~bpo13+1+rpt19` with the
reference left behind. That pairing produced the 0-byte `/etc/netplan/90-NM-*.yaml` and the
unrecoverable WiFi in `coordinator/docs/coordinator-network.md`. A keyfile is what `nmtui`
writes when a human fixes one of these by hand, and it never enters netplan.

Because that reference is still dangling, cloud-init reports `degraded` on every boot on
every card. **`cloud-init status` is therefore not a health check here** -- reachability is.

**No `rpi:` key.** `cc_raspberry_pi` would turn `rpi: {interfaces: {spi: true}}` into
`raspi-config nonint do_spi 0`, which edits `/boot/firmware/config.txt` on the running
device and reboots. Device-tree config comes from the image so routine operation never
writes the FAT partition.

## Known difference from a GUI flash

The GUI also appends `cfg80211.ieee80211_regdom=<CC>` to `cmdline.txt`; the CLI path does
not (`imagewriter.cpp` sets it from wizard settings only). `user-data`'s `runcmd` calls
`raspi-config nonint do_wifi_country` instead, which sets the regulatory domain
persistently. The Zero 2 W is 2.4 GHz only, so the channels the default regdom would
restrict are not in play either. **Not tested on hardware.**

## Check the template without a card

A malformed `user-data` is not rejected -- cloud-init skips it -- so the card comes up with
no user and no WiFi and nothing says why. Render it with dummy values and parse it:

```bash
python3 - <<'EOF'
import yaml, re
s = open('pi-image/provision/user-data.template').read()
for k, v in {'HOSTNAME':'x','TIMEZONE':'UTC','KEYMAP':'us','USERNAME':'pi','PW_HASH':'$y$x$y',
             'SSH_PUBKEY':'ssh-ed25519 AAAA x','WIFI_SSID':'s','WIFI_PSK':'p','WIFI_COUNTRY':'US'}.items():
    s = s.replace(f'__{k}__', v)
assert not re.findall(r'__[A-Z_]+__', s), 'unsubstituted placeholder'
d = yaml.safe_load(s)
assert 'network' not in d and 'rpi' not in d
print('ok:', sorted(d))
EOF
```

Placeholders left over are the interesting failure: `Flash-Card.ps1` treats any
`__NAME__` as a missing `fleet.env` key and refuses to flash, so a placeholder-shaped
string anywhere in the template -- including in a comment -- breaks the render.

## Handling of secrets

`fleet.env` is gitignored and holds the only real secret in the flow: the WiFi PSK. The
SSH key is a **public** key, the hostname is not secret, and with key-only auth the
password hash protects an account that has no reachable password login. Nothing here is
baked into the image, so the image itself stays publishable.

A rendered `user-data` **does** contain the PSK and the password hash, each exactly once.
`Flash-Card.ps1` writes it to a temp file and deletes it in a `finally` block.
