# ADR-0004: Fixed messages become `@rodata` byte tables, and a real string-output primitive

**Status:** VERIFIED — all three conformance harnesses (`m0-boot`, `mb-info`, `m1-interrupts`) report
an unqualified PASS with **completely unchanged golden files**. The serial capture is byte-for-byte
what it was before this change, produced by an entirely different mechanism.

## Context

Since M0, every fixed message this kernel prints was a hand-written run of one `Port.outb`/`uartPutc`
call per character. `docs/known-gaps.md` GAP-0001 and GAP-0004 both recorded the reason: `@bare`
DCDart had no String type, no array type, and no static data of any kind, so there was genuinely no
other way to spell a literal message.

DCDart ADR-0040 added `@rodata final List<uN> t = const [...]` plus `Rodata.addressOf(t)`. That is
exactly the missing piece.

## Decision

### 1. `uartWrite(base, len)` — one primitive, not a reimplementation

A base address and a length, looping over `Pointer<u8>` and calling the **existing** `uartPutc` per
byte. `uartPutc`'s Transmit-Holding-Register-Empty poll is what makes output longer than one 16-byte
FIFO safe; duplicating that logic inside a bulk-write path would be two places to get it wrong, for no
gain — the poll cost is per byte either way.

### 2. Lengths are passed, not derived — and the alternative was tested, not assumed

A `@rodata` table carries **no length word**: ADR-0040's central layout promise is elements only, no
header of any kind, so `Rodata.addressOf(t)` *is* element 0's address. The length therefore has to
come from somewhere else.

NUL-termination was the obvious alternative and was rejected: it makes the data self-describing, but
it puts a run-away loop one missing byte away from spinning forever inside a `cli` region — the same
unbounded-hang failure mode `uartPutc`'s own missing timeout already has (GAP-0001), and there is no
reason to add a second instance of it.

Passing an explicit count duplicates a number next to a literal, which is a classic drift bug. That
risk is **covered mechanically rather than by care**: every byte this kernel prints is asserted
byte-for-byte by three harnesses, so a wrong length changes the capture and fails immediately.
Verified by deliberately breaking one — changing `M1 END`'s length from 7 to 6 produced
`M1-interrupts: FAIL`, exit 1. The count is written in each table's doc comment next to the string it
describes, so the two are read together.

### 3. One table per whole line prefix, not one per word

`mbPrefix()` and `m1Prefix()` are gone. Rather than emitting `"MB "` and then `"FLAGS "`, each line
has a single table containing its complete fixed prefix (`"MB FLAGS "`, `"M1 TICKS "`), and lines with
no variable part are one table including the trailing newline (`"MB END\n"`). Fewer tables, one
`uartWrite` per line, and the literal in the source reads as the thing that appears on the wire.

### 4. `List<u8>`, because the declared type is the only source of element width

ADR-0040 rejects `List<int>` outright: the constant erases every sized-int extension type to a bare
`IntConstant`, so the declared type is the only thing that can decide stride. This kernel would have
used `List<u8>` regardless — these are bytes — but it is worth recording that the strictness is
load-bearing, not stylistic: the failure mode it prevents is reading at the wrong stride and getting
plausible garbage rather than an error.

## Verification

**Byte-for-byte identical output from a different mechanism.** The goldens were not regenerated and
not touched. That is the strongest available evidence the conversion is a pure refactor, and it is a
genuinely demanding test of `@rodata` itself: a header in front of element 0, a wrong stride, or a
mis-emitted table would all have shifted the output.

**Structural assertions, added to `m1-interrupts/run.sh` so they run every time:**

- `kernel.elf` has **no `.got`/`.got.plt`**. This is the first change that could have produced one; a
  GOT would mean the toolchain decided a fixed-address 1MiB kernel needed position-independent
  indirection, which would be both wrong and silent. `core/link/kernel.ld` places `.rodata.*`, `.got`
  and `.got.plt` explicitly so neither can be silently orphaned.
- All 16 tables are `OBJECT` symbols in **`.rodata`'s** section index — none landed somewhere
  writable or unloaded.
- `.rodata`'s size **equals the sum of the table symbol sizes** (127 bytes across 16 tables). This is
  the assertion that actually pins ADR-0040's "elements only" promise: a per-table header or length
  word would inflate the section beyond the sum. Exact equality holds while every table is `List<u8>`
  (1-byte aligned, no inter-table padding); a wider table would introduce legitimate padding and this
  should become `>=` as a deliberate edit.

## What this does NOT resolve

**Runtime strings.** There is still no `Str`/`String`, no array type, no concatenation, no formatting.
Everything here is a **compile-time-constant byte table**. A message that has to be built or modified
at runtime needs a real string type and an allocator, and neither exists.

**The Multiboot memory map still cannot be retained**, and `@rodata` does not move that at all — its
contents are unknowable at compile time, so it can never be read-only data in any form. Retaining it
needs *mutable* static storage, which DCDart deliberately does not have: a module-level mutable global
is a memory-model question frozen under DCDart's `CLAUDE.md` rule 4 and escalated rather than decided.
No workaround was attempted.

**No extern was eliminated.** Checked rather than assumed — see `docs/known-gaps.md` GAP-0002 for the
nine-row audit and the real error message that settles the `isr_stub_table_addr` case.

## A note on the pin, because the check mattered again

While this work was in progress DCDart's working tree carried uncommitted changes (struct constants in
`@rodata`, since committed). Rather than assume the kernel did not depend on them, it was built
against a **pristine clone checked out at `3d3dfee`** in a correct sibling layout: every allocated
section of `kernel.elf` came out byte-identical, and the booted serial output matched the golden
exactly. So the dependency was genuinely only on committed work.

Two traps worth recording, because both produced a *confident wrong answer* first:

1. The first attempt pointed `DCDART_HOME` at the clone but left the kernel in place. It failed with
   *"no @bare top-level function found"* — not a real dependency, but GAP-0003 biting: `kmain.dart`
   imports the prelude by a hardcoded relative path, so the prelude came from the working tree while
   `dcc` matched annotations against the clone's URI. Fixed by building a full sibling layout.
2. An `objcopy --only-section` comparison of the two images "passed" before its output sizes were
   checked — two empty files compare equal. Re-run with sizes printed (`.text` 8346, `.rodata` 2215),
   it was a real comparison.

`DCDART_PIN.txt` ends up at the current clean HEAD, with the full suite re-run against it.
