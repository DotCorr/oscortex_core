// core/kernel/nvme.dart
//
// oscortex_core NVM0 + NVM1 + NVM2 + NVM3 + NVM4 + NVM5: find an NVMe
// I/O controller on PCI, print the function and BAR0, load CAP/VS,
// issue one Identify Controller (admin opcode 06h, CNS=1) through a
// real admin queue, create an I/O queue pair, complete one NVM Read
// of a planted sector, complete one NVM Write whose bytes the host
// image can read back, and serve FAT sectors through that I/O pair.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// The decisions are docs/decisions/0071-nvme-is-recognised.md (NVM0),
// docs/decisions/0074-the-kernel-reads-nvme-cap-and-vs.md (NVM1),
// docs/decisions/0087-nvme-identify-controller.md (NVM2),
// docs/decisions/0088-one-nvme-sector-read.md (NVM3),
// docs/decisions/0089-one-nvme-sector-write.md (NVM4), and
// docs/decisions/0090-fat-sectors-move-through-nvme.md (NVM5).
// The design this points back at is docs/design/storage.md (PIO / AHCI
// / FAT) and docs/design/portable-hardware.md §6.4 (a modern laptop
// disk is NVMe).
//
// ---------------------------------------------------------------------------
// ZERO DONATED BSS. THAT IS THE WHOLE OF THE MERGE RULE.
// ---------------------------------------------------------------------------
// `part 'nvme.dart'` sits AFTER `part 'usb.dart'` and BEFORE
// `part 'ahci.dart'`. D7 owns last place: `wmeventStore` is the newest
// bss block, and stealing that slot would move every harness that
// measures D7 to the end of .bss. NVM0/NVM1 print from locals. NVM2's
// admin SQ, admin CQ and Identify buffer come from three `allocFrame()`
// calls. NVM3 adds three more frames for the I/O SQ, I/O CQ and the
// sector buffer (identity-mapped, so the physical address IS the
// virtual address). Nothing here donates `.bss`, so D7 stays last.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE DOES, AND WHAT IT DOES NOT
// ---------------------------------------------------------------------------
// NVM0 walks bus 0 for class 01/08/02 (mass-storage / NVM / NVMe I/O
// controller) and prints the function and BAR0. Prog-IF 00 (vendor
// specific), 01 (NVMHCI), and 03 (NVMe over Fabrics) are not this
// device -- a class-only match would claim the wrong controller.
//
// BAR0 is a 64-bit MMIO BAR on QEMU's `-device nvme`. The upper dword
// is refused if non-zero: `boot.S` maps [3 GiB, 4 GiB) and nothing
// above 4 GiB (same refusal as G0 / USB1). Memory-decode is checked
// and not written.
//
// NVM1 is the first *device* read: CAP (8 bytes at BAR0+0) and VS
// (4 bytes at BAR0+8) are `Volatile<u32>` loads [NVM Express Base,
// Controller Properties]. MQES and TO are decoded from CAP so a
// canned dword cannot pass the spec checks. `nvme` still does not
// write 0xCFC and does not write CC.EN.
//
// NVM2 is the first *command*: `nvme id` sets bus-master, programmes
// AQA/ASQ/ACQ from three frames, writes CC.EN, rings the admin SQ
// doorbell, and waits on the CQ phase bit. Identify Controller
// (opcode 06h, CNS=1) returns SN/VID/NN from the 4096-byte data
// structure the controller DMA'd.
//
// NVM3 is the first *sector*: `nvme rd` reuses that admin pair (four
// entries so Identify + Create CQ + Create SQ do not wrap), issues
// Create I/O CQ (05h) and Create I/O SQ (01h) for QID 1, then one
// NVM Read (02h) of LBA 7 into a sixth frame. The printed 16 bytes
// are that PRP buffer, not the Identify structure.
//
// NVM4 is the first *write*: `nvme wr` reuses that I/O pair (four
// entries so Read + Write do not wrap), DMA-reads the planted sector
// at LBA 7, then issues NVM Write (01h) of that same PRP to LBA 11.
// The host image is the judge. Identify and `nvme rd` are unchanged.
//
// NVM5 is FAT on that path: [nvmeIoSetup] builds a 64-entry I/O pair
// once, [nvmeIoRead] / [nvmeIoWrite] issue one NVM command at an
// arbitrary LBA, and `fat.dart` calls them when [nvmeFind] sees a
// controller. No NVMe still uses ATA PIO. Still zero `.bss`: the
// session lives in a frame and two spare `fat_store` words.
//
// PCI helpers that are specific to this triple live here, not in
// pci.dart -- a sibling AHCI walk owns its own find (hot-files.md).
//
// ---------------------------------------------------------------------------
// WHY THE PRINT IS A COMMAND, NOT A BOOT LINE
// ---------------------------------------------------------------------------
// QEMU's default machine has no NVMe controller. A boot-time line would
// be `NVME NONE` on every session golden after `M1 END`. The print is
// therefore [nvmeReport], reached from the `nvme` command, which is not
// in `help` (the same reason `nic`, `usb` and `virtgpu` are not:
// GAP-0105 / GAP-0115). [nvmeInit] is called from `kmain` and prints
// nothing, so `m1-interrupts`' 544-byte golden is untouched. An absent
// device is silent unless the command is typed.

part of 'kmain.dart';

/// PCI class 0x01 subclass 0x08 is NVM Express. Prog-IF 0x02 is an
/// NVMe I/O controller. The other prog-IFs are vendor-specific (0x00),
/// NVMHCI (0x01), and NVMe over Fabrics (0x03). NVM0 matches the
/// triple, not the class alone.
const int nvmeClassStorage = 0x01;
const int nvmeSubclassNvm = 0x08;
const int nvmeProgIfIo = 0x02;

/// Command-register bit 1: memory decode. NVM1 loads CAP/VS through
/// BAR0, so this bit must be set. Bit 2 (bus-master) is a DMA fact:
/// NVM2 writes MEM|BME before the first admin-queue DMA. NVM1 does
/// not write 0xCFC.
const int nvmeCmdMem = 0x02;
const int nvmeCmdBme = 0x04;
const int nvmeCmdMemBme = 0x06;

