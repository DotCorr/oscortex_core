// core/kernel/mouse.dart
//
// oscortex_core D1: the PS/2 MOUSE -- the first pointing device this OS has
// ever had. Auxiliary port of the 8042, IRQ12 on the SLAVE 8259, the three-byte
// packet protocol, and the four-byte IntelliMouse extension WHEN THE DEVICE
// ANSWERS THE KNOCK AND NOT OTHERWISE.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is -- `dcc` lowers exactly one library per object file. See
// docs/known-gaps.md GAP-0004 item 4.
//
// The architecture is docs/decisions/0035-the-ps2-mouse.md. The design this
// implements is docs/design/display-protocol.md D1, and the six steps that
// document listed are all here, including the sixth one it said was missing.
//
// ---------------------------------------------------------------------------
// THIS DRIVER IS SHAPED LIKE keyboard.dart ON PURPOSE
// ---------------------------------------------------------------------------
// The keyboard already solved controller access (ports 0x60/0x64 and the OBF
// bit), IRQ wiring (a vector arm in `isrDispatch`, an EOI, an unmask that runs
// once the console is up) and translation-in-the-handler. This file reuses
// `kbdData`/`kbdStatus` rather than declaring its own names for the same two
// ports, installs its arm next to the keyboard's, and is unmasked from the same
// place in `m2Enter()` immediately after `kbdInit()`. Where it DIFFERS from the
// keyboard, it differs because the hardware does:
//
//   * THE KEYBOARD NEVER WRITES THE COMMAND PORT AND THIS FILE MUST. `kbdInit`
//     deliberately uses SeaBIOS's power-on state as-is; a mouse cannot, because
//     the auxiliary port is DISABLED at power-on and the controller's
//     configuration byte has the aux interrupt turned off. Every write here is
//     a read-modify-write of the byte the controller reports: bit 1 is SET (aux
//     interrupt on) and bit 5 is CLEARED (aux clock on) and NOTHING ELSE IS
//     TOUCHED -- not bit 0, the keyboard's own interrupt enable, and not bit 6,
//     translation, which is what makes what arrives at 0x60 scan code set 1 and
//     therefore what `kbdSet1Ascii` is a table of. A mouse that stops the
//     keyboard working is worse than no mouse, and that is a property of these
//     two bits being left alone.
//
//   * IT IS ON THE SLAVE PIC, WHICH NOTHING IN THIS KERNEL HAS EVER USED. The
//     slave has been masked 0xFF at every point in the kernel's life. IRQ12
//     needs the slave's line 4 unmasked AND the master's line 2 -- the cascade
//     -- unmasked, or the slave's interrupt has nowhere to go. It also needs an
//     EOI to BOTH chips (see `picEoiSlave`).
//
//   * IT HAS A FRAMING PROBLEM THE KEYBOARD DOES NOT. A scancode is
//     self-delimiting. A mouse packet is three or four bytes with no length and
//     no terminator, and one dropped byte offsets the stream forever. See
//     [mouseByte].
//
// ---------------------------------------------------------------------------
// WHAT IS DETECTED AND WHAT IS ASSUMED, STATED RATHER THAN HOPED
// ---------------------------------------------------------------------------
// 1. THE SCROLL WHEEL IS DETECTED, NOT ASSUMED. [mouseEnable] performs the
//    IntelliMouse "magic knock" -- set sample rate 200, then 100, then 80 --
//    and then ASKS the device for its identity with 0xF2. The packet size
//    becomes 4 if and only if the answer is 0x03. The id that came back is kept
//    in the state block and printed by the `mouse` command, so the claim "this
//    device has a wheel" is always accompanied by the byte it was derived from.
//    A device that answers 0x00 stays on three-byte packets and the fourth-byte
//    path is never entered.
// 2. THE CONTROLLER IS ASSUMED TO EXIST. Same assumption `keyboard.dart` makes
//    and for the same reason (GAP-0055): under QEMU SeaBIOS leaves an 8042
//    there. Every wait in this file is BOUNDED, so an absent controller makes
//    the init sequence fail and record its failure in [mouseInitFlags] rather
//    than hang the machine -- which is strictly better than the keyboard's
//    behaviour, not equal to it.
// 3. NOTHING IS ASSUMED ABOUT WHAT THE DEVICE SENDS. The overflow bits are
//    honoured, the always-one bit is checked, and the 9-bit deltas are
//    sign-extended from the sign bits in byte 0 rather than from byte 1's or
//    byte 2's own high bit -- which is the single easiest thing to get wrong
//    here and the reason `d1-mouse`'s harness asserts a NEGATIVE delta before
//    it asserts a positive one.
//
// ---------------------------------------------------------------------------
// NO ALLOCATION IN THE INTERRUPT HANDLER
// ---------------------------------------------------------------------------
// [mouseHandle] and everything it calls read and write a fixed `@bss` block
// through `Pointer<u64>` and touch nothing else. There is no queue to grow, no
// buffer to take, and no frame to allocate; the compiler forbids allocation in
// `@bare` code and `core/scripts/verify-freestanding.sh` is the mechanical
// proof that none appeared. The cursor is NOT drawn from the handler -- see
// [shellMouse].

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040). Byte counts
// are hand-maintained literals at every call site (docs/known-gaps.md
// GAP-0060); d1-mouse's harness cross-checks all of them against the symbol
// table, which is the check m5-pci invented and every milestone since has run.
// ---------------------------------------------------------------------------

/// T.he per-packet decode line's label
///
/// `"MOUSE PKT "` -- 10 bytes.
@rodata
final List<u8> mouseStrPkt = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x50), u8(0x4B), u8(0x54), u8(0x20),
];

/// S.eparator before the raw 9-bit X delta
///
/// `" DX "` -- 4 bytes.
@rodata
final List<u8> mouseStrDx = const [
  u8(0x20), u8(0x44), u8(0x58), u8(0x20),
];

/// S.eparator before the raw 9-bit Y delta
///
/// `" DY "` -- 4 bytes.
@rodata
final List<u8> mouseStrDy = const [
  u8(0x20), u8(0x44), u8(0x59), u8(0x20),
];

/// S.eparator before an X coordinate
///
/// `" X "` -- 3 bytes.
@rodata
final List<u8> mouseStrX = const [
  u8(0x20), u8(0x58), u8(0x20),
];

/// S.eparator before a Y coordinate
///
/// `" Y "` -- 3 bytes.
@rodata
final List<u8> mouseStrY = const [
  u8(0x20), u8(0x59), u8(0x20),
];

/// S.eparator before the button bitmap
///
/// `" B "` -- 3 bytes.
@rodata
final List<u8> mouseStrB = const [
  u8(0x20), u8(0x42), u8(0x20),
];

/// T.he resynchronisation line's label
///
/// `"MOUSE SYNC "` -- 11 bytes.
@rodata
final List<u8> mouseStrSync = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x53), u8(0x59), u8(0x4E), u8(0x43), u8(0x20),
];

/// S.eparator before a running counter
///
/// `" N "` -- 3 bytes.
@rodata
final List<u8> mouseStrN = const [
  u8(0x20), u8(0x4E), u8(0x20),
];

/// T.he overflow-discard line's label
///
/// `"MOUSE OVF "` -- 10 bytes.
@rodata
final List<u8> mouseStrOvf = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x4F), u8(0x56), u8(0x46), u8(0x20),
];

/// T.he `mouse` command's report label
///
/// `"MOUSE STATE"` -- 11 bytes.
@rodata
final List<u8> mouseStrState = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x54), u8(0x45),
];

/// S.eparator before the packet counter
///
/// `" PKT "` -- 5 bytes.
@rodata
final List<u8> mouseStrPktN = const [
  u8(0x20), u8(0x50), u8(0x4B), u8(0x54), u8(0x20),
];

/// S.eparator before the resync counter
///
/// `" SYNC "` -- 6 bytes.
@rodata
final List<u8> mouseStrSyncN = const [
  u8(0x20), u8(0x53), u8(0x59), u8(0x4E), u8(0x43), u8(0x20),
];

