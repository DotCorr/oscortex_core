// core/kernel/ahci.dart
//
// oscortex_core A0 + A1: the kernel finds an AHCI HBA on PCI, reads
// CAP through BAR5 (ABAR), and issues one READ DMA EXT.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// The architecture is docs/decisions/0069-the-kernel-finds-the-ahci-hba.md
// and docs/decisions/0077-one-ahci-sector-read.md. The design is
// docs/design/storage.md §2.2. This is a second path next to ATA PIO
// (`ata.dart`). It does not replace it.
//
// ---------------------------------------------------------------------------
// ZERO DONATED `.bss`. THAT IS THE WHOLE OF THE MERGE RULE.
// ---------------------------------------------------------------------------
// `part 'ahci.dart'` sits AFTER `part 'nvme.dart'` and BEFORE
// `part 'wmevent.dart'`. D7 owns last place: `wmeventStore` is the newest
// `@bss` block, and stealing that slot would move every harness that
// measures D7 to the end of `.bss`. A0 prints from locals. A1's command
// list, Received FIS, command table and sector buffer live in one
// `allocFrame()` (identity-mapped, so the physical address IS the
// virtual address). Nothing here donates `.bss`.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE DOES, AND WHAT IT DOES NOT
// ---------------------------------------------------------------------------
// A0: walk bus 0 for class 01/06/01 (SATA / AHCI prog-IF), or for the
// QEMU ICH9 id 8086:2922 / QEMU AHCI id 1B36:0001. Read BAR5 (ABAR),
// load CAP, print the BDF, the BAR, CAP, and the port count
// (CAP.NP + 1).
//
// A1: set bus-master through `pciWrite32`, stop the first implemented
// port that has a SATA disk, point PxCLB / PxFB at one frame, start
// the port, issue READ DMA EXT (0x25) for LBA 7, wait on PxCI while
// watching PxIS.TFES. Every MMIO load in that poll is `Volatile<u32>`
// (GAP-0071: a cacheable mapping is entitled to serve a plain load
// from the first fetch; Volatile forces a device access each time).
//
// A2 (ADR-0137): [ahciIoSetup] / [ahciIoRead] / [ahciIoWrite] are
// the FAT door. Arbitrary LBA, one persistent frame, silent.
// Class 01/06/01 is the match; QEMU ICH9 is a stand-in, not a SKU
// success condition. It does not use NCQ, does not remap the PCI
// hole uncached, and does not touch ata.dart.
//
// ---------------------------------------------------------------------------
// WHY THE PRINT IS A COMMAND, NOT A BOOT LINE
// ---------------------------------------------------------------------------
// QEMU's default `-M pc` has no AHCI (storage.md fact 15: every disk
// harness attaches the PIIX3 IDE). A boot-time `AHCI NONE` would sit
// in every session golden after `M1 END`. The prints are [ahciReport]
// (`ahci`) and [ahciRead] (`ahci read`), neither of which is in `help`
// (GAP-0105 / GAP-0115). [ahciInit] is called from `kmain` and prints
// nothing, so `m1-interrupts`' 544-byte golden is untouched.

part of 'kmain.dart';

/// PCI class 0x01 subclass 0x06 is SATA. Prog-IF 0x01 is AHCI.
/// Prog-IF 0x00 is vendor-specific; 0x02 is Serial Storage Bus.
/// A class-only match would claim those as AHCI.
const int ahciClassStorage = 0x01;
const int ahciSubclassSata = 0x06;
const int ahciProgIfAhci = 0x01;

/// QEMU `-device ahci` / `ich9-ahci` is Intel ICH9, 8086:2922.
/// Some QEMU builds expose a generic AHCI as 1B36:0001.
const int ahciVendIch9 = 0x8086;
const int ahciDevIch9 = 0x2922;
const int ahciVendQemu = 0x1B36;
const int ahciDevQemu = 0x0001;

/// Command-register bit 1: memory decode. A0 loads CAP through ABAR,
/// so this bit must be set. Bit 2 (bus-master) is a DMA fact: A1
/// writes MEM|BME before the first DMA. A0 does not write 0xCFC.
const int ahciCmdMem = 0x02;
const int ahciCmdBme = 0x04;
const int ahciCmdMemBme = 0x06;

/// ABAR is BAR5 (config offset 0x24). storage.md §2.2.
const int ahciBarIndex = 5;

