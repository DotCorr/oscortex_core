# ADR-0027 — The first IPC primitive: a bounded, asynchronous, two-endpoint channel

**Status:** Accepted (M20)
**Supersedes nothing. Narrows:** GAP-0096 item 3 ("there is no way for one process to affect
another — no signals, no kill, no shared memory, no pipe, no message"). **Moves goldens:**
GAP-0095's list, extended — see §8.1.
**Verified by:** `core/tests/conformance/m20-ipc/run.sh`

---

## 0. The problem, stated as small as it actually is

Since M11 this operating system has run two processes in two different address spaces. M11's `proc
cross` proves the isolation with a `#PF`: process B dereferences an address process A has mapped and
B has not, and the CPU refuses it. M18 made the switching preemptive. M19 gave a program a command
line.

And the two processes **cannot say one word to each other**. There is no shared memory, no pipe, no
signal, no socket, no message. Isolation without communication is not an operating system; it is two
programs that happen to be on the same machine.

M20 is the first thing that crosses that boundary on purpose.

---

## 1. What was built

`core/kernel/chan.dart` and three syscalls:

| # | Call | Returns |
|---|---|---|
| 11 | `chanopen(port)` | an endpoint handle `(port << 1) \| side`, or a refusal |
| 12 | `chansend(ep, ptr, len)` | `len`, or a refusal |
| 13 | `chanrecv(ep, ptr, cap)` | the number of bytes delivered, or a status, or a refusal |

A **channel** is a kernel object with exactly **two endpoints** and **two independent rings**, one per
direction. Each ring holds up to 8 messages of at most **64 bytes**. Neither call ever blocks: a full
ring is `chanRetFull` and an empty one is `chanRetEmpty`, both handed back to ring 3 as values.

There are two channels (`chanPorts = 2`), because a channel has two endpoints and `procMax` is 4, so
two is the most that can be simultaneously open on this machine. They live in one 2624-byte `@bss`
block. **IPC allocates nothing** — it cannot fail for want of memory and it costs the frame allocator
nothing, which the harness checks by bracketing two whole sessions with `frames`.

---

## 2. Why a bounded asynchronous queue, and why 64 bytes is the design

The client this exists for is a compositor, and the brief was explicit: *a compositor moves large
pixel buffers and small input events, and those two have opposite requirements; do not pick one and
discover later it cannot carry frames.*

### 2.1 The three realistic options

**Synchronous message ports (L4/seL4-style rendezvous).** `send` blocks until the peer receives. It
is the smallest possible kernel object and it needs no buffers at all. **Rejected**, for one reason
that is fatal for this client: *it makes the compositor's liveness depend on every client's.* A
display server that blocks in `send` because one client stopped calling `recv` has stopped compositing
for everybody. seL4 works around this with a separate Notification object and non-blocking variants,
and building a compositor on it is still hard for exactly this reason. There is a second, cheaper
reason: a blocking primitive needs a wait queue, a `blocked` process state and a wakeup path, which is
real surgery on `proc.dart`. This milestone adds **no new scheduler state at all**.

**Shared memory regions with a notification channel.** This is what the frame path actually has to be.
**Deferred, not rejected** — see §3. It is the *next* rung of the ladder, and building it here would
have made this milestone two milestones.

**A bounded asynchronous queue of fixed-size messages.** Chosen. `send` and `recv` are total
functions of kernel state; neither can wait; a full ring is the sender's problem and an empty ring is
the receiver's. A compositor is never stopped by a client, and a client is never stopped by a slow
compositor.

### 2.2 Why the message is capped at 64 bytes, in the kernel

This is the part that answers "do not pick one and discover later it cannot carry frames", and the
answer is **not** "this one can carry frames." It is: **this one is built so that nobody can ever
believe it does.**

At 800×600×32 a frame is **1,920,000 bytes**. The kernel's entire mutable static budget, with this
file in it, is **16,992 bytes**. A message channel that could carry a frame would have to copy 1.92 MB
through the kernel *twice* — once in, once out — per frame, at 60 Hz. That is 230 MB/s of byte stores
in a loop with interrupts disabled, and it would need a megabyte of kernel buffer per queued frame.

A message primitive with a *generous* cap is the trap. 4 KB looks harmless, and then somebody
chunks a frame across it, and the design has failed quietly and expensively. So `chanMsgBytes` is 64,
it is checked in the kernel on every call, and `m20-ipc/run.sh` asserts the constant by name with a
message saying that changing it abandons this argument.

**What that forces, correctly:** bulk data travels **by reference**. A message carries the *name* of a
region, not its contents. And it is the right shape for the other reason too — the two payloads have
opposite delivery semantics:

| | input events | pixel frames |
|---|---|---|
| must not be lost | yes | **no** — a compositor draws the newest and skips stale ones |
| must be ordered | yes | irrelevant |
| must not be copied | irrelevant | **yes** |
| size | tens of bytes | megabytes |

A single primitive doing both would have to be a queue (wrong for frames: it queues frames nobody
will draw) or a shared buffer (wrong for events: it loses them). They are two mechanisms because they
are two problems.

### 2.3 What that costs, and why it is cheap

The message is **opaque bytes to the kernel**. It copies `len` of them and looks at none. So the frame
descriptor a later milestone needs — region handle, offset, length, width, height, stride, sequence,
damage rectangle — is 8 × `u64` at most, fits inside 64 bytes with room to spare, and adding it
**requires no change to `chan.dart` whatsoever**. The ring does not move. The syscalls do not change.
That is the sense in which this design "can carry frames": it is already the notification half of the
mechanism that will.

---

## 3. What this deliberately is NOT

Each with a gap number, so none of it is left as an impression:

* **Not a rendezvous, and not synchronous.** §2.1.
* **No blocking receive, no wait queue, no wakeup.** A receiver polls; under M18's preemption a
  polling receiver burns its quantum and is switched away. **GAP-0160**, which also records that
  everything a `chanwait` would need is already in the ring's state.
* **No capability or handle transfer.** A message is bytes; it cannot convey authority. **GAP-0161**.
* **No naming.** A port is a small integer both peers agree on by convention. There is no registry and
  no way to ask "who is the compositor". **GAP-0162**.
* **No multicast, no broadcast, exactly two endpoints.** A compositor with N clients uses N channels,
  and today N ≤ 2. **GAP-0163**.
* **Not a byte stream.** Messages are discrete: never coalesced, never split.
* **Not reachable without a process.** An endpoint is owned by a process id, so an M9 payload and an
  M10 `run` program are refused with `chanRetNoProc`. **GAP-0164**, and the harness's second boot is
  that refusal happening.
* **No flow control beyond FULL.** The kernel never drops a message it accepted, and never accepts one
  it cannot hold.
* **No shell command.** IPC is something programs do. `shellStrHelp` is unchanged at 2224 bytes, which
  is what keeps five byte-exact goldens where they are (GAP-0105).

---

## 4. What is validated in the kernel, and why each check is there

IPC is the classic place to hand back the protections other milestones paid for. Every item below is a
refusal with its own code, and every one **except item 9** is exercised **from ring 3, as a return
value**, in `m20-ipc`'s first boot. Item 9 cannot be — see it, and GAP-0166.

**1. The endpoint is an argument; the owner is not.** A handle names a port and a side. The *owner* of
that side is compared against `procGet(procCurrent(), procSlotId)` — the kernel's own scheduler state,
which no syscall argument reaches. A process cannot send or receive on another's endpoint
(`chanRetNotOwner`). This is the check that makes "two processes" mean something.

**2. The length is bounded before any arithmetic touches the pointer.** DCDart traps on overflow by
emitting a real `ud2` (DCDART_SPEC §4.1). `chansend(ep, 0xFFFFFFFFFFFFFFFF, 64)` would make
`ptr + len` overflow *inside the range check that was supposed to stop it*, and a ring-3 program would
have chosen which instruction the kernel executes next. `chanOwnsRead` and `chanOwnsWrite` both bound
`ptr` against the program window and `len` against `chanMsgBytes` **first**. M9's `userOwns` carries
the same note about the same hazard; the harness asserts the ordering by reading both function bodies,
and the program performs the probe.

**3. The destination of a receive must be WRITABLE by ring 3, not merely reachable.** This is the one
that matters most and it is a genuine hole if you skip it. `chanOwnsRead` checks only the **U** bit,
because sending *out of* a read-only page is legitimate — the kernel only reads it, and `m20-ipc`'s
program sends round 3's request straight out of its own `.rodata` as a positive control.
`chanOwnsWrite` additionally requires the **W** bit at every level, because a receive *writes*. Without
that, a program could hand `chanrecv` a pointer into its own text segment and have the **kernel** write
there. `CR0.WP` is set (M8, ADR-0012 §2) so the store would fault rather than land — but a kernel page
fault at an address ring 3 picked is not an answer. A refusal is. The harness makes the program do
exactly this and requires `chanRetBadPtr`.

**4. No page is ever mapped writable and executable, because no page is mapped at all.** The channel
is `@bss` inside the kernel image. There is no shared page, no new mapping, no new page-table entry
and no change to any permission bit anywhere. W^X, NX and the ring-3 boundary are untouched by this
milestone — which is a property of the copying design and is the strongest single argument for it at
this stage. **When the shared-region milestone arrives, this paragraph stops being true and that ADR
will have to earn its own W^X argument.**

**5. The kernel never dereferences one process's pointer while another's page tables are loaded.**
A message is copied user→kernel on the sender's CR3 and kernel→user on the receiver's, and those are
two different syscalls. There is no instant at which a pointer from one address space is followed
under another's tables. `chanCopyIn` and `chanCopyOut` are the only two functions in the file that
touch a caller-supplied address, and each has exactly one caller which has already validated exactly
the range being passed.

**6. A slot is zeroed before it is filled**, so a 64-byte message followed by an 8-byte one cannot
leave 56 bytes of the first behind. `chanrecv` copies only `len`, so this is belt and braces — and it
is 64 stores.

**7. A port is wiped when it goes free.** Undelivered bytes of a dead conversation must not be readable
by whoever opens that port number next. `chanPortWipe` runs on every transition to `chanPortFree`, and
the generation counter survives it so the transcript can tell one conversation on a port from the next.

**8. A half-closed port does not admit a new peer.** When one side of an *open* channel dies the port
goes to `chanPortHalfClosed`, and `chanopen` refuses it. Letting a third process take the dead side
would let it join a conversation in progress and read the survivor's traffic. This is why
`chanPortHalfClosed` is a distinct state from `chanPortHalf` rather than bookkeeping.

**9. `head < tail` is a refusal, not a trap.** DCDart traps on *underflow* as well as overflow, so a
corrupted counter pair would emit a real `ud2` and the kernel would execute an undefined instruction
inside a syscall handler because a ring index was wrong. It is checked and counted instead
(`chanRetCorrupt`, `chanMetaCorrupt`). It is the one refusal that **cannot** be provoked from ring 3,
and `build-progs.sh` knows that and exempts it **by name** — one symbol wide — from the "the program
knows every refusal `chan.dart` declares" check, so a fifteenth refusal added without teaching the
program about it still fails the build. GAP-0166.

### 4.1 One thing the brief assumed that this tree does not have

The brief said the kernel enforces **SMEP and SMAP**. In this tree (`d4e768c`) it enforces neither:
`GAP-0122` item 6 says so, `CR4.SMEP` and `CR4.SMAP` are never set, and `ADR-0013` §"what is still not
here" lists them as absent. A SMEP probe landed in the main tree in `e1381f8`, which this branch is not
based on. Nothing in `chan.dart` depends on either bit; every check above is a software check. Said
here so that nobody reads §4 as "and the hardware backstops it", because at this commit it does not.

---

## 5. Ownership and lifetime, and what happens when a peer dies

A channel is never allocated and never freed. What is *owned* is an endpoint, and it is owned by a
**process id** (`procSlotId`, monotonic from `procHeadCreated`) rather than by a slot index, because
slots are reused and ids are not.

```
 free  --chanopen-->  half  --chanopen-->  open
  ^                    |                    |
  |   the owner exits  |   one owner exits  |
  +--------------------+                    v
  ^                                    halfClosed
  +-----------------------------------------+   the survivor exits
```

**The release happens in `procCleanup`**, which is the one function both the exit path and the
fault/kill path go through. A process that faults with a channel open releases it exactly like one
that exits. That is M15's `fileReleaseOwner` finding applied to a second kind of resource, and it is
the property that stops a killed process from leaving its peer waiting forever on a conversation with
nobody on the other end. The harness asserts there is exactly one call site and that it is that
function.

**When a peer dies holding the channel:**

* **Its queued messages are still delivered.** They were copied into *kernel* memory when they were
  sent; the sender's death does not unsend them. `chanrecv` **drains first** and returns
  `chanRetPeerGone` only once the ring is empty. This is a real advantage of copying over sharing —
  with a shared page, the dead peer's buffer would have to be either unmapped (losing the data) or
  kept alive (leaking it) — and the harness proves it: the requester fills the ring with eight
  messages and exits *before its peer has read a byte*, and the survivor then receives all eight and
  checks every byte against the host's model, in that order, with `CHAN_PEERGONE` arriving only after
  the last one.
* **A send to a dead peer is refused immediately** rather than enqueued, because nothing will ever
  drain it.
* **When the survivor also releases, the port returns to free and is wiped**, so a later `chanopen` on
  the same number cannot read a dead conversation's bytes. The harness runs a second session on the
  same port in the same boot, with a new generation and two new process ids, and requires byte-for-byte
  the same two exit hashes — which a port that had kept one stale index could not produce.

---

## 6. Concurrency: where this depends on being single-core

**Written down deliberately, because it is exactly the kind of assumption that is invisible until it
is not.**

Every function in `chan.dart` runs inside a syscall entered through an **interrupt gate**, so `IF` is
clear for its whole duration, and this machine has one CPU. The whole of `chanSysSend` is therefore a
critical section by construction rather than by a lock, and every read-modify-write in the file is a
plain load, add and store.

**Atomics now exist and are deliberately not used.** DCDart grew real atomics and fences after this
milestone was designed (its ADR-0055/0056, commit `3c28e65` — `lock xaddq`, `lock cmpxchgq`, `mfence`,
no `__atomic_*` libcalls). They are not used here, and that is a choice rather than an oversight: on a
single core with `IF` clear they would be pure cost, and using them would *disguise* the dependency
this section exists to record. The design is instead shaped so that the SMP change is small and
mechanical:

1. **Single producer, single consumer, per direction.** `chanPortHead0` is written only by side 0 and
   `chanPortTail0` only by side 1; direction 1 is the mirror. **No word in a ring has two writers.**
   That is the one queue discipline that is already correct with plain loads and stores, so on the day
   this kernel has two cores the fix is *two fences*, not a redesign. A shared "count" word, or a
   second producer, would have made it a rewrite. `m20-ipc/run.sh` asserts this by reading
   `chanSysSend` and `chanSysRecv` and failing if either writes the other's index word — because one
   CPU cannot demonstrate its absence.
2. **The counters are free-running, not modular.** Depth is `head - tail`; the slot index is
   `counter & chanRingMask`. A *stale* tail makes the producer believe the ring is fuller than it is;
   a *stale* head makes the consumer believe it is emptier. **Both errors are in the safe direction**,
   so a reordered pair of loads costs a delayed message and never a lost or duplicated one.
3. **The publication order is stated and obeyed.** The producer fills the slot and its length word
   *before* advancing head; the consumer copies the slot out *before* advancing tail. Both points are
   marked in the code as where the release/acquire fence goes, and the harness asserts the source order.
4. **The unsafe counters are not load-bearing.** `chanPortSends`, `chanMetaBytesW` and the rest are
   statistics. Nothing decides anything from them; they are printed.

**So, precisely: the single thing this file relies on that an SMP kernel would not give it is that no
fence instruction is emitted.** Everything else is already SMP-shaped. **GAP-0165** records that, and
records that `m20-ipc` runs under `proc coop` on one CPU and therefore cannot demonstrate the
difference.

---

## 7. What the conformance harness establishes

`core/tests/conformance/m20-ipc/run.sh` — 8 structural checks, `verify-freestanding`, and two real
QEMU boots.

The headline: **one binary, built once, written to two byte-identical disk slots** (`make-image.py`
refuses to build an image where they differ). Which process becomes the requester and which the
responder is decided **entirely by which one `chanopen` answers first**. So "the two processes behaved
differently" is a claim about the kernel rather than about two programs — the same discipline M19 used
for `argv`.

**The contents are asserted, not the return code.** Each side exits with a 64-bit FNV-1a hash of every
payload byte the kernel handed it, and `derive.py` computes both hashes on the host from the
protocol's formulas *before the machine boots*. The two hashes are required to differ from each other,
so one exit status cannot satisfy both checks. A kernel that returned the right lengths over a
zero-filled buffer, delivered a stale ring slot, or gave the right bytes to the wrong side produces a
different 64-bit number. The per-round running hashes are checked too, so a wrong byte names its round.

**Twelve of the fourteen refusal-and-status codes are provoked from ring 3 and checked as return
values.** The two that are not are named rather than left to be counted: `chanRetCorrupt`, which
nothing can produce (GAP-0166), and `chanRetBusy`, which needs a **third** process to knock on an
occupied port — and every `proc` form starts exactly two, so no boot in this suite can arrange one
(GAP-0167). Both are asserted structurally instead, which is a weaker claim and is written down as one.

Also established: four request lengths and four different reply lengths crossing in both directions,
with each reply **derived by the responder from the bytes that arrived** (so one wrong byte fails on
both sides); the ring accepting exactly `chanRingDepth` messages and refusing the next; eight messages
delivered in full to a survivor whose peer had already exited, in that order; **nineteen refusal
outcomes observed from ring 3 as return values**, including the read-only destination and the
overflowing pointer; the frame allocator's free count identical to the frame across two sessions; and
the same binary run as an M10-style program refused by all three syscalls.

### 7.1 A bug this harness found

The first build returned `chanRetBusy` when a process re-opened a port it *already held*, because the
"already mine" test lived inside the `chanPortHalf` arm and the port was `chanPortOpen` by then.
`BUSY` and `TWICE` are different facts and a client acts differently on them — back off and find
another port, versus you already have the handle you are asking for. The test caught it because it
asks for the specific code rather than "some refusal". The check now runs before the state is
consulted.

---

## 8. What this unlocks, and what has to come next

The ladder is: input to ring 3 (M-input, done) → `argv` (M19, done) → **one IPC primitive (this)** →
**a shared frame region** → PS/2 mouse → a compositor process.

The next rung is the one this ADR keeps pointing at: `shmcreate` / `shmmap`, a region mapped into two
address spaces, named by a 64-byte message on this channel. Its ADR will have to make the W^X argument
this one did not have to make (§4.4), and it will have to decide whether a region is mapped
read-write to one side and read-only to the other — for a compositor it should be, and that is the
whole reason the region is a separate primitive with its own permissions rather than a flag on a
message.

---

### 8.1 The goldens M20 moved, and how that was reviewed

Adding `chan.dart` grew the kernel image by three 4 KiB pages, which moved **every physical address
the kernel prints**. Twelve byte-exact goldens moved with it: `m8-paging`, `m9-ring3`, `m10-elf`,
`m11-proc`, `m12-heap`, `m13-libc`, `m14-fat`, `m15-fileio`, `m16-filewrite` and `m19-argv` (serial
and screen). This is GAP-0095's situation again and it was handled the way GAP-0095 records: `--regen`,
which still runs **every derived check** in each harness, so a wrong kernel cannot enshrine itself.

**They were then reviewed mechanically rather than eyeballed.** Every regenerated golden was
normalised by replacing every run of six or more hex digits with a single token and compared against
the committed version. **All twelve are identical after that substitution** — not one line added,
removed, reordered or reworded. In particular:

* `VM TEXT ... W 00 X 11`, `VM RODATA ... W 00 X 00`, `VM DATA ... W 11 X 00` are unchanged, so W^X
  and NX still hold exactly as M8 left them;
* `USER PAGE CODE ... U 1 W 0 X 1` and `USER PAGE STACK ... U 1 W 1 X 0` are unchanged, and both still
  go to `U 0` on teardown, so M9's ring-3 window is exactly as wide as it was;
* every `PAGES`, `FREED`, `ENTRY` and process id is unchanged — only frame numbers moved, each by the
  same 0x3000.

`m0-boot`, `mb-info`, `m1-interrupts`, `m2-console`, `m3-shell`, `m4-fault`, `m5-pci` and `m6-disk`
did **not** move: their captures contain no kernel-image address, which was confirmed by regenerating
four of them and getting a zero-byte diff.
