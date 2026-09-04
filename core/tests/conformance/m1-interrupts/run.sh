#!/usr/bin/env bash
# core/tests/conformance/m1-interrupts/run.sh
#
# Mechanical check of ROADMAP.md's M1 exit criterion: the kernel takes a real
# interrupt and a real exception, handles both in DCDart, and keeps running.
#
# This harness asserts the ENTIRE captured serial output byte-for-byte, so it
# strictly subsumes both m0-boot (which asserts the first line) and mb-info
# (which asserts through `MB END`). All three must be run: each one owns its
# own milestone's claim and fails with a message about THAT milestone, which
# is what makes a regression legible instead of just "the golden changed."
#
# What each asserted line proves, and why it cannot pass by accident:
#
#   M1 IDT 0100      256 gates written, COUNTED BY THE INSTALL LOOP and
#                    printed — not a hard-coded constant.
#   M1 EXC 03 ...    boot-time `int3` was delivered through the IDT, reached a
#                    DCDart handler over the C ABI, and `iretq` resumed
#                    correctly. If the return were wrong, nothing after this
#                    line would ever be printed.
#   M1 PIC 20        the FIRST timer interrupt reporting the vector it was
#                    actually delivered on. An 8259's ICW2 is write-only, so
#                    printing back the programmed constant would prove
#                    nothing; observing delivery on 0x20 instead of the
#                    power-on default 0x08 is the real evidence the remap took.
#   M1 TICKS ...64   the PIT handler ran exactly 0x64 = 100 times. Proves
#                    end-of-interrupt works: without the EOI the PIC never
#                    re-asserts, exactly one tick ever arrives, and the wait
#                    loop hangs instead of reaching 100. Host-speed
#                    independent — the COUNT is the trigger, not a duration.
#   M1 FAULT 06 ...  a deliberate u64 overflow, which DCDart's own
#                    overflow-trap codegen turns into `ud2` (#UD, vector 6),
#                    was CAUGHT AND DIAGNOSED. At M0 this same fault
#                    triple-faulted the VM and printed nothing at all. This
#                    line is the milestone's actual point.
#   M1 END           terminator, so a report truncated by a hang is a hard
#                    failure rather than a prefix that happens to match.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m1-interrupts/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M1-interrupts: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M1-interrupts: FAIL — $1" >&2
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
ASSERTIONS_REQUIRED=26


ck; if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  setup_error "qemu-system-x86_64 not found on PATH, see docs/known-gaps.md"
fi

EXPECTED="$SCRIPT_DIR/expected.txt"
ck; [[ -f "$EXPECTED" ]] || setup_error "golden file not found at $EXPECTED"

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m1.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build (dcc build + assemble boot.S and isr.S + link)
# Isolated BUILD_DIR so this harness cannot stomp live core/build/kernel*.elf.
# ---------------------------------------------------------------------------
M1_BUILD="$WORKDIR/kbuild"
export BUILD_DIR="$M1_BUILD"
mkdir -p "$M1_BUILD"
if [[ -d "$CORE_DIR/build/skia" && ! -e "$M1_BUILD/skia" ]]; then
  ln -s "$CORE_DIR/build/skia" "$M1_BUILD/skia"
fi
BUILD_LOG="$WORKDIR/build.log"
capture_log "$BUILD_LOG" BUILD_STATUS -- BUILD_DIR="$M1_BUILD" bash "$CORE_DIR/scripts/build-kernel.sh"
cat "$BUILD_LOG"
ck; if [[ $BUILD_STATUS -ne 0 ]]; then
  fail "build-kernel.sh exited $BUILD_STATUS (log above)"
fi

KERNEL_ELF="$M1_BUILD/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — structural checks that need no QEMU (CLAUDE.md's testing rules say
# anything verifiable without booting should be).
# ---------------------------------------------------------------------------
ck; if ! command -v x86_64-elf-objdump >/dev/null 2>&1; then
  setup_error "x86_64-elf-objdump not found on PATH (brew install x86_64-elf-binutils)"
fi

