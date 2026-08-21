// core/kernel/fb.dart
//
// oscortex_core M5, part 2: a LINEAR FRAMEBUFFER console -- a graphics mode
// set through the Bochs VBE (dispi) interface, at an address discovered by
// reading a PCI base address register, with glyphs blitted from an 8x16
// bitmap font in `.rodata`.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is (docs/known-gaps.md GAP-0004 item 4).
//
// ---------------------------------------------------------------------------
// WHAT THIS IS FOR, AND WHAT IT IS NOT
// ---------------------------------------------------------------------------
// `OSCORTEX_SPEC.md` §3 chose serial over VGA and gave the reason: VGA text
// mode does not exist on most modern machines' primary boot path. GAP-0054 has
// said since M2 that the honest port is "a framebuffer console driven from a
// glyph font in .rodata". This is that renderer, and it closes the part of
// GAP-0054 that is about DRAWING.
//
// It does NOT close the part that is about BOOTING. A UEFI machine hands the
// loader a framebuffer through the boot protocol; this kernel is a Multiboot1
// image and gets nothing of the kind, so it finds the framebuffer the only
// other way there is -- by enumerating PCI and reading BAR0 of the display
// controller (core/kernel/pci.dart, ADR-0008), then programming a mode through
// a device-specific register interface. That works on the QEMU/Bochs std VGA
// device and on nothing else. See GAP-0070.
//
// **The VGA text console is untouched.** `conPutc` still writes COM1 first and
// `0xB8000` second; this is a THIRD output path, enabled only by the `fb`
// command, exactly as the text console was added alongside serial at M2. Every
// existing golden is unaffected, which four harnesses check mechanically.
//
// ---------------------------------------------------------------------------
// THE THREE THINGS THAT HAD TO BE TRUE BEFORE A SINGLE PIXEL COULD BE WRITTEN
// ---------------------------------------------------------------------------
// 1. **The address had to be discovered.** BAR0 of the display controller is
//    0xFD000000 on this machine, and that is a fact about SeaBIOS's allocator,
//    not about this kernel. It is read, not hardcoded.
// 2. **The address had to be MAPPED.** `boot.S` identity-mapped 0..16MiB and
//    nothing else, so a store to 0xFD000000 was a page fault. M5 adds a second
//    page directory covering 3-4GiB (ADR-0009) -- the PC's PCI hole, where BARs
//    always land.
// 3. **The mode had to be set through 16-BIT port writes.** The dispi index and
//    data registers at 0x1CE/0x1CF are 2-byte ports; a byte access is not
//    narrowed, it is not decoded at all. DCDart's `Port` is byte-wide, so this
//    needs `port_outw`/`port_inw` from core/boot/portio.S -- GAP-0066 again,
//    one width down from the one PCI needed.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040). Byte counts
// are hand-maintained literals at every call site (docs/known-gaps.md
// GAP-0060); the M5 harness cross-checks all of them against the symbol table.
// ---------------------------------------------------------------------------

/// Command name.
///
/// `"fb"` -- 2 bytes.
@rodata
final List<u8> fbStrCmd = const [
  u8(0x66), u8(0x62),
];

/// `fb` label: the framebuffer address read out of BAR0.
///
/// `"FB BAR "` -- 7 bytes.
@rodata
final List<u8> fbStrBar = const [
  u8(0x46), u8(0x42), u8(0x20), u8(0x42), u8(0x41), u8(0x52), u8(0x20),
];

/// `fb` separator before the geometry.
///
/// `" MODE "` -- 6 bytes.
@rodata
final List<u8> fbStrMode = const [
  u8(0x20), u8(0x4D), u8(0x4F), u8(0x44), u8(0x45), u8(0x20),
];

/// `fb` separator between width and height.
///
/// `"x"` -- 1 bytes.
@rodata
final List<u8> fbStrBy = const [
  u8(0x78),
];

/// `fb` terminator: the mode was set and the console painted.
///
/// `" OK\n"` -- 4 bytes.
@rodata
final List<u8> fbStrOk = const [
  u8(0x20), u8(0x4F), u8(0x4B), u8(0x0A),
];

/// Printed when the PCI walk found no display controller.
///
/// `"FB NONE -- no VGA-class device with a memory BAR0 on bus 0\n"` -- 59 bytes.
@rodata
final List<u8> fbStrNoDev = const [
  u8(0x46), u8(0x42), u8(0x20), u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x20), u8(0x2D), u8(0x2D), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x20), u8(0x56), u8(0x47), u8(0x41), u8(0x2D), u8(0x63), u8(0x6C), u8(0x61), u8(0x73), u8(0x73), u8(0x20),
  u8(0x64), u8(0x65), u8(0x76), u8(0x69), u8(0x63), u8(0x65), u8(0x20), u8(0x77), u8(0x69), u8(0x74), u8(0x68), u8(0x20),
  u8(0x61), u8(0x20), u8(0x6D), u8(0x65), u8(0x6D), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x42), u8(0x41), u8(0x52),
  u8(0x30), u8(0x20), u8(0x6F), u8(0x6E), u8(0x20), u8(0x62), u8(0x75), u8(0x73), u8(0x20), u8(0x30), u8(0x0A),
];

