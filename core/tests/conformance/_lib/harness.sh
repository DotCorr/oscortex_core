# core/tests/conformance/_lib/harness.sh
#
# Shared machinery for the conformance harnesses. SOURCED, never executed.
# (Precedent: the sibling DCDart repo's core/tests/conformance/_lib/.)
#
# ===========================================================================
# WHY THIS EXISTS (GAP-0168, ADR-0030, ADR-0032)
# ===========================================================================
#
# The property this file defends, stated once:
#
#     A HARNESS MUST NOT BE ABLE TO PRINT ITS PASS LINE WITHOUT HAVING
#     ACTUALLY EXECUTED THE ASSERTIONS THAT PASS LINE DESCRIBES.
#
# Three real defects in this repo, all of which a green suite could not see:
#
#   1. A VACUOUS CHECK. verify-freestanding.sh used `mapfile` (bash 4+) on a
#      host whose /bin/bash is 3.2.57. It failed closed ONLY because
#      `set -euo pipefail` was on. Without it the undefined-symbol list would
#      have been empty, the loop would have examined nothing, and it would
#      have printed `FREESTANDING: pass` having checked zero symbols.
#      (ADR-0028.)
#
#   2. A CLAIM WITH NO CHECK UNDER IT. m19-argv's PASS line asserted
#      `-> verify-freestanding ->` and the harness never invoked it. Worse
#      than a vacuous check, because the claim is what a reader audits and
#      re-running never contradicts it. (GAP-0167.)
#
#   3. A SILENT ABORT. `OUT=$(cmd); STATUS=$?` under `set -e` aborts on the
#      assignment, so `fail()` -- the thing that prints the FAIL line -- is
#      exactly what never runs. (GAP-0156 §survey.)
#
# ADR-0030 surveyed `set -e` as the remedy and rejected it: it does not catch
# defect 1 at all (a bash-3.2 `declare -A` that collapses to index 0 produces
# no non-zero status anywhere -- every assignment succeeds and the harness
# compares wrong values against wrong values), and it converts 3's diagnostic
# into silence. `trap ERR` was rejected for the same reason: it fires under
# exactly the rules that make `set -e` fire.
#
# What is here instead is what ADR-0030 §4 argues for:
#
#   * ck / require_assertions -- an ASSERTION-COUNT FLOOR. The counter is
#     incremented next to each real check, so the count is a property of the
#     path actually taken, not a constant. This catches an abort, a `for` that
#     iterated zero times, a `case` that fell through, a guard edited into
#     unreachability, AND the silent-wrong-value case that `set -e` is blind
#     to -- because a harness whose map collapsed still has to reach the same
#     number of checks, and one that aborted early cannot.
#
#   * capture / capture_log / capture_sh / run_status / await -- replacements
#     for capture-then-`$?`, which keep the command and the reading of its
#     status ATOMIC. Two things are bought: the pattern becomes safe if
#     `set -e` is ever adopted, and -- true TODAY, without `set -e` -- it
#     becomes impossible for a command inserted between the capture and the
#     `$?` line to silently substitute its own status for the one being
#     tested. That second hazard is live in every one of the 86 sites.
#
# ===========================================================================
# PORTABILITY: THIS FILE MUST RUN UNDER bash 3.2 (ADR-0028)
# ===========================================================================
#
# macOS ships /bin/bash 3.2.57 and env.sh puts brew's bash 5 first, so a
# bash-4-ism here would be invisible to every sweep and fatal to anyone
# running /bin/bash. Rules, same three as verify-freestanding.sh:
#
#   1. No bash-4 builtins: no `mapfile`/`readarray`, no `declare -A`, and no
#      `declare -n` namerefs (bash 4.3+). Variables are set by name with
#      `printf -v`, which is bash 3.1+.
#   2. Every array expansion uses the ${arr[@]+"${arr[@]}"} guard.
#   3. No GNU regex extensions.
#
# The controls in _lib/controls/run.sh are executed under /bin/bash
# explicitly, not `env bash`, precisely so this claim is tested rather than
# asserted.
#
# ===========================================================================
# USAGE
# ===========================================================================
#
#   fail() { echo "M0-boot: FAIL — $1" >&2; exit 1; }
#   setup_error() { echo "M0-boot: FAIL — $1" >&2; exit 2; }
#   source "$SCRIPT_DIR/../_lib/harness.sh"
#   ASSERTIONS_REQUIRED=42
#   ...
#   ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
#   capture VERIFY_OUT VERIFY_STATUS -- bash scripts/verify-freestanding.sh k.o
#   ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding exited $VERIFY_STATUS"
#   ...
#   require_assertions "$ASSERTIONS_REQUIRED"
#   echo "M0-boot: PASS — ..."
#
# `fail` MUST be defined before this file is sourced -- every helper here
# reports through it, and each harness's fail() carries that harness's own
# name and exit convention.

