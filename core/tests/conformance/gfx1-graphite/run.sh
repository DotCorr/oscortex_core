#!/usr/bin/env bash
# GFX1 — platform osgfx paints a rounded rect through Skia Graphite.
# docs/design/c-modules.md, ADR-0082.
#
# Platform clang++. Not an app ELF. Not Flutter. Not brew graphite2.
#
# Proof:
#   * binaries exist after build-preview-ui.sh
#   * file(1) says arm64 Mach-O
#   * nm shows osgfx_fill_rrect AND a real Graphite symbol
#     (skgpu::graphite / MakeMetal) — osgfx_backend_graphite alone is
#     not enough (a stub .cpp that calls Metal would export that)
#   * default headless BACKEND is graphite; AABB corner is desktop
#   * --square PPM: same corner is TITLE (negative control)
#   * OSGFX_FORCE_METAL=1 is metal and still rrects — fallback exists,
#     Graphite stays in the binary (nm still has skgpu::graphite)
# Anti-vacuity: TITLE != DESK; RADIUS != 0; graphite .mm calls drawRRect.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "GFX1-graphite: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GFX1-graphite: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=40

for tool in clang++ python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-gfx1.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-preview-ui.sh"
SKIA_BUILD="$CORE_DIR/scripts/build-skia-graphite.sh"
HEADLESS="$CORE_DIR/build/osgfx-headless"
DERIVE="$SCRIPT_DIR/../gfx0-host/derive.py"
HDR="$CORE_DIR/plat/osgfx/osgfx.h"
GRAPHITE_MM="$CORE_DIR/plat/osgfx/osgfx_graphite.mm"
SKIA_LIB="$CORE_DIR/build/skia/out/graphite/libskia.a"

ck; [[ -f "$BUILD" ]] || fail "no build-preview-ui.sh"
ck; [[ -f "$SKIA_BUILD" ]] || fail "no build-skia-graphite.sh"
ck; [[ -f "$HDR" ]] || fail "no osgfx.h"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"
ck; [[ -f "$GRAPHITE_MM" ]] || fail "no osgfx_graphite.mm"

# Restated from osgfx.h — the harness owns the expectation.
RADIUS=14
DESK=0x00184060
TITLE=0x00E8E0D0
WIN_W=240
WIN_H=160

ck; [[ $RADIUS -gt 0 ]] || fail "radius is zero"
ck; [[ $((WIN_W * WIN_H)) -gt 0 ]] || fail "window area is zero"
ck; [[ $TITLE -ne $DESK ]] || fail "TITLE equals DESK"

# The header and derive.py's copy must AGREE; neither number is typed here.
# This used to be `grep -q 'OSGFX_X = <literal>'`, a THIRD copy of the same
# fact, so ADR-0187's chrome redesign (pearl title band, elevated slate
# taskbar, softer corner radius) had to be transcribed into three places and
# was transcribed into one. derive.py stays a hand-edited double entry -- that
# is the point of it -- but the harness now checks the pair rather than
# remembering a value of its own.
HDR_RADIUS=$(awk -F'= *' '/OSGFX_RADIUS *=/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$HDR")
PY_RADIUS=$(python3 - "$DERIVE" <<'PYX'
import re, sys
m = re.search(r"^RADIUS = (\S+)", open(sys.argv[1]).read(), re.M)
print(m.group(1) if m else "")
PYX
)
ck; [[ -n "$HDR_RADIUS" && -n "$PY_RADIUS" ]] \
  || fail "could not read OSGFX_RADIUS out of $HDR or RADIUS out of $DERIVE"
ck; [[ $(( HDR_RADIUS )) -eq $(( PY_RADIUS )) ]] \
  || fail "OSGFX_RADIUS is $HDR_RADIUS in the header but derive.py's RADIUS is $PY_RADIUS — the harness is measuring against a colour/size the module no longer paints"
ck; grep -q 'OSGFX_DESK = 0x00184060' "$HDR" || fail "osgfx.h DESK moved without derive.py"
ck; grep -q 'OSGFX_TITLE = 0x00E8E0D0' "$HDR" || fail "osgfx.h TITLE moved without derive.py"

# A stub .cpp that only calls Metal is a FAIL — the Graphite TU must
# actually name Graphite types and draw an SkRRect.
ck; grep -q 'skgpu::graphite::ContextFactory::MakeMetal' "$GRAPHITE_MM" \
  || fail "osgfx_graphite.mm does not call ContextFactory::MakeMetal"
ck; grep -q 'canvas->drawRRect' "$GRAPHITE_MM" \
  || fail "osgfx_graphite.mm does not drawRRect"
ck; grep -q 'include/gpu/graphite' "$GRAPHITE_MM" \
  || fail "osgfx_graphite.mm has no Graphite include"
# The Graphite fill_rrect path must push a Graphite command, not only
# forward to Metal. Metal dispatch is allowed on the fallback kind.
ck; grep -A20 'void osgfx_fill_rrect' "$GRAPHITE_MM" | grep -q 'push_cmd' \
  || fail "osgfx_fill_rrect does not record a Graphite command"

echo "=== BUILD (platform clang++ + Skia Graphite) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' --headless 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-preview-ui.sh exited $BUILD_STATUS"
ck; [[ -x "$HEADLESS" ]] || fail "no osgfx-headless"
ck; [[ -f "$SKIA_LIB" ]] || fail "no libskia.a — Graphite was not built"

capture_sh FILE_OUT FILE_STATUS -- "file '$HEADLESS'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "headless is not Mach-O (do not use none-elf)"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "headless is ELF — wrong toolchain"
fi
ck; echo "$FILE_OUT" | grep -q 'arm64' || fail "headless is not arm64"

NM_FILE="$WORKDIR/nm.txt"
capture_sh NM_OUT NM_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM_STATUS -eq 0 ]] || fail "nm failed"
printf '%s\n' "$NM_OUT" > "$NM_FILE"
ck; grep -q 'osgfx_fill_rrect' "$NM_FILE" || fail "osgfx_fill_rrect not in the binary"
ck; grep -q 'osgfx_backend_graphite' "$NM_FILE" \
  || fail "osgfx_backend_graphite not in the binary"
