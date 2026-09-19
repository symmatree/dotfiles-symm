#!/usr/bin/env python3
"""Check a device's observations against what the image build claims it did.

    ssh pi@<host> sudo python3 - < pi-image/probe-claims.py > /tmp/<host>.json
    pi-image/check-claims.py /tmp/<host>.json

Every check traces to a line in `roles/<role>.env`, `roles/<role>/config.append.txt`,
`build-image.sh` or `assemble-btrfs.sh` -- the expectations are READ FROM THE BUILD,
not restated here, so a role change cannot leave a stale copy behind. Nothing is
checked because somebody thought it looked interesting.

This is deliberately NOT a health check. Load, free space, failed units and
journal state are a different question about a different subject; see
coordinator#248, which makes the same distinction.

Three outcomes per claim, and the third one matters:

    PASS     the claim is declared and observably took effect
    FAIL     the claim is declared and observably did not
    UNKNOWN  the probe could not see (ran unprivileged, or the evidence is
             not reachable from userspace) -- never counted as a failure

Exit 0 if nothing failed, 1 otherwise. UNKNOWNs do not fail the run; they are
listed so the gap is visible rather than silently scored as a pass.
"""

import fnmatch
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SUBVOLS = ["@", "@usr", "@var", "@home", "@data", "@scratch", "@snapshots"]

# Packages the purge must not remove, because a dependency edge would take them.
# raspi-config Depends alsa-utils; raspberrypi-sys-mods Depends raspi-config.
# This cost a card once -- see PIPELINE.md "apt-get purge cascades".
PURGE_SURVIVORS = ["raspi-config", "raspberrypi-sys-mods", "userconf-pi", "rfkill"]

# A config.txt directive is only real if something appeared. Left: a regex over
# the directive as written in config.append.txt. Right: the observation key and
# what it has to show. Adding a directive to a role without adding it here makes
# the checker say so, rather than silently skipping it.
DT_EFFECTS = [
    (r"^enable_uart=1", "tty", lambda v: any("ttyAMA" in x for x in v),
     "a PL011/mini-UART tty"),
    (r"^dtparam=spi=on", "spidev", lambda v: bool(v), "at least one /dev/spidev*"),
    (r"^dtparam=i2c_arm=on", "i2c", lambda v: bool(v), "at least one /dev/i2c-*"),
    (r"^dtoverlay=dwc2", "udc", lambda v: bool(v), "a USB device controller"),
]


class Sources:
    """Reads build inputs AT THE REVISION THE IMAGE WAS BUILT FROM.

    This is the whole reason /etc/fleet-image carries a gitsha. Checking a
    device against the working tree asks "does this card match what we would
    build today", which is a different and usually wrong question -- a card
    flashed last week fails every claim added since, and the report blames the
    device for the repo moving. Verified the hard way: the first run of this
    checker reported ten failures on a healthy card, seven of them claims that
    did not exist when its image was built.

    Falls back to the working tree only when the revision is unavailable, and
    says so loudly, because the answer then means something weaker.
    """

    def __init__(self, revision):
        self.revision = revision
        self.from_worktree = False
        if revision:
            ok = subprocess.run(
                ["git", "-C", REPO, "cat-file", "-e", f"{revision}^{{commit}}"],
                capture_output=True,
            )
            if ok.returncode == 0:
                return
        self.from_worktree = True

    def read(self, relpath):
        """relpath is relative to the repo root, e.g. pi-image/build-image.sh."""
        if not self.from_worktree:
            got = subprocess.run(
                ["git", "-C", REPO, "show", f"{self.revision}:{relpath}"],
                capture_output=True, text=True,
            )
            if got.returncode == 0:
                return got.stdout
            return None  # the file did not exist at that revision
        try:
            with open(os.path.join(REPO, relpath)) as fh:
                return fh.read()
        except OSError:
            return None

    def describe(self):
        if self.from_worktree:
            return ("WORKING TREE -- the image's revision is not in this checkout, so "
                    "claims added since it was built will show as failures")
        return f"{self.revision[:10]} (the revision this image was built from)"


def parse_env_text(text):
    """Read roles/<role>.env. Shell, but only ever flat KEY=VALUE assignments."""
    out = {}
    if text:
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            if not re.match(r"^[A-Z_]+$", key):
                continue
            out[key] = value.strip().strip('"').strip("'")
    return out


