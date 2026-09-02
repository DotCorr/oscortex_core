# ADR-0003: A real UART driver module, and reading the Multiboot information structure

**Status:** VERIFIED — `core/tests/conformance/mb-info/run.sh` reports an unqualified PASS: real
`dcc build` → real assembly → real link → `verify-freestanding.sh` clean on both `kmain.o` and
`kernel.elf` → a real `qemu-system-x86_64 -kernel` boot → the full 433-byte captured COM1 output
matching `expected.txt` byte-for-byte (`cmp`). `core/tests/conformance/m0-boot/run.sh` still reports
PASS.

Numbered 0003 rather than 0002 only because `0002-m1-interrupts-architecture.md` was written in the
same change; ADR numbers are identifiers, not a chronology.

## Context

Two items of `docs/known-gaps.md` GAP-0001:

- "Multiboot's EBX (info struct pointer) is never read. The kernel doesn't know how much RAM exists."
- COM1 "has no busy-wait on the Line Status Register's Transmit-Holding-Register-Empty bit", and real
  polling "belongs in a proper, reusable UART driver module, which the interrupts milestone will need
  to build anyway."

GAP-0001 recorded the LSR busy-wait as blocked on a `u8` comparison operator DCDart did not have.
**It is no longer blocked.** DCDart's `u8 operator <` landed with its ADR-0035, alongside `u8` `+`,
`-`, `*`, `<=`, `>`, `>=`, `~/`, `%` at all four widths. Verified by compiling the real loop, not by
reading the prelude.

*(That DCDart work was uncommitted when this ADR was written. It is committed now —
`DCDART_PIN.txt` points at `531cb89` and GAP-0005 is closed.)*

## Decision 1 — `part`/`part of`, not `import`, for kernel modules

`core/kernel/` is now three files: `kmain.dart` (the library root), `uart.dart`, `multiboot.dart`. The
latter two are `part of 'kmain.dart'`.

