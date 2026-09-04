#!/usr/bin/env bash
# core/tests/conformance/d8-chrome/run.sh
#
# ADR-0056 -- compositor chrome is a bottom strip, off by default.
# Title bars (ADR-0075) share this flag; `d8-title` photographs them.
#
# Binary: type `wm chrome` after `wm on`, dump the framebuffer the way
# d2-compositor does (pmemsave at the address THE KERNEL reported), and
# assert a colour the host derived from wmchrome.dart on the bottom 24
# rows. The serial line carries the same height and strip pixel count.
# Derived, not a golden PNG.
#
# Default-off is d2-compositor's job: that harness never types this
# command, and this one refuses to emit expectations if the strip colour
# equals the desktop colour.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D8-chrome: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D8-chrome: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=53

for tool in qemu-system-x86_64 python3 x86_64-elf-readelf x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d8-chrome.XXXXXX")" || setup_error "mktemp failed"
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
dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

CH_H=$(dartconst wmChromeH wmchrome.dart)
CH_COLOR=$(dartconst wmChromeColor wmchrome.dart)
CH_META=$(dartconst wmMetaChrome wmchrome.dart)
FB_W=$(dartconst fbWidth fb.dart)
FB_H=$(dartconst fbHeight fb.dart)
DESK=$(dartconst wmColorDesktop wm.dart)
META_WORDS=$(dartconst wmMetaWords wm.dart)
STORE=$(dartconst wmStoreBytes wm.dart)

ck; [[ -n "$CH_H" && -n "$CH_COLOR" && -n "$CH_META" ]] \
  || fail "could not read wmChromeH / wmChromeColor / wmMetaChrome out of wmchrome.dart"
ck; [[ "$CH_H" -gt 0 && "$CH_H" -lt "$FB_H" ]] \
  || fail "wmChromeH is $CH_H and fbHeight is $FB_H — the strip would be empty or the whole screen"
ck; [[ "$CH_COLOR" -ne "$DESK" ]] \
  || fail "wmChromeColor equals the desktop colour — a probe on the strip would be vacuous"
ck; [[ "$CH_META" -eq 19 ]] || fail "wmMetaChrome is $CH_META, expected spare word 19"
ck; [[ "$CH_META" -lt "$META_WORDS" ]] \
  || fail "wmMetaChrome $CH_META is not inside the $META_WORDS-word meta block"
ck; [[ "$STORE" -eq 704 ]] || fail "wmStoreBytes is $STORE, expected 704 — chrome must not grow the block"

CH_PX=$(( FB_W * CH_H ))
CH_Y0=$(( FB_H - CH_H ))
FULL_PX=$(( FB_W * FB_H ))
ck; [[ "$CH_PX" -gt 0 && "$CH_PX" -lt "$FULL_PX" ]] \
  || fail "strip is $CH_PX pixels and a full frame is $FULL_PX — the added-count assertion would be vacuous"

H_HEX=$(printf '%04X' "$CH_H")
PX_HEX=$(printf '%08X' "$CH_PX")
FULL_HEX=$(printf '%08X' "$FULL_PX")
CHROME_HEX=$(printf '%08X' "$CH_PX")
FRAME2_PX=$(( FULL_PX + CH_PX ))
FRAME2_HEX=$(printf '%08X' "$FRAME2_PX")
COLOR_HEX=$(printf '%08X' "$CH_COLOR")
DESK_HEX=$(printf '%08X' "$DESK")
echo "DERIVED: strip ${FB_W}x${CH_H} at y=$CH_Y0 colour $COLOR_HEX, $CH_PX pixels (frame 2 = $FRAME2_HEX)"

echo
echo "=== STRUCTURAL ==="
ck; ! grep -q '^@bss' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart declares @bss — the flag was supposed to live in a spare wmStore word"
ck; grep -q "part 'wmchrome.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not part wmchrome.dart"
LAST_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" | tail -1)
ck; [[ "$LAST_PART" != "part 'wmchrome.dart';" ]] \
  || fail "wmchrome.dart is last in the part list — D7's wmevent.dart / D2's kbdq.dart must stay last"
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
if b'chrome' in blob.lower():
    raise SystemExit('chrome appeared inside shellStrHelp')
