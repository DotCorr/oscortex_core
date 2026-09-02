# ADR-0015 — Two processes, two address spaces, and the 512 bytes that make SSE safe

**Status:** accepted, implemented, verified (`core/tests/conformance/m11-proc/run.sh`)
**Date:** 2026-08-22
**Closes:** GAP-0092. **Narrows:** GAP-0089 items 1, 2 and 5.
**Depends on:** ADR-0011 (frames, and the storage seam), ADR-0012 (paging), ADR-0013 (ring 3), ADR-0014 (the loader).

---

## 0. What was wrong, stated as the fact that made it wrong

Two facts, and the second one is the expensive one.

**There was one address space and it was the kernel's.** A loaded program got a
single 2MiB window inside it, carried by one page-directory entry in the
kernel's own page directory. Two programs could not be loaded at once, and
`run` refused the second by name — a refusal nothing could reach, because
nothing could produce the state that would trigger it (GAP-0089 item 1).

**`core/boot/boot.S` set exactly one bit of CR4: PAE.** It had never set
`OSFXSR` (bit 9), so *every SSE instruction was a #UD, in ring 0 and ring 3
alike*. That had not mattered for ten milestones, because `dcc` emits integer
code only and every line of assembly here is hand-written. It mattered the
moment a program arrived that this kernel had not compiled: at `-O2`, clang
emits `movups` for an ordinary 64-byte struct copy, and the x86-64 SysV ABI
assumes SSE exists. M10's test program had to be built with
`-mgeneral-regs-only`, and `build-prog.sh` had to assert the *disassembly*
contained no `%xmm` register, because a flag is not evidence. GAP-0092 recorded
the cost in one sentence: **a program compiled the way anybody would compile one
dies in ring 3 at whatever instruction happened to get an XMM register, with a
`#UD` whose cause looks like a loader bug.**

GAP-0092 also recorded why the fix was a milestone and not three bits:

> Setting the bits without the save area would be worse than not setting them:
> two things sharing `%xmm0` across a syscall is a corruption nobody would look
> for.

Which is to say the FPU half needed the process half. This ADR is both.

---

## 1. What was built

* `core/boot/boot.S` probes CPUID leaf 1 for FXSR (EDX[24]) and SSE (EDX[25]),
  writes the answer to `sse_flag`, and — **only if the answer is yes** — sets
  `CR4.OSFXSR | CR4.OSXMMEXCPT`, sets `CR0.MP`, clears `CR0.EM`, and executes
  `fninit`.
* `core/boot/isr.S` gains `fx_save`/`fx_restore`: `fxsave (%rdi)` and
  `fxrstor (%rdi)`, and `cr4_read`.
* `core/boot/kdata.S` gains `proc_store`: **4160 bytes, `.align 16`, one
  symbol** — an 8-word header, four 512-byte process slots, four 512-byte
  FXSAVE areas — behind one accessor, `proc_store_addr`.
* `core/kernel/proc.dart` (new): the process table, the per-process address
  space, the context switch, the `yield` syscall, the teardown, and the `proc`
  shell command.
* `core/kernel/vm.dart` gains `vmLivePml4()` and `vmProgPd()`: the program-window
  API now walks from **CR3** rather than from the kernel's remembered PML4.
* `core/kernel/user.dart` routes `exit`, faults and pointer validation through
  the process path when one is live, and dispatches syscall 3.

Donated `.bss`: **5496 → 9664 bytes**. 4160 of that is `proc_store`; the other
**8 are alignment padding**, because `elf_store` ends at 5496 and `.align 16`
must round up. The padding is charged to this milestone rather than hidden, and
every earlier harness recovers its own number by subtracting *everything past
the end of `elf_store`* rather than by subtracting `proc_store`'s size.

