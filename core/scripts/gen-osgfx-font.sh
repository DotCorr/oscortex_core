#!/usr/bin/env bash
# core/scripts/gen-osgfx-font.sh
#
# Regenerate core/plat/osgfx/osgfx_font_data.c — the real TrueType glyph
# OUTLINES that osgfx_text() replays into an SkPath for live Skia
# rasterisation (ADR-0187). Not a bitmap dump, not a coverage-mask bake.
#
# The face is Roboto (Apache-2.0), which is the font Flutter and Material
# ship, i.e. the exact thing the DE chrome is being measured against. It is
# already in this tree under the vendored Dart SDK's devtools assets, so the
# build needs no network and no new vendored binary.
#
# Exit: 0 on success, 1 on failure, 2 on setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "gen-osgfx-font: FAIL — $1" >&2; exit 1; }
setup_error() { echo "gen-osgfx-font: FAIL — $1" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || setup_error "python3 not on PATH"

OUT="$CORE_DIR/plat/osgfx/osgfx_font_data.c"

find_face() {
  local leaf="$1" p
  for p in \
    "$CORE_DIR/build/host-dart/dart-sdk/bin/resources/devtools/assets/fonts/Roboto/$leaf" \
    "$CORE_DIR/build/host-dart/dart-sdk/bin/resources/devtools/assets/packages/devtools_app_shared/fonts/Roboto/$leaf" \
    "/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/$leaf"
  do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

REG="$(find_face Roboto-Regular.ttf)" \
  || setup_error "no Roboto-Regular.ttf found (looked in the vendored Dart SDK devtools assets and the Flutter material_fonts cache)"
MED="$(find_face Roboto-Medium.ttf)" \
  || setup_error "no Roboto-Medium.ttf found"

echo "gen-osgfx-font: regular $REG"
echo "gen-osgfx-font: medium  $MED"

python3 "$SCRIPT_DIR/gen-osgfx-font.py" "$OUT" \
  "regular=$REG" "medium=$MED" || fail "gen-osgfx-font.py failed"

# Independent check: rasterise the GENERATED C with a second, non-Skia
# scanline filler. A bad verb stream shows up here, on the host, before it
# costs a kernel build.
python3 "$SCRIPT_DIR/check-osgfx-font.py" "$OUT" \
  "$CORE_DIR/build/font-check.png" medium 22 \
  || fail "check-osgfx-font.py could not rasterise the generated table"

echo "gen-osgfx-font: PASS — $OUT"
exit 0
