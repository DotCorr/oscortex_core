#!/usr/bin/env bash
# core/tests/conformance/de-skia-own/run.sh
#
# Round 12: Skia wrapper ownership + SHM per-client windows + present hold.
# Structural floor. Runtime first-miss / repeated-miss / backing-change /
# rewind is de-desk (BIOS) run twice — that is the cross-boot regression.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "DE-skia-own: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-skia-own: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=21

SKIA="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
CRT="$CORE_DIR/plat/osgfx/osgfx_guest_crt.c"
CHROME="$CORE_DIR/plat/osgfx/osgfx_chrome.c"
SHM="$CORE_DIR/kernel/shm.dart"
WM="$CORE_DIR/kernel/wm.dart"
WMDE="$CORE_DIR/kernel/wmde.dart"
FILES="$CORE_DIR/user/frame/files.c"
FRAME="$CORE_DIR/user/frame/osframe.h"

ck; [[ -f "$SKIA" ]] || fail "osgfx_skia.cpp missing"
ck; [[ -f "$CRT" ]] || fail "osgfx_guest_crt.c missing"
ck; [[ -f "$CHROME" ]] || fail "osgfx_chrome.c missing"
ck; [[ -f "$SHM" ]] || fail "shm.dart missing"
ck; [[ -f "$WM" ]] || fail "wm.dart missing"

echo "=== STRUCTURAL ==="
ck; grep -q 'SKIA_OWN_EMPTY' "$SKIA" \
  || fail "no SKIA_OWN state machine"
ck; grep -q 'bind → paint → flush → drop' "$SKIA" \
  || fail "ownership comment lost the required sequence"
ck; grep -q 'skia_drop_chrome' "$SKIA" \
  || fail "chrome drop is not a named step"
ck; grep -q 'OSGFX SKIA BIND' "$SKIA" \
  || fail "no BIND serial token"
ck; grep -q 'OSGFX SKIA DROP' "$SKIA" \
  || fail "no DROP serial token"
ck; grep -q 'OSGFX SKIA REWIND' "$SKIA" \
  || fail "no REWIND serial token"
ck; grep -q 'owned.release()' "$SKIA" \
  || fail "rewound wrapper still calls reset() instead of leak"
ck; python3 - "$SKIA" <<'PY' || fail "chrome_heap_after_paint still rewinds under a live g_one"
import sys
t = open(sys.argv[1]).read()
h = t.find("static void chrome_heap_after_paint")
he = t.find("\n}", h)
body = t[h:he] if h >= 0 and he > h else ""
sys.exit(0 if body.find("skia_drop_chrome") >= 0 and
              body.find("skia_drop_chrome") < body.find("skia_release_client") else 1)
PY
ck; grep -q 'u64 shmProcMapsReg' "$SHM" \
  || fail "no per-client SHM occupancy"
ck; grep -q 'u64 shmRegsShareAs' "$SHM" \
  || fail "grow still uses a global first-fit"
ck; grep -q 'SYS_SHMSHRINK' "$FRAME" \
  || fail "no SYS_SHMSHRINK"
ck; grep -q 'SYS_SHMSHRINK' "$FILES" \
  || fail "FILES does not reclaim on restore"
ck; grep -q 'wmWin(wI, u64(wmWinSeq)) < u64(1)' "$WM" \
  || fail "present hold is not in wmBlitRow"
ck; grep -q 'wmSetWin(wI, u64(wmWinSeq), u64(0))' "$WMDE" \
  || fail "max/restore does not raise the present-hold token"
ck; grep -q 'Treating them as a full miss was the 1.6s TCG focus hitch' \
     "$CHROME" \
  || fail "focus_only still fails on desk_have / launch churn"
ck; grep -q 'if (heap_chrome_mark == 0)' "$CRT" \
  || fail "client_begin still falls back to the Graphite watermark"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-skia-own: PASS ($ASSERTIONS_REQUIRED checks) — ownership + per-client SHM + hold"
exit 0
