# ADR-0028 — The rule-1 check must run on the bash macOS actually ships. **It did not, and `set -e` was the only thing standing between that and a vacuous pass.**

**Status:** accepted, implemented, verified (three negative controls, §5, run under `/bin/bash` explicitly)
**Date:** 2026-08-26
**Part of:** a fix batch, not a milestone. No `ROADMAP.md` entry.
**Records:** GAP-0155, GAP-0156. **Also found, not fixed:** GAP-0157 (an `m9-ring3` flake), GAP-0167
(`m19-argv`'s PASS line claims a `verify-freestanding` run that does not exist — the same defect as
this ADR's, in its purest form; escalated, see §8).
**Touches:** `core/scripts/verify-freestanding.sh`, and `m8-paging` / `m9-ring3` / `m13-libc`'s harnesses.

---

## 0. What was wrong

`core/scripts/verify-freestanding.sh` is the mechanical guarantee behind CLAUDE.md rule 1 — the
project's spine. It used **`mapfile`** in three places. `mapfile` arrived in **bash 4.0**. macOS ships
**`/bin/bash` 3.2.57**. Reproduced before any change was made:

```
$ OSCORTEX_ALLOWLIST=core/tools/bare-symbol-allowlist.txt \
    /bin/bash core/scripts/verify-freestanding.sh core/build/kernel.elf
core/scripts/verify-freestanding.sh: line 70: mapfile: command not found
EXIT=127
```

**Why nobody saw it.** `env.sh` line 10 prepends `/opt/homebrew/bin` to `PATH`, which supplies bash
5.3.15, and sourcing `env.sh` is mandatory project setup. The script's shebang is `#!/usr/bin/env
bash`, so it found brew's bash every time. Every freestanding sweep ever run in this repo used a bash
where `mapfile` works. **The environment that grew around the work hid the state of the work** — the
check was broken on the interpreter the platform actually provides, and the setup step that made the
project usable was also the step that made the breakage invisible.

**How close this came to being silent.** It failed *closed*, at exit 127, for one reason only: `set
-euo pipefail` is on. Take `set -e` away and `mapfile` failing leaves `undef` **unset**; the loop over
it examines nothing; `leaked` stays empty; and the script prints

```
FREESTANDING: pass  core/build/kernel.elf
```

**having checked zero symbols.** A vacuous pass on the spine — the exact failure mode where a green
result and an unexamined one are printed with the same words. A sibling repo (DCDart) carried the
identical defect and has already fixed it.

## 1. The decision

**`verify-freestanding.sh` and every conformance harness must run under bash 3.2**, because that is
what `/bin/bash` is on this platform, and a check whose correctness depends on which `bash` happened
to be first on `PATH` is not a check. Three rules follow, and each is written into the script's own
header so the next person inherits the reason and not just the code:

1. **No bash-4 builtins** — `mapfile`, `readarray`, `declare -A`.
2. **Every array expansion that can be empty uses `${arr[@]+"${arr[@]}"}`.** Under bash 3.2 with `set
   -u`, `"${arr[@]}"` on an **empty** array is an unbound-variable abort. This is not hypothetical
   here: see §3.
3. **No GNU regex extensions.** POSIX classes only. See §4.

## 2. `nm`'s exit status is now checked, and a failed `nm` is FATAL

The old line was:

```bash
mapfile -t undef < <("$NM" -u --format=posix "$obj" 2>/dev/null | awk '{print $1}' | sed 's/^_//')
```

which lost `nm`'s status **twice over**: a pipeline reports `awk`'s status, not `nm`'s, and a process
substitution's status is never examined at all. `set -o pipefail` could not help, because nothing
consumed that status. `2>/dev/null` then discarded the reason. Measured on the unmodified script:

```
$ NM=/bin/false; out=$("$NM" -u --format=posix core/build/kernel.elf 2>/dev/null | awk '{print $1}' | sed 's/^_//')
status_of_pipeline=0 output=[]
```

**Status 0, output empty — which is exactly what a genuinely clean object produces.** Every conclusion
this script draws is drawn from the **absence** of a symbol, so a broken, missing or
wrong-architecture `nm` is *indistinguishable at the point of use* from a kernel that links
freestanding. The old code reported the wrong one of those two as `FREESTANDING: pass`.

`nm` is now run on its own, its status captured explicitly, its stderr sent to a temp file (not
`2>&1`, which would fold warnings into the symbol list and parse them as symbol names), and a
non-zero status is **FATAL, exit 2** with the diagnostic echoed. It does not fall through to a pass.

## 3. The trap that was NOT walked into: no non-vacuity guard on the allowlist

The obvious next move — and the one the sibling repo made — is to assert by symmetry that the
allowlist parsed to **more than zero** entries. **That is wrong here, and it is recorded as a decision
so it is not "fixed" later.**

`core/tools/bare-symbol-allowlist.txt` has **zero** non-comment entries, and says so in its own
header: *"Empty by design -- nothing built so far needs anything allowlisted."* The freestanding
baseline **genuinely permits zero symbols**. A guard asserting non-emptiness turns the correct
configuration into a hard FATAL.

> **Asserting the non-emptiness of something designed to be empty is the same defect as a vacuous
> pass, pointed the other way.** Both replace a real question with one whose answer was fixed in
> advance.

**A vacuity guard is only correct where the empty case is genuinely impossible.** That is the test
applied throughout this change, and it is why there is a guard on `nm`'s output path (where empty is a
state the script *cannot distinguish*) and none on the allowlist (where empty is the *expected and
correct* state). The same test is why `"${RESERVED[@]}"` is left unguarded — it is a literal defined
three lines above and deliberately not configurable, so it cannot be empty — with a comment saying so.

This is also the concrete reason rule 2 in §1 was not optional: `ALLOWED` is empty by design, so
`for a in "${ALLOWED[@]}"` would have aborted on the very first non-reserved undefined symbol.

## 4. The GNU-isms — and the one that was actively wrong, not merely non-portable

The script used `grep -vE '^\s*(#|$)'` and `sed 's/\s*$//'`. `\s` is a GNU extension, not POSIX ERE.
Measured on this machine rather than assumed:

* **`/usr/bin/grep -E` accepts `\s`.** It happened to work. Still changed — a check that relies on an
  undocumented extension of whichever `grep` is first on `PATH` is one `PATH` change from silent
  breakage.
* **`/usr/bin/sed` does NOT.** BSD `sed` reads `\s` as a **literal `s`**, so `s/\s*$//` means *"delete
  trailing `s` characters"*:

  ```
  $ printf 'dc_args\n__aeabi_*s\nmemclrs\n' | /usr/bin/sed 's/\s*$//'
  dc_arg
  __aeabi_*
  memclr
  ```

  So it never stripped trailing whitespace — and it **corrupted symbol names ending in `s`**. Worst
  case is the second line: an allowlist glob `__aeabi_*s` silently became `__aeabi_*`, which **permits
  strictly more than its author wrote.** A parser that widens an allowlist entry is the same class of
  problem as everything else in this ADR — the file no longer means what it says.

Both are now `[[:space:]]`. The parse was diffed old-against-new on a synthetic allowlist exercising
comments, indented comments, blank lines, whitespace-only lines, trailing whitespace and a glob ending
in `s`: **identical, except that trailing whitespace is now actually stripped and `__aeabi_*s` now
survives as written.**

Leading whitespace on an entry is still retained, exactly as before. That is a latent oddity, but
changing it would change *what the allowlist permits*, which is a semantic change to the spine and not
this ADR's to make. Recorded in GAP-0155.

## 5. The three controls

Green on a rewritten check proves nothing on its own — a vacuous pass is green too. So the fix is
demonstrated by **negative** controls, run with **`/bin/bash` explicitly**; `env bash` finds brew's
bash 5 and would prove nothing.

| # | control | expected | observed |
|---|---|---|---|
| 1 | clean object, no undefined symbols | exit 0, reports pass | `FREESTANDING: pass` — **exit 0** |
| 2 | object with undefined **reserved** `dc_alloc` | exit 1, reports the leak | `FREESTANDING: FAIL` + the `dc_alloc` diagnostic + the RESERVED note — **exit 1** |
| 3 | `NM=/bin/false` (and a script that exits 1) | **FATAL, exit 2, NOT a pass** | `FATAL: ... failed` + refusal text — **exit 2** |

Two further controls, because control 2 short-circuits at `is_reserved` and never reaches the loop
over the **empty** `ALLOWED` array — the precise line rule 2 exists for:

| # | control | observed |
|---|---|---|
| 2b | object with a **non-reserved** undefined symbol | `FREESTANDING: FAIL`, exit 1 — the empty-`ALLOWED` loop is traversed and does not abort |
| 2c | the same object with an `.externs` manifest | `FREESTANDING: pass ... (1 declared extern(s): some_c_helper)`, exit 0 |

And an **equivalence** check, which is the one that shows behaviour did not drift: the pristine script
under bash 5 versus the new script under `/bin/bash` 3.2, across `boot.o`, `isr.o`, `kdata.o`,
`kmain.o`, `portio.o` and `kernel.elf` — **byte-identical output and identical exit codes on all
six** (two of which legitimately FAIL, so the comparison covers the failure path too).

The real kernel passes under `/bin/bash` 3.2, under brew's bash 5, and via its shebang.

## 6. The same defect class in three harnesses

`declare -A` is also bash 4+, and appeared in `m13-libc:248`, `m8-paging:174` and `m9-ring3:158`.

Under bash 3.2 `declare -A` fails, and the following `SYM[__kernel_start]=...` is then an **indexed**
array assignment whose subscript is evaluated as **arithmetic** — so `__kernel_start` is an unbound
variable and the harness aborts at exit 127, mid-run, **after** printing several `STRUCTURAL: pass`
lines.

**All twenty harnesses in this repo use `set -uo pipefail` and none has `set -e`.** So `set -u` was
the only thing making this loud — and it is load-bearing by accident, not by design: had the subscript
been a *defined* numeric variable it would have silently collapsed to index 0 and the harness would
have carried on with a corrupt map. Recorded as GAP-0156.

**Fixed rather than refused**, because a fix was proportionate: every key in all three maps is fixed at
authoring time and is a valid identifier, so `m8`/`m9` hold the map as ordinary `SYM_<key>` /
`SEL_<key>` variables read through a one-line accessor, and `m13`'s literal became the *"name const
file"* triple list that the section immediately below it already used. Every assertion and every
failure message is unchanged. The accessors deliberately have **no `:-` default**, so a mistyped key
stays a loud unbound-variable abort exactly as an associative array under `set -u` would.

A `declare -A` grep found only the declarations; **running the harness under `/bin/bash` found five
more `${SYM[...]}` expansions further down `m8-paging`** that the grep had missed. Recorded because it
is the general lesson of this ADR: the compatibility claim is only worth what the *execution* under
the target interpreter is worth.

## 7. Rejected alternatives

* **Require bash 4+ and refuse to run otherwise.** Reasonable for the harnesses, wrong for
  `verify-freestanding.sh`: rule 1 says run it on *every* kernel change, and a spine check that
  refuses on the platform's own `/bin/bash` invites being bypassed.
* **Change the shebang to `#!/opt/homebrew/bin/bash`.** Hard-codes one machine's Homebrew prefix and
  makes the environment *more* load-bearing, which is the cause of this ADR, not a fix for it.
* **Add the non-vacuity guard on the allowlist.** §3.
* **Keep `2>/dev/null` on `nm` and just check the status.** The status says a failure happened; the
  stderr says *why*. Both are kept, and the stderr is echoed only on failure.

## 8. What this unit found and did not fix

Two things surfaced while proving the above, both recorded rather than quietly taken:

* **GAP-0167 — `m19-argv` claims a `verify-freestanding` run it does not make.** Its PASS message
  reads `... -> verify-freestanding -> FOUR real QEMU boots`, and that sentence is the *only*
  occurrence of the string in the harness. Every other harness invokes it four or five times and
  checks the status. This is the defect of this ADR in its purest form — not a check that concludes
  from nothing, but a **claim with no check under it at all** — and it is the more dangerous shape,
  because the claim is what a reader audits and re-running the harness will never contradict it. Rule
  1 is still enforced on the same objects by seven other harnesses, so this is a missing assertion and
  a false sentence, not an unguarded kernel. Not fixed here only because this unit was scoped to the
  freestanding script and the three `declare -A` harnesses.
* **GAP-0157 — `m9-ring3` is flaky.** An intermittent RFLAGS.RF bit in the ring-3 register dump makes
  its byte-exact serial golden non-deterministic. Observed once here, then passing on retry under both
  bash 3.2 and bash 5, and the *pristine* pre-change harness passed too — so it is not caused by this
  change. Previously unrecorded, and distinct from the known `m12-heap` flake.
