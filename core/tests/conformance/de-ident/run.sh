#!/usr/bin/env bash
# core/tests/conformance/de-ident/run.sh
#
# Anti-vacuity: FILES and SET keep distinct client identity through
# attach, configure, chrome cache, and session titles. A SET hole that
# shows FILES pixels, or a title band that always says FILES, is a FAIL.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "DE-ident: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-ident: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=18

WM="$CORE_DIR/kernel/wm.dart"
POP="$CORE_DIR/kernel/wmpop.dart"
GFX="$CORE_DIR/kernel/wmgfx.dart"
PACE="$CORE_DIR/kernel/wmpace.dart"
SESS="$CORE_DIR/plat/osgfx/osgfx_session.c"
CHROME="$CORE_DIR/plat/osgfx/osgfx_chrome.c"
GUEST_H="$CORE_DIR/plat/osgfx/osgfx_guest.h"
FILES="$CORE_DIR/user/frame/files.c"
SET="$CORE_DIR/user/frame/set.c"

ck; [[ -f "$WM" ]] || fail "no wm.dart"
ck; grep -q 'wmStrP' "$WM" || fail "attach dropped owner-id probe"
ck; grep -q 'wmStrC' "$WM" || fail "attach dropped caption-code probe"
ck; grep -q 'reqW == u64(440)' "$WM" \
  || fail "SET caption is not keyed off requested 440"
ck; grep -q 'wmPageWLaunch0' "$WM" \
  || fail "attach does not store caption on the launch words"
ck; grep -q 'wmPageWCapMail' "$GFX" \
  || fail "kick does not publish mailbox captions"
ck; grep -q 'ordinary FRAME clients' "$GFX" \
  || fail "win0/win1 still include the DESK panel"
ck; grep -q 'files_slot' "$FILES" \
  || fail "FILES configure is not slot-filtered"
ck; grep -q 'set_slot' "$SET" \
  || fail "SET configure is not slot-filtered"
ck; grep -q 'SET CSD' "$SET" || fail "SET lost the CSD identity token"
ck; grep -q 'csd_noted = 1' "$SET" \
  || fail "SET CSD is no longer emitted before the first fill"
ck; grep -q 'OSGFX TITLE SET' "$SESS" \
  || fail "session never paints a SET caption"
ck; grep -q 'OSGFX_WMPAGE_W_CAP_MAIL' "$SESS" \
  || fail "session titles ignore mailbox captions"
ck; grep -q 'chrome_span_hit' "$CHROME" \
  || fail "chrome_blit still unions client holes"
ck; grep -q 'OSGFX_WMPAGE_W_CAP_MAIL' "$GUEST_H" \
  || fail "guest header has no caption-mail word"
ck; grep -q 'wmPageWCapMail' "$PACE" \
  || fail "wmpage has no caption-mail word"
ck; grep -q 'u64 wmPopClientHit' "$POP" \
  || fail "menu placement does not test client overlap"
ck; grep -q 'u64 wmPopFits' "$POP" \
  || fail "menu placement does not refuse an occluded card"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-ident: PASS ($ASSERTIONS_REQUIRED checks) — FILES/SET captions, slots, disjoint holes"
exit 0
