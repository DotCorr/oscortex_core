#!/usr/bin/env bash
# core/tests/conformance/mmap-file/run.sh
#
# ADR-0164 — file-backed shm + demand paging (GAP-0235 remainder).
# docs/decisions/0164-shmfile-demand-fills-from-fat.md
#
# PROG.ELF: open PLANT.DAT → shmfile → P 0 leaves → touch page0/1 →
# DEMAND fill → plant bytes match → RO store #PF.
# 11 stays fdwait. No help. No oslibc name. No Graphite/Venus.
# Does not break mmap-prot / shm-*.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "MMAP-FILE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "MMAP-FILE: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=49

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-mmap-file.XXXXXX")" \
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
ISR_SRC="$CORE_DIR/kernel/interrupts.dart"
ADR="$CORE_DIR/docs/decisions/0164-shmfile-demand-fills-from-fat.md"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$ADR" ]] || fail "ADR-0164 is missing"

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
ck; grep -q 'const int shmSysFileNo = 37;' "$SHM_SRC" \
  || fail "shmSysFileNo is not 37"
ck; grep -q 'void shmSysFile(' "$SHM_SRC" \
  || fail "shmSysFile is missing"
ck; grep -q 'u64 shmDemandTry(' "$SHM_SRC" \
  || fail "shmDemandTry is missing"
ck; grep -q 'shmRegLiveFile' "$SHM_SRC" \
  || fail "shmRegLiveFile is missing"
ck; grep -q 'shmDemandTry' "$ISR_SRC" \
  || fail "interrupts.dart never calls shmDemandTry"
ck; grep -q 'shmSysFileNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart does not dispatch shmfile"
ck; grep -E '^\| 37 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q shmfile \
  || fail "registry row 37 is not shmfile"
ck; grep -E '^\| 36 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q mprotect \
  || fail "registry row 36 is no longer mprotect"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -q 'SYS_SHMFILE' "$CORE_DIR/user/libc/oslibc.h" \
  || fail "oslibc.h grew SYS_SHMFILE"
ck; grep -q 'Why `shmfile` is 37' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry missing ADR-0164 note"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing}, expected 2511"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" \
  || fail "verify-syscall-registry.sh failed"
echo "STRUCTURAL: pass  shmfile=37 demand fill  fdwait=11 help=2511"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/mmap-file.img"
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
KEYS="$KEYS,$(typekeys 'run prog.elf'),ret,wait:20000"
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
ck; grep -qF 'MMAP FILE OPEN OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "open PLANT.DAT failed"; }
ck; grep -qE 'SHM FILE R .* PAGES 0002 SIZE 00002000' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing SHM FILE … PAGES 0002 SIZE 00002000"; }
ck; grep -qF 'MMAP FILE CREATE OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing MMAP FILE CREATE OK"; }
# Anti-vacuity: create left leaves not present (P 0) before any DEMAND.
ck; python3 - "$SER" <<'PY' || fail "create did not report P 0 leaves before demand"
import sys, re
t = open(sys.argv[1]).read()
i_file = t.find('SHM FILE R')
i_dem = t.find('SHM DEMAND')
if i_file < 0 or i_dem < 0 or i_dem <= i_file:
    raise SystemExit('file/demand order')
chunk = t[i_file:i_dem]
pages = re.findall(r'^SHM PAGE ([0-9A-F]{16}) P ([01])', chunk, re.M)
if len(pages) < 2:
    raise SystemExit('need >=2 SHM PAGE lines before DEMAND, got %d' % len(pages))
for va, p in pages[:2]:
    if p != '0':
        raise SystemExit('page %s was P %s before demand — pre-faulted' % (va, p))
print('pre-demand P 0 x%d' % len(pages[:2]))
PY
ck; grep -qE 'SHM DEMAND R .* PAGE 0000' "$SER" \
  || { sed -n '/MMAP FILE CREATE OK/,$p' "$SER" >&2; fail "missing DEMAND page 0"; }
ck; grep -qE 'SHM DEMAND R .* PAGE 0001' "$SER" \
  || { sed -n '/MMAP FILE CREATE OK/,$p' "$SER" >&2; fail "missing DEMAND page 1"; }
ck; grep -qF 'MMAP FILE PAGE0 OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "page 0 plant mismatch"; }
ck; grep -qF 'MMAP FILE PAGE1 OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "page 1 plant mismatch"; }
ck; grep -qF 'MMAP FILE OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing MMAP FILE OK"; }
ck; grep -qF 'MMAP FILE WRITE PROBE' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing write probe"; }
ck; ! grep -qF 'FILE STILL WRITABLE' "$SER" \
  || fail "RO file page still writable"
ck; ! grep -qF 'FILE PAGE0 BAD' "$SER" || fail "page0 plant wrong"
ck; ! grep -qF 'FILE PAGE1 BAD' "$SER" || fail "page1 plant wrong"
ck; grep -qE 'USER FAULT VEC 0E' "$SER" \
  || { sed -n '/MMAP FILE WRITE PROBE/,$p' "$SER" >&2; fail "RO store did not fault"; }
ck; python3 - "$SER" <<'PY' || fail "ordering wrong: file→P0→demand→match→probe→fault"
import sys
t = open(sys.argv[1]).read()
i_cr = t.find('MMAP FILE CREATE OK')
i_d0 = t.find('SHM DEMAND R')
i_p0 = t.find('MMAP FILE PAGE0 OK')
i_d1 = t.find('SHM DEMAND R', i_d0 + 1) if i_d0 >= 0 else -1
i_p1 = t.find('MMAP FILE PAGE1 OK')
i_ok = t.find('MMAP FILE OK')
i_pr = t.find('MMAP FILE WRITE PROBE')
i_pf = t.find('USER FAULT VEC 0E', i_pr if i_pr >= 0 else 0)
if not (i_cr >= 0 and i_d0 > i_cr and i_p0 > i_d0 and i_d1 > i_p0
        and i_p1 > i_d1 and i_ok > i_p1 and i_pr > i_ok and i_pf > i_pr):
    raise SystemExit('cr=%d d0=%d p0=%d d1=%d p1=%d ok=%d pr=%d pf=%d'
                     % (i_cr, i_d0, i_p0, i_d1, i_p1, i_ok, i_pr, i_pf))
PY
echo "ASSERT: pass  file map + demand fill + plant match + RO #PF"

require_assertions "$ASSERTIONS_REQUIRED"
echo "MMAP-FILE: PASS — shmfile 37 + demand fill from FAT (ADR-0164)"
