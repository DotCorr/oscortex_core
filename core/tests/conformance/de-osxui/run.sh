#!/usr/bin/env bash
# core/tests/conformance/de-osxui/run.sh
#
# ADR-0133 — live DE chrome Start is painted via osxui_button.
# wmde calls osxui_button_fb → osxui_button (null OsGfx) → rrect.
# A click on Start still opens the launch list. Stub button misses
# the interior. Square blit would paint the AABB corner.
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

fail() { echo "DE-osxui: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-osxui: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run.
ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-osxui.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
CHROME="$CORE_DIR/tests/conformance/de-chrome"
UI_H="$CORE_DIR/plat/osxui/osxui.h"
UI_C="$CORE_DIR/plat/osxui/osxui.c"
UI_FB="$CORE_DIR/plat/osxui/osxui_fb.c"
HEADLESS="$CORE_DIR/build/osxui-headless"

ck; [[ -f "$DRIVER" ]] || fail "no comp-drive.py"
ck; [[ -f "$UI_FB" ]] || fail "no osxui_fb.c — scanout door is a new .c"
ck; [[ -f "$UI_C" ]] || fail "no osxui.c"
ck; grep -q 'void osxui_button_fb' "$UI_H" || fail "osxui.h has no osxui_button_fb"
ck; grep -q 'osxui_button(0' "$UI_FB" || fail "osxui_button_fb does not call osxui_button"
ck; grep -q 'osxui_scan_button' "$UI_C" || fail "osxui_button does not call osxui_scan_button"
ck; grep -q 'osgfx_fill_rrect' "$UI_C" || fail "osxui_button lost osgfx_fill_rrect"
ck; grep -q 'osxui_button_fb' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart does not call osxui_button_fb"
ck; grep -q 'wmOsxuiButton' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart has no wmOsxuiButton helper"
ck; grep -A20 'u64 wmDeChromeDraw' "$CORE_DIR/kernel/wmde.dart" \
  | grep -q 'wmOsxuiButton' \
  || fail "wmDeChromeDraw does not paint Start through osxui"
ck; grep -A16 'void wmTitleButtonsDraw' "$CORE_DIR/kernel/wmde.dart" \
  | grep -q 'wmOsxuiButton' \
  || fail "wmTitleButtonsDraw does not paint close/min through osxui"
ck; ! grep -A16 'void wmTitleButtonsDraw' "$CORE_DIR/kernel/wmde.dart" \
  | grep -q 'wmFillRect' \
  || fail "wmTitleButtonsDraw still uses wmFillRect"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
ck; ! grep -qE 'guest OS|Guest OS' "$CORE_DIR/docs/decisions/0133-osxui-button-is-live-de-chrome.md" \
  || fail "ADR-0133 said guest OS"

echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
ck; python3 "$SCRIPT_DIR/derive.py" geometry \
  "$CORE_DIR/kernel/wmde.dart" \
  "$CORE_DIR/kernel/wmchrome.dart" \
  "$CORE_DIR/kernel/wm.dart" \
  "$UI_H" > "$MODEL" \
  || fail "derive geometry failed"
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
START_C=$(d start_color); CHROME_C=$(d chrome)
AABB_X=$(d aabb_x); AABB_Y=$(d aabb_y)
MID_X=$(d mid_x); MID_Y=$(d mid_y)
STRIP_X=$(d strip_x); STRIP_Y=$(d strip_y)
FILL_X=$(d fill_x); LABEL_FG=$(d label_fg)
LABEL_X0=$(d label_x0); LABEL_X1=$(d label_x1)
LABEL_Y0=$(d label_y0); LABEL_Y1=$(d label_y1)
RELS_START=$(d rels_start)
START_R=$(d start_r)
ck; [[ -n "$RELS_START" && -n "$AABB_X" ]] || fail "derive omitted Start"
ck; [[ "$START_R" -gt 0 ]] || fail "Start radius is zero"
ck; [[ "$START_C" != "$CHROME_C" ]] || fail "Start colour equals chrome"
echo "DERIVED: Start interior ($MID_X,$MID_Y) AABB ($AABB_X,$AABB_Y) r=$START_R"

echo
echo "=== HELP ==="
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'osxui' in blob.lower() or b'de-osxui' in blob.lower():
    raise SystemExit('osxui appeared inside shellStrHelp')
print('    shellStrHelp has no osxui line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "osxui appeared in help (GAP-0304)"; }
echo "$HELP_OUT"

echo
echo "=== HOST START (osxui_button_fb) ==="
capture_sh BUILD_UI BUILD_UI_ST -- "bash '$CORE_DIR/scripts/build-osxui.sh' 2>&1"
echo "$BUILD_UI"
ck; [[ $BUILD_UI_ST -eq 0 ]] || fail "build-osxui.sh exited $BUILD_UI_ST"
ck; [[ -x "$HEADLESS" ]] || fail "no osxui-headless"
capture_sh NMH NMH_ST -- "nm '$HEADLESS'"
ck; [[ $NMH_ST -eq 0 ]] || fail "nm headless failed"
printf '%s\n' "$NMH" > "$WORKDIR/nmh.txt"
ck; grep -q 'osxui_button_fb' "$WORKDIR/nmh.txt" || fail "headless has no osxui_button_fb"
ck; grep -q 'osxui_button' "$WORKDIR/nmh.txt" || fail "headless has no osxui_button"
capture_sh ST_OUT ST_ST -- "'$HEADLESS' --chrome-start -o '$WORKDIR/start.ppm'"
echo "$ST_OUT"
ck; [[ $ST_ST -eq 0 ]] || fail "headless --chrome-start exited $ST_ST"
AABB_HOST=$(python3 "$SCRIPT_DIR/derive.py" ppm "$WORKDIR/start.ppm" "$AABB_X" "$AABB_Y")
MID_HOST=$(python3 "$SCRIPT_DIR/derive.py" ppm "$WORKDIR/start.ppm" "$MID_X" "$MID_Y")
STRIP_HOST=$(python3 "$SCRIPT_DIR/derive.py" ppm "$WORKDIR/start.ppm" "$STRIP_X" "$STRIP_Y")
ck; [[ "$AABB_HOST" == "$CHROME_C" ]] \
  || fail "host AABB is $AABB_HOST, want chrome $CHROME_C — not an rrect"
ck; [[ "$MID_HOST" == "$START_C" ]] \
  || fail "host Start interior is $MID_HOST, want $START_C"
ck; [[ "$STRIP_HOST" == "$CHROME_C" ]] \
  || fail "host strip beside Start is $STRIP_HOST"
echo "HOST: pass  Start rrect; AABB chrome; interior START"

echo
echo "=== ANTI-VACUITY (stub osxui_button) ==="
SRC="$CORE_DIR/plat/osxui"
GFX="$CORE_DIR/plat/osgfx"
clang -O2 -Wall -Wextra -I "$GFX" -I "$SRC" -DOSXUI_STUB_BUTTON=1 \
  -c -o "$WORKDIR/osxui-stub.o" "$SRC/osxui.c" \
  || fail "stub osxui.c did not compile"
clang -O2 -Wall -Wextra -I "$GFX" -I "$SRC" \
  -c -o "$WORKDIR/osxui_fb.o" "$SRC/osxui_fb.c" \
  || fail "osxui_fb.c did not compile for stub link"
clang -O2 -Wall -Wextra -I "$GFX" \
  -c -o "$WORKDIR/osxui_osgfx_cpu.o" "$SRC/osgfx_cpu.c" \
  || fail "osgfx_cpu.c did not compile"
clang -O2 -Wall -Wextra -I "$GFX" \
  -c -o "$WORKDIR/osgfx_glyph.o" "$GFX/osgfx_glyph.c" \
  || fail "osgfx_glyph.c did not compile"
clang -O2 -Wall -Wextra -I "$GFX" -I "$SRC" \
  -c -o "$WORKDIR/osxui_headless.o" "$SRC/headless_main.c" \
  || fail "headless_main.c did not compile"
clang -O2 -Wall -Wextra \
  -o "$WORKDIR/osxui-stub" \
  "$WORKDIR/osxui-stub.o" "$WORKDIR/osxui_fb.o" "$WORKDIR/osxui_osgfx_cpu.o" \
  "$WORKDIR/osgfx_glyph.o" "$WORKDIR/osxui_headless.o" \
  || fail "stub headless did not link"
capture_sh STB_OUT STB_ST -- "'$WORKDIR/osxui-stub' --chrome-start -o '$WORKDIR/stub.ppm'"
echo "$STB_OUT"
ck; [[ $STB_ST -eq 0 ]] || fail "stub --chrome-start exited $STB_ST"
MID_STUB=$(python3 "$SCRIPT_DIR/derive.py" ppm "$WORKDIR/stub.ppm" "$MID_X" "$MID_Y")
ck; [[ "$MID_STUB" != "$START_C" ]] \
  || fail "stub Start interior is still START — stub did not miss"
ck; [[ "$MID_STUB" == "$CHROME_C" ]] \
  || fail "stub interior is $MID_STUB, want chrome $CHROME_C (pixel miss)"
echo "ANTI-VACUITY: pass  stub osxui_button → Start interior is chrome"

echo
echo "=== BUILD KERNEL ==="
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
ck; grep -q 'osxui_button_fb' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_button_fb"
ck; grep -q 'osxui_button' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_button"
ck; grep -q 'osxui_scan_button' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_scan_button"
ck; grep -q 'osxui_fb.o' "$CORE_DIR/build/kernel.map" \
  || fail "kernel.map does not name osxui_fb.o"

echo
echo "=== DISK ==="
bash "$CHROME/build-progs.sh" "$WORKDIR/chrome" \
  || fail "de-chrome build-progs.sh failed"
DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$CHROME/make-image.py" "$DISK_IMG" \
  "$WORKDIR/chrome/win.elf" "$WORKDIR/chrome/ping.elf" \
  || fail "make-image.py failed"
echo "IMAGE: pass  FAT16 WIN.ELF + PING.ELF"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

BASE_KEYS="$(typekeys 'fb'),ret,wait:1500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"

start_boot() {
  local keys="$1" settle="$2" keys2="${3:-}" settle2="${4:-}"
  local dir="$WORKDIR/start"
  mkdir -p "$dir"
  local ser="$dir/serial.txt"
  local fb1="$dir/fb.bin"
  local fb2="$dir/fb2.bin"
  local png1="$dir/shot.png"
  local png2="$dir/shot2.png"
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
    local extra=()
    [[ -n "$keys2" ]] && extra+=(--keys2 "$keys2")
    [[ -n "$settle2" ]] && extra+=(--settle2-for "$settle2")
    [[ -n "$keys2" ]] && extra+=(--fb-out2 "$fb2" --png2 "$png2")
    run_status drive_status -- python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --keys "$keys" \
      --settle-for "$settle" \
      --settle-timeout 60 \
      --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
      --fb-out "$fb1" \
      --png "$png1" \
      "${extra[@]}"
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
  DE_FB2="$fb2"
}

echo
echo "=== BOOT START ==="
start_boot "$BASE_KEYS" "WM DE ON" "$RELS_START" "WM DE START"
ck; grep -qE '^WM DE ON' "$DE_SER" || fail "WM DE ON did not appear"
ck; grep -qE '^WM DE START' "$DE_SER" || fail "Start click did not print WM DE START"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" || fail "Start boot faulted"
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$DE_SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; [[ -s "$DE_FB" ]] || fail "no framebuffer before click"
ck; python3 "$PROBE" "$DE_FB" "$PITCH" "$AABB_X" "$AABB_Y" "0x$CHROME_C" "start_aabb" \
  || fail "Start AABB is not chrome — still a square blit or missing strip"
ck; python3 "$PROBE" "$DE_FB" "$PITCH" "$FILL_X" "$MID_Y" "0x$START_C" "start_fill" \
  || fail "Start interior is not START — osxui_button did not paint"
# The pill is labelled, so an interior probe alone would now pass on a bare
# pill. Require the label's ink inside it too.
capture_sh LBL_OUT LBL_STATUS -- "python3 - '$DE_FB' '$PITCH' '$LABEL_X0' '$LABEL_X1' '$LABEL_Y0' '$LABEL_Y1' '$LABEL_FG' <<'PY'
import sys
fb, pitch = sys.argv[1], int(sys.argv[2])
x0, x1, y0, y1 = (int(a) for a in sys.argv[3:7])
want = int(sys.argv[7], 16) & 0xFFFFFF
blob = open(fb, 'rb').read()
ink = 0
for y in range(y0, y1):
    row = y * pitch
    for x in range(x0, x1):
        o = row + x * 4
        if o + 4 <= len(blob) and int.from_bytes(blob[o:o+4], 'little') & 0xFFFFFF == want:
            ink += 1
if ink == 0:
    raise SystemExit('no %06X ink in the Start label box' % want)
print('    start_label            %d px of %06X in (%d,%d)-(%d,%d)'
      % (ink, want, x0, y0, x1, y1))
PY"
echo "$LBL_OUT"
ck; [[ $LBL_STATUS -eq 0 ]] \
  || fail "the Start pill carries no label ink: $LBL_OUT"
ck; python3 "$PROBE" "$DE_FB" "$PITCH" "$STRIP_X" "$STRIP_Y" "0x$CHROME_C" "strip" \
  || fail "taskbar beside Start is not chrome"
capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$DE_FB" "$PITCH" \
  "$AABB_X" "$AABB_Y" "0x$START_C" "control_square"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "control wanted START on the AABB and passed — square blit still wins"
echo "START: pass  live rrect; AABB chrome; interior START; click prints WM DE START"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-osxui: PASS — live Start via osxui_button; click works ($ASSERTIONS checks)"
exit 0
