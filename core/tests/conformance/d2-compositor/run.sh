#!/usr/bin/env bash
# core/tests/conformance/d2-compositor/run.sh
#
# ===========================================================================
# D4/D5 -- TWO CLIENT PROCESSES, TWO SURFACES, ONE SCREEN, AND THE PROOF IS
# PIXELS.
# ===========================================================================
#
# ADR-0050 (who owns the framebuffer) and ADR-0051 (the surface protocol).
#
# WHAT THIS HARNESS ASSERTS, AND WHY IT IS NOT A MESSAGE-DELIVERY TEST
# ---------------------------------------------------------------------------
# A compositor test that checked syscalls returned the right numbers would
# prove nothing about what is on the screen. Every claim below is settled by
# READING THE FRAMEBUFFER BACK OUT OF GUEST PHYSICAL MEMORY, at the address the
# KERNEL reported after finding it in a PCI BAR, and comparing a colour at a
# coordinate against a colour computed on the host before the machine booted.
#
#   * the desktop is where no window is;
#   * each client's fill colour and each client's inner block are where that
#     client's surface is;
#   * IN THE OVERLAP, THE TOP WINDOW'S COLOUR IS WHAT IS THERE -- and the top
#     window's BORDER is drawn over the bottom window's content, which is a
#     second, independent statement of the same stacking claim;
#   * the pointer is drawn ON TOP, with its own edge and fill colours at the
#     coordinates this kernel's own 16x12 bitmaps put them.
#
# AND ONE ASSERTION THAT MUST FAIL
# ---------------------------------------------------------------------------
# `derive.py` emits a `control=` line: the BOTTOM window's fill, at the
# coordinate in the overlap where the TOP window's fill actually is. This
# harness runs that assertion with the same probe program as the other eleven
# and REQUIRES IT TO FAIL. A compositor that ignored stacking order would
# satisfy one of the two windows' probes and could never satisfy both
# `b_overlap` and this -- which is `display-protocol.md` D5's negative control
# in as many words: "swap the stacking order and require the previous
# expectation to fail".
#
# THE ANTI-VACUITY GUARDS, because a pixel assertion is easy to make hollow
# ---------------------------------------------------------------------------
#   1. `derive.py` REFUSES to emit expectations if the two surfaces do not
#      overlap -- two disjoint rectangles are composed correctly by any order
#      at all and D5 would be testing nothing.
#   2. It refuses if the two fills are the same colour, for the same reason.
#   3. It refuses if the pointer script moves the pointer nowhere.
#   4. This harness requires the framebuffer dump to contain MORE THAN ONE
#      distinct colour, and to contain every colour the model names. A kernel
#      that filled the screen with one colour would otherwise satisfy whichever
#      probes happened to want that colour.
#   5. The probe loop's iteration count is asserted against `probe_count=`, so
#      a loop that ran zero times cannot pass.
#
# Usage: bash run.sh
# Exit status: 0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D2-compositor: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D2-compositor: FAIL — $1" >&2; exit 2; }

# GAP-0168 / ADR-0032: the `ck` assertion counter, the `require_assertions`
# floor, and the capture()/run_status() replacements for capture-then-`$?`.
# Sourced AFTER fail(), which every helper in it reports through.
source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=114

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d2.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$SCRIPT_DIR/comp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found at $DRIVER"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"

# ===========================================================================
# Step 1 — build the kernel.
# ===========================================================================
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

# ===========================================================================
# Step 2 — the host model, derived before anything boots.
# ===========================================================================
echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SCRIPT_DIR/prog.c' \
  '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/mouse.dart' '$SCRIPT_DIR/events.txt' \
  '$SCRIPT_DIR/events-drag.txt' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

WIN_W=$(d win_w); WIN_H=$(d win_h); BORDER=$(d border)
EXIT_A=$(d exit_a); EXIT_B=$(d exit_b)
PX1=$(d px1); PX2=$(d px2); PX3=$(d px3); PX4=$(d px4)
DMG_W=$(d dmg_w); DMG_H=$(d dmg_h)
DMG_X=$(d dmg_x); DMG_Y=$(d dmg_y)
CUR_X=$(d cursor_x); CUR_Y=$(d cursor_y)
PROBE_COUNT=$(d probe_count)
OVERLAP_AREA=$(d overlap_area)
SYSNO=$(d syscall)
PROBE2_COUNT=$(d probe2_count)
DRAG_MOVES=$(d drag_moves)
DRAG_WIN=$(d drag_window)
MOVED_X=$(d moved_x); MOVED_Y=$(d moved_y)
RAISE_TO=$(echo "$(d drag_raise)" | awk '{print $1}')
RAISE_FROM=$(echo "$(d drag_raise)" | awk '{print $2}')

ck; [[ "$OVERLAP_AREA" -gt 0 ]] \
  || fail "the model says the two surfaces overlap in $OVERLAP_AREA pixels — the stacking assertion would be vacuous"
ck; [[ "$PROBE_COUNT" -gt 0 ]] \
  || fail "the model derives $PROBE_COUNT probes; a probe loop with nothing in it passes by doing nothing"
ck; [[ "$EXIT_A" != "$EXIT_B" ]] \
  || fail "the two clients' derived exit codes are equal — one number would satisfy both checks"
