// core/kernel/pci.dart
//
// oscortex_core M5: PCI configuration-space enumeration over the legacy
// 0xCF8/0xCFC port pair.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is: `dcc` lowers exactly ONE library per object file, so a
// `@bare` function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHY THIS, AND WHY NOW
// ---------------------------------------------------------------------------
// Every device this kernel drives today was found by KNOWING WHERE IT IS. The
// 16550 is at 0x3F8 because that is where a COM1 has been since 1981; the
// 8259s are at 0x20/0xA0; the PIT is at 0x40; the 8042 is at 0x60/0x64; the
// VGA text buffer is at 0xB8000. Not one of those addresses was discovered --
// they are all constants compiled into the kernel, and every one of them is a
// bet that this machine is shaped like a 1990 PC.
//
// A PCI device is the first thing this kernel can find WITHOUT having been
// told. That is the whole point of this file, and it is a prerequisite for
// every real driver after it: a disk controller, a NIC and a framebuffer all
// begin the same way, by asking the bus what is on it and where it put the
// device's registers.
//
// ---------------------------------------------------------------------------
// THE MECHANISM, AND THE ONE THING DCDart CANNOT DO
// ---------------------------------------------------------------------------
// Configuration mechanism #1 is two I/O registers:
//
//   0xCF8  CONFIG_ADDRESS   write a 32-bit selector:
//                             bit 31     enable
//                             bits 23:16 bus
//                             bits 15:11 device
//                             bits 10:8  function
//                             bits 7:2   register (dword-aligned)
//   0xCFC  CONFIG_DATA      then read the selected 32-bit register
//
// Both accesses are DOUBLEWORD accesses, and `Port.outb`/`Port.inb` (DCDart
// ADR-0029) are the only port primitives the language has -- they are BYTE
// wide. Four byte writes to 0xCF8..0xCFB are not a legal substitute: the PCI
// specification decodes CONFIG_ADDRESS only for a full doubleword access.
//
// So `outl`/`inl` live in `core/boot/portio.S` behind a plain C-ABI call, the
// same seam `cpuid`, `lidt` and `int3` already use, and the real ask -- a
// `Port.outl`/`Port.inl` one width wider than ADR-0029 -- is filed as
// docs/known-gaps.md GAP-0066. Everything ABOVE the instruction, including the
// whole selector layout and the bus walk, is DCDart in this file.
//
// ---------------------------------------------------------------------------
// NO STORAGE. THIS SUBSYSTEM COSTS ZERO DONATED BYTES.
// ---------------------------------------------------------------------------
// Worth saying out loud, because it is the first one since M1 that does not
// grow `core/boot/kdata.S` (docs/known-gaps.md GAP-0053): the scan PRINTS as
// it walks and retains nothing, exactly as `mbReport` does with the memory
// map. That is not virtue, it is the same limitation wearing a different hat
// -- there is nowhere to put a device list, so a later driver that wants "the
// NIC I found" has to walk the bus again to find it. Recorded in GAP-0067.
//
// ---------------------------------------------------------------------------
// WHAT AN ABSENT DEVICE LOOKS LIKE
// ---------------------------------------------------------------------------
// A configuration read to a bus/device/function nothing answers returns all
// ones -- the host bridge drives 0xFFFFFFFF rather than aborting -- so a
// vendor ID of 0xFFFF means "not present". That is the only presence test
// there is, and it is why the walk below can be a plain loop with no timeout
// and no error path: an empty slot is a value, not a failure.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The two instructions DCDart does not have. See core/boot/portio.S.
// ---------------------------------------------------------------------------

/// 32-bit `in`. [port] is a port number; only the low 16 bits are used.
@extern
external u64 port_inl(u64 port);

/// 32-bit `out`. Only the low 32 bits of [value] are written.
@extern
external void port_outl(u64 port, u64 value);

// ---------------------------------------------------------------------------
// Ports and layout constants. Named `const int`s (DCDart ADR-0037).
// ---------------------------------------------------------------------------

/// Configuration mechanism #1's address and data registers.
const int pciConfigAddress = 0xCF8;
const int pciConfigData = 0xCFC;

