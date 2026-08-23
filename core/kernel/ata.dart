// core/kernel/ata.dart
//
// oscortex_core M6: ATA PIO -- reading actual bytes off an actual disk.
// oscortex_core M16: and WRITING them. `ataWriteFrom` is the first code in this
// kernel that can change a disk; it starts below `shellDiskRead`'s neighbours,
// after [ataReadInto], and its own header says what is different about it. The
// architecture is docs/decisions/0020-writing-to-a-disk.md.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is: `dcc` lowers exactly ONE library per object file, so a
// `@bare` function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHY THIS, AND WHY NOW
// ---------------------------------------------------------------------------
// M5 taught this kernel to FIND hardware: `pci` walks configuration space and
// reports an IDE controller at 00:01.1 (8086:7010, class 01/01). It could see
// storage and could not read a byte of it. Everything the kernel has ever
// known came in through the loader or was compiled into it; nothing has ever
// been READ from a device that stores data.
//
// ATA PIO is the shortest honest path to that, and the reason is structural
// rather than aesthetic: it moves data through the CPU one 16-bit port read at
// a time, so it needs no bus-master DMA, no physically-contiguous buffer, no
// scatter/gather list -- and therefore NO PHYSICAL MEMORY MANAGER. This kernel
// does not have one and cannot have one until DCDart's mutable-statics
// decision lands (docs/known-gaps.md GAP-0053, ROADMAP M7 -- which this
// milestone renumbered from M6 by taking that number, and did not unblock). A
// DMA driver would
// need somewhere to put a PRDT and a landing buffer; a PIO driver needs a port
// number and a loop.
//
// ---------------------------------------------------------------------------
// NO STORAGE. THIS SUBSYSTEM COSTS ZERO DONATED BYTES.
// ---------------------------------------------------------------------------
// A 512-byte sector buffer is exactly the kind of thing this kernel cannot
// spell (GAP-0053: no mutable statics, no array type, no allocator), and
// `core/boot/kdata.S` is at 424 donated bytes already. So the driver does not
// have one: `disk read` HEXDUMPS EACH WORD AS IT ARRIVES, and `disk id`
// prints the IDENTIFY fields it cares about as they go past. The data port is
// read exactly 256 times per sector either way, in order, and nothing is
// retained.
//
// That is the same deal `pci` and `mem` took, and it has the same cost stated
// the same way: this driver can SHOW you a sector and cannot GIVE you one.
// There is no `read(lba) -> bytes` here because there is nowhere for the bytes
// to go. A filesystem is the milestone that cannot take this deal, for the
// same reason an allocator could not -- see docs/known-gaps.md GAP-0074.
//
// ---------------------------------------------------------------------------
// THE PROTOCOL, AND THE TWO THINGS THAT MAKE IT CORRECT RATHER THAN LUCKY
// ---------------------------------------------------------------------------
// The primary channel is eight registers at 0x1F0..0x1F7 plus a control
// register at 0x3F6. A single-sector LBA28 read is:
//
//   1. write the drive/head register: 0xE0 | LBA bits 27:24  (master, LBA)
//   2. wait 400ns -- four reads of the ALTERNATE status register, which is
//      the classic way to spend that time without side effects (reading the
//      real status register at 0x1F7 clears a pending interrupt)
//   3. sector count = 1, LBA bits 7:0, 15:8, 23:16 into 0x1F2..0x1F5
//   4. command 0x20 (READ SECTORS) into 0x1F7
//   5. poll until BSY clears and DRQ sets
//   6. read 256 16-bit words from 0x1F0
//
// **BSY BEFORE DRQ, ALWAYS.** While BSY is set the drive OWNS every other bit
// of the status register, so DRQ, ERR and DF read during BSY mean nothing at
// all. [ataWait] therefore tests BSY first and only looks at anything else on
// an iteration where BSY is clear. A poll written the other way round appears
// to work on an emulator that clears BSY instantly and is a race on hardware.
//
// **EVERY WAIT IS BOUNDED.** docs/known-gaps.md GAP-0058 already records an
// unbounded wait as a real hazard in this kernel (`uartPutc` spins on THRE
// forever). A disk is a far better candidate for wedging than a UART, and a
// command runs with interrupts enabled but with nothing that could break the
// loop -- so an unbounded poll on a dead controller is a silent hang with no
// diagnostic, which is precisely the failure this project's fault work exists
// to abolish. Every poll here is an iteration-counted loop that gives up and
// SAYS SO. What it is not is a wall-clock timeout: see [ataPollLimit].
//
// ---------------------------------------------------------------------------
// THE DATA PORT IS 16 BITS WIDE, AND THAT IS A LANGUAGE GAP AGAIN
// ---------------------------------------------------------------------------
// `Port.inb`/`Port.outb` (DCDart ADR-0029) are byte-wide, and 0x1F0 is a
// 16-bit port: a byte read returns half a word and advances the drive's
// internal pointer by an amount that is not part of any specification. So the
// data port is read through `port_inw`, the same `core/boot/portio.S` helper
// M5's framebuffer mode-set added for the Bochs VBE registers, over the same
// `@extern` seam. No new externs and no new assembly -- the third subsystem to
// need a width DCDart's `Port` does not have, which is the whole of the
// argument in docs/known-gaps.md GAP-0066.
//
// **That argument has been won, and this file does not yet get to enjoy it.**
// GAP-0066 asked for `Port.inw`/`outw`/`inl`/`outl`, and DCDart `b3f0ed9`
// added exactly those. `DCDART_PIN.txt` is `9e836a3`, which predates the
// commit, so the toolchain that actually builds this kernel still has only the
// byte-wide forms and `port_inw` is still the only way to read 0x1F0. When the
// pin moves, `port_inw(u64(ataRegData))` becomes `Port.inw(u16(ataRegData))`,
// `core/boot/portio.S` is deleted outright, and four externs go with it. Why
// that did not happen inside this unit is
// `docs/decisions/0010-ata-pio-disk-read.md` §6.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The primary channel's registers. Named `const int`s (DCDart ADR-0037).
//
// 0x1F7 and 0x3F6 are each TWO registers -- one on read, a different one on
// write -- so they are named twice rather than once. `ataRegCommand` and
// `ataRegStatus` being the same number is a fact about the hardware, and
// spelling it out is what keeps a call site readable.
// ---------------------------------------------------------------------------

/// 16-bit data register. Read 256 times per sector; NOT byte-addressable.
const int ataRegData = 0x1F0;

/// Error register (read) / features (write). Only read here, and only after a
/// command has set ERR -- its contents are meaningless otherwise.
const int ataRegError = 0x1F1;