/// Controller Properties [NVM Express Base]. CAP is 8 bytes at
/// BAR0+0; VS is 4 bytes at BAR0+8. Two 32-bit loads rebuild CAP.
/// NVM2 writes INTMS, CC, AQA, ASQ, ACQ and the admin doorbells.
const int nvmeRegCap = 0x00;
const int nvmeRegVs = 0x08;
const int nvmeRegIntms = 0x0C;
const int nvmeRegCc = 0x14;
const int nvmeRegCsts = 0x1C;
const int nvmeRegAqa = 0x24;
const int nvmeRegAsq = 0x28;
const int nvmeRegAcq = 0x30;
const int nvmeRegSq0Tdbl = 0x1000;

/// CAP bit fields used in the print. MQES is bits 15:0 (0-based max
/// queue entries). TO is bits 31:24 (500 ms units). DSTRD is bits
/// 35:32 of CAP (doorbell stride = 4 << DSTRD).
const int nvmeCapMqesMask = 0xFFFF;
const int nvmeCapToShift = 24;
const int nvmeCapToMask = 0xFF;
const int nvmeCapDstrdShift = 32;
const int nvmeCapDstrdMask = 0x0F;

/// CC.EN clear mask, CSTS.RDY, and the admin-enable CC dword:
/// EN | IOSQES=6 | IOCQES=4. AQA programmes two-entry queues
/// (0-based size 1). Identify is opcode 06h, CNS=1, CID=1.
const int nvmeCcEn = 0x01;
const int nvmeCcEnClr = 0xFFFFFFFE;
const int nvmeCcAdmin = 0x00460001;
const int nvmeCstsRdy = 0x01;
const int nvmeAqaTwo = 0x00010001;
const int nvmeOpcIdentify = 0x06;
const int nvmeOpcCreateSq = 0x01;
const int nvmeOpcCreateCq = 0x05;
const int nvmeOpcRead = 0x02;
const int nvmeOpcWrite = 0x01;
const int nvmeCnsController = 0x01;
const int nvmeCid = 0x01;
const int nvmeCidCq = 0x02;
const int nvmeCidSq = 0x03;
const int nvmeCidRd = 0x04;
const int nvmeCidWr = 0x05;
const int nvmeIdOffSn = 4;
const int nvmeIdSnBytes = 20;
const int nvmeIdOffNn = 516;
const int nvmeCqDw3 = 12;
const int nvmeCqPhase = 0x10000;
const int nvmeSqeNsid = 4;
const int nvmeSqePrp1 = 24;
const int nvmeSqeCdw10 = 40;
const int nvmeSqeCdw11 = 44;
const int nvmeSqeBytes = 64;
const int nvmeCqeBytes = 16;
const int nvmeAqaFour = 0x00030003;
const int nvmeIoQid1 = 0x00010001;
const int nvmeIoQid4 = 0x00030001;
const int nvmeCreateCqPc = 0x01;
const int nvmeNsid1 = 0x01;
const int nvmeReadLba = 7;
const int nvmeWriteLba = 11;
const int nvmePrintBytes = 16;

/// NVM5 I/O session, packed at offset 512 of the bounce frame so the
/// 512-byte PRP and the words do not overlap. QSIZE is 64 (CDW10
/// 0-based 63) so a `cat` of a small file does not wrap; wrap is
/// still handled by the phase bit. Power-of-two so the slot is a mask.
const int nvmeIoQsize = 64;
const int nvmeIoQid64 = 0x003F0001;
const int nvmeIoOffBar = 512;
const int nvmeIoOffStride = 520;
const int nvmeIoOffIosq = 528;
const int nvmeIoOffIocq = 536;
const int nvmeIoOffTail = 544;
const int nvmeIoOffQsize = 552;

/// Same bound as `ataWait` / `ahciWaitBits`: 2^21 iterations, not a
/// duration (GAP-0073). Returned high bit distinguishes a timeout.
const int nvmePollLimit = 0x200000;
const int nvmeTimedOut = 0x100000000;

/// Hidden command name. Not in `help` (goldens contain shellStrHelp).
///
/// `"nvme"` -- 4 bytes.
@rodata
final List<u8> nvmeStrCmd = const [
  u8(0x6E), u8(0x76), u8(0x6D), u8(0x65),
];

/// `"nvme id"` -- 7 bytes. Longest-first so `nvme` cannot swallow it.
@rodata
final List<u8> nvmeStrCmdId = const [
  u8(0x6E), u8(0x76), u8(0x6D), u8(0x65), u8(0x20),
  u8(0x69), u8(0x64),
];

/// `"nvme rd"` -- 7 bytes. Longest-first, same length as `nvme id`.
@rodata
final List<u8> nvmeStrCmdRd = const [
  u8(0x6E), u8(0x76), u8(0x6D), u8(0x65), u8(0x20),
  u8(0x72), u8(0x64),
];

/// `"nvme wr"` -- 7 bytes. Longest-first, same length as `nvme rd`.
@rodata
final List<u8> nvmeStrCmdWr = const [
  u8(0x6E), u8(0x76), u8(0x6D), u8(0x65), u8(0x20),
  u8(0x77), u8(0x72),
];

/// Found-device line prefix.
///
/// `"NVME "` -- 5 bytes.
@rodata
final List<u8> nvmeStrLine = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
];

/// Absent-device line. The negative control greps this and forbids any
/// `NVME ` BDF line on the same boot.
///
/// `"NVME NONE\n"` -- 10 bytes.
@rodata
final List<u8> nvmeStrNone = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// Memory-decode is clear. A later MMIO load of BAR0 would be a
/// guest-physical address the host bridge is not decoding.
///
/// `"NVME NOCMD\n"` -- 11 bytes.
@rodata
final List<u8> nvmeStrNocmd = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x43), u8(0x4D), u8(0x44), u8(0x0A),
];

/// BAR0 is I/O, unimplemented, or above 4 GiB.
///
/// `"NVME NOBAR\n"` -- 11 bytes.
@rodata
final List<u8> nvmeStrNobar = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x42), u8(0x41), u8(0x52), u8(0x0A),
];

