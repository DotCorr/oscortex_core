# ADR-0013 — Ring 3, and a way back: the privilege boundary, and the two writes that nearly stopped it

**Status:** accepted, implemented, verified (`core/tests/conformance/m9-ring3/run.sh`)
**Date:** 2026-08-21
**Narrows:** GAP-0081 items 1 and 3, GAP-0083. **Depends on:** ADR-0011 (frames), ADR-0012 (the address space, and its permissions).

---

## 0. What was wrong, stated as the fact that made it wrong

Everything this kernel had ever executed ran at CPL 0. Not "ran privileged by
default" — there was no other option available on the machine:

* `core/boot/boot.S`'s GDT had a null descriptor, one code descriptor and one
  data descriptor, all DPL 0. **CPL comes from the DPL of the code descriptor in
  CS.** With no DPL-3 code descriptor there is nothing `iretq` could load that
  would produce a CPL other than 0;
* there was no TSS and no `ltr`, so `RSP0` did not exist. Even with a ring-3
  descriptor, the first interrupt taken in ring 3 would have had no stack to be
  delivered on — a page fault, then a double fault, then a triple fault;
* every page in the address space `core/kernel/vm.dart` builds was mapped
  supervisor-only. A ring-3 program has nothing it is allowed to touch;
* every IDT gate had DPL 0, so even if all of the above existed, `int n` from
  ring 3 would have been a #GP rather than a way in.

The observable consequence was one field of one diagnostic. `vmPageFaultReport`
decodes bit 2 of the page-fault error code as `USER` or `SUPER`, and in nine
milestones it had printed `SUPER` every single time, because the CPU had never
had an opportunity to set that bit. GAP-0081 item 1 called this "the single
largest thing between M8 and *an operating system* rather than *a kernel with an
address space*".

`DCDART_SPEC.md` §2 anticipates the boundary by name: `@hosted` code reaching
`@bare` kernel services "crosses a syscall boundary, declared with `@syscall`".
Nothing in this milestone builds that language feature. What it builds is the
machine side of it, so that there is a boundary for a future `@syscall` to
declare.

---

## 1. What was built

| Piece | Where | What |
|---|---|---|
| two DPL-3 descriptors | `core/boot/boot.S` | `gdt64_user_data` (0x1B), `gdt64_user_code` (0x23) |
| a TSS + its descriptor | `core/boot/boot.S` | 104 bytes in `.bss`, descriptor patched at runtime, `ltr` in the boot stub |
| a 16KiB ring-0 stack | `core/boot/boot.S` | `kstack0`, and RSP0 points at its top |
| the transition | `core/boot/isr.S` | `enter_user` — five pushes and an `iretq`, with every register scrubbed |
| the way back | `core/boot/isr.S` | `user_return` — the `exit` syscall's stack switch, `fault_resume`'s sibling |
| `invlpg` | `core/boot/isr.S` | the first thing in this kernel that edits a live mapping needed it |
| U/S support | `core/kernel/vm.dart` | `vmMapUser`, `vmClearUser`, `vmEffective`, `vmCountUser` |
| a DPL-3 gate | `core/kernel/user.dart` | IDT vector 0x80, attribute `0xEE` instead of `0x8E` |
| three syscalls | `core/kernel/user.dart` | `exit`, `write`, `whoami` |
| six payloads | `core/kernel/user.dart` | 38, 15, 17, 16, 24 and 9 bytes of hand-written machine code, plus a 17-byte message — 136 `@rodata` bytes in six tables |
| 144 bytes of state | `core/boot/kdata.S` | `user_store` behind one accessor, plus two asm-owned resume words |

Seven shell commands: `user`, `user gp`, `user pf`, `user badint`, `user badptr`,
`user hold`, `user pages`.

---

## 2. The two writes, and why they are the most useful thing in this ADR

