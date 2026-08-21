#!/usr/bin/env bash
# core/tests/conformance/m3-shell/run.sh
#
# Mechanical check of ROADMAP.md's M3 exit criterion: the kernel is a shell —
# it edits a line, dispatches commands, produces real results, and reports
# what it does not understand — and every claim is asserted by machine.
#
# WHAT THIS ASSERTS THAT M2 COULD NOT
# ---------------------------------------------------------------------------
# M2 proved keystrokes arrive and are echoed. That is an echo box: no state
# survives a keystroke, so nothing can be *submitted*. Everything below depends
# on state surviving, and on a command running in TASK context rather than in
# an interrupt handler:
#
#   * a LINE exists, so backspace shortens it and Enter submits it;
#   * a PROMPT exists, and backspace cannot erase it (typed backspaces at an
#     empty prompt are asserted to produce no bytes at all, and the prompt is
#     asserted intact in the framebuffer afterwards);
#   * commands produce results the boot report does not — `mem` re-walks the
#     Multiboot map from a pointer stashed at boot AND totals the usable
#     regions, and the harness checks the re-walk equals the boot-time dump
#     line for line;
#   * `ticks` observes the PIT counter advance, which is only possible because
#     commands run with interrupts enabled — inside the IRQ1 handler IF is
#     clear and that wait would deadlock;
#   * an unknown command names what was typed instead of failing silently;
#   * arrow keys type NOTHING. At M2 the up arrow typed `8`
#     (docs/known-gaps.md GAP-0055 item 2, a wrong answer rather than a missing
#     feature). Four arrow presses are injected at an empty prompt and asserted
#     to produce zero bytes.
#
# SIX INDEPENDENT ASSERTIONS
# ---------------------------------------------------------------------------
#   1. SERIAL, byte-for-byte (`expected.txt`). Its first 544 bytes are
#      m1-interrupts' golden, checked MECHANICALLY as a prefix against M1's own
#      file rather than merely documented — so regenerating this golden after a
#      serial change still fails and still names M1.
#   2. ZERO BYTES from three backspaces and four arrow presses at an empty
#      prompt, checked as an exact byte sequence on the wire rather than as an
#      absence in a diff. Two claims in one: the prompt is uneraseable, and the
#      0xE0 extended-key prefix is handled.
#   3. THE `mem` RE-WALK equals the boot-time dump, extracted from the same
#      capture and compared to itself.
#   4. THE FRAMEBUFFER, byte-for-byte (`expected-screen.txt`), read out of
#      GUEST PHYSICAL MEMORY at 0xB8000 with the monitor's `xp`. This is what
#      the video hardware would display, not a re-render of what the kernel
#      meant.
#   5. A PNG at core/build/screenshot-shell.png. NOT asserted (a pixel diff
#      would break on a font change that says nothing about the kernel), but
#      its absence is a failure.
#   6. A NEGATIVE CONTROL: a second real boot with a DIFFERENT key sequence
#      must fail both goldens, diverging past M1's 544th byte. A check that
#      cannot fail is not a check.
#
# `qmp-drive.py` is REUSED from m2-console rather than duplicated — one driver,
# two harnesses. The `wait:<ms>` element in the key list is new and is not
# cosmetic: a shell runs commands, and `ticks` deliberately takes 160 ms, so
# without an explicit pause the keys that follow it would be injected into a
# running command and dropped (there is no input queue — GAP-0055 item 4).
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m3-shell/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M3-shell: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M3-shell: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
# Deliberately the M2 harness's driver, not a copy of it.
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m3-shell reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m3.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build.
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
bash "$CORE_DIR/scripts/build-kernel.sh" >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
cat "$BUILD_LOG"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS (log above)"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
[[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — structural checks (CLAUDE.md: anything checkable without booting
# should be).
# ---------------------------------------------------------------------------

# 2a. THE DONATED STORAGE THIS MILESTONE ADDED.
#
# DCDart has no mutable static data of any kind (docs/known-gaps.md GAP-0053).
# core/boot/kdata.S is the workaround and its size is the running measure of
# the gap's cost. M2 donated 16 bytes; M3's line editor needs a BUFFER, and
# there is no array type either, so M3 took it to 304:
#
#   vga_cursor 8 + m2_phase 8 + shell_line 256 + shell_len 8
#   + shell_state 8 + shell_mbinfo 8 + kbd_prefix 8  =  304
#
# CHANGED AT M4, exactly the way it changed at M3. The EXACT-TOTAL assertion
# has moved to m4-fault/run.sh (392 bytes), because one harness should own that
# number and it is the milestone that grew it — the same reasoning that moved
# it here from m2-console, recorded in GAP-0059. What this harness asserts
# instead is the part that is genuinely M3's: the five words the shell owns are
# still present and still the right sizes. A shrunk, renamed or missing shell
# word is still caught here; a deliberate growth elsewhere is no longer a false
# failure here.
KDATA_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$KDATA_BSS_HEX" ]] || fail "kdata.o has no .bss section — the donated storage is missing"
KDATA_BSS=$((16#$KDATA_BSS_HEX))
if [[ "$KDATA_BSS" -lt 304 ]]; then
  fail "kdata.o .bss is $KDATA_BSS bytes, which is less than the 304 M2's console and M3's shell need between them (known-gaps GAP-0053)"
fi
for sym in shell_len shell_state shell_mbinfo kbd_prefix; do
  SZ=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ "$SZ" == "8" ]] || fail "kdata.o's $sym is ${SZ:-missing} bytes, expected 8 — the shell's donated state changed shape"
done
echo "STRUCTURAL: pass  kdata.o donates $KDATA_BSS bytes of .bss, including all four of M3's shell state words at 8 bytes each"

# 2b. The line buffer is really 256 bytes, and shell.dart's shellLineMax says
# the same. A buffer shorter than the constant is a silent overflow of donated
# .bss — it would write over kbd_prefix and whatever came next.
LINE_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="shell_line" {print $3; exit}')
[[ -n "$LINE_SIZE" ]] || fail "shell_line symbol not found in kdata.o"
if [[ "$LINE_SIZE" -ne 256 ]]; then
  fail "shell_line is $LINE_SIZE bytes, expected 256"
fi
if ! grep -q 'const int shellLineMax = 256;' "$CORE_DIR/kernel/shell.dart"; then
  fail "core/kernel/shell.dart's shellLineMax no longer says 256 — the DCDart bound and the donated buffer would disagree, and the editor would write past the end of .bss"
fi
echo "STRUCTURAL: pass  shell_line is 256 bytes and shell.dart's shellLineMax agrees"

# 2c. THE COMMAND-NAME TABLES ARE EXACT.
#
# Dispatch is a byte-compare over two ranges (there are no strings in @bare
# DCDart). The comparison length is a literal at each call site because a
# @rodata table carries no length word (DCDart ADR-0040: elements only). A
# table that is not the size the dispatcher assumes reads past its own end, so
# the sizes are asserted rather than trusted.
check_table() {
  local sym="$1" want="$2"
  local got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table the shell dispatches on was not emitted"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes, expected $want (the dispatcher compares exactly $want bytes)"
}
check_table shellCmdHelp 4
check_table shellCmdClear 5
check_table shellCmdMem 3
check_table shellCmdTicks 5
check_table shellCmdEcho 4
check_table shellStrPrompt 10
# 395, not 237: M4 added `cpu` and two `crash` lines to the listing. The number
# is the table's real size and both it and the literal in shellHelp() are
# maintained by hand (GAP-0060) — the first M4 build printed 237 bytes of the
# 395-byte table because only one of the two had been updated.
check_table shellStrHelp 1155  # M5 added `pci`/`fb`, M6 two `disk` lines, M7 six frame-allocator lines, M8 `vm`/`vmtest`; GAP-0060
check_table shellStrUnknown 27
echo "STRUCTURAL: pass  all 8 shell @rodata tables are exactly the sizes the dispatcher compares"

# 2d. `idle_once` MUST BE `sti; hlt; ret`, IN THAT ORDER, WITH NOTHING BETWEEN
# THE FIRST TWO.
#
# This is the sleeping race, and it is invisible in a passing boot. The shell's
# main loop does `cli`, tests its state word, and sleeps only if there is
# nothing to do. x86 delivers no interrupt between `sti` and the very next
# instruction, so `sti; hlt` adjacent means a keystroke arriving in that window
# wakes the CPU instead of being missed. Anything inserted between them — a
# reordering, a debug call, a compiler-inserted anything — reintroduces a hang
# that only shows up as "it stopped responding after a keystroke", occasionally.
IDLE_ONCE_OPS=$(x86_64-elf-objdump -d --disassemble=idle_once "$CORE_DIR/build/isr.o" \
  | awk '/^ +[0-9a-f]+:/ {print $NF}' | tr '\n' ' ')
case "$IDLE_ONCE_OPS" in
  "sti hlt ret "*) ;;
  *)
    x86_64-elf-objdump -d --disassemble=idle_once "$CORE_DIR/build/isr.o" >&2
    fail "idle_once is not 'sti; hlt; ret' (got: $IDLE_ONCE_OPS) — sti and hlt must be adjacent or the shell can sleep through the keystroke it was waiting for"
    ;;
esac
echo "STRUCTURAL: pass  idle_once is exactly 'sti; hlt; ret' — the wake-up race stays closed"

# 2e. The scancode table is still exactly 128 bytes. Carried over from
# m2-console because M3 changed kbdHandle, and a make code is only in range by
# construction while the table has one entry per possible make code.
KBD_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$8=="kbdSet1Ascii" {print $3; exit}')
[[ "$KBD_SIZE" == "128" ]] || fail "kbdSet1Ascii is ${KBD_SIZE:-missing} bytes, expected exactly 128"
echo "STRUCTURAL: pass  kbdSet1Ascii is still exactly 128 bytes in .rodata"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1), on every object dcc or
# the assembler produced that can be checked in isolation, plus the image.
#
# boot.o and isr.o are still excluded and still legitimately so: each
# references one DCDart symbol only the link resolves, and being assembly they
# have no dcc-written extern manifest (docs/known-gaps.md GAP-0056).
# kernel.elf covers them.
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o, every one named in core/boot/{isr,kdata}.S"

