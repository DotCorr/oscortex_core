# Security — the model this OS already enforces, the one it does not have, and the order to build it in

**Status: DESIGN. Nothing here is implemented and nothing here is a decision.** It is the fourteenth
specialist document in `core/docs/design/`, and `README.md` names its subject as one of the seven
things the corpus does not cover: *"a security model beyond W^X and ring separation"*. This is that
gap, written by an agent that read `user.dart`, `vm.dart`, `proc.dart`, `heap.dart`, `file.dart`,
`elf.dart`, `args.dart`, ADR-0013, and the thirteen sibling designs.

Where a sibling document already measured something, this one **cites it rather than re-deriving
it**. Where nothing had measured something this document needs — and there were three such places,
all about CPUID leaf 7 — it was measured here and is marked `measured:`.

---

## 0. The one-paragraph version

This kernel's privilege boundary is **better than its milestone number suggests**, and materially
better than most hobby kernels at the same stage: W^X is enforced inside the mapping primitive rather
than at its callers, per-process address spaces are verified by walking guest physical memory from
two different PML4 frames, and all four ring-3 pointer validators bound before they do arithmetic —
for a reason specific to this toolchain that most kernels never have to think about. What it does
not have is **any notion of who is asking**. There are no users, no owners, no permissions, no
capabilities and no identities of any kind; every ring-3 program on this machine is equally
privileged, and the only thing the boundary distinguishes is *ring 3* from *ring 0*.

**Today that is the correct design.** One user, no network, no untrusted code: the entire threat
model is *bugs*, not *adversaries*, and the highest-value work is therefore the work that catches
kernel bugs mechanically. That is why §3's recommendation is SMEP — **one CR4 bit, zero code changes,
zero new externs, and it converts the single most dangerous class of kernel bug on this machine from
silent memory corruption into a loud fault at the exact instruction** — and why ASLR, canaries,
signed executables and a capability model are all correctly deferred.

**`net-stack.md` is the event that changes the model, and it changes it completely.** Everything in
this document is ordered around being ready for that day and not before it.

---

## 1. What is already right, stated precisely

Credit where it is due, with the specifics, because a security document that opens by listing
absences would misrepresent this codebase.

### 1.1 Ring separation, and a gate that is one attribute byte wide

`core/boot/boot.S` carries two DPL-3 descriptors (`gdt64_user_data` = 0x1B, `gdt64_user_code` =
0x23), a 104-byte TSS with a real `RSP0`, and a `ltr` that runs in the one window in which it can —
after paging is on but before `vmInit` makes the GDT read-only, because **`ltr` writes the busy bit
into the descriptor** and M8's `.rodata` protection would otherwise page-fault on it (ADR-0013 §2).
That was measured, not looked up; so was the second write, the CPU setting the ACCESSED bit on the
first `mov %eax,%ds` in `enter_user`. Both were fixed by removing the write, not the protection.

Exactly **one** of 256 IDT gates has DPL 3, and it is vector 0x80 (`idtSetUserGate`,
`user.dart:950`). The whole of userland's entry permission is the attribute byte `0xEE` instead of
`0x8E`. `user badint` executes `int $3` against a gate that still has `0x8E` and takes a #GP with
error code `0x1A` = `(3 << 3) | IDT` — so the harness observes both halves of "the DPL field is
load-bearing" in one session. Without that control, "int 0x80 reached the kernel" would be equally
consistent with "the DPL field does nothing on this CPU".

IOPL is 0 and the TSS's I/O-bitmap base is past its limit, so `in`/`out` from ring 3 is a #GP with no
bitmap to override it. Every general-purpose register is scrubbed before the `iretq`; ring 3 gets
zeros and one value in RDI.

### 1.2 W^X is enforced inside `vmProgMap`, not by its callers

`vm.dart:2196`:

```dart
if (write > u64(0)) {
  if (exec > u64(0)) {
    return u64(vmProgWx);
  }
}
```

**This is the property that matters, and it is the one most kernels get wrong.** `p_flags` from an
ELF file on a disk becomes `write` and `exec`; a segment with `PF_W|PF_X` cannot be mapped *even by a
caller that forgot to check*, and the refusal is a distinct status code (`vmProgWx` = 6) rather than
"the writable bit wins". The block comment above it says why in one line: *"ADR-0012 bought that
property for the kernel; a guest does not get an exemption from it."*

The same file gets the two other halves of W^X right in ways that are easy to get wrong:

* **Interior page-table entries are the absence of a veto, not a permission.** `PML4[0]`, `PDPT[0]`
  and the page directory carry `present | writable | user` with **NX clear**, because a page's
  effective permission is the AND of all four levels — an NX bit on `PML4[0]` would make `.text`
  non-executable no matter what the leaf said. `vmEffective` (`vm.dart:1858`) combines them the two
  different ways they combine: W and U by AND, NX by OR, because NX is a veto.
* **`CR0.WP` is set, and the kernel knows the difference between the bits and the enforcement.**
  ADR-0012 §2's lesson, restated in ADR-0013 §2: *the enforcement mechanism and the permission bits
  are two different things, and only one of them is visible in a page-table dump.* The `vm` command
  prints `NX` and `WP` side by side because the two together are the enforcement.
* **NX is probed, not assumed.** `boot.S` reads CPUID leaf `0x80000001` EDX bit 20 after asking leaf
  `0x80000000` whether that leaf exists at all, and `m8-paging` runs a negative control on
  `-cpu qemu64,nx=off` in which the kernel reports `NX 0`, maps `.rodata` executable, and
  `vmtest nx` *survives* while `vmtest ro` still faults. That is what makes the fetch fault in the
  main session attributable to the NX bit and to nothing else.

### 1.3 Per-process address spaces, verified from both sides

`procSpaceBuild` (`proc.dart:1239`) gives each of four slots its own PML4, PDPT, PD and PT, copying
the kernel's upper PML4 entries so that kernel code remains executable on a process's CR3 — which is
what makes writing CR3 in the middle of a kernel function survivable at all.

The verification is the part worth naming. `m11-proc/run.sh` does not ask the kernel whether the two
address spaces are different. With **both processes alive and the CPU at CPL 3 inside B**, it walks
the live page tables **out of guest physical memory, from both PML4 frames**, and requires:

> A's private pages absent from B's, **every address both map backed by a different physical frame**,
> and the kernel the same frame and supervisor-only in both.

