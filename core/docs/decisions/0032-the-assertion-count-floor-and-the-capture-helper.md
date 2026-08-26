# ADR-0032 — The assertion-count floor and the `capture()` family: what ADR-0030 left open

**Status:** accepted
**Date:** 2026-08-26
**Supersedes:** nothing. **Implements:** ADR-0030 §4. **Related:** ADR-0028 (the freestanding check
under bash 3.2), GAP-0155, GAP-0156, GAP-0167, GAP-0168.

---

## 1. What this decides, and what it does not

ADR-0030 decided that the conformance suite does **not** adopt `set -e`, and proposed two mechanisms
instead: an assertion-count floor, and a `capture()` helper. It deliberately implemented neither, and
said the counter discipline "is a decision the next author should make with this ADR in front of
them rather than inherit silently."

This is that decision. **ADR-0030's argument is not re-litigated here** — `set -e` stays rejected,
`trap ERR` stays rejected, and the reasons are in ADR-0030 §3 and §5. What follows is only the part
ADR-0030 left open: *where the counter increments, where the floor comes from, and what shape the
capture helper actually has to be.*

Three findings below contradict ADR-0030's own sketch. They are stated as corrections rather than
folded in silently, because the sketch is what a reader will have read first.

---

## 2. Correction: there are 86 capture-then-`$?` sites, not 135

ADR-0030's survey table and GAP-0156's per-harness work list both say **135** class-A sites across
20/20 harnesses. The real number is **86**. Counted three ways, all agreeing:

```
$ grep -cE '^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\$\?[[:space:]]*$' */run.sh
   -> 86
$ grep -c '\$?' */run.sh          -> 89   (86 assignments + 3 direct reads, §6)
$ <count of helper calls after conversion>  -> 86
```

The survey's classifier counted **both lines** of the two-line idiom for some sites (`m0-boot` is
listed as `A: 39, 40, 63, 83` — 39 and 40 are the command and its `$?`, while 63 and 83 are single
lines of the same two-line shape). The conclusion the survey drew from the number — that class A is
universal and decisive, 20/20 harnesses, minimum four each — is unaffected and was independently
re-confirmed here. Only the total is wrong. GAP-0156's table is corrected in the same commit.

This matters beyond bookkeeping: **135 was the number quoted as the cost of the conversion**, in
ADR-0030 §3.3 ("135 sites currently name what failed and with what status") and in GAP-0168's
"134 sites, mechanical, no semantic change". A cost estimate that is 57% too high is the kind of
number that gets a piece of work deferred.

---

## 3. Correction: one `capture()` was not enough. Five helpers were needed.

ADR-0030 §4.2 sketches the helper as

```sh
capture VERIFY_OUT VERIFY_STATUS -- bash scripts/verify-freestanding.sh build/kmain.o
```

i.e. a name, a status name, and a command as argv words. **15 of the 86 subjects are not simple
commands and cannot be passed that way.** A mechanical conversion that assumed they were would have
produced silent, passing, wrong harnesses. The two shapes that break it, both found by reading the
generated diff rather than by reasoning:

```sh
# a COMPOUND command -- `capture` runs "$@", so this would have run only the
# `cd` under capture and the `bash` uncaptured, in the current directory:
VF_OUT="$(cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o 2>&1)"

# an ASSIGNMENT PREFIX -- this would have tried to exec a program whose name is
# literally `OSCORTEX_ALLOWLIST=/path/to/allowlist`:
VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" ... 2>&1)"
```

Both would have "converted" cleanly, passed `bash -n`, and — for the second — turned
`verify-freestanding.sh` into a check that never ran while the harness went on asserting things about
its output. That is GAP-0167's defect, reintroduced by the fix for it.

The five helpers, and why each exists rather than being folded into one:

| Helper | Sites | Subject shape |
|---|---:|---|
| `capture <out> <st> -- cmd...` | 17 | a simple command whose combined output is wanted |
| `capture_log <file> <st> -- cmd...` | 17 | output went to a log file, not a variable |
| `capture_sh <out> <st> -- 'snippet'` | 20 | compound / assignment-prefixed — argv words cannot express it |
| `run_status <st> -- cmd...` | 17 | output must keep streaming to the terminal (the QMP driver) |
| `await <st> <pid>` | 17 | `wait "$qemu_pid" 2>/dev/null` — reaping the background QEMU |
| **total** | **88** | (86 survey sites + the 2 in §6) |

`capture_sh` evaluates its snippet in a subshell. That is **not a new evaluation**: `$( ... )` was
already evaluating exactly the same text in exactly the same way, so `cd` still does not leak and the
quoting is unchanged. What moves is only *when the status is bound* — which is the entire point.

