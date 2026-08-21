# ADR-0002: M1 interrupts architecture — asm stubs, DCDart-filled IDT, DCDart-driven

**Status:** IMPLEMENTED AND VERIFIED. `core/tests/conformance/m1-interrupts/run.sh` reports an
unqualified PASS: real `dcc build` → real assembly of `boot.S` and `isr.S` → real link →
structural checks → `verify-freestanding.sh` clean → a real `qemu-system-x86_64 -kernel -m 128M` boot
→ the full 544-byte captured COM1 output matching `expected.txt` byte-for-byte (`cmp`). `m0-boot` and
`mb-info` both still PASS.

**This document was revised after implementation.** Two of its original decisions did not survive
contact with reality and are recorded below as changed, not quietly edited away: the mandatory IST
(§"The red zone") and the asm-arms-after-`kmain`-returns control flow (§"Decision"). A third — the
`M1 PIC` line's meaning — was wrong in `ROADMAP.md` and is corrected there.

## Context

M0 is green: boot → long mode → `kmain()` → COM1. `docs/known-gaps.md` GAP-0001's second item is the
next thing worth doing: "No interrupts. No IDT, no PIC remap, no exception handlers. Any real fault
(page fault, GPF, divide-by-zero) triple-faults the VM with no diagnostic beyond 'it stopped.'"

The obvious blocker is that DCDart has no `@naked`, no `@interrupt`, and no general inline `asm()` (its
own GAP-0019). The claim worth testing is that none of those are actually required, because an
interrupt entry stub can be hand-written assembly that calls a DCDart handler through the plain C ABI
— the same inbound direction `boot.S` → `kmain()` already proves.

**That claim is correct, but it is not the whole constraint set, and the parts it omits changed this
design substantially.** The rest of this ADR is what was found.

## What was actually verified about DCDart's capabilities

All of the following was checked by compiling real code through the real `dcc`, not by reading the
prelude:

**[VERIFIED] The DCDart side of this design compiles today.** A scratch file containing
`idtSetGate`/`idtInstallAll`/`picRemap`/`pitInit`/`isrDispatch` — gate-descriptor bit packing with
`&`/`|`/`<<`/`>>` on `u64`, a `while` loop over 256 vectors, `Pointer<u64>` loads AND stores, and a
`Port.outb` PIC/PIT sequence — built to a clean object file with `dcc build --mode bare` and produced
exactly the five expected symbols. No language feature that does not exist today is needed for any of
it.

**[VERIFIED] `part`/`part of` is the only way to split kernel code across files.** `dcc-lower` lowers
exactly ONE Kernel library per `dcc build` — the one whose `importUri` matches the path on the command
line (`core/dcc-lower/lib/lower.dart`'s `component.libraries.firstWhere(...)`). A `@bare` function in
an imported library is silently dropped: no DC-IR, no symbol, and the only symptom is an undefined
symbol at link time. `part` files are the same library, so they lower normally — confirmed by building
a two-file part/part-of pair and finding both symbols in one `.o`.

**[VERIFIED] A `@bare` call cannot be a statement.** `dcc-lower` has no `ExpressionStatement` case for
a call to a `@bare` function, so `doThing();` is a hard compile error. Only calls in value position
lower. Every helper in `core/kernel/` therefore returns `u64` and every call site is
`final u64 _ = doThing();`. This is cosmetic, but it is pervasive.

**[VERIFIED] DCDart has no width conversion at all** — no widening, no narrowing, at any width.
`core/dc-ir/lib/instructions.dart` says so itself: a source-level `.toU32()` "lowers to an explicit
truncate/extend instruction; that instruction is not yet [implemented]". Consequences for M1: a PIT
divisor cannot be computed and then split into two `u8` port writes, so the divisor must be spelled as
two `u8` literals for one fixed frequency; and a vector number cannot be turned into a printable
character without a branch per value.

## The three real constraints the "just use asm stubs" framing omits

1. **DCDart cannot execute `lidt`, `ltr`, `cli` or `sti`.** `Port.outb`/`Port.inb` (DCDart ADR-0029)
   is the only inline asm DCDart has and it is a fixed, single-purpose shape.
2. **DCDart cannot take the address of an external symbol.** So it cannot name `isr_stubs` in order to
   install it. This is the extern-FFI half of DCDart's GAP-0019.
3. **DCDart has no static or global data.** Not a global variable, not a `.bss` array, nothing. The
   IDT, the IDTR, the TSS, the IST stack, and a timer tick counter are all state that must outlive a
   function call, and none of them can be declared in DCDart.

## Decision — DCDart drives; assembly provides what DCDart cannot express

**This is a revision.** The original design was "asm scaffolds, DCDart fills, **asm arms**":
`boot.S` would call `kmain`, then execute `lidt`/`sti` itself after `kmain` returned, because DCDart
could not call an external symbol. That is no longer necessary. DCDart's `@extern` (ADR-0038, commit
`f0c2497`) landed before this was implemented, so `kmain()` now sequences the entire milestone in one
readable function and **`boot.S` is completely unchanged by M1**.

