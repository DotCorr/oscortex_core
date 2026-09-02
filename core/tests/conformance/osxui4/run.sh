#!/usr/bin/env bash
# OSXUI4 — widgets as a C module that paints through osgfx.h only.
# docs/design/osx-ui.md, ADR-0113.
#
# Not a second box toolkit. Not Flutter. Not a new syscall.
# Same osxui.c the kernel triple compiles. Host scene: one button;
# click (hit-test) changes a derived colour; AABB corners are desktop
# (rrect). --square is the box-painter negative.
#
# Anti-vacuity: no osgfx_fill_rrect in the link → osxui.c cannot link.
# Widgets have no pixel blit.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "OSXUI4: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OSXUI4: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run (66 checks executed).
ASSERTIONS_REQUIRED=66

for tool in clang python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-osxui4.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-osxui.sh"
HEADLESS="$CORE_DIR/build/osxui-headless"
DERIVE="$SCRIPT_DIR/derive.py"
HDR="$CORE_DIR/plat/osxui/osxui.h"
SRC="$CORE_DIR/plat/osxui/osxui.c"
GFX_H="$CORE_DIR/plat/osgfx/osgfx.h"
MAIN="$CORE_DIR/plat/osxui/headless_main.c"
CPU="$CORE_DIR/plat/osxui/osgfx_cpu.c"

ck; [[ -f "$BUILD" ]] || fail "no build-osxui.sh"
ck; [[ -f "$HDR" ]] || fail "no osxui.h"
ck; [[ -f "$SRC" ]] || fail "no osxui.c"
ck; [[ -f "$GFX_H" ]] || fail "no osgfx.h"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"
ck; [[ -f "$MAIN" ]] || fail "no headless_main.c"
ck; [[ -f "$CPU" ]] || fail "no osgfx_cpu.c"

# Restated from osxui.h — the harness owns the expectation.
BTN_W=96
BTN_H=48
RADIUS=10
DESK=0x00184060
IDLE=0x0020A060
HIT=0x00E04090
PANEL=0x00D8B060
PANEL_H=18

ck; [[ $RADIUS -gt 0 ]] || fail "radius is zero"
ck; [[ $((BTN_W * BTN_H)) -gt 0 ]] || fail "button area is zero"
ck; [[ $((BTN_W * BTN_H)) -lt $((800 * 600)) ]] || fail "button is the whole scene"
ck; [[ $IDLE -ne $HIT ]] || fail "IDLE equals HIT"
ck; [[ $IDLE -ne $DESK ]] || fail "IDLE equals DESK"
ck; [[ $HIT -ne $DESK ]] || fail "HIT equals DESK"
ck; [[ $PANEL -ne $DESK ]] || fail "PANEL equals DESK"
ck; [[ $PANEL_H -gt 0 ]] || fail "panel height is zero"

