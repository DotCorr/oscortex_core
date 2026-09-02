# ADR-0041 — Shared memory regions, and a capability that can be handed to a peer

**Status:** Accepted (M21)
**Date:** 2026-08-27
**Verified by:** `core/tests/conformance/m21-shmem/run.sh` (86 checks, one QEMU boot)
**Closes:** GAP-0161 (no capability transfer). **Narrows:** GAP-0096 item 3, the last clause —
"no shared memory".
**Implements:** `docs/design/memory.md` §1.3 (a second region, not a bigger one) and §2.1–2.5
(the shared-frame hazard, the guard's location, the bit-plane, the primitive's shape).
**Builds on:** ADR-0027 (the channel), which named this milestone in its §8 and left it two
questions to answer. **Depends on:** ADR-0012 (W^X), ADR-0026 (zeroing at the call site).

---

## 0. The problem, stated as the thing M20 refused to fake

ADR-0027 capped a channel message at **64 bytes, in the kernel**, and argued that a *generous* cap is
the trap: an 800×600×32 frame is 1,920,000 bytes against a total kernel mutable-static budget of
17,504, so a message primitive that could carry a frame would copy 1.92 MB through the kernel twice
per frame at 60 Hz, and somebody would eventually chunk a frame across whatever cap it had.

**That argument is only honest if bulk data has somewhere else to go.** M20 wrote down, in as many
words, that it did not: GAP-0161 recorded that there is no way to hand a region from one process to
another, and §3 recorded that "a message is bytes; it cannot convey authority" (GAP-0201).

M21 is the somewhere else. A message carries the **name** of a region; the region carries the bytes.

---

## 1. What was built

`core/kernel/shm.dart`, a second ring-3 window in `core/kernel/vm.dart`, one branch in
`core/kernel/pmm.dart`, and four syscalls:

| # | Call | Returns |
|---|---|---|
| 16 | `shmcreate(pages)` | a capability handle, region mapped **read-write** in the caller |
| 17 | `shmgrant(ep, h)` | **the grantee's** handle — a **read-only** capability installed in the peer of channel endpoint `ep` |
| 18 | `shmmap(h, perms)` | the region's virtual address |
| 19 | `shmdrop(h)` | 0; releases the caller's own capability, destroying the region if it was the last |

Numbers 16–19 are the registry's next free ones (11 stays reserved for `fdwait`, 12 is `ioctl`,
13–15 are M20's). `docs/syscall-registry.md` is the allocator and `verify-syscall-registry.sh` checks
this claim; GAP-0213 is why that matters.

**`chan.dart` gained exactly one function and lost nothing.** `chanPeerId(ep, id)` answers "who is on
the other end of an endpoint I own". It reads no ring, moves no byte, and returns an id.

---

## 2. Why a second window rather than a bigger one

`vmProgEnd` was doing two unrelated jobs, and M21 needed one of them to move:

| job | used by | had to change? |
|---|---|---|
| top of the **loadable** region — the bound `elfCheckPhdr` refuses a segment past, the address the stack sits below, the ceiling `heapTop` is measured down from | `elf.dart`, `heap.dart`, every `prog.ld` | **no** |
| top of what **ring 3 can reach** — the bound every user-pointer validator tests | `elfOwns`, `fileOwnsRead`, `fileOwnsWrite`, `chanOwnsRead`, `chanOwnsWrite` | **yes** |

So they are split. `vmProgEnd` stays the load bound; **`vmUserEnd` is new** and is the reachability
bound. Shared regions live in a second window at page-directory entry **129**,
`[0x10200000, 0x10400000)`, which nothing M0–M20 built has ever touched.

**What that bought, and it is the entire reason for the shape:** `prog.ld` in nine harnesses is
unchanged; `heapTop`, `heapTopIndex`, `heapGuardPage`, `heapGuardIndex` and `heapMaxInc` are
unchanged, so `m12-heap`'s whole structural block — which multiplies all five back out against the
window — passes verbatim; `vmProgStackPage`/`vmProgStackTop` are unchanged, so `ELF ENTER … RSP`,
`m19-argv/check-stack.py` and `m18-preempt`'s RSP-in-range check are untouched; and the 47 golden
occurrences of `101FE000`/`101FF000`/`10200000` across nine `expected*.txt` files did not move.
`m21-shmem` asserts each of those constants by value, so a later change that moved the load region
would fail *this* harness rather than nine others mysteriously.