/// Sector count. Always 1 in this driver: a multi-sector read would produce
/// another DRQ phase per sector and there is nothing here that needs one yet.
const int ataRegCount = 0x1F2;

/// LBA bits 7:0, 15:8 and 23:16. Bits 27:24 go in the drive/head register.
const int ataRegLbaLo = 0x1F3;
const int ataRegLbaMid = 0x1F4;
const int ataRegLbaHi = 0x1F5;

/// Drive/head register: [ataDevLbaMaster] plus LBA bits 27:24.
const int ataRegDevice = 0x1F6;

/// Status (read) / command (write).
const int ataRegStatus = 0x1F7;
const int ataRegCommand = 0x1F7;

/// Alternate status (read) / device control (write).
///
/// The alternate status register returns exactly the same byte as 0x1F7 but
/// does NOT clear a pending interrupt, which is what makes it the right
/// register to read when all you want to do is spend 400 nanoseconds.
const int ataRegAltStatus = 0x3F6;
const int ataRegDevCtl = 0x3F6;

/// Status register bits.
const int ataStErr = 0x01;
const int ataStDrq = 0x08;
const int ataStDf = 0x20;
const int ataStRdy = 0x40;
const int ataStBsy = 0x80;

/// Commands.
const int ataCmdIdentify = 0xEC;
const int ataCmdReadSectors = 0x20;

/// M16 (docs/decisions/0020-writing-to-a-disk.md): WRITE SECTORS, LBA28, PIO.
///
/// Two milestones' worth of harnesses asserted that this constant did not
/// exist, and they were right to: a driver that can write is a driver that can
/// destroy a volume, and nothing before M16 had a reason to. Those assertions
/// are not deleted — m14-fat and m15-fileio now assert that THEIR OWN boots
/// issue no write, which is a stronger claim than "the opcode is unspellable"
/// because it is checked by running rather than by grepping.
const int ataCmdWriteSectors = 0x30;

/// FLUSH CACHE. ATA/ATAPI-6 §8.16 and §6.8: WRITE SECTORS is allowed to report
/// completion when the data is in the drive's write cache, not on the medium.
/// Every write path in this kernel ends with this command, and it is the reason
/// a file written by a guest survives QEMU exiting rather than surviving only
/// until the process does.
const int ataCmdCacheFlush = 0xE7;

/// Drive/head register: master drive, LBA addressing. Bits 7 and 5 are set
/// because they are hardwired to 1 in the original definition of the register,
/// bit 6 selects LBA over CHS, and bit 4 selects master over slave.
const int ataDevLbaMaster = 0xE0;

/// Device control: nIEN. Writing this masks the drive's own interrupt line at
/// the drive, which is the honest thing to do in a driver that polls.
///
/// Not strictly required on this machine -- the slave 8259 is masked entirely
/// at rest (`picUnmaskKeyboardOnly` writes 0xFF to 0xA1) so IRQ14 could not
/// reach the CPU anyway -- but "the interrupt cannot be delivered" and "the
/// drive was told not to raise one" are different claims, and only the second
/// one survives someone later unmasking the cascade.
const int ataCtlNien = 0x02;

/// How many times a poll re-reads the status register before giving up.
///
/// **This is an iteration count, not a duration, and the difference is worth
/// stating rather than hiding.** A wall-clock timeout needs a clock, and the
/// only one this kernel has is the PIT -- which is MASKED at rest so that
/// `ticks` can report a reproducible number (docs/known-gaps.md GAP-0058).
/// Unmasking it here to time a disk read would make every `disk` command's
/// duration depend on the host, and a duration cannot appear in a byte-exact
/// golden.
///
/// So the bound is the number of I/O port reads the driver is willing to
/// perform, which is a real bound on a real resource even though it is not a
/// number of seconds. Under QEMU each iteration is one VM exit and the whole
/// budget is a fraction of a second; on real hardware an ISA-speed `in` is
/// roughly a microsecond, so 2^21 iterations is on the order of a second --
/// ample for any command this driver issues to a drive that is already
/// spinning, and NOT ample for a cold spin-up. Recorded as
/// docs/known-gaps.md GAP-0073.
const int ataPollLimit = 0x200000;

/// Returned by [ataWait] instead of a status byte when the bound expired. A
/// status register is one byte, so any value above 0xFF is unambiguously not
/// one; the low byte still carries the last status actually seen, which is the
/// most useful thing to print.
const int ataTimedOut = 0x100;

/// The largest LBA28 address, and one past it. Two constants rather than one
/// and an arithmetic expression, for the reason [ataIdModelBefore] records.
///
/// [ataLba28Limit] doubles as the "that is not a number"
/// return from [ataParseLba]: every failure is a value the caller must reject
/// anyway, so there is exactly one check at the call site instead of two.
const int ataLba28Max = 0x0FFFFFFF;
const int ataLba28Limit = 0x10000000;

/// IDENTIFY result layout, in 16-bit words.
///
///   27..46  model number, 40 bytes, two characters per word, HIGH BYTE FIRST
///   60,61   total addressable sectors in LBA28 mode, low word first
///
/// Words 0..255 are all read whatever happens: a drive holds DRQ until the
/// whole block has been transferred, and walking away early leaves the channel
/// in a state the next command has to clean up.
///
/// The model range is spelled as the word BEFORE the first and the word AFTER
/// the last, because
/// DCDart has no `>=` or `<=` and `dcc` will not fold `27 - 1` inside a
/// `u64(...)` constructor -- "the argument must be an integer literal or a
/// compile-time integer constant", and a `const int` subtraction does not
/// qualify. So the two bounds a half-open range needs are two more literals
/// rather than arithmetic on one, and they are named for what they are.
const int ataIdModelBefore = 26;
const int ataIdModelAfter = 47;
const int ataIdSectorsLo = 60;
const int ataIdSectorsHi = 61;

/// Words in one PIO data block: 512 bytes / 2.
const int ataWordsPerSector = 256;

/// Bytes per sector, and per hexdump line. The line's WORD count is named
/// separately rather than divided at the call site: `/` is floating-point
/// division in Dart's grammar and `~/` carries a zero-divisor check `dcc`
/// lowers to a `ud2` (docs/known-gaps.md GAP-0063), so a constant that is
/// wanted in two units is cheapest to spell twice and assert once.
const int ataBytesPerSector = 512;
const int ataDumpLineBytes = 16;
const int ataDumpLineWords = 8;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// Every table below, its byte count, and the literal each call site passes were
// generated from the string rather than counted by hand -- docs/known-gaps.md
// GAP-0060, which has already caused one truncation incident in this kernel.
// `tests/conformance/m6-disk/run.sh` reads every one of these sizes back out of
// the object file and compares it against the number the call site passes.
// ---------------------------------------------------------------------------