The cost that revision removed was real and worth naming: the old shape turned `boot.S` from a
one-shot stub into the sequencer of a multi-phase boot protocol, splitting M1's ordering across two
files and requiring `kmain` to be split into phases so a self-test could run between them. None of
that exists now.

What remains in assembly, and why:

1. **`core/boot/isr.S` owns all storage and all privileged instructions.** The IDT (4096 bytes) and
   the tick counter live in `.bss`; the IDTR in `.data`. DCDart has no static or global data of any
   kind, so this is not a preference.
2. **`isr.S` publishes `isr_stub_table`: 256 quadwords, entry N = the address of stub N.** DCDart
   cannot name a code symbol, but it can read a `u64` out of memory. Turning 256 code addresses into
   ordinary data is what lets DCDart install the IDT at all. **[VERIFIED]** the table links as 256
   `R_X86_64_64` relocations against `isr_stubs` with addends `0, 0x10 … 0xff0`, and the harness
   asserts `.rodata` is exactly 2048 bytes.
3. **DCDart calls into `isr.S` through `@extern`** for the nine things it cannot do: read the address
   of the IDT, the stub table and the tick counter; execute `lidt`, `sti`, `cli`, `int3` and `hlt`;
   and read the tick counter through an opaque call.

Extern signatures are **scalars only** (DCDart GAP-0025 — `Pointer<T>` is not permitted yet), which is
exactly why each accessor returns a `u64` *address* that DCDart then wraps in `Pointer<u64>` itself,
rather than passing pointers across the boundary. That limitation cost nothing here.

### The one place a missing volatile guarantee actually bit

`kmain` waits for 100 ticks. The obvious spelling — loop on a `Pointer<u64>` load of the tick counter
— is **wrong and would hang**: DC-IR's `Load` carries no volatile semantics (DCDart GAP-0006), so a
loop reloading one address with nothing opaque in between is one LLVM is entitled to hoist. The wait
would spin on a stale register forever.

The fix is not a workaround for a compiler bug (which rule 3 would forbid) but a correct use of the
call boundary: `tick_count()` is an `@extern` call, and LLVM cannot prove an external call leaves
memory alone, so the value is genuinely re-read every iteration. **[VERIFIED]** by disassembly — the
`call tick_count` sits inside the loop's back edge, not hoisted above it.

## The red zone — found here, fixed upstream, and the mitigation withdrawn

**What was found.** DCDart's backend emitted code using the System V AMD64 128-byte red zone: it wrote
locals below RSP without ever subtracting from RSP. `uartPutc` disassembled to `mov %al,-0x1(%rsp)`
with no stack adjustment anywhere in the function; a five-argument function reached `-0x68(%rsp)`, 104
bytes deep. An interrupt taken without a stack switch pushes a 40-byte frame directly below RSP —
through the interrupted function's live locals. Every DCDart function in the kernel would have been
silently corruptible the moment `sti` executed.

**What was decided then.** Give every IDT gate a non-zero IST index, so the CPU switches to a
dedicated stack before pushing anything. That was described in this document's first revision as
"load-bearing, not hygiene."

**What happened.** The bug was fixed upstream — DCDart ADR-0039, commit `0f5374e`, making
`DCTarget.forbidsRedZone => isFreestanding` so the guarantee is a property of the target rather than a
flag someone must remember, setting both `-mno-red-zone` and the `noredzone` IR attribute.
**[VERIFIED]** here against real kernel output rather than taken on trust: `uartPutc` now opens with
`sub $0x2,%rsp`, and there is not one negative-`%rsp` access anywhere in `kmain.o`.