**One page-directory entry is 2 MiB is 512 pages, and that is not an arbitrary size:** an 800×600×32
frame is 469 pages, so a full-screen compositor frame fits in one such window with 43 to spare. The
window is sized by what the client this exists for actually needs. §7 says why a region is
nevertheless capped at 256 pages today, and what changing that costs (two constants, no ABI).

### 2.1 Why widening the validators' bound is safe, which is not obvious

Between the load region and the shared window there is now a 512-page span that is mapped only where
a region has been mapped in. A validator that tested `lo <= p < hi` would accept every address in that
span and the kernel would then take a page fault dereferencing one — a ring-3 program choosing which
instruction the kernel executes next.

**All five validators walk every page through `vmEffective` instead, and that is exactly the property
M16's mutation round established.** GAP-0124 records that the two mutations which survived a range
test and died against the per-page walk were *a page inside the window that is not mapped* and *a
range whose first page is mapped and whose second is not* — which is precisely this case. So the
bound could be widened without writing a third page walk, which is what the brief asked for.
`m21-shmem` re-reads all five bodies and fails if any one of them stops walking, stops consulting
`vmEffective`, or stops bounding `len` before computing `ptr + len`.

---

## 3. What a capability is, physically

One packed `u64` per capability, in the **process slot** — `procSlotShmCaps`, words 24..27, four per
process, in storage `procStore` already had:

```
 bits  0..3   region index + 1   (0 = the slot is empty)
 bits  4..7   permissions        (shmPermRo = 1, or shmPermRw = 3)
 bit   8      mapped in this address space
 bits 32..63  the region's generation when the capability was made
```

A ring-3 **handle** is `(capability index << 32) | generation`. It carries no region index at all.

---

## 4. What makes a capability unforgeable — and the honest form of that claim

**The security does not rest on the handle being hard to guess, and any design that needed it to would
be a bad one.** A 32-bit generation that starts at 1 and increments is trivially guessable, and M21
does not care.

It rests on **where the table lives**. A capability table is inside the process slot, reached only
through `procGet(procCurrent(), …)` — the scheduler's own state, which no syscall argument reaches.
This is `chanCallerId`'s discipline (ADR-0027 §4 item 1) applied to a second kind of authority. A
handle names **an index into the caller's own table**, so:

* guessing an index reaches only a capability **the kernel itself installed there**, i.e. one this
  process was granted or created;
* there is no number, however chosen, that names another process's capability, because the lookup
  never leaves this process's slot;
* an index that was never filled is `shmRetBadCap`, which is what a forged handle actually gets — the
  common case, not the exotic one.

**The generation defends against something else entirely** and it is worth not conflating them: it
catches a *stale* handle to a region that has died and whose slot has been reused. That is
use-after-free, not forgery, and it gets its own code (`shmRetStale`) because a client acts
differently on the two — "that region is gone" versus "you never had it".

### 4.1 The experiment that demonstrates it, and why it is the right one

Both processes' handles in `m21-shmem` are index 0 with the same generation, so **the consumer's
handle is numerically the same 64-bit value the producer holds** — and the producer's is read-write.
The consumer calls `shmmap(ph, SHM_RW)` with it. If a handle were a global name, that call would hand
a second writer a writable mapping. It is refused with `shmRetBadPerm`.

That is the strongest available form of the claim: **the consumer knows the number and still cannot
widen it.** A test that used an unlikely number would only have shown that unlikely numbers fail.

---

## 5. Ownership and lifetime

**A region's frames are held by the number of LIVE CAPABILITIES naming it — not by the number of
address spaces mapping it.** `shmRegRefs` is that count. `shmRegMaps` exists and is printed and
nothing decides a lifetime from it.