echo "DERIVED: two ${WIN_W}x${WIN_H} surfaces overlapping in $OVERLAP_AREA pixels, a ${BORDER}px border"
ck; [[ $((16#$PX4)) -lt $((16#$PX2)) ]] \
  || fail "D6's 16x16 count $PX4 is not smaller than a decorated window $PX2 — the small-count assertion would be vacuous"
ck; [[ $((16#$PX2)) -lt $((16#$PX1)) ]] \
  || fail "a decorated-window commit $PX2 is not smaller than a full desktop $PX1 — a full-frame fallback would be indistinguishable"
echo "DERIVED: four composition passes of $PX1, $PX2, $PX3 and $PX4 pixels (D6: the last is ${DMG_W}x${DMG_H})"
echo "DERIVED: the pointer ends at X $CUR_X Y $CUR_Y; side 0 exits $EXIT_A and side 1 exits $EXIT_B"
echo "DERIVED: $PROBE_COUNT pixel probes and one control that must fail"
ck; [[ "$DRAG_MOVES" -gt 0 ]] \
  || fail "the drag script derives $DRAG_MOVES window moves; phase 2 would assert that nothing happened"
ck; [[ "$PROBE2_COUNT" -gt 0 ]] \
  || fail "the model derives $PROBE2_COUNT phase-2 probes"
ck; [[ "$RAISE_TO" != "$RAISE_FROM" ]] \
  || fail "the drag script raises the window that is already on top; the stacking half of phase 2 would be vacuous"
echo "DERIVED: the drag raises window $RAISE_TO over window $RAISE_FROM, moves it $DRAG_MOVES times to X $MOVED_X Y $MOVED_Y, and is checked by $PROBE2_COUNT more probes and a second control"

# ===========================================================================
# Step 3 — structural checks. Everything answerable without booting.
# ===========================================================================
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

W_META=$(dartconst wmMetaBytes wm.dart)
W_WINB=$(dartconst wmWinBytes wm.dart)
W_MAX=$(dartconst wmMaxWindows wm.dart)
W_STORE=$(dartconst wmStoreBytes wm.dart)
W_DESCB=$(dartconst wmDescBytes wm.dart)
W_DESCW=$(dartconst wmDescWords wm.dart)
CHAN_MSG=$(dartconst chanMsgBytes chan.dart)
SHM_MAX=$(dartconst shmMax shm.dart)
W_SYS=$(dartconst wmSysSurfaceNo wm.dart)

# 3a. THE BLOCK TILES EXACTLY. A store whose parts do not add up to its size is
# either wasting bytes or overlapping two records, and both are silent.
ck; [[ $(( W_META + W_MAX * W_WINB )) -eq "$W_STORE" ]] \
  || fail "wmMetaBytes ($W_META) + wmMaxWindows ($W_MAX) * wmWinBytes ($W_WINB) = $(( W_META + W_MAX * W_WINB )), and wmStoreBytes is $W_STORE"

# 3b. THE DESCRIPTOR IS A CHANNEL MESSAGE. This is the equality ADR-0051 §2
# rests on -- when the compositor moves to ring 3 the identical eight words go
# through `chansend` and the wire format does not move. If it ever stops being
# true, that promise has quietly expired.
ck; [[ "$W_DESCB" -eq "$CHAN_MSG" ]] \
  || fail "wmDescBytes is $W_DESCB and chanMsgBytes is $CHAN_MSG — the descriptor is no longer a legal channel message and ADR-0051 §2's promise has expired"
ck; [[ $(( W_DESCW * 8 )) -eq "$W_DESCB" ]] \
  || fail "$W_DESCW words of 8 bytes is $(( W_DESCW * 8 )), not wmDescBytes $W_DESCB"

# 3c. WINDOWS ARE DERIVED FROM REGIONS, not picked. A window's pixels live in a
# shared region, so more window slots than region slots is storage nothing can
# reach and fewer is a surface that cannot be shown.
ck; [[ "$W_MAX" -eq "$SHM_MAX" ]] \
  || fail "wmMaxWindows is $W_MAX and shmMax is $SHM_MAX — a window's pixels live in a region, so the two numbers are the same number"

# 3d. THE SYSCALL NUMBER, in all three places that name it.
ck; [[ "$W_SYS" -eq "$SYSNO" ]] || fail "internal: the model and the kernel disagree about the syscall number"
PROG_SYS=$(grep -m1 '^#define SYS_WMSURFACE ' "$SCRIPT_DIR/prog.c" | awk '{print $3}')
ck; [[ "$PROG_SYS" -eq "$W_SYS" ]] \
  || fail "prog.c says SYS_WMSURFACE is $PROG_SYS and wm.dart says wmSysSurfaceNo is $W_SYS"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh' 2>&1"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "the syscall registry does not accept $W_SYS"; }
echo "$REG_OUT"

# 3e. THE REFUSAL CODES: distinct, above one floor, and agreeing with the
# private copy in prog.c -- and the kernel must declare NO refusal the program
# has not been taught. M21's rule, kept.
capture_sh RET_OUT RET_STATUS -- "python3 - '$CORE_DIR/kernel/wm.dart' '$SCRIPT_DIR/prog.c' <<'PY'
import re, sys
wm, prog = open(sys.argv[1]).read(), open(sys.argv[2]).read()
kern = {}
for m in re.finditer(r'^const int wmRet(\w+) = (0x[0-9A-Fa-f]+);', wm, re.M):
    kern[m.group(1).upper()] = int(m.group(2), 16) & 0xFFFFFFFFFFFFFFFF
floor = kern.pop('FLOOR', None)
if floor is None:
    raise SystemExit('wm.dart declares no wmRetFloor')
if not kern:
    raise SystemExit('wm.dart declares no refusal codes at all')
if len(set(kern.values())) != len(kern):
    raise SystemExit('two wmRet* constants share a value: %r' % kern)
for n, v in kern.items():
    if v <= floor:
        raise SystemExit('wmRet%s = 0x%X is not above wmRetFloor 0x%X' % (n, v, floor))
prg = {}
for m in re.finditer(r'^#define WM_(\w+) (0x[0-9A-Fa-f]+)UL', prog, re.M):
    prg[m.group(1)] = int(m.group(2), 16)
prg.pop('FLOOR', None)
prg.pop('ATTACH', None)
prg.pop('COMMIT', None)
missing = sorted(set(kern) - set(prg))
if missing:
    raise SystemExit('the kernel declares refusals prog.c has not been taught: %s' % missing)
for n in sorted(kern):
    if kern[n] != prg[n]:
        raise SystemExit('wmRet%s = 0x%X and prog.c WM_%s = 0x%X' % (n, kern[n], n, prg[n]))
print('    %d refusal codes, all distinct, all above the floor, all matching prog.c' % len(kern))
PY"
ck; [[ $RET_STATUS -eq 0 ]] || { echo "$RET_OUT" >&2; fail "the kernel's refusal codes and prog.c's copy of them disagree"; }
echo "$RET_OUT"

# 3f. THE FRAMEBUFFER GATE. ADR-0050's decision is enforced in ONE place, and a
# second one would be a second thing to keep in step.
GATE=$(grep -c 'if (wmActive() > u64(0)) {' "$CORE_DIR/kernel/fb.dart")
ck; [[ "$GATE" -eq 1 ]] \
  || fail "fb.dart tests wmActive() in $GATE places, expected exactly 1 — ADR-0050's exclusive-ownership decision has more than one enforcement point"
ck; grep -q 'void fbPutc(u8 c) {' "$CORE_DIR/kernel/fb.dart" \
  || fail "fbPutc is gone; the gate above is attached to nothing"
# ...and NOT in conPutc, so COM1 is untouched. Every byte-exact golden from M1
# onwards depends on this being true.
ck; ! grep -q 'wmActive' "$CORE_DIR/kernel/vga.dart" \
  || fail "vga.dart consults wmActive — the compositor is suppressing SERIAL output, and every byte-exact golden in this suite has moved"

# 3g. THE STORAGE SEAM. ADR-0011 §0: the symbol is named in its accessors and
# nowhere else in the kernel.
SEAM=$(grep -cE "Bss[.]addressOf[(]wmStore[)]" "$CORE_DIR/kernel/wm.dart")
ck; [[ "$SEAM" -eq 3 ]] \
  || fail "Bss.addressOf(wmStore) appears in $SEAM places in wm.dart, expected exactly 3 (the meta accessor, the window accessor and the initialiser)"
# COMMENTS STRIPPED. `kmain.dart` EXPLAINS in prose why `part 'wm.dart'` is
# last and names the block while doing it; a seam check that could not tell
# prose from code would make the explanation illegal.
capture_sh SEAM2_OUT SEAM2_STATUS -- "python3 - '$CORE_DIR/kernel' <<'PY'
import os, re, sys
d = sys.argv[1]
bad = []
for f in sorted(os.listdir(d)):
    if not f.endswith('.dart') or f == 'wm.dart':
        continue
    src = open(os.path.join(d, f)).read()
    src = re.sub(r'///[^\n]*', ' ', src)
    src = re.sub(r'//[^\n]*', ' ', src)
    if 'wmStore' in src:
        bad.append(f)
if bad:
    raise SystemExit('wmStore is referenced in CODE outside wm.dart: %s' % bad)
print('    wmStore is reached only through wm.dart accessors')
PY"
ck; [[ $SEAM2_STATUS -eq 0 ]] || { echo "$SEAM2_OUT" >&2; fail "the wmStore storage seam is broken"; }
echo "$SEAM2_OUT"

# 3h. THE @bss BLOCK IS THE SIZE IT SAYS AND IT IS LAST.
bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$3" -v f="$1" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield 3 x "$1"; }
bssoff()  { bssfield 2 x "$1"; }
WM_SIZE=$(bsssize wmStore)
ck; [[ "$WM_SIZE" -eq "$W_STORE" ]] \
  || fail "wm.dart says wmStoreBytes=$W_STORE and the image has ${WM_SIZE:-no wmStore at all}"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section"
DART_BSS=$((16#$DART_BSS_HEX))
WM_OFF=$(bssoff wmStore)
KBDQ_SIZE=$(bsssize kbdqStore)
KBDQ_OFF=$(bssoff kbdqStore)
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
ck; [[ "$KBDQ_SIZE" -eq 288 ]] || fail "kbdqStore is ${KBDQ_SIZE:-missing} bytes, expected 288 (ADR-0054)"
ck; [[ "$EV_SIZE" -eq 768 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 768 (ADR-0055)"
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore ends at $(( 16#$EV_OFF + EV_SIZE )) and kmain.o's .bss is $DART_BSS — D7's block is not last"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore ends at $(( 16#$KBDQ_OFF + KBDQ_SIZE )) and wmeventStore begins at $(( 16#$EV_OFF )) — D2's block is not immediately before D7's"
ck; [[ $(( 16#$WM_OFF + WM_SIZE )) -eq $(( 16#$KBDQ_OFF )) ]] \
  || fail "wmStore ends at $(( 16#$WM_OFF + WM_SIZE )) and kbdqStore begins at $(( 16#$KBDQ_OFF )) — D4's block is not immediately before D2's"
SHM_OFF=$(bssoff shmStore)
SHM_SIZE=$(bsssize shmStore)
ck; [[ $(( 16#$SHM_OFF + SHM_SIZE )) -eq $(( 16#$WM_OFF )) ]] \
  || fail "shmStore ends at $(( 16#$SHM_OFF + SHM_SIZE )) and wmStore begins at $(( 16#$WM_OFF )) — M21's block is not immediately before D4's"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section"
TOTAL_BSS=$(( DART_BSS + 16#$ASM_BSS_HEX ))
ck; [[ "$TOTAL_BSS" -eq 36576 ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 36576 — ADR-0109's 23264, plus ADR-0155's doubling of `pmmMaxFrames` to 65536 (`pmmStore` 4672 -> 8768 and `shmStore` 4480 -> 8576, because `shmPlaneFrames` must equal `pmmMaxFrames`), plus ADR-0189's larger fine map (`vmStore` 128 -> 240), plus the two geometry words ADR-0064's fallback chain needs (`fbStateBlock` 32 -> 48). If that changed, it changed deliberately and GAP-0053's running total and every harness that subtracts a later block move with it."
echo "STRUCTURAL: pass  wmStore is $WM_SIZE bytes at .bss+0x$WM_OFF, immediately after shmStore and before kbdqStore; wmeventStore last; total .bss $TOTAL_BSS"

# 3i. NO HELP LINE. `shellStrHelp` is inside five byte-exact serial goldens plus
# m3-shell's screen golden, so one line here moves six goldens by substitution.
# GAP-0304 records the cost. D1 made the same choice and m20 made it before.
ck; ! grep -q '  wm  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'wm' help line has appeared in shell.dart — six byte-exact goldens have moved"

# 3j. EVERY @rodata TABLE'S REAL SIZE AGAINST WHAT ITS CALL SITE PASSES.
# GAP-0060: a table carries no length, so every byte count is repeated by hand.
# BOTH FILES. `wm.dart`'s compositor now spans `wm.dart` + `wmext.dart` (the
# subsurface/scale/seat helpers and, since ADR-0192, the screen-rect and client
# paint ops). A table declared in one and written from the other is not a size
# mismatch, and reading only the first file reported exactly that.
capture_sh ROD_OUT ROD_STATUS -- "python3 - '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/wmext.dart' <<'PY'
import re, sys
src = ''.join(open(p).read() for p in sys.argv[1:])
sizes = {}
for m in re.finditer(r'final List<u8> (wmStr\w+) = const \[(.*?)\];', src, re.S):
    sizes[m.group(1)] = len(re.findall(r'u8\(0x[0-9A-Fa-f]{2}\)', m.group(2)))
if not sizes:
    raise SystemExit('no wmStr* tables found at all')
bad = []
n = 0
for m in re.finditer(r'uartWrite\(Rodata\.addressOf\((wmStr\w+)\), u64\((\d+)\)\)', src):
    name, passed = m.group(1), int(m.group(2))
    n += 1
    if name not in sizes:
        bad.append('%s is written but not declared' % name)
    elif sizes[name] != passed:
        bad.append('%s is %d bytes and a call site passes %d' % (name, sizes[name], passed))
if n == 0:
    raise SystemExit('no uartWrite call sites found; this check examined nothing')
if bad:
    raise SystemExit('\n'.join(bad))
print('    %d @rodata tables, %d call sites, every length agrees' % (len(sizes), n))
PY"
ck; [[ $ROD_STATUS -eq 0 ]] || { echo "$ROD_OUT" >&2; fail "a wmStr* call site passes the wrong byte count (GAP-0060)"; }
echo "$ROD_OUT"

# ===========================================================================
# Step 4 — freestanding. CLAUDE.md rule 1, under /bin/bash 3.2.
# ===========================================================================
echo
echo "=== FREESTANDING ==="
BASH_VER="$(/bin/bash -c 'echo $BASH_VERSION')"
ck; [[ "$BASH_VER" == 3.2.* ]] || echo "    (note: /bin/bash reports $BASH_VER, not a 3.2.x — ADR-0028's portability claim is being checked against a different shell than it was written for)"
capture FS_OUT FS_STATUS -- env OSCORTEX_ALLOWLIST="${OSCORTEX_ALLOWLIST:-$CORE_DIR/tools/bare-symbol-allowlist.txt}" \
  /bin/bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" \
  "$CORE_DIR/build/portio.o" "$CORE_DIR/build/kernel.elf"
echo "$FS_OUT"
ck; [[ $FS_STATUS -eq 0 ]] || fail "verify-freestanding.sh exited $FS_STATUS under /bin/bash $BASH_VER"
ck; [[ "$(grep -c '^FREESTANDING: pass' <<<"$FS_OUT")" -eq 4 ]] \
  || fail "verify-freestanding reported $(grep -c '^FREESTANDING: pass' <<<"$FS_OUT") passes, expected 4"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern.*/\1/p' <<<"$FS_OUT")
# D3 added resume_user and proc_idle_gate. Subtract so this milestone's extern pin still describes THIS change.
if [[ -f "$CORE_DIR/build/kmain.o.externs" ]]; then
  D3_EXTERNS=$(grep -cE '^(resume_user|proc_idle_gate|kbd_drain_gate)$' "$CORE_DIR/build/kmain.o.externs" || true)
  EXTERN_COUNT=$(( EXTERN_COUNT - D3_EXTERNS ))
fi
# ADR-0104 (the OS calls osgfx), ADR-0113/ADR-0133 (osxui paints through
# osgfx), ADR-0136 (panel hex is an osgfx glyph), ADR-0172 (Venus encodes
# retained SPIR-V) and ADR-0181 (the generative desk) gave the OS platform C
# modules to call. Their entry points are `external` too, so the RAW count
# moves every time the OS calls one more of its own modules -- which is not
# what any milestone's extern pin below is about.
#
# Subtracted BY PATTERN rather than by a typed list, because a typed list is a
# second place to forget: `osgfx_*` and `osxui_*` are, by ADR-0104, C module
# entry points. Read out of dcc's own manifest, which is the authority on what
# kmain.o declares, the same file the D3 block above reads. The pin they are
# subtracted from still says exactly what it always said -- THIS milestone
# added no new assembly primitive -- and each module entry point is asserted
# NOT to be defined in assembly, which is the property the pin exists to
# protect and which a bumped total would not state.
EXTERN_MANIFEST="$CORE_DIR/build/kmain.o.externs"
ck; [[ -f "$EXTERN_MANIFEST" ]] || fail "dcc wrote no $EXTERN_MANIFEST — the extern census below has nothing authoritative to read"
PLAT_EXTERNS=$(grep -E '^(osgfx|osxui)_[A-Za-z0-9_]+$' "$EXTERN_MANIFEST" | sort -u)
PLAT_PRESENT=$(wc -w <<<"$PLAT_EXTERNS" | tr -d ' ')
ck; [[ "$PLAT_PRESENT" -ge 7 ]] \
  || fail "kmain.o declares only $PLAT_PRESENT osgfx_/osxui_ entry points, expected at least the seven of ADR-0104/0113/0136/0172/0181 — the OS stopped calling its own C modules"
for sym in $PLAT_EXTERNS; do
  ck; ! grep -qE "^[.]glob(a)?l[[:space:]]+$sym\b" "$CORE_DIR/boot/isr.S" "$CORE_DIR/boot/boot.S" "$CORE_DIR/boot/portio.S" \
    || fail "$sym is defined in assembly — it is a platform C module entry point (ADR-0104), and an assembly definition of it would mean the module seam had been replaced by a stub"
done
EXTERN_COUNT=$(( EXTERN_COUNT - PLAT_PRESENT ))
# ADR-0148's TLS door is the one genuinely NEW assembly primitive since these
# numbers were pinned: `setfs` has to land in the FS_BASE MSR, and wrmsr has no
# DCDart spelling. Subtracted by name, and asserted to BE assembly.
ck; grep -qE "^[.]glob(a)?l[[:space:]]+msr_write\b" "$CORE_DIR/boot/isr.S" \
  || fail "msr_write is not defined in isr.S — ADR-0148's FS_BASE door was supposed to be one wrmsr stub in assembly"
MSR_PRESENT=$(grep -cE '^msr_write$' "$EXTERN_MANIFEST" || true)
EXTERN_COUNT=$(( EXTERN_COUNT - MSR_PRESENT ))
ck; [[ "$EXTERN_COUNT" -eq 44 ]] \
  || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — UNCHANGED, because a compositor that needed a new @extern would be doing in assembly something ADR-0050 says is DCDart's job"

# ===========================================================================
# Step 5 — the clients, and the disk they live on.
# ===========================================================================
echo
echo "=== CLIENT ==="
PROGDIR="$WORKDIR/progs"
capture PROG_OUT PROG_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" "$CORE_DIR/kernel"
echo "$PROG_OUT"
ck; [[ $PROG_STATUS -eq 0 ]] || fail "build-progs.sh exited $PROG_STATUS"
DISK_IMG="$WORKDIR/disk.img"
capture_sh MI_OUT MI_STATUS -- "python3 '$SCRIPT_DIR/make-image.py' '$DISK_IMG' '$PROGDIR/wm.elf' 2>&1"
ck; [[ $MI_STATUS -eq 0 ]] || { echo "$MI_OUT" >&2; fail "make-image.py could not build the disk image"; }
echo "$MI_OUT"
LBA_A=$(echo "$MI_OUT" | awk '/^slot A:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
LBA_B=$(echo "$MI_OUT" | awk '/^slot B:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read the two slot LBAs out of make-image.py's report"

# ===========================================================================
# Step 6 — the boot.
# ===========================================================================
echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

# The pointer script, turned into driver elements. It is injected BEFORE
# `proc coop` and not after, and that is not a stylistic ordering: the shell is
# not running while the two clients are, so there is no command that could ask
# for a recompose afterwards. The pointer therefore has to be where it is going
# to be BEFORE the frame that photographs it is composed -- which is exactly the
# situation a compositor is in with a real pointer and is the honest shape.
RELS=$(python3 -c "
import re, sys
out = []
for line in open(sys.argv[1]):
    line = line.split('#', 1)[0].strip()
    if not line:
        continue
    m = re.match(r'^rel\s+(-?\d+)\s+(-?\d+)\$', line)
    out.append('rel:%s:%s' % (m.group(1), m.group(2)))
print(','.join(out))
" "$SCRIPT_DIR/events.txt")
ck; [[ -n "$RELS" ]] || fail "the event script produced no pointer elements"

# Phase 2's script, in the same vocabulary. `grab`/`drop` become the button
# edges; each edge is its own `input-send-event` so press and release are two
# PS/2 packets, which is what makes a press distinguishable from a hold.
KEYS2=$(python3 -c "
import re, sys
out = []
for line in open(sys.argv[1]):
    line = line.split('#', 1)[0].strip()
    if not line:
        continue
    if line == 'grab':
        out.append('btn:left:down'); out.append('wait:400'); continue
    if line == 'drop':
        out.append('wait:400'); out.append('btn:left:up'); continue
    m = re.match(r'^rel\s+(-?\d+)\s+(-?\d+)\$', line)
    out.append('rel:%s:%s' % (m.group(1), m.group(2)))
print(','.join(out + ['wait:600']))
" "$SCRIPT_DIR/events-drag.txt")
ck; [[ -n "$KEYS2" ]] || fail "the drag script produced no phase-2 elements"

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:3000"
KEYS="$KEYS,$RELS,wait:500"
KEYS="$KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret"

SER="$WORKDIR/serial.txt"
FB_BIN="$WORKDIR/fb.bin"
FB_BIN2="$WORKDIR/fb2.bin"
SHOT_PNG="$CORE_DIR/build/screenshot-compositor.png"
SHOT_PNG2="$CORE_DIR/build/screenshot-compositor-moved.png"
QEMU_PIDS=""
# GAP-0150: the port is BOUND-THEN-RELEASED by pick-port.py rather than derived
# from $$, and the launch is RETRIED if QEMU still loses the race.
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
  : >"$SER"
  timeout 400 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$SER" \
    -display none \
    -no-reboot \
    -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
    >"$WORKDIR/qemu.log" 2>&1 &
  QEMU_PID=$!
  QEMU_PIDS="$QEMU_PIDS $QEMU_PID"
  run_status DRIVE_STATUS -- python3 "$DRIVER" \
    --port "$PORT" \
    --serial "$SER" \
    --wait-for 'M1 END\n' \
    --keys "$KEYS" \
    --settle-for "WM FRAME N 000000$(printf '%02X' "$(d frames)")" \
    --settle-timeout 120 \
    --finish-for 'PROC END SWITCHES 00000002 EXITS 00000002' \
    --finish-timeout 180 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$FB_BIN" \
    --png "$SHOT_PNG" \
    --keys2 "$KEYS2" \
    --settle2-for "WM MOVE W $DRAG_WIN" \
    --fb-out2 "$FB_BIN2" \
    --png2 "$SHOT_PNG2"
  await QEMU_STATUS "$QEMU_PID"
  if [[ $DRIVE_STATUS -ne 0 ]] && grep -q "Address already in use" "$WORKDIR/qemu.log" \
     && [[ $attempt -lt 5 ]]; then
    echo "    (port $PORT was taken between the probe and the launch; retrying — attempt $attempt)"
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

# ===========================================================================
# Step 7 — the transcript. The kernel's own account of what it did.
# ===========================================================================
echo
echo "=== TRANSCRIPT ==="
have() { grep -qF -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript does not contain: $1"; }; }
havere() { grep -qE -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript matches nothing against: $1"; }; }
countof() { grep -cE -- "$1" "$SER" | tr -d ' '; }

ck; havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$'
# TWO ATTACHES, in two different window slots, from two different regions.
ck; [[ "$(countof '^WM ATTACH W [01] R [01] GEN ')" -eq 2 ]] \
  || fail "$(countof '^WM ATTACH W [01] R [01] GEN ') surfaces attached, expected 2"
ck; havere "^WM ATTACH W 0 R 0 GEN [0-9A-F]{8} X $(printf '%04X' "$(grep -m1 '^#define A_X ' "$SCRIPT_DIR/prog.c" | awk '{print $3+0}')")"
ck; havere "^WM ATTACH W 1 R 1 GEN [0-9A-F]{8} X $(printf '%04X' "$(grep -m1 '^#define B_X ' "$SCRIPT_DIR/prog.c" | awk '{print $3+0}')")"
# THREE COMMITS: two full-surface presents, then D6's 16x16.
ck; [[ "$(countof '^WM COMMIT W [01] SEQ ')" -eq 3 ]] \
  || fail "$(countof '^WM COMMIT W [01] SEQ ') commits, expected 3"
ck; havere "^WM COMMIT W 0 SEQ 00000001 DMG X 0000 Y 0000 W $(printf '%04X' "$WIN_W") H $(printf '%04X' "$WIN_H")\$"
ck; havere "^WM COMMIT W 1 SEQ 00000001 DMG X 0000 Y 0000 W $(printf '%04X' "$WIN_W") H $(printf '%04X' "$WIN_H")\$"
ck; havere "^WM COMMIT W 1 SEQ 00000002 DMG X $DMG_X Y $DMG_Y W $(printf '%04X' "$DMG_W") H $(printf '%04X' "$DMG_H")\$"
# FOUR FRAMES, with the pixel counts derived on the host. Frame 1 is `wm on`
# (the desktop). 2 and 3 are decorated windows. 4 is D6's 16x16.
ck; havere "^WM FRAME N 00000001 PX $PX1 TOP $W_MAX CUR X 0000 Y 0000\$"
ck; havere "^WM FRAME N 00000002 PX $PX2 TOP 0 CUR X $CUR_X Y $CUR_Y\$"
ck; havere "^WM FRAME N 00000003 PX $PX3 TOP 1 CUR X $CUR_X Y $CUR_Y\$"
ck; havere "^WM FRAME N 00000004 PX $PX4 TOP 1 CUR X $CUR_X Y $CUR_Y\$"
# THE FORGED HANDLE. Exactly one, refused by name.
ck; [[ "$(countof '^WM REFUSE C .* R FFFFFFFFFFFFFFFA$')" -eq 1 ]] \
  || fail "$(countof '^WM REFUSE C .* R FFFFFFFFFFFFFFFA$') forged-handle refusals, expected exactly 1 (wmRetBadCap)"
# THE TWO EXIT CODES, derived from the pixels each client actually wrote.
ck; have "PROC EXIT SLOT 00 ID 00000001 CODE $EXIT_A"
ck; have "PROC EXIT SLOT 01 ID 00000002 CODE $EXIT_B"
# NOTHING FAULTED. `M1 FAULT 06` is M1's own deliberate #UD and is inside the
# 544-byte golden, so this asks about the RECOVERABLE fault report.
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "something faulted during the compositor boot"; }
ck; ! grep -q '^SHM REFUSE' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "a shared-memory call was refused; the clients should have needed none"; }
# THE RAISE AND THE MOVES, and the final origin the host computed.
ck; havere "^WM RAISE W $RAISE_TO FROM $RAISE_FROM PX [0-9A-F]{8}\$"
ck; [[ "$(countof '^WM MOVE W ')" -eq "$DRAG_MOVES" ]] \
  || fail "$(countof '^WM MOVE W ') drag steps were applied, the host model derives $DRAG_MOVES"
ck; havere "^WM MOVE W $DRAG_WIN X $MOVED_X Y $MOVED_Y FROM [0-9A-F]{4} Y [0-9A-F]{4} PX [0-9A-F]{8}\$"
# **A DRAG STEP MUST BE A PARTIAL REPAINT.** If it composed a full frame the
# pixel count would be at least the screen, and the whole reason wmRepaintRect
# exists (GAP-0301) would be gone without any other assertion noticing.
capture_sh MVPX_OUT MVPX_STATUS -- "python3 - '$SER' '$PX1' <<'PY'
import re, sys
t = open(sys.argv[1]).read()
full = int(sys.argv[2], 16)
px = [int(m, 16) for m in re.findall(r'^WM (?:MOVE|RAISE) .* PX ([0-9A-F]{8})\$', t, re.M)]
if not px:
    raise SystemExit('no WM MOVE/RAISE lines carry a pixel count')
worst = max(px)
if worst >= full:
    raise SystemExit('a drag step painted %d pixels and a full desktop fill alone is %d -- '
                     'the partial repaint is not partial' % (worst, full))
print('    every drag step painted at most %d pixels; a full frame is %d or more' % (worst, full))
PY"
ck; [[ $MVPX_STATUS -eq 0 ]] || { echo "$MVPX_OUT" >&2; fail "a pointer-driven repaint was not a PARTIAL repaint"; }
echo "$MVPX_OUT"
# NOTHING WAS COMPOSED IN FULL DURING PHASE 2. Four frames, and no more --
# a drag that fell back to wmCompose would still look right and would add
# a fifth WM FRAME line.
ck; [[ "$(countof '^WM FRAME N ')" -eq 4 ]] \
  || fail "$(countof '^WM FRAME N ') composition passes, expected exactly 4 — a drag that fell back to a full frame would still look right and would not be D5b"
echo "TRANSCRIPT: pass  one WM ON, two attaches, three commits (the third a ${DMG_W}x${DMG_H} damage present), four frames at $PX1/$PX2/$PX3/$PX4 pixels, one forged handle refused, two derived exit codes, one raise, $DRAG_MOVES partial-repaint drag steps ending at X $MOVED_X Y $MOVED_Y, and no faults"

# ===========================================================================
# Step 8 — THE PIXELS. The exit criterion.
# ===========================================================================
echo
echo "=== PIXELS ==="
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported out of the transcript"
ck; [[ -s "$FB_BIN" ]] || fail "comp-drive.py produced no framebuffer dump"
FB_BYTES=$(wc -c <"$FB_BIN" | tr -d ' ')
ck; [[ "$FB_BYTES" -eq $(( PITCH * 600 )) ]] \
  || fail "the framebuffer dump is $FB_BYTES bytes and $PITCH * 600 is $(( PITCH * 600 ))"

# ANTI-VACUITY FIRST, before any probe: a dump of one colour would satisfy every
# probe that happened to want that colour, and a dump of zeroes would satisfy
# none but would look like a compositor bug rather than a broken read.
capture_sh DIST_OUT DIST_STATUS -- "python3 - '$FB_BIN' '$MODEL' <<'PY'
import re, sys
blob = open(sys.argv[1], 'rb').read()
words = set()
for i in range(0, len(blob), 4):
    words.add(int.from_bytes(blob[i:i+4], 'little') & 0xFFFFFF)
if len(words) < 2:
    raise SystemExit('the framebuffer holds %d distinct colour(s); a uniform screen '
                     'satisfies every probe that happens to want that colour' % len(words))
want = set()
for line in open(sys.argv[2]):
    m = re.match(r'^probe=\S+ \d+ \d+ ([0-9A-F]{8})\$', line.strip())
    if m:
        want.add(int(m.group(1), 16) & 0xFFFFFF)
missing = sorted(want - words)
if missing:
    raise SystemExit('the model names colour(s) %s and the framebuffer contains none of '
                     'them anywhere' % ['%06X' % c for c in missing])
print('    %d distinct colours in the frame, and every colour the model names is present'
      % len(words))
PY"
ck; [[ $DIST_STATUS -eq 0 ]] || { echo "$DIST_OUT" >&2; fail "the framebuffer dump cannot support a pixel assertion"; }
echo "$DIST_OUT"

# THE PROBES. Every one is a colour at a coordinate, both computed on the host.
PROBES_RUN=0
while IFS= read -r line; do
  set -- $line
  PROBES_RUN=$(( PROBES_RUN + 1 ))
  ck; python3 "$SCRIPT_DIR/probe.py" "$FB_BIN" "$PITCH" "$2" "$3" "$4" "$1" \
    || fail "pixel probe '$1' failed — the compositor did not put that colour there"
done < <(sed -n 's/^probe=//p' "$MODEL")
ck; [[ "$PROBES_RUN" -eq "$PROBE_COUNT" ]] \
  || fail "the probe loop ran $PROBES_RUN times and the model derives $PROBE_COUNT probes"
echo "PIXELS: pass  $PROBES_RUN probes, every one a colour the host computed at a coordinate the host computed"

# ===========================================================================
# Step 9 — THE CONTROL THAT MUST FAIL.
# ===========================================================================
echo
echo "=== CONTROL ==="
CONTROL=$(sed -n 's/^control=//p' "$MODEL")
ck; [[ -n "$CONTROL" ]] || fail "the model emitted no control probe; the negative control would be skipped silently"
set -- $CONTROL
CTL_NAME="$1"; CTL_X="$2"; CTL_Y="$3"; CTL_COLOUR="$4"
capture CTL_OUT CTL_STATUS -- python3 "$SCRIPT_DIR/probe.py" "$FB_BIN" "$PITCH" "$CTL_X" "$CTL_Y" "$CTL_COLOUR" "$CTL_NAME"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "the control probe '$CTL_NAME' exited $CTL_STATUS, expected 1 (a MISMATCH). It asserts the BOTTOM window's fill at a coordinate inside the overlap; a pass there would mean the compositor drew the windows in the wrong order, and any other status would mean probe.py could not run at all and the eleven checks above are worth nothing."
echo "    the control asserted $CTL_COLOUR at ($CTL_X,$CTL_Y) and FAILED, which is the required outcome:"
echo "$CTL_OUT" | sed 's/^/    /'
echo "CONTROL: pass  the bottom window's colour is NOT in the overlap; the top window's is (probe b_overlap, above)"

# ===========================================================================
# Step 9b — THE SECOND FRAME: the pointer raised a window and moved it.
# ===========================================================================
echo
echo "=== PIXELS AFTER THE DRAG ==="
ck; [[ -s "$FB_BIN2" ]] || fail "comp-drive.py produced no second framebuffer dump"
FB2_BYTES=$(wc -c <"$FB_BIN2" | tr -d ' ')
ck; [[ "$FB2_BYTES" -eq $(( PITCH * 600 )) ]] \
  || fail "the second framebuffer dump is $FB2_BYTES bytes and $PITCH * 600 is $(( PITCH * 600 ))"
# THE TWO DUMPS MUST DIFFER. They are two readings of one boot, and if the
# pointer changed nothing they would be identical -- and every phase-2 probe
# that happened to match a phase-1 colour would pass anyway.
ck; ! cmp -s "$FB_BIN" "$FB_BIN2" \
  || fail "the framebuffer is byte-identical before and after the drag; the pointer changed nothing on screen and every phase-2 probe below is being satisfied by phase 1's frame"
PROBES2_RUN=0
while IFS= read -r line; do
  set -- $line
  PROBES2_RUN=$(( PROBES2_RUN + 1 ))
  ck; python3 "$SCRIPT_DIR/probe.py" "$FB_BIN2" "$PITCH" "$2" "$3" "$4" "$1" \
    || fail "phase-2 pixel probe '$1' failed — the compositor did not put that colour there after the drag"
done < <(sed -n 's/^probe2=//p' "$MODEL")
ck; [[ "$PROBES2_RUN" -eq "$PROBE2_COUNT" ]] \
  || fail "the phase-2 probe loop ran $PROBES2_RUN times and the model derives $PROBE2_COUNT probes"
echo "PIXELS: pass  $PROBES2_RUN probes on the frame the POINTER produced"

# THE SECOND CONTROL, and it is the sharpest one in this harness: the colour
# that WAS at the raise coordinate, asserted after the raise. It is not an
# arbitrary wrong colour -- it is the previous frame's CORRECT one, and probe
# `before_raise` above asserts it positively in the first dump.
echo
echo "=== CONTROL 2 ==="
CONTROL2=$(sed -n 's/^control2=//p' "$MODEL")
ck; [[ -n "$CONTROL2" ]] || fail "the model emitted no second control probe"
set -- $CONTROL2
C2_NAME="$1"; C2_X="$2"; C2_Y="$3"; C2_COLOUR="$4"
capture C2_OUT C2_STATUS -- python3 "$SCRIPT_DIR/probe.py" "$FB_BIN2" "$PITCH" "$C2_X" "$C2_Y" "$C2_COLOUR" "$C2_NAME"
ck; [[ $C2_STATUS -eq 1 ]] \
  || fail "the stacking control '$C2_NAME' exited $C2_STATUS, expected 1 (a MISMATCH). It asserts, AFTER the raise, the colour that was correct BEFORE it — and probe 'before_raise' asserts that same colour positively in the first dump. A pass here would mean the click did not change which window is on top."
echo "    the control asserted $C2_COLOUR at ($C2_X,$C2_Y) — the colour probe 'before_raise' found there in the FIRST dump — and FAILED, which is the required outcome:"
echo "$C2_OUT" | sed 's/^/    /'
echo "CONTROL 2: pass  the pixel that was the top window's before the click is not the top window's after it"

# ===========================================================================
# Step 9c — A SECOND BOOT: does the compositor actually OWN the framebuffer?
# ===========================================================================
#
# ADR-0050's decision is "the compositor and the text console alternate by
# mode". Everything above asserts the composed picture and nothing above asserts
# THE MODE -- a kernel whose gate did nothing would compose exactly the same
# frames and then let the shell's next line of output blit glyphs over them, and
# every probe in this harness would still pass, because every probe is taken
# before the shell prints anything again.
#
# So: bring the compositor up, print a SCREENFUL of text at it, and require
# that NOT ONE FOREGROUND PIXEL of the console font reached the framebuffer.
# Then `wm off`, print the same screenful, and require that they did. Two dumps,
# one boot, and the assertion is the presence and absence of ONE COLOUR --
# `fbColorFg`, read out of `fb.dart` rather than written here.
#
# `help` is the command, because it is the longest fixed output this shell has
# (2511 bytes, GAP-0105) and it needs no disk.
echo
echo "=== OWNERSHIP ==="
FB_FG=$(printf '%08X' "$(dartconst fbColorFg fb.dart)")
FB_BG=$(printf '%08X' "$(dartconst wmColorDesktop wm.dart)")
ck; [[ "$FB_FG" != "$FB_BG" ]] \
  || fail "the console's foreground colour and the desktop colour are the same ($FB_FG); 'no glyph reached the framebuffer' would be unobservable"

OWN_KEYS="$(typekeys 'fb'),ret,wait:1500"
OWN_KEYS="$OWN_KEYS,$(typekeys 'wm on'),ret,wait:3000"
OWN_KEYS="$OWN_KEYS,$(typekeys 'help'),ret,wait:2500"
# `wm` reports, `wm off` hands the framebuffer back, `help` fills it with glyphs,
# and `wm draw` is then REFUSED by name -- which is the last unexercised path in
# this file and is what the settle waits for, so the dump below is taken with
# the console's output on the screen and the refusal already printed.
OWN_KEYS2="$(typekeys 'wm'),ret,wait:800"
OWN_KEYS2="$OWN_KEYS2,$(typekeys 'wm off'),ret,wait:800"
OWN_KEYS2="$OWN_KEYS2,$(typekeys 'help'),ret,wait:2500"
OWN_KEYS2="$OWN_KEYS2,$(typekeys 'wm draw'),ret,wait:800"
OWN_SER="$WORKDIR/own-serial.txt"
OWN_FB1="$WORKDIR/own-fb1.bin"
OWN_FB2="$WORKDIR/own-fb2.bin"
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
  : >"$OWN_SER"
  timeout 400 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$OWN_SER" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
    >"$WORKDIR/own-qemu.log" 2>&1 &
  OWN_PID=$!
  QEMU_PIDS="$QEMU_PIDS $OWN_PID"
  run_status OWN_STATUS -- python3 "$DRIVER" \
    --port "$PORT" \
    --serial "$OWN_SER" \
    --wait-for 'M1 END\n' \
    --keys "$OWN_KEYS" \
    --settle-for 'echo <rest>   print the rest of the line' \
    --settle-timeout 60 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$OWN_FB1" \
    --png "$WORKDIR/own1.png" \
    --keys2 "$OWN_KEYS2" \
    --settle2-for 'R FFFFFFFFFFFFFFFD' \
    --fb-out2 "$OWN_FB2" \
    --png2 "$CORE_DIR/build/screenshot-compositor-console.png"
  await OWN_QSTATUS "$OWN_PID"
  if [[ $OWN_STATUS -ne 0 ]] && grep -q "Address already in use" "$WORKDIR/own-qemu.log" \
     && [[ $attempt -lt 5 ]]; then
    echo "    (port $PORT was taken between the probe and the launch; retrying — attempt $attempt)"
    continue
  fi
  break
done
ck; if [[ $OWN_STATUS -ne 0 ]]; then
  cat "$WORKDIR/own-qemu.log" >&2
  sed -n '/M1 END/,$p' "$OWN_SER" >&2
  fail "comp-drive.py exited $OWN_STATUS on the ownership boot"
fi
ck; if [[ $OWN_QSTATUS -ne 0 && $OWN_QSTATUS -ne 124 ]]; then
  cat "$WORKDIR/own-qemu.log" >&2
  fail "qemu-system-x86_64 exited $OWN_QSTATUS unexpectedly on the ownership boot"
fi
# THE SERIAL SIDE IS UNTOUCHED, and that is half the decision. `help`'s text
# must be on COM1 in BOTH phases -- the compositor suppresses GLYPHS, not
# OUTPUT, and if it ever suppressed output every byte-exact golden in this suite
# would have moved.
ck; [[ "$(grep -c 'print the rest of the line' "$OWN_SER")" -eq 2 ]] \
  || fail "'help' appears $(grep -c 'print the rest of the line' "$OWN_SER") time(s) on COM1, expected 2 — the compositor is suppressing SERIAL output and not just glyphs"
ck; grep -q '^WM OFF FRAMES ' "$OWN_SER" || fail "'wm off' printed nothing"
ck; grep -qE "^WM STATE A 1 WINS 0 PX [0-9A-F]{8} TOP $W_MAX MOVES 00000000 RAISES 00000000 DROPS 00000000\$" "$OWN_SER" \
  || fail "'wm' did not report a live compositor with no windows: $(grep -m1 '^WM STATE' "$OWN_SER")"
# `wm draw` WITH THE COMPOSITOR OFF is refused by name, and it is the only
# refusal in this file a person can reach from the shell.
WM_SYS_HEX=$(printf '%02X' "$W_SYS")
ck; grep -qE "^WM REFUSE C $WM_SYS_HEX OP 0000000000000000 H 0000000000000000 R FFFFFFFFFFFFFFFD\$" "$OWN_SER" \
  || fail "'wm draw' with the compositor off was not refused with wmRetOff. Got: $(grep -m1 '^WM REFUSE' "$OWN_SER")"
# ...and it drew NOTHING, which is what makes the refusal a refusal rather than
# a diagnostic printed beside the thing happening anyway.
ck; [[ "$(grep -c '^WM FRAME N ' "$OWN_SER")" -eq 1 ]] \
  || fail "$(grep -c '^WM FRAME N ' "$OWN_SER") composition passes on the ownership boot, expected exactly 1 (the one 'wm on' does) — the refused 'wm draw' composed a frame anyway"

capture_sh OWN_OUT OWN_PSTATUS -- "python3 - '$OWN_FB1' '$OWN_FB2' '$FB_FG' <<'PY'
import sys
fg = int(sys.argv[3], 16) & 0xFFFFFF
def count(path):
    blob = open(path, 'rb').read()
    n = 0
    for i in range(0, len(blob), 4):
        if (int.from_bytes(blob[i:i+4], 'little') & 0xFFFFFF) == fg:
            n += 1
    return n
on, off = count(sys.argv[1]), count(sys.argv[2])
if on != 0:
    raise SystemExit('%d pixel(s) of the console foreground colour %06X are on '
                     'the screen while the compositor owns it -- the gate in '
                     'fbPutc is not stopping glyphs' % (on, fg))
if off == 0:
    raise SystemExit('the console drew NOTHING after wm off -- the framebuffer '
                     'was never given back, so the check above is passing '
                     'because the console is broken rather than because the '
                     'compositor is working')
print('    while the compositor owns the framebuffer: %d glyph pixels. After '
      'wm off, with the SAME command: %d.' % (on, off))
PY"
ck; [[ $OWN_PSTATUS -eq 0 ]] || { echo "$OWN_OUT" >&2; fail "the framebuffer-ownership assertion failed"; }
echo "$OWN_OUT"
echo "OWNERSHIP: pass  a screenful of console output reached COM1 in both phases and reached the FRAMEBUFFER only after 'wm off'; 'wm' reports, and 'wm draw' with the compositor off is refused by name AND composes nothing — ADR-0050's mode, asserted as pixels rather than as a grep of fb.dart"

# ===========================================================================
# Step 10 — the screenshots a person can look at.
# ===========================================================================
echo
ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot at $SHOT_PNG"
ck; [[ -s "$SHOT_PNG2" ]] || fail "no screenshot at $SHOT_PNG2"
ck; [[ -s "$CORE_DIR/build/screenshot-compositor-console.png" ]] || fail "no ownership screenshot"
echo "SCREENSHOT: $SHOT_PNG2"
echo "SCREENSHOT: $SHOT_PNG"

require_assertions "$ASSERTIONS_REQUIRED"
echo "D2-compositor: PASS — dcc build -> verify-freestanding on kmain.o, kdata.o, portio.o and kernel.elf under /bin/bash $BASH_VER with 44 externs UNCHANGED -> structural checks (wmStore tiles exactly at $W_STORE bytes and is LAST in .bss with the total at $TOTAL_BSS; the descriptor is $W_DESCB bytes, which IS chanMsgBytes; wmMaxWindows equals shmMax; $W_SYS is in the syscall registry; the refusal codes are distinct, above one floor and agree with prog.c's private copy; the framebuffer gate is exactly ONE branch in fbPutc and vga.dart does not know it exists; every @rodata length agrees with its call site) -> clang builds ONE freestanding ELF64 that CONTAINS NO SHARED-WINDOW ADDRESS in its source or its emitted code -> make-image.py writes it to two byte-identical disk slots -> A REAL QEMU BOOT. Two processes in two different address spaces each create a shared region, are TOLD by the kernel where it is, paint a ${WIN_W}x${WIN_H} surface into it and commit it. The compositor composes four frames of $PX1, $PX2, $PX3 and $PX4 pixels — the last of them D6's ${DMG_W}x${DMG_H} damage present — and the framebuffer is then READ BACK OUT OF GUEST PHYSICAL MEMORY at the address the kernel found in a PCI BAR: $PROBES_RUN probes, each a colour computed on the host at a coordinate computed on the host, covering the desktop, both fills, both inner blocks, both borders in their two stacking colours, the TOP window's fill and border inside the $OVERLAP_AREA-pixel overlap, and the pointer's own edge, fill and clear pixels from this kernel's own 16x12 bitmaps. THEN, IN THE SAME BOOT AND WHILE BOTH SURFACES ARE STILL LIVE, a left click on the BOTTOM window inside the clients' hold — where the shell is not running and IRQ12 is the only thing that can act — RAISES it and $DRAG_MOVES pointer motions DRAG it to X $MOVED_X Y $MOVED_Y, the origin the host derived from the grab offset and the clamp; every one of those repaints is asserted to have painted FEWER pixels than a bare desktop fill, and the number of WM FRAME lines is asserted to still be 4. The framebuffer is read back a SECOND time and $PROBES2_RUN more probes cover the raised window's fill, ink and now-BRIGHT border, the other window's now-DIM border, the rectangle the window VACATED being desktop again, and the pointer's own three pixels over a window rather than over the desktop — which is what proves the erase-repaint recomputed what was underneath rather than remembering it. AND TWO CONTROLS THAT MUST FAIL: the bottom window's fill asserted inside the overlap before the raise, and — after the raise — the colour that probe 'before_raise' positively asserted at that same coordinate in the first dump. Each client exits with a 64-bit number derived from the pixels it actually wrote ($EXIT_A and $EXIT_B), computed on the host before the machine booted, and a forged capability handle is refused by name."
