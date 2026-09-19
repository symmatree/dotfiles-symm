#!/usr/bin/env bash
# Probe a device and check the image's mechanisms, in one step.
#
#   pi-image/run-claims-check.sh campod-se
#   pi-image/run-claims-check.sh pi@10.0.5.237 -i ~/.ssh/somekey
#
# Run it after changing something you are worried about. Nothing is installed on
# the device: the probe is piped over ssh and run from stdin, reads only, and
# leaves nothing behind. The JSON is kept so two runs can be diffed -- which is
# the point before and after a suite bump.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${CLAIMS_OUT_DIR:-${TMPDIR:-/tmp}}"

[ $# -ge 1 ] || {
	echo "usage: $(basename "$0") [user@]host [ssh args...]" >&2
	exit 2
}
TARGET="$1"
shift
case "$TARGET" in
*@*) ;;
*) TARGET="pi@$TARGET" ;;
esac

OUT="$OUT_DIR/$(echo "$TARGET" | tr '@/' '__').json"

# sudo: a few claims (the sudoers file, lsattr on /var/lib/docker) sit behind
# root-only directories, and an unprivileged probe reports them UNKNOWN rather
# than guessing. -n so this fails loudly instead of hanging on a password prompt.
echo "== probing $TARGET ==" >&2
ssh -o BatchMode=yes "$@" "$TARGET" 'sudo -n python3 -' <"$HERE/probe-claims.py" >"$OUT"
echo "== wrote $OUT ==" >&2
echo >&2

exec python3 "$HERE/check-claims.py" "$OUT"