/// Configuration-space register offsets this file reads.
///
///   +0x00  vendor ID (15:0), device ID (31:16)
///   +0x08  revision (7:0), prog-IF (15:8), subclass (23:16), class (31:24)
///   +0x0C  cache line, latency, HEADER TYPE (23:16), BIST
///   +0x18  (header type 1 only) primary, SECONDARY (15:8), subordinate bus
const int pciRegId = 0x00;
const int pciRegCommand = 0x04;
const int pciRegClass = 0x08;
const int pciRegHeader = 0x0C;
const int pciRegBusNumbers = 0x18;

/// Configuration-space offset of BAR0. BAR *n* is this plus `n * 4`.
/// `fb.dart` has the same number under [pciRegBar0]; both names are the
/// same constant, and N0's [pciReadBar] is the general reader M5 declined
/// to write (GAP-0067 item 3).
const int pciRegBar = 0x10;

/// Packed bus/device/function: `(bus << 16) | (dev << 11) | (fn << 8)`.
/// That is the selector shape [pciAddr] wants, minus the enable bit and
/// the register offset. No legal selector is all-ones, so the sentinel
/// below cannot collide with a real device.
const int pciBdfNone = 0xFFFFFFFF;

/// Class 0x06 subclass 0x04 is a PCI-to-PCI bridge: the only header type this
/// scan follows to another bus.
const int pciClassBridge = 0x06;
const int pciSubclassPciBridge = 0x04;

/// How deep the bus walk will follow bridges. Not a spec limit -- a stack
/// limit. `boot.S` gives this kernel a 16KiB boot stack and there is no guard
/// page (docs/known-gaps.md GAP-0007), so an unbounded recursion driven by a
/// number read out of a device register is a way for hardware to overflow the
/// kernel stack. Four is deeper than any machine this has been run on and
/// cheap to bound. See also the strictly-increasing-bus guard in
/// [pciScanFunction], which is the other half.
const int pciMaxDepth = 4;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
// ---------------------------------------------------------------------------
/// Per-device line prefix. Every line this command prints starts with it, so
/// a capture can be grepped for the scan without knowing the format.
///
/// `"PCI "` -- 4 bytes.
@rodata
final List<u8> pciStrLine = const [
  u8(0x50), u8(0x43), u8(0x49), u8(0x20),
];

/// Summary label, followed by the number of functions that answered.
///
/// A terminator as much as a total: it is the line that says the walk RAN TO
/// COMPLETION rather than stopping in the middle of a bus, the same job
/// `MB END` does for the memory map.
///
/// `"PCI TOTAL "` -- 10 bytes.
@rodata
final List<u8> pciStrTotal = const [
  u8(0x50), u8(0x43), u8(0x49), u8(0x20), u8(0x54), u8(0x4F), u8(0x54), u8(0x41), u8(0x4C), u8(0x20),
];

/// Suffix on a PCI-to-PCI bridge's line, followed by the secondary bus number
/// the scan is about to descend into. Printed BEFORE the descent, so the
/// devices behind the bridge appear under it in the capture.
///
/// `" >BUS "` -- 6 bytes.
@rodata
final List<u8> pciStrToBus = const [
  u8(0x20), u8(0x3E), u8(0x42), u8(0x55), u8(0x53), u8(0x20),
];

