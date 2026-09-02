#!/usr/bin/env bash
# One-command Darwin daily-drive verification for DE-001..015.
#
# Usage:
#   bash core/scripts/verify-de-mac.sh [--abs|--venus]
#   bash core/scripts/verify-de-mac.sh --check
#   bash core/scripts/verify-de-mac.sh --help
#
# The default --abs run leaves the QEMU cocoa/VNC door visible.  This script
# refuses to replace an existing sit-in door and only signals the QEMU PID it
# started if interrupted.  It never changes branches or resets a worktree.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
PIN_FILE="$REPO_DIR/DCDART_PIN.txt"
QMP_HELPER="$SCRIPT_DIR/de-qmp-evidence.py"
SITIN="$SCRIPT_DIR/sit-in-view.sh"
COMPAT_PROBE="$SCRIPT_DIR/verify-dcdart-compat.sh"

usage() {
  cat <<'EOF'
Usage: bash core/scripts/verify-de-mac.sh [--abs|--venus]

Runs the pinned DCDart/Skia kernel build, all available DE evidence harnesses,
then opens a visible sit-in session and records QMP screenshots before and
after pointer, menu, launch, drag, resize, and minimise interaction classes.
QEMU is intentionally left running for inspection.

Options:
  --abs       Visible QEMU cocoa absolute-pointer door (default).
  --venus     Visible Venus/TigerVNC door when its Docker prerequisites exist.
  --check     Linux-safe static path/discovery check; does not build or run QEMU.
  -h, --help  Show this help.

Environment:
  DE_ARTIFACTS_DIR  Exact output directory. Default:
                    core/build/de-verification/<UTC timestamp>
  DCDART_HOME       Explicit DCDart checkout. If unset, the runner searches
                    ~/Desktop/dc_sys/DCDart and nearby checkout spellings.

Safety:
  The runner refuses to start when a sit-in QEMU/container is already active.
  It never uses pkill itself, never resets/cleans the worktree, and only records
  build/log/screenshot output. On interruption it kills only the PID it started.
EOF
}

MODE=abs
CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --abs) MODE=abs ;;
  --venus) MODE=venus ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "verify-de-mac: FAIL — unknown option: $1" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "verify-de-mac: FAIL — too many arguments" >&2; exit 2; }

need_paths=(
  "$PIN_FILE"
  "$CORE_DIR/scripts/build-kernel.sh"
  "$COMPAT_PROBE"
  "$SITIN"
  "$QMP_HELPER"
  "$CORE_DIR/tests/conformance/m2-console/pick-port.py"
)
for path in "${need_paths[@]}"; do
  [[ -f "$path" ]] || { echo "verify-de-mac: FAIL — required path missing: $path" >&2; exit 2; }
done

HARNESS_NAMES=(
  de-pace de-wall de-desk de-deskboot de-retain de-chrome-cache
  de-wm de-resize d2-compositor de-session de-chrome de-osxui de-panel
)

if [[ "$CHECK_ONLY" == 1 ]]; then
  echo "verify-de-mac: static check (no build/QEMU)"
  echo "verify-de-mac: pin $(awk '{print $1; exit}' "$PIN_FILE")"
  for name in "${HARNESS_NAMES[@]}"; do
    run="$CORE_DIR/tests/conformance/$name/run.sh"
    if [[ -f "$run" ]]; then
      printf '  harness %-18s FOUND\n' "$name"
    else
      printf '  harness %-18s absent (runtime skip)\n' "$name"
    fi
  done
  python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
    "$QMP_HELPER" \
    || { echo "verify-de-mac: FAIL — QMP helper does not parse" >&2; exit 1; }
  bash -n "$COMPAT_PROBE" \
    || { echo "verify-de-mac: FAIL — DCDart compatibility probe does not parse" >&2; exit 1; }
  echo "verify-de-mac: CHECK PASS"
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "verify-de-mac: FAIL — runtime verification requires Darwin; use --check for Linux static validation" >&2
  exit 2
}

MAC_ENV="$HOME/Desktop/dc_sys/env.sh"
if [[ -f "$MAC_ENV" ]]; then
  echo "verify-de-mac: sourcing $MAC_ENV"
  # shellcheck disable=SC1090
  source "$MAC_ENV"
