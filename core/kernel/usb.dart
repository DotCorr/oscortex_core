// core/kernel/usb.dart
//
// oscortex_core USB0 + USB1 + USB2: find an xHCI controller on PCI, read
// its capability and operational registers through BAR0 MMIO, and turn
// one HID boot-protocol keyboard report into a set-1 scancode on kbdq.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// The design is docs/design/usb-hid.md. The MMIO read is ADR-0068.
// The HID→set-1 enqueue is ADR-0073.
//
// ---------------------------------------------------------------------------
// ZERO DONATED BSS. THAT IS THE WHOLE OF THE MERGE RULE.
// ---------------------------------------------------------------------------
// `part 'usb.dart'` sits AFTER `part 'nic.dart'` and BEFORE
// `part 'wmevent.dart'`. D7 owns last place: `wmeventStore` is the newest
// bss block, and stealing that slot would move every harness that
// measures D7 to the end of .bss. USB0 and USB1 print from locals.
// USB2's modifier-shadow lives in `usbFeed`'s locals across reports in
// ONE command -- there is no transfer ring yet, so there is no live
// previous-report word to keep. A `@bss` here would sit between
// kbdqStore and wmeventStore and break d2-input's abutment. D7 stays
// last.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE DOES, AND WHAT IT DOES NOT
// ---------------------------------------------------------------------------
// USB0 walks bus 0 for class 0C/03/30 (serial-bus / USB / xHCI prog-IF)
// and prints the function it found. UHCI (prog-IF 00), OHCI (10) and
// EHCI (20) are not this device -- a class-only match would claim
// `-M pc,usb=on`'s PIIX3 UHCI as xHCI, which is the lie USB0 exists
// to refuse.
//
// USB1 reads BAR0 as a 64-bit pair (qemu-xhci is a 64-bit MMIO BAR),
// refuses a non-zero upper dword (the identity map stops at 4 GiB),
// and loads CAPLENGTH, HCIVERSION, HCSPARAMS1, DBOFF, RTSOFF, USBCMD
// and USBSTS through Volatile MMIO. It does not write configuration
// space, does not set Run/Stop, does not reset, and does not talk to
// a usb-kbd.
//
// USB2 is the upper half: HID usage → set-1, then [kbdqPush]. The
// transfer ring is USB3. Until that exists the `usb feed` seam (same
// shape as `mouse feed`, labelled as one) is the producer. Attaching
// `-device usb-kbd` would steal QEMU send-key from the 8042
// (usb-hid.md §1); the harness therefore injects through COM1, not
// through a USB keyboard device.
//
// ---------------------------------------------------------------------------
// WHY THE PRINT IS A COMMAND, NOT A BOOT LINE
// ---------------------------------------------------------------------------
// QEMU's default machine has no USB controller (peripherals.md §0.1).
// A boot-time line would be `USB NONE` on every session golden after
// `M1 END`. The print is therefore [usbReport], reached from the `usb`
// command, which is not in `help` (the same reason `nic` and `virtgpu`
// are not: GAP-0105 / GAP-0115). [usbInit] is called from `kmain` and
// prints nothing, so `m1-interrupts`' 544-byte golden is untouched.

part of 'kmain.dart';

/// PCI class 0x0C subclass 0x03 is a USB host controller. Prog-IF 0x30
/// is xHCI (USB 3). The other prog-IFs are UHCI (0x00), OHCI (0x10),
/// EHCI (0x20). USB0 matches the triple, not the class alone.
const int usbClassSerial = 0x0C;
const int usbSubclassUsb = 0x03;
const int usbProgIfXhci = 0x30;

/// Command-register bit 1: memory decode. USB1 loads BAR0 MMIO, so
/// this bit must be set. Bit 2 (bus-master) is a DMA fact and is not
/// required to read a register. USB1 does not write 0xCFC.
const int usbCmdMem = 0x02;

/// Capability-register offsets from BAR0. CAPLENGTH / HCIVERSION share
/// the dword at 0. Operational registers sit at BAR0 + CAPLENGTH.
const int usbCapHcsparams1 = 0x04;
const int usbCapDboff = 0x14;
const int usbCapRtsoff = 0x18;
const int usbOpUsbcmd = 0x00;
const int usbOpUsbsts = 0x04;

