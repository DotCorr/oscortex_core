# ADR-0030 — The conformance suite does not adopt `set -e`; it should count its own assertions instead

**Status:** accepted
**Date:** 2026-08-26
**Supersedes:** nothing. **Related:** ADR-0028 (the freestanding check under bash 3.2), GAP-0155,
GAP-0156, GAP-0167, GAP-0168.

---

## 1. Context

Three defects in the same family were open against the conformance suite. They are not bugs in the
kernel; they are places where **the suite says something it does not check**.

* **GAP-0167** — `m19-argv`'s PASS line reads `... -> verify-freestanding -> FOUR real QEMU boots`,
  and that sentence was the only occurrence of the string in the file. The harness never invoked
  `scripts/verify-freestanding.sh`.
* **The executable bit** — ten of the twenty harnesses were mode `644`, so `./run.sh` exited 126.
  Every sweep in this repo invokes `bash run.sh`, so nothing ever noticed.
* **GAP-0156** — no harness has `set -e`. A `declare -A` breakage under bash 3.2 was caught only
  because `set -u` happened to fire on an arithmetic subscript; the note recorded that a *defined*
  numeric subscript would have collapsed every key to index 0 and reported PASS over a corrupt map.

The first two are mechanical and were fixed. The third is a judgement call, and this ADR is that
judgement.

**The property being protected**, stated once so the rest of this document can be measured against
it: *a harness must not print its PASS line unless the assertions that PASS line describes actually
executed.* `set -e` is one candidate means to that end. It is not the end itself, and the distinction
turns out to matter.

## 2. The survey