if ! declare -f fail >/dev/null 2>&1; then
  echo "harness.sh: FAIL — the sourcing harness must define fail() BEFORE sourcing _lib/harness.sh" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# THE ASSERTION COUNTER
# ---------------------------------------------------------------------------
#
# `ck` sits immediately before a check, on the same line:
#
#     ck; [[ "$GOT" -eq 44 ]] || fail "44 externs expected, got $GOT"
#     ck; if [[ $STATUS -ne 0 ]]; then cat "$LOG" >&2; fail "..."; fi
#
# It is deliberately a statement of its own rather than a wrapper around the
# condition, because the conditions in this suite are `[[ ]]`, `grep -q`,
# `cmp`, pipelines and multi-line continuations, and a wrapper would have had
# to `eval` its argument -- trading a mechanical, reviewable edit for a
# quoting hazard at a thousand sites.
#
# It increments BEFORE the check rather than after. That is not a weakening:
# no harness has `set -e`, so a check that is reached always completes, and
# incrementing first means a check that ABORTS mid-way (a killed subprocess,
# an unbound variable under `set -u`) is still counted as reached -- which is
# the honest reading, and in any case such a run dies before the PASS line.
#
# Placement rule, applied uniformly: `ck` goes on the FIRST line of the
# statement that owns the failure. For `<test> || fail`, that is the test's
# own line (its continuations do not get one). For a bare `fail` inside an
# `if`/`case`, it goes on the head of the INNERMOST enclosing `if`/`case`, so
# a check nested in a branch that was not taken is correctly NOT counted.
#
# WHAT THIS DOES NOT CLAIM. The count proves the checks were REACHED. It does
# not prove any of them was a good check -- a `[[ 1 -eq 1 ]] || fail` counts
# like any other. That is a code-review property and this is not a substitute
# for it. What it does rule out is the whole family above, where the harness
# printed a verdict about work it never did.
ASSERTIONS=0

ck() {
  ASSERTIONS=$(( ASSERTIONS + 1 ))
  return 0
}

# require_assertions <floor> -- the gate, called immediately before the PASS
# line. Prints the observed count so the pinned floor can be re-derived from a
# run rather than hand-counted (that is how you update it: run the harness,
# read the number, pin it).
#
# `>=`, not `==`: a harness whose checks live in a loop over a list it built
# may legitimately execute more than the floor, and a floor is the property
# worth pinning -- "at least this much work happened". A count that DROPS
# below the floor is what the failure family looks like, and that is caught.
#
# A FLOOR OF ZERO IS REFUSED, and this is the one non-vacuity guard in this
# file, so its justification is written down rather than assumed. ADR-0028's
# lesson -- a sibling repo asserted its symbol allowlist parsed to more than
# zero entries, and that allowlist is EMPTY BY DESIGN, so the guard turned the
# correct configuration into a hard FATAL -- is that asserting non-emptiness
# of something designed to be empty is the same defect as a vacuous pass,
# pointed the other way. It does not apply here, and the reason is specific:
# a conformance harness with zero checks is not a legitimate configuration
# this suite has, or could have. Every harness in it begins by checking that
# its tools are on PATH and ends by asserting captured output, and a harness
# that asserted nothing would have nothing to print a PASS line ABOUT. Zero is
# impossible here in a way empty-allowlist is not: the empty allowlist means
# "permit nothing", a real and intended state, whereas a zero floor means
# "this gate is switched off", which is the failure it exists to prevent.
require_assertions() {
  local floor="${1:-}"
  case "$floor" in
    ''|*[!0-9]*)
      fail "require_assertions: the declared floor must be a non-negative integer, got \"$floor\"" ;;
  esac
  if [[ "$floor" -lt 1 ]]; then
    fail "require_assertions: a declared floor of $floor is refused — a zero floor is a gate that is switched off, and no harness in this suite legitimately runs zero checks (see _lib/harness.sh)"
  fi
  if [[ "$ASSERTIONS" -lt "$floor" ]]; then
    fail "only $ASSERTIONS of the $floor declared checks executed — the PASS line below describes work this run did not do (GAP-0168). Either the harness aborted, a loop iterated zero times, a branch was not taken, or a check was deleted without lowering ASSERTIONS_REQUIRED."
  fi
  echo "ASSERTIONS: pass  $ASSERTIONS checks executed, declared floor $floor"
}

# ---------------------------------------------------------------------------
# CAPTURE-THEN-STATUS, MADE ATOMIC
# ---------------------------------------------------------------------------
#
# All five helpers below return 0 always. They never abort the harness and
# never call fail() on the wrapped command's behalf: the caller reads the
# status out of the variable it named and decides, exactly as before. The ONLY
# thing that changes is that the command and the recording of its status can
# no longer be separated.
#
# Combined stdout+stderr is what the old idiom captured (`2>&1` inside the
# command substitution), and it is what capture/capture_log/capture_sh
# capture, so the conversion is behaviour-preserving. Trailing newlines are
# stripped by command substitution here exactly as they were there.

