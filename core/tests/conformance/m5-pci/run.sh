#!/usr/bin/env bash
# core/tests/conformance/m5-pci/run.sh
#
# Mechanical check of ROADMAP.md's M5 exit criterion, in two parts: the kernel
# FINDS hardware it was not compiled to know about, and then DRAWS on a piece
# of it whose address it had to discover.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every device driven through M4 was found by knowing where it is: 0x3F8 for
# COM1, 0x20/0xA0 for the 8259s, 0x40 for the PIT, 0x60/0x64 for the 8042,
# 0xB8000 for the text buffer. Each of those is a constant compiled into the
# kernel and a bet that the machine is shaped like a 1990 PC. Nothing before
# this milestone asked the hardware what was present.
#
#   * the kernel enumerates PCI configuration space over 0xCF8/0xCFC and
#     reports six devices, and the harness compares that list against QEMU's
#     OWN `info pci` from the SAME boot -- two independent programs walking the
#     same bus, not a golden the kernel wrote and then agreed with;
#   * the multi-function bit is honoured rather than ignored: exactly one slot
#     (00:01, the PIIX3) reports a header type with bit 7 set, and it is
#     exactly the slot that has more than one function. A scan that probed all
#     eight function numbers blindly would report the other five devices eight
#     times each, and the `TOTAL` line would say 0030 instead of 0006;
#   * a THIRD boot adds a real `pci-bridge` with an e1000 behind it, and the
#     kernel discovers a device on BUS 01 that does not exist in the other two
#     boots. That is the bridge recursion executing, not merely compiling;
#   * `pci` after a deliberate fault produces byte-identical output to `pci`
#     before it -- M4's recovery still holds with a new subsystem on top;
#   * the 320-byte class-name table is validated RECORD BY RECORD out of the
#     object file (docs/known-gaps.md GAP-0060, which has already bitten once).
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ---------------------------------------------------------------------------
# BAR values. SeaBIOS assigns them and they are stable under this QEMU, but
# they are a property of the firmware's allocator rather than of this kernel's
# enumeration, and pinning them in a golden would make an unrelated SeaBIOS
# change look like a kernel regression. The kernel does not print them.
#
# `-cpu qemu64` and `-m 128M` are PINNED for the reason m4-fault pins them, and
# `-vga std` is now pinned EXPLICITLY: the VGA device's 1234:1111 line is in
# the golden, so which display adapter QEMU attaches is part of the contract
# rather than a default that may drift.
#
# PART 2 (the framebuffer) IS ASSERTED AS PIXELS, NOT AS A SCREENSHOT
# ---------------------------------------------------------------------------
# `fb` finds the display controller by PCI class, reads BAR0, sets 800x600x32
# through the Bochs VBE interface, and blits 8x16 glyphs from a `@rodata` font.
# A PNG proves QEMU rendered something; it does not prove this kernel wrote it,
# found the right address, or drew the glyph it meant to. So the pixels are read
# back out of GUEST PHYSICAL MEMORY at the address the KERNEL printed, and
# compared against the banner re-rendered from the SAME font table, read out of
# `kmain.o`. The expected image is therefore not a golden anybody typed.
#
# The framebuffer gets its OWN boot, and that is a finding rather than tidiness:
# setting a graphics mode repoints the legacy 0xB8000 aperture at video RAM, so
# after `fb` the text buffer is not a text buffer any more. Both halves are
# asserted -- the text console intact on a boot that does not run `fb`, and
# 2000 of 2000 cells reading as pixel data on the boot that does.
#
# FIFTEEN INDEPENDENT ASSERTIONS
# ---------------------------------------------------------------------------
#   1. SERIAL, byte-for-byte (`expected.txt`), with m1-interrupts' 544-byte
#      golden checked MECHANICALLY as a prefix against M1's own file.
#   2. THE ENUMERATION MATCHES QEMU'S OWN `info pci`, device for device.
#   3. THE MULTI-FUNCTION BIT: exactly one `H8x`, on exactly the multi-function
#      slot, and no aliased duplicates.
#   4. THE THREE `pci` BLOCKS ARE IDENTICAL, including the one after a fault.
#   5. THE FRAMEBUFFER, byte-for-byte, read out of GUEST PHYSICAL MEMORY.
#   6. A PNG at core/build/screenshot-pci.png.
#   7. A NEGATIVE CONTROL: a different key sequence fails both goldens,
#      diverging past M1's 544th byte.
#   8. A BRIDGE BOOT: the same kernel on hardware with a PCI-to-PCI bridge
#      finds a bus that does not exist otherwise.
#   9. STRUCTURAL: `port_inl`/`port_outl` are the exact 32-bit instructions.
#  10. STRUCTURAL: every `@rodata` table is the size its call site passes, and
#      the class-name table is self-consistent record by record.
#  11. STRUCTURAL: donated `.bss` outside M7's page-allocator and M8's page-table blocks is exactly
#      424 bytes -- PCI added none, the framebuffer console's cursor and
#      geometry added 32. (M7 owns the grand total; this owns M5's own claim.)
#  12. STRUCTURAL: the font is 96 whole glyphs, the space is blank, the FALLBACK
#      is not blank, and no glyph strays outside its 5-pixel column range.
#  13. THE DISCOVERED BAR: the kernel read 0xFD000000 out of configuration
#      space and QEMU's own `info pci` agrees that is where the framebuffer is.
#  14. THE PIXELS: 6528 of them at that address, matched against the banner
#      re-rendered from the kernel's own font.
#  15. ONE SCREEN AT A TIME: the text console is byte-exact on the session boot,
#      and 0xB8000 stops being text on the boot that sets a graphics mode.
#
# `qmp-drive.py` is REUSED from m2-console -- one driver, four harnesses. It
# gained two OPTIONAL capabilities for this milestone and is otherwise
# unchanged: repeatable `--monitor-command`, and `--addr-from-serial`, which
# substitutes an address the KERNEL printed into those commands. No other
# harness passes either flag.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m5-pci/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M5-pci: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M5-pci: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-objcopy llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m5-pci reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m5.XXXXXX")" || setup_error "could not create a temp workdir"
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

