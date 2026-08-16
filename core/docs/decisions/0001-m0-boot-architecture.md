# ADR-0001: M0 boot architecture — Multiboot1, hand-written long-mode transition, COM1 proof of life

**Status:** VERIFIED — `core/tests/conformance/m0-boot/run.sh` reports an unqualified PASS: real
`dcc build` (kmain.dart) + real assembly (boot.S) + real link (kernel.ld) + `verify-freestanding.sh`
clean + a real `qemu-system-x86_64` boot with the captured COM1 serial output matching the expected
15-byte message exactly (`cmp`, byte-for-byte, not eyeballed).

## Decision

- **x86_64 only.** DCDart's backend has only ever verified `x86_64-unknown-none-elf` as a target
  triple — using anything else for the kernel would be genuinely unverified, unbudgeted risk on top of
  an already-new project.
- **Multiboot1, not v2.** `qemu-system-x86_64 -kernel` loads a Multiboot1 image directly — no GRUB, no
  ISO. M0 needs none of Multiboot2's extra tags (memory map, modules).
- **Hand-written assembly (`boot.S`) owns the 32-bit→long-mode transition** — GDT, PAE identity page
  tables (2MiB pages, first 16MiB), `EFER.LME`, `CR0.PG`, far jump into a 64-bit code segment — then a
  plain C-ABI `call kmain()`. This is the exact same "asm stub calls into DCDart via C ABI" pattern
  DCDart's own `m0-seam`/`m1-pointer` conformance harnesses already prove works, just permanent here
  instead of test-only. DCDart itself has no primitive for any of this (no inline asm beyond the
  narrow `Port.outb`/`Port.inb`, see the DCDart repo's GAP-0019) and building one would be premature.
- **Proof of life = COM1 serial (16550 UART) output**, not VGA. `kmain()` (real `@bare` DCDart, calling
  DCDart's `Port.outb`/`Port.inb`, ADR-0029 in the DCDart repo) initializes the UART with the standard
  init sequence and writes a fixed 15-byte message, `"OSCORTEX M0 OK\n"`, one `Port.outb` call per
  byte — `@bare` has no String/array type yet, so there's no other way to spell this.

## Two real bugs found and fixed, both via the actual toolchain, not guessed

**1. QEMU rejects a 64-bit ELF container.** The first link attempt produced a genuine x86_64 ELF64
executable; QEMU's built-in Multiboot loader refused it outright: `"Cannot load x86-64 image, give a
32bit one."` — a real error message from actually trying it, not a documentation assumption. A second
attempt, linking as `elf32-x86-64` (32-bit ELF container, x86-64 machine type/relocations), was tried
as a plausible middle ground and *also* failed the same way. Only genuine `elf32-i386` satisfied QEMU.
The 64-bit relocations DCDart's backend emits for `kmain.o` still link cleanly into an i386-formatted
output (every address here is well under 4GiB) — the ELF format is loader metadata only, it doesn't
restrict what raw instruction bytes `.text` actually contains, so the real 64-bit code after the
long-mode transition is completely unaffected by the container format.

**2. The Multiboot header silently vanished from the linked image.** `.multiboot`'s own `.section`
directive in `boot.S` had no explicit flags — GAS doesn't recognize a non-standard section name like
`.multiboot` and defaults it to *no section flags at all* (confirmed via `readelf -S boot.o`: an EMPTY
flags column, versus `.text`'s `AX` or `.rodata`'s `A`). `ld` then correctly, per the flags it actually
saw, excluded a non-allocatable section from every loadable segment — the header's bytes were still
physically present in the file, just outside the loaded image entirely. Fixed with an explicit `"a"`
(`SHF_ALLOC`) flag on the `.section .multiboot` directive.

Both were diagnosed by reading real tool output (`readelf -S`/`-l`, QEMU's own stderr) at each step,
not by reasoning about what *should* happen — exactly the discipline `CLAUDE.md`'s own "verify against
the real toolchain" rule (inherited in spirit from the DCDart repo) exists for.

## A design choice tested and deliberately not kept: `PHDRS`

An explicit `PHDRS` block forcing every section into one `PT_LOAD` segment was added while chasing bug
2 above, before the real cause (the missing `SHF_ALLOC` flag) was found. After fixing the real bug,
`PHDRS` was re-tested by removing it: without it, `ld`'s default orphan-section handling puts `.bss`
in its own second segment instead, which *also* boots correctly and produces the identical serial
output. `PHDRS` was kept anyway — one segment is simpler to reason about — but the ADR record is
honest that it wasn't the load-bearing fix, the section flag was.

## Consequences

- `docs/known-gaps.md` gets entries for what M0 deliberately doesn't do yet: no memory-map/Multiboot2
  parsing, no interrupts/IDT/PIC, no busy-wait on the UART's Transmit-Holding-Register-Empty bit
  (DCDart has no bitwise AND operator yet — the message is kept short enough to fit the 16550's 16-byte
  TX FIFO in one shot instead), no real bootloader (BIOS MBR/UEFI), no `isa-debug-exit`.
- The RWX-permissions warning `ld` emits on every link is expected and accepted for M0 — there's no
  fine-grained page-permission policy yet (the identity-mapped PD entries mark the whole first 16MiB
  present+writable at 2MiB granularity, no separate read-only/no-execute regions).
- `kernel.ld`'s two fixes (ELF format, and the general "watch for GAS defaulting non-standard section
  names to zero flags" lesson) are worth remembering for any future custom `.section` this project
  adds.
