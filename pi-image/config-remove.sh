#!/usr/bin/env bash
#
# config-remove.sh -- comment out config.txt directives matching glob patterns.
#
# Appending cannot undo a directive: there is no "dtoverlay=none", and a second
# dtoverlay line loads a second overlay rather than replacing the first. Only
# dtparam has last-wins semantics, and not reliably across sections. So the only
# way to drop a vendor directive is to stop the firmware reading it.
#
# Usage:
#   config-remove.sh CONFIG_TXT PATTERN...
#
# Lines are rewritten in place. A matching line becomes a comment recording what
# it was, so a card still shows what the vendor shipped and that its absence was
# chosen. Exits non-zero if a pattern matched nothing -- that is a typo or a
# vendor change, and the directive would otherwise stay enabled with nothing said.
#
# SECTION-BLIND, deliberately. config.txt is scoped by [all]/[cm4]/[pi5] headers
# and this ignores them: a pattern removes its directive from every section. The
# roles that use it want a directive gone from the whole file, and a
# section-aware matcher is a parser, not a filter.
#
# Matching ignores surrounding whitespace, so an indented directive cannot slip
# through; the original line is preserved byte-for-byte when it does not match.
set -euo pipefail

CFG="${1:?usage: config-remove.sh CONFIG_TXT PATTERN...}"
shift
[ "$#" -gt 0 ] || {
	echo "config-remove.sh: no patterns given" >&2
	exit 2
}
[ -f "$CFG" ] || {
	echo "config-remove.sh: no such file: $CFG" >&2
	exit 2
}

LABEL="${CONFIG_REMOVE_LABEL:-build-image.sh}"

declare -A matched=()
for pat in "$@"; do matched["$pat"]=0; done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
	# Compare against a trimmed copy; emit the original. \r is in [:space:], so
	# trimming also handles a CRLF file.
	probe="${line#"${line%%[![:space:]]*}"}"
	probe="${probe%"${probe##*[![:space:]]}"}"

	hit=""
	case "$probe" in
	\#* | '') ;;
	*)
		for pat in "$@"; do
			# shellcheck disable=SC2254  # glob match is the point
			case "$probe" in
			$pat)
				hit="$pat"
				break
				;;
			esac
		done
		;;
	esac

	if [ -n "$hit" ]; then
		matched["$hit"]=$((matched["$hit"] + 1))
		printf '# disabled by %s: %s\n' "$LABEL" "$probe" >>"$tmp"
		echo "   disabled: $probe"
	else
		printf '%s\n' "$line" >>"$tmp"
	fi
done <"$CFG"

cat "$tmp" >"$CFG"

rc=0
for pat in "$@"; do
	if [ "${matched[$pat]}" -eq 0 ]; then
		echo "   !! pattern matched nothing: $pat" >&2
		rc=1
	fi
done
exit "$rc"
