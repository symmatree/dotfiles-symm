#!/bin/bash
# How kernel/build/patches/ was populated for build r1 (run on the pod, then
# scp'd to ~/pkgs/kernel/build/patches/ on the board). DockSeed a7s-linux-lts
# d1176934016f, kernel/6.18/series, renamed so they sort after Talos's 15.
# usage: stage-patches.sh <a7s-linux-lts checkout> <outdir>
set -euo pipefail
D=$1/kernel/6.18
S=$2
rm -rf "$S"
mkdir -p "$S"
n=0
grep -vE '^\s*(#|$)' "$D/series" | while read -r p; do
	n=$((n + 1))
	cp "$D/patches/$p" "$S/$(printf '1%03d' $n)-a733-$(basename "$p")"
done
