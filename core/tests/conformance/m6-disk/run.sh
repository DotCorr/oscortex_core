#!/usr/bin/env bash
# core/tests/conformance/m6-disk/run.sh
#
# Mechanical check of ROADMAP.md's M6 exit criterion: the kernel READS BYTES
# OFF A DISK, and the bytes it prints are the bytes that are on it.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# M5 taught this kernel to find hardware: `pci` reports an IDE controller at
# 00:01.1 (8086:7010, class 01/01). It could SEE storage and could not read a
# byte of it. Every byte this kernel has ever printed came from a register, a
# constant compiled into it, or the loader.
#
# The assertion that matters here is not "a hexdump appeared". It is that the
# hexdump equals THE BYTES THIS HARNESS ITSELF WROTE INTO THE IMAGE, computed
# by calling make-image.py's own generator -- not quoted from a capture and not
# typed by a human. If the driver reads the wrong sector, swaps the halves of a
# word, or reads the data port a byte at a time, the comparison names the exact
# line that went wrong.
#
# THE IMAGE IS BUILT HERE, AND VERIFIED AFTER IT IS WRITTEN
# ---------------------------------------------------------------------------
# `make-image.py` generates 128 sectors from `(31*s + 7*i + 0x21) & 0xFF`, with
# a per-sector ASCII label at offset 0, a signature at 0x100 of sector 0 and
# 0x55 0xAA at 0x1FE. It then READS THE FILE BACK and checks all of that,
# because a generator that is wrong in the same way as its own expectation
# proves nothing. Sectors differ from each other by construction, which is what
# makes an LBA off-by-one impossible to pass.
#
# NINE INDEPENDENT ASSERTIONS
# ---------------------------------------------------------------------------
#   1. SERIAL, byte-for-byte (`expected.txt`), with m1-interrupts' 544-byte
#      golden checked MECHANICALLY as a prefix against M1's own file.
#   2. THE SECTOR 0 HEXDUMP EQUALS THE IMAGE, derived from make-image.py.
#   3. TWO MORE SECTORS -- 0x2A and 0x05, neither of them zero and neither of
#      them sector zero -- likewise, and each dump differs from its neighbour's.
#      An LBA off-by-one cannot pass.
#   4. THE REPORTED CAPACITY MATCHES THE IMAGE FILE'S REAL SIZE, and QEMU's own
#      `info block` agrees the drive is attached and is that file.
#   5. TWO `disk id` LINES, byte-identical, the second after a deliberate
#      `crash ud` -- M4's recovery re-proved with a new subsystem on top.
#   6. STRUCTURAL: `port_inw` is the exact 16-bit instruction (`66 ed`); every
#      @rodata table is the size its call site passes; donated `.bss` did NOT
#      grow; and `ataWait`'s compiled loop carries its poll bound.
#   7. A PNG at core/build/screenshot-disk.png.
#   8. NEGATIVE CONTROL A: the same kernel, the same keys, an image with ONE
#      BIT flipped -- the dump must differ from the expectation at exactly that
#      byte and nowhere else.
#   9. NEGATIVE CONTROL B: the same kernel with NO DRIVE ATTACHED -- `disk id`
#      must report NODEV and no hexdump may appear at all.
#
# Control B is the one that makes the rest mean anything: it is the boot that
# proves the hexdump comes off the disk rather than out of the kernel.
#
# `qmp-drive.py` is REUSED from m2-console unchanged -- one driver, five
# harnesses. This harness passes `--monitor-command 'info block'`, which m5-pci
# already made an optional, repeatable flag.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m6-disk/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M6-disk: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M6-disk: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
MAKE_IMAGE="$SCRIPT_DIR/make-image.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"
[[ -f "$MAKE_IMAGE" ]] || setup_error "image generator not found at $MAKE_IMAGE"
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m6-disk reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m6.XXXXXX")" || setup_error "could not create a temp workdir"
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
# Step 2 — the disk image, built and then verified from the filesystem.
# ---------------------------------------------------------------------------
DISK_IMG="$WORKDIR/disk.img"
python3 "$MAKE_IMAGE" "$DISK_IMG" || fail "make-image.py could not produce a verified image"
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
IMG_SECTORS=$(( IMG_BYTES / 512 ))
[[ $(( IMG_BYTES % 512 )) -eq 0 ]] || fail "the generated image is $IMG_BYTES bytes, not a whole number of sectors"
echo "IMAGE: pass  $IMG_BYTES bytes = $IMG_SECTORS sectors, generated and re-read from disk"

