#!/usr/bin/env bash
# core/tests/conformance/de-corner-aa/run.sh
#
# Shared rrect coverage must close every rounded card: 4×4 eighths,
# blend over wallpaper, no AABB through the curve, no binary stair.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "DE-corner-aa: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-corner-aa: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=18

for tool in clang python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-corner-aa.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

HDR="$CORE_DIR/plat/osgfx/osgfx.h"
SKIA="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
DESK="$CORE_DIR/plat/osgfx/osgfx_desk.c"
SESS="$CORE_DIR/plat/osgfx/osgfx_session.c"
CHROME="$CORE_DIR/plat/osgfx/osgfx_chrome.c"
SW="$CORE_DIR/plat/osgfx/osgfx_sw.c"
WM="$CORE_DIR/kernel/wm.dart"
GFX="$CORE_DIR/kernel/wmgfx.dart"
TEST_C="$SCRIPT_DIR/rrect_cover_test.c"

ck; [[ -f "$HDR" ]] || fail "osgfx.h missing"
ck; [[ -f "$TEST_C" ]] || fail "rrect_cover_test.c missing"
ck; grep -q 'static inline int osgfx_rrect_cover' "$HDR" \
  || fail "osgfx.h has no shared osgfx_rrect_cover"
ck; grep -q 'u64 wmRrectCover' "$GFX" \
  || fail "wmgfx.dart has no wmRrectCover"
ck; grep -q 'u64 wmCoverBlend' "$WM" \
  || fail "wm.dart has no wmCoverBlend"
ck; grep -q 'u64 wmUnderWallpaper' "$WM" \
  || fail "wm.dart has no wallpaper underlay helper"
ck; grep -q 'wmRrectCover(px, py, u64(0), u64(0), w, h, u64(wmGfxRadius))' "$WM" \
  || fail "wmBlitRow does not coverage-blend the bottom corner band"
ck; grep -q 'x0 = wmGfxRowInset(py, w, h)' "$WM" \
  || fail "wmGfxRowInset call dropped (de-desk lockstep)"
ck; grep -q 'static int rrect_cover' "$SKIA" \
  || fail "osgfx_skia.cpp lost the rrect_cover name"
ck; grep -q 'return osgfx_rrect_cover' "$SKIA" \
  || fail "osgfx_skia.cpp rrect_cover is not the shared primitive"
ck; grep -q 'return osgfx_rrect_cover' "$DESK" \
  || fail "glass_rrect_cover is not the shared primitive"
ck; grep -q 'osgfx_rrect_cover' "$SW" \
  || fail "osgfx_sw.c fill_rrect is still a binary hit"
ck; grep -q 'paint_border_corner' "$SESS" \
  || fail "session borders have no coverage corner stroke"
ck; ! grep -q 'osgfx_fill_rect(g, x - b, y - b, w + b + b, b + 1, border)' "$SESS" \
  || fail "session still draws an AABB through the rounded corners"
ck; grep -q 'yy < wy + OSGFX_RADIUS' "$CHROME" \
  || fail "chrome_body_span dropped the top-corner chrome inset"
ck; python3 - "$CHROME" <<'PY' || fail "bottom corner squares are still chrome-owned"
import sys
s = open(sys.argv[1]).read()
i = s.find("if (yy >= wy + wh - OSGFX_RADIUS)")
if i < 0:
    raise SystemExit("no bottom-radius arm")
arm = s[i:i + 220]
if "*x0 = wx;" not in arm or "*x1 = wx + ww;" not in arm:
    raise SystemExit("bottom arm is not a full-width client hole")
print("bottom corners are a client hole for coverage blit")
PY

clang -std=c11 -Wall -Wextra -Werror -I "$CORE_DIR/plat/osgfx" \
  -o "$WORKDIR/rrect_cover_test" "$TEST_C" \
  || fail "rrect_cover_test.c did not compile"
capture PIX_OUT PIX_STATUS -- "$WORKDIR/rrect_cover_test"
echo "$PIX_OUT"
ck; [[ $PIX_STATUS -eq 0 ]] || fail "rrect_cover_test exited $PIX_STATUS"
ck; python3 - "$PIX_OUT" <<'PY' || fail "pixel tester reported a failing case"
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
if d.get("pass") != d.get("cases") or d.get("fail") != 0:
    raise SystemExit(str(d))
if d.get("cases", 0) < 40:
    raise SystemExit("too few cases: %s" % d)
print("pixel cases", d["cases"], "pass", d["pass"],
      "corners", d["corners_per_case"], "radii", d["radii"])
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-corner-aa: PASS — shared 4x4 rrect coverage, wallpaper underlay, no AABB teeth"
