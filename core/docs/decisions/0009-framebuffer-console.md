# ADR-0009 — A linear framebuffer console, at an address the kernel discovered

**Status:** accepted, implemented, verified (`tests/conformance/m5-pci/run.sh`)
**Date:** 2026-08-21
**Milestone:** M5, part 2 (`ROADMAP.md`)
**Files:** `core/kernel/fb.dart`, `core/boot/boot.S` (a second page directory), `core/boot/portio.S`
(16-bit port I/O), `core/boot/kdata.S` (32 bytes), `core/kernel/vga.dart` (`conPutc`),
`core/kernel/shell.dart` (the `fb` command and the `help` line),
`core/tests/conformance/m5-pci/{run.sh,check-font.py,check-pixels.py}`,
`core/tests/conformance/m2-console/qmp-drive.py` (two more optional flags)

---

## 0. What this closes, and what it does not

`OSCORTEX_SPEC.md` §3 chose serial over VGA because VGA text mode does not exist on most modern
machines' primary boot path. `docs/known-gaps.md` GAP-0054 has said since M2 that the honest port is
"a framebuffer console driven from a glyph font in `.rodata`", and listed three things it needs:
Multiboot2, a glyph renderer, and pixel-row scrolling.

**This delivers the glyph renderer and does not deliver the other two.** It also finds the
framebuffer a different way than GAP-0054 assumed, which is the interesting part.

## 1. Decision

Add an `fb` shell command that:

1. **finds** the display controller by walking PCI configuration space (ADR-0008) looking for class
   `0x03` subclass `0x00`, and reads its **BAR0** — `0xFD000000` on this machine, which is a fact
   about SeaBIOS's allocator this boot, not a constant the kernel is entitled to know;
2. **sets a mode** — 800x600 at 32bpp with the linear framebuffer enabled — through the Bochs VBE
   ("dispi") index/data registers at `0x1CE`/`0x1CF`, after checking the interface's ID register
   actually answers;
3. **draws**, blitting 8x16 glyphs from `fbFont8x16`, a 1536-byte `@rodata final List<u8>`.

From then on `conPutc` routes to the framebuffer instead of the VGA text buffer, so the framebuffer
is a live console — the shell prompt, `pci`, `cpu` and everything else render on it — rather than a
banner painted once.

## 2. GAP-0054 assumed Multiboot2. It was not needed, and that is a real result

GAP-0054's step 1 is "**Multiboot2**, because the framebuffer tag does not exist in Multiboot1. That
is a boot-protocol change… also the CLAUDE.md-escalation kind of decision (boot protocol), not one to
take unilaterally."

That reasoning was correct about Multiboot1 and wrong about the conclusion, because it assumed the
only way to learn a framebuffer's address is to be told it by the loader. **A PCI base address
register is a second way**, and it became available to this kernel one part-of-a-milestone earlier.
So the boot protocol did not change, no escalation was needed, and `boot.S`'s Multiboot1 header is
untouched.

**What that buys and what it costs.** It works on a machine whose display adapter is a PCI device
this kernel can program. It does *not* work on a machine that boots UEFI and hands the loader a
framebuffer it has already configured — there, the right answer is still to take the one you are
given, and asking a GOP-configured adapter for a Bochs VBE mode will get nothing. Multiboot2 (or a
UEFI stub) is therefore still the portable answer and is still unbuilt. GAP-0054 is **narrowed, not
closed**, and its text now says which part is which.

## 3. Three walls, in the order they were hit

**3a. The address is not mapped.** `boot.S` identity-mapped 0–16MiB and nothing else. A store to
`0xFD000000` is a page fault — which, after M4, means a diagnostic and a recovered shell rather than
a dead machine, but not a framebuffer. Fixed in `boot.S` by adding a **second page directory** that
identity-maps 3–4GiB with 512 huge pages: the PC's PCI hole, where BARs always land.

Mapping the whole gigabyte rather than exactly the BAR is deliberate. Mapping exactly the BAR means
DCDart writing page-table entries at runtime, which is a page-table walker, TLB invalidation, and a
decision about where new tables come from with no allocator to ask. 512 entries in one loop at boot
needs none of that, and it is boot-time policy expressed in boot-time assembly, which is what
CLAUDE.md rule 4 asks for. It is emphatically **not** a memory manager: no permissions, no MTRR/PAT,
cacheable (GAP-0071).

**3b. The mode-set registers are 16-bit ports.** `Port.outb`/`Port.inb` are byte-wide, and QEMU
registers `0x1CE`/`0x1CF` as 2-byte-only ports — a byte access there is not narrowed, it is not
decoded at all, so a mode set built on `Port.outb` would write nothing and report no error.
`port_inw`/`port_outw` joined `port_inl`/`port_outl` in `core/boot/portio.S`. Same gap as PCI needed
(GAP-0066), one width down.

**3c. `0xB8000` stops being a text buffer.** This one was not predicted, and it was *measured*: the
first build that wired the framebuffer in as a **third** output path — serial, text buffer,
framebuffer — produced an 80x25 text buffer that read back out of guest memory as 2000 cells of pixel
data. The legacy `0xB8000` window is an **aperture into the adapter's own video RAM**, and setting a
VBE mode repoints it. Continuing to write it after the mode set does not "also update the text
console"; it scribbles two bytes into the middle of the framebuffer for every character printed.

