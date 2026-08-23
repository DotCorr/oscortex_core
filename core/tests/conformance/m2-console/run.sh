#!/usr/bin/env bash
# core/tests/conformance/m2-console/run.sh
#
# Mechanical check of ROADMAP.md's M2 exit criterion: the kernel puts its
# output on a real screen and takes real keyboard input, and both are asserted
# by machine rather than looked at.
#
# THREE INDEPENDENT ASSERTIONS, deliberately of different kinds
# ---------------------------------------------------------------------------
#   1. SERIAL, byte-for-byte (`expected.txt`). Its head is m1-interrupts'
#      golden unchanged -- so this harness re-proves, on the same boot, that
#      adding a VGA console and a keyboard did not move one byte of the output
#      three earlier milestones depend on. Its tail is the ECHO of a fixed
#      keystroke sequence injected over QMP. That tail is the keyboard proof:
#      no key pressed, no bytes; wrong translation, wrong bytes.
#
#   2. THE FRAMEBUFFER, byte-for-byte (`expected-screen.txt`). Read out of
#      GUEST PHYSICAL MEMORY at 0xB8000 through the QEMU monitor's `xp`
#      command and decoded to 25 lines of text. This is what the video
#      hardware would actually display -- not a re-render of what the kernel
#      intended. It asserts things serial cannot: that the mirror works, that
#      backspace EDITS the screen (serial sees `ab\bc`, the screen shows `ac`),
#      and that scrolling works (the typed lines push the boot banner off the
#      top, and the golden's first line is no longer `OSCORTEX M0 OK`).
#
#   3. A PNG SCREENSHOT at core/build/screenshot.png, from QEMU's own
#      `screendump`. NOT asserted, on purpose: a pixel comparison would break
#      on a font or palette change that says nothing about the kernel. It
#      exists to be looked at, and its ABSENCE is a failure.
#
# GOLDENS REGENERATED AT M3 (2026-08-21), DELIBERATELY
# ---------------------------------------------------------------------------
# Both goldens in this directory were regenerated when the shell landed
# (ADR-0006). That is not a harness being made green: the key sequence below is
# UNCHANGED, and every property this harness asserts is unchanged. What changed
# is the kernel's answer to a keystroke. At M2 a typed line was echoed and
# discarded; at M3 it is a COMMAND, so `oscortex 2026` now produces an
# unknown-command diagnostic and a fresh prompt. Re-recording the goldens was
# the only honest option -- the alternative was to keep asserting behaviour the
# kernel no longer has.
#
# What survives, and is still the point of this file:
#   * the M1 prefix check (untouched, and M1's golden did not move a byte);
#   * backspace EDITING the screen -- serial still sees `ab\bc` while the
#     screen still shows `ac`, and the shell now proves it twice over, because
#     the command it dispatches on is `ac` rather than `abc`;
#   * real scrolling -- there is MORE output per line now, so the boot banner is
#     pushed further off the top than it was (the screen golden's first line is
#     an `MB E` entry, where it used to be `MB UPP`);
#   * the PNG.
#
# WHY THE KEYSTROKES ARE REAL
# ---------------------------------------------------------------------------
# QMP `send-key` drives QEMU's emulated PS/2 controller: it synthesizes make
# and break scancodes into the 8042, which raises IRQ1, which the CPU delivers
# through this kernel's own IDT to its own DCDart handler, which reads port
# 0x60 and translates through a `@rodata` table. Nothing about the path is
# stubbed. A key sequence that produced the right serial echo with a broken
# IDT, a masked PIC line, or a wrong translation table is not constructible.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m2-console/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M2-console: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-console: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DRIVER="$SCRIPT_DIR/qmp-drive.py"
[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER"

# The M1 golden, reused as a prefix check. Keeping the RELATIONSHIP mechanical
# rather than documented is the point: if someone regenerates M2's golden after
# a serial change, this still fails and names M1.
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m2.XXXXXX")" || setup_error "could not create a temp workdir"
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

# 2a. THE MMIO STORES MUST SURVIVE OPTIMIZATION.
#
# This is the check this milestone exists to make, and it is new: as of
# 2026-08-21 `dcc` passes `-O2` (DCDart ADR-0042), where every DCDart object
# ever built before that day was -O0. A store to a VGA cell is textbook dead
# code -- nothing in this program ever reads it back -- so without DCDart
# ADR-0041's volatile `Pointer<T>` access, LLVM would delete `vgaClear`'s
# entire loop and leave a function whose whole body is `ret`.
#
# Asserted on the ACCESS, not the value, for the same reason ADR-0041's own
# harness is shaped that way: the value-checking test passed throughout the
# period the bug was live.
CLEAR_STORES=$(x86_64-elf-objdump -d --disassemble=vgaClear "$CORE_DIR/build/kmain.o" \
  | grep -cE 'movw[[:space:]]+\$0xf20')
if [[ "$CLEAR_STORES" -lt 1 ]]; then
  x86_64-elf-objdump -d --disassemble=vgaClear "$CORE_DIR/build/kmain.o" >&2
  fail "vgaClear contains no 16-bit store of the blank cell 0x0f20 — the MMIO writes were optimized away (DCDart ADR-0041's volatile Pointer<T> access regressed, or -O is on without it)"
fi
echo "STRUCTURAL: pass  vgaClear keeps $CLEAR_STORES volatile 16-bit MMIO store(s) under optimization"

# 2b. No vectorized stores in the screen loops. LLVM cannot merge volatile
# accesses, so a `movdqa`/`movups` appearing here would mean the stores stopped
# being volatile — the same defect as 2a, caught before it becomes total
# deletion. A real check, not a restatement: this fires while 2a still passes.
if x86_64-elf-objdump -d --disassemble=vgaClear "$CORE_DIR/build/kmain.o" \
   | grep -qE '\b(movdqa|movdqu|movaps|movups)\b'; then
  fail "vgaClear contains vector stores — volatile semantics were lost, so the individual MMIO writes are being coalesced"
fi
echo "STRUCTURAL: pass  vgaClear has no coalesced/vector stores (volatile semantics intact)"

# 2c. The keyboard translation table must be a real 128-byte @rodata table.
# A wrong size means either a header appeared in front of element 0 (which
# would shift every lookup) or the table was truncated (which would make
# high scancodes index off the end).
KBD_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="kbdSet1Ascii" {print $3; exit}')
[[ -n "$KBD_SIZE" ]] || fail "kbdSet1Ascii symbol not found in kmain.o — the scancode table was not emitted"
if [[ "$KBD_SIZE" -ne 128 ]]; then
  fail "kbdSet1Ascii is $KBD_SIZE bytes, expected exactly 128 (one entry per make code) — a make code has bit 7 clear, so 128 entries is what makes every lookup in-range by construction"
fi
echo "STRUCTURAL: pass  kbdSet1Ascii is exactly 128 bytes in .rodata"

# 2d. The donated mutable storage must really be in .bss, and the two words
# THIS milestone needs must still be the first two of it. DCDart has no mutable
# statics (known-gaps GAP-0053); core/boot/kdata.S is the workaround.
#
# CHANGED AT M3: this used to assert the whole section was exactly 16 bytes,
# which was the right check while M2's two words were all of it. The shell
# added a 256-byte line buffer and four more words, so the total moved to 304
# and the exact-total assertion moved WITH it, to m3-shell/run.sh — one place
# owns that number, and it is the milestone that grew it. What this harness
# asserts instead is the part that is M2's: `vga_cursor` and `m2_phase` are
# still 8 bytes each and still present. A shrunk or missing cursor word is
# still caught here; a deliberate growth is no longer a false failure here.
# ---------------------------------------------------------------------------
# M17 (docs/decisions/0021-mutable-statics-and-the-end-of-donated-bss.md):
# WHERE THE MUTABLE STORAGE LIVES NOW. This check did not change what it
# asserts; it changed where it reads it from, and it is written out here rather
# than only in a commit message because an accounting assertion that moves is
# exactly the kind of thing that must never move quietly.
#
# Until M17 every mutable byte in this kernel was hand-donated `.bss` in
# core/boot/kdata.S, because DCDart had no mutable static data (GAP-0053).
# DCDart ADR-0051 landed `@bss`, so the blocks are now DCDart mutable statics
# declared in the subsystem that owns them, and they land in `kmain.o`'s `.bss`.
# FIVE WORDS DID NOT MOVE and never will: `cpu_info`, `shell_resume_rsp`,
# `shell_resume_ok`, `user_resume_rsp` and `user_resume_ok` are written by
# assembly itself (isr.S), and a `@bss` symbol is LOCAL, so assembly cannot
# name one. Those 96 bytes are still in kdata.o.
#
# So the total is a SUM OF TWO OBJECTS, and every historical number below is
# reproduced by it byte for byte: 16 at M2, 304 at M3, 392 at M4, 424 at M5/M6,
# 5096 at M7, 5224 at M8, 5368 at M9, 5496 at M10, 9664 at M11-M13, 11488 at
# M14, 14048 at M16. `DART_BSS` is the DCDart half, `ASM_BSS` the assembly
# half; offset arithmetic ("bytes from this block to the end") is done inside
# DART_BSS, because every block a later milestone added is in that half.
bssfield() {   # bssfield <readelf column> <symbol> -- kmain.o first, then kdata.o
  local f="$1" n="$2" o v
  for o in kmain.o kdata.o; do
    v=$(x86_64-elf-readelf -sW "$CORE_DIR/build/$o" \
          | awk -v s="$n" -v f="$f" '$4=="OBJECT" && $8==s {print $f; exit}')
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
bssaddr() {    # bssaddr <symbol> -- the LINKED address of a @bss block.
  # A `@bss` symbol is LOCAL to kmain.o and kernel.ld's OUTPUT_FORMAT(elf32-i386)
  # container keeps no local symbols, so kernel.elf's symbol table cannot answer
  # this. The LINK MAP can, and it is the linker's own statement of where it put
  # kmain.o's `.bss`; the block's offset inside that section comes from kmain.o.
  local n="$1" base off
  base=$(awk '$1==".bss" && $4 ~ /kmain\.o$/ {print $2; exit}' "$CORE_DIR/build/kernel.map")
  [[ -n "$base" ]] || return 1
  off=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
          | awk -v s="$n" '$4=="OBJECT" && $8==s {print $2; exit}')
  [[ -n "$off" ]] || return 1
  printf '%x\n' $(( 16#${base#0x} + 16#$off ))
}
bsssize() { bssfield 3 "$1"; }
bssoff()  { bssfield 2 "$1"; }
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
[[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$(( DART_BSS + ASM_BSS ))
if [[ "$KDATA_BSS" -lt 16 ]]; then
  fail "the kernel's mutable static storage is $KDATA_BSS bytes, which is less than the 16 M2's console alone needs"
fi
for sym in vgaCursorWord m2PhaseWord; do
  SZ=$(bsssize "$sym")
  [[ "$SZ" == "8" ]] || fail "$sym is ${SZ:-missing} bytes, expected 8 — the console's mutable state changed shape"
done
echo "STRUCTURAL: pass  the kernel holds $KDATA_BSS bytes of mutable static storage ($DART_BSS DCDart @bss + $ASM_BSS assembly-written), including vgaCursorWord and m2PhaseWord at 8 bytes each"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi

# ---------------------------------------------------------------------------
# Step 4 — boot, type, capture.
#
# `-m 128M` is pinned for the same reason m1-interrupts pins it: the `MB ...`
# portion of the golden is a real memory map and every figure in it is a
# function of the RAM size.
#
# The QMP endpoint is TCP rather than a UNIX socket: macOS caps a UNIX socket
# path at 104 bytes and the default TMPDIR there is already most of that. The
# port is derived from the shell PID so concurrent runs do not collide, and the
# bind failing is a hard error (QEMU exits), never a silent skip.
# ---------------------------------------------------------------------------
SERIAL_CAPTURE="$WORKDIR/serial.txt"
: >"$SERIAL_CAPTURE"
QMP_PORT=$(( 45000 + ($$ % 10000) ))
SCREEN_TEXT="$WORKDIR/screen.txt"
SHOT_DIR="$CORE_DIR/build"
SHOT_PNG="$SHOT_DIR/screenshot.png"
rm -f "$SHOT_PNG"

# The key sequence. Every keystroke is echoed to BOTH outputs, so this string
# is what makes both goldens what they are.
#
#   oscortex 2026<enter>   ordinary letters, digits and space
#   ab<backspace>c<enter>  serial sees `ab\bc`; the SCREEN shows `ac`. The two
#                          goldens differ here by construction, which is what
#                          proves the console does real cursor editing rather
#                          than mirroring a byte stream.
#   scroll1..scroll5       five more lines, enough to push the screen past row
#                          25 and force real scrolling. Without these the boot
#                          report fits exactly and vgaScroll never executes.
KEYS="o,s,c,o,r,t,e,x,spc,2,0,2,6,ret"
KEYS="$KEYS,a,b,backspace,c,ret"
for n in 1 2 3 4 5; do
  KEYS="$KEYS,s,c,r,o,l,l,$n,ret"
done

timeout 90 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -serial "file:$SERIAL_CAPTURE" \
  -display none \
  -no-reboot \
  -qmp "tcp:127.0.0.1:$QMP_PORT,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!

python3 "$DRIVER" \
  --port "$QMP_PORT" \
  --serial "$SERIAL_CAPTURE" \
  --wait-for 'M1 END\n' \
  --png "$SHOT_PNG" \
  --screen-text "$SCREEN_TEXT" \
  --keys "$KEYS"
DRIVE_STATUS=$?

wait "$QEMU_PID" 2>/dev/null
QEMU_STATUS=$?

if [[ $DRIVE_STATUS -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial captured so far ---" >&2
  cat "$SERIAL_CAPTURE" >&2
  fail "qmp-drive.py exited $DRIVE_STATUS — the kernel did not reach the interactive console, or QMP failed. This is a FAILURE, not a skip: if keystroke injection stops working, this milestone stops being verified."
fi

# The driver ends with `quit`, so 0 is the expected exit. 124 (timeout) would
# mean the driver never got that far, which DRIVE_STATUS would already have
# caught; anything else is a real QEMU-level failure.
if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  fail "qemu-system-x86_64 exited $QEMU_STATUS unexpectedly (log above)"
fi

# ---------------------------------------------------------------------------
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — adding the console changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 5b. The whole serial capture, including the keyboard echo.
if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- captured serial ---" >&2
  cat -v "$SERIAL_CAPTURE" >&2
  echo "--- expected ---" >&2
  cat -v "$EXPECTED_SERIAL" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte (boot report + keyboard echo)"

# 5c. The framebuffer.
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  echo "--- expected ---" >&2
  cat -n "$EXPECTED_SCREEN" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 5d. The screenshot has to exist and has to be a PNG.
[[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG (QEMU's screendump format argument may be unsupported on this build)" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

echo "M2-console: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S) -> link -> structural checks -> verify-freestanding pass -> real QEMU boot (-m 128M) with real QMP keystroke injection: M1's golden intact as a byte-exact prefix, ${SERIAL_BYTES}-byte serial match including the echo of every typed key, exact 80x25 framebuffer match read from guest memory (backspace edited the screen, five lines of scrolling), and a PNG screenshot at $SHOT_PNG"
exit 0
