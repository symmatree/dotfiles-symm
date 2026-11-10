#!/bin/bash
# How config-arm64 for build r1 was produced (pod, x86-64, 2026-11-09).
# Toolchain: conda-forge clang/lld 23.1.4 (env from
#   conda create -p kenv -c conda-forge --override-channels clang lld llvm-tools flex bison bc make)
# and Ubuntu pahole 1.25 (dwarves_1.25-0ubuntu3, pahole_1.25-0ubuntu3, libdw1t64 0.190-1.1ubuntu0.1,
# libbpf1 1:1.3.0-2build2, libelf1t64 0.190-1.1ubuntu0.1; unpacked with dpkg -x, run with
# LD_LIBRARY_PATH). Tree: linux-6.18.58.tar.xz + Talos's 15 patches (pkgs f4bda77) +
# the renamed DockSeed series, applied with patch -p1 --fuzz=0 (apply-series.sh).
# usage: make-config.sh <patched tree> <talos config-arm64 @ f4bda77> <fragment> <outdir>
set -euo pipefail
tree=$1
talos=$2
frag=$3
out=$4
cd "$tree"
rm -rf "$out"
mkdir -p "$out"
ARCH=arm64 LLVM=1 scripts/kconfig/merge_config.sh -m -O "$out" "$talos" "$frag"
make -s ARCH=arm64 LLVM=1 O="$out" olddefconfig
# the result is $out/.config, saved as datasets/cubie-a7s/talos-kernel/config-arm64
