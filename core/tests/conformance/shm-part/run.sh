#!/usr/bin/env bash
# core/tests/conformance/shm-part/run.sh
#
# ADR-0160 — partial / offset map of a shm.
# docs/decisions/0160-partial-offset-map-is-a-range-word.md
#
# One ELF in two slots (`proc coop`). Producer creates 4 pages, grants.
# Peer refuses out-of-range offset, maps [1,3) only, reads marks, probes
# page 0 (hole) → #PF. 11 stays fdwait. No help. No new syscall number.
# No Graphite/Venus. Does not touch grow/shrink/multi ABI.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "SHM-PART: FAIL — $1" >&2; exit 1; }
setup_error() { echo "SHM-PART: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=46

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-shm-part.XXXXXX")" \
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
ADR="$CORE_DIR/docs/decisions/0160-partial-offset-map-is-a-range-word.md"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$ADR" ]] || fail "ADR-0160 is missing"

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
ck; grep -q 'shmCapWhole' "$SHM_SRC" \
  || fail "shmCapWhole is missing"
ck; grep -q 'shmCapOff' "$SHM_SRC" \
  || fail "shmCapOff is missing"
ck; grep -q 'shmCapCount' "$SHM_SRC" \
  || fail "shmCapCount is missing"
ck; grep -q 'userFrameRdx' "$SHM_SRC" \
  || fail "shmmap does not read rdx range"
ck; grep -q 'const int shmSysMapNo = 18;' "$SHM_SRC" \
  || fail "shmSysMapNo is not 18"
ck; grep -q 'const int shmSysGrowNo = 34;' "$SHM_SRC" \
  || fail "shmSysGrowNo is not 34"
ck; grep -q 'const int shmSysShrinkNo = 35;' "$SHM_SRC" \
  || fail "shmSysShrinkNo is not 35"
ck; grep -E '^\| 18 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q shmmap \
  || fail "registry row 18 is not shmmap"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -q 'SYS_SHMMAP' "$CORE_DIR/user/libc/oslibc.h" \
  || fail "oslibc.h grew SYS_SHMMAP"
ck; grep -q 'ADR-0160 adds no number' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry missing ADR-0160 note"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing}, expected 2511"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" \
  || fail "verify-syscall-registry.sh failed"
echo "STRUCTURAL: pass  partial/offset on 18  grow/shrink intact  fdwait=11 help=2511"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/shm-part.img"
capture_sh MI_OUT MI_STATUS -- "python3 '$SCRIPT_DIR/make-image.py' '$DISK_IMG' '$WORKDIR/prog.elf' 2>&1"
echo "$MI_OUT"
ck; [[ $MI_STATUS -eq 0 ]] || fail "make-image.py failed"
LBA_A=$(echo "$MI_OUT" | awk '/^slot A:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
LBA_B=$(echo "$MI_OUT" | awk '/^slot B:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read slot LBAs"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

echo
echo "=== BOOT — proc coop partial map ==="
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret,wait:20000"
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
ck; grep -qF 'SHM PART BAD OFF OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "out-of-range offset was not refused"; }
ck; grep -qE 'SHM MAP .* OFF 0001 COUNT 0002' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing SHM MAP … OFF 0001 COUNT 0002"; }
ck; grep -qF 'SHM PART MAP OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "peer did not read partial marks"; }
ck; grep -qF 'SHM PART HOLE PROBE' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "missing hole probe"; }
ck; grep -qF 'SHM PART OWNER OK' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "owner did not finish"; }
ck; ! grep -qF 'PART STILL MAPPED' "$SER" \
  || fail "unmapped hole still mapped — partial was vacuous"
ck; ! grep -qF 'PART BAD OFF NOT REFUSED' "$SER" \
  || fail "out-of-range offset was accepted"
ck; ! grep -qF 'PART MARKS BAD' "$SER" || fail "mapped pages unreadable"
ck; ! grep -qF 'PART MAP FAIL' "$SER" || fail "partial map failed"
ck; grep -qE 'USER FAULT VEC 0E' "$SER" \
  || { sed -n '/SHM PART HOLE PROBE/,$p' "$SER" >&2; fail "hole did not fault"; }
ck; python3 - "$SER" <<'PY' || fail "ordering wrong: bad-off then map then hole then fault"
import sys
t = open(sys.argv[1]).read()
i_bad = t.find('SHM PART BAD OFF OK')
i_map = t.find('SHM PART MAP OK')
i_pr = t.find('SHM PART HOLE PROBE')
i_pf = t.find('USER FAULT VEC 0E')
if not (i_bad >= 0 and i_map > i_bad and i_pr > i_map and i_pf > i_pr):
    raise SystemExit('bad=%d map=%d probe=%d pf=%d' % (i_bad, i_map, i_pr, i_pf))
PY
echo "ASSERT: pass  out-of-range refuse; partial read; hole #PF"

require_assertions "$ASSERTIONS_REQUIRED"
echo "SHM-PART: PASS — partial / offset map of a shm (ADR-0160)"
