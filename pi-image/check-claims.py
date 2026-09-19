#!/usr/bin/env python3
"""The integration test for the imaging code: did the patches' MECHANISMS work?

    pi-image/run-claims-check.sh <host>      # probe + check in one step
    pi-image/check-claims.py <host>.json     # check an existing probe

Run it after changing something you are worried about.

Not a health check -- load, disk space and failed units are a different question.
Not a golden copy of the config either: one sentinel shows a mechanism ran, while
restating every purged package proves nothing and makes each deliberate edit a
failure. What earns a check is a mechanism that is fragile, or depends on two
things agreeing, and whose failure is remote and silent. Test until fear turns
into boredom, then stop.

Expectations are written HERE, independently. A test that reads its expectations
out of the code under test cannot fail when that code is wrong. So a card older
than a check will fail it -- that means "this card predates this expectation",
and the image's gitsha is in the header.

To add a check: one @check(...) and a function returning (ok, detail). Return
None for ok when the probe could not see; that is UNKNOWN and never a failure.
"""

import json
import os
import re
import sys

PASS, FAIL, UNKNOWN = "PASS", "FAIL", "UNKNOWN"

# Per-role expectations. Only what the checks below need.
ROLES = {
    "campod": dict(data="/var/lib/campod", cma=131072, nodes=["spidev", "udc"],
                   absent=["drm", "sound"], uart_console=True,
                   blacklist=["drm", "snd_bcm2835"]),
    "coordinator": dict(data="/var/lib/coordinator", cma=None, nodes=["i2c_buses"],
                        absent=[], uart_console=False, blacklist=[]),
    "pocketterm": dict(data="/var/lib/store", cma=None, nodes=[], absent=[],
                       uart_console=False, blacklist=[]),
}

PURGE_SENTINEL = "avahi-daemon"
# raspi-config Depends alsa-utils, raspberrypi-sys-mods Depends raspi-config: an
# over-broad purge takes provisioning and the radio and still boots.
SURVIVORS = ["raspi-config", "raspberrypi-sys-mods", "userconf-pi", "rfkill"]
MASK_SENTINEL = "apt-daily.timer"
SUBVOLS = ["@", "@usr", "@var", "@home", "@data", "@scratch", "@snapshots"]
DISK_ID = "c0dec0de"  # fixed MBR id, so PARTUUIDs match across cards

CHECKS = []


def check(name, why, needs=None):
    """Register a check. `needs` names a ROLES key that must be truthy to apply."""
    def register(fn):
        CHECKS.append((name, why, needs, fn))
        return fn
    return register


class Obs:
    """Thin accessors over the probe's JSON, so checks stay one-liners."""

    def __init__(self, doc):
        self.doc = doc
        self.role = doc["fleet_image"]["keys"].get("FLEET_ROLE")
        self.expect = ROLES.get(self.role, {})
        self.mounts = {m["target"]: m for m in doc["mounts"]}
        self.subvols = {m["subvol_root"].lstrip("/") for m in doc["mounts"]
                        if m["fstype"] == "btrfs"}
        self.packages = set(doc["packages_installed"])
        self.modules = set(doc["modules_loaded"])
        self.cmdline = doc["cmdline"].split()

    def nodes(self, key):
        """Device nodes, with card-like keys filtered to real cardN entries."""
        got = self.doc["device_nodes"].get(key) or []
        if key in ("drm", "sound"):
            return [c for c in got if re.match(r"^card\d+$", c)]
        return got

    def opts(self, target):
        m = self.mounts.get(target)
        return m["vfs_options"].split(",") if m else []


@check("purge/mechanism", "an over-broad purge is silent until something needs it")
def _(o):
    gone = PURGE_SENTINEL not in o.packages
    return gone, f"{PURGE_SENTINEL}: {'absent' if gone else 'STILL INSTALLED'}"


@check("purge/cascade-guard", "purging one package can take provisioning and the radio")
def _(o):
    missing = [p for p in SURVIVORS if p not in o.packages]
    return not missing, "all survivors present" if not missing else f"lost {missing}"


@check("config.txt/in-force",
       "appended lines land at the END of the vendor file; if it ends inside a "
       "[cm4]/[cm5] section they are all silently inert", needs="nodes")
