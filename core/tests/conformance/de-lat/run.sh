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

ASSERTIONS_REQUIRED=32

PACE="$CORE_DIR/kernel/wmpace.dart"
WM="$CORE_DIR/kernel/wm.dart"
POP="$CORE_DIR/kernel/wmpop.dart"
EV="$CORE_DIR/kernel/wmevent.dart"
PROC="$CORE_DIR/kernel/proc.dart"
GUEST_H="$CORE_DIR/plat/osgfx/osgfx_guest.h"
SESSION_C="$CORE_DIR/plat/osgfx/osgfx_session.c"
CHROME_C="$CORE_DIR/plat/osgfx/osgfx_chrome.c"
DRIVE="$CORE_DIR/scripts/daily-drive-round8.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
ART="$CORE_DIR/scripts/artifacts-dir.sh"

ck; [[ -f "$PACE" ]] || fail "no wmpace.dart"
ck; grep -q 'void wmLatStamp' "$PACE" || fail "no guest-tick stamp"
ck; grep -q 'void wmLatNotePresent' "$PACE" || fail "no present-tick note"
ck; grep -q 'tick_count()' "$PACE" || fail "latency path does not read PIT ticks"
ck; grep -q 'wmLatStrLine' "$PACE" || fail "no WM LAT UART token"
ck; grep -q 'wmPageWEvTick' "$PACE" || fail "no event-tick page word"
ck; grep -q 'wmPageWEvToPres' "$PACE" || fail "no event-to-present page word"
ck; grep -q 'wmLatStamp(u64(wmLatKindPtr))' "$WM" \
  || fail "pointer path does not stamp"
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
ck; grep -q 'wmLatStrG' "$PACE" \
  || fail "present note does not print chrome-regen (TCG vs schedule)"
ck; awk '/void wmPointerTick/{p=1} p&&/wmLatStamp\(u64\(wmLatKindPtr\)\)/{s=1} s&&/wmLatNotePresent/{ok=1} END{exit ok?0:1}' "$WM" \
  || fail "pointer LAT is not stamped and noted on the sprite path"
ck; grep -q 'osgfx_chrome_is_focus_only' "$CHROME_C" \
  || fail "chrome cache has no focus-only incremental path"
ck; grep -q 'skip_soft_shadow' "$SESSION_C" \
  || fail "session still always paints the 18px window shadow"
ck; grep -q 'osgfx_session_patch_focus' "$SESSION_C" \
  || fail "session has no focus-border patch"
ck; grep -q 'wmLatNotePresent' "$PACE" \
  && awk '/void wmSessionRestore/{p=1} p&&/wmLatNotePresent/{ok=1} END{exit ok?0:1}' "$PACE" \
  || fail "session restore does not note LAT after the C tick (focus inherits maximize)"
ck; awk '/void wmPointerTick/{p=1} p&&/wmDamageRect\(ox, oy/{ok=1} END{exit ok?0:1}' "$WM" \
  || fail "pointer path does not dirty old+new cursor bounds"
ck; grep -q 'wmMetaGfx' "$PROC" \
  || fail "procYield is not gated under wm gfx (COM1 flood)"
ck; grep -q -- '--absent' "$PROBE" \
  || fail "probe.py has no --absent (start_tile still prints MISMATCH on success)"
ck; [[ -f "$ART" ]] || fail "no artifacts-dir.sh"
ck; grep -q 'PROBE_XY = (120, 180)' "$DRIVE" \
  || fail "round8 driver does not pin the (120,180) probe"
ck; grep -q 'lat_seq_gaps' "$DRIVE" \
  || fail "driver has no LAT drop detection"
ck; grep -q 'osgfx_chrome_is_geom_only' "$CHROME_C" \
  || fail "chrome cache has no geom-only incremental path"
ck; grep -q 'def wait_present' "$DRIVE" \
  || fail "driver has no host event→present pairing"
ck; grep -q 'sock-only' "$DRIVE" \
  || fail "driver does not document sock-only live ingest"
ck; grep -q 'wmPaceLogging' "$PROC" \
  || fail "procYield is not opt-in under wm pace log"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-lat: PASS ($ASSERTIONS_REQUIRED checks) — guest tick + host wall-time pairing"
exit 0