**So the IST was withdrawn, deliberately, and every gate now uses IST index 0.** The reasoning, stated
in full because reversing a decision deserves at least as much argument as making it:

- The justification that made it mandatory is gone. Keeping a mitigation whose stated reason has
  evaporated is exactly the "route around a compiler bug in the OS" that CLAUDE.md rule 3 forbids.
- Its remaining merits are real but untested here: surviving a double fault taken on an exhausted or
  corrupt stack, and NMI. M1 exercises none of them — every interrupt it takes is delivered while the
  healthy 16KiB boot stack is current.
- Keeping it meant carrying a TSS, a long-mode TSS descriptor with runtime bit-field patching, `ltr`,
  and an edit to `boot.S`'s currently-green GDT to reserve two spare quadwords — roughly 60 lines of
  assembly that **no test would ever execute**, justified by a scenario this milestone does not
  create. That is speculative building.

**What would bring it back:** the milestone that adds a real double-fault test and can prove the IST
works. At that point it earns its place on its own merits, with its own IST slot for `#DF`
specifically, which is the configuration that actually matters. Recorded in `docs/known-gaps.md`
GAP-0007.

**Kept even so:** the harness asserts on every run that `kmain.o` contains zero negative-`%rsp`
accesses. The red zone regressing would be silent data corruption rather than a crash, and this kernel
is the thing that gets corrupted — so it checks rather than trusting the toolchain to keep its
promise.

## IDT/IDTR layout

A 64-bit interrupt gate is 16 bytes:

| bytes | field | value used here |
|---|---|---|
| 0–1 | offset 15:0 | stub address low half |
| 2–3 | segment selector | `0x08` — `boot.S`'s `gdt64_code` |
| 4 | IST index (bits 0–2) | `0` — no stack switch; see the red-zone section for why this changed from `1` |
| 5 | type/attributes | `0x8E` — present, DPL 0, 64-bit **interrupt** gate |
| 6–7 | offset 31:16 | |
| 8–11 | offset 63:32 | |
| 12–15 | reserved | zero |

DCDart writes this as two `u64` stores, packing the low quadword as
`(h & 0xFFFF) | (0x08 << 16) | (ist << 32) | (attr << 40) | (((h >> 16) & 0xFFFF) << 48)`.
**[VERIFIED]** by execution — 256 gates built this way, and the CPU delivers through them.

**Interrupt gates, not trap gates** (`0x8E`, not `0x8F`): an interrupt gate clears IF on entry, so a
handler is not reentered by the next tick while it is running. With no way to write a critical section
in DCDart (see above), non-reentrancy is the only thing making the tick counter safe to touch, so this
is not a default — it is the mechanism.

IDTR is fully static: `.word 4095` (256 × 16 − 1) then `.quad idt`. Both are link-time constants, so
unlike the TSS descriptor it needs no runtime patching.

There is no TSS and no GDT change at all — see the red-zone section. `boot.S`'s GDT is untouched by
M1.

## PIC remapping

**Remap the legacy 8259 pair to vectors 0x20–0x2F.** Not optional and not a style choice: at power-on
the master PIC delivers IRQ0–7 to vectors 0x08–0x0F, which in long mode collide with CPU exception
vectors 8–15 — double fault, invalid TSS, segment-not-present, stack fault, **general protection**,
**page fault**. Without the remap a keyboard IRQ is indistinguishable from a page fault, and the
handler that most needs to be trustworthy is the one that gets corrupted.

Standard ICW1–ICW4 sequence via `Port.outb`, entirely expressible today. Masks are set so only IRQ0
(the PIT) is unmasked; the slave is fully masked.

**A correction made during implementation.** `ROADMAP.md`'s draft exit criterion said the `M1 PIC 20`
line would be the master's vector base "read back and printed, proving the remap took." That is not
possible: an 8259's ICW2 is **write-only**, so there is nothing to read back, and printing the
constant this kernel just sent would have proved only that it can print a constant. What *is*
observable is where the interrupt actually lands, so the line is now printed **by the first timer
interrupt, reporting the vector it was delivered on**. `20` means IRQ0 arrived on 0x20 rather than the
power-on default 0x08. That reorders the golden output (`M1 PIC` now follows `M1 EXC 03`) and is a
genuine strengthening: it is evidence from the hardware instead of an echo.