# 2a. The red zone must stay disabled. DCDart ADR-0039 makes -mno-red-zone a
# property of any freestanding target, but this kernel is the thing that
# actually gets corrupted if it ever regresses, and the corruption would be
# silent data damage rather than a crash. Assert it here rather than trusting
# the toolchain to keep its promise.
RED_ZONE_HITS=$(x86_64-elf-objdump -d "$M1_BUILD/kmain.o" | grep -cE '\-0x[0-9a-f]+\(%rsp\)')
ck; if [[ "$RED_ZONE_HITS" -ne 0 ]]; then
  x86_64-elf-objdump -d "$M1_BUILD/kmain.o" | grep -nE '\-0x[0-9a-f]+\(%rsp\)' >&2
  fail "kmain.o contains $RED_ZONE_HITS negative-%rsp access(es) — the red zone is back (DCDart ADR-0039 regressed). An interrupt would corrupt the interrupted function's locals."
fi
echo "STRUCTURAL: pass  no red-zone (negative %rsp) accesses in kmain.o"

# 2b. The deliberate fault must be a RUNTIME conditional trap. If LLVM ever
# constant-folds the overflow, the `ud2` becomes unconditional or the code is
# replaced by `unreachable` and deleted — either way `M1 FAULT 06` would stop
# being evidence of a real trap. A `ud2` reached only by a conditional branch
# is what makes it real.
ck; if ! x86_64-elf-objdump -d --disassemble=kmain "$M1_BUILD/kmain.o" | grep -q 'ud2'; then
  fail "kmain contains no ud2 — the deliberate overflow trap was optimized away, so M1's fault test would prove nothing"
fi
echo "STRUCTURAL: pass  kmain contains a ud2 (deliberate overflow trap survives codegen)"