M8 made `.rodata` read-only and set `CR0.WP` so the CPU obeys it. The GDT lives
in `.rodata`. Both of the following were **measured**, in this order, and neither
was anticipated:

**`ltr` writes to the GDT.** Loading the task register sets the BUSY bit in the
TSS descriptor — type 9 (available) becomes type 11 (busy). The first revision
called `ltr` from DCDart after `idt_load()`, on the deliberate theory that a
malformed descriptor should produce a reported #GP rather than a triple fault.
What it produced was:

```
M1 FAULT 0E 0000000000000003
```

A page fault. Present, write, supervisor — on the descriptor itself.

**A segment load writes to the GDT.** The CPU sets the ACCESSED bit (bit 40) the
first time a descriptor is loaded into a segment register. The kernel's own two
descriptors had always had it set by the CPU during `long_mode_start`, before
paging protections existed, so nothing had ever noticed. The user descriptors are
first loaded much later — `enter_user` writes the user data selector into DS —
and that produced:

```
FAULT 0E ERR 0000000000000003 OP 8ED8
PF CR2 000000000011701C ERR 00000003 PRESENT WRITE SUPER DATA
```

`OP 8ED8` is `mov %eax,%ds`. CR2 is `gdt64 + 0x1C`: byte 4 of the user data
descriptor.

### Both were fixed by removing the write, not by removing the protection

The obvious repair for each is "put the GDT in `.data`". It was rejected twice:
the GDT is a table the CPU re-reads on every privilege transition and every
interrupt, and M8 paid for the property that it is not writable. So:

* `ltr` moved into `boot.S`'s 64-bit stub, which runs after paging is on but
  before `vmInit` installs the real tables — the bootstrap tables mark everything
  writable, so the busy bit is written in the only window in which it can be, and
  the GDT is immutable from the CR3 switch onwards;
* the ACCESSED bit is pre-set on all four segment descriptors, so the CPU never
  needs to write it.

**The generalisation is the point, and it is ADR-0012 §2's lesson in a different
key.** There, the page-table entries were right and the CPU ignored them because
`CR0.WP` was clear: *the enforcement mechanism and the permission bits are two
different things, and only one of them is visible in a page-table dump.* Here,
the descriptors were right and the CPU refused to use them: **a table can be
correct and the hardware can still refuse it, for a reason that is nowhere in the
table.** Both times the artefact looked genuine.

What was given up by moving `ltr` is a diagnostic: a malformed TSS descriptor is
now a triple fault with no output, the same risk every other line of the boot
stub carries, which is why CLAUDE.md rule 4 puts GDT setup there. What replaced
it is external evidence — `m9-ring3/run.sh` reads the descriptor out of guest
physical memory and requires its type to be **11**, a state only `ltr` can
produce.

---

## 3. `int 0x80`, and why not `syscall`

`syscall`/`sysret` is the faster instruction and it is what a real kernel uses.
It was not taken, and the reason is not performance:

* `syscall` **does not change RSP**. It leaves the user stack pointer in place
  and hands the kernel `RIP` in RCX and `RFLAGS` in R11, so the kernel must
  switch stacks itself — which needs a per-CPU scratch location, `swapgs`, and
  `IA32_KERNEL_GS_BASE`. This kernel has one CPU and no per-CPU anything;
* it needs three MSRs (`STAR`, `LSTAR`, `SFMASK`) and a GDT laid out at fixed
  offsets from `STAR`;
* it needs a second entry path. `int 0x80` lands in `isr_common`, which already
  saves all fifteen general-purpose registers into exactly the data structure a
  `@bare` DCDart handler can read — because DCDart cannot read a register, and
  the only way to hand it CPU state is as an address it can walk with
  `Pointer<u64>` (ADR-0002).

So the syscall entry path for M9 is **one attribute byte**: gate 0x80 gets
`0xEE` instead of `0x8E`, which is `present, DPL 3, 64-bit interrupt gate`. The
GDT is nevertheless laid out in `sysret` order (user data before user code), so
that adding `syscall` later is a new instruction rather than a GDT rearrangement.