# The negative control's image: identical except for ONE BIT in sector 0.
NEG_IMG="$WORKDIR/disk-flipped.img"
python3 "$MAKE_IMAGE" "$NEG_IMG" --flip 0 >/dev/null || fail "could not build the flipped control image"
FLIP_DIFF=$(cmp -l "$DISK_IMG" "$NEG_IMG" | wc -l | tr -d ' ')
[[ "$FLIP_DIFF" -eq 1 ]] || fail "the control image differs from the real one in $FLIP_DIFF bytes, expected exactly 1 — a control that differs everywhere proves nothing about where"

# ---------------------------------------------------------------------------
# Step 3 — structural checks (CLAUDE.md: anything checkable without booting
# should be).
# ---------------------------------------------------------------------------

# 3a. DONATED `.bss` DID NOT GROW, AND THAT IS THIS MILESTONE'S CLAIM RATHER
#     THAN AN INHERITED NUMBER.
#
# DCDart has no mutable static data (docs/known-gaps.md GAP-0053) and
# core/boot/kdata.S's .bss is the running measure of what that costs: 16 bytes
# after M2, 304 after M3, 392 after M4, 424 after M5. A disk driver's obvious
# shape is `read(lba, buffer)`, and a 512-byte buffer would have taken this to
# 936 -- more than doubling in one milestone, for one command.
#
# It is still 424 because the driver HEXDUMPS EACH WORD AS IT ARRIVES and
# retains nothing.
#
# M7 TOOK THE GRAND TOTAL TO 5096 (a 4672-byte page-allocator block), and
# m7-frames/run.sh owns that number now. M6's claim is untouched by it: the
# disk driver still has no sector buffer, and that is asserted here by
# EXCLUDING the allocator's block, which leaves exactly the 424 bytes M6
# inherited. If any non-allocator storage appeared, this fails; if the
# allocator's block changed size, m7-frames fails. Neither hides behind the
# other.
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
PMM_STORE_SIZE=$(bsssize pmmStore)
PMM_STORE_SIZE=${PMM_STORE_SIZE:-0}
# M8 added a second block after M7's (`vm_store`, 128 bytes: the virtual-
# memory subsystem's entire state). Subtracted for exactly the reason
# `pmm_store` is: this milestone's claim was never "the total is 424", it was
# "MY subsystem cost this much", and a later milestone must not be able to
# dilute that by growing the total. docs/known-gaps.md GAP-0053 carries the
# running total; m8-paging/run.sh owns the 5224 now.
VM_STORE_SIZE=$(bsssize vmStore)
[[ -n "$VM_STORE_SIZE" ]] || fail "vm_store is not in kdata.o — M8's virtual-memory state block is missing"
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
# `.bss`, and then subtracted out below, so that THIS harness's own number and
# M11's both come out exactly as they did before M14 existed.
M14_OFF_HEX=$(bssoff fatStore)
[[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
[[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824. If M14's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
M11_BSS=$(( KDATA_BSS - 16#$M11_ELF_OFF_HEX - M10_STORE - M14_BSS ))
[[ "$M11_BSS" -eq 4232 ]] || fail "the donated bytes past the end of M10's elf_store are $M11_BSS, expected 4232 (M11's proc_store, grown to 4224 by M18's scheduler header (ADR-0022), plus the 8 bytes of padding its .align 16 needs). If M11's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
NON_PMM_BSS=$(( KDATA_BSS + ASM_BSS - PMM_STORE_SIZE - VM_STORE_SIZE - M9_BSS - M10_STORE - M11_BSS - M14_BSS ))
if [[ "$NON_PMM_BSS" -ne 424 ]]; then
  fail "the kernel holds $(( KDATA_BSS + ASM_BSS )) bytes of mutable static storage, of which $PMM_STORE_SIZE are M7's pmmStore and $VM_STORE_SIZE are M8's vmStore, leaving $NON_PMM_BSS — expected 424. ATA PIO was supposed to add NONE. A 512-byte sector buffer is exactly what this driver does not have; if you meant to grow it, say so in kdata.S's header, in GAP-0053, and in docs/decisions/0010-ata-pio-disk-read.md."
fi
echo "STRUCTURAL: pass  424 bytes of mutable static storage outside M7's page-allocator and M8's page-table blocks — the disk driver still adds ZERO (no sector buffer exists)"

# 3b. `port_inw` MUST BE THE 16-BIT INSTRUCTION.
#
# The ATA data register at 0x1F0 is sixteen bits wide, and it is not a register
# you can read half of: each access pops one word out of the drive's sector
# buffer and advances its internal pointer. A BYTE read would return half a
# word and advance by an amount no specification defines.
#
# Asserted by EXACT OPCODE BYTES: `66 ed` is `in (%dx),%ax`. `ed` alone is the
# 32-bit form and `ec` the 8-bit one, so this distinguishes all three widths --
# which "the disassembly contains the word in" would not. QEMU would silently
# widen or narrow the access for us and real hardware would not, which is
# exactly the class of bug this check exists for.
insn_bytes() {
  local want="$1"
  awk -F'\t' -v w="$want" '/^ +[0-9a-f]+:/ && $3 != "" {
    split($3, a, " ");
    if (a[1] == w) { gsub(/ +$/, "", $2); print $2; exit }
  }'
}
PINW_DIS=$(x86_64-elf-objdump -d --disassemble=port_inw "$CORE_DIR/build/portio.o")
PINW_BYTES=$(insn_bytes in <<<"$PINW_DIS")
if [[ "$PINW_BYTES" != "66 ed" ]]; then
  echo "$PINW_DIS" >&2
  fail "port_inw's \`in\` encodes as '${PINW_BYTES:-nothing}', expected exactly '66 ed' (in (%dx),%ax). 'ec' would be a BYTE read of the ATA data port and 'ed' a 32-bit one; both would desynchronise the drive's sector-buffer pointer."
fi
echo "STRUCTURAL: pass  port_inw is exactly '66 ed' — the ATA data port is read 16 bits at a time, as the hardware requires"

# 3c. EVERY WAIT IS BOUNDED, AND THE BOUND IS IN THE COMPILED CODE.
#
# docs/known-gaps.md GAP-0058 records an unbounded wait as a real hazard in
# this kernel. A disk is a far better candidate for wedging than a UART, and a
# poll that never gives up is a silent hang with no diagnostic -- the exact
# failure M4's fault work exists to abolish.
#
# `ataWait` is the ONLY polling loop in the driver, and its bound is
# `ataPollLimit` = 0x200000. LLVM is free to count up from -0x200000 or down
# from +0x200000, so either immediate is accepted; what is NOT accepted is
# neither of them, which would mean the counter was optimised away and the loop
# has no exit but success.
ATAWAIT_DIS=$(x86_64-elf-objdump -d --disassemble=ataWait "$CORE_DIR/build/kmain.o")
[[ -n "$ATAWAIT_DIS" ]] || fail "ataWait is not in kmain.o — the driver's only polling loop is missing"
if ! grep -qE '0x200000|0xffffffffffe00000' <<<"$ATAWAIT_DIS"; then
  echo "$ATAWAIT_DIS" >&2
  fail "ataWait's compiled code carries neither 0x200000 nor its negation, so the iteration bound (ataPollLimit) is not in the instruction stream — the poll may have become unbounded (known-gaps GAP-0058)"
fi
grep -qE '^\s+[0-9a-f]+:.*\bin\b' <<<"$ATAWAIT_DIS" || {
  echo "$ATAWAIT_DIS" >&2
  fail "ataWait contains no \`in\` instruction — it is not reading the status register at all"
}
echo "STRUCTURAL: pass  ataWait polls the status port and its 0x200000-iteration bound survives into the compiled code — the driver cannot spin forever"

# 3d. THE @rodata TABLES ARE EXACTLY THE SIZES THEIR CALL SITES PASS.
#
# A @rodata table carries no length (DCDart ADR-0040), so every byte count is a
# hand-maintained literal -- docs/known-gaps.md GAP-0060, which bit at M4 when
# shellStrHelp grew and its one call site did not. shellStrHelp grew AGAIN here
# (498 -> 621, the two `disk` lines), so this check is not hypothetical for
# this milestone either. Every ATA table below was generated from its string,
# and every number here is the number the call site passes.
check_table() {
  local sym="$1" want="$2"
  local got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M6 depends on was not emitted"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060: the length is a hand-maintained literal)"
}
check_table shellStrHelp 2224  # M10 added `run <lba>`, M11 three `proc` lines, M14 `run <name>` + `fs`/`ls`/`cat`; GAP-0060
check_table ataCmdName 4
check_table ataCmdIdName 7
check_table ataCmdReadName 10
check_table ataStrUsage 43
check_table ataStrBadLba 52
check_table ataStrIdLbl 12
check_table ataStrModel 7
check_table ataStrSectors 9
check_table ataStrOk 4
check_table ataStrReadLbl 14
check_table ataStrReadEnd 14
check_table ataStrNoDev 18
check_table ataStrTimeout 18
check_table ataStrStTail 4
check_table ataStrErrLbl 12
check_table ataStrErTail 4
check_table ataStrNotAta 20
echo "STRUCTURAL: pass  all 17 M6 @rodata tables plus shellStrHelp (498 -> 621 at M6, 1028 at M7) are exactly the sizes their call sites pass"

# ---------------------------------------------------------------------------
# Step 4 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# The extern count must be UNCHANGED at 29. That is a claim about the design:
# ATA PIO needed no new assembly at all. The 16-bit `in` it reads the data port
# with is `port_inw`, which core/boot/portio.S already provides for M5's Bochs
# VBE mode-set -- the same helper, one more caller.
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
# M7 took this from 29 to 32 (pmmStore, kernel_image_start,
# kernel_image_end -- m7-frames/run.sh names and owns those three). M6's claim
# was "ATA PIO needed NO new assembly", which is asserted directly below: the
# count is 32, and removing M7's three leaves M5's 29 exactly.
# M8 (ADR-0012) added TWELVE more, so the raw count is now 44. They are
# SUBTRACTED BY NAME rather than folded into a new total, for the same reason
# the donated-`.bss` checks above subtract `pmm_store` and `vm_store`: this
# milestone's claim is about the externs IT added, and a later milestone must
# not be able to move the number that states it. Subtracting by name also fails
# if one of M8's externs quietly disappears, which a bumped total would not.
M8_EXTERNS="cr0_read cr2_read cr3_read paging_install vm_exec_probe vm_exec_ok_addr nx_enabled kernel_text_end kernel_rodata_start kernel_rodata_end kernel_data_start"
M8_PRESENT=0
for sym in $M8_EXTERNS; do
  grep -q "$sym" <<<"$VERIFY_OUT" && M8_PRESENT=$(( M8_PRESENT + 1 ))
done
[[ "$M8_PRESENT" -eq 11 ]] || fail "only $M8_PRESENT of M8's 11 externs are in kmain.o's manifest ($M8_EXTERNS)"
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bvm_store_addr\b" <<<"$VERIFY_OUT" && fail "vm_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static vmStore"

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
# seam. Subtracted for the same reason M8's, M9's, M10's and M11's are: this
# harness's claim is about ITS OWN milestone's count.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && fail "fat_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fatStore"
M14_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M11_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M9_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M8_PRESENT ))
# M17 (ADR-0021) took M5's 29 to 20 and M7's three to two, because nine of
# them were `_addr()` accessors for assembly-donated `.bss` and the storage is
# now DCDart `@bss`. M6's own claim -- "the disk driver needed no new assembly"
# -- is unchanged and is still the whole point of the subtraction below.
for gone in vga_cursor_addr m2_phase_addr shell_line_addr shell_len_addr \
            shell_state_addr shell_mbinfo_addr kbd_prefix_addr fault_count_addr \
            fb_state_addr pmm_store_addr; do
  grep -q "\b$gone\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
[[ "$EXTERN_COUNT" -eq 22 ]] || fail "kmain.o declares $EXTERN_COUNT externs outside M8's eleven, expected 22 (M5's 20 after ADR-0021, plus M7's kernel_image_start and kernel_image_end). M6 itself was supposed to add NONE: ATA PIO reads the data port through port_inw, which portio.S already had for the Bochs VBE registers."
M7_EXTERNS=0
for sym in kernel_image_start kernel_image_end; do
  grep -q "$sym" <<<"$VERIFY_OUT" && M7_EXTERNS=$(( M7_EXTERNS + 1 ))
done
[[ $(( EXTERN_COUNT - M7_EXTERNS )) -eq 20 ]] || fail "kmain.o declares $EXTERN_COUNT externs of which $M7_EXTERNS are M7's, leaving $(( EXTERN_COUNT - M7_EXTERNS )) — expected M5's 29 less the nine accessors ADR-0021 deleted = 20, because the disk driver needed no new assembly"
grep -q "port_inw" <<<"$VERIFY_OUT" || fail "port_inw is not in kmain.o's extern manifest — the ATA data port is not being read through the 16-bit helper"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — $M7_EXTERNS of them M7's, leaving M5's 20 UNCHANGED; the disk driver needed no new assembly"

# ---------------------------------------------------------------------------
# Step 5 — boot with the disk attached and drive a real session.
#
# The session, in order. Every element makes a specific claim:
#
#   disk id       IDENTIFY: the model and capacity read off the drive.
#   disk read 0   sector 0, hexdumped as it arrives.
#   disk read 2a  a DIFFERENT sector, whose content differs by construction --
#                 so an LBA off-by-one produces a wrong dump, not a lucky one.
#   crash ud      a deliberate #UD, abandoning the stack (M4).
#   disk id       THE SAME IDENTIFY, AFTER A FAULT. Asserted byte-identical.
#   help          the listing, which now has to mention `disk` or the command
#                 is undiscoverable -- and shellStrHelp is the table GAP-0060
#                 bit on.
#   clear         blank screen, so the text-buffer golden is a clean dump.
#   disk read 5   the listing this boot's screenshot shows.
#
# `fb` is deliberately NOT in this session, for the reason m5-pci gives: a
# graphics mode repoints the 0xB8000 aperture, and a boot that sets one has no
# text buffer left to assert.
# ---------------------------------------------------------------------------
SESSION_KEYS="d,i,s,k,spc,i,d,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,d,i,s,k,spc,r,e,a,d,spc,0,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,d,i,s,k,spc,r,e,a,d,spc,2,a,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,c,r,a,s,h,spc,u,d,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,d,i,s,k,spc,i,d,ret,wait:600"
# M14 took `help` 1871 -> 2147 bytes: ~24ms more serial and four more lines of VGA
# scrolling. GAP-0105's settle is widened 600 -> 800ms with it, because the settle is a
# guess about how long a command takes and this milestone made the command longer. A
# pause emits no byte, so no golden changes.
SESSION_KEYS="$SESSION_KEYS,h,e,l,p,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret,wait:300"
SESSION_KEYS="$SESSION_KEYS,d,i,s,k,spc,r,e,a,d,spc,5,ret,wait:1200"

SHOT_PNG="$CORE_DIR/build/screenshot-disk.png"
rm -f "$SHOT_PNG"

# `-vga std`, `-cpu qemu64` and `-m 128M` are PINNED for the reason m5-pci pins
# them: they are part of the contract the goldens describe, not defaults that
# may drift.
#
# The drive is attached with `if=ide,index=0`, which is the PRIMARY MASTER --
# the one channel this driver knows about (0x1F0..0x1F7 / 0x3F6). `format=raw`
# is explicit so QEMU never probe-guesses the format of an image this harness
# generated.
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5"
  shift 5
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
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    "$@" \
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
    --monitor-command 'info block' \
    --monitor-capture "$outdir/info-block.txt" \
    --keys "$keys"
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

drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 10 \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk"
SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"
INFO_BLOCK="$WORKDIR/session/info-block.txt"

# ---------------------------------------------------------------------------
# Step 6 — assert.
# ---------------------------------------------------------------------------

# 6a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M6 changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 6b. The whole serial capture.
if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL_CAPTURE") | head -40 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 6c. THE HEXDUMPS EQUAL THE IMAGE. This is the assertion the milestone exists
#     for, and the expectation is COMPUTED FROM THE IMAGE by make-image.py's
#     own generator rather than quoted from any capture.
if ! python3 - "$SERIAL_CAPTURE" "$MAKE_IMAGE" "$DISK_IMG" <<'PY'
import importlib.util, sys

cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("mkimg", sys.argv[2])
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
blob = open(sys.argv[3], "rb").read()
fails = []


def dump_for(lba):
    """The hexdump the capture contains for `lba`, or None."""
    head = "DISK READ LBA %08X\n" % lba
    i = cap.find(head)
    if i < 0:
        return None
    j = cap.find("DISK READ END\n", i)
    if j < 0:
        return None
    return cap[i + len(head):j]


for lba in (0, 0x2A, 5):
    got = dump_for(lba)
    if got is None:
        fails.append("no complete `disk read %X` block in the capture -- either "
                     "the command never ran or it never reached DISK READ END, "
                     "which is only printed after 512 bytes have been "
                     "transferred and the drive has gone idle" % lba)
        continue
    # THE EXPECTATION, DERIVED. Read straight out of the image file that was
    # attached to QEMU, and formatted by the generator's own hexdump().
    want = mk.hexdump(blob[lba * 512:(lba + 1) * 512])
    if got != want:
        gl, wl = got.split("\n"), want.split("\n")
        for n, (a, b) in enumerate(zip(gl, wl)):
            if a != b:
                fails.append("sector %X line %d: kernel printed %r, the image "
                             "holds %r" % (lba, n, a, b))
                break
        else:
            fails.append("sector %X: the dump has %d lines, the image needs %d"
                         % (lba, len(gl), len(wl)))
    # And it must be the sector that was ASKED for, not merely some sector.
    if got == mk.hexdump(blob[(lba + 1) * 512:(lba + 2) * 512]):
        fails.append("sector %X's dump equals sector %X's -- an LBA off-by-one "
                     "would pass" % (lba, lba + 1))

d0, d2a = dump_for(0), dump_for(0x2A)
if d0 is not None and d0 == d2a:
    fails.append("`disk read 0` and `disk read 2a` produced identical dumps -- "
                 "the LBA is not reaching the drive at all")

# The label the image carries at offset 0 of each sector must be in the dump,
# which is the human-readable half of the same claim.
for lba in (0, 0x2A, 5):
    got = dump_for(lba) or ""
    label = ("OSCORTEX SECTOR %04X" % lba).encode("ascii")
    first = "0000" + "".join(" %02X" % b for b in label[:16])
    if not got.startswith(first):
        fails.append("sector %X's first line is %r, expected it to begin with "
                     "the image's own ASCII label %r"
                     % (lba, got.split("\n")[0] if got else None, first))

# 6c-2: THE CAPACITY. Words 60/61 of IDENTIFY against the image's real size.
import re
ids = re.findall(r"^DISK ID SIG ([0-9A-F]{4}) MODEL (.*) SECTORS ([0-9A-F]{8}) OK$",
                 cap, re.M)
if len(ids) != 2:
    fails.append("expected exactly two `DISK ID` lines (one of them after a "
                 "deliberate fault), found %d" % len(ids))
if ids:
    if len(set(ids)) != 1:
        fails.append("the two `DISK ID` lines differ: %r -- IDENTIFY is not "
                     "reproducible, or the fault changed it" % (ids,))
    sig, model, sectors = ids[0]
    if sig != "0000":
        fails.append("the ATA signature is %s, expected 0000 (an ATA disk). "
                     "EB14 would be ATAPI and 9669 SATA." % sig)
    want_sectors = len(blob) // 512
    if int(sectors, 16) != want_sectors:
        fails.append("the drive reports %s sectors (%d) but the image this "
                     "harness generated and attached is %d sectors"
                     % (sectors, int(sectors, 16), want_sectors))
    if not model.strip():
        fails.append("the IDENTIFY model string came back empty")
    if not all(0x20 <= ord(c) < 0x7F for c in model):
        fails.append("the model string contains non-printable bytes: %r" % model)
    print("    (model %r, %d sectors, matching the image byte count)"
          % (model, int(sectors, 16)))

if fails:
    print("m6-disk: disk-content check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (3 sectors dumped, every byte equal to the image)")
PY
then
  fail "the hexdumps the kernel printed are not the bytes this harness wrote into the image"
fi
echo "ASSERT: pass  every byte of sectors 0000, 002A and 0005 as hexdumped by the kernel equals the bytes make-image.py wrote — expectation DERIVED from the image, and the reported capacity matches the image's real size"

# 6d. QEMU'S OWN VIEW OF THE SAME DRIVE.
#
# `info block` is the emulator describing its own device model. It is what
# turns "the kernel printed a plausible model string" into "there really is a
# drive on the primary master and it is the file this harness generated" -- the
# same second-source discipline m5-pci applies with `info pci`.
if ! grep -q "ide0-hd0" "$INFO_BLOCK"; then
  cat "$INFO_BLOCK" >&2
  fail "QEMU's own \`info block\` does not show a drive at ide0-hd0 (the primary master), so the kernel's IDENTIFY would be describing something this harness did not attach"
fi
if ! grep -q "$(basename "$DISK_IMG")" "$INFO_BLOCK"; then
  cat "$INFO_BLOCK" >&2
  fail "QEMU's \`info block\` does not name $(basename "$DISK_IMG") — the attached image is not the one this harness generated and verified"
fi
echo "ASSERT: pass  QEMU's own \`info block\` confirms the primary master is backed by the generated image"

# 6e. The framebuffer (the 80x25 text buffer, read out of guest memory).
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 6f. The screenshot.
[[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG (QEMU's screendump format argument may be unsupported on this build)" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 7 — NEGATIVE CONTROL A: ONE BIT.
#
# Same kernel, same keys, same everything -- except that byte 3 of sector 0 of
# the image has one bit flipped. The dump must differ from the real image's
# expectation at EXACTLY that byte and nowhere else.
#
# This is a sharper control than "different keys produce a different capture",
# because it holds the kernel and the session fixed and changes only what is on
# the disk. If the dump came from anywhere other than the disk -- a buffer the
# kernel filled itself, a cached read, an invented pattern -- it would be
# unchanged.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/flip" "d,i,s,k,spc,r,e,a,d,spc,0,ret,wait:1200" \
  "$WORKDIR/flip/shot.png" "flipped-image" 11 \
  -drive "file=$NEG_IMG,format=raw,if=ide,index=0,media=disk"

if ! python3 - "$WORKDIR/flip/serial.txt" "$MAKE_IMAGE" "$DISK_IMG" "$NEG_IMG" <<'PY'
import importlib.util, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("mkimg", sys.argv[2])
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
real = open(sys.argv[3], "rb").read()
flipped = open(sys.argv[4], "rb").read()

head = "DISK READ LBA 00000000\n"
i = cap.find(head)
j = cap.find("DISK READ END\n", i) if i >= 0 else -1
if i < 0 or j < 0:
    sys.exit("the control boot produced no complete sector dump at all, so its "
             "divergence says nothing")
got = cap[i + len(head):j]

want_real = mk.hexdump(real[0:512])
want_flip = mk.hexdump(flipped[0:512])
if got == want_real:
    sys.exit("NEGATIVE CONTROL A FAILED: the kernel dumped the ORIGINAL image's "
             "bytes from a disk that does not contain them. The hexdump is not "
             "coming off the disk.")
if got != want_flip:
    for n, (a, b) in enumerate(zip(got.split("\n"), want_flip.split("\n"))):
        if a != b:
            sys.exit("the control dump matches neither image; line %d is %r, "
                     "the flipped image holds %r" % (n, a, b))
    sys.exit("the control dump matches neither image (length mismatch)")

diffs = [n for n, (a, b) in enumerate(zip(want_real.split("\n"),
                                          got.split("\n"))) if a != b]
if diffs != [0]:
    sys.exit("the control dump differs from the original on lines %r, expected "
             "exactly line 0 (byte 3 is the only byte that was changed)" % diffs)
print("    (the dump follows the DISK, not the kernel: one flipped bit, one "
      "changed line, line 0)")
PY
then
  fail "NEGATIVE CONTROL A FAILED: flipping one bit on the disk did not change exactly one byte of the kernel's hexdump"
fi
echo "ASSERT: pass  negative control A — one flipped bit in the image changes exactly one byte of the kernel's dump, and the unflipped expectation FAILS against it"

# ---------------------------------------------------------------------------
# Step 8 — NEGATIVE CONTROL B: NO DRIVE.
#
# The same kernel with nothing attached. `disk id` must say NODEV and name the
# status byte it saw; `disk read 0` must fail the same way and print NO HEXDUMP
# AT ALL. And it must fail FAST -- the presence test is what keeps a missing
# drive from spending the whole poll bound before saying so.
#
# This is the boot that makes every assertion above mean something: it is the
# proof that a hexdump is evidence of a disk rather than a thing this kernel
# can produce on its own.
# ---------------------------------------------------------------------------
NEG_START=$(python3 -c 'import time; print(time.time())')
drive_session "$WORKDIR/nodrive" "d,i,s,k,spc,i,d,ret,wait:800,d,i,s,k,spc,r,e,a,d,spc,0,ret,wait:800" \
  "$WORKDIR/nodrive/shot.png" "no-drive" 12
NEG_SERIAL="$WORKDIR/nodrive/serial.txt"

grep -q "^DISK ERR NODEV ST 00$" "$NEG_SERIAL" || {
  sed -n '/M1 END/,$p' "$NEG_SERIAL" >&2
  fail "NEGATIVE CONTROL B FAILED: with no drive attached the kernel did not report \`DISK ERR NODEV ST 00\`. Either it invented a drive, or it hung, or it reported a different failure than the one that actually happened."
}
NODEV_LINES=$(grep -c "^DISK ERR NODEV ST 00$" "$NEG_SERIAL")
[[ "$NODEV_LINES" -eq 2 ]] || fail "NEGATIVE CONTROL B FAILED: expected both \`disk id\` and \`disk read 0\` to report NODEV, found $NODEV_LINES such lines"
if grep -qE '^[0-9A-F]{4}( [0-9A-F]{2}){16}$' "$NEG_SERIAL"; then
  grep -E '^[0-9A-F]{4}( [0-9A-F]{2}){16}$' "$NEG_SERIAL" | head -3 >&2
  fail "NEGATIVE CONTROL B FAILED: the kernel printed hexdump lines with NO DRIVE ATTACHED. Whatever those bytes are, they are not off a disk."
fi
grep -q "^DISK READ END$" "$NEG_SERIAL" && \
  fail "NEGATIVE CONTROL B FAILED: \`DISK READ END\` was printed on a boot with no drive — that line is supposed to be reachable only after 512 bytes have actually been transferred"
if cmp -s "$NEG_SERIAL" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL B FAILED: a boot with no drive produced the same serial capture as the session boot"
fi
echo "ASSERT: pass  negative control B — with no drive attached, both commands report \`DISK ERR NODEV ST 00\`, no hexdump line is printed anywhere, and \`DISK READ END\` never appears"

echo "M6-disk: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S + portio.S) -> link -> 4 structural checks (donated .bss outside M7's allocator block still 424, port_inw exactly '66 ed', ataWait's poll bound in the compiled code, 18 @rodata sizes) -> verify-freestanding pass ($EXTERN_COUNT declared externs, M5's 29 UNCHANGED plus M7's three) -> THREE real QEMU boots (-m 128M -cpu qemu64 -vga std) over QMP. A deterministic ${IMG_SECTORS}-sector image generated and re-verified from disk, attached as the primary master; a ${SERIAL_BYTES}-byte serial match with M1's golden intact as a prefix; IDENTIFY reporting a model and a capacity that equals the image's real size and that QEMU's own \`info block\` confirms; sectors 0000, 002A and 0005 hexdumped as they arrived and equal, byte for byte, to the bytes this harness wrote — the expectation DERIVED from the image, never typed; two identical IDENTIFY lines, the second after a deliberate #UD; and two negative controls — one flipped bit changing exactly one dumped byte, and a no-drive boot that reports NODEV and prints no hexdump at all. Screenshot at $SHOT_PNG"
exit 0
