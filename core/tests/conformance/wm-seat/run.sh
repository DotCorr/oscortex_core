#!/usr/bin/env bash
# core/tests/conformance/wm-seat/run.sh — ADR-0186 two seats, two surfaces.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && source /Users/ghostportal/Desktop/dc_sys/env.sh
fail() { echo "WM-seat: FAIL — $1" >&2; exit 1; }
source "$SCRIPT_DIR/../_lib/harness.sh"
export OSGFX_SKIA=0 OSGFX_CRT=0 OSMEDIA_FFMPEG=0
ASSERTIONS_REQUIRED=20

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-wm-seat.XXXXXX")"; WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT
KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"

echo "=== BUILD ==="
capture_sh BO BS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"; echo "$BO"; ck; [[ $BS -eq 0 ]] || fail "build"
ck; grep -q 'wmOpSeat = 6' "$CORE_DIR/kernel/wmext.dart" || fail "wmOpSeat"
ck; grep -q 'wmSeatCount = 2' "$CORE_DIR/kernel/wmext.dart" || fail "wmSeatCount"
STORE=$(awk '/^const int wmStoreBytes = /{print $5}' "$CORE_DIR/kernel/wm.dart" | tr -d ';')
ck; [[ "$STORE" -eq 448 ]] || fail "wmStore"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait || fail "fdwait"

# single prog
CFLAGS=(-c -target x86_64-unknown-none-elf -ffreestanding -nostdlib -fno-pic -fno-pie
  -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror)
clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$WORKDIR/prog.o" || fail "clang"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$WORKDIR/prog.elf" "$WORKDIR/prog.o" || fail "ld"
python3 "$CORE_DIR/tests/conformance/wm-scale/make-image.py" "$WORKDIR/seat.img" "$WORKDIR/prog.elf" || fail "image"

typekeys() { python3 -c "import sys; print(','.join({' ':'spc','.':'dot'}.get(c,c.lower()) for c in sys.argv[1]))" "$1"; }
KEYS="$(typekeys 'fb'),ret,wait:1500,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn PROG.ELF'),ret,wait:6000"

SER="$WORKDIR/serial.txt"; : >"$SER"
port=$(python3 "$PICKER") || fail "port"
timeout 180 qemu-system-x86_64 -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
  -serial "file:$SER" -display none -no-reboot \
  -drive "file=$WORKDIR/seat.img,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" >"$WORKDIR/qemu.log" 2>&1 &
qid=$!
run_status ds -- python3 "$DRIVER" --port "$port" --serial "$SER" --wait-for 'M1 END\n' \
  --png "$WORKDIR/shot.png" --screen-text "$WORKDIR/screen.txt" --keys "$KEYS"
kill "$qid" 2>/dev/null || true; await qs "$qid"
ck; [[ $ds -eq 0 ]] || { tail -80 "$SER" >&2; fail "drive $ds"; }
cp "$SER" "$CORE_DIR/build/wm-seat-serial.txt"

ck; grep -qF 'WM SEAT BITS 3' "$SER" || { grep 'WM SEAT' "$SER" >&2; fail "BITS 3"; }
ck; grep -qF 'WM SEAT OK' "$SER" || fail "no SEAT OK"
ck; grep -cE '^WM SEAT 0 S ' "$SER" | awk '{exit !($1>=2)}' || fail "need two seat uart lines"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" || fail "fault"
echo "WM-seat: PASS — seat0 and seat1 focus two different surfaces"
exit 0
