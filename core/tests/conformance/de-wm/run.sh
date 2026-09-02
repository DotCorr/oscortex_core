#!/usr/bin/env bash
# core/tests/conformance/de-wm/run.sh
#
# ADR-0111 — under `wm de`, a title-bar drag moves the window:
# origin changes, derived pixels move, client surface follows.
# A body drag does not move. Reflection panel still lists live
# names after spawn and is empty after close. Gated on `wm de`
# so d7 / d8 / d9 / de-chrome stay on their pictures.
#
# No new syscall. 11 is fdwait. No help line. shmMax stays >= 4.
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

fail() { echo "DE-wm: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-wm: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-wm.XXXXXX")" || setup_error "mktemp failed"
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

echo "=== BUILD ==="
# Title-drag is compositor policy, not Skia. OSGFX_SKIA=0 is the
# documented anti-vacuity link (osgfx_cmd.o + weak tick). Do not
# invoke build-skia-guest — that is another agent's rung.
capture_sh BUILD_OUT BUILD_STATUS -- "OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
DISK_IMG="$WORKDIR/de-wm.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/win.elf" \
  || fail "make-image.py could not write the volume"
if command -v fsck_msdos >/dev/null 2>&1 || [[ -x /sbin/fsck_msdos ]]; then
  FSCK="${FSCK:-fsck_msdos}"
  [[ -x /sbin/fsck_msdos ]] && FSCK=/sbin/fsck_msdos
  capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
else
  ck; true
fi
echo "IMAGE: pass  WIN.ELF"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' \
  '$CORE_DIR/kernel/wmde.dart' \
  '$CORE_DIR/kernel/wmchrome.dart' \
  '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/fb.dart' \
  '$CORE_DIR/kernel/shm.dart' \
  '$SCRIPT_DIR/win.c' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

DESK=$(d desk); TITLE=$(d title); WIN_FILL=$(d win_fill)
PANEL_ROW=$(d panel_row0)
SHM_MAX=$(d shm_max); WM_MAX=$(d wm_max); STORE=$(d store)
A_X=$(d a_x); A_Y=$(d a_y); NEW_X=$(d new_x); NEW_Y=$(d new_y)
TITLE_X=$(d title_x); TITLE_Y=$(d title_y)
BODY_X=$(d body_x); BODY_Y=$(d body_y)
NEW_TITLE_X=$(d new_title_x); NEW_TITLE_Y=$(d new_title_y)
NEW_FILL_X=$(d new_fill_x); NEW_FILL_Y=$(d new_fill_y)
MOVE_X_HEX=$(d move_x_hex); MOVE_Y_HEX=$(d move_y_hex)
FROM_X_HEX=$(d from_x_hex); FROM_Y_HEX=$(d from_y_hex)
RELS_TITLE=$(d rels_title_drag)
RELS_BODY=$(d rels_body_drag)
RELS_NOTE=$(d rels_note)
RELS_CLOSE_NOTE=$(d rels_close_from_note)
RELS_NOTE_AGAIN=$(d rels_note_again)
PANEL_RX=$(d panel_row_x); PANEL_RY=$(d panel_row_y)

ck; [[ -n "$RELS_TITLE" && -n "$NEW_X" && -n "$TITLE" ]] \
  || fail "derive.py omitted title-drag geometry"
ck; [[ "$SHM_MAX" -ge 4 ]] || fail "shmMax is $SHM_MAX, need >= 4"
ck; [[ "$WM_MAX" -eq "$SHM_MAX" ]] \
  || fail "wmMaxWindows is $WM_MAX and shmMax is $SHM_MAX"
ck; [[ "$NEW_X" -ne "$A_X" || "$NEW_Y" -ne "$A_Y" ]] \
  || fail "derived move is zero — the title-drag assertion would be vacuous"
echo "DERIVED: origin ($A_X,$A_Y) -> ($NEW_X,$NEW_Y)  title grab ($TITLE_X,$TITLE_Y)"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'u64 wmTitleHit(' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart has no wmTitleHit"
ck; grep -q 'wmTitleHit' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmGrab does not call wmTitleHit"
ck; grep -q 'wmDeOn' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmGrab does not gate the title-drag on wmDeOn"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall number"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart allocated a syscall number"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -qE 'const int \w+SysNo = 11;' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel file claimed syscall 11"
ck; [[ "$STORE" -ge 448 ]] || fail "wmStoreBytes is $STORE, shrank below 448"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
ck; grep -q "typekeys 'wm gfx'" "$SITIN" \
  || fail "sit-in.sh does not type wm gfx"
ck; grep -q "typekeys 'wm de'" "$SITIN" \
  || fail "sit-in.sh does not type wm de"
ck; grep -q "part 'wmde.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not part wmde.dart"
ck; [[ -f "$CORE_DIR/docs/decisions/0111-title-drag-is-de-policy.md" ]] \
  || fail "ADR-0111 is missing"
ck; ! grep -q '^@bss' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart declares @bss"
ck; grep -q 'ADR-0111' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart does not cite ADR-0111"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'title drag' in blob.lower() or b'de-wm' in blob.lower() or b'wm de' in blob.lower():
    raise SystemExit('de-wm appeared inside shellStrHelp')
