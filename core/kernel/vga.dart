// core/kernel/vga.dart
//
// oscortex_core M2: a real VGA text-mode console (80x25), and the console
// layer that mirrors every byte this kernel prints onto it.
//
// A `part of 'kmain.dart'` for the same forced reason uart.dart,
// multiboot.dart and interrupts.dart are: `dcc` lowers exactly ONE library per
// object file, so a `@bare` function in an IMPORTED library is never compiled
// at all. See docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHY VGA AT ALL, GIVEN OSCORTEX_SPEC.md §3 CHOSE SERIAL *OVER* VGA
// ---------------------------------------------------------------------------
// §3's reasoning is not overturned by this file and is not weakened by it:
// VGA text mode does not exist on most modern machines' primary boot path,
// while a serial or debug UART does. That is still why serial is the
// PRIMARY output and why all three existing conformance harnesses assert
// serial bytes and nothing else.
//
// This is a SECOND output path, added for one honest reason: the project owner
// wants to SEE the OS run, and under QEMU the text buffer at 0xB8000 is the
// shortest path from "the kernel is alive" to "here is a picture of it."
// Serial output is unchanged by a single byte -- see `conPutc` below, which
// writes serial FIRST and unconditionally.
//
// What this is NOT: a path to real hardware. A modern machine boots UEFI with
// a linear framebuffer and no VGA text mode; the honest answer there is a
// framebuffer console driven from the Multiboot framebuffer tag (which this
// kernel does not request, because it is a Multiboot1 loader today), rendering
// glyphs from a font in `.rodata`. That is real, unbudgeted work and is
// recorded as such -- docs/known-gaps.md GAP-0054, ADR-0005.
//
// ---------------------------------------------------------------------------
// EVERY ACCESS BELOW IS MMIO, AND THAT USED TO BE A LIVE HAZARD
// ---------------------------------------------------------------------------
// A store to a screen cell is textbook dead code to an optimizer: nothing in
// this program ever reads it back. Until 2026-08-21 DC-IR's `Load`/`Store`
// carried no volatile semantics AND `dcc` passed no `-O` flag at all, so this
// file would have been correct only by the accident of shipping unoptimized.
//
// Both halves changed on the same day: DCDart ADR-0041 made every
// `Pointer<T>.value` access volatile, and `dcc` now passes `-O2` by default.
// So this console is a large NEW consumer of a feature that is one commit old,
// and `tests/conformance/m2-console/run.sh` asserts the emitted stores survive
// -O2 rather than trusting the changelog. See docs/known-gaps.md GAP-0052.
//
// DCDart ADR-0069 then SPLIT the types: `Pointer<T>` is ordinary memory again
// (plain, optimizable loads/stores) and `Volatile<T>` is the MMIO type. So the
// screen-cell accesses below -- and ONLY those; the cursor word and the M2
// phase word are ordinary `.bss` RAM -- are spelled `Volatile<u16>`, and
// `core/scripts/verify-mmio-volatile.sh` asserts per site that the access
// survives -O2 in the emitted object. An ordinary `Pointer<u16>` here would
// compile clean and then let the optimizer delete or coalesce device stores
// (the exact GAP-0006 failure mode ADR-0041 first fixed).
//
// Port I/O (the CRTC cursor writes below) goes through a different backend
// path -- `asm sideeffect` inline assembly, not `Load`/`Store` -- and is
// therefore covered by inline-asm semantics rather than by ADR-0041.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Geometry and layout.
//
// Named `const int`s (DCDart ADR-0037 -- dcc-lower accepts a named const where
// it used to demand a bare literal), not magic numbers at each use site.
// ---------------------------------------------------------------------------

/// Base of the VGA text buffer in physical memory.
///
/// Reachable without any new mapping work: `boot.S` identity-maps the low
/// address space with 2MiB pages, and 0xB8000 is inside the first one.
const int vgaBase = 0xB8000;

