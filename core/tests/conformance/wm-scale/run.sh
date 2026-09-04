#!/usr/bin/env bash
# core/tests/conformance/wm-scale/run.sh — ADR-0185 integer scale 2.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && source /Users/ghostportal/Desktop/dc_sys/env.sh
fail() { echo "WM-scale: FAIL — $1" >&2; exit 1; }
source "$SCRIPT_DIR/../_lib/harness.sh"
export OSGFX_SKIA=0 OSGFX_CRT=0 OSMEDIA_FFMPEG=0
ASSERTIONS_REQUIRED=20

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-wm-scale.XXXXXX")"; WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT
KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"; ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build"

ck; grep -q 'wmWinScaleOf' "$CORE_DIR/kernel/wmext.dart" || fail "scale helper"
ck; grep -q 'wmWinScaleShift' "$CORE_DIR/kernel/wmext.dart" || fail "scale shift"
STORE=$(awk '/^const int wmStoreBytes = /{print $5}' "$CORE_DIR/kernel/wm.dart" | tr -d ';')
ck; [[ "$STORE" -eq 1472 ]] || fail "wmStore $STORE"

capture BP_OUT BP -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"; ck; [[ $BP -eq 0 ]] || fail "progs"
python3 "$SCRIPT_DIR/make-image.py" "$WORKDIR/scale.img" "$WORKDIR/prog.elf" || fail "image"

FILL_A=0x00E05030; FILL_B=0x0030A070
# surface (120,120) 40x40; pixel (0,0)->A, (1,0)->B
AX=120; AY=120; BX=121; BY=120

typekeys() { python3 -c "import sys; print(','.join({' ':'spc','.':'dot'}.get(c,c.lower()) for c in sys.argv[1]))" "$1"; }
KEYS="$(typekeys 'fb'),ret,wait:1500,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn PROG.ELF'),ret,wait:4000"

SER="$WORKDIR/serial.txt"; FB="$WORKDIR/fb.bin"; : >"$SER"
port=$(python3 "$PICKER") || fail "port"
timeout 180 qemu-system-x86_64 -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
  -serial "file:$SER" -display none -no-reboot \
  -drive "file=$WORKDIR/scale.img,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" >"$WORKDIR/qemu.log" 2>&1 &
qid=$!
run_status ds -- python3 "$DRIVER" --port "$port" --serial "$SER" --wait-for 'M1 END\n' \
  --keys "$KEYS" --settle-for 'WM SCALE OK' --settle-timeout 40 \
  --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' --fb-out "$FB" --png "$WORKDIR/shot.png"
kill "$qid" 2>/dev/null || true; await qs "$qid"
ck; [[ $ds -eq 0 ]] || { tail -60 "$SER" >&2; fail "drive $ds"; }
cp "$SER" "$CORE_DIR/build/wm-scale-serial.txt"
PITCH=$(grep -m1 -oE 'PITCH [0-9A-F]{8}' "$SER" | awk '{print $2}')
PITCH=$((16#$PITCH))

ck; grep -qF 'WM SCALE OK' "$SER" || fail "no SCALE OK"
ck; grep -qE 'SCL 2' "$SER" || fail "attach missing SCL 2"
ck; python3 "$PROBE" "$FB" "$PITCH" "$AX" "$AY" "$(printf '%08X' $FILL_A)" a0 || fail "scale (0,0)"
ck; python3 "$PROBE" "$FB" "$PITCH" "$BX" "$BY" "$(printf '%08X' $FILL_B)" b0 || fail "scale (1,0)"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" || fail "fault"
echo "WM-scale: PASS — 2x buffer maps to surface pixels"
exit 0