/// Hidden command name. Not in `help` (goldens contain shellStrHelp).
///
/// `"usb"` -- 3 bytes.
@rodata
final List<u8> usbStrCmd = const [
  u8(0x75), u8(0x73), u8(0x62),
];

/// Found-device line prefix.
///
/// `"USB XHCI "` -- 9 bytes.
@rodata
final List<u8> usbStrXhci = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x58), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
];

/// Absent-device line. The negative control greps this and forbids any
/// `USB XHCI` line on the same boot.
///
/// `"USB NONE\n"` -- 9 bytes.
@rodata
final List<u8> usbStrNone = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// Memory-decode is clear. USB1 cannot load BAR0.
///
/// `"USB NOCMD\n"` -- 10 bytes.
@rodata
final List<u8> usbStrNocmd = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x43), u8(0x4D), u8(0x44), u8(0x0A),
];

/// BAR0 is I/O, unimplemented, or above 4 GiB.
///
/// `"USB NOBAR\n"` -- 10 bytes.
@rodata
final List<u8> usbStrNobar = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x42), u8(0x41), u8(0x52), u8(0x0A),
];

/// `"USB BAR "` -- 8 bytes.
@rodata
final List<u8> usbStrBar = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x42), u8(0x41), u8(0x52), u8(0x20),
];

/// `" CAPLENGTH "` -- 11 bytes.
@rodata
final List<u8> usbStrCaplength = const [
  u8(0x20), u8(0x43), u8(0x41), u8(0x50),
  u8(0x4C), u8(0x45), u8(0x4E), u8(0x47),
  u8(0x54), u8(0x48), u8(0x20),
];

/// `" HCIVERSION "` -- 12 bytes.
@rodata
final List<u8> usbStrHciver = const [
  u8(0x20), u8(0x48), u8(0x43), u8(0x49),
  u8(0x56), u8(0x45), u8(0x52), u8(0x53),
  u8(0x49), u8(0x4F), u8(0x4E), u8(0x20),
];

/// `" SLOTS "` -- 7 bytes.
@rodata
final List<u8> usbStrSlots = const [
  u8(0x20), u8(0x53), u8(0x4C), u8(0x4F),
  u8(0x54), u8(0x53), u8(0x20),
];

/// `" INTRS "` -- 7 bytes.
@rodata
final List<u8> usbStrIntrs = const [
  u8(0x20), u8(0x49), u8(0x4E), u8(0x54),
  u8(0x52), u8(0x53), u8(0x20),
];

/// `" PORTS "` -- 7 bytes.
@rodata
final List<u8> usbStrPorts = const [
  u8(0x20), u8(0x50), u8(0x4F), u8(0x52),
  u8(0x54), u8(0x53), u8(0x20),
];

/// `"USB DBOFF "` -- 10 bytes.
@rodata
final List<u8> usbStrDboff = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x44), u8(0x42), u8(0x4F), u8(0x46),
  u8(0x46), u8(0x20),
];

/// `" RTSOFF "` -- 8 bytes.
@rodata
final List<u8> usbStrRtsoff = const [
  u8(0x20), u8(0x52), u8(0x54), u8(0x53),
  u8(0x4F), u8(0x46), u8(0x46), u8(0x20),
];

/// `" USBCMD "` -- 8 bytes.
@rodata
final List<u8> usbStrUsbcmd = const [
  u8(0x20), u8(0x55), u8(0x53), u8(0x42),
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
];

/// `" USBSTS "` -- 8 bytes.
@rodata
final List<u8> usbStrUsbsts = const [
  u8(0x20), u8(0x55), u8(0x53), u8(0x42),
  u8(0x53), u8(0x54), u8(0x53), u8(0x20),
];

/// `"usb mfeed "` -- 10 bytes. Matched before `usb feed ` so the
/// mouse seam cannot fall through as an unknown feed argument.
@rodata
final List<u8> usbStrCmdMfeed = const [
  u8(0x75), u8(0x73), u8(0x62), u8(0x20),
  u8(0x6D), u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20),
];

/// `"usb feed "` -- 9 bytes. Matched before the bare `usb` exact
/// match so the feed argument cannot fall through as unknown.
@rodata
final List<u8> usbStrCmdFeed = const [
  u8(0x75), u8(0x73), u8(0x62), u8(0x20),
  u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20),
];

/// `"USB FEED"` -- 8 bytes. The seam's own label, same as `MOUSE FEED`.
@rodata
final List<u8> usbStrFeed = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x46), u8(0x45), u8(0x45), u8(0x44),
];