Plus a fifth boot in which the kernel computes an address A has and B has not, and B takes a
`NOTPRES READ USER` page fault on it and is torn down with the shell surviving. **"Different address
spaces" is therefore a property of the tables the CPU walks, not of a flag the kernel prints.** A
kernel that shared one PML4 and lied about it would fail this, and regenerating a golden would not
help.

### 1.4 Four validators, and the reason they bound before they multiply

There are four distinct ring-3 pointer validators, and they are written out four times rather than
folded into one with a flag argument, on the stated grounds that *"a validator whose meaning depends
on an argument is a validator somebody will eventually call with the wrong one"*:

| validator | file:line | question it answers | length bound |
|---|---|---|---|
| `userOwns` | `user.dart:1328` | is this inside an M9 payload's two pages? (dispatches to `elfOwns` if a process or a loaded program is live) | 128 (`userWriteMax`) |
| `elfOwns` | `elf.dart:1548` | **may ring 3 read this** — every page of the range present and USER | 128 (`userWriteMax`) |
| `fileOwnsWrite` | `file.dart:751` | **may ring 3 write this** — every page USER **and WRITABLE** | 512 (`fileReadMax`) |
| `fileOwnsRead` | `file.dart:917` | may ring 3 read this, at file-write length | 512 (`fileWriteMax`) |

Every one of them puts the bound on `ptr` **first, before any arithmetic on it**, and the reason is
specific to this toolchain and is documented at all four sites:

> DCDart's arithmetic traps on overflow (DCDART_SPEC §4.1) **by emitting a real `ud2`**, and `ptr` is
> a value ring 3 chose: `write(0xFFFFFFFFFFFFFFFF, 8)` would make `ptr + len` overflow *inside the
> range check* and take a #UD in the syscall handler. A ring-3 program must not be able to choose
> which instruction the kernel executes next, and the check that was supposed to stop it would have
> been the thing it used.

That is not a generic "check your pointers" comment. It is a hazard created by a *safety* feature of
the language, correctly identified, and it is the kind of thing that is normally found by an
exploit rather than by a code comment.

The two `file.dart` validators are also **not** the same function with a flag. `fileOwnsWrite`
requires the WRITABLE bit and `fileOwnsRead` does not, and `m16-filewrite`'s program proves the
distinction is real from both directions: it aims a `read` at its own `.rodata` and requires a
refusal, and it aims an `fdwrite` at its own `.rodata` and requires a **success**. A validator that
demanded WRITABLE on the write-out path would have refused the most ordinary call there is.

`fileOwnsRead`'s doc comment records a second trap that the obvious refactor would have walked into:
reusing `elfOwns` there — which is what a reader would reach for — *"would have silently capped every
file write at 128 bytes"*, because `elfOwns`' length bound is the console `write` syscall's, not the
file layer's.

### 1.5 A mutation round killed the validator that checked only the first page

This is the strongest single piece of evidence in the tree that the validators are tested rather than
merely written. `m15-fileio`'s first mutation round produced a **surviving mutant**: a validator that
bounded the range against `[vmProgBase, vmProgEnd)` and then checked the permissions of the *first
page only*. `m16-filewrite/prog.c:384-389` is the test that kills it, in the program's own words:

```c
/* A RANGE THAT STRADDLES THE END OF THE MAPPED IMAGE. Its FIRST page is user
 * and present; its SECOND page is not mapped. A validator that looked at the
 * first page only would accept it and the kernel would then fault reading
 * from unmapped memory INSIDE A SYSCALL -- which is precisely the failure a
 * page-by-page walk exists to prevent, and which is the mutant that survived
 * m15-fileio's first round until it grew this check. */
```

Beside it, `rHole` aims a write at `0x10100000` — an address *inside* the program window, between the
image at `0x10000000` and the stack at `0x101FF000`, mapped by nothing. A range check against the
window's two bounds accepts it. **The consequence of that fix is why all four validators walk every
page of the range against `vmEffective` rather than testing endpoints**, and it is the reason
`elfOwns`' doc comment says a range test against lo/hi *"would accept a pointer into a gap"*.

### 1.6 Every exit from ring 3 goes through one teardown, including the faults

`userTeardown`, `elfTeardown` and `procCleanup` are reached from **both** the `exit` syscall and the
fault path, and `fileReleaseOwner` closes descriptors from the teardown rather than from `exit`. The
stated reason is the correct one: *"a boundary that is open whenever something went wrong is not a
boundary"*, and three of M9's six sub-commands end in a fault on purpose. Without the fault-path
hook, `user gp` would leave two user-accessible pages mapped for the rest of the boot, every time,
and `user pages` would report `USER 00000002` with nothing running.

Frames are **zeroed before they are mapped**, not after — `heapSbrk` says why in one line: *"between
the mapping and the zeroing there would be a window in which the previous owner's bytes are reachable
from ring 3."* `allocFrame()` returns whatever the frame last held (GAP-0076 item 5), so that window
would be a real information leak created by the allocator.

### 1.7 The summary judgement

Ring separation with a verified DPL-3 gate; W^X in the mapping primitive; per-process page tables
verified by walking guest memory from two PML4s and requiring distinct physical frames; four
validators that bound before arithmetic and walk every page; a teardown that runs on the fault path;
frames zeroed before mapping; and a mutation round that found and killed a real hole. **That is a
stronger base than most hobby kernels reach at any point.**

It is also, precisely, a *mechanism*. What is missing is a *policy* — and §2 argues that for this
machine, today, that is the right order.

---

## 2. The threat model

### 2.1 Today: one user, no network, no untrusted code

State it plainly, because half the value of a threat model is refusing to inflate it.

There is **no adversary on this machine**. There is one human. The disk image is written by a
`make-image.py` in this repo. The programs `run` loads are compiled from `core/tests/conformance/*/`
and `core/user/` by the same build that produced the kernel. There is no network, no removable
media, no package manager, no downloaded code and no second user to be isolated from. Nobody is
attacking oscortex, and if somebody were, they would have the disk image.

**So what is the privilege boundary actually for?** Three things, and all three are real:

1. **It is a bug detector with a hardware backstop.** A kernel bug that dereferences a bad pointer,
   or a program bug that runs off the end of an array, becomes an attributable fault at a named
   instruction instead of silent corruption discovered three milestones later. That is the same
   argument `CR0.WP` and NX are already made on, and it is why `m4-fault` exists.
