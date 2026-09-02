#!/usr/bin/env bash
# core/tests/conformance/_lib/controls/run.sh
#
# NEGATIVE CONTROLS FOR _lib/harness.sh (GAP-0168, ADR-0032).
#
# A guard that has only ever been observed passing is indistinguishable from a
# guard that cannot fail. This file exists so that the assertion-count floor
# and the capture() helpers are shown FAILING on the inputs they are meant to
# reject, not merely shown green on inputs that were already fine.
#
# It is the same discipline as ADR-0028's three freestanding controls, and it
# is deliberately CHEAP -- no QEMU, no kernel build, ~1 second -- so it can be
# run on every edit to _lib/harness.sh instead of once a unit.
#
# RUN IT UNDER BOTH INTERPRETERS. `env bash` is brew's bash 5; `/bin/bash` on
# macOS is 3.2.57, and the library claims to work under both:
#
#   bash core/tests/conformance/_lib/controls/run.sh
#   /bin/bash core/tests/conformance/_lib/controls/run.sh
#
# Exit status: 0 if every control behaved as specified, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../harness.sh"
[[ -f "$LIB" ]] || { echo "CONTROLS: FAIL — no harness.sh at $LIB" >&2; exit 2; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-harness-controls.XXXXXX")" || exit 2
trap 'rm -rf "$WORKDIR"' EXIT

BASH_ID="$("$BASH" --version 2>/dev/null | head -1)"
echo "CONTROLS: interpreter — ${BASH_ID:-unknown} (\$BASH=$BASH)"
echo

CONTROLS_RUN=0
CONTROLS_BAD=0

# expect <name> <expected-status> <must-contain-or-empty> <fixture-file>
#
# Runs the fixture with the SAME interpreter this control script is running
# under -- not `bash` off PATH -- so that "/bin/bash controls/run.sh" really
# does exercise bash 3.2 all the way down.
expect() {
  local name="$1" want_status="$2" want_text="$3" fixture="$4"
  local out status
  CONTROLS_RUN=$(( CONTROLS_RUN + 1 ))
  out="$("$BASH" "$fixture" 2>&1)"
  status=$?
  local verdict="ok"
  if [[ "$status" -ne "$want_status" ]]; then
    verdict="WRONG STATUS"
  elif [[ -n "$want_text" ]] && ! grep -q -- "$want_text" <<<"$out"; then
    verdict="WRONG OUTPUT"
  fi
  if [[ "$verdict" == "ok" ]]; then
    printf 'CONTROL %-42s observed: exit %-3s %s\n' "$name" "$status" "-> as specified"
  else
    CONTROLS_BAD=$(( CONTROLS_BAD + 1 ))
    printf 'CONTROL %-42s observed: exit %-3s -> %s (wanted exit %s%s)\n' \
      "$name" "$status" "$verdict" "$want_status" \
      "${want_text:+, output containing \"$want_text\"}"
    sed 's/^/    | /' <<<"$out"
  fi
}

# Every fixture shares this preamble: the fail()/setup_error() a real harness
# defines, then the library.
preamble() {
  cat <<PREAMBLE
set -uo pipefail
fail() { echo "FIXTURE: FAIL — \$1" >&2; exit 1; }
setup_error() { echo "FIXTURE: FAIL — \$1" >&2; exit 2; }
source "$LIB"
PREAMBLE
}

# ---------------------------------------------------------------------------
# CONTROL 1 — the positive control.
#
# A well-formed fixture that executes exactly the checks it declares must
# PASS. Without this one the other controls prove only that the gate can say
# no. The floor must not manufacture false failures, and this is where that is
# observed rather than assumed.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
ASSERTIONS_REQUIRED=4
ck; [[ 1 -eq 1 ]] || fail "one"
ck; [[ 2 -eq 2 ]] || fail "two"
for i in a b; do
  ck; [[ -n "$i" ]] || fail "empty $i"
done
require_assertions "$ASSERTIONS_REQUIRED"
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c1-honest.sh"
expect "1 honest harness passes" 0 "FIXTURE: PASS" "$WORKDIR/c1-honest.sh"

# ---------------------------------------------------------------------------
# CONTROL 2 — THE ONE THIS WHOLE UNIT IS FOR.
#
# The assertions are DELIBERATELY SKIPPED: the loop that carries four of the
# six checks iterates over an empty list, which is exactly GAP-0155's shape (a
# `for` that examined nothing) and exactly what verify-freestanding.sh did
# when `mapfile` produced an empty symbol list under bash 3.2. Every statement
# in the fixture succeeds. Nothing returns non-zero. `set -e` would see
# nothing wrong, and neither would `trap ERR`.
#
# It must FAIL, and it must fail BEFORE the PASS line prints.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
ASSERTIONS_REQUIRED=6
ck; [[ 1 -eq 1 ]] || fail "one"
ck; [[ 2 -eq 2 ]] || fail "two"
# The list is empty -- the four checks below never execute. No command fails.
SYMS=""
for s in $SYMS; do
  ck; [[ -n "$s" ]] || fail "symbol $s"
  ck; [[ "$s" != "dc_alloc" ]] || fail "runtime symbol $s leaked"
done
require_assertions "$ASSERTIONS_REQUIRED"
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c2-skipped.sh"
expect "2 skipped assertions FAIL" 1 "only 2 of the 6 declared checks executed" "$WORKDIR/c2-skipped.sh"

# ---------------------------------------------------------------------------
# CONTROL 3 — a declared floor that EXCEEDS what ran must FAIL.
#
# The GAP-0167 shape: the harness's claim about itself is larger than the work
# it did. Here the claim is arithmetic rather than prose, which is the point --
# prose cannot be checked and a number can.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
ASSERTIONS_REQUIRED=99
ck; [[ 1 -eq 1 ]] || fail "one"
ck; [[ 2 -eq 2 ]] || fail "two"
ck; [[ 3 -eq 3 ]] || fail "three"
require_assertions "$ASSERTIONS_REQUIRED"
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c3-overclaim.sh"
expect "3 floor exceeds what ran FAIL" 1 "only 3 of the 99 declared checks executed" "$WORKDIR/c3-overclaim.sh"

# ---------------------------------------------------------------------------
# CONTROL 4 — a floor of zero is refused.
#
# A zero floor is a gate switched off, and switching the gate off must not be
# the quiet way past it. Note the asymmetry with ADR-0028's allowlist, which
# is empty BY DESIGN and therefore must NOT be guarded for non-emptiness: the
# justification for treating zero as impossible here is written out in
# harness.sh's comment on require_assertions, because "assert it is not empty"
# is only correct where empty is genuinely unreachable.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
ck; [[ 1 -eq 1 ]] || fail "one"
require_assertions 0
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c4-zero-floor.sh"
expect "4 zero floor refused" 1 "a declared floor of 0 is refused" "$WORKDIR/c4-zero-floor.sh"

# ---------------------------------------------------------------------------
# CONTROL 5 — a non-numeric / missing floor is refused.
#
# `require_assertions "$ASSERTIONS_REQUIRED"` with the variable deleted must
# not degrade into a pass. Under `set -u` this would abort anyway; the fixture
# passes an explicit empty string so the guard itself is what is observed.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
ck; [[ 1 -eq 1 ]] || fail "one"
require_assertions ""
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c5-bad-floor.sh"
expect "5 non-numeric floor refused" 1 "must be a non-negative integer" "$WORKDIR/c5-bad-floor.sh"

# ---------------------------------------------------------------------------
# CONTROL 6 — sourcing without fail() defined is refused.
#
# Every helper reports through the harness's own fail(). A harness that
# sourced the library first would get "command not found" at the moment of
# diagnosis, which is the failure mode this whole unit is about.
# ---------------------------------------------------------------------------
{
  echo "set -uo pipefail"
  echo "source \"$LIB\""
  echo 'echo "FIXTURE: PASS"'
} >"$WORKDIR/c6-no-fail.sh"
expect "6 sourcing without fail() refused" 2 "must define fail() BEFORE sourcing" "$WORKDIR/c6-no-fail.sh"

# ---------------------------------------------------------------------------
# CONTROL 7 — a capture()d command that FAILS is caught, not silently aborted.
#
# `set -e` is ON in this fixture, which is the condition under which the old
# `OUT=$(cmd); STATUS=$?` idiom aborts on the assignment line and never
# reaches fail(). capture() must instead bind the status, let the harness
# reach its own assertion, and produce the named diagnostic.
#
# The command's OUTPUT must survive too: the reason ADR-0030 refused `set -e`
# is that aborting throws away the compiler's error text, so a replacement
# that kept the status and lost the output would be no better.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
set -e
capture OUT STATUS -- sh -c 'echo "the compiler said no" >&2; exit 42'
ck; [[ "$STATUS" -eq 0 ]] || fail "the build exited $STATUS: $OUT"
require_assertions 1
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c7-capture-catches.sh"
expect "7 failed capture() caught under set -e" 1 "the build exited 42: the compiler said no" "$WORKDIR/c7-capture-catches.sh"

# ---------------------------------------------------------------------------
# CONTROL 8 — the same fixture written the OLD way aborts silently.
#
# This is the control that establishes control 7 measured something. Identical
# fixture, `OUT=$(cmd); STATUS=$?` instead of capture(). Expected: exit 42
# straight out of the assignment, no `FIXTURE: FAIL` line, no output. If this
# one ever starts printing a diagnostic, control 7 has stopped proving
# anything and both need re-reading.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
set -e
OUT="$(sh -c 'echo "the compiler said no" >&2; exit 42' 2>&1)"
STATUS=$?
ck; [[ "$STATUS" -eq 0 ]] || fail "the build exited $STATUS: $OUT"
require_assertions 1
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c8-old-idiom-aborts.sh"
expect "8 old idiom aborts silently (contrast)" 42 "" "$WORKDIR/c8-old-idiom-aborts.sh"
# ...and the silence is the point, so it is asserted rather than described.
C8_OUT="$("$BASH" "$WORKDIR/c8-old-idiom-aborts.sh" 2>&1)"
CONTROLS_RUN=$(( CONTROLS_RUN + 1 ))
if [[ -n "$C8_OUT" ]]; then
  CONTROLS_BAD=$(( CONTROLS_BAD + 1 ))
  printf 'CONTROL %-42s observed: printed %s bytes -> expected total silence\n' \
    "8b old idiom prints no diagnostic" "${#C8_OUT}"
  sed 's/^/    | /' <<<"$C8_OUT"
else
  printf 'CONTROL %-42s observed: %-10s %s\n' \
    "8b old idiom prints no diagnostic" "0 bytes" "-> as specified"
fi

# ---------------------------------------------------------------------------
# CONTROL 9 — capture() is behaviour-preserving on the SUCCESS path.
#
# 86 sites are being converted mechanically; if capture() differed from the
# idiom it replaces in what it puts in the variable, the conversion would be a
# silent rewrite of 86 assertions rather than a refactor. Same combined
# stdout+stderr, same trailing-newline stripping, same status.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
OLD="$(sh -c 'echo out; echo err >&2; printf "no-newline"' 2>&1)"
OLD_STATUS=$?
capture NEW NEW_STATUS -- sh -c 'echo out; echo err >&2; printf "no-newline"'
ck; [[ "$NEW" == "$OLD" ]] || fail "capture() captured $(printf '%q' "$NEW"), the idiom captured $(printf '%q' "$OLD")"
ck; [[ "$NEW_STATUS" == "$OLD_STATUS" ]] || fail "capture() said $NEW_STATUS, the idiom said $OLD_STATUS"
require_assertions 2
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c9-equivalence.sh"
expect "9 capture() == old idiom on success" 0 "FIXTURE: PASS" "$WORKDIR/c9-equivalence.sh"

# ---------------------------------------------------------------------------
# CONTROL 10 — run_status and await bind a status without capturing output.
#
# The QMP-driver sites stream their progress to the terminal; a conversion
# that swallowed that output would make every boot failure harder to read.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
run_status ST -- sh -c 'echo "driver progress"; exit 7'
ck; [[ "$ST" -eq 7 ]] || fail "run_status said $ST, expected 7"
sh -c 'exit 3' &
BG=$!
await BGST "$BG"
ck; [[ "$BGST" -eq 3 ]] || fail "await said $BGST, expected 3"
require_assertions 2
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c10-run-status.sh"
expect "10 run_status/await bind status" 0 "driver progress" "$WORKDIR/c10-run-status.sh"

# ---------------------------------------------------------------------------
# CONTROL 11 — capture_sh keeps a compound command's status.
#
# The `$( (cd X && a && b) 2>&1 )` sites. `cd` must still not leak out of the
# subshell, and a failure in the middle of the && chain must be reported.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
HERE="$PWD"
capture_sh OUT ST -- 'cd / && echo "in $PWD" && sh -c "exit 5" && echo unreachable'
ck; [[ "$ST" -eq 5 ]] || fail "capture_sh said $ST, expected 5"
ck; [[ "$OUT" == "in /" ]] || fail "capture_sh captured \"$OUT\""
ck; [[ "$PWD" == "$HERE" ]] || fail "capture_sh let cd leak: now in $PWD"
require_assertions 3
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c11-capture-sh.sh"
expect "11 capture_sh compound status + no cd leak" 0 "FIXTURE: PASS" "$WORKDIR/c11-capture-sh.sh"

# ---------------------------------------------------------------------------
# CONTROL 12 — capture_log sends combined output to the file and binds status.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
LOG="$(mktemp "${TMPDIR:-/tmp}/hs-c12.XXXXXX")"
capture_log "$LOG" ST -- sh -c 'echo out; echo err >&2; exit 9'
ck; [[ "$ST" -eq 9 ]] || fail "capture_log said $ST, expected 9"
ck; grep -q '^out$' "$LOG" || fail "stdout missing from the log"
ck; grep -q '^err$' "$LOG" || fail "stderr missing from the log"
rm -f "$LOG"
require_assertions 3
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c12-capture-log.sh"
expect "12 capture_log file + status" 0 "FIXTURE: PASS" "$WORKDIR/c12-capture-log.sh"

# ---------------------------------------------------------------------------
# CONTROL 13 — a bad destination name is refused rather than eval'd.
#
# printf -v with an attacker-shaped name is the obvious way for a helper like
# this to become an injection site. It is a harness library, not a network
# service, so this is hygiene rather than security -- but a silent no-op here
# would leave a status variable unset and `set -u` would then blame the wrong
# line.
# ---------------------------------------------------------------------------
{
  preamble
  cat <<'BODY'
capture 'x; echo pwned' ST -- true
echo "FIXTURE: PASS"
BODY
} >"$WORKDIR/c13-bad-varname.sh"
expect "13 bad destination name refused" 1 "is not a valid variable name" "$WORKDIR/c13-bad-varname.sh"

echo
if [[ "$CONTROLS_BAD" -eq 0 ]]; then
  echo "CONTROLS: PASS — $CONTROLS_RUN controls, every one observed behaving as specified"
  exit 0
fi
echo "CONTROLS: FAIL — $CONTROLS_BAD of $CONTROLS_RUN controls did not behave as specified" >&2
exit 1