else
  echo "verify-de-mac: note — $MAC_ENV is absent; using the current environment"
fi

PIN_WANT="$(awk '{print $1; exit}' "$PIN_FILE")"
[[ "$PIN_WANT" =~ ^[0-9a-fA-F]{7,40}$ ]] || {
  echo "verify-de-mac: FAIL — invalid pin in $PIN_FILE: $PIN_WANT" >&2
  exit 2
}

find_dcdart() {
  local candidate full compatible=""
  if [[ -n "${DCDART_HOME:-}" ]]; then
    candidate="$DCDART_HOME"
    [[ -d "$candidate" ]] || {
      echo "verify-de-mac: FAIL — explicit DCDART_HOME does not exist: $candidate" >&2
      return 1
    }
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    "$HOME/Desktop/dc_sys/DCDart" \
    "$HOME/Desktop/dc_sys/dcdart" \
    "$REPO_DIR/../DCDart" \
    "$REPO_DIR/../dcdart"
  do
    [[ -d "$candidate" ]] || continue
    full="$(git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$full" && "$full" == "$PIN_WANT"* &&
          -z "$(git -C "$candidate" status --porcelain 2>/dev/null)" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    echo "verify-de-mac: probing candidate $candidate @ ${full:-not-git}" >&2
    if bash "$COMPAT_PROBE" "$candidate" >&2; then
      [[ -n "$compatible" ]] || compatible="$candidate"
    else
      echo "verify-de-mac: rejected incompatible candidate $candidate" >&2
    fi
  done
  if [[ -n "$compatible" ]]; then
    printf '%s\n' "$compatible"
    return 0
  fi
  echo "verify-de-mac: FAIL — no exact or probe-compatible DCDart checkout was found" >&2
  echo "               set DCDART_HOME to a checkout with Volatile/@rodata/no-FP support" >&2
  return 1
}

DCDART_HOME="$(find_dcdart)" || exit 2
export DCDART_HOME
export OSGFX_SKIA=1
export OSCORTEX_REQUIRE_PIN=1

[[ -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]] || {
  echo "verify-de-mac: FAIL — $DCDART_HOME is not a DCDart checkout (dcc.dart missing)" >&2
  exit 2
}
DCDART_FULL="$(git -C "$DCDART_HOME" rev-parse HEAD 2>/dev/null || true)"
DCDART_SHORT="$(git -C "$DCDART_HOME" rev-parse --short HEAD 2>/dev/null || true)"
echo "verify-de-mac: DCDART_HOME=$DCDART_HOME"
echo "verify-de-mac: toolchain=${DCDART_FULL:-not-a-git-checkout}"
echo "verify-de-mac: required-pin=$PIN_WANT"
if [[ -z "$DCDART_FULL" || "$DCDART_FULL" != "$PIN_WANT"* ||
      -n "$(git -C "$DCDART_HOME" status --porcelain 2>/dev/null)" ]]; then
  echo "verify-de-mac: exact clean pin unavailable; running semantic compiler probe"
  bash "$COMPAT_PROBE" "$DCDART_HOME" || {
    echo "verify-de-mac: FAIL — toolchain is neither an exact clean pin nor probe-compatible" >&2
    exit 2
  }
fi

for tool in bash python3 git clang qemu-system-x86_64; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "verify-de-mac: FAIL — required tool not found after env.sh: $tool" >&2
    exit 2
  }
done
if [[ "$MODE" == venus ]]; then
  command -v docker >/dev/null 2>&1 || {
    echo "verify-de-mac: FAIL — --venus requires docker" >&2
    exit 2
  }
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACTS="${DE_ARTIFACTS_DIR:-$CORE_DIR/build/de-verification/$STAMP}"
mkdir -p "$ARTIFACTS/logs" "$ARTIFACTS/screenshots" || {
  echo "verify-de-mac: FAIL — cannot create artifacts directory: $ARTIFACTS" >&2
  exit 2
}
ARTIFACTS="$(cd "$ARTIFACTS" && pwd -P)"
RESULTS="$ARTIFACTS/results.tsv"
printf 'kind\tname\tstatus\texit\tlog\n' >"$RESULTS"
printf 'repo=%s\ncommit=%s\npin=%s\ntoolchain=%s\nmode=%s\n' \
  "$REPO_DIR" "$(git -C "$REPO_DIR" rev-parse HEAD)" "$PIN_WANT" \
  "$DCDART_FULL" "$MODE" >"$ARTIFACTS/run-info.txt"