/// Command name, matched as a PREFIX for the usage line.
///
/// `disk` -- 4 bytes.
@rodata
final List<u8> ataCmdName = const [
  u8(0x64), u8(0x69), u8(0x73), u8(0x6B),
];

/// Whole-line command name.
///
/// `disk id` -- 7 bytes.
@rodata
final List<u8> ataCmdIdName = const [
  u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x69), u8(0x64),
];

/// Command name matched as a PREFIX; the LBA follows it.
///
/// `disk read ` -- 10 bytes.
@rodata
final List<u8> ataCmdReadName = const [
  u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x20),
];

/// `disk` with no argument, or with one this shell does not know.
///
/// `disk: usage: disk id | disk read <lba-hex>\n` -- 43 bytes.
@rodata
final List<u8> ataStrUsage = const [
  u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A),
  u8(0x20), u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x69), u8(0x64), u8(0x20), u8(0x7C), u8(0x20), u8(0x64),
  u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62),
  u8(0x61), u8(0x2D), u8(0x68), u8(0x65), u8(0x78), u8(0x3E), u8(0x0A),
];

/// `disk read` with an argument that is not a legal LBA28 address.
///
/// `disk: bad lba: 1-7 hex digits, LBA28 (max 0FFFFFFF)\n` -- 52 bytes.
@rodata
final List<u8> ataStrBadLba = const [
  u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x3A), u8(0x20), u8(0x62), u8(0x61), u8(0x64), u8(0x20), u8(0x6C), u8(0x62),
  u8(0x61), u8(0x3A), u8(0x20), u8(0x31), u8(0x2D), u8(0x37), u8(0x20), u8(0x68), u8(0x65), u8(0x78), u8(0x20), u8(0x64),
  u8(0x69), u8(0x67), u8(0x69), u8(0x74), u8(0x73), u8(0x2C), u8(0x20), u8(0x4C), u8(0x42), u8(0x41), u8(0x32), u8(0x38),
  u8(0x20), u8(0x28), u8(0x6D), u8(0x61), u8(0x78), u8(0x20), u8(0x30), u8(0x46), u8(0x46), u8(0x46), u8(0x46), u8(0x46),
  u8(0x46), u8(0x46), u8(0x29), u8(0x0A),
];

/// `disk id` line prefix, followed by the 16-bit ATA signature.
///
/// `DISK ID SIG ` -- 12 bytes.
@rodata
final List<u8> ataStrIdLbl = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x49), u8(0x44), u8(0x20), u8(0x53), u8(0x49), u8(0x47), u8(0x20),
];

/// `disk id` separator before the IDENTIFY model string.
///
/// ` MODEL ` -- 7 bytes.
@rodata
final List<u8> ataStrModel = const [
  u8(0x20), u8(0x4D), u8(0x4F), u8(0x44), u8(0x45), u8(0x4C), u8(0x20),
];

/// `disk id` separator before the LBA28 sector count.
///
/// ` SECTORS ` -- 9 bytes.
@rodata
final List<u8> ataStrSectors = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x43), u8(0x54), u8(0x4F), u8(0x52), u8(0x53), u8(0x20),
];

/// `disk id` terminator -- only reachable after all 256 words were read.
///
/// ` OK\n` -- 4 bytes.
@rodata
final List<u8> ataStrOk = const [
  u8(0x20), u8(0x4F), u8(0x4B), u8(0x0A),
];

/// `disk read` line prefix, followed by the LBA.
///
/// `DISK READ LBA ` -- 14 bytes.
@rodata
final List<u8> ataStrReadLbl = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x20), u8(0x4C), u8(0x42),
  u8(0x41), u8(0x20),
];

/// `disk read` terminator -- only reachable after 512 bytes.
///
/// `DISK READ END\n` -- 14 bytes.
@rodata
final List<u8> ataStrReadEnd = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x20), u8(0x45), u8(0x4E),
  u8(0x44), u8(0x0A),
];

/// No drive answered on the primary channel.
///
/// `DISK ERR NODEV ST ` -- 18 bytes.
@rodata
final List<u8> ataStrNoDev = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x4E), u8(0x4F), u8(0x44),
  u8(0x45), u8(0x56), u8(0x20), u8(0x53), u8(0x54), u8(0x20),
];

/// A bounded wait expired; the phase digit follows.
///
/// `DISK ERR TIMEOUT P` -- 18 bytes.
@rodata
final List<u8> ataStrTimeout = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x54), u8(0x49), u8(0x4D),
  u8(0x45), u8(0x4F), u8(0x55), u8(0x54), u8(0x20), u8(0x50),
];

/// Separator before a status byte.
///
/// ` ST ` -- 4 bytes.
@rodata
final List<u8> ataStrStTail = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x20),
];

/// The drive set ERR or DF; status follows.
///
/// `DISK ERR ST ` -- 12 bytes.
@rodata
final List<u8> ataStrErrLbl = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x53), u8(0x54), u8(0x20),
];

/// Separator before the error register.
///
/// ` ER ` -- 4 bytes.
@rodata
final List<u8> ataStrErTail = const [
  u8(0x20), u8(0x45), u8(0x52), u8(0x20),
];

/// The signature registers say this is not an ATA disk.
///
/// `DISK ERR NOTATA SIG ` -- 20 bytes.
@rodata
final List<u8> ataStrNotAta = const [
  u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x4E), u8(0x4F), u8(0x54),
  u8(0x41), u8(0x54), u8(0x41), u8(0x20), u8(0x53), u8(0x49), u8(0x47), u8(0x20),
];

// ---------------------------------------------------------------------------
// Polling.
// ---------------------------------------------------------------------------

/// Reads the alternate status register four times and returns the last value.
///
/// This is the ATA 400-nanosecond settle, and it is also a real presence test,
/// which is why it returns the byte instead of being a `void` delay whose
/// result an optimiser would be entitled to discard. Two values are special:
///
///   0x00  no drive is attached. The channel's registers read back as zero
///         because nothing is driving them.
///   0xFF  the bus is FLOATING -- no device decodes these ports at all, so the
///         pull-ups win. On a machine with no IDE controller this is what
///         every register reads as, and treating it as a status byte would
///         mean seeing BSY, DRDY, DRQ and ERR all set at once.
///
/// Four reads rather than one because the specification's requirement is a
/// duration, not a count: an ISA-speed port read is ~100ns, so four of them is
/// the idiom that has meant "400ns" since before this kernel's author was
/// born. It is an approximation on a modern machine and it is the same
/// approximation every other ATA driver makes.
@bare
u64 ataSettle() {
  u64 st = u64(0);
  u64 i = u64(0);
  while (i < u64(4)) {
    st = Port.inb(u16(ataRegAltStatus)).toU64();
    i = i + u64(1);
  }
  return st;
}