def _(o):
    got = {k: o.nodes(k) for k in o.expect["nodes"]}
    missing = [k for k, v in got.items() if not v]
    return not missing, f"{got}" if not missing else f"nothing appeared for {missing}"


@check("config.txt/removal-took",
       "CONFIG_REMOVE matches a vendor line by glob; a suite bump can change that "
       "line and the glob then matches nothing", needs="cma")
def _(o):
    want, got = o.expect["cma"], o.doc["cma_total_kb"]
    return got == want, f"CmaTotal {got} kB, want {want} (256 MB = vc4 still loaded)"


@check("config.txt/driver-gone",
       "a removed overlay is only really gone if its driver stopped binding",
       needs="absent")
def _(o):
    still = {k: o.nodes(k) for k in o.expect["absent"] if o.nodes(k)}
    return not still, "no drm or sound cards" if not still else f"still bound: {still}"


@check("blacklist/modules",
       "modprobe.d must be copied INTO the initramfs; coldplug runs before the "
       "rootfs is up, so a miss loads the module anyway", needs="blacklist")
def _(o):
    loaded = [m for m in o.expect["blacklist"] if m in o.modules]
    return not loaded, "none loaded" if not loaded else f"LOADED: {loaded}"


@check("cmdline/console-order",
       "/dev/console is the LAST console= token; wrong order sends systemd's "
       "output to a monitor nobody has", needs="uart_console")
def _(o):
    consoles = [t for t in o.cmdline if t.startswith("console=")]
    if not consoles:
        return False, "no console= token at all"
    dev = consoles[-1].partition("console=")[2].split(",")[0]
    resolved = o.doc.get("dt_aliases", {}).get(dev, dev)
    return resolved.startswith(("ttyAMA", "ttyS")), f"{consoles[-1]} -> {resolved}"


@check("subvols/graph", "a subvolume that fails to mount leaves its mountpoint "
                        "working, backed by the wrong subvolume")
def _(o):
    missing = [s for s in SUBVOLS if s not in o.subvols]
    return not missing, "all seven mounted" if not missing else f"missing {missing}"


@check("subvols/@data-lockstep",
       "must equal coord_state_root in the coordinator repo, or captures land on "
       "@var with no error and no warning")
def _(o):
    want = o.expect["data"]
    m = o.mounts.get(want)
    if not m:
        return False, f"{want} is not a mount point"
    return m["subvol_root"].endswith("@data"), f"{want} <- {m['subvol_root']}"


@check("mount/usr-ro", "the write-frugality pillar; a converge remounts it rw and "
                       "cannot restore it, so this reads rw until the next boot")
def _(o):
    if "/usr" not in o.mounts:
        return False, "/usr is not a separate mount"
    return "ro" in o.opts("/usr"), f"/usr {','.join(o.opts('/usr'))}"


@check("mount/nodatacow", "nodatacow cannot be a per-subvolume mount option; a "
                          "fstab line saying so is silently discarded")
def _(o):
    flags = o.doc["nodatacow"]
    unknown = [p for p, a in flags.items() if a == "unknown"]
    bad = [p for p, a in flags.items() if a not in (None, "unknown") and "C" not in a]
    bad += [p for p, a in flags.items() if a is None]
    if unknown and not bad:
        return None, f"could not read {unknown} (run the probe with sudo)"
    return not bad, "both +C" if not bad else f"missing +C on {bad}"


@check("mount/boot-firmware", "no nofail: that drops Before=local-fs.target and "
                              "lets first-boot provisioning race an empty mountpoint")
def _(o):
    m = o.mounts.get("/boot/firmware")
    if not m:
        return False, "not mounted"
    return m["fstype"] == "vfat" and "rw" in o.opts("/boot/firmware"), \
        f"{m['fstype']} {m['vfs_options']}"


@check("manifest/three-formats", "must parse as TOML, shell and EnvironmentFile; "
                                 "one space around an = breaks sourcing only")
def _(o):
    fi = o.doc["fleet_image"]
    ok = bool(fi.get("parses_toml") and fi.get("shell_safe"))
    return ok, f"toml={fi.get('parses_toml')} shell_safe={fi.get('shell_safe')}"


