# The shared files every kernel subsystem must edit, and what would remove that requirement — a design, not yet a decision

**Status: DESIGN. Nothing implemented. No file outside this one was touched to produce it.** Every
count below was measured with `grep`/`sed` against the tree as it stands (M19 done, `shellStrHelp` at
2224 bytes) and the command is given so it can be re-measured. When a piece of this is built it gets
its own numbered ADR; this file is what those ADRs point back at.

**The question this answers, and only this question:** which files must EVERY new kernel subsystem
edit, what mechanism would remove that requirement, and — for N agents working in separate worktrees —
what actually collides at merge time.

---

## 0. The answer for a reader in a hurry

| shared file | what a new subsystem must add | how often | verdict |
|---|---|---|---|
| `core/kernel/kmain.dart` | **two lines**: one `part` and one `<sub>Init()` call — and **both** positions are load-bearing, for two different reasons | **every subsystem, always** | **fixable today.** No DCDart feature needed — generate the library root at build time |
| `core/kernel/shell.dart` | an `if` arm in `shellExecute` **+ bytes appended to the `shellStrHelp` byte array + a hand-maintained length at its call site** | 9 of 18 subsystems so far | **fixable today** (generation), but it is the largest fan-out and the fix is bigger |
| `core/kernel/user.dart` | an `if (no == …)` arm in `userSyscall`, and a syscall number picked from a namespace with **no registry** | 5 subsystems, 11 syscalls | **partly fixable today.** The chain can be generated; a real *table* needs DCDart function pointers |
| `core/kernel/interrupts.dart` | an `if (vector == …)` arm in `isrDispatch` | 2 subsystems in 19 milestones | **leave it.** Not hot enough to pay for |
| 11 × `run.sh` structural constants, 5 × byte-exact goldens | regenerated numbers and captures | every subsystem that prints or adds storage | **inherently serial.** Git merges these cleanly and the result is wrong |
| `core/scripts/build-kernel.sh` | nothing, unless a new `.S` file is added (4 are hand-listed) | 4 times in 19 milestones | **leave it** |

**The one change to make first: generate `core/kernel/kmain.dart` at build time from a one-line
declaration in each subsystem's own file.** It is the only file *every* subsystem must edit, it needs
no DCDart language feature, it is roughly 60 lines of shell/Dart in `build-kernel.sh`, and it converts
the two most-contended lines in the repo into a per-file declaration plus one integer whose collisions
the generator can *fail* on instead of silently mis-ordering. §5.

**Two findings worth putting above the fold:**

1. **The most-edited shared file is not the most dangerous one.** The dangerous conflicts are the ones
   git resolves without complaining: two agents each regenerating their own goldens and a merged kernel
   that matches neither (§5.1), and two agents both claiming syscall number 11 in two different files
   (§2).
2. **`kmain.dart`'s `part` list is not the free, order-free half it looks like.** `@bss` blocks are
   emitted in part order and every harness measures "from my block to the end of `.bss`", so the part
   list is append-only in the same load-bearing way the init sequence is topological — and two agents
   who each correctly append their file *last* cannot both be last after a merge (§1, §5.3).

---

## 1. `core/kernel/kmain.dart` — one file, two conflict points, 100% of subsystems

Measured: `grep -c "^part '" core/kernel/kmain.dart` → **18**. Init calls in `kmain()` → **12**
(`vgaInit`, `shellInit`, `fbInit`, `pmmInit`, `vmInit`, `userInit`, `elfInit`, `procInit`, `fatInit`,
`fileInit`, `uartInit`, `pitInit`).

