# ADR-0022 — Preemptive scheduling: a program that never yields no longer hangs the machine

**Status:** accepted, M18
**Supersedes nothing. Narrows** GAP-0085 item 3 and GAP-0097.
**DCDart pin:** unchanged at `8713298` (`DCDART_PIN.txt`). M18 needed no language feature M17 did not
already have, and no new `@extern`: the extern count on `kmain.o` is **44, exactly what it was at
M17**.

**The pin was tested rather than assumed** (GAP-0084, GAP-0110). An isolated clone of DCDart checked
out at `8713298`, under `/private/tmp` with an rsync'd copy of this repo beside it, builds a
`kernel.elf` that is **byte-identical** to the one the everyday checkout (`c51bb0b`, monomorphized
generics) produces — so not one regenerated golden can depend on which of the two compiled it, and
that is a stronger statement than a passing suite. `m1-interrupts`, `m11-proc` and `m18-preempt` were
then run inside that sandbox as an end-to-end check, and the sandbox was deleted.

---

## 0. What changed, in one paragraph

`isrDispatch`'s timer arm now calls `procTick(frame)`. On a PIT tick that interrupted **ring 3** with
a process live, `procTick` charges one tick to the running process's slice; when the slice reaches
`procQuantumTicks` it saves the interrupted 22-word frame and the 512-byte FPU image into the current
slot, picks the next READY slot round-robin, writes CR3, restores the next process's FPU and frame,
and returns — and `isr_common` pops fifteen registers and `iretq`s into a **different program**. The
program that was taken off the CPU never asked to be, and never learns it happened except by asking.

Everything else is bookkeeping, and §2–§13 are why each piece is shaped the way it is.

---

## 1. The switch is `procYield`'s body minus one line, and that line is the whole difference

M11's ADR-0015 §2 already made the argument that the 22-word interrupt frame IS a suspended thread,
and built `procSaveFrame` / `procLoadFrame` / `procSwitchTo` around it. M18 reuses all three
unchanged. `procTick`'s switch differs from `procYield`'s in exactly two ways:

* **The saved RAX is NOT patched.** `procYield` overwrites the saved frame's RAX with 1 before
  switching, because the frame it saves was built by an `int $0x80` whose RAX held the syscall
  *number*, and handing that back to a resumed process would be a return value arrived at by
  accident. `procTick`'s frame was built by a **timer interrupt at an arbitrary instruction
  boundary**: its RAX is the program's own live register. Writing anything into it would corrupt the
  program. The line that is correct in one path is a bug in the other.

  **The first check written for this did not catch it, and GAP-0143 §2 is the record.** It required
  progD's saved RAX to be *below* the count its loop spins on; the mutant writes 1, which is below 3.
  The real problem was that neither program kept anything live in RAX at all. progC now loads
  `0x00C0FFEEC0FFEE00` into RAX once and never writes it again — `build-progs.sh` disassembles
  `_start` and requires exactly one RAX write in it — and the harness reads that constant out of
  `progC.c` and compares it against the saved frame in guest RAM.

* **The counters are different words.** See §6.

Everything else — CR3 first, FPU second, frame last, and why that order is a correctness argument and
not a sequence — is ADR-0015 §2's, unchanged.

---

## 2. Preemption is a SESSION POLICY, and `proc coop` is the one opt-out

`proc run`, `proc cross` and `proc spin` all set `procHeadPolicy = procPolicyPreempt`. `procInit`
writes the same value, so a kernel that has run no session at all still says it is preemptive.

**`proc coop` sets `procPolicyCoop`, and it exists for one specific harness.** `m11-proc`'s "hold"
boot loads a variant of progB with `jmp .` written over its entry point, so that BOTH address spaces
stay alive while the harness dumps guest memory and walks two page-table trees, reads a suspended
process's FXSAVE area, and checks that A's private pages are absent from B's. That boot asserts
things about **a machine held by a non-yielding program** — which is precisely the state a preemptive
scheduler abolishes. Under `proc run` at M18, that held process is taken off the CPU after one
quantum and the other one runs to completion; there is no moment at which two processes are
simultaneously live and suspended for the harness to inspect.