# Real Skia Graphite, not a comment and not brew graphite2.
ck; grep -qE 'skgpu.*graphite|graphite.*MakeMetal|ContextFactory' "$NM_FILE" \
  || fail "no skgpu::graphite symbol — stub .cpp that only names osgfx_backend_graphite"

echo "=== HEADLESS rrect (Graphite) ==="
unset OSGFX_FORCE_METAL
capture_sh RRECT_OUT RRECT_STATUS -- "'$HEADLESS' -o '$WORKDIR/rrect.ppm'"
echo "$RRECT_OUT"
ck; [[ $RRECT_STATUS -eq 0 ]] || fail "headless rrect exited $RRECT_STATUS"
ck; echo "$RRECT_OUT" | grep -q 'BACKEND graphite' \
  || fail "default path is not Graphite (got: $RRECT_OUT)"
ck; [[ -f "$WORKDIR/rrect.ppm" ]] || fail "no rrect.ppm"

capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/rrect.ppm' rrect"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive rrect failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'RRECT_OK' || fail "no RRECT_OK"

echo "=== HEADLESS square (negative) ==="
capture_sh SQ_OUT SQ_STATUS -- "'$HEADLESS' --square -o '$WORKDIR/square.ppm'"
echo "$SQ_OUT"
ck; [[ $SQ_STATUS -eq 0 ]] || fail "headless square exited $SQ_STATUS"
ck; echo "$SQ_OUT" | grep -q 'BACKEND graphite' || fail "square path left Graphite"

capture_sh DS_OUT DS_STATUS -- "python3 '$DERIVE' '$WORKDIR/square.ppm' square"
echo "$DS_OUT"
ck; [[ $DS_STATUS -eq 0 ]] || fail "derive square failed: $DS_OUT"
ck; echo "$DS_OUT" | grep -q 'SQUARE_OK' || fail "no SQUARE_OK"

capture_sh DIFF_OUT DIFF_STATUS -- "python3 -c \"
import pathlib
a=pathlib.Path('$WORKDIR/rrect.ppm').read_bytes()
b=pathlib.Path('$WORKDIR/square.ppm').read_bytes()
raise SystemExit(0 if a!=b else 1)
\""
ck; [[ $DIFF_STATUS -eq 0 ]] || fail "rrect and square PPMs are identical"

echo "=== FORCE METAL fallback (negative: Graphite still linked) ==="
capture_sh METAL_OUT METAL_STATUS -- "OSGFX_FORCE_METAL=1 '$HEADLESS' -o '$WORKDIR/metal.ppm'"
echo "$METAL_OUT"
ck; [[ $METAL_STATUS -eq 0 ]] || fail "force-metal rrect exited $METAL_STATUS"
ck; echo "$METAL_OUT" | grep -q 'BACKEND metal' || fail "OSGFX_FORCE_METAL did not select metal"
if echo "$METAL_OUT" | grep -q 'BACKEND graphite'; then
  fail "force-metal still says graphite"
fi

capture_sh DM_OUT DM_STATUS -- "python3 '$DERIVE' '$WORKDIR/metal.ppm' rrect"
echo "$DM_OUT"
ck; [[ $DM_STATUS -eq 0 ]] || fail "derive force-metal rrect failed: $DM_OUT"

# Graphite symbols must survive the metal-fallback run — they were linked,
# not imagined. Re-check nm after the metal path so a "Metal-only rebuild"
# cannot sneak through.
capture_sh NM2_OUT NM2_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM2_STATUS -eq 0 ]] || fail "nm after metal path failed"
printf '%s\n' "$NM2_OUT" > "$WORKDIR/nm2.txt"
ck; grep -qE 'skgpu.*graphite|graphite.*MakeMetal|ContextFactory' "$WORKDIR/nm2.txt" \
  || fail "Graphite symbols gone after metal fallback"

require_assertions "$ASSERTIONS_REQUIRED"
echo "GFX1-graphite: PASS — Skia Graphite linked; rrect corner is desktop; metal fallback is a negative ($ASSERTIONS checks)"
