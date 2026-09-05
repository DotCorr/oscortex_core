#!/usr/bin/env bash
# core/tests/conformance/d8-title/run.sh
#
# ADR-0075 -- title bars are compositor chrome, off by default.
#
# Binary: build d2-compositor's two-window disk, type `wm chrome` before
# `proc coop`, dump the framebuffer the way d2-compositor does
# (pmemsave at the address THE KERNEL reported), and assert a colour
# the host derived from wmchrome.dart on the title row of window A.
# A second boot types only `fb` / `wm on` / `proc coop` and requires
# that row to still be the client's fill.
#
# Derived, not a golden PNG. d8-chrome is unmoved: its chrome-on boot
# has no windows.
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

fail() { echo "D8-title: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D8-title: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=60

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d8-title.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
D2="$CORE_DIR/tests/conformance/d2-compositor"
DRIVER="$D2/comp-drive.py"
PROBE="$D2/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
[[ -f "$PROBE" ]] || setup_error "probe.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$D2/prog.c" ]] || setup_error "d2-compositor/prog.c not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

cdef() {
  python3 - "$D2/prog.c" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^#define %s\s+(0x[0-9A-Fa-f]+|\d+)U?L?" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

TH=$(dartconst wmTitleH wmchrome.dart)
T_COLOR=$(dartconst wmTitleColor wmchrome.dart)
CH_COLOR=$(dartconst wmChromeColor wmchrome.dart)
CH_META=$(dartconst wmMetaChrome wmchrome.dart)
DESK=$(dartconst wmColorDesktop wm.dart)
FOCUS=$(dartconst wmColorFocus wm.dart)
STORE=$(dartconst wmStoreBytes wm.dart)
FB_W=$(dartconst fbWidth fb.dart)
FB_H=$(dartconst fbHeight fb.dart)
A_X=$(cdef A_X)
A_Y=$(cdef A_Y)
A_FILL=$(cdef A_FILL)
B_X=$(cdef B_X)
B_Y=$(cdef B_Y)
B_FILL=$(cdef B_FILL)
WIN_W=$(cdef WIN_W)
WIN_H=$(cdef WIN_H)
INK=$(cdef INK_INSET)

ck; [[ -n "$TH" && -n "$T_COLOR" && -n "$A_X" && -n "$A_FILL" ]] \
  || fail "could not read title constants / window A geometry"
# ADR-0075 asked for 16..20, back when the title band held one flat colour
# and nothing else. It holds two fixed-size things now, and BOTH have to fit
# measured down from the window's top edge:
#   * the close/min column — wmBtnY (wmde.dart) puts a wmBtnS-tall button
#     wmBtnGap down from the top, and FALLS BACK to flush-with-the-top when
#     wmBtnGap + wmBtnS does not fit, so a band shorter than that sum does
#     not fail loudly, it silently degrades the layout;
#   * ADR-0187's live Skia caption — osgfx_session.c draws
#     OSGFX_TEXT_TITLE_PX-tall text SESS_TITLE_PAD_Y down from that same top.
# wmTitleH went 18 -> 32 to hold them (26 is the binding floor) and no ADR
# recorded the move: GAP-0340. Asserting the containment rather than a
# remembered range is strictly stronger — the old range could not even be
# satisfied by a band that fits its own buttons.
CAPPX=$(python3 - "$CORE_DIR/plat/osgfx/osgfx.h" <<'PY2'
import re, sys
m = re.search(r"OSGFX_TEXT_TITLE_PX\s*=\s*(\d+)", open(sys.argv[1]).read())
print(m.group(1) if m else "")
PY2
)
CAPPAD=$(python3 - "$CORE_DIR/plat/osgfx/osgfx_session.c" <<'PY2'
import re, sys
m = re.search(r"SESS_TITLE_PAD_Y\s*=\s*(\d+)", open(sys.argv[1]).read())
print(m.group(1) if m else "")
PY2
)
BTN_S=$(dartconst wmBtnS wmde.dart)
BTN_GAP=$(dartconst wmBtnGap wmde.dart)
ck; [[ -n "$BTN_S" && -n "$BTN_GAP" && -n "$CAPPX" && -n "$CAPPAD" ]] \
  || fail "could not read wmBtnS/wmBtnGap (wmde.dart) or OSGFX_TEXT_TITLE_PX/SESS_TITLE_PAD_Y (core/plat/osgfx) — the title band's floor is derived from them, not remembered"
ck; [[ "$TH" -ge $(( BTN_GAP + BTN_S )) ]] \
  || fail "wmTitleH is $TH but the close/min column needs wmBtnGap + wmBtnS = $(( BTN_GAP + BTN_S )); wmBtnY would fall back to flush-with-the-window-top and the buttons would sit on the client's first row"
ck; [[ "$TH" -ge $(( CAPPAD + CAPPX )) ]] \
  || fail "wmTitleH is $TH but ADR-0187's caption needs SESS_TITLE_PAD_Y + OSGFX_TEXT_TITLE_PX = $(( CAPPAD + CAPPX )); the live Skia caption would be clipped by the band that is supposed to contain it"
ck; [[ "$TH" -lt "$WIN_H" ]] \
  || fail "wmTitleH $TH is not smaller than the window height $WIN_H"
ck; [[ "$TH" -lt "$INK" ]] \
  || fail "wmTitleH $TH reaches the ink inset $INK — a below-title fill probe would land in the inner block"
ck; [[ "$T_COLOR" -ne "$DESK" ]] \
  || fail "wmTitleColor equals the desktop — a probe on the caption would be vacuous"
ck; [[ "$T_COLOR" -ne "$CH_COLOR" ]] \
  || fail "wmTitleColor equals the taskbar — chrome-on would not tell caption from strip"
ck; [[ "$T_COLOR" -ne "$A_FILL" ]] \
  || fail "wmTitleColor equals window A's fill — default-off would be indistinguishable"
ck; [[ "$T_COLOR" -ne "$B_FILL" ]] \
  || fail "wmTitleColor equals window B's fill"
ck; [[ "$T_COLOR" -ne "$FOCUS" ]] \
  || fail "wmTitleColor equals the focus border"
ck; [[ "$CH_META" -eq 19 ]] || fail "wmMetaChrome is $CH_META, expected spare word 19"
ck; [[ "$STORE" -eq 1472 ]] || fail "wmStoreBytes is $STORE, expected 1472 — titles must not grow the block"

TITLE_HEX=$(printf '%08X' "$T_COLOR")
FILL_HEX=$(printf '%08X' "$A_FILL")
BFILL_HEX=$(printf '%08X' "$B_FILL")
DESK_HEX=$(printf '%08X' "$DESK")
CHROME_HEX=$(printf '%08X' "$CH_COLOR")
FULL_PX=$(( FB_W * FB_H ))
FULL_HEX=$(printf '%08X' "$FULL_PX")
# Chrome-on: wm on, wm chrome, A commit, B commit, B 16x16.
ON_FRAMES=5
# Default-off: wm on, A, B, B 16x16.
OFF_FRAMES=4
TX=$(( A_X + 8 ))
TY=$(( A_Y + 4 ))
TMID=$(( A_X + WIN_W / 2 ))
TR=$(( A_X + WIN_W - 8 ))
BELOW=$(( A_Y + TH + 4 ))
BX=$(( B_X + 8 ))
BY=$(( B_Y + 4 ))
ck; [[ "$BELOW" -lt $(( A_Y + INK )) ]] \
  || fail "below-title probe y=$BELOW is not inside the fill band (ink starts at $(( A_Y + INK )))"
echo "DERIVED: title ${WIN_W}x${TH} colour $TITLE_HEX at y=$A_Y; probe ($TX,$TY); below ($TMID,$BELOW)=$FILL_HEX"

echo
echo "=== STRUCTURAL ==="
ck; ! grep -q '^@bss' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart declares @bss — titles reuse wmMetaChrome"
ck; grep -q "part 'wmchrome.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not part wmchrome.dart"
LAST_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" | tail -1)
ck; [[ "$LAST_PART" != "part 'wmchrome.dart';" ]] \
  || fail "wmchrome.dart is last in the part list — D7's wmevent.dart must stay last"
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
ck; ! grep -q '  wm  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'wm' help line has appeared in shell.dart — six byte-exact goldens have moved"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'title' in blob.lower():
    raise SystemExit('title appeared inside shellStrHelp')
print('    shellStrHelp has no title line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "title appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
ck; grep -q 'wmTitleDraw(' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmDrawWindow does not call wmTitleDraw"
ck; grep -q 'wmTitlePixel(' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmWindowPixel does not call wmTitlePixel"
ck; ! grep -qE 'const int \w+SysNo|syscall' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart names a syscall — titles are kernel policy, not a new ABI"
capture_sh SEAM_OUT SEAM_STATUS -- "python3 - '$CORE_DIR/kernel/wmchrome.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'///[^\n]*', ' ', src)
src = re.sub(r'//[^\n]*', ' ', src)
if 'wmStore' in src:
    raise SystemExit('wmchrome.dart names wmStore in code — use wmMeta/wmSetMeta')
if '&&' in src or '||' in src:
    raise SystemExit('wmchrome.dart uses && or ||')
if re.search(r'(?<![!=])!(?!=)', src):
    raise SystemExit('wmchrome.dart uses unary !')
print('    wmchrome.dart @bare cut: no wmStore, no && || !')
PY"
ck; [[ $SEAM_STATUS -eq 0 ]] || { echo "$SEAM_OUT" >&2; fail "the wmchrome.dart seam / @bare cut is broken"; }
echo "$SEAM_OUT"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
WM_SIZE=$(bsssize wmStore)
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ "$WM_SIZE" -eq 1472 ]] || fail "the image has wmStore ${WM_SIZE:-missing}, expected 1472"
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
TOTAL_BSS=$(( DART_BSS + 16#$ASM_BSS_HEX ))
ck; [[ "$TOTAL_BSS" -eq 51936 ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 51936 — titles still reuse wmMetaChrome and still add no block; the total moved under them: ADR-0155 doubled pmmMaxFrames to 65536 (pmmStore 4672 -> 8768, shmStore 4480 -> 8576), ADR-0189 grew vmStore to 240, and ADR-0064's fallback chain put two geometry words in fbStateBlock (32 -> 48), plus wmeventStore 768->1920 so every window slot has a ring"
echo "STRUCTURAL: pass  no new @bss, part not last, no help line, no syscall, wmStore $WM_SIZE, total .bss $TOTAL_BSS"

echo
echo "=== CLIENT ==="
PROGDIR="$WORKDIR/progs"
capture PROG_OUT PROG_STATUS -- bash "$D2/build-progs.sh" "$PROGDIR" "$CORE_DIR/kernel"
echo "$PROG_OUT"
ck; [[ $PROG_STATUS -eq 0 ]] || fail "d2-compositor/build-progs.sh exited $PROG_STATUS"
DISK_IMG="$WORKDIR/disk.img"
capture_sh MI_OUT MI_STATUS -- "python3 '$D2/make-image.py' '$DISK_IMG' '$PROGDIR/wm.elf' 2>&1"
ck; [[ $MI_STATUS -eq 0 ]] || { echo "$MI_OUT" >&2; fail "make-image.py could not build the disk image"; }
echo "$MI_OUT"
LBA_A=$(echo "$MI_OUT" | awk '/^slot A:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
LBA_B=$(echo "$MI_OUT" | awk '/^slot B:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read the two slot LBAs"
ck; [[ "$LBA_A" != "$LBA_B" ]] || fail "both slots have the same header LBA"
echo "IMAGE: pass  window A at 0x$LBA_A, window B at 0x$LBA_B"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

boot_once() {
  local ser="$1" fb="$2" png="$3" keys="$4" settle="$5" log="$6"
  local attempt=0 port qemu_pid
  while :; do
    attempt=$(( attempt + 1 ))
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
    timeout 400 qemu-system-x86_64 \
      -kernel "$KERNEL_ELF" \
      -m 128M \
      -cpu qemu64 \
      -vga std \
      -serial "file:$ser" \
      -display none \
      -no-reboot \
      -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
      -qmp "tcp:127.0.0.1:$port,server,nowait" \
      >"$log" 2>&1 &
    qemu_pid=$!
    run_status BOOT_DRIVE -- python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --keys "$keys" \
      --settle-for "$settle" \
      --settle-timeout 120 \
      --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
      --fb-out "$fb" \
      --fb-height "$FB_H" \
      --png "$png"
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
echo "=== TITLE ON ==="
ON_KEYS="$(typekeys 'fb'),ret,wait:1500"
ON_KEYS="$ON_KEYS,$(typekeys 'wm on'),ret,wait:3000"
ON_KEYS="$ON_KEYS,$(typekeys 'wm chrome'),ret,wait:3000"
ON_KEYS="$ON_KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret"
ON_SER="$WORKDIR/on-serial.txt"
ON_FB="$WORKDIR/on-fb.bin"
ON_SETTLE="WM FRAME N 0000000${ON_FRAMES}"
boot_once "$ON_SER" "$ON_FB" "$CORE_DIR/build/screenshot-title.png" \
  "$ON_KEYS" "$ON_SETTLE" "$WORKDIR/on-qemu.log"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$ON_SER" \
  || { sed -n '/M1 END/,$p' "$ON_SER" >&2; fail "something faulted during the chrome-on boot"; }
ck; grep -qE '^WM CHROME ON H ' "$ON_SER" \
  || fail "WM CHROME ON did not appear after typing wm chrome"
ck; grep -qE "^WM FRAME N 0000000${ON_FRAMES} " "$ON_SER" \
  || fail "chrome-on boot did not reach frame $ON_FRAMES"

PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$ON_SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"
FB_BYTES=$(wc -c <"$ON_FB" | tr -d ' ')
ck; [[ "$FB_BYTES" -eq $(( PITCH * FB_H )) ]] \
  || fail "the chrome-on dump is $FB_BYTES bytes and $PITCH * $FB_H is $(( PITCH * FB_H ))"

capture_sh DIST_OUT DIST_STATUS -- "python3 - '$ON_FB' '$TITLE_HEX' '$FILL_HEX' '$CHROME_HEX' <<'PY'
import sys
blob = open(sys.argv[1], 'rb').read()
words = set()
for i in range(0, len(blob), 4):
    words.add(int.from_bytes(blob[i:i+4], 'little') & 0xFFFFFF)
title = int(sys.argv[2], 16) & 0xFFFFFF
fill = int(sys.argv[3], 16) & 0xFFFFFF
chrome = int(sys.argv[4], 16) & 0xFFFFFF
if title not in words:
    raise SystemExit('title colour %06X is nowhere in the dump' % title)
if fill not in words:
    raise SystemExit('window-A fill %06X is nowhere in the dump' % fill)
if chrome not in words:
    raise SystemExit('taskbar colour %06X is nowhere in the dump' % chrome)
print('    %d distinct colours; title, fill, and taskbar are all present' % len(words))
PY"
ck; [[ $DIST_STATUS -eq 0 ]] || { echo "$DIST_OUT" >&2; fail "the chrome-on dump cannot support a title assertion"; }
echo "$DIST_OUT"

PROBES_RUN=0
for spec in \
  "a_title_left $TX $TY $TITLE_HEX" \
  "a_title_mid $TMID $TY $TITLE_HEX" \
  "a_title_right $TR $TY $TITLE_HEX" \
  "a_below $TMID $BELOW $FILL_HEX" \
  "b_title $BX $BY $TITLE_HEX"
do
  set -- $spec
  PROBES_RUN=$(( PROBES_RUN + 1 ))
  ck; python3 "$PROBE" "$ON_FB" "$PITCH" "$2" "$3" "$4" "$1" \
    || fail "pixel probe '$1' failed — title chrome did not put that colour there"
done
ck; [[ "$PROBES_RUN" -eq 5 ]] || fail "the probe loop ran $PROBES_RUN times, expected 5"

capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$ON_FB" "$PITCH" \
  "$TMID" "$TY" "$FILL_HEX" "control_fill_on_title"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "the chrome-on control exited $CTL_STATUS, expected 1 (a MISMATCH). It asserts window A's fill on the title row; a pass would mean the caption did not paint."
echo "    the control asserted $FILL_HEX on the title and FAILED, which is required:"
echo "$CTL_OUT" | sed 's/^/    /'
echo "TITLE ON: pass  $TITLE_HEX at ($TX,$TY); fill immediately below; window B caption too"

echo
echo "=== DEFAULT OFF ==="
OFF_KEYS="$(typekeys 'fb'),ret,wait:1500"
OFF_KEYS="$OFF_KEYS,$(typekeys 'wm on'),ret,wait:3000"
OFF_KEYS="$OFF_KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret"
OFF_SER="$WORKDIR/off-serial.txt"
OFF_FB="$WORKDIR/off-fb.bin"
OFF_SETTLE="WM FRAME N 0000000${OFF_FRAMES}"
boot_once "$OFF_SER" "$OFF_FB" "$WORKDIR/off.png" \
  "$OFF_KEYS" "$OFF_SETTLE" "$WORKDIR/off-qemu.log"
ck; ! grep -q 'WM CHROME ON' "$OFF_SER" \
  || fail "WM CHROME ON appeared without anyone typing wm chrome"
ck; grep -qE "^WM FRAME N 0000000${OFF_FRAMES} " "$OFF_SER" \
  || fail "default-off boot did not reach frame $OFF_FRAMES"
OFF_PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$OFF_SER" | awk '{print $NF}')))
ck; [[ "$OFF_PITCH" -gt 0 ]] || fail "could not read default-off pitch"
ck; python3 "$PROBE" "$OFF_FB" "$OFF_PITCH" "$TMID" "$TY" "$FILL_HEX" "off_title_is_fill" \
  || fail "default-off: the title row is not the client's fill — chrome painted without being asked"
capture OFF_CTL OFF_CTL_STATUS -- python3 "$PROBE" "$OFF_FB" "$OFF_PITCH" \
  "$TMID" "$TY" "$TITLE_HEX" "control_title_while_off"
ck; [[ $OFF_CTL_STATUS -eq 1 ]] \
  || fail "default-off control exited $OFF_CTL_STATUS, expected 1. It asserts the title colour while chrome is off; a pass would mean the caption painted anyway."
echo "    default-off: title row is $FILL_HEX; title colour $TITLE_HEX is not there"
echo "DEFAULT OFF: pass  wm on alone leaves the top $TH rows of window A as the client fill"

require_assertions "$ASSERTIONS_REQUIRED"
echo "D8-title: PASS — title colour $TITLE_HEX at ($TX,$TY) when chrome on; default-off boot kept $FILL_HEX"