/// Printed when the scan found nothing at all.
///
/// `"PCI NONE\n"` -- 9 bytes.
@rodata
final List<u8> pciStrNone = const [
  u8(0x50), u8(0x43), u8(0x49), u8(0x20), u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// PCI class-code names, as fixed-width records: **20 records of 16 bytes
/// each, 320 bytes total.**
///
///     +0  class code
///     +1  subclass, or 0xFF meaning "any subclass of this class"
///     +2  name length, 1..13
///     +3  the name, NUL-padded to 13 bytes
///
/// **This shape is a deliberate answer to docs/known-gaps.md GAP-0060.** The
/// obvious encoding -- one `@rodata` table per name -- would have added twenty
/// more hand-maintained byte counts to the forty-nine this kernel already
/// carries, on a path where a wrong one prints a device's class name with the
/// next name's first letters glued on. Putting the length INSIDE each record
/// leaves exactly one hand-maintained number for the whole table (its 320
/// bytes, which `tests/conformance/m5-pci/run.sh` reads out of the symbol
/// table and compares against [pciNameCount] * [pciNameStride]), and the
/// per-name lengths become data the lookup reads rather than literals a human
/// counted. It does not close GAP-0060 -- it moves twenty instances of it into
/// one.
///
/// Fixed 16-byte records rather than a packed variable-length run so that
/// record *i* is at `base + i * 16` -- a shift, not a walk -- and so a
/// truncated table is a misaligned record rather than a read that runs off the
/// end of `.rodata`.
///
/// **Unknown class codes get no name at all.** There is no default entry and
/// no "unknown device" string: a class this table does not list prints its raw
/// `class/subclass/prog-IF` triple and stops. Guessing would be worse than
/// saying nothing, because the raw number is always exactly true.
@rodata
final List<u8> pciClassNames = const [
  u8(0x01), u8(0xFF), u8(0x07), u8(0x73), u8(0x74), u8(0x6F), u8(0x72), u8(0x61), u8(0x67), u8(0x65), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x01), u8(0x01), u8(0x0B), u8(0x69), u8(0x64), u8(0x65), u8(0x20), u8(0x73), u8(0x74), u8(0x6F), u8(0x72), u8(0x61), u8(0x67), u8(0x65), u8(0x00), u8(0x00),
  u8(0x01), u8(0x06), u8(0x0C), u8(0x73), u8(0x61), u8(0x74), u8(0x61), u8(0x20), u8(0x73), u8(0x74), u8(0x6F), u8(0x72), u8(0x61), u8(0x67), u8(0x65), u8(0x00),
  u8(0x01), u8(0x08), u8(0x0C), u8(0x6E), u8(0x76), u8(0x6D), u8(0x65), u8(0x20), u8(0x73), u8(0x74), u8(0x6F), u8(0x72), u8(0x61), u8(0x67), u8(0x65), u8(0x00),
  u8(0x02), u8(0xFF), u8(0x07), u8(0x6E), u8(0x65), u8(0x74), u8(0x77), u8(0x6F), u8(0x72), u8(0x6B), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x02), u8(0x00), u8(0x08), u8(0x65), u8(0x74), u8(0x68), u8(0x65), u8(0x72), u8(0x6E), u8(0x65), u8(0x74), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x03), u8(0xFF), u8(0x07), u8(0x64), u8(0x69), u8(0x73), u8(0x70), u8(0x6C), u8(0x61), u8(0x79), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x03), u8(0x00), u8(0x0B), u8(0x76), u8(0x67), u8(0x61), u8(0x20), u8(0x64), u8(0x69), u8(0x73), u8(0x70), u8(0x6C), u8(0x61), u8(0x79), u8(0x00), u8(0x00),
  u8(0x04), u8(0xFF), u8(0x0A), u8(0x6D), u8(0x75), u8(0x6C), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x64), u8(0x69), u8(0x61), u8(0x00), u8(0x00), u8(0x00),
  u8(0x05), u8(0xFF), u8(0x0B), u8(0x6D), u8(0x65), u8(0x6D), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x63), u8(0x74), u8(0x72), u8(0x6C), u8(0x00), u8(0x00),
  u8(0x06), u8(0xFF), u8(0x06), u8(0x62), u8(0x72), u8(0x69), u8(0x64), u8(0x67), u8(0x65), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x06), u8(0x00), u8(0x0B), u8(0x68), u8(0x6F), u8(0x73), u8(0x74), u8(0x20), u8(0x62), u8(0x72), u8(0x69), u8(0x64), u8(0x67), u8(0x65), u8(0x00), u8(0x00),
  u8(0x06), u8(0x01), u8(0x0A), u8(0x69), u8(0x73), u8(0x61), u8(0x20), u8(0x62), u8(0x72), u8(0x69), u8(0x64), u8(0x67), u8(0x65), u8(0x00), u8(0x00), u8(0x00),
  u8(0x06), u8(0x04), u8(0x0A), u8(0x70), u8(0x63), u8(0x69), u8(0x20), u8(0x62), u8(0x72), u8(0x69), u8(0x64), u8(0x67), u8(0x65), u8(0x00), u8(0x00), u8(0x00),
  u8(0x07), u8(0xFF), u8(0x09), u8(0x63), u8(0x6F), u8(0x6D), u8(0x6D), u8(0x20), u8(0x63), u8(0x74), u8(0x72), u8(0x6C), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x08), u8(0xFF), u8(0x0A), u8(0x70), u8(0x65), u8(0x72), u8(0x69), u8(0x70), u8(0x68), u8(0x65), u8(0x72), u8(0x61), u8(0x6C), u8(0x00), u8(0x00), u8(0x00),
  u8(0x09), u8(0xFF), u8(0x05), u8(0x69), u8(0x6E), u8(0x70), u8(0x75), u8(0x74), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x0C), u8(0xFF), u8(0x0A), u8(0x73), u8(0x65), u8(0x72), u8(0x69), u8(0x61), u8(0x6C), u8(0x20), u8(0x62), u8(0x75), u8(0x73), u8(0x00), u8(0x00), u8(0x00),
  u8(0x0C), u8(0x03), u8(0x03), u8(0x75), u8(0x73), u8(0x62), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0x0D), u8(0xFF), u8(0x08), u8(0x77), u8(0x69), u8(0x72), u8(0x65), u8(0x6C), u8(0x65), u8(0x73), u8(0x73), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
];

