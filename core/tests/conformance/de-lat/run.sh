#!/usr/bin/env bash
# core/tests/conformance/de-lat/run.sh
#
# Anti-vacuity: event→present uses guest PIT ticks / sequence, not UART
# wall-time or a full serial reread. Pointer, wheel, drag, menu, focus
# each stamp a kind; present consumes it and prints WM LAT.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "DE-lat: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-lat: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=16

PACE="$CORE_DIR/kernel/wmpace.dart"
WM="$CORE_DIR/kernel/wm.dart"
POP="$CORE_DIR/kernel/wmpop.dart"
EV="$CORE_DIR/kernel/wmevent.dart"
GUEST_H="$CORE_DIR/plat/osgfx/osgfx_guest.h"
DRIVE="$CORE_DIR/scripts/daily-drive-round5.py"

ck; [[ -f "$PACE" ]] || fail "no wmpace.dart"
ck; grep -q 'void wmLatStamp' "$PACE" || fail "no guest-tick stamp"
ck; grep -q 'void wmLatNotePresent' "$PACE" || fail "no present-tick note"
ck; grep -q 'tick_count()' "$PACE" || fail "latency path does not read PIT ticks"
ck; grep -q 'wmLatStrLine' "$PACE" || fail "no WM LAT UART token"
ck; grep -q 'wmPageWEvTick' "$PACE" || fail "no event-tick page word"
ck; grep -q 'wmPageWEvToPres' "$PACE" || fail "no event-to-present page word"
ck; grep -q 'wmLatKindPtr' "$WM" || fail "pointer path does not stamp"
ck; grep -q 'wmLatKindDrag' "$WM" || fail "drag path does not stamp"
ck; grep -q 'wmLatKindFocus' "$WM" || fail "focus path does not stamp"
ck; grep -q 'wmLatKindWheel' "$EV" || fail "wheel path does not stamp"
ck; grep -q 'wmLatKindMenu' "$POP" || fail "menu path does not stamp"
ck; grep -q 'wmLatNotePresent' "$WM" || fail "compose present does not note latency"
ck; grep -q 'OSGFX_WMPAGE_W_EV_TO_PRES' "$GUEST_H" \
  || fail "guest header has no event-to-present word"
ck; grep -q 'PROC YIELD' "$DRIVE" \
  || fail "driver does not drop YIELD lines from the latency window"
ck; grep -q 'self.off' "$DRIVE" \
  || fail "driver still rereads the UART logfile from offset 0"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-lat: PASS ($ASSERTIONS_REQUIRED checks) — guest tick event→present, not wall time"
exit 0
