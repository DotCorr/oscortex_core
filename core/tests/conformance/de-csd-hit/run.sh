#!/usr/bin/env bash
# Static lockstep: title-control layout is one formula for paint + hit-test
# after move/resize/max/restore, and close reaps slot/SHM/cache.
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WMDE="$CORE_DIR/kernel/wmde.dart"
WM="$CORE_DIR/kernel/wm.dart"
CHROME="$CORE_DIR/plat/osgfx/osgfx_chrome.c"
SESS="$CORE_DIR/plat/osgfx/osgfx_session.c"
fail() { echo "FAIL: $*" >&2; exit 1; }
ck() { "$@"; }

ck; grep -q 'const int wmBtnPadY = 7' "$WMDE" \
  || fail "wmBtnPadY is not 7 (SESS_BTN_PAD_Y lockstep)"
ck; grep -q 'SESS_BTN_PAD_Y = 7' "$SESS" \
  || fail "SESS_BTN_PAD_Y drifted from wmBtnPadY"
ck; python3 - "$WMDE" "$SESS" "$CHROME" "$WM" <<'PY' || fail "CSD lockstep source-of-truth checks"
import re, sys
wmde, sess, chrome, wm = [open(p).read() for p in sys.argv[1:]]

def fn(src, name):
    m = re.search(r"u64 %s\(" % name, src)
    if not m:
        raise SystemExit("missing %s" % name)
    rest = src[m.start():]
    nxt = re.search(r"\n(@bare\n)?(u64|void) \w+\(", rest[8:])
    return rest[: (8 + nxt.start())] if nxt else rest

close_x = fn(wmde, "wmCloseX")
btn_y = fn(wmde, "wmBtnY")
if "wmHitGeom" not in close_x and "wmViewGeom" not in close_x:
    raise SystemExit("wmCloseX does not use committed/visible geom")
if "wmHitAbsX(wI)" not in close_x and "wmAbsX(wI)" not in close_x:
    raise SystemExit("wmCloseX does not use hit/abs X")
if "wmGeomX(g)" in close_x and "AbsX" not in close_x:
    raise SystemExit("wmCloseX still uses packed geom X only")
if "wmHitGeom" not in btn_y and "wmViewGeom" not in btn_y:
    raise SystemExit("wmBtnY does not use committed/visible geom")
if "wmHitAbsY" not in btn_y and "wmAbsY" not in btn_y:
    raise SystemExit("wmBtnY does not use hit/abs Y")
if "wmBtnPadY" not in btn_y:
    raise SystemExit("wmBtnY does not use wmBtnPadY")
if "win_close_x" not in sess or "SESS_BTN_GAP" not in sess:
    raise SystemExit("session paint lost win_close_x")
if "chrome_shift_geom" not in chrome or "old_cx" not in chrome:
    raise SystemExit("chrome_drag_apply does not follow blit with geom shift")
if "wmDeCsdRelease" not in wmde or "wmDeCsdRelease" not in wm:
    raise SystemExit("pointer up does not call wmDeCsdRelease")
close_fn = wmde[wmde.index("void wmCloseWindow"):wmde.index("void wmMinWindow")]
if "wmPageWChromeHave" not in close_fn:
    raise SystemExit("wmCloseWindow does not invalidate chrome cache")
if "wmLifeNote" not in close_fn:
    raise SystemExit("wmCloseWindow does not report reclaim")
if "wmPageWLaunch0" not in close_fn:
    raise SystemExit("wmCloseWindow does not clear launch/cap word")
grab = wmde[wmde.index("u64 wmDeGrab("):wmde.index("void wmDeCmd(")]
if grab.find("wmDeGeomHit(") > grab.find("wmCloseHit("):
    raise SystemExit("CSD still hits before title geom")
if "while (i < u64(wmMaxWindows))" in grab[:grab.find("wmCloseHit(")]:
    raise SystemExit("CSD still walks every slot")
print("de-csd-hit static PASS")
PY
echo "de-csd-hit: PASS"