/// 80 columns, 25 rows, 2 bytes per cell (character byte, attribute byte).
const int vgaCols = 80;
const int vgaRows = 25;
const int vgaCells = 2000; // vgaCols * vgaRows

/// Attribute byte, pre-shifted into the high half of a cell: 0x0F = white
/// foreground on black background, no blink.
const int vgaAttrCell = 0x0F00;

/// A blank cell: a space character carrying the standard attribute. Written
/// by [vgaClear] and by the bottom row after a scroll.
const int vgaBlankCell = 0x0F20;

/// CRTC index and data ports. Writing a register number to the index port
/// then a value to the data port is the entire protocol.
const int crtcIndex = 0x3D4;
const int crtcData = 0x3D5;

/// CRTC cursor-location registers: high byte at 14, low byte at 15.
const int crtcCursorHigh = 14;
const int crtcCursorLow = 15;

// ---------------------------------------------------------------------------
// Cursor state.
//
// The cursor is a LINEAR CELL INDEX (row * 80 + column) in the range 0..1999.
// Until M17 (ADR-0021) it lived in `core/boot/kdata.S`'s `.bss`, because DCDart
// had no mutable static data of any kind (docs/known-gaps.md GAP-0053); it is
// now a DCDart `@bss` block declared here. These two functions are still the
// only readers and writers, and their names did not change -- see shell.dart's
// note on why the accessor names were deliberately left alone.
// ---------------------------------------------------------------------------

/// The cursor word itself -- a DCDart mutable static (`@bss`), no longer a
/// donated block in `core/boot/kdata.S`.
@bss
final Bss vgaCursorWord = const Bss(bytes: 8);

/// The M2 phase word itself.
@bss
final Bss m2PhaseWord = const Bss(bytes: 8);

/// Address of the cursor word.
@bare
u64 vga_cursor_addr() {
  return Bss.addressOf(vgaCursorWord);
}

/// Address of the M2 phase word.
@bare
u64 m2_phase_addr() {
  return Bss.addressOf(m2PhaseWord);
}

/// Reads the cursor.
@bare
u64 vgaCursor() {
  return Pointer<u64>.fromAddress(vga_cursor_addr()).value;
}

/// Writes the cursor. Callers maintain `0 <= c < 2000`; this does not clamp,
/// because a clamp here would silently hide the bug rather than the caller's
/// own scroll logic being wrong in a visible way.
@bare
void vgaSetCursor(u64 c) {
  Pointer<u64>.fromAddress(vga_cursor_addr()).value = c;
}

// ---------------------------------------------------------------------------
// Cell access.
// ---------------------------------------------------------------------------

/// Address of cell [index] in the text buffer.
@bare
u64 vgaCellAddr(u64 index) {
  return u64(vgaBase) + (index * u64(2));
}

/// Writes character [c] with the standard attribute into cell [index].
///
/// One 16-bit store, not two 8-bit ones: the character and its attribute are
/// a single cell as far as the hardware is concerned, and splitting the write
/// would briefly show the new character in the OLD colour. Invisible at
/// today's palette (everything is 0x0F) and free to get right now.
@bare
void vgaPutCellAt(u64 index, u8 c) {
  Volatile<u16>.fromAddress(vgaCellAddr(index)).value =
      u16(vgaAttrCell) | c.toU16();
}

/// Blanks cell [index].
@bare
void vgaBlankAt(u64 index) {
  Volatile<u16>.fromAddress(vgaCellAddr(index)).value = u16(vgaBlankCell);
}

// ---------------------------------------------------------------------------
// Screen operations.
// ---------------------------------------------------------------------------

/// Clears the whole screen and homes the cursor.
///
/// Also the reason the console is safe to use at all: `vga_cursor` lives in
/// `.bss`, nothing in this kernel zeroes `.bss`, and a garbage cursor would
/// scatter stores across memory at `0xB8000 + 2 * garbage`. [vgaInit] sets it
/// to a known value BEFORE any output happens, and `kmain()` calls [vgaInit]
/// first for exactly that reason.
@bare
void vgaInit() {
  vgaSetCursor(u64(0));
  vgaClear();
  vgaUpdateHwCursor();
}

