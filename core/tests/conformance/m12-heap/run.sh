#!/usr/bin/env bash
# core/tests/conformance/m12-heap/run.sh
#
# Mechanical check of ROADMAP.md's M12 exit criterion: a user process on this
# kernel can ASK FOR MEMORY AT RUNTIME, be given real pages with real
# permissions, be TOLD NO in a way it can check, and give every page back when
# it dies -- to the frame.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# M11 gave each process an address space. What it did not give any of them was a
# way to get one more page than its ELF asked for: `procSlotHi` was the top of
# the world and stayed there for the life of the process (GAP-0096 item 6). A
# `malloc` cannot exist on that machine, so neither can any real C program.
#
#   * A SYSCALL THAT ALLOCATES. `sbrk` (number 4) takes frames from the PMM,
#     zeroes them, and maps them into THE CALLING PROCESS's window as
#     user + writable + NX. The permissions are read back OUT OF THE LIVE PAGE
#     TABLES in guest RAM, with the process still on the CPU.
#
#   * ABSENT BEFORE, PRESENT AFTER, FROM TWO BOOTS OF THE SAME BINARY. The disk
#     carries progH twice more with two bytes changed: one copy stops at a
#     labelled `nop; nop` BEFORE its first `sbrk`, one stops AFTER its last. The
#     page tables are dumped in both, and the same walk that finds ~500
#     user-writable-NX pages in the second finds NOTHING AT ALL in the first.
#     That is what turns "the syscall created the mapping" from an inference
#     into a measurement.
#
#   * THE PATTERN IS CONFIRMED AT THE PHYSICAL FRAME. The program writes a
#     signature derived from its own `.rodata` into every page it is given and
#     reads it back; this harness then translates the virtual address through
#     the page tables IT walked and reads the same qword out of guest physical
#     memory. A kernel that returned addresses without mapping frames could
#     print anything it liked on the serial port and could not do that.
#
#   * THE REFUSALS ARE WALKED, NOT DESCRIBED. The program grows its heap until
#     even a single page is refused -- ~500 pages, ending at exactly the guard
#     page below the stack -- and then keeps running, asks again, is refused
#     again, and exits normally. Two more refusals (an increment of
#     0xFFFF...FFFF, which is what a C program's `sbrk(-1)` becomes, and one
#     byte more than the whole window) are exercised by BOTH processes.
#
#   * THE LEAK CHECK IS EXACT. `frames` before and after must print the same
#     free count, after a session in which one process took 507 heap pages and
#     the other took 5. `PROC KILL ... FREED n` is checked against a number
#     DERIVED from the two ELFs plus the four table frames.
#
#   * ISOLATION, AT THE SAME ADDRESS. The two programs are ONE SOURCE COMPILED
#     TWICE, so their heaps start at the same virtual address by construction.
#     Each writes its own signature there and reads back its own; the harness
#     then proves from the two page tables that the same address is a DIFFERENT
#     PHYSICAL FRAME in each.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * `heapRetNoMem` -- the frame allocator running out part-way through a
#     grow -- IS NOT REACHED BY ANY BOOT HERE, and this was measured rather
#     than assumed. The address-space bound is ~500 pages and the smallest
#     machine this kernel boots on has thousands of free frames, so the window
#     always fills first. docs/known-gaps.md GAP-0108 is the accounting, and
#     the structural check below at least requires the code path to exist and
#     to be reachable from a `return`.
#   * There is no `free`. The break never moves down. GAP-0107.
#
# Usage:
#   core/tests/conformance/m12-heap/run.sh
#   ... --regen    rewrite the goldens from this boot (the derived checks below
#                  still have to pass, so a wrong kernel cannot enshrine itself)
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "M12-heap: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M12-heap: FAIL — $1" >&2; exit 2; }

# GAP-0168 / ADR-0032: shared harness machinery -- the `ck` assertion counter,
# the `require_assertions` floor checked immediately before the PASS line, and
# the capture()/run_status()/await() replacements for capture-then-`$?`.
# Sourced AFTER fail(), which every helper in it reports through.
source "$SCRIPT_DIR/../_lib/harness.sh"

# How many checks this harness must have executed before it is allowed to
# print PASS. Derived from a run, not counted by hand: run the harness and
# read the "ASSERTIONS: pass  <n> checks executed" line it prints just above
# its PASS line. It moves when the harness legitimately gains or loses checks,
# exactly like the pinned .bss sizes elsewhere in this file -- and a DROP
# below it is the failure this exists to catch.
ASSERTIONS_REQUIRED=144


