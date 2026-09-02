#!/usr/bin/env bash
# core/tests/conformance/_lib/sweep.sh
#
# Run conformance harnesses one at a time and print a PASS/FAIL table.
#
# SEQUENTIAL ON PURPOSE. Every harness rebuilds into the SHARED core/build,
# and several of them build with different flags (OSGFX_SKIA=0,
# OSMEDIA_FFMPEG=0). Two harnesses in flight at once overwrite each other's
# .o files between compile and link -- observed as
# `undefined reference to osmedia_trace`, which is osmedia_guest.o compiled
# -DOSMEDIA_NO_FFMPEG_LINK by one run and linked against osmedia.o by
# another. build-kernel.sh already makes the LINK atomic; the object files
# are not, so do not parallelise this.
#
# Usage:
#   bash core/tests/conformance/_lib/sweep.sh [-o OUTDIR] [-t SECS] [name...]
#
# With no names, every directory under core/tests/conformance/ that has a
# run.sh is run, in alphabetical order. Per-harness logs land in OUTDIR.
#
# Exit: 0 if every harness passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTDIR=""
TIMEOUT=1800
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTDIR="$2"; shift 2 ;;
    -t) TIMEOUT="$2"; shift 2 ;;
    *) break ;;
  esac
done
[[ -n "$OUTDIR" ]] || OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-sweep.XXXXXX")"
mkdir -p "$OUTDIR" || { echo "sweep: cannot create $OUTDIR" >&2; exit 2; }

NAMES=()
if [[ $# -gt 0 ]]; then
  NAMES=("$@")
else
  while IFS= read -r d; do
    NAMES+=("$(basename "$(dirname "$d")")")
  done < <(find "$CONF_DIR" -mindepth 2 -maxdepth 2 -name run.sh | sort)
fi

echo "sweep: $((${#NAMES[@]})) harness(es), logs in $OUTDIR"
START_ALL=$(date +%s)
PASSED=0
FAILED=0
RESULTS="$OUTDIR/results.tsv"
: >"$RESULTS"

for name in ${NAMES[@]+"${NAMES[@]}"}; do
  RUN="$CONF_DIR/$name/run.sh"
  if [[ ! -f "$RUN" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$name" "MISSING" "0" "no run.sh" >>"$RESULTS"
    FAILED=$(( FAILED + 1 ))
    printf '%-16s MISSING\n' "$name"
    continue
  fi
  LOG="$OUTDIR/$name.log"
  START=$(date +%s)
  timeout "$TIMEOUT" bash "$RUN" >"$LOG" 2>&1
  STATUS=$?
  ELAPSED=$(( $(date +%s) - START ))
  # The harnesses' own verdict line, which is the thing to quote.
  VERDICT=$(grep -aE '^[A-Za-z0-9_-]+: (PASS|FAIL)' "$LOG" | tail -1)
  [[ -n "$VERDICT" ]] || VERDICT=$(tail -1 "$LOG")
  if [[ $STATUS -eq 0 ]]; then
    STATE=PASS
    PASSED=$(( PASSED + 1 ))
  elif [[ $STATUS -eq 124 ]]; then
    STATE=TIMEOUT
    FAILED=$(( FAILED + 1 ))
  else
    STATE=FAIL
    FAILED=$(( FAILED + 1 ))
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$STATE" "$ELAPSED" "$VERDICT" >>"$RESULTS"
  printf '%-16s %-7s %5ds  %s\n' "$name" "$STATE" "$ELAPSED" "${VERDICT:0:120}"
done

echo
echo "sweep: $PASSED passed, $FAILED failed, $(( $(date +%s) - START_ALL ))s total"
echo "sweep: results $RESULTS"
[[ $FAILED -eq 0 ]]