/// `"USB MOUSE "` -- 10 bytes. Boot-mouse seam announce.
@rodata
final List<u8> usbStrMouse = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x4D), u8(0x4F), u8(0x55), u8(0x53), u8(0x45), u8(0x20),
];

/// `"usb: usage: usb | usb feed <hex>\n"` -- 33 bytes.
@rodata
final List<u8> usbStrUsage = const [
  u8(0x75), u8(0x73), u8(0x62), u8(0x3A), u8(0x20),
  u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A), u8(0x20),
  u8(0x75), u8(0x73), u8(0x62), u8(0x20), u8(0x7C), u8(0x20),
  u8(0x75), u8(0x73), u8(0x62), u8(0x20),
  u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20),
  u8(0x3C), u8(0x68), u8(0x65), u8(0x78), u8(0x3E), u8(0x0A),
];

/// HID Keyboard/Keypad page usage → set-1 make scancode. 128 entries
/// so a usage below 0x80 is in range by construction. 0x00 means
/// unmapped. HID `0x04` is `a`; set-1 `0x1E` is `a`. They are
/// different numbers -- that is the whole of USB2.
///
/// Indexed by HID usage, not by set-1. A host model that treated the
/// usage as a scancode would index [kbdSet1Ascii] at 0x04 and type
/// `3`. The harness fails that.
@rodata
final List<u8> usbHidUsageSet1 = const [
  // 0x00-0x0F  ....a b c d e f g h i j k l
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x1E), u8(0x30), u8(0x2E), u8(0x20),
  u8(0x12), u8(0x21), u8(0x22), u8(0x23), u8(0x17), u8(0x24), u8(0x25), u8(0x26),
  // 0x10-0x1F  m n o p q r s t u v w x y z 1 2
  u8(0x32), u8(0x31), u8(0x18), u8(0x19), u8(0x10), u8(0x13), u8(0x1F), u8(0x14),
  u8(0x16), u8(0x2F), u8(0x11), u8(0x2D), u8(0x15), u8(0x2C), u8(0x02), u8(0x03),
  // 0x20-0x2F  3 4 5 6 7 8 9 0 Enter Esc BS Tab Spc - = [
  u8(0x04), u8(0x05), u8(0x06), u8(0x07), u8(0x08), u8(0x09), u8(0x0A), u8(0x0B),
  u8(0x1C), u8(0x01), u8(0x0E), u8(0x0F), u8(0x39), u8(0x0C), u8(0x0D), u8(0x1A),
  // 0x30-0x3F  ] \ # ; ' ` , . / Caps F1 F2 F3 F4 F5 F6
  u8(0x1B), u8(0x2B), u8(0x2B), u8(0x27), u8(0x28), u8(0x29), u8(0x33), u8(0x34),
  u8(0x35), u8(0x3A), u8(0x3B), u8(0x3C), u8(0x3D), u8(0x3E), u8(0x3F), u8(0x40),
  // 0x40-0x4F  F7 F8 F9 F10 F11 F12 ..........
  u8(0x41), u8(0x42), u8(0x43), u8(0x44), u8(0x57), u8(0x58), u8(0x00), u8(0x00),
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x50-0x5F
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x60-0x6F
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  // 0x70-0x7F
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
];

/// HID modifier bitmap bit → set-1 make. Bit 0 is Left Ctrl.
@rodata
final List<u8> usbHidModSet1 = const [
  u8(0x1D), u8(0x2A), u8(0x38), u8(0x5B),
  u8(0x1D), u8(0x36), u8(0x38), u8(0x5C),
];

/// 1 if that modifier is an 0xE0-extended set-1 code (LGUI, RCtrl,
/// RAlt, RGUI). Left shift / left alt / left ctrl / right shift are not.
@rodata
final List<u8> usbHidModExt = const [
  u8(0x00), u8(0x00), u8(0x00), u8(0x01),
  u8(0x01), u8(0x00), u8(0x01), u8(0x01),
];

/// Bit masks for the eight modifier bits, so the walk does not shift
/// by a variable.
@rodata
final List<u8> usbHidModMask = const [
  u8(0x01), u8(0x02), u8(0x04), u8(0x08),
  u8(0x10), u8(0x20), u8(0x40), u8(0x80),
];