/// S.eparator before the overflow counter
///
/// `" OVF "` -- 5 bytes.
@rodata
final List<u8> mouseStrOvfN = const [
  u8(0x20), u8(0x4F), u8(0x56), u8(0x46), u8(0x20),
];

/// S.eparator before the IRQ12 counter
///
/// `" IRQ "` -- 5 bytes.
@rodata
final List<u8> mouseStrIrq = const [
  u8(0x20), u8(0x49), u8(0x52), u8(0x51), u8(0x20),
];

/// S.eparator before the stray-byte counter
///
/// `" STRAY "` -- 7 bytes.
@rodata
final List<u8> mouseStrStray = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x52), u8(0x41), u8(0x59), u8(0x20),
];

/// S.eparator before the detected packet size
///
/// `" SIZE "` -- 6 bytes.
@rodata
final List<u8> mouseStrSize = const [
  u8(0x20), u8(0x53), u8(0x49), u8(0x5A), u8(0x45), u8(0x20),
];

/// S.eparator before the device id
///
/// `" ID "` -- 4 bytes.
@rodata
final List<u8> mouseStrId = const [
  u8(0x20), u8(0x49), u8(0x44), u8(0x20),
];

/// S.eparator before the wheel-up counter
///
/// `" WU "` -- 4 bytes.
@rodata
final List<u8> mouseStrWu = const [
  u8(0x20), u8(0x57), u8(0x55), u8(0x20),
];

/// S.eparator before the wheel-down counter
///
/// `" WD "` -- 4 bytes.
@rodata
final List<u8> mouseStrWd = const [
  u8(0x20), u8(0x57), u8(0x44), u8(0x20),
];

/// S.eparator before the init-progress bitmap
///
/// `" INIT "` -- 6 bytes.
@rodata
final List<u8> mouseStrInit = const [
  u8(0x20), u8(0x49), u8(0x4E), u8(0x49), u8(0x54), u8(0x20),
];

/// T.he cursor-blit report's label
///
/// `"MOUSE DRAW"` -- 10 bytes.
@rodata
final List<u8> mouseStrDraw = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x44), u8(0x52), u8(0x41), u8(0x57),
];

/// S.eparator before the framebuffer base
///
/// `" BASE "` -- 6 bytes.
@rodata
final List<u8> mouseStrBase = const [
  u8(0x20), u8(0x42), u8(0x41), u8(0x53), u8(0x45), u8(0x20),
];

/// S.eparator before the framebuffer pitch
///
/// `" PITCH "` -- 7 bytes.
@rodata
final List<u8> mouseStrPitch = const [
  u8(0x20), u8(0x50), u8(0x49), u8(0x54), u8(0x43), u8(0x48), u8(0x20),
];

/// S.eparator before the row-8 scanline address
///
/// `" ROW8 "` -- 6 bytes.
@rodata
final List<u8> mouseStrRow8 = const [
  u8(0x20), u8(0x52), u8(0x4F), u8(0x57), u8(0x38), u8(0x20),
];

/// P.rinted when no framebuffer mode is set
///
/// `"MOUSE NOFB\n"` -- 11 bytes.
@rodata
final List<u8> mouseStrNoFb = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x4E), u8(0x4F), u8(0x46), u8(0x42), u8(0x0A),
];

/// T.he `mouse feed` report's label
///
/// `"MOUSE FEED "` -- 11 bytes.
@rodata
final List<u8> mouseStrFeed = const [
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20), u8(0x46), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// C.ommand name
///
/// `"mouse"` -- 5 bytes.
@rodata
final List<u8> mouseStrCmd = const [
  u8(0x6D), u8(0x6F), u8(0x75), u8(0x73), u8(0x65),
];

/// C.ommand name plus its argument's space
///
/// `"mouse feed "` -- 11 bytes.
@rodata
final List<u8> mouseStrCmdFeed = const [
  u8(0x6D), u8(0x6F), u8(0x75), u8(0x73), u8(0x65), u8(0x20), u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20),
];

/// T.he usage line
///
/// `"mouse: usage: mouse | mouse feed <hex>\n"` -- 39 bytes.
@rodata
final List<u8> mouseStrUsage = const [
  u8(0x6D), u8(0x6F), u8(0x75), u8(0x73), u8(0x65), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65),
  u8(0x3A), u8(0x20), u8(0x6D), u8(0x6F), u8(0x75), u8(0x73), u8(0x65), u8(0x20), u8(0x7C), u8(0x20), u8(0x6D), u8(0x6F),
  u8(0x75), u8(0x73), u8(0x65), u8(0x20), u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20), u8(0x3C), u8(0x68), u8(0x65),
  u8(0x78), u8(0x3E), u8(0x0A),
];


// ---------------------------------------------------------------------------
// Ports, vectors and protocol constants.
//
// `kbdData` (0x60) and `kbdStatus` (0x64) are keyboard.dart's names and are
// reused deliberately: they are the SAME two ports, and giving them a second
// pair of names in this file would make it look as though there were a second
// controller. There is one, and it is shared. That sharing is the whole reason
// this file is careful.
// ---------------------------------------------------------------------------

/// Vector the remapped SLAVE PIC delivers IRQ12 on (0x28 + 4).
const int vectorMouse = 0x2C;

/// The slave 8259's own line number for the auxiliary device.
const int irqMouseLine = 12;

/// The master's line the slave is cascaded onto. Unmasking IRQ12 without this
/// is the classic silent failure: the slave asserts, the master has that input
/// masked, and nothing is ever delivered.
const int irqCascadeLine = 2;

/// 8042 status-register bits.
///
/// Bit 0 (OBF) -- a byte is waiting at 0x60.
/// Bit 1 (IBF) -- the controller has not yet consumed the last byte written.
/// Bit 5 (AUX) -- the waiting byte came from the AUXILIARY device, not the
///                keyboard. This is the only thing that distinguishes a mouse
///                byte from a scancode at the port, and it is why
///                [mouseHandle] reads the status BEFORE the data.
const int mouseStatusObf = 0x01;
const int mouseStatusIbf = 0x02;
const int mouseStatusAux = 0x20;

/// 8042 controller commands.
const int mouseCmdEnableAux = 0xA8; // enable the auxiliary port
const int mouseCmdReadCfg = 0x20; // read the controller configuration byte
const int mouseCmdWriteCfg = 0x60; // write it back
const int mouseCmdToAux = 0xD4; // "the next byte written to 0x60 goes to the mouse"

/// Configuration-byte bits this file touches, and ONLY these two.
///
/// Bit 1 set enables the interrupt the auxiliary device raises (IRQ12).
/// Bit 5 set DISABLES the auxiliary clock, so it must be cleared.
///
/// Bit 0 (the keyboard's own interrupt enable) and bit 6 (translation, which is
/// what makes port 0x60 deliver scan code set 1) are deliberately preserved.
/// Clearing either of them is exactly how a mouse driver kills typing.
const int mouseCfgAuxIrq = 0x02;
const int mouseCfgAuxClockOff = 0x20;

/// Mask that clears [mouseCfgAuxClockOff] from a 64-bit configuration value.
const int mouseCfgAuxClockKeep = 0xFFFFFFDF;

/// Device commands, sent through [mouseAuxWrite].
const int mouseDevReset = 0xFF;
const int mouseDevDefaults = 0xF6;
const int mouseDevSampleRate = 0xF3;
const int mouseDevGetId = 0xF2;
const int mouseDevEnable = 0xF4;

/// Device replies.
const int mouseReplyAck = 0xFA;
const int mouseReplyBat = 0xAA; // "basic assurance test" passed, after a reset

/// The IntelliMouse knock: three sample rates, in this order, and then ask.
const int mouseKnock1 = 200;
const int mouseKnock2 = 100;
const int mouseKnock3 = 80;

/// The device id that means "four-byte packets with a Z axis".
const int mouseIdWheel = 0x03;

/// Packet sizes. Three unless the knock above is answered.
const int mousePacketPlain = 3;
const int mousePacketWheel = 4;