/// Global HBA registers at ABAR + offset.
const int ahciRegCap = 0x00;
const int ahciRegGhc = 0x04;
const int ahciRegIs = 0x08;
const int ahciRegPi = 0x0C;
const int ahciCapNpMask = 0x1F;
const int ahciGhcAe = 0x80000000;

/// Per-port registers at ABAR + 0x100 + port*0x80.
const int ahciPortBase = 0x100;
const int ahciPxClb = 0x00;
const int ahciPxClbu = 0x04;
const int ahciPxFb = 0x08;
const int ahciPxFbu = 0x0C;
const int ahciPxIs = 0x10;
const int ahciPxIe = 0x14;
const int ahciPxCmd = 0x18;
const int ahciPxTfd = 0x20;
const int ahciPxSig = 0x24;
const int ahciPxSsts = 0x28;
const int ahciPxSerr = 0x30;
const int ahciPxCi = 0x38;

const int ahciPxCmdSt = 0x0001;
const int ahciPxCmdStClr = 0xFFFFFFFE;
const int ahciPxCmdFre = 0x0010;
const int ahciPxCmdFreClr = 0xFFFFFFEF;
const int ahciPxCmdFr = 0x4000;
const int ahciPxCmdCr = 0x8000;
const int ahciPxIsTfes = 0x40000000;
const int ahciPxTfdBsyDrq = 0x88;
const int ahciSstsDetMask = 0x0F;
const int ahciSstsDetPhyon = 0x03;
const int ahciSstsIpmMask = 0x0F00;
const int ahciSstsIpmActive = 0x0100;
const int ahciSigAta = 0x00000101;

/// Frame layout (storage.md §2.3): one 4 KiB frame holds the list,
/// the Received FIS, the command table, and the sector.
const int ahciOffCl = 0;
const int ahciOffFis = 1024;
const int ahciOffCt = 2048;
const int ahciOffData = 2560;
const int ahciOffPrdt = 128;

/// Command header DW0: PRDTL=1, CFL=5 (Register H2D FIS is 5 dwords).
const int ahciChDw0 = 0x00010005;

/// Register H2D FIS. Command 0x25 is READ DMA EXT. 0x35 is
/// WRITE DMA EXT. Write sets command-header W (bit 6).
const int ahciFisH2d = 0x27;
const int ahciFisCmdBit = 0x80;
const int ahciAtaReadDmaExt = 0x25;
const int ahciOpcWriteExt = 0x35;
const int ahciChDw0Write = 0x00010045;
const int ahciDevLba = 0x40;
const int ahciPrdDbc = 511;
const int ahciSectorBytes = 512;
const int ahciReadLba = 7;
const int ahciPrintBytes = 16;

/// FAT session words live after the 512-byte bounce (2560+512).
/// One pointer in `fat_store` word 31 names this frame.
const int ahciIoOffBar = 3072;
const int ahciIoOffPoff = 3080;

/// Same bound as `ataWait` / `nicWaitByte`: 2^21 iterations, not a
/// duration (GAP-0073). Returned high bit distinguishes a timeout
/// from a register value.
const int ahciPollLimit = 0x200000;
const int ahciTimedOut = 0x100000000;

const int ahciSlotOk = 0;
const int ahciSlotTfes = 1;
const int ahciSlotTmo = 2;

/// Hidden command name. Not in `help` (goldens contain shellStrHelp).
///
/// `"ahci"` -- 4 bytes.
@rodata
final List<u8> ahciStrCmd = const [
  u8(0x61), u8(0x68), u8(0x63), u8(0x69),
];

/// `"ahci read"` -- 9 bytes. Longest-first so `ahci` cannot swallow it.
@rodata
final List<u8> ahciStrCmdRead = const [
  u8(0x61), u8(0x68), u8(0x63), u8(0x69), u8(0x20),
  u8(0x72), u8(0x65), u8(0x61), u8(0x64),
];

/// Found-device line prefix.
///
/// `"AHCI "` -- 5 bytes.
@rodata
final List<u8> ahciStrDev = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
];

/// Absent-device line. The negative control greps this and forbids any
/// `AHCI ` device line on the same boot.
///
/// `"AHCI NONE\n"` -- 10 bytes.
@rodata
final List<u8> ahciStrNone = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// Memory-decode is clear. A0 cannot load ABAR.
///
/// `"AHCI NOCMD\n"` -- 11 bytes.
@rodata
final List<u8> ahciStrNocmd = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x43), u8(0x4D), u8(0x44), u8(0x0A),
];