print('    shellStrHelp has no chrome line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "chrome appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
ck; grep -q 'wmStrCmdChrome' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch wm chrome"
ck; grep -q 'wmChromeDraw()' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmCompose does not call wmChromeDraw"
ck; grep -q 'wmChromeHit(' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmGrab does not call wmChromeHit"
ck; ! grep -qE 'const int \w+SysNo|syscall' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart names a syscall — chrome is kernel policy, not a new ABI"
capture_sh SEAM_OUT SEAM_STATUS -- "python3 - '$CORE_DIR/kernel/wmchrome.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'///[^\n]*', ' ', src)
src = re.sub(r'//[^\n]*', ' ', src)
if 'wmStore' in src:
    raise SystemExit('wmchrome.dart names wmStore in code — use wmMeta/wmSetMeta')
print('    wmchrome.dart reaches chrome state only through wmMeta accessors')
PY"
ck; [[ $SEAM_STATUS -eq 0 ]] || { echo "$SEAM_OUT" >&2; fail "the wmStore seam is broken from wmchrome.dart"; }
echo "$SEAM_OUT"

capture_sh ROD_OUT ROD_STATUS -- "python3 - '$CORE_DIR/kernel/wmchrome.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
sizes = {}
for m in re.finditer(r'final List<u8> (wmStr\w+) = const \[(.*?)\];', src, re.S):
    sizes[m.group(1)] = len(re.findall(r'u8\(0x[0-9A-Fa-f]{2}\)', m.group(2)))
bad = []
n = 0
for m in re.finditer(r'uartWrite\(Rodata\.addressOf\((wmStr\w+)\), u64\((\d+)\)\)', src):
    name, passed = m.group(1), int(m.group(2))
    n += 1
    if name in sizes and sizes[name] != passed:
        bad.append('%s is %d bytes and a call site passes %d' % (name, sizes[name], passed))
if n == 0:
    raise SystemExit('no uartWrite call sites in wmchrome.dart')
if bad:
    raise SystemExit('\n'.join(bad))
print('    %d chrome @rodata tables, %d local call sites agree' % (len(sizes), n))
PY"
ck; [[ $ROD_STATUS -eq 0 ]] || { echo "$ROD_OUT" >&2; fail "a wmchrome.dart call site passes the wrong byte count"; }
echo "$ROD_OUT"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$3" -v f="$1" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield 3 x "$1"; }
bssoff()  { bssfield 2 x "$1"; }
WM_SIZE=$(bsssize wmStore)
KBDQ_SIZE=$(bsssize kbdqStore)
WMEV_SIZE=$(bsssize wmeventStore)
WM_OFF=$(bssoff wmStore)
KBDQ_OFF=$(bssoff kbdqStore)
WMEV_OFF=$(bssoff wmeventStore)
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
TOTAL_BSS=$(( DART_BSS + 16#$ASM_BSS_HEX ))
# D2's two-slot total, carried forward. The old arithmetic (22672 + 256 +
# wmeventStore) reconstructed the total from remembered deltas, so every
# unrelated growth below this milestone silently invalidated it. The total is
# now pinned outright with its ledger, exactly as D7 pins it, and the claim
# this check actually makes -- chrome must not add a block -- is enforced
# directly below by the "every byte is inside a named block" census.
EXPECT_BSS=37600
ck; [[ "$WM_SIZE" -eq 704 ]] || fail "the image has wmStore ${WM_SIZE:-missing}, expected 704"
ck; [[ "$TOTAL_BSS" -eq "$EXPECT_BSS" ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected $EXPECT_BSS — ADR-0109's 23264, plus four authorised growths that all sit BELOW this milestone: pmmStore +4096 (ADR-0155 doubled pmmMaxFrames to 65536 and pmmBoundMib to 256), shmStore +4096 (the bit-plane must describe exactly pmmMaxFrames), vmStore +112 (ADR-0189 took vmFineBytes to 32MiB, vmMapBytes to 256MiB, vmFrameCount to 20) and fbStateBlock +16 (ADR-0064's scanout geometry words). See GAP-0053's ledger. Chrome itself must still add nothing"
# Anti-anonymity: every byte of the Dart .bss must belong to a NAMED block,
# up to the alignment padding the assembler inserts between them. A chrome
# block smuggled in without a name -- the exact failure the total was meant
# to catch -- now fails here as well as on the total.
capture_sh CENSUS_OUT CENSUS_STATUS -- "python3 - '$CORE_DIR/build/kmain.o' '$DART_BSS' <<'PY'
import re, subprocess, sys
obj, want = sys.argv[1], int(sys.argv[2])
secs = subprocess.run(['x86_64-elf-readelf', '-SW', obj],
                      capture_output=True, text=True).stdout
idx = None
for line in secs.splitlines():
    m = re.match(r'\s*\[\s*(\d+)\]\s+\.bss\s', line)
    if m:
        idx = m.group(1)
if idx is None:
    raise SystemExit('kmain.o has no .bss section')
syms = subprocess.run(['x86_64-elf-readelf', '-sW', obj],
                      capture_output=True, text=True).stdout
named = []
for line in syms.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == 'OBJECT' and f[6] == idx:
        named.append((int(f[1], 16), int(f[2]), f[7]))
if not named:
    raise SystemExit('no named .bss blocks — the census would be vacuous')
named.sort()
covered = sum(sz for _, sz, _ in named)
pad = want - covered
if pad < 0 or pad > 16 * len(named):
    raise SystemExit('%d of %d .bss bytes are in no named block' % (pad, want))
print('    %d named .bss blocks cover %d of %d bytes (%d alignment)'
      % (len(named), covered, want, pad))
PY"
echo "$CENSUS_OUT"
ck; [[ $CENSUS_STATUS -eq 0 ]] \
  || fail "an unnamed block appeared in .bss — chrome must not add a block: $CENSUS_OUT"
if [[ -n "$WMEV_SIZE" ]]; then
  ck; [[ $(( 16#$WMEV_OFF + WMEV_SIZE )) -eq "$DART_BSS" ]] \
    || fail "wmeventStore is not last in .bss"
else
  ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq "$DART_BSS" ]] \
    || fail "kbdqStore is not last in .bss — a new chrome block would have moved it"
fi
echo "STRUCTURAL: pass  no new @bss, part not last, no help line, no syscall, wmStore $WM_SIZE, total .bss $TOTAL_BSS"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:3000"
KEYS="$KEYS,$(typekeys 'wm chrome'),ret,wait:3000"

SER="$WORKDIR/serial.txt"
FB_BIN="$WORKDIR/fb.bin"
SHOT_PNG="$CORE_DIR/build/screenshot-chrome.png"
QEMU_PIDS=""
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
  : >"$SER"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$SER" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
    >"$WORKDIR/qemu.log" 2>&1 &
  QEMU_PID=$!
  QEMU_PIDS="$QEMU_PIDS $QEMU_PID"
  run_status DRIVE_STATUS -- python3 "$DRIVER" \
    --port "$PORT" \
    --serial "$SER" \
    --wait-for 'M1 END\n' \
    --keys "$KEYS" \
    --settle-for "WM FRAME N 00000002 PX $FRAME2_HEX" \
    --settle-timeout 60 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$FB_BIN" \
    --png "$SHOT_PNG"
  await QEMU_STATUS "$QEMU_PID"
  if [[ $DRIVE_STATUS -ne 0 ]] && grep -q "Address already in use" "$WORKDIR/qemu.log" \
     && [[ $attempt -lt 5 ]]; then
    echo "    (port $PORT was taken; retrying — attempt $attempt)"
    continue
  fi
  break
done
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial captured so far ---" >&2
  sed -n '/M1 END/,$p' "$SER" >&2
  fail "comp-drive.py exited $DRIVE_STATUS"
fi
ck; if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  fail "qemu-system-x86_64 exited $QEMU_STATUS unexpectedly"
fi
ck; [[ -s "$SER" ]] || fail "the boot captured no serial output at all"

echo
echo "=== TRANSCRIPT ==="
havere() { grep -qE -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript matches nothing against: $1"; }; }
countof() { grep -cE -- "$1" "$SER" | tr -d ' '; }

ck; havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$'
ck; havere "^WM CHROME ON H $H_HEX PX $PX_HEX\$"
# Frame 1 is `wm on` with chrome still off: a bare desktop. Frame 2 is the
# recompose after `wm chrome`, which adds exactly the strip.
ck; havere "^WM FRAME N 00000001 PX $FULL_HEX "
ck; havere "^WM FRAME N 00000002 PX $FRAME2_HEX "
ck; [[ "$(countof '^WM FRAME N ')" -eq 2 ]] \
  || fail "$(countof '^WM FRAME N ') frames, expected 2"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "something faulted during the chrome boot"; }
echo "TRANSCRIPT: pass  WM CHROME ON H $H_HEX PX $PX_HEX, frames $FULL_HEX then $FRAME2_HEX"

echo
echo "=== PIXELS ==="
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"
ck; [[ -s "$FB_BIN" ]] || fail "comp-drive.py produced no framebuffer dump"
FB_BYTES=$(wc -c <"$FB_BIN" | tr -d ' ')
ck; [[ "$FB_BYTES" -eq $(( PITCH * FB_H )) ]] \
  || fail "the framebuffer dump is $FB_BYTES bytes and $PITCH * $FB_H is $(( PITCH * FB_H ))"

capture_sh DIST_OUT DIST_STATUS -- "python3 - '$FB_BIN' '$COLOR_HEX' '$DESK_HEX' <<'PY'
import sys
blob = open(sys.argv[1], 'rb').read()
words = set()
for i in range(0, len(blob), 4):
    words.add(int.from_bytes(blob[i:i+4], 'little') & 0xFFFFFF)
chrome = int(sys.argv[2], 16) & 0xFFFFFF
desk = int(sys.argv[3], 16) & 0xFFFFFF
if len(words) < 2:
    raise SystemExit('the framebuffer holds %d distinct colour(s); a uniform screen cannot prove a strip' % len(words))
if chrome not in words:
    raise SystemExit('chrome colour %06X is nowhere in the dump' % chrome)
if desk not in words:
    raise SystemExit('desktop colour %06X is nowhere in the dump' % desk)
print('    %d distinct colours; chrome and desktop are both present' % len(words))
PY"
ck; [[ $DIST_STATUS -eq 0 ]] || { echo "$DIST_OUT" >&2; fail "the framebuffer dump cannot support a chrome assertion"; }
echo "$DIST_OUT"

PROBES_RUN=0
# Left, middle, right of the strip, and one pixel ABOVE it (still desktop).
for spec in \
  "bar_left 0 $CH_Y0 $COLOR_HEX" \
  "bar_mid $(( FB_W / 2 )) $(( FB_H - 1 )) $COLOR_HEX" \
  "bar_right $(( FB_W - 1 )) $CH_Y0 $COLOR_HEX" \
  "above_bar $(( FB_W / 2 )) $(( CH_Y0 - 1 )) $DESK_HEX"
do
  set -- $spec
  PROBES_RUN=$(( PROBES_RUN + 1 ))
  ck; python3 "$PROBE" "$FB_BIN" "$PITCH" "$2" "$3" "$4" "$1" \
    || fail "pixel probe '$1' failed — chrome did not put that colour there"
done
ck; [[ "$PROBES_RUN" -eq 4 ]] || fail "the probe loop ran $PROBES_RUN times, expected 4"
echo "PIXELS: pass  $PROBES_RUN probes, strip $COLOR_HEX, desktop immediately above"

echo
echo "=== CONTROL ==="
# Desktop colour asserted ON the strip must fail. A compositor that never
# painted chrome would satisfy every probe that wanted the desktop, and this
# is the check that would still catch it if the positive probes were edited
# to ask for the desktop by mistake.
capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$FB_BIN" "$PITCH" \
  "$(( FB_W / 2 ))" "$(( CH_Y0 + 1 ))" "$DESK_HEX" "control_desk_on_bar"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "the control probe exited $CTL_STATUS, expected 1 (a MISMATCH). It asserts the desktop colour on the strip; a pass would mean chrome did not paint."
echo "    the control asserted $DESK_HEX on the strip and FAILED, which is required:"
echo "$CTL_OUT" | sed 's/^/    /'
echo "CONTROL: pass  the strip is not the desktop colour"

# ===========================================================================
# Default-off. `d2-compositor` cannot currently finish its STRUCTURAL
# section on this branch (D7 moved last-block from kbdqStore to
# wmeventStore). This boot is the same commands d2 types -- `fb`, `wm on`,
# never `wm chrome` -- and requires the bottom strip to be the desktop.
# ===========================================================================
echo
echo "=== DEFAULT OFF ==="
OFF_KEYS="$(typekeys 'fb'),ret,wait:1500"
OFF_KEYS="$OFF_KEYS,$(typekeys 'wm on'),ret,wait:3000"
OFF_SER="$WORKDIR/off-serial.txt"
OFF_FB="$WORKDIR/off-fb.bin"
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
  : >"$OFF_SER"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$OFF_SER" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
    >"$WORKDIR/off-qemu.log" 2>&1 &
  OFF_PID=$!
  QEMU_PIDS="$QEMU_PIDS $OFF_PID"
  run_status OFF_DRIVE -- python3 "$DRIVER" \
    --port "$PORT" \
    --serial "$OFF_SER" \
    --wait-for 'M1 END\n' \
    --keys "$OFF_KEYS" \
    --settle-for "WM FRAME N 00000001 PX $FULL_HEX" \
    --settle-timeout 60 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$OFF_FB" \
    --png "$WORKDIR/off.png"
  await OFF_QSTATUS "$OFF_PID"
  if [[ $OFF_DRIVE -ne 0 ]] && grep -q "Address already in use" "$WORKDIR/off-qemu.log" \
     && [[ $attempt -lt 5 ]]; then
    echo "    (port $PORT was taken; retrying — attempt $attempt)"
    continue
  fi
  break
done
ck; if [[ $OFF_DRIVE -ne 0 ]]; then
  cat "$WORKDIR/off-qemu.log" >&2
  sed -n '/M1 END/,$p' "$OFF_SER" >&2
  fail "default-off comp-drive.py exited $OFF_DRIVE"
fi
ck; if [[ $OFF_QSTATUS -ne 0 && $OFF_QSTATUS -ne 124 ]]; then
  cat "$WORKDIR/off-qemu.log" >&2
  fail "default-off qemu exited $OFF_QSTATUS unexpectedly"
fi
ck; [[ -s "$OFF_SER" ]] || fail "the default-off boot captured no serial"
ck; ! grep -q 'WM CHROME ON' "$OFF_SER" \
  || fail "WM CHROME ON appeared without anyone typing wm chrome"
ck; grep -qE "^WM FRAME N 00000001 PX $FULL_HEX " "$OFF_SER" \
  || fail "default-off frame 1 is not a bare desktop ($FULL_HEX)"
OFF_PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$OFF_SER" | awk '{print $NF}')))
ck; [[ "$OFF_PITCH" -gt 0 ]] || fail "could not read default-off pitch"
ck; [[ -s "$OFF_FB" ]] || fail "default-off produced no framebuffer dump"
ck; python3 "$PROBE" "$OFF_FB" "$OFF_PITCH" "$(( FB_W / 2 ))" "$(( CH_Y0 + 1 ))" "$DESK_HEX" "off_bar_is_desktop" \
  || fail "default-off: the strip is not the desktop colour — chrome painted without being asked"
capture OFF_CTL OFF_CTL_STATUS -- python3 "$PROBE" "$OFF_FB" "$OFF_PITCH" \
  "$(( FB_W / 2 ))" "$(( CH_Y0 + 1 ))" "$COLOR_HEX" "control_chrome_while_off"
ck; [[ $OFF_CTL_STATUS -eq 1 ]] \
  || fail "default-off control exited $OFF_CTL_STATUS, expected 1. It asserts the chrome colour on the strip while chrome is off; a pass would mean the bar painted anyway."
echo "    default-off: strip is $DESK_HEX; chrome colour $COLOR_HEX is not there"
echo "DEFAULT OFF: pass  wm on alone leaves the bottom $CH_H rows as the desktop"

require_assertions "$ASSERTIONS_REQUIRED"
echo "D8-chrome: PASS — WM CHROME ON H $H_HEX PX $PX_HEX, strip colour $COLOR_HEX at y=$CH_Y0; default-off boot kept the desktop"