**Rejected: the APIC.** The local APIC and I/O APIC are the right long-term answer and the 8259 is
legacy. But the APIC needs MMIO at `0xFEE00000`, MSR access (`IA32_APIC_BASE`), and ACPI/MP-table
parsing to find the I/O APIC — MSR reads/writes have no DCDart primitive and no asm escape hatch here,
and ACPI parsing is a milestone of its own. The 8259 needs nothing but `outb`, which already exists
and is already verified. Deferred deliberately, recorded in `docs/known-gaps.md`.

## What stays assembly, and why (CLAUDE.md rule 4)

| Thing | Where | Why not DCDart |
|---|---|---|
| 256 entry stubs, `iretq` | `isr.S` | no `@naked`; must not have a compiler prologue; must return with `iretq` |
| register save/restore frame | `isr.S` | DCDart cannot read or write a register |
| `lidt` / `ltr` / `cli` / `sti` | `isr.S` | privileged instructions, no DCDart primitive, no general `asm()` |
| IDT / TSS / IST stack / tick counter storage | `isr.S` `.bss` | DCDart has no static or global data of any kind |
| `isr_stub_table` | `isr.S` `.rodata` | DCDart cannot take the address of a code symbol |
| gate descriptor packing | **DCDart** | pure bit manipulation on `u64` — verified expressible |
| PIC remap, PIT programming | **DCDart** | pure `Port.outb` — verified expressible |
| exception/IRQ handler bodies | **DCDart** | ordinary code reachable by C-ABI call |

The split is not "asm where convenient." Every row in the top half is something DCDart genuinely
cannot express today; every row in the bottom half is something it can, and therefore does.

## What is blocked on DCDart, and what is not

**Not blocked. M1 is built and passing.** Every DCDart capability this needed exists.

The original version of this section predicted M1 would be buildable without extern FFI, and it would
have been — but three of the costs it listed were paid off by `@extern` landing first:

| Predicted cost | Actual outcome |
|---|---|
| `boot.S` becomes a multi-phase boot sequencer | **Avoided.** `boot.S` is unchanged by M1; `kmain` sequences everything. |
| No runtime interrupt control from DCDart | **Resolved.** `cli`/`sti` are `@extern` calls; `kmain` masks the PIC and clears IF before the deliberate fault. |
| `kmain`'s signature grows to four arguments | **Avoided.** Still one argument (`mbInfo`). Addresses come from `@extern` accessors instead. |

Still real, and now precisely bounded:

- **`Pointer<T>` in an extern signature** (DCDart GAP-0025): scalars only. Cost here: nil — accessors
  return a `u64` address that DCDart wraps itself. It would matter for a richer asm/DCDart interface.
- **`@volatile` loads/stores** (DCDart GAP-0006): the tick wait would be miscompiled by a plain load.
  Routed around correctly via an opaque `@extern` read, not by a trick — see the Decision section.
- **No static data in DCDart**: every byte of kernel state still lives in assembly `.bss`. This does
  not scale past a handful of subsystems and is the next structural limit this kernel will hit.
- **No function pointers or dynamic dispatch**: `isrDispatch` classifies with a branch chain on the
  vector. Fine for three interesting vectors; wrong shape for thirty.
- **One library per object file** (GAP-0004 item 4): still true, so `core/kernel/` remains one library
  split into `part` files. No longer *silent*, though — `dcc` now rejects it by name and points at
  `part`/`part of`.

## Consequences

- **A fault is now diagnosable.** `docs/known-gaps.md` GAP-0001's second item said any real fault
  "triple-faults the VM with no diagnostic beyond 'it stopped.'" `M1 FAULT 06 0000000000000000` is
  that diagnostic, produced by a real `#UD` from DCDart's own overflow-trap `ud2`, with the kernel
  still alive to print it. That was the milestone's point and it is done.
- **`boot.S` is untouched by M1.** The long-mode transition remains the only thing it does.
- Every gate is an interrupt gate with IST 0, uniformly — no vector gets special treatment, including
  double fault. Deliberate, recorded in GAP-0007.
- The whole kernel is still one DCDart library and one object file. `core/kernel/` is now four `part`
  files (`kmain`, `uart`, `multiboot`, `interrupts`), which is at the edge of what one namespace
  comfortably holds.
- Two `@extern` helpers exist but are not needed by M1's own flow and are called anyway because the
  flow reads better with them: `debug_break()` is the self-test, `halt_forever()` ends it. Neither is
  dead code.