/// `"NVME BAR "` -- 9 bytes. NVM0's line. NVM1 does not rewrite it.
@rodata
final List<u8> nvmeStrBar = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x42), u8(0x41), u8(0x52), u8(0x20),
];

/// `"NVME CAP "` -- 9 bytes.
@rodata
final List<u8> nvmeStrCap = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x43), u8(0x41), u8(0x50), u8(0x20),
];

/// `" VS "` -- 4 bytes.
@rodata
final List<u8> nvmeStrVs = const [
  u8(0x20), u8(0x56), u8(0x53), u8(0x20),
];

/// `" MQES "` -- 6 bytes.
@rodata
final List<u8> nvmeStrMqes = const [
  u8(0x20), u8(0x4D), u8(0x51), u8(0x45), u8(0x53), u8(0x20),
];

/// `" TO "` -- 4 bytes.
@rodata
final List<u8> nvmeStrTo = const [
  u8(0x20), u8(0x54), u8(0x4F), u8(0x20),
];

/// `"NVME NOFRM\n"` -- 11 bytes. `allocFrame` returned 0.
@rodata
final List<u8> nvmeStrNofrm = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x46), u8(0x52), u8(0x4D), u8(0x0A),
];

/// `"NVME CMD STUCK\n"` -- 15 bytes. BME did not stick.
@rodata
final List<u8> nvmeStrStuck = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
  u8(0x53), u8(0x54), u8(0x55), u8(0x43), u8(0x4B), u8(0x0A),
];

/// `"NVME TMO\n"` -- 9 bytes.
@rodata
final List<u8> nvmeStrTmo = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x54), u8(0x4D), u8(0x4F), u8(0x0A),
];

/// `"NVME STS "` -- 9 bytes. Then the CQ status field.
@rodata
final List<u8> nvmeStrSts = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x53), u8(0x54), u8(0x53), u8(0x20),
];

/// `"NVME ID SN "` -- 11 bytes.
@rodata
final List<u8> nvmeStrIdSn = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x49), u8(0x44), u8(0x20),
  u8(0x53), u8(0x4E), u8(0x20),
];

/// `" VID "` -- 5 bytes.
@rodata
final List<u8> nvmeStrVid = const [
  u8(0x20), u8(0x56), u8(0x49), u8(0x44), u8(0x20),
];

/// `" NN "` -- 4 bytes.
@rodata
final List<u8> nvmeStrNn = const [
  u8(0x20), u8(0x4E), u8(0x4E), u8(0x20),
];

/// `"NVME RD "` -- 8 bytes.
@rodata
final List<u8> nvmeStrRd = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x52), u8(0x44), u8(0x20),
];

/// `"NVME WR "` -- 8 bytes.
@rodata
final List<u8> nvmeStrWr = const [
  u8(0x4E), u8(0x56), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x57), u8(0x52), u8(0x20),
];

/// `" DATA "` -- 6 bytes.
@rodata
final List<u8> nvmeStrData = const [
  u8(0x20), u8(0x44), u8(0x41), u8(0x54), u8(0x41), u8(0x20),
];

/// Called from `kmain` with the other silent inits. NVM0 has no
/// `.bss` to zero and must print nothing: `m1-interrupts` asserts the
/// entire 544-byte capture. The print is [nvmeReport].
@bare
void nvmeInit() {
}