for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m12.XXXXXX")" || setup_error "mktemp failed"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
DERIVE="$SCRIPT_DIR/derive.py"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
ck; [[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"

# ---------------------------------------------------------------------------
# Step 1 — build.
# ---------------------------------------------------------------------------
capture BUILD_OUT BUILD_STATUS -- bash "$CORE_DIR/scripts/build-kernel.sh"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

dartconst() {
  # `const int NAME = VALUE;` out of a kernel source, decimal or hex.
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks.
# ---------------------------------------------------------------------------

# 2a. THE DONATED `.bss` DID NOT GROW, AND THAT IS A CLAIM ABOUT THE DESIGN.
#
# Every milestone from M7 to M11 needed more mutable state in `kdata.S`:
# 424 -> 5096 -> 5224 -> 5368 -> 5496 -> 9664. A heap needs four numbers per
# process -- base, break, pages, calls -- and M11 deliberately left slot words
# 16..31 unused so that a later field would land somewhere somebody chose. So
# M12 adds ZERO bytes of donated storage, and this is where that is checked
# rather than claimed.
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
# M14, 14048 at M16, and 9728/11552/14112 at M18 -- M18 (ADR-0022) grew procStore by 64 bytes -- six scheduler header words and two per-slot counters, in the block the process table already owns rather than in a second one -- so every total below moves by exactly 64. `DART_BSS` is the DCDart half, `ASM_BSS` the assembly
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
ck; [[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
ck; [[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$DART_BSS
# S0 (ADR-0033) added a block AFTER M19's, and it is now the LAST one in .bss:
# `ioctlStore`, 512 bytes -- 32 metadata words and the 256-byte `ioctl` bounce
# buffer, which is the only memory a DRM payload is ever copied through.
# Subtracted FIRST, before M19's, exactly as M14, M15, M16 and M19 each were in
# turn, so that every earlier milestone's number continues to mean what it meant
# when it was written.
#
# **ADR-0031 §4.3 rule 5 SAID PUTTING THE BLOCK LAST WOULD LEAVE "every existing
# harness's 'bytes from my block to the end' arithmetic unchanged". THAT IS NOT
# QUITE TRUE, AND THIS BLOCK IS THE PROOF.** Last is necessary but not
# sufficient: the previously-last block's own to-the-end measurement is exactly
# the one a new block after it changes. M19's number went 256 -> 768 and twelve
# harnesses said so. ADR-0033 §6.4.
# M21 (ADR-0041) added a block AFTER S0's, and it is now the LAST one in .bss:
# `shmStore`, 8576 bytes -- 16 global counter words, four 64-byte shared-region
# records, and an 8192-byte BIT-PLANE with one bit per frame in the machine that
# says whether a live region owns that frame. The plane is what makes the guard
# at the top of `freeFrame` O(1) instead of a linear scan on all 65536 calls of
# `frames refill` (`docs/design/memory.md` §2.4).
#
# Subtracted FIRST, before S0's, exactly as M14, M15, M16, M19 and S0 each were
# in turn -- so that every earlier milestone's number continues to mean what it
# meant when it was written. This is the THIRD application of ADR-0033 §6.4's
# correction to ADR-0031 §4.3 rule 5: last is necessary but not sufficient, and
# the previously-last block's own to-the-end measurement is exactly the one a
# new block after it changes. S0's number goes 512 -> 8960 nowhere, because it
# is measured to shmStore's start rather than to the end of .bss -- which is the
# line below, and which is why it still reads 512.
# D4 (ADR-0050) added a block AFTER M21's, and it is now the LAST one in .bss:
# `wmStore`, 320 bytes -- nineteen compositor state words (counters, the drag
# and its grab offset, the painted pointer position, and the re-entrancy guard)
# in a 24-word block, then two 64-byte window records, one per shared region,
# because a window's pixels live in a region and `shmMax` is 2.
#
# Subtracted FIRST, before M21's, exactly as M14, M15, M16, M19, S0 and M21 each
# were in turn -- so that every earlier milestone's number continues to mean what
# it meant when it was written. This is the FOURTH application of ADR-0033 §6.4's
# correction to ADR-0031 §4.3 rule 5: last is necessary but not sufficient, and
# the previously-last block's own to-the-end measurement is exactly the one a new
# block after it changes. M21's number below still reads 8576 for that reason --
# it is measured to wmStore's start rather than to the end of .bss.
# D2 (ADR-0054) added a block AFTER D4's, and it is now the LAST one in .bss:
# `kbdqStore`, 288 bytes -- four header words (head, tail, dropped, count)
# and 32 event slots. Subtracted FIRST, before D4's, so D4's number still
# reads 320 -- it is now measured to kbdqStore's START rather than to the
# end of .bss.
# D7 (ADR-0055) added a block AFTER D2's, and it is now the LAST one in .bss:
# `wmeventStore`, 192 bytes -- two per-window rings (four header words and
# 8 event slots each). Subtracted FIRST, before D2's, so D2's number still
# reads 288 -- it is now measured to wmeventStore's START rather than to
# the end of .bss.
D7_OFF_HEX=$(bssoff wmeventStore)
ck; [[ -n "$D7_OFF_HEX" ]] || fail "wmeventStore has no .bss offset in kmain.o -- D7's click-event block (ADR-0055) is missing"
D7_BSS=$(( KDATA_BSS - 16#$D7_OFF_HEX ))
ck; [[ "$D7_BSS" -eq 1920 ]] || fail "the bytes from D7's wmeventStore to the end of .bss are $D7_BSS, expected 1920. If that block changed size, change it in ADR-0109, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D7_BSS ))
D2_OFF_HEX=$(bssoff kbdqStore)
ck; [[ -n "$D2_OFF_HEX" ]] || fail "kbdqStore has no .bss offset in kmain.o -- D2's input-queue block (ADR-0054) is missing"
D2_BSS=$(( KDATA_BSS - 16#$D2_OFF_HEX ))
ck; [[ "$D2_BSS" -eq 288 ]] || fail "the bytes from D2's kbdqStore to D7's wmeventStore are $D2_BSS, expected 288. If that block changed size, change it in ADR-0054, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D2_BSS ))
D4_OFF_HEX=$(bssoff wmStore)
ck; [[ -n "$D4_OFF_HEX" ]] || fail "wmStore has no .bss offset in kmain.o -- D4's compositor block (ADR-0050) is missing"
D4_BSS=$(( KDATA_BSS - 16#$D4_OFF_HEX ))
ck; [[ "$D4_BSS" -eq 1472 ]] || fail "the bytes from D4's wmStore to D2's kbdqStore are $D4_BSS, expected 1472. If that block changed size, change it in ADR-0109, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D4_BSS ))
M21_OFF_HEX=$(bssoff shmStore)
ck; [[ -n "$M21_OFF_HEX" ]] || fail "shmStore has no .bss offset in kmain.o -- M21's shared-memory block (ADR-0041) is missing"
M21_BSS=$(( KDATA_BSS - 16#$M21_OFF_HEX ))
ck; [[ "$M21_BSS" -eq 9600 ]] || fail "the bytes from M21's shmStore to the end of .bss are $M21_BSS, expected 8832 — ADR-0109 made it 4480, and ADR-0155 doubled `pmmMaxFrames` to 65536, which the bit-plane must track (`shmPlaneFrames == pmmMaxFrames`, asserted in m21-shmem), so the plane went 4096 -> 8192. If that block changed size, change it in ADR-0109/ADR-0155, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M21_BSS ))
S0_OFF_HEX=$(bssoff ioctlStore)
ck; [[ -n "$S0_OFF_HEX" ]] || fail "ioctlStore has no .bss offset in kmain.o -- S0's ioctl block (ADR-0033) is missing"
S0_BSS=$(( KDATA_BSS - 16#$S0_OFF_HEX ))
ck; [[ "$S0_BSS" -eq 512 ]] || fail "the bytes from S0's ioctlStore to M21's shmStore are $S0_BSS, expected 512. If that block changed size, change it in ADR-0033, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - S0_BSS ))
# D1 (ADR-0042) added a block BEFORE S0's, because ADR-0031 s4.3 rule 5 requires
# the ioctl bounce buffer to stay LAST: `mouseStore`, 160 bytes -- twenty words
# of PS/2 mouse driver state, of which the first five are the packet being
# assembled and the rest are the accumulated pointer, five counters, the DETECTED
# packet size and device id, and the init-progress bitmap. Subtracted SECOND,
# after S0's block and before M20's, exactly as M14, M15, M16, M19, M20 and S0
# each were in turn, so that every earlier milestone's number continues to mean
# what it meant when it was written.
D1_OFF_HEX=$(bssoff mouseStore)
ck; [[ -n "$D1_OFF_HEX" ]] || fail "mouseStore has no .bss offset in kmain.o -- D1's PS/2 mouse block (ADR-0042) is missing"
D1_BSS=$(( KDATA_BSS - 16#$D1_OFF_HEX ))
ck; [[ "$D1_BSS" -eq 160 ]] || fail "the bytes from D1's mouseStore to S0's ioctlStore are $D1_BSS, expected 160. If that block changed size, change it in ADR-0042, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D1_BSS ))
# M19 (ADR-0023) added a block AFTER M16's, and it is the LAST one in .bss:
# `argsStore`, 256 bytes -- eight metadata words, eight per-argument offsets and
# 128 bytes of argument text, which is where a command line is staged before it
# is copied onto the program's own stack page. Subtracted FIRST, before every
# earlier milestone's, so that this harness's own number continues to mean what
# it meant when it was written. Exactly the accounting M14, M15 and M16 each got
# in turn.
# M20 (ADR-0027) added a block AFTER M19's, and S0's `ioctlStore` later landed
# behind it, so it is the SECOND-TO-LAST block in .bss and is subtracted second:
# `chanStore`, 2624 bytes -- eight global counter words and two 1280-byte channel
# port records, each of which is a 128-byte header, 128 bytes of per-slot lengths
# and 1024 bytes of message ring. Subtracted after S0's block and before every
# earlier milestone's, so that this harness's own number continues to mean what it meant
# when it was written. Exactly the accounting M14, M15, M16 and M19 each got in
# turn.
M20_OFF_HEX=$(bssoff chanStore)
ck; [[ -n "$M20_OFF_HEX" ]] || fail "chanStore has no .bss offset in kmain.o -- M20's IPC channel block (ADR-0027) is missing"
M20_BSS=$(( KDATA_BSS - 16#$M20_OFF_HEX ))
ck; [[ "$M20_BSS" -eq 2624 ]] || fail "the bytes from M20's chanStore to D1's mouseStore are $M20_BSS, expected 2624. If that block changed size, change it in ADR-0027, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M20_BSS ))
M19_OFF_HEX=$(bssoff argsStore)
ck; [[ -n "$M19_OFF_HEX" ]] || fail "argsStore has no .bss offset in kmain.o -- M19's argument block (ADR-0023) is missing"
M19_BSS=$(( KDATA_BSS - 16#$M19_OFF_HEX ))
ck; [[ "$M19_BSS" -eq 256 ]] || fail "the bytes from M19's argsStore to M20's chanStore are $M19_BSS, expected 256. If that block changed size, change it in ADR-0023, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M19_BSS ))
# M15 (ADR-0019) added a block AFTER M14's: `file_store`, 1280 bytes -- 16
# metadata words, five rows of four file descriptors, and a one-sector bounce
# buffer. Subtracted FIRST, before M14's, so that this harness's own milestone's
# number continues to mean in 2026 what it meant when it was written.
M15_OFF_HEX=$(bssoff fileStore)
ck; [[ -n "$M15_OFF_HEX" ]] || fail "file_store has no .bss offset in kdata.o -- M15's file-descriptor block is missing"
M15_BSS=$(( KDATA_BSS - 16#$M15_OFF_HEX ))
ck; [[ "$M15_BSS" -eq 6016 ]] || fail "the donated bytes from M15's file_store to the end of .bss are $M15_BSS, expected 6016 — 1280 at M15, 2560 at M16, +1024 for 8 proc rows, doubled by M16's write path (ADR-0020 §7). If that block changed size again, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M15_BSS ))
# M14 (ADR-0018) added `fat_store`, 1824 bytes, AFTER M12. Subtracted here so
# that M12's own claim -- "a heap needed no new mutable state" -- still means in
# 2026 what it meant when it was written.
M14_OFF_HEX=$(bssoff fatStore)
ck; [[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
ck; [[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824"
KDATA_BSS=$(( KDATA_BSS - M14_BSS ))
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))   # M17 (ADR-0021): the DCDart half plus the 96 assembly-owned bytes
ck; [[ "$KDATA_BSS" -eq 27264 ]] || fail "the kernel's mutable static storage outside M14's fatStore is $KDATA_BSS bytes, expected 27264 (26240 at 16 slots plus 1024 for the 17th process slot and matching FXSAVE). M12's per-process heap state lives in process-table slot words 16..19."
echo "STRUCTURAL: pass  kdata.o donates 9664 bytes of .bss outside M14's fat_store — M12 added no mutable state of its own"

# 2b. THE STORAGE SEAM IS STILL EXACTLY THREE CALL SITES, ALL IN proc.dart.
#
# ADR-0011 §0's migration plan is only three lines long if the number of places
# that know where the process table's memory came from stays three. A heap that
# had reached for its own `@extern` would have made it four.
SEAM_SITES=$(grep -c '^\s*return Bss[.]addressOf(procStore)' "$CORE_DIR/kernel/proc.dart")
ck; [[ "$SEAM_SITES" -eq 3 ]] || fail "Bss.addressOf(procStore) is returned from $SEAM_SITES functions in proc.dart, expected exactly 3"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "proc.dart" ]] && continue
  ck; grep -qw 'procStore' "$f" && fail "$(basename "$f") references procStore — the process table's storage seam must not leak out of proc.dart"
done
ck; grep -qE '^\s*(final u64 |u64 )?[A-Za-z]* *=? *Pointer<u64>\.fromAddress' "$CORE_DIR/kernel/heap.dart" \
  && fail "heap.dart dereferences a raw address of its own. Every word of heap state must go through procGet/procSet, which is what keeps it behind ADR-0011's seam."
echo "STRUCTURAL: pass  the storage seam is still 3 call sites in proc.dart, and heap.dart reaches its state only through procGet/procSet"

# 2c. heap.dart's GEOMETRY, MULTIPLIED OUT AGAINST vm.dart's WINDOW AND AGAINST
#     derive.py's COPY OF IT.
#
# The heap lives between the top of a program and the stack, so three files have
# to agree about where those are. A `heapTop` that drifted one page up would put
# the last heap page on top of the stack, and the only thing that would notice
# is a program that grew far enough -- which is exactly what this milestone's
# program does, so the failure would be real but the diagnosis would be awful.
HEAP_TOP=$(dartconst heapTop heap.dart)
HEAP_TOP_INDEX=$(dartconst heapTopIndex heap.dart)
HEAP_GUARD_PAGE=$(dartconst heapGuardPage heap.dart)
HEAP_GUARD_INDEX=$(dartconst heapGuardIndex heap.dart)
HEAP_MAX_INC=$(dartconst heapMaxInc heap.dart)
HEAP_SBRK_NO=$(dartconst heapSysSbrkNo heap.dart)
PROG_BASE=$(dartconst vmProgBase vm.dart)
PROG_END=$(dartconst vmProgEnd vm.dart)
PROG_BYTES=$(dartconst vmProgBytes vm.dart)
PROG_PAGES=$(dartconst vmProgPages vm.dart)
PAGE_BYTES=$(dartconst vmPageBytes vm.dart)
STACK_PAGE=$(dartconst vmProgStackPage vm.dart)
YIELD_NO=$(dartconst procSysYieldNo proc.dart)
for v in HEAP_TOP HEAP_TOP_INDEX HEAP_GUARD_PAGE HEAP_GUARD_INDEX HEAP_MAX_INC \
         HEAP_SBRK_NO PROG_BASE PROG_END PROG_BYTES PROG_PAGES PAGE_BYTES STACK_PAGE YIELD_NO; do
  ck; [[ -n "${!v}" ]] || fail "could not read $v out of the kernel sources"
done
ck; [[ $(( STACK_PAGE - PAGE_BYTES )) -eq "$HEAP_TOP" ]] \
  || fail "heapTop is $HEAP_TOP but the stack page is $STACK_PAGE — there must be exactly ONE unmapped guard page between the top of the heap and the bottom of the stack"
ck; [[ "$HEAP_GUARD_PAGE" -eq "$HEAP_TOP" ]] || fail "heapGuardPage ($HEAP_GUARD_PAGE) is not heapTop ($HEAP_TOP)"
ck; [[ $(( PROG_BASE + HEAP_TOP_INDEX * PAGE_BYTES )) -eq "$HEAP_TOP" ]] \
  || fail "heapTopIndex $HEAP_TOP_INDEX does not multiply back out to heapTop"
ck; [[ "$HEAP_GUARD_INDEX" -eq "$HEAP_TOP_INDEX" ]] || fail "heapGuardIndex is not heapTopIndex"
ck; [[ "$HEAP_MAX_INC" -eq "$PROG_BYTES" ]] \
  || fail "heapMaxInc is $HEAP_MAX_INC and the whole window is $PROG_BYTES — the largest increment one call may ask for is the whole window and no more"
ck; [[ $(( PROG_BASE + PROG_PAGES * PAGE_BYTES )) -eq "$PROG_END" ]] \
  || fail "vm.dart's window geometry does not multiply out"
ck; [[ "$HEAP_SBRK_NO" -ne "$YIELD_NO" ]] || fail "sbrk and yield have the same syscall number"
ck; [[ "$HEAP_SBRK_NO" -eq 4 ]] || fail "heapSysSbrkNo is $HEAP_SBRK_NO; prog.c hard-codes 4 as its SYS_SBRK"
echo "STRUCTURAL: pass  heapTop, its page index, the guard page and the maximum increment all multiply back out against vm.dart's window and against each other ($HEAP_TOP_INDEX heap pages max, one guard page, then the stack)"

# 2d. derive.py's COPIES OF THOSE CONSTANTS AGREE WITH THE KERNEL'S.
ck; python3 - "$DERIVE" "$HEAP_TOP" "$HEAP_TOP_INDEX" "$HEAP_GUARD_PAGE" "$HEAP_GUARD_INDEX" \
        "$HEAP_MAX_INC" "$HEAP_SBRK_NO" \
        "$(dartconst heapRetNoMem heap.dart)" "$(dartconst heapRetNoSpace heap.dart)" \
        "$(dartconst heapRetBadArg heap.dart)" "$(dartconst heapRetFloor heap.dart)" \
        "$(dartconst heapSlotBase heap.dart)" "$(dartconst heapSlotBrk heap.dart)" \
        "$(dartconst heapSlotPages heap.dart)" "$(dartconst heapSlotCalls heap.dart)" \
        <<'PY' || fail "derive.py's copies of heap.dart's constants do not all agree with heap.dart"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m12_derive", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
names = ["HEAP_TOP", "HEAP_TOP_INDEX", "HEAP_GUARD_PAGE", "HEAP_GUARD_INDEX",
         "HEAP_MAX_INC", "HEAP_SYS_SBRK_NO", "HEAP_RET_NOMEM", "HEAP_RET_NOSPACE",
         "HEAP_RET_BADARG", "HEAP_RET_FLOOR", "HEAP_SLOT_BASE", "HEAP_SLOT_BRK",
         "HEAP_SLOT_PAGES", "HEAP_SLOT_CALLS"]
bad = []
for i, n in enumerate(names):
    want = int(sys.argv[2 + i])
    got = getattr(m, n)
    if got != want:
        bad.append("derive.py has %s = %s, heap.dart says %s" % (n, hex(got), hex(want)))
for b in bad:
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  derive.py's fourteen copies of heap.dart's constants all agree with heap.dart"

# 2e. THE THREE REFUSALS ARE DISTINCT, ARE ALL ABOVE THE FLOOR, AND THE FLOOR IS
#     ABOVE ANYTHING THE WINDOW CAN CONTAIN.
#
# A program tells success from failure with ONE comparison, `ret > floor`. If a
# legal break could ever exceed the floor the test would be a coin toss, and if
# two refusals shared a value a program could not tell "the machine is out of
# memory" from "your address space is full" -- which are different facts with
# different remedies.
ck; python3 - "$(dartconst heapRetNoMem heap.dart)" "$(dartconst heapRetNoSpace heap.dart)" \
         "$(dartconst heapRetBadArg heap.dart)" "$(dartconst heapRetFloor heap.dart)" \
         "$PROG_END" <<'PY' || fail "heap.dart's refusal values are not usable by a ring-3 program"
import sys
nomem, nospace, badarg, floor, prog_end = (int(a) for a in sys.argv[1:6])
bad = []
vals = {"heapRetNoMem": nomem, "heapRetNoSpace": nospace, "heapRetBadArg": badarg}
if len(set(vals.values())) != 3:
    bad.append("the three refusal values are not distinct: %s" % vals)
for n, v in vals.items():
    if v <= floor:
        bad.append("%s (0x%X) is not above heapRetFloor (0x%X)" % (n, v, floor))
if floor < prog_end:
    bad.append("heapRetFloor 0x%X is below the top of the program window 0x%X -- a legal "
               "break could be mistaken for a refusal" % (floor, prog_end))
for b in bad:
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  the three refusal values are distinct, all above heapRetFloor, and heapRetFloor is far above any address the program window can hold"

# 2f. THE ORDER INSIDE `heapSbrk`, READ OUT OF THE SOURCE.
#
# The atomicity argument is entirely an argument about order:
#   * the oversize refusal comes BEFORE the round-up, which is the addition that
#     would overflow -- and DCDart turns an overflow into a real `ud2`, inside a
#     syscall handler, which takes the machine down instead of the request;
#   * the address-space bound comes BEFORE the first `allocFrame`, so a request
#     that could never fit never touches the allocator;
#   * every frame is ZEROED BEFORE it is mapped, so there is no instant at which
#     a page holding a dead process's bytes is reachable from ring 3.
ck; python3 - "$CORE_DIR/kernel/heap.dart" <<'PY' || fail "heapSbrk's checks are not in the order its safety argument needs"
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index("u64 heapSbrk("):]
body = body[:body.index("\n}\n")]
bad = []

def at(pat, what):
    m = re.search(pat, body)
    if not m:
        bad.append("heapSbrk has no %s" % what)
        return 10 ** 9
    return m.start()

badarg = at(r"return u64\(heapRetBadArg\)", "heapRetBadArg return")
roundup = at(r"\+ u64\(vmPageMask\)\)\s*>>", "round-up to whole pages")
nospace = at(r"return u64\(heapRetNoSpace\)", "heapRetNoSpace return")
alloc = at(r"allocFrame\(\)", "allocFrame call")
zero = at(r"vmZeroFrame\(", "vmZeroFrame call")
mapc = at(r"vmProgMap\(", "vmProgMap call")
rollback = at(r"heapRollback\(", "heapRollback call")
nomem = at(r"return u64\(heapRetNoMem\)", "heapRetNoMem return")

if not badarg < roundup:
    bad.append("the oversize refusal is not before the round-up: an increment of "
               "0xFFFFFFFFFFFFFFFF would overflow inside the syscall handler")
if not nospace < alloc:
    bad.append("the address-space bound is not checked before the first allocFrame")
if not zero < mapc:
    bad.append("vmZeroFrame is not called before vmProgMap -- there would be an instant "
               "in which a page holding another process's bytes is reachable from ring 3")
if not rollback < nomem:
    bad.append("heapRetNoMem is returned without heapRollback running first -- a "
               "half-finished grow would leak every frame it had already taken")
if body.count("allocFrame()") != 1:
    bad.append("heapSbrk calls allocFrame %d times; the rollback is written for one"
               % body.count("allocFrame()"))
if "vmProgMap" not in body:
    bad.append("heapSbrk never calls vmProgMap, so it maps nothing")
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  inside heapSbrk the oversize refusal precedes the round-up, the address-space bound precedes the first allocFrame, every frame is zeroed before it is mapped, and heapRollback precedes the out-of-memory return"

# 2g. EVERY REFUSAL RETURN IS REACHABLE FROM A `return`, INCLUDING THE ONE NO
#     BOOT HERE CAN WALK.
#
# m11-proc's 3g found a refusal code with a sentence and no `return` reaching
# it -- text the machine could never say. `heapRetNoMem` is this milestone's
# version of that risk, because no boot in this file exhausts the frame
# allocator (GAP-0108), so the ONLY thing standing between it and being dead
# text is this check.
for sym in heapRetNoMem heapRetNoSpace heapRetBadArg; do
  n=$(grep -cE "return u64\($sym\)" "$CORE_DIR/kernel/heap.dart")
  ck; [[ "$n" -ge 1 ]] || fail "$sym is never returned anywhere in heap.dart — it is a value the kernel cannot produce"
done
ck; grep -qE 'if \(no == u64\(heapSysSbrkNo\)\)' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart's syscall dispatcher never tests for heapSysSbrkNo — the syscall is unreachable"
ck; grep -qE 'heapSysSbrk\(frame\)' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart never calls heapSysSbrk"
ck; grep -qE 'heapInit\(s, elfMeta\(u64\(elfMetaHi\)\)\)' "$CORE_DIR/kernel/proc.dart" \
  || fail "procCreate does not give a new process a heap starting at elfMetaHi"
ck; grep -qE 'heapReset\(s\)' "$CORE_DIR/kernel/proc.dart" \
  || fail "procSpaceFree does not clear a dead process's heap bookkeeping"
echo "STRUCTURAL: pass  all three refusal values are returned somewhere, the dispatcher reaches heapSysSbrk, and procCreate/procSpaceFree call heapInit/heapReset"

# 2h. EVERY @rodata TABLE IS EXACTLY THE SIZE ITS CALL SITE PASSES (GAP-0060).
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  ck; [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M12 depends on was not emitted (a table with no call site is dropped by the linker)"
  ck; [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table heapStrLine 10
check_table heapStrInc 5
check_table heapStrOld 5
check_table heapStrNew 5
check_table heapStrBase 6
check_table heapStrTop 5
check_table procStrPages 7
check_table vmStrErr 5
check_table shellStrHelp 2511
echo "STRUCTURAL: pass  M12's six new message tables, the two it reuses, and shellStrHelp (2511 — the heap is a syscall and added no help line) are all exactly the sizes their call sites pass"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# 58 externs, UNCHANGED from M11. A heap needed no assembly at all: the frames
# come from the PMM, the mapping goes through vm.dart, and the state lives in
# the process table. That is the whole claim of this line.
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
ck; [[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$CORE_DIR/build/portio.o" "$KERNEL_ELF"'
echo "$VERIFY_OUT"
ck; if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
# M15 (ADR-0019) added exactly ONE: `fileStore`, the file-descriptor
# table's storage seam. Subtracted for the same reason every block above is.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\bfile_store_addr\b" <<<"$VERIFY_OUT" && fail "file_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fileStore"
M15_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M15_PRESENT ))
# M14 added exactly ONE extern: `fatStore`.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && fail "fat_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fatStore"
M14_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
# M17 (ADR-0021) deleted 16 `_addr()` accessor externs at or before this
# milestone, because the assembly-donated `.bss` they addressed became DCDart
# `@bss` mutable statics. The kernel now declares 44.
# Each deleted name is asserted ABSENT as well as the count being asserted: a
# count alone can be restored by an unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr vm_store_addr user_store_addr \
            elf_store_addr proc_store_addr fat_store_addr \
            file_store_addr; do
  ck; grep -q "\\b$gone\\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
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
ck; [[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — UNCHANGED from M11 after ADR-0021. A heap needs no new assembly."
ck; grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — unchanged from M11, and kdata.o still passes standalone"

# ---------------------------------------------------------------------------
# Step 4 — the two programs and the disk.
# ---------------------------------------------------------------------------
capture PROGS_OUT PROGS_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR/progs"
echo "$PROGS_OUT"
ck; [[ $PROGS_STATUS -eq 0 ]] || fail "build-progs.sh exited $PROGS_STATUS"
PROG_H="$WORKDIR/progs/progH.elf"
PROG_P="$WORKDIR/progs/progP.elf"

DISK_IMG="$WORKDIR/m12.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROG_H" "$PROG_P" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not write the test disk"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['slots'][sys.argv[2]]['lba'])" "$LAYOUT_JSON" "$1"; }
LBA_H=$(lba_of H)
LBA_P=$(lba_of P)
LBA_HEARLY=$(lba_of Hearly)
LBA_HLATE=$(lba_of Hlate)
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
echo "IMAGE: pass  $IMG_BYTES bytes = $(( IMG_BYTES / 512 )) sectors, 4 program slots from 2 ELFs (H at 0x$LBA_H, P at 0x$LBA_P, H-stopped-before at 0x$LBA_HEARLY, H-stopped-after at 0x$LBA_HLATE), generated and re-read from disk"

# ---------------------------------------------------------------------------
# Step 5 — the boots.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" mem="$6" cpu="$7"
  shift 7
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  # GAP-0150: a port that is FREE RIGHT NOW, from the host kernel, rather
  # than a hash of this shell's PID -- which collides with a concurrent
  # harness, with a re-run onto a recycled PID, and with this harness's own
  # previous boot still in TIME_WAIT. All three used to surface as QEMU
  # dying with "Address already in use".
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 420 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m "$mem" \
    -cpu "$cpu" \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" --wait-for 'M1 END\n' --png "$png" --screen-text "$outdir/screen.txt" --keys "$keys" "$@"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# BOOT A — the driven session. `frames` brackets the whole thing, which is the
# leak check; `proc` after it shows the table is empty again.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc run $LBA_H $LBA_P"),ret,wait:40000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,p,r,o,c,ret,wait:800"

SHOT_PNG="$CORE_DIR/build/screenshot-heap.png"
rm -f "$SHOT_PNG"
drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 110 128M qemu64

SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"

if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"
  cp "$SCREEN_TEXT" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL and $EXPECTED_SCREEN — the derived checks below still have to pass"
fi
ck; [[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
ck; [[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# BOOT B — THE AFTER PICTURE. progH stopped at `heapHoldLate`, with every page
# it was ever given still mapped and still written, and progP suspended in a
# yield with its own heap. The dump is anchored at the FIRST `FX` address the
# kernel prints -- slot 0's FPU save area inside `proc_store`, an address the
# KERNEL chose and printed. 131072 quadwords (1MiB) from there covers the
# process table, the kernel's own six page-table frames, both address spaces'
# four table frames each, and the first ~230 heap frames.
# M17 (ADR-0021): `procStore` is a DCDart @bss block, so its symbol is LOCAL and
# kernel.ld's elf32-i386 container discards it. The linked address comes from the
# link map instead -- the same address, stated by the linker itself.
PROC_STORE=$(bssaddr procStore)
ck; [[ -n "$PROC_STORE" ]] || fail "procStore's linked address is not derivable from core/build/kernel.map"
PROC_STORE="0x$PROC_STORE"
# `proc coop`, NOT `proc run`, AND M18 IS WHY (ADR-0022 §2).
#
# This boot needs progH parked at a `jmp .` with progP suspended in a `yield`,
# so that BOTH address spaces are live while the harness walks them out of guest
# physical memory. `proc run` became a PREEMPTIVE session at M18: the parked
# process is taken off the CPU after one quantum, progP resumes and runs to
# completion, and there is no moment at which two heaps are simultaneously live
# and suspended. `proc coop` is the one command that keeps M11's semantics; it
# prints exactly the same lines, so every regex below is unchanged.
HOLD_KEYS="$(typekeys "proc coop $LBA_HLATE $LBA_P"),ret,wait:40000"
# TWO WINDOWS. procStore holds the slot words; the PAGE TABLES the walk below
# needs are frames the allocator handed out, and they are no longer anywhere
# near procStore: the kernel image grew (ADR-0104's platform C modules) and
# allocFrame now starts several megabytes higher, so a single window anchored
# at procStore stopped containing the tables it was being walked over. The
# second window is anchored at the CR3 the kernel PRINTS, so it is still an
# address this harness read out of the machine rather than one it chose.
drive_session "$WORKDIR/late" "$HOLD_KEYS" "$WORKDIR/late/shot.png" "hold-late" 120 128M qemu64 \
  --addr-from-serial 'KPML4 ([0-9A-F]{16})' \
  --monitor-command 'info registers' \
  --monitor-command "xp/131072gx $PROC_STORE" \
  --monitor-command 'xp/131072gx {addr}' \
  --monitor-capture "$WORKDIR/late/monitor.txt"

# BOOT C — THE BEFORE PICTURE. The SAME BINARY with two different bytes changed,
# stopped after `sbrk(0)` and before the first allocation.
# Cooperative for the same reason as the hold-late boot immediately above.
EARLY_KEYS="$(typekeys "proc coop $LBA_HEARLY $LBA_P"),ret,wait:6000"
# TWO WINDOWS. procStore holds the slot words; the PAGE TABLES the walk below
# needs are frames the allocator handed out, and they are no longer anywhere
# near procStore: the kernel image grew (ADR-0104's platform C modules) and
# allocFrame now starts several megabytes higher, so a single window anchored
# at procStore stopped containing the tables it was being walked over. The
# second window is anchored at the CR3 the kernel PRINTS, so it is still an
# address this harness read out of the machine rather than one it chose.
drive_session "$WORKDIR/early" "$EARLY_KEYS" "$WORKDIR/early/shot.png" "hold-early" 130 128M qemu64 \
  --addr-from-serial 'KPML4 ([0-9A-F]{16})' \
  --monitor-command 'info registers' \
  --monitor-command "xp/32768gx $PROC_STORE" \
  --monitor-command 'xp/32768gx {addr}' \
  --monitor-capture "$WORKDIR/early/monitor.txt"

# BOOT D — a drained allocator. `proc run` refuses before any heap exists, which
# is M11's property and must not have regressed.
NOMEM_KEYS="$(typekeys "frames drain"),ret,wait:2500,$(typekeys "proc run $LBA_H $LBA_P"),ret,wait:2000"
drive_session "$WORKDIR/nomem" "$NOMEM_KEYS" "$WORKDIR/nomem/shot.png" "drained" 140 128M qemu64

# ---------------------------------------------------------------------------
# Step 6 — assert.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# RFLAGS.RF NORMALISATION FOR THE WHOLE-CAPTURE COMPARE (GAP-0212).
#
# QEMU sets RFLAGS bit 16 -- RF, the Resume Flag -- non-deterministically on the
# ring-3 register dump. The same two binaries print
#
#     USER CS ... SS ... RFLAGS 0000000000000246 CPL 3
#
# on one boot and RFLAGS 0000000000010246 on the next, with nothing else in the
# capture different. 6b is a byte-for-byte `cmp` of the whole file rather than a
# field parse, so that one bit fails the entire harness.
#
# `--regen` NEVER FIXED THIS, IT RE-FLIPPED THE COIN. Regenerating wrote
# whichever way the bit had landed on that boot into the golden, so the harness
# went on failing about half the time -- in the other direction, which is why it
# looked intermittent rather than wrong.
#
# So the bit is cleared in BOTH the capture and the golden before they are
# compared, and nowhere else in either file. Every other byte survives, INCLUDING
# THE OTHER FIFTEEN HEX DIGITS OF THIS FIELD: IF (0x200), ZF (0x40), PF (0x4) and
# the reserved 0x2 are assertions about the state ring 3 actually ran in.
# Blanking the value or wildcarding the field would pass a kernel that returned
# to user mode with interrupts disabled, which is the exact defect family this
# suite has been repairing -- a check converted into a vacuous one.
#
# 6a is deliberately NOT normalised. It compares the M1 boot prefix against
# m1-interrupts/expected.txt, that prefix contains no RFLAGS token, and that
# golden has to stay byte-exact for the reason 6a exists at all.
# ---------------------------------------------------------------------------
rflags_canon() {
  python3 - "$1" "$2" <<'RFPY'
import re, sys
src = open(sys.argv[1], "rb").read()
n = [0]
def clear_rf(m):
    n[0] += 1
    return m.group(1) + (b"%016X" % (int(m.group(2), 16) & ~0x10000))
out = re.sub(rb"(RFLAGS )([0-9A-F]{16})", clear_rf, src)
open(sys.argv[2], "wb").write(out)
print(n[0])
RFPY
}

# 6a. M1's whole golden must still be a byte-exact PREFIX.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
ck; if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M12 changed M0/M1 serial output. heapInit() must print NOTHING."
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 6b. The whole serial capture, with RFLAGS.RF cleared on both sides (GAP-0212).
CAP_RF=$(rflags_canon "$SERIAL_CAPTURE" "$WORKDIR/serial.rfcanon")
EXP_RF=$(rflags_canon "$EXPECTED_SERIAL" "$WORKDIR/expected.rfcanon")

# NON-VACUITY. If the register dump ever changes shape, the substitution above
# matches nothing, silently stops normalising, and the flake returns with no
# test having gone red to say so. These three lines are what stop this
# normalisation from becoming the thing it exists to prevent.
ck; [[ "$CAP_RF" -ge 1 ]] || fail "the RFLAGS.RF normalisation matched no RFLAGS field in the capture — the ring-3 register dump changed format and this normaliser is now vacuous (GAP-0212)"
ck; [[ "$EXP_RF" -eq "$CAP_RF" ]] || fail "the capture has $CAP_RF RFLAGS field(s), the golden has $EXP_RF — a differing COUNT is a real behavioural difference, not the RF flake (GAP-0212)"
ck; [[ "$(wc -c <"$WORKDIR/serial.rfcanon" | tr -d ' ')" -eq "$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')" ]] || fail "the RFLAGS.RF normalisation changed the capture's byte length — it must rewrite one hex digit in place and touch nothing else (GAP-0212)"
ck; ! grep -q 'RFLAGS' "$EXPECTED_SCREEN" || fail "expected-screen.txt now carries an RFLAGS field. The screen check below is a byte-for-byte cmp too, so the RF flake (GAP-0212) will reappear there. Normalise it the way 6b does."

ck; if ! cmp -s "$WORKDIR/serial.rfcanon" "$WORKDIR/expected.rfcanon"; then
  echo "--- first difference (RFLAGS bit 16 cleared on both sides; every other byte is as captured) ---" >&2
  cmp "$WORKDIR/serial.rfcanon" "$WORKDIR/expected.rfcanon" >&2
  diff <(cat -v "$WORKDIR/expected.rfcanon") <(cat -v "$WORKDIR/serial.rfcanon") | head -60 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte in every bit but RFLAGS.RF, which QEMU sets non-deterministically ($CAP_RF field(s) normalised on each side — GAP-0212)"

# 6c. EVERY EXPECTATION ABOUT THE SESSION COMES OUT OF THE TWO BINARIES.
ck; python3 - "$SERIAL_CAPTURE" "$DERIVE" "$PROG_H" "$PROG_P" <<'PY' || fail "the session capture does not match what the two ELF files say must have happened"
import importlib.util, re, sys

cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("m12_derive", sys.argv[2])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
h = D.Elf(open(sys.argv[3], "rb").read())
p = D.Elf(open(sys.argv[4], "rb").read())
fails = []

base_h = D.heap_base_of(h)
base_p = D.heap_base_of(p)
if base_h != base_p:
    fails.append("the two builds have different heap bases (0x%X, 0x%X)" % (base_h, base_p))
room = D.heap_room(base_h)

# --- the very first sbrk must report the break the ELF implies ---
first = re.search(r"USER WRITE H0 BRK0 ([0-9A-F]{16})", cap)
if not first:
    fails.append("progH never reported its initial break")
elif int(first.group(1), 16) != base_h:
    fails.append("progH's first sbrk(0) returned 0x%X; its own PT_LOADs end at 0x%X. The "
                 "break must start where the program ends, not at a constant."
                 % (int(first.group(1), 16), base_h))

# --- and the kernel's own line for that call must agree ---
k0 = re.search(r"PROC HEAP 00 INC 0{16} OLD ([0-9A-F]{16}) NEW ([0-9A-F]{16}) PAGES ([0-9A-F]{8})", cap)
if not k0:
    fails.append("the kernel never printed a PROC HEAP line for slot 0's sbrk(0)")
else:
    if int(k0.group(1), 16) != base_h or int(k0.group(2), 16) != base_h:
        fails.append("the kernel's first PROC HEAP line reports OLD/NEW 0x%s/0x%s, expected "
                     "0x%X twice" % (k0.group(1), k0.group(2), base_h))
    if int(k0.group(3), 16) != 0:
        fails.append("sbrk(0) allocated %d page(s); it must allocate none"
                     % int(k0.group(3), 16))

# --- the growth ran out at exactly the guard page, and took exactly the number
#     of pages the ELF's own size leaves room for ---
sums = re.findall(r"USER WRITE H(\d) SUM PAGES ([0-9A-F]{8}) ZBAD ([0-9A-F]{8}) "
                  r"BAD ([0-9A-F]{8}) BRK ([0-9A-F]{16})", cap)
if len(sums) != 2:
    fails.append("expected exactly 2 summary lines, got %d" % len(sums))
got = {}
for pid, pages, zbad, bad, brk in sums:
    got[int(pid)] = (int(pages, 16), int(zbad, 16), int(bad, 16), int(brk, 16))
    if int(zbad, 16) != 0:
        fails.append("process %s found %d non-zero word(s) in pages it had just been "
                     "given. A heap page arriving unzeroed is another process's data."
                     % (pid, int(zbad, 16)))
    if int(bad, 16) != 0:
        fails.append("process %s reported %d failed check(s)" % (pid, int(bad, 16)))
if 0 in got:
    pages, _, _, brk = got[0]
    if pages != room:
        fails.append("progH took %d heap pages; the room between its own top (0x%X) and "
                     "the guard page (0x%X) is exactly %d. It must exhaust the window."
                     % (pages, base_h, D.HEAP_TOP, room))
    if brk != D.HEAP_TOP:
        fails.append("progH's final break is 0x%X, not the guard page 0x%X. The window was "
                     "not exhausted to the last page." % (brk, D.HEAP_TOP))
if 1 in got:
    pages, _, _, brk = got[1]
    if pages != 5:
        fails.append("progP took %d heap pages, expected 5 (1 + 3 + 1)" % pages)
    if brk != base_p + 5 * D.PAGE_BYTES:
        fails.append("progP's break is 0x%X, expected 0x%X" % (brk, base_p + 5 * D.PAGE_BYTES))

# --- the three refusals, by value, from ring 3 ---
for tag, want, who in (("ERRNEG", D.HEAP_RET_BADARG, "0"), ("ERRBIG", D.HEAP_RET_BADARG, "0"),
                       ("FULL", D.HEAP_RET_NOSPACE, "0"), ("AGAIN", D.HEAP_RET_NOSPACE, "0"),
                       ("ERRNEG", D.HEAP_RET_BADARG, "1"), ("ERRBIG", D.HEAP_RET_BADARG, "1")):
    m = re.search(r"USER WRITE H%s %s ([0-9A-F]{16})" % (who, tag), cap)
    if not m:
        fails.append("process %s never reported %s" % (who, tag))
    elif int(m.group(1), 16) != want:
        fails.append("process %s's %s returned 0x%s, expected 0x%X" % (who, tag, m.group(1), want))

# --- ...and every one of them came back as a RETURN VALUE, not a fault ---
if "USER FAULT" in cap:
    fails.append("a USER FAULT line appears in a session in which nothing is supposed to "
                 "fault: a refusal that faults is not a refusal")

# --- one line was read by the kernel out of a heap page, which means the
#     kernel's own pointer validator walked the tables and agreed ---
heaptext = h.sym_cstr("msgHeapText")
if isinstance(heaptext, bytes):
    heaptext = heaptext.decode("latin-1")
if ("USER WRITE " + heaptext) not in cap:
    fails.append("the kernel never printed %r, so no heap pointer was ever accepted by "
                 "userOwns/elfOwns" % heaptext)

# --- the exit statuses, computed from the two files ---
exit_base = h.sym_u64("exitBase")
data_word = h.sym_u64("dataWord")
for pid, slot in ((0, "00"), (1, "01")):
    if pid not in got:
        continue
    pages = got[pid][0]
    want = (exit_base + data_word + (pages << 16)) & 0xFFFFFFFFFFFFFFFF
    m = re.search(r"PROC EXIT SLOT %s ID [0-9A-F]{8} CODE ([0-9A-F]{16})" % slot, cap)
    if not m:
        fails.append("no PROC EXIT line for slot %s" % slot)
    elif int(m.group(1), 16) != want:
        fails.append("slot %s exited with 0x%s; exitBase + dataWord + (pages << 16) read "
                     "out of the ELF is 0x%016X" % (slot, m.group(1), want))

# --- THE TEARDOWN COUNT, DERIVED. Every page the process had: its program pages
#     from the ELF, one stack page, its heap pages, and the four table frames. ---
for pid, slot, elf in ((0, "00", h), (1, "01", p)):
    if pid not in got:
        continue
    prog_pages = len(elf.pages())
    want = prog_pages + 1 + got[pid][0] + 4
    m = re.search(r"PROC KILL SLOT %s FREED ([0-9A-F]{8})" % slot, cap)
    if not m:
        fails.append("no PROC KILL line for slot %s" % slot)
    elif int(m.group(1), 16) != want:
        fails.append("slot %s freed %d frames; its ELF has %d program pages, plus 1 stack, "
                     "plus %d heap pages, plus 4 table frames = %d. The heap pages must go "
                     "back with everything else." % (slot, int(m.group(1), 16), prog_pages,
                                                     got[pid][0], want))

# --- THE LEAK CHECK, EXACT. ---
frames = re.findall(r"PMM MANAGED [0-9A-F]{8} FREE ([0-9A-F]{8}) USED ([0-9A-F]{8})", cap)
if len(frames) < 2:
    fails.append("expected at least two `frames` reports, got %d" % len(frames))
elif frames[0] != frames[-1]:
    fails.append("the allocator's free count is %s before the session and %s after it. "
                 "%d heap page(s) and two address spaces went out and did not all come back."
                 % (frames[0][0], frames[-1][0],
                    sum(v[0] for v in got.values())))

# --- the process table is empty again ---
if not re.search(r"PROC CAP [0-9A-F]{8} USED 00000000 LIVE 00000000", cap):
    fails.append("`proc` after the session does not report USED 0 LIVE 0")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (heap base 0x%X derived from progH's own PT_LOADs; %d pages taken by process 0 "
      "and 5 by process 1; final break 0x%X == the guard page; free count %s before and "
      "after)" % (base_h, got[0][0], got[0][3], frames[0][0]))
PY
echo "ASSERT: pass  every number in the session is derived from the two ELF files: the heap base is the top of progH's own PT_LOADs, the window is exhausted to exactly the guard page, both processes report ZERO unzeroed words and ZERO failed checks, all six refusals return the value heap.dart names, the kernel printed a line it read out of a heap page, both exit statuses and both teardown counts are computed from the binaries, and the allocator's free count is identical before and after"

# 6d. THE AFTER PICTURE — the live page tables, both address spaces, read out of
#     guest physical memory with the CPU at CPL 3 inside the held process.
ck; python3 - "$WORKDIR/late/serial.txt" "$WORKDIR/late/monitor.txt" "$DERIVE" \
     "$PROG_H" "$PROG_P" "$WORKDIR/late/facts.json" "$PROC_STORE" <<'PY' || fail "the live page tables in the hold-late boot are not what the two ELFs and the kernel's own report say they must be"
import importlib.util, json, re, sys

ser = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2]).read()
spec = importlib.util.spec_from_file_location("m12_derive", sys.argv[3])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
h = D.Elf(open(sys.argv[4], "rb").read())
p = D.Elf(open(sys.argv[5], "rb").read())
fails = []

regs = D.parse_registers(mon)
if regs.get("CPL") != 3:
    fails.append("CPL is %s, not 3 — the process was not on the CPU when the tables were "
                 "dumped" % regs.get("CPL"))
cr3 = regs.get("CR3")
if cr3 is None:
    fails.append("QEMU's `info registers` did not report CR3")

# THE DUMP IS ANCHORED AT `proc_store` IN THE LINKED IMAGE, AND CROSS-CHECKED
# AGAINST AN ADDRESS THE KERNEL PRINTED. The symbol comes out of kernel.elf; the
# kernel independently printed slot 0's FXSAVE area, which must be that symbol
# plus proc.dart's own `procFxOffset`. Two routes to one number.
store = int(sys.argv[7], 16)
anchor = re.search(r" FX ([0-9A-F]{16})", ser)
if not anchor:
    raise SystemExit("the hold-late boot never printed an FX address")
fx0 = int(anchor.group(1), 16)
if fx0 != store + D.PROC_FX_OFFSET:
    fails.append("the kernel printed slot 0's FXSAVE area at 0x%X; proc_store is at 0x%X in "
                 "the linked image and proc.dart says the FX region starts %d bytes in, "
                 "which is 0x%X" % (fx0, store, D.PROC_FX_OFFSET, store + D.PROC_FX_OFFSET))
kpml4_m = re.search(r"KPML4 ([0-9A-F]{16})", ser)
if not kpml4_m:
    raise SystemExit("the hold-late boot never printed KPML4")
kpml4 = int(kpml4_m.group(1), 16)
mem = (D.Memory()
       .add(store, D.parse_xp(mon, "xp/131072gx 0x%x" % store))
       .add(kpml4, D.parse_xp(mon, "xp/131072gx 0x%016X" % kpml4)))
pml4 = {}
for slot in (0, 1):
    state = D.slot_word(mem, store, slot, D.PROC_SLOT_STATE)
    if state == 0:
        fails.append("process-table slot %d is FREE in the hold-late boot; both processes "
                     "must be alive when the tables are read" % slot)
    pml4[slot] = D.slot_word(mem, store, slot, D.PROC_SLOT_PML4)

tables = {s: D.PageTables(pml4[s], mem) for s in (0, 1)}
if cr3 is not None and cr3 != pml4[0]:
    fails.append("CR3 is 0x%X and slot 0's PML4 is 0x%X — the held process is not the one "
                 "on the CPU" % (cr3, pml4[0]))

# The break each process reached, out of the KERNEL's own slot words.
base = {0: D.heap_base_of(h), 1: D.heap_base_of(p)}
brk = {s: D.slot_word(mem, store, s, D.HEAP_SLOT_BRK) for s in (0, 1)}
kpages = {s: D.slot_word(mem, store, s, D.HEAP_SLOT_PAGES) for s in (0, 1)}
for s in (0, 1):
    kbase = D.slot_word(mem, store, s, D.HEAP_SLOT_BASE)
    if kbase != base[s]:
        fails.append("slot %d's heap base is 0x%X in the process table and 0x%X by the "
                     "ELF's own PT_LOADs" % (s, kbase, base[s]))
    if brk[s] != base[s] + kpages[s] * D.PAGE_BYTES:
        fails.append("slot %d: base 0x%X + %d pages != break 0x%X"
                     % (s, base[s], kpages[s], brk[s]))

# THE WHOLE WINDOW, PAGE BY PAGE, FROM THE LIVE TABLES: the ELF's own pages with
# their own p_flags, one stack page, the heap, the guard page absent, and NOTHING
# ELSE. One audit rather than two, because the program's pages and the heap's are
# in the same page table and a check that ignored one of them would let a spare
# mapping through.
got = {}
for s, label, elf in ((0, "held progH", h), (1, "suspended progP", p)):
    f, pages = D.check_window(tables[s], elf, base[s], brk[s], label)
    fails += f
    got[s] = pages
if got.get(0) is not None and len(got[0]) < 400:
    fails.append("only %d heap pages were found in the held process's tables; the window "
                 "holds ~500 and the program exhausted it" % len(got[0]))

# THE PATTERN, AT THE PHYSICAL FRAME.
sig_h = h.sym_u64("progSig")
sig_p = p.sym_u64("progSig")
if sig_h == sig_p:
    fails.append("the two builds carry the same progSig; 'each read back its own' would be "
                 "vacuous")
fh, checked_h, skipped_h = D.check_heap_contents(mem, tables[0], sig_h, base[0], got.get(0, []))
fp, checked_p, skipped_p = D.check_heap_contents(mem, tables[1], sig_p, base[1], got.get(1, []))
fails += fh + fp
if checked_h < 100:
    fails.append("only %d of progH's heap pages had their contents confirmed in guest "
                 "physical memory (%d frames fell outside the dumped region); the dump is "
                 "too small to make the claim" % (checked_h, skipped_h))
if checked_p != 5:
    fails.append("progP had %d of its 5 heap pages confirmed in guest memory" % checked_p)

# ISOLATION, AT THE SAME VIRTUAL ADDRESS.
fi, shared = D.check_heap_distinct(tables[0], tables[1], base[0], brk[0], base[1], brk[1])
fails += fi
if len(shared) < 5:
    fails.append("the two heaps share only %d virtual address(es); the two builds have "
                 "identical geometry so the first five pages must overlap" % len(shared))

# ...and the kernel is the SAME frame in both, and supervisor-only in both, so
# the isolation above is not an artefact of an empty second address space.
fails += D.check_kernel_shared(tables[0], tables[1], [0x100000, 0x200000, 0x400000])

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

json.dump({"store": store, "pml4": pml4, "base": base, "brk": brk,
           "pages": {s: len(got[s]) for s in got},
           "checked": {"h": checked_h, "p": checked_p},
           "shared": len(shared)}, open(sys.argv[6], "w"))
print("    (%d heap pages in the held process and %d in the suspended one, every one "
      "present+user+writable+NX, nothing above either break, the guard page 0x%X unmapped "
      "in both; %d of progH's and %d of progP's frames re-read in guest RAM holding their "
      "own signatures; %d virtual addresses mapped by both and not one shared frame)"
      % (len(got[0]), len(got[1]), D.HEAP_GUARD_PAGE, checked_h, checked_p, len(shared)))
PY
echo "ASSERT: pass  with progH held after its last allocation and progP suspended in a yield, BOTH address spaces were walked out of guest physical memory from two different PML4 frames: every heap page is present, user-accessible, writable and NX; nothing is mapped above either break; the guard page below the stack is unmapped in both; the pages' contents were re-read at their PHYSICAL frames and hold the signature each program derived from its own .rodata; and every virtual address both heaps map is a different physical frame"

# 6e. THE BEFORE PICTURE, AND IT IS THE SAME BINARY.
ck; python3 - "$WORKDIR/early/serial.txt" "$WORKDIR/early/monitor.txt" "$DERIVE" "$PROG_H" \
     "$PROC_STORE" <<'PY' || fail "the hold-early boot does not show an empty heap"
import importlib.util, re, sys

ser = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2]).read()
spec = importlib.util.spec_from_file_location("m12_derive", sys.argv[3])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
h = D.Elf(open(sys.argv[4], "rb").read())
fails = []

regs = D.parse_registers(mon)
if regs.get("CPL") != 3:
    fails.append("CPL is %s, not 3" % regs.get("CPL"))
store = int(sys.argv[5], 16)
kpml4 = int(re.search(r"KPML4 ([0-9A-F]{16})", ser).group(1), 16)
mem = (D.Memory()
       .add(store, D.parse_xp(mon, "xp/32768gx 0x%x" % store))
       .add(kpml4, D.parse_xp(mon, "xp/32768gx 0x%016X" % kpml4)))

base = D.heap_base_of(h)
pml4 = D.slot_word(mem, store, 0, D.PROC_SLOT_PML4)
tables = D.PageTables(pml4, mem)

# The process is ALIVE and RUNNING -- it printed its break and it is at CPL 3 --
# and its program pages are all there. That is what makes the absence below an
# absence of HEAP rather than an absence of process.
if "USER WRITE H0 BRK0" not in ser:
    fails.append("the held process never got as far as reporting its break, so it is not "
                 "'alive and about to allocate'")
if "PROC HEAP 00 INC 0000000000001000" in ser:
    fails.append("the early-hold variant reached its first real sbrk; the `jmp .` patch did "
                 "not stop it where it was supposed to")
fails += D.check_program_pages(tables, h)
fails += D.check_heap_absent(tables, base, "held-before-sbrk progH")

kbrk = D.slot_word(mem, store, 0, D.HEAP_SLOT_BRK)
kbase = D.slot_word(mem, store, 0, D.HEAP_SLOT_BASE)
kpages = D.slot_word(mem, store, 0, D.HEAP_SLOT_PAGES)
if kbase != base or kbrk != base or kpages != 0:
    fails.append("the kernel's own slot words say base 0x%X, break 0x%X, pages %d before "
                 "the first sbrk; expected 0x%X, 0x%X, 0" % (kbase, kbrk, kpages, base, base))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (the same binary, two bytes different, stopped at CPL 3 after sbrk(0) and before "
      "sbrk(4096): %d program pages present with their own p_flags, and not one page mapped "
      "anywhere between 0x%X and the stack)" % (len(h.pages()), base))
PY
echo "ASSERT: pass  the BEFORE picture — the same binary, stopped two instructions earlier, is alive at CPL 3 with all its program pages and NOT ONE page mapped between the top of its image and its stack. The mapping is shown to be the syscall's work rather than assumed"

# 6f. THE NEGATIVE CONTROL ON THE CHECK ITSELF.
#
# The after-picture assertions must FAIL against the before-picture dump. A
# harness whose page-table walk quietly returned "absent" for everything would
# pass 6d and 6e both; this is what makes that impossible.
ck; if python3 - "$WORKDIR/early/serial.txt" "$WORKDIR/early/monitor.txt" "$DERIVE" "$PROG_H" \
     "$PROC_STORE" >/dev/null 2>&1 <<'PY'
import importlib.util, re, sys
ser = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2]).read()
spec = importlib.util.spec_from_file_location("m12_derive", sys.argv[3])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
h = D.Elf(open(sys.argv[4], "rb").read())
store = int(sys.argv[5], 16)
kpml4 = int(re.search(r"KPML4 ([0-9A-F]{16})", ser).group(1), 16)
mem = (D.Memory()
       .add(store, D.parse_xp(mon, "xp/32768gx 0x%x" % store))
       .add(kpml4, D.parse_xp(mon, "xp/32768gx 0x%016X" % kpml4)))
base = D.heap_base_of(h)
tables = D.PageTables(D.slot_word(mem, store, 0, D.PROC_SLOT_PML4), mem)
# The AFTER expectation, applied to the BEFORE dump: ~500 pages of heap.
f, pages = D.check_window(tables, h, base, D.HEAP_TOP, "negative control")
sys.exit(0 if not f and len(pages) > 400 else 1)
PY
then
  fail "negative control — the after-picture check PASSED against the before-picture dump. The page-table walk is not measuring anything."
fi
echo "ASSERT: pass  negative control — the same walk that finds ~500 user-writable-NX heap pages in the after dump finds none in the before dump, and applying the after expectation to the before dump FAILS as it must"

# 6g. The drained-allocator boot: `proc run` still refuses by name, and the
#     shell is still alive afterwards. M11's property, re-checked because a
#     heap is exactly the kind of change that could have moved an allocation
#     before the refusal.
NOMEM_SER="$WORKDIR/nomem/serial.txt"
ck; grep -q "PROC REFUSED" "$NOMEM_SER" || fail "with every frame drained, proc run did not refuse by name"
ck; grep -q "PROC HEAP" "$NOMEM_SER" && fail "a PROC HEAP line appears in the drained boot — no process was ever created, so nothing can have called sbrk"
ck; tail -c 200 "$NOMEM_SER" | grep -q "oscortex>" || fail "the shell prompt is not the last thing on the drained boot's console"
echo 'ASSERT: pass  with every frame drained, `proc run` refuses by name, no heap is ever created, and the shell survives'

# 6h. The framebuffer and the screenshot.
ck; if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  diff "$EXPECTED_SCREEN" "$SCREEN_TEXT" | head -30 >&2
  fail "the 80x25 VGA text buffer does not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"
ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot at $SHOT_PNG"
ck; head -c 8 "$SHOT_PNG" | cmp -s - <(printf '\x89PNG\r\n\x1a\n') || fail "$SHOT_PNG is not a PNG"
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# GAP-0168: the PASS line below describes work; this refuses to print it
# unless that many checks actually executed. An abort, a loop that iterated
# zero times, a branch not taken or a deleted guard all land here.
require_assertions "$ASSERTIONS_REQUIRED"
echo "M12-heap: PASS — dcc build -> assemble -> link -> clang + x86_64-elf-ld build ONE source TWICE into two freestanding static ELF64 programs with byte-identical segment geometry -> make-image.py writes four program slots (two of them the same binary with two bytes changed) onto a disk -> 8 structural checks (donated .bss UNCHANGED at 9664 and externs UNCHANGED at $EXTERN_COUNT, so a heap needed no new mutable state and no new assembly; the storage seam still 3 call sites with heap.dart reaching its state only through procGet/procSet; heapTop, its page index, the guard page and the maximum increment multiplied out against vm.dart's window; derive.py's fourteen constants against heap.dart's; three distinct refusal values all above a floor above the window; heapSbrk's four orderings read out of the source; every refusal value reachable from a return; and 9 @rodata sizes with shellStrHelp UNCHANGED) -> verify-freestanding pass -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; a user process asking the kernel for memory and being given it, taking every page the window has room for, reading every one of them BEFORE writing it and finding it zero, writing a signature derived from its own .rodata and reading it back after later allocations and after a trip through another address space; the kernel itself reading a line out of that heap through its own ring-3 pointer validator; the window exhausted to exactly the guard page below the stack, with a clean error return the program checks, twice, and a normal exit afterwards; a 'negative' increment and an oversized one each refused by their own value; BOTH address spaces walked out of guest physical memory with the CPU at CPL 3, every heap page present+user+writable+NX and nothing mapped above either break; those pages' contents re-read AT THEIR PHYSICAL FRAMES; the two heaps at the same virtual addresses on different frames with the kernel the same frame and supervisor-only in both; the SAME BINARY stopped two instructions earlier showing NOT ONE heap page mapped, and the after-expectation failing against that dump as a negative control; a drained allocator where 'proc run' refuses instead of pretending; and the allocator's free count identical, to the frame, before and after a session that mapped and unmapped over five hundred pages. Screenshot at $SHOT_PNG"
exit 0
