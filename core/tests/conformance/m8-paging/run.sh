#!/usr/bin/env bash
# core/tests/conformance/m8-paging/run.sh
#
# Mechanical check of ROADMAP.md's M8 exit criterion: the kernel builds its own
# page tables, in DCDart, out of frames from the M7 allocator, with REAL
# per-section permissions -- and the hardware enforces them.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every milestone up to M7 ran on `core/boot/boot.S`'s bootstrap identity map:
# one flat 2MiB-page mapping, present and writable, no permissions of any kind,
# in a single `PT_LOAD` with `FLAGS(7)`. `.text` was writable and `.rodata` was
# writable, and a store through a pointer derived from a constant global
# SUCCEEDED SILENTLY. That is docs/known-gaps.md GAP-0050, and this harness is
# what closes it -- not by looking at the program headers, which prove nothing
# on their own, but by making the machine fault.
#
#   * a deliberate write to a `@rodata` table must raise #PF, be reported with
#     the correct CR2 and a decoded error code, and leave the shell alive;
#   * a deliberate instruction fetch from that same page must raise #PF with the
#     instruction-fetch bit set;
#   * the same two operations against a writable page and an executable page
#     must NOT fault -- without which the first two prove nothing;
#   * and the permissions are read out of the LIVE PAGE TABLES in guest physical
#     memory, at the CR3 QEMU reports, walked by `derive.py`'s own
#     implementation of the x86-64 walk -- never from the kernel's own report.
#
# THE EXPECTATION IS DERIVED, NOT TYPED
# ---------------------------------------------------------------------------
# `expected.txt` is a byte-exact golden AND every permission in it is
# independently recomputed by `derive.py` from `kernel.elf`'s section headers
# and from the tables dumped out of guest memory. This is m7-frames' discipline
# applied to the address space instead of to the frame bitmap: **regenerating
# the golden cannot make an unprotected kernel pass**, because the derived
# checks run against the same boot.
#
# FOUR BOOTS, EACH MAKING A CLAIM THE OTHERS CANNOT
# ---------------------------------------------------------------------------
#   A  128M, qemu64          the driven session: the report, both controls,
#                            both deliberate faults, the report again. Serial +
#                            framebuffer + PNG + `info registers` + the whole
#                            24KiB of page tables dumped out of guest memory.
#   B  128M, qemu64,nx=off   NEGATIVE CONTROL 1 -- A CPU WITH NO NX. `vm` must
#                            report `NX 0` and `.rodata` as executable, and
#                            `vmtest nx` must SURVIVE while `vmtest ro` still
#                            faults. This is what proves the fetch fault in boot
#                            A is caused by the NX bit and by nothing else, and
#                            that the kernel reports the machine it is on rather
#                            than the machine it wishes it were on.
#   C  32M, qemu64           NEGATIVE CONTROL 2 -- a different machine. The
#                            address space must still come up (`READY 1`) and
#                            still be W^X, and the capture must differ from the
#                            golden.
#   D  128M, qemu64          W^X SURVIVES THE ALLOCATOR. `frames drain` and
#                            `frames refill` are run BEFORE `vm`: the drain
#                            hands out every free frame and the refill frees
#                            everything allocatable, so if the six page-table
#                            frames were not reserved, this boot would either
#                            hand a live PML4 to `frames test` or free it. The
#                            tables are dumped afterwards and must be intact.
#
# `qmp-drive.py` is REUSED from m2-console unchanged -- one driver, seven
# harnesses now.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m8-paging/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M8-paging: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M8-paging: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DERIVE="$SCRIPT_DIR/derive.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$DERIVE" ]] || setup_error "page-table walker not found at $DERIVE"
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m8-paging reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m8.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# `--regen` writes the two goldens from this run instead of asserting them. It
# is NOT a way to make a red run green: every derived check below still has to
# pass, and they run against the same boot. See this file's header.
REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

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

# The link script no longer produces an RWX segment, so ld's warning about one
# must be GONE. This is the cheapest possible statement of GAP-0050's closure
# and it comes from the linker rather than from us.
if grep -q "LOAD segment with RWX permissions" "$BUILD_LOG"; then
  fail "the linker still warns about an RWX LOAD segment — core/link/kernel.ld's split into three PT_LOADs did not take (GAP-0050)"
fi
echo "STRUCTURAL: pass  the linker no longer warns about an RWX LOAD segment"

# ---------------------------------------------------------------------------
# Step 2 — structural checks (CLAUDE.md: anything checkable without booting
# should be).
# ---------------------------------------------------------------------------

hexnum() { python3 -c "import sys; print(int(sys.argv[1], 16))" "$1"; }

