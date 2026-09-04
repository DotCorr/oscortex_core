#!/usr/bin/env bash
# Platform-neutral DE verification. Runnable on Linux.
# Does not claim Mac cocoa/window-server sit-in coverage.
#
# Usage:
#   bash core/scripts/verify-de-neutral.sh
#   bash core/scripts/verify-de-neutral.sh --probe   # also run dcdart-compat
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
PIN_FILE="$REPO_DIR/DCDART_PIN.txt"
MANIFEST="$REPO_DIR/DCDART_MANIFEST.json"
COMPAT="$SCRIPT_DIR/verify-dcdart-compat.sh"
QMP_HELPER="$SCRIPT_DIR/de-qmp-evidence.py"
ART="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
mkdir -p "$ART"

PROBE=0
case "${1:-}" in
  ""|--check) ;;
  --probe) PROBE=1 ;;
  -h|--help)
    echo "usage: verify-de-neutral.sh [--check|--probe]"
    exit 0
    ;;
  *) echo "verify-de-neutral: FAIL — unknown option $1" >&2; exit 2 ;;
esac

fail() { echo "verify-de-neutral: FAIL — $*" >&2; exit 1; }

need=(
  "$PIN_FILE" "$MANIFEST" "$COMPAT" "$QMP_HELPER"
  "$CORE_DIR/scripts/build-kernel.sh"
  "$CORE_DIR/scripts/bootstrap-dcdart.sh"
  "$CORE_DIR/tests/conformance/m2-console/pick-port.py"
)
for p in "${need[@]}"; do
  [[ -f "$p" ]] || fail "required path missing: $p"
done

PIN="$(awk '{print $1; exit}' "$PIN_FILE")"
[[ "$PIN" == "df3d053+0001-volatile-compiler-used" ]] \
  || fail "pin $PIN is not the reachable base+patch identity"
grep -q '"base": "df3d05304531e0aadd315ec40d12f30fec6ee534"' "$MANIFEST" \
  || fail "manifest base is not public origin/main"
grep -q '"base_reachable": true' "$MANIFEST" || fail "manifest lost base_reachable"
grep -q '02631a77' "$MANIFEST" || fail "manifest must document unreachable legacy pin"
python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
  "$QMP_HELPER" || fail "QMP helper does not parse"
bash -n "$COMPAT" || fail "compat probe does not parse"
bash -n "$SCRIPT_DIR/bootstrap-dcdart.sh" || fail "bootstrap script does not parse"

HARNESS_NAMES=(
  de-pace de-wall de-desk de-deskboot de-retain de-chrome-cache
  de-wm de-resize d2-compositor de-session de-chrome de-osxui de-panel
  de-hold-menu de-txn-geom de-csd-hit dcdart-compat
)
found=0
absent=0
rows=""
for name in "${HARNESS_NAMES[@]}"; do
  run="$CORE_DIR/tests/conformance/$name/run.sh"
  if [[ -f "$run" ]]; then
    printf '  harness %-18s FOUND\n' "$name"
    found=$((found + 1))
    rows="${rows}    {\"name\":\"$name\",\"present\":true},\n"
  else
    printf '  harness %-18s absent\n' "$name"
    absent=$((absent + 1))
    rows="${rows}    {\"name\":\"$name\",\"present\":false},\n"
  fi
done

compat_status="not-run"
if [[ "$PROBE" == 1 ]]; then
  home="${DCDART_HOME:-}"
  if [[ -z "$home" || ! -f "$home/core/dcc/bin/dcc.dart" ]]; then
    eval "$(bash "$SCRIPT_DIR/bootstrap-dcdart.sh" | tail -n 1)"
    home="$DCDART_HOME"
  fi
  if bash "$COMPAT" "$home"; then
    compat_status="PASS"
  else
    fail "compat probe failed"
  fi
fi

echo "verify-de-neutral: pin $PIN"
echo "verify-de-neutral: harnesses found=$found absent=$absent"
echo "verify-de-neutral: cocoa/window-server NOT claimed (Linux-neutral only)"
echo "verify-de-neutral: CHECK PASS"

OUT="$ART/oscortex-round25-verify-de-neutral.json"
cat >"$OUT" <<EOF
{
  "round": 25,
  "platform": "$(uname -s)",
  "pin": "$PIN",
  "harnesses_found": $found,
  "harnesses_absent": $absent,
  "compat": "$compat_status",
  "mac_ui_claimed": false,
  "cocoa": false,
  "result": "PASS"
}
EOF
echo "verify-de-neutral: wrote $OUT"
exit 0