```
 free --shmcreate--> live(refs=1) --shmgrant--> live(refs=2)
                          ^                          |
                          |    a holder drops or dies|
                          +--------------------------+
                          |
                    refs reaches 0
                          v
                    frames freed, record wiped, generation NOT reused
```

That choice is what answers the four questions the brief asked, and the answers are different from
each other:

* **The creator exits while a peer holds the capability.** `procCleanup` releases the creator's
  capability; refs 2 → 1; **the frames stay**. The peer keeps reading. This is the shared-memory
  form of ADR-0027 §5's "a dead sender's messages are still delivered", and `m21-shmem` executes it:
  the producer exits, its address space is reclaimed, and the consumer then re-reads all 16,384 bytes
  and gets the hash the host computed before the machine booted.
* **Both exit.** The second release takes refs to 0, the region is destroyed, and the frames go back.
  The allocator's free count is identical before and after the session, to the frame.
* **A process is killed mid-write.** `procCleanup` is the one function both the exit path and the
  fault/kill path go through, so a faulting process releases its capability exactly like a polite one.
  `m21-shmem` asserts there is exactly one call site and that it is that function — M15's
  `fileReleaseOwner` finding and M20's `chanReleaseOwner` finding, applied a third time.
  **What the peer sees is a torn region**, and that is not fixable here; see §6 and GAP-0236.
* **A region nothing maps.** A creator can exit before its grantee ever calls `shmmap`. The frames are
  held by the *capability*, so they survive — which is why the frame list lives in a per-region
  **frame-vector page** rather than being recovered from a page table. At that instant there is no
  page table to recover it from.

### 5.1 The one branch that makes all of it true, and where it had to go

`docs/design/memory.md` §2.1 works the hazard through: A and B both map frame F, A exits,
`procSpaceFree(A)` sees F present in A's page table and calls `freeFrame(F)`, F is handed to somebody
else, and B is still writing it. The existing double-free check catches B's *later* free loudly — so
**the thing that is missing is not detection of the second free, it is preventing the first**.

The guard is therefore **one bit-test at the top of `freeFrame` and nowhere else**, because five paths
give a frame back — `procSpaceFree`, `heapRollback`, `elfUnload`, `shellFree` and `frames refill` —
and all five funnel through that function. Putting it in `procSpaceFree` would have needed the same
change in four more places and would still have missed one.

Three details that are not arbitrary:

1. **It goes after the `ready` and *alignment* checks and before the range check.** The guard is keyed
   by frame number and an unaligned address must never be allowed to compute one; `free 1001` has to
   keep being `pmmFreeAlign`, which `m7-frames` asserts.
2. **It returns `pmmFreeOk` and frees nothing.** Every caller in this kernel *adds* the returned
   status to a running error counter, which works only because `pmmFreeOk == 0` (ADR-0011 §4). A
   distinct `pmmFreeShared` would have silently started adding a non-zero number to `procHeadErrors`
   at four call sites. The retention is made visible in a counter (`shmMetaRetained`) instead.
3. **`procSpaceFree` asks `shmFrameShared` itself, before calling**, so that it does not *count* what
   it did not free. Its contract is "frames actually given back", and nine harnesses bracket a free
   count around it. `m21-shmem` requires both processes to report exactly 11 frames freed — their own
   six pages and five table frames, and not one frame of the region they shared.

The lookup is a **4096-byte bit-plane, one bit per frame**, the same size and the same idiom as the
frame bitmap. `memory.md` §2.4 measured the alternative: `frames refill` calls `freeFrame` 32768
times, and a linear scan of even a 64-entry table there is 2.1 M volatile loads added to a fixture
nine harnesses run.

---

## 6. Concurrency: the call, made consciously, and it is NOT the same call M20 made

ADR-0027 §6 recorded that `chan.dart` deliberately does not use DCDart's atomics (its ADR-0055/0056),
because on one core with `IF` clear they are pure cost and would *disguise* the single-core dependency
rather than remove it. GAP-0205 records it.

**M21 makes the same call for its metadata and a different, stronger statement about its contents,
and the two must not be run together.**