/// Called from `kmain` with the other silent inits. USB0/USB1 have no
/// `.bss` to zero and must print nothing: `m1-interrupts` asserts the
/// entire 544-byte capture. The print is [usbReport].
@bare
void usbInit() {
}

/// Walks bus 0, function 0 of each slot, for class 0C/03/30. Returns a
/// packed bus/device/function, or [pciBdfNone]. Bus 0 and function 0
/// only, deliberately: [pciFindByClass] is the same walk, and an xHCI
/// behind a bridge is a named successor, not a defect in USB0.
/// qemu-xhci is a single-function device on bus 0.
@bare
u64 usbFindXhci() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) < u64(0xFFFF)) {
      final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
      if (((classReg >> u64(24)) & u64(0xFF)) == u64(usbClassSerial)) {
        if (((classReg >> u64(16)) & u64(0xFF)) == u64(usbSubclassUsb)) {
          if (((classReg >> u64(8)) & u64(0xFF)) == u64(usbProgIfXhci)) {
            return (dev << u64(11));
          }
        }
      }
    }
    dev = dev + u64(1);
  }
  return u64(pciBdfNone);
}

/// Physical base of BAR0, or 0 if it is I/O, unimplemented, or above
/// 4 GiB. qemu-xhci is a 64-bit MMIO BAR: the next register is the
/// upper half. A non-zero upper dword is refused -- `boot.S` maps
/// [3 GiB, 4 GiB) and nothing above 4 GiB (same refusal as G0).
@bare
u64 usbReadBar0(u64 bus, u64 dev, u64 fn) {
  final u64 lo = pciRead32(bus, dev, fn, u64(pciRegBar));
  if ((lo & u64(1)) > u64(0)) {
    return u64(0);
  }
  final u64 addr = lo & u64(0xFFFFFFF0);
  if (((lo >> u64(1)) & u64(3)) == u64(2)) {
    final u64 hi = pciRead32(bus, dev, fn, u64(pciRegBar) + u64(4));
    if (hi > u64(0)) {
      return u64(0);
    }
  }
  return addr;
}

/// 32-bit MMIO load at [bar] + [off]. Every `Volatile` access is
/// emitted volatile (ADR-0044), which is what MMIO needs.
@bare
u64 usbRegGet(u64 bar, u64 off) {
  return Volatile<u32>.fromAddress(bar + off).value.toU64();
}

/// One found-device line:
///
///     USB XHCI 00:04.0 1B36:000D 0C/03/30
///
/// Shape matches [pciReportDevice] / [virtgpuReportDevice] so a harness
/// can parse BDF and vendor:device and compare them to QEMU's `info pci`
/// without a second encoding.
@bare
void usbReportDevice(u64 bus, u64 dev, u64 fn, u64 id, u64 classReg) {
  uartWrite(Rodata.addressOf(usbStrXhci), u64(9));
  uartPutHex(bus, u64(2));
  conPutc(u8(0x3A)); // ':'
  uartPutHex(dev, u64(2));
  conPutc(u8(0x2E)); // '.'
  uartPutHex(fn, u64(1));
  uartSpace();
  uartPutHex(id & u64(0xFFFF), u64(4));
  conPutc(u8(0x3A));
  uartPutHex((id >> u64(16)) & u64(0xFFFF), u64(4));
  uartSpace();
  uartPutHex((classReg >> u64(24)) & u64(0xFF), u64(2));
  conPutc(u8(0x2F));
  uartPutHex((classReg >> u64(16)) & u64(0xFF), u64(2));
  conPutc(u8(0x2F));
  uartPutHex((classReg >> u64(8)) & u64(0xFF), u64(2));
  uartNewline();
}

