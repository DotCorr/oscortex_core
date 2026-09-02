# Blocking, waiting, and threads — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered, nothing implemented.** Same standing as
`display-protocol.md`: this file exists so the agent who builds the first piece does not have to
re-decide anything, and so the pieces that are *not* built are recorded as choices rather than as
omissions. When a piece is built it gets its own numbered ADR and that ADR points back here.

**What this document is about.** `core/kernel/proc.dart` has five process states — FREE, READY,
RUNNING, EXITED, KILLED (`proc.dart:272`–`276`) — and there is no sixth. M18 (ADR-0022) made the
scheduler *preemptive*; it did not make it *blocking*, and §12 of that ADR says so in one line:
*"**blocking** (nothing ever waits: a process is READY, RUNNING, EXITED or KILLED, and there is no
fifth state, so a disk read spins the whole machine)"*.

That single missing state is upstream of more of this OS's design than anything else in it.
`display-protocol.md` §0 constraint 4 names it as the reason events must ride a reply; §2.2 designs a
client main loop around a spin; §5.2 says a Wayland client is impossible *independently of sockets and
shared memory* because of it. Disk I/O spins the machine for up to 2,097,152 port reads
(`ata.dart:206`). A network stack cannot exist without it. This document specifies what it takes to
add it.

### The five things decided here, for a reader in a hurry

| | recommendation | where |
|---|---|---|
| **The sixth state** | `procStateBlocked = 5`. One constant. **Every existing scan in the kernel already does the right thing with it**, and that is checkable before a boot. | §1.1 |
| **Where the wait queue lives** | **Nowhere. There is no queue.** With `procMax = 4` a wakeup is a four-slot scan of the process table, and a scan needs no allocator, no arrays and no list surgery on five teardown paths. The threshold at which that stops being the right answer is stated. | §1.3 |
| **One blocking primitive, not three** | **`fdwait(mask, timeoutTicks) -> readyMask`**, syscall 11. `sleep` is `fdwait(0, n)`; a non-blocking poll is `fdwait(mask, 0)`. One block point, one wake path, one thing to get right. | §3 |
| **The hard part is not the state — it is having nothing to run** | The idle context is the whole cost of this milestone, and **it is the same missing piece `display-protocol.md` §6/D3 needs for a resident process.** Build them as one milestone. | §1.8 |
| **Threads** | **No.** Not now, and — more usefully — *the thing that makes ffmpeg and libwayland link is a stub pthread implementation in libc that needs zero kernel support.* Real threads are a refinement of a scheduler that can already suspend, so they are strictly after blocking, not before. | §4 |

**The one sentence that reframes §2.** "The kernel is not preemptible" sounds like a scheduler
problem. It is mostly a driver problem: the unbounded thing in this kernel is not a syscall, it is a
**wait** — a poll loop with `IF` clear waiting for hardware. Convert the waits into blocks and the
longest syscall becomes a bounded 512-byte copy. **Preempting ring 0 is not the next step; it is what
you do after you run out of waits to delete.**

---

## 0. What this has to be true of

Every constraint below is a property of this machine, read out of it, not a taste.

1. **Every kernel entry from ring 3 runs with `IF` clear.** Every gate in this IDT is an *interrupt*
   gate, including the DPL-3 syscall gate (`user.dart:726`, `userGateAttr = 0xEE`). A timer tick
   inside a syscall is not merely un-preempted, **it is not delivered** — and the 8259 cannot queue a
   second IRQ0, so a long syscall does not defer time, it destroys it (GAP-0138 item 3).
2. **There is exactly one ring-0 stack.** `proc.dart`'s own header: the single RSP0 in the TSS is
   enough *"PRECISELY BECAUSE only one of them is ever inside the kernel at a time."* M18 did not
   break that and neither may this design. §1.9 is the rule that keeps it true.
3. **The 22-word interrupt frame IS a suspended thread** (ADR-0015 §2), and `procSaveFrame` /
   `procLoadFrame` / `procSwitchTo` (`proc.dart:1410`, `1425`, `1486`) are the whole switch. This is
   the single most important fact in this document: **a process that is blocked in this kernel has no
   kernel state at all** — its entire continuation is 22 words in its slot plus 512 bytes of FXSAVE.
4. **There is no allocator for kernel objects and no arrays.** Kernel state is donated `@bss` blocks
   in `core/boot/kdata.S`, reached through exactly one address function per block, indexed by hand
   with shifts. `procStore` is 4224 bytes: a 16-word header, four 512-byte slots, four 512-byte FXSAVE
   areas. Anything this design needs must fit in words somebody chose, or the block grows and seven
   harness numbers move with it (ADR-0022 §5).
5. **`procMax = 4` and `fileMaxFds = 4`.** Four processes, four descriptors each. Both numbers are
   capacities rather than design limits, and both are small enough that a linear scan is not a data
   structure, it is a loop.
6. **Nothing else in this kernel is re-entrant.** Not the frame allocator, not the FAT cluster cache,
   not the descriptor table, not the UART. Nothing in this design may require that to change.
7. **Every counter written from an interrupt handler is a read-modify-write with no atomicity**, and
   is correct today for exactly one reason: one core, and interrupt gates clear `IF` (GAP-0136,
   ADR-0022 §13). §1.11 applies that rule to every word this design adds.

---

## 1. A BLOCKED state

### 1.1 The sixth state is one constant, and every existing scan already handles it

```dart
/// A process that is waiting for something and must not be given the CPU.
/// FIVE, and it is deliberately above KILLED so that every `state > procStateFree`
/// test in this kernel keeps meaning "there is a process here".
const int procStateBlocked = 5;
```

That is the whole state addition, and the reason it is that cheap is worth checking rather than
asserting. Every place in the kernel that reads `procSlotState` today:

| site | test | what it does with BLOCKED = 5 | verdict |
|---|---|---|---|
| `procPickNext` (`proc.dart:1175`) | `== procStateReady` | **does not pick it** | correct, and unchanged |
| `procFreeSlot` (`proc.dart:1156`) | `== procStateFree` | **does not reuse its slot** | correct, and unchanged |
| `procCleanup` / `procBudgetEnd` / `procOnFault` | `> procStateFree` | **tears it down like any live slot** | correct, and unchanged |
| `procSlotLines` (the `proc` report) | prints the number | prints `5` | needs one name in the report, nothing more |

**Not one line of `procPickNext` changes, and that is the point of putting the new value at 5.** A
blocked process is invisible to the scheduler because the picker asks for READY and only READY, and it
is visible to every teardown path because they all ask for "not FREE". This is checkable *before a
boot*, by grep, which is the kind of check this repo prefers: `m20`'s harness should enumerate every
`procSlotState` comparison in every kernel source file and require each one to be `== procStateFree`,
`== procStateReady`, `== procStateRunning` or `> procStateFree` — never `< procStateExited` or any
other ordering that a new value silently changes the meaning of.

### 1.2 What a process blocks ON

Three candidate models, and the choice matters less than writing down which one it is:

1. **A descriptor set** — "wake me when one of these fds is ready". Plan 9, ToaruOS `fswait2`, POSIX
   `poll`. It is what `display-protocol.md` §2.2 and §5.3(2) ask for by name.
