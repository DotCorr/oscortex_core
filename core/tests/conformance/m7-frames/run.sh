#!/usr/bin/env bash
# core/tests/conformance/m7-frames/run.sh
#
# Mechanical check of ROADMAP.md's M7 exit criterion: the kernel has a PHYSICAL
# MEMORY MANAGER — a bitmap over 4KiB frames, built from the Multiboot memory
# map it has been reading and throwing away since M0, that can hand a frame out
# and take it back.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every subsystem before this one re-derived its results on every use because
# there was nowhere to keep them: the memory map (`mem`), the PCI bus (`pci`),
# every sector `disk read` prints. This is the first thing in the kernel that
# REMEMBERS, and the assertions are about the memory rather than about the
# printing:
#
#   * the bitmap is read out of GUEST PHYSICAL MEMORY with the monitor and
#     compared bit-for-bit against one this harness computes itself;
#   * every allocated frame is proved distinct, in-range and writable;
#   * exhaustion is exact — the drain count equals a number derived from the
#     memory map, and the next allocation must fail;
#   * freeing everything returns the free count to exactly the initial value.
#
# THE EXPECTATION IS DERIVED, NOT TYPED
# ---------------------------------------------------------------------------
# `derive.py` recomputes the bitmap, the free count, the folds and the bounds
# from the boot's own `MB E` memory-map lines plus `__kernel_start` /
# `__kernel_end` read out of `kernel.elf`. `expected.txt` is a byte-exact
# golden AND every number in it is checked against that derivation, which is
# what makes the golden safe to regenerate: **updating expected.txt cannot make
# a wrong allocator pass**, because the derived checks run against the same
# capture. This is m6-disk's discipline (the hexdump expectation is computed by
# the image generator) applied to memory.
#
# One consequence, stated because it will surprise someone: this golden is a
# FUNCTION OF THE KERNEL'S OWN SIZE. The allocator reserves the real image
# extents, so adding code to this kernel changes the free-frame count and moves
# this golden. That is not fragility to work around — it is the reservation
# being real. docs/known-gaps.md GAP-0078.
#
# FOUR BOOTS, EACH MAKING A CLAIM THE OTHERS CANNOT
# ---------------------------------------------------------------------------
#   A  -m 128M   the driven session: report, alloc, five rejected frees, the
#                self-test, the drain, the refill. Serial + framebuffer +
#                PNG + the post-refill bitmap dumped out of guest memory.
#   B  -m 128M   drain only, so the bitmap can be dumped in the DRAINED state
#                and asserted ALL ONES. Session A can only show the restored
#                one; the monitor runs after every keystroke.
#   C  -m 256M   THE BOUND IS LOUD. A machine with more usable RAM than the
#                allocator manages must print `OVER <count> CAPPED` with the
#                exact count, not silently pretend the machine is smaller.
#   D  -m 32M    NEGATIVE CONTROL. Same kernel, same keys, less RAM: the
#                numbers must all change, must match a derivation for 32M, and
#                the 128M derivation must FAIL against them.
#
# Control D is what makes the rest mean anything: it is the boot that proves
# the counts come off the memory map rather than out of a constant compiled
# into the kernel.
#
# `qmp-drive.py` is REUSED from m2-console unchanged — one driver, six
# harnesses now.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m7-frames/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M7-frames: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M7-frames: FAIL — $1" >&2
  exit 2
}

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
ASSERTIONS_REQUIRED=225


