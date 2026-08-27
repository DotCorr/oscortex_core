# ADR-0039 — The four guards ADR-0034 left behind: two deleted, one given a caller, one recorded

**Status:** accepted (shakedown)
**Depends on:** ADR-0034 (one launch path)
**Related:** GAP-0214 (`chanRetNoProc`, the first instance of this to be noticed)

---

## 1. What ADR-0034 did to the refusal set, which nobody measured at the time

ADR-0034 merged two launch paths into one: `run <lba>` and `run <name>` now go through
`procCreate`, exactly as `proc run` always did. It is the right change and it is not in question
here.

**Its blast radius on the kernel's refusal coverage was never measured.** GAP-0214 recorded ONE
casualty — `chanRetNoProc`, whose behavioural test had to become structural because every ring-3
program now has a process slot. The shakedown's T3 sweep booted the rest and found **four more**, all
from the same commit:

| code | guard | what happened |
|---|---|---|
| `elfErrLive` (02) | `if (elfLive() > 0)` in `shellElfLoadAndEnter` | **dead by construction** |
| `procErrElfLive` (08) | `if (elfLive() > 0)` in `shellProcRun` | **dead by construction** |
| `elfErrNoFrames` (03) | the loader's `allocFrame` failures | **shadowed** by `procErrNoFrames` |
| `procErrBusy` (02) | `if (procLive() > 0)`, twice | live, unreachable from a synchronous shell |

Each one passes `m10-elf`'s and `m11-proc`'s existing "every refusal code is reachable from a
`return`" census, because that census greps for a `return` and cannot see that **something else
answers first**. That is precisely the difference between reachable as a property of the SOURCE and
reachable as a property of the MACHINE, and it is why the shakedown boots things.

The rule applied to each: **either it is genuinely unnecessary, in which case delete it and say so,
or it is still needed for a caller that is not the shell, in which case keep it and give it a test
that reaches it.** A live guard with no test is the one outcome not allowed.

## 2. `elfErrLive`'s and `procErrElfLive`'s `elfLive()` guards — DELETED

`elfLive()` reads `elfMeta(elfMetaLive)`. After ADR-0034 there is **exactly one assignment to that
word in the entire kernel**:

```
$ grep -rn "elfSetMeta(u64(elfMetaLive)" core/kernel/
core/kernel/elf.dart:1525:  elfSetMeta(u64(elfMetaLive), u64(0));
```

`elfInit` zeroes it and `elfTeardown` zeroes it. **Nothing has written 1 since the M10 window-program
launch was deleted**, so `elfLive()` is a compile-time zero, and both guards were dead code wearing
the shape of a safety check.

That is the worst state a guard can be in. It reads as protection, it satisfies every reachability
census, it costs a branch on every launch, and it cannot fire. Both are deleted.

`procErrElfLive` had no other call site, so the constant, its `procRefuse` branch and its sentence
table `procStrE08` go with it. **The number 8 is not reused** — a refusal code that changes meaning is
worse than a gap in the sequence, because a transcript from an older kernel is still readable.

`elfErrLive` survives, because `shellElfLoadAndEnter`'s *second* guard is a different question:
`userMeta(userMetaLive) > 0` asks whether an M9 payload is in ring 3, and `shellUser` really does set
that flag. See §5.

**What now fails without the deletion:** `m10-elf/run.sh` §2i asserts that `elfMetaLive` has no
non-zero writer **and** that no refusal guard branches on `elfLive()`. Whichever half comes back
first, the other is required with it. Before this commit that check failed, which is what makes it a
test of the change rather than a description of it.

### 2a. What is deliberately NOT deleted, and why

Five *dispatch* sites still ask `elfLive()` — in `userOwns`, `userSyscall` (twice, because `@bare`
DCDart has no boolean operators, GAP-0023), `userOnFault` and `fileOwnsWrite` — where the question is "which of the three things that can be in ring 3 is running",
and the answer is now always "not that one". They are dead branches too, and removing them is a wider
change than a refusal audit should make: it deletes a concept (the M10 window program) from four
files and moves the `.bss` layout. **GAP-0244 records it, with the measurement, so the next person
does not have to re-derive it.** The §2i check tolerates them explicitly and fails only on a guard
that *refuses*.

## 3. `elfErrNoFrames` — KEPT, and given a caller: `frames leave <n>`

The process layer allocates **five** frames before `elfLoadImage` is called at all —
`procSpaceBuild`'s PML4, PDPT and page directory, plus the header and scratch frames `procCreate`
takes for itself. So on a drained allocator the answer is always
`PROC REFUSED 04 the allocator has no frames`, and the loader's own out-of-memory refusal is never
reached. `m10-elf`'s existing no-frames boot proves the launch refuses; it cannot prove **which
layer** refused, and it would go on passing if `elfErrNoFrames` were deleted outright.

The guard is not unnecessary: the loader allocates **eight** frames after `procCreate`'s three, and a
kernel that ran out half way through a segment load and did not say so would map a partial image.
What was missing was a machine state in which the two layers give different answers.