2. **It is a containment boundary for buggy programs.** `m11-proc` requires that a process taking a
   `NOTPRES READ USER` fault is torn down **and the shell survives**. A C program compiled at `-O2`
   with a wild pointer must not be able to take the machine with it, because during development it
   *will* have one, and the difference between "the program died and said why" and "the machine
   triple-faulted" is the difference between a ten-second and a ten-minute debug cycle.
3. **It is a load-bearing invariant that later work is built on.** `net-stack.md` §1.3 is the
   clearest example: it rejects a raw-packet descriptor in ring 3 *because* M8/M9/M11 built something
   worth not punching a hole through. A boundary nobody relies on is not worth having; this one is
   already relied on by an unbuilt design.

**What is NOT defended against today, correctly:** a deliberately hostile ring-3 program. One exists
in the tree already — `user hold` — and it cannot be stopped (GAP-0085 item 3); it is the last
command any session can run. A hostile program could also drive unbounded console output (every
refusal prints, and `heapLine` prints on **every** `sbrk` including the refused ones), and could
reach the `fatLookup` return-code hazard `README.md` records as *"a ring-3-reachable volume
corruption"*. None of that matters when the only person who can start a program is the person who
owns the machine. All of it matters later.

### 2.2 The day `net-stack.md` lands, the model changes completely

`net-stack.md` N2 — "ARP: a frame arrives, and the kernel understood it" — is the first moment bytes
this machine did not author are parsed by code this machine runs. Five things become true at once,
and only one of them is about the network:

**(a) The adversary becomes unauthenticated, remote, and able to retry.** Every property in §1 was
verified against a *cooperating* attacker: the harness programs deliberately hand the kernel bad
pointers, but they hand it the bad pointers the author thought of. A remote peer supplies inputs
nobody enumerated, as often as it likes, and gets to observe the outcome.

**(b) The parse happens in the kernel, in interrupt context, with `IF` clear.** `net-stack.md` §1.2
settles the stack in the kernel for a sound reason — *"the buffers cannot live anywhere else"*, there
is nowhere else that runs — and §6.3 puts `netTick`'s receive poll inside the PIT IRQ0 handler. The
doc itself rejects running protocol code in the NIC's own IRQ on the grounds that *"a TCP receive
path is not something to run with `IF` clear"* (`net-stack.md:829-830`) — **and then puts it on the
timer IRQ, which also runs with `IF` clear.** That tension is not addressed in either document and it
should be resolved before N2 rather than after.

**(c) The parser is hand-indexed byte arithmetic in an `if`-chain.** DCDart GAP-0025 forbids a
`@packed` struct in a signature, so there is no `IpHeader` type: every field is
`Pointer<u8>.fromAddress(base + 9).value` with the 9 in a named constant, and every demultiplex is a
chain of single-test `if`s because `@bare` DCDart has no `&&` (GAP-0023) and no jump table this repo
controls (GAP-0088). That is not a criticism of the design — it is the only shape available — but it
means **there is no type system helping here at all**, and every bound is a hand-written comparison
that a mutation test has to prove is load-bearing.

**(d) DMA arrives, and none of M8–M12 applies to it.** `net-e1000.md` §3.4 is blunt about this and it
is the single most important passage in either network document:

> The device uses physical addresses. CR3 is irrelevant, the page tables are irrelevant, and there is
> no fault path — **a descriptor pointing at the wrong frame is a silent write into RAM nothing
> tracks** … **The NIC can read `.rodata` and can write `.text` if a descriptor says so** … **A
> descriptor pointing into the ring-3 window would have the NIC write into a process's address space,
> with `m11-proc`'s isolation assertions all still passing.** … **No IOMMU.** There is no unit on this
> machine that could refuse any of the above.

Plus the sharpest one: `freeFrame` is a bit-clear, so **freeing an RX buffer while `RCTL.EN` is still
set hands that frame to the next `allocFrame` caller while the NIC is still writing packets into
it**, with no diagnostic at any level. Every hard-won property in §1 of this document is a property
of *the CPU's* memory accesses. A bus-mastering device is a second writer that none of them cover.

**(e) The safety of the RX path rests on one number the device wrote.** `net-stack.md:717-721` leaves
the 2 KiB packet buffers deliberately un-zeroed, on the argument that *"the device writes them and the
descriptor carries the length, so no byte is ever read that was not written."* That claim is only as
strong as the length field, and **neither document states that the driver must clamp it to
`RCTL.BSIZE`**. The RX descriptor's `errors` byte at `+0x0D` is documented in `net-e1000.md:413` and
is checked by nothing in any bring-up step or milestone.

### 2.3 The gap in the network ladder that this document exists to name

Both network ladders are well built by this repo's standards: `romfile=` is mandated so the option
ROM's seven-packet DHCP exchange cannot make a capture vacuously non-empty, and every milestone has a
binary criterion. But **every negative control in both ladders is a kernel mutation, not a hostile
input**: an inverted ARP opcode, an omitted one's-complement, a removed `TDT` write, a cleared `RS`
bit, a removed BME write. Not one truncated header, not one oversized length field, not one
zero-length frame, not one IP header whose `IHL` disagrees with its total length.

**Through N9 the only peer is QEMU's SLIRP, which is benign by construction.** A ladder verified
entirely against a cooperative peer proves the stack works; it proves nothing at all about what the
stack does when the peer is not cooperating, which is the entire reason a network stack is a security
boundary. §7's ladder puts a malformed-frame injector in as a prerequisite for N2 rather than as a
follow-up, because it is far cheaper to write the ten hostile frames *before* the parser exists than
to retrofit them into eight milestones of goldens afterwards.

### 2.4 A contradiction to resolve before N4, not after

`net-stack.md` §7.2 makes this design's central security claim:

> **Ring 3 never sees a frame it did not earn.** A program's channel receives only the payload of
> packets addressed to its 4-tuple; it cannot set a source address, cannot choose a source MAC,
> cannot transmit an arbitrary ethertype and cannot observe another program's traffic.

and §7.1 says "no promiscuous mode", with `RCTL = EN | BAM | SECRC | BSIZE(2048)`. But
**`net-e1000.md:453`, bring-up step 11, sets `RCTL = EN|BAM|SECRC|UPE|SZ_2048`, and `UPE` is unicast
promiscuous enable** (`net-e1000.md:251`). As written, the driver document turns on the mode the stack
document forbids. Under SLIRP nothing is on the segment so nothing changes; on a bridged tap, or the
day this OS shares a segment with anything, the two documents disagree about whether §7.2's sentence
is true. **`UPE` should be dropped from step 11 and the `EN|BAM|SECRC` form in `net-stack.md:783`
should be the one that is built**, with a `net` command reporting `RCTL` so the claim is read out of
the device rather than restated from a comment.

