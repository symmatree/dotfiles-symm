#!/usr/bin/env python3
"""Report what this device observably IS, as JSON, for the image-claim checker.

Runs ON a fleet device. Emits observations only -- it holds no expectations and
makes no judgements, so it never needs updating when a role changes. The
comparison against what the build declared happens in the repo, where the role
files live (check-claims.py). Same division as coordinator#326 R5: the device
prints its map, nothing is pushed to it to compare itself against.

Everything here is a claim the image build makes. Nothing here is "is this box
healthy" -- load, free space and failed units are a different question, asked of
a different tool.

stdlib only, and no root required for most of it. Pi OS Lite ships python3 for
cloud-init, so nothing needs installing:

    ssh pi@<host> python3 - < pi-image/probe-claims.py > <host>.json
"""

import glob
import json
import os
import re
import subprocess
import sys


# "I could not look" is a THIRD state, never folded into "it is not there".
# /etc/sudoers.d is 0750 root:root, so an unprivileged probe cannot stat inside
# it -- reporting that as absent would be a checker that lies in the direction of
# alarm. Every observation that can be blocked by permissions returns UNKNOWN
# instead, and the checker refuses to pass or fail on it.
UNKNOWN = "unknown"


def read(path, default=None):
    """File contents, None if absent, UNKNOWN if permissions hid it."""
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except PermissionError:
        return UNKNOWN
    except OSError:
        return default


def run(*argv):
    """Capture a command's stdout, or None if it cannot run. Never raises."""
    try:
        out = subprocess.run(
            argv, capture_output=True, text=True, timeout=60, check=False
        )
        return out.stdout if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def fleet_image():
    """The manifest, plus whether it still parses all three ways it promises to.

    PIPELINE.md: /etc/fleet-image is simultaneously valid TOML, sourceable shell
    and a systemd EnvironmentFile. The build asserts that; this re-checks it on
    the device, because the file is what identifies the image under test.
    """
    raw = read("/etc/fleet-image")
    if raw is None:
        return {"present": False}

    out = {"present": True, "raw": raw, "keys": {}}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        out["keys"][key] = value.strip('"')

    # TOML is the strictest of the three and catches whitespace around '='.
    try:
        import tomllib

        tomllib.loads(raw)
        out["parses_toml"] = True
    except Exception as exc:  # noqa: BLE001 -- any parse failure is the finding
        out["parses_toml"] = False
        out["toml_error"] = str(exc)

    # `source` fails on a space around '=' and expands a bare $.
    out["shell_safe"] = all(
        re.match(r'^[A-Z0-9_]+="[^"$]*"$', ln.strip()) is not None
        for ln in raw.splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    )
    return out


def mounts():
    """Mount table with the options actually in force.

    Options matter as much as the graph: btrfs applies most of them
    per-filesystem, so a subvolume can be mounted at the right place with the
    wrong options and look correct in `mount`.
    """
    out = []
    for line in (read("/proc/self/mountinfo") or "").splitlines():
        # <id> <parent> <maj:min> <root> <target> <options> ... - <fstype> <src> <sopts>
        left, _, right = line.partition(" - ")
        lf, rf = left.split(), right.split()
        if len(lf) < 6 or len(rf) < 3:
            continue
        out.append(
            {
                "target": lf[4],
                "subvol_root": lf[3],
                "vfs_options": lf[5],
                "fstype": rf[0],
                "source": rf[1],
                "fs_options": rf[2],
            }
        )
    return out


def modules():
    return sorted(
        ln.split()[0] for ln in (read("/proc/modules") or "").splitlines() if ln.split()
    )


def packages():
    out = run("dpkg-query", "-W", "-f=${Package}\n")
    return sorted(out.split()) if out else []


def unit_states():
    """Masked/enabled state for every timer, plus the units the build masks byname."""
    states = {}
    out = run("systemctl", "list-unit-files", "--no-legend", "--no-pager", "--type=timer")
    for line in (out or "").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            states[parts[0]] = parts[1]
    for unit in ("e2scrub_reap.service",):
        got = run("systemctl", "is-enabled", unit)
        states[unit] = (got or "absent").strip()
    return states