2. **A wait channel** — a `u64` token, BSD's `tsleep(chan)`. Maximally general: any subsystem invents
   a token and any subsystem wakes it.
3. **A deadline** — "wake me at tick N". `sleep`.

**Recommendation: (1) and (3), carried as two words in the blocking process's own slot, and NOT (2).**

```dart
const int procSlotWaitMask  = 22;  // descriptor bits; 0 means "a pure sleep"
const int procSlotWaitUntil = 23;  // ABSOLUTE tick deadline; 0 means "no deadline"
const int procSlotWaitKind  = 24;  // reserved. DEADLINE|FDSET today; ADDR (a futex) later
```

Words 22, 23 and 24 are free: slot words 0..15 are `proc.dart`'s metadata, 16..19 are M12's per-process
heap (`heap.dart:186`–`189`), 20 and 21 are M18's counters, 32..53 are the saved frame, and 54..63 are
asserted zero by the harness. **Words 22..31 are unclaimed and unasserted, which is exactly the hole
ADR-0022 §5a fell into**: `procSlotPreempts` was first written as word 16, collided with `heapSlotBase`,
and printed a heap break as a preemption count on a kernel that booted fine. `m18-preempt/run.sh`
already parses every `*Slot*` constant out of every kernel source and requires the indices to be
distinct; adding three constants is safe **only because that check exists**, and the blocking milestone
must keep it.

**Why not a general wait channel.** A `u64` token needs a namespace, and a namespace needs a rule about
who may mint one and what happens when two subsystems collide. With four slots and one wakeable device
that is machinery bought for a generality nobody has asked for. A descriptor is already a namespace
this kernel owns, already refuses out-of-range values, already has an owner row, and is already the
thing the display protocol wants to wait on. The day a futex is wanted (§4), it arrives as a third
`procSlotWaitKind` value with the token being a *physical* address — and that is the moment to
generalise, with a consumer in hand.

**The deadline is absolute and in TICKS, not relative and not in milliseconds.** Relative would have to
be decremented on every tick for every waiter, which turns a wake into bookkeeping; absolute is a
comparison. Ticks rather than milliseconds is §3.3's argument and it is the same one ADR-0022 §10 used
for the quantum budget: *a duration is a different test on every host; a tick count is the same test
everywhere.*

### 1.3 Where the queue lives: **it does not exist, and that is the decision**

There is no allocator, no arrays, and no way to make a node. So a wait queue has exactly two possible
shapes here:

**(a) An intrusive list through the slots.** A `procSlotWaitNext` word holding the next slot index, a
header word holding the head. No allocation — the nodes are the slots. O(1) wake.

**(b) No queue at all. Scan the table.** `procMax` is 4. "Wake everyone waiting on fd *f*" is four
iterations of a loop that already exists in five other places in this file.

**Recommendation: (b), and it is not a shortcut.** A list has to be maintained on *every* transition
out of BLOCKED, and this kernel has five ways out: the wake, `exit`, `procOnFault`'s teardown,
`procBudgetEnd`'s teardown, and `procCleanup` from a refused load. GAP-0098 already records that
teardown here happens from anywhere, abandoning arbitrary stack frames; a linked list whose removal is
skipped by one of those paths is a dangling index into a slot that has since been reused — the exact
failure mode ADR-0022 §5a describes, one layer up. A scan cannot dangle, cannot leak and needs no
invariant. It costs four comparisons per wake, at wake rates of at most a few hundred per second.

**The threshold at which this is wrong, stated up front so nobody has to re-derive it:** when
`procMax` exceeds roughly 32, or when the wake rate exceeds roughly 10 kHz (a NIC at line rate, not a
keyboard). At that point (a) becomes correct and so does an allocator, and both are their own
milestone. **Until then, "the process table is the wait queue" should be written in the source as a
sentence, not left as a shape somebody has to reverse-engineer.**

### 1.4 How a wakeup is delivered from an interrupt handler

**The rule, and everything else follows from it: an interrupt handler NEVER switches. It makes READY.**

```dart
/// Wakes every BLOCKED slot waiting on descriptor [fd] of row [row].
/// Called from a DEVICE INTERRUPT HANDLER. Never switches, never prints
/// more than one line, never touches CR3.
@bare
u64 procWakeFd(u64 row, u64 fd) { ... }        // returns how many it woke

/// Wakes every BLOCKED slot whose deadline has arrived. Called from procTick.
@bare
u64 procWakeDue(u64 now) { ... }
```

Each is a four-iteration scan that, for a matching slot: re-tests readiness (§3.5), writes the result
into the slot's **saved frame RAX word** (§1.5), clears `procSlotWaitMask`/`procSlotWaitUntil`, sets
`procSlotState = procStateReady`, and bumps a counter. It does not call `procSwitchTo`, does not write
CR3, and does not care which process is on the CPU.

**Why an ISR must not switch, even though it could.** The keyboard handler has a 22-word frame in its
hands exactly like `procTick` does, so switching from it is mechanically possible. Three reasons not
to:

* it would make **every device ISR a scheduling point**, so every future driver would have to be
  audited as a piece of the scheduler;
* it would fire while the interrupted code is at CPL 0 — inside a syscall — where `procTick` already
  refuses to switch for the reason GAP-0138 gives, and a keyboard handler has no better claim than a
  timer handler;
* it is not needed. See the latency arithmetic below.

**What that costs, in wake-to-run latency, exactly:**

| the CPU was… | when the woken process actually runs | worst case |
|---|---|---|
| idle (§1.8) | the idle loop re-tests immediately after the `hlt` returns | microseconds |
| running another process in ring 3 | at the next quantum expiry | **80 ms** (`procQuantumTicks = 8` at 100 Hz) |
| inside a syscall | at the first tick after that syscall returns | 80 ms + the syscall |

The 80 ms is the honest number and it is the one to quote. If it ever matters — and for a compositor
answering a keystroke it plausibly does — the fix is **one** narrowly-scoped rule, not a general one:
*a wake that finds the interrupted CS at ring 3 may end the current process's slice*, by writing
`procHeadSlice = procQuantumTicks - 1` so the very next tick switches. That is a hint to the
scheduler, costs nothing, cannot switch stacks out from under anything, and turns the worst case into
10 ms. Recommend it as a **later** refinement with its own before/after measurement, not as part of
the first blocking milestone.

### 1.5 How the woken process gets its answer — and ADR-0022 §1 gains a third case

A blocked process is suspended *inside* `int $0x80`. When it resumes, `isr_common` pops fifteen
registers and `iretq`s, and whatever is in the frame's RAX word is its syscall return value. So the
wake must write the answer there:

```dart
procSet(s, u64(procSlotSaved) + u64(procFrameRaxWord), readyMask);
```

**This is the exact word `procYield` patches and the exact word `procTick` must never touch**
(ADR-0022 §1). That ADR says the RAX patch *"is correct in one path and a bug in the other"*; the
general rule it was reaching for, and which the blocking milestone should write down, is:

> **The saved RAX may be written if and only if the frame was built by `int $0x80`.** A frame built by
> a timer interrupt holds the program's own live register. Frames built by the syscall gate hold a
> syscall number nobody wants back.

A blocked process's frame was built by `int $0x80`, so it qualifies, and the mechanism is one store.

