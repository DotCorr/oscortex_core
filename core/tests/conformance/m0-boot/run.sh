#!/usr/bin/env bash
# core/tests/conformance/m0-boot/run.sh
#
# Mechanical check of ROADMAP.md's M0 exit criterion: a @bare DCDart
# kernel boots under QEMU and proves it's alive over COM1 serial output.
# Same discipline as DCDart's own conformance harnesses: build for real,
# run for real, assert exact expected output, no silent skips.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m0-boot/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M0-boot: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M0-boot: FAIL — $1" >&2
  exit 2
}

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  setup_error "qemu-system-x86_64 not found on PATH, see docs/known-gaps.md"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m0-boot.XXXXXX")" || setup_error "could not create a temp workdir"
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
# Step 2 — verify-freestanding.sh against the linked kernel. kmain.o alone
# is verified by DCDart's own conformance suite; this additionally
# confirms the FINAL LINKED kernel.elf carries no undefined runtime
# symbol either (boot.S's own symbols, plus kmain.o's, resolved against
# each other with nothing left dangling).
# ---------------------------------------------------------------------------
if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH, see docs/known-gaps.md"
fi
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $KERNEL_ELF"
fi

# ---------------------------------------------------------------------------
# Step 3 — boot under QEMU, capture COM1 serial output, assert an exact
# byte match against the expected proof-of-life message.
#
# The kernel halts in an infinite hlt loop after kmain() returns (no
# shutdown mechanism exists yet, OSCORTEX_SPEC.md §2) -- `timeout`
# killing QEMU after a few seconds is therefore the EXPECTED
# termination path, not a failure. Only wrong or missing captured
# serial bytes are a failure.
# ---------------------------------------------------------------------------
SERIAL_CAPTURE="$WORKDIR/serial.txt"
: >"$SERIAL_CAPTURE"

timeout 5 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -serial "file:$SERIAL_CAPTURE" \
  -display none \
  -no-reboot \
  >"$WORKDIR/qemu.log" 2>&1
QEMU_STATUS=$?
# 124 = timeout had to kill it (expected: the hlt loop never exits on its
# own). Any OTHER nonzero status is a real QEMU-level failure (e.g. it
# refused to even start) worth surfacing.
if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  fail "qemu-system-x86_64 exited $QEMU_STATUS unexpectedly (log above)"
fi

EXPECTED="$WORKDIR/expected.txt"
printf 'OSCORTEX M0 OK\n' >"$EXPECTED"

# M0's proof of life is the FIRST LINE of serial output, asserted byte-for-
# byte. This used to be a whole-file `cmp`, back when the kernel printed
# exactly one line and nothing else.
#
# It is a first-line comparison now because the kernel legitimately prints
# more than M0's message: core/kernel/multiboot.dart's report follows it
# (docs/decisions/0003-uart-driver-and-multiboot-info.md). Keeping a
# whole-file `cmp` here would have meant either deleting real work or
# folding M1-scope output into M0's exit criterion, and both are worse.
#
# This is a WEAKENING of this harness taken on its own -- it no longer proves
# "and nothing else was printed" -- and that is stated plainly rather than
# glossed. The property is not lost, it MOVED: tests/conformance/mb-info/run.sh
# asserts the ENTIRE capture byte-for-byte, first line included, so the two
# harnesses together assert strictly more than this one did alone. Run both.
#
# `head -c` on the exact expected byte length, not `head -1`: comparing a
# fixed byte count means a capture that is SHORTER than expected, or that has
# the right first line but a missing newline, still fails. `head -1` would
# paper over both.
EXPECTED_BYTES=$(wc -c <"$EXPECTED" | tr -d ' ')
FIRST_LINE="$WORKDIR/first_line.txt"
head -c "$EXPECTED_BYTES" "$SERIAL_CAPTURE" >"$FIRST_LINE"

if ! cmp -s "$FIRST_LINE" "$EXPECTED"; then
  echo "--- captured serial output, first $EXPECTED_BYTES bytes (hex) ---" >&2
  xxd "$FIRST_LINE" >&2 2>/dev/null || od -An -tx1 "$FIRST_LINE" >&2
  echo "--- expected (hex) ---" >&2
  xxd "$EXPECTED" >&2 2>/dev/null || od -An -tx1 "$EXPECTED" >&2
  echo "--- full capture, for context (hex) ---" >&2
  xxd "$SERIAL_CAPTURE" >&2 2>/dev/null || od -An -tx1 "$SERIAL_CAPTURE" >&2
  fail "the first $EXPECTED_BYTES captured serial bytes did not exactly match the expected proof-of-life message"
fi

echo "M0-boot: PASS — dcc build -> assemble -> link -> verify-freestanding pass -> real QEMU boot -> exact serial byte match ('OSCORTEX M0 OK')"
exit 0