# ---------------------------------------------------------------------------
# Step 4 — boot, drive a real session, capture.
#
# The session, in order. Every element is here to make a specific claim:
#
#   h,e,l,q,BACKSPACE,p,ret   a typo corrected INSIDE the line. Serial sees
#                             `helq\bp`; the command that runs is `help`, which
#                             is only true if backspace edited the BUFFER and
#                             not just the screen.
#   m,e,m,ret                 re-walks the Multiboot map from the pointer
#                             boot.S stashed, and totals usable RAM. Asserted
#                             twice: byte-for-byte, and against the boot dump.
#   f,r,o,b,n,i,c,a,t,e,ret   unknown command. Must name what was typed.
#   e,c,h,o,spc,...,ret       `echo hello world` -> `hello world`.
#   c,l,e,a,r,ret             clears the screen and homes the cursor. Nothing
#                             on serial: you cannot un-print a serial byte, and
#                             faking it would be a different operation wearing
#                             this one's name.
#   BACKSPACE x3              at a freshly cleared, EMPTY prompt. Must produce
#                             no bytes and leave the prompt intact — which the
#                             framebuffer golden then proves, because the
#                             prompt they failed to erase is still row 0.
#   up,down,left,right        GAP-0055 item 2. At M2 these typed `8`, `2`, `4`,
#                             `6`. They must now produce nothing at all.
#   t,i,c,k,s,ret             the PIT counter, observed advancing.
#   wait:350                  `ticks` takes 160 ms and there is no input queue.
#   h,e,l,p,ret               leaves the screen showing a full command listing
#                             on an otherwise-cleared screen, which is also
#                             what makes the screenshot worth looking at.
# ---------------------------------------------------------------------------
SESSION_KEYS="h,e,l,q,backspace,p,ret"
SESSION_KEYS="$SESSION_KEYS,m,e,m,ret"
SESSION_KEYS="$SESSION_KEYS,f,r,o,b,n,i,c,a,t,e,ret"
SESSION_KEYS="$SESSION_KEYS,e,c,h,o,spc,h,e,l,l,o,spc,w,o,r,l,d,ret"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret"
SESSION_KEYS="$SESSION_KEYS,backspace,backspace,backspace,up,down,left,right"
SESSION_KEYS="$SESSION_KEYS,t,i,c,k,s,ret,wait:350"
SESSION_KEYS="$SESSION_KEYS,h,e,l,p,ret"

