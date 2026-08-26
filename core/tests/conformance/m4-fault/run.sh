#!/usr/bin/env bash
# core/tests/conformance/m4-fault/run.sh
#
# Mechanical check of ROADMAP.md's M4 exit criterion: the kernel takes a real
# fault ON PURPOSE, twice, on two different vectors, and comes back to a
# working prompt each time — and it can say what CPU it is running on.
#
# WHAT THIS ASSERTS THAT M1 COULD NOT
# ---------------------------------------------------------------------------
# M1 proved a fault can be CAUGHT: a deliberate #UD produced `M1 FAULT 06 ...`
# instead of a triple-fault. What it did next was change phase — the handler
# walked forward into the console and never came back, because a fault handler
# cannot `iretq` to the instruction that faulted. Nothing was ever RESUMED.
#
# Everything below depends on resumption, and specifically on resumption of a
# context that is NOT the one that faulted:
#
#   * two faults on two DIFFERENT vectors — 0x06 (#UD, DCDart's own overflow
#     trap) and 0x00 (#DE, a real hardware divide error) — each followed by a
#     command that produces output. The proof is not the diagnostic; it is the
#     `commands:` listing printed AFTER the diagnostic;
#   * a fault COUNTER that reaches 0003, so `FAULT RECOVERED` is a number the
#     kernel kept and not a constant it prints;
#   * `ticks` AFTER two faults, which only works if IF, the IDT, the PIC and
#     the 8259 mask state all survived the stack being thrown away;
#   * `mem` after two faults re-walking the Multiboot map to the same bytes the
#     boot-time dump produced — the kernel compared against itself, across two
#     abandoned stacks;
#   * the OP field, which is the first two bytes of the faulting instruction
#     read through the RIP the CPU pushed. `0F0B` is a `ud2` and `48F7` is a
#     64-bit `div`. Those bytes cannot appear unless the handler really has the
#     faulting address and really dereferenced it.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ---------------------------------------------------------------------------
# The absolute faulting RIP, which is reachable and is deliberately not printed
# (docs/known-gaps.md GAP-0064): an absolute code address in a byte-exact
# golden would force this golden to be regenerated on every future kernel edit,
# for a reason that says nothing about whether recovery works.
#
# `-cpu qemu64` is PINNED, for the same class of reason `-m 128M` is: the `CPU
# ...` lines report what the hardware says, so the hardware has to be fixed or
# the golden is a property of whoever ran it.
#
# SEVEN INDEPENDENT ASSERTIONS
# ---------------------------------------------------------------------------
# NOTE (M5): the exact donated-`.bss` total moved to m5-pci/run.sh, which is
# the harness for the milestone that grew it (392 -> 424). See check 2a.
#
#   1. SERIAL, byte-for-byte (`expected.txt`), with m1-interrupts' 544-byte
#      golden checked MECHANICALLY as a prefix against M1's own file.
#   2. BOTH FAULT VECTORS, as exact byte sequences: 06/0F0B and 00/48F7.
#   3. RECOVERY IS FOLLOWED BY WORK: the exact bytes `RECOVERED 0001 ...` then
#      a prompt then `help` then `commands:` — a command that ran after a fault.
#   4. THE `mem` RE-WALK equals the boot-time dump, both from this capture.
#   5. THE FRAMEBUFFER, byte-for-byte, read out of GUEST PHYSICAL MEMORY.
#   6. A PNG at core/build/screenshot-fault.png.
#   7. A NEGATIVE CONTROL: a different key sequence must fail both goldens,
#      diverging past M1's 544th byte.
#
# `qmp-drive.py` is REUSED from m2-console — one driver, three harnesses.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m4-fault/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M4-fault: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M4-fault: FAIL — $1" >&2
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
ASSERTIONS_REQUIRED=86