for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DERIVE="$SCRIPT_DIR/derive.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
ck; [[ -f "$DERIVE" ]] || setup_error "derivation module not found at $DERIVE"
ck; [[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m7-frames reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
ck; [[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m7.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# `--regen` writes the two goldens from this run instead of asserting them.
# It is NOT a way to make a red run green: every derived check below still has
# to pass, and they run against the same capture. See this file's header.
REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

# ---------------------------------------------------------------------------
# Step 1 — build.
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
capture_log "$BUILD_LOG" BUILD_STATUS -- bash "$CORE_DIR/scripts/build-kernel.sh"
cat "$BUILD_LOG"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS (log above)"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — structural checks (CLAUDE.md: anything checkable without booting
# should be).
# ---------------------------------------------------------------------------

hexnum() { python3 -c "import sys; print(int(sys.argv[1], 16))" "$1"; }

# 2a. DONATED `.bss` GREW FROM 424 TO 5096, AND THIS HARNESS NOW OWNS THE
#     NUMBER.
#
# The total has been asserted exactly since M2 and moved only on purpose:
# 16 (M2) -> 304 (M3) -> 392 (M4) -> 424 (M5) -> 424 (M6) -> 5096 (M7). Each
# time, ownership passes to the harness for the milestone that grew it, so one
# harness owns it and it is the one with a reason.
#
# M7's 4672 bytes are the page allocator's entire state: a 4096-byte frame
# bitmap, 64 bytes of metadata and a 512-byte self-test ledger, in ONE symbol
# behind ONE accessor. docs/known-gaps.md GAP-0053 carries the reasoning; if
# you meant to grow this, say so there, in core/boot/kdata.S's header, and in
# docs/decisions/0011-physical-memory-manager.md.
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
ck; [[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
ck; [[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$DART_BSS
# M8 (ADR-0012) added a block AFTER M7's: `vm_store`, 128 bytes for the
# virtual-memory subsystem. It is SUBTRACTED here rather than folded into the
# total, for the same reason m5-pci and m6-disk subtract `pmm_store`: M7's claim
# was never "the total is 5096", it was "the page allocator cost 4672 bytes and
# everything before it cost 424", and a later milestone must not be able to
# dilute that by growing the total. m8-paging/run.sh owns the 5224 now.
VM_STORE_SIZE=$(bsssize vmStore)
ck; [[ -n "$VM_STORE_SIZE" ]] || fail "vm_store is not in kdata.o — M8's virtual-memory state block is missing"
# M9 (ADR-0013) added a third block after M8's: `user_store` (128 bytes, the
# ring-3 subsystem's state) plus the two asm-owned resume words
# `user_resume_rsp`/`user_resume_ok` (8 each). They are SUBTRACTED here rather
# than folded into the total, for the same reason `vm_store` and `pmm_store`
# are: this milestone's claim is about ITS OWN number, and a later milestone
# must not be able to dilute it by growing the total.
M9_STORE=$(bsssize userStore)
M9_RSP=$(bsssize user_resume_rsp)
M9_OK=$(bsssize user_resume_ok)
ck; [[ -n "$M9_STORE" && -n "$M9_RSP" && -n "$M9_OK" ]] || fail "user_store / user_resume_rsp / user_resume_ok are not all in kdata.o — M9's ring-3 state block is missing"
M9_BSS=$(( M9_STORE + M9_RSP + M9_OK ))
# M10 (ADR-0014) added a fourth block after M9's: `elf_store` (128 bytes, the
# ELF loader's whole state, behind ONE accessor called from ONE function). It is
# SUBTRACTED here rather than folded into this milestone's number, so this
# harness keeps asserting ITS OWN claim exactly as it did before M10 existed --
# the same discipline every earlier harness applies to every later block.
M10_STORE=$(bsssize elfStore)
ck; [[ -n "$M10_STORE" ]] || fail "elf_store is not in kdata.o — M10's ELF-loader state block is missing"
# M11 (ADR-0015) added a fifth block after M10's: `proc_store` (4160 bytes -- an
# 8-word header, four 512-byte process slots, and four 512-byte FXSAVE areas).
# Its `.align 16` is a CORRECTNESS requirement and not hygiene (`fxsave` on a
# misaligned operand is a #GP, not a slow path), and it also inserts 8 bytes of
# padding after `elf_store`, so M11 really costs 4168 bytes and not 4160.
#
# M11's share is therefore measured as EVERYTHING PAST THE END OF M10's BLOCK
# rather than as `proc_store`'s own size: the padding is charged to the
# milestone whose alignment made it necessary, and this harness's own number
# comes out exactly as it did before M11 existed.
M11_ELF_OFF_HEX=$(bssoff elfStore)
ck; [[ -n "$M11_ELF_OFF_HEX" ]] || fail "elf_store has no .bss offset in kdata.o"
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
M21_OFF_HEX=$(bssoff shmStore)
ck; [[ -n "$M21_OFF_HEX" ]] || fail "shmStore has no .bss offset in kmain.o -- M21's shared-memory block (ADR-0041) is missing"
M21_BSS=$(( KDATA_BSS - 16#$M21_OFF_HEX ))
ck; [[ "$M21_BSS" -eq 4352 ]] || fail "the bytes from M21's shmStore to the end of .bss are $M21_BSS, expected 4352. If that block changed size, change it in ADR-0041, in GAP-0053's running total, and in every harness that subtracts it."
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
# M14 (ADR-0018) added a SIXTH block after M11's: `fat_store` (1824 bytes -- 32
# metadata words, a 256-entry cluster chain, one sector buffer and an 8.3 name
# buffer). Its `.align 8` inserts NO padding, because `proc_store` ends at a
# multiple of 16. Measured as everything from `fat_store`'s offset to the end of
# `.bss` and subtracted out below, so that THIS harness's own number and M11's
# both come out exactly as they did before M14 existed.
M14_OFF_HEX=$(bssoff fatStore)
ck; [[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
ck; [[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824. If M14's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
M11_BSS=$(( KDATA_BSS - 16#$M11_ELF_OFF_HEX - M10_STORE - M14_BSS ))
ck; [[ "$M11_BSS" -eq 4232 ]] || fail "the donated bytes past the end of M10's elf_store are $M11_BSS, expected 4232 (M11's proc_store, grown to 4224 by M18's scheduler header (ADR-0022), plus the 8 bytes of padding its .align 16 needs). If M11's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
NON_VM_BSS=$(( KDATA_BSS + ASM_BSS - VM_STORE_SIZE - M9_BSS - M10_STORE - M11_BSS - M14_BSS ))
ck; if [[ "$NON_VM_BSS" -ne 5096 ]]; then
  fail "the kernel holds $(( KDATA_BSS + ASM_BSS )) bytes of mutable static storage, of which $VM_STORE_SIZE are M8's vmStore, leaving $NON_VM_BSS — expected 5096 (424 before M7, plus 4672 for the allocator)."
fi
echo "STRUCTURAL: pass  exactly 5096 bytes of mutable static storage outside M8's page-table block — 424 inherited, 4672 for the page allocator"

# 2b. THE ALLOCATOR'S STATE IS ONE SYMBOL.
PMM_SIZE=$(bsssize pmmStore)
ck; [[ -n "$PMM_SIZE" ]] || fail "pmm_store is not in kdata.o — the allocator's storage block is missing"
ck; [[ "$PMM_SIZE" -eq 4672 ]] || fail "pmm_store is $PMM_SIZE bytes, expected 4672 (4096 bitmap + 64 metadata + 512 ledger)"
echo "STRUCTURAL: pass  pmm_store is one 4672-byte symbol: 4096 bitmap + 64 metadata + 512 ledger"

# 2c. THE STORAGE SEAM IS EXACTLY THREE CALL SITES, AND THIS IS THE CHECK THAT
#     PROTECTS THE MIGRATION.
#
# core/kernel/pmm.dart's design claim is that swapping assembly-donated `.bss`
# for real DCDart mutable statics is a change to three functions. That is only
# true while `Bss.addressOf(pmmStore)` is called from exactly those three functions
# and from nowhere else in the kernel. A fourth call site anywhere is the
# moment the claim stops being true, and it would be invisible in any test that
# only looks at behaviour — so it is checked here.
SEAM_SITES=$(grep -c '^\s*return Bss[.]addressOf(pmmStore)' "$CORE_DIR/kernel/pmm.dart")
ck; [[ "$SEAM_SITES" -eq 3 ]] || fail "Bss.addressOf(pmmStore) is returned from $SEAM_SITES functions in pmm.dart, expected exactly 3 (pmmBitmapBase, pmmMetaBase, pmmLedgerBase). The storage seam is the whole mutable-statics migration plan — see pmm.dart's header."
STRAY=$(grep -n 'Bss[.]addressOf(pmmStore)' "$CORE_DIR/kernel/pmm.dart" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | grep -vE 'final Bss pmmStore = ' | grep -vc 'return Bss[.]addressOf(pmmStore)')
ck; [[ "$STRAY" -eq 0 ]] || fail "pmm.dart has $STRAY call(s) of Bss.addressOf(pmmStore) outside the three seam functions"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "pmm.dart" ]] && continue
  ck; grep -qw 'pmmStore' "$f" && fail "$(basename "$f") references pmmStore — the allocator's storage seam must not leak out of pmm.dart"
done
echo "STRUCTURAL: pass  Bss.addressOf(pmmStore) is called from exactly 3 functions, all in pmm.dart's storage seam, and from no other kernel source"

# 2d. THE IDENTITY MAP AND THE ALLOCATOR'S BOUND ARE THE SAME NUMBER.
#
# boot.S maps MAP_2MIB_PAGES 2MiB pages at 0; pmm.dart manages pmmMaxFrames
# 4KiB frames. If the allocator's bound were the larger of the two it would
# hand out frames nothing maps, and the first write through one would be a page
# fault inside whatever used it rather than a diagnosable allocator bug. Both
# halves are read out of the source and multiplied out.
MAP_PAGES=$(awk -F', *' '/^\.set MAP_2MIB_PAGES/{print $2; exit}' "$CORE_DIR/boot/boot.S")
MAX_FRAMES=$(awk -F'= *' '/^const int pmmMaxFrames/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/pmm.dart")
FRAME_BYTES=$(awk -F'= *' '/^const int pmmFrameBytes/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/pmm.dart")
ck; [[ -n "$MAP_PAGES" && -n "$MAX_FRAMES" && -n "$FRAME_BYTES" ]] || fail "could not read MAP_2MIB_PAGES / pmmMaxFrames / pmmFrameBytes out of the source"
MAPPED=$(( MAP_PAGES * 2 * 1024 * 1024 ))
MANAGED=$(( MAX_FRAMES * FRAME_BYTES ))
ck; [[ "$MAPPED" -eq "$MANAGED" ]] || fail "boot.S identity-maps $MAPPED bytes but the allocator manages $MANAGED — a frame the kernel cannot address is not a frame it can hand out. Raise MAP_2MIB_PAGES and pmmMaxFrames together."
echo "STRUCTURAL: pass  boot.S maps $MAP_PAGES x 2MiB = $MAPPED bytes and the allocator manages $MAX_FRAMES x $FRAME_BYTES = $MANAGED — the same number"

# derive.py restates pmm.dart's constants; they must not drift apart either.
ck; python3 - "$DERIVE" "$MAX_FRAMES" "$FRAME_BYTES" <<'PY' || fail "derive.py's constants do not match pmm.dart's"
import re, sys
src = open(sys.argv[1]).read()
want = {"MAX_FRAMES": int(sys.argv[2]), "FRAME_BYTES": int(sys.argv[3])}
for name, v in want.items():
    m = re.search(r"^%s = (\d+)$" % name, src, re.M)
    if not m or int(m.group(1)) != v:
        sys.exit("derive.py %s is %s, pmm.dart says %d" % (name, m and m.group(1), v))
PY
echo "STRUCTURAL: pass  derive.py's independent copy of the frame geometry matches pmm.dart's"

# 2e. THE KERNEL EXTENTS COME FROM THE LINKER SCRIPT, AND THE BITMAP IS INSIDE
#     THEM.
KSTART=$(x86_64-elf-readelf -sW "$KERNEL_ELF" | awk '$8=="__kernel_start"{print $2; exit}')
KEND=$(x86_64-elf-readelf -sW "$KERNEL_ELF" | awk '$8=="__kernel_end"{print $2; exit}')
# M17 (ADR-0021): `pmmStore` is a DCDart `@bss` block, and a `@bss` symbol is
# LOCAL, which kernel.ld's elf32-i386 container discards. The address is read
# out of the LINK MAP instead — still the linked address, still stated by the
# linker, and now the only place that states it.
PMM_ADDR=$(bssaddr pmmStore)
ck; [[ -n "$KSTART" && -n "$KEND" && -n "$PMM_ADDR" ]] || fail "__kernel_start / __kernel_end / pmmStore are not all resolvable — the linker script did not export the image extents, or kernel.map has no .bss line for kmain.o"
KSTART_D=$(hexnum "$KSTART"); KEND_D=$(hexnum "$KEND"); PMM_D=$(hexnum "$PMM_ADDR")
ck; [[ "$KSTART_D" -eq $((1024*1024)) ]] || fail "__kernel_start is 0x$KSTART, expected 0x100000 (the Multiboot load address in kernel.ld)"
ck; [[ "$KEND_D" -gt "$KSTART_D" ]] || fail "__kernel_end (0x$KEND) is not above __kernel_start (0x$KSTART)"
ck; [[ "$PMM_D" -ge "$KSTART_D" && "$PMM_D" -lt "$KEND_D" ]] || fail "pmmStore (0x$PMM_ADDR) is outside [__kernel_start, __kernel_end) — the allocator's own bitmap would not be covered by the kernel-image reservation, so the allocator could hand out the frame its bitmap lives in"
echo "STRUCTURAL: pass  the image is [0x$KSTART, 0x$KEND) from kernel.ld, and pmmStore (0x$PMM_ADDR) is inside it — the bitmap reserves itself"

# 2f. THE BOUND SURVIVES INTO THE COMPILED CODE.
#
# Same check m6-disk makes on `ataWait`'s poll bound and for the same reason: a
# constant that exists only in the source proves nothing about what runs. LLVM
# may count up to 0x8000 or down from it, so either immediate is accepted; what
# is not accepted is neither.
PMMINIT_DIS=$(x86_64-elf-objdump -d --disassemble=pmmInit "$CORE_DIR/build/kmain.o")
ck; [[ -n "$PMMINIT_DIS" ]] || fail "pmmInit is not in kmain.o — the allocator is not being compiled"
ck; if ! grep -qE '0x8000|0xffff8000|32768' <<<"$PMMINIT_DIS"; then
  echo "$PMMINIT_DIS" >&2
  fail "pmmInit's compiled code carries neither 0x8000 nor its negation, so the frame bound (pmmMaxFrames) is not in the instruction stream"
fi
echo "STRUCTURAL: pass  pmmInit's compiled code carries the 0x8000-frame bound"

# 2g. THE NESTED `while` LOOPS REALLY COMPILED.
#
# This milestone bumped DCDART_PIN.txt to e3cfe18 specifically to get nested
# loop lowering (GAP-0068), and the memory-map walk is a loop inside a loop.
# `dcc` would have REFUSED rather than miscompiled, so this is really a check
# that the pin is what the source expects — but a silent revert to an old
# toolchain would otherwise fail the build with a confusing error rather than
# this one.
#
# M17 (ADR-0021) MOVED THE PIN to `8713298`, DCDart's ADR-0051 (`@bss` mutable
# statics), which is the commit `pmm.dart`'s storage seam is now built against.
# The assertion is a literal, not an ordering, for the reason it always was: a
# git hash carries no order, and the check exists to catch a SILENT REVERT to an
# older toolchain, which an ordering test could not express anyway. Both facts
# the pin is load-bearing for are named so a future bump has to answer to both:
# nested while-loops (e3cfe18, M7) and `@bss` (8713298, M17).
PIN=$(awk '{print $1; exit}' "$CORE_DIR/../DCDART_PIN.txt")
# GAP-0247: a pin assertion that is a literal HERE and a value in
# DCDART_PIN.txt is a two-place edit, and the second place was missed the first
# time it mattered (71cf08f bumped the file to 38f0b06 and left this line at
# 8713298, leaving this harness red on the pristine tree). Moved deliberately
# with the file this time, and the two-place edit no longer stands alone:
# build-kernel.sh now compares DCDART_PIN.txt against the commit the toolchain
# is ACTUALLY on and says so on every build, so a pin that has drifted from the
# compiler is caught by the build rather than only by this literal.
ck; [[ "$PIN" == 02631a77* ]] || fail "DCDART_PIN.txt says $PIN; the tree is built against 02631a77 (DCDart neon-round4) — which is past 8713298 (ADR-0051, @bss, pmm.dart's storage seam — M17) and past e3cfe18 (nested while-loops — M7, GAP-0068), and which adds the three facts THIS bump is load-bearing for: ADR-0069's Pointer/Volatile split (ordinary Pointer<T> is optimizable, so every MMIO and every side-effect-only probe in this kernel must be Volatile<T> — ADR-0044, core/scripts/verify-mmio-volatile.sh), 4e1d571 (-mgeneral-regs-only on freestanding targets, which stopped @bare emitting SSE — the 275-%xmm regression m11-proc catches), and 02631a77 itself (read-only globals pinned via llvm.compiler.used, so a one-byte @rodata table is not folded-then-GlobalDCE'd out of kmain.o — argsStrSp/fbStrBy, m5-pci and m19-argv). All five facts the pin is load-bearing for are named here so a future bump has to answer to all of them."
ck; grep -q 'while (f < lastEx)' "$CORE_DIR/kernel/pmm.dart" || fail "pmm.dart's inner frame loop is gone — if it was decomposed into a helper, the pin bump is no longer justified and GAP-0068 needs updating"
echo "STRUCTURAL: pass  DCDART_PIN.txt is $PIN and pmm.dart's memory-map walk is still a genuine nested loop"

# 2h. EVERY @rodata TABLE IS THE SIZE ITS CALL SITE PASSES.
#
# GAP-0060: a @rodata table carries no length (DCDart ADR-0040), so every byte
# count is a hand-maintained literal. It bit at M4 when shellStrHelp grew and
# its one call site did not, printing 237 bytes of a 395-byte table. M7 adds 52
# tables and grows shellStrHelp again (621 -> 1028), so this is not
# hypothetical for this milestone either.
#
# It bit again here, in a new way: a 53rd table (`pmmStrErrParse`) had no call
# site, so the linker dropped it and this check failed with "not found in
# kmain.o". The table was deleted rather than given a call site. A check that
# only looked at the tables it could find would have missed it.
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  ck; [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M7 depends on was not emitted"
  ck; [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060: the length is a hand-maintained literal)"
}
check_table shellStrHelp 2511  # M10 added `run <lba>`, M11 three `proc` lines, M14 `run <name>` + `fs`/`ls`/`cat`; GAP-0060
check_table pmmStrBase 9
check_table pmmStrStore 7
check_table pmmStrBitmap 8
check_table pmmStrMeta 6
check_table pmmStrLedger 8
check_table pmmStrBound 10
check_table pmmStrFrame 7
check_table pmmStrLimit 7
check_table pmmStrMib 4
check_table pmmStrManaged 12
check_table pmmStrFreeL 6
check_table pmmStrUsedL 6
check_table pmmStrBaseL 10
check_table pmmStrAllocs 11
check_table pmmStrErrorsL 8
check_table pmmStrOverL 6
check_table pmmStrCapped 7
check_table pmmStrAlloc 10
check_table pmmStrFreeCmd 9
check_table pmmStrOk 2
check_table pmmStrFail 4
check_table pmmStrErrAlign 9
check_table pmmStrErrRange 9
check_table pmmStrErrDouble 10
check_table pmmStrErrRsvd 12
check_table pmmStrErrReady 12
check_table pmmStrTest 9
check_table pmmStrTestN 2
check_table pmmStrDist 10
check_table pmmStrRangeL 7
check_table pmmStrRwL 4
check_table pmmStrFreedL 7
check_table pmmStrPass 4
check_table pmmStrRw 7
check_table pmmStrDrain 10
check_table pmmStrTook 5
check_table pmmStrSumL 5
check_table pmmStrXorL 5
check_table pmmStrLowL 4
check_table pmmStrHighL 6
check_table pmmStrTouch 6
check_table pmmStrNextL 5
check_table pmmStrRefill 11
check_table pmmStrGave 5
check_table pmmStrUsage 92   # 67 until the shakedown added `frames leave <n>` on a second line (ADR-0039 §3)
# ...AND IT LISTS THE COMMAND, which is the half a size check cannot make. A
# usage line that grew by 25 bytes of anything would satisfy the number above.
# `frames leave <n>` exists so that `elfErrNoFrames` has a reachable caller
# (ADR-0039 §3); a sub-command that is not in its own family's usage line is
# undiscoverable exactly as one that is not in `help` is (GAP-0115).
ck; python3 - "$CORE_DIR/kernel/pmm.dart" <<'PY' || fail "pmmStrUsage does not list \`frames leave <n>\`, or pmm.dart no longer dispatches it"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"final List<u8> pmmStrUsage = const \[(.*?)\];", src, re.S)
text = bytes(int(x, 16) for x in re.findall(r"u8\(0x([0-9A-Fa-f]{2})\)", m.group(1))).decode("ascii")
fails = []
if "frames leave <n>" not in text:
    fails.append("pmmStrUsage does not mention `frames leave <n>`: %r" % text)
for line in text.rstrip("\n").split("\n"):
    if len(line) > 78:
        fails.append("a usage line is %d columns, and this shell is read on an "
                     "80-column console: %r" % (len(line), line))
if "void shellFramesLeave(" not in src:
    fails.append("shellFramesLeave is gone, so the usage line advertises a "
                 "command that does not exist")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (pmmStrUsage lists five forms on two lines, none over 78 columns)")
PY
check_table pmmStrFreeUsage 44
check_table pmmCmdFrames 6
check_table pmmCmdTest 11
check_table pmmCmdDrain 12
check_table pmmCmdRefill 13
check_table pmmCmdAlloc 5
check_table pmmCmdFree 5
echo "STRUCTURAL: pass  all 52 M7 @rodata tables plus shellStrHelp (621 -> 1028) are exactly the sizes their call sites pass"

# 2i. EVERY FRAME `allocFrame()` HANDS OUT IS ZEROED BEFORE IT IS USED —
#     ACROSS THE WHOLE KERNEL, NOT JUST THE ELF LOADER. GAP-0154.
#
# WHAT THIS CHECK IS AND, MORE IMPORTANTLY, WHAT IT IS NOT.
#
# `allocFrame()` does not zero. It hands back whatever the frame last held, and
# this kernel recycles frames between processes, so a frame that is mapped into
# ring 3 without being zeroed first is a page of some previous program's data,
# user-readable, at an address the new program is guaranteed to look at.
#
# THIS CHECK CANNOT PROVE THAT DOES NOT HAPPEN. It is a SOURCE-SHAPE assertion
# and nothing more: it reads core/kernel/*.dart and requires that every frame
# taken from the allocator is named to `vmZeroFrame` in the same function, or is
# on the exemption list below with a reason. A behavioural test is not available
# — GAP-0094 and GAP-0109 are the accounting: QEMU hands out zeroed guest RAM,
# so on a FIRST allocation the unzeroed frame and the zeroed one are the same
# 4096 bytes and no boot can tell them apart. m12-heap's program reads every
# byte of every heap page before it writes one, which is the one behavioural
# check that is possible here, and it is not this one.
#
# What it DOES buy, and the reason it is worth having anyway: m10-elf has
# asserted this for elf.dart alone since M10, and elf.dart is now three of the
# TWENTY allocFrame() call sites in this kernel. proc.dart's five, user.dart's
# two ring-3 pages and heap.dart's page are all outside it. This is the check
# that fails when the twenty-first call site is added without a zeroing beside
# it — which is exactly how a frame reaches ring 3 dirty.
#
# WHY TWENTY AND NOT SEVENTEEN (M21, ADR-0041, shared memory). `shm.dart` takes
# three frames: the shared window's page table, a region's frame-vector page,
# and each page of a region. ALL THREE ARE ZEROED IN shm.dart ITSELF and NONE IS
# EXEMPTED — the census moved, the rule did not. The third one is the one that
# matters: a region's pages are about to be readable from ring 3 in TWO address
# spaces, so the previous owner's bytes would be reachable by a process that
# never allocated them. `shmSysCreate` zeroes each page BEFORE it is mapped, not
# after, which is `heapSbrk`'s discipline for `heapSbrk`'s reason.
#
# The window's page table is zeroed in `shm.dart` as well as inside
# `vmShmTableInstall`, deliberately: the install zeroes it because a table full
# of allocator litter is 512 mappings the CPU will believe, and the redundant
# line is what keeps this check true for that site without adding a fifth
# delegating exemption.
#
# WHY SEVENTEEN AND NOT NINETEEN (ADR-0034, the launch unification). This census
# was written against nineteen when e1381f8 added it. Unifying the launch path
# deleted elf.dart's own `hdr` and `scratch` frames: loading now goes through
# `procCreate`, which already had that pair, so the duplicates went rather than
# the work. proc.dart still takes `pml4 pdpt pd hdr scratch` and elf.dart is down
# to `frame pt sf`. NOTHING WAS EXEMPTED TO GET HERE — the pairing rule, the
# exemption table and its two delegation re-checks are untouched and still
# enforced against all seventeen; only the census moved. Neither branch could
# see this alone: the nineteen-site check arrived on the milestone line in
# e1381f8, which the launch branch never had.
ck; python3 - "$CORE_DIR/kernel" <<'PYEOF' || fail "a frame from allocFrame() is not zeroed before it is used, or a new call site has appeared with no accounting (GAP-0154)"
import glob, os, re, sys
kdir = sys.argv[1]

# name -> (file, why). Each of these takes a frame and does NOT name it to
# vmZeroFrame in its own function. Every one is here with a reason, and a
# reason that is checkable by reading the function named.
EXEMPT = {
    ("elf.dart", "pt"): "vmProgTableInstall zeroes the page-table frame itself, "
                        "and vm.dart is required below to still do so",
    ("vm.dart", "f"): "vmInit's six frames are zeroed by vmBuild's own loop, "
                      "`vmZeroFrame(vmFrame(i))`, before a single entry is written",
    ("pmm.dart", "a"): "the allocator's own `alloc`, `frames self`, `frames "
                       "drain` and `frames leave <n>` shell commands. Nothing is "
                       "mapped, nothing reaches ring 3, and the drain writes one "
                       "word of its own by hand. `frames leave` (ADR-0039 §3) "
                       "reads nothing at all from the frames it takes: they exist "
                       "to be MISSING from the free pool, which is the whole "
                       "point of a partial drain",
    ("pmm.dart", "next"): "the allocation `frames drain` attempts AFTER exhaustion. "
                          "It is required to be 0 and there is no frame to zero",
}

bad = []
sites = 0
for path in sorted(glob.glob(os.path.join(kdir, "*.dart"))):
    base = os.path.basename(path)
    src = open(path).read()
    # `final u64 x =`, `u64 x =` and a bare re-assignment `x =` all count:
    # the drain loop's second allocFrame() has no declaration in front of it and
    # is still a frame this kernel took.
    for m in re.finditer(r"^\s*(?:final )?(?:u64 )?(\w+) = allocFrame\(\);", src, re.M):
        sites += 1
        name = m.group(1)
        if (base, name) in EXEMPT:
            continue
        if not re.search(r"vmZeroFrame\(%s\);" % re.escape(name), src):
            line = src[:m.start()].count("\n") + 1
            bad.append("%s:%d takes a frame into `%s` and no vmZeroFrame(%s) "
                       "appears anywhere in the file. allocFrame() returns "
                       "whatever the frame last held (GAP-0154); if this frame "
                       "genuinely does not need zeroing, say so in this check's "
                       "exemption table rather than leaving it silent."
                       % (base, line, name, name))

# The exemptions must still be REAL. An entry naming a site that no longer
# exists would silently excuse a future site that happened to reuse the name.
for (base, name) in EXEMPT:
    src = open(os.path.join(kdir, base)).read()
    if not re.search(r"^\s*(?:final )?(?:u64 )?%s = allocFrame\(\);" % re.escape(name),
                     src, re.M):
        bad.append("the exemption for %s's `%s` names a call site that is no "
                   "longer there" % (base, name))

# The two exemptions that delegate must still delegate.
vmsrc = open(os.path.join(kdir, "vm.dart")).read()
if "  vmZeroFrame(ptFrame);" not in vmsrc:
    bad.append("vmProgTableInstall no longer zeroes the page-table frame, and "
               "elf.dart's `pt` is exempted here on the grounds that it does")
if "vmZeroFrame(vmFrame(i));" not in vmsrc:
    bad.append("vmBuild no longer zeroes vmInit's six frames, and vm.dart's `f` "
               "is exempted here on the grounds that it does")

if sites != 20:
    bad.append("there are %d allocFrame() call sites and this check was written "
               "against 20. A new one is not a failure -- an unaccounted one is. "
               "Add it, or its exemption, and move this number." % sites)

for b in bad:
    print("    - " + b, file=sys.stderr)
print("    (%d allocFrame() call sites; %d exempted with a reason)"
      % (sites, len(EXEMPT)))
sys.exit(1 if bad else 0)
PYEOF
echo "STRUCTURAL: pass  all 20 allocFrame() call sites in core/kernel/ are accounted for: each names its frame to vmZeroFrame, or is exempted with a reason that is itself re-checked. SOURCE SHAPE ONLY — QEMU hands out zeroed RAM, so no boot on this machine can tell an unzeroed first allocation from a zeroed one (GAP-0094, GAP-0109, GAP-0154)"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# THREE new externs, 29 -> 32, and each one is named because the count is a
# claim about the design:
#
#   pmmStore      the whole storage seam. One accessor for 4672 bytes.
#   kernel_image_start  } the image extents, from the linker script rather than
#   kernel_image_end    } hardcoded. In boot.S, not kdata.S, so that kdata.o
#                         keeps passing this check standalone (GAP-0056).
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
ck; [[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$CORE_DIR/build/portio.o" "$KERNEL_ELF"'
echo "$VERIFY_OUT"
ck; if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
# M8 (ADR-0012) added TWELVE more, so the raw count is now 44. Subtracted BY
# NAME rather than folded into a new total, the same way the donated-`.bss`
# check above subtracts `vm_store`: M7's claim is about M7's three externs, and
# a later milestone must not be able to move the number that states it.
M8_EXTERNS="cr0_read cr2_read cr3_read paging_install vm_exec_probe vm_exec_ok_addr nx_enabled kernel_text_end kernel_rodata_start kernel_rodata_end kernel_data_start"
M8_PRESENT=0
for sym in $M8_EXTERNS; do
  grep -q "$sym" <<<"$VERIFY_OUT" && M8_PRESENT=$(( M8_PRESENT + 1 ))
done
ck; [[ "$M8_PRESENT" -eq 11 ]] || fail "only $M8_PRESENT of M8's 11 externs are in kmain.o's manifest"
# M9 (ADR-0013) added eight more, and they are subtracted BY NAME for the reason
# the donated-`.bss` check above subtracts M9's blocks: this milestone's claim is
# about its own externs.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\buser_store_addr\b" <<<"$VERIFY_OUT" && fail "user_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static userStore"
M9_EXTERNS="enter_user gdt_base tlb_invlpg tr_read tss_base user_resume_ok_addr user_return"
M9_PRESENT=0
for sym in $M9_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M9_PRESENT=$(( M9_PRESENT + 1 ))
done
# M10 (ADR-0014) added exactly ONE more -- `elfStore`, the ELF loader's
# storage seam -- and it is subtracted here for the reason M9's eight are: this
# harness's claim is about ITS OWN milestone's count, and it must keep meaning
# what it meant before M10 existed.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\belf_store_addr\b" <<<"$VERIFY_OUT" && fail "elf_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static elfStore"
# M11 (ADR-0015) added FIVE more -- `sse_enabled`, `cr4_read`, `fx_save`,
# `fx_restore` and `procStore`. They are subtracted BY NAME for the reason
# M8's twelve, M9's eight and M10's one are: this harness's claim is about ITS
# OWN milestone's count, and it must keep meaning what it meant before M11.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\bproc_store_addr\b" <<<"$VERIFY_OUT" && fail "proc_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static procStore"
M11_EXTERNS="sse_enabled cr4_read fx_save fx_restore"
M11_PRESENT=0
for sym in $M11_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M11_PRESENT=$(( M11_PRESENT + 1 ))
done
ck; [[ "$M11_PRESENT" -eq 4 ]] || fail "only $M11_PRESENT of M11's 4 externs are in kmain.o's manifest ($M11_EXTERNS)"
# M15 (ADR-0019) added exactly ONE: `fileStore`, the file-descriptor
# table's storage seam. Subtracted for the same reason every block above is.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\bfile_store_addr\b" <<<"$VERIFY_OUT" && fail "file_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fileStore"
M15_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M15_PRESENT ))
# M14 (ADR-0018) added exactly ONE: `fatStore`, the filesystem's storage
# seam. Subtracted for the same reason M8's, M9's, M10's and M11's are: this
# harness's claim is about ITS OWN milestone's count.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && fail "fat_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fatStore"
M14_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M11_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M9_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M8_PRESENT ))
# M17 (ADR-0021) deleted 10 `_addr()` accessor externs at or before this
# milestone, because the assembly-donated `.bss` they addressed became DCDart
# `@bss` mutable statics. M6's 29 becomes 20 and M7's own three become two.
# Each deleted name is asserted ABSENT as well as the count being asserted: a
# count alone can be restored by an unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr; do
  ck; grep -q "\\b$gone\\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
ck; [[ "$EXTERN_COUNT" -eq 22 ]] || fail "kmain.o declares $EXTERN_COUNT externs outside M8's eleven, expected 22 (20 from M6 after ADR-0021, plus kernel_image_start and kernel_image_end)"
# M7's three externs became two: `pmm_store_addr` is gone (asserted absent
# above) and the storage it addressed is `pmmStore`, a @bss block in pmm.dart --
# which is asserted to exist, by name, in kmain.o's .bss rather than in its
# extern manifest. That is the migration, stated as two assertions.
for sym in kernel_image_start kernel_image_end; do
  ck; grep -q "$sym" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest"
done
ck; [[ "$(bsssize pmmStore)" == "4672" ]] || fail "pmmStore is not a 4672-byte object in kmain.o's .bss — the allocator's storage did not survive the ADR-0021 migration"
# kdata.o must STILL have no undefined symbols at all — GAP-0056 records that
# as a real property, and it is why the kernel-extent accessors went in boot.S.
ck; grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs — something in it now references an outside symbol (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — 20 from M6 plus exactly two, the third having become the @bss block pmmStore, and kdata.o still passes standalone"

# ---------------------------------------------------------------------------
# Step 4 — the boots.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" mem="$6"
  shift 6
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
  timeout 300 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m "$mem" \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
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

# The session. Every element makes a specific claim:
#
#   frames        the report, before anything has happened.
#   alloc         one frame. Its address must be the lowest allocatable frame.
#   free 0        the first megabyte is reserved      -> ERR RESERVED
#   free 1001     not frame-aligned                   -> ERR ALIGN
#   free 8000000  frame 32768, past the bound         -> ERR RANGE
#   free 100000   the kernel image's first frame      -> ERR RESERVED
#   free 7fdf000  allocatable, but not allocated      -> ERR DOUBLE
#   free zz       not a hex address                   -> usage, and NO error
#   frames zz     an argument `frames` does not know  -> usage, and NO error
#   frames        five rejections counted, one allocation counted.
#   frames test   64 frames: distinct, in range, written and read back, freed.
#   frames drain  every remaining frame, then the next allocation must fail.
#   alloc         and it does                         -> PMM ALLOC FAIL
#   frames        FREE 0, USED all of them.
#   frames refill everything back                     -> FREE == BASELINE
#   frames        the baseline, restored.
#   clear         blank screen, so the text-buffer golden is a clean dump.
#   frames        the report the screenshot shows.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,a,l,l,o,c,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,e,e,spc,0,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,e,e,spc,1,0,0,1,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,e,e,spc,8,0,0,0,0,0,0,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,e,e,spc,1,0,0,0,0,0,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,e,e,spc,7,f,d,f,0,0,0,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,e,e,spc,z,z,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,spc,z,z,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,spc,t,e,s,t,ret,wait:3000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,spc,d,r,a,i,n,ret,wait:12000"
SESSION_KEYS="$SESSION_KEYS,a,l,l,o,c,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,spc,r,e,f,i,l,l,ret,wait:25000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:600"

SHOT_PNG="$CORE_DIR/build/screenshot-frames.png"
rm -f "$SHOT_PNG"

# The bitmap is dumped from the address the LINKER put pmm_store at, not from
# the address the kernel printed — an independent source for the same fact, and
# the two are compared below. 512 quadwords is the whole 4096-byte bitmap.
BITMAP_CMD="xp/512gx 0x$PMM_ADDR"

drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 20 128M \
  --addr-from-serial 'PMM RW ([0-9A-F]{16}) ' \
  --monitor-command "$BITMAP_CMD" \
  --monitor-command 'xp/1gx {addr}' \
  --monitor-capture "$WORKDIR/session/monitor.txt"

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
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
ck; if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M7 changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 5b. The whole serial capture.
ck; if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL_CAPTURE") | head -40 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 5c. EVERY NUMBER, DERIVED. This is the assertion the milestone exists for.
ck; if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$KSTART" "$KEND" "$WORKDIR/session/monitor.txt" "$PMM_ADDR" <<'PY'
import importlib.util, re, sys

cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
kstart, kend = int(sys.argv[3], 16), int(sys.argv[4], 16)
monitor = open(sys.argv[5], encoding="utf-8").read()
pmm_addr = int(sys.argv[6], 16)

entries = d.parse_mmap(cap)
if len(entries) < 2:
    sys.exit("only %d MB E lines in the capture -- the memory map this whole "
             "derivation rests on is not there" % len(entries))
used, over = d.build(entries, kstart, kend)
free = d.free_frames(used)
baseline = len(free)
fails = []

# --- the four `frames` reports, in order --------------------------------
reports = re.findall(
    r"^PMM BASE ([0-9A-F]{16}) STORE ([0-9A-F]{8}) BITMAP ([0-9A-F]{8}) "
    r"META ([0-9A-F]{8}) LEDGER ([0-9A-F]{8})\n"
    r"PMM BOUND ([0-9A-F]{8}) FRAME ([0-9A-F]{8}) LIMIT ([0-9A-F]{8}) MIB\n"
    r"PMM MANAGED ([0-9A-F]{8}) FREE ([0-9A-F]{8}) USED ([0-9A-F]{8}) "
    r"BASELINE ([0-9A-F]{8})\n"
    r"PMM ALLOCS ([0-9A-F]{16}) ERRORS ([0-9A-F]{8}) OVER ([0-9A-F]{8})"
    r"( CAPPED)?$", cap, re.M)
if len(reports) != 5:
    sys.exit("expected 5 `frames` reports in the session, found %d" % len(reports))
for n, r in enumerate(reports):
    base, store, bm, meta, led = (int(x, 16) for x in r[0:5])
    bound, frame, limit = (int(x, 16) for x in r[5:8])
    managed, freec, usedc, basec = (int(x, 16) for x in r[8:12])
    allocs, errors, overc = int(r[12], 16), int(r[13], 16), int(r[14], 16)
    if base != pmm_addr:
        fails.append("report %d prints PMM BASE %016X but the linker put "
                     "pmm_store at %016X -- the kernel is not reporting the "
                     "storage it is using" % (n, base, pmm_addr))
    if (store, bm, meta, led) != (4672, 4096, 64, 512):
        fails.append("report %d's footprint is %r, expected (4672, 4096, 64, 512)"
                     % (n, (store, bm, meta, led)))
    if (bound, frame, limit) != (d.MAX_FRAMES, d.FRAME_BYTES, 128):
        fails.append("report %d's bound is %r, expected (%d, %d, 128)"
                     % (n, (bound, frame, limit), d.MAX_FRAMES, d.FRAME_BYTES))
    if managed != d.MAX_FRAMES:
        fails.append("report %d manages %d frames, expected %d" % (n, managed, d.MAX_FRAMES))
    if usedc != managed - freec:
        fails.append("report %d says USED %d with FREE %d of %d managed -- "
                     "they do not add up" % (n, usedc, freec, managed))
    if basec != baseline:
        fails.append("report %d's BASELINE is %d, but the memory map and the "
                     "kernel image say %d" % (n, basec, baseline))
    if overc != over:
        fails.append("report %d's OVER is %d, derived %d" % (n, overc, over))
    if (overc > 0) != bool(r[15]):
        fails.append("report %d's CAPPED word and OVER count disagree" % n)

# reports[0] before anything; [1] after one alloc and five rejections;
# [2] after the drain; [3] after the refill; [4] after `clear`.
# M8: `vmInit()` allocates d.VM_FRAMES frames for the kernel's own page tables
# at boot, before the shell exists, so the lifetime ALLOCS counter starts at
# that number rather than at 0. The FREE counts are unaffected -- `build()`
# above already reserves those frames, and `vmInit` re-takes the allocator's
# BASELINE afterwards, so "FREE returns to BASELINE" still means "nothing is
# leaked" rather than "six frames are missing and nobody counted them".
wants = [(baseline, d.VM_FRAMES, 0), (baseline - 1, d.VM_FRAMES + 1, 5),
         (0, None, 5), (baseline, None, 5), (baseline, None, 5)]
for n, (wfree, wallocs, werrors) in enumerate(wants):
    freec = int(reports[n][9], 16)
    allocs = int(reports[n][12], 16)
    errors = int(reports[n][13], 16)
    if freec != wfree:
        fails.append("report %d says FREE %d, expected %d" % (n, freec, wfree))
    if wallocs is not None and allocs != wallocs:
        fails.append("report %d says ALLOCS %d, expected %d" % (n, allocs, wallocs))
    if errors != werrors:
        fails.append("report %d says ERRORS %d, expected %d -- every rejected "
                     "operation must be counted" % (n, errors, werrors))

# --- `alloc` gave the lowest allocatable frame --------------------------
allocs_seen = re.findall(r"^PMM ALLOC ([0-9A-F]{16})$", cap, re.M)
if len(allocs_seen) != 1:
    fails.append("expected exactly one successful `alloc` line, found %d" % len(allocs_seen))
elif int(allocs_seen[0], 16) != free[0] * d.FRAME_BYTES:
    fails.append("`alloc` returned %s but the lowest allocatable frame derived "
                 "from the memory map is %016X"
                 % (allocs_seen[0], free[0] * d.FRAME_BYTES))
if cap.count("PMM ALLOC FAIL\n") != 1:
    fails.append("expected exactly one `PMM ALLOC FAIL` -- the allocation "
                 "attempted after the drain")

# --- the five rejections, each with its own reason ----------------------
for addr, code in (("0000000000000000", "ERR RESERVED"),
                   ("0000000000001001", "ERR ALIGN"),
                   ("0000000008000000", "ERR RANGE"),
                   ("0000000000100000", "ERR RESERVED"),
                   ("0000000007FDF000", "ERR DOUBLE")):
    line = "PMM FREE %s %s\n" % (addr, code)
    if line not in cap:
        fails.append("missing %r -- free() did not reject that address for that "
                     "reason" % line.strip())
if "0000000000100000" and int("100000", 16) // d.FRAME_BYTES < len(used):
    if not used[int("100000", 16) // d.FRAME_BYTES]:
        fails.append("frame 0x100000 is derived as FREE, so `free 100000` "
                     "returning ERR RESERVED would be wrong -- the kernel image "
                     "reservation is not where this harness thinks it is")

# --- the self-test ------------------------------------------------------
m = re.search(r"^PMM TEST N ([0-9A-F]{8}) DISTINCT (OK|FAIL) RANGE (OK|FAIL) "
              r"RW (OK|FAIL) FREED ([0-9A-F]{8}) FREE ([0-9A-F]{8}) "
              r"BASELINE ([0-9A-F]{8})$", cap, re.M)
if not m:
    fails.append("no `PMM TEST` result line in the capture")
else:
    n, dist, rng, rw, freed, freec, basec = m.groups()
    if int(n, 16) != 64:
        fails.append("the self-test took %s frames, expected 64" % n)
    for name, v in (("DISTINCT", dist), ("RANGE", rng), ("RW", rw)):
        if v != "OK":
            fails.append("the self-test's %s check FAILED" % name)
    if int(freed, 16) != 64:
        fails.append("the self-test freed %s of its 64 frames" % freed)
    if int(basec, 16) != baseline:
        fails.append("the self-test's BASELINE is %s, derived %d" % (basec, baseline))
if "PMM TEST PASS\n" not in cap:
    fails.append("the self-test did not report PASS")

# --- the write/read-back, CHECKED FROM OUTSIDE THE KERNEL ---------------
m = re.search(r"^PMM RW ([0-9A-F]{16}) ([0-9A-F]{16})$", cap, re.M)
if not m:
    fails.append("no `PMM RW` witness line -- the write/read-back proof is missing")
else:
    rw_addr, rw_val = int(m.group(1), 16), int(m.group(2), 16)
    if rw_val != (rw_addr ^ 0xA5A5A5A5A5A5A5A5):
        fails.append("the RW witness value %016X is not derived from its own "
                     "address %016X" % (rw_val, rw_addr))
    if rw_addr // d.FRAME_BYTES >= len(used) or used[rw_addr // d.FRAME_BYTES]:
        fails.append("the RW witness frame %016X is not derived as allocatable"
                     % rw_addr)
    # The monitor dumped that address out of guest physical memory.
    blocks = monitor.split("=== ")
    got = None
    for b in blocks:
        if b.startswith("xp/1gx"):
            toks = [t for t in re.findall(r"0x[0-9a-f]+", b)]
            if toks:
                got = int(toks[-1], 16)
    if got is None:
        fails.append("the monitor produced no `xp/1gx` value for the RW address")
    elif got != rw_val:
        fails.append("the kernel says it wrote %016X at %016X; QEMU's own memory "
                     "dump of that address reads %016X" % (rw_val, rw_addr, got))

# --- the drain: exhaustion is EXACT -------------------------------------
m = re.search(r"^PMM DRAIN TOOK ([0-9A-F]{8}) SUM ([0-9A-F]{16}) "
              r"XOR ([0-9A-F]{16})$", cap, re.M)
m2 = re.search(r"^PMM DRAIN LOW ([0-9A-F]{16}) HIGH ([0-9A-F]{16})$", cap, re.M)
m3 = re.search(r"^PMM DRAIN NEXT ([0-9A-F]{16}) FREE ([0-9A-F]{8})$", cap, re.M)
m4 = re.search(r"^PMM DRAIN TOUCH ([0-9A-F]{16}) ([0-9A-F]{16}) (OK|FAIL)$", cap, re.M)
if not (m and m2 and m3 and m4):
    fails.append("the drain did not print all four of its lines")
else:
    # One frame was already held by the earlier `alloc`, so the drain takes
    # every allocatable frame except that one.
    held = free[0]
    drained = [f for f in free if f != held]
    want_sum = sum(drained)
    want_xor = 0
    for f in drained:
        want_xor ^= f
    if int(m.group(1), 16) != len(drained):
        fails.append("the drain took %s frames; the memory map and the kernel "
                     "image say exactly %d were free" % (m.group(1), len(drained)))
    if int(m.group(2), 16) != want_sum:
        fails.append("the drain's SUM is %s, derived %016X -- the set of frames "
                     "handed out is not the set that was free"
                     % (m.group(2), want_sum))
    if int(m.group(3), 16) != want_xor:
        fails.append("the drain's XOR is %s, derived %016X" % (m.group(3), want_xor))
    if int(m2.group(1), 16) != drained[0] * d.FRAME_BYTES:
        fails.append("the drain's LOW is %s, derived %016X"
                     % (m2.group(1), drained[0] * d.FRAME_BYTES))
    if int(m2.group(2), 16) != drained[-1] * d.FRAME_BYTES:
        fails.append("the drain's HIGH is %s, derived %016X"
                     % (m2.group(2), drained[-1] * d.FRAME_BYTES))
    if int(m3.group(1), 16) != 0:
        fails.append("the allocation attempted after exhaustion returned %s "
                     "instead of failing" % m3.group(1))
    if int(m3.group(2), 16) != 0:
        fails.append("FREE is %s after a full drain, expected 0" % m3.group(2))
    # TOUCH: the HIGHEST managed frame is real, mapped, writable RAM.
    t_addr, t_val, t_ok = int(m4.group(1), 16), int(m4.group(2), 16), m4.group(3)
    if t_ok != "OK":
        fails.append("the drain could not write and read back the highest frame "
                     "it handed out -- boot.S's identity map does not reach the "
                     "allocator's bound")
    if t_addr != drained[-1] * d.FRAME_BYTES:
        fails.append("TOUCH wrote to %016X, not the highest drained frame %016X"
                     % (t_addr, drained[-1] * d.FRAME_BYTES))
    if t_val != (t_addr ^ 0xC3C3C3C3C3C3C3C3):
        fails.append("the TOUCH value is not derived from its own address")

# --- the refill: back to the baseline, EXACTLY --------------------------
m = re.search(r"^PMM REFILL GAVE ([0-9A-F]{8}) FREE ([0-9A-F]{8}) "
              r"BASELINE ([0-9A-F]{8}) ERRORS ([0-9A-F]{8}) (OK|FAIL)$", cap, re.M)
if not m:
    fails.append("no `PMM REFILL` line in the capture")
else:
    gave, freec, basec, errs, verdict = m.groups()
    if int(gave, 16) != baseline:
        fails.append("the refill gave back %s frames, derived %d (every "
                     "allocatable frame: the drain took all but one, and `alloc` "
                     "took that one)" % (gave, baseline))
    if int(freec, 16) != baseline or int(basec, 16) != baseline:
        fails.append("after the refill FREE is %s and BASELINE is %s, both "
                     "should be %d" % (freec, basec, baseline))
    if int(errs, 16) != 0:
        fails.append("the refill hit %s errors -- pmmInit's region walk and "
                     "pmmAllocatable's per-frame test disagree about which "
                     "frames are allocatable" % errs)
    if verdict != "OK":
        fails.append("the refill did not report OK")

# --- THE BITMAP ITSELF, READ OUT OF GUEST MEMORY ------------------------
# The strongest assertion available: not a count, not a checksum, the actual
# 32768 bits, compared against 32768 bits this harness computed. The session
# ends after the refill, so the guest's bitmap must equal the one pmmInit
# should have built.
qwords = []
for b in monitor.split("=== "):
    if b.startswith("xp/512gx"):
        for tok in re.findall(r"0x[0-9a-f]{16}", b):
            qwords.append(int(tok, 16))
if len(qwords) != 512:
    fails.append("parsed %d quadwords from the monitor's bitmap dump, expected "
                 "512 (4096 bytes)" % len(qwords))
else:
    got = d.from_qwords(qwords)
    want = d.to_bytes(used)
    if got != want:
        diffs = [i for i in range(len(want)) if got[i] != want[i]]
        first = diffs[0]
        fails.append("the frame bitmap in guest memory differs from the derived "
                     "one in %d of 4096 bytes; first at byte %d (frames %d..%d): "
                     "guest 0x%02X, derived 0x%02X"
                     % (len(diffs), first, first * 8, first * 8 + 7,
                        got[first], want[first]))
    else:
        print("    (4096 bytes of bitmap read out of guest memory at 0x%X, "
              "equal bit-for-bit to the derivation: %d free frames)"
              % (pmm_addr, baseline))

if fails:
    print("m7-frames: derived check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d memory-map entries, %d free frames derived and matched "
      "everywhere)" % (len(entries), baseline))
PY
then
  fail "the numbers the kernel reported are not the numbers the memory map and the kernel's own image extents imply"
fi
echo "ASSERT: pass  every count, address and fold the kernel printed equals one DERIVED from the Multiboot memory map and kernel.elf's own extents — and the 4096-byte bitmap read out of guest memory matches bit-for-bit"

# 5d. The framebuffer (the 80x25 text buffer, read out of guest memory).
ck; if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 5e. The screenshot.
ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
ck; case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG (QEMU's screendump format argument may be unsupported on this build)" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 6 — BOOT B: the bitmap in its DRAINED state.
#
# Session A can only show the bitmap after the refill, because the monitor runs
# once, after every keystroke. This boot stops at the drain so the exhausted
# bitmap can be read out of guest memory and asserted ALL ONES.
#
# THIS IS THE PROOF THAT NO FRAME WAS HANDED OUT TWICE, and it is a proof
# rather than a loose assertion: the drain reports it performed N allocations,
# and every one of the 32768 bits is set afterwards. If any frame had been
# handed out twice, some other frame would still be free and its bit would be
# clear -- there is no way to perform N allocations, leave every bit set, and
# have handed the same frame out twice.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/drained" \
  "f,r,a,m,e,s,ret,wait:600,f,r,a,m,e,s,spc,d,r,a,i,n,ret,wait:12000" \
  "$WORKDIR/drained/shot.png" "drained" 21 128M \
  --addr-from-serial 'PMM DRAIN TOUCH ([0-9A-F]{16}) ' \
  --monitor-command "$BITMAP_CMD" \
  --monitor-command 'xp/1gx {addr}' \
  --monitor-capture "$WORKDIR/drained/monitor.txt"

ck; if ! python3 - "$WORKDIR/drained/serial.txt" "$DERIVE" "$KSTART" "$KEND" "$WORKDIR/drained/monitor.txt" <<'PY'
import importlib.util, re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
used, over = d.build(d.parse_mmap(cap), int(sys.argv[3], 16), int(sys.argv[4], 16))
free = d.free_frames(used)
monitor = open(sys.argv[5], encoding="utf-8").read()
fails = []

m = re.search(r"^PMM DRAIN TOOK ([0-9A-F]{8}) ", cap, re.M)
if not m:
    sys.exit("this boot produced no drain line at all")
if int(m.group(1), 16) != len(free):
    fails.append("the drain took %s frames from an untouched allocator; the "
                 "memory map says exactly %d were free"
                 % (m.group(1), len(free)))

qwords = []
for b in monitor.split("=== "):
    if b.startswith("xp/512gx"):
        for tok in re.findall(r"0x[0-9a-f]{16}", b):
            qwords.append(int(tok, 16))
if len(qwords) != 512:
    sys.exit("parsed %d quadwords from the drained bitmap dump, expected 512"
             % len(qwords))
blob = d.from_qwords(qwords)
clear = [i for i, b in enumerate(blob) if b != 0xFF]
if clear:
    fails.append("after draining every frame, %d bitmap bytes are not 0xFF "
                 "(first at byte %d, frames %d..%d, value 0x%02X) -- either a "
                 "frame was handed out twice and another was skipped, or the "
                 "drain stopped early"
                 % (len(clear), clear[0], clear[0] * 8, clear[0] * 8 + 7,
                    blob[clear[0]]))

# The TOUCH write, confirmed by QEMU rather than by the kernel.
m = re.search(r"^PMM DRAIN TOUCH ([0-9A-F]{16}) ([0-9A-F]{16}) (OK|FAIL)$", cap, re.M)
if not m or m.group(3) != "OK":
    fails.append("the drain's TOUCH of the highest frame did not succeed")
else:
    want = int(m.group(2), 16)
    got = None
    for b in monitor.split("=== "):
        if b.startswith("xp/1gx"):
            toks = re.findall(r"0x[0-9a-f]+", b)
            if toks:
                got = int(toks[-1], 16)
    if got != want:
        fails.append("the kernel wrote %016X into the highest managed frame; "
                     "QEMU's dump of that address reads %s"
                     % (want, "%016X" % got if got is not None else "nothing"))
    if int(m.group(1), 16) != free[-1] * d.FRAME_BYTES:
        fails.append("TOUCH did not write to the highest allocatable frame")

if fails:
    print("m7-frames: drained-state check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d frames allocated, all 32768 bits set, and the top frame at 0x%X "
      "holds the value the kernel wrote there)"
      % (len(free), free[-1] * d.FRAME_BYTES))
PY
then
  fail "the drained bitmap read out of guest memory is not fully allocated, or the top-frame write did not land"
fi
echo "ASSERT: pass  after draining, all 32768 bits of the bitmap are set in guest memory — N allocations and N distinct frames, so no frame was handed out twice — and the highest managed frame holds the value the kernel wrote into it"

# ---------------------------------------------------------------------------
# Step 7 — BOOT C: THE BOUND IS LOUD.
#
# 256MiB of RAM, twice what this allocator manages. It must report the exact
# number of usable frames it is refusing to manage and say CAPPED, rather than
# silently truncating the memory map.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/over" "f,r,a,m,e,s,ret,wait:800" \
  "$WORKDIR/over/shot.png" "over-bound" 22 256M

ck; if ! python3 - "$WORKDIR/over/serial.txt" "$DERIVE" "$KSTART" "$KEND" <<'PY'
import importlib.util, re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
used, over = d.build(d.parse_mmap(cap), int(sys.argv[3], 16), int(sys.argv[4], 16))
free = d.free_frames(used)
if over <= 0:
    sys.exit("this boot was supposed to have MORE usable RAM than the allocator "
             "manages, but the derivation says nothing is over the bound -- the "
             "control is not controlling anything")
m = re.search(r"^PMM ALLOCS [0-9A-F]{16} ERRORS [0-9A-F]{8} OVER ([0-9A-F]{8})"
              r"( CAPPED)?$", cap, re.M)
if not m:
    sys.exit("no `frames` report in the over-bound boot")
if int(m.group(1), 16) != over:
    sys.exit("the kernel reports OVER %s on a 256MiB machine; derived %d (0x%X)"
             % (m.group(1), over, over))
if not m.group(2):
    sys.exit("OVER is non-zero but the line does not say CAPPED -- exceeding the "
             "bound has to be loud, not just a number someone might read")
m2 = re.search(r"^PMM MANAGED ([0-9A-F]{8}) FREE ([0-9A-F]{8}) ", cap, re.M)
if int(m2.group(1), 16) != d.MAX_FRAMES:
    sys.exit("MANAGED moved on a bigger machine; the bound is supposed to be fixed")
if int(m2.group(2), 16) != len(free):
    sys.exit("FREE is %s, derived %d" % (m2.group(2), len(free)))
print("    (256MiB machine: %d frames managed, %d (0x%X) usable frames above "
      "the bound, counted and refused)" % (len(free), over, over))
PY
then
  fail "on a machine with more usable RAM than the allocator manages, the excess was not counted and reported exactly"
fi
echo "ASSERT: pass  on a 256MiB machine the allocator reports the exact number of usable frames above its bound and says CAPPED — the limit is loud, never a silent truncation"

# ---------------------------------------------------------------------------
# Step 8 — BOOT D: NEGATIVE CONTROL. Same kernel, same keys, less RAM.
#
# This is the boot that proves the numbers come off the memory map. If the free
# count were a constant compiled into the kernel — or derived from anything
# other than what the loader said — it would be unchanged here.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/small" "f,r,a,m,e,s,ret,wait:800" \
  "$WORKDIR/small/shot.png" "small-machine" 23 32M

ck; if ! python3 - "$WORKDIR/small/serial.txt" "$SERIAL_CAPTURE" "$DERIVE" "$KSTART" "$KEND" <<'PY'
import importlib.util, re, sys
small = open(sys.argv[1], "rb").read().decode("latin-1")
big = open(sys.argv[2], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[3])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
kstart, kend = int(sys.argv[4], 16), int(sys.argv[5], 16)

used_s, _ = d.build(d.parse_mmap(small), kstart, kend)
used_b, _ = d.build(d.parse_mmap(big), kstart, kend)
free_s, free_b = len(d.free_frames(used_s)), len(d.free_frames(used_b))
if free_s >= free_b:
    sys.exit("the 32MiB machine derives %d free frames and the 128MiB machine "
             "%d -- the control is not a smaller machine" % (free_s, free_b))

m = re.search(r"^PMM MANAGED ([0-9A-F]{8}) FREE ([0-9A-F]{8}) USED ([0-9A-F]{8}) "
              r"BASELINE ([0-9A-F]{8})$", small, re.M)
if not m:
    sys.exit("no `frames` report in the small-machine boot")
got = int(m.group(2), 16)
if got != free_s:
    sys.exit("on a 32MiB machine the kernel reports FREE %s; derived %d"
             % (m.group(2), free_s))
if got == free_b:
    sys.exit("NEGATIVE CONTROL FAILED: the 32MiB machine reports the same free "
             "count as the 128MiB one. The number is not coming from the memory "
             "map.")
if int(m.group(1), 16) != d.MAX_FRAMES:
    sys.exit("MANAGED changed with the machine; the bound is supposed to be fixed")
if int(m.group(3), 16) != d.MAX_FRAMES - got:
    sys.exit("USED and FREE do not add up on the small machine")
print("    (32MiB: %d free frames; 128MiB: %d. The 128MiB expectation fails "
      "against this boot, as it must.)" % (free_s, free_b))
PY
then
  fail "NEGATIVE CONTROL FAILED: the allocator's counts did not follow the machine's memory map"
fi
# And the capture itself must differ from the session golden.
ck; if cmp -s "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a boot on a different machine produced the same serial capture as the session boot"
fi
# WHERE it diverges is itself worth asserting, and this control diverges in a
# DIFFERENT PLACE from m3/m4/m5/m6's controls, on purpose. Those hold the
# machine fixed and change the keystrokes, so they diverge at byte 545 — just
# past M1's golden. This one holds the keystrokes fixed and changes the
# MACHINE, so it must diverge INSIDE the boot-time memory-map report, where the
# loader's own description of the RAM is printed. If it diverged only later,
# the kernel would be reporting a memory map that does not depend on the
# memory, which would invalidate every derived number in this harness.
#
# BSD `cmp` says "char", GNU `cmp` says "byte"; accept either.
SMALL_DIFF=$(cmp "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE '(byte|char) [0-9]+' | head -1)
ck; [[ -n "$SMALL_DIFF" ]] || fail "could not locate where the small-machine capture diverges from the golden, which means cmp reported no difference at all"
SMALL_OFFSET=${SMALL_DIFF##* }
ck; [[ "$SMALL_OFFSET" -le 544 ]] || fail "the 32MiB capture matches M1's entire 544-byte golden, so the boot-time memory-map report did not change with the machine's memory — the map the allocator is built from is not describing this machine"
ck; head -c 15 "$WORKDIR/small/serial.txt" | cmp -s - <(head -c 15 "$EXPECTED_SERIAL") \
  || fail "the 32MiB boot does not even produce the same M0 banner — this is not the same kernel"
echo "ASSERT: pass  negative control — the same kernel (same M0 banner) on a 32MiB machine reports a different, independently derived free count, and its capture diverges from the 128MiB golden at $SMALL_DIFF, inside the boot-time memory-map report where a different machine must show"

# GAP-0168: the PASS line below describes work; this refuses to print it
# unless that many checks actually executed. An abort, a loop that iterated
# zero times, a branch not taken or a deleted guard all land here.
require_assertions "$ASSERTIONS_REQUIRED"
echo "M7-frames: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S + portio.S) -> link -> 8 structural checks (donated .bss 424 -> 5096, pmm_store one 4672-byte symbol, the storage seam exactly 3 call sites, boot.S's identity map == the allocator's bound, derive.py's geometry == pmm.dart's, the image extents from kernel.ld with pmm_store inside them, the 0x8000 bound in the compiled code, 53 @rodata sizes) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 29 + 3, kdata.o still clean standalone) -> FOUR real QEMU boots (-cpu qemu64 -vga std) over QMP. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; every count, address, sum and xor DERIVED from the Multiboot memory map and kernel.elf's own extents rather than typed; 64 frames allocated, proved pairwise distinct, proved inside usable regions and outside the kernel image, written and read back, and all 64 freed; a full drain whose count equals the derived free count exactly and whose next allocation fails; the whole 4096-byte bitmap read out of guest memory and matched bit-for-bit, both after the refill and in the drained state where all 32768 bits are set; the highest managed frame written and confirmed by QEMU's own memory dump; a 256MiB boot that reports the exact number of frames above its bound and says CAPPED; and a 32MiB negative control whose numbers follow the machine rather than the kernel. Screenshot at $SHOT_PNG"
exit 0