An interrupt gate, not a trap gate: IF is cleared on entry, so a timer tick
cannot interleave with a syscall that is half-way through printing.

---

## 4. The payload is a `@rodata` byte table, and that is the scope decision

There is no ELF loader here, no relocation, no `fork`, no `exec`. A payload is a
run of machine-code bytes in this kernel's own `.rodata`, copied into a frame
from the M7 allocator and jumped to. The largest is 55 bytes.

**Building a loader to prove a privilege boundary would have made the loader the
thing under test.** What is being proved is that the CPU enforces a privilege
level and that the kernel can be re-entered from one. The harness disassembles
every payload out of `kmain.o` and asserts the mnemonic sequence, so the
instruction-by-instruction documentation in `user.dart` cannot drift into
fiction, and each payload is required to still contain the one instruction it
exists to execute — `user gp` with the `mov %cr3` removed would still "pass" a
behavioural test by faulting for some other reason.

**Position-independence is the payload's job**, because there is no loader to
relocate it: the well-behaved payload reaches its message with `lea msg(%rip)`.

### Why `mov %cr3,%rax` and not `cli`

`cli` and `hlt` are privileged *relative to IOPL*. `cli` from CPL 3 is a #GP only
because `enter_user` pushes RFLAGS with IOPL 0, so a test built on it would be
measuring this kernel's choice of RFLAGS as much as the CPU's privilege check.
Reading CR3 is unconditionally privileged above CPL 0. If it faults, it faults
because the code is not in ring 0, and for no other reason.

### Why the payloads that must fault still contain an `exit`

Unreachable on a working kernel, and there so that a broken one says so. `user
gp`'s payload exits with the value it read, so a kernel that really did let ring
3 read CR3 prints its own PML4 address as an exit status — both an unmistakable
failure and the most useful possible evidence. The others exit `0xBAD`.

---

## 5. Decisions inside the boundary, and why each one

**Two pages, exactly, and W^X applies to ring 3 too.** The code page is
user + read + execute and **not writable**; the stack page is user + read + write
and **not executable**. A payload that could write its own code, or execute its
own stack, would be the hole M8 closed for the kernel, reopened for the one
program that is actually untrusted.

**The interior page-table entries carry U/S; no leaf does, except the payload's
two.** A page's effective permission is the AND of all four levels, so a U/S=0
entry on `PML4[0]` would make every leaf under it supervisor-only whatever the
leaf said. Interior entries are the ABSENCE of a veto — the same argument
ADR-0012 §5 makes for W and NX — and the leaf decides. The harness reads the U
bit of all 1024 pages in the 4KiB window out of guest memory, so "nothing else is
user-accessible" is a property of the leaves rather than of one interior entry.

**Both pages are zeroed before the payload is copied in.** `allocFrame()` returns
whatever the frame last contained (GAP-0076 item 5), and both pages are about to
become readable by an untrusted program. Handing ring 3 a page of stale kernel
data would be an information leak created by the very command that exists to
demonstrate isolation.

**Every general-purpose register is scrubbed before the `iretq`.** At that moment
they hold kernel addresses — the return address, pointers into donated `.bss`.
Ring 3 gets zeros and exactly one value, in RDI.

**Interrupts stay ENABLED in ring 3** (RFLAGS 0x202). A payload that ran with IF
clear would never exercise RSP0, which is the one field of the TSS this kernel
fills and the one whose absence triple-faults. With IF set, `user hold`'s spin
takes thousands of timer and keyboard interrupts, each switching to the ring-0
stack and `iretq`ing back to CPL 3.

**IOPL is 0 and the TSS's I/O-bitmap base is past its limit.** Together they make
`in`/`out` from ring 3 a #GP with no bitmap to override it. A payload that could
reach a device port would not be unprivileged in any sense that matters.