### 6.1 Metadata — same as M20, and atomics stay unused for the same reason

Everything in `shmStore`, every capability word, and every page-table entry this milestone writes is
touched **only inside a syscall**, entered through an interrupt gate, so `IF` is clear for the whole
duration, and this machine has one CPU. Every read-modify-write is a plain load, add and store. On
the day this kernel has two cores, `shmRegRefs` becomes the one word that needs a real atomic — it is
incremented by `shmgrant` and decremented by `shmdrop` and `shmReleaseOwner`, which is a genuine
multi-writer counter and is the *only* one here. That is written down rather than discovered.

### 6.2 Contents — where a shared region stops being like a channel, and no atomic helps

**A channel's data is only ever touched by the kernel with `IF` clear. A shared region's data is
touched by ring 3, with no syscall involved at all.** So the single-core-with-interrupts-clear
argument does not extend to region contents, and this is exactly the place where a single-core
assumption stops being safe first — which is why it is stated here rather than left to be inferred.

Two things make it survivable today, and one of them is a design choice rather than an accident:

1. **There is exactly ONE WRITER of any region, by construction.** `shmcreate` gives the creator
   read-write; **`shmgrant` conveys read-only and takes no permission argument**, and `shmmap`
   refuses to widen a read-only capability (`shmRetBadPerm`). So there is no writer-writer race in
   this design, at all, on any number of cores. ADR-0027 §8 asked whether a region should be
   read-write to one side and read-only to the other and answered "for a compositor it should be";
   this is that answer, made structural rather than conventional. `m21-shmem` reads `shmSysGrant` and
   fails if it ever installs anything but `shmPermRo` or reads a third argument.
2. **Under `proc coop` nothing preempts**, so the interleaving in the harness is exactly the two
   programs' yields.

**What remains, and it is real:** under M18's preemption a reader *can* be scheduled in the middle of
the writer's update and observe a half-written region. **No atomic fixes this and adding one would be
worse than useless**, because the unit of tearing is a frame or a whole buffer, not a word — an
`lock cmpxchgq` on one `u64` of a 16 KB update buys nothing and would advertise a guarantee that does
not exist. The answer for a compositor is a sequence number the client writes last and the server
re-reads after copying, or double buffering — both of which are the *client's* protocol, above this
primitive. **GAP-0236** records that, and records that this harness cannot demonstrate it because
`proc coop` does not preempt.

---

## 7. Revocation: there is none, and this is the stated reason

**`shmdrop` releases the CALLER'S OWN capability. A grantor cannot take one back from a grantee.**
That is a real limitation and it is a design decision rather than an oversight, so here is what it
would take.

Revoking a capability in another address space means unmapping pages in page tables the kernel can
reach **only while that process's CR3 is loaded**. Every mapping function in `vm.dart` walks from CR3
(`vmProgPd` → `vmLivePml4` → `cr3_read`), and that is deliberate: M11's design note says the loader
runs with the target's CR3 already in the register. Involuntary revocation therefore needs one of:

* a **cross-address-space unmap** — the `procPtOf(s)` shape, editing another slot's tables directly.
  It works on one core because a CR3 write on the next switch flushes everything and this kernel never
  enables PGE. It does **not** work on two, without a TLB shootdown, which needs an IPI, which needs
  an APIC this kernel does not program; or
* a **deferred revoke** — a flag on the victim's slot, checked at the next `procSwitchTo`. That is
  cheap and correct on one core, and it puts a new field and a new step in the scheduler's hot path,
  which is surgery on `proc.dart` that this milestone would then be shipping untested.

Neither is free and neither is needed by the client this exists for: a compositor revokes by asking
the client to drop, or by outliving it. **GAP-0233** carries it with the two mechanisms written out.

**What M21 does have** is the part of revocation that is actually load-bearing for safety: a
capability dies with its holder, on the fault path as well as the exit path, and a handle to a dead
region is refused by generation rather than dangling.

### 7.1 The other things this deliberately is NOT, each with a gap number

