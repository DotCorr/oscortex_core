# ADR-0034 — One launch path: `run` creates a process, and `procCreate` builds the argv stack

**Status:** accepted (M20)
**Supersedes the launch half of:** ADR-0014 (ELF loader), ADR-0023 (argv and the initial process stack)
**Depends on:** ADR-0015 (processes), ADR-0016 (a growable user heap), ADR-0023

---

## 1. The defect, stated as it was found

This operating system had **two ways to start a program, and each was missing what the
other had.**

| | `run <name> [args]` (M10/M14, argv added by M19) | `proc run <lbaA> <lbaB>` (M11) |
|---|---|---|
| loads the image | `elfLoad` / `elfLoadFile` | `elfLoad`, via `procCreate` |
| address space | the KERNEL's page directory, entry 128 | its own PML4, built by `procSpaceBuild` |
| process slot | **none** | one |
| initial stack | **System V, built by `argsBuild`** | RSP = `vmProgStackTop`, an empty page |
| heap | **none** | one, `heapInit` at `elfMetaHi` |
| so: | **argv, and `malloc` returns NULL** | **a heap, and no argv** |

`core/kernel/elf.dart` contained **zero** calls to `procCreate`, and
`core/kernel/user.dart` gates `sbrk` behind `procLive() >= 1`. Both facts were correct
in isolation and together they meant **no program on this machine could have arguments
and dynamic memory at the same time.**

It is visible in the test suite itself, which is how sure we can be that it was real:

* `m19-argv/prog.c` — the argv harness — carried the sentence *"NO malloc ANYWHERE.
  `sbrk` is refused unless a PROCESS is live and `run <name>` does not create one"*, and
  every buffer in it is static.
* `m13-libc` — the `malloc` harness — is launched with `proc run 20 a0`, by LBA, with no
  argv at all.

Two harnesses, two launch paths, one capability each. That is a hard blocker on hosting
real C software, which is the project's stated goal.

## 2. Why they diverged, and why that reason is respected rather than bulldozed

The divergence is **structural, not accidental**, and the fix had to keep the structure:

1. **A heap's bookkeeping lives in a process slot.** `heapSlotBase`, `heapSlotBrk`,
   `heapSlotPages` and `heapSlotCalls` are words 16–19 of a `proc` slot, read and written
   through `procGet`/`procSet`. There is no heap without a slot — not as a policy, but
   because there is nowhere to put the break.
2. **The two address-space arrangements are mutually exclusive by design.** An M10 `run`
   program owns page-directory entry 128 of the *kernel's* directory; a process owns its
   own PML4. `procCreate` refuses with `procErrElfLive` when an M10 program is live, and
   `shellElfLoadAndEnter` refused when a process was. They could never coexist.

So "give the M10 path a heap" was never available: it would have meant a second copy of
the heap's storage and a third, hybrid address-space state. **The only way to have one
program with both was to have one launch path**, and the process path is the one with an
address space of its own.

## 3. The decision

**`run` creates a process. `procCreate` builds the argv stack. Neither thing happens
anywhere else.**

Three changes, and the third is the one that makes the first two cheap:

1. **`procCreate(u64 lba, u64 named)`** — the loader selection that
   `shellElfLoadAndEnter` used to make is now a parameter. `named > 0` reads the image
   through an already-open FAT16 chain (`elfLoadFile`); `named == 0` closes any open
   chain and reads contiguous sectors (`elfLoad`). Nothing else differs between the two
   forms, which is why it is one parameter and two `if`s rather than a second function.

2. **`procCreate` calls `argsBuild`** and sets `procSlotRsp` from its result, replacing
   `procSet(s, procSlotRsp, vmProgStackTop)`. A refusal returns the new `procErrArgs` and
   tears the slot down through `procCleanup`, the same path every other refusal uses.

3. **`shellElfLoadAndEnter` no longer loads or enters anything.** It checks the guards,
   opens a cooperative session, calls `procCreate`, reports the vector, and calls
   `procStart`. Its `allocFrame` pair, its `elfLoad` call, its `argsBuild` call, its
   `elfSetMeta(elfMetaLive, 1)` and its `enter_user` are **deleted** — `enter_user` no
   longer appears in `elf.dart` at all, which `m20-launch` asserts structurally.

### 3.1 The ordering question, which is the only subtle part

`argsBuild` is called **after `procToKernel()`**, on the kernel's CR3, and that is
deliberate rather than incidental.

`argsBuild(frame)` writes every byte through `argsPhys(frame, va)` — the **physical**
address of the process's stack frame, which the kernel's identity map covers — and not
through `[vmProgStackPage, vmProgStackTop)`, which only the process's own tables map. So
it neither needs nor wants the target address space installed. Placing it after
`procToKernel()` keeps the window in which this kernel runs on a process's page tables
exactly as narrow as it has always been: **the loader call, and nothing else.**

The RSP it returns is a *user virtual* address, which `procInitFrame` copies into the
synthesised register frame — so a process resumed from its frame and a process entered by
`procStart` begin on the same stack, as they always did.

### 3.2 What `proc run` gets

`proc run` names its programs by LBA and has no arguments to give, so it calls
`argsReset()` before creating either process. They get a **complete but empty** System V
stack: `argc` = 0, the `argv` NULL, the `envp` NULL and the AT_NULL pair.