**The honest statement of the cost:** a per-session policy bit is not what a finished kernel has. One
kernel, one policy. What keeps this defensible rather than a dodge is that the DEFAULT is preemptive,
that the opt-out is named for what it does, and that the same command is `m18-preempt`'s **negative
control** — the harness requires `proc coop` to hang the machine, so the bit is not a place a bug can
hide. GAP-0139 records what removing it needs.

---

## 3. The kernel is NOT preemptible, and the reason is stronger than the decision

`procTick` reads the CS the CPU pushed and returns unless its low two bits are 3. So a tick that
interrupted kernel code counts (`procHeadKernTicks`) and does nothing else: **a syscall cannot be
preempted**, and neither can the ELF loader, a disk read, or the shell.

**What that costs.** Latency is bounded by the longest syscall, not by the quantum. A program that
calls `read()` on a twenty-thousand-byte file holds the CPU for the whole of it, and no other process
runs until it returns. `sbrk`, `open` and `write` are all in the same position. For a kernel that
will eventually host arbitrary C programs, that is a real ceiling and GAP-0138 is the accounting.

**Why the CS check is nevertheless not the thing doing the work.** Every gate in this IDT is an
INTERRUPT gate, so IF is clear for the whole of every kernel entry from ring 3. A timer tick inside a
syscall is not merely un-preempted — **it is not delivered**, and if two ticks elapse inside one
syscall the PIC delivers one and the other is lost. `procHeadKernTicks` measures this directly, and
on a real boot it reads **1**: the single tick that can arrive with CPL 0 and a process live is the
one that lands in `enter_user`'s three-instruction window between recording the resume RSP and its
`cli`. That is the number, it is printed by `proc sched`, and if it is ever large this paragraph has
stopped being true and should be treated as the bug rather than the machine.

**AND THAT IS ALSO WHY THE CS CHECK CANNOT BE TESTED BY BOOTING.** A mutation that deletes it — so a
tick interrupting ring 0 switches processes, and the kernel's own stack goes out from under it —
**survived every behavioural assertion in `m18-preempt`**, because the case it guards essentially
never arises on this machine. The harness asserts the test's presence in the *source* instead, and
says so in its own comment. That is weaker than a boot and is labelled as weaker. GAP-0143 §3.

**What preempting ring 0 would buy and cost.** It would need (a) a second ring-0 stack per process —
`proc.dart`'s own header says the single RSP0 in the TSS is enough "PRECISELY BECAUSE only one of
them is ever inside the kernel at a time — which is a property of the switching being cooperative,
and would stop being true the day it is not." **It has not stopped being true**: a preemption from
ring 3 puts the CPU back in ring 3, so there is still never a second kernel context on that stack.
And (b) re-entrancy in the frame allocator, the FAT cluster cache, the descriptor table and the UART,
none of which is re-entrant and none of which is guarded. Doing the ring-3-only version first is not
a shortcut around those two; it is a scheduler that does not need them yet.

---

## 4. The quantum: eight ticks, and why not one

`const int procQuantumTicks = 8;` — the PIT is at 100.0 Hz (`interrupts.dart`), so a tick is 10 ms
and a quantum is **80 ms of ring-3 time**. Not of wall-clock time: only a tick that interrupted CPL 3
with a process live is charged to the slice, so kernel time spent on the process's behalf is not
billed to it. The slice is reset by `procSwitchTo`, by `procStart` and by every expiry, so it is a
per-slice count and never a running total.

**One would have been simpler and would have been wrong.** `m11-proc`'s 4096-byte golden is an
interleaving that only a scheduler which does not preempt produces, and its slices are
**microseconds** long — every M11 program reaches a `yield` within a few thousand instructions. For a
quantum of eight to fire inside one of those, eight 10 ms ticks would have to be delivered inside a
ten-microsecond slice. One tick landing there is merely unlikely; eight is not a race, it is
arithmetic. A quantum of one would have made M11's golden a coin flip, and a flaky golden is worse
than no golden. `m18-preempt/run.sh` refuses a quantum below 2 by name.

---

## 5. New state goes in the block the process table already owns

Six header words (`procHeadPreempts`, `procHeadQuanta`, `procHeadSlice`, `procHeadPolicy`,
`procHeadKernTicks`, `procHeadBudget`) and two per-slot words (`procSlotPreempts`, `procSlotYields`).
The header had exactly eight words and all eight were in use, so `procStore` grew from **4160 to
4224** bytes: header 64 → 128, table at 128, FXSAVE areas at 2176, still 16-byte aligned.