/// BAR5 is I/O or unimplemented.
///
/// `"AHCI NOBAR\n"` -- 11 bytes.
@rodata
final List<u8> ahciStrNobar = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x42), u8(0x41), u8(0x52), u8(0x0A),
];

/// `"AHCI BAR "` -- 9 bytes.
@rodata
final List<u8> ahciStrBar = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x42), u8(0x41), u8(0x52), u8(0x20),
];

/// `" CAP "` -- 5 bytes.
@rodata
final List<u8> ahciStrCap = const [
  u8(0x20), u8(0x43), u8(0x41), u8(0x50), u8(0x20),
];

/// `" PORTS "` -- 7 bytes.
@rodata
final List<u8> ahciStrPorts = const [
  u8(0x20), u8(0x50), u8(0x4F), u8(0x52),
  u8(0x54), u8(0x53), u8(0x20),
];

/// `"AHCI NOFRM\n"` -- 11 bytes. `allocFrame` returned 0.
@rodata
final List<u8> ahciStrNofrm = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x46), u8(0x52), u8(0x4D), u8(0x0A),
];

/// `"AHCI NOPORT\n"` -- 12 bytes. PI has no disk.
@rodata
final List<u8> ahciStrNoport = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x50), u8(0x4F),
  u8(0x52), u8(0x54), u8(0x0A),
];

/// `"AHCI TFES "` -- 10 bytes. Then PxTFD.
@rodata
final List<u8> ahciStrTfes = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x54), u8(0x46), u8(0x45), u8(0x53), u8(0x20),
];

/// `"AHCI TMO\n"` -- 9 bytes.
@rodata
final List<u8> ahciStrTmo = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x54), u8(0x4D), u8(0x4F), u8(0x0A),
];

/// `"AHCI CMD STUCK\n"` -- 15 bytes. BME did not stick.
@rodata
final List<u8> ahciStrStuck = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
  u8(0x53), u8(0x54), u8(0x55), u8(0x43), u8(0x4B), u8(0x0A),
];

/// `"AHCI READ "` -- 10 bytes.
@rodata
final List<u8> ahciStrRead = const [
  u8(0x41), u8(0x48), u8(0x43), u8(0x49), u8(0x20),
  u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x20),
];

/// `" PRDBC "` -- 7 bytes.
@rodata
final List<u8> ahciStrPrdbc = const [
  u8(0x20), u8(0x50), u8(0x52), u8(0x44),
  u8(0x42), u8(0x43), u8(0x20),
];

/// `" DATA "` -- 6 bytes.
@rodata
final List<u8> ahciStrData = const [
  u8(0x20), u8(0x44), u8(0x41), u8(0x54),
  u8(0x41), u8(0x20),
];

/// Called from `kmain` with the other silent inits. A0/A1 have no `.bss`
/// to zero and must print nothing: `m1-interrupts` asserts the entire
/// 544-byte capture. The prints are [ahciReport] and [ahciRead].
@bare
void ahciInit() {
}

