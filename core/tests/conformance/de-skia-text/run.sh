#!/usr/bin/env bash
# core/tests/conformance/de-skia-text/run.sh
#
# ADR-0187. Two claims, both binary:
#
#   1. The chrome text in this image is a REAL PROPORTIONAL TRUETYPE OUTLINE
#      scan-converted live by Skia, not an 8x16 bitmap cell and not a baked
#      coverage mask. Proved from three independent sides: the generated
#      outline table re-rasterised on the host by a non-Skia filler, the
#      in-OS advance being proportional, and the painted pixels carrying a
#      real antialiasing ramp on off-grid metrics.
#   2. Every Skia raster op the chrome needs completes on `-cpu qemu64`,
#      including AA drawRRect(MakeRectXY), AA drawPath, LinearGradient and
#      MakeBlur -- the ops ADR-0161 recorded as a hang.
#
# Runs its own uniquely named QEMU. Never touches the interactive door.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

fail() { echo "DE-skia-text: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-skia-text: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=36

for tool in qemu-system-x86_64 python3 x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-skia-text.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
FONT_C="$CORE_DIR/plat/osgfx/osgfx_font_data.c"
FONT_H="$CORE_DIR/plat/osgfx/osgfx_font.h"
SKIA_CPP="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
SESSION_C="$CORE_DIR/plat/osgfx/osgfx_session.c"
GEN_PY="$CORE_DIR/scripts/gen-osgfx-font.py"
CHECK_PY="$CORE_DIR/scripts/check-osgfx-font.py"
SIT="$CORE_DIR/tests/conformance/d3-session"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
OUT_DIR="$CORE_DIR/build/de-skia-text"
mkdir -p "$OUT_DIR"

echo "=== OUTLINE TABLE ==="
ck; [[ -f "$GEN_PY" ]] || fail "gen-osgfx-font.py missing"
ck; [[ -f "$FONT_C" ]] || fail "osgfx_font_data.c missing — run gen-osgfx-font.sh"
ck; grep -q 'osgfx_face_regular' "$FONT_C" || fail "no regular face in font data"
ck; grep -q 'osgfx_face_medium' "$FONT_C" || fail "no medium face in font data"
# The table is outline verbs and per-glyph hmtx advances. A mask cache would
# carry pixel spans and a cell font would carry no advance at all.
ck; grep -q 'OSGFX_VERB_QUAD' "$FONT_H" \
  || fail "osgfx_font.h declares no quadratic outline verb"
ck; grep -q 'short advance' "$FONT_H" \
  || fail "osgfx_font.h glyph record has no per-glyph advance"
ck; python3 "$SCRIPT_DIR/outline.py" "$FONT_C" \
  || fail "outline table is not proportional quadratic TrueType data"
# Re-rasterise the GENERATED C with a filler that is not Skia. Two
# independent rasterisers agreeing is what makes the table trustworthy.
ck; python3 "$CHECK_PY" "$FONT_C" "$OUT_DIR/host-face-medium.png" medium 22 \
  || fail "check-osgfx-font.py could not rasterise the generated table"
ck; [[ -s "$OUT_DIR/host-face-medium.png" ]] \
  || fail "host re-rasterisation produced no PNG"
echo "OUTLINE TABLE: pass  two faces, proportional quadratic outlines"

echo
echo "=== PAINT PATH ==="
ck; grep -q 'skia-drawpath-outline' "$SKIA_CPP" \
  || fail "osgfx_skia.cpp lost the outline text path token"
ck; grep -q 'SkPathBuilder' "$SKIA_CPP" \
  || fail "osgfx_text does not build an SkPath"
ck; grep -q 'c->drawPath' "$SKIA_CPP" \
  || fail "osgfx_text does not hand its path to SkCanvas::drawPath"
ck; grep -q 'c->drawRRect' "$SKIA_CPP" \
  || fail "chrome rrects do not reach SkCanvas::drawRRect"
ck; grep -q 'SkMaskFilter::MakeBlur' "$SKIA_CPP" \
  || fail "elevation is not a Skia mask blur"
ck; grep -q 'SkGraphics::PurgeAllCaches' "$SKIA_CPP" \
  || fail "global Skia caches are not purged before the bump heap rewinds"
ck; grep -q 'osgfx_text(' "$SESSION_C" \
  || fail "osgfx_session.c does not label chrome through osgfx_text"
ck; ! grep -q 'osgfx_fill_glyph' "$SESSION_C" \
  || fail "osgfx_session.c still stamps 8x16 glyph cells"
# Build the image this harness is about to assert on. Reading whatever
# kernel.elf the previous harness happened to leave behind made the result
# depend on sweep order: an OSGFX_SKIA=0 predecessor leaves an image with no
# outline table at all, and this harness would report that as a missing face.
if [[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]]; then
  # shellcheck disable=SC1091
  source /Users/ghostportal/Desktop/dc_sys/env.sh
fi
capture_sh SKIA_BUILD_OUT SKIA_BUILD_STATUS -- \
  "OSGFX_SKIA=1 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
ck; [[ $SKIA_BUILD_STATUS -eq 0 ]] \
  || { echo "$SKIA_BUILD_OUT" >&2; fail "build-kernel.sh OSGFX_SKIA=1 exited $SKIA_BUILD_STATUS"; }
echo "$SKIA_BUILD_OUT" | tail -2
ck; [[ -f "$KERNEL_ELF" ]] || setup_error "no kernel.elf — build it first"
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; elf_has "$KERNEL_ELF" "skia-drawpath-outline" \
  || fail "kernel.elf does not contain the outline text path"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -q ' osgfx_face_regular' \
  || fail "kernel.elf has no osgfx_face_regular — no outline table in image"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -q ' T osgfx_text$' \
  || fail "kernel.elf has no osgfx_text"
echo "PAINT PATH: pass  SkPathBuilder + drawPath + drawRRect + MakeBlur linked"

echo
echo "=== IN-OS (qemu64) ==="
ck; bash "$SIT/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" >/dev/null \
  || fail "d3-session clients failed to build"
DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$SIT/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$WORKDIR/layout.json" \
  || fail "make-image.py failed"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$WORKDIR/layout.json" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)

