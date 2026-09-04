#!/usr/bin/env bash
# core/tests/conformance/wm-clip/run.sh
#
# ADR-0183 — clipboard offer/take between two processes.
# A offers "CLIPOK"; B takes and prints WM CLIP B GOT CLIPOK.
# No new syscall. 11 stays fdwait. wmStore stays 448.
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

fail() { echo "WM-clip: FAIL — $1" >&2; exit 1; }
setup_error() { echo "WM-clip: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=28

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-wm-clip.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'wmOpOffer = 3' "$CORE_DIR/kernel/wmext.dart" || fail "wmOpOffer missing"
ck; grep -q 'wmOpTake = 4' "$CORE_DIR/kernel/wmext.dart" || fail "wmOpTake missing"
ck; grep -q 'shmMetaClipReg = 9' "$CORE_DIR/kernel/shm.dart" || fail "clip meta missing"
ck; grep -q 'part .wmext.dart.' "$CORE_DIR/kernel/kmain.dart" || fail "wmext not in kmain"
STORE=$(awk '/^const int wmStoreBytes = /{print $5}' "$CORE_DIR/kernel/wm.dart" | tr -d ';')
ck; [[ "$STORE" -eq 704 ]] || fail "wmStoreBytes is $STORE, expected 704"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] || fail "last .bss is $LAST_BSS"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "11 is no longer fdwait"
ck; ! grep -qE 'const int \w+SysNo = 11;' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel file claimed syscall 11"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing}"
echo "STRUCTURAL: pass  offer/take, wmStore=704, wmevent last, fdwait=11"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
DISK_IMG="$WORKDIR/clip.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/a.elf" "$WORKDIR/b.elf" \
  || fail "make-image failed"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower()) for c in sys.argv[1]))
" "$1"; }

echo
echo "=== BOOT ==="
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn A.ELF'),ret,wait:3000"
KEYS="$KEYS,$(typekeys 'proc spawn B.ELF'),ret,wait:12000"

SER="$WORKDIR/serial.txt"
: >"$SER"
port=$(python3 "$PICKER") || fail "pick-port failed"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$WORKDIR/shot.png" --screen-text "$WORKDIR/screen.txt" \
  --keys "$KEYS"
kill "$qemu_pid" 2>/dev/null || true
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  tail -100 "$SER" >&2
  fail "qmp-drive exited $drive_status"
fi
cp "$SER" "$CORE_DIR/build/wm-clip-serial.txt"

echo
echo "=== ASSERT ==="
ck; grep -qF 'WM CLIP A OFFERED' "$SER" || { tail -80 "$SER" >&2; fail "A did not offer"; }
ck; grep -qE 'WM OFFER R [0-9] ' "$SER" || fail "missing WM OFFER kernel line"
ck; grep -qF 'WM CLIP B GOT CLIPOK' "$SER" || { tail -80 "$SER" >&2; fail "B did not get CLIPOK"; }
ck; grep -qE 'WM TAKE R [0-9] ' "$SER" || fail "missing WM TAKE kernel line"
ck; ! grep -qF 'WM CLIP B GOT FAIL' "$SER" || fail "negative got line appeared"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" || fail "fault during boot"
echo "WM-clip: PASS — A offered CLIPOK, B took the same bytes"
exit 0