**A second `@bss` block with a second storage seam was the alternative, and it was refused.**
`m11-proc/run.sh`'s "one symbol behind three offsets" check exists to prevent exactly that, and
scheduler state is process-table state. The seam is still three call sites in one file, and
`m18-preempt/run.sh` re-asserts it because M18 is the milestone that was tempted.

**The cost is 64 bytes and seven harness numbers**, each of which is spelled out rather than
computed: `m10-elf` 4168 → 4232, `m11-proc` 9664 → 9728 and 4160 → 4224, `m12-heap` and `m13-libc`
9664 → 9728, `m14-fat` 11488 → 11552, `m15-fileio` and `m16-filewrite` 14048 → 14112. GAP-0053's
running total moves with them.

**Words 14 and 15 of the header are unused and asserted zero**, same discipline as slot words 54..63,
so a future field lands somewhere somebody chose.

### 5a. The slot-word collision, which happened

`procSlotPreempts` was first written as word **16**. Word 16 is `heapSlotBase` — M12's per-process
heap, allocated in `heap.dart`, which `proc.dart`'s "slot words 0..31 are metadata" comment does not
mention. The kernel built, booted, preempted correctly, and printed `N 10003001` as a preemption
count: the process's heap break, read back as a scheduler statistic. Nothing crashed and no existing
harness noticed. `m18-preempt/run.sh` now parses every `*Slot*` constant out of every kernel source
file and requires the indices to be distinct.

---

## 6. `SWITCHES` counts all switches; `PREEMPTS` is a separate word, and M11's identity gained a term

`procSwitchTo` bumps `procHeadSwitches` on every switch, voluntary or not. `procHeadPreempts` counts
only the involuntary ones, and `procSlotYields` / `procSlotPreempts` do the same per process.

So M11's arithmetic identity does not break — it **acquires the term it was missing**:

```
switches == yields + surviving exits + preemptions
```

`m11-proc/run.sh` asserts it with the third term counted out of the log, one `PROC PREEMPT` line at a
time (and additionally requires that term to be **zero** in its own sessions, for §4's arithmetic
reason). `m18-preempt/run.sh` asserts the same equation with the third term dominant and the first
term zero. Both are falsifiable from two directions: a kernel that switched without printing fails,
and so does one that printed without switching.

---

## 7. Three things M18 deliberately did not do to the output

1. **No existing serial line gained a field.** `PROC END`, `PROC SSE` and `PROC PD` are inside
   byte-exact goldens owned by other harnesses. The scheduler's numbers are on a **new command**,
   `proc sched`, and the session's policy and budget are printed there rather than on `PROC RUN`.

2. **`shellStrHelp` is byte-identical at 2147.** GAP-0105: the help text is inside the goldens of m3,
   m4, m5, m6 and m14, and its size is asserted by six harnesses. M18 adds three commands
   (`proc sched`, `proc spin`, `proc coop`) and documents them on a second usage table
   (`procStrUsage2`, reached from `proc` with a bad argument) instead. The cost is real and is stated
   here: **`help` does not mention `proc spin`.** GAP-0142.

3. **`m1-interrupts`' 544-byte golden did not move**, and is still asserted byte-for-byte as a prefix
   by **sixteen** harnesses — every one that boots past M1 — including both of M18's boots. `procTick` prints nothing with no process live,
   which is every tick M1 ever takes.

Goldens that *did* move, moved only in hexadecimal literals — the kernel image grew, so the frame
allocator's base moved by one page and every printed physical address with it. Same rule M17 used:
every regenerated golden was required to differ from its predecessor in hex literals and frame counts
only, same lines in the same order, before it was accepted.

---

## 8. `procTick` is called AFTER the EOI, and that side of the line is deliberate

`isrDispatch`'s timer arm sends `picEoiMaster()` and **then** calls `procTick`. The EOI was already
the last thing that arm did before M18; what is new is that there is a handler body at all, and
putting it on that side of the line is required rather than inherited — on one path `procTick` does
not return. When a session's quantum budget is exhausted,
`procBudgetEnd` tears every process down and leaves through `user_return`, abandoning the interrupt
frame — so an EOI written after the call would never be written, and IRQ0 would sit in the PIC's
in-service register for the rest of the boot — blocking IRQ1 with it, because the keyboard is a lower
priority line on the same PIC, so the shell we returned to would answer nothing at all.

