#!/usr/bin/env bash
# core/tests/conformance/de-sitfat/run.sh
#
# ADR-0108 / ADR-0173 — sit-in Start lists FAT 8.3 names. The disk is
# a FAT16 volume (FILES SET PING STUDIO + BROWSE PLAY TAP + APP1), not
# OSCXPRG1 LBA. Start caches the first four ELF names. `wm de` is
# unmoved (ADR-0106). No new syscall, no help line.
#
# Binary:
#   1. sit-in.sh builds/uses this FAT image.
#   2. layout carries BROWSE.ELF PLAY.ELF TAP.ELF; model start_count=04.
#   3. After `wm de` + start click, serial carries WM DE START 04 and
#      a derived 8.3 name (FILES NAME and/or FS OPEN).
#   4. Activating the PING row prints DE CHROME PING (same guts as
#      de-chrome).
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

fail() { echo "DE-sitfat: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-sitfat: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=38

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-sitfat.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SITIN="$CORE_DIR/scripts/sit-in.sh"
[[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
[[ -f "$PROBE" ]] || setup_error "probe.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$SITIN" ]] || setup_error "sit-in.sh not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DISK ==="
capture BUILD_DISK_OUT BD_STATUS -- bash "$SCRIPT_DIR/build-disk.sh" "$WORKDIR"
echo "$BUILD_DISK_OUT"
ck; [[ $BD_STATUS -eq 0 ]] || fail "build-disk.sh exited $BD_STATUS"
DISK_IMG="$WORKDIR/disk.img"
ck; [[ -s "$DISK_IMG" ]] || fail "no disk.img"
ck; ! python3 -c "import sys; b=open(sys.argv[1],'rb').read(8); sys.exit(0 if b==b'OSCXPRG1' else 1)" "$DISK_IMG" \
  || fail "disk.img begins with OSCXPRG1 — sit-in Start would stay empty"
ck; python3 -c "import sys; b=open(sys.argv[1],'rb').read(62); sys.exit(0 if b[54:62]==b'FAT16   ' else 1)" "$DISK_IMG" \
  || fail "disk.img is not FAT16"
if command -v fsck_msdos >/dev/null 2>&1 || [[ -x /sbin/fsck_msdos ]]; then
  FSCK="${FSCK:-fsck_msdos}"
  [[ -x /sbin/fsck_msdos ]] && FSCK=/sbin/fsck_msdos
  capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
else
  ck; true
fi
LAYOUT="$WORKDIR/layout.json"
ck; [[ -s "$LAYOUT" ]] || fail "build-disk.sh omitted layout.json"
for plant in BROWSE.ELF PLAY.ELF TAP.ELF FILES.ELF SET.ELF PING.ELF STUDIO.ELF; do
  ck; python3 -c "import json,sys; lay=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in lay['order'] else 1)" \
    "$LAYOUT" "$plant" \
    || fail "layout.json missing $plant"
done
echo "IMAGE: pass  FAT16 FILES SET PING STUDIO BROWSE PLAY TAP (+APP1)"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
ck; [[ -s "$MODEL" ]] || fail "build-disk.sh omitted model.txt"
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
ROW0_X=$(d row0_x); ROW0_Y=$(d row0_y)
ROW0_C=$(d launch_row0)
START_N=$(d start_count)
PING_OPEN=$(d ping_open)
RELS_START=$(d rels_start)
RELS_PING=$(d rels_ping_row)
ELVES=$(d elves)
ck; [[ -n "$ROW0_X" && -n "$RELS_START" && -n "$RELS_PING" ]] \
  || fail "derive.py omitted start / PING geometry"
ck; [[ "$START_N" == "04" ]] || fail "derived launch count is $START_N, want 04 (Start floor)"
ck; [[ "$ELVES" == "FILES.ELF,SET.ELF,PING.ELF,STUDIO.ELF" ]] \
  || fail "Start elves drifted: $ELVES"
echo "DERIVED: Start $ELVES  PING open '$PING_OPEN'  start $START_N (full FAT has BROWSE PLAY TAP)"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'de-sitfat/build-disk.sh' "$SITIN" \
  || fail "sit-in.sh does not call de-sitfat/build-disk.sh"
ck; grep -q 'proc spawn FILES.ELF' "$SITIN" \
  || fail "sit-in.sh does not spawn FILES.ELF by 8.3 name"
ck; grep -q 'rels_ping_row\|RELS_PING' "$SITIN" \
  || fail "sit-in.sh does not click a start launch row"
ck; ! grep -q 'd3-session/make-image.py' "$SITIN" \
  || fail "sit-in.sh still writes OSCXPRG1 via d3-session/make-image.py"
ck; grep -q "typekeys 'wm de'" "$SITIN" \
  || fail "sit-in.sh does not type wm de"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall number"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'sit-in' in blob.lower() or b'sitfat' in blob.lower():
    raise SystemExit('sit-in appeared inside shellStrHelp')
print('    shellStrHelp has no sit-in line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "sit-in appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
echo "STRUCTURAL: pass  sit-in uses FAT, no LBA image, no help, no syscall"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

BASE_KEYS="$(typekeys 'fb'),ret,wait:1500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"
BASE_KEYS="$BASE_KEYS,$(typekeys 'proc spawn FILES.ELF'),ret,wait:400"
BASE_KEYS="$BASE_KEYS,$RELS_START"

fat_boot() {
  local name="$1" keys="$2" settle="$3" keys2="${4:-}" settle2="${5:-}"
  local dir="$WORKDIR/$name"
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
    fail "$name: comp-drive.py exited $drive_status"
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$dir/qemu.log" >&2
    fail "$name: qemu exited $qemu_status"
  fi
  [[ -s "$ser" ]] || fail "$name: no serial"
  FAT_SER="$ser"
  FAT_FB1="$fb1"
  FAT_FB2="$fb2"
}

pitch_of() {
  grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$1" | awk '{print $NF}'
}

havere() { grep -qE -- "$1" "$FAT_SER" || { sed -n '/M1 END/,$p' "$FAT_SER" >&2; fail "$2"; }; }

echo
echo "=== BOOT START + PING ==="
fat_boot start "$BASE_KEYS" "WM DE START" "$RELS_PING,wait:400" "DE CHROME PING"
ck; havere '^WM DE ON' "WM DE ON did not appear"
ck; havere '^WM DE START '"$START_N" "start printed the wrong count (want $START_N)"
ck; havere 'FILES NAME SET.ELF' "FILES.ELF did not list SET.ELF"
ck; havere 'FILES NAME PING.ELF' "FILES.ELF did not list PING.ELF"
ck; havere 'DE CHROME PING' "activating the launch row did not spawn PING.ELF"
ck; havere '^WM DE SPAWN ' "start did not print WM DE SPAWN"
ck; grep -q "FS OPEN $PING_OPEN" "$FAT_SER" \
  || fail "FS OPEN did not print the derived PING 8.3 name ($PING_OPEN)"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$FAT_SER" \
  || fail "sitfat boot faulted"
PITCH=$((16#$(pitch_of "$FAT_SER")))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; [[ -s "$FAT_FB1" ]] || fail "start boot missing framebuffer dump"
ck; python3 "$PROBE" "$FAT_FB1" "$PITCH" "$ROW0_X" "$ROW0_Y" "$ROW0_C" "launch_row0" \
  || fail "start popover row 0 was not the derived launch-row colour"
echo "START: pass  listed $ELVES; PING.ELF spawned"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-sitfat: PASS ($ASSERTIONS checks)"
exit 0
