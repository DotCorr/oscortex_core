#!/usr/bin/env bash
# core/tests/conformance/de-chrome/run.sh
#
# ADR-0106 — compositor DE chrome: close, minimise, start/spotlight,
# reflection panel. Gated on `wm de` so d8-chrome / d8-title exact-rect
# goldens stay on `wm chrome` alone.
#
# Binary:
#   1. Close affordance destroys the surface; client is gone. Body click
#      does not close.
#   2. Min hides the surface; taskbar slot restores it.
#   3. Start lists spawnable names; activating PING.ELF prints a derived
#      line and the panel lists the new surface.
#   4. After close the panel count drops.
#
# Derived, not a golden PNG.
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

fail() { echo "DE-chrome: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-chrome: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=54

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-chrome.XXXXXX")" || setup_error "mktemp failed"
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
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
DISK_IMG="$WORKDIR/de.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/win.elf" "$WORKDIR/ping.elf" \
  || fail "make-image.py could not write the volume"
if command -v fsck_msdos >/dev/null 2>&1 || [[ -x /sbin/fsck_msdos ]]; then
  FSCK="${FSCK:-fsck_msdos}"
  [[ -x /sbin/fsck_msdos ]] && FSCK=/sbin/fsck_msdos
  capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
else
  ck; true
fi
echo "IMAGE: pass  WIN.ELF + PING.ELF"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' \
  '$CORE_DIR/kernel/wmde.dart' \
  '$CORE_DIR/kernel/wmchrome.dart' \
  '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/fb.dart' \
  '$SCRIPT_DIR/win.c' \
  '$SCRIPT_DIR/ping.c' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

FB_W=$(d fb_w); FB_H=$(d fb_h)
DESK=$(d desk); WIN_FILL=$(d win_fill)
CLOSE_C=$(d close_color); MIN_C=$(d min_color)
START_C=$(d start_color); NOTE_C=$(d note_color); SLOT0_C=$(d slot0_color)
PANEL_ROW=$(d panel_row0)
CLOSE_X=$(d close_x); CLOSE_Y=$(d close_y)
MIN_X=$(d min_x); MIN_Y=$(d min_y)
BODY_X=$(d body_x); BODY_Y=$(d body_y)
START_X=$(d start_x); START_Y=$(d start_y)
START_FILL_X=$(d start_fill_x)
LABEL_FG=$(d label_fg)
LABEL_X0=$(d label_x0); LABEL_X1=$(d label_x1)
LABEL_Y0=$(d label_y0); LABEL_Y1=$(d label_y1)
NOTE_X=$(d note_x); NOTE_Y=$(d note_y)
SLOT0_X=$(d slot0_x); SLOT0_Y=$(d slot0_y)
PANEL_RX=$(d panel_row_x); PANEL_RY=$(d panel_row_y)
RELS_CLOSE=$(d rels_close)
RELS_MIN=$(d rels_min)
RELS_BODY=$(d rels_body)
RELS_START=$(d rels_start)
RELS_PING=$(d rels_ping_row)
RELS_NOTE_PING=$(d rels_note_from_ping)
RELS_NOTE=$(d rels_note)
RELS_CLOSE_NOTE=$(d rels_close_from_note)
RELS_NOTE_AGAIN=$(d rels_note_again)
RELS_SLOT=$(d rels_slot_from_min)

ck; [[ -n "$CLOSE_X" && -n "$RELS_CLOSE" ]] \
  || fail "derive.py omitted close geometry"
ck; [[ "$CLOSE_C" != "$DESK" && "$MIN_C" != "$DESK" ]] \
  || fail "button colours collapsed onto the desktop"
echo "DERIVED: close ($CLOSE_X,$CLOSE_Y) min ($MIN_X,$MIN_Y) body ($BODY_X,$BODY_Y)"

echo
echo "=== STRUCTURAL ==="
ck; ! grep -q '^@bss' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart declares @bss — DE chrome must live in the chrome word"
ck; grep -q "part 'wmde.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not part wmde.dart"
LAST_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" | tail -1)
ck; [[ "$LAST_PART" != "part 'wmde.dart';" ]] \
  || fail "wmde.dart is last — virtgpu3d.dart must stay last"
# This used to be an allow-list of file NAMES for the last part, which every
# newly added part broke on sight without anything having actually moved
# (ADR-0145's virtnet.dart, then virtab.dart, are the ones that broke it). The
# property it was proxying for is that NOTHING lands in .bss after
# wmevent.dart's block: every harness that measures "from my block to the end
# of .bss" depends on it. Assert that property directly, from the source side,
# so it holds for any part list.
LAST_BSS_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" \
  | sed -E "s/^part '(.*)';/\\1/" \
  | while read -r p; do grep -q '^@bss' "$CORE_DIR/kernel/$p" && echo "$p"; done \
  | tail -1)
ck; [[ "$LAST_BSS_PART" == "wmevent.dart" ]] \
  || fail "the last part that declares @bss is ${LAST_BSS_PART:-none}, expected wmevent.dart — a part after it now owns mutable static storage, so wmeventStore is no longer the last block in .bss and every harness that measures to the end of .bss has silently moved"
ck; grep -q 'wmStrCmdDe' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch wm de"
ck; grep -q 'wmDeGrab' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmGrab does not call wmDeGrab"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall number — close is compositor teardown, spawn is 26"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'wm de' in blob.lower() or b'de chrome' in blob.lower():
    raise SystemExit('de appeared inside shellStrHelp')
print('    shellStrHelp has no de line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "de appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
STORE=$(python3 - "$CORE_DIR/kernel/wm.dart" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int wmStoreBytes = (\d+);", src, re.M)
print(int(m.group(1)) if m else "")
PY
)
ck; [[ "$STORE" -eq 1472 ]] || fail "wmStoreBytes is $STORE, expected 1472"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
ck; grep -q "typekeys 'wm de'" "$SITIN" \
  || fail "sit-in.sh does not type wm de"
ck; grep -q "DESK.ELF" "$SITIN" \
  || fail "sit-in.sh does not spawn DESK.ELF (ADR-0197 boot-to-desk)"
echo "STRUCTURAL: pass  no @bss, not last, no help, no syscall, sit-in types wm de + DESK"

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
echo "=== BOOT CLOSE ==="
de_boot close "$BASE_KEYS" "DE WIN COMMIT" "$RELS_CLOSE" "PROC KILL"
ck; havere '^WM DE ON' "WM DE ON did not appear"
ck; havere 'DE WIN COMMIT' "WIN.ELF did not commit"
ck; havere '^WM CLOSE W ' "close did not print WM CLOSE"
ck; havere '^PROC KILL' "close did not kill the client"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" \
  || fail "close boot faulted"
PITCH=$((16#$(pitch_of "$DE_SER")))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
ck; [[ -s "$DE_FB1" && -s "$DE_FB2" ]] || fail "close boot missing framebuffer dumps"
ck; python3 "$PROBE" "$DE_FB1" "$PITCH" "$CLOSE_X" "$CLOSE_Y" "$CLOSE_C" "close_btn" \
  || fail "close affordance was not the derived close colour"
ck; python3 "$PROBE" "$DE_FB1" "$PITCH" "$MIN_X" "$MIN_Y" "$MIN_C" "min_btn" \
  || fail "min affordance was not the derived min colour"
ck; python3 "$PROBE" "$DE_FB1" "$PITCH" "$BODY_X" "$BODY_Y" "$WIN_FILL" "win_body" \
  || fail "WIN fill was missing before close"
ck; python3 "$PROBE" "$DE_FB1" "$PITCH" "$START_FILL_X" "$START_Y" "$START_C" "start_fill" \
  || fail "start fill was not the derived start colour"
# The button is labelled (wmDeChromeDraw paints Start, then osxui_label_fb).
# Probing only the fill would now pass on an unlabelled button, so require
# the label's ink inside the button as well.
capture_sh LBL_OUT LBL_STATUS -- "python3 - '$DE_FB1' '$PITCH' '$LABEL_X0' '$LABEL_X1' '$LABEL_Y0' '$LABEL_Y1' '$LABEL_FG' <<'PY'
import sys
fb, pitch = sys.argv[1], int(sys.argv[2])
x0, x1, y0, y1 = (int(a) for a in sys.argv[3:7])
want = int(sys.argv[7], 16) & 0xFFFFFF
blob = open(fb, 'rb').read()
ink = 0
for y in range(y0, y1):
    row = y * pitch
    for x in range(x0, x1):
        o = row + x * 4
        if o + 4 <= len(blob) and int.from_bytes(blob[o:o+4], 'little') & 0xFFFFFF == want:
            ink += 1
if ink == 0:
    raise SystemExit('no %06X ink in the Start label box' % want)
print('    start_label            %d px of %06X in (%d,%d)-(%d,%d)'
      % (ink, want, x0, y0, x1, y1))
PY"
echo "$LBL_OUT"
ck; [[ $LBL_STATUS -eq 0 ]] \
  || fail "the Start button carries no label ink: $LBL_OUT"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$BODY_X" "$BODY_Y" "$DESK" "closed_body" \
  || fail "after close the client body is not the desktop"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "108" "124" "$DESK" "closed_title" \
  || fail "after close the title is not the desktop"
capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$DE_FB2" "$PITCH" \
  "$BODY_X" "$BODY_Y" "$WIN_FILL" "control_fill_after_close"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "control wanted WIN fill after close and passed — the surface is still there"
echo "CLOSE: pass  affordance destroys the surface; PROC KILL; body is desktop"

echo
echo "=== BOOT BODY (anti-vacuity) ==="
de_boot body "$BASE_KEYS" "DE WIN COMMIT" "$RELS_BODY" "DE WIN COMMIT"
ck; ! grep -qE '^WM CLOSE W ' "$DE_SER" \
  || fail "a body click printed WM CLOSE"
ck; ! grep -qE '^PROC KILL' "$DE_SER" \
  || fail "a body click killed the client"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "105" "200" "$WIN_FILL" "body_still" \
  || fail "body click moved or closed the fill"
echo "BODY: pass  client click does not close"

echo
echo "=== BOOT MIN ==="
de_boot min "$BASE_KEYS" "DE WIN COMMIT" "$RELS_MIN" "WM MIN W "
ck; havere '^WM MIN W ' "min did not print WM MIN"
ck; ! grep -qE '^WM CLOSE W ' "$DE_SER" \
  || fail "min printed WM CLOSE"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$BODY_X" "$BODY_Y" "$DESK" "min_body" \
  || fail "after min the client body is still painted"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$SLOT0_X" "$SLOT0_Y" "$SLOT0_C" "min_slot" \
  || fail "after min the taskbar slot is gone"
echo "MIN: pass  surface not painted; slot remains"

echo
echo "=== BOOT RESTORE ==="
RESTORE_KEYS="$RELS_MIN,wait:400,$RELS_SLOT"
de_boot rest "$BASE_KEYS" "DE WIN COMMIT" "$RESTORE_KEYS" "WM REST W "
ck; havere '^WM MIN W ' "restore boot never minimised"
ck; havere '^WM REST W ' "slot click did not restore"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$BODY_X" "$BODY_Y" "$WIN_FILL" "restored_body" \
  || fail "after restore the client fill is missing"
echo "RESTORE: pass  taskbar slot brings the surface back"

echo
echo "=== BOOT START + PANEL ==="
START_KEYS="$RELS_START,wait:300,$RELS_PING,wait:400,$RELS_NOTE_PING"
de_boot start "$BASE_KEYS" "DE WIN COMMIT" "$START_KEYS" "WM DE LIST 02"
ck; havere '^WM DE START ' "start did not print WM DE START"
ck; havere 'DE CHROME PING' "activating the launch row did not spawn PING.ELF"
ck; havere '^WM DE SPAWN ' "start did not print WM DE SPAWN"
ck; havere '^WM DE LIST 02' "panel did not list two surfaces after spawn"
ck; [[ "$(grep -cE '^WM DE SURF ' "$DE_SER" | tr -d ' ')" -ge 2 ]] \
  || fail "panel printed fewer than two SURF lines"
ck; python3 "$PROBE" "$DE_FB2" "$PITCH" "$PANEL_RX" "$PANEL_RY" "$PANEL_ROW" "panel_row" \
  || fail "panel row was not the derived panel colour"
echo "START: pass  PING.ELF spawned; panel lists two surfaces"

echo
echo "=== BOOT PANEL AFTER CLOSE ==="
PANEL_KEYS="$RELS_NOTE,wait:200,$RELS_CLOSE_NOTE,wait:400,$RELS_NOTE_AGAIN"
de_boot panel "$BASE_KEYS" "DE WIN COMMIT" "$PANEL_KEYS" "WM DE LIST 00"
ck; havere '^WM DE LIST 01' "panel did not list the live window before close"
ck; havere '^WM CLOSE W ' "panel boot never closed"
ck; havere '^WM DE LIST 00' "panel still listed a surface after close"
echo "PANEL: pass  name present after spawn-equivalent attach; gone after close"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-chrome: PASS ($ASSERTIONS checks)"
exit 0