* **No region larger than 256 pages.** The *window* is 512 and holds a full 800×600 frame; the
  *slotting* — `shmMax = 2` regions of `shmSlotPages = 256` — is what caps it. Configuring one slot of
  512 fits a full-screen frame and changes no ABI, no syscall and no structure, only two constants.
  M21 did not take that configuration because two regions is what two processes need and a
  one-region kernel could not test a grant to a peer that already holds one. **GAP-0237.**
* **No partial map, no offset map, no resize.** A capability names a whole region and maps it whole.
  **GAP-0234.**
* **No file backing, no `MAP_FIXED`, no `mprotect`, no demand paging.** **GAP-0235** — closed by ADR-0163 (`mprotect` / `MAP_FIXED`) and ADR-0164 (`shmfile` + demand).
* **Addresses are chosen by the kernel, never by the caller** — and a region's address is a function
  of its *slot*, so it is the same number in every address space. That is worth more than the address
  space it wastes: an offset in a frame descriptor means the same thing to both peers.
* **No blocking.** A reader polls, exactly as ADR-0027's receiver does (GAP-0200). Nothing on this
  machine can block.

---

## 8. Security: what is checked, and the one thing that is not

Shared memory is the classic place to hand back the protections other milestones paid for. Every item
is a software check and says so — **GAP-0153 records that SMEP is set and nothing proves it blocks a
fetch, so nothing here leans on a hardware backstop.**

1. **A shared page is never executable, and the state is not EXPRESSIBLE.** `vmShmMap` has no `exec`
   parameter — not one that is checked, *absent* — and ORs `vmNxBit()` into its base bits
   unconditionally. `vmProgMap` needs an `exec` argument because an ELF's `p_flags` can ask for X;
   nothing can ask here. Belt and braces: `shmSysMap` refuses a *request* for it by name
   (`shmRetExec`) so ring 3 is told rather than quietly given something else, and it checks that
   **first**, before deciding whether the permission word is even legal.
   *Asserted three ways:* the harness reads `vmShmMap`'s body and fails if `exec` reappears or NX
   becomes conditional; ring 3 asks for `R|X` and for `RW|X` and gets `shmRetExec`; and the kernel
   prints one `SHM PAGE … W … X …` line per page **read out of the live tables through
   `vmEffective`**, and the harness requires `X 0` on every line in both address spaces.
2. **Every length from userspace is bounded before any arithmetic uses it.** `pages` is a value
   ring 3 chose and is about to be multiplied by 4096; DCDart traps on overflow with a real `ud2`, so
   an unbounded `pages` would let ring 3 choose which instruction the kernel executes next.
   `shmcreate(0)`, `shmcreate(257)` and `shmcreate(0xFFFFFFFFFFFFFFFF)` are each refused from ring 3.
3. **No pointer from userspace is dereferenced by this subsystem at all.** `shm.dart` takes no user
   buffer: its arguments are a page count, a handle, an endpoint and a permission word. The one place
   a user pointer crosses is `chansend`/`chanrecv` carrying the descriptor, which is M20's already-
   validated path. That is a property worth stating because it is *why* no third page walk was
   written.
4. **A capability cannot be widened by the argument that uses it.** §4.1.
5. **A new address space cannot inherit a region.** `procSpaceBuild` copies all 512 page-directory
   entries by value and clears **both** windows' entries afterwards. Missing the second would have
   given every process created after a region existed a silent path into another's memory. Asserted.
6. **Pages are zeroed before they are mapped, never after.** `heapSbrk`'s discipline and its exact
   reason: between the mapping and the zeroing there is a window in which the previous owner's bytes
   are reachable from ring 3, and a shared region is the one place two processes are looking. Every
   `allocFrame()` call site in `shm.dart` names its frame to `vmZeroFrame` in the same file, which is
   ADR-0026's rule and `m7-frames`' check 2i.
7. **A generation is never reused within a boot** and a region record is wiped only *after* the line
   describing it is printed — `chanPortWipe`'s ordering, and its reason.

### 8.1 What is NOT checked, named so nobody infers it

