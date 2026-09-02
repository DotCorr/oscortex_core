#!/usr/bin/env bash
# core/scripts/build-kernel-arm.sh
#
# A1 aarch64 virt kernel: dcc --target bare-aarch64 (kmain_virt.dart) +
# clang on boot-arm/boot.S + ld.lld -T kernel-arm.ld -> build/kernel-arm.elf.
#
# Parallel to build-kernel.sh. Does NOT write build/kernel.elf and does
# NOT assemble or link any x86 object. Do not fold this into the x86
# script: arm64-port.md STEP 5 says parameterising every harness is a
# hot-file change that must land atomically, and this milestone is one
# rung, not that change.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart core/scripts/build-kernel-arm.sh
#   core/scripts/build-kernel-arm.sh   # default: ../DCDart sibling checkout
#
# Exit status: 0 on success, 1 on a build/assemble/link failure, 2 on
# harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() {
  echo "build-kernel-arm: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "build-kernel-arm: FAIL — $1" >&2
  exit 2
}

DCDART_HOME="${DCDART_HOME:-$REPO_DIR/../DCDart}"
[[ -d "$DCDART_HOME" ]] || setup_error "DCDART_HOME not found at $DCDART_HOME (set DCDART_HOME explicitly, or checkout DCDart as a sibling of $REPO_DIR)"
[[ -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]] || setup_error "$DCDART_HOME does not look like a DCDart checkout (missing core/dcc/bin/dcc.dart)"

command -v dart >/dev/null 2>&1 || setup_error "dart not found on PATH (source env.sh)"

# Same identity banner as build-kernel.sh (GAP-0242): where, which commit,
# dirty or not. A mismatch is a warning unless OSCORTEX_REQUIRE_PIN=1.
DCDART_DESC="(not a git checkout)"
DCDART_FULL=""
DCDART_DIRTY=""
if command -v git >/dev/null 2>&1 && git -C "$DCDART_HOME" rev-parse --git-dir >/dev/null 2>&1; then
  DCDART_DESC="$(git -C "$DCDART_HOME" rev-parse --short HEAD 2>/dev/null)"
  DCDART_FULL="$(git -C "$DCDART_HOME" rev-parse HEAD 2>/dev/null)"
  if [[ -n "$(git -C "$DCDART_HOME" status --porcelain 2>/dev/null)" ]]; then
    DCDART_DIRTY=" +DIRTY"
  fi
fi
PIN_FILE="$REPO_DIR/DCDART_PIN.txt"
PIN_WANT="(no DCDART_PIN.txt)"
[[ -f "$PIN_FILE" ]] && PIN_WANT="$(awk '{print $1; exit}' "$PIN_FILE")"
echo "build-kernel-arm: toolchain $DCDART_HOME @ ${DCDART_DESC}${DCDART_DIRTY}; DCDART_PIN.txt says $PIN_WANT"
if [[ -n "$DCDART_FULL" && "$DCDART_FULL" != "$PIN_WANT"* && "$PIN_WANT" != "(no DCDART_PIN.txt)" ]]; then
  echo "build-kernel-arm: WARNING — the toolchain is NOT the pinned commit." >&2
  [[ "${OSCORTEX_REQUIRE_PIN:-0}" == "1" ]] && setup_error "toolchain $DCDART_DESC != pinned $PIN_WANT (OSCORTEX_REQUIRE_PIN=1)"
fi
if [[ -n "$DCDART_DIRTY" ]]; then
  echo "build-kernel-arm: WARNING — the toolchain working tree is DIRTY." >&2
  [[ "${OSCORTEX_REQUIRE_PIN:-0}" == "1" ]] && setup_error "toolchain working tree is dirty (OSCORTEX_REQUIRE_PIN=1)"
fi

command -v clang >/dev/null 2>&1 || setup_error "clang not found on PATH"

# aarch64 ELF linker. The x86 build needs GNU ld for elf32-i386; this one
# does not. ld.lld is the documented sufficient linker (arm64-port.md STEP 3).
find_aarch64_linker() {
  if [[ -n "${LD:-}" ]]; then
    command -v "$LD" >/dev/null 2>&1 && { echo "$LD"; return 0; }
    return 1
  fi
  local candidate
  for candidate in ld.lld aarch64-elf-ld aarch64-linux-gnu-ld; do
    command -v "$candidate" >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  local brewed
  for brewed in /opt/homebrew/opt/lld/bin/ld.lld \
                /opt/homebrew/opt/aarch64-elf-binutils/bin/aarch64-elf-ld; do
    [[ -x "$brewed" ]] && { echo "$brewed"; return 0; }
  done
  return 1
}

LD_CMD="$(find_aarch64_linker)" || setup_error "no ELF linker found (need ld.lld). Set LD=<linker> to override."

BUILD_DIR="$CORE_DIR/build"
mkdir -p "$BUILD_DIR"

