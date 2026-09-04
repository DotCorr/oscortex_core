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
`tests/conformance/m1-interrupts/run.sh`). The real bootloader is
**NARROWED under QEMU+OVMF** (ADR-0060, `tests/conformance/p2-gop/run.sh`)
and remains OPEN on real hardware.

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

- **No real bootloader.** **NARROWED, not closed (2026-08-30, ADR-0060,
  ADR-0072).** QEMU + OVMF + Limine 12 now loads the same Multiboot1
  `kernel.elf` without `-kernel` (`tests/conformance/p2-gop/run.sh`:
  serial `OSCORTEX M0 OK`, then `fb` prints a GOP tag). The same hybrid
  ISO also boots under QEMU SeaBIOS (`tests/conformance/p4-bios/run.sh`,
  ADR-0072: `-cdrom`, no OVMF, no `-kernel`; first line `OSCORTEX M0 OK`;
  `fb` is any ADR-0064 winner, GOP not required). The Multiboot `-kernel` path
  is still required and still passes (`m0-boot`, `m1-interrupts`).
  **BIOS MBR / UEFI on real hardware is still unbuilt and unverified.**
  A Ryzen laptop is not this harness. GOP paint under OVMF is done
  (ADR-0061). Leftover: USB HID / NVMe on metal.

**Cost of the workaround:** none of this was worked around — the resolved items were real work.
The bootloader is no longer un-started (ADR-0060 proved Limine+OVMF on QEMU;
ADR-0072 proved the same ISO under SeaBIOS); metal is.

---

## GAP-0002 — DCDart-side primitives this kernel needs but doesn't have yet

**Domain:** kernel (blocked on DCDart repo changes, not this repo's to fix directly)
**Status:** LARGELY RESOLVED — bitwise operators (DCDart ADR-0030), the complete integer operator set
including `u8 operator <` (ADR-0041), explicit width conversions (ADR-0037), extern FFI (ADR-0038) and
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

## GAP-0003 — The kernel could not name DCDart's prelude portably

**Domain:** kernel, build tooling
**Status:** NARROWED (2026-08-27, ADR-0043). The oscortex_core half is **RESOLVED** — the build is now
portable to any `DCDART_HOME`, proved from a worktree with no sibling DCDart. The DCDart half —
**dcc has no library resolution and no way to be told where its prelude is** — is OPEN and is
**DCDart's to fix**, per CLAUDE.md rule 3.

### What was wrong

`core/kernel/kmain.dart:20` imported the prelude by a literal relative path
(`../../../DCDart/core/runtime/dc-core-bare/prelude.dart`) while `core/scripts/build-kernel.sh`
located the compiler through `DCDART_HOME`. Two independent answers to "which DCDart", with nothing
checking that they agreed. When they diverged the build failed with

```
dcc build: DccLowerError: no @bare top-level function found in kmain.dart
```

**which describes a broken compiler, and was read as one.** Four clean DCDart checkouts were tested,
all four failed, and the reported conclusion was that `dcc` was unbuildable. A sibling session
disproved it by building a clean clone. One cause, four data points, one line of Dart. That
misdiagnosis is the real cost of this gap and it is why it was worth fixing properly.

### The mechanism (measured, and it corrects GAP-0110)

`dcc` accepts an annotation only when the annotation class's enclosing-library URI **equals** the one
prelude URI it computes for itself as `Platform.script.resolve('../../runtime/dc-core-bare/
prelude.dart')` (`dcc-lower/lib/lower.dart:622`, `dcc/lib/pipeline.dart:165`). That comparison is
exact `Uri` equality on a **lexically** normalised absolute path: `..` is folded, and **symlinks are
resolved on neither side**. Six experiments in ADR-0043 pin this down, including a direct probe
showing `Platform.script` reports a symlinked path unresolved.

So it is not, as GAP-0110 records, that "Dart resolves library identity through real paths" — it
resolves nothing. Two spellings of one file are two libraries; one spelling reached through a symlink
on *both* sides is one library. The observable failures are identical, but the wrong model made a
symlink look impossible in principle. It is not, and the fix depends on that.

### What was done here

`build-kernel.sh` materialises `core/build/dcdart` as a symlink to `$DCDART_HOME`, runs
`dart core/build/dcdart/core/dcc/bin/dcc.dart`, and `kmain.dart` imports through the same prefix. The
two paths are the same characters by construction. A `dcc` on PATH is no longer used (it would be a
third uncontrolled answer), the import line is asserted literally before every build, and the resolved
prelude path is printed on every build — it is the fact `@bare` resolution turns on and it was
previously invisible.

Verified: canonical sibling layout, an unrelated real path, a symlinked `DCDART_HOME` (previously
fatal), and a worktree with no sibling DCDart. `kmain.o` is byte-identical
(md5 `4e7efe27345b84cc8de56cc159c406ed`) in all four and against the pre-change build, so no golden
moves.

### What remains, and where it belongs

DCDart cannot be *told* where its prelude is: no `--prelude` flag and no env override in
`core/dcc/lib/cli_args.dart`; `dc:core.bare` as a real scheme needs the front_end fork DCDart's
ADR-0008 deferred; and a `package:` URI cannot work at all, because `kernel_frontend.dart` writes its
synthetic driver into a fresh temp directory and invokes `dart compile kernel` with no `--packages`,
so no package config is ever in scope. DCDart's own `pipeline.dart:157-164` says it: *"dcc currently
only works run from inside this checkout at this exact relative layout."*

**Escalation, not implemented here.** The narrowest honest fix is `dcc build --prelude <path>`,
defaulting to today's behaviour, so a consumer names the prelude once instead of encoding it in a
source import. That is a DCDart-repo change with a DCDart ADR and DCDart conformance coverage
(rule 3). Nothing in DCDart was touched — its tree also carries ~2,300 lines of another session's
uncommitted work.

**Residual cost here:** `kmain.dart` does not resolve in an editor or under `dart analyze` until
`build-kernel.sh` has run once in that checkout, and two concurrent builds in one checkout with
different `DCDART_HOME` values race on the symlink (they already raced on `core/build/*.o`).

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

## GAP-0053 — RESOLVED at M17: DCDart grew mutable statics, and 13952 of the 14048 donated bytes went home

**Domain:** kernel (M2–M16), DCDart-side language gap
**Status:** **RESOLVED at M17** (`docs/decisions/0021-mutable-statics-and-the-end-of-donated-bss.md`),
verified by all eighteen harnesses. DCDart ADR-0051 landed `@bss` mutable statics;
`DCDART_PIN.txt` moved to `8713298` and the migration was carried out.

**The running total, and where it ended.** **16 → 304 at M3, → 392 at M4, → 424 at
M5, → 424 at M6 (unchanged), → 5096 at M7, → 5224 at M8, → 5368 at M9, → 5496 at M10,
→ 9664 at M11, → 9664 at M12 and M13 (unchanged, twice), → 11488 at M14, → 12768 at M15,
→ 14048 at M16, → 96 at M17.**

**The total after M17 is a total of DCDart `@bss` rather than of donated bytes, and it keeps moving.**
14048 + 64 (M18's scheduler header, ADR-0022) = **14112 at M18**, + 256 (`argsStore`, ADR-0023) =
**14368 at M19**, + 2624 (`chanStore`, ADR-0027 — eight global counter words and two 1280-byte channel
port records) = **16992 at M20**, + 512 (`ioctlStore`, ADR-0033 — 32 metadata words and the 256-byte
`ioctl` bounce buffer) = **17504 at S0**, + 4352 (`shmStore`, ADR-0041 — 16 global counter words,
two 64-byte shared-region records and a 4096-byte one-bit-per-frame plane) = **21856 at M21**.
**+ 320 (`wmStore`, ADR-0050 — nineteen compositor state words in a 24-word block and two 64-byte
window records, one per shared region) = the D1/M21 merge total of 22016 becomes 22336 at D4.**
**+ 288 (`kbdqStore`, ADR-0054 — four header words and 32 event slots) = 22624 at D2.**
**+ 192 (`wmeventStore`, ADR-0055 — two per-window rings of four header words and
8 event slots) = 22816 at D7.** **ADR-0109 grew the three tables in place
(`shmStore` +128, `wmStore` +128, `wmeventStore` +192) = 23264.**
**Four authorised growths take it to 31584.** Round 27 then raised the three
tables and the process table so DESK + six dock apps coexist:
**+ 256 (`wmStore` 448 → 704)**, **+ 256 (`shmStore` 8576 → 8832)**,
**+ 384 (`wmeventStore` 384 → 768)**, **+ 4096 (`procStore` 4224 → 8320)**.
Harnesses pin **37600** (31584 + 4992 + 1024 file-descriptor rows) today. In ledger order, and each traceable to the ADR that required it:
**+ 4096 (`pmmStore`, 4672 → 8768: ADR-0155 doubled `pmmMaxFrames` 32768 →
65536 and `pmmBoundMib` 128 → 256 so a measured `libcef` slice fits, and the
bitmap is one bit per managed frame)**, **+ 4096 (`shmStore`, 4480 → 8576: the
shared-region bit-plane must describe exactly `pmmMaxFrames` — `shmPlaneFrames
== pmmMaxFrames` is asserted in `m21-shmem` — so ADR-0155 moved this block
too, 4096 → 8192 of plane)**, **+ 112 (`vmStore`, 128 → 240: ADR-0189 took
`vmFineBytes` 4MiB → 32MiB, `vmMapBytes` 128MiB → 256MiB and `vmFrameCount`
6 → 20 so a driver-reported mode can be mapped)**, **+ 16 (`fbStateBlock`,
32 → 48: ADR-0064's scanout fallback chain added the geometry width and height
words so a VirtIO scanout can outrank Bochs's 800x600 default)**.
23264 + 4096 + 4096 + 112 + 16 = **31584**; plus Round 27's 4992 + 1024 file rows = **37600**, section total including the 8 bytes
of alignment padding and `kdata.o`'s own blocks. `wmeventStore` is now the LAST block, `kbdqStore`
the one immediately before it, `wmStore` before that. **Every harness that
subtracted `kbdqStore` first now subtracts `wmeventStore` first**, then
`kbdqStore` — the sixth application of ADR-0033 §6.4's correction, and it
moved `kbdqStore`'s own to-the-end number in exactly the way that correction
predicts, which is why every harness now measures `kbdqStore` to
`wmeventStore`'s START and still reads 288.
**`shmStore` is the LAST block** in `kmain.o`'s `.bss`, `ioctlStore` is the one immediately before it,
and `chanStore` before that. `m19-argv` asserts that `shmStore` ends exactly at the end of the
section, that `ioctlStore` ends where `shmStore` begins, that `chanStore` ends where `ioctlStore`
begins, and that nothing sits between `argsStore` and `chanStore` — the same convention M14, M15,
M16, M19 and S0 each followed in turn, so that every earlier harness's "the donated bytes from MY
block to the end of `.bss`" keeps meaning what it meant when it was written, by subtracting each
later milestone's block first. Twelve harnesses subtract `shmStore` first, `ioctlStore` second and
`chanStore` third.

**M21 is the third instance of ADR-0033 §6.4's correction and it went exactly as that correction
predicts.** ADR-0031 §4.3 rule 5 said putting a block last leaves "every existing harness's 'bytes
from my block to the end' arithmetic unchanged"; last is necessary but not sufficient, and the block
that WAS last has a to-the-end measurement of its own. `ioctlStore`'s number did not change here only
because twelve harnesses measure it to `shmStore`'s START rather than to the end of the section —
which is the fix ADR-0033 put in, working.
`ioctl` bounce buffer) = **17504 at S0**, + 160 (`mouseStore`, ADR-0042 — twenty words of PS/2 mouse
driver state: the packet being assembled, the accumulated pointer, five counters, the DETECTED packet
size and device id, and the init-progress bitmap) = **17664 at D1**. **`ioctlStore` is still the LAST
block** in `kmain.o`'s `.bss` — ADR-0031 §4.3 rule 5 requires it — so D1's block went in FRONT of it
rather than after it, and `chanStore` is now the one immediately before `mouseStore` rather than
before `ioctlStore`. `m19-argv` asserts that `ioctlStore` ends exactly
at the end of the section, that `chanStore` ends where `ioctlStore` begins, and that nothing sits
between `argsStore` and `chanStore` — the same convention M14, M15, M16 and M19 each followed in
turn, so that every earlier harness's "the donated bytes from MY block to the end of `.bss`" keeps
meaning what it meant when it was written, by subtracting each later milestone's block first. Twelve
harnesses subtract `ioctlStore` first, `mouseStore` second and `chanStore` third.

**14368 at M19**, + 512 (`ioctlStore`, ADR-0033 — 32 metadata words and the 256-byte `ioctl` bounce
buffer) = **14880 at S0**. **`ioctlStore` is now the LAST block** in `kmain.o`'s `.bss`, and
`m19-argv` asserts that it ends exactly at the end of the section — the same convention M14, M15,
M16 and M19 each followed in turn, so that every earlier harness's "the donated bytes from MY block
to the end of `.bss`" keeps meaning what it meant when it was written, by subtracting each later
milestone's block first.

**And S0 is where that convention's wording turned out to be slightly wrong**, which is worth
recording here because this is the running total everyone consults. ADR-0031 §4.3 rule 5 said that
putting the new block LAST would leave *"every existing harness's 'bytes from my block to the end'
arithmetic unchanged"*. **Last is necessary but not sufficient**: the block that WAS last has a
to-the-end measurement of its own, and a new block after it changes exactly that one. `argsStore`'s
number went **256 → 768** and twelve harnesses said so. The remedy is the one already in the repo —
each new block adds its own subtraction step first — and the rule should read *"…so that every
EARLIER block's arithmetic is unchanged, and the previously-last block gets a new subtraction
step."* ADR-0033 §6.3(a).

**M20 WAS ITSELF THE NEXT DEMONSTRATION OF THAT POINT, on the very next merge.** `chanStore` was the
last block when M20 wrote the paragraph above, and `ioctlStore` landing behind it changed exactly the
one number ADR-0033 §6.3(a) predicts: `chanStore`'s own raw to-the-end measurement went **2624 →
3136**. The remedy was the one already in the repo — the twelve harnesses that subtract `chanStore`
were given the `ioctlStore` subtraction ahead of it, so their asserted 2624 still means 2624, and its
fail message now reads "to S0's ioctlStore" rather than "to the end of .bss". Two blocks in a row
have now proved the same rule, which is a reason to state it as the rule rather than as an anecdote.

**M20's 2624 bytes buy something specific and it is worth saying:** IPC allocates no frames at all. A
channel is `@bss`, so `chanopen` cannot fail for want of memory, and `m20-ipc` brackets two whole
two-process sessions with `frames` and requires the allocator's free count to be identical to the
frame.

**The donated total does not reach zero, and that is why this gap CLOSES rather than shrinking.** The
96 bytes left in `core/boot/kdata.S` are not a measure of a missing language feature: a DCDart `@bss`
symbol is emitted LOCAL, assembly cannot name a local symbol in another object, and all five remaining
words (`cpu_info` 64, `shell_resume_rsp`/`shell_resume_ok`/`user_resume_rsp`/`user_resume_ok` 8 each)
are written by `isr.S` **by name**. Two of ADR-0007's and ADR-0013's predictions — made milestones
before the feature existed — said exactly those four resume words would still be there on this day,
and they were right. What remains is the true size of the DCDart/assembly boundary, tracked as
**GAP-0134** (the one block that could still move, `cpu_info`, and the price of moving it).

**What the migration cost, measured.** 13952 bytes moved into ten DCDart source files as sixteen
`@bss` blocks; 27 storage-seam functions rewrote their one-line bodies; 16 `@extern` accessor
declarations were deleted; `kmain.o`'s declared externs went **60 → 44**; and the number of lines
changed **outside a storage seam was ZERO**. That last number is the settlement of the design bet
ADR-0011 §0 opened at M7 and eight later ADRs repeated. See ADR-0021 §0.

**Every historical number above is still asserted, byte for byte**, by the harness that owned it —
the totals are now `kmain.o`'s `.bss` plus `kdata.o`'s, and `kdata.o`'s half is pinned to exactly 96
so storage cannot drift back into assembly unnoticed. ADR-0021 §5.

**The record of what the workaround cost, kept:**

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
Multiboot2 or a UEFI stub was the portable answer. **ADR-0060 took the Multiboot1 VIDEO
flag + Limine/OVMF instead of Multiboot2:** under QEMU the kernel now reads the GOP tag
(`FB GOP …`) without a `multiboot.dart` rewrite. Metal is still unbuilt. This entry is
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
**CLOSED at D2** (ADR-0054: a 32-event ring, counted overflow, the shell is a consumer).

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

4. **No input buffer — CLOSED at D2 (ADR-0054).** A keystroke used to be echoed and discarded; M3
   added a 256-byte line buffer; D2 added the queue that item asked for. IRQ1 enqueues a raw
   scancode+edge; `kbdqDrainToShell` consumes it at the prompt; while a command runs the events wait
   rather than vanish; ring 3 reads them through syscall 24. Serial type-ahead is still dropped
   (GAP-0309) — a COM1 byte is not a scancode.

5. **8042 assumed to exist.** On hardware that came up through UEFI with no legacy emulation there may
   be no PS/2 controller at all; the real input path there is USB HID. USB3 (ADR-0085) is one
   command-driven xHCI transfer, not a resident keyboard at the idle prompt.

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
**Status:** OPEN — item 2 closed at G1 (ADR-0065). The rest is deliberately scoped out. Every
remaining item is absence, not wrongness: nothing below is mis-reported, it is simply not
attempted.

`core/kernel/pci.dart` finds devices and prints them. That is the whole of it.

1. **Nothing is retained.** The scan prints as it walks and keeps no device list, exactly as
   `mbReport` keeps no memory map, and for exactly the same reason: DCDart has no mutable static data
   (GAP-0053) and this kernel has no allocator. **This is why M5 cost zero donated `.bss`**, which
   `m5-pci/run.sh` asserts — and it is also the bill. A later driver that wants "the NIC I found" has
   to walk the bus again to find it, and two subsystems that both want a device will each walk it.
   A device table is the same donated-storage decision the physical memory manager is blocked on, and
   building it here would have prejudged that decision (ADR-0008 §6).

2. **Configuration space is writable (G1, ADR-0065).** `pciWrite32` is the twin of `pciRead32`:
   the same 0xCF8 selector, then `outl` to 0xCFC. G1 sets bus-master (command bit 2) on the
   VirtIO GPU from the `virtgpu` command, reads it back, and refuses if it did not stick.
   **What this item still does not do:** BAR *sizing* (write all-ones, read back the mask,
   restore) and assigning a BAR at all. SeaBIOS still leaves bus-master **clear** on both
   `virtio-vga` and `virtio-gpu-pci` (measured `cmd=0x0103`, `gpu.md` §3.2) — the kernel
   must set it; firmware will not. **The e1000 with `romfile=` is the same case:**
   SeaBIOS leaves bit 2 clear. N0 (ADR-0058) *reads* memory-decode and still
   does not write `0xCFC`. N1 (ADR-0063) writes MEM|BME through `pciWrite32`
   before the first DMA. The `pci` command still only reads.

3. **BARs are not read or printed by `pci.dart`.** Deliberate at M5: without item 2 there is no way
   to verify a BAR is decoded, and printing an address the kernel cannot use would suggest more than
   is true. **G0 narrowed this for one device:** `virtgpu.dart` reads the BAR a VirtIO capability
   names, including the 64-bit form, and refuses a non-zero upper dword.
   `fbFindVgaBar` still reads one 32-bit register and masks. **N0 added `pciReadBar` in
   `pci.dart` — a second walk, same I/O-bit refusal.** The `pci` command still does not
   print BAR values, so m5-pci goldens do not move.

4. **No capability list in `pci.dart`.** Offset `0x34` is not followed there, so MSI/MSI-X, PCIe
   capabilities and power management stay invisible to `pci`. **G0 (ADR-0059) walks the list for
   vendor `0x1AF4` device `0x1050` only**, in `virtgpu.dart`, and prints the five VirtIO vendor
   capabilities. That is not a general helper. Every modern interrupt path for a PCI device still
   starts at `0x34` and still has no shared walker.

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

8. **The e1000 now transmits, resolves ARP, and pings.** N0 (ADR-0058)
   reads its MAC from `RAL0`/`RAH0`. N1 (ADR-0063) programs a TX ring
   from `allocFrame()`, rings `TDT`, and puts one 60-byte broadcast
   frame on the wire. N2 (ADR-0066) posts an RX ring, sends an ARP
   request for 10.0.2.2, and prints the reply's SHA. N3 (ADR-0076)
   sends an ICMP echo to 10.0.2.2 and prints the reply's source IP.
   It still does not speak TCP, and does not unmask IRQ 11. The IDE
   controller is still found and named and then left alone.

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

1. **Bochs / GOP still do not scroll. The VirtIO console does (G6 / ADR-0086).**
   On a BAR or GOP aperture the cursor still stops at row 37 and further
   characters are dropped: sit-in / d2 goldens must not grow a 467,000-store
   scroll of the dispi aperture. On VirtIO backing (`virtgpuc` / `virtgpus`)
   a newline past the last row, or an explicit `fbScroll`, copies
   `fbWidth × (fbHeight - glyphHeight)` pixels up and issues
   `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of that rectangle. The guest-side
   move is still a byte-at-a-time copy (DCDart has no `memcpy`); what G6
   bought is a host-visible transfer of the moved region, not a free scroll.

   *What would fix the Bochs path:* a `memcpy`/`memmove` primitive in DCDart
   (a DCDart-repo decision, CLAUDE.md rule 3), or a hardware scroll via the
   dispi Y-offset register — which is genuinely the right answer for that
   device and needs a ring-buffer discipline over the framebuffer that this
   console does not have.

2. **The Bochs VBE interface is not portable, and it is the only mode-set path here.** `0x1CE`/
   `0x1CF` is implemented by QEMU's std VGA, by Bochs, **and by `virtio-vga`** (`gpu.md` §0.1 —
   that is why the existing `fb` command scanouts on `-vga virtio` with zero kernel change, and why
   G0 can be a probe rather than a mode-set). On real hardware the
   equivalents are VBE 2.0/3.0 real-mode BIOS calls (unreachable from long mode without a v8086
   monitor or an emulator), a UEFI GOP handle (which needs a UEFI boot), or a device-specific
   modesetting driver (which is what a real graphics driver *is*). This kernel checks the dispi ID
   register and prints `FB NOVBE` rather than pretending — but "prints an honest error on every real
   machine" is still the situation. G7 (ADR-0091) scanouts on `virtio-gpu-pci` without dispi;
   `fb` on that machine prints `FB NONE` (no VGA-class BAR), which is the ADR-0064 line,
   not a third spelling.

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

6. **Bochs still has no double buffering. VirtIO does (G8 / ADR-0093).**
   On a BAR or GOP aperture glyphs are still blitted straight into the
   scanned-out framebuffer — invisible at this rate; it stops being
   invisible the moment anything animates. On VirtIO (`virtgpuf`) two
   resources exist, the console paints the back resource, and
   `SET_SCANOUT` flips to it. `virtgpuy` paints both and never flips.

   *What would fix the Bochs path:* a dispi Y-offset page-flip
   (`display-protocol.md` §3.2), which needs a ring-buffer discipline
   over the BAR that this console does not have.

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

> **OBSOLETE as of 2026-08-27 (ADR-0043).** The whole "SECOND STEP" above — copy the repo beside the
> clone, and the "a symlink is not enough" paragraph with it — existed only because `kmain.dart`
> hard-coded `../../../DCDart`. It no longer does. `DCDART_HOME` now selects the prelude as well as
> the compiler, so a pinned sandbox is just:
>
> ```bash
> DCDART_HOME=<sandbox>/DCDart bash core/tests/conformance/<h>/run.sh   # from the real repo, in place
> ```
>
> No rsync, no mirror, no re-sync after every edit, and the sandbox may be a symlink. The FIRST step
> (copying `core/frontend` into the clone) is unaffected and still required. Note also that the
> mechanism this entry states — "Dart resolves a relative import through the file's REAL path" — is
> wrong; see the correction under GAP-0110.


---

## GAP-0085 — What ring 3 does NOT do, listed rather than discovered later

**Domain:** kernel (M9)
**Status:** OPEN, **NARROWED at M10 (ADR-0014) and again at M18 (ADR-0022)**.

**What M18 changed:** **item 3** — "`user hold` cannot be stopped ... this kernel has no way to kill a
payload, because that needs either a keyboard interrupt that can reach the kernel or a scheduler" — is
**no longer true of a PROCESS on the default path.** M18 built the scheduler that sentence names. `proc run`, `proc cross` and `proc spin` are
preemptive sessions: a program that never calls `yield` is taken off the CPU by the timer after
`procQuantumTicks` (8) ticks of ring-3 time and the other runnable process resumes, and a session
started by `proc spin` with a quantum budget is torn down by the scheduler when the budget is spent,
with the shell surviving. `m18-preempt/run.sh` proves it with two programs neither of which contains
the instruction that produces a `yield`, one of which contains no system call at all.

**What remains, and it is item 3's remainder rather than its whole:** `user hold` itself — M9's ring-3
payload, which is not a PROCESS and has no process-table slot — still holds the machine, because
`procTick` returns at its first line when `procLive()` is 0. So does `proc coop` with a non-yielding
program (GAP-0139), and so does an M10 `run <lba>` program that loops. Preemption in this kernel is a
property of PROCESSES, not of ring 3.

**The other successors M18 opens:** GAP-0138 (only ring 3 is preempted), GAP-0140 (the runaway
backstop and the absence of a kill), GAP-0141 (fork/exec, priorities, blocking, sleep, SMP).

---

 Item 5's ELF-loader half is CLOSED and item 4 is
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

**PAID AGAIN AT M20 (ADR-0027), and with one addition to the method.** `chan.dart` grew the kernel
image by three pages, so every physical address the kernel prints moved and TWELVE goldens moved with
it — m8, m9, m10, m11, m12, m13, m14, m15, m16 and m19, serial and screen. Regenerated by `--regen`,
which still runs every derived check, exactly as m7–m10 were here.

**The addition: the diffs were reviewed MECHANICALLY rather than read.** Every regenerated golden was
normalised by replacing each run of six or more hex digits with one token and compared against the
committed version; all twelve are byte-identical after that substitution, so not one line was added,
removed, reordered or reworded, and every permission column (`W`, `X`, `U`) is unchanged. Reading a
120-line diff and concluding "only addresses moved" is exactly the judgement that is easy to get
wrong at the eleventh file, and it is now a three-line script. See ADR-0027 §8.1.

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
3. ~~**There is no way for one process to affect another.** No signals, no kill, no shared memory, no
   pipe, no message. The only interaction two processes have is that yielding lets the other one run.~~
   **NARROWED at M20 (ADR-0027).** There is now a **message**: `chanopen`/`chansend`/`chanrecv`
   (syscalls 13-15) give two processes a two-endpoint channel with a bounded ring in each direction,
   carrying messages of at most 64 bytes, verified by `tests/conformance/m20-ipc/run.sh` — two
   processes in two address spaces exchanging sixteen messages and each exiting with a hash of the
   bytes it received.
   **NARROWED AGAIN at M21 (ADR-0041).** There is now **shared memory and a capability that can be
   handed to a peer**: `shmcreate`/`shmgrant`/`shmmap`/`shmdrop` (syscalls 16-19), verified by
   `tests/conformance/m21-shmem/run.sh` — two processes in two address spaces mapping one set of
   physical frames, read-write to the creator and read-only to the grantee, with the reader exiting
   on a hash of the 16384 bytes it read through the mapping. **Still true:** no signals, no kill and
   no pipe. A message is still opaque bytes and still cannot convey authority (GAP-0201, now closed
   the other way — the AUTHORITY moved to a syscall and the message kept carrying only a NAME).

   *(This item cited GAP-0161 for "a message cannot convey authority" until M21. GAP-0161 is the DRM
   ABI's per-driver ioctl range; the gap meant is **GAP-0201**. Corrected here rather than left,
   because a wrong cross-reference in a narrowing note is how a closed gap gets re-opened against the
   wrong entry.)*
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
7. ~~**A process cannot create a process.** No `fork`, no `exec`, no `spawn`. Both processes are created
   by the shell before either runs.~~
   **NARROWED at STUDIO2 (ADR-0078), ADR-0099, and STUDIO2b (ADR-0119).**
   Syscall 26 `spawn(namePtr, nameLen)` starts a named ELF into a free
   slot from a live process. Hidden `go <name>` is the idle-line
   spelling of the same named residency (not in `help`). `SEL.DAT` is
   four bytes of a selected row (destroy-on-save). No `fork`, no
   `exec`, no argv pointer (APP7 remainder). The leftover that is
   still true: a process cannot **reflect or emit** another program
   (GAP-0166 / GAP-0321 — `@extern` is a name, not a descriptor;
   there is no compiler on the box). `de-studio/` / `studio2b/` are
   launcher/exhibit/persist, not a builder.
8. **Nothing is shared between address spaces except the kernel.** Which is the point, and is also
   the reason there is no way to build anything that needs sharing.

**Why this is not a bug:** every item is absence, and each one is refused or simply absent rather than
half-present. The one that would be a bug if left unsaid is item 4, because "the exit code is
reported" reads like something a program could collect.

---

## GAP-0097 — The switching is COOPERATIVE, and this entry exists so nobody infers otherwise

**Domain:** kernel (M11)
**Status:** **NARROWED at M18 (ADR-0022) — the first paragraph below is now FALSE for a preemptive
session and remains true for a cooperative one.** Kept in full, unamended, because it is the record of
what M11 shipped and because its four-item list of "what preemption would need" is the list M18 was
measured against. What changed:

* **Item 1 is DONE.** `procTick` is the timer handler that switches, and it is `procYield`'s body
  minus the RAX patch (ADR-0022 §1).
* **Item 2 is NOT NEEDED YET and its premise is intact.** M18 preempts only when the tick interrupted
  RING 3, so a preemption puts the CPU back in ring 3 and there is still never a second kernel
  context on the one RSP0. GAP-0138 is what it costs and what preempting ring 0 would need.
* **Item 3 is UNCHANGED.** Nothing in this kernel became re-entrant. It did not have to, for item 2's
  reason.
* **Item 4 is UNCHANGED.** `procPickNext` is still M11's round-robin and GAP-0101's argument that two
  processes cannot distinguish it from lowest-first still stands. GAP-0141.

**The last paragraph's assertion also changed, and gained a term rather than being deleted:**
`m11-proc/run.sh` now requires `switches == yields + surviving exits + preemptions`, with the third
term counted out of the log one `PROC PREEMPT` line at a time — and requires it to be zero in its own
sessions. GAP-0143 records why the un-amended version would have been silently satisfiable by a
kernel that preempts.

**A process that never yields can now be stopped**, by `proc spin`'s quantum budget (GAP-0140) — and
under `proc coop` it still cannot (GAP-0139).

---

**The M11 text, unamended:**

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

> **Correction (2026-08-27, ADR-0043).** The *symptom* and the *fix* above are both right; the stated
> **cause is not**. Dart does not resolve library identity through real paths — it does not resolve
> symlinks at all. A direct probe shows `Platform.script` reporting a symlinked path unresolved, and
> a build whose import *and* dcc invocation both go through the same symlink succeeds. The comparison
> in `dcc-lower/lib/lower.dart:622` is exact `Uri` equality on a **lexically** normalised path, so
> `/tmp/…` and `/private/tmp/…` are two libraries because they are two *strings*, not because either
> was canonicalised. This matters: the real-path model made a symlink look impossible in principle,
> and it is not — a symlinked `DCDART_HOME` now builds fine. The sandbox rule ("use `/private/tmp`")
> is unchanged, and is now enforced by construction: `build-kernel.sh` derives both sides from one
> `core/build/dcdart` prefix, so they cannot disagree whatever the sandbox is called.

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
* `argc`/`argv`/`envp` — **`argc` and `argv` ARE PRESENT AT M19**
  (`docs/decisions/0023-argv-and-the-initial-process-stack.md`), and this bullet is the one item of
  GAP-0113 that M15 could not touch. `core/kernel/args.dart` builds the System V x86-64 initial
  process stack — `argc` at a 16-byte-aligned `RSP`, `argv[0..argc-1]` pointing at NUL-terminated
  strings on the program's own stack page, a NULL terminator — and `core/user/libc/start.c`'s `_start`
  unpacks it and calls `int main(int argc, char **argv)`, passing what `main` returns to `exit`. The
  shell types `run PROG.ELF one two three`. `m19-argv` runs ONE BINARY over TWO DIFFERENT FILES named
  on the command line and requires two different derived answers, and reads the constructed stack back
  out of guest physical memory to check its shape against the ABI. **`envp` IS STILL ABSENT**: the
  kernel writes a NULL where `envp[0]` goes, there is no environment of any kind, and `main` takes two
  parameters — GAP-0146. The bounds, and everything a program still cannot learn about how it was
  invoked, are GAP-0144.

**What it would take**, restated: ~~`argv` needs the ELF loading path to have somewhere for a command
line to come from (ADR-0015's process creation is the obvious place)~~ — **done at M19, though not
where this sentence guessed**: it went into the `run <name>` path in `elf.dart`, not into
ADR-0015's `procCreate`, and `proc run` still passes no arguments at all (GAP-0149). `stdin` needs a
console-input syscall and a decision about blocking, which needs a scheduler that can block
(GAP-0097 — narrowed at M18, which made the scheduler PREEMPTIVE but not BLOCKING); writes need
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
   no working directory, and no `opendir`/`readdir` syscall. **NARROWED AT ADR-0100:**
   `open(":ROOT")` in `fileSysOpen` (never `fatLookup`) yields a `fileFdRoot` descriptor;
   `read` returns whole 32-byte directory records. `FILES.ELF` (`files-fm/`) lists planted
   names and cats a planted file. **ADR-0118** copied and moved planted
   `.DAT`s with `open` / `fdwrite` (`files-fm/`). The shell's `ls` is still ring 0. `LS.ELF` (APP3) is still
   unbuilt. Subdirectories remain open. Icons closed (ADR-0154).
   Move consumes rename (ADR-0149).
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
8. ~~**NO `argv`, SO A PROGRAM CANNOT BE TOLD WHICH FILE TO OPEN.** `m15-fileio`'s program has
   `"DATA.BIN"` in its own `.rodata`. This is half an interface and it is the most visible thing left:
   a file API whose file name is a compile-time constant is a program with a file in it.~~
   **RESOLVED AT M19** (`docs/decisions/0023-argv-and-the-initial-process-stack.md`). The kernel builds
   the System V initial process stack, the C library's `_start` unpacks it and calls
   `main(argc, argv)`, and `run WC.ELF ALPHA.TXT` runs a program that was not compiled to know either
   word. **GAP-0144 is the successor entry** and lists what a program still cannot learn about how it
   was invoked — the largest being that there is no environment (GAP-0146) and no auxiliary vector
   (GAP-0147), and that `proc run` passes nothing at all (GAP-0149). `m15-fileio`'s own program still
   has `"DATA.BIN"` in its `.rodata` and was deliberately not converted: GAP-0151.
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
3. **NO `mkdir`, NO `rmdir`.** `unlink` and `rename` for root
   files landed in ADR-0147 (`files-unl/`, syscalls 31/32). A
   subdirectory still cannot be created or removed from ring 3.
   Marking a directory entry 0xE5 and freeing its chain is what
   APP4 shipped; mkdir/rmdir remain.
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

**M19 HIT IT ON A DIFFERENT HARNESS, AND `--regen` ALMOST ENSHRINED IT.** On 2026-08-23 the flake
appeared on **`m11-proc`**, not `m10-elf`: the THIRD of its four `USER CS ... RFLAGS` lines came back
`0000000000010246`. That is the same bit and the same cause, and it says the flake belongs to the
`int $0x80` path rather than to any one harness — every harness whose golden contains that line can
show it.

**The dangerous part is what happened next.** M19 regenerated `m11-proc`'s golden (the kernel image
grew, so every printed physical address moved), and the boot it regenerated FROM was one where RF was
set. Every derived check in that harness passed — because **nothing in `m11-proc` asserts RFLAGS
except the byte-exact comparison itself** — so `--regen` wrote `0x10246` into the golden as if it were
the truth, and the next three runs failed against it. It was caught by re-running, noticing the
failure was in the *opposite direction* to the flake, and diffing the golden against its pre-M19
version, which carries `0x246` at that line as every earlier golden does. The line was corrected by
hand and the kernel then reproduced the file byte-for-byte.

**The lesson is about `--regen`, not about RF.** "A wrong kernel cannot enshrine itself, because every
derived check still has to pass" is true and is not the same claim as "a wrong BOOT cannot enshrine
itself". A value that only the byte-exact comparison ever looks at has no derived check behind it, so
a regeneration is exactly as trustworthy as the single boot it came from. **Any golden regenerated
while this flake is open should be diffed against its predecessor and required to differ only in what
the change actually moved** — which for M19 was hexadecimal addresses and its own new lines, and RF is
neither.

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

---

## GAP-0134 — 96 bytes are still assembly-donated, and only one of them could move

**Domain:** kernel (M17), DCDart/assembly boundary
**Status:** OPEN, and **three fifths of it is CLOSED BY DESIGN and will never move.** Recorded
because GAP-0053's running total ends at 96 rather than 0, and a number that stops short needs a
reason attached to it rather than a hope.

**Why anything is left.** A DCDart `@bss` symbol is emitted with **LOCAL** binding (DCDart ADR-0051).
Assembly in another object file cannot name a local symbol. So storage that **assembly itself writes,
by name** cannot become a `@bss` block, whatever the language grows next.

| Symbol | Bytes | Written by | Could it move? |
|---|---|---|---|
| `cpu_info` | 64 | `cpu_probe` in `isr.S`: `leaq cpu_info(%rip)`, four `cpuid` leaves stored through it | **Yes, at a price — see below** |
| `shell_resume_rsp` | 8 | `shell_run_forever` in `isr.S`, read by `fault_resume` at fault time | **No.** It holds RSP, which DCDart cannot read or write at all |
| `shell_resume_ok` | 8 | the guard for the word above, written by the same code | **No.** Same instant, same code, no caller to pass an address in from |
| `user_resume_rsp` | 8 | `enter_user` / `user_return` | **No**, for `shell_resume_rsp`'s reason |
| `user_resume_ok` | 8 | the guard for the word above | **No**, for `shell_resume_ok`'s reason |

**The four resume words were predicted.** ADR-0007 (M4, "The constraint everything else follows
from") and ADR-0013 (M9) each said, milestones
before mutable statics existed, that these two pairs would still be in `kdata.S` on the day the
language feature landed. They are. That is not a gap; it is a boundary that was correctly drawn in
advance, and `m4-fault/run.sh` and `m9-ring3/run.sh` now assert they are **defined in `kdata.o`**
rather than merely present somewhere — "somewhere" would mean a local symbol assembly cannot reach.

**`cpu_info` is the one that could move, and the price is why it did not.** `cpu_probe()` currently
takes no arguments and writes a fixed symbol. Migrating the block means changing `cpu_probe`'s
**signature** to take a destination pointer and rewriting its four store sequences — a change to an
assembly function, not to a storage seam, and therefore not the change M17 was measuring. It would
take the residue from 96 bytes to 32 and the assembly-owned symbol count from five to four.

**Cost of the workaround:** 96 bytes of `.bss` and three `@extern` accessors (`cpu_info_addr`,
`shell_resume_ok_addr`, `user_resume_ok_addr`) out of `kmain.o`'s 44 declared externs. `kdata.S` still
exists as a file, at 96 bytes and five symbols instead of 14048 bytes and twenty-one.

**What would close it:** either the `cpu_probe` signature change above (closing three fifths of what
is left), or a DCDart facility for giving a `@bss` block **external** linkage on request — which
ADR-0051 did not provide and which nothing in this kernel currently needs, since the four words that
would want it are ones DCDart cannot manipulate anyway.

---

## GAP-0135 — Nothing in this kernel zeroes `.bss`, and `@bss` did not change that

**Domain:** boot, kernel (M17)
**Status:** OPEN, **pre-existing, and currently harmless because every subsystem initializes its own
state before first use.** Recorded at M17 because DCDart ADR-0051 states that `@bss` storage is
zero-initialized, and it would be easy for a later reader to believe this kernel gets that for free.

**What is true.** DCDart's `@bss` lowers to an LLVM `zeroinitializer` global in `.bss`. That makes the
storage zero **if something zeroes it** — an ELF loader that honours `p_memsz > p_filesz`, or startup
code. This kernel's Multiboot boot path does neither for `.bss` as a whole. `boot.S` zeroes exactly
two things by explicit address range: the three page-table pages (`zero_tables`) and the 104-byte TSS
(`zero_tss`), and it says so in comments at both sites precisely because nothing else is zeroed.
`isr.S`'s `idt_load` zeroes the IDT and the tick counter for the same reason.

**Why it is not biting.** It was already the case for all 14048 donated bytes, which had exactly the
same property, and every subsystem was written against it: `pmmInit`, `vmInit`, `userInit`, `elfInit`,
`procInit`, `fatInit`, `fileInit`, `shellInit` and `fbInit` each write their metadata before anything
reads it, and the two `_ok` guard words in `kdata.S` exist specifically because a stale non-zero value
there would triple-fault the machine. **None of that initialization was removed at M17**, deliberately,
even where ADR-0051's zero-initialization promise would appear to make it redundant.

**The trap this entry exists to prevent:** a future subsystem declaring `@bss final Bss x = const
Bss(bytes: N);` and reading it before writing it, on the strength of ADR-0051's wording. In this
kernel that reads whatever the loader left in memory.

**What would close it:** zeroing `.bss` in `_start`, between `__bss_start` and `__kernel_end`, before
the jump to `kmain`. `kernel.ld` already defines `__kernel_end`; a `__bss_start` and a `rep stosb`
would be about six instructions. It was not done at M17 because it is a change to the boot path, which
is outside this milestone's unit, and because doing it silently would make the initialization every
subsystem currently performs look unnecessary when it is the only thing making the kernel correct.

---

## GAP-0136 — `@bss` has no atomicity story: the tick counter is a read-modify-write that only works because there is one core

**Domain:** kernel (M1 onward), DCDart-side language gap
**Status:** OPEN, **PRE-EXISTING — not introduced by M17, and not fixed by it.** Recorded here
because M17 is the milestone that made "where mutable state lives" a language question, and the first
question anyone asks about a mutable global is what happens when two things write it.

**The concrete case.** The PIT handler increments a tick counter on every timer interrupt; the shell
reads it (`uptime`, and the idle path). That is a **read-modify-write**, and it is correct today for
exactly one reason: interrupt entry serializes against the interrupted code **on a single core**. The
handler cannot be interrupted by itself, and the reader cannot observe a half-updated value because
there is only one execution context that is not the handler.

**It is not M17's.** The tick counter is `isr.S`'s own `.bss`, reached through `tick_count()` and
`tick_counter_addr()`, and it **did not migrate** — it is written by assembly, by name, so GAP-0134's
rule applies to it. Every word of this was equally true at M1. What M17 changes is only that the
kernel now has sixteen DCDart-declared mutable blocks alongside it, none of which is concurrently
accessed either, for the same single-core reason.

**What DCDart does not provide.** ADR-0051 is explicit that `@bss` is raw bytes with no
initialization order and says nothing about atomicity: there is no atomic load/store, no
read-modify-write intrinsic, no memory ordering, and no `volatile` on a `@bss` block (ADR-0041's
volatile access is a `Pointer<T>` property, which the seam functions do compose with, and which gives
ordering against the compiler but not against another core).

**When it starts mattering:** a second core, or a preemptive scheduler that can switch inside a
sequence that reads-modifies-writes a shared word.

**UPDATED AT M18 (ADR-0022 §13): the second of those now exists.** `procTick` runs from the timer
interrupt and read-modify-writes six scheduler words (`procHeadSlice`, `procHeadQuanta`,
`procHeadPreempts`, `procHeadKernTicks`, and two per-slot counters). Every one of them is still
correct, and for *exactly this entry's reason and no other*: they are touched only from inside an
interrupt handler, and every gate in this IDT is an INTERRUPT gate, so IF is clear and the handler
cannot be re-entered. **Nothing was made worse; more of the kernel now depends on the same single-core
invariant.**

Three places in M18 would need a lock on two cores and have none:
`procSwitchTo`'s window between writing `procHeadCurrent` and the last word of `procLoadFrame`, during
which the table describes neither process consistently and a second CPU could schedule the same READY
slot twice; `procHeadPolicy`/`procHeadBudget`, written from shell context with IF set (safe because
IRQ0 is still masked at that point AND because `procLive()` is 0 — two reasons, both load-bearing);
and `procSessionReset`, for the second of those reasons. ADR-0022 §13 is the full accounting.

`procYield` is still called from a known point. `procTick` is not, and that is the difference M18
made.

**What would close it:** a DCDart atomics story, or a stated single-core invariant in
`OSCORTEX_SPEC.md` that this kernel is entitled to rely on. The second is cheaper and is probably the
honest one, since nothing else in this design is SMP-ready either.

---

## GAP-0137 — What M17's new assertions catch, tested by mutation, and the one link in the alignment chain that catches nothing on its own

**Domain:** conformance (M1–M16), M17
**Status:** OPEN as a record. **Twelve mutants, twelve killed. One sub-check is disclosed as unable to
kill on its own** and is kept for continuity rather than for coverage.

M17 changed the *meaning* of three families of assertion — the donated-`.bss` totals, the symbol-size
checks, and `proc_store`'s alignment proof — so "the harnesses still pass" says nothing about whether
they still catch anything. Each was mutated deliberately. Every mutant was run to completion against
the real harness; no golden was regenerated for any of them.

| # | Mutant | Harness | Result |
|---|---|---|---|
| M1 | `procStore` declared without `align: 16` | m11-proc | **KILLED** — by the 9664 total first (the 8 padding bytes vanish), then, with the total suppressed, by the declaration grep, then, with that suppressed too, by the object check |
| M1c | as M1, with the total *and* the declaration grep suppressed | m11-proc | **KILLED** — "procStore sits at +5400 inside kmain.o's .bss, which is not a multiple of 16" |
| M1d | as M1c, with the object check suppressed too, leaving only the link map | m11-proc | **SURVIVED the alignment chain.** See below |
| M2 | `align: 16` → `align: 32` | m11-proc | **KILLED** — declaration grep is an exact literal |
| M3 | `bytes: procStoreBytes` → `bytes: 4176` | m11-proc | **KILLED** — total is 9680 |
| M4 | a new `@bss` block declared and never referenced | m1-interrupts | **KILLED** — LLVM really does drop it, and the name-for-name source↔image comparison really does notice |
| M5 | an 8-byte `.skip` added back to `kdata.S` | m2-console | **KILLED** — "kdata.o still donates 104 bytes, expected exactly 96" |
| M6 | a fourth `return Bss.addressOf(procStore)` in `proc.dart` | m11-proc | **KILLED** — seam site count |
| M7b | `heap.dart` given a function returning `Bss.addressOf(procStore)` | m11-proc | **KILLED** — "heap.dart references procStore" |
| M8 | `fatStoreBytes` 1824 → 1832 | m5-pci | **KILLED** — the subtract-M14's-block arithmetic |
| M9 | line buffer declared `const Bss(bytes: 256)` instead of `bytes: shellLineMax` | m3-shell | **KILLED** — the new "cannot drift again" grep |
| M11 | `fat_store` and `fat_store_addr` restored in assembly and used | m14-fat | **KILLED** — kdata.o donates 1920, expected 96 |
| M12 | `fat_store_addr` resurrected as an extern **without** re-donating any `.bss` | m14-fat | **KILLED** — "fat_store_addr is still declared extern", the inverted check, which is the only one that could have caught this |

**THE SURVIVOR, precisely.** ADR-0021 §2 describes the alignment proof as three links: the
declaration, the object, and the linked address from `core/build/kernel.map`. **The third link alone
does not catch a dropped `align: 16`.** With `align:` removed, `kmain.o`'s `.bss` alignment falls to
2\*\*3 and the linker places that section at `0x142068` — itself 8 short of a multiple of 16 — while
`procStore`'s offset inside it becomes `0x1518`, also 8 short. **The two errors cancel**: the linked
address is `0x143580`, which is 16-aligned, and the check passes. (In that particular build `fxsave`
would not actually have faulted, which is exactly why "verify the declaration, not one build's
output" is the right rule.) M1d died only to the byte-exact serial golden, which is an address check
and not an alignment check.

**What this means for the three links.** Links (a) the declaration and (b) the object each kill
independently; link (c) does not. (c) is kept because it is the assertion M11 originally made and
because it is the only one that speaks about the *linked image*, but **it is not what makes this check
sound, and this entry exists so that nobody deletes (b) believing (c) covers it.** The pre-M17 check
was (c) alone, read from `kernel.elf` instead of the link map — so the check as it stood at M16 had
this same blind spot, and M17 closed it rather than opened it.

**Untested, and disclosed as such:** no mutant was written for the `.bss`-section-alignment half of
link (b) on its own (`KMAIN_BSS_ALIGN -ge 4`), because every mutation that lowers it also lowers the
offset, and the two cannot be separated from the source.

**The sandbox verification (GAP-0110, GAP-0084).** All eighteen harnesses were run inside
`/private/tmp` — not `/tmp` — against an isolated clone of DCDart checked out at `DCDART_PIN.txt`'s
`8713298`, with an rsync'd copy of this repo beside it: **18/18, first attempt**, `m10-elf` included
(GAP-0133's flake did not appear). The pin was chosen and then *tested*: `8713298` is the first commit
at which this kernel builds, and the **unmigrated** sources at `cf2737f` were also rebuilt against it
and produced a byte-identical `.text` and `__kernel_end`, which is what makes ADR-0021 §5a's claim
that the image growth is all migration and none of it toolchain a measurement rather than an
assumption.

---

## GAP-0138 — M18 preempts from RING 3 ONLY: a syscall cannot be preempted, and this is what that costs

**Domain:** kernel (M18)
**Status:** OPEN — a stated design boundary, not an omission. ADR-0022 §3 is the argument; this entry
is the accounting.

`procTick` reads the CS the CPU pushed and returns unless its low two bits are 3. A tick that
interrupted kernel code is counted (`procHeadKernTicks`) and does nothing else.

**What that costs, concretely.** Scheduling latency is bounded by the longest system call, not by the
quantum. `read()` on a 20000-byte file, `open()` on a fragmented chain, `sbrk()` that maps pages —
each holds the CPU for its whole duration and no other process runs. On a kernel that will eventually
host arbitrary C programs, that is a real ceiling.

**Why the CS check is nevertheless not what does the work, and the number that says so.** Every gate
in this IDT is an INTERRUPT gate, so IF is clear for the whole of every kernel entry from ring 3. A
timer tick inside a syscall is not merely un-preempted — **it is not delivered**, and if two ticks
elapse inside one syscall the PIC delivers one and the other is *lost*. So the kernel would not be
preemptible even without the CS check; the check is what makes the intent explicit and what stops the
scheduler from switching stacks out from under itself in the one window where a tick *can* arrive at
CPL 0.

`procHeadKernTicks` measures the size of that window directly. On the M18 harness's boot it reads
**1**: the single tick that can arrive with CPL 0 and a process live is the one landing in
`enter_user`'s three-instruction gap between recording the resume RSP and its `cli`. `proc sched`
prints it. **If it is ever large, this entry is wrong and should be treated as the bug.**

**What preempting ring 0 would need**, unchanged from GAP-0097's list except that item 2's premise is
still intact:

1. **A second ring-0 stack per process.** One RSP0 in the TSS is enough *because only one process is
   ever inside the kernel at a time*. M18 did **not** break that: a preemption from ring 3 puts the
   CPU back in ring 3, so there is still never a second kernel context on that stack. Preempting ring
   0 would break it immediately.
2. **Re-entrancy** in the frame allocator, the FAT cluster cache, the descriptor table and the UART.
   None is re-entrant; none is guarded.
3. **Lost ticks accounted for.** The PIC cannot queue more than one IRQ0, so a long syscall does not
   defer time — it destroys it. Nothing in this kernel notices, and `tick_count` is therefore a lower
   bound on elapsed time rather than a measure of it.

---

## GAP-0139 — Preemption is a per-SESSION policy bit, and `proc coop` exists because `m11-proc` asserts a hung machine

**Domain:** kernel + conformance (M18)
**Status:** OPEN — the honest cost of not rewriting M11's most intricate boot.

`procHeadPolicy` is a header word. `proc run`, `proc cross` and `proc spin` set it to
`procPolicyPreempt`; `procInit` writes the same default. **`proc coop` sets `procPolicyCoop`**, and
one boot in one harness is the entire reason it exists.

**Why.** `m11-proc`'s "hold" boot loads a variant of progB with `jmp .` written over its entry point,
so BOTH address spaces stay alive while the harness dumps guest memory and walks two page-table trees
from two PML4 frames, reads a *suspended* process's FXSAVE area, and shows A's private pages absent
from B's. Every one of those assertions needs a process parked at its entry point with the other one
suspended — the exact state a preemptive scheduler abolishes. Under `proc run` at M18 the held
process is taken off the CPU after one quantum and the other runs to completion; there is no moment
at which both are live and suspended.

**What is wrong with this, stated plainly.** A finished kernel has one scheduler and one policy. A
policy bit is a place where the two behaviours can drift, and it means `proc coop <a> <b>` with a
non-yielding program **still hangs the machine** exactly as it did at M11.

**What keeps it from being a dodge:**

* the DEFAULT is preemptive, and `procInit` states it rather than leaving it as whatever zero means;
* the opt-out is named for what it does and takes a different command;
* `m18-preempt/run.sh` uses `proc coop` as its **negative control** and REQUIRES it to hang — so the
  bit is asserted from both sides rather than being somewhere a bug can hide;
* `m11-proc/run.sh` additionally requires **zero** `PROC PREEMPT` lines in its own sessions.

**What closing it needs:** `m11-proc`'s hold boot re-derived so that it inspects two live address
spaces without depending on the machine being stuck — most likely by having the kernel take the
snapshot itself, or by a `proc freeze` that suspends the scheduler for the duration of a dump. That
is a change to M11's evidence, not to M18's code, and it should be done deliberately rather than
folded into a scheduler milestone.

---

## GAP-0140 — A runaway is stopped by a QUANTUM BUDGET typed at the shell, because nothing else in this kernel can stop one

**Domain:** kernel (M18)
**Status:** OPEN — a real mechanism with a real limit, not a placeholder.

Preemption makes a runaway **share** the CPU. It does not give anybody a way to get the CPU **back**.
`proc spin`'s progC never yields, never exits and makes no system call at all, so with preemption
alone the session would run until the machine was switched off.

So `proc spin <a> <b> <quanta>` states a budget, and `procTick` enforces it: at the stated number of
quantum expiries `procBudgetEnd` prints, restores the kernel's CR3, tears down every live slot and
returns to the shell through `user_return`.

**What is missing, and it is the general version of this:**

* **No way to kill a process from outside it.** There is no signal, no `kill`, and no keyboard-driven
  interrupt. The keyboard IRQ *is* delivered while a process runs (IRQ1 is unmasked and the process
  runs with IF set), and the handler echoes the character — but the shell's line processing runs from
  the idle loop, which is not running, so a typed `^C` reaches the line buffer and nothing acts on
  it. A `^C` that killed the session is the obvious next step and needs a flag the timer handler
  checks.
* **The budget is per session, not per process.** A runaway and a well-behaved program share one
  budget, and the well-behaved one is torn down with the runaway. `procBudgetEnd` kills all four
  slots for `procOnFault`'s reason (GAP-0098) and inherits its limitation.
* **`proc run` passes budget 0, meaning no limit.** So the ordinary command is still capable of an
  unbounded session — it just no longer starves the *other* process while it runs.

---

## GAP-0141 — What M18's scheduler still does not have: fork, exec, priorities, blocking, sleep, SMP

**Domain:** kernel (M18)
**Status:** OPEN — the successor list to GAP-0097, which M18 narrows rather than closes.

* **`fork` / `exec`.** A process still comes from exactly one place: `proc run`/`proc spin` and a disk
  LBA. There is no way for a program to create one. Successor to GAP-0085 item 5's remaining half.
* **Priorities.** `procPickNext` is M11's round-robin, unchanged and unweighted. Every process gets
  the same 80 ms whatever it is doing. With four slots and no way to create a third from a program,
  a priority scheme could not be told apart from round-robin by any test this suite can write —
  GAP-0101's argument, unchanged.
* **Blocking, and this is the biggest one.** There are four states — FREE, READY, RUNNING, EXITED,
  KILLED — and no fifth. **Nothing ever waits.** A process that calls `read()` on a file spins the
  whole machine through a PIO disk transfer with IF clear; a process waiting for a keystroke would
  have to poll. Every I/O syscall in this kernel is synchronous, and a scheduler with no blocked state
  cannot overlap I/O with computation, which is most of what a scheduler is for.
* **Sleep.** No `nanosleep`, no timer queue, no way for a program to ask for time to pass. `tick_count`
  advances and nothing but `procTick` reads it.
* **SMP.** One core. See GAP-0136 and ADR-0022 §13 for which of M18's new state is safe for that
  reason alone.

---

## GAP-0142 — `help` does not mention M18's three commands, and that is GAP-0105 being obeyed

**Domain:** kernel + conformance (M18)
**Status:** **CLOSED by the shakedown commit — see GAP-0246.** The three lines are in `shellStrHelp`,
which goes 2224 → 2511, and the five goldens moved with them, each required to differ from its
predecessor in the help text alone. The paragraph below is kept as written because the deferral was
correct at M18 and the reasoning is what a future `help` line has to answer to. **It was the T1 sweep
that forced the issue**: the three commands were booted, shown working, and found to be documented
only on `procStrUsage2` — a table a user reaches by typing `proc` wrong.

`proc sched`, `proc spin <a> <b> <quanta>` and `proc coop <a> <b>` are not in `shellStrHelp`. They are
on a second usage table (`procStrUsage2`), printed by `proc` with an argument it cannot parse.

**Why.** GAP-0105: `shellStrHelp`'s bytes are inside the byte-exact goldens of m3, m4, m5, m6 and
m14, and its size is asserted by m4, m10, m11, m12, m13, m15 and now m18. Adding three lines to it
moves five goldens for a milestone that has nothing to do with the shell.

**The cost is real:** somebody typing `help` at this kernel's prompt is not told that a preemptive
session exists. `m18-preempt/run.sh` asserts `shellStrHelp` is **unchanged at 2147** so that the
decision is visible rather than forgotten, and the usage line is at least reachable by typo.

**What closed it:** one commit that adds the three lines and regenerates the five goldens, with each
regenerated golden required to differ from its predecessor **in the help text alone**. It was
mechanical; it was separate; doing it inside M18 would have mixed it with a change that already had
to regenerate nine goldens for address drift. `m18-preempt/run.sh` no longer asserts `shellStrHelp` is
*unchanged* — it asserts it is 2511 and that the three commands are in it.

---

## GAP-0143 — M18's mutation results: what two survivors mean, and one check that no boot can make

**Domain:** conformance (M18)
**Status:** OPEN as a record. Fifteen mutations, each applied to a clean tree, built, run against
`m18-preempt/run.sh`, and reverted. **Thirteen killed, two survivors.** The full table is in
`ROADMAP.md`'s M18 entry; this entry is the four results that are about the *checks* rather than about
the code.

---

### 1. A slot-word collision produces a plausible number and no failure

`procSlotPreempts` was originally word 16, which is M12's `heapSlotBase` (`core/kernel/heap.dart`).
The kernel built, booted, preempted **correctly**, and printed `N 10003001` for a preemption count —
a process's heap break, read back as a scheduler statistic.

**No harness that existed at the time noticed.** Not `m11-proc`; not `m12-heap`, whose word it was;
not the first draft of `m18-preempt`, because that draft asserted `preempts > 0` and `0x10003001` is
greater than zero. `proc.dart`'s own comment says "slot words 0..31 are metadata" and does not say
which of them are spoken for, and two files were assigning them independently.

The check that catches it now (`m18-preempt/run.sh` §3b) parses every `*Slot*` constant out of every
kernel source file and requires the indices to be distinct. **An assertion about a VALUE could not
have caught it, because the wrong value was in range.**

---

### 2. The saved-RAX check was satisfied by the bug it was written for

`procYield` overwrites the saved frame's RAX with 1 before switching, deliberately: its frame came
from an `int $0x80` whose RAX held a syscall number. `procTick` must not, because its frame came from
a timer at an arbitrary instruction boundary and that word is the program's live register.

The mutation that copies `procYield`'s line into `procTick` **SURVIVED**. The assertion written for
it required progD's saved RAX to be *below* the count its loop spins on — and the mutant writes 1,
which is below 3. The deeper problem was that **neither program kept anything live in RAX**: progD's
RAX is dead except immediately after a syscall, so overwriting it changed nothing observable at all.

Fixed by giving the *other* program something to lose: progC now loads `0x00C0FFEEC0FFEE00` into RAX
once and never writes it again, `build-progs.sh` disassembles `_start` and requires exactly one RAX
write in it, and the harness compares the saved frame against the constant **read out of `progC.c`**
rather than typed twice. The mutant dies on the second attempt.

---

### 3. Removing the ring-3 privilege test changed nothing a boot can see

Deleting `procTick`'s CS check — letting a tick that interrupted **ring 0** switch processes, which
would switch stacks out from under the kernel — **SURVIVED every behavioural assertion in the
harness.**

That is a finding about the machine, not about the check. Every gate in this IDT is an INTERRUPT
gate, so IF is clear for the whole of every kernel entry from ring 3, and a tick essentially never
arrives at CPL 0 with a process live: `procHeadKernTicks` reads **1** for an entire session — the one
tick that can land in `enter_user`'s three-instruction window before its `cli`. **There is no
behavioural evidence available to be had**, and a harness that claimed otherwise would be claiming
more than it can see.

`m18-preempt/run.sh` now asserts the test's **presence in the source** and says in its own comment
that this is the only kind of check available here. That is weaker than a boot and is labelled as
weaker. ADR-0022 §3 is the argument the check protects.

---

### 4. SURVIVOR — the slice is not reset on a switch, and nothing notices

`procSwitchTo` resets `procHeadSlice` to 0 so the incoming process gets a full quantum. **Deleting
that line kills no assertion in this suite.** Each incoming process inherits whatever was left of the
outgoing one's slice, so a process scheduled late in a quantum is preempted almost immediately — the
classic round-robin starvation bug.

Every count still adds up: the *number* of quantum expiries is unchanged (the slice still reaches the
quantum at the same rate overall), only their **distribution between processes** moves. The harness
asserts `slot 1 preempts == 3` and `slot 0 preempts >= 3`, and both survive a lopsided split.

**What would catch it is a fairness assertion, and this suite has none.** The honest version would be
something like "over N quanta with two runnable processes, neither may receive fewer than N/3
slices". That is a real check and it is not written; writing it needs a session long enough for the
ratio to be meaningful, which is wall-clock the rest of this suite avoids.

---

### 5. SURVIVOR — the per-slot `YIELDS` counter never counts, and nothing notices

Making `procSlotYields` increment by zero kills nothing. Both of M18's programs have **zero** yields,
so the only thing ever asserted about that word is that it *is* zero — which a counter that never
counts satisfies perfectly.

Killing it needs a session that yields AND a `proc sched` afterwards to read the counter back. The
only sessions in this suite that yield are `m11-proc`'s, and typing a command after them changes a
byte-exact 4096-byte golden. **So the per-slot yield counter is, today, an unverified number that the
kernel prints.** It is used in exactly one assertion — "these programs yielded zero times" — and that
assertion would pass on a kernel that could not count yields at all.

---

### 6. `m11-proc`'s cooperative-switch identity would have been silently disarmed

Not a mutation, but the same class of finding. `m11-proc` asserted `switches == yields + surviving
exits`, and its own comment said a timer that switched processes would break the arithmetic. It would
have — but **only because M18's `procSwitchTo` still bumps `procHeadSwitches`.** Had M18 counted
preemptions in a separate counter and left `SWITCHES` meaning "voluntary switches", the identity would
have held unchanged on a kernel that preempts, and M11's stated tripwire would have been disarmed
without anybody editing it. The identity now carries the third term explicitly (ADR-0022 §6) rather
than relying on a counter's meaning that nobody had written down.

---

## GAP-0144 — What a program can and cannot learn about how it was invoked

**Domain:** kernel, userland (M19)
**Status:** OPEN — deliberately scoped out. GAP-0122's shape, restated for the thing that now exists,
because "oscortex programs get argv now" is exactly the kind of sentence that grows in the retelling.
`docs/decisions/0023-argv-and-the-initial-process-stack.md` makes the argument; this is the accounting.

**What IS there:** the System V x86-64 initial process stack, built by `core/kernel/args.dart` in the
program's own address space; `argc` at `RSP`, 16-byte aligned; `argv[0..argc-1]` pointing at
NUL-terminated strings on the program's own stack page; a NULL argv terminator; a NULL `envp[0]`; one
`AT_NULL` auxiliary entry; and `core/user/libc/start.c`'s `_start`, which unpacks all of it and calls
`int main(int argc, char **argv)`, passing what `main` returns to the `exit` syscall. The shell passes
`run PROG.ELF one two three`.

1. **EIGHT ARGUMENTS AND 128 BYTES, AND BOTH BOUNDS ARE EXERCISED FROM BOTH SIDES.** `argsMaxCount`
   is 8 **including `argv[0]`**, and `argsMaxBytes` is 128 **including one NUL per argument**. Neither
   is a truncation, and both are decided in the shell's parse before a frame is allocated, so a refused
   command line costs the machine nothing.

   **What a boot actually establishes**, because a bound asserted only from the refusing side is half a
   bound: `m19-argv` runs a command line of **exactly eight tokens** (`run wc.elf -c` plus six file
   names) and requires the program to report `argc 8` and to count all six files; it runs one of
   **exactly 128 bytes** (`wc.elf\0` is 7, plus a 120-character argument and its NUL) and requires the
   kernel to report `BYTES 0080`; and it then types **nine** arguments and **129** bytes and requires
   each to be refused by its own sentence with nothing loaded. The two accepted cases are at the
   boundary to the byte, and the two refused ones are one unit past it.

   **Eight arguments and 128 bytes are not a design maximum anybody measured a need for** — they are
   what fits in a 256-byte block whose whole point was to be small, and raising them is one constant
   and one `.bss` size.
2. **`argv[0]` IS THE TOKEN THE USER TYPED**, which for `run WC.ELF` is `wc.elf` (lower case, as typed —
   the FAT lookup upper-cases its own copy and `argv` does not). For `run 2A` it is the string `2A`.
   There is no path, no `/proc/self/exe`, and no way for a program to learn where it was loaded from.
3. **NOTHING ELSE IS PASSED.** No environment (GAP-0146), no auxiliary vector (GAP-0147), no file
   descriptors inherited from anywhere, no working directory, no umask, no process group, no TTY, no
   signal mask. A process's entire inheritance is `argc` and `argv`.
4. **THE ARGUMENTS DO NOT SURVIVE THE PROCESS.** They live on the stack page and `elfTeardown` frees it
   like any other. Nothing in `argv` outlives the address space, which `m19-argv` proves by bracketing a
   three-program session with `frames` and requiring the free count to be identical to the frame.
5. **THERE IS NO WAY FOR A PROGRAM TO SET ANOTHER PROGRAM'S ARGUMENTS.** There is no `exec` and no
   `fork` (GAP-0141 unchanged). `argv` is a thing the shell hands the loader, once, at load time.
6. **`argsErrBadByte` HAS NEVER EXECUTED ON A BOOT.** It refuses a byte outside `0x21..0x7E`, which is
   `fatParseAt`'s grammar applied to every argument, and the line editor accepts only printable ASCII —
   so nothing that can reach `argsCollect` can carry one. It is kept because the two parsers should
   agree about what a byte may be, and it is named here rather than left to be discovered, exactly as
   GAP-0122 item 13 names `fileRetNoOwner`. **`argsErrNoRoom` has never executed either**: with eight
   arguments and 128 bytes the worst case is 240 bytes on a 4096-byte page, so the check is a guard on
   two constants in two files rather than a reachable path.
7. **THE STAGING AREA IS 256 BYTES OF `.bss` AND IS NOT PER-PROCESS.** `argsStore` holds one command
   line. That is correct today because `run` is synchronous and one program at a time is loaded through
   it, and it is exactly the kind of thing that stops being correct the day two loads can overlap.

---

## GAP-0145 — The shell's tokeniser is runs of spaces, and there is nothing else

**Domain:** kernel, shell (M19)
**Status:** OPEN — deliberately scoped out. Narrows GAP-0057 item 3 for **one command**.

Before M19 this shell had no tokeniser at all: every command took "the rest of the line", which is why
`run PROGRAMME.ELF x` was `fatErrBadName` — a space is below 0x21 and the 8.3 parser refused it.
`argsTokenEnd` and `argsCollect` now split the line after `run ` on runs of spaces. That is the entire
grammar:

* **No quoting.** `'a b'` is two arguments, `a` and `b'`, and `'a` is the first of them.
* **No escapes.** A backslash is an ordinary byte, and `\ ` is two arguments.
* **No way to pass an argument containing a space**, therefore, and no way to pass an empty one.
* **No globbing.** `*.TXT` is the four bytes `*.TX` and a `T`; there is no expansion and nothing that
  could do one — the shell's `ls` is ring-0 code and no program can enumerate the volume (GAP-0122
  item 2 unchanged).
* **No redirection and no pipes.** `>` and `|` are ordinary bytes in an argument.
* **No `--` and no option grammar of any kind.** `-l` is a four-byte argument like any other; that it
  means something is a decision `m19-argv`'s program makes, not the shell.
* **`run` IS THE ONLY COMMAND WITH A TOKENISER.** `cat`, `echo` and every other command still take the
  rest of the line, and GAP-0057 item 3 is unchanged for them. `cat A.TXT B.TXT` is still one bad name.

---

## GAP-0146 — There is no environment

**Domain:** kernel, userland (M19)
**Status:** OPEN — deliberately scoped out.

The initial process stack has an `envp` and it is **empty**: the word after `argv`'s NULL terminator is
a NULL, `envp[0]` **is** the terminator, and `environ` — if anything declared one — would be a vector of
length zero. `m19-argv`'s `check-stack.py` reads that word out of guest physical memory and asserts it
is zero, so "empty" is a claim a boot makes rather than a thing this file asserts.

There is no `getenv`, no `setenv`, no `putenv`, no `environ` symbol in the C library, and `main` takes
**two** parameters. There is nowhere for an environment to come from: the shell has no `export` and no
variables of any kind, and there is no init, no login and no profile.

**What it would take:** somewhere for the strings to come from (shell variables), a place to keep them
across commands (more `.bss`, or a heap the shell can use — it has neither), and three library
functions. The stack layout already has the slot, so the kernel half is `argsBuild` writing more than
one NULL.

---

## GAP-0147 — The auxiliary vector is a terminator and nothing else

**Domain:** kernel (M19)
**Status:** OPEN — deliberately scoped out.

`argsBuild` writes exactly one `Elf64_auxv_t` and its `a_type` is `AT_NULL`: two zero words. There is no
`AT_PHDR`, `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ`, `AT_ENTRY`, `AT_BASE`, `AT_RANDOM`, `AT_HWCAP`,
`AT_SECURE`, `AT_CLKTCK` or `AT_SYSINFO_EHDR`.

**The terminator is there rather than the whole thing being omitted** because an ABI-conformant `_start`
or dynamic loader walks past `envp`'s NULL looking for the vector, and a terminator is the difference
between "the vector is empty" and "the vector is absent and you are now reading the argument strings as
`a_type` values". `check-stack.py` asserts both words are zero.

**What is lost by having none of them.** A program cannot find its own program headers (so no
self-relocation and no `dl_iterate_phdr`), cannot learn the page size except by knowing it is 4096, and
has no kernel-provided entropy. None of those matter yet: there is no dynamic linking (GAP-0096), no
`mmap`, and no randomisation anywhere in this kernel — `vmProgBase` is a fixed 0x10000000 and every
program is loaded at the same addresses on every boot, which is exactly why `m10-elf`'s goldens can be
byte-exact.

---

## GAP-0148 — `_start` runs no initialisers and `exit` runs no finalisers

**Domain:** userland (M19)
**Status:** OPEN — deliberately scoped out.

`core/user/libc/start.c` zeroes `%rbp`, reads `argc` and `argv`, calls `main`, and passes what `main`
returns to `exit`. Between the kernel's `iretq` and the first line of `main` **nothing else happens**:

* **No `.init_array`/`.preinit_array` walk and no `.fini_array` walk.** A C file-scope object with a
  non-constant initialiser, or any C++ static constructor, would silently never run. `prog.ld` does not
  even emit the sections; a program that needed them would link with them discarded, which is louder
  than running them in the wrong order but is still not a diagnostic.
* **No `atexit` and no `on_exit`.** GAP-0113's original entry said `exit` runs no handlers and flushes
  nothing, and that is unchanged. An `RFILE` that is never `rfclose`d is closed by the KERNEL at
  teardown, which prints `FILE ORPHANS <n>`.
* **No TLS.** No `%fs` base is set, `FS.base` is whatever the kernel left, and `__thread` does not work.
* **No `errno` location**, and there is no `errno` (GAP-0122 item 6 unchanged).
* **No stack guard, no `__stack_chk_guard`.** The programs are built `-fno-stack-protector`.
* **No `argv`-derived `program_invocation_name`** or any other global; `argv[0]` is a parameter and
  nothing copies it anywhere.

---

## GAP-0149 — `proc run` passes no arguments, and a program built against `start.c` cannot be started that way

**Domain:** kernel (M19)
**Status:** OPEN — a real limitation with a named cost, not a deferral of work nobody wants.

M19 gives `argv` to **`run`**, the shell command that loads a program by name (or by LBA) into the
single-address-space M9/M10 path. It does **not** give `argv` to **`proc run`**, M11's process-creation
path: `procCreate` still sets `procSlotRsp` to `vmProgStackTop` and enters ring 3 with an empty stack
page, exactly as before.

**Why not.** `proc run` takes an LBA and only an LBA (GAP-0119), so there is no name to be `argv[0]`,
and building even a zero-argument block there would move `m11-proc`'s and `m18-preempt`'s goldens —
`PROC START SLOT 00 ENTRY ... RSP 0000000010200000` — for two harnesses whose programs are hand-written
assembly that never reads `(%rsp)`.

**What it costs, named rather than left to be found.** A program whose `_start` is `core/user/libc/
start.c`'s — which reads `(%rsp)` as its second instruction — started with `proc run` **page-faults
immediately**, at `vmProgStackTop`, which is one past the last mapped byte of its address space. The
failure is clean: the kernel reports the fault at `_start + 2`, tears the process down, and the shell
survives. It is not silent and it is not corruption. But it is a real footgun, and the honest statement
is that **there are two ways to start a program on this operating system and only one of them satisfies
the C entry contract.**

**What closing it takes:** `procCreate` calling `argsBuild` on the slot's stack frame, `proc run`
growing a name form, and regenerating two harnesses' goldens.

---

## GAP-0150 — The QMP port is probed, not reserved

**Domain:** tests (M19)
**Status:** OPEN — halved rather than closed, and the residual race is named.

Every harness that drives QEMU through QMP used to pick its port arithmetically:

```bash
port=$(( 47000 + ($$ % 8000) + portoff ))
```

which is a hash of a process id, not a free port. It collides three ways — two harnesses whose PIDs are
8000 apart, a re-run onto a recycled PID, and a previous boot's socket still in `TIME_WAIT` — and every
one of them surfaces as QEMU dying with `Failed to find an available port: Address already in use` and a
harness reporting a failure that has nothing to do with the kernel. **It was observed twice in one sweep
on 2026-08-23**, on `m5-pci` and `m16-filewrite`.

**What M19 did.** `core/tests/conformance/m2-console/pick-port.py` asks the host kernel for a free port
(bind to 0, read it back, close) and every `drive_session` in every harness now calls it. On top of
that, `drive_session` **retries the launch up to five times** when — and only when — QEMU's own log says
the address was in use, printing a line when it does so.

**What is still racy.** The port is released before QEMU claims it, so something else can take it in the
window between. The retry covers that; it does not eliminate it. **Fully closing it needs QEMU to be
handed an already-bound file descriptor**, which its `-qmp tcp:` form does not accept — `-qmp
fd:<n>` does, but then the harness owns the listening socket's lifetime and the `wait`/`timeout`
structure every harness shares would have to change. That is a bigger edit than the failure justifies
today, and this entry is where whoever decides otherwise should start.

---

## GAP-0151 — Four test programs still carry their own `_start`

**Domain:** tests, userland (M19)
**Status:** OPEN — a deliberate non-migration, recorded so nobody reads M19 as bigger than it is.

`core/user/libc/start.c` is the C entry contract and `m19-argv`'s program is written against it: it
defines `int main(int argc, char **argv)` and nothing else, and `build-progs.sh` refuses a build in
which `prog.c` defines `_start`.

**The four older test programs were not converted.** `m10-elf`'s are hand-written assembly with no
library at all; `m13-libc`'s, `m15-fileio`'s and `m16-filewrite`'s each carry a four-instruction
`_start` that aligns the stack, zeroes `%rbp` and calls a `progMain(void)`. Converting them would have
changed every one of those programs' R+X segments, and therefore the self-hashes those harnesses derive
from them and the goldens that carry those hashes — for no gain to this milestone.

**What that means precisely.** M19's claim is *a C program written as `main(argc, argv)` runs on this
operating system*, evidenced by one program that is. It is **not** *every program on this operating
system now goes through the library's `_start`*. The older programs are not broken by M19 — an initial
stack a program ignores is harmless, and all four still pass — but they are not evidence for it either.

**One thing they now do differently and it is worth knowing:** their `_start` begins
`andq $-16, %rsp`, which on a stack the kernel has already 16-byte aligned is a no-op, and which
**would silently repair a kernel that had got the alignment wrong**. That is exactly why `start.c` does
not do it and why `build-progs.sh` asserts no write to `%rsp` anywhere in `_start`.

---

## GAP-0152 — `open(name, O_WRITE)` truncated a read-only file, and a nineteen-item gap entry did not mention it

**Domain:** kernel, filesystem (fix batch, ADR-0024)
**Status:** **CLOSED.** Recorded rather than deleted because the way it was missed is the useful part.

**The defect.** `fatAttrReadOnly` was declared at `fat.dart:154` at M14 and **read by nothing anywhere
in the tree**. `fileMakeEmpty` — the function `open(name, O_WRITE)` reaches before it has a descriptor
— tested `fatErrIsDir` and looked at no other bit of the attribute byte. So **any ring-3 program could
empty a file the volume marks read-only**, and the refusal it should have received did not exist as a
value.

**The fix.** `fatErrReadOnly` (32) with its own sentence and its own branch in `fatReportError`;
`fatWritable()` in `fat.dart`, which is where the attribute byte's meaning lives; `fileRetReadOnly`
(`0xFFFFFFFFFFFFFFF1`), the fourteenth refusal ring 3 can see and the first that is about permission;
`FILE_EREADONLY` in `oslibc.h`. The guard sits after the lookup is known to be a HIT and **before**
`fatClose`, `fatTruncate` and `fatDirWrite` — the first three things that change the volume.

**Why the test is not just the refusal.** A guard placed one line lower returns ring 3 the same
`FILE_EREADONLY` and leaves an empty file behind. `m16-filewrite` therefore requires three separate
statements about the same file: the program's `create("RO.TXT")` is refused; the **same program** then
reopens RO.TXT for reading and hashes all 1024 bytes to a value the host computed; and after the boot
the harness mounts the image with macOS's own `msdos` driver and compares RO.TXT byte-for-byte against
the bytes `make-image.py` generated before the machine was switched on. RO.TXT takes its single
cluster off the end of `FILL.BIN`'s run rather than out of the free pool, exactly as `SUB` does, so no
cluster of the allocation this harness predicts moves because it exists.

**What is still not there, so this entry is not read as bigger than it is:**

* **This is not a permission system.** FAT has no owner, no group, no mode. Bit 0 of `DIR_Attr` is the
  whole access-control vocabulary of the format and this kernel has no user identity to compare it
  against. Any ring-3 program may still create, truncate and write any file that is not marked.
* **The bit cannot be set from this OS.** No `chmod`, no `attrib`; `fatDirCreate` writes
  `fatAttrArchive` and nothing else. A read-only file arrives from the host.
* **`fatAttrHidden` and `fatAttrSystem` are still read by nothing**, deliberately — neither is a
  protection bit and inventing a meaning for them here would be this kernel making up policy the
  format does not have. They are the two remaining declared-and-unread constants in `fat.dart`, and
  they are named here so the next audit does not have to find them twice.
* **There is no delete and no rename**, so there is nothing else to gate.

**The part worth keeping.** M16 shipped GAP-0127, nineteen items of what its write path deliberately
does not do, and this was not among them. That list is not careless; it is careless about one specific
thing. GAP-0127 enumerates **design limits** — decisions not to build something — and it was written
by asking *what did I choose not to do?* An **omission** cannot appear in the answer to that question,
because it is a case the author never brought to mind. A read-only file is not something M16 decided
not to honour; it is something M16 did not notice existed, in a constant its own file declares.

So: **a gap list written by its author bounds the author's intent, not the code.** Nineteen items of
deliberate non-coverage is evidence of care and is not evidence of coverage, and it must not be cited
as though it were. What found this was an audit asking a *different* question — *which declared
constants does nothing read?* — which is a question no author asks about their own work, because every
constant they wrote had a purpose when they wrote it.

---

## GAP-0153 — SMEP is enabled and is NOT proved to block anything; SMAP is refused, by four lines of kernel

**Domain:** kernel, boot (fix batch, ADR-0025)
**Status:** OPEN — half shipped, half named. Read §2 before citing this as a security property.

**Which kind of "not proved" this is: A TEST NOBODY HAS WRITTEN, not a limit of the emulator.** The
distinction matters and this entry is easy to misread as the other kind, because GAP-0154 sits beside
it using the same words for the opposite cause. There, QEMU genuinely cannot tell the truth — it hands
out zeroed guest RAM, so no boot can distinguish a zeroed first allocation from an unzeroed one, and
no amount of work in this repo would change that. Here the emulator is not the obstacle at all: QEMU
accepts `+smep`, the bit reaches `CR4` (`0x100620`, asserted in `m11-proc`), and the feature is live on
the emulated CPU. What is missing is a `vmtest smep` this project has not built, blocked by its own
fault-path cleanup (§2). So the honest one-line statement of this gap is: **the kernel sets `CR4.SMEP`
and nothing in this repo proves the bit does anything.** It is a hole in the protection story, not an
unavoidable consequence of testing under emulation, and it should not be cited as though it were.

**What shipped.** `boot.S` probes CPUID leaf 7 subleaf 0 (`EBX[7]`) and folds `CR4` bit 20 into its
single CR4 write when the CPU has SMEP. Seventeen lines of assembly, no DCDart change, no new extern
(still 44), no new `.bss`, no new shell command. On `-cpu qemu64` — which reports `smep=false` — CR4
stays `0x620`.

**"Measured to move zero goldens" was the claim, and it is false.** It is true of the `CR4` *value*:
plain `qemu64` has neither feature, so nothing that prints `CR4` changes. It is not true of the
goldens. Four kernels were linked and their section headers read:

| build | `.text` end | `.rodata` end | `.bss` |
|---|---|---|---|
| HEAD | `0x131820` | `0x135CAE` | 71728 |
| + SMEP only | `0x131850` (**+48**) | unchanged | unchanged |
| + GAP-0152's read-only fix only | `0x131910` (+240) | `0x135D0A` (+92) | unchanged |
| both (shipped) | `0x131940` (+288) | `0x135D0A` (+92) | unchanged |

`m8-paging`, `m9-ring3` and `m10-elf` each print a `VM SECT` line carrying the kernel's own section
extents, so **all three move — for the SMEP change alone, and for the read-only change alone.** Any
change that adds one instruction to this kernel moves them. That is a property of what those three
goldens chose to record, not of this change, and it is the reason "no golden moves" is a claim that
has to be measured per change rather than inherited from a design note.

**1. WHAT IS PROVED.** `m11-proc` boots four CPU models and reads `CR4` back with `cr4_read()`:
`qemu64` → `…0620`; `qemu64,-sse,-fxsr` → `…0020` (the pre-existing control); `qemu64,+smep` →
`…100620`; `qemu64,+smep,+smap` → `…100620`. That is: the probe finds the feature when it is there,
the bit really reaches `CR4`, the machine still boots and still runs a ring-3 program with it on, and
SMAP is **not** set — the last of those asserted mechanically so that "we chose not to" is not merely
a sentence in an ADR.

**2. WHAT IS NOT PROVED, AND THIS IS THE ENTRY'S POINT.** **No boot in this repo shows SMEP refusing an
instruction fetch.** Everything above is a read-back of a control register plus "nothing broke". A
`CR4` bit that is set and does nothing looks exactly like this. `security.md` §5.5 names this the
vacuity trap.

The demonstration is reachable and costs no new extern: `vm_exec_probe(addr)` (`isr.S:816`, already an
extern, already used by `vmtest nx`) does `call *%rdi`, and `vmMapUser(va, 1)` makes a 4 KiB identity
page user-accessible and executable. `vmtest smep` would be: map a page holding a `ret` as user+exec,
probe it, and require `#PF ERR 0x11` on a `+smep` boot and a clean return on a plain one — **the pair,
or it proves nothing.**

**What stopped it here, which is a real obstacle rather than a shortage of time:** the faulting probe
never returns. `fault_resume` abandons the stack and re-enters the shell loop, so the `vmClearUser`
that puts the page back to supervisor is skipped **on precisely the run where the test succeeds**, and
the machine is left holding a user-accessible kernel page. Closing that needs fault-path cleanup — a
pending-restore note the shell loop honours — plus a new `vmtest` sub-command, a longer
`vmStrTestUsage`, and a regenerated `m8-paging` golden.

**3. WHY SMAP IS NOT SET.** This kernel dereferences a ring-3 **virtual** address at CPL=0 in exactly
four places, and all 160 `Pointer<…>.fromAddress` sites in `core/kernel/` were classified to be sure
the number is four: `user.dart:1393` (`userSysWrite` → `uartWrite`), `file.dart:1398` (`open`'s name
copy), `file.dart:975` (`fileCopyIn`), `file.dart:811` (`fileCopyOut`). With `CR4.SMAP` set every one
of them `#PF`s — `open()` from ring 3 would fault inside the kernel on the first syscall m15 and m16
make. Enabling it today ships a kernel that works only on CPUs lacking the feature.

The ELF loader and `args.dart` are **not** among the four: `elfCopyPageBytes` writes at the frame's
identity address before `vmProgMap` runs at all, and `argsBuild` goes through `argsPhys(frame, va) =
frame + (va - vmProgStackPage)`. Both use the physical alias, which is supervisor, so both are already
SMAP-clean — and that is the shape the other four would have to take.

**4. THE ONE THAT CANNOT TAKE THAT SHAPE.** Sites 2, 3 and 4 are convertible: their pages are in
`[0x10000000, 0x10200000)`, every frame behind them is below 128 MiB, and `vmProgLeaf` already does
the VA→leaf walk. Ordinary work, page by page. **Site 1 is not convertible.** The M9 payload path does
not use a separate window — `vmMapUser` flips the U/S bit **in place inside the 4 KiB identity map**,
so for that page the user virtual address *is* the physical address and there is no supervisor alias
to reach it by; `userOwns` bounds ring 3 to `< vmFineBytes`, which is that identity region. Site 1
needs `stac`/`clac` (two new externs — eight harnesses assert the count), or a second supervisor
mapping of the same frame, or the `user` command excluded from any `+smap` boot.

**So SMAP is one design decision behind SMEP, not one instruction behind it.** `boot.S` does not even
probe for it, because an answer nothing may act on is storage with no reader — which is what GAP-0152
had just been.

---

## GAP-0154 — `allocFrame` does not zero, on purpose; the check that says so is source shape and cannot fail on QEMU

**Domain:** kernel, memory (fix batch, ADR-0026)
**Status:** OPEN — the decision is settled and recorded; the *verification* is the open half.

**First, the correction.** `allocFrame()` returning an unzeroed frame is true and has been since M7.
It was described as a live hazard. **It is not one today.** All nineteen `allocFrame()` call sites were
classified: every frame that goes into a page table, a ring-3 mapping, a heap page or an ELF segment
is zeroed before anything reads it — thirteen by a `vmZeroFrame` beside the allocation, one by
`vmProgTableInstall`, one by `vmBuild`'s loop. The remaining five are `pmm.dart`'s own `alloc`,
`frames self` and `frames drain`, which map nothing and hand nothing to ring 3. The motivating example
— a UHCI frame list the controller reads as pointers at 1000 Hz — is a claim about work not yet done:
this kernel has **no DMA at all**, ATA is PIO, there is no USB, NIC or GPU. Latent hazard, not
reachable defect. The two deserve different fixes.

**The decision: zeroing stays at the call site, and the reason is a measurement.**
`shellFramesDrain` calls `allocFrame()` until it returns 0 — **32768 frames** on the `-m 128M` boot
`m7-frames` runs four times under `timeout`. An allocator that zeroed would make that command write
**128 MiB**, a page at a time, from a DCDart loop under TCG. The same harness already records that
draining first-fit "takes visible seconds under emulation", which is why `allocFrame` has a cursor at
all. Zeroing inside the allocator makes the allocator's own conformance test slower by two orders of
magnitude, in the one operation that test exists to measure, to protect frames nothing ever maps.

**What was added.** `m7-frames` check 2i: all nineteen sites found by regex, each required to name its
frame to `vmZeroFrame` in the same file or to sit in an exemption table with a reason — where the two
delegating exemptions are themselves re-checked, and a stale exemption or an unaccounted twentieth
site is a failure. Before this, `m10-elf` asserted the property for `elf.dart`'s five sites and
nothing asserted it for the other fourteen.

**UPDATE — the census is now SEVENTEEN, and the check caught the change (ADR-0034).** Unifying the
launch path deleted `elf.dart`'s own `hdr` and `scratch` frames: loading goes through `procCreate`,
which already took that pair, so the duplicates went and the work did not. `elf.dart` is down to
`frame pt sf` and `proc.dart` still takes `pml4 pdpt pd hdr scratch`. **This is the check working as
designed, in the direction nobody writes a test for** — it was built to fail on an unaccounted
*twentieth* site and it failed just as loudly on an unexplained *seventeenth*, which is what a census
is for. Nothing was exempted to make it pass: the pairing rule, the exemption table and its two
delegation re-checks are untouched and still enforced against all seventeen. Only the number moved.
Worth recording because **neither branch could see it alone** — this check arrived on the milestone
line in `e1381f8`, and the launch branch forked before that commit existed.

**WHAT THIS CHECK DOES NOT DO, said plainly.** It is a **source-shape assertion**. It proves nothing
about a running machine. QEMU hands out zeroed guest RAM (GAP-0094, GAP-0109), so on a *first*
allocation an unzeroed frame and a zeroed one hold the same 4096 bytes: **deleting every
`vmZeroFrame` in this kernel leaves every behavioural check in this repo passing.** Three units have
now failed to falsify frame-zeroing behaviourally and none of them failed for lack of trying.

**The behavioural test that WOULD work, and is not written.** A *recycled* frame is distinguishable,
because its previous contents were written by the guest rather than by QEMU. `m12-heap` already does
this for the heap: its program reads every byte of every page before writing one and reports what it
found. The same idea applied to the ELF loader — program A fills every page of its image and stack
with a signature and exits; program B, loaded into the frames A just freed, reads its own `.bss` and
stack before writing and reports — is a test that would really fail if `elfLoadSegment`'s
`vmZeroFrame` were removed. It needs a new program pair and a fourth boot in `m10-elf`. That is the
next real piece of work in this area and it is deliberately not in this fix batch.

**What would change the decision.** The first DMA structure. When a device reads a frame's bytes as
pointers, "the call site zeroes it" becomes a rule enforced by whoever writes the driver. The answer
then is probably still not to make `allocFrame` zero, but to give the DMA path an `allocDmaFrame()`
that does — so `frames drain` keeps costing what it costs. Recorded here so that is a decision rather
than an accident.

---

## GAP-0155 — the rule-1 check was broken on the bash macOS ships, and `set -e` was the only thing between that and a vacuous pass

**Domain:** tooling, freestanding check (fix batch, ADR-0028)
**Status:** CLOSED for the defect; two residual items below are OPEN.

`core/scripts/verify-freestanding.sh` used `mapfile` (bash 4+) at three sites. macOS ships `/bin/bash`
3.2.57, so under it the script died at exit 127. It had **never** been run on that bash: `env.sh`
prepends `/opt/homebrew/bin`, which supplies bash 5, and sourcing `env.sh` is mandatory setup — so the
shebang `#!/usr/bin/env bash` found bash 5 on every sweep this repo has ever done. The environment
that made the project usable is the same thing that hid the state of the check.

It failed **closed** only because of `set -euo pipefail`. Without `set -e`, `mapfile` failing leaves
the undefined-symbol array unset, the loop examines nothing, and the script prints `FREESTANDING:
pass` **having checked zero symbols.**

Three further defects were found and fixed in the same pass, each independently able to produce a
vacuous pass:

1. **`nm`'s exit status was swallowed.** `mapfile -t undef < <("$NM" ... 2>/dev/null | awk ... )` — a
   pipeline reports `awk`'s status, and a process substitution's status is never examined at all.
   Measured: `NM=/bin/false` gave **status 0, empty output**, identical to a genuinely clean object.
   Since every conclusion here is drawn from the **absence** of a symbol, a broken `nm` was reported
   as a pass. Now captured explicitly and **FATAL, exit 2**.
2. **`"${arr[@]}"` on an empty array aborts under bash 3.2 with `set -u`.** `ALLOWED` is empty **by
   design**, so this was certain to fire. All expansions that can be empty now use
   `${arr[@]+"${arr[@]}"}`.
3. **`sed 's/\s*$//'` was actively wrong, not merely non-portable.** BSD `sed` reads `\s` as a literal
   `s`, so it never stripped trailing whitespace and it **truncated symbol names ending in `s`** —
   turning the allowlist glob `__aeabi_*s` into `__aeabi_*`, which **permits more than its author
   wrote**. Now `[[:space:]]`. (`/usr/bin/grep -E` does accept `\s`; changed anyway.)

**Deliberately NOT done: no non-vacuity guard on the allowlist.** The allowlist is empty by design —
the freestanding baseline genuinely permits zero symbols. A sibling repo added such a guard and it was
wrong: it made the correct configuration a hard FATAL. Asserting the non-emptiness of something
designed to be empty is the same defect as a vacuous pass, pointed the other way. A vacuity guard is
correct only where the empty case is genuinely impossible — which is why `nm`'s path has one and the
allowlist's does not. See ADR-0028 §3.

**Verified** by three negative controls under `/bin/bash` explicitly (clean → 0; leaked `dc_alloc` →
1; `NM=/bin/false` → FATAL 2), two more covering the empty-`ALLOWED` loop and the manifest path, and a
byte-identical old-vs-new differential across all five objects and `kernel.elf`.

**OPEN residuals:**

* **Leading whitespace on an allowlist or manifest entry is still retained**, so `"  foo"` never
  matches the symbol `foo`. That is pre-existing behaviour, preserved deliberately — trimming it would
  change *what the allowlist permits*, a semantic change to rule 1's spine that wants its own
  decision. Harmless while the allowlist is empty; a trap the first time an entry is added with a
  stray indent.
* **Nothing enforces the bash-3.2 rule.** The three rules are documented in the script's header and
  the harnesses' comments, but no check fails if someone reintroduces `mapfile`, `declare -A` or an
  unguarded `"${arr[@]}"`. A CI step running the freestanding controls under `/bin/bash` would close
  this; it is not written.

---

## GAP-0156 — no conformance harness has `set -e`, so `set -u` is load-bearing by accident

**Domain:** tooling, conformance harnesses (fix batch, ADR-0028)
**Status:** OPEN — the three known instances are fixed; the structural weakness is not. **Surveyed
2026-08-26 (ADR-0030): 0 of 20 harnesses can take `set -e` as written; 20 of 20 are blocked.** The
per-harness work list is at the bottom of this entry, and ADR-0030 argues that `set -e` is the wrong
mechanism for this suite in any case. Superseding work is GAP-0168.

**UPDATE 2026-08-26 (ADR-0032, GAP-0168's implementation). Two things changed here, and one of them
is a correction to this entry's own numbers.**

1. **The class-A total in the table below is wrong: it is 86, not 135.** The classifier counted BOTH
   lines of the two-line idiom for some sites — `m0-boot` is listed as `A: 39, 40, 63, 83`, where 39
   and 40 are the command and its `$?` while 63 and 83 are single lines of the identical two-line
   shape. Three independent counts agree on 86: `grep -cE '^[[:space:]]*(local[[:space:]]+)?[A-Za-z_]
   [A-Za-z0-9_]*=\$\?[[:space:]]*$'` over the suite, `grep -c '\$?'` (89 = 86 assignments + 3 direct
   reads), and the number of helper calls after conversion. The **conclusion** the survey drew from
   the number — class A is universal, 20/20, minimum four per harness — is unaffected and was
   re-confirmed. Only the total was wrong, and it was quoted as the COST of the conversion in
   ADR-0030 §3.3 and GAP-0168, which is how a 57%-too-high number gets work deferred.
2. **All 86 are converted** (plus two more that read `$?` on the following line: 88 in total), to the
   `capture` / `capture_log` / `capture_sh` / `run_status` / `await` helpers in
   `core/tests/conformance/_lib/harness.sh`. **`set -e`'s prerequisite is therefore met**: every
   wrapped command runs inside an `if` condition, where `set -e` is suppressed, so the helpers are
   already safe under it. Whether to adopt `set -e` at all is still ADR-0030's "no", and classes C
   and G below are still the reason. This entry stays OPEN for that question alone; it is no longer
   blocked on class A.

`declare -A` (bash 4+) appeared in `m13-libc:248`, `m8-paging:174` and `m9-ring3:158`. Under
`/bin/bash` 3.2 the declaration fails and the subsequent `SYM[__kernel_start]=...` becomes an
**indexed** assignment whose subscript is evaluated as **arithmetic**, so the harness aborts at exit
127 — **after** printing several `STRUCTURAL: pass` lines and before reaching most of its own
assertions. All three are now bash-3.2-compatible and all three pass under `/bin/bash` 3.2, with every
assertion and message unchanged (ADR-0028 §6).

**The structural point, which is not fixed.** All twenty harnesses use `set -uo pipefail`; **none has
`set -e`.** They rely on explicit `fail()` calls. So the only reason the `declare -A` breakage was
loud is that `set -u` happened to catch the arithmetic subscript — and that is luck, not design: had
the subscript been a *defined* numeric variable, bash 3.2 would have silently collapsed every key to
index 0 and the harness would have continued with a corrupt map and reported PASS. **A harness that
aborts before reaching its own assertions while still reporting success is the same vacuous-pass
defect** as GAP-0155, and nothing in the current `set` flags rules it out in general.

Adding `set -e` to twenty harnesses is not a safe drive-by — these scripts use `cmd || fail ...`,
`grep -q` as a predicate and `(( ... ))` in conditions, several of which legitimately return non-zero
— so it wants its own unit, harness by harness, with each one re-run.

**Method note, recorded because it generalises.** Grepping for `declare -A` found the three
declarations and **missed five further `${SYM[...]}` expansions** further down `m8-paging`, which only
surfaced when the harness was actually executed under `/bin/bash`. A portability claim is worth what
its execution under the target interpreter is worth, not what a grep says.

---

### The survey (2026-08-26) — what actually blocks `set -e`, harness by harness

**The paragraph above names the wrong constructs.** Executed under `/bin/bash` 3.2.57 with
`set -euo pipefail`, `cmd || fail ...` is **safe** (`set -e` is suppressed for every command in a
`&&`/`||` list except the last), `(( ... ))` **in a condition** is **safe** (condition contexts are
suppressed too), and `grep -q ... || fail` is **safe** for the same reason as the first. There are
**zero** bare `(( ... ))` statements and **zero** uses of `let` anywhere in the suite.

The construct that actually blocks all twenty was not named: **capture-then-`$?`**.

```sh
BUILD_OUT="$(bash "$CORE_DIR/scripts/build-kernel.sh" 2>&1)"
BUILD_STATUS=$?          # <-- under set -e this line is NEVER REACHED when the build fails
echo "$BUILD_OUT"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
```

Under `set -e` the assignment aborts the harness. `fail()` never runs, so there is **no**
`M<n>: FAIL — ...` line and no captured build output — a strict regression in diagnosis. Verified by
execution, not by reading the manual.

**Classes.** A = capture-then-`$?`. C = a bare predicate as a statement (`cmp`/`diff` in a diagnostic
block, `hdiutil detach` in cleanup, `grep`) whose non-zero status is expected. G = `grep -q ... && fail`,
where the *good* case is grep returning 1.

| Harness | A | C | G | Blocking sites (line numbers) |
|---|---:|---:|---:|---|
| `m0-boot` | 4 | 0 | 0 | A: 39, 40, 63, 83 |
| `m1-interrupts` | 4 | 1 | 0 | A: 72, 73, 314, 342 · C: 361 |
| `m2-console` | 6 | 3 | 0 | A: 106, 107, 241, 242, 302, 311 · C: 337, 348, 360 |
| `m3-shell` | 7 | 7 | 0 | A: 104, 105, 283, 284, 376, 377, 385 · C: 413, 424, 458, 477, 478, 480, 491 |
| `m4-fault` | 7 | 7 | 1 | A: 105, 106, 382, 383, 464, 465, 473 · C: 503, 514, 595, 614, 615, 617, 628 · G: 127 |
| `m5-pci` | 7 | 5 | 12 | A: 138, 139, 511, 512, 714, 715, 726 · C: 753, 764, 920, 998, 1020 · G: 153, 340, 534, 541, 550, 554, 564, 573, 577, 586, 596, 618 |
| `m6-disk` | 7 | 5 | 13 | A: 103, 104, 380, 381, 557, 558, 568 · C: 596, 604, 605, 738, 835 · G: 299, 402, 409, 418, 422, 432, 441, 445, 454, 464, 477, 482, 838 |
| `m7-frames` | 7 | 4 | 10 | A: 111, 112, 558, 559, 688, 689, 698 · C: 785, 793, 794, 1072 · G: 292, 574, 584, 588, 598, 607, 611, 620, 630, 646 |
| `m8-paging` | 7 | 4 | 9 | A: 113, 114, 454, 455, 640, 641, 650 · C: 724, 732, 733, 1043 · G: 354, 470, 474, 484, 493, 497, 506, 516, 531 |
| `m9-ring3` | 7 | 6 | 9 | A: 127, 128, 421, 422, 735, 736, 745 · C: 150, 155, 822, 830, 831, 1166 · G: 194, 344, 437, 444, 448, 457, 467, 481, 493 |
| `m10-elf` | 7 | 5 | 6 | A: 125, 126, 632, 633, 730, 731, 740 · C: 118, 807, 815, 816, 1189 · G: 297, 649, 653, 662, 672, 687 |
| `m11-proc` | 7 | 5 | 4 | A: 141, 142, 610, 611, 686, 687, 696 · C: 134, 818, 826, 827, 1341 · G: 410, 625, 633, 647 |
| `m12-heap` | 7 | 5 | 6 | A: 107, 435, 436, 482, 528, 529, 538 · C: 115, 632, 640, 641, 1006 · G: 231, 233, 450, 458, 473, 1000 |
| `m13-libc` | 7 | 6 | 5 | A: 122, 384, 385, 431, 481, 482, 491 · C: 129, 140, 543, 551, 552, 579 · G: 239, 332, 399, 407, 422 |
| `m14-fat` | 9 | 6 | 2 | A: 109, 484, 526, 527, 546, 548, 632, 633, 642 · C: 116, 581, 928, 929, 935, 945 · G: 401, 503 |
| `m15-fileio` | 9 | 5 | 3 | A: 120, 486, 516, 517, 536, 538, 618, 619, 628 · C: 127, 136, 570, 868, 873 · G: 503, 826, 830 |
| `m16-filewrite` | 9 | 7 | 8 | A: 144, 668, 698, 699, 737, 738, 818, 819, 828 · C: 151, 160, 766, 1076, 1248, 1349, 1354 · G: 685, 744, 1196, 1215, 1234, 1276, 1296, 1332 |
| `m18-preempt` | 6 | 1 | 1 | A: 103, 104, 285, 322, 323, 332 · C: 96 · G: 228 |
| `m19-argv` | 7 | 3 | 1 | A: 112, 303, 329, 330, 398, 399, 408 · C: 119, 515, 520 · G: 311 |
| `mb-info` | 4 | 1 | 0 | A: 63, 64, 93, 123 · C: 149 |
| **totals** | **~~135~~ 86** | **86** | **90** | **~~311~~ 262 sites, 20/20 harnesses blocked, 0 convertible** |

*(The class-A column is per-LINE, not per-site — see the UPDATE at the top of this entry. The line
numbers are still correct as pointers; there are just 86 distinct sites among them, and all 86 are
now converted, so the column is a historical record rather than a work list.)*

*(Line numbers are as of this commit — i.e. **after** GAP-0167's `Step 3b` was added to `m19-argv`.)*

**GAP-0167's fix added two of these sites, and that is worth stating rather than hiding.** `Step 3b`
introduces one class A (`VERIFY_OUT=$(...)` / `VERIFY_STATUS=$?` at 329–330) and one class G
(`grep -q "FREESTANDING: FAIL" ... && fail` at 311). Both were copied deliberately from
`m18-preempt` §3h and `m8-paging`, because matching the suite's existing idiom is worth more than
pre-emptively adopting a convention that has not been decided yet (GAP-0168). When the `capture()`
helper of GAP-0168 §2 lands, these two sites convert with the other 133.

**Nothing was converted, because nothing qualified.** Two notes on reading the table:

* **Class C is not uniformly benign.** The `cmp "$SERIAL_CAPTURE" "$EXPECTED" >&2` sites sit inside
  failure-diagnostic blocks, where `cmp` returning 1 *is* the expected case. Under `set -e` the
  harness would abort **inside its own diagnostic**, before the `fail "..."` that names what went
  wrong — losing the message while keeping the non-zero exit. The `hdiutil detach` sites
  (`m14-fat:581`, `m15-fileio:570`, `m16-filewrite:766` and `1076`) are cleanup and can legitimately
  return non-zero when the volume is briefly busy.
* **Class G is load-bearing style, not sloppiness.** `grep -q "\b$gone\b" <<<"$VERIFY_OUT" && fail
  "$gone is still declared extern"` is how nine harnesses assert the ADR-0021 extern deletions. The
  passing case is grep exit 1. Converting these means inverting ~89 assertions, each with its own
  sentence.

**ADR-0030 is the decision**: do not adopt `set -e`; adopt an assertion-count floor plus a `capture()`
helper instead, because `set -e` does not catch this gap's own motivating example (a collapsed
`declare -A` map produces no non-zero status anywhere — every assignment succeeds and the harness
compares wrong values against wrong values). GAP-0168 tracks that work.

---

## GAP-0157 — `m9-ring3` is flaky: an intermittent RFLAGS.RF bit in the ring-3 register dump

**Domain:** conformance, ring 3 (observed during the ADR-0028 fix batch)
**Status:** OPEN — newly observed, not diagnosed.

`m9-ring3` failed once during this unit with a one-line serial diff:

```
< USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000000202 CPL 3
> USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000010202 CPL 3
```

Bit 16 is **RF (Resume Flag)**. `expected.txt` pins the full RFLAGS word, so an RF that is sometimes
set makes the byte-exact serial comparison non-deterministic. The same harness then passed on retry
under **both** `/bin/bash` 3.2 and bash 5, and the pristine pre-change harness also passed — so this is
**not** caused by the ADR-0028 changes, which touch only a selector comparison performed before QEMU
is started.

This is a **second, distinct flake** from the known `m12-heap` one and had not been recorded before.
The likely fix is for the harness to mask RF (and any other CPU-managed bit not under test) before
comparing, rather than pinning the whole word — M9's claim is about CPL, CS and SS, not about RF. Not
done here: it changes what an existing golden asserts, which wants its own unit.

**UPDATE 2026-08-26 (GAP-0168's unit): the `m12-heap` flake is THIS flake, not a separate one, and
here is the measurement rather than the assertion.** `m12-heap` failed three times during that unit,
every time on a line of exactly this shape:

```
< USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000000246 CPL 3
> USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000010246 CPL 3
```

Same bit 16, same `expected.txt`-pins-the-whole-word cause, different harness — and note the polarity
is the reverse of M9's: here the golden has RF **set** and the flaky run has it clear, so whichever
way the bit lands, a golden that pins the whole word is a coin toss.

**Attribution, because a flake appearing during a unit that touched all twenty harnesses needs one.**
`m12-heap` was run from the instrumented harness and from the **unmodified HEAD harness**, alternating,
on the same loaded machine:

| | runs | passed | failed, this exact diff |
|---|---:|---:|---:|
| HEAD, untouched by that unit | 4 | 3 | **1** |
| instrumented (`ck` + `capture`) | 6 | 4 | 2 |

**The unmodified harness reproduces it**, so the flake is not the instrumentation's. It correlates
with machine load — all three instrumented failures were inside a full sweep with four or five other
QEMUs running, and every standalone run passed — which fits an RF that depends on where a fault lands
relative to the keystroke injection. Not diagnosed further, and still not fixed: the fix is the same
one this entry already proposes (mask the CPU-managed bits before comparing) and it now has two
harnesses' goldens to move rather than one.

**UPDATE — same defect, and the remedy now exists next door.** GAP-0212 turned out to be this exact
bug in `m12-heap`, and it is now closed there: `rflags_canon()` in `m12-heap/run.sh` clears bit 16 in
both the capture and the golden before the `cmp`, with four guards that fail the harness if the
normalisation ever stops matching, if the two files disagree on how many RFLAGS fields they hold, if
the rewrite changes the file's length, or if the screen golden grows an RFLAGS field of its own.
**`m9-ring3` is still OPEN and was deliberately not changed during that integration** — the scope
there was the merge and `m12-heap`'s flake, and quietly editing what a second, unrelated golden
asserts is how a merge starts hiding things. But whoever takes this should copy that helper rather
than reinvent it, and should keep its guards: the `0202` in the diff above means IF and the reserved
bit and nothing else, so blanking the word instead of the one bit would vacate M9's only evidence
that ring 3 ran with interrupts enabled.

---

## GAP-0158 — There is no `ioctl` and no device namespace, and the DRM ABI is an ioctl ABI reached through a device node

**Domain:** kernel, syscalls, ABI (design unit, ADR-0029)
**Status:** **CLOSED by ADR-0033.** `ioctl` is syscall 12 and is implemented in
`core/kernel/ioctl.dart`; `/dev/dri/card0` and `/dev/dri/renderD128` are served from `fileSysOpen`.
Both halves this entry called "separable" were built in one unit, because the second is four
lines once the first exists.

**What was built, against what this entry asked for:** the `_IOC` decode with all four fields; a
dispatch on `_IOC_NR` that is never handed the request word; `_IOC_SIZE` checked against the
descriptor's SET and **refused, not zero-extended**, on a mismatch; a size above `ioctlMaxPayload`
(256) **refused, not truncated**; both of M16's pointer validators, read-side for `_IOC_WRITE` and
write-side for `_IOC_READ` and **both before either copy** on an `_IOWR`; and a copy through a
kernel `.bss` bounce buffer, so a driver is handed an offset and never a ring-3 pointer. The
device branch went in `fileSysOpen` after the validated copy and before `fatParseAt`, **not** in
`fatLookup` — exactly as this entry warned in bold.

**The syscall registry this entry asked for in its third point was built by ADR-0031**, one unit
ahead of `ioctl`, which is what it asked for.

**What is NOT closed and is now GAP-0177:** there is no DRM driver behind the syscall and no DRM
semantics at all. What works is the membrane. Also still open: `mmap` (GAP-0159) and
`drmGetDevices2` (GAP-0171).

**Verified by** `tests/conformance/drm-abi/run.sh` CHECKs 14–16, four mandatory negative controls,
and four mutations, all killed.

*The original entry follows, unchanged, because what it asked for is the specification that was
implemented.*

The kernel has **ten syscalls** — `exit`, `write`, `who`, `yield`, `sbrk`, `open`, `read`, `close`,
`seek`, `fdwrite` (`core/user/libc/oslibc.h:66`–`80`). **`ioctl` is not among them and no equivalent
exists in any form.** The Linux DRM ABI that ADR-0029 adopts is delivered entirely through `ioctl`:
measured against Linux 6.12, `include/uapi/drm/drm.h` defines **109** `DRM_IOCTL_*` constants and
`drivers/gpu/drm/drm_ioctl.c` dispatches **75** of them.

Two distinct missing pieces, and they are separable:

1. **The syscall.** `ioctl(fd, request, argp)` where `request` is an `_IOC`-encoded word carrying
   direction (2 bits), payload size (14 bits), type letter (8 bits) and command number (8 bits). A
   server must decode all four. **It must not switch on the whole 32-bit value**, because `libdrm`
   computes the number from `sizeof(struct)` at compile time — a struct whose size differs by one byte
   produces a different request number and the mismatch is silent. The copy-in/copy-out is bounded by
   `_IOC_SIZE` and must go through M16's two mutation-tested pointer validators; a size above a fixed
   bound must be **refused**, not truncated.
2. **Something to call it on.** Every `open` on this OS goes to FAT16, root directory, 8.3 names
   (ADR-0018). **There are no device nodes.** `display-protocol.md` §2.1 already solved the shape —
   a reserved-name branch carrying the `:` sigil, which `fatNameByteBad` already forbids in disk names,
   so the two namespaces are disjoint by construction. **That document also recorded the trap and it
   applies verbatim here: the branch goes in `fileSysOpen` (`file.dart:1360`), after the
   pointer-validated bounce-buffer copy and before `fatParseAt` — NOT in `fatLookup`, where
   `fileMakeEmpty` would treat the device name as a real directory entry, truncate and rewrite it. A
   device branch in `fatLookup` is a ring-3-reachable volume corruption.**

**A third thing this surfaces, and it is not graphics.** `design/README.md` fix #2 asks for a
**syscall-number registry** because numbers 0–10 live in four files and **two agents have both already
written `= 11`** (`fdwait` and an earlier display draft). `ioctl` is at least the third claimant on a
number. **The registry should be built in the same unit as `ioctl`, not after it.**

**Cost of the workaround:** there is no workaround. Without `ioctl` there is no DRM ABI, and without a
device namespace there is nothing to issue it against. `drm-abi.md` S0 and S1 are the rungs.

---

## GAP-0159 — There is no `mmap`, and every DRM buffer object is reached through one

**Domain:** kernel, memory, ABI (design unit, ADR-0029)
**Status:** OPEN — NARROWED (ADR-0128, `plat-map/`): a named
`PLAT.ELF` may `mmap(len)` anonymous pages (syscall 27). TAP/FILES
and `ASK.ELF` are still refused. There is still no `munmap`, no
`mprotect`, no fd/`MAP_SHARED` map, and no DRM GEM offset map.

`sbrk` (ADR-0016) is still how every other ring-3 program obtains a
page. ADR-0128 is the platform door, not this unit.

**The DRM ABI does not have an alternative path.** A GEM buffer object is reached by calling a
driver-specific ioctl to obtain a **fake offset** — Linux calls the machinery the
`drm_vma_offset_manager`; virtio-gpu's is `DRM_IOCTL_VIRTGPU_MAP`, xe's is
`DRM_IOCTL_XE_GEM_MMAP_OFFSET` — and then calling **`mmap` on the DRM file descriptor at that offset**.
The offset is a token in a per-device address space, **not a file offset**, and a `read`/`write`
substitute does not exist in the ABI. `drm_gem.c` is 1,535 lines and `drm_gem_shmem_helper.c` — the
shared implementation for drivers whose buffers are ordinary system pages, which is virtio-gpu's case
and would be ours — is 782.

**The prerequisite, and it is the important half of this entry.** A mapped buffer object outlives the
handle that created it, and a second process may map the same object. Today:

* `freeFrame` is a plain bit-clear with **no reference count**;
* `procSpaceFree` frees **every present leaf** in the window unconditionally.

`display-protocol.md` §1.3/§8 wants this fixed for shared surface frames and calls mapping one physical
frame into two address spaces *"unsound today… silent at the machine level and only loud at the harness
level"*. `blocking-and-threads.md` §4.3 wants the same fix for shared page tables under threads. **This
is now a third consumer, and it should be one unit for all three rather than three.**

**Cost of the workaround:** there is none available. A copy-based substitute would defeat the entire
point of the buffer-object model, whose purpose is that the device reads the pages the CPU wrote.

---

## GAP-0160 — No file descriptor can cross a process boundary, so PRIME and dma-buf have no transport

**Domain:** kernel, IPC, ABI (design unit, ADR-0029)
**Status:** OPEN — nothing implemented. The receiving slot exists and is reserved; the mechanism does not.

`DRM_IOCTL_PRIME_HANDLE_TO_FD` turns a GEM handle into a file descriptor. That fd is a `dma-buf`: it can
be `mmap`ed, `poll`ed for its implicit fence, given `DMA_BUF_IOCTL_SYNC`
(`include/uapi/linux/dma-buf.h`, 182 lines — the whole uAPI), and imported by a *different* device with
`PRIME_FD_TO_HANDLE`. `drivers/dma-buf/` is 8,618 lines.

**The ioctls are not the problem. The transport is.** On Linux an fd crosses a process boundary through
`SCM_RIGHTS` on a Unix socket. This OS has **no sockets, no fd passing, and no mechanism that could
carry one** (`display-protocol.md` §0). That document ranked it first in its retrofit table and called
it *"the single hardest thing to retrofit"*, because buffers, keymaps and clipboard all ride on it.

**What is already right about this.** `display-protocol.md` §2.5 and §5.3(1) reserved **four handle
words in the verb-batch header, defined as must-be-zero**, precisely so a future out-of-band handle
transport needs no wire-format version 2. **Those four words are the slot, and ADR-0029 is the first
consumer that justifies filling them** (`drm-abi.md` R5, C1). The foresight cost sixteen bytes and it
is about to pay.

**One scope note that keeps this smaller than it looks.** Under ADR-0029's containment (`drm-abi.md`
§4.3) the compositor talks to a Mesa-hosting process and clients still send drawing verbs. **So the
number of fd-passing boundaries is one, inside the system's own trust domain — not one per client, as
it would be under Wayland.**

---

## GAP-0161 — The DRM ABI is per-driver below `DRM_COMMAND_BASE`, so "one ABI, all GPUs" is false, and here are the numbers

**Domain:** ABI, planning (design unit, ADR-0029)
**Status:** OPEN as a record — this is not a defect to fix, it is a fact that corrects an expectation,
and it is filed so nobody re-derives it.

ADR-0029's rationale is that Mesa already covers Intel, AMD, Nvidia, Adreno and Mali, so implementing
"the DRM ABI" means being able to run what exists. **That is true of the userspace half of a GPU driver
and false of the kernel half**, and the ioctl number space says so directly. From
`include/uapi/drm/drm.h`:

| range | meaning |
|---|---|
| `0x00`–`0x3F` | core DRM — **shared**, 75 table entries, of which **17** are `DRM_RENDER_ALLOW` |
| `0x40`–`0x9F` | `DRM_COMMAND_BASE`..`DRM_COMMAND_END` — **per-driver** |
| `0xA0`–`0xBC` | KMS — **shared**, 38 ioctls |
| `0xBF`–`0xCD` | `drm_syncobj` — **shared**, 12 ioctls |

Measured per-driver, Linux 6.12, `wc -l include/uapi/drm/*_drm.h` and a `grep` for the ioctl defines:

| driver | uAPI header lines | ioctls |
|---|---:|---:|
| `virtgpu` | 270 | **11** (all `DRM_RENDER_ALLOW`) |
| `panfrost` | 282 | 9 |
| `msm` | 405 | 12 |
| `nouveau` | 520 | 13 |
| `panthor` | 966 | 15 |
| `amdgpu` | 1,299 | 16, **plus 53 `AMDGPU_INFO_*` sub-queries behind one ioctl** |
| `xe` | 1,701 | 12 |
| `i915` | **3,916** | **62**, plus 59 `I915_PARAM_*` and an open-ended extension-chain scheme |

**The ioctl count understates the difference and the header line count understates it further.** `xe`
has twelve ioctls and 1,701 header lines because the work moved into the structures: `drm_xe_vm_bind`
is a page-table programming interface, `drm_xe_exec_queue_create` is a hardware context, and
`drm_xe_device_query` returns the ASIC's topology. **Serving those honestly means having the thing they
describe — which is the kernel driver `gpu.md` §1 measured at 560,555 lines for Intel and ~1.2 million
non-header lines for AMD, behind firmware that is cryptographically signed.**

**The correct statement, and the one to quote if this comes back:** *implementing "the DRM ABI" for a
given GPU is not an alternative to writing that GPU's kernel driver — it is the interface that driver
exposes.* What the shared 17 + 38 + 12 buy is that the day such a driver exists, Mesa works against it
unchanged. **What actually delivers "almost all GPUs" under ADR-0029 is virtio-gpu's eleven ioctls plus
venus / virgl / DRM native context, and that works in a virtual machine and nowhere else**
(`drm-abi.md` §1.3, §6.3).

---

## GAP-0162 — Mesa would be the first C library this OS ever links, and there is no C++ runtime at all

**Domain:** toolchain, userland, planning (design unit, ADR-0029)
**Status:** OPEN — two items, of which the second is the larger and is unscoped anywhere in the project.

**1. Reuse in this project is currently zero, and Mesa is the wrong place to start.** Kernel, libc and
drivers are all hand-written DCDart. DCDart has extern FFI (DCDart ADR-0038, verified) and **the OS has
never linked a real C library.** The libc is **32 exported functions**, of which 9 are C89 names
(`libc-roadmap.md` §1.1). The ELF loader **refuses `ET_DYN` and `PT_INTERP` by name** (`elf.dart:1280`,
GAP-0091). Pointing that toolchain at one of the largest C/C++ codebases in existence as its first
target is the highest-variance possible plan.

**The recommendation is concrete and is on the critical path anyway: `libdrm` is the right first C
library.** It is small, it is almost entirely `ioctl` wrappers and struct marshalling, it needs no
threads beyond atomics, no C++ and no libm — and decisively, **it is the thing that tells you whether
your DRM ABI is right**, because its own `modetest` and `drmdevice` tools are a conformance suite for
the first four DRM rungs written by somebody else. That is exactly the independently-authored
expectation every exit criterion in this repo is built on. ⚠ *libdrm's size and undefined-symbol count
were not measured — `drm-abi.md` V0 is the rung that measures them.*

**2. There is no C++ runtime, and no document in this project has ever scoped one.**
`libc-roadmap.md` is 1,518 lines about the C library and does not mention C++ once. Its picolibc
recommendation does not touch it. But **Mesa's Vulkan runtime and several of its drivers are C++17, and
ACO is C++20.** A C++ runtime needs `operator new`/`delete`, `__cxa_atexit` and static-initialisation
ordering, RTTI unless every object is built `-fno-rtti`, and either exception support — an unwinder,
`.eh_frame`, a personality routine — or a proof that the whole build links `-fno-exceptions`.

⚠ *Whether the venus path specifically can be built entirely `-fno-exceptions -fno-rtti` is unmeasured,
and it is the difference between "a few hundred lines of glue" and "port libc++abi". `drm-abi.md` V0
measures it by checking whether the built venus ICD has any undefined `_Z*` symbols at all.*

**This is the single largest unbudgeted item in ADR-0029's plan.** `libc-roadmap.md`'s tier table
(A…E) has no row for Mesa and should gain one: Mesa sits **above** tier E, because it needs everything
tier E needs *plus* a C++ runtime that no tier includes.

---

## GAP-0163 — This machine's QEMU cannot exercise any 3D or compute path, and no software substitute exists

**Domain:** tooling, conformance, environment (design unit, ADR-0029)
**Status:** NARROWED — Homebrew QEMU 11.0.0 on this arm64 Mac still has no
`virtio-gpu-gl-pci`. G10 (`g10-virgl/`, ADR-0098) boots a Docker image
`oscortex-qemu-gl:local` (`scripts/build-qemu-gl.sh`: Debian sid
`qemu-system-x86` 11.1.0 + `qemu-system-modules-opengl` +
`libvirglrenderer1` + Xvfb + llvmpipe). That is the 3D QEMU. Vendor
GPUs and Skia-on-this-GPU remain OPEN.

Measured on this Mac, 2026-08-26, QEMU 11.0.0 (Homebrew):

```
$ qemu-system-x86_64 -device help | grep -i virtio-gpu
name "virtio-gpu-device", bus virtio-bus
name "virtio-gpu-pci", bus PCI, alias "virtio-gpu"
name "virtio-vga", bus PCI

$ qemu-system-x86_64 -display help
none  curses  cocoa  dbus
```

**There is no `virtio-gpu-gl-pci` and no `vhost-user-gpu`**, so this QEMU was built without
virglrenderer; and **no EGL-capable display backend**, so there is nothing for a 3D backend to render
into. `gpu.md` §3.8 already measured the consequence from the guest side on the same machine:
`device_feature[0..31] = 0x30000002` with `VIRTIO_GPU_F_VIRGL` (bit 0) **clear**, and `num_capsets = 0`.

**Every rung from `drm-abi.md` R4 (`EXECBUFFER`) onward — which is the entire Vulkan compute track —
requires a Linux host with a QEMU built against virglrenderer.** That host does **not** need a discrete
GPU: a Linux host's own llvmpipe would serve. It does need to be Linux.

**And there is no software substitute, which is the part worth stating.** The obvious one is Mesa's
**lavapipe** — a conformant software Vulkan implementation needing no GPU and no DRM at all, which
would let the whole Vulkan stack be proved with zero driver work. **It requires LLVM in the guest**: it
JITs, which means millions of lines of C++ and an `mmap(PROT_EXEC)` hole in the W^X policy ADR-0012
established. That is not a rung, it is a second project. `drm-abi.md` §3.3 has the per-driver table;
the only Mesa Vulkan drivers that need no LLVM are the ones that need real hardware or a host to
forward to.

**Consequence if the host is not available:** the compute ladder stops at "the venus ICD links against
our libc" and **the honest statement becomes that the compute path cannot be proved on the available
hardware.** That is `drm-abi.md` Q5 and it is an owner question, not an engineering one.

---

## GAP-0164 — There are no fences, no vblank events, and no way to deliver either

**Domain:** kernel, ABI, scheduling (design unit, ADR-0029)
**Status:** OPEN — the primitive that would carry them is designed (`fdwait`) and unbuilt.

The DRM ABI reports completion three ways and a serious implementation eventually needs all three:

1. **`drm_syncobj`** — 12 ioctls, `drivers/gpu/drm/drm_syncobj.c` is 1,719 lines. Binary **and
   timeline** semaphores; this is what Vulkan's `VkSemaphore` and `VkFence` map onto. `DRM_CAP_SYNCOBJ`
   and `DRM_CAP_SYNCOBJ_TIMELINE` gate them, so a first implementation may honestly answer *no*. ⚠ *I
   do not know whether any current Mesa Vulkan driver still functions with syncobj declined — RADV and
   ANV have required it for years. This is the single most likely place the compute ladder stalls, and
   `drm-abi.md` V2 is where it is found out.*
2. **`sync_file`** — an fd whose readiness *is* the fence
   (`include/uapi/linux/sync_file.h`, 113 lines), interoperating with `poll` and with dma-buf's
   implicit fences.
3. **Event records read off the DRM fd.** `read(2)` on a DRM descriptor returns a stream of fixed-size
   records — `DRM_EVENT_VBLANK`, `DRM_EVENT_FLIP_COMPLETE`, `DRM_EVENT_CRTC_SEQUENCE`. **This is how a
   compositor learns a page flip completed**, and it is the mechanism `display-protocol.md` §3.2
   refused to claim tearing was eliminated without. Repo-wide there is still no vblank interrupt of any
   kind.

**All three want a blocking wait, and this OS still has none.** `blocking-and-threads.md` designed
exactly the right primitive — `fdwait(mask, timeoutTicks) → readyMask`, level-triggered, re-tested by
the kernel at wake time — and nothing is built. **This entry adds a fourth readiness kind to that
document's §3.5 table: a DRM descriptor is ready when an event record is queued.**

**The asymmetry worth recording, because it is why the compute path is harder here than the display
path.** `gpu.md` §3.6 argued correctly that a first virtio-gpu driver can **poll** the used ring and
that this is the same trade `ata.dart` already made. That stays true for display. **It does not
transfer to compute: a dispatch you poll for burns the core you were trying to free**, so real fences —
and, behind them, MSI-X and the local APIC this kernel has never touched — are promoted from "not
needed" to "wanted" the moment `drm-abi.md` V3 exists.

---

## GAP-0165 — Write-combining is now a correctness bug rather than a performance note, and this narrows GAP-0071 item 1

**Domain:** kernel, memory, hardware correctness (design unit, ADR-0029)
**Status:** OPEN — **narrows GAP-0071 item 1**, which predicted this and did not name the subsystem
that would trip it.

GAP-0071 item 1 records that `core/boot/boot.S` maps all of `[3 GiB, 4 GiB)` **writable, cacheable,
with no MTRR or PAT setup**, and says of it:

> for a *linear framebuffer* specifically it is benign and even desirable… **the moment it touches a
> real device register through a BAR rather than a framebuffer, this becomes a correctness problem
> rather than a performance note.**

`gpu.md` §3.5 named the first subsystem that trips it — a virtio-gpu driver's common-configuration,
ISR and notify registers — and recorded it as *"known-wrong, invisible here"*: under TCG nothing
notices, and under KVM the EPT memory type for an MMIO slot forces uncacheable regardless of the guest
PAT.

**ADR-0029 adds a second and worse case, and it is not invisible under emulation for the same reason.**
A GEM buffer object that is CPU-mapped and device-read is the classic write-combining case: the CPU
streams pixels or command-buffer bytes into it, and the correct memory type is **WC**, not WB and not
UC. Getting it wrong is a large, silent performance loss on every frame and every dispatch, and — where
the device reads without a snoop — a correctness bug.

**Two distinct memory types are therefore wanted, and they are not the same fix:**

* **UC / UC-** for device registers reached through a BAR (GAP-0071 item 1's original case);
* **WC** for CPU-mapped buffer objects (this entry's case).

**The narrow fix, unchanged from `gpu.md` §3.5's:** program PAT entries and map the specific pages with
`PWT`/`PCD`/`PAT` set, rather than remapping the whole gigabyte. That is real page-table work at
runtime and it is its own unit. **Until it exists, no claim that this driver stack is
hardware-correct should be made** — and under ADR-0029 that caveat matters less than it looks, because
§8.2 of that ADR says bare metal is not reachable anyway.

---

## GAP-0166 — The reflective membrane has no mechanism: an `@extern` declaration carries no descriptors, and Mesa is the largest zombie the project will consider

**Domain:** cross-repo dependency, DCDart-side language gap, ABI (design unit, ADR-0029)
**Status:** OPEN — recorded from this side of the seam. **The decision it depends on is DCDart's, not
this repo's**, and DCDart's own escalation for it is open and unratified.

DCDart escalation 0004 §6 states the tension this project has now committed to:

> **C libraries are zombies by construction, and linking them does not fix that.** … Every FFI boundary
> is a hole in the reflective world, and the holes are exactly where the large, useful, already-written
> software lives.

It offers three options — FFI it in, simulate it, **describe the boundary** — and recommends the third:
*"the FFI declaration itself carries full descriptors, so the interface is reflective even though the
implementation is opaque."* **Nothing implements it.** DCDart ADR-0038 built `@extern` as a signature
plus a sidecar `<output>.o.externs` manifest of permitted-undefined symbol *names*. A name is not a
descriptor: it records that `ffs` may be undefined, not what `ffs` takes, returns or means.

**Two things this repo should record, and neither is a request to change DCDart.**

1. **ADR-0029 §7 takes option 3 and specifies the mechanism as a build-time table generator in *this*
   repo**, reading `include/uapi/drm/*.h` and emitting a descriptor per ioctl request number — name,
   direction, size, field list — which the dispatcher validates against and which backs a `drm trace`
   command that can say, by field name, what crossed. **That is not a DCDart language feature and
   CLAUDE.md rule 3 applies in the negative: nobody should open a DCDart escalation for it.** It is the
   same category as `derive.py` and `check-font.py`.
2. **The DRM boundary is unusually well suited to being described, and that is worth writing down
   because the next boundary will not be.** It is one call — `ioctl(fd, request, argp)` — carrying one
   flat POD struct per request number, with the struct's exact size encoded in the request number
   itself, defined in 24,265 lines of public, versioned, stability-guaranteed uAPI, with **nothing
   crossing that the kernel does not own on both sides.** Compare ffmpeg, whose boundary is hundreds of
   hand-written signatures with prose-documented ownership — which is precisely why DCDart ADR-0038
   refuses ARC-managed types in an `@extern` signature. **A generated-descriptor plan that works for
   DRM does not automatically work for ffmpeg, and the two should not be costed together.**

**What remains genuinely DCDart's:** whether `@extern` declarations ever carry descriptors in the
language, which is escalation 0004 §6's open question and is blocked behind that escalation's items 2
and 3 (ratify the introspection/intercession split; ship static `.rodata` emission — the latter having
landed since, as ADR-0040/0051).

**The limit, stated so this entry is not read as bigger than it is.** Describing a boundary describes
*what crosses it*. Mesa's internal state, threads, heap and shader IR stay opaque, and ADR-0029 §7(d)
says so. The architectural half of the answer — Mesa quarantined in its own address space behind
oscortex's own protocol for the display path — is this repo's and is recorded in `drm-abi.md` §4.3.

---

## GAP-0167 — `m19-argv`'s PASS line claims `verify-freestanding` ran. It never invokes it.

**Domain:** conformance, rule 1 (found during the ADR-0028 fix batch)
**Status:** **CLOSED** 2026-08-26 (ADR-0030 §6). Fixed and verified — see "How it was fixed" below.

`core/tests/conformance/m19-argv/run.sh` ends with a PASS message reading
`... -> build-progs checks (...) -> verify-freestanding -> FOUR real QEMU boots`. **The only mention
of `verify-freestanding` anywhere in that harness is that sentence.** There is no invocation:

```
$ grep -cE 'verify-freestanding\.sh' core/tests/conformance/m19-argv/run.sh
0          # vs 4 in m8-paging, m13-libc, m14-fat, m16-filewrite, m18-preempt; 5 in m15-fileio
$ grep -c 'FREESTANDING: pass' <m19-argv run log>
0          # vs 1-4 for every other harness
```

Every other harness runs it **and checks its status** — `VERIFY_STATUS`/`FS_STATUS` captured, plus a
`grep -q "FREESTANDING: FAIL"` belt-and-braces in `m8-paging` and `m13-libc`. M19's does neither.

**This is the same defect as the rest of this batch, in its purest form: a PASS message asserting a
check that did not run.** It is not a vacuous *check* — it is a vacuous *claim*, which is worse,
because the claim is what a reader audits and no amount of re-running the harness will contradict it.

**Severity, honestly stated.** Rule 1 is not currently unenforced: `m18-preempt` and six other
harnesses run `verify-freestanding` against the same `build/kmain.o`, `kdata.o`, `portio.o` and
`kernel.elf` that M19 builds, so a leaked runtime symbol would still be caught by the suite. What is
missing is M19's *own* assertion of it, and what is wrong is the sentence saying it has one.

**Why it was not fixed when found.** The unit that found it was scoped to
`core/scripts/verify-freestanding.sh` and the three `declare -A` harnesses, and was explicitly told to
touch only those. `m19-argv` belongs to the milestone that just landed. The fix is small — copy
`m18-preempt`'s five-line block and re-run the harness (~290 s) — but it is another agent's harness
and another milestone's exit criterion, so it is escalated rather than taken.

---

**How it was fixed (2026-08-26).** A new `Step 3b` in `m19-argv/run.sh`, placed between the
`build-progs` checks and the volume, modelled on `m18-preempt` §3h and matching its style. It does
five things, not one:

1. Runs `scripts/verify-freestanding.sh` on `build/kmain.o`, `build/kdata.o` and `build/kernel.elf`,
   capturing combined output.
2. **Checks the exit status** (`VERIFY_STATUS`), which is the part the gap was really about.
3. Belt-and-braces as `m8-paging` and `m13-libc` do it: fails if a `FREESTANDING: FAIL` line was
   printed while the script exited 0.
4. Requires **exactly three** `FREESTANDING: pass` lines — the status alone would be satisfied by a
   script that printed nothing at all, which is the vacuity this whole batch is about.
5. Pins the declared-extern count at **44**, unchanged from M18. M19 builds the initial process stack
   in Dart and enters ring 3 through the `enter_user` stub that already existed; a new assembly
   primitive would be a different design, and this is where that would show up.

The PASS line no longer asserts the bare word. It now reads `-> verify-freestanding pass on kmain.o,
kdata.o and kernel.elf (44 declared externs, unchanged from M18 — M19 added no assembly) ->`, so the
sentence carries a number that came out of the check rather than a claim that the check happened.

Occurrences of the string in the file went from **1 to 8**. `m19-argv` was re-run in full under
`/bin/bash` 3.2.57 and passes with the check executing: four `FREESTANDING:` lines now appear in its
log where there were none.

**What this was and was not.** It was a missing assertion plus a false sentence. It was **not** an
unguarded kernel: rule 1 was enforced on these same objects by seven other harnesses throughout, and
the extern count the new check pins is the value those harnesses were already asserting.

---

## GAP-0168 — the conformance suite has no mechanism that a PASS line only prints if its assertions ran

**Domain:** tooling, conformance harnesses (opened by ADR-0030, successor to GAP-0156)
**Status:** **CLOSED 2026-08-26 by ADR-0032.** Both mechanisms are built and both are shown failing
on the inputs they exist to reject. What is left over is GAP-0176 (nothing runs the controls
automatically) — see "What landed" at the end of this entry. The design discussion below is kept as
written, because ADR-0032 corrects three parts of it and a correction needs its original.

GAP-0156 asked for `set -e`. ADR-0030 surveyed all twenty harnesses, found **0 of 20** convertible
(134 capture-then-`$?` sites, 86 bare predicates, 89 `grep -q ... && fail`), and concluded that `set
-e` is the wrong instrument regardless — **it does not catch GAP-0156's own motivating example.** A
`declare -A` that silently collapses to index 0 under bash 3.2 produces no non-zero exit status
anywhere: every assignment succeeds, every lookup returns the same wrong value, and the harness
compares wrong values against wrong values and prints PASS.

**The property that actually wants protecting** is not "no command failed" but **"the assertions this
PASS line describes actually executed."** Two mechanisms address it directly, and both also cover the
silent-wrong-value case above:

1. **An assertion-count floor.** A `checked()`/`pass()` helper increments a counter; immediately
   before the PASS line, `(( ASSERTIONS >= <pinned N> )) || fail "only $ASSERTIONS of N assertions
   ran"`. One site per harness instead of 134. Catches an abort, a `for` that iterated zero times, a
   `case` that fell through, and a guard edited into unreachability — the whole GAP-0155 / GAP-0156
   family. The cost is honest and should be stated when it is done: the pinned N is a golden that
   moves whenever a harness legitimately gains or loses an assertion, exactly like `shellStrHelp`'s
   size, and it must be derived from a count the harness itself emits rather than hand-maintained.
2. **A `capture()` helper** replacing capture-then-`$?`, preserving output *and* status:
   `capture OUT STATUS -- bash scripts/verify-freestanding.sh build/kmain.o`. This is what would have
   to be written anyway before `set -e` could ever be safe, and it is a readability gain on its own
   merits. 134 sites, mechanical, no semantic change.

**Why not done in the opening commit.** Touching twenty harnesses costs a ~27-minute full re-run per
iteration, and the counter discipline is a choice the implementer should make with ADR-0030 in front
of them rather than inherit silently. The unit that opened this had already spent its re-run budget on
GAP-0167's fix and the executable-bit change.

**Ordering note for whoever takes it.** Do (2) first and independently — it is mechanical, it is
verifiable one harness at a time, and it strictly improves diagnostics whether or not (1) ever lands.
(1) needs a decision about where N comes from before any code is written.

---

### What landed (2026-08-26, ADR-0032)

`core/tests/conformance/_lib/harness.sh` — sourced by all twenty harnesses, bash-3.2 clean.

| | |
|---|---|
| `ck` sites inserted | **1191**, across 20/20 harnesses |
| checks actually executed, whole suite | **2783** — the counts are emergent, not static: `m5-pci` has 74 `ck` sites in its text and runs **133** checks |
| pinned floors | 9 (`m0-boot`) … 268 (`m16-filewrite`) |
| capture-then-`$?` sites converted | **88** — 17 `capture`, 17 `capture_log`, 20 `capture_sh`, 17 `run_status`, 17 `await` |
| `$?` reads remaining | **1** (`m5-pci`, a heredoc-fed `python3`; ADR-0032 §6) |

**Three corrections to the design above, all in ADR-0032:**

1. **There are 86 class-A sites, not 134/135.** See the UPDATE at the top of GAP-0156.
2. **One `capture()` was not enough.** 15 of the 86 subjects are compound commands (`cd X && bash y`)
   or carry an assignment prefix (`OSCORTEX_ALLOWLIST=… bash …`), neither of which survives being
   passed as argv words. A single mechanical `capture` would have run only the `cd` under capture, or
   tried to exec a program named `OSCORTEX_ALLOWLIST=/path` — i.e. it would have turned
   `verify-freestanding.sh` into a check that never ran, **reintroducing GAP-0167 as the fix for it**.
   Five helpers, split so the eval path is a different word at the call site.
3. **The instrumenter's first version manufactured the very defect this gap is about.** `ck` is a
   command, so it sets `$?`; prefixing it to `if [[ $? -ne 0 ]]` made three real checks read `ck`'s
   status instead of the command's — checks that could never fail, still passing, count still rising.
   Caught by reading the generated diff, not by any test. The rule is now mechanical (the counter
   never goes between a command and a read of `$?`) and ADR-0032 §4.2 records it rather than tidying
   it away, because it is the sharpest available demonstration that a green run says nothing about
   whether the check under it is real.

**Observed behaviour of the controls** (`_lib/controls/run.sh`, 14 controls, ~1s, both interpreters —
`bash` 5.3.15 and `/bin/bash` 3.2.57 — all as specified), plus three run against the REAL `m0-boot`:

| Control | Observed |
|---|---|
| assertions deliberately skipped (a `for` over an empty list; no command fails) | `exit 1`, `only 2 of the 6 declared checks executed` |
| floor exceeds what ran | `exit 1`, `only 3 of the 99 declared checks executed` |
| a `capture`d command fails, `set -e` ON | `exit 1`, `the build exited 42: the compiler said no` — status named, stderr kept |
| the same fixture with the OLD `OUT=$(cmd); STATUS=$?`, `set -e` ON | `exit 42`, **0 bytes of output**, no FAIL line — the contrast that makes the row above mean something |
| zero floor / non-numeric floor / sourcing before `fail()` is defined | refused: `exit 1`, `1`, `2` |
| **real `m0-boot`, floor 9 → 99** | `exit 1`, `only 9 of the 99 declared checks executed` |
| **real `m0-boot`, Step 2's freestanding block wrapped in `if false`** | `exit 1`, `only 6 of the 9 declared checks executed` — this is GAP-0167's exact defect (the PASS line says `verify-freestanding pass` while the check does not run), caught |
| **real `m0-boot`, unmodified** | `exit 0`, `ASSERTIONS: pass  9 checks executed, declared floor 9` |

**What is left over:** GAP-0176 — nothing runs the controls automatically, so the guard on twenty
harnesses is itself unguarded.

---

## GAP-0169 — `libdrm` compiles for this OS and cannot be linked: 43 symbols, and here they are

**Status: CLOSED by ADR-0033. The 43 are 0.** `libdrm`'s five core objects now link completely
against `core/user/libc` plus the two files ADR-0033 added — `posix.c` (the opt-in POSIX face and
the twenty tier-2 loud stubs) and `port.c` (the tier-1 C functions). **`main` is the only undefined
symbol left**, which is what "a library" means.

`expected-missing-core.txt` is now empty and the harness diffs against it on every run, so the
anti-vacuity moved with it: CHECK 2b requires the LINK to succeed and requires `main` to be
undefined, which an empty object set could not satisfy.

**`modetest` went 76 → 32**, and the 32 that remain are exactly the expensive set
`design/libdrm-port.md` §7.2 predicted: `pthread_create`/`pthread_join`, `poll`, `select`, libm
(`fabs`, `roundf`), `getopt`, `strtod`/`strtof`, `gettimeofday`, `usleep`. **That prediction was
made before any of this was built and it was exactly right.** GAP-0173 is unchanged.

*The original entry follows.*

**Domain:** userland, libc, ports (ADR-0031)
**Status:** OPEN — **and it is now a list rather than an estimate.** The list is checked into the repo
and diffed on every run of `tests/conformance/drm-abi/run.sh`.

`drm-abi.md` §8.3 recommended `libdrm` as the first C library this OS is pointed at and marked its own
size claim ⚠ *"(not measured — V0 measures it)"*. It is measured now, and V0 was not needed:

```
core/user/ports/libdrm/build.sh <libdrm> <out>
  → 5 objects, 7,801 lines, UNMODIFIED source, x86_64-unknown-none-elf: COMPILES
  → 53 external symbols, 10 defined by core/user/libc (47 exported), 43 MISSING
core/user/ports/libdrm/build.sh <libdrm> <out> --with-modetest
  → 11 objects, 13,433 lines: 88 external, 76 MISSING
```

**The 43** (`core/user/ports/libdrm/expected-missing-core.txt`):

```
FD_ISSET* FD_SET* FD_ZERO*  — modetest only, listed with the 76
__errno_location  access  asprintf  calloc  chmod  chown  clock_gettime
closedir  fclose  fopen  fprintf  fstat  getenv  geteuid  getpagesize
ioctl  major  makedev  memcmp  memmove  minor  mkdir  mknod  mmap  munmap
open_memstream  opendir  qsort  readdir  realloc  remove  snprintf  sprintf
sscanf  stat  stderr  strcasecmp  strdup  strerror  strncasecmp  strncmp
strncpy  strstr  vfprintf
```

**`design/libdrm-port.md` §2 tiers them** into 16 that must actually *work* for an R0–R3 client and 20
that must merely *link* because they sit on `drmOpenDevice`'s X-server path or on sysfs walking that
is dead here anyway (§6 / GAP-0171). **That distinction is the useful part of this entry**: a first
link can satisfy 20 of them with stubs that abort loudly.

**The cost of leaving it open:** `libdrm` cannot be linked into a program, so no DRM ioctl can be
issued through it, so R0 (`DRM_IOCTL_VERSION` answers) cannot be reached even after `ioctl` exists.
The two are independent: `ioctl` is GAP-0158 and is kernel work; this is `libc-roadmap.md` tier A–C
work and is userland.

**What it does NOT need, and this is the good news:** no threads, no TLS, no futexes, no dynamic
linking, no C++ runtime, no libm. See GAP-0173 for what does.

---

## GAP-0170 — four libc symbols bind by name and are the wrong function, and the link is clean

**Domain:** userland, libc (ADR-0031 §2.1)
**Status:** **CLOSED by ADR-0033**, and CHECK 2 now asserts the OPPOSITE of what it used to: linking
libdrm against `core/user/libc`'s NATIVE objects alone must leave `open`, `read`, `close` and
`printf` **undefined**, and the check fails if any of them ever binds again.

**The fix.** The native surface exports `os_open`, `os_read`, `os_close`, `os_printf` and
`os_write`; `oslibc.h` keeps the short spellings for its own callers as `#define`s stated in the
header. A program that includes `oslibc.h` is unchanged to the character. A port — which includes
`<fcntl.h>` and `<unistd.h>`, not `oslibc.h` — gets an undefined reference and cannot link. **A
mismatch that used to link silently is now a link error.**

**The `errno` question this entry called "a decision, not a patch" is decided:** `core/user/libc/
posix.c` is a separate, opt-in translation unit, it is the only place `errno` exists on this
operating system, and nothing in `core/kernel/` learned the word. `drmIoctl`'s retry loop is
**provably one-shot** rather than emulated: no oscortex refusal maps to `EINTR` or `EAGAIN`,
because there are no signals and nothing blocks. GAP-0179 records what makes that false later.
ADR-0033 §2.5 states the four alternatives that were rejected.

**A FIFTH SYMBOL, AND THE COMPILER FOUND IT.** This entry named four. When `posix.c` tried to define
POSIX's `ssize_t write(int, const void *, size_t)`, clang refused it against oscortex's
two-argument `unsigned long write(const void *, size_t)` — *"conflicting types for `write`"*. The
clash was not merely latent, it **blocked the adapter**. `write` is `os_write` now. `exit` and
`sbrk` are a sixth and seventh, are not reached by libdrm, and are measured in GAP-0178 rather than
changed.

*The original entry follows.*

Of the 53 symbols libdrm needs, `core/user/libc` defines ten: `open close read printf malloc free
memcpy memset strcmp strlen`. **Six are the right function. Four are not.**

| | `core/user/libc` | what libdrm means |
|---|---|---|
| `open` | `unsigned long open(const char *name)` — **one argument**, an 8.3 name in the FAT16 **root directory**, refusal at or above `FILE_ERR_FLOOR` | `open(path, O_RDWR\|O_CLOEXEC)` / `open(path, O_RDWR, 0)` — a path, 2–3 arguments, `-1` + `errno` |
| `read` | `unsigned long read(unsigned long, void *, size_t)`, refusal floor, `READ_MAX` 512 | `ssize_t read(int, void *, size_t)`, `-1` on failure |
| `close` | `unsigned long close(unsigned long)` | `int close(int)` |
| `printf` | five conversions, 120-byte cap, one call is one line on the console | pulled in transitively; libdrm's real diagnostic path is `vfprintf(stderr, …)`, which does not exist here at all |

**`x86_64-elf-ld` resolves all four without a word.** Measured: linking libdrm's five objects against
`core/user/libc`'s six leaves exactly the 43 undefined, plus `main`, and **not** these four.

**And the near-miss is what would make it hard to find.** `core/user/libc`'s refusals are
`0xFFFFFFFFFFFFFFF9` and friends, which *as an `int`* are small negative numbers — so libdrm's
`if (fd < 0)` would appear to work. What would not work is everything after: a successful `open`
returns 0..3, the `O_RDWR` argument is silently discarded, and `drmOpenDevice("/dev/dri/card0", …)`
would try to open a FAT16 file whose name is a path.

**And there is no `errno`.** `drmIoctl`'s entire body is
`do { ret = ioctl(fd, request, arg); } while (ret == -1 && (errno == EINTR || errno == EAGAIN));`.
GAP-0113 decided against `errno` deliberately — *"the refusal IS the return value"* — and that is a
good decision this three-line function is incompatible with. `__errno_location` is in the missing 43
and it is not a formality.

**The fix is a decision, not a patch**, and ADR-0031 §9 declines to take it: either `core/user/libc`
grows a second, POSIX-shaped surface (`posix_open`, an `errno`, a `-1` convention) that ported C is
linked against, or the two are kept apart and a port supplies its own adapter. It is a
`libc-roadmap.md` decision.

---

## GAP-0171 — `libdrm` cannot enumerate a device on this OS whatever the kernel does, and fixing it means modifying libdrm

**Domain:** ports, GPU (ADR-0031 §8.2, `design/libdrm-port.md` §6)
**Status:** OPEN, and it is the first place ADR-0029's word "unmodified" needs a qualification.

`xf86drm.c` ends **eight** functions with

```c
#else
#warning "Missing implementation of drmParseSubsystemType"
    return -EINVAL;
#endif
```

— `drmParse{SubsystemType,PciBusInfo,PciDeviceInfo,UsbBusInfo,UsbDeviceInfo,OFBusInfo,OFDeviceInfo,FauxBusInfo}`.
The `#ifdef` chain above each is `__linux__` (sysfs) / the BSDs (sysctl or `DRM_IOCTL_GET_PCIINFO`) /
**nothing**. `drmGetDevices2()` and `drmGetDevice2()` are built on them, and **that is how Mesa finds a
GPU.** So those calls return `-EINVAL` before any ioctl is issued, no matter how complete this kernel's
DRM implementation is.

`tests/conformance/drm-abi/run.sh` CHECK 3 requires exactly eight of those warnings to still be
emitted, so the day libdrm gains an oscortex branch the harness notices.

**Three ways out, none free** (`libdrm-port.md` §6): upstream an `#elif defined(__oscortex__)` branch
(~30 lines, following the OpenBSD one, but a real review cycle); carry a patch (cheap now, and every
later "unmodified" claim needs a footnote); or arrange that no client ever calls it —
⚠ *`modetest -D /dev/dri/card0` and Mesa's driver-file overrides appear to bypass enumeration, but
this is inferred from reading `modetest.c` and has not been run.*

**The cost of leaving it open:** nothing until R3, and then everything. It should be decided before
R0, not discovered at R3.

---

## GAP-0172 — `drm.h` takes its BSD branch on this target, so the `_IOC` encoding is ours to choose and choosing wrong is silent

**Domain:** GPU, ABI (ADR-0031 §3)
**Status:** **RESOLVED for this port** — `core/user/ports/libdrm/shim/sys/ioccom.h` serves Linux's
encoding and `tests/conformance/drm-abi/run.sh` CHECKs 4, 5 and 11 hold it there, including a negative
control that boots. **Recorded rather than closed**, because the same trap is waiting for every other
uAPI header this project ever compiles.

`include/drm/drm.h`'s first `#if` is `defined(__linux__)`. It is false for
`x86_64-unknown-none-elf`, so the header takes its "one of the BSDs" branch and uses whatever `_IOWR`
it finds in `<sys/ioccom.h>` — **ours**. Writing BSD's real encoding there compiles cleanly, produces
byte-identical structs, and changes **29 of 121** DRM request numbers:

* the 92 `_IOWR` requests are **unaffected** (`IOC_INOUT` and `_IOC_READ|_IOC_WRITE` are both
  `0xC0000000` and the size starts at bit 16 in both schemes);
* `_IOR`/`_IOW` have their **direction bits swapped**;
* `_IO` gets `IOC_VOID` (`0x20000000`) instead of zero.

**The 29 include `GEM_CLOSE`** — one of the five core render ioctls — **`SET_CLIENT_CAP`,
`SET_MASTER` and `DROP_MASTER`.** So a ladder taking the default would have reached R3 before
anything went wrong, and then failed on the one call that frees a buffer.

`xf86drm.h` needs the same treatment and is easy to miss: its non-`__linux__` branch spells the
direction bits `IOC_VOID`/`IOC_OUT`/`IOC_IN`/`IOC_INOUT`, and `drmCommandRead`/`Write`/`WriteRead` —
**the entry point for every per-driver ioctl, i.e. all eleven virtio-gpu ones** — build their requests
through those names.

**Why not `-D__linux__=1` instead:** `xf86drm.c` has dozens of `#ifdef __linux__` blocks and they turn
on sysfs walking, `realpath`, udev and `/proc`. Claiming a Linux personality to get four bits right is
what ADR-0029 §3 rejected by name.

---

## GAP-0173 — `modetest` needs threads, `poll`, `select` and a libm, so the independently-authored conformance suite is behind the substrate

**Domain:** ports, blocking, threads (ADR-0031 §8.3, `design/libdrm-port.md` §7.2)
**Status:** OPEN, and it changes a schedule assumption `drm-abi.md` made.

`drm-abi.md` §8.3's argument for `libdrm` was partly that *"`libdrm`'s own `modetest` and `drmdevice`
tools are a conformance suite for R0–R3 written by somebody else."* Measured:

| | libdrm core | + `modetest` + `tests/util` |
|---|---:|---:|
| objects / lines | 5 / 7,801 | 11 / 13,433 |
| missing symbols | **43** | **76** |

The 33 extra include the ones that are not libc-shaped:

* **`pthread_create`, `pthread_join`** — `tests/modetest/cursor.c` animates the cursor on its own
  thread. Not a linking artefact; the feature does not work without it.
* **`poll` and `select`** — `modetest.c` waits for DRM events **both** ways, in two places.
  `blocking-and-threads.md`'s `fdwait` (syscall 11) is the primitive and is unbuilt (GAP-0141).
* **libm** — `fabs`, `roundf`. There is no libm at all.
* `getopt`/`optarg`/`optind`, `strtod`, `strtof`, `gettimeofday`, `usleep`, `getchar`, `abort`, `div`,
  `rand`/`srand`, `time`, `strpbrk`, `strtok`, `strndup`, `strchr`.

**So the honest sequencing is: `libdrm` links after a tier-C libc; `modetest` runs only after threads
and `fdwait`.** Anyone planning R0–R3 against "modetest will tell us" should plan against a program we
write, and keep `modetest` as the later acceptance test it can be.

**It also adds a second, much smaller counter-example to `blocking-and-threads.md` §4.2's "no
threads".** That conclusion rested on ffmpeg and libwayland linking mutexes without needing
concurrency; `drm-abi.md` §8.1 named Mesa as the counter-example. A 2,491-line test program is a
cheaper one, and §4.2 should name it.

---

## GAP-0174 — the DRM device must be named `/dev/dri/card0`, not `:DRI0`, and `drm-abi.md` S1 says otherwise

**Status: NARROWED by ADR-0033.** Both names are served, literally, from `fileSysOpen`, and the
placement rule this entry carried over from `display-protocol.md` §2.1 was obeyed: the branch is
after the pointer-validated bounce-buffer copy and before `fatParseAt`, never in `fatLookup`.

**What remains open is the DOCUMENT, not the code:** `design/drm-abi.md` S1 still proposes `:DRI0`
and still needs correcting. And `drmOpenByName` additionally `stat`s the node and compares
`major()`/`minor()` against `DRM_MAJOR` 226 — `major`/`minor`/`makedev` are implemented in
`posix.c` and compute Linux's encoding correctly, but **`stat` is a loud stub** (GAP-0180), so
nothing can produce a `dev_t` for them to decode. That is the remaining half of this entry.

*The original entry follows.*

**Domain:** namespace, GPU (ADR-0031 §6)
**Status:** OPEN — the device namespace does not exist at all (GAP-0158). This entry corrects the
*design* before it is built.

`drm-abi.md` S1 proposed `open(":DRI0")` and `open(":DRIR0")`, using the `:` sigil that
`fatNameByteBad` already forbids in disk names, and marked it ⚠ *"whether Mesa can be told those names
… is the second thing V0 must check."*

**Checked. It cannot.** `xf86drm.h` hardcodes `DRM_DIR_NAME "/dev/dri"`, `DRM_DEV_NAME "%s/card%d"`
and `DRM_RENDER_DEV_NAME "%s/renderD%d"`; `drmOpenByName` builds the path with `sprintf`, hands it to
`open`, then `stat`s it and compares `major()`/`minor()` against `DRM_MAJOR` 226. Telling libdrm a name
of our own means **editing libdrm**, which is the one thing the port exists not to do.

**So the namespace serves the literal strings `/dev/dri/card0` and `/dev/dri/renderD128`.** S1's
disjointness argument survives unchanged: `fatNameByteBad` forbids `/` in an 8.3 name exactly as it
forbids `:`, so `/` is as good a sigil and it is the one libdrm already emits. **S1's placement rule
is unchanged and is the important half** — the branch goes in `fileSysOpen`, after the
pointer-validated bounce-buffer copy and before `fatParseAt`, **not in `fatLookup`**, where
`display-protocol.md` §2.1 caught a ring-3-reachable volume corruption.

**Still unresolved by this entry:** `stat` on a device node, and a `major`/`minor` scheme, are both in
GAP-0169's missing 43 and both would have to answer 226 for `drmOpenByName` to accept the node.

---

## GAP-0175 — the descriptor generator exists only as a name table, because nothing consumes a descriptor yet

**Domain:** GPU, reflection (ADR-0031 §7, `drm-abi.md` §4.2, DCDart escalation 0004 §6)
**Status:** OPEN — partially addressed, and the part that is built is the cheap half.

`drm-abi.md` §4.2 proposed a build-time generator that reads the uAPI headers and emits, per request:
name, direction, payload size, and the field list (name, offset, width, signedness) — for the
dispatcher to validate against and for a `drm trace` command to print by field name. It is this
project's concrete answer to escalation 0004 §6's "describe the boundary", and `drm-abi.md` Q6 warned
it *"gets expensive to retrofit once several ioctls are served by hand."*

**Built:** `tests/conformance/drm-abi/gen-table.py` — the *name* half. It reads `drm.h` and
`virtgpu_drm.h` and emits one entry per request. **It emits names and never numbers**, on purpose:
a generator that parsed `_IOWR(...)` and did the `_IOC` arithmetic itself would be a second
implementation of the encoding, and a harness whose expectation is its own second implementation
proves nothing.

**Not built:** the field list, the offsets, the widths, the reserved-must-be-zero fields, and the
`drm trace` command. Nothing consumes them, because the dispatcher they would validate does not exist
(GAP-0158).

**And GAP-0172's version-skew finding adds a requirement §4.2 did not have.** A descriptor cannot
carry *one* size per request: `struct drm_syncobj_handle` grew a `__u64` after Linux 6.12, so
`DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD` is `0xc018…` in libdrm 2.4.134 and `0xc010…` in 6.12. The descriptor
has to carry the **set** of sizes the kernel will accept, plus a policy for a short one. Linux's policy
is to zero-extend. **Ours should be to refuse until a request is deliberately given a second legal
size**, because zero-extending by default is how a caller's uninitialised field silently becomes a
kernel default nobody chose.

**Nobody should open a DCDart escalation for this.** It is a build-time table generator in this repo —
the same category as `derive.py` and `check-font.py` — and CLAUDE.md rule 3 applies in the negative.
The DCDart-side question that *is* real is escalation 0004 §6's own, and GAP-0166 records it.

---

## GAP-0176 — nothing runs the harness-library controls, or ADR-0028's freestanding controls, automatically

**Domain:** tooling, conformance harnesses (ADR-0032, sibling of the same complaint in GAP-0155)
**Status:** OPEN — newly opened by the unit that built the controls, because the controls are exactly
the kind of thing that rots unrun.

`core/tests/conformance/_lib/controls/run.sh` proves that the assertion-count floor and the
`capture()` family actually bite: 14 controls, ~1 second, no QEMU, no kernel build. ADR-0028's three
freestanding controls prove the same thing about `verify-freestanding.sh` under `/bin/bash` 3.2.
**Neither set is invoked by anything.** No sweep runs them, no harness sources them, and the twenty
milestone harnesses will stay green if `require_assertions` is edited into a no-op tomorrow.

This is the identical shape to the note already at the bottom of GAP-0155 — *"Nothing enforces the
bash-3.2 rule. The three rules are documented in the script's header ... but no check fails if someone
reintroduces `mapfile`"* — and it deserves the same standing rather than being folded in, because it
is now about two independent control sets and about the mechanism that guards every other harness.

**What would close it.** A `core/tests/conformance/run-all.sh` (which this repo does not have — every
sweep so far has been an ad-hoc shell loop typed by an agent) whose FIRST step is:

```sh
/bin/bash core/tests/conformance/_lib/controls/run.sh   || exit 1   # 3.2.57, deliberately
bash      core/tests/conformance/_lib/controls/run.sh   || exit 1   # brew's 5.x
```

Both interpreters, explicitly, for ADR-0028's reason: `env bash` finds brew's bash 5 and proves
nothing about the bash macOS actually ships. Roughly two seconds on the front of a 28-minute sweep.

**The cost of leaving it open, stated plainly.** The guard on twenty harnesses is itself unguarded.
Someone can weaken `_lib/harness.sh` — lower a floor, make `ck` a no-op, make `capture` swallow a
status — and every one of the twenty will still print PASS, which is precisely the defect family
GAP-0168 was opened to end. The controls exist and are known-good as of this commit (all 14 observed
passing under both interpreters); what is missing is anything that will notice when they stop being.

**Why it was not closed in the same unit.** Writing `run-all.sh` means deciding the sweep's contract —
ordering, `--regen`, whether a setup_error (exit 2) is a failure, what to do about `m12-heap`'s
flakiness (GAP-0161) and `m9-ring3`'s (GAP-0157) — and that is a separate decision from "does the
guard work", which is what this unit was asked to establish. Doing it here would have meant
inheriting those choices silently, which is the thing ADR-0030 §4 explicitly warned the next author
about.

---

## GAP-0177 — `ioctl` works and there is no DRM: the membrane is built, the driver behind it is a pattern generator, and the descriptor table is six hand-written rows

**Domain:** kernel, ABI, GPU (ADR-0033 §5)
**Status:** OPEN, and it is the honest boundary of what ADR-0033 claims.

**`ioctl` is syscall 12 and it works. NO DRM SEMANTICS ARE IMPLEMENTED.** `ioctlDevServe` — the
"driver" — fills the read-side payload with `(descIndex << 4 | devIndex) ^ byteIndex` and returns 0.
That is a deterministic pattern the harness predicts from outside the kernel, and it is there to
prove the bounce and the direction handling, not to be a GPU. `DRM_IOCTL_VERSION` does not return a
driver name; `GEM_CLOSE` closes nothing; `SET_MASTER` masters nothing.

**What genuinely works is the membrane**, and it is the rung `design/drm-abi.md` S0 asked for:
decode, validate, bounce, dispatch on `_IOC_NR`, refuse on skew, out-copy only on success. Every
future driver inherits that shape, including the signature that makes it impossible for one to hold
a ring-3 pointer.

**The descriptor table is SIX ROWS AND HAND-WRITTEN**, and this entry is also the argument for
finally building `design/drm-abi.md` §4.2's generator (GAP-0175, still open). The six are `VERSION`,
`GET_MAGIC`, `GEM_CLOSE`, `GET_CAP`, `SET_MASTER` and `SYNCOBJ_HANDLE_TO_FD` — chosen to exercise
every direction, the no-payload case, and the two-legal-sizes case. There are **121** requests.

**AND SIX ROWS PRODUCED ONE WRONG NUMBER.** `struct drm_auth` is **4** bytes on the branch `drm.h`
takes here, so `DRM_IOCTL_GET_MAGIC` is `0x80046402`. This table said **8** — a plausible guess,
because `drm_handle_t` genuinely IS `unsigned long` on that same branch (ADR-0031 §3), so "the BSD
branch widens things" is a real pattern that does not apply to this struct. It was caught only
because the value was read out of a compiled object before being trusted. **Six rows, one error, by
an author who had just finished reading the encoding ADR. 121 rows by hand is not a plan.**

**Cost of the workaround:** every request the kernel is asked to serve needs a row, and each row is
a chance to transcribe a size wrongly in a way that is invisible until a client sends that request.

---

## GAP-0178 — `exit` and `sbrk` still collide with POSIX by name, and the collision class is now measured rather than guessed

**Domain:** userland, libc (ADR-0033 §2.3)
**Status:** OPEN, deliberately, and scoped rather than fixed.

ADR-0033 renamed five symbols to `os_*` — the four of GAP-0170 plus `write`, which clang found by
refusing to compile `posix.c` against it. **Two more collide and were left alone:**

| symbol | ours | POSIX's | why it was left |
|---|---|---|---|
| `exit` | `void exit(unsigned long status)` | `void exit(int)` | A port's `exit(1)` converts and behaves correctly. The hazard is real but benign |
| `sbrk` | `void *sbrk(size_t)`, **NULL** on failure | `void *sbrk(intptr_t)`, **`(void *)-1`** on failure | A port testing `== (void *)-1` **misses an out-of-memory and proceeds**. This is the sharper of the two |

**Neither is reached by libdrm and neither blocks `posix.c`**, which is why this unit stopped here.
`sbrk`'s is the one to fix first if a port ever calls it: NULL-instead-of-`MAP_FAILED` is the same
shape of error as GAP-0170's, one layer down.

**The general rule this suggests, which nothing enforces yet:** every symbol `core/user/libc`
exports under a name that also exists in POSIX is a candidate for this failure, and the only two
things standing between us and it are (a) that ports mostly do not call them and (b) that somebody
looks. A check that enumerated `oslibc.h`'s exports against a list of POSIX names would be cheap and
does not exist.

---

## GAP-0179 — `drmIoctl`'s retry loop is provably one-shot, and the proof expires the day this OS grows signals or non-blocking descriptors

**Domain:** userland, libc, ABI (ADR-0033 §2.4)
**Status:** OPEN as a **tripwire**, not as a defect. Nothing is wrong today.

`drmIoctl`'s entire body is
`do { ret = ioctl(...); } while (ret == -1 && (errno == EINTR || errno == EAGAIN));`.

`posix_errno_for` maps **no** oscortex refusal onto `EINTR` or `EAGAIN`, and that is not an
omission: there are no signals on this operating system (no delivery mechanism exists at all) and
no descriptor is non-blocking (nothing blocks). So the `while` condition is false on its first
evaluation, always, and the loop runs its body exactly once — the loop doing precisely what it was
written to do on a platform where the conditions it retries on cannot arise.

**WHAT MAKES THIS FALSE.** `fdwait` (syscall 11, GAP-0141) is the blocking primitive three designs
name. The day it exists, or the day anything delivers a signal, a refusal that *should* map to
`EAGAIN` will appear — and if `posix_errno_for` is not updated in the same unit, `drmIoctl` will
return an error where it should have retried. If it IS updated but nothing sets the condition that
ends the retry, `drmIoctl` spins forever.

**A retry loop that silently starts spinning is worse than one that never did**, which is why this
is a gap entry and not a comment. Whoever builds `fdwait` should read this one.

---

## GAP-0180 — three of the sixteen "must work" libdrm symbols are loud stubs, because the kernel has nothing behind them

**Domain:** userland, libc, kernel (ADR-0033, `design/libdrm-port.md` §2)
**Status:** OPEN, and this is the one place ADR-0033 does not meet libdrm-port.md §2's bar.

`design/libdrm-port.md` §2 tiers sixteen symbols as **must WORK**. Thirteen do. **Three are stubs
that refuse loudly**, and each is blocked on kernel work rather than on libc work:

| symbol | reached from | what it needs |
|---|---|---|
| `stat` / `fstat` | `drmGetNodeTypeFromFd`, `drmGetDevice2` | **A `stat` syscall and a `dev_t` scheme.** Neither exists. `drmOpenByName` compares `major()`/`minor()` against `DRM_MAJOR` 226 — and `major`/`minor`/`makedev` ARE implemented and correct, so the arithmetic is ready and there is nothing to feed it |
| `clock_gettime(CLOCK_MONOTONIC)` | `drmWaitVBlank` | **A time syscall.** `tick_count` is the kernel's and no syscall reads it. GAP-0164 |

**They are stubbed rather than faked, and the distinction is the whole entry.** Inventing 226:0 in
`fstat` would make `drmGetNodeTypeFromFd` return `DRM_NODE_PRIMARY` on the strength of a number this
OS made up, and the first thing that number would do is be believed. A stub that refuses is a
missing feature; a stub that returns a plausible value is a wrong answer, which is GAP-0170's whole
lesson applied one layer up.

**Every tier-2 stub is in `posix.c` and every one of them COUNTS ITSELF.** `posix_stub_calls()` and
`posix_stub_last()` are exported so that *"nothing on the R0–R3 path called a stub"* is a claim a
program can assert rather than one this repo makes. The twenty are: `mknod`, `chmod`, `chown`,
`mkdir`, `remove`, `access`, `opendir`, `readdir`, `closedir`, `fopen`, `fclose`, `sscanf`,
`fprintf`, `vfprintf`, `open_memstream`, `asprintf`, `strcasecmp`, `strncasecmp`, `mmap`, `munmap`.

**Two things in that list are NOT stubs and are correct:** `geteuid` returns a non-zero uid (true —
there are no users, so nobody is root — and it is also the answer that keeps libdrm off the
device-node-creation path), and `getenv` returns NULL (true: GAP-0146, there is no environment, so
every variable really is unset). Neither counts itself, because nothing went wrong.

**Also a real difference from POSIX, recorded here so a port author meets it:** `posix.c`'s `open`
honours the access mode and ignores every other flag. `O_CREAT`/`O_TRUNC`/`O_APPEND` are *subsumed*
— oscortex's `O_WRITE` already means all three (ADR-0020 §0, GAP-0127) — so a caller who did not ask
for truncation gets it anyway. `O_RDWR` on a **device** maps to `O_READ` and is honest, because
`ioctl` is the write path; `O_RDWR` on a **file** is not serveable and is refused rather than
silently downgraded.

---

## GAP-0181 — `O_CLOEXEC` is ignored, correctly, and will stop being correct the day `exec` exists

**Domain:** userland, libc
**Status:** OPEN as a tripwire. Nothing is wrong today.

`posix.c`'s `open` ignores `O_CLOEXEC`. libdrm passes it on every device open
(`open(path, O_RDWR | O_CLOEXEC)`). **Ignoring it is correct right now** because there is no `exec`
on this operating system, so there is no descriptor-inheritance event for the flag to control.

The day something like `exec` appears, this becomes a descriptor leak across it — and it will be
silent, because the flag was accepted. Same shape as GAP-0179: a promise that is vacuously kept
until the thing it promises about exists.

---

## GAP-0182 — `realloc` always copies and `qsort` is insertion sort, and both are stack-driven choices

**Domain:** userland, libc (`core/user/libc/port.c`)
**Status:** OPEN, with the complexity stated so that neither is a mystery later.

**`realloc` cannot grow in place.** `malloc.c` is a first-fit free list, and even with
`malloc_usable` (added by ADR-0033 so `realloc` could copy a safe length rather than over-reading
the old block) there is no "is the next block free" query. So every `realloc` is
malloc + copy + free. libdrm calls it from `drmModeAtomicAddProperty`, which grows by a page's worth
of items at a time, so the copies are O(log n) in the number of properties — acceptable, and not a
general guarantee.

**AND ADDING `malloc_usable` GREW EVERY PROGRAM ON THE VOLUME BY 48 BYTES.** Worth recording
because it is the kind of number that is baffling later: the function is **19 bytes of code**, and
with 16-byte function alignment and its symbol-table entry each linked program grew **0x30**. That is
not free — `m14-fat`'s test program crossed a cluster boundary because of it, so `FS CHAIN LEN` went
`000A → 000B` and a third cluster appeared in `FS CLUS`. Nothing is wrong; it is what adding a
function to `malloc.c` costs when the link has no `--gc-sections`. **The trade is clearly worth it:**
without `malloc_usable`, `realloc` has no safe copy length and over-reads the old block on every
growing call, silently, on a heap with no guard pages.

**`qsort` is insertion sort, O(n²), and that is a deliberate trade against the stack.** Real qsort
is quicksort with O(log n) recursion depth; **this OS gives a program ONE PAGE of stack** (ADR-0013)
and there is no guard page below it, so a recursive sort on a pathological input overflows silently.
libdrm's atomic property list is tens of items. **The day something sorts a large array this is the
entry to read**, and the fix is heapsort — O(n log n) with O(1) stack — not quicksort.

---

## GAP-0183 — one `printf` is still one console line, so a POSIX `printf` cannot honour `\n`, and no userland change can fix it

**Domain:** userland, libc, kernel console
**Status:** OPEN. It is a kernel-interface property, not a libc bug.

`posix.c` provides a real POSIX `printf` — port.c's full conversion set, C's return value, and no
120-byte cap, because the output is chunked across as many `write` syscalls as it takes.

**What it cannot do is line semantics.** `userSysWrite` prints `USER WRITE `, the caller's bytes,
**and a newline of its own**. So every chunk becomes its own console line, an embedded `\n` produces
nothing where a newline should be and a line break where one should not, and a program that builds
output incrementally cannot.

**No userland change fixes this**, which is why it is recorded rather than worked around: the
newline and the `USER WRITE ` prefix are the kernel's, added inside syscall 1. Fixing it means a
console syscall that does not frame what it is given — which is a real interface change, affects
every golden in the repo, and was correctly out of scope for a unit about `ioctl`.

---

## GAP-0200 — There is no blocking receive; an IPC receiver polls

**Domain:** kernel, IPC (M20)
**Status:** OPEN — deliberate for M20, and the next thing this primitive should grow.

`chanrecv` never blocks. An empty ring is `chanRetEmpty`, handed back to ring 3 as a value, and a
receiver that wants to wait must call again. `m20-ipc`'s responder does exactly that, with a `yield`
between attempts.

**Why it is deliberate.** A blocking receive needs a wait queue, a `blocked` process state and a wakeup
path on the send side — real surgery on `core/kernel/proc.dart`, and the reason ADR-0027 chose a
bounded queue in the first place was that it needs *no new scheduler state at all*. Shipping the
primitive without it makes the primitive testable now; shipping the scheduler change with it would have
made the scheduler the thing under test.

**What it costs, precisely.** Under M18's preemptive policy a polling receiver burns its whole quantum
doing nothing and is then switched away, so a compositor that had no work would consume a full share of
the CPU. Under `proc coop` — which is what `m20-ipc` uses — it costs nothing, because the poll loop
yields. So the cost is invisible in the harness and real in production, which is why it is written here.

**What closing it takes.** Everything a `chanwait` needs is already in the ring's state: `head == tail`
per direction is the wait condition, and `chanSysSend` already knows the moment it stops being true.
What is missing is `procStateBlocked`, a per-slot "blocked on endpoint N direction D" pair of words, a
`procPickNext` that skips blocked slots, and a wake in `chanSysSend`. Roughly one screen of code in each
of two files, plus the deadlock question: if every process is blocked, the session has to end rather
than hang, which is `procBudgetEnd`'s existing shape.

---

## GAP-0201 — A message cannot convey authority

**Domain:** kernel, IPC (M20)
**Status:** **CLOSED at M21 (ADR-0041)** — and closed the way this entry recommended, which is worth
saying because the recommendation was the load-bearing part.

**What was built.** `shmgrant(ep, h)` is the fourth syscall this entry proposed: the kernel
interprets it, installs a READ-ONLY capability in the peer's own capability table, and returns the
handle THAT process will use. The message stayed opaque — `chan.dart` is unchanged apart from one
read-only accessor, `chanPeerId`, which names the peer and touches no ring. So "a message is bytes and
cannot convey authority" is **still true**, and it is now true *and sufficient*: the descriptor
carries the NAME, the grant carried the AUTHORITY, and a forged name reaches nothing because a handle
is an index into the caller's own table (ADR-0041 §4).

The alternative this entry named — messages growing a typed header the kernel parses — was not taken,
for the reason given here: it would have made `chan.dart` interpret its payload, and every argument in
ADR-0027 §2.3 for the ring being opaque would have had to be re-made.

Verified by `tests/conformance/m21-shmem/run.sh`, which sends a 64-byte frame descriptor down the
channel and requires the receiving process to map the region it names and hash all 16384 bytes of it.

*(Historical: the original text follows.)*

**Domain:** kernel, IPC (M20)
**Status:** was OPEN — the boundary of M20, and a prerequisite for the shared-frame milestone.

A message is 64 opaque bytes. The kernel copies them and looks at none, so a message **cannot carry a
capability, a handle, an endpoint, or a page**. Two processes that share a channel can say things to
each other; they cannot give each other anything.

**Why that matters for the very next milestone.** ADR-0027 §2 is explicit that bulk data must travel by
reference: a message names a shared region rather than containing it. But "names" is doing work there —
a region handle in a message is only meaningful if the kernel can be told *this endpoint's peer may map
region R*, and today it cannot, because the kernel does not read messages.

**What closing it takes, and the decision it forces.** Either the region grant is a fourth syscall
(`changrant(ep, region)`) that the kernel *does* interpret, and the message stays opaque; or messages
grow a typed header the kernel parses. The first keeps `chan.dart` as simple as it is and is the
recommendation. Whichever, it is the shared-region ADR's decision, not this one's.

---

## GAP-0202 — Ports are integers agreed by convention, not names

**Domain:** kernel, IPC (M20)
**Status:** OPEN — acceptable at two ports, not acceptable at twenty.

`chanopen(port)` takes a small integer below `chanPorts`, and the two peers have to already agree on
which one. There is no registry, no way to publish a name, and no way to ask "which port is the
compositor listening on". `m20-ipc`'s two processes both have `PORT 0` compiled into them.

**What it costs.** A compositor and N clients need a rendezvous point that the clients did not have to
be compiled with. Today the only thing that could supply one is the shell — and `proc coop` passes no
arguments at all (GAP-0149), so it cannot even do that.

**What closing it takes.** Least work, and probably right: fold it into GAP-0149's fix, so
`proc run <name> <port>` hands the port number in `argv` and the convention is established by whoever
starts the processes rather than by whoever compiled them. A real name registry is a much larger thing
and there is no need for it yet.

---

## GAP-0203 — A channel has exactly two endpoints; there is no multicast

**Domain:** kernel, IPC (M20)
**Status:** OPEN — a scaling limit, not a correctness one.

A channel is two endpoints and two rings. A compositor with N clients needs N channels, and
`chanPorts` is 2 — which is the most that can be simultaneously open when `procMax` is 4, so it is not
currently a limit at all. It becomes one the moment either number grows.

**What it costs.** Nothing today. The table is a compile-time constant array in `@bss` and widening it
is one constant and 1280 bytes per port; the harness's structural check multiplies the regions out
against `chanPortBytes` and will keep doing so. What does *not* scale is the compositor's poll loop,
which would have to walk N endpoints — which is GAP-0200 again, from the other side.

---

## GAP-0204 — IPC requires a process; an M9 payload and an M10 `run` program cannot use it

**Domain:** kernel, IPC (M20)
**Status:** OPEN — a consequence of the ownership model, and arguably correct.

An endpoint is owned by a **process id** (`procSlotId`). Three things can be in ring 3 on this machine:
an M9 `@rodata` payload, an M10 `run <name>` program, and a process. Only the third has an id, so
`chanCallerId()` returns 0 for the other two and all three syscalls refuse them with `chanRetNoProc`.

`m20-ipc`'s second boot is that refusal happening: the **same binary** started with `run <lba>` gets
`CHAN_NOPROC` from all three calls and exits with a distinct status.

**Whether it should be closed at all.** Probably not as stated. The right fix is not to give
non-processes endpoints; it is that `run <name>` should create a process (which is GAP-0149's
neighbourhood), at which point this gap closes as a side effect and the ownership model does not have
to grow a second kind of owner. Recorded so that nobody "fixes" it the other way.

---

## GAP-0205 — The channel's correctness depends on one core and no fences

**Domain:** kernel, IPC, concurrency (M20)
**Status:** OPEN — recorded precisely, because it is the kind of assumption that is invisible until it is not.

Every function in `core/kernel/chan.dart` runs inside a syscall entered through an **interrupt gate**,
so `IF` is clear for its whole duration, and this machine has one CPU. Every read-modify-write in the
file is therefore a plain load, add and store, and the whole of `chanSysSend` is a critical section by
construction rather than by a lock.

**Atomics now exist and are deliberately not used.** DCDart grew real atomics and fences (its
ADR-0055/0056, commit `3c28e65`: `lock xaddq`, `lock cmpxchgq`, `mfence`, no `__atomic_*` libcalls).
On a single core with `IF` clear they would be pure cost, and using them would *disguise* rather than
remove the dependency this entry exists to record.

**What the design does so the dependency is small.** ADR-0027 §6 in full; in short: each ring is
single-producer/single-consumer with **no word written by two writers**, the head/tail counters are
free-running so every stale read errs in the safe direction, the publication order is written down and
asserted from the source by `m20-ipc/run.sh`, and the counters that are *not* safe are statistics that
nothing decides anything from.

**So, precisely: the single thing this file relies on that an SMP kernel would not give it is that no
fence instruction is emitted.** On the day this kernel has a second core, the change is a release fence
between the last store to a ring slot and the store that advances `head`, and an acquire fence after the
load of `head` in `chanSysRecv`. Both points are marked in the code.

**What the harness cannot show.** `m20-ipc` runs under `proc coop` on one CPU, so the interleaving is
exactly the two programs' `yield` calls. It cannot demonstrate the absence of a fence, and it does not
claim to — which is why the discipline is asserted **structurally**, by reading `chanSysSend` and
`chanSysRecv` and failing if either writes the other's index word.

---

## GAP-0206 — `chanRetCorrupt` is unreachable from ring 3, so no boot exercises it

**Domain:** kernel, IPC (M20)
**Status:** OPEN — an honest hole in an otherwise well-exercised refusal set.

`chan.dart` declares **fourteen** refusal-and-status codes above one floor. `chanRetCorrupt` is
returned when a ring's `head < tail`, a state nothing in this kernel can produce, so no boot exercises
it.

**THE NUMBER IN THIS ENTRY WAS WRONG AND IS CORRECTED HERE.** It used to say the program "provokes
**twelve** of them from ring 3 and checks each as a return value", and named `chanRetBusy` (GAP-0207)
as the only other absentee. Those are two different claims and only the first was ever true of twelve:

| | codes | which |
|---|---|---|
| provoked from ring 3 | 12 | everything except `chanRetCorrupt` (unreachable by construction) and `chanRetBusy` (GAP-0207) |
| **checked** by `m20-ipc/run.sh` | **11** | the twelve, less `chanRetNoPeer` — see below |
| checked before the shakedown | 10 | the eleven, less `chanRetNoProc`, whose behavioural half GAP-0214 abolished |

Two things went wrong at once, and they are different kinds of wrong.

* **Honest drift.** ADR-0034 made every ring-3 program a process, so nothing reachable from the shell
  can be a caller without a slot. `m20-ipc`'s CHECK 13 became structural (GAP-0214) and this entry's
  "twelve" was not decremented with it.
* **A claim that was never true.** `chanRetNoPeer` was **provoked and unasserted**. `prog.c`'s
  `spinSend` retries on exactly the two answers meaning "not yet", counts every `CHAN_NOPEER` in
  `sawNoPeer`, and prints a ` NOPEER <n> ` field — and `run.sh` never looked at that field.
  `grep -n NOPEER run.sh` returned nothing. The code fired on every run, the harness saw the number,
  and nothing compared it to anything. **A provoked-but-unchecked code has the appearance of coverage
  and none of the protection**, which is strictly worse than an honest hole, because the hole is not
  in the list of holes.

**MEASURED, on the boot that settles it.** `m20-ipc`'s transcript carries four ` NOPEER <n> ` fields
— two processes in each of two sessions — reading `01 00 01 00`, and the kernel printed exactly two
`CHAN REFUSE C 0E EP ... R FFFFFFFFFFFFFFF4` lines. So the code is REACHED, once per session, on the
requester's first send before the responder has opened its end. It belongs in the fourth row this
tier counts separately: **reached and unasserted** — not GAP-0206's "cannot happen", and not
GAP-0214's "could happen, nothing makes it happen".

**CLOSED for `chanRetNoPeer`.** `m20-ipc/run.sh` CHECK 14 now asserts three independent things: that
`prog.c`'s `CHAN_NOPEER` is read out of `chan.dart` rather than typed twice; that the KERNEL narrated
that value on the send path (`CHAN REFUSE C 0E ... R FFFFFFFFFFFFFFF4`); and that ring 3's own count
of it, summed across both processes, equals the number of lines the kernel printed. The last of those
is what a "count is non-zero" check would not have given: a program counting a *different* refusal
into the same field would fail it.

**This entry stays OPEN for `chanRetCorrupt` alone**, which is the thing it was always about.

**It is not decoration.** DCDart traps on *underflow* as well as overflow, so `head - tail` on a
corrupted pair would emit a real `ud2` and the kernel would execute an undefined instruction inside a
syscall handler because a ring index was wrong. Turning that into a counted refusal is the difference
between a diagnosis and a fault.

**What it costs.** It is untested code on a path that only runs when something else has already gone
wrong. `build-progs.sh` exempts it **by name** from the "prog.c knows every refusal chan.dart declares"
check, so adding a fourteenth refusal without teaching the program about it still fails the build —
the exemption is one symbol wide, not a hole.

**What closing it takes.** A debug syscall or shell command that corrupts a counter deliberately, which
is a shell command M20 explicitly does not add (adding one moves `shellStrHelp` and five byte-exact
goldens, GAP-0105). Worth doing when something else needs a kernel-poke command anyway.

---

## GAP-0207 — `chanRetBusy` is reachable but unexercised: `proc coop` starts exactly two processes

**Domain:** kernel, IPC, tests (M20)
**Status:** OPEN — a testing gap, not a design one, and cheap to close later.

`chanopen` returns `chanRetBusy` when a **third** process tries to open a port whose two endpoints are
already taken, or one that is half-closed. Unlike `chanRetCorrupt` (GAP-0206) this is a perfectly
reachable state — it is the ordinary "that channel is taken" answer, and it is the one a compositor
client will meet most often once there is more than one of them.

**Why no boot provokes it.** Every path into ring 3 that has a process id comes from `proc coop`,
`proc run` or `proc spin`, and all three start **exactly two** processes. There is no shell command
that starts a third, so `m20-ipc` cannot arrange for one to knock on an occupied port.

**What that costs.** The refusal's *value* is asserted (distinct, above the floor) and its *code path*
is one `if` with no arithmetic, so the risk is low. But it is asserted structurally rather than
behaviourally, and this file's whole discipline is that those are different strengths of claim.

**What closing it takes.** Either a `proc` form that starts three processes, or — better, and useful
for other reasons — the port number arriving in `argv` (GAP-0202 and GAP-0149 together), at which
point one program can be told to open a port it does not own and the existing two-process session
covers it.

---

## GAP-0208 — RESOLVED: a program could not have both argv and a heap

**Domain:** kernel (M10/M11/M19/M20)
**Status:** **RESOLVED** by `docs/decisions/0034-one-launch-path.md`, verified by
`tests/conformance/m20-launch/run.sh`.

This entry records a defect that was closed, because it was invisible in every green suite and the
shape of how it hid is worth keeping.

**What was wrong.** This operating system had two ways to start a program and each was missing what
the other had. `run <name> [args]` built a System V initial stack (M19) and entered ring 3 without
creating a process — and `sbrk` is refused unless a process is live, because a heap's break lives in
a process slot (`heapSlotBase`..`heapSlotCalls`), so `malloc` returned NULL. `proc run <lbaA> <lbaB>`
created processes with address spaces and heaps and entered them with RSP at the top of an empty
page, so they had no argv. **No program could have arguments and dynamic memory at the same time**,
which is a hard blocker on hosting real C software.

**Why no harness caught it.** Because each harness exercised the path that had the half it needed.
`m19-argv/prog.c` states in its own header "NO malloc ANYWHERE ... `run <name>` does not create
[a process]" and uses only static buffers; `m13-libc`, the `malloc` harness, is launched with
`proc run 20 a0` and is named by LBA. Twenty green harnesses, and the gap between them was the bug.
**A capability that two tests cover one half each is not covered.**

**How it is closed.** `run` now creates a process (`procCreate`, which also learned the FAT-named
load), and `procCreate` builds the argv stack for every process it creates. `enter_user` no longer
appears in `elf.dart` at all. `m20-launch` proves the two halves *through each other*: its program
reads every byte of the argv-named file through a `malloc`ed buffer, so the counts it prints are
unobtainable unless both halves worked.

---

## GAP-0209 — `proc run` gets a complete stack but an empty argv

**Domain:** kernel (M20)
**Status:** OPEN — a bounded consequence of ADR-0034, recorded so nobody reads M20 as bigger than it is.

Since ADR-0034 every process gets a System V initial stack built by `argsBuild`. `proc run` names its
programs by **LBA** and has no arguments to give them, so it calls `argsReset()` and its processes get
a complete but **empty** vector: `argc` = 0, the `argv` NULL, the `envp` NULL and the AT_NULL pair.

That is strictly better than the bare `vmProgStackTop` they got before — an empty argv is not the same
thing as no stack — but it means **`proc run` still cannot pass arguments**. A program that needs them
must be launched by name with `run`. Closing this needs `proc run` to take names rather than sector
numbers, which is a shell-parsing change and not a kernel one.

**The visible cost of the change:** `PROC START ... RSP` moved from `0x10200000` to `0x101FFFD0` for
every `proc run` program, which is why m11, m12, m13 and m18's goldens moved in the M20 commit.

---

## GAP-0210 — `run` now refuses on a machine without FXSR

**Domain:** kernel (M20)
**Status:** OPEN — a deliberate behavioural narrowing, stated so it is not discovered as a surprise.

Before ADR-0034 an M10 `run` program had no process slot, no FPU save area and no need of one, so it
ran on a CPU with SSE disabled. Now that `run` creates a process it inherits `proc run`'s refusal:
a machine where `sse_enabled()` is 0 has nowhere to `fxsave`, and `procHeadSse < 1` refuses the launch
with `procErrNoSse` rather than starting a program whose sixteen XMM registers nobody owns (GAP-0092
makes that argument at length).

**What that costs:** `run` on `-cpu qemu64,-sse,-fxsr` used to work and now prints a refusal. Nothing
in the suite depended on it — `m11-proc` boots that machine precisely to require the refusal — but it
is a capability that was silently removed rather than one that was never there.

---

## GAP-0211 — A second `paging_install` bracket in the shell launcher loses control after the last exit

**Domain:** kernel (M20)
**Status:** OPEN — **worked around, not solved.** The cost is that one diagnostic had to move, and
that nobody yet knows why it had to.

While implementing ADR-0034 the page report (`elfPageReport`/`elfWindowLine`, which walk from CR3)
needed the program's own address space installed, because the window belongs to the process now
rather than to the kernel's page directory. The first attempt put a
`paging_install(procGet(0, procSlotPml4))` ... `procToKernel()` pair in `shellElfLoadAndEnter`,
**after** `procCreate` had returned — that is, after the slot was already READY and LIVE and its
register frame synthesised.

**The symptom.** The load reported correctly, the page report printed correct flags and physical
addresses, the program ran and produced correct output, `sbrk` worked, and the process exited and was
torn down — `PROC EXIT` and `PROC KILL` both printed. Then **nothing.** No `PROC END`, no shell
prompt, no fault line, no `#UD`. Control never came back from `user_return()`. Removing that one
bracket, changing nothing else, restored it exactly.

**What is not known.** Why. `procToKernel()` is a single `paging_install` of the kernel PML4;
`procSpaceBuild` copies every kernel mapping into the process's PML4, which is the stated reason
running kernel code on a process's CR3 is safe at all; and `procCreate` has done exactly this around
the loader since M11 without trouble. The difference is only *when* — after the slot is live rather
than during its construction. Whether the resume words `enter_user` records, a TLB effect, or
something about a LIVE slot is involved was **not** determined.

**The workaround.** The report was moved into `procCreate`'s existing bracket, where the loader's CR3
is already installed. That is arguably where it belonged anyway — it describes the load — and it is
also why `proc run` now prints `ELF PAGE`/`ELF WINDOW` lines it did not print before.

**Why this matters to the next person.** The obvious tidy-up is to move the page report back out of
`procCreate` and into the launcher "where the other reporting lives". A comment in `procCreate` says
not to. Understanding this properly is worth doing before any second `paging_install` site is added
anywhere outside `procCreate`, `procStart`, `procSwitchTo` and `procSysExit`.

---

## GAP-0212 — m12-heap's flake is RFLAGS bit 16 (RF), and it is in the golden

**Domain:** tests (M12)
**Status:** **CLOSED.** Diagnosed on the launch branch, fixed during integration. The diagnosis below
is kept intact because it is the useful part; what changed is that the fix it asks for now exists.

**THE FIX.** Step 6b compares the whole capture against the golden with `cmp -s` — a byte-for-byte
whole-file compare, not a field parse — so there was no numeric mask to apply anywhere. Instead
`rflags_canon()` rewrites the RFLAGS field **in both the capture and the golden** before they are
compared, clearing **bit 16 and no other bit**, leaving every other byte of both files untouched. The
comparison runs on the two normalised copies; the originals are not modified, so step 6a — M1's
544-byte golden as a byte-exact prefix — sees exactly what it always saw. That prefix carries no
RFLAGS token and has to stay byte-exact for its own reasons.

**WHAT THE FIX DELIBERATELY DOES NOT DO.** It does not blank the RFLAGS value and it does not
wildcard the field. IF (0x200), ZF (0x40), PF (0x4) and the reserved 0x2 are live assertions about
the state ring 3 actually ran in; a normalisation that vacated them would pass a kernel that returned
to user mode with interrupts disabled. Turning a real check into a vacuous one is the defect family
this suite has spent a session repairing, and it would have been an easy one to commit here.

**FOUR GUARDS KEEP THE NORMALISATION FROM BECOMING VACUOUS ITSELF**, because a substitution that
silently stops matching is exactly how this flake would return with nothing going red. The harness
fails if the pattern matches **no** RFLAGS field in the capture (the register dump changed shape); if
capture and golden hold **different numbers** of RFLAGS fields (a real behavioural difference, not
this flake); if the normalisation changes the capture's **byte length** (it must rewrite one hex digit
in place); or if `expected-screen.txt` ever grows an RFLAGS field, since the screen check is a
byte-for-byte `cmp` too and the flake would simply reappear there.

**Demonstrated, not asserted.** Repeated consecutive runs of the harness, plus two mutations of the
same regenerated golden with opposite required outcomes: setting bit 16 in the golden must still
**pass**, and clearing IF — a different bit in the same field — must still **fail**. The numbers are
in the integration commit.

`m12-heap` fails intermittently on its byte-exact serial comparison. The difference is always the
same one field:

```
<  USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000000246 CPL 3
>  USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000010246 CPL 3
```

`0x10000` is **RF, the Resume Flag** — bit 16 of RFLAGS. The CPU sets it transiently around
instruction restart, so whether it is set in the frame this kernel reports depends on exactly where
the process was when the syscall was taken. It is genuinely non-deterministic under QEMU, and
`--regen` does not fix it: it just records whichever value that particular boot produced, so the
golden is a coin flip that stays flipped until the next regeneration.

**Why it looks like a kernel bug and is not.** Every other field on the line — CS, SS, CPL, and the
low twelve bits of RFLAGS (IF, and the arithmetic flags) — is stable and correct. RF carries no
information this harness is trying to assert.

**The fix, when someone takes it:** mask RF out of the reported RFLAGS in the harness's comparison
(or in the kernel's report), the way a `wc` harness would normalise line endings. Do not regenerate
the golden and call it fixed — that is what has been happening.

*(Taken. The comparison-side option was the one implemented, for the reason given at the top: 6b is a
whole-file `cmp`, so the normalisation had to happen on both files rather than on one field of a
parse. The kernel's report is unchanged — no kernel code was touched to fix a test flake.)*

**Observed in this milestone:** the M20 sweep regenerated m12's golden with RF **set** and then the
verification boot produced it **clear**, failing the comparison. m12 passed on the baseline sweep of
the same tree earlier the same session. Nothing in ADR-0034 touches RFLAGS.

---

## GAP-0213 — M20's IPC claimed syscalls 11, 12 and 13; the registry had already reserved 11 and 12, and arbitrated

**Domain:** kernel ABI, IPC (surfaced by integration, ADR-0027 meeting ADR-0031)
**Status:** **CLOSED — arbitrated by the registry.** `fdwait` keeps 11, `ioctl` keeps 12, and the
channel syscalls moved to the registry's next free numbers: **`chanopen` 13, `chansend` 14,
`chanrecv` 15**. Escalated first, because syscall numbers are userland ABI and CLAUDE.md names that
explicitly; the answer was that this is **applying the registry's existing decision, not making a new
one** — the ABI question was settled when `79a5a6a` landed the registry, and what remained was only
which side pays to conform.

**Why the channel moved and not `ioctl`.** The party that can move at zero cost moves. `ioctl` is
implemented across `core/kernel/ioctl.dart`, `core/user/libc/*.c` and `drm-abi/run.sh`, and `fdwait`
is named by three design documents that all say 11. The channel's numbers lived in two files, and
`m20-ipc` keeps **no golden** — it derives every expectation — so moving it cost three constants,
three `#define`s, six doc comments, one required-syscall set in its own harness, an ADR table, three
registry rows, and a re-run. Moving `ioctl` would have been a cross-cutting rewrite of work that had
not landed yet.

**What it looks like now.** `verify-syscall-registry.sh` reports `14 allocated (0..15), 2 reserved
(11=fdwait, 12=ioctl), no number claimed twice, kernel and oslibc.h agree with the registry`.

`core/kernel/chan.dart` declares

```
const int chanSysOpenNo = 11;
const int chanSysSendNo = 12;
const int chanSysRecvNo = 13;
```

and `core/docs/syscall-registry.md` reserves **11 for `fdwait`** — named by three separate design
documents, all of which say 11 — and **12 for `ioctl`**, which the registry calls "allocated by this
registry, and the reason it exists". Only 13 was free.

**Neither branch could see this, and neither is at fault.** The registry and its verifier
`core/scripts/verify-syscall-registry.sh` were both added by `79a5a6a` (ADR-0031), the tip of
`milestones-m1-m6`. M20 branched from `d4e768c`, five commits earlier, when no registry existed and
nothing had claimed 11, 12 or 13. M20 took the next three numbers, which was the only convention
available to it. The collision exists only once the two are on one line.

**Measured, not inferred.** `verify-syscall-registry.sh` passes on a pristine `79a5a6a` export:
`11 allocated (0..10), 2 reserved (11=fdwait, 12=ioctl), no number claimed twice`. On the merged line
it fails with three rows missing, and `m20-ipc`'s own userland agrees with the kernel
(`#define SYS_CHANOPEN 11 / SYS_CHANSEND 12 / SYS_CHANRECV 13` in `m20-ipc/prog.c`), so this is a
real ABI claim on both sides of the syscall boundary and not a stale constant.

**12 is not merely reserved any more, it is taken.** `ioctl` is implemented as `ioctlSysNo = 12` with
`#define SYS_IOCTL 12`, in work that had not yet been committed when this was written. When that
lands beside this, two kernels claim 12 and one of them is wrong.

**Cost while it is open.** `drm-abi/run.sh` invokes the registry verifier, so that harness fails on
the merged line. It is the only harness that does.

**THE POINT WORTH KEEPING, once the numbers stop being interesting.** `syscall-registry.md`'s own
header says why it exists: `design/hot-files.md` §5.1 records that **two agents both claimed 11 in two
different files**, and that such a duplicate "merges clean, builds clean, boots clean, and
mis-dispatches". That is precisely what happened here, a second time, between two branches that could
not see each other — and this time the registry and its verifier caught it before it ran. The registry
earned its keep on the first merge after it landed.

**What it cost to be caught late rather than early.** `m20-ipc`'s own harness carries a duplicate-
syscall check that scans every `const int *SysNo` in `core/kernel/*.dart`. It did **not** fire, and
could not have: 11 and 12 were *reserved* in a document, not *declared* in the kernel, so there was
no second constant for it to collide with. A check that reads only code cannot see a reservation that
lives only in prose. The registry verifier is the one that reads both, which is the argument for
running it on every merge and not only when `drm-abi` happens to be in the set.

---

## GAP-0214 — `chanRetNoProc` is a LIVE guard that nothing tests, because ADR-0034 removed the only way the shell could reach it

**Domain:** kernel IPC, conformance (surfaced by integration: ADR-0027 meeting ADR-0034)
**Status:** **OPEN — live but unreachable from the shell; needs a no-slot payload to test.**

`chanSysOpen`, `chanSysSend` and `chanSysRecv` each begin by asking `chanCallerId()`, which returns 0
when `procLive() < 1`, and each refuses such a caller with `chanRetNoProc`. At M20 that path was
covered behaviourally: `m20-ipc`'s CHECK 13 booted the same binary with `run <lba>`, which gave a
program ring 3, its own address space, a heap and file descriptors **and no process slot**, and the
transcript showed all three syscalls refusing it by name.

**ADR-0034 abolished the premise, not the guard.** Unifying the launch path routed `run` through
`procCreate`, so every ring-3 program now has a slot and nothing reachable from the shell produces
`procLive() < 1` while ring-3 code runs. Thirteen assertions and one whole QEMU boot went with it.

**THIS IS NOT GAP-0206's CATEGORY AND MUST NOT BE FILED AS THOUGH IT WERE.** `chanRetCorrupt` is
unreachable **by construction** — no state this kernel can enter produces it, which is why recording
it as structurally-asserted-only is the honest end of that story. This one is different in the way
that matters: **the path still exists and is still reachable.** An M9-style payload runs with no
process slot and would hit these three lines today; what is missing is a payload that issues
`chanopen`. A live defence with nothing proving it works is a **worse** state than dead-and-known,
and flattening the two into one entry would put a working guard in the drawer marked "can't happen".

**What is asserted now, stated as the weaker claim it is.** `m20-ipc` CHECK 13 is structural: all
three syscalls still call `chanCallerId()`, all three still refuse with `chanRetNoProc`, and
`chanCallerId` still returns 0 when `procLive()` is 0. That proves the guard has not been deleted. It
does not prove it works.

**Why the payload was not simply added during the merge, measured rather than asserted.** A payload
is a fixed byte sequence in kernel `.rodata` and would itself be about fourteen bytes. The cost is
everything around it: `shellStrHelp` **enumerates every `user` mode, one line each**, so a new mode
grows it; three harnesses (`m10-elf`, `m12-heap`, `m13-libc`) pin it at exactly **2224** bytes; and
GAP-0105 and GAP-0115 both record that moving `shellStrHelp` moves **m3-m6's goldens by
substitution**, because the help text is in their transcripts. Add `userCodeSizes` going 6 → 7 bytes,
`userModeCount`, the mode-name parsing, and `m9-ring3`'s "six payload tables" checks and goldens, and
one fourteen-byte payload reaches eight harnesses' goldens and three pinned constants. That is a unit
of its own, not a line in a merge.

**What closing it takes.** A `user chanopen` payload — `mov $13,%rax; xor %rdi,%rdi; int $0x80` and
an exit — plus its mode wiring, and then the golden churn above taken deliberately in one commit. The
kernel prints `CHAN REFUSE C 0D EP 0000000000000000 R FFFFFFFFFFFFFFFD` itself when it refuses, so
the payload needs to report nothing: the existing transcript assertion works unchanged the moment
something can reach the path.

---

## GAP-0243 — `procErrBusy` and `elfErrLive` are LIVE re-entrancy guards that nothing can reach, because this shell is synchronous

**Domain:** kernel (proc, elf), conformance (surfaced by the shakedown campaign's T3 sweep)
**Status:** **OPEN — live but unreachable; deliberately kept and deliberately untested. ADR-0039 §4.**

**This is GAP-0214's category, with four more instances from the same commit.** ADR-0034's blast
radius on refusal coverage was never measured; the shakedown booted for it and found these.

`procErrBusy` — *"a process session is already running"* — guards three sites:

| file:what it asks | |
|---|---|
| `proc.dart` `shellProcRun`, `procLive() > 0` | is a process on the CPU? |
| `proc.dart` `shellProcRun`, `userMeta(userMetaLive) > 0` | is an M9 payload on the CPU? |
| `elf.dart` `shellElfLoadAndEnter`, `procLive() > 0` | is a process on the CPU? |

and `elfErrLive` — *"a program is already running"* — survives on one site, `shellElfLoadAndEnter`'s
`userMeta(userMetaLive) > 0`. (Its `elfLive()` twin is DELETED — ADR-0039 §2, and GAP-0244.)

**Why nothing reaches them, and why that is a fact about the shell rather than about the guards.**
`shellMain` is the only caller of every launcher and it is not re-entrant. `run` and `proc run` do not
return the prompt until the program has exited and `PROC KILL` has reclaimed it, so a second command
cannot overlap the first. Every exit path — including the fault path through `procOnFault` and
`userOnFault` — calls `procSessionReset` / `userTeardown` before `shellMain` runs again. The one thing
that stays live is a program that never exits, and such a run never returns the prompt either
(GAP-0085, which is why `user hold` is the last command of its session), so the second command cannot
be typed at all.

There is no non-shell caller. Every launcher in this kernel is reached from `shellExecute` and from
nowhere else.

**Why they are not deleted.** Deleting a re-entrancy guard because today's only caller happens to be
synchronous trades a real property for a test result. Any asynchronous launch — a `spawn` syscall, a
second shell, job control — reaches all four sites at once, and the day that lands is not the day to
discover the guard was removed for tidiness. The three ADR-0039 deleted are a different case
entirely: those branched on a flag **no code writes**, so they could not fire under any caller.

**What IS asserted.** `m11-proc`'s and `m10-elf`'s refusal censuses still require each code to be
returned from a live line with its own distinct sentence. That proves the guard has not been deleted.
It does not prove it works. **This is stated as the weaker claim it is, the same way GAP-0214 states
its own.**

**What closing it takes.** An asynchronous launch — the shell returning its prompt while a program
runs. All four sites become reachable at once, from the shell, with no new refusal vocabulary and no
new payload. Until then they are live guards waiting for a test, not dead code filed away.

---

## GAP-0244 — `elfLive()` has no writer: the M10 window-program concept survives only as four dispatch branches that always answer "no"

**Domain:** kernel (elf, user, file)
**Status:** OPEN — measured, bounded, and deliberately out of the shakedown's scope. ADR-0039 §2a.

ADR-0034 deleted the M10 window-program launch. With it went the only assignment of a **non-zero**
value to `elfMetaLive`:

```
$ grep -rn "elfSetMeta(u64(elfMetaLive)" core/kernel/
core/kernel/elf.dart:1525:  elfSetMeta(u64(elfMetaLive), u64(0));
```

`elfInit` zeroes it, `elfTeardown` zeroes it, nothing writes 1. **`elfLive()` is a compile-time zero.**

Two REFUSAL guards branched on it and are deleted (ADR-0039 §2). **Five** *dispatch* sites remain,
and they are a different thing — they ask "which of the three things that can be in ring 3 is
running", and the answer is now permanently "not that one":

| site | what the dead branch would have done |
|---|---|
| `user.dart` `userOwns` | validate a pointer against `elfOwns` instead of the payload window |
| `user.dart` `userSyscall` (×2) | admit a caller with no process slot and no payload; the nested `elfLive() < 1` that stands in for a boolean `\|\|` (GAP-0023) |
| `user.dart` `userOnFault` | tear down through `elfTeardown` instead of `userTeardown` |
| `file.dart` `fileOwnsWrite` | the same ownership dispatch, one layer up |

**Why they are not removed here.** Removing them deletes a *concept* from four files, changes what
`elfMetaLive` and `elfTeardown` are for, and moves the `.bss` layout that six harnesses pin. That is
a unit of its own. A refusal audit is not the place to do it, and doing it half way — deleting the
branches and leaving the flag — would be worse than either end.

**What is asserted instead.** `m10-elf/run.sh` §2i requires that `elfMetaLive` has no non-zero writer
**and** that no *refusal* guard branches on `elfLive()`. It counts the dispatch sites and prints the
number rather than failing on them, so the day someone makes the flag live again, the check tells
them the guards were removed on the assumption that it never would be.

**What closing it takes.** Either delete the concept — `elfMetaLive`, `elfLive`, `elfOwns`'s dispatch,
`elfTeardown`'s fault path — in one commit with the `.bss` and golden churn that implies; or give the
flag a writer again, which means a second kind of thing in ring 3, which ADR-0034 exists to prevent.

---

## GAP-0245 — `procErrArgs` and `procErrBadLba` are shadowed ON PURPOSE, and the missing thing is a test rather than a fix

**Domain:** kernel (proc, args), conformance
**Status:** OPEN as a record. Two guards, two different reasons, neither a defect in the kernel.
ADR-0039 §5.

The shakedown's T3 sweep found six shadowed guards and they split 4/2. Four were accidents
(GAP-0243, GAP-0244, ADR-0039). **These two are defence in depth working as designed**, and filing
them with the accidents would be wrong.

### `procErrBadLba` (05) — *"that is not a pair of LBAs"*

`shellProcArgs` caps both fields at `ataLba28Max` and answers the usage line, which is correct: the
shell should refuse a line it knows is malformed rather than build a process to find out. The kernel
guard behind it is the second line of defence **for a caller that is not the shell**, and there is no
such caller — `shellProcRun` is reached from `shellExecute` and from nowhere else.

It is squeezed from both sides, which is why the sweep could not corner it: malformed argument text
hits the shell's usage line, and well-formed text naming a bad sector reaches the *loader* and gets
`ELF REFUSED 05` / `PROC REFUSED 06` instead.

**Why a test was not added.** The obvious one is a second shell command that calls `shellProcRun`
without pre-checking. That is circular — the thing under test is what happens when the shell is not
in the way, and a shell command is the shell being in the way with its checks removed. The
non-circular version is a real second caller (a `spawn` syscall), which is a feature and belongs in
its own unit with its own ADR.

### `procErrArgs` (0A) — *"the arguments do not fit on the initial stack"*

Stronger than shell-unreachable: **unreachable by any caller of the launch API**, by arithmetic.
`argsBuild` fails only if the block it must write plus `argsMinStack` exceeds one stack page, and
`args.dart` caps staging at `argsMaxCount` = 8 arguments and `argsMaxBytes` = 128 bytes of text
including terminators. Worst case is 240 bytes against 4096 − 1024 = 3072 available. There is no
input to `argsStage` that reaches it.

So it is a **cross-file consistency guard** — the same kind `argsErrNoRoom` already is, and already
says it is, in its own comment: *"Not reachable with the bounds above — the worst case is 240 bytes —
and checked anyway, because the bounds and the page size are two numbers in two files."*

**The test that fits it is arithmetic, not a boot.** `m19-argv/run.sh` now multiplies the four numbers
out and fails if a change to any one of them would make `argsBuild` able to fail. That is exactly when
someone needs to be told, and it is a stronger statement than a boot could make: a boot proves the
guard fires for one input, and this proves no input exists.

---

## GAP-0246 — `help` grew to 2511 bytes: GAP-0142 paid, and the recurring golden cost paid with it

**Domain:** kernel (shell), conformance
**Status:** OPEN — the same recurring cost GAP-0059, GAP-0065, GAP-0069, GAP-0072, GAP-0075,
GAP-0078, GAP-0087, GAP-0093, GAP-0095, GAP-0106 and GAP-0115 record, at the twelfth change that has
paid it. **GAP-0142 is CLOSED by this entry.**

`shellStrHelp` goes 2224 → **2511**, by five lines:

* `proc sched`, `proc coop <lbaA> <lbaB>` and `proc spin <lbaA> <lbaB> <quanta>` — **GAP-0142's three.**
  That entry said exactly what closing it would take (*"one commit that adds the three lines and
  regenerates the five goldens, with each regenerated golden required to differ from its predecessor
  in the help text alone"*) and this is that commit. They were dispatched, booted and shown working,
  and the only place they appeared was `procStrUsage2` — which a user sees **only by typing `proc`
  wrong**. Discovering a feature by making a mistake is not discoverability.
* `frames leave <n>` — new, and it exists because `elfErrNoFrames` had no reachable caller without it
  (ADR-0039 §3).
* the `fb` line is rewritten in place. It said `800x600x32`; the command prints `0320x0258x20`; and
  nothing said which base either was in. It now carries the bytes the command actually prints and the
  decimal beside them, labelled — the only place in the shell's listing where a stated value did not
  textually appear in the command's output.

**What moved, and how.** `m3-shell`, `m4-fault`, `m5-pci` and `m6-disk` have no `--regen`; their
serial goldens were moved by **mechanical substitution** of the old 2224-byte block for the new
2511-byte one, and `m3-shell`'s 80x25 screen golden by taking the last 24 lines of the new listing —
both then required to be reproduced by the kernel byte-for-byte, which they were, first try. Every
other golden in the suite moved anyway, because the kernel image grew past a 4KiB boundary and
`__kernel_end` took every downstream address with it (GAP-0078's mitigation, for the tenth time).

**Cost:** unchanged and still real. Whoever adds the next shell command pays the substitution for
four harnesses and the `--regen` for the rest, and the twelve pinned copies of the number
`shellStrHelp` is asserted at.

---

## GAP-0247 — `m7-frames` asserted a DCDart pin that commit 71cf08f had already moved, and was red on the pristine tree

**Domain:** conformance (M7)
**Status:** CLOSED by the same commit that found it, and recorded because of what it says about the
"24 harnesses green" claim.

`m7-frames/run.sh` asserted `DCDART_PIN.txt` began with `8713298`. Commit **71cf08f** — *"...and
DCDART_PIN moves to 38f0b06 now that the sweep is green"* — changed the pin file and did not change
the literal. So from that commit onwards `m7-frames` failed on a clean checkout, with a message that
reads like a toolchain problem and is a two-place-edit problem:

```
M7-frames: FAIL — DCDART_PIN.txt says 38f0b06; the tree is built against 8713298
```

**Nothing about the kernel was wrong.** The shakedown found it by running the suite rather than by
reading the commit, which is the only way this class of thing is ever found.

**What it says about the surrounding claim.** The pin bump was made *because* a sweep was green; the
sweep that proved it green necessarily ran before the bump. A change whose whole content is "the
suite passes" is the one change most likely to be committed without re-running the suite after it.

**The fix** is the literal, moved to `38f0b06` with both facts the pin is load-bearing for still named
beside it (`e3cfe18`, nested while-loops, GAP-0068; `8713298`, `@bss`, ADR-0051) so a future bump has
to answer to both. **The underlying shape is not fixed:** the pin is a value in one file and a literal
in another, and nothing derives the second from the first. Deriving it would defeat the check, which
exists to catch a silent revert to an older toolchain; so it stays a two-place edit, now with a
comment at the second place saying so.

---

## GAP-0248 — the sibling DCDart checkout is not at `DCDART_PIN.txt`'s commit, and nothing notices

**Domain:** toolchain, build (surfaced by the shakedown campaign)
**Status:** OPEN — measured and benign **today**, and the measurement is the point.

`core/scripts/build-kernel.sh` compiles with whatever `dcc` is in `$DCDART_HOME` (default: the sibling
`DCDart` checkout). `DCDART_PIN.txt` records **38f0b06**. During this campaign the sibling checkout was
at **f9676f2** — three commits past the pin, because DCDart is being worked on at the same time. So
every harness run here, and every golden regenerated here, was produced by a compiler the pin does not
name, and **nothing in the build or the suite says so.**

**It was checked rather than assumed, because the goldens depend on it.** A byte-exact golden carries
frame addresses derived from `__kernel_end`; a codegen change of one instruction moves them. The
control:

```
git archive HEAD | tar -x -C /tmp/headtree      # the PRISTINE kernel at 71cf08f
cd /tmp/headtree && bash core/scripts/build-kernel.sh          # with dcc f9676f2
bash core/tests/conformance/m8-paging/run.sh                   # against HEAD's OWN goldens
  -> M8-paging: PASS, 238 checks, 3445-byte serial match
```

`m8-paging` was chosen because its golden is byte-exact **and** contains the six page-table frame
addresses the allocator hands out immediately above the kernel image — the numbers that move first if
codegen moves at all. `__kernel_end` came out at `0x14e470` and `pmmStore` at `0x14a1c8`, which are
the values HEAD's own goldens carry. **So f9676f2 and 38f0b06 are codegen-equivalent for this kernel,
and the goldens in this commit are trustworthy.**

**What is still wrong.** That was luck, established after the fact. Three things make it a gap:

1. **No check enforces the pin at build time.** `m7-frames` asserts the *contents of the pin file*
   (and GAP-0247 records that even that assertion went stale). Nothing compares the pin against the
   `HEAD` of the checkout actually being compiled with.
2. **The pinned commit could not be built in isolation**, which is why the first attempt at this
   control failed. `git archive 38f0b06` produces a tree that `dart pub get` refuses: `dcc_lower`
   depends on `core/frontend/vendor/dart-sdk`, which is **not in git**. Reproducing an old toolchain
   therefore needs the live checkout's vendored SDK symlinked in — i.e. the pin is not sufficient to
   reconstruct the compiler it names.
3. Even with that symlinked, `dcc` at 38f0b06 rejected the current `kmain.dart` with
   `no @bare top-level function found`, which is more likely a broken reconstruction than a real
   incompatibility — and *not being able to tell which* is exactly the cost of item 2.

**What closing it takes.** `build-kernel.sh` printing (and a harness asserting)
`git -C "$DCDART_HOME" rev-parse HEAD` against `DCDART_PIN.txt`, so building against an unpinned
toolchain is a visible fact rather than an invisible one. Item 2 is DCDart's to fix — vendoring a
compiler by reference to a gitignored directory means no commit of this repo names a reproducible
compiler — and by rule 3 of `CLAUDE.md` that is a DCDart-repo decision, not this repo's.

---

## GAP-0249 — m12-heap's byte-exact golden pins the INTERLEAVING of two preemptive processes, and that is not deterministic

**Domain:** conformance (M12)
**Status:** OPEN — observed twice on the same kernel, once green and once red, under different machine
load. **Distinct from GAP-0212**, which was RFLAGS bit 16 and is closed.

`m12-heap` runs two processes under `proc run` — a **preemptive** policy since M18 — and compares the
whole serial capture byte-for-byte. The capture therefore encodes **the order in which two
independently-scheduled processes reached each `write` syscall**, and that order depends on where the
timer interrupt lands.

Observed during the shakedown, with a **byte-identical kernel**:

```
09:0x  M12-heap: PASS
11:17  M12-heap: FAIL — captured serial output did not exactly match expected.txt
         PROC END SWITCHES 00000003   (golden)
         PROC END SWITCHES 00000004   (capture)
       ...and slot 01's whole H1 block moved to before slot 00's exit, with
       SYSCALLS 0000003B where the golden has 00000044 and LEFT 00000001 where
       it has 00000000.
```

One extra involuntary switch reorders two processes' output relative to each other. `--regen` does not
fix it, for GAP-0212's reason: it records whichever interleaving that boot produced and the golden
becomes a coin flip that stays flipped.

**Re-run alone at load 4.5 it PASSED**, 152 checks, with no change to the kernel or the golden
between the two runs. Three observations on one binary: green, red, green.

**Why it surfaced now.** Three agents were running full conformance sweeps on one 8-core machine;
load average reached ~25. The harness types on a wall clock and the guest schedules on another one,
and the window in which the two processes' quanta line up the way the golden records narrows as the
host gets busier. That is the same underlying shape as GAP-0105 — **every timing constant in this
suite is a guess that gets worse as the machine gets busier** — arriving from the guest side instead
of the driver side.

**What it costs.** A green suite is not reproducible on a loaded machine, and the failure names a
scheduler counter, so it reads as a kernel regression rather than as a harness one. That is the worst
shape a flake can have and it is exactly what GAP-0105 says about its own.

**What closing it takes.** The same shape GAP-0212's fix used: normalise the thing that is genuinely
non-deterministic in **both** the capture and the golden before comparing, and assert the invariants
separately. Here that means comparing the two processes' line-sets rather than their interleaving, and
keeping `switches == yields + exits + preemptions` as its own check — which `m18-preempt` already
makes. The byte-exact compare should cover the parts that ARE deterministic and stop pretending the
interleaving is one of them.

## GAP-0263 — three goldens embed the kernel's own section boundaries, so they CANNOT be green across the ADR-0069 pin move; their regen must ride the pin-move/migration merge commit

**Domain:** conformance (M8/M9/M10) / toolchain coupling
**Status:** OPEN — deliberately left failing on branch `mmio-volatile-migration` (and the three
`*-volatile` sibling branches), because fixing it here would hide the drift the pin exists to
surface. Numbered 0263: 0262 (branch `b1-live-console`) is the highest GAP claimed on any branch,
worktree, or uncommitted tree at assignment time.

**Found:** during the `Volatile<T>` migration (ADR-0044), 2026-08-28. The full 24-harness sweep on
the migrated tree, built against the post-ADR-0069 DCDart working tree, fails `m8-paging`,
`m9-ring3` and `m10-elf` on one line class:

```
expected  VM SECT 0000000000100000 0000000000135EA0 ... 000000000013A2FC ...
captured  VM SECT 0000000000100000 0000000000135680 ... 000000000013A32A ...
```

`VM SECT` prints `kernel_text_end`/`kernel_rodata_end` — the kernel's OWN layout, not behaviour.
Three independent movements stack in it, separated by building an UNMIGRATED baseline
(`milestones-m1-m6` @ 45b9c7a) against the same new toolchain:

1. **Blanket-volatile removal** (the big one): the pinned 38f0b06 made every `Pointer` access
   volatile; the post-split toolchain makes ordinary access plain and the same kernel source
   compiles ~2.7KiB smaller (`__text_end` 0x135EA0 → 0x1353E0, unmigrated).
2. **This migration**: +0x2A0 of `.text` back (one `movw` per cell in the VGA loops; the probe
   sites).
3. **On `b1-live-console`**, whose goldens were freshly re-recorded with its own vmTestRo fix
   (8a72cb7): the sibling `b1-live-console-volatile` still moves `__text_end` 0x138350 → 0x1386D0,
   same cause, behaviour byte-identical elsewhere.

The `VM FAULTS 2 → 1` half of the original m8 failure was a REAL regression (the deleted W^X probe
store, see ADR-0044 and b1's GAP-0261) and is FIXED by the migration — after it, only the
section-address lines differ.

**Why not fixed here:** the migration's ground rules forbid regenerating goldens, and rightly — a
regen against a toolchain the pin does not name makes the drift invisible. The regen belongs to
the single commit that moves `DCDART_PIN.txt` to `neon-round3` @ 7669e77 and merges the migration
branches (ADR-0044 "The coupled step").

**Also observed during the same sweep, NOT this migration's, tracked separately:** the DCDart
working tree's `@rodata` constant-merging regression deletes one-byte tables' symbols
(`argsStrSp`, `fbStrBy`), failing `m19-argv` and `m5-pci` on unmigrated and migrated trees alike —
recorded as GAP-0262 on `b1-live-console` and being fixed on the DCDart side.

**The wart that survives the regen:** any golden that freezes the kernel's own section addresses
re-breaks on EVERY code-size change, toolchain or source. Deriving those fields at run time from
`core/build/kernel.map` (as `m21-shmem/run.sh` already does for ordering) would assert the same
property without freezing the layout. Left open for the harness owner.
## GAP-0233 — There is no involuntary revocation, and the two mechanisms it would take

**Domain:** kernel, shared memory (M21, ADR-0041 §7)
**Status:** OPEN — a stated design boundary, not a defect. `shmdrop` releases the CALLER'S OWN
capability; a grantor cannot take one back from a grantee.

**Why it is not simply missing.** Revoking a capability in another address space means unmapping
pages in page tables the kernel can reach **only while that process's CR3 is loaded**. Every mapping
function in `vm.dart` walks from CR3 (`vmProgPd` → `vmLivePml4` → `cr3_read`) and that is
deliberate — M11's design note says the loader runs with the target's CR3 already in the register.

**The two mechanisms, priced.**

1. **A cross-address-space unmap**, the `procPtOf(s)` shape: edit the victim slot's tables directly
   through `vmSetEntry`. It is correct on one core *because a CR3 write on the next switch flushes
   everything and this kernel never enables PGE* — `procSpaceFree`'s comment says so explicitly. It is
   **wrong on two cores** without a TLB shootdown, which needs an IPI, which needs an APIC this
   kernel does not program. It also bypasses `vmShmMap`'s NX-always and busy checks, so the W^X
   argument would have to be re-made at a second site.
2. **A deferred revoke**: a flag on the victim's slot, checked at the next `procSwitchTo`. Cheap and
   correct on one core, and it puts a new field and a new step in the scheduler's hot path — surgery
   on `proc.dart` that M21 would then be shipping untested.

**What is NOT missing, and the distinction matters.** The part of revocation that is load-bearing for
*safety* is present: a capability dies with its holder on the fault path as well as the exit path
(`procCleanup`), and a handle to a dead region is refused by generation (`shmRetStale`) rather than
dangling. What is absent is revocation as a *policy* tool — "I have changed my mind about you".

**Who needs it.** Not the client this exists for: a compositor revokes by asking the client to drop,
or by outliving it. It becomes real the day a region is granted to something untrusted that will not
cooperate.

---

## GAP-0234 — A capability names a whole region and maps it whole

**Domain:** kernel, shared memory (M21)
**Status:** CLOSED — grow-in-place landed (ADR-0150, `shmgrow`
34), shrink-in-place landed (ADR-0156, `shmshrink` 35),
multi-mapper grow/shrink landed (ADR-0158, `shm-multi/`), and
partial / offset map landed (ADR-0160, `shm-part/`: `shmmap` rdx
range word + capability window). Syscall 11 stays `fdwait`.

There was no partial map and no offset map. `shmmap` mapped every
page of the region at the region's own address, and `shmdrop`
unmapped all of them. A client that wants to share one tile of a
surface can now map `[offset, offset+count)` of a larger region
(ADR-0160). Growing past the create size without a new region is
ADR-0150. Shrinking without a new region is ADR-0156. Updating every
mapper's page table on grow/shrink is ADR-0158.

**Cost:** a compositor with many small surfaces needs many regions, and `shmMax` is 2 (GAP-0237). The
frame-vector page already indexes pages individually, so a partial map is a bounded change to
`shmMapPages`/`shmUnmapPages` and a wider capability word — not a redesign.

**Binary next step:** done — `shm-part/run.sh` PASSes.

---

## GAP-0235 — File backing + demand paging closed (`shmfile` / demand)

**Domain:** kernel, shared memory (M21)
**Status:** CLOSED — ADR-0163 (`mprotect` / `MAP_FIXED`, `mmap-prot/`);
ADR-0164 (`shmfile` + demand fill, `mmap-file/`).

A region may be anonymous and eager (ADR-0041) or file-backed and
demand-filled (ADR-0164). `shmfile(fd)` sizes a RO window to an open
FAT file with not-present leaves; first `#PF` NOTPRES fills from the
fd and resumes. Syscall 11 stays `fdwait`.

**Binary next step:** none for this gap. Write-through shared file
maps and anonymous lazy `shmcreate` are later work if needed.

---

## GAP-0236 — There is no atomicity across a shared region, and no atomic would give one

**Domain:** kernel, shared memory, concurrency (M21, ADR-0041 §6)
**Status:** OPEN — the honest boundary of the one-writer design, and **the place a single-core
assumption stops being safe first**.

**This is deliberately NOT filed as "the same as GAP-0205".** GAP-0205 records that `chan.dart` runs
with `IF` clear on one core and that its ring is therefore a critical section by construction. That
argument covers M21's **metadata** — `shmStore`, capability words, page-table entries — which is
touched only inside syscalls, and DCDart's atomics (its ADR-0055/0056) are deliberately not used
there for GAP-0205's exact reason: on one core with `IF` clear they are pure cost and would disguise
the dependency rather than remove it. On the day this kernel has two cores, `shmRegRefs` is the one
word here that needs a real atomic — `shmgrant` increments it and `shmdrop`/`shmReleaseOwner`
decrement it, which is a genuine multi-writer counter and the only one.

**It does not cover region CONTENTS, and that is the gap.** A channel's data is only ever touched by
the kernel with `IF` clear; a region's data is touched by **ring 3, with no syscall involved at all**.
Two things make that survivable today:

* **exactly one writer, by construction.** `shmgrant` conveys read-only and takes no permission
  argument, and `shmmap` refuses to widen a read-only capability. There is no writer-writer race in
  this design on any number of cores;
* `proc coop` does not preempt, so the harness's interleaving is exactly the two programs' yields.

**What remains is real:** under M18's preemption a reader can be scheduled in the middle of the
writer's update and observe a **half-written region**. `m21-shmem` cannot demonstrate it, because it
runs under `proc coop`.

**No atomic fixes this and adding one would be worse than useless.** The unit of tearing is a frame or
a whole buffer, not a word; a `lock cmpxchgq` on one `u64` of a 16 KB update buys nothing and
advertises a guarantee that does not exist. The answer is a **sequence number the writer bumps last
and the reader re-reads after copying**, or double buffering — both of which live in the client's
protocol, above this primitive. Closing this gap means writing that protocol down and testing it under
`proc run` rather than `proc coop`.

---

## GAP-0237 — A region is capped at 128 pages, and a full-screen frame is 469

**Domain:** kernel, shared memory (M21, ADR-0041 §7.1)
**Status:** OPEN — a configuration choice with the numbers attached, and the one number a compositor
will hit first.

The shared **window** is 512 pages (2 MiB, one page-directory entry) and was sized so that an
800×600×32 frame — **1,920,000 bytes = 469 pages** — fits in it with 43 to spare. The **slotting** is
what caps a region: **ADR-0109 took `shmMax = 4` regions of `shmSlotPages = 128`**, so `shmMaxPages` is 128 and
`shmcreate(469)` is still refused with `shmRetBadLen`. The DE can hold four named surfaces; a
full-screen frame still does not fit.

**What changing it costs: two constants and nothing else.** `shmMax = 1` / `shmSlotPages = 512` fits a
full-screen frame today and changes no ABI, no syscall, no structure and no wire format — the harness
multiplies `shmMax * shmSlotPages` against `vmShmPages` and would keep passing. ADR-0109 went the
other way (more slots, smaller slots) so Start can spawn.

**Why M21 did not take the one-slot configuration.** Two regions is what two processes needed, and a
one-region kernel could not exercise `shmRetTwice` or a second concurrent region at all. The test
coverage was worth more at that rung than the region size.

**The other way out, for later:** a second page-directory entry. `docs/design/memory.md` §1.1 counts
383 free contiguous entries above the load region, so the window can grow to 768 MiB without touching
the page-directory budget. That is a `vmShmLeafSlot` change — §1.2(b) names the table-selection bug it
would introduce — and it is a milestone, not a constant bump.

---

## GAP-0238 — A write through the read-only mapping is never attempted

**Domain:** conformance, shared memory (M21, ADR-0041 §8.1)
**Status:** **CLOSED at M21**, in the same unit that opened it, after the first version of this entry
deferred it. `m21-shmem`'s second boot now performs the store and requires the fault.

**What it does.** A second binary is built from the SAME `prog.c` with `-DM21_ROFAULT` (and
`build-progs.sh` fails if the two link byte-identical, so a `-D` that stopped taking effect cannot
silently degrade the test into booting the ordinary binary). Its consumer maps the region read-only,
reads all 16384 bytes, prints its hash, and then stores one byte at the region base. The harness
requires:

```
PF CR2 0000000010200000 ERR 00000007 PRESENT WRITE USER DATA
USER FAULT VEC 0E ERR 0000000000000007 RIP ... CPL 3
PROC KILL SLOT ...
```

and requires the ordering — region read correctly, THEN store announced, THEN fault — so a fault
raised for some other reason cannot satisfy it.

**It is TWO-SIDED, which is what makes it worth having.** If a grantee were ever mapped writable the
store SUCCEEDS, the program prints `ROSTORE SURVIVED`, and the harness fails on that line's PRESENCE
with a message naming the invariant that just died. Verified by mutation: turning the store into a
load made `ROSTORE SURVIVED` appear and the harness caught it. So neither outcome passes by accident.

**The hash is read out of the TRANSCRIPT on that boot, not out of an exit code**, which is the detail
that made this awkward in the first place: the faulting process is killed and never reaches `exit`.
`prog.c` prints the hash before storing, so the boot still proves the region was read correctly
before the fault — otherwise a fault would prove nothing about what was mapped.

*(Historical: the original text follows.)*

**Status:** was OPEN — the read-only-ness was asserted from the page tables, which is a weaker claim
than a fault.

`m21-shmem` proves the consumer's mapping is read-only by reading the **live page tables** — the
kernel walks them through `vmEffective` and prints `W 0 X 0` per page, and the harness requires it.
It does **not** have the consumer store through the mapping and take a `#PF`.

**Why not.** The store would fault, the kernel would kill the process, and the process would never
reach its `exit` — so the 64-bit hash of the bytes it read, which is the harness's headline assertion,
would be lost. The two cannot both be the last thing a process does.

**What closing it takes.** A third boot with a variant payload whose *last* act is the store, with the
hash carried out some other way — printed and matched from the transcript rather than returned as an
exit code — and the expected `#PF` at a known CR2 asserted from M4's recovery report. That is the
shape `m8-paging`'s `vmtest ro` already has for the kernel's own mappings; this would be its ring-3
twin.

**Why it matters more than it looks.** `W 0` in a page table and "a store actually faults" are the
same claim only if `CR0.WP` and the ring-3 boundary behave as M8 and M9 established. They do, and
those are separately tested — but this milestone is the one that introduces a page ring 3 can *reach*
and must not *write*, so the direct demonstration belongs here eventually.

---

## GAP-0239 — M21's no-process guard is live, reachable, and unreachable from this harness

**Domain:** kernel, shared memory, conformance (M21)
**Status:** **OPEN — GAP-0214's situation exactly, for a second subsystem.**

`shmSysCreate`, `shmSysGrant`, `shmSysMap` and `shmSysDrop` each begin by asking `shmCallerId()`,
which returns 0 when `procLive() < 1`, and each refuses such a caller with `shmRetNoProc`. A
capability table IS process-slot storage, so this is not a formality.

**Nothing the shell can start reaches it.** ADR-0034 unified the launch path so `run <lba>` goes
through `procCreate`; every ring-3 program therefore has a slot. `m21-shmem` was written with a
`run <lba>` boot as its no-process control, and that boot was **observed taking the producer path
instead** — `PROC NEW SLOT 00 ID 00000001`, then `CHAN OPEN`, then `SHM CREATE`. The boot was removed
and replaced with a structural read.

**THIS IS GAP-0214's CATEGORY AND NOT GAP-0206's**, and the distinction is the same one GAP-0214
draws. `chanRetCorrupt` is unreachable **by construction** — no state this kernel can enter produces
it. This guard is **reachable**: an M9-style `user` payload runs with no process slot and would hit
all four of these lines today. What is missing is a payload that issues `shmcreate`. A live defence
with nothing proving it works is a worse state than dead-and-known.

**What is asserted now, as the weaker claim it is.** All four syscalls call `shmCallerId()`, all four
refuse with `shmRetNoProc`, all four do so **before** anything reads `procCurrent()`, and
`shmCallerId` still returns 0 when `procLive()` is 0. That proves the guard has not been deleted. It
does not prove it works.

**What closing it takes is the same payload GAP-0214 needs**, and that is the point worth keeping:
one `user` mode that issues a syscall with no process slot closes GAP-0214 and GAP-0239 together.
GAP-0214 prices it — `shellStrHelp` grows, three harnesses pin it at 2224 bytes, and eight harnesses'
goldens move by substitution — and that price is now shared between two entries rather than charged
to one.

---

## GAP-0240 — Which of `m21-shmem`'s checks are load-bearing, measured by mutation

**Domain:** conformance (M21)
**Status:** OPEN — the entry GAP-0114 established the shape of and GAP-0120 and GAP-0124 refined,
written for this milestone's own harness. **A test suite's own coverage is a thing to measure, not to
assume.**

Four deliberately broken kernels were built and run against the harness. All four were caught, and
**which check caught each one is the useful output**:

| mutation | caught by | kind |
|---|---|---|
| `vmShmMap` sets NX only on read-only pages | the structural read of its body | READING |
| the `freeFrame` shared-frame guard deleted | the structural read of `freeFrame` | READING |
| the guard still *called*, but `shmFrameMark` never marks anything | `SHM DEAD … FREED 00000001` instead of 5 | RUNNING |
| the grantee's mapping made writable | `consumer page 0 is W 1, expected W 0` | RUNNING |

### The finding: the peer-death hash is necessary and NOT sufficient

**The third mutation is the one that taught something.** With nothing marked shared, the producer's
teardown really did release the region's four frames — a live use-after-free — and **the consumer's
re-read after peer death still produced the correct hash**, because nothing reallocated those frames
in the interval between the producer's exit and the consumer's second read.

So the milestone's headline assertion — *the bytes are still right after the creator died* — would
**not** on its own have caught a kernel with a use-after-free in it. What caught it was the **frame
accounting**: `PROC KILL … FREED` being 11 rather than 15, and `SHM DEAD … FREED` being 5 rather
than 1.

**Consequence, and it is a general one.** A retention property cannot be tested only by reading the
retained data, because a freed-but-not-yet-reused frame reads exactly like a retained one. It has to
be tested by counting. Any later harness that asserts "X survived Y" should carry both.

### What is checked by READING rather than by running, and is therefore weaker

`vmShmMap`'s signature and NX; `freeFrame`'s guard position and return value; the five pointer
validators' bodies; `procCleanup`'s release order; `procSpaceBuild`'s two clears; `shmSysGrant`'s
unconditional read-only; the four no-process guards (GAP-0239); `chanPeerId` touching no ring; and the
storage seam's call-site count. Each is a grep, and a grep can be satisfied by dead code — which is
why the mutation round above exists and why its results are written down rather than asserted.

### What is checked by NEITHER

* **A store through the read-only mapping** — GAP-0238.
* **Any preemptive interleaving of the two processes** — GAP-0236. The harness runs `proc coop`.
* **`shmRetNoSpace`, `shmRetNoMem`, `shmRetNoCap`, `shmRetNoTable` and `shmRetMapFail` have never
  executed on a boot.** They are reachable in principle — a third region, a drained allocator, a fifth
  capability, a failed table install — and no boot in this suite arranges one. `shmRetNoCap` is the
  cheapest to reach (a process creating five regions) and would be the first to add.

---

## GAP-0241 — Two M21 decisions are flagged for a human, and are shipped rather than blocked

**Domain:** memory model, syscall ABI (M21, ADR-0041 §10)
**Status:** OPEN — an escalation, recorded here so it is discoverable from the work queue rather than
only from an ADR nobody re-reads.

`CLAUDE.md`'s escalation rule names one of these by hand: *"memory layout that userland will
eventually depend on."* M21 makes exactly such a choice, plus one about the syscall ABI's shape. Both
are implemented and verified — the ladder is blocked without them — and both want confirmation
before a compositor protocol is written on top, at which point they stop being cheap.

1. **Ring 3 now has two windows**, `[0x10000000, 0x10200000)` for the load region and
   `[0x10200000, 0x10400000)` for shared regions, with `vmUserEnd` as the reachability bound. A
   region's address is a function of its SLOT, so it is the same number in every address space —
   which is the property a frame descriptor's offset depends on, and therefore the property userland
   will encode. `docs/design/memory.md` §1.3 recommends this shape, but that file is explicitly a
   proposal ("Status: DESIGN … nothing implemented"), so M21 promoted a proposal to a shipped memory
   layout on its own authority.
2. **`shmgrant` is the first syscall in this kernel that changes another process's state.** GAP-0201
   recommended a grant syscall in as many words, so the substance is not unilateral; the SHAPE is —
   four syscalls rather than two, a grant that is read-only and cannot be anything else, and a peer
   named through a channel endpoint rather than by process id.

ADR-0041 §10 has the full statement of each and what specifically to confirm.

---

## GAP-0242 — `DCDART_PIN.txt` is checked against a literal in a harness, never against the toolchain that actually built the kernel

**Domain:** build, conformance
**Status:** OPEN — **found by M21 the boring way: by noticing its own builds did not use the pinned
commit and that nothing anywhere objected.**

`DCDART_PIN.txt` exists to record "the DCDart commit this was last verified against" (CLAUDE.md's
documentation rules). One harness asserts it — `m7-frames`, with `[[ "$PIN" == <literal>* ]]` — and
that assertion compares **the file against a string in a shell script**. Nothing compares either one
against the DCDart checkout `build-kernel.sh` actually invokes.

**Measured during M21.** `DCDART_PIN.txt` says `38f0b06`. `build-kernel.sh` resolves
`DCDART_HOME="${DCDART_HOME:-$REPO_DIR/../DCDart}"`, which for a worktree under
`.claude/worktrees/<agent>` is `.claude/worktrees/DCDart` — a checkout sitting at **`f9676f2`, two
commits past the pin**. Every kernel M21 built, and every harness M21 ran, used `f9676f2`. The pin
file said `38f0b06` throughout and no check noticed, because no check looks.

**Why this is worse than it sounds.** The pin's whole purpose is reproducibility: "this kernel is
known to work against that compiler". A pin that is verified against a hardcoded string is verified
against nothing — it can only catch somebody editing one of the two files, which is precisely the
two-place-edit problem GAP-0232 already records from the other side. GAP-0232 is "the literal went
stale"; this is "even when the literal is fresh, it is not measuring the toolchain".

**PARTLY CLOSED at M21.** `build-kernel.sh` now prints the toolchain's identity on **every build**,
so it lands in every harness log:

```
build-kernel: toolchain /path/to/DCDart @ f9676f2 +DIRTY; DCDART_PIN.txt says 38f0b06
build-kernel: WARNING — the toolchain is NOT the pinned commit. ...
build-kernel: WARNING — the toolchain working tree is DIRTY, so 'f9676f2' does not identify it. ...
```

Three facts because all three vary independently: **where** the toolchain is, **what commit** it is
on, and **whether that commit is what is actually on disk**. `OSCORTEX_REQUIRE_PIN=1` makes either
mismatch fatal, and that should become the default the moment the pin and the toolchain agree — it is
a warning today only because a hard failure would take all 24 harnesses red for a reason that is not
theirs. `m7-frames`' literal can then go away entirely.

### The harder half, and it is NOT what this entry first assumed

The first version of this entry concluded "the pin is stale". **That is not established, and the
experiment that would have established it fails for a different reason.** Measured at M21:

| toolchain | result building the same kernel |
|---|---|
| `.claude/worktrees/DCDart` @ `f9676f2` **+ uncommitted edits** | **builds** |
| clean `git worktree` @ `38f0b06` (the pin) | `DccLowerError: no @bare top-level function found in kmain.dart` |
| clean `git worktree` @ `f9676f2` — **the same commit as the working one** | same error |
| clean worktree @ `f9676f2` **with the working tree's uncommitted diff applied** | same error |

Each fresh worktree was given the documented setup: the 211 MB vendored frontend copied in as **real
files** (a symlink is not enough — GAP-0110, dcc resolves library identity through real paths), and
`dart pub get` run in all six packages so every `.dart_tool` and `pubspec.lock` exists. Package
resolution was confirmed identical in shape to the working checkout's.

**So the pin is not proven bad; what is proven is worse.** A checkout of the *exact commit that
works* does not build. The working toolchain therefore depends on local state that **neither repo
tracks and the documented setup does not reproduce** — `core/frontend/` is gitignored by DCDart's own
ADR-0005/0007, and whatever else is missing was not found. A commit hash does not currently identify
a buildable DCDart, which is why `DCDART_PIN.txt` cannot mean what it says no matter how it is
checked.

**What closing THAT takes** is DCDart's to answer, not this repo's (CLAUDE.md rule 3): either a
`tools/bootstrap.sh` in DCDart that turns a bare checkout into a working toolchain and is itself
tested, or a recorded statement of exactly which untracked artifacts are load-bearing. Until then,
"verified against DCDart X" means "verified against the DCDart working tree that happened to be on
that machine", and this repo can only do what it now does: say so, loudly, in every build log.

**A caveat that is part of the finding.** `38f0b06` IS an ancestor of `f9676f2`, so nothing built
during M21 used a compiler older than the pin — the drift is forward, and the two intervening commits
are DCDart's own optimiser work. That is luck, not a property anything enforced.

### And it is worse than drift: the toolchain is a SHARED MUTABLE WORKING TREE

M21's last verification run failed to build at all, with

```
../../../DCDart/core/backend/lib/llvm_emit.dart:448:11: Error: The type 'DCInstruction' is not
exhaustively matched by the switch cases since it doesn't match 'ConstFloat()'.
```

because another agent was **mid-edit** in the DCDart checkout `build-kernel.sh` resolves to —
`core/dc-ir/lib/instructions.dart`, `core/backend/lib/llvm_emit.dart` and `core/dc-elide/lib/elide.dart`
all modified and uncommitted, adding a `ConstFloat` instruction. So the compiler this repo builds with
is not merely un-pinned, it is a **working tree that other work is actively changing**, and a kernel
build can therefore fail — or, much worse, SUCCEED DIFFERENTLY — for reasons that have nothing to do
with the change being tested and leave no trace in this repo.

**Why the "succeed differently" case is the dangerous one.** A build that fails is loud. A build that
picks up half of somebody's optimiser change and produces a subtly different kernel is silent, and
every byte-exact golden in this suite would then move for a reason no commit here explains. M21 got
the loud case and only noticed the shared-tree problem because of it.

**This makes the fix in the previous paragraph load-bearing rather than tidy.** Comparing
`DCDART_PIN.txt` against `git -C "$DCDART_HOME" rev-parse --short HEAD` is not enough on its own:
`git -C "$DCDART_HOME" status --porcelain` must also be empty, or the build must say out loud that it
is using a dirty toolchain. A pin names a commit; a dirty tree is not that commit.

**What M21 did about it, and what it could not do.** Every M21 result was produced with one kernel
image, `md5 75f8a81216c6585e89db80fa44c62247`, and that was checked rather than assumed: the two
comment-only edits made after the full sweep were each followed by a successful rebuild and a `cmp`
against the pre-edit binary, both byte-identical. So the sweep's results and the final tree describe
the same kernel. What M21 could NOT do is re-run anything after the breakage began, because no clean
DCDart checkout exists on this machine while that edit is in flight.

---

## GAP-0258 — A harness can fail a sweep on a QMP teardown race and pass alone

**Domain:** conformance, infrastructure
**Status:** OPEN — one observation, recorded because the next person to see it will otherwise spend
the morning on a kernel that is fine.

`m8-paging` FAILED in M21's full sweep and PASSED on its own re-run, with the same kernel image, no
edit in between. The failure was not a golden mismatch — the transcript in the failing run is correct,
`VM TEXT … W 00 X 11` and all — it was:

```
qmp-drive: wrote .../screen.txt
Traceback (most recent call last):
ConnectionResetError: [Errno 54] Connection reset by peer
M8-paging: FAIL — qmp-drive.py exited 1 for the session boot.
```

i.e. QEMU closed the QMP socket while the driver was still talking to it, **after** the driver had
already written the screenshot and the screen text. Everything the harness asserts had been captured;
the process died during teardown.

**Not GAP-0150.** That entry is the *launch*-side race — the port `pick-port.py` hands out being taken
between the probe and QEMU's bind — and `drive_session` already retries on `Address already in use`.
This is the *teardown* side and the retry does not cover it: the error text is different and the run
is not retried.

**Seen TWICE, on two different harnesses, which is what makes it a class rather than an anecdote.**
`m16-filewrite` failed the same way on its negative-control boot — `neg.png` and `neg/screen.txt`
both written, then `ConnectionResetError` — and passed on a straight re-run with no edit in between.

**The condition it was seen under** is worth writing down because it is the likely cause: three
agents running QEMU-heavy sweeps concurrently, load average **21**, on 8 cores. Both re-runs that
passed were done after the other agents finished, at load **2.3**. That is correlation from two
observations, not a proof, and it is recorded as the former.

**The tell that separates it from a real failure**, and the reason it is cheap to triage: the last
`qmp-drive:` line before the traceback is always a `wrote …` line. Everything the harness asserts has
already been captured; only the teardown handshake is lost. A real failure fails a `cmp` or a check,
and says so.

**What closing it takes.** `drive_session` already knows how to retry a boot; it would need to treat a
`ConnectionResetError` *after* the captures were written as a retryable launch failure rather than a
harness failure — or, better, `qmp-drive.py` should tolerate the socket going away once it has
everything it came for, since at that point there is nothing left to ask QEMU. The second is smaller
and does not re-run a two-minute boot to fix a one-millisecond race.
## GAP-0250 — Every mouse packet prints a line on COM1, and that is a milestone artefact rather than a design

**Domain:** kernel (D1)
**Status:** **OPEN — deliberate, and it is the evidence D1 is made of.**

`mouseComplete` calls `mouseReportPacket` on every decoded packet, so a boot in which somebody moves
the pointer produces one 62-byte serial line per packet. At a PS/2 mouse's default 100 samples per
second that is about 6 KB/s of COM1 traffic, and `uartPutc` polls the transmit-holding register with
an **unbounded** spin (GAP-0001) — so a fast enough pointer would spend most of an interrupt handler
waiting on a serial port.

**Why it is there anyway.** This is the first device whose whole purpose is *visible*, and the
milestone's binary exit criterion is that the kernel decoded *exactly* the movement it was given.
That claim is only checkable if the decode is written down somewhere a byte-exact assertion can read,
and COM1 is the only such place this kernel has. `d1-mouse` asserts twelve of these lines byte for
byte against a model derived on the host before the boot; without them the harness could assert the
accumulated position and nothing about how it got there.

**What closing it takes.** A trace flag in `mouseStore` (one word, already allocated as spare
capacity is not — the block is exactly twenty words and full), defaulting off, with `mouse trace on`
turning it on. That is one more word, one more `@rodata` command name, and a harness change to turn
tracing on before it injects anything. It was not done at D1 because the flag would have been a
switch with exactly one setting anybody used, and a switch nobody has ever flipped the other way is
not a tested switch.

**What it does NOT affect.** No harness other than `d1-mouse` injects a pointer event, so on the other
twenty-four this code never runs and no golden moves. The no-pointer control boot asserts exactly
that.

---

## GAP-0251 — The cursor does not track; it is drawn by the `mouse` command and left behind

**Domain:** kernel (D1)
**Status:** **OPEN — a real limitation, and ADR-0042 §6 is the reasoning.**

`mouseHandle` updates numbers. `shellMouse` draws pixels. So the arrow appears where the pointer was
when you typed `mouse`, it does not follow the pointer, and every `mouse` leaves an arrow behind at
the position it was drawn at — there is no erase.

**Why.** Blitting a cursor that tracks needs the pixels under the previous position saved and
restored. **There is no allocation in an interrupt handler**, the compiler forbids it, and this driver
does not work around it (CLAUDE.md rule 3's spirit: the honest fix is not a workaround here). A fixed
save buffer would be 12 × 16 × 4 = 768 bytes — 96 more `u64` words of `.bss`, nearly five times the
whole driver's state — for a feature no compositor will want, because a compositor composites rather
than blitting a cursor over a console.

**The cost, measured rather than asserted.** A screenshot of a session with several `mouse` commands
has several arrows on it. `d1-mouse` works around this by running `fb` — which repaints the whole
framebuffer — immediately before the single `mouse` that draws the arrow it asserts, so the twelve
pixels it reads back are the only cursor on the screen.

**What closing it takes.** Either the save buffer above, or — better and the direction
`docs/design/display-protocol.md` points — a compositor that owns the frame and draws the pointer as
part of composition, at which point this whole function is deleted rather than fixed. The second is
why the first was not built.

---

## GAP-0252 — Syscall 20 returns a packed `u64` whose coordinates are 16 bits, and that stops working above 65535 pixels

**Domain:** kernel (D1)
**Status:** **OPEN — and it is a shape that is meant to be replaced, not widened.**

`mouse` (syscall 20) returns `x | y<<16 | buttons<<32 | packets<<40`. One register, no arguments, no
pointer, no failure mode.

**What is fine about it.** 800×600 is the only mode `fb.dart` sets, the coordinates are clamped to it
in the driver, and one register means the kernel never has to validate a ring-3 address for this call
— `chan.dart`'s fourteen refusal codes are the evidence for how much work that honestly is.

**What is not.** Three things a real pointer interface has are missing and cannot be added to this
shape:

1. **A wider screen.** Sixteen bits per axis is 65535, which is far away, but a `u64` with four fields
   in it has no room for a timestamp, a wheel delta, or a modifier state, and those are wanted long
   before the resolution is.
2. **The wheel.** `WU`/`WD` are in the state block and are reported by the `mouse` command, and ring 3
   cannot see them at all. A program that wanted to scroll would have to be given another syscall.
3. **Events, not state.** This is a *poll* of a *level*. A program cannot see a click that happened
   and ended between two polls — only that the packet counter moved, which says something changed
   without saying what.

**What closing it takes, and it is not "make the fields wider".** `docs/design/display-protocol.md`
D2 is the milestone: a ring buffer of input events in `@bss`, and either a `read` of a device
descriptor or an `ioctl` on one (S0's `ioctl` already exists and ADR-0031 already has the bounce
buffer). At that point syscall 20 is deleted, not extended, and `docs/syscall-registry.md`'s row for
it goes with it.

---

## GAP-0253 — Every ring-3 program can see the pointer; keyboard focus is D9

**Domain:** kernel (D1 / D9)
**Status:** **NARROWED — keyboard focus is ADR-0062; the pointer is still a global poll.**

`mouseSysRead` refuses nobody. An M9 payload, an M10 `run` program and a process can all call syscall
20 and all get the same global device state. There is no notion of which program the *pointer*
belongs to. Keyboard focus is a compositor slot (`wmMetaFocus`); syscall 24 pops only for the
owner of that window while the slot is live.

**Keyboard half is answered.** ADR-0062 took §4.3's second option: the shell keeps the
keys when focus is 0, so a compositor that is off (or a window that has died) does not
take the keyboard with it. The pointer is still the original gap.

**What closing the pointer half takes.** The same word, or a sibling, saying which
process may read syscall 20. Not a driver change that invents a second policy.

---

## GAP-0254 — The `mouse` command is not in `help`, so it is undiscoverable from the shell

**Domain:** kernel (D1), documentation
**Status:** **OPEN — deliberate, for the reason M18 and M20 each declined the same line.**

`shellExecute` dispatches `mouse` and `mouse feed <hex>`, and `help` lists neither. Somebody sitting
at this shell has no way to find out the commands exist.

**Why.** `shellStrHelp` is **2224 bytes**, three harnesses pin that number, and **five byte-exact
serial goldens plus `m3-shell`'s screen golden contain the help text verbatim** (GAP-0105,
GAP-0115). One line moves six goldens by substitution. M18 added three commands with no help line and
M20 added none at all, both for this reason, so D1 following the same rule keeps the debt in one
place rather than paying a sixth of it.

**The debt is now five commands deep** (`proc`'s three from M18, and D1's `mouse` and
`mouse feed`), and that is worth saying out loud: the argument "one line is not worth six goldens"
gets weaker every time it is made, because the thing it is protecting — a help text that describes
the shell — is getting less true.

**AND SOMEBODY ELSE IS PAYING IT WHILE THIS WAS BEING WRITTEN, WHICH CHANGES WHAT CLOSING THIS
MEANS.** A concurrent branch is settling GAP-0142 and takes `shellStrHelp` from 2224 bytes to 2511,
regenerating the six goldens by substitution. So the mechanical work this entry describes is being
done once, by that branch, for its own commands — and D1's two lines are then **a two-line addition
to a text that has just been re-pinned**, not a sixth of a golden regeneration. The sequencing
matters: adding them here first would have collided with that branch in six goldens and one pinned
constant.

**What closing it takes, after that merge.** Two lines in `shellStrHelp`, a re-pin of whatever
`shellStrHelp` then measures, and the six goldens regenerated by substitution one more time. The
kernel is then required to reproduce the result byte-for-byte, which is what makes the substitution
safe. Sequence it AFTER the GAP-0142 work lands, never beside it.

**What `d1-mouse` asserts in the meantime, so this does not rot into a lie.** Two things: that
`shellStrHelp` is exactly 2224 bytes ON THIS BRANCH — a pin that MOVES at the merge described above —
and, separately, that the kernel's `.rodata` contains no help-shaped `  mouse ` line at all. The
second is the half that survives the merge, because the claim D1 is making is that *it* added no
line, not that nobody ever will.

---

## GAP-0255 — One IRQ12 per boot arrives with the 8042's output buffer empty

**Domain:** kernel (D1)
**Status:** **OPEN — understood, harmless, and NOT hidden.**

`mouse` reports `IRQ <n>` and `PKT <m>`, and on every boot measured so far **n is exactly
`4 * m + 1`**: one interrupt more than there were bytes to read. Measured on QEMU 11.0.0: 17 IRQs for
4 packets, 53 for 13.

**What it is.** `mouseEnable` sends `0xF4` (enable reporting) and *then* unmasks IRQ12. Between those
two, the device is free to put a byte in the controller's output buffer; the 8042 asserts the line,
the 8259 latches the edge while the line is masked, and when the mask is lifted the interrupt is
delivered — for a byte that `mouseEnable`'s own last `mouseRead` had already consumed. The handler
reads the status, sees OBF clear, and returns without reading the data port.

**Why that path is right rather than merely tolerated.** An unconditional `in` from 0x60 with OBF
clear returns *the previous byte again*, and the decoder would consume it a second time — which is one
byte of stream offset, i.e. exactly the desynchronisation the framing rule exists to recover from,
manufactured by the driver on every boot. The guard is the fix; the count is the evidence it fires.

**Why the count is reported instead of the guard being silent.** A spurious interrupt is a real event
on real and emulated hardware alike, and a driver that silently swallowed them could not tell one from
a thousand. `d1-mouse` therefore asserts `IRQ` is *present and hexadecimal* rather than exact, and
asserts `STRAY 00000000` exactly — because a **stray** (a byte that arrived with the AUX status bit
clear, i.e. a keyboard byte on the mouse's line) is a genuine defect and an empty-buffer interrupt is
not.

**What closing it takes.** Draining the controller between `0xF4` and the unmask, the way `kbdDrain`
does for the keyboard — which trades a known, counted, harmless interrupt for a bounded poll that
could itself swallow a real first packet. Not obviously an improvement, which is why it was measured
and recorded rather than "fixed".

---

## GAP-0256 — `m7-frames` was already red at `71cf08f`: it pins a DCDart commit that commit had moved

**Domain:** conformance harness (M7), pre-existing
**Status:** **OPEN, NOT D1'S, AND NOT D1'S TO FIX — recorded here because D1's sweep is where this
agent met it.**

`core/tests/conformance/m7-frames/run.sh` asserts `[[ "$PIN" == 8713298* ]]`. `DCDART_PIN.txt` at
`71cf08f` says `38f0b06`. The assertion cannot pass, and it fails four seconds into the harness —
before any boot, and **after** the `.bss` arithmetic, so everything a milestone-integration reviewer
would want from it still runs and still reports.

**Established without booting anything**, on the pristine `/private/tmp/oscortex-demo/src-71cf08f`
worktree: the pin file says `38f0b06` and the harness's own text says `8713298`. It is not
intermittent, it is not environmental, and it has nothing to do with the mouse: D1 changed neither
file's assertion, and `git diff` against `71cf08f` shows this harness gained exactly the twelve-line
`mouseStore` subtraction stanza and its assertion-floor bump and nothing else.

**So "24 harnesses green at `71cf08f`" is 23.** That is worth saying plainly rather than folding into
a pass count, because the premise every branch forked from is one harness weaker than it was
believed to be.

**Somebody else is already fixing it.** A concurrent branch working on recorded defects has this in
its own known-gaps as "m7-frames asserted a DCDart pin that commit 71cf08f had already moved, and was
red on the pristine tree", so the fix belongs there and D1 deliberately did not touch it — two
branches editing the same three lines of the same harness is exactly the collision
`docs/design/hot-files.md` warns about.

**One thing the fix should not miss.** The assertion appears **twice** in that file, at two different
line numbers, with the same text and the same hard-coded hash. Changing one of them leaves the other,
and the harness fails in the same way at a later line — which reads like a different defect.

---

## GAP-0257 — A new kernel file moves every golden that prints an absolute address, and D1 moved 23

**Domain:** conformance harnesses (every milestone with an address in a golden)
**Status:** **OPEN — structural, and it gets worse with every driver this OS gains.**

`core/kernel/mouse.dart` is ~1450 lines and 31 `@rodata` tables, so the kernel image grew by **three
4KiB pages**. Nothing about the mouse appears in any earlier milestone's transcript. These do:

* `VM SECT`, which prints `.text`, `.rodata` and image-end **absolute addresses**;
* `VM TEST RW/RO/NX ADDR` and the `PF CR2` lines under them — addresses of kernel objects;
* `PMM BASE`, and `PMM FREE`/`USED`, because the frame bitmap reserves the image and a bigger image
  reserves **three more frames**;
* every `ELF PAGE ... PA`, `PROC NEW ... PML4/PD/PT`, `VM CR3` and `ELF STACK FRAME`, because those
  are frames the allocator hands out **after** the image.

**Measured, not estimated.** `PMM BASE 0x14A1C8 -> 0x14D1C8`; `PMM FREE 0x7E8B -> 0x7E88` and
`USED 0x175 -> 0x178` — exactly three frames, exactly the three pages. **23 goldens across 12
harnesses moved, 376 lines in total, and not one line changed meaning.**

**That last clause is a CHECKED claim, not an assurance.** Regenerating a golden from a wrong kernel
enshrines the wrong output — `m11-proc`'s own comment says exactly that — so the regeneration was
gated: every removed/added line pair had every run of two or more hex digits masked out, and the two
were required to be **identical afterwards**. All 376 passed. A line that had changed *meaning*
rather than *address* would have failed that gate and been read by a human before anything was
accepted. The gate is in this milestone's working notes rather than in a harness, and **that is
itself a gap**: the next agent to regenerate has to rebuild it.

**Two harnesses could not be regenerated by their own `--regen` and needed handling.**
`m19-argv` has a `.bss` grand-total assertion that no other harness's shape matches, so it failed
before its boot until D1's block was added to its accounting (this was a real miss: D1's first pass
found the twelve harnesses that share one stanza and not this one). `m7-frames` failed on GAP-0256's
stale DCDart pin, four seconds in and before its own boot; its goldens were regenerated through a
temporary copy with **only** that one assertion removed, and the copy was deleted afterwards. With
that pin bypassed `m7-frames` passes in full — which is independent evidence that GAP-0256 is the
only thing wrong with it.

**What this costs the project, plainly.** Any new kernel `.dart` file of any size moves this set. A
driver is therefore never a self-contained change here, and the cost is a **merge hazard rather than
a correctness one**: two branches that each add a kernel file both regenerate the same 23 goldens,
and the merge cannot take either side — it has to rebuild from the merged kernel and regenerate once.

**What would close it, and it is not "stop printing addresses".** The addresses are load-bearing:
`m8-paging` reads back the page tables the kernel says it built, and `m10-elf`'s whole claim is that
the loader mapped the frames it named. What would close it is printing them **relative to a base the
same transcript reports** — which is exactly what `d1-mouse` does for the cursor, asserting the
pixels at `base + derived offset` rather than at a pinned absolute address, so its own golden does
not move when the image does. That is a per-harness change to roughly forty lines of kernel
diagnostics and their goldens, and it is a unit of its own.

---

## GAP-0259 — The kernel builds against whatever DCDart is at a fixed relative PATH, not against `DCDART_PIN.txt`

**Domain:** build (all milestones), toolchain discipline
**Status:** **OPEN — and it stopped a build dead during D1, which is how it was found.**

`DCDART_PIN.txt` says `38f0b06 2026-08-26`. `core/scripts/build-kernel.sh` resolves the compiler as
`DCDART_HOME="${DCDART_HOME:-$REPO_DIR/../DCDart}"` — **a path, not a commit**. So the pin is a claim
this repo makes about a toolchain it never checks, and the compiler actually used is whatever happens
to be sitting in that directory.

**Observed, not theorised.** During D1's final verification the sibling DCDart checkout was at
`f9676f2` — seventeen commits past the pin — **with six files modified in the working tree**
(`prelude.dart`, `llvm_emit.dart`, `lower.dart`, `elide.dart`, `instructions.dart`, `c_header.dart`),
because another agent was mid-edit on the compiler. The kernel had built and passed a full 25-harness
sweep against that directory forty minutes earlier and would not build against it at all afterwards.
Nothing in this repo changed between those two facts.

**Checking out the pinned commit is NOT a workaround, and that is the sharp part.** A `git worktree`
at `38f0b06` still fails, because Dart resolves `package:dc_ir` and friends through a
`.dart_tool/package_config.json` whose paths point back at the *shared* checkout — so a pristine
source tree is compiled with the dirty tree's packages, and the mixture fails in a way that looks
like the pinned commit being broken. `MEMORY.md`'s "stale `.dart_tool` cache" note is the same trap
seen from the other end.

**What is and is not affected.** Nothing about this repo's correctness: the kernel binary D1's sweep
tested is on disk and every boot result stands. What is affected is **reproducibility** — "verified
against `38f0b06`" is not something any check in this repo can establish, and a green sweep is
evidence about the compiler that happened to be in a directory at the time.

**What closing it takes.** `build-kernel.sh` reading `DCDART_PIN.txt` and asserting
`git -C "$DCDART_HOME" rev-parse HEAD` starts with it, **and** that the tree is clean — refusing
otherwise, with the override spelled out for the agent who is deliberately bumping the pin. That is
about fifteen lines and one new failure mode ("your DCDart is dirty"), and it would have turned
forty minutes of confusion into one sentence. The `.dart_tool` half needs a per-checkout
`--packages` or a `dart pub get` in the pinned tree, and is the harder half.

---

## GAP-0260 — DCDart now emits SSE for `.bss` zeroing, and this kernel's FPU story forbids it

**Domain:** toolchain, kernel correctness (cross-repo: the fix is DCDart's)
**Status:** **RESOLVED IN DCDart, same day, by the unit that caused it.** Kept as a record because
the mechanism is worth not re-deriving, and because §"what unblocks it" became a real fix rather than
a wish. Not a defect in any oscortex commit at any point.

**The fix, in DCDart:** `compileToObject` gained a `noFpRegs` flag that passes
**`-mgeneral-regs-only`**, wired from `target.isFreestanding && !options.allowFp` in `pipeline.dart`
— derived from the target exactly as `noRedZone`/`-mno-red-zone` already was (ADR-0039's shape), with
`--allow-fp` as the deliberate opt-in for a `@bare` program that genuinely wants floating point and
accepts the FPU-state obligation.

**Their measurement is worth carrying here**, because it kills the fix I would have reached for first:

```
(baseline)                          xmm=9
-fno-vectorize -fno-slp-vectorize   xmm=5     <- NOT enough
-mprefer-vector-width=0             xmm=9     <- does nothing
-mgeneral-regs-only                 xmm=0
```

Disabling the vectorisers leaves the `memset` that loop-idiom recognition forms, which is then
expanded with vector stores anyway. **Only forbidding the register class removes all of it.**

**Verified from this side**: `kernel.elf` rebuilt with the fixed toolchain contains **0** `%xmm`
instructions and `m11-proc` PASSES again. The kernel's md5 moved a third time
(`75f8a81…` → `32a2425…` broken → `ff9a4ca…` fixed), because `-mgeneral-regs-only` changes
instruction selection throughout — so the byte-exact goldens moved legitimately this time and were
regenerated against the fixed compiler, not the broken one.

**The one thing that did NOT get fixed by this** is GAP-0242: the toolchain is still an untracked,
mutable working tree, and this whole episode — a correctness regression appearing and disappearing in
one afternoon with no commit in either repo naming it — is what that entry is about. The SSE bug is
closed; the reason nobody noticed it for a whole rebuild cycle is not.

**What happened, measured rather than inferred.** Commit `d2bfef7` — M21, unchanged, which passed a
full 24/24 sweep this morning — was rebuilt this afternoon with no edit of any kind:

| | this morning | this afternoon |
|---|---|---|
| `kernel.elf` md5 | `75f8a81216c6585e89db80fa44c62247` | `32a24251928fbf4f926ce61820b11f19` |
| `%xmm` instructions in the linked kernel | **0** | **275** |
| `m11-proc` | PASS | FAIL |

The only thing that changed is the DCDart working tree `build-kernel.sh` resolves to, which another
unit is editing in place (floating point: `ConstFloat` in DCIR, `f64`/`f32` in the prelude, ADR-0065).

**What the 275 instructions are, and why they appear.** `170 movups`, `58 movaps`, `47 xorps` — the
shape LLVM produces when it **vectorises a zeroing loop**:

```
chanInit:
    xorps  %xmm0,%xmm0
    movups %xmm0,0x0(%rax)
    movups %xmm0,0x0(%rax)
```

That is `chanInit` clearing its own `@bss` block. Every subsystem's `*Init` does the same loop, which
is why the count is in the hundreds and spread across `argsCollect`, `chanInit`, `elfInit`,
`fatDirCreate` and the rest. **No oscortex source changed**; the backend simply started allowing SSE
where it previously emitted integer stores only.

**Why it is a correctness failure here and not a performance question.** `m11-proc` asserts the
kernel contains **zero** `%xmm` references, and ADR-0015 §2 is why: `procYield` saves a process's FPU
state **after several hundred instructions of kernel code have already run**. That is only sound while
the kernel itself never touches an XMM register. With 275 of them — in `chanInit`, in `elfInit`, on
paths a syscall reaches — a process's FPU state can be clobbered by the kernel between the trap and
the save. The harness is right and the kernel is now wrong.

**The fix is DCDart's, not this repo's** (CLAUDE.md rule 3: never build a workaround here for a
DCDart-language gap). A `@bare` freestanding target must not emit SSE at all — the backend needs the
equivalent of `-mno-sse` / soft-float for bare mode, or at minimum a way for this kernel to say so.
Working around it here would mean hand-writing every `*Init` to defeat the vectoriser, which is both
fragile and exactly the kind of workaround rule 3 forbids.

**What this repo did about it.** Nothing that would hide it:

* the regenerated goldens were **thrown away, not committed**. Regenerating against this toolchain
  would have written a kernel with 275 SSE instructions into twelve byte-exact goldens and turned a
  loud failure into a silent one — which is the exact failure `--regen` is most able to cause
  (GAP-0095's warning, and the reason `--regen` still runs every derived check);
* the regen sweep was stopped as soon as the cause was known, so only `m7`–`m15` were touched and
  all were reverted;
* `build-kernel.sh` already prints the toolchain's commit and dirtiness on every build (GAP-0242),
  which is how this was caught in one step instead of being blamed on B1's IRQ4 work.

**This is GAP-0242's "dangerous case", and it has now happened.** That entry said: *"The loud case is
a broken build. The dangerous case is a build that succeeds against half of somebody's compiler change
and produces a subtly different kernel, and every byte-exact golden in this suite would then move for
a reason no commit here explains."* It did, they would have, and the only reason it was not written
into the goldens is that `m11-proc` fails loudly on an invariant that has nothing to do with
addresses. **Without that one check, this would have been a silent 12-golden regeneration.**

**What unblocks it:** DCDart stops emitting SSE in `@bare` mode, or `DCDART_PIN.txt` is honoured by a
toolchain that does not — and per GAP-0242 there is currently no way to reconstruct such a checkout
from a commit hash, which is why that entry is the prerequisite for this one.

---

## GAP-0261 — A security test evaporated: `vmtest ro`'s faulting store was optimised away, and this kernel uses `Volatile` nowhere

**Domain:** kernel, conformance, toolchain seam
**Status:** **FIXED for `vmTestRo`. OPEN as an audit** — the one instance was found by a harness; the
class was not searched for.

**What happened.** DCDart's ADR-0069 split device access (`Volatile<T>`) from ordinary access
(`Pointer<T>`) and made the latter **plain**, so `-O2` may now delete, reorder or coalesce it. The
first oscortex build after that change deleted this line outright:

```dart
Pointer<u8>.fromAddress(a).value = u8(0xFF);   // vmTestRo
```

It is a store nothing reads — the canary is checked through a different path — so as an ordinary
store it is dead and LLVM removed it. `vmtest ro` then printed **SURVIVED with the canary INTACT**:
the fault never happened *and* the write never landed.

**Why that is the worst possible failure shape.** Those two facts together read as "W^X is broken"
and are in fact "the test evaporated". `m8-paging` is the harness that proves GAP-0050 closed and
ADR-0012's W^X real; a deleted store makes it prove nothing while still looking like a test. Had the
store been deleted in a build where nobody ran `m8-paging`, the suite would have gone green with the
W^X demonstration silently absent.

**The fix is in this repo and it is not a workaround.** The store exists ONLY for its side effect —
taking a #PF — which is exactly what `Volatile` means: *this access IS the observable behaviour*. So
`vmTestRo` now uses `Volatile<u8>`. Verified: the `movb` is back in `vmTestRo`'s codegen and
`m8-paging` PASSES.

**What was NOT done, and is the open half.** **This kernel contains no other use of `Volatile<T>`
anywhere** — `grep -rn "Volatile<" core/kernel/` found exactly the one line this entry adds. Every
memory-mapped access in the kernel predates ADR-0069 and is therefore an *ordinary* access that the
optimiser is now free to delete, reorder or coalesce. The obvious candidates:

* **`fb.dart`'s framebuffer writes.** Pixels are written and never read back by the kernel, which is
  the same dead-store shape as `vmTestRo`. They appear to survive today (`m5-pci` reads pixels back
  out of guest memory over QMP and passes), most likely because the addresses vary through a loop —
  but "the optimiser did not happen to do it" is not the same as "it may not".
* Anything else writing to a device or to memory whose reader is the hardware.

**What closing it takes:** an audit of every `Pointer<T>` access in `core/kernel/` against the
question ADR-0069 actually asks — *is the ACCESS the observable behaviour, or the VALUE?* — and
`Volatile<T>` wherever the answer is the access. That is a reading task over ~20 files and it is
worth doing deliberately rather than one harness failure at a time, because the failure mode is a
test or a device write that silently stops happening.

**And a note on how this was found**, because it argues for the practice: it was not found by
reading the ADR-0069 change and reasoning about consequences. It was found because a byte-exact
harness with a two-sided control (`SURVIVED` must not appear; the canary must not change) failed in a
way that could not be explained by addresses moving.

---

## GAP-0262 — One-byte `@rodata` tables are constant-merged away, and two harnesses assert them by name

**Domain:** toolchain seam, conformance
**Status:** OPEN — narrow, precisely bounded, and NOT a defect in any kernel source.

**Measured.** After the DCDart change of 2026-08-27, `x86_64-elf-readelf -sW kmain.o` no longer
contains `argsStrSp` or `fbStrBy`. Both are **one byte long**:

```
argsStrSp   args.dart   1 byte   0x20  (a space)
fbStrBy     fb.dart     1 byte
```

LLVM has constant-merged them into an identical byte elsewhere in `.rodata`. The BEHAVIOUR is
unaffected — `Rodata.addressOf(argsStrSp)` still resolves to an address holding `0x20` — but the
SYMBOL is gone, and two harnesses look the symbol up by name to check its size:

* `m19-argv`  → `argsStrSp not found in kmain.o`
* `m5-pci`    → `fbStrBy not found in kmain.o — a @rodata table M5 depends on was not emitted`

**The blast radius is exactly three tables and it was enumerated rather than guessed.** Of every
`@rodata` table in `core/kernel/`, ten are 1–2 bytes and only the **three one-byte** ones can merge:
`procStrGap`, `argsStrSp`, `fbStrBy`. The two-byte tables survive. `m1-interrupts` — which asserts
that every table is in `.rodata` and that they abut with no padding — **PASSES**, so this is not a
general breakdown of the `@rodata` contract; `m3-shell` and `m13-libc` pass too.

**Why the check being defeated matters, rather than just being noisy.** `check_table` exists for
GAP-0060: a table and the length its `uartWrite` call site passes are two numbers, and a table that
grew without its call site growing prints the NEXT table's bytes. For a merged table that check can
no longer run at all — so those two tables lose a guard, silently, and the harness reports it as
"not emitted" which is the wrong diagnosis and would send the next reader looking in the wrong place.

**AND DCDART ALREADY DECIDED THIS SHOULD NOT HAPPEN**, which changes what kind of entry this is.
`core/backend/lib/llvm_emit.dart`'s `_emitGlobal` says, in a comment written long before today:

> Deliberately NOT `unnamed_addr`. That moves a global into a mergeable section (verified:
> `.section .rodata.cst8,"aM",@progbits,8`), which lets the linker collapse two byte-identical
> globals to ONE ADDRESS. Harmless for name strings; **catastrophic for anything whose address
> means something**.

So the merging is **a regression against DCDart's own stated intent**, not a design choice this
repo has to accommodate. Whatever is collapsing these globals is doing it despite `unnamed_addr`
being withheld on purpose — which means the cause is somewhere else (a `-O2`/globalopt pass, or the
linker) and is worth finding rather than working around. That reframes option 1 below from "please
change your design" to "your design says this, and it is no longer true".

**Three ways to close it, and the preference is the first:**

1. **DCDart stops merging `@rodata` tables** — they are a load-bearing named ABI in this project
   (harnesses assert them by name and by size), so the symbols should survive. This is the right fix
   and it is DCDart's, because `@rodata`'s contract is DCDart's.
2. Pad every one-byte table to two. Cheap, and it makes the fix invisible to anyone reading the
   kernel later — a table whose size is a workaround for a linker behaviour is a trap.
3. Teach `check_table` to skip tables it cannot find AND say so loudly. Weakens two guards and is the
   worst of the three; recorded only so nobody reaches for it thinking it is the easy one.

**Not fixed here** because the choice belongs with whoever owns `@rodata`'s contract, and because
patching two harnesses to accommodate a compiler behaviour that may itself be transient is how a
suite stops meaning what it says.

## GAP-0264 — Three numbering collisions in one merge: syscall 16, GAP-0263, and a citation to a GAP that does not exist

**Domain:** docs (syscall-registry, known-gaps), kernel (mouse.dart), conformance (d1-mouse)
**Status:** **syscall 16 RESOLVED here; GAP-0263 OPEN against `b1-live-console`; the dangling citation OPEN against `merge-d1-m21`.**

Four branches forked from `71cf08f` and were merged here in one pass. Each allocated numbers from
the same free pool without being able to see the others, and three of those allocations collided.
They are recorded together because they are one defect with three faces: **a number is an
allocation, and this repo allocates on branches that cannot see each other.**

### 1. Syscall 16, claimed twice — RESOLVED

`d1-ps2-mouse` gave `mouse` 16 (ADR-0042). `m21-shared-frame` gave `shmcreate` 16, `shmgrant` 17,
`shmmap` 18 and `shmdrop` 19 (ADR-0041). Both were correct on their own line; 15 was the highest
allocated number at the fork.

**The kernel constants MERGED CLEAN.** `const int mouseSysNo = 16;` lives in `mouse.dart` and
`const int shmSysCreateNo = 16;` lives in `shm.dart`, so git had no textual conflict to report. Only
`docs/syscall-registry.md` conflicted, and only because both branches happened to edit the same
table. This is precisely the shape `docs/design/hot-files.md` §5.1 records: **a duplicate syscall
number merges clean, builds clean, boots clean and mis-dispatches.**

`core/scripts/verify-syscall-registry.sh` is what caught it, on a tree that had already built:

```
syscall 16 is in the registry twice
core/kernel/shm.dart declares shmSysCreateNo = 16 and the registry has no row for it
verify-syscall-registry: FAIL — the syscall registry, the kernel and oslibc.h disagree
```

**Resolution: M21's contiguous block of four keeps 16–19 and D1's single call moves to 20** — the
same rule M20's three moved under, *the cheaper move is the correct one and the number is not the
interface*. Moved together, and `verify-syscall-registry.sh` is the proof they moved together:
`mouseSysNo`, `d1-mouse/prog.c`'s private `SYS_MOUSE`, `d1-mouse/run.sh`'s two assertions, the
registry row, ADR-0042 §7 and GAP-0252.

**This was resolved independently and identically on `merge-d1-m21`,** by another agent that hit the
same collision on a different integration line. Two lines reaching 20 by the same argument is the
registry doing its job.

### 2. GAP-0263, claimed twice — OPEN against `b1-live-console`

| branch | GAP-0263 |
|---|---|
| `mmio-volatile-migration` (merged here) | three goldens embed the kernel's own section boundaries |
| `b1-live-console` (**unmerged, live**) | `recv` works and is not in `help` |

`b1-live-console-volatile` — the branch merged here — does **not** carry GAP-0263; it was added to
`b1-live-console` afterwards, in `b6aa027`. So this tree is self-consistent and the collision has
not landed yet. **It will the moment `b1-live-console` merges.** The migration's GAP-0263 is the
earlier claim and is now merged, so `b1-live-console`'s must become **GAP-0265** on the way in.
Recorded here rather than fixed there because `b1-live-console` is another session's live branch and
rewriting it underneath that session is how the next collision gets made.

### 3. A citation to a GAP that does not exist — OPEN against `merge-d1-m21`

`merge-d1-m21`'s `syscall-registry.md` says *"GAP-0260 records the collision itself"*. That branch
has no `## GAP-0260` heading. On **this** line GAP-0260 is already taken (DCDart emits SSE for
`.bss` zeroing), which is why the collision is recorded here as GAP-0264 instead. A citation is a
reference to an allocation, and it can dangle the same way a number can collide.

### What would have caught these earlier

`verify-syscall-registry.sh` caught #1 and is the model: **an allocator with a checker.** Nothing
plays that role for GAP or ADR numbers — they are allocated by reading the tail of a file on one
branch. The check that found #2 and #3 was written for this merge and is not committed anywhere: for
every number, collect its heading across every branch and every worktree and require agreement. That
is a small script and it belongs beside the syscall one.

---

## GAP-0300 — The compositor is in the kernel, and it is there because moving it is a later ADR

ADR-0050. D3 (ADR-0053) now exists: `proc spawn` leaves a process live at the prompt. The
compositor is **still** `core/kernel/wm.dart`. Resident processes make the *move* expressible;
they do not perform it. The protocol (ADR-0051) does not change when it does.

**What that actually costs, itemised, because "it should be a process" is easy to say and the cost is
not obvious:**

* **Compositor policy is kernel policy.** Stacking order is "the newest surface is on top", it is one
  line in `wmAttach`, and ring 3 cannot change it. `display-protocol.md` §0.1 is explicit that window
  management is compositor policy and not protocol — so this is policy in the wrong *place*, not
  policy in the protocol. See GAP-0302.
* **A misbehaving compositor is a kernel bug**, not a dead process. There is no restart.
* **The composition loop runs with the caller's page tables installed.** It does not use them — it
  reads a region's frames by physical address through `shmRegVec` — but it is on the caller's stack
  and inside the caller's syscall, so a compositor fault is a ring-3 process's fault.

**What it does NOT cost, and this is the part worth keeping visible:** nothing about the *protocol*.
The descriptor is a legal `chan` message carrying no address (ADR-0051 §2, §3), so moving the
compositor to ring 3 under D3 changes who reads the eight words and nothing else. **The final blit
was always going to be a kernel operation** — ring 3 cannot execute `out`, `m9-ring3` asserts the TSS
has no I/O bitmap, and `display-protocol.md` §3.1 settled that before any of this existed.

---

## GAP-0301 — Damage is carried, validated and printed, and then a full frame is composed anyway

**Status:** RESOLVED by ADR-0052 (D6). A commit paints the damage rectangle, and
`d2-compositor` requires the 16×16 present to print `00000100` pixels, not
`00075300`. Full-surface damage paints the decorated window (border included);
`wm on` / `wm draw` still compose a full frame, because they have no damage to
honour.

**What remains, and it is a shape not a skip:** the dirty region is a bounding
box, not an exact region. `display-protocol.md` §3.5 says an exact region needs a
data structure `@bare` DCDart cannot express yet. A one-pixel present in the
corner of a window still paints a box; it does not paint 480,000 stores.

The per-buffer trap in that same section does not apply: this compositor writes
the visible scanout in place and does not flip (ADR-0052 §3). If a flip lands,
the union-of-both-buffers rule has to be built and this entry reopens.

---

## GAP-0302 — Window move exists; what does NOT is anything else a window manager does

Superseded in part. A left click raises the window under the pointer and a drag moves it, from the
IRQ12 path, with a damage-limited repaint (`wmGrab`, `wmDragStep`, `wmPointerTick`; ADR-0050 §D5b).
`d2-compositor` asserts the raise and the drag as **pixels in a second framebuffer dump taken from the
same boot**, with the moved origin derived on the host from the grab offset and the clamp.

**What is still missing, and it is most of a window manager:**

* **Chrome has started (ADR-0056): a 24-pixel bottom strip, off by default, compositor-drawn,
  compositor-consumed clicks.** `wm chrome` turns it on. **Title bars have started
  (ADR-0075): an 18-pixel compositor-drawn caption on the top of each window's
  content, colour `0x00D8B060`, on only with `wm chrome`.** A press on the caption
  still raises and still starts a drag. A **right-click popover has started
  (ADR-0070 / OSXUI1): 96×64 pixels near the pointer, colour `0x00C04088`, on whenever
  the compositor is on.** Right-click does not start a drag and does not enqueue a client
  click. Left-click or a click elsewhere dismisses it. **Close, minimise, start/spotlight,
  and a reflection panel landed behind `wm de` (ADR-0106 / `de-chrome`).**
  **Title-drag under `wm de` landed (ADR-0111 / `de-wm/`):** a caption
  press moves the origin; a body press does not. **SE-corner resize
  under `wm de` landed (ADR-0121 / `de-resize/`):** geom w/h change,
  same shm, clip. Configure and enter/leave under `wm de` are
  ADR-0142 (`de-cfg/`). Growing the shm past the attach region is
  ADR-0150 (`shm-grow/`, syscall 34). Keyboard focus is D9 (ADR-0062): a click names the window that may pop
  syscall 24. A client is told about a left press (ADR-0055) and,
  under `wm de`, about place / move / resize / enter / leave
  (ADR-0142). A
  damage pass does not paint the taskbar strip; only a full compose does. The popover
  and the title strip are in `wmPixelAt`, so a cursor erase does not punch a hole
  in them.
* **Middle is still ignored.** Right is the popover (ADR-0070). Bit 0 is still the only
  button that raises, drags, or enqueues.
* **A drag is bounded by the client's hold.** D3 lets a client be `proc spawn`ed and stay live at
  the prompt, but `d2-compositor` still launches through `proc run` and so still has to drag inside
  that session's busy spin. The drag path itself does not care which command created the process.
* **The repaint is a rectangle, not a region.** A drag step paints where the window was and where it
  is, as two full rectangles, so a one-pixel move costs two window-sized repaints (81,672 pixels for
  a 240×160 window). The harness asserts only that this is *less than a full frame*. A real
  implementation subtracts the intersection; that is region algebra, and `display-protocol.md` §3.5
  says an exact region needs a data structure `@bare` DCDart cannot express yet.

## GAP-0303 — A client pays for its own composite, inside its own syscall

`wmOpCommit` composes and then returns, and the return **is** the release (ADR-0051 §1.1). That is
the only shape available: nothing on this machine can block (GAP-0141), so telling a client later
needs a queue, a wakeup and a sixth process state, none of which exist.

The cost is that a `wmsurface` commit still runs **on the calling process's time**, on its stack,
with interrupts on but the scheduler not consulted. D6 (ADR-0052) cut the bill from 561,672 stores
to the damage rectangle — 256 for the 16×16 present `d2-compositor` asserts — but a client that
commits a full surface still pays for a decorated window, and a client that commits in a tight
loop still starves its peer without ever yielding.

The honest remaining fix is a compositor that is not a syscall, which is D3.

---

## GAP-0304 — `wm` is not in `help`, so it is undiscoverable from the shell

The same choice D1 made for `mouse`, for the same reason and with the same cost. `shellStrHelp` is
2511 bytes and appears verbatim inside five byte-exact serial goldens plus `m3-shell`'s screen
golden (GAP-0105, GAP-0115), so one line moves six goldens by substitution. M18 added three commands
with no help line and M20 added none at all.

`wm`, `wm on`, `wm off` and `wm draw` are therefore documented in ADR-0050, in `wm.dart`'s header and
in this file, and nowhere a person sitting at the machine can find them. `d2-compositor/run.sh`
asserts the *absence* of a help line, so adding one is a deliberate act that moves six goldens rather
than an accident that moves them silently.

---

## GAP-0305 — `m21-shmem/build-progs.sh`'s syscall detector reads a stale `%eax`

Not a kernel gap; a harness one, found by copying the check and having it fail.

`m21-shmem/build-progs.sh` decides which syscalls a program issues by tracking the most recent
`mov $imm,%eax` before each `int $0x80`. **`xor %eax,%eax` is `mov $0,%eax`** and clang emits it for
`SYS_EXIT`; the regex does not match it, so the detector reads the syscall number off whatever *last*
wrote `%eax` — which in `d2-compositor/prog.c` is a 32-bit diagnostic code an exit-on-failure path
builds, and the check reported the program issuing "syscall 3523215363".

`d2-compositor/build-progs.sh` recognises the `xor` form. **`m21-shmem`'s copy has not been changed**,
because it is green as it stands: M21's program happens to get a literal `mov $0x0,%eax` from clang
at that site, so its detector is correct by luck rather than by construction. It will report a
nonsense number the first time that codegen changes, and the failure mode is a build check that
*rejects* a correct program rather than one that accepts a wrong one — loud, not silent, which is why
this is recorded rather than fixed across a file another line is editing.

---

## GAP-0306 — A window dies with its client, because the compositor holds no capability

`wmWindowUsable` checks, on every painter, that the region a window was attached to is still live
**and still the same generation**; `wmReap` closes the window if it is not. Without it the first
pointer packet after `PROC END` read a freed page as a frame vector and the machine took a
`FAULT 0D` at the shell prompt. That was found by running a drag past the end of the clients' hold,
and it is the reason the check is at the top of every painter rather than on a teardown path.

**The gap is not the check, it is what the check reveals: this compositor cannot outlive its
clients' pixels.** A region dies with its last capability (`shm.dart`), the compositor holds none —
ADR-0050 §4 records that reading the frame vector rather than mapping the region was a deliberate
choice — so the instant a client exits, its window's pixels are back in the frame allocator.

**Sit-in / `d3-session` does not close this.** Those clients `proc spawn` and never exit, so the
region stays live for the same reason the process does (ADR-0053). That is option 3 deferred: the
window survives because nobody disconnected. `sit-in.sh` used to `proc coop` the d2-compositor
clients; they exited after the hold and the next painter printed `WM REAP`. The compositor still
holds no capability. Option 1 is still unbuilt.

Three ways out, none of them free, and the choice belongs with D3 rather than here:

1. **The compositor takes a capability.** It would need a process identity to hold one in
   (`shmgrant` installs into a process slot), which is D3. Not taken: windows stay only while the
   resident client lives.
2. **The compositor keeps a copy.** 153,600 bytes per window against a kernel mutable-static total of
   22,336 — so it is a frame-allocator allocation with a lifetime nobody has designed.
3. **The window closes, which is what happens now when a client exits.** Honest, and it is what a compositor does when a
   client disconnects. What is missing is that nothing *tells* anyone: the screen still shows the
   composed pixels until the next paint, because the framebuffer is not repainted on reap.

**That last sentence is a real inconsistency and it is deliberate.** `wmReap` closes the window and
does NOT repaint, so a boot that ends with two windows on screen keeps showing them after both
clients have exited — which is what `d2-compositor`'s screenshots are taken during, and it is why the
harness's second dump happens while the clients are still holding. Repainting on reap would be one
line and would make the screen go blank at the end of every run; leaving the last frame up is what a
person looking at the QEMU window wants, and it is recorded here rather than defended as a design.

---

## GAP-0307 — The compositor's re-entrancy guard is one word, and on two cores it is a lock

`wmMetaBusy` is set by every painter and checked by `wmPointerTick`, which returns without painting
if it is set. On this single-core kernel that is a real mutual exclusion: the interrupt gate clears
IF, so the tick's test-and-return cannot itself be interrupted, and there is no second CPU to observe
a stale value.

**On two cores it is a data race**, in exactly the shape `chan.dart`'s publication point is
(GAP-0205): the store that sets the flag and the loads that follow it need release/acquire ordering,
and the test-and-set needs to be atomic. It becomes a real lock — one `lock cmpxchg` — and the
interesting part is that the *pointer tick must still not block on it*, because it runs in an
interrupt handler. A tick that could not take the lock would still have to drop the frame, so the
behaviour this gap describes is the behaviour a correct SMP version keeps; only the mechanism
changes.

`wmMetaDropped` counts the ticks that were dropped, and `wm` prints it, so "how often does this
actually happen" is a number rather than a worry. In `d2-compositor`'s boot it is 0.

---

## GAP-0308 — A client is never told configure or enter/leave

**Status:** CLOSED — ADR-0142 (`tests/conformance/de-cfg/run.sh`).
Under `wm de`, attach / move / resize enqueue type 2 (configure)
on the existing press queue; a focus change enqueues enter/leave.
Syscall 25 is still `wmevent`. 11 stays `fdwait`. Without `wm de`
the ring is still press-only (`d7-click`).

**Narrowed at D7 (ADR-0055).** A left press on a window is enqueued for that window's
owner and popped through syscall 25 `wmevent`, with surface-relative coordinates.
`d7-click` asserts the top client in an overlap reports the derived point and the
bottom client reports nothing; a desktop click is reported by neither.

**Keyboard-focus closed at D9 (ADR-0062).** `wmMetaFocus` is a spare compositor
word (index 20, plus-one). A click on a window focuses it; a desktop click or a
reap returns keys to the shell. `kbdqDrainToShell` skips while focus is live;
syscall 24 `kbdevent` pops only for the focused window's owner. `d9-focus`
asserts the focused client reads the derived make+break sequence and the
unfocused client prints NONE. Escape is not special.

**Configure and enter/leave closed at ADR-0142.** Types 2/3/4 on the
same ring. `de-cfg/` asserts the client pops the host-derived attach
geom, the host-derived resize geom, ENTER on focus, and LEAVE on a
desktop click. A second boot without `wm de` still attaches and the
client pops NONE.

**Leftover:** growing the shm past the attach region (a new region,
not a new syscall). `unlink` / `rename` (APP4 / `m23-unlink`) is
the next named leftover after this gap. Not Flutter. Not `fdwait`.

---

## GAP-0309 — Serial type-ahead is still dropped, and that is a second input path

**Domain:** kernel (D2)
**Status:** **OPEN — accepted for this milestone, not forgotten.**

ADR-0054 put PS/2 keystrokes on a ring. COM1 still calls `shellKey` from `shellSerialIrq` when
`shellState == 0` and drops the byte when a command is running. Putting a UART byte on the same
ring would make syscall 24 return something that is not a scancode, and inventing a second ring
for serial is a different milestone.

**What it costs.** Type-ahead from a serial console during `ticks` or `proc run` is still lost.
A program that reads `kbdevent` never sees a character that arrived on COM1. The two paths agree
on the line editor's alphabet (CR→LF, DEL→BS) and disagree on whether a key waits.

**What closing it takes.** Either a serial-to-scancode translator nobody has asked for, or a
second ring with its own syscall, or `fdwait` plus a `/dev/cons` that is not this file's to design.

---

## GAP-0310 — A1 boots aarch64 virt; that is not an ARM64 port

**Domain:** boot, kernel (ARM64 A1)
**Status:** OPEN — A1 is green (`docs/decisions/0057-a1-aarch64-virt-proof-of-life.md`,
`tests/conformance/a1-boot/run.sh` PASS). Everything above A1 is unstarted.

A `@bare` `kmain_virt.dart` linked with `boot-arm/boot.S` boots under
`qemu-system-aarch64 -M virt-11.0`, prints `OSCORTEX A64 OK\n` on the PL011, and shuts the
guest down with PSCI `SYSTEM_OFF` (QEMU exit 0). `dcc --target bare-aarch64` was verified to
emit an aarch64 ELF, not assumed from the design doc. The x86 kernel and its harnesses were
not edited.

**What A1 worked around, and the cost:**

1. **The PL011 address is a literal `0x09000000`.** A2 is the device-tree walk. A QEMU that
   moves `pl011@9000000` fails this golden rather than being discovered. The machine is pinned
   to `virt-11.0,gic-version=2` for that reason.
2. **`hvc` / `mrs` / `msr` still cannot come from DCDart.** PSCI lives in `boot.S` behind
   `@extern psci_system_off`. That is fine for halt. It is not fine for `CNTPCT_EL0`,
   `VBAR_EL1`, `TTBR0_EL1`, or anything A4/A5 need to read at runtime. This is the design
   doc's second-largest open question and it is still DCDart's.
3. **A0 is still DCDart's file.** There is no `core/tests/conformance/bare-aarch64/` in the
   DCDart repo. Dart 3.12.2 unblocked `dcc`; the registry comment's "adding a target means
   adding a conformance target" rule is still unpaid.
4. **Two library roots were not tested.** `kmain_virt.dart` does not `part` any x86 file.
   Whether DCDart accepts one file as `part of` two library roots in two `dcc` invocations
   is still the first thing a later rung that wants to share `fat.dart` must check.
5. **PL011 `UARTFR.TXFF` is the opposite polarity of the 16550 `LSR.THRE`.** Copying the x86
   wait hung the guest (exit 124, empty serial). Recorded so A3 does not rediscover it when
   `uart.dart`'s interface is put in front of this driver.

**What a real port still does not have** (A2–A9, named so this entry cannot be read as
"ARM64 is started, therefore those are close"):

| missing | why it is not A1 |
|---|---|
| Flattened device tree in `x0` | RAM base, UART, GIC, ECAM all come from it; A1 hardcodes the UART |
| GIC + vector table (`VBAR_EL1`) | no IRQs, no faults reported |
| ARM generic timer (`CNTPCT_EL0`) | blocked on `mrs` from DCDart, or an asm call per read |
| TTBR0/TTBR1, 4 KiB granule, `SCTLR_EL1` | MMU is off; identity is luck, not policy |
| PMM from `/memory` | RAM starts at `0x40000000`, not 0; the x86 bitmap is the wrong shape |
| EL0 + `SVC` | no user mode |
| virtio-mmio block / virtio-net | no disk, no NIC |
| ECAM `pciRead32` | PCI exists at `0x4010000000`; nothing walks it |
| framebuffer / VirtIO-GPU | no display |
| Keyboard | virt has no i8042; serial input is the honest first input |
| Sharing `uart.dart` / `kmain.dart` / `fat.dart` | A3 and A8 |

The x86 suite is the production kernel. This gap exists so A1 cannot be mistaken for a
second architecture.

---

## GAP-0311 — N0 depends on firmware for bus-master, and on `romfile=` for an honest pcap

**Domain:** kernel (N0/N1/N2/N3), harness
**Status:** NARROWED — N1 (ADR-0063) writes BME through `pciWrite32`. N2
(ADR-0066) receives. N3 (ADR-0076) pings. `romfile=` is
still mandatory for every N-series pcap.

Two dependencies N0 created; N1 closed the first:

1. ~~**Bus-master is a firmware fact, not a kernel write.**~~ **NARROWED.** N1 writes
   MEM|BME before the first DMA. N0 still only *reads* memory-decode and prints
   `NIC NOCMD` if it is clear. With `romfile=` SeaBIOS leaves bit 2 clear; the
   write is load-bearing, not decorative.
2. **The e1000 option ROM transmits before the kernel runs.** A default `-device e1000`
   puts seven frames in a pcap (DHCP plus a gratuitous ARP) with no guest OS at all.
   `romfile=` (empty) removes BAR6 and the traffic. Every later N-series pcap assertion
   must pass that flag, or "the guest transmitted" is satisfied by firmware.

The PCI hole is still mapped write-back with no `PCD` (net-e1000.md §1.2). Invisible
under QEMU; wrong on hardware. It already affects `fb.dart`. Not new in N0, but N0 is
the second MMIO consumer in that window.

---

## GAP-0312 — AHCI is found; a sector is not

**Domain:** kernel (storage A0/A1)
**Status:** NARROWED — A1 is green (`docs/decisions/0077-one-ahci-sector-read.md`,
`tests/conformance/a1-ahci-read/run.sh`). One `READ DMA EXT` of LBA 7
prints host-planted bytes. A write, NCQ, and uncached MMIO are unstarted.

The kernel walks bus 0 for class `01/06/01` (or QEMU `8086:2922` / `1B36:0001`),
reads BAR5, loads CAP, starts one port, and DMA-reads one sector. ATA PIO
is still the path FAT and the loader use (`ata.dart`, `m6-disk`).

**What A1 worked around, and the leftover:**

1. ~~**No command list, no Received FIS, no Command Table.**~~ **NARROWED.**
   One `allocFrame` holds all three plus the sector (`storage.md` §2.3).
2. ~~**No port start.**~~ **NARROWED.** `PxCMD.ST` / `PxCMD.FRE` are written.
   `ahciWaitSlot` watches `PxIS.TFES` on every `PxCI` load.
3. **MMIO is still cacheable** (GAP-0071). The completion poll is
   `Volatile<u32>`, so it cannot hoist under QEMU. The mapping is still
   wrong for hardware.
4. ~~**LBA48 FIS is unbuilt.**~~ **NARROWED** for this command. The 128 GiB
   `ataLba28Max` ceiling still binds the PIO path.

---

## GAP-0313 — Skia Graphite, Vulkan, and Chromium WebView are not in the OS image; DCDart cannot call C++ yet

**Domain:** platform C/C++, UI language, DCDart FFI
**Status:** NARROWED — GFX0 / CMOD1 landed (ADR-0080, `tests/conformance/gfx0-host/run.sh`);
CMOD-FFI1 landed (ADR-0081, `cmod-ffi1/`); **GFX1 landed** (ADR-0082,
`tests/conformance/gfx1-graphite/run.sh`); **COMPOSE0 landed** (ADR-0094,
`tests/conformance/gfx2-compose/run.sh`): session chrome through
`osgfx_scene_compose` / Graphite, policy pixels match `wm*`;
**BROWSER0 landed** (ADR-0083, `tests/conformance/browser0/run.sh`);
**CMOD-CHROME1 landed** (ADR-0095, `tests/conformance/cmod-chrome1/run.sh`):
platform clang++ links official Spotify CEF macosarm64 (Chromium 144
Content) behind `oschrome.h`, and DCDart `@extern`s that ABI
(`oschrome.dart`, u64 handles). A `data:` HTML names PAGE; PPM/readback
matches; `--no-init` is the negative. **MEDIA0 landed** (ADR-0103,
`tests/conformance/media0/run.sh`): platform clang links brew FFmpeg
8.1.2 (`libavcodec` / `libavformat` / `libavutil`) behind `osmedia.h`.
A planted H.264 solid names FRAME; PPM/readback matches; `--no-init`
and `--missing` are the negatives. Not in `kernel.elf`. Vulkan is still unbuilt. **G9 landed** (ADR-0097,
`g9-virtgpu/`): the OS submits `GET_CAPSET_INFO` on the
VirtIO-GPU control queue. **G10 landed** (ADR-0098,
`g10-virgl/`): `virtio-gpu-gl-pci` in Docker QEMU executes a
virgl CLEAR with alpha; `VIRTIO 3D PIX` is device-written
`A=0x80` (or src-over). That is not Skia-on-GPU. Graphite /
Vulkan / Venus / CEF are still not in the **running GPU
path**. Preview.app is gone. CPU Skia in the kernel image
(ADR-0096) is withdrawn. **DE-osgfx landed** (ADR-0104 then
ADR-0110, `de-osgfx/`): `osgfx_skia.cpp` + ELF `libskia.a`
are linked into `kernel.elf` on the kernel triple; sit-in /
`wm gfx` calls `osgfx_fill_rrect` → live `SkCanvas::drawRRect`
(ADR-0125; qemu64 stays SSE2 / no `xgetbv`).
`osgfx_sw.c` stays in-tree and is not the linked backend.
**DE-browse landed** (ADR-0115 then ADR-0122, `de-browse/`):
`oschrome_guest.c` implements `oschrome.h` on the kernel triple;
`BROWSE.ELF` loads a `data:` page and the derived pixel is PAGE;
`--no-init` / `NINIT.ELF` is not PAGE. Official linux64
`cef_initialize` (Spotify CEF, same stamp as macosarm64) is
linked into that ELF. Mac CEF is not copied into `kernel.elf`.
Leftover: execute Content `OnPaint` — **hard process-ABI
blocker** (ADR-0123, GAP-0322). Official `libcef.so` is 1.5 GiB
`ET_DYN` with 32 `DT_NEEDED` (`libc.so.6`,
`ld-linux-x86-64.so.2`, pthread, X11, glib, NSS, …). `.text` is
231 MiB. ADR-0124 (`plat-proc/`) opened a 16 MiB **platform**
`sbrk` window for `PLAT.ELF`; TAP/FILES stay 64K/2MiB.
ADR-0126 (`plat-dyn/`) opened `PT_INTERP` for that name
(`LD.SO` on the FAT, our loader, not glibc). ADR-0127
(`plat-rel/`) opened `PT_DYNAMIC` on that name; `LD.SO`
applies `R_X86_64_64`. ADR-0128 (`plat-map/`) opened anonymous
`mmap` (syscall 27) on that name; pages are real and teardown
frees them. ADR-0130 (`plat-clone/`) opened `clone`
(syscall 28) on that name; the child shares the page tables
and writes a derived line; first FREED is 0. ADR-0144
(`plat-dl/`) opened `dlopen` (syscall 29) for our own tiny
FAT `ET_DYN`. ADR-0146 (`plat-futex/`) opened `futex`
(syscall 30) wait/wake so two clones sync a derived line.
ADR-0148 (`plat-tls/`) opened `setfs` (syscall 33) so a
`%fs:` store/load reaches a derived TLS block.
ADR-0152 (`plat-libc/`) opened OUR tiny FAT `LIBC.SO`:
`dlopen` resolves `write`, remaps X LOADs R+X, and the call
prints a derived LINE. Not glibc.
The 558-byte extract's first real call is `memset@plt`.
Floor stays 87. ADR-0154 (`plat-huge/`) planted **112 MiB**
of that window under the 128 MiB PMM floor. **ADR-0155** raised
`MAP_2MIB_PAGES` / `pmmMaxFrames` together to **256 MiB** and the
platform window to the full **189 MiB** CEF `.text` plant
(`189 << 20`; measured `.text` 189095087). **ADR-0157**
(`plat-need/`) walks two FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO`)
via `dlopen` with derived `LINE1`/`LINE2`; missing `LIBM.SO`
refuses the second line. Satisfies **2 of 32** CEF `DT_NEEDED`
stand-ins. **ADR-0160** (`plat-need2/`) grows that walk to
four (`LIBC.SO` + `LIBM.SO` + `LIBDL.SO` + `LIBPT.SO`) with
derived `LINE1`..`LINE4`; missing `LIBPT.SO` refuses the
fourth line. Satisfies **4 of 32** (**28 remain**).
**ADR-0162** (`plat-need3/`) grows that walk to eight
(`LIBC.SO` + `LIBM.SO` + `LIBDL.SO` + `LIBPT.SO` + `LIBGB.SO`
+ `LIBGO.SO` + `LIBNP.SO` + `LIBNS.SO`) with derived
`LINE1`..`LINE8`; missing `LIBNS.SO` refuses the eighth
line. Satisfies **8 of 32** (**24 remain**).
**ADR-0163** (`plat-need4/`) grows that walk to sixteen
(ADR-0162's eight plus `LIBNU.SO` + `LIBSM.SO` + `LIBDB.SO`
+ `LIBGI.SO` + `LIBAT.SO` + `LIBAB.SO` + `LIBCU.SO` +
`LIBX1.SO`) with derived `LINE1`..`LINE16`; missing
`LIBX1.SO` refuses the sixteenth line. Satisfies **16 of
32** (**16 remain**). **ADR-0165** (`plat-need5/`) finishes
that walk to thirty-two (ADR-0163's sixteen plus `LIBXC.SO`
… `LIBLD.SO` covering `libXcomposite.so.1` …
`ld-linux-x86-64.so.2`) with derived `LINE1`..`LINE32`;
missing `LIBLD.SO` refuses the thirty-second line. Satisfies
**32 of 32**. Leftover: `OnPaint`. Not another extract.
**G11 landed** (ADR-0107, `g11-osgfx-gl/`): that compose
buffer is `TRANSFER_TO_HOST_3D` + `SET_SCANOUT` on
`virtio-gpu-gl-pci`. Rounded AABB / title come back through
`TRANSFER_FROM_HOST_3D`. Not Graphite.
**ADR-0129 landed** (`de-graphite/`): `kernel.elf` links
guest-elf Graphite and calls `ContextFactory::MakeVulkan`.
**ADR-0134 landed** (`de-graphite2/`): Venus capset 4 arms
mailbox `vk`; a kernel Vulkan 1.1 ICD supplies handles;
MakeVulkan returns a live context (`OSGFX GRAPHITE OK`) and
one Graphite GPU clear (`PIX 00E24A18`) is stamped at (8,8).
Homebrew stays `NONE`. **ADR-0153 landed** (`de-graphite3/`):
a chrome title-bar-class rrect is Graphite `drawRRect` + ICD
DRAW (`OSGFX GRAPHITE RRECT 00C45A20`), not CPU `drawRect`.
**ADR-0159 landed** (`de-graphite4/`): desktop / taskbar fill is
Graphite `drawRect` + ICD DRAW (`OSGFX GRAPHITE DESK 001C6A38`),
not CPU `put_px`. **ADR-0161 landed** (`de-graphite5/`): curved
`MakeRectXY` paints via host-precompiled SPIR-V (`osgfx-host-spirv`)
+ ICD radius (`CURVE 00A87C14`) — freestanding AnalyticRRect SkSL
still #GPs if invoked; curve path does not run it. **ADR-0172 landed**
(`de-graphite6/`): retained SPIR-V is encoded through Venus
CONTEXT_INIT + SUBMIT (`OSGFX VENUS SPIRV`); HOST3D blob is
best-effort. Full lavapipe CreateShaderModule / Graphite FS
coverage is leftover.

**What GFX0 worked around:** this arm64 Mac has Metal. brew `graphite2`
is a font shaper. Flutter is on PATH and must not be embedded
(`dcdart.md`). The 64 KiB / 2 MiB numbers are the **app** sandbox.
They do not apply to WebView (`c-modules.md` §0 — Android shape).
Chromium is not a FRAME ELF.

**Binary next steps (do not mark DESIGN done without the named harness):**

1. ~~**GFX1 — vendor Skia Graphite** behind `osgfx.h` as platform C++.~~
   **NARROWED** (ADR-0082, `gfx1-graphite/`). `nm` shows
   `skgpu::graphite`; the rrect corner is desktop; force-metal is the
   fallback negative. Graphite is a host `libskia.a`, not a kernel
   object.
1b. ~~**COMPOSE0 — session chrome through osgfx / Graphite.**~~
   **NARROWED** (ADR-0094, `gfx2-compose/`). One scene is the real
   compositor policy. **G9** (ADR-0097) sends `GET_CAPSET_INFO`.
   **G10** (ADR-0098) is virgl CLEAR+alpha on `virtio-gpu-gl-pci`.
   **G11** (ADR-0107) uploads the osgfx compose buffer to that
   3D scanout (`g11-osgfx-gl/`). **ADR-0129** (`de-graphite/`)
   links Graphite `MakeVulkan` into `kernel.elf`. **ADR-0134**
   (`de-graphite2/`) is the VkDevice door (Venus arm + kernel
   ICD + one Graphite GPU pixel). **ADR-0153** (`de-graphite3/`)
   paints a chrome rrect through Graphite `drawRRect` (serial
   `RRECT 00C45A20`); not CPU `drawRect`. **ADR-0159**
   (`de-graphite4/`) paints desktop/taskbar through Graphite
   `drawRect` (serial `DESK 001C6A38`); not CPU `put_px`.
   **ADR-0161** (`de-graphite5/`) paints curved `MakeRectXY` via
   host-precompiled SPIR-V + ICD radius (`CURVE 00A87C14`);
   freestanding AnalyticRRect SkSL still #GPs if invoked.
   **ADR-0172** (`de-graphite6/`) encodes retained SPIR-V through
   Venus CONTEXT_INIT + SUBMIT (`OSGFX VENUS SPIRV`); HOST3D blob
   best-effort. Leftover: full lavapipe CreateShaderModule /
   Graphite FS coverage.
2. **GFX2 — Vulkan / MoltenVK** behind the same header. Same probe.
3. ~~**CMOD-FFI1 — `dcc` `@bare` calls `osgfx_*`.**~~ **NARROWED**
   (ADR-0081, `cmod-ffi1/`). DCDart calls the C module; the harness
   samples a PPM. Vulkan / Chromium still OPEN.
4. ~~**BROWSER0 — Chromium Content as platform WebView**~~
   **NARROWED** (ADR-0083, `browser0/`). `nm` shows `cef_initialize`;
   the `data:` pixel is PAGE; `--no-init` is not PAGE. Content is a
   host CEF framework, not a kernel object.
5. ~~**CMOD-CHROME1 — `dcc` `@bare` calls `oschrome_*`.**~~
   **NARROWED** (ADR-0095, `cmod-chrome1/`). DCDart `@extern`s the
   WebView; PAGE pixel matches; `--no-init` is not PAGE. Leftover:
   Content is still not **in the running OS image**, and a guest
   FRAME app cannot `@extern` host CEF. **DE-browse** (ADR-0115,
   ADR-0122) links `oschrome_guest.c` plus official linux64
   `cef_initialize` into `BROWSE.ELF`; leftover is executing
   Content `OnPaint` (ADR-0123: 32 missing `.so`, no POSIX/glibc;
   next binary is ring-3 libc / process ABI).
6. **`@extern` descriptors** stay DCDart escalation 0004 (GAP-0166).
   A platform process / C++ region of the OS image (Android
   `webview_zygote` class) is what puts Graphite and Content **in
   the running OS**, not the app 2 MiB window.
7. ~~**MEDIA0 — FFmpeg as a platform decoder.**~~ **NARROWED**
   (ADR-0103, `media0/`; **ADR-0116**, `de-media/`). Host `nm`
   shows `avcodec_` / `avformat_`. The running `kernel.elf` now
   links official FFmpeg for its triple; hidden `play` decodes a
   planted clip to serial PIX (ADR-0116). **ADR-0131** blits that
   tile onto the sit-in scanout (`de-vblit/`). **ADR-0135**
   commits it through a `wmsurface` (`de-vwin/`). **ADR-0143
   (`de-movie/`)** lands a second still on the same window
   (PIX→MOV, body FRAME→FRAME2). Leftover: Graphite / Venus
   paint of the same buffer; guest annex-B decode.

**Cost of the workaround:** the host rasterizer is Graphite;
the host browser is CEF. Vulkan is still unbuilt. QEMU scanout
paints PAGE through `BROWSE.ELF` (ADR-0115); `nm` of that ELF
shows official `cef_initialize` (ADR-0122). Executing Content
`OnPaint` is leftover and **blocked** (ADR-0123 / GAP-0322):
`libcef.so` needs 32 `.so` including `libc.so.6` and
`ld-linux-x86-64.so.2`. ADR-0126 opened the interp door
(`plat-dyn/`). ADR-0127 opened the RELA door (`plat-rel/`).
ADR-0128 opened the mmap door (`plat-map/`, syscall 27).
ADR-0130 opened the clone door (`plat-clone/`, syscall 28).
ADR-0144 opened the dlopen door (`plat-dl/`, syscall 29) for
our own tiny FAT `ET_DYN`. ADR-0146 opened the futex door
(`plat-futex/`, syscall 30) so two clones sync a derived
line. ADR-0148 opened the TLS door (`plat-tls/`, syscall 33)
so a `%fs:` store/load reaches a derived block. ADR-0152
opened the first libc door (`plat-libc/`): OUR tiny
`LIBC.SO` exports `write` through `dlopen`. ADR-0154
(`plat-huge/`) raised the platform window to **112 MiB** under
the 128 MiB PMM floor. **ADR-0155** raised PMM/identity to
**256 MiB** and the window to the full **189 MiB** CEF `.text`
plant; `mmap` of that size is real and teardown frees it.
Leftover: the rest of the 32 `.so`, and `OnPaint`.
Do not raise `de-browse` on another thunk. A later drop must keep
`osgfx.h` and `oschrome.h` or the language splits.

---

## GAP-0314 — NVMe Identify, one sector, one write, FAT, a named load, and class roots landed

**Domain:** kernel (storage NVM0/NVM1/NVM2/NVM3/NVM4/NVM5/NVM6/A2)
**Status:** NARROWED — NVM6 is green (`docs/decisions/0092-a-named-elf-loads-through-nvme.md`,
`tests/conformance/nvm6/run.sh`). **A2 is green (ADR-0137,
`tests/conformance/nvm-root/run.sh`).** After Identify, one I/O-queue
NVM Read of LBA 7, one NVM Write of those planted bytes to
LBA 11, and FAT sector I/O on that pair, the ELF loader uses the
same pick (`elfDiskRead` → `fatDiskRead`). NVMe class `01/08/02`
and AHCI class `01/06/01` are equal roots. Machines with neither
still use ATA PIO. MMIO is still cacheable.

The kernel walks bus 0 for class `01/08/02`, reads BAR0, loads CAP/VS,
enables an admin pair, DMA-reads Identify Controller, creates I/O
SQ/CQ QID 1, DMA-reads one sector, and DMA-writes one sector.

**What NVM2–NVM6 worked around, and the leftover:**

1. ~~**No admin queue.**~~ **NARROWED.** Three `allocFrame` calls hold
   ASQ, ACQ and the Identify buffer. CC.EN is written. The SQ0
   doorbell is the submission.
2. ~~**No Identify.**~~ **NARROWED.** CNS=1, SN/VID/NN printed from
   the controller-written buffer. `nvm2` derives `serial=` at test
   time.
3. ~~**An I/O queue and one sector are unbuilt.**~~ **NARROWED.**
   Create I/O CQ (05h) + Create I/O SQ (01h) + NVM Read (02h) of
   LBA 7. `nvm3` plants 16 bytes at test time.
4. **MMIO is still cacheable** (GAP-0071). The CSTS/CQ poll is
   `Volatile<u32>`, so it cannot hoist under QEMU. The mapping is still
   wrong for hardware.
5. ~~**A write on this path is unbuilt.**~~ **NARROWED.** NVM Write
   (01h) of the LBA 7 plant to LBA 11. `nvm4` reads the raw image
   after QEMU exits.
6. ~~**FAT is not on this path.**~~ **NARROWED.** `fatDiskPick`
   chooses NVMe when `nvmeFind` sees class `01/08/02`, else ATA PIO.
   `nvm5` plants `PLANT.TXT` on a FAT16 volume served as `-device
   nvme` and requires `cat` to print derived bytes. `m6-disk` /
   `m14-fat` / `m15` / `m16` stay on ATA.

7. ~~**The ELF loader still uses ATA PIO.**~~ **NARROWED.**
   `elfDiskRead` is `fatDiskRead`. `nvm6` plants a derived `PROG.ELF`
   on a FAT16 volume served as `-device nvme` (no IDE) and requires
   `run prog.elf` to print host-derived write bytes and exit.
   `m10-elf` / `m11-proc` / `m14-fat` stay on ATA.

8. ~~**AHCI is a probe, not a FAT root.**~~ **NARROWED (ADR-0137,
   `nvm-root/`).** `fatDiskPick` is class-first: `01/08/02` →
   `nvmeIoRead`, else `01/06/01` → `ahciIoRead`, else ATA PIO.
   The same planted ELF lists and `run`s on both DMA backends.
   Either backend off misses. QEMU NVMe/AHCI are stand-ins. A
   laptop vendor:device is not the success condition.
   `m6-disk` / `m14-fat` stay on ATA.

**What is still open, and the leftover:**

9. **MMIO is still cacheable** (GAP-0071). Unchanged. Binary next
   step is still S5 in `docs/design/storage.md`: runtime page-table
   entries with PCD+PWT so a poll of CQ phase cannot be served from
   a cacheable mapping on real hardware. A later metal smoke test
   may attach a real disk; class is still the match. Not a SKU.

---

## GAP-0315 — FILES lists, copies, moves, and icons

**Domain:** userland (FRAME file manager)
**Status:** CLOSED — listing and open/cat landed (ADR-0100).
**Copy and move landed (ADR-0118,** `core/user/frame/files.c`,
`tests/conformance/files-fm/run.sh`). **`unlink` / `rename` landed
(ADR-0147, `files-unl/`).** **FILES move consumes rename (ADR-0149,
`files-mv2/`):** source name is gone after move; copy still keeps
its source. **Icons landed (ADR-0154, `files-ico/`):** each listed
name band gets `osxui_icon_fb` / `osgfx_icon_rows` (`.rodata`
silhouette). `FILES_NO_ICON=1` is the pixel miss.

**Leftover:** none on this gap. Subdirectories stay APP3 / APP4
remainder if opened later.

---

## GAP-0316 — FFmpeg is in kernel.elf; the compositor does not blit video

**Domain:** platform C (MEDIA0 / DE-media)
**Status:** NARROWED — ADR-0116 (`de-media/`) decode; **ADR-0131
(`tests/conformance/de-vblit/run.sh`)** lands the 64×64 RGB tile on
the sit-in scanout at (16, 400) through `fbBlitArgb`. **ADR-0135
(`tests/conformance/de-vwin/run.sh`)** commits that buffer through
a `wmsurface` at (200, 80). Hidden `play` still copies planted
`CLIP.MP4`; Start of `PLAY.ELF` kicks play; IRQ0 decodes;
`OSMEDIA_NO_BLIT=1` prints PIX and the tile is not FRAME;
`OSMEDIA_NO_WIN=1` keeps the raw tile and the window body is not
FRAME. Missing file is not FRAME. Host `media0/` remains a Mac
program.

**Leftover:** a movie (more than one still). Graphite / Venus
paint of the same buffer.

**Binary next step:** decode a second frame into the same shm
and commit damage. Not a new syscall. Not stuffing libavcodec
into a FRAME ELF. Not Flutter. Not Graphite video.

---

## GAP-0317 — Sit-in Start lists FAT names; the third spawn and glyphs are leftover

**Domain:** DE chrome / sit-in disk
**Status:** NARROWED — ADR-0108 (`de-sitfat/`, `sit-in.sh`) listed the
names. **ADR-0109 (`de-shm/`) grew `shmMax` / `wmMaxWindows` /
`wmeventSlots` to 4.** Three derived surfaces stay mapped. Sit-in
that holds FILES + PING can spawn SET or STUDIO. **ADR-0173 plants
`BROWSE.ELF` / `PLAY.ELF` / `TAP.ELF` on the same sit-in FAT;** Start
stays `WM DE START 04` (first four ELF names). Full FAT vs Start is
documented there.

**Leftover:**

1. **Start stems are 8.3 glyphs (ADR-0117, `de-glyph/`).** The
   planted four-letter name is derived foreground pixels through
   `osgfx_fill_glyph`. **Title-bar `PID` is ADR-0132 (`de-title/`).**
   **Panel hex pids are ADR-0136 (`de-panel/`).**
2. **Raise Start past 04** so BROWSE / PLAY / TAP are launch rows
   (`wmDeLaunchMax`, chrome-word packing, `wmLaunchH`). Not this
   plant.
3. **0107 (osgfx-gl) is a sibling.** This rung did not touch virtgpu.

---

## GAP-0318 — OSXUI widgets paint through osgfx; title strings leftover

**Domain:** platform C (OSXUI-kit)
**Status:** CLOSED — ADR-0113 painted buttons/panels; **ADR-0117
(`tests/conformance/de-glyph/run.sh`) added `osxui_label` /
`osgfx_fill_glyph`.** The strip can show an 8.3 stem. Start rows
call the same hook. `osxui_panel` stays a colour tile so `osxui4`
does not move. **ADR-0132 (`tests/conformance/de-title/run.sh`)
paints title-bar `PID` through the same hook.** **ADR-0133
(`tests/conformance/de-osxui/run.sh`) paints live Start / close /
min through `osxui_button`.** **ADR-0136
(`tests/conformance/de-panel/run.sh`) paints live hex pids on the
reflection panel through `osxui_hex` / `osxui_label`.**

**Leftover:** none on this gap. Configure-to-client is ADR-0142
(`de-cfg/`). **APP4 `unlink` / `rename` is ADR-0147
(`files-unl/`).** **FILES move consumes rename (ADR-0149,
`files-mv2/`).** **shm grow past attach is ADR-0150
(`shm-grow/`, syscall 34).** **shm shrink past attach is ADR-0156
(`shm-shrink/`, syscall 35).** **multi-mapper grow/shrink is ADR-0158
(`shm-multi/`).** **FILES icons are ADR-0154
(`files-ico/`).** Not Flutter. Not `fdwait`.

---

## GAP-0319 — osgpu is the explicit app GPU; swapchain and shaders are leftover

**Domain:** GPU / app framework
**Status:** OPEN leftover after ADR-0114 (`tests/conformance/gpu-app0/run.sh`).
`osgpu.h` names `osgpu_create` / `osgpu_submit` / `osgpu_readback`.
Hidden `osgpug` hits G10 virgl. UI / osgfx / wm do not call it.
The C stub returns `OSGPU_NONE` until a later syscall wraps it
(next free number, not 11).

**Leftover:**

1. **Swapchain.** One dest resource, one transfer. A game that
   flips needs a second resource and a present.
2. **Shaders.** Submit is a CLEAR (or a reserved triangle kind).
   No TGSI / SPIR-V app ABI. G10's hand-built stream stays kernel.

**Binary next step:** a second 3D resource and a present, or a
syscall wrapping the three C functions. Not wm in C++. Not a
UI app calling osgpu.

---

## GAP-0320 — Settings toggle reached live chrome; persist/glyphs leftover

**Domain:** DE Settings
**Status:** NARROWED — ADR-0120 (`tests/conformance/de-set2/run.sh`).
`SET.ELF` writes `CHROME.DAT` on toggle (`open` + `fdwrite`). Under
`wm de` compose notices that file, sets bit 4 of the chrome word,
prints `WM DE SET ON`, and paints the notify strip `wmDeSetColor`.
A miss click does none of those. `de-set` stays the 130 local-swatch
path (no `wm de`). No new syscall. Title-drag unmoved.

**Leftover:**

1. **Persist atomic.** ADR-0147 opened `unlink` / `rename`; Settings
   can grow write-temp-and-rename. Not done here.
2. **Glyphs.** The notify strip is a colour tile, not an 8.3 caption.

**Binary next step:** Settings rewrite via rename-over, or a baked
glyph on the notify tile. Not a new syscall.

---

## GAP-0321 — Studio persists a selection; emit is leftover

**Domain:** userland (OSXStudio)
**Status:** OPEN leftover after ADR-0119 (`tests/conformance/studio2b/run.sh`).
`STUDIO.ELF` lists planted `APPS.TXT`, `spawn`s a catalog name, and
`fdwrite`s `SEL.DAT` (4 bytes, a row index). A second Studio start
exhibits `STUDIO2 SEL` plus that derived name. That is persist of
**data**. It is not a builder.

**Leftover — emit:**

1. **No reflection.** `@extern` is a name, not a descriptor
   (GAP-0166). Studio cannot inspect a live widget or emit a
   new program from one.
2. **No compiler on the box.** `elfImageMax` is 65,536. A C
   compiler or a Dart SDK does not fit and is not claimed
   (`osxstudio.md` STUDIO3). Host `clang` still produces the ELF.
3. **Save is destroy-on-save.** `O_WRITE` truncates. APP4
   `unlink` / `rename` is the later atomic idiom. Not a project
   format.

**Binary next step:** none on this prefix until DCDart ships
descriptors *and* something that can emit (STUDIO3). Do not mark
OSXStudio a builder because `SEL.DAT` landed.

---

## GAP-0322 — Content OnPaint cannot run: 32 DT_NEEDED, 189 MiB .text

**Domain:** platform C (DE-browse leftover)
**Status:** OPEN — hard process-ABI blocker (ADR-0123,
`tests/conformance/de-browse/prove-onpaint-block.py`).
**NARROWED** (ADR-0124, `plat-proc/`): a named platform ELF
(`PLAT.ELF`) may `sbrk` a 16 MiB window at
`[0x10400000, 0x11400000)`. TAP/FILES stay 64 KiB / 2 MiB.
Same bytes as `ASK.ELF` are refused the platform increment.
**NARROWED** (ADR-0126, `plat-dyn/`): that same name may carry
`PT_INTERP` pointing at our `LD.SO` on the FAT. The interp
maps the dyn ELF and jumps to `e_entry`. Missing `LD.SO` is
still `ELF REFUSED 11`, not a silent static run. `ASK.ELF`
with the same bytes is still 11.
**NARROWED** (ADR-0127, `plat-rel/`): that same name may carry
`PT_DYNAMIC`. `LD.SO` applies one `R_X86_64_64` RELA; the
derived line is `reloc_word ^ MIX` after the reloc. The word
is 0 in the file — skip RELA and the line is `MIX` alone.
`ASK.ELF` with the same bytes is still 11. A `PLAT.ELF`
without `PT_DYNAMIC` still runs as the interp door. libc is
still not this. This is not `OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0128, `plat-map/`): that same name may
`mmap` anonymous pages (syscall 27). `mmap(3 MiB)` maps real
frames at `0x10400000`; `write()` of a planted string from
that VA matches; teardown frees eight plat tables plus the
mapped pages above `ASK.ELF` of the same bytes. A no-op
return of heap base without new frames fails that delta.
`ASK.ELF` is `heapRetBadArg`. 11 stays `fdwait`. Not POSIX
`mmap`. Not `OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0130, `plat-clone/`): that same name may
`clone(fn, stack)` (syscall 28). The child shares the
caller's page tables, starts at `fn`, and writes a derived
`CHILD` line. First `PROC KILL FREED` is 0 — the survivor
still walks those tables. The last free is `ASK.ELF` of
the same bytes plus eight platform PD tables. `ASK.ELF` is `cloneRetBadArg`. 11 stays
`fdwait`. Not Linux `clone`. Not `futex`. Not `OnPaint`.
Floor 87 stays.
**NARROWED** (ADR-0144, `plat-dl/`): that same name may
`dlopen` our tiny FAT `ET_DYN` (syscall 29). `so_mark` is
read from the mapped pages; `MISS.SO` is NotFound; `ASK.ELF`
of the same bytes is BadArg. Not glibc. Not `OnPaint`.
Floor 87 stays.
**NARROWED** (ADR-0146, `plat-futex/`): that same name may
`futex(op, addr, val)` (syscall 30). Parent waits on a shared
word; child stores SIG and wakes; parent writes derived
`SYNC`. `ASK.ELF` is `futexRetBadArg`. 11 stays `fdwait`.
Not Linux `futex`. Not TLS. Not `OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0148, `plat-tls/`): that same name may
`setfs(base)` (syscall 33). Plants `IA32_FS_BASE` so a
`%fs:` store/load reaches a derived TLS block. `ASK.ELF` is
`setfsRetBadArg`. Without the MSR write the store faults at
VA 0. 11 stays `fdwait`. Not Linux `arch_prctl`. Not
`OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0152, `plat-libc/`): that same name may
`dlopen` OUR tiny FAT `LIBC.SO`, resolve `write`, and call
it (X LOADs remapped R+X). Derived `LINE` is `MARK ^ MIX`.
`MISS.SO` is NotFound; `ASK.ELF` is BadArg. Not glibc. Not
the 32 `DT_NEEDED`. Not 189 MiB. Not `OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0155, `plat-huge/`): that same name may
`mmap` the full **189 MiB** CEF `.text` plant. TAP/FILES stay
64 KiB / 2 MiB. Not the 32 `DT_NEEDED`. Not `OnPaint`.
**NARROWED** (ADR-0157, `plat-need/`): that same name may
carry two FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO`); the program
walks them, `dlopen`s each, and prints derived `LINE1` /
`LINE2` from `write` / `need_fn`. Missing `LIBM.SO` is
NotFound and cannot invent `LINE2`. `ASK.ELF` of the same
bytes is `ELF REFUSED 11`. Satisfies **2 of 32** CEF
`DT_NEEDED` stand-ins; **30 remain**. Not glibc. Not
`OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0160, `plat-need2/`): that same name may
carry four FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO` +
`LIBDL.SO` + `LIBPT.SO`); the program walks them, `dlopen`s
each, and prints derived `LINE1`..`LINE4` from `write` /
`need_fn` / `dl_fn` / `pt_fn`. Missing `LIBPT.SO` is
NotFound and cannot invent `LINE4`. `ASK.ELF` of the same
bytes is `ELF REFUSED 11`. Satisfies **4 of 32** CEF
`DT_NEEDED` stand-ins; **28 remain**. Not glibc. Not
`OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0162, `plat-need3/`): that same name may
carry eight FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO` +
`LIBDL.SO` + `LIBPT.SO` + `LIBGB.SO` + `LIBGO.SO` +
`LIBNP.SO` + `LIBNS.SO`); the program walks them, `dlopen`s
each, and prints derived `LINE1`..`LINE8` from `write` /
`need_fn` / `dl_fn` / `pt_fn` / `gb_fn` / `go_fn` /
`np_fn` / `ns_fn`. Missing `LIBNS.SO` is NotFound and
cannot invent `LINE8`. `ASK.ELF` of the same bytes is
`ELF REFUSED 11`. Satisfies **8 of 32** CEF `DT_NEEDED`
stand-ins; **24 remain**. Not glibc. Not `OnPaint`. Floor
87 stays.
**NARROWED** (ADR-0163, `plat-need4/`): that same name may
carry sixteen FAT `DT_NEEDED` (ADR-0162's eight plus
`LIBNU.SO` + `LIBSM.SO` + `LIBDB.SO` + `LIBGI.SO` +
`LIBAT.SO` + `LIBAB.SO` + `LIBCU.SO` + `LIBX1.SO`); the
program walks them, `dlopen`s each, and prints derived
`LINE1`..`LINE16` from `write` / `need_fn` / `dl_fn` /
`pt_fn` / `gb_fn` / `go_fn` / `np_fn` / `ns_fn` /
`nu_fn` / `sm_fn` / `db_fn` / `gi_fn` / `at_fn` /
`ab_fn` / `cu_fn` / `x1_fn`. Missing `LIBX1.SO` is
NotFound and cannot invent `LINE16`. `ASK.ELF` of the same
bytes is `ELF REFUSED 11`. Satisfies **16 of 32** CEF
`DT_NEEDED` stand-ins; **16 remain**. Not glibc. Not
`OnPaint`. Floor 87 stays.
**NARROWED** (ADR-0165, `plat-need5/`): that same name may
carry thirty-two FAT `DT_NEEDED` (ADR-0163's sixteen plus
`LIBXC.SO` + `LIBXD.SO` + `LIBXE.SO` + `LIBXF.SO` +
`LIBXR.SO` + `LIBGM.SO` + `LIBEX.SO` + `LIBXB.SO` +
`LIBXK.SO` + `LIBCA.SO` + `LIBPG.SO` + `LIBUD.SO` +
`LIBAS.SO` + `LIBAP.SO` + `LIBGC.SO` + `LIBLD.SO`); the
program walks them, `dlopen`s each, and prints derived
`LINE1`..`LINE32` from `write` / `need_fn` / … / `ld_fn`.
Missing `LIBLD.SO` is NotFound and cannot invent `LINE32`.
`ASK.ELF` of the same bytes is `ELF REFUSED 11`. Satisfies
**32 of 32** CEF `DT_NEEDED` stand-ins. Not glibc. Not
`OnPaint`. Floor 87 stays.

ADR-0115 / ADR-0122 PASSed `de-browse/` at floor 87 with
`oschrome_guest.c` `parse_rgb` plus a 558-byte official
`cef_initialize` extract. That is not Chromium painting.
`OnPaint` did not run.

Official linux64 `libcef.so` (Spotify CEF 144.0.34, same stamp
as macosarm64):

* 1.5 GiB, `ET_DYN`, `PT_DYNAMIC`, `PT_TLS`
* `.text` 189,095,087 bytes — 90× the 2 MiB process window
* 1,336 undefined dynsym (`clone`, `dlopen`, `mmap64`,
  `pthread_*` @ `GLIBC_*`)
* 32 `DT_NEEDED`: `libdl.so.2` `libpthread.so.0`
  `libglib-2.0.so.0` `libgobject-2.0.so.0` `libnspr4.so`
  `libnss3.so` `libnssutil3.so` `libsmime3.so` `libdbus-1.so.3`
  `libgio-2.0.so.0` `libatk-1.0.so.0` `libatk-bridge-2.0.so.0`
  `libcups.so.2` `libX11.so.6` `libXcomposite.so.1`
  `libXdamage.so.1` `libXext.so.6` `libXfixes.so.3`
  `libXrandr.so.2` `libgbm.so.1` `libexpat.so.1` `libxcb.so.1`
  `libxkbcommon.so.0` `libcairo.so.2` `libpango-1.0.so.0`
  `libudev.so.1` `libasound.so.2` `libm.so.6` `libatspi.so.0`
  `libgcc_s.so.1` `libc.so.6` `ld-linux-x86-64.so.2`

The loader honours `PT_INTERP` and `PT_DYNAMIC` only on named
`PLAT.ELF` when the 8.3 interp is on the volume (ADR-0126,
ADR-0127). `LD.SO` applies RELA. Every other name is still
`ELF REFUSED 11`. `elfImageMax` is 65,536. Calling the extract
with non-null args hits `memset@plt` and `#PF`. Null args
return 0 without leaving the extract — a thunk, refused. A
larger FAT `CEFHOST.ELF` that still paints `rgb()` is the same
thunk. ADR-0029 already rejected a Linux personality for
prebuilt `.so` files. Host `browser0` `OnPaint` is not this
QEMU.


**NARROWED** (ADR-0166, `browse-paint/`): `oschrome_on_paint` is the
CEF OSR callback ABI (PET_VIEW + BGRA). `load_url` stages BGRA only;
pixels come only from the callback. `PAINT.ELF` shows PAGE;
`--no-onpaint` / `NOPAIN.ELF` misses. Labelled OUR stand-in — not
`nm` of `cef_initialize`, not a rename of `parse_rgb`→pixels.
Leftover: **wire official `libcef.so`**. Floor 87 stays. TAP ≤64 KiB.

**NARROWED** (ADR-0167, `cef-wire/`): a named `PLAT.ELF` may
`dlopen` a **measured official** `CEF.SO` slice (32 verbatim
`DT_NEEDED` names, 558-byte `cef_initialize` text, one
official-addend `R_X86_64_64`). Map + NEEDED walk + reloc
PASSed. Not full 1.5 GiB LOADs. Not glibc UND. Not OnPaint.
Floor 87 stays. TAP ≤64 KiB.

**NARROWED** (ADR-0168, `cef-load/`): `PLAT.ELF` maps **full
official LOADs** (RO 42593760 + RX 189117488) from a host-backed
plant (FAT cannot hold 1.5 GiB). Anti-vacuity vs 12 KiB slice.
Not glibc UND. Not OnPaint. Floor 87 stays.

**NARROWED** (ADR-0169, `cef-plt/`): official `memset@plt` is
bound to OUR tiny `LIBC.SO` `memset` (planted over the PLT stub).
Derived call through the official CEF PLT address PASSes.
Anti-vacuity: unbound PLT → `#PF` / no `LINE`. Not the rest of
1,336 UND. Not real `libdl.so.2`. Not OnPaint. Floor 87 stays.

**NARROWED** (ADR-0170, `cef-und/`): measured high-traffic UND
batch — `memset` / `memcpy` / `memmove` / `strlen` / `memcmp` —
bound through OUR `LIBC.SO` (RX face slab + 12-byte PLT
trampolines). **5 of 1,336** bound; **1,331** remain. `malloc`
is absent from official libcef PLT (not claimed). Anti-vacuity:
unbound → `#PF` / no `LINE`. Not real `libdl.so.2`. Not OnPaint.
Floor 87 stays.

**NARROWED** (ADR-0171, `cef-und2/`): grows the bound set to
**20 of 1,336** (15+ beyond ADR-0170) — adds `bcmp` / `memchr` /
`strncmp` / `strcpy` / `strcmp` / `strnlen` / `strncpy` /
`strchr` / `strrchr` / `strstr` / `strcat` / `strspn` /
`strcspn` / `strncat` / `strcasecmp`. Face slab at PLT idx ≥ 511.
First five remain required (cef-plt / cef-und keep PASSing).
**1,316** remain. Anti-vacuity: unbound → `#PF` / no `LINE`;
host `libc-miss.so` drops `strcasecmp`. Not real `libdl.so.2`.
Not OnPaint. Floor 87 stays.

**NARROWED** (ADR-0172, `cef-und2/`): grows the bound set to
**50 of 1,336** (30+ beyond ADR-0171) — adds `strncasecmp` /
wide-string / ctype / `strto*` / tiny POSIX stubs through OUR
`LIBC.SO` (two-page RX copy). **1,286** remain. Anti-vacuity:
host `libc-miss.so` drops `geteuid`. Not real-named `libdl.so.2`
(FAT 8.3 leftover). Not OnPaint. Floor 87 stays.

**NARROWED** (ADR-0174, `cef-dl/`): real `DT_NEEDED` soname
`libdl.so.2` (not `LIBDL.SO`) resolves via planted `SOMAP.TXT`
(`libdl.so.2=LIBDL.SO`) onto OUR `dl_fn` face. Anti-vacuity:
missing SOMAP → NotFound (even with `LIBDL.SO` present); missing
`LIBDL.SO` → NotFound after alias. FAT stays 8.3 (no LFN).
UND floor **50 / 1,336** held. Not the other 31 sonames. Not
OnPaint. Floor 87 stays.

**NARROWED** (ADR-0176, `cef-somap/`): planted `SOMAP.TXT` covers
**all 32** official CEF Linux sonames → OUR plat-need5 `LIB*.SO`
faces. `elfDlopenNameMax=64` (FAT `fileNameMax` stays 12). Accidental
8.3 CEF names (`libnspr4.so` / `libnss3.so`) still hit SOMAP after
NotFound. Anti-vacuity: SOMAP missing `ld-linux-x86-64.so.2` refuses
that name (no `LINE32`). Satisfies **32/32** real-named `DT_NEEDED`.
UND floor raised by ADR-0178. Not OnPaint. Floor 87 stays.

**NARROWED** (ADR-0178, `cef-und2/`): grows the bound set to
**100 of 1,336** (50+ beyond ADR-0172) — math / POSIX leaf stubs
through OUR `LIBC.SO`. Face slab stays 4 KiB; `elfDlopenSymMax`
rises to 128. Anti-vacuity: host `libc-miss.so` drops `nearbyintf`.
**1,236** remain. Not OnPaint. Floor 87 stays.

**NARROWED** (ADR-0179, `cef-und2/`): grows the bound set to
**200 of 1,336** (100+ beyond ADR-0178) — more math / stdio /
POSIX leaf stubs through OUR `LIBC.SO`. LIBC RX may span three
pages; `elfDlopenSymMax` rises to 256. Anti-vacuity: host
`libc-miss.so` drops `mktime`. **1,136** remain. Not OnPaint.
Floor 87 stays.


**NARROWED** (ADR-0180, `cef-und2/`): grows the bound set to
**400 of 1,336** (200+ beyond ADR-0179) — POSIX / pthread / locale
leaf stubs through OUR `LIBC.SO`. LIBC RX may span six pages;
`elfDlopenSymMax` rises to 512; face slab stays 4096 B with 8-byte bodies.
Anti-vacuity: host `libc-miss.so` drops `__udivti3`. **936** remain.
Not OnPaint. Floor 87 stays.

**Binary next step:** remaining UND, then Content `OnPaint`.
Do not raise `de-browse` floor 87. `BROWSE.ELF` stays the thin
FRAME client.

---

## GAP-0323 — Portable hardware classes: five green, one honest leftover

**Domain:** kernel (storage / HID / GOP / net)
**Status:** NARROWED — five harness PASSes; Wi-Fi remains OPEN.
OTA plant is PASS (`ota0/`); OTA host TCP fetch is PASS
(`ota-host/`, ADR-0151). OTA TLS 1.2 record layer is PASS
(`ota-tls/`, ADR-0154). OTA cert store / chain verify is PASS
(`ota-cert/`, ADR-0168). OTA TLS 1.3 is PASS (`ota-tls13/`,
ADR-0177). Leftover on OTA: none (Wi-Fi only).

| Class | ADR | Harness | Status |
|---|---|---|---|
| NVMe + AHCI FAT roots | 0137 | `nvm-root/` | PASS (class, not SKU) |
| xHCI HID → kbdevent + mouse | 0138 | `hid-sess/` | PASS (no `usb-kbd` on 8042) |
| GOP session chrome | 0141 | `gop-sess/` | PASS (OVMF aperture) |
| VirtIO-net second NIC | 0145 | `net-virtio/` | PASS (`1af4:1041`) |
| OTA signed plant on NIC | 0140 | `ota0/` | PASS (RX plant + FAT apply; bad sig refuses) |
| OTA host TCP fetch | 0151 | `ota-host/` | PASS (real host; bad sig / no listener refuse) |
| OTA TLS 1.2 record layer | 0154 | `ota-tls/` | PASS (AES128-SHA; bad cert / plain TCP refuse) |
| OTA cert store / chain verify | 0168 | `ota-cert/` | PASS (planted CA; wrong chain → BADCERT) |
| OTA TLS 1.3 record layer | 0177 | `ota-tls13/` | PASS (AES-128-GCM; TLS 1.2/plain refuse) |
| 802.11 first class door | 0139 | — | OPEN — QEMU 11 has no Wi-Fi |

Graphite / MakeVulkan / Venus are fenced. Syscall 11 stays `fdwait`.
Do not mark Wi-Fi CLOSED without a real device path and a harness
PASS. Do not relabel e1000/virtio as Wi-Fi. OTA TLS closed (1.2 + CA +
1.3); leftover is Wi-Fi only (not plat-tls / FSGS).

---

## GAP-0324 — Sit-in looked tiny; the door is a QEMU viewer, not another hypervisor

**Domain:** display / sit-in / Venus
**Status:** NARROWED — ADR-0175 (`sit-in-view.sh`, `view-door/`).

**Cause (measured):** Multiboot sit-in is Bochs **800×600** with cocoa
at 1:1 (postage stamp on Retina). Venus under Docker used
`gtk,gl=on` + default Xvfb, so `GET_DISPLAY_INFO` reported
**~640×480** despite `xres`/`yres`; the only Mac deliverable was a
tiny PNG (no live window). QEMU `-vnc` cannot share a GL context.

**Door:** `scripts/sit-in-view.sh` — local `cocoa,zoom-to-fit=on`
(optional `--uefi-hd` GOP 1280×720); Venus `--venus` uses
`sdl,gl=on` + Xvfb 1280×720 + xdotool `+0+0` + **x11vnc `-rawfb` of
guest SCAN at 1280×720** (same pixels as pmemsave PNG) **plus
`-pipeinput` → `sit-in-view-input-bridge.py` → QMP** so Tiger
pointer/keyboard reach PS/2 (rawfb alone is display-only). Do **not**
`-clip 640x480` / upscale that cell — it crops the desk. Tiger
`-FullScreen=1` letterboxes 16:9. Host VNC port **5900** by default
(`VNC_PORT`). `sit-in.sh` defaults to zoom-to-fit. QEMU remains the
Graphite emulator; VirtualBox / UTM-without-gl are not substitutes.

**Leftover:** Homebrew cocoa cannot arm Venus (no gl device). Do not
claim a second hypervisor runs Graphite. Fractional Mac-fill was
retired for stair-stepped chrome; integer scale + letterbox is the
door. Guest FB PNG is the sharpness proof — Tiger fullscreen is the
**look** viewer for Venus, not Skia.

**Pointer leftover CLOSED by ADR-0193.** Relative PS/2 + x11vnc-rawfb
+ QMP warp cannot track the Mac cursor. The clickable door is
`sit-in-view.sh --abs`: QEMU cocoa (`oscortex-abs-pointer`) or QEMU
`-vnc` plus `virtio-tablet-pci`. The kernel SETs `mouseWordX/Y` from
ABS events (`virtab.dart` / `mouseAbsPlace`). USB `usb-tablet` on a
resident xHCI poll is still OPEN — `usbHidTabletApply` is the SET
seam, not a live interrupt IN. **Do not mass-`docker rm` every
`oscortex-qemu-gl:local` container.** Leave `oscortex-onebar-proof`
alone. The owner click target is the QEMU window, not Tiger :5900.

**Live OTA on abs CLOSED by ADR-0199.** Pointer-only abs intentionally
omitted NIC + `OTAKEY`/`SLOT.TXT`. `--abs` now adds SLIRP user-net +
e1000 (same flags as `ota-host/`) and plants the OTA FAT files.
Host serves `build/sit-in-view/ota-blob.bin` on `127.0.0.1:<port>`;
in the OS shell: `ota get <port>` → `10.0.2.2` → `OTA OK`. No sshd.
Leftover: DHCP/DNS beyond SLIRP; Wi-Fi (GAP-0323).

---

## GAP-0325 — Sit-in DE presence (taskbar / apps / titles) is visible

**Domain:** DE chrome / sit-in / Venus session paint
**Status:** NARROWED — presence + designed chrome this session.

**Was:** generative desk alone with postage-stamp windows (~160×64)
and a hairline taskbar; Start had no glyph; close/min were 10×10
dots. Owner saw an “empty green field.” Then presence landed but
chrome still read as flat neon stamps (hard shadow, gold strip,
`PID` blob) — owner rejected “that can never be Skia.”

**Now:**

- Taskbar `wmChromeH` / `OSGFX_CHROME_H` = **48** (elevated slate
  vgrad + top sheen); title **32** pearl; close/min **18** circles
  with highlight via osxui → osgfx rrect (Graphite when Venus arms).
- Soft alpha-blended drop shadow; CPU coverage-AA rrect spans;
  Start **96×36** inset pill with glyph; slots `W0`/`W1`; note strip.
- FILES **400×280** at (48,40); SET **300×260** at (460,48); sit-in
  spawns both. Session titles label `FILES` / `SET` (not `PID`).
- `de-session/` harness + `sit-in-view.sh --venus` PRESENCE probes
  + `tigervnc-live-now.png`.

**Then (ADR-0187, `de-skia-text/`) the two leftovers below that the
owner had rejected were closed, and this entry's own diagnosis of why
was wrong:**

- **The qemu64 AA hang was ours, not qemu's.** This entry said "curved
  Skia `drawRRect(MakeRectXY)+AA` still hangs on qemu64 in practice."
  It hung because `osgfx_guest_crt.c`'s `sqrtf` was
  `return __builtin_sqrtf(x)` compiled `-fno-builtin` without
  `-fno-math-errno`, so the compiler lowered the builtin back to a call
  to `sqrtf` — a self-recursive jump every curve measurement entered.
  Inline `sqrtss`/`sqrtsd` fixed it. `OSGFX SKIA OPS OK 16` on serial
  every boot covers all sixteen probe ops.
- **Chrome shapes are Skia CPU `drawRRect`/`drawPath` with
  `setAntiAlias(true)`**, plus `SkShaders::LinearGradient` and
  `SkMaskFilter::MakeBlur` for elevation. `rrect_cover` demoted to the
  no-canvas fallback. A window is one `osgfx_card_stroke` outline, not
  four square strips.
- **Chrome text is live TrueType outlines**, `SkPathBuilder` +
  `drawPath` at paint time, real `hmtx` advances. Not a cell, not baked
  masks, not `SkFont` — see GAP-0327 and ADR-0187 §1.1 for the exact
  line.
- Two `#GP` sources found on the way: `SkResourceCache` holding
  bump-heap pointers across `osgfx_heap_frame_begin` (now
  `SkGraphics::PurgeAllCaches()` first), and `saved_rsp` parked in
  `.bss` where a paint-stack overflow could zero it (now on the stack
  top, with a canaried guard band).

**Leftover:**

1. **Graphite is still not the chrome rasteriser.** Chrome AA is Skia
   **CPU** raster. ADR-0161's Graphite `Recorder::snap` GP in
   freestanding AnalyticRRect SkSL was **not** retested by ADR-0187 and
   must be assumed to stand; the ICD binary-radius stamp keeps its
   coverage and stays off live chrome. Graphite still arms for
   PIX/RRECT/DESK proof stamps.
2. **Start launch max stays 04** (GAP-0317) — BROWSE/PLAY/TAP on FAT
   are not Start rows yet.
3. **Title stem is session-painted `FILES`/`SET` by slot**, not a
   live 8.3 name from the process table — reflective name-on-chrome
   is a later rung.
4. **Venus sit-in-view QMP flake** (`qmp-drive` exit 3 before
   `virtgpuk`) can miss SCAN/PRESENCE; `de-session` Venus path is
   the reliable Graphite proof.
5. **The DE strip is still `osgfx_session.c`, not `DESK.ELF`.**
   ADR-0183's direction is unchanged and unfinished; `osxui_label` now
   routes to `osgfx_text` when it holds an `OsGfx`, which is the door,
   not the move. Worse than unfinished: with `DESK.ELF` attached both
   strips paint at once, because DESK's slot is frozen at 800x600 —
   GAP-0329.

**Binary next step:** the same Skia AA rrect that now returns on the
CPU, reached through Graphite `Recorder::snap` on Venus, so chrome
corners are GPU-rasterised rather than CPU-rasterised. **ADR-0183
landed** (`de-desk/`): `wm gfx` blits FRAME shm after session wallpaper
(no `OSGFX_WIN_FILL` body wipe); `DESK.ELF` is the desk-shell FRAME app
planted/spawned with osxui taskbar paint.

---

## GAP-0326 — Surface protocol: four “we shouldn't lack” rungs landed; honest leftovers

**Domain:** display protocol / `wm` / syscall 23
**Status:** NARROWED — clipboard, one-level subsurfaces, integer
scale, and two seats PASSed this session.

**Landed:**

| ADR | harness | what |
|---|---|---|
| 0183 | `wm-clip/` | kernel selection offer/take (cap-backed copy) |
| 0184 | `wm-sub/` | child relative pose; parent move carries child |
| 0185 | `wm-scale/` | integer buffer scale on attach+compose |
| 0186 | `wm-seat/` | two packed focus slots on `wmMetaFocus` |

Shared code: `core/kernel/wmext.dart`. No new syscall. 11 stays
`fdwait`. `wmStore` stays 448. Not Wayland.

**Leftover (binary next steps):**

1. **Fractional scale** — integer only (ADR-0185).
2. **DnD beyond clipboard** — offer/take only; no gesture path.
3. **Deep subsurface trees / child drag** — one parent level
   (ADR-0184).
4. **Per-seat pointer hardware + seat-routed `kbdevent`** — two
   focus slots; seat 0 still owns the legacy click/kbd path
   (ADR-0186).

---

## GAP-0327 — Chrome text is a real outline scan-converted live; it is not a font engine

**Domain:** DE chrome / text / `osgfx_text`
**Status:** NARROWED — ADR-0187 replaced the 8×16 cell with live Skia
outline fills. What is missing is everything above the scan-converter.

**What is real, so nobody has to re-derive it:** `gen-osgfx-font.py`
reads Roboto's `glyf` table at build time and emits each ASCII glyph's
quadratic outline **in font units** plus its real `hmtx` advance into
`osgfx_font_data.c`. `osgfx_text` replays those verbs into an
`SkPathBuilder` — one path per run — and `SkCanvas::drawPath` fills it
antialiased at a caller-chosen px size. So the size is live, the
coverage is live, the advances are proportional. Three independent
proofs in `de-skia-text/` (35 checks): `outline.py` on the generated C,
`check-osgfx-font.py` re-rasterising that same C with a non-Skia
scanline filler, and `caption.py` on the framebuffer.

**Leftover (binary next steps):**

1. **No `SkTypeface` / `SkFont` / `SkTextBlob`.** The guest-elf Skia is
   built `skia_use_freetype=false`, `skia_enable_fontmgr_empty=true` —
   no scaler context, no font manager, no TrueType parser in the image.
   Binary next step: an `SkFontMgr` backed by a planted `.ttf` on FAT,
   proven by `SkFont::measureText` agreeing with `osgfx_text_width` on
   serial.
2. **No shaping.** No GSUB/GPOS, so no kerning pairs, no ligatures, no
   marks, no bidi, no complex scripts. Advances are `hmtx` only.
3. **No hinting and no subpixel positioning.** Outlines are scaled
   linearly from 2048 upem and origins snap to integers, so small text
   has uneven stem weight — visible at 14px, not at 15px title size.
4. **ASCII 0x20..0x7E, two weights, one size pair** (14px label, 15px
   title). No glyph beyond `~`; a missing codepoint draws nothing.
   `osgfx_font_data.c` is ~1740 verbs; a full BMP face is not a
   `@rodata` table.
5. **No glyph cache, and ADR-0191 measured that it is not the one to
   build next.** GAP-0330's brief expected the outlines to be "likely a
   large share" of a 40–47 ms chrome frame. Stubbing every `osgfx_text`
   call out of a rasterising build made the tick *slower* (41.0 ms
   against 35.9 — noise around zero), and against the cached-band
   baseline text is **0.25 ms of a 4.46 ms rasterisation**: 5.6% of a
   cheap frame, 0.7% of the frame ADR-0191 started from. A cache keyed
   by char + size + colour would buy at most 0.25 ms of a 0.602 ms
   cached tick and nothing of the miss, against a keyed A8 mask store,
   an eviction policy and a subpixel-positioning argument. The 88% was
   the taskbar's `SkShaders::LinearGradient`, and that has its own cache
   now (ADR-0191 §5).

   **The counter is in the OS so the next worker starts from a number
   rather than from this paragraph.** `osgfx_text` calls
   `osgfx_chrome_glyph_count(0)` per run and `wm pace off` prints
   `WM CHROME ... GLYPH <n> HIT <n>`. On the `de-chrome-cache` boot that
   read **471 scan conversions across 469 rasterisations, 0 served** —
   one outline run per frame on a bare desktop, all misses.
   `de-chrome-cache` asserts `GLYPH >= REGEN` (the counter is wired) and
   `HIT == 0` (no cache exists), so landing one requires editing the
   assertion that says none has.

   **This is a bare-desktop claim and does not generalise.** A screen
   full of window titles scan-converts one run per title per
   rasterisation, and document volume is the case item 5 was always
   about. `GLYPH` over `REGEN` climbing is what says the balance moved.
6. **`osgfx_glyph.c`'s 8×16 cell still exists** for the packed-scanout
   label path and keeps its `osgfx-glyph-aa` soft-coverage door. It is
   soft-edged, not antialiased-by-a-rasteriser, and must not be
   described as Skia.
7. **`osgfx_sw.c`, `osgfx_metal.m`, `osgfx_graphite.mm` do not
   implement `osgfx_text` / `osgfx_elevate` / `osgfx_card*`.** They are
   not linked into `kernel.elf`; a host harness that links one and calls
   the session paint fails to link.
---

## GAP-0328 — The GL scanout is 640x480 no matter what `xres=`/`yres=` say

**Domain:** GPU / virtio-gpu / scanout geometry
**Status:** CLOSED by ADR-0189. Found while capturing the ADR-0187
chrome on Venus; the OS now drives 1280x720 and no longer takes the
device's answer as a mode.

**What it was.** `virtgpuk` sized the compose target from the device's
answer to `GET_DISPLAY_INFO` (`virtgpu3d.dart`, `sw`/`sh` at
`resp+32`/`resp+36`). The device answered **640x480** even when the
command line said `-device virtio-gpu-gl-pci,...,xres=1200,yres=720`:
`VIRTIO SCAN 00000000 00000000 00000280 000001E0`, then
`WM ON BASE 00D8D000 PITCH 00000A00` — pitch 0xA00 is 2560, i.e. 640 px.

**Root cause.** Not ignored properties and not a parse bug — the
offsets were always right. QEMU seeds `req_state[0]` from
`xres=`/`yres=`, then the UI frontend overwrites `req_state[0]` through
`dpy_set_ui_info` with the console it actually realised, and
`GET_DISPLAY_INFO` answers from `req_state[0]`. Last writer wins and
the last writer is the display backend. That is the whole difference
the previous entry recorded as "not yet identified": `shot-venus.sh`
ran `gtk,gl=on` under `xvfb-run`, which realises a 640x480 placeholder
console; the door runs `sdl,gl=on` sized 1280x720, which is why the
same OS reported 1280x720 there.

**Fix.** The driver picks the mode. `virtgpuModeFloor` /
`virtgpuModeFits` (`virtgpu.dart`) override a hint that is smaller than
1280x720 or too large for the attach path to back, and
`RESOURCE_CREATE_3D` + `SET_SCANOUT` are sized from that choice —
SET_SCANOUT's rect is what resizes the host console, so driving it is
the mode set. 1280x720 is the ceiling of the *current* attach path, not
a taste: it needs 900 backing pages (cap 1024) and exactly 4 entry
pages (cap `virtgpuEntCap` 4), so anything larger needs that cap grown
first.

A new serial line reports what was driven, distinct from what was
reported: `VIRTIO MODE wwwwwwww hhhhhhhh ssssssss`, `src` 1 when the
driver overrode the hint. `sit-in-view.sh`, `sit-in-view-fb-refresh.py`
and `probe-run.py` now take geometry from `VIRTIO MODE` and fall back
to `VIRTIO SCAN` only if it is absent — `VIRTIO SCAN` is a readback and
is *expected* to disagree.

**Guarded by** `de-skia-text/shot-venus.sh`, which asserts
`VIRTIO MODE 1280x720` and `WM ON BASE ... PITCH 0x1400` on the
`gtk,gl=on` path, i.e. the path where the hint really is 640x480 and
the override really fires. Live door proof:
`VIRTIO MODE 00000500 000002D0 00000000`,
`WM ON BASE 0103C000 PITCH 00001400`, capture
`core/build/tigervnc-live-now.png` at 1280x720.

**Left open, deliberately:** no `GET_EDID`, so there is still no mode
*list* and no validation against what the host would enumerate — the
floor is driver policy plus a fit check. The mode is a constant, not a
negotiation, and there is no post-boot mode change. See ADR-0189 §6.

**Not to be confused with** GAP-0325 leftover 4 (the Venus `qmp-drive`
screendump flake) or with the `xvfb-run -a` park noted in
`shot-venus.sh`: those are harness-side. Nor with GAP-0329, which this
makes *more* visible: DESK.ELF's strip is hardcoded to an 800x600
bottom, so at 1280x720 it floats mid-desk.
---

## GAP-0329 — Two taskbars paint whenever DESK.ELF is attached

**Domain:** DE chrome / ADR-0183 desk shell / `osgfx_session.c`
**Status:** **CLOSED by ADR-0192.** All three numbered steps below were taken
in the order they were written, and there is now one taskbar:
`DESK.ELF`'s, at 800x600 and at 1280x720
(`core/build/de-one-taskbar-1280x720.png`). The three claims, in serial:
`DESK SCREEN 0500 H 02D0` (it asks -- `wmsurface` op 9, `wmOpScreen`),
`DESK ATT OK X 0000 Y 02A0 W 0500 H 0030` (full width, flush bottom),
`OSGFX SESSION STRIP CLIENT` (the fallback withdrew, on committed pixels
over the strip rect via `wmPanelStrip` -> `OSGFX_GUEST_PANEL` bit 3 --
exactly the free bit this gap named). `de-desk` asserts all three plus
four corner probes; `de-session`, which spawns no `DESK.ELF`, asserts the
fallback is still there without one.

**Two things this gap got wrong, both worth keeping.** It said the
`osxui_button_fb` hang was "not the ADR-0187 `sqrtf` bug" because
`DESK.ELF` links only `desk.o` + `osgfx_glyph.o` and so gets the weak
no-op. The first half is right and the reasoning was wrong: with
`osxui.c` + `osxui_fb.c` really linked the call still faulted, and the
cause was neither float nor linkage but a stack 8 mod 16 at `_start`
(GAP-0339). It also said "a FRAME client has no way to learn the scanout
size ... the compositor is the only party that knows where the slot is" --
true of the tree as it stood, and the fix was to say it, not to work
around it.

**Was:** OPEN, visible in the owner's own `tigervnc-live-now.png`.

Under `wm gfx` + `wm de` with `DESK.ELF` spawned, **two** strips are
painted every frame by two paths that never consult each other:

| strip | painter | y | width | slots shown |
|---|---|---|---|---|
| lower, flush to the bottom edge | `paint_de_strip` in `osgfx_session.c` | `cmd->h - OSGFX_CHROME_H` (live scanout height) | `cmd->w` | `W0` **and** `W1` (reads the `HELD0`/`HELD1` mailbox flag bits) |
| upper, floating mid-screen | the compositor blitting DESK's shm | `SURF_Y`, **hardcoded 549** in `core/user/frame/desk.c` | `WIN_W`, **hardcoded 794** | `W0` only |

549 is `600 - 48 - 3`, i.e. the 800x600 bottom slot frozen into the
client. 794 is `800 - 2*3`. At any other scanout size DESK's strip is
both in the wrong place and the wrong width, which is exactly what the
owner's 1280x720 shot shows: a 794-wide bar hanging in the middle of the
desk above the real one.

**Why the session strip is not simply deleted:** ADR-0183 kept it so
that Start exists before DESK attaches, and `paint_de_strip` has no way
to know DESK is up. `wmDeChromeDraw` (the *Dart* strip) already
self-suppresses under `wmMetaGfx`; the C fallback has no equivalent
guard, and `wmMeta` has no desk-shell slot.

**Why this cannot be fixed by moving the constants:** a FRAME client has
no way to learn the scanout size. `osframe.h` exposes no geometry query,
and `configure` (ADR-0142) does not carry the screen rect. So DESK
cannot compute its own slot, and the compositor is the only party that
knows where the slot is.

**Binary next steps, in order:**

1. **Give a client its screen rect.** A new `wmOp` (9 is free; 1..8 are
   taken) returning `(w << 32) | h` in `rax`, the way `wmOpSeatGet`
   already returns bits in `rax`. No new syscall — 23 stays `wmsurface`,
   11 stays `fdwait`. Harness: `DESK` prints the rect it was told and it
   equals `VIRTIO SCAN`'s.
2. **DESK sizes and places itself from that**, replacing `SURF_Y 549` /
   `WIN_W 794`. Harness: assert DESK's strip pixels are flush to the
   bottom edge at two different scanout sizes.
3. **Suppress the fallback once DESK owns the slot.** A spare
   `OsGfxGuestCmd.flags` bit (bit 3 is free; 0..2, 4..5, 8..9, 16..17 are
   used) set by `wmGfxKick` when a live FRAME window covers the strip
   rect, checked by `paint_de_strip`. Harness: exactly one strip, i.e.
   the desk-generative wallpaper is unbroken at the old `SURF_Y`.

Only after 3 is ADR-0183's "the DE owns the strip" true. Until then the
session fallback is the strip that is actually correct at every
resolution, and DESK's is the one that is wrong.

**Related:** GAP-0325 leftover 5 (the strip is still `osgfx_session.c`,
not `DESK.ELF`) names the ownership; this names the visible defect.
`desk.c`'s own header comment records a separate, older problem —
`osxui_button_fb` hung in-ELF, so DESK's pills are manual solid fills.
That hang is **not** the ADR-0187 `sqrtf` bug: `DESK.ELF` links only
`desk.o` + `osgfx_glyph.o`, so it gets the weak no-op `osxui_button_fb`
and never links `osgfx_guest_crt.c` at all.

---

## GAP-0330 — The DE chrome re-stamp is now the whole frame

**Domain:** DE chrome / `osgfx_session.c` / ADR-0187, ADR-0188
**Status:** **CLOSED by ADR-0191.** At the median of six runs the session tick
is **63x** cheaper (`wm fps` `K D` 43.4 ms against `K 4` 0.74 ms within one
binary; **44x** against the pre-change build's 32.703 ms) and a full compose is
**9.2x** cheaper within the binary, **36x** across the builds. The spread is
wide — this host was shared with concurrent harnesses and a live door all
afternoon and the milliseconds move ±50% run to run — so ADR-0191 §2 reports
all five runs and the outlier rather than the best one. Harness
`core/tests/conformance/de-chrome-cache/run.sh`, 57 checks, floors set at 10x /
5x / 3x so a FAIL means the cache broke and not that the Mac was busy.
`de-session` (65) and `de-pace` (63) still PASS on the final tree, and `de-pace`
measures 48.3–49.9 fps against its 50 fps cap with the ratio to `wm pace 4`
holding at 1.93–2.02.

**Two things below turned out to be wrong, and they are left in place because
the corrections are the finding.**

1. **The invalidation condition is NOT `wmGfxChromeSig`**, which item (1)
   proposed. The signature answers a Dart question and does not fold
   `tone0`/`tone1`, the client's bottom-corner colours that the compositor
   re-samples out of client shm on every kick and that `osgfx_session_paint`
   reads. A cache keyed on it would have held a stale corner. ADR-0191 §3 has
   the argument; the key is a fold taken in C, on the side that reads the
   mailbox, and `de-chrome-cache/keycover.py` derives the coverage condition
   out of both sources rather than trusting either comment.

2. **The chrome is cached as ONE full-screen frame, not composited over the
   wallpaper blit** as item (2) proposed. Two buffers would have needed a
   coverage mask — the chrome is antialiased and its fringes blend against the
   wallpaper — and the session already paints the wallpaper itself. One buffer
   holding the composed result is the same 0.6 ms and no mask.

**And the prediction about where the time went was wrong by two orders of
magnitude.** The glyph outlines (GAP-0327), which the rung brief expected to
be "likely a large share", are **0.25 ms** — 0.7% of the frame. The taskbar's
one `SkShaders::LinearGradient` fill was **87.6%**, at ~820 ns/px, and
`setAntiAlias(false)` on it changed nothing, so the cost was the gradient
shader and not the coverage pass. ADR-0191 §5 has the stub-one-thing-at-a-time
table that establishes it. That band has its own cache, keyed on width, height
and the two colours, which is what makes a chrome frame that genuinely
*changed* 8.8x cheaper as well.

**What the original entry said, kept for the record:**

ADR-0188 removed the generative wallpaper from the per-frame cost (17–23x,
`wm fps` stage `K 8` against `K 3`). What is left of a full compose is the
Skia session tick, and it is essentially all of it. Four runs at 800x600 on
`-cpu qemu64`:

| stage | ms/iter |
|---|---|
| session tick, `K 4` | 40.3 – 47.3 |
| full compose, `K 5` | 40.3 – 44.6 |
| cached wallpaper, `K 3` | 0.41 – 0.55 |
| damage-limited present, `K A` | 2.7 – 3.0 |

So a full compose is a session tick plus about a millisecond, and the DE's
ceiling for a frame that must repaint chrome is **22–25 fps**. The paced path
does not pay it — a client update is 2.7–3.0 ms and the frame clock holds a
measured 49.7 fps against its 50 fps cap — but every chrome change does, and
that includes a window raise, a focus change, a popover and a wallpaper
change.

**Why ADR-0188 left it alone:** a worker was concurrently rewriting chrome to
real Skia text and shapes (ADR-0187) in the same file and the same paint path.
Two workers restructuring one paint is how both changes get reverted.

**What the fix looks like, and it already has its hard part done.** A chrome
cache needs an invalidation condition, and `wmGfxChromeSig` in
`core/kernel/wmpace.dart` **is** that condition: it folds every input
`osgfx_session_paint` reads (window set and geometry, top slot, keyboard
focus, DE and popover state and position, wallpaper mode) into one word, it is
stamped after the tick so a fault inside Skia leaves it stale, and
`de-pace/run.sh` already tests that damage is honoured only while it holds
still. So:

1. **Paint chrome into its own buffer, keyed by `wmGfxChromeSig`**, from the
   same frame allocator run `wmDeskEnsure` uses (§5 of ADR-0188 has the
   contiguity check to copy). Harness: a `WM CHROME REGEN <n>` counter that is
   1 for a boot in which nothing raises, focuses or pops.
2. **Composite chrome over the wallpaper blit instead of re-drawing it.** The
   two buffers make a full compose two blits plus the client rows, which is
   `K 3` + `K 2` territory — under 2 ms, not 40.
3. **Only then is `wmGfxChromeFresh`'s fallback cheap.** Today a signature
   change costs a whole session tick; after (2) it costs one Skia paint into a
   buffer, and the *present* is a blit either way.

**Related:** ADR-0188 §8 names this as the work it did not do. GAP-0329 (two
taskbars) is a different defect in the same file and should be fixed before
(1), because caching a wrong strip caches it harder.

---

## GAP-0331 — The frame clock is the PIT, not the display

**Domain:** compositor pacing / ADR-0188
**Status:** OPEN. Named by ADR-0188 §8 as a limit of the policy it chose.

`wmFrameTick` runs from IRQ0. That gives the DE a real, measured refresh rate
(49.7 fps against a stated 50 fps cap, `de-pace/run.sh`) and it is the first
one this OS has ever had. Two things it is not:

1. **It is not vsync.** There is no vblank interrupt from stdvga on the
   Homebrew path and no fence on the Venus one, so "present" means "the
   compositor finished writing the scanout it shares with the host". Tearing
   against the host's own read of that scanout is possible and **unmeasured**
   — no harness in this suite can see it, because every harness reads the
   framebuffer with `pmemsave` after the fact rather than during a present.
2. **The cap is expressible only in whole PIT ticks.** `wmPacePeriod` is a
   tick count and the PIT is 100 Hz, so the rates this policy can name are
   100, 50, 33, 25, 20, … **60 is not one of them.** A 60 Hz cap would need
   either a faster PIT programming (and every `ticks` golden rests on the
   current divisor, GAP-0058) or a sub-tick clock.

**Binary next steps, in order:**

1. **Get a real presentation signal on one path.** virtio-gpu's
   `RESOURCE_FLUSH` completion on the control queue is the closest thing
   available (ADR-0079, ADR-0093 already drive that queue). Harness: a
   `WM PRESENT` line whose count equals the flush completions, on the
   `virtio-gpu` boot rather than on stdvga.
2. **Drive the clock from that completion instead of the tick** when it
   exists, keeping the PIT as the fallback the stdvga path still needs.
   Harness: `WM PACE` reports a rate that tracks the device's, not 100/N.
3. **Only then does a cap that is not a tick divisor mean anything.**

Until 1, "50 fps" means "fifty presents per wall-clock second, each of which
finished writing memory the host reads whenever it likes".

---

## GAP-0332 — Coalesced damage is a bounding box, not a region

**Domain:** compositor pacing / ADR-0188
**Status:** OPEN by design, with the cost printed.

`wmDamageRect` folds each mark into the **union** of everything pending, so
two 16x16 rectangles at opposite corners of the screen present as the box that
contains both — 480,000 pixels for 512 that changed.

**Why it is a union and not a list:** a list is a queue that can overflow, and
an overflowing damage queue has to decide what to drop, which is a correctness
question with no good answer. The union is never wrong, only sometimes bigger
than it had to be.

**Why it has not bitten:** the measured case is one client committing small
rectangles in one place. `de-pace/run.sh` records 226,586 marks folded into
416 presents — a 545:1 ratio — and the presented rate held at the cap, so the
boxes being presented were small. A DE with two clients animating in opposite
corners is the case that would hurt, and it does not exist yet.

**What the fix looks like:** a small fixed array of rectangles (four is the
number every other compositor picked) with a merge rule — union two
rectangles when the union is cheaper than the pair, otherwise keep both, and
fall back to the screen when the array is full. `wmPageWDmg*` is already four
words per rectangle in a page that has room.

**Harness that would prove it:** two resident clients committing at opposite
corners, asserting that the presented pixel count per frame is under some
fraction of the screen. The `PX` field of `WM FRAME` already reports it.

---

## GAP-0333 — A client that stops committing loses its body to the cached wallpaper

**Domain:** compositor pacing / ADR-0188 / `wm.dart`
**Status:** CLOSED by ADR-0190. Root-caused, fixed, and covered by a
time-based harness (`core/tests/conformance/de-retain`, 34 checks, 135 s
of wall clock) that was shown to FAIL with the fix backed out.

A window's chrome survived indefinitely but its **client body did not**.
Measured on `oscortex-interactive-door` at 1280x720, one boot:

| when | `SET` window | `FILES` window |
|---|---|---|
| at boot (`tigervnc-live-now.png`) | full file listing | full |
| ~2 min idle (`tigervnc-live-current.png`) | empty card, chrome only | title text and buttons floating with no body at all |

**The suspicion recorded here was wrong in its mechanism and right in
its missing rule.** Damage honouring was not implicated at all. The
actual cause: `isr_common` calls `osgfx_guest_tick` after **every**
interrupt (`isr.S:297`), that tick paints the whole scanout whenever
`gen` has moved, the only thing that moves `gen` is `wmGfxKick`, and
**nothing in the session's path reads client shm** — the one client
blit on this machine is `wmDrawWindow` (`wm.dart:857`), reached from
`wmCompose` and nowhere else. `wmPointerTick` kicked unconditionally on
every pointer packet, so one pointer walk handed the screen to Skia and
erased every idle client's body permanently.

It is therefore **not the slow decay it looked like**: it is one packet.
The two minutes were how long it took the owner to move the mouse and
then look. And it is not strictly an ADR-0188 regression — the kick
predates it. ADR-0188 removed the always-full-compose that used to
paper the wipe over on the next commit, and a client that commits once
and idles has no next commit.

**The rule this gap asked for was the right one** and ADR-0190 states
it: a present must re-blit every mapped client it covered.
`wmSessionRestore` (`wmpace.dart:990`) pays that debt on the
instruction after the tick, Dart-only, busy-guarded; `wmGfxKick`
records it; `wmCompose` settles it; and `wmPointerTick` no longer kicks
for a move that would not change the picture.

**The binary next step this gap set was performed** and is stricter
than it asked: two clients that commit once and then only yield, their
interior blocks compared byte-for-byte at T0 and after 2.8 s, 15.1 s,
45.1 s and 135.1 s, across 60 pointer packets and 10 popover cycles
with the frame clock armed. All intact; 40 restores, 3 266 880 pixels
put back, no debt outstanding at the end. With `DE_RETAIN_NOFIX=1` and
the fix reverted, both bodies die on the first pointer stage.

**Remaining, and carried in ADR-0190 §7:** `wmGfxEdgeTone` is not part
of `wmGfxChromeSig`, so an edge-tone-only change now waits for the next
compose instead of riding an accidental pointer repaint; and an
exhausted frame allocator leaves the debt unrecordable, in which case
the kick still happens and the restore does not.

---

## GAP-0334 — Two resident clients starve the shell

**Domain:** scheduler / shell / `procTick`
**Status:** OPEN. Found by ADR-0191's harness, which is shaped around it.

`de-chrome-cache/drive.py` spawns ONE client, and the first draft spawned two.
With two resident processes the scheduler round-robins them under IRQ0 — which
`wm pace off` deliberately leaves unmasked while a process is resident, on
`shellTicks`' terms — the serial fills with `PROC PREEMPT` / `PROC YIELD`, and
**the shell never reads another typed line.** A `wm pace off` typed 25 seconds
after the second spawn produced no report at all.

This is not a graphics defect and not an artefact of the harness typing too
fast: `de-session` spawns two clients and then types nothing, which is why it
has never seen it. The reproduction is two spawns followed by any command.

**What is not known:** whether the shell's line is lost (keyboard IRQ serviced
while a client is current, byte dropped) or merely never scheduled (shell task
never runs long enough to reach `shellExec`). Those need different fixes and
the serial cannot tell them apart, because the shell echoes nothing until it
executes.

**Binary next step:** a harness that spawns two clients, types `ticks`, and
asserts the count line appears within 5 s. Then, if it fails, echo each byte
on receipt so the two hypotheses separate.

**Independently reproduced by ADR-0190's `de-retain`**, which needs two
resident clients for its own reasons and lost the shell in exactly this way:
every command typed after the second spawn was ignored, including `wm pace`.
The workaround it uses — and it is a workaround, not a fix — is to type
everything **before** the second spawn and then read the compositor's counters
straight out of the state page in guest physical memory, locating
`osgfx_guest_cmd` with `nm` and `pmemsave`ing it. That the serial line cannot
be used at all after two spawns is a second, harder statement of this gap.

---

## GAP-0335 — The 4.46 ms chrome rasterisation is not analysed past the gradient

**Domain:** DE chrome / `osgfx_session.c` / ADR-0191
**Status:** OPEN, and it is the next rung on this line.

ADR-0191 §5 took a chrome rasterisation from 35.9 ms to 4.46 ms by caching the
taskbar gradient, and established that text is 0.25 ms of what is left. **The
other 4.2 ms has not been taken apart.** The candidates, in the order a
stub-one-thing-at-a-time pass should try them:

1. `SkGraphics::PurgeAllCaches()`, which `tick_body` calls on **every** tick,
   before the cache-hit check decides whether anything will be drawn. It is
   there for a real reason (ADR-0172: bump-heap pointers in the global
   `SkResourceCache` outlive `osgfx_heap_frame_begin`) but it is unmeasured,
   and on a hit nothing was allocated to purge.
2. `SkMaskFilter::MakeBlur` for the elevation rings — a real blur per elevated
   window per rasterisation.
3. The rrects themselves, which is the irreducible part.

**Why it matters and when:** only when chrome changes every frame, which is
dragging a window or a live popover. At 4.46 ms that is a 220 fps ceiling, so
this is not urgent — it is recorded so the number is not mistaken for
analysed.

**Binary next step:** hoist the purge below the hit check (it is provably
unnecessary on a blit), measure `K 4` and `K B` again, and report both.

---

## GAP-0336 — The taskbar band cache is one entry

**Domain:** DE chrome / `osgfx_chrome.c` / ADR-0191
**Status:** OPEN by design, and instrumented rather than fixed.

`osgfx_chrome_band` holds exactly one band, keyed on `(w, h, top, bot)`. There
is exactly one full-width radius-0 vertical gradient in the chrome today, so a
one-entry cache is a *complete* cache of the thing it caches. A second gradient
strip of a different height or colour pair would thrash it: every rasterisation
would refill, and the 8.8x would quietly become 1x.

**It would not be silent.** `WM BAND FILL` climbing in step with
`WM CHROME REGEN` is exactly what thrashing looks like, and
`de-chrome-cache/run.sh` asserts `FILL < REGEN`, so adding that second strip is
a harness FAIL rather than a slow boot. That is the whole of the mitigation and
it is deliberate: a two-entry cache would need an eviction rule, and there is
no second entry to evict yet.

**Binary next step, when a second gradient lands:** a small keyed table, and
`WM BAND` gaining a per-entry line so `FILL`/`HIT` stays readable.

---

## GAP-0337 — A cached chrome frame is presented as a full-screen blit

**Domain:** compositor / ADR-0188, ADR-0191
**Status:** OPEN.

`osgfx_chrome_present` blits `w * h` pixels — 480,000 loads and stores at
800x600 — for any tick that reaches it, including one where a single pixel
changed. That blit **is** the 0.602 ms `K 4` measures; the rasterisation it
replaced was 44 ms, so this was the right trade and it is not the end of it.

ADR-0188's damage path already avoids composing at all for a client commit, so
this only bites where a session tick happens for a small reason: a pointer
move under `wm gfx`, a caret blink, a hover highlight. What is missing is a
**damage-limited blit out of the chrome cache** — the cache is a full-screen
image in the scanout's own format, so presenting a sub-rectangle of it is the
same loop with different bounds and no new state.

**Binary next step:** `osgfx_chrome_present_rect(m, x, y, w, h)` plus a
`wm fps` stage that presents a 64x64 rect out of the cache, asserted against
`K 4` to be at least 20x cheaper. The damage rectangle is already in the
mailbox for the gfx arm.

---

## GAP-0338 — Every ADR-0191 number is 800x600 stdvga on qemu64

**Domain:** DE chrome / ADR-0191 / measurement
**Status:** OPEN, and overlapping live work.

The chrome frame buffer is sized from `fbGeomWidth()`/`fbGeomHeight()`, the
band offset is recomputed on every `wmChromeBufEnsure` precisely so a
resolution change moves it, and `wmChromeBufFree` gives the old run back before
taking a new one. **All three of those are code-reading claims.** No harness
boots this cache at a second resolution, and none boots it on Venus at all —
`de-chrome-cache` is Homebrew-only 800x600.

Two specific things are unproven rather than merely unmeasured:

1. **A resolution change mid-boot.** The path exists (free, realloc,
   republish the band slice) and nothing has taken it. The failure mode if the
   band slice were *not* republished would be Skia rasterising the taskbar into
   the middle of the cached frame, which is visible and ugly rather than
   subtle — but that is an argument that a bug would be found, not that there
   is none.
2. **Venus/Graphite.** `de-session` proves the Graphite arm still arms and
   still paints after this change, but `wm de` on Venus takes a different
   desktop-fill arm and no `WM CHROME` report has ever been read off a Venus
   boot.

**Why now:** the worker on GAP-0328 / ADR-0189 is changing what
`GET_DISPLAY_INFO` reports, which is exactly the input this cache sizes itself
from. These numbers should be re-taken once that lands rather than trusted
across it.

**Binary next step:** add a second `de-chrome-cache` phase that types `fb` at a
different mode after the first report and asserts `WM CHROME PX` grew, `REGEN`
moved once, and the taskbar gradient probe still passes at the new width.

---

## GAP-0339 — A FRAME `_start` was 8 mod 16, so any SSE spill killed the app

**Domain:** ring 3 ABI / `core/user/frame/` / ADR-0192
**Status:** **CLOSED for FRAME apps by ADR-0192's `OSFRAME_START`**, and OPEN as
a class: nothing verifies the property, and every ring-3 entry that is not a
FRAME app still hand-rolls its own `_start`.

The System V ABI says RSP is 16-byte aligned *at the instruction after* a
`call`, which is to say a function entered by `call` sees RSP ≡ 8 (mod 16) and
clang emits prologues on that assumption. The kernel enters ring 3 with
`iretq` and a 16-aligned RSP. A `void _start(void)` compiled by clang is
therefore off by 8 for its whole call tree, and the first *aligned* SSE store
anywhere below it -- `movdqa %xmm0,-0xc0(%rbp)`, which clang emits freely when
it vectorises an integer loop -- raises #GP(0):

    FAULT 0D ERR 0000000000000000 OP 660F
    USER FAULT VEC 0D ... RIP 0000000010002C62 CPL 3
    PROC KILL SLOT 00

**This is what "`osxui_button_fb` HANGS in-ELF" was.** `desk.c` carried that
sentence in its header for two ADRs and hand-wrote solid-span pills because of
it. The program was not wedged, it was reaped, and from outside the two look
the same: no more `USER WRITE` lines. Every unaligned-stack app that never
happened to be vectorised worked, which is why this survived so long.

**What is not done:**

1. **No harness asserts the alignment.** `OSFRAME_START` is used by `desk.c`
   and correct there; nothing fails if the next FRAME app writes a plain C
   `_start`, and it will fault only if its compiler happens to vectorise.
   A one-instruction `test $15, %rsp` self-check in the shim, or a build-time
   `nm`/objdump check that `_start` is the shim, would make it structural.
2. **The other ring-3 entries are unconverted.** `core/user/**` has many
   `_start`s (libc programs, `app1.c`, the d2/d3 probes). They are not known to
   be broken -- they are known not to have been vectorised yet.
3. **The kernel does not have to enter this way.** Entering with RSP ≡ 8
   (mod 16) in `procEnterUser` would make a plain C `_start` correct and this
   whole class disappear. That is a one-word change to the initial stack and it
   was not made in ADR-0192 because it moves the initial-stack layout every
   existing `_start` already reads `argc`/`argv` off.

## GAP-0340 — `wmTitleH` went 18 → 32 and no ADR says so

**Status:** open. **Found by:** the conformance sweep, triaging `d8-title`.

ADR-0075 (title bars are chrome) specifies an 18-pixel title band, and
`d8-title` asserted `16 <= wmTitleH <= 20` on that authority. `wmchrome.dart`
says 32. Nothing in `core/docs/decisions/` authorises the move.

The move is nonetheless **correct and forced**, which is why the code was not
reverted:

1. `wmBtnY` (`wmde.dart`) places a `wmBtnS`-tall button `wmBtnGap` down from
   the window top and **falls back to flush-with-the-top** when
   `wmBtnGap + wmBtnS` does not fit. With `wmBtnS = 18` and `wmBtnGap = 8` the
   binding floor is 26, so an 18-row band did not fail loudly — it silently
   put the close and minimise buttons on the client's first row.
2. ADR-0187 made the caption a live Skia outline, `OSGFX_TEXT_TITLE_PX` tall,
   drawn `SESS_TITLE_PAD_Y` down from the same top edge. An 18-row band clips
   it.
3. ADR-0187's own de-session measurement already reads "27 over 32 rows", so a
   32-row band was assumed by the ADR that needed it.

`d8-title` now asserts the **containment** — the band is at least
`wmBtnGap + wmBtnS` and at least `SESS_TITLE_PAD_Y + OSGFX_TEXT_TITLE_PX`,
every term read out of source — instead of a remembered range. That is
strictly stronger: the old range could not even be satisfied by a band that
fits its own buttons.

**Binary next step:** amend ADR-0075 (or write a successor) stating the title
band's height is derived from the button column and the caption box, and that
18 was the pre-ADR-0187 bitmap-caption value.

## GAP-0341 — Six byte-exact goldens encode kernel physical addresses, so any kernel edit invalidates them

**Status:** open. **Found by:** regenerating M7/M9/M10/M11/M12/M13 twice in one
afternoon during the ADR-0187/0188/0189 sweep.

`m7-frames`, `m9-ring3`, `m10-elf`, `m11-proc`, `m12-heap` and `m13-libc`
compare the whole serial capture byte-for-byte, and that capture contains
`PMM BASE`, `PMM ALLOC`, `VM CR3`, `VM SECT`, `PROC NEW SLOT … PML4` and
friends — physical addresses that follow the size of `kernel.elf`. The
allocator is first-fit from the end of the kernel image, so **any** change to
**any** kernel source file, by any worker, moves every one of those numbers and
turns six harnesses red for a reason that has nothing to do with what they
test. During this sweep the goldens had to be regenerated twice: once after the
`isr.S` FPU fix and the `nic.dart`/`ota.dart` zeroing, and again after a
sibling's unrelated edit moved `__text_end` by 0x60 bytes.

The derived checks around them are not affected — they compute the expected
values from the Multiboot map, `kernel.elf`'s own extents and the program ELFs
— so the byte-exact comparison is the only fragile part, and it is the part
that produces the churn.

**Binary next step:** normalise physical addresses in the byte-exact
comparison the way `m12-heap` already normalises `RFLAGS.RF` for GAP-0212:
replace each `[0-9A-F]{16}` that the derived checks have already verified with
a fixed token on both sides, so the golden pins the SHAPE of the session while
the derivation keeps pinning the numbers. One harness (`m7-frames`) proves the
idea before the other five adopt it.

## GAP-0342 — Every interrupt now costs an `fxsave`/`fxrstor` pair and 512 bytes of interrupt stack

**Status:** open, and it is the price of a REAL fix. **Found by:** `m11-proc`
during the ADR-0187 sweep.

`isr_common` calls `osgfx_guest_tick`, `wmSessionRestore` and
`osmedia_guest_tick` on **every** interrupt and exception — not just IRQ0 —
after `isrDispatch` has already restored the interrupted process's FPU state
with `fx_restore`. Skia and FFmpeg are compiled with SSE, so those trampolines
clobbered `%xmm0-15` between the restore and the `iretq`: a ring-3 process
preempted mid-SSE resumed with another process's (or Skia's) register file.
ADR-0015 §2 says the kernel never touches the FPU between save and resume, and
`m11-proc` asserted it by counting XMM mnemonics in the whole linked image,
which is how it was caught.

**Fixed in code** (this is not a test change): the three trampolines are now
bracketed by `fxsave`/`fxrstor` over 512 bytes of interrupt stack, and the
whole bracket — allocation, calls and restore — is skipped when `sse_flag` is
clear, which also stops a non-SSE CPU from taking a `#UD` storm out of the
timer.

What remains a gap is the **cost and the shape**: a full 512-byte FXSAVE on
every interrupt, including the overwhelming majority that will not paint
anything, plus 528 bytes of extra interrupt-stack depth. The mailbox check that
makes the tick a no-op happens INSIDE `osgfx_guest_tick`, i.e. after the save.

**Binary next step:** hoist the mailbox test into `isr.S` — read the one word
`osgfx_guest_tick` reads first and branch over the entire bracket when it is
zero — so the FPU cost is paid only on interrupts that actually paint. Measure
before and after with `m18-preempt`'s tick counter.

## GAP-0343 — `osgfx_text` existed only in the Skia backend, so every no-Skia link of `osxui.c` failed at `ld`

**Status:** **fixed in code.** **Found by:** `de-glyph`, `de-panel`,
`de-title` and `files-ico` during the ADR-0187 sweep, all four failing with
`build-osxui.sh exited 1`.

ADR-0187 rewrote `osxui_label` to ask for a real proportional outline run
first and fall back to the 8x16 cells when the backend cannot draw one:

    if (osgfx_text(g, x, y, text, stem, ...) > 0) { return; }
    /* ... 8x16 osgfx_fill_glyph loop ... */

The fallback arm is correct and the contract is right — "return <= 0 and I
will use cells". The problem is that **nothing defined `osgfx_text` for a
backend that has no outlines.** The only definitions were the strong one in
`osgfx_skia.cpp` and a stub inside `osgfx_glyph.c`'s
`#if OSGFX_GLYPH_APP_LINK` block, which is compiled only for FRAME programs.
`osxui.c` is triple-compiled — kernel, host module, app — so the host module
link (`core/scripts/build-osxui.sh`, no Skia) and any `OSGFX_SKIA=0` kernel
link referenced a symbol that did not exist:

    Undefined symbols for architecture arm64:
      "_osgfx_text", referenced from:
          _osxui_label in osxui.o
          _osxui_hex in osxui.o

This was **not** a stale expectation. Four harnesses were red because a build
was broken, and the harnesses were right.

**Fixed in code:** `osgfx_text` is now a `__attribute__((weak))` definition in
`osgfx_glyph.c`, compiled unconditionally and sitting next to the cell
fallback it hands off to, and the `OSGFX_GLYPH_APP_LINK` copy is deleted. Zero
is not a stub answer here, it is the backend's honest reply: *this backend
rasterises no outlines, use cells.* The Skia build still overrides it with the
strong symbol, and `de-skia-text` still requires that strong `T osgfx_text` in
`kernel.elf`, so the weak definition cannot hide a missing Skia.

**What remains a gap:** nothing enforces that a symbol `osxui.c` calls is
resolvable in **all three** of its links. `build-osxui.sh` is the only one of
the three that a conformance harness builds directly, and it is built by four
harnesses that are about glyphs and icons, not about linkage — so this took
four red harnesses to surface rather than one that says what it means.

**Binary next step:** add to `cmod-ffi1` (which already owns the "the C module
is really there" question) a check that every `osgfx_`/`osxui_` symbol
undefined in `osxui.o` is defined by at least one object in each of the three
link sets, and prove it fails by deleting the weak `osgfx_text`.

## GAP-0344 — Harnesses keep a third copy of `osgfx.h` / `osxui.h` constants, so a chrome redesign goes red in places that are not about chrome

**Status:** partly fixed; the pattern is still present in harnesses that
happen to agree today. **Found by:** the ADR-0187 sweep.

The intended design is a **double entry**: the C header holds the value and
the harness's `derive.py` holds an independently typed copy, so a silent edit
to one is caught by the other. Several harnesses added a **third** copy, as a
literal inside `run.sh`:

    ck; grep -q 'OSGFX_RADIUS = 14' "$HDR" || fail "osgfx.h RADIUS moved without derive.py"

A third copy is not a third check. It means an authorised redesign has to be
transcribed into three files, and ADR-0187 — pearl title band, elevated slate
taskbar, 12px corner radius, 2px border, 32px title, 48px chrome — was
transcribed into one. Six harnesses went red saying "X moved" about a change
that was decided, recorded and implemented: `gfx0-host`, `gfx1-graphite`,
`gfx2-compose` (twice), `osxui4`, `de-osxui`, `gop-sess`.

`gop-sess` is the clearest case: it typed the taskbar's **fill colour** and
**height** into the harness and then asserted the screen matched them, so it
was testing its own memory of the design rather than testing that the screen
agrees with the source.

**Fixed for those six:** `run.sh` now reads the header and `derive.py` and
asserts the **pair agrees**, with no value of its own; `gop-sess` reads
`wmChromeH` / `wmChromeColor` / `wmColorDesktop` straight out of the kernel.

**What remains a gap:** `OSGFX_DESK` and `OSGFX_TITLE` are still pinned as
literals in three harnesses. They agree with the header today, so they are not
red, and rewriting a passing assertion during a red sweep is how a sweep stops
being trustworthy.

**Binary next step:** convert the remaining `grep -q 'OSGFX_… = 0x…'` pins in
`gfx0-host`, `gfx1-graphite` and `gfx2-compose` to the same pair-agreement
form, and prove each one still fails by editing `derive.py` alone.

## GAP-0345 — `plat-map` and `plat-huge` pinned the same constant to two different values

**Status:** fixed in the harnesses. **Found by:** the ADR-0187 sweep.

`vmPlatPdCount` was asserted `-eq 95` by `plat-map` and `-eq 111` by
`plat-huge`. Both cannot be right, and `vm.dart` says 111 (ADR-0168 grew the
platform window to the RO+RX LOAD span of the measured official `libcef`). The
pair had been inconsistent for as long as one of them was failing for an
unrelated reason and nobody read the other.

`vmPlatPdCount` is not an independent fact: it is exactly how many 2 MiB
page-directory entries `[vmPlatBase, vmPlatEnd)` needs. Both harnesses now
assert that arithmetic instead of a number, so they cannot disagree again.

**What remains a gap:** the same "two harnesses, one constant, two literals"
shape is everywhere in this suite — it is the same disease as GAP-0344, one
level up. There is no cross-harness check that two `dartconst`-derived pins on
the same name agree.

**Binary next step:** a sweep-time lint that collects every
`dartconst <name>` … `-eq <literal>` pair across all `run.sh` files and fails
when one name carries two different literals. Prove it by re-introducing the
95.

## GAP-0346 — The no-Skia glyph fallback painted the AA fringe at full opacity, so labels were smears

**Status:** **fixed in code.** **Found by:** `de-panel`, once GAP-0343's link
break stopped hiding it.

`osgfx_glyph.c` computes a soft coverage mask for the 8x16 cells — a set bit
is 255, and a clear bit next to `n` set bits is `70 + n * 32` — and hands each
pixel to `osgfx_blend_px`. Skia supplies a strong `osgfx_blend_px` that really
composites. Every other link got the weak one, which cannot read the
destination and so **thresholded**:

    if (cov >= 128) { osgfx_fill_rect(g, x, y, 1, 1, rgb); }

A clear pixel with two set neighbours is `70 + 64 = 134`, so the entire fringe
came out **fully opaque**. An 8x16 letter grew into a 3px-wide blob and the
letterforms stopped being letterforms. `de-panel` measured it exactly:
against a painted `DEADBEEF`, the deliberately WRONG font scored 33% and the
wrong TEXT `WXYZWXYZ` scored **88%** — the label matched a string it did not
say.

**Fixed in code:** the weak `osgfx_blend_px` paints only `cov == 255`. On a
backend that cannot blend, the honest rendering of a soft mask is the hard
mask inside it — the same crisp cells the framebuffer console draws. Skia is
untouched and still gets the real fringe. After the fix the same measurement
reads: real font 136/136, wrong font **0**/504, wrong text 58/112.

**What remains a gap:** the CPU backend still has no way to blend at all, so
`osgfx_shadow`, `osgfx_fill_rrect_vgrad` and the glyph fringe are all
all-or-nothing without Skia. That is invisible today because the live door and
every screenshot harness build with Skia.

**Binary next step:** give `osgfx_cpu.c` a strong `osgfx_blend_px` that reads
and writes its own pixel store — it already owns one, `blend_store()` in
`osgfx_glyph.c` does exactly this arithmetic — and prove it by asserting a
fringe pixel strictly between the fill and the ink in `gfx0-host`.

## GAP-0347 — `cmd | grep -q` under `pipefail` fails when the producer outgrows the pipe buffer

**Status:** open (one instance fixed). **Found by:** `de-graphite3`.

Every harness runs `set -uo pipefail`. `grep -q` exits at its FIRST match, so
whatever is upstream of it gets SIGPIPE if it still has bytes to write.
`pipefail` then reports the pipeline's status as 141 and the check fails —
**with a message about the code under test, which is fine.**

`de-graphite3` proved this the expensive way. Its check is

    awk '/osgfx_graphite_ready\(\) != 0/,/draw_rrect_spans/' osgfx_skia.cpp \
      | grep -q 'return;'

The awk range used to be a few dozen lines. ADR-0187/0188 grew `osgfx_skia.cpp`
until the range was 816 lines, and the very `return;` the check is looking for
is on line 10 of it. `grep -q` matched immediately, exited, awk took SIGPIPE
on the remaining 806 lines, and the harness reported *"Graphite title path
still falls through to CPU drawRect"* about a path that does return. Verified
directly: `bash -c 'set -euo pipefail; awk ... | grep -q "return;"'` exits 141
while the same awk output searched in a variable matches.

This is silent, load-bearing, and grows with the codebase: a check flips from
pass to fail with **no change to what it tests**, and the failure message
accuses the code. The fixed instance now reads the range into a variable.

**Binary next step:** sweep the suite for `| grep -q` where the producer can
exceed 64 KiB (`nm`, `objdump -s`, `awk` over a whole file) and convert each to
`capture` + `grep -q` on a variable, or to `grep -c ... -ge 1`. A one-line
`shellcheck`-style guard in `_lib/harness.sh` — a `pipeq()` helper — would stop
the pattern coming back.

## GAP-0348 — Harnesses that assert on `core/build/kernel.elf` without building it are sweep-order dependent

**Status:** open (two instances fixed). **Found by:** `de-skia-text`;
`gfx0-host` (host/guest `.o` collision).

`de-skia-text` asserted `nm kernel.elf | grep osgfx_face_regular` but never
built a kernel: it took whatever the previous harness left in `core/build`.
In the baseline sweep it passed because `de-set2` aborted structurally and
left an `OSGFX_SKIA=1` image behind. Once `de-set2` got far enough to build
its own `OSGFX_SKIA=0` kernel, `de-skia-text` reported *"kernel.elf has no
osgfx_face_regular — no outline table in image"* — a true statement about an
image that has nothing to do with `de-skia-text`.

A harness whose verdict depends on its neighbour is not a harness. Fixed here
by building `OSGFX_SKIA=1` in the harness itself.

The same collision on **object files**: `build-preview-ui.sh` and
`build-kernel.sh` both wrote `core/build/osgfx_scene.o`. A kernel build
racing the host preview's second link left an ELF64 `.o` and `gfx0-host`
failed `unknown file type`. The preview now writes `osgfx_*_host.o`.

**Binary next step:** grep the suite for `KERNEL_ELF` reads not preceded by a
`build-kernel.sh` call in the same file, and give each one its own build; the
suite is already ~90 minutes, so the cost is real and should be paid by
sharing one built image per backend through an explicit fixture, not by
accident.

## GAP-0349 — `cef-load`'s volume has no `LIBC.SO`, and ADR-0168's door has quietly needed one since ADR-0169

**Status:** fixture fixed; the coupling itself is the open gap.
**Found by:** `cef-load`.

`cef-load` proves ADR-0168 — that `dlopen` maps official libcef's FULL RO+RX
LOADs (about 42 MiB + 189 MiB) from a host plant. Its volume plants
`PLAT.ELF`, `ASK.ELF` and the 12 KiB `CEF.SO` ticket. It has never planted
`LIBC.SO`.

ADR-0169 later added `elfCefPlaceLibcMemset` to the same `dlopen` path: before
returning, the kernel places OUR `memset` over official libcef's `memset@plt`,
and that placement does a FAT lookup for `LIBC.SO`. On a volume without it the
lookup fails and `dlopen` returns `elfDlopenRetNotFound` — the serial shows
`CEF LOAD RO 000000000289EDE0 RX 000000000B45B430` (both LOADs measured
correctly) and then `PROC DLOPEN 00 ERR FFFFFFFFFFFFFFF9`. So the door under
test was reached, did its work, and was then failed by an unrelated step.

Fixed by planting `LIBC.SO` on `cef-load`'s volume, built from `cef-plt`'s
`libc.c`/`libc.ld` so the two harnesses cannot disagree about what OUR libc is.

**What remains a gap:** a missing `LIBC.SO` makes `dlopen` refuse the whole
mapping rather than return the mapping with the PLT unbound. The refusal is
indistinguishable from "the .so is not there". **Binary next step:** give the
placement step its own return code (`elfDlopenRetNoLibc`) so a volume without
OUR libc is a different, nameable outcome, and assert it in `cef-plt` with a
volume that has `CEF.SO` and no `LIBC.SO`.

## GAP-0350 — Three `OSGFX` probe lines are now baked into every byte-exact boot golden, and a sibling is about to remove them

**Status:** open. **Found by:** this triage.

ADR-0187 added `OSGFX TEXT OUTLINE PROPORTIONAL`, `OSGFX SKIA OPS OK 16` and
`OSGFX PAINT STACK HI 13 KIB` before `M1 END`. Every byte-exact golden in the
suite has been regenerated to contain them.

A concurrent worker is putting per-tick `com1_puts` lines behind a debug flag
as part of the GAP-0330 chrome cache. If that flag also gates these three
lines — they are printed from the same module — **every one of those goldens
moves again**, for a reason that has nothing to do with the milestone each
golden is protecting.

**Binary next step:** decide whether a probe line is part of the boot contract
or diagnostics. If it is diagnostics it must be off by default and the goldens
must not contain it; if it is contract it must not be behind a debug flag.
Either answer is fine; having it both ways costs a suite-wide golden
regeneration every time somebody changes their mind.

## GAP-0351 — Title chrome and file-row actions are still not DESK surfaces

**Status:** closed for the named leftovers (ADR-0195), then narrowed
again by ADR-0196. **Found by:** ADR-0194.
**Does not reopen GAP-0333.**

ADR-0195 moved titles onto CSD and menus onto DESK. ADR-0196 closed
the wallpaper teeth (one modest Skia AA card, radius 8 lockstep),
put `osxui_app_csd` on SET / TAP / BROWSE / STUDIO / PING as well as
FILES, proved file-row Rename (`FILES RENAME` + list update), and
restored overlay pixels on hide (`WM OVERLAY CLEAR`). Client
paint reclaims the Skia bump past half so Open+Rename cannot
print `OSGFX OOM`.

**What still is not a full DE:**

1. PLAY stays 64×64 for `kmedia` and has no CSD. It is **not** an
   overlay: `wmIsOverlay` is exactly DESK's 160×88 card (`wmOverlayW` ×
   `wmOverlayH`, lockstep with `desk.c`). A size range (8–96 × 32–176)
   had swallowed PLAY, the 40×40 scale client, and the 32×32 subsurface
   — they composed only while a popover was showing. Fixed in code.
2. Rename is stem.REN, not an in-place field. No widget tree.
3. Pointer is still compositor-placed. Overlay park is still a live
   slot; hide now restores pixels rather than skipping the blit.
4. Look is glass language (ADR-0197/0198): frosted split dock (wallpaper
   sample + blur), light FILES rows, Settings sidebar + Appearance /
   Devices. Start is the hamburger on the left island. Copper `C87840`
   is only the no-DESK fallback.

**Binary next step:** titled PLAY, or an in-place rename field.
Live clock; Dashboard / browser chrome. SET window-body sampled frost
optional (toggle probes need exact hexes).
Do not kick `osgfx_guest_tick` on a plain pointer move — that is
GAP-0333.

## GAP-0352 — `WM WALL MENU` printed before the row fill was on the scanout

**Status:** **fixed in code.** **Found by:** `de-wall` after ADR-0187–0196.
**Does not reopen GAP-0333.**

Under `wm gfx` Dart stopped CPU-filling the wallpaper menu (session owns
the card). `wmPopShow` then printed `WM WALL MENU` and `de-wall` dumped
the fb at that token. The row probe was generative wallpaper `0x63769B`,
not `wmPopRow0` `0x304878`. A kick+`wmCompose` before the token is not
enough: compose may share `last_gen` with an IRQ0 tick, and the chrome
cache can present a still without the card. The token is a pixel claim.

**Fixed in code:** `wmPopShow` kicks, calls `osgfx_guest_tick`, composes
if active, then CPU-fills the card and `wmPopMenuDraw` rows (lockstep
`SESS_POP_ROW0` / `SESS_POP_ROW1`) *before* the uart line. `wmPopPlace`
does the same kick/tick/card fill. Labels still skip under gfx
(`wmPopLabel`). Kick/tick/CPU fill run only when `wmPanelStrip()==0`
(ADR-0192): a tick+compose after TITLE held `wmMetaBusy` and
`de-desk`'s FILES Open click dropped. de-wall plants no DESK.ELF so
the fill still runs. Not a golden loosen — the assertion stays exact
`0x304878`. `de-wall` now fails the build instead of reusing a stale
`kernel.elf` after `OSMEDIA_FFMPEG=0` link races (GAP-0348).

**Binary next step:** done — `de-wall` PASS (44 checks) and `de-desk`
PASS (100 checks) on this tree.

## GAP-0353 — planted `play` decodes PIX; `wmMediaFill` does not print WIN

**Status:** **fixed in code.** **Found by:** `de-movie` / `de-vwin`.
**CODE, not a golden.** Do not loosen FRAME slop.

`OSMEDIA FILL` then hang with `FILL-MISS 0` and no WIN: `wmMediaBlitSlot`
used the packed stride word `(scale<<32)|byte_stride` (ADR-0185) as a
byte stride, so `off` jumped to ~2^32 and `shmVec` page-faulted
(`PF CR2 0x10290008`, FILL-MISS A). Full `wmCompose` after fill also
`fbFill`d away the ADR-0131 raw tile.

**Fixed in code:**
- `wmMediaBlitSlot` uses `wmWinStrideOf` (low 32 bits only).
- Decode path only arms `win_have`; idle IRQ0 runs fill+present on
  `decode_stack` (16KiB RSP0 is too small).
- `wmMediaPresent` damage-commits the media window only (keeps the
  Bochs blit tile).
- `wmPanelStrip` needed `@bare` (sibling CSD call from `wmBlitRow`).
- `de-vwin` nm checks: no `grep -q` on a pipe under `pipefail`
  (SIGPIPE false miss).

**Binary next step:** done — `de-movie` PASS (44), `de-vblit` PASS (62),
`de-vwin` PASS (77) on this tree.

## GAP-0351 — `elfCefPlantOwns` leaked every platform-window frame on a boot with no plant

**Status:** **fixed in code.** **Found by:** `plat-map`, `plat-huge`.
**This was a real frame leak, not golden drift.**

ADR-0168 gave the CEF host plant an ownership predicate so teardown would
not hand an *alias* frame back to the PMM. The predicate was a bare
physical-address range, `[elfCefPlantPa, +elfCefPlantBytes)` =
`[16 MiB, 237 MiB)` of a 256 MiB pool. But the reservation that creates
those aliases, `elfCefPlantReserve`, returns immediately when QEMU planted
no official bytes — which is every boot except the `cef-*` family.

So on an ordinary boot the predicate claimed ownership of *ordinary*
frames the process had allocated, and both teardown walks
(`proc.dart`'s platform-PD walk and `heapSbrk`'s unmap) skipped freeing
them. `plat-map` measured it exactly: a program that mapped 768 platform
pages, wrote them and passed its own XOR handed back **0** of them, so the
teardown delta was `vmPlatPdCount` alone.

**Fixed in code:** `elfCefPlantOwns` now returns 0 unless
`elfCefPlantReady()` — the plant's ELF magic, class and `ET_DYN` at
`elfCefPlantPa` — actually holds. The frames it exists to protect are
reserved and never handed out, so the plant path is unchanged;
`cef-load`, `cef-plt`, `cef-wire`, `cef-und*`, `cef-somap` and `cef-dl`
all still pass, and `plat-map`/`plat-huge`/`plat-clone` went green.

**Binary next step:** none for the leak. The residual weakness is that the
predicate re-reads guest-visible memory on every freed frame; a one-word
"reserve actually took N frames" flag would be cheaper and airtight, but
`elfStoreWords` is full at 16 and growing it moves every pinned `.bss`
total.

## GAP-0352 — `m1-interrupts` pinned the size of the compiler's literal pool

**Status:** **fixed in test.** **Found by:** ADR-0040 check firing at
44 bytes against a pinned 40.

Check (2) of the `.rodata` layout test required the bytes after the last
`@rodata` table to be *exactly* `TRAIL_ANON = 40`. That trail is the
compiler's literal pool — every `u64(0)` / `u64(1)` loaded from memory
lands in it — so its size moves whenever any function anywhere gains a
constant. The pin therefore fired on unrelated code growth while proving
nothing about ADR-0040, whose promise ("elements only, no header") is
check (1) and was passing throughout.

**Fixed in test, not weakened:** `TRAIL_ANON` is now a floor (the known
lookup block must still be there), and the claim the size pin was
standing in for — *nothing but literals follows the last message table* —
is asserted about the pool's **content**: whole 8-byte words, no
`.rela.rodata` relocation past the last table, reached from `.text`, and
no printable-ASCII run of 4+ bytes (a smuggled unnamed message table is
ASCII by construction). That is a statement the old size pin never made.

## GAP-0353 — byte-exact boot goldens cannot be regenerated during a sibling edit

**Status:** open (process, not code). **Found by:** two regen rounds.

`VM SECT` and `PMM BASE` are derived from the linked image, so every
byte-exact golden moves when `.text` or `.bss` moves by a single byte. A
regen round of 12 goldens takes ~28 minutes; a sibling landing a 112-byte
`.text` edit inside that window invalidates the ones regenerated before
it, and the verify sweep reports them as failures that look like
regressions. Round one regenerated 12 and four (`m4-fault`, `m8-paging`,
`m9-ring3`, `m10-elf`) were stale again by the time the verify reached
them; a second targeted round took all four green.

**Binary next step:** regen the byte-exact set under an exclusive
`core/build` with no sibling writes to `core/kernel`, or teach the
harnesses to normalise image-derived addresses so only *semantic* serial
changes move a golden.

## GAP-0354 — the four OSMEDIA decode harnesses do not reach a decoded frame

**Status:** **closed.** `de-media` / `de-vblit` / `de-vwin` / `de-movie`
all PASS on this tree (GAP-0353).

**Binary next step:** none for the decode/WIN floor.

## GAP-0355 — `view-door` fails on `sit-in-view.sh --venus`

**Status:** **narrowed.** Venus path boots: `VIRTIO VENUS OK`,
`VIEW MODE 1280x720`, PNG 1280×720 written. `oscortex-abs-pointer` is
not touched (`sit-in-view.sh --kill` no longer pkills it; only
`--kill-all` does).

Fail is the DE presence probe in `sit-in-view.sh`: left island at
`(40, h-chrome+20)` reads copper `0xC87840` (no-DESK Start fallback),
not glass. That probe belongs to the in-flight glass-DE sibling
(`eb01e2ad` / ADR-0197). Serial is quiet enough for MODE/VENUS; the
miss is pixels, not a hung serial.

**Binary next step:** after the glass-DE sibling lands DESK glass
islands on the Venus sit-in image, re-run
`tests/conformance/view-door/run.sh` (unique VNC 5907; do not mass-rm
`oscortex-qemu-gl`; do not kill `oscortex-abs-pointer`).

## GAP-0356 — Glass dock is light fill, not sampled wallpaper blur

**Status:** **closed** by ADR-0198. **Found by:** ADR-0197.

`WM_PAINT_GLASS` + `osgfx_glass_frost` samples the wallpaper (cache or
generative), 5×5 box-blurs, tints, and writes island shm. `de-desk`
proves island samples are not one flat colour (`DESK FROST … VARY`).
Radius is 18 lockstep. Dock icons are glyphs. Settings has Appearance
/ Devices with a blue accent toggle.

**Binary next step:** none for frost/radius/Appearance. Leftover:
live clock, Dashboard, Skia ImageFilter backdrop (optional), SET
window-body sampled frost (toggle probes need exact hexes). Soft-shadow
elevate stays ≤8 while card radius is 18 (de-retain MaskFilter budget).
