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

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  setup_error "qemu-system-x86_64 not found on PATH, see docs/known-gaps.md"
fi

EXPECTED="$SCRIPT_DIR/expected.txt"
[[ -f "$EXPECTED" ]] || setup_error "golden file not found at $EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m1.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build (dcc build + assemble boot.S and isr.S + link)
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
bash "$CORE_DIR/scripts/build-kernel.sh" >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
cat "$BUILD_LOG"
if [[ $BUILD_STATUS -ne 0 ]]; then
  fail "build-kernel.sh exited $BUILD_STATUS (log above)"
fi

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
[[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — structural checks that need no QEMU (CLAUDE.md's testing rules say
# anything verifiable without booting should be).
# ---------------------------------------------------------------------------
if ! command -v x86_64-elf-objdump >/dev/null 2>&1; then
  setup_error "x86_64-elf-objdump not found on PATH (brew install x86_64-elf-binutils)"
fi

# 2a. The red zone must stay disabled. DCDart ADR-0039 makes -mno-red-zone a
# property of any freestanding target, but this kernel is the thing that
# actually gets corrupted if it ever regresses, and the corruption would be
# silent data damage rather than a crash. Assert it here rather than trusting
# the toolchain to keep its promise.
RED_ZONE_HITS=$(x86_64-elf-objdump -d "$CORE_DIR/build/kmain.o" | grep -cE '\-0x[0-9a-f]+\(%rsp\)')
if [[ "$RED_ZONE_HITS" -ne 0 ]]; then
  x86_64-elf-objdump -d "$CORE_DIR/build/kmain.o" | grep -nE '\-0x[0-9a-f]+\(%rsp\)' >&2
  fail "kmain.o contains $RED_ZONE_HITS negative-%rsp access(es) — the red zone is back (DCDart ADR-0039 regressed). An interrupt would corrupt the interrupted function's locals."
fi
echo "STRUCTURAL: pass  no red-zone (negative %rsp) accesses in kmain.o"

# 2b. The deliberate fault must be a RUNTIME conditional trap. If LLVM ever
# constant-folds the overflow, the `ud2` becomes unconditional or the code is
# replaced by `unreachable` and deleted — either way `M1 FAULT 06` would stop
# being evidence of a real trap. A `ud2` reached only by a conditional branch
# is what makes it real.
if ! x86_64-elf-objdump -d --disassemble=kmain "$CORE_DIR/build/kmain.o" | grep -q 'ud2'; then
  fail "kmain contains no ud2 — the deliberate overflow trap was optimized away, so M1's fault test would prove nothing"
fi
echo "STRUCTURAL: pass  kmain contains a ud2 (deliberate overflow trap survives codegen)"

# 2c. 256 stubs at a 16-byte stride, and the stub table sized to match.
# Size column is hex; converted with bash arithmetic rather than awk's
# strtonum(), which is a gawk extension and absent from macOS's awk.
STUB_TABLE_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/isr.o" | awk '$2 == ".rodata" {print $3; exit}')
[[ -n "$STUB_TABLE_HEX" ]] || fail "isr.o has no .rodata section — the stub-address table is missing"
STUB_TABLE_BYTES=$((16#$STUB_TABLE_HEX))
if [[ "$STUB_TABLE_BYTES" -ne 2048 ]]; then
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
if x86_64-elf-objdump -h "$KERNEL_ELF" | grep -qE '\.got(\.plt)?[[:space:]]'; then
  x86_64-elf-objdump -h "$KERNEL_ELF" | grep -E '\.got' >&2
  fail "kernel.elf has a .got/.got.plt section — something started emitting position-independent indirection into a fixed-address kernel image"
fi
echo "STRUCTURAL: pass  kernel.elf has no .got/.got.plt"

# Every OBJECT symbol dcc emits is a @rodata table (DCDart emits no other
# globals), so all of them must live in .rodata's section index.
RODATA_IDX=$(x86_64-elf-readelf -SW "$CORE_DIR/build/kmain.o" | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\][[:space:]]*\.rodata[[:space:]].*/\1/p')
[[ -n "$RODATA_IDX" ]] || fail "kmain.o has no .rodata section — the @rodata message tables are missing entirely"

TABLE_COUNT=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v ix="$RODATA_IDX" '$4=="OBJECT" && $7==ix' | wc -l | tr -d ' ')
STRAY=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v ix="$RODATA_IDX" '$4=="OBJECT" && $7!=ix {print $8" (section "$7")"}')
if [[ -n "$STRAY" ]]; then
  echo "$STRAY" >&2
  fail "a @rodata table landed outside .rodata — it would be writable, or not loaded at all"
fi
[[ "$TABLE_COUNT" -ge 16 ]] || fail "only $TABLE_COUNT @rodata table(s) found in kmain.o .rodata, expected at least 16 (one per fixed message)"
echo "STRUCTURAL: pass  all $TABLE_COUNT @rodata message tables are in .rodata"

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
# ---------------------------------------------------------------------------
if ! python3 - "$CORE_DIR/build/kmain.o" "$RODATA_IDX" <<'PY'
import re, subprocess, sys

obj, idx = sys.argv[1], sys.argv[2]


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


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

# (2) nothing after the last table.
if end != sec:
    sys.exit("%d byte(s) follow the last table (.rodata is %d bytes, the last "
             "table ends at %d)" % (sec - end, sec, end))

# (3) anything before the first table must be a relocated jump table.
lead = syms[0][0]
relocs = len(re.findall(r"^[0-9a-f]{16} ", run("x86_64-elf-readelf", "-rW", obj)
                        .split("'.rela.rodata'")[-1], re.M)) if ".rela.rodata" \
    in run("x86_64-elf-readelf", "-SW", obj) else 0
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
      "entries; %d bytes total)" % (len(syms), lead, relocs, sec))
PY
then
  fail "kmain.o's .rodata layout is not 'elements only, no header' (ADR-0040)"
fi
SEC_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".rodata"{print $3; exit}')
SEC_TOTAL=$((16#$SEC_HEX))
echo "STRUCTURAL: pass  .rodata's $TABLE_COUNT table symbols abut exactly with no header or padding between any pair, and nothing but a relocated jump table precedes them ($SEC_TOTAL bytes total)"

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
if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH, see docs/known-gaps.md"
fi
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
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

timeout 10 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -serial "file:$SERIAL_CAPTURE" \
  -display none \
  -no-reboot \
  >"$WORKDIR/qemu.log" 2>&1
QEMU_STATUS=$?
if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  fail "qemu-system-x86_64 exited $QEMU_STATUS unexpectedly (log above)"
fi

if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED"; then
  echo "--- captured serial output ---" >&2
  cat "$SERIAL_CAPTURE" >&2
  echo "--- expected ---" >&2
  cat "$EXPECTED" >&2
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED" >&2
  fail "captured serial output did not exactly match $EXPECTED"
fi

CAPTURED_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "M1-interrupts: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S) -> link -> structural checks -> verify-freestanding pass -> real QEMU boot (-m 128M) -> exact ${CAPTURED_BYTES}-byte serial match: 256 IDT gates installed, int3 delivered to a DCDart handler and resumed, timer IRQ observed on remapped vector 0x20, 100 PIT ticks with working EOI, and a deliberate #UD caught and diagnosed instead of triple-faulting"
exit 0