/// Printed when the dispi ID register did not answer.
///
/// `"FB NOVBE -- no Bochs VBE interface at 0x1CE\n"` -- 44 bytes.
@rodata
final List<u8> fbStrNoVbe = const [
  u8(0x46), u8(0x42), u8(0x20), u8(0x4E), u8(0x4F), u8(0x56), u8(0x42), u8(0x45), u8(0x20), u8(0x2D), u8(0x2D), u8(0x20),
  u8(0x6E), u8(0x6F), u8(0x20), u8(0x42), u8(0x6F), u8(0x63), u8(0x68), u8(0x73), u8(0x20), u8(0x56), u8(0x42), u8(0x45),
  u8(0x20), u8(0x69), u8(0x6E), u8(0x74), u8(0x65), u8(0x72), u8(0x66), u8(0x61), u8(0x63), u8(0x65), u8(0x20), u8(0x61),
  u8(0x74), u8(0x20), u8(0x30), u8(0x78), u8(0x31), u8(0x43), u8(0x45), u8(0x0A),
];

/// First line painted into the framebuffer itself.
///
/// `"OSCORTEX framebuffer console  800x600x32  8x16 font\n"` -- 52 bytes.
@rodata
final List<u8> fbStrBanner = const [
  u8(0x4F), u8(0x53), u8(0x43), u8(0x4F), u8(0x52), u8(0x54), u8(0x45), u8(0x58), u8(0x20), u8(0x66), u8(0x72), u8(0x61),
  u8(0x6D), u8(0x65), u8(0x62), u8(0x75), u8(0x66), u8(0x66), u8(0x65), u8(0x72), u8(0x20), u8(0x63), u8(0x6F), u8(0x6E),
  u8(0x73), u8(0x6F), u8(0x6C), u8(0x65), u8(0x20), u8(0x20), u8(0x38), u8(0x30), u8(0x30), u8(0x78), u8(0x36), u8(0x30),
  u8(0x30), u8(0x78), u8(0x33), u8(0x32), u8(0x20), u8(0x20), u8(0x38), u8(0x78), u8(0x31), u8(0x36), u8(0x20), u8(0x66),
  u8(0x6F), u8(0x6E), u8(0x74), u8(0x0A),
];


// ---------------------------------------------------------------------------
// The 16-bit port instructions. See core/boot/portio.S and GAP-0066.
// ---------------------------------------------------------------------------

/// 16-bit `in`.
@extern
external u64 port_inw(u64 port);

/// 16-bit `out`. Only the low 16 bits of [value] are written.
@extern
external void port_outw(u64 port, u64 value);

// ---------------------------------------------------------------------------
// Bochs VBE ("dispi") interface.
//
// Two 16-bit ports: write a register index to 0x1CE, then read or write its
// value at 0x1CF. Implemented by QEMU's std VGA, by the Bochs VGA BIOS, and by
// virtually nothing else -- see GAP-0070.
// ---------------------------------------------------------------------------

const int vbeIndexPort = 0x1CE;
const int vbeDataPort = 0x1CF;

/// Register indices.
const int vbeRegId = 0;
const int vbeRegXres = 1;
const int vbeRegYres = 2;
const int vbeRegBpp = 3;
const int vbeRegEnable = 4;
const int vbeRegVirtWidth = 6;
const int vbeRegXOffset = 8;
const int vbeRegYOffset = 9;

/// `ENABLE` register bits.
const int vbeDisabled = 0x00;
const int vbeEnabled = 0x01;
const int vbeLfbEnabled = 0x40;

/// The lowest interface version that supports a linear framebuffer. The ID
/// register reads back `0xB0C0 + version`; `0xB0C4` is what QEMU reports.
/// Checked rather than assumed: on a machine with no dispi interface, port
/// 0x1CF is not decoded and reads back all ones or all zeroes, and setting a
/// "mode" on it would silently do nothing while this kernel drew into an
/// address nobody was scanning out.
const int vbeIdMin = 0xB0C2;
const int vbeIdMax = 0xB0C5;

/// The mode this console asks for.
///
/// 800x600 at 32bpp, deliberately modest. It is inside every Bochs/QEMU
/// default video-memory size (1.9MiB of a 16MiB BAR), it is a mode the dispi
/// interface has supported since its first version, and it is large enough to
/// hold 100x37 characters of 8x16 text. Something more impressive would have
/// been a bet on a device parameter this kernel does not read (the VRAM size
/// register at dispi index 0x0A), which is exactly the kind of bet GAP-0070
/// exists to record rather than take.
const int fbWidth = 800;
const int fbHeight = 600;
const int fbBpp = 32;

