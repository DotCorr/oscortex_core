#!/usr/bin/env bash
# Round 38 isolated harness cluster. Does not touch the leftover QEMU.
set -u
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
mkdir -p "$ART"
OUT="$ART/oscortex-round38-harnesses.json"
export PATH="/opt/dart-sdk-3.12.2/bin:/tmp/oscortex-elf-tools:/usr/bin:/bin"

if [[ -z "${DCDART_HOME:-}" || ! -f "${DCDART_HOME:-}/core/dcc/bin/dcc.dart" ]]; then
  eval "$(bash "$CORE_DIR/scripts/bootstrap-dcdart.sh" | tail -n 1)"
fi
export DCDART_HOME
unset BUILD_DIR
unset KERNEL_UEFI
unset DRIVE_GIT_SHA

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

run_one dcdart-compat "bash '$CORE_DIR/tests/conformance/dcdart-compat/run.sh'"
run_one verify-de-neutral "bash '$CORE_DIR/scripts/verify-de-neutral.sh' --probe"
run_one de-hold-menu "bash '$CORE_DIR/tests/conformance/de-hold-menu/run.sh'"
run_one de-txn-geom "bash '$CORE_DIR/tests/conformance/de-txn-geom/run.sh'"
run_one de-pace "bash '$CORE_DIR/tests/conformance/de-pace/run.sh'"
run_one de-csd-hit "bash '$CORE_DIR/tests/conformance/de-csd-hit/run.sh'"
run_one de-geom "bash '$CORE_DIR/tests/conformance/de-geom/run.sh'"
run_one de-ident "bash '$CORE_DIR/tests/conformance/de-ident/run.sh'"
run_one de-corner-aa "bash '$CORE_DIR/tests/conformance/de-corner-aa/run.sh'"
run_one m5-pci "bash '$CORE_DIR/tests/conformance/m5-pci/run.sh'"
run_one m11-proc "bash '$CORE_DIR/tests/conformance/m11-proc/run.sh'"
run_one m21-shmem "bash '$CORE_DIR/tests/conformance/m21-shmem/run.sh'"
run_one files-fm "bash '$CORE_DIR/tests/conformance/files-fm/run.sh'"
run_one files-mkdir "bash '$CORE_DIR/tests/conformance/files-mkdir/run.sh'"
run_one d1-mouse "bash '$CORE_DIR/tests/conformance/d1-mouse/run.sh'"
run_one d2-compositor "bash '$CORE_DIR/tests/conformance/d2-compositor/run.sh'"
run_one d7-click "bash '$CORE_DIR/tests/conformance/d7-click/run.sh'"
run_one d8-title "bash '$CORE_DIR/tests/conformance/d8-title/run.sh'"
run_one d9-focus "bash '$CORE_DIR/tests/conformance/d9-focus/run.sh'"
run_one osxui1-pop "bash '$CORE_DIR/tests/conformance/osxui1-pop/run.sh'"
run_one g7-virtgpu "bash '$CORE_DIR/tests/conformance/g7-virtgpu/run.sh'"
run_one wm-clip "bash '$CORE_DIR/tests/conformance/wm-clip/run.sh'"

if [[ "$(uname -s)" == "Darwin" ]]; then
  run_one verify-de-mac "bash '$CORE_DIR/scripts/verify-de-mac.sh'"
else
  skip_one verify-de-mac "Mac cocoa/window-server only; neutral checks ran as verify-de-neutral"
fi

{
  echo "{"
  echo "  \"round\": 37,"
  echo "  \"pass\": $pass,"
  echo "  \"fail\": $fail,"
  echo "  \"skip\": $skip,"
  echo "  \"dcdart_home\": \"$DCDART_HOME\","
  echo "  \"build_dir_leaked\": false,"
  echo "  \"results\": ["
  i=0
  for r in "${rows[@]}"; do
    if [[ $i -gt 0 ]]; then echo ","; fi
    echo -n "    $r"
    i=$((i + 1))
  done
  echo
  echo "  ]"
  echo "}"
} > "$OUT"
echo "wrote $OUT pass=$pass fail=$fail skip=$skip"
[[ "$fail" -eq 0 ]]