**A write through the consumer's read-only mapping IS attempted, and faults.** This paragraph
originally said it was not, and deferred it to GAP-0238 on the grounds that the store kills the
process before it can report its hash. That was true and was not a good enough reason: the hash is
now PRINTED before the store and read out of the transcript, and a second binary built from the same
source with `-DM21_ROFAULT` performs the store as its last act. The harness requires
`PF CR2 <region base> ERR 00000007 PRESENT WRITE USER DATA` from `CPL 3` and the process to be
killed — and requires the absence of the line the program prints if the store SUCCEEDS, so the
control is two-sided. GAP-0238 is closed.

**The no-process guard is structural, not behavioural.** All four syscalls refuse a caller with no
process slot, and ADR-0034 unified the launch path so that nothing the shell can start produces one.
This is GAP-0214's situation exactly, for a second subsystem, and it is filed as **GAP-0239** in that
category and explicitly not in GAP-0206's: the path is live and reachable — an M9-style `user` payload
would hit it — and what is missing is a payload that issues `shmcreate`.

---

## 9. What the conformance harness establishes

`core/tests/conformance/m21-shmem/run.sh` — 93 checks, `verify-freestanding` on four objects, two
QEMU boots.

**One binary, built once, written to two byte-identical disk slots.** Which process creates the region
and which receives it is decided entirely by which one `chanopen` answers first, so "one process wrote
a page and the other read it" is a claim about the kernel rather than about two programs.

The headline: **the consumer exits with a 64-bit FNV-1a of all 16,384 bytes it read through the shared
mapping**, and `derive.py` computes that number on the host from the pattern's formula *before the
machine boots*. The pattern depends on both the page index and the byte offset, so a kernel that
mapped the pages in the wrong order, or mapped one page four times, produces a different number. The
two sides' hashes are required to differ, so one exit status cannot satisfy both checks.

Also established: the same **physical frames** in both address spaces, read out of the live tables,
`W 1 X 0` for the creator and `W 0 X 0` for the grantee, with the four frames distinct; the region
re-read in full **after** its creator exited and its address space was reclaimed, in that order;
neither teardown releasing or counting one frame of the region; the region returning exactly five
frames (four pages plus its frame-vector page) when its last capability goes; the allocator's free
count identical before and after, to the frame, with no allocator error recorded; and **twenty
refusals observed from ring 3 as return values**, each compared against the *specific* code expected
rather than against "some refusal".

### 9.1 Four mutations were run against this harness, and what the third one taught

A check nobody has seen fail proves nothing, so the harness was run against four deliberately broken
kernels. All four were caught:

| mutation | caught by |
|---|---|
| `vmShmMap` sets NX only on read-only pages | the structural read of its body |
| the `freeFrame` guard deleted | the structural read of `freeFrame` |
| the guard still *called* but nothing ever marked shared | **behaviourally** — `SHM DEAD … FREED 00000001` instead of 5 |
| the grantee's mapping made writable | **behaviourally** — `consumer page 0 is W 1, expected W 0` |

**The third one is the useful finding and it is recorded rather than glossed.** With nothing marked
shared, the producer's teardown really did release the region's four frames — and *the peer-death hash
still matched*, because nothing reallocated them in the interval. **So the hash is necessary and not
sufficient**: what actually proves retention is the frame accounting — `PROC KILL … FREED` being 11
rather than 15, and `SHM DEAD … FREED` being 5. A harness that had asserted only "the bytes are still
right after the peer died" would have passed a kernel with a live use-after-free in it. That is the
GAP-0124 question — which of these checks is load-bearing — asked of this milestone's own harness, and
**GAP-0240** carries the answer.

---

## 10. ESCALATION — two decisions this unit made that it should not have made alone

`CLAUDE.md`'s escalation rule names one of these by hand: *"Any hardware/boot-protocol choice
that's hard to reverse later … memory layout that userland will eventually depend on."* M21 makes
exactly such a choice, and a second one about the syscall ABI's shape. Both are **implemented and
verified**, because the ladder is blocked without them and a reversible decision that is written down
is worth more than a blocked milestone — but both are flagged here rather than left to be discovered
by whoever depends on them.