/// Walks bus 0, function 0 of each slot, for class 01/08/02. Returns a
/// packed bus/device/function, or [pciBdfNone]. Bus 0 and function 0
/// only, deliberately: [pciFindByClass] is the same walk, and an NVMe
/// behind a bridge is a named successor, not a defect in NVM0.
/// QEMU `-device nvme` is a single-function device on bus 0.
@bare
u64 nvmeFind() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) < u64(0xFFFF)) {
      final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
      if (((classReg >> u64(24)) & u64(0xFF)) == u64(nvmeClassStorage)) {
        if (((classReg >> u64(16)) & u64(0xFF)) == u64(nvmeSubclassNvm)) {
          if (((classReg >> u64(8)) & u64(0xFF)) == u64(nvmeProgIfIo)) {
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
/// 4 GiB. QEMU's NVMe controller is a 64-bit MMIO BAR: the next
/// register is the upper half. A non-zero upper dword is refused --
/// `boot.S` maps [3 GiB, 4 GiB) and nothing above 4 GiB (same refusal
/// as G0 / USB1). Lives here, not in pci.dart (sibling AHCI).
@bare
u64 nvmeReadBar0(u64 bus, u64 dev, u64 fn) {
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

/// One found-device line:
///
///     NVME 00:04.0 1B36:0010 01/08/02
///
/// Shape matches [pciReportDevice] / [usbReportDevice] so a harness
/// can parse BDF and vendor:device and compare them to QEMU's `info pci`
/// without a second encoding.
@bare
void nvmeReportDevice(u64 bus, u64 dev, u64 fn, u64 id, u64 classReg) {
  uartWrite(Rodata.addressOf(nvmeStrLine), u64(5));
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

///     NVME BAR FEBF0000
///
/// The address is the type-stripped BAR0 the kernel read from
/// configuration space. The harness compares it to QEMU `info pci`.
/// NVM0 matches this line exactly; NVM1 adds a second line.
@bare
void nvmeReportBar(u64 bar) {
  uartWrite(Rodata.addressOf(nvmeStrBar), u64(9));
  uartPutHex(bar, u64(8));
  uartNewline();
}

/// 32-bit MMIO load at [bar] + [off]. Every `Volatile` access is
/// emitted volatile (ADR-0044), which is what MMIO needs. NVM2's
/// completion poll of the CQ phase bit and CSTS.RDY goes through
/// this (GAP-0071).
@bare
u64 nvmeRegGet(u64 bar, u64 off) {
  return Volatile<u32>.fromAddress(bar + off).value.toU64();
}

/// 32-bit MMIO store at [bar] + [off]. Twin of [nvmeRegGet]. NVM1
/// never calls this; NVM2 writes CC, AQA, ASQ, ACQ and doorbells.
@bare
void nvmeRegPut(u64 bar, u64 off, u64 val) {
  Volatile<u32>.fromAddress(bar + off).value = val.toU32();
}

/// Poll [bar]+[off] until `(value & mask) == want`, or the iteration
/// bound expires. Returns the last value, or [nvmeTimedOut] with the
/// last value in the low bits. Same shape as `ahciWaitBits`.
@bare
u64 nvmeWaitBits(u64 bar, u64 off, u64 mask, u64 want) {
  u64 n = u64(nvmePollLimit);
  u64 v = u64(0);
  while (u64(0) < n) {
    v = nvmeRegGet(bar, off);
    if ((v & mask) == want) {
      return v;
    }
    n = n - u64(1);
  }
  return u64(nvmeTimedOut) | v;
}

/// CAP is 64 bits at BAR0+0. Two dword loads, low then high.
@bare
u64 nvmeCapGet(u64 bar) {
  final u64 lo = nvmeRegGet(bar, u64(nvmeRegCap));
  final u64 hi = nvmeRegGet(bar, u64(nvmeRegCap) + u64(4));
  return lo | (hi << u64(32));
}

///     NVME CAP 000000200F0107FF VS 00020000 MQES 07FF TO 0F
///
/// CAP and VS are loads. MQES and TO are decoded from CAP so a
/// canned qword cannot satisfy both the hex and the fields. Nothing
/// is written. The controller is not enabled.
@bare
void nvmeReportCap(u64 bar) {
  final u64 cap = nvmeCapGet(bar);
  final u64 vs = nvmeRegGet(bar, u64(nvmeRegVs));
  final u64 mqes = cap & u64(nvmeCapMqesMask);
  final u64 to = (cap >> u64(nvmeCapToShift)) & u64(nvmeCapToMask);
  uartWrite(Rodata.addressOf(nvmeStrCap), u64(9));
  uartPutHex(cap, u64(16));
  uartWrite(Rodata.addressOf(nvmeStrVs), u64(4));
  uartPutHex(vs, u64(8));
  uartWrite(Rodata.addressOf(nvmeStrMqes), u64(6));
  uartPutHex(mqes, u64(4));
  uartWrite(Rodata.addressOf(nvmeStrTo), u64(4));
  uartPutHex(to, u64(2));
  uartNewline();
}

/// `nvme` -- find an NVMe I/O controller, print BDF, BAR0, CAP and
/// VS, or print `NVME NONE`.
///
/// Runs in TASK context with interrupts enabled, like every other
/// command (ADR-0006). It is a handful of configuration reads and
/// three MMIO loads. Nothing here waits on a device, nothing is
/// written, and nothing is retained.
@bare
void nvmeReport() {
  final u64 bdf = nvmeFind();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nvmeStrNone), u64(10));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 id = pciRead32(bus, dev, fn, u64(pciRegId));
  final u64 classReg = pciRead32(bus, dev, fn, u64(pciRegClass));
  nvmeReportDevice(bus, dev, fn, id, classReg);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nvmeCmdMem)) < u64(nvmeCmdMem)) {
    uartWrite(Rodata.addressOf(nvmeStrNocmd), u64(11));
    return;
  }
  final u64 bar = nvmeReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrNobar), u64(11));
    return;
  }
  nvmeReportBar(bar);
  nvmeReportCap(bar);
}

/// Clear CC.EN and wait until CSTS.RDY is 0. Returns 0, or 1 on
/// timeout. A controller that is already idle is a no-op.
@bare
u64 nvmeDisable(u64 bar) {
  final u64 cc = nvmeRegGet(bar, u64(nvmeRegCc));
  if ((cc & u64(nvmeCcEn)) == u64(0)) {
    return u64(0);
  }
  nvmeRegPut(bar, u64(nvmeRegCc), cc & u64(nvmeCcEnClr));
  final u64 rdy = nvmeWaitBits(
      bar, u64(nvmeRegCsts), u64(nvmeCstsRdy), u64(0));
  if (rdy >= u64(nvmeTimedOut)) {
    return u64(1);
  }
  return u64(0);
}

/// Programme an admin pair of [aqa] 0-based size and set CC.EN.
/// [asq] and [acq] are page-aligned frames. Returns 0, or 1 on a
/// CSTS.RDY timeout. NVM2 uses two entries; NVM3 uses four so
/// Identify + Create CQ + Create SQ do not wrap the phase bit.
@bare
u64 nvmeEnableAqa(u64 bar, u64 asq, u64 acq, u64 aqa) {
  nvmeRegPut(bar, u64(nvmeRegIntms), u64(0xFFFFFFFF));
  nvmeRegPut(bar, u64(nvmeRegAqa), aqa);
  nvmeRegPut(bar, u64(nvmeRegAsq), asq);
  nvmeRegPut(bar, u64(nvmeRegAsq) + u64(4), u64(0));
  nvmeRegPut(bar, u64(nvmeRegAcq), acq);
  nvmeRegPut(bar, u64(nvmeRegAcq) + u64(4), u64(0));
  nvmeRegPut(bar, u64(nvmeRegCc), u64(nvmeCcAdmin));
  final u64 rdy = nvmeWaitBits(
      bar, u64(nvmeRegCsts), u64(nvmeCstsRdy), u64(nvmeCstsRdy));
  if (rdy >= u64(nvmeTimedOut)) {
    return u64(1);
  }
  return u64(0);
}

/// Programme a two-entry admin pair and set CC.EN. NVM2's path.
@bare
u64 nvmeEnable(u64 bar, u64 asq, u64 acq) {
  return nvmeEnableAqa(bar, asq, acq, u64(nvmeAqaTwo));
}

/// One Identify Controller SQE at slot 0: opcode 06h, CNS=1, CID=1,
/// PRP1 = [ident]. The rest of the 64-byte slot is already zero.
@bare
void nvmeBuildIdentify(u64 asq, u64 ident) {
  Volatile<u32>.fromAddress(asq + u64(0)).value =
      ((u64(nvmeCid) << u64(16)) | u64(nvmeOpcIdentify)).toU32();
  Volatile<u32>.fromAddress(asq + u64(nvmeSqePrp1)).value = ident.toU32();
  Volatile<u32>.fromAddress(asq + u64(nvmeSqeCdw10)).value =
      u64(nvmeCnsController).toU32();
}