/// Bytes per pixel at [fbBpp]. Named because it appears in every address
/// computation below and `4` at each site says nothing about why.
const int fbBytesPerPixel = 4;

// ---------------------------------------------------------------------------
// Glyph geometry.
// ---------------------------------------------------------------------------

/// One glyph is 8 pixels wide and 16 tall: one byte per row, most significant
/// bit leftmost, sixteen rows. That is the classic VGA text cell, and it is
/// what makes the font table a flat byte run with no per-glyph header --
/// glyph *n* starts at `n * 16`.
const int glyphWidth = 8;
const int glyphHeight = 16;
const int glyphBytes = 16;

/// The font covers a CONTIGUOUS RANGE of ASCII, and only that range.
const int fontFirstChar = 0x20; // space
const int fontLastChar = 0x7E; // tilde
const int fontGlyphCount = 95; // 0x7E - 0x20 + 1

/// Index of the FALLBACK GLYPH inside the font table, one past the last real
/// glyph.
///
/// **This exists so that an unrenderable byte is VISIBLE rather than blank.**
/// A byte outside `[0x20, 0x7E]` -- a control character, a high-bit byte, a
/// bug -- draws a hollow box. Drawing nothing would make a rendering failure
/// indistinguishable from a space, which is precisely the failure mode that
/// makes a graphics bug take an afternoon instead of a minute.
const int fontFallbackIndex = 95;

/// Foreground and background, as 0x00RRGGBB in the little-endian 32bpp layout
/// QEMU's std VGA presents (byte 0 blue, byte 1 green, byte 2 red, byte 3
/// unused). Light grey on near-black rather than pure white on pure black:
/// identical to read back, easier to look at, and it makes a genuinely
/// untouched pixel (0x00000000) distinguishable from a deliberately painted
/// background.
const int fbColorFg = 0x00C8C8C8;
const int fbColorBg = 0x00101018;

// ---------------------------------------------------------------------------
// Donated state. core/boot/kdata.S, because DCDart has no mutable static data
// (docs/known-gaps.md GAP-0053).
// ---------------------------------------------------------------------------

/// Address of the 32-byte framebuffer state block:
///
///     +0   u64  base address of the linear framebuffer, or 0 if unavailable
///     +8   u64  bytes per scanline (pitch)
///     +16  u64  cursor column, in glyph cells
///     +24  u64  cursor row, in glyph cells
///
/// One block with fixed offsets rather than four symbols with four accessors,
/// for the reason `cpu_info` gives in GAP-0061: every extra accessor is another
/// `@extern` declaration and another line of assembly.
@extern
external u64 fb_state_addr();

/// Reads word [i] of the framebuffer state block.
@bare
u64 fbState(u64 i) {
  return Pointer<u64>.fromAddress(fb_state_addr() + (i * u64(8))).value;
}

/// Writes word [i] of the framebuffer state block.
@bare
void fbSetState(u64 i, u64 v) {
  Pointer<u64>.fromAddress(fb_state_addr() + (i * u64(8))).value = v;
}

/// Word indices inside the state block.
const int fbStateBase = 0;
const int fbStatePitch = 1;
const int fbStateCol = 2;
const int fbStateRow = 3;

/// Zeroes the block. Called from `kmain()` alongside `vgaInit()` and
/// `shellInit()`, and for the identical reason: `.bss` is not zeroed by
/// anything in this kernel, so a garbage base address would make the first
/// glyph blit scatter 32-bit stores across memory at an address nothing chose.
/// A base of 0 is the "no framebuffer" value and every writer checks it.
@bare
void fbInit() {
  fbSetState(u64(fbStateBase), u64(0));
  fbSetState(u64(fbStatePitch), u64(0));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
}

// ---------------------------------------------------------------------------
// Finding the device.
// ---------------------------------------------------------------------------

/// PCI class 0x03 subclass 0x00 is a VGA-compatible display controller.
const int pciClassDisplay = 0x03;
const int pciSubclassVga = 0x00;

/// Configuration-space offset of BAR0.
const int pciRegBar0 = 0x10;

/// Returns the linear-framebuffer physical address from BAR0 of the first
/// VGA-compatible display controller on bus 0, or 0 if there is none.
///
/// **The address is discovered, not hardcoded, and that is the entire point of
/// this function.** On this machine it comes back 0xFD000000, which is a fact
/// about what SeaBIOS's BAR allocator decided this boot -- not a constant this
/// kernel is entitled to know.
///
/// Only bus 0 is searched, and only function 0 of each slot. A display adapter
/// behind a bridge or on a non-zero function is possible and is not handled;
/// `pciScanBus` already knows how to walk further, but it PRINTS as it walks
/// and cannot return a device (GAP-0067 item 1), so this is a second, narrower
/// walk rather than a reuse of the first. That duplication is itself the cost
/// of having nowhere to store an enumeration result.
///
/// **Bit 0 of a BAR distinguishes memory from I/O space**, and bits 3:1 encode
/// the type and prefetchability; all four are masked off, which is what turns
/// the register into an address. A BAR whose bit 0 is set is an I/O port range
/// and is skipped rather than treated as an address -- it would otherwise
/// produce a plausible-looking small number and a store into low memory.
@bare
u64 fbFindVgaBar() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) < u64(0xFFFF)) {
      final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
      if (((classReg >> u64(24)) & u64(0xFF)) == u64(pciClassDisplay)) {
        if (((classReg >> u64(16)) & u64(0xFF)) == u64(pciSubclassVga)) {
          final u64 bar = pciRead32(u64(0), dev, u64(0), u64(pciRegBar0));
          if ((bar & u64(1)) < u64(1)) {
            return bar & u64(0xFFFFFFF0);
          }
          return u64(0); // BAR0 is an I/O range: not a framebuffer
        }
      }
    }
    dev = dev + u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Setting the mode.