**Conflict point 1 — the `part` list.** This is a *compilation-unit* constraint, not a design choice:
`dcc` compiles one library per object file and a `@bare` function in an *imported* library is not
compiled at all (kmain.dart's own header; known-gaps GAP-0004 item 4). Every one of the 18 kernel files
carries `part of 'kmain.dart';` — verified: `grep -h "^part of" core/kernel/*.dart | sort | uniq -c`
gives 18 identical lines. A new file that is not listed does not fail loudly at the source level; it
fails at link as a missing symbol (now a hard `dcc` error, but still a *build* error rather than a
merge one).

**And the `part` order is load-bearing too, which is easy to miss.** Parts are a textual union at the
language level, but `@bss` blocks are emitted in part order, and every harness from M2 onward measures
"the donated bytes from MY block to the end of `.bss`". `m19-argv/run.sh:132-144` states it outright:
`argsStore` is declared in `args.dart`, "which kmain.dart lists LAST… That is not a filing preference…
a new block anywhere other than the end would change every one of those numbers at once. At the end,
each older harness subtracts this one first and its own number keeps meaning in 2026 what it meant when
it was written." M14, M15, M16, M18 and M19 each appended in turn, and the running total (14368 bytes)
is arithmetic over that order.

So `kmain.dart` carries **two independent orderings** — part order, constrained to append-only by the
`.bss` accounting, and init order, constrained topologically — and a mechanism that respects one and
not the other breaks the suite.

**Conflict point 2 — the init sequence.** The order here is the opposite: it is load-bearing in at
least five separate, individually documented ways, and kmain.dart spends ~140 lines of comment saying
so. Three constraints are worth restating because any mechanism has to preserve them:

* `pmmInit()` **after** `shellInit()`, because it reads the Multiboot pointer out of the word
  `shellInit()` stashed it in;
* `vmInit()` **after** `pmmInit()`, because page tables come from `allocFrame()`;
* everything above **before** `uartInit()`, because nothing in that prefix may print a byte —
  `m1-interrupts/run.sh` asserts the entire 544-byte capture and one diagnostic line there breaks a
  green milestone.

So the init list is a *topologically ordered* sequence, and "resolve the conflict by keeping both
lines" is a mechanically plausible resolution that can be silently wrong. That is the property that
makes this file worth fixing rather than merely annoying.

**Verdict: fixable today, no DCDart feature required.** §5.

---

## 2. `core/kernel/user.dart` — 11 syscalls, and a number namespace with no owner

`userSyscall(u64 frame)` at user.dart:1527. Measured: **11** `if (no == …)` arms
(`sed -n '1527,1640p' core/kernel/user.dart | grep -c "if (no == "`), falling through to
`userRefuse(...)`. The shape:

```dart
  if (no == u64(fileSysOpenNo)) {
    fileSysOpen(frame);
    return;
  }
```

with four of the eleven wrapping the call in a per-arm precondition (`procLive() < u64(1)` →
`userRefuse`), because `yield`, `preempts` and `sbrk` require a *process* and the file syscalls
require only an *owner row*.

**The chain is not the worst part of this file.** The syscall numbers are `const int` declarations
scattered across four files with nothing in between them:

| number | constant | file |
|---|---|---|
| 0, 1, 2 | `userSysExitNo`, `userSysWriteNo`, `userSysWhoNo` | `user.dart:731-733` |
| 3, 10 | `procSysYieldNo`, `procSysPreemptsNo` | `proc.dart:294, 309` |
| 4 | `heapSysSbrkNo` | `heap.dart:142` |
| 5, 6, 7, 8, 9 | `fileSysOpenNo` … `fileSysWriteNo` | `file.dart:256-276` |

There is no registry, no reservation, and no check. **Two agents in two worktrees both writing
`const int fooSysNo = 11;` in two different files produce a clean git merge and a kernel where the
first arm in the chain silently wins.** The corresponding constants are also mirrored by hand into
`core/user/libc`'s `oslibc.h` (m13-libc's run.sh reads all eleven numbers back out of `user.dart`,
`proc.dart` and `heap.dart` — that harness check is the only thing that currently notices anything
about this namespace at all, and it notices divergence, not collision).

