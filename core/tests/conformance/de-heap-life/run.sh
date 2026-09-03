#!/usr/bin/env bash
# core/tests/conformance/de-heap-life/run.sh
#
# Round 9: Skia bump lifetime + desk-cache sub-rect identity.
# Host protocol stress (does not compile guest_crt.c — com1 uses inb/outb)
# plus structural checks that unique_ptrs die before rewind.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "DE-heap-life: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-heap-life: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=20

SKIA="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
CRT="$CORE_DIR/plat/osgfx/osgfx_guest_crt.c"
DESK="$CORE_DIR/plat/osgfx/osgfx_desk.c"
DRIVE="$CORE_DIR/scripts/daily-drive-round9.py"

for tool in clang python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; [[ -f "$SKIA" ]] || fail "osgfx_skia.cpp missing"
ck; [[ -f "$CRT" ]] || fail "osgfx_guest_crt.c missing"
ck; [[ -f "$DESK" ]] || fail "osgfx_desk.c missing"
ck; [[ -f "$DRIVE" ]] || fail "daily-drive-round9.py missing"

echo "=== STRUCTURAL ==="
ck; grep -q 'skia_release_client' "$SKIA" \
  || fail "no skia_release_client — client rewind is still ad hoc"
ck; grep -q 'g_one.owned.reset()' "$SKIA" \
  || fail "drop_skia no longer resets g_one"
ck; grep -q 'client_g.owned.reset()' "$SKIA" \
  || fail "drop_skia no longer resets client_g"
ck; python3 - "$SKIA" <<'PY' || fail "unique_ptrs still reset after the bump rewind"
import sys
t = open(sys.argv[1]).read()
h = t.find("static void drop_skia_before_rewind")
he = t.find("\n}", h)
body = t[h:he] if h >= 0 and he > h else ""
ri = body.find("g_one.owned.reset()")
cj = body.find("client_g.owned.reset()")
hj = body.find("osgfx_heap_frame_begin()")
sys.exit(0 if 0 <= ri < hj and 0 <= cj < hj else 1)
PY
ck; grep -q 'if (heap_chrome_mark == 0)' "$CRT" \
  || fail "client_begin still falls back to the Graphite watermark"
ck; ! grep -q 'mark = heap_watermark' "$CRT" \
  || fail "client_begin still assigns the Graphite watermark as a fallback"
ck; grep -q 'heap_reclaim_armed' "$CRT" \
  || fail "malloc OOM reclaim is not armed only after unique_ptrs die"
ck; grep -q 'osgfx_heap_scratch_live' "$SKIA" \
  || fail "bind() does not disarm OOM reclaim while a canvas is live"
ck; grep -q 'desk_blit_rect' "$DESK" \
  || fail "desk cache has no sub-rect blit"
ck; grep -q 'x == 0 && y == 0' "$DESK" \
  || fail "desk cache still regenerates from a hole"
ck; grep -q 'OSGFX HEAP HI' "$CRT" \
  || fail "no OSGFX HEAP HI high-water token"
ck; grep -q 'picture_sentinels' "$DRIVE" \
  || fail "round9 driver has no screenshot pixel sentinels"
ck; grep -q 'OSGFX OOM' "$DRIVE" \
  || fail "round9 driver does not fail on OSGFX OOM"
ck; grep -q 'oscortex-round9-full-desktop.png' "$DRIVE" \
  || fail "round9 driver does not write the full-desktop artifact"

echo
echo "=== HOST STRESS ==="
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-heap-life.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

clang -O1 -Wall -Werror -o "$WORKDIR/heap_life" "$SCRIPT_DIR/heap_life.c" \
  || fail "heap_life.c did not compile on the host"
clang -O1 -Wall -Werror -o "$WORKDIR/desk_subrect" "$SCRIPT_DIR/desk_subrect.c" \
  || fail "desk_subrect.c did not compile on the host"
capture_sh HEAP_OUT HEAP_ST -- "'$WORKDIR/heap_life'"
echo "$HEAP_OUT"
ck; [[ $HEAP_ST -eq 0 ]] || fail "host heap protocol stress failed"
capture_sh DESK_OUT DESK_ST -- "'$WORKDIR/desk_subrect'"
echo "$DESK_OUT"
ck; [[ $DESK_ST -eq 0 ]] || fail "host desk subrect stress failed"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-heap-life: PASS ($ASSERTIONS_REQUIRED checks) — reset-before-rewind, bounded high-water, subrect blit"
exit 0