/// Bytes per record in [pciClassNames], and how many records there are.
/// Their product is the table's byte count and is checked against the symbol's
/// real size by the M5 harness.
const int pciNameStride = 16;
const int pciNameCount = 20;

/// Byte offsets inside one [pciClassNames] record.
const int pciNameClassOff = 0;
const int pciNameSubOff = 1;
const int pciNameLenOff = 2;
const int pciNameTextOff = 3;

/// The subclass byte that means "any subclass of this class".
///
/// 0xFF is safe to overload: it is a real PCI encoding only in class 0xFF
/// ("device does not fit any defined class"), which this table does not list,
/// and the two-pass lookup in [pciFindName] tries exact matches first anyway.
const int pciSubclassAny = 0xFF;

// ---------------------------------------------------------------------------
// Configuration-space access.
// ---------------------------------------------------------------------------

/// Builds a CONFIG_ADDRESS selector for [bus]:[dev].[fn], register [off].
///
/// [off] is masked to a doubleword boundary rather than trusted, because bits
/// 1:0 of CONFIG_ADDRESS are reserved and must be zero -- a caller that passed
/// a byte offset would otherwise select a neighbouring register with no
/// diagnostic anywhere. Every caller in this file passes an aligned offset; the
/// mask is what makes that a property of the function rather than of its
/// callers.
///
/// Bit 31 is the enable bit. Without it the write is not a configuration cycle
/// at all and the subsequent read of 0xCFC returns whatever the last cycle
/// left, which reads as a plausible device that is not there.
@bare
u64 pciAddr(u64 bus, u64 dev, u64 fn, u64 off) {
  return u64(0x80000000) |
      (bus << u64(16)) |
      (dev << u64(11)) |
      (fn << u64(8)) |
      (off & u64(0xFC));
}

/// Reads one 32-bit configuration register.
///
/// **Two port accesses that are not atomic with respect to each other.** If an
/// interrupt handler between the `outl` and the `inl` also touched 0xCF8, this
/// would read the wrong register. Nothing in this kernel does -- the only
/// unmasked line while a command runs is IRQ1, and `kbdHandle` touches 0x60
/// and 0x64 and nothing else -- so the hazard is real in principle and absent
/// in fact. Recorded in docs/known-gaps.md GAP-0067 rather than "solved" by a
/// `cli` that would also stop the keyboard.
@bare
u64 pciRead32(u64 bus, u64 dev, u64 fn, u64 off) {
  port_outl(u64(pciConfigAddress), pciAddr(bus, dev, fn, off));
  return port_inl(u64(pciConfigData));
}

