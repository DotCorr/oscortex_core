// core/kernel/multiboot.dart
//
// Multiboot1 information-structure reader. Closes the FIRST item of
// docs/known-gaps.md GAP-0001: "Multiboot's EBX (info struct pointer) is
// never read. The kernel doesn't know how much RAM exists." It does now --
// boot.S hands the pointer to kmain() as a plain C-ABI argument (RDI), and
// this file walks the structure and reports it over COM1.
//
// A `part of 'kmain.dart'` for the same forced reason uart.dart is -- see
// that file's header and docs/known-gaps.md GAP-0004.
//
// ---------------------------------------------------------------------------
// Multiboot1 information structure (the subset this reads), byte offsets:
//
//   +0   flags        u32   bit 0 => mem_lower/mem_upper valid
//                           bit 6 => mmap_length/mmap_addr valid
//   +4   mem_lower    u32   KiB of conventional memory below 1MiB
//   +8   mem_upper    u32   KiB of memory above 1MiB
//   +12  boot_device  u32   (not read)
//   +16  cmdline      u32   (not read)
//   +20  mods_count   u32   (not read)
//   +24  mods_addr    u32   (not read)
//   +28  syms[0..3]   u32x4 (not read)
//   +44  mmap_length  u32   total bytes of the mmap buffer
//   +48  mmap_addr    u32   physical address of the mmap buffer
//
// Each memory-map entry, at mmap_addr + running offset:
//
//   +0   size         u32   size of THIS entry EXCLUDING the size field
//                           itself, so the stride is (size + 4)
//   +4   base_addr    u64
//   +12  length       u64
//   +20  type         u32   1 = usable RAM, anything else = not usable
//
// ---------------------------------------------------------------------------
// Reading the 32-bit fields.
//
// UPDATE 2026-08-20: this file used to read every u32 field as a MASKED
// 8-BYTE LOAD at an 8-aligned address, because DCDart had no width conversion
// of any kind -- a `u32` could not become a `Pointer` address, a loop bound
// or a stride, so eight bytes had to be loaded and shifted to get one of
// these fields into the `u64` domain. That needed three runtime 8-alignment
// guards, because Multiboot1 promises only 4-byte alignment and DCDart's
// `Load` carries no alignment attribute, so the load was only well-defined if
// the address happened to be 8-aligned.
//
// `.toU64()` (DCDart ADR-0037) removed the whole problem. Each field is now
// an ordinary `Pointer<u32>` load widened explicitly, and the guards check
// the 4-byte alignment Multiboot1 actually GUARANTEES rather than an
// 8-byte one it does not. The alignment checks are kept -- a malformed
// hand-off is a real failure mode and a distinct marker beats a wrong number
// -- but they now verify the spec's own promise instead of covering for a
// missing language primitive.
//
// Fields that are only PRINTED, never computed with, are read a byte at a
// time by uartPutHex32At/uartPutHex64At and need no conversion at all.
// ---------------------------------------------------------------------------

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text.
//
// `@rodata` byte tables (DCDart ADR-0040). These used to be runs of one
// `uartPutc` call per character -- `@bare` DCDart had no String type, no array
// type and no static data, so there was no other way to spell a literal
// message. See uart.dart's `uartWrite` and docs/known-gaps.md GAP-0004 item 6.
//
// Each table's byte count is in its doc comment and is repeated at the call
// site, because a `@rodata` table carries no length word (ADR-0040: elements
// only, no header). A wrong count is caught immediately -- every byte printed
// here is asserted byte-for-byte by tests/conformance/mb-info/run.sh.
// ---------------------------------------------------------------------------

/// Line label: `"MB FLAGS "` — 9 bytes.
@rodata
final List<u8> mbStrFlags = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x46), u8(0x4C), u8(0x41), u8(0x47), u8(0x53), u8(0x20)];

/// Line label: `"MB LOW "` — 7 bytes.
@rodata
final List<u8> mbStrLow = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x4C), u8(0x4F), u8(0x57), u8(0x20)];

/// Line label: `"MB UPP "` — 7 bytes.
@rodata
final List<u8> mbStrUpp = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x55), u8(0x50), u8(0x50), u8(0x20)];

/// Line label: `"MB MAP "` — 7 bytes.
@rodata
final List<u8> mbStrMap = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x4D), u8(0x41), u8(0x50), u8(0x20)];

/// Line label: `"MB E "` — 5 bytes.
@rodata
final List<u8> mbStrEntry = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x45), u8(0x20)];

/// Diagnostic prefix, followed by one marker char and a newline: `"MB BAD"` — 6 bytes.
@rodata
final List<u8> mbStrBad = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x42), u8(0x41), u8(0x44)];

/// Complete line: `"MB NOMEM\n"` — 9 bytes.
@rodata
final List<u8> mbStrNoMem = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x4E), u8(0x4F), u8(0x4D), u8(0x45), u8(0x4D), u8(0x0A)];

/// Complete line: `"MB NOMAP\n"` — 9 bytes.
@rodata
final List<u8> mbStrNoMap = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x4E), u8(0x4F), u8(0x4D), u8(0x41), u8(0x50), u8(0x0A)];

/// Complete line: `"MB END\n"` — 7 bytes.
@rodata
final List<u8> mbStrEnd = const [u8(0x4D), u8(0x42), u8(0x20), u8(0x45), u8(0x4E), u8(0x44), u8(0x0A)];



/// Reads the 32-bit field at [addr] and widens it to `u64`.
///
/// [addr] must be 4-byte aligned, which is what Multiboot1 guarantees and
/// what callers check before calling.
@bare
u64 mbU32(u64 addr) {
  return Pointer<u32>.fromAddress(addr).value.toU64();
}