It is safe because every gate in this IDT is an interrupt gate: IF is clear for the whole handler, so
acknowledging the PIC before the body cannot let a second tick arrive inside the first. The keyboard arm keeps
the opposite order and keeps its comment; the difference between them is which one has a path that
never returns.

---

## 9. The timer is unmasked for a preemptive session and masked again at every exit

The PIT has been **masked at the PIC since M2**. That was deliberate and written down twice: a 100 Hz
interrupt "would only add jitter between keystrokes", and — GAP-0058 — with IRQ0 masked at rest the
tick counter holds still, which is the only reason `ticks` can print a number that `m3-shell`'s
byte-exact golden asserts.

A preemptive scheduler needs the tick. Turning it on for the whole boot would move m3's golden and
make every later `ticks` reading depend on how long the machine sat at a prompt. So `shellProcRun`
unmasks it when a preemptive session begins, and `procSessionTimerOff()` puts it back at **every**
exit from one: the ordinary end, the two refusals that can happen after the unmask, and
`procOnFault`, whose `fault_resume` abandons `shellProcRun`'s stack and would otherwise leave the
timer running under every later command in the boot — silently, because nothing prints.
`m18-preempt/run.sh` counts both call sites.

**This was found by running the thing.** The first working build of `procTick` was correct and
preempted nothing, because IRQ0 had been masked since M2 and nobody had noticed that "the PIT already
fires" was only true during M1.

---

## 10. The runaway backstop: a budget in quanta, not in seconds

Preemption means a runaway **shares** the CPU. It does not mean anybody can ever get the CPU **back**:
`proc spin`'s progC never yields, never exits, and makes no system call at all, so with only
preemption the session would run until the machine was switched off.

There is no keyboard-driven kill and no signal in this kernel (GAP-0140). So `proc spin <a> <b>
<quanta>` states a budget up front, and `procTick` enforces it: when `procHeadQuanta` reaches
`procHeadBudget`, `procBudgetEnd` prints, restores the kernel's CR3, tears down every live slot and
returns to the shell through `user_return` — the same shape `procOnFault` has used since M11, from a
different interrupt.

**It is a count of quantum expiries and that is what makes the boot assertable.** "Run for a second"
is a different test on every host. "Run for 24 quanta" is the same test everywhere, and
`m18-preempt/run.sh` requires the number the kernel prints to equal the number typed at the shell,
exactly. A budget of 0 means no limit and is what `proc run` passes; `proc spin` refuses a budget of
zero by name, because a command whose whole purpose is a limit should not accept a typo as "none".

**A quantum expiry with only one runnable process still counts and does not switch.** That is why
`preempts < quanta` is an assertion in the harness: after progD exits, progC is alone, the expiries
keep accruing with nowhere to go, and the budget stops it anyway. **A lone runaway is stopped too.**

---

## 11. `preempts` (syscall 10): the syscall that makes a preemptive milestone assertable

Returns the calling process's `procSlotPreempts`. Refused unless a process is live, for `yield`'s
reason: the number lives in a process table slot.

It is a **pure read**. It does not switch, sleep or block, so a program that calls it in a loop is
still a program that never yields — and progC, which contains no `int $0x80` at all, is on the disk
to close even that argument.

Why it exists: a test program has no clock. "Run for a while and check you were interrupted" is a
wall-clock criterion and unassertable. "Run until the kernel says it has taken you off the CPU three
times" terminates after exactly three quantum expiries on any host, and the number is the kernel's
own. M1 solved the same problem the same way by making the tick count the trigger.

---

## 12. What M18 does not do

`fork` and `exec` (a process still comes only from `proc run` and a disk LBA); priorities (round-robin
and nothing else — `procPickNext` is unchanged from M11); **blocking** (nothing ever waits: a process
is READY, RUNNING, EXITED or KILLED, and there is no fifth state, so a disk read spins the whole
machine); **sleep** (no way to ask for time to pass); and SMP. GAP-0138 through GAP-0142 are the
accounting, and GAP-0136 — the tick counter's read-modify-write, correct only because interrupt entry
serializes on one core — now covers M18's own state too: §13.

