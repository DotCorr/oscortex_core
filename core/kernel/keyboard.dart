// core/kernel/keyboard.dart
//
// oscortex_core M2: the PS/2 keyboard, on IRQ1.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS DRIVER ASSUMES, STATED RATHER THAN HOPED
// ---------------------------------------------------------------------------
// 1. The 8042 controller is already initialized and its keyboard port enabled.
//    Under QEMU that is done by SeaBIOS before it hands control to a
//    `-kernel` image, and this kernel never touches the command port (0x64)
//    except to read status. On hardware that came up through UEFI with no
//    legacy emulation there may be no 8042 at all -- see docs/known-gaps.md
//    GAP-0055.
// 2. Translation is on, so what appears at port 0x60 is SCAN CODE SET 1
//    (the "XT" set), not the set 2 the keyboard itself sends. This is the
//    8042's power-on default and what SeaBIOS leaves configured. The kernel
//    does not verify it, because reading back the controller command byte
//    needs a real command/response handshake with timeouts that nothing here
//    would do anything useful with yet.
// 3. UPDATED AT M3: the 0xE0 prefix IS handled now. It used to be ignored,
//    after which its follower was translated as an ordinary make code, so the
//    up arrow (0xE0 0x48) typed `8` -- a wrong answer rather than a missing
//    feature. `kbdHandle` now consumes the prefix and its follower as a unit,
//    using one donated word in core/boot/kdata.S (`kbd_prefix`). Arrow keys
//    emit nothing at all. 0xE1 (Pause, a six-byte sequence) is STILL wrong in
//    the same way -- GAP-0055 item 2 is narrowed, not closed.
// 4. No shift, no caps lock, no control. Modifier scancodes map to 0x00 and
//    are ignored, so output is always the unshifted US-QWERTY character.
//    Same reason: state. GAP-0055.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Ports and vectors.
// ---------------------------------------------------------------------------

/// 8042 data port: scancodes are read from here.
const int kbdData = 0x60;

/// 8042 status port. Bit 0 (OBF) set means there is a byte waiting at 0x60.
const int kbdStatus = 0x64;

/// Vector the remapped master PIC delivers IRQ1 on (0x20 + 1).
const int vectorKeyboard = 0x21;

// ---------------------------------------------------------------------------
// Scan-code set 1 -> ASCII.
// ---------------------------------------------------------------------------

/// Unshifted US-QWERTY translation of scan-code set 1 MAKE codes, indexed by
/// the scancode itself. 128 entries, so a make code (which always has bit 7
/// clear) is an in-range index BY CONSTRUCTION -- `kbdHandle` rejects
/// everything with bit 7 set before it ever indexes, so no bounds check is
/// needed and none is skipped.
///
/// `0x00` means "no character": unmapped, a modifier, a function key, or a
/// prefix byte. Callers must ignore it rather than print it -- printing NUL
/// would put a garbage glyph on the screen for every shift press.
///
/// Three codes map to control characters on purpose, because they are the
/// operations a console has rather than characters it shows:
/// `0x0E -> 0x08` (backspace), `0x0F -> 0x09` (tab), `0x1C -> 0x0A` (enter,
/// translated to LF -- this kernel's newline is bare LF everywhere).
///
/// A `@rodata final List<u8>` (DCDart ADR-0040) is the ONLY way to spell this
/// in `@bare` DCDart: there is no array type, no String, and no mutable
/// static data. Before ADR-0040 a 128-way translation would have had to be a
/// 128-arm `if` chain.
///
/// The comment above each row is that row's own contents, so the table can be
/// proof-read against a scancode chart without decoding hex: `.` is
/// unmapped, `B` backspace, `T` tab, `N` enter/newline, `_` space.
@rodata
final List<u8> kbdSet1Ascii = const [
  // 0x00-0x0F  ..1234567890-=BT
  u8(0x00), u8(0x00), u8(0x31), u8(0x32), u8(0x33), u8(0x34), u8(0x35), u8(0x36), u8(0x37), u8(0x38), u8(0x39), u8(0x30), u8(0x2D), u8(0x3D), u8(0x08), u8(0x09),
  // 0x10-0x1F  qwertyuiop[]N.as
  u8(0x71), u8(0x77), u8(0x65), u8(0x72), u8(0x74), u8(0x79), u8(0x75), u8(0x69), u8(0x6F), u8(0x70), u8(0x5B), u8(0x5D), u8(0x0A), u8(0x00), u8(0x61), u8(0x73),
  // 0x20-0x2F  dfghjkl;'`.\zxcv
  u8(0x64), u8(0x66), u8(0x67), u8(0x68), u8(0x6A), u8(0x6B), u8(0x6C), u8(0x3B), u8(0x27), u8(0x60), u8(0x00), u8(0x5C), u8(0x7A), u8(0x78), u8(0x63), u8(0x76),
  // 0x30-0x3F  bnm,./.*._......
  u8(0x62), u8(0x6E), u8(0x6D), u8(0x2C), u8(0x2E), u8(0x2F), u8(0x00), u8(0x2A), u8(0x00), u8(0x20), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x40-0x4F  .......789-456+1
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x37), u8(0x38), u8(0x39), u8(0x2D), u8(0x34), u8(0x35), u8(0x36), u8(0x2B), u8(0x31),
  // 0x50-0x5F  230.............
  u8(0x32), u8(0x33), u8(0x30), u8(0x2E), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x60-0x6F  ................
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x70-0x7F  ................
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
];

