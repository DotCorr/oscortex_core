#!/usr/bin/env bash
# Locate a Limine install for the UEFI/GOP HD route.
#
# Prefers Limine 12+ (repo limine.conf uses `path:`). PATH often has
# Limine 8, which panics `KERNEL_PATH not specified` on that file.
# Standalone Limine 12 builds have no --print-datadir; the files sit
# next to the `limine` binary.
#
# Usage: eval "$(bash find-limine.sh)"
# Exports: LIMINE, LIMINE_DATADIR, LIMINE_MAJOR, LIMINE_VERSION

set -uo pipefail

is_limine12() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  "$bin" --version 2>/dev/null | grep -qE 'Limine 1[2-9]'
}

probe() {
  local bin="$1"
  local dir
  [[ -x "$bin" ]] || return 1
  dir="$(cd "$(dirname "$bin")" && pwd -P)"
  if [[ -f "$dir/BOOTX64.EFI" && -f "$dir/limine-uefi-cd.bin" &&
        -f "$dir/limine-bios-cd.bin" && -f "$dir/limine-bios.sys" ]]; then
    echo "$bin" "$dir"
    return 0
  fi
  local dd
  dd="$("$bin" --print-datadir 2>/dev/null || true)"
  if [[ -n "$dd" && -f "$dd/BOOTX64.EFI" && -f "$dd/limine-uefi-cd.bin" ]]; then
    echo "$bin" "$dd"
    return 0
  fi
  return 1
}

CANDIDATES=(
  "${LIMINE:-}"
  /opt/cursor/limine-binary/limine-binary/limine
  "${LIMINE_DATADIR:-}/limine"
  /usr/local/bin/limine
  /opt/homebrew/bin/limine
)

if command -v limine >/dev/null 2>&1; then
  CANDIDATES+=("$(command -v limine)")
fi

PICK_BIN=""
PICK_DIR=""
FALLBACK_BIN=""
FALLBACK_DIR=""

for c in "${CANDIDATES[@]}"; do
  [[ -n "$c" ]] || continue
  got="$(probe "$c" || true)"
  [[ -n "$got" ]] || continue
  bin="${got%% *}"
  dir="${got#* }"
  if is_limine12 "$bin"; then
    PICK_BIN="$bin"
    PICK_DIR="$dir"
    break
  fi
  if [[ -z "$FALLBACK_BIN" ]]; then
    FALLBACK_BIN="$bin"
    FALLBACK_DIR="$dir"
  fi
done

if [[ -z "$PICK_BIN" ]]; then
  PICK_BIN="$FALLBACK_BIN"
  PICK_DIR="$FALLBACK_DIR"
fi

if [[ -z "$PICK_BIN" ]]; then
  echo "find-limine: FAIL — no Limine with BOOTX64.EFI" >&2
  exit 2
fi

VER="$("$PICK_BIN" --version 2>/dev/null | head -1 || true)"
MAJOR="$(printf '%s\n' "$VER" | sed -n 's/.*Limine \([0-9][0-9]*\).*/\1/p')"
[[ -n "$MAJOR" ]] || MAJOR=0

printf 'export LIMINE=%q\n' "$PICK_BIN"
printf 'export LIMINE_DATADIR=%q\n' "$PICK_DIR"
printf 'export LIMINE_MAJOR=%q\n' "$MAJOR"
printf 'export LIMINE_VERSION=%q\n' "$VER"