**Splitting rather than unifying was chosen deliberately.** A single helper that inspected its
argument and decided between exec and eval would have made the eval path invisible at the call site;
here `capture_sh` is a different word, and a reader can grep for the 20 places where a shell snippet
is evaluated.

---

## 4. The counter: `ck` next to each check, not a wrapper

`ck` is a statement placed immediately before the check it counts:

```sh
ck; [[ "$KDATA_BSS" -eq 14368 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes ..."
ck; if [[ $BUILD_STATUS -ne 0 ]]; then cat "$BUILD_LOG" >&2; fail "build-kernel.sh exited $BUILD_STATUS"; fi
have() { ck; grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "..."; }; }
```

**Why not a wrapper** (`assert '[[ ... ]]' "message"`): the conditions in this suite are `[[ ]]`
keywords, `(( ))`, `grep -q` pipelines, `cmp`, `case`, and multi-line `\`-continuations. `[[` is a
shell keyword, not a command, so it cannot be passed as an argument — a wrapper would have had to
`eval` its first argument, converting a mechanical and reviewable edit into a quoting hazard at a
thousand sites, in a suite whose assertion messages are full of quotes, `$(...)` and backticks.

**Why before and not after:** no harness has `set -e`, so a check that is reached always completes.
Incrementing first also counts a check that is reached and then aborts (a killed subprocess, `set -u`
firing) — which is the honest reading, and such a run dies before the PASS line anyway.

### 4.1 The placement rule

Applied uniformly by the instrumenter, and worth stating because it is what makes the count mean
something:

1. **`<test> || fail` / `&& fail` / `|| { …; fail …; }`** — `ck` goes on the FIRST line of the
   statement. Its `\`-continuations do not get one; one check, one increment.
2. **A bare `fail` inside `if`/`case`/`{ … }`** — `ck` goes on the head of the INNERMOST enclosing
   construct, so a check nested in a branch that was not taken is correctly NOT counted.
3. **A bare `fail` inside a loop with no conditional** — `for sym in <symbols that must not exist>;
   do fail …; done`. `ck` goes on the **loop head**. Counting the `fail` would count zero on every
   passing run, which is the very vacuity this mechanism exists to catch; counting the head counts
   *"we looked"*. Two sites (`m10-elf`, `m11-proc`).
4. **A one-line function whose body is the check** (`have`, `havent`, `nhave`, `phave`, `vhave`,
   `fhave`, `rhave` — the transcript assertions) — `ck` goes INSIDE the braces. Counting the
   definition would count once, at definition time, however many hundreds of times the function is
   then called. 16 such definitions.
5. **Never between a command and a read of `$?`** — see §5.

### 4.2 The rule that had to be added after it broke something

`ck` is a command, so it sets `$?`. The first version of the instrumenter prefixed it to
`if [[ $? -ne 0 ]]`, which made that test read `ck`'s status — always 0 — instead of the command's.
Three checks (`m14-fat`, `m15-fileio`, `m5-pci`) were silently converted into checks that could
never fail, and all three still passed, and the count still went up.

**That is the defect this entire mechanism exists to prevent, manufactured by the mechanism itself.**
It is recorded here rather than quietly fixed because it is the sharpest available illustration of
ADR-0030's own point: a green run proves nothing about whether the check under it is real. It was
caught by reading the generated diff, not by any test.

The rule is now mechanical: a statement whose text contains `$?` never receives the counter; it moves
up to the statement that PRODUCES the status. Two of the three sites were additionally converted to
`capture`, removing the `$?` read entirely (§6).

---

## 5. The floor: pinned per harness, derived from a run, `>=`

```sh
ASSERTIONS_REQUIRED=133          # near the top, next to the source line
...
require_assertions "$ASSERTIONS_REQUIRED"
echo "M5-pci: PASS — ..."
```

* **Where the number comes from.** `require_assertions` prints
  `ASSERTIONS: pass  <n> checks executed, declared floor <N>` immediately above the PASS line. The
  pin is read off a run, never hand-counted. GAP-0168 asked for exactly this ("it must be derived
  from a count the harness itself emits rather than hand-maintained"), and the reason is the same one
  that applies to the pinned `.bss` sizes and `shellStrHelp` byte counts already in these harnesses:
  a golden that a human recomputes is a golden that drifts.
* **`>=`, not `==`.** The runtime counts are *emergent, not static*: `m5-pci` has 74 `ck` sites in
  its text and executes **133** checks, because the loops and the `have`/`havent` helpers run many
  times. Pinning equality would make every re-run of a data-dependent loop a harness failure. A DROP
  below the floor is the failure family; a rise is someone adding work.
* **The honest cost, stated as GAP-0168 asked.** The pin is a golden that moves whenever a harness
  legitimately gains or loses a check. That is 20 numbers to maintain. It buys one thing `set -e`
  cannot buy at any price: it catches the case where **every command succeeded and the harness still
  did not do its job** — the bash-3.2 `declare -A` collapse of GAP-0156, the empty `mapfile` list of
  ADR-0028, and the branch that stopped being taken.
* **A second cost, which is not obvious and is worth writing down: these floors are macOS floors.**
  Four harnesses gate real checks behind `if command -v hdiutil` / `command -v fsck_msdos`, which are
  true on this machine and false on a Linux runner. On such a host the count would legitimately drop
  below the pin and the floor would fail a harness that is behaving correctly — the ADR-0028
  empty-allowlist mistake in a new costume. Nothing in the repo runs on Linux today (the suite needs
  `hdiutil` to certify a written FAT volume at all, and `m14`/`m15`/`m16` say so in their own
  comments), so this is recorded rather than solved. Whoever first runs this suite on Linux should
  expect it, and the fix is to count those branches' checks separately rather than to lower the pin.

### 5.1 A zero floor is refused — and why that is NOT the trap ADR-0028 warns about

`require_assertions` rejects a floor of 0 or a non-numeric floor.

ADR-0028 records a defect worth not repeating: a sibling repo added a guard asserting its symbol
allowlist parsed to more than zero entries, and **that allowlist is empty by design**, so the guard
turned the correct configuration into a hard FATAL. Asserting the non-emptiness of something designed
to be empty is the same defect as a vacuous pass, pointed the other way. ADR-0030 §5 rejects
"asserting non-emptiness of every captured variable" on precisely those grounds.

So the justification for guarding here is written down rather than assumed. **The empty case is
genuinely impossible here, and the allowlist's is not.** An empty allowlist means "permit nothing" —
a real, intended, expressible state. A zero floor means "this gate is switched off", which is not a
configuration but the absence of one: every harness in this suite begins by checking that its tools
are on PATH and ends by asserting captured bytes, and a harness that checked nothing would have
nothing to print a PASS line *about*. There is no harness for which zero is correct, and there cannot
be one, because a conformance harness with no checks is not a conformance harness.

That is the test to apply to any future vacuity guard in this repo: not "is empty unlikely" but
"is empty a state this thing can legitimately be in".

---

## 6. What was NOT converted

* **One `$?` read remains**, `m5-pci:1035`:

  ```sh
  ck; python3 - "$FB_SERIAL" <<'PY'
  ...
  PY
  [[ $? -eq 0 ]] || fail "the framebuffer boot did not run a command after the mode was set"
  ```

  The subject is a heredoc-fed `python3`, which cannot be passed as argv words to `capture`, and
  wrapping it in `capture_sh` would mean moving a 12-line Python program into a quoted string. It is
  left in the existing idiom, and §4.2's placement rule is what keeps it correct: the counter is on
  the `python3` line, not between it and the `$?`.
* **The 90 `grep -q … && fail` sites (class G) and the 86 bare predicates (class C)** are untouched.
  ADR-0030 classified them as obstacles *to `set -e`*, which is not being adopted; under the counter
  they are ordinary checks and are counted like any other.
* **`set -e` is still not adopted.** GAP-0156 stays open. What changed is that the helpers here are
  written to be `set -e`-safe (every wrapped command runs inside an `if` condition, where `set -e` is
  suppressed), so the prerequisite ADR-0030 §4.2 named is now met. Control 7 in
  `_lib/controls/run.sh` executes a fixture with `set -e` ON to demonstrate it.

---

## 7. The controls are part of the deliverable, not a check on it

`core/tests/conformance/_lib/controls/run.sh` — 14 controls, ~1 second, no QEMU, no kernel build.
Same discipline as ADR-0028's three freestanding controls, and for the same reason: **a guard that
has only ever been observed passing is indistinguishable from a guard that cannot fail.**

The two that carry the argument:

* **Control 2** — a fixture whose checks are deliberately skipped, by a `for` loop over an empty
  list. *Every statement in it succeeds. Nothing returns non-zero.* `set -e` would see nothing wrong
  and neither would `trap ERR`. It must FAIL, and the observed result is `exit 1`,
  `only 2 of the 6 declared checks executed`.
* **Controls 7 and 8** — the same fixture written both ways under `set -e`. With `capture()`: exit 1
  with `the build exited 42: the compiler said no`, the status named and the command's stderr
  preserved. With the old `OUT=$(cmd); STATUS=$?`: exit 42, **zero bytes of output**, no `FAIL` line.
  Control 8 exists so that control 7 is known to be measuring something; control 8b asserts the
  silence rather than describing it.

They are run under **both** interpreters — `bash` (brew's 5.x) and `/bin/bash` (macOS's 3.2.57) —
because ADR-0028's whole lesson is that a portability claim is worth what its execution under the
target interpreter is worth. Every control passes under both.

### 7.1 And three more, run against a REAL harness

Fixtures can be built to fail. The same two failures were therefore also produced on `m0-boot`
itself, unmodified except for the one line each control changes:

| | Observed |
|---|---|
| floor raised 9 → 99, harness otherwise untouched | `exit 1` — `M0-boot: FAIL — only 9 of the 99 declared checks executed` |
| Step 2's `verify-freestanding` block wrapped in `if false` | `exit 1` — `M0-boot: FAIL — only 6 of the 9 declared checks executed` |
| unmodified | `exit 0` — `ASSERTIONS: pass  9 checks executed, declared floor 9`, then the PASS line |

The middle row is the one worth stopping on. It is **GAP-0167's defect, reconstructed**: the PASS
line still says `-> verify-freestanding pass ->`, the check no longer runs, and every command in the
harness still succeeds. Before this commit that harness would have printed PASS. It now refuses.

---

## 8. Rejected alternatives

* **A `trap DEBUG` counter.** Rejected: it counts every simple command, so the number would be
  dominated by `echo`s and would move for reasons unrelated to checks — a constant in all but name,
  which is exactly what GAP-0168 says the counter must not be.
* **An `assert`-style wrapper taking the condition as a string.** Rejected: §4.
* **Counting only per verification STEP** (one increment per `STRUCTURAL: pass` block, ~10 per
  harness). Rejected: it would not have caught control 2's shape, where the step runs and prints its
  banner but the loop inside it examines nothing.
* **An `OSCORTEX_ASSERTION_HARVEST=1` env var to bypass the floor while re-deriving pins.** Rejected:
  a safety property with an escape hatch is a safety property that will be escaped (the same wording,
  and the same reason, as `verify-freestanding.sh`'s `RESERVED` list). Re-deriving a pin is an edit
  to the harness, visible in a diff, not a flag.
* **`==` instead of `>=` for the floor.** Rejected: §5.
* **One `capture()` for all 86 sites.** Rejected: §3 — it would have silently mis-executed 15 of them.

---

## 9. Consequences

* **88 capture-then-`$?` sites converted** across 20/20 harnesses (86 from the survey class, plus the
  two `hdiutil attach` sites that read `$?` on the following line). One `$?` read remains, §6.
* **1191 `ck` sites** inserted across the 20 harnesses. At runtime the suite executes **2783 checks**,
  and the per-harness floors are pinned at what a green run reports: 9 (`m0-boot`), 10 (`mb-info`),
  23, 33, 61, 86, 133 (`m5-pci`), 119, 218, 232, 221, 240, 235, 142, 101, 199, 205,
  268 (`m16-filewrite`), 100, 148 (`m19-argv`). The gap between 1191 static sites and 2783 executed
  checks is the point: the number is a property of the path taken, not of the text.
* Every embedded Python/awk heredoc body is **byte-identical** to before the conversion, verified
  mechanically rather than by inspection — the instrumenter's heredoc, quote and `$( )` tracking is
  the part most likely to be subtly wrong, so it is the part with a machine check on it. Every
  harness also parses under `bash -n` **and** `/bin/bash -n`, and the whole conversion was reviewed as
  a `ck`-stripped diff so that the 88 semantic changes could be read on their own.
* **The instrumenter itself is deliberately NOT checked in.** It was a one-shot: its output is the
  artifact, the placement rules it applied are §4.1 above in prose, and a new check gets its `ck` by
  hand. A migration script left lying around is one that eventually gets re-run over already-migrated
  files, which here would mean double-counting — and the floors would not notice, because they only
  catch counts going DOWN.
* GAP-0156's site table is corrected from 135 to 86 in the same commit, and gains the note that
  `set -e`'s prerequisite is now met.
* GAP-0167 stays CLOSED. GAP-0168 is CLOSED. GAP-0176 is opened for the one thing this does not do:
  nothing runs `_lib/controls/run.sh` automatically, exactly as nothing runs ADR-0028's freestanding
  controls automatically.
* **What this does not claim.** The count proves the checks were REACHED. It does not prove any of
  them is a good check — `ck; [[ 1 -eq 1 ]] || fail` counts like any other. That is a code-review
  property, and this is not a substitute for one. What it rules out is the family where the harness
  printed a verdict about work it never did.
