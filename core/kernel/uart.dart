// core/kernel/uart.dart
//
// oscortex_core's real 16550 UART (COM1) driver -- the reusable module
// docs/known-gaps.md GAP-0001 said had to exist before anything longer than
// M0's 15-byte proof-of-life could be written safely, and which the
// interrupts milestone (ROADMAP.md M1) needs regardless.
//
// This is a `part of 'kmain.dart'`, NOT a separate library, and that is a
// deliberate, forced choice, not a style preference: `dcc-lower` lowers
// EXACTLY ONE Kernel library per `dcc build` invocation -- the one whose
// importUri matches the source file passed on the command line
// (core/dcc-lower/lib/lower.dart's `component.libraries.firstWhere(...)`).
// A `@bare` function in an IMPORTED DCDart library is silently dropped: it
// never reaches DC-IR, never reaches the object file, and the only symptom
// is an undefined symbol at link time. Dart `part`/`part of` files belong to
// the SAME library, so their procedures land in `targetLibrary.procedures`
// and are lowered normally -- verified empirically (a two-file part/part-of
// build produced both symbols in one .o; the same code split across an
// import produced neither). See docs/known-gaps.md GAP-0004.
//
// UPDATE 2026-08-20 (2): fixed messages are `@rodata` byte tables now, not one
// `Port.outb` call per character. See `uartWrite` below and
// docs/known-gaps.md GAP-0004 item 6.
//
// UPDATE 2026-08-20: these functions return `void` again. They used to all
// return `u64` because `dcc-lower` had no `ExpressionStatement` case for a
// call to a `@bare` function, so `uartPutc(x);` as a statement was a hard
// compile error and every call site had to read `final u64 _ = uartPutc(x);`.
// That is fixed upstream: a VOID-returning `@bare` call may now stand alone
// as a statement (a value-returning one still may not, and says so clearly).
// Re-verified by compiling both shapes before making this change, not
// assumed from a changelog. known-gaps GAP-0004 item 3 updated accordingly.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Register map (16550, COM1 base 0x3F8). Spelled as literals at every use
// site rather than named constants because `dcc-lower` recognizes a sized-int
// literal ONLY as a direct `u8(<int literal>)`/`u16(<int literal>)` call
// shape -- a top-level `const u16 com1 = u16(0x3F8);` is not lowered at all
// (only `@bare` procedures are). The comment on each line is the name.
//
//   0x3F8  THR (write) / RBR (read) / DLL (when DLAB=1)
//   0x3F9  IER          / DLM (when DLAB=1)
//   0x3FA  FCR (write)  / IIR (read)
//   0x3FB  LCR          (bit 7 = DLAB)
//   0x3FC  MCR
//   0x3FD  LSR          (bit 5 = THRE, transmit holding register empty)
// ---------------------------------------------------------------------------

/// Initializes COM1: 38400 baud, 8N1, FIFOs on. Identical register sequence
/// to M0's (which came from DCDart's own core/examples/m2-port/port_io.dart,
/// already verified there) -- moved here unchanged rather than reinvented, so
/// this is not a behaviour change, only a relocation into a real module.
///
/// One deliberate difference from M0: IER (0x3F9) is left at 0x00, i.e.
/// receive/transmit interrupts DISABLED. M1 will change this, but only once
/// there is an IDT to route a UART IRQ into -- enabling it now would arm an
/// interrupt line with no handler behind it.
@bare
void uartInit() {
  Port.outb(u16(0x3F9), u8(0x00)); // IER: all UART interrupts off
  Port.outb(u16(0x3FB), u8(0x80)); // LCR: DLAB=1 (divisor latch visible)
  Port.outb(u16(0x3F8), u8(0x03)); // DLL: divisor low  = 3 -> 38400 baud
  Port.outb(u16(0x3F9), u8(0x00)); // DLM: divisor high = 0
  Port.outb(u16(0x3FB), u8(0x03)); // LCR: DLAB=0, 8 data bits, no parity, 1 stop
  Port.outb(u16(0x3FA), u8(0xC7)); // FCR: enable+clear both FIFOs, 14-byte trigger
  Port.outb(u16(0x3FC), u8(0x0B)); // MCR: DTR+RTS+OUT2
}