**The alternative — rewind RIP by 2 and re-execute the `int $0x80`** — is Linux's `ERESTARTSYS` and it
is worse here: it requires the syscall's arguments to still be in the frame's RDI/RSI (they are), that
the syscall be idempotent at its block point (it is), *and* that `int $0x80` really was two bytes at
`RIP-2`, which is a claim about the user program's instruction encoding that the kernel cannot check.
One store beats that.

### 1.6 What it does to `procTick` — precisely, and one ordering that is a trap

`procTick` (`proc.dart:1545`) today is: bail if no process is live; bail if the policy is cooperative;
bail (counting) if the tick interrupted ring 0; charge the slice; on expiry, count the quantum, check
the budget, pick, save, switch.

The blocking version inserts **one call, and where it goes is load-bearing**:

```dart
void procTick(u64 frame) {
  // NEW, AND IT IS ABOVE procLive() DELIBERATELY.
  if (procHead(u64(procHeadReady)) > u64(0)) {
    // The tick counter is `.bss` behind `tick_counter_addr()` (interrupts.dart:118)
    // and this handler has just incremented it, so `now` is a load, not a call.
    procWakeDue(Pointer<u64>.fromAddress(tick_counter_addr()).value);
  }
  if (procLive() < u64(1)) { return; }        // unchanged from here down
  ...
}
```

**The trap.** `procLive()` (`proc.dart:1138`) is *"the table is initialised AND a slot is current"*.
When every process is blocked there is **no current slot** — `procHeadCurrent` is 0, which already
means "nobody is on the CPU" (`proc.dart:148`) — so `procLive()` is 0 and a deadline scan placed below
it would **never run while the machine is idle**. Every sleeping process would sleep forever, on a
kernel that looks completely correct and passes any test in which a second process happens to be
runnable. The scan is therefore gated on `procHeadReady` — *the table exists* — and not on
`procLive()` — *somebody is running*.

**And that mutation is testable by booting**, which is more than can be said for M18's CS check
(ADR-0022 §3, GAP-0143 §3): a session whose only process is asleep hangs if the scan is below the
guard, and the harness's negative control is exactly that boot. **The blocking milestone should use
this deliberately** — one of M18's two mutation survivors existed because the case it guarded could
not arise on this machine; this case can be made to arise on demand.

Two further changes inside `procTick`, both small:

* **The kernel-tick early return must not skip the wake scan.** Today a tick that interrupted ring 0
  bumps `procHeadKernTicks` and returns. A deadline must still expire during a long syscall, so the
  scan is above that check too — which the ordering above already gives.
* **`procPickNext` returning `procMax` acquires a second meaning.** Today it means "one runnable
  process, nowhere to go, resume the current one". With blocking it can also mean "*nothing* is
  runnable", and resuming the current one is then wrong because the current one is the process that
  just blocked. In `procTick` this case cannot arise (a blocked process is never RUNNING — it left
  through the syscall path), but the distinction must be written down, because it is the whole of
  §1.8 seen from the other side.

### 1.7 What it does to `procSwitchTo`: **nothing**

`procSwitchTo` (`proc.dart:1486`) is unchanged by this entire design, and that is a result rather than
a coincidence. It writes CR3, restores the FPU, loads the frame, bumps `switches`, resets the slice.
Every one of those is right for a resuming blocked process, because a blocked process differs from a
yielded one in exactly one word of state.

The invariant it relies on — *it is only ever called with a slot `procPickNext` returned, and
`procPickNext` only returns READY slots* — must be stated and mutation-tested: a mutant that makes
`procPickNext` accept BLOCKED must fail a boot (it will resume a process into the middle of a syscall
that never completed, with a stale RAX). That is a boot-visible mutation, unlike ADR-0022's CS check.

The blocking syscall itself is `procYield`'s body with two lines different, which is the same
relationship `procTick` has to `procYield`:

```dart
void procBlock(u64 frame, u64 mask, u64 until) {
  final u64 cur = procCurrent();
  procSaveFrame(cur, frame);
  // NO RAX PATCH HERE. The answer is written by the WAKE (§1.5), not by the block.
  if (procHead(u64(procHeadSse)) > u64(0)) { fx_save(procFxArea(cur)); }
  procSet(cur, u64(procSlotWaitMask), mask);
  procSet(cur, u64(procSlotWaitUntil), until);
  procSet(cur, u64(procSlotState), u64(procStateBlocked));   // <- the whole milestone
  procBumpHead(u64(procHeadBlocks));
  final u64 next = procPickNext(cur);
  if (next == u64(procMax)) { procIdle(frame); return; }     // <- §1.8, the hard part
  procSwitchTo(next, frame);
}
```

### 1.8 THE HARD PART: nothing to run

Everything above is a day's work. **This is the milestone.**

When the last runnable process blocks, the CPU must go somewhere, and today there is nowhere. The
options, with what each actually costs:

**Option A — refuse to block when nothing else is READY** (return "would block"). Cheap, and
**wrong**: it makes a correct program's behaviour depend on how many other programs happen to be
loaded, which is precisely the thing `procYield`'s own doc comment refuses ("A scheduler that made that
a refusal would make a correct program's behaviour depend on how many other programs happened to be
loaded"). Rejected, and named here so nobody rediscovers it as a shortcut.

**Option B — park in a `sti; hlt; cli` loop on the ring-0 stack inside the blocking syscall.** This is
the obvious answer and it is **unsound**, in a way that is worth writing down because it looks fine:
the parked frame sits on the *one* ring-0 stack below RSP0. The moment any other process enters the
kernel from ring 3, the CPU starts pushing at RSP0 — **on top of the parked frame** — and destroys it.
Parking on a shared kernel stack requires a per-process kernel stack, which is item 1 of GAP-0138's
"what preempting ring 0 would need". **Blocking does not need that; parking does.** Rejected.

**Option C — a dedicated kernel idle context**: its own stack, a synthesised 22-word frame with a
ring-0 CS and a RIP pointing at `sti; hlt; jmp`, resumed by `iretq` (which in 64-bit mode always pops
RSP and SS, so returning to CPL 0 on a different stack is legal). Works, but the timer tick that
arrives during it interrupts **ring 0**, so `procTick` refuses to switch away from it — meaning the
idle context has to be special-cased in the one place ADR-0022 §3 most wants left alone. Defensible
(the idle loop holds no locks and touches no non-re-entrant subsystem, so preempting *it* is safe in a
way that preempting an arbitrary syscall is not), but it reopens the argument for a case that has a
cheaper answer.

**Option D — RECOMMENDED. The shell is the idle context.**

The machinery already exists and is already load-bearing. `enter_user` records a kernel RSP into the
assembly-owned resume words; `user_return` restores it and reappears inside `shellProcRun`
(`proc.dart:2302`, and `procBudgetEnd` already uses exactly this to abandon an interrupt frame from
inside the timer handler). `shellMain` already has an idle loop with the right shape —
`interrupts_disable(); test; idle_once()` where `idle_once` puts `sti` and `hlt` adjacent so a wakeup
cannot be missed (`shell.dart:1624`–`1640`).

So: **when nothing is runnable, leave through `user_return` and let the shell's idle loop be the idle
task**; when a slot becomes READY, the shell's loop notices and re-enters through an
`enter_user`-shaped `procResume()`, which records a fresh resume RSP exactly as `procStart` does today.

