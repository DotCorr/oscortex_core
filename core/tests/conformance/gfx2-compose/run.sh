#!/usr/bin/env bash
# GFX-COMPOSE — session chrome through osgfx / Skia Graphite.
# docs/design/c-modules.md, docs/design/osx-ui.md, ADR-0094.
#
# One scene = compositor policy (same colours/sizes as wm chrome).
# Rasterised by Graphite via osgfx only. Not a second CPU box painter.
# Not sit-in. Not Flutter. Not preview.html. Not Vulkan GFX2.
#
# Proof:
#   * default --compose BACKEND is graphite
#   * nm shows osgfx_fill_rrect / osgfx_shadow AND skgpu::graphite
#   * scene calls fill_rrect + shadow (not a CPU blit loop)
#   * derived pixels: desktop, title, chrome, popover, focus, unfocus
#   * AABB corners are desktop (rrect), not title / pop / box border
#   * --square is the box-painter negative
#   * OSGFX_FORCE_METAL=1 is metal — must not be this PASS
# Anti-vacuity: policy colours differ; radius != 0; popover area != 0.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "GFX2-compose: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GFX2-compose: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=66

for tool in clang++ python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-gfx2-compose.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-preview-ui.sh"
HEADLESS="$CORE_DIR/build/osgfx-headless"
DERIVE="$SCRIPT_DIR/derive.py"
HDR="$CORE_DIR/plat/osgfx/osgfx.h"
SCENE="$CORE_DIR/plat/osgfx/osgfx_scene.c"
GRAPHITE_MM="$CORE_DIR/plat/osgfx/osgfx_graphite.mm"
WM="$CORE_DIR/kernel/wm.dart"
CHROME="$CORE_DIR/kernel/wmchrome.dart"
POP="$CORE_DIR/kernel/wmpop.dart"
SKIA_LIB="$CORE_DIR/build/skia/out/graphite/libskia.a"

ck; [[ -f "$BUILD" ]] || fail "no build-preview-ui.sh"
ck; [[ -f "$HDR" ]] || fail "no osgfx.h"
ck; [[ -f "$SCENE" ]] || fail "no osgfx_scene.c"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"
ck; [[ -f "$GRAPHITE_MM" ]] || fail "no osgfx_graphite.mm"
ck; [[ -f "$WM" ]] || fail "no wm.dart"
ck; [[ -f "$CHROME" ]] || fail "no wmchrome.dart"
ck; [[ -f "$POP" ]] || fail "no wmpop.dart"

# Restated compositor policy — the harness owns the expectation.
DESK=0x00184060
CHROME_C=0x00344050
TITLE=0x00E8E0D0
POP_C=0x00C04088
FOCUS=0x00F0F0F0
UNFOCUS=0x00505860
CHROME_H=40
TITLE_H=28
BORDER=2
POP_W=$(awk -F'= *' '/^const int wmPopW /{gsub(/[^0-9]/,"",$2); print $2; exit}' "$POP")
POP_H=$(awk -F'= *' '/^const int wmPopH /{gsub(/[^0-9]/,"",$2); print $2; exit}' "$POP")
[[ -n "$POP_W" && -n "$POP_H" ]] || fail "could not read wmPopW/H from wmpop.dart"
RADIUS=12

ck; [[ $RADIUS -gt 0 ]] || fail "radius is zero"
ck; [[ $BORDER -gt 0 ]] || fail "border is zero"
ck; [[ $((POP_W * POP_H)) -gt 0 ]] || fail "popover area is zero"
ck; [[ $TITLE -ne $DESK ]] || fail "TITLE equals DESK"
ck; [[ $CHROME_C -ne $DESK ]] || fail "CHROME equals DESK"
ck; [[ $POP_C -ne $DESK ]] || fail "POP equals DESK"
ck; [[ $POP_C -ne $CHROME_C ]] || fail "POP equals CHROME"
ck; [[ $FOCUS -ne $UNFOCUS ]] || fail "FOCUS equals UNFOCUS"