/// Two capability / operational lines from a mapped BAR0:
///
///     USB BAR FEBF0000 CAPLENGTH 40 HCIVERSION 0100 SLOTS 40 INTRS 0010 PORTS 05
///     USB DBOFF 00002000 RTSOFF 00001000 USBCMD 00000000 USBSTS 00000001
///
/// Loads only. Run/Stop is not set. The controller is not reset.
@bare
void usbReportRegs(u64 bar) {
  final u64 cap0 = usbRegGet(bar, u64(0));
  final u64 caplength = cap0 & u64(0xFF);
  final u64 hciver = (cap0 >> u64(16)) & u64(0xFFFF);
  final u64 hcs1 = usbRegGet(bar, u64(usbCapHcsparams1));
  final u64 slots = hcs1 & u64(0xFF);
  final u64 intrs = (hcs1 >> u64(8)) & u64(0x7FF);
  final u64 ports = (hcs1 >> u64(24)) & u64(0xFF);
  final u64 dboff = usbRegGet(bar, u64(usbCapDboff));
  final u64 rtsoff = usbRegGet(bar, u64(usbCapRtsoff));
  final u64 usbcmd = usbRegGet(bar + caplength, u64(usbOpUsbcmd));
  final u64 usbsts = usbRegGet(bar + caplength, u64(usbOpUsbsts));

  uartWrite(Rodata.addressOf(usbStrBar), u64(8));
  uartPutHex(bar, u64(8));
  uartWrite(Rodata.addressOf(usbStrCaplength), u64(11));
  uartPutHex(caplength, u64(2));
  uartWrite(Rodata.addressOf(usbStrHciver), u64(12));
  uartPutHex(hciver, u64(4));
  uartWrite(Rodata.addressOf(usbStrSlots), u64(7));
  uartPutHex(slots, u64(2));
  uartWrite(Rodata.addressOf(usbStrIntrs), u64(7));
  uartPutHex(intrs, u64(4));
  uartWrite(Rodata.addressOf(usbStrPorts), u64(7));
  uartPutHex(ports, u64(2));
  uartNewline();

  uartWrite(Rodata.addressOf(usbStrDboff), u64(10));
  uartPutHex(dboff, u64(8));
  uartWrite(Rodata.addressOf(usbStrRtsoff), u64(8));
  uartPutHex(rtsoff, u64(8));
  uartWrite(Rodata.addressOf(usbStrUsbcmd), u64(8));
  uartPutHex(usbcmd, u64(8));
  uartWrite(Rodata.addressOf(usbStrUsbsts), u64(8));
  uartPutHex(usbsts, u64(8));
  uartNewline();
}

/// `usb` -- find xHCI, print it, read cap/op registers, or print
/// `USB NONE`.
///
/// Runs in TASK context with interrupts enabled, like every other
/// command (ADR-0006). It is a handful of configuration reads and
/// MMIO loads. Nothing here waits on a device, nothing is written,
/// and nothing is retained.
@bare
void usbReport() {
  final u64 bdf = usbFindXhci();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(usbStrNone), u64(9));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 id = pciRead32(bus, dev, fn, u64(pciRegId));
  final u64 classReg = pciRead32(bus, dev, fn, u64(pciRegClass));
  usbReportDevice(bus, dev, fn, id, classReg);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(usbCmdMem)) < u64(usbCmdMem)) {
    uartWrite(Rodata.addressOf(usbStrNocmd), u64(10));
    return;
  }
  final u64 bar = usbReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(usbStrNobar), u64(10));
    return;
  }
  usbReportRegs(bar);
}

/// HID usage → set-1 make, or 0 if the usage is unmapped or out of
/// the table. This is the function a transfer-ring path must call.
/// The feed seam calls it too, so a decoder that only worked when
/// fed by hand is still the decoder the ring will use.
@bare
u64 usbHidToSet1(u64 usage) {
  if (usage > u64(0x7F)) {
    return u64(0);
  }
  return Pointer<u8>.fromAddress(
    Rodata.addressOf(usbHidUsageSet1) + usage,
  ).value.toU64();
}

/// Enqueues one packed kbdq event. CLI around the push: IRQ1 is the
/// other producer and this runs in TASK context with IF set.
@bare
void usbHidPush(u64 ev) {
  interrupts_disable();
  kbdqPush(ev);
  interrupts_enable();
}

/// Make or break [set1], optionally extended, and if [announce] is
/// not 0 print a space and the packed event as four hex digits.
@bare
void usbHidEdge(u64 set1, u64 brk, u64 ext, u64 announce) {
  if (set1 > u64(0)) {
    final u64 ev = set1 | brk | ext;
    usbHidPush(ev);
    if (announce > u64(0)) {
      uartSpace();
      uartPutHex(ev, u64(4));
    }
  }
}

