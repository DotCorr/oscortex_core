#!/usr/bin/env bash
# core/tests/conformance/osxui1-pop/run.sh
#
# OSXUI1 / ADR-0070 — compositor-owned right-click popover.
#
# Binary: type `fb`, `wm on`, inject a host-derived motion and a right
# button via QMP (the same vocabulary d1-mouse / qmp-drive.py use), dump
# the framebuffer, assert the derived colour at the derived popover
# centre. Phase two left-clicks the desktop and requires that colour
# gone. A second boot left-clicks only and requires the popover colour
# nowhere at those coordinates.
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

fail() { echo "OSXUI1-pop: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OSXUI1-pop: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=54

for tool in qemu-system-x86_64 python3 x86_64-elf-readelf x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-osxui1-pop.XXXXXX")" || setup_error "mktemp failed"
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
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' \
  '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/wmpop.dart' \
  '$CORE_DIR/kernel/wmchrome.dart' \
  '$CORE_DIR/kernel/mouse.dart' \
  '$CORE_DIR/kernel/fb.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

CLICK_X=$(d click_x); CLICK_Y=$(d click_y)
DESK_X=$(d desk_x); DESK_Y=$(d desk_y)
POP_X=$(d pop_x); POP_Y=$(d pop_y)
POP_W=$(d pop_w); POP_H=$(d pop_h)
PROBE_X=$(d probe_x); PROBE_Y=$(d probe_y)
POP_COLOR=$(d pop_color)
DESK_COLOR=$(d desk_color)
RELS_CLICK=$(d rels_to_click)
RELS_DESK=$(d rels_to_desk)
META_POP=$(d meta_pop)
META_XY=$(d meta_xy)
FB_W=$(d fb_w); FB_H=$(d fb_h)

ck; [[ -n "$POP_COLOR" && -n "$PROBE_X" && -n "$RELS_CLICK" ]] \
  || fail "the host model is missing popover colour, probe, or motion"
ck; [[ "$POP_COLOR" != "$DESK_COLOR" ]] \
  || fail "popover colour equals the desktop — the probe would be vacuous"
echo "DERIVED: right-click ($CLICK_X,$CLICK_Y) -> popover ${POP_W}x${POP_H} at ($POP_X,$POP_Y) colour $POP_COLOR; probe ($PROBE_X,$PROBE_Y); dismiss ($DESK_X,$DESK_Y)"

echo
echo "=== STRUCTURAL ==="
dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

W_POP=$(dartconst wmMetaPop wmpop.dart)
W_XY=$(dartconst wmMetaPopXY wmpop.dart)
W_CHROME=$(dartconst wmMetaChrome wmchrome.dart)
W_FOCUS=$(dartconst wmMetaFocus wm.dart)
W_SIZE=$(dartconst wmStoreBytes wm.dart)

ck; [[ "$W_POP" -eq 21 ]] || fail "wmMetaPop is $W_POP, expected 21"
ck; [[ "$W_XY" -eq 22 ]] || fail "wmMetaPopXY is $W_XY, expected 22"
ck; [[ "$W_POP" -ne "$W_CHROME" ]] || fail "popover and chrome share a wmStore word"
ck; [[ "$W_POP" -ne "$W_FOCUS" ]] || fail "popover and focus share a wmStore word"
ck; [[ "$W_XY" -ne "$W_FOCUS" ]] || fail "popover origin and focus share a wmStore word"
ck; [[ "$W_SIZE" -eq 1472 ]] || fail "wmStoreBytes is $W_SIZE, expected 1472 — popover must not grow the block"
ck; [[ "$META_POP" -eq 21 && "$META_XY" -eq 22 ]] \
  || fail "derive.py and the kernel disagree about the spare words"

ck; ! grep -q '^@bss' "$CORE_DIR/kernel/wmpop.dart" \
  || fail "wmpop.dart declares @bss — the flag was supposed to live in spare wmStore words"
ck; grep -q "part 'wmpop.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not part wmpop.dart"
LAST_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" | tail -1)
# This used to be an allow-list of file NAMES for the last part, which every
# newly added part broke on sight without anything having actually moved
# (ADR-0145's virtnet.dart is the one that broke it). The property it was
# proxying for is that NOTHING lands in .bss after wmevent.dart's block:
# "wmeventStore is last in .bss" below, and every harness that measures "from
# my block to the end of .bss", depend on it. Assert that property directly,
# from the source side, so it holds for any part list.
LAST_BSS_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" \
  | sed -E "s/^part '(.*)';/\\1/" \
  | while read -r p; do grep -q '^@bss' "$CORE_DIR/kernel/$p" && echo "$p"; done \
  | tail -1)
ck; [[ "$LAST_BSS_PART" == "wmevent.dart" ]] \
  || fail "the last part that declares @bss is ${LAST_BSS_PART:-none}, expected wmevent.dart — a part after it now owns mutable static storage, so wmeventStore is no longer the last block in .bss and every harness that measures to the end of .bss has silently moved"
ck; ! grep -q '  wm  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'wm' help line has appeared in shell.dart — six byte-exact goldens have moved"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'pop' in blob.lower():
    raise SystemExit('popover appeared inside shellStrHelp')
print('    shellStrHelp has no popover line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "popover appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
ck; grep -qE 'wmPopShow\(|wmContextShow\(' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmPointerTick does not call wmPopShow/wmContextShow"
ck; grep -q 'wmPopHide(' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmGrab does not call wmPopHide"
ck; grep -q 'wmPopDraw()' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmCompose does not call wmPopDraw"
ck; grep -q 'wmPopHit(' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart does not hit-test the popover"
ck; ! grep -qE 'const int \w+SysNo|syscall' "$CORE_DIR/kernel/wmpop.dart" \
  || fail "wmpop.dart names a syscall — the popover is kernel policy, not a new ABI"

capture_sh BARE_OUT BARE_STATUS -- "python3 - '$CORE_DIR/kernel/wmpop.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'///[^\n]*', ' ', src)
src = re.sub(r'//[^\n]*', ' ', src)
if '&&' in src or '||' in src:
    raise SystemExit('wmpop.dart uses && or ||')
# unary ! is forbidden; != is used nowhere here on purpose
if re.search(r'(?<![!=])!(?!=)', src):
    raise SystemExit('wmpop.dart uses unary !')
print('    wmpop.dart @bare cut: no && || !')
PY"
ck; [[ $BARE_STATUS -eq 0 ]] || { echo "$BARE_OUT" >&2; fail "wmpop.dart breaks the @bare cut"; }
echo "$BARE_OUT"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
WM_SIZE=$(bsssize wmStore)
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
KBDQ_OFF=$(bssoff kbdqStore)
KBDQ_SIZE=$(bsssize kbdqStore)
ck; [[ "$WM_SIZE" -eq 1472 ]] || fail "the image has wmStore ${WM_SIZE:-missing}, expected 1472"
ck; [[ "$EV_SIZE" -eq 768 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 768"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore is not immediately before wmeventStore"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
TOTAL_BSS=$(( DART_BSS + 16#$ASM_BSS_HEX ))
ck; [[ "$TOTAL_BSS" -eq 51936 ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 51936 — ADR-0109's 23264, plus ADR-0155's doubling of `pmmMaxFrames` to 65536 (`pmmStore` 4672 -> 8768 and `shmStore` 4480 -> 8576, because `shmPlaneFrames` must equal `pmmMaxFrames`), plus ADR-0189's larger fine map (`vmStore` 128 -> 240), plus the two geometry words ADR-0064's fallback chain needs (`fbStateBlock` 32 -> 48)"
echo "STRUCTURAL: pass  no new @bss, part not last, no help line, no syscall, wmStore $WM_SIZE, total .bss $TOTAL_BSS"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

FULL_PX=$(( FB_W * FB_H ))
FULL_HEX=$(printf '%08X' "$FULL_PX")
BASE_KEYS="$(typekeys 'fb'),ret,wait:1500,$(typekeys 'wm on'),ret"

boot_once() {
  local ser="$1" fb="$2" png="$3" keys2="$4" log="$5"
  local attempt=0 port qemu_pid
  while :; do
    attempt=$(( attempt + 1 ))
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
      -qmp "tcp:127.0.0.1:$port,server,nowait" \
      >"$log" 2>&1 &
    qemu_pid=$!
    run_status BOOT_DRIVE -- python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --keys "$BASE_KEYS" \
      --settle-for "WM FRAME N 00000001 PX $FULL_HEX" \
      --settle-timeout 60 \
      --keys2 "$keys2" \
      --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
      --fb-out "$WORKDIR/pre-keys2.bin" \
      --fb-height "$FB_H" \
      --png "$WORKDIR/pre-keys2.png" \
      --fb-out2 "$fb" \
      --png2 "$png"
    await BOOT_QEMU "$qemu_pid"
    if [[ $BOOT_DRIVE -ne 0 ]] && grep -q "Address already in use" "$log" \
       && [[ $attempt -lt 5 ]]; then
      echo "    (port $port was taken; retrying — attempt $attempt)"
      continue
    fi
    break
  done
  ck; if [[ $BOOT_DRIVE -ne 0 ]]; then
    cat "$log" >&2
    echo "--- serial captured so far ---" >&2
    sed -n '/M1 END/,$p' "$ser" >&2
    fail "comp-drive.py exited $BOOT_DRIVE ($ser)"
  fi
  ck; if [[ $BOOT_QEMU -ne 0 && $BOOT_QEMU -ne 124 ]]; then
    cat "$log" >&2
    fail "qemu-system-x86_64 exited $BOOT_QEMU unexpectedly"
  fi
  ck; [[ -s "$ser" ]] || fail "the boot captured no serial output at all"
  ck; [[ -s "$fb" ]] || fail "comp-drive.py produced no framebuffer dump"
}

echo
echo "=== SHOW ==="
SHOW_SER="$WORKDIR/show-serial.txt"
SHOW_FB="$WORKDIR/show-fb.bin"
SHOW_KEYS="$RELS_CLICK,wait:200,btn:right:down,wait:100,btn:right:up,wait:200"
boot_once "$SHOW_SER" "$SHOW_FB" "$CORE_DIR/build/screenshot-osxui1-pop.png" \
  "$SHOW_KEYS" "$WORKDIR/show-qemu.log"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SHOW_SER" \
  || { sed -n '/M1 END/,$p' "$SHOW_SER" >&2; fail "something faulted during the show boot"; }

PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SHOW_SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"
FB_BYTES=$(wc -c <"$SHOW_FB" | tr -d ' ')
ck; [[ "$FB_BYTES" -eq $(( PITCH * FB_H )) ]] \
  || fail "the show dump is $FB_BYTES bytes and $PITCH * $FB_H is $(( PITCH * FB_H ))"

ck; python3 "$PROBE" "$SHOW_FB" "$PITCH" "$PROBE_X" "$PROBE_Y" "$POP_COLOR" "pop_centre" \
  || fail "pixel probe 'pop_centre' failed — the popover did not put $POP_COLOR at ($PROBE_X,$PROBE_Y)"
# Inset, not the origin: the cursor (12x16 at the pointer) overlaps the
# top-left of a popover placed at pointer+gap.
ck; python3 "$PROBE" "$SHOW_FB" "$PITCH" "$(( POP_X + 16 ))" "$(( POP_Y + 16 ))" \
  "$POP_COLOR" "pop_inset" \
  || fail "pixel probe 'pop_inset' failed — the inset is not the popover colour"
ck; python3 "$PROBE" "$SHOW_FB" "$PITCH" "$(( POP_X + POP_W - 1 ))" "$(( POP_Y + POP_H - 1 ))" \
  "$POP_COLOR" "pop_corner" \
  || fail "pixel probe 'pop_corner' failed — the far corner is not the popover colour"
# Just outside the rectangle, below the cursor, must still be the desktop.
ck; python3 "$PROBE" "$SHOW_FB" "$PITCH" "$(( POP_X - 1 ))" "$(( POP_Y + 40 ))" "$DESK_COLOR" "left_of_pop" \
  || fail "pixel probe 'left_of_pop' failed — the desktop beside the popover moved"

capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$SHOW_FB" "$PITCH" \
  "$PROBE_X" "$PROBE_Y" "$DESK_COLOR" "control_desk_on_pop"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "the show control exited $CTL_STATUS, expected 1 (a MISMATCH). It asserts the desktop colour on the popover; a pass would mean the popover did not paint."
echo "    the control asserted $DESK_COLOR on the popover and FAILED, which is required:"
echo "$CTL_OUT" | sed 's/^/    /'
echo "SHOW: pass  $POP_COLOR at ($PROBE_X,$PROBE_Y)"

echo
echo "=== DISMISS ==="
HIDE_SER="$WORKDIR/hide-serial.txt"
HIDE_FB="$WORKDIR/hide-fb.bin"
HIDE_KEYS="$RELS_CLICK,wait:200,btn:right:down,wait:100,btn:right:up,wait:200,$RELS_DESK,wait:200,btn:left:down,wait:100,btn:left:up,wait:200"
boot_once "$HIDE_SER" "$HIDE_FB" "$WORKDIR/hide.png" \
  "$HIDE_KEYS" "$WORKDIR/hide-qemu.log"
HIDE_PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$HIDE_SER" | awk '{print $NF}')))
ck; [[ "$HIDE_PITCH" -gt 0 ]] || fail "could not read dismiss pitch"
ck; python3 "$PROBE" "$HIDE_FB" "$HIDE_PITCH" "$PROBE_X" "$PROBE_Y" "$DESK_COLOR" "dismissed_centre" \
  || fail "dismiss: the popover colour is still at ($PROBE_X,$PROBE_Y)"
capture HIDE_CTL HIDE_CTL_STATUS -- python3 "$PROBE" "$HIDE_FB" "$HIDE_PITCH" \
  "$PROBE_X" "$PROBE_Y" "$POP_COLOR" "control_pop_after_dismiss"
ck; [[ $HIDE_CTL_STATUS -eq 1 ]] \
  || fail "dismiss control exited $HIDE_CTL_STATUS, expected 1. It asserts the popover colour after a desktop left-click; a pass would mean it did not dismiss."
echo "DISMISS: pass  ($PROBE_X,$PROBE_Y) is $DESK_COLOR again"

echo
echo "=== NEGATIVE ==="
NEG_SER="$WORKDIR/neg-serial.txt"
NEG_FB="$WORKDIR/neg-fb.bin"
NEG_KEYS="$RELS_CLICK,wait:200,btn:left:down,wait:100,btn:left:up,wait:200"
boot_once "$NEG_SER" "$NEG_FB" "$WORKDIR/neg.png" \
  "$NEG_KEYS" "$WORKDIR/neg-qemu.log"
NEG_PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$NEG_SER" | awk '{print $NF}')))
ck; [[ "$NEG_PITCH" -gt 0 ]] || fail "could not read negative-boot pitch"
ck; python3 "$PROBE" "$NEG_FB" "$NEG_PITCH" "$PROBE_X" "$PROBE_Y" "$DESK_COLOR" "neg_still_desktop" \
  || fail "negative: a left-click painted something other than the desktop at the popover probe"
capture NEG_CTL NEG_CTL_STATUS -- python3 "$PROBE" "$NEG_FB" "$NEG_PITCH" \
  "$PROBE_X" "$PROBE_Y" "$POP_COLOR" "control_pop_on_left_only"
ck; [[ $NEG_CTL_STATUS -eq 1 ]] \
  || fail "negative control exited $NEG_CTL_STATUS, expected 1. It asserts the popover colour after a left-click only; a pass would mean left-click showed the popover."
echo "NEGATIVE: pass  left-click only never showed $POP_COLOR"

require_assertions "$ASSERTIONS_REQUIRED"
echo "OSXUI1-pop: PASS — right-click $POP_COLOR at ($PROBE_X,$PROBE_Y); desktop left-click dismisses; left-only never shows it"
