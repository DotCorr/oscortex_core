# oscortex_core

A from-scratch modern operating system, written primarily in [DCDart](https://github.com/DotCorr/DCDart)
— a native systems language with Dart's syntax, ARC memory management, no VM.

Everything buildable lives under [`core/`](core/README.md). Start there.

## Status

**M0 — done.** A `@bare` DCDart kernel boots under QEMU (x86_64, Multiboot1) and proves it's alive
over COM1 serial output — verified end to end (`core/tests/conformance/m0-boot/run.sh`), not a stub.
It also now reads the Multiboot memory map the loader hands it and prints it over a real 16550 UART
driver, asserted byte-for-byte by `core/tests/conformance/mb-info/run.sh`.

**M1 — done.** The kernel installs a 256-gate IDT, remaps the 8259 PICs, runs a 100 Hz PIT timer, and
handles a real CPU exception in DCDart with a printed diagnostic — where at M0 the same fault would
have triple-faulted the VM silently. Verified end to end by
`core/tests/conformance/m1-interrupts/run.sh`, byte-for-byte, not a stub.

**M2 — done.** The kernel drives an 80x25 VGA text console at `0xB8000` (real scrolling, real
hardware cursor) and takes real PS/2 keyboard input on IRQ1, without moving one byte of the serial
output three earlier harnesses depend on. `core/tests/conformance/m2-console/run.sh` injects real
keystrokes into QEMU's emulated PS/2 controller over QMP and asserts the serial capture, the
framebuffer read out of guest physical memory, and a PNG screenshot.

**M3 — done.** It is a shell now, not an echo box: a prompt, a line you can edit and submit, and
commands that dispatch — `help`, `clear`, `mem` (re-walks the Multiboot memory map and totals usable
RAM), `ticks` (watches the timer counter advance), `echo`, and a named error for anything else.
Commands run in task context with interrupts enabled, not inside the keyboard interrupt handler.
`core/tests/conformance/m3-shell/run.sh` drives a full session over QMP and asserts it six ways,
including a negative control.

**M4 — done.** The kernel survives its own mistakes. Two shell commands fault on purpose — `crash ud`
(an invalid opcode, from DCDart's own overflow trap) and `crash div` (a real hardware divide error) —
and the kernel catches each one, prints a diagnostic that includes the first two bytes of the
instruction *at the faulting address*, throws away the computation that faulted, and returns you to a
working prompt. `help`, `mem`, `ticks` and `cpu` all keep working afterwards. There is a `cpu` command
too, reading the CPUID vendor and brand strings out of the hardware.
`core/tests/conformance/m4-fault/run.sh` drives a session with three deliberate faults and asserts it
nine ways, including a negative control that also faults.

**M5 — done.** The kernel can find hardware nobody told it about. Every device it drove before this
was located by a constant compiled into it — `0x3F8` for the serial port, `0x60` for the keyboard,
`0xB8000` for the screen — which is a bet that the machine is shaped like a 1990 PC. A new `pci`
command enumerates PCI configuration space over the legacy `0xCF8`/`0xCFC` port pair and prints what
is actually there: bus, device, function, vendor and device IDs, class, subclass, prog-IF, header
type, and a short decoded class name (or the raw number, never a guess). It honours the multi-function
bit rather than probing blindly, and it follows PCI-to-PCI bridges to the buses behind them.

```
oscortex> pci
PCI 00:00.0 8086:1237 06/00/00 H00 host bridge
PCI 00:01.0 8086:7000 06/01/00 H80 isa bridge
PCI 00:01.1 8086:7010 01/01/80 H00 ide storage
PCI 00:01.3 8086:7113 06/80/00 H00 bridge
PCI 00:02.0 1234:1111 03/00/00 H00 vga display
PCI 00:03.0 8086:100E 02/00/00 H00 ethernet
PCI TOTAL 0006
```

`core/tests/conformance/m5-pci/run.sh` boots three times and asserts eleven things — including that
the device list matches **QEMU's own `info pci`** from the same boot, so the kernel is checked against
an independent description of the machine rather than only against a golden it wrote itself, and that
a boot with a real PCI bridge attached finds a device on a bus that exists in no other boot.

**And then it draws on one of them.** `fb` finds the display controller by PCI class, reads BAR0 —
`0xFD000000` on this machine, discovered rather than hardcoded — sets 800x600 at 32bpp through the
Bochs VBE registers, and renders text into the linear framebuffer with an 8x16 bitmap font kept in
`.rodata`. From then on the shell runs on it: the prompt, `pci`, `cpu`, everything.

Three things had to be true first, and the third was a surprise. The framebuffer's address was not
mapped (`boot.S` covered the first 16MiB; it now identity-maps the 3–4GiB PCI hole as well). The
mode-set ports are 16-bit and DCDart's port primitive is byte-wide. And `0xB8000` turned out to be an
*aperture into the adapter's video RAM* rather than separate memory — setting a graphics mode
repoints it, so the text buffer stops being a text buffer. That was measured, not assumed: the first
build wrote both screens and the text buffer came back full of pixels. The kernel therefore drives
one screen at a time, and serial is unaffected, which is the third time this project's decision to
make COM1 primary has quietly been the thing that mattered.

**What this is, and is not:** the kernel *finds* devices and drives exactly one of them. It cannot
write configuration space at all — no BAR sizing, no bus-master bit, no MSI. It keeps nothing: the
scan prints as it walks, because there is still nowhere to put a device list. The framebuffer console
does not scroll (a pixel-row scroll is a 1.9MiB move and there is no `memcpy`), the mode-set path
works on QEMU/Bochs and no real machine, and the font covers printable ASCII with a deliberately
visible fallback box for everything else. See `core/docs/decisions/0008-pci-enumeration.md` and
`0009-framebuffer-console.md`, and `docs/known-gaps.md` GAP-0067, GAP-0070 and GAP-0071.

**M6 — done.** The kernel can read a disk. M5 left it able to *see* an IDE controller at `00:01.1`
and unable to read a byte of it — and up to that point every byte this kernel had ever printed came
out of a register it was compiled to know the address of, a constant in its own image, or the
structure the loader handed it. Nothing had ever come from outside the running machine.

```
oscortex> disk id
DISK ID SIG 0000 MODEL QEMU HARDDISK SECTORS 00000080 OK
oscortex> disk read 2a
DISK READ LBA 0000002A
0000 4F 53 43 4F 52 54 45 58 20 53 45 43 54 4F 52 20
0010 30 30 32 41 C3 CA D1 D8 DF E6 ED F4 FB 02 09 10
...
01F0 C7 CE D5 DC E3 EA F1 F8 FF 06 0D 14 1B 22 29 30
DISK READ END
```

That is ATA PIO on the primary channel: IDENTIFY for the model and capacity, LBA28 READ SECTORS for
the data, polled — no DMA, and therefore no need for the physical memory manager this kernel still
does not have. It also has **no sector buffer**: it prints each 16-bit word as it arrives off the
data port, which is why it costs nothing in donated storage and why it can *show* you a sector but
cannot *give* you one.

`core/tests/conformance/m6-disk/run.sh` generates a deterministic disk image, re-reads it from the
filesystem to verify what it wrote, boots with it attached, and asserts the hexdump **against the
bytes it put there** — the expectation computed by calling the generator, never typed. Two negative
controls: flipping one bit on the disk must change exactly one dumped byte, and a boot with **no
drive attached** must report `DISK ERR NODEV ST 00` and print no hexdump anywhere. That last one is
the assertion that makes the others mean something — it is the proof that the dump comes off the disk
rather than out of the kernel.

**What this is, and is not:** one sector at a time, read only, primary master only, LBA28 only, and
polled with every wait bounded so a wedged controller fails loudly instead of hanging silently. There
is no `read(lba) -> bytes`, so there is no filesystem, no partition table and no block cache — all
three are the same missing thing, and it is the same missing thing the memory manager is waiting on.
See `core/docs/decisions/0010-ata-pio-disk-read.md` and `docs/known-gaps.md` GAP-0073 and GAP-0074.

**M7 — done. The kernel remembers what memory it has.** Since M0 it has parsed the loader's memory
map, printed it, and thrown it away — because nothing in this kernel could outlive the call that
produced it. Three subsystems were shaped by that: the memory map, the PCI bus, and every sector the
disk driver read. M7 closes it for physical memory.

```
oscortex> frames
PMM BASE 00000000001191B0 STORE 00001240 BITMAP 00001000 META 00000040 LEDGER 00000200
PMM BOUND 00008000 FRAME 00001000 LIMIT 00000080 MIB
PMM MANAGED 00008000 FREE 00007EC5 USED 0000013B BASELINE 00007EC5
PMM ALLOCS 0000000000000000 ERRORS 00000000 OVER 00000000
oscortex> alloc
PMM ALLOC 000000000011B000
oscortex> free 100000
PMM FREE 0000000000100000 ERR RESERVED
oscortex> frames drain
PMM DRAIN TOOK 00007EC4 SUM 000000001FEF2516 XOR 0000000000000000
PMM DRAIN LOW 000000000011C000 HIGH 0000000007FDF000
PMM DRAIN TOUCH 0000000007FDF000 C3C3C3C3C43E33C3 OK
PMM DRAIN NEXT 0000000000000000 FREE 00000000
```

A bitmap over 4KiB frames: 4096 bytes of bitmap covering 128MiB, built from the type-1 regions of the
Multiboot map, with the first megabyte and **the kernel's own image** reserved — extents read from the
linker script, `.bss` included, so the allocator reserves the frame its own bitmap lives in.
`allocFrame()` returns a physical address or 0; `freeFrame()` catches double frees, unaligned
addresses, out-of-range frames and frames that were never allocatable, and counts every refusal.

**Why this took until M7, and what changed.** DCDart has no mutable static data, so the bitmap can
only be assembly-donated `.bss` — and four earlier milestones declined to build the kernel's most
important subsystem on a workaround, because that would make the workaround load-bearing and turn the
eventual language fix into a rewrite. That objection was answered by *shape* rather than by waiting:
every mutable byte lives in **one** block behind **one** accessor, reached through **three** functions
marked as a storage seam, and the harness **counts the call sites** so it stays that way. When DCDart
grows mutable statics the migration is three functions and a deletion.

`core/tests/conformance/m7-frames/run.sh` boots four machines. Every number the kernel prints is also
recomputed by `derive.py` from the boot's own memory-map lines and the ELF's kernel extents, so
regenerating the golden cannot make a wrong allocator pass. The whole 4096-byte bitmap is read out of
**guest physical memory** and compared bit-for-bit; a second boot dumps it in the *drained* state,
where N allocations must leave all 32768 bits set — which is what makes "no frame was handed out
twice" a proof rather than a hope. A 256MiB boot must report the exact number of frames above the
bound and say `CAPPED`; a 32MiB boot is the negative control, where every number must change.

**What this is, and is not:** a *physical* memory manager. It hands out one frame at a time, returns a
`u64` rather than typed memory, does not zero frames, does not know who owns one, has no lock, and is
not virtual memory — nothing maps anything at runtime. It is the prerequisite for paging, not paging.
See `core/docs/decisions/0011-physical-memory-manager.md` and `docs/known-gaps.md` GAP-0076.

**What this is, and is not:** fault survival with *abandonment* of the faulting computation. The
command that faulted is gone — not repaired, not retried, not resumed. Resuming a failed computation
after fixing its cause is a condition system, and that needs language support neither this kernel nor
DCDart has. See `core/docs/decisions/0007-fault-recovery-and-cpuid.md`.