SHOT_PNG="$CORE_DIR/build/screenshot-shell.png"
rm -f "$SHOT_PNG"

# Boots the kernel, injects $2, and leaves the capture at $1/serial.txt and the
# decoded framebuffer at $1/screen.txt. Used twice: once for the real session,
# once for the negative control.
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  # Port derived from the shell PID so concurrent runs do not collide; the
  # second call adds 1 so the two boots in ONE run cannot collide either.
  local port=$(( 46000 + ($$ % 8000) + ${5:-0} ))
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --png "$png" \
    --screen-text "$outdir/screen.txt" \
    --keys "$keys"
  local drive_status=$?
  wait "$qemu_pid" 2>/dev/null
  local qemu_status=$?
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot — the kernel did not reach the shell, or QMP failed. This is a FAILURE, not a skip: if keystroke injection stops working, this milestone stops being verified."
  fi
  # The driver ends with `quit`, so 0 is expected; 124 would be the timeout,
  # which drive_status would already have caught.
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 0
SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"

# ---------------------------------------------------------------------------
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — the shell changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 5b. The whole serial capture.
if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- captured serial ---" >&2
  cat -v "$SERIAL_CAPTURE" >&2
  echo "--- expected ---" >&2
  cat -v "$EXPECTED_SERIAL" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte (boot report + a full shell session)"