# Internal: reject a destination that is not a plain variable name, and reject
# the helpers' own locals, which dynamic scoping would otherwise let a caller
# clobber from underneath.
__hs_check_var() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*|[0-9]*)
      fail "harness.sh: \"$1\" is not a valid variable name" ;;
    __hs_*)
      fail "harness.sh: \"$1\" collides with this library's own locals" ;;
  esac
}

__hs_check_sep() {
  [[ "$1" == "--" ]] || fail "harness.sh: expected '--' before the command, got '$1'"
}

# capture <outvar> <statusvar> -- cmd [args...]
#   outvar   <- combined stdout+stderr of cmd
#   statusvar<- cmd's exit status
capture() {
  local __hs_out_var="${1:-}" __hs_status_var="${2:-}" __hs_sep="${3:-}"
  __hs_check_var "$__hs_out_var"
  __hs_check_var "$__hs_status_var"
  __hs_check_sep "$__hs_sep"
  shift 3
  [[ $# -gt 0 ]] || fail "harness.sh: capture was given no command"
  local __hs_out __hs_status
  # The `if` condition suppresses `set -e` for the assignment, so this helper
  # is already correct should the suite ever adopt it -- which is the whole
  # reason ADR-0030 calls capture() a prerequisite rather than a nicety.
  if __hs_out="$("$@" 2>&1)"; then __hs_status=0; else __hs_status=$?; fi
  printf -v "$__hs_out_var" '%s' "$__hs_out"
  printf -v "$__hs_status_var" '%s' "$__hs_status"
  return 0
}

# capture_log <logfile> <statusvar> -- cmd [args...]
#   for the sites that sent combined output to a file instead of a variable.
capture_log() {
  local __hs_log="${1:-}" __hs_status_var="${2:-}" __hs_sep="${3:-}"
  [[ -n "$__hs_log" ]] || fail "harness.sh: capture_log was given no log path"
  __hs_check_var "$__hs_status_var"
  __hs_check_sep "$__hs_sep"
  shift 3
  [[ $# -gt 0 ]] || fail "harness.sh: capture_log was given no command"
  local __hs_status
  if "$@" >"$__hs_log" 2>&1; then __hs_status=0; else __hs_status=$?; fi
  printf -v "$__hs_status_var" '%s' "$__hs_status"
  return 0
}

# capture_sh <outvar> <statusvar> -- <shell snippet>
#   for the handful of sites whose subject is a COMPOUND command --
#   `$( (cd X && a && b) 2>&1 )` -- which cannot be passed as argv words.
#   The snippet is evaluated in a subshell, which is precisely what `$( ... )`
#   already did to the same text: no new evaluation is introduced, it is the
#   same one, moved. `cd` inside it still does not leak, for the same reason.
capture_sh() {
  local __hs_out_var="${1:-}" __hs_status_var="${2:-}" __hs_sep="${3:-}"
  __hs_check_var "$__hs_out_var"
  __hs_check_var "$__hs_status_var"
  __hs_check_sep "$__hs_sep"
  shift 3
  [[ $# -gt 0 ]] || fail "harness.sh: capture_sh was given no snippet"
  local __hs_snippet="$*" __hs_out __hs_status
  if __hs_out="$( eval "$__hs_snippet" 2>&1 )"; then __hs_status=0; else __hs_status=$?; fi
  printf -v "$__hs_out_var" '%s' "$__hs_out"
  printf -v "$__hs_status_var" '%s' "$__hs_status"
  return 0
}

# run_status <statusvar> -- cmd [args...]
#   for the sites whose output must keep streaming to the terminal (the QMP
#   driver's progress lines). Nothing is captured; only the status is bound.
run_status() {
  local __hs_status_var="${1:-}" __hs_sep="${2:-}"
  __hs_check_var "$__hs_status_var"
  __hs_check_sep "$__hs_sep"
  shift 2
  [[ $# -gt 0 ]] || fail "harness.sh: run_status was given no command"
  local __hs_status
  if "$@"; then __hs_status=0; else __hs_status=$?; fi
  printf -v "$__hs_status_var" '%s' "$__hs_status"
  return 0
}

# await <statusvar> <pid>
#   `wait "$pid" 2>/dev/null; STATUS=$?` -- the background-QEMU reap. stderr is
#   discarded because the pid is routinely already reaped by the time this
#   runs, and bash's complaint about that is not a result.
await() {
  local __hs_status_var="${1:-}" __hs_pid="${2:-}"
  __hs_check_var "$__hs_status_var"
  [[ -n "$__hs_pid" ]] || fail "harness.sh: await was given no pid"
  local __hs_status=0
  wait "$__hs_pid" 2>/dev/null || __hs_status=$?
  printf -v "$__hs_status_var" '%s' "$__hs_status"
  return 0
}