All twenty harnesses were classified mechanically, then the classifier's hits were read back by hand
in context (the first pass over-counted: it flagged `grep -q ... \` continued onto a following
`|| fail` line, and it flagged shell-looking lines inside Python heredocs). Blocking constructs, with
counts across the suite:

| Class | Construct | Sites | Harnesses |
|---|---|---:|---:|
| **A** | `OUT=$(cmd); STATUS=$?` — capture, then read the status on a later line | **135** | **20/20** |
| **C** | a bare predicate as a statement (`cmp`, `diff`, `hdiutil detach`, `grep`) whose non-zero status is expected or is a diagnostic | 86 | 18/20 |
| **G** | `grep -q ... && fail "..."` — the *good* case is grep returning 1 | 90 | 14/20 |
| **B** | bare `(( ... ))` as a statement | **0** | 0/20 |
| **F** | `let` | **0** | 0/20 |

**Harnesses that are safe to convert as-is: 0 of 20. Harnesses blocked: 20 of 20.**

311 blocking sites in all. Class A alone is decisive and universal: every harness has at least four
(`m0-boot` and `mb-info` 4; `m14-fat`, `m15-fileio` and `m16-filewrite` 9). The per-harness line
numbers for all three classes are recorded in GAP-0156, so the next person has a work list rather
than a warning.

Counts are as of this commit, so they include the two sites GAP-0167's own fix added to `m19-argv`
(one class A, one class G). Those were copied deliberately from `m18-preempt` §3h and `m8-paging`:
matching the suite's existing idiom is worth more than a lone harness pre-empting a convention this
ADR is only proposing.

### 2.1 A correction to the prior assessment

GAP-0156 named three constructs as the obstacle: `cmd || fail`, `grep -q` as a predicate, and `(( ))`
in conditions. Executed under `/bin/bash` 3.2.57 with `set -euo pipefail`, **two of those three are
not hazards at all**, and the one that is only bites in a form the note did not name:

```
1. cmd || fail  (success case)            -> ok, still running
2. (( n == 0 )) in an if condition        -> ok, condition context is safe
3. echo hello | grep -q hello || fail     -> ok
4. OUT=$(false); STATUS=$?                -> ABORTED. "$STATUS" never read.
```

`set -e` is suppressed for every command in a `&&`/`||` list except the last, and for the whole
condition part of `if`/`while`/`until`, so `cmd || fail` and `(( ))`-in-a-condition are fine. There
are **zero** bare `(( ))` statements in the suite. `grep -q` is only a hazard bare (class C) or as
the left half of `&& fail` (class G).

The construct that actually blocks all twenty is the one the note did not mention: **capture-then-`$?`**.
And its failure mode is precisely the defect under repair. Line 4 above did not merely abort — it
aborted *silently*, with no `M19-argv: FAIL —` line, because `fail()` is exactly what never ran.
Adding `set -e` to `m19-argv` would convert

```sh
BUILD_OUT="$(bash "$CORE_DIR/scripts/build-kernel.sh" 2>&1)"
BUILD_STATUS=$?
echo "$BUILD_OUT"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
```

from a harness that prints the compiler's output and names the exit status into one that prints
nothing and exits 1. That is a strict regression in diagnosis, applied 135 times.

## 3. Decision

**Do not adopt `set -e` in the conformance harnesses.** Not in bulk, and — on this survey — not
individually either, because no harness qualifies. `set -uo pipefail` plus the explicit `fail()`
discipline stays.

This is not "the conversion is too much work." It is that the conversion is **not obviously a net
gain even when done correctly**, for three reasons.

### 3.1 `set -e` does not catch GAP-0156's own motivating example

The scenario the gap describes — a defined numeric subscript collapsing every `SYM[...]` key to index
0 under bash 3.2 — produces **no non-zero exit status anywhere**. Every assignment succeeds; every
lookup returns the same wrong value; the harness compares wrong values against wrong values and
prints PASS. `set -e` is blind to it. The mechanism proposed as the fix does not address the failure
that prompted it, which is the strongest single argument against reaching for it reflexively.

### 3.2 The abort case is already loud, and the flags already say so

`set -u` and `pipefail` are on. An abort exits non-zero, and the PASS line is the last statement in
every harness, so an aborted run prints no PASS line *and* returns non-zero. The sweep sees a failure.
What `set -e` adds over the status quo is coverage of the narrow case where a command fails, the
script continues, and every downstream assertion still passes on stale data — and in this suite the
downstream assertions are overwhelmingly `[[ ... ]] || fail` against *derived* values, which is
exactly the shape that does not silently accept stale data.

### 3.3 It would trade a real diagnostic for a weaker guarantee

See §2.1. 135 sites currently name what failed and with what status.

## 4. What should be done instead (proposed, not implemented here — GAP-0168)

The property in §1 is about **assertions having executed**, not about **commands having succeeded**.
Two mechanisms address it directly, and both are strictly stronger than `set -e` for this suite
because they also catch the silent-wrong-value case of §3.1:

1. **An assertion-count floor.** Have `fail()`'s sibling — a `pass()` / `checked()` helper — increment
   a counter, and assert a pinned minimum immediately before the PASS line:
   `(( ASSERTIONS >= 61 )) || fail "only $ASSERTIONS of 61 assertions ran"`. This catches an abort, a
   `for` loop that iterated zero times, a `case` that fell through, and a guard that was edited into
   unreachability — the whole GAP-0155/GAP-0156 family — and it does so at one site per harness rather
   than 135.

2. **A `capture()` helper** replacing the class-A idiom, preserving both the output and the status:
   `capture VERIFY_OUT VERIFY_STATUS -- bash scripts/verify-freestanding.sh build/kmain.o`. This is
   what would have to be written anyway to make `set -e` safe, and it is worth doing on its own merits
   whether or not `set -e` ever follows.

Mechanism 1 is the one that protects the stated property. Mechanism 2 is a prerequisite for `set -e`
and a readability gain regardless. **Neither is implemented in this commit**, deliberately: touching
all twenty harnesses is a ~27-minute re-run per iteration and belongs in its own unit, and choosing a
counter discipline for a suite this heavily commented is a decision the next author should make with
this ADR in front of them rather than inherit silently.

## 5. Rejected alternatives

* **Bulk `set -e` across all twenty.** Rejected: 20/20 blocked (§2), and §3.
* **`trap ... ERR`.** Rejected: the ERR trap fires under exactly the same rules that make `set -e`
  fire, so every class A/C/G site above is an equally spurious trigger. It changes the reporting, not
  the classification.
* **`set -e` only inside the boot-driving functions.** Rejected: `drive_session()` and its siblings are
  the *densest* concentration of class A (`local drive_status=$?`, `local qemu_status=$?`), so the one
  region where it is most tempting is the one where it is least applicable.
* **Asserting non-emptiness of every captured variable.** Rejected as a general rule for the reason
  ADR-0028 already gives about the allowlist: a vacuity guard is correct only where the empty case is
  genuinely impossible, and asserting the non-emptiness of something legitimately empty is the same
  defect pointed the other way.

## 6. Consequences

* The suite keeps `set -uo pipefail` and explicit `fail()`. No harness's diagnostics regress.
* GAP-0156 stays **OPEN**, but is no longer a warning — it now carries the per-harness, per-line work
  list from §2 and the §2.1 correction.
* GAP-0168 is opened for the two mechanisms in §4.
* GAP-0167 is **CLOSED**: `m19-argv` now runs `verify-freestanding.sh` against `build/kmain.o`,
  `build/kdata.o` and `build/kernel.elf`, checks the exit status, checks that no `FREESTANDING: FAIL`
  line was printed while exiting 0, requires exactly three `FREESTANDING: pass` lines, and pins the
  declared-extern count at 44 (unchanged from M18 — M19 added no assembly). The PASS line now reports
  that number instead of asserting the bare word `verify-freestanding`.
* All twenty harnesses are mode `755`. Verified per-file that the shebang is `#!/usr/bin/env bash`
  **before** setting the bit: `+x` on a file with a wrong shebang converts a clean 126 into an
  arbitrary misinterpretation, which is a worse failure, not a better one.
