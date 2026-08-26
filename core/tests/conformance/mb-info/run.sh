#!/usr/bin/env bash
# core/tests/conformance/mb-info/run.sh
#
# Mechanical check that the kernel READS the Multiboot1 information structure
# the loader hands it (docs/known-gaps.md GAP-0001's first item) and reports
# it correctly over COM1 -- and, at the same time, that the real 16550 UART
# driver (core/kernel/uart.dart) can push far more than one 16-byte FIFO's
# worth of bytes without dropping any, which is what the Transmit-Holding-
# Register-Empty busy-wait exists for.
#
# Relationship to the other harnesses: each one asserts its own milestone's
# claim byte-for-byte, and the newest one asserts the whole file.
#
#   m0-boot/run.sh        the first line          `OSCORTEX M0 OK`
#   mb-info/run.sh (this) everything through      `MB END`
#   m1-interrupts/run.sh  the ENTIRE capture      through `M1 END`
#
# So m1-interrupts strictly subsumes this one, and this one strictly subsumes
# m0-boot. Run all three: each fails with a message about its OWN milestone,
# which is what makes a regression legible rather than just "the golden
# changed."
#
# This used to assert the whole file, back when `MB END` was the last thing
# the kernel printed. It is a prefix compare now because M1 legitimately
# prints more after it (docs/decisions/0002-m1-interrupts-architecture.md).
# Taken alone that is a weakening -- it no longer proves "and nothing else was
# printed" -- and it is said plainly rather than glossed. The property is not
# lost, it moved to m1-interrupts.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/mb-info/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "mb-info: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "mb-info: FAIL — $1" >&2
  exit 2
}

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  setup_error "qemu-system-x86_64 not found on PATH, see docs/known-gaps.md"
fi

EXPECTED="$SCRIPT_DIR/expected.txt"
[[ -f "$EXPECTED" ]] || setup_error "golden file not found at $EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-mb-info.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build the kernel (dcc build + assemble boot.S + link)
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
# Step 2 — verify-freestanding.sh, against the DCDart-compiled object AND the
# final linked image. kmain.o is checked explicitly here (m0-boot checks only
# the linked kernel) because uart.dart/multiboot.dart are new DCDart code and
# a leaked runtime symbol from THEM is exactly what CLAUDE.md rule 1 exists to
# catch -- in the linked image it could in principle be resolved by something
# in boot.o and hidden.
#
# boot.o and isr.o are deliberately NOT checked in isolation: each
# legitimately references one DCDart symbol that only the link resolves
# (`kmain` and `isrDispatch`). They are assembly, so there is no dcc to write
# them an extern manifest. kernel.elf covers both.
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
# Step 3 — boot under QEMU with a PINNED RAM size and assert the whole
# captured serial output byte-for-byte against expected.txt.
#
# `-m 128M` is pinned deliberately. The golden file records a real memory map
# and every figure in it is a function of the RAM size: 0x27F KiB conventional
# memory, 0x1FB80 KiB upper memory, and seven map entries whose usable regions
# sum to that. Relying on QEMU's compiled-in default (which is 128 MiB today —
# verified: the capture is byte-identical with and without the flag) would make
# this harness silently start failing on a QEMU that changed its default, and
# the failure would look like a kernel bug rather than a harness assumption.
#
# The kernel halts in an infinite hlt loop after kmain() returns (no shutdown
# mechanism exists yet), so `timeout` killing QEMU is the EXPECTED termination
# path, not a failure. Only wrong or missing captured bytes are a failure --
# and the `MB END` terminator line in the golden file is what makes a
# truncated report (a hang partway through) a hard failure rather than a
# prefix that happens to match.
# ---------------------------------------------------------------------------
SERIAL_CAPTURE="$WORKDIR/serial.txt"
: >"$SERIAL_CAPTURE"

timeout 5 qemu-system-x86_64 \
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

# Compare a fixed BYTE COUNT, not `head -n`: a capture that is shorter than
# expected, or that has the right lines but a missing trailing newline, must
# still fail.
EXPECTED_BYTES=$(wc -c <"$EXPECTED" | tr -d ' ')
PREFIX="$WORKDIR/prefix.txt"
head -c "$EXPECTED_BYTES" "$SERIAL_CAPTURE" >"$PREFIX"

if ! cmp -s "$PREFIX" "$EXPECTED"; then
  echo "--- captured serial output, first $EXPECTED_BYTES bytes ---" >&2
  cat "$PREFIX" >&2
  echo "--- expected ---" >&2
  cat "$EXPECTED" >&2
  echo "--- first differing byte ---" >&2
  cmp "$PREFIX" "$EXPECTED" >&2
  echo "--- full capture, for context ---" >&2
  cat "$SERIAL_CAPTURE" >&2
  fail "captured serial output did not exactly match $EXPECTED through 'MB END'"
fi

CAPTURED_BYTES="$EXPECTED_BYTES"
echo "mb-info: PASS — dcc build -> assemble -> link -> verify-freestanding pass -> real QEMU boot (-m 128M) -> exact ${CAPTURED_BYTES}-byte match against expected.txt (output through 'MB END') (M0 banner + full Multiboot info report, 7 memory-map entries, 'MB END' terminator)"
exit 0
