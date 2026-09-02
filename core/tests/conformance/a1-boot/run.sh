#!/usr/bin/env bash
# core/tests/conformance/a1-boot/run.sh
#
# Mechanical check of arm64-port.md A1: a @bare DCDart kmain for
# bare-aarch64 links with an aarch64 boot.S, boots under
# qemu-system-aarch64 -M virt, prints exactly `OSCORTEX A64 OK\n` on
# serial, and shuts the machine down via PSCI SYSTEM_OFF (QEMU exit 0).
# verify-freestanding.sh is clean on the linked ELF.
#
# Derived/serial, not an x86 golden: the 16-byte banner is spelled here
# from the design-doc exit criterion, and the ELF machine type is read
# from `file` on the object this run just built.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/a1-boot/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "A1-boot: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "A1-boot: FAIL — $1" >&2
  exit 2
}

source "$SCRIPT_DIR/../_lib/harness.sh"

# Derived from a run, not counted by hand. See m0-boot/run.sh.
ASSERTIONS_REQUIRED=13

ck; if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  setup_error "qemu-system-aarch64 not found on PATH"
fi

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-a1-boot.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build the aarch64 kernel (does not touch kernel.elf)
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
capture_log "$BUILD_LOG" BUILD_STATUS -- bash "$CORE_DIR/scripts/build-kernel-arm.sh"
cat "$BUILD_LOG"
ck; if [[ $BUILD_STATUS -ne 0 ]]; then
  fail "build-kernel-arm.sh exited $BUILD_STATUS (log above)"
fi

KERNEL_ELF="$CORE_DIR/build/kernel-arm.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "build-kernel-arm.sh reported success but $KERNEL_ELF was not produced"

# The image must be aarch64. A mix-up that linked the x86 kernel.elf, or
# a dcc that ignored --target, fails here before QEMU is even invoked.
ELF_DESC="$(file "$KERNEL_ELF")"
ck; case "$ELF_DESC" in
  *"ARM aarch64"*) ;;
  *) fail "kernel-arm.elf is not an aarch64 ELF (file said: $ELF_DESC)" ;;
esac

# ---------------------------------------------------------------------------
# Step 1b — the banner is in the DCDart object, not in boot.S
#
# A1's whole point over the design-doc's 17-line k.S is that the serial
# bytes come from @rodata. A boot.S that .asciz'd the same string would
# still print and still exit 0. strings(1) on the two objects is the
# cheap way to keep that from passing.
# ---------------------------------------------------------------------------
KMAIN_O="$CORE_DIR/build/kmain_virt.o"
BOOT_O="$CORE_DIR/build/boot-arm.o"
ck; [[ -f "$KMAIN_O" && -f "$BOOT_O" ]] || fail "build-kernel-arm.sh did not leave kmain_virt.o and boot-arm.o in core/build/"
ck; if ! strings "$KMAIN_O" | grep -q 'OSCORTEX A64 OK'; then
  fail "kmain_virt.o does not contain the A1 banner — the message is not coming from DCDart @rodata"
fi
ck; if strings "$BOOT_O" | grep -q 'OSCORTEX A64 OK'; then
  fail "boot-arm.o contains the A1 banner — A1 requires the bytes to come from DCDart, not .asciz"
fi

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh against the linked kernel
# ---------------------------------------------------------------------------
ck; if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH, see docs/known-gaps.md"
fi
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
ck; [[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" "$KERNEL_ELF"'
echo "$VERIFY_OUT"
ck; if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $KERNEL_ELF"
fi

# ---------------------------------------------------------------------------
# Step 3 — boot under QEMU. Exit 0 is required (PSCI SYSTEM_OFF).
# timeout's 124 is a hang, not the expected path — unlike m0-boot.
#
# Machine pin: virt-11.0 + gic-version=2 + cortex-a72 + TCG. arm64-port.md
# STEP 4: -M virt is a versioned alias; HVF is a tempting host-speed
# optimisation and is refused for goldens.
# ---------------------------------------------------------------------------
SERIAL_CAPTURE="$WORKDIR/serial.txt"
: >"$SERIAL_CAPTURE"

capture_log "$WORKDIR/qemu.log" QEMU_STATUS -- timeout 10 qemu-system-aarch64 \
    -M virt-11.0,gic-version=2 \
    -cpu cortex-a72 \
    -m 128M \
    -kernel "$KERNEL_ELF" \
    -serial "file:$SERIAL_CAPTURE" \
    -display none \
    -no-reboot

ck; if [[ $QEMU_STATUS -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- captured serial (hex) ---" >&2
  xxd "$SERIAL_CAPTURE" >&2 2>/dev/null || od -An -tx1 "$SERIAL_CAPTURE" >&2
  fail "qemu-system-aarch64 exited $QEMU_STATUS (want 0 from PSCI SYSTEM_OFF; 124 means the guest hung)"
fi

EXPECTED="$WORKDIR/expected.txt"
# 16 bytes, spelled from the design-doc criterion, not copied from m0-boot.
printf 'OSCORTEX A64 OK\n' >"$EXPECTED"
EXPECTED_BYTES=$(wc -c <"$EXPECTED" | tr -d ' ')
FIRST_LINE="$WORKDIR/first_line.txt"
head -c "$EXPECTED_BYTES" "$SERIAL_CAPTURE" >"$FIRST_LINE"

ck; if ! cmp -s "$FIRST_LINE" "$EXPECTED"; then
  echo "--- captured serial, first $EXPECTED_BYTES bytes (hex) ---" >&2
  xxd "$FIRST_LINE" >&2 2>/dev/null || od -An -tx1 "$FIRST_LINE" >&2
  echo "--- expected (hex) ---" >&2
  xxd "$EXPECTED" >&2 2>/dev/null || od -An -tx1 "$EXPECTED" >&2
  echo "--- full capture (hex) ---" >&2
  xxd "$SERIAL_CAPTURE" >&2 2>/dev/null || od -An -tx1 "$SERIAL_CAPTURE" >&2
  fail "the first $EXPECTED_BYTES captured serial bytes did not exactly match 'OSCORTEX A64 OK\\n'"
fi

require_assertions "$ASSERTIONS_REQUIRED"
echo "A1-boot: PASS — dcc --target bare-aarch64 -> assemble boot-arm.S -> link kernel-arm.elf -> verify-freestanding pass -> qemu-system-aarch64 -M virt-11.0 exit 0 -> exact serial byte match ('OSCORTEX A64 OK')"
exit 0