Four things fall out of it, and all four are good:

1. **No second kernel stack.** Every transition is ring-3→ring-0→ring-3 through the existing door, and
   there is still never two kernel contexts on one stack. GAP-0138's item 1 stays intact.
2. **No ring-0 preemption.** The idle context is the shell, running with `IF` set at CPL 0, and it is
   *cooperative* — it re-tests every time the `hlt` returns. `procTick` needs no special case.
3. **The shell answers commands while processes are blocked**, which is `display-protocol.md` D3's
   entire exit criterion, obtained as a side effect rather than as a second milestone.
4. **`procHeadCurrent = 0` already encodes "nobody is on the CPU"** (`proc.dart:148`), so the idle
   state needs no new representation. The sentinel that exists because "slot 0 must not be ambiguous
   with nothing" turns out to be the idle marker.

**What it costs, stated plainly.** `shellProcRun`'s single meaning — *this call returns when the
session is over* — has to split into two: *the session is over* and *the session is idle*. That is one
word and a loop, and it is the same change D3 requires for a different reason. It also means `IRQ0`
must stay unmasked while a session is idle, which moves `m3-shell`'s byte-exact `ticks` golden
(GAP-0058) — a real cost in somebody else's harness, already identified by `display-protocol.md` D3
item 4, and it should be budgeted once for both milestones rather than paid twice.

**Conclusion for the ladder: the blocked state and a resident process are the same milestone.** They
are two consumers of one missing thing — a scheduler that can be idle. Building either one alone means
building the idle context alone, and the idle context alone has no exit criterion.

### 1.9 Why blocking does not need a per-process kernel stack — and the one rule that keeps it that way

A blocked process here has **no kernel state**: its continuation is 22 words plus an FXSAVE image, and
`isr_common`'s stack frame is abandoned, not saved. That is only true if the block happens **before
the syscall has acquired anything**.

> **THE RULE: a syscall may block only at its first action, before it holds any kernel resource** — no
> half-open descriptor, no half-read sector, no allocated frame, no claim on either 512-byte bounce
> buffer, nothing written into `fileStore`'s metadata.

Everything follows from that rule:

* **`fdwait` is the only blocking syscall.** It takes a mask and a deadline and holds nothing.
* **`read`, `open`, `fdwrite` and `seek` do NOT block** — they keep today's semantics exactly, and a
  device-backed `read` returns 0 for "nothing now", which is precisely the shape `display-protocol.md`
  §2.2 already designed against. **The blocking milestone changes no existing syscall.**
* The day `read` on a *disk* should block (§5, B4), it will have acquired the drive and a bounce
  buffer first — and at that point it needs a place to keep them across a suspension, which is a
  per-process kernel stack, which is GAP-0138. **That is the milestone at which this rule is paid for,
  and it should be paid deliberately.** An interim that costs nothing: have the disk path *return to
  ring 3 and re-enter*, i.e. make a long read a sequence of short non-blocking reads driven by
  `fdwait` on the drive's readiness, which needs the ATA interrupt (IRQ14) and no kernel stack at all.

### 1.10 Storage, priced

Two new counters fit in header words 14 and 15, which are free and asserted zero. The ladder in §5
wants more than two — blocks, wakes, timeouts, idle ticks, and probably a wake-scan count — so plan
one growth rather than two:

| | now | after |
|---|---|---|
| header words | 16 (128 bytes) | 24 (192 bytes) |
| table offset | 128 | 192 |
| FXSAVE offset | 2176 | 2240 |
| `procStoreBytes` | 4224 | **4288** |

The cost is the same one ADR-0022 §5 paid and it is the same list of harness numbers, each spelled out
rather than computed: `m10-elf`, `m11-proc` (two), `m12-heap`, `m13-libc`, `m14-fat`, `m15-fileio`,
`m16-filewrite`, and now `m19-argv`'s 14368 — **every harness that subtracts this block out of `.bss`
moves by 64 bytes.** `argsStore` is the last block in `.bss` (M19), so it is unaffected in kind but its
total moves. Budget it once.

**And keep the seam at three call sites.** `m11-proc/run.sh`'s "one symbol behind three offsets" check
exists to stop a second `@bss` block appearing; wait state is process-table state and belongs in the
process table's block, reached through the process table's three seam functions. M18 was tempted and
refused; this milestone will be tempted harder, because a wait queue *feels* like its own thing. It is
not — §1.3 says there is no queue at all.

### 1.11 One-core safety, applied word by word (GAP-0136's rule)

ADR-0022 §13 set the rule: *anything a second CPU would need a lock for, this kernel gets away with
because there is exactly one instruction stream and interrupt gates clear `IF`*. Each new word has to
be answered for.

**Safe today for exactly that reason, and no other:**

* `procSlotWaitMask`, `procSlotWaitUntil`, `procSlotWaitKind` — written by `procBlock` (the `int 0x80`
  gate, `IF` clear), cleared by `procWakeFd` / `procWakeDue` (device and timer gates, `IF` clear). One
  core means a wake cannot land inside a block.
* `procSlotState` transitioning RUNNING→BLOCKED→READY — same two gates.
* The new counters — read-modify-write, interrupt context only, same as M18's six.

**A genuinely new hazard, which did not exist before this design and must be written into the source:**
the wake path writes a **saved frame word** (`procSlotSaved + procFrameRaxWord`) of a process that is
not running. On one core, the only code that could be reading that frame is `procLoadFrame` inside
`procSwitchTo`, which cannot be executing because we are inside an interrupt handler with `IF` clear.
On two cores it is a torn resume. **It belongs in GAP-0136's list as the first piece of *process*
state, rather than *scheduler* state, that a second CPU would corrupt.**