# Header and kernel still name the same policy.
ck; grep -q 'OSGFX_DESK = 0x00184060' "$HDR" || fail "osgfx.h DESK moved"
ck; grep -q 'OSGFX_CHROME = 0x00344050' "$HDR" || fail "osgfx.h CHROME moved"
ck; grep -q 'OSGFX_TITLE = 0x00E8E0D0' "$HDR" || fail "osgfx.h TITLE moved"
ck; grep -q 'OSGFX_POP = 0x00C04088' "$HDR" || fail "osgfx.h POP moved"
# The header and derive.py's copy must AGREE; neither number is typed here.
# This used to be `grep -q 'OSGFX_X = <literal>'`, a THIRD copy of the same
# fact, so ADR-0187's chrome redesign (pearl title band, elevated slate
# taskbar, softer corner radius) had to be transcribed into three places and
# was transcribed into one. derive.py stays a hand-edited double entry -- that
# is the point of it -- but the harness now checks the pair rather than
# remembering a value of its own.
HDR_FOCUS=$(awk -F'= *' '/OSGFX_FOCUS *=/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$HDR")
PY_FOCUS=$(python3 - "$DERIVE" <<'PYX'
import re, sys
m = re.search(r"^FOCUS = (\S+)", open(sys.argv[1]).read(), re.M)
print(m.group(1) if m else "")
PYX
)
ck; [[ -n "$HDR_FOCUS" && -n "$PY_FOCUS" ]] \
  || fail "could not read OSGFX_FOCUS out of $HDR or FOCUS out of $DERIVE"
ck; [[ $(( HDR_FOCUS )) -eq $(( PY_FOCUS )) ]] \
  || fail "OSGFX_FOCUS is $HDR_FOCUS in the header but derive.py's FOCUS is $PY_FOCUS — the harness is measuring against a colour/size the module no longer paints"
# The header and derive.py's copy must AGREE; neither number is typed here.
# This used to be `grep -q 'OSGFX_X = <literal>'`, a THIRD copy of the same
# fact, so ADR-0187's chrome redesign (pearl title band, elevated slate
# taskbar, softer corner radius) had to be transcribed into three places and
# was transcribed into one. derive.py stays a hand-edited double entry -- that
# is the point of it -- but the harness now checks the pair rather than
# remembering a value of its own.
HDR_UNFOCUS=$(awk -F'= *' '/OSGFX_UNFOCUS *=/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$HDR")
PY_UNFOCUS=$(python3 - "$DERIVE" <<'PYX'
import re, sys
m = re.search(r"^UNFOCUS = (\S+)", open(sys.argv[1]).read(), re.M)
print(m.group(1) if m else "")
PYX
)
ck; [[ -n "$HDR_UNFOCUS" && -n "$PY_UNFOCUS" ]] \
  || fail "could not read OSGFX_UNFOCUS out of $HDR or UNFOCUS out of $DERIVE"
ck; [[ $(( HDR_UNFOCUS )) -eq $(( PY_UNFOCUS )) ]] \
  || fail "OSGFX_UNFOCUS is $HDR_UNFOCUS in the header but derive.py's UNFOCUS is $PY_UNFOCUS — the harness is measuring against a colour/size the module no longer paints"
ck; grep -q 'OSGFX_CHROME_H = 48' "$HDR" || fail "osgfx.h CHROME_H moved"
ck; grep -q 'OSGFX_TITLE_H = 32' "$HDR" || fail "osgfx.h TITLE_H moved"
HDR_BORDER=$(awk -F'= *' '/OSGFX_BORDER *=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$HDR")
PY_BORDER=$(awk -F'= *' '/^BORDER = /{print $2; exit}' "$DERIVE")
ck; [[ -n "$HDR_BORDER" && -n "$PY_BORDER" ]] \
  || fail "could not read OSGFX_BORDER out of $HDR or BORDER out of $DERIVE"
ck; [[ "$HDR_BORDER" -eq "$PY_BORDER" ]] \
  || fail "OSGFX_BORDER is $HDR_BORDER in the header but derive.py's BORDER is $PY_BORDER — the harness is measuring against a border width the module no longer paints"
HDR_POP_W=$(awk -F'= *' '/OSGFX_POP_W *=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$HDR")
HDR_POP_H=$(awk -F'= *' '/OSGFX_POP_H *=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$HDR")
ck; [[ -n "$HDR_POP_W" && -n "$HDR_POP_H" ]] \
  || fail "could not read OSGFX_POP_W/H from osgfx.h"
ck; [[ "$HDR_POP_W" -eq "$POP_W" ]] \
  || fail "OSGFX_POP_W is $HDR_POP_W but wmPopW is $POP_W — preview and live menu geometry must match"
ck; [[ "$HDR_POP_H" -eq "$POP_H" ]] \
  || fail "OSGFX_POP_H is $HDR_POP_H but wmPopH is $POP_H — preview and live menu geometry must match"
HDR_RADIUS=$(awk -F'= *' '/OSGFX_RADIUS *=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$HDR")
PY_RADIUS=$(awk -F'= *' '/^RADIUS = /{print $2; exit}' "$DERIVE")
ck; [[ -n "$HDR_RADIUS" && -n "$PY_RADIUS" ]] \
  || fail "could not read OSGFX_RADIUS out of $HDR or RADIUS out of $DERIVE"
ck; [[ "$HDR_RADIUS" -eq "$PY_RADIUS" ]] \
  || fail "OSGFX_RADIUS is $HDR_RADIUS in the header but derive.py's RADIUS is $PY_RADIUS — the harness is measuring against a corner radius the module no longer paints"
ck; grep -q 'wmColorDesktop = 0x00184060' "$WM" || fail "wm.dart desktop moved"
ck; grep -q 'wmColorFocus = 0x00F0F0F0' "$WM" || fail "wm.dart focus moved"
ck; grep -q 'wmColorUnfocus = 0x00505860' "$WM" || fail "wm.dart unfocus moved"
ck; grep -q 'wmBorder = 3' "$WM" || fail "wm.dart border moved"
ck; grep -q 'wmChromeColor = 0x00344050' "$CHROME" || fail "wmchrome colour moved"
ck; grep -q 'wmChromeH = 48' "$CHROME" || fail "wmchrome H moved"
ck; grep -q 'wmTitleColor = 0x00E8E0D0' "$CHROME" || fail "wmtitle colour moved"
ck; grep -q 'wmTitleH = 32' "$CHROME" || fail "wmtitle H moved"
ck; grep -q 'wmPopColor = 0x00F4F6FA' "$POP" || fail "wmpop live card colour moved"
ck; grep -q 'u64 wmPopKind' "$POP" || fail "wmpop has no kind/hover model"
ck; grep -q 'u64 wmPopHoverTick' "$POP" || fail "wmpop has no pointer hover"
ck; grep -q 'u64 wmPopKey' "$POP" || fail "wmpop has no keyboard selection"
ck; grep -q 'u64 wmPopRowDisabled' "$POP" || fail "wmpop has no disabled rows"
ck; grep -q 'void wmPopWritePage' "$POP" || fail "wmpop does not publish hover to the session"

# Compose scene must speak osgfx (rrect + shadow), not a CPU box loop.
ck; grep -q 'void osgfx_scene_compose' "$SCENE" || fail "no osgfx_scene_compose"
ck; grep -A30 'void osgfx_scene_compose' "$SCENE" | grep -q 'osgfx_fill_rrect' \
  || fail "compose scene does not call osgfx_fill_rrect"
ck; grep -A30 'void osgfx_scene_compose' "$SCENE" | grep -q 'osgfx_shadow' \
  || fail "compose scene does not call osgfx_shadow"
if grep -A40 'void osgfx_scene_compose' "$SCENE" | grep -qE 'cpu\[|pixels\[|memset'; then
  fail "compose scene has a CPU pixel blit"
fi
ck; grep -q 'canvas->drawRRect' "$GRAPHITE_MM" \
  || fail "osgfx_graphite.mm does not drawRRect"

echo "=== BUILD (platform clang++ + Skia Graphite) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' --headless 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-preview-ui.sh exited $BUILD_STATUS"
ck; [[ -x "$HEADLESS" ]] || fail "no osgfx-headless"
ck; [[ -f "$SKIA_LIB" ]] || fail "no libskia.a — Graphite was not built"

capture_sh FILE_OUT FILE_STATUS -- "file '$HEADLESS'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "headless is not Mach-O"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "headless is ELF — wrong toolchain"
fi
ck; echo "$FILE_OUT" | grep -q 'arm64' || fail "headless is not arm64"

NM_FILE="$WORKDIR/nm.txt"
capture_sh NM_OUT NM_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM_STATUS -eq 0 ]] || fail "nm failed"
printf '%s\n' "$NM_OUT" > "$NM_FILE"
ck; grep -q 'osgfx_fill_rrect' "$NM_FILE" || fail "osgfx_fill_rrect not in the binary"
ck; grep -q 'osgfx_shadow' "$NM_FILE" || fail "osgfx_shadow not in the binary"
ck; grep -q 'osgfx_scene_compose' "$NM_FILE" || fail "osgfx_scene_compose not in the binary"
ck; grep -qE 'skgpu.*graphite|graphite.*MakeMetal|ContextFactory' "$NM_FILE" \
  || fail "no skgpu::graphite symbol — a Metal-only stub is not this PASS"

echo "=== HEADLESS compose (Graphite) ==="
unset OSGFX_FORCE_METAL
capture_sh COMP_OUT COMP_STATUS -- "'$HEADLESS' --compose -o '$WORKDIR/compose.ppm'"
echo "$COMP_OUT"
ck; [[ $COMP_STATUS -eq 0 ]] || fail "headless compose exited $COMP_STATUS"
ck; echo "$COMP_OUT" | grep -q 'BACKEND graphite' \
  || fail "compose default path is not Graphite (got: $COMP_OUT)"
if echo "$COMP_OUT" | grep -q 'BACKEND metal'; then
  fail "compose path says metal — OSGFX_FORCE_METAL or missing Graphite is not this PASS"
fi
ck; [[ -f "$WORKDIR/compose.ppm" ]] || fail "no compose.ppm"

capture_sh DC_OUT DC_STATUS -- "python3 '$DERIVE' '$WORKDIR/compose.ppm' compose"
echo "$DC_OUT"
ck; [[ $DC_STATUS -eq 0 ]] || fail "derive compose failed: $DC_OUT"
ck; echo "$DC_OUT" | grep -q 'COMPOSE_OK' || fail "no COMPOSE_OK"

echo "=== HEADLESS compose square (negative: box painter) ==="
capture_sh SQ_OUT SQ_STATUS -- "'$HEADLESS' --compose --square -o '$WORKDIR/square.ppm'"
echo "$SQ_OUT"
ck; [[ $SQ_STATUS -eq 0 ]] || fail "headless compose square exited $SQ_STATUS"
ck; echo "$SQ_OUT" | grep -q 'BACKEND graphite' || fail "square path left Graphite"

capture_sh DS_OUT DS_STATUS -- "python3 '$DERIVE' '$WORKDIR/square.ppm' square"
echo "$DS_OUT"
ck; [[ $DS_STATUS -eq 0 ]] || fail "derive square failed: $DS_OUT"
ck; echo "$DS_OUT" | grep -q 'SQUARE_OK' || fail "no SQUARE_OK"

capture_sh DIFF_OUT DIFF_STATUS -- "python3 -c \"
import pathlib
a=pathlib.Path('$WORKDIR/compose.ppm').read_bytes()
b=pathlib.Path('$WORKDIR/square.ppm').read_bytes()
raise SystemExit(0 if a!=b else 1)
\""
ck; [[ $DIFF_STATUS -eq 0 ]] || fail "compose and square PPMs are identical"

echo "=== FORCE METAL (negative: must not count as Graphite PASS) ==="
capture_sh METAL_OUT METAL_STATUS -- "OSGFX_FORCE_METAL=1 '$HEADLESS' --compose -o '$WORKDIR/metal.ppm'"
echo "$METAL_OUT"
ck; [[ $METAL_STATUS -eq 0 ]] || fail "force-metal compose exited $METAL_STATUS"
ck; echo "$METAL_OUT" | grep -q 'BACKEND metal' || fail "OSGFX_FORCE_METAL did not select metal"
if echo "$METAL_OUT" | grep -q 'BACKEND graphite'; then
  fail "force-metal still says graphite"
fi
# Metal may still rrect; it is not this PASS. Graphite must remain linked.
capture_sh NM2_OUT NM2_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM2_STATUS -eq 0 ]] || fail "nm after metal path failed"
printf '%s\n' "$NM2_OUT" > "$WORKDIR/nm2.txt"
ck; grep -qE 'skgpu.*graphite|graphite.*MakeMetal|ContextFactory' "$WORKDIR/nm2.txt" \
  || fail "Graphite symbols gone after metal fallback"

require_assertions "$ASSERTIONS_REQUIRED"
echo "GFX2-compose: PASS — session chrome through osgfx/Graphite; rrects+shadow; policy pixels; metal is negative ($ASSERTIONS checks)"