// ---------------------------------------------------------------------------

/// Writes [value] to dispi register [index].
@bare
void vbeWrite(u64 index, u64 value) {
  port_outw(u64(vbeIndexPort), index);
  port_outw(u64(vbeDataPort), value);
}

/// Reads dispi register [index].
@bare
u64 vbeRead(u64 index) {
  port_outw(u64(vbeIndexPort), index);
  return port_inw(u64(vbeDataPort));
}

/// Programs [fbWidth] x [fbHeight] at [fbBpp] with the linear framebuffer
/// enabled. Returns 1 on success, 0 if no dispi interface answered.
///
/// **The interface is identified before it is programmed.** `vbeRead(ID)` must
/// come back in the 0xB0C2..0xB0C5 range. On a machine without this device the
/// data port is not decoded, reads return all-ones or all-zeroes, and every
/// write below would be swallowed -- after which this kernel would happily
/// blit glyphs into an address nothing was scanning out, and report success.
/// The check is the difference between "no framebuffer" and "a framebuffer
/// that does not exist".
///
/// **`ENABLE` is cleared before the geometry registers are written and set
/// afterwards.** That ordering is required by the interface: the device latches
/// the geometry when the enable bit goes from 0 to 1, so writing XRES while
/// enabled is either ignored or produces a torn intermediate mode.
@bare
u64 fbSetMode() {
  final u64 id = vbeRead(u64(vbeRegId));
  if (id < u64(vbeIdMin)) {
    return u64(0);
  }
  if (id > u64(vbeIdMax)) {
    return u64(0);
  }
  vbeWrite(u64(vbeRegEnable), u64(vbeDisabled));
  vbeWrite(u64(vbeRegXres), u64(fbWidth));
  vbeWrite(u64(vbeRegYres), u64(fbHeight));
  vbeWrite(u64(vbeRegBpp), u64(fbBpp));
  // VIRT_WIDTH and the two offsets are set EXPLICITLY rather than left at
  // whatever the previous mode used. The pitch this kernel computes below is
  // `fbWidth * 4`, which is only the real pitch if the virtual width equals the
  // visible width -- and a non-zero Y offset would make every glyph land one
  // scanline block away from where it was drawn.
  vbeWrite(u64(vbeRegVirtWidth), u64(fbWidth));
  vbeWrite(u64(vbeRegXOffset), u64(0));
  vbeWrite(u64(vbeRegYOffset), u64(0));
  vbeWrite(u64(vbeRegEnable), u64(vbeEnabled) | u64(vbeLfbEnabled));
  return u64(1);
}

// ---------------------------------------------------------------------------
// Drawing.
// ---------------------------------------------------------------------------

/// Address of the pixel at ([x], [y]).
@bare
u64 fbPixelAddr(u64 x, u64 y) {
  return fbState(u64(fbStateBase)) +
      (y * fbState(u64(fbStatePitch))) +
      (x * u64(fbBytesPerPixel));
}

/// Writes one pixel. No bounds check: every caller derives its coordinates
/// from the glyph grid, which is derived from [fbWidth]/[fbHeight].
@bare
void fbPutPixel(u64 x, u64 y, u64 color) {
  Pointer<u32>.fromAddress(fbPixelAddr(x, y)).value = color.toU32();
}

/// Fills one scanline segment of [w] pixels starting at ([x], [y]).
///
/// A separate function rather than an inner loop because `dcc` rejects nested
/// `while` loops (docs/known-gaps.md GAP-0068) -- the same limitation
/// `pciScanFunctions1To7` exists for, met a second time in the same milestone
/// and this time in a place where the natural shape really is two nested loops
/// over an (x, y) pair.
@bare
void fbFillRow(u64 x, u64 y, u64 w, u64 color) {
  u64 i = u64(0);
  while (i < w) {
    fbPutPixel(x + i, y, color);
    i = i + u64(1);
  }
}

/// Fills the whole visible area with [color].
@bare
void fbFill(u64 color) {
  u64 y = u64(0);
  while (y < u64(fbHeight)) {
    fbFillRow(u64(0), y, u64(fbWidth), color);
    y = y + u64(1);
  }
}