/// Polls the status register until BSY is clear AND at least one of the bits
/// in [want] is set, or until the poll bound expires.
///
/// Returns the status byte on success, or `ataTimedOut | lastStatus` if the
/// bound expired. The caller must test for the timeout FIRST -- see
/// [ataFailed].
///
/// **BSY is honoured before anything else, on every iteration.** ATA/ATAPI-6
/// §6.2: while BSY is set, the contents of every other status bit and every
/// other register are undefined, because the drive owns them. A poll that
/// tests DRQ without first testing BSY can therefore see a DRQ left over from
/// the previous command and start reading the data port before the drive has
/// put anything in it. On QEMU that race is invisible (BSY is clear by the
/// time the `out` returns); on hardware it is a corrupted sector.
///
/// **ERR and DF end the wait too.** They are not failures of this function --
/// it returns the status and lets the caller diagnose it -- but a drive that
/// has set ERR will never set DRQ, so a loop waiting only for DRQ would spin
/// out its whole bound on an error that was already reported in the first
/// microsecond.
@bare
u64 ataWait(u64 want) {
  u64 n = u64(ataPollLimit);
  u64 st = u64(0);
  while (u64(0) < n) {
    st = Port.inb(u16(ataRegStatus)).toU64();
    if ((st & u64(ataStBsy)) < u64(1)) {
      if ((st & (u64(ataStErr) | u64(ataStDf))) > u64(0)) {
        return st;
      }
      if ((st & want) > u64(0)) {
        return st;
      }
    }
    n = n - u64(1);
  }
  return u64(ataTimedOut) | st;
}