/// Wait until the CQE at [cq] + [off] has its phase bit set.
/// Returns the DW3 value, or [nvmeTimedOut] on expiry. The load
/// is `Volatile<u32>`. NVM2 waits slot 0 ([off] = 0); NVM3 waits
/// admin slots 0..2 and I/O slot 0.
@bare
u64 nvmeWaitCqOff(u64 cq, u64 off) {
  u64 n = u64(nvmePollLimit);
  u64 dw3 = u64(0);
  while (u64(0) < n) {
    dw3 = Volatile<u32>.fromAddress(cq + off + u64(nvmeCqDw3)).value.toU64();
    if ((dw3 & u64(nvmeCqPhase)) > u64(0)) {
      return dw3;
    }
    n = n - u64(1);
  }
  return u64(nvmeTimedOut) | dw3;
}

/// Wait until CQ slot 0's phase bit is set. NVM2's path.
@bare
u64 nvmeWaitCq(u64 acq) {
  return nvmeWaitCqOff(acq, u64(0));
}

/// `nvme id` -- one Identify Controller on the admin queue.
///
/// Runs in TASK context. Three frames from `allocFrame()` hold the
/// admin SQ, the admin CQ and the 4096-byte Identify buffer. Never
/// freed: 12 KiB of 128 MiB, held for the boot. The SQ0 doorbell
/// store is the submission.
@bare
void nvmeIdentify() {
  final u64 bdf = nvmeFind();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nvmeStrNone), u64(10));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nvmeCmdMem)) < u64(nvmeCmdMem)) {
    uartWrite(Rodata.addressOf(nvmeStrNocmd), u64(11));
    return;
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nvmeCmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(nvmeCmdBme)) < u64(nvmeCmdBme)) {
    uartWrite(Rodata.addressOf(nvmeStrStuck), u64(15));
    return;
  }
  final u64 bar = nvmeReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrNobar), u64(11));
    return;
  }

  final u64 asq = allocFrame();
  if (asq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 acq = allocFrame();
  if (acq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 ident = allocFrame();
  if (ident < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  vmZeroFrame(asq);
  vmZeroFrame(acq);
  vmZeroFrame(ident);

  if (nvmeDisable(bar) > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }
  if (nvmeEnable(bar, asq, acq) > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }

  nvmeBuildIdentify(asq, ident);
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl), u64(1));

  final u64 dw3 = nvmeWaitCq(acq);
  if (dw3 >= u64(nvmeTimedOut)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }
  final u64 sts = dw3 >> u64(17);
  if (sts > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrSts), u64(9));
    uartPutHex(sts, u64(8));
    uartNewline();
    return;
  }

  final u64 cap = nvmeCapGet(bar);
  final u64 dstrd = (cap >> u64(nvmeCapDstrdShift)) & u64(nvmeCapDstrdMask);
  final u64 cqdbl = u64(nvmeRegSq0Tdbl) + (u64(4) << dstrd);
  nvmeRegPut(bar, cqdbl, u64(1));

  final u64 vid = Volatile<u32>.fromAddress(ident).value.toU64() & u64(0xFFFF);
  final u64 nn = Volatile<u32>.fromAddress(ident + u64(nvmeIdOffNn)).value.toU64();
  uartWrite(Rodata.addressOf(nvmeStrIdSn), u64(11));
  u64 i = u64(0);
  while (i < u64(nvmeIdSnBytes)) {
    uartPutHex(
        Volatile<u8>.fromAddress(ident + u64(nvmeIdOffSn) + i).value.toU64(),
        u64(2));
    i = i + u64(1);
  }
  uartWrite(Rodata.addressOf(nvmeStrVid), u64(5));
  uartPutHex(vid, u64(4));
  uartWrite(Rodata.addressOf(nvmeStrNn), u64(4));
  uartPutHex(nn, u64(8));
  uartNewline();
}

/// Create I/O CQ SQE at [sqe]: opcode 05h, QID=1, QSIZE=1, PC=1,
/// IEN=0, PRP1 = [iocq]. The rest of the 64-byte slot is already zero.
@bare
void nvmeBuildCreateCq(u64 sqe, u64 iocq) {
  Volatile<u32>.fromAddress(sqe).value =
      ((u64(nvmeCidCq) << u64(16)) | u64(nvmeOpcCreateCq)).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqePrp1)).value = iocq.toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw10)).value =
      u64(nvmeIoQid1).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw11)).value =
      u64(nvmeCreateCqPc).toU32();
}

/// Create I/O SQ SQE at [sqe]: opcode 01h, QID=1, QSIZE=1, PC=1,
/// CQID=1, PRP1 = [iosq].
@bare
void nvmeBuildCreateSq(u64 sqe, u64 iosq) {
  Volatile<u32>.fromAddress(sqe).value =
      ((u64(nvmeCidSq) << u64(16)) | u64(nvmeOpcCreateSq)).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqePrp1)).value = iosq.toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw10)).value =
      u64(nvmeIoQid1).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw11)).value =
      u64(nvmeIoQid1).toU32();
}

/// NVM Read SQE at [sqe]: opcode 02h, NSID=1, SLBA=[nvmeReadLba],
/// NLB=0 (one block), PRP1 = [data]. CDW11/CDW12 stay zero because
/// the frame was zeroed.
@bare
void nvmeBuildRead(u64 sqe, u64 data) {
  Volatile<u32>.fromAddress(sqe).value =
      ((u64(nvmeCidRd) << u64(16)) | u64(nvmeOpcRead)).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeNsid)).value =
      u64(nvmeNsid1).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqePrp1)).value = data.toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw10)).value =
      u64(nvmeReadLba).toU32();
}

