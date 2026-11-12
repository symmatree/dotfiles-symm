#!/usr/bin/env python3
# Make one board's image from another's by rewriting the address and hostname in
# its ip= kernel argument (grub.cfg on the XFS BOOT partition, once per menu
# entry). The argument keeps its byte length, padded with spaces, so no
# filesystem metadata changes; a longer ip or name than the source's is refused.
# usage: set-node.py <in.raw> <out.raw> <ip> <name>
import mmap
import re
import shutil
import sys

src, dst, ip, name = sys.argv[1:]
arg = re.compile(rb"ip=\d+\.\d+\.\d+\.\d+::[^ \n]*")

shutil.copyfile(src, dst)
with open(dst, "r+b") as f, mmap.mmap(f.fileno(), 0) as m:
    found = [(h.start(), h.group()) for h in arg.finditer(m)]
    if not found or len({old for _, old in found}) != 1:
        sys.exit(f"want one distinct ip= argument, found {[old for _, old in found]}")
    old = found[0][1]
    fields = old[3:].split(b":")
    fields[0], fields[4] = ip.encode(), name.encode()
    new = b"ip=" + b":".join(fields)
    if len(new) > len(old):
        sys.exit(f"{new.decode()} is longer than {old.decode()}")
    new = new.ljust(len(old))
    for at, _ in found:
        m[at : at + len(old)] = new
    print(f"{len(found)}x {old.decode()}\n -> {new.decode().rstrip()}")
