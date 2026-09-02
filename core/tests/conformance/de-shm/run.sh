#!/usr/bin/env bash
# core/tests/conformance/de-shm/run.sh
#
# ADR-0109 — shmMax / window slots are 4. Three derived ELFs each
# attach a surface; all three stay mapped. No new syscall. 11 is
# fdwait. wmeventStore stays last in .bss.
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

fail() { echo "DE-shm: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-shm: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=30

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-shm.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
[[ -f "$PROBE" ]] || setup_error "probe.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
DISK_IMG="$WORKDIR/shm.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/a.elf" "$WORKDIR/b.elf" "$WORKDIR/c.elf" \
  || fail "make-image.py could not write the volume"
if command -v fsck_msdos >/dev/null 2>&1 || [[ -x /sbin/fsck_msdos ]]; then
  FSCK="${FSCK:-fsck_msdos}"
  [[ -x /sbin/fsck_msdos ]] && FSCK=/sbin/fsck_msdos
  capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
else
  ck; true
fi
echo "IMAGE: pass  A.ELF + B.ELF + C.ELF"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' \
  '$CORE_DIR/kernel/shm.dart' \
  '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/wmevent.dart' \
  '$CORE_DIR/kernel/wmde.dart' \
  '$CORE_DIR/kernel/wmchrome.dart' \
  '$CORE_DIR/kernel/fb.dart' \
  '$SCRIPT_DIR/a.c' \
  '$SCRIPT_DIR/b.c' \
  '$SCRIPT_DIR/c.c' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
SHM_MAX=$(d shm_max); WM_MAX=$(d wm_max); EV_SLOTS=$(d ev_slots)
A_PX=$(d a_px); A_PY=$(d a_py); A_FILL=$(d a_fill)
B_PX=$(d b_px); B_PY=$(d b_py); B_FILL=$(d b_fill)
C_PX=$(d c_px); C_PY=$(d c_py); C_FILL=$(d c_fill)
RELS_START0=$(d rels_start0); RELS_ROW0=$(d rels_row0)
RELS_START1=$(d rels_start1); RELS_ROW1=$(d rels_row1)
RELS_START2=$(d rels_start2); RELS_ROW2=$(d rels_row2)
ck; [[ -n "$SHM_MAX" && -n "$A_PX" && -n "$C_FILL" && -n "$RELS_ROW2" ]] \
  || fail "derive.py omitted caps, probes, or start-row clicks"
ck; [[ "$SHM_MAX" -ge 4 ]] || fail "shmMax is $SHM_MAX, need >= 4"
ck; [[ "$WM_MAX" -eq "$SHM_MAX" ]] \
  || fail "wmMaxWindows is $WM_MAX and shmMax is $SHM_MAX"
ck; [[ "$EV_SLOTS" -eq "$WM_MAX" ]] \
  || fail "wmeventSlots is $EV_SLOTS and wmMaxWindows is $WM_MAX"
echo "DERIVED: shmMax=$SHM_MAX  probes A($A_PX,$A_PY) B($B_PX,$B_PY) C($C_PX,$C_PY)"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
ck; grep -q '| 11 |' "$CORE_DIR/docs/syscall-registry.md" \
  || grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "11 is no longer fdwait's reservation"
ck; ! grep -qE 'const int \w+SysNo = 11;' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel file claimed syscall 11"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'shm' in blob.lower() or b'de-shm' in blob.lower():
    raise SystemExit('shm appeared inside shellStrHelp')
print('    shellStrHelp has no shm line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "shm appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
echo "STRUCTURAL: pass  shmMax=$SHM_MAX, 11 fdwait, wmeventStore last, no help"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

# Start clicks, not typed spawn: after the first surface attaches,
# keyboard focus is a compositor slot (ADR-0062) and further typing
# does not reach the shell.
BASE_KEYS="$(typekeys 'fb'),ret,wait:1500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"
BASE_KEYS="$BASE_KEYS,$RELS_START0,wait:300,$RELS_ROW0,wait:800"
BASE_KEYS="$BASE_KEYS,$RELS_START1,wait:300,$RELS_ROW1,wait:800"
BASE_KEYS="$BASE_KEYS,$RELS_START2,wait:300,$RELS_ROW2"

shm_boot() {
  local name="$1" keys="$2" settle="$3"
  local dir="$WORKDIR/$name"
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
      --keys "$keys" \
      --settle-for "$settle" \
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
    fail "$name: comp-drive.py exited $drive_status"
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$dir/qemu.log" >&2
    fail "$name: qemu exited $qemu_status"
  fi
  [[ -s "$ser" ]] || fail "$name: no serial"
  SHM_SER="$ser"
  SHM_FB="$fb1"
}

pitch_of() {
  grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$1" | awk '{print $NF}'
}

havere() { grep -qE -- "$1" "$SHM_SER" || { sed -n '/M1 END/,$p' "$SHM_SER" >&2; fail "$2"; }; }

echo
echo "=== BOOT THREE SURFACES ==="
shm_boot three "$BASE_KEYS" "DE SHM C COMMIT"
ck; havere '^WM DE ON' "WM DE ON did not appear"
ck; havere 'DE SHM A' "A.ELF did not print DE SHM A"
ck; havere 'DE SHM B' "B.ELF did not print DE SHM B"
ck; havere 'DE SHM C' "C.ELF did not print DE SHM C"
ck; havere 'DE SHM A COMMIT' "A.ELF did not commit"
ck; havere 'DE SHM B COMMIT' "B.ELF did not commit"
ck; havere 'DE SHM C COMMIT' "C.ELF did not commit"
ATTACHES=$(grep -cE '^WM ATTACH W ' "$SHM_SER" | tr -d ' ')
ck; [[ "$ATTACHES" -ge 3 ]] || fail "WM ATTACH count is $ATTACHES, need >= 3"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SHM_SER" \
  || fail "three-surface boot faulted"
ck; ! grep -qE 'WM RET |SHM NOSPACE|wmRetNoSpace' "$SHM_SER" \
  || fail "a spawn was refused as no-space"
PITCH=$((16#$(pitch_of "$SHM_SER")))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; [[ -s "$SHM_FB" ]] || fail "three-surface boot missing framebuffer dump"
ck; python3 "$PROBE" "$SHM_FB" "$PITCH" "$A_PX" "$A_PY" "$A_FILL" "surf_a" \
  || fail "surface A fill is gone — the third spawn displaced it"
ck; python3 "$PROBE" "$SHM_FB" "$PITCH" "$B_PX" "$B_PY" "$B_FILL" "surf_b" \
  || fail "surface B fill is gone — the third spawn displaced it"
ck; python3 "$PROBE" "$SHM_FB" "$PITCH" "$C_PX" "$C_PY" "$C_FILL" "surf_c" \
  || fail "surface C fill is missing"
echo "THREE: pass  $ATTACHES attaches; A+B+C fills still mapped"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-shm: PASS ($ASSERTIONS checks) — shmMax=$SHM_MAX, three surfaces stay mapped"
exit 0