/// Writes one byte to COM1, busy-waiting on LSR bit 5 (THRE) first.
///
/// This is the real Transmit-Holding-Register-Empty poll that GAP-0001
/// recorded as missing at M0. It is no longer missing: `u8 operator &`
/// (DCDart ADR-0030) and `u8 operator <` (DCDart ADR-0035) both exist now,
/// which is exactly what the condition needs. The loop condition is spelled
/// `(lsr & 0x20) < 1` rather than `== 0` on purpose -- Dart refuses to let an
/// extension type declare `operator ==` at all (DCDart ADR-0035 §3 documents
/// this), so while `==` does lower (via `EqualsCall`), `<` is the spelling
/// that goes through the same generalized operator path as every other
/// comparison and needs no special case.
///
/// Verified structurally, not assumed: disassembling this function shows a
/// real `in (%dx),%al` / `and` / `cmp` / `jae` back edge around the wait, with
/// the `out %al,(%dx)` only on the exit path.
///
/// STILL FRAGILE, stated plainly: there is no timeout. If COM1 is absent or
/// wedged, THRE never sets and this spins forever with interrupts disabled --
/// i.e. it hangs the machine silently instead of failing loudly. A bounded
/// spin needs a counter compared against a limit, which is expressible today,
/// but "give up and do what?" has no answer yet (there is no second output
/// device, no panic path, and no way to signal a failure to the harness). It
/// is left unbounded deliberately rather than bounded-and-silently-lossy, and
/// is recorded in docs/known-gaps.md GAP-0001 as still-open.
@bare
void uartPutc(u8 c) {
  u8 lsr = Port.inb(u16(0x3FD));
  while ((lsr & u8(0x20)) < u8(1)) {
    lsr = Port.inb(u16(0x3FD));
  }
  Port.outb(u16(0x3F8), c);
}

/// Writes one hex digit for the low nibble of [n] (the high nibble is
/// ignored -- callers mask). Two branches, not a 16-arm dispatch, because
/// the arithmetic stays in `u8`: 0-9 -> '0'..'9' (+0x30), 10-15 -> 'A'..'F'
/// (+0x37).
///
/// This is why every hex value printed by this driver is read out of MEMORY
/// one byte at a time rather than computed in a register: DCDart has no
/// width-conversion primitive at all (no `u64 -> u8` narrowing, no `u8 -> u64`
/// widening -- see dc-ir/lib/instructions.dart's own "not yet [implemented]"
/// note, and known-gaps GAP-0004). A nibble extracted from a `u64` cannot be
/// turned into the `u8` that `Port.outb` requires. Extracting it from a `u8`
/// loaded via `Pointer<u8>` keeps the whole computation at one width and
/// needs no conversion.
@bare
void uartPutNibble(u8 n) {
  if ((n & u8(0x0F)) < u8(10)) {
    conPutc((n & u8(0x0F)) + u8(0x30));
    return;
  }
  conPutc((n & u8(0x0F)) + u8(0x37));
}

/// Writes the byte at [addr] as two hex digits, high nibble first.
@bare
void uartPutHexByteAt(u64 addr) {
  final u8 b = Pointer<u8>.fromAddress(addr).value;
  uartPutNibble(b >> u8(4));
  uartPutNibble(b);
}

/// Writes the little-endian 32-bit value at [addr] as 8 hex digits, MOST
/// significant digit first (i.e. printed big-endian, read little-endian):
/// bytes are emitted from `addr+3` down to `addr+0`.
@bare
void uartPutHex32At(u64 addr) {
  u64 i = u64(4);
  while (u64(0) < i) {
    i = i - u64(1);
    uartPutHexByteAt(addr + i);
  }
}