Declared externs on `kmain.o`: **53 → 58**. Five, and each is a thing DCDart
cannot express: two instructions (`fxsave`, `fxrstor`), two control-register
reads (`cr4_read`, and `sse_enabled`'s word), and one storage seam.

---

## 2. The FPU state: eager, late, and built from a known image

**Eager, not lazy.** x86 offers lazy FPU switching through `CR0.TS` and #NM.
This kernel does not use it. `CR0.MP` is set and `CR0.TS` is never touched;
every switch saves and restores unconditionally. Lazy switching buys 512 bytes
of memory traffic on switches where the FPU was not used, and costs a fault
handler, a per-CPU "who owns the FPU" variable, and an entire class of bug
whose symptom is one program seeing another's registers. At two processes and a
cooperative `yield`, that is a trade with no upside.

**Late, and that is a claim the harness checks.** `procYield` calls `fx_save`
*after* `isr_common` has pushed fifteen registers, after `userSyscall` has
dispatched, and after `procSaveFrame` has copied 22 words. That is only correct
if none of the intervening code can have touched an XMM register. It cannot:
`dcc` emits integer code only, and every line of assembly in this repo is
hand-written. **`m11-proc/run.sh` disassembles the entire linked kernel and
requires the number of instructions naming an `%xmm`, `%ymm` or `%zmm` register
to be exactly ZERO.** The day that number is not zero, saving late stops being
safe, and the check says so before a program does.

**Built, not captured.** A fresh process's save area is *zeroed and then
written* — control word `0x037F`, MXCSR `0x1F80` — rather than produced by
`fninit; fxsave`. `fxsave` would capture whatever was in XMM0-15 at the moment
it ran, which is the previous process's data: the exact leak this subsystem
exists to prevent. The initial register state of a process is something this
kernel gets to state, and `procFxInit` is where it states it.

**Why the MXCSR value is written by hand rather than inherited.** `fxrstor`
raises **#GP if the MXCSR image has a reserved bit set** — a general protection
fault *inside a context switch*, with the FPU half-restored. `.bss` is not
zeroed by anything in this kernel, so an area that had never been initialised
would be allocator litter, and roughly half of all litter has a reserved MXCSR
bit. `procInit()` writes all four areas from `kmain()` before the first byte of
output, and `m11-proc/run.sh` reads all four back **out of guest RAM** and
checks the control word and the mask bits there rather than believing the source
that wrote them.

**Why `CR0.EM` clear and `CR0.MP` set.** `EM` ("emulate coprocessor") makes
every x87 *and* every SSE instruction raise #UD no matter what CR4 says, so
`CR4.OSFXSR` with `EM` still set is a bit that changes nothing. `MP` pairs with
`TS`; with both clear, `wait`/`fwait` would ignore a pending unmasked x87
exception. Both are power-on-correct on QEMU and are written anyway, because
"the reset state happens to be right" is not a property a kernel gets to depend
on — and `cr0_read()` prints the answer back.

---

## 3. Probe before you write, or there is nothing to debug with

CR4 bits 9 and 10 are **reserved on a CPU without SSE**, and writing a reserved
CR4 bit is a #GP. This write happens in the 32-bit boot stub, *before any IDT
exists*, so on real hardware the failure mode is a triple fault: a silently
rebooting VM with no output at all and nothing to attach a debugger to.

That is not hypothetical here. It is exactly what `EFER.NXE` would have done at
M8 if it had been set unconditionally, which is why `nx_flag` exists, and this
is `nx_flag`'s argument applied to a second capability. The probe is asked first
(leaf 0 for the maximum leaf, then leaf 1), the answer is written to memory, and
**all three** of the CR4 write, the CR0 write and `fninit` are guarded by it —
`m11-proc/run.sh` counts the guards and requires three, and requires the probe
to appear *before* the CR4 write in the file rather than merely to exist.

**A measurement that corrects the story, and it is the reason boot C asserts two
things instead of one.** A kernel built with the guard deleted was run on
`-cpu qemu64,-sse,-fxsr`. **It did not triple-fault.** QEMU accepted bit 10 and
silently dropped bit 9, and all 544 bytes of M1's output appeared as usual. So
under this emulator the thing that catches an unguarded write is CR4 reading
back `0x420` instead of `0x20`; on real hardware it would be the absence of
output. The harness asserts both, and GAP-0099 records that only one of them can
fire here.

**On a CPU that says no, this kernel refuses to make a process at all.**
`procErrNoSse` — *"this CPU has no FXSAVE, so a process cannot own FPU state"* —
is returned by `shellProcRun` before anything is allocated. That refusal is
GAP-0092's argument read from the other end: a process whose FPU state is a
thing nobody owns is the state that gap says must not exist.

---

## 4. One PML4 each, and the one line that made the loader per-process

`procSpaceBuild` takes three frames from the allocator — a PML4, a PDPT and a
page directory for `[0, 1GiB)` — and copies the kernel's entries into all three.
The kernel's 4KiB identity window is shared **by reference** (the process's page
directory holds the same pointers to `pt0`/`pt1` the kernel's does, so a change
to a kernel page is seen by every process, which is what "the kernel's mappings
are shared" has to mean). The 2MiB leaves are copied by value, because a leaf
*is* its mapping and there is nothing to point at. `PML4[0]` and `PDPT[0]` are
then pointed at the process's **own** next level, which is what makes `PD[128]`
— the program window — able to differ.

**Why not share `PML4[0]` and give each process a different window address.**
Because that is not isolation, it is address allocation. Sharing `PML4[0]`
shares the whole low 512GiB: every process's pages would be reachable from every
other process's tables and the only thing keeping them apart would be the
programs not looking. The window stays at `0x10000000` for **all** processes —
the same address M10's `run` uses, so the same linker script and the same
binaries work under both — and it is a **different page** at that address in
each one.

**`core/kernel/elf.dart` did not change by one line, and that is the point of
`vmProgPd`.** The loader edits the page directory it reaches through
`vmProgMap`; `vmProgPd` used to be the constant `vmFrame(vmIxPdLow)` and is now
a walk from **CR3**. So `procCreate` installs the target process's CR3, calls
`elfLoad` unchanged, and installs the kernel's again. Every doc comment in
`vm.dart` already said "the live tables"; M11 is the milestone at which there is
more than one set of them and the sentence acquired teeth. A mutation that
removed those two `paging_install` calls — loading both programs into the
kernel's address space, which is exactly what M10 did — fails the harness with
neither program's message appearing at all.

---

## 5. The interrupt frame is the continuation, and that is the whole switch

`isr_common` already pushes fifteen general-purpose registers and the CPU
already pushed RIP/CS/RFLAGS/RSP/SS. **Twenty-two consecutive words on the
ring-0 stack therefore describe a suspended ring-3 thread completely.** M9 built
that layout for a DCDart handler to *read*; it turns out to be a context block.

So a context switch here is: copy those 22 words out to the current slot, copy
the next slot's 22 words in, write CR3, restore 512 bytes of FPU state, and
return normally. `isr_common` then pops fifteen registers and `iretq`s — into
the *other* process. No second kernel stack, no stack switching, no assembly
beyond the two instructions `fx_save`/`fx_restore` already are.

**One ring-0 stack is enough**, precisely because only one process is ever
inside the kernel at a time — a property of the switching being cooperative,
which would stop being true the day it is not. RSP0 in the TSS is reloaded by
the CPU on every entry from ring 3, so nothing else has to happen.

**The one word patched by hand.** The saved frame was built by an `int $0x80`
whose RAX held the syscall *number*, 3. Restoring it unaltered would hand the
resumed process a `3` as its syscall return value — a number that means nothing,
arrived at by accident, and indistinguishable from a real result. The saved
copy's RAX word is overwritten with 1: *"you yielded, and you are back."* A
mutation that deleted that one line **passed every check in the first version of
this harness**, because neither test program looked at the value. Both do now
(§7).

---

## 6. Cooperative. Not preemptive. Said here so nothing has to infer it

There is no scheduler and no preemption. A process runs until it calls `yield`
(syscall 3) or `exit` (syscall 0). The timer interrupt fires while it runs and
returns to it, exactly as it did at M9 and M10. **A process that calls neither
cannot be stopped**, and `proc run <a> <b>` where either program loops forever
is the last command that session can run.

`procPickNext` is round-robin from the caller rather than lowest-first, because
lowest-first with two processes is not a policy, it is a coin that always lands
the same way — and with three it would starve the third outright. The policy is
one line and it is stated rather than emergent. **It is also currently
untestable**: with exactly two processes the two policies produce identical
schedules, a mutation replacing one with the other passes the whole harness, and
`proc run` takes exactly two LBAs so a third process cannot be created from the
shell at all. GAP-0101 records that.

`m11-proc/run.sh` asserts the absence of preemption directly rather than
describing it: for every session in the capture, **the number of switches must
equal the number of `yield` lines plus the number of exits that had a
survivor.** If a timer ever started switching processes, that arithmetic would
stop working, and nothing else in the harness would notice.

---

## 7. How this is verified, and the four mutations that were NOT caught

Eleven structural checks, four QEMU boots, and — because M10's most valuable
finding was a check that passed for the wrong reason — **twelve mutations built
and run in a sandbox mirror, each with `--regen` so that a wrong golden could
not hide a wrong kernel.**

**Caught, by a check that is not a golden:**

| mutation | what caught it |
|---|---|
| `fx_restore` deleted from `procSwitchTo` | both programs report the *other's* XMM0; both exit statuses differ |
| `fx_save` deleted from `procYield` | the extern manifest (57, not 58) — an incidental catch |
| `fx_save` writing the **incoming** slot (extern preserved) | the derived XMM check — the real catch for the same bug |
| `PML4[0]` pointing at the kernel's PDPT | neither program's message appears |
| `paging_install` removed from `procSwitchTo` | no XMM report lines at all |
| the CPUID guard removed from the CR4 write | the guard count, and CR4 reading `0x420` on boot C |
| the RAX patch removed from `procYield` | both exit statuses, once the programs were taught to check `yield`'s return value (§5) |
| the window page table not freed in `procSpaceFree` | the allocator's free count, 0x7EA2 → 0x7E9E |
| `paging_install` removed from `procCreate` (load into the kernel's space) | neither program's message appears |

**NOT caught, and each is a hole in the TEST rather than in the kernel:**

1. **`vmZeroFrame` deleted for all three table frames in `procSpaceBuild`.**
   The whole harness passes. This is GAP-0094 again, for a second subsystem: a
   freshly-booted QEMU hands out RAM that is already zero, and nothing dirties a
   frame before the allocator gives it out. GAP-0102.
2. **Round-robin replaced by lowest-first in `procPickNext`.** Identical with two
   processes; three cannot be created. GAP-0101.
3. **The `PD[128]` clear removed from `procSpaceBuild`.** `shellProcRun` already
   refuses to start while an M10 `run` program is live, so the kernel's
   `PD[128]` is always zero when the copy happens. It is a second lock on a door
   the first lock holds shut. GAP-0100.
4. **The exact failure mode of an unguarded CR4 write.** Caught, but by the
   *wrong assertion*: QEMU does not fault where real hardware would. GAP-0099.

The behavioural checks are not vacuous in general — nine of twelve mutations
died on a derived check with the golden regenerated underneath them. What they
cannot see is the difference between "the kernel zeroed it" and "it was already
zero", and the difference between two scheduling policies that cannot be told
apart at this scale.

**What is read out of hardware rather than out of the kernel's own report:**
both processes' page tables, walked from two different PML4 frames in one
256KiB dump of guest RAM taken while both processes are alive and the CPU is at
CPL 3 inside the second one; A's private pages absent from B's; every virtual
address both map backed by a *different physical frame*; the kernel the *same*
frame in both and supervisor-only in both; and A's suspended XMM0 and XMM7 read
out of its 512-byte FXSAVE area holding its own signature in all four lanes
while B's area does not.

---

## 8. `DCDART_PIN.txt` did not move

M11 needed nothing from DCDart that M10 did not have. A process table is
arithmetic and memory; a context switch is twenty-two loads and twenty-two
stores; an address space is three frames and a copy loop. The five new externs
are two instructions DCDart cannot emit, two control-register reads, and one
storage seam — the same shape as every milestone since M7.

Verified against an isolated clone of DCDart at `e3cfe18` with this repo
rsync'd beside it, per GAP-0084 (`DCDART_HOME` alone does not isolate the
toolchain, because `kmain.dart` reaches the prelude by a hardcoded relative
path).

The shared checkout was four commits ahead of the pin throughout, and that raised
a question worth answering rather than assuming: **do those four commits move a
golden?** They do not. This repo's sources — both at `439a126` and at M11 —
build to a byte-identical `.text` and `.rodata` under `e3cfe18` and under
`70509df`. The intervening work changes what the language accepts, not what the
code generator emits for what this kernel already writes.

That question was asked because a golden mismatch in the pinned sandbox looked
like toolchain drift for about twenty minutes, and was not: it was an edit made
to `proc.dart` *after* the goldens were regenerated. GAP-0078's rule —
**regenerate the address-bearing goldens LAST, after the final line of kernel
source** — is the actual lesson, and it is cheap to get wrong because the
symptom (four goldens off by a constant) looks identical either way. The
distinguishing test is two builds of the same tree against two toolchains, and
it takes ninety seconds.

GAP-0104 lists the three DCDart features that would close gaps here and were not
adopted.

---

## 9. Rejected alternatives

**A kernel stack per process.** The classic design, and unnecessary here: only
one process is ever inside the kernel at a time, because the only way in is a
syscall and the only way out of a syscall is back to ring 3. One RSP0 in the
TSS, reloaded by the CPU on every entry, is enough. This becomes wrong the day
switching becomes preemptive, and GAP-0097 says so by name rather than leaving
it to be discovered.

**Lazy FPU switching via `CR0.TS`.** §2.

**Three symbols in `kdata.S` instead of one.** The storage seam's whole value is
that the number of places knowing where this memory came from is a number a
harness can count. Three symbols would be three accessors and three call sites
to audit on the day DCDart grows mutable statics; one symbol is three *offsets*
behind three named functions, and the harness counts exactly three
`return proc_store_addr()` in `proc.dart` and zero anywhere else in the kernel.

**A `fork` syscall.** There is no filesystem, no `exec`, no copy-on-write and no
`wait`. `fork` without `exec` is a way to make two copies of one program, which
is the one thing this milestone did not need: it needed two *different*
programs, and `proc run <a> <b>` loads two.

**Compiling one test program twice with `-DPROG=A/B`.** "Two different programs
ran" is a claim about two binaries; a preprocessor flag makes it a claim about
one. `progA.c` and `progB.c` are separate sources that differ in message, XMM
signature, `.data`, `.rodata`, size, page count and behaviour.

---

## 10. What this closes, and what it does not

**Closes GAP-0092.** CR4.OSFXSR and OSXMMEXCPT are set behind a CPUID probe,
`CR0.EM` is clear, `fninit` has run, and there is a 16-byte-aligned 512-byte
FXSAVE area per process, saved and restored across every switch this kernel
performs. Programs are now built **without** `-mgeneral-regs-only` and the
harness asserts the compiler emitted `%xmm` into a function containing no inline
assembly.

**Narrows GAP-0089.** Item 1 (one PML4, and it is the kernel's) and item 2 (a
second CR3 was deliberately not built) are done. Item 5 — nothing accounts for a
program's memory as belonging to it — is *partly* done: a process's frames are
now recorded in its slot and recovered from its own page table at teardown, and
`PROC KILL SLOT n FREED n` says how many came back. `frames` still cannot say
who has what.

**Does not close item 3.** No preemption, no `fork`, no `exec`, no `wait`, no
exit status anyone can collect from another process — the exit code is printed
and kept in the slot for `proc` to show, and that is all. GAP-0097.

**Does not close item 4.** A process that never yields and never exits still
cannot be stopped.

**A fault kills the whole session, not just the faulting process**, and that is
a decision rather than an omission: M4's recovery path abandons every stack
frame between the fault and the shell loop, so `shellProcRun` never runs again
and never gets to clean up. A survivor left READY would be a process nothing can
ever schedule, holding four frames and a page table, for the rest of the boot.
GAP-0098.