/// Synthesise modifier make/break from the bitmap delta.
@bare
void usbHidModEdges(u64 now, u64 prev, u64 announce) {
  u64 bit = u64(0);
  while (bit < u64(8)) {
    final u64 mask = Pointer<u8>.fromAddress(
      Rodata.addressOf(usbHidModMask) + bit,
    ).value.toU64();
    final u64 set1 = Pointer<u8>.fromAddress(
      Rodata.addressOf(usbHidModSet1) + bit,
    ).value.toU64();
    final u64 extb = Pointer<u8>.fromAddress(
      Rodata.addressOf(usbHidModExt) + bit,
    ).value.toU64();
    u64 ext = u64(0);
    if (extb > u64(0)) {
      ext = u64(kbdqBitExt);
    }
    final u64 was = prev & mask;
    final u64 isn = now & mask;
    if (was < u64(1)) {
      if (isn > u64(0)) {
        usbHidEdge(set1, u64(0), ext, announce);
      }
    } else {
      if (isn < u64(1)) {
        usbHidEdge(set1, u64(kbdqBitBreak), ext, announce);
      }
    }
    bit = bit + u64(1);
  }
}

/// One packed HID boot report: modifier bitmap plus the first usage
/// slot. Compares against the previous report and [kbdqPush]es the
/// edges. The transfer path will call this with the same arguments
/// once a report exists on the wire.
@bare
void usbHidApply(u64 mods, u64 usage, u64 prevMods, u64 prevUsage, u64 announce) {
  usbHidModEdges(mods, prevMods, announce);
  if (usage == prevUsage) {
    return;
  }
  if (prevUsage > u64(0)) {
    usbHidEdge(usbHidToSet1(prevUsage), u64(kbdqBitBreak), u64(0), announce);
  }
  if (usage > u64(0)) {
    usbHidEdge(usbHidToSet1(usage), u64(0), u64(0), announce);
  }
}

/// One HID boot-protocol mouse report into the pointer state.
///
/// Byte 0 is buttons (bit0 left). Bytes 1 and 2 are signed 8-bit
/// displacements. HID Y positive is toward the user, which is DOWN
/// the framebuffer -- the opposite of PS/2's axis (see
/// [mouseApplyY]). The transfer path will call this with the same
/// arguments once a mouse report exists on the wire. No `@bss`.
@bare
void usbHidMouseApply(u64 buttons, u64 dx, u64 dy, u64 announce) {
  u64 x = mouseState(u64(mouseWordX));
  if ((dx & u64(0x80)) > u64(0)) {
    final u64 mag = u64(0x100) - dx;
    if (x < mag) {
      x = u64(0);
    } else {
      x = x - mag;
    }
  } else {
    x = x + dx;
    if (x > (fbGeomWidth() - u64(1))) {
      x = fbGeomWidth() - u64(1);
    }
  }
  mouseSetState(u64(mouseWordX), x);

  u64 y = mouseState(u64(mouseWordY));
  if ((dy & u64(0x80)) > u64(0)) {
    final u64 mag = u64(0x100) - dy;
    if (y < mag) {
      y = u64(0);
    } else {
      y = y - mag;
    }
  } else {
    y = y + dy;
    if (y > (fbGeomHeight() - u64(1))) {
      y = fbGeomHeight() - u64(1);
    }
  }
  mouseSetState(u64(mouseWordY), y);

  mouseSetState(u64(mouseWordButtons), buttons & u64(0x07));
  mouseBump(u64(mouseWordPackets));
  if (announce > u64(0)) {
    uartWrite(Rodata.addressOf(usbStrMouse), u64(10));
    uartPutHex(x, u64(4));
    uartWrite(Rodata.addressOf(mouseStrY), u64(3));
    uartPutHex(y, u64(4));
    uartWrite(Rodata.addressOf(mouseStrB), u64(3));
    uartPutHex(buttons & u64(0x07), u64(1));
    uartNewline();
  }
  wmPointerTick();
}

/// How many complete hex bytes are on the line after `usb feed `.
@bare
u64 usbFeedByteCount() {
  final u64 len = shellLen();
  u64 i = u64(9);
  u64 pending = u64(0x100);
  u64 n = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        n = n + u64(1);
        pending = u64(0x100);
      }
    }
    i = i + u64(1);
  }
  return n;
}