/// Writes the little-endian 64-bit value at [addr] as 16 hex digits, most
/// significant digit first.
@bare
void uartPutHex64At(u64 addr) {
  u64 i = u64(8);
  while (u64(0) < i) {
    i = i - u64(1);
    uartPutHexByteAt(addr + i);
  }
}

/// Writes [value] as exactly [digits] hex digits, most significant first.
///
/// This takes a VALUE, unlike the `...At` functions above which take an
/// ADDRESS. Those exist because DCDart used to have no width conversion at
/// all: a nibble extracted from a `u64` could not become the `u8` that
/// `Port.outb` requires, so the only way to print a number was to read it
/// back out of memory a byte at a time. `.toU8()` (DCDart ADR-0037) removed
/// that constraint, so a computed value -- an install count, a vector number,
/// a tick total -- can now be printed directly.
///
/// The `...At` variants are kept rather than reimplemented on top of this
/// one: they read little-endian memory and print big-endian, which is a
/// genuinely different operation from formatting a value already in a
/// register, and `core/kernel/multiboot.dart` wants exactly that.
@bare
void uartPutHex(u64 value, u64 digits) {
  u64 i = digits;
  while (u64(0) < i) {
    i = i - u64(1);
    uartPutNibble(((value >> (i * u64(4))) & u64(0xF)).toU8());
  }
}

/// Newline. Named rather than inlined because it appears ~12 times and
/// `uartPutc(u8(0x0A))` reads worse than `uartNewline()` at every one.
@bare
void uartNewline() {
  conPutc(u8(0x0A));
}

/// Space separator.
@bare
void uartSpace() {
  conPutc(u8(0x20));
}

/// M0's proof-of-life banner.
///
/// Kept byte-identical to M0's message on purpose: it is the first line of
/// serial output and `tests/conformance/m0-boot/run.sh` asserts it exactly.
/// M0's proof-of-life banner, including its trailing newline.
///
/// `"OSCORTEX M0 OK\n"` — 15 bytes.
@rodata
final List<u8> uartBannerLine = const [u8(0x4F), u8(0x53), u8(0x43), u8(0x4F), u8(0x52), u8(0x54), u8(0x45), u8(0x58), u8(0x20), u8(0x4D), u8(0x30), u8(0x20), u8(0x4F), u8(0x4B), u8(0x0A)];

/// Writes [len] bytes starting at [base] to COM1.
///
/// The real string-output primitive. Until `@rodata` existed (DCDart ADR-0040)
/// there was no way to spell a literal message in `@bare` DCDart at all: no
/// String type, no array type, and no static data, so every fixed message in
/// this kernel was a hand-written run of one `uartPutc` call per character.
/// `docs/known-gaps.md` GAP-0001 and GAP-0004 both recorded that as the single
/// largest ergonomic gap in writing kernel code in this language.
///
/// [base] comes from `Rodata.addressOf(table)`, which is the address of
/// element 0 — there is **no header of any kind** in front of it, which is why
/// the length has to be passed separately. That is a contract of ADR-0040,
/// asserted by DCDart's own conformance suite, not an assumption made here.
///
/// Lengths are passed rather than derived because a `@rodata` table carries no
/// length word. A wrong length is not a silent corruption, though: every byte
/// this kernel prints is asserted by three byte-exact harnesses, so an
/// off-by-one changes the capture and fails immediately.
///
/// Deliberately calls the existing [uartPutc] per byte rather than
/// reimplementing the write: the Transmit-Holding-Register-Empty poll is the
/// thing that makes output longer than one FIFO safe, and duplicating it here
/// would be two places to get it wrong.
@bare
void uartWrite(u64 base, u64 len) {
  u64 i = u64(0);
  while (i < len) {
    conPutc(Pointer<u8>.fromAddress(base + i).value);
    i = i + u64(1);
  }
}

/// Writes the proof-of-life banner and its newline.
@bare
void uartPutBanner() {
  uartWrite(Rodata.addressOf(uartBannerLine), u64(15));
}