/// 1 if [id] / [classReg] is an AHCI HBA this probe will name.
@bare
u64 ahciIsHba(u64 id, u64 classReg) {
  if (((classReg >> u64(24)) & u64(0xFF)) == u64(ahciClassStorage)) {
    if (((classReg >> u64(16)) & u64(0xFF)) == u64(ahciSubclassSata)) {
      if (((classReg >> u64(8)) & u64(0xFF)) == u64(ahciProgIfAhci)) {
        return u64(1);
      }
    }
  }
  if ((id & u64(0xFFFF)) == u64(ahciVendIch9)) {
    if (((id >> u64(16)) & u64(0xFFFF)) == u64(ahciDevIch9)) {
      return u64(1);
    }
  }
  if ((id & u64(0xFFFF)) == u64(ahciVendQemu)) {
    if (((id >> u64(16)) & u64(0xFFFF)) == u64(ahciDevQemu)) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Probes functions 1..7 of a multi-function slot. ICH9 AHCI on
/// `-M q35` sits at 00:1f.2; a function-0-only walk would miss it.
/// Separate from [ahciFind] because a nested `while` used to be
/// uncompilable (GAP-0068, now adopted) and this shape matches
/// [pciScanFunctions1To7].
@bare
u64 ahciScanFunctions1To7(u64 dev) {
  u64 fn = u64(1);
  while (fn < u64(8)) {
    final u64 id = pciRead32(u64(0), dev, fn, u64(pciRegId));
    if ((id & u64(0xFFFF)) < u64(0xFFFF)) {
      final u64 classReg = pciRead32(u64(0), dev, fn, u64(pciRegClass));
      if (ahciIsHba(id, classReg) > u64(0)) {
        return (dev << u64(11)) | (fn << u64(8));
      }
    }
    fn = fn + u64(1);
  }
  return u64(pciBdfNone);
}

/// Walks bus 0 for an AHCI HBA. Returns a packed bus/device/function,
/// or [pciBdfNone]. Bus 0 only, deliberately: [pciFindByClass] is the
/// same walk, and an HBA behind a bridge is a named successor.
@bare
u64 ahciFind() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id0 = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id0 & u64(0xFFFF)) < u64(0xFFFF)) {
      final u64 class0 = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
      if (ahciIsHba(id0, class0) > u64(0)) {
        return (dev << u64(11));
      }
      final u64 hdr0 =
          (pciRead32(u64(0), dev, u64(0), u64(pciRegHeader)) >> u64(16)) &
              u64(0xFF);
      if ((hdr0 & u64(0x80)) > u64(0)) {
        final u64 hit = ahciScanFunctions1To7(dev);
        if (hit < u64(pciBdfNone)) {
          return hit;
        }
      }
    }
    dev = dev + u64(1);
  }
  return u64(pciBdfNone);
}

/// 32-bit MMIO load at [bar] + [off]. Every `Volatile` access is
/// emitted volatile (ADR-0044), which is what MMIO needs. A1's
/// completion poll of PxCI / PxIS goes through this (GAP-0071).
@bare
u64 ahciRegGet(u64 bar, u64 off) {
  return Volatile<u32>.fromAddress(bar + off).value.toU64();
}

/// 32-bit MMIO store at [bar] + [off]. Twin of [ahciRegGet].
@bare
void ahciRegPut(u64 bar, u64 off, u64 val) {
  Volatile<u32>.fromAddress(bar + off).value = val.toU32();
}

/// Port [n]'s register block offset from ABAR. Stride is 0x80.
@bare
u64 ahciPortOff(u64 n) {
  return u64(ahciPortBase) + (n << u64(7));
}

/// Poll [bar]+[off] until `(value & mask) == want`, or the iteration
/// bound expires. Returns the last value, or [ahciTimedOut] with the
/// last value in the low bits. Same shape as `ataWait` / `nicWaitByte`.
/// Every load is [ahciRegGet] (`Volatile<u32>`).
@bare
u64 ahciWaitBits(u64 bar, u64 off, u64 mask, u64 want) {
  u64 n = u64(ahciPollLimit);
  u64 v = u64(0);
  while (u64(0) < n) {
    v = ahciRegGet(bar, off);
    if ((v & mask) == want) {
      return v;
    }
    n = n - u64(1);
  }
  return u64(ahciTimedOut) | v;
}

/// Wait until PxCI bit 0 clears. Check PxIS.TFES on every iteration:
/// a task-file error leaves PxCI set and a loop that only watches
/// PxCI hangs (storage.md §2.2 step 6). Both loads are Volatile.
@bare
u64 ahciWaitSlot(u64 bar, u64 poff) {
  u64 n = u64(ahciPollLimit);
  while (u64(0) < n) {
    final u64 ci = ahciRegGet(bar, poff + u64(ahciPxCi));
    final u64 isr = ahciRegGet(bar, poff + u64(ahciPxIs));
    if ((isr & u64(ahciPxIsTfes)) > u64(0)) {
      return u64(ahciSlotTfes);
    }
    if ((ci & u64(1)) == u64(0)) {
      return u64(ahciSlotOk);
    }
    n = n - u64(1);
  }
  return u64(ahciSlotTmo);
}

