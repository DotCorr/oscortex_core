#!/usr/bin/env bash
# core/tests/conformance/m11-proc/run.sh
#
# Mechanical check of ROADMAP.md's M11 exit criterion: this kernel can enable
# SSE, run TWO programs it did not compile, in TWO address spaces, switching
# between them on a `yield` syscall with each one's FPU state its own -- and it
# can show, from hardware, that neither can reach the other's memory.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# M10 loaded one program into one address space -- the kernel's -- and ran it.
# Its own program had to be built with `-mgeneral-regs-only`, because
# `core/boot/boot.S` had never set CR4.OSFXSR and every SSE instruction was a
# #UD (docs/known-gaps.md GAP-0092), and there was no second thing for it to be
# isolated from (GAP-0089). This harness closes both:
#
#   * THE PROGRAMS ARE BUILT WITHOUT `-mgeneral-regs-only`, at -O2, and
#     build-progs.sh asserts the disassembly of a function containing NO INLINE
#     ASSEMBLY does contain an `%xmm` register. That is the inverse of M10's
#     assertion, and it is what makes this a test of a kernel that enabled SSE
#     rather than a test of one that did not need it.
#
#   * THE FPU STATE IS READ OUT OF GUEST RAM. With process A suspended in a
#     `yield` and process B on the CPU, A's 512-byte FXSAVE area is dumped and
#     its XMM0 and XMM7 must hold A's own signature in all four lanes, while
#     B's area -- B is running, so nothing has been saved into it -- must not.
#
#   * BOTH ADDRESS SPACES ARE WALKED FROM GUEST RAM, from two different PML4
#     frames, at the same time. A's private pages must be ABSENT from B's; the
#     pages both map (the two programs are deliberately linked at the same
#     addresses) must be backed by DIFFERENT physical frames; and the kernel's
#     own pages must be the SAME frame in both and supervisor-only in both --
#     without which "isolated" would be satisfied by an empty address space.
#
#   * THE NEGATIVE CONTROL IS RUN BY THE KERNEL, NOT BY THE HARNESS.
#     `proc cross` asks the KERNEL to compute an address A has mapped and B has
#     not (`procCrossVa`, from the two page tables it built), hands it to B in
#     RDI, and B dereferences it. It must #PF with NOTPRES READ USER, and the
#     address the kernel chose must equal the one this harness computed
#     independently from its own walk of the same two tables.
#
# THE SWITCHING IS COOPERATIVE. There is no timer-driven scheduler and nothing
# in this file pretends otherwise: every switch in every capture is preceded by
# a `yield` syscall or an `exit`, and step 6h asserts exactly that -- the number
# of switches equals the number of yields plus the number of exits that had a
# survivor. docs/known-gaps.md GAP-0097.
#
# FOUR BOOTS, EACH MAKING A CLAIM THE OTHERS CANNOT
# ---------------------------------------------------------------------------
#   A  128M   the driven session: both programs run to completion, interleaved;
#             a refusal; then the cross probe, which faults and tears both
#             down; then the allocator's free count back at its baseline.
#             Serial golden + 80x25 screen + PNG.
#   B  128M   BOTH PROCESSES LEFT ALIVE. progB is written onto the disk a third
#             time with `jmp .` over its entry point, so A yields to a process
#             that never finishes and both address spaces stay live while
#             QEMU's own `info registers` and a 256KiB `xp` are taken.
#   C  128M   NEGATIVE CONTROL -- `-cpu qemu64,-sse,-fxsr`. `proc` must print
#             `SSE 0`, CR4 must be 0x20 EXACTLY, and `proc run` must refuse by
#             name instead of running two processes with nowhere to save an FPU.
#
#             WHAT THIS BOOT ACTUALLY CATCHES, MEASURED RATHER THAN ASSUMED.
#             The SDM says CR4.OSFXSR is reserved when CPUID reports no FXSR,
#             and that writing a reserved CR4 bit is a #GP -- which, before any
#             IDT exists, is a triple fault. A kernel built here with the CPUID
#             guard DELETED was run on this machine and DID NOT triple-fault:
#             QEMU accepted bit 10 and silently dropped bit 9, and all 544
#             bytes of M1's output still appeared. So what catches an unguarded
#             CR4 write HERE is the exact-0x20 assertion below (it read 0x420),
#             NOT the absence of output -- and on real hardware it would be the
#             absence of output. Both are asserted; neither claim is left
#             resting on the other. docs/known-gaps.md GAP-0099.
#   D  128M   NEGATIVE CONTROL -- no frames. `frames drain` first, so
#             `proc run` must REFUSE rather than build an address space out of
#             pages nobody allocated.
#
# `qmp-drive.py` is REUSED from m2-console unchanged -- one driver, ten
# harnesses now -- and derive.py's ELF reader and page-table walker are
# m10-elf's, loaded by path.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m11-proc/run.sh
#   ... --regen    rewrite the goldens from this boot (the derived checks below
#                  still have to pass afterwards)
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M11-proc: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M11-proc: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DERIVE="$SCRIPT_DIR/derive.py"
BUILD_PROGS="$SCRIPT_DIR/build-progs.sh"
MAKE_IMAGE="$SCRIPT_DIR/make-image.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
M10_DERIVE="$CORE_DIR/tests/conformance/m10-elf/derive.py"
for f in "$DERIVE" "$BUILD_PROGS" "$MAKE_IMAGE"; do
  [[ -f "$f" ]] || setup_error "$f not found"
done
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m11-proc reuses m2-console's)"
[[ -f "$M10_DERIVE" ]] || setup_error "m10-elf/derive.py not found at $M10_DERIVE — m11-proc's derive.py loads its ELF reader and page-table walker from it"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m11.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