/// `MB BAD<c>` -- a one-line diagnostic marker. [c] distinguishes which check
/// failed: 'P' = info pointer not 4-aligned, 'M' = mmap buffer not 4-aligned,
/// 'E' = an entry not 4-aligned, 'S' = an entry reported size 0 (which would
/// make the walk loop forever).
@bare
void mbBad(u8 c) {
  uartWrite(Rodata.addressOf(mbStrBad), u64(6));
  conPutc(c);
  uartNewline();
}

/// `MB FLAGS xxxxxxxx`
@bare
void mbReportFlags(u64 info) {
  uartWrite(Rodata.addressOf(mbStrFlags), u64(9));
  uartPutHex32At(info);
  uartNewline();
}

/// `MB LOW xxxxxxxx` -- mem_lower, in KiB, straight out of the structure.
@bare
void mbReportLow(u64 info) {
  uartWrite(Rodata.addressOf(mbStrLow), u64(7));
  uartPutHex32At(info + u64(4));
  uartNewline();
}

/// `MB UPP xxxxxxxx` -- mem_upper, in KiB.
@bare
void mbReportUpper(u64 info) {
  uartWrite(Rodata.addressOf(mbStrUpp), u64(7));
  uartPutHex32At(info + u64(8));
  uartNewline();
}

/// `MB NOMEM` -- flags bit 0 clear, so mem_lower/mem_upper are meaningless
/// and are deliberately NOT printed rather than printed as garbage.
@bare
void mbNoMem() {
  uartWrite(Rodata.addressOf(mbStrNoMem), u64(9));
}

/// `MB NOMAP` -- flags bit 6 clear, so there is no memory map to walk.
@bare
void mbNoMap() {
  uartWrite(Rodata.addressOf(mbStrNoMap), u64(9));
}

/// `MB MAP <mmap_length> <mmap_addr>` -- both as raw 8-digit hex, read
/// straight out of the structure at +44 and +48.
@bare
void mbReportMapHeader(u64 info) {
  uartWrite(Rodata.addressOf(mbStrMap), u64(7));
  uartPutHex32At(info + u64(44));
  uartSpace();
  uartPutHex32At(info + u64(48));
  uartNewline();
}

/// `MB E <base_addr:16> <length:16> <type:8>` for one entry at [entry].
@bare
void mbReportEntry(u64 entry) {
  uartWrite(Rodata.addressOf(mbStrEntry), u64(5));
  uartPutHex64At(entry + u64(4)); // base_addr
  uartSpace();
  uartPutHex64At(entry + u64(12)); // length
  uartSpace();
  uartPutHex32At(entry + u64(20)); // type
  uartNewline();
}

/// `MB END` -- terminator, so the harness can assert the report is COMPLETE
/// and not truncated by a hang partway through.
@bare
void mbEnd() {
  uartWrite(Rodata.addressOf(mbStrEnd), u64(7));
}

/// Walks the memory map and prints one `MB E` line per entry.
///
/// Bails out with a distinct `MB BAD<c>` marker rather than continuing on any
/// structural problem: a non-8-aligned entry (the 8-byte size load would be
/// unaligned) or a zero-size entry (the walk would never advance and would
/// spin forever with interrupts disabled). Both are real failure modes of a
/// malformed loader hand-off, not hypothetical.
@bare
void mbWalkMmap(u64 mmapAddr, u64 mmapLen) {
  u64 off = u64(0);
  while (off < mmapLen) {
    final u64 entry = mmapAddr + off;
    if ((entry & u64(3)) > u64(0)) {
      mbBad(u8(0x45)); // 'E'
      return;
    }
    final u64 size = mbU32(entry);
    if (size < u64(1)) {
      mbBad(u8(0x53)); // 'S'
      return;
    }
    mbReportEntry(entry);
    off = off + size + u64(4);
  }
}

/// Reads the Multiboot1 information structure at [info] and reports it over
/// COM1. Returns nothing -- the report IS the result (there is no storage to
/// put a parsed memory map into yet: DCDart has no static/global data and this
/// kernel has no allocator, so nothing can outlive this call. Recorded in
/// docs/known-gaps.md GAP-0001; the memory map is now READ and REPORTED, not
/// yet RETAINED).
@bare
void mbReport(u64 info) {
  // Multiboot1 promises the information structure is 4-byte aligned. Check
  // it rather than assume it: a misaligned hand-off means the loader is not
  // doing what the spec says, and a distinct marker beats a wrong number.
  if ((info & u64(3)) > u64(0)) {
    mbBad(u8(0x50)); // 'P'
    return;
  }

  mbReportFlags(info);

  // flags bit 0 and bit 6 both live in the LOW BYTE of flags, so they can be
  // tested with a plain u8 load -- no widening needed at all here.
  final u8 flagsLow = Pointer<u8>.fromAddress(info).value;

  if ((flagsLow & u8(0x01)) < u8(1)) {
    mbNoMem();
  } else {
    mbReportLow(info);
    mbReportUpper(info);
  }

  if ((flagsLow & u8(0x40)) < u8(1)) {
    mbNoMap();
    mbEnd();
    return;
  }

  mbReportMapHeader(info);

  final u64 mmapLen = mbU32(info + u64(44));
  final u64 mmapAddr = mbU32(info + u64(48));

  if ((mmapAddr & u64(3)) > u64(0)) {
    mbBad(u8(0x4D)); // 'M'
    mbEnd();
    return;
  }

  mbWalkMmap(mmapAddr, mmapLen);
  mbEnd();
}