/// Idle the port: clear ST, spin until CR clears; clear FRE, spin
/// until FR clears. Returns 0 on success, 1 on timeout.
@bare
u64 ahciStopPort(u64 bar, u64 poff) {
  final u64 cmd0 = ahciRegGet(bar, poff + u64(ahciPxCmd));
  ahciRegPut(bar, poff + u64(ahciPxCmd), cmd0 & u64(ahciPxCmdStClr));
  final u64 cr = ahciWaitBits(
      bar, poff + u64(ahciPxCmd), u64(ahciPxCmdCr), u64(0));
  if (cr >= u64(ahciTimedOut)) {
    return u64(1);
  }
  final u64 cmd1 = ahciRegGet(bar, poff + u64(ahciPxCmd));
  ahciRegPut(bar, poff + u64(ahciPxCmd), cmd1 & u64(ahciPxCmdFreClr));
  final u64 fr = ahciWaitBits(
      bar, poff + u64(ahciPxCmd), u64(ahciPxCmdFr), u64(0));
  if (fr >= u64(ahciTimedOut)) {
    return u64(1);
  }
  return u64(0);
}

/// FRE then ST. Returns 0 on success, 1 on timeout waiting for FR.
@bare
u64 ahciStartPort(u64 bar, u64 poff) {
  final u64 cmd0 = ahciRegGet(bar, poff + u64(ahciPxCmd));
  ahciRegPut(bar, poff + u64(ahciPxCmd), cmd0 | u64(ahciPxCmdFre));
  final u64 fr = ahciWaitBits(
      bar, poff + u64(ahciPxCmd), u64(ahciPxCmdFr), u64(ahciPxCmdFr));
  if (fr >= u64(ahciTimedOut)) {
    return u64(1);
  }
  final u64 cmd1 = ahciRegGet(bar, poff + u64(ahciPxCmd));
  ahciRegPut(bar, poff + u64(ahciPxCmd), cmd1 | u64(ahciPxCmdSt));
  return u64(0);
}

/// First implemented port whose SSTS says a SATA disk is present
/// and communicating. Returns 0..31, or 0xFF if there is none.
@bare
u64 ahciPickPort(u64 bar) {
  final u64 pi = ahciRegGet(bar, u64(ahciRegPi));
  u64 n = u64(0);
  u64 found = u64(0xFF);
  while (n < u64(32)) {
    if (found > u64(31)) {
      if ((pi & (u64(1) << n)) > u64(0)) {
        final u64 poff = ahciPortOff(n);
        final u64 ssts = ahciRegGet(bar, poff + u64(ahciPxSsts));
        if ((ssts & u64(ahciSstsDetMask)) == u64(ahciSstsDetPhyon)) {
          if ((ssts & u64(ahciSstsIpmMask)) == u64(ahciSstsIpmActive)) {
            final u64 sig = ahciRegGet(bar, poff + u64(ahciPxSig));
            if (sig == u64(ahciSigAta)) {
              found = n;
            }
          }
        }
      }
    }
    n = n + u64(1);
  }
  return found;
}