/// Fills every cell with a blank.
@bare
void vgaClear() {
  u64 i = u64(0);
  while (i < u64(vgaCells)) {
    vgaBlankAt(i);
    i = i + u64(1);
  }
}

/// Scrolls the screen up by one row: rows 1..24 move to 0..23 and row 24 is
/// blanked. The cursor is NOT touched here -- callers decide where it lands,
/// because a scroll triggered by a newline and one triggered by running off
/// the end of a row want the same screen and different cursors.
///
/// A cell-by-cell copy rather than a wide block move: DCDart has no memcpy,
/// no array type and no intrinsic, so a loop over `Pointer<u16>` IS the
/// primitive. 1920 volatile 16-bit loads and stores per scroll, which is
/// nothing next to the 16550's byte-at-a-time serial output that runs
/// alongside it.
@bare
void vgaScroll() {
  u64 i = u64(0);
  final u64 last = u64(vgaCells) - u64(vgaCols);
  while (i < last) {
    Volatile<u16>.fromAddress(vgaCellAddr(i)).value =
        Volatile<u16>.fromAddress(vgaCellAddr(i + u64(vgaCols))).value;
    i = i + u64(1);
  }
  while (i < u64(vgaCells)) {
    vgaBlankAt(i);
    i = i + u64(1);
  }
}

/// Moves the cursor to the start of the next line, scrolling if that would
/// leave the screen.
@bare
void vgaNewline() {
  final u64 next = ((vgaCursor() ~/ u64(vgaCols)) + u64(1)) * u64(vgaCols);
  if (next < u64(vgaCells)) {
    vgaSetCursor(next);
    return;
  }
  vgaScroll();
  vgaSetCursor(u64(vgaCells) - u64(vgaCols));
}

/// Backspace: move back one cell and blank it. Stops at cell 0 rather than
/// wrapping to the end of the screen -- backspacing off the top-left is a
/// user error, not a request to corrupt the last line.
@bare
void vgaBackspace() {
  final u64 c = vgaCursor();
  if (c < u64(1)) {
    return;
  }
  vgaSetCursor(c - u64(1));
  vgaBlankAt(c - u64(1));
}

/// Writes one character to the screen, honouring newline (0x0A) and
/// backspace (0x08), and scrolling when the cursor runs off the bottom.
///
/// Carriage return (0x0D) is deliberately NOT special-cased: this kernel emits
/// bare LF and nothing else, and inventing CR handling for a byte no caller
/// produces would be untested code pretending to be a feature.
@bare
void vgaPutc(u8 c) {
  if (c == u8(0x0A)) {
    vgaNewline();
    return;
  }
  if (c == u8(0x08)) {
    vgaBackspace();
    return;
  }
  final u64 at = vgaCursor();
  vgaPutCellAt(at, c);
  final u64 next = at + u64(1);
  if (next < u64(vgaCells)) {
    vgaSetCursor(next);
    return;
  }
  // Ran off the bottom-right corner: scroll and land at the start of the
  // (now blank) last row.
  vgaScroll();
  vgaSetCursor(u64(vgaCells) - u64(vgaCols));
}

/// Writes [len] bytes starting at [base] to the screen. Same contract as
/// `uartWrite`: [base] comes from `Rodata.addressOf(table)`, which is the
/// address of element 0 with no header of any kind in front of it (DCDart
/// ADR-0040), so the length must be passed separately.
@bare
void vgaWrite(u64 base, u64 len) {
  u64 i = u64(0);
  while (i < len) {
    vgaPutc(Pointer<u8>.fromAddress(base + i).value);
    i = i + u64(1);
  }
}