# 5c. THE PROMPT SURVIVED THE BACKSPACES AND THE ARROWS, ON THE WIRE.
#
# Between the echo of `clear` and the echo of `ticks` the session pressed
# backspace three times and all four arrow keys at an EMPTY prompt. If
# backspace could erase the prompt there would be 0x08 bytes here; if the 0xE0
# prefix were still mishandled there would be `8`, `2`, `4` and `6`. The
# expected byte sequence is the prompt and then `ticks`, with nothing between.
if ! python3 - "$SERIAL_CAPTURE" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
want = b"clear\noscortex> ticks\n"
if want not in data:
    i = data.find(b"clear\n")
    print("m3-shell: prompt-protection check FAILED", file=sys.stderr)
    print("  expected the bytes %r, got %r" % (want, data[i:i+40]), file=sys.stderr)
    sys.exit(1)
PY
then
  fail "three backspaces and four arrow presses at an empty prompt produced bytes on COM1 — either backspace erased past the prompt, or the 0xE0 extended-key prefix is being translated as an ordinary key again (docs/known-gaps.md GAP-0055 item 2)"
fi
echo "ASSERT: pass  3 backspaces + 4 arrow keys at an empty prompt emitted ZERO bytes (prompt uneraseable, GAP-0055 item 2 fixed)"

# 5d. THE `mem` RE-WALK EQUALS THE BOOT-TIME DUMP.
#
# Both come out of the SAME capture, so this compares the kernel against
# itself: the Multiboot structure is still there, still parseable from the
# pointer boot.S stashed, and still says exactly the same thing after
# interrupts, a deliberate fault and a console have all happened on top of it.
python3 - "$SERIAL_CAPTURE" >"$WORKDIR/dumps.txt" <<'PY'
import sys
lines = open(sys.argv[1], "rb").read().decode("latin-1").split("\n")
blocks, cur = [], None
for ln in lines:
    if ln.startswith("MB FLAGS "):
        cur = []
    if cur is not None:
        cur.append(ln)
        if ln.startswith("MB END"):
            blocks.append("\n".join(cur))
            cur = None