**And one thing that is safe for a second, independent reason worth keeping:** the idle path (§1.8)
runs at CPL 0 with `IF` **set**, which is new — until now the only ring-0 code that runs with `IF` set
is the shell. The rule that keeps it safe is that the idle loop touches exactly two words (its "is
anything READY" test) and takes them with `interrupts_disable()` around the test, which is the
discipline `shellMain` already uses for `shellState()` and which `shell.dart`'s own header documents.
**Do not invent a second discipline for it.**

---

## 2. The kernel is not preemptible

### 2.1 What is true today, measured rather than argued

* Every syscall runs with `IF` clear (interrupt gates), so a tick inside one is **not delivered**, and
  a second tick in the same window is **lost** — the 8259 cannot queue two.
* `procTick` additionally refuses to switch when the interrupted CS is ring 0, and counts those ticks
  in `procHeadKernTicks`. **On the M18 harness's boot that counter reads 1** — the single tick that can
  arrive at CPL 0 with a process live, in `enter_user`'s three-instruction window between recording the
  resume RSP and its `cli`. The CS check is therefore correct and almost never load-bearing, and
  ADR-0022 §3 says a large value there should be treated as the bug.
* The ATA driver polls: `ataPollLimit = 0x200000` = **2,097,152 status reads** before giving up
  (`ata.dart:206`), with the drive's own interrupt masked at the device (`nIEN`) and the slave PIC
  fully masked, so IRQ14 cannot be delivered at all. `ata.dart`'s own comment prices the budget at
  *"on the order of a second"* on real hardware.

**So the honest worst case is not "one quantum".** It is: one `read()` on a cold drive can hold the
machine for order-of-a-second, during which roughly a hundred ticks are destroyed rather than deferred,
`tick_count` under-reports elapsed time by that much, and no other process runs. **That is unbounded
in wall-clock in the only sense that matters: the bound is an iteration count on a device, not a
duration the kernel controls.**

### 2.2 The unbounded thing is a WAIT, not a syscall

Enumerate what a syscall on this machine actually does:

| syscall | work | bounded by |
|---|---|---|
| `write` | ≤ 128 bytes to the UART, polling THRE | the UART's own rate — microseconds |
| `read` / `fdwrite` | ≤ 512 bytes, **plus a disk transfer** | **`ataPollLimit`: the device** |
| `open` | a FAT directory scan **plus disk reads** | **the device** |
| `sbrk` | maps pages | a handful of frame allocations |
| `yield`, `preempts`, `exit` | pure | tens of instructions |

**Every unbounded entry in that table is a device wait, and none of them is computation.** The
computation in this kernel is already bounded and already small: 512 bytes is `fileReadMax` by
deliberate design, so that "the loop cannot be wrong about how many times it has to go round"
(`file.dart:293`).

That reframes the question. Making a *computation* interruptible needs re-entrancy and a second kernel
stack. Making a *wait* interruptible needs neither — it needs the wait to stop existing, replaced by an
interrupt and a blocked process. **The answer to "the kernel is not preemptible" is mostly §1.**

### 2.3 The four levels, in the order they are worth doing

**L0 — Delete the waits. (Recommended next, and it is §1 + §5's B4.)** Unmask the cascade and IRQ14,
clear `nIEN`, and make the data phase of a disk transfer an interrupt that wakes a blocked process
instead of a poll loop that owns the CPU. Cost: the slave PIC has been `0xFF` since M2 and this would
be its first use — **shared with `display-protocol.md` D1**, which needs IRQ12 for the mouse and the
cascade for both. Buys: the longest syscall becomes a bounded copy; ticks stop being destroyed; two
processes can overlap I/O with computation, which is *most of what a scheduler is for* (GAP-0141).

**L1 — Make the remaining spins interrupt-*visible* without making them preemptible.** A narrow `sti`
window around a poll loop means ticks are **delivered and counted** even though `procTick`'s CS check
still refuses to switch. Time stops being destroyed; `tick_count` becomes a measure rather than a lower
bound (GAP-0138 item 3). **Safe only where the interrupted code shares no state with any handler** —
and the handlers touch the tick counter, the keyboard state, the UART and `procStore`. A poll loop in
`ata.dart` touches the drive and a bounce buffer and none of those, so it qualifies; a loop inside
`uartWrite` does **not**, because a handler printing a diagnostic would interleave characters into a
byte-exact golden. **This is a per-site argument, not a global switch, and it must be written as one.**

**L2 — Preempt ring 0.** The full price, unchanged from GAP-0138: a second ring-0 stack per process,
plus re-entrancy in the frame allocator, the FAT cluster cache, the descriptor table and the UART.
None of them is re-entrant, none is guarded, and a lock in a kernel with one core and no atomics is
`cli`/`sti` — which is what the interrupt gates already do.

**L3 — A preemptible kernel with real locks.** This is an SMP design, and it should be *entered from*
the SMP question rather than arrived at from the latency one.

### 2.4 Recommendation: LATER, and here is the falsifier

**Ring-0 preemption is not the right next step**, for four reasons in decreasing order of strength:

1. **It fixes the wrong thing.** After L0 there is no syscall long enough to be worth preempting.
2. **It costs the property everything else rests on.** `proc.dart`'s header sentence — one RSP0 is
   enough because only one process is ever inside the kernel at a time — is load-bearing for the whole
   frame-as-continuation design, and §1.9 shows blocking *keeps* it while parking and preemption both
   destroy it.
3. **No consumer wants it.** The display protocol wants blocking (§2.2, §5.2 of that document); a
   network stack wants blocking; disk I/O wants blocking. Nothing named in this repo wants a
   preemptible syscall.
4. **It is measured to be nearly inert today.** `procHeadKernTicks = 1`.

**The numbers that would change this answer**, so the decision is falsifiable rather than permanent:

* `procHeadKernTicks` growing beyond single digits on an ordinary boot — the CS check would then be
  doing real work, and ADR-0022 §3's argument would have stopped being true.
* A measured count of **lost** ticks during a disk read. Today that number cannot be produced, and
  producing it is cheap: **latch the PIT's channel-0 counter** (a mode-command write of `0x00` to port
  `0x43`, then two reads of `0x40`) to get sub-tick elapsed time, take it before and after a syscall,
  and compare against `tick_count`'s delta. That is one new function, no new hardware, and it turns
  "the kernel destroys time" from a paragraph into a number. **Recommended as a small unit of its own,
  independent of everything else here** — it makes L1's benefit measurable before L1 is built.

---

## 3. `fdwait` — wait with a timeout over N descriptors

`display-protocol.md` §2.2 and §5.3(2), and the network design, both want this and both name
ToaruOS's `fswait2(count, fds, timeout_ms)` as the shape. Here is the specification.

### 3.1 The ABI

```
   syscall 11:   fdwait(mask, timeoutTicks) -> readyMask
                 RDI = mask            bit f set = "tell me about descriptor f"
                 RSI = timeoutTicks    0 = poll; N = block up to N ticks; ~0 = refused (§3.4)
                 RAX = readyMask       bits set = ready; 0 = timed out; ~0 = refused
```

**A MASK, not a pointer to an array, and that is a deliberate divergence from `fswait2`.** Three
reasons:

1. **`fileMaxFds = 4`.** A descriptor number is 0..3. The entire "set of N descriptors" fits in a
   nibble, and a nibble fits in a register. An array of four `u64`s to express four bits is a pointer
   the kernel must then validate.
2. **A pointer argument means a validator**, and the refusal floor M16 mutation-tested with fourteen
   mutants is a thing to inherit, not to extend. `fdwait` with no pointer cannot have a pointer bug.
3. **`@bare` DCDart has no arrays** (§0 item 4). Every array in this kernel is hand-indexed donated
   `@bss`, and a user-supplied one would be hand-indexed donated user memory.

**`fswait2(count, fds[], timeout_ms)` is then three lines in `core/user/libc/`** that fold the array
into a mask and the milliseconds into ticks. A future compatibility shim gets the POSIX-ish shape for
free, and the kernel ABI stays one instruction wide. This is the same call GAP-0128 made when it named
`fdwrite` rather than overloading `write`: **the kernel's name says what the kernel does; the library
provides the shape the ecosystem expects.** Call the syscall `fdwait` for exactly that precedent.

### 3.2 The semantics table

| `mask` | `timeoutTicks` | behaviour |
|---|---|---|
| 0 | N > 0 | **`sleep(N)`.** Blocks; returns 0 at the deadline. |
| M ≠ 0 | 0 | **Poll.** Tests readiness now, returns the ready bits (possibly 0), **never blocks**, does not count as a block. |
| M ≠ 0 | N > 0 | Blocks until a descriptor in M is ready **or** the deadline; returns the ready bits, or 0 on timeout. |
| 0 | 0 | Returns 0 immediately. A well-defined nothing, not an error. |
| any | ~0 (forever) | **Refused** — see §3.4. |

**One primitive, three uses, one block point.** `sleep` is not a separate syscall and should not be:
two blocking syscalls means two places that must get §1.9's rule right, and the second one is where
somebody blocks while holding a bounce buffer.

### 3.3 The timeout is in TICKS, and this is the one place the design argues with ToaruOS

`fswait2` takes milliseconds. This kernel should take **ticks**, and the libc wrapper should do the
conversion, for the reason ADR-0022 §10 gave when it made the runaway budget a count of quanta rather
than a number of seconds:

> *"Run for a second" is a different test on every host. "Run for 24 quanta" is the same test
> everywhere, and the harness requires the number the kernel prints to equal the number typed at the
> shell, exactly.*

A tick is 10 ms because the PIT divisor is 11932 (`interrupts.dart:298`). A millisecond timeout would
be rounded by the kernel, and a rounded value is one no harness can assert exactly; a tick count wakes
at *exactly* `deadline` and the harness can require `wakeTick - blockTick == N` with no tolerance. **A
tolerance in an exit criterion is where a scheduler bug hides.**

The libc wrapper needs `HZ`. Publish it as a constant in the libc header *and* assert in the harness
that it equals the kernel's divisor-derived rate, so the two cannot drift.

### 3.4 Refusals, each with a sentence

Same discipline as `procCreate`'s ten refusal codes and `file.dart`'s return values (`~0` is already
this kernel's refusal value, `userRefused`, `user.dart:743`), which is what makes the three outcomes — ready, timed
out, refused — distinguishable without a signed errno in a language with no signed type.

| condition | why |
|---|---|
| no process is live | `yield`'s reason exactly: the wait state lives in a process-table slot. An M9 payload or a `run <name>` program (descriptor row 4, `fileRunRow`) has no slot and cannot block. |
| a bit set above `fileMaxFds` | a set bit that names nothing is a client bug, and silently ignoring it hides it. |
| a bit naming a descriptor that is not open | same. **Not** "ready" and **not** "never ready" — refused. |
| `timeoutTicks == ~0` (wait forever) | **RECOMMENDED REFUSAL, and it is temporary.** There is no kill, no signal and no `^C` in this kernel (GAP-0140). A process blocked forever is a slot that can never be freed and a session that can never end — the same argument that made `proc spin` demand a budget up front. **Lift this the day there is a way to kill a process**, and not before. |

### 3.5 Readiness is level-triggered and re-tested by the kernel

**Definition per descriptor kind**, because "ready" is not one thing:

| kind | ready means |
|---|---|
| a regular file on the FAT volume | **always ready.** A file never blocks — same as `poll(2)`. A mask containing one returns immediately with that bit set, which is correct and not a degenerate case. |
| the input queue (`display-protocol.md` D2) | the queue is non-empty. |
| a `WSYS` session (D4+) | an event record is queued for this client. |
| a socket (network design) | receive queue non-empty, or a connect/accept completed. |

**Level-triggered, and the wake re-tests.** `procWakeFd` runs when a device *becomes* ready, but by the
time the woken process runs, another process may have drained the queue. So the wake path re-tests
readiness before it deposits a mask, and if nothing is ready any more it leaves the process BLOCKED
with its **original deadline**, unchanged. With a four-slot scan that costs nothing, and it removes the
entire class of spurious-wake bug — a class this kernel would otherwise meet for the first time.

**A consequence to state rather than discover:** two processes waiting on one descriptor are both
woken, and the loser gets a subsequent `read` of 0 bytes. With one input queue and one compositor that
does not arise; it will arise the first time two clients share a device, and the correct answer then is
still "the reader must tolerate 0", which is the semantics the display protocol already has.

### 3.6 What it does to the display protocol's main loop

`display-protocol.md` §2.2 today:

```c
   while (read(fd, ev, sizeof ev) == 0) yield();     /* a spin through the scheduler */
```

with `fdwait`:

```c
   for (;;) {
       unsigned ready = fdwait(1u << fd, 16 /* ticks = 160 ms */);
       if (ready) { while (read(fd, ev, sizeof ev) > 0) handle(ev); }
       redraw_if_needed();                            /* the timeout is the animation clock */
   }
```

That is *"redraw when the compositor says so, but also in 16 ms"* — §5.3(2)'s native justification,
literally. **And `read` still returns 0 for "nothing now"**: `fdwait` does not change one line of the
file syscalls, which is §1.9's rule paying for itself.

---

## 4. Threads

### 4.1 What a process is here, exactly

A slot: 64 words of metadata, its own PML4/PDPT/PD/PT (`procSlotPml4`..`procSlotPt`), a 512-byte
FXSAVE area, a 22-word saved frame, four descriptors in its row of `fileStore`, a heap in slot words
16..19, and a 2 MiB ring-3 window at `0x10000000` with the stack at page 511 and the heap growing to
page 509. Four of them exist, ever.

A thread would be: a slot **sharing** the four page-table words with its leader, its own FXSAVE area
(already per-slot), its own saved frame (already per-slot), its own stack **inside the same 2 MiB
window**, its own TLS base, and a synchronisation primitive.

### 4.2 Does this OS want them? Not yet — and the honest reason is that *the thing that motivates them does not need them*

The brief is right that **ffmpeg and libwayland link mutex operations unconditionally.** But linking a
mutex is not the same as needing concurrency:

* `pthread_mutex_lock` / `unlock` / `init` / `destroy` on a single-threaded process is *a function that
  returns 0*, and every no-thread libc in existence ships exactly that. The uncontended path in musl
  and glibc is an atomic compare-exchange that always succeeds; with one thread it always succeeds
  trivially.
* `pthread_self` is a constant. `pthread_once` is a flag. `pthread_key_*` is a small table.
* **`pthread_create` must FAIL — with `EAGAIN` — and must not pretend.** A library that checks the
  result runs single-threaded; a library that ignores it was going to be broken anyway. libwayland
  takes the lock and never spawns. ffmpeg has a single-threaded path and honours `-threads 1`.
* The one thing a stub genuinely cannot fake is **`pthread_cond_timedwait` actually waiting** — and
  what that needs is §3's `fdwait`, not threads.

**So the minimum to link the software that motivated the question is a libc unit with ZERO kernel
changes.** That is a real finding and it should be the recommendation: build the stubs, be explicit in
their source that they are stubs, make `pthread_create` fail loudly, and spend the kernel budget on
blocking instead.

### 4.3 If threads are ever built, the minimum, and the hazard that must be fixed first

**The hazard, first, because it is a use-after-free and it already exists in a different disguise.**
`procSpaceFree` frees **every present leaf in the window unconditionally**, and `freeFrame` is a plain
bit-clear with no reference count. `display-protocol.md` §1.3 found this for shared surface frames and
§8 asks for a GAP entry about it. **Two slots sharing a PML4 is the same bug one level up**: the first
thread to exit frees its leader's page tables and every page in them, under the other threads' feet,
silently at the machine level. **Threads must not be built before frames and page tables are
reference-counted**, and that is a `pmm.dart`/`proc.dart` milestone with its own ADR.

The minimum after that:

1. **`spawn_thread(entry, stackTop, arg)`** — `procCreate` without `procSpaceBuild`: a slot whose four
   table words are *copied* from the leader, plus a leader index and a per-space reference count so
   teardown frees the address space exactly once. `procInitFrame` already synthesises a resume frame
   from `(entry, rsp, rdi)`, so the thread's first run needs no new mechanism at all.
2. **Per-thread stacks inside the 2 MiB window.** Pages 511, 510 and 509 are taken (stack, guard,
   heap top). Four threads at one page each is four pages out of 512 — affordable, but it collides
   head-on with `display-protocol.md` §1.2, which found the 2 MiB window to be the binding constraint
   on the whole window system. **Threads make the window question urgent; they do not answer it.**
3. **TLS.** `__thread` and a threaded libc's `errno` need `%fs`, which needs `IA32_FS_BASE`, which
   needs `wrmsr` — a privileged instruction this kernel executes only in `boot.S` for EFER. That is a
   new primitive, and CLAUDE.md rule 3 applies: scope it as narrowly as the real need (one
   `set_fs_base` syscall over one `wrmsr` extern, not general MSR access), and decide in the DCDart
   repo whether it is a language primitive or an assembly stub. **A single-threaded libc puts `errno`
   in a global and needs none of this**, which is the fourth reason §4.2's answer is "not yet".
4. **A futex-shaped primitive.** `wait_on(addr, expected, timeoutTicks)` / `wake(addr, n)` is §1's
   block and wake with `procSlotWaitKind = ADDR` and the token being the **physical** address of the
   word — physical rather than virtual so that the same primitive works for two *processes* sharing a
   page later, and so the token means one thing when there are several address spaces.
5. **`procMax = 4` becomes the binding limit on everything.** Four threads *total, across all
   processes*. Raising it is "`procStoreBytes` and one number in `kdata.S`" plus every harness number
   in §1.10's table again.

### 4.4 Ordering: strictly after blocking, and the reason is not preference

**A thread exists so that one flow of control can wait while another runs.** On a kernel where nothing
can wait, threads buy nothing that `yield` in a loop does not already buy — and they cost a shared
address space, a reference-counted PMM, TLS, an MSR primitive and a futex. **Blocking is a
prerequisite, not a neighbour.**

And the failure mode to avoid is named in `display-protocol.md` §5.3(2): *a single-handle wait, or one
with no timeout, forces a shim to use a thread per handle on an OS with no threads.* **§3 is what
stops threads from being needed for the wrong reason.** Build `fdwait` and the pressure for threads
mostly evaporates; build threads first and `fdwait` still has to be built afterwards anyway.

---

## 5. The milestone ladder

Same rules for a derived expectation as `display-protocol.md` §6 restates and M7–M19 established:
compute the expectation from a source the kernel does not control; restate the kernel's rules in the
harness rather than importing them; assert every copied constant against the kernel's source;
structural checks before boot checks; **and a negative control that must fail.**

**The inverse-of-M18 discipline, which is the whole shape of this ladder.** M18 proved preemption with
*a program that never yields* — `build-progs.sh` disassembles progC and requires **zero** `int $0x80`
instructions in it, so the switches observed cannot be the program's own doing. A blocking milestone
needs the mirror image: **a program that never spins.** Its body must contain no backward branch at
all between its two prints, and exactly one syscall between them, asserted by disassembly. Then
"it made progress" cannot be explained by anything except a wake. And the vacuity guard — the
equivalent of `check-pixels.py` refusing to pass against a blank screen — is that **the kernel must
have been idle**: a new `procHeadIdle` counter (ticks taken with the table live and nobody current)
must exceed the derived sleep length, so a kernel that "blocked" by spinning in ring 3 fails.

---

### B1 — A process can wait, and the machine is idle while it does

**Blocked on: work only. This is the milestone; everything else on this ladder is small by
comparison.** It is also `display-protocol.md`'s D3 — see §1.8 — and the two should be one unit.

Adds: `procStateBlocked`; three slot words and the header growth of §1.10; `procBlock`; `procWakeDue`;
the `procTick` reordering of §1.6; `fdwait` (syscall 11) with `mask == 0` only; and the idle context of
§1.8 (`user_return` to the shell's loop, `procResume` back in).

*Binary, boot 1:* a program prints `A`, calls `fdwait(0, 30)`, prints `B`, exits. The kernel prints
`PROC BLOCK <slot> UNTIL <tick>` and `PROC WAKE <slot> AT <tick>`; the harness requires
`wakeTick − blockTick == 30`, **exactly**, with no tolerance. `procHeadIdle` ≥ 29. The program's
`procSlotPreempts` is **0** — it never consumed a quantum. `build-progs.sh` disassembles the program
and requires zero backward branches and exactly one `int $0x80` between the two `write` calls.

*Binary, boot 2 (the ordering claim):* two programs, A blocks for 30 ticks, then B blocks for 10. The
wake lines must appear **B then A** — deadline order, not slot order and not FIFO order. This is
falsifiable against the most likely wrong implementation.

*Binary, boot 3 (the idle claim):* while both programs are blocked, the harness types `ticks` at the
shell and gets its normal output; both programs then wake and finish. This is D3's exit criterion and
it is free here.

*Negative control 1:* a build with `procWakeDue` moved **below** `procLive()` (§1.6's trap) must hang
with `B` never printed, ending only at the quantum budget.
*Negative control 2:* a build with `procPickNext` accepting BLOCKED must fail — the resumed process
returns from a syscall that never completed.

---

### B2 — A descriptor can be waited on

**Blocked on: B1, and on `display-protocol.md` D2** (the input queue is the first wakeable descriptor
this machine has; before D2 there is no asynchronous wake source except the timer).

Adds: non-zero masks in `fdwait`; per-descriptor readiness (§3.5) with the level-triggered re-test;
`procWakeFd` called from the keyboard ISR after it pushes to the queue.

*Binary:* a program calls `fdwait(1<<fd, 200)` on the input descriptor. The harness waits for the
kernel's `PROC BLOCK` line, injects a known keystroke over QMP, and requires: the program prints
**exactly** the injected scancode; the returned mask has **exactly** one bit; the program's slice and
preempt counters are **0** across the whole wait; and `procHeadIdle` grew. Then `fdwait(1<<fd, 0)` on an
empty queue returns 0 **without** incrementing `procHeadBlocks` — the poll case really does not block.
*Negative control:* the same boot with `procWakeFd` removed from the ISR must reach the timeout instead
and return 0, proving the test is sensitive to the wake rather than to the deadline.

---

### B3 — Two descriptors and a timeout, and the timeout is the one that fires

**Blocked on: B2 and a second wakeable descriptor** — realistically `display-protocol.md`'s D4 `WSYS`
session, or a pipe if one arrives first. **State the dependency honestly rather than inventing a second
device to test with.**

*Binary:* a program waits on a two-bit mask with a 20-tick timeout, three times: once where descriptor
X is fed, once where descriptor Y is fed, once where neither is — returning `1<<X`, `1<<Y` and `0`, and
in the third case waking at exactly `blockTick + 20`. *Negative control:* a mask naming a closed
descriptor must be **refused** (`~0`), not treated as never-ready.

---

### B4 — The disk stops spinning the machine

**Blocked on: B2, and it shares the slave-PIC work with `display-protocol.md` D1** (the cascade has
been masked at `0xFF` since M2; D1 needs IRQ12, this needs IRQ14).

Adds: clearing `nIEN`, unmasking the cascade and IRQ14, an `isrDispatch` arm at vector `0x2E` with an
**EOI to both PICs**, and a disk read that waits by blocking rather than by polling — within §1.9's
rule (see its last bullet: a long read becomes a sequence of short transfers driven from ring 3, so no
per-process kernel stack is needed).

*Binary, and it is the cleanest statement of what blocking buys:* while process A reads a derived
number of sectors, process B's ring-3 slice counter **advances by at least one quantum**. That is
impossible today by construction. Plus: a new count of ATA poll iterations for the data phase drops to
**zero**; `procHeadKernTicks` stays in single digits; and the bytes read are identical to today's,
compared against the host's own copy of the file.
*Negative control:* the same read with the drive's interrupt left masked must fall back to polling and
show B's counter **not** advancing — so the assertion is sensitive to the interrupt, not to the read.

---

### B5 — Time stops being destroyed, and it is a number

**Blocked on: nothing. Can be built at any point, and is most useful BEFORE B4** because it is how B4's
benefit is measured.

Adds: a PIT channel-0 latch read (§2.4) giving sub-tick elapsed time, and a narrow `sti` window around
exactly the ATA poll loop (§2.3 L1) — argued per site, never globally.

*Binary:* across a derived disk read, `tick_count`'s delta and the latched-clock delta agree to within
one tick. On a build without the `sti` window, they must **disagree** by the derived number of lost
ticks — the negative control and the measurement are the same experiment run twice.

---

### B6 — Threads, and only the half that costs nothing

**Blocked on: nothing in the kernel.** This is a `core/user/libc/` unit.

Stub `pthread_mutex_*`, `pthread_cond_*` (with `timedwait` implemented over `fdwait`), `pthread_once`,
`pthread_self`, `pthread_key_*`, and a `pthread_create` that returns `EAGAIN`.

*Binary:* a C program that takes and releases a mutex a derived number of times, calls `pthread_once`
twice and observes one initialisation, calls `pthread_cond_timedwait` and is woken at exactly the
derived tick, and calls `pthread_create` and prints the refusal. `nm` on the linked binary shows **no
undefined `pthread_*` symbols**. *Negative control:* a build with `pthread_create` returning 0 must fail
the harness — a stub that lies is worse than no stub.

**Real threads (a shared address space) are NOT on this ladder**, and §4.3 says what they would need
first: a reference-counted PMM. That is its own milestone with its own ADR and it should be entered
from the shared-frame question (`display-protocol.md` §1.3/§8), not from the thread question.

---

## 6. What I did not decide, and would rather be told

**Q1 — Is the idle context the shell (§1.8 Option D), or a dedicated kernel idle task (Option C)?**
I recommend D: it needs no second kernel stack, no ring-0 preemption special case, and it delivers
`display-protocol.md`'s D3 as a side effect. It costs `shellProcRun` a second meaning and it moves
`m3-shell`'s `ticks` golden (GAP-0058) because IRQ0 must stay unmasked. **That golden moves either way
the moment there is a resident process**, so the question is really about ordering, not about cost.

**Q2 — Is `fdwait`'s timeout in ticks (§3.3) or in milliseconds?** I recommend ticks in the kernel and
milliseconds in libc, and the argument is ADR-0022 §10's, verbatim. This is a deliberate divergence
from `fswait2`, and a compatibility shim pays for it in three lines of arithmetic. **Worth a
confirmation because it is in a syscall ABI, which is the expensive place to change one's mind.**

**Q3 — Is "wait forever" refused until there is a kill (§3.4)?** I recommend yes, on
GAP-0140's argument. It means a first compositor must pass a timeout, which is what a compositor
should be doing anyway. The alternative is a machine that can be wedged by a correct-looking program,
in a kernel with no `^C`.

**Q4 — Should a wake shorten the running process's slice (§1.4)?** It turns an 80 ms worst-case
wake-to-run latency into 10 ms for one line of code. I recommend **deferring** it until there is
something whose responsiveness can be measured, and then landing it with a before/after number, because
"it feels snappier" is not an exit criterion.

**Q5 — Do threads get built at all?** §4 argues that the software that motivated the question links
against stubs and runs single-threaded, and that real threads need a reference-counted PMM first. **If
the answer is "yes eventually", the thing to do NOW is nothing** — except to know that the 2 MiB window
(`display-protocol.md` §1.2) and `procMax = 4` are the two numbers that will bind, and that neither
should be chosen as a side effect of some other milestone.

---

## 7. Notes for the coordinator to fold in elsewhere

**A factual error in `known-gaps.md` that this document contradicts.** GAP-0141's blocking bullet
reads *"There are four states — FREE, READY, RUNNING, EXITED, KILLED — and no fifth."* It names five
and says four. ADR-0022 §12 is the correct original — *"a process is READY, RUNNING, EXITED or KILLED,
and there is no fifth state"* — which counts four because it excludes FREE. `display-protocol.md` §0
item 4 has it right: **five states, and BLOCKED would be a sixth.** Worth fixing in place, because
this exact sentence is quoted in three documents and is about to be quoted in an ADR.

**Three gaps this document is the successor to, and each should point here once it exists as an ADR:**
GAP-0097 (cooperative → narrowed at M18 → blocking is the remaining half), GAP-0138 (ring 0 is not
preemptible — §2 argues that is the *right* state and says what would change the answer), and GAP-0141
(the blocking, sleep and SMP bullets).

**A new hazard for GAP-0136's list.** The wake path writes another process's **saved frame** word
(§1.11), which is the first time *process* state rather than *scheduler* state is written across a
context boundary. It is safe on one core for the existing reason and would be a torn resume on two.

**The reference-counting hazard is now wanted by two designs, not one.** `display-protocol.md` §8 asks
for a GAP entry about `freeFrame` being a bit-clear and `procSpaceFree` freeing every present leaf
unconditionally. §4.3 shows **threads are the same bug at the page-table level**. One entry covers
both, and it should say so, because the fix (a reference count in the PMM) is the shared prerequisite.

**Shared work between this ladder and the display ladder, so it is scheduled once and not twice:**

| work | wanted by |
|---|---|
| the idle context / a resident process | B1 **and** D3 — *the same milestone* |
| unmasking the 8259 cascade (`0xFF` since M2) | B4 (IRQ14) **and** D1 (IRQ12) |
| the input queue | B2 (the first wakeable descriptor) **and** D2 |
| IRQ0 permanently unmasked, moving `m3-shell`'s golden | B1 **and** D3 |
| a growable ring-3 window | threads (§4.3) **and** D-anything full-screen (§1.2 of that doc) |

**And the one sentence to carry into whichever ADR lands first:** *a process blocked in this kernel has
no kernel state, and every design decision here exists to keep that true* — because the day it stops
being true, the price is a per-process kernel stack, re-entrancy in four subsystems, and the end of the
one-RSP0 argument that `proc.dart` has rested on since M11.