mnemonics() {
  awk -F'\t' '/^ +[0-9a-f]+:/ && $3 != "" { split($3, a, " "); printf "%s ", a[1] }'
}

# 2a. THE DONATED STORAGE, EXACTLY — AND THE TWO HALVES OF THIS MILESTONE
#     LAND ON OPPOSITE SIDES OF IT.
#
# DCDart has no mutable static data (docs/known-gaps.md GAP-0053) and
# core/boot/kdata.S's .bss size is the running measure of what that costs: 16
# bytes after M2, 304 after M3, 392 after M4. M5 takes it to 424, and the split
# is the interesting part:
#
#   PCI enumeration      +0   it prints as it walks and retains nothing, which
#                             is why nothing can later ask it what it found
#                             (GAP-0067 item 1)
#   framebuffer console  +32  fb_state: base, pitch, cursor column, cursor row.
#                             A console has a cursor and cannot not have one.
#
# OWNERSHIP OF THE EXACT TOTAL MOVED TO m7-frames/run.sh AT M7, AND WHAT THIS
# HARNESS ASSERTS INSTEAD IS STILL M5'S OWN CLAIM.
#
# The total went 424 -> 5096 at M7, because the page allocator's bitmap,
# metadata and self-test ledger are 4672 bytes in one donated block. By the
# rule that has moved this number since M2 -- one harness owns it, and it is
# the harness for the milestone that grew it -- m7-frames owns 5096 now.
#
# M5's claim was never "the total is 424". It was "the framebuffer console cost
# 32 bytes and PCI enumeration cost nothing", and that claim is unaffected by a
# later milestone donating more. So this now asserts the total EXCLUDING the
# page allocator's block, which is exactly the pre-M7 number and is still 424:
# if anything else in this kernel grew donated storage, this fails, and if the
# allocator's block changed size, m7-frames fails. Neither can hide behind the
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
  fail "the kernel holds $(( KDATA_BSS + ASM_BSS )) bytes of mutable static storage, of which $PMM_STORE_SIZE are M7's pmmStore and $VM_STORE_SIZE are M8's vmStore, leaving $NON_PMM_BSS — expected 424 (392 through M4, plus 32 for the framebuffer console's state; PCI enumeration adds NONE). That number is the measured cost of DCDart having no mutable statics (known-gaps GAP-0053) — if you meant to change it, change it in kdata.S's header and in GAP-0053 too."
fi
FB_STATE_SIZE=$(bsssize fbStateBlock)
[[ "$FB_STATE_SIZE" == "32" ]] || fail "fbStateBlock is ${FB_STATE_SIZE:-missing} bytes, expected 32 (four u64: base, pitch, cursor column, cursor row) — fbSetState indexes it by fixed offset and a shorter block would write past the end of its own object"
echo "STRUCTURAL: pass  424 bytes of mutable static storage outside M7's page-allocator and M8's page-table blocks (392 through M4 + 32 for fbStateBlock; PCI enumeration added zero)"

# 2b. `port_inl` AND `port_outl` MUST BE THE 32-BIT INSTRUCTIONS.
#
# The entire reason core/boot/portio.S exists is that DCDart's Port class is
# BYTE wide (its ADR-0029) and PCI configuration mechanism #1 is defined in
# terms of doubleword accesses. If either routine silently became a byte
# access, `pci` would still print plausible-looking output on QEMU (whose
# memory core would widen the access for us) and would be wrong on hardware.
#
# Asserted by EXACT OPCODE BYTE, not by mnemonic text: `ed` is `in (%dx),%eax`
# and `ef` is `out %eax,(%dx)`. Their byte-wide siblings are `ec` and `ee`, and
# the 16-bit forms carry a `66` operand-size prefix -- so this check
# distinguishes all three widths, which "the disassembly contains the word in"
# would not.
# The raw byte column of the line whose mnemonic is `in` (or `out`). Padding
# after the `ret` is skipped: ld's alignment nops are multi-byte `cs nopw`
# encodings that themselves begin 66, so "does the function contain a 66
# prefix" would be true of every aligned function on earth. What matters is the
# encoding of the port instruction ITSELF.
insn_bytes() {
  local want="$1"
  awk -F'\t' -v w="$want" '/^ +[0-9a-f]+:/ && $3 != "" {
    split($3, a, " ");
    if (a[1] == w) { gsub(/ +$/, "", $2); print $2; exit }
  }'
}

PIN_DIS=$(x86_64-elf-objdump -d --disassemble=port_inl "$CORE_DIR/build/portio.o")
POUT_DIS=$(x86_64-elf-objdump -d --disassemble=port_outl "$CORE_DIR/build/portio.o")
PIN_BYTES=$(insn_bytes in <<<"$PIN_DIS")
POUT_BYTES=$(insn_bytes out <<<"$POUT_DIS")
if [[ "$PIN_BYTES" != "ed" ]]; then
  echo "$PIN_DIS" >&2
  fail "port_inl's \`in\` encodes as '${PIN_BYTES:-nothing}', expected exactly 'ed' (in (%dx),%eax). 'ec' would be a BYTE read and '66 ed' a 16-bit one -- and PCI configuration mechanism #1 is only decoded for doubleword accesses."
fi
if [[ "$POUT_BYTES" != "ef" ]]; then
  echo "$POUT_DIS" >&2
  fail "port_outl's \`out\` encodes as '${POUT_BYTES:-nothing}', expected exactly 'ef' (out %eax,(%dx)). 'ee' would be a BYTE write and '66 ef' a 16-bit one."
fi
PIN_OPS=$(mnemonics <<<"$PIN_DIS")
POUT_OPS=$(mnemonics <<<"$POUT_DIS")
case "$PIN_OPS" in
  "mov in ret"*) ;;
  *) echo "$PIN_DIS" >&2; fail "port_inl is not 'mov->dx; in; ret' (got: $PIN_OPS)" ;;
esac
case "$POUT_OPS" in
  "mov mov out ret"*) ;;
  *) echo "$POUT_DIS" >&2; fail "port_outl is not 'mov->dx; mov->eax; out; ret' (got: $POUT_OPS)" ;;