ck; grep -q 'OSXUI_BTN_R = 10' "$HDR" || fail "osxui.h RADIUS moved without derive.py"
ck; grep -q 'OSXUI_BTN_IDLE = 0x0020A060' "$HDR" || fail "osxui.h IDLE moved"
ck; grep -q 'OSXUI_BTN_HIT = 0x00E04090' "$HDR" || fail "osxui.h HIT moved"
# The header and derive.py's copy must AGREE; neither number is typed here.
# This used to be `grep -q 'OSGFX_X = <literal>'`, a THIRD copy of the same
# fact, so ADR-0187's chrome redesign (pearl title band, elevated slate
# taskbar, softer corner radius) had to be transcribed into three places and
# was transcribed into one. derive.py stays a hand-edited double entry -- that
# is the point of it -- but the harness now checks the pair rather than
# remembering a value of its own.
HDR_PANEL=$(awk -F'= *' '/OSXUI_PANEL *=/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$HDR")
PY_PANEL=$(python3 - "$DERIVE" <<'PYX'
import re, sys
m = re.search(r"^PANEL = (\S+)", open(sys.argv[1]).read(), re.M)
print(m.group(1) if m else "")
PYX
)
ck; [[ -n "$HDR_PANEL" && -n "$PY_PANEL" ]] \
  || fail "could not read OSXUI_PANEL out of $HDR or PANEL out of $DERIVE"
ck; [[ $(( HDR_PANEL )) -eq $(( PY_PANEL )) ]] \
  || fail "OSXUI_PANEL is $HDR_PANEL in the header but derive.py's PANEL is $PY_PANEL — the harness is measuring against a colour/size the module no longer paints"
ck; grep -q 'OSXUI_BTN_X = 352' "$HDR" || fail "osxui.h BTN_X moved"
ck; grep -q 'OSXUI_BTN_W = 96' "$HDR" || fail "osxui.h BTN_W moved"
ck; grep -q '#include "osgfx.h"' "$HDR" || fail "osxui.h does not include osgfx.h"

# Widgets paint only through osgfx. A blit loop here is a second toolkit.
ck; grep -q 'osgfx_fill_rrect' "$SRC" || fail "osxui.c does not call osgfx_fill_rrect"
ck; grep -q 'osgfx_fill_rect' "$SRC" || fail "osxui.c does not call osgfx_fill_rect"
ck; grep -q 'int osxui_hit' "$SRC" || fail "osxui.c has no osxui_hit"
ck; grep -q 'void osxui_button' "$SRC" || fail "osxui.c has no osxui_button"
ck; grep -q 'void osxui_panel' "$SRC" || fail "osxui.c has no osxui_panel"
if grep -qE 'put_px|pixels\[|memset|framebuffer|shm' "$SRC"; then
  fail "osxui.c blits pixels — widgets must call osgfx only"
fi
if grep -qE '\*\(uint32_t|\*\(volatile uint32_t' "$SRC"; then
  fail "osxui.c stores pixels directly"
fi

# Scene uses the kit, not a CPU box loop of its own for the button.
ck; grep -q 'osxui_button' "$MAIN" || fail "headless does not call osxui_button"
ck; grep -q 'osxui_panel' "$MAIN" || fail "headless does not call osxui_panel"
ck; grep -q 'osxui_hit' "$MAIN" || fail "headless does not call osxui_hit"

echo "=== ANTI-VACUITY (no osgfx_fill_rrect) ==="
capture_sh NOR_OUT NOR_STATUS -- "clang -O2 -Wall -Wextra \
  -I '$CORE_DIR/plat/osgfx' -I '$CORE_DIR/plat/osxui' \
  -o '$WORKDIR/osxui-no-rrect' \
  '$SRC' '$MAIN' '$CPU' -DOSGFX_NO_RRECT=1 2>&1"
echo "$NOR_OUT"
ck; [[ $NOR_STATUS -ne 0 ]] || fail "osxui linked without osgfx_fill_rrect — vacuous"
if [[ -x "$WORKDIR/osxui-no-rrect" ]]; then
  fail "no-rrect binary exists — link should have failed"
fi
# A binary that never linked osgfx has no rrect symbol.
clang -O2 -Wall -Wextra -c -o "$WORKDIR/main_only.o" \
  -I "$CORE_DIR/plat/osgfx" -I "$CORE_DIR/plat/osxui" "$MAIN" \
  || fail "main-only compile failed"
capture_sh MAIN_NM MAIN_NM_ST -- "nm '$WORKDIR/main_only.o'"
ck; [[ $MAIN_NM_ST -eq 0 ]] || fail "nm main_only failed"
ck; ! echo "$MAIN_NM" | grep -q 'T _*osgfx_fill_rrect' \
  || fail "main-only object defines osgfx_fill_rrect"
echo "ANTI-VACUITY: pass  no osgfx_fill_rrect → osxui.c does not link"

echo
echo "=== BUILD (platform clang + osgfx.h software) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-osxui.sh exited $BUILD_STATUS"
ck; [[ -x "$HEADLESS" ]] || fail "no osxui-headless"

capture_sh FILE_OUT FILE_STATUS -- "file '$HEADLESS'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "headless is not Mach-O"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "headless is ELF — wrong toolchain for the host harness"
fi

capture_sh NM_OUT NM_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM_STATUS -eq 0 ]] || fail "nm failed"
printf '%s\n' "$NM_OUT" > "$WORKDIR/nm.txt"
ck; grep -q 'osgfx_fill_rrect' "$WORKDIR/nm.txt" || fail "osgfx_fill_rrect not in the binary"
ck; grep -q 'osxui_button' "$WORKDIR/nm.txt" || fail "osxui_button not in the binary"
ck; grep -q 'osxui_panel' "$WORKDIR/nm.txt" || fail "osxui_panel not in the binary"
ck; grep -q 'osxui_hit' "$WORKDIR/nm.txt" || fail "osxui_hit not in the binary"

echo
echo "=== KERNEL TRIPLE (same osxui.c) ==="
capture_sh K_OUT K_STATUS -- "clang -c -target x86_64-unknown-none-elf \
  -ffreestanding -nostdlib -fno-pic -fno-pie -mno-red-zone \
  -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin \
  -O2 -Wall \
  -I '$CORE_DIR/plat/osgfx' -I '$CORE_DIR/plat/osxui' \
  -o '$WORKDIR/osxui-kernel.o' '$SRC' 2>&1"