// ---------------------------------------------------------------------------
// Driver.
// ---------------------------------------------------------------------------

/// Drains anything the 8042 is already holding, and returns how many bytes it
/// discarded.
///
/// Not optional. The controller raises IRQ1 when its output buffer fills and
/// will not raise another until that byte is READ. A key pressed while the
/// kernel was still doing M0/M1 work leaves a byte sitting there; unmask IRQ1
/// on top of it and the line is already high with no edge to come, so the
/// keyboard appears completely dead with no diagnostic anywhere.
///
/// The count is returned rather than dropped so a caller can report it, and
/// so the discarded byte is genuinely consumed rather than assigned to a
/// variable nothing reads.
///
/// Bounded at 16 iterations: the 8042's buffer is one byte deep, so anything
/// past a couple of passes means the status port is stuck reporting
/// "byte ready" -- broken or absent hardware. Spinning forever on that would
/// hang the kernel before the console ever came up, which is precisely the
/// unbounded-poll failure `uart.dart` documents and has no answer for yet.
@bare
u64 kbdDrain() {
  u64 discarded = u64(0);
  u8 status = Port.inb(u16(kbdStatus));
  // Spelled as a bounded loop with a guard-clause exit rather than
  // `while (obf && n < 16)`: DCDart has no boolean operators at all -- no
  // `&&`, no `||`, no `!` (DCDart GAP-0023) -- so a compound condition is not
  // expressible and an early `return` inside the body is the idiom.
  while (discarded < u64(16)) {
    if ((status & u8(0x01)) < u8(1)) {
      return discarded;
    }
    final u8 stale = Port.inb(u16(kbdData));
    // `stale` is deliberately read and dropped: emptying the buffer is the
    // entire operation, and what the stale byte contained is meaningless
    // (whatever was typed before the kernel was listening). The read itself
    // is what matters and cannot be optimized away -- Port.inb lowers to
    // `asm sideeffect` inline assembly (DCDart ADR-0029).
    discarded = discarded + u64(1);
    status = Port.inb(u16(kbdStatus));
  }
  return discarded;
}

/// Prepares the keyboard. Today that is exactly one thing: drain the buffer.
///
/// No controller programming at all -- no self-test, no set-scancode-set, no
/// LED update. Every one of those needs a command/response handshake with a
/// timeout and a failure path, and this kernel has no answer to "the keyboard
/// did not respond" beyond hanging. The 8042's power-on state (set 1 via
/// translation, keyboard port enabled) is what SeaBIOS leaves, and using it
/// as-is is honest about what has actually been verified. GAP-0055.
@bare
void kbdInit() {
  final u64 discarded = kbdDrain();
  // Report the count on screen only, never serial -- see shellStrBanner in
  // shell.dart for why anything printed on COM1 before a keystroke would break
  // M1's byte-exact golden. The banner ends with `8042 drained: `, so this
  // digit and its newline finish that line.
  vgaPutc((discarded & u64(0x0F)).toU8() + u8(0x30));
  vgaPutc(u8(0x0A));
  vgaUpdateHwCursor();
}

/// Masks the PIT and unmasks the keyboard, LEAVING EVERY OTHER LINE ALONE.
///
/// The PIT (IRQ0) stays MASKED deliberately: `kmain()` masked it before M1's
/// deliberate fault so a tick could not interleave output into the middle of a
/// diagnostic, and re-enabling it here would restart a 100 Hz interrupt that
/// has nothing left to do and would only add jitter to the console.
///
/// **D1 (ADR-0042) CHANGED HOW, NOT WHAT.** This used to be
/// `outb(0x21, 0xFD); outb(0xA1, 0xFF)` -- two WHOLE-BYTE writes, which
/// re-masked every line they did not name and re-masked the entire slave PIC
/// every time. `docs/design/display-protocol.md` s4.4 identified that as a
/// cross-cutting blocker on every interrupt-driven device this OS will ever
/// have: an IRQ12 unmasked at boot survived until the next `ticks` command and
/// then stopped, silently, with no diagnostic anywhere. It is now two
/// read-modify-writes of one bit each ([picMaskLine]/[picUnmaskLine] in
/// mouse.dart), so IRQ2 and IRQ12 come through this function unchanged.
///
/// **The port traffic it produces with no mouse present is identical to what it
/// always produced**: from a mask of 0xFE this still leaves the master at 0xFD,
/// which is why no earlier milestone's behaviour moves.
@bare
void picUnmaskKeyboardOnly() {
  picMaskLine(u64(0));
  picUnmaskLine(u64(1));
}