# 2a. THREE SEGMENTS, WITH THREE DIFFERENT SETS OF FLAGS.
#
# This is the half GAP-0050 explicitly said must NOT be done on its own —
# separate segments without page-table enforcement look like protection while
# providing none. It is checked first because it is the cheapest, and the whole
# rest of this harness is the other half.
# `readelf -lW`'s Flg column is "R E" (two fields) for one segment and "R" for
# another, so the row is parsed by fixed COLUMN POSITION rather than by field
# number -- an awk `$7 $8` reads the alignment of the read-only row as its
# flags and silently compares the wrong thing.
PHDRS=$(x86_64-elf-readelf -lW "$KERNEL_ELF" | python3 -c '
import re, sys
rows = []
for line in sys.stdin:
    m = re.match(r"\s+LOAD\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+([RWE ]{3})\s+(\S+)", line)
    if m:
        rows.append(m.group(1).replace(" ", "") + "/" + m.group(2))
print(" ".join(rows))')
PHDR_COUNT=$(wc -w <<<"$PHDRS" | tr -d ' ')
[[ "$PHDR_COUNT" -eq 3 ]] || fail "kernel.elf has $PHDR_COUNT PT_LOAD segments, expected 3 (.text R E, .rodata R, .data+.bss RW) — see core/link/kernel.ld"
[[ "$PHDRS" == "RE/0x1000 R/0x1000 RW/0x1000" ]] || fail "the three PT_LOAD segments are '$PHDRS', expected 'RE/0x1000 R/0x1000 RW/0x1000' — they must be R E, R, RW, each 4KiB-aligned"
echo "STRUCTURAL: pass  kernel.elf has exactly three PT_LOAD segments: R E, R, RW, each 4KiB-aligned"

# Which sections are in which segment. `.text` must not share a segment with
# anything writable, and `.rodata` must be alone.
SEGMAP=$(x86_64-elf-readelf -lW "$KERNEL_ELF" | sed -n '/Section to Segment/,$p')
grep -qE '^ +00 +\.multiboot \.text *$' <<<"$SEGMAP" || fail "segment 0 is not exactly '.multiboot .text' — something else landed on the executable segment: $(grep -E '^ +00 ' <<<"$SEGMAP")"
grep -qE '^ +01 +\.rodata *$' <<<"$SEGMAP" || fail "segment 1 is not exactly '.rodata' — the read-only segment has company: $(grep -E '^ +01 ' <<<"$SEGMAP")"
grep -qE '^ +02 +\.data \.bss *$' <<<"$SEGMAP" || fail "segment 2 is not exactly '.data .bss': $(grep -E '^ +02 ' <<<"$SEGMAP")"
echo "STRUCTURAL: pass  .text is alone with .multiboot on the executable segment, .rodata is alone on the read-only one, and only .data/.bss are writable"

# 2b. THE SECTION BOUNDARIES ARE PAGE-ALIGNED AND DO NOT SHARE PAGES.
#
# The whole mechanism. A page is the unit permissions come in, so if `.text` and
# `.rodata` shared one, that page would need the union of what each needs —
# writable AND executable, in the one place it matters most. All six symbols are
# read out of the ELF, never out of the source.
declare -A SYM
for s in __kernel_start __text_end __rodata_start __rodata_end __data_start __kernel_end; do
  v=$(x86_64-elf-readelf -sW "$KERNEL_ELF" | awk -v n="$s" '$8==n{print $2; exit}')
  [[ -n "$v" ]] || fail "$s is not in kernel.elf — core/link/kernel.ld did not export the section boundaries the page-table builder maps against"
  SYM[$s]=$(hexnum "$v")
done
[[ "${SYM[__kernel_start]}" -eq $((1024*1024)) ]] || fail "__kernel_start is ${SYM[__kernel_start]}, expected 0x100000 (the Multiboot load address). vm.dart refuses to build a map if it is anything else."
for s in __rodata_start __data_start; do
  (( SYM[$s] % 4096 == 0 )) || fail "$s (0x$(printf %X "${SYM[$s]}")) is not 4KiB-aligned — two sections would share a page and could not have different permissions"
done
(( SYM[__kernel_start] < SYM[__text_end] )) || fail "__text_end is not above __kernel_start"
(( SYM[__text_end] <= SYM[__rodata_start] )) || fail "__text_end (0x$(printf %X "${SYM[__text_end]}")) is above __rodata_start — .text spills onto a read-only page"
(( SYM[__rodata_end] <= SYM[__data_start] )) || fail "__rodata_end is above __data_start — .rodata spills onto a writable page"
(( SYM[__data_start] < SYM[__kernel_end] )) || fail "__kernel_end is not above __data_start"
# vm.dart's 4KiB window is 4MiB and it REFUSES to switch if the image outgrows
# it. Checked here so the refusal is a build-time diagnostic rather than a
# silent `READY 0` discovered three boots later.
(( SYM[__kernel_end] <= 4*1024*1024 )) || fail "the kernel image ends at 0x$(printf %X "${SYM[__kernel_end]}"), past vm.dart's 4MiB 4KiB-page window (vmFineBytes). vmInit would refuse to install a map. Raise vmFineBytes and vmFrameCount together."
echo "STRUCTURAL: pass  the six section boundaries from kernel.ld are ordered, page-aligned where permissions change, and the image (0x$(printf %X "${SYM[__kernel_start]}")..0x$(printf %X "${SYM[__kernel_end]}")) fits vm.dart's 4MiB window"

# 2c. DONATED `.bss` GREW FROM 5096 TO 5224, AND THIS HARNESS NOW OWNS THE
#     NUMBER.
#
# 16 (M2) -> 304 (M3) -> 392 (M4) -> 424 (M5) -> 424 (M6) -> 5096 (M7) ->
# 5224 (M8). Each time, ownership passes to the harness for the milestone that
# grew it, and the earlier harnesses keep asserting their own claim by
# SUBTRACTING the blocks that came after theirs. M8's 128 bytes are the
# virtual-memory subsystem's entire state. docs/known-gaps.md GAP-0053.
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
KDATA_BSS=$DART_BSS
# M9 (ADR-0013) added a third block after M8's: `user_store` (128 bytes, the
# ring-3 subsystem's state) plus the two asm-owned resume words
# `user_resume_rsp`/`user_resume_ok` (8 each). They are SUBTRACTED here rather
# than folded into the total, for the same reason `vm_store` and `pmm_store`
# are: this milestone's claim is about ITS OWN number, and a later milestone
# must not be able to dilute it by growing the total.
M9_STORE=$(bsssize userStore)
M9_RSP=$(bsssize user_resume_rsp)
M9_OK=$(bsssize user_resume_ok)
[[ -n "$M9_STORE" && -n "$M9_RSP" && -n "$M9_OK" ]] || fail "user_store / user_resume_rsp / user_resume_ok are not all in kdata.o — M9's ring-3 state block is missing"
M9_BSS=$(( M9_STORE + M9_RSP + M9_OK ))
# M10 (ADR-0014) added a fourth block after M9's: `elf_store` (128 bytes, the
# ELF loader's whole state, behind ONE accessor called from ONE function). It is
# SUBTRACTED here rather than folded into this milestone's number, so this
# harness keeps asserting ITS OWN claim exactly as it did before M10 existed --
# the same discipline every earlier harness applies to every later block.
M10_STORE=$(bsssize elfStore)
[[ -n "$M10_STORE" ]] || fail "elf_store is not in kdata.o — M10's ELF-loader state block is missing"
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
[[ -n "$M11_ELF_OFF_HEX" ]] || fail "elf_store has no .bss offset in kdata.o"
# M19 (ADR-0023) added a block AFTER M16's, and it is the LAST one in .bss:
# `argsStore`, 256 bytes -- eight metadata words, eight per-argument offsets and
# 128 bytes of argument text, which is where a command line is staged before it
# is copied onto the program's own stack page. Subtracted FIRST, before every
# earlier milestone's, so that this harness's own number continues to mean what
# it meant when it was written. Exactly the accounting M14, M15 and M16 each got
# in turn.
# M20 (ADR-0027) added a block AFTER M19's, and it is now the LAST one in .bss:
# `chanStore`, 2624 bytes -- eight global counter words and two 1280-byte channel
# port records, each of which is a 128-byte header, 128 bytes of per-slot lengths
# and 1024 bytes of message ring. Subtracted FIRST, before every earlier
# milestone's, so that this harness's own number continues to mean what it meant
# when it was written. Exactly the accounting M14, M15, M16 and M19 each got in
# turn.
M20_OFF_HEX=$(bssoff chanStore)
[[ -n "$M20_OFF_HEX" ]] || fail "chanStore has no .bss offset in kmain.o -- M20's IPC channel block (ADR-0027) is missing"
M20_BSS=$(( KDATA_BSS - 16#$M20_OFF_HEX ))
[[ "$M20_BSS" -eq 2624 ]] || fail "the bytes from M20's chanStore to the end of .bss are $M20_BSS, expected 2624. If that block changed size, change it in ADR-0027, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M20_BSS ))
M19_OFF_HEX=$(bssoff argsStore)
[[ -n "$M19_OFF_HEX" ]] || fail "argsStore has no .bss offset in kmain.o -- M19's argument block (ADR-0023) is missing"
M19_BSS=$(( KDATA_BSS - 16#$M19_OFF_HEX ))
[[ "$M19_BSS" -eq 256 ]] || fail "the bytes from M19's argsStore to M20's chanStore are $M19_BSS, expected 256. If that block changed size, change it in ADR-0023, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M19_BSS ))
# M15 (ADR-0019) added a block AFTER M14's: `file_store`, 1280 bytes -- 16
# metadata words, five rows of four file descriptors, and a one-sector bounce
# buffer. Subtracted FIRST, before M14's, so that this harness's own milestone's
# number continues to mean in 2026 what it meant when it was written.
M15_OFF_HEX=$(bssoff fileStore)
[[ -n "$M15_OFF_HEX" ]] || fail "file_store has no .bss offset in kdata.o -- M15's file-descriptor block is missing"
M15_BSS=$(( KDATA_BSS - 16#$M15_OFF_HEX ))
[[ "$M15_BSS" -eq 2560 ]] || fail "the donated bytes from M15's file_store to the end of .bss are $M15_BSS, expected 2560 — 1280 at M15, doubled by M16's write path (ADR-0020 §7). If that block changed size again, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M15_BSS ))
# M14 (ADR-0018) added a SIXTH block after M11's: `fat_store` (1824 bytes -- 32
# metadata words, a 256-entry cluster chain, one sector buffer and an 8.3 name
# buffer). Its `.align 8` inserts NO padding, because `proc_store` ends at a
# multiple of 16. Measured as everything from `fat_store`'s offset to the end of
# `.bss` and subtracted out below, so that THIS harness's own number and M11's
# both come out exactly as they did before M14 existed.
M14_OFF_HEX=$(bssoff fatStore)
[[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
[[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824. If M14's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
M11_BSS=$(( KDATA_BSS - 16#$M11_ELF_OFF_HEX - M10_STORE - M14_BSS ))
[[ "$M11_BSS" -eq 4232 ]] || fail "the donated bytes past the end of M10's elf_store are $M11_BSS, expected 4232 (M11's proc_store, grown to 4224 by M18's scheduler header (ADR-0022), plus the 8 bytes of padding its .align 16 needs). If M11's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
M9_BSS=$(( M9_BSS + M10_STORE + M11_BSS + M14_BSS ))
[[ $(( KDATA_BSS + ASM_BSS - M9_BSS )) -eq 5224 ]] || fail "the kernel's mutable static storage is $(( KDATA_BSS + ASM_BSS )) bytes, of which $M9_BSS are M9's ring-3 blocks, leaving $(( KDATA_BSS + ASM_BSS - M9_BSS )) — expected 5224 (5096 through M7, plus 128 for the virtual-memory state). If you meant to grow it, say so in GAP-0053."
echo "STRUCTURAL: pass  exactly 5224 bytes of mutable static storage outside M9's blocks — 5096 inherited, 128 for the address space"

# 2d. THE VM SUBSYSTEM'S STATE IS ONE SYMBOL.
VM_SIZE=$(bsssize vmStore)
[[ -n "$VM_SIZE" ]] || fail "vm_store is not in kdata.o"
[[ "$VM_SIZE" -eq 128 ]] || fail "vm_store is $VM_SIZE bytes, expected 128 (sixteen u64 words)"
echo "STRUCTURAL: pass  vm_store is one 128-byte symbol"

# 2e. THE STORAGE SEAM IS EXACTLY ONE CALL SITE.
#
# The same check m7-frames makes on the allocator's three, and for the same
# reason: core/kernel/vm.dart's claim is that swapping assembly-donated `.bss`
# for real DCDart mutable statics is a change to ONE function. That is only true
# while `Bss.addressOf(vmStore)` is called from that one function and nowhere else, and
# a second call site would be invisible in any test that only looked at
# behaviour. ADR-0011 §0 is the pattern; ADR-0012 §3 restates it.
SEAM_SITES=$(grep -c '^\s*return Bss[.]addressOf(vmStore)' "$CORE_DIR/kernel/vm.dart")
[[ "$SEAM_SITES" -eq 1 ]] || fail "Bss.addressOf(vmStore) is returned from $SEAM_SITES functions in vm.dart, expected exactly 1 (vmMetaBase). The storage seam is the whole mutable-statics migration plan — see vm.dart's header."
STRAY=$(grep -n 'Bss[.]addressOf(vmStore)' "$CORE_DIR/kernel/vm.dart" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | grep -vE 'final Bss vmStore = ' | grep -vc 'return Bss[.]addressOf(vmStore)')
[[ "$STRAY" -eq 0 ]] || fail "vm.dart has $STRAY call(s) of Bss.addressOf(vmStore) outside vmMetaBase"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "vm.dart" ]] && continue
  grep -qw 'vmStore' "$f" && fail "$(basename "$f") references vmStore — the VM's storage seam must not leak out of vm.dart"
done
echo "STRUCTURAL: pass  Bss.addressOf(vmStore) is called from exactly 1 function, in vm.dart's storage seam, and from no other kernel source"

# 2f. THE MAPPED EXTENT AND THE ALLOCATOR'S BOUND ARE THE SAME NUMBER.
#
# m7-frames already asserts boot.S's BOOTSTRAP map against `pmmMaxFrames`. This
# asserts the same thing for the map that is actually installed: a frame the
# allocator hands out that vm.dart does not map is a page fault inside whatever
# first uses it rather than a diagnosable allocator bug.
VM_MAP=$(awk -F'= *' '/^const int vmMapBytes/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/vm.dart")
MAX_FRAMES=$(awk -F'= *' '/^const int pmmMaxFrames/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/pmm.dart")
FRAME_BYTES=$(awk -F'= *' '/^const int pmmFrameBytes/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/pmm.dart")
[[ -n "$VM_MAP" && -n "$MAX_FRAMES" && -n "$FRAME_BYTES" ]] || fail "could not read vmMapBytes / pmmMaxFrames / pmmFrameBytes out of the source"
[[ "$VM_MAP" -eq $(( MAX_FRAMES * FRAME_BYTES )) ]] || fail "vm.dart maps $VM_MAP bytes but the allocator manages $(( MAX_FRAMES * FRAME_BYTES )) — raise vmMapBytes, vmBigLastEx and pmmMaxFrames together"
echo "STRUCTURAL: pass  vm.dart maps $VM_MAP bytes and the allocator manages $(( MAX_FRAMES * FRAME_BYTES )) — the same number"

# The geometry constants have to multiply out against each other, and derive.py
# keeps an independent copy of them that must not drift.
python3 - "$CORE_DIR/kernel/vm.dart" "$DERIVE" <<'PY' || fail "vm.dart's page geometry is internally inconsistent, or derive.py's copy of it has drifted"
import re, sys
src = open(sys.argv[1]).read()
def c(name):
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);$" % name, src, re.M)
    if not m:
        sys.exit("vm.dart has no `const int %s`" % name)
    return int(m.group(1), 0)
page, big, fine, low = c("vmPageBytes"), c("vmBigBytes"), c("vmFineBytes"), c("vmLowBytes")
mapb, pages, first, lastex = c("vmMapBytes"), c("vmFinePages"), c("vmBigFirst"), c("vmBigLastEx")
pci_base, pci_end, entries = c("vmPciBase"), c("vmPciEnd"), c("vmEntries")
frames, shift, bshift = c("vmFrameCount"), c("vmPageShift"), c("vmBigShift")
mask, store, words = c("vmPageMask"), c("vmStoreBytes"), c("vmStoreWords")
bad = []
if 1 << shift != page: bad.append("vmPageShift/vmPageBytes")
if 1 << bshift != big: bad.append("vmBigShift/vmBigBytes")
if mask != page - 1: bad.append("vmPageMask/vmPageBytes")
if fine // page != pages: bad.append("vmFinePages != vmFineBytes/vmPageBytes")
if fine // big != first: bad.append("vmBigFirst != vmFineBytes/vmBigBytes")
if mapb // big != lastex: bad.append("vmBigLastEx != vmMapBytes/vmBigBytes")
if pci_end - pci_base != entries * big: bad.append("the PCI range is not 512 2MiB pages")
if store != words * 8: bad.append("vmStoreBytes != vmStoreWords*8")
# PML4 + PDPT + PD(low) + PD(pci) + one page table per 2MiB of the fine window.
if frames != 4 + fine // big:
    bad.append("vmFrameCount is %d; the map needs 4 + %d = %d frames"
               % (frames, fine // big, 4 + fine // big))
if low > fine: bad.append("the first megabyte is outside the 4KiB window")
d = open(sys.argv[2]).read()
for name, want in (("PAGE_BYTES", page), ("BIG_BYTES", big), ("FINE_BYTES", fine),
                   ("LOW_BYTES", low), ("MAP_BYTES", mapb), ("FRAME_COUNT", frames)):
    m = re.search(r"^%s = (0x[0-9A-Fa-f]+|\d+)$" % name, d, re.M)
    if not m or int(m.group(1), 0) != want:
        bad.append("derive.py %s is %s, vm.dart says %d" % (name, m and m.group(1), want))
if bad:
    sys.exit("; ".join(bad))
print("    (page geometry: %d 4KiB pages + %d 2MiB pages low + %d 2MiB pages PCI, "
      "from %d page-table frames)" % (pages, lastex - first, entries, frames))
PY
echo "STRUCTURAL: pass  vm.dart's page geometry multiplies out against itself and derive.py's independent copy matches"

# 2g. THE PAGE-TABLE FRAME COUNT SURVIVES INTO m7-frames' DERIVATION.
#
# The six frames are taken from the allocator at boot, so M7's free count is six
# lower than it was. m7-frames/derive.py reserves exactly that many; if the two
# numbers ever disagree, m7 would fail with a confusing off-by-six rather than
# this message.
M7_VM=$(awk -F'= *' '/^VM_FRAMES = /{print $2; exit}' "$CORE_DIR/tests/conformance/m7-frames/derive.py")
VM_FRAMES=$(awk -F'= *' '/^const int vmFrameCount/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/vm.dart")
[[ "$M7_VM" == "$VM_FRAMES" ]] || fail "m7-frames/derive.py reserves $M7_VM frames for the page tables but vm.dart takes $VM_FRAMES"
echo "STRUCTURAL: pass  m7-frames' derivation reserves the same $VM_FRAMES page-table frames vm.dart takes"

# 2h. CR0.WP IS SET IN boot.S, AND IT IS HALF THE MILESTONE.
#
# A page-table entry with RW=0 does not stop a ring-0 write unless CR0.WP is
# set. This kernel measured that the hard way: with the three-segment image and
# real tables installed, `vm` reported every `.rodata` page as not-writable and
# `vmtest ro` STILL printed SURVIVED. Boot A below proves it from the register;
# this proves the instruction is in the source, so a revert is caught before a
# boot. GAP-0080.
grep -qE '^\s*orl \$0x80010000, %eax' "$CORE_DIR/boot/boot.S" || fail "core/boot/boot.S no longer sets CR0 bit 16 (WP) alongside bit 31 (PG). Without WP a read-only page-table entry does not stop a supervisor write and this whole milestone is decorative — see GAP-0080."
grep -qE '^\s*orl \$\(1 << 11\), %eax' "$CORE_DIR/boot/boot.S" || fail "core/boot/boot.S no longer sets EFER.NXE (bit 11). A page-table entry with bit 63 set would then be a RESERVED-bit violation rather than a protection."
echo "STRUCTURAL: pass  boot.S sets CR0.WP with PG and EFER.NXE with LME"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# ELEVEN new externs, 32 -> 43 at first and 44 once CR0 had to be read back, and
# each one is named because the count is a claim about the design:
#
#   cr0_read cr2_read cr3_read paging_install   the control registers. DCDart
#                                               cannot execute a privileged
#                                               instruction or read CR2 at all.
#   vm_exec_probe vm_exec_ok_addr               an indirect call, which is a
#                                               function pointer, which DCDart
#                                               does not have.
#   nx_enabled                                  a CPUID answer boot.S recorded.
#   kernel_text_end kernel_rodata_start
#   kernel_rodata_end kernel_data_start         the linker's section boundaries.
#   vmStore                               the whole storage seam.
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$CORE_DIR/build/portio.o" "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
# M9 (ADR-0013) added eight more, and they are subtracted BY NAME for the reason
# the donated-`.bss` check above subtracts M9's blocks: this milestone's claim is
# about its own externs.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\buser_store_addr\b" <<<"$VERIFY_OUT" && fail "user_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static userStore"
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
grep -q "\belf_store_addr\b" <<<"$VERIFY_OUT" && fail "elf_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static elfStore"
# M11 (ADR-0015) added FIVE more -- `sse_enabled`, `cr4_read`, `fx_save`,
# `fx_restore` and `procStore`. They are subtracted BY NAME for the reason
# M8's twelve, M9's eight and M10's one are: this harness's claim is about ITS
# OWN milestone's count, and it must keep meaning what it meant before M11.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bproc_store_addr\b" <<<"$VERIFY_OUT" && fail "proc_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static procStore"
M11_EXTERNS="sse_enabled cr4_read fx_save fx_restore"
M11_PRESENT=0
for sym in $M11_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M11_PRESENT=$(( M11_PRESENT + 1 ))
done
[[ "$M11_PRESENT" -eq 4 ]] || fail "only $M11_PRESENT of M11's 4 externs are in kmain.o's manifest ($M11_EXTERNS)"
# M15 (ADR-0019) added exactly ONE: `fileStore`, the file-descriptor
# table's storage seam. Subtracted for the same reason every block above is.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bfile_store_addr\b" <<<"$VERIFY_OUT" && fail "file_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fileStore"
M15_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M15_PRESENT ))
# M14 (ADR-0018) added exactly ONE: `fatStore`, the filesystem's storage
# seam. Subtracted for the same reason M9's and M11's are: this harness's claim
# is about ITS OWN milestone's count.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && fail "fat_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fatStore"
M14_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M11_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M9_PRESENT ))
# M17 (ADR-0021) deleted 11 `_addr()` accessor externs at or before this
# milestone, because the assembly-donated `.bss` they addressed became DCDart
# `@bss` mutable statics. M7's 32 becomes 22 and M8's own twelve become eleven.
# Each deleted name is asserted ABSENT as well as the count being asserted: a
# count alone can be restored by an unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr vm_store_addr; do
  grep -q "\\b$gone\\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
[[ "$EXTERN_COUNT" -eq 33 ]] || fail "kmain.o declares $EXTERN_COUNT externs outside M9's seven, expected 33 (22 from M7 after ADR-0021, plus M8's eleven)"
for sym in cr0_read cr2_read cr3_read paging_install vm_exec_probe vm_exec_ok_addr \
           nx_enabled kernel_text_end kernel_rodata_start kernel_rodata_end \
           kernel_data_start; do
  grep -q "$sym" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest"
done
# M8's twelfth was `vm_store_addr` (asserted absent above). What it addressed is
# now `vmStore`, a 128-byte @bss block in vm.dart, asserted here by size rather
# than by presence in an extern manifest it is no longer in.
[[ "$(bsssize vmStore)" == "128" ]] || fail "vmStore is not a 128-byte object in kmain.o's .bss — M8's state did not survive the ADR-0021 migration"
# kdata.o must STILL have no undefined symbols at all — GAP-0056 records that as
# a real property, and it is why the section-boundary accessors went in boot.S
# rather than beside the storage they describe.
grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — 32 from M7 plus exactly twelve, and kdata.o still passes standalone"

# 2i. EVERY @rodata TABLE IS THE SIZE ITS CALL SITE PASSES.
#
# GAP-0060: a @rodata table carries no length (DCDart ADR-0040), so every byte
# count is a hand-maintained literal. M8 adds 48 tables and grows shellStrHelp
# again (1028 -> 1155 at M8, 1589 at M9), so this is not hypothetical here
# either.
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M8 depends on was not emitted (a table with no call site is dropped by the linker)"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table shellStrHelp 2224  # M10 added `run <lba>`, M11 three `proc` lines, M14 `run <name>` + `fs`/`ls`/`cat`; GAP-0060
check_table vmStrCr3 7
check_table vmStrPml4 6
check_table vmStrNx 4
check_table vmStrReady 7
check_table vmStrStatus 8
check_table vmStrFrames 10
check_table vmStrSpan 6
check_table vmStrPages 12
check_table vmStr2m 4
check_table vmStrSect 8
check_table vmStrText 8
check_table vmStrRodata 10
check_table vmStrData 8
check_table vmStrLow 7
check_table vmStrHigh 8
check_table vmStrPci 7
check_table vmStrP 3
check_table vmStrW 3
check_table vmStrX 3
check_table vmStrCanary 10
check_table vmStrFaults 10
check_table vmStrCr2 5
check_table vmStrErr 5
check_table vmStrTestRo 16
check_table vmStrTestRoOops 40
check_table vmStrTestNx 16
check_table vmStrTestNxOops 37
check_table vmStrTestRw 16
check_table vmStrTestX 15
check_table vmStrTestUsage 39
check_table vmStrPf 7
check_table vmStrPfPres 7
check_table vmStrPfNotPres 7
check_table vmStrPfWrite 5
check_table vmStrPfRead 4
check_table vmStrPfUser 4
check_table vmStrPfSuper 5
check_table vmStrPfFetch 5
check_table vmStrPfData 4
check_table vmStrPfRsvd 5
check_table vmCanary 8
check_table vmCmdVm 2
check_table vmCmdTestRo 9
check_table vmCmdTestNx 9
check_table vmCmdTestRw 9
check_table vmCmdTestX 8
check_table vmCmdTest 6
check_table vmStrWp 4
echo "STRUCTURAL: pass  all 48 M8 @rodata tables plus shellStrHelp (1028 -> 1155 -> 1871 -> 2147) are exactly the sizes their call sites pass"

# ---------------------------------------------------------------------------
# Step 4 — the boots.
# ---------------------------------------------------------------------------
TABLE_QWORDS=$(( VM_FRAMES * 512 ))

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
  port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 300 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m "$mem" \
    -cpu "$cpu" \
    -vga std \
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
    --keys "$keys" \
    "$@"
  local drive_status=$?
  wait "$qemu_pid" 2>/dev/null
  local qemu_status=$?
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

# The session. Every element makes a specific claim, and the ORDER is the
# argument: the two things that must NOT fault are run BEFORE the two that must,
# so a kernel where every store faulted would fail at `vmtest rw` rather than
# looking like a success at `vmtest ro`.
#
#   vm          the address space, walked page by page out of the live tables.
#   vmtest rw   CONTROL: a u64 store to a writable page. Must not fault.
#   vmtest x    CONTROL: an indirect call to an executable page. Must not fault.
#   vmtest ro   a u64 store to a `@rodata` page  -> #PF, write, present.
#   vmtest nx   an indirect call to that same page -> #PF, instruction fetch.
#   vm          the canary UNCHANGED, and two faults recorded.
#   clear       blank screen, so the text-buffer golden is a clean dump.
#   vm          the report the screenshot shows.
SESSION_KEYS="v,m,ret,wait:1500"
SESSION_KEYS="$SESSION_KEYS,v,m,t,e,s,t,spc,r,w,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,v,m,t,e,s,t,spc,x,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,v,m,t,e,s,t,spc,r,o,ret,wait:1000"
SESSION_KEYS="$SESSION_KEYS,v,m,t,e,s,t,spc,n,x,ret,wait:1000"
SESSION_KEYS="$SESSION_KEYS,v,m,ret,wait:1500"
SESSION_KEYS="$SESSION_KEYS,v,m,t,e,s,t,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,v,m,ret,wait:1500"

SHOT_PNG="$CORE_DIR/build/screenshot-paging.png"
rm -f "$SHOT_PNG"

# The tables are dumped from the CR3 THE KERNEL PRINTED, and `info registers`
# gives the CR3 the CPU is actually using; the two are asserted equal below, so
# neither the kernel's word nor the harness's guess is load-bearing on its own.
drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 40 128M qemu64 \
  --addr-from-serial 'VM CR3 ([0-9A-F]{16}) ' \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx {addr}" \
  --monitor-capture "$WORKDIR/session/monitor.txt"

SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"

if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"
  cp "$SCREEN_TEXT" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL and $EXPECTED_SCREEN — the derived checks below still have to pass"
fi

[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# ---------------------------------------------------------------------------
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
#
# This is the assertion that says the CR3 switch is invisible from outside.
# vmInit() runs before the first byte of output and prints nothing; if it ever
# printed a diagnostic, or if the kernel's boot path changed shape at all, this
# fails before anything else does.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M8 changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 5b. The whole serial capture.
if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL_CAPTURE") | head -40 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 5c. THE LIVE PAGE TABLES, READ OUT OF GUEST PHYSICAL MEMORY.
#
# The assertion this milestone exists for. Not the program headers, not `vm`'s
# own report: the actual entries the MMU is walking, dumped with the monitor at
# the CR3 QEMU says is installed, and walked here by derive.py's independent
# implementation of the x86-64 4-level walk.
if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$WORKDIR/session/monitor.txt" \
     "${SYM[__kernel_start]}" "${SYM[__text_end]}" "${SYM[__rodata_start]}" \
     "${SYM[__rodata_end]}" "${SYM[__data_start]}" "${SYM[__kernel_end]}" <<'PY'
import importlib.util, re, sys

cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
kstart, textend, rostart, roend, datastart, kend = (int(x) for x in sys.argv[4:10])
fails = []

# --- CR3 and CR0, from QEMU rather than from the kernel -----------------
regs = d.parse_registers(monitor)
if "CR3" not in regs or "CR0" not in regs:
    sys.exit("`info registers` produced no CR0/CR3 -- the monitor capture is unusable")
cr3 = regs["CR3"] & d.ADDR_MASK
if not regs["CR0"] & (1 << 31):
    fails.append("CR0.PG is clear -- paging is not even on")
if not regs["CR0"] & (1 << 16):
    fails.append("CR0.WP is CLEAR (CR0=%08X). A read-only page-table entry does "
                 "not stop a ring-0 write without it, so every W=0 below is "
                 "decorative. See known-gaps GAP-0080." % regs["CR0"])

# The kernel's own two numbers must agree with QEMU's.
reports = re.findall(
    r"^VM CR3 ([0-9A-F]{16}) PML4 ([0-9A-F]{16}) NX ([01]) WP ([01]) "
    r"READY ([01]) STATUS ([0-9A-F]{8})$", cap, re.M)
if len(reports) != 3:
    sys.exit("expected 3 `vm` reports in the session, found %d" % len(reports))
for n, (rc3, pml4, nx, wp, ready, status) in enumerate(reports):
    if int(rc3, 16) != cr3:
        fails.append("report %d prints CR3 %s but QEMU says the CPU is using "
                     "%016X" % (n, rc3, cr3))
    if int(pml4, 16) != cr3:
        fails.append("report %d built PML4 %s but the CPU is using %016X -- the "
                     "switch did not install the table this kernel made"
                     % (n, pml4, cr3))
    if nx != "1":
        fails.append("report %d says NX 0 on a CPU that has NX" % n)
    if wp != "1":
        fails.append("report %d says WP 0 -- CR0.WP is not set" % n)
    if ready != "1":
        fails.append("report %d says READY 0: vmInit REFUSED to install a map "
                     "and the kernel is still on boot.S's bootstrap tables "
                     "(STATUS %s)" % (n, status))
    if status != "00000000":
        fails.append("report %d says STATUS %s, expected 00000000" % (n, status))

tables = d.PageTables(cr3, d.parse_xp(monitor))

# --- W^X, PAGE BY PAGE, OVER THE LINKER'S OWN SECTION RANGES ------------
# The ranges are page-rounded outward, which is the honest thing to check: the
# tail padding of `.text`'s last page IS executable and must be, and a byte of
# `.rodata` sharing a page with `.data` would show up here as a `.rodata` page
# that is writable.
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)

t_lo, t_hi = pages(kstart, textend)
r_lo, r_hi = pages(rostart, roend)
d_lo, d_hi = pages(datastart, kend)
if t_hi > rostart:
    fails.append(".text's last page (ending 0x%X) reaches into .rodata at 0x%X"
                 % (t_hi, rostart))
if r_hi > datastart:
    fails.append(".rodata's last page (ending 0x%X) reaches into .data at 0x%X"
                 % (r_hi, datastart))

fails += d.check_region(tables, t_lo, t_hi, False, True, ".text")
fails += d.check_region(tables, r_lo, r_hi, False, False, ".rodata")
fails += d.check_region(tables, d_lo, d_hi, True, False, ".data/.bss")
fails += d.check_region(tables, 0, d.LOW_BYTES, True, False, "the first megabyte")
fails += d.check_region(tables, d.FINE_BYTES, d.MAP_BYTES, True, False,
                        "[4MiB, 128MiB)", step=d.BIG_BYTES)
fails += d.check_region(tables, d.PCI_BASE, d.PCI_END, True, False,
                        "the PCI hole", step=d.BIG_BYTES)

# Everything above the allocator's bound, up to the end of the gigabyte, must be
# UNMAPPED. boot.S's bootstrap tables mapped it; vm.dart deliberately does not,
# so an address above the bound faults instead of writing into RAM nothing
# tracks. Checked at four points rather than 448, since it is one absent PD
# entry per 2MiB and a spot check that finds one mapped is enough to fail.
for va in (d.MAP_BYTES, d.MAP_BYTES + d.BIG_BYTES, 0x20000000, 0x3FE00000):
    if tables.effective(va) is not None:
        fails.append("0x%X is MAPPED, but it is above the allocator's %d-byte "
                     "bound -- vm.dart is supposed to leave it unmapped so a "
                     "stray access faults" % (va, d.MAP_BYTES))

# The page tables themselves must be mapped writable, or the kernel could not
# have kept editing them after the switch (and `vm` could not walk them).
for i in range(d.FRAME_COUNT):
    va = cr3 + i * d.PAGE_BYTES
    got = tables.effective(va)
    if got is None or not got[0]:
        fails.append("page-table frame %d at 0x%X is not mapped writable" % (i, va))

# --- `vm`'s OWN REPORT MUST AGREE WITH THIS WALK ------------------------
# Six region lines per report, each carrying a present-page count and an
# all/any pair for W and X. The kernel walked its tables through `vmWalk`; this
# walked the same bytes out of guest memory through `derive.py`. They are two
# implementations and they must produce the same numbers.
region_lines = re.findall(
    r"^VM (TEXT|RODATA|DATA|LOW|HIGH|PCI) ([0-9A-F]{16}) ([0-9A-F]{16}) "
    r"P ([0-9A-F]{8}) W ([01])([01]) X ([01])([01])$", cap, re.M)
if len(region_lines) != 18:
    fails.append("expected 18 region lines (6 per report x 3), found %d"
                 % len(region_lines))
for name, lo, hi, p, wall, wany, xall, xany in region_lines:
    lo, hi, p = int(lo, 16), int(hi, 16), int(p, 16)
    step = d.BIG_BYTES if name in ("HIGH", "PCI") else d.PAGE_BYTES
    present = 0
    w_all, w_any, x_all, x_any = True, False, True, False
    a = lo
    while a < hi:
        got = tables.effective(a)
        if got is None:
            w_all = x_all = False
        else:
            present += 1
            w_all &= got[0]; w_any |= got[0]
            x_all &= got[1]; x_any |= got[1]
        a += step
    if present != p:
        fails.append("`vm` says %s has %d present pages; the tables in guest "
                     "memory have %d" % (name, p, present))
    got = "%d%d%d%d" % (w_all, w_any, x_all, x_any)
    want = wall + wany + xall + xany
    if got != want:
        fails.append("`vm` says %s is W %s%s X %s%s; the tables in guest memory "
                     "say W %s%s X %s%s"
                     % (name, wall, wany, xall, xany,
                        int(w_all), int(w_any), int(x_all), int(x_any)))
print("    (%d region lines checked against an independent walk of %d bytes of "
      "page tables read out of guest memory at CR3=0x%X)"
      % (len(region_lines), tables.span, cr3))

if fails:
    print("m8-paging: page-table check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
then
  fail "the live page tables in guest memory do not enforce W^X, or they are not the tables the kernel says it installed"
fi
echo "ASSERT: pass  the LIVE page tables, read out of guest physical memory at QEMU's own CR3, map .text read+execute, .rodata read-only+NX, .data/.bss read+write+NX — identity, page by page — and CR0.WP is set so the CPU obeys them"

# 5d. THE FAULTS THEMSELVES — AND THE TWO THAT MUST NOT HAPPEN.
#
# GAP-0050's whole point was that a write to `.rodata` succeeded SILENTLY. This
# is where that stops being true, and the controls are checked first so a kernel
# in which everything faults cannot look like a pass.
if ! python3 - "$SERIAL_CAPTURE" "${SYM[__rodata_start]}" "${SYM[__rodata_end]}" \
     "${SYM[__kernel_start]}" "${SYM[__text_end]}" "${SYM[__data_start]}" "${SYM[__kernel_end]}" <<'PY'
import re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
rostart, roend, kstart, textend, datastart, kend = (int(x) for x in sys.argv[2:8])
fails = []

# --- the controls: neither may fault ------------------------------------
m = re.search(r"^VM TEST RW ADDR ([0-9A-F]{16}) ([0-9A-F]{16}) (OK|FAIL)$", cap, re.M)
if not m:
    fails.append("no `VM TEST RW` line -- the writable-page control did not run")
else:
    addr, val, verdict = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
    if verdict != "OK":
        fails.append("the writable-page control FAILED: the store to 0x%X did "
                     "not read back" % addr)
    if val != (addr ^ 0x5A5A5A5A5A5A5A5A):
        fails.append("the RW control's value is not derived from its own address")
    if not (datastart <= addr < kend):
        fails.append("the RW control wrote to 0x%X, which is not inside "
                     "[.data, .bss end) = [0x%X, 0x%X)" % (addr, datastart, kend))
m = re.search(r"^VM TEST X ADDR ([0-9A-F]{16}) (OK|FAIL)$", cap, re.M)
if not m:
    fails.append("no `VM TEST X` line -- the executable-page control did not run")
else:
    addr, verdict = int(m.group(1), 16), m.group(2)
    if verdict != "OK":
        fails.append("the executable-page control FAILED: the indirect call to "
                     "0x%X did not return" % addr)
    if not (kstart <= addr < textend):
        fails.append("the X control called 0x%X, which is not inside .text "
                     "[0x%X, 0x%X)" % (addr, kstart, textend))
# Nothing may fault between the two controls and the first deliberate fault.
head = cap.split("VM TEST RO ADDR")[0]
if "FAULT " in head.split("M1 END")[-1]:
    fails.append("a fault was reported BEFORE the first deliberate one -- the "
                 "controls did not run clean, so the faults below prove nothing "
                 "about permissions")

# --- the write to `.rodata` ---------------------------------------------
m = re.search(r"^VM TEST RO ADDR ([0-9A-F]{16})\n"
              r"FAULT 0E ERR 0000000000000003 OP ([0-9A-F]{4})\n"
              r"PF CR2 ([0-9A-F]{16}) ERR 00000003 PRESENT WRITE SUPER DATA\n"
              r"FAULT RECOVERED ([0-9A-F]{4}) ", cap, re.M)
if not m:
    if "VM TEST RO SURVIVED" in cap:
        fails.append("**THE WRITE TO `.rodata` LANDED.** `vmtest ro` printed "
                     "SURVIVED, which means the store through a pointer into a "
                     "read-only page succeeded. GAP-0050 is not closed. The "
                     "usual cause is CR0.WP being clear -- a read-only "
                     "page-table entry does not stop a ring-0 write without it.")
    else:
        fails.append("`vmtest ro` did not produce the expected #PF sequence "
                     "(vector 0E, error code 3, CR2, and a recovery line). "
                     "Captured: %r" % cap[cap.find("VM TEST RO"):][:400])
else:
    target, cr2 = int(m.group(1), 16), int(m.group(3), 16)
    if cr2 != target:
        fails.append("`vmtest ro` aimed at 0x%X but CR2 reports 0x%X -- the "
                     "handler is not reporting the address that faulted"
                     % (target, cr2))
    if not (rostart <= target < roend):
        fails.append("the canary is at 0x%X, which is not inside .rodata "
                     "[0x%X, 0x%X) -- the test is not aimed at a read-only page"
                     % (target, rostart, roend))

# --- the instruction fetch from `.rodata` --------------------------------
m = re.search(r"^VM TEST NX ADDR ([0-9A-F]{16})\n"
              r"FAULT 0E ERR 0000000000000011 OP ([0-9A-F]{4})\n"
              r"PF CR2 ([0-9A-F]{16}) ERR 00000011 PRESENT READ SUPER FETCH\n"
              r"FAULT RECOVERED ([0-9A-F]{4}) ", cap, re.M)
if not m:
    if "VM TEST NX SURVIVED" in cap:
        fails.append("**THE INSTRUCTION FETCH FROM `.rodata` RAN.** `vmtest nx` "
                     "printed SURVIVED on a CPU that has NX, so either the NX "
                     "bit is not in the entries or EFER.NXE is not set.")
    else:
        fails.append("`vmtest nx` did not produce the expected #PF sequence "
                     "(vector 0E, error code 0x11 = present + fetch). Captured: "
                     "%r" % cap[cap.find("VM TEST NX"):][:400])
else:
    target, op, cr2 = int(m.group(1), 16), m.group(2), int(m.group(3), 16)
    if cr2 != target:
        fails.append("`vmtest nx` fetched from 0x%X but CR2 reports 0x%X"
                     % (target, cr2))
    if op != "C34F":
        fails.append("the faulting instruction's first two bytes are %s, "
                     "expected C34F -- the canary. If they are not the canary's "
                     "own bytes, either the fetch was aimed somewhere else or "
                     "the `vmtest ro` write DID land and changed them." % op)
    if not (rostart <= target < roend):
        fails.append("the NX test fetched from 0x%X, outside .rodata" % target)

# --- THE CANARY IS UNCHANGED, IN ALL THREE REPORTS -----------------------
# The strongest single statement that the write did not land: not "a fault was
# reported", but "the eight bytes are still what the linker put there".
canaries = re.findall(r"^VM CANARY ([0-9A-F]{16})$", cap, re.M)
if len(canaries) != 3:
    fails.append("expected 3 `VM CANARY` lines, found %d" % len(canaries))
for n, c in enumerate(canaries):
    if c != "C34F534352575821":
        fails.append("canary %d reads %s, expected C34F534352575821 ('\\xC3OSCRWX!'). "
                     "A write into `.rodata` landed." % (n, c))

# --- the faults were COUNTED --------------------------------------------
counts = re.findall(r"^VM FAULTS ([0-9A-F]{8}) CR2 ([0-9A-F]{16}) ERR ([0-9A-F]{8})$",
                    cap, re.M)
if len(counts) != 3 or int(counts[0][0], 16) != 0 or int(counts[1][0], 16) != 2 \
        or int(counts[2][0], 16) != 2:
    fails.append("the page-fault counts across the three reports are %r, "
                 "expected 0 then 2 then 2 -- a fault the kernel reported but "
                 "did not record, or one it recorded twice"
                 % [c[0] for c in counts])
elif int(counts[1][2], 16) != 0x11:
    fails.append("the last recorded error code is %s, expected 00000011 (the "
                 "NX fetch, which was the most recent)" % counts[1][2])

# --- the shell survived both --------------------------------------------
if cap.count("FAULT RECOVERED") != 2:
    fails.append("expected exactly 2 recovery lines, found %d"
                 % cap.count("FAULT RECOVERED"))
if not cap.rstrip().endswith("oscortex>"):
    fails.append("the session does not end at a live prompt")
# `vmtest` with no argument is a usage line, not an unknown command.
if "vmtest: usage: vmtest ro | nx | rw | x" not in cap:
    fails.append("`vmtest` with no argument did not print its usage line")

if fails:
    print("m8-paging: enforcement check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (write to .rodata -> #PF err 3 at the right CR2; fetch from .rodata "
      "-> #PF err 0x11; both controls clean; canary intact in all three reports)")
PY
then
  fail "the deliberate faults did not happen, did not report the right address, or the controls did not run clean"
fi
echo "ASSERT: pass  a write to a @rodata table raises #PF (present/write/supervisor/data) at exactly that address and the canary is unchanged; an instruction fetch from it raises #PF with the fetch bit; the same operations on writable and executable pages do NOT fault; the shell survived both"

# 5e. The framebuffer (the 80x25 text buffer, read out of guest memory).
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly — the console still works through the new mapping"

# 5f. The screenshot.
[[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 6 — BOOT B: NEGATIVE CONTROL 1. A CPU WITH NO NX.
#
# `-cpu qemu64,nx=off` clears CPUID leaf 0x80000001 EDX bit 20, so boot.S's
# probe finds no NX and does not set EFER.NXE, and vm.dart puts no NX bit in any
# entry. THREE things must then be true at once, and together they are what make
# boot A's fetch fault mean "NX" rather than "something faulted":
#
#   * `vm` must say `NX 0` and report `.rodata` as EXECUTABLE. A kernel that
#     printed NX 1 here would be reporting the machine it wished it were on.
#   * `vmtest nx` must SURVIVE. The fetch that faults in boot A is the same
#     instruction against the same address; the only difference is the bit.
#   * `vmtest ro` must STILL FAULT, with the same error code 3. Write protection
#     is CR0.WP and the RW bit, and has nothing to do with NX -- if this stopped
#     working here, the two halves would be entangled and neither result would
#     be attributable.
#
# It is also the boot that proves vm.dart degrades honestly rather than
# refusing: READY must still be 1. A kernel that declined to install any map on
# a CPU without NX would be safe and useless.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/nonx" \
  "v,m,ret,wait:1500,v,m,t,e,s,t,spc,r,o,ret,wait:1000,v,m,t,e,s,t,spc,n,x,ret,wait:1000,v,m,ret,wait:1500" \
  "$WORKDIR/nonx/shot.png" "no-NX" 41 128M qemu64,nx=off \
  --addr-from-serial 'VM CR3 ([0-9A-F]{16}) ' \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx {addr}" \
  --monitor-capture "$WORKDIR/nonx/monitor.txt"

if ! python3 - "$WORKDIR/nonx/serial.txt" "$DERIVE" "$WORKDIR/nonx/monitor.txt" \
     "${SYM[__rodata_start]}" "${SYM[__rodata_end]}" <<'PY'
import importlib.util, re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
rostart, roend = int(sys.argv[4]), int(sys.argv[5])
fails = []

regs = d.parse_registers(monitor)
if not regs.get("CR0", 0) & (1 << 16):
    fails.append("CR0.WP is clear even here -- write protection is supposed to "
                 "be independent of NX")

m = re.search(r"^VM CR3 ([0-9A-F]{16}) PML4 [0-9A-F]{16} NX ([01]) WP ([01]) "
              r"READY ([01]) STATUS ([0-9A-F]{8})$", cap, re.M)
if not m:
    sys.exit("no `vm` report in the no-NX boot")
cr3, nx, wp, ready, status = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
if nx != "0":
    fails.append("on `-cpu qemu64,nx=off` the kernel still reports NX 1 -- it is "
                 "not reading the CPU's answer, it is printing a constant")
if wp != "1":
    fails.append("WP is 0 on the no-NX boot")
if ready != "1" or status != "00000000":
    fails.append("vmInit refused to install a map on a CPU without NX "
                 "(READY %s STATUS %s). Losing NX should cost NX, not the whole "
                 "address space." % (ready, status))

# `.rodata` must read back EXECUTABLE here, and still not writable.
tables = d.PageTables(int(cr3, 16) & d.ADDR_MASK, d.parse_xp(monitor))
lo, hi = rostart & ~0xFFF, (roend + 0xFFF) & ~0xFFF
fails += d.check_region(tables, lo, hi, False, True, ".rodata on a no-NX CPU")
if not re.search(r"^VM RODATA [0-9A-F]{16} [0-9A-F]{16} P [0-9A-F]{8} W 00 X 11$",
                 cap, re.M):
    fails.append("`vm` does not report .rodata as W 00 X 11 on a CPU without NX")

# The fetch must SURVIVE, and the write must still FAULT.
if "VM TEST NX SURVIVED -- THE FETCH RAN" not in cap:
    fails.append("NEGATIVE CONTROL FAILED: the instruction fetch from `.rodata` "
                 "faulted on a CPU with NO NX. Whatever made it fault in the "
                 "main session, it was not the NX bit.")
if not re.search(r"^PF CR2 [0-9A-F]{16} ERR 00000003 PRESENT WRITE SUPER DATA$",
                 cap, re.M):
    fails.append("the write to `.rodata` did not fault on the no-NX boot -- "
                 "write protection is not independent of NX after all")
if "VM TEST RO SURVIVED" in cap:
    fails.append("the write to `.rodata` LANDED on the no-NX boot")
canaries = re.findall(r"^VM CANARY ([0-9A-F]{16})$", cap, re.M)
if any(c != "C34F534352575821" for c in canaries):
    fails.append("the canary changed on the no-NX boot: %r" % canaries)

if fails:
    print("m8-paging: no-NX control FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (no-NX CPU: NX 0 reported, .rodata executable in the live tables, the "
      "fetch survives, and the write still faults with error code 3)")
PY
then
  fail "NEGATIVE CONTROL FAILED: the no-NX boot did not behave differently in exactly the way losing NX should"
fi
# And its capture must differ from the golden, in the `vm` report.
if cmp -s "$WORKDIR/nonx/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a boot on a CPU without NX produced the same serial capture as the main session"
fi
echo "ASSERT: pass  negative control — on -cpu qemu64,nx=off the kernel reports NX 0, maps .rodata executable, and 'vmtest nx' SURVIVES while 'vmtest ro' still faults: the fetch fault in the main session is caused by the NX bit and by nothing else"

# ---------------------------------------------------------------------------
# Step 7 — BOOT C: NEGATIVE CONTROL 2. A DIFFERENT MACHINE.
#
# 32MiB instead of 128. The memory map changes, so the frame allocator's answers
# change, so the frames the page tables are built from could change -- and the
# address space must still come up and still be W^X. This is the boot that says
# the tables are BUILT at runtime out of whatever the allocator gives them,
# rather than being a fixed blob the kernel could have had all along.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/small" "v,m,ret,wait:1500,v,m,t,e,s,t,spc,r,o,ret,wait:1000" \
  "$WORKDIR/small/shot.png" "small-machine" 42 32M qemu64 \
  --addr-from-serial 'VM CR3 ([0-9A-F]{16}) ' \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx {addr}" \
  --monitor-capture "$WORKDIR/small/monitor.txt"

if ! python3 - "$WORKDIR/small/serial.txt" "$DERIVE" "$WORKDIR/small/monitor.txt" \
     "${SYM[__kernel_start]}" "${SYM[__text_end]}" "${SYM[__rodata_start]}" \
     "${SYM[__rodata_end]}" "${SYM[__data_start]}" "${SYM[__kernel_end]}" <<'PY'
import importlib.util, re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
kstart, textend, rostart, roend, datastart, kend = (int(x) for x in sys.argv[4:10])
fails = []
m = re.search(r"^VM CR3 ([0-9A-F]{16}) PML4 ([0-9A-F]{16}) NX 1 WP 1 READY 1 "
              r"STATUS 00000000$", cap, re.M)
if not m:
    sys.exit("the 32MiB machine did not bring up an address space: %r"
             % cap[cap.find("VM CR3"):][:200])
cr3 = int(m.group(1), 16) & d.ADDR_MASK
regs = d.parse_registers(monitor)
if (regs.get("CR3", 0) & d.ADDR_MASK) != cr3:
    fails.append("the 32MiB boot's reported CR3 disagrees with QEMU's")
tables = d.PageTables(cr3, d.parse_xp(monitor))
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)
fails += d.check_region(tables, *pages(kstart, textend), False, True, ".text (32MiB)")
fails += d.check_region(tables, *pages(rostart, roend), False, False, ".rodata (32MiB)")
fails += d.check_region(tables, *pages(datastart, kend), True, False, ".data/.bss (32MiB)")
if not re.search(r"^PF CR2 [0-9A-F]{16} ERR 00000003 PRESENT WRITE SUPER DATA$",
                 cap, re.M):
    fails.append("the write to `.rodata` did not fault on the 32MiB machine")
# The allocator's numbers must have followed the machine, or this is not a
# different machine at all -- the `MB E` lines are what pmmInit builds from.
if "MB E 0000000007FE0000" in cap:
    fails.append("the 32MiB boot reports the 128MiB machine's memory map -- it "
                 "is not a smaller machine")
if fails:
    print("m8-paging: small-machine control FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (32MiB machine: a different memory map, and the address space still "
      "comes up W^X at CR3=0x%X)" % cr3)
PY
then
  fail "NEGATIVE CONTROL FAILED: the address space did not come up correctly on a different machine"
fi
if cmp -s "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a boot on a 32MiB machine produced the same serial capture as the 128MiB session"
fi
SMALL_DIFF=$(cmp "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE '(byte|char) [0-9]+' | head -1)
SMALL_OFFSET=${SMALL_DIFF##* }
[[ "$SMALL_OFFSET" -le 544 ]] || fail "the 32MiB capture matches M1's entire 544-byte golden, so the boot-time memory-map report did not change with the machine"
echo "ASSERT: pass  negative control — on a 32MiB machine the memory map differs inside M1's own boot report, and the address space still comes up W^X and still faults on a .rodata write"

# ---------------------------------------------------------------------------
# Step 8 — BOOT D: W^X SURVIVES THE ALLOCATOR.
#
# The page tables are the first kernel memory that cannot be lost and is NOT
# inside `[__kernel_start, __kernel_end)` -- they come out of `allocFrame()`. So
# `pmmAllocatable` gained a clause (`vmHoldsFrame`), and this boot is what
# proves the clause works rather than merely existing:
#
#   frames drain   hands out every free frame. If the six were free, they would
#                  be handed out here.
#   frames test    allocates 64 frames and WRITES an address-derived value into
#                  the first and last u64 of each. On a live PML4 that is a
#                  scrambled address space, i.e. an immediate triple fault.
#   frames refill  frees everything `pmmAllocatable` says was ever allocatable.
#                  If the clause were missing, all six would be freed here.
#   free <PML4>    the explicit statement: giving the page-table frame back must
#                  be REFUSED with ERR RESERVED, not accepted.
#   vm             and the address space is still there, still W^X.
#
# The tables are then dumped out of guest memory and walked again. A kernel that
# had handed its own PML4 to `frames test` would fail here rather than three
# milestones later.
# ---------------------------------------------------------------------------
PML4_HEX=$(grep -m1 -oE '^VM CR3 [0-9A-F]{16}' "$SERIAL_CAPTURE" | awk '{print $3}')
PML4_KEYS=$(python3 -c "
import sys
v = sys.argv[1].lstrip('0').lower()
print(','.join(v))" "$PML4_HEX")
drive_session "$WORKDIR/drain" \
  "f,r,a,m,e,s,spc,d,r,a,i,n,ret,wait:12000,f,r,a,m,e,s,spc,r,e,f,i,l,l,ret,wait:25000,f,r,a,m,e,s,spc,t,e,s,t,ret,wait:3000,f,r,e,e,spc,$PML4_KEYS,ret,wait:600,v,m,ret,wait:1500" \
  "$WORKDIR/drain/shot.png" "drain-then-vm" 43 128M qemu64 \
  --addr-from-serial 'VM CR3 ([0-9A-F]{16}) ' \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx {addr}" \
  --monitor-capture "$WORKDIR/drain/monitor.txt"

if ! python3 - "$WORKDIR/drain/serial.txt" "$DERIVE" "$WORKDIR/drain/monitor.txt" \
     "$PML4_HEX" "${SYM[__kernel_start]}" "${SYM[__text_end]}" \
     "${SYM[__rodata_start]}" "${SYM[__rodata_end]}" "${SYM[__data_start]}" \
     "${SYM[__kernel_end]}" <<'PY'
import importlib.util, re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
pml4_hex = sys.argv[4]
kstart, textend, rostart, roend, datastart, kend = (int(x) for x in sys.argv[5:11])
fails = []

# `free <PML4>` must be REFUSED, and refused for the right reason.
want = "PMM FREE %s ERR RESERVED\n" % pml4_hex
if want not in cap:
    got = re.search(r"^PMM FREE %s (.*)$" % pml4_hex, cap, re.M)
    fails.append("freeing the live PML4 at %s was not refused with ERR RESERVED "
                 "(got %r). pmmAllocatable's vmHoldsFrame clause is not working, "
                 "and the allocator can hand the running address space out."
                 % (pml4_hex, got.group(1) if got else "no PMM FREE line at all"))

# The drain must not have taken them either, and the refill must not have freed
# them: both would show as the allocator believing it has six more frames than
# it does, which is exactly what FREE == BASELINE measures.
m = re.search(r"^PMM REFILL GAVE ([0-9A-F]{8}) FREE ([0-9A-F]{8}) "
              r"BASELINE ([0-9A-F]{8}) ERRORS ([0-9A-F]{8}) (OK|FAIL)$", cap, re.M)
if not m:
    fails.append("no `PMM REFILL` line -- the refill did not run")
elif m.group(5) != "OK" or m.group(2) != m.group(3):
    fails.append("after drain+refill FREE is %s and BASELINE is %s (%s). The "
                 "page-table frames were either handed out or freed."
                 % (m.group(2), m.group(3), m.group(5)))
if "PMM TEST PASS" not in cap:
    fails.append("`frames test` did not pass after the drain/refill cycle")

# And the address space is STILL there, still W^X, after all of that.
m = re.search(r"^VM CR3 ([0-9A-F]{16}) PML4 [0-9A-F]{16} NX 1 WP 1 READY 1 "
              r"STATUS 00000000$", cap, re.M)
if not m:
    sys.exit("no healthy `vm` report after the drain/refill cycle: %r"
             % cap[cap.find("VM CR3"):][:200])
if m.group(1) != pml4_hex:
    fails.append("CR3 changed between boots (%s vs %s) -- the page tables are "
                 "not landing on the frames this check assumed"
                 % (m.group(1), pml4_hex))
cr3 = int(m.group(1), 16) & d.ADDR_MASK
tables = d.PageTables(cr3, d.parse_xp(monitor))
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)
fails += d.check_region(tables, *pages(kstart, textend), False, True, ".text after drain")
fails += d.check_region(tables, *pages(rostart, roend), False, False, ".rodata after drain")
fails += d.check_region(tables, *pages(datastart, kend), True, False, ".data/.bss after drain")
canaries = re.findall(r"^VM CANARY ([0-9A-F]{16})$", cap, re.M)
if any(c != "C34F534352575821" for c in canaries):
    fails.append("the canary changed during the drain/refill cycle: %r" % canaries)

if fails:
    print("m8-paging: allocator-interaction check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (every free frame drained, 64 allocated and written, everything "
      "refilled to the baseline, the PML4 refused as RESERVED -- and the page "
      "tables in guest memory are still intact and still W^X)")
PY
then
  fail "the frame allocator can reach the kernel's own page tables, or the address space did not survive a full drain/refill cycle"
fi
echo "ASSERT: pass  a full drain / 64-frame write test / refill cycle does not touch the six page-table frames, 'free <PML4>' is refused with ERR RESERVED, and the live tables are still W^X afterwards"

echo "M8-paging: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S + portio.S) -> link into THREE PT_LOAD segments -> 12 structural checks (no RWX segment, three segments R E / R / RW, section boundaries page-aligned and non-overlapping, donated .bss 5096 -> 5224, vm_store one 128-byte symbol, the storage seam exactly 1 call site, the mapped extent == the allocator's bound, the page geometry multiplied out against itself and against derive.py, m7's derivation reserving the same 6 frames, CR0.WP and EFER.NXE in boot.S, 49 @rodata sizes) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 32 + 12, kdata.o still clean standalone) -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; the LIVE page tables read out of guest physical memory at QEMU's own CR3 and walked independently, proving .text read+execute, .rodata read-only+NX and .data/.bss read+write+NX, identity, page by page, with everything above the 128MiB bound unmapped; a deliberate write to a @rodata table raising #PF with the right CR2 and a decoded error code while the canary stays intact and the shell survives; a deliberate instruction fetch from the same page raising #PF with the fetch bit; both controls (a store to a writable page, a call to an executable page) running clean; a no-NX CPU where the fetch SURVIVES and the write still faults; a 32MiB machine where the address space still comes up W^X; and a full allocator drain/refill cycle that cannot reach the page tables. Screenshot at $SHOT_PNG"
exit 0
