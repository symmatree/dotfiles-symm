#!/bin/bash
# usage: apply-series.sh <tarball> <series-dir> <outdir>
set -u
tb=$1
sd=$2
out=$3
[ "$tb" = "-" ] || {
	rm -rf "$out"
	mkdir -p "$out"
	tar -xf "$tb" -C "$out" --strip-components=1
}
cd "$out" || exit 1
n=0
while read -r p; do
	[ -z "$p" ] && continue
	case $p in \#*) continue ;; esac
	n=$((n + 1))
	o=$(patch -p1 --fuzz=0 --no-backup-if-mismatch <"$sd/patches/$p" 2>&1)
	rc=$?
	if [ $rc -ne 0 ]; then
		echo "FAIL $n $p"
		echo "$o" | sed 's/^/    /' | head -6
	elif echo "$o" | grep -q "offset"; then
		echo "OFFSET $n $p"
	else echo "OK $n $p"; fi
done <"$sd/series"