# 2c. 256 stubs at a 16-byte stride, and the stub table sized to match.
# Size column is hex; converted with bash arithmetic rather than awk's
# strtonum(), which is a gawk extension and absent from macOS's awk.
STUB_TABLE_HEX=$(x86_64-elf-objdump -h "$M1_BUILD/isr.o" | awk '$2 == ".rodata" {print $3; exit}')
ck; [[ -n "$STUB_TABLE_HEX" ]] || fail "isr.o has no .rodata section — the stub-address table is missing"
STUB_TABLE_BYTES=$((16#$STUB_TABLE_HEX))
ck; if [[ "$STUB_TABLE_BYTES" -ne 2048 ]]; then
  fail "isr.o .rodata is $STUB_TABLE_BYTES bytes, expected 2048 (256 stub addresses x 8)"
fi
echo "STRUCTURAL: pass  isr.o stub-address table is 2048 bytes (256 entries)"

# 2d. The @rodata message tables must really be in .rodata, and the kernel
# image must still have no GOT.
#
# This is the first change that could produce either problem, so it is
# asserted rather than assumed. core/link/kernel.ld places .rodata.*, .got and
# .got.plt explicitly; a GOT appearing would mean the toolchain decided this
# freestanding image needed position-independent indirection, which for a
# kernel linked at a fixed 1MiB is both wrong and silent.
ck; if x86_64-elf-objdump -h "$KERNEL_ELF" | grep -qE '\.got(\.plt)?[[:space:]]'; then
  x86_64-elf-objdump -h "$KERNEL_ELF" | grep -E '\.got' >&2
  fail "kernel.elf has a .got/.got.plt section — something started emitting position-independent indirection into a fixed-address kernel image"
fi
echo "STRUCTURAL: pass  kernel.elf has no .got/.got.plt"

# Every OBJECT symbol dcc emits is either a @rodata table or -- since M17
# (ADR-0021) -- a @bss mutable static, and each must land in its own section.
#
# ---------------------------------------------------------------------------
# THIS CHECK CHANGED AT M17 AND IT GOT STRONGER. Until M17 the assertion was
# "every OBJECT symbol is in .rodata", which was true only because DCDart could
# not emit a mutable global at all; the kernel's mutable state was 14048 bytes
# of hand-written `.bss` in core/boot/kdata.S. DCDart ADR-0051 landed `@bss`,
# so "every OBJECT is read-only" would now be FALSE for a correct kernel, and
# relaxing it to "OBJECTs may be anywhere" would have thrown away the property
# it was protecting: that a @rodata table is never writable.
#
# The substitution is: PARTITION the OBJECT symbols into exactly two sets, and
# require BOTH to be complete.
#
#   * every @rodata table is in .rodata  -- unchanged, and still the point
#   * every @bss block is in .bss        -- new, and the reason .bss exists
#   * NOTHING is anywhere else           -- unchanged
#   * the .bss set matches, name for name, the `@bss` declarations in
#     core/kernel/*.dart                 -- new, and the strongest half: a
#     mutable static cannot appear in the image without appearing in the
#     source, and cannot be declared in the source without reaching the image
#     (an unreferenced `@bss` block is dropped by LLVM, silently, which is
#     exactly the failure this catches).
# ---------------------------------------------------------------------------
RODATA_IDX=$(x86_64-elf-readelf -SW "$M1_BUILD/kmain.o" | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\][[:space:]]*\.rodata[[:space:]].*/\1/p')
ck; [[ -n "$RODATA_IDX" ]] || fail "kmain.o has no .rodata section — the @rodata message tables are missing entirely"
BSS_IDX=$(x86_64-elf-readelf -SW "$M1_BUILD/kmain.o" | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\][[:space:]]*\.bss[[:space:]].*/\1/p')
ck; [[ -n "$BSS_IDX" ]] || fail "kmain.o has no .bss section — the @bss mutable statics (ADR-0021) are missing entirely"

TABLE_COUNT=$(x86_64-elf-readelf -sW "$M1_BUILD/kmain.o" | awk -v ix="$RODATA_IDX" '$4=="OBJECT" && $7==ix' | wc -l | tr -d ' ')
STRAY=$(x86_64-elf-readelf -sW "$M1_BUILD/kmain.o" \
  | awk -v r="$RODATA_IDX" -v b="$BSS_IDX" '$4=="OBJECT" && $7!=r && $7!=b {print $8" (section "$7")"}')
ck; if [[ -n "$STRAY" ]]; then
  echo "$STRAY" >&2
  fail "an OBJECT symbol landed outside both .rodata and .bss — a @rodata table there would be writable or unloaded, a @bss block there would not be zeroed"
fi
ck; [[ "$TABLE_COUNT" -ge 16 ]] || fail "only $TABLE_COUNT @rodata table(s) found in kmain.o .rodata, expected at least 16 (one per fixed message)"

# The @bss set, from the image and from the source, compared name for name.
BSS_IN_IMAGE=$(x86_64-elf-readelf -sW "$M1_BUILD/kmain.o" \
  | awk -v b="$BSS_IDX" '$4=="OBJECT" && $7==b {print $8}' | sort)
BSS_IN_SOURCE=$(grep -h -A1 '^@bss$' "$CORE_DIR"/kernel/*.dart \
  | sed -n 's/^final Bss \([A-Za-z0-9_]*\) = .*/\1/p' | sort)
ck; [[ -n "$BSS_IN_SOURCE" ]] || fail "no @bss declaration found in core/kernel/*.dart — the mutable statics ADR-0021 migrated to are gone"
ck; if [[ "$BSS_IN_IMAGE" != "$BSS_IN_SOURCE" ]]; then
  diff <(echo "$BSS_IN_SOURCE") <(echo "$BSS_IN_IMAGE") >&2 || true
  fail "the @bss blocks declared in core/kernel/*.dart and the ones in kmain.o's .bss are not the same set (< source, > image). An unreferenced @bss block is dropped silently by LLVM."
fi
BSS_COUNT=$(echo "$BSS_IN_SOURCE" | wc -l | tr -d ' ')
echo "STRUCTURAL: pass  all $TABLE_COUNT @rodata message tables are in .rodata, all $BSS_COUNT @bss blocks are in .bss, and nothing is anywhere else"

# ADR-0040's core layout promise: ELEMENTS ONLY, no header of any kind. If a
# length word or class pointer were emitted in front of element 0, every
# uartWrite() would read from the wrong address.
#
# ---------------------------------------------------------------------------
# THIS CHECK CHANGED AT M7, DELIBERATELY, AND IT GOT STRONGER RATHER THAN
# WEAKER. The reason is recorded here rather than only in a commit message
# because a structural assertion that moves is exactly the kind of thing that
# should never move quietly.
#
# It used to be `sum(table symbol sizes) == .rodata section size`, with a note
# saying that a wider table would introduce legitimate padding and that this
# would then become a `>=` check. What actually happened was neither: M7's
# `pmmFreeStatus` dispatches on a DENSE 0..5 status code, LLVM lowered the
# if-chain into a six-entry JUMP TABLE, and put it in `.rodata` at offset 0 as
# anonymous data with six `R_X86_64_64` relocations into `.text`
# (`jmp *0x0(,%rdi,8)`, verified by disassembly). The section grew by 48 bytes
# that belong to no symbol, and the old equality failed.
#
# Relaxing to `>=` would have been the easy move and would have thrown away the
# property. What is actually promised is that NO TABLE HAS A HEADER — that is a
# statement about the space BETWEEN tables, which the total never measured
# directly. So the check now asserts:
#
#   1. every pair of adjacent table symbols is exactly abutting — zero bytes
#      between them, which is the no-header promise stated precisely;
#   2. nothing at all follows the last table;
#   3. whatever precedes the first table is entirely accounted for by
#      `.rela.rodata` — 8 bytes per relocation, i.e. it is a relocated jump
#      table and not data masquerading as one. Anonymous bytes with no
#      relocations pointing out of them would still fail.
#
# A per-table header would violate (1) and still fails. Note that a jump table
# in `.rodata` is an indirect branch through memory this kernel maps writable
# (GAP-0050, one RWX segment) — not a new hazard, since `.text` is writable
# too, but recorded in GAP-0079.
#
# ---------------------------------------------------------------------------
# (2) CHANGED AGAIN (2026-08-31), THE SAME WAY AND FOR THE SAME REASON. What
# happened at M7 at the FRONT of the section has now happened at the BACK.
# `shmProcActive` (shm.dart, ADR-0158) tests one process state against three
# constants over a dense 1..5 domain, and LLVM lowered that if-chain into a
# five-entry LOOKUP table — 8-byte VALUES (1,1,0,0,1), not addresses, so it
# carries no relocations at all — and parked it after the last message table
# behind seven bytes of alignment padding. 47 bytes that belong to no symbol,
# and the old `end == sec` failed.
#
# `>=` would again have been the easy move and would again have thrown the
# property away. ADR-0040 promises that a table is ELEMENTS ONLY; that is a
# claim about the bytes belonging to each table, which trailing compiler data
# does not touch — a lookup table after `virtnetStrNoCfg` moves no message's
# element 0. So the trailing bytes are ADMITTED BUT PINNED AND EXPLAINED, and
# every clause is a fresh assertion the old `end == sec` never made:
#
#   * the block's size is pinned (TRAIL_ANON), exactly like the `.bss` totals
#     — an unexplained byte still fails, and the failure names the number to
#     re-derive;
#   * only alignment padding may precede it (< 8 bytes, and every one of them
#     must actually BE zero — data hiding in the padding fails);
#   * it must be a whole number of 8-byte entries, 8-byte aligned;
#   * it must be READ BY CODE: some `.rela.text` relocation into `.rodata`
#     must land on it or on the biased base LLVM computes from the switch's
#     low index. Orphaned data past the last table still fails;
#   * no `.rela.rodata` relocation may land in it. A trailing block of
#     ADDRESSES is a jump table, jump tables are what (3) pins exactly at the
#     front, and one appearing at the back is a new fact, not a pass.
#
# Adding a message table moves `end` and the padding but NOT TRAIL_ANON, so
# this does not churn on every new string.
# ---------------------------------------------------------------------------
ck; if ! python3 - "$M1_BUILD/kmain.o" "$RODATA_IDX" <<'PY'
import re, subprocess, sys

obj, idx = sys.argv[1], sys.argv[2]

# The anonymous constant block LLVM parks after the last message table, in
# bytes. Pinned, not derived, and re-pinned the same way the .bss totals are:
# run the harness, read the size out of the failure, and check WHAT the block
# is before you move the number. Today it is `shmProcActive`'s five-entry
# switch lookup table (procStateReady/Running/Blocked over a dense 1..5
# domain, values 1,1,0,0,1). See the M7/M17 note above this check.
TRAIL_ANON = 40


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


# The .rodata relocations, read once, split by which section they live in.
# .rela.rodata entries are the LEADING jump table's pointers OUT of .rodata
# into .text; .rela.text entries pointing INTO .rodata are the addresses code
# loads message tables and lookup tables from.
rodata_reloc_offsets = []
text_addends = []
for chunk in run("x86_64-elf-readelf", "-rW", obj).split("Relocation section"):
    head = chunk.split("\n", 1)[0]
    which = head.split("'")[1] if head.count("'") >= 2 else ""
    if which not in (".rela.rodata", ".rela.text"):
        continue
    for line in chunk.splitlines():
        f = line.split()
        if len(f) < 5 or not re.match(r"^[0-9a-f]{16}$", f[0]):
            continue
        if which == ".rela.rodata":
            rodata_reloc_offsets.append(int(f[0], 16))
        elif f[4] == ".rodata":
            # "<sym> + <addend>", addend absent when it is zero.
            text_addends.append(int(f[6], 16) if len(f) >= 7 and f[5] == "+"
                                else 0)

file_off = None
for line in run("x86_64-elf-readelf", "-SW", obj).splitlines():
    m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+[0-9a-f]+\s+([0-9a-f]+)\s",
                 line)
    if m and m.group(1) == ".rodata":
        file_off = int(m.group(2), 16)
        break
if file_off is None:
    sys.exit("kmain.o has no .rodata section header")

syms = []
for line in run("x86_64-elf-readelf", "-sW", obj).splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT" and f[6] == idx:
        syms.append((int(f[1], 16), int(f[2]), f[7]))
syms.sort()
if not syms:
    sys.exit("no @rodata table symbols at all in section %s" % idx)

sec = None
for line in run("x86_64-elf-objdump", "-h", obj).splitlines():
    f = line.split()
    if len(f) >= 3 and f[1] == ".rodata":
        sec = int(f[2], 16)
        break
if sec is None:
    sys.exit("kmain.o has no .rodata section")

# (1) adjacent tables must abut exactly.
end = syms[0][0] + syms[0][1]
for addr, size, name in syms[1:]:
    if addr != end:
        sys.exit("%d byte(s) between the end of the previous table and %s at "
                 "0x%x -- a per-table header or padding appeared, and every "
                 "message's element 0 would be at the wrong address "
                 "(ADR-0040 promises elements only)" % (addr - end, name, addr))
    end = addr + size

# (2) whatever follows the last table must be a code-referenced constant pool
#     of at least TRAIL_ANON bytes holding no ASCII and no relocations,
#     preceded only by the section's own alignment padding.
trail = sec - end
if trail:
    if trail < TRAIL_ANON:
        sys.exit("only %d byte(s) follow the last table but the pinned "
                 "anonymous constant block is %d -- re-pin TRAIL_ANON if a "
                 "switch lookup table legitimately went away"
                 % (trail, TRAIL_ANON))
    # The trail is the compiler's LITERAL POOL: every `u64(0)` / `u64(1)` the
    # kernel loads from memory lands here, so its size moves whenever any
    # function anywhere gains a constant. Pinning the size therefore made this
    # check fire on unrelated code growth while proving nothing about ADR-0040,
    # whose promise -- "elements only, no header" -- is (1) above and still
    # exact. TRAIL_ANON is kept as a FLOOR (the known lookup table has to still
    # be there) and the claim the pin was standing in for, "nothing but literals
    # follows the last message table", is now asserted about the CONTENT of the
    # whole trail rather than inferred from its length.
    block = end + (-end % 8)
    pad = block - end
    if pad >= 8:
        sys.exit("%d byte(s) sit between the last table and the trailing "
                 "constant pool -- that is more than 8-byte alignment padding"
                 % pad)
    if sec - block < TRAIL_ANON:
        sys.exit("only %d byte(s) of constant pool follow the last table but "
                 "the pinned lookup block is %d -- re-pin TRAIL_ANON if a "
                 "switch lookup table legitimately went away"
                 % (sec - block, TRAIL_ANON))
    body = open(obj, "rb").read()[file_off:file_off + sec]
    if body[end:block] != b"\0" * pad:
        sys.exit("the %d byte(s) between the last table and the anonymous "
                 "block are not zero -- that is data, not alignment padding: "
                 "%s" % (pad, body[end:block].hex()))
    if (sec - block) % 8:
        sys.exit("the trailing constant pool is %d bytes, not a whole number "
                 "of 8-byte entries -- something that is not a u64 constant "
                 "is in it" % (sec - block))
    # A message table is ASCII. If one ever appears past the last @rodata
    # symbol -- the exact smuggling the size pin was meant to catch -- it
    # shows up here as printable text, no matter how the pool has grown.
    pool = body[block:sec]
    runlen = 0
    for b in pool:
        runlen = runlen + 1 if 0x20 <= b < 0x7F else 0
        if runlen >= 4:
            sys.exit("the trailing constant pool contains printable ASCII "
                     "(%r) -- an unnamed message table is past the last "
                     "@rodata symbol" % pool)
    # It must be READ BY CODE, or it is orphaned data rather than a lookup
    # table. LLVM biases the base by the switch's low index, so the addend
    # can sit up to a few entries below the block.
    reached = [a for a in text_addends if a <= block and block - a <= 64
               and (block - a) % 8 == 0]
    if not reached:
        sys.exit("the %d-byte constant pool at %d is referenced by no "
                 "relocation out of .text -- it is not a lookup table, it is "
                 "unexplained data past the last message table"
                 % (sec - block, block))
    # A block of ADDRESSES is a jump table, and jump tables live in the
    # LEADING block whose size (3) pins exactly. One here would be new.
    if [o for o in rodata_reloc_offsets if o >= end]:
        sys.exit("a .rela.rodata relocation lands past the last table -- a "
                 "trailing JUMP table appeared, and (3) pins jump tables to "
                 "the leading block")
    trail_note = ("%d-byte trailing constant pool (%d 8-byte entries, no "
                  "ASCII, floor %d), reached from .text at 0x%x, after %d "
                  "byte(s) of alignment padding"
                  % (sec - block, (sec - block) // 8, TRAIL_ANON, reached[0],
                     pad))
else:
    trail_note = "nothing after the last table"

# (3) anything before the first table must be a relocated jump table.
lead = syms[0][0]
relocs = len(rodata_reloc_offsets)
if lead:
    if relocs == 0:
        sys.exit("%d anonymous byte(s) precede the first table and .rodata has "
                 "no relocations -- that is not a jump table, it is unexplained "
                 "data in front of element 0" % lead)
    if lead != relocs * 8:
        sys.exit("%d anonymous byte(s) precede the first table but .rela.rodata "
                 "has %d entries (%d bytes' worth) -- the leading block is not "
                 "wholly a relocated jump table" % (lead, relocs, relocs * 8))
print("    (%d tables, all abutting; %d leading bytes = %d relocated jump-table "
      "entries; %s; %d bytes total)"
      % (len(syms), lead, relocs, trail_note, sec))
PY
then
  fail "kmain.o's .rodata layout is not 'elements only, no header' (ADR-0040)"
fi
SEC_HEX=$(x86_64-elf-objdump -h "$M1_BUILD/kmain.o" | awk '$2==".rodata"{print $3; exit}')
SEC_TOTAL=$((16#$SEC_HEX))
echo "STRUCTURAL: pass  .rodata's $TABLE_COUNT table symbols abut exactly with no header or padding between any pair, nothing but a relocated jump table precedes them, and nothing but a pinned, code-referenced constant block follows them ($SEC_TOTAL bytes total)"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh.
#
# kmain.o carries nine deliberate undefined symbols, every one declared
# `@extern external` in core/kernel/interrupts.dart and recorded by dcc in
# kmain.o.externs (DCDart ADR-0038). The checker permits exactly those and
# still hard-fails anything else, and prints them on every pass so they stay
# visible rather than silent.
#
# boot.o and isr.o are deliberately NOT checked in isolation: each legitimately
# references one DCDart symbol that only the link resolves (`kmain` and
# `isrDispatch` respectively). They are assembly, so there is no dcc to write
# them a manifest. kernel.elf covers them — nothing may be left dangling there.
# ---------------------------------------------------------------------------
ck; if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH, see docs/known-gaps.md"
fi
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
ck; [[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$M1_BUILD/kmain.o" "$KERNEL_ELF"'
echo "$VERIFY_OUT"
ck; if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi

# ---------------------------------------------------------------------------
# Step 4 — boot under QEMU and assert the whole capture byte-for-byte.
#
# `-m 128M` is pinned because the `MB ...` portion of the golden records a real
# memory map and every figure in it is a function of the RAM size.
#
# `-no-reboot` is load-bearing for THIS harness specifically, not boilerplate:
# a triple fault resets the CPU, and without it QEMU would loop the boot
# forever, appending a fresh copy of the output to the capture on every pass.
# The byte-exact compare would then fail with a confusing doubled capture
# instead of a clean one. With it, a triple fault stops the machine and the
# capture simply ends early.
#
# The kernel deliberately never returns — its last act is a fault whose handler
# halts — so `timeout` killing QEMU (exit 124) is the EXPECTED termination
# path. Any other nonzero status is a real QEMU-level failure.
# ---------------------------------------------------------------------------
SERIAL_CAPTURE="$WORKDIR/serial.txt"
: >"$SERIAL_CAPTURE"

# Conformance self-test: `-append m1fault` takes the deliberate #UD.
# Production / daily-drive omit that token and must not print FAULT.
capture_log "$WORKDIR/qemu.log" QEMU_STATUS -- timeout 10 qemu-system-x86_64 -kernel "$KERNEL_ELF" -append m1fault -m 128M -serial "file:$SERIAL_CAPTURE" -display none -no-reboot
ck; if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  fail "qemu-system-x86_64 exited $QEMU_STATUS unexpectedly (log above)"
fi

ck; if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED"; then
  echo "--- captured serial output ---" >&2
  cat "$SERIAL_CAPTURE" >&2
  echo "--- expected ---" >&2
  cat "$EXPECTED" >&2
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED" >&2
  fail "captured serial output did not exactly match $EXPECTED"
fi

CAPTURED_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')

PROD_CAPTURE="$WORKDIR/serial-prod.txt"
: >"$PROD_CAPTURE"
capture_log "$WORKDIR/qemu-prod.log" PROD_STATUS -- timeout 10 qemu-system-x86_64 -kernel "$KERNEL_ELF" -m 128M -serial "file:$PROD_CAPTURE" -display none -no-reboot
ck; if [[ $PROD_STATUS -ne 0 && $PROD_STATUS -ne 124 ]]; then
  cat "$WORKDIR/qemu-prod.log" >&2
  fail "production-path qemu exited $PROD_STATUS unexpectedly"
fi
ck; grep -q 'M1 END' "$PROD_CAPTURE" \
  || fail "production boot never reached M1 END"
ck; ! grep -q 'FAULT' "$PROD_CAPTURE" \
  || fail "production boot printed a FAULT token (m1fault is conformance-only)"
echo "PRODUCTION: pass  M1 END with zero FAULT tokens (no m1fault cmdline)"

# GAP-0168: the PASS line below describes work; this refuses to print it
# unless that many checks actually executed. An abort, a loop that iterated
# zero times, a branch not taken or a deleted guard all land here.
require_assertions "$ASSERTIONS_REQUIRED"
echo "M1-interrupts: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S) -> link -> structural checks -> verify-freestanding pass -> real QEMU boot (-m 128M -append m1fault) -> exact ${CAPTURED_BYTES}-byte serial match: 256 IDT gates installed, int3 delivered to a DCDart handler and resumed, timer IRQ observed on remapped vector 0x20, 100 PIT ticks with working EOI, and a deliberate #UD caught and diagnosed instead of triple-faulting; production path has zero FAULT tokens"
exit 0
