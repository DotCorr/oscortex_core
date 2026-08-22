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

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DERIVE="$SCRIPT_DIR/derive.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
[[ -f "$DERIVE" ]] || setup_error "derivation module not found at $DERIVE"
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m7-frames reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m7.XXXXXX")" || setup_error "could not create a temp workdir"
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
KDATA_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$KDATA_BSS_HEX" ]] || fail "kdata.o has no .bss section — the donated storage is missing"
KDATA_BSS=$(hexnum "$KDATA_BSS_HEX")
# M8 (ADR-0012) added a block AFTER M7's: `vm_store`, 128 bytes for the
# virtual-memory subsystem. It is SUBTRACTED here rather than folded into the
# total, for the same reason m5-pci and m6-disk subtract `pmm_store`: M7's claim
# was never "the total is 5096", it was "the page allocator cost 4672 bytes and
# everything before it cost 424", and a later milestone must not be able to
# dilute that by growing the total. m8-paging/run.sh owns the 5224 now.
VM_STORE_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="vm_store"{print $3; exit}')
[[ -n "$VM_STORE_SIZE" ]] || fail "vm_store is not in kdata.o — M8's virtual-memory state block is missing"
# M9 (ADR-0013) added a third block after M8's: `user_store` (128 bytes, the
# ring-3 subsystem's state) plus the two asm-owned resume words
# `user_resume_rsp`/`user_resume_ok` (8 each). They are SUBTRACTED here rather
# than folded into the total, for the same reason `vm_store` and `pmm_store`
# are: this milestone's claim is about ITS OWN number, and a later milestone
# must not be able to dilute it by growing the total.
M9_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="user_store"{print $3; exit}')
M9_RSP=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="user_resume_rsp"{print $3; exit}')
M9_OK=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="user_resume_ok"{print $3; exit}')
[[ -n "$M9_STORE" && -n "$M9_RSP" && -n "$M9_OK" ]] || fail "user_store / user_resume_rsp / user_resume_ok are not all in kdata.o — M9's ring-3 state block is missing"
M9_BSS=$(( M9_STORE + M9_RSP + M9_OK ))
# M10 (ADR-0014) added a fourth block after M9's: `elf_store` (128 bytes, the
# ELF loader's whole state, behind ONE accessor called from ONE function). It is
# SUBTRACTED here rather than folded into this milestone's number, so this
# harness keeps asserting ITS OWN claim exactly as it did before M10 existed --
# the same discipline every earlier harness applies to every later block.
M10_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="elf_store"{print $3; exit}')
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
M11_ELF_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="elf_store"{print $2; exit}')
[[ -n "$M11_ELF_OFF_HEX" ]] || fail "elf_store has no .bss offset in kdata.o"
# M14 (ADR-0018) added a SIXTH block after M11's: `fat_store` (1824 bytes -- 32
# metadata words, a 256-entry cluster chain, one sector buffer and an 8.3 name
# buffer). Its `.align 8` inserts NO padding, because `proc_store` ends at a
# multiple of 16. Measured as everything from `fat_store`'s offset to the end of
# `.bss` and subtracted out below, so that THIS harness's own number and M11's
# both come out exactly as they did before M14 existed.
M14_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="fat_store"{print $2; exit}')
[[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
[[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824. If M14's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
M11_BSS=$(( KDATA_BSS - 16#$M11_ELF_OFF_HEX - M10_STORE - M14_BSS ))
[[ "$M11_BSS" -eq 4168 ]] || fail "the donated bytes past the end of M10's elf_store are $M11_BSS, expected 4168 (M11's 4160-byte proc_store plus the 8 bytes of padding its .align 16 needs). If M11's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
NON_VM_BSS=$(( KDATA_BSS - VM_STORE_SIZE - M9_BSS - M10_STORE - M11_BSS - M14_BSS ))
if [[ "$NON_VM_BSS" -ne 5096 ]]; then
  fail "kdata.o donates $KDATA_BSS bytes of .bss, of which $VM_STORE_SIZE are M8's vm_store, leaving $NON_VM_BSS — expected 5096 (424 before M7, plus 4672 for the allocator)."
fi
echo "STRUCTURAL: pass  kdata.o donates exactly 5096 bytes of .bss outside M8's page-table block — 424 inherited, 4672 for the page allocator"

# 2b. THE ALLOCATOR'S STATE IS ONE SYMBOL.
PMM_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="pmm_store"{print $3; exit}')
[[ -n "$PMM_SIZE" ]] || fail "pmm_store is not in kdata.o — the allocator's storage block is missing"
[[ "$PMM_SIZE" -eq 4672 ]] || fail "pmm_store is $PMM_SIZE bytes, expected 4672 (4096 bitmap + 64 metadata + 512 ledger)"
echo "STRUCTURAL: pass  pmm_store is one 4672-byte symbol: 4096 bitmap + 64 metadata + 512 ledger"

# 2c. THE STORAGE SEAM IS EXACTLY THREE CALL SITES, AND THIS IS THE CHECK THAT
#     PROTECTS THE MIGRATION.
#
# core/kernel/pmm.dart's design claim is that swapping assembly-donated `.bss`
# for real DCDart mutable statics is a change to three functions. That is only
# true while `pmm_store_addr()` is called from exactly those three functions
# and from nowhere else in the kernel. A fourth call site anywhere is the
# moment the claim stops being true, and it would be invisible in any test that
# only looks at behaviour — so it is checked here.
SEAM_SITES=$(grep -c '^\s*return pmm_store_addr()' "$CORE_DIR/kernel/pmm.dart")
[[ "$SEAM_SITES" -eq 3 ]] || fail "pmm_store_addr() is returned from $SEAM_SITES functions in pmm.dart, expected exactly 3 (pmmBitmapBase, pmmMetaBase, pmmLedgerBase). The storage seam is the whole mutable-statics migration plan — see pmm.dart's header."
STRAY=$(grep -n 'pmm_store_addr()' "$CORE_DIR/kernel/pmm.dart" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | grep -vE 'external u64 pmm_store_addr\(\);' | grep -vc 'return pmm_store_addr()')
[[ "$STRAY" -eq 0 ]] || fail "pmm.dart has $STRAY call(s) of pmm_store_addr() outside the three seam functions"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "pmm.dart" ]] && continue
  grep -q 'pmm_store_addr' "$f" && fail "$(basename "$f") references pmm_store_addr — the allocator's storage seam must not leak out of pmm.dart"
done
echo "STRUCTURAL: pass  pmm_store_addr() is called from exactly 3 functions, all in pmm.dart's storage seam, and from no other kernel source"

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
[[ -n "$MAP_PAGES" && -n "$MAX_FRAMES" && -n "$FRAME_BYTES" ]] || fail "could not read MAP_2MIB_PAGES / pmmMaxFrames / pmmFrameBytes out of the source"
MAPPED=$(( MAP_PAGES * 2 * 1024 * 1024 ))
MANAGED=$(( MAX_FRAMES * FRAME_BYTES ))
[[ "$MAPPED" -eq "$MANAGED" ]] || fail "boot.S identity-maps $MAPPED bytes but the allocator manages $MANAGED — a frame the kernel cannot address is not a frame it can hand out. Raise MAP_2MIB_PAGES and pmmMaxFrames together."
echo "STRUCTURAL: pass  boot.S maps $MAP_PAGES x 2MiB = $MAPPED bytes and the allocator manages $MAX_FRAMES x $FRAME_BYTES = $MANAGED — the same number"

# derive.py restates pmm.dart's constants; they must not drift apart either.
python3 - "$DERIVE" "$MAX_FRAMES" "$FRAME_BYTES" <<'PY' || fail "derive.py's constants do not match pmm.dart's"
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
PMM_ADDR=$(x86_64-elf-readelf -sW "$KERNEL_ELF" | awk '$8=="pmm_store"{print $2; exit}')
[[ -n "$KSTART" && -n "$KEND" && -n "$PMM_ADDR" ]] || fail "__kernel_start / __kernel_end / pmm_store are not all in kernel.elf — the linker script did not export the image extents"
KSTART_D=$(hexnum "$KSTART"); KEND_D=$(hexnum "$KEND"); PMM_D=$(hexnum "$PMM_ADDR")
[[ "$KSTART_D" -eq $((1024*1024)) ]] || fail "__kernel_start is 0x$KSTART, expected 0x100000 (the Multiboot load address in kernel.ld)"
[[ "$KEND_D" -gt "$KSTART_D" ]] || fail "__kernel_end (0x$KEND) is not above __kernel_start (0x$KSTART)"
[[ "$PMM_D" -ge "$KSTART_D" && "$PMM_D" -lt "$KEND_D" ]] || fail "pmm_store (0x$PMM_ADDR) is outside [__kernel_start, __kernel_end) — the allocator's own bitmap would not be covered by the kernel-image reservation, so the allocator could hand out the frame its bitmap lives in"
echo "STRUCTURAL: pass  the image is [0x$KSTART, 0x$KEND) from kernel.ld, and pmm_store (0x$PMM_ADDR) is inside it — the bitmap reserves itself"

# 2f. THE BOUND SURVIVES INTO THE COMPILED CODE.
#
# Same check m6-disk makes on `ataWait`'s poll bound and for the same reason: a
# constant that exists only in the source proves nothing about what runs. LLVM
# may count up to 0x8000 or down from it, so either immediate is accepted; what
# is not accepted is neither.
PMMINIT_DIS=$(x86_64-elf-objdump -d --disassemble=pmmInit "$CORE_DIR/build/kmain.o")
[[ -n "$PMMINIT_DIS" ]] || fail "pmmInit is not in kmain.o — the allocator is not being compiled"
if ! grep -qE '0x8000|0xffff8000|32768' <<<"$PMMINIT_DIS"; then
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
PIN=$(awk '{print $1; exit}' "$CORE_DIR/../DCDART_PIN.txt")
[[ "$PIN" == e3cfe18* ]] || fail "DCDART_PIN.txt says $PIN; M7 requires e3cfe18 or later (nested while-loops, GAP-0068) — pmm.dart's memory-map walk is a loop inside a loop"
grep -q 'while (f < lastEx)' "$CORE_DIR/kernel/pmm.dart" || fail "pmm.dart's inner frame loop is gone — if it was decomposed into a helper, the pin bump is no longer justified and GAP-0068 needs updating"
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
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M7 depends on was not emitted"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060: the length is a hand-maintained literal)"
}
check_table shellStrHelp 2147  # M10 added `run <lba>`, M11 three `proc` lines, M14 `run <name>` + `fs`/`ls`/`cat`; GAP-0060
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
check_table pmmStrUsage 67
check_table pmmStrFreeUsage 44
check_table pmmCmdFrames 6
check_table pmmCmdTest 11
check_table pmmCmdDrain 12
check_table pmmCmdRefill 13
check_table pmmCmdAlloc 5
check_table pmmCmdFree 5
echo "STRUCTURAL: pass  all 52 M7 @rodata tables plus shellStrHelp (621 -> 1028) are exactly the sizes their call sites pass"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# THREE new externs, 29 -> 32, and each one is named because the count is a
# claim about the design:
#
#   pmm_store_addr      the whole storage seam. One accessor for 4672 bytes.
#   kernel_image_start  } the image extents, from the linker script rather than
#   kernel_image_end    } hardcoded. In boot.S, not kdata.S, so that kdata.o
#                         keeps passing this check standalone (GAP-0056).
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
# M8 (ADR-0012) added TWELVE more, so the raw count is now 44. Subtracted BY
# NAME rather than folded into a new total, the same way the donated-`.bss`
# check above subtracts `vm_store`: M7's claim is about M7's three externs, and
# a later milestone must not be able to move the number that states it.
M8_EXTERNS="cr0_read cr2_read cr3_read paging_install vm_exec_probe vm_exec_ok_addr nx_enabled kernel_text_end kernel_rodata_start kernel_rodata_end kernel_data_start vm_store_addr"
M8_PRESENT=0
for sym in $M8_EXTERNS; do
  grep -q "$sym" <<<"$VERIFY_OUT" && M8_PRESENT=$(( M8_PRESENT + 1 ))
done
[[ "$M8_PRESENT" -eq 12 ]] || fail "only $M8_PRESENT of M8's 12 externs are in kmain.o's manifest"
# M9 (ADR-0013) added eight more, and they are subtracted BY NAME for the reason
# the donated-`.bss` check above subtracts M9's blocks: this milestone's claim is
# about its own externs.
M9_EXTERNS="enter_user gdt_base tlb_invlpg tr_read tss_base user_resume_ok_addr user_return user_store_addr"
M9_PRESENT=0
for sym in $M9_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M9_PRESENT=$(( M9_PRESENT + 1 ))
done
# M10 (ADR-0014) added exactly ONE more -- `elf_store_addr`, the ELF loader's
# storage seam -- and it is subtracted here for the reason M9's eight are: this
# harness's claim is about ITS OWN milestone's count, and it must keep meaning
# what it meant before M10 existed.
M10_EXTERNS="elf_store_addr"
for sym in $M10_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M9_PRESENT=$(( M9_PRESENT + 1 ))
done
# M11 (ADR-0015) added FIVE more -- `sse_enabled`, `cr4_read`, `fx_save`,
# `fx_restore` and `proc_store_addr`. They are subtracted BY NAME for the reason
# M8's twelve, M9's eight and M10's one are: this harness's claim is about ITS
# OWN milestone's count, and it must keep meaning what it meant before M11.
M11_EXTERNS="sse_enabled cr4_read fx_save fx_restore proc_store_addr"
M11_PRESENT=0
for sym in $M11_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M11_PRESENT=$(( M11_PRESENT + 1 ))
done
[[ "$M11_PRESENT" -eq 5 ]] || fail "only $M11_PRESENT of M11's 5 externs are in kmain.o's manifest ($M11_EXTERNS)"
# M14 (ADR-0018) added exactly ONE: `fat_store_addr`, the filesystem's storage
# seam. Subtracted for the same reason M8's, M9's, M10's and M11's are: this
# harness's claim is about ITS OWN milestone's count.
M14_EXTERNS="fat_store_addr"
M14_PRESENT=0
for sym in $M14_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M14_PRESENT=$(( M14_PRESENT + 1 ))
done
[[ "$M14_PRESENT" -eq 1 ]] || fail "M14's fat_store_addr is not in kmain.o's manifest"
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M11_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M9_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M8_PRESENT ))
[[ "$EXTERN_COUNT" -eq 32 ]] || fail "kmain.o declares $EXTERN_COUNT externs outside M8's twelve, expected 32 (29 from M6 plus pmm_store_addr, kernel_image_start, kernel_image_end)"
for sym in pmm_store_addr kernel_image_start kernel_image_end; do
  grep -q "$sym" <<<"$VERIFY_OUT" || fail "$sym is not in kmain.o's extern manifest"
done
# kdata.o must STILL have no undefined symbols at all — GAP-0056 records that
# as a real property, and it is why the kernel-extent accessors went in boot.S.
grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs — something in it now references an outside symbol (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — 29 from M6 plus exactly three, and kdata.o still passes standalone"

# ---------------------------------------------------------------------------
# Step 4 — the boots.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" mem="$6"
  shift 6
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port=$(( 47000 + ($$ % 8000) + portoff ))
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

[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# ---------------------------------------------------------------------------
# Step 5 — assert.
# ---------------------------------------------------------------------------

# 5a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M7 changed M0/M1 serial output"
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

# 5c. EVERY NUMBER, DERIVED. This is the assertion the milestone exists for.
if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$KSTART" "$KEND" "$WORKDIR/session/monitor.txt" "$PMM_ADDR" <<'PY'
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
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  cat -n "$SCREEN_TEXT" >&2
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

if ! python3 - "$WORKDIR/drained/serial.txt" "$DERIVE" "$KSTART" "$KEND" "$WORKDIR/drained/monitor.txt" <<'PY'
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

if ! python3 - "$WORKDIR/over/serial.txt" "$DERIVE" "$KSTART" "$KEND" <<'PY'
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

if ! python3 - "$WORKDIR/small/serial.txt" "$SERIAL_CAPTURE" "$DERIVE" "$KSTART" "$KEND" <<'PY'
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
if cmp -s "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL"; then
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
[[ -n "$SMALL_DIFF" ]] || fail "could not locate where the small-machine capture diverges from the golden, which means cmp reported no difference at all"
SMALL_OFFSET=${SMALL_DIFF##* }
[[ "$SMALL_OFFSET" -le 544 ]] || fail "the 32MiB capture matches M1's entire 544-byte golden, so the boot-time memory-map report did not change with the machine's memory — the map the allocator is built from is not describing this machine"
head -c 15 "$WORKDIR/small/serial.txt" | cmp -s - <(head -c 15 "$EXPECTED_SERIAL") \
  || fail "the 32MiB boot does not even produce the same M0 banner — this is not the same kernel"
echo "ASSERT: pass  negative control — the same kernel (same M0 banner) on a 32MiB machine reports a different, independently derived free count, and its capture diverges from the 128MiB golden at $SMALL_DIFF, inside the boot-time memory-map report where a different machine must show"

echo "M7-frames: PASS — dcc build -> assemble (boot.S + isr.S + kdata.S + portio.S) -> link -> 8 structural checks (donated .bss 424 -> 5096, pmm_store one 4672-byte symbol, the storage seam exactly 3 call sites, boot.S's identity map == the allocator's bound, derive.py's geometry == pmm.dart's, the image extents from kernel.ld with pmm_store inside them, the 0x8000 bound in the compiled code, 53 @rodata sizes) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 29 + 3, kdata.o still clean standalone) -> FOUR real QEMU boots (-cpu qemu64 -vga std) over QMP. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; every count, address, sum and xor DERIVED from the Multiboot memory map and kernel.elf's own extents rather than typed; 64 frames allocated, proved pairwise distinct, proved inside usable regions and outside the kernel image, written and read back, and all 64 freed; a full drain whose count equals the derived free count exactly and whose next allocation fails; the whole 4096-byte bitmap read out of guest memory and matched bit-for-bit, both after the refill and in the drained state where all 32768 bits are set; the highest managed frame written and confirmed by QEMU's own memory dump; a 256MiB boot that reports the exact number of frames above its bound and says CAPPED; and a 32MiB negative control whose numbers follow the machine rather than the kernel. Screenshot at $SHOT_PNG"
exit 0