def device_nodes():
    """Device tree claims are only real if a node appeared.

    Asserting a line is present in config.txt proves nothing -- coordinator#248
    was written because `dtparam=i2c_arm=on` shipped with no bus behind it.
    """
    return {
        "tty": sorted(glob.glob("/dev/ttyAMA*") + glob.glob("/dev/ttyS*")),
        "serial_symlinks": sorted(glob.glob("/dev/serial*")),
        "spidev": sorted(glob.glob("/dev/spidev*")),
        "i2c": sorted(glob.glob("/dev/i2c-*")),
        "udc": sorted(os.path.basename(p) for p in glob.glob("/sys/class/udc/*")),
        "drm": sorted(os.path.basename(p) for p in glob.glob("/sys/class/drm/*")),
        "sound": sorted(os.path.basename(p) for p in glob.glob("/proc/asound/card*")),
        "video": sorted(glob.glob("/dev/video*")),
        # The BUS existing and the /dev node existing are different layers. The
        # device tree (image) brings up the bus; i2c-dev (ansible, via
        # modules-load.d) creates the character device. Without both
        # observations a missing /dev/i2c-* cannot be attributed to a layer --
        # which is the exact confusion behind coordinator#248.
        "i2c_buses": sorted(os.path.basename(p)
                            for p in glob.glob("/sys/bus/i2c/devices/*")),
    }


def nodatacow():
    """chattr +C targets. Cannot be a mount option on btrfs; must be an inode flag."""
    out = {}
    for path in ("/var/lib/docker", "/scratch"):
        if not os.path.exists(path):
            out[path] = None
            continue
        got = run("lsattr", "-d", path)
        # /var/lib/docker is 0710 root:root -- unreadable unprivileged, and that
        # is not the same as having no +C flag.
        out[path] = got.split()[0] if got else UNKNOWN
    return out


def dt_aliases():
    """Device-tree aliases, so the checker can resolve `serial0`.

    cmdline.txt says `console=serial0,115200`; /proc/cmdline says
    `console=ttyAMA0,115200`, because the firmware substitutes the alias before
    handing the line to the kernel. Without this the checker reports a correct
    device as missing its console.
    """
    out = {}
    # /dev/serialN is a udev symlink to the tty the alias resolved to, which is
    # the name that shows up in /proc/cmdline. The device-tree alias value is a
    # node path (serial@7e201000) and cannot be compared with a console= token.
    for link in glob.glob("/dev/serial[0-9]"):
        try:
            out[os.path.basename(link)] = os.path.basename(os.path.realpath(link))
        except OSError:
            pass
    for path in glob.glob("/proc/device-tree/aliases/serial*"):
        name = os.path.basename(path)
        if name in out:
            continue
        target = read(path)
        if target and target is not UNKNOWN:
            out[name] = target.strip("\x00").split("/")[-1]
    return out


def firmware_boot_state():
    """What the firmware says it did -- the channel that settled the tryboot question.

    See BOOT-SELECTION.md. Not a claim the image makes, but it is how a boot
    selector would be verified, and it is four cheap reads.
    """
    out = {}
    base = "/proc/device-tree/chosen/bootloader"
    for name in ("partition", "tryboot", "boot-mode", "rsts"):
        raw = read(os.path.join(base, name))
        out[name] = (
            int.from_bytes(raw.encode("latin-1")[:4], "big") if raw else None
        )
    return out


def main():
    cma = re.search(r"^CmaTotal:\s+(\d+) kB", read("/proc/meminfo") or "", re.M)
    root_dev = read("/proc/cmdline") or ""

    doc = {
        "probe_version": 1,
        # The checker needs this: unprivileged runs legitimately cannot see some
        # claims, and it must report those as unknown rather than as failures.
        "euid": os.geteuid(),
        "hostname": (read("/etc/hostname") or "").strip(),
        "model": (read("/proc/device-tree/model") or "").strip("\x00").strip(),
        "kernel": os.uname().release,
        "fleet_image": fleet_image(),
        "config_txt": read("/boot/firmware/config.txt", ""),
        "cmdline": root_dev.strip(),
        "modules_loaded": modules(),
        "mounts": mounts(),
        "packages_installed": packages(),
        "unit_states": unit_states(),
        "swaps": (read("/proc/swaps") or "").splitlines(),
        "sudoers_nopasswd": None,
        "device_nodes": device_nodes(),
        "nodatacow": nodatacow(),
        "cma_total_kb": int(cma.group(1)) if cma else None,
        "dt_aliases": dt_aliases(),
        "cmdline_txt": read("/boot/firmware/cmdline.txt", ""),
        "firmware_boot_state": firmware_boot_state(),
        "boot_files": sorted(
            os.path.basename(p) for p in glob.glob("/boot/firmware/*")
        ),
    }

    sudoers = "/etc/sudoers.d/010_pi-nopasswd"
    try:
        st = os.stat(sudoers)
        doc["sudoers_nopasswd"] = {
            "present": True,
            "mode": oct(st.st_mode & 0o777),
            "uid": st.st_uid,
        }
    except PermissionError:
        # The containing directory is 0750 root:root. Unprivileged, this says
        # nothing either way -- run the probe under sudo to resolve it.
        doc["sudoers_nopasswd"] = {"present": UNKNOWN}
    except OSError:
        doc["sudoers_nopasswd"] = {"present": False}

    json.dump(doc, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