/// Submit one admin command whose SQE is already at [slot], ring
/// the SQ0 doorbell with [tail], wait that slot's CQE, ring the
/// admin CQ doorbell with the same [tail]. Returns 0, or 1 after
/// printing TMO / STS. One-at-a-time: CQ head equals SQ tail.
@bare
u64 nvmeKickAdmin(u64 bar, u64 acq, u64 slot, u64 tail, u64 stride) {
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl), tail);
  final u64 dw3 = nvmeWaitCqOff(acq, slot * u64(nvmeCqeBytes));
  if (dw3 >= u64(nvmeTimedOut)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return u64(1);
  }
  final u64 sts = dw3 >> u64(17);
  if (sts > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrSts), u64(9));
    uartPutHex(sts, u64(8));
    uartNewline();
    return u64(1);
  }
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + stride, tail);
  return u64(0);
}

/// `nvme rd` -- Identify, then one I/O-queue sector read of LBA 7.
///
/// Runs in TASK context. Six frames: admin SQ/CQ, Identify, I/O SQ,
/// I/O CQ, sector. Never freed. The printed DATA bytes come from
/// the sector frame the controller DMA'd, not from Identify.
@bare
void nvmeRead() {
  final u64 bdf = nvmeFind();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nvmeStrNone), u64(10));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nvmeCmdMem)) < u64(nvmeCmdMem)) {
    uartWrite(Rodata.addressOf(nvmeStrNocmd), u64(11));
    return;
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nvmeCmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(nvmeCmdBme)) < u64(nvmeCmdBme)) {
    uartWrite(Rodata.addressOf(nvmeStrStuck), u64(15));
    return;
  }
  final u64 bar = nvmeReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrNobar), u64(11));
    return;
  }

  final u64 asq = allocFrame();
  if (asq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 acq = allocFrame();
  if (acq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 ident = allocFrame();
  if (ident < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 iosq = allocFrame();
  if (iosq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 iocq = allocFrame();
  if (iocq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 data = allocFrame();
  if (data < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  vmZeroFrame(asq);
  vmZeroFrame(acq);
  vmZeroFrame(ident);
  vmZeroFrame(iosq);
  vmZeroFrame(iocq);
  vmZeroFrame(data);

  if (nvmeDisable(bar) > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }
  if (nvmeEnableAqa(bar, asq, acq, u64(nvmeAqaFour)) > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }

  final u64 cap = nvmeCapGet(bar);
  final u64 dstrd = (cap >> u64(nvmeCapDstrdShift)) & u64(nvmeCapDstrdMask);
  final u64 stride = u64(4) << dstrd;

  nvmeBuildIdentify(asq, ident);
  if (nvmeKickAdmin(bar, acq, u64(0), u64(1), stride) > u64(0)) {
    return;
  }

  nvmeBuildCreateCq(asq + u64(nvmeSqeBytes), iocq);
  if (nvmeKickAdmin(bar, acq, u64(1), u64(2), stride) > u64(0)) {
    return;
  }

  nvmeBuildCreateSq(asq + (u64(2) * u64(nvmeSqeBytes)), iosq);
  if (nvmeKickAdmin(bar, acq, u64(2), u64(3), stride) > u64(0)) {
    return;
  }

  nvmeBuildRead(iosq, data);
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + (u64(2) * stride), u64(1));
  final u64 dw3 = nvmeWaitCqOff(iocq, u64(0));
  if (dw3 >= u64(nvmeTimedOut)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }
  final u64 sts = dw3 >> u64(17);
  if (sts > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrSts), u64(9));
    uartPutHex(sts, u64(8));
    uartNewline();
    return;
  }
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + (u64(3) * stride), u64(1));

  uartWrite(Rodata.addressOf(nvmeStrRd), u64(8));
  uartPutHex(u64(nvmeReadLba), u64(8));
  uartWrite(Rodata.addressOf(nvmeStrData), u64(6));
  u64 i = u64(0);
  while (i < u64(nvmePrintBytes)) {
    uartPutHex(
        Volatile<u8>.fromAddress(data + i).value.toU64(), u64(2));
    i = i + u64(1);
  }
  uartNewline();
}

/// NVM Write SQE at [sqe]: opcode 01h, NSID=1, SLBA=[nvmeWriteLba],
/// NLB=0 (one block), PRP1 = [data]. CDW11/CDW12 stay zero because
/// the frame was zeroed. Admin Create SQ is also 01h; this is the
/// I/O command set.
@bare
void nvmeBuildWrite(u64 sqe, u64 data) {
  Volatile<u32>.fromAddress(sqe).value =
      ((u64(nvmeCidWr) << u64(16)) | u64(nvmeOpcWrite)).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeNsid)).value =
      u64(nvmeNsid1).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqePrp1)).value = data.toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw10)).value =
      u64(nvmeWriteLba).toU32();
}

/// Submit one I/O command whose SQE is already at [slot] of the
/// QID-1 SQ, ring SQ1's doorbell with [tail], wait that slot's CQE
/// on [iocq], ring CQ1's doorbell with the same [tail]. Returns 0,
/// or 1 after printing TMO / STS.
@bare
u64 nvmeKickIo(u64 bar, u64 iocq, u64 slot, u64 tail, u64 stride) {
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + (u64(2) * stride), tail);
  final u64 dw3 = nvmeWaitCqOff(iocq, slot * u64(nvmeCqeBytes));
  if (dw3 >= u64(nvmeTimedOut)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return u64(1);
  }
  final u64 sts = dw3 >> u64(17);
  if (sts > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrSts), u64(9));
    uartPutHex(sts, u64(8));
    uartNewline();
    return u64(1);
  }
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + (u64(3) * stride), tail);
  return u64(0);
}