---

## 13. What of M18's state is safe for GAP-0136's reason, and what is not

**Not a fix for SMP, and not an attempt at one.** GAP-0136 records that the PIT tick counter is a
read-modify-write with no atomicity, correct today only because there is one core and interrupt entry
serializes. Preemption adds scheduler state that is read and written across interrupt boundaries, so
the same question has to be answered for each new word.

**Safe today, for exactly GAP-0136's reason and no other:**

* `procHeadSlice`, `procHeadQuanta`, `procHeadPreempts`, `procHeadKernTicks`, `procSlotPreempts` and
  `procSlotYields` are all read-modify-write, and every one of them is touched **only** from inside
  an interrupt handler running with IF clear — `procTick` (timer gate) and `procYield` (the `int
  0x80` gate). On one core, a handler cannot be re-entered by the next tick, so the read and the
  write cannot be split. On two cores they could be, and every one of these counters would lose
  increments.

* `procHeadCurrent` and each slot's `procSlotState` are written from interrupt context and read from
  shell context (`procLive`, `proc sched`). The reads are single aligned 64-bit loads, which x86
  guarantees are not torn, and the shell only ever reads them.

**Would NOT be safe, and is only safe today because there is one core:**

* **`procSwitchTo` is not atomic and is not a critical section.** Between `procSetHead(procHeadCurrent,
  next+1)` and the last word of `procLoadFrame` the table describes neither process consistently. On
  one core nothing can observe that window, because IF is clear and there is nobody else. On two
  cores a second CPU running the same scheduler could pick the same READY slot and run it on both.
  There is no lock and no per-CPU current-process pointer; `procHeadCurrent` is one global word.

* **`procHeadPolicy` and `procHeadBudget` are written by `shellProcRun` with IF SET**, from ordinary
  shell context, and their only reader is the timer handler. They are safe today for TWO independent
  reasons and it is worth knowing that both are load-bearing, because a later edit could remove
  either: (a) the two stores happen **before** `picUnmaskTimerAndKeyboard()`, so IRQ0 is still masked
  at the PIC and no tick can be delivered between them at all; and (b) even if one were, `procLive()`
  is still 0 at that point — `shellProcRun` refused a busy table further up — so `procTick` returns
  at its first line without reading either word. **Moving the unmask above the two stores would
  destroy (a) and leave only (b)**, and that is exactly the kind of reordering that looks like
  tidying. Stated here rather than discovered later.

* **`procSessionReset` writes the whole header and every slot with IF set**, and is safe for the same
  single reason: no process is live, so `procTick` returns at its first line.

The rule for the next milestone: **anything a second CPU would need a lock for, this kernel gets away
with because there is exactly one instruction stream and interrupt gates clear IF.** Nothing in M18
made that better or worse; it made more of the kernel depend on it, and GAP-0136 now says so.

---

## 14. What the milestone actually proved

`core/tests/conformance/m18-preempt/run.sh`, two QEMU boots:

* **Two programs, neither of which can call `yield`** — `build-progs.sh` disassembles both and
  requires that the immediate 3 never reaches RAX, and that progC contains **zero** `int $0x80`
  instructions of any kind. progC's whole body is `xorl %r15d,%r15d; 1: incq %r15; jmp 1b`.
* **Seven involuntary context switches and zero yields**, with per-slot counters from the kernel
  showing 4 and 3 preemptions and 0 yields each.
* **The FPU across preemption:** progD writes its signature into XMM0 and XMM7 inside one asm block,
  spins until the kernel reports three preemptions, and reads both back — all four lanes intact,
  after three switches chosen by a timer rather than by the program.
* **progC's saved R15 = 190,943,355 iterations**, its saved RIP inside its own R+X segment and its
  saved CS = 0x23, all read out of the kernel's process table in guest physical memory at an address
  the kernel printed.
* **The session ended at exactly the 24 quantum expiries typed at the shell**, and the shell answered
  two more commands afterwards.
* **The negative control:** the same two programs under `proc coop` hang the machine at CPL 3 inside
  progC, with progD never once reaching the CPU — GAP-0085 item 3, still true of the cooperative
  path and no longer true of the preemptive one.
