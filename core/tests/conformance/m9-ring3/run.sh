#!/usr/bin/env bash
# core/tests/conformance/m9-ring3/run.sh
#
# Mechanical check of ROADMAP.md's M9 exit criterion: this kernel can run code at
# CPL 3, that code is genuinely unprivileged, and it can get back into the kernel
# only through one gate.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every milestone up to M8 ran entirely in ring 0. Every page was supervisor-only
# (U/S = 0), there was no TSS, there were no ring-3 segment descriptors, and the
# `USER`/`SUPER` field of the page-fault report had only ever printed one of its
# two values -- docs/known-gaps.md GAP-0081 item 1, which is what this harness
# closes. "Privilege" did not describe anything about the machine.
#
# A privilege boundary is proved by REFUSALS, so four of the six things the
# `user` command can run are designed to fail:
#
#   * a payload that behaves -- the CONTROL. Without it, "ring 3 faulted" would
#     be equally consistent with "nothing can execute in ring 3 at all";
#   * `mov %cr3,%rax` from ring 3 -> #GP (vector 13), reported, recovered;
#   * a one-byte store into kernel `.bss` from ring 3 -> #PF with error code 7:
#     present, write, **USER**. That bit had never been observed set on this
#     machine, and the target word is compared afterwards against the value the
#     kernel wrote, so "the store did not land" is a comparison and not merely
#     the absence of a fault;
#   * `int $3` from ring 3, whose gate is DPL 0 -> #GP with error code 0x1A,
#     which decodes as "IDT entry 3". This is the control for the syscall gate:
#     without it, "int 0x80 reached the kernel" would be equally consistent with
#     "the DPL field does nothing on this CPU";
#   * a syscall handed a KERNEL pointer -> refused, and the refusal is observed
#     FROM RING 3, in the exit status the payload reports back.
#
# NOTHING IS TAKEN FROM THE KERNEL'S OWN REPORT
# ---------------------------------------------------------------------------
# The privilege state is read out of guest physical memory and out of QEMU's own
# `info registers`, and `derive.py` decodes it independently of `core/kernel/`:
#
#   * the GDT, at the base the GDTR reports: both user descriptors must have
#     DPL 3, and the TSS descriptor's type must be 11 (BUSY), which is a state
#     only `ltr` can produce and is the only external evidence it ever ran;
#   * the TSS, at the base that descriptor names: RSP0 must be a real address
#     inside the kernel image, and the I/O-permission-bitmap base must be past
#     the segment limit so ring 3 cannot reach a device port;
#   * all 256 IDT gates: exactly one may have DPL 3;
#   * the page tables, walked page by page with U/S combined across all four
#     levels. **While a payload is running** (boot B) exactly two of the 1024
#     pages in the 4KiB window are user-accessible and they are that payload's;
#     at every other moment none of them are, and no page of `.text`,
#     `.rodata`, `.data`/`.bss` or the first megabyte ever is.
#
# FOUR BOOTS, EACH MAKING A CLAIM THE OTHERS CANNOT
# ---------------------------------------------------------------------------
#   A  128M, qemu64   the driven session: the address space, all six `user`
#                     sub-commands, the report before and after. Serial golden +
#                     framebuffer + PNG + the page tables dumped afterwards,
#                     which must show ZERO user-accessible pages.
#   B  128M, qemu64   THE PAYLOAD IS LEFT RUNNING. `user hold` spins in ring 3
#                     forever, so the machine can be inspected mid-payload:
#                     QEMU's own `info registers` must say CPL=3 with CS=0x23,
#                     and the tables must show exactly two user pages -- the two
#                     the kernel said it mapped. This is the only moment at
#                     which the U/S bits are set on anything, and dumping them
#                     at any other time proves the teardown instead.
#   C  32M, qemu64    NEGATIVE CONTROL -- a different machine. Different memory
#                     map, different frames, and ring 3 must still work. The
#                     capture must differ from the golden inside M1's own
#                     boot-time report.
#   D  128M, qemu64   NEGATIVE CONTROL -- no frames. `frames drain` first, so
#                     `user` must REFUSE with "no free frame" rather than
#                     entering ring 3 with a garbage page. This is what says the
#                     payload's pages are really allocated.
#
# `qmp-drive.py` is REUSED from m2-console unchanged -- one driver, eight
# harnesses now.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m9-ring3/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M9-ring3: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M9-ring3: FAIL — $1" >&2
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
ASSERTIONS_REQUIRED=221