hexnum() { python3 -c "import sys; print(int(sys.argv[1], 16))" "$1"; }
dartconst() {
  awk -F'= *' -v n="$1" '$0 ~ ("^const int " n " =") { gsub(/;.*/,"",$2); print $2; exit }' \
    "$CORE_DIR/kernel/$2"
}

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
bash "$CORE_DIR/scripts/build-kernel.sh" >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
cat "$BUILD_LOG"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS (log above)"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
[[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — build the two PROGRAMS and the disk they live on.
# ---------------------------------------------------------------------------
bash "$BUILD_PROGS" "$WORKDIR" || fail "the test programs could not be built (see above)"
PROG_A="$WORKDIR/progA.elf"
PROG_B="$WORKDIR/progB.elf"

DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
python3 "$MAKE_IMAGE" "$DISK_IMG" "$PROG_A" "$PROG_B" --emit "$WORKDIR/variants" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
PROG_BHOLD="$WORKDIR/variants/prog-Bhold.elf"
[[ -f "$PROG_BHOLD" ]] || fail "make-image.py did not emit prog-Bhold.elf"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)
LBA_BHOLD=$(lba_of Bhold)
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
echo "IMAGE: pass  $IMG_BYTES bytes = $(( IMG_BYTES / 512 )) sectors, 3 program slots (A at 0x$LBA_A, B at 0x$LBA_B, B-held at 0x$LBA_BHOLD), generated and re-read from disk"

# ---------------------------------------------------------------------------
# Step 3 — structural checks (CLAUDE.md: anything checkable without booting
# should be).
# ---------------------------------------------------------------------------

# 3a. DONATED `.bss` GREW FROM 5496 TO 9664, AND THIS HARNESS NOW OWNS THE
#     NUMBER.
#
# 16 (M2) -> 304 (M3) -> 392 (M4) -> 424 (M5) -> 424 (M6) -> 5096 (M7) ->
# 5224 (M8) -> 5368 (M9) -> 5496 (M10) -> 9664 (M11). M11's share is 4168 and
# not 4160: `proc_store` needs `.align 16` because `fxsave` on a misaligned
# operand is a #GP, `elf_store` ends at 5496, and 5496 is 8 short of a multiple
# of 16. The padding is charged HERE rather than hidden, and every earlier
# harness subtracts M11's share the same way.
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
[[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
[[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$DART_BSS
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
# M14 (ADR-0018) added a sixth block AFTER M11's: `fat_store`, 1824 bytes, with
# no padding because proc_store ends at a multiple of 16. Subtracted here so
# that M11's own number stays exactly what it was before M14 existed -- the same
# accounting every earlier harness does for every later milestone's block.
M14_OFF_HEX=$(bssoff fatStore)
[[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
[[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824"
KDATA_BSS=$(( KDATA_BSS - M14_BSS ))
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))
[[ "$KDATA_BSS" -eq 9728 ]] || fail "the kernel's mutable static storage outside M14's fatStore is $KDATA_BSS bytes, expected 9728 (5496 through M10, plus 4224 for the process table -- 4160 at M11 and 64 more for M18's scheduler header, ADR-0022 -- and 8 for the alignment its align: 16 forces). If you meant to grow it, say so in GAP-0053."
PROC_STORE=$(bsssize procStore)
[[ "$PROC_STORE" == "4224" ]] || fail "procStore is ${PROC_STORE:-missing} bytes, expected 4224 (4160 at M11, plus M18's eight extra header words)"
ELF_STORE_OFF_HEX=$(bssoff elfStore)
ELF_STORE_SZ=$(bsssize elfStore)
# The offset arithmetic runs inside the DCDart half (ASM_BSS is 96 bytes of
# assembly-owned words that are NOT at the end of it), so subtract it back out.
[[ $(( KDATA_BSS - ASM_BSS - 16#$ELF_STORE_OFF_HEX - ELF_STORE_SZ )) -eq 4232 ]] \
  || fail "the mutable static bytes past the end of elfStore are $(( KDATA_BSS - ASM_BSS - 16#$ELF_STORE_OFF_HEX - ELF_STORE_SZ )), expected 4232"
# M17: scan BOTH objects, and only their .bss sections. The storage moved to
# kmain.o, so a scan of kdata.o alone would now find nothing and pass for the
# wrong reason. The migration this check was written to protect has happened;
# what it protects now is that it did not have to find a second symbol.
for obj in kmain.o kdata.o; do
  BIX=$(x86_64-elf-readelf -SW "$CORE_DIR/build/$obj" | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\][[:space:]]*\.bss[[:space:]].*/\1/p')
  [[ -n "$BIX" ]] || continue
  for sym in $(x86_64-elf-readelf -sW "$CORE_DIR/build/$obj" | awk -v b="$BIX" '$4=="OBJECT" && $7==b && $8 ~ /buffer|sector|proc_scratch|proc_head|proc_table|proc_fx|procScratch|procHead|procTable|procFx|Buffer|Sector/ {print $8}'); do
    fail "$obj holds MUTABLE STATIC '$sym'. M11's state is ONE symbol behind three offsets (ADR-0015 §1) — a second one is a second thing the storage seam would have had to know about."
  done
done
echo "STRUCTURAL: pass  exactly 9728 bytes of mutable static storage — 5496 inherited, 4224 for procStore and 8 for the alignment fxsave requires, in ONE symbol"

# 3b. `proc_store` IS 16-BYTE ALIGNED IN THE LINKED IMAGE, AND SO IS EVERY
#     FXSAVE AREA INSIDE IT.
#
# `.align 16` in kdata.S is a directive; this is the evidence. `fxsave` and
# `fxrstor` on a misaligned operand raise #GP -- a fault in the middle of a
# context switch, on a machine where everything else worked. The address is
# read out of kernel.elf, after linking, and each of the four areas is
# multiplied out from it.
# ---------------------------------------------------------------------------
# THIS CHECK CHANGED AT M17 (ADR-0021) AND IT GOT STRONGER, in three places.
#
# What it used to do: read `proc_store`'s address out of kernel.elf's symbol
# table and check it mod 16. That worked because `.align 16` in kdata.S produced
# a GLOBAL symbol. The storage is now a DCDart `@bss` block, `@bss` symbols are
# LOCAL, and kernel.ld's OUTPUT_FORMAT(elf32-i386) container discards every
# local symbol -- so kernel.elf's symbol table cannot answer the question at
# all. Dropping the check would have been the silent way to lose it.
#
# What it does instead, and why no part of it is weaker than what it replaced:
#
#   (a) THE DECLARATION SAYS SO. `proc.dart` must declare the block with an
#       explicit `align: 16`. This is stronger than a directive in an assembly
#       file, because DCDart REJECTS a non-power-of-two alignment at compile
#       time (DCDart ADR-0051) -- the wrong kind of wrong cannot be built at
#       all, where `.align 15` in kdata.S would have assembled quietly.
#
#   (b) THE OBJECT AGREES. `procStore`'s offset inside kmain.o's `.bss` is a
#       multiple of 16 AND the section's own alignment is at least 16, which is
#       what makes that offset mean anything after linking.
#
#   (c) THE LINKED IMAGE AGREES. The address comes from the LINK MAP -- the
#       linker's own statement of where it placed kmain.o's `.bss` -- and is
#       checked mod 16, exactly as before. Same claim, same artifact, read from
#       the only place that still states it.
#
# All three, or this is not the check it replaced.
grep -qE '^final Bss procStore = const Bss\(bytes: procStoreBytes, align: 16\);$' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart no longer declares 'final Bss procStore = const Bss(bytes: procStoreBytes, align: 16);' — fxsave on a misaligned operand is a #GP, not a slow path, and the declaration is where that requirement now lives"
grep -qE '^@bss$' "$CORE_DIR/kernel/proc.dart" || fail "proc.dart's procStore is not annotated @bss"
PROC_STORE_OFF=$(( 16#$(bssoff procStore) ))
[[ $(( PROC_STORE_OFF % 16 )) -eq 0 ]] || fail "procStore sits at +$PROC_STORE_OFF inside kmain.o's .bss, which is not a multiple of 16"
KMAIN_BSS_ALIGN=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $NF; exit}')
KMAIN_BSS_ALIGN=${KMAIN_BSS_ALIGN##*\*}
[[ "$KMAIN_BSS_ALIGN" -ge 4 ]] || fail "kmain.o's .bss is only 2**$KMAIN_BSS_ALIGN aligned; procStore's declared align: 16 did not reach the section, so the linker is free to place the section wherever"
PROC_STORE_ADDR_HEX=$(bssaddr procStore)
[[ -n "$PROC_STORE_ADDR_HEX" ]] || fail "procStore's linked address is not derivable from core/build/kernel.map — the link map is the only place a @bss block's linked address is stated (see core/scripts/build-kernel.sh)"
PROC_STORE_ADDR=$(hexnum "$PROC_STORE_ADDR_HEX")
[[ $(( PROC_STORE_ADDR % 16 )) -eq 0 ]] || fail "procStore is linked at 0x$PROC_STORE_ADDR_HEX, which is not 16-byte aligned — fxsave would #GP"
PROC_FX_OFFSET=$(dartconst procFxOffset proc.dart)
PROC_FX_BYTES=$(dartconst procFxBytes proc.dart)
PROC_MAX=$(dartconst procMax proc.dart)
for i in $(seq 0 $(( PROC_MAX - 1 ))); do
  A=$(( PROC_STORE_ADDR + PROC_FX_OFFSET + i * PROC_FX_BYTES ))
  [[ $(( A % 16 )) -eq 0 ]] || fail "FXSAVE area $i lands at 0x$(printf %X $A), which is not 16-byte aligned"
done
echo "STRUCTURAL: pass  proc.dart declares procStore with align: 16, kmain.o puts it at +$PROC_STORE_OFF inside a 2**$KMAIN_BSS_ALIGN-aligned .bss, the link map places it at 0x$PROC_STORE_ADDR_HEX, and all $PROC_MAX FXSAVE areas inherit the alignment"

# 3c. THE TABLE'S GEOMETRY MULTIPLIES OUT, against itself and against the
#     donated block. GAP-0077 forces every one of these to be a separate
#     literal in proc.dart (`dcc` will not fold `procMax - 1` inside `u64(...)`),
#     so a pair that stopped agreeing would be silent until a slot overran its
#     neighbour.
PROC_STORE_BYTES=$(dartconst procStoreBytes proc.dart)
PROC_HEAD_WORDS=$(dartconst procHeadWords proc.dart)
PROC_TABLE_OFFSET=$(dartconst procTableOffset proc.dart)
PROC_SLOT_BYTES=$(dartconst procSlotBytes proc.dart)
PROC_SLOT_WORDS=$(dartconst procSlotWords proc.dart)
PROC_SLOT_SHIFT=$(dartconst procSlotShift proc.dart)
PROC_FX_SHIFT=$(dartconst procFxShift proc.dart)
PROC_MAX_SLOT=$(dartconst procMaxSlot proc.dart)
PROC_FRAME_WORDS=$(dartconst procFrameWords proc.dart)
PROC_SLOT_SAVED=$(dartconst procSlotSaved proc.dart)
[[ "$PROC_STORE_BYTES" -eq "$PROC_STORE" ]] || fail "proc.dart says procStoreBytes = $PROC_STORE_BYTES but kmain.o's procStore is $PROC_STORE bytes"
[[ $(( PROC_HEAD_WORDS * 8 )) -eq "$PROC_TABLE_OFFSET" ]] || fail "the header is $PROC_HEAD_WORDS words but the table starts at +$PROC_TABLE_OFFSET"
[[ $(( PROC_SLOT_WORDS * 8 )) -eq "$PROC_SLOT_BYTES" ]] || fail "a slot is $PROC_SLOT_WORDS words but $PROC_SLOT_BYTES bytes"
[[ $(( PROC_TABLE_OFFSET + PROC_MAX * PROC_SLOT_BYTES )) -eq "$PROC_FX_OFFSET" ]] || fail "the table does not end where the FPU areas start: $PROC_TABLE_OFFSET + $PROC_MAX * $PROC_SLOT_BYTES != $PROC_FX_OFFSET"
[[ $(( PROC_FX_OFFSET + PROC_MAX * PROC_FX_BYTES )) -eq "$PROC_STORE_BYTES" ]] || fail "the FPU areas do not end where the block does"
[[ $(( 1 << PROC_SLOT_SHIFT )) -eq "$PROC_SLOT_BYTES" ]] || fail "procSlotShift $PROC_SLOT_SHIFT does not shift by procSlotBytes $PROC_SLOT_BYTES"
[[ $(( 1 << PROC_FX_SHIFT )) -eq "$PROC_FX_BYTES" ]] || fail "procFxShift $PROC_FX_SHIFT does not shift by procFxBytes $PROC_FX_BYTES"
[[ "$PROC_MAX_SLOT" -eq $(( PROC_MAX - 1 )) ]] || fail "procMaxSlot is $PROC_MAX_SLOT, expected procMax - 1 = $(( PROC_MAX - 1 ))"
[[ "$PROC_FX_BYTES" -eq 512 ]] || fail "an FXSAVE image is 512 bytes architecturally; proc.dart says $PROC_FX_BYTES"
[[ $(( PROC_SLOT_SAVED + PROC_FRAME_WORDS )) -le "$PROC_SLOT_WORDS" ]] || fail "the saved $PROC_FRAME_WORDS-word interrupt frame at word $PROC_SLOT_SAVED runs past the end of a $PROC_SLOT_WORDS-word slot"
echo "STRUCTURAL: pass  the process table multiplies out: ${PROC_HEAD_WORDS}-word header + $PROC_MAX x $PROC_SLOT_BYTES-byte slots + $PROC_MAX x $PROC_FX_BYTES-byte FPU areas = $PROC_STORE_BYTES bytes, and derive.py's copy agrees"

# 3d. derive.py's copy of every one of those numbers is the same number.
python3 - "$DERIVE" "$PROC_MAX" "$PROC_STORE_BYTES" "$PROC_HEAD_WORDS" \
    "$PROC_TABLE_OFFSET" "$PROC_FX_OFFSET" "$PROC_SLOT_BYTES" "$PROC_SLOT_WORDS" \
    "$PROC_FX_BYTES" "$PROC_FRAME_WORDS" <<'PY' || fail "derive.py's copy of proc.dart's geometry has drifted"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m11_derive", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
want = dict(zip(("PROC_MAX", "PROC_STORE_BYTES", "PROC_HEAD_WORDS", "PROC_TABLE_OFFSET",
                 "PROC_FX_OFFSET", "PROC_SLOT_BYTES", "PROC_SLOT_WORDS", "PROC_FX_BYTES",
                 "PROC_FRAME_WORDS"), (int(x) for x in sys.argv[2:])))
bad = [(k, getattr(m, k), v) for k, v in want.items() if getattr(m, k) != v]
for k, got, exp in bad:
    print("derive.py has %s = %s, proc.dart says %s" % (k, got, exp), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  derive.py's nine copies of proc.dart's constants all agree with proc.dart"

# 3e. THE STORAGE SEAM IS EXACTLY THREE CALL SITES, ALL IN proc.dart.
#
# ADR-0011 §0's migration plan is only three lines long if the number of places
# that know where this memory came from is three. This counts them, and counts
# every OTHER mention of `procStore` in that file (there must be exactly
# one, the `external` declaration) and in every other kernel source (none).
SEAM_SITES=$(grep -c '^\s*return Bss[.]addressOf(procStore)' "$CORE_DIR/kernel/proc.dart")
[[ "$SEAM_SITES" -eq 3 ]] || fail "Bss.addressOf(procStore) is returned bare from $SEAM_SITES functions in proc.dart, expected exactly 3 (procHeadBase, procTableBase, procFxBase). The storage seam is the whole mutable-statics migration plan — see proc.dart's header."
for fn in procHeadBase procTableBase procFxBase; do
  grep -q "^u64 $fn()" "$CORE_DIR/kernel/proc.dart" || fail "$fn is not in proc.dart — the storage seam's three named functions are what ADR-0011 §0's migration rewrites"
done
STRAY=$(grep -n 'Bss[.]addressOf(procStore)' "$CORE_DIR/kernel/proc.dart" \
        | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' \
        | grep -vE 'final Bss procStore = ' \
        | grep -vcE 'return Bss[.]addressOf[(]procStore[)]')
[[ "$STRAY" -eq 0 ]] || fail "proc.dart has $STRAY call(s) of Bss.addressOf(procStore) outside the three seam functions"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "proc.dart" ]] && continue
  grep -qw 'procStore' "$f" && fail "$(basename "$f") references procStore — the process table's storage seam must not leak out of proc.dart"
done
echo "STRUCTURAL: pass  Bss.addressOf(procStore) is returned from exactly 3 named functions in proc.dart's storage seam, and from nowhere else in the kernel"

# 3f. EVERY @rodata TABLE IS EXACTLY THE SIZE ITS CALL SITE PASSES.
#
# GAP-0060: `@bare` DCDart has no string type, so the length is a hand-written
# literal at the call site and a wrong one prints the next table's bytes. The
# only other thing that catches it is a byte-exact golden, and a golden
# regenerated from a wrong kernel would enshrine it.
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M11 depends on was not emitted (a table with no call site is dropped by the linker)"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table shellStrHelp 2224
check_table procStrSse 9
check_table procStrCr4 5
check_table procStrCr0 5
check_table procStrPd 8
check_table procStrPdF 4
check_table procStrKpd 5
check_table procStrCr3 5
check_table procStrKpml4 7
check_table procStrCap 9
check_table procStrUsed 6
check_table procStrLiveW 6
check_table procStrSwitches 10
check_table procStrCreated 9
check_table procStrSlot 10
check_table procStrState 7
check_table procStrId 4
check_table procStrPml4 6
check_table procStrPt 4
check_table procStrExitF 6
check_table procStrEnd 18
check_table procStrExits 7
check_table procStrNew 14
check_table procStrEntry 7
check_table procStrPages 7
check_table procStrFx 4
check_table procStrStart 16
check_table procStrRspF 5
check_table procStrYield 11
check_table procStrArrow 4
check_table procStrExitL 15
check_table procStrCode 6
check_table procStrLeft 6
check_table procStrKill 15
check_table procStrFreed 7
check_table procStrRun 13
check_table procStrProbe 14
check_table procStrRefused 13
check_table procStrGap 1
check_table procStrUsage 64
check_table procCmdProc 4
check_table procCmdRunSp 9
check_table procCmdCrossSp 11
echo "STRUCTURAL: pass  all 42 M11 message/command tables plus shellStrHelp (1658 -> 1871 -> 2147; three new command lines at M11, four at M14) are exactly the sizes their call sites pass"

# 3g. EVERY REFUSAL CODE IS REACHABLE, AND EVERY ONE HAS ITS OWN SENTENCE.
#
# THIS CHECK FOUND A REAL HOLE. `procErrNoSse` (code 7) had a sentence --
# `this CPU has no FXSAVE, so a process cannot own FPU state` -- and nothing in
# the kernel ever returned it: the CPU-capability refusal existed as text only.
# It is wired now (`shellProcRun`), and boot C is what runs it. A refusal code
# with no `return` reaching it is a sentence the machine can never say, which
# is worse than not having written it.
python3 - "$CORE_DIR/kernel/proc.dart" "$CORE_DIR/build/kmain.o" <<'PY' || fail "proc.dart's refusal codes and messages do not line up one-to-one"
import re, subprocess, sys
src = open(sys.argv[1]).read()
fails = []

codes = dict((m.group(1), int(m.group(2)))
             for m in re.finditer(r"^const int (procErr\w+) = (\d+);", src, re.M))
if "procErrOk" not in codes:
    fails.append("procErrOk is missing")
codes.pop("procErrOk", None)

# Every code must be RETURNED or REFUSED somewhere outside its own declaration.
for name in sorted(codes):
    uses = len(re.findall(r"(?:return|procRefuse\()\s*u64\(%s\)" % name, src))
    if uses == 0:
        fails.append("%s (code %d) is never returned or refused anywhere in "
                     "proc.dart -- it is a sentence the kernel cannot say"
                     % (name, codes[name]))

# Every code must be named in procRefuse, which is where the sentence is chosen.
refuse = src[src.index("void procRefuse("):]
refuse = refuse[:refuse.index("\n}\n")]
named = set(re.findall(r"code == u64\((procErr\w+)\)", refuse))
tables = re.findall(r"Rodata\.addressOf\((procStrE\d+)\), u64\((\d+)\)", refuse)
if len(tables) != len(codes):
    fails.append("procRefuse writes %d message table(s) for %d refusal codes"
                 % (len(tables), len(codes)))
missing = set(codes) - named
# The last code is the fall-through and is deliberately not compared by name.
if len(missing) > 1:
    fails.append("procRefuse does not name %s" % ", ".join(sorted(missing)))

# The sentences must be DISTINCT. Two codes with one sentence is one refusal
# wearing two numbers.
syms = {}
out = subprocess.run(["x86_64-elf-readelf", "-sW", sys.argv[2]],
                     capture_output=True, text=True).stdout
for line in out.splitlines():
    f = line.split()
    if len(f) >= 8 and f[7].startswith("procStrE"):
        syms[f[7]] = int(f[2])
seen = {}
for name, length in tables:
    if name not in syms:
        fails.append("%s is not in kmain.o" % name)
        continue
    if syms[name] != int(length):
        fails.append("%s is %d bytes but procRefuse passes %s" % (name, syms[name], length))
    if name in seen:
        fails.append("%s is used for two different refusal codes" % name)
    seen[name] = True

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d refusal codes, %d distinct sentences, every code returned "
      "somewhere)" % (len(codes), len(seen)))
PY
echo "STRUCTURAL: pass  every proc refusal code is reachable from a return and has its own distinct sentence"

# 3h. THE BOOT STUB PROBES BEFORE IT WRITES, AND WRITES THE RIGHT BITS.
#
# CR4 bits 9 and 10 are RESERVED on a CPU without SSE, and writing a reserved
# CR4 bit is a #GP -- which, before any IDT exists, is a triple fault and a
# silently rebooting VM with no output at all. That is the M8 incident
# `nx_flag` records, and it is why this is asserted on the SOURCE as well as
# proved by boot C.
BOOT="$CORE_DIR/boot/boot.S"
grep -qE 'testl \$\(1 << 24\), %edx' "$BOOT" || fail "boot.S does not test CPUID leaf 1 EDX bit 24 (FXSR) — the CR4 write would be unconditional"
grep -qE 'testl \$\(1 << 25\), %edx' "$BOOT" || fail "boot.S does not test CPUID leaf 1 EDX bit 25 (SSE)"
grep -qE 'orl +\$0x600, %eax' "$BOOT" || fail "boot.S never sets CR4 bits 9 and 10 (OSFXSR | OSXMMEXCPT) — GAP-0092 is not closed"
grep -qE 'orl +\$0x00000002, %eax' "$BOOT" || fail "boot.S never sets CR0.MP (bit 1)"
grep -qE 'andl +\$0xFFFFFFFB, %eax' "$BOOT" || fail "boot.S never clears CR0.EM (bit 2) — with EM set every SSE instruction is a #UD whatever CR4 says"
grep -qE '^\s*fninit' "$BOOT" || fail "boot.S never executes fninit — a process's save area is built from a KNOWN x87 state and this is where it becomes known"
# The three writes and the fninit must each be GUARDED. Counted rather than
# eyeballed: `sse_flag` is compared four times, once before each.
GUARDS=$(grep -cE '^\s*(cmpl|cmpq) +\$0, sse_flag' "$BOOT")
[[ "$GUARDS" -eq 3 ]] || fail "boot.S compares sse_flag $GUARDS time(s), expected 3 (before the CR4 write, before the CR0 write, and before fninit). An unguarded one is a #GP or a #UD on a CPU without SSE."
# ...and the probe has to come BEFORE the CR4 write, not merely exist.
PROBE_LINE=$(grep -nE 'movl +\$1, sse_flag' "$BOOT" | head -1 | cut -d: -f1)
CR4_LINE=$(grep -nE 'orl +\$0x600, %eax' "$BOOT" | head -1 | cut -d: -f1)
[[ -n "$PROBE_LINE" && -n "$CR4_LINE" && "$PROBE_LINE" -lt "$CR4_LINE" ]] \
  || fail "boot.S writes CR4's SSE bits at line ${CR4_LINE:-?} but does not set sse_flag until line ${PROBE_LINE:-?} — the probe must come first"
echo "STRUCTURAL: pass  boot.S probes CPUID leaf 1 for FXSR and SSE before it writes CR4, and all three of the CR4 write, the CR0 write and fninit are guarded by the answer"

# 3i. THE TWO INSTRUCTIONS THAT SAVE AND RESTORE, AND NOTHING ELSE IN THE
#     KERNEL, TOUCH AN XMM REGISTER.
#
# This is the load-bearing assumption behind saving EAGERLY BUT LATE:
# `procYield` calls `fx_save` after `isr_common`, `userSyscall` and its own
# bookkeeping have already run. That is only safe because none of that code can
# have modified an XMM register in the meantime. `dcc` emits integer code only
# and every line of assembly here is hand-written, so the claim is true -- and
# this is what makes it CHECKED rather than believed.
grep -qE '^\s*fxsave \(%rdi\)' "$CORE_DIR/boot/isr.S" || fail "isr.S has no `fxsave (%rdi)` — fx_save is what makes a process's FPU state its own"
grep -qE '^\s*fxrstor \(%rdi\)' "$CORE_DIR/boot/isr.S" || fail "isr.S has no `fxrstor (%rdi)`"
XMM_IN_KERNEL=$(x86_64-elf-objdump -d "$KERNEL_ELF" | grep -cE '%(x|y|z)mm[0-9]')
[[ "$XMM_IN_KERNEL" -eq 0 ]] || fail "the linked kernel contains $XMM_IN_KERNEL instruction(s) naming an %xmm register. proc.dart saves a process's FPU state AFTER several hundred instructions of kernel code have already run (procYield); that is only correct while the kernel itself never touches one. See ADR-0015 §2."
echo "STRUCTURAL: pass  isr.S has fxsave and fxrstor, and the whole linked kernel names an %xmm register in exactly 0 instructions — which is what makes saving late safe"

# 3j. THE SAVED FRAME IS THE ONE isr_common BUILDS.
#
# proc.dart copies 22 words wholesale and patches exactly one of them by index
# (`procFrameRaxWord`). Both numbers are derived here from user.dart's own byte
# offsets rather than trusted, because a frame that is one word short would
# silently drop SS -- and the process would resume with a stack segment
# selector nobody chose.
USER_FRAME_WORDS=$(dartconst userFrameWords user.dart)
USER_FRAME_RAX=$(dartconst userFrameRax user.dart)
PROC_FRAME_RAX_WORD=$(dartconst procFrameRaxWord proc.dart)
[[ -n "$USER_FRAME_WORDS" ]] || USER_FRAME_WORDS=$PROC_FRAME_WORDS
[[ "$PROC_FRAME_WORDS" -eq 22 ]] || fail "proc.dart says the interrupt frame is $PROC_FRAME_WORDS words; isr_common pushes 15 registers, a vector, an error code and the CPU's five = 22"
[[ $(( PROC_FRAME_RAX_WORD * 8 )) -eq "$USER_FRAME_RAX" ]] || fail "proc.dart patches word $PROC_FRAME_RAX_WORD of the saved frame as RAX, but user.dart says RAX is at byte offset $USER_FRAME_RAX (word $(( USER_FRAME_RAX / 8 )))"
echo "STRUCTURAL: pass  the 22-word saved frame and the RAX word proc.dart patches are both derived from user.dart's own offsets"

# ---------------------------------------------------------------------------
# Step 4 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# M11 added FIVE new externs, 53 -> 58, and that was a claim about the design:
# `sse_enabled` and `cr4_read` are the two ways to ask the machine what
# happened, `fx_save` and `fx_restore` are the two instructions DCDart cannot
# emit, and `proc_store_addr` was the storage seam. A process table, a scheduler
# and a second address space needed no assembly at all beyond those.
#
# M17 (ADR-0021) DELETED THE FIFTH. `procStore` is a DCDart `@bss` mutable
# static, so the seam needs no symbol from assembly: 44 = 40 through M10 plus
# M11's remaining FOUR, and the four instructions above are still the whole of
# what a process table needs assembly for.
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
# M15 (ADR-0019) added exactly ONE: `fileStore`, the file-descriptor
# table's storage seam. Subtracted for the same reason every block above is.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bfile_store_addr\b" <<<"$VERIFY_OUT" && fail "file_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fileStore"
M15_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M15_PRESENT ))
# M14 added exactly ONE: `fatStore`, the filesystem's storage seam.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && fail "fat_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fatStore"
M14_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
# M17 (ADR-0021) deleted 14 `_addr()` accessor externs at or before this
# milestone, because the assembly-donated `.bss` they addressed became DCDart
# `@bss` mutable statics. M10's 53 becomes 40 and M11's own five become four.
# Each deleted name is asserted ABSENT as well as the count being asserted: a
# count alone can be restored by an unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr vm_store_addr user_store_addr \
            elf_store_addr proc_store_addr; do
  grep -q "\\b$gone\\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
[[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 (40 from M10 after ADR-0021 plus M11's four: sse_enabled, cr4_read, fx_save, fx_restore)"
for sym in sse_enabled cr4_read fx_save fx_restore; do
  grep -qE "\b$sym\b" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest"
done
# M11's fifth was `proc_store_addr` (asserted absent above). What it addressed is
# now `procStore`, the 4224-byte @bss block asserted at check 3a.
[[ "$(bsssize procStore)" == "4224" ]] || fail "procStore is not a 4224-byte object in kmain.o's .bss — M11's process table did not survive the ADR-0021 migration, or M18's scheduler header did not land in it"
grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — 40 from M10 plus exactly four (M11's fifth, proc_store_addr, is gone with ADR-0021), and kdata.o still passes standalone"

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
  port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 300 qemu-system-x86_64 \
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

# A shell line as a key list. The LBAs come from make-image.py's own layout, so
# nothing here is a number typed twice.
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# BOOT A — the driven session.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,p,r,o,c,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc run $LBA_A $LBA_B"),ret,wait:4000"
SESSION_KEYS="$SESSION_KEYS,p,r,o,c,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc run $LBA_A $LBA_A"),ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc cross $LBA_A $LBA_B"),ret,wait:4000"
SESSION_KEYS="$SESSION_KEYS,p,r,o,c,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:800"

SHOT_PNG="$CORE_DIR/build/screenshot-proc.png"
rm -f "$SHOT_PNG"
drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 70 128M qemu64

SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"

if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"
  cp "$SCREEN_TEXT" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL and $EXPECTED_SCREEN — the derived checks below still have to pass"
fi

[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# BOOT B — both processes left alive, and the memory read out from under them.
#
# The dump is anchored at the FIRST `FX` address the kernel prints, which is
# slot 0's FPU save area inside `proc_store` -- an address the KERNEL chose and
# printed, not one this harness assumed. 32768 quadwords from there covers the
# four FXSAVE areas, the kernel's own six page-table frames, and every frame
# both processes' address spaces were built out of. A walk that needed a byte
# outside it RAISES rather than reading zero (derive.py's `Memory`).
# `proc coop`, NOT `proc run`, AND M18 IS WHY.
#
# `proc run` became a PREEMPTIVE session at M18 (ADR-0022): a process that holds
# is taken off the CPU after one quantum and the other one resumes, which is the
# milestone working and is exactly what this boot must not have. Everything
# below needs a process PARKED at its entry point with the OTHER one suspended
# and both address spaces live, and a preemptive scheduler abolishes that state.
#
# `proc coop` is the one command that keeps M11's semantics, it is named for
# them, and it prints exactly the same lines -- so every regex in this section
# is unchanged. `m18-preempt/run.sh` uses the same command as its NEGATIVE
# CONTROL and requires it to hang, which is the other half of the same claim.
HOLD_KEYS="$(typekeys "proc coop $LBA_A $LBA_BHOLD"),ret,wait:3000"
drive_session "$WORKDIR/hold" "$HOLD_KEYS" "$WORKDIR/hold/shot.png" "hold" 80 128M qemu64 \
  --addr-from-serial ' FX ([0-9A-F]{16})' \
  --monitor-command 'info registers' \
  --monitor-command 'xp/32768gx {addr}' \
  --monitor-capture "$WORKDIR/hold/monitor.txt"

# BOOT C — a CPU with no SSE and no FXSAVE.
NOSSE_KEYS="p,r,o,c,ret,wait:800,$(typekeys "proc run $LBA_A $LBA_B"),ret,wait:1500"
drive_session "$WORKDIR/nosse" "$NOSSE_KEYS" "$WORKDIR/nosse/shot.png" "no-SSE" 90 128M "qemu64,-sse,-fxsr"

# BOOT D — no frames.
NOMEM_KEYS="$(typekeys "frames drain"),ret,wait:2500,$(typekeys "proc run $LBA_A $LBA_B"),ret,wait:1500"
drive_session "$WORKDIR/nomem" "$NOMEM_KEYS" "$WORKDIR/nomem/shot.png" "drained" 100 128M qemu64

# BOOT E and BOOT F — A CPU THAT HAS SMEP, AND ONE THAT HAS SMEP AND SMAP.
# GAP-0153 / docs/decisions/0025-smep.md.
#
# THIS HARNESS OWNS THE CR4 LINE, which is why the two boots are here and not in
# m8-paging: `procSseLine` is what prints CR4, and BOOT C above is already the
# negative control for a guarded CR4 write. Every other boot in this repo runs
# plain `qemu64`, which reports `smep=false`, so the probe finds nothing and CR4
# stays 0x620.
#
# THAT IS NOT THE SAME AS "NO GOLDEN MOVES", and the difference matters. The CR4
# VALUE does not move. The 48 bytes of `.text` the probe costs DO move
# `.text_end`, and m8-paging, m9-ring3 and m10-elf each print a `VM SECT` line
# carrying it, so all three goldens moved and were regenerated. Any change that
# adds an instruction to this kernel moves them.
#
# The two boots are a PAIR and the second is the one that is easy to leave out.
# BOOT E says the probe works and the bit reaches CR4. BOOT F says that on a CPU
# which has SMAP as well, CR4 comes back with SMEP and WITHOUT SMAP — so the
# decision not to enable SMAP (ADR-0025 §3: four sites dereference a ring-3
# VIRTUAL address at CPL=0 and every one would #PF) is a mechanically checked
# property of this kernel rather than a sentence in a document. Without BOOT F,
# a probe that quietly set both bits would pass everything here.
#
# Both run `proc run`, not just `proc`: a ring-3 program has to still work with
# the bit on, and the two processes' whole session is the check that it does.
SMEP_KEYS="p,r,o,c,ret,wait:800,$(typekeys "proc run $LBA_A $LBA_B"),ret,wait:2500"
drive_session "$WORKDIR/smep" "$SMEP_KEYS" "$WORKDIR/smep/shot.png" "smep" 110 128M "qemu64,+smep"
drive_session "$WORKDIR/smepsmap" "$SMEP_KEYS" "$WORKDIR/smepsmap/shot.png" "smep+smap" 120 128M "qemu64,+smep,+smap"

# ---------------------------------------------------------------------------
# Step 6 — assert.
# ---------------------------------------------------------------------------

# 6a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M11 changed M0/M1 serial output. procInit() and the SSE probe must both print NOTHING."
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 6b. The whole serial capture.
if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL_CAPTURE") | head -60 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 6c. BOTH PROGRAMS RAN, AND EVERY EXPECTATION COMES OUT OF THE TWO BINARIES.
if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$PROG_A" "$PROG_B" "$LAYOUT_JSON" <<'PY'
import importlib.util, json, re, sys

cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("m11_derive", sys.argv[2])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
a = D.Elf(open(sys.argv[3], "rb").read())
b = D.Elf(open(sys.argv[4], "rb").read())
layout = json.load(open(sys.argv[5]))
fails = []

def blob_sum(elf):
    """The checksum progX.c computes over the 64 bytes its SSE copy moved,
    read out of the FILE. If the copy did not happen, or happened wrong, the
    exit status below is a different number."""
    value, size = elf.sym("srcBlob")
    raw = elf.read(value, size)
    if raw is None or len(raw) != 64:
        raise SystemExit("srcBlob is not 64 file-backed bytes in %s" % elf)
    return sum(int.from_bytes(raw[i:i + 8], "little") for i in range(0, 64, 8)) % (1 << 64)

for name, elf, tag in (("A", a, "A"), ("B", b, "B")):
    # 1. The message is the bytes at its own `msg` symbol.
    msg = elf.sym_cstr("msg").decode("latin-1")
    want = "USER WRITE %s\n" % msg
    if cap.count(want) < 1:
        fails.append("prog%s's `msg` symbol holds %r and the capture never shows "
                     "`%s`" % (name, msg, want.strip()))
    # 2. The entry point is the e_entry in the file.
    if "ENTRY %016X" % elf.e_entry not in cap:
        fails.append("prog%s's e_entry is 0x%X and no `ENTRY %016X` appears in the "
                     "capture" % (name, elf.e_entry, elf.e_entry))
    # 3. The exit status is derived: .rodata word + .data word + the SSE copy's
    #    checksum + one per XMM register that came back wrong (must be zero).
    want_code = (elf.sym_u64("exitStatus") + elf.sym_u64("dataWord")
                 + blob_sum(elf)) % (1 << 64)
    if "CODE %016X" % want_code not in cap:
        got = re.findall(r"PROC EXIT SLOT \d\d ID \w{8} CODE (\w{16}) ", cap)
        fails.append("prog%s should exit with 0x%016X — its own exitStatus + dataWord "
                     "+ the checksum of the 64 bytes its SSE struct copy moved, all "
                     "read out of the ELF — and the capture shows %s. A difference of "
                     "a small number is XMM registers that did not survive a switch; "
                     "a large one is a loader problem."
                     % (name, want_code, got))
    # 4. The page count the kernel reported is the one the ELF's own p_memsz
    #    implies, plus one stack page.
    want_pages = len(elf.pages()) + 1
    if not re.search(r"PAGES %08X FX " % want_pages, cap):
        fails.append("prog%s's program headers plus a stack page need %d pages and no "
                     "`PAGES %08X` appears" % (name, want_pages, want_pages))

# 5. THE PER-PROCESS FPU CLAIM, from the programs' own report.
#    Each program prints the low 64 bits of XMM0 after every yield. The value
#    must be its OWN signature, doubled (pshufd broadcasts the low 32 bits), and
#    never the other program's.
xmm = re.findall(r"USER WRITE ([AB]) XMM (\d) ([0-9A-F]{16}) (..)\n", cap)
if len(xmm) != 6:
    fails.append("expected 6 XMM report lines (3 from each process), got %d" % len(xmm))
sigs = {}
for tag, _, val, ok in xmm:
    sigs.setdefault(tag, set()).add(val)
    if ok != "OK":
        fails.append("process %s came back from a yield with XMM0=%s and reported "
                     "`%s` — its FPU state did not survive the switch" % (tag, val, ok))
if len(sigs) == 2:
    va, vb = sigs.get("A", set()), sigs.get("B", set())
    if len(va) != 1 or len(vb) != 1:
        fails.append("a process reported more than one XMM0 value across its yields: "
                     "A=%s B=%s" % (sorted(va), sorted(vb)))
    if va & vb:
        fails.append("processes A and B reported the SAME XMM0 value %s — that is one "
                     "FPU state shared by two processes" % sorted(va & vb))

# 6. EVERY SWITCH IS ACCOUNTED FOR, AND M18 ADDED THE THIRD TERM.
#
#    Until M18 this read `switches == yields + surviving exits`, and its stated
#    reason was that those were the only two things that could switch a process:
#    "there is no preemption (GAP-0097), and a number that does not add up would
#    be the first sign of one." There IS preemption now, so the identity gets
#    the term it was missing rather than being deleted:
#
#        switches == yields + surviving exits + preemptions
#
#    and the preemption count is not taken from the kernel's own counter but
#    COUNTED OUT OF THE LOG, one `PROC PREEMPT` line at a time. That keeps the
#    check falsifiable from two directions at once: a kernel that switched
#    without printing fails it, and so does one that printed without switching.
#
#    In THIS harness's sessions the third term must be zero, and that is a claim
#    about arithmetic rather than about hope: `proc run` IS preemptive at M18,
#    but a quantum is eight 10 ms ticks of ring-3 time and M11's programs reach
#    a `yield` within a few thousand instructions, so a slice here never
#    survives one tick, let alone eight. If that ever stops being true this
#    check fails loudly instead of the golden silently drifting.
for block in cap.split("oscortex> "):
    if "PROC END SWITCHES" not in block:
        continue
    yields = len(re.findall(r"^PROC YIELD \d\d -> \d\d ", block, re.M))
    preempts = len(re.findall(r"^PROC PREEMPT \d\d -> \d\d ", block, re.M))
    exits = re.findall(r"^PROC EXIT SLOT \d\d ID \w{8} CODE \w{16} LEFT (\w{8})\n", block, re.M)
    survivors = sum(1 for left in exits if int(left, 16) > 0)
    end = re.search(r"^PROC END SWITCHES (\w{8}) EXITS (\w{8}) ", block, re.M)
    total = int(end.group(1), 16)
    if preempts:
        fails.append("a session in this harness performed %d INVOLUNTARY switch(es). "
                     "M11's 4096-byte golden is an interleaving only a scheduler that "
                     "did not preempt produces; a quantum is %d ticks of ring-3 time "
                     "and these programs yield within microseconds, so this should be "
                     "arithmetically impossible. See ADR-0022 on the quantum."
                     % (preempts, 8))
    if total != yields + survivors + preempts:
        fails.append("a session reports %d switches but %d yields, %d exits with a "
                     "survivor and %d preemptions. Every switch this kernel performs is "
                     "one of those three things, and a number that does not add up is "
                     "the first sign of a fourth."
                     % (total, yields, survivors, preempts))
    if int(end.group(2), 16) != len(exits):
        fails.append("a session reports %s exits and shows %d PROC EXIT lines"
                     % (end.group(2), len(exits)))

# 7. The two programs are at the LBAs make-image.py chose, and the kernel was
#    told those and no others.
for name in ("A", "B"):
    lba = layout[name]["header_lba"]
    if "ELF DISK LBA %08X IMAGE %08X " % (lba, lba + 1) not in cap:
        fails.append("no `ELF DISK LBA %08X` in the capture — the kernel was not told "
                     "where make-image.py put prog%s" % (lba, name))

# 8. The negative control faulted, at the address the KERNEL computed.
m = re.search(r"^PROC PROBE VA ([0-9A-F]{16})\n", cap, re.M)
if not m:
    fails.append("`proc cross` never printed a probe address")
else:
    va = int(m.group(1), 16)
    if va == 0:
        fails.append("procCrossVa found no page A has and B has not, so the isolation "
                     "probe was refused rather than run. The two programs must map "
                     "different page sets -- see progA.c's crossPage.")
    if "PF CR2 %016X ERR 00000004 NOTPRES READ USER DATA\n" % va not in cap:
        fails.append("process B did not take a not-present USER read fault at 0x%016X, "
                     "the address the kernel itself said A had and B did not" % va)
    if "B READ" in cap:
        fails.append("process B PRINTED the quadword it read from A's page. The read "
                     "succeeded; the two address spaces are one.")

if fails:
    print("--- derived checks ---", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (two programs, %d ELF-derived expectations each, 6 XMM reports, "
      "switches == yields + surviving exits in every session)" % 4)
PY
then
  fail "the serial capture does not match what the two ELF files say should have happened"
fi
echo "ASSERT: pass  both programs ran; every message, entry point, page count and exit status was DERIVED from its own ELF; each process's XMM0 came back its own and never the other's; and every switch is accounted for by a yield or an exit"

# 6d. THE TWO ADDRESS SPACES, READ OUT OF GUEST PHYSICAL MEMORY, WITH BOTH
#     PROCESSES ALIVE.
#
# Everything below is walked from the two PML4 frames the KERNEL printed, in a
# region of guest RAM dumped at an address the KERNEL printed, while the CPU is
# at CPL 3 inside process B. Nothing here is an address this harness chose.
if ! python3 - "$WORKDIR/hold/serial.txt" "$WORKDIR/hold/monitor.txt" "$DERIVE" \
     "$PROG_A" "$PROG_BHOLD" <<'PY'
import importlib.util, re, sys

ser = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("m11_derive", sys.argv[3])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
a_elf = D.Elf(open(sys.argv[4], "rb").read())
b_elf = D.Elf(open(sys.argv[5], "rb").read())
fails = []

def one(pattern, what):
    m = re.search(pattern, ser, re.M)
    if not m:
        raise SystemExit("the hold boot never printed %s (pattern %r)" % (what, pattern))
    return int(m.group(1), 16)

fx0 = one(r" FX ([0-9A-F]{16})", "a slot's FXSAVE area address")
pml4_a = one(r"PROC NEW SLOT 00 ID [0-9A-F]{8} PML4 ([0-9A-F]{16}) ", "process A's PML4")
pml4_b = one(r"PROC NEW SLOT 01 ID [0-9A-F]{8} PML4 ([0-9A-F]{16}) ", "process B's PML4")
pt_a = one(r"PROC NEW SLOT 00 PT ([0-9A-F]{16}) ", "process A's page table")
pt_b = one(r"PROC NEW SLOT 01 PT ([0-9A-F]{16}) ", "process B's page table")
kpml4 = one(r"KPML4 ([0-9A-F]{16})", "the kernel's PML4")

if pml4_a == pml4_b:
    fails.append("both processes report the same PML4 frame 0x%X — there is one "
                 "address space, not two" % pml4_a)
if pt_a == pt_b:
    fails.append("both processes report the same window page table 0x%X" % pt_a)
for name, f in (("A's PML4", pml4_a), ("B's PML4", pml4_b)):
    if f == kpml4:
        fails.append("%s is the KERNEL's PML4 0x%X — the process did not get its own"
                     % (name, kpml4))

regs = D.parse_registers(mon)
if regs.get("CPL") != 3:
    fails.append("the CPU is at CPL %s, not 3 — nothing was running in ring 3 when "
                 "the tables were dumped" % regs.get("CPL"))
if regs.get("CR3") != pml4_b:
    fails.append("CR3 is 0x%X but the process that should be on the CPU (slot 1) has "
                 "PML4 0x%X. A switch that does not change CR3 is not a switch of "
                 "address space." % (regs.get("CR3", 0), pml4_b))
if regs.get("RIP") != b_elf.e_entry:
    fails.append("RIP is 0x%X, and prog-Bhold.elf's e_entry is 0x%X — the held "
                 "process is not sitting where its own ELF header says it starts"
                 % (regs.get("RIP", 0), b_elf.e_entry))
if regs.get("CR4", 0) & 0x600 != 0x600:
    fails.append("CR4 is 0x%X: bits 9 (OSFXSR) and 10 (OSXMMEXCPT) are not both set"
                 % regs.get("CR4", 0))
if regs.get("CR0", 0) & 0x4:
    fails.append("CR0.EM (bit 2) is set — every SSE instruction is a #UD whatever "
                 "CR4 says")
if not regs.get("CR0", 0) & 0x2:
    fails.append("CR0.MP (bit 1) is clear")

qwords = D.parse_xp(mon, "xp/32768gx 0x%016X" % fx0)
mem = D.Memory().add(fx0, qwords)
ta = D.PageTables(pml4_a, mem)
tb = D.PageTables(pml4_b, mem)
tk = D.PageTables(kpml4, mem)

# Each address space on its own must satisfy everything M10 asserted about one.
for name, t, e in (("A", ta, a_elf), ("B", tb, b_elf)):
    for f in D.check_program_pages(t, e):
        fails.append("process %s: %s" % (name, f))

# THE ISOLATION CLAIM.
iso, private, shared = D.check_isolation(ta, tb, a_elf, b_elf)
fails.extend(iso)

# The kernel is SHARED, at the same frames, and still supervisor-only in both.
fails.extend(D.check_kernel_shared(
    ta, tb, [0x100000, 0x200000, 0x400000, 0x1000000, 0x7000000]))
for name, t in (("A", ta), ("B", tb)):
    fails.extend(D.check_supervisor(t, 0x100000, 0x140000, "process %s's view of the kernel image" % name))

# The kernel's OWN address space must have no program window at all: M10's
# `run` installs one there and M11's processes must not.
leftover = tk.mapped_pages(D.PROG_BASE, D.PROG_END)
if leftover:
    fails.append("the kernel's own address space maps %d page(s) of the program "
                 "window, first at 0x%X — a process's pages leaked into it"
                 % (len(leftover), leftover[0]))

# THE FPU STATE, READ OUT OF RAM.
#
# Slot 0 is process A, suspended inside a `yield`: `fx_save` has run, so its
# 512-byte area must hold ITS OWN signature in XMM0 and XMM7, in all four
# lanes. Slot 1 is process B, on the CPU: nothing has been saved into its area,
# so it must NOT hold A's. Slots 2 and 3 have never held a process and must
# still be the legal, zeroed image `procFxInit` wrote.
SIG_A = 0xA1A2A3A4
for s in range(D.PROC_MAX):
    base = fx0 + s * D.PROC_FX_BYTES
    f, cw, mxcsr = D.check_fx_area(mem, base)
    fails.extend("FXSAVE area %d: %s" % (s, x) for x in f)
    if cw != D.FX_CW_INIT:
        fails.append("FXSAVE area %d has x87 control word 0x%04X, expected 0x%04X"
                     % (s, cw, D.FX_CW_INIT))
    if mxcsr != D.FX_MXCSR_INIT:
        fails.append("FXSAVE area %d has MXCSR 0x%08X, expected 0x%08X"
                     % (s, mxcsr, D.FX_MXCSR_INIT))

def xmm(base, n):
    lo = mem.qword(base + 160 + n * 16)
    hi = mem.qword(base + 160 + n * 16 + 8)
    return (hi << 64) | lo

want_a = int(("%08X" % SIG_A) * 4, 16)
for n in (0, 7):
    got = xmm(fx0, n)
    if got != want_a:
        fails.append("process A is suspended in a yield and its saved XMM%d is "
                     "0x%032X, not its own signature 0x%032X. `fx_save` did not "
                     "capture it, or captured somebody else's." % (n, got, want_a))
    other = xmm(fx0 + D.PROC_FX_BYTES, n)
    if other == want_a:
        fails.append("process B's FXSAVE area holds process A's XMM%d signature — "
                     "one FPU state is being written into two slots" % n)
for s in (2, 3):
    base = fx0 + s * D.PROC_FX_BYTES
    for n in (0, 7):
        if xmm(base, n) != 0:
            fails.append("slot %d has never held a process but its XMM%d is not zero "
                         "— procFxInit did not clear it" % (s, n))

if fails:
    print("--- page tables and FPU state, read out of guest memory ---", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (A: PML4 0x%X PT 0x%X, %d pages; B: PML4 0x%X PT 0x%X, %d pages; "
      "%d page(s) private to A and absent from B (%s); %d virtual address(es) "
      "mapped by both and backed by different frames; %d qwords of guest RAM read)"
      % (pml4_a, pt_a, len(a_elf.pages()) + 1, pml4_b, pt_b, len(b_elf.pages()) + 1,
         len(private), ", ".join(hex(x) for x in private), len(shared), len(qwords)))
PY
then
  fail "the two address spaces read out of guest physical memory are not two"
fi
echo "ASSERT: pass  with both processes alive and the CPU at CPL 3 inside B, the LIVE page tables were walked from BOTH PML4 frames: A's private pages are absent from B's, every address both map is a different physical frame, the kernel is the same frame in both and supervisor-only in both, and A's suspended XMM0/XMM7 hold A's own signature while B's save area does not"

# 6e. NEGATIVE CONTROL — A CPU WITH NO SSE.
#
# This boot is the evidence that the CPUID probe in boot.S is load-bearing.
# TWO independent things are asserted, because on this emulator only one of
# them fires (GAP-0099): M1's golden must still be a byte-exact prefix — on
# real hardware an unguarded CR4 write is a reserved-bit #GP with no IDT and
# therefore NO OUTPUT AT ALL — and CR4 must read back EXACTLY 0x20, which is
# what actually caught the deleted guard under QEMU, at 0x420.
if ! python3 - "$WORKDIR/nosse/serial.txt" "$M1_EXPECTED" <<'PY'
import re, sys
cap = open(sys.argv[1], "rb").read()
m1 = open(sys.argv[2], "rb").read()
fails = []
if not cap.startswith(m1):
    fails.append("the kernel did not reach the end of M1's output on a CPU without "
                 "SSE. If it produced nothing at all, the CR4 write is not guarded "
                 "and a reserved-bit #GP triple-faulted the machine before any IDT "
                 "existed.")
text = cap.decode("latin-1")
m = re.search(r"^PROC SSE (\d) CR4 ([0-9A-F]{16}) CR0 ([0-9A-F]{16})\n", text, re.M)
if not m:
    fails.append("no `PROC SSE` line in the no-SSE capture")
else:
    flag, cr4, cr0 = int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16)
    if flag != 0:
        fails.append("boot.S reported SSE %d on a CPU built without SSE or FXSR" % flag)
    if cr4 != 0x20:
        fails.append("CR4 is 0x%X on the no-SSE machine, expected exactly 0x20 (PAE "
                     "alone). Any other bit is one this kernel set on a CPU that does "
                     "not have it." % cr4)
    if cr0 & 0x2:
        fails.append("CR0.MP is set on a CPU with no FPU support enabled")
if "PROC REFUSED 07 this CPU has no FXSAVE, so a process cannot own FPU state\n" not in text:
    fails.append("`proc run` did not refuse with code 07 on a CPU with no FXSAVE. "
                 "Running a process there would mean two things sharing FPU registers "
                 "with nowhere to save them, which is GAP-0092's argument read from "
                 "the other end.")
if "PROC NEW SLOT" in text:
    fails.append("a process was CREATED on a CPU with no FXSAVE")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (SSE 0, CR4 exactly 0x20, `proc run` refused 07, no process created, and "
      "the machine still reached an interactive shell)")
PY
then
  fail "the no-SSE boot did not behave as a kernel that probes CPUID before writing CR4 must"
fi
echo "ASSERT: pass  on -cpu qemu64,-sse,-fxsr the kernel still boots to a shell, reports SSE 0 with CR4 exactly 0x20, and REFUSES to create a process by name — which is what proves the CPUID probe is load-bearing rather than decorative"

# 6f. NEGATIVE CONTROL — no frames.
if ! python3 - "$WORKDIR/nomem/serial.txt" <<'PY'
import re, sys
text = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if not re.search(r"^PMM DRAIN NEXT 0000000000000000 FREE 00000000\n", text, re.M):
    fails.append("`frames drain` did not empty the allocator, so this control did not "
                 "test what it claims to")
if "PROC REFUSED 04 " not in text:
    fails.append("`proc run` did not refuse with code 04 (out of frames) on a drained "
                 "allocator")
if "PROC START SLOT" in text:
    fails.append("a process was STARTED with no frames available")
# A refused create must leave nothing behind: the slot is emptied by procCleanup
# on the failing path, so the table must still report zero live.
if not re.search(r"^PROC END SWITCHES 00000000 EXITS 00000000 CREATED \w{8} LIVE 00000000\n", text, re.M):
    fails.append("the drained session did not end with LIVE 00000000 — a half-built "
                 "address space was left in the table")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (allocator drained to zero, `proc run` refused 04, nothing started, "
      "nothing left live)")
PY
then
  fail "the drained-allocator boot did not refuse cleanly"
fi
echo "ASSERT: pass  with every frame allocated, proc run refuses by name and leaves no half-built address space in the table"

# 6f-smep. SMEP IS SET WHEN THE CPU HAS IT, AND SMAP IS NOT SET EVEN WHEN IT DOES.
#          GAP-0153, docs/decisions/0025-smep.md.
if ! python3 - "$WORKDIR/smep/serial.txt" "$WORKDIR/smepsmap/serial.txt" \
              "$SERIAL_CAPTURE" "$M1_EXPECTED" <<'PY'
import re, sys
smep = open(sys.argv[1], "rb").read()
both = open(sys.argv[2], "rb").read()
plain = open(sys.argv[3], "rb").read().decode("latin-1")
m1 = open(sys.argv[4], "rb").read()
fails = []

CR4_SMEP = 1 << 20
CR4_SMAP = 1 << 21
BASE = 0x620          # PAE | OSFXSR | OSXMMEXCPT, this kernel on a qemu64


def cr4_of(cap, label):
    if not cap.startswith(m1):
        fails.append("the %s boot did not reach the end of M1's output. An "
                     "unguarded CR4 write is a reserved-bit #GP with no IDT, "
                     "which is a triple fault and NO OUTPUT AT ALL." % label)
        return None
    m = re.search(r"^PROC SSE (\d) CR4 ([0-9A-F]{16}) CR0 [0-9A-F]{16}\n",
                  cap.decode("latin-1"), re.M)
    if not m:
        fails.append("no `PROC SSE` line in the %s capture" % label)
        return None
    if int(m.group(1)) != 1:
        fails.append("the %s boot reported SSE 0; it was launched with SSE" % label)
    return int(m.group(2), 16)


# The control: the ordinary boot, on plain qemu64, must have NEITHER bit. This
# is the line that makes the two below mean something -- without it, "CR4 has
# bit 20 on a +smep machine" is equally consistent with "this kernel always
# sets bit 20", which would be a reserved-bit #GP on most of the world's CPUs.
m = re.search(r"^PROC SSE 1 CR4 ([0-9A-F]{16}) CR0 [0-9A-F]{16}\n", plain, re.M)
if not m:
    fails.append("no `PROC SSE` line in the main capture")
else:
    cr4 = int(m.group(1), 16)
    if cr4 != BASE:
        fails.append("CR4 is 0x%X on plain -cpu qemu64 and must be exactly 0x%X. "
                     "qemu64 reports smep=false and smap=false, so a kernel that "
                     "probes CPUID before writing CR4 sets NEITHER bit here -- and "
                     "every golden in this repo was recorded with this value."
                     % (cr4, BASE))

cr4_smep = cr4_of(smep, "+smep")
if cr4_smep is not None:
    if not (cr4_smep & CR4_SMEP):
        fails.append("CR4 is 0x%X on -cpu qemu64,+smep: bit 20 (SMEP) is NOT set, so "
                     "the CPUID leaf-7 probe in boot.S found nothing on a CPU that "
                     "has the feature." % cr4_smep)
    if cr4_smep & CR4_SMAP:
        fails.append("CR4 is 0x%X on -cpu qemu64,+smep: bit 21 (SMAP) is set on a CPU "
                     "that does not have SMAP. That is a reserved bit." % cr4_smep)
    if cr4_smep != BASE | CR4_SMEP:
        fails.append("CR4 is 0x%X on -cpu qemu64,+smep, expected exactly 0x%X"
                     % (cr4_smep, BASE | CR4_SMEP))

cr4_both = cr4_of(both, "+smep,+smap")
if cr4_both is not None:
    # THE ASSERTION THAT IS EASY TO LEAVE OUT AND IS THE POINT OF THIS BOOT.
    # SMAP is deliberately NOT enabled: this kernel dereferences a ring-3
    # VIRTUAL address at CPL=0 in four places (user.dart:1393, file.dart:1398,
    # file.dart:975, file.dart:811) and every one of them would #PF with SMAP
    # on. Without this line, "we chose not to" is a sentence in an ADR and a
    # probe that quietly set both bits would pass everything else here.
    if cr4_both & CR4_SMAP:
        fails.append("CR4 is 0x%X on -cpu qemu64,+smep,+smap: bit 21 (SMAP) is SET. "
                     "It must not be. Four sites in this kernel read or write a "
                     "ring-3 virtual address at CPL=0 and every one of them faults "
                     "with SMAP on -- open() would #PF inside the kernel on the "
                     "first syscall m15-fileio makes. See ADR-0025 section 3."
                     % cr4_both)
    if cr4_both != BASE | CR4_SMEP:
        fails.append("CR4 is 0x%X on -cpu qemu64,+smep,+smap, expected exactly 0x%X"
                     % (cr4_both, BASE | CR4_SMEP))

# AND RING 3 STILL WORKS WITH THE BIT ON. A CR4 bit that is set and breaks the
# machine would satisfy every assertion above.
for cap, label in ((smep, "+smep"), (both, "+smep,+smap")):
    text = cap.decode("latin-1")
    if "PROC START SLOT" not in text:
        fails.append("no process started on the %s boot" % label)
    if not re.search(r"^PROC END SWITCHES", text, re.M):
        fails.append("the %s boot's session did not end" % label)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (plain qemu64 CR4 0x%X; +smep CR4 0x%X; +smep,+smap CR4 0x%X -- SMAP "
      "refused on a CPU that has it; two ring-3 processes ran on both)"
      % (BASE, cr4_smep, cr4_both))
PY
then
  fail "SMEP is not enabled from the CPUID probe, or SMAP was enabled when it must not be (GAP-0153)"
fi
echo "ASSERT: pass  CR4 is 0x620 on plain qemu64 (so no golden in this repo moves), 0x100620 on -cpu qemu64,+smep, and STILL 0x100620 on -cpu qemu64,+smep,+smap - SMEP comes from the leaf-7 probe and SMAP is deliberately refused, with ring 3 running on both. THIS DOES NOT SHOW SMEP BLOCKING A FETCH: see GAP-0153 section 2."

# 6g. THE ALLOCATOR IS BACK WHERE IT STARTED.
#
# Four processes were created across the session -- two that ran to completion
# and two that were torn down by a fault -- and the free count printed by the
# LAST `frames` must equal the one printed by the FIRST. Twenty-eight
# allocations, all returned.
FREE_FIRST=$(awk '/^PMM MANAGED /{print $5; exit}' "$SERIAL_CAPTURE")
FREE_LAST=$(awk '/^PMM MANAGED /{v=$5} END{print v}' "$SERIAL_CAPTURE")
[[ -n "$FREE_FIRST" && "$FREE_FIRST" == "$FREE_LAST" ]] \
  || fail "the allocator had $FREE_FIRST free frames before the session and $FREE_LAST after it — four address spaces were built and torn down and something did not come back"
ALLOCS_LAST=$(awk '/^PMM ALLOCS /{v=$3} END{print v}' "$SERIAL_CAPTURE")
ERRORS_LAST=$(awk '/^PMM ALLOCS /{v=$5} END{print v}' "$SERIAL_CAPTURE")
[[ "$ERRORS_LAST" == "00000000" ]] || fail "the allocator reports $ERRORS_LAST free-errors after the session"
echo "ASSERT: pass  the allocator's free count is $FREE_FIRST before and after a session that built and tore down FOUR address spaces (0x$ALLOCS_LAST allocations, 0 free-errors)"

# 6h. The 80x25 text screen and the PNG.
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  diff "$EXPECTED_SCREEN" "$SCREEN_TEXT" | head -40 >&2
  fail "the 80x25 VGA text buffer read out of guest memory did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

[[ -s "$SHOT_PNG" ]] || fail "no PNG screenshot was written to $SHOT_PNG"
head -c 8 "$SHOT_PNG" | cmp -s - <(printf '\211PNG\r\n\032\n') \
  || fail "$SHOT_PNG is not a PNG"
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

echo "M11-proc: PASS — dcc build -> assemble -> link -> clang + x86_64-elf-ld build TWO freestanding static ELF64 programs AT -O2 WITHOUT -mgeneral-regs-only -> make-image.py writes three program slots onto a disk -> 11 structural checks (donated .bss 5496 -> 9664 in ONE symbol with proc_store 16-byte aligned in the LINKED image and all four FXSAVE areas with it, the table's geometry multiplied out against itself and against derive.py, the storage seam exactly 3 call sites in one file, 42 @rodata sizes plus shellStrHelp 1658 -> 1871, 9 refusal codes each reachable from a return and each with its own sentence, boot.S probing CPUID leaf 1 before writing CR4 with all three writes guarded, fxsave/fxrstor present and ZERO %xmm instructions anywhere else in the linked kernel, and the 22-word frame derived from user.dart's offsets) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 53 + 5, kdata.o still clean standalone) -> SIX real QEMU boots (GAP-0153 added two CPU models). A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; TWO DIFFERENT PROGRAMS, compiled with SSE and running SSE, interleaved by a cooperative \`yield\` syscall, each printing its own message from its own \`msg\` symbol and exiting with a status derived from its own \`.rodata\`, its own \`.data\` and the checksum of the 64 bytes its own compiler-emitted \`movups\` moved; each one's XMM0 and XMM7 surviving three round trips through the other process; BOTH address spaces walked out of guest physical memory from two different PML4 frames with both processes alive and the CPU at CPL 3, showing A's private pages absent from B's, every shared virtual address on a different physical frame, and the kernel the same frame and supervisor-only in both; process A's suspended FPU state read out of its 512-byte FXSAVE area holding its own signature in all four lanes; the kernel computing an address A has and B has not and B taking a NOTPRES READ USER page fault on it and being torn down with the shell surviving; a CPU with no SSE where the kernel still boots, reports CR4 0x20, and refuses to create a process by name; a drained allocator where \`proc run\` refuses instead of pretending; the allocator's free count identical before and after four address spaces; and CR4 read back on THREE CPU models -- 0x620 on plain qemu64 so no golden in this repo moves, 0x100620 on +smep, and STILL 0x100620 on +smep,+smap because SMAP is deliberately refused, which GAP-0153 explains and does NOT claim as a demonstration that SMEP blocks a fetch. Screenshot at $SHOT_PNG"
exit 0