typekeys() { python3 -c "
import sys
print(','.join({' ':'spc'}.get(c, c.lower()) for c in sys.argv[1]))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2000"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:1500"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_A"),ret,until:D3S COMMIT,wait:800"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_B"),ret,until:D3S COMMIT,wait:1500"

SER="$WORKDIR/serial.txt"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
  -serial "file:$SER" -display none -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!
run_status DRIVE_STATUS -- python3 "$SCRIPT_DIR/probe-run.py" \
  "$PORT" "$SER" "$KEYS" --fb-png "$OUT_DIR/de-skia-text.png"
await QEMU_STATUS "$QEMU_PID"
ck; [[ $DRIVE_STATUS -eq 0 ]] || { tail -40 "$SER" >&2; fail "driver exited $DRIVE_STATUS"; }

# ADR-0161 recorded AA MakeRectXY rrect and AA path as unreachable on qemu64.
# The probe walks every op the chrome uses and names the one it dies inside,
# so a regression points at an op instead of at "Skia hangs".
ck; grep -q 'OSGFX SKIA OPS OK 16' "$SER" \
  || { grep -E 'OSGFX (SKIA OPS|PROBE)' "$SER" | tail -3 >&2 || true; \
       fail "not all 16 Skia raster ops completed on qemu64"; }
ck; grep -q 'OSGFX TEXT OUTLINE PROPORTIONAL' "$SER" \
  || fail "in-OS advance is a fixed cell, not a proportional outline"
ck; ! grep -q 'OSGFX PAINT STACK OVERFLOW' "$SER" \
  || fail "paint stack guard was breached"
ck; ! grep -q 'OSGFX OOM' "$SER" || fail "Skia ran the bump heap out"
# The #GP a dangling SkResourceCache entry used to cause: a virtual call
# through the real-mode IVT, i.e. RIP F000FF54F000FF53.
ck; ! grep -q 'FAULT 0D' "$SER" \
  || fail "#GP during session paint (dangling Skia cache after heap rewind?)"
ck; grep -q 'OSGFX SESSION CHROME' "$SER" || fail "session chrome never ran"
ck; [[ -s "$OUT_DIR/de-skia-text.png.bin" ]] || fail "no framebuffer dump"
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-Fa-f]+ PITCH ([0-9A-Fa-f]+)' "$SER" | awk '{print $NF}')))
echo "IN-OS: pass  16/16 Skia ops, proportional advance, no fault"

echo
echo "=== PAINTED PIXELS ==="
FB="$OUT_DIR/de-skia-text.png.bin"
# Window A caption band ("FILES", 15px Roboto Medium) and the Start pill
# label ("Start", 14px Roboto Medium). Both must show an AA ramp on metrics
# that do not land on the 8x16 cell grid.
ck; python3 "$SCRIPT_DIR/caption.py" "$FB" "$PITCH" 114 120 285 152 \
  || fail "window caption is not antialiased proportional outline text"
ck; python3 "$SCRIPT_DIR/caption.py" "$FB" "$PITCH" 20 560 92 592 --min-ink 30 \
  || fail "Start pill label is not antialiased proportional outline text"
# Rounded chrome: the Start pill's corner must be a Skia curve, i.e. a
# coverage ramp, not a stair.
ck; python3 "$SCRIPT_DIR/curve.py" "$FB" "$PITCH" 8 558 104 36 \
  || fail "Start pill corner has no antialiased coverage ramp"
echo "PAINTED PIXELS: pass  AA ramps on off-grid text and curved chrome"

# The assertions above are the proof; these crops are so a human can check the
# same claim by eye. Fringe quality lives in 2-3 pixels, which is invisible at
# 1:1 in an 800x600 shot, so magnify the two places the claim is strongest.
python3 "$SCRIPT_DIR/zoom.py" "$FB" "$PITCH" 100 118 250 40 4 \
  "$OUT_DIR/zoom-title.png" >/dev/null
python3 "$SCRIPT_DIR/zoom.py" "$FB" "$PITCH" 8 562 280 40 4 \
  "$OUT_DIR/zoom-taskbar.png" >/dev/null
echo "    PNG: $OUT_DIR/de-skia-text.png"
echo "    4x crops: $OUT_DIR/zoom-title.png, $OUT_DIR/zoom-taskbar.png"
echo "    host re-raster: $OUT_DIR/host-face-medium.png"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-skia-text: PASS — live Skia outline text + AA chrome ($ASSERTIONS checks)"
exit 0