/// Build slot 0: command header, Register H2D FIS for READ DMA EXT
/// of one sector at [lba], one PRD pointing at [data].
@bare
void ahciBuildRead(u64 clb, u64 ct, u64 data, u64 lba) {
  Volatile<u32>.fromAddress(clb + u64(0)).value = u64(ahciChDw0).toU32();
  Volatile<u32>.fromAddress(clb + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(clb + u64(8)).value = ct.toU32();
  Volatile<u32>.fromAddress(clb + u64(12)).value = u64(0).toU32();

  Volatile<u8>.fromAddress(ct + u64(0)).value = u8(ahciFisH2d);
  Volatile<u8>.fromAddress(ct + u64(1)).value = u8(ahciFisCmdBit);
  Volatile<u8>.fromAddress(ct + u64(2)).value = u8(ahciAtaReadDmaExt);
  Volatile<u8>.fromAddress(ct + u64(3)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(4)).value = (lba & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(5)).value = ((lba >> u64(8)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(6)).value = ((lba >> u64(16)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(7)).value = u8(ahciDevLba);
  Volatile<u8>.fromAddress(ct + u64(8)).value = ((lba >> u64(24)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(9)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(10)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(11)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(12)).value = u8(1);
  Volatile<u8>.fromAddress(ct + u64(13)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(14)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(15)).value = u8(0);

  final u64 prd = ct + u64(ahciOffPrdt);
  Volatile<u32>.fromAddress(prd + u64(0)).value = data.toU32();
  Volatile<u32>.fromAddress(prd + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(prd + u64(8)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(prd + u64(12)).value = u64(ahciPrdDbc).toU32();
}

/// One found-device line:
///
///     AHCI 00:04.0 8086:2922 01/06/01
///
/// Shape matches [usbReportDevice] / [pciReportDevice] so a harness
/// can parse BDF and vendor:device and compare them to QEMU's `info pci`
/// without a second encoding.
@bare
void ahciReportDevice(u64 bus, u64 dev, u64 fn, u64 id, u64 classReg) {
  uartWrite(Rodata.addressOf(ahciStrDev), u64(5));
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

/// One register line from a mapped ABAR:
///
///     AHCI BAR FEBF1000 CAP C0141F05 PORTS 06
///
/// CAP is a load. PORTS is CAP.NP + 1. Nothing is written.
@bare
void ahciReportRegs(u64 bar) {
  final u64 cap = ahciRegGet(bar, u64(ahciRegCap));
  final u64 ports = (cap & u64(ahciCapNpMask)) + u64(1);
  uartWrite(Rodata.addressOf(ahciStrBar), u64(9));
  uartPutHex(bar, u64(8));
  uartWrite(Rodata.addressOf(ahciStrCap), u64(5));
  uartPutHex(cap, u64(8));
  uartWrite(Rodata.addressOf(ahciStrPorts), u64(7));
  uartPutHex(ports, u64(2));
  uartNewline();
}

/// `ahci` -- find the HBA, print it and CAP, or print `AHCI NONE`.
///
/// Runs in TASK context with interrupts enabled, like every other
/// command (ADR-0006). It is a handful of configuration reads and
/// one MMIO load. Nothing here waits on a device, nothing is written,
/// and nothing is retained. A1's sector is [ahciRead].
@bare
void ahciReport() {
  final u64 bdf = ahciFind();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(ahciStrNone), u64(10));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 id = pciRead32(bus, dev, fn, u64(pciRegId));
  final u64 classReg = pciRead32(bus, dev, fn, u64(pciRegClass));
  ahciReportDevice(bus, dev, fn, id, classReg);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(ahciCmdMem)) < u64(ahciCmdMem)) {
    uartWrite(Rodata.addressOf(ahciStrNocmd), u64(11));
    return;
  }
  final u64 bar = pciReadBar(bdf, u64(ahciBarIndex));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(ahciStrNobar), u64(11));
    return;
  }
  ahciReportRegs(bar);
}

/// `ahci read` -- one READ DMA EXT of LBA 7.
///
/// Runs in TASK context. One frame from `allocFrame()` holds the
/// command list, Received FIS, command table and sector. Never
/// freed: 4 KiB of 128 MiB, held for the boot. The PxCI store is
/// the doorbell.
@bare
void ahciRead() {
  final u64 bdf = ahciFind();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(ahciStrNone), u64(10));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(ahciCmdMem)) < u64(ahciCmdMem)) {
    uartWrite(Rodata.addressOf(ahciStrNocmd), u64(11));
    return;
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(ahciCmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(ahciCmdBme)) < u64(ahciCmdBme)) {
    uartWrite(Rodata.addressOf(ahciStrStuck), u64(15));
    return;
  }
  final u64 bar = pciReadBar(bdf, u64(ahciBarIndex));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(ahciStrNobar), u64(11));
    return;
  }

  final u64 ghc = ahciRegGet(bar, u64(ahciRegGhc));
  ahciRegPut(bar, u64(ahciRegGhc), ghc | u64(ahciGhcAe));

  final u64 port = ahciPickPort(bar);
  if (port > u64(31)) {
    uartWrite(Rodata.addressOf(ahciStrNoport), u64(12));
    return;
  }
  final u64 poff = ahciPortOff(port);

  final u64 mem = allocFrame();
  if (mem < u64(1)) {
    uartWrite(Rodata.addressOf(ahciStrNofrm), u64(11));
    return;
  }
  vmZeroFrame(mem);

  if (ahciStopPort(bar, poff) > u64(0)) {
    uartWrite(Rodata.addressOf(ahciStrTmo), u64(9));
    return;
  }

  final u64 clb = mem + u64(ahciOffCl);
  final u64 fb = mem + u64(ahciOffFis);
  final u64 ct = mem + u64(ahciOffCt);
  final u64 data = mem + u64(ahciOffData);
  ahciRegPut(bar, poff + u64(ahciPxClb), clb);
  ahciRegPut(bar, poff + u64(ahciPxClbu), u64(0));
  ahciRegPut(bar, poff + u64(ahciPxFb), fb);
  ahciRegPut(bar, poff + u64(ahciPxFbu), u64(0));
  ahciRegPut(bar, poff + u64(ahciPxSerr), u64(0xFFFFFFFF));
  ahciRegPut(bar, poff + u64(ahciPxIs), u64(0xFFFFFFFF));
  ahciRegPut(bar, poff + u64(ahciPxIe), u64(0));
  ahciRegPut(bar, u64(ahciRegIs), u64(0xFFFFFFFF));

  if (ahciStartPort(bar, poff) > u64(0)) {
    uartWrite(Rodata.addressOf(ahciStrTmo), u64(9));
    return;
  }

  ahciBuildRead(clb, ct, data, u64(ahciReadLba));

  ahciRegPut(bar, poff + u64(ahciPxIs), u64(0xFFFFFFFF));
  final u64 tfd = ahciWaitBits(
      bar, poff + u64(ahciPxTfd), u64(ahciPxTfdBsyDrq), u64(0));
  if (tfd >= u64(ahciTimedOut)) {
    uartWrite(Rodata.addressOf(ahciStrTmo), u64(9));
    return;
  }

  ahciRegPut(bar, poff + u64(ahciPxCi), u64(1));

  final u64 slot = ahciWaitSlot(bar, poff);
  if (slot == u64(ahciSlotTfes)) {
    uartWrite(Rodata.addressOf(ahciStrTfes), u64(10));
    uartPutHex(ahciRegGet(bar, poff + u64(ahciPxTfd)), u64(8));
    uartNewline();
    return;
  }
  if (slot == u64(ahciSlotTmo)) {
    uartWrite(Rodata.addressOf(ahciStrTmo), u64(9));
    return;
  }

  final u64 prdbc = Volatile<u32>.fromAddress(clb + u64(4)).value.toU64();
  uartWrite(Rodata.addressOf(ahciStrRead), u64(10));
  uartPutHex(u64(ahciReadLba), u64(8));
  uartWrite(Rodata.addressOf(ahciStrPrdbc), u64(7));
  uartPutHex(prdbc, u64(8));
  uartWrite(Rodata.addressOf(ahciStrData), u64(6));
  u64 i = u64(0);
  while (i < u64(ahciPrintBytes)) {
    uartPutHex(Volatile<u8>.fromAddress(data + i).value.toU64(), u64(2));
    i = i + u64(1);
  }
  uartNewline();
}