/// `nvme wr` -- Identify, then one I/O-queue sector write of LBA 11.
///
/// Runs in TASK context. Six frames, same as `nvme rd`. The I/O
/// pair is four entries so NVM Read of the planted LBA 7 plus NVM
/// Write of LBA 11 do not wrap the phase bit. The bytes written
/// are the planted sector, not a kernel constant. The host image
/// is the judge; the printed DATA is the same 16 bytes.
@bare
void nvmeWrite() {
  final u64 bdf = nvmeFind();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nvmeStrNone), u64(10));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nvmeCmdMem)) < u64(nvmeCmdMem)) {
    uartWrite(Rodata.addressOf(nvmeStrNocmd), u64(11));
    return;
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nvmeCmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(nvmeCmdBme)) < u64(nvmeCmdBme)) {
    uartWrite(Rodata.addressOf(nvmeStrStuck), u64(15));
    return;
  }
  final u64 bar = nvmeReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrNobar), u64(11));
    return;
  }

  final u64 asq = allocFrame();
  if (asq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 acq = allocFrame();
  if (acq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 ident = allocFrame();
  if (ident < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 iosq = allocFrame();
  if (iosq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 iocq = allocFrame();
  if (iocq < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  final u64 data = allocFrame();
  if (data < u64(1)) {
    uartWrite(Rodata.addressOf(nvmeStrNofrm), u64(11));
    return;
  }
  vmZeroFrame(asq);
  vmZeroFrame(acq);
  vmZeroFrame(ident);
  vmZeroFrame(iosq);
  vmZeroFrame(iocq);
  vmZeroFrame(data);

  if (nvmeDisable(bar) > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }
  if (nvmeEnableAqa(bar, asq, acq, u64(nvmeAqaFour)) > u64(0)) {
    uartWrite(Rodata.addressOf(nvmeStrTmo), u64(9));
    return;
  }

  final u64 cap = nvmeCapGet(bar);
  final u64 dstrd = (cap >> u64(nvmeCapDstrdShift)) & u64(nvmeCapDstrdMask);
  final u64 stride = u64(4) << dstrd;

  nvmeBuildIdentify(asq, ident);
  if (nvmeKickAdmin(bar, acq, u64(0), u64(1), stride) > u64(0)) {
    return;
  }

  nvmeBuildCreateCq(asq + u64(nvmeSqeBytes), iocq);
  Volatile<u32>.fromAddress(
          asq + u64(nvmeSqeBytes) + u64(nvmeSqeCdw10))
      .value = u64(nvmeIoQid4).toU32();
  if (nvmeKickAdmin(bar, acq, u64(1), u64(2), stride) > u64(0)) {
    return;
  }

  nvmeBuildCreateSq(asq + (u64(2) * u64(nvmeSqeBytes)), iosq);
  Volatile<u32>.fromAddress(
          asq + (u64(2) * u64(nvmeSqeBytes)) + u64(nvmeSqeCdw10))
      .value = u64(nvmeIoQid4).toU32();
  if (nvmeKickAdmin(bar, acq, u64(2), u64(3), stride) > u64(0)) {
    return;
  }

  nvmeBuildRead(iosq, data);
  if (nvmeKickIo(bar, iocq, u64(0), u64(1), stride) > u64(0)) {
    return;
  }

  nvmeBuildWrite(iosq + u64(nvmeSqeBytes), data);
  if (nvmeKickIo(bar, iocq, u64(1), u64(2), stride) > u64(0)) {
    return;
  }

  uartWrite(Rodata.addressOf(nvmeStrWr), u64(8));
  uartPutHex(u64(nvmeWriteLba), u64(8));
  uartWrite(Rodata.addressOf(nvmeStrData), u64(6));
  u64 i = u64(0);
  while (i < u64(nvmePrintBytes)) {
    uartPutHex(
        Volatile<u8>.fromAddress(data + i).value.toU64(), u64(2));
    i = i + u64(1);
  }
  uartNewline();
}

/// Wait until the CQE at [cq]+[off] has `(DW3 & phase) == [want]`.
/// NVM2/NVM3 wait for phase 1 ([want] = [nvmeCqPhase]). After a
/// wrap the controller writes phase 0, so FAT's reused pair must
/// be able to wait for either. Silent: FAT I/O prints nothing.
@bare
u64 nvmeWaitCqPhase(u64 cq, u64 off, u64 want) {
  u64 n = u64(nvmePollLimit);
  u64 dw3 = u64(0);
  while (u64(0) < n) {
    dw3 = Volatile<u32>.fromAddress(cq + off + u64(nvmeCqDw3)).value.toU64();
    if ((dw3 & u64(nvmeCqPhase)) == want) {
      return dw3;
    }
    n = n - u64(1);
  }
  return u64(nvmeTimedOut) | dw3;
}

/// One NVM Read or Write SQE at [sqe]: [opc] is 02h or 01h, NSID=1,
/// SLBA=[lba], NLB=0, PRP1 = [data]. Used by FAT. `nvmeBuildRead`
/// and `nvmeBuildWrite` stay hardcoded to LBA 7 / 11 for NVM3/NVM4.
@bare
void nvmeBuildIo(u64 sqe, u64 opc, u64 cid, u64 data, u64 lba) {
  Volatile<u32>.fromAddress(sqe).value = ((cid << u64(16)) | opc).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeNsid)).value =
      u64(nvmeNsid1).toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqePrp1)).value = data.toU32();
  Volatile<u32>.fromAddress(sqe + u64(nvmeSqeCdw10)).value = lba.toU32();
}

/// 512 bytes, one byte at a time. DCDart has no memcpy.
@bare
void nvmeCopy512(u64 dst, u64 src) {
  u64 i = u64(0);
  while (i < u64(512)) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Zero one 64-byte SQE so a reused slot cannot keep a previous
/// LBA or PRP.
@bare
void nvmeZeroSqe(u64 sqe) {
  u64 i = u64(0);
  while (i < u64(nvmeSqeBytes)) {
    Volatile<u8>.fromAddress(sqe + i).value = u8(0);
    i = i + u64(1);
  }
}

/// Admin kick that returns a status and prints nothing. FAT must
/// not emit `NVME TMO` / `NVME STS` on a `cat`.
@bare
u64 nvmeKickAdminQuiet(u64 bar, u64 acq, u64 slot, u64 tail, u64 stride) {
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl), tail);
  final u64 dw3 = nvmeWaitCqOff(acq, slot * u64(nvmeCqeBytes));
  if (dw3 >= u64(nvmeTimedOut)) {
    return u64(1);
  }
  if ((dw3 >> u64(17)) > u64(0)) {
    return u64(1);
  }
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + stride, tail);
  return u64(0);
}