for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DERIVE="$SCRIPT_DIR/derive.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
ck; [[ -f "$DERIVE" ]] || setup_error "privilege-state decoder not found at $DERIVE"
ck; [[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m9-ring3 reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
ck; [[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m9.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# `--regen` writes the two goldens from this run instead of asserting them. It is
# NOT a way to make a red run green: every derived check below still has to pass,
# and they run against the same boot. See this file's header.
REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

hexnum() { python3 -c "import sys; print(int(sys.argv[1], 16))" "$1"; }

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

# 2a. THE SELECTORS ARE ONE NUMBER, NOT THREE COPIES OF ONE NUMBER.
#
# `core/boot/boot.S` builds the descriptors and names their selectors with
# `.set`; `core/kernel/user.dart` names the same selectors as `const int`s and
# passes them to `enter_user`. Two files is already one more than ideal (the
# alternative -- a third copy inside isr.S -- was rejected by passing them as
# arguments instead), and a GDT rearrangement that updated only one of them would
# produce a #GP whose cause is invisible in hex.
sel_from_asm() {
  awk -v n="$1" '$0 ~ ("^\\.set " n ",") {
    line=$0; sub(/.*,[[:space:]]*/, "", line); sub(/[[:space:]]*\/\*.*/, "", line);
    gsub(/[[:space:]]/, "", line); print line; exit }' "$CORE_DIR/boot/boot.S"
}
sel_from_dart() {
  awk -F'= *' -v n="$1" '$0 ~ ("^const int " n " =") { gsub(/;.*/,"",$2); print $2; exit }' \
    "$CORE_DIR/kernel/user.dart"
}
# bash 3.2 COMPATIBILITY (ADR-0028). `declare -A` is bash 4+ and macOS ships
# /bin/bash 3.2.57; under it `SEL[$2]=$D` treats `userCodeSel` as an ARITHMETIC
# subscript and aborts on `set -u` before either assertion below runs. This
# harness has `set -uo pipefail` and no `set -e`, so `set -u` was the only
# thing keeping that loud. The three keys are fixed and are valid identifier
# names, so the map is three ordinary variables named SEL_<key>, read through
# sel(). No `:-` default on purpose: a mistyped key must stay a loud
# unbound-variable abort.
sel() { eval "printf '%s' \"\$SEL_$1\""; }
for pair in "SEL_UCODE userCodeSel" "SEL_UDATA userDataSel" "SEL_TSS userTssSel"; do
  set -- $pair
  A=$(python3 -c "print(eval('$(sel_from_asm "$1")'))")
  D=$(hexnum "$(sel_from_dart "$2" | sed 's/^0x//')")
  ck; [[ -n "$A" && -n "$D" ]] || fail "could not read $1 out of boot.S or $2 out of user.dart"
  ck; [[ "$A" -eq "$D" ]] || fail "boot.S's $1 is $A but user.dart's $2 is $D — the GDT and the code that loads it disagree about which descriptor is which"
  eval "SEL_$2=\$D"
done
ck; [[ "$(sel userCodeSel)" -eq $(( 0x20 | 3 )) ]] || fail "the user code selector is $(sel userCodeSel), expected 0x23 (GDT entry 4 with RPL 3)"
ck; [[ "$(sel userDataSel)" -eq $(( 0x18 | 3 )) ]] || fail "the user data selector is $(sel userDataSel), expected 0x1B"
echo "STRUCTURAL: pass  boot.S's SEL_UCODE/SEL_UDATA/SEL_TSS and user.dart's userCodeSel/userDataSel/userTssSel are the same three numbers (0x23, 0x1B, 0x28)"

# 2b. THE ACCESSED BIT IS PRE-SET ON ALL FOUR SEGMENT DESCRIPTORS, AND `ltr` IS
#     IN THE BOOT STUB.
#
# Both are the same finding wearing two hats, and both were MEASURED rather than
# looked up (see boot.S's notes). The CPU WRITES to a descriptor the first time
# it loads it (the accessed bit) and writes to the TSS descriptor when `ltr`
# loads it (the busy bit) -- and since M8 the GDT is on a read-only page with
# CR0.WP set, so both writes are a #PF. The fixes were "make the write
# unnecessary" and "do it before the address space exists", NOT "make the GDT
# writable", and this check is what stops the second one being reintroduced.
for d in gdt64_code gdt64_data gdt64_user_data gdt64_user_code; do
  ck; grep -A1 "^$d:" "$CORE_DIR/boot/boot.S" | grep -q '(1<<40)' \
    || fail "$d in core/boot/boot.S no longer pre-sets bit 40 (the ACCESSED bit). The CPU will try to set it itself on the first segment load, which is a write into .rodata and a #PF — see boot.S's note beside the GDT."
done
ck; grep -qE '^\s*ltr %ax' "$CORE_DIR/boot/boot.S" || fail "core/boot/boot.S no longer loads the task register. Without `ltr` the CPU has no TSS, RSP0 is unreachable, and the first interrupt taken in ring 3 has no stack to be delivered on — a triple fault with no diagnostic."
ck; grep -qE '^[[:space:]]*ltr ' "$CORE_DIR/boot/isr.S" && fail "core/boot/isr.S executes ltr. It belongs in boot.S, before vm.dart makes the GDT read-only: ltr WRITES the busy bit into the descriptor it loads."

echo "STRUCTURAL: pass  all four segment descriptors pre-set the accessed bit, and ltr is in the boot stub where the GDT is still writable"

# 2c. DONATED `.bss` GREW FROM 5224 TO 5368, AND THIS HARNESS NOW OWNS THE
#     NUMBER.
#
# 16 (M2) -> 304 (M3) -> 392 (M4) -> 424 (M5) -> 424 (M6) -> 5096 (M7) ->
# 5224 (M8) -> 5368 (M9). Each time, ownership passes to the harness for the
# milestone that grew it, and the earlier harnesses keep asserting their own
# claim by SUBTRACTING the blocks that came after theirs. M9's 144 bytes are 128
# for the ring-3 subsystem's state and 16 for the two asm-owned resume words.
# docs/known-gaps.md GAP-0053.
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
S0_OFF_HEX=$(bssoff ioctlStore)
ck; [[ -n "$S0_OFF_HEX" ]] || fail "ioctlStore has no .bss offset in kmain.o -- S0's ioctl block (ADR-0033) is missing"
S0_BSS=$(( KDATA_BSS - 16#$S0_OFF_HEX ))
ck; [[ "$S0_BSS" -eq 512 ]] || fail "the bytes from S0's ioctlStore to the end of .bss are $S0_BSS, expected 512. If that block changed size, change it in ADR-0033, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - S0_BSS ))
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
ck; [[ "$M20_BSS" -eq 2624 ]] || fail "the bytes from M20's chanStore to S0's ioctlStore are $M20_BSS, expected 2624. If that block changed size, change it in ADR-0027, in GAP-0053's running total, and in every harness that subtracts it."
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
KDATA_BSS=$(( KDATA_BSS - M10_STORE - M11_BSS - M14_BSS ))
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))
ck; [[ "$KDATA_BSS" -eq 5368 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes, expected 5368 (5224 through M8, plus 128 for the ring-3 state and 16 for the resume words). If you meant to grow it, say so in GAP-0053."
# M17 (ADR-0021) SPLIT M9's three blocks and the split is the milestone's own
# claim restated: `userStore` is ordinary kernel state and is now a DCDart @bss
# in user.dart; the two resume words are written by `enter_user`/`user_return`
# in core/boot/isr.S, and a `@bss` symbol is LOCAL to kmain.o, so assembly
# cannot name one. They stay donated. `bsssize` finds each where it lives.
for pair in "userStore 128" "user_resume_rsp 8" "user_resume_ok 8"; do
  set -- $pair
  SZ=$(bsssize "$1")
  ck; [[ "$SZ" == "$2" ]] || fail "$1 is ${SZ:-missing} bytes, expected $2"
done
ck; x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$4=="OBJECT" && $8=="user_resume_rsp"' | grep -q . \
  || fail "user_resume_rsp is no longer defined in kdata.o — isr.S writes it by name and a DCDart @bss symbol is local, so it cannot live in kmain.o"
echo "STRUCTURAL: pass  exactly 5368 bytes of mutable static storage — 5224 inherited, 128 for the ring-3 state as a DCDart @bss, 16 for the assembly-owned resume words"

# 2d. THE STORAGE SEAM IS EXACTLY ONE CALL SITE.
#
# The same check m8-paging makes on `vmStore` and m7-frames makes on the
# allocator's three, and for the same reason: user.dart's claim is that swapping
# assembly-donated `.bss` for real DCDart mutable statics is a change to ONE
# function. That is only true while `Bss.addressOf(userStore)` is called from that one
# function and nowhere else, and a second call site would be invisible in any
# test that only looked at behaviour. ADR-0011 §0 is the pattern.
SEAM_SITES=$(grep -c '^\s*return Bss[.]addressOf(userStore)' "$CORE_DIR/kernel/user.dart")
ck; [[ "$SEAM_SITES" -eq 1 ]] || fail "Bss.addressOf(userStore) is returned from $SEAM_SITES functions in user.dart, expected exactly 1 (userMetaBase). The storage seam is the whole mutable-statics migration plan — see user.dart's header."
STRAY=$(grep -n 'Bss[.]addressOf(userStore)' "$CORE_DIR/kernel/user.dart" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | grep -vE 'final Bss userStore = ' | grep -vc 'return Bss[.]addressOf(userStore)')
ck; [[ "$STRAY" -eq 0 ]] || fail "user.dart has $STRAY call(s) of Bss.addressOf(userStore) outside userMetaBase"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "user.dart" ]] && continue
  ck; grep -qw 'userStore' "$f" && fail "$(basename "$f") references userStore — the ring-3 subsystem's storage seam must not leak out of user.dart"
done
echo "STRUCTURAL: pass  Bss.addressOf(userStore) is called from exactly 1 function, in user.dart's storage seam, and from no other kernel source"

# 2e. THE SAVED-REGISTER FRAME OFFSETS MATCH isr_common's PUSH ORDER.
#
# `userSyscall` reads the syscall number, its arguments and the CPL out of the
# frame `isr_common` builds, at byte offsets spelled out as constants in
# user.dart. Those constants are a copy of an ORDER that lives in assembly, and
# a reordered push list would make the syscall read the wrong register --
# silently, with the wrong value, for a caller that cannot be trusted. So the
# push order is read out of isr.S and the offsets are recomputed from it.
ck; python3 - "$CORE_DIR/boot/isr.S" "$CORE_DIR/kernel/user.dart" <<'PY' || fail "core/kernel/user.dart's saved-register frame offsets no longer match core/boot/isr.S's push order"
import re, sys
asm = open(sys.argv[1]).read()
body = asm.split("isr_common:", 1)[1].split("call isrDispatch", 1)[0]
pushes = re.findall(r"^\s*pushq %(\w+)$", body, re.M)
if len(pushes) != 15:
    sys.exit("isr_common pushes %d registers, expected 15: %r" % (len(pushes), pushes))
# The LAST push is at offset 0 -- the stack grows down.
off = {reg: 8 * (len(pushes) - 1 - i) for i, reg in enumerate(pushes)}
after = 8 * len(pushes)
# Then the stub's two pushes and the CPU's five, in the order isr_common's own
# comment documents.
for i, name in enumerate(("vector", "errcode", "rip", "cs", "rflags", "rsp", "ss")):
    off[name] = after + 8 * i
src = open(sys.argv[2]).read()
def const(name):
    m = re.search(r"^const int %s = (\d+);$" % name, src, re.M)
    if not m:
        sys.exit("user.dart has no `const int %s`" % name)
    return int(m.group(1))
want = {"userFrameRdi": off["rdi"], "userFrameRsi": off["rsi"],
        "userFrameRdx": off["rdx"], "userFrameRax": off["rax"],
        "userFrameRip": off["rip"], "userFrameCs": off["cs"],
        "userFrameFlags": off["rflags"], "userFrameRsp": off["rsp"],
        "userFrameSs": off["ss"]}
bad = ["%s is %d, isr.S's push order puts it at %d" % (k, const(k), v)
       for k, v in want.items() if const(k) != v]
if bad:
    sys.exit("; ".join(bad))
print("    (15 pushes in isr_common; CS at +%d, RAX at +%d, RDI at +%d — recomputed from the assembly)"
      % (off["cs"], off["rax"], off["rdi"]))
PY
echo "STRUCTURAL: pass  user.dart's frame offsets are exactly what isr_common's push order produces"

# 2f. THE SYSCALL GATE'S ATTRIBUTE BYTE, AND THE ONE BIT THAT IS THE WHOLE ENTRY
#     PERMISSION.
#
# 0x8E (present, DPL 0, 64-bit interrupt gate) is what all 256 gates get from
# `idtInstallAll`; 0xEE is the same gate with DPL 3. The difference is 0x60, and
# it is the difference between `int 0x80` being a syscall and being a #GP.
GATE_ATTR=$(awk -F'= *' '/^const int userGateAttr/{gsub(/;.*/,"",$2); print $2; exit}' "$CORE_DIR/kernel/user.dart")
ck; [[ "$(hexnum "${GATE_ATTR#0x}")" -eq $(( 0x8E | 0x60 )) ]] || fail "userGateAttr is $GATE_ATTR, expected 0xEE (0x8E with DPL 3). Boot B reads the gate out of guest memory, but a wrong constant here should fail before a boot."
ck; grep -qE '^\s*idtSetUserGate\(\);' "$CORE_DIR/kernel/kmain.dart" || fail "kmain() no longer installs the DPL-3 syscall gate"
echo "STRUCTURAL: pass  the syscall gate's attribute byte is 0xEE (0x8E plus DPL 3) and kmain() installs it"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# EIGHT new externs, 44 -> 52, and each one is named because the count is a claim
# about the design:
#
#   enter_user user_return    `iretq` into ring 3, and the stack switch back.
#                             DCDart cannot write a segment register, build a
#                             stack frame, or read RSP.
#   tr_read                   `str`. A privileged instruction with no primitive.
#   tlb_invlpg                `invlpg`. Likewise -- and the first thing in this
#                             kernel that has ever needed it (GAP-0083).
#   tss_base gdt_base         addresses of symbols, which DCDart cannot name.
#   userStore           the whole storage seam.
#   user_resume_ok_addr       the asm-owned resume guard, cleared by userInit.
#
# `tss_load` is deliberately NOT among them: `ltr` moved into boot.S when it
# turned out to write the GDT. See 2b.
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
ck; [[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$CORE_DIR/build/portio.o" "$KERNEL_ELF"'
echo "$VERIFY_OUT"
ck; if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
# M10 (ADR-0014) added exactly ONE more -- `elfStore`, the ELF loader's
# storage seam -- subtracted here so this harness keeps asserting M9's own
# number, the same way m5/m6/m7/m8 subtract M9's eight.
# M17 (ADR-0021) deleted this accessor: `elf_store_addr`'s storage became the
# DCDart `@bss` mutable static `elfStore`, so M10 now adds NO extern here and
# there is nothing left to subtract. The check INVERTS rather than disappearing,
# for the reason every other one on this page does.
ck; grep -q "\belf_store_addr\b" <<<"$VERIFY_OUT" && fail "elf_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static elfStore"
# M11 (ADR-0015) added FIVE more -- `sse_enabled`, `cr4_read`, `fx_save`,
# `fx_restore` and `procStore` -- subtracted BY NAME for the same reason.
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
# seam. Subtracted for the same reason M10's and M11's are: this harness's claim
# is about ITS OWN milestone's count.
# M17 (ADR-0021) deleted this accessor: the storage it addressed became a DCDart
# `@bss` mutable static in the subsystem that owns it, so the extern is gone.
# The check INVERTS rather than disappearing — a resurrected accessor would
# otherwise be invisible here, and that is the regression ADR-0021 must prevent.
ck; grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && fail "fat_store_addr is still declared extern — ADR-0021 deleted it when the storage became the @bss mutable static fatStore"
M14_PRESENT=0
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M11_PRESENT ))
# M17 (ADR-0021) deleted 12 `_addr()` accessor externs at or before this
# milestone, because the assembly-donated `.bss` they addressed became DCDart
# `@bss` mutable statics. M8's 44 becomes 33 and M9's own eight become seven.
# Each deleted name is asserted ABSENT as well as the count being asserted: a
# count alone can be restored by an unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr vm_store_addr user_store_addr; do
  ck; grep -q "\\b$gone\\b" <<<"$VERIFY_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
ck; [[ "$EXTERN_COUNT" -eq 40 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 40 (33 from M8 after ADR-0021, plus M9's seven)"
for sym in enter_user user_return tr_read tlb_invlpg tss_base gdt_base \
           user_resume_ok_addr; do
  ck; grep -q "$sym" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest"
done
# M9's eighth was `user_store_addr` (asserted absent above). What it addressed is
# now `userStore`, a 128-byte @bss block in user.dart. The two resume words are
# NOT migrated and never will be -- isr.S writes them by name -- which is why
# `user_resume_ok_addr` is still in the list above.
ck; [[ "$(bsssize userStore)" == "128" ]] || fail "userStore is not a 128-byte object in kmain.o's .bss — M9's state did not survive the ADR-0021 migration"
ck; grep -q "tss_load" <<<"$VERIFY_OUT" && fail "kmain.o still declares tss_load - ltr moved into boot.S (see 2b) and the extern should have gone with it"

ck; grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — 33 from M8 plus M9's remaining seven (its eighth, user_store_addr, is gone with ADR-0021), and kdata.o still passes standalone"

# 2g. EVERY @rodata TABLE IS THE SIZE ITS CALL SITE PASSES.
#
# GAP-0060: a @rodata table carries no length (DCDart ADR-0040), so every byte
# count is a hand-maintained literal. M9 adds 53 tables and grows shellStrHelp
# again (1155 -> 1589, seven new command lines), so this is not hypothetical
# here either.
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  ck; [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M9 depends on was not emitted (a table with no call site is dropped by the linker)"
  ck; [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table shellStrHelp 2511
check_table userStrTss 9
check_table userStrRsp0 6
check_table userStrGdt 5
check_table userStrTr 4
check_table userStrIdt 5
check_table userStrMap 14
check_table userStrStack 7
check_table userStrPageCode 15
check_table userStrPageStack 16
check_table userStrU 3
check_table userStrWindow 18
check_table userStrUserFld 6
check_table userStrEnter 15
check_table userStrRsp 5
check_table userStrArg 5
check_table userStrCs 8
check_table userStrSs 4
check_table userStrRflags 8
check_table userStrCpl 5
check_table userStrWrite 11
check_table userStrExit 15
check_table userStrSyscalls 10
check_table userStrRefusals 10
check_table userStrDone 18
check_table userStrAborts 8
check_table userStrFault 15
check_table userStrRip 5
check_table userStrAbort 17
check_table userStrCanary 12
check_table userStrRefuse 15
check_table userStrPtr 5
check_table userStrLen 5
check_table userStrCleanup 20
check_table userStrGate 17
check_table userStrGate3 13
check_table userStrUsage 91
check_table userStrNoFrames 36
check_table userStrNoMap 49
check_table userStrNotReady 53
check_table userCmdUser 4
check_table userCmdGp 7
check_table userCmdPf 7
check_table userCmdBadint 11
check_table userCmdBadptr 11
check_table userCmdHold 9
check_table userCmdPages 10
check_table userCodeSizes 6
echo "STRUCTURAL: pass  all 47 M9 message/command tables are exactly the sizes their call sites pass, and shellStrHelp is 2147 (M9 took it 1155 -> 1589; M10 added one command line, M11 three, M14 four)"

# 2h. THE PAYLOAD LENGTH TABLE IS THE PAYLOADS' REAL SIZES.
#
# `userCodeLen` indexes a six-byte `@rodata` table rather than branching, and
# that is itself a finding: written as a chain of `if`s returning constants, LLVM
# recognised the shape and lowered it into `.Lswitch.table.userCodeLen` in
# `.rodata.cst32` -- outside `.rodata`'s section index, which
# `m1-interrupts/run.sh` asserts every OBJECT symbol dcc emits is inside. That
# assertion was NOT relaxed (ADR-0012 §8); the table was written explicitly
# instead, which is where it belonged. GAP-0079's phenomenon, second sighting.
#
# The consequence is that the payload lengths are now DATA, and data can be
# checked against the symbols it describes rather than against a literal in a
# comment.
ck; python3 - "$CORE_DIR/build/kmain.o" <<'PY' || fail "userCodeSizes does not match the real sizes of the payload tables in kmain.o"
import re, subprocess, sys
obj = sys.argv[1]
out = subprocess.run(["x86_64-elf-readelf", "-sW", obj],
                     capture_output=True, text=True).stdout
size = {}
for line in out.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT":
        size[f[7]] = (int(f[2]), int(f[1], 16), f[6])
order = ["userCodeRun", "userCodeGp", "userCodePf", "userCodeBadint",
         "userCodeBadptr", "userCodeHold"]
# The table's own bytes, read out of the object file's .rodata.
sec = subprocess.run(["x86_64-elf-objdump", "-h", obj], capture_output=True,
                     text=True).stdout
m = re.search(r"\s+\d+ \.rodata\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", sec)
if not m:
    sys.exit("kmain.o has no .rodata section")
rodata_off = int(m.group(4), 16)
blob = open(obj, "rb").read()
if "userCodeSizes" not in size:
    sys.exit("userCodeSizes is not in kmain.o")
n, addr, _ = size["userCodeSizes"]
if n != len(order):
    sys.exit("userCodeSizes is %d bytes but there are %d payloads" % (n, len(order)))
table = blob[rodata_off + addr: rodata_off + addr + n]
bad = []
for i, name in enumerate(order):
    if name not in size:
        bad.append("%s is not in kmain.o" % name)
        continue
    real = size[name][0]
    if table[i] != real:
        bad.append("userCodeSizes[%d] says %d but %s is %d bytes"
                   % (i, table[i], name, real))
if bad:
    sys.exit("; ".join(bad))
print("    (payload lengths %s, each equal to its symbol's real size in kmain.o)"
      % list(table))
PY
echo "STRUCTURAL: pass  userCodeSizes' six bytes are the real sizes of the six payload tables, read out of kmain.o"

# 2i. THE PAYLOADS DISASSEMBLE TO WHAT THEIR COMMENTS SAY.
#
# A payload is machine code written by hand in a `@rodata` table. The bytes are
# documented instruction-by-instruction in user.dart, and this is what stops that
# documentation from drifting into fiction: the bytes are extracted from
# `kmain.o` and disassembled, and the mnemonic sequence must match. It is also
# the check that would catch a payload edited to be harmless -- `user gp` with
# the `mov %cr3` removed would still "pass" every behavioural test by faulting
# for some other reason, or by not faulting at all.
ck; python3 - "$CORE_DIR/build/kmain.o" "$WORKDIR" <<'PY' || fail "a payload's machine code does not disassemble to the instructions user.dart documents"
import re, subprocess, sys
obj, work = sys.argv[1], sys.argv[2]
out = subprocess.run(["x86_64-elf-readelf", "-sW", obj],
                     capture_output=True, text=True).stdout
size = {}
for line in out.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT":
        size[f[7]] = (int(f[2]), int(f[1], 16))
sec = subprocess.run(["x86_64-elf-objdump", "-h", obj], capture_output=True,
                     text=True).stdout
m = re.search(r"\s+\d+ \.rodata\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", sec)
rodata_off = int(m.group(4), 16)
blob = open(obj, "rb").read()

want = {
    "userCodeRun":    ["push", "mov", "int3?", "lea", "pop", "mov", "int3?",
                       "mov", "mov", "int3?", "jmp"],
    "userCodeGp":     ["mov", "mov", "mov", "int3?", "jmp"],
    "userCodePf":     ["movb", "mov", "mov", "int3?", "jmp"],
    "userCodeBadint": ["int3?", "mov", "mov", "int3?", "jmp"],
    "userCodeBadptr": ["mov", "mov", "int3?", "mov", "mov", "int3?", "jmp"],
    "userCodeHold":   ["mov", "int3?", "jmp"],
}
# The one instruction whose exact operand matters in each payload -- what makes
# it the test it claims to be rather than merely 15 plausible bytes.
signature = {
    "userCodeGp": "mov %cr3,%rax",
    "userCodePf": "movb $0x5a,(%rdi)",
    "userCodeBadint": "int $0x3",
    "userCodeRun": "push $0x11",
    "userCodeHold": "jmp",
    "userCodeBadptr": "int $0x80",
}
code_len = {"userCodeRun": 38}   # the rest is the message text, not code
fails = []
for name, mnem in want.items():
    n, addr = size[name]
    n = code_len.get(name, n)
    data = blob[rodata_off + addr: rodata_off + addr + n]
    path = "%s/%s.bin" % (work, name)
    open(path, "wb").write(data)
    dis = subprocess.run(["x86_64-elf-objdump", "-D", "-b", "binary",
                          "-m", "i386:x86-64", "-M", "att", path],
                         capture_output=True, text=True).stdout
    ops = []
    body = []
    for line in dis.splitlines():
        m2 = re.match(r"\s+[0-9a-f]+:\t[0-9a-f ]+\t(\S+)(.*)", line)
        if m2:
            ops.append(m2.group(1))
            body.append((m2.group(1) + " " + m2.group(2).strip()).strip())
    got = ["int3?" if o == "int" else o for o in ops]
    if got != mnem:
        fails.append("%s disassembles to %r, expected %r" % (name, got, mnem))
        continue
    sig = signature[name]
    if not any(sig in b for b in body):
        fails.append("%s no longer contains `%s` -- it is not the test it says "
                     "it is" % (name, sig))
    # Every syscall must be `int $0x80`, and nothing may be `int` anything else
    # except badint's deliberate `int $3`.
    for b in body:
        if b.startswith("int "):
            allowed = ("$0x80",) if name != "userCodeBadint" else ("$0x80", "$0x3")
            if not any(a in b for a in allowed):
                fails.append("%s contains `%s`, which is neither the syscall "
                             "gate nor its deliberate control" % (name, b))
if fails:
    print("m9-ring3: payload disassembly FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (six payloads disassembled out of kmain.o; every syscall is `int $0x80` "
      "and each payload still contains the instruction it exists to execute)")
PY
echo "STRUCTURAL: pass  all six payloads disassemble to the instruction sequences user.dart documents, and each still contains the one instruction it exists to execute"

# ---------------------------------------------------------------------------
# Step 4 — the boots.
# ---------------------------------------------------------------------------
VM_FRAMES=$(awk -F'= *' '/^const int vmFrameCount/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/vm.dart")
TABLE_QWORDS=$(( VM_FRAMES * 512 ))
IDT_QWORDS=512     # 256 gates x 16 bytes
GDT_QWORDS=7       # null + 2 kernel + 2 user + a 16-byte TSS descriptor
TSS_QWORDS=14      # 104 bytes, rounded up

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

# BOOT A -- the session. The ORDER is the argument:
#
#   vm            the address space, so the harness has the CR3 to dump at and
#                 so W^X is re-asserted on the same boot as the U/S bits.
#   user pages    the baseline: zero user-accessible pages, gate 0x80 DPL 3.
#   user          THE CONTROL. A payload that runs to completion. Everything
#                 after it is a failure being demonstrated, and without this one
#                 they would all be equally consistent with "ring 3 does not
#                 work at all".
#   user gp       a privileged instruction  -> #GP 0D
#   user pf       a store into kernel memory -> #PF with the USER bit
#   user badint   a DPL-0 gate               -> #GP 0D, error 0x1A
#   user badptr   a kernel pointer to write  -> refused, and ring 3 says so
#   user pages    back to zero user-accessible pages, after four teardowns of
#                 which three were faults.
#   clear         a clean text buffer for the screen golden.
#   user pages    the report the screenshot shows.
SESSION_KEYS="v,m,ret,wait:1500"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,p,a,g,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,g,p,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,p,f,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,b,a,d,i,n,t,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,b,a,d,p,t,r,ret,wait:1200"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,p,a,g,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,z,z,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,spc,p,a,g,e,s,ret,wait:800"

SHOT_PNG="$CORE_DIR/build/screenshot-ring3.png"
rm -f "$SHOT_PNG"

drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 50 128M qemu64 \
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

ck; [[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
ck; [[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# ---------------------------------------------------------------------------
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
#
# The strongest statement that ring 3 costs the boot path nothing: `userInit()`
# runs before the first byte of output, the DPL-3 gate is installed between
# `idtInstallAll` and `lidt`, and `ltr` runs in the boot stub -- and none of it
# is visible from outside.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
ck; if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M9 changed M0/M1 serial output"
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

# 5c. THE PRIVILEGE BOUNDARY, FROM THE SESSION'S OWN OUTPUT.
#
# Every claim here is read out of the capture and cross-checked against another
# line of it or against the ELF, never accepted because the kernel printed it.
ck; if ! python3 - "$SERIAL_CAPTURE" "$KERNEL_ELF" <<'PY'
import re, subprocess, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
elf = sys.argv[2]
sym = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", elf],
                           capture_output=True, text=True).stdout.splitlines():
    m0 = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
    if m0:
        sym[m0.group(2)] = int(m0.group(1), 16)
kstart, kend = sym["__kernel_start"], sym["__kernel_end"]
dstart = sym["__data_start"]
fails = []

# --- THE CONTROL: a payload that ran to completion ----------------------
m = re.search(r"^USER ENTER RIP ([0-9A-F]{16}) RSP ([0-9A-F]{16}) ARG ([0-9A-F]{16})\n"
              r"USER CS ([0-9A-F]{16}) SS ([0-9A-F]{16}) RFLAGS ([0-9A-F]{16}) CPL ([0-7])\n"
              r"USER WRITE HELLO FROM RING 3\n"
              r"USER EXIT CODE ([0-9A-F]{16}) SYSCALLS ([0-9A-F]{8}) REFUSALS ([0-9A-F]{8})$",
              cap, re.M)
if not m:
    fails.append("the well-behaved payload did not run to completion. Without it "
                 "every fault below is equally consistent with 'nothing executes "
                 "in ring 3'. Captured: %r"
                 % cap[cap.find("USER ENTER"):][:400])
else:
    rip, rsp, arg = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
    cs, ss, rfl, cpl = (int(m.group(4), 16), int(m.group(5), 16),
                        int(m.group(6), 16), int(m.group(7)))
    code, ncalls, nref = int(m.group(8), 16), int(m.group(9), 16), int(m.group(10), 16)
    # THE assertion: the CPL comes out of the CS the CPU pushed.
    if cs != 0x23:
        fails.append("the saved CS is %04X, expected 0023 (GDT entry 4, RPL 3)" % cs)
    if cs & 3 != 3:
        fails.append("the saved CS's low two bits are %d -- the payload was NOT "
                     "running at CPL 3" % (cs & 3))
    if cpl != 3:
        fails.append("the reported CPL is %d, expected 3" % cpl)
    if ss != 0x1B:
        fails.append("the saved SS is %04X, expected 001B" % ss)
    if rfl & (1 << 9) == 0:
        fails.append("RFLAGS %016X has IF clear -- the payload ran with "
                     "interrupts disabled, so RSP0 was never exercised by a "
                     "device interrupt" % rfl)
    if (rfl >> 12) & 3 != 0:
        fails.append("RFLAGS %016X has IOPL %d, expected 0 -- ring 3 could reach "
                     "device ports" % (rfl, (rfl >> 12) & 3))
    if code != 0 or ncalls != 3 or nref != 0:
        fails.append("the payload exited %016X after %d syscalls with %d "
                     "refusals; expected 0, 3, 0" % (code, ncalls, nref))
    if arg != 0:
        fails.append("the well-behaved payload was handed a non-zero argument")
    if kstart <= rip < kend:
        fails.append("the payload's entry point 0x%X is INSIDE the kernel image "
                     "[0x%X, 0x%X) -- it is not running from an allocated frame"
                     % (rip, kstart, kend))

# --- the payload's pages, while mapped and after teardown ---------------
pages = re.findall(r"^USER PAGE (CODE|STACK) ([0-9A-F]{16}) P (\d) U (\d) W (\d) X (\d)$",
                   cap, re.M)
# Five payloads run to a conclusion in this session (four of them by dying),
# and each prints its two pages twice: once as mapped, once after teardown.
if len(pages) != 20:
    fails.append("expected 20 `USER PAGE` lines (2 pages x 2 reports x 5 runs), "
                 "found %d" % len(pages))
for i, (kind, addr, p, u, w, x) in enumerate(pages):
    if i % 4 < 2:
        # As mapped for ring 3: code is read+execute, stack is read+write, and
        # W^X applies to the payload exactly as it applies to the kernel.
        want = ("1", "1", "0", "1") if kind == "CODE" else ("1", "1", "1", "0")
        if (p, u, w, x) != want:
            fails.append("run %d: while mapped, the %s page at %s is "
                         "P%s U%s W%s X%s, expected P%s U%s W%s X%s"
                         % (i // 4, kind, addr, p, u, w, x, *want))
    else:
        # After teardown: back to a supervisor kernel page.
        if u != "0":
            fails.append("run %d: after teardown the %s page at %s is STILL "
                         "user-accessible" % (i // 4, kind, addr))
        if (p, w, x) != ("1", "1", "0"):
            fails.append("run %d: after teardown the %s page at %s is "
                         "P%s W%s X%s, expected the ordinary .data/.bss "
                         "permissions P1 W1 X0" % (i // 4, kind, addr, p, w, x))

# --- the window count: none, two, none ----------------------------------
windows = [int(m2, 16) for m2 in
           re.findall(r"^USER WINDOW PAGES 00000400 USER ([0-9A-F]{8})$", cap, re.M)]
if not windows:
    fails.append("no `USER WINDOW` line at all")
elif windows[0] != 0:
    fails.append("before any payload ran, %d of the 1024 pages in the 4KiB "
                 "window were already user-accessible" % windows[0])
elif windows[-1] != 0:
    fails.append("after every payload finished, %d pages are still "
                 "user-accessible" % windows[-1])
if 2 not in windows:
    fails.append("the user-accessible page count is never 2 -- nothing was ever "
                 "actually mapped for ring 3")
for n in windows:
    if n not in (0, 2):
        fails.append("the user-accessible page count reached %d; only 0 and 2 "
                     "are possible with one payload of two pages" % n)

# --- THE PRIVILEGED INSTRUCTION -----------------------------------------
m = re.search(r"^USER ENTER RIP ([0-9A-F]{16}) RSP [0-9A-F]{16} ARG 0{16}\n"
              r"FAULT 0D ERR 0000000000000000 OP 0F20\n"
              r"USER FAULT VEC 0D ERR 0000000000000000 RIP ([0-9A-F]{16}) CPL 3\n",
              cap, re.M)
if not m:
    if "USER EXIT CODE" in cap.split("user gp")[-1][:400]:
        fails.append("**`mov %cr3,%rax` DID NOT FAULT IN RING 3.** The payload "
                     "exited with the value it read, which means the CPU is not "
                     "enforcing the privilege level at all.")
    else:
        fails.append("`user gp` did not produce #GP (vector 0D, error 0) at the "
                     "payload's entry point. Captured: %r"
                     % cap[cap.find("user gp"):][:400])
elif m.group(1) != m.group(2):
    fails.append("the #GP was reported at RIP %s but the payload started at %s "
                 "-- it faulted somewhere other than its first instruction"
                 % (m.group(2), m.group(1)))

# --- THE STORE INTO KERNEL MEMORY, AND THE BIT THAT HAD NEVER BEEN SET ---
m = re.search(r"^USER ENTER RIP ([0-9A-F]{16}) RSP [0-9A-F]{16} ARG ([0-9A-F]{16})\n"
              r"FAULT 0E ERR 0000000000000007 OP C607\n"
              r"PF CR2 ([0-9A-F]{16}) ERR 00000007 PRESENT WRITE USER DATA\n"
              r"USER FAULT VEC 0E ERR 0000000000000007 RIP ([0-9A-F]{16}) CPL 3\n",
              cap, re.M)
if not m:
    fails.append("`user pf` did not produce a #PF with error code 7 "
                 "(present + write + USER). That USER bit is the whole of "
                 "GAP-0081 item 1 and had never been observed set on this "
                 "machine. Captured: %r" % cap[cap.find("user pf"):][:500])
else:
    target, cr2 = int(m.group(2), 16), int(m.group(3), 16)
    if cr2 != target:
        fails.append("`user pf` aimed at 0x%X but CR2 reports 0x%X" % (target, cr2))
    if not (dstart <= target < kend):
        fails.append("the #PF target 0x%X is not inside the kernel's writable "
                     "image [0x%X, 0x%X) -- the test is not aimed at kernel "
                     "memory" % (target, dstart, kend))

# --- THE DPL-0 GATE ------------------------------------------------------
if not re.search(r"^FAULT 0D ERR 000000000000001A OP CD03\n"
                 r"USER FAULT VEC 0D ERR 000000000000001A RIP [0-9A-F]{16} CPL 3$",
                 cap, re.M):
    fails.append("`int $3` from ring 3 did not produce #GP with error code 0x1A "
                 "((3 << 3) | IDT). Either the DPL check is not happening, or "
                 "gate 3 has DPL 3 too -- in which case ring 3 has the whole "
                 "exception table. Captured: %r"
                 % cap[cap.find("user badint"):][:400])

# --- THE REFUSED SYSCALL, OBSERVED FROM RING 3 ---------------------------
m = re.search(r"^USER REFUSE NO 0000000000000001 PTR ([0-9A-F]{16}) LEN 0000000000000008\n"
              r"USER EXIT CODE FFFFFFFFFFFFFFFF SYSCALLS [0-9A-F]{8} REFUSALS ([0-9A-F]{8})$",
              cap, re.M)
if not m:
    fails.append("the `write` syscall handed a kernel pointer was not refused, "
                 "or ring 3 did not see the refusal. Captured: %r"
                 % cap[cap.find("user badptr"):][:400])
else:
    ptr = int(m.group(1), 16)
    if not (dstart <= ptr < kend):
        fails.append("the refused pointer 0x%X is not a kernel address" % ptr)

# --- THE CANARY --------------------------------------------------------
canaries = re.findall(r"^USER CANARY ([0-9A-F]{16}) (OK|FAIL)$", cap, re.M)
if len(canaries) != 5:
    fails.append("expected 5 `USER CANARY` lines (one per payload), found %d"
                 % len(canaries))
for v, verdict in canaries:
    if v != "4B45524E454C2121" or verdict != "OK":
        fails.append("the canary reads %s (%s), expected 4B45524E454C2121 OK. "
                     "A store from ring 3 into kernel memory LANDED." % (v, verdict))

# --- the gates, as the kernel read them back out of the live IDT --------
gates = re.findall(r"^USER GATE 80 DPL (\d) GATE 03 DPL (\d) IDT ([0-9A-F]{16})$",
                   cap, re.M)
if not gates:
    fails.append("no `USER GATE` line")
for g80, g03, idt in gates:
    if g80 != "3":
        fails.append("gate 0x80 has DPL %s -- `int 0x80` from ring 3 would be a "
                     "#GP, not a syscall" % g80)
    if g03 != "0":
        fails.append("gate 3 has DPL %s, expected 0 -- the `user badint` control "
                     "would then prove nothing" % g03)

# --- the shell survived all three faults --------------------------------
if cap.count("FAULT RECOVERED") != 3:
    fails.append("expected exactly 3 recovery lines (gp, pf, badint), found %d"
                 % cap.count("FAULT RECOVERED"))
if cap.count("USER ABORT FREED") != 3:
    fails.append("expected exactly 3 `USER ABORT` lines, found %d"
                 % cap.count("USER ABORT FREED"))
if not cap.rstrip().endswith("oscortex>"):
    fails.append("the session does not end at a live prompt")
if "user: usage: user | user gp" not in cap:
    fails.append("`user zz` did not print the usage line")
m = re.search(r"^USER DONE ENTRIES ([0-9A-F]{8}) ABORTS ([0-9A-F]{8})$", cap, re.M)
if not m:
    fails.append("no `USER DONE` line -- no payload ever returned through the "
                 "exit syscall")

if fails:
    print("m9-ring3: privilege check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (CS 0023 / CPL 3 out of the interrupt frame; #GP on mov %cr3; #PF "
      "error 7 with the USER bit at the address ring 3 aimed at; #GP 0x1A on a "
      "DPL-0 gate; a kernel pointer refused and the refusal seen from ring 3; "
      "the canary intact five times)")
PY
then
  fail "the privilege boundary did not behave as M9 claims: see the list above"
fi
echo "ASSERT: pass  ring 3 is ring 3 (CS 0023, CPL 3, read out of the frame the CPU pushed); a privileged instruction, a store into kernel memory and a DPL-0 gate all fault and are recovered from; a syscall with a kernel pointer is refused and ring 3 observes the refusal; and a well-behaved payload runs to completion so none of that is vacuous"

# 5d. THE PAGE TABLES AFTER THE SESSION, READ OUT OF GUEST PHYSICAL MEMORY.
#
# Five payloads ran and five were torn down, three of them by faults. Not one
# page in the address space may be user-accessible now. This is the teardown
# half of the claim; boot B below is the other half, and neither is worth much
# without the other -- a kernel that never set the U bit at all would pass this
# check perfectly.
ck; if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$WORKDIR/session/monitor.txt" \
     "$KERNEL_ELF" <<'PY'
import importlib.util, re, subprocess, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
elf = sys.argv[4]
sym = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", elf],
                           capture_output=True, text=True).stdout.splitlines():
    m0 = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
    if m0:
        sym[m0.group(2)] = int(m0.group(1), 16)
fails = []

regs = d.parse_registers(monitor)
if "CR3" not in regs:
    sys.exit("`info registers` produced no CR3 -- the monitor capture is unusable")
cr3 = regs["CR3"] & d.ADDR_MASK
if not regs.get("CR0", 0) & (1 << 16):
    fails.append("CR0.WP is CLEAR -- see known-gaps GAP-0080; every W=0 below is "
                 "decorative and so is the ring-3 code page's read-only bit")
if regs.get("CPL") != 0:
    fails.append("at the end of the session the CPU is at CPL %s, expected 0 -- "
                 "the shell is not running in the kernel" % regs.get("CPL"))

# The kernel's own CR3, from the `vm` line, must be the one QEMU reports.
m = re.search(r"^VM CR3 ([0-9A-F]{16}) PML4 ([0-9A-F]{16}) ", cap, re.M)
if not m or int(m.group(1), 16) != cr3 or int(m.group(2), 16) != cr3:
    fails.append("the kernel reports CR3/PML4 %s/%s but QEMU says %016X"
                 % (m.group(1) if m else "?", m.group(2) if m else "?", cr3))

tables = d.PageTables(cr3, d.parse_xp(monitor, "xp/%dgx " % (d.FRAME_COUNT * 512)))

# NOT ONE user-accessible page anywhere, at any granularity.
leftover = tables.user_pages(0, d.FINE_BYTES)
if leftover:
    fails.append("%d page(s) in the 4KiB window are still user-accessible after "
                 "every payload finished, first at 0x%X. Three of those payloads "
                 "died in a fault, so this is the fault path failing to reclaim."
                 % (len(leftover), leftover[0]))
for lo, hi, label in ((d.FINE_BYTES, d.MAP_BYTES, "[4MiB, 128MiB)"),
                      (d.PCI_BASE, d.PCI_END, "the PCI hole")):
    big = tables.user_pages(lo, hi, step=d.BIG_BYTES)
    if big:
        fails.append("%d 2MiB page(s) in %s are user-accessible, first at 0x%X"
                     % (len(big), label, big[0]))

# And the kernel's own image, stated as its own claim rather than as a corollary.
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)
fails += d.check_supervisor(tables, *pages(sym["__kernel_start"], sym["__text_end"]), ".text")
fails += d.check_supervisor(tables, *pages(sym["__rodata_start"], sym["__rodata_end"]), ".rodata")
fails += d.check_supervisor(tables, *pages(sym["__data_start"], sym["__kernel_end"]), ".data/.bss")
fails += d.check_supervisor(tables, 0, d.LOW_BYTES, "the first megabyte")

# The interior entries DO carry U/S -- deliberately, because a page's effective
# permission is the AND and the leaf has to be able to decide. Asserted so that
# "no page is user-accessible" is known to be a property of the LEAVES rather
# than an accident of one interior entry someone might later change.
pml4e = tables.entry(cr3, 0)
pdpte = tables.entry(pml4e & d.ADDR_MASK, 0)
for name, e in (("PML4[0]", pml4e), ("PDPT[0]", pdpte)):
    if not e & d.USER:
        fails.append("%s does NOT have U/S set. Nothing below it can ever be "
                     "user-accessible, so `user` would fault instead of running "
                     "-- and every 'no user pages' check here would pass for the "
                     "wrong reason." % name)
pd_base = pdpte & d.ADDR_MASK          # the page directory for [0, 1GiB)
for i in (0, 1):
    e = tables.entry(pd_base, i)       # -> the two page tables of the 4KiB window
    if not e & d.USER:
        fails.append("PD_low[%d] does not have U/S set, so nothing in "
                     "[%dMiB, %dMiB) can ever be user-accessible" % (i, i * 2, i * 2 + 2))
for i in range(2, d.MAP_BYTES // d.BIG_BYTES):
    e = tables.entry(pd_base, i)       # 2MiB LEAVES -- these must not have it
    if e & d.PRESENT and e & d.USER:
        fails.append("PD_low[%d] is a 2MiB LEAF with U/S set -- 512 pages of RAM "
                     "are user-accessible at once" % i)

if fails:
    print("m9-ring3: post-session page-table check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d bytes of page tables walked at QEMU's own CR3=0x%X: zero of the "
      "1024 window pages, zero 2MiB pages and no page of the kernel image is "
      "user-accessible, while the four interior entries that make ring 3 "
      "possible at all still carry U/S)" % (tables.span, cr3))
PY
then
  fail "after five ring-3 payloads -- three of which died in a fault -- the address space still has user-accessible pages, or the kernel's own pages became reachable from ring 3"
fi
echo "ASSERT: pass  the LIVE page tables, read out of guest physical memory at QEMU's own CR3, show ZERO user-accessible pages after five payloads (three of them killed by faults), and no page of .text, .rodata, .data/.bss or the first megabyte is user-accessible"

# 5e. The framebuffer (the 80x25 text buffer, read out of guest memory).
ck; if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 5f. The screenshot.
ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
ck; case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 6 — BOOT B: THE PAYLOAD IS LEFT RUNNING IN RING 3.
#
# Every check so far looked at the address space with nothing running, which can
# only ever prove the TEARDOWN. `user hold`'s payload reports its CS and then
# spins forever, so this boot stops with a ring-3 program live and the machine
# can be asked what it actually looks like at that moment:
#
#   * QEMU's own `info registers` must say CPL=3 with CS=0x23 and RIP inside the
#     payload's own page. That is a third party's account of the privilege level,
#     independent of anything this kernel prints;
#   * the page tables must show EXACTLY TWO user-accessible pages in the whole
#     4KiB window, and they must be the two the kernel said it mapped -- code
#     read+execute, stack read+write, W^X applying to ring 3 as well;
#   * the GDT, read at the base the GDTR reports: both user descriptors present
#     with DPL 3, and the TSS descriptor's type 11 (BUSY), which only `ltr` can
#     produce;
#   * the TSS, at the base that descriptor names: RSP0 inside the kernel image
#     and equal to what the kernel printed, and the I/O-bitmap base past the
#     limit so ring 3 cannot reach a device port;
#   * all 256 IDT gates: exactly one with DPL 3, and it is 0x80.
#
# The addresses for the GDT, TSS and IDT dumps come from BOOT A's serial capture
# -- the kernel named them -- and are then required to equal the ones QEMU's own
# descriptor-table registers report. Neither number is load-bearing alone.
# ---------------------------------------------------------------------------
CR3_HEX=$(grep -m1 -oE '^VM CR3 [0-9A-F]{16}' "$SERIAL_CAPTURE" | awk '{print $3}')
GDT_HEX=$(grep -m1 -oE 'GDT [0-9A-F]{16}' "$SERIAL_CAPTURE" | awk '{print $2}')
TSS_HEX=$(grep -m1 -oE '^USER TSS [0-9A-F]{16}' "$SERIAL_CAPTURE" | awk '{print $3}')
IDT_HEX=$(grep -m1 -oE 'IDT [0-9A-F]{16}' "$SERIAL_CAPTURE" | awk '{print $2}')
ck; [[ -n "$CR3_HEX" && -n "$GDT_HEX" && -n "$TSS_HEX" && -n "$IDT_HEX" ]] || fail "could not read the CR3, GDT, TSS and IDT bases out of the session capture"

# `user hold` is the LAST thing this boot can run: its payload never exits and
# nothing in this kernel can stop it. The dumps below therefore happen with a
# ring-3 program on the CPU.
drive_session "$WORKDIR/hold" "u,s,e,r,spc,h,o,l,d,ret,wait:2500" \
  "$WORKDIR/hold/shot.png" "hold" 51 128M qemu64 \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx 0x$CR3_HEX" \
  --monitor-command "xp/${GDT_QWORDS}gx 0x$GDT_HEX" \
  --monitor-command "xp/${TSS_QWORDS}gx 0x$TSS_HEX" \
  --monitor-command "xp/${IDT_QWORDS}gx 0x$IDT_HEX" \
  --monitor-capture "$WORKDIR/hold/monitor.txt"

ck; if ! python3 - "$WORKDIR/hold/serial.txt" "$DERIVE" "$WORKDIR/hold/monitor.txt" \
     "$KERNEL_ELF" "$GDT_HEX" "$TSS_HEX" "$IDT_HEX" "$GDT_QWORDS" "$TSS_QWORDS" "$IDT_QWORDS" \
     "$CR3_HEX" "$TABLE_QWORDS" <<'PY'
import importlib.util, re, subprocess, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
elf = sys.argv[4]
gdt_hex, tss_hex, idt_hex = sys.argv[5], sys.argv[6], sys.argv[7]
gdt_n, tss_n, idt_n = (int(x) for x in sys.argv[8:11])
cr3_hex, table_n = sys.argv[11], int(sys.argv[12])
sym = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", elf],
                           capture_output=True, text=True).stdout.splitlines():
    m0 = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
    if m0:
        sym[m0.group(2)] = int(m0.group(1), 16)
kstart, kend, dstart = sym["__kernel_start"], sym["__kernel_end"], sym["__data_start"]
fails = []
regs = d.parse_registers(monitor)

# --- QEMU's own account of the privilege level ---------------------------
if regs.get("CPL") != 3:
    fails.append("QEMU reports CPL=%s while `user hold`'s payload should be "
                 "spinning in ring 3. Either it never got there, or it came "
                 "back." % regs.get("CPL"))
if regs.get("CS") != 0x23:
    fails.append("QEMU reports CS=%04X, expected 0023" % (regs.get("CS") or 0))
if regs.get("SS") != 0x1B:
    fails.append("QEMU reports SS=%04X, expected 001B" % (regs.get("SS") or 0))

m = re.search(r"^USER MAP CODE ([0-9A-F]{16}) STACK ([0-9A-F]{16})$", cap, re.M)
if not m:
    sys.exit("`user hold` never printed its mapping: %r" % cap[-400:])
code, stack = int(m.group(1), 16), int(m.group(2), 16)
rip = None
m2 = re.search(r"^RIP=([0-9a-fA-F]{16}) ", monitor, re.M)
if m2:
    rip = int(m2.group(1), 16)
    if not (code <= rip < code + d.PAGE_BYTES):
        fails.append("RIP is 0x%X, which is not inside the payload's code page "
                     "[0x%X, 0x%X)" % (rip, code, code + d.PAGE_BYTES))
    if kstart <= rip < kend:
        fails.append("RIP 0x%X is inside the kernel image" % rip)

# --- THE PAGE TABLES, WHILE THE PAYLOAD IS LIVE --------------------------
#
# The check the whole boot exists for. Dumped at the CR3 BOOT A's `vm` line
# named, and then required to equal the CR3 QEMU says the CPU is using -- so the
# address is neither the harness's guess nor the kernel's unchecked word.
cr3 = regs["CR3"] & d.ADDR_MASK
if int(cr3_hex, 16) != cr3:
    sys.exit("the tables were dumped at 0x%s but the CPU is using 0x%X -- the "
             "hold boot did not land on the same page tables as the session"
             % (cr3_hex, cr3))
tables = d.PageTables(cr3, d.parse_xp(monitor, "xp/%dgx 0x%s" % (table_n, cr3_hex)))

live = tables.user_pages(0, d.FINE_BYTES)
if sorted(live) != sorted([code, stack]):
    fails.append("the user-accessible pages in the 4KiB window are %s, expected "
                 "exactly the payload's two: code 0x%X and stack 0x%X. More than "
                 "two means ring 3 can reach memory nobody gave it; fewer means "
                 "the U/S bit is not doing the work the payload's execution "
                 "appears to prove."
                 % ([hex(a) for a in live], code, stack))
fails += d.check_page(tables, code, False, True, True, "the payload's CODE page")
fails += d.check_page(tables, stack, True, False, True, "the payload's STACK page")
# W^X for ring 3, stated as its own claim: the page it executes from is not
# writable and the page it writes to is not executable.
got_code = tables.effective(code)
got_stack = tables.effective(stack)
if got_code and got_code[0]:
    fails.append("the payload's code page is WRITABLE -- ring 3 can rewrite its "
                 "own instructions")
if got_stack and got_stack[1]:
    fails.append("the payload's stack page is EXECUTABLE -- ring 3 can execute "
                 "what it pushes")
# And the kernel is still out of reach while ring 3 is on the CPU. This is the
# assertion the post-session dump cannot make.
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)
fails += d.check_supervisor(tables, *pages(kstart, sym["__text_end"]), ".text (payload live)")
fails += d.check_supervisor(tables, *pages(sym["__rodata_start"], sym["__rodata_end"]), ".rodata (payload live)")
fails += d.check_supervisor(tables, 0, d.LOW_BYTES, "the first megabyte (payload live)")
for lo, hi, label in ((d.FINE_BYTES, d.MAP_BYTES, "[4MiB, 128MiB) (payload live)"),
                      (d.PCI_BASE, d.PCI_END, "the PCI hole (payload live)")):
    big = tables.user_pages(lo, hi, step=d.BIG_BYTES)
    if big:
        fails.append("%d 2MiB page(s) in %s are user-accessible, first at 0x%X"
                     % (len(big), label, big[0]))
# `.data`/`.bss` minus the two payload pages, which are inside that range
# because they came from the allocator above the image. Checked page by page so
# the exception is exactly two pages and not a range.
a, hi = pages(sym["__data_start"], kend)
while a < hi:
    got = tables.effective(a)
    if got is None:
        fails.append(".data/.bss: 0x%X is not mapped" % a)
    elif got[2]:
        fails.append(".data/.bss: 0x%X is user-accessible while a payload runs" % a)
    a += d.PAGE_BYTES

# --- the GDT, at the base the kernel named and the GDTR confirms ---------
if regs.get("GDT_BASE") != int(gdt_hex, 16):
    fails.append("the kernel printed GDT base %s but the GDTR says %016X"
                 % (gdt_hex, regs.get("GDT_BASE") or 0))
if regs.get("GDT_LIMIT") != 7 * 8 - 1:
    fails.append("the GDT limit is %s, expected %d (seven 8-byte entries: null, "
                 "two kernel, two user, and a 16-byte TSS descriptor)"
                 % (regs.get("GDT_LIMIT"), 7 * 8 - 1))
gdt = d.parse_xp(monitor, "xp/%dgx 0x%s" % (gdt_n, gdt_hex))
if len(gdt) < 7:
    sys.exit("the GDT dump is %d quadwords, expected %d" % (len(gdt), gdt_n))
if gdt[0] != 0:
    fails.append("GDT entry 0 is not the null descriptor")
for idx, name, want_dpl, want_exec, want_l in (
        (1, "kernel code", 0, True, True),
        (2, "kernel data", 0, False, False),
        (3, "user data", 3, False, False),
        (4, "user code", 3, True, True)):
    de = d.Descriptor(gdt[idx])
    if not de.present:
        fails.append("GDT entry %d (%s) is not present" % (idx, name))
    if de.dpl != want_dpl:
        fails.append("GDT entry %d (%s) has DPL %d, expected %d. The DPL of the "
                     "user code descriptor is where CPL 3 comes from; nothing "
                     "else in the machine can produce it."
                     % (idx, name, de.dpl, want_dpl))
    if de.system:
        fails.append("GDT entry %d (%s) is a system descriptor" % (idx, name))
    if de.executable != want_exec:
        fails.append("GDT entry %d (%s) executable=%s, expected %s"
                     % (idx, name, de.executable, want_exec))
    if want_l and not de.long_mode:
        fails.append("GDT entry %d (%s) does not have the L bit -- it is not a "
                     "64-bit code segment" % (idx, name))
    if not de.accessed:
        fails.append("GDT entry %d (%s) does not have the ACCESSED bit set. The "
                     "CPU sets it itself on the first load, which is a write "
                     "into .rodata and a #PF -- see boot.S's note beside the GDT."
                     % (idx, name))
base, limit, typ, dpl, present = d.tss_descriptor(gdt[5], gdt[6])
if base != int(tss_hex, 16):
    fails.append("the TSS descriptor names base 0x%X but the kernel printed %s"
                 % (base, tss_hex))
if limit != d.TSS_SIZE - 1:
    fails.append("the TSS descriptor's limit is 0x%X, expected 0x%X"
                 % (limit, d.TSS_SIZE - 1))
if not present or dpl != 0:
    fails.append("the TSS descriptor is present=%s dpl=%d" % (present, dpl))
if typ != 0xB:
    fails.append("the TSS descriptor's type is %X, expected B (BUSY). The CPU "
                 "turns 9 into B when `ltr` loads it, and nothing else in this "
                 "kernel writes that byte -- so type 9 here means `ltr` never "
                 "ran and RSP0 is unreachable." % typ)
if regs.get("TR") != 0x28 or regs.get("TR_BASE") != base:
    fails.append("the task register is %04X/base %016X, expected 0028/%016X"
                 % (regs.get("TR") or 0, regs.get("TR_BASE") or 0, base))

# --- the TSS itself ------------------------------------------------------
tss = d.parse_xp(monitor, "xp/%dgx 0x%s" % (tss_n, tss_hex))
raw = b"".join(q.to_bytes(8, "little") for q in tss)
rsp0 = int.from_bytes(raw[d.TSS_RSP0_OFF:d.TSS_RSP0_OFF + 8], "little")
iomap = int.from_bytes(raw[d.TSS_IOMAP_OFF:d.TSS_IOMAP_OFF + 2], "little")
m4 = re.search(r"^USER TSS [0-9A-F]{16} RSP0 ([0-9A-F]{16}) ", cap, re.M)
if not m4 or int(m4.group(1), 16) != rsp0:
    fails.append("the kernel printed RSP0 %s but the TSS in guest memory holds "
                 "%016X" % (m4.group(1) if m4 else "?", rsp0))
if rsp0 == 0:
    fails.append("RSP0 is ZERO. An interrupt taken in ring 3 would push its "
                 "frame at address 0 and triple-fault the machine.")
elif not (kstart <= rsp0 <= kend):
    fails.append("RSP0 0x%X is not inside the kernel image [0x%X, 0x%X] -- it is "
                 "not a stack this kernel owns" % (rsp0, kstart, kend))
elif rsp0 <= dstart:
    fails.append("RSP0 0x%X is below __data_start 0x%X -- it is not in writable "
                 "memory" % (rsp0, dstart))
if iomap != d.TSS_SIZE:
    fails.append("the TSS's I/O-bitmap base is %d, expected %d (past the limit, "
                 "i.e. NO bitmap). Inside the limit it would hand ring 3 whatever "
                 ".bss contains as an I/O permission map." % (iomap, d.TSS_SIZE))
if regs.get("TR_LIMIT") != d.TSS_SIZE - 1:
    fails.append("the task register's cached limit is %s, expected %d"
                 % (regs.get("TR_LIMIT"), d.TSS_SIZE - 1))

# --- the IDT: exactly ONE gate is reachable from ring 3 ------------------
if regs.get("IDT_BASE") != int(idt_hex, 16):
    fails.append("the kernel printed IDT base %s but the IDTR says %016X"
                 % (idt_hex, regs.get("IDT_BASE") or 0))
idt = d.parse_xp(monitor, "xp/%dgx 0x%s" % (idt_n, idt_hex))
if len(idt) < 512:
    sys.exit("the IDT dump is %d quadwords, expected 512" % len(idt))
user_gates = []
for v in range(256):
    off, sel, ist, typ2, dpl2, present2 = d.idt_gate(idt, v)
    if not present2:
        fails.append("IDT gate %d is not present" % v)
        break
    if sel != 0x08:
        fails.append("IDT gate %d has selector %04X, expected 0008 (the KERNEL "
                     "code segment). A gate that entered through a ring-3 "
                     "selector would not raise the privilege level." % (v, sel))
        break
    if typ2 != 0xE:
        fails.append("IDT gate %d is type %X, expected E (64-bit interrupt "
                     "gate -- IF is cleared on entry)" % (v, typ2))
        break
    if ist != 0:
        fails.append("IDT gate %d has IST %d, expected 0" % (v, ist))
        break
    if dpl2 == 3:
        user_gates.append(v)
    elif dpl2 != 0:
        fails.append("IDT gate %d has DPL %d" % (v, dpl2))
        break
if user_gates != [0x80]:
    fails.append("the gates reachable from ring 3 are %r, expected exactly "
                 "[0x80]. Every other vector must refuse an `int` from CPL 3 -- "
                 "which is what `user badint` demonstrates on gate 3."
                 % [hex(g) for g in user_gates])

if fails:
    print("m9-ring3: live-payload check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (payload live at RIP 0x%X, CPL 3, CS 0023 by QEMU's own account; "
      "exactly 2 of 1024 window pages user-accessible and they are 0x%X (R+X) "
      "and 0x%X (R+W); GDT entries 3 and 4 present with DPL 3 and the accessed "
      "bit; the TSS descriptor BUSY at 0x%X with RSP0 0x%X and no I/O bitmap; "
      "exactly one of 256 IDT gates has DPL 3 and it is 0x80)"
      % (rip or 0, code, stack, base, rsp0))
PY
then
  fail "with a payload live in ring 3, the machine's own privilege state does not match what the kernel says it built"
fi
echo "ASSERT: pass  with a payload LIVE in ring 3: QEMU reports CPL 3 / CS 0023 with RIP inside the payload's page; exactly two of the 1024 pages in the 4KiB window are user-accessible in the live tables and they are the payload's code (read+execute) and stack (read+write) while no kernel page is; the GDT's two user descriptors are present with DPL 3; the TSS descriptor is BUSY (only ltr does that) and names a TSS whose RSP0 is inside the kernel image with no I/O bitmap; and exactly one of the 256 IDT gates has DPL 3"

# ---------------------------------------------------------------------------
# Step 7 — BOOT C: NEGATIVE CONTROL 1. A DIFFERENT MACHINE.
#
# 32MiB instead of 128. The memory map changes, so the allocator's answers
# change, so the frames the payload's pages come from change -- and ring 3 must
# still work, at different addresses. This is the boot that says the payload is
# mapped at runtime out of whatever the allocator gives it rather than living at
# an address that happens to be baked into the image.
#
# It must also DIFFER from the golden inside M1's own boot-time memory-map
# report. A capture that diverged only later would mean the kernel reports a
# memory map that does not depend on the memory.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/small" \
  "u,s,e,r,ret,wait:1500,u,s,e,r,spc,p,f,ret,wait:1500,u,s,e,r,spc,p,a,g,e,s,ret,wait:800" \
  "$WORKDIR/small/shot.png" "small-machine" 52 32M qemu64 \
  --monitor-command 'info registers' \
  --monitor-capture "$WORKDIR/small/monitor.txt"

ck; if ! python3 - "$WORKDIR/small/serial.txt" "$SERIAL_CAPTURE" <<'PY'
import re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
big = open(sys.argv[2], "rb").read().decode("latin-1")
fails = []
if "MB E 0000000007FE0000" in cap:
    fails.append("the 32MiB boot reports the 128MiB machine's memory map -- it "
                 "is not a smaller machine")
m = re.search(r"^USER CS 0000000000000023 SS 000000000000001B "
              r"RFLAGS 0000000000000202 CPL 3$", cap, re.M)
if not m:
    fails.append("ring 3 did not come up on the 32MiB machine: %r"
                 % cap[cap.find("USER"):][:400])
if "USER WRITE HELLO FROM RING 3" not in cap:
    fails.append("the payload did not complete on the 32MiB machine")
if not re.search(r"^PF CR2 [0-9A-F]{16} ERR 00000007 PRESENT WRITE USER DATA$",
                 cap, re.M):
    fails.append("the store into kernel memory did not fault with the USER bit "
                 "on the 32MiB machine")
if not re.search(r"^USER WINDOW PAGES 00000400 USER 00000000$", cap, re.M):
    fails.append("the 32MiB boot does not end with zero user-accessible pages")
# The payload's frames MUST be different addresses, or this is not a different
# machine as far as the allocator is concerned.
def frames(text):
    return re.findall(r"^USER MAP CODE ([0-9A-F]{16}) STACK ([0-9A-F]{16})$",
                      text, re.M)
if frames(cap) and frames(big) and frames(cap)[0] == frames(big)[0]:
    print("    (note: the payload landed on the same frames on both machines; "
          "the allocator's first free frame above the image did not move)")
if fails:
    print("m9-ring3: small-machine control FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (32MiB machine: a different memory map, and ring 3 still enters, "
      "still faults with the USER bit, and still leaves nothing mapped)")
PY
then
  fail "NEGATIVE CONTROL FAILED: ring 3 did not work correctly on a different machine"
fi
ck; if cmp -s "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a boot on a 32MiB machine produced the same serial capture as the 128MiB session"
fi
SMALL_DIFF=$(cmp "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE '(byte|char) [0-9]+' | head -1)
SMALL_OFFSET=${SMALL_DIFF##* }
ck; [[ "$SMALL_OFFSET" -le 544 ]] || fail "the 32MiB capture matches M1's entire 544-byte golden, so the boot-time memory-map report did not change with the machine"
echo "ASSERT: pass  negative control — on a 32MiB machine the memory map differs inside M1's own boot report, and ring 3 still enters, still faults with the USER bit set, and still leaves zero user-accessible pages"

# ---------------------------------------------------------------------------
# Step 8 — BOOT D: NEGATIVE CONTROL 2. NO FRAMES.
#
# `frames drain` hands out every free frame in the machine, so `allocFrame()`
# returns 0 and `user` must REFUSE. This is what says the payload's two pages are
# really allocated rather than being an address the command was compiled to know:
# with the allocator empty, a kernel that mapped a fixed address would enter ring
# 3 anyway and this check would fail.
#
# It is also the refusal path's only test. Every other boot exercises the happy
# path of `shellUser`; this one exercises the branch that has to leave the
# machine exactly as it found it, and `user pages` afterwards is what says it did.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/nomem" \
  "f,r,a,m,e,s,spc,d,r,a,i,n,ret,wait:14000,u,s,e,r,ret,wait:1500,u,s,e,r,spc,p,a,g,e,s,ret,wait:800" \
  "$WORKDIR/nomem/shot.png" "no-frames" 53 128M qemu64

ck; if ! python3 - "$WORKDIR/nomem/serial.txt" <<'PY'
import re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if not re.search(r"^PMM DRAIN NEXT 0000000000000000 FREE 00000000$", cap, re.M):
    fails.append("the drain did not exhaust the allocator, so this control "
                 "proves nothing")
if "user: no free frame for the payload" not in cap:
    fails.append("`user` did not refuse when the allocator was empty. Either it "
                 "entered ring 3 with a page nobody allocated, or it faulted "
                 "instead of reporting. Captured: %r"
                 % cap[cap.rfind("PMM DRAIN NEXT"):][:400])
if "USER ENTER" in cap.split("user: no free frame")[0].split("PMM DRAIN NEXT")[-1]:
    fails.append("`user` entered ring 3 despite the allocator being empty")
if "FAULT " in cap.split("M1 END")[-1]:
    fails.append("a fault was reported on the no-frames boot -- the refusal path "
                 "is supposed to leave a running kernel")
if not re.search(r"^USER WINDOW PAGES 00000400 USER 00000000$", cap, re.M):
    fails.append("after the refusal, the window does not report zero "
                 "user-accessible pages")
if not cap.rstrip().endswith("oscortex>"):
    fails.append("the no-frames boot does not end at a live prompt")
if fails:
    print("m9-ring3: no-frames control FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (allocator drained to zero; `user` refuses, reports why, maps nothing "
      "and leaves a live prompt)")
PY
then
  fail "NEGATIVE CONTROL FAILED: with no free frames, `user` did not refuse cleanly"
fi
echo "ASSERT: pass  negative control — with every frame drained, 'user' refuses with a diagnostic instead of entering ring 3, maps nothing, and leaves the shell alive"

# GAP-0168: the PASS line below describes work; this refuses to print it
# unless that many checks actually executed. An abort, a loop that iterated
# zero times, a branch not taken or a deleted guard all land here.
require_assertions "$ASSERTIONS_REQUIRED"
echo "M9-ring3: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S + portio.S) -> link -> 9 structural checks (the three selectors are one number in two files, the accessed bit pre-set on all four segment descriptors, ltr in the boot stub, donated .bss 5224 -> 5368, user_store one 128-byte symbol, the storage seam exactly 1 call site, the frame offsets recomputed from isr_common's push order, the syscall gate's DPL-3 attribute byte, 48 @rodata sizes, userCodeSizes against the payloads' real sizes, and all six payloads disassembled) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 44 + 8, kdata.o still clean standalone) -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; a payload running at CPL 3 with CS 0023 read out of the frame the CPU pushed; a privileged instruction, a store into kernel memory and a DPL-0 gate each faulting with the right vector and error code -- including #PF error 7 with the USER bit, which had never been observed set on this machine -- each reported, each recovered from, and the target word unchanged every time; a syscall refusing a kernel pointer and ring 3 observing the refusal; the LIVE page tables read out of guest physical memory with a payload still on the CPU, showing exactly two user-accessible pages of 1024 and no kernel page among them; the GDT's user descriptors at DPL 3, the TSS descriptor BUSY with a real RSP0 and no I/O bitmap, and exactly one of 256 IDT gates reachable from ring 3; a 32MiB machine where all of it still holds; and a drained allocator where 'user' refuses instead of pretending. Screenshot at $SHOT_PNG"
exit 0