/// Writes one 32-bit configuration register. Twin of [pciRead32]: the
/// same selector, then `outl` to 0xCFC instead of `inl`.
///
/// **The upper half of offset 0x04 is the status register, and its
/// error bits are write-1-to-clear.** A caller that reads the dword and
/// writes it straight back clears whatever the device had latched.
/// Writing 0 to a W1C bit is a no-op, so the command-register idiom is
/// `pciWrite32(..., 0x04, (pciRead32(...) & 0xFFFF) | bits)`. G1
/// (ADR-0065) and N1 (ADR-0063) both set bus-master (bit 2) that way.
///
/// Same non-atomicity as [pciRead32] (GAP-0067 item 6): two port
/// accesses, and an interrupt between them would select the wrong
/// register. Nothing in this kernel touches 0xCF8 from a handler.
@bare
void pciWrite32(u64 bus, u64 dev, u64 fn, u64 off, u64 value) {
  port_outl(u64(pciConfigAddress), pciAddr(bus, dev, fn, off));
  port_outl(u64(pciConfigData), value);
}

// ---------------------------------------------------------------------------
// Class-name lookup.
// ---------------------------------------------------------------------------

/// Returns the byte offset of the [pciClassNames] record describing
/// [cls]/[sub], or the table's length if there is none.
///
/// Two passes, deliberately, rather than one pass that remembers a wildcard
/// candidate: DCDart has no `break` and no boolean operators (GAP-0023), so
/// "keep looking but hold onto this" costs more here than looking twice over
/// twenty records. It also makes the result independent of the table's order,
/// which a one-pass version would not be.
@bare
u64 pciFindName(u64 cls, u64 sub) {
  final u64 base = Rodata.addressOf(pciClassNames);
  final u64 end = u64(pciNameCount) * u64(pciNameStride);
  // Pass 1: an exact class+subclass match.
  u64 i = u64(0);
  while (i < end) {
    if (Pointer<u8>.fromAddress(base + i + u64(pciNameClassOff)).value.toU64() == cls) {
      if (Pointer<u8>.fromAddress(base + i + u64(pciNameSubOff)).value.toU64() == sub) {
        return i;
      }
    }
    i = i + u64(pciNameStride);
  }
  // Pass 2: the class's catch-all entry.
  i = u64(0);
  while (i < end) {
    if (Pointer<u8>.fromAddress(base + i + u64(pciNameClassOff)).value.toU64() == cls) {
      if (Pointer<u8>.fromAddress(base + i + u64(pciNameSubOff)).value == u8(pciSubclassAny)) {
        return i;
      }
    }
    i = i + u64(pciNameStride);
  }
  return end;
}

