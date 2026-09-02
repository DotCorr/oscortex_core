# ADR-0007: Fault recovery by abandoning the faulting computation — and CPUID across a boundary with no strings

**Status:** decided — implemented and verified (`tests/conformance/m4-fault/run.sh`)
**Date:** 2026-08-21
**Milestone:** M4 (`ROADMAP.md`)

## Context

M1 proved a fault can be **caught**: a deliberate `u64` overflow becomes DCDart's own `ud2`, the
handler prints `M1 FAULT 06 ...`, and the machine is still alive to print it. `docs/known-gaps.md`
GAP-0001's "any real fault triple-faults the VM with no diagnostic" has been closed since.

What M1 did *next* is the thing this milestone is about. The handler did not return — it walked
forward into `m2Enter()` and never came back. That is not recovery, it is a **phase change**. From M2
onward the second arrival on that path called `halt_forever()`: a genuine fault while the console was
up printed a diagnostic and stopped the machine. Honest, and the right thing to do given nothing
better existed, but the project's founding thesis is an OS whose programs can be *operated on* in a
bad state rather than dying. Stopping is dying with a note attached.

## The constraint everything else follows from

**A fault handler cannot `iretq` back to the instruction that faulted.** A fault pushes the address of
the faulting instruction itself, so returning re-executes it, faults again, and loops forever printing
the same line. (A *trap* — `int3`, which M1 uses for its delivery self-test — pushes the following
address and returns fine. That difference is why M1's self-test uses a breakpoint.)

So there are exactly two things a handler can do that are not "stop":

### Option 1 — advance the return RIP past the faulting instruction

Add the instruction's length to the pushed RIP and `iretq`. The frame is reachable: `isr_common`
already hands `isrDispatch` the address of the saved-register block, and the CPU's RIP slot is at a
fixed offset from it.

**Rejected.** It is correct only if you know the instruction's length, and for a general x86-64
instruction you do not — variable-length encoding, prefixes, ModRM, SIB, displacements and immediates
mean the only way to know is to *decode* it. This kernel could special-case `ud2` (always two bytes)
and get `crash ud` working today, and that is exactly why it should not: it would be a demo that works
for the one instruction the test uses and silently corrupts control flow for every other fault, by
resuming in the middle of an instruction. An x86 length decoder is a real, unbudgeted subsystem.

It is also the wrong *shape*. Skipping the faulting instruction resumes a computation whose invariants
are already broken — the add that overflowed did not produce a value, so whatever was going to consume
it now consumes garbage. Continuing there is not recovery; it is corruption with extra steps.

### Option 2 — abandon the faulting computation and resume a known-good context

**Chosen.** This is what a real OS does when a process faults: it does not repair the process, it
stops running that computation and returns to something that was already healthy. Here the healthy
thing is the shell's main loop.

The mechanism is one word:

- `shell_run_forever` (`core/boot/isr.S`) records RSP the instant before the shell loop starts, into
  `shell_resume_rsp` in donated `.bss`, and sets a guard word next to it. It has to be assembly:
  DCDart cannot read a register.
- The fault handler prints its diagnostic in interrupt context and calls `fault_resume`.
- `fault_resume` does `cli`, checks the guard, sets RSP back to the recorded mark, and calls
  `shellRecover()` and then `shellMain()`.

Every frame between the mark and the fault — the faulting command, anything it had called, and the
interrupt frame itself — disappears in that single store. Nothing is unwound; there is nothing *to*
unwind, because `@bare` DCDart has no destructors, no `finally`, and no allocator whose state could be
left inconsistent. That is not a coincidence, it is why this mechanism is *sound in this language* and
would not be in a richer one.

Because RSP is reset to the **same** value every time, N faults cost no stack. That is a property of
the design rather than something the test measures; the harness demonstrates it with three.

## What this is, and what it is not

Stated plainly, because the difference is the whole point and it would be easy to oversell:

**It is:** fault survival with *abandonment* of the faulting computation. The kernel catches a #UD or
a #DE, reports it with real context, discards everything that was running, and returns you to a
working prompt with the timer, the keyboard, the IDT and the memory map all still functioning.

**It is not:** resumption of the failed computation. `crash ud` is gone. It did not finish, it was not
retried, and no value it was computing survives. A command that faults halfway through leaves whatever
it had already printed on the screen and nothing else.

**It is not a condition system.** Resuming a failed computation *after repairing its cause* — the
model this project is ultimately aiming at, where a program in a bad state is something you operate on
rather than something that dies — needs language support that exists on neither side. DCDart's own
`docs/escalations/0005-condition-system.md` is where that lives. Concretely, what is missing is: a way
to name a condition, a way to establish a handler dynamically, a way to resume the signalling point
with a supplied value, and restarts. This ADR does not approximate any of them and should not be read
as a step toward them that is 20% done. It is a different, smaller, complete thing: the kernel stops
losing the machine.

## What this does NOT handle, precisely

1. **A fault inside the fault handler.** `faultReport` dereferences the faulting RIP to print the
   opcode bytes. If the RIP is outside the 16MiB `boot.S` identity-maps, that read would itself fault
   — inside a fault handler, which is a double fault and then a triple fault. So the read is bounds-
   checked and an unmapped RIP prints `----` instead. That is the only such hazard on this path today;
   there is no general "fault while handling a fault" story, and there cannot be a good one without an
   IST for `#DF` (GAP-0007).

2. **A fault before the shell exists.** `shell_resume_rsp` is `.bss`, which nothing zeroes, so it is
   garbage until `shell_run_forever` runs. `shellInit()` clears the guard word at the top of `kmain()`
   and `fault_resume` refuses to switch stacks without it — falling back to `halt_forever`, which
   loses the machine but keeps the diagnostic already printed. Recovering onto a garbage stack pointer
   would triple-fault *while reporting a fault*, which is the one failure this milestone must not add.

3. **A corrupt or exhausted stack.** Recovery resumes on the same 16KiB boot stack. If the fault was
   *caused* by that stack being exhausted or corrupted, resuming on it is not recovery. The honest fix
   is a `#DF` IST slot, which ADR-0002 withdrew on its own merits and which GAP-0007 says should come
   back with the milestone that can prove it works.

4. **Faults in interrupt context, partially.** The 8259's in-service bit is the one piece of *device*
   state an abandoned handler would leak, so `shellRecover()` issues a non-specific EOI to the master
   before printing. That covers the one level this kernel can have in service; it is not a general
   device-state rollback, and there is no mechanism at all for a device left half-programmed by an
   abandoned command. GAP-0062.

5. **Anything the abandoned computation had already done.** Output already printed stays printed; a
   port already written stays written. Abandonment is not a transaction.

6. **A fault on the recovery path itself.** `fault_resume` always resets RSP to the *same* mark, which
   is what makes N faults cost no stack — and it also means a fault inside `shellRecover()` would land
   back in `fault_resume`, reset to the same mark, and call `shellRecover()` again: an infinite loop
   printing the same two lines rather than a crash. That is a better failure than a triple fault and
   it is still a failure. It is bounded in practice only by `shellRecover()` being nine lines that
   touch three donated words, a PIC port and the console — but "it is short" is not a mechanism.
   Closing it needs a recursion guard (a depth word, and a decision about what to do when it trips),
   which is real design about what "give up" means, and this kernel still has no answer to that (the
   same gap `uart.dart`'s unbounded THRE poll and `shellTicks`' unbounded wait both record). GAP-0062.

## The diagnostic: the address is used, and deliberately not printed

`isr_common` already passes the faulting RIP to `isrDispatch`, and `faultReport` **dereferences it** —
the `OP` field is the first two bytes of the instruction that actually faulted:

```
FAULT 06 ERR 0000000000000000 OP 0F0B      <- ud2
FAULT 00 ERR 0000000000000000 OP 48F7      <- REX.W + F7: a 64-bit div
```

Reading through the address is a stronger claim than printing it would be: the bytes cannot be right
unless the handler really has the faulting address.

**The absolute value is left out on purpose.** Every byte this kernel prints is asserted by a
byte-exact golden. An absolute code address moves whenever *any* kernel code changes, so printing it
would guarantee that every future milestone had to regenerate this one's golden for a reason that says
nothing about whether recovery works — which is precisely the "regenerate until green" habit
`CLAUDE.md` exists to prevent. Two opcode bytes are position-independent and identify the instruction.
The cost — you cannot tell *where* it faulted from the log — is real and is recorded as GAP-0064
rather than glossed. Two bytes rather than four, because the third and fourth bytes after a
DCDart-emitted `ud2` are padding whose contents legitimately move.

## `crash div` cannot be a DCDart division, and that is a finding

The obvious implementation of `crash div` is `a ~/ b` with `b == 0`. **It does not produce a divide
error.** Verified by compiling a probe through the real `dcc` and disassembling it, not assumed:

```
probeDiv:
   0:  48 85 f6      test   %rsi,%rsi
   3:  74 1c         je     21        <- zero divisor
  ...
  21:  0f 0b         ud2
```

`dcc` emits an explicit zero-divisor check in front of every `~/` and `%` and traps with `ud2`. A
DCDart division by zero is therefore a **#UD on vector 6** — the same vector, from the same
instruction, as `crash ud`. It would have proved nothing new, and calling it a divide error would have
been false.

So `crash div` executes the `div` in assembly (`divide_by_zero`, `core/boot/isr.S`), in exactly the
category and for exactly the reason `debug_break` executes `int3`: an instruction DCDart cannot emit,
behind a C-ABI function. The CPU raises a genuine **#DE on vector 0** — a different fault class,
delivered by hardware, through the same recovery path. Recorded as GAP-0063.

A side benefit worth naming: the encoding is hand-written and therefore fixed (`48 f7 f1`), which is
what makes ` OP 48F7` a stable golden value rather than a hostage to register allocation.

## `cpu`: returning a 12-byte string across a boundary that has no strings

`cpuid` has no DCDart primitive and DCDart has no general inline `asm()`, so it goes in assembly
reached by `@extern` — that part is routine. The interesting constraint is the *result*.

The vendor string is 12 bytes and the brand string is 48. Across the DCDart/assembly boundary there is:

- no `String` type;
- no array type — `@rodata final List<u8>` is a declaration form, not a value, and it is read-only
  anyway;
- no `Pointer<T>` in an extern signature (DCDart GAP-0025), so scalars only;
- no allocator, and no mutable static data of any kind (GAP-0053).

There is nothing a CPUID string could be **returned as**, and nothing it could be **stored into**.
Both halves are missing at once, which is why this is worth an ADR paragraph rather than being obvious.

The shape that exists: `cpu_probe()` writes the bytes into 64 bytes of assembly-donated `.bss`
(`cpu_info` in `core/boot/kdata.S` — 12-byte vendor at +0, 48-byte brand at +16), and returns the two
CPUID *limits* packed into the one `u64` it is allowed to return
(`(extended << 32) | standard`). DCDart gets the block's address from an accessor and walks it a byte
at a time.

Cost, recorded as GAP-0061 rather than waved through:

- 64 of the 392 donated bytes exist purely to carry two strings between two functions;
- DCDart has to implement its own string layer — `cpuSkipSpaces` and `cpuWrite` are `strlen`-ish and
  `strspn`-ish, written out because there is nothing to call;
- the length and the layout are a contract in a comment, checked by a harness assertion, rather than
  by anything either language can express.

Two facts are printed that are not decoration: `cpu_probe` **asks** whether the brand leaves exist
(`0x80000000` limit ≥ `0x80000004`) and NULs the buffer if they do not, so a CPU without them shows an
empty brand rather than 48 bytes of whatever the loader left in `.bss`; and the two leaf limits are
printed because they are the honest bound on everything else CPUID could be asked.

## Rejected alternatives

**A `setjmp`/`longjmp` pair.** Save the callee-saved registers and RSP/RIP at a recovery point in
`shellMain`, restore them from the fault handler, and *return into the middle of* `shellMain`. That is
the textbook shape and it was rejected for a specific reason: it needs LLVM's `returns_twice`
attribute to be sound, and neither DCDart nor this kernel has any way to put it on a call. Without it
the optimizer is entitled to keep a value in a register across the "call" that returns twice, and the
restore would then resume with stale state — a miscompilation that would be invisible at `-O0`, real
at `-O2`, and would present as impossible-looking data corruption rather than a crash. Re-entering
`shellMain` at its *entry point* on a reset stack needs no such attribute and no register restoration
at all, because there is nothing live to preserve.

**Keeping `halt_forever` and calling it recovery-adjacent.** It is what M2 and M3 did and it is
honest, but it is the behaviour this milestone exists to replace.

**A separate recovery stack.** Would need a second `.bss` region and would make the recovery context
different from the normal one, so a bug reachable only after a fault would be a bug in a context
nothing else ever runs in. Resuming on the *same* stack at the *same* depth means the post-recovery
shell is bit-for-bit the same situation as the pre-fault shell — which is also why the harness can
assert that `mem` produces identical bytes before and after.

**Putting the new state in a new `.S` file.** Would have kept `kdata.S`'s number at 304 while the real
donated total grew, understating GAP-0053. One file owns donated mutable storage; the number moved to
392 and every place that quotes it moved with it.

## Verification

`tests/conformance/m4-fault/run.sh`. Eight structural checks, `verify-freestanding.sh` on `kmain.o`,
`kdata.o` and `kernel.elf` (**24** declared externs, up from 17), then a real boot driving a real
session over QMP, then a second real boot for the negative control.

Asserted:

1. **Serial, byte-for-byte** (2260 bytes). First 544 bytes are M1's golden, checked *mechanically* as
   a prefix against M1's own file — M4 changes the fault path, so this is the check that proves it did
   not change M1's fault path.
2. **Both vectors, from the real faulting address**: `FAULT 06 ... OP 0F0B` and `FAULT 00 ... OP 48F7`,
   as exact byte sequences, with counts (two #UD, one #DE).
3. **Recovery is followed by work**: the exact bytes `FAULT RECOVERED 0001 ...` then a prompt then
   `help` then `commands:`. That adjacency in the byte stream *is* the milestone.
4. **A counter, not a constant**: `0001`, `0002`, `0003`, in that order.
5. **`ticks` after two faults** prints ` LIVE`, which is only reachable through a loop that exits when
   a timer interrupt has actually been delivered — so IF, the IDT and the PIC masks all survived.
6. **The `mem` re-walk equals the boot-time dump**, both extracted from the same capture, across two
   abandoned stacks.
7. **The framebuffer, byte-for-byte**, read out of guest physical memory at `0xB8000`.
8. **A PNG** at `core/build/screenshot-fault.png` — produced, not pixel-compared.
9. **A negative control**: a different key sequence, which *also* faults and *also* recovers, must fail
   both goldens with the divergence past byte 544. Measured: byte 545. The control faults on purpose so
   that what it proves is sensitivity to *which* faults were taken, not merely to whether anything did.

Structural: `kdata.o` donates exactly 392 bytes; `cpu_info` is exactly 64; `divide_by_zero` is exactly
`xor; xor; mov $1; div %rcx` with the encoding `48 f7 f1` asserted; `fault_resume` is exactly
`cli; guard; load %rsp from memory; align; call; call; jmp` in that order (asserted as an ordered
mnemonic sequence, because "contains a mov to rsp somewhere" would pass with the guard deleted);
`shell_run_forever` stores `%rsp` and arms the guard; `cpu_probe` issues exactly five real `cpuid`s;
`shellCrashUd` keeps a **conditional** `ud2`; and all 18 new `@rodata` tables are exactly the sizes
their call sites pass.

## m3-shell's goldens were regenerated, deliberately

`help` lists what the shell can do. M4 added three lines to it (`cpu`, `crash ud`, `crash div`), and
m3-shell's session ends with `help`, so both of its goldens moved. The distinction that matters is the
same one GAP-0059 drew:

- **M1's 544-byte golden did not move by one byte**, and both m3-shell and m4-fault still check it
  mechanically as a prefix.
- **m3-shell's key sequence is unchanged** — the same 63 elements.
- **Every property m3-shell asserts is unchanged in kind.**
- **The diff is exactly the three new `help` lines, in both files, and nothing else.** That was checked
  as a diff against the previous goldens, not asserted.
- m3-shell's exact-`.bss`-total assertion moved to m4-fault, the same way it moved from m2-console to
  m3-shell — one harness owns that number and it is the milestone that grew it. m3-shell kept a
  narrower check that is genuinely its own: its four shell state words are still 8 bytes each.

Recorded as GAP-0065.

## Consequences

- **The kernel survives its own mistakes and keeps being usable.** That is the founding thesis made
  testable for the first time, on the smallest thing that can carry it.
- The fault path has two arms now, and the boot-time one is frozen by a 544-byte golden. Anything
  added to fault handling from here has to keep that arm byte-identical.
- Donated `.bss` is 392 bytes. GAP-0053's number grew again, and this time 64 of the 88 new bytes exist
  purely because a 12-byte string cannot cross a function boundary.
- `kdata.o` now *exports* three symbols for `isr.S` to write. It still has no undefined symbols, so it
  still passes `verify-freestanding.sh` standalone — GAP-0056's one green assembly object stays green,
  and m4-fault checks it explicitly rather than assuming it.
- The shell has a command that is *supposed* to fail. That is a new category of test surface, and the
  right one: the failure path is now exercised on every harness run instead of only when something is
  broken.
