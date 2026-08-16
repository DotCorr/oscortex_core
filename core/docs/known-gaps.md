# Known gaps

Work queue, not a confession log (same discipline as the DCDart repo's `CLAUDE.md`). Every entry: what
was worked around, and the cost.

---

## GAP-0001 — M0 boots but has no memory map, no interrupts, no drivers beyond one UART

**Domain:** boot, kernel (M0)
**Status:** OPEN — all explicitly out of scope for M0 on purpose, see `ROADMAP.md`/`OSCORTEX_SPEC.md`.

M0's exit criterion (`docs/decisions/0001-m0-boot-architecture.md`) is deliberately narrow: boot, prove
alive over serial, nothing else. What's missing, for real, before the next milestone:

- **No memory map.** Multiboot's EBX (info struct pointer) is never read. The kernel doesn't know how
  much RAM exists or what's usable — it only knows the first 16MiB is identity-mapped because `boot.S`
  said so, not because anything was measured.
- **No interrupts.** No IDT, no PIC remap, no exception handlers. Any real fault (page fault, GPF,
  divide-by-zero) triple-faults the VM with no diagnostic beyond "it stopped." This also blocks a real
  `timeout`-free shutdown path (`isa-debug-exit` or an actual `ACPI` shutdown would need at least basic
  I/O handling to be worth adding).
- **No drivers beyond COM1**, and even COM1 has no busy-wait on the Line Status Register's
  Transmit-Holding-Register-Empty bit before each `Port.outb` write — DCDart has no bitwise AND
  operator yet (its own spec's "Cut" list), so `LSR & 0x20`-style polling isn't expressible. The M0
  message is kept to 15 bytes, safely under the 16550's 16-byte TX FIFO, so every byte queues in one
  shot without needing to poll — this is fragile and would silently drop bytes for a longer message.
- **No real bootloader.** QEMU's built-in Multiboot loader (`-kernel`) is the only tested boot path.
  BIOS MBR / UEFI boot on real hardware is unbuilt and unverified.

**Cost of the workaround:** none of this was worked around — it's real, un-started work, correctly
scoped out of M0. The next milestone (interrupts, most likely — see `ROADMAP.md`) is what starts
closing these.

---

## GAP-0002 — DCDart-side primitives this kernel needs but doesn't have yet

**Domain:** kernel (blocked on DCDart repo changes, not this repo's to fix directly)
**Status:** OPEN — tracked here so it's visible from the kernel side; the actual work happens in the
DCDart repo's own `docs/known-gaps.md`/`docs/decisions/`.

- **Bitwise operators** (`&`, `|`, `^`, `<<`, `>>`) — needed for real register-flag manipulation
  (LSR polling above, page-table flag bits currently done in hand-written asm instead of DCDart because
  of this, PIC/IDT setup once that milestone starts). DCDart's own spec lists these in its "Cut"
  section — not started.
- **General inline asm / `@naked` / extern-FFI** — `@interrupt` handler entry points need `@naked`
  (no compiler-generated prologue/epilogue); `cli`/`sti`/`lgdt`/`lidt` need either dedicated
  instructions (the same narrow pattern `Port.outb`/`Port.inb` used, ADR-0029 in the DCDart repo) or a
  real general asm mechanism. See DCDart's own `GAP-0019` for the fuller accounting — deliberately not
  built speculatively ahead of a real need.
- **`@interrupt` safety enforcement** (no allocation inside an interrupt handler, compiler-enforced) —
  mentioned in DCDart's `CLAUDE.md` coding rules as a real requirement, not implemented at all yet.

**Cost of the workaround:** the page-table/GDT setup that would ideally be expressible in DCDart stays
hand-written assembly in `boot.S` for now. This is honest, not a hidden cost — `boot.S`'s own header
comment already documents this is intentional (see `OSCORTEX_SPEC.md` §5's provides-vs-hand-written
table).

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
