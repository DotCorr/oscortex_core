#!/usr/bin/env bash
# core/tests/conformance/mmap-prot/run.sh
#
# ADR-0163 — mprotect + MAP_FIXED on shm.
# docs/decisions/0163-mprotect-and-map-fixed-are-shm-doors.md
#
# PROG.ELF: create → FIXED wrong VA refused → FIXED overlap refused →
# mprotect RO → exec/escalate refused → store #PF.
# 11 stays fdwait. No help. No oslibc name. No Graphite/Venus.
# Does not touch grow/shrink/partial ABI.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "MMAP-PROT: FAIL — $1" >&2; exit 1; }
setup_error() { echo "MMAP-PROT: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=48

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-mmap-prot.XXXXXX")" \
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
VM_SRC="$CORE_DIR/kernel/vm.dart"
ADR="$CORE_DIR/docs/decisions/0163-mprotect-and-map-fixed-are-shm-doors.md"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$ADR" ]] || fail "ADR-0163 is missing"

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
ck; grep -q 'const int shmSysMprotectNo = 36;' "$SHM_SRC" \
  || fail "shmSysMprotectNo is not 36"
ck; grep -q 'void shmSysMprotect(' "$SHM_SRC" \
  || fail "shmSysMprotect is missing"
ck; grep -q 'const int shmMapFixed = 0x100;' "$SHM_SRC" \
  || fail "shmMapFixed is missing"
ck; grep -q 'shmRetBadFixed' "$SHM_SRC" \
  || fail "shmRetBadFixed is missing"
ck; grep -q 'vmShmProtect' "$VM_SRC" \
  || fail "vmShmProtect is missing"
ck; grep -q 'shmSysMprotectNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart does not dispatch mprotect"
ck; grep -E '^\| 36 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q mprotect \
  || fail "registry row 36 is not mprotect"
ck; grep -E '^\| 35 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q shmshrink \
  || fail "registry row 35 is no longer shmshrink"
ck; grep -E '^\| 34 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q shmgrow \
  || fail "registry row 34 is no longer shmgrow"
ck; grep -E '^\| 18 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q shmmap \
  || fail "registry row 18 is not shmmap"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -q 'SYS_MPROTECT' "$CORE_DIR/user/libc/oslibc.h" \
  || fail "oslibc.h grew SYS_MPROTECT"
ck; grep -q 'Why `mprotect` is 36' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry missing ADR-0163 note"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing}, expected 2511"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" \
  || fail "verify-syscall-registry.sh failed"
echo "STRUCTURAL: pass  mprotect=36 MAP_FIXED on 18  grow/shrink intact  fdwait=11 help=2511"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/mmap-prot.img"
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
ck; grep -qF 'MMAP FIXED BAD OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "wrong MAP_FIXED VA was not refused"; }
ck; grep -qF 'MMAP FIXED OVERLAP OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "MAP_FIXED overlap was not refused"; }
ck; grep -qE 'SHM PROT R .* PERM 1' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing SHM PROT R … PERM 1"; }
ck; grep -qF 'MMAP PROT EXEC OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "mprotect EXEC was not refused"; }
ck; grep -qF 'MMAP PROT ESC OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "mprotect escalate was not refused"; }
ck; grep -qF 'MMAP PROT OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing MMAP PROT OK"; }
ck; grep -qF 'MMAP PROT WRITE PROBE' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing write probe"; }
ck; ! grep -qF 'PROT STILL WRITABLE' "$SER" \
  || fail "RO page still writable — mprotect was vacuous"
ck; ! grep -qF 'PROT FIXED BAD NOT REFUSED' "$SER" \
  || fail "wrong MAP_FIXED was accepted"
ck; ! grep -qF 'PROT FIXED OVERLAP NOT REFUSED' "$SER" \
  || fail "MAP_FIXED overlap was accepted"
ck; ! grep -qF 'PROT EXEC NOT REFUSED' "$SER" || fail "EXEC mprotect accepted"
ck; ! grep -qF 'PROT ESC NOT REFUSED' "$SER" || fail "escalate mprotect accepted"
ck; grep -qE 'USER FAULT VEC 0E' "$SER" \
  || { sed -n '/MMAP PROT WRITE PROBE/,$p' "$SER" >&2; fail "RO store did not fault"; }
ck; python3 - "$SER" <<'PY' || fail "ordering wrong: fixed then prot then probe then fault"
import sys
t = open(sys.argv[1]).read()
i_bad = t.find('MMAP FIXED BAD OK')
i_ov = t.find('MMAP FIXED OVERLAP OK')
i_ok = t.find('MMAP PROT OK')
i_pr = t.find('MMAP PROT WRITE PROBE')
i_pf = t.find('USER FAULT VEC 0E')
if not (i_bad >= 0 and i_ov > i_bad and i_ok > i_ov and i_pr > i_ok and i_pf > i_pr):
    raise SystemExit('bad=%d ov=%d ok=%d probe=%d pf=%d'
                     % (i_bad, i_ov, i_ok, i_pr, i_pf))
PY
echo "ASSERT: pass  FIXED bad+overlap; mprotect RO; exec/esc refuse; write #PF"

require_assertions "$ASSERTIONS_REQUIRED"
echo "MMAP-PROT: PASS — mprotect 36 + MAP_FIXED on shm (ADR-0163)"
