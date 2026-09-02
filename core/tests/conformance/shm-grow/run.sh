#!/usr/bin/env bash
# core/tests/conformance/shm-grow/run.sh
#
# ADR-0150 — shmgrow past create / past attach.
# docs/decisions/0150-shmgrow-extends-a-mapped-region.md
#
# PROG.ELF creates 2 pages, grows to 5, writes the new pages, refuses
# same/shrink/oversize, then attaches a second region and grows past
# the attach paint size. Kernel prints SHM GROW. 11 stays fdwait.
# No help line. No oslibc name for 34.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "SHM-GROW: FAIL — $1" >&2; exit 1; }
setup_error() { echo "SHM-GROW: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=36

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-shm-grow.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SHM_SRC="$CORE_DIR/kernel/shm.dart"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$CORE_DIR/docs/decisions/0150-shmgrow-extends-a-mapped-region.md" ]] \
  || fail "ADR-0150 is missing"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" || fail "snapshot failed"
KERNEL_ELF="$WORKDIR/kernel.elf"
KERN_END=$(x86_64-elf-nm "$KERNEL_ELF" | awk '$3=="__kernel_end"{print $1; exit}')
ck; [[ -n "$KERN_END" ]] || fail "no __kernel_end"
ck; [[ $((16#$KERN_END)) -le 4194304 ]] \
  || fail "kernel __kernel_end 0x$KERN_END above vmFineBytes"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'const int shmSysGrowNo = 34;' "$SHM_SRC" \
  || fail "shmSysGrowNo is not 34"
ck; grep -q 'void shmSysGrow(' "$SHM_SRC" \
  || fail "shmSysGrow is missing"
ck; grep -q 'shmSysGrowNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart does not dispatch shmgrow"
ck; grep -E '^\| 34 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q shmgrow \
  || fail "registry row 34 is not shmgrow"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -q 'SYS_SHMGROW' "$CORE_DIR/user/libc/oslibc.h" \
  || fail "oslibc.h grew SYS_SHMGROW — leave 34 unnamed like the other shm doors"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing}, expected 2511"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" \
  || fail "verify-syscall-registry.sh failed"
echo "STRUCTURAL: pass  shmgrow=34 fdwait=11 help=2511 no oslibc name"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/shm-grow.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/prog.elf" \
  || fail "make-image.py failed"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

echo
echo "=== BOOT — run prog.elf ==="
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'run prog.elf'),ret,wait:15000"
mkdir -p "$WORKDIR/boot"
SER="$WORKDIR/boot/serial.txt"
: >"$SER"
ck; port=$(python3 "$PICKER") || fail "pick-port failed"
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
  >"$WORKDIR/boot/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$WORKDIR/boot/shot.png" --screen-text "$WORKDIR/boot/screen.txt" \
  --keys "$KEYS"
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  tail -80 "$SER" >&2
  fail "qmp-drive.py exited $drive_status"
fi
ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  fail "qemu exited $qemu_status"
fi
ck; [[ -s "$SER" ]] || fail "no serial"

echo
echo "=== ASSERT ==="
ck; grep -qF 'SHM GROW OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing SHM GROW OK"; }
ck; grep -qE 'SHM GROW R [0-9] PAGES 0005' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing first SHM GROW R … PAGES 0005"; }
ck; grep -qE 'SHM GROW R [0-9] PAGES 0006' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing grow-past-attach SHM GROW … 0006"; }
ck; ! grep -qF 'GROW FAIL' "$SER" || fail "serial carries GROW FAIL"
ck; ! grep -qF 'GROW OLD LOST' "$SER" || fail "old pages lost after grow"
ck; ! grep -qF 'GROW NEW BAD' "$SER" || fail "new pages not writable after grow"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "fault during boot"; }
echo "ASSERT: pass  grow after create and after attach; BadLen refusals silent"

require_assertions "$ASSERTIONS_REQUIRED"
echo "SHM-GROW: PASS — shmgrow 34 extended a mapped region past create and past attach (ADR-0150)"