/// Unmasks IRQ0 (the PIT) as well as IRQ1. Mask byte 0xFC = bits 0 and 1
/// clear.
///
/// Used ONLY by the `ticks` command, which turns the timer on, watches the
/// counter advance by a fixed amount, and turns it off again
/// (`core/kernel/shell.dart`). The PIT stays masked the rest of the time for
/// M2's original reason -- nothing else needs a timer, and 100 interrupts a
/// second would only add jitter between keystrokes -- and for one M3 reason:
/// with it masked at rest, the tick counter holds still, which is what lets
/// `ticks` print a value a byte-exact golden can assert. See
/// docs/known-gaps.md GAP-0058.
/// D1 (ADR-0042): two read-modify-writes rather than two whole-byte writes,
/// for [picUnmaskKeyboardOnly]'s reason exactly. With no mouse present it still
/// takes a master mask of 0xFD to 0xFC, so `ticks` behaves as it always has;
/// with one present, IRQ12 SURVIVES a `ticks` command, which before this it did
/// not.
@bare
void picUnmaskTimerAndKeyboard() {
  picUnmaskLine(u64(0));
  picUnmaskLine(u64(1));
}

/// Handles one IRQ1: read the scancode, translate it, hand it to the line
/// editor.
///
/// Reading port 0x60 is not optional even for a scancode that is thrown away
/// -- the controller will not raise another IRQ1 until its output buffer is
/// emptied, so an early `return` before the read would make the keyboard stop
/// after exactly one keypress. Every path below reads it first.
///
/// Four classes are dropped rather than printed, which is the difference
/// between a console and a garbage generator:
///
///   - **The 0xE0 prefix, and the byte after it.** See [kbdSetPrefix] below;
///     this is the M3 fix for docs/known-gaps.md GAP-0055 item 2.
///   - **Key releases.** Bit 7 set means a break code. Every key produces one,
///     so echoing them would double every character.
///   - **Unmapped codes.** A 0x00 in the table means modifier, function key,
///     or nothing at all. Printing it would put a NUL glyph on the screen for
///     every shift press.
///   - **Anything typed while a command is running** (shell state 2). There is
///     no input queue to hold it (GAP-0055 item 4), and letting it into the
///     buffer would change the line out from under `shellExecute`.
///
/// **M3 CHANGE: this no longer echoes.** It calls [shellKey], which appends to
/// the line buffer, echoes through [conPutc] itself, and treats Enter and
/// backspace as editing operations rather than characters. The visible
/// difference is that backspace now shortens a LINE, and Enter now submits
/// one, instead of both being bytes that happen to move a cursor.
@bare
void kbdHandle() {
  final u8 scancode = Port.inb(u16(kbdData));

  // --- The 0xE0 two-byte sequence, consumed as a unit -------------------
  //
  // Extended keys (arrows, right-hand modifiers, keypad Enter, the cursor
  // block) send 0xE0 and then a second byte, in two SEPARATE interrupts.
  // Before M3 the 0xE0 was ignored and its follower was then translated as
  // though it were an ordinary make code, so the up arrow (0xE0 0x48) typed
  // `8` -- 0x48 is keypad-8 in the table above. That was a wrong answer, not a
  // missing feature, which is why it was the first thing GAP-0055 said to fix.
  //
  // The flag is cleared for the follower whether it is a make code or a break
  // code (0xE0 0x48 / 0xE0 0xC8), because BOTH halves of an extended key press
  // carry the prefix. Ignoring the release without clearing would leave the
  // flag set and swallow the next ordinary key.
  //
  // Still not handled, and still recorded rather than implied: 0xE1 (the Pause
  // key's six-byte sequence). It maps to 0x00 in the table and its five
  // followers are translated as ordinary keys, so Pause still types garbage.
  // GAP-0055 item 2 stays open for that reason -- narrowed, not closed.
  if (scancode == u8(0xE0)) {
    kbdSetPrefix(u64(1));
    return;
  }
  if (kbdPrefix() > u64(0)) {
    kbdSetPrefix(u64(0));
    return; // the extended key itself: consumed, deliberately does nothing
  }

  if ((scancode & u8(0x80)) > u8(0)) {
    return; // key release
  }
  // In range by construction: bit 7 is clear, so scancode < 128 and the table
  // has 128 entries.
  final u8 c = Pointer<u8>.fromAddress(
    Rodata.addressOf(kbdSet1Ascii) + scancode.toU64(),
  ).value;
  if (c < u8(1)) {
    return; // unmapped
  }
  if (shellState() > u64(0)) {
    return; // a line is submitted or a command is running -- no queue exists
  }
  shellKey(c);
  vgaUpdateHwCursor();
}