/// Byte 0's fixed bits.
///
/// Bit 3 is ALWAYS ONE in a first byte. It is the only framing signal a PS/2
/// mouse gives, and [mouseByte] uses it as such.
const int mousePktAlwaysOne = 0x08;

/// Byte 0's sign bits for the two 9-bit deltas, and its two overflow bits.
const int mousePktSignX = 0x10;
const int mousePktSignY = 0x20;
const int mousePktOverflow = 0xC0;

/// Byte 0's three button bits: left, right, middle.
const int mousePktButtons = 0x07;

/// The value a 9-bit two's-complement delta is subtracted from when its sign
/// bit is set: value = byte - 256, so magnitude = 256 - byte.
const int mouseDeltaSpan = 256;

/// Returned by [mouseRead] and [mouseAuxWrite] when the controller did not
/// answer inside [mouseSpinLimit]. Deliberately 0x100 -- outside the range of
/// any byte, so no real reply can be mistaken for a timeout and no timeout can
/// be mistaken for a reply.
const int mouseNoReply = 0x100;

/// How many status-port reads a wait will do before giving up.
///
/// BOUNDED, unlike `uartPutc`'s transmit-holding poll (GAP-0001), and this is
/// the one place in the kernel where the bound has a real answer to "give up
/// and do what?": the failure is recorded as a missing bit in
/// [mouseInitFlags], the `mouse` command prints it, and the machine carries on
/// with no pointer rather than hanging before the shell ever appears. An 8042
/// that is absent (a UEFI machine with no legacy emulation -- GAP-0055) reaches
/// this limit on the first wait and costs one boot a few milliseconds.
const int mouseSpinLimit = 100000;

// ---------------------------------------------------------------------------
// State. One `@bss` block, DCDart mutable statics (ADR-0021).
// ---------------------------------------------------------------------------

/// Twenty `u64` words of driver state.
///
/// One block with fixed offsets rather than twenty symbols, for `fbStateBlock`'s
/// reason: [mouseState]/[mouseSetState] are two functions that know the layout.
///
/// **SECOND-TO-LAST IN `.bss`.** ADR-0031 s4.3 rule 5 requires S0's `ioctlStore`
/// to be last, so this block goes immediately before it, and every harness that
/// measures "the donated bytes from MY block to the end of `.bss`" subtracts
/// this one after S0's and before M20's. That is the same accounting M14, M15,
/// M16, M19, M20 and S0 each got in turn -- see ADR-0033 s6.4, which is the
/// entry that explains why "put it last" is necessary but not sufficient.
@bss
final Bss mouseStore = const Bss(bytes: mouseStoreBytes);

/// Words in the state block, and the bytes they come to.
///
/// Two constants rather than one literal because [mouseInit] loops over the
/// WORDS and every harness measures the BYTES, and a block that grew by a word
/// without the loop growing with it would leave the new word as `.bss` litter --
/// read by an interrupt handler, on the first packet of the boot.
/// `d1-mouse` asserts `mouseStoreBytes == mouseStoreWords * 8` and asserts the
/// loop bound is the word count rather than a literal.
const int mouseStoreWords = 20;
const int mouseStoreBytes = 160;

/// Word indices inside the block.
const int mouseWordIdx = 0; // 0..3: how many bytes of the current packet are in
const int mouseWordB0 = 1;
const int mouseWordB1 = 2;
const int mouseWordB2 = 3;
const int mouseWordB3 = 4;
const int mouseWordX = 5; // accumulated pointer position, in pixels
const int mouseWordY = 6;
const int mouseWordButtons = 7;
const int mouseWordPackets = 8;
const int mouseWordSyncs = 9;
const int mouseWordOverflows = 10;
const int mouseWordIrqs = 11;
const int mouseWordStrays = 12;
const int mouseWordSize = 13; // 3 or 4, DETECTED
const int mouseWordId = 14; // whatever 0xF2 answered
const int mouseWordFlags = 15; // how far [mouseEnable] actually got
const int mouseWordWheelUp = 16;
const int mouseWordWheelDown = 17;
const int mouseWordDxRaw = 18; // the last packet's raw 9-bit deltas, as sent
const int mouseWordDyRaw = 19;

/// [mouseInitFlags] bits. One per step of [mouseEnable] that SUCCEEDED, so the
/// `mouse` command's `INIT` field says how far the sequence got rather than
/// merely whether it finished.
const int mouseFlagAuxPort = 0x0001; // 0xA8 accepted
const int mouseFlagCfgRead = 0x0002; // the configuration byte came back
const int mouseFlagCfgWrite = 0x0004; // the modified byte was accepted
const int mouseFlagReset = 0x0008; // 0xFF ACKed
const int mouseFlagBat = 0x0010; // 0xAA (self-test passed) followed it
const int mouseFlagId = 0x0020; // 0xF2 answered with something
const int mouseFlagWheel = 0x0040; // ...and the something was 0x03
const int mouseFlagReporting = 0x0080; // 0xF4 ACKed
const int mouseFlagUnmasked = 0x0100; // IRQ2 and IRQ12 unmasked
const int mouseFlagPostReset = 0x0200; // the post-reset identity byte was read
const int mouseFlagDefaults = 0x0400; // 0xF6 (set defaults) ACKed

/// Reads word [i].
@bare
u64 mouseState(u64 i) {
  return Pointer<u64>.fromAddress(Bss.addressOf(mouseStore) + (i * u64(8))).value;
}

/// Writes word [i].
@bare
void mouseSetState(u64 i, u64 v) {
  Pointer<u64>.fromAddress(Bss.addressOf(mouseStore) + (i * u64(8))).value = v;
}

/// Increments word [i]. A named operation because five different counters do
/// exactly this and a `+ 1` open-coded five times is five places to write the
/// wrong index.
@bare
void mouseBump(u64 i) {
  mouseSetState(i, mouseState(i) + u64(1));
}

/// The init-progress bitmap, for the harness and the `mouse` command.
@bare
u64 mouseInitFlags() {
  return mouseState(u64(mouseWordFlags));
}

/// Sets one bit of it.
@bare
void mouseFlag(u64 bit) {
  mouseSetState(u64(mouseWordFlags), mouseInitFlags() | bit);
}

/// Zeroes the block, and puts the packet size at its UNDETECTED default of 3.
///
/// Called from `kmain()` alongside `fbInit()` and `chanInit()`, for the
/// identical reason: nothing in this kernel zeroes `.bss`, and this block is
/// read by an interrupt handler. A garbage byte index would make the first
/// mouse byte of the boot land in a slot the decoder then treats as a complete
/// packet; a garbage packet size would make a three-byte device's stream be
/// read four bytes at a time, which desynchronises permanently on the first
/// packet.
///
/// **Prints nothing, and must keep printing nothing.**
/// `tests/conformance/m1-interrupts/run.sh` asserts the ENTIRE 544-byte serial
/// capture, so one line here would break a green milestone.
@bare
void mouseInit() {
  u64 i = u64(0);
  while (i < u64(mouseStoreWords)) {
    mouseSetState(i, u64(0));
    i = i + u64(1);
  }
  mouseSetState(u64(mouseWordSize), u64(mousePacketPlain));
}

// ---------------------------------------------------------------------------
// Talking to the controller. Every wait is bounded; every one reports whether
// it succeeded rather than returning void and hoping.
// ---------------------------------------------------------------------------

/// Waits until the controller's input buffer is EMPTY, so a byte written to
/// 0x60 or 0x64 will not overwrite one it has not read yet. Returns 1 on
/// success, 0 on timeout.
@bare
u64 mouseWaitInput() {
  u64 spins = u64(0);
  while (spins < u64(mouseSpinLimit)) {
    final u8 status = Port.inb(u16(kbdStatus));
    if ((status & u8(mouseStatusIbf)) < u8(1)) {
      return u64(1);
    }
    spins = spins + u64(1);
  }
  return u64(0);
}