/// Returns the address of the 16-byte glyph for character [c].
///
/// Anything outside `[fontFirstChar, fontLastChar]` maps to the fallback box.
/// That includes every control character, so a stray `\n` reaching here draws a
/// box rather than nothing -- and [fbPutc] handles `\n` before calling this, so
/// a box on screen means a byte arrived that this console genuinely cannot
/// draw. Visible beats silent.
@bare
u64 fbGlyphAddr(u8 c) {
  final u64 base = Rodata.addressOf(fbFont8x16);
  if (c < u8(fontFirstChar)) {
    return base + (u64(fontFallbackIndex) * u64(glyphBytes));
  }
  if (c > u8(fontLastChar)) {
    return base + (u64(fontFallbackIndex) * u64(glyphBytes));
  }
  return base + ((c.toU64() - u64(fontFirstChar)) * u64(glyphBytes));
}

/// Draws one row of a glyph: the eight pixels encoded by [bits], most
/// significant bit leftmost.
///
/// Both foreground AND background are written, deliberately -- this is an
/// opaque blit, not a transparent one. Drawing only the set bits would leave
/// whatever was underneath showing through, which turns overwriting a character
/// into a union of two glyphs.
@bare
void fbGlyphRow(u64 x, u64 y, u8 bits) {
  u64 i = u64(0);
  while (i < u64(glyphWidth)) {
    // Bit 7 is the leftmost pixel, so column i tests bit (7 - i).
    //
    // The parentheses around the `&` are not decoration. Dart binds bitwise
    // AND TIGHTER than a relational operator -- the opposite of C -- so
    // `a & b > c` already means `(a & b) > c` here and the unparenthesized
    // form is correct. It is spelled out anyway, because a reader who knows C
    // reads it the other way, and "correct for a reason the next person will
    // get wrong" is how this line becomes a bug.
    if (((bits.toU64() >> (u64(7) - i)) & u64(1)) > u64(0)) {
      fbPutPixel(x + i, y, u64(fbColorFg));
    } else {
      fbPutPixel(x + i, y, u64(fbColorBg));
    }
    i = i + u64(1);
  }
}

/// Blits the glyph for [c] into cell ([col], [row]).
@bare
void fbDrawGlyph(u64 col, u64 row, u8 c) {
  final u64 glyph = fbGlyphAddr(c);
  final u64 x = col * u64(glyphWidth);
  final u64 y = row * u64(glyphHeight);
  u64 i = u64(0);
  while (i < u64(glyphHeight)) {
    fbGlyphRow(x, y + i, Pointer<u8>.fromAddress(glyph + i).value);
    i = i + u64(1);
  }
}

/// Columns and rows of glyph cells that fit in the visible area.
const int fbCols = 100; // fbWidth / glyphWidth
const int fbRows = 37; // fbHeight ~/ glyphHeight, rounded down

/// Writes one character to the framebuffer console, honouring newline and
/// backspace, and wrapping at the right edge.
///
/// **Does nothing at all when there is no framebuffer.** A zero base address is
/// the "the `fb` command was never run, or found nothing" state, and it is
/// checked FIRST -- which is what makes this safe to call from `conPutc` on
/// every byte the kernel prints, on a machine with no display, from boot. Every
/// harness before M5 exercises exactly that path and is byte-identical because
/// of it.
///
/// **Scrolling is not implemented, and running off the bottom STOPS the
/// console rather than corrupting it.** Once the cursor passes the last row
/// every subsequent character is dropped: the framebuffer keeps the first 37
/// lines and stops. That is a real limitation and it is deliberate rather than
/// unnoticed -- a pixel-row scroll is a 1.9MiB move, DCDart has no `memcpy`
/// (GAP-0054 item 3 predicted this exact wall), and doing it a pixel at a time
/// through `Pointer<u32>` is 467,000 volatile load/store pairs per line. The
/// alternative shapes -- overwriting the last row forever, or wrapping to the
/// top -- both produce a screen that looks like a corrupted one. Stopping looks
/// like what it is. docs/known-gaps.md GAP-0070.
@bare
void fbPutc(u8 c) {
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return; // no framebuffer: this is the state on every boot until `fb` runs
  }
  final u64 row = fbState(u64(fbStateRow));
  if (row > u64(fbRows) - u64(1)) {
    return; // the console is full; see the note above
  }
  if (c == u8(0x0A)) {
    fbSetState(u64(fbStateCol), u64(0));
    fbSetState(u64(fbStateRow), row + u64(1));
    return;
  }
  final u64 col = fbState(u64(fbStateCol));
  if (c == u8(0x08)) {
    if (col > u64(0)) {
      fbSetState(u64(fbStateCol), col - u64(1));
      fbDrawGlyph(col - u64(1), row, u8(0x20));
    }
    return;
  }
  fbDrawGlyph(col, row, c);
  if (col + u64(1) < u64(fbCols)) {
    fbSetState(u64(fbStateCol), col + u64(1));
    return;
  }
  // Ran off the right edge: wrap, which is a newline by another name.
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), row + u64(1));
}

