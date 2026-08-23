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
M5, → 424 at M6 (unchanged), → 5096 at M7, → 5224 at M8, → 5368 at M9, → 5496 at M10,
→ 9664 at M11, → 9664 at M12 and M13 (unchanged, twice), → 11488 at M14, → 12768 at M15,
→ 14048 at M16.**

**M15's share was 1280 and M16 DOUBLED IT to 2560** — `file_store` is still one symbol, now behind
FOUR seam functions rather than three. M15 put 16 metadata words, five rows of four file descriptors
of four words each, and one 512-byte bounce buffer in it. M16 (ADR-0020 §7) made the metadata 32
words (six of them its own counters), a descriptor EIGHT words (a directory-entry index, a last
cluster, and how many bytes of cluster the descriptor owns), and added a SECOND 512-byte sector
buffer — because a write that does not start and end on a sector boundary needs the caller's bytes and
the sector already on the drive in memory at the same time, and one buffer for both would mean the
read destroyed the data being written.

`fat_store` did NOT move: M16's whole write path reuses the four regions M14 donated, and both
m14-fat and m16-filewrite assert 1824 as well as the total.

The `.align 8` costs nothing, because `fat_store` ends at a multiple of 16. **Ten harnesses subtract
the file_store block** (m5 through m14) so that every older milestone's number still means what it
meant when it was written — in particular m12's "a heap needed no new mutable state", m13's "a C
library is entirely userland" and m14's 11488 are all still checked as such. ADR-0019 §8, ADR-0020 §7.

**M14's share is 1824** — `fat_store`, one symbol behind four seam functions: 32 metadata words,
a 256-entry cluster chain, one 512-byte sector buffer and the 11 bytes of an 8.3 name. The
`.align 8` costs nothing, because `proc_store` ends at a multiple of 16. **Nine harnesses
subtract it** (m5 through m13) so that every older milestone's number still means what it meant when it was
written — in particular m12's "a heap needed no new mutable state" and m13's "a C library is
entirely userland" are both still statements about 9664 bytes, and are both still checked.

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

**M10 ADDS A SECOND STEP, and it is the one that makes the isolation real.** `core/kernel/kmain.dart`
imports the prelude through a HARDCODED RELATIVE PATH — `import '../../../DCDart/core/runtime/
dc-core-bare/prelude.dart';` — which is GAP-0003. So pointing `DCDART_HOME` at a pinned clone
isolates the COMPILER and not the PRELUDE: `dcc` from the clone is then handed the shared checkout's
prelude, and the two disagreeing produces

```
dcc build: DccLowerError: no @bare top-level function found in kmain.dart
```

which looks like a broken kernel and is not. **The repo has to be COPIED beside the clone**, so that
`../../../DCDart` resolves inside the sandbox — which is what ADR-0011 §7 means by "mirrored beside a
copy of this repo", stated here as a command rather than as a description:

```bash
rsync -a --delete --exclude __pycache__ <repo>/ <sandbox>/oscortex_core/
cd <sandbox>/oscortex_core && DCDART_HOME=<sandbox>/DCDart bash core/tests/conformance/<h>/run.sh
```

**A symlink is not enough.** `ln -s <repo> <sandbox>/oscortex_core` produces the same error: Dart
resolves a relative import through the file's REAL path, so the import walks out of the real repo and
lands on the shared checkout again. This was measured at M10, where the shared checkout's `HEAD` was
four commits ahead of the pin and the difference was visible immediately.

**Cost:** an rsync per build, and a mirror that has to be re-synced after every edit. M10's sandbox
did that with a three-line script.


---

## GAP-0085 — What ring 3 does NOT do, listed rather than discovered later

**Domain:** kernel (M9)
**Status:** OPEN, **NARROWED at M10 (ADR-0014)**. Item 5's ELF-loader half is CLOSED and item 4 is
narrowed; the successors are GAP-0089 (processes), GAP-0090 (a filesystem) and GAP-0091 (dynamic
linking). Every remaining item is absence, not wrongness: nothing below is mis-reported, and `user`
and `run` print what is actually mapped and what actually happened rather than what was intended.

**What M10 changed, item by item:**

* **item 1** is unchanged and its successor is GAP-0089. There is still one PML4. A loaded program
  gets a 2MiB window inside the kernel's own address space, temporarily, and it is handed back the
  moment the program exits or dies.
* **item 2** is unchanged and its successor is GAP-0089.
* **item 4** is NARROWED. The same three syscalls now serve a program that arrived from outside this
  repo, and `write`'s pointer check is a per-page walk of the live tables (`elfOwns`) rather than a
  comparison against two frame numbers — because a loaded program's pages have unmapped gaps between
  them and a range test would accept a pointer into one. There is still no `read`, no file
  descriptor, no `brk` and no `mmap`.
* **item 5** is HALF CLOSED. **There is an ELF loader.** A freestanding static ELF64 is read off a
  disk, validated field by field, mapped at the `p_vaddr`s its own program headers name with the
  permissions its own `p_flags` ask for, and entered at its own `e_entry` in ring 3. What is still
  absent is `fork`, `exec`, relocation and dynamic linking — GAP-0091.
* **items 3, 6, 7, 8, 9 and 10** are unchanged, and every one of them now applies to a loaded program
  as well as to a `@rodata` payload. In particular item 10: a fault taken in the kernel while a
  loaded program is live still tears that program down.

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
   **CLOSED IN PART at M10 (ADR-0014): the ELF loader exists.** `fork`, `exec`, relocation and
   dynamic linking do not — GAP-0091.
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

---

## GAP-0089 — There is still no process: one address space, one program, no scheduler

**Domain:** kernel (M10)
**Status:** **NARROWED at M11** (ADR-0015). **Items 1 and 2 are done**: every process now gets its own
PML4, PDPT and page directory from the allocator, the kernel's mappings copied in and its program
pages private, and `CR3` is switched on every transition. `proc run <lbaA> <lbaB>` loads two programs
into two address spaces and a `yield` syscall switches between them. **Item 5 is partly done**: a
process's frames are recorded in its slot and recovered from its own page table at teardown, and
`PROC KILL SLOT n FREED n` says how many came back — but `frames` still cannot say who has what.
**Items 3 and 4 are NOT done and are restated as GAP-0097 (cooperative, not preemptive; no fork, exec
or wait) and GAP-0096 (everything else a process does not have).**

**NARROWED AGAIN at M12 (ADR-0016). Item 5 is narrowed a second time**: a process's memory is still
the kernel's memory, but a process now *asks for* memory and the kernel now *accounts for what it
gave*. `sbrk` (syscall 4) maps frames into the calling process's own window; each slot records its
own heap base, break and page count; `PROC HEAP` prints them on every call; and `PROC KILL SLOT n
FREED c` counts the heap pages back with the program's, which `m12-heap/run.sh` checks against a
number derived from the ELF. What is still true is the last sentence of item 5: **`frames` shows the
total and cannot say who has what**, and there is no per-process quota (GAP-0107 items 5 and 6).

The original entry follows, unedited.

**Original status:** OPEN — deliberately scoped out. GAP-0085 items 1 and 2, restated for the thing that now
runs in ring 3, because "the payload is not a process" was easy to accept about 136 bytes of
`@rodata` and is easier to forget about a program that arrived on a disk.

1. **One PML4, and it is the kernel's.** A loaded program gets ONE 2MiB window
   (`[0x10000000, 0x10200000)`) inside the kernel's own address space, carried by one
   page-directory entry that is installed at load and removed at teardown. Two programs cannot be
   loaded at once and `run` refuses the second with `ELF REFUSED 02 a program is already running` —
   a state nothing can currently produce, and therefore exactly the kind of thing that has to say so
   out loud.
2. **A second `CR3` is the obvious next thing and was deliberately not built.** It needs per-process
   page tables, a switch on entry and exit, and the whole of GAP-0083's TLB question. It also needs
   something to schedule.
3. **No scheduler, no preemption, no `fork`, no `exec`, no wait, no exit status anyone can collect.**
   One program at a time, entered synchronously from a shell command, running until it exits or
   faults. The timer interrupt fires while it runs and returns to it.
4. **A program that never exits cannot be stopped**, exactly as `user hold` cannot. The `spin`
   variant on m10-elf's test disk is that program, and it is the LAST command any session can run.
5. **The program's memory is the kernel's memory.** Its frames come from the same allocator as
   everything else and its page table is a page-directory entry in the kernel's page directory.
   Nothing accounts for a program's memory as belonging to it — `frames` shows the total and cannot
   say who has what.

**Why this is not a bug:** every item is absence. `run` reports what it actually mapped, `ELF WINDOW
PAGES` counts what is actually user-accessible, and the teardown is asserted from outside on both the
exit path and the fault path.

---

## GAP-0090 — There is no filesystem, and this is the list of what one has to add

**Domain:** kernel (M10)
**Status:** **NARROWED AT M14, ITEM BY ITEM.** ADR-0018 adds a read-only FAT16 driver. What that closes
and what it leaves is set out immediately below, and GAP-0116 is the successor entry for what the
filesystem that now exists does NOT do.

| item | at M14 |
|---|---|
| 1. Names | **CLOSED.** `run PROGA.ELF` is a filename. 8.3 only, upper-cased on input, and anything else is a refusal (GAP-0117). |
| 2. A directory | **CLOSED for the root directory.** `ls` enumerates it, skipping deleted entries, long-filename entries and the volume label, and reports how many of each it skipped. Subdirectories are refused by name (GAP-0116 item 2). |
| 3. Allocation | **NARROWED AT M16.** `fatFindFree` scans the FAT for a free cluster from a hint, wrapping once; `fatAlloc` marks it end-of-chain and links it; `fatTruncate` frees a whole chain. There is still no free-space FIGURE — no count kept, no `statfs`, and a program discovers the volume is full by being refused (GAP-0127 item 11). `make-image.py` still places every cluster of the files it plants by hand; the ones the GUEST writes are placed by the kernel, and `m16-filewrite/derive.py` predicts every one of them. |
| 4. A write path | **NARROWED AT M16** (`docs/decisions/0020-writing-to-a-disk.md`). `WRITE SECTORS` (0x30) and `FLUSH CACHE` (0xE7) are implemented, `fatSetEntry` updates every copy of the FAT, `fatDirCreate`/`fatDirWrite` change the root directory, and a ring-3 program creates a file and writes to it. Verified by `fsck_msdos` and by macOS's own `msdos` driver, not by this kernel reading back what it wrote. **What is still absent by choice, not by construction:** a journal, crash consistency beyond an ordering discipline, an atomic replace, and any way to delete or rename — GAP-0127 items 3, 7 and 8. m14-fat's three greps for the absence of all this are gone and GAP-0130 says what replaced them. |
| 5. Metadata | **PARTLY.** A size and an attribute byte come from the directory entry and are used — the size bounds the chain walk and the attribute is what refuses a subdirectory. No timestamps, no ownership, no permissions, and nothing still says "this file is executable": `run` will try to load anything, and the ELF checks are still the only gate. |
| 6. Partitions | **PARTLY.** The volume is still the whole disk and the MBR is still unread. What is new is that sector 0 is now *validated* as a boot sector — signature, BPB, geometry — rather than ignored. |
| 7. More than one device | **UNCHANGED.** Primary master only (ADR-0010). |
| 8. Buffering or caching | **PARTLY.** One 512-byte sector buffer, used for FAT and root-directory reads only. File data still goes straight from the drive into the caller's frame, and loading the same program twice still reads every data sector twice. `fatMetaReads` and `fatMetaHits` make the difference a number. |
| 9. Concurrency | **UNCHANGED.** One caller, no locking, one open file at a time. |

**The original entry follows unchanged**, because the argument for why the accounting was written down
at all has not stopped applying to items 3, 4, 7 and 9.

**Domain:** kernel (M10)
**Status (as written at M10):** OPEN — deliberately scoped out. ADR-0014 §4 makes the argument; this is
the accounting, written down rather than gestured at, because "we will add a filesystem later" hides
how much of one is missing.

**NOT NARROWED at M11 or M12, and this line exists so that is not mistaken for an oversight.** M11
put three program slots on its test disk and M12 puts four (two of them the same binary with two
bytes changed), so the number of things a disk carries has gone up and the metadata format has not
changed by one byte: it is still `"OSCXPRG1"`, a length and an LBA, written by a generator that also
tells the harness where it put things. A heap is a memory question and this is a storage one; nothing
in M12 touches items 1–9 below. The one thing M12 does change about the picture is that a program can
now allocate at runtime, which means the day a `read()` syscall exists it will have somewhere to read
INTO — item 4's write path and everything downstream of it are still absent.

**What exists** is a 32-byte header sector — `"OSCXPRG1"`, a byte count, a starting LBA — written by
`core/tests/conformance/m10-elf/make-image.py` at an LBA `run` is told. That is the entire metadata
format.

**What a real filesystem has to add, none of which exists:**

1. **Names.** There is no way to refer to a program except by the sector number of its header. `run
   20` is not a path.
2. **A directory**, and therefore a way to enumerate what is on a disk at all. `disk read <lba>` can
   show you a sector; nothing can tell you which sectors are worth reading.
3. **Allocation.** Nothing tracks which sectors are in use. `make-image.py` places programs 64
   sectors apart by hand and asserts they fit.
4. **A write path.** This kernel has never written a byte to a disk: `ataReadInto` and
   `shellDiskRead` are the whole driver, and `WRITE SECTORS` (0x30) is not implemented. Everything
   downstream of that — a free list, an inode table, a journal, crash consistency — is therefore
   absent by construction rather than by choice.
5. **Metadata.** No size beyond the header's byte count, no timestamps, no ownership, no
   permissions. In particular nothing says "this file is executable"; `run` will try to load
   anything a header sector points at, and the ELF checks are the only gate.
6. **Partitions.** The image has an MBR signature at sector 0 (m6-disk put it there) and nothing
   reads it. The disk is a flat array of sectors.
7. **More than one device.** The driver knows the primary master and nothing else (ADR-0010).
8. **Buffering or caching.** Every sector is read from the drive every time. Loading the same program
   twice reads it twice.
9. **Concurrency of any kind.** There is one caller, no locking, and no notion of a file being open.

**What it costs today:** a program must be placed by a generator that also tells the harness where it
put it, and the kernel can only run programs somebody wrote down the sector number of. That is
enough to prove a loader and is not enough for anything else.

---

## GAP-0091 — The loader links nothing: no relocation, no `ET_DYN`, no dynamic linking

**Domain:** kernel (M10)
**Status:** OPEN — deliberately scoped out, and REFUSED BY NAME rather than half-supported.

`core/kernel/elf.dart` loads `ET_EXEC` and nothing else. Every one of the following is refused with
its own sentence rather than attempted:

1. **`PT_INTERP` or `PT_DYNAMIC`** → `ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not
   link`. A file that names an interpreter needs one, and this kernel has neither an interpreter nor
   anywhere to load it.
2. **`ET_DYN`** (a position-independent executable) → `ELF REFUSED 0C e_type is not 2 (ET_EXEC)`. A
   PIE would need `R_X86_64_RELATIVE` processing and a `PT_DYNAMIC` walk. Loading one at its nominal
   `p_vaddr` without relocating would produce a program whose every absolute reference is wrong —
   which is why the refusal is on `e_type` rather than a best effort.
3. **Relocations of any kind.** `build-prog.sh` asserts the built program has none left to apply.
4. **Symbol resolution.** The loader reads the program headers and never looks at the section
   headers or the symbol table. `derive.py` reads the symbol table, but that is the HARNESS deriving
   its expectations from the file, on the host, not the kernel resolving anything.
5. **`.init_array`/`.fini_array`, `DT_INIT`, constructors.** Nothing runs before `e_entry` and
   nothing runs after `exit`.
6. **`PT_TLS`, `PT_GNU_STACK`, `PT_GNU_RELRO`, `PT_NOTE`.** Ignored, per the gABI's rule for
   unrecognised segment types — with the deliberate exception of the two in item 1. **`PT_GNU_STACK`
   being ignored is safe here only because nothing derives stack permissions from it:** the stack is
   mapped writable and non-executable unconditionally, and a `PT_GNU_STACK` asking for `PF_X` would
   be silently not honoured. That is the right answer and it is not the answer the file asked for.

**What it costs today:** the test program is built `-fno-pic -fno-pie -static -nostdlib`, and any
program for this OS has to be. `run` on an ordinary Linux binary gets `ELF REFUSED 11` or
`ELF REFUSED 0C`, which is at least a sentence that says what to do about it.

---

## GAP-0092 — The kernel never enables SSE, so ordinary compiler output faults in ring 3

**Domain:** boot, kernel (M10)
**Status:** **CLOSED at M11** (ADR-0015, `core/tests/conformance/m11-proc/run.sh`). `core/boot/boot.S`
now probes CPUID leaf 1 for FXSR and SSE, sets `CR4.OSFXSR | CR4.OSXMMEXCPT` and `CR0.MP`, clears
`CR0.EM` and runs `fninit` — all four guarded by the probe — and `core/kernel/proc.dart` gives every
process a 16-byte-aligned 512-byte FXSAVE area that is saved and restored across every switch this
kernel performs. **The M11 test programs are built WITHOUT `-mgeneral-regs-only`, at -O2, and the
harness asserts the opposite of what M10's asserted: the disassembly of a function containing no
inline assembly MUST contain an `%xmm` register.** On a CPU where the probe says no, `proc run` is
refused by name (`procErrNoSse`) rather than run with nowhere to save an FPU. What is NOT covered —
AVX, `xsave`, a #XF handler, and any test of the x87 half — is GAP-0103.

The original entry follows, unedited, because its argument is the one M11 implemented.

**Original status:** OPEN — a real limit on what this OS can run, found while building the first
program for it.

`core/boot/boot.S` sets exactly one bit of CR4: PAE (bit 5). It has never set **`CR4.OSFXSR`** (bit
9) or `CR4.OSXMMEXCPT` (bit 10), and it has never executed `fxsave`/`fxrstor` or reserved anywhere to
save an FPU state to. So **any SSE instruction raises #UD**, in ring 0 and in ring 3 alike.

That has never mattered before, because `dcc` emits integer code only and every line of assembly in
this repo was written by hand. It matters now: at `-O2`, clang emits SSE for an ordinary `memcpy`, a
struct copy, or a vectorised loop — and the x86-64 SysV ABI assumes SSE exists. A program compiled
the way anybody would compile one dies in ring 3 at whatever instruction happened to get one, with a
`#UD` whose cause looks like a loader bug.