/// Walks the hex argument a second time and applies each packed
/// report or each 8-byte boot report. [kind] 0 is packed (mod, key)
/// pairs; [kind] 1 is 8-byte boot reports (byte 0 = mod, byte 2 =
/// first usage). Previous state is locals -- one command, no `.bss`.
@bare
void usbFeedApply(u64 kind) {
  final u64 len = shellLen();
  u64 i = u64(9);
  u64 pending = u64(0x100);
  u64 n = u64(0);
  u64 cur = u64(0);
  u64 prevMods = u64(0);
  u64 prevUsage = u64(0);
  u64 mods = u64(0);
  u64 usage = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        cur = (pending << u64(4)) | d;
        pending = u64(0x100);
        if (kind > u64(0)) {
          if (n == u64(0)) {
            mods = cur;
          }
          if (n == u64(2)) {
            usage = cur;
          }
          n = n + u64(1);
          if (n == u64(8)) {
            usbHidApply(mods, usage, prevMods, prevUsage, u64(1));
            prevMods = mods;
            prevUsage = usage;
            n = u64(0);
          }
        } else {
          if (n == u64(0)) {
            mods = cur;
            n = u64(1);
          } else {
            usbHidApply(mods, cur, prevMods, prevUsage, u64(1));
            prevMods = mods;
            prevUsage = cur;
            n = u64(0);
          }
        }
      }
    }
    i = i + u64(1);
  }
}

/// `usb feed <hex>` -- push packed HID boot reports into [usbHidApply].
///
/// **THIS IS A TEST SEAM AND IT IS LABELLED AS ONE.** xHCI bring-up
/// (port reset, address, SET_CONFIGURATION, SET_PROTOCOL(0), one
/// interrupt endpoint) is USB3. Until a report exists on the wire,
/// the harness injects one through this command on COM1. The
/// translator it calls is the translator the transfer path must call.
///
/// Packed form is two bytes per report: modifier bitmap, then the
/// first usage slot. `0004` is usage `a`. `0000` is all keys up.
/// An 8-byte boot report (`00 00 04 00 00 00 00 00`) is accepted
/// when the argument is a multiple of eight bytes: byte 0 is the
/// modifier, byte 2 is the first usage. Six-key rollover is USB3.
///
/// Non-hex bytes are skipped, so `0004 0000` and `00040000` are the
/// same packed input.
@bare
void usbFeed() {
  final u64 n = usbFeedByteCount();
  if (n < u64(2)) {
    uartWrite(Rodata.addressOf(usbStrUsage), u64(33));
    return;
  }
  u64 kind = u64(0);
  if (n >= u64(8)) {
    if ((n & u64(7)) == u64(0)) {
      kind = u64(1);
    }
  }
  if (kind < u64(1)) {
    if ((n & u64(1)) > u64(0)) {
      uartWrite(Rodata.addressOf(usbStrUsage), u64(33));
      return;
    }
  }
  uartWrite(Rodata.addressOf(usbStrFeed), u64(8));
  usbFeedApply(kind);
  uartNewline();
}

/// How many complete hex bytes follow `usb mfeed `.
@bare
u64 usbMfeedByteCount() {
  final u64 len = shellLen();
  u64 i = u64(10);
  u64 pending = u64(0x100);
  u64 n = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        n = n + u64(1);
        pending = u64(0x100);
      }
    }
    i = i + u64(1);
  }
  return n;
}

/// `usb mfeed <hex>` -- push HID boot-mouse reports into
/// [usbHidMouseApply]. Three bytes per report: buttons, dx, dy.
/// Labelled seam, same shape as `usb feed` / `mouse feed`. No `@bss`.
@bare
void usbMfeed() {
  final u64 n = usbMfeedByteCount();
  if (n < u64(3)) {
    uartWrite(Rodata.addressOf(usbStrUsage), u64(33));
    return;
  }
  if ((n % u64(3)) > u64(0)) {
    uartWrite(Rodata.addressOf(usbStrUsage), u64(33));
    return;
  }
  final u64 len = shellLen();
  u64 i = u64(10);
  u64 pending = u64(0x100);
  u64 k = u64(0);
  u64 b0 = u64(0);
  u64 b1 = u64(0);
  u64 b2 = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        final u64 cur = (pending << u64(4)) | d;
        pending = u64(0x100);
        if (k == u64(0)) {
          b0 = cur;
          k = u64(1);
        } else {
          if (k == u64(1)) {
            b1 = cur;
            k = u64(2);
          } else {
            b2 = cur;
            usbHidMouseApply(b0, b1, b2, u64(1));
            k = u64(0);
          }
        }
      }
    }
    i = i + u64(1);
  }
}

/// `usb` with an argument this command does not know.
@bare
void usbUsage() {
  uartWrite(Rodata.addressOf(usbStrUsage), u64(33));
}