/// Waits until the controller's output buffer is FULL, so there is a byte to
/// read at 0x60. Returns 1 on success, 0 on timeout.
///
/// Reading 0x60 with OBF clear returns whatever the last byte was, not nothing
/// -- which is why this is a separate wait rather than an optimistic read.
@bare
u64 mouseWaitOutput() {
  u64 spins = u64(0);
  while (spins < u64(mouseSpinLimit)) {
    final u8 status = Port.inb(u16(kbdStatus));
    if ((status & u8(mouseStatusObf)) > u8(0)) {
      return u64(1);
    }
    spins = spins + u64(1);
  }
  return u64(0);
}

/// Writes one COMMAND byte to the controller's command port (0x64).
@bare
u64 mouseCommand(u8 c) {
  if (mouseWaitInput() < u64(1)) {
    return u64(0);
  }
  Port.outb(u16(kbdStatus), c);
  return u64(1);
}

/// Reads one byte from the data port, or [mouseNoReply] if none arrived.
@bare
u64 mouseRead() {
  if (mouseWaitOutput() < u64(1)) {
    return u64(mouseNoReply);
  }
  return Port.inb(u16(kbdData)).toU64();
}

/// Sends one byte TO THE MOUSE and returns what the mouse answered.
///
/// **This is the 0xD4 prefix, and it is the whole reason the auxiliary port is
/// awkward.** Port 0x60 is the keyboard's data port; a byte written to it goes
/// to the KEYBOARD unless the controller has just been told, through its
/// command port, that the next one is for the auxiliary device. Every device
/// command below -- including each byte of a two-byte "set sample rate N" pair
/// -- needs its own prefix. Forgetting one does not fail: it sends a mouse
/// command to the keyboard, which is how a mouse driver silently reprograms
/// somebody else's device.
@bare
u64 mouseAuxWrite(u8 c) {
  if (mouseCommand(u8(mouseCmdToAux)) < u64(1)) {
    return u64(mouseNoReply);
  }
  if (mouseWaitInput() < u64(1)) {
    return u64(mouseNoReply);
  }
  Port.outb(u16(kbdData), c);
  return mouseRead();
}

/// Sends "set sample rate" and then the rate itself, and returns 1 only if BOTH
/// halves were acknowledged. The knock in [mouseEnable] is three of these and
/// is worthless if a half is silently dropped.
@bare
u64 mouseSetSampleRate(u8 rate) {
  if (mouseAuxWrite(u8(mouseDevSampleRate)) != u64(mouseReplyAck)) {
    return u64(0);
  }
  if (mouseAuxWrite(rate) != u64(mouseReplyAck)) {
    return u64(0);
  }
  return u64(1);
}

// ---------------------------------------------------------------------------
// The PIC, read-modify-write.
//
// ADR-0042 s3 and docs/design/display-protocol.md s4.4: until this milestone
// every PIC mask write in this kernel was a WHOLE BYTE, so every one of them
// re-masked every line it did not name. An IRQ12 unmasked at boot would have
// been re-masked by the next `ticks` command, silently, with no diagnostic --
// and the same was true of any future device.
//
// The fix is not a shadow copy in `.bss`. The 8259's mask register is
// READABLE: an `in` from the data port returns the current OCW1. So the mask
// is read from the chip, one bit is changed, and it is written back --
// which means no state to keep in sync, no ordering hazard with `.bss` not
// being zeroed, and no way for a shadow to drift from the hardware.
// ---------------------------------------------------------------------------

/// Clears one line's mask bit, leaving every other line as it was.
@bare
void picUnmaskLine(u64 irq) {
  if (irq < u64(8)) {
    final u8 mask = Port.inb(u16(picMasterData));
    Port.outb(u16(picMasterData), mask & (u8(0xFF) - (u8(1) << irq.toU8())));
    return;
  }
  final u8 mask = Port.inb(u16(picSlaveData));
  Port.outb(u16(picSlaveData), mask & (u8(0xFF) - (u8(1) << (irq - u64(8)).toU8())));
}

/// Sets one line's mask bit, leaving every other line as it was.
@bare
void picMaskLine(u64 irq) {
  if (irq < u64(8)) {
    final u8 mask = Port.inb(u16(picMasterData));
    Port.outb(u16(picMasterData), mask | (u8(1) << irq.toU8()));
    return;
  }
  final u8 mask = Port.inb(u16(picSlaveData));
  Port.outb(u16(picSlaveData), mask | (u8(1) << (irq - u64(8)).toU8()));
}

/// End-of-interrupt to the SLAVE PIC, then to the master.
///
/// **Both, in that order, and it is not a style choice.** An interrupt from the
/// slave reaches the CPU through the master's cascade input, so the master has
/// it in service too. Acknowledging only the master leaves the slave's
/// in-service bit set and IRQ12 never fires again; acknowledging only the slave
/// leaves the master's IRQ2 in service, which blocks every line below it --
/// including IRQ12 itself, and the keyboard's IRQ1 is ABOVE it and would
/// survive, which is exactly the sort of half-working that is hard to see.
@bare
void picEoiSlave() {
  Port.outb(u16(picSlaveCmd), u8(0x20));
  Port.outb(u16(picMasterCmd), u8(0x20));
}

// ---------------------------------------------------------------------------
// The packet decoder.
// ---------------------------------------------------------------------------

/// `MOUSE SYNC <byte:2> N <count:8>` -- a byte that CANNOT be a first byte was
/// discarded, and the stream stayed where it was.
@bare
void mouseReportSync(u8 b) {
  uartWrite(Rodata.addressOf(mouseStrSync), u64(11));
  uartPutHex(b.toU64(), u64(2));
  uartWrite(Rodata.addressOf(mouseStrN), u64(3));
  uartPutHex(mouseState(u64(mouseWordSyncs)), u64(8));
  uartNewline();
}

/// `MOUSE OVF <byte0:2> N <count:8>` -- a complete packet was thrown away
/// because the device said its own delta did not fit.
@bare
void mouseReportOvf(u64 b0) {
  uartWrite(Rodata.addressOf(mouseStrOvf), u64(10));
  uartPutHex(b0, u64(2));
  uartWrite(Rodata.addressOf(mouseStrN), u64(3));
  uartPutHex(mouseState(u64(mouseWordOverflows)), u64(8));
  uartNewline();
}

/// `MOUSE PKT <size:1> <b0:2> <b1:2> <b2:2> <b3:2> DX <9-bit:3> DY <9-bit:3> X <x:4> Y <y:4> B <buttons:1>`
///
/// Everything a reader needs to redo the decode by hand: the raw bytes as they
/// came off the wire, the two 9-bit deltas the driver read out of them, and the
/// position and buttons it derived. A harness can assert the deltas and the
/// position SEPARATELY, which is what makes "the sign extension is right" a
/// different claim from "the accumulator is right".
///
/// `b3` is `00` on a three-byte device, and the `size` field says which it was,
/// so the line's shape never changes between the two.
@bare
void mouseReportPacket() {
  uartWrite(Rodata.addressOf(mouseStrPkt), u64(10));
  uartPutHex(mouseState(u64(mouseWordSize)), u64(1));
  uartSpace();
  uartPutHex(mouseState(u64(mouseWordB0)), u64(2));
  uartSpace();
  uartPutHex(mouseState(u64(mouseWordB1)), u64(2));
  uartSpace();
  uartPutHex(mouseState(u64(mouseWordB2)), u64(2));
  uartSpace();
  uartPutHex(mouseState(u64(mouseWordB3)), u64(2));
  uartWrite(Rodata.addressOf(mouseStrDx), u64(4));
  uartPutHex(mouseState(u64(mouseWordDxRaw)), u64(3));
  uartWrite(Rodata.addressOf(mouseStrDy), u64(4));
  uartPutHex(mouseState(u64(mouseWordDyRaw)), u64(3));
  uartWrite(Rodata.addressOf(mouseStrX), u64(3));
  uartPutHex(mouseState(u64(mouseWordX)), u64(4));
  uartWrite(Rodata.addressOf(mouseStrY), u64(3));
  uartPutHex(mouseState(u64(mouseWordY)), u64(4));
  uartWrite(Rodata.addressOf(mouseStrB), u64(3));
  uartPutHex(mouseState(u64(mouseWordButtons)), u64(1));
  uartNewline();
}