def build_constants(sources):
    """Pull PURGE and the masked-unit list out of build-image.sh itself."""
    src = sources.read("pi-image/build-image.sh") or ""
    purge = re.search(r'^\s*PURGE="([^"]+)"', src, re.M)
    mask = re.search(r"systemctl mask \\\n(.*?)\n\t*# ", src, re.S)
    units = re.findall(r"[\w.-]+\.timer", mask.group(1)) if mask else []
    return (purge.group(1).split() if purge else []), units


def cards(entries):
    """Real card nodes only. /proc/asound/cards is a FILE, not a sound card --
    a startswith('card') test counts it and reports audio that is not there."""
    return [e for e in entries if re.match(r"^card\d+$", e)]


def console_matches(token, want, aliases):
    """Compare a console= token, resolving the firmware's serial alias.

    cmdline.txt carries `console=serial0,115200`; the firmware substitutes the
    alias, so /proc/cmdline carries `console=ttyAMA0,115200`. Both name the same
    port, and a checker that does not know this fails a correct device.
    """
    if token == want:
        return True
    dev_t, _, rate_t = token.partition("console=")[2].partition(",")
    dev_w, _, rate_w = want.partition("console=")[2].partition(",")
    if rate_t != rate_w:
        return False
    return aliases.get(dev_w, dev_w) == aliases.get(dev_t, dev_t)