**The mitigation, and it is only a mitigation:** `build-prog.sh` compiles with `-mgeneral-regs-only`
and then asserts the DISASSEMBLY contains no `%xmm`/`%ymm`/`%zmm` register, because a flag is not
evidence. `prog.c`'s header says why.

**What closing it needs:** `CR4.OSFXSR | CR4.OSXMMEXCPT` in the boot stub, `CR0.EM` clear and
`CR0.MP` set, and — the part that is a milestone rather than three bits — somewhere to save and
restore 512 bytes of FPU/SSE state per program, which needs a notion of a program that owns
registers, which is GAP-0089. Setting the bits without the save area would be worse than not setting
them: two things sharing `%xmm0` across a syscall is a corruption nobody would look for.

**Cost of the workaround:** every program for this OS must be built with SSE disabled, and a program
built without that flag fails in a way that does not name the cause.

---

## GAP-0093 — m3-shell's, m4-fault's, m5-pci's, m6-disk's, m7-frames', m8-paging's and m9-ring3's goldens were regenerated at M10, deliberately

**Domain:** conformance (M10)
**Status:** OPEN — the same recurring cost GAP-0059, GAP-0065, GAP-0069, GAP-0072, GAP-0075, GAP-0078
and GAP-0087 record, at the seventh milestone that has paid it. Recorded again because the METHOD is
what makes it safe, and the method differed between the two groups exactly as it did at M9.

**Two different causes, and only one of them was a fresh capture.**

* **m3, m4, m5 and m6 moved because `help` grew by ONE LINE.** `shellStrHelp` went 1589 → **1658**:
  `  run <lba>     load an ELF program from that disk sector and run it`, because a command that is
  not in `help` is undiscoverable. Those four goldens were NOT regenerated from a boot. The line was
  inserted mechanically after `user pages` in each file and the kernel was then required to reproduce
  the result byte-for-byte — which it did, at 4533, 3523, 3307 and 7817 bytes. m3's 80×25 screen
  golden was rebuilt the same way: one line inserted, one line dropped off the top, which is exactly
  what one more line of `help` does to an 80×25 buffer. A substitution that produced a file the kernel
  does not print fails immediately, which is the whole reason this is substitution and not a fresh
  capture.
* **m7, m8 and m9 moved because the image grew**, which is GAP-0078 exercised for the fourth time.
  M10 adds `elf.dart`'s code and its 59 `@rodata` tables, `vm.dart`'s program-window API and 128
  bytes of donated `.bss` — about 20KiB — so `__kernel_end` moved and every address, count and fold in
  all three goldens moved with it: m7's free count and its drain's `SUM`/`XOR`/`LOW`; m8's `CR3`/`PML4`
  `12C000` → `131000` and all six `VM SECT` boundaries; m9's TSS, RSP0, GDT and IDT bases and every
  payload frame. Those three were regenerated with `run.sh --regen`, and **each harness's derived
  checks recomputed every one of those numbers from the boot's own `MB E` memory-map lines and from
  `kernel.elf`'s extents**. The mitigation held exactly as GAP-0078 says it does.

**What did NOT move: `m1-interrupts/expected.txt`.** All 544 bytes are byte-for-byte identical, and
that is the assertion that says the ELF loader costs the boot path nothing — `elfInit()` prints
nothing and runs before the first byte of output. m0-boot, mb-info and m2-console are likewise
untouched.

**What ALSO did not move, and it is worth noting:** `faultReport`'s widened `OP` field (ADR-0014 §6)
changed no golden at all, because nothing below 16MiB reaches the new branch. A change to a
diagnostic every fault in the kernel goes through, with four byte-exact goldens unaffected, is the
evidence that it was added rather than altered.

**Cost:** whoever adds the next shell command pays the substitution again for four goldens, and
whoever grows the image pays the `--regen` again for four.

---

## GAP-0094 — The frame-zeroing has no behavioural test that can fail, and this was measured

**Domain:** conformance, kernel (M10)
**Status:** OPEN — a hole in the TEST, not in the kernel. The kernel zeroes correctly; nothing in
this harness would notice if it stopped.

`core/kernel/elf.dart` zeroes every frame with `vmZeroFrame` before anything is copied into it, so
`.bss` is zero because the frame is zero (ADR-0014 §5). Two checks claim to prove that:

* the test program reads all 64 bytes of its own `.bss` and reports `BSS[00] SUM=00`;
* boot B reads every loaded page out of GUEST PHYSICAL MEMORY and requires everything outside
  `[p_vaddr, p_vaddr + p_filesz)` to be zero.

**A kernel built in the sandbox mirror with `vmZeroFrame(frame)` DELETED from `elfLoadSegment`
passed both of them, and the whole harness exited 0.**

**Why.** A freshly-booted QEMU hands out RAM that is already zero, and nothing in this kernel dirties
a frame before the loader gets one. Every frame the loader touches it zeroes; the two scratch frames
it fills with file bytes are freed after the load and, because the allocator is next-fit from a
FORWARD-MOVING cursor (ADR-0011), never handed back to a later `run` in the same session.

**Three shell sequences were tried against the broken kernel and none of them worked**, which is why
this entry says "cannot" rather than "does not":

* `frames test` writes a pattern into word 0 and the last word of 64 frames — and leaves the cursor
  past all 64, so the next `run` gets clean frames;
* `frames drain` writes to exactly ONE frame (the highest) and, being next-fit, ends with the cursor
  back where it started, so `frames drain; frames refill; run` lands just past whatever came before;
* running the program twice does not reuse its frames: the cursor advances by six each time, and
  wrapping it would take ~5,400 loads.

**What is asserted instead.** `m10-elf/run.sh` requires each of `elf.dart`'s five `allocFrame()`
calls to be paired with a zeroing (four in `elf.dart`, the page table's inside
`vmProgTableInstall`), and requires the exact line `vmZeroFrame(frame);` in `elfLoadSegment`. **A
structural check is weaker than a behavioural one and neither ADR-0014 nor this entry pretends
otherwise.**

**What is NOT weakened.** The behavioural checks are not vacuous in general — they caught a mutation
that read sectors straight into the destination frame instead of through the scratch frame, which is
the same bug's other half: `BSS[00] SUM=C2` and an exit status 0x2C2 too high. What they cannot see
is the difference between "the loader zeroed it" and "it was already zero".

**What would close it:** a way to dirty a frame before the allocator hands it out. The cheapest
honest one is a shell command that fills every free frame with a pattern and returns them — the
inverse of `frames drain`, which already owns every frame at the moment it could do it. That is a
change to M7's code and M7's goldens, and it belongs to whoever needs it rather than to the milestone
that found the hole.

**Cost of the workaround:** one class of loader bug — handing ring 3 a page of stale kernel data — is
caught by reading the source rather than by running the kernel.

## GAP-0095 — m3-shell's, m4-fault's, m5-pci's and m6-disk's goldens moved by substitution at M11, and m7/m8/m9/m10's by `--regen`

**Domain:** conformance (M11)
**Status:** OPEN — the same recurring cost GAP-0059, GAP-0065, GAP-0069, GAP-0072, GAP-0075, GAP-0078,
GAP-0087 and GAP-0093 record, at the eighth milestone that has paid it. Recorded again because the
METHOD is what makes it safe, and the method differed between the two groups exactly as it did at M9
and M10.

**Two different causes, and only one of them was a fresh capture.**

* **m3, m4, m5 and m6 moved because `help` grew by THREE LINES.** `shellStrHelp` went 1658 → **1871**:
  ```
    proc          the process table, the CR4 SSE bits, and each slot
    proc run      <lbaA> <lbaB>: two processes, two address spaces, yield
    proc cross    <lbaA> <lbaB>: the same, but B reads A's page -- must #PF
  ```
  because a command that is not in `help` is undiscoverable. Those four goldens were NOT regenerated
  from a boot. The three lines were inserted mechanically after `run <lba>` in each file and the
  kernel was then required to reproduce the result byte-for-byte — which it did, at 4959, 3736, 3520
  and 8030 bytes. m3's 80×25 screen golden was rebuilt the same way: three lines inserted, three
  dropped off the top, which is exactly what three more lines of `help` do to an 80×25 buffer. A
  substitution that produced a file the kernel does not print fails immediately, which is the whole
  reason this is substitution and not a fresh capture.
* **m7, m8, m9 and m10 moved because the image grew**, which is GAP-0078 exercised for the fifth
  time. M11 adds `proc.dart`'s code and its 46 `@rodata` tables and **4168 bytes of donated `.bss`**
  — the largest single donation since M7's bitmap — so `__kernel_end` moved and every address, count
  and fold in all four goldens moved with it: m7's `PMM BASE` 0x12F1B0 → 0x1351B8, its free count
  0x7EA9 → 0x7EA2 and the drain's `SUM`/`XOR`/`LOW`; m8's `CR3`/`PML4` and its `VM SECT` boundaries;
  m9's TSS, RSP0, GDT and IDT bases and every payload frame; m10's page-table and program frames.
  Those four were regenerated with `run.sh --regen`, and **each harness's derived checks recomputed
  every one of those numbers from the boot's own `MB E` memory-map lines and from `kernel.elf`'s
  extents**. The mitigation held exactly as GAP-0078 says it does.

**What did NOT move: `m1-interrupts/expected.txt`.** All 544 bytes are byte-for-byte identical, and
that is the assertion that says the process table and the SSE probe cost the boot path nothing —
`procInit()` prints nothing, `sse_flag` is written before any output exists, and `fninit` is silent.
m0-boot, mb-info and m2-console are likewise untouched. m11-proc/run.sh asserts it again as a prefix
of its own capture, and so does every other harness from M4 onwards.

**A SECOND, SMALLER SUBSTITUTION, recorded because it changed output that a golden had never seen.**
`procCreate` printed `PML4 000000000013E000PROC PD 0000000000140000` — it reused `procStrPd`, the
LINE label `'PROC PD '`, as a mid-line field separator, welding a second line label into the middle of
a field with no space in front of it. A new 4-byte table `procStrPdF` (`' PD '`) was added, the same
distinction `procStrExitF` already makes against `procStrExit`. This was found by reading a boot, not
by a check, and nothing in any harness would have failed on it: a golden regenerated from that kernel
would have enshrined it.

**Cost:** whoever adds the next shell command pays the substitution again for four goldens, and
whoever grows the image pays the `--regen` again for five.

---

## GAP-0096 — What a process does NOT do, listed rather than discovered later

**Domain:** kernel (M11)
**Status:** OPEN — deliberately scoped out. GAP-0089's shape, restated for the thing that now exists,
because "there is no process" was easy to be precise about and "there is a process" is where the
vagueness starts.

1. **Four is the capacity, and it is a capacity rather than a design limit.** A fifth `procCreate` is
   refused with `procErrNoSlot` and says so. Raising it is `procStoreBytes` and one number in
   `kdata.S` — and it is untestable from the shell, because `proc run` takes exactly two LBAs and
   there is no way to ask for a third process (GAP-0101).
2. **A process has no name, no parent, no children, no priority and no accounting.** A slot holds an
   id, a state, four frame numbers, an entry, a stack pointer, a page count, an exit code and the LBA
   it was loaded from. Nothing measures how long it ran; the tick counter is global and nothing
   attributes a tick to anybody.
3. **There is no way for one process to affect another.** No signals, no kill, no shared memory, no
   pipe, no message. The only interaction two processes have is that yielding lets the other one run.
4. **`exit` status goes nowhere.** It is printed and kept in the slot for `proc` to show. No process
   can collect another's, because there is no `wait` and no parent.
5. **The stack is one page and it does not grow.** A process gets exactly the page at
   `[0x101FF000, 0x10200000)`; a #PF just below it is a fault, not a stack extension. This is M10's
   arrangement unchanged.
6. ~~**No process can allocate memory.** There is no `brk`, no `mmap`, and no syscall that returns a
   page. A process's address space is exactly what its ELF asked for plus one stack page, forever.~~
   **CLOSED at M12 (ADR-0016).** `sbrk` (syscall 4) takes frames from the PMM, zeroes them and maps
   them into the calling process's window as user + writable + NX, growing on demand from the top of
   the program's own image up to a guard page below the stack. It refuses with a checkable return
   value rather than faulting, and every page goes back at teardown. **What replaces this item is
   GAP-0107**: what exists is a monotonic page-granular break with no `free`, no reuse and no quota —
   the interface a `malloc` needs, and not an allocator.
7. **A process cannot create a process.** No `fork`, no `exec`, no `spawn`. Both processes are created
   by the shell before either runs.
8. **Nothing is shared between address spaces except the kernel.** Which is the point, and is also
   the reason there is no way to build anything that needs sharing.

**Why this is not a bug:** every item is absence, and each one is refused or simply absent rather than
half-present. The one that would be a bug if left unsaid is item 4, because "the exit code is
reported" reads like something a program could collect.

---

## GAP-0097 — The switching is COOPERATIVE, and this entry exists so nobody infers otherwise

**Domain:** kernel (M11)
**Status:** OPEN — a deliberate scope boundary, stated in the loudest available place because a
milestone called "processes" invites the assumption it does not support.

**There is no scheduler and no preemption.** A process runs until it calls `yield` (syscall 3) or
`exit` (syscall 0). The timer interrupt fires while a process runs and returns to it, exactly as it
did at M9 and M10 — `tickCount` advances and nothing consults it.

**A process that calls neither cannot be stopped.** `proc run <a> <b>` where either program loops
forever is the last command that session can run, exactly as `user hold` and M10's `spin` are. The
M11 harness relies on this: its second boot deliberately loads a program with `jmp .` written over
its entry point so that both address spaces stay alive while guest memory is dumped.

**What preemption would need, and none of it exists:**

1. **A timer handler that switches.** Mechanically small — `procYield`'s body without the syscall —
   and it is the smallest part.
2. **A second ring-0 stack, per process.** Today one RSP0 in the TSS is enough *because only one
   process is ever inside the kernel at a time*, which is true only while the sole way in is a
   syscall the process chose to make. A timer that switched processes while one was mid-syscall would
   have two kernel contexts on one stack. ADR-0015 §9 says so by name.
3. **Reentrancy.** Every subsystem in this kernel — the allocator, the loader, the UART, the shell —
   assumes one caller. A preempting timer makes all of them concurrent.
4. **A policy that is testable.** GAP-0101: with two processes, round-robin and lowest-first cannot be
   told apart, and the shell cannot make a third.

**What is asserted instead, and it is a real assertion rather than a promise:** `m11-proc/run.sh`
requires, for every session in the capture, that **the number of switches equals the number of
`PROC YIELD` lines plus the number of exits that had a survivor.** If a timer ever started switching
processes, that arithmetic would stop working. Nothing else in the harness would notice.

---

## GAP-0098 — A fault kills EVERY process, not just the faulting one

**Domain:** kernel (M11)
**Status:** OPEN — a decision rather than an omission, and the honest version of what M4's recovery
path can currently recover to.

When a process faults, `procOnFault` tears down **all four slots**, not the one that faulted, and the
session ends at the shell prompt.

**Why.** M4's recovery path (`fault_resume`, ADR-0007) abandons every stack frame between the fault
and the shell loop. `shellProcRun` is one of those frames. So after a fault it never runs again and
never gets a chance to clean anything up. A survivor left READY would be a process nothing can ever
schedule, holding four table frames and its program pages, for the rest of the boot — which is
exactly the state GAP-0085 item 10 warned a kernel WITH processes must not reach.

**What a per-process kill would need:**

1. a way to return to `shellProcRun` rather than past it — i.e. a resume point per process rather than
   per session, which is `enter_user`'s recorded RSP generalised;
2. somewhere for the *survivors* to keep running from, which with cooperative switching means
   switching to one of them from inside the fault handler rather than returning to the shell;
3. an answer to "what does the shell print while three processes are still running", which is a
   question this kernel's single-threaded prompt has never had to have.

**What it costs today:** one program's bug ends the whole session. `PROC KILL SLOT n FREED n` prints
once per slot that owned anything, so the teardown is at least visible and countable — and the M11
harness checks the allocator's free count is identical before and after a session containing a fault.

---

## GAP-0099 — QEMU does not #GP on a reserved CR4 bit, so the no-SSE control catches an unguarded write by the WRONG assertion

**Domain:** conformance (M11)
**Status:** OPEN — a limit of the emulator, measured rather than assumed, and the reason one harness
assertion is doubled.

`core/boot/boot.S` probes CPUID leaf 1 before setting `CR4.OSFXSR | CR4.OSXMMEXCPT`, because the SDM
says those bits are **reserved** when `CPUID.01H:EDX.FXSR` is 0 and that writing a reserved CR4 bit is
a #GP — which, in the 32-bit boot stub before any IDT exists, is a triple fault and a silently
rebooting VM with no output at all.

**A kernel built with that guard DELETED was run on `-cpu qemu64,-sse,-fxsr`. It did not triple-fault.**
All 544 bytes of M1's output appeared exactly as usual, and `proc` then reported
`PROC SSE 0 CR4 0000000000000420`: **QEMU accepted bit 10 (OSXMMEXCPT) and silently dropped bit 9
(OSFXSR)** rather than faulting on either.

**What this means for the harness.** `m11-proc/run.sh`'s boot C asserts two things where one would
have looked sufficient:

* M1's golden is still a byte-exact prefix — which is what would catch the unguarded write **on real
  hardware**, and which passes vacuously here;
* CR4 reads back **exactly 0x20** — which is what actually caught it, at 0x420.

Neither claim is left resting on the other, and the ADR and the harness both say which one fires here.

**What would close it:** running the mutated kernel on a machine that implements the reserved-bit #GP.
No such machine is available to this project, and a second emulator would be a second thing to trust.
The doubled assertion is the honest answer.

**Cost:** one of the two assertions in boot C is untestable on the only hardware this project has, and
is kept anyway.

---

## GAP-0100 — The `PD[128]` clear in `procSpaceBuild` cannot be made to matter, and this was measured

**Domain:** kernel, conformance (M11)
**Status:** OPEN — a hole in the TEST, not in the kernel. The clear is correct; nothing can currently
notice if it stopped.

`procSpaceBuild` copies the kernel's page directory into the process's and then explicitly clears
entry 128 — the program window — so that a process cannot inherit whatever an M10 `run` program left
mapped there.

**A kernel built in the sandbox mirror with that line DELETED passed the whole of `m11-proc/run.sh`.**

**Why.** `shellProcRun` already refuses to start while an M10 `run` program is live
(`procErrElfLive`), and nothing else ever writes the kernel's own `PD[128]`. So at the moment the copy
happens, the entry being copied is always zero, and clearing it is a no-op in every state this kernel
can reach. It is a second lock on a door the first lock already holds shut.