/// Applies the 9-bit X delta in byte 1 to the accumulated position.
///
/// **THE SIGN BIT IS IN BYTE 0, NOT IN BYTE 1.** The delta is nine bits: byte 1
/// is the low eight and bit 4 of byte 0 is the ninth, and the whole thing is
/// two's complement. So a delta of -10 arrives as byte0 bit 4 SET and byte1
/// 0xF6 -- and a driver that sign-extended from byte 1's own high bit would get
/// -10 by luck here and +200 for a delta of +200 (0xC8, high bit set), which is
/// the pointer jumping two-thirds of the way across an 800-pixel screen. The
/// magnitude is computed as `256 - byte1` rather than by negating, because
/// every value in this language is unsigned and `0 - x` traps.
///
/// Clamped to the framebuffer, at both ends. A pointer is not allowed off the
/// screen, and with unsigned arithmetic "off the left edge" would otherwise be
/// a subtraction below zero, which traps and takes the interrupt handler with
/// it.
@bare
void mouseApplyX(u64 b0, u64 b1) {
  u64 x = mouseState(u64(mouseWordX));
  if ((b0 & u64(mousePktSignX)) > u64(0)) {
    final u64 magnitude = u64(mouseDeltaSpan) - b1;
    if (x < magnitude) {
      x = u64(0);
    } else {
      x = x - magnitude;
    }
    mouseSetState(u64(mouseWordX), x);
    return;
  }
  x = x + b1;
  if (x > u64(fbWidth - 1)) {
    x = u64(fbWidth - 1);
  }
  mouseSetState(u64(mouseWordX), x);
}

/// Applies the 9-bit Y delta in byte 2.
///
/// **THE AXIS IS INVERTED AND THAT IS THE PROTOCOL, NOT A CHOICE.** A PS/2
/// mouse reports Y positive when it is pushed AWAY from the user, and a
/// framebuffer's Y grows DOWNWARD. So a positive delta DECREASES the row, and
/// a negative one increases it. Getting this backwards gives a pointer that
/// works perfectly except that it goes the wrong way, which is the second
/// easiest thing to get wrong here after the sign extension.
@bare
void mouseApplyY(u64 b0, u64 b2) {
  u64 y = mouseState(u64(mouseWordY));
  if ((b0 & u64(mousePktSignY)) > u64(0)) {
    // Negative delta: the mouse moved TOWARD the user, so DOWN the screen.
    y = y + (u64(mouseDeltaSpan) - b2);
    if (y > u64(fbHeight - 1)) {
      y = u64(fbHeight - 1);
    }
    mouseSetState(u64(mouseWordY), y);
    return;
  }
  if (y < b2) {
    y = u64(0);
  } else {
    y = y - b2;
  }
  mouseSetState(u64(mouseWordY), y);
}

/// Accounts for the fourth byte of an IntelliMouse packet.
///
/// Only ever called when [mouseWordSize] is 4, which is only ever true when
/// 0xF2 answered 0x03. The Z field is an 8-bit two's-complement wheel delta;
/// its high bit set is a rotation AWAY from the user, which is what QEMU's
/// `wheel-up` button produces (it sends 0xFF). The two directions are counted
/// separately rather than summed into one signed accumulator, because an
/// unsigned accumulator cannot go below zero without trapping and a wheel is
/// perfectly entitled to be turned backwards first.
@bare
void mouseApplyWheel(u64 b3) {
  if (b3 < u64(1)) {
    return;
  }
  if ((b3 & u64(0x80)) > u64(0)) {
    mouseSetState(u64(mouseWordWheelUp),
        mouseState(u64(mouseWordWheelUp)) + (u64(mouseDeltaSpan) - b3));
    return;
  }
  mouseSetState(u64(mouseWordWheelDown),
      mouseState(u64(mouseWordWheelDown)) + b3);
}

/// A whole packet has arrived. Decode it, or throw it away if the device says
/// it overflowed.
///
/// **An overflowed packet is DISCARDED, not clamped.** Bits 6 and 7 of byte 0
/// mean the movement since the last report did not fit in nine bits; the byte
/// that arrived is therefore not the delta, it is the low eight bits of
/// something larger, and there is no way to recover what. Using it would move
/// the pointer by a number the hardware never reported. The packet is counted
/// so the discard is visible rather than silent.
@bare
void mouseComplete() {
  final u64 b0 = mouseState(u64(mouseWordB0));
  if ((b0 & u64(mousePktOverflow)) > u64(0)) {
    mouseBump(u64(mouseWordOverflows));
    mouseReportOvf(b0);
    return;
  }
  final u64 b1 = mouseState(u64(mouseWordB1));
  final u64 b2 = mouseState(u64(mouseWordB2));
  // The raw 9-bit deltas, kept EXACTLY as the wire carried them, so the report
  // shows what was decoded from rather than only what was decoded to.
  mouseSetState(u64(mouseWordDxRaw),
      b1 | (((b0 & u64(mousePktSignX)) >> u64(4)) << u64(8)));
  mouseSetState(u64(mouseWordDyRaw),
      b2 | (((b0 & u64(mousePktSignY)) >> u64(5)) << u64(8)));
  mouseApplyX(b0, b1);
  mouseApplyY(b0, b2);
  mouseSetState(u64(mouseWordButtons), b0 & u64(mousePktButtons));
  if (mouseState(u64(mouseWordSize)) > u64(mousePacketPlain)) {
    mouseApplyWheel(mouseState(u64(mouseWordB3)));
  }
  mouseBump(u64(mouseWordPackets));
  mouseReportPacket();
}

/// One byte of the mouse's byte stream, wherever it came from.
///
/// **THE FRAMING RULE, AND THE RESYNCHRONISATION IT BUYS.** A PS/2 packet has
/// no length field, no terminator and no checksum. The only structure the
/// protocol gives is that BIT 3 OF BYTE 0 IS ALWAYS ONE. So: when this decoder
/// is expecting a first byte and receives one with bit 3 clear, that byte
/// cannot be a first byte, the stream is offset, and the ONLY safe move is to
/// discard the byte and stay where it is -- because the next byte might be a
/// real first byte, and consuming this one as though it were would keep the
/// offset forever.
///
/// Discarding one byte at a time realigns a stream offset by one within one
/// packet and a stream offset by two within two, which is every offset a
/// three-byte packet can have. It is not infallible and this file does not
/// claim it is: a byte 1 or byte 2 whose value happens to have bit 3 set is
/// accepted as a first byte and produces ONE wrong packet before the next
/// misaligned byte fails the test. That is the protocol's own limit -- there is
/// no more information on the wire to use -- and `d1-mouse`'s harness asserts
/// exactly that sequence: one wrong packet, then a resynchronisation, then
/// correct packets forever after.
///
/// Every discard is COUNTED and PRINTED, so a stream that is quietly
/// resynchronising forty times a second is visible rather than merely
/// producing a pointer that stutters.
///
/// This is also the seam the `mouse feed` command writes into, which is how the
/// harness can present a deliberately misaligned stream to the decoder without
/// a device that can be asked to produce one.
@bare
void mouseByte(u8 b) {
  final u64 index = mouseState(u64(mouseWordIdx));
  if (index < u64(1)) {
    if ((b & u8(mousePktAlwaysOne)) < u8(1)) {
      mouseBump(u64(mouseWordSyncs));
      mouseReportSync(b);
      return; // deliberately NOT advancing: the stream stays where it is
    }
    mouseSetState(u64(mouseWordB0), b.toU64());
    mouseSetState(u64(mouseWordIdx), u64(1));
    return;
  }
  if (index < u64(2)) {
    mouseSetState(u64(mouseWordB1), b.toU64());
    mouseSetState(u64(mouseWordIdx), u64(2));
    return;
  }
  if (index < u64(3)) {
    mouseSetState(u64(mouseWordB2), b.toU64());
    if (mouseState(u64(mouseWordSize)) > u64(mousePacketPlain)) {
      mouseSetState(u64(mouseWordIdx), u64(3));
      return;
    }
    mouseSetState(u64(mouseWordB3), u64(0));
    mouseSetState(u64(mouseWordIdx), u64(0));
    mouseComplete();
    return;
  }
  mouseSetState(u64(mouseWordB3), b.toU64());
  mouseSetState(u64(mouseWordIdx), u64(0));
  mouseComplete();
}