class Report:
    def __init__(self):
        self.rows = []

    def add(self, status, claim, detail, source):
        self.rows.append((status, claim, detail, source))

    def ok(self, claim, detail, source):
        self.add("PASS", claim, detail, source)

    def bad(self, claim, detail, source):
        self.add("FAIL", claim, detail, source)

    def unknown(self, claim, detail, source):
        self.add("UNKNOWN", claim, detail, source)

    def render(self):
        width = max(len(r[1]) for r in self.rows)
        order = {"FAIL": 0, "UNKNOWN": 1, "PASS": 2}
        for status, claim, detail, source in sorted(
            self.rows, key=lambda r: (order[r[0]], r[1])
        ):
            print(f"{status:<8} {claim:<{width}}  {detail}")
            if status != "PASS":
                print(f"{'':<8} {'':<{width}}  declared in: {source}")
        fails = sum(1 for r in self.rows if r[0] == "FAIL")
        unknowns = sum(1 for r in self.rows if r[0] == "UNKNOWN")
        passes = len(self.rows) - fails - unknowns
        print(f"\n{passes} pass, {fails} fail, {unknowns} unknown")
        return 1 if fails else 0


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print(f"usage: {os.path.basename(argv[0])} <host.json>", file=sys.stderr)
        return 2

    obs = json.load(open(argv[1]))
    rep = Report()
    role = obs["fleet_image"]["keys"].get("FLEET_ROLE")
    if not role:
        print("no FLEET_ROLE in /etc/fleet-image; cannot pick a role", file=sys.stderr)
        return 2

    revision = obs["fleet_image"]["keys"].get("ORG_OPENCONTAINERS_IMAGE_REVISION")
    sources = Sources(revision)
    env = parse_env_text(sources.read(f"pi-image/roles/{role}.env"))
    purge, masked_units = build_constants(sources)
    aliases = obs.get("dt_aliases", {})
    unpriv = obs.get("euid", 0) != 0
    config_txt = obs["config_txt"]
    cmdline = obs["cmdline"].split()

    print(f"# {obs['hostname']} ({obs['model']}) role={role} kernel={obs['kernel']}")
    print(f"# image {obs['fleet_image']['keys'].get('FLEET_IMAGE')}")
    print(f"# claims read from {sources.describe()}")
    print()

    # -- the manifest, which is how the image under test identifies itself ------
    src = "build-image.sh write_manifest(), PIPELINE.md 'three formats at once'"
    if obs["fleet_image"].get("parses_toml") and obs["fleet_image"].get("shell_safe"):
        rep.ok("manifest/formats", "parses as TOML and is shell-safe", src)
    else:
        rep.bad("manifest/formats",
                f"toml={obs['fleet_image'].get('parses_toml')} "
                f"shell_safe={obs['fleet_image'].get('shell_safe')}", src)

    # -- CONFIG_APPEND: every declared line present, and its effect visible -----
    append_path = env.get("CONFIG_APPEND")
    directives = []
    if append_path:
        src = append_path
        for line in (sources.read(f"pi-image/{append_path}") or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("["):
                continue
            directives.append(line)
            if line in config_txt:
                rep.ok(f"config.txt/{line}", "present in the running config.txt", src)
            else:
                rep.bad(f"config.txt/{line}", "NOT in the running config.txt", src)

        nodes = obs["device_nodes"]
        for pattern, key, predicate, want in DT_EFFECTS:
            for line in directives:
                if re.match(pattern, line):
                    got = nodes.get(key) or []
                    if predicate(got):
                        rep.ok(f"effect/{line}", f"{want}: {got}", src)
                    else:
                        rep.bad(f"effect/{line}", f"expected {want}, found {got}", src)

        # cma-N is the one directive with a number to check rather than a node.
        for line in directives:
            m = re.match(r"^dtoverlay=cma,cma-(\d+)", line)
            if m:
                want_kb = int(m.group(1)) * 1024
                got_kb = obs.get("cma_total_kb")
                if got_kb == want_kb:
                    rep.ok(f"effect/{line}", f"CmaTotal is {got_kb} kB", src)
                else:
                    rep.bad(f"effect/{line}",
                            f"CmaTotal is {got_kb} kB, expected {want_kb}", src)

    # -- CONFIG_REMOVE: vendor line commented out, and its effect gone ---------
    src = f"roles/{role}.env CONFIG_REMOVE"
    for pattern in env.get("CONFIG_REMOVE", "").split():
        live = [
            ln.strip()
            for ln in config_txt.splitlines()
            if ln.strip() and not ln.strip().startswith("#")
            and fnmatch.fnmatch(ln.strip(), pattern)
        ]
        if live:
            rep.bad(f"config-remove/{pattern}", f"still active: {live}", src)
        else:
            rep.ok(f"config-remove/{pattern}", "no active line matches", src)

        # The two removals with an observable consequence on this fleet.
        if pattern.startswith("dtoverlay=vc4-kms-v3d"):
            got = cards(obs["device_nodes"]["drm"])
            (rep.ok if not got else rep.bad)(
                "effect/no-vc4", f"DRM cards: {got or 'none'}", src)
        if pattern.startswith("dtparam=audio=on"):
            got = cards(obs["device_nodes"]["sound"])
            (rep.ok if not got else rep.bad)(
                "effect/no-audio", f"sound cards: {got or 'none'}", src)

    # -- kernel command line ---------------------------------------------------
    src = f"roles/{role}.env CMDLINE_REMOVE/CMDLINE_APPEND"
    for pattern in env.get("CMDLINE_REMOVE", "").split():
        hits = [t for t in cmdline if fnmatch.fnmatch(t, pattern)]
        # An appended token may legitimately re-add what was removed (campod
        # moves the serial console to the END so /dev/console is the UART).
        appended = env.get("CMDLINE_APPEND", "").split()
        hits = [t for t in hits if t not in appended]
        (rep.ok if not hits else rep.bad)(
            f"cmdline-remove/{pattern}",
            "no unexpected token matches" if not hits else f"still present: {hits}", src)
    for token in env.get("CMDLINE_APPEND", "").split():
        hit = any(console_matches(t, token, aliases) for t in cmdline) \
            if token.startswith("console=") else token in cmdline
        (rep.ok if hit else rep.bad)(
            f"cmdline-append/{token}",
            "present (alias-resolved)" if hit else "missing", src)
    if env.get("CMDLINE_APPEND"):
        last = env["CMDLINE_APPEND"].split()[-1]
        consoles = [t for t in cmdline if t.startswith("console=")]
        if consoles and last.startswith("console="):
            good = console_matches(consoles[-1], last, aliases)
            (rep.ok if good else rep.bad)(
                "cmdline/console-order",
                f"last console= is {consoles[-1]}"
                + ("" if good else f", expected {last}"),
                f"roles/{role}.env -- /dev/console is the LAST console=")

    # -- module blacklist ------------------------------------------------------
    src = f"roles/{role}.env MODULE_BLACKLIST"
    for mod in env.get("MODULE_BLACKLIST", "").split():
        loaded = mod in obs["modules_loaded"]
        (rep.bad if loaded else rep.ok)(
            f"blacklist/{mod}", "LOADED" if loaded else "not loaded", src)

    # -- the subvolume graph ---------------------------------------------------
    src = "assemble-btrfs.sh"
    by_target = {m["target"]: m for m in obs["mounts"]}
    seen = {
        m["subvol_root"].lstrip("/"): m
        for m in obs["mounts"] if m["fstype"] == "btrfs"
    }
    for sv in SUBVOLS:
        name = sv.lstrip("@") or "@"
        key = sv.lstrip("/")
        present = any(k == sv.lstrip("/") or k == sv[1:] or f"@{k}" == sv for k in seen)
        (rep.ok if present else rep.bad)(
            f"subvol/{sv}", "mounted" if present else "NOT mounted", src)

    data_mount = env.get("DATA_MOUNT")
    if data_mount:
        m = by_target.get(data_mount)
        src = f"roles/{role}.env DATA_MOUNT (lockstep with the coordinator repo)"
        if m and m["subvol_root"].endswith("@data"):
            rep.ok("subvol/@data-location", f"@data is at {data_mount}", src)
        else:
            rep.bad("subvol/@data-location",
                    f"{data_mount} is {m['subvol_root'] if m else 'not a mount'}, "
                    "so captures land on @var", src)

    usr = by_target.get("/usr")
    src = "assemble-btrfs.sh fstab (/usr ... ro) -- contested, coordinator#202"
    if usr:
        ro = "ro" in usr["vfs_options"].split(",")
        (rep.ok if ro else rep.bad)(
            "mount/usr-ro", f"/usr options: {usr['vfs_options']}", src)

    # -- nodatacow, which cannot be a mount option -----------------------------
    src = "assemble-btrfs.sh chattr +C (btrfs(5): not settable per-subvolume)"
    for path, attrs in obs["nodatacow"].items():
        if attrs == "unknown":
            rep.unknown(f"nodatacow/{path}",
                        "probe could not read it (run the probe with sudo)", src)
        elif attrs is None:
            rep.bad(f"nodatacow/{path}", "path does not exist", src)
        else:
            (rep.ok if "C" in attrs else rep.bad)(
                f"nodatacow/{path}", f"lsattr: {attrs}", src)

    # -- the purge, in both directions -----------------------------------------
    installed = set(obs["packages_installed"])
    src = "build-image.sh PURGE (coordinator#316)"
    for pkg in purge:
        (rep.bad if pkg in installed else rep.ok)(
            f"purged/{pkg}", "STILL INSTALLED" if pkg in installed else "absent", src)
    src = "PIPELINE.md 'apt-get purge cascades' -- absence check is not enough"
    for pkg in PURGE_SURVIVORS:
        (rep.ok if pkg in installed else rep.bad)(
            f"survived/{pkg}",
            "present" if pkg in installed else "MISSING -- a dependency took it", src)

    # -- scheduled maintenance, swap, sudo -------------------------------------
    src = "build-image.sh systemctl mask (coordinator#282)"
    for unit in masked_units:
        state = obs["unit_states"].get(unit, "absent")
        (rep.ok if state in ("masked", "absent") else rep.bad)(
            f"masked/{unit}", state, src)

    src = "build-image.sh install_no_swap() (rpi-swap Mechanism=none)"
    active = [ln for ln in obs["swaps"][1:] if ln.strip()]
    (rep.ok if not active else rep.bad)(
        "no-swap", "no swap active" if not active else f"swap active: {active}", src)

    src = "build-image.sh install_sudoers() -- 0440, root-owned, visudo-checked"
    s = obs["sudoers_nopasswd"]
    if s.get("present") == "unknown":
        rep.unknown("sudoers/010_pi-nopasswd",
                    "probe could not stat it (run the probe with sudo)", src)
    elif s.get("present") and s.get("mode") == "0o440" and s.get("uid") == 0:
        rep.ok("sudoers/010_pi-nopasswd", "present, 0440, root-owned", src)
    else:
        rep.bad("sudoers/010_pi-nopasswd", f"{s}", src)

    if unpriv:
        print("NOTE: probe ran unprivileged; some claims are UNKNOWN rather than"
              " checked. Re-run with `sudo python3 -`.\n")
    return rep.render()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