esac
echo "STRUCTURAL: pass  port_inl is 'mov; in (ed); ret' and port_outl is 'mov; mov; out (ef); ret' — both genuinely 32-bit"

# 2c. THE @rodata TABLES ARE EXACTLY THE SIZES THEIR CALL SITES PASS.
#
# A @rodata table carries no length (DCDart ADR-0040), so every byte count is a
# hand-maintained literal -- docs/known-gaps.md GAP-0060, which bit at M4 when
# shellStrHelp grew and its one call site did not. shellStrHelp grew AGAIN here
# (395 -> 498, the `pci` and `fb` lines), and again at M6 (498 -> 621, the two
# `disk` lines), so this check is not hypothetical for this milestone either.
# The number below is M6's because the table is shared -- see known-gaps
# GAP-0072 for why this harness's golden was regenerated at M6.
check_table() {
  local sym="$1" want="$2"
  local got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M5 depends on was not emitted"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060: the length is a hand-maintained literal)"
}
check_table shellStrHelp 2224  # M10 added `run <lba>`, M11 three `proc` lines, M14 `run <name>` + `fs`/`ls`/`cat`; GAP-0060
check_table shellCmdPci 3
check_table pciStrLine 4
check_table pciStrTotal 10
check_table pciStrToBus 6
check_table pciStrNone 9
check_table pciClassNames 320
check_table fbStrCmd 2
check_table fbStrBar 7
check_table fbStrMode 6
check_table fbStrBy 1
check_table fbStrOk 4
check_table fbStrNoDev 59
check_table fbStrNoVbe 44
check_table fbStrBanner 52
check_table fbFont8x16 1536
echo "STRUCTURAL: pass  all 16 M5 @rodata tables are exactly the sizes their call sites pass (shellStrHelp 395 -> 498 at M5, 621 at M6, 1028 at M7; the font is 96 glyphs x 16 bytes)"

