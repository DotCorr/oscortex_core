#!/usr/bin/env bash
# verify-freestanding.sh — copied as-is from the DCDart repo
# (core/scripts/verify-freestanding.sh), same spine-check discipline.
#
# Every kernel object file must link with no runtime. This script is the
# mechanical guarantee of that. A green test suite with a leaked runtime
# symbol is a FAILED change. Run it on every boot/kernel change.
#
# Usage: core/scripts/verify-freestanding.sh build/kernel.o [more.o ...]

set -euo pipefail

ALLOWLIST="${OSCORTEX_ALLOWLIST:-tools/bare-symbol-allowlist.txt}"
NM="${NM:-llvm-nm}"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <objfile> [objfile ...]" >&2
  exit 2
fi

if [[ ! -f "$ALLOWLIST" ]]; then
  echo "FATAL: allowlist not found at $ALLOWLIST" >&2
  echo "Do not create one to make this pass without a real reason recorded in known-gaps.md." >&2
  exit 2
fi

# Strip comments and blanks from the allowlist.
mapfile -t ALLOWED < <(grep -vE '^\s*(#|$)' "$ALLOWLIST" | sed 's/\s*$//')

fail=0

for obj in "$@"; do
  [[ -f "$obj" ]] || { echo "FATAL: no such object: $obj" >&2; exit 2; }

  # Undefined symbols only.
  mapfile -t undef < <("$NM" -u --format=posix "$obj" 2>/dev/null | awk '{print $1}' | sed 's/^_//')

  leaked=()
  for sym in "${undef[@]}"; do
    [[ -z "$sym" ]] && continue
    ok=0
    for a in "${ALLOWED[@]}"; do
      # Allowlist entries may be exact names or shell globs (e.g. __aeabi_*).
      # shellcheck disable=SC2053
      if [[ "$sym" == $a ]]; then ok=1; break; fi
    done
    (( ok )) || leaked+=("$sym")
  done

  if (( ${#leaked[@]} )); then
    fail=1
    echo "FREESTANDING: FAIL  $obj"
    for sym in "${leaked[@]}"; do
      case "$sym" in
        dc_alloc|dc_free|dc_realloc)
          echo "  $sym  -> implicit allocation from DCDart's ARC runtime." ;;
        dc_throw|dc_unwind|__gxx_personality*)
          echo "  $sym  -> a throw reached @bare code." ;;
        dart_*|Dart_*)
          echo "  $sym  -> old Dart VM runtime symbol. This is a DCDart backend bug, not an oscortex_core one -- file it against the DCDart repo." ;;
        *)
          echo "  $sym  -> undefined and not allowlisted." ;;
      esac
    done
    echo "  Do NOT add to the allowlist to make this pass without a real, recorded reason."
  else
    echo "FREESTANDING: pass  $obj"
  fi
done

exit $fail