**Can the chain become a table today?** No, not as a table of *handlers*. `@bare` DCDart has no
function pointers and no way to take the address of a function (known-gaps GAP-0002; ADR-0006;
`isrDispatch`'s own doc comment says it in one sentence). What DCDart *does* have since ADR-0040 is
static data tables — `@rodata List<u64>` with `Rodata.addressOf` and `@bss` blocks with
`Bss.addressOf` — so a table of *numbers*, *flags* or *offsets* is expressible and is already used
(GAP-0088's six-byte `userCodeLen` table indexed by mode). A table of code addresses is not.

**What it would take, named for whoever owns the DCDart requirements list:**

1. **Address-of-code.** Some spelling of `Code.addressOf(fn)` yielding a `u64`, legal inside `@bare`,
   for a `@bare` function *and* for an `@extern` symbol. The `@extern` half is already an independently
   recorded need (known-gaps: the `isr_stub_table` "falls to read-only data by category… not achievable
   today, because building it in DCDart needs address-of-extern").
2. **An indirect call** through a `u64`, at a *statically declared* C-ABI signature — e.g. a
   `callIndirect<...>` primitive or a real function-pointer type. Without (2), (1) only lets DCDart
   *build* a table for something else to jump through.

**There is a workaround shape available today, and this document recommends against it.** `isr.S`
already contains exactly the missing mechanism: `isr_stub_table` is 256 quads of code addresses built
by a `.rept` loop, handed to DCDart as a bare `u64` by `isr_stub_table_addr()`, and *the CPU* does the
indirect jump when it takes an interrupt. A general `dispatch_call(index, arg)` trampoline in assembly
(`call *table(,%rdi,8)`) would give the whole kernel table dispatch this afternoon. It is also
precisely what CLAUDE.md rule 3 forbids: "Never build a workaround inside oscortex_core for something
that's really a DCDart-language gap." The IDT case is defensible because the indirect jump is
*hardware's*, not ours; a syscall trampoline would not be.

**Verdict: the *chain* is fixable today by generation (§6); the *table* needs DCDart features 1 and 2;
the *number namespace* is fixable today and is cheaper than either.**

---

## 3. `core/kernel/interrupts.dart` — measured, and not actually hot

`isrDispatch(vector, errorCode, rip, frame)` at interrupts.dart:477. Arms: timer (0x20), keyboard
(0x21), syscall (0x80), breakpoint (3), then the fault fallback which is the interesting half of the
function (phase-0 vs phase-1 recovery, `userOnFault`, `fault_resume`). **Four vector arms in nineteen
milestones**, and no new IRQ since M2's keyboard.

Nothing else is needed to add a vector: `isr.S` builds all 256 stubs with a `.rept` loop
(`isr_stubs + N*16`), and `idtInstallAll()` installs all 256 from `isr_stub_table`. So an IRQ costs
*one* arm in *one* function, plus an unmask call.

**Verdict: leave it.** The comment in the file is right — "with three interesting vectors that is not a
cost worth noting; at thirty it would be." A driver-heavy milestone (AHCI, NIC, HPET, APIC) is what
changes that, and it changes it for the same reason and with the same fix as the syscall chain. Do not
pay for it before then.

---

## 4. `core/kernel/shell.dart` — the largest fan-out in the repo, by a wide margin

Measured in `shellExecute` (shell.dart:1260-1557): **48** `shellIsCmd`/`shellStartsWith` arms. But the
`if` chain is the *cheap* part. Adding one shell command touches:

1. **the arm** in `shellExecute`, whose position is load-bearing — exact matches must precede prefix
   matches or `crash ud` prints a usage line (known-gaps GAP-0057 item 5);
2. **a `@rodata` name table** for the command's bytes (fine — it lives in the subsystem's own file);
3. **`shellStrHelp`**, a hand-encoded `final List<u8> shellStrHelp = const [u8(0x63), u8(0x6F), …]`
   at shell.dart:173 — every command must appear there or it is undiscoverable;
4. **the length literal at its one call site**: `uartWrite(Rodata.addressOf(shellStrHelp), u64(2224));`
   — a `@rodata` table carries no length (GAP-0060), and the number has been 237 → 395 → 1658 → 1871 →
   2147 → 2224 over six milestones;
5. **11 harness structural checks** that hardcode that number:
   `grep -rn "check_table shellStrHelp" core/tests/conformance/*/run.sh | wc -l` → **11**;
6. **5 byte-exact goldens** that contain the whole help listing:
   `grep -ln "commands:" core/tests/conformance/*/expected*.txt` → m3-shell, m4-fault, m5-pci, m6-disk,
   m14-fat;
7. **and, historically, a timing constant** — GAP-0105: `help` growing past ~160ms of serial output
   made three harnesses fail *intermittently at exactly the help boundary*, because `qmp-drive.py`
   injects a keystroke every 50ms.

That chain of consequences already has five known-gaps entries attached to it (GAP-0059, GAP-0065,
GAP-0069, GAP-0072, GAP-0075/0105) and GAP-0075 states the fix explicitly: "a `help` whose text is
generated from the command table rather than being a literal — which needs a command table, which needs
function pointers, which `@bare` DCDart does not have."

**That last sentence is half right, and the half that is wrong is the useful half.** Generating *help
text* needs only a table of **names and descriptions** — pure data, expressible today, and the length
can be emitted by the generator instead of typed by a human, which deletes GAP-0060 for this table
outright. Only generating the *dispatch* needs handler addresses — and dispatch can be *generated as an
if-chain of direct calls* rather than executed as a table, which also needs no language feature.

What generation does **not** fix: `help` growing still moves five goldens, because the goldens capture
what the kernel prints and `help` prints more. That is inherent (§5 of GAP-0075 is right to refuse the
"assert everything except the help block" alternative). What it fixes is that the *source* conflict and
the eleven hand-maintained numbers disappear.

**Verdict: fixable today, second priority.** Bigger than kmain's fix, and it should be done with
kmain's generator already in place rather than as a separate mechanism.

---

## 5. What actually conflicts with N agents in N worktrees — ranked

Ranked by **expected damage**, which is frequency × severity × how likely a wrong resolution is to
survive review. Not by how often git prints `<<<<<<<`.

### 1. The byte-exact goldens and the harness structural constants — *the worst, and git never says a word*

There are 34 `expected*.txt` files and 20 `run.sh` harnesses. The harnesses hardcode, among other
things, `shellStrHelp`'s byte size (11 sites), every `@rodata` table's size (`check_table` appears 61
times in m10-elf's run.sh alone, 54 in m7-frames, 50 in m8-paging, 49 in m9-ring3), and the total
donated `.bss` size (5368 → 5496 → 9664 across milestones).

Two agents in two worktrees each add a subsystem, each run `--regen`, each commit a green tree. **Git
merges both cleanly — different files, different lines, no conflict markers — and the merged kernel
matches neither set of goldens.** Every affected harness has to be re-run and re-derived *after* the
merge, on the merged tree, serially. There is no mechanism that removes this: a byte-exact golden is a
statement about the whole program, and two changes to the whole program do not compose.

**Verdict: inherently serial.** The mitigation is scheduling, not code: goldens are regenerated once,
on the integration branch, by whoever merges — and CI must run the full conformance suite on the
*merge result*, never only on each branch. If only one thing in this document is adopted, it should be
that CI rule, because it is the only one of these failures that is currently invisible.

### 2. `shell.dart` — the highest textual conflict probability, and the least mechanical resolution

Two agents adding commands both append arms near the end of `shellExecute` **and** both append bytes to
the same `const [...]` literal **and** both change the same `u64(2224)`. That is three overlapping
edits in one file, one of which is a hex-encoded byte array where a hand merge is genuinely
error-prone, and the resolution requires recomputing a length that nothing but a golden will check.

### 3. `kmain.dart` — near-certain conflict, mechanical resolution, *but a wrong resolution is silent*

Everyone appends a `part` line at the end of an 18-line block and an init call into a clustered region.
It looks like "keep both lines" and it is not, in **both** halves:

* the init order is topological (§1), and "keep both lines, in whichever order the merge tool picked"
  can produce a kernel that reads a Multiboot pointer out of un-zeroed `.bss`, or prints a byte before
  `uartInit()` and breaks a 544-byte golden;
* the part order decides `.bss` layout (§1), and **two agents who each correctly append their file last
  cannot both be last after a merge.** Whichever one loses had a harness measuring "from my block to
  the end of `.bss`", and that number is now wrong — in a file neither agent touched.

Frequency is 100% of subsystems, which is why it ranks above the syscall chain despite each individual
edit being smaller.

### 4. `user.dart` — lower frequency, but carries the only *undetectable* collision

The chain conflicts the same way kmain's init list does. The number namespace (§2) is the real hazard:
duplicate syscall numbers merge clean, build clean, boot clean, and mis-dispatch. Ranked below shell
and kmain only because syscalls are added less often.

### 5. `interrupts.dart` — barely participates

Two arms added in nineteen milestones. It is on this list for completeness.

### Not on the list, deliberately

`build-kernel.sh` hand-lists four assembly objects (`boot isr kdata portio`) and the link order. New
`.S` files have appeared four times in nineteen milestones, and every one of them deserved the
discussion the edit forces. `core/tools/bare-symbol-allowlist.txt` is empty by design and must stay
that way. `kernel.ld` is edited for genuinely architectural reasons only.

---

## 6. The recommendation: generate the library root

**Change one file — `core/scripts/build-kernel.sh` — so that `core/kernel/kmain.dart` is produced by
the build instead of edited by hand.**

### The mechanism

Each subsystem declares itself, in **its own file**, with one magic comment the generator greps for.
A comment, not an annotation, because `@bare` DCDart annotations would have to survive into Kernel IR
to be readable and nothing needs them to:

```dart
// core/kernel/pmm.dart
// @kunit part=100 order=40 init=pmmInit
part of 'kmain.dart';
```

`part=` fixes the file's position in the `part` list; `order=` fixes its position in the init sequence.
They are two different orderings (§1) and conflating them would be the mechanism's first bug: `args.dart`
is *last* in the part list and has *no* init at all.

`build-kernel.sh` gains a pre-step that:

1. globs `core/kernel/*.dart` (excluding the generated root) and emits the `part` list **sorted by a
   second declared key, `part=`, not alphabetically** — see the warning below;
2. reads every `// @kunit` line, sorts by `order`, and emits `void kinitAll()` as a straight sequence
   of direct calls;
3. **fails the build** on a duplicate `order`, a duplicate `part=`, a `@kunit` naming an init function
   that does not exist in that file, or a `.dart` file with no `part of 'kmain.dart';` line;
4. writes the result to `core/kernel/kmain.dart`, which becomes **generated and git-ignored**.

The hand-written half of today's `kmain()` — the M1 sequence, the deliberate `#UD`, all 140 lines of
ordering rationale — moves to a new ordinary part file (`core/kernel/boot_seq.dart`), which defines
`@bare void kmain(u64 mbInfo)` and calls `kinitAll()` first. Nothing about the emitted code changes:
same library, same object file, same direct calls, same order.

### Why this and not something cleverer

* **It needs nothing from DCDart.** Generated source contains direct calls in a fixed order, so no
  function pointers, no indirect call, no arrays. The two DCDart features named in §2 stay on someone
  else's list, unblocked and un-urgent.
* **It cannot trip GAP-0088.** There is no dense constant chain here — just a straight-line sequence of
  calls. (This is exactly why the *syscall* chain is the second change and not the first: an 11-arm
  chain over the dense integers 0..10, regenerated into perfectly regular shape, is the ideal input for
  LLVM's switch-to-jump-table lowering, and GAP-0088 says the section that table lands in is not
  something this repo controls. Any generated dispatch chain must be re-checked against
  `m1-interrupts`' "every OBJECT symbol lives in `.rodata`'s section index" assertion, and the
  generator should probably emit the arms in non-monotonic order on purpose.)
* **It removes a shared file from git entirely.** Not "reduces conflicts in" — removes. After this
  change a new subsystem is *one new file*, with zero edits to any existing kernel source, provided it
  adds no shell command and no syscall.
* **It converts a silent mis-order into a build failure.** Two agents who both pick `order=40` get a
  hard error naming both files. Today they get a clean merge and a boot-order bug. Leave gaps of 10
  between orders and hand out ranges per milestone, the way IRQ numbers are handed out.

### What it costs, stated rather than discovered later

* **One harness check breaks and must be updated in the same commit**: `m9-ring3/run.sh:390` greps
  `core/kernel/kmain.dart` for `^\s*idtSetUserGate\(\);`. It should point at `boot_seq.dart`. This is
  the *only* such grep — verified with `grep -rn "kmain.dart" core/scripts core/tests/conformance/*/run.sh`.
* **A generated root that is git-ignored is a file a reviewer cannot see.** The generator must print
  the emitted init sequence during the build so it appears in every harness log, and `build-kernel.sh`
  should refuse to overwrite a `kmain.dart` that lacks the generated-file banner (so nobody's local
  hand-edit is destroyed silently).
* **`part of 'kmain.dart';` is a relative URI**, so the generated root must be written to
  `core/kernel/kmain.dart` and nowhere else. Generating into `build/` would require rewriting all 18
  `part of` lines to a library-name form; do not.
* **Never sort the part list alphabetically, and never renumber `part=` to tidy it.** `@bss` blocks
  come out in part order and every harness's donated-`.bss` arithmetic is built on it (§1). A new
  subsystem takes the highest `part=` in the tree, always — which is the convention today, just written
  down. The generator should print the part order as well as the init order during the build so a
  reordering is visible in the log rather than only in a failed `bssfield` check.
* **It does not make ordering correct, only explicit.** `order=40` still has to be chosen by someone
  who read §1's three constraints. What changes is that the constraint is written down as a number next
  to the subsystem it belongs to, instead of as a comment next to a line in a file everyone edits.

### The order to do these in

| | change | needs | why not first |
|---|---|---|---|
| **1** | **Generated library root** (this section) | nothing | — |
| **2** | **A syscall number registry**: one `@rodata`-free header of `const int`s, or a generator check that no two `*SysNo` constants collide, cross-checked against `oslibc.h` | nothing | ~20 lines, but only 5 subsystems touch it |
| **3** | **Generated `shellExecute` + generated `shellStrHelp` + generated length** from `// @kcmd` declarations | nothing; must be re-checked against GAP-0088 | biggest win, biggest change; wants the §1 generator to exist first |
| **4** | **Generated syscall dispatch chain** | nothing; GAP-0088 caution applies hardest here | 11 arms is not yet painful |
| **5** | **Real table dispatch** for syscalls, shell commands and IRQ vectors | **DCDart: address-of-code + indirect call at a declared C-ABI signature** | not this repo's to build (CLAUDE.md rule 3) |

Changes 1-4 are all the same mechanism applied four times, and none of them waits on DCDart. Change 5
is the only one that does, and by the time it lands, 1-4 will have already told us the exact shape the
table wants.
