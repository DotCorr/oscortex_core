#!/usr/bin/env bash
# core/scripts/build-kernel.sh
#
# dcc build (kmain.dart) + assemble (boot.S) + link (kernel.ld) ->
# build/kernel.elf. Mirrors DCDart's own conformance harnesses' PATH-
# then-fallback pattern for finding dcc.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart core/scripts/build-kernel.sh   # explicit
#   core/scripts/build-kernel.sh                                # default: ../DCDart sibling checkout
#
# Exit status: 0 on success, 1 on a build/assemble/link failure, 2 on
# harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() {
  echo "build-kernel: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "build-kernel: FAIL — $1" >&2
  exit 2
}

DCDART_HOME="${DCDART_HOME:-$REPO_DIR/../DCDart}"
[[ -d "$DCDART_HOME" ]] || setup_error "DCDART_HOME not found at $DCDART_HOME (set DCDART_HOME explicitly, or checkout DCDart as a sibling of $REPO_DIR — see core/README.md)"
[[ -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]] || setup_error "$DCDART_HOME does not look like a DCDart checkout (missing core/dcc/bin/dcc.dart)"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$DCDART_HOME/core/dcc/bin/dcc.dart")
else
  setup_error "neither dcc nor dart found on PATH"
fi

if ! command -v clang >/dev/null 2>&1; then
  setup_error "clang not found on PATH"
fi
if ! command -v ld >/dev/null 2>&1; then
  setup_error "ld not found on PATH"
fi

BUILD_DIR="$CORE_DIR/build"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare kmain.dart -o build/kmain.o
# ---------------------------------------------------------------------------
( cd "$CORE_DIR/kernel" && "${DCC_CMD[@]}" build --mode bare kmain.dart -o "$BUILD_DIR/kmain.o" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare kmain.dart -o kmain.o' exited $DCC_STATUS"
fi
[[ -f "$BUILD_DIR/kmain.o" ]] || fail "dcc reported success but kmain.o was not produced"

# ---------------------------------------------------------------------------
# Step 2 — assemble boot.S
# ---------------------------------------------------------------------------
clang -c -target x86_64-unknown-none-elf "$CORE_DIR/boot/boot.S" -o "$BUILD_DIR/boot.o"
ASM_STATUS=$?
if [[ $ASM_STATUS -ne 0 ]]; then
  fail "assembling boot.S exited $ASM_STATUS"
fi

# ---------------------------------------------------------------------------
# Step 3 — link via kernel.ld
# ---------------------------------------------------------------------------
ld -T "$CORE_DIR/link/kernel.ld" -o "$BUILD_DIR/kernel.elf" "$BUILD_DIR/boot.o" "$BUILD_DIR/kmain.o"
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  fail "linking kernel.elf exited $LINK_STATUS"
fi
[[ -f "$BUILD_DIR/kernel.elf" ]] || fail "ld reported success but kernel.elf was not produced"

echo "build-kernel: PASS — $BUILD_DIR/kernel.elf"
exit 0