/// 512 bytes, one byte at a time. DCDart has no memcpy. Not
/// [nvmeCopy512] — nvm5 forbids NVMe names in this file.
@bare
void ahciCopy512(u64 dst, u64 src) {
  u64 i = u64(0);
  while (i < u64(512)) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Slot 0 for one sector at [lba]. [write] 0 is READ DMA EXT;
/// non-zero is WRITE DMA EXT with header W. Arbitrary LBA so FAT
/// is not stuck on A1's LBA 7.
@bare
void ahciBuildIo(u64 clb, u64 ct, u64 data, u64 lba, u64 write) {
  u64 dw0 = u64(ahciChDw0);
  u64 opc = u64(ahciAtaReadDmaExt);
  if (write > u64(0)) {
    dw0 = u64(ahciChDw0Write);
    opc = u64(ahciOpcWriteExt);
  }
  Volatile<u32>.fromAddress(clb + u64(0)).value = dw0.toU32();
  Volatile<u32>.fromAddress(clb + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(clb + u64(8)).value = ct.toU32();
  Volatile<u32>.fromAddress(clb + u64(12)).value = u64(0).toU32();

  Volatile<u8>.fromAddress(ct + u64(0)).value = u8(ahciFisH2d);
  Volatile<u8>.fromAddress(ct + u64(1)).value = u8(ahciFisCmdBit);
  Volatile<u8>.fromAddress(ct + u64(2)).value = opc.toU8();
  Volatile<u8>.fromAddress(ct + u64(3)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(4)).value = (lba & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(5)).value = ((lba >> u64(8)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(6)).value = ((lba >> u64(16)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(7)).value = u8(ahciDevLba);
  Volatile<u8>.fromAddress(ct + u64(8)).value = ((lba >> u64(24)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(ct + u64(9)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(10)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(11)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(12)).value = u8(1);
  Volatile<u8>.fromAddress(ct + u64(13)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(14)).value = u8(0);
  Volatile<u8>.fromAddress(ct + u64(15)).value = u8(0);

  final u64 prd = ct + u64(ahciOffPrdt);
  Volatile<u32>.fromAddress(prd + u64(0)).value = data.toU32();
  Volatile<u32>.fromAddress(prd + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(prd + u64(8)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(prd + u64(12)).value = u64(ahciPrdDbc).toU32();
}

/// Doorbell slot 0 and wait. Silent. [mem] is the session frame.
@bare
u64 ahciIoKick(u64 mem) {
  final u64 bar = Pointer<u64>.fromAddress(mem + u64(ahciIoOffBar)).value;
  final u64 poff = Pointer<u64>.fromAddress(mem + u64(ahciIoOffPoff)).value;
  ahciRegPut(bar, poff + u64(ahciPxIs), u64(0xFFFFFFFF));
  final u64 tfd = ahciWaitBits(
      bar, poff + u64(ahciPxTfd), u64(ahciPxTfdBsyDrq), u64(0));
  if (tfd >= u64(ahciTimedOut)) {
    return u64(1);
  }
  ahciRegPut(bar, poff + u64(ahciPxCi), u64(1));
  final u64 slot = ahciWaitSlot(bar, poff);
  if (slot != u64(ahciSlotOk)) {
    return u64(1);
  }
  return u64(0);
}

/// One sector into [dst] through the session at [st].
@bare
u64 ahciIoRead(u64 st, u64 lba, u64 dst) {
  if (st < u64(1)) {
    return u64(1);
  }
  final u64 clb = st + u64(ahciOffCl);
  final u64 ct = st + u64(ahciOffCt);
  final u64 data = st + u64(ahciOffData);
  ahciBuildIo(clb, ct, data, lba, u64(0));
  if (ahciIoKick(st) > u64(0)) {
    return u64(1);
  }
  ahciCopy512(dst, data);
  return u64(0);
}

/// One sector from [src] through the session at [st].
@bare
u64 ahciIoWrite(u64 st, u64 lba, u64 src) {
  if (st < u64(1)) {
    return u64(1);
  }
  final u64 clb = st + u64(ahciOffCl);
  final u64 ct = st + u64(ahciOffCt);
  final u64 data = st + u64(ahciOffData);
  ahciCopy512(data, src);
  ahciBuildIo(clb, ct, data, lba, u64(1));
  if (ahciIoKick(st) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

/// Find class 01/06/01, enable BME, start one port, keep one frame.
/// Returns the session frame, or 0. Prints nothing.
@bare
u64 ahciIoSetup() {
  final u64 bdf = ahciFind();
  if (bdf == u64(pciBdfNone)) {
    return u64(0);
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(ahciCmdMem)) < u64(ahciCmdMem)) {
    return u64(0);
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(ahciCmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(ahciCmdBme)) < u64(ahciCmdBme)) {
    return u64(0);
  }
  final u64 bar = pciReadBar(bdf, u64(ahciBarIndex));
  if (bar == u64(0)) {
    return u64(0);
  }

  final u64 ghc = ahciRegGet(bar, u64(ahciRegGhc));
  ahciRegPut(bar, u64(ahciRegGhc), ghc | u64(ahciGhcAe));

  final u64 port = ahciPickPort(bar);
  if (port > u64(31)) {
    return u64(0);
  }
  final u64 poff = ahciPortOff(port);

  final u64 mem = allocFrame();
  if (mem < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(mem);

  if (ahciStopPort(bar, poff) > u64(0)) {
    return u64(0);
  }

  final u64 clb = mem + u64(ahciOffCl);
  final u64 fb = mem + u64(ahciOffFis);
  ahciRegPut(bar, poff + u64(ahciPxClb), clb);
  ahciRegPut(bar, poff + u64(ahciPxClbu), u64(0));
  ahciRegPut(bar, poff + u64(ahciPxFb), fb);
  ahciRegPut(bar, poff + u64(ahciPxFbu), u64(0));
  ahciRegPut(bar, poff + u64(ahciPxSerr), u64(0xFFFFFFFF));
  ahciRegPut(bar, poff + u64(ahciPxIs), u64(0xFFFFFFFF));
  ahciRegPut(bar, poff + u64(ahciPxIe), u64(0));
  ahciRegPut(bar, u64(ahciRegIs), u64(0xFFFFFFFF));

  if (ahciStartPort(bar, poff) > u64(0)) {
    return u64(0);
  }

  Pointer<u64>.fromAddress(mem + u64(ahciIoOffBar)).value = bar;
  Pointer<u64>.fromAddress(mem + u64(ahciIoOffPoff)).value = poff;
  return mem;
}
