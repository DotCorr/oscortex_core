#!/usr/bin/env bash
# core/tests/conformance/m13-libc/run.sh
#
# Mechanical check of ROADMAP.md's M13 exit criterion: ORDINARY C SOURCE, USING
# A LIBRARY, RUNS ON THIS OPERATING SYSTEM.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# M12 gave a process a way to ask the kernel for pages. What no program had was
# a library: m10's, m11's and m12's test programs each hand-rolled their own
# `int $0x80` stub, their own hex formatter and their own byte loops, and none
# of them could call `malloc`, `printf` or `strcmp` because none of those
# existed anywhere on this machine. M13 adds core/user/libc -- one header and
# four .c files -- and runs a program written the way C is normally written.
#
#   * A REAL ALLOCATOR ON TOP OF A BUMP POINTER. `sbrk` is monotone and never
#     gives anything back (ADR-0016 §4, GAP-0107). `malloc` keeps a first-fit
#     free list over it WITH SPLITTING AND WITH COALESCING, and the program
#     demonstrates all three: a freed block comes back at the same address, two
#     freed neighbours merge into one that satisfies a request neither could,
#     and after everything is freed six fresh allocations land on the same six
#     addresses having taken NOT ONE MORE BYTE from the kernel.
#
#   * THE ADDRESSES ARE DERIVED, NOT OBSERVED. derive.py recomputes where every
#     block must land from `mallocHdrBytes`, `mallocAlign` and `reqSize` -- all
#     three READ OUT OF THE ELF -- and this harness requires the program to have
#     printed exactly those offsets. The total taken from the kernel is derived
#     a SECOND, different way and checked against the KERNEL's own
#     `PROC HEAP ... NEW` line, which knows nothing about any allocator.
#
#   * THE NEGATIVE CONTROL IS A SECOND BUILD OF THE SAME SOURCE. progN is progL
#     with `free()` disabled by one `volatile const` word, so the two binaries
#     have byte-identical segment geometry and the same heap base. progL must
#     report REUSE 1 / COALESCE 1 / ROUND2 1 and progN must report 0 / 0 / 0,
#     the two exit statuses must differ by exactly the constant derive.py
#     computes, and progN must take MORE memory from the kernel than progL.
#     Check 6d then runs progL's expectations against progN's transcript and
#     REQUIRES THEM TO FAIL: a reuse check that passed for both would be
#     measuring nothing, which is the exact failure three previous milestones
#     found in their own checks.
#
#   * printf's CONVERSIONS ARE COUNTED. Five are implemented. The program
#     formats all five and four unsupported ones in the same session, and this
#     harness requires the five to be exactly right and each of the four to be
#     the visible marker `%!` -- including a trailing `%` with nothing after it,
#     and including a string too long for this kernel's 128-byte write, which
#     must come back marked `%!OVF` and with a return value of -1.
#
#   * THE COMPILER'S OWN memcpy AND memset. build-progs.sh requires progL.o to
#     have UNDEFINED references to both, emitted by clang -O2 from source that
#     names neither, and requires not one `call` instruction inside any of the
#     five string functions -- which is what would catch LLVM's loop-idiom pass
#     rewriting `memcpy`'s body into a call to `memcpy`.
#
#   * THE KERNEL VALIDATES A malloc'd POINTER. The program copies a message into
#     memory `malloc` gave it and passes that pointer to `write`; `elfOwns`
#     walks the live page tables before believing it, so the line appearing on
#     the console is the kernel confirming the mapping from its own side.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * THIS MILESTONE CHANGES NO KERNEL CODE AT ALL, and the checks below say so
#     rather than the commit message: donated .bss UNCHANGED at 9664, externs
#     UNCHANGED at 58, `shellStrHelp` UNCHANGED at 1871 (no new shell command,
#     so m3-m6's goldens do not move -- GAP-0105's incident, designed around
#     again).
#   * `malloc` NEVER RETURNS MEMORY TO THE KERNEL, because `sbrk` cannot shrink.
#     GAP-0107 item 1 is unchanged; GAP-0111 is this library's own accounting.
#   * There is no `realloc`, no `calloc`, no `open`, no `read`, no `FILE`, no
#     `errno` and no `%u`/`%p`/`%f`/`%ld`. GAP-0112 and GAP-0113 list what is
#     absent, so that "oscortex has a libc now" cannot be read as more than it
#     says.
#   * `heapRetNoMem` is still unreachable (GAP-0108) and the heap's frame
#     zeroing still has no behavioural test (GAP-0109). A library does not
#     change either.
#
# Usage:
#   core/tests/conformance/m13-libc/run.sh
#   ... --regen    rewrite the goldens from this boot (the derived checks below
#                  still have to pass, so a wrong library cannot enshrine itself)
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "M13-libc: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M13-libc: FAIL — $1" >&2; exit 2; }

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
ASSERTIONS_REQUIRED=103