So `conPutc` writes COM1 and then **exactly one** screen:

```dart
uartPutc(c);
if (fbState(fbStateBase) < 1) { vgaPutc(c); return; }
fbPutc(c);
```

**The VGA text console is not removed, disabled or regressed.** It is what every boot uses, including
all six pre-M5 harnesses, right up until something deliberately switches the adapter into a graphics
mode — at which point one adapter can show one thing, which is a property of the hardware and not a
choice this kernel made. `m5-pci/run.sh` asserts **both** directions: the text buffer is byte-exact
on the session boot that never runs `fb`, and 2000 of 2000 cells are pixel data on the boot that
does.

## 4. The font

1536 bytes: 96 glyphs of 16 bytes, one byte per pixel row, most significant bit leftmost. Glyphs
0..94 are ASCII `0x20`..`0x7E` in order, so glyph *n* is at `n * 16` and needs no header — which is
the shape `@rodata` gives (ADR-0040) and the shape that avoids adding 96 more hand-maintained lengths
to GAP-0060's tally.

**Glyph 95 is a fallback: a hollow box, drawn for every byte outside the range.** Not decoration. A
console that drew *nothing* for a byte it could not render would make a rendering failure
indistinguishable from a space, and `m5-pci/run.sh` asserts specifically that the fallback glyph is
**not** blank and that exactly one glyph (the space) is.

**The glyphs were authored at 5x9 and placed mechanically**, not typed as hex: nine rows of five
cells per glyph in a generator, with one line of code doing the placement into columns 1..5 of the
8-pixel cell. Hand-encoding 1536 bytes with a correct count is exactly the activity that bit at M4.
The harness checks the consequence — no byte in the table may set bit 7 or bits 1:0, because the
placement leaves those clear, and a stray one is a placement bug that would show as a single lit
pixel welded to a character's edge.

It is **not** the IBM VGA font and it is not typographically complete: `0x20`..`0x7E` and nothing
else. That is the "partial font with a clearly-marked fallback" this milestone budgeted for, stated
rather than implied.

## 5. Verification: pixels, not a screenshot

A PNG proves QEMU rendered something. It does not prove this kernel wrote it, that it found the right
address, or that it drew the glyph it meant to, and it cannot fail in a way that names what went
wrong.

So `check-pixels.py` reads 6528 pixels back out of **guest physical memory** at the address the
**kernel printed** (`qmp-drive.py`'s new `--addr-from-serial` substitutes it into the `xp` commands,
so the harness never assumes where the framebuffer is), and compares them against the banner
re-rendered from the **same `@rodata` font table**, read out of `kmain.o`. The expected image is
therefore not a golden anybody typed: change the font and the check follows it; get the blit wrong
and it names the pixel.

What that catches, concretely: a mode that was never set (the memory would not hold the painted
background either), the wrong or unmapped BAR, a reversed bit order in the row blit, a wrong pitch,
an off-by-one in the glyph index, and a transparent blit that left the fill showing through.

Separately, `check-font.py` validates the table's structure out of the object file, and the harness
asserts that a full `pci` enumeration ran **after** the mode set and reached the screen — which is
what distinguishes a live console from a banner painted once.

## 6. What is not built, and why it is recorded rather than half-done

**No scrolling.** The cursor stops at row 37 and further output is dropped — the console keeps what
it has and stops, rather than overwriting the last line forever or wrapping to the top, both of which
produce a screen that looks corrupted. GAP-0054 item 3 predicted this exact wall: a pixel-row scroll
is a 1.9MiB move, DCDart has no `memcpy`, and doing it through `Pointer<u32>` is ~467,000 volatile
load/store pairs per line. GAP-0070.

**No hardware cursor, one fixed colour pair, no double buffering, no VRAM-size check, no mode
negotiation.** 800x600x32 is asked for and either granted or not; the kernel does not read the dispi
VRAM-size register, it picks a mode small enough (1.9MiB) that every configuration this device ships
with can hold it. Asking for something larger would be a bet on a parameter it does not read.

**The text console cannot be switched back to.** There is no `fb off`. Returning to text mode means
programming the VGA sequencer, CRTC, graphics and attribute controllers back to mode 3, which is a
different and much larger piece of device programming than setting a dispi mode.

## 7. Rejected alternatives

**Hardcoding `0xFD000000`.** It is what this machine uses and it would have worked in every test
here. It would also have made the milestone meaningless: the entire point of doing this after PCI
enumeration is that the address is *discovered*. The harness pins the value only to check that the
kernel and QEMU agree on it.

**Wiring the framebuffer in as a third output alongside `0xB8000`.** Tried first, and it is what
produced finding 3c. Kept only as the note in `conPutc` explaining why it is not that.

**Reading the font out of the VGA BIOS at runtime** (the adapter already has an 8x16 font in plane 2).
It would be free of any authored data and is genuinely how a text-mode driver gets a font. Rejected
because it requires reprogramming the sequencer and graphics controller to expose plane 2, is
specific to a VGA-compatible adapter in a way a `.rodata` font is not, and produces a console whose
appearance depends on what firmware happened to load. The milestone asked for a font in `.rodata`.

**Scrolling by copying pixel rows.** See §6. The honest version of this needs a `memcpy` primitive,
which is a DCDart-repo decision (GAP-0070), not something to approximate with a 467,000-iteration
loop and call done.
