#!/usr/bin/env bash
#
# test-config-remove.sh -- exercise config-remove.sh against fixtures.
#
# Pure text transformation: no root, no loop devices, no arm64, no btrfs. Runs
# anywhere bash does, unlike the image build it is part of.
#
#   pi-image/test-config-remove.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/config-remove.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "  PASS  $*"; }
fail() {
	echo "  FAIL  $*"
	FAIL=$((FAIL + 1))
}

# run CASE_NAME <<'EOF' ... input ... EOF  -- sets $OUT, $RC, $ERR
run() {
	local name="$1"
	shift
	printf '%s' "$INPUT" >"$WORK/config.txt"
	ERR="$(env CONFIG_REMOVE_LABEL=test "$SUT" "$WORK/config.txt" "$@" 2>&1 >/dev/null)"
	RC=$?
	OUT="$(cat "$WORK/config.txt")"
	echo "- $name"
}

want_line() {
	case "$OUT" in
	*"$1"*) pass "contains: $1" ;;
	*) fail "missing: $1" ;;
	esac
}
want_no_line() {
	case "$OUT" in
	*"$1"*) fail "should not contain: $1" ;;
	*) pass "absent: $1" ;;
	esac
}
want_rc() {
	if [ "$RC" -eq "$1" ]; then pass "rc=$1"; else fail "rc=$RC, wanted $1"; fi
}

# ---- 1. the real vendor shape ----------------------------------------------
INPUT='# comment
dtparam=audio=on
camera_auto_detect=1
display_auto_detect=1
auto_initramfs=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
[cm5]
dtoverlay=dwc2,dr_mode=host
[all]
'
run "vendor config.txt" 'dtoverlay=vc4-kms-v3d*' 'dtparam=audio=on' 'display_auto_detect=*'
want_line '# disabled by test: dtparam=audio=on'
want_line '# disabled by test: dtoverlay=vc4-kms-v3d'
want_line '# disabled by test: display_auto_detect=1'
want_line 'camera_auto_detect=1'        # the camera must survive
want_line 'auto_initramfs=1'            # so must the initramfs switch
want_line '[cm5]'                       # section headers untouched
want_no_line $'\ndtoverlay=vc4-kms-v3d' # no live copy left
want_rc 0

# ---- 2. an indented directive must not slip through ------------------------
INPUT='  dtparam=audio=on
	dtoverlay=vc4-kms-v3d
'
run "leading whitespace" 'dtparam=audio=on' 'dtoverlay=vc4-kms-v3d*'
want_line '# disabled by test: dtparam=audio=on'
want_line '# disabled by test: dtoverlay=vc4-kms-v3d'
want_rc 0

# ---- 3. CRLF must not defeat matching (covered by the whitespace trim) -----
INPUT=$'dtparam=audio=on\r\ncamera_auto_detect=1\r\n'
run "CRLF line endings" 'dtparam=audio=on'
want_line '# disabled by test: dtparam=audio=on'
want_rc 0

# ---- 4. a pattern that matches nothing must be loud ------------------------
INPUT='camera_auto_detect=1
'
run "pattern matches nothing" 'dtoverlay=vc4-kms-v3d*'
want_line 'camera_auto_detect=1'
case "$ERR" in
*"matched nothing: dtoverlay=vc4-kms-v3d*"*) pass "warned" ;;
*) fail "no warning: $ERR" ;;
esac
want_rc 1

# ---- 5. a short unmatched pattern is not masked by a longer matched one -----
# 'vc4-kms-v3d' is a substring of 'dtoverlay=vc4-kms-v3d'. As a glob it matches
# no line (globs match whole strings), so it must be reported. A matched-set kept
# as one concatenated string finds it inside the pattern that DID match and stays
# quiet -- which is the bug this guards.
INPUT='dtoverlay=vc4-kms-v3d
'
run "short pattern masked by a longer match" 'dtoverlay=vc4-kms-v3d' 'vc4-kms-v3d'
case "$ERR" in
*"matched nothing: vc4-kms-v3d"*) pass "the unmatched short pattern is named" ;;
*) fail "substring masking: $ERR" ;;
esac
want_rc 1

# ---- 6. comments are never rewritten ---------------------------------------
INPUT='#dtparam=audio=on
# dtoverlay=vc4-kms-v3d
dtparam=audio=on
'
run "already-commented lines" 'dtparam=audio=on' 'dtoverlay=vc4-kms-v3d*'
want_line '#dtparam=audio=on'
want_no_line '# disabled by test: #dtparam=audio=on'
case "$ERR" in
*"matched nothing: dtoverlay=vc4-kms-v3d*"*) pass "commented line does not count as a match" ;;
*) fail "a comment satisfied a pattern: $ERR" ;;
esac

# ---- 7. idempotent: a second pass changes nothing ---------------------------
INPUT='dtparam=audio=on
camera_auto_detect=1
'
run "first pass" 'dtparam=audio=on'
FIRST="$OUT"
INPUT="$FIRST"
run "second pass (idempotence)" 'dtparam=audio=on'
if [ "$OUT" = "$FIRST" ]; then pass "unchanged on rerun"; else fail "not idempotent"; fi

# ---- 8. no trailing newline on the input ------------------------------------
INPUT='dtparam=audio=on'
run "no trailing newline" 'dtparam=audio=on'
want_line '# disabled by test: dtparam=audio=on'
want_rc 0

echo
if [ "$FAIL" -eq 0 ]; then
	echo "### ALL CHECKS PASSED"
else
	echo "### $FAIL CHECK(S) FAILED"
fi
exit "$FAIL"
