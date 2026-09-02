#!/usr/bin/env bash
# GFX0 / CMOD1 — platform osgfx paints a rounded rect on Metal.
# docs/design/c-modules.md, ADR-0080.
#
# Platform clang. Not an app ELF. Not preview.html.
#
# Proof:
#   * binaries exist after build-preview-ui.sh
#   * file(1) says arm64 Mach-O, not ELF
#   * nm shows osgfx_fill_rrect
#   * headless PPM: AABB corner is desktop, title interior is TITLE
#   * --square PPM: same corner is TITLE (negative control)
# Anti-vacuity: TITLE != DESK; RADIUS != 0; window area != 0.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "GFX0-host: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GFX0-host: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=25

for tool in clang python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-gfx0.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-preview-ui.sh"
HEADLESS="$CORE_DIR/build/osgfx-headless"
DERIVE="$SCRIPT_DIR/derive.py"
HDR="$CORE_DIR/plat/osgfx/osgfx.h"

ck; [[ -f "$BUILD" ]] || fail "no build-preview-ui.sh"
ck; [[ -f "$HDR" ]] || fail "no osgfx.h"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"

# Restated from osgfx.h — the harness owns the expectation.
W=800
H=600
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

echo "=== BUILD (platform clang + Metal) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-preview-ui.sh exited $BUILD_STATUS"
ck; [[ -x "$HEADLESS" ]] || fail "no osgfx-headless"

capture_sh FILE_OUT FILE_STATUS -- "file '$HEADLESS'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "headless is not Mach-O (do not use none-elf)"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "headless is ELF — wrong toolchain"
fi
ck; echo "$FILE_OUT" | grep -qv 'ELF' || fail "headless file(1) line mentions ELF"
ck; echo "$FILE_OUT" | grep -q 'arm64' || fail "headless is not arm64"

capture_sh NM_OUT NM_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM_STATUS -eq 0 ]] || fail "nm failed"
ck; echo "$NM_OUT" | grep -q 'osgfx_fill_rrect' || fail "osgfx_fill_rrect not in the binary"

echo "=== HEADLESS rrect ==="
capture_sh RRECT_OUT RRECT_STATUS -- "'$HEADLESS' -o '$WORKDIR/rrect.ppm'"
echo "$RRECT_OUT"
ck; [[ $RRECT_STATUS -eq 0 ]] || fail "headless rrect exited $RRECT_STATUS"
ck; [[ -f "$WORKDIR/rrect.ppm" ]] || fail "no rrect.ppm"

capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/rrect.ppm' rrect"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive rrect failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'RRECT_OK' || fail "no RRECT_OK"

echo "=== HEADLESS square (negative) ==="
capture_sh SQ_OUT SQ_STATUS -- "'$HEADLESS' --square -o '$WORKDIR/square.ppm'"
echo "$SQ_OUT"
ck; [[ $SQ_STATUS -eq 0 ]] || fail "headless square exited $SQ_STATUS"

capture_sh DS_OUT DS_STATUS -- "python3 '$DERIVE' '$WORKDIR/square.ppm' square"
echo "$DS_OUT"
ck; [[ $DS_STATUS -eq 0 ]] || fail "derive square failed: $DS_OUT"
ck; echo "$DS_OUT" | grep -q 'SQUARE_OK' || fail "no SQUARE_OK"

# The two PPMs must differ at the AABB corner — otherwise rrect did nothing.
capture_sh DIFF_OUT DIFF_STATUS -- "python3 -c \"
import pathlib
a=pathlib.Path('$WORKDIR/rrect.ppm').read_bytes()
b=pathlib.Path('$WORKDIR/square.ppm').read_bytes()
raise SystemExit(0 if a!=b else 1)
\""
ck; [[ $DIFF_STATUS -eq 0 ]] || fail "rrect and square PPMs are identical"

require_assertions "$ASSERTIONS_REQUIRED"
echo "GFX0-host: PASS — platform clang linked Metal; rrect corner is desktop; square negative is title ($ASSERTIONS checks)"