### 10.1 The ring-3 memory layout is now two windows, and userland will depend on it

Before M21 a ring-3 program's whole world was `[0x10000000, 0x10200000)`. It is now:

```
  [0x10000000, 0x10200000)   PD[128]   load region -- code, data, heap, guard, stack   (UNCHANGED)
  [0x10200000, 0x10400000)   PD[129]   shared regions                                  (NEW)
  vmUserEnd = 0x10400000               one past the last address ring 3 can reach
```

**What makes it hard to reverse:** a shared region's virtual address is a function of its *slot*
(`vmShmBase + r * shmSlotPages * 4096`), so it is the same number in every address space — which is
the property that lets a frame descriptor carry an offset both peers agree about. The moment a
compositor and a client are written against that, `0x10200000` is in userland's contract, exactly as
`0x10000000` has been since M10 and `prog.ld` in nine harnesses shows.

**The specific things a human should confirm:**

* **Two windows rather than one bigger one.** `docs/design/memory.md` §1.3 recommends this and it is
  what was built; §2 of this ADR prices the alternative. But that design doc is explicitly a proposal
  ("Status: DESIGN. Not an ADR, not numbered, nothing implemented"), so this unit promoted a proposal
  to a shipped memory layout on its own authority.
* **The address is derived from the slot, not allocated.** The alternative — a bump pointer, or
  caller-proposed addresses — was rejected in §7.1. It is cheap to change *now* and expensive once a
  descriptor format is in userland.
* **`vmUserEnd` is 0x10400000 and not `memory.md`'s proposed 0x14000000 (64 MiB).** This unit claimed
  only the one page-directory entry it uses, because a validator bound should be what ring 3 can
  actually reach rather than what it might one day. Raising it later is a one-constant change; it is
  named here because `memory.md` says a different number and a reader will notice.

### 10.2 The syscall ABI grew four numbers and a new KIND of operation

16–19 are `shmcreate`/`shmgrant`/`shmmap`/`shmdrop`. Three of those are ordinary. **`shmgrant` is
not:** it is the first syscall in this kernel that changes *another process's* state — it writes a
capability into the peer's slot. Everything before it acted on the caller.

GAP-0201 recommended precisely this ("either the region grant is a fourth syscall that the kernel
*does* interpret … the first keeps `chan.dart` as simple as it is and is the recommendation"), so it
is not unilateral in substance. What this unit decided alone is the **shape**:

* **four syscalls rather than two.** `shmdrop` could have been folded into a flag, and `shmgrant`
  into `chansend`. Both were kept separate for `file.dart`'s stated reason — a call whose meaning
  depends on an argument is one somebody eventually calls wrong — at the cost of four registry
  numbers on a machine that has used twenty.
* **a grant is READ-ONLY and cannot be anything else** (§6.2). This is the single most load-bearing
  choice in the design: it is what makes "exactly one writer" a structural fact rather than a
  convention, and it is what makes the absence of any lock defensible. It also means a
  producer/consumer pair is the *only* topology this primitive supports. Two peers that both need to
  write need two regions, or a different primitive.
* **`shmgrant` names its target through a channel endpoint** rather than by process id, so a process
  can only grant to somebody it is already talking to. That couples `shm.dart` to `chan.dart` by one
  function, and it means capability transfer is impossible without a channel.

**None of these is hard to reverse in the kernel.** All of them are hard to reverse once a compositor
protocol is written on top, which is the next rung.

---

## 11. What this unlocks

The ladder was: input to ring 3 → `argv` (M19) → one IPC primitive (M20) → **a shared frame region
(this)** → PS/2 mouse → a compositor process.

The frame path now exists end to end in the shape a compositor needs: a client creates a region,
writes pixels into it with ordinary stores and no syscall, grants the compositor a read-only
capability, and sends a 64-byte descriptor naming it down a channel that did not have to change. What
is still missing before a compositor is real is a mouse, a way to wait (GAP-0200's `chanwait` or the
registry's reserved `fdwait`), and a client-level sequence-number protocol for tear-free updates
(GAP-0236).