An empty argv is not the same thing as no stack, and it is the first that a program is
entitled to. The visible consequence is that `PROC START ... RSP` moved from
`0x10200000` to `0x101FFFD0` — five words down, 16-byte aligned — which is why m11, m12,
m13 and m18's goldens moved.

## 4. What this costs, stated plainly

* **Every `run` harness's serial capture changed shape.** The `ELF LOAD`/`ELF STACK`/
  `ELF ENTER`/`ELF TEARDOWN`/`ELF DONE` sequence is replaced by `PROC NEW`/`PROC START`/
  `PROC EXIT`/`PROC KILL`/`PROC END`. m10, m13, m14, m15, m16 and m19's goldens were
  re-derived with each harness's own `--regen`, which rewrites the captured golden but
  **does not** bypass the derived structural checks — those are computed on the host and
  still had to pass.
* **The kernel grew by one page**, so every physical address in m7, m8 and m9's goldens
  shifted. That is the routine per-milestone churn this project has had since M8; those
  goldens moved in every milestone commit from M14 onward.
* **A `run` program now costs two more frames** (its own PML4 and PD) than it did, and
  `PROC KILL ... FREED` reports them coming back. `m20-launch` asserts the free-frame
  count is identical before and after a session, to the frame.
* **`elfLive()` is now permanently 0.** The only place that set `elfMetaLive` to 1 was the deleted
  launch block, so the M10 "a program is live in the kernel's window" state no longer exists. The
  branches guarded by it — `elfTeardown()` on `user.dart`'s exit and fault paths, and the
  `elfErrLive` guard at the top of `shellElfLoadAndEnter` — are left in place rather than deleted:
  they are correct, they are cheap, and they are what a future second window-based loader would
  need. **They are, today, unreachable.** Nothing depends on them being reached; `m20-launch`
  asserts the frame count returns to baseline, which is the property they used to provide.

* **`run` now refuses on a machine without FXSR**, with `procErrNoSse`, because a process
  needs somewhere to `fxsave` and a machine with no FXSR has nowhere (GAP-0092). Before
  M20 an M10 `run` program had no FPU state to own and did not care. This is a real
  behavioural narrowing and it is the correct one: the alternative is a process whose XMM
  registers nobody owns.

### 4.1 Two things this change broke on the way, kept here because they cost real time

**The exit code had to move.** `ELF DONE EXIT <code>` used to read the code out of the ELF loader's
own meta word. On the process path the code is written into a *process slot*, and `procCleanup`
releases that slot before the shell runs again — so the shell printed `F000F859F000E739`, BIOS shadow,
which is how this was noticed. `userSysExit` now records `userMetaExit` **before** it branches into
`procSysExit`, on both paths, because `procSysExit` does not come back when this was the last process.

**The exit accounting had to move too.** `USER EXIT CODE <code> SYSCALLS <n> REFUSALS <n>` was
printed *below* the process branch in `userSysExit`, so a program that was a process never reported
its syscall or refusal counts — and once `run` created a process, that was every program. Those are
per-boot counters in `userMeta`, not per-process, and the question they answer is exactly as
meaningful for a process. The line now prints on both paths, above the branch. `m10-elf` asserts
`REFUSALS` is zero for a program that should have made none that needed refusing, and would have
silently lost that check otherwise.

**The page report cannot be taken from the shell.** `elfPageReport`/`elfWindowLine` walk from CR3, and
the program's window now belongs to the process rather than to the kernel's page directory. The first
attempt wrapped them in a second `paging_install`/`procToKernel` pair inside the shell launcher, after
the slot was already READY and LIVE. The program then ran correctly and the session **never came back
from its last `exit`** — control was lost somewhere after `PROC KILL`, with no fault and no prompt.
**That mechanism was not run to ground.** The report was moved into `procCreate`'s existing bracket —
the one this kernel has walked process page tables in since M11 — and the problem does not arise.
A comment in `procCreate` says so, because the obvious "tidy-up" is to move it back out.

## 5. What was considered and rejected

* **Teach the M10 path about heaps.** Rejected: it needs a second copy of the heap's
  per-owner storage and a heap-owner concept that is neither a process nor a payload.
  The duplication is exactly what let the two paths drift apart in the first place.
* **Parameterise `heap.dart` over an owner** so both paths could keep their own storage.
  Same objection one level down, and it would have made `sbrk`'s refusal floor a
  three-way question inside a syscall.
* **Leave `run` alone and add a third, process-backed launch command.** This would have
  kept every existing golden green and closed the capability gap. Rejected because it
  leaves three launch paths where there were two, and the next agent inherits the same
  drift with more surface.

## 6. Exit criterion

`core/tests/conformance/m20-launch/` — a C program written as
`int main(int argc, char **argv)`, launched with `run wc.elf alpha.txt`, which:

* reads `argc`, `argv[0]`, `argv[1]` and both ABI terminators, and
* **reads every byte of the file through a `malloc`ed buffer** — the two halves are
  tested *through each other*, not side by side. The counts are unobtainable unless both
  worked: with no heap the program prints `WC HEAP FAIL` and exits 5; with no argv it has
  no file to open. Neither can produce the counts `derive.py` computes on the host.

plus a negative control that ignores argv and must print the wrong file's counts while
still getting a heap, and the structural assertion that `elf.dart` contains no
`enter_user` call and `proc.dart` contains exactly one `argsBuild` call.