**`frames leave <n>`** is that state. It allocates until exactly `<n>` frames are free, so
`frames leave 5` gives the process layer exactly what it needs and the loader nothing:

```
oscortex> frames leave 5
PMM LEAVE WANT 00000005 TOOK 00007E86 FREE 00000005
oscortex> run 20
ELF REFUSED 03 no free frame
PROC REFUSED 06 the program could not be loaded
```

**The number was not guessed right the first time, and that is worth recording.** The first draft of
this boot used 3 — `procSpaceBuild`'s allocations, which is what the shakedown's write-up named — and
got `PROC REFUSED 04` again, because `procCreate` takes two more after `procSpaceBuild` returns. The
check now derives the number from the source and refuses to derive it at all if `procCreate` grows an
allocation *after* the loader call, which would make the number a lie in the other direction.

`m10-elf/run.sh` step 9b boots exactly that, and requires **four** things: that the partial drain left
the number it asked for; that `PROC REFUSED 04` does **not** appear (or the boot is the old one
again); that `ELF REFUSED 03 no free frame` does; and that `PROC REFUSED 06` follows it, because a
refusal that reaches ring 0 and stops there is GAP-0214 happening one layer up.

`frames leave <n>` is a shell command, so it is in `shellStrHelp` and in `frames`' usage line. That
cost — five goldens — is paid once in this commit, together with GAP-0142's three `proc` lines.

## 4. `procErrBusy` — KEPT, and NOT tested, because nothing in this kernel can reach it

`procErrBusy` guards three sites, two on `procLive() > 0` and one on `userMeta(userMetaLive) > 0`. It
means *"something is already in ring 3; I will not start a second thing"*.

**It cannot be reached, and the reason is a property of the shell rather than of the guard.**
`shellMain` is the only caller of every launcher, and it is not re-entrant: `run` and `proc run` do
not return the prompt until the program has exited and `PROC KILL` has reclaimed it. The one thing
that stays live is a program that never exits — `m10-elf` has a `spin` mutator, `user hold` is one by
design — and such a run never returns the prompt either (GAP-0085), so the second command can never
be typed. Every exit path, including the fault path through `procOnFault`, calls `procSessionReset`
before `shellMain` runs again.

**It is not deleted, and that is a decision rather than an omission.** Deleting a re-entrancy guard
because today's only caller happens to be synchronous is trading a real property for a test result.
Any asynchronous launch — a `spawn` syscall, a second shell, a job control command — reaches all
three sites at once, and the day that lands is not the day to discover the guard was removed for
tidiness.

**What is asserted instead is structural**, and it is stated as weaker than a boot: `m11-proc`'s
refusal census still requires the code to be returned from a live line with its own sentence.
**GAP-0243 records that it is a live guard with no reaching test, names the exact caller shape that
would reach it, and is deliberately worded the way GAP-0214 is** — a guard waiting for a test, not
dead code filed away. This repo already has a precedent for that outcome and it is followed here
rather than invented.

The same reasoning and the same gap cover `shellElfLoadAndEnter`'s surviving `elfErrLive` guard on
`userMetaLive`.

## 5. The two INTENDED shadows, which are a different finding

`procErrArgs` (0A) and `procErrBadLba` (05) are also unreachable from the shell, and unlike the four
above **that is correct behaviour**, not an accident: a shell check answers first, which is defence in
depth working as designed. They are recorded in GAP-0245 rather than changed, and the reasons are not
the same for the two:

* **`procErrBadLba`** is reachable by any caller of `shellProcRun` that does not pre-check its
  arguments — `shellProcArgs` caps both LBAs at `ataLba28Max` and prints the usage line. There is no
  such second caller today. One could be added, and adding one **as a shell command** would be
  circular: the thing under test is what happens when the shell is not in the way.
* **`procErrArgs`** is stronger than shell-unreachable: it is unreachable by **any** caller of the
  launch API. `argsBuild` can only fail if the staged vector plus `argsMinStack` exceeds the stack
  page, and `args.dart` caps staging at `argsMaxCount` = 8 arguments and `argsMaxBytes` = 128 bytes —
  a worst case of 240 bytes against 4096 − 1024. It is a **cross-file consistency guard**, the same
  kind `argsErrNoRoom` already is and already says it is in its own comment. The test that fits it is
  arithmetic, not a boot, and `m19-argv/run.sh` now multiplies the four numbers out and fails if a
  change to any one of them would make the guard reachable — which is exactly when someone needs to
  be told.

## 6. Summary of the six

| code | verdict | what now tests it |
|---|---|---|
| `elfErrLive` (elfLive guard) | **deleted** — dead by construction | `m10-elf` §2i, which failed before |
| `procErrElfLive` | **deleted** — dead by construction, code and sentence with it | `m10-elf` §2i |
| `elfErrNoFrames` | **kept**, given a caller | `m10-elf` step 9b, a real boot |
| `procErrBusy` | **kept**, untested, recorded | `m11-proc` census + GAP-0243 |
| `procErrBadLba` | kept, untested, recorded | GAP-0245 |
| `procErrArgs` | kept, unreachable by arithmetic | `m19-argv` arithmetic check + GAP-0245 |