/// Handles one IRQ12.
///
/// **The status register is read BEFORE the data register**, because bit 5 --
/// the only thing that says this byte came from the mouse rather than the
/// keyboard -- describes the byte that is waiting, and reading the data port
/// consumes it. Reading them the other way round asks a question about a byte
/// that is already gone.
///
/// A byte that is waiting but is NOT auxiliary data is a keyboard byte
/// delivered on the wrong line. It is read anyway -- leaving it would stop the
/// 8042 raising any further interrupt AT ALL, keyboard included -- and counted
/// as a stray rather than fed to either decoder, because feeding a scancode to
/// the packet state machine is how a keystroke becomes pointer motion.
///
/// If OBF is clear there is nothing to read and nothing is read: a spurious
/// interrupt with an empty buffer is real, and an unconditional `in` would
/// return the previous byte a second time and decode it twice.
@bare
void mouseHandle() {
  mouseBump(u64(mouseWordIrqs));
  final u8 status = Port.inb(u16(kbdStatus));
  if ((status & u8(mouseStatusObf)) < u8(1)) {
    return; // spurious: nothing in the buffer
  }
  final u8 b = Port.inb(u16(kbdData));
  if ((status & u8(mouseStatusAux)) < u8(1)) {
    mouseBump(u64(mouseWordStrays));
    return;
  }
  mouseByte(b);
}

// ---------------------------------------------------------------------------
// Bringing the device up.
// ---------------------------------------------------------------------------

/// Asks the device what it is, through 0xF2, and returns the answer.
///
/// Two replies, not one: the ACK, and then the identity byte. Reading only the
/// first is how a driver decides a mouse has a wheel because 0xFA happened not
/// to be 0x03.
@bare
u64 mouseDeviceId() {
  if (mouseAuxWrite(u8(mouseDevGetId)) != u64(mouseReplyAck)) {
    return u64(mouseNoReply);
  }
  return mouseRead();
}

/// Runs the IntelliMouse knock and returns the identity the device answers with
/// AFTERWARDS.
///
/// **This is a DETECTION, and the detection is the point.** The knock is three
/// "set sample rate" commands with three specific values; a plain PS/2 mouse
/// accepts all three and stays a plain PS/2 mouse, and an IntelliMouse takes
/// them as a secret handshake and switches to a four-byte packet with a Z axis.
/// There is no way to tell which happened except to ASK -- so this asks, and
/// the caller believes the answer rather than the knock.
///
/// If any half of any of the three rates goes unacknowledged the knock is
/// abandoned and the identity is read anyway, because a device that stopped
/// answering mid-knock is exactly the device whose packet size must NOT be
/// assumed to have changed.
@bare
u64 mouseKnockForWheel() {
  if (mouseSetSampleRate(u8(mouseKnock1)) < u64(1)) {
    return mouseDeviceId();
  }
  if (mouseSetSampleRate(u8(mouseKnock2)) < u64(1)) {
    return mouseDeviceId();
  }
  if (mouseSetSampleRate(u8(mouseKnock3)) < u64(1)) {
    return mouseDeviceId();
  }
  return mouseDeviceId();
}

/// Brings the auxiliary device up and unmasks its interrupt.
///
/// Returns nothing: what it achieved is in [mouseWordFlags], which is where the
/// `mouse` command and `d1-mouse`'s harness both read it from, and a return
/// value would be a second copy of the same fact for `m2Enter()` to ignore.
///
/// **Prints nothing on any path, including every failure path**, for
/// `mouseInit`'s reason: it is called from `m2Enter()`, which runs after
/// `M1 END`, and `tests/conformance/m1-interrupts/run.sh` asserts the entire
/// 544-byte serial capture. What happened is recorded in the flags word and
/// reported by the `mouse` command, from a prompt, exactly as `pmmInit`'s work
/// is reported by `frames` and `vmInit`'s by `vm`.
///
/// **THE ORDER OF THE LAST TWO STEPS IS LOAD-BEARING.** Reporting is enabled
/// (0xF4) BEFORE the interrupt is unmasked, not after. The other order leaves a
/// window in which IRQ12 is live and the device is silent, which is harmless;
/// this order leaves a window in which the device has queued a byte and the
/// interrupt is masked, which is ALSO harmless, because the 8259 latches the
/// edge while masked and delivers it when the mask is lifted. What is NOT
/// harmless is either of them combined with leaving a byte unread: the 8042's
/// output buffer is one byte deep and SHARED WITH THE KEYBOARD, so a mouse byte
/// nobody reads stops keystrokes as well as pointer motion. Every reply this
/// sequence provokes is read, including the ones it does not use.
@bare
void mouseEnable() {
  // 1. The auxiliary port itself. Disabled at power-on; nothing else works
  //    until this is sent.
  if (mouseCommand(u8(mouseCmdEnableAux)) > u64(0)) {
    mouseFlag(u64(mouseFlagAuxPort));
  }

  // 2. The configuration byte, READ before it is written. keyboard.dart has
  //    never written this register at all and its header explains why; this
  //    file has to, and does it as a read-modify-write of exactly two bits so
  //    that the keyboard's own interrupt enable (bit 0) and translation
  //    (bit 6) come back unchanged.
  // The read is attempted only if the controller took the command. Asking for
  // the configuration byte and then reading 0x60 regardless would read whatever
  // was last in the buffer and modify THAT, which is a write of an invented
  // configuration to a controller the keyboard is also on.
  if (mouseCommand(u8(mouseCmdReadCfg)) > u64(0)) {
    final u64 cfg = mouseRead();
    if (cfg != u64(mouseNoReply)) {
      mouseFlag(u64(mouseFlagCfgRead));
      final u64 wanted =
          (cfg | u64(mouseCfgAuxIrq)) & u64(mouseCfgAuxClockKeep);
      if (mouseCommand(u8(mouseCmdWriteCfg)) > u64(0)) {
        if (mouseWaitInput() > u64(0)) {
          Port.outb(u16(kbdData), wanted.toU8());
          mouseFlag(u64(mouseFlagCfgWrite));
        }
      }
    }
  }

  // 3. Reset the device, so what follows starts from a state this kernel chose
  //    rather than from whatever the firmware left. Three bytes come back: the
  //    ACK, the self-test result, and the post-reset identity. All three are
  //    read; the third is discarded because the identity that matters is the
  //    one AFTER the knock.
  if (mouseAuxWrite(u8(mouseDevReset)) == u64(mouseReplyAck)) {
    mouseFlag(u64(mouseFlagReset));
    if (mouseRead() == u64(mouseReplyBat)) {
      mouseFlag(u64(mouseFlagBat));
    }
    // The post-reset device id. Read because it MUST be -- the 8042's output
    // buffer is one byte deep and SHARED WITH THE KEYBOARD, so a reply nobody
    // consumes stops keystrokes as well as packets. Its VALUE is deliberately
    // not used (the identity that matters is the one after the knock), so what
    // is recorded is that it arrived at all, which is the part that says the
    // conversation is still in step.
    if (mouseRead() != u64(mouseNoReply)) {
      mouseFlag(u64(mouseFlagPostReset));
    }
  }

  // 4. Known defaults: 100 samples/second, resolution 4 counts/mm, scaling 1:1,
  //    reporting off. `mouse` reports what the device says, and this is what
  //    makes that report the same on two machines.
  if (mouseAuxWrite(u8(mouseDevDefaults)) == u64(mouseReplyAck)) {
    mouseFlag(u64(mouseFlagDefaults));
  }

  // 5. The wheel. DETECTED, never assumed -- see [mouseKnockForWheel].
  final u64 id = mouseKnockForWheel();
  mouseSetState(u64(mouseWordId), id);
  if (id != u64(mouseNoReply)) {
    mouseFlag(u64(mouseFlagId));
    if (id == u64(mouseIdWheel)) {
      mouseSetState(u64(mouseWordSize), u64(mousePacketWheel));
      mouseFlag(u64(mouseFlagWheel));
    }
  }

  // 6. Start reporting.
  if (mouseAuxWrite(u8(mouseDevEnable)) == u64(mouseReplyAck)) {
    mouseFlag(u64(mouseFlagReporting));
  }

  // 7. The slave PIC, for the first time in this kernel's life. BOTH lines: the
  //    device's own, and the cascade the slave reaches the CPU through.
  picUnmaskLine(u64(irqCascadeLine));
  picUnmaskLine(u64(irqMouseLine));
  mouseFlag(u64(mouseFlagUnmasked));
}