echo "$K_OUT"
ck; [[ $K_STATUS -eq 0 ]] || fail "osxui.c failed the kernel triple"
capture_sh KNM_OUT KNM_ST -- "nm '$WORKDIR/osxui-kernel.o'"
ck; [[ $KNM_ST -eq 0 ]] || fail "nm kernel-triple osxui.o failed"
printf '%s\n' "$KNM_OUT" > "$WORKDIR/knm.txt"
ck; grep -q 'osxui_button' "$WORKDIR/knm.txt" || fail "kernel-triple .o has no osxui_button"
ck; grep -q 'osgfx_fill_rrect' "$WORKDIR/knm.txt" || fail "kernel-triple .o does not reference osgfx_fill_rrect"
echo "KERNEL TRIPLE: pass  same osxui.c for x86_64-unknown-none-elf"

echo
echo "=== IDLE rrect ==="
capture_sh IDLE_OUT IDLE_STATUS -- "'$HEADLESS' -o '$WORKDIR/idle.ppm'"
echo "$IDLE_OUT"
ck; [[ $IDLE_STATUS -eq 0 ]] || fail "headless idle exited $IDLE_STATUS"
ck; echo "$IDLE_OUT" | grep -q 'BACKEND software' || fail "idle backend is not software"
ck; echo "$IDLE_OUT" | grep -q 'COLOUR 0x20A060' || fail "idle colour is not IDLE"
ck; [[ -f "$WORKDIR/idle.ppm" ]] || fail "no idle.ppm"
capture_sh DI_OUT DI_STATUS -- "python3 '$DERIVE' '$WORKDIR/idle.ppm' idle"
echo "$DI_OUT"
ck; [[ $DI_STATUS -eq 0 ]] || fail "derive idle failed: $DI_OUT"
ck; echo "$DI_OUT" | grep -q 'IDLE_OK' || fail "no IDLE_OK"

echo
echo "=== CLICK (hit flips colour) ==="
capture_sh CLK_OUT CLK_STATUS -- "'$HEADLESS' --click -o '$WORKDIR/click.ppm'"
echo "$CLK_OUT"
ck; [[ $CLK_STATUS -eq 0 ]] || fail "headless click exited $CLK_STATUS"
ck; echo "$CLK_OUT" | grep -q 'HIT 1' || fail "click path did not hit"
ck; echo "$CLK_OUT" | grep -q 'COLOUR 0xE04090' || fail "click colour is not HIT"
capture_sh DC_OUT DC_STATUS -- "python3 '$DERIVE' '$WORKDIR/click.ppm' click"
echo "$DC_OUT"
ck; [[ $DC_STATUS -eq 0 ]] || fail "derive click failed: $DC_OUT"
ck; echo "$DC_OUT" | grep -q 'CLICK_OK' || fail "no CLICK_OK"

echo
echo "=== MISS (outside press does not flip) ==="
capture_sh MISS_OUT MISS_STATUS -- "'$HEADLESS' --miss -o '$WORKDIR/miss.ppm'"
echo "$MISS_OUT"
ck; [[ $MISS_STATUS -eq 0 ]] || fail "headless miss exited $MISS_STATUS"
ck; echo "$MISS_OUT" | grep -q 'HIT 0' || fail "miss path hit the button"
ck; echo "$MISS_OUT" | grep -q 'COLOUR 0x20A060' || fail "miss colour is not IDLE"
capture_sh DM_OUT DM_STATUS -- "python3 '$DERIVE' '$WORKDIR/miss.ppm' miss"
echo "$DM_OUT"
ck; [[ $DM_STATUS -eq 0 ]] || fail "derive miss failed: $DM_OUT"
ck; echo "$DM_OUT" | grep -q 'MISS_OK' || fail "no MISS_OK"

echo
echo "=== SQUARE (negative: box painter) ==="
capture_sh SQ_OUT SQ_STATUS -- "'$HEADLESS' --square -o '$WORKDIR/square.ppm'"
echo "$SQ_OUT"
ck; [[ $SQ_STATUS -eq 0 ]] || fail "headless square exited $SQ_STATUS"
capture_sh DS_OUT DS_STATUS -- "python3 '$DERIVE' '$WORKDIR/square.ppm' square"
echo "$DS_OUT"
ck; [[ $DS_STATUS -eq 0 ]] || fail "derive square failed: $DS_OUT"
ck; echo "$DS_OUT" | grep -q 'SQUARE_OK' || fail "no SQUARE_OK"

capture_sh DIFF_OUT DIFF_STATUS -- "python3 -c \"
import pathlib
a=pathlib.Path('$WORKDIR/idle.ppm').read_bytes()
b=pathlib.Path('$WORKDIR/square.ppm').read_bytes()
c=pathlib.Path('$WORKDIR/click.ppm').read_bytes()
raise SystemExit(0 if a!=b and a!=c else 1)
\""
ck; [[ $DIFF_STATUS -eq 0 ]] || fail "idle/square/click PPMs did not differ"

require_assertions "$ASSERTIONS_REQUIRED"
echo "OSXUI4: PASS — osxui_button/panel/hit through osgfx.h; click flips HIT; AABB is desktop; no-rrect link fails ($ASSERTIONS checks)"