PASS_N=0
FAIL_N=0
SKIP_N=0
record() {
  local kind="$1" name="$2" status="$3" rc="$4" log="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$status" "$rc" "$log" >>"$RESULTS"
  case "$status" in
    PASS) PASS_N=$((PASS_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)) ;;
    SKIP) SKIP_N=$((SKIP_N + 1)) ;;
  esac
}

run_logged() {
  local kind="$1" name="$2"; shift 2
  local log="$ARTIFACTS/logs/${name}.log" rc
  echo
  echo "=== $kind: $name ==="
  "$@" > >(tee "$log") 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    record "$kind" "$name" PASS 0 "$log"
    echo "verify-de-mac: PASS $name"
  else
    record "$kind" "$name" FAIL "$rc" "$log"
    echo "verify-de-mac: FAIL $name (exit $rc; continuing)" >&2
  fi
  return 0
}

run_logged build kernel-initial env OSGFX_SKIA=1 OSCORTEX_REQUIRE_PIN=1 \
  bash "$CORE_DIR/scripts/build-kernel.sh"

for name in "${HARNESS_NAMES[@]}"; do
  run="$CORE_DIR/tests/conformance/$name/run.sh"
  if [[ -f "$run" ]]; then
    run_logged harness "$name" env OSCORTEX_REQUIRE_PIN=1 bash "$run"
  else
    record harness "$name" SKIP 0 "not present"
  fi
done

# Several policy harnesses deliberately produce a no-Skia kernel. Rebuild the
# exact visible image after the whole sweep, even when an earlier harness failed.
run_logged build kernel-final-skia env OSGFX_SKIA=1 OSCORTEX_REQUIRE_PIN=1 \
  bash "$CORE_DIR/scripts/build-kernel.sh"

FINAL_BUILD="$(awk -F '\t' '$1=="build" && $2=="kernel-final-skia" {print $3}' "$RESULTS")"
if [[ "$FINAL_BUILD" != PASS ]]; then
  echo "verify-de-mac: visible session skipped because the final Skia build failed" >&2
  record runtime sit-in SKIP 0 "final Skia build failed"