// ---------------------------------------------------------------------------
// The cursor.
//
// A 12x16 arrow in two `@rodata` bitmaps, one for the black outline and one for
// the white interior, sixteen rows of sixteen bits each stored high byte first.
// Two bitmaps rather than one because an arrow with no outline is invisible
// over light content and a solid black arrow is invisible over dark content;
// with both, exactly one of the two colours always contrasts.
//
// **IT IS DRAWN BY THE `mouse` COMMAND, NOT BY THE INTERRUPT HANDLER, AND THAT
// IS A DELIBERATE LIMIT RATHER THAN AN OVERSIGHT.** Drawing from IRQ12 needs
// the previous position's pixels restored before the new ones are written, and
// this kernel has nowhere to save them: there is no allocation in an interrupt
// handler (the compiler forbids it and this file does not work around it) and a
// fixed save buffer would be 192 more words of `.bss` for a feature no
// compositor will want, because a compositor composites rather than blitting a
// cursor over a console. So the handler updates NUMBERS and the command draws
// PIXELS. docs/known-gaps.md GAP-0251 records the cost: the pointer does not
// track live, and each `mouse` leaves an arrow behind at the last position.
// ---------------------------------------------------------------------------

/// The arrow's outline. Sixteen rows, two bytes each, high byte first, bit 15
/// of the pair being the leftmost pixel.
@rodata
final List<u8> mouseCursorEdge = const [
  u8(0x80), u8(0x00), u8(0xC0), u8(0x00), u8(0xA0), u8(0x00), u8(0x90), u8(0x00),
  u8(0x88), u8(0x00), u8(0x84), u8(0x00), u8(0x82), u8(0x00), u8(0x81), u8(0x00),
  u8(0x80), u8(0x80), u8(0x80), u8(0x40), u8(0x83), u8(0xE0), u8(0x92), u8(0x00),
  u8(0xA9), u8(0x00), u8(0xC9), u8(0x00), u8(0x84), u8(0x80), u8(0x03), u8(0x80),
];

/// The arrow's interior, same shape.
@rodata
final List<u8> mouseCursorFill = const [
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x40), u8(0x00), u8(0x60), u8(0x00),
  u8(0x70), u8(0x00), u8(0x78), u8(0x00), u8(0x7C), u8(0x00), u8(0x7E), u8(0x00),
  u8(0x7F), u8(0x00), u8(0x7F), u8(0x80), u8(0x7C), u8(0x00), u8(0x6C), u8(0x00),
  u8(0x46), u8(0x00), u8(0x06), u8(0x00), u8(0x03), u8(0x00), u8(0x00), u8(0x00),
];

/// Rows and columns in the cursor bitmaps.
const int mouseCursorRows = 16;
const int mouseCursorCols = 12;

/// The outline is black and the interior is white, both opaque.
const int mouseCursorEdgeColor = 0x00000000;
const int mouseCursorFillColor = 0x00FFFFFF;

/// The row `MOUSE DRAW`'s `ROW8` field points at.
///
/// Row 8 of the bitmap is `edge, seven fill, edge` followed by three untouched
/// pixels, which is the widest unambiguous run in the whole glyph -- so a
/// twelve-dword dump at that address is a strong statement about WHERE the
/// cursor is and WHAT was drawn, in one read. `d1-mouse`'s harness asserts all
/// twelve values.
const int mouseCursorProbeRow = 8;

/// Reads row [row] of a cursor bitmap as a 16-bit word.
@bare
u64 mouseCursorRow(u64 table, u64 row) {
  final u64 hi = Pointer<u8>.fromAddress(table + (row * u64(2))).value.toU64();
  final u64 lo = Pointer<u8>.fromAddress(table + (row * u64(2)) + u64(1)).value.toU64();
  return (hi << u64(8)) | lo;
}

/// Blits one row of one bitmap in one colour, clipped to the visible area.
@bare
void mouseBlitRow(u64 table, u64 row, u64 x, u64 y, u64 color) {
  if (y + row > u64(fbHeight - 1)) {
    return;
  }
  final u64 bits = mouseCursorRow(table, row);
  u64 col = u64(0);
  while (col < u64(mouseCursorCols)) {
    if (x + col < u64(fbWidth)) {
      if ((bits & (u64(1) << (u64(15) - col))) > u64(0)) {
        fbPutPixel(x + col, y + row, color);
      }
    }
    col = col + u64(1);
  }
}

/// Draws the arrow at ([x], [y]).
///
/// The outline goes down first and the interior over it, so a one-pixel
/// diagonal edge is not erased by the fill that follows it.
@bare
void mouseDrawCursor(u64 x, u64 y) {
  u64 row = u64(0);
  while (row < u64(mouseCursorRows)) {
    mouseBlitRow(Rodata.addressOf(mouseCursorEdge), row, x, y,
        u64(mouseCursorEdgeColor));
    row = row + u64(1);
  }
  row = u64(0);
  while (row < u64(mouseCursorRows)) {
    mouseBlitRow(Rodata.addressOf(mouseCursorFill), row, x, y,
        u64(mouseCursorFillColor));
    row = row + u64(1);
  }
}

// ---------------------------------------------------------------------------
// The `mouse` command.
// ---------------------------------------------------------------------------

/// `MOUSE STATE X <4> Y <4> B <1> PKT <8> SYNC <8> OVF <8> IRQ <8> STRAY <8>
///  SIZE <1> ID <2> WU <4> WD <4> INIT <4>`
///
/// Every number the driver has. `SIZE` and `ID` are printed TOGETHER on purpose:
/// `SIZE 4` is a conclusion and `ID 03` is the evidence for it, and a report
/// that gave only the conclusion would be indistinguishable from one that had
/// assumed it.
///
/// `INIT` is the bitmap [mouseEnable] built, so a mouse that is not working
/// says which step it stopped at instead of merely saying nothing.
@bare
void mouseReportState() {
  uartWrite(Rodata.addressOf(mouseStrState), u64(11));
  uartWrite(Rodata.addressOf(mouseStrX), u64(3));
  uartPutHex(mouseState(u64(mouseWordX)), u64(4));
  uartWrite(Rodata.addressOf(mouseStrY), u64(3));
  uartPutHex(mouseState(u64(mouseWordY)), u64(4));
  uartWrite(Rodata.addressOf(mouseStrB), u64(3));
  uartPutHex(mouseState(u64(mouseWordButtons)), u64(1));
  uartWrite(Rodata.addressOf(mouseStrPktN), u64(5));
  uartPutHex(mouseState(u64(mouseWordPackets)), u64(8));
  uartWrite(Rodata.addressOf(mouseStrSyncN), u64(6));
  uartPutHex(mouseState(u64(mouseWordSyncs)), u64(8));
  uartWrite(Rodata.addressOf(mouseStrOvfN), u64(5));
  uartPutHex(mouseState(u64(mouseWordOverflows)), u64(8));
  uartWrite(Rodata.addressOf(mouseStrIrq), u64(5));
  uartPutHex(mouseState(u64(mouseWordIrqs)), u64(8));
  uartWrite(Rodata.addressOf(mouseStrStray), u64(7));
  uartPutHex(mouseState(u64(mouseWordStrays)), u64(8));
  uartWrite(Rodata.addressOf(mouseStrSize), u64(6));
  uartPutHex(mouseState(u64(mouseWordSize)), u64(1));
  uartWrite(Rodata.addressOf(mouseStrId), u64(4));
  // THREE digits, not two, and the third one is the whole point. [mouseRead]
  // answers [mouseNoReply] = 0x100 when the controller did not reply, and that
  // is what is stored here when the device never said what it was. Printed in
  // two digits it comes out `00` -- indistinguishable from a plain PS/2 mouse
  // that answered 0x00 -- so a machine with no mouse at all would report
  // `SIZE 3 ID 00`, which is a claim about a device rather than an admission
  // that none answered. `ID 100` says the second thing.
  uartPutHex(mouseState(u64(mouseWordId)), u64(3));
  uartWrite(Rodata.addressOf(mouseStrWu), u64(4));
  uartPutHex(mouseState(u64(mouseWordWheelUp)), u64(4));
  uartWrite(Rodata.addressOf(mouseStrWd), u64(4));
  uartPutHex(mouseState(u64(mouseWordWheelDown)), u64(4));
  uartWrite(Rodata.addressOf(mouseStrInit), u64(6));
  uartPutHex(mouseInitFlags(), u64(4));
  uartNewline();
}