**Why it is kept.** The day the `procErrElfLive` refusal is relaxed — which is the day somebody wants
a `run` program and a process at once — is not the day to discover that the second lock was never
there. The cost is one line and one store.

**What would close it:** a way to reach `procSpaceBuild` with the kernel's `PD[128]` non-zero, which
means either relaxing the refusal or adding a shell command that installs a window without running a
program. Both are changes to M10's code, and they belong to whoever needs them.

**Cost of the workaround:** one class of address-space bug — a process inheriting another program's
window — is prevented by two mechanisms and tested by neither.

---

## GAP-0101 — The scheduling policy is untestable at two processes, and the shell cannot make a third

**Domain:** kernel, conformance (M11)
**Status:** OPEN — a hole in the TEST and in the COMMAND SURFACE, not in the kernel.

`procPickNext` is round-robin from the caller, deliberately: lowest-first with two processes is not a
policy, it is a coin that always lands the same way, and with three it would starve the third
outright. ADR-0015 §6 makes the argument.

**A kernel built with round-robin replaced by lowest-first passed the whole of `m11-proc/run.sh`.**

**Why.** With exactly two READY processes the two policies produce identical schedules, always. And
there is no way to get a third: `proc run <lbaA> <lbaB>` takes exactly two LBAs, `procMax` is 4 but
nothing can fill it, and a process cannot create a process (GAP-0096 item 7).

**What would close it:** a shell command that takes three or four LBAs, or a `proc add <lba>` that
loads into a free slot without starting anything. Either is small. Neither was built, because a third
process with nothing to prove would have been a feature added to satisfy a test — and this entry is
the honest alternative to that.

**A consequence worth stating separately:** `procMaxWrap` (5) and the wrap arithmetic inside
`procPickNext` are exercised only in the two-process case, where `cur + 1` never needs the wrap at
all except for slot 1 → slot 0. The loop that walks past `procMaxSlot` and subtracts `procMax` has
never run with three live slots.

**Cost of the workaround:** the scheduler's only policy decision is asserted by reading the source.

---

## GAP-0102 — The page-table zeroing in `procSpaceBuild` has no behavioural test that can fail

**Domain:** conformance, kernel (M11)
**Status:** OPEN — GAP-0094, for a second subsystem, with the same cause and the same measurement.

`procSpaceBuild` zeroes all three of the PML4, PDPT and page-directory frames it takes, before writing
a single entry into any of them. An unzeroed page table is 512 entries of allocator litter every one
of which the CPU will read as a mapping, with the present bit set roughly half the time.

**A kernel built in the sandbox mirror with all three `vmZeroFrame` calls DELETED passed the whole of
`m11-proc/run.sh`, including the two page-table walks out of guest memory.**

**Why.** Exactly GAP-0094's reason: a freshly-booted QEMU hands out RAM that is already zero, and
nothing in this kernel dirties a frame before the allocator gives it out. The frames a process's
tables come from have never been written by anything.

**What is asserted instead.** The harness walks both address spaces out of guest RAM and requires the
mapped set of the program window to be EXACTLY what the ELF's own program headers say plus one stack
page — so a table full of litter WOULD be caught, if the litter existed. It does not.

**What would close it:** the same thing GAP-0094 named — a shell command that fills every free frame
with a pattern and returns them, the inverse of `frames drain`. That is a change to M7's code and M7's
goldens, and it is now the *second* milestone that would have used it. Whoever builds it closes two
gaps.

**Cost of the workaround:** one class of address-space bug — handing a process a page directory full
of stale mappings — is caught by reading the source rather than by running the kernel.

---

## GAP-0103 — What the FPU support does NOT cover: no AVX, no XSAVE, no #XF handler, no x87 test

**Domain:** kernel (M11)
**Status:** OPEN — deliberately scoped out, and listed because "SSE works now" is exactly the sentence
that hides all four.

1. **`fxsave`/`fxrstor`, not `xsave`/`xrstor`.** The save area is 512 bytes and covers x87, MXCSR and
   **XMM0-15 only**. `CR4.OSXSAVE` is never set, `XCR0` is never written, and CPUID leaf 0x0D is never
   asked. A program that used **AVX** would get a #UD — which is the right answer, because the state
   is not being saved — but the kernel never tells it so: there is no `#UD` message that says "this OS
   does not support AVX", only the generic fault report.
2. **The extended save area's size is never queried.** With `xsave` it would have to be, because it is
   CPU-dependent. With `fxsave` it is architecturally 512 and this kernel hardcodes 512.
3. **`CR4.OSXMMEXCPT` is set and there is no #XF handler that says anything special.** Vector 19 goes
   through the same generic fault path as everything else. It cannot fire today — `procFxInit` masks
   every SSE exception in MXCSR and no program unmasks one — so the bit changes no behaviour; it is
   set because the alternative is a #UD whose cause names the wrong thing entirely if a program ever
   does unmask one.
4. **Nothing tests x87.** Both test programs use SSE and neither pushes a value onto the x87 stack.
   The x87 half of the save area is asserted only through its control word (0x037F, read out of guest
   RAM) and the tag word being the zeroed image `procFxInit` wrote. A kernel that saved XMM correctly
   and x87 incorrectly would pass everything.
5. **MXCSR is per-process in the save area and no program can usefully change it.** A process that
   wrote MXCSR would have it saved and restored correctly; nothing tests that, and the harness asserts
   all four areas hold 0x1F80 exactly, which a program changing its own MXCSR would break.
6. **There is no lazy-FPU path**, deliberately (ADR-0015 §2), so `CR0.TS` is never set and #NM
   (vector 7) is a fault this kernel can still only report generically.

**What it costs today:** a program built for this OS may use SSE and SSE2 and must not use AVX; and
the x87 half of the per-process state is correct by construction rather than by test.

---

## GAP-0104 — Three DCDart features that would close standing gaps here landed AFTER the pin and were not adopted

**Domain:** kernel, tooling (M11)
**Status:** OPEN — deliberately not adopted at M11, listed so the next session does not have to
rediscover them. All three landed in DCDart between `DCDART_PIN.txt`'s `e3cfe18` and the shared
checkout's `70509df`, i.e. **they are not available at the pin** and taking any of them is a pin bump.

1. **`ADR-0046` folds compile-time integer arithmetic inside sized-int literals**, which is exactly
   **GAP-0077**. `core/kernel/proc.dart` spells `procMaxSlot = 3` and `procMaxWrap = 5` as separate
   literals because `u64(procMax - 1)` was refused; `m11-proc/run.sh` multiplies every such pair
   against every other to catch a drift the language now makes impossible. Adopting it deletes the
   duplicate constants across `proc.dart`, `pmm.dart`, `vm.dart` and `elf.dart` and closes GAP-0077.
2. **`ADR-0045` adds word and doubleword port I/O**, whose commit message says in so many words that
   it **deletes the kernel's `core/boot/portio.S`** — which is **GAP-0066**. That is a whole assembly
   file and four of the 58 declared externs.
3. **`ADR-0047` adds `break` and `continue`.** Several loops here are written with a sentinel or a
   flag because they could not exit early.

**Why none of it was taken here.** M11's scope was FPU state and a second address space, and each of
these is a pin bump plus a regeneration of four address-bearing goldens (GAP-0078) for a reason
unrelated to the milestone. Each of the three is small, independently verifiable, and closes a gap by
DELETION rather than by addition, which is the best kind of unit this repo has.

**One thing that was measured and is worth writing down, because it is the question anybody bumping
the pin will ask first.** This repo's sources — both at `439a126` and at M11 — build to a
**byte-identical `.text` and `.rodata`** under `e3cfe18` and under `70509df`. The four intervening
DCDart commits change what the language ACCEPTS, not what its code generator emits for what this
kernel already writes. So the bump itself will not move a single golden; only adopting the features
will.

---

## GAP-0105 — `help` growing made three harnesses intermittently fail at exactly the `help` boundary

**Domain:** conformance (M11)
**Status:** OPEN — mitigated by a pause, and the mitigation is a timing constant, which is the part
that makes this a gap rather than a fix.

M11 took `shellStrHelp` from 1658 to **1871 bytes**. At 115200 baud that is roughly **160ms** of
serial output, plus three more lines of VGA scrolling. `qmp-drive.py` injects a keystroke every
**50ms**. So after `help,ret`, the next command's keystrokes were being injected while `help` was
still printing, its echo interleaved into the middle of the listing, and the byte-exact golden failed.

**It failed INTERMITTENTLY, at exactly the same byte offset every time** — char 2650 of m4-fault's
capture, the start of the line after `help`'s last — and it passed three times in a row immediately
afterwards, which is the worst possible shape for a test failure: it looks like a kernel race and it
is a harness one. Two of the four failures observed today happened while other QEMU instances were
running on the same machine.

m6-disk already carried `wait:600` after `help` for exactly this reason, from the last time `help`
grew. m3-shell, m4-fault and m5-pci did not, and now do. **A pause does not emit a byte, so no golden
changed.**

**THE FIRST FIX WAS INCOMPLETE, AND THE WAY IT WAS INCOMPLETE IS THE INTERESTING PART.** m3-shell runs
`help` **twice** — once near the end, and once at the very start as the backspace typo-correction test
(`h,e,l,q,backspace,p,ret`). The M11 mitigation was applied by matching the *key sequence* `h,e,l,p,ret`,
which does not match the typo-corrected spelling, so m3's first `help` kept no settle at all and the
`m,e,m` that follows it kept being typed into the tail of the listing. Measured at **one failure in
four runs**, always at char 2433 — `oscortex> mem` — with the capture reading `oscortex> em` and then
`unknown command: em`, i.e. a dropped keystroke and a correct report of the truncated word.

That is the second time this gap has been closed by pattern-matching a key list rather than by asking
"which commands in this session produce long output". The general fix is still the one below; the
specific lesson is that **a timing mitigation applied by grep will miss the instance that is spelled
differently.**

**What is actually wrong, underneath.** The driver has no flow control: it types on a wall clock and
the kernel prints on another one. Every `wait:` in every key list in this repo is a guess about how
long a command takes, tuned by observation, and every one of them gets worse as the thing it waits
for grows. The correct mechanism is the one `--wait-for` already implements for the boot marker —
wait for a byte pattern in the capture, not for a duration — and applying it per command would delete
every `wait:` constant in the suite.

**Cost:** four harnesses carry a timing constant that has to be revisited whenever the output of the
command before it grows, and the failure it prevents is intermittent and looks like something else.

---

## GAP-0106 — m7/m8/m9/m10/m11's goldens moved at M12 by `--regen`, and m3–m6's did NOT

**Domain:** conformance (M12)
**Status:** OPEN — the same recurring cost GAP-0059, GAP-0065, GAP-0069, GAP-0072, GAP-0075,
GAP-0078, GAP-0087, GAP-0093 and GAP-0095 record, at the ninth milestone that has paid it. Recorded
again because the interesting half of this one is the half that did NOT happen.

**Why five goldens moved.** `core/kernel/heap.dart` adds code and six `@rodata` tables, so
`__kernel_end` moved past a 4KiB boundary: the kernel image grew by exactly one page. Everything
downstream of `kernel_image_end` moved with it — the six page-table frames `vmInit` takes
(`0x138000` → `0x139000`), `pmm_store`'s base (`0x1351B8` → `0x1361B8`), the free-frame count
(`0x7EA2` → `0x7EA1`), and every process and program frame in m9's, m10's and m11's captures. All
five were regenerated with `run.sh --regen`, and **each harness's derived checks recomputed every one
of those numbers from the boot's own `MB E` memory-map lines and from `kernel.elf`'s extents**, so a
kernel that had regressed could not have enshrined itself. GAP-0078's mitigation held for the sixth
time.

**Why FOUR goldens did not move, and this was designed rather than lucky.** m3-shell, m4-fault,
m5-pci and m6-disk contain `help` output and have no `--regen`; their goldens can only be edited by
mechanical substitution, which is slow and is the thing GAP-0105's intermittent failure came out of.
**M12 adds no shell command**, so `shellStrHelp` is unchanged at 1871 bytes and those four goldens are
byte-identical to M11's. The heap is a syscall; the shell has nothing to say about it that `proc run`
does not already say (ADR-0016 §8). That was a design decision taken *because* of what GAP-0095 and
GAP-0105 cost, and `m12-heap/run.sh` asserts `shellStrHelp` is still 1871 so that the next person to
reach for a `help` line finds out at a structural check rather than in four goldens.

**What did NOT move: `m1-interrupts/expected.txt`.** All 544 bytes byte-for-byte identical.
`heapInit()` prints nothing and is called from `procCreate`, which no boot path reaches before the
shell exists. m0-boot, mb-info and m2-console are likewise untouched.

**Cost:** whoever grows the image pays the `--regen` for five harnesses. Whoever adds the next shell
command pays the substitution for four, and now has a structural check telling them so.

---

## GAP-0107 — The heap is a monotonic bump pointer: no `free`, no shrink, no reuse, no quota

**Domain:** kernel (M12)
**Status:** OPEN, NARROWED at M13 — item 3 is answered: `core/user/libc/malloc.c` is the `malloc`
this entry said userland still had to write, and it keeps exactly the free list item 2 says the
kernel does not. Everything else here is unchanged, and item 1 is why GAP-0111 item 1 exists: a
userland `free` gives memory back to the PROGRAM, and there is still no way to give it back to the
MACHINE. Deliberately scoped out, and named in the source rather than discovered. ADR-0016 §4 makes
the argument; this is the accounting, because "the kernel has a heap now" is exactly the kind of
sentence that gets read as more than it says.

1. **The break only ever moves up.** `sbrk(0)` reports it, a positive increment advances it, and
   nothing lowers it. A negative increment is not expressible — RDI arrives as a `u64`, so a C
   program's `sbrk(-1)` becomes `0xFFFFFFFFFFFFFFFF`, which is refused as `heapRetBadArg`. That
   refusal is exercised by both processes in `m12-heap`, so the behaviour is stated by the machine
   rather than only here.
2. **Nothing is ever reused inside a process's lifetime.** There is no free list, no coalescing, no
   size class and no header on an allocation, because there is no allocation — there are pages. A
   process that grows its heap and stops using it holds those frames until it exits.
3. **A `malloc` is therefore still entirely userland's problem**, which is the normal division of
   labour and is stated because it is the reason this milestone exists. What M12 removes is the wall:
   at M11 no `malloc` could have been written at all. **RESOLVED at M13** — `core/user/libc/malloc.c`
   is that `malloc` (ADR-0017 §6): a first-fit free list with splitting and coalescing, over this
   `sbrk`, whose reuse is measured against a second build of the same source with `free()` disabled.
4. **Granularity is one 4KiB page.** `sbrk(1)` costs a whole page. `m12-heap`'s program asks for
   exactly one byte and checks that the break moved by 4096, so the rounding is a measured property.
5. **There is no per-process quota and nothing limits how much of a machine one process can take.**
   `m12-heap`'s progH takes 507 pages — every page its window has room for — and the only thing that
   stopped it was the address space, not a policy. A second process asking for the same on a small
   machine would take frames the first one is holding and nothing would arbitrate. The bound that
   exists is accidental (the 2MiB window) rather than chosen.
6. **The heap is not visible to `proc` or to `frames`.** GAP-0089 item 5 is narrowed but not closed:
   a slot now records its own base, break and page count, and `PROC HEAP` prints them on every call,
   but `frames` still reports one global total and cannot say who has what.

**Why this is not a bug:** every item is absence, and the two that could be mistaken for presence —
"there is a heap" and "there is an allocator" — are separated in the file's own header, in its
milestone's ADR, and in the harness's summary line.

---

## GAP-0108 — `heapRetNoMem` cannot be reached on any machine this kernel boots, and this was measured

**Domain:** kernel + conformance (M12)
**Status:** OPEN — a refusal path that exists, is correct as far as anybody can tell by reading it,
and that **no boot in the conformance suite walks**. Recorded loudly because m11-proc/run.sh's check
3g found the previous instance of this shape — a refusal code with a sentence and no `return` that
could produce it — and this is the same risk one step further along: a `return` nothing can reach.

**What it is.** `heapSbrk` takes frames one at a time. If `allocFrame()` returns 0 part-way through a
multi-page grow, every page that call already mapped is unmapped and freed (`heapRollback`), the break
does not move, and `heapRetNoMem` (`0xFFFFFFFFFFFFFFFC`) goes back to ring 3.

**Why no boot reaches it.** The heap is bounded by the address space at `heapTopIndex` = 510 pages
minus the program, which is 507 for `m12-heap`'s program. To reach `heapRetNoMem` the frame allocator
would have to have fewer than ~500 free frames while a process is running. Measured:

| machine | free frames | enough to exhaust? |
|---|---|---|
| 128MiB (the suite's default) | 32417 | no, by 64× |
| 32MiB (m7/m8/m9/m10/m11's small-machine boot) | 7842 | no, by 15× |
| 8MiB | — | **the kernel does not get past `M1 END`**; no shell, no `frames` |
| 6MiB, 5MiB | — | no serial output at all |

So the window always fills first, on every machine size this kernel is known to boot on, and there is
no shell command that drains the allocator *partially* — `frames drain` takes everything, after which
`proc run` refuses and no process exists to call `sbrk` at all.

**What stands in for a behavioural test.**

* `m12-heap/run.sh` check 2g requires `heapRetNoMem` to be returned somewhere in `heap.dart`, so it
  cannot become dead text.
* Check 2f parses `heapSbrk`'s body and requires `heapRollback` to appear **before** the
  `heapRetNoMem` return, and requires exactly one `allocFrame()` call in the function, because the
  rollback is written for one.
* A deliberate mutation that deleted the rollback was run against the whole harness and was killed by
  that structural check — and by nothing else, which is exactly what this entry says.

**Cost:** the one arm of this syscall that a real out-of-memory machine would exercise is checked by
reading the source rather than by running it. The honest closing move is either a `frames hold <n>`
shell command that leaves a chosen number of frames free (one command, one help line, four goldens by
substitution — GAP-0106) or a per-process page quota, which GAP-0107 item 5 wants anyway.

**M13 NOTE, measured while scoping that closing move and recorded so the next unit does not
re-measure it.** The command has to be a *partial drain*, not a *hold*. To reach `heapRetNoMem` the
free count must be below ~500 while a process runs, and on the suite's 128 MiB machine that means
withholding **31 900 of 32 417 frames** — so a command that records the frames it is holding cannot
be the shape. `pmm.dart`'s existing ledger is `pmmLedgerN = 64` entries / `pmmLedgerBytes = 512`
(`shellFramesTest` fills it), and growing it is not free: `m12-heap/run.sh` and `m13-libc/run.sh`
BOTH assert `kdata.o`'s donated `.bss` is exactly 9664, so any new per-frame storage is a deliberate
change to two harnesses' structural checks as well as to `kdata.S`'s header and GAP-0053. The shape
that avoids all of it is `frames drain` with a keep-count — the drain path already frees everything
back without a list, so keeping `n` is a loop bound, not a table.

---

## GAP-0109 — The heap's frame-zeroing has no behavioural test that can fail, for the same reason as GAP-0094 and GAP-0102, and this was measured

**Domain:** kernel, conformance (M12)
**Status:** OPEN — the third subsystem in this kernel whose zeroing is correct, load-bearing, and
**unfalsifiable from outside**. GAP-0094 recorded it for `allocFrame`'s callers at M10 and GAP-0102 for
`procSpaceBuild`'s page tables at M11. This entry exists because M12 built what looked like the test
that would finally close it, and then measured that it does not.

**What the test looks like.** `m12-heap`'s program reads every heap page it is given BEFORE it writes
one and reports the number of non-zero words as `ZBAD`; the harness requires zero. On paper that is
exactly the behavioural check GAP-0094 asks for: `allocFrame()` hands back whatever the frame last
held, this kernel recycles frames between processes, and an unzeroed heap page is another process's
data delivered to the one place a program is guaranteed to look.

**What was measured.** `vmZeroFrame(f)` was deleted from `heapSbrk` and the kernel rebuilt. The
harness's *structural* check (2f: `vmZeroFrame` must appear before `vmProgMap`) killed it. With that
check bypassed and the whole session run anyway, **`ZBAD` was `00000000` for both processes** — 512
heap pages read as zero on a kernel that zeroes nothing.

Two further attempts were made and both failed to produce a dirty page:

* **Two `proc run` sessions in one boot.** Session 2's frames come from the allocator's cursor, which
  is monotone: session 1's PML4 landed at `0x13F000` and session 2's at `0x353000` — one frame past
  session 1's last heap page. Nothing was reused.
* **`frames drain` + `frames refill` between the two sessions**, to try to force the cursor to wrap.
  It did not: session 2 still started immediately above session 1's range, and `ZBAD` was still 0.

**Why it cannot fail.** `allocFrame` scans forward from a cursor and only wraps after a full pass over
the bitmap (ADR-0011). A 128MiB machine has 32417 free frames and one full `m12-heap` session uses
about 531, so a frame would have to be handed out and freed roughly **sixty times over** before one
came back dirty. On the 32MiB machine the other harnesses use it is still about fifteen sessions, each
of which takes forty seconds of emulated growth. **Within any boot a harness can drive, every frame a
heap ever receives is virgin RAM, which QEMU has already zero-filled.** The check is therefore
measuring QEMU's `-m` allocation, not the kernel's.

**What actually guards the property**, and it is worth being precise because the property is real: the
structural check that `vmZeroFrame` textually precedes `vmProgMap` inside `heapSbrk`. That is a check
on the source, it dies to a compiler that reorders (it cannot — both are calls with side effects), and
it says nothing about `vmZeroFrame` itself being correct.

**What would close it:** a `frames cursor <n>` or `frames hold <n>` shell command that puts the
allocator's cursor somewhere chosen, so a dirtied frame can be handed straight back out. That is one
command, one `help` line, and four goldens by substitution (GAP-0106) — the same price GAP-0108's
closing move costs, and the two would share it.

**M13 NOTE.** Unlike GAP-0108's version (see its own M13 note), THIS one fits inside what already
exists: `pmm.dart`'s ledger holds 64 frames (`pmmLedgerN`), which is enough to allocate a few dozen
frames, write a nonzero pattern into each, and free them all — leaving dirty frames at the head of
the free list with **no new donated `.bss`**, and therefore without touching the `9664` assertion
that `m12-heap/run.sh` and `m13-libc/run.sh` both make. The cost that remains is the `help` line and
the goldens: `shellStrHelp` is asserted at exactly 1871 bytes by m12's and m13's harnesses as well
as m3–m6's, so a new command is a seven-file change even before anything is proved with it.

---

## GAP-0110 — The pinned-DCDart sandbox must live at a REAL path: `/tmp` breaks it silently, with GAP-0084's error message

**Domain:** tooling, conformance (M12)
**Status:** OPEN — a third step for GAP-0084's procedure, found the hard way at M12 and recorded so the
next unit does not spend an hour proving the pin is broken when it is not.

GAP-0084 establishes the sandbox: a `git clone` of DCDart at `DCDART_PIN.txt`'s commit, `core/frontend`
copied in, and an **rsync'd copy of this repo beside it** so that `kmain.dart`'s hardcoded relative
prelude import (GAP-0003) resolves inside the sandbox. M12 followed it exactly, put the sandbox in
`/tmp/m12-pinned/`, and got

```
dcc build: DccLowerError: no @bare top-level function found in kmain.dart
```

on **every one of the fourteen harnesses** — which is GAP-0084's own documented symptom of the prelude
coming from the wrong checkout, so the first hour went into proving the prelude was right. It was. So
was the compiler. The pin was fine, and **the same failure reproduced with `DCDART_HOME` pointed at the
SHARED checkout**, which is what finally identified it as a sandbox problem rather than a pin problem.

**On macOS `/tmp` is a symlink to `/private/tmp`.** Dart resolves a library's identity through its
REAL path, so the entry file canonicalises to `/private/tmp/…/kmain.dart` while the relative import is
resolved against the `/tmp/…` URI it was given. The prelude is then loaded as **two different
libraries**, the `bare` annotation on `kmain` resolves to neither, and `dcc` correctly reports that it
found no `@bare` top-level function. Nothing about the pin, the clone, the rsync or the kernel is
wrong.

**The fix is one character of path:**

```bash
SANDBOX=/private/tmp/m12-pinned        # NOT /tmp/m12-pinned
```

With that, all fourteen harnesses build and run against the pinned clone unchanged. This is the same
class of hazard GAP-0084's own "a symlink is not enough" paragraph records — Dart resolving through
real paths — arriving from the other direction: there the symlink was the repo, here it is the parent
directory the whole sandbox sits in, and `mktemp -d` on this machine hands you one by default.

**Cost:** one line in whatever script builds the sandbox, and this entry, because the error message
points at the one thing that is not wrong.

---
## GAP-0111 — What `core/user/libc`'s `malloc` does NOT do, listed rather than discovered later

**Domain:** userland (M13)
**Status:** OPEN — deliberately scoped out, and named in the source rather than found later.
ADR-0017 §6 makes the argument; this is the accounting, because "oscortex has a `malloc` now" is
exactly the kind of sentence that gets read as more than it says.

`malloc` IS a real allocator: a first-fit free list with splitting and with coalescing, whose `free`
returns a block to the program and whose next `malloc` of a fitting size gives the same address
back. `m13-libc`'s program measures all three behaviours at runtime and a second build of the same
source with `free()` disabled measures their absence. What it does not do:

1. **It never returns memory to the KERNEL.** `sbrk` cannot shrink (GAP-0107 item 1), so a freed
   block stays in this process's address space until it exits. `free` returns memory to the program,
   not to the machine, and a program whose peak footprint is 400 KiB holds 400 KiB until it dies
   however little it is using.
2. **There is no `realloc` and no `calloc`.** Both are three lines on top of what is here and
   neither has a caller yet; adding an untested `realloc` would be adding the buggiest function in
   every C library with nothing exercising it.
3. **First fit, linear, from the head.** No bins, no size classes, no best fit. A program that frees
   many small blocks and then asks for a large one walks the whole list every time — O(free blocks)
   per `malloc`. Nothing here is allocation-rate-bound yet.
4. **No double-free detection, no guard bytes, no canary, no heap-consistency check.** Freeing a
   pointer twice corrupts the free list and nothing will say so; freeing a pointer that `malloc` did
   not return reads a 16-byte header out of whatever is there. The allocator trusts its caller
   completely, which is what every allocator of this size does and is worth writing down anyway.
5. **Not reentrant and not thread-safe.** There are no threads and no signals on this OS, so this
   costs nothing today and would cost everything on the day there are.
6. **No per-process quota.** GAP-0107 item 5 is unchanged: the only bound on how much of the machine
   one process can take is its own 2 MiB window.
7. **The `heapRetNoSpace` arm of `malloc` is not walked by any boot here.** `m13-libc`'s program
   shows a 4 MiB request refused with `heapRetBadArg` — the increment is larger than the whole window
   — and shows `malloc` returning `NULL` and the program running on. A request refused because the
   window filled up *part-way through a program's life* needs the ~500-page growth loop that
   `m12-heap` runs for eight seconds, and `m13-libc` deliberately does not repeat it. So `grow()`
   returning 0 IS exercised; it is exercised through only one of the kernel's three refusal values.
8. **The alignment is 16 bytes and is not negotiable.** There is no `aligned_alloc` and no way to ask
   for more. 16 is what the x86-64 ABI wants for anything a `movaps` might touch, which is why the
   header is 16 bytes rather than 8.

**Why this is not a bug:** every item is absence. The two that could be mistaken for presence — "it
frees" and "it gives memory back" — are different sentences, and the difference between them is item
1, which is stated in the library's own header, in ADR-0017 §6, and here.

---

## GAP-0112 — `printf` implements five conversions, and everything else is a visible refusal

**Domain:** userland (M13)
**Status:** OPEN by design — this entry exists so that "oscortex has `printf`" is never read as
"oscortex has C's `printf`".

**Implemented, and exactly these:** `%s`, `%d`, `%x`, `%c`, `%%`. That is five.

**Not implemented, and each one produces the two characters `%!` in the output rather than being
skipped:** every width (`%5d`), every flag (`%-s`, `%+d`, `%08x`), every precision (`%.3s`), every
length modifier (`%ld`, `%zu`, `%hhd`), `%u`, `%p`, `%o`, `%f`, `%g`, `%e`, `%n`, and a `%` at the
very end of the format string. `m13-libc/run.sh` reads the set of implemented conversions **out of
printf.c** and requires it to be exactly those five, and requires the final `else` to emit the marker
and to consume no varargs argument.

**Other absences of the same kind:**

* **There is no `stdout`, no `FILE`, no file descriptor and no buffering.** One `printf` call is one
  `write` syscall is one line on the console. A `\n` in a format string is a byte that goes to the
  UART, not a flush.
* **A formatted string longer than 120 bytes cannot be printed.** `elfOwns` refuses a write above
  `userWriteMax` (128), so the library caps its buffer at 120, appends `%!OVF`, and returns `-1`.
  It does not wrap, and it does not chunk into several writes — several `USER WRITE` lines for one
  logical line reads as a bug in the program and becomes one in every golden that captures it.
* **`%d` is `int` and `%x` is `unsigned int` — both 32-bit.** A 64-bit value has to be printed as two
  `%x`es or cast down, and `%ld`/`%lx` are conversions that produce `%!`. `m13-libc`'s program prints
  addresses with `%x` and gets away with it only because the program window is at 256 MiB and fits in
  32 bits; a program above 4 GiB would silently print the low half, and there is no conversion here
  that would not.
* **There is no `snprintf`, no `sprintf` and no `vprintf`.** There is nowhere to put a formatted
  string except the console.
* **`%s` with a NULL pointer prints `(null)`** rather than faulting, which is a choice and not a
  standard.

**Cost:** ordinary C that formats anything with a width or a `%u` compiles and runs and prints `%!`
where the number should be. That is the intended failure and it is loud; the alternative — printing
nothing where the number should be — is the failure this library was arranged to avoid.

---

## GAP-0113 — There is no I/O in the library, because there is no filesystem under it

**Domain:** userland, storage (M13)
**Status:** **NARROWED at M15, and not closed.** ADR-0019 built `open`, `read`, `close` and `seek`,
a per-program file-descriptor table, and a buffered read-only layer (`RFILE`, `rfopen`/`rfread`/
`rfgets`/`rfseek`/`rfclose`) in `core/user/libc/rfile.c`. **A C program on this operating system can
now name a file, read it in pieces at offsets it chooses, and compute something from what it read** —
`m15-fileio` runs one that reads a 20000-byte file in 116 reads of 173 bytes and hashes it to a value
the host computed independently.

**WHAT IS STILL MISSING, ITEM BY ITEM AGAINST THE ORIGINAL LIST BELOW:**

* `open`, `close`, `read`, `lseek`, a file descriptor — **all present**, with the caveats in
  GAP-0122. `lseek` is `seek` and it is absolute-only: there is no `whence`, so no `SEEK_CUR` and no
  `SEEK_END`.
* `FILE`, `fopen`, `fprintf`, `fgets`, `stdin` — **`FILE` and `fopen` are deliberately still absent**
  and are not coming under those names: what exists is `RFILE`/`rfopen`, which reads and does not
  write, has no `stdout`/`stderr`/`stdin`, does not flush and does not `freopen`. ADR-0019 §7 makes
  the argument. `fgets` has a counterpart in `rfgets`. **`fprintf` and `stdin` are absent entirely**,
  and `stdin` is absent for the reason it always was: there is no console-input syscall at all, the
  keyboard belongs to the shell in ring 0, and a process still has no way to read a character.
* `errno` — **still absent, and still deliberately.** Every file call returns its own refusal, all
  eleven of them at or above one floor, so a caller distinguishes an answer from a refusal with one
  comparison and only then has to care which. `rf_last_error()` carries the last one for the buffered
  layer, exactly as `sbrk_last_error()` does for `sbrk`.
* `exit` runs no atexit handlers and flushes nothing — **unchanged, and now it means something**:
  an `RFILE` that is never `rfclose`d is not flushed, because there is nothing to flush; the KERNEL
  closes the descriptor on teardown and prints `FILE ORPHANS <n>` when it had to.
* `argc`/`argv`/`envp` — **unchanged.** `_start` still calls `progMain()` with nothing, and a program
  still cannot be told which file to open: `m15-fileio`'s program has `"DATA.BIN"` in its own
  `.rodata`. This is now the most visible remaining hole, because a file API without a way to name a
  file from outside the program is half an interface.

**What it would take**, restated: `argv` needs the ELF loading path to have somewhere for a command
line to come from (ADR-0015's process creation is the obvious place); `stdin` needs a console-input
syscall and a decision about blocking, which needs a scheduler that can block (GAP-0097); writes need
GAP-0116 item 1, which is a milestone of its own.

**The rest of GAP-0122 is the honest boundary of M15.**

**The original entry, unchanged:**

**Status (as written at M13):** OPEN — and it does NOT narrow GAP-0090, which is the entry for the
filesystem itself.

`core/user/libc` has `write` and nothing else that touches the outside world. Specifically absent:

* **`open`, `close`, `read`, `lseek`, and any notion of a file descriptor.** `write` takes a pointer
  and a length and always goes to the console, because `userSysWrite` always goes to the console.
* **`FILE`, `fopen`, `fprintf`, `fgets`, `stdin`.** There is no console *input* syscall at all: the
  keyboard belongs to the shell, in ring 0, and a process has no way to read a character.
* **`errno`.** `sbrk_last_error()` exists and returns the kernel's own refusal value for the last
  `sbrk`, which is one function's error for one function's caller. A global `errno` that only `sbrk`
  ever set would be a convention pretending to be an interface, and every later syscall would have to
  remember to clear it.
* **`exit` runs no atexit handlers and flushes nothing**, because there is nothing registered and
  nothing buffered.
* **`argc`/`argv`/`envp`.** `_start` calls `progMain()` with nothing. The kernel's `proc run` passes
  a probe address to slot 1 and nothing to slot 0 (ADR-0015), and there is no place in the ELF
  loading path where a command line could come from.

**What it would take**, briefly, so the size is visible: a filesystem (GAP-0090 lists what that
needs), a per-process descriptor table in the process slot, three or four more syscalls, and a
decision about whether `read` blocks — which needs a scheduler that can block a process, and this one
is cooperative (GAP-0097).

**Cost:** a C program for this OS can compute and can print, and cannot read anything. That is the
honest boundary of M13 and it is drawn here rather than discovered by somebody porting something.

---

## GAP-0114 — What `m13-libc` checks by RUNNING and what it checks by READING, and the mutations that survived

**Domain:** conformance (M13)
**Status:** OPEN — the accounting of this harness's own reach, in the shape m10, m11 and m12 each
established: every milestone here has found exactly one check that passed for the wrong reason, and
the way it found it was mutation testing followed by writing down what survived.

**Every mutation was run TWICE**: once against the committed golden, and once with the golden
**regenerated from the mutated library**, so that a byte-exact-serial mismatch could not count as a
kill and only a derived or structural check could.

| mutation | pass 1 (committed golden) | pass 2 (golden regenerated from the mutant) |
|---|---|---|
| `free()` returns without doing anything | killed | killed — *structural*: `free() does not consult libcFreeEnabled` |
| the forward merge deleted from `insertFree` | killed | killed — `process 0 reported ROUND2 0, expected 1` |
| the backward merge deleted from `insertFree` | killed | killed — `offsets [… 0x1010, 0x470, 0x490]; derive.py computes […]` |
| splitting removed (a fitting block is always taken whole) | killed | killed — `offsets [0x10, 0x1010, 0x2010, …]` |
| `malloc`'s overflow guard deleted | killed | killed — `process 0 reported 1 failed self-check(s)` (`MALLOCMAX`) |
| the payload returned at `+8` instead of `+16` | killed | killed — `offsets [0x8, 0x38, 0x438, …]` |
| `%d` prints the digits without the sign | killed | killed — `1 failed self-check` (`FMTRET`), and the `FMT` line text |
| the unsupported-conversion branch made silent | killed | killed — *structural*: `printf's final else does not emit %!` |
| the over-long line truncated with no marker and a positive return | killed | killed — `1 failed self-check` (`OVFRET`) |
| `%x` made uppercase | killed | killed — `process 0 printed 1 BLK lines, expected 2` |
| `strcmp` comparing as signed `char` | killed | killed — `1 failed self-check` (`STRCMPSIGN`) |
| **every `volatile` removed from `string.c`** | killed *(golden only)* | **SURVIVED** |
| **`sbrk`'s refusal test `>=` weakened to `>`** | **SURVIVED** | **SURVIVED** |

**The two survivors, and what they mean.**

* **`string.c` without `volatile`.** The `volatile` is there to stop a loop-idiom pass rewriting
  `memcpy`'s body into a call to `memcpy`. It was then measured: **Apple clang 17 at `-O2` for
  `x86_64-unknown-none-elf` does not do it** — with `-fno-builtin` or without — because LLVM's
  `LoopIdiomRecognize` declines to rewrite a loop into a call to the function containing it. So the
  plain version behaves identically and the only difference in pass 1 was the size of the generated
  code moving every address in the capture. `build-progs.sh`'s "not one `call` inside any of the five"
  check is correct and would catch the hazard the day a toolchain introduced it; **on this toolchain
  it currently has nothing to catch**, and `string.c`'s header comment now says exactly that instead
  of implying the recursion was observed here. This is the finding of M13's mutation pass.
* **`sbrk`'s floor test.** `if (r >= SBRK_ERR_FLOOR)` weakened to `>` is an EQUIVALENT mutant given
  this kernel: `heap.dart` returns exactly three refusal values, all of them strictly above
  `heapRetFloor`, so no call can produce the boundary value that distinguishes the two tests. It is
  left as `>=` because the floor is documented as "at or above is a refusal" (ADR-0016 §1) and a
  fourth refusal value added at the boundary would make the difference real.

**What is checked by reading the source rather than by running anything**, and is therefore only as
good as the parser:

* that `printf.c` implements exactly five conversions (a sixth one that worked would fail this check
  even though the output would be fine — that is the intended direction);
* that the final `else` consumes no varargs argument;
* that the negative control is a `volatile const` word rather than an `#ifdef`;
* that `free()` mentions `libcFreeEnabled` and `insertFree`;
* that there is exactly one `int $0x80` instruction in the library.

**What no boot in this harness exercises at all:**

* `malloc` failing because the window filled up part-way through a program's life
  (`heapRetNoSpace`) — GAP-0111 item 7;
* a double `free`, a `free` of a pointer `malloc` did not return, or any other caller error;
* `memcpy` with overlapping ranges (it is not `memmove` and does not claim to be);
* `strcpy` into a buffer that is too small;
* `printf` with more conversions than arguments, or fewer;
* any allocation pattern long enough to make first-fit's O(n) scan visible.

---

---

## GAP-0115 — `help` grew again at M14, and m3–m6's goldens moved by substitution while m7–m13's moved by `--regen`

**Domain:** conformance (M14)
**Status:** OPEN — the same recurring cost GAP-0059, GAP-0065, GAP-0069, GAP-0072, GAP-0075, GAP-0078,
GAP-0087, GAP-0093, GAP-0095 and GAP-0106 record, at the eleventh milestone that has paid it.
Recorded again because the METHOD is what makes it safe, and the method differed between the two
groups exactly as it has every time.

**Two different causes, and only one of them was a fresh capture.**

* **m3, m4, m5 and m6 moved because `help` grew by FOUR LINES.** `shellStrHelp` went 1871 → **2147**:
  ```
    run <name>    load an ELF program from the filesystem by name and run it
    fs            FAT16: mount the primary master and report its geometry
    ls            list the root directory: name, size, first cluster
    cat <name>    print a file, following its FAT cluster chain
  ```
  because a command that is not in `help` is undiscoverable. Those four goldens were NOT regenerated
  from a boot. The four lines were inserted mechanically after the `run <lba>` line in each file and
  the kernel was then required to reproduce the result byte-for-byte — which it did, at **5511, 4012,
  3796 and 8306** bytes. m3's 80×25 screen golden was rebuilt the same way: four lines inserted, four
  dropped off the top, which is exactly what four more lines of `help` do to a buffer that is already
  scrolling. A substitution that produced a file the kernel does not print fails immediately, which is
  the whole reason this is substitution and not a fresh capture.
* **m7, m8, m9, m10, m11, m12 and m13 moved because the image grew**, which is GAP-0078 exercised for
  the seventh time. M14 adds `fat.dart`'s code, its 63 `@rodata` tables (plus one in `elf.dart`) and **1824 bytes of
  donated `.bss`**, so `__kernel_end` moved and every address and count moved with it: m7's `PMM BASE`
  0x1361B8 → 0x13C1B8 and its free count 0x7EA1 → 0x7E9B, m8's `CR3`/`PML4` and section boundaries,
  m9's TSS/GDT/IDT bases, m10–m13's page-table and program frames. Those seven were regenerated with
  `run.sh --regen`, and **each harness's derived checks recomputed every one of those numbers from
  the boot's own `MB E` memory-map lines and from `kernel.elf`'s extents**. The mitigation held.

**What did NOT move: `m1-interrupts/expected.txt`.** All 544 bytes are byte-for-byte identical, and so
are m0-boot's, mb-info's and m2-console's goldens. `fatInit()` prints nothing and mounting is not done
at boot — deliberately, and ADR-0018 §3 gives the reason. m14-fat asserts M1's golden again as a prefix
of its own capture, and so does every other harness from M4 onwards.

**A SECOND, SMALLER COST, recorded because it is the one that repeats.** Nine harnesses assert the
`.bss` total or the extern count by SUBTRACTING every later milestone's block. All nine had to learn
about `fat_store` (1824 bytes) and `fat_store_addr` (one extern). That is nine mechanical edits, and
it is the price of each harness's number continuing to mean what it meant when it was written — m12's
"a heap needed no new mutable state" and m13's "a C library is entirely userland" are both still true
statements about 9664 bytes, and are still checked as such.

**Cost:** whoever adds the next shell command pays the substitution again for four goldens, whoever
grows the image pays the `--regen` again for seven, and whoever donates `.bss` pays nine subtractions.

---

## GAP-0116 — What the filesystem does NOT do, listed rather than discovered later

**Domain:** kernel (M14)
**Status:** OPEN — deliberately scoped out. GAP-0090's shape, restated for the thing that now exists,
because "there is no filesystem" was easy to be precise about and "there is a filesystem" is where the
vagueness starts.

1. **There are NO WRITES, at any layer.** `WRITE SECTORS` (0x30) is not implemented in `ata.dart`;
   there is no `fatWrite`, no free-cluster search, no directory-entry update, no FAT update, no
   second-FAT mirroring and no crash consistency. This is not "not yet tested" — it is not there, and
   `m14-fat/run.sh` asserts its absence three ways (no ATA write opcode declared, no `port_outw` call
   site outside the framebuffer's VBE pair, no write function by name). Everything downstream — a free
   list, a journal, `fsync` — is absent by construction.
2. **No subdirectories.** Only the root directory is enumerable and only root-directory names are
   findable. A name whose entry has the `0x10` attribute is `fatErrIsDir` and says so. The volume
   carries a real `SUB` directory with real `.` and `..` entries so that the refusal is produced by a
   boot rather than asserted.
3. **No long filenames.** LFN entries (attribute exactly `0x0F`) are skipped and counted. A file whose
   only human-readable name is its long one is reachable only by its 8.3 alias. macOS resolves
   `program-b-with-a-long-name.elf` on this very volume; this kernel calls it `PROGB   .ELF`.
   **The explicit `0x0F` check is redundant and cannot be tested** — `0x0F` includes the volume-label
   bit, so an LFN entry is already skipped as a volume label. That is by FAT's design, not by
   accident, and GAP-0120 records it as a mutation survivor that is not a gap.
4. **No timestamps, no ownership, no permissions**, and nothing that says "this file is executable."
   `run` will try to load any file, and the ELF checks are still the only gate (GAP-0090 item 5).
5. **One open file at a time — NARROWED AT M15, and the sentence that survives is smaller than it
   was.** The chain array in `fat_store` still holds ONE chain and M15 did not make it hold more.
   What M15 added is `fatSelect`/`fatSelected`, which rebuild that one chain from the two numbers a
   descriptor stores (first cluster and size), so **four files can be open at once and be read in any
   order** through `open`/`read`/`close`/`seek` (ADR-0019 §0). The cost is one FAT walk per switch
   between two open files, counted in `fileMetaRebuilds` and printed: `m15-fileio`'s program
   alternates twelve times between two files and the kernel reports exactly 24 rebuilds. So: one
   CHAIN at a time, not one FILE at a time.
6. **A 256-cluster bound, and it has never been reached.** A file needing more is `fatErrTooBig` with
   its own sentence rather than a truncation. **The largest file this has ever been tested on is 20000
   bytes — twenty clusters** (M15's `DATA.BIN`; it was 9632 bytes and ten clusters at M14). Nothing
   here should be read as a claim about a megabyte-sized file.
7. **One partition, and it is the whole disk.** The MBR at sector 0 is overwritten by the boot sector
   on this volume and is not parsed anywhere. A volume inside a partition would not be found.
8. **One device.** Primary master only, ADR-0010 unchanged.
9. **No caching of file data.** The one sector buffer serves the FAT and the root directory. Loading
   the same program twice reads every data sector twice.
10. **`FAT[1]`'s "clean shutdown" and "no hard error" bits are not consulted.** FAT[1] is required to
    be an end mark and nothing more; a volume flagged dirty by a host is read anyway. There is nothing
    to be lost by reading a dirty volume read-only, which is why this is a note and not a refusal.
11. **The second FAT is never read.** `BPB_NumFATs` is validated and the first FAT is used.
    `fsck_msdos` checks that the two agree on the image the harness builds; this kernel would not
    notice if they did not.

---

## GAP-0117 — 8.3 names only, upper-cased, and the characters FAT forbids are not enforced

**Domain:** kernel (M14)
**Status:** OPEN — a deliberate narrowing, recorded because "supports filenames" is exactly the kind
of claim that grows in the retelling.

`fatParseName` turns the rest of the typed line into the 11 raw bytes a FAT directory stores: up to 8
of stem, up to 3 of extension, space-padded, upper-cased. Everything else is `fatErrBadName` — an
empty name, two dots, an empty stem, a stem over 8, an extension over 3, or any byte outside
`0x21..0x7E`.

**Two things it does NOT do:**

* **It does not enforce FAT's forbidden-character set.** `"`, `*`, `+`, `,`, `/`, `:`, `;`, `<`, `=`,
  `>`, `?`, `[`, `\`, `]` and `|` are illegal in an 8.3 name and this parser accepts all of them. It
  is harmless *here* — the lookup simply fails, because no directory entry can contain them — and it
  would stop being harmless the moment there were a write path. Recorded so the write path's author
  finds it.
* **It cannot express a lower-case name.** The shell has no shift handling on the letter keys
  (GAP-0055), so a name is upper-cased on the way in. A directory entry whose stored name has a
  lower-case byte in it — which some formatters write, using the reserved case bits at offset 12 —
  is unreachable from this shell.

The trailing-space padding is printed rather than trimmed in `ls` and in `FS OPEN`, so `HELLO   .TXT`
is what appears. That is the literal directory content, and it makes a name with a space actually in
it visible, which no other tool does.

---

## GAP-0118 — The FAT cache is one sector, and its hit counter is the only evidence it helps

**Domain:** kernel (M14)
**Status:** OPEN — a measurement, not a complaint.

GAP-0090 item 8 said "every sector is read from the drive every time." That is now false for the FAT
and the root directory and still true for file data. The mechanism is one 512-byte buffer and one
"which LBA is in it" word, and the honest description of what it buys is:

* A cluster chain confined to one FAT sector — every chain on this volume, and every chain on any
  volume under 128 clusters of span — costs **one** disk read instead of one per link.
* A root-directory walk costs one read per 16 entries rather than one per entry.
* **File data is not cached at all**, deliberately: `elf.dart` reads it straight into the frame it
  owns, and a cache in between would be a copy.

**What is missing is a test that the cache is CORRECT under invalidation.** The buffer is invalidated
before every read and repopulated after a successful one, so a failed `ataReadInto` cannot leave it
claiming to hold a sector. That ordering is asserted by reading the source, not by a boot: producing a
read failure in the middle of a chain walk needs a drive that fails on demand, and QEMU's IDE
emulation offers no way to ask for one. `fatMetaHits` is incremented on every hit and nothing reads it
back yet — the counter exists so that the day somebody wants to know, the answer is a number.

---

## GAP-0119 — `run 20` is a sector and `run CAFE` would be too, so a file with a hex-digit name is unreachable by `run`

**Domain:** kernel (M14)
**Status:** OPEN — a known, bounded ambiguity, taken on purpose.

`shellElfRunCmd` distinguishes the two forms with `ataParseLba`, which returns a value above
`ataLba28Max` for anything that is not one to seven hex digits. So:

* `run 20` is sector 0x20 — which is what m10-elf, m11-proc, m12-heap and m13-libc's sessions type,
  and why their goldens did not have to change shape.
* `run PROGA.ELF` is a filename.
* **`run CAFE` is sector 0xCAFE, even if a file called `CAFE` exists.** So is `run 20` on a volume with
  a file called `20`. Such a file is reachable by `cat` and not by `run`.

**Why it was not solved.** The alternatives were a distinct spelling for one of the two forms —
`run @20`, or `runlba 20` — and every one of them changes the command four existing harnesses type,
which moves four byte-exact serial goldens and a screen golden for a case no volume in this repo
contains. The ambiguity is one comparison wide, it is documented at the call site as well as here, and
the day a `path` type exists it disappears on its own.

**What would make it a real bug:** a write path. A user who creates `20.TXT` can still `cat` it; a user
who creates `20` cannot `run` it and gets a disk-sector read instead, with no diagnostic that mentions
files at all.

---

## GAP-0120 — What m14-fat checks by RUNNING and what it checks by READING, and the mutations that survived

**Domain:** conformance (M14)
**Status:** OPEN — the entry GAP-0114 established the shape of, written for this milestone's own
harness, because the useful output of a milestone is which of its checks are load-bearing.

**Checked by RUNNING** (seven QEMU boots, one against a correct volume and six against volumes with
one thing deliberately wrong): the BPB validated field by field; the four region offsets computed; the root
directory enumerated with three kinds of entry skipped; a file read across a 98-cluster hole; two
programs loaded **by filename** off interleaved chains, each hashing its own image to a value derived
on the host; four name-level refusals; the numeric `run <lba>` path still refusing a non-program
sector; the frame allocator's count identical before and after; and eight volume-level refusals — no
boot signature, 1024-byte sectors, a FAT32-shaped BPB, a FAT12 cluster count, a chain cycle, a bad
cluster, a short chain, and a chain link one past the last legal cluster.

**Checked by READING the source rather than by running**, and therefore weaker: that
`fatFileSector` indexes the chain array; that `fatBuildChain` calls `fatChainSeen`; that
`elfImageLba` consults `fat.dart`; that `BS_FilSysType` is never named; that no ATA write opcode
exists; that the seam has four call sites. Each of these is a grep, and a grep can be satisfied by
dead code. They are cheap insurance against a refactor, not evidence about behaviour — with the
exception of `fatFileSector` and `elfImageLba`, whose behaviour IS separately proved by the
fragmented volume.

**Checked by NEITHER, and named so nobody assumes otherwise:**

* **Eleven of the twenty-eight refusal codes have never executed on a real boot** —
  `fatErrDiskBoot`, `fatErrClusterSize`, `fatErrReserved`, `fatErrFatCount`, `fatErrRootEntries`,
  `fatErrTotalZero`, `fatErrGeometry`, `fatErrFatSize`, `fatErrEmpty`, `fatErrTooBig`,
  `fatErrChainFree`, plus the three disk-read failures (`fatErrDiskDir`, `fatErrDiskFat`,
  `fatErrDiskData`), which need a drive that fails on demand and QEMU's IDE emulation offers no way to
  ask for one. Each is returned from a reachable line and each has its own sentence, and the harness
  asserts both — but no variant image produces them. **Thirteen of the twenty-eight are exercised by a
  boot**; the rest are exercised only by the reachability grep. `fatErrRootEntries` in particular is a
  named mutation survivor below.
* **The cache's invalidate-before-read ordering** (GAP-0118).
* **Any file larger than ten clusters.** The 256-cluster bound has never been approached.
* **`sectorsPerCluster` other than 2.** The volume uses 2 on purpose — so that a driver which dropped
  the cluster-to-sector multiply entirely would fail — but 1, 4, 8 … 128 are untested.
* **A volume with one FAT.** `BPB_NumFATs` is validated as 1-or-2 and only 2 is ever built.

### The mutation tests: eighteen runs, two rounds, three survivors

Every mutation was run with **`--regen`**, so a byte-exact-serial mismatch could never count as a kill
and only a *derived* or *structural* check could. Sources and goldens were restored between runs and
the kernel rebuilt clean afterwards.

**Round 1 — twelve mutations. Eight died, four survived.**

| mutation | outcome |
|---|---|
| `fatFileSector` computes `first + ci` instead of reading the chain | KILLED — *structural*: "fatFileSector no longer reads the chain array" |
| `fatChainSeen` returns 0 immediately | KILLED — **did not compile**: `dcc` rejects the unreachable tail. Not a valid mutant; re-run evasively in round 2 |
| the short-chain guard deleted outright | KILLED — *structural*: `fatErrChainShort` became unreachable |
| `fatValidCluster`'s upper bound loosened by 64 clusters | **SURVIVED** |
| `fatFat12Max` 4085 → 0 | KILLED — *structural*: "fatFat12Max is not 4085" |
| the `0xE5` deleted-entry check disabled | KILLED — *behavioural*, CHECK 7b: the listing counts changed |
| the `0x0F` long-filename check disabled | **SURVIVED** |
| the volume-label check disabled | KILLED — *behavioural*, CHECK 7b: the listing counts changed |
| `elfImageLba` never takes the chain branch | KILLED — *structural*: "elfImageLba no longer consults fat.dart" |
| `fatMetaHits` never incremented | **SURVIVED** |
| the `rootEnt & 15` check disabled | **SURVIVED** |
| `media` read AFTER the FAT sector replaces the boot sector | KILLED — *behavioural*, CHECK 7a: `fs` refuses with `fatErrMedia`. **This was not a hypothetical: it was the first build's real bug, found by a boot before any check for it existed.** |

**The most important thing round 1 showed is that five of the eight kills were STRUCTURAL GREPS, which
fire before any boot.** A grep can be satisfied by dead code, so those five kills say nothing about
whether the fragmented volume actually catches a contiguous reader. So:

**Round 2 — six EVASIVE mutations, each written to satisfy the grep that killed its round-1
counterpart while still changing behaviour. All six died, and every one of them died to a BOOT.**

| evasive mutation | what killed it |
|---|---|
| the chain is read and then ignored (`fatChain(ci)` still in the source) | CHECK 7d — "the bytes `cat` printed are not HELLO.TXT's bytes" |
| `fatChainSeen` compares against `c + 0x10000`, so it never matches | CHECK 8b — the 2-cycle is not reported as a cycle |
| the short-chain guard fires only above `0xFFFFFFFF` | CHECK 8b — the short chain is not refused |
| `fatOpenActive()` masked to 0, so the loader takes the contiguous branch | CHECK 7e — PROGA does not print its own hash |
| the bad-cluster check compares against `0x1FFF7` | CHECK 8b — the `FFF7` link is not refused |
| `fatValidCluster`'s bound loosened by 64 (round 1's survivor, re-run) | CHECK 8b-bis — **the variant added because of it** |

**The round-1 survivor that got fixed.** `cluster-bound-off-by-two` survived because no chain on any
volume went anywhere near the end of the data region, so `fatErrChainRange` had never executed. A
sixth variant image was added — `outofrange`, whose first link is exactly `clusterCount + 2`, the
first illegal cluster number and precisely the value an off-by-two accepts — and the mutation was
re-run against it and died. **That is the mutation round paying for itself**, and it is why
`m14-fat` now performs seven boots rather than six.

**THREE SURVIVE, and they are the honest finding of this milestone:**

| survivor | why nothing catches it |
|---|---|
| **the `0x0F` long-filename check** | **Not a test gap — a redundancy that is baked into FAT.** The LFN attribute is `0x01\|0x02\|0x04\|0x08`, and that last bit is `ATTR_VOLUME_ID`. An entry skipped for being an LFN entry is *already* skipped for looking like a volume label, which is exactly why the LFN designers chose `0x0F`. Removing the explicit check changes nothing observable and cannot be made to. The check stays because it names the intent; ADR-0018 §5 says so. |
| **`fatMetaHits`, the cache hit counter** | Nothing reads it back. The cache still works; only the evidence disappears. GAP-0118 says so, and the fix is a line of `fs` output nobody has needed. |
| **the `rootEnt & 15` multiple-of-16 check** | No variant image has a root-entry count that is not a multiple of 16, so `fatErrRootEntries` is never produced. The guard is real and its absence is invisible: a volume with, say, 500 root entries would have its last 12 entries read out of the first data sector. A seventh variant would kill it, and was not written. |

Two of the three are **absences of a test**, not of behaviour, and both are named above under "checked
by NEITHER." The third is not a gap at all. That is the point of writing this down: the driver is not
weaker than the table says, and it is not stronger either.

---

## GAP-0121 — The M14 sandbox verification, and the two GAP-0084/0110 steps that were needed unchanged

**Domain:** tooling, conformance (M14)
**Status:** OPEN — not a new gap, a confirmation that the existing procedure still works, recorded so
the next unit knows the cost is stable.

M14 verified all sixteen harnesses against an isolated clone of DCDart at `DCDART_PIN.txt`'s commit
`e3cfe18`. **16/16, first attempt, no re-runs.** The procedure was GAP-0084's and GAP-0110's, applied
verbatim and with nothing added:

```bash
SANDBOX=/private/tmp/m14-pinned          # NOT /tmp -- GAP-0110
git clone <shared>/DCDart $SANDBOX/DCDart && (cd $SANDBOX/DCDart && git checkout e3cfe18)
cp -Rc <shared>/DCDart/core/frontend $SANDBOX/DCDart/core/frontend      # GAP-0084 step 1
(cd $SANDBOX/DCDart/core/dcc && dart pub get --offline)
rsync -a --delete --exclude __pycache__ --exclude build/ <repo>/ $SANDBOX/oscortex_core/   # step 2
cd $SANDBOX/oscortex_core && DCDART_HOME=$SANDBOX/DCDart bash core/tests/conformance/<h>/run.sh
```

**Two things worth recording for the next unit.**

* **`dcc` is not on this machine's PATH**, so `build-kernel.sh` falls through to
  `dart $DCDART_HOME/core/dcc/bin/dcc.dart`. That is what makes `DCDART_HOME` actually select the
  compiler rather than merely the prelude. If a future toolchain puts a `dcc` binary on PATH, the
  sandbox would silently use THAT compiler with the pinned prelude, and the isolation would be half
  what it looks like. Worth checking before trusting a future sandbox run.
* **`--exclude build/` in the rsync matters.** Without it the clone starts with the shared checkout's
  `kernel.elf` and object files, and a harness that failed to rebuild would still find a kernel to
  boot. With it, `$SANDBOX/oscortex_core/core/build/` is created from nothing by the sandbox's own
  `dcc`, which is visible in every log line the run produced.

The sandbox was **225MB** and was deleted afterwards.

---

## GAP-0122 — What a program can and cannot do with a file, listed rather than discovered later

**Domain:** userland, kernel, storage (M15)
**Status:** OPEN — deliberately scoped out. GAP-0113's shape, restated for the thing that now exists,
because "oscortex programs can read files now" is exactly the kind of sentence that grows in the
retelling. ADR-0019 §10 makes the argument; this is the accounting.

**What IS there:** `open(name)` by 8.3 name in the root directory, `read(fd, buf, len)` with the
offset kept in the descriptor, `close(fd)`, `seek(fd, off)` absolute; four descriptors per program;
eleven distinct refusals above one floor; and a buffered read-only layer (`RFILE`) in the C library.

1. ~~**THERE ARE NO WRITES, AT ANY LAYER.** `open` has no mode argument and there is nothing for one
   to mean: GAP-0116 item 1 is unchanged — no ATA write opcode, no `fatWrite`, no free-cluster search,
   no directory update, no FAT update, no `fsync`. `m15-fileio` re-greps for all of it. A program on
   this OS can read every byte of the disk it is allowed to name and cannot change one.~~
   **RESOLVED AT M16** (`docs/decisions/0020-writing-to-a-disk.md`), every clause of it: `open` has a
   mode, `fdwrite` is syscall 9, `close` flushes, and all six named absences are now present.
   **GAP-0127 is the successor entry** and lists what a program still cannot do — the largest being
   that a write descriptor is APPEND-ONLY and starts EMPTY, so there is no writing at an offset and no
   keeping what a file already had. `m15-fileio` no longer greps for any of this: it asserts instead
   that its own four boots leave the image byte-for-byte identical (GAP-0130), which is a claim about
   what ran rather than about what is spellable.
2. **NO PATHS AND NO DIRECTORIES.** `open("SUB")` is `fileRetIsDir` and `open("SUB/X.TXT")` is
   `fileRetBadName`, because `/` is not a character an 8.3 name may contain here. There is no `chdir`,
   no working directory, no `opendir`/`readdir`, and no way for a program to enumerate the volume at
   all — the shell's `ls` is ring-0 code and is not reachable from ring 3.
3. **NO `stat`, NO `fstat`, AND THEREFORE NO WAY TO ASK HOW BIG A FILE IS.** The kernel knows: the
   size is in the descriptor. A program finds it by reading to the end and counting, which is what
   `m15-fileio`'s program does. This is the single most obviously missing call and it was left out
   because a `stat` worth having returns a structure, and copying a structure out to ring 3 is the
   same pointer-validation problem `read` already solved — one call, not a struct ABI, was the smaller
   thing to get right first.
4. **`seek` IS ABSOLUTE-ONLY.** No `whence`, so no `SEEK_CUR` (the descriptor already keeps it) and no
   `SEEK_END` (which needs item 3). Seeking past the end is `fileRetBadSeek`; seeking exactly to the
   end is legal.
5. **NO `dup`, NO `dup2`, NO `fcntl`, NO CLOSE-ON-EXEC.** There is no `fork` and no `exec`, so there
   is nothing for a descriptor to be inherited by. `proc run` gives a new process an EMPTY row.
6. **NO `errno`.** Every call returns its own refusal. This is a choice, not an omission — GAP-0113's
   original entry made the argument and it is unchanged.
7. **NO INPUT THAT IS NOT A FILE.** No `stdin`, no `getchar`, no console-input syscall of any kind.
   The keyboard belongs to the shell, in ring 0. A program still cannot be asked a question.
8. **NO `argv`, SO A PROGRAM CANNOT BE TOLD WHICH FILE TO OPEN.** `m15-fileio`'s program has
   `"DATA.BIN"` in its own `.rodata`. This is half an interface and it is the most visible thing left:
   a file API whose file name is a compile-time constant is a program with a file in it.
9. **FOUR DESCRIPTORS, 512 BYTES PER `read`, 12 CHARACTERS PER NAME.** Each is a refusal a program can
   test and each is asserted by a boot. A fifth `open` is `fileRetNoSlot`; a 513-byte `read` is
   `fileRetBadLen`; a 13-character name is `fileRetBadLen`.
10. **NOTHING BLOCKS AND NOTHING CAN.** GAP-0097 is unchanged: this scheduler is cooperative and
    cannot suspend a process inside a syscall, so every `read` completes or refuses. That is fine for
    a PIO disk and would not be for anything else.
11. **ONE CHAIN, CACHED.** GAP-0116 item 5 as narrowed: four files open at once, one cluster chain in
    `fat_store`, one FAT walk per switch between two of them. Alternating reads between two files
    costs a chain rebuild every time and the count is printed. On this volume a rebuild is one cached
    FAT-sector read; on a volume whose chains span many FAT sectors it would be many.
12. **NO CACHING OF FILE DATA.** GAP-0118 item 3 unchanged. Every `read` reads every sector it touches
    off the drive, so a program reading the same 173 bytes twice does two disk reads. `m15-fileio`'s
    program reads 43336 bytes in 186 reads and the kernel performs 229 sector reads for it.
13. **`fileRetNoOwner` HAS NEVER EXECUTED ON A BOOT.** It needs an M9 payload to execute
    `int $0x80` with RAX = 5, and no payload in `user.dart` does; adding one is sixty bytes of
    hand-written machine code in a `@rodata` table and was not worth a milestone's budget. It is
    returned from four reachable lines and is named here rather than assumed exercised.
    **`fileRetEmpty` IS exercised**: `m15-fileio`'s volume carries `EMPTY.TXT`, a real, legal,
    zero-length FAT file with first cluster 0, which `fsck_msdos` accepts and this kernel refuses to
    open.
14. **A `read` THAT FAILS PART-WAY THROUGH HAS ALREADY WRITTEN INTO THE CALLER'S BUFFER.** The loop
    copies sector by sector; if the third sector of a five-sector read cannot be read off the drive,
    the syscall returns `fileRetIo` and the first two sectors' worth of bytes are in the caller's
    buffer with no count to say so. POSIX would return the short count instead. **This has never
    happened**, because the only way to make a mid-chain read fail is a drive that fails on demand and
    QEMU's IDE emulation offers no way to ask for one (GAP-0118 records the same limitation for the
    FAT cache). It is written down rather than discovered by whoever first runs this on real
    hardware.

---

## GAP-0123 — `read` needed a third argument, and that moved two byte-exact goldens

**Domain:** userland, conformance (M15)
**Status:** OPEN — a cost, paid once, recorded because it is the kind of thing that looks like an
accident in a diff.

`read(fd, buf, len)` does not fit in the two argument registers `sys_call` had. m13-libc requires
**exactly one `int $0x80` instruction in the whole library** — because before M13 each test program
carried its own stub and its own spelling of the syscall numbers, and a disagreement showed up as a
program that faulted rather than as a build error. So the three-argument form became the real stub and
`sys_call` became a C call to it with a zero third argument (ADR-0019 §2).

**`syscall.o` therefore grew, and m13-libc and m14-fat are the only two harnesses that link
`core/user/libc`.** Their programs are a few bytes larger, so m13's heap base moved and m14's
program's self-hash moved, and both harnesses' `expected.txt` and `expected-screen.txt` were
**regenerated deliberately**.

**Why that is safe rather than merely convenient.** Every expectation in both harnesses is *derived*
— m13's six malloc addresses come from `derive.py` and the allocator's own exported constants, m14's
two program hashes come from FNV-1a over the ELFs on the host — so `--regen` can only enshrine a
capture in which all of those still pass. m14-fat's own header documents the flag with that sentence.
The regenerated captures were checked to differ from the old ones **only** in the numbers that depend
on program layout.

**What did NOT move:** `m1-interrupts/expected.txt`, all 544 bytes, byte for byte — and m0-boot's,
mb-info's and m2-console's. `fileInit()` prints nothing, and `fileExitReport()` prints nothing unless
something opened a file, which is why m10's, m11's and m12's goldens did not move either.

**Cost:** whoever adds a fourth syscall argument pays this again for m13 and m14. Whoever adds a
`.c` file to `core/user/libc` pays it too, unless they also add it to those harnesses'
`LIBC_SRCS` — `rfile.c` is deliberately NOT in m13's or m14's list, which is why adding it moved
nothing on its own.

---

## GAP-0124 — What `m15-fileio` checks by RUNNING and what it checks by READING, and the mutations that survived

**Domain:** conformance (M15)
**Status:** OPEN — the entry GAP-0114 established the shape of and GAP-0120 refined, written for this
milestone's own harness, because the useful output of a milestone is which of its checks are
load-bearing.

**Checked by RUNNING** (four QEMU boots — one against a correct volume, one of the negative-control
build, two against volumes with one thing deliberately wrong): a 20000-byte file opened by name and
read in 116 pieces of 173 bytes and hashed to a value the host computed over the same file; the byte
count `read` returns at end of file; `seek` to 0, to `size-8`, to `size` and to `size+1`; two files
open at once and read alternately with the chain rebuilt on every read; the same file open twice with
independent offsets; four descriptors and a fifth refused; **fourteen refusals observed from ring 3 as
return values**, including a `read` into the program's own R+X segment, one into kernel memory, one
into a range straddling the last mapped page and the unmapped one after it, an `open` whose NAME
pointer is a kernel address, and a real zero-length file; the buffered layer agreeing to the byte with
the raw loop over a different syscall sequence; `cat small.txt` typed at the shell; the kernel's nine
exit-line counters, every one derived; the frame allocator's count before and after; and the program's
own R+X hash before and after the read aimed at it.

**Checked by READING the source rather than by running**, and therefore weaker: the three storage-seam
call sites; `fileOwnsWrite`'s body (that it consults `vmEffective`, tests bit 1 AND bit 2, walks page
by page, and bounds `ptr` before doing arithmetic on it); that there is exactly ONE store through a
`dst` pointer in `file.dart`; that `fileSysRead` calls `fileOwnsWrite` before it; that `elfTeardown`
and `procCleanup` release descriptors; that no write opcode, write function or open mode exists. Each
is a grep, and a grep can be satisfied by dead code — which is why round 2 below exists.

**Checked by NEITHER, and named so nobody assumes otherwise:**

* **`fileRetNoOwner` has never executed on a boot** (GAP-0122 item 13).
* **A `read` that fails part-way through** (GAP-0122 item 14) — QEMU's IDE emulation cannot be asked
  to fail on demand, which is GAP-0118's limitation restated for a second subsystem.
* **A file above 20 clusters, and the 256-cluster bound.** GAP-0116 item 6.
* **Descriptors owned by a PROCESS rather than by a `run <name>` program.** Rows 0..3 of the table are
  written by `fileInit` and released by `procCleanup` and are otherwise **untouched by any boot in
  this repo**: `m15-fileio`'s program runs through `run <name>`, so every descriptor it takes is in
  row 4. The row arithmetic is exercised for exactly one value of `row`. A `proc run` program that
  opened a file would exercise the rest, and none does.
* **Two programs holding descriptors at the same time.** Needs the above.

### The mutation tests: twenty runs, three rounds, one survivor

Every mutation was run with **`--regen`**, so a byte-exact-serial mismatch could never count as a kill
and only a *derived* or *structural* check could. Sources and goldens were restored between runs and
the kernel rebuilt clean afterwards.

**Round 1 — fourteen mutations. Eleven died, three survived.**

| mutation | outcome |
|---|---|
| the WRITABLE-bit test deleted from `fileOwnsWrite` | KILLED — *structural*: "does not test bit 2 of vmEffective" |
| `read` does not clamp its count to the bytes remaining | KILLED — *behavioural*: the DATA hash |
| the descriptor's offset advances by the REQUESTED length, not the delivered count | **SURVIVED** |
| `fatSelect` never rebuilds the chain | KILLED — *behavioural*: the two alternating-phase hashes |
| `fileFreeFd` ignores the in-use state and always returns slot 0 | KILLED — *behavioural*: the alternating hashes (both descriptors became the same one) |
| `seek`'s bound loosened by 4096 | KILLED — *behavioural*: `PAST` is an offset instead of a refusal |
| the sector index computed from `done` instead of `pos + done` | KILLED — *behavioural*: the DATA hash |
| `fileCopyOut` ignores the offset inside the sector | KILLED — *behavioural*: the DATA hash |
| `fileOwnsWrite` walks only the FIRST page of the range | **SURVIVED** |
| `open` skips the validation of its NAME pointer | KILLED — *behavioural*: `REFUSE OPEN2` |
| the 12-character name bound loosened to 64 | KILLED — *behavioural*: the over-long name is refused as a BAD NAME instead of a BAD LENGTH |
| `fileReleaseOwner` closes nothing | **SURVIVED** |
| `close` counts the close but does not free the slot | KILLED — *behavioural*: the later opens run out of descriptors |
| the bytes counter never incremented | KILLED — *derived*: the exit line's `BYTES` field |

**TEN OF THE ELEVEN KILLS WERE BOOTS**, which is the number GAP-0120 wanted and did not get: m14's
round 1 produced eight kills of which five were structural greps. The one structural kill here got an
evasive counterpart in round 2.

**Two of the three survivors were FIXED rather than merely recorded.**

* **`fileOwnsWrite` walking only the first page.** Every buffer the program used was in `.bss`, so
  every range it passed lay inside one writable region and a validator that checked the first page
  only was indistinguishable from one that checked all of them. **Fixed by adding `__rw_end` to
  `prog.ld` and a `read` aimed at `align_up(__rw_end) - 8` with a length of 64** — a range whose first
  page is the last mapped page of the image and whose second page is not mapped at all (the stack is
  at `0x101FF000`, far above). The mutation was re-run and died to a boot.
* **`fileReleaseOwner` closing nothing.** The program tidied up perfectly, so a teardown that did
  nothing was invisible. **Fixed by having the program deliberately leave one descriptor open**, so
  the kernel must close it and print `FILE ORPHANS 01`. The mutation was re-run and died to a boot.
  This also means the teardown path — which is shared with the FAULT path — is now exercised.

**Round 2 — five runs: two evasive mutations and the three survivors re-run. Four died, one survived.**

| mutation | what killed it |
|---|---|
| the WRITABLE-bit test kept in the source but compared against 0 so it never fires (evades round 1's grep) | *behavioural* — `REFUSE READ`: the read into `.rodata` was accepted |
| `fileOwnsWrite`'s two bounds rewritten so every pointer passes | *structural* — **and that is a failure of the MUTANT, not a success of the check**: it rewrote the two lines 2c looks up by name, so the grep caught it before any boot. Round 3 below is the honest version |
| `fileOwnsWrite` first-page-only (round 1's survivor, re-run) | *behavioural* — `REFUSE STRADDLE`, the check added because of it |
| `fileReleaseOwner` closes nothing (round 1's survivor, re-run) | *behavioural* — `FILE ORPHANS 01` did not appear |
| the offset advances by the requested length (round 1's survivor, re-run unchanged) | **SURVIVED** |

**Round 3 — one mutation, written properly evasive. It died to a boot.**
Both bit tests kept textually intact and compared against 0, so *every* line check 2c inspects —
`vmEffective(a)`, `u64(2)`, `u64(4)`, the page advance, the bound before the arithmetic — is present
and `fileOwnsWrite` nevertheless returns 1 for every pointer in the program window. Killed by
`REFUSE READ`: the read into the program's own read-only segment came back as a byte count.

**ONE SURVIVES, and it is the honest finding of this milestone.**

| survivor | why nothing catches it |
|---|---|
| **the descriptor's offset advancing by the REQUESTED length instead of the delivered count** | **Not a test gap — unobservable through this interface.** A short read happens only at end of file, so after one the offset is at or past the size either way, and the very next `read` returns 0 in both. Nothing can tell `pos == size` from `pos > size`, because there is no `tell`, no `SEEK_CUR` and no way to ask a descriptor where it is (GAP-0122 items 3 and 4). The code is right; the mutation is latent. **The day `tell` or `SEEK_CUR` exists this becomes a real bug and a real test**, and this row is where whoever adds one should look. |

Compare GAP-0120's three survivors: two of those were absences of a test and one was untestable in
principle. This milestone has one, and it is the third kind.

---

## GAP-0125 — `m14-fat` compared an exit status in the wrong hex case, and passed for two milestones because both statuses happened to be decimal

**Domain:** conformance (M14, found at M15)
**Status:** **FIXED** — recorded because the way it was found is the point.

`m14-fat/derive.py` emitted `PROGB.ELF`'s expected exit status as `%02x` and `run.sh` greps the
transcript for `ELF DONE EXIT 00000000000000<that>`. **`uartPutHex` prints UPPER-case hex.** The check
therefore only ever worked for a status whose two hex digits are both decimal — and at M14 both
programs' statuses were: `0x48` and a value in the same range. The check was a literal `grep -F` for a
string the kernel can only print when the byte contains no `A`–`F`.

**How it surfaced.** M15 added `sys_call3` to `core/user/libc/syscall.c` (GAP-0123), which grew
`syscall.o`, which grew both of m14's programs, which changed the FNV-1a hash each computes over its
own R+X segment, which changed `PROGB.ELF`'s exit status from a decimal-digit value to `0x3E`. The
harness then failed with `the transcript does not contain: ELF DONE EXIT 000000000000003e` while the
capture plainly contained `...003E`.

**The fix is one character** (`%02x` → `%02X`) and it is in `m14-fat/derive.py` with a note beside it.

**What this says about the harness, honestly.** m14-fat is one of the most thorough harnesses in this
repo and this check had a one-in-four chance of being wrong-but-green from the day it was written.
Nothing about it was weak except the case of one letter, and no mutation round would have found it,
because every mutant was run against the same two programs whose statuses were both decimal. **The
thing that found it was an unrelated change to a shared file.** That is worth writing down: a check
that greps for a formatted number is only as good as the format, and the format is not tested by
anything unless the number moves.

---

## GAP-0126 — The M15 sandbox verification: the same three steps, still, and the reason a fourth was not needed

**Domain:** tooling, conformance (M15)
**Status:** OPEN — not a new gap, a second confirmation that GAP-0084's and GAP-0110's procedure is
stable. Recorded so the next unit knows the cost has not moved.

M15 verified all **seventeen** harnesses against an isolated clone of DCDart at `DCDART_PIN.txt`'s
commit `e3cfe18`. **17/17, first attempt, no re-runs.** The procedure was GAP-0084's and GAP-0110's,
applied verbatim and with nothing added:

```bash
SANDBOX=/private/tmp/m15-pinned          # NOT /tmp -- GAP-0110
git clone <shared>/DCDart $SANDBOX/DCDart && (cd $SANDBOX/DCDart && git checkout e3cfe18)
cp -Rc <shared>/DCDart/core/frontend $SANDBOX/DCDart/core/frontend      # GAP-0084 step 1
(cd $SANDBOX/DCDart/core/dcc && dart pub get --offline)
rsync -a --delete --exclude __pycache__ --exclude build/ <repo>/ $SANDBOX/oscortex_core/   # step 2
cd $SANDBOX/oscortex_core && DCDART_HOME=$SANDBOX/DCDart bash core/tests/conformance/<h>/run.sh
```

**The two things GAP-0121 said to check were checked again.** `dcc` is still not on this machine's
PATH, so `build-kernel.sh` still falls through to `dart $DCDART_HOME/core/dcc/bin/dcc.dart` and
`DCDART_HOME` really does select the compiler; the sandbox script now says so out loud, printing a
warning if a `dcc` binary ever appears on PATH, because a future toolchain that installed one would
make the isolation half what it looks like without changing a single log line. And `--exclude build/`
still matters: `$SANDBOX/oscortex_core/core/build/` was created from nothing by the sandbox's own
compiler.

**What M15 added to the sandbox's reach, and it is not nothing.** M15's harness compiles a C library
of FIVE objects and links two programs, and neither the library nor the programs go through `dcc` at
all — they are `clang` and `x86_64-elf-ld`, which are the same binaries in the sandbox and outside it.
So the sandbox isolates the KERNEL's compiler and not userland's, which was already true at M13 and
M14 and is worth stating once: **a pinned-DCDart run says nothing about the C library.** What makes
the library's behaviour reproducible is that every expectation about it is derived from the binaries
that were actually built, in the same run.

The sandbox was **226MB** and was deleted afterwards.

---

## GAP-0127 — What a program can and cannot do to a file now that it can write one

**Domain:** userland, kernel, storage (M16)
**Status:** OPEN — deliberately scoped out. GAP-0122's shape, restated for the thing that now exists,
because "oscortex programs can write files now" is exactly the kind of sentence that grows in the
retelling. ADR-0020 §10 makes the argument; this is the accounting.

**GAP-0122 ITEM 1 IS RESOLVED AND IS REPRODUCED HERE STRUCK THROUGH**, because the sentence it made
in capitals — "THERE ARE NO WRITES, AT ANY LAYER" — was true for two milestones and is the thing this
one changed:

> ~~1. **THERE ARE NO WRITES, AT ANY LAYER.** `open` has no mode argument and there is nothing for one
> to mean: no ATA write opcode, no `fatWrite`, no free-cluster search, no directory update, no FAT
> update, no `fsync`. A program on this OS can read every byte of the disk it is allowed to name and
> cannot change one.~~
>
> **RESOLVED at M16** (`docs/decisions/0020-writing-to-a-disk.md`), item by item: `ataWriteFrom`
> (0x30) with `FLUSH CACHE` (0xE7) after every sector; `fatFindFree`/`fatAlloc`/`fatTruncate`;
> `fatDirCreate`/`fatDirWrite`; `fatSetEntry` writing every copy of the FAT; a `mode` argument on
> `open`; `fdwrite` as syscall 9; and `close` as the flush. Verified by `fsck_msdos` accepting the
> written volume and by macOS's own `msdos` driver reading every file the guest wrote back
> byte-for-byte — not by this kernel reading back what this kernel wrote.

**What IS there:** `open(name, O_WRITE)` creating or emptying a file in the root directory,
`fdwrite(fd, buf, len)` appending up to 512 bytes at a time, `close(fd)` flushing the directory entry,
thirteen distinct refusals above one floor, and a volume the host tools accept.

**And here is what is not.**

1. **A WRITE DESCRIPTOR IS APPEND-ONLY AND STARTS EMPTY, AND THERE IS NO WAY TO ASK FOR ANYTHING
   ELSE.** `open(name, O_WRITE)` is create + truncate + append, all three, indivisibly. There is no
   `O_APPEND` that keeps what a file already had, no `O_EXCL`, no `O_CREAT` separate from the
   truncation, and no way to write at an offset. `seek` on a write descriptor is `FILE_EBADMODE`.
   **This is the single largest thing M16 did not build** and ADR-0020 §0 gives the reason: a general
   write needs the cluster chain of a file that is being modified while it is being walked, which is
   the case where a wrong FAT update joins two files together. What it would take: a `fileFdChain`
   that survives a seek, a `fatSelect` on the write path, and a read-modify-write that can land in the
   middle of an existing chain rather than only at its end.
2. **NO READ-WRITE MODE.** A descriptor is a read descriptor or a write descriptor and the other
   operation on it is `FILE_EBADMODE`. A program that wants both opens the file twice — and since
   `open(..., O_WRITE)` truncates, it must write first and read after.
3. **NO `unlink`, NO `rename`, NO `mkdir`, NO `rmdir`.** A file can be created and its contents
   replaced; it cannot be removed or moved. Marking a directory entry 0xE5 and freeing its chain is
   twenty lines and was left out because "delete" is the operation whose failure modes are worst and
   because nothing in this OS yet needs one — `m16-filewrite`'s volume carries a deleted entry that
   `make-image.py` planted, and the kernel REUSES it, which is the half of the mechanism that is
   built.
4. **NO TIMESTAMPS.** `DIR_CrtTime`, `DIR_WrtTime` and `DIR_LstAccDate` are written as zero on a file
   this kernel creates, and are LEFT ALONE on a file it truncates — so a file that has been rewritten
   still carries the date the formatter gave it. This kernel has no wall clock (GAP-0058: the PIT is
   masked at rest so `ticks` stays reproducible, and there is no RTC driver). Zero is what a FAT date
   field is allowed to be and what `fsck_msdos` and macOS's `msdos` driver both accept; a made-up date
   would be worse than no date.
5. **A FILE WHOSE CHAIN IS BROKEN CANNOT BE OVERWRITTEN.** `open(..., O_WRITE)` on a file whose FAT
   chain is a cycle, runs into a bad cluster, or disagrees with the directory entry's size is
   `FILE_EIO` — it is not truncated and not repaired. The volume disagrees with itself about that
   file, and choosing which of the two accounts to believe is a repair tool's job. `m16-filewrite`
   boots that case and requires the image to come back byte-for-byte identical.
6. **NO `fsync`, AND `close` IS NOT OPTIONAL.** The FAT links and the data sectors reach the drive as
   they are produced; the directory entry that makes them a file reaches it at `close` — or at
   teardown, because `fileReleaseOwner` flushes a write descriptor before dropping it, so a program
   that faults with a file open leaves the bytes it had written rather than a chain nothing points at.
   There is no third path and no way to ask for a flush without giving up the descriptor.
7. **NOTHING IS CRASH-CONSISTENT IN THE SENSE A JOURNAL WOULD BE, AND THIS IS EXACTLY WHAT AN
   INTERRUPTION COSTS.** ADR-0020 §3 gives the ordering rules; this is what they buy and what they do
   not:
   * between allocating a cluster and linking it → **one leaked cluster**, which `fsck` calls a lost
     chain and can reclaim;
   * between the last data sector and `close` → **the new data is lost and the old file is intact**
     (or, for a new file, a zero-length file is left behind);
   * between the two copies of one FAT sector → **the copies differ**, which `fsck` reports and
     repairs from copy 0;
   * **during a single sector write** → that sector is undefined, and nothing here can detect it.
     There is no checksum anywhere in this filesystem, because FAT has none.
   The one thing that is NOT possible is two files sharing a cluster, which is the ordering rule
   ADR-0020 §3 item 2 exists for.
8. **ONE FILE'S WRITES ARE NOT ORDERED AGAINST ANOTHER'S.** Two write descriptors open at once each
   flush at their own `close`, and nothing sequences them. There is no `rename`-based atomic replace
   either (item 3), so "write a new version and swap it in" is not expressible.
9. **THE ROOT DIRECTORY ONLY.** `open("SUB/X.TXT", O_WRITE)` is `FILE_EBADNAME` for GAP-0122 item 2's
   reason — `/` is not a character an 8.3 name may contain — and `open("SUB", O_WRITE)` is
   `FILE_EISDIR`. Nothing can create, extend or shorten a subdirectory.
10. **512 BYTES PER `fdwrite`, AND THE COUNT IS LOAD-BEARING.** A longer call is `FILE_EBADLEN` and is
    not split. A SHORT return is not an error: when the volume fills up, the bytes reported really are
    on the drive and the next call is `FILE_ENOSPACE`. This is deliberately better than what `read`
    does (GAP-0122 item 14, unchanged), and `m16-filewrite`'s negative control is a build of the same
    source that ignores the count.
11. **NO FREE-SPACE FIGURE A PROGRAM CAN ASK FOR.** There is no `statfs` and no `df`; a program
    discovers the volume is full by being refused. The kernel does not keep a free-cluster count
    either — `fatFindFree` scans, which on this volume is up to 4200 FAT entries against a
    one-sector cache, and the cost is real: the last two clusters of `m16-filewrite`'s NEW.BIN each
    cost a full scan of the volume.
12. **THE FREE-CLUSTER HINT IS NOT PERSISTED AND IS NOT `FSINFO`.** FAT32's `FSInfo` sector holds a
    next-free hint across mounts; FAT16 has no such sector and this kernel keeps its hint in RAM, so
    every boot starts searching from cluster 2. That is correct and slow, and it is why
    `m16-filewrite` can predict every allocation from a cold boot.
13. **A NAME THIS KERNEL CREATES IS CHECKED AGAINST FAT'S RULES AND A NAME IT READS IS NOT.**
    `fatNameLegal` refuses the fifteen bytes a FAT short name may not contain, on the write path only.
    ADR-0020 §5 gives the argument. The read path's laxity (GAP-0117) is unchanged and deliberate.
14. **NOTHING BLOCKS AND NOTHING CAN.** GAP-0097 and GAP-0122 item 10 are unchanged. Every `fdwrite`
    completes or refuses, with interrupts off, on a cooperative scheduler. A 512-byte write is two
    sector writes and two FLUSH CACHE commands with the CPU spinning on BSY for all of it.
15. **THE WRITE PATH HAS NEVER FAILED ON A REAL DRIVE, BECAUSE NOTHING HAS RUN IT ON ONE.**
    `ataWriteFrom` has six distinct failure codes and QEMU's IDE emulation has produced none of them.
    The same limitation GAP-0118 records for the read path applies here and matters more: a write that
    fails half way through a multi-sector request leaves the descriptor describing what actually
    reached the drive (which is better than the read path manages), but the sector that was in flight
    is undefined and nothing can say so.
16. **`ataWriteNoFlush` AND `ataWriteTrailing` HAVE NEVER EXECUTED.** They are returned from
    `ataFlushCache` and from the post-transfer status check, and QEMU never produces the conditions.
    Named here rather than assumed exercised, exactly as GAP-0122 item 13 names `fileRetNoOwner`.
17. **A FILE OPEN FOR READING WHILE THE SAME FILE IS OPENED FOR WRITING WILL READ RUBBISH, AND
    NOTHING STOPS IT.** This is the sharpest one on the list and it is written first among the three
    below for that reason. A read descriptor holds the first cluster and the size the directory entry
    had at `open`; `open(..., O_WRITE)` on the same name frees that chain and hands the clusters to
    whatever asks next. The read descriptor then walks a chain that no longer describes anything —
    most likely getting `fileRetIo` from `fatSelect`'s validation, and at worst reading a cluster that
    now belongs to a different file. **There is no sharing mode, no open-file table keyed by name and
    no reference count**, because GAP-0122 item 5 is unchanged: descriptors are per-program rows in a
    fixed table and nothing indexes them by what they point at. The fix is an open-file layer, which
    is a milestone rather than a patch.
18. **A NAME THIS KERNEL CREATES IS NOT CHECKED FOR COLLISION WITH ANYTHING `fatLookup` SKIPS.**
    `fileMakeEmpty` looks the name up first, so an existing FILE is truncated rather than duplicated —
    but `fatLookup` deliberately ignores volume labels and long-filename entries (ADR-0018), so
    `create("OSCORTEX")` on a volume whose label is `OSCORTEX` makes a FILE with the same eleven name
    bytes as the label. `fsck_msdos` accepts it. It is not data loss and it is not right either.
19. **A DELETED DIRECTORY ENTRY IS REUSED WITHOUT LOOKING AT WHAT PRECEDES IT.** `fatDirFreeSlot`
    takes the first 0x00 or 0xE5 slot. On a volume where some other driver deleted a long-named file
    and left its LFN entries live — which Windows and macOS do not do, so this is a malformed-volume
    case — the new short entry would acquire a stale long name. Refusing a 0xE5 slot whose predecessor
    is a live 0x0F entry is about ten lines; it was left out because every volume this kernel has met
    marks the whole run deleted, and because the failure is a wrong NAME rather than wrong BYTES.

---

## GAP-0128 — `fdwrite` is not called `write`, and syscall 1 is still the console

**Domain:** userland (M16)
**Status:** OPEN — a naming decision with a cost, recorded so it is a decision rather than an
accident.

Syscall 1 has been `write(buf, len)` since M9 and it prints on the console. Six byte-exact goldens
contain its output, `core/user/libc/printf.c` is built on it, and it takes no descriptor. M16's file
write takes one. **Two C functions called `write` distinguished only by arity is the kind of thing
that compiles and then does the wrong one**, so the new call is `fdwrite(fd, buf, len)` and the old
one is untouched.

**What that costs:** ordinary C that says `write(1, buf, n)` does not compile here and would not mean
what its author intended if it did. There is no `stdout`, no file descriptor 1, and no `FILE`.

**What a real `write(fd, ...)` would take**, so the size is visible: syscall 1 would have to grow a
descriptor argument, descriptors 0/1/2 would have to be pre-opened in every owner row and mean
something (`fileOwnerRow` currently hands out an EMPTY row), `userSysWrite`'s `USER WRITE ` prefix
would have to go or become a property of a console descriptor rather than of the syscall — and that
prefix is in six goldens. It is a milestone's worth of change to the shape of the syscall table and it
buys source compatibility with C that this OS cannot run anyway (no `stdin`, no `argv` — GAP-0122
items 7 and 8, both unchanged).

---

## GAP-0129 — What `m16-filewrite` checks by RUNNING and what it checks by READING, and the mutations that survived

**Domain:** conformance (M16)
**Status:** OPEN — the entry GAP-0114 established the shape of and GAP-0120 and GAP-0124 refined,
written for this milestone's harness. **A test suite's own coverage is a thing to measure, not to
assume**, and the measurement is here rather than in a commit message.

### What is checked by RUNNING (seven boots)

* **A file that was not on the volume is created and filled.** NEW.BIN, 21801 bytes, written in
  173-byte pieces — a size that divides neither a sector (512) nor a cluster (1024) nor the file.
* **The clusters it lands on were PREDICTED.** `derive.py` implements `fat.dart`'s allocation policy
  independently and computes the chain before the boot; `run.sh` reads the chain back out of the image
  afterwards. One of its links goes **backwards by 2923 clusters**, because the allocator ran off the
  end of the free band and wrapped — which is a property of the kernel rather than of the image.
* **A file that WAS there is replaced**, and its five scattered clusters are freed and partly reused.
* **Both directions of the zero-length case**: a file created and closed without a byte (first cluster
  0, size 0 — which the host accepts and this kernel refuses to open for reading), and a zero-length
  file that was already on the volume being given contents.
* **Thirteen refusals, observed from ring 3 as return values** — including a source page INSIDE the
  program's own window that is not mapped, and a range whose FIRST page is mapped and whose second is
  not. Those two are the ones that separate "the validator checked the bounds" from "the validator
  walked every page", and they are in the program because m15-fileio's first mutation round found the
  read-side equivalent surviving without them.
* **A write OUT OF `.rodata` succeeding**, which the write-side pointer validator would have refused.
* **`fsck_msdos` accepting the written volume**, with no lost chain, no FAT difference and no bad
  directory.
* **macOS's own `msdos` driver mounting it** and reading every file the guest wrote back byte-for-byte
  against payloads the harness generated independently.
* **KEEP.BIN unchanged**, 307200 bytes on the clusters INTERLEAVED with NEW.BIN's.
* **Both copies of the FAT byte-for-byte identical.**
* **A SECOND BOOT of the machine** finding all of it, running a build of the same source with no
  `fdwrite` and no `create` in it, and leaving the image byte-for-byte identical.
* **A volume with five free clusters** — ten once `SEED.TXT` is truncated, eight left after its
  rewrite — producing a short write of exactly 8192 bytes and then `FILE_ENOSPACE`, still clean
  afterwards.
* **A DIRECTORY WITH A LIVE-LOOKING ENTRY ONE SLOT PAST ITS END MARKER**, which `fsck_msdos` refuses
  as built and calls CLEAN after the guest has consumed the marker slot and re-established the marker.
  That boot exists because mutant 9 survived without it.
* **The negative control** reporting 8304 where the kernel reported 8192, with the two boots leaving
  identical volumes.
* **A full root directory** refusing `create` with nothing written.
* **A cyclic chain** refusing an open-for-write BEFORE freeing anything, leaving the image
  byte-for-byte identical.

### What is checked by READING the source

Eight structural checks, listed in `run.sh`'s own PASS line. The ones that carry weight:

* `ataWriteFrom` **defined once and called from exactly one place**, ending in `ataFlushCache()`, with
  the only `port_outw` aimed at 0x1F0 inside it.
* `fatSetEntry` looping over `BPB_NumFATs`.
* `fileOwnsWrite` and `fileOwnsRead` bounding their pointer before any arithmetic, walking the range
  page by page, and **differing in exactly the WRITABLE test**.
* `fileCopyOut` and `fileCopyIn` each having one call site, each after its own validator.

**These are read rather than run because there is no boot that could distinguish them.** A kernel
whose `ataWriteFrom` did not flush passes every one of the six boots, because QEMU's IDE emulation
persists a write with or without the flush — see the survivor table below.

### The mutation round

**Twenty mutants across three rounds, EVERY ONE RUN WITH `--regen`** so that a byte-exact serial
mismatch could never count as a kill and only a DERIVED or STRUCTURAL check could. That is GAP-0124's
standard and it is what makes the round mean anything: without it, every mutant that changed one byte
of output would "die" to the golden and the number would measure nothing.

**SIXTEEN KILLED, FOUR SURVIVED. THIRTEEN OF THE SIXTEEN KILLS WERE BOOTS**, three were structural
checks, and two of the survivors were FIXED rather than recorded — the harness grew a check and a
seventh boot, and both mutants were re-run and both died.

| # | what was broken | verdict | what killed it |
|---|---|---|---|
| 1 | `ataWriteFrom` does not issue FLUSH CACHE | KILLED | structural 2d. **A boot cannot** — see below |
| 2 | the two bytes of each 16-bit word go out swapped | KILLED | boot: `SEED BACK` hashed wrong |
| 3 | no wait for BSY to clear after the data | **SURVIVED** | untestable on QEMU |
| 4 | only ONE copy of the FAT is updated | KILLED | structural 2d — **and a boot too**, see below |
| 5 | `fatFindFree` hands out clusters that are in use | KILLED | boot: `ls` showed NEW.BIN on the wrong cluster |
| 6 | a cluster is LINKED before it is marked end-of-chain | **SURVIVED → FIXED → KILLED** | structural 2d, added because it survived |
| 7 | truncate does not aim the hint at the freed chain | KILLED | boot: the predicted chain was wrong |
| 8 | the directory entry's FIRST CLUSTER is never written | KILLED | boot |
| 9 | the end-of-directory marker is not re-established | **SURVIVED → FIXED → KILLED** | boot, on a `dirjunk` volume added because it survived |
| 10 | the allocation test is "on a cluster boundary" | **SURVIVED** | untestable on QEMU |
| 11 | a partial sector is zeroed instead of read back | KILLED | boot |
| 12 | `fileOwnsRead` also demands the WRITABLE bit | KILLED | boot: the `.rodata` write was refused |
| 13 | `fileOwnsRead` walks the range and asks nothing | KILLED | boot: HOLE and STRADDLE were accepted |
| 14 | `close()` does not flush the directory entry | KILLED | boot |
| 15 | EVASIVE: FLUSH CACHE's opcode to the wrong register | **SURVIVED** | untestable on QEMU |
| 16 | "EVASIVE": a failed write leaves the cache stale | **SURVIVED** | untestable on QEMU — and see the disclosure below |
| 17 | a mid-sector write runs past the end of the sector | KILLED | boot |
| 18 | `fdwrite` reports what it was ASKED for | KILLED | boot: the `full` volume's short write |
| 19 | EVASIVE: the data region is off by one cluster | KILLED | boot |
| 20 | the descriptor's SIZE never advances | KILLED | boot |

### The three killed by a GREP, and how far a boot actually reaches

M1, M4 and M6 die to structural check 2d, which runs before QEMU starts. **"It would also have died
to a boot" is exactly the kind of claim this project does not get to make without measuring**, so each
was run again with check 2d REMOVED. The answers are not the same:

* **M1 (no FLUSH CACHE) SURVIVES A BOOT.** Every one of the seven boots passes, `fsck_msdos` accepts
  the volume and macOS's driver reads every file back. **QEMU persists a write to a raw image whether
  or not the drive's cache is flushed**, so no test in this harness — and no test that could be
  written for this emulator — distinguishes a driver that flushes from one that does not.
  **THE FLUSH IS VERIFIED STRUCTURALLY AND ONLY STRUCTURALLY**, and that is stated here rather than
  left to be assumed from the fact that check 2d exists. On real hardware with a write-back cache and
  a power cut it is the difference between a file and nothing.
* **M4 (one copy of the FAT) IS KILLED BY A BOOT.** With 2d removed it dies to the DERIVED sector
  count: `FILEW ... DISKW 0000012E` is 302, and a one-copy driver writes 249. That is the check that
  made deriving `disk_writes` from the FAT-entry count worth the arithmetic, and it means the
  structural check is belt-and-braces rather than the only thing holding.
* **M6 (link before end-of-chain) SURVIVES A BOOT.** Nothing inside an emulator loses power between
  two `out` instructions, so the two orders are indistinguishable by running. Structural only, and the
  check exists precisely because the mutant survived round 1.

### The four survivors, and the single reason all four survive

**Every one of them needs something QEMU's IDE emulation cannot be asked for: a write that FAILS, or
a machine that loses power between two instructions.** GAP-0118 records the same limitation for the
read path and GAP-0124 for the read syscall; this is its third appearance and it is now the dominant
reason a mutation survives here.

* **M3 — no wait for BSY after the data.** QEMU clears BSY before the `out` that ends the transfer
  returns, so the wait never has anything to wait for. On hardware it is the difference between the
  next command finding a busy drive and finding a ready one. Not a test gap; a property of the
  emulator.
* **M10 — the allocation test.** `offset on a cluster boundary` and `offset past what is allocated`
  agree on every path where no write fails, and they differ only after a `fileWriteChunk` that
  allocated a cluster and then could not write its data sector. **This has never happened**, for M3's
  reason. The code is right and the mutation is latent; the day a drive can be made to fail on demand,
  this becomes a real test.
* **M15 — FLUSH CACHE's opcode written to the sector-count register.** Genuinely evasive: every line
  check 2d reads is textually intact — `ataCmdCacheFlush` appears, `ataWait` appears, `ataWriteFrom`
  still ends with `return ataFlushCache();` — and no cache is flushed. It survives for M1's reason,
  which the bypass experiment above measured rather than assumed. **A structural check that reads for
  the presence of a name cannot tell which PORT the name is written to**, and tightening it to demand
  `ataRegCommand` would be one more grep against one more spelling. It is recorded instead.
* **M16 — a failed write leaves the sector cache claiming to hold what the drive rejected.**

**AND HERE IS THE DISCLOSURE THIS ENTRY OWES.** M16 was labelled EVASIVE when it was written and it is
not. An evasive mutant is one that defeats a check while leaving what the check reads intact; there is
no check for this one at all, structural or otherwise, so it evaded nothing. It survives because the
condition it breaks — a failed sector write — cannot be produced on this emulator, which is the same
reason M3 and M10 survive. Calling it evasive would have flattered the round by one. **M15 and M19 are
properly evasive and M19 died**; M16 is a third untestable, filed under the wrong heading by its
author.

---

## GAP-0130 — `m14-fat` and `m15-fileio` ran six greps making four claims that this kernel could not write, and M16 made all of them false

**Domain:** conformance (M14, M15, M16)
**Status:** RESOLVED BY SUBSTITUTION — recorded because deleting an assertion is the kind of change
that should never be silent.

Between them, two harnesses ran **six greps making four claims** — the opcode grep and the
write-function grep appear in both, over different file lists:

1. `core/kernel/ata.dart` declares no ATA command constant equal to `0x30` or `0x34`;
2. no `port_outw` call site in `core/kernel/` targets anything but the framebuffer's VBE pair;
3. no function named `ataWrite*`, `fatWrite*`, `fatSetDir`, `fatAlloc`, `fileWrite` or `fileSysWrite`
   exists anywhere in `core/kernel/`;
4. `core/user/libc/oslibc.h` defines no `O_WRONLY`, `O_RDWR`, `O_CREAT`, `O_APPEND` or `O_TRUNC`.

Every one of those was correct while nothing in this kernel could write a sector, and every one of
them is now false by construction. **They were not deleted. They were replaced**, and the replacements
are stronger in the way that matters:

| the claim the old assertion was really protecting | what checks it now |
|---|---|
| "there is one place to look to answer *does this write?*" | `ataWriteFrom` is defined once and called from exactly one place (`fatWriteSector`); the only `port_outw` aimed at 0x1F0 is inside it. Checked by m14-fat and m16-filewrite, over the same code. m16-filewrite's copy also requires the flush, the status discipline, `fatAlloc`'s ordering and `fatSetEntry`'s loop over every FAT copy. |
| "M14's read path does not write" | **the image m14-fat boots is byte-for-byte identical afterwards**, SHA-256, across the main boot and all five broken-volume boots |
| "M15's read path does not write" | the same, across all four m15-fileio boots |
| "a mode-less `open()` is read-only" | `fileOpenRead` is asserted to be 0, so the two-argument form every M15 program performs still asks for a read descriptor |

**Why the measurement is strictly better than the greps.** A grep for an opcode says what is
*spellable*. The checksum says what *ran*. A kernel that can write and does not still passes; a kernel
that quietly wrote one sector does not, and no amount of renaming gets round it.

**What was lost.** One thing, and it is worth naming: the old greps would have caught a write path
added to `elf.dart` or `shell.dart` *even if no test ever executed it*. The replacement catches an
unused one only through the "defined once, called once" structural check, which a determinedly evasive
author could satisfy by routing a second caller through `fatWriteSector`. That is a real reduction in
reach and it is recorded rather than absorbed.

---

## GAP-0131 — `m14-fat` compared a hash with a leading zero, and would have failed one time in sixteen since M14

**Domain:** conformance (M14)
**Status:** RESOLVED at M16.

`core/tests/conformance/m14-fat/prog.c` prints its self-hash with `printf("... FNV %x\n", ...)`, and
oslibc's `printf` has **no width modifiers at all** (ADR-0017 §5 made that a deliberate, loud
limitation). `derive.py` computed the same hash and emitted it as `%08x`. The two agree for fifteen
values of the top nibble and disagree for one.

**How it surfaced.** M16 added three functions to `core/user/libc/syscall.c`, so every program that
links the library grew by a couple of hundred bytes, so `progB.elf`'s self-hash changed — to
`0x02ab07fc`. The program printed `2ab07fc` and the harness looked for `02ab07fc`.

**What it says about the harness.** Nothing about the kernel was wrong. This is a latent break that
had been in `m14-fat` since M14 and that no change before M16 happened to trip: it needed a program
whose own bytes hashed to a value with a zero top nibble, which is a one-in-sixteen event per
milestone that touches the C library. It is the kind of failure that looks like a real regression for
as long as it takes to read the transcript.

**Fixed by making `derive.py` emit `%x`**, which is what the program prints, in both `m14-fat` and
`m16-filewrite` (whose `derive.py` had the same latent bug from the day it was written — six hashes,
all of them zero-padded, all of them currently lucky). `m15-fileio` already used `%x` and was never
affected.

**The general rule this earns:** a harness that renders a number for comparison must render it the way
the thing under test renders it. Deriving the VALUE independently is the point; deriving the
FORMATTING independently is a bug waiting for a leading zero.

---

## GAP-0132 — The M16 sandbox verification, and the one thing about it that a write path changes

**Domain:** tooling, conformance (M16)
**Status:** OPEN — not a new gap. A third confirmation that GAP-0084's and GAP-0110's procedure is
stable, plus one observation that is new because M16 is the first milestone whose harness CHANGES its
inputs.

The procedure is GAP-0126's, applied verbatim:

```bash
SANDBOX=/private/tmp/m16-pinned          # NOT /tmp -- GAP-0110
git clone <shared>/DCDart $SANDBOX/DCDart && (cd $SANDBOX/DCDart && git checkout e3cfe18)
cp -Rc <shared>/DCDart/core/frontend $SANDBOX/DCDart/core/frontend      # GAP-0084 step 1
(cd $SANDBOX/DCDart/core/dcc && dart pub get --offline)
rsync -a --delete --exclude __pycache__ --exclude build/ <repo>/ $SANDBOX/oscortex_core/   # step 2
cd $SANDBOX/oscortex_core && DCDART_HOME=$SANDBOX/DCDart bash core/tests/conformance/<h>/run.sh
```

**RESULT: 18/18, FIRST ATTEMPT, NO RE-RUNS.**

**The two things GAP-0121 established were checked again.** `dcc` is still not on this machine's PATH,
so `build-kernel.sh` still falls through to `dart $DCDART_HOME/core/dcc/bin/dcc.dart` and `DCDART_HOME`
really does select the compiler; the script prints a warning if a `dcc` binary ever appears, because a
toolchain that installed one would make the isolation half what it looks like without changing a log
line. And `--exclude build/` still matters: `$SANDBOX/oscortex_core/core/build/` is created from
nothing by the sandbox's own compiler.

**WHAT IS NEW AT M16, AND IT IS WORTH ONE PARAGRAPH.** Every harness before this one was read-only
with respect to its own inputs: it built an image, booted it, and the image came back unchanged. M16's
harness WRITES to the images it builds — and every one of them lives inside the harness's own
`mktemp -d` workdir, which its `trap cleanup EXIT` removes. **Nothing under `$SANDBOX/oscortex_core`
is modified by running the suite**, which is what makes an rsync'd copy still a faithful copy after a
run rather than only before one. The only files the suite writes into the repo at all are
`core/build/` (a build artefact, gitignored) and, with `--regen`, the goldens — and `--regen` is never
passed by the sandbox script.

The sandbox was **228MB** and was deleted afterwards.

---

## GAP-0133 — `m10-elf` is intermittently red because QEMU sometimes pushes RFLAGS.RF, and it has nothing to do with M16

**Domain:** conformance (M10), QEMU
**Status:** OPEN — a real, newly-measured flake in an existing harness. Recorded rather than
absorbed, because "all eighteen harnesses pass" is a claim that a one-in-six intermittent failure
makes false.

**What happens.** `m10-elf`'s golden contains, three times, a line the kernel prints from the
interrupt frame the CPU pushed when a ring-3 program executed `int $0x80`:

```
USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000000246 CPL 3
```

Once in roughly six runs the third of those lines comes back as `RFLAGS 0000000000010246` instead —
**bit 16, RF, the Resume Flag** — and the byte-exact serial comparison fails. Nothing else in the
9-kilobyte capture differs.

**It is not M16's.** The golden at `7ffd8ab` carries `0x246` and so does the regenerated one; the
value the kernel prints is whatever the CPU pushed, and this kernel does not touch RF. The same
harness passed twice in a row immediately after the failure, passed in the pinned-toolchain sandbox
run, and passed in the full sweep before it. M16's changes do not touch `elf.dart`, `user.dart`'s
frame decoding or the payload; the only thing they change about this path is that the kernel image is
two pages bigger.

**Observed rate during M16's work:** one failure in six runs of `m10-elf`. It was seen once in a full
sweep, and `m10-elf` was then re-run twice on the same binaries and passed both times.

**Why it is left alone.** RF is set by the CPU on an instruction restart and QEMU's TCG frontend sets
it in paths a guest cannot control. Masking bit 16 out of the printed value would make the golden
stable and would also make the harness stop reporting a flag the CPU really pushed — which is the
opposite of what `m9-ring3` and `m10-elf` exist to do (they read CS, SS and RFLAGS out of the frame
precisely because a kernel that reported its own idea of them would prove nothing). **The right fix is
for the harness to normalise RF explicitly, in one place, with a comment saying that it is emulator
noise** — which is a change to `m10-elf`, owned by M10, and was not made inside M16's unit.

**What to do meanwhile:** if `m10-elf` fails with exactly this one-line difference, re-run it. If it
fails twice, it is not this.