print(len(blocks))
for b in blocks:
    print("----")
    print(b)
PY
DUMP_COUNT=$(head -1 "$WORKDIR/dumps.txt")
[[ "$DUMP_COUNT" == "2" ]] || fail "expected exactly 2 'MB FLAGS ... MB END' blocks in the capture (one at boot, one from the mem command), found $DUMP_COUNT"
awk '/^----$/{n++; next} n==1' "$WORKDIR/dumps.txt" >"$WORKDIR/dump-boot.txt"
awk '/^----$/{n++; next} n==2' "$WORKDIR/dumps.txt" >"$WORKDIR/dump-shell.txt"
if ! cmp -s "$WORKDIR/dump-boot.txt" "$WORKDIR/dump-shell.txt"; then
  diff -u "$WORKDIR/dump-boot.txt" "$WORKDIR/dump-shell.txt" >&2
  fail 'the memory map printed by the mem command differs from the one printed at boot -- the same walk over the same structure gave two different answers'
fi
echo 'ASSERT: pass  the mem command re-walk is line-for-line identical to the boot-time dump'

# 5e. The framebuffer.
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  echo "--- expected ---" >&2
  cat -n "$EXPECTED_SCREEN" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 5f. The screenshot.
[[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG (QEMU's screendump format argument may be unsupported on this build)" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 6 — THE NEGATIVE CONTROL.
#
# A check that cannot fail is not a check. m2-console ran this by hand; running
# it in the harness means the property is re-proved on every run rather than
# remembered from a changelog. The same kernel, a DIFFERENT key sequence: both
# goldens must fail, and the serial divergence must start AFTER M1's 544 bytes
# (if it started earlier, the goldens would be failing for some reason that has
# nothing to do with what was typed).
# ---------------------------------------------------------------------------
NEG_KEYS="e,c,h,o,spc,n,o,p,e,ret"
drive_session "$WORKDIR/negative" "$NEG_KEYS" "$WORKDIR/negative/shot.png" "negative-control" 1

if cmp -s "$WORKDIR/negative/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a different key sequence produced the same serial capture. The serial golden is not actually sensitive to what was typed."
fi
if cmp -s "$WORKDIR/negative/screen.txt" "$EXPECTED_SCREEN"; then
  fail "NEGATIVE CONTROL FAILED: a different key sequence produced the same framebuffer. The screen golden is not actually sensitive to what was typed."
fi
NEG_DIVERGE=$(cmp "$WORKDIR/negative/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE 'byte [0-9]+' | grep -oE '[0-9]+' | head -1)
[[ -n "$NEG_DIVERGE" ]] || NEG_DIVERGE=$(( M1_BYTES + 1 ))
if [[ "$NEG_DIVERGE" -le "$M1_BYTES" ]]; then
  fail "NEGATIVE CONTROL FAILED: the divergence starts at byte $NEG_DIVERGE, which is inside M1's ${M1_BYTES}-byte golden — the goldens are failing for a reason unrelated to what was typed."
fi
echo "ASSERT: pass  negative control — a different key sequence fails BOTH goldens, serial diverging at byte $NEG_DIVERGE (M1's golden is $M1_BYTES bytes, so the divergence is entirely in the shell session)"

echo "M3-shell: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S) -> link -> 5 structural checks -> verify-freestanding pass ($EXTERN_COUNT declared externs) -> a real QEMU boot (-m 128M) driving a real shell session over QMP: ${SERIAL_BYTES}-byte serial match with M1's golden intact as a prefix, an uneraseable prompt, arrow keys emitting nothing, a memory-map re-walk identical to the boot dump, an exact 80x25 framebuffer match read from guest memory, a PNG at $SHOT_PNG, and a negative control that fails both goldens"
exit 0