else
  RUN_PIDFILE="$CORE_DIR/build/sit-in-view/qemu.pid"
  if [[ -f "$RUN_PIDFILE" ]] && kill -0 "$(cat "$RUN_PIDFILE" 2>/dev/null)" 2>/dev/null; then
    echo "verify-de-mac: FAIL — an existing sit-in QEMU is active (PID $(cat "$RUN_PIDFILE"))" >&2
    echo "               close it explicitly before rerunning; this runner will not kill it" >&2
    record runtime sit-in FAIL 2 "pre-existing sit-in QEMU"
  elif pgrep -f '[o]scortex-abs-pointer' >/dev/null 2>&1; then
    echo "verify-de-mac: FAIL — an oscortex-abs-pointer QEMU already exists; refusing to replace it" >&2
    record runtime sit-in FAIL 2 "pre-existing abs-pointer QEMU"
  elif [[ "$MODE" == venus ]] && pgrep -f '[o]scortex-sit-in-view' >/dev/null 2>&1; then
    echo "verify-de-mac: FAIL — an existing local sit-in QEMU exists; refusing to replace it" >&2
    record runtime sit-in FAIL 2 "pre-existing local sit-in QEMU"
  elif [[ "$MODE" == venus ]] && pgrep -x vncviewer >/dev/null 2>&1; then
    echo "verify-de-mac: FAIL — an existing VNC viewer exists; refusing to replace it" >&2
    record runtime sit-in FAIL 2 "pre-existing VNC viewer"
  elif [[ "$MODE" == venus ]] && docker ps -a --format '{{.Names}}' 2>/dev/null \
      | grep -qE '^oscortex-(interactive-door($|-boot-)|venus-view$|tiger-view$|venus-graphite$)'; then
    echo "verify-de-mac: FAIL — an existing Venus sit-in container exists; refusing to replace it" >&2
    record runtime sit-in FAIL 2 "pre-existing Venus container"
  else
    SITIN_ARG="--abs"
    [[ "$MODE" == venus ]] && SITIN_ARG="--venus"
    SITIN_LOG="$ARTIFACTS/logs/sit-in.log"
    echo
    echo "=== runtime: sit-in-view $SITIN_ARG ==="
    SITIN_SKIP_BUILD=1 OSCORTEX_REQUIRE_PIN=1 bash "$SITIN" "$SITIN_ARG" \
      > >(tee "$SITIN_LOG") 2>&1
    SITIN_RC=$?
    if [[ $SITIN_RC -ne 0 ]]; then
      record runtime sit-in FAIL "$SITIN_RC" "$SITIN_LOG"
    else
      record runtime sit-in PASS 0 "$SITIN_LOG"
      OWN_QEMU_PID=""
      if [[ "$MODE" == abs && -f "$RUN_PIDFILE" ]]; then
        OWN_QEMU_PID="$(tr -d '[:space:]' <"$RUN_PIDFILE")"
      fi
      on_signal() {
        echo "verify-de-mac: interrupted"
        if [[ -n "$OWN_QEMU_PID" ]] && kill -0 "$OWN_QEMU_PID" 2>/dev/null; then
          echo "verify-de-mac: stopping only owned QEMU PID $OWN_QEMU_PID"
          kill "$OWN_QEMU_PID" 2>/dev/null || true
        fi
        exit 130
      }
      trap on_signal INT TERM HUP

      if [[ "$MODE" == venus ]]; then
        QMP_PORT_FILE="$CORE_DIR/build/sit-in-view-venus/qmp.port"
        SERIAL="$CORE_DIR/build/sit-in-view-venus/serial.txt"
        SCREEN_W=1280
        SCREEN_H=720
      else
        QMP_PORT_FILE="$CORE_DIR/build/sit-in-view/qmp.port"
        SERIAL="$CORE_DIR/build/sit-in-view-serial.txt"
        SCREEN_W=800
        SCREEN_H=600
      fi
      if [[ ! -s "$QMP_PORT_FILE" ]]; then
        record interaction qmp-evidence FAIL 2 "missing $QMP_PORT_FILE"
      else
        QMP_PORT="$(tr -d '[:space:]' <"$QMP_PORT_FILE")"
        QMP_LOG="$ARTIFACTS/logs/qmp-evidence.log"
        python3 "$QMP_HELPER" --port "$QMP_PORT" --serial "$SERIAL" \
          --width "$SCREEN_W" --height "$SCREEN_H" \
          --output "$ARTIFACTS/screenshots" --results "$ARTIFACTS/interactions.tsv" \
          > >(tee "$QMP_LOG") 2>&1
        QMP_RC=$?
        if [[ $QMP_RC -eq 0 ]]; then
          record interaction qmp-evidence PASS 0 "$QMP_LOG"
        else
          record interaction qmp-evidence FAIL "$QMP_RC" "$QMP_LOG"
        fi
      fi
    fi
  fi
fi

{
  echo "DE verification artifacts"
  echo "commit: $(git -C "$REPO_DIR" rev-parse HEAD)"
  echo "toolchain: $DCDART_FULL (pin $PIN_WANT)"
  echo "PASS=$PASS_N FAIL=$FAIL_N SKIP=$SKIP_N"
  echo "QEMU is intentionally left running when runtime launch succeeded."
  echo "See: $RESULTS"
  echo "Checklist: $CORE_DIR/docs/de-001-015-verification-checklist.md"
} | tee "$ARTIFACTS/SUMMARY.txt"

echo
echo "verify-de-mac: artifacts $ARTIFACTS"
echo "verify-de-mac: PASS=$PASS_N FAIL=$FAIL_N SKIP=$SKIP_N"
if [[ -n "${OWN_QEMU_PID:-}" ]]; then
  echo "verify-de-mac: visible QEMU left running (owned PID $OWN_QEMU_PID)"
fi
[[ "$FAIL_N" -eq 0 ]]