**RSP0 is a SEPARATE 16KiB stack, not the boot stack.** The boot stack is in use
when a payload runs: `shellUser` is a frame on it, `shellMain` is under that, and
M4's recovery mark points into the middle of it. RSP0 = `stack_top` would push the
first syscall's interrupt frame over `shellMain`'s own frame, and the corruption
would surface only after control returned to the shell. It lives in `boot.S`'s
`.bss` rather than `kdata.S`'s for `nx_flag`'s reason: `kdata.S` is DCDart's
donated **mutable** storage and its size is a measurement of a language gap, and
a CPU stack is neither — no DCDart code reads or writes it.

**The TSS is declared before the stack.** They are adjacent either way and there
is no guard page (GAP-0081 item 6 is still open). This order makes RSP0 a
different address from `tss_base()`, so the report is unambiguous, and it puts
the TSS where a stack overflow lands on it — which corrupts RSP0 and makes the
next entry from ring 3 a triple fault: loud and attributable, rather than
silently overwriting the boot stack's live frames.

**A syscall that takes a pointer validates it, and the bound on the pointer comes
before any arithmetic on it.** DCDart's arithmetic traps on overflow
(DCDART_SPEC §4.1) by emitting a real `ud2`, and `ptr` is a value ring 3 chose:
`write(0xFFFFFFFFFFFFFFFF, 8)` would make `ptr + len` overflow *inside the range
check* and take a #UD in the syscall handler. A ring-3 program must not be able
to choose which instruction the kernel executes next, and the check that was
supposed to stop it would have been the thing it used.

**Every exit from ring 3 goes through one teardown.** The `exit` syscall and the
fault path both call `userTeardown`, because the property that matters is not
"the pages are unmapped when the payload is polite". Three of the six
sub-commands end in a fault on purpose, and without the fault-path hook each of
them would leave two user-accessible pages and two allocated frames behind for
the rest of the boot. A boundary that is open whenever something went wrong is
not a boundary.

**`user hold` exists for the harness, and it is honest about it.** Every other
sub-command has torn its pages down by the time the prompt returns, so a dump
taken afterwards can only ever prove the teardown. `user hold` reports its CS and
spins forever, so the tables can be read with a ring-3 program on the CPU. It
never exits and nothing in this kernel can stop it (GAP-0085); it is the last
command any session can run.

---

## 6. The storage seam, for the third time

DCDart still has no mutable static data (GAP-0053), so this subsystem's state is
assembly-donated `.bss`: **128 bytes in ONE symbol (`user_store`) behind ONE
accessor (`user_store_addr`) reached through exactly ONE function
(`userMetaBase`)** — `vm_store`'s shape exactly, for `vm_store`'s exact reason
(ADR-0012 §3), which is ADR-0011 §0's answer to the objection that building on
the workaround makes the workaround load-bearing. `m9-ring3/run.sh` counts the
call site.

The two words `enter_user` and `user_return` need are **not** behind that seam
and never will be. They hold a stack pointer; DCDart cannot read or write one;
they will still be assembly-owned on the day DCDart grows mutable statics —
exactly like M4's `shell_resume_rsp`.

Donated `.bss` goes 5224 → **5368**. Every earlier harness still asserts its own
milestone's number by subtracting the blocks that came after it, so no earlier
claim is diluted: m5-pci and m6-disk still assert 424, m7-frames still asserts
5096, m8-paging still asserts 5224. The same discipline applies to the extern
count, which m5/m6/m7/m8 now check by subtracting M9's **eight by name**.

---

## 7. How this is verified, and why the golden cannot launder a broken boundary

`m9-ring3/run.sh`: 9 structural checks, `verify-freestanding.sh` clean, **four**
QEMU boots. `expected.txt` is a byte-exact golden **and** every privilege claim
in it is independently recomputed from two sources the kernel does not control —
QEMU's own `info registers`, and guest physical memory.