/// One I/O command on the NVM5 session. [st] is the bounce frame
/// whose high half holds BAR / stride / queues / tail. Returns 0
/// or 1. Silent.
@bare
u64 nvmeIoSubmit(u64 st, u64 opc, u64 lba) {
  final u64 bar = Pointer<u64>.fromAddress(st + u64(nvmeIoOffBar)).value;
  final u64 stride = Pointer<u64>.fromAddress(st + u64(nvmeIoOffStride)).value;
  final u64 iosq = Pointer<u64>.fromAddress(st + u64(nvmeIoOffIosq)).value;
  final u64 iocq = Pointer<u64>.fromAddress(st + u64(nvmeIoOffIocq)).value;
  final u64 tail = Pointer<u64>.fromAddress(st + u64(nvmeIoOffTail)).value;
  final u64 qsize = Pointer<u64>.fromAddress(st + u64(nvmeIoOffQsize)).value;
  final u64 slot = tail & (qsize - u64(1));
  final u64 sqe = iosq + (slot * u64(nvmeSqeBytes));
  nvmeZeroSqe(sqe);
  nvmeBuildIo(sqe, opc, (tail + u64(1)) & u64(0xFFFF), st, lba);
  final u64 newTail = tail + u64(1);
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + (u64(2) * stride), newTail);
  u64 want = u64(nvmeCqPhase);
  if (((tail >> u64(6)) & u64(1)) > u64(0)) {
    want = u64(0);
  }
  final u64 dw3 = nvmeWaitCqPhase(iocq, slot * u64(nvmeCqeBytes), want);
  if (dw3 >= u64(nvmeTimedOut)) {
    return u64(1);
  }
  if ((dw3 >> u64(17)) > u64(0)) {
    return u64(1);
  }
  nvmeRegPut(bar, u64(nvmeRegSq0Tdbl) + (u64(3) * stride), newTail);
  Pointer<u64>.fromAddress(st + u64(nvmeIoOffTail)).value = newTail;
  return u64(0);
}

/// NVM Read of [lba] into [dst] through the session at [st].
@bare
u64 nvmeIoRead(u64 st, u64 lba, u64 dst) {
  if (st < u64(1)) {
    return u64(1);
  }
  if (nvmeIoSubmit(st, u64(nvmeOpcRead), lba) > u64(0)) {
    return u64(1);
  }
  nvmeCopy512(dst, st);
  return u64(0);
}

/// NVM Write of [src] to [lba] through the session at [st].
@bare
u64 nvmeIoWrite(u64 st, u64 lba, u64 src) {
  if (st < u64(1)) {
    return u64(1);
  }
  nvmeCopy512(st, src);
  if (nvmeIoSubmit(st, u64(nvmeOpcWrite), lba) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

/// Enable admin + a 64-entry I/O pair. Returns the bounce/session
/// frame, or 0. Prints nothing. Six `allocFrame` calls, same as
/// `nvme rd`. The session words live at offset 512 of the bounce
/// frame so FAT can keep one pointer in a spare `fat_store` word
/// and steal no `.bss`.
@bare
u64 nvmeIoSetup() {
  final u64 bdf = nvmeFind();
  if (bdf == u64(pciBdfNone)) {
    return u64(0);
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nvmeCmdMem)) < u64(nvmeCmdMem)) {
    return u64(0);
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nvmeCmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(nvmeCmdBme)) < u64(nvmeCmdBme)) {
    return u64(0);
  }
  final u64 bar = nvmeReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    return u64(0);
  }

  final u64 asq = allocFrame();
  if (asq < u64(1)) {
    return u64(0);
  }
  final u64 acq = allocFrame();
  if (acq < u64(1)) {
    return u64(0);
  }
  final u64 ident = allocFrame();
  if (ident < u64(1)) {
    return u64(0);
  }
  final u64 iosq = allocFrame();
  if (iosq < u64(1)) {
    return u64(0);
  }
  final u64 iocq = allocFrame();
  if (iocq < u64(1)) {
    return u64(0);
  }
  final u64 data = allocFrame();
  if (data < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(asq);
  vmZeroFrame(acq);
  vmZeroFrame(ident);
  vmZeroFrame(iosq);
  vmZeroFrame(iocq);
  vmZeroFrame(data);

  if (nvmeDisable(bar) > u64(0)) {
    return u64(0);
  }
  if (nvmeEnableAqa(bar, asq, acq, u64(nvmeAqaFour)) > u64(0)) {
    return u64(0);
  }

  final u64 cap = nvmeCapGet(bar);
  final u64 dstrd = (cap >> u64(nvmeCapDstrdShift)) & u64(nvmeCapDstrdMask);
  final u64 stride = u64(4) << dstrd;

  nvmeBuildIdentify(asq, ident);
  if (nvmeKickAdminQuiet(bar, acq, u64(0), u64(1), stride) > u64(0)) {
    return u64(0);
  }

  nvmeBuildCreateCq(asq + u64(nvmeSqeBytes), iocq);
  Volatile<u32>.fromAddress(
          asq + u64(nvmeSqeBytes) + u64(nvmeSqeCdw10))
      .value = u64(nvmeIoQid64).toU32();
  if (nvmeKickAdminQuiet(bar, acq, u64(1), u64(2), stride) > u64(0)) {
    return u64(0);
  }

  nvmeBuildCreateSq(asq + (u64(2) * u64(nvmeSqeBytes)), iosq);
  Volatile<u32>.fromAddress(
          asq + (u64(2) * u64(nvmeSqeBytes)) + u64(nvmeSqeCdw10))
      .value = u64(nvmeIoQid64).toU32();
  if (nvmeKickAdminQuiet(bar, acq, u64(2), u64(3), stride) > u64(0)) {
    return u64(0);
  }

  Pointer<u64>.fromAddress(data + u64(nvmeIoOffBar)).value = bar;
  Pointer<u64>.fromAddress(data + u64(nvmeIoOffStride)).value = stride;
  Pointer<u64>.fromAddress(data + u64(nvmeIoOffIosq)).value = iosq;
  Pointer<u64>.fromAddress(data + u64(nvmeIoOffIocq)).value = iocq;
  Pointer<u64>.fromAddress(data + u64(nvmeIoOffTail)).value = u64(0);
  Pointer<u64>.fromAddress(data + u64(nvmeIoOffQsize)).value = u64(nvmeIoQsize);
  return data;
}
