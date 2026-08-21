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
PMM BASE 00000000001201B0 STORE 00001240 BITMAP 00001000 META 00000040 LEDGER 00000200
PMM BOUND 00008000 FRAME 00001000 LIMIT 00000080 MIB
PMM MANAGED 00008000 FREE 00007EB8 USED 00000148 BASELINE 00007EB8
PMM ALLOCS 0000000000000006 ERRORS 00000000 OVER 00000000
oscortex> alloc
PMM ALLOC 0000000000128000
oscortex> free 100000
PMM FREE 0000000000100000 ERR RESERVED
oscortex> frames drain
PMM DRAIN TOOK 00007EB7 SUM 000000001FEF165C XOR 0000000000000128
PMM DRAIN LOW 0000000000129000 HIGH 0000000007FDF000
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
not virtual memory by itself — M8 is what maps anything at runtime, and the `ALLOCS 6` above is M8's page tables, taken from this allocator at boot. It is the prerequisite for paging.
See `core/docs/decisions/0011-physical-memory-manager.md` and `docs/known-gaps.md` GAP-0076.

**M8 — done. The kernel protects itself from itself.** Until now the whole image was one `PT_LOAD`
with `FLAGS(7)` — read, write and execute on everything — and `boot.S`'s flat 2MiB identity map
honoured exactly that. A stray pointer could rewrite code, and a store through a pointer derived from
a constant global **succeeded silently**: no compile-time check, and no runtime check either.

```
oscortex> vm
VM CR3 0000000000122000 PML4 0000000000122000 NX 1 WP 1 READY 1 STATUS 00000000
VM FRAMES 00000006 SPAN 0000000000122000 0000000000127000
VM PAGES 4K 00000400 2M 0000023E
VM TEXT   0000000000100000 0000000000113000 P 00000013 W 00 X 11
VM RODATA 0000000000113000 0000000000115000 P 00000002 W 00 X 00
VM DATA   0000000000115000 0000000000400000 P 000002EB W 11 X 00
VM CANARY C34F534352575821
oscortex> vmtest rw
VM TEST RW ADDR 0000000000121420 5A5A5A5A5A484E7A OK
oscortex> vmtest ro
VM TEST RO ADDR 0000000000114BE3
FAULT 0E ERR 0000000000000003 OP C605
PF CR2 0000000000114BE3 ERR 00000003 PRESENT WRITE SUPER DATA
FAULT RECOVERED 0001 -- faulting computation abandoned, shell resumed
oscortex> vmtest nx
VM TEST NX ADDR 0000000000114BE3
FAULT 0E ERR 0000000000000011 OP C34F
PF CR2 0000000000114BE3 ERR 00000011 PRESENT READ SUPER FETCH
```

Three `PT_LOAD` segments now (`R E`, `R`, `RW`, 4KiB-aligned), and — the half that matters — a real
4-level page table **built in DCDart out of six frames from the M7 allocator** and installed in `CR3`
while the kernel runs. `.text` is read+execute, `.rodata` is neither writable nor executable,
`.data`/`.bss` are writable and never executable. The `W 00` / `X 11` pairs above are an *all/any*
fold the kernel produces by **walking its own live tables**, not by restating what it built.

**The proof is a fault, and the controls come first.** `vmtest rw` and `vmtest x` do the same two
operations against a writable page and an executable page and must *not* fault — otherwise "the store
faulted" would be equally consistent with "stores fault". Then `vmtest ro` writes a byte into a
`@rodata` table and `vmtest nx` calls into it, and both are page faults reported with the faulting
address out of `CR2` and a decoded error code, survived by the shell through M4's recovery path. The
canary's eight bytes are unchanged afterwards, which is a stronger statement than "a fault happened".

**One bit was the whole difference, and testing found it, not reading.** With the segments split, the
tables built and every `.rodata` entry reading back `RW=0`, the write *still landed* — because
`CR0.WP` was clear, and without it a ring-0 store ignores the read-only bit entirely. The NX half
faulted correctly the whole time. A milestone that had tested only NX would have shipped "W^X works"
with every artefact genuine and the W half completely absent. `docs/known-gaps.md` GAP-0080.

`core/tests/conformance/m8-paging/run.sh` boots four machines and never takes the kernel's word for
anything: the permissions are read out of the **live page tables in guest physical memory**, at the
`CR3` QEMU itself reports, and walked by an independent implementation of the x86-64 four-level walk.
A `-cpu qemu64,nx=off` boot is the sharpest control — there `vmtest nx` must **survive** while
`vmtest ro` still faults, which is what makes the fetch fault attributable to the NX bit and nothing
else. A fourth boot drains and refills every frame the allocator has and requires `free <PML4>` to
come back `ERR RESERVED`, because the page tables are the first kernel memory that lives outside the
kernel image.