@check("swap/off", "rpi-swap's drop-in dir is upstream's; a rename re-enables swap "
                   "onto the SD card silently")
def _(o):
    active = [x for x in o.doc["swaps"][1:] if x.strip()]
    return not active, "none active" if not active else f"swap ACTIVE: {active}"


@check("timers/masked", "masking happens in the chroot; if it did not take, timers "
                        "with Persistent=true catch up every missed window at once")
def _(o):
    state = o.doc["unit_states"].get(MASK_SENTINEL, "absent")
    return state in ("masked", "absent"), f"{MASK_SENTINEL}: {state}"


@check("sudo/nopasswd", "sudo validates the ownership of a symlink's TARGET, so this "
                        "must be a copy; without it provisioning hangs at a prompt")
def _(o):
    s = o.doc["sudoers_nopasswd"]
    if s.get("present") == "unknown":
        return None, "could not stat it (run the probe with sudo)"
    return s.get("present") and s.get("mode") == "0o440" and s.get("uid") == 0, f"{s}"


@check("disk/partuuid-stable", "the fixed MBR id is what makes PARTUUIDs identical "
                               "across cards; the vendor resize randomises it")
def _(o):
    root = [t for t in o.cmdline if t.startswith("root=PARTUUID=")]
    if not root:
        return None, "no root=PARTUUID= on the command line"
    uuid = root[0].split("=", 2)[2]
    return uuid.startswith(DISK_ID), f"root={uuid}"


@check("disk/grow-rootfs", "if it stops, the card stays the size it was built and "
                           "nothing says so until it fills")
def _(o):
    sizes = o.doc.get("block", {}).get("sizes_512b", {})
    disk = next((n for n in sizes if re.match(r"^(mmcblk\d+|nvme\d+n\d+)$", n)), None)
    if not disk or f"{disk}p2" not in sizes:
        return None, "no whole-disk device or p2 found"
    frac = sizes[f"{disk}p2"] / sizes[disk]
    gib = 2 ** 30 // 512  # 512-byte sectors per GiB
    return frac > 0.90, (f"p2 {sizes[f'{disk}p2'] // gib} GiB of "
                         f"{sizes[disk] // gib} GiB ({frac:.0%})")


def run(obs):
    rows = []
    for name, why, needs, fn in CHECKS:
        if needs and not obs.expect.get(needs):
            continue
        try:
            ok, detail = fn(obs)
        except Exception as exc:  # noqa: BLE001 -- a broken check is a finding
            ok, detail = None, f"check raised: {exc}"
        rows.append((PASS if ok else FAIL if ok is not None else UNKNOWN,
                     name, why, detail))
    return rows


def main(argv):
    if len(argv) != 2:
        print(f"usage: {os.path.basename(argv[0])} <host.json>", file=sys.stderr)
        return 2
    doc = json.load(open(argv[1]))
    obs = Obs(doc)
    if obs.role not in ROLES:
        print(f"unknown role {obs.role!r}; add it to ROLES", file=sys.stderr)
        return 2

    keys = doc["fleet_image"]["keys"]
    print(f"# {doc['hostname']} ({doc['model']}) role={obs.role} kernel={doc['kernel']}")
    print(f"# image {keys.get('FLEET_IMAGE')} built from "
          f"{keys.get('ORG_OPENCONTAINERS_IMAGE_REVISION', '?')[:10]}\n")

    rows = run(obs)
    width = max(len(r[1]) for r in rows)
    for status, name, why, detail in sorted(rows, key=lambda r: ("FUP".index(r[0][0]),
                                                                 r[1])):
        print(f"{status:<8} {name:<{width}}  {detail}")
        if status != PASS:
            print(f"{'':<8} {'':<{width}}  why: {why}")

    fails = sum(1 for r in rows if r[0] == FAIL)
    unknown = sum(1 for r in rows if r[0] == UNKNOWN)
    print(f"\n{len(rows) - fails - unknown} pass, {fails} fail, {unknown} unknown")
    if doc.get("euid", 0) != 0:
        print("NOTE: probe ran unprivileged; re-run with sudo to resolve UNKNOWNs.")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