/// Writes [len] bytes at [base] to the framebuffer console ONLY -- not to
/// serial and not to the text console. Same contract as `uartWrite`/`vgaWrite`:
/// `@rodata` tables carry no length (ADR-0040).
///
/// Used for the one line that is painted into the framebuffer *before* the
/// framebuffer becomes a mirrored output path, so that a boot which sets the
/// mode and then prints nothing still has something on it to look at.
@bare
void fbWrite(u64 base, u64 len) {
  u64 i = u64(0);
  while (i < len) {
    fbPutc(Pointer<u8>.fromAddress(base + i).value);
    i = i + u64(1);
  }
}

// ---------------------------------------------------------------------------
// THE FONT.
//
// **1536 bytes: 96 glyphs of 16 bytes each.** Glyphs 0..94 are printable ASCII
// `0x20`..`0x7E` in order, so glyph *n* is character `0x20 + n` and lives at
// `n * 16`. Glyph 95 is the FALLBACK -- a hollow box, drawn for any byte this
// font cannot represent.
//
// One byte per pixel ROW, most significant bit leftmost, sixteen rows. That is
// the classic VGA text-cell layout, and it is why the table needs no header and
// no per-glyph length: it is a flat byte run indexed by arithmetic, which is
// exactly the shape `@rodata` gives (DCDart ADR-0040) and exactly the shape
// that avoids adding 96 more hand-maintained lengths to GAP-0060's tally.
//
// **The glyphs were authored at 5x9 and PLACED mechanically**, not typed as
// hex. Each one is nine rows of five cells in a generator script; the placement
// (rows 3..11, columns 1..5, i.e. `bits << 2`) is done in one line of code that
// every glyph goes through. Hand-encoding 1536 bytes with a correct count is
// the exact activity GAP-0060 exists to warn about, and this is the third table
// in this milestone generated rather than counted.
//
// **What this font IS NOT: it is not the IBM VGA font, and it is not a
// complete one in any typographic sense.** It is a plain 5x7-with-descenders
// design covering `0x20`..`0x7E` and nothing else -- no accents, no box
// drawing, no code page. Every byte outside that range draws the fallback box,
// visibly, on purpose: a console that silently drew nothing for a byte it could
// not render would make a rendering bug indistinguishable from a space.
@rodata
final List<u8> fbFont8x16 = const [
  // 0x20 space
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x21 !
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x00), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x22 "
  u8(0x00), u8(0x00), u8(0x00), u8(0x28), u8(0x28), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x23 #
  u8(0x00), u8(0x00), u8(0x00), u8(0x28), u8(0x28), u8(0x7C), u8(0x28), u8(0x7C), u8(0x28), u8(0x28), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x24 $
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x3C), u8(0x50), u8(0x38), u8(0x14), u8(0x78), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x25 %
  u8(0x00), u8(0x00), u8(0x00), u8(0x64), u8(0x64), u8(0x08), u8(0x10), u8(0x20), u8(0x4C), u8(0x4C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x26 &
  u8(0x00), u8(0x00), u8(0x00), u8(0x30), u8(0x48), u8(0x50), u8(0x20), u8(0x54), u8(0x48), u8(0x34), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x27 '
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x28 (
  u8(0x00), u8(0x00), u8(0x00), u8(0x08), u8(0x10), u8(0x20), u8(0x20), u8(0x20), u8(0x10), u8(0x08), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x29 )
  u8(0x00), u8(0x00), u8(0x00), u8(0x20), u8(0x10), u8(0x08), u8(0x08), u8(0x08), u8(0x10), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x2A *
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x54), u8(0x38), u8(0x7C), u8(0x38), u8(0x54), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x2B +
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x10), u8(0x7C), u8(0x10), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x2C ,
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x18), u8(0x10), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x2D -
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x2E .
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x30), u8(0x30), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x2F /
  u8(0x00), u8(0x00), u8(0x00), u8(0x04), u8(0x04), u8(0x08), u8(0x10), u8(0x20), u8(0x40), u8(0x40), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x30 0
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x4C), u8(0x54), u8(0x64), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x31 1
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x30), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x32 2
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x04), u8(0x08), u8(0x10), u8(0x20), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x33 3
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x08), u8(0x10), u8(0x08), u8(0x04), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x34 4
  u8(0x00), u8(0x00), u8(0x00), u8(0x08), u8(0x18), u8(0x28), u8(0x48), u8(0x7C), u8(0x08), u8(0x08), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x35 5
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x40), u8(0x78), u8(0x04), u8(0x04), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x36 6
  u8(0x00), u8(0x00), u8(0x00), u8(0x18), u8(0x20), u8(0x40), u8(0x78), u8(0x44), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x37 7
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x04), u8(0x08), u8(0x10), u8(0x20), u8(0x20), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x38 8
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x44), u8(0x38), u8(0x44), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x39 9
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x44), u8(0x3C), u8(0x04), u8(0x08), u8(0x30), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x3A :
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x30), u8(0x30), u8(0x00), u8(0x30), u8(0x30), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x3B ;
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x30), u8(0x30), u8(0x00), u8(0x30), u8(0x10), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x3C <
  u8(0x00), u8(0x00), u8(0x00), u8(0x08), u8(0x10), u8(0x20), u8(0x40), u8(0x20), u8(0x10), u8(0x08), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x3D =
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x00), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x3E >
  u8(0x00), u8(0x00), u8(0x00), u8(0x20), u8(0x10), u8(0x08), u8(0x04), u8(0x08), u8(0x10), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x3F ?
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x04), u8(0x08), u8(0x10), u8(0x00), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x40 @
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x5C), u8(0x54), u8(0x5C), u8(0x40), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x41 A
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x28), u8(0x44), u8(0x44), u8(0x7C), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x42 B
  u8(0x00), u8(0x00), u8(0x00), u8(0x78), u8(0x44), u8(0x44), u8(0x78), u8(0x44), u8(0x44), u8(0x78), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x43 C
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x40), u8(0x40), u8(0x40), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x44 D
  u8(0x00), u8(0x00), u8(0x00), u8(0x70), u8(0x48), u8(0x44), u8(0x44), u8(0x44), u8(0x48), u8(0x70), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x45 E
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x40), u8(0x40), u8(0x78), u8(0x40), u8(0x40), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x46 F
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x40), u8(0x40), u8(0x78), u8(0x40), u8(0x40), u8(0x40), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x47 G
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x40), u8(0x5C), u8(0x44), u8(0x44), u8(0x3C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x48 H
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x7C), u8(0x44), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x49 I
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x4A J
  u8(0x00), u8(0x00), u8(0x00), u8(0x1C), u8(0x08), u8(0x08), u8(0x08), u8(0x08), u8(0x48), u8(0x30), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x4B K
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x48), u8(0x50), u8(0x60), u8(0x50), u8(0x48), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x4C L
  u8(0x00), u8(0x00), u8(0x00), u8(0x40), u8(0x40), u8(0x40), u8(0x40), u8(0x40), u8(0x40), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x4D M
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x6C), u8(0x54), u8(0x54), u8(0x44), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x4E N
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x64), u8(0x54), u8(0x4C), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x4F O
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x50 P
  u8(0x00), u8(0x00), u8(0x00), u8(0x78), u8(0x44), u8(0x44), u8(0x78), u8(0x40), u8(0x40), u8(0x40), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x51 Q
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x44), u8(0x44), u8(0x54), u8(0x48), u8(0x34), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x52 R
  u8(0x00), u8(0x00), u8(0x00), u8(0x78), u8(0x44), u8(0x44), u8(0x78), u8(0x50), u8(0x48), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x53 S
  u8(0x00), u8(0x00), u8(0x00), u8(0x3C), u8(0x40), u8(0x40), u8(0x38), u8(0x04), u8(0x04), u8(0x78), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x54 T
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x55 U
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x56 V
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x28), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x57 W
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x54), u8(0x54), u8(0x6C), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x58 X
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x28), u8(0x10), u8(0x28), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x59 Y
  u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x28), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x5A Z
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x04), u8(0x08), u8(0x10), u8(0x20), u8(0x40), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x5B [
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x5C \
  u8(0x00), u8(0x00), u8(0x00), u8(0x40), u8(0x40), u8(0x20), u8(0x10), u8(0x08), u8(0x04), u8(0x04), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x5D ]
  u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x08), u8(0x08), u8(0x08), u8(0x08), u8(0x08), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x5E ^
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x28), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x5F _
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x60 `
  u8(0x00), u8(0x00), u8(0x00), u8(0x20), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x61 a
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x04), u8(0x3C), u8(0x44), u8(0x3C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x62 b
  u8(0x00), u8(0x00), u8(0x00), u8(0x40), u8(0x40), u8(0x78), u8(0x44), u8(0x44), u8(0x44), u8(0x78), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x63 c
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x40), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x64 d
  u8(0x00), u8(0x00), u8(0x00), u8(0x04), u8(0x04), u8(0x3C), u8(0x44), u8(0x44), u8(0x44), u8(0x3C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x65 e
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x7C), u8(0x40), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x66 f
  u8(0x00), u8(0x00), u8(0x00), u8(0x18), u8(0x24), u8(0x20), u8(0x70), u8(0x20), u8(0x20), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x67 g
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x3C), u8(0x44), u8(0x44), u8(0x3C), u8(0x04), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x68 h
  u8(0x00), u8(0x00), u8(0x00), u8(0x40), u8(0x40), u8(0x78), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x69 i
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x00), u8(0x30), u8(0x10), u8(0x10), u8(0x10), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x6A j
  u8(0x00), u8(0x00), u8(0x00), u8(0x08), u8(0x00), u8(0x18), u8(0x08), u8(0x08), u8(0x08), u8(0x08), u8(0x48), u8(0x30), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x6B k
  u8(0x00), u8(0x00), u8(0x00), u8(0x40), u8(0x40), u8(0x48), u8(0x50), u8(0x60), u8(0x50), u8(0x48), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x6C l
  u8(0x00), u8(0x00), u8(0x00), u8(0x30), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x6D m
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x68), u8(0x54), u8(0x54), u8(0x54), u8(0x54), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x6E n
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x78), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x6F o
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x38), u8(0x44), u8(0x44), u8(0x44), u8(0x38), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x70 p
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x78), u8(0x44), u8(0x44), u8(0x78), u8(0x40), u8(0x40), u8(0x40), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x71 q
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x3C), u8(0x44), u8(0x44), u8(0x3C), u8(0x04), u8(0x04), u8(0x04), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x72 r
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x58), u8(0x64), u8(0x40), u8(0x40), u8(0x40), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x73 s
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x3C), u8(0x40), u8(0x38), u8(0x04), u8(0x78), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x74 t
  u8(0x00), u8(0x00), u8(0x00), u8(0x20), u8(0x20), u8(0x78), u8(0x20), u8(0x20), u8(0x24), u8(0x18), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x75 u
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x3C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x76 v
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x28), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x77 w
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x54), u8(0x54), u8(0x54), u8(0x28), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x78 x
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x28), u8(0x10), u8(0x28), u8(0x44), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x79 y
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x44), u8(0x44), u8(0x44), u8(0x3C), u8(0x04), u8(0x08), u8(0x30), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x7A z
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x08), u8(0x10), u8(0x20), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x7B {
  u8(0x00), u8(0x00), u8(0x00), u8(0x0C), u8(0x10), u8(0x10), u8(0x20), u8(0x10), u8(0x10), u8(0x0C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x7C |
  u8(0x00), u8(0x00), u8(0x00), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x10), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x7D }
  u8(0x00), u8(0x00), u8(0x00), u8(0x60), u8(0x10), u8(0x10), u8(0x08), u8(0x10), u8(0x10), u8(0x60), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x7E ~
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x24), u8(0x54), u8(0x48), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // fallback: a hollow box, drawn for any byte outside 0x20..0x7E
  u8(0x00), u8(0x00), u8(0x00), u8(0x7C), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x44), u8(0x7C), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
];

// ---------------------------------------------------------------------------
// The `fb` command.
// ---------------------------------------------------------------------------

/// Paints a fixed banner into the framebuffer, at the top left.
///
/// Deliberately SHORT and deliberately fixed: it is the string the M5 harness
/// reads back **as pixels** out of guest memory at the BAR address, so it has
/// to be something whose glyph bitmaps are known at test-authoring time. See
/// `tests/conformance/m5-pci/run.sh`'s glyph check.
@bare
void fbPaintBanner() {
  fbWrite(Rodata.addressOf(fbStrBanner), u64(52));
}

/// `fb` -- find the display controller, set a graphics mode, and draw.
///
/// Prints to serial and the text console (through `uartWrite`, i.e. `conPutc`)
/// what it found, and paints into the framebuffer itself. Both, on purpose: the
/// serial line is what a byte-exact golden can assert, and the framebuffer is
/// what a pixel read-back can assert, and they are different claims.
///
/// **The VGA text console keeps working across this.** Setting a Bochs VBE
/// graphics mode does not unmap `0xB8000` -- the text buffer is still there and
/// `vgaPutc` still writes it -- so every byte after this command still reaches
/// three places. What changes is what the *display* is scanning out, which is
/// why the M5 harness reads the text buffer out of guest memory rather than
/// looking at the screen.
@bare
void shellFb() {
  final u64 bar = fbFindVgaBar();
  if (bar < u64(1)) {
    uartWrite(Rodata.addressOf(fbStrNoDev), u64(59));
    return;
  }
  if (fbSetMode() < u64(1)) {
    uartWrite(Rodata.addressOf(fbStrNoVbe), u64(44));
    return;
  }
  fbSetState(u64(fbStateBase), bar);
  fbSetState(u64(fbStatePitch), u64(fbWidth) * u64(fbBytesPerPixel));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
  fbFill(u64(fbColorBg));
  fbPaintBanner();

  uartWrite(Rodata.addressOf(fbStrBar), u64(7));
  uartPutHex(bar, u64(8));
  uartWrite(Rodata.addressOf(fbStrMode), u64(6));
  uartPutHex(u64(fbWidth), u64(4));
  uartWrite(Rodata.addressOf(fbStrBy), u64(1));
  uartPutHex(u64(fbHeight), u64(4));
  uartWrite(Rodata.addressOf(fbStrBy), u64(1));
  uartPutHex(u64(fbBpp), u64(2));
  uartWrite(Rodata.addressOf(fbStrOk), u64(4));
}
