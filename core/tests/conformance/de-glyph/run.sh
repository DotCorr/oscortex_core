#!/usr/bin/env bash
# core/tests/conformance/de-glyph/run.sh
#
# ADR-0117 — Start / osxui 8.3 glyphs through osgfx_fill_glyph.
# A planted 4-letter name is visible as derived foreground pixels
# matching fbFont8x16 (count). Wrong font does not match.
# de-chrome / osxui4 stay on colour-tile probes (glyphs sit left of
# the row centre).
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

fail() { echo "DE-glyph: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-glyph: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run.
ASSERTIONS_REQUIRED=42

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-glyph.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SITFAT="$CORE_DIR/tests/conformance/de-sitfat"
CHROME="$CORE_DIR/tests/conformance/de-chrome"
HDR="$CORE_DIR/plat/osgfx/osgfx.h"
GLYPH_C="$CORE_DIR/plat/osgfx/osgfx_glyph.c"
UI_H="$CORE_DIR/plat/osxui/osxui.h"
UI_C="$CORE_DIR/plat/osxui/osxui.c"
SW="$CORE_DIR/plat/osgfx/osgfx_sw.c"
SKIA="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
HEADLESS="$CORE_DIR/build/osxui-headless"

ck; [[ -f "$DRIVER" ]] || fail "no comp-drive.py"
ck; [[ -f "$GLYPH_C" ]] || fail "no osgfx_glyph.c — glyphs must be a new .c"
ck; [[ -f "$HDR" ]] || fail "no osgfx.h"
ck; grep -q 'osgfx_fill_glyph' "$HDR" || fail "osgfx.h has no osgfx_fill_glyph"
ck; grep -q 'osgfx_fill_rect' "$GLYPH_C" || fail "osgfx_glyph.c does not call osgfx_fill_rect"
ck; ! grep -q 'osgfx_fill_glyph' "$SW" \
  || fail "osgfx_sw.c grew fill_glyph — that file is mid-swap"
ck; ! grep -q 'osgfx_fill_glyph' "$SKIA" \
  || fail "osgfx_skia.cpp grew fill_glyph — Skia agent file"
ck; grep -q 'void osxui_label' "$UI_C" || fail "osxui.c has no osxui_label"
ck; grep -q 'osgfx_fill_glyph' "$UI_C" || fail "osxui_label does not call osgfx_fill_glyph"
if grep -qE 'put_px|pixels\[|memset|framebuffer|shm' "$UI_C"; then
  fail "osxui.c blits pixels — labels must call osgfx only"
fi
ck; grep -q 'osxui_label_fb' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart does not call osxui_label_fb"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall"
ck; ! grep -q '^@extern' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart grew @extern — policy stays in wmde"

echo "=== ANTI-VACUITY (no osgfx_fill_glyph) ==="
capture_sh NOG_OUT NOG_STATUS -- "clang -O2 -Wall -Wextra \
  -I '$CORE_DIR/plat/osgfx' -I '$CORE_DIR/plat/osxui' \
  -o '$WORKDIR/osxui-no-glyph' \
  '$UI_C' '$CORE_DIR/plat/osxui/headless_main.c' \
  '$CORE_DIR/plat/osxui/osgfx_cpu.c' 2>&1"
echo "$NOG_OUT"
ck; [[ $NOG_STATUS -ne 0 ]] || fail "osxui linked without osgfx_fill_glyph — vacuous"
if [[ -x "$WORKDIR/osxui-no-glyph" ]]; then
  fail "no-glyph binary exists — link should have failed"
fi
echo "ANTI-VACUITY: pass  no osgfx_fill_glyph → osxui.c does not link"

echo
echo "=== HOST LABEL ==="
capture_sh BUILD_UI BUILD_UI_ST -- "bash '$CORE_DIR/scripts/build-osxui.sh' 2>&1"
echo "$BUILD_UI"
ck; [[ $BUILD_UI_ST -eq 0 ]] || fail "build-osxui.sh exited $BUILD_UI_ST"
ck; [[ -x "$HEADLESS" ]] || fail "no osxui-headless"
capture_sh NMH NMH_ST -- "nm '$HEADLESS'"
ck; [[ $NMH_ST -eq 0 ]] || fail "nm headless failed"
printf '%s\n' "$NMH" > "$WORKDIR/nmh.txt"
ck; grep -q 'osgfx_fill_glyph' "$WORKDIR/nmh.txt" || fail "headless has no osgfx_fill_glyph"
ck; grep -q 'osxui_label' "$WORKDIR/nmh.txt" || fail "headless has no osxui_label"

FONT="$WORKDIR/font.txt"
ck; python3 "$SCRIPT_DIR/derive.py" font "$CORE_DIR/kernel/fb.dart" > "$FONT" \
  || fail "derive font failed"
capture_sh LAB_OUT LAB_ST -- "'$HEADLESS' --label ABCD -o '$WORKDIR/label.ppm'"
echo "$LAB_OUT"
ck; [[ $LAB_ST -eq 0 ]] || fail "headless --label exited $LAB_ST"
ck; echo "$LAB_OUT" | grep -q 'LABEL ABCD' || fail "headless did not print LABEL ABCD"
# READ the label foreground out of osxui.h. It was typed as 00101820, which is
# what OSXUI_LABEL_FG was before ADR-0187 made the panel pearl and darkened the
# text on it to 0x00202830. A harness that types the colour it expects on
# screen cannot tell "the module changed its mind" from "the module painted
# nothing", and this one reported MATCH 0 for a label that was in fact fully
# painted, in the colour the header names.
LABEL_FG=$(printf '%08X' "$(awk -F'= *' '/OSXUI_LABEL_FG *=/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$UI_H")")
ck; [[ -n "$LABEL_FG" && "$LABEL_FG" != "00000000" ]] \
  || fail "could not read OSXUI_LABEL_FG out of $UI_H"
capture_sh HM_OUT HM_ST -- "python3 '$SCRIPT_DIR/match.py' ppm \
  '$WORKDIR/label.ppm' 0 \
  $((352 + 2)) $((252 + 1)) $LABEL_FG '$FONT' ABCD"
echo "$HM_OUT"
ck; [[ $HM_ST -eq 0 ]] || fail "host ABCD did not match the font: $HM_OUT"
ck; echo "$HM_OUT" | grep -q 'GLYPH_OK' || fail "no GLYPH_OK on host"
echo "HOST: pass  ABCD on the panel matches fbFont8x16; wrong font does not"

echo
echo "=== BUILD KERNEL ==="
# OSMEDIA_FFMPEG=0 is the existing anti-vacuity path (de-osgfx). This
# rung does not touch media; skip the guest libav rebuild.
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" || fail "could not snapshot kernel.elf"
KERNEL_ELF="$WORKDIR/kernel.elf"
capture_sh KNM KNM_ST -- "nm '$KERNEL_ELF'"
ck; [[ $KNM_ST -eq 0 ]] || fail "nm kernel.elf failed"
printf '%s\n' "$KNM" > "$WORKDIR/knm.txt"
ck; grep -q 'osgfx_fill_glyph' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osgfx_fill_glyph"
ck; grep -q 'osxui_label_fb' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_label_fb"

echo
echo "=== DISK (ABCD.ELF) ==="
bash "$CHROME/build-progs.sh" "$WORKDIR/chrome" \
  || fail "de-chrome build-progs.sh failed"
ck; [[ -s "$WORKDIR/chrome/ping.elf" ]] || fail "no ping.elf to plant as ABCD.ELF"
DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$SITFAT/make-image.py" "$DISK_IMG" \
  "ABCD.ELF=$WORKDIR/chrome/ping.elf" \
  || fail "make-image.py could not write ABCD.ELF"
if command -v fsck_msdos >/dev/null 2>&1 || [[ -x /sbin/fsck_msdos ]]; then
  FSCK="${FSCK:-fsck_msdos}"
  [[ -x /sbin/fsck_msdos ]] && FSCK=/sbin/fsck_msdos
  capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
else
  ck; true
fi
echo "IMAGE: pass  FAT16 ABCD.ELF"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
ck; python3 "$SCRIPT_DIR/derive.py" geometry \
  "$CORE_DIR/kernel/wmde.dart" \
  "$CORE_DIR/kernel/wmchrome.dart" \
  "$CORE_DIR/kernel/fb.dart" \
  ABCD.ELF > "$MODEL" \
  || fail "derive geometry failed"
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
STEM=$(d stem); FG=$(d fg); ROW0=$(d row0)
GX=$(d glyph_x); GY=$(d glyph_y)
RX=$(d row0_x); RY=$(d row0_y)
RELS_START=$(d rels_start)
EXPECT=$(d expect_bits)
ck; [[ "$STEM" == "ABCD" ]] || fail "derived stem is $STEM"
ck; [[ -n "$RELS_START" && -n "$GX" ]] || fail "derive omitted start / glyph origin"
echo "DERIVED: stem $STEM fg $FG at ($GX,$GY) expect $EXPECT bits"

echo
echo "=== HELP ==="
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'glyph' in blob.lower() or b'de-glyph' in blob.lower():
    raise SystemExit('glyph appeared inside shellStrHelp')
print('    shellStrHelp has no glyph line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "glyph appeared in help (GAP-0304)"; }
echo "$HELP_OUT"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

BASE_KEYS="$(typekeys 'fb'),ret,wait:1500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"
BASE_KEYS="$BASE_KEYS,$RELS_START"

glyph_boot() {
  local dir="$WORKDIR/start"
  mkdir -p "$dir"
  local ser="$dir/serial.txt"
  local fb1="$dir/fb.bin"
  local png1="$dir/shot.png"
  : >"$ser"
  local attempt=0 drive_status=1 qemu_status=0
  while :; do
    attempt=$(( attempt + 1 ))
    local port
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
    timeout 180 qemu-system-x86_64 \
      -kernel "$KERNEL_ELF" \
      -m 128M \
      -cpu qemu64 \
      -vga std \
      -serial "file:$ser" \
      -display none \
      -no-reboot \
      -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
      -qmp "tcp:127.0.0.1:$port,server,nowait" \
      >"$dir/qemu.log" 2>&1 &
    local qemu_pid=$!
    run_status drive_status -- python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --keys "$BASE_KEYS" \
      --settle-for "WM DE START" \
      --settle-timeout 60 \
      --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
      --fb-out "$fb1" \
      --png "$png1"
    await qemu_status "$qemu_pid"
    if [[ $drive_status -ne 0 ]] && grep -q "Address already in use" "$dir/qemu.log" \
       && [[ $attempt -lt 5 ]]; then
      echo "    (port $port was taken; retrying — attempt $attempt)"
      continue
    fi
    break
  done
  if [[ $drive_status -ne 0 ]]; then
    cat "$dir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    sed -n '/M1 END/,$p' "$ser" >&2
    fail "start: comp-drive.py exited $drive_status"
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$dir/qemu.log" >&2
    fail "start: qemu exited $qemu_status"
  fi
  [[ -s "$ser" ]] || fail "start: no serial"
  [[ -s "$fb1" ]] || fail "start: no framebuffer"
  DE_SER="$ser"
  DE_FB="$fb1"
}

echo
echo "=== BOOT START ==="
glyph_boot
ck; grep -qE '^WM DE ON' "$DE_SER" || fail "WM DE ON did not appear"
ck; grep -qE '^WM DE START 01' "$DE_SER" || fail "start did not list one planted ELF"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" || fail "start boot faulted"
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$DE_SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; python3 "$PROBE" "$DE_FB" "$PITCH" "$RX" "$RY" "$ROW0" "launch_row0" \
  || fail "row centre is not the launch-row colour — de-sitfat probe moved"
capture_sh GM_OUT GM_ST -- "python3 '$SCRIPT_DIR/match.py' fb \
  '$DE_FB' '$PITCH' '$GX' '$GY' '$FG' '$FONT' ABCD"
echo "$GM_OUT"
ck; [[ $GM_ST -eq 0 ]] || fail "Start ABCD did not match the font: $GM_OUT"
ck; echo "$GM_OUT" | grep -q 'GLYPH_OK' || fail "no GLYPH_OK on Start"
echo "START: pass  planted ABCD matches fbFont8x16; row centre still the band"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-glyph: PASS ($ASSERTIONS checks)"
exit 0