**Ring 3 is ring 3, and the payload is not asked.** The `whoami` syscall reports
the CS the **CPU** pushed when it took the `int 0x80`; its low two bits are the
CPL the processor believed the code was running at. A payload that read `%cs`
itself and printed it would be the thing under test testing itself. Boot B adds a
third party: QEMU's `info registers` says `CPL=3`, `CS =0023`, with RIP inside
the payload's own page.

**The U/S bits are read out of the live tables with a payload on the CPU.**
Exactly two of the 1024 pages in the 4KiB window are user-accessible, and they are
the two the kernel said it mapped — code read+execute, stack read+write. No page
of `.text`, `.rodata`, `.data`/`.bss` or the first megabyte is, and no 2MiB leaf
anywhere is. After the session, with five payloads finished (three of them killed
by faults), the count is zero.

**The GDT, the TSS and the IDT are decoded out of guest memory** at the bases the
kernel printed, which are then required to equal the ones the GDTR, the task
register and the IDTR report. Both user descriptors present with DPL 3 and the
accessed bit; the TSS descriptor **busy**, limit 103, base equal to the symbol;
RSP0 inside `[__data_start, __kernel_end)`; the I/O-bitmap base past the limit;
and of 256 IDT gates, exactly one has DPL 3 and it is 0x80.

**Three negative controls, plus two mutation tests.**

* **`-m 32M`** — a different machine. Different memory map, different frames, and
  ring 3 must still enter, still fault with the USER bit, and still leave nothing
  mapped. The capture must diverge from the golden *inside* M1's own boot report.
* **the drained allocator** — `frames drain` first, so `user` must REFUSE with a
  diagnostic rather than entering ring 3 with a page nobody allocated. This is
  what says the payload's pages are really allocated, and it is the refusal
  path's only test.
* **`user badint`** — the control for the syscall gate. `int $3` from ring 3
  raises #GP with error code `0x1A` = `(3 << 3) | IDT`. Without it, "int 0x80
  reached the kernel" would be equally consistent with "the DPL field does
  nothing on this CPU".

Two deliberately broken kernels were built in the sandbox mirror (never in the
repo) and run:

* **`vmMapUser` with the U/S bit removed.** The payload took `#PF ERR 0x15`
  (present, read, user, fetch) on its first instruction fetch. With the golden
  **regenerated from the broken kernel** — the exact scenario "regenerating the
  golden cannot make it pass" claims to cover — the derived checks still failed,
  naming the cause: *"the well-behaved payload did not run to completion"*, and
  then ten times over, *"while mapped, the CODE page is P1 U0 W0 X1, expected P1
  U1 W0 X1"*.
* **the syscall gate at DPL 0.** The structural check caught it before booting;
  with that check disabled AND the golden regenerated, `int 0x80` from ring 3
  produced `#GP ERR 0x402` = `(0x80 << 3) | IDT`, and the derived checks failed
  with *"gate 0x80 has DPL 0"*.

---

## 8. `DCDART_PIN.txt` did not move

`e3cfe18`, unchanged from M7 and M8. Nothing in this milestone needed a language
capability that pin does not have. All ten pre-existing harnesses were re-run
against it, **with the kernel unchanged**, before any M9 code was written —
10/10 — using an isolated clone of DCDart at that commit mirrored beside a copy
of this repo (ADR-0011 §7's method, with GAP-0084's `core/frontend` step).

One `dcc` refusal was hit and it was correct:

```
dcc build: DccLowerError: "userTeardown": "vmClearUser" returns a value, but its
result is discarded here — bind it to a local (`final _unused = vmClearUser(...);`).
Only void-returning calls may stand alone as a statement
```

The statuses are now bound and reported when non-zero.