/// Writes ` <name>` for [cls]/[sub], or nothing at all if the table has no
/// entry. The leading space is part of the name so that an unknown class ends
/// its line at the prog-IF digits with no trailing whitespace.
@bare
void pciWriteName(u64 cls, u64 sub) {
  final u64 base = Rodata.addressOf(pciClassNames);
  final u64 rec = pciFindName(cls, sub);
  if (rec < u64(pciNameCount) * u64(pciNameStride)) {
    uartSpace();
    // The length comes OUT OF THE TABLE. See pciClassNames' doc comment: this
    // is the one call site in this kernel that does not pass a hand-counted
    // literal (GAP-0060).
    uartWrite(
      base + rec + u64(pciNameTextOff),
      Pointer<u8>.fromAddress(base + rec + u64(pciNameLenOff)).value.toU64(),
    );
  }
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// One device line:
///
///     PCI 00:01.1 8086:7010 01/01/80 H00 ide storage
///     `--' `--'`' `--' `--' `' `' `' `-' `----------'
///      |    |   |   |    |   |  |  |   |       name, or nothing
///      |    |   |   |    |   |  |  |   raw header-type byte
///      |    |   |   |    |   |  |  prog-IF
///      |    |   |   |    |   |  subclass
///      |    |   |   |    |   class
///      |    |   |   |    device ID
///      |    |   |   vendor ID
///      |    |   function
///      |    device
///      bus
///
/// The raw header-type byte is printed rather than only its low seven bits,
/// because bit 7 is the multi-function flag and printing it is what makes the
/// scan's own decision checkable from a capture: exactly the devices whose
/// line says `H8x` are the ones whose functions 1..7 were probed at all.
@bare
void pciReportDevice(u64 bus, u64 dev, u64 fn, u64 id, u64 classReg, u64 hdr) {
  uartWrite(Rodata.addressOf(pciStrLine), u64(4));
  uartPutHex(bus, u64(2));
  conPutc(u8(0x3A)); // ':'
  uartPutHex(dev, u64(2));
  conPutc(u8(0x2E)); // '.'
  uartPutHex(fn, u64(1));
  uartSpace();
  uartPutHex(id & u64(0xFFFF), u64(4)); // vendor
  conPutc(u8(0x3A));
  uartPutHex((id >> u64(16)) & u64(0xFFFF), u64(4)); // device
  uartSpace();
  uartPutHex((classReg >> u64(24)) & u64(0xFF), u64(2)); // class
  conPutc(u8(0x2F)); // '/'
  uartPutHex((classReg >> u64(16)) & u64(0xFF), u64(2)); // subclass
  conPutc(u8(0x2F));
  uartPutHex((classReg >> u64(8)) & u64(0xFF), u64(2)); // prog-IF
  uartSpace();
  conPutc(u8(0x48)); // 'H'
  uartPutHex(hdr, u64(2));
  pciWriteName((classReg >> u64(24)) & u64(0xFF), (classReg >> u64(16)) & u64(0xFF));
}

// ---------------------------------------------------------------------------
// The walk.
//
// [pciScanBus] and [pciScanFunction] are MUTUALLY RECURSIVE, which is the
// whole of the bridge handling: a PCI-to-PCI bridge names the bus behind it in
// its own configuration space, and the only way to see what is over there is
// to go and look.
// ---------------------------------------------------------------------------

/// Probes one function. Returns 1 plus whatever was found behind it if a
/// device answered, 0 if the slot is empty.
@bare
u64 pciScanFunction(u64 bus, u64 dev, u64 fn, u64 depth) {
  final u64 id = pciRead32(bus, dev, fn, u64(pciRegId));
  if ((id & u64(0xFFFF)) == u64(0xFFFF)) {
    return u64(0); // nothing answered: the host bridge returned all ones
  }
  final u64 classReg = pciRead32(bus, dev, fn, u64(pciRegClass));
  final u64 hdr = (pciRead32(bus, dev, fn, u64(pciRegHeader)) >> u64(16)) & u64(0xFF);
  pciReportDevice(bus, dev, fn, id, classReg, hdr);

  if (((classReg >> u64(24)) & u64(0xFF)) == u64(pciClassBridge)) {
    if (((classReg >> u64(16)) & u64(0xFF)) == u64(pciSubclassPciBridge)) {
      // A type-1 header's secondary bus number is the bus on the far side.
      final u64 sec = (pciRead32(bus, dev, fn, u64(pciRegBusNumbers)) >> u64(8)) & u64(0xFF);
      uartWrite(Rodata.addressOf(pciStrToBus), u64(6));
      uartPutHex(sec, u64(2));
      uartNewline();
      // TWO guards, and they are not redundant. `bus < sec` is what makes the
      // recursion terminate at all: bus numbers strictly increase away from
      // the host bridge, so a device claiming a secondary bus at or below its
      // own would otherwise be an infinite loop driven by a register value.
      // The depth cap bounds the 16KiB boot stack even on a machine whose bus
      // numbers are legal and deeply nested.
      if (bus < sec) {
        if (depth < u64(pciMaxDepth)) {
          return u64(1) + pciScanBus(sec, depth + u64(1));
        }
      }
      return u64(1);
    }
  }
  uartNewline();
  return u64(1);
}

/// Probes functions 1..7 of a multi-function device. Returns how many
/// answered.
///
/// **A separate function purely because `dcc` rejects a nested `while`**
/// ("nested while-loops are not supported yet" -- hit for the first time by
/// this file, recorded as docs/known-gaps.md GAP-0068). The natural shape is
/// this loop inside [pciScanBus]'s device loop; DCDart cannot express that
/// today, so the inner loop becomes a call. The cost here is small and the
/// result is arguably clearer, which is exactly why it is worth writing down:
/// nothing about the source says a compiler limitation chose this shape.
@bare
u64 pciScanFunctions1To7(u64 bus, u64 dev, u64 depth) {
  u64 found = u64(0);
  u64 fn = u64(1);
  while (fn < u64(8)) {
    found = found + pciScanFunction(bus, dev, fn, depth);
    fn = fn + u64(1);
  }
  return found;
}

/// Probes one device slot: function 0, and functions 1..7 only if function 0
/// says it is multi-function.
///
/// **The multi-function bit is honoured rather than ignored.** Scanning all
/// eight function numbers unconditionally would also "work" on this machine,
/// and would be wrong: a single-function device is permitted to alias its
/// function-0 registers across every function number, so a blind scan reports
/// one device eight times. Under QEMU's i440FX exactly one slot (00:01, the
/// PIIX3) sets bit 7 of its header type, and it is exactly the slot that has
/// more than one function -- which is why the `H80` in its line is worth
/// printing.
@bare
u64 pciScanDevice(u64 bus, u64 dev, u64 depth) {
  final u64 id0 = pciRead32(bus, dev, u64(0), u64(pciRegId));
  if ((id0 & u64(0xFFFF)) == u64(0xFFFF)) {
    return u64(0); // empty slot
  }
  final u64 hdr0 =
      (pciRead32(bus, dev, u64(0), u64(pciRegHeader)) >> u64(16)) & u64(0xFF);
  final u64 found = pciScanFunction(bus, dev, u64(0), depth);
  if ((hdr0 & u64(0x80)) > u64(0)) {
    return found + pciScanFunctions1To7(bus, dev, depth);
  }
  return found;
}

/// Walks all 32 device slots on [bus]. Returns how many functions answered.
@bare
u64 pciScanBus(u64 bus, u64 depth) {
  u64 found = u64(0);
  u64 dev = u64(0);
  while (dev < u64(32)) {
    found = found + pciScanDevice(bus, dev, depth);
    dev = dev + u64(1);
  }
  return found;
}

/// Walks bus 0, function 0 of each slot, for class [cls] subclass [sub].
/// Returns a packed bus/device/function, or [pciBdfNone] if nothing
/// answered. Bus 0 only, deliberately: [fbFindVgaBar] is the same walk,
/// and a NIC behind a bridge is a named successor, not a defect in N0.
@bare
u64 pciFindByClass(u64 cls, u64 sub) {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) < u64(0xFFFF)) {
      final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
      if (((classReg >> u64(24)) & u64(0xFF)) == cls) {
        if (((classReg >> u64(16)) & u64(0xFF)) == sub) {
          return (dev << u64(11));
        }
      }
    }
    dev = dev + u64(1);
  }
  return u64(pciBdfNone);
}