# ADR-0043: one spelling of the prelude. Same symlink the x86 script owns
# (`core/build/dcdart`). Sequential builds recreate it; do not run the two
# scripts in parallel against the same tree.
KERNEL_DIR="$(cd "$CORE_DIR/arch/aarch64" && pwd -P)"
LINK_DIR="$(cd "$CORE_DIR/build" && pwd -P)"
mkdir -p "$LINK_DIR"

DCDART_LINK="$LINK_DIR/dcdart"
if [[ -L "$DCDART_LINK" ]]; then
  rm -f "$DCDART_LINK"
elif [[ -e "$DCDART_LINK" ]]; then
  setup_error "$DCDART_LINK exists and is not a symlink — remove it (build-kernel-arm.sh owns that name for the duration of a build)"
fi
ln -s "$DCDART_HOME" "$DCDART_LINK" || setup_error "could not create toolchain symlink $DCDART_LINK -> $DCDART_HOME"

DCC_CMD=(dart "$DCDART_HOME/core/dcc/bin/dcc.dart")
PRELUDE_PATH="$DCDART_LINK/core/runtime/dc-core-bare/prelude.dart"
[[ -f "$PRELUDE_PATH" ]] || setup_error "no prelude at $PRELUDE_PATH (DCDART_HOME=$DCDART_HOME does not look like a DCDart checkout)"

EXPECTED_IMPORT="import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';"
if ! grep -qxF -- "$EXPECTED_IMPORT" "$CORE_DIR/arch/aarch64/kmain_virt.dart"; then
  setup_error "core/arch/aarch64/kmain_virt.dart does not import the prelude through core/build/dcdart.
              expected exactly: $EXPECTED_IMPORT
              found:            $(grep -n "dc-core-bare/prelude.dart'" "$CORE_DIR/arch/aarch64/kmain_virt.dart" | head -1)
              dcc matches annotation libraries by exact URI (ADR-0043)."
fi

echo "build-kernel-arm: prelude  $PRELUDE_PATH"
echo "build-kernel-arm: target   bare-aarch64"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare --target bare-aarch64
# ---------------------------------------------------------------------------
( cd "$KERNEL_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-aarch64 \
    --prelude "$PRELUDE_PATH" \
    kmain_virt.dart -o "$BUILD_DIR/kmain_virt.o" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare --target bare-aarch64 kmain_virt.dart' exited $DCC_STATUS"
fi
[[ -f "$BUILD_DIR/kmain_virt.o" ]] || fail "dcc reported success but kmain_virt.o was not produced"

# Verify, do not assume: the design doc claims dcc emits aarch64. A silent
# fallback to the default bare-x86_64 target would still produce an object
# and would fail later, more confusingly, at qemu-system-aarch64 -kernel.
KMAIN_FILE="$(file "$BUILD_DIR/kmain_virt.o")"
echo "build-kernel-arm: kmain_virt.o  $KMAIN_FILE"
case "$KMAIN_FILE" in
  *"ARM aarch64"*) ;;
  *) fail "dcc --target bare-aarch64 did not emit an aarch64 ELF (file said: $KMAIN_FILE)" ;;
esac

# ---------------------------------------------------------------------------
# Step 2 — assemble boot-arm/boot.S
# ---------------------------------------------------------------------------
clang -c --target=aarch64-unknown-none-elf -mno-red-zone \
    "$CORE_DIR/boot-arm/boot.S" -o "$BUILD_DIR/boot-arm.o"
ASM_STATUS=$?
if [[ $ASM_STATUS -ne 0 ]]; then
  fail "assembling boot-arm/boot.S exited $ASM_STATUS"
fi

# ---------------------------------------------------------------------------
# Step 3 — link via kernel-arm.ld  (ld.lld; output is NOT kernel.elf)
# ---------------------------------------------------------------------------
"$LD_CMD" -T "$CORE_DIR/link/kernel-arm.ld" -Map "$BUILD_DIR/kernel-arm.map" \
    -o "$BUILD_DIR/kernel-arm.elf" \
    "$BUILD_DIR/boot-arm.o" "$BUILD_DIR/kmain_virt.o"
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  fail "linking kernel-arm.elf with $LD_CMD exited $LINK_STATUS"
fi
[[ -f "$BUILD_DIR/kernel-arm.elf" ]] || fail "ld reported success but kernel-arm.elf was not produced"

ELF_FILE="$(file "$BUILD_DIR/kernel-arm.elf")"
echo "build-kernel-arm: kernel-arm.elf  $ELF_FILE"
case "$ELF_FILE" in
  *"ARM aarch64"*) ;;
  *) fail "linked image is not an aarch64 ELF (file said: $ELF_FILE)" ;;
esac

echo "build-kernel-arm: PASS — $BUILD_DIR/kernel-arm.elf"
exit 0