for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
ck; [[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL"
ck; [[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"
ck; [[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m4-fault reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
ck; [[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m4.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

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

# Mnemonic sequence of a disassembled routine, in order.
#
# objdump's columns are tab-separated: address, raw bytes, then the
# instruction. A long instruction's raw bytes wrap onto a continuation line
# with NO third column, and those lines are skipped -- taking the last
# whitespace-delimited field instead would yield operands for anything that has
# them, which is why this is a function rather than a one-liner repeated twice.
mnemonics() {
  awk -F'\t' '/^ +[0-9a-f]+:/ && $3 != "" { split($3, a, " "); printf "%s ", a[1] }'
}

# 2a. THE DONATED STORAGE M4 ITSELF ADDED.
#
# **The exact TOTAL moved to m5-pci/run.sh at M5**, by the same rule that moved
# it from m2-console to m3-shell at M3 and from m3-shell to here at M4: one
# harness owns the number, and it is the harness for the milestone that grew it.
# M5's framebuffer console added 32 bytes (base, pitch, cursor column, cursor
# row), taking 392 to 424 — see docs/known-gaps.md GAP-0053 and GAP-0072.
# Asserting a total in two places would guarantee they drift.
#
# What stays here is what is genuinely M4's: the three words fault recovery and
# the fault counter need, at 8 bytes each, and the CPUID block below. Those are
# this milestone's own contribution to GAP-0053 and they are checked by symbol
# size rather than by a section total, so they do not move when a later
# milestone donates something of its own.
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
KDATA_BSS=$(( DART_BSS + ASM_BSS ))
ck; [[ "$KDATA_BSS" -ge 392 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes, which is less than the 392 M4 itself needs — something M4 owned has been deleted"
# M17 SPLIT M4's THREE WORDS, and the split is the point. `faultCountWord` is
# ordinary kernel state and became a DCDart `@bss`; `shell_resume_rsp` and
# `shell_resume_ok` are written by `shell_run_forever` and read by
# `fault_resume`, both in core/boot/isr.S, and a `@bss` symbol is LOCAL to
# kmain.o, so assembly cannot name one. They stay donated, deliberately, and
# `bsssize` finds each in whichever object now defines it.
for sym in faultCountWord shell_resume_rsp shell_resume_ok; do
  SZ=$(bsssize "$sym")
  ck; [[ "$SZ" == "8" ]] || fail "$sym is ${SZ:-missing} bytes, expected 8 — a word M4's fault recovery depends on"
done
ck; x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$4=="OBJECT" && $8=="shell_resume_rsp"' | grep -q . \
  || fail "shell_resume_rsp is no longer defined in kdata.o — isr.S writes it by name and a DCDart @bss symbol is local, so it cannot live in kmain.o"
echo "STRUCTURAL: pass  M4's own three words are 8 bytes each (faultCountWord a DCDart @bss, the two resume words still assembly-owned) and the kernel's mutable static storage is $KDATA_BSS ($DART_BSS + $ASM_BSS; the exact total is owned by m5-pci/run.sh as of M5)"

# 2b. THE CPUID RESULT BLOCK IS THE SIZE CPUID ACTUALLY RETURNS.
#
# Vendor is 12 bytes at +0, brand is 48 bytes at +16. `cpu_probe` writes them
# by fixed offset, so a block shorter than 64 would have `cpu_probe` writing
# past the end of its own object and over whatever kdata.S put next.
CPU_INFO_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="cpu_info" {print $3; exit}')  # still kdata.o: isr.S's cpu_probe writes it by name
ck; [[ "$CPU_INFO_SIZE" == "64" ]] || fail "kdata.o's cpu_info is ${CPU_INFO_SIZE:-missing} bytes, expected 64 (12-byte vendor at +0, 48-byte brand at +16)"
echo "STRUCTURAL: pass  cpu_info is exactly 64 bytes, the size CPUID's two strings need"

# 2c. `divide_by_zero` MUST REALLY DIVIDE BY ZERO.
#
# `crash div` claims a hardware divide error. If this routine ever stopped
# being a `div` with a zero divisor — or if a non-zero divisor crept in — the
# command would silently return instead of faulting, and the harness would see
# a missing diagnostic rather than a wrong one. The exact encoding is asserted
# too (`48 f7 f1` = 64-bit `div %rcx`), because that is what makes the fault
# diagnostic's ` OP 48F7` a stable golden value instead of a hostage to
# whichever register an assembler picked.
DIV_DIS=$(x86_64-elf-objdump -d --disassemble=divide_by_zero "$CORE_DIR/build/isr.o")
ck; if ! grep -qE '48 f7 f1' <<<"$DIV_DIS"; then
  echo "$DIV_DIS" >&2
  fail "divide_by_zero does not contain the exact encoding 48 f7 f1 (div %rcx) -- 'crash div' would not raise a #DE, or the OP field's golden value would move"
fi
DIV_OPS=$(mnemonics <<<"$DIV_DIS")
ck; case "$DIV_OPS" in
  "xor xor mov div ret"*) ;;
  *)
    echo "$DIV_DIS" >&2
    fail "divide_by_zero is not 'xor; xor; mov; div; ret' (got: $DIV_OPS) — the zero divisor must be set immediately before the div, with nothing in between that could change it"
    ;;
esac
echo "STRUCTURAL: pass  divide_by_zero is exactly 'xor; xor; mov \$1; div %rcx (48 f7 f1); ret'"

# 2d. `fault_resume` MUST ACTUALLY SWITCH STACKS, AND CHECK BEFORE IT DOES.
#
# This is the whole recovery mechanism in five instructions, and every one of
# them is load-bearing:
#
#   cli        RSP is about to stop describing the current frame's stack
#   cmpq $1    the guard. .bss is not zeroed, so an unset resume point is
#              garbage, and using it would triple-fault the machine WHILE
#              REPORTING A FAULT
#   mov x6     M9. The kernel's own segment selectors, put back before the stack
#              switch. A fault taken in RING 3 arrives with DS/ES/FS/GS holding
#              the ring-3 data selector and with SS NULL (the CPU nulls it on a
#              privilege-changing interrupt in long mode). Harmless in long mode,
#              and a no-op on a ring-0 fault, but the shell would otherwise run
#              on inherited ring-3 selectors for the rest of the boot.
#   mov -> rsp the abandonment: every frame between the shell loop and the
#              fault disappears in this one store
#   and $-16   System V AMD64 stack alignment for the calls that follow
#
# Asserted as an ordered opcode sequence rather than by grepping for `rsp`,
# because "it contains a mov to rsp somewhere" would pass with the guard
# deleted. The seven `mov`s are counted exactly: six segment loads and the stack
# switch, in that order, so neither the guard nor the switch can move.
FR_DIS=$(x86_64-elf-objdump -d --disassemble=fault_resume "$CORE_DIR/build/isr.o")
FR_OPS=$(mnemonics <<<"$FR_DIS")
ck; case "$FR_OPS" in
  "cli cmpq jne mov mov mov mov mov mov mov and call call jmp"*) ;;
  *)
    echo "$FR_DIS" >&2
    fail "fault_resume is not 'cli; cmpq; jne; 6x mov->segment; mov->rsp; and; call; call; jmp' (got: $FR_OPS) — the stack switch, its guard, or the interrupt disable around it has moved"
    ;;
esac
ck; if ! grep -qE 'mov +0x[0-9a-f]*\(%rip\),%rsp' <<<"$FR_DIS"; then
  echo "$FR_DIS" >&2
  fail "fault_resume's mov does not load %rsp from memory — it is not restoring the recorded resume point"
fi
echo "STRUCTURAL: pass  fault_resume is 'cli; guard; restore the kernel's six segment selectors; load %rsp from the recorded mark; align; call' in that order"

# 2e. `shell_run_forever` MUST RECORD THE MARK IT WILL LATER BE RESTORED TO.
#
# Without the store there is no resume point, and the guard word would never be
# set, so every fault would fall through fault_resume's `jne halt_forever` and
# the kernel would stop instead of recovering — with a passing diagnostic. That
# failure would look almost exactly like success in a serial log.
SRF_DIS=$(x86_64-elf-objdump -d --disassemble=shell_run_forever "$CORE_DIR/build/isr.o")
ck; grep -qE 'mov +%rsp,0x[0-9a-f]*\(%rip\)' <<<"$SRF_DIS" || {
  echo "$SRF_DIS" >&2
  fail "shell_run_forever does not store %rsp — there would be no resume point for fault_resume to restore"
}
ck; grep -qE 'movq +\$0x1,' <<<"$SRF_DIS" || {
  echo "$SRF_DIS" >&2
  fail "shell_run_forever does not set the resume-point guard to 1 — fault_resume would refuse to recover and halt instead"
}
echo "STRUCTURAL: pass  shell_run_forever records %rsp and arms the resume-point guard"

# 2f. `cpu_probe` MUST EXECUTE REAL CPUIDs.
#
# Five of them: leaf 0 (vendor + standard limit), leaf 0x80000000 (extended
# limit), and 0x80000002..4 (brand). Fewer means a leaf is being assumed rather
# than asked for, and the brand check is the one that matters — a CPU without
# the extended leaves would otherwise have 48 bytes of uninitialised .bss
# printed to a screen as its name.
CPUID_COUNT=$(x86_64-elf-objdump -d --disassemble=cpu_probe "$CORE_DIR/build/isr.o" | grep -c 'cpuid')
ck; if [[ "$CPUID_COUNT" -ne 5 ]]; then
  fail "cpu_probe contains $CPUID_COUNT cpuid instruction(s), expected 5 (leaf 0, leaf 0x80000000, and the three brand leaves)"
fi
echo "STRUCTURAL: pass  cpu_probe issues exactly 5 real cpuid instructions"

# 2g. `crash ud`'s TRAP MUST SURVIVE CODEGEN, AND MUST STAY CONDITIONAL.
#
# The fault is DCDart's own overflow trap, not a hand-written ud2. If LLVM ever
# folded the overflow at compile time the `ud2` would become unconditional (or
# the code would become `unreachable` and be deleted), and `crash ud` would
# stop being evidence that DCDart's arithmetic really traps. A `ud2` reached
# only through a conditional branch is what makes it real — the same property
# m1-interrupts asserts about kmain's own deliberate overflow.
UD_DIS=$(x86_64-elf-objdump -d --disassemble=shellCrashUd "$CORE_DIR/build/kmain.o")
ck; grep -q 'ud2' <<<"$UD_DIS" || {
  echo "$UD_DIS" >&2
  fail "shellCrashUd contains no ud2 -- DCDart's overflow trap was optimized away and 'crash ud' would not fault"
}
ck; grep -qE '\bj(ne|e|a|b|ae|be)\b' <<<"$UD_DIS" || {
  echo "$UD_DIS" >&2
  fail "shellCrashUd's ud2 is not reached through a conditional branch — the overflow was constant-folded, so the trap proves nothing about runtime arithmetic"
}
echo "STRUCTURAL: pass  shellCrashUd keeps a CONDITIONAL ud2 (DCDart's overflow trap survives -O2)"

# 2h. THE @rodata TABLES M4 ADDED ARE EXACTLY THE SIZES THEIR CALL SITES PASS.
#
# A @rodata table carries no length (DCDart ADR-0040 promises elements only),
# so every byte count is a literal maintained by hand — docs/known-gaps.md
# GAP-0060. This is not theoretical: the first M4 build printed 237 bytes of
# the new 395-byte help table because that one number had not been updated.
# Checking the sizes here catches it before a golden does.
check_table() {
  local sym="$1" want="$2"
  local got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  ck; [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M4 depends on was not emitted"
  ck; [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060: the length is a hand-maintained literal)"
}
check_table shellStrHelp 2224  # M5 added `pci`/`fb`, M6 two `disk` lines, M7 six frame-allocator lines, M8 `vm`/`vmtest`, M9 seven `user` lines, M10 `run <lba>`, M11 three `proc` lines, M14 `run <name>` + `fs`/`ls`/`cat`; GAP-0060
check_table shellCmdCpu 3
check_table shellCmdCrash 5
check_table shellCmdCrashUd 8
check_table shellCmdCrashDiv 9
check_table shellStrCrashUsage 35
check_table shellStrCrashUd 41
check_table shellStrCrashDiv 30
check_table shellStrCpuVendor 11
check_table shellStrCpuBrand 10
check_table shellStrCpuLeaf 9
check_table shellStrCpuExt 5
check_table shellStrRecovered 16
check_table shellStrAbandoned 50
check_table m1StrFaultHead 6
check_table m1StrFaultErr 5
check_table m1StrFaultOp 4
check_table m1StrFaultOpUnmapped 4
echo "STRUCTURAL: pass  all 18 M4 @rodata tables are exactly the sizes their call sites pass"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# boot.o and isr.o are still excluded and still legitimately so: each
# references DCDart symbols only the link resolves, and being assembly they
# have no dcc-written extern manifest (docs/known-gaps.md GAP-0056).
# kernel.elf covers them.
#
# kdata.o is checked EXPLICITLY, because M4 is the first milestone in which it
# EXPORTS symbols (cpu_info, shell_resume_rsp, shell_resume_ok) for isr.S to
# write. Exporting a definition adds no undefined symbol, so kdata.o must still
# pass standalone — GAP-0056 records that pass as a real data point about why
# boot.o and isr.o fail, and this is the check that keeps it true.
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
ck; [[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$KERNEL_ELF"'
echo "$VERIFY_OUT"
ck; if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o, every one named in core/boot/{isr,kdata}.S"

# ---------------------------------------------------------------------------
# Step 4 — boot, drive a real session, capture.
#
# The session, in order. Every element makes a specific claim:
#
#   crash                 a command that exists but needs to be told which
#                         fault to take. Prints usage, does not fault.
#   crash ud              #UD (vector 6) from DCDart's own overflow trap.
#   help                  A COMMAND AFTER A FAULT. This is the milestone.
#   crash div             #DE (vector 0) from a real hardware divide error —
#                         a DIFFERENT vector through the same recovery path.
#   mem                   the Multiboot map, re-walked after two abandoned
#                         stacks, and asserted identical to the boot dump.
#   ticks                 the PIT, observed advancing after two faults. Only
#                         possible if IF, the IDT and the PIC masks all
#                         survived — a wait for a timer interrupt that cannot
#                         be delivered is a hang, not a wrong number.
#   wait:350              ticks takes 160ms and there is no input queue.
#   cpu                   CPUID vendor, brand and leaf limits.
#   clear                 blank screen, so the final screenshot is readable.
#   crash ud              a THIRD fault, counter reaching 0003.
#   cpu                   and the shell is still answering questions.
# ---------------------------------------------------------------------------
SESSION_KEYS="c,r,a,s,h,ret"
SESSION_KEYS="$SESSION_KEYS,c,r,a,s,h,spc,u,d,ret"
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
SESSION_KEYS="$SESSION_KEYS,c,r,a,s,h,spc,d,i,v,ret"
SESSION_KEYS="$SESSION_KEYS,m,e,m,ret"
SESSION_KEYS="$SESSION_KEYS,t,i,c,k,s,ret,wait:350"
SESSION_KEYS="$SESSION_KEYS,c,p,u,ret"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret"
SESSION_KEYS="$SESSION_KEYS,c,r,a,s,h,spc,u,d,ret"
SESSION_KEYS="$SESSION_KEYS,c,p,u,ret"

SHOT_PNG="$CORE_DIR/build/screenshot-fault.png"
rm -f "$SHOT_PNG"

drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4"
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
  # -cpu qemu64 is PINNED: the `CPU VENDOR`/`CPU BRAND`/`CPU LEAF` lines report
  # what CPUID says, so the golden is only meaningful against a fixed CPU
  # model. Same reasoning as -m 128M for the memory map. It is also the TCG
  # default, so this pins today's behaviour rather than changing it.
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" --wait-for 'M1 END\n' --png "$png" --screen-text "$outdir/screen.txt" --keys "$keys"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot. This is a FAILURE, not a skip: if the kernel stopped recovering, it would hang here rather than print wrong bytes."
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
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
#
# M4 changes what happens on the fault path, so this is the check that proves
# it did not change what happens on M1's fault path. The boot-time #UD is still
# reported with the same bytes and still walks into the console.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
ck; if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — fault recovery changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 5b. The whole serial capture.
ck; if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- captured serial ---" >&2
  cat -v "$SERIAL_CAPTURE" >&2
  echo "--- expected ---" >&2
  cat -v "$EXPECTED_SERIAL" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte (boot report + three faults + six commands)"

# 5c. TWO DIFFERENT FAULTS, EACH FOLLOWED BY REAL WORK.
#
# The claims, in one Python block so each failure names itself:
#
#   * a #UD on vector 06 whose faulting instruction really is a `ud2` (0F0B),
#     and a #DE on vector 00 whose faulting instruction really is a 64-bit
#     `div` (48F7). Those opcode bytes were read through the RIP the CPU
#     pushed, so they cannot be right by accident;
#   * the fault counter goes 0001, 0002, 0003 in that order — a count the
#     kernel kept, not a constant;
#   * after the FIRST fault, `help` runs and prints `commands:`. That
#     adjacency, in the byte stream, IS the milestone: a command executing
#     after the stack it would have run on was thrown away;
#   * after the SECOND fault, `ticks` prints ` LIVE`, which is only reachable
#     through a loop that exits when a timer interrupt has been delivered.
ck; if ! python3 - "$SERIAL_CAPTURE" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
fails = []

def need(seq, why):
    if seq not in d:
        fails.append("missing %r\n      (%s)" % (seq, why))

need(b"FAULT 06 ERR 0000000000000000 OP 0F0B\n",
     "#UD on vector 6; OP is the first two bytes at the faulting RIP -- 0F0B is ud2")
need(b"FAULT 00 ERR 0000000000000000 OP 48F7\n",
     "#DE on vector 0; 48F7 is the REX.W prefix and opcode of a 64-bit div")

# The counter, in order.
last = -1
for n in (1, 2, 3):
    tag = b"FAULT RECOVERED %04d -- faulting computation abandoned, shell resumed\n" % n
    i = d.find(tag)
    if i < 0:
        fails.append("missing recovery line %04d" % n)
    elif i < last:
        fails.append("recovery line %04d appears out of order" % n)
    else:
        last = i

# Recovery is immediately followed by a working prompt and a command that runs.
need(b"FAULT RECOVERED 0001 -- faulting computation abandoned, shell resumed\n"
     b"oscortex> help\ncommands:\n",
     "a command must run AFTER the first fault, on a prompt the kernel printed itself")
need(b"FAULT RECOVERED 0002 -- faulting computation abandoned, shell resumed\n"
     b"oscortex> mem\n",
     "the second recovery must be followed by the mem command")
need(b" LIVE\n", "the PIT must still deliver interrupts after two faults")

# Vector 6 and vector 0 must BOTH appear, i.e. two genuinely different faults.
if d.count(b"FAULT 06 ERR") != 2:
    fails.append("expected exactly two vector-06 faults (crash ud, twice), found %d"
                 % d.count(b"FAULT 06 ERR"))
if d.count(b"FAULT 00 ERR") != 1:
    fails.append("expected exactly one vector-00 fault (crash div), found %d"
                 % d.count(b"FAULT 00 ERR"))

if fails:
    print("m4-fault: fault-recovery check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
then
  fail "the two deliberate faults were not both caught, diagnosed from the real faulting address, counted, and followed by working commands"
fi
echo "ASSERT: pass  #UD (06/0F0B) and #DE (00/48F7) both diagnosed from the pushed RIP, counted 0001..0003, each followed by a command that produced output"

# 5d. THE `mem` RE-WALK EQUALS THE BOOT-TIME DUMP.
#
# Both come out of the SAME capture, so this compares the kernel against
# itself — and at M4 it does so across two abandoned stacks. The Multiboot
# structure is still there and still says exactly the same thing after two
# deliberate faults have thrown away everything that was running.
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
ck; [[ "$DUMP_COUNT" == "2" ]] || fail "expected exactly 2 'MB FLAGS ... MB END' blocks in the capture (one at boot, one from the mem command), found $DUMP_COUNT"
awk '/^----$/{n++; next} n==1' "$WORKDIR/dumps.txt" >"$WORKDIR/dump-boot.txt"
awk '/^----$/{n++; next} n==2' "$WORKDIR/dumps.txt" >"$WORKDIR/dump-shell.txt"
if ! cmp -s "$WORKDIR/dump-boot.txt" "$WORKDIR/dump-shell.txt"; then
  diff -u "$WORKDIR/dump-boot.txt" "$WORKDIR/dump-shell.txt" >&2
  fail 'the memory map printed by the mem command differs from the one printed at boot -- the same walk over the same structure gave two different answers, after two faults'
fi
echo 'ASSERT: pass  the mem re-walk after two faults is line-for-line identical to the boot-time dump'

# 5e. The framebuffer, read from guest physical memory.
ck; if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
  echo "--- expected ---" >&2
  cat -n "$EXPECTED_SCREEN" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"

# 5f. The screenshot.
ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
ck; case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG (QEMU's screendump format argument may be unsupported on this build)" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 6 — THE NEGATIVE CONTROL.
#
# A check that cannot fail is not a check. The same kernel, a DIFFERENT key
# sequence: both goldens must fail, and the serial divergence must start AFTER
# M1's 544 bytes — if it started earlier, the goldens would be failing for a
# reason that has nothing to do with what was typed.
#
# The control sequence deliberately faults too (`crash div` only), so what it
# proves is specifically that the goldens are sensitive to WHICH faults were
# taken and in what order, not merely to whether anything faulted at all.
# ---------------------------------------------------------------------------
NEG_KEYS="c,r,a,s,h,spc,d,i,v,ret,c,p,u,ret"
drive_session "$WORKDIR/negative" "$NEG_KEYS" "$WORKDIR/negative/shot.png" "negative-control" 1

ck; if cmp -s "$WORKDIR/negative/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a different key sequence produced the same serial capture. The serial golden is not actually sensitive to what was typed."
fi
ck; if cmp -s "$WORKDIR/negative/screen.txt" "$EXPECTED_SCREEN"; then
  fail "NEGATIVE CONTROL FAILED: a different key sequence produced the same framebuffer. The screen golden is not actually sensitive to what was typed."
fi
# It must still have recovered — a control that fails by crashing would prove
# nothing about the goldens.
ck; grep -q "FAULT RECOVERED 0001" "$WORKDIR/negative/serial.txt" || \
  fail "NEGATIVE CONTROL FAILED: the control boot did not recover from its own fault, so its divergence says nothing about the goldens"
NEG_DIVERGE=$(cmp "$WORKDIR/negative/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE 'byte [0-9]+' | grep -oE '[0-9]+' | head -1)
[[ -n "$NEG_DIVERGE" ]] || NEG_DIVERGE=$(( M1_BYTES + 1 ))
ck; if [[ "$NEG_DIVERGE" -le "$M1_BYTES" ]]; then
  fail "NEGATIVE CONTROL FAILED: the divergence starts at byte $NEG_DIVERGE, which is inside M1's ${M1_BYTES}-byte golden — the goldens are failing for a reason unrelated to what was typed."
fi
echo "ASSERT: pass  negative control — a different key sequence (which also faults, and also recovers) fails BOTH goldens, serial diverging at byte $NEG_DIVERGE (M1's golden is $M1_BYTES bytes, so the divergence is entirely in the shell session)"

# GAP-0168: the PASS line below describes work; this refuses to print it
# unless that many checks actually executed. An abort, a loop that iterated
# zero times, a branch not taken or a deleted guard all land here.
require_assertions "$ASSERTIONS_REQUIRED"
echo "M4-fault: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S) -> link -> 8 structural checks -> verify-freestanding pass ($EXTERN_COUNT declared externs) -> a real QEMU boot (-m 128M -cpu qemu64) driving a real session over QMP: ${SERIAL_BYTES}-byte serial match with M1's golden intact as a prefix, a #UD and a #DE both diagnosed from the pushed RIP and both recovered from, three recoveries counted, commands running after every one of them, a memory-map re-walk identical to the boot dump, CPUID vendor and brand read out of the hardware, an exact 80x25 framebuffer match read from guest memory, a PNG at $SHOT_PNG, and a negative control that fails both goldens"
exit 0