/// Reads BAR [n] of the packed [bdf]. A memory BAR is returned as its
/// address with the type bits stripped. An I/O BAR, or a BAR that is not
/// implemented, is 0 — the same refusal [fbFindVgaBar] makes for a
/// display whose BAR0 is an I/O range.
///
/// This is a READ. It does not write all-ones to size the BAR and it
/// does not write the command register. G1 added [pciWrite32]; this
/// helper is still a reader.
@bare
u64 pciReadBar(u64 bdf, u64 n) {
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 off = u64(pciRegBar) + (n << u64(2));
  final u64 bar = pciRead32(bus, dev, fn, off);
  if ((bar & u64(1)) > u64(0)) {
    return u64(0);
  }
  return bar & u64(0xFFFFFFF0);
}

/// `pci` -- enumerate the bus and say what is on it.
///
/// Runs in TASK context with interrupts enabled, like every other command
/// (ADR-0006). It is a few hundred port accesses and returns in well under a
/// millisecond of guest time; nothing here waits on a device.
@bare
void shellPci() {
  final u64 found = pciScanBus(u64(0), u64(0));
  if (found < u64(1)) {
    // Not decoration. A machine with no configuration mechanism #1 at all
    // answers every read with 0xFFFFFFFF, which is indistinguishable from 32
    // empty slots -- so "the bus is empty" is a real, reportable outcome and
    // silence would look like a hang.
    uartWrite(Rodata.addressOf(pciStrNone), u64(9));
    return;
  }
  uartWrite(Rodata.addressOf(pciStrTotal), u64(10));
  uartPutHex(found, u64(4));
  uartNewline();
}