---

## 3. The attack surface that already exists: an audit of all eleven syscalls

Eleven syscalls, numbered 0–10, dispatched by one `if`-chain in `userSyscall` (`user.dart:1529`).
Every one of them takes its arguments out of the register frame `isr_common` saved, which means every
argument is a 64-bit value ring 3 chose.

### 3.1 The two refusals that come before any dispatch

Both are about the *caller*, not the request, and both are documented as being unreachable from
anything in the tree today — they exist because the gate is DPL 3 and a DPL-3 gate is reachable by
anything that ever runs in ring 3, including whatever a later milestone loads:

* **the saved CS must have CPL 3.** Ring-0 code executing `int 0x80` is the kernel calling itself
  through an interrupt gate, and the `exit` path would then hand a stack pointer recorded for a
  different call to `user_return`;
* **something must be live** — an M9 payload, an M10 loaded program, or an M11 process. Otherwise the
  frame numbers the pointer validators check against are stale.

Note that the *second* check is what makes the validators meaningful: `userOwns`' M9 branch bounds
against `userMetaCodeFrame` and `userMetaStackFrame`, which are zero when nothing is live, and
`ptr >= 0` would then be true of everything below `vmFineBytes`. The liveness gate is load-bearing,
not hygiene.

### 3.2 The table

`R` = RDI, `S` = RSI, `D` = RDX. "Deref" means the kernel loads or stores through an address ring 3
supplied.

| # | call | site | args | dereferenced? | what bounds it | verdict |
|---|---|---|---|---|---|---|
| 0 | `exit(code)` | `user.dart:1467` | R=code | no | nothing — stored in a slot, printed as 16 hex digits | **validated** (nothing to validate) |
| 1 | `write(ptr,len)` | `user.dart:1385` | R=ptr, S=len | **yes, read** (`uartWrite(ptr,len)`) | `userOwns` → page-walk; `1 ≤ len ≤ 128` | **validated** |
| 2 | `whoami()` | `user.dart:1299` | none | no | reads the CS/SS/RFLAGS the **CPU** pushed | **validated** |
| 3 | `yield()` | `proc.dart` `procYield` | none | no | refused unless `procLive()` | **validated** |
| 4 | `sbrk(inc)` | `heap.dart:heapSysSbrk` | R=inc | no | `inc ≤ heapMaxInc` (2 MiB) **before** the round-up; `want ≤ heapRoom(s)` **before** the first `allocFrame` | **validated** |
| 5 | `open(ptr,len,mode)` | `file.dart:1328` | R=ptr, S=len, D=mode | **yes, read** (copy loop) | `mode ≤ 1`; `1 ≤ len ≤ 12`; `elfOwns`; **copy into `fileBufBase()` before `fatParseAt`** | **validated** |
| 6 | `read(fd,dst,len)` | `file.dart:1429` | R=fd, S=dst, D=len | **yes, written** (`fileCopyOut`) | `fd < 4` **then** state, then `state == fileFdOpen`; `1 ≤ len ≤ 512`; `fileOwnsWrite` (USER **and** WRITABLE) | **validated** |
| 7 | `close(fd)` | `file.dart:1516` | R=fd | no | `fd < 4` then state | **validated** |
| 8 | `seek(fd,to)` | `file.dart:1558` | R=fd, S=to | no | `fd < 4`, state, `state == fileFdOpen`, `to ≤ size` | **validated** |
| 9 | `fdwrite(fd,src,len)` | `file.dart:1186` | R=fd, S=src, D=len | **yes, read** (`fileCopyIn`) | `fd < 4` then state, then `state == fileFdWrite`; `1 ≤ len ≤ 512`; `fileOwnsRead` (USER, **not** WRITABLE) | **validated** |
| 10 | `preempts()` | `user.dart:1573` | none | no | refused unless `procLive()`; reads `procGet(procCurrent(), …)` | **validated** |

**The audit found no unvalidated pointer and no unvalidated index in the eleven.** Every index is
compared against its table's bound *before* it is used to index, every length is bounded before it is
added to anything, every pointer goes through one of the four validators, and in the three places
where the kernel then works on the bytes (`open`'s name, `fdwrite`'s payload) the bytes are copied
into a kernel buffer first, so the parser and the FAT layer never dereference a ring-3 address at all.
`fileSysOpen`'s doc comment states that ordering as a rule: *"doing that through a pointer ring 3
still owns would be a validator with a window in it."*

### 3.3 The number that matters most for §5: **four**

Grepped across all 22,088 lines of `core/kernel/`, the kernel dereferences a ring-3-chosen *virtual*
address in exactly **four** places:

| site | direction | preceded by |
|---|---|---|
| `user.dart:1393` — `uartWrite(ptr, len)` | read | `userOwns` |
| `file.dart:1353-1358` — `open`'s name copy loop | read | `elfOwns` |
| `file.dart:fileCopyIn` | read | `fileOwnsRead` |
| `file.dart:fileCopyOut` | write | `fileOwnsWrite` |

Everything else that looks like it should be a fifth site is not, because **this kernel already
prefers the physical alias**:

* the ELF loader writes segment bytes at `userCopy(frame + lo, …)` — the *frame's* identity address,
  before `vmProgMap` ever runs (`elf.dart:1360`);
* `args.dart` writes `argc`, the pointer array and the argument text through `argsPhys(frame, va)`
  = `frame + (va - vmProgStackPage)`, and says so in its header: *"written through the stack frame's
  PHYSICAL address … The two addresses of one byte differ"*;
* `vmZeroFrame` zeroes at the identity address;
* `fatReadSector` reads into `fileBufBase()`, kernel memory.

That is an unusually disciplined pattern and it was arrived at for reasons that were not about
security — but it is what makes §5's proposal cheap, and it is worth recording as a rule before
somebody breaks it: **the kernel should reach a program's memory through the frame, not through the
program's address.** Every frame the allocator can hand out is inside `[0, 128 MiB)`
(`pmmMaxFrames = 32768`, and `m7-frames` asserts `boot.S`'s identity map equals the allocator's
bound), and `procSpaceBuild` copies the kernel's upper PML4 entries into every process, so the
physical alias is reachable from every address space this kernel can install.