/// 1 if [st] is anything other than a clean status with no error bits.
///
/// A `u64` rather than a `bool` because DCDart has no boolean operators at all
/// (GAP-0023), so `a || b` is not expressible and an `if` chain returning 1 is
/// what composes.
@bare
u64 ataFailed(u64 st) {
  if (st > u64(0xFF)) {
    return u64(1); // the timeout flag is set
  }
  if ((st & (u64(ataStErr) | u64(ataStDf))) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Diagnostics. Every failure path prints one, and every one names a value read
// out of the hardware rather than a constant.
// ---------------------------------------------------------------------------

/// `DISK ERR NODEV ST xx` -- nothing answered on the primary channel.
@bare
void ataReportNoDev(u64 st) {
  uartWrite(Rodata.addressOf(ataStrNoDev), u64(18));
  uartPutHex(st & u64(0xFF), u64(2));
  uartNewline();
}

/// `DISK ERR TIMEOUT Pn ST xx` -- a bounded wait expired in phase [phase].
///
/// The phase digit is what makes this diagnostic worth more than "it hung":
/// 1 is waiting for the drive to go idle before a command, 2 is waiting for
/// IDENTIFY's data, 3 is waiting for READ SECTORS' data. They fail for
/// different reasons and a capture that says which one is a different bug
/// report.
@bare
void ataReportTimeout(u64 phase, u64 st) {
  uartWrite(Rodata.addressOf(ataStrTimeout), u64(18));
  uartPutHex(phase, u64(1));
  uartWrite(Rodata.addressOf(ataStrStTail), u64(4));
  uartPutHex(st & u64(0xFF), u64(2));
  uartNewline();
}

/// `DISK ERR ST xx ER yy` -- the drive set ERR or DF.
///
/// The error register is read HERE rather than passed in, because it is only
/// meaningful once ERR has been observed, and reading it on a path where ERR
/// is clear would print a stale byte from some earlier command.
@bare
void ataReportError(u64 st) {
  uartWrite(Rodata.addressOf(ataStrErrLbl), u64(12));
  uartPutHex(st & u64(0xFF), u64(2));
  uartWrite(Rodata.addressOf(ataStrErTail), u64(4));
  uartPutHex(Port.inb(u16(ataRegError)).toU64(), u64(2));
  uartNewline();
}

/// Prints whichever of the two diagnostics above [st] calls for.
@bare
void ataReportFailure(u64 phase, u64 st) {
  if (st > u64(0xFF)) {
    ataReportTimeout(phase, st);
    return;
  }
  ataReportError(st);
}

/// `DISK ERR NOTATA SIG xxxx` -- the drive is not an ATA disk.
///
/// After an IDENTIFY, a device that is not an ATA disk reports a signature in
/// the LBA mid/high registers: 0xEB14 for ATAPI (a CD-ROM), 0x9669 for SATA
/// behind a legacy shim. This driver reads sectors and those devices do not
/// serve them the same way, so it stops and says what it saw. **Guessing here
/// would be worse than stopping**: an ATAPI device answers 0x20 with an error
/// rather than data, and a driver that ploughed on would report a failed read
/// of a disk that was never a disk.
@bare
void ataReportNotAta(u64 sig) {
  uartWrite(Rodata.addressOf(ataStrNotAta), u64(20));
  uartPutHex(sig, u64(4));
  uartNewline();
}

// ---------------------------------------------------------------------------
// Selecting a drive.
// ---------------------------------------------------------------------------

/// Selects the master drive with LBA bits 27:24 from [lba], masks the drive's
/// interrupt, settles, and returns the alternate status.
///
/// Writing nIEN BEFORE the select rather than after is deliberate: the control
/// register is not per-drive on the primary channel, and a drive selected with
/// its interrupt still enabled can assert IRQ14 the instant it becomes ready.
@bare
u64 ataSelect(u64 lba) {
  Port.outb(u16(ataRegDevCtl), u8(ataCtlNien));
  Port.outb(
    u16(ataRegDevice),
    (u64(ataDevLbaMaster) | ((lba >> u64(24)) & u64(0x0F))).toU8(),
  );
  return ataSettle();
}

/// 1 if [st] means "there is nothing here": all zeroes (no drive) or all ones
/// (a floating bus with nothing decoding these ports).
@bare
u64 ataAbsent(u64 st) {
  if (st == u64(0)) {
    return u64(1);
  }
  if (st == u64(0xFF)) {
    return u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// `disk id` -- IDENTIFY DEVICE.
// ---------------------------------------------------------------------------

/// Writes [n] spaces.
///
/// A separate function ONLY because the PINNED `dcc` cannot compile a `while`
/// inside a `while` and the caller of the caller of this is a loop. That
/// limitation is fixed upstream and is NOT fixed in the toolchain this repo
/// builds against -- docs/known-gaps.md GAP-0068 records both halves. Its real
/// job is trailing-space suppression: see [ataModelByte].
@bare
void ataSpaces(u64 n) {
  u64 i = u64(0);
  while (i < n) {
    uartSpace();
    i = i + u64(1);
  }
}

/// Emits one character of the IDENTIFY model string, deferring spaces.
///
/// [pending] is how many spaces have been seen since the last printed
/// character; the return value is the new count. Spaces are only emitted once
/// a non-space follows them, so the 40-byte space-padded field prints as
/// `QEMU HARDDISK` and not as `QEMU HARDDISK` followed by 27 spaces.
///
/// **This is what "no buffer" costs and buys.** Trimming a trailing field
/// normally means holding it; holding it means 40 bytes of storage this kernel
/// does not have (GAP-0053). A one-word running count does the same job for
/// one word of a live local, and it works BECAUSE the characters arrive in
/// order and are printed as they arrive.
///
/// Bytes outside the printable range are DROPPED rather than printed. A drive
/// is free to pad with NULs, and a NUL or a control byte in the middle of a
/// byte-exact serial golden is a capture nobody can diff.
@bare
u64 ataModelByte(u8 c, u64 pending) {
  if (c == u8(0x20)) {
    return pending + u64(1);
  }
  if (c < u8(0x20)) {
    return pending;
  }
  if (c > u8(0x7E)) {
    return pending;
  }
  ataSpaces(pending);
  conPutc(c);
  return u64(0);
}

/// Reads all 256 words of an IDENTIFY block, printing the model string and the
/// LBA28 sector count as they go past.
///
/// **The output order is the word order, and that is not a coincidence.** The
/// model is words 27..46 and the sector count is words 60..61, so `MODEL ...
/// SECTORS ...` is the order the drive sends them in. Printing them the other
/// way round would require holding one of them, which would require somewhere
/// to hold it. The line reads the way it does because of what this kernel
/// cannot do, and it is worth knowing that when reading it.
///
/// ATA strings are stored HIGH BYTE FIRST within each 16-bit word -- the one
/// place in the whole interface where a little-endian machine's instincts are
/// wrong, and the one that produces `EQUMH RADDSI K` when it is missed.
///
/// Every word is read even when nothing is done with it: the drive asserts DRQ
/// until the entire block has been transferred, and abandoning it half-read
/// leaves the channel wedged for the next command.
@bare
void ataIdentifyBlock() {
  u64 i = u64(0);
  u64 pending = u64(0);
  u64 sectorsLo = u64(0);
  while (i < u64(ataWordsPerSector)) {
    final u64 w = port_inw(u64(ataRegData));
    if (i > u64(ataIdModelBefore)) {
      if (i < u64(ataIdModelAfter)) {
        pending = ataModelByte(((w >> u64(8)) & u64(0xFF)).toU8(), pending);
        pending = ataModelByte((w & u64(0xFF)).toU8(), pending);
      }
    }
    if (i == u64(ataIdSectorsLo)) {
      sectorsLo = w & u64(0xFFFF);
    }
    if (i == u64(ataIdSectorsHi)) {
      uartWrite(Rodata.addressOf(ataStrSectors), u64(9));
      uartPutHex(((w & u64(0xFFFF)) << u64(16)) | sectorsLo, u64(8));
    }
    i = i + u64(1);
  }
}

/// `disk id` -- IDENTIFY DEVICE on the primary master.
///
/// Prints one line:
///
///     DISK ID SIG 0000 MODEL QEMU HARDDISK SECTORS 00000080 OK
///
///   `SIG`      the LBA mid/high registers after IDENTIFY. 0000 is an ATA
///              disk; EB14 would be ATAPI and 9669 a SATA shim, and either
///              stops the command rather than being guessed at.
///   `MODEL`    IDENTIFY words 27..46, trailing spaces trimmed.
///   `SECTORS`  IDENTIFY words 60..61: LBA28 capacity, low word first.
///   `OK`       the whole 256-word block was read and the drive went idle.
///
/// Every field is read out of the drive. ` OK` is the only part that is a
/// constant, and it is printed after the block has been drained and the status
/// re-read, so it is a claim about what happened rather than a decoration.
@bare
void shellDiskId() {
  final u64 st0 = ataSelect(u64(0));
  if (ataAbsent(st0) > u64(0)) {
    ataReportNoDev(st0);
    return;
  }
  final u64 idle = ataWait(u64(ataStRdy));
  if (ataFailed(idle) > u64(0)) {
    ataReportFailure(u64(1), idle);
    return;
  }

  // IDENTIFY requires the LBA and count registers to be zero: they are what
  // the drive writes its signature into, and a stale value in one of them
  // would be read back below as a signature that never happened.
  Port.outb(u16(ataRegCount), u8(0));
  Port.outb(u16(ataRegLbaLo), u8(0));
  Port.outb(u16(ataRegLbaMid), u8(0));
  Port.outb(u16(ataRegLbaHi), u8(0));
  Port.outb(u16(ataRegCommand), u8(ataCmdIdentify));

  // A status of zero AFTER the command means the drive does not exist. This is
  // the specified presence test and it is separate from the one in ataSelect:
  // that one catches an empty channel, this one catches an empty slot on a
  // channel that does have a controller.
  final u64 st1 = ataSettle();
  if (ataAbsent(st1) > u64(0)) {
    ataReportNoDev(st1);
    return;
  }

  final u64 st2 = ataWait(u64(ataStDrq));
  if (st2 > u64(0xFF)) {
    ataReportTimeout(u64(2), st2);
    return;
  }

  // The signature is only meaningful once BSY has cleared, which ataWait
  // guarantees for every value it returns that is not a timeout.
  final u64 sig = Port.inb(u16(ataRegLbaMid)).toU64() |
      (Port.inb(u16(ataRegLbaHi)).toU64() << u64(8));
  if (sig > u64(0)) {
    ataReportNotAta(sig);
    return;
  }
  if ((st2 & (u64(ataStErr) | u64(ataStDf))) > u64(0)) {
    ataReportError(st2);
    return;
  }
  if ((st2 & u64(ataStDrq)) < u64(1)) {
    ataReportError(st2);
    return;
  }

  uartWrite(Rodata.addressOf(ataStrIdLbl), u64(12));
  uartPutHex(sig, u64(4));
  uartWrite(Rodata.addressOf(ataStrModel), u64(7));
  ataIdentifyBlock();

  // Drained: DRQ must be clear again. If it is not, the drive has more to say
  // than the specification allows and the channel is not in a state the next
  // command can trust.
  final u64 st3 = Port.inb(u16(ataRegStatus)).toU64();
  if ((st3 & u64(ataStDrq)) > u64(0)) {
    ataReportError(st3);
    return;
  }
  uartWrite(Rodata.addressOf(ataStrOk), u64(4));
}

// ---------------------------------------------------------------------------
// `disk read <lba>` -- READ SECTORS, hexdumped as it arrives.
// ---------------------------------------------------------------------------

/// Reads eight words from the data port and prints them as sixteen bytes, in
/// memory order, prefixed by the offset:
///
///     0000 4F 53 43 4F 52 54 45 58 20 53 45 43 54 4F 52 20
///
/// A word read off the data port holds two consecutive sector bytes with the
/// LOW byte first -- the opposite of the model string above, and correct for
/// the same reason: the model is a big-endian string field, sector data is
/// just bytes.
///
/// **A separate function only because the PINNED `dcc` cannot compile a nested
/// `while`** (docs/known-gaps.md GAP-0068). The natural shape is this loop
/// inside [ataDumpSector]'s line loop. That is the THIRD subsystem in this
/// kernel forced into this decomposition, after `pciScanFunctions1To7` (M5,
/// PCI) and `fbFillRow` (M5, the framebuffer).
///
/// GAP-0068 is RESOLVED UPSTREAM (DCDart `e3cfe18`) and this repo has NOT
/// adopted the fix: `DCDART_PIN.txt` is `9e836a3`, which predates it. This
/// shape is therefore still forced by the compiler that actually builds this
/// kernel, and it is not a shape anyone would choose. See
/// `docs/decisions/0010-ata-pio-disk-read.md` §6 for why the pin was not moved
/// inside this unit.
@bare
void ataDumpLine(u64 off) {
  uartPutHex(off, u64(4));
  u64 i = u64(0);
  while (i < u64(ataDumpLineWords)) {
    final u64 w = port_inw(u64(ataRegData));
    uartSpace();
    uartPutHex(w & u64(0xFF), u64(2));
    uartSpace();
    uartPutHex((w >> u64(8)) & u64(0xFF), u64(2));
    i = i + u64(1);
  }
  uartNewline();
}

/// Hexdumps a whole 512-byte sector, 16 bytes per line, AS IT READS IT.
///
/// This is the function the whole "no donated storage" claim rests on: the
/// data port is read exactly 256 times, in order, and each word is printed and
/// forgotten. There is no 512-byte buffer anywhere in this kernel and there is
/// nowhere to put one (GAP-0053).
@bare
void ataDumpSector() {
  u64 off = u64(0);
  while (off < u64(ataBytesPerSector)) {
    ataDumpLine(off);
    off = off + u64(ataDumpLineBytes);
  }
}

// ---------------------------------------------------------------------------
// M10 (docs/decisions/0014-elf-loader.md): READ ONE SECTOR INTO MEMORY.
//
// M6 built a driver that could only PRINT what it read, because there was
// nowhere to put 512 bytes: DCDart has no mutable static data (GAP-0053) and
// the allocator did not exist yet. ROADMAP.md said so in the sharpest possible
// terms -- "the kernel can now read a disk and has nowhere to put what it
// read." M7 answered that, and this is the first caller to take it up.
//
// STILL ZERO DONATED `.bss`. The destination is an address the CALLER owns --
// in practice a frame from `allocFrame()` -- so this adds nothing to
// `kdata.S`'s block and m6-disk's "the disk driver has no sector buffer"
// assertion is still true of this kernel. What changed is that the caller can
// now own one.
//
// It does NOT share code with [shellDiskRead]. The two differ in the middle
// (dump a word / store a word) and in the ends (report / return a status), and
// the shape that would let them share -- a callback, or a flag threaded through
// the transfer loop -- costs more than the twenty duplicated register writes.
// Merging them would also put a `@rodata` message write inside the path an ELF
// load takes 18 times, which is a real cost: m6's own golden is 7679 bytes of
// hexdump.
// ---------------------------------------------------------------------------

/// [ataReadInto] succeeded and 512 bytes are at the destination.
const int ataReadOk = 0;

/// Nothing answered on the channel -- status all-zeroes or all-ones.
const int ataReadNoDev = 1;

/// The drive never became ready, or reported ERR/DF before the command.
const int ataReadNotReady = 2;

/// The drive never raised DRQ, so there is no data to take.
const int ataReadNoDrq = 3;

/// The drive reported ERR or DF after the transfer.
const int ataReadError = 4;

/// DRQ was still set after 256 words -- the drive has more to say than one
/// sector, so the channel is not in a state the next command can trust.
const int ataReadTrailing = 5;

/// Reads LBA28 sector [lba] from the primary master into the 512 bytes at
/// [dst]. Returns [ataReadOk] or one of the codes above.
///
/// **Every failure returns a code and prints nothing.** The caller is an ELF
/// loader that has its own diagnostic vocabulary and its own idea of which
/// sector of which structure failed to arrive; a driver that printed here would
/// interleave `DISK ` lines into the middle of it and would still not say what
/// the sector was for.
///
/// The bytes are stored ONE AT A TIME out of each 16-bit port read, low byte
/// first, because that is the order they occupy in the sector -- the opposite
/// of the IDENTIFY model string, and correct for the same reason: the model is
/// a big-endian string field, sector data is just bytes. Byte stores rather
/// than a `u16` store because DC-IR's `Load`/`Store` carry no alignment
/// attribute and [dst] is chosen by the caller (multiboot.dart's split `u32`
/// loads make the same argument).
@bare
u64 ataReadInto(u64 lba, u64 dst) {
  final u64 st0 = ataSelect(lba);
  if (ataAbsent(st0) > u64(0)) {
    return u64(ataReadNoDev);
  }
  final u64 idle = ataWait(u64(ataStRdy));
  if (ataFailed(idle) > u64(0)) {
    return u64(ataReadNotReady);
  }

  Port.outb(u16(ataRegCount), u8(1));
  Port.outb(u16(ataRegLbaLo), (lba & u64(0xFF)).toU8());
  Port.outb(u16(ataRegLbaMid), ((lba >> u64(8)) & u64(0xFF)).toU8());
  Port.outb(u16(ataRegLbaHi), ((lba >> u64(16)) & u64(0xFF)).toU8());
  Port.outb(u16(ataRegCommand), u8(ataCmdReadSectors));

  final u64 st1 = ataSettle();
  if (ataAbsent(st1) > u64(0)) {
    return u64(ataReadNoDev);
  }
  final u64 st2 = ataWait(u64(ataStDrq));
  if (ataFailed(st2) > u64(0)) {
    return u64(ataReadNoDrq);
  }
  // BSY is clear and neither error bit is set, so DRQ is the only remaining
  // reason ataWait could have returned. Checked anyway, for shellDiskRead's
  // reason: reading 512 bytes from a data port the drive has not filled is the
  // one failure here that would produce plausible-looking output -- and here it
  // would produce a plausible-looking PROGRAM.
  if ((st2 & u64(ataStDrq)) < u64(1)) {
    return u64(ataReadNoDrq);
  }

  u64 i = u64(0);
  while (i < u64(ataWordsPerSector)) {
    final u64 w = port_inw(u64(ataRegData));
    final u64 at = dst + (i << u64(1));
    Pointer<u8>.fromAddress(at).value = (w & u64(0xFF)).toU8();
    Pointer<u8>.fromAddress(at + u64(1)).value = ((w >> u64(8)) & u64(0xFF)).toU8();
    i = i + u64(1);
  }

  final u64 st3 = Port.inb(u16(ataRegStatus)).toU64();
  if ((st3 & (u64(ataStErr) | u64(ataStDf))) > u64(0)) {
    return u64(ataReadError);
  }
  if ((st3 & u64(ataStDrq)) > u64(0)) {
    return u64(ataReadTrailing);
  }
  return u64(ataReadOk);
}

// ---------------------------------------------------------------------------
// M16 (docs/decisions/0020-writing-to-a-disk.md): WRITE ONE SECTOR.
//
// THIS IS THE FIRST CODE IN THIS KERNEL THAT CAN CHANGE A DISK. Everything
// above it can only look. The status discipline is [ataReadInto]'s, in the same
// order and with the same bounds, and the differences are exactly three:
//
//   1. THE TRANSFER GOES THE OTHER WAY, through `port_outw` rather than
//      `port_inw`, and the two bytes of each word are assembled low-first out
//      of the source buffer for the same reason the read path takes them apart
//      low-first: sector data is bytes, and a `u16` store would be trusting the
//      CPU's byte order to match the disk's.
//
//   2. THE DRIVE IS BUSY AFTER THE DATA, NOT BEFORE IT. A read ends when the
//      last word leaves the data port; a write ends when the drive has taken
//      the last word and finished with it, so this waits for BSY to clear and
//      DRDY to return AFTER the loop, and treats a still-set DRQ as the drive
//      wanting more than one sector -- which would mean the channel is in a
//      state the next command cannot trust.
//
//   3. IT ENDS WITH FLUSH CACHE, ALWAYS. See [ataCmdCacheFlush]. A write that
//      "succeeded" into a volatile cache and a write that reached the medium
//      are indistinguishable from the host side until the power goes off, and
//      the whole claim M16 makes is about what is on the image afterwards.
//
// NO RETRIES. A failed write returns a code and the caller decides; a driver
// that retried would turn one bad sector into several attempts to write it and
// would still not know whether the first attempt had landed.
// ---------------------------------------------------------------------------

/// [ataWriteFrom] succeeded: 512 bytes were transferred and FLUSH CACHE
/// completed without an error.
const int ataWriteOk = 0;

/// Nothing answered on the channel -- status all-zeroes or all-ones.
const int ataWriteNoDev = 1;

/// The drive never became ready, or reported ERR/DF before the command.
const int ataWriteNotReady = 2;

/// The drive never raised DRQ, so it is not asking for the data.
const int ataWriteNoDrq = 3;

/// The drive reported ERR or DF after the transfer.
const int ataWriteError = 4;

/// DRQ was still set after 256 words -- the drive wants more than one sector's
/// worth, so the channel is not in a state the next command can trust.
const int ataWriteTrailing = 5;

/// The transfer completed and FLUSH CACHE did not. The bytes may be in the
/// drive's cache and may not be on the medium; this is reported as its own code
/// rather than folded into [ataWriteError] because the two mean different
/// things to anyone deciding whether to trust the volume.
const int ataWriteNoFlush = 6;

/// Issues FLUSH CACHE (0xE7) on the primary master and waits for it.
///
/// Selects the drive again first: this is called immediately after a transfer,
/// but a caller that had touched the channel in between would otherwise be
/// flushing whichever device was selected last. The LBA bits of the
/// drive/head register are irrelevant to this command and are written as zero.
@bare
u64 ataFlushCache() {
  final u64 st0 = ataSelect(u64(0));
  if (ataAbsent(st0) > u64(0)) {
    return u64(ataWriteNoDev);
  }
  Port.outb(u16(ataRegCommand), u8(ataCmdCacheFlush));
  final u64 st1 = ataSettle();
  if (ataAbsent(st1) > u64(0)) {
    return u64(ataWriteNoDev);
  }
  final u64 st2 = ataWait(u64(ataStRdy));
  if (ataFailed(st2) > u64(0)) {
    return u64(ataWriteNoFlush);
  }
  return u64(ataWriteOk);
}

/// Writes the 512 bytes at [src] to LBA28 sector [lba] on the primary master,
/// then flushes the drive's cache. Returns [ataWriteOk] or one of the codes
/// above.
///
/// **Every failure returns a code and prints nothing**, for [ataReadInto]'s
/// reason: the caller is a filesystem that knows which sector of which
/// structure it was trying to change, and a driver that printed here would say
/// less while interleaving itself into somebody else's transcript.
@bare
u64 ataWriteFrom(u64 lba, u64 src) {
  final u64 st0 = ataSelect(lba);
  if (ataAbsent(st0) > u64(0)) {
    return u64(ataWriteNoDev);
  }
  final u64 idle = ataWait(u64(ataStRdy));
  if (ataFailed(idle) > u64(0)) {
    return u64(ataWriteNotReady);
  }

  Port.outb(u16(ataRegCount), u8(1));
  Port.outb(u16(ataRegLbaLo), (lba & u64(0xFF)).toU8());
  Port.outb(u16(ataRegLbaMid), ((lba >> u64(8)) & u64(0xFF)).toU8());
  Port.outb(u16(ataRegLbaHi), ((lba >> u64(16)) & u64(0xFF)).toU8());
  Port.outb(u16(ataRegCommand), u8(ataCmdWriteSectors));

  final u64 st1 = ataSettle();
  if (ataAbsent(st1) > u64(0)) {
    return u64(ataWriteNoDev);
  }
  final u64 st2 = ataWait(u64(ataStDrq));
  if (ataFailed(st2) > u64(0)) {
    return u64(ataWriteNoDrq);
  }
  // BSY is clear and neither error bit is set, so DRQ is the only remaining
  // reason ataWait could have returned. Checked anyway, and here the cost of
  // not checking is worse than on the read path: pushing 512 bytes at a data
  // port the drive is not expecting is not a wrong answer, it is a wrong
  // SECTOR somewhere on the volume.
  if ((st2 & u64(ataStDrq)) < u64(1)) {
    return u64(ataWriteNoDrq);
  }

  u64 i = u64(0);
  while (i < u64(ataWordsPerSector)) {
    final u64 at = src + (i << u64(1));
    final u64 lo = Pointer<u8>.fromAddress(at).value.toU64();
    final u64 hi = Pointer<u8>.fromAddress(at + u64(1)).value.toU64();
    port_outw(u64(ataRegData), lo | (hi << u64(8)));
    i = i + u64(1);
  }

  // The drive raises BSY when it takes the last word. Four alt-status reads
  // (400ns) before the first real poll, exactly as after issuing a command --
  // ATA/ATAPI-6 §6.2 makes the same requirement of both edges.
  final u64 st3 = ataSettle();
  if (ataAbsent(st3) > u64(0)) {
    return u64(ataWriteNoDev);
  }
  final u64 st4 = ataWait(u64(ataStRdy));
  if (ataFailed(st4) > u64(0)) {
    return u64(ataWriteError);
  }
  if ((st4 & u64(ataStDrq)) > u64(0)) {
    return u64(ataWriteTrailing);
  }
  return ataFlushCache();
}

/// `disk read <lba>` -- one LBA28 sector from the primary master.
@bare
void shellDiskRead(u64 lba) {
  uartWrite(Rodata.addressOf(ataStrReadLbl), u64(14));
  uartPutHex(lba, u64(8));
  uartNewline();

  final u64 st0 = ataSelect(lba);
  if (ataAbsent(st0) > u64(0)) {
    ataReportNoDev(st0);
    return;
  }
  final u64 idle = ataWait(u64(ataStRdy));
  if (ataFailed(idle) > u64(0)) {
    ataReportFailure(u64(1), idle);
    return;
  }

  Port.outb(u16(ataRegCount), u8(1));
  Port.outb(u16(ataRegLbaLo), (lba & u64(0xFF)).toU8());
  Port.outb(u16(ataRegLbaMid), ((lba >> u64(8)) & u64(0xFF)).toU8());
  Port.outb(u16(ataRegLbaHi), ((lba >> u64(16)) & u64(0xFF)).toU8());
  Port.outb(u16(ataRegCommand), u8(ataCmdReadSectors));

  final u64 st1 = ataSettle();
  if (ataAbsent(st1) > u64(0)) {
    ataReportNoDev(st1);
    return;
  }
  final u64 st2 = ataWait(u64(ataStDrq));
  if (ataFailed(st2) > u64(0)) {
    ataReportFailure(u64(3), st2);
    return;
  }
  // BSY is clear and neither error bit is set, so DRQ is the only remaining
  // reason ataWait could have returned. Checked anyway: reading 512 bytes from
  // a data port the drive has not filled is the one failure here that would
  // produce plausible-looking output.
  if ((st2 & u64(ataStDrq)) < u64(1)) {
    ataReportError(st2);
    return;
  }

  ataDumpSector();

  // After the block, the drive clears DRQ and must not be reporting an error.
  // `DISK READ END` is printed only if that is true, which is what makes it
  // evidence that 512 bytes were actually transferred rather than a line that
  // always follows the dump.
  final u64 st3 = Port.inb(u16(ataRegStatus)).toU64();
  if ((st3 & (u64(ataStErr) | u64(ataStDf))) > u64(0)) {
    ataReportError(st3);
    return;
  }
  if ((st3 & u64(ataStDrq)) > u64(0)) {
    ataReportError(st3);
    return;
  }
  uartWrite(Rodata.addressOf(ataStrReadEnd), u64(14));
}

// ---------------------------------------------------------------------------
// Parsing the argument. There is still no tokenizer (GAP-0057 item 3), so this
// is two byte ranges and a loop, exactly like command dispatch.
// ---------------------------------------------------------------------------

/// Value of [c] as a hex digit, or 0x100 if it is not one.
///
/// Both cases are accepted because the shell has no shift handling on the
/// letter keys worth relying on and because a user who types `1f` means the
/// same thing as one who types `1F`.
@bare
u64 ataHexDigit(u8 c) {
  if (c < u8(0x30)) {
    return u64(0x100);
  }
  if (c < u8(0x3A)) {
    return (c - u8(0x30)).toU64(); // '0'..'9'
  }
  if (c < u8(0x41)) {
    return u64(0x100);
  }
  if (c < u8(0x47)) {
    return (c - u8(0x37)).toU64(); // 'A'..'F'
  }
  if (c < u8(0x61)) {
    return u64(0x100);
  }
  if (c < u8(0x67)) {
    return (c - u8(0x57)).toU64(); // 'a'..'f'
  }
  return u64(0x100);
}

/// Parses the line buffer from [from] to the end as a hex LBA.
///
/// Returns [ataLba28Limit] or more for ANY failure -- empty, too long, a
/// non-hex byte -- because every failure is rejected by the same bound check
/// the address itself has to pass, so the caller needs one test rather than
/// four. Values are LBA28 addresses: 28 bits is seven hex digits, and an
/// eighth digit is rejected here rather than silently truncated into the
/// drive/head register's low nibble.
@bare
u64 ataParseLba(u64 from) {
  final u64 len = shellLen();
  if (len < from + u64(1)) {
    return u64(ataLba28Limit); // nothing after the space
  }
  if (len - from > u64(7)) {
    return u64(ataLba28Limit); // more digits than LBA28 has
  }
  u64 v = u64(0);
  u64 i = from;
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d > u64(0xF)) {
      return u64(ataLba28Limit);
    }
    v = (v << u64(4)) | d;
    i = i + u64(1);
  }
  return v;
}

/// `disk read <lba>` from the shell: parse, bound-check, then read.
@bare
void shellDiskReadCmd() {
  final u64 lba = ataParseLba(u64(10));
  if (lba > u64(ataLba28Max)) {
    uartWrite(Rodata.addressOf(ataStrBadLba), u64(52));
    return;
  }
  shellDiskRead(lba);
}

/// `disk` with no argument, or with one this shell does not know.
@bare
void shellDiskUsage() {
  uartWrite(Rodata.addressOf(ataStrUsage), u64(43));
}