This is **forced**, not stylistic. `dcc-lower` lowers exactly one Kernel library per `dcc build` — the
one whose `importUri` matches the source path on the command line
(`core/dcc-lower/lib/lower.dart`'s `component.libraries.firstWhere(...)`). A `@bare` function in an
imported DCDart library is **silently dropped**: it never reaches DC-IR, never reaches the object file,
and the only symptom is an undefined symbol at link time — a bad failure mode, since nothing along the
way says "your file was ignored."

Verified empirically both ways before committing to it: the same two functions split across an
`import` produced neither symbol; split across `part`/`part of` produced both in one `.o`. `part`
files belong to the same library, so their procedures land in `targetLibrary.procedures` and lower
normally.

Filed as a DCDart-side need (`docs/known-gaps.md` GAP-0004): either lower every `@bare` library in the
component, or at minimum make a dropped library a hard error rather than a silent one.

## Decision 2 — every driver function returns `u64`, even when it returns nothing — **REVERSED**

**Superseded 2026-08-20.** DCDart now allows a void-returning `@bare` or `@extern` call to stand alone
as a statement, so these functions return `void` again and the `final u64 _ = ...` noise is gone.
Re-verified by compiling both shapes before changing anything. `docs/known-gaps.md` GAP-0004 item 3.
The original reasoning is kept below because it explains why the code looked the way it did.

`dcc-lower` has no `ExpressionStatement` case for a call to a `@bare` function. `uartPutc(x);` as a
statement is a hard compile error: *"unsupported expression statement StaticInvocation … M1 only
understands `pointer.value = x;` … and `Port.outb(port, value);`"*. Only calls in **value position**
lower.

So every function in `uart.dart`/`multiboot.dart` returns `u64` and every call site reads
`final u64 _ = uartPutc(...);`. It is noise on every line and it is honest noise — inventing a
wrapper to hide it would hide a real language gap. Filed in GAP-0004.

## Decision 3 — the LSR busy-wait, and what is still fragile about it

```dart
u8 lsr = Port.inb(u16(0x3FD));
while ((lsr & u8(0x20)) < u8(1)) {
  lsr = Port.inb(u16(0x3FD));
}
Port.outb(u16(0x3F8), c);
```

Verified structurally, not assumed — disassembling `uartPutc` shows a real `in (%dx),%al` / `and` /
`cmp` / `jae` back edge with the `out %al,(%dx)` only on the exit path.

`< u8(1)` rather than `== u8(0)`: Dart refuses to let an extension type declare `operator ==` at all
(DCDart's ADR-0035 §3), so `<` goes through the same generalized operator path as every other
comparison and needs no special case.

**Still fragile, stated plainly: there is no timeout.** If COM1 is absent or wedged, THRE never sets
and this spins forever with interrupts disabled — hanging the machine silently rather than failing
loudly. A bounded spin is expressible; "give up and do what?" is not answerable yet, because there is
no second output device, no panic path, and no way to signal failure to the harness. Left unbounded
deliberately rather than bounded-and-silently-lossy. Recorded in GAP-0001 as still open.

## Decision 4 — hex output is read out of memory, never computed in a register — **PARTLY SUPERSEDED**

**Superseded 2026-08-20 for computed values.** `.toU8()` (DCDart ADR-0037) exists, so
`uartPutHex(value, digits)` can format a `u64` held in a register — which is what M1's `M1 IDT 0100`,
`M1 PIC 20` and `M1 TICKS` lines need. The `...At` variants are KEPT and still used by
`multiboot.dart`: reading little-endian memory and printing big-endian is a genuinely different
operation from formatting a register value. The original reasoning follows.

Every number this kernel prints is loaded from memory one byte at a time via `Pointer<u8>` and split
into nibbles with `u8` `>>`/`&`. That looks like a strange way to print a number. It is the only way.

**DCDart has no width-conversion primitive of any kind** — no widening, no narrowing, at any width.
`core/dc-ir/lib/instructions.dart` states it directly: a source-level `.toU32()` "lowers to an explicit
truncate/extend instruction; that instruction is not yet [implemented]". `dcc-lower` additionally
rejects `u8(someRuntimeExpression)` outright — sized-int constructors accept integer **literals** only.

So a nibble extracted from a `u64` cannot become the `u8` that `Port.outb` requires. There is no cast,
no constructor, no operator that crosses widths. Extracting the nibble from a `u8` that was loaded as
a `u8` keeps the whole computation at one width and needs no conversion — and turns nibble-to-ASCII
into two branches (`+0x30` / `+0x37`) instead of a 16-arm dispatch.

The same constraint drives Decision 5.

## Decision 5 — 32-bit Multiboot fields are read as masked 64-bit loads — **REVERSED**

**Superseded 2026-08-20.** `.toU64()` (DCDart ADR-0037) landed, so each field is now an ordinary
`Pointer<u32>` load widened explicitly. Every 8-byte load is gone, and with it the three runtime
**8-byte** alignment guards that existed only to make those loads well-defined. The file still guards
alignment, but now checks the **4-byte** alignment Multiboot1 actually guarantees. `mb-info` still
passes byte-for-byte after the change. The original reasoning follows.

A `u32` read out of the Multiboot information structure is a **dead end**: it cannot become a
`Pointer` address, a loop bound, or a stride, because nothing converts it to `u64`. Three fields need
to cross that line — `mmap_length` (loop bound), `mmap_addr` (base address), and each entry's `size`
(stride).

The technique used is to load **eight** bytes at an 8-aligned address and mask or shift out the half
wanted:

- `flags` → `load64(info + 0) & 0xFFFFFFFF`
- `mmap_length` (at +44) → `load64(info + 40) >> 32`
- `mmap_addr` (at +48) → `load64(info + 48) & 0xFFFFFFFF`
- entry `size` (at +0) → `load64(entry) & 0xFFFFFFFF`

**Every one of those loads is guarded by an explicit runtime 8-byte-alignment check** that reports a
distinct `MB BADP` / `MB BADM` / `MB BADE` marker and stops. Multiboot1 guarantees only 4-byte
alignment for the information structure, and DCDart's `Load` carries no alignment attribute at all —
`llvm_emit.dart` emits a bare `load i64, ptr %v`, so LLVM assumes ABI alignment. Rather than perform a
technically-undefined load and rely on x86 tolerating it, the kernel checks and refuses.

Under QEMU all three addresses are 8-aligned in practice, so the guard paths are **not exercised** by
the harness. That is stated rather than glossed: those three branches are compiled and unreached.

A real `u32 → u64` widening in DCDart would delete this entire decision and all three guards. Filed in
GAP-0004.

Fields that are only *printed*, never computed with — `flags`, `mem_lower`, `mem_upper`, each entry's
`base_addr`/`length`/`type` — need none of this; `uartPutHex32At`/`uartPutHex64At` read them a byte at
a time.

## Decision 6 — EBX is stashed in `.bss`, not kept in a register

`boot.S` writes EBX to a dedicated `.bss` dword at the top of `_start` and reloads it into EDI
immediately before `call kmain`.

EBX does happen to survive the current long-mode transition untouched, so a register stash would work
today. It was rejected anyway: every register in that sequence is fair game (the page-table loops
clobber EAX/ECX/EDI, `rdmsr`/`wrmsr` clobber EAX/ECX/EDX, and all three control-register writes go
through EAX), so a stash that survives *by inspection* would become a silent corruption the first time
someone adds a step. A `.bss` dword costs four bytes and cannot be clobbered by accident.

`movl multiboot_info_ptr, %edi` — a 32-bit move — is deliberate: writing a 32-bit register
zero-extends into the full 64-bit register, which is exactly what `kmain`'s `u64` parameter needs.

**One real bug this introduced and fixed before it could bite:** adding a 4-byte object to `.bss`
above the boot stack silently made `stack_top` 4-mod-16. Before this change `stack_top` was
4096-aligned only by accident of `p4`/`p3`/`p2` each being exactly 4096 bytes. The System V AMD64 ABI
requires RSP to be 16-byte aligned at every `call` site, which DCDart's backend assumes since it
targets that ABI. Fixed with an explicit `.align 16` before `stack_bottom`, so the property is stated
rather than inherited. This would not have shown up in M0's output; it would have shown up as a crash
on the first SSE spill DCDart ever emits.

## Decision 7 — M0's harness now asserts its first line, not the whole file

*(Extended by M1: `mb-info` in turn became a prefix compare through `MB END`, and
`m1-interrupts/run.sh` now asserts the whole capture. Same layering, same reasoning — each harness
owns its own milestone's claim and the newest one owns the whole file.)*

`core/tests/conformance/m0-boot/run.sh` used to `cmp` the entire capture against `OSCORTEX M0 OK\n`.
The kernel legitimately prints more now, so that had to change.

It asserts the **first 15 bytes** (`head -c` on the expected byte count, not `head -1` — a short
capture or a missing newline must still fail) against the same fixed message.

**This is a weakening of that harness taken alone** — it no longer proves "and nothing else was
printed" — and it is called out in the script itself rather than glossed. The property is not lost, it
moved: `core/tests/conformance/mb-info/run.sh` asserts the **entire** 433-byte capture byte-for-byte,
first line included, so the two harnesses together assert strictly more than the one did before. Both
must be run.

The alternatives were worse: folding M1-scope output into M0's exit criterion, or not doing the work.

## Verification

**[VERIFIED] Real boot, real memory map.** The captured output is not "whatever it printed" — every
figure was cross-checked independently against `-m 128M`:

| Reported | Value | Independent check |
|---|---|---|
| `MB LOW 0000027F` | 639 KiB | conventional memory below 1MiB, minus the 1 KiB EBDA |
| `MB UPP 0001FB80` | 129920 KiB | 131072 (128 MiB) − 1024 (first MiB) − 128 (reserved at top) |
| `MB MAP 000000A8` | 168 bytes | 7 entries × 24 bytes each — and exactly 7 `MB E` lines follow |
| entry 1 | `0..0x9FC00` type 1 | 654336 bytes = 639 KiB, matching `MB LOW` exactly |
| entry 2 | `0x9FC00` +0x400 type 2 | the 1 KiB EBDA |
| entry 3 | `0xF0000` +0x10000 type 2 | the 64 KiB BIOS ROM window |
| entry 6 | `0xFFFC0000` +0x40000 type 2 | 256 KiB BIOS flash at the top of 4GiB |

**[VERIFIED] Deterministic.** Three consecutive boots produced byte-identical captures (same MD5), and
the capture is byte-identical with and without `-m 128M`. The flag is pinned in the harness anyway, so
a QEMU that changes its default RAM size fails as a harness assumption rather than looking like a
kernel bug.

**[VERIFIED] Freestanding.** `verify-freestanding.sh` reports `pass` for both `build/kmain.o` and
`build/kernel.elf`. (`build/boot.o` alone legitimately has one undefined symbol, `kmain`, which only
the link resolves — that has been true since M0, and the harnesses do not check it in isolation.)

## Consequences

- The UART driver exists and is reusable — `uartPutc`, `uartPutNibble`, `uartPutHexByteAt`,
  `uartPutHex32At`, `uartPutHex64At`. M1 needs exactly these to print exception diagnostics.
- The memory map is **read and reported, not retained**. There is nowhere to put it: DCDart has no
  static data and this kernel has no allocator, so nothing can outlive the `mbReport` call. A real
  physical memory manager is a later milestone and needs the static-storage gap closed first.
- `docs/known-gaps.md` gains GAP-0004 (five DCDart-side needs this work surfaced) and GAP-0005 (the
  dependency on uncommitted DCDart work, and the now-untruthful `DCDART_PIN.txt`).