### 3.4 Three things that are *not* validated, because they are not pointers

Recorded rather than left to be discovered:

1. **Ring 3 chooses how much the kernel prints.** Every refusal prints a line (`userRefuse`,
   `fileRefuse`), and `heapLine` prints on **every** `sbrk` including `sbrk(0)`, which has no side
   effect at all and is the documented way for `malloc` to ask where the break is. A program that
   calls `sbrk(0)` in a loop produces unbounded serial output. With one user this is a nuisance; with
   `net-stack.md`'s counters and a display server sharing the same UART it becomes GAP-0085 item 9 —
   *"the `write` syscall prints straight to the console, with no arbitration"* — reaching a new place.
2. **The exit code is unbounded and printed as a full 64-bit value.** Harmless, and worth knowing
   before a `wait`-like call ever returns one to another program.
3. **The validators' soundness depends on three properties that are all scheduled to change.** The
   check-then-copy sequences in `fileCopyIn`/`fileCopyOut` are TOCTOU-free *today* for three stated
   reasons: gate 0x80 is an **interrupt** gate so `IF` is clear, this kernel is **single-CPU**, and it
   **does not preempt inside a syscall**. `smp.md`'s conclusion that a second core is not yet worth
   building is therefore also a security property, and `blocking-and-threads.md` B1's decision to park
   by *leaving* the syscall rather than blocking inside it preserves it. **Anything that makes a
   syscall yield in the middle, or puts a second CPU in a page table, invalidates all four
   validators simultaneously** and needs to say so in its own ADR.

### 3.5 The larger surface is not the syscalls — it is the disk

Eleven syscalls with eleven validated argument lists is a small surface. The ELF loader and the FAT16
layer are a much larger one, and they consume a file rather than a register:

* `elf.dart` reads `p_vaddr`, `p_memsz`, `p_filesz` and `e_entry` off a disk and does arithmetic on
  them. The code is aware of this — `elf.dart:1306-1324` records that `vaddr + memsz` on a malformed
  file *"would overflow inside the test meant to reject it"*, the same `ud2` hazard as the pointer
  validators, correctly identified — and `m10-elf` runs six single-field mutations of a real program.
* `fat.dart` parses a BPB, a FAT and directory entries authored by whatever wrote the image.
* **`README.md` records a live hazard here:** *"`fatLookup`'s four callers disagree about what its
  return codes mean, and `fileMakeEmpty` acts on two of them by truncating and rewriting a directory
  entry. Any future change that returns those codes for something that is not a plain file is a
  ring-3-reachable volume corruption."* `display-protocol.md:275-295` reached the same conclusion
  independently, from the other direction, and its fix — **put the device branch in `fileSysOpen`,
  after the pointer-validated copy and before `fatParseAt`, never in `fatLookup`** — is the right one
  and should be treated as binding on both the display protocol and `net-stack.md`'s `/net`.
* **`fatParseAt` accepts `0x2F`**, so `open("SUB/X.TXT")` folds silently to `SUB/X   TXT`
  (`README.md` corrects GAP-0122 item 2 on exactly this point). A name that silently folds is worse
  than one that is refused, and it is the kind of thing a path grammar will be built on top of.

Today the disk is authored by this repo. The moment anything writes a disk this repo did not — a
package, a download, a second machine — the ELF and FAT parsers become the primary attack surface,
and they are two of the three largest files in the kernel.

---

## 4. What is missing, and what each one costs *for this OS*

Nine absences, each judged on this machine rather than in general. The recurring answer is not "yes"
or "no" but **"what does it protect against, and does that thing exist here yet?"** — because a
mitigation with no corresponding threat is not free: it costs lines, it costs goldens, and in two
cases below it costs the verification method that makes this codebase trustworthy in the first place.

Two measurements were taken for this section, because nothing in the repo had them.
**`measured:` `query-cpu-model-expansion` on QEMU 11.0.0, the version this tree is developed
against.**

| feature | `-cpu qemu64` (**pinned by every harness**) | `-cpu max` (what TCG can do) |
|---|---|---|
| `smep` | **false** | **true** |
| `smap` | **false** | **true** |
| `umip` | false | true |
| `pcid` | false | **false** — TCG does not implement it at all |
| `rdrand` / `rdseed` | **false** / **false** | true / true |
| `rdtscp` | false | true |
| `nx` | true | true |

Two consequences run through everything below. **First: there is no hardware random number generator
on the pinned CPU model.** Any design that needs entropy — ASLR, KASLR, a real stack-canary value, a
TCP initial sequence number — has to get it from the PIT or the TSC, and the kernel has no
`rdtsc_read` extern today. **Second: `pcid` is false even on `max`, so PCID/KPTI are not merely
unbuilt, they are unavailable** — which retires GAP-0085 item 6's PCID clause and ADR-0013 §10's on
this machine, permanently, until someone runs on KVM or on metal.

### 4.1 No users · no uids · no `root`

**Worth it: no. Not at this milestone and, I will argue, not ever in this shape.**

A uid is an answer to "which *human* is asking", and this OS has one human and no plausible second.
The principals that will actually multiply here are not people, they are **programs**: a compositor
that must be allowed to receive every keystroke, a network daemon that must be allowed to open
`/net`, an ffmpeg job that must be allowed neither. A uid cannot express any of those distinctions,
because all three would run as the same user.

The cost of building it anyway is small and the cost of *having* it is the problem: a uid word in the
process slot (free — the slot is 64 words and 20-odd are used), a `getuid`, and then nothing that
consults it, because FAT has no owner field to compare against. This repo has a rule about that —
GAP-0120's *"no counter that nothing reads"* — and a uid nothing checks is exactly such a field, with
the added hazard that its presence invites later code to *believe* it means something.

**Recommendation: skip uids entirely and put the authority on the process, not on a user.** §6.

### 4.2 No permissions

**Worth it: not as a general model. Worth exactly one bit, now, and that bit is a bug.**

A general permission model is blocked on the filesystem, not on the kernel. FAT16 has one attribute
byte and no owner, no mode, no ACL; `storage.md` is where a filesystem that could carry them is
argued for, and bolting a permission model onto FAT would mean inventing a side table, which is worse
than not having one.

**But one permission bit already exists on disk and this kernel ignores it.** `fat.dart:154` defines
`fatAttrReadOnly = 0x01`. `fileMakeEmpty` (`file.dart:1042`) — the function `open(name, O_WRITE)`
calls, which **truncates and rewrites the directory entry** — checks `fatErrIsDir` and does not check
`fatAttrReadOnly` at all. So on this OS today:

> `open("README.TXT", O_WRITE)` on a file whose FAT read-only attribute is set **truncates it to zero
> bytes**, from ring 3, silently.

That is not a design gap, it is a defect, and it is the cheapest genuine security fix in this
document: **one test against `fatMetaFileAttr` in `fileMakeEmpty`, one new refusal code
(`fileRetReadOnly`) with its own sentence, and one line in a harness program.** It honours a bit the
disk already carries, it needs no filesystem work, no model and no policy, and it is the only piece
of §4 that is worth doing before anything else in this document.

**Recommendation: fix the read-only attribute now. Defer everything else about permissions to
`storage.md`'s filesystem milestone, and do not invent a mode word for FAT.**

### 4.3 No file ownership

**Worth it: no, and it is the same answer as §4.1 for the same reason.** FAT has no owner field, so
this is not deferred-because-expensive, it is deferred-because-there-is-nowhere-to-put-it. When
`storage.md` produces a filesystem with an inode, the question to ask is not "who owns this file" but
"which handle was this process given" — §6.

### 4.4 No capabilities

§6, in full. Short version: **yes, this is the right model for this OS, and it is the only item in
§4 that changes the architecture rather than adding a defence to it.**

### 4.5 No ASLR

**Worth it: no, and it would be theatre if it were built today.**

Four separate things block it and each is a real cost:

1. **There is no entropy.** Measured above: `-cpu qemu64` has neither `rdrand` nor `rdseed`. A
   randomised base derived from a constant is not randomised.
2. **Programs are not position-independent.** The loader maps at each segment's `p_vaddr` and enters
   at `e_entry`; the programs are static non-PIE ELF64 linked at `0x10000000`. Making them PIE means
   relocation processing in the loader, which `exec-format.md` treats as its own milestone.
3. **The window is 512 pages wide.** `[vmProgBase, vmProgEnd)` is exactly one page-directory entry,
   `[0x10000000, 0x10200000)`. Randomising a base inside 2 MiB at page granularity buys **at most 9
   bits**, and the stack is pinned at the last page (`vmProgStackPage = 0x101FF000`). Nine bits is
   brute-forceable in under a second by an attacker who can retry — and an attacker who can retry is
   the only kind ASLR defends against.
4. **It defeats the harnesses.** `m10-elf`, `m11-proc`, `m12-heap` and `m19-argv` all derive expected
   addresses from `prog.elf`'s own headers and compare them against guest memory. A randomised base
   turns every one of those into a derivation from a runtime-reported value, which is a strictly
   weaker assertion.

ASLR is a mitigation for *remote code execution against a long-lived process an attacker can crash
and retry*. That process does not exist here and will not exist until `net-stack.md` N8 puts a
listening endpoint on the machine. **Recommendation: not before N8, and even then only for a
network-facing daemon, and only after `exec-format.md` has PIE for its own reasons.**

### 4.6 No stack canaries in user code

**Worth it: yes — and it is the one classic mitigation whose value here is *not* about adversaries.**

This OS's real threat model is bugs (§2.1). A stack smash in a ring-3 program today produces a return
into garbage and then a #GP or a page fault at a RIP that says nothing about where the bug is. A
canary turns that into `__stack_chk_fail` → `exit(<named status>)` at the *function that overflowed*.
That is a debugging win in a system whose entire verification method is "the capture says what
happened", and it is worth having even with a **fixed** guard value, because a fixed guard catches
every accidental overflow and only fails against a deliberate one.

Cost, precisely: `clang -fstack-protector-strong` on the userland build, plus two symbols in
`core/user/libc/` — a `__stack_chk_guard` word and a `__stack_chk_fail()` that calls `exit()` with a
distinguished code. `libc-roadmap.md` counts 41 symbols today; this is two more, neither of them
C89, both trivial.

The cost that is **not** trivial: every program rebuilt with the flag has a different ELF, which
changes its disk image, which moves that harness's derived expectations. So: **apply it to `libc` and
to new programs; do not retrofit it onto the nineteen existing harness programs.** The flag belongs
in `core/user/`'s build alongside whatever tier of `libc-roadmap.md` lands next, not in a milestone of
its own.

### 4.7 No SMEP, no SMAP

§5, in full. **This is the highest value-per-line item in the document.**

### 4.8 No KASLR

**Worth it: no — and unlike §4.5 this is not "not yet", it is "this would make the project worse".**

The kernel is loaded by Multiboot at a fixed physical address, linked by `core/link/kernel.ld` at a
fixed virtual address, identity-mapped, and is not relocatable. Building KASLR means making it
relocatable and then randomising the base with entropy that does not exist (§4).

