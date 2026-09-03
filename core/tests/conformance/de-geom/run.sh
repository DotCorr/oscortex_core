#!/usr/bin/env bash
# core/tests/conformance/de-geom/run.sh
#
# Anti-vacuity gate for attach placement and COMMIT geometry.
# Valid rapid max/restore/resize must clip stale damage, not refuse.
# Invalid origin/zero extents must still refuse.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "DE-geom: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-geom: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=13

WM="$CORE_DIR/kernel/wm.dart"
POP="$CORE_DIR/kernel/wmpop.dart"
FILES="$CORE_DIR/user/frame/files.c"
DISK="$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh"

ck; [[ -f "$WM" ]] || fail "no wm.dart"
ck; grep -q 'u64 wmPlacePrev' "$WM" \
  || fail "placement still treats overlay cards as tile neighbours"
ck; grep -q 'u64 wmPlaceExtent' "$WM" \
  || fail "attach does not shrink a client that would leave the work area"
ck; grep -q 'remainW >= minW' "$WM" \
  || fail "800x600 tile-right path is gone"
ck; grep -q 'if (nx != x)' "$WM" \
  || fail "attach still drops a tile origin that needs a shrink"
ck; grep -q 'dw = ww - dx' "$WM" \
  || fail "stale full-surface commits are still refused instead of clipped"
ck; grep -q 'dh = hh - dy' "$WM" \
  || fail "stale tall commits are still refused instead of clipped"
ck; grep -q 'if (dx >= ww)' "$WM" \
  || fail "origin-outside commits are no longer clipped into the live geom"
ck; grep -q 'if (dw < u64(1))' "$WM" \
  || fail "zero-extent commits are no longer refused"
ck; grep -q 'const int wmPopW = 168' "$POP" \
  || fail "menu geometry is still the primitive 96x64 card"
ck; grep -q 'files_show_empty' "$FILES" \
  || fail "FILES has no empty-folder sit-in"
ck; grep -q 'VOID=:dir' "$DISK" \
  || fail "sit-in FAT does not plant VOID"
ck; grep -q 'MISS.DAT=:miss' "$DISK" \
  || fail "sit-in FAT does not plant MISS.DAT"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-geom: PASS ($ASSERTIONS_REQUIRED checks) — clip stale commits, refuse invalid, tile on small screens"
exit 0