/// Points the hardware cursor at the software cursor.
///
/// This is what makes the blinking block appear where the next character will
/// go. Two index/data register pairs, high byte first; the value is the same
/// linear cell index the software cursor uses, which is exactly what the CRTC
/// wants (it addresses characters, not bytes).
///
/// Masked before `.toU8()` at both sites. `.toU8()` truncates silently rather
/// than trapping (DCDart ADR-0037 -- writing it IS the statement that you
/// meant to), so masking is how the intent stays visible in the source.
///
/// Called at the end of a burst rather than after every character: it is four
/// port writes, and doing it per character during the boot report would triple
/// the cost of printing for a cursor nobody watches mid-line.
@bare
void vgaUpdateHwCursor() {
  final u64 pos = vgaCursor();
  Port.outb(u16(crtcIndex), u8(crtcCursorHigh));
  Port.outb(u16(crtcData), ((pos >> u64(8)) & u64(0xFF)).toU8());
  Port.outb(u16(crtcIndex), u8(crtcCursorLow));
  Port.outb(u16(crtcData), (pos & u64(0xFF)).toU8());
}

// ---------------------------------------------------------------------------
// The console layer.
// ---------------------------------------------------------------------------

/// Writes one byte to COM1 and to whichever display is currently live: the VGA
/// text buffer, or the M5 linear framebuffer once a graphics mode has been set.
///
/// **Why it is not both, and why that is a hardware fact rather than a design
/// choice.** `0xB8000` is not memory the adapter merely happens to scan out --
/// it is an APERTURE into the adapter's own video RAM, and which part of that
/// RAM it exposes depends on the mode. Setting a Bochs VBE graphics mode
/// repoints it: after `fb` runs, reading `0xB8000` out of guest physical memory
/// returns PIXELS, not character cells, and a `vgaPutc` store into it scribbles
/// two bytes into the middle of the framebuffer. **This was measured, not
/// assumed** -- the first M5 build wrote both, and the 80x25 text buffer read
/// back out of guest memory came back as 2000 cells of pixel data.
///
/// So one adapter shows one thing at a time. The text console is not removed,
/// disabled or regressed: it is what every boot uses, including all six
/// pre-M5 harnesses, right up until something deliberately switches the
/// adapter into a graphics mode. `tests/conformance/m5-pci/run.sh` asserts
/// both halves -- the text buffer is intact on a boot that does not run `fb`,
/// and on a boot that does, the same buffer stops being text at exactly the
/// moment the mode is set. docs/known-gaps.md GAP-0071.
///
/// Serial is unaffected by any of it, which is the whole reason
/// `OSCORTEX_SPEC.md` §3 made it primary.
///
/// This is the single seam through which the whole kernel's output is
/// mirrored, and the ordering is deliberate. COM1 is written first and
/// unconditionally, so the byte stream three byte-exact conformance harnesses
/// assert is produced by the same code in the same order it always was; the
/// screen is strictly additional. If [vgaPutc] ever faults, the serial line
/// has already got the byte.
///
/// Every fixed-message and hex-digit emitter in `uart.dart`,
/// `multiboot.dart` and `interrupts.dart` calls THIS rather than `uartPutc`.
/// `uartPutc` itself stays a pure 16550 driver that knows nothing about a
/// screen -- the mirror is a layer above the driver, not a wart inside it.
@bare
void conPutc(u8 c) {
  // COM1 FIRST and unconditionally, unchanged since M2. Every byte three
  // byte-exact goldens assert is produced here, in this order, before anything
  // that touches a display.
  uartPutc(c);
  // Then EXACTLY ONE of the two screens -- see the note above on why it cannot
  // be both.
  if (fbState(u64(fbStateBase)) < u64(1)) {
    vgaPutc(c);
    return;
  }
  fbPutc(c);
}

// ---------------------------------------------------------------------------
// M2 entry.
// ---------------------------------------------------------------------------

