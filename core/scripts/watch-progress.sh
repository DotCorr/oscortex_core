#!/usr/bin/env bash
# Live TTY dashboard + canvas snapshot. Does not start work or re-run suites.
#   bash core/scripts/watch-progress.sh            # refresh every 2s (Ctrl-C to stop)
#   bash core/scripts/watch-progress.sh --once     # one collect, write JSON, print, exit
# Writes core/build/progress.json each tick and patches owner-progress.canvas.tsx.
# INTERVAL=N to change period. Companion canvas: reopen/reload after a tick.
# Scrapes: ADRs, harness run.sh + leftover PASS/FAIL logs, nm kernel.elf
# (osgfx_fill_rrect / SkCanvas / oschrome / osmedia), shmMax, wm de, sit-in FAT,
# leftover-named files, preview-ui.sh, osgfx_guest_* hookup, withdrawn ADRs,
# workaround vs real (osgfx_sw / GET_CAPSET / host-only plat).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$SCRIPT_DIR/progress-status.py"
INTERVAL="${INTERVAL:-2}"

if [[ ! -f "$PY" ]]; then
  echo "watch-progress: missing $PY" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "watch-progress: python3 required" >&2; exit 2; }
mkdir -p "$CORE/build"

if [[ "${1:-}" == "--once" ]]; then
  exec python3 "$PY"
fi

trap 'printf "\nwatch-progress: stopped (JSON left at %s/build/progress.json)\n" "$CORE"; exit 0' INT TERM

while true; do
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
  python3 "$PY" || true
  sleep "$INTERVAL"
done
