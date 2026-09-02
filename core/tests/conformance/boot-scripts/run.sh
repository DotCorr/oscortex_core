#!/usr/bin/env bash
# Structural regressions for source/tool paths needed before QEMU can boot.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "BOOT-SCRIPTS: FAIL — $1" >&2; exit 1; }

HOST="$CORE_DIR/scripts/build-skia-graphite.sh"
CPU="$CORE_DIR/scripts/build-skia-guest.sh"
GPU="$CORE_DIR/scripts/build-skia-guest-graphite.sh"

for script in "$HOST" "$CPU" "$GPU"; do
  bash -n "$script" || fail "$(basename "$script") does not parse"
done

grep -q '( cd "$SRC" && "$SRC/bin/gn" gen "$OUT"' "$HOST" \
  || fail "host Graphite invokes GN outside the Skia source root"
grep -q 'SKIA_FETCH_ONLY' "$HOST" \
  || fail "Skia fetch helper has no source-only mode"
grep -q 'SKIA_FETCH_ONLY=1 bash "$CORE/scripts/build-skia-graphite.sh"' "$CPU" \
  || fail "CPU guest build unnecessarily runs the Mac host build while fetching"
grep -q 'SKIA_FETCH_ONLY=1 bash "$CORE/scripts/build-skia-graphite.sh"' "$GPU" \
  || fail "Graphite guest build unnecessarily runs the Mac host build while fetching"

echo "BOOT-SCRIPTS: PASS — GN runs at the source root; guest fetch does not build the Mac host archive"
