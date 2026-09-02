#!/usr/bin/env bash
# Builds DESK.ELF — desk shell FRAME app (ADR-0183, ADR-0192).
#
# THE LINK IS THE CLAIM. desk.c reaches antialiased Skia and proportional
# TrueType outlines through `wmOpPaint` (osxui_app.h), i.e. through a syscall,
# because the rasteriser is in kernel.elf and this ELF is 64KiB of freestanding
# C. So the assertions below are:
#
#   - the ELF names WM_OP_PAINT's op path (osxui_app.h is header-only, so the
#     evidence is in the source and in the absence of osxui_label_fb), and
#   - it does NOT bind osxui_label_fb, the 8x16 bitmap cell it used to caption
#     the taskbar with (osgfx_glyph.c). A DESK that still had that symbol would
#     be a DESK that could still draw a cell.
#
# osxui.c + osxui_fb.c ARE linked, for one reason only: ADR-0192 §5 retests
# `osxui_button_fb`, which desk.c's own header used to record as "hung in-ELF".
# Its pills are not painted with it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
SRC="$FRAME_DIR/desk.c"
GLYPH_C="$CORE_DIR/plat/osgfx/osgfx_glyph.c"
OSXUI_C="$CORE_DIR/plat/osxui/osxui.c"
OSXUI_FB_C="$CORE_DIR/plat/osxui/osxui_fb.c"
GFX_H="$CORE_DIR/plat/osgfx"
UI_H="$CORE_DIR/plat/osxui"
LD="$CORE_DIR/tests/conformance/frame2/prog.ld"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-nm x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found"
done
[[ -f "$SRC" ]] || setup_error "no desk.c"
[[ -f "$FRAME_DIR/osxui_app.h" ]] || setup_error "no osxui_app.h"
[[ -f "$GLYPH_C" ]] || setup_error "no osgfx_glyph.c"
[[ -f "$OSXUI_C" ]] || setup_error "no osxui.c"
[[ -f "$OSXUI_FB_C" ]] || setup_error "no osxui_fb.c"
[[ -f "$LD" ]] || setup_error "no prog.ld"

CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror
  -I"$FRAME_DIR" -I"$GFX_H" -I"$UI_H"
)

clang "${CFLAGS[@]}" "$SRC" -o "$OUT/desk.o" || fail "desk.c"
# OSGFX_GLYPH_APP_LINK: the app-side weak floor for osxui.c's non-scan arms.
# Never set for kernel.elf, where osgfx_fill_rrect must come from Skia.
clang "${CFLAGS[@]}" -DOSGFX_GLYPH_APP_LINK=1 "$GLYPH_C" \
  -o "$OUT/osgfx_glyph.o" || fail "glyph"
clang "${CFLAGS[@]}" "$OSXUI_C" -o "$OUT/osxui.o" || fail "osxui.c"
clang "${CFLAGS[@]}" "$OSXUI_FB_C" -o "$OUT/osxui_fb.o" || fail "osxui_fb.c"

x86_64-elf-ld -T "$LD" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/desk.elf" \
  "$OUT/desk.o" "$OUT/osgfx_glyph.o" "$OUT/osxui.o" "$OUT/osxui_fb.o" \
  || fail "ld DESK.ELF"

[[ -s "$OUT/desk.elf" ]] || fail "empty desk.elf"

# THE TASKBAR IS NOT A BITMAP CELL ANY MORE. `osxui_label_fb` is the 8x16 cell
# path; DESK must not call it. (osgfx_glyph.o still DEFINES it — osxui_hex_fb
# needs it — so this greps desk.o's undefined list, not the whole image.)
x86_64-elf-nm --undefined-only "$OUT/desk.o" | grep -q 'osxui_label_fb' \
  && fail "desk.o still calls osxui_label_fb — the taskbar is still a cell"
x86_64-elf-nm --undefined-only "$OUT/desk.o" | grep -q 'osxui_button_fb' \
  || fail "desk.o does not call osxui_button_fb — the ADR-0192 §5 retest is gone"
grep -qE 'osxui_app_label_box|osxui_app_clock|osxui_app_text' "$SRC" \
  || fail "desk.c does not reach the osxui app text API"
grep -q 'osxui_app_island' "$SRC" \
  || fail "desk.c does not reach the osxui glass island API"
grep -q 'osxui_app_vgrad\|osxui_app_island\|osxui_app_glass' "$SRC" \
  || fail "desk.c does not reach the osxui app paint API"
grep -q 'osxui_app_screen' "$SRC" \
  || fail "desk.c does not ask for the screen rect"
grep -q 'DESK READY' "$SRC" || fail "no DESK READY"
# No 800x600 in the strip's CODE. Comments may (and do) recount GAP-0329.
grep -vE '^[[:space:]]*(\*|/\*|//)' "$SRC" \
  | grep -qE '(^|[^0-9A-Za-z_])(794|549|800|600)([^0-9]|$)' \
  && fail "desk.c still has an 800x600 constant in its code"

BYTES=$(wc -c <"$OUT/desk.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "desk.elf is $BYTES bytes (>65536)"

echo "build-progs: PASS — $OUT/desk.elf ($BYTES bytes)"
exit 0