**What this is, and is not:** W^X for the kernel's own image. There is no user/supervisor separation,
no second address space, no `map`/`unmap` for changing a live mapping, and no TLB shootdown — and
`.rodata` is protected from a stray pointer, not from a type error, because DCDart's `Pointer` still
carries no const-ness. A store into a constant global is now a *fault* instead of silent corruption,
which is the whole difference; catching it before it runs is DCDart's side of the same problem. See
`core/docs/decisions/0012-paging-and-w-xor-x.md` and `docs/known-gaps.md` GAP-0081.

**M9 — done. The kernel runs something it does not trust.** Everything above ran at CPL 0, and not by
choice: the GDT had no DPL-3 descriptor, so nothing `iretq` could load would produce any other CPL;
there was no TSS, so an interrupt taken in ring 3 would have had no stack to be delivered on; every
page was supervisor-only; and every IDT gate was DPL 0. In nine milestones the `USER`/`SUPER` field of
the page-fault report had printed `SUPER` every single time, because the CPU had never had an
opportunity to set that bit.

```
oscortex> user
USER TSS 0000000000124010 RSP0 0000000000128080 GDT 0000000000118000 TR 0028
USER GATE 80 DPL 3 GATE 03 DPL 0 IDT 0000000000129000
USER MAP CODE 0000000000132000 STACK 0000000000133000
USER PAGE CODE 0000000000132000 P 1 U 1 W 0 X 1
USER PAGE STACK 0000000000133000 P 1 U 1 W 1 X 0
USER WINDOW PAGES 00000400 USER 00000002
USER ENTER RIP 0000000000132000 RSP 0000000000134000 ARG 0000000000000000
USER CS 0000000000000023 SS 000000000000001B RFLAGS 0000000000000202 CPL 3
USER WRITE HELLO FROM RING 3
USER EXIT CODE 0000000000000000 SYSCALLS 00000003 REFUSALS 00000000
oscortex> user pf
...
FAULT 0E ERR 0000000000000007 OP C607
PF CR2 000000000012B4D8 ERR 00000007 PRESENT WRITE USER DATA
USER FAULT VEC 0E ERR 0000000000000007 RIP 0000000000136000 CPL 3
USER CANARY 4B45524E454C2121 OK
FAULT RECOVERED 0002 -- faulting computation abandoned, shell resumed
```

`USER` in that error code is the bit that had never been observed. The payload is 17 bytes of
hand-written machine code that stores one byte into kernel `.bss`; the store is refused by the
hardware, the address in `CR2` is exactly the one it aimed at, and the target word is read back
afterwards and compared — *"the store did not land"* is a comparison, not the absence of a fault.

Seven commands, four of them designed to fail, because **a privilege boundary is proved by refusals**:
`mov %cr3` from ring 3 (#GP), a store into kernel memory (#PF with `USER`), `int $3` through a DPL-0
gate (#GP `0x1A` = "IDT entry 3"), and a syscall handed a kernel pointer (refused, and the payload
exits with the refusal it was given). `user` itself is the control — without a payload that runs to
completion, "ring 3 faulted" would be equally consistent with "nothing executes in ring 3 at all".

**The CPL is never asked of the code under test.** The `whoami` syscall reports the `CS` the *CPU*
pushed when it took the `int 0x80`; its low two bits are the privilege level the processor believed
the code was running at. And `user hold` leaves a payload spinning in ring 3 so the harness can stop
the machine mid-flight: QEMU's own `info registers` says `CPL=3`, `CS =0023`, and the live page tables
show exactly **two of 1024** pages in the 4KiB window user-accessible — the payload's code
(read+execute) and stack (read+write), W^X applying to ring 3 exactly as it applies to the kernel —
while no page of `.text`, `.rodata`, `.data`/`.bss` or the first megabyte is.

**Two writes nearly stopped it, and both were the M8 lesson in a mirror.** M8 made `.rodata`
read-only, and the GDT is in `.rodata`. `ltr` sets the *busy* bit in the TSS descriptor; loading a
segment selector sets the *accessed* bit. Both are writes into the GDT, and both produced a page fault
on a descriptor that was perfectly correct. Where M8's near-miss was entries that were right and a CPU
that ignored them, this was tables that were right and a CPU that refused them — **for a reason that
is nowhere in the table.** Both were fixed by removing the write rather than the protection, so the
GDT stays read-only.

**What this is, and is not:** a privilege level with two pages, not a process. One PML4, still the
kernel's. No scheduler, no preemption, no ELF loader, no `fork`, no `exec`, no SMEP/SMAP, and `user
hold` cannot be stopped once started. See
`core/docs/decisions/0013-ring-3-and-the-syscall-boundary.md` and `docs/known-gaps.md` GAP-0085.

**What this is, and is not:** fault survival with *abandonment* of the faulting computation. The
command that faulted is gone — not repaired, not retried, not resumed. Resuming a failed computation
after fixing its cause is a condition system, and that needs language support neither this kernel nor
DCDart has. See `core/docs/decisions/0007-fault-recovery-and-cpuid.md`.