One toolchain behaviour was worth recording rather than working around. Written
as a chain of `if`s returning five constants, `userCodeLen` was lowered by LLVM
into `.Lswitch.table.userCodeLen` in **`.rodata.cst32`** — outside `.rodata`'s
section index, which `m1-interrupts/run.sh` asserts every OBJECT symbol `dcc`
emits is inside. That is GAP-0079's phenomenon, second sighting, in a mergeable
section this time. **The assertion was not relaxed** (ADR-0012 §8: an assertion a
milestone weakens in order to pass is not an assertion); the table LLVM wanted to
build is written explicitly instead, which is where it belonged — and the harness
now checks its six bytes against the payload symbols' real sizes, which is a
stronger check than the hand-maintained literal it replaced.

---

## 9. Rejected alternatives

**`syscall`/`sysret` instead of `int 0x80`.** Rejected as scope: three MSRs, a
stack switch this kernel would have to write itself, `swapgs` and a per-CPU
scratch area, and a second entry path — to replace one attribute byte. §3.

**Put the GDT in `.data` so `ltr` and the segment loads can write it.** Rejected
twice, once for each write. It gives up a property M8 paid for, on a table the CPU
consults on every privilege transition. §2.

**An IST for the ring-3 entry path.** Rejected for the reason M1 removed the one
it had (`isr.S`'s header): every interrupt this milestone takes is delivered while
a healthy 16KiB ring-0 stack is current, and an IST's remaining merits — surviving
a double fault on a corrupt stack, and NMI — belong to the milestone that adds a
double-fault test and can prove it works.

**A second address space (a second CR3) for the payload.** Rejected as scope, and
it is the honest next step rather than a wrong one: it needs per-process page
tables, a switch on entry and exit, and the `invlpg`/shootdown question in full.
GAP-0085 item 1.

**An ELF loader.** Rejected: it would make the loader the thing under test. §4.

**A `kill` for `user hold`.** Rejected: killing a running payload needs either
preemption (a timer handler that can decide not to return to ring 3) or a
scheduler, and both are a different milestone. Named in GAP-0085 rather than
half-built.

**Let the fault path leave the payload's pages mapped and reclaim them lazily.**
Rejected: it is precisely the state a privilege boundary must not be able to end
up in, and three of six sub-commands would produce it every time.

---

## 10. What this closes, and what it does not

**Narrows GAP-0081 item 1 to nothing.** There is user/supervisor separation. Ring
3 exists, a TSS exists, RSP0 exists, a syscall path exists, and the `USER` field
of the page-fault report has now printed both of its values. The item is closed.

**Narrows GAP-0081 item 3.** There is now a `map`/`unmap` API — but it is
deliberately not the general one. `vmMapUser`/`vmClearUser` flip the U/S bit and
the W/NX pair of a leaf that **already exists** inside the 4KiB window; they
cannot create a mapping, choose an address, or allocate a page table. The general
`map(va, pa, flags)` is still unbuilt.

**Narrows GAP-0083.** `invlpg` exists and is used, because M9 is the first thing
that edits a live mapping. TLB *shootdown* is still absent and still needs a
second CPU to matter.

**What remains, and none of it is in scope here** (GAP-0085):

* **No per-process address spaces.** One PML4, still the kernel's, with two pages
  temporarily marked user-accessible. The payload is not a process; it is a
  privilege level with two pages.
* **No scheduler, no preemption, no processes.** One payload at a time, entered
  synchronously from a shell command, and `user hold` cannot be stopped.
* **No ELF loader, no `fork`, no `exec`, no file descriptors, no `brk`/`mmap`.**
  Three syscalls, two of which exist to be refused.
* **No SMEP, no SMAP, no PCID.** The kernel can still execute and read
  user-accessible pages, and nothing stops it.
* **The syscall ABI is not DCDart's.** `DCDART_SPEC.md` §2's `@syscall` is a
  language feature that does not exist on either side; this milestone builds the
  machine boundary it would compile down to, not the declaration.
