#!/usr/bin/env bash
# Exact-tip R21/R22/R23 harnesses. Isolated BUILD_DIR. SKIP external tools.
set -u
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
mkdir -p "$ART"
OUT="$ART/oscortex-round23-harnesses.json"
export PATH="/opt/dart-sdk-3.12.2/bin:/tmp/oscortex-elf-tools:/usr/bin:/bin"
export DCDART_HOME="${DCDART_HOME:-/home/ubuntu/DCDart}"

pass=0
fail=0
skip=0
rows=()

run_one() {
  local name="$1" cmd="$2"
  echo "=== $name ==="
  if bash -c "$cmd"; then
    echo "PASS $name"
    rows+=("{\"name\":\"$name\",\"result\":\"PASS\"}")
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    rows+=("{\"name\":\"$name\",\"result\":\"FAIL\"}")
    fail=$((fail + 1))
  fi
}

skip_one() {
  local name="$1" why="$2"
  echo "SKIP $name — $why"
  rows+=("{\"name\":\"$name\",\"result\":\"SKIP\",\"why\":\"$why\"}")
  skip=$((skip + 1))
}

run_one de-txn-geom "bash '$CORE_DIR/tests/conformance/de-txn-geom/run.sh'"
run_one de-csd-hit "bash '$CORE_DIR/tests/conformance/de-csd-hit/run.sh'"
run_one de-geom "bash '$CORE_DIR/tests/conformance/de-geom/run.sh'"
run_one de-ident "bash '$CORE_DIR/tests/conformance/de-ident/run.sh'"
run_one de-corner-aa "bash '$CORE_DIR/tests/conformance/de-corner-aa/run.sh'"

if [[ -x "$(command -v qemu-system-x86_64)" ]]; then
  run_one de-desk "bash '$CORE_DIR/tests/conformance/de-desk/run.sh'"
else
  skip_one de-desk "qemu-system-x86_64 not on PATH"
fi

# Host-only / Mac / external GPU tools.
skip_one de-chrome-cache "needs live kernel.elf or long isolated QEMU; run separately if needed"
skip_one de-session "Mac/QEMU session harness; not this Linux tip gate"
skip_one verify-de-mac "Mac-only"

{
  echo "{"
  echo "  \"round\": 23,"
  echo "  \"pass\": $pass,"
  echo "  \"fail\": $fail,"
  echo "  \"skip\": $skip,"
  echo "  \"results\": ["
  i=0
  for r in "${rows[@]+"${rows[@]}"}"; do
    if [[ $i -gt 0 ]]; then echo ","; fi
    printf "    %s" "$r"
    i=$((i + 1))
  done
  echo
  echo "  ]"
  echo "}"
} >"$OUT"
echo "harnesses written $OUT pass=$pass fail=$fail skip=$skip"
[[ $fail -eq 0 ]]
