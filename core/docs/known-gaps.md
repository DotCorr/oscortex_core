# Known gaps

Work queue, not a confession log (same discipline as the DCDart repo's `CLAUDE.md`). Every entry: what
was worked around, and the cost.

---

## GAP-0001 — M0's four missing pieces: three are now built, one is not

**Domain:** boot, kernel (M0)
**Status:** PARTIALLY RESOLVED — memory map RESOLVED, real UART driver RESOLVED
(`docs/decisions/0003-uart-driver-and-multiboot-info.md`, verified by
`tests/conformance/mb-info/run.sh`), interrupts RESOLVED
(`docs/decisions/0002-m1-interrupts-architecture.md`, verified by
`tests/conformance/m1-interrupts/run.sh`). Only the real bootloader remains OPEN.

M0's exit criterion (`docs/decisions/0001-m0-boot-architecture.md`) is deliberately narrow: boot, prove
alive over serial, nothing else. Status of what was missing:

- ~~**No memory map.**~~ **RESOLVED.** `boot.S` now stashes EBX at `_start` and passes it to
  `kmain()` as a plain C-ABI argument; `core/kernel/multiboot.dart` parses the Multiboot1 information
  structure and reports flags, `mem_lower`, `mem_upper`, and every memory-map entry over COM1.
  `tests/conformance/mb-info/run.sh` asserts the whole 433-byte capture byte-for-byte, and every
  reported figure was cross-checked independently against `-m 128M` (see ADR-0003's verification
  table), not merely recorded.

  **What is still missing here, precisely:** the map is READ and REPORTED, not RETAINED. There is
  nowhere to put it — DCDart has no static or global data of any kind and this kernel has no
  allocator, so nothing can outlive the `mbReport` call. A real physical memory manager needs the
  static-storage gap (GAP-0004) closed first, or needs asm to donate the storage the way M1's design
  donates the IDT.

- ~~**No interrupts.**~~ **RESOLVED.** M1 is done: a 256-gate IDT built by DCDart from a stub-address
  table, the 8259 pair remapped to 0x20–0x2F, a 100 Hz PIT with a working end-of-interrupt path, and
  exception handlers with real diagnostics. `tests/conformance/m1-interrupts/run.sh` asserts the whole
  544-byte capture byte-for-byte.

  The specific complaint this entry made — "any real fault triple-faults the VM with no diagnostic
  beyond 'it stopped'" — is closed by evidence, not by assertion: the kernel deliberately overflows a
  `u64`, DCDart's own overflow-trap codegen turns that into a `ud2` (#UD, vector 6), and the handler
  prints `M1 FAULT 06 0000000000000000` and halts cleanly. The harness fails if that line is missing.

  **Still true:** there is no `timeout`-free shutdown path. `isa-debug-exit` or ACPI shutdown remains
  unbuilt, so every harness still ends by letting `timeout` kill QEMU.

- ~~**No busy-wait on the UART's Transmit-Holding-Register-Empty bit.**~~ **RESOLVED.**
  `core/kernel/uart.dart` is a real, reusable 16550 driver and `uartPutc` polls LSR bit 5 before every
  write, verified structurally by disassembly (a real `in`/`and`/`cmp`/`jae` back edge). The blocker
  this entry recorded — "a comparison operator on `u8`, which DCDart doesn't have yet" — is gone:
  DCDart's ADR-0035 added `<`/`<=`/`>`/`>=`/`+`/`-`/`*`/`~/`/`%` at all four widths. Confirmed by
  compiling the real loop, not by reading the prelude. **That DCDart work is uncommitted — see
  GAP-0005.**

  **What is still fragile, stated plainly:** the busy-wait has no timeout. If COM1 is absent or
  wedged, THRE never sets and `uartPutc` spins forever with interrupts disabled — hanging the machine
  silently rather than failing loudly. A bounded spin is expressible today; "give up and do what?" is
  not answerable yet (no second output device, no panic path, no way to signal failure to the
  harness). Left unbounded deliberately rather than bounded-and-silently-lossy.

  ~~Also still true: `@bare` has no String or array type, so every literal message is one
  `Port.outb` call per character.~~ **RESOLVED for fixed messages** — they are `@rodata` byte tables
  now (`docs/decisions/0004-rodata-message-tables.md`). See GAP-0004 item 6 for exactly what that does
  and does not cover.

- **No real bootloader.** Still true. QEMU's built-in Multiboot loader (`-kernel`) is the only tested
  boot path. BIOS MBR / UEFI boot on real hardware is unbuilt and unverified.

**Cost of the workaround:** none of this was worked around — the two resolved items were real work,
and the two open ones are real, un-started work correctly scoped out of M0.

---

## GAP-0002 — DCDart-side primitives this kernel needs but doesn't have yet

**Domain:** kernel (blocked on DCDart repo changes, not this repo's to fix directly)
**Status:** LARGELY RESOLVED — bitwise operators (DCDart ADR-0030), the complete integer operator set
including `u8 operator <` (ADR-0035), explicit width conversions (ADR-0037), extern FFI (ADR-0038) and
no-red-zone on freestanding targets (ADR-0039) have all landed and are all in use here. `@naked`,
general inline `asm()`, and `@interrupt` enforcement remain unstarted — and M1 shipping without them
is the evidence that the first two were never actually required. Tracked here so it's visible from
the kernel side; the actual work happens in the DCDart repo's own `docs/known-gaps.md`/`docs/decisions/`.

- **Bitwise operators** (`&`, `|`, `^`, `<<`, `>>`) — available on `u8`/`u16`/`u32`/`u64` (DCDart
  ADR-0030) and now genuinely USED: `core/kernel/uart.dart`'s LSR mask and nibble split, and
  `core/kernel/multiboot.dart`'s field masking. M1's IDT gate-descriptor packing is the bigger payoff
  and has been proven to compile (ADR-0002).

- **Comparison operators on `u8`** — available (DCDart ADR-0035) and used for the LSR busy-wait. This
  entry previously said this was the thing blocking real UART polling. It no longer is.

- **Extern FFI** — **RESOLVED** (DCDart ADR-0038) and load-bearing here: `core/kernel/interrupts.dart`
  declares nine `@extern external` functions implemented in `core/boot/isr.S`, and `dcc` records them
  in `kmain.o.externs` so `verify-freestanding.sh` permits exactly those and still hard-fails anything
  else. Two costs this entry predicted were paid off rather than paid: `boot.S` did NOT have to become
  a multi-phase boot sequencer, and DCDart DOES have runtime interrupt control (`kmain` masks the PIC
  and clears IF before the deliberate fault).

  Remaining limit: **extern signatures are scalars only** — `Pointer<T>` is not permitted (DCDart
  GAP-0025). Cost here: nil. Every accessor returns a `u64` address that DCDart wraps in
  `Pointer<u64>` itself. It would matter for a richer asm/DCDart interface.

- **`@naked` and `@interrupt` were never actually prerequisites.** This entry used to imply they were.
  M1 shipped without either. An ISR entry stub is hand-written assembly that calls a DCDart handler
  through the plain C ABI — the same inbound direction `boot.S` → `kmain()` had already proved. What
  was genuinely missing was the ability to execute privileged instructions, name an external symbol,
  and declare static data; the first two are now solved by `@extern`.

- **General inline `asm()`** — still missing, and still not needed. Every privileged instruction M1
  uses (`lidt`, `cli`, `sti`, `int3`, `hlt`) lives in `isr.S` behind a C-ABI function. That is a
  better boundary than inline asm would have been, not a worse one.

- **`@interrupt` safety enforcement** (no allocation inside an interrupt handler, compiler-enforced)
  — mentioned in DCDart's `CLAUDE.md` coding rules as a real requirement, still not implemented.
  **Cost:** nothing enforces it. `isrDispatch` and everything it calls are allocation-free by
  inspection only. This is now a REAL exposure rather than a theoretical one, because there is a real
  interrupt handler for the first time.

- **Static READ-ONLY data now exists** (DCDart ADR-0040) and is used for every fixed message
  (`docs/decisions/0004-rodata-message-tables.md`). **Mutable** static data does not, and that is the
  half this kernel still needs.

  **Extern audit, checked rather than assumed** (all nine remain necessary — zero eliminated):

  | Extern | Why `@rodata` does not replace it |
  |---|---|
  | `isr_stub_table_addr` | Its contents are the addresses of 256 **assembly** symbols. `Ref('name')` resolves only against `@rodata` tables **in the same compilation unit** — verified by a real error: *"`isr_stubs` is not a `@rodata` table in this compilation unit. Cross-object references would need address-of-extern, which does not exist."* This table is categorically read-only data, and is still unreachable. |
  | `idt_base`, `tick_counter_addr` | Point at **mutable** `.bss` written at runtime. Read-only data cannot hold either. |
  | `tick_count` | Not a data accessor at all — it is an **opaque call acting as a volatile barrier** (GAP-0006). Replacing it with a data read would reintroduce the hoisting hang. |
  | `idt_load`, `interrupts_enable`, `interrupts_disable`, `debug_break`, `halt_forever` | Privileged or control-flow instructions. These stay in assembly permanently. |

  DCDart's own ADR-0040 says "of `oscortex_core`'s nine externs, exactly one falls to read-only data."
  That is true by **category** — the stub table is read-only data by nature — but not achievable
  today, because building it in DCDart needs address-of-extern. Worth stating precisely so the number
  is not read as "one extern can be deleted now."

- **No MUTABLE static data in DCDart** — unchanged and now the sharpest structural limit. Every byte of kernel
  state (the IDT, the tick counter) lives in `isr.S`'s `.bss` and is reached through an `@extern`
  accessor. That works for two objects; it does not scale to a dozen subsystems, and it is why the
  memory map GAP-0001 now reads can be reported but not retained.

- **No function pointers or dynamic dispatch** — `isrDispatch` classifies with a branch chain on the
  vector number because a dispatch table is not expressible. Fine for three interesting vectors, wrong
  shape for thirty.

**Cost of the workaround:** page-table/GDT setup stays hand-written assembly in `boot.S`. `boot.S`
itself is UNCHANGED by M1 — the predicted growth into a boot sequencer did not happen, because
`@extern` landed first and `kmain()` sequences the milestone instead.

---

## GAP-0003 — Import path from kernel.dart to DCDart's prelude assumes a fixed sibling checkout

**Domain:** kernel, build tooling
**Status:** OPEN — same limitation DCDart's own `dcc/README.md` already accepts for itself.

`core/kernel/kmain.dart` imports DCDart's prelude via a literal relative path
(`../../../DCDart/core/runtime/dc-core-bare/prelude.dart`), which only resolves correctly if
oscortex_core and DCDart are checked out as siblings at the expected depth. `DCDART_HOME` (used by
`core/scripts/build-kernel.sh` to locate `dcc` itself) does NOT control this — Dart's own import
resolution is independent of how the build script finds the compiler binary. A real fix needs either a
proper package/library resolver (the same gap DCDart's own `dcc` has for its own prelude — see that
repo's `core/dcc/README.md` "known simplification") or an explicit override mechanism neither project
has built yet.

**Cost of the workaround:** the checkout layout is undocumented-enforced, not tooling-enforced — a
different layout silently breaks the import with a front_end error, not a clear "wrong layout" message.

---

## GAP-0004 — Five DCDart-side needs this kernel's real code surfaced

**Domain:** kernel (blocked on DCDart repo changes — file and build them THERE, per `AGENTS.md`'s
"Where DCDart-side work belongs" and `CLAUDE.md` rule 3)
**Status:** FOUR OF FIVE RESOLVED and in use here; one open. Every one was found by compiling real
kernel code through the real `dcc`, not by reading the prelude — and every fix was verified from this
repo against real kernel output before being called resolved, not accepted on the strength of an
upstream ADR header.

| # | Need | Status |
|---|---|---|
| 1 | `-mno-red-zone` | **RESOLVED** — DCDart ADR-0039 |
| 2 | width conversion | **RESOLVED** — DCDart ADR-0037 |
| 3 | `@bare` call as a statement | **RESOLVED for void**, open for value-returning |
| 4 | one library per object file | **Silence RESOLVED**, multi-library compilation still OPEN |
| 5 | `Load`/`Store` alignment | **OPEN** — no longer costing this repo anything |
| 6 | no String/array type for literal messages | **RESOLVED for compile-time-fixed text** — DCDart ADR-0040; runtime strings still absent |

### 1. `-mno-red-zone` — RESOLVED (DCDart ADR-0039, commit `0f5374e`)

**This was the most important one.** DCDart's backend emitted code that used the System V AMD64
128-byte **red zone** — it wrote locals below RSP without ever subtracting from RSP.

*Evidence, by disassembly of real output:* `core/kernel/uart.dart`'s `uartPutc` compiles to
`mov %al,-0x1(%rsp)` with no stack adjustment anywhere in the function; a five-argument function
(M1's staged `idtSetGate`) reaches `-0x68(%rsp)`, 104 bytes deep.

*Cause, located precisely:* DCDart's `core/backend/lib/compile.dart` builds its clang command line
with `-ffreestanding -fno-builtin -fno-stack-protector -fno-exceptions -fno-unwind-tables
-fno-asynchronous-unwind-tables` and **no `-mno-red-zone`**; `core/backend/lib/llvm_emit.dart` emits
`attributes #0 = { nounwind }` with no `noredzone`.

*Why it matters:* an interrupt taken without a stack switch pushes a 40-byte frame directly below RSP,
through the interrupted function's live locals. Every DCDart function in a kernel becomes silently
corruptible the instant `sti` executes. Not a hazard that might materialize — a certainty on the first
timer tick, presenting as impossible-looking data corruption rather than a crash.

*How it was fixed:* `DCTarget.forbidsRedZone => isFreestanding`, setting both clang's
`-mno-red-zone` and the `noredzone` IR attribute — a property of the target rather than a flag anyone
has to remember.

*Verified from here, not assumed:* `uartPutc` now opens with `sub $0x2,%rsp` where it used to write
`-0x2(%rsp)` with no adjustment, and there is not one negative-`%rsp` access anywhere in `kmain.o`.
`tests/conformance/m1-interrupts/run.sh` asserts that count is zero **on every run** — a regression
would be silent data corruption rather than a crash, and this kernel is the thing that gets corrupted,
so it checks rather than trusting the toolchain to keep its promise.

*The mitigation was withdrawn.* M1's design briefly made a non-zero IST index mandatory on all 256
gates purely to dodge this bug. With the bug fixed that justification evaporated, and keeping it would
have been exactly the "route around a compiler bug in the OS" CLAUDE.md rule 3 forbids. See ADR-0002's
red-zone section for the full reasoning and what would bring an IST back on its own merits.

### 2. Width conversion between sized integers — RESOLVED (DCDart ADR-0037)

`.toU8()`/`.toU16()`/`.toU32()`/`.toU64()` now exist at all four widths, and named `const int`s are
accepted where a literal used to be demanded. **Both are in use here**, and both deleted real
workarounds rather than merely being available:

- `core/kernel/multiboot.dart` no longer reads 32-bit fields as masked 8-byte loads. Each is an
  ordinary `Pointer<u32>` load widened with `.toU64()`. That removed the three runtime **8-byte**
  alignment guards that existed only to make the masked load well-defined; the file still guards
  alignment, but now checks the **4-byte** alignment Multiboot1 actually guarantees rather than
  covering for a missing primitive.
- `core/kernel/uart.dart` gained `uartPutHex(value, digits)`, which formats a `u64` held in a
  register. Previously every number printed had to be read back out of memory a byte at a time,
  because a nibble extracted from a `u64` could not become the `u8` that `Port.outb` requires. M1's
  `M1 IDT 0100`, `M1 PIC 20` and `M1 TICKS ...` lines are all computed values and could not have been
  printed at all without this.
- `core/kernel/interrupts.dart` uses named `const int` port numbers instead of bare literals.

*What the gap used to say:* no widening, no narrowing, at any width. DCDart's own `core/dc-ir/lib/instructions.dart` says so: a
source-level `.toU32()` "lowers to an explicit truncate/extend instruction; that instruction is not yet
[implemented]". `dcc-lower` additionally rejects `u8(someRuntimeExpression)` outright — sized-int
constructors accept integer **literals** only.

*Exactly what is needed:* explicit conversions, e.g. `u64 u8.toU64()` / `u8 u64.toU8()` (or a
`widen`/`truncate` spelling), lowering to LLVM `zext`/`trunc`. Explicit, never implicit — DCDART_SPEC
§4.1 already says "no implicit widening or narrowing", so this is completing a stated design, not
changing one.

*Why the kernel needs it, concretely:*
- A `u32` read out of the Multiboot structure cannot become a `Pointer` address, a loop bound, or a
  stride. Worked around by loading **8** bytes at an 8-aligned address and masking — which then needs
  three runtime alignment guards that a real widening would delete outright (ADR-0003 Decision 5).
- A nibble extracted from a `u64` cannot become the `u8` that `Port.outb` requires, so every number
  printed has to be read back out of memory a byte at a time rather than computed (ADR-0003
  Decision 4).
- M1's PIT divisor cannot be computed and split into two `u8` port writes; it must be spelled as two
  `u8` literals for one hard-coded frequency.

### 3. A `@bare` call cannot be an expression statement

`dcc-lower` has no `ExpressionStatement` case for a call to a `@bare` function. `doThing();` is a hard
compile error: *"unsupported expression statement StaticInvocation … M1 only understands
`pointer.value = x;` … and `Port.outb(port, value);`"*. Only calls in **value** position lower.

*Exactly what is needed:* an `ExpressionStatement` case in `_lowerStatement` that lowers a `@bare`
`StaticInvocation` and discards its result — the same `Call` instruction already emitted in value
position, with no destination consumed.

*Cost here:* every function in `core/kernel/` returns `u64` whether or not it has a result, and every
call site reads `final u64 _ = doThing();`. Pervasive noise on almost every line. Deliberately not
hidden behind a wrapper, because hiding it would hide a real language gap.

### 4. Only one library is compiled per object file — the SILENCE is fixed, the limit is not

`dcc-lower` lowers exactly the library whose `importUri` matches the source path on the command line
(`core/dcc-lower/lib/lower.dart`'s `component.libraries.firstWhere(...)`). A `@bare` function in an
IMPORTED DCDart library is silently dropped: no DC-IR, no symbol, and the only symptom is an undefined
symbol at link time.

**The silent half is fixed** (DCDart GAP-0026 work, commit `a5f5d5e`). Re-verified here rather than
assumed: an `import` of a library containing `@bare` functions is now a hard error that names each
dropped function and points at `part`/`part of`. That was the dangerous part — a build that silently
omitted code and failed later at link time with an unrelated-looking undefined symbol.

**The limit itself is unchanged:** still one library per object file, so `core/kernel/` remains one
library split into four `part` files (`kmain`, `uart`, `multiboot`, `interrupts`).

*Cost here:* the kernel cannot have a module with private internals, and every symbol shares one
namespace. Four `part` files is already at the edge of what that comfortably holds. Multi-library
compilation plus multi-object linking is what actually closes this.

### 5. `Load`/`Store` carry no alignment attribute — OPEN, but no longer costing this repo anything

`llvm_emit.dart` emits a bare `load i64, ptr %v`, so LLVM assumes ABI alignment (8 for `i64`). A
kernel reading loader-supplied structures cannot promise that: Multiboot1 guarantees only 4-byte
alignment for its information structure.

*Exactly what is needed:* an alignment field on DC-IR's `Load`/`Store`, printed as `, align N`.

*Cost here: none any more.* `.toU64()` (item 2) removed every 8-byte load from
`core/kernel/multiboot.dart`, so nothing in this kernel now performs a load whose alignment it cannot
guarantee. The alignment guards that remain check Multiboot1's own 4-byte promise, which the natural
`Pointer<u32>` load needs anyway.

**Those guard branches are still compiled and never exercised** — under QEMU every address is
correctly aligned — which is stated rather than glossed. The gap stays open because the next thing to
parse a caller-supplied structure will want it.

### 6. No String or array type, so a literal message was one call per character — RESOLVED for fixed text

**What is resolved.** `@rodata final List<u8> t = const [...]` plus `Rodata.addressOf(t)` (DCDart
ADR-0040) makes a fixed message a real byte table. `core/kernel/uart.dart` gained `uartWrite(base,
len)`, and all 16 fixed messages across `uart.dart`, `multiboot.dart` and `interrupts.dart` are now
tables. `mbPrefix()`/`m1Prefix()` are gone. This was the single largest ergonomic gap in writing
kernel code in this language.

Verified as a pure refactor: all three harnesses pass with **unchanged golden files**, byte-for-byte.

**What is NOT resolved, precisely.** Everything above is **compile-time-constant** text. There is
still:

- **no `Str`/`String` type** — nothing that carries a pointer and a length together, so every call
  site passes a hand-written byte count next to the table;
- **no array type** — `List<u8>` here is a `@rodata` declaration form, not a value. It cannot be
  passed to a function, indexed with bounds checking, sliced, or held in a local;
- **no runtime string construction of any kind** — no concatenation, no formatting, no building a
  message from parts. Anything assembled at runtime needs a real string type *and* an allocator, and
  neither exists. This kernel's number formatting is still a hand-rolled hex loop for exactly that
  reason;
- **no mutable static storage**, so a string cannot be modified after it is built even if it could be
  built.

The practical boundary: a message known when the kernel is compiled is now easy; a message that
depends on anything the kernel learns at runtime is still one hand-written character loop.

---

## GAP-0005 — RESOLVED: the DCDart dependency is committed again, and `DCDART_PIN.txt` is truthful

**Domain:** build tooling, cross-repo dependency
**Status:** RESOLVED 2026-08-20.

This entry recorded that the kernel depended on DCDart work that existed only as uncommitted working-
tree changes, so no commit hash described what it had been verified against, and `DCDART_PIN.txt` was
annotated as not truthful rather than bumped to a hash that would have implied a verification that did
not happen.

That is fixed. DCDart's working tree is clean and everything this kernel needs is committed.
`DCDART_PIN.txt` is back to its one-line form:

```
531cb892c2cd407e228017f2f0bd523d2b60c0e7 2026-08-20
```

**Checked, not assumed, and the check mattered.** The pin was going to be set to `0f5374e` (ADR-0039,
the red-zone fix — the commit this kernel most obviously depends on). `git rev-parse HEAD` says the
DCDart tree actually in use is `531cb89`, two commits further on: `a5f5d5e` (imported `@bare`
functions became a hard error) and `531cb89` (a known-gaps edit). `0f5374e` is an ancestor of HEAD,
so pinning it would have been *plausible* and still wrong — this kernel was built and verified against
`531cb89`, and one of those two extra commits changes a compiler diagnostic this repo's own docs now
describe. `git status --porcelain` empty is what makes the pin mean anything; without that, the hash
alone would say nothing about what was on disk.

**Cost of the workaround:** none remaining. `core/README.md`'s dependency story ("`DCDART_PIN.txt` is
the entire dependency story for now") is accurate again.

---

## GAP-0006 — RESOLVED: M1's assembly is linked, executed, and verified

**Domain:** boot (M1)
**Status:** RESOLVED 2026-08-20.

This entry existed so that staged-but-never-executed assembly could not be mistaken for working
assembly. `core/boot/isr.S` is now assembled by `core/scripts/build-kernel.sh`, linked into
`kernel.elf`, and executed under real QEMU by `core/tests/conformance/m1-interrupts/run.sh`.

Each item this entry listed as "unverified beyond assembles" resolved as follows:

- **`isr_common`'s stack offsets and the 16-byte RSP alignment argument** — verified by execution.
  Wrong offsets would have passed a garbage vector number and the branch chain in `isrDispatch` would
  have fallen through to the fault path, printing `M1 FAULT` for the `int3` instead of `M1 EXC 03`.
- **The long-mode TSS descriptor and `tss_install`'s runtime patching** — **deleted, not verified.**
  The IST it existed for was withdrawn once the DCDart red-zone bug it mitigated was fixed (GAP-0004
  item 1, ADR-0002's red-zone section). It was roughly 60 lines of assembly no test would ever have
  executed.
- **`gdtr_with_tss`, declared and entirely unused** — deleted with it. `boot.S`'s GDT is untouched by
  M1, as originally intended.

**Cost:** none. The entry did its job: nothing was ever reported as working on the strength of having
assembled.

---

## GAP-0007 — M1 simplifications, recorded now so they aren't discovered later

**Domain:** boot, kernel (M1)
**Status:** OPEN, all deliberate, and now all *shipped-with* rather than planned. These are
`ROADMAP.md` M1's stated out-of-scope items, restated with the costs M1 actually pays.

- **Legacy 8259 PIC, not the APIC.** The APIC is the right long-term answer, but it needs MMIO at
  `0xFEE00000`, MSR access (`IA32_APIC_BASE`) which has no DCDart primitive and no asm escape hatch
  here, and ACPI/MP-table parsing to locate the I/O APIC. The 8259 needs only `outb`, which already
  exists and is already verified. **Cost:** no per-CPU interrupt routing, so SMP is blocked on
  redoing this.
- **No IST at all — every gate uses IST index 0, so interrupts run on the interrupted stack.**
  Originally this milestone made a non-zero IST mandatory, to mitigate a DCDart red-zone bug; that bug
  is fixed (GAP-0004 item 1) and the mitigation was withdrawn with its justification rather than kept
  for reasons it never had. **Cost:** a fault taken on an exhausted or corrupt stack — the case an IST
  exists for — cannot be reported, and would escalate to a double fault and then a triple fault. M1
  never creates that case (every interrupt it takes is delivered on the healthy 16KiB boot stack), so
  the cost is real but currently unreachable. The milestone that adds a double-fault test should add
  an IST slot for `#DF` specifically and prove it works, rather than reinstating one everywhere on
  faith.
- **No nested or reentrant handlers.** Gates are interrupt gates (`0x8E`), which clear IF on entry —
  chosen deliberately, since with no way to write a critical section in DCDart, non-reentrancy is the
  only thing making shared handler state safe. **Cost:** interrupt latency is bounded by the slowest
  handler, and a handler that busy-waits on the UART (as the diagnostic path does) blocks every other
  interrupt for the duration.
- **PIT only; no other IRQ, and no interrupt-driven UART receive.** `core/kernel/uart.dart` leaves IER
  at `0x00` on purpose. There is an IDT now, so this is no longer blocked — it is simply not needed
  yet, and `picRemap()` masks every line except IRQ0.

- **No allocation-in-handler enforcement.** `isrDispatch` and everything it calls are allocation-free
  by inspection only; DCDart has no `@interrupt` checking (GAP-0002). This became a real exposure
  rather than a theoretical one the moment a real interrupt handler existed.

- **The tick handler busy-waits on the UART.** `m1ReportPic` runs inside the interrupt handler and
  calls `uartPutc`, which spins on the Line Status Register. Interrupt gates clear IF so nothing is
  re-entered, but the machine is unresponsive for the duration. It fires exactly once (on the first
  tick) which is why it does not measurably distort the 100-tick count, but printing from a handler is
  not a pattern to keep.

---

## GAP-0050 — The kernel image is a single RWX segment: `.rodata` and `.text` are writable at runtime

**Domain:** boot, link (M1, blocking for anything that trusts read-only data)
**Status:** **CLOSED at M8 (2026-08-21)** for the kernel's own image, by
`docs/decisions/0012-paging-and-w-xor-x.md`, verified by
`tests/conformance/m8-paging/run.sh`. The original entry is kept below unedited, because what it
predicted is exactly what happened and the entry is the reason it was done properly.

**WHAT CLOSED IT.** `core/link/kernel.ld` now emits THREE `PT_LOAD` segments — `.multiboot`+`.text`
`R E`, `.rodata` `R`, `.data`+`.bss` `RW`, each 4KiB-aligned — and `core/kernel/vm.dart` builds a real
4-level page table out of six frames from the M7 allocator that honours those boundaries with actual
PTE bits: `.text` RW=0/NX=0, `.rodata` RW=0/NX=1, `.data`/`.bss` RW=1/NX=1, plus `EFER.NXE` and
`CR0.WP` set in `boot.S`. The new `CR3` is installed during `kmain()`.

**THE EVIDENCE IS A FAULT, NOT A FLAG**, which is what this entry asked for. `vmtest ro` stores a byte
through a pointer into a `@rodata` table:

```
VM TEST RO ADDR 0000000000114BE8
FAULT 0E ERR 0000000000000003 OP 4889
PF CR2 0000000000114BE8 ERR 00000003 PRESENT WRITE SUPER DATA
FAULT RECOVERED 0001 -- faulting computation abandoned, shell resumed
```

and the canary's eight bytes are unchanged in the next report. `vmtest nx` calls into the same page and
gets `ERR 00000011 PRESENT READ SUPER FETCH`. `vmtest rw` and `vmtest x` are the controls — the same
two operations against a writable page and an executable page — and must NOT fault. The permissions are
read out of the LIVE page tables in guest physical memory at the CR3 QEMU reports, walked by
`m8-paging/derive.py`, never from the kernel's own report.

**THIS ENTRY'S OWN WARNING WAS THE LOAD-BEARING PART.** It said the fix must not be a link-script-only
change, because separate segments without page-table enforcement look like protection while providing
none. That was right, and it was nearly right in a second way nobody predicted: with the segments split
AND the page tables built AND every `.rodata` entry reading back RW=0, the write still landed, because
`CR0.WP` was clear. See GAP-0080.

**WHAT IS NOT CLOSED:** user/supervisor separation, per-process address spaces, TLB shootdown, a
null-page trap, and compile-time const-ness on `Pointer` (a DCDart-side problem — a store into
`.rodata` is now a fault instead of silent corruption, which is not the same as catching it before it
runs). GAP-0081 has the full list.

---

### The original entry, as filed at M1 — unedited

`core/link/kernel.ld`'s PHDRS block deliberately forces every section into ONE `PT_LOAD` with
`FLAGS(7)`, and `boot.S` identity-maps with 2MiB pages and no per-section permissions. Verified, not
assumed:

```
Program Headers:
  LOAD  0x00100000  FileSiz 0x02ae2  MemSiz 0x0c008  Flg RWE
  Segment Sections: .multiboot .text .rodata .data .bss
```

Both were correct simplifications when the only thing in `.rodata` was a handful of constants and
nothing could write to them anyway. Neither is correct once DCDart can emit constant globals.

**The concrete consequence, and it is worse than a fault:** a `Store` through a `Pointer` derived from
a constant global **succeeds silently**. DCDart's `DCPointer` carries no const-ness, `Store` accepts any
`DCPointer`, and DC-IR has no verifier pass (DCDart's own gap for the compile-time half). So there is no
compile-time check and, on this target today, no runtime check either — the write lands in `.rodata`
and nothing anywhere notices. `.text` is equally writable, so a stray pointer can overwrite code.

**Why this matters more than it looks:** the project owner's reflection thesis
(DCDart `docs/escalations/0004-runtime-reflection.md`) puts type descriptors, field tables, name
strings, condition descriptors and restart tables in `.rodata`. A silently corrupted type descriptor in
a system whose central premise is that programs know what they are is not a crash — it is a program
confidently reporting a false answer about itself. That is the worst available failure mode for this
design and it deserves to be closed before descriptors ship, not after.

**Cost of the workaround:** none taken — this is un-started work, not something routed around. It was
correctly out of scope for M0 and M1, neither of which had any read-only data worth protecting.

**What closing it needs:** separate `PT_LOAD` segments with real flags (`.text` RX, `.rodata` R,
`.data`/`.bss` RW), 4KiB pages for the boundaries (or section alignment to 2MiB), and page-table entries
that actually honour them — including `NX`, which needs `EFER.NXE` set. That is a real paging unit and
almost certainly belongs with the physical memory manager rather than ahead of it, since both need
`boot.S` to stop being the only thing that ever touches page tables.

**Blocked on:** nothing in this repo. It can be started whenever paging is scoped. It should NOT be
started as a link-script-only change — separate segments without page-table enforcement would look like
protection while providing none, which is worse than the honest single RWX segment we have now.

---

## GAP-0052 — The kernel is compiled at `-O2` for the first time, and MMIO correctness now rests on one-day-old upstream work

**Domain:** kernel, toolchain (M2)
**Status:** OPEN — not a workaround; a dependency worth watching, with a real residual gap named below.

Until 2026-08-21 every object this project ever built was `-O0`, because `dcc` passed no `-O` flag at
all. Two DCDart commits landed on the same day and changed that:

- **ADR-0041** (`c20063c`) — `Pointer<T>` load and store are now emitted as LLVM `volatile`.
- **ADR-0042** (`bb2925f`) — `dcc` passes `-O2` by default.

`DCDART_PIN.txt` is bumped to `9e836a3` (a clean tree, docs-only above `bb2925f`), which is the commit
all four harnesses were finally re-run against.

The ordering is load-bearing and DCDart got it right: `-O2` before ADR-0041 would have silently deleted
MMIO accesses across this whole kernel — UART, PIC, PIT, IDT, and every one of the ~2000 VGA cell
stores M2 added.

**What was verified here, at `-O2`, rather than taken from the changelog:**

| Claim | Evidence |
|---|---|
| VGA stores survive | `vgaClear` disassembles to a 5×-unrolled loop with all five `movw $0xf20,...` stores intact. Asserted by `tests/conformance/m2-console/run.sh`. |
| VGA stores are not coalesced | No `movdqa`/`movups` anywhere in `vgaClear` — LLVM may not vectorize volatile accesses. Also asserted. |
| Port I/O survives, and is not hoisted | `uartPutc`'s Line-Status-Register poll keeps `in (%dx),%al` **inside** the loop back edge. |
| Nothing else moved | All three pre-existing harnesses produce byte-identical serial output at `-O2`. |

**Port I/O is covered by a DIFFERENT mechanism, and this is the part to keep an eye on.** ADR-0041 is
about `Load`/`Store`. `Port.outb`/`Port.inb` lower to LLVM `asm sideeffect` inline assembly
(ADR-0029), which cannot be deleted and cannot be hoisted out of a loop — so port I/O is safe today,
but it is safe *incidentally*, by a property of inline asm, not because anyone decided port I/O should
be volatile. Nothing upstream asserts that property at `-O`. If the port-I/O lowering is ever changed
to something other than `sideeffect` asm, this kernel's UART poll becomes an infinite loop on a stale
register and the failure mode is a silent hang, not a wrong value.

**Residual gap, stated precisely:** DCDart's conformance suite proves `Pointer<T>` volatility across
`-O0..-O3` (`tests/conformance/volatile/`). It proves nothing equivalent for `PortIn`/`PortOut`. That
is a DCDart-side need, not something to work around here (CLAUDE.md rule 3): a structural harness that
disassembles a `Port.inb` poll loop at `-O2` and asserts the `in` is inside the back edge.

**UPDATE 2026-08-21 (M3), not yet pinned:** the DCDart checkout has since grown `b3e7b38`, "Test port
I/O under optimization (GAP-0036) — it was safe by accident", which looks like exactly the harness
this paragraph asked for. It is **two commits past `DCDART_PIN.txt`** and was not built against here,
so nothing above is retracted on its strength. When the pin next moves, re-read that commit and, if it
does what its subject says, close this residual gap with the evidence rather than with the changelog.

**Cost of the workaround:** none taken. This entry exists so that "it works at `-O2`" is attached to
the evidence that made it true, and so the one uncovered half is named.

---

## GAP-0053 — DCDart still has no mutable static data, and the shell made that expensive rather than merely awkward

**Domain:** kernel (M2, M3, M4, M5, M6, M7, M8, M9), DCDart-side language gap
**Status:** OPEN — worked around, with the cost measured. **16 → 304 at M3, → 392 at M4, → 424 at
M5, → 424 at M6 (unchanged), → 5096 at M7, → 5224 at M8, → 5368 at M9.**

**THE M9 MEASUREMENT: 5368 bytes**, asserted exactly by `tests/conformance/m9-ring3/run.sh`. M9's 144
bytes are 128 for `user_store` — the ring-3 subsystem's entire state, one symbol behind one accessor
reached through one function, the same shape `vm_store` uses — plus 16 for `user_resume_rsp` and
`user_resume_ok`, which hold a stack pointer and its guard and are therefore ASSEMBLY-owned forever:
DCDart cannot read or write RSP, so those two will still be in `kdata.S` on the day mutable statics
land. m8-paging now asserts its own 5224 by subtracting M9's blocks by name, as m5/m6/m7 already did
for `pmm_store` and `vm_store`.

**THE M8 MEASUREMENT: 5224 bytes**, asserted by `tests/conformance/m8-paging/run.sh` (excluding M9's
blocks), which
owns the total now. The new 128 bytes are `vm_store` — the virtual-memory subsystem's entire state:
the PML4 it built, the six frames it took from the allocator, the page counts it mapped, the last page
fault it reported, and one deliberately writable scratch word so `vmtest rw` can be the control for
`vmtest ro`. It is ONE symbol behind ONE accessor reached from ONE function, which is the tightest
storage seam in this kernel and one notch tighter than M7's three (ADR-0012 §3).

Every earlier harness still asserts its own milestone's number by SUBTRACTING the blocks that came
after it — m5-pci and m6-disk assert 424 excluding `pmm_store` and `vm_store`, m7-frames asserts 5096
excluding `vm_store` — so growing the total cannot dilute an older claim. The same discipline was
extended to the declared-extern count at M8: m5/m6/m7 subtract M8's twelve **by name** rather than
bumping a total, which also fails if one of them quietly disappears. M5 is the first milestone whose two halves land on
opposite sides of this gap; see the M5 note. M6 is the first milestone that had an obvious 512-byte
need and refused it; see the M6 note. **M7 is the milestone that stopped refusing** — and the M7 note
is the one to read, because it is about the SHAPE of the workaround rather than its size.

**THE CURRENT MEASUREMENT (M7, 2026-08-21): 5096 bytes**, asserted exactly by
`tests/conformance/m7-frames/run.sh`, which owns the total now. Of that, **4672 bytes are one
symbol** — `pmm_store`, the page allocator's bitmap, metadata and self-test ledger — and **424 are
everything M2 through M6 donated put together**. `m5-pci/run.sh` and `m6-disk/run.sh` still assert
that 424, restated as "the total EXCLUDING `pmm_store`", so each older milestone still asserts its
own claim and neither can hide behind the other.

**The pre-M7 measurement, kept because the table below is M4's 392.** `core/boot/kdata.S` donated
**424 bytes** of `.bss` through M6, asserted exactly by `tests/conformance/m5-pci/run.sh` — which
inherited ownership of the exact total
from `m4-fault/run.sh` the same way m4-fault inherited it from m3-shell and m3-shell from
m2-console, because one harness should own the number and it should be the milestone that grew it.
The table below is M4's 392; M5's `fb_state` (32 bytes: base, pitch, cursor column, cursor row) is
the eleventh row and is described in the M5 note:

| Word | Bytes | Milestone | Exists because |
|---|---|---|---|
| `vga_cursor` | 8 | M2 | the console cursor must outlive a call |
| `m2_phase` | 8 | M2 | a fault during M2 must not re-enter the console |
| `shell_line` | **256** | M3 | **a line editor needs a buffer, and DCDart has no array type either** |
| `shell_len` | 8 | M3 | how much of the buffer is valid |
| `shell_state` | 8 | M3 | 0 accepting / 1 submitted / 2 running — closes the race where a keystroke mutates the line a command is walking |
| `shell_mbinfo` | 8 | M3 | the Multiboot pointer, so `mem` can re-walk it after `kmain`'s frame is gone |
| `kbd_prefix` | 8 | M3 | the one-byte `0xE0` state machine that fixes GAP-0055 item 2 |
| `cpu_info` | **64** | M4 | **two CPUID strings that cannot cross a function boundary at all** — see GAP-0061 |
| `fault_count` | 8 | M4 | how many faults have been recovered from, so `FAULT RECOVERED 0002` is a count and not a constant |
| `shell_resume_rsp` | 8 | M4 | the stack pointer fault recovery resumes onto (ADR-0007). Written by assembly; DCDart cannot read RSP |
| `shell_resume_ok` | 8 | M4 | 1 once that mark is real. `.bss` is not zeroed, so without it a fault before the shell started would resume onto garbage and triple-fault *while reporting a fault* |

**What M4 added to the argument.** M3's growth was a buffer; **M4's is a return value.** 64 of the 88
new bytes exist for no reason other than that a 12-byte string cannot be handed from one function to
another in this language — not returned, not passed, not stored anywhere but donated `.bss`. That is
GAP-0061, and it is a different failure mode from "a line editor needs somewhere to put a line": it
shows up at every *interface*, not just at every subsystem with state.

**M5 NOTE (2026-08-21): 392 -> 424, and the two halves of the milestone land on opposite sides of
it.** The framebuffer console (ADR-0009) donated **32 bytes** — `fb_state`: base address, pitch,
cursor column, cursor row. A console has a cursor and cannot not have one, and four `u64`s is the
smallest honest shape for it. `tests/conformance/m5-pci/run.sh` inherits ownership of the exact
total from `m4-fault/run.sh`, by the same rule that moved it m2 -> m3 -> m4: the harness for the
milestone that grew it owns the number.

**The other half of M5 added nothing, and the reason is not good news.** PCI enumeration
(ADR-0008) added **zero** donated bytes — `tests/conformance/m5-pci/run.sh` asserts the total is
still 392 — because `core/kernel/pci.dart` prints as it walks and retains nothing, exactly as
`mbReport` does with the memory map. That is the *same* limitation this entry describes, showing up
as an absence rather than as a cost: there is no device list because there is nowhere to put one, so
every future consumer of "which devices are on this machine" has to re-walk the bus. GAP-0067 item 1.
The trajectory argument is unchanged and M5 sharpens it into a rule: **a subsystem either pays in
donated `.bss` or pays by being unable to remember anything.** PCI enumeration took the second deal
and cannot tell anyone what it found; the framebuffer console took the first and cost 32 bytes. The
page allocator cannot take the second deal at all.

That is 18× growth in one milestone, and the shape of the growth is the finding: **M2's cost was
words, M3's cost is a buffer.** `static u8 line[256];` is one line of C and it is not expressible in
this language at all — not as a mutable static, not as an array, not through an allocator. It has to
be donated by assembly and reached through a `u64` address, and every read or write of it is a call
across an object boundary this kernel does not LTO.

The trajectory is the argument: a keyboard input queue, a scheduler run queue and a page-allocator
bitmap are each larger than this, and each one lands in the same file.


**M6 NOTE (2026-08-21): still 424, and this is the first milestone that turned the tax DOWN.**

An ATA PIO driver's obvious shape is `read(lba, buffer)`, and the buffer is 512 bytes — which would
have taken this total from 424 to **936**, more than doubling it in one milestone, for one command.

It is still 424. `core/kernel/ata.dart` hexdumps each 16-bit word as it comes off the data port and
retains nothing, and the one place a buffer looked unavoidable — trimming the 40-byte space-padded
IDENTIFY model field — is done with a **running count of deferred spaces** instead: spaces are
counted rather than printed until a non-space follows them. One word of a live local does the job of
forty bytes of storage, and it works *because* the characters arrive in order and are printed as
they arrive.

**That is the same deal `pci` and `mem` took, and this is the clearest statement of its price the
project has reached.** Three subsystems now re-derive their results from scratch on every use
because there is nowhere to keep them, and the third one is a *disk*: the kernel can read persisted
data off a device and has nowhere to put it. There is no `read(lba) -> bytes`, so a filesystem, a
partition parse and a block cache are all the same missing thing (GAP-0074 item 1).

So M6 did not spend any of the budget the allocator's decision is about — which is deliberate, since
spending it would have prejudged that decision — and it ends by making the case for spending it
unanswerable.


**M7 NOTE (2026-08-21): 424 → 5096, and the number is the least interesting thing about it.**

The page allocator donated **4672 bytes** — a 4096-byte frame bitmap, 64 bytes of metadata, and a
512-byte ledger the self-test needs to hold 64 addresses at once. That is **eleven times everything
the previous five milestones donated put together**, and it is exactly the growth four earlier
milestones deferred rather than take.

**The objection that deferred it was about load-bearingness, not size, and it was answered by shape.**
The recorded argument was: building the kernel's most important subsystem on assembly-donated `.bss`
would make the workaround load-bearing and turn the eventual language fix into a rewrite. So the
allocator's state is **ONE symbol behind ONE accessor**, and `core/kernel/pmm.dart` reaches it through
exactly **three** functions marked as a storage seam. Nothing else in the kernel knows the storage
exists. When DCDart grows mutable statics the migration is: declare three statics, rewrite three
functions, delete `pmm_store` and `pmm_store_addr`. The allocator does not move.

**This is the first entry in this file with a mechanically-enforced migration plan.**
`tests/conformance/m7-frames/run.sh` counts the seam's call sites — exactly three in `pmm.dart`, zero
in every other kernel source — and fails on a fourth. It is the only structural check in this project
that protects a *future* change rather than a present property, and it is the reason this milestone
was buildable before the language decision was made.

**What it costs while the workaround stands**, stated plainly: 4672 bytes of hand-written assembly
`.bss`; one `@extern` call (`pmm_store_addr`) on *every* bitmap bit test, every metadata read and
every metadata write, none of which `-O2` can inline because it crosses an object boundary this kernel
does not LTO — a full 32768-frame drain makes roughly 200,000 of them; and the same `.bss`-is-not-
zeroed footgun every other donated word has, answered by `pmmInit()` filling the bitmap with 0xFF
before it frees anything.

**The trajectory prediction in this entry was right and can now be closed out.** It said "a keyboard
input queue, a scheduler run queue and a page-allocator bitmap are each larger than this, and each one
lands in the same file." The bitmap landed. It was 4KiB. The other two are still ahead.

---

**Historical detail (M2), kept because it is where the measurement started:**

DCDart has no `static`, no global, no mutable top-level anything. `@rodata` (ADR-0040) gives read-only
tables and nothing else. Every byte of kernel state that must outlive a call has to be donated by
assembly and reached through a `u64` address.

At M1 that was one word (the tick counter) and it hid inside `isr.S` without distorting anything,
because the only state M1 needed *was* interrupt state. M2 broke that: a console cursor is not
interrupt state. `core/boot/kdata.S` now exists purely to donate it — 16 bytes, two words
(`vga_cursor`, `m2_phase`), plus two `leaq`/`ret` accessor functions and their `@extern` declarations.

**The cost, concretely:**

- ~90 lines of assembly and 3 extern declarations to express what `static u64 x;` would say in one line.
- Two extra function calls on every character printed (`vgaCursor()` reads through an accessor;
  `vgaSetCursor()` writes through one), neither of which `-O2` can inline, because they cross an
  object-file boundary this kernel does not LTO.
- `.bss` is not zeroed by anything here, so every donated word needs an explicit initializer at a
  carefully chosen moment — `vgaInit()` must be the first call in `kmain()` or a garbage cursor
  scatters 16-bit stores across memory at `0xB8000 + 2 * garbage`. That is a real, silent-corruption
  footgun created entirely by the workaround.
- It does not scale. Every subsequent subsystem with state — a keyboard input buffer, a scheduler's
  run queue, a physical page allocator's bitmap — pays the same tax, and each one makes `kdata.S`
  more of a junk drawer.

`tests/conformance/m2-console/run.sh` used to assert `kdata.o`'s `.bss` was **exactly** 16 bytes. That
assertion moved to `m3-shell/run.sh` at M3, and moved again to `m4-fault/run.sh` at M4, where it reads
392 — one harness owns the total, and it is the milestone that grew it. The harnesses it left behind
each kept a narrower check that is genuinely theirs: m2-console asserts `vga_cursor` and `m2_phase` are
8 bytes each, and m3-shell asserts its own four shell state words are 8 bytes each and that
`shell_line` is 256. A shrunk or renamed word is still caught in the milestone that owns it. The total
should move only as a deliberate edit, and its growth is the argument for closing this upstream.

**Where the real fix belongs:** the DCDart repo, not here (CLAUDE.md rule 3). This is already recorded
on DCDart's side; what this entry adds is the concrete downstream price, which had not been paid
before M2 and got 18× worse at M3.

---

## GAP-0054 — The VGA text console is QEMU-shaped; real hardware needs a framebuffer console

**Domain:** kernel (M2, M5)
**Status:** **PARTIALLY RESOLVED at M5.** Item 2 (the glyph renderer) is BUILT and verified —
`core/kernel/fb.dart`, `docs/decisions/0009-framebuffer-console.md`,
`tests/conformance/m5-pci/run.sh`. Item 1 (Multiboot2) turned out **not to be required**, for a
reason worth reading. Item 3 (scrolling) is OPEN and is now GAP-0070 item 1.

**M5 UPDATE, and it corrects this entry's own reasoning rather than just adding to it.**

This entry said the framebuffer console needed Multiboot2 first, "because the framebuffer tag does
not exist in Multiboot1", and called that a boot-protocol change of the kind CLAUDE.md says to
escalate rather than take unilaterally. The premise was right; the conclusion was wrong, because it
assumed the only way to learn a framebuffer's address is to be *told* it by the loader.

**A PCI base address register is a second way.** M5's own first half (ADR-0008) gave this kernel the
ability to enumerate configuration space, so `fb` finds the display controller by class code, reads
BAR0, and gets `0xFD000000` — from the hardware, not from a boot protocol. `boot.S`'s Multiboot1
header is untouched, and no escalation was needed.

**What that does and does not buy.** It works on a machine whose display adapter is a PCI device this
kernel can program a mode on. It does **not** work on a machine that boots UEFI and hands the loader
an already-configured framebuffer — there the right answer is still to take the one you are given,
and asking a GOP-configured adapter for a Bochs VBE mode gets nothing (GAP-0070 item 2). So
Multiboot2 or a UEFI stub is **still** the portable answer and is **still** unbuilt. This entry is
narrowed, not closed.

**Original entry follows, kept because items 1 and 3 are still live.**

`core/kernel/vga.dart` writes to the VGA text buffer at `0xB8000`: 80x25 cells, two bytes each,
character plus attribute. That works under QEMU (and on legacy-BIOS hardware with a real VGA
adapter), and it is what `OSCORTEX_SPEC.md` §3 says it is — a development-time output path, not a
generalizable one.

**What a modern machine actually presents:** it boots UEFI, has no VGA text mode on the primary boot
path, and hands the loader a linear RGB framebuffer (address, width, height, pitch, bits per pixel).
Writing `0xB8000` there does nothing at all — not a fault, not a garbled screen, simply nothing.

**What closing this needs, in order:**

1. **Multiboot2**, because the framebuffer tag does not exist in Multiboot1. That is a boot-protocol
   change: a new header, a tag walk instead of a fixed struct, and `core/kernel/multiboot.dart`
   rewritten. It is also the CLAUDE.md-escalation kind of decision (boot protocol), not one to take
   unilaterally.
2. A **glyph renderer**: an 8x16 bitmap font as a `@rodata final List<u8>` (4096 bytes), and a blit
   loop that expands one glyph into `height * width` pixels at the reported pitch.
3. **Scrolling by pixel row**, which is a memmove of hundreds of KiB rather than 3840 bytes — at which
   point "DCDart has no memcpy" stops being a curiosity and becomes a performance problem.

**Cost of the workaround:** the console works on exactly the target this project has ever tested on,
and nowhere else. Nothing is *mis*-stated in the code — `vga.dart`'s header says this outright — but
the screenshot in `core/build/` should not be read as evidence that a laptop would show the same
thing. **That last sentence is still true at M5 and now applies to `screenshot-fb.png` as well**, for
a different reason: the framebuffer console's *renderer* would work anywhere, and its *mode-set path*
is Bochs-specific.

---

## GAP-0055 — The keyboard driver is deliberately stateless, and one of its consequences was a wrong behaviour rather than a missing one

**Domain:** kernel (M2, M3)
**Status:** OPEN — **item 2 is largely FIXED at M3** (arrow keys); items 1, 3 and 5 unchanged; item 4
partly answered by the shell's line buffer and partly still open.

`core/kernel/keyboard.dart` reads one byte per IRQ1, rejects anything with bit 7 set, translates
through a 128-entry `@rodata` table, and (as of M3) hands the character to the shell's line editor.
Every omission below traces back to the same root cause — state costs a donated word (GAP-0053) — but
they are not equally harmless:

1. **No shift, caps lock or control.** Modifier scancodes map to `0x00` and are ignored, so output is
   always the unshifted US-QWERTY character. Typing a capital letter is impossible. This is an
   *absence*: nothing wrong is printed. **Unchanged at M3**, and it is now the most visible
   limitation, because a shell is a thing people expect to type mixed case into.

2. **`0xE0` prefix handling — FIXED at M3 for the two-byte case, still WRONG for `0xE1`.**

   *What it was:* extended keys (arrows, right-hand modifiers, keypad Enter) send `0xE0` followed by a
   second byte, in two separate interrupts. `0xE0` mapped to `0x00` and was ignored — but its
   **follower was then interpreted as an ordinary make code**. Pressing the up arrow (`0xE0 0x48`)
   typed `8`, because `0x48` is keypad-8 in the table.

   *What it is now:* `kbdHandle` sets a flag on `0xE0` and consumes the next byte whether it is a make
   or a break code (both halves of an extended key press carry the prefix; clearing only on the make
   would leave the flag set and swallow the next ordinary key). Arrow keys emit nothing.
   `tests/conformance/m3-shell/run.sh` injects all four arrows at an empty prompt and asserts **zero
   bytes** on COM1. Cost: one donated word (`kbd_prefix`, GAP-0053).

   *What is still wrong:* **`0xE1`** — the Pause key's six-byte sequence — is mishandled in exactly the
   old way. `0xE1` maps to `0x00`, is ignored, and its five followers are translated as ordinary keys,
   so Pause still types garbage. Narrowed, not closed. Fixing it needs a small counter rather than a
   flag, i.e. the same donated word carrying a count instead of a boolean.

   *Also still absent:* the extended keys are consumed and **do nothing**. Arrows do not move a cursor
   within the line and there is no history. See GAP-0057.

3. **No controller programming at all.** No self-test, no explicit set-scancode-set, no LED update. The
   driver uses the 8042's power-on state (set 1 via translation, keyboard port enabled) as SeaBIOS
   leaves it, and does not verify it. Verifying it needs a command/response handshake with timeouts,
   and this kernel has no answer to "the keyboard did not respond" beyond hanging.

4. **No input buffer — HALF ANSWERED at M3.** A keystroke used to be echoed and discarded; there is a
   256-byte line buffer now, and something that consumes lines (the shell). What is still missing is a
   **queue**: while a command is running, `shell_state` is 2 and `kbdHandle` drops every keystroke, so
   type-ahead during `mem` or `ticks` is lost silently. A real queue is another donated buffer plus
   head/tail indices (GAP-0053), and it is what a `getchar()` for programs would eventually be built
   on. See GAP-0057.

5. **8042 assumed to exist.** On hardware that came up through UEFI with no legacy emulation there may
   be no PS/2 controller at all; the real input path there is USB HID, which needs a USB stack.

**Cost of the workaround:** the shell types lowercase ASCII correctly and no longer does anything
visibly wrong for arrow keys — they are consumed and ignored. The remaining *wrong* answer is Pause
(`0xE1`); everything else on this list is an absence.

---

## GAP-0056 — `verify-freestanding.sh` cannot check `boot.o`, `isr.o` in isolation, and now `kdata.o` is the exception that proves it

**Domain:** test (M1, M2)
**Status:** OPEN — accepted limitation, restated because M2 added a third assembly object.

CLAUDE.md rule 1 says every kernel object must link freestanding. The checker permits undefined symbols
only when the source *declared* them, which `dcc` records in a per-object `.externs` manifest (DCDart
ADR-0038). Assembly has no `dcc`, so it has no manifest.

Measured, not assumed:

| Object | Standalone result | Why |
|---|---|---|
| `kdata.o` | **pass** | references nothing outside itself |
| `boot.o` | fail | references `kmain` |
| `isr.o` | fail | references `isrDispatch` |
| `kmain.o` | pass (17 declared externs as of M3, was 12) | manifest |
| `kernel.elf` | pass | nothing left dangling |

`kdata.o` passing is the useful new data point: the failures are genuinely about cross-object
references, not about assembly being unanalysable. `kernel.elf` covers all three, so nothing is
unchecked — but the *per-object* claim is weaker for `boot.o`/`isr.o` than the rule's wording suggests,
and the honest closure is a hand-written `.externs` manifest for assembly objects, not an allowlist
entry (the allowlist is owned by DCDart's E4 and must stay empty).

**M3 note — `kdata.o`'s standalone pass is now a design constraint, not just an observation.** The
`mem` command needs the Multiboot information pointer, which `boot.S` already holds in its own `.bss`.
The obvious implementation is to make `multiboot_info_ptr` global and add an accessor for it in
`kdata.S` — and that would give `kdata.o` an undefined symbol and turn the one passing assembly object
into a third failing one. It was implemented as an 8-byte **copy** instead (`shell_mbinfo`, written by
`shellInit()` from `kmain`'s argument), which costs eight bytes of GAP-0053's budget and keeps this
row green. Recorded so the eight bytes are not later "optimized away" by someone who has not read
this. `tests/conformance/m3-shell/run.sh` runs `verify-freestanding.sh` on `kdata.o` explicitly, so
the property is asserted rather than assumed.

**M4 note — `kdata.o` now EXPORTS symbols, and still passes.** `cpu_probe` and `shell_run_forever` in
`isr.S` write into `kdata.S`'s `.bss` (`cpu_info`, `shell_resume_rsp`, `shell_resume_ok`), so those
three are `.global` now. Exporting a *definition* adds no undefined symbol, so the row above is
unchanged — and `tests/conformance/m4-fault/run.sh` runs `verify-freestanding.sh` on `kdata.o`
explicitly rather than assuming it, because "the one assembly object that passes standalone" is the
evidence this entry rests on. The reference goes the other way (`isr.o` gains three more undefined
symbols), which costs nothing: `isr.o` already fails standalone for `isrDispatch`, and now also for
`shellMain` and `shellRecover`, which is the fault-recovery seam running inbound.

**M5 note — `portio.o` is a SECOND assembly object that passes standalone.** `core/boot/portio.S`
(GAP-0066) is two leaf functions with no data and no undefined symbols at all, so it passes on its
own, and `tests/conformance/m5-pci/run.sh` runs `verify-freestanding.sh` on it explicitly. Two rows
in the table above now pass and two fail, which strengthens the entry's central point rather than
changing it: the failures are about *cross-object references*, not about assembly being
unanalysable. The table as of M5:

| Object | Standalone result | Why |
|---|---|---|
| `kdata.o` | **pass** | references nothing outside itself |
| `portio.o` | **pass** | two leaf functions, no data, no references |
| `boot.o` | fail | references `kmain` |
| `isr.o` | fail | references `isrDispatch`, `shellMain`, `shellRecover` |
| `kmain.o` | pass (29 declared externs as of M5, was 24 at M4) | manifest |
| `kernel.elf` | pass | nothing left dangling |

**Cost of the workaround:** a link-time regression in `boot.S` or `isr.S` is caught at the `kernel.elf`
step rather than at the object step — later and with a less specific message, but caught.

---

## GAP-0057 — The shell is a dispatcher, not a command line: no history, no in-line cursor, no arguments, no type-ahead

**Domain:** kernel (M3)
**Status:** OPEN — every item below was deliberately not built, not overlooked.

`core/kernel/shell.dart` reads a line, compares it byte-for-byte against five `@rodata` names, and
runs the matching function. That is genuinely a shell — it edits, it submits, it dispatches, it
reports what it does not understand — and it is also the smallest thing that is. What it is not:

1. **No history.** Up-arrow does nothing (it is consumed by the `0xE0` handler, GAP-0055 item 2). A
   ring of previous lines is another donated buffer (GAP-0053) times however many lines are kept.

2. **No cursor movement inside the line.** Left/right arrows do nothing. Editing is append and
   backspace only, so a typo in the middle of a long line means backspacing over everything after it.
   Adding it needs an insertion point separate from the length, plus a redraw of the tail on every
   keystroke — the redraw is the real work, not the extra word.

3. **No tokenizer, no arguments, no quoting.** `echo` takes "everything after the space" as one
   undivided run of bytes. There is no argv, so a command that wanted two arguments would have to
   split the line itself, and there is nowhere to put the result of the split.

   **M4 made this visible rather than worse.** `crash ud` and `crash div` are dispatched as WHOLE
   LINES — `"crash ud"` is an 8-byte command name, argument included — because there is still nothing
   to split a line into. That works for a fixed, small set of sub-commands and it does not generalise
   past one: `crash <n>` for an arbitrary `n` is not expressible without a tokenizer and somewhere to
   put the parsed number. `crash` with anything else falls through to a usage line rather than being
   silently misread, which is the same guard `echonow` already had.

4. **No type-ahead.** While a command runs, `shell_state` is 2 and `kbdHandle` drops every keystroke
   silently. A user typing during `mem` loses those characters with no indication. This is the direct
   consequence of having no input queue (GAP-0055 item 4) — and it is a *correctness* mechanism, not
   laziness: without it a keystroke would mutate the line buffer that `shellExecute` is walking.

5. **Dispatch is an `if` chain, one arm per command.** DCDart has no function pointers and no dynamic
   dispatch of any kind (GAP-0002), so a `{name, handler}` table is not expressible. Five arms is
   fine. Twenty is a maintenance surface where a missing `return` silently runs two commands. **M4
   took it to nine** (`help`, `clear`, `mem`, `ticks`, `cpu`, `crash ud`, `crash div`, `crash`, `echo`)
   and the ordering became load-bearing for the first time: the two exact `crash` matches must precede
   the `crash` prefix match, or every `crash ud` would print a usage line instead of faulting.

6. **No exit, no way to stop.** `shellMain` never returns and there is no shutdown mechanism in this
   kernel at all (`isa-debug-exit` has been out of scope since M0). The harness's termination path is
   QEMU's `quit` over QMP.

**Cost of the workaround:** the shell does what its own `help` says it does and nothing more, which is
honest — and at M4 that sentence acquired a receipt: `help` was updated in the same change as the
commands, m3-shell's goldens moved because of it (GAP-0065), and the one thing that briefly disagreed
was a hand-maintained byte count (GAP-0060). It is still noticeably less than a user's muscle memory
expects — arrows and history are the two
that will be missed first. None of these should be built speculatively; they should be built when
something needs them (history when sessions get long enough to repeat commands; argv when a command
takes an argument that is not "the rest of the line").

---

## GAP-0058 — The PIT is masked at rest, so `ticks` measures the timer rather than reporting it — and it waits without a timeout

**Domain:** kernel (M3)
**Status:** OPEN — a deliberate trade with two named costs.

The tick counter is **not free-running**. `kmain()` masks every IRQ before M1's deliberate fault, and
the console unmasks IRQ1 only (mask `0xFD`). The `ticks` command unmasks IRQ0, waits for the counter
to advance by `0x10`, re-masks, and prints `TICKS <start> +0010 LIVE`.

**Why, stated rather than implied.** A raw live count is a duration, and a duration cannot appear in a
byte-exact golden. With the PIT masked between commands the counter holds still, so `start` is a fixed
value (100 — the count M1 stopped at) and the whole line is assertable. That is the same reasoning M1
used for `M1 TICKS`: the count is the trigger, not a duration.

**Cost 1 — "live" means "advances when asked", not "running".** Nothing in this kernel keeps time.
There is no uptime, no scheduling quantum, no timeout anywhere, because there is no clock running
between commands. The moment something needs a real timebase — a preemptive scheduler, an I/O timeout,
a `sleep` command — the PIT has to stay unmasked, at which point `ticks` output becomes
non-deterministic and this milestone's golden needs a different shape (report a delta only, or move
the assertion off the raw value).

**Cost 2 — the wait is unbounded.** If the PIT never fires, `shellTicks` spins forever with interrupts
enabled and the shell is wedged. That is the same failure mode `uart.dart`'s Transmit-Holding-Register
poll already has and for the same reason: "give up and do what?" still has no answer, because there is
no panic path. Under the harness it surfaces as a timeout, which is a hard failure — but at a real
prompt it is an unresponsive machine with no diagnostic. A bounded spin is expressible today; a useful
*response* to the bound being hit is not.

---

## GAP-0059 — m2-console's goldens were regenerated at M3, deliberately

**Domain:** test (M2, M3)
**Status:** RECORDED — a fact on the record, not a workaround. Read this before treating the M2
goldens as continuous with the ones ADR-0005 describes.

`tests/conformance/m2-console/expected.txt` and `expected-screen.txt` were re-recorded when the shell
landed. Both had encoded the *echo box*: type `oscortex 2026`, see `oscortex 2026`. M3 replaces the
echo box with a line editor, so typing that now produces an unknown-command diagnostic and a fresh
prompt. The old goldens asserted behaviour the change was designed to remove.

**Why this is not "regenerate until green".** The distinction that matters is whether the *assertions*
changed or only the *recording* did:

- **M1's 544-byte golden did not move by one byte**, and m2-console still checks it mechanically as a
  prefix of its own capture. That is the load-bearing continuity check and it was untouched.
- **The key sequence is unchanged** — the same 59 keystrokes.
- **Every property m2-console asserts is unchanged in kind**, and one got stronger: backspace editing
  the screen used to be shown only by `ab\bc` on the wire versus `ac` on screen, and is now *also*
  shown by the command the shell dispatches on being `ac` rather than `abc` — the buffer was edited,
  not just the display.
- Serial grew 603 → 919 bytes and the screen golden's first line moved from `MB UPP ...` to an `MB E`
  entry, because there is more output per typed line, so scrolling pushes the boot report further off
  the top than it did.

**What DID move, and where it went:** m2-console's assertion that `kdata.o`'s `.bss` is exactly 16
bytes. It is 304 now (GAP-0053), and asserting a total in two places would guarantee they drift, so
the exact-total assertion moved to `m3-shell/run.sh` — the harness for the milestone that grew it.
m2-console kept a narrower check that is genuinely its own: `vga_cursor` and `m2_phase` are still 8
bytes each. A shrunk, renamed or missing console cursor still fails there.

**Cost:** anyone reading ADR-0005's "603 bytes" or "the golden's first line is `MB UPP ...`" against
the current files will find they disagree. ADR-0005 is a historical record and was not rewritten; this
entry and ADR-0006 §10 are the pointer that explains the discrepancy.

---

## GAP-0060 — A `@rodata` table has no length, so every literal's byte count is a magic number maintained by hand

**Domain:** kernel (M2, M3), DCDart-side language gap
**Status:** OPEN — worked around; the cost is now countable and it grew by 14 in one milestone.

`Rodata.addressOf(table)` returns the address of element 0 with **no header of any kind** in front of
it — that is an explicit contract of DCDart ADR-0040, not an accident, and it is the right contract for
a kernel. The consequence is that a table's length exists nowhere at runtime, so every call site
passes it as a literal:

```dart
uartWrite(Rodata.addressOf(shellStrHelp), u64(237));
```

There are now **63 `@rodata` tables** in `kmain.o` totalling 3215 bytes (M3 added 14, M4 added 18,
M5 added 15 — see the M5 note below for why it was not 130), and every one of the
non-scancode tables has its byte count written out at least twice: once in its doc comment and once at
each call site. `237` above is a number a human counted — and it is the exact number that went wrong at
M4; see below.

**IT HAS NOW BITTEN, and the record should say so.** M4 grew `shellStrHelp` from 237 bytes to 395 by
adding three lines to the `help` listing. The table was regenerated correctly; the literal `237` at
the single call site in `shellHelp()` was not. The first M4 build printed 237 bytes of a 395-byte
table — `cpu           CPUID vendor, brand and lea` and then, mid-word, the next prompt. Caught in
under a minute by looking at a capture, which is exactly the safety net described below working. The
cost was small *because* every byte is asserted; on an unasserted path it would have been a silent
read past the end of `.rodata`.

M4 also added a structural defence that did not exist: `tests/conformance/m4-fault/run.sh` reads each
new table's size out of the symbol table and compares it against the literal its call site passes, for
all 18 of them. That catches the mistake at the object-file step instead of at a golden. It does not
close the gap — it is 18 more hand-maintained numbers, in a second place — but a disagreement between
the two now fails with a message that names the table.

**Why it had not bitten before:** every byte this kernel prints is asserted byte-for-byte by six
harnesses, so a wrong length changes the capture and fails immediately and loudly. That is a real
safety net and it is why this is an ergonomics gap rather than a correctness one *today*.

**Where it stops being safe:** the moment a table is printed on a path the goldens do not cover — an
error message for a condition the harness never triggers, say. Then a wrong length is a silent read
past the end of `.rodata` into whatever the linker put next, printed to a screen, and nothing fails.

**What would close it, narrowly (DCDart repo, CLAUDE.md rule 3):** a compile-time `Rodata.lengthOf(t)`
that lowers to the constant the compiler already knows — no header, no runtime cost, no change to the
memory layout ADR-0040 promises. That is a much smaller ask than a String type and it removes the
whole class of error. Filed here because rule 3 says language needs are recorded in this repo and
built in that one.

**M5 (2026-08-21): the count went to 63 tables / 3215 bytes, and TWO of them answered the gap
instead of adding to it.** `pciClassNames` needed twenty short strings — one per PCI class name. The
obvious encoding is twenty `@rodata` tables and twenty more hand-maintained literals, on a path where
a wrong one prints a device's class name with the next name's first letters glued to it. It is
**one** 320-byte table of twenty fixed 16-byte records instead, each record carrying **its own length
byte** at +2, so the per-name lengths are data the lookup reads rather than numbers a human counted.
Exactly one hand-maintained constant remains for the whole table, and `m5-pci/run.sh` reads the
table's bytes back out of the object file and checks every record's self-declared length against its
own name and its own NUL padding.

**The second is `fbFont8x16`**, and it is the same idea from the other direction: 96 glyphs of 16
bytes each, in one 1536-byte table with NO lengths at all, because every element is the same size and
the renderer indexes it arithmetically (`(c - 0x20) * 16`). Ninety-six separate tables would have
been ninety-six more literals. `m5-pci/run.sh` reads the table's bytes back out of the object file
and checks its structure — 96 whole glyphs, exactly one blank, a non-blank fallback, no byte outside
the 5-pixel column range — which is a stronger check than a length ever was.

Neither closes this gap; between them they collapse a hundred-odd instances of it into two, and both
of those two are then checked mechanically. It is worth recording as a *pattern* rather than a
one-off: **when a subsystem wants N short things, put the length in the record or make every record
the same size.** `shellStrHelp` grew again in the same milestone (395 → 498) and is still the old
shape, so all three encodings sit side by side in one kernel.

**Cost of the workaround:** 63 hand-maintained constants — plus 18 in `m4-fault/run.sh` and 16 more in
`m5-pci/run.sh` — and a generator script was used to emit M3's, M4's and M5's tables precisely because
hand-encoding hundreds of bytes of ASCII into `u8(0x..)` literals with a correct count is not
something to do by eye. M5's font is the extreme case: 1536 bytes authored as 96 glyphs of nine rows
of five cells and *placed* by one line of code, because typing it as hex is the exact activity that
went wrong at M4. The generator emitted M4's tables correctly and the one number it did *not*
emit is the one that was wrong.

---

## GAP-0061 — A CPUID string cannot be handed from assembly to DCDart at all, so 64 bytes of `.bss` are the calling convention

**Domain:** kernel (M4), DCDart-side language gap
**Status:** OPEN — worked around, and the workaround is the only shape available today.

`cpuid` leaf 0 returns a 12-byte vendor string; leaves `0x80000002..4` return a 48-byte brand string.
Getting either from the assembly that executed the instruction into the DCDart that wants to print it
runs into **four missing things at once**, which is why this is its own entry rather than a line in
GAP-0053:

| Missing | Consequence |
|---|---|
| no `String` type | nothing to return the bytes *as* |
| no array type | `@rodata final List<u8>` is a declaration form, not a value — it cannot be a local, a parameter or a return type, and it is read-only anyway |
| no `Pointer<T>` in an extern signature (DCDart GAP-0025) | the address cannot be passed either direction as a pointer; only `u64` scalars cross |
| no mutable static data (GAP-0053) | there is nowhere in DCDart to *put* the bytes once they arrive |

So `cpu_probe()` (`core/boot/isr.S`) writes the two strings into 64 bytes of assembly-donated `.bss`
(`cpu_info` in `core/boot/kdata.S`) and returns the only thing it *can* return: two 32-bit CPUID leaf
limits packed into one `u64`. DCDart asks a second `@extern` accessor for the block's address and walks
it a byte at a time.

**What that costs, concretely:**

- **64 of the 392 donated bytes** exist purely to carry a return value between two functions. Not to
  hold kernel state that must outlive a call — to *cross an interface once*.
- **DCDart has to implement its own string layer.** `cpuSkipSpaces` (Intel pads the brand string with
  leading spaces) and `cpuWrite` (the brand is NUL-padded to a fixed 48 bytes, and writing those NULs
  would put 20 glyphs of garbage next to a CPU name) are `strspn` and a bounded `strlen`, written out
  because there is nothing to call.
- **The layout is a contract in a comment.** "Vendor at +0, 12 bytes; brand at +16, 48 bytes" is
  agreed between an assembly file and a Dart file with nothing checking it but
  `tests/conformance/m4-fault/run.sh`'s assertion that `cpu_info` is exactly 64 bytes. A shorter block
  would have `cpu_probe` writing past the end of its own object and over whatever `kdata.S` put next.

**Why this generalizes badly.** Every future device driver that reads a descriptor — a PCI config
space read, an ACPI table, a USB device descriptor, a disk partition entry — has the same shape and
will need the same donated block. The trajectory is the argument, exactly as it is in GAP-0053.

**What would close it, in rough order of size:** `Pointer<T>` permitted in an extern signature (DCDart
GAP-0025) would at least let the address be a first-class argument, removing the accessor but not the
storage. Mutable static data would remove the assembly donation. A real `Str` value carrying a pointer
and a length together would remove the hand-maintained lengths (see also GAP-0060). All three belong in
the DCDart repo (`CLAUDE.md` rule 3), and none of them is this repo's to build.

---

## GAP-0062 — Abandoning a computation abandons whatever device state it was holding; only the PIC is handled

**Domain:** kernel (M4)
**Status:** OPEN — one case handled deliberately, the general case named rather than solved.

ADR-0007's recovery works by discarding every frame between the shell loop and the fault. That is
sound for *memory* state in this kernel — `@bare` DCDart has no destructors, no `finally`, and no
allocator whose bookkeeping could be left half-updated — but it says nothing about state that lives in
a **device**.

**The one case that is handled.** If the fault is taken inside an interrupt handler, that handler's
end-of-interrupt is one of the things being abandoned, and the 8259 would keep the in-service bit set
forever — the interrupt line would be dead for the rest of the boot. A shell that comes back with no
keyboard is not a recovered shell. `shellRecover()` therefore issues a **non-specific EOI to the
master** before it prints anything. It clears at most one in-service level, which is all this kernel
can have: the slave is fully masked, and interrupt gates mean handlers do not nest. It is harmless when
nothing is in service.

**What is NOT handled, precisely:**

- **A device left half-programmed.** `shellTicks` unmasks IRQ0, waits, and re-masks. A fault in the
  middle of that leaves the PIT unmasked, and nothing puts it back. Today the consequence is benign
  (a free-running 100 Hz timer whose handler works fine); tomorrow, for a device with a real
  configuration sequence, it would not be.
- **A partially written output.** Bytes already pushed down COM1 or into the VGA buffer stay there.
  Abandonment is not a transaction and does not pretend to be.
- **A fault on the recovery path itself.** `fault_resume` always resets RSP to the same mark — that is
  what makes repeated faults cost no stack — so a fault inside `shellRecover()` lands back in
  `fault_resume`, resets to the same mark, and calls `shellRecover()` again. The result is an infinite
  loop printing the same two lines, not a crash and not a triple fault. Better than the alternative and
  still a failure. Closing it needs a recursion depth word AND an answer to "give up and do what?",
  which this kernel does not have anywhere else either (GAP-0001's unbounded THRE poll and GAP-0058's
  unbounded `ticks` wait are the same missing answer).
- **Any general notion of "what was this computation holding?"** There is no ownership tracking, no
  cleanup registry, and no `finally`. Adding one is not a small feature — it is the resource half of
  the condition-system work (DCDart `docs/escalations/0005-condition-system.md`), and it needs language
  support that does not exist.

**Cost of the workaround:** the one failure that would visibly break the shell (a dead IRQ line) is
closed by one `outb`. Everything else on this list is real, currently unreachable in this kernel's own
code paths, and will stop being unreachable the moment a driver with a multi-step configuration
sequence exists.

---

## GAP-0063 — DCDart's `~/` and `%` cannot produce a divide error; they check first and trap with `ud2`

**Domain:** kernel (M4), DCDart-side observation
**Status:** RECORDED — a fact about the toolchain, discovered by measurement, worked around correctly.

The obvious way to make the kernel take a #DE is `a ~/ b` with `b == 0`. **It does not work**, and
this is worth recording because the assumption is extremely natural and it is wrong.

Verified by compiling a probe through the real `dcc` and disassembling the object, not by reading the
lowering code:

```
probeDiv:
   0:  48 85 f6      test   %rsi,%rsi
   3:  74 1c         je     21          <- zero divisor jumps here
   5:  48 89 f8      mov    %rdi,%rax
  ...
  16:  48 f7 f6      div    %rsi
  19:  c3            ret
  21:  0f 0b         ud2
```

`dcc` emits an explicit zero-divisor test in front of every division and traps with `ud2`. `%` is the
same. So a DCDart division by zero raises **#UD (vector 6)**, from the same instruction as an overflow
trap — indistinguishable, in the handler, from `crash ud`.

**This is not a DCDart bug.** DCDART_SPEC §4.1 says arithmetic traps; trapping a zero divisor before
the hardware does is a correct and defensible implementation of that, and it means DCDart code cannot
accidentally take a #DE. It is only a problem for a kernel that wants to *provoke* one on purpose.

**How it was worked around, and why that is not a rule-3 violation.** `crash div` executes the `div` in
assembly (`divide_by_zero` in `core/boot/isr.S`), in exactly the category and for exactly the reason
`debug_break` executes `int3` and `halt_forever` executes `hlt`: an instruction DCDart cannot emit,
behind a C-ABI function. Nothing was added to DCDart and nothing was routed around in the kernel — the
fault is real, raised by hardware, on vector 0.

**What this costs:** the `crash div` command demonstrates recovery from a *hardware* divide error,
which is what it says it does, but it does **not** demonstrate that a DCDart program dividing by zero
is survivable. That case reduces to `crash ud` and is covered by it. Anyone reading `crash div` as
"DCDart division is now safe" would be reading it wrong, which is why `shellCrashDiv`'s own doc comment
says this too.

---

## GAP-0064 — The faulting address is reached and dereferenced, and deliberately not printed

**Domain:** kernel (M4), test
**Status:** OPEN — a deliberate trade with a named cost.

`isr_common` passes the faulting RIP to `isrDispatch`, and `faultReport` **dereferences it**: the
` OP ` field of a fault diagnostic is the first two bytes of the instruction that actually faulted
(`0F0B` for a `ud2`, `48F7` for a 64-bit `div`). The absolute address is available and is not printed.

**Why.** Every byte this kernel prints is asserted by a byte-exact golden. An absolute code address
moves whenever *any* kernel code changes — a comment that shifts a function, an added `@rodata` table,
a compiler upgrade — so putting one in the output would guarantee that every future milestone had to
regenerate this milestone's goldens for a reason that says nothing about whether recovery works. That
is the "regenerate until green" habit `CLAUDE.md` rule 2 exists to prevent, and building it into a
golden on purpose would be worse than any single instance of it.

**What is lost, stated plainly:** you cannot tell *where* a fault happened from a capture. `OP 0F0B`
says "a `ud2`" and not "the `ud2` in `shellCrashUd`". For the two faults this kernel raises on purpose
that is enough, because the command that was typed is on the line above. For an unexpected fault in a
future subsystem it would not be — the address is exactly what you would want, and it is the thing
that is missing.

**What would close it without breaking the golden**, in increasing order of work: print the RIP as an
offset from a symbol (needs a symbol table in the image, which the kernel does not have and would have
to build); print it only when a runtime flag is set, so the goldens run with it off (cheap, and mostly
moves the problem); or have the harness normalise the field before comparing and separately assert it
falls inside `.text` read from the ELF (strictly stronger than either, but it means "byte-for-byte"
acquires an asterisk, and that phrase is load-bearing in five other harnesses). None of these was worth
doing at M4; the first real unexpected fault is what should decide it.

**Also recorded here, because it is the same field:** only **two** bytes are printed, not four. The
third and fourth bytes after a DCDart-emitted `ud2` are inter-function padding whose contents
legitimately move, so a four-byte field would reintroduce exactly the golden churn this entry avoids.
Two bytes distinguishes every fault class this kernel can currently produce and would not distinguish,
say, two different `0F 0x` two-byte opcodes.

---

## GAP-0065 — m3-shell's goldens were regenerated at M4, deliberately

**Domain:** test (M3, M4)
**Status:** RECORDED — a fact on the record, not a workaround. Same shape as GAP-0059, and it should
be read with it.

`help` lists what the shell can do. M4 added three lines to that listing (`cpu`, `crash ud`,
`crash div`), and `m3-shell`'s session ends with `help`, so both of its goldens moved:
`expected.txt` 1691 → 2007 bytes, and `expected-screen.txt` by three lines.

**Why this is not "regenerate until green".** The distinction is whether the *assertions* changed or
only the *recording* did:

- **M1's 544-byte golden did not move by one byte.** m2-console, m3-shell and m4-fault all still check
  it mechanically as a prefix of their own captures.
- **m3-shell's key sequence is unchanged** — the same 63 elements, making the same claims about
  backspace, arrow keys, `mem`, `ticks` and the uneraseable prompt.
- **Every property m3-shell asserts is unchanged in kind.**
- **The diff was checked, not assumed.** Old and new goldens were diffed: the change is exactly the
  three new `help` lines, twice in the serial capture (the session runs `help` twice) and once on the
  screen, and nothing else.
- **m2-console's goldens did not move at all**, because its session never runs `help`.

**What DID move, and where it went:** m3-shell's assertion that `kdata.o`'s `.bss` is exactly 304
bytes. It is 392 now (GAP-0053), and asserting a total in two places would guarantee they drift, so
the exact-total assertion moved to `m4-fault/run.sh` — the harness for the milestone that grew it, by
the same rule that moved it from m2-console to m3-shell at M3. m3-shell kept a narrower check that is
genuinely its own: its four shell state words are still 8 bytes each, and `shell_line` is still 256.
m3-shell's `shellStrHelp` size check moved 237 → 395 for the same reason the golden did.

**Cost:** anyone reading ADR-0006's "1691 bytes" against the current file will find it disagrees.
ADR-0006 is a historical record and was not rewritten; this entry and ADR-0007's own section are the
pointer that explains the discrepancy.

---

## GAP-0066 — DCDart's port I/O is byte-wide only, and PCI configuration space is not

**Domain:** kernel (M5, M6), DCDart-side language gap
**Status:** **RESOLVED UPSTREAM, NOT YET ADOPTED HERE.** DCDart commit `b3f0ed9` adds
`Port.inw`/`Port.outw`/`Port.inl`/`Port.outl` — exactly the ask below, at exactly the two widths
asked for, in ADR-0029's existing fixed-asm `sideeffect` shape. This repo still builds against
`DCDART_PIN.txt` = `9e836a3`, which predates that commit, so `core/boot/portio.S` is still live and
still the only way to reach any width but a byte. The workaround is described below in the present
tense because it is still what the code does.

**What adopting it looks like, and why it was not done inside M6** (see
`docs/decisions/0010-ata-pio-disk-read.md` §6): bump the pin, re-verify all eight harnesses on the
new toolchain, then delete `portio.S` outright — `pciRead32` and `pciAddr`'s port calls in
`core/kernel/pci.dart`, `vbeWrite`/`vbeRead` in `core/kernel/fb.dart` and `ataDumpLine`/
`ataIdentifyBlock`'s data-port reads in `core/kernel/ata.dart` all become `Port` calls, and
`kmain.o`'s declared-extern count drops from 29 to 25. That is a toolchain change plus a refactor of
three subsystems, and it belongs in a unit whose subject is that rather than riding along with a
disk driver.

**A third caller arrived before the fix did.** M6's ATA driver reads the 16-bit data register at
`0x1F0` through `port_inw` — the same helper M5 added for the Bochs VBE registers, one more caller,
no new assembly and no new externs. `tests/conformance/m6-disk/run.sh` asserts that helper encodes
as exactly `66 ed`, because a byte or doubleword access to an ATA data port does not merely return
the wrong width: it desynchronises the drive's own sector-buffer pointer.

`Port.outb(u16, u8)` / `Port.inb(u16) -> u8` (DCDart ADR-0029) are the only port primitives the
language has. They are **byte wide**. Three things this kernel has now met need other widths:

| need | width | where |
|---|---|---|
| PCI CONFIG_ADDRESS / CONFIG_DATA (`0xCF8`/`0xCFC`) | 32-bit | `core/kernel/pci.dart` — **live** |
| Bochs VBE dispi index/data (`0x1CE`/`0x1CF`) | 16-bit | `core/kernel/fb.dart` — **live** (M5 part 2) |
| most PCI BAR-sized register windows | 16- and 32-bit | any real device driver |

**Byte accesses are not a substitute, and this is not a style opinion.** The PCI Local Bus
Specification decodes CONFIG_ADDRESS only for a full doubleword access, so four `outb`s to
`0xCF8..0xCFB` are not a legal way to select a configuration register. They would very likely *work*
under QEMU, whose memory core widens an undersized access to a register that declares a 4-byte
minimum implementation size — which makes this exactly the kind of shortcut that passes every test
here and fails on the first real machine, with nothing in the source admitting it.

**The workaround:** `core/boot/portio.S` — **four** functions as of M5 part 2: `port_inl`/`port_outl`
for PCI configuration space and `port_inw`/`port_outw` for the Bochs VBE registers, all called over
the plain C ABI. The 16-bit pair is not a nicety: QEMU registers `0x1CE`/`0x1CF` as 2-byte-only
ports, so a byte access there is not *narrowed*, it is not decoded at all — a mode set built on
`Port.outb` would write nothing and report no error. That puts `outl`/`inl` in the same category as `cpuid`, `lidt`, `int3` and `div` — an
instruction with no DCDart primitive, behind an `@extern` — which is a category `OSCORTEX_SPEC.md` §5
already has five entries in, and is why this is a *narrow* workaround rather than a general escape
hatch. `tests/conformance/m5-pci/run.sh` asserts the exact opcode bytes (`ed`, `ef`) so a silent
narrowing to `ec`/`ee` fails at the object file rather than on hardware nobody here owns.

**What would close it, narrowly:** `Port.outl`/`Port.inl` and `Port.outw`/`Port.inw` in DCDart —
ADR-0029's existing lowering path at two more widths, not a new subsystem and not general inline asm.
When they land, `portio.S` is deleted and the two `@extern` declarations in `core/kernel/pci.dart`
become `Port` calls. The deletion is mechanical by construction: the assembly deliberately contains
the *instruction* and no protocol, so there is nothing in it to port.

**Cost of the workaround:** one more assembly object in the build (four now: `boot.S`, `isr.S`,
`kdata.S`, `portio.S`), four more declared externs on `kmain.o` (29 at M5, was 24 at M4 — the fifth
new one is `fb_state_addr`, which is GAP-0053 rather than this entry), and a seam where a reader has
to know that `pciRead32`'s port accesses are 32-bit and `vbeWrite`'s are 16-bit even though every
other port access in this kernel is 8-bit.

---

## GAP-0067 — What PCI enumeration does NOT do, listed rather than discovered later

**Domain:** kernel (M5)
**Status:** OPEN — deliberately scoped out. Every item is absence, not wrongness: nothing below is
mis-reported, it is simply not attempted.

`core/kernel/pci.dart` finds devices and prints them. That is the whole of it.

1. **Nothing is retained.** The scan prints as it walks and keeps no device list, exactly as
   `mbReport` keeps no memory map, and for exactly the same reason: DCDart has no mutable static data
   (GAP-0053) and this kernel has no allocator. **This is why M5 cost zero donated `.bss`**, which
   `m5-pci/run.sh` asserts — and it is also the bill. A later driver that wants "the NIC I found" has
   to walk the bus again to find it, and two subsystems that both want a device will each walk it.
   A device table is the same donated-storage decision the physical memory manager is blocked on, and
   building it here would have prejudged that decision (ADR-0008 §6).

2. **Configuration space is read-only.** No `port_outl` to `0xCFC` anywhere. That rules out, today:
   enabling memory or I/O decoding in the command register, setting the bus-master bit (needed by
   every DMA-capable device), BAR *sizing* (write all-ones, read back the mask, restore), and
   assigning a BAR at all. On QEMU the firmware has already done all of this, which is precisely why
   it is easy to not notice that the kernel cannot.

3. **BARs are not read or printed.** Deliberate at M5: without item 2 there is no way to verify a BAR
   is decoded, and printing an address the kernel cannot use would suggest more than is true.

4. **No capability list.** Offset `0x34` is not followed, so MSI/MSI-X, PCIe capabilities and power
   management are all invisible. Every modern interrupt path for a PCI device starts there.

5. **No ECAM/MMCONFIG.** Mechanism #1 reaches only the first 256 bytes of configuration space; PCIe's
   extended 4KiB space needs the memory-mapped window whose base comes from the ACPI `MCFG` table,
   and this kernel has no ACPI parser at all. On a machine with no legacy mechanism #1 — increasingly
   plausible — `pci` would print `PCI NONE` and be right to.

6. **The two port accesses in `pciRead32` are not atomic.** An interrupt handler that also touched
   `0xCF8` between the `outl` and the `inl` would make this read the wrong register. Nothing in this
   kernel does — the only unmasked line while a command runs is IRQ1, and `kbdHandle` touches `0x60`
   and `0x64` only — so the hazard is real in principle and absent in fact. Fixing it properly needs
   a lock, and this kernel has no concurrency to lock against yet; wrapping it in `cli` would stop
   the keyboard for the duration of a bus walk to defend against a handler that does not exist.

7. **Bridge recursion is depth-capped at 4 and bus-monotonic.** Both guards are real (a bus number
   read out of a device register drives the recursion, and there is no stack guard page — GAP-0007),
   and the cap means a legitimately deeper hierarchy would be silently truncated. Nothing would say
   so. A worklist instead of recursion needs storage — see item 1.

8. **No device is *driven*.** The e1000 and the IDE controller are found and named and then left
   alone. That is the next milestone's problem, not a defect in this one.

---

## GAP-0068 — `dcc` cannot compile a nested `while` loop

**Domain:** kernel (M5, M6, M7), DCDart-side language gap
**Status:** **RESOLVED AND ADOPTED AT M7.** `DCDART_PIN.txt` moved from `9e836a3` to `e3cfe18` for
the physical memory manager, and `core/kernel/pmm.dart` contains two genuinely nested `while` loops:
`pmmInit`'s memory-map walk (entries outside, frames inside) and `shellFramesTest`'s pairwise
distinctness proof. This entry's own prediction — "a page-table walk and a **memory-map merge** are
each naturally a loop inside a loop" — named the milestone that would need it, one milestone early.

**How the pin bump was verified, because a pin bump is a toolchain migration.** An isolated clone of
DCDart at `e3cfe18` was mirrored beside a copy of this repo (GAP-0003 fixes the sibling layout, so
the layout has to be reproduced rather than pointed at), and **all eight pre-existing harnesses were
run against it with the kernel unchanged, before any M7 code was written: 8/8.** One run failed on a
QMP ephemeral-port collision — `Address already in use`, not a kernel fault — and passed on re-run.
The same eight, plus m7-frames, pass against `e3cfe18` after the milestone.

**Only that far, deliberately.** Three DCDart commits were available past `9e836a3`. `ff9aa89`
(instance methods) came along for the ride as an ancestor and is unused. `b3f0ed9` (word/doubleword
port I/O) was NOT taken: it deletes `core/boot/portio.S` outright and rewrites M5's and M6's port
access, which is a different unit's work and would have mixed a toolchain migration into an
allocator. `fbd21e4` (compile-time folding in sized-int literals) was not taken either, and its
absence cost two named constants — GAP-0077.

**The three decompositions below are still in the tree and were NOT undone.** `pciScanFunctions1To7`,
`fbFillRow` and `ataDumpLine` still exist as separate functions. Rewriting three working, tested
subsystems to inline them would have put unrelated churn in an allocator milestone; they are now
optional cleanups rather than forced workarounds, which is a different status and is why the present
tense below is left as it was written.

**Worth recording about the fix itself, because the lesson generalises:** the refusal was never
protecting against a real hazard. `_lowerWhile` declined to nest with a well-written comment naming
a plausible one — that the carried-variable analysis would be scoped to the wrong loop — but the
candidate filtering already made that impossible. It survived eleven ADRs *because the comment was
good enough to read as a settled decision.* The kernel-side lesson: a `dcc-lower` message saying
something is "not supported yet" is a report to be checked, not a fact to be designed around.

`dcc build` rejects a `while` inside a `while` with

```
DccLowerError: "pciScanBus": nested while-loops are not supported yet
```

which is a clear, named error rather than a miscompile — the good half of this. It was hit for the
first time by `core/kernel/pci.dart`, whose natural shape is a function loop (0..7) inside a device
loop (0..31) inside a bus walk.

**The workaround** is to make each inner loop its own `@bare` function: `pciScanFunctions1To7` exists
only because it cannot be four lines inside `pciScanDevice`. Sequential loops in one function are
fine, and `pciFindName`'s two passes prove it; it is specifically nesting that is rejected.

**Why it is recorded even though the result reads well.** The decomposed version is arguably clearer
than the nested one, and that is the trap: nothing in the source says a compiler limitation chose it,
so the next author hits the same error and re-derives the same workaround. And the cost is not
constant — a scroll-by-pixel-row blit, a page-table walk, a memory-map merge and a matrix operation
are all naturally two nested loops over an index pair, and splitting those pushes loop-carried state
through a parameter list.

**What would close it:** loop lowering in `dcc-lower` that does not assume one loop per function
body. A DCDart-repo change (CLAUDE.md rule 3), filed here because that is where language needs are
recorded.

**IT HAPPENED AGAIN IN THE SAME MILESTONE, in exactly the place this entry predicted.** M5's second
half needed to fill a rectangle of pixels — a loop over x inside a loop over y, which is as
irreducibly two-dimensional as code gets. `fbFillRow` exists for the same reason
`pciScanFunctions1To7` does, and this time the decomposition is not "arguably clearer": it splits a
single conceptual operation across a call boundary because the compiler cannot express it. Two
instances in one milestone, in unrelated subsystems, is the argument for fixing it upstream rather
than a coincidence.

**IT HAPPENED A THIRD TIME AT M6.** `ataDumpLine` (`core/kernel/ata.dart`) exists only because the
inner loop over eight words cannot sit inside `ataDumpSector`'s loop over thirty-two lines. Three
instances, three unrelated subsystems, three milestones — and this one is the mildest, which is why
M6 shipped on the old pin rather than bumping it (ADR-0010 §6). A multi-sector `READ SECTORS` would
be a fourth and would not be mild: the outer loop carries the sector index and the inner loop is the
256-word transfer (GAP-0074 item 4).

**Cost of the workaround today:** three extra functions and three paragraphs of explanation.

---

## GAP-0069 — m3-shell's and m4-fault's goldens were regenerated at M5, deliberately

**Domain:** test (M5)
**Status:** RESOLVED-BY-DECISION — recorded so the change is a documented act rather than a mystery
in a diff, exactly as GAP-0059 (M3) and GAP-0065 (M4) did before it.

`help` lists what the shell can do, and M5 added **two** commands to the shell, so `shellStrHelp`
grew from 395 bytes to **498** — `  pci           enumerate the PCI bus` and
`  fb            framebuffer console: BAR0, 800x600x32, 8x16 font`. Both m3-shell and m4-fault run
`help` inside their sessions, so both goldens moved.

**What was preserved, mechanically rather than by assertion:**

- **M1's 544-byte golden did not move by one byte.** m2-console, m3-shell, m4-fault and now m5-pci
  all still check it as a byte-exact prefix of their own captures.
- **Neither key sequence changed.** m3-shell's and m4-fault's sessions are the same elements making
  the same claims about backspace, arrows, `mem`, `ticks`, both fault vectors and the fault counter.
- **The diff was checked, not assumed.** Old and new goldens were diffed: m3-shell's serial capture
  gains exactly two lines, twice (its session runs `help` twice); m4-fault's gains exactly two lines,
  once. The screen goldens shifted by the same amount. Nothing else in any of the four files
  changed.
- **m2-console's goldens did not move at all**, because its session never runs `help` — the same
  reason they did not move at M4.
- **`shellStrHelp`'s size check moved 395 → 498 in both harnesses**, in the same edit as the goldens.
  That check exists because GAP-0060 bit at M4 in exactly this way, and it is the check that would
  have caught it: the table and its one hand-maintained call-site literal are now cross-checked in
  three harnesses.

**Cost:** ADR-0006's "1691 bytes" and ADR-0007's "2260 bytes" both now disagree with the files
(2213 and 2363). Those ADRs are historical records and were not rewritten; this entry, GAP-0065 and
GAP-0059 are the chain that explains the discrepancy.

---

## GAP-0070 — What the framebuffer console does NOT do, listed rather than discovered later

**Domain:** kernel (M5)
**Status:** OPEN — deliberately scoped out. `docs/decisions/0009-framebuffer-console.md` is the
record of what WAS built.

`core/kernel/fb.dart` finds a display controller by PCI class, reads BAR0, sets 800x600x32 through
the Bochs VBE interface, and blits 8x16 glyphs. Everything below is absent rather than wrong.

1. **No scrolling. The console fills up and stops.** Once the cursor passes row 37 every further
   character is dropped: the framebuffer keeps its first 37 lines and freezes. GAP-0054 item 3
   predicted exactly this wall and it arrived exactly as predicted — a pixel-row scroll of a
   800x600x32 screen is a **1.9MiB** move, DCDart has no `memcpy`, no array type and no intrinsic,
   and doing it through `Pointer<u32>` a pixel at a time is roughly **467,000 volatile load/store
   pairs per line scrolled**. The two cheaper-looking shapes were rejected as worse: overwriting the
   last row forever, and wrapping to the top, both produce a screen that looks like a corrupted one
   rather than a full one. Stopping looks like what it is.

   *What would fix it properly:* a `memcpy`/`memmove` primitive in DCDart (a DCDart-repo decision,
   CLAUDE.md rule 3), or a hardware scroll via the dispi Y-offset register — which is genuinely the
   right answer for this device and needs a ring-buffer discipline over the framebuffer that this
   console does not have.

2. **The Bochs VBE interface is not portable, and it is the only mode-set path here.** `0x1CE`/
   `0x1CF` is implemented by QEMU's std VGA, by Bochs, and by very little else. On real hardware the
   equivalents are VBE 2.0/3.0 real-mode BIOS calls (unreachable from long mode without a v8086
   monitor or an emulator), a UEFI GOP handle (which needs a UEFI boot), or a device-specific
   modesetting driver (which is what a real graphics driver *is*). This kernel checks the dispi ID
   register and prints `FB NOVBE` rather than pretending — but "prints an honest error on every real
   machine" is still the situation.

3. **The mode is fixed and unnegotiated.** 800x600x32, always. The dispi VRAM-size register (index
   0x0A) is not read, so the mode is chosen to be small enough (1.9MiB) that any configuration this
   device ships with can hold it, rather than chosen to fit what is actually there. There is no mode
   list, no fallback to a smaller mode, and no way to ask for a different one.

4. **No way back to text mode.** There is no `fb off`. Returning the adapter to mode 3 means
   programming the sequencer, CRTC, graphics and attribute controllers, which is a much larger piece
   of device programming than setting a dispi mode — and see GAP-0071 for why it matters that the
   text buffer is gone until you do.

5. **One colour pair, no attributes, no cursor.** Light grey on near-black, compiled in. No
   per-character colour, no bold, no reverse video, and no drawn cursor block — the text console's
   CRTC hardware cursor has no equivalent here, so there is nothing on screen showing where the next
   character will go.

6. **No double buffering and no tearing control.** Glyphs are blitted straight into the scanned-out
   framebuffer. Invisible at this rate; it stops being invisible the moment anything animates.

7. **Every pixel is an individual volatile 32-bit store.** One glyph is 128 of them, so a full line
   of text is ~12,800. That is the same "DCDart has no memcpy" problem as item 1 wearing everyday
   clothes, and it is why `fbFill` (480,000 stores) is noticeable even under emulation.

8. **The font is `0x20`..`0x7E` and nothing else** — no accents, no box drawing, no code page. Every
   other byte draws the fallback box. That is deliberate and is asserted (`check-font.py` requires
   the fallback to be non-blank), but it means this console cannot render text most of the world
   writes in.

---

## GAP-0071 — Two things the framebuffer work touched that are not safe, only sufficient

**Domain:** boot, kernel (M5)
**Status:** OPEN — both are known-unsafe simplifications, recorded with what they would cost to fix.

**1. The 3–4GiB identity map is a mapping, not a memory policy.**

`core/boot/boot.S` now fills a second page directory with 512 huge pages covering `0xC0000000`..
`0xFFFFFFFF`, because that is where a PC's firmware puts BARs and the framebuffer is at
`0xFD000000`. What that mapping is:

- **writable, present, and identity** — with no permission distinction of any kind, which is the same
  situation the rest of the image is in (GAP-0050: one RWX segment);
- **cacheable**, with no MTRR or PAT setup. For MMIO in general that is wrong — a device register
  read must not be served from a cache line — and for a *linear framebuffer* specifically it is
  benign and even desirable. This kernel maps the whole gigabyte the same way, so the moment it
  touches a real device register through a BAR rather than a framebuffer, this becomes a correctness
  problem rather than a performance note. Under QEMU/TCG nothing notices either way, which is exactly
  why it is written down here instead of being discovered on hardware;
- **unconditional.** The pages are mapped whether or not anything is there. A stray pointer into
  3–4GiB now silently succeeds where it used to fault.

*What would fix it:* PAT/MTRR configuration for the framebuffer range, and page-table entries created
on demand rather than up front — which needs a page-table walker and somewhere to get new tables
from, i.e. the physical memory manager (M7 — it was M6 until the disk driver took that number; see ROADMAP.md).

**2. `0xB8000` is an APERTURE, and a graphics mode repoints it — measured, not assumed.**

The first M5 build wired the framebuffer in as a **third** output path (serial, then the text buffer,
then the framebuffer). The 80x25 text buffer read back out of guest physical memory afterwards came
back as **2000 cells of pixel data**. The legacy text window is not separate memory; it is a window
into the adapter's own video RAM, and enabling a VBE mode changes what it exposes. Continuing to
write it after the mode set does not keep a second console alive — it scribbles two bytes into the
middle of the framebuffer for every character printed.

So `conPutc` writes COM1 and then **exactly one** screen, chosen by whether a framebuffer has been
brought up. Consequences, stated plainly:

- **The VGA text console is not removed or regressed.** It is what every boot uses, including all six
  pre-M5 harnesses, until something deliberately switches the adapter. `m5-pci/run.sh` asserts the
  text buffer byte-for-byte on a boot that does not run `fb`.
- **After `fb`, there is no text console**, and there is no way back (GAP-0070 item 4). A machine
  whose framebuffer console has filled up (item 1) and whose text console is gone has serial and
  nothing else — which is the third time in this project that COM1 being primary
  (`OSCORTEX_SPEC.md` §3) has quietly been the thing that saved a milestone.
- **This generalizes.** Any future driver that touches a legacy aperture — the VGA planes, the BIOS
  data area, an ISA hole — is looking at a window whose meaning depends on device state, not at
  memory. It is the same class of mistake as assuming a BAR is at a fixed address.

---

## GAP-0072 — m3-shell's, m4-fault's and m5-pci's goldens were regenerated at M6, deliberately

**Domain:** test (M6)
**Status:** RESOLVED-BY-DECISION — recorded so the change is a documented act rather than a mystery
in a diff, exactly as GAP-0059 (M3), GAP-0065 (M4) and GAP-0069 (M5) did before it.

`help` lists what the shell can do, and M6 added **two** lines to it, so `shellStrHelp` grew from
498 bytes to **621**:

```
  disk id       ATA PIO IDENTIFY: model and sector count
  disk read <n> read one 512-byte sector, hexdumped as it arrives
```

m3-shell, m4-fault and m5-pci all run `help` inside their sessions, so all three serial goldens
moved. m3-shell's *screen* golden moved too, because its session leaves the help listing on the
80x25 screen; m4-fault's and m5-pci's screen goldens did **not**, because both `clear` afterwards.

**The alternative was considered and rejected.** Leaving `disk` out of `help` would have kept three
goldens frozen and made the command undiscoverable — and m5-pci's own harness header says exactly
this about `pci`: *"the listing, which now has to mention `pci` or the command is undiscoverable."*
A command the shell will run and will not admit to is worse than a regenerated golden.

**What was preserved, mechanically rather than by assertion:**

- **M1's 544-byte golden did not move by one byte.** m2-console, m3-shell, m4-fault, m5-pci and now
  m6-disk all still check it as a byte-exact prefix of their own captures.
- **No key sequence changed.** All three sessions are the same elements making the same claims.
- **The diff was checked, not assumed.** Each old/new golden pair was diffed before the new one was
  installed: m3-shell's serial gains exactly two lines twice (its session runs `help` twice) and its
  screen golden gains exactly two lines; m4-fault's and m5-pci's serial captures gain exactly two
  lines once each and their screen goldens are byte-identical. **Nothing else changed in any of the
  five files** — no PCI line, no fault line, no memory-map figure.
- **`shellStrHelp`'s size check moved 498 → 621 in all three harnesses**, in the same edit as the
  goldens, and m6-disk adds a fourth copy of it. That check exists because GAP-0060 bit at M4 in
  exactly this way.
- **m2-console's goldens did not move at all**, because its session never runs `help` — the same
  reason they did not move at M4 or M5.

**Cost:** the byte counts quoted in ADR-0006, ADR-0007 and ADR-0009 now disagree with the files
again. Those ADRs are historical records and were not rewritten; this entry and its three
predecessors are the chain that explains the discrepancy. That chain is now four links long, which
is itself the finding: **any milestone that adds a command rewrites every golden that runs `help`.**
The fix is not to stop adding commands — it is that `help` output is derived data that a harness
could render from the command table if this language had one (there is no table; dispatch is an `if`
chain, because DCDart has no function pointers — ADR-0006).

---

## GAP-0073 — The ATA driver's waits are bounded by an ITERATION COUNT, not by time

**Domain:** kernel (M6)
**Status:** OPEN — a deliberate, narrow limitation. The important half (unbounded → bounded) is
done; what is missing is that the bound is not a duration.

`ataWait` (`core/kernel/ata.dart`) polls the status register at most `ataPollLimit` = 2²¹ times and
then gives up, returning `0x100 | lastStatus` so the caller prints `DISK ERR TIMEOUT Pn ST xx`. That
closes the hazard GAP-0058 names — a wedged device is a **loud** failure rather than a silent hang —
and `m6-disk/run.sh` disassembles `ataWait` to check the bound is still in the compiled code.

**What it is not:** a timeout. A wall-clock bound needs a clock, and the only one this kernel has is
the PIT, which is **masked at rest** so that `ticks` can report a reproducible number (GAP-0058
again). Unmasking it to time a disk command would make every `disk` command's duration
host-dependent, and a duration cannot appear in a byte-exact golden.

**What that costs, concretely:**

- The bound means different things on different machines. Under QEMU each iteration is one VM exit
  and the whole budget is a fraction of a second; on real hardware an ISA-speed `in` is roughly a
  microsecond, so 2²¹ iterations is on the order of **one second**.
- One second is ample for any command this driver issues to a drive that is already spinning, and is
  **not** ample for a drive spinning up from cold, which the ATA specification allows to take up to
  31 seconds. This driver never issues a reset and never runs at power-on, so it does not meet that
  case today — but a driver that did would have to raise this number blindly rather than wait
  properly.
- A faster CPU polls faster and therefore times out *sooner in wall-clock terms*. The bound is
  anti-correlated with the thing it is trying to bound, which is the opposite of what a timeout does.

**What would close it:** a monotonic time source that does not depend on an unmasked interrupt —
`rdtsc` with a calibrated frequency, or the PIT read back through its latch command rather than
through its IRQ. Both are small; neither is free, and `rdtsc` needs a DCDart primitive it does not
have (the same category as `cpuid`, OSCORTEX_SPEC §5).

---

## GAP-0074 — What the ATA driver does NOT do, listed rather than discovered later

**Domain:** kernel (M6)
**Status:** OPEN — deliberately scoped out. Every item is absence, not wrongness: nothing below is
mis-reported, it is simply not attempted, and every failure path this driver *can* reach prints a
diagnostic naming a value it read out of the hardware.

1. **It cannot RETURN a sector, and this is the structural one.** `disk read` hexdumps each word as
   it arrives and forgets it. There is no `read(lba) -> bytes` because there is nowhere for 512
   bytes to go: DCDart has no mutable statics, no array type, and this kernel has no allocator
   (GAP-0053). **This driver can show you a sector and cannot give you one.** A filesystem, a
   partition table parse, a boot-sector check and a block cache are all the same missing thing, and
   they are all waiting on the same decision the physical memory manager is waiting on. It cost zero
   donated `.bss` — and, exactly as with `pci` (GAP-0067 item 1), that is the bill rather than the
   win.

   **M7 UPDATE (2026-08-21): the stated reason for this item is no longer true, and the item is
   still open.** "There is nowhere for 512 bytes to go" was accurate when it was written. There is
   now: `allocFrame()` returns a 4KiB physical frame, and a sector is 512 bytes. `disk read <lba>`
   into an allocated frame — `Pointer<u16>.fromAddress(frame + offset)` in the transfer loop instead
   of `ataDumpLine` — is **writable today with no new language feature and no new donated storage**,
   and nobody has written it. That is a much smaller statement than this item used to make, and the
   honest version of it is: *the driver still cannot give you a sector because nobody has changed
   it, not because the kernel cannot hold one.*

   What M7 does **not** give this item is a way to say what the 512 bytes *are*. A frame is a
   physical address, not a typed buffer; `@bare` DCDart still has no array type, so a filesystem
   that wants to read a directory entry out of that frame is doing pointer arithmetic on a `u64`.
   See GAP-0076 item 2 — that is the boundary between "a physical memory manager" and "an
   allocator" in the sense a program would use, and M7 is deliberately only the first one.
2. **Primary master only.** The secondary channel (`0x170`/`0x376`) and the slave device on either
   channel are not probed. A machine whose disk is the slave, or is on the secondary channel, reports
   `DISK ERR NODEV ST 00` — correctly, and unhelpfully.
3. **Read only.** There is no `WRITE SECTORS`, and adding one is not symmetric with reading: a write
   needs the data to come from somewhere, which is item 1 again.
4. **LBA28 only, one sector at a time.** No LBA48 (so no address above 128GiB), and no multi-sector
   transfers — `disk read` sets the count to 1 every time. Nested `while` loops would make a
   multi-sector loop natural (GAP-0068), which is a second reason the pin bump is worth taking.
5. **No ATAPI.** A CD-ROM is detected (`DISK ERR NOTATA SIG EB14`) and refused, deliberately: ATAPI
   is a SCSI command set tunnelled over the same registers, and pretending otherwise would report a
   failed read of something that was never a disk.
6. **No reset, and therefore no recovery.** There is no `SRST` and no re-initialisation path. If the
   channel wedges, every subsequent `disk` command fails the same way until reboot. The failure is at
   least loud (GAP-0073) — the kernel says so and the shell keeps its prompt — but "the driver
   noticed" and "the driver recovered" are different claims and only the first one is true.
7. **Polled, never interrupt-driven.** IRQ14 is masked at the drive (`nIEN`) and could not be
   delivered anyway (the slave 8259 is fully masked at rest). A 512-byte PIO read holds the CPU for
   the whole transfer with no yield; nothing else can run. With no scheduler, nothing else wants to
   — but this is the shape that a scheduler would have to undo.
8. **Nothing is remembered between commands.** `disk read` re-selects the drive and re-issues the
   whole sequence every time, including the 400ns settle. There is no notion of "the drive I
   identified" — the same re-derivation `pci` and `mem` both do, for the same reason.
9. **The 400ns settle is four port reads, which is an approximation.** It is the idiom every ATA
   driver uses and it assumes an ISA-speed port access is ~100ns. On a modern machine a port access
   is much slower than that, so the delay is conservative; on some future faster path it would not
   be. There is no calibrated delay to use instead (GAP-0073).

---

## GAP-0075 — m3-shell's, m4-fault's, m5-pci's and m6-disk's goldens were regenerated at M7, deliberately

**Domain:** kernel (M7), conformance
**Status:** RECORDED — the fifth link in a chain that is itself the finding.

`help` gained **six lines** at M7 (`frames`, `frames test`, `frames drain`, `frames refill`, `alloc`,
`free <addr>`), so `shellStrHelp` went **621 -> 1028 bytes** and every golden that types `help`
moved with it. Four serial goldens and one screen golden changed:

| Golden | Bytes before | Bytes after |
|---|---|---|
| `m3-shell/expected.txt` | 2459 | 3273 (two `help` blocks) |
| `m4-fault/expected.txt` | 2486 | 2893 |
| `m5-pci/expected.txt` | 2270 | 2677 |
| `m6-disk/expected.txt` | 6780 | 7187 |
| `m3-shell/expected-screen.txt` | 25 rows, 8 blank at the bottom | 25 rows, 2 blank |

**How they were regenerated, because "regenerated" is where a bug hides.** Not by copying a capture.
The four serial goldens were transformed **mechanically**: the exact 621-byte `help` block was
replaced by the exact 1028-byte one, by a script that asserted how many times the old block occurred
in each file and changed nothing else. The kernel then had to reproduce the result byte-for-byte, and
did. That is a stronger check than reading a diff: a capture that had drifted anywhere *else* would
have failed.

`m3-shell/expected-screen.txt` was transformed the same way, with the extra assertion that the six
rows pushed off the bottom of the 25-row window were blank — so no content was silently truncated.

**m1-interrupts' 544-byte golden did not move and must never move for this reason.** It ends at the
newline after `M1 END`, before any shell exists. It was re-verified byte-for-byte identical.

**The chain, which is the actual finding.** GAP-0059 (M3), GAP-0065 (M4), GAP-0069 (M5), GAP-0072
(M6) and now this. **Five milestones, five regenerations, every one caused by `help` growing.** Every
byte this kernel prints is in a byte-exact golden, `help` lists every command, and a command that is
not in `help` is undiscoverable — so adding any command necessarily moves every golden that types
`help`. The cost is not the regeneration; it is that a *real* regression in one of those captures
would arrive in the same commit as a legitimate diff, and the only thing separating them is that the
diff was checked. Mechanically transforming rather than re-capturing is this project's answer so far,
and it is a mitigation rather than a fix.

**What would close it:** a `help` whose text is generated from the command table rather than being a
literal — which needs a command table, which needs function pointers, which `@bare` DCDart does not
have (GAP-0057). Or goldens that assert everything *except* the `help` block, which trades a real
assertion for convenience and should not be done.

---

## GAP-0076 — What the frame allocator does NOT do, listed rather than discovered later

**Domain:** kernel (M7)
**Status:** OPEN — deliberately scoped out. Every item is absence, not wrongness: nothing below is
mis-reported, and every operation the allocator refuses prints a status naming the reason.

1. **It allocates ONE frame at a time, and there is no contiguous multi-frame request.** `allocFrame()`
   returns one 4KiB frame. A DMA landing buffer, a larger-than-page structure and a 2MiB huge page all
   need N *adjacent* frames, and asking for them is a different search (and, done properly, a
   different data structure). Nothing in this kernel needs it yet; the first thing that will is
   bus-master DMA, which needs much more than an allocator anyway (ADR-0010).
2. **It returns a `u64`, not memory.** There is no `alloc(n) -> typed memory` and there cannot be one
   today: `@bare` DCDart has no array type, no String, and no type a heap allocation could be returned
   *as*. **This is the honest boundary between "a physical memory manager" and "an allocator" in the
   sense a program would use.** Callers get a physical address and do `Pointer<T>.fromAddress` on it,
   which is exactly as unchecked as it sounds.
3. **No virtual memory.** Nothing maps anything at runtime. `core/boot/boot.S`'s identity map IS the
   address space — 0..128MiB plus 3..4GiB for the PCI hole — and the allocator's bound is pinned to it
   (ADR-0011 §2). A frame allocator is a *prerequisite* for paging (page tables have to come from
   somewhere) and this is that prerequisite, not paging itself.
4. **The bound is 128MiB and a bigger machine is capped, not managed.** Counted and reported as
   `OVER nnnnnnnn CAPPED`, never silently. Raising it is linear in `.bss` and in page-directory
   entries.
5. **No zeroing.** `allocFrame()` hands back whatever the frame contained. Every future user that
   cares — page tables, in particular — must zero it, exactly as `boot.S` already zeroes its four
   page-table pages by explicit address range. A zero-on-free policy was rejected as 4KiB of stores
   per free with no caller that needs it yet.
6. **No accounting beyond counts.** The allocator knows how many frames are free; it does not know
   who has one. There is no owner, no tag, no leak detection. `frames drain` exists because "allocate
   everything and see" is the only whole-system question this bookkeeping can answer.
7. **Not reentrant, and not interrupt-safe.** `allocFrame` and `freeFrame` read-modify-write the
   bitmap and the metadata with no lock and no `cli`. Commands run in task context with interrupts
   enabled (ADR-0006), so an IRQ arriving mid-allocation is possible today; it is harmless only
   because no interrupt handler in this kernel allocates. The moment one does, this is a real race.
   Stated now rather than discovered then.
8. **The memory map is consulted, not cached.** `pmmAllocatable` re-walks the Multiboot structure on
   every call — seven entries, a few loads. Caching it needs somewhere to put a parsed copy, which is
   the same missing thing this milestone closed for *frames* and did not close for *records*
   (item 2). A second copy that could disagree with the first would be a worse bug than a slow loop.
9. **`frames refill` is a test fixture, not a memory-management operation.** "Free everything that was
   ever allocatable" is not something a real system does. It exists so the drain has an inverse that
   goes through `freeFrame`'s real checks 32768 times, which is what makes "the free count returns to
   the baseline" mean something.
10. **The self-test's ledger is 64 entries because 64 is what fits.** 512 bytes of donated `.bss`. It
    is not a limit on the allocator, only on how many frames one `frames test` can hold at once to
    prove them pairwise distinct.

---

## GAP-0077 — `dcc` cannot fold compile-time integer arithmetic inside a sized-int literal

**Domain:** kernel (M7), DCDart-side language gap
**Status:** **RESOLVED UPSTREAM, NOT ADOPTED HERE.** DCDart commit `fbd21e4` ("Fold compile-time
integer arithmetic in sized-int literals", its ADR-0046) fixes it. `DCDART_PIN.txt` is `e3cfe18`,
which predates it.

`u64(pmmFrameBytes - 1)` — a `u64` literal built from two compile-time constants — is rejected:

```
dcc build: DccLowerError: "pmmInit": a Instance of 'DCInt' literal constructed from a non-constant
expression InstanceInvocation(InstanceAccessKind.Instance, 4096.-(1)) (InstanceInvocation) — the
argument must be an integer literal or a compile-time integer constant
```

A clear, named error rather than a miscompile, and it names the function. **The workaround** is to
give every derived constant its own name: `core/kernel/pmm.dart` declares `pmmFrameMask = 4095` and
`pmmFrameLastWord = 4088` next to `pmmFrameBytes = 4096`, with a comment saying why they are spelled
out. Nine call sites use them.

**Cost of the workaround today:** two constants and a paragraph — genuinely small, which is why the
pin was not moved a second time for it. The reason it is recorded anyway is that the cost is *not*
constant: every alignment mask, every `size - 1`, every "last element" offset is this expression, and
a subsystem with several page sizes or several structure layouts would name a dozen of them. The pin
bump is a lookup rather than an excavation now that the commit hash is here.

**Worth noting about the pin discipline itself:** M7 moved the pin exactly as far as the capability it
needed (`e3cfe18`, nested `while`) and no further, even though two later commits were available and
one of them would have removed this entry. Taking a toolchain forward past the thing you verified is
how a pin stops meaning anything.

---

## GAP-0078 — m7-frames' golden is a function of the kernel's own image size

**Domain:** kernel (M7), conformance
**Status:** OPEN — accepted deliberately, with the mitigation that makes it safe.

The allocator reserves the real image extents, `[__kernel_start, __kernel_end)`, read from
`core/link/kernel.ld`. So **adding code to this kernel changes the number of free frames**, and every
count, address and fold in `m7-frames/expected.txt` moves with it: `FREE 00007EC5`, the first
`alloc`'s address, the drain's `TOOK`/`SUM`/`XOR`/`LOW`, the refill's `GAVE`. A future milestone that
adds a page of `.text` will find this golden red.

**This is the reservation being real, not fragility to be engineered away.** The alternative —
reserving a fixed `[1MiB, 2MiB)` — is a guess, is wrong the moment the kernel outgrows it, and
discards information the linker already has. It was rejected in ADR-0011 §8.

**The mitigation, which is the part that matters.** Every number in the golden is *also* recomputed
by `core/tests/conformance/m7-frames/derive.py` from the boot's own `MB E` memory-map lines and from
`__kernel_start`/`__kernel_end` read out of `kernel.elf`. So regenerating the golden **cannot** make a
wrong allocator pass: the derived checks run against the same capture, and they do not care what the
golden says. `run.sh --regen` exists for exactly this and its own comment says it is not a way to make
a red run green.

**Cost:** whoever grows this kernel next has to re-run `m7-frames/run.sh --regen` and read the diff.
That is one extra step, and it is the same step GAP-0075 already imposes for `help`.

**M8 EXERCISED IT, AND ADDED A SECOND REASON THE GOLDEN MOVES.** The image grew by seven frames (the
page-table builder's code and tables, plus up to two pages of the 4KiB section alignment the new link
script needs), and M8 also permanently spends **six** frames on the kernel's own page tables — so
`FREE` went `00007EC5` → `00007EB8`, `ALLOCS` starts at 6 rather than 0, and the first `alloc`, the
drain's `SUM`/`XOR`/`LOW` and the refill's `GAVE` all moved with them. The mitigation held exactly as
written: `derive.py` gained the page-table reservation as a sixth rule and recomputed every one of
those numbers, so the regenerated golden was checked against a derivation rather than blessed. The six
frames are asserted equal to `vm.dart`'s `vmFrameCount` by `m8-paging/run.sh`, so the two cannot
drift.

**M9 EXERCISED IT AGAIN, AND ONLY FOR THE FIRST REASON.** Ring 3 costs ~36KiB of image — a 16KiB
ring-0 stack for RSP0, 104 bytes of TSS, 144 bytes of donated `.bss`, and `core/kernel/user.dart`'s
code and tables — so `__kernel_end` moved by ten frames and `FREE` went `00007EB8` → `00007EAE`. It
spends NO permanent frames of its own: the payload's two come from `allocFrame()` at command time and
go back on every exit, including the three that are faults, which is what `user pages` reporting
`USER 00000000` afterwards is for. `derive.py` needed no new rule. GAP-0087 records the regeneration.

---

## GAP-0079 — LLVM emits a jump table into `.rodata`, and `.rodata` is writable in this image

**Domain:** kernel (M7), toolchain
**Status:** **NARROWED at M8** — the writability is CLOSED (see below); the jump table itself is
still there and still an indirect branch, which is now a statement about `.rodata`'s integrity rather
than about its permissions. The assertion that noticed it remains RESOLVED, and M8 defended it a
second time rather than relaxing it (GAP-0082).

**M8 UPDATE.** Consequence 2 below — "the jump table is an indirect branch through memory this kernel
maps WRITABLE" — is no longer true. `.rodata` is its own `PT_LOAD` with `R` flags and every one of its
pages is mapped RW=0/NX=1 by `core/kernel/vm.dart`, enforced by `CR0.WP` and `EFER.NXE`, and a
deliberate store into it is a reported page fault (GAP-0050, ADR-0012). What remains is the ordinary
observation that a jump table is a branch through data: it cannot be rewritten by a stray kernel
store any more, but it is still the one piece of `.rodata` whose *contents* decide control flow, and
it is still anonymous data the source did not ask for.

`pmmFreeStatus` dispatches on a DENSE `0..5` status code. LLVM lowered the if-chain into a **six-entry
jump table**, placed it in `kmain.o`'s `.rodata` at offset 0 as anonymous data with six `R_X86_64_64`
relocations into `.text`, and reaches it with `jmp *0x0(,%rdi,8)`. Verified by disassembly, not
inferred.

**Two consequences, and the second one is the real entry.**

**1. A structural assertion had to change shape, and it got stronger.** `m1-interrupts/run.sh`
asserted `sum(@rodata table symbol sizes) == .rodata section size` — ADR-0040's promise that a
`@rodata` table is *elements only, no header*. The 48 anonymous bytes broke the equality, and the
check's own comment had pre-authorised relaxing it to `>=`. **Relaxing it would have thrown the
property away.** What ADR-0040 actually promises is a statement about the space *between* tables,
which a total never measured directly, so the check now asserts:

  1. every pair of adjacent table symbols abuts exactly — zero bytes between them;
  2. nothing follows the last table;
  3. whatever precedes the first table is entirely accounted for by `.rela.rodata`, 8 bytes per
     relocation — i.e. it is a relocated jump table and not data masquerading as one. Anonymous bytes
     with no relocations still fail.

A per-table header violates (1) and still fails. This is recorded because **a structural assertion
that moves is exactly the kind of thing that should never move quietly**, and because the easy move
was available and was not taken.

**2. The jump table is an indirect branch through memory this kernel maps WRITABLE.** GAP-0050:
the image is a single RWX `PT_LOAD`, so `.rodata` is writable at runtime. A stray store into that
table redirects a branch. This is **not a new hazard in kind** — `.text` is writable too, so anything
that can rewrite the jump table can rewrite the code it points at — and it is not a reason to contort
`pmmFreeStatus` into something LLVM will not optimise. It is a reason GAP-0050 matters slightly more
than it did: the kernel now has data whose *integrity* is control-flow integrity.

**What would close the writability:** separate `PT_LOAD` segments with real page permissions, which
needs runtime page-table manipulation, which needs a frame allocator to get page tables from. That
prerequisite now exists (M7). GAP-0050 is the entry; this is a note that it acquired a second reason.

---

## GAP-0080 — `CR0.WP` was clear, so read-only page-table entries did not stop a kernel write

**Domain:** kernel, boot (M8)
**Status:** **RESOLVED at M8**, and recorded anyway because the near-miss is the entry.

A page-table entry with `RW = 0` does **not** prevent a write from ring 0 unless `CR0.WP` (bit 16) is
set. Its power-on state is clear, and this kernel had never set it: `boot.S` set `PG` (bit 31) and
nothing else.

**This was measured, not looked up.** With M8's three-segment image linked, the new page tables built
and installed, and `vm` reporting every `.rodata` page as not-writable by *walking the live tables* —

```
VM RODATA 0000000000113000 0000000000115000 P 00000002 W 00 X 00
```

— `vmtest ro` still printed `VM TEST RO SURVIVED -- THE WRITE LANDED`, and the next report showed the
canary as `EFBEADDEEFBEADDE`. Every entry was correct and the CPU was ignoring all of them.

**Why it is worth an entry rather than a commit message.** In the same session `vmtest nx` faulted
correctly, because NX is enforced whatever WP says. A milestone that had tested only the NX half would
have shipped "W^X works" with the W half entirely absent — and every artefact it produced (the program
headers, the page-table dump, the NX fault) would have been genuine. **The enforcement mechanism and
the permission bits are two different things, and only one of them is visible in a page-table dump.**

The fix is one instruction: `boot.S` now ORs `0x80010000` into `CR0` instead of `0x80000000`. It is set
there, with `PG`, because it is a CPU-mode fact like `LME` and `NXE` and has no effect while the
bootstrap tables (which mark everything writable) are live. `vm` prints it back off the register
through `cr0_read()`, and `m8-paging/run.sh` checks it three ways: the instruction is in `boot.S`, the
bit is set in QEMU's `info registers`, and the write faults.

**Cost of the workaround:** none — nothing was worked around. The residual risk is the general one this
entry names: a permission scheme can be entirely correct in the tables and entirely inert in the
machine, and the only test that tells the difference is one that performs the forbidden operation.

---

## GAP-0081 — What the address space does NOT do, listed rather than discovered later

**Domain:** kernel (M8)
**Status:** PARTIALLY RESOLVED at M9. **Item 1 (no user/supervisor separation) is CLOSED**
(`docs/decisions/0013-ring-3-and-the-syscall-boundary.md`, verified by
`tests/conformance/m9-ring3/run.sh`); **item 3 (no map/unmap API) is NARROWED**; items 2 and 4-10 are
still OPEN and item 2's successor list is GAP-0085. Every remaining item is absence, not wrongness:
nothing below is mis-reported, and `vm` prints what is actually mapped rather than what was intended.

1. ~~**No user/supervisor separation.**~~ **RESOLVED at M9.** There is a ring-3 code and data
   descriptor at DPL 3, a TSS with a real RSP0 loaded by `ltr`, an `int 0x80` gate at DPL 3, and
   `vmMapUser`/`vmClearUser` to set and clear U/S on a leaf. The `USER`/`SUPER` field has now printed
   both of its values — `PF CR2 ... ERR 00000007 PRESENT WRITE USER DATA` is a store from ring 3 into
   kernel `.bss`, refused by the hardware, with the target word verified unchanged afterwards. What
   M9 does NOT add is a process: the payload runs on the kernel's own PML4 with two pages temporarily
   user-accessible. See ADR-0013 and GAP-0085.
2. **One address space, and it is the kernel's.** There is one PML4, built once at boot. No second
   `CR3`, no per-process mapping, no address-space switch on a context switch — because there are no
   processes and no context switches.
3. **NARROWED at M9, and only narrowed.** `vmInit` still installs a whole address space once, but it
   is no longer true that nothing edits a mapping: `vmMapUser(va, exec)` and `vmClearUser(va)` flip
   the U/S bit and the W/NX pair of a leaf that ALREADY EXISTS inside the 4KiB window, and they
   invalidate (item 4, and GAP-0083, are consequently narrowed too). They cannot create a mapping,
   choose an address, or allocate a page table, which is why the general `map(va, pa, flags)` /
   `unmap(va)` is still unbuilt — the narrow pair is everything M9 needed and a much smaller claim.
4. **PARTIALLY RESOLVED at M9: `invlpg` exists, shootdown does not.** M9 is the thing that edits a
   live mapping, so `tlb_invlpg` was built and both `vmMapUser` and `vmClearUser` use it. TLB
   SHOOTDOWN — the IPI protocol — is still absent and still needs more than one CPU to matter.
5. **No demand paging, no swap, no copy-on-write, no lazy allocation.** Every page that will ever be
   mapped is mapped at boot.
6. **Page 0 is mapped, and there is no guard page below the stack.** Leaving page 0 unmapped is a free
   null-pointer trap and was not taken, because this milestone's brief was to preserve the identity
   mapping the kernel already depends on and a guard page is a separate claim needing its own test.
   Both are cheap and both are unclaimed.
7. **The 4KiB window is 4MiB and the image must fit in it.** Permissions can only change at a page
   boundary, so every section boundary has to be inside 4KiB-page territory. `vmInit` REFUSES (status
   `TOOBIG`) rather than mis-mapping if `__kernel_end` ever passes 4MiB, and `m8-paging/run.sh` checks
   it at build time so the refusal is a diagnostic rather than a silent `READY 0`. Raising it is
   mechanical: `vmFineBytes` and `vmFrameCount` move together, one more frame per 2MiB.
8. **`[128MiB, 1GiB)` is unmapped on purpose, and that is a behaviour change from the bootstrap map.**
   boot.S mapped the whole gigabyte; vm.dart maps only what the allocator manages, so an access above
   the bound now faults instead of silently writing into RAM nothing tracks. Anything that assumed the
   old map reaches further will find a page fault rather than a wrong answer, which is the intended
   direction.
9. **`.rodata` is protected from the kernel's stray pointers, not from a type error.** DCDart's
   `Pointer` still carries no const-ness and DC-IR still has no verifier, so a store into a constant
   global is still expressible and still compiles. It is now a fault instead of silent corruption —
   which is the whole difference M8 buys — but catching it before it runs is DCDart's side of the same
   problem.
10. **The self-check is a spot check, not a proof.** `vmSelfCheck` walks the new tables for the
    fourteen-odd addresses the kernel is standing on before writing `CR3`. It does not walk all 1600
    pages, and it cannot check the one thing that would matter most — that nothing ELSE the kernel will
    later touch is unmapped. The harness's full page-by-page walk covers that from outside; the kernel
    itself does not.

---

## GAP-0082 — A `@rodata` table accessed through a wider pointer acquires that width's alignment, and opens a hole

**Domain:** kernel (M8), toolchain
**Status:** OPEN (the toolchain behaviour); avoided rather than worked around (the kernel does not
provoke it).

`@rodata` tables are emitted 1-byte aligned and pack against each other with no padding. That is the
observable form of DCDart ADR-0040's "a table is elements only, no header" promise, and
`tests/conformance/m1-interrupts/run.sh` asserts it table-by-table: every adjacent pair must abut
exactly, nothing may follow the last table, and anything preceding the first must be wholly accounted
for by `.rela.rodata`.

Writing M8's canary through a `Pointer<u64>` gave that ONE table 8-byte alignment — no other 8-byte
table in the image moved, so it is the access width and not the size that does it — and the resulting
five-byte hole failed the abutment assertion:

```
5 byte(s) between the end of the previous table and vmCanary at 0x13c0 --
a per-table header or padding appeared
```

**The check was not relaxed.** GAP-0079 already records that this assertion had to change shape once
and that the easy weakening was refused; weakening it again to accommodate a test's convenience would
have thrown the property away for nothing. The deliberate write in `vmTestRo` was made **byte-wide**
instead, which is also the more faithful statement of the hazard — `table[0] = x` is what a stray
pointer into a byte table actually does — and the alignment went back to 1.

**Cost of the workaround:** one byte instead of eight, in one test. Genuinely nothing today.

**Why it is recorded anyway:** the day something legitimately needs a wide access to a `@rodata` table
— a `u64` constant pool, a relocation table, a type descriptor read as a word — this assertion will
fail for a good reason, and the fix will be to teach it that a gap explained by the *following*
symbol's alignment is not a header. That is a deliberate change to a safety check and it should be made
by someone who has read this entry, not by someone staring at a red harness.

---

## GAP-0083 — TLB management does not exist, and does not need to yet

**Domain:** kernel (M8)
**Status:** PARTIALLY RESOLVED at M9 — `invlpg` now exists and is used; shootdown does not and still
needs a second CPU. Named at M8 so the first thing that needed it would not discover it as a bug,
which is exactly what happened: `vmMapUser` edits two leaf entries while the CPU is running on the
table they are in, and `core/boot/isr.S`'s `tlb_invlpg` was written for it. See ADR-0013.

`paging_install` is one instruction, `mov %rdi,%cr3`, and it needs no invalidation: writing `CR3`
flushes every non-global TLB entry, and this kernel never enables `CR4.PGE`, so there are no global
pages and the entire old mapping is gone the moment it returns. There is exactly one such write, at
boot.

There is no `invlpg` primitive, no per-page invalidation, and no shootdown protocol. All three become
necessary together the moment anything **edits a live mapping** (GAP-0081 item 3) — and the third one
also needs more than one CPU, which this kernel does not have. Stated now rather than discovered then.

---

## GAP-0084 — The pinned-DCDart verification clone needs `core/frontend/` copied in by hand

**Domain:** tooling, conformance (M7, M8)
**Status:** OPEN — a property of DCDart's repo layout, not something to fix here.

ADR-0011 §7 established the method this project verifies with: an isolated clone of DCDart at
`DCDART_PIN.txt`'s commit, mirrored beside a copy of this repo, because GAP-0003 fixes the sibling
layout and the shared checkout is edited live by other sessions. M8 reused it and hit one step the ADR
did not record.

`git clone` + `git checkout <pin>` is **not sufficient**. DCDart's `.gitignore` excludes
`core/frontend/vendor/` (a ~212MB sparse clone of dart-lang/sdk, per DCDart's own ADR-0005/0007), and
in practice the whole of `core/frontend/` is untracked. Without it, `dart pub get` in `core/dcc` fails
with

```
Because every version of dcc_lower from path depends on kernel from path which
doesn't exist (could not find package kernel at "../frontend/vendor/dart-sdk/pkg/kernel")
```

and every harness then fails at `dcc build` with a wall of "Couldn't resolve the package 'backend'"
errors that look like a toolchain break rather than a missing directory.

**The step:** `cp -Rc <shared>/core/frontend <clone>/core/frontend` (APFS clone-copy, ~7 seconds and no
extra disk), then `dart pub get --offline` in `<clone>/core/dcc`. The vendored SDK is a pinned,
read-only artifact that no session edits, so copying it from the shared checkout does not weaken the
isolation the pinned clone exists for — the isolation that matters is over DCDart's own tracked source,
which the clone gets from the commit.

**Cost of the workaround:** one command, and this entry so the next unit does not spend twenty minutes
diagnosing it as a broken `dcc`.


---

## GAP-0085 — What ring 3 does NOT do, listed rather than discovered later

**Domain:** kernel (M9)
**Status:** OPEN — deliberately scoped out. Every item is absence, not wrongness: nothing below is
mis-reported, and `user` prints what is actually mapped and what actually happened rather than what
was intended.

1. **No per-process address space.** There is still one PML4 and it is the kernel's. A payload runs on
   the kernel's own page tables with exactly two leaves temporarily marked user-accessible, and it is
   handed back the moment the payload exits or dies. **The payload is not a process; it is a privilege
   level with two pages.** A second `CR3`, a per-process table, and a switch on entry and exit are the
   obvious next thing and were deliberately not built: they bring the whole of GAP-0083's TLB question
   with them and they need something to schedule.
2. **No scheduler, no preemption, no processes.** One payload at a time, entered synchronously from a
   shell command, running until it exits or faults. The timer interrupt fires while ring 3 is running
   and returns to it — it does not and cannot decide to run something else.
3. **`user hold` cannot be stopped.** Its payload spins forever and this kernel has no way to kill a
   running program: that needs either preemption (a timer handler that declines to return to ring 3)
   or a scheduler. `user hold` is therefore the LAST command any session can run, which is said out
   loud in its own doc comment, in the shell dispatcher and in this entry rather than left to be
   discovered.
4. **Three syscalls, and two of them exist to be refused.** `exit`, `write` and `whoami`. No `read`, no
   file descriptors, no `brk`, no `mmap`, no way for ring 3 to ask for memory at all. `write` is bounded
   at 128 bytes and only accepts a pointer inside the payload's own two pages.
5. **No ELF loader, no `fork`, no `exec`, no relocation.** A payload is a run of machine-code bytes in
   this kernel's `.rodata`, copied into a frame and jumped to. ADR-0013 §4 explains why building a
   loader to prove a privilege boundary would have made the loader the thing under test.
6. **No SMEP, no SMAP, no PCID, no KPTI.** `CR4.SMEP` would stop the KERNEL executing a
   user-accessible page and `CR4.SMAP` would stop it reading one without `stac`; neither is enabled, so
   the `write` syscall's pointer check is software-only. It is a real check (ADR-0013 §5) and it is the
   only one: a bug in it is not backstopped by hardware the way `.rodata` is backstopped by `CR0.WP`.
7. **The syscall ABI is not DCDart's `@syscall`.** `DCDART_SPEC.md` §2 anticipates `@hosted` code
   reaching `@bare` kernel services across "a syscall boundary, declared with `@syscall`". That is a
   language feature and it exists on neither side. What M9 builds is the MACHINE boundary such a
   declaration would compile down to.
8. **A keystroke typed while a payload runs is dropped.** `shell_state` is 2 for the whole of a
   command, including the part of it that is executing in ring 3, and `kbdHandle` discards keys in that
   state. That is GAP-0055 item 4 (no input queue) reaching a new place rather than a new bug.
9. **The `write` syscall prints straight to the console, with no arbitration.** A payload's bytes and
   the kernel's own diagnostics go down the same UART in whatever order they are emitted. With one
   payload and no preemption they cannot interleave; the moment either of those changes, they can.
10. **A fault taken in the KERNEL while a payload is live still tears the payload down.** `userOnFault`
    reports the CPL it actually read rather than assuming 3, but it reclaims either way — the payload
    is not going to run again in either case. That is the right call for a kernel with no processes and
    the wrong one for a kernel with them, because it would then be reclaiming somebody else's memory
    on the strength of an unrelated fault.

---

## GAP-0086 — `ltr` runs before any IDT exists, so a malformed TSS descriptor is a triple fault

**Domain:** boot, kernel (M9)
**Status:** OPEN — accepted deliberately, with the mitigation that makes it safe.

`ltr` SETS THE BUSY BIT IN THE TSS DESCRIPTOR, which is a write into the GDT, and since M8 the GDT is
in `.rodata` — a read-only page with `CR0.WP` set. M9's first revision called it from DCDart after
`idt_load()`, precisely so a malformed descriptor would be a reported `FAULT 0D` on a running kernel
rather than a triple fault. It produced `M1 FAULT 0E ... ERR 3` instead: a page fault on the descriptor
itself. See ADR-0013 §2 for the measurement.

The fix moved `ltr` into `core/boot/boot.S`'s 64-bit stub, where paging is on but `vmInit` has not run,
so the bootstrap tables still mark everything writable. **The cost is the diagnostic.** A malformed TSS
descriptor now raises #GP before any IDT exists, which is a double fault and then a triple fault: a VM
that reboots with no output at all.

**Why the alternative was worse.** Moving the GDT into `.data` would have made it writable — a table
the CPU re-reads on every privilege transition and every interrupt, on a writable page, giving up a
property ADR-0012 paid for. The same argument applies to the ACCESSED bit, which is pre-set on all four
segment descriptors for exactly this reason.

**The mitigation:** `m9-ring3/run.sh` reads the TSS descriptor out of guest physical memory and
requires its type to be **11 (busy)**, a state only `ltr` can produce, plus its base, limit, DPL and
present bit; and requires the task register to report the same base. So `ltr` having run correctly is
asserted from outside rather than inferred from the machine not having crashed. The structural half
also asserts that `ltr` is in `boot.S` and NOT in `isr.S`, so the diagnostic-shaped mistake cannot be
made again by accident.

**Cost of the workaround:** one class of boot-time bug has no diagnostic. It is the same class every
other line of the boot stub carries, which is why CLAUDE.md rule 4 puts GDT setup there.

---

## GAP-0087 — m3-shell's, m4-fault's, m5-pci's, m6-disk's, m7-frames' and m8-paging's goldens were regenerated at M9, deliberately

**Domain:** conformance (M9)
**Status:** OPEN — the same recurring cost GAP-0059, GAP-0065, GAP-0069, GAP-0072, GAP-0075 and
GAP-0078 record, at the sixth milestone that has paid it. Recorded again because the METHOD is what
makes it safe, and the method differed between the two groups.

**Two different causes, and only one of them was a fresh capture.**

* **m3, m4, m5 and m6 moved because `help` grew.** `shellStrHelp` went 1155 → **1589** bytes: seven new
  command lines, because a command that is not in `help` is undiscoverable. Those four goldens were NOT
  regenerated from a boot. The old seven-line block was located in each file and **mechanically
  substituted** with the new one, and the kernel was then required to reproduce the result byte-for-byte
  — which it did, at 4257, 3385, 3169 and 7679 bytes. m3's 80×25 screen golden was rebuilt the same
  way: the seven lines were inserted after `vmtest` and seven lines were dropped off the top, which is
  exactly what one more screenful of `help` does to an 80x25 buffer. (The first six of those seven were
  constructed and then asserted equal to a real capture before being written; the seventh was
  constructed and left to the harness to confirm, which it did.) A substitution that produced a file
  the kernel does not print fails immediately — which is the whole reason this is substitution and not
  a fresh capture.
* **m7 and m8 moved because the image grew**, which is GAP-0078 exercised for the third time. M9 adds
  ~36KiB — 16KiB of ring-0 stack, 104 bytes of TSS, 144 bytes of donated `.bss`, and `user.dart`'s code
  and tables — so `__kernel_end` moved by ten frames and every address, count and fold in both goldens
  moved with it: m7's `FREE 00007EB8` → `00007EAE`, its first `alloc` `128000` → `132000`, its drain's
  `SUM`/`XOR`/`LOW`; m8's `CR3`/`PML4` `122000` → `12C000` and all six `VM SECT` boundaries. Those two
  were regenerated with `run.sh --regen`, and **`derive.py` recomputed every one of those numbers from
  the boot's own `MB E` memory-map lines and from `kernel.elf`'s extents**. The mitigation held exactly
  as GAP-0078 says it does: regenerating cannot make a wrong allocator or a wrong map pass, because the
  derived checks run against the same capture.

**What did NOT move: `m1-interrupts/expected.txt`.** All 544 bytes are byte-for-byte identical, and
that is the assertion that says ring 3 costs the boot path nothing — `userInit()` prints nothing, the
DPL-3 gate is installed between `idtInstallAll` and `lidt`, and `ltr` runs in the boot stub. m0-boot,
mb-info and m2-console are likewise untouched.

**Cost:** whoever adds the next shell command pays the substitution again for four goldens, and whoever
grows the image pays the `--regen` again for three. Both steps are mechanical and both are checked.

---

## GAP-0088 — LLVM will build a table out of a chain of `if`s, and it does not always land in `.rodata`

**Domain:** toolchain, kernel (M9)
**Status:** OPEN — a property of the backend, recorded so the next milestone that writes a dense
constant chain knows what to expect.

GAP-0079 recorded that LLVM lowered `pmmFreeStatus`'s dense dispatch into a jump table in `.rodata`.
M9 hit the same behaviour in a different section. `userCodeLen` was written as five `if`s returning five
constants, and `dcc`/LLVM lowered it into

```
.Lswitch.table.userCodeLen   ->  section .rodata.cst32
```

— a MERGEABLE-CONSTANT section, not `.rodata`. `m1-interrupts/run.sh` asserts that every `OBJECT`
symbol `dcc` emits lives in `.rodata`'s section index, on the grounds that a table landing elsewhere
might be writable or might not be loaded at all, and it failed.

**The assertion was not relaxed.** ADR-0012 §8's rule applies: an assertion a milestone weakens in
order to pass is not an assertion. The table LLVM wanted to build is written explicitly instead, as a
six-byte `@rodata` table indexed by mode — which is where it belonged anyway, and which let the harness
check its bytes against the payload symbols' real sizes in `kmain.o` rather than against a literal in a
comment. That is a strictly stronger check than the one it replaced.

**What is still true and still unfixed:** the backend is free to synthesise a table from ordinary
control flow, and the section it chooses is not something this repo controls. The link script does
place `*(.rodata.*)` into the read-only segment, so such a table WOULD have been read-only in the final
image; what it would not have been is inside `.rodata`'s *object-file* section index, which is what the
M1 assertion tests. The two are different claims and the assertion tests the narrower one on purpose.

**Cost of the workaround:** one hand-written table, and this entry so the next dense `if`-chain in
`@bare` DCDart is recognised as the same thing rather than diagnosed as a toolchain break.