/// Draws the arrow at the accumulated position and reports where it went.
///
/// `MOUSE DRAW X <4> Y <4> BASE <8> PITCH <8> ROW8 <16>`, or `MOUSE NOFB` when
/// no graphics mode has been set.
///
/// **`ROW8` IS THE ADDRESS OF A SCANLINE AND IT IS THERE FOR THE HARNESS.**
/// `m5-pci` established that pixels drawn by this kernel are asserted by reading
/// them back out of guest physical memory at an address the KERNEL reported,
/// never one the harness assumed -- because the framebuffer's base is a fact
/// about SeaBIOS's BAR allocator. The same rule applies with one more variable
/// here, since where the cursor is is the whole thing under test. So the kernel
/// prints the address of row [mouseCursorProbeRow] of the arrow it just drew,
/// and the harness dumps twelve pixels there. If the driver decoded a different
/// position, this address is different and the twelve pixels are background.
@bare
void mouseDrawAndReport() {
  final u64 base = fbState(u64(fbStateBase));
  if (base < u64(1)) {
    uartWrite(Rodata.addressOf(mouseStrNoFb), u64(11));
    return;
  }
  final u64 x = mouseState(u64(mouseWordX));
  final u64 y = mouseState(u64(mouseWordY));
  mouseDrawCursor(x, y);
  uartWrite(Rodata.addressOf(mouseStrDraw), u64(10));
  uartWrite(Rodata.addressOf(mouseStrX), u64(3));
  uartPutHex(x, u64(4));
  uartWrite(Rodata.addressOf(mouseStrY), u64(3));
  uartPutHex(y, u64(4));
  uartWrite(Rodata.addressOf(mouseStrBase), u64(6));
  uartPutHex(base, u64(8));
  uartWrite(Rodata.addressOf(mouseStrPitch), u64(7));
  uartPutHex(fbState(u64(fbStatePitch)), u64(8));
  uartWrite(Rodata.addressOf(mouseStrRow8), u64(6));
  uartPutHex(fbPixelAddr(x, y + u64(mouseCursorProbeRow)), u64(16));
  uartNewline();
}

/// `mouse` -- report the pointer, and draw it if there is anywhere to draw it.
@bare
void shellMouse() {
  mouseReportState();
  mouseDrawAndReport();
}

/// `mouse feed <hex>` -- push bytes straight into [mouseByte].
///
/// **THIS IS A TEST SEAM AND IT IS LABELLED AS ONE.** The framing rule in
/// [mouseByte] only does anything when the stream is misaligned, and there is no
/// way to ask a PS/2 mouse to misalign its own stream -- QEMU's `input-send-event`
/// injects MOTION, and motion produces well-formed packets. So the decoder gets
/// its own entrance, and `d1-mouse`'s harness uses it two ways:
///
///   * a fully synthetic misaligned stream, which proves the rule in isolation;
///   * ONE byte, injected before a REAL motion event, which leaves the state
///     machine expecting a second byte when the device's next genuine packet
///     arrives -- so the resynchronisation that follows is of the real device's
///     real bytes, which is a claim the synthetic case cannot make.
///
/// What it does NOT do is bypass anything: it calls exactly the function IRQ12
/// calls, with exactly the same state, so a decoder that only worked when fed
/// by hand would still be the decoder the interrupt uses.
///
/// Non-hex bytes in the argument are skipped, so `08 F6 00` and `08F600` are the
/// same input. An odd number of digits leaves the last nibble unused rather than
/// inventing a byte from it.
@bare
void shellMouseFeed() {
  final u64 len = shellLen();
  u64 i = u64(11);
  u64 pending = u64(0x100); // 0x100: no high nibble collected yet
  u64 fed = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        mouseByte(((pending << u64(4)) | d).toU8());
        fed = fed + u64(1);
        pending = u64(0x100);
      }
    }
    i = i + u64(1);
  }
  uartWrite(Rodata.addressOf(mouseStrFeed), u64(11));
  uartPutHex(fed, u64(2));
  uartNewline();
}

/// `mouse` with an argument this command does not know.
@bare
void shellMouseUsage() {
  uartWrite(Rodata.addressOf(mouseStrUsage), u64(39));
}

// ---------------------------------------------------------------------------
// Ring 3.
// ---------------------------------------------------------------------------

/// Syscall 16 -- `mouse`. See docs/syscall-registry.md.
const int mouseSysNo = 16;

/// Packs the pointer into the one `u64` a syscall can return.
///
/// | bits | field |
/// |---|---|
/// | 0-15 | X, in pixels |
/// | 16-31 | Y, in pixels |
/// | 32-39 | the three button bits |
/// | 40-63 | the packet counter, low 24 bits |
///
/// **The packet counter is in there so that "nothing has moved" and "the mouse
/// is not working" are different values to a ring-3 program.** A position of
/// (0, 0) with no buttons is a legitimate state and is also exactly what a
/// caller would see from a kernel that had never decoded a packet at all; the
/// counter distinguishes them, and lets a program poll for a CHANGE without
/// having to guess whether one happened.
///
/// One register rather than a pointer to a struct, deliberately: a struct means
/// validating a ring-3 address, and `chan.dart`'s refusal list is the evidence
/// for how much work that honestly is. Sixteen bits is enough for a coordinate
/// on a screen this kernel can actually set (800x600 -- `fbWidth`/`fbHeight`),
/// and when that stops being true this becomes a real read into a real buffer
/// and gets its own ADR. GAP-0252.
@bare
u64 mousePacked() {
  return (mouseState(u64(mouseWordX)) & u64(0xFFFF)) |
      ((mouseState(u64(mouseWordY)) & u64(0xFFFF)) << u64(16)) |
      ((mouseState(u64(mouseWordButtons)) & u64(0xFF)) << u64(32)) |
      ((mouseState(u64(mouseWordPackets)) & u64(0xFFFFFF)) << u64(40));
}

/// The syscall body: one read, no arguments, no failure mode.
///
/// **It requires no process slot and refuses nobody**, which puts it with
/// `who` rather than with `yield` and `sbrk`. The reason is not laziness: it
/// reads GLOBAL device state and writes nothing, so there is no per-caller
/// resource to look up and nothing a caller could corrupt. Every other syscall
/// that refuses a caller does so because it would otherwise have to invent an
/// owner -- a heap, a descriptor table, an endpoint -- and this one has no
/// owner to invent.
///
/// What that costs is stated rather than hidden: EVERY ring-3 program can see
/// the pointer, including one that should not. There is no notion of input
/// focus in this kernel and this syscall is not the place to invent one --
/// `docs/design/display-protocol.md` s4.3 is, and it says the routing decision
/// belongs to a compositor. GAP-0253.
@bare
void mouseSysRead(u64 frame) {
  userSetFrame(frame, u64(userFrameRax), mousePacked());
}