# 2d. THE CLASS-NAME TABLE IS SELF-CONSISTENT, RECORD BY RECORD.
#
# pciClassNames is 20 fixed 16-byte records, each carrying its OWN name length
# at +2 -- which is how twenty instances of GAP-0060 were collapsed into one.
# That only helps if the lengths in the table are right, so they are checked
# here against the actual bytes read out of the object file: length in 1..13,
# exactly that many printable bytes, NUL padding after them, and no two records
# claiming the same (class, subclass).
#
# The failure this catches is specific and would otherwise be invisible: a
# length one too large prints the first byte of a record's NUL padding, and a
# length one too small silently truncates a device's class name in output
# nobody would question.
# The symbol's VALUE in a relocatable object is its offset within its section,
# which is what indexes the raw .rodata bytes below. Converted in bash rather
# than awk: BSD awk has no strtonum().
RODATA_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$8=="pciClassNames" {print $2; exit}')
[[ -n "$RODATA_OFF_HEX" ]] || fail "pciClassNames has no symbol value in kmain.o"
RODATA_OFF=$((16#$RODATA_OFF_HEX))
x86_64-elf-objcopy -O binary --only-section=.rodata "$CORE_DIR/build/kmain.o" "$WORKDIR/rodata.bin" \
  || fail "could not extract .rodata from kmain.o"
if ! python3 - "$WORKDIR/rodata.bin" "$RODATA_OFF" <<'PY'
import sys
blob = open(sys.argv[1], "rb").read()
off = int(sys.argv[2])
STRIDE, COUNT, MAXNAME = 16, 20, 13
tbl = blob[off:off + STRIDE * COUNT]
fails = []
if len(tbl) != STRIDE * COUNT:
    fails.append("only %d bytes of table available in .rodata, need %d"
                 % (len(tbl), STRIDE * COUNT))
seen = {}
for i in range(COUNT):
    r = tbl[i * STRIDE:(i + 1) * STRIDE]
    if len(r) != STRIDE:
        break
    cls, sub, ln = r[0], r[1], r[2]
    name, pad = r[3:3 + ln], r[3 + ln:]
    if not 1 <= ln <= MAXNAME:
        fails.append("record %d: length byte %d is outside 1..%d" % (i, ln, MAXNAME))
        continue
    if not all(0x20 <= b < 0x7F for b in name):
        fails.append("record %d (%02x/%02x): name bytes are not all printable: %r"
                     % (i, cls, sub, name))
    if any(b != 0 for b in pad):
        fails.append("record %d (%02x/%02x): padding after a %d-byte name is not NUL: %r"
                     % (i, cls, sub, ln, pad))
    key = (cls, sub)
    if key in seen:
        fails.append("records %d and %d both claim class %02x subclass %02x"
                     % (seen[key], i, cls, sub))
    seen[key] = i
# The wildcard entries have to exist for the classes the golden relies on.
for cls in (0x01, 0x02, 0x03, 0x06):
    if (cls, 0xFF) not in seen:
        fails.append("class %02x has no wildcard (subclass 0xFF) entry" % cls)
if fails:
    print("m5-pci: pciClassNames record check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d records, all self-consistent)" % COUNT)
PY
then
  fail "pciClassNames is not self-consistent — a name length in the table disagrees with the bytes next to it (known-gaps GAP-0060)"
fi
echo "STRUCTURAL: pass  pciClassNames is 20 x 16 bytes, every record's own length byte agrees with its name and padding"

# 2e. THE FONT IS 96 WHOLE GLYPHS, AND THE FALLBACK IS NOT BLANK.
#
# 1536 bytes = 96 glyphs x 16 rows x 1 byte. The renderer indexes it by pure
# arithmetic (`(c - 0x20) * 16`), so a table that is not an exact multiple of 16
# means the last glyph is truncated and every byte past it is whatever the
# linker put next -- rendered as pixels, on a screen, with nothing failing.
#
# The four claims worth more than the size:
#
#   * glyph 0 (space) is entirely blank. If it were not, every space in every
#     line would draw something and the console would be unreadable;
#   * the FALLBACK glyph (index 95) is NOT blank. It is drawn for any byte
#     outside 0x20..0x7E, and its whole purpose is to make an unrenderable byte
#     VISIBLE -- a blank fallback would make a rendering failure
#     indistinguishable from a space, which is the exact failure mode it exists
#     to prevent;
#   * exactly ONE glyph is blank. An unauthored glyph would be sixteen zero
#     bytes and would render as nothing at all, silently;
#   * no glyph sets bit 7 or bits 1:0. The glyphs are authored 5 pixels wide and
#     placed in columns 1..5 of 8, so those three bits must be clear in all 1536
#     bytes. A stray bit is a placement bug and shows up as one lit pixel welded
#     to the edge of a character.
FONT_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$8=="fbFont8x16" {print $2; exit}')
[[ -n "$FONT_OFF_HEX" ]] || fail "fbFont8x16 has no symbol value in kmain.o"
FONT_OFF=$((16#$FONT_OFF_HEX))
if ! python3 "$SCRIPT_DIR/check-font.py" "$WORKDIR/rodata.bin" "$FONT_OFF"; then
  fail "fbFont8x16 is not a well-formed 96-glyph 8x16 font"
fi
echo "STRUCTURAL: pass  fbFont8x16 is 96 x 16 bytes: space blank, fallback NOT blank, exactly one blank glyph, no stray edge bits"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# portio.o is checked EXPLICITLY and standalone. It is a new assembly object
# and, like kdata.o, it has NO undefined symbols at all -- two leaf functions
# and nothing else -- so it must pass on its own. GAP-0056 records why boot.o
# and isr.o cannot, and this keeps portio.o on the right side of that line.
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
# kernel_image_end -- m7-frames/run.sh names and owns those three). M5's claim
# is about the five externs M5 itself added, so it is asserted directly rather
# than through a total a later milestone moved.
# M8 (ADR-0012) added twelve more, ELEVEN of which survive M17 (ADR-0021 deleted
# `vm_store_addr`). They are
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
# M17 (ADR-0021) TOOK 32 TO 22, and the ten are named rather than absorbed.
# Every one of them was an `_addr()` accessor whose only job was to hand DCDart
# the address of a block of assembly-donated `.bss`; the blocks are now DCDart
# `@bss` mutable statics and the accessors do not exist. The ten:
#   M2  vga_cursor_addr m2_phase_addr
#   M3  shell_line_addr shell_len_addr shell_state_addr shell_mbinfo_addr
#       kbd_prefix_addr
#   M4  fault_count_addr
#   M5  fb_state_addr           <- M5's own five became four
#   M7  pmm_store_addr          <- M7's own three became two
# So M4's 24 becomes 16, M5's five become four, and M7's three become two:
# 16 + 4 + 2 = 22. The count is asserted AND each deleted name is asserted
# absent, because a count alone can be restored by an unrelated extern.
for gone in vga_cursor_addr m2_phase_addr shell_line_addr shell_len_addr \
            shell_state_addr shell_mbinfo_addr kbd_prefix_addr fault_count_addr \
            fb_state_addr pmm_store_addr; do
  grep -q "\b$gone\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
[[ "$EXTERN_COUNT" -eq 22 ]] || fail "kmain.o declares $EXTERN_COUNT externs outside M8's eleven, expected 22 (M4's 24 less the eight accessors ADR-0021 deleted = 16, plus M5's port_inl/port_outl for PCI configuration space and port_inw/port_outw for the Bochs VBE registers, plus M7's kernel_image_start/kernel_image_end)"
for sym in port_inl port_outl port_inw port_outw; do
  grep -q "$sym" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest — one of the four externs M5 added and still has is gone"
done
for sym in port_inl port_outl port_inw port_outw; do
  grep -q "$sym" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest — the code that should be calling it is not"
done
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o (M4's 24 + port_{in,out}{l,w} + fb_state_addr), every one named in core/boot/{isr,kdata,portio}.S"

# ---------------------------------------------------------------------------
# Step 4 — boot, drive a real session, capture.
#
# The session, in order. Every element makes a specific claim:
#
#   pci        the enumeration. Six devices found by asking, not by knowing.
#   help       the listing, which now has to mention `pci` or the command is
#              undiscoverable -- and shellStrHelp is the table GAP-0060 bit on.
#   crash ud   a deliberate #UD, abandoning the stack (M4).
#   pci        THE SAME ENUMERATION, AFTER A FAULT. Asserted byte-identical to
#              the first: port I/O, the bus and the class table all survived.
#   clear      blank screen, so the text-buffer golden is a clean listing.
#   pci        the final listing, which is what this boot's screenshot shows.
#
# `fb` is deliberately NOT in this session. It switches the adapter into a
# graphics mode, after which 0xB8000 stops being a text buffer at all (see the
# framebuffer boot in step 6), so a session that ran it could not also assert an
# 80x25 text golden. The two claims need two boots, and they get two.
# ---------------------------------------------------------------------------
SESSION_KEYS="p,c,i,ret"
# M11 took `help` from 1658 to 1871 bytes. At 115200 baud that is ~160ms of serial
# plus three more lines of VGA scrolling, and the driver types the next key 50ms
# later — so without this pause the following command's echo interleaves into the
# middle of `help`'s output and the golden fails intermittently, at exactly the
# `help` boundary. m6-disk already carried a wait here for the same reason.
# M14 took `help` 1871 -> 2147 bytes: ~24ms more serial and four more lines of VGA
# scrolling. GAP-0105's settle is widened 600 -> 800ms with it, because the settle is a
# guess about how long a command takes and this milestone made the command longer. A
# pause emits no byte, so no golden changes.
SESSION_KEYS="$SESSION_KEYS,h,e,l,p,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,c,r,a,s,h,spc,u,d,ret"
SESSION_KEYS="$SESSION_KEYS,p,c,i,ret"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret"
SESSION_KEYS="$SESSION_KEYS,p,c,i,ret"

SHOT_PNG="$CORE_DIR/build/screenshot-pci.png"
rm -f "$SHOT_PNG"

# Sixteen `xp` dumps, one per scanline of the first glyph row, each 8 pixels
# per character of the banner. `{addr}` is substituted by qmp-drive.py with the
# framebuffer base THE KERNEL PRINTED -- so the pixels are read back from
# wherever the kernel says it wrote them, not from an address this harness
# assumed. On a boot where `fb` never ran there is no `FB BAR` line, the
# substitution is not needed, and these dumps are simply not requested.
# EMPTY by default. Only the framebuffer boot in step 6 asks for these, because
# only that boot runs `fb` -- a boot with no `FB BAR` line in its capture has no
# address to substitute, and asking would (correctly) be a hard error.
FB_DUMP_ARGS=()
fb_dump_args() {
  # 51, not 52: fbStrBanner's 52nd byte is the newline, which draws no pixels.
  local chars=51 pitch=$(( 800 * 4 )) scanline
  FB_DUMP_ARGS=(--addr-from-serial 'FB BAR ([0-9A-F]{8})')
  for scanline in $(seq 0 15); do
    FB_DUMP_ARGS+=(--monitor-command "xp/$(( chars * 8 ))wx {addr}+$(( scanline * pitch ))")
  done
}

# `-vga std` is PASSED EXPLICITLY. It is QEMU's default for this machine type
# today, and the VGA controller's `1234:1111` line is in the golden -- so
# leaving it implicit would make this harness depend on a default rather than
# on a stated configuration.
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
  timeout 120 qemu-system-x86_64 \
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
    --monitor-command 'info pci' \
    "${FB_DUMP_ARGS[@]}" \
    --monitor-capture "$outdir/info-pci.txt" \
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

drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 0
SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"
INFO_PCI="$WORKDIR/session/info-pci.txt"

# ---------------------------------------------------------------------------
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M5 changed M0/M1 serial output"
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
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 5c. THE KERNEL'S ENUMERATION vs. QEMU'S OWN `info pci`.
#
# This is the assertion that makes the whole milestone more than a golden.
# `info pci` is QEMU describing its own device model; the `PCI ...` lines are
# this kernel describing what it found by writing 0xCF8 and reading 0xCFC. They
# are produced by different programs from different sources and have to agree
# on the set of bus:device.function and vendor:device pairs.
#
# It also checks the three claims a golden alone could not distinguish from
# luck: the multi-function bit is honoured (exactly one H8x, on the slot that
# really has extra functions), no device is reported twice (which is what a
# blind eight-function scan produces), and the TOTAL matches the line count.
if ! python3 - "$SERIAL_CAPTURE" "$INFO_PCI" <<'PY'
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

LINE = re.compile(
    r"^PCI ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2}) H([0-9A-F]{2})(.*)$")

blocks, cur = [], None
for ln in serial.split("\n"):
    if ln.startswith("PCI ") and not ln.startswith("PCI TOTAL"):
        if cur is None:
            cur = []
        cur.append(ln)
    elif ln.startswith("PCI TOTAL"):
        blocks.append((cur or [], int(ln.split()[2], 16)))
        cur = None
    elif cur is not None and ln.strip() == "":
        continue

if len(blocks) != 3:
    fails.append("expected 3 `pci` blocks in the capture (before a fault, "
                 "after it, and after clear), found %d" % len(blocks))

# 5c-1: every block identical, including the one that ran on a stack the
# previous one did not have.
if blocks and any(b[0] != blocks[0][0] or b[1] != blocks[0][1] for b in blocks):
    fails.append("the three `pci` blocks are not identical -- enumerating the "
                 "bus is not reproducible, or a fault changed it")

lines, total = (blocks[0] if blocks else ([], 0))
devs = {}
for ln in lines:
    m = LINE.match(ln)
    if not m:
        fails.append("unparseable device line: %r" % ln)
        continue
    bus, dev, fn, ven, did, cls, sub, pif, hdr, name = m.groups()
    key = (bus, dev, fn)
    if key in devs:
        fails.append("device %s:%s.%s reported twice -- functions are being "
                     "probed blindly and a single-function device is aliasing"
                     % key)
    devs[key] = (ven, did, cls, sub, pif, hdr, name.strip())

if total != len(lines):
    fails.append("`PCI TOTAL %04d` disagrees with the %d device lines printed"
                 % (total, len(lines)))

# 5c-2: QEMU's own view of the same bus.
qemu = {}
cur_key = None
for ln in info.split("\n"):
    m = re.match(r"\s*Bus\s+(\d+), device\s+(\d+), function (\d+):", ln)
    if m:
        cur_key = ("%02X" % int(m.group(1)), "%02X" % int(m.group(2)),
                   "%X" % int(m.group(3)))
        continue
    m = re.search(r"PCI device ([0-9a-f]{4}):([0-9a-f]{4})", ln)
    if m and cur_key is not None:
        qemu[cur_key] = (m.group(1).upper(), m.group(2).upper())
        cur_key = None

if not qemu:
    fails.append("parsed no devices at all out of QEMU's `info pci` -- the "
                 "comparison would have been vacuously true")

only_kernel = sorted(set(devs) - set(qemu))
only_qemu = sorted(set(qemu) - set(devs))
if only_kernel:
    fails.append("the kernel reported devices QEMU does not have: %s" % (only_kernel,))
if only_qemu:
    fails.append("QEMU has devices the kernel did not find: %s" % (only_qemu,))
for key in sorted(set(devs) & set(qemu)):
    if devs[key][:2] != qemu[key]:
        fails.append("%s: kernel says %s:%s, QEMU says %s:%s"
                     % (":".join(key), devs[key][0], devs[key][1],
                        qemu[key][0], qemu[key][1]))

# 5c-3: the multi-function bit.
multi = sorted(k for k, v in devs.items() if int(v[5], 16) & 0x80)
if len(multi) != 1:
    fails.append("expected exactly one device with the multi-function bit set "
                 "in its header type, found %d: %s" % (len(multi), multi))
else:
    slot = multi[0][:2]
    fns_here = sorted(k[2] for k in devs if k[:2] == slot)
    if len(fns_here) < 2:
        fails.append("%s:%s claims to be multi-function but only function %s "
                     "was reported" % (slot + (fns_here,)))
    for k in devs:
        if k[:2] != slot and k[2] != "0":
            fails.append("%s is a non-zero function on a slot whose function 0 "
                         "did NOT set the multi-function bit -- it was probed "
                         "when it should not have been" % ":".join(k))

# 5c-4: the named devices this machine is supposed to have.
def want(key, ven, did, tail):
    if key not in devs:
        fails.append("expected a device at %s" % ":".join(key))
        return
    v = devs[key]
    if (v[0], v[1]) != (ven, did):
        fails.append("%s is %s:%s, expected %s:%s"
                     % (":".join(key), v[0], v[1], ven, did))
    if v[6] != tail:
        fails.append("%s decoded as %r, expected %r" % (":".join(key), v[6], tail))

want(("00", "00", "0"), "8086", "1237", "host bridge")
want(("00", "01", "0"), "8086", "7000", "isa bridge")
want(("00", "01", "1"), "8086", "7010", "ide storage")
want(("00", "02", "0"), "1234", "1111", "vga display")
want(("00", "03", "0"), "8086", "100E", "ethernet")
# 06/80 has no exact entry and falls back to the class wildcard: `bridge`, not
# a guess at what subclass 0x80 might be.
want(("00", "01", "3"), "8086", "7113", "bridge")

if fails:
    print("m5-pci: enumeration check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d devices, matching QEMU's info pci device-for-device)" % len(devs))
PY
then
  fail "the kernel's PCI enumeration does not agree with QEMU's own device model, or the multi-function bit was not honoured"
fi
echo "ASSERT: pass  the kernel's enumeration matches QEMU's own \`info pci\` device-for-device; exactly one multi-function slot, no aliased duplicates, and all three \`pci\` blocks identical (one of them after a fault)"

# 5d. The framebuffer, read from guest physical memory.
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  echo "--- expected ---" >&2
  cat -n "$EXPECTED_SCREEN" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 5e. The screenshot.
[[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG (QEMU's screendump format argument may be unsupported on this build)" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 6 — PART 2: THE FRAMEBUFFER BOOT.
#
# A SEPARATE boot, because `fb` and an 80x25 text golden cannot both be true of
# one boot. Setting a Bochs VBE graphics mode repoints the legacy `0xB8000`
# aperture at pixel data, so a session that sets a mode has no text buffer left
# to assert. That is a property of the adapter, not of this kernel, and it is
# asserted below in both directions rather than described.
#
# The session is `pci` (with the text console live), then `fb`, then `pci`
# again (now rendered as pixels). The second listing is what the screenshot
# shows and what the pixel read-back is taken over.
# ---------------------------------------------------------------------------
FB_SHOT_PNG="$CORE_DIR/build/screenshot-fb.png"
rm -f "$FB_SHOT_PNG"
# Sixteen `xp` dumps, one per scanline of the banner's glyph row. `{addr}` is
# substituted by qmp-drive.py with the framebuffer base THE KERNEL PRINTED, so
# the pixels are read back from wherever the kernel says it wrote them rather
# than from an address this harness assumed.
fb_dump_args
drive_session "$WORKDIR/fb" "p,c,i,ret,f,b,ret,wait:1500,p,c,i,ret,wait:1500" \
  "$FB_SHOT_PNG" "framebuffer" 3
FB_DUMP_ARGS=()   # back to empty: the bridge and control boots do not run `fb`
FB_SERIAL="$WORKDIR/fb/serial.txt"
FB_SCREEN="$WORKDIR/fb/screen.txt"
FB_INFO_PCI="$WORKDIR/fb/info-pci.txt"

# ---------------------------------------------------------------------------
# Step 5g — PART 2: THE LINEAR FRAMEBUFFER, AS ACTUAL PIXELS.
#
# A screenshot is not proof. It shows that QEMU rendered something; it does not
# show that this kernel wrote it, that the kernel found the right address, or
# that the glyph it drew is the glyph it meant to draw, and it cannot fail in a
# way that names what went wrong.
#
# So the pixels are read back out of GUEST PHYSICAL MEMORY, at the address the
# kernel itself printed (`FB BAR FD000000` -- qmp-drive.py substitutes it into
# the `xp` commands, so nothing here assumes where the framebuffer is), and
# compared against the banner re-rendered from the SAME `@rodata` font table
# the kernel blitted from, read out of `kmain.o`.
#
# That makes the expected image something nobody typed. What it catches:
#
#   * a mode that was never actually set -- the memory would be zeroes, and the
#     BACKGROUND colour would not match either (0x101018 is painted, not left);
#   * the wrong BAR, or an unmapped one -- nothing would be there at all;
#   * a reversed bit order in the glyph row blit -- every asymmetric glyph
#     would mismatch, and the message names the exact pixel;
#   * a wrong pitch -- rows past the first would be offset;
#   * an off-by-one in the glyph index -- every character would be its
#     neighbour, which a screenshot at this size would not make obvious;
#   * a transparent blit -- the background pixels inside a glyph cell would
#     still hold whatever `fbFill` left, which is the same colour here, so this
#     check ALSO compares the fill.
# ---------------------------------------------------------------------------
grep -q "^FB BAR FD000000 MODE 0320x0258x20 OK$" "$FB_SERIAL" || {
  grep "^FB " "$FB_SERIAL" >&2 || echo "(no FB lines in the capture at all)" >&2
  fail "the kernel did not report finding a framebuffer at BAR0 and setting 800x600x32. All numbers this kernel prints are hex, so 0320x0258x20 is 800x600x32."
}

# QEMU's own view of the same BAR. The kernel discovered 0xFD000000 by reading
# configuration space; this is the emulator saying the same thing about its own
# device model, which is what turns 'the kernel printed an address' into 'the
# kernel printed the RIGHT address'.
grep -qi "BAR0: 32 bit prefetchable memory at 0xfd000000" "$FB_INFO_PCI" || {
  grep -i -A4 "VGA controller" "$FB_INFO_PCI" >&2
  fail "QEMU's own \`info pci\` does not put the VGA controller's BAR0 at 0xfd000000, so the address the kernel read back is not confirmed by an independent source"
}
echo "ASSERT: pass  the kernel read BAR0 = FD000000 out of configuration space and QEMU's own \`info pci\` agrees that is where the VGA framebuffer is"

FONT_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$8=="fbFont8x16" {print $2; exit}')
FONT_OFF=$((16#$FONT_OFF_HEX))
if ! python3 "$SCRIPT_DIR/check-pixels.py" \
      "$FB_INFO_PCI" "$WORKDIR/rodata.bin" "$FONT_OFF" \
      'OSCORTEX framebuffer console  800x600x32  8x16 font' \
      0x00C8C8C8 0x00101018; then
  fail "the pixels in the linear framebuffer do not match the banner re-rendered from the kernel's own font table"
fi
echo "ASSERT: pass  the first 16 scanlines at the discovered BAR contain exactly the banner, rendered from the same @rodata font the kernel blitted from"

# 6c. The framebuffer is a LIVE CONSOLE, not a one-shot banner.
#
# The `pci` that runs after `fb` produces its output through `conPutc`, so it
# has to reach the framebuffer the same way the banner did. Asserted on serial
# (the listing is there, after the FB line) and, above, in pixels for the
# banner -- together they say the renderer is wired into the console rather
# than being a function the `fb` command calls once.
python3 - "$FB_SERIAL" <<'''PY'''
import sys
d = open(sys.argv[1], "rb").read().decode("latin-1")
i = d.find("FB BAR FD000000")
if i < 0:
    sys.exit("the FB line is missing entirely")
tail = d[i:]
if "PCI TOTAL 0006" not in tail:
    sys.exit("no PCI enumeration ran AFTER the graphics mode was set, so "
             "nothing proves the framebuffer is a live console rather than a "
             "banner painted once")
PY
[[ $? -eq 0 ]] || fail "the framebuffer boot did not run a command after the mode was set"
echo "ASSERT: pass  a full PCI enumeration ran AFTER the mode set and went through conPutc, so the framebuffer is a live console rather than a painted banner"

# 6d. THE TEXT CONSOLE IS NOT REMOVED -- AND 0xB8000 REALLY DOES STOP BEING A
#     TEXT BUFFER WHEN A GRAPHICS MODE IS SET.
#
# Both halves are asserted, because the first alone would be a claim and the
# second alone would look like a regression.
#
#   * On the SESSION boot, which never runs `fb`, the 80x25 text buffer matches
#     `expected-screen.txt` byte-for-byte (step 5d). The text console is
#     untouched by this milestone on every boot that does not deliberately
#     switch the adapter.
#   * On THIS boot, which does, the same guest-physical read comes back as
#     pixel data rather than character cells. That is the adapter aliasing its
#     legacy window into video RAM, and it is why `conPutc` writes exactly one
#     screen: continuing to write 0xB8000 after the mode set would scribble two
#     bytes into the middle of the framebuffer for every character printed.
#     Measured, not assumed -- the first M5 build did exactly that.
#
# `?` is what qmp-drive.py renders a non-printable cell as, so a text buffer
# that is no longer text is a screen made almost entirely of them.
FB_QMARKS=$(tr -cd '?' <"$FB_SCREEN" | wc -c | tr -d ' ')
if [[ "$FB_QMARKS" -lt 1000 ]]; then
  cat -n "$FB_SCREEN" >&2
  fail "after the graphics mode was set, 0xB8000 still reads back as $((2000 - FB_QMARKS)) printable text cells. Either the mode was not actually set, or this kernel's understanding of the aperture (core/kernel/vga.dart's conPutc, known-gaps GAP-0071) is wrong."
fi
grep -q "^PCI TOTAL 0006$" "$SCREEN_TEXT" || {
  cat -n "$SCREEN_TEXT" >&2
  fail "the SESSION boot's 80x25 text buffer does not contain the PCI listing -- the text console regressed on a boot that never set a graphics mode"
}
echo "ASSERT: pass  the text console is intact on the session boot, and on THIS boot 0xB8000 stops being a text buffer the moment the mode is set ($FB_QMARKS of 2000 cells are pixel data) -- which is why conPutc drives one screen at a time"

# 6e. This boot's own screenshot.
[[ -s "$FB_SHOT_PNG" ]] || fail "no framebuffer screenshot was produced at $FB_SHOT_PNG"
case "$(head -c 8 "$FB_SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$FB_SHOT_PNG is not a PNG" ;;
esac
echo "ASSERT: pass  framebuffer screenshot written to $FB_SHOT_PNG ($(wc -c <"$FB_SHOT_PNG" | tr -d ' ') bytes, PNG)"

# 6f. The framebuffer boot must DIFFER from the session golden. Same kernel,
# same hardware, different keys and a different display mode -- if the captures
# matched, `fb` would be doing nothing.
if cmp -s "$FB_SERIAL" "$EXPECTED_SERIAL"; then
  fail "the framebuffer boot produced the same serial capture as the session boot, which is impossible if fb ran"
fi


# ---------------------------------------------------------------------------
# Step 7 — THE BRIDGE BOOT.
#
# The same kernel, on DIFFERENT HARDWARE: a real PCI-to-PCI bridge at 00:1E
# with an e1000 behind it. Nothing about the kernel changes; what changes is
# what is out there to find.
#
# This is what makes the bridge recursion in pciScanFunction evidence rather
# than decoration. QEMU's default i440FX has no PCI-to-PCI bridge at all, so
# on the session boot above that code path is never entered even once -- it
# would compile, pass every other assertion here, and be completely untested.
# Here it must produce a `>BUS 01` suffix and a device whose bus number is 01,
# which cannot appear in any other boot.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/bridge" "p,c,i,ret" "$WORKDIR/bridge/shot.png" "bridge" 1 \
  -device pci-bridge,chassis_nr=1,id=br0,addr=0x1e \
  -device e1000,bus=br0,addr=0x02

if ! python3 - "$WORKDIR/bridge/serial.txt" "$WORKDIR/bridge/info-pci.txt" <<'PY'
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

bridge_lines = [ln for ln in serial.split("\n")
                if ln.startswith("PCI ") and " >BUS " in ln]
if len(bridge_lines) != 1:
    fails.append("expected exactly one bridge line with a `>BUS` suffix, found "
                 "%d: %r" % (len(bridge_lines), bridge_lines))
else:
    m = re.match(r"^PCI 00:1E\.0 1B36:0001 06/04/00 H01 pci bridge >BUS 01$",
                 bridge_lines[0])
    if not m:
        fails.append("the bridge line is %r, expected "
                     "'PCI 00:1E.0 1B36:0001 06/04/00 H01 pci bridge >BUS 01' "
                     "-- header type 1, class 06/04, and the secondary bus "
                     "number read out of the bridge's own config space"
                     % bridge_lines[0])

behind = [ln for ln in serial.split("\n") if ln.startswith("PCI 01:")]
if len(behind) != 1:
    fails.append("expected exactly one device on bus 01 (the e1000 behind the "
                 "bridge), found %d: %r" % (len(behind), behind))
elif not behind[0].startswith("PCI 01:02.0 8086:100E 02/00/00 H00 ethernet"):
    fails.append("the device behind the bridge is %r, expected the e1000 at "
                 "01:02.0" % behind[0])

totals = [ln for ln in serial.split("\n") if ln.startswith("PCI TOTAL")]
if totals != ["PCI TOTAL 0008"]:
    fails.append("expected a single `PCI TOTAL 0008` (the six on bus 0, the "
                 "bridge, and the device behind it), got %r" % totals)

# And QEMU agrees there is a bus 1.
if not re.search(r"Bus\s+1,", info):
    fails.append("QEMU's own `info pci` does not report a bus 1 -- the bridge "
                 "boot did not actually create one, so the kernel's `>BUS 01` "
                 "would prove nothing")

if fails:
    print("m5-pci: bridge check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
then
  fail "the bridge boot did not exercise the bus recursion: no secondary bus was followed, or the device behind the bridge was not found"
fi
# It must also DIFFER from the session golden -- otherwise the goldens are not
# sensitive to what hardware is present, only to what was typed.
if cmp -s "$WORKDIR/bridge/serial.txt" "$EXPECTED_SERIAL"; then
  fail "the bridge boot produced the same serial capture as the session boot, which is impossible if the extra devices were really enumerated"
fi
echo "ASSERT: pass  bridge boot — the same kernel on hardware with a PCI-to-PCI bridge follows it to bus 01 and finds the e1000 behind it (PCI TOTAL 0008 vs 0006)"

# ---------------------------------------------------------------------------
# Step 8 — THE NEGATIVE CONTROL.
#
# A check that cannot fail is not a check. The same kernel, the same hardware,
# a DIFFERENT key sequence: both goldens must fail, and the serial divergence
# must start AFTER M1's 544 bytes -- if it started earlier, the goldens would
# be failing for a reason that has nothing to do with what was typed.
#
# The control sequence deliberately runs `pci` too, once, so what it proves is
# that the goldens are sensitive to HOW MANY times the bus was enumerated and
# what else was run, not merely to whether `pci` appeared at all.
# ---------------------------------------------------------------------------
NEG_KEYS="p,c,i,ret,c,p,u,ret"
drive_session "$WORKDIR/negative" "$NEG_KEYS" "$WORKDIR/negative/shot.png" "negative-control" 2

if cmp -s "$WORKDIR/negative/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a different key sequence produced the same serial capture. The serial golden is not actually sensitive to what was typed."
fi
if cmp -s "$WORKDIR/negative/screen.txt" "$EXPECTED_SCREEN"; then
  fail "NEGATIVE CONTROL FAILED: a different key sequence produced the same framebuffer. The screen golden is not actually sensitive to what was typed."
fi
grep -q "^PCI TOTAL 0006$" "$WORKDIR/negative/serial.txt" || \
  fail "NEGATIVE CONTROL FAILED: the control boot did not enumerate the bus successfully, so its divergence says nothing about the goldens"
NEG_DIVERGE=$(cmp "$WORKDIR/negative/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE 'byte [0-9]+' | grep -oE '[0-9]+' | head -1)
[[ -n "$NEG_DIVERGE" ]] || NEG_DIVERGE=$(( M1_BYTES + 1 ))
if [[ "$NEG_DIVERGE" -le "$M1_BYTES" ]]; then
  fail "NEGATIVE CONTROL FAILED: the divergence starts at byte $NEG_DIVERGE, which is inside M1's ${M1_BYTES}-byte golden — the goldens are failing for a reason unrelated to what was typed."
fi
echo "ASSERT: pass  negative control — a different key sequence (which also enumerates the bus) fails BOTH goldens, serial diverging at byte $NEG_DIVERGE (M1's golden is $M1_BYTES bytes, so the divergence is entirely in the shell session)"

echo "M5-pci: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S + portio.S) -> link -> 5 structural checks -> verify-freestanding pass ($EXTERN_COUNT declared externs, portio.o clean standalone) -> FOUR real QEMU boots (-m 128M -cpu qemu64 -vga std) over QMP. PART 1: a ${SERIAL_BYTES}-byte serial match with M1'''s golden intact as a prefix, six PCI devices enumerated over 0xCF8/0xCFC and matched device-for-device against QEMU'''s own info pci, the multi-function bit honoured with no aliased duplicates, three identical enumerations one of which ran after a deliberate fault, and a bridge boot that follows a PCI-to-PCI bridge to bus 01. PART 2: BAR0 discovered at FD000000 and confirmed by QEMU, a 800x600x32 mode set through the Bochs VBE registers, and 6528 pixels read back out of guest memory at that address matching the banner re-rendered from the kernel'''s own 96-glyph font — plus the measured fact that 0xB8000 stops being a text buffer when the mode is set, which is why the text console is asserted on a boot that does not set one. Screenshots at $SHOT_PNG and $FB_SHOT_PNG, and a negative control that fails both goldens"
exit 0