print('    shellStrHelp has no de-wm line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "de-wm appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
echo "STRUCTURAL: pass  title-drag gated on wm de, 11 fdwait, sit-in types wm gfx + wm de"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

BASE_KEYS="$(typekeys 'fb'),ret,wait:1500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"
BASE_KEYS="$BASE_KEYS,$(typekeys 'proc spawn WIN.ELF'),ret,wait:400"

de_boot() {
  local name="$1" keys="$2" settle="$3" keys2="${4:-}" settle2="${5:-}" finish="${6:-}"
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
    [[ -n "$finish" ]] && extra+=(--finish-for "$finish")
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
  DE_SER="$ser"
  DE_FB1="$fb1"
  DE_FB2="$fb2"
}

pitch_of() {
  grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$1" | awk '{print $NF}'
}

havere() { grep -qE -- "$1" "$DE_SER" || { sed -n '/M1 END/,$p' "$DE_SER" >&2; fail "$2"; }; }

echo
echo "=== BOOT TITLE DRAG ==="
de_boot title "$BASE_KEYS" "DE WM COMMIT" "$RELS_TITLE" "WM MOVE W "
ck; havere '^WM DE ON' "WM DE ON did not appear"
ck; havere 'DE WM COMMIT' "WIN.ELF did not commit"
ck; havere '^WM MOVE W ' "title drag did not print WM MOVE"
ck; havere "^WM MOVE W 0 X $MOVE_X_HEX Y $MOVE_Y_HEX FROM $FROM_X_HEX Y $FROM_Y_HEX" \
  "title drag did not land at the derived origin"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" \
  || fail "title-drag boot faulted"
PITCH=$((16#$(pitch_of "$DE_SER")))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; [[ -s "$DE_FB1" && -s "$DE_FB2" ]] || fail "title-drag boot missing framebuffer dumps"
ck; python3 "$PROBE" "$DE_FB1" "$PITCH" "$TITLE_X" "$TITLE_Y" "$TITLE" "title_before" \
  || fail "title grab was not the derived title colour before the drag"
ck; python3 "$PROBE" "$DE_FB1" "$PITCH" "$BODY_X" "$BODY_Y" "$WIN_FILL" "fill_before" \
  || fail "WIN fill was missing before the drag"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$BODY_X" "$BODY_Y" "$DESK" "vacated_body" \
  || fail "after title-drag the old body is not the desktop"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$TITLE_X" "$TITLE_Y" "$DESK" "vacated_title" \
  || fail "after title-drag the old title is not the desktop"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$NEW_TITLE_X" "$NEW_TITLE_Y" "$TITLE" "title_after" \
  || fail "after title-drag the caption did not follow"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$NEW_FILL_X" "$NEW_FILL_Y" "$WIN_FILL" "fill_after" \
  || fail "after title-drag the client fill did not follow"
capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$DE_FB2" "$PITCH" \
  "$BODY_X" "$BODY_Y" "$WIN_FILL" "control_fill_stayed"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "control wanted WIN fill at the old origin and passed — the window did not move"
echo "TITLE: pass  origin ($A_X,$A_Y)->($NEW_X,$NEW_Y); vacated desktop; fill followed"

echo
echo "=== BOOT BODY (anti-vacuity) ==="
de_boot body "$BASE_KEYS" "DE WM COMMIT" "$RELS_BODY" "DE WM COMMIT"
ck; ! grep -qE '^WM MOVE W ' "$DE_SER" \
  || fail "a body drag printed WM MOVE — title-drag is not gated"
ck; ! grep -qE '^WM CLOSE W ' "$DE_SER" \
  || fail "a body drag printed WM CLOSE"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$BODY_X" "$BODY_Y" "$WIN_FILL" "body_still" \
  || fail "body drag moved or closed the fill"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$TITLE_X" "$TITLE_Y" "$TITLE" "title_still" \
  || fail "body drag moved the title"
echo "BODY: pass  client press does not move the window under wm de"

echo
echo "=== BOOT PANEL AFTER SPAWN ==="
de_boot panel "$BASE_KEYS" "DE WM COMMIT" "$RELS_NOTE" "WM DE LIST 01"
ck; havere '^WM DE LIST 01' "panel did not list the live window after spawn"
ck; [[ "$(grep -cE '^WM DE SURF ' "$DE_SER" | tr -d ' ')" -ge 1 ]] \
  || fail "panel printed no SURF line after spawn"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$PANEL_RX" "$PANEL_RY" "$PANEL_ROW" "panel_row" \
  || fail "panel row was not the derived panel colour after spawn"
echo "PANEL-SPAWN: pass  live name listed"

echo
echo "=== BOOT PANEL AFTER CLOSE ==="
PANEL_KEYS="$RELS_NOTE,wait:200,$RELS_CLOSE_NOTE,wait:400,$RELS_NOTE_AGAIN"
de_boot pclose "$BASE_KEYS" "DE WM COMMIT" "$PANEL_KEYS" "WM DE LIST 00"
ck; havere '^WM DE LIST 01' "close boot never listed the live window"
ck; havere '^WM CLOSE W ' "panel boot never closed"
ck; havere '^WM DE LIST 00' "panel still listed a surface after close"
echo "PANEL-CLOSE: pass  name gone after close"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-wm: PASS ($ASSERTIONS checks) — title-drag moves the surface; body does not; panel lists live names"
exit 0
