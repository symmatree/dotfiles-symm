#!/usr/bin/env python3
"""The integration test for the imaging code: did the patches' MECHANISMS work?

    pi-image/run-claims-check.sh <host>          # probe + check in one step
    pi-image/check-claims.py <host>.json         # check an existing probe

Run it after changing something you are worried about. Ideally this would run on
merge against a VM or a spare Pi with automated flashing; until that exists it is
run by hand, which is still better than finding out on the vehicle.

## What it tests, and what it deliberately does not

Not a health check. Load, free space, failed units and journal state are a
different question about a different subject.

Not a golden copy of the configuration either. Restating every purged package
proves nothing about the purge and turns every deliberate edit into a failure.
One sentinel is enough to show the mechanism ran.

What earns a check here is a mechanism that is **fragile**, or that depends on
**two things agreeing**, and whose failure is **remote and silent** -- a file
dropped in a directory that some other tool is supposed to notice, where nothing
reports the omission and the card just quietly behaves differently. Test until
fear turns into boredom, then stop.

Expectations below are written down HERE, independently, in the form we believe
they ought to be. They are not read out of `build-image.sh`: a test that derives
its expectations from the code under test cannot fail when that code is wrong.
If someone drops packages from PURGE, the sentinel below still says avahi-daemon
must be gone, and the run fails until a human decides the change was intended.
That drift is the signal, not a defect -- same as any unit test.
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

PASS, FAIL, UNKNOWN, SKIP = "PASS", "FAIL", "UNKNOWN", "SKIP"

# Roles whose claims differ. Only what this file needs -- not a copy of the role.
ROLE_EXPECT = {
    "campod": {
        "data_mount": "/var/lib/campod",
        "cma_kb": 131072,          # dtoverlay=cma,cma-128
        "want_nodes": ["spidev", "udc"],
        "want_absent": ["drm_cards", "sound_cards"],
        "console_is_uart": True,   # serial console re-appended LAST
        "blacklisted": ["drm", "snd_bcm2835"],
    },
    "coordinator": {
        "data_mount": "/var/lib/coordinator",
        "cma_kb": None,
        "want_nodes": ["i2c_bus"],  # the BUS is the image's half; i2c-dev is ansible's
        "want_absent": [],
        "console_is_uart": False,   # the FC owns that UART; no serial console at all
        "blacklisted": [],
    },
    "pocketterm": {
        "data_mount": "/var/lib/store",
        "cma_kb": None,
        "want_nodes": [],
        "want_absent": [],
        "console_is_uart": False,
        "blacklisted": [],
    },
}

# One package that must be gone, and the ones that must have survived. The
# survivors are the point: raspi-config Depends alsa-utils and
# raspberrypi-sys-mods Depends raspi-config, so an over-broad purge takes
# provisioning and the radio with it and produces a card that boots and never
# joins WiFi. An absence check cannot see that; both directions are needed.
PURGE_SENTINEL = "avahi-daemon"
PURGE_SURVIVORS = ["raspi-config", "raspberrypi-sys-mods", "userconf-pi", "rfkill"]

# One masked timer is enough to show `systemctl mask` took effect in the chroot.
MASK_SENTINEL = "apt-daily.timer"

SUBVOLS = ["@", "@usr", "@var", "@home", "@data", "@scratch", "@snapshots"]

DISK_ID = "c0dec0de"  # fixed MBR identifier, so PARTUUIDs match across cards


class Checks:
    def __init__(self, obs):
        self.obs = obs
        self.rows = []
        self.role = obs["fleet_image"]["keys"].get("FLEET_ROLE")
        self.expect = ROLE_EXPECT.get(self.role, {})
        self.mounts = {m["target"]: m for m in obs["mounts"]}
        self.nodes = obs["device_nodes"]

    def add(self, status, name, why, detail):
        self.rows.append((status, name, why, detail))

    def check(self, name, why, fn):
        """fn returns (ok, detail), or (None, detail) when it cannot tell."""
        try:
            ok, detail = fn()
        except Exception as exc:  # noqa: BLE001 -- a broken check is a finding
            self.add(UNKNOWN, name, why, f"check raised: {exc}")
            return
        if ok is None:
            self.add(UNKNOWN, name, why, detail)
        else:
            self.add(PASS if ok else FAIL, name, why, detail)

    # -- the checks ---------------------------------------------------------

    def run(self):
        o, e = self.obs, self.expect

        self.check(
            "purge/mechanism",
            "an over-broad purge is silent until something needs the package",
            lambda: (PURGE_SENTINEL not in o["packages_installed"],
                     f"{PURGE_SENTINEL}: "
                     + ("absent" if PURGE_SENTINEL not in o["packages_installed"]
                        else "STILL INSTALLED")))

        missing = [p for p in PURGE_SURVIVORS if p not in o["packages_installed"]]
        self.check(
            "purge/cascade-guard",
            "purging one package can take provisioning and the radio with it",
            lambda: (not missing,
                     "all survivors present" if not missing
                     else f"a dependency took: {missing}"))

        self.check(
            "config.txt/in-force",
            "appended lines land at the END of the vendor file; if that file ends "
            "inside a [cm4]/[cm5] section every one of them is silently inert",
            self._config_in_force)

        if e.get("cma_kb"):
            self.check(
                "config.txt/removal-took",
                "CONFIG_REMOVE comments out a vendor line by glob; a suite bump can "
                "change that line's text and the glob then matches nothing",
                lambda: (o["cma_total_kb"] == e["cma_kb"],
                         f"CmaTotal {o['cma_total_kb']} kB, expected {e['cma_kb']} "
                         "(256 MB would mean vc4-kms-v3d is still loaded)"))

        for key in e.get("want_absent", []):
            self.check(
                f"config.txt/{key}-gone",
                "the removal is only real if the driver stopped binding",
                lambda key=key: self._absent(key))

        for mod in e.get("blacklisted", []):
            self.check(
                f"blacklist/{mod}",
                "modprobe.d has to be copied INTO the initramfs; coldplug happens "
                "before the rootfs is up, so a miss here loads the module anyway",
                lambda mod=mod: (mod not in o["modules_loaded"],
                                 "not loaded" if mod not in o["modules_loaded"]
                                 else "LOADED"))

        if e.get("console_is_uart"):
            self.check(
                "cmdline/console-order",
                "/dev/console is the LAST console= token; get the order wrong and "
                "systemd's output goes to a monitor nobody has",
                self._console_order)

        self.check(
            "subvols/graph",
            "a subvolume that fails to mount leaves its mountpoint working but "
            "backed by the wrong subvolume",
            self._subvols)

        self.check(
            "subvols/@data-lockstep",
            "DATA_MOUNT must equal coord_state_root in the coordinator repo; if "
            "they diverge captures land on @var with no error and no warning",
            self._data_mount)

        self.check(
            "mount/usr-ro",
            "the write-frugality pillar; only meaningful on a box that has not "
            "been converged since boot, since a converge remounts it rw",
            self._usr_ro)

        self.check(
            "mount/nodatacow",
            "nodatacow CANNOT be a per-subvolume mount option -- it has to be an "
            "inode flag, and a fstab line saying otherwise is silently discarded",
            self._nodatacow)

        self.check(
            "mount/boot-firmware",
            "no nofail: that drops the Before=local-fs.target ordering and lets "
            "first-boot provisioning race an empty mountpoint",
            self._boot_firmware)

        self.check(
            "manifest/three-formats",
            "/etc/fleet-image must parse as TOML, as shell, and as an "
            "EnvironmentFile; one space around an = breaks sourcing only",
            lambda: (bool(o["fleet_image"].get("parses_toml")
                          and o["fleet_image"].get("shell_safe")),
                     f"toml={o['fleet_image'].get('parses_toml')} "
                     f"shell_safe={o['fleet_image'].get('shell_safe')}"))

        self.check(
            "swap/off",
            "rpi-swap's drop-in directory is upstream's; a rename re-enables swap "
            "onto the SD card silently",
            lambda: (not [x for x in o["swaps"][1:] if x.strip()],
                     "no swap active" if not [x for x in o["swaps"][1:] if x.strip()]
                     else f"swap ACTIVE: {o['swaps'][1:]}"))

        self.check(
            "timers/masked",
            "masking happens in the chroot; if it silently did not take, timers "
            "with Persistent=true catch up every missed window at once",
            lambda: (o["unit_states"].get(MASK_SENTINEL) in ("masked", "absent"),
                     f"{MASK_SENTINEL}: {o['unit_states'].get(MASK_SENTINEL, 'absent')}"))

        self.check(
            "sudo/nopasswd",
            "sudo validates the OWNERSHIP of a symlink's target, so this must be a "
            "copy; without it non-interactive provisioning hangs at a prompt",
            self._sudoers)

        self.check(
            "disk/partuuid-stable",
            "the fixed MBR id is what makes PARTUUIDs identical across cards; the "
            "vendor's own first-boot resize randomises it",
            self._partuuid)

        self.check(
            "disk/grow-rootfs",
            "p2 is expanded on every boot; if it stops the card silently stays the "
            "size it was built and nothing says so until it fills",
            self._grew)

        return self.rows

    # -- individual predicates ----------------------------------------------

    def _config_in_force(self):
        """Proven by a node that only the appended block can have produced."""
        want = self.expect.get("want_nodes", [])
        if not want:
            return None, "this role appends nothing with an observable node"
        got = {}
        for key in want:
            if key == "i2c_bus":
                got[key] = self.nodes.get("i2c_buses") or []
            elif key == "drm_cards":
                got[key] = self._cards("drm")
            else:
                got[key] = self.nodes.get(key) or []
        missing = [k for k, v in got.items() if not v]
        return (not missing,
                f"{got}" if not missing else f"nothing appeared for {missing}")

    def _cards(self, key):
        return [c for c in self.nodes.get(key, []) if re.match(r"^card\d+$", c)]

    def _absent(self, key):
        got = self._cards("drm" if key == "drm_cards" else "sound")
        return not got, f"{key}: {got or 'none'}"

    def _console_order(self):
        consoles = [t for t in self.obs["cmdline"].split() if t.startswith("console=")]
        if not consoles:
            return False, "no console= token at all"
        dev = consoles[-1].partition("console=")[2].split(",")[0]
        aliases = self.obs.get("dt_aliases", {})
        resolved = aliases.get(dev, dev)
        uart = resolved.startswith("ttyAMA") or resolved.startswith("ttyS")
        return uart, f"last console= is {consoles[-1]} (-> {resolved})"

    def _subvols(self):
        seen = {m["subvol_root"].lstrip("/") for m in self.obs["mounts"]
                if m["fstype"] == "btrfs"}
        missing = [s for s in SUBVOLS if s not in seen]
        return not missing, "all seven mounted" if not missing else f"missing {missing}"

    def _data_mount(self):
        want = self.expect.get("data_mount")
        if not want:
            return None, "no DATA_MOUNT known for this role"
        m = self.mounts.get(want)
        if not m:
            return False, f"{want} is not a mount point at all"
        ok = m["subvol_root"].endswith("@data")
        return ok, f"{want} <- {m['subvol_root']}"

    def _usr_ro(self):
        m = self.mounts.get("/usr")
        if not m:
            return False, "/usr is not a separate mount"
        ro = "ro" in m["vfs_options"].split(",")
        return ro, f"/usr {m['vfs_options']}"

    def _nodatacow(self):
        bad, unknown = [], []
        for path, attrs in self.obs["nodatacow"].items():
            if attrs == "unknown":
                unknown.append(path)
            elif not attrs or "C" not in attrs:
                bad.append(path)
        if unknown and not bad:
            return None, f"could not read {unknown} (run the probe with sudo)"
        return not bad, "both +C" if not bad else f"missing +C on {bad}"

    def _boot_firmware(self):
        m = self.mounts.get("/boot/firmware")
        if not m:
            return False, "not mounted"
        rw = "rw" in m["vfs_options"].split(",")
        return rw and m["fstype"] == "vfat", f"{m['fstype']} {m['vfs_options']}"

    def _sudoers(self):
        s = self.obs["sudoers_nopasswd"]
        if s.get("present") == "unknown":
            return None, "could not stat it (run the probe with sudo)"
        ok = s.get("present") and s.get("mode") == "0o440" and s.get("uid") == 0
        return ok, f"{s}"

    def _partuuid(self):
        root = [t for t in self.obs["cmdline"].split() if t.startswith("root=PARTUUID=")]
        if not root:
            return None, "no root=PARTUUID= on the command line"
        uuid = root[0].split("=", 2)[2]
        return uuid.startswith(DISK_ID), f"root={uuid}"

    def _grew(self):
        sizes = self.obs.get("block", {}).get("sizes_512b", {})
        disk = next((n for n in sizes if re.match(r"^(mmcblk\d+|nvme\d+n\d+)$", n)), None)
        if not disk:
            return None, "no whole-disk device found"
        part = f"{disk}p2"
        if part not in sizes:
            return None, f"{part} not found"
        used = sizes[part] / sizes[disk]
        return used > 0.90, (f"p2 is {sizes[part] * 512 // 2**30} GiB of "
                             f"{sizes[disk] * 512 // 2**30} GiB ({used:.0%})")


def render(rows, obs):
    width = max(len(r[1]) for r in rows)
    order = {FAIL: 0, UNKNOWN: 1, SKIP: 2, PASS: 3}
    for status, name, why, detail in sorted(rows, key=lambda r: (order[r[0]], r[1])):
        print(f"{status:<8} {name:<{width}}  {detail}")
        if status in (FAIL, UNKNOWN):
            print(f"{'':<8} {'':<{width}}  why it matters: {why}")
    fails = sum(1 for r in rows if r[0] == FAIL)
    unknowns = sum(1 for r in rows if r[0] == UNKNOWN)
    print(f"\n{len(rows) - fails - unknowns} pass, {fails} fail, {unknowns} unknown")
    if obs.get("euid", 0) != 0:
        print("NOTE: probe ran unprivileged; re-run it with sudo to resolve UNKNOWNs.")
    return 1 if fails else 0


def main(argv):
    if len(argv) != 2:
        print(f"usage: {os.path.basename(argv[0])} <host.json>", file=sys.stderr)
        return 2
    obs = json.load(open(argv[1]))
    checks = Checks(obs)
    if checks.role not in ROLE_EXPECT:
        print(f"unknown role {checks.role!r}; add it to ROLE_EXPECT", file=sys.stderr)
        return 2
    keys = obs["fleet_image"]["keys"]
    print(f"# {obs['hostname']} ({obs['model']}) role={checks.role}")
    print(f"# image {keys.get('FLEET_IMAGE')} built from "
          f"{keys.get('ORG_OPENCONTAINERS_IMAGE_REVISION', '?')[:10]}")
    print(f"# kernel {obs['kernel']}\n")
    return render(checks.run(), obs)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
