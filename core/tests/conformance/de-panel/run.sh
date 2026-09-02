#!/usr/bin/env bash
# core/tests/conformance/de-panel/run.sh
#
# ADR-0136 — reflection-panel hex pid through osgfx_fill_glyph / osxui_hex.
# The live owner is visible as derived foreground pixels matching fbFont8x16.
# Disable glyphs → the sample is the panel/row fill, not the letter.
# de-chrome / de-wm row probes stay the fill. Title-bar PID stays de-title.
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

fail() { echo "DE-panel: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-panel: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run.
ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-panel.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
GLYPH="$CORE_DIR/tests/conformance/de-glyph"
CHROME="$CORE_DIR/tests/conformance/de-chrome"
SITIN="$CORE_DIR/scripts/sit-in.sh"
HDR="$CORE_DIR/plat/osgfx/osgfx.h"
UI_H="$CORE_DIR/plat/osxui/osxui.h"
UI_C="$CORE_DIR/plat/osxui/osxui.c"
GLYPH_C="$CORE_DIR/plat/osgfx/osgfx_glyph.c"
SW="$CORE_DIR/plat/osgfx/osgfx_sw.c"
SKIA="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
HEADLESS="$CORE_DIR/build/osxui-headless"
MATCH="$GLYPH/match.py"
DEDE="$CORE_DIR/kernel/wmde.dart"
HEAP="$CORE_DIR/kernel/heap.dart"

ck; [[ -f "$DRIVER" ]] || fail "no comp-drive.py"
ck; [[ -f "$GLYPH_C" ]] || fail "no osgfx_glyph.c"
ck; grep -q 'osgfx_fill_glyph' "$HDR" || fail "osgfx.h has no osgfx_fill_glyph"
ck; grep -q 'void osxui_hex' "$UI_H" || fail "osxui.h has no osxui_hex"
ck; grep -q 'void osxui_hex' "$UI_C" || fail "osxui.c has no osxui_hex"
ck; grep -q 'osxui_label' "$UI_C" || fail "osxui_hex does not call osxui_label"
ck; grep -q 'osxui_hex_fb' "$GLYPH_C" || fail "osgfx_glyph.c has no osxui_hex_fb"
ck; grep -q 'osxui_hex_fb' "$DEDE" || fail "wmde.dart does not call osxui_hex_fb"
ck; grep -q 'wmPanelPidDraw' "$DEDE" || fail "wmde.dart has no wmPanelPidDraw"
ck; if grep -nE 'put_px|fbPutPixel' "$DEDE" | grep -q 'PanelPid\|PanelLabel\|hex pid'; then
  fail "panel pid uses put_px — captions must call osgfx"
fi
ck; ! grep -qE 'const int \w+SysNo' "$DEDE" \
  || fail "wmde.dart allocated a syscall"
ck; grep -q 'heapMaxInc = 2097152' "$HEAP" \
  || fail "heapMaxInc moved — TAP/FILES must stay 2 MiB"
ck; ! grep -q 'osgfx_fill_glyph' "$SW" \
  || fail "osgfx_sw.c grew fill_glyph — that file is mid-swap"
ck; ! grep -q 'osgfx_fill_glyph' "$SKIA" \
  || fail "osgfx_skia.cpp grew fill_glyph — Skia agent file"
ck; grep -q "typekeys 'wm de'" "$SITIN" \
  || fail "sit-in.sh does not type wm de"
ck; grep -q "typekeys 'wm gfx'" "$SITIN" \
  || fail "sit-in.sh does not type wm gfx"

echo
echo "=== HELP ==="
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'de-panel' in blob.lower() or b'wm de panel' in blob.lower():
    raise SystemExit('de-panel appeared inside shellStrHelp')
print('    shellStrHelp has no de-panel line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "de-panel appeared in help (GAP-0304)"; }
echo "$HELP_OUT"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
ck; python3 "$SCRIPT_DIR/derive.py" geometry \
  "$CORE_DIR/kernel/wmde.dart" \
  "$CORE_DIR/kernel/wmchrome.dart" \
  "$CORE_DIR/kernel/fb.dart" \
  "$UI_H" > "$MODEL" \
  || fail "derive geometry failed"
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
HOST=$(d host); FG=$(d fg); ROW=$(d row)
GX=$(d glyph_x); GY=$(d glyph_y)
HX=$(d host_x); HY=$(d host_y)
PX=$(d probe_x); PY=$(d probe_y)
RELS_NOTE=$(d rels_note)
EXPECT=$(d expect_bits)
ck; [[ "$HOST" == "DEADBEEF" ]] || fail "derived host stem is $HOST"
ck; [[ -n "$GX" && -n "$GY" && -n "$HX" && -n "$HY" ]] \
  || fail "derive omitted glyph origin"
ck; [[ -n "$RELS_NOTE" ]] || fail "derive omitted notify click"
echo "DERIVED: host $HOST fg $FG at ($GX,$GY) host ($HX,$HY) probe ($PX,$PY)=$ROW expect $EXPECT bits"

echo
echo "=== HOST PANEL / ANTI-VACUITY ==="
capture_sh BUILD_UI BUILD_UI_ST -- "bash '$CORE_DIR/scripts/build-osxui.sh' 2>&1"
echo "$BUILD_UI"
ck; [[ $BUILD_UI_ST -eq 0 ]] || fail "build-osxui.sh exited $BUILD_UI_ST"
ck; [[ -x "$HEADLESS" ]] || fail "no osxui-headless"

FONT="$WORKDIR/font.txt"
ck; python3 "$SCRIPT_DIR/derive.py" font "$CORE_DIR/kernel/fb.dart" > "$FONT" \
  || fail "derive font failed"

capture_sh NOLAB_OUT NOLAB_ST -- "'$HEADLESS' --panel -o '$WORKDIR/nolabel.ppm'"
echo "$NOLAB_OUT"
ck; [[ $NOLAB_ST -eq 0 ]] || fail "headless --panel (no label) exited $NOLAB_ST"
capture_sh FILL2_OUT FILL2_ST -- "python3 -c \"
path = '$WORKDIR/nolabel.ppm'
with open(path, 'rb') as f:
    if f.readline() != b'P6' + bytes([10]):
        raise SystemExit('not P6')
    line = f.readline()
    while line.startswith(b'#'):
        line = f.readline()
    w, h = [int(x) for x in line.split()]
    if f.readline().strip() != b'255':
        raise SystemExit('maxval')
    data = f.read()
x, y = $HX, $HY
i = (y * w + x) * 3
c = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
if c != 0x$ROW:
    raise SystemExit('no-glyph sample 0x%06X is not panel fill 0x$ROW' % c)
print('NOGLYPH_FILL 0x%06X' % c)
\""
ck; [[ $FILL2_ST -eq 0 ]] || { echo "$FILL2_OUT" >&2; fail "no-glyph sample is not the panel fill: $FILL2_OUT"; }
echo "$FILL2_OUT"
echo "ANTI-VACUITY: pass  disable glyphs → sample is panel/row fill, not a letter"

capture_sh LAB_OUT LAB_ST -- "'$HEADLESS' --panel --label DEADBEEF -o '$WORKDIR/label.ppm'"
echo "$LAB_OUT"
ck; [[ $LAB_ST -eq 0 ]] || fail "headless --panel --label DEADBEEF exited $LAB_ST"
ck; echo "$LAB_OUT" | grep -q 'LABEL DEADBEEF' || fail "headless did not print LABEL DEADBEEF"
capture_sh HM_OUT HM_ST -- "python3 '$MATCH' ppm \
  '$WORKDIR/label.ppm' 0 \
  '$HX' '$HY' '$FG' '$FONT' DEADBEEF"
echo "$HM_OUT"
ck; [[ $HM_ST -eq 0 ]] || fail "host DEADBEEF did not match the font: $HM_OUT"
ck; echo "$HM_OUT" | grep -q 'GLYPH_OK' || fail "no GLYPH_OK on host"
echo "HOST: pass  DEADBEEF on the panel matches fbFont8x16; no-glyph is the fill"

echo
echo "=== BUILD KERNEL ==="
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSMEDIA_NO_WIN=1 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
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
ck; grep -q 'osxui_hex_fb' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_hex_fb"

echo
echo "=== DISK (WIN.ELF) ==="
bash "$CHROME/build-progs.sh" "$WORKDIR/chrome" \
  || fail "de-chrome build-progs.sh failed"
ck; [[ -s "$WORKDIR/chrome/win.elf" ]] || fail "no win.elf"
DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$CHROME/make-image.py" "$DISK_IMG" \
  "$WORKDIR/chrome/win.elf" "$WORKDIR/chrome/ping.elf" \
  || fail "make-image.py could not write WIN.ELF"
echo "IMAGE: pass  FAT16 WIN.ELF"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

BASE_KEYS="$(typekeys 'fb'),ret,wait:1500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"
BASE_KEYS="$BASE_KEYS,$(typekeys 'proc spawn WIN.ELF'),ret,wait:400"
PANEL_KEYS="$RELS_NOTE"

panel_boot() {
  local dir="$WORKDIR/panel"
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
      --settle-for "DE WIN COMMIT" \
      --settle-timeout 60 \
      --keys2 "$PANEL_KEYS" \
      --settle2-for "WM DE LIST" \
      --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
      --fb-out "$fb1" \
      --png "$png1" \
      --fb-out2 "$dir/fb2.bin" \
      --png2 "$dir/shot2.png"
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
    fail "panel: comp-drive.py exited $drive_status"
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$dir/qemu.log" >&2
    fail "panel: qemu exited $qemu_status"
  fi
  [[ -s "$ser" ]] || fail "panel: no serial"
  [[ -s "$dir/fb2.bin" ]] || fail "panel: no framebuffer after notify"
  DE_SER="$ser"
  DE_FB="$dir/fb2.bin"
}

echo
echo "=== BOOT PANEL ==="
panel_boot
ck; grep -qE '^WM DE ON' "$DE_SER" || fail "WM DE ON did not appear"
ck; grep -qE 'DE WIN COMMIT' "$DE_SER" || fail "WIN.ELF did not commit"
ck; grep -qE '^WM DE LIST' "$DE_SER" || fail "panel did not print WM DE LIST"
ck; grep -qE '^WM DE SURF ' "$DE_SER" || fail "panel did not print WM DE SURF"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" || fail "panel boot faulted"
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$DE_SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; python3 "$PROBE" "$DE_FB" "$PITCH" "$PX" "$PY" "$ROW" "de_chrome_row" \
  || fail "de-chrome row probe is not the fill — glyphs landed on (x+10)"
# READ the owner field's label out of wmde.dart. It was typed as "PID" here,
# which stopped matching when the chrome-text work renamed wmStrPid's bytes to
# " App " -- and a harness that types the label it expects cannot tell "the
# kernel renamed the field" from "the kernel printed no owner at all". Deriving
# it means the serial line and the @rodata table now have to agree.
SURF_LABEL=$(python3 -c "
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> wmStrPid = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('wmde.dart no longer declares wmStrPid')
b = bytes(int(h, 16) for h in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
sys.stdout.write(b.decode('ascii').strip())
" "$CORE_DIR/kernel/wmde.dart")
ck; [[ -n "$SURF_LABEL" ]] \
  || fail "could not read the WM DE SURF owner label out of wmde.dart"
PID=$(grep -m1 -oE "^WM DE SURF [^ ]+ $SURF_LABEL [0-9A-F]{8}" "$DE_SER" | awk '{print $NF}')
ck; [[ -n "$PID" ]] \
  || fail "could not parse live hex pid from serial (label '$SURF_LABEL')"
ck; [[ ${#PID} -eq 8 ]] || fail "parsed pid $PID is not 8 hex digits"
capture_sh GM_OUT GM_ST -- "python3 '$MATCH' fb \
  '$DE_FB' '$PITCH' '$GX' '$GY' '$FG' '$FONT' '$PID'"
echo "$GM_OUT"
ck; [[ $GM_ST -eq 0 ]] || fail "panel pid $PID did not match the font: $GM_OUT"
ck; echo "$GM_OUT" | grep -q 'GLYPH_OK' || fail "no GLYPH_OK on the panel"
echo "PANEL: pass  hex pid $PID matches fbFont8x16; de-chrome probe still the fill"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-panel: PASS ($ASSERTIONS checks)"
exit 0