for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m13.XXXXXX")" || setup_error "mktemp failed"
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
ck; [[ -d "$LIBC_DIR" ]] || setup_error "no C library at $LIBC_DIR"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel. UNCHANGED by this milestone, which is itself
# checked below.
# ---------------------------------------------------------------------------
capture BUILD_OUT BUILD_STATUS -- bash "$CORE_DIR/scripts/build-kernel.sh"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

cdefine() {
  # `#define NAME VALUE` out of core/user/libc/oslibc.h, decimal or hex, with an
  # optional UL suffix.
  python3 - "$LIBC_DIR/oslibc.h" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^#define %s\s+(0x[0-9A-Fa-f]+|\d+)U?L?\b" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks.
# ---------------------------------------------------------------------------

# 2a. THE KERNEL DID NOT MOVE. M13 is a userland milestone and this is where
#     that is a measurement rather than a claim in a commit message.
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
# M21 (ADR-0041) added a block AFTER S0's, and it was the LAST one in .bss until
# D4 (ADR-0050) put `wmStore` behind it:
# `shmStore`, 4352 bytes -- 16 global counter words, two 64-byte shared-region
# records, and a 4096-byte BIT-PLANE with one bit per frame in the machine that
# says whether a live region owns that frame. The plane is what makes the guard
# at the top of `freeFrame` O(1) instead of a linear scan on all 32768 calls of
# `frames refill` (`docs/design/memory.md` §2.4).
#
# Subtracted FIRST, before S0's, exactly as M14, M15, M16, M19 and S0 each were
# in turn -- so that every earlier milestone's number continues to mean what it
# meant when it was written. This is the THIRD application of ADR-0033 §6.4's
# correction to ADR-0031 §4.3 rule 5: last is necessary but not sufficient, and
# the previously-last block's own to-the-end measurement is exactly the one a
# new block after it changes. S0's number goes 512 -> 4864 nowhere, because it
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
# it meant when it was written. This is the FOURTH application of ADR-0033 s6.4's
# correction to ADR-0031 s4.3 rule 5: last is necessary but not sufficient, and
# the previously-last block's own to-the-end measurement is exactly the one a new
# block after it changes. M21's number below still reads 4352 for that reason --
# it is now measured to wmStore's START rather than to the end of .bss.
D4_OFF_HEX=$(bssoff wmStore)
ck; [[ -n "$D4_OFF_HEX" ]] || fail "wmStore has no .bss offset in kmain.o -- D4's compositor block (ADR-0050) is missing"
D4_BSS=$(( KDATA_BSS - 16#$D4_OFF_HEX ))
ck; [[ "$D4_BSS" -eq 320 ]] || fail "the bytes from D4's wmStore to the end of .bss are $D4_BSS, expected 320. If that block changed size, change it in ADR-0050, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D4_BSS ))
M21_OFF_HEX=$(bssoff shmStore)
ck; [[ -n "$M21_OFF_HEX" ]] || fail "shmStore has no .bss offset in kmain.o -- M21's shared-memory block (ADR-0041) is missing"
M21_BSS=$(( KDATA_BSS - 16#$M21_OFF_HEX ))
ck; [[ "$M21_BSS" -eq 4352 ]] || fail "the bytes from M21's shmStore to D4's wmStore are $M21_BSS, expected 4352. If that block changed size, change it in ADR-0041, in GAP-0053's running total, and in every harness that subtracts it."
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
ck; [[ "$M15_BSS" -eq 2560 ]] || fail "the donated bytes from M15's file_store to the end of .bss are $M15_BSS, expected 2560 — 1280 at M15, doubled by M16's write path (ADR-0020 §7). If that block changed size again, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M15_BSS ))
# M14 (ADR-0018) added `fat_store`, 1824 bytes, AFTER M13. Subtracted here so
# that M13's own claim -- "a C library is entirely userland" -- still means in
# 2026 what it meant when it was written.
M14_OFF_HEX=$(bssoff fatStore)
ck; [[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
ck; [[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824"
KDATA_BSS=$(( KDATA_BSS - M14_BSS ))
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))   # M17 (ADR-0021): the DCDart half plus the 96 assembly-owned bytes
ck; [[ "$KDATA_BSS" -eq 9728 ]] || fail "the kernel's mutable static storage outside M14's fatStore is $KDATA_BSS bytes, expected 9728 — M11/M12's 9664 plus M18's 64-byte scheduler header (ADR-0022), and not one byte of M13's. A C LIBRARY IS USERLAND. If the kernel needed new mutable state to host one, that is a different milestone and it needs its own ADR."
ck; grep -rq "oslibc" "$CORE_DIR/kernel/" && fail "a kernel source mentions oslibc — the C library must not be reachable from ring 0"
echo "STRUCTURAL: pass  kdata.o donates 9728 bytes of .bss outside M14's fat_store and no kernel source mentions the library — M13 is entirely userland"

# 2b. EVERY SYSCALL NUMBER THE LIBRARY USES IS THE KERNEL'S OWN.
#
# Before this milestone each test program carried its own copy of these five
# numbers. Three copies is three chances for one to drift, and the drift shows
# up as a program that faults rather than as a build error. There is one copy
# now, in oslibc.h, and this is the check that it is the right one.
#
# bash 3.2 COMPATIBILITY (ADR-0028). This was a `declare -A WANT_SYS=(...)`
# literal. `declare -A` is bash 4+ and macOS ships /bin/bash 3.2.57; under it
# the compound assignment treats `[SYS_EXIT]` as an ARITHMETIC subscript and
# aborts on `set -u` before any of the five numbers is compared. This harness
# has `set -uo pipefail` and no `set -e`, so `set -u` was the only thing
# keeping that loud.
#
# Rewritten as the "name const file" triple list that section 2c immediately
# below already uses -- same idiom, same five assertions, same messages, and
# no associative array. The triple order matches 2c's: $1 is the C name, $2
# the DCDart constant, $3 the kernel source file.
for triple in "SYS_EXIT userSysExitNo user.dart" "SYS_WRITE userSysWriteNo user.dart" \
              "SYS_WHO userSysWhoNo user.dart" "SYS_YIELD procSysYieldNo proc.dart" \
              "SYS_SBRK heapSysSbrkNo heap.dart"; do
  set -- $triple
  k=$(dartconst "$2" "$3")
  c=$(cdefine "$1")
  ck; [[ -n "$k" ]] || fail "could not read $2 out of core/kernel/$3"
  ck; [[ -n "$c" ]] || fail "oslibc.h does not define $1"
  ck; [[ "$k" -eq "$c" ]] || fail "oslibc.h has $1 = $c and core/kernel/$3 says $2 = $k"
done
echo "STRUCTURAL: pass  all five syscall numbers in oslibc.h are the kernel's own ($(cdefine SYS_EXIT)/$(cdefine SYS_WRITE)/$(cdefine SYS_WHO)/$(cdefine SYS_YIELD)/$(cdefine SYS_SBRK)), read back out of user.dart, proc.dart and heap.dart"

# 2c. AND SO IS EVERY REFUSAL VALUE AND THE WRITE LIMIT.
for pair in "SBRK_ERR_FLOOR heapRetFloor heap.dart" "SBRK_ENOMEM heapRetNoMem heap.dart" \
            "SBRK_ENOSPACE heapRetNoSpace heap.dart" "SBRK_EBADARG heapRetBadArg heap.dart" \
            "SYS_REFUSED userRefused user.dart" "WRITE_MAX userWriteMax user.dart"; do
  set -- $pair
  k=$(dartconst "$2" "$3")
  c=$(cdefine "$1")
  ck; [[ -n "$k" && -n "$c" ]] || fail "could not compare $1 against $2 in core/kernel/$3"
  ck; [[ "$k" -eq "$c" ]] || fail "oslibc.h has $1 = $c and core/kernel/$3 says $2 = $k. A library that disagrees with the kernel about what a refusal LOOKS LIKE will treat one as an address."
done
PRINTF_MAX=$(cdefine PRINTF_MAX)
WRITE_MAX=$(cdefine WRITE_MAX)
ck; [[ -n "$PRINTF_MAX" && "$PRINTF_MAX" -lt "$WRITE_MAX" ]] \
  || fail "PRINTF_MAX ($PRINTF_MAX) is not below WRITE_MAX ($WRITE_MAX) — printf's overflow marker must still fit inside one write the kernel will accept"
ck; [[ $(( PRINTF_MAX + 5 )) -le "$WRITE_MAX" ]] \
  || fail "PRINTF_MAX + the 5-byte overflow marker is $(( PRINTF_MAX + 5 )), above the kernel's $WRITE_MAX-byte limit: an overflowing printf would be REFUSED instead of printing its marker"
echo "STRUCTURAL: pass  the four sbrk refusal values, the syscall refusal value and the 128-byte write limit in oslibc.h are all the kernel's own, and PRINTF_MAX ($PRINTF_MAX) plus the 5-byte overflow marker still fits inside one legal write"

# 2d. printf IMPLEMENTS EXACTLY FIVE CONVERSIONS, AND HAS AN ELSE THAT MARKS.
#
# The claim this whole milestone rests on is "every unsupported conversion is a
# visible failure". A sixth conversion added without a test, or an `else` that
# fell through silently, would make the claim false while every golden still
# matched. So the set is read out of the source.
ck; python3 - "$LIBC_DIR/printf.c" <<'PY' || fail "printf.c does not implement exactly the five conversions its header promises, with a marking else"
import re, sys
src = open(sys.argv[1]).read()
# S0 (ADR-0033) renamed the native printf to `os_printf` so that a PORT cannot
# bind to it by accident (GAP-0170). The five-conversion promise is unchanged
# and this check is unchanged in substance -- only the symbol it looks for.
body = src[src.index("int os_printf("):]
bad = []
got = set(re.findall(r"k == '(.)'", body))
want = {"%", "c", "s", "d", "x"}
if got != want:
    bad.append("printf.c tests for %s; oslibc.h promises exactly %s"
               % (sorted(got), sorted(want)))
# The final else must emit '%' then '!' and must consume no argument.
tail = body[body.rindex("} else {"):]
if "put(n, '%')" not in tail or "put(n, '!')" not in tail:
    bad.append("printf's final else does not emit the two characters `%!` — an unsupported "
               "conversion would vanish silently, which is the one thing this printf exists "
               "not to do")
if "va_arg" in tail:
    bad.append("printf's final else consumes a varargs argument for a conversion it does not "
               "understand; every later conversion in the same call would be out of step")
# The trailing-`%` branch is separate and must also mark.
if not re.search(r"if \(k == 0\) \{\s*(/\*.*?\*/\s*)?\s*n = put\(n, '%'\);\s*n = put\(n, '!'\);", body, re.S):
    bad.append("a `%` at the very end of the format is not marked `%!`")
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  printf.c tests for exactly %s %d %x %c %% and nothing else, its final else emits \`%!\` and consumes no argument, and a trailing \`%\` is marked too"

# 2e. THE NEGATIVE CONTROL IS A RUNTIME WORD, NOT A #ifdef.
#
# If `free`'s body were removed by the preprocessor the two builds would be
# different sizes, would have different heap bases, and their two transcripts
# could differ for reasons that have nothing to do with `free`. It is one
# `volatile const` load instead, and this is where that stays true.
ck; grep -q 'volatile const unsigned long libcFreeEnabled = LIBC_FREE_ENABLED;' "$LIBC_DIR/malloc.c" \
  || fail "malloc.c does not define libcFreeEnabled as a volatile const word"
ck; grep -qE '^\s*#if(n?def)? .*LIBC_FREE_ENABLED' "$LIBC_DIR/malloc.c" \
  && ! grep -q '#ifndef LIBC_FREE_ENABLED' "$LIBC_DIR/malloc.c" \
  && fail "malloc.c switches on LIBC_FREE_ENABLED with the preprocessor; the control build must differ only in one word of .rodata"
ck; python3 - "$LIBC_DIR/malloc.c" <<'PY' || fail "free() does not consult libcFreeEnabled, so the negative-control build would behave exactly like the real one"
import sys
src = open(sys.argv[1]).read()
body = src[src.index("void free(void *p) {"):]
sys.exit(0 if "libcFreeEnabled" in body and "insertFree" in body else 1)
PY
echo "STRUCTURAL: pass  the negative control is one volatile const word read at runtime by free(), not a preprocessor switch — so both builds have identical geometry"

# 2f. THE LIBRARY IS SELF-CONTAINED AND STANDS ON THE FIVE SYSCALLS.
#
# `malloc` may reach the kernel only through `sbrk` and `printf` only through
# `write`, or the library has more surface than its header admits.
ck; python3 - "$LIBC_DIR" <<'PY' || fail "the library reaches the kernel from somewhere other than syscall.c"
import os, re, sys
d = sys.argv[1]
bad = []
for f in ("malloc.c", "string.c", "printf.c"):
    src = open(os.path.join(d, f)).read()
    if re.search(r'__asm__[^;]*int \$0x80', src) or "__asm__ volatile" in src:
        bad.append("%s contains inline assembly; every syscall must go through syscall.c" % f)
    if re.search(r"\bsys_call\s*\(", src):
        bad.append("%s calls sys_call directly instead of a named wrapper" % f)
src = open(os.path.join(d, "syscall.c")).read()
# The INSTRUCTION, not the prose: this file's own header names it too.
n = len(re.findall(r'__asm__ volatile\("int \$0x80"', src))
if n != 1:
    bad.append("syscall.c has %d `int $0x80` instructions; there must be exactly one" % n)
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  exactly one \`int \$0x80\` in the whole library, in syscall.c, and no other file contains assembly or calls it directly"

# 2g. shellStrHelp UNCHANGED, so m3-m6's goldens do not move (GAP-0105).
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  ck; [[ -n "$got" ]] || fail "$sym not found in kmain.o"
  ck; [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table shellStrHelp 2511
check_table heapStrLine 10
check_table procStrPages 7
echo "STRUCTURAL: pass  shellStrHelp is 2511 bytes — M13 added no shell command; the number is maintained by whoever does (GAP-0115)"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1). 58 externs, unchanged.
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
ck; [[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — UNCHANGED from M11/M12 after ADR-0021"
ck; grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — unchanged from M12, and kdata.o still passes standalone"

# ---------------------------------------------------------------------------
# Step 4 — the library, the two programs, and the disk.
# ---------------------------------------------------------------------------
capture PROGS_OUT PROGS_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR/progs"
echo "$PROGS_OUT"
ck; [[ $PROGS_STATUS -eq 0 ]] || fail "build-progs.sh exited $PROGS_STATUS"
PROG_L="$WORKDIR/progs/progL.elf"
PROG_N="$WORKDIR/progs/progN.elf"

DISK_IMG="$WORKDIR/m13.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROG_L" "$PROG_N" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not write the test disk"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['slots'][sys.argv[2]]['lba'])" "$LAYOUT_JSON" "$1"; }
LBA_L=$(lba_of L)
LBA_N=$(lba_of N)
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
echo "IMAGE: pass  $IMG_BYTES bytes = $(( IMG_BYTES / 512 )) sectors, 2 program slots (progL at 0x$LBA_L, the free()-disabled control progN at 0x$LBA_N), generated and re-read from disk"

# ---------------------------------------------------------------------------
# Step 5 — the boot.
#
# ONE boot, not m12's four. M12 needed three extra ones to read page tables out
# of guest RAM at chosen moments; M13 asserts nothing about page tables that M12
# did not already assert about the same unchanged kernel, and a harness that
# re-proves a neighbour's property at four times the cost is a harness people
# stop running.
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

# `frames` brackets the whole thing, which is the leak check; `proc` after it
# shows the table is empty again.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc run $LBA_L $LBA_N"),ret,wait:12000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,p,r,o,c,ret,wait:800"

SHOT_PNG="$CORE_DIR/build/screenshot-libc.png"
rm -f "$SHOT_PNG"
drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 150 128M qemu64

SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"

if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"
  cp "$SCREEN_TEXT" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL and $EXPECTED_SCREEN — the derived checks below still have to pass"
fi
ck; [[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
ck; [[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# ---------------------------------------------------------------------------
# Step 6 — assert.
# ---------------------------------------------------------------------------

# 6a. M1's whole golden must still be a byte-exact PREFIX.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
ck; if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M13 changed M0/M1 serial output, which a userland library cannot legitimately do"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 6b. The whole serial capture.
ck; if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL_CAPTURE") | head -60 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 6c. EVERY EXPECTATION ABOUT THE SESSION COMES OUT OF THE TWO BINARIES.
ck; python3 "$SCRIPT_DIR/check-session.py" "$SERIAL_CAPTURE" "$DERIVE" "$PROG_L" "$PROG_N" \
        --reuse-ids 0 \
  || fail "the session capture does not match what the two ELF files say must have happened"
echo "ASSERT: pass  every number in the session is derived from the two ELF files: the heap base is the top of progL's own PT_LOADs, all six malloc addresses are recomputed from the allocator's own exported header size and alignment and from the request sizes in .rodata, the total taken from the kernel is derived a second way and cross-checked against the KERNEL's PROC HEAP line, both exit statuses and both teardown counts are computed from the binaries, the five printf conversions are exact and the four unsupported ones are all marked, the over-long line is marked and still fits in one legal write, an oversized malloc returns NULL with heap.dart's own refusal value, the kernel printed a line it read out of a malloc'd buffer for BOTH processes, and the allocator's free count is identical before and after"

# 6d. THE NEGATIVE CONTROL ON THE CHECK ITSELF.
#
# The same checker, told to expect reuse from BOTH processes, must FAIL — because
# progN's `free()` returns immediately and it cannot reuse anything. A reuse
# check that passed here would be a check that passes for a program with no
# `free` at all, which is precisely the shape of the wrong-for-the-right-reason
# bug m10, m11 and m12 each found exactly one of in their own harnesses.
ck; if python3 "$SCRIPT_DIR/check-session.py" "$SERIAL_CAPTURE" "$DERIVE" "$PROG_L" "$PROG_N" \
        --reuse-ids 0,1 >/dev/null 2>&1; then
  fail "negative control — the reuse/coalesce/round-trip checks PASSED when applied to the process whose free() does nothing. They are not measuring anything."
fi
echo "ASSERT: pass  negative control — the same checks that find REUSE 1, COALESCE 1 and ROUND2 1 in the process with a working free() FAIL when applied to the process built without one, and the control build took strictly more memory from the kernel than the real one"

# 6e. The framebuffer and the screenshot.
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
echo "M13-libc: PASS — dcc build -> assemble -> link -> clang builds core/user/libc's FOUR OBJECTS AND ONE PROGRAM SOURCE TWICE into two freestanding static ELF64 executables with byte-identical segment geometry, the second with free() disabled as a negative control -> make-image.py writes two program slots onto a disk -> 7 structural checks (donated .bss UNCHANGED at 9664 and externs UNCHANGED at $EXTERN_COUNT and shellStrHelp UNCHANGED at 1871, because a C library is entirely userland; all eleven numbers in oslibc.h -- five syscall numbers, four sbrk refusal values, the syscall refusal value and the write limit -- read back out of user.dart, proc.dart and heap.dart; PRINTF_MAX plus its overflow marker inside the kernel's own write limit; printf.c implementing exactly five conversions with a marking else that consumes no argument; the control being one volatile const word rather than a preprocessor switch; and exactly one \`int \$0x80\` in the whole library) -> verify-freestanding pass -> ONE real QEMU boot. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; ordinary C compiled at -O2 with SSE on, calling malloc, free, printf, strcpy, strcmp, strlen, memset and a memcpy CLANG ITSELF emitted; six blocks of six different sizes landing on the six addresses derive.py computes from the allocator's exported header size and alignment and the request sizes in .rodata; a freed block coming back at the same address; two freed neighbours merging into one that satisfies a request neither could; everything freed and all six allocated again onto the same six addresses having taken not one more byte from the kernel; the free()-disabled build of the same source taking strictly more and reporting 0 where the real one reports 1, with the harness's own reuse checks REQUIRED to fail against it; five printf conversions exact and four unsupported ones each marked %! including a trailing %; an over-long line marked %!OVF, returning -1, and still inside the kernel's 128-byte write limit; an oversized malloc returning NULL with heap.dart's own refusal value and the program running on; the kernel reading a line out of a malloc'd buffer through its own ring-3 pointer validator for both processes; both teardown counts derived from the ELFs; and the frame allocator's free count identical, to the frame, before and after. Screenshot at $SHOT_PNG"
exit 0