The decisive objection is not the cost, it is what it destroys. **This codebase's trustworthiness
comes from harnesses that read guest physical memory at addresses derived from `kernel.elf`'s own
symbols** — `m7-frames` reads the 4096-byte allocator bitmap and matches it bit-for-bit; `m8-paging`
decodes the live page tables; `m9-ring3` decodes the GDT, TSS and all 256 IDT gates at the bases the
kernel printed *and requires them to equal the ones GDTR/TR/IDTR report*; `m11-proc` walks two PML4s.
Every one of those becomes "derive the base from something the kernel said, then check the kernel
against itself" — which is precisely the class of assertion this repo has repeatedly refused
(ADR-0013 §7: *"a payload that read `%cs` itself and printed it would be the thing under test testing
itself"*).

KASLR defends against a remote attacker who has an information leak and needs a kernel address. That
attacker is defeated far more cheaply by SMEP (§5), which costs one bit and no goldens.
**Recommendation: never, or at least never before there is a demonstrated kernel info-leak primitive
reachable from outside the machine.**

### 4.9 No signed executables

**Worth it: no. The useful thing in this neighbourhood is not signing, it is integrity, and it is a
verification feature rather than a security one.**

Signing needs a hash and a signature scheme in a kernel with no bignum arithmetic and, per
`libc-roadmap.md`, **nine of C89's 139 functions**. It needs a key, and the only place to put one is
compiled into a kernel that is built by the same command as the disk image it would be checking — so
the signature would prove that the build signed its own output, which is not a property anyone needs.

The cheaper thing that captures most of the value: **the ELF loader already knows every byte it
mapped.** A running hash over the mapped image, printed in the `ELF` report, would let a harness
assert *"the bytes that reached the page tables are the bytes on the disk"* — which is a real
anti-vacuity property (it kills the mutant that maps a page and forgets to copy into it) and needs no
key, no crypto and no policy. `m10-elf` already runs six single-field mutations; an image hash is the
seventh, and it covers a class the six do not.

**Recommendation: no signing. Consider an image hash as a `m10-elf`/`exec-format.md` verification
item, decided on verification grounds and not filed under security at all.**

### 4.10 The summary, ordered by value per line

| item | verdict | when |
|---|---|---|
| FAT read-only attribute honoured in `fileMakeEmpty` | **defect — fix now** | immediately; ~6 lines |
| **SMEP** | **build** | as soon as anything touches `boot.S`; §5 |
| stack canaries in `libc` | build | with the next `libc-roadmap.md` tier |
| **SMAP** | build | after the §5.4 audit; before N2 |
| a malformed-frame injector | build | **before** N2, not after; §7 |
| capabilities (handles) | adopt as the model | at the first multi-principal milestone; §6 |
| file ownership / permissions | defer | to `storage.md`'s filesystem |
| ASLR | defer | not before N8, and after PIE |
| signed executables | reject; do an image hash instead | — |
| uids | **reject** | — |
| KASLR | **reject** | — |
| PCID / KPTI | **unavailable** — `max` reports `pcid: false` under TCG | — |

---

## 5. SMEP and SMAP — the measurement, and why SMEP is the highest value-per-line item here

### 5.1 The bug class

`CR4.SMEP` (bit 20) makes an **instruction fetch from a user-accessible page while CPL = 0** a page
fault. `CR4.SMAP` (bit 21) makes a **data access to a user-accessible page while CPL = 0** a page
fault unless `EFLAGS.AC` is set with `stac`.

The class they catch is exactly the one this kernel's four validators exist to prevent and are
otherwise the *only* defence against — and GAP-0085 item 6 already says so, in the best sentence in
`known-gaps.md`:

> neither is enabled, so the `write` syscall's pointer check is software-only. It is a real check
> (ADR-0013 §5) and it is the only one: **a bug in it is not backstopped by hardware the way
> `.rodata` is backstopped by `CR0.WP`.**

That is the whole argument. §1.5 records that a validator which checked only the first page of a
range **survived a mutation round**. It was found, and the person who found it wrote a test that
kills it — but the next one might not be. SMEP and SMAP are the backstop that turns "a validator was
wrong" from *silent corruption* into *a fault at the exact instruction, with the address in CR2*.

### 5.2 The measurement — and it is not in the corpus

`smp.md` is the document that measured this CPU model's features, and what it measured is narrower
than one would hope. Its fact 13 (`smp.md:65`) records exactly two properties from
`query-cpu-model-expansion` on `qemu64`: `"apic": true` and `"x2apic": false`. Mechanically, over its
1173 lines: **zero occurrences of `SMEP`, `SMAP`, `CR4`, `CR0`, `0x80000001`, `leaf 7`, or any
register name.** The two places in the whole tree that mention SMEP — `known-gaps.md:2408` and
ADR-0013 §10 — assert the absence and neither says whether the CPU even has the bits.

So it was measured here.

**`measured:` QEMU 11.0.0, `query-cpu-model-expansion` type `full`:**

```
qemu64            smep=false  smap=false  umip=false  pcid=false  nx=true
max               smep=TRUE   smap=TRUE   umip=true   pcid=false  nx=true
qemu64,+smep,+smap  ->  smep=TRUE  smap=TRUE
```

Three conclusions, in order of importance:

1. **`-cpu qemu64` does NOT expose SMEP or SMAP.** CPUID.7.0:EBX bits 7 and 20 are clear. A kernel
   that probed for them today would find nothing and set nothing.
2. **TCG implements them.** `max` is "everything this accelerator can do", and it reports both true.
   So `-cpu qemu64,+smep,+smap` is not a request QEMU will silently ignore — it is a supported
   configuration, and the expansion confirms the bits come back set.
3. **Turning them on moves no CPUID report.** `measured:` with `+smep,+smap` the model still reports
   `level = 13` (0xD), `xlevel = 0x8000000A`, `vendor = AuthenticAMD`, `model-id = "QEMU Virtual CPU
   version 2.5+"`. Those are exactly the four things `m4-fault/run.sh:451` pins `-cpu qemu64` for:
   *"the `CPU VENDOR`/`CPU BRAND`/`CPU LEAF` lines report…"*. **`CPU LEAF 0000000D EXT 8000000A` does
   not move.**

### 5.3 SMEP costs one `orl` and moves zero goldens

The kernel already has every piece.

**The probe pattern exists, twice, in the file that would host a third.** `boot.S:490-505` probes
CPUID leaf 1 EDX bits 24/25 for FXSR/SSE into `sse_flag`, asking leaf 0 first so that "maximum leaf
is 0" is handled rather than assumed. `boot.S:548-562` probes leaf `0x80000001` EDX bit 20 for NX
into `nx_flag`, asking leaf `0x80000000` first so an unsupported leaf is not executed. A leaf-7
subleaf-0 probe for EBX bits 7 and 20 is **the same eight instructions a third time**, guarded by
`cmpl $7, %eax` after leaf 0 — and it goes in the same place, between the existing two.

**The CR4 write exists and is deliberately singular.** `boot.S:522-528`:

```
    movl %cr4, %eax
    orl $0x20, %eax                /* PAE */
    cmpl $0, sse_flag
    je skip_osfxsr
    orl $0x600, %eax               /* bit 9 OSFXSR, bit 10 OSXMMEXCPT */
skip_osfxsr:
    movl %eax, %cr4
```

with a comment insisting on **one** CR4 write because *"a second read-modify-write of the same
control register is a second chance to clobber a bit that is already in it"*. SMEP is one more
`cmpl`/`je`/`orl $0x100000` in the same block, honouring that rule.

**The reporting accessor exists.** `cr4_read()` (`isr.S:714`) is already an `@extern`, already
declared in `proc.dart:1013`, and the `proc` command already prints **the full 16 hex digits of
CR4**:

```
PROC SSE 1 CR4 0000000000000620 CR0 0000000080010013
```

That line is already in the goldens of **m3-shell, m4-fault, m5-pci, m6-disk, m11-proc, m12-heap,
m13-libc and m14-fat**. And here is the whole cost analysis in one paragraph:

> **On `-cpu qemu64` the probe finds nothing, CR4 stays `0x620`, and every one of those goldens is
> byte-identical. Not one moves.** On a new boot with `-cpu qemu64,+smep` the same line reads
> `CR4 0000000000100620`, and the harness asserts it. **Zero new externs, zero new `@rodata` strings,
> zero DCDart changes, zero moved goldens, and roughly twelve lines of assembly.**

The precedent for the new boot is already in the tree: `m11-proc/run.sh:775` boots
`-cpu qemu64,-sse,-fxsr` and asserts *"reports SSE 0 with CR4 exactly 0x20 … which is what proves the
CPUID probe is load-bearing rather than decorative"*. This is the same control run in the other
direction — **add** a feature and require the kernel to consume it.

**And the kernel needs no code change whatsoever to be SMEP-clean**, because it never executes a
user-accessible page. The only user-accessible pages that exist are inside `[vmProgBase, vmProgEnd)`
or the M9 payload's two frames in the 4 KiB window, and the only thing that jumps into either is
`enter_user`'s `iretq`, which lands at CPL 3.

**Two corrections to the obvious cost estimate**, both of which make it cheaper than it looks:

* It does **not** need a sixth `cpuid` in `cpu_probe`. `m4-fault` asserts `cpu_probe` issues *exactly
  five* `cpuid`s in a 64-byte block — but those five are the vendor and brand strings (leaf 0,
  `0x80000000`, `0x80000002/3/4`). The **feature** probes have never gone through `cpu_probe`; they
  are inline in `_start`, and a third one changes nothing `m4-fault` measures.
* It does **not** move the donated-`.bss` count. `sse_flag` and `nx_flag` live in `boot.S`'s own
  `.bss`, not `kdata.S`'s, for the reason ADR-0013 §5 gives about `kstack0`: `kdata.S` is *DCDart's
  donated mutable storage and its size is a measurement of a language gap*, and a CPU capability flag
  is not that. A `smep_flag` beside them is invisible to every donated-`.bss` assertion in the suite.

### 5.4 SMAP is not free, and the reason it is not free is the reason to want it

SMAP faults on *data* access, and the kernel does dereference ring-3 addresses — in exactly the four
places §3.3 enumerates. There are two ways to satisfy it, and they are genuinely different designs.

**Option A — `stac`/`clac` around the four sites.** Two new `@extern` stubs in `isr.S`
(`stac_begin`/`clac_end`, two instructions each, `portio.S`'s shape). Four call sites bracket their
copy. Costs: the extern count moves (`m11-proc/run.sh:649` asserts 58), and the stubs must be
*guarded by the flag* because `stac` is `#UD` on a CPU without SMAP — so either the guard is a branch
at every copy, or the stubs are patched, or the machine is required to have SMAP. This is what Linux
does and it is the conventional answer.

**Option B — reach the program through the frame, not through the program's address.** §3.3's
finding is that this kernel *already does this everywhere else*: the ELF loader writes segment bytes
at `frame + lo`, `args.dart` writes `argc` and `argv` through `argsPhys(frame, va)` and says in its
header that *"the two addresses of one byte differ"*, `vmZeroFrame` zeroes at the identity address,
and every frame the allocator can hand out is inside the `[0, 128 MiB)` identity map that
`m7-frames` asserts equals the allocator's bound. Converting the four remaining sites means
translating the validated virtual range to physical — `vmProgLeaf(va)` already exists and already
returns the leaf entry — and copying at the identity alias, which is a supervisor mapping that SMAP
does not touch.

**Option B is the better one for this OS, and not primarily because of SMAP.** It makes the stronger
statement: *the kernel never dereferences an address ring 3 chose, at all.* The validators stop being
the last line of defence and become a policy check whose failure mode is a wrong-but-owned frame
rather than a wild pointer. It needs no new instruction, no new extern, no `#UD` guard and no
`AC`-flag state to get wrong on the interrupt path. Its costs are real and should be stated: a page
walk per page copied (the validator already does one, so the walk can be fused), one more place that
depends on the identity map being total, and — the one that matters — **`fileCopyIn`/`fileCopyOut`
must handle a range that crosses a page boundary into a different physical frame**, which is the same
straddle case §1.5's mutation round already made the validators handle. That symmetry is a good sign
rather than a coincidence.

**Recommendation: SMEP first and separately, because it is free. Then the Option-B conversion of the
four sites, which is worth doing on its own merits and makes SMAP a one-`orl` follow-on.**

### 5.5 The vacuity trap, named before anyone falls into it

**A SMEP probe written against `-cpu qemu64` and never booted with `+smep` is dead code that every
harness passes.** The probe finds nothing, the `orl` never executes, `CR4` reads `0x620`, every
golden matches, and the milestone reports success having proved nothing at all. That is the same
shape as `net-e1000.md`'s option-ROM trap — a criterion that passes against a kernel that does
nothing — and it is the specific way this item would go wrong.

So the exit criterion has to be a *pair* of boots and a *positive* fault. Borrowing the shape of
`vmtest nx` / `vmtest x`, which is already exactly this argument for NX:

* **`vmtest smep`** — take the page `vm_exec_ok` lives on (a lone `ret` in `.text`, already reachable
  through the existing `vm_exec_probe(addr)` extern which does `call *%rdi`), set its U/S bit with
  the existing `vmMapUser`, probe it, and clear it again with `vmClearUser` — the same
  set/probe/clear discipline `userTeardown` already uses, with interrupts already off.
* **The control is `vmtest x`, unchanged, on the same boot.** Same instruction, same page, same
  probe; the *only* difference is one bit of one page-table entry.
* **On `-cpu qemu64`:** both survive. `vm` reports `SMEP 0`, `proc` reports `CR4 …0620`.
* **On `-cpu qemu64,+smep`:** `vmtest x` still survives and `vmtest smep` takes **`#PF ERR 0x11`**
  — present, read, supervisor, **fetch** — at `vm_exec_ok`'s own address, and `proc` reports
  `CR4 …100620`.

Two boots, one bit of difference between the two commands, and the negative control is the *absence*
of the feature rather than a mutation of the kernel. That is the same structure `m8-paging` already
uses for `nx=off`, and it is why NX's claim in this tree is believable.

The SMAP pair is the same shape one layer down: a `Pointer<u64>` read from a user-accessible page,
with `vmtest rw`'s supervisor read as the control, faulting `#PF ERR 0x01` — present, **read**,
supervisor — only on the `+smap` boot.