/// Brings the interactive console up. **Never returns.**
///
/// Entered from the FAULT path of `isrDispatch`, which looks odd and is not.
/// M1's last act is a deliberate `u64` overflow that DCDart's overflow-trap
/// codegen turns into a `ud2` (#UD, vector 6). #UD is a FAULT, so the pushed
/// RIP is the address of the `ud2` itself and `iretq` would re-execute it
/// forever. The handler therefore cannot return, and the only way for the
/// kernel to keep running is to continue forward from inside it -- on the same
/// (healthy, 16KiB) boot stack, roughly 200 bytes deeper than kmain's frame.
/// Keyboard IRQs nest on top of that and unwind normally.
///
/// The alternative -- moving M1's fault to the end of M2 -- was rejected: it
/// would reorder M1's serial output and break a milestone that is green.
///
/// The phase word makes this safe to reach twice. A GENUINE fault during M2
/// lands on the same path; without the guard it would re-enter the console
/// recursively, printing a fresh banner over the diagnostic that explains
/// what went wrong. With it, the second arrival halts.
///
/// **M4 CHANGE, and it is the point of that milestone.** `isrDispatch` no
/// longer sends a post-console fault here at all — it recovers instead, and
/// this function's guard is now the last line of defence rather than the
/// normal path. It is kept, not deleted: `fault_resume` refuses to switch to a
/// stack it has not been told is real, and if it ever refuses, halting here is
/// what stops the kernel from scribbling a second banner over a diagnostic.
/// Reads the M2 phase word: 0 = the console has not been entered, 1 = it has.
///
/// Read by [isrDispatch] as well as by [m2Enter], because it is what tells the
/// fault path which of its two arms it is on — M1's one-shot boot fault, whose
/// bytes are frozen in a 544-byte golden, or a fault the shell can be recovered
/// from (ADR-0007).
@bare
u64 m2Phase() {
  return Pointer<u64>.fromAddress(m2_phase_addr()).value;
}

@bare
void m2Enter() {
  final u64 phase = m2Phase();
  if (phase > u64(0)) {
    // Already interactive: this is a real fault, not M1's deliberate one.
    // m1ReportFault has already printed the diagnostic; stop here rather than
    // restarting the console on top of it.
    halt_forever();
    return;
  }
  Pointer<u64>.fromAddress(m2_phase_addr()).value = u64(1);

  // Banner and first prompt: SCREEN ONLY (vgaWrite, never conPutc), for the
  // reason shellStrBanner's own doc comment gives -- m1-interrupts asserts the
  // whole serial capture and its last byte is the newline after `M1 END`, so a
  // prompt on COM1 before any key is pressed would break a green milestone.
  // Every LATER prompt is mirrored to both outputs, because by then a
  // keystroke has already been echoed and the M1 golden is behind us.
  vgaWrite(Rodata.addressOf(shellStrBanner), u64(57));

  // Order matters: drain any byte the 8042 is already holding BEFORE
  // unmasking. A full output buffer means the controller never raises another
  // IRQ1, so a single stale keystroke from before the kernel was ready would
  // wedge the keyboard permanently and silently. kbdInit() also finishes the
  // banner line with the drained count and a newline.
  kbdInit();
  picUnmaskKeyboardOnly();

  vgaWrite(Rodata.addressOf(shellStrPrompt), u64(10));
  vgaUpdateHwCursor();

  // M3: the steady state is a DCDart loop, not assembly's `sti; hlt; jmp`.
  // Every keystroke is an IRQ1 that edits the line buffer and returns; Enter
  // sets a flag that this loop picks up and runs in task context. Never
  // returns.
  //
  // M4: through `shell_run_forever` rather than by calling shellMain()
  // directly. The only thing that indirection buys is one store -- the stack
  // pointer the shell is about to run on, recorded in donated .bss, because
  // DCDart cannot read RSP. That one word is what a fault taken inside a
  // command resumes onto: see fault_resume() in core/boot/isr.S and ADR-0007.
  shell_run_forever();
}
