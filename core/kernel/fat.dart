// core/kernel/fat.dart
//
// oscortex_core M14: A READ-ONLY FAT16 FILESYSTEM.
// oscortex_core M16: AND A WRITE PATH -- allocation, truncation, directory
// entries, and both copies of the FAT.
//
// **THE WRITE HALF STARTS AT `fatPut16` AND IS DOCUMENTED THERE**, with the
// five ordering rules it keeps and why each one matters. Everything above that
// point reads and nothing above it can change a volume. The architecture is
// docs/decisions/0020-writing-to-a-disk.md.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS REPLACES, AND WHY IT IS A STRUCTURAL CHANGE RATHER THAN A FEATURE
// ---------------------------------------------------------------------------
// Until this file existed, "getting a program onto the disk" meant a Python
// script writing 32 bytes -- `"OSCXPRG1"`, a length, an LBA -- at a sector
// number it then told the harness, and `run 20` meant SECTOR 0x20. That is the
// whole of docs/known-gaps.md GAP-0090: no names, no directory, no allocation.
//
// This file adds names, a directory and a chain. At M14 it did NOT add writes
// and said so everywhere rather than leaving it to be discovered (GAP-0116); at
// M16 it adds them, and GAP-0127 is the list of what a program still cannot do.
// GAP-0090 items 3 and 4 are narrowed rather than closed: there is an allocator
// and there is no journal.
//
// ---------------------------------------------------------------------------
// FAT16 IS NOT A FLAG IN THE BOOT SECTOR, AND THIS DRIVER DOES NOT PRETEND IT IS
// ---------------------------------------------------------------------------
// `BS_FilSysType` at offset 54 spells "FAT16   " on this volume and spells
// whatever the formatter felt like on the next one. Microsoft's specification
// is explicit that the type is determined by ONE COMPUTED QUANTITY and nothing
// else -- the count of data clusters:
//
//     CountOfClusters <  4085   ->  FAT12
//     CountOfClusters < 65525   ->  FAT16
//     otherwise                 ->  FAT32
//
// so [fatMount] computes it and refuses FAT12 and FAT32 BY NAME, with two
// different refusal codes, and never looks at the string. A driver that read
// the string would read a FAT12 volume as FAT16 and every 12-bit chain entry
// would be a plausible 16-bit cluster number pointing somewhere else -- the
// exact failure mode that produces a "corrupt" file rather than an error.
//
// ---------------------------------------------------------------------------
// THE CHAIN IS WALKED. THIS IS THE WHOLE POINT AND IT IS TESTED ADVERSARIALLY.
// ---------------------------------------------------------------------------
// A file on a freshly-written volume is contiguous, so a driver that ignores
// the FAT entirely and reads `size` bytes forward from the first cluster passes
// every test anybody writes by accident. `m14-fat/make-image.py` therefore
// writes an image on which NOTHING is contiguous: the two programs take the odd
// and the even clusters and are interleaved slab by slab, and the text file's
// two clusters are 98 apart. A contiguous reader on that image does not get
// garbage -- it gets half of the other program.
//
// The chain is materialised ONCE, at [fatOpen], into `fat_store`'s 256-entry
// chain array, rather than re-walked per sector. That is not an optimisation:
// it is what makes the three integrity checks below possible in one place.
//
//   * A cluster number outside [2, clusterCount + 2) is `fatErrChainRange`.
//   * A link to cluster 0 (FREE) is `fatErrChainFree`; to 0xFFF7 (BAD) is
//     `fatErrChainBad`. Neither is "end of chain" and neither may be followed.
//   * A cluster already in the chain is `fatErrChainCycle`, detected by
//     scanning what has been collected so far. A cycle is what a corrupt FAT
//     produces, and a driver that only stopped at an end mark would spin
//     forever on one.
//   * The chain's length must AGREE with the directory entry's size, in both
//     directions: `fatErrChainShort` if it ends early, `fatErrChainLong` if the
//     link after the last expected cluster is not an end mark.
//
// ---------------------------------------------------------------------------
// EIGHT-POINT-THREE ONLY, AND THAT IS A REFUSAL RATHER THAN A SILENT TRUNCATION
// ---------------------------------------------------------------------------
// Long-filename entries (attribute 0x0F) are SKIPPED by [shellFatLs] and are
// invisible to [fatFind]. A file whose only reachable name is its long one is
// therefore reachable here only by its 8.3 alias, which is what the directory
// actually stores. `m14-fat`'s image carries three real LFN entries in front of
// `PROGB.ELF` precisely so that a driver that printed them as 8.3 names would
// print three lines of UTF-16 rendered as Latin-1, which is unmistakable.
//
// ---------------------------------------------------------------------------
// THE STORAGE SEAM (ADR-0011 section 0, for the fifth time)
// ---------------------------------------------------------------------------
// DCDart has no mutable static data of any kind (GAP-0053), so every byte of
// filesystem state is assembly-donated `.bss`: ONE symbol, `fat_store`, reached
// through ONE `@extern` accessor, called from exactly FOUR places in this file
// -- [fatMetaBase], [fatChainBase], [fatSectorBase] and [fatNameBase]. Nothing
// else in this file, and nothing anywhere else in the kernel, knows where those
// bytes came from. `tests/conformance/m14-fat/run.sh` COUNTS the call sites; a
// fifth fails the harness.
//
// See docs/decisions/0018-a-read-only-fat16-filesystem.md.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The BPB, field by field. Offsets into the boot sector; every one of them is
// read with [fatU16] or a byte load, never with a wider load, because a boot
// sector is a byte array off a disk and DC-IR's `Load` carries no alignment
// attribute (the same argument multiboot.dart's header makes).
// ---------------------------------------------------------------------------

/// `BPB_BytsPerSec`, u16. Must be 512 -- see [fatErrSectorSize].
const int fatBpbBytesPerSec = 11;

/// `BPB_SecPerClus`, u8. A power of two, 1..128.
const int fatBpbSecPerClus = 13;

/// `BPB_RsvdSecCnt`, u16. Where the first FAT starts. 1 on a FAT16 volume.
const int fatBpbRsvdSecCnt = 14;

/// `BPB_NumFATs`, u8. 1 or 2.
const int fatBpbNumFats = 16;

/// `BPB_RootEntCnt`, u16. 0 on FAT32, which is one of the two ways this driver
/// notices a FAT32 boot sector before it has computed anything.
const int fatBpbRootEntCnt = 17;

/// `BPB_TotSec16`, u16. 0 when the volume needs 32 bits, in which case
/// `BPB_TotSec32` carries it.
const int fatBpbTotSec16 = 19;

/// `BPB_Media`, u8. Its value is also required to be the low byte of FAT[0].
const int fatBpbMedia = 21;

/// `BPB_FATSz16`, u16. 0 on FAT32.
const int fatBpbFatSz16 = 22;

/// `BPB_TotSec32`, u32.
const int fatBpbTotSec32 = 32;

/// The `0x55 0xAA` at the end of the boot sector.
const int fatBpbSigOff = 510;
const int fatBpbSig = 0xAA55;

/// One directory entry is 32 bytes, on every FAT variant ever shipped.
const int fatDirEntBytes = 32;

/// Offsets inside one directory entry.
const int fatDirOffName = 0;
const int fatDirOffAttr = 11;
const int fatDirOffCluster = 26;
const int fatDirOffSize = 28;

/// The 11 raw bytes of an 8.3 name: 8 of stem, 3 of extension, space-padded,
/// no dot.
const int fatNameBytes = 11;

/// Directory-entry attribute bits.
const int fatAttrReadOnly = 0x01;
const int fatAttrHidden = 0x02;
const int fatAttrSystem = 0x04;
const int fatAttrVolumeId = 0x08;
const int fatAttrDirectory = 0x10;

/// The archive bit. M16 sets exactly this and nothing else on a file it
/// creates: a plain file, not read-only, not hidden, not a system file, not a
/// volume label and not a directory. `fsck_msdos` and macOS's `msdos` driver
/// both have to accept it, which is the check that makes the choice load-bearing
/// rather than cosmetic.
const int fatAttrArchive = 0x20;

/// The long-filename attribute is all four of the first bits at once, and it is
/// tested as an exact value rather than as a mask because that is what makes it
/// distinguishable from a read-only hidden system file.
const int fatAttrLongName = 0x0F;

/// First byte of a directory entry: 0x00 means this entry and every entry after
/// it in this directory is free (the walk may stop); 0xE5 means this one entry
/// was deleted.
const int fatDirFree = 0x00;
const int fatDirDeleted = 0xE5;

/// The FAT16 band, from Microsoft's specification. Both bounds are refusals.
const int fatFat12Max = 4085;
const int fatFat16Max = 65525;

/// End-of-chain marks are anything from 0xFFF8 up. 0xFFF7 is BAD and 0x0000 is
/// FREE, and neither is an end mark.
const int fatEocMin = 0xFFF8;
const int fatBadCluster = 0xFFF7;
const int fatFreeCluster = 0x0000;

/// The first legal data cluster. Entries 0 and 1 of the FAT are not clusters.
const int fatFirstCluster = 2;

/// 512 bytes, twice: this driver reads 512-byte sectors and refuses a volume
/// whose sectors are a different size.
const int fatSectorBytes = 512;
const int fatSectorShift = 9;

/// Two bytes per FAT16 entry, hence 256 entries per sector.
const int fatEntriesPerSector = 256;

/// The bound on a chain, and therefore on a file: 256 clusters. At this image's
/// 1KiB clusters that is 256KiB, four times [elfImageMax]. A file that needs
/// more is `fatErrTooBig` and says so; it is not truncated.
const int fatChainMax = 256;

// ---------------------------------------------------------------------------
// `fat_store` -- the donated block. 1824 bytes, four regions, ONE symbol.
// ---------------------------------------------------------------------------

/// Byte offsets of the four regions inside `fat_store`.
const int fatMetaOffset = 0;
const int fatChainOffset = 256;
const int fatSectorOffset = 1280;
const int fatNameOffset = 1792;
const int fatStoreBytes = 1824;

/// 32 metadata words.
const int fatMetaWords = 32;

const int fatMetaReady = 0;
const int fatMetaBytesPerSec = 1;
const int fatMetaSecPerClus = 2;
const int fatMetaReserved = 3;
const int fatMetaNumFats = 4;
const int fatMetaFatSectors = 5;
const int fatMetaRootEntries = 6;
const int fatMetaTotalSectors = 7;
const int fatMetaFatStart = 8;
const int fatMetaRootStart = 9;
const int fatMetaRootSectors = 10;
const int fatMetaDataStart = 11;
const int fatMetaClusters = 12;
const int fatMetaStatus = 13;

/// 1 while a file is open, i.e. while the chain array describes it. **Read by
/// `elf.dart`**: it is what makes `run <name>` fetch sectors through the chain
/// and `run <lba>` fetch them contiguously, without the loader growing a second
/// copy of the decision.
const int fatMetaOpen = 14;
const int fatMetaFileFirst = 15;
const int fatMetaFileBytes = 16;
const int fatMetaFileClusters = 17;
const int fatMetaFileAttr = 18;
const int fatMetaFileEntry = 19;

/// The LBA currently in the sector buffer, or [fatNoSector].
const int fatMetaCached = 20;

/// Counters the last `ls` produced, so the harness can check the three add up.
const int fatMetaEntries = 21;
const int fatMetaListed = 22;
const int fatMetaSkipped = 23;

/// Sectors this driver has read since boot. Every read goes through
/// [fatReadCached] or [fatReadSector], and both count.
const int fatMetaReads = 24;

/// Reads the one-sector cache satisfied without touching the drive. The
/// difference between this and [fatMetaReads] is the whole of GAP-0090 item 8's
/// narrowing, and it is a number rather than a claim.
const int fatMetaHits = 25;

/// M16: sectors this driver has WRITTEN since boot, allocations made, clusters
/// freed, and the cluster to start the next free-cluster search from.
///
/// [fatMetaWrites] is the number this milestone exists to make non-zero. It is
/// printed by `fileWriteReport` and it is zero on every boot of every harness
/// before M16 — which is how m14-fat and m15-fileio now prove they still write
/// nothing, by RUNNING rather than by grepping for an opcode.
///
/// [fatMetaNextFree] is a HINT and nothing more: [fatFindFree] wraps, so a
/// stale or wrong value costs a longer scan and cannot cost a wrong cluster.
const int fatMetaWrites = 26;
const int fatMetaAllocs = 27;
const int fatMetaFrees = 28;
const int fatMetaNextFree = 29;

/// A cached LBA that cannot be a real one. Sector 0 IS real (it is the boot
/// sector), so 0 would be wrong here.
const int fatNoSector = 0xFFFFFFFFFFFFFFFF;

// ---------------------------------------------------------------------------
// Refusal codes. Zero is success; every other value has a sentence.
// ---------------------------------------------------------------------------

const int fatErrOk = 0;
const int fatErrDiskBoot = 1;
const int fatErrSignature = 2;
const int fatErrSectorSize = 3;
const int fatErrClusterSize = 4;
const int fatErrReserved = 5;
const int fatErrFatCount = 6;
const int fatErrFat32Shape = 7;
const int fatErrRootEntries = 8;
const int fatErrTotalZero = 9;
const int fatErrGeometry = 10;
const int fatErrFat12 = 11;
const int fatErrFat32 = 12;
const int fatErrFatSize = 13;
const int fatErrMedia = 14;
const int fatErrDiskDir = 15;
const int fatErrNotFound = 16;
const int fatErrIsDir = 17;
const int fatErrEmpty = 18;
const int fatErrTooBig = 19;
const int fatErrChainRange = 20;
const int fatErrChainFree = 21;
const int fatErrChainBad = 22;
const int fatErrChainCycle = 23;
const int fatErrChainLong = 24;
const int fatErrChainShort = 25;
const int fatErrDiskFat = 26;
const int fatErrDiskData = 27;
const int fatErrBadName = 28;

/// M16 (docs/decisions/0020-writing-to-a-disk.md): the three refusals a WRITE
/// can produce that a read never could. Each one leaves the volume exactly as
/// it was — that is the whole point of naming them rather than letting a
/// partial update stand.
const int fatErrFull = 29;
const int fatErrNoDirSlot = 30;
const int fatErrDiskWrite = 31;

/// The fourth write refusal, and the only one of the four that is about
/// PERMISSION rather than about the drive or the volume running out.
///
/// [fatAttrReadOnly] has been defined in this file since M14 and, until this
/// code existed, was **read by nothing**. `open(name, O_WRITE)` truncated a
/// file the volume marks read-only, from ring 3, with no refusal — see
/// docs/decisions/0024-the-read-only-attribute.md and GAP-0152. It is here in
/// `fat.dart` rather than in `file.dart` because the attribute byte is this
/// file's vocabulary: `file.dart` is not entitled to know that bit 0 of
/// `DIR_Attr` means anything.
const int fatErrReadOnly = 32;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// Byte counts are repeated at every call site because a `@rodata` table has no
// length word. Every one of these tables and its length was GENERATED from the
// string in its doc comment, and tests/conformance/m14-fat/run.sh reads each
// symbol's real size back out of the object file and compares it against the
// literal the call site passes -- GAP-0060's mitigation, applied from the start.
// ---------------------------------------------------------------------------

/// `'fs'` -- 2 bytes.
@rodata
final List<u8> fatCmdFs = const [
  u8(0x66), u8(0x73),
];

/// `'ls'` -- 2 bytes.
@rodata
final List<u8> fatCmdLs = const [
  u8(0x6C), u8(0x73),
];

/// `'cat'` -- 3 bytes.
@rodata
final List<u8> fatCmdCat = const [
  u8(0x63), u8(0x61), u8(0x74),
];

/// `'cat '` -- 4 bytes.
@rodata
final List<u8> fatCmdCatSp = const [
  u8(0x63), u8(0x61), u8(0x74), u8(0x20),
];

/// `'FS MOUNT BPS '` -- 13 bytes.
@rodata
final List<u8> fatStrMount = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x4D), u8(0x4F), u8(0x55), u8(0x4E), u8(0x54), u8(0x20), u8(0x42), u8(0x50), u8(0x53),
  u8(0x20),
];

/// `' SPC '` -- 5 bytes.
@rodata
final List<u8> fatStrSpc = const [
  u8(0x20), u8(0x53), u8(0x50), u8(0x43), u8(0x20),
];

/// `' RSV '` -- 5 bytes.
@rodata
final List<u8> fatStrRsv = const [
  u8(0x20), u8(0x52), u8(0x53), u8(0x56), u8(0x20),
];

/// `' NFAT '` -- 6 bytes.
@rodata
final List<u8> fatStrNfat = const [
  u8(0x20), u8(0x4E), u8(0x46), u8(0x41), u8(0x54), u8(0x20),
];

/// `' FATSZ '` -- 7 bytes.
@rodata
final List<u8> fatStrFatsz = const [
  u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x53), u8(0x5A), u8(0x20),
];

/// `' ROOT '` -- 6 bytes.
@rodata
final List<u8> fatStrRootc = const [
  u8(0x20), u8(0x52), u8(0x4F), u8(0x4F), u8(0x54), u8(0x20),
];

/// `' TOT '` -- 5 bytes.
@rodata
final List<u8> fatStrTot = const [
  u8(0x20), u8(0x54), u8(0x4F), u8(0x54), u8(0x20),
];

/// `'FS GEOM FAT '` -- 12 bytes.
@rodata
final List<u8> fatStrGeom = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x47), u8(0x45), u8(0x4F), u8(0x4D), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x20),
];

/// `' DATA '` -- 6 bytes.
@rodata
final List<u8> fatStrData = const [
  u8(0x20), u8(0x44), u8(0x41), u8(0x54), u8(0x41), u8(0x20),
];

/// `' CLUSTERS '` -- 10 bytes.
@rodata
final List<u8> fatStrClusters = const [
  u8(0x20), u8(0x43), u8(0x4C), u8(0x55), u8(0x53), u8(0x54), u8(0x45), u8(0x52), u8(0x53), u8(0x20),
];

/// `' TYPE '` -- 6 bytes.
@rodata
final List<u8> fatStrType = const [
  u8(0x20), u8(0x54), u8(0x59), u8(0x50), u8(0x45), u8(0x20),
];

/// `'FS ENT '` -- 7 bytes.
@rodata
final List<u8> fatStrEnt = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x45), u8(0x4E), u8(0x54), u8(0x20),
];

/// `' NAME '` -- 6 bytes.
@rodata
final List<u8> fatStrName = const [
  u8(0x20), u8(0x4E), u8(0x41), u8(0x4D), u8(0x45), u8(0x20),
];

/// `' ATTR '` -- 6 bytes.
@rodata
final List<u8> fatStrAttr = const [
  u8(0x20), u8(0x41), u8(0x54), u8(0x54), u8(0x52), u8(0x20),
];

/// `' CLUS '` -- 6 bytes.
@rodata
final List<u8> fatStrClus = const [
  u8(0x20), u8(0x43), u8(0x4C), u8(0x55), u8(0x53), u8(0x20),
];

/// `' SIZE '` -- 6 bytes.
@rodata
final List<u8> fatStrSize = const [
  u8(0x20), u8(0x53), u8(0x49), u8(0x5A), u8(0x45), u8(0x20),
];

/// `' DIR'` -- 4 bytes.
@rodata
final List<u8> fatStrDir = const [
  u8(0x20), u8(0x44), u8(0x49), u8(0x52),
];

/// `'FS LIST ENTRIES '` -- 16 bytes.
@rodata
final List<u8> fatStrList = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x4C), u8(0x49), u8(0x53), u8(0x54), u8(0x20), u8(0x45), u8(0x4E), u8(0x54), u8(0x52),
  u8(0x49), u8(0x45), u8(0x53), u8(0x20),
];

/// `' LISTED '` -- 8 bytes.
@rodata
final List<u8> fatStrListed = const [
  u8(0x20), u8(0x4C), u8(0x49), u8(0x53), u8(0x54), u8(0x45), u8(0x44), u8(0x20),
];

/// `' SKIPPED '` -- 9 bytes.
@rodata
final List<u8> fatStrSkipped = const [
  u8(0x20), u8(0x53), u8(0x4B), u8(0x49), u8(0x50), u8(0x50), u8(0x45), u8(0x44), u8(0x20),
];

/// `'FS OPEN '` -- 8 bytes.
@rodata
final List<u8> fatStrOpen = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x4F), u8(0x50), u8(0x45), u8(0x4E), u8(0x20),
];

/// `'FS CHAIN LEN '` -- 13 bytes.
@rodata
final List<u8> fatStrChain = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x43), u8(0x48), u8(0x41), u8(0x49), u8(0x4E), u8(0x20), u8(0x4C), u8(0x45), u8(0x4E),
  u8(0x20),
];

/// `' FIRST '` -- 7 bytes.
@rodata
final List<u8> fatStrFirst = const [
  u8(0x20), u8(0x46), u8(0x49), u8(0x52), u8(0x53), u8(0x54), u8(0x20),
];

/// `' LAST '` -- 6 bytes.
@rodata
final List<u8> fatStrLast = const [
  u8(0x20), u8(0x4C), u8(0x41), u8(0x53), u8(0x54), u8(0x20),
];

/// `'FS CLUS'` -- 7 bytes.
@rodata
final List<u8> fatStrClusL = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x43), u8(0x4C), u8(0x55), u8(0x53),
];

/// `'FS CAT '` -- 7 bytes.
@rodata
final List<u8> fatStrCat = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x43), u8(0x41), u8(0x54), u8(0x20),
];

/// `' BYTES '` -- 7 bytes.
@rodata
final List<u8> fatStrBytes = const [
  u8(0x20), u8(0x42), u8(0x59), u8(0x54), u8(0x45), u8(0x53), u8(0x20),
];

/// `'FS CAT END '` -- 11 bytes.
@rodata
final List<u8> fatStrCatEnd = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x43), u8(0x41), u8(0x54), u8(0x20), u8(0x45), u8(0x4E), u8(0x44), u8(0x20),
];

/// `'FS ERR '` -- 7 bytes.
@rodata
final List<u8> fatStrErr = const [
  u8(0x46), u8(0x53), u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20),
];

/// `'usage: cat <NAME.EXT> -- an 8.3 name in the root directory\n'` -- 59 bytes.
@rodata
final List<u8> fatStrCatUsage = const [
  u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A), u8(0x20), u8(0x63), u8(0x61), u8(0x74), u8(0x20), u8(0x3C),
  u8(0x4E), u8(0x41), u8(0x4D), u8(0x45), u8(0x2E), u8(0x45), u8(0x58), u8(0x54), u8(0x3E), u8(0x20), u8(0x2D), u8(0x2D),
  u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x38), u8(0x2E), u8(0x33), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65),
  u8(0x20), u8(0x69), u8(0x6E), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x74),
  u8(0x20), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x0A),
];

/// `'   or: run <NAME.EXT> -- an 8.3 name in the root directory\n'` -- 59 bytes.
@rodata
final List<u8> fatStrRunUsage = const [
  u8(0x20), u8(0x20), u8(0x20), u8(0x6F), u8(0x72), u8(0x3A), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x3C),
  u8(0x4E), u8(0x41), u8(0x4D), u8(0x45), u8(0x2E), u8(0x45), u8(0x58), u8(0x54), u8(0x3E), u8(0x20), u8(0x2D), u8(0x2D),
  u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x38), u8(0x2E), u8(0x33), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65),
  u8(0x20), u8(0x69), u8(0x6E), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x74),
  u8(0x20), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x0A),
];

// -------------------------------------------------------------------------

// Refusal text. One sentence per code, each naming the FIELD that was wrong.

// -------------------------------------------------------------------------

/// `'the boot sector could not be read off the primary master\n'` -- 57 bytes.
@rodata
final List<u8> fatStrE01 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x62), u8(0x6F), u8(0x6F), u8(0x74), u8(0x20), u8(0x73), u8(0x65), u8(0x63),
  u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F),
  u8(0x74), u8(0x20), u8(0x62), u8(0x65), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x20), u8(0x6F), u8(0x66),
  u8(0x66), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x69), u8(0x6D), u8(0x61), u8(0x72),
  u8(0x79), u8(0x20), u8(0x6D), u8(0x61), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x0A),
];

/// `'no 55AA signature at offset 510: this is not a FAT volume\n'` -- 58 bytes.
@rodata
final List<u8> fatStrE02 = const [
  u8(0x6E), u8(0x6F), u8(0x20), u8(0x35), u8(0x35), u8(0x41), u8(0x41), u8(0x20), u8(0x73), u8(0x69), u8(0x67), u8(0x6E),
  u8(0x61), u8(0x74), u8(0x75), u8(0x72), u8(0x65), u8(0x20), u8(0x61), u8(0x74), u8(0x20), u8(0x6F), u8(0x66), u8(0x66),
  u8(0x73), u8(0x65), u8(0x74), u8(0x20), u8(0x35), u8(0x31), u8(0x30), u8(0x3A), u8(0x20), u8(0x74), u8(0x68), u8(0x69),
  u8(0x73), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x61), u8(0x20), u8(0x46),
  u8(0x41), u8(0x54), u8(0x20), u8(0x76), u8(0x6F), u8(0x6C), u8(0x75), u8(0x6D), u8(0x65), u8(0x0A),
];

/// `'bytes-per-sector is not 512, and this driver reads 512-byte sectors\n'` -- 68 bytes.
@rodata
final List<u8> fatStrE03 = const [
  u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x73), u8(0x2D), u8(0x70), u8(0x65), u8(0x72), u8(0x2D), u8(0x73), u8(0x65),
  u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20),
  u8(0x35), u8(0x31), u8(0x32), u8(0x2C), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x74), u8(0x68), u8(0x69),
  u8(0x73), u8(0x20), u8(0x64), u8(0x72), u8(0x69), u8(0x76), u8(0x65), u8(0x72), u8(0x20), u8(0x72), u8(0x65), u8(0x61),
  u8(0x64), u8(0x73), u8(0x20), u8(0x35), u8(0x31), u8(0x32), u8(0x2D), u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x20),
  u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x73), u8(0x0A),
];

/// `'sectors-per-cluster is not a power of two between 1 and 128\n'` -- 60 bytes.
@rodata
final List<u8> fatStrE04 = const [
  u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x73), u8(0x2D), u8(0x70), u8(0x65), u8(0x72), u8(0x2D),
  u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x74), u8(0x20), u8(0x61), u8(0x20), u8(0x70), u8(0x6F), u8(0x77), u8(0x65), u8(0x72), u8(0x20), u8(0x6F),
  u8(0x66), u8(0x20), u8(0x74), u8(0x77), u8(0x6F), u8(0x20), u8(0x62), u8(0x65), u8(0x74), u8(0x77), u8(0x65), u8(0x65),
  u8(0x6E), u8(0x20), u8(0x31), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x31), u8(0x32), u8(0x38), u8(0x0A),
];

/// `'the reserved-sector count is 0, so the FAT would start inside the boot sector\n'` -- 78 bytes.
@rodata
final List<u8> fatStrE05 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x65), u8(0x73), u8(0x65), u8(0x72), u8(0x76), u8(0x65), u8(0x64),
  u8(0x2D), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E),
  u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x30), u8(0x2C), u8(0x20), u8(0x73), u8(0x6F), u8(0x20), u8(0x74),
  u8(0x68), u8(0x65), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x20), u8(0x77), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64),
  u8(0x20), u8(0x73), u8(0x74), u8(0x61), u8(0x72), u8(0x74), u8(0x20), u8(0x69), u8(0x6E), u8(0x73), u8(0x69), u8(0x64),
  u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x62), u8(0x6F), u8(0x6F), u8(0x74), u8(0x20), u8(0x73),
  u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x0A),
];

/// `'the FAT count is neither 1 nor 2\n'` -- 33 bytes.
@rodata
final List<u8> fatStrE06 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E),
  u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x65), u8(0x69), u8(0x74), u8(0x68), u8(0x65), u8(0x72),
  u8(0x20), u8(0x31), u8(0x20), u8(0x6E), u8(0x6F), u8(0x72), u8(0x20), u8(0x32), u8(0x0A),
];

/// `'BPB_FATSz16 is 0, which is the FAT32 boot sector\'s shape\n'` -- 57 bytes.
@rodata
final List<u8> fatStrE07 = const [
  u8(0x42), u8(0x50), u8(0x42), u8(0x5F), u8(0x46), u8(0x41), u8(0x54), u8(0x53), u8(0x7A), u8(0x31), u8(0x36), u8(0x20),
  u8(0x69), u8(0x73), u8(0x20), u8(0x30), u8(0x2C), u8(0x20), u8(0x77), u8(0x68), u8(0x69), u8(0x63), u8(0x68), u8(0x20),
  u8(0x69), u8(0x73), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x33), u8(0x32),
  u8(0x20), u8(0x62), u8(0x6F), u8(0x6F), u8(0x74), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72),
  u8(0x27), u8(0x73), u8(0x20), u8(0x73), u8(0x68), u8(0x61), u8(0x70), u8(0x65), u8(0x0A),
];

/// `'the root-entry count is 0 or is not a multiple of 16\n'` -- 53 bytes.
@rodata
final List<u8> fatStrE08 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x74), u8(0x2D), u8(0x65), u8(0x6E), u8(0x74),
  u8(0x72), u8(0x79), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20),
  u8(0x30), u8(0x20), u8(0x6F), u8(0x72), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20),
  u8(0x61), u8(0x20), u8(0x6D), u8(0x75), u8(0x6C), u8(0x74), u8(0x69), u8(0x70), u8(0x6C), u8(0x65), u8(0x20), u8(0x6F),
  u8(0x66), u8(0x20), u8(0x31), u8(0x36), u8(0x0A),
];

/// `'both BPB_TotSec16 and BPB_TotSec32 are 0\n'` -- 41 bytes.
@rodata
final List<u8> fatStrE09 = const [
  u8(0x62), u8(0x6F), u8(0x74), u8(0x68), u8(0x20), u8(0x42), u8(0x50), u8(0x42), u8(0x5F), u8(0x54), u8(0x6F), u8(0x74),
  u8(0x53), u8(0x65), u8(0x63), u8(0x31), u8(0x36), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x42), u8(0x50),
  u8(0x42), u8(0x5F), u8(0x54), u8(0x6F), u8(0x74), u8(0x53), u8(0x65), u8(0x63), u8(0x33), u8(0x32), u8(0x20), u8(0x61),
  u8(0x72), u8(0x65), u8(0x20), u8(0x30), u8(0x0A),
];

/// `'the data region starts at or past the end of the volume\n'` -- 56 bytes.
@rodata
final List<u8> fatStrE10 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x64), u8(0x61), u8(0x74), u8(0x61), u8(0x20), u8(0x72), u8(0x65), u8(0x67),
  u8(0x69), u8(0x6F), u8(0x6E), u8(0x20), u8(0x73), u8(0x74), u8(0x61), u8(0x72), u8(0x74), u8(0x73), u8(0x20), u8(0x61),
  u8(0x74), u8(0x20), u8(0x6F), u8(0x72), u8(0x20), u8(0x70), u8(0x61), u8(0x73), u8(0x74), u8(0x20), u8(0x74), u8(0x68),
  u8(0x65), u8(0x20), u8(0x65), u8(0x6E), u8(0x64), u8(0x20), u8(0x6F), u8(0x66), u8(0x20), u8(0x74), u8(0x68), u8(0x65),
  u8(0x20), u8(0x76), u8(0x6F), u8(0x6C), u8(0x75), u8(0x6D), u8(0x65), u8(0x0A),
];

/// `'the cluster count is under 4085, so this volume is FAT12\n'` -- 57 bytes.
@rodata
final List<u8> fatStrE11 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x20),
  u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x75), u8(0x6E), u8(0x64),
  u8(0x65), u8(0x72), u8(0x20), u8(0x34), u8(0x30), u8(0x38), u8(0x35), u8(0x2C), u8(0x20), u8(0x73), u8(0x6F), u8(0x20),
  u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x76), u8(0x6F), u8(0x6C), u8(0x75), u8(0x6D), u8(0x65), u8(0x20),
  u8(0x69), u8(0x73), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x31), u8(0x32), u8(0x0A),
];

/// `'the cluster count is 65525 or more, so this volume is FAT32\n'` -- 60 bytes.
@rodata
final List<u8> fatStrE12 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x20),
  u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x36), u8(0x35), u8(0x35),
  u8(0x32), u8(0x35), u8(0x20), u8(0x6F), u8(0x72), u8(0x20), u8(0x6D), u8(0x6F), u8(0x72), u8(0x65), u8(0x2C), u8(0x20),
  u8(0x73), u8(0x6F), u8(0x20), u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x76), u8(0x6F), u8(0x6C), u8(0x75),
  u8(0x6D), u8(0x65), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x33), u8(0x32), u8(0x0A),
];

/// `'the FAT is too small to hold one entry per cluster\n'` -- 51 bytes.
@rodata
final List<u8> fatStrE13 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x74),
  u8(0x6F), u8(0x6F), u8(0x20), u8(0x73), u8(0x6D), u8(0x61), u8(0x6C), u8(0x6C), u8(0x20), u8(0x74), u8(0x6F), u8(0x20),
  u8(0x68), u8(0x6F), u8(0x6C), u8(0x64), u8(0x20), u8(0x6F), u8(0x6E), u8(0x65), u8(0x20), u8(0x65), u8(0x6E), u8(0x74),
  u8(0x72), u8(0x79), u8(0x20), u8(0x70), u8(0x65), u8(0x72), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74),
  u8(0x65), u8(0x72), u8(0x0A),
];

/// `'FAT[0] does not carry the media byte, or FAT[1] is not an end mark\n'` -- 67 bytes.
@rodata
final List<u8> fatStrE14 = const [
  u8(0x46), u8(0x41), u8(0x54), u8(0x5B), u8(0x30), u8(0x5D), u8(0x20), u8(0x64), u8(0x6F), u8(0x65), u8(0x73), u8(0x20),
  u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x63), u8(0x61), u8(0x72), u8(0x72), u8(0x79), u8(0x20), u8(0x74), u8(0x68),
  u8(0x65), u8(0x20), u8(0x6D), u8(0x65), u8(0x64), u8(0x69), u8(0x61), u8(0x20), u8(0x62), u8(0x79), u8(0x74), u8(0x65),
  u8(0x2C), u8(0x20), u8(0x6F), u8(0x72), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x5B), u8(0x31), u8(0x5D), u8(0x20),
  u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x65), u8(0x6E),
  u8(0x64), u8(0x20), u8(0x6D), u8(0x61), u8(0x72), u8(0x6B), u8(0x0A),
];

/// `'a root-directory sector could not be read\n'` -- 42 bytes.
@rodata
final List<u8> fatStrE15 = const [
  u8(0x61), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x74), u8(0x2D), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63),
  u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20),
  u8(0x63), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x62), u8(0x65),
  u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x0A),
];

/// `'no such name in the root directory\n'` -- 35 bytes.
@rodata
final List<u8> fatStrE16 = const [
  u8(0x6E), u8(0x6F), u8(0x20), u8(0x73), u8(0x75), u8(0x63), u8(0x68), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65),
  u8(0x20), u8(0x69), u8(0x6E), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x74),
  u8(0x20), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x0A),
];

/// `'that name is a subdirectory, and subdirectories are not supported\n'` -- 66 bytes.
@rodata
final List<u8> fatStrE17 = const [
  u8(0x74), u8(0x68), u8(0x61), u8(0x74), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x20), u8(0x69), u8(0x73),
  u8(0x20), u8(0x61), u8(0x20), u8(0x73), u8(0x75), u8(0x62), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74),
  u8(0x6F), u8(0x72), u8(0x79), u8(0x2C), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x73), u8(0x75), u8(0x62),
  u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x69), u8(0x65), u8(0x73), u8(0x20),
  u8(0x61), u8(0x72), u8(0x65), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x73), u8(0x75), u8(0x70), u8(0x70),
  u8(0x6F), u8(0x72), u8(0x74), u8(0x65), u8(0x64), u8(0x0A),
];

/// `'the entry\'s first cluster is 0: an empty file has no chain to walk\n'` -- 67 bytes.
@rodata
final List<u8> fatStrE18 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x65), u8(0x6E), u8(0x74), u8(0x72), u8(0x79), u8(0x27), u8(0x73), u8(0x20),
  u8(0x66), u8(0x69), u8(0x72), u8(0x73), u8(0x74), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65),
  u8(0x72), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x30), u8(0x3A), u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x65),
  u8(0x6D), u8(0x70), u8(0x74), u8(0x79), u8(0x20), u8(0x66), u8(0x69), u8(0x6C), u8(0x65), u8(0x20), u8(0x68), u8(0x61),
  u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x74),
  u8(0x6F), u8(0x20), u8(0x77), u8(0x61), u8(0x6C), u8(0x6B), u8(0x0A),
];

/// `'the file needs more than this driver\'s 256-cluster bound\n'` -- 57 bytes.
@rodata
final List<u8> fatStrE19 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x66), u8(0x69), u8(0x6C), u8(0x65), u8(0x20), u8(0x6E), u8(0x65), u8(0x65),
  u8(0x64), u8(0x73), u8(0x20), u8(0x6D), u8(0x6F), u8(0x72), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x61), u8(0x6E),
  u8(0x20), u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x64), u8(0x72), u8(0x69), u8(0x76), u8(0x65), u8(0x72),
  u8(0x27), u8(0x73), u8(0x20), u8(0x32), u8(0x35), u8(0x36), u8(0x2D), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74),
  u8(0x65), u8(0x72), u8(0x20), u8(0x62), u8(0x6F), u8(0x75), u8(0x6E), u8(0x64), u8(0x0A),
];

/// `'the chain leaves a cluster number outside the data region\n'` -- 58 bytes.
@rodata
final List<u8> fatStrE20 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x6C), u8(0x65),
  u8(0x61), u8(0x76), u8(0x65), u8(0x73), u8(0x20), u8(0x61), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74),
  u8(0x65), u8(0x72), u8(0x20), u8(0x6E), u8(0x75), u8(0x6D), u8(0x62), u8(0x65), u8(0x72), u8(0x20), u8(0x6F), u8(0x75),
  u8(0x74), u8(0x73), u8(0x69), u8(0x64), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x64), u8(0x61),
  u8(0x74), u8(0x61), u8(0x20), u8(0x72), u8(0x65), u8(0x67), u8(0x69), u8(0x6F), u8(0x6E), u8(0x0A),
];

/// `'the chain runs into a FREE cluster: the volume is inconsistent\n'` -- 63 bytes.
@rodata
final List<u8> fatStrE21 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x72), u8(0x75),
  u8(0x6E), u8(0x73), u8(0x20), u8(0x69), u8(0x6E), u8(0x74), u8(0x6F), u8(0x20), u8(0x61), u8(0x20), u8(0x46), u8(0x52),
  u8(0x45), u8(0x45), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x3A), u8(0x20),
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x76), u8(0x6F), u8(0x6C), u8(0x75), u8(0x6D), u8(0x65), u8(0x20), u8(0x69),
  u8(0x73), u8(0x20), u8(0x69), u8(0x6E), u8(0x63), u8(0x6F), u8(0x6E), u8(0x73), u8(0x69), u8(0x73), u8(0x74), u8(0x65),
  u8(0x6E), u8(0x74), u8(0x0A),
];

/// `'the chain runs into a cluster marked bad, FFF7\n'` -- 47 bytes.
@rodata
final List<u8> fatStrE22 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x72), u8(0x75),
  u8(0x6E), u8(0x73), u8(0x20), u8(0x69), u8(0x6E), u8(0x74), u8(0x6F), u8(0x20), u8(0x61), u8(0x20), u8(0x63), u8(0x6C),
  u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x20), u8(0x6D), u8(0x61), u8(0x72), u8(0x6B), u8(0x65), u8(0x64),
  u8(0x20), u8(0x62), u8(0x61), u8(0x64), u8(0x2C), u8(0x20), u8(0x46), u8(0x46), u8(0x46), u8(0x37), u8(0x0A),
];

/// `'the chain visits a cluster twice: it is a cycle, not a chain\n'` -- 61 bytes.
@rodata
final List<u8> fatStrE23 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x76), u8(0x69),
  u8(0x73), u8(0x69), u8(0x74), u8(0x73), u8(0x20), u8(0x61), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74),
  u8(0x65), u8(0x72), u8(0x20), u8(0x74), u8(0x77), u8(0x69), u8(0x63), u8(0x65), u8(0x3A), u8(0x20), u8(0x69), u8(0x74),
  u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x61), u8(0x20), u8(0x63), u8(0x79), u8(0x63), u8(0x6C), u8(0x65), u8(0x2C),
  u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x61), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E),
  u8(0x0A),
];

/// `'the chain has more clusters than the directory entry\'s size\n'` -- 60 bytes.
@rodata
final List<u8> fatStrE24 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x68), u8(0x61),
  u8(0x73), u8(0x20), u8(0x6D), u8(0x6F), u8(0x72), u8(0x65), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74),
  u8(0x65), u8(0x72), u8(0x73), u8(0x20), u8(0x74), u8(0x68), u8(0x61), u8(0x6E), u8(0x20), u8(0x74), u8(0x68), u8(0x65),
  u8(0x20), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x65),
  u8(0x6E), u8(0x74), u8(0x72), u8(0x79), u8(0x27), u8(0x73), u8(0x20), u8(0x73), u8(0x69), u8(0x7A), u8(0x65), u8(0x0A),
];

/// `'the chain ends before the directory entry\'s size does\n'` -- 54 bytes.
@rodata
final List<u8> fatStrE25 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x65), u8(0x6E),
  u8(0x64), u8(0x73), u8(0x20), u8(0x62), u8(0x65), u8(0x66), u8(0x6F), u8(0x72), u8(0x65), u8(0x20), u8(0x74), u8(0x68),
  u8(0x65), u8(0x20), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x20),
  u8(0x65), u8(0x6E), u8(0x74), u8(0x72), u8(0x79), u8(0x27), u8(0x73), u8(0x20), u8(0x73), u8(0x69), u8(0x7A), u8(0x65),
  u8(0x20), u8(0x64), u8(0x6F), u8(0x65), u8(0x73), u8(0x0A),
];

/// `'a FAT sector could not be read\n'` -- 31 bytes.
@rodata
final List<u8> fatStrE26 = const [
  u8(0x61), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72),
  u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x62),
  u8(0x65), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x0A),
];

/// `'a data sector could not be read\n'` -- 32 bytes.
@rodata
final List<u8> fatStrE27 = const [
  u8(0x61), u8(0x20), u8(0x64), u8(0x61), u8(0x74), u8(0x61), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F),
  u8(0x72), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20),
  u8(0x62), u8(0x65), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x0A),
];

/// `'that is not an 8.3 name: it is empty, over 8.3, or has a bad byte\n'` -- 66 bytes.
@rodata
final List<u8> fatStrE28 = const [
  u8(0x74), u8(0x68), u8(0x61), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20),
  u8(0x61), u8(0x6E), u8(0x20), u8(0x38), u8(0x2E), u8(0x33), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x3A),
  u8(0x20), u8(0x69), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x65), u8(0x6D), u8(0x70), u8(0x74), u8(0x79),
  u8(0x2C), u8(0x20), u8(0x6F), u8(0x76), u8(0x65), u8(0x72), u8(0x20), u8(0x38), u8(0x2E), u8(0x33), u8(0x2C), u8(0x20),
  u8(0x6F), u8(0x72), u8(0x20), u8(0x68), u8(0x61), u8(0x73), u8(0x20), u8(0x61), u8(0x20), u8(0x62), u8(0x61), u8(0x64),
  u8(0x20), u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x0A),
];

/// `'the volume has no free cluster left\n'` -- 36 bytes.
@rodata
final List<u8> fatStrE29 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x76), u8(0x6F), u8(0x6C), u8(0x75), u8(0x6D), u8(0x65), u8(0x20), u8(0x68),
  u8(0x61), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20), u8(0x63),
  u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x20), u8(0x6C), u8(0x65), u8(0x66), u8(0x74), u8(0x0A),
];

/// `'the root directory has no free entry left\n'` -- 42 bytes.
@rodata
final List<u8> fatStrE30 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x74), u8(0x20), u8(0x64), u8(0x69), u8(0x72),
  u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x68), u8(0x61), u8(0x73), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20), u8(0x65), u8(0x6E), u8(0x74), u8(0x72), u8(0x79),
  u8(0x20), u8(0x6C), u8(0x65), u8(0x66), u8(0x74), u8(0x0A),
];

/// `'a sector could not be written to the drive\n'` -- 43 bytes.
@rodata
final List<u8> fatStrE31 = const [
  u8(0x61), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x63), u8(0x6F), u8(0x75),
  u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x62), u8(0x65), u8(0x20), u8(0x77), u8(0x72),
  u8(0x69), u8(0x74), u8(0x74), u8(0x65), u8(0x6E), u8(0x20), u8(0x74), u8(0x6F), u8(0x20), u8(0x74), u8(0x68), u8(0x65),
  u8(0x20), u8(0x64), u8(0x72), u8(0x69), u8(0x76), u8(0x65), u8(0x0A),
];

/// `'the file is marked read-only and may not be emptied\n'` -- 52 bytes.
@rodata
final List<u8> fatStrE32 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x66), u8(0x69), u8(0x6C), u8(0x65), u8(0x20), u8(0x69), u8(0x73), u8(0x20),
  u8(0x6D), u8(0x61), u8(0x72), u8(0x6B), u8(0x65), u8(0x64), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x2D),
  u8(0x6F), u8(0x6E), u8(0x6C), u8(0x79), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x6D), u8(0x61), u8(0x79),
  u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x62), u8(0x65), u8(0x20), u8(0x65), u8(0x6D), u8(0x70), u8(0x74),
  u8(0x69), u8(0x65), u8(0x64), u8(0x0A),
];

// ===========================  THE STORAGE SEAM  ============================
//
// ADR-0011 section 0, for the fifth time -- AND THE MIGRATION IT DESCRIBED HAS
// HAPPENED (M17, ADR-0021). `fatStore` is a DCDart `@bss` mutable static
// declared right here, in the file that owns it, and not 1824 bytes of
// hand-donated `.bss` in core/boot/kdata.S. The FOUR functions below are still
// the only things in this kernel that know where the bytes are.
//
// WHAT THE MIGRATION ACTUALLY COST IN THIS FILE, exactly:
//   - `@extern u64 fat_store_addr();`      became the `@bss` declaration below
//   - four `return fat_store_addr()`       became four `return
//                                          Bss.addressOf(fatStore)`
// Nothing else moved. Not one line of the driver, not one shell command.
//
// The rule is unchanged and still enforced: do NOT name `fatStore` anywhere
// else. If a new piece of state is needed, give it one of the eight spare
// metadata words -- that is what they are for.
//
// `tests/conformance/m14-fat/run.sh` COUNTS exactly four `return
// Bss.addressOf(fatStore)` in this file and zero anywhere else in core/kernel/.

/// The 1824 bytes this subsystem owns, as a DCDart mutable static.
@bss
final Bss fatStore = const Bss(bytes: fatStoreBytes);

/// The 32 metadata words.
@bare
u64 fatMetaBase() {
  return Bss.addressOf(fatStore);
}

/// The 256-entry cluster-chain array of the open file, four bytes per entry.
@bare
u64 fatChainBase() {
  return Bss.addressOf(fatStore) + u64(fatChainOffset);
}

/// The one-sector buffer every FAT and directory read lands in.
@bare
u64 fatSectorBase() {
  return Bss.addressOf(fatStore) + u64(fatSectorOffset);
}

/// The 11 raw bytes of the 8.3 name currently being looked up.
@bare
u64 fatNameBase() {
  return Bss.addressOf(fatStore) + u64(fatNameOffset);
}

// ========================  END OF THE STORAGE SEAM  ========================

/// Reads metadata word [i].
@bare
u64 fatMeta(u64 i) {
  return Pointer<u64>.fromAddress(fatMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void fatSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(fatMetaBase() + (i << u64(3))).value = v;
}

/// Reads chain entry [i]. Four bytes, so that a 16-bit cluster number and the
/// 32-bit form a future FAT32 would need occupy the same slot.
@bare
u64 fatChain(u64 i) {
  return Pointer<u32>.fromAddress(fatChainBase() + (i << u64(2))).value.toU64();
}

/// Writes chain entry [i].
@bare
void fatSetChain(u64 i, u64 v) {
  Pointer<u32>.fromAddress(fatChainBase() + (i << u64(2))).value = v.toU32();
}

/// Gives every word of the donated block a known value.
///
/// Called from `kmain()`, for the reason [elfInit] and [userInit] are: `.bss`
/// is not zeroed by anything in this kernel, and [fatOpenActive] is read by
/// `elfReadSectors` on every sector of every `run` -- including `run <lba>`,
/// which has nothing to do with this file. A garbage word there would send the
/// ELF loader's sector reads through a chain array full of `.bss` litter.
///
/// Prints NOTHING, and must keep printing nothing:
/// `tests/conformance/m1-interrupts/run.sh` asserts the entire 544-byte serial
/// capture and its last byte is the newline after `M1 END`.
@bare
void fatInit() {
  u64 i = u64(0);
  while (i < u64(fatMetaWords)) {
    fatSetMeta(i, u64(0));
    i = i + u64(1);
  }
  fatSetMeta(u64(fatMetaCached), u64(fatNoSector));
}

// ---------------------------------------------------------------------------
// Little-endian decode, byte at a time.
//
// `elf.dart` carries the same three functions for the same two reasons, and
// they are written out again here rather than shared because the argument is
// about THIS structure: DC-IR's `Load` carries no alignment attribute and a
// BPB field sits wherever the formatter put it (`BPB_TotSec32` is at byte 32 of
// a sector this kernel did not lay out), and FAT is a little-endian format
// whose byte order is a property of the FORMAT rather than of the host. A wide
// load would be trusting the CPU's byte order to match the disk's. The obvious
// cleanup -- one `bytes.dart` with one copy -- is worth doing at the third
// caller, not the second.
// ---------------------------------------------------------------------------

/// One byte of the buffer at [a].
@bare
u64 fatU8(u64 a) {
  return Pointer<u8>.fromAddress(a).value.toU64();
}

/// Two bytes, low first.
@bare
u64 fatU16(u64 a) {
  return fatU8(a) | (fatU8(a + u64(1)) << u64(8));
}

/// Four bytes, low first.
@bare
u64 fatU32(u64 a) {
  return fatU16(a) | (fatU16(a + u64(2)) << u64(16));
}

// ---------------------------------------------------------------------------
// Reading sectors. Everything this driver reads goes through one of these two,
// and both count what they did.
// ---------------------------------------------------------------------------

/// Reads sector [lba] into the shared sector buffer, unless it is already
/// there. Returns 0 on success, 1 on a drive failure.
///
/// **The cache is invalidated BEFORE the read, not after.** A failed
/// `ataReadInto` leaves whatever it managed to transfer in the buffer, and a
/// cache that still claimed to hold [lba] would serve those bytes to the next
/// caller as if they were a sector. So the window in which the buffer is
/// undefined is a window in which the cache says it holds nothing.
///
/// One sector is the whole cache. It exists because a cluster chain confined to
/// one FAT sector -- which is what every chain on a small volume is -- would
/// otherwise re-read that sector once per link. GAP-0090 item 8 said "every
/// sector is read from the drive every time"; that is now false for the FAT and
/// the root directory, still true for file data, and the two counters
/// [fatMetaReads] and [fatMetaHits] make the difference a number.
@bare
u64 fatReadCached(u64 lba) {
  if (fatMeta(u64(fatMetaCached)) == lba) {
    fatSetMeta(u64(fatMetaHits), fatMeta(u64(fatMetaHits)) + u64(1));
    return u64(0);
  }
  fatSetMeta(u64(fatMetaCached), u64(fatNoSector));
  if (ataReadInto(lba, fatSectorBase()) > u64(0)) {
    return u64(1);
  }
  fatSetMeta(u64(fatMetaCached), lba);
  fatSetMeta(u64(fatMetaReads), fatMeta(u64(fatMetaReads)) + u64(1));
  return u64(0);
}

/// Reads sector [lba] straight into [dst], bypassing the cache.
///
/// For the ELF loader, whose destination is a frame it owns. Deliberately does
/// NOT populate the cache: the bytes are not in the shared buffer, and a cache
/// that recorded [lba] as present would then hand out the sector buffer's stale
/// contents under that name.
@bare
u64 fatReadSector(u64 lba, u64 dst) {
  if (ataReadInto(lba, dst) > u64(0)) {
    return u64(1);
  }
  fatSetMeta(u64(fatMetaReads), fatMeta(u64(fatMetaReads)) + u64(1));
  return u64(0);
}

// ---------------------------------------------------------------------------
// Mounting.
// ---------------------------------------------------------------------------

/// 1 if [n] is a power of two in 1..128, which is what `BPB_SecPerClus` is
/// allowed to be. Written out rather than folded into [fatMount] because the
/// `n & (n - 1)` trick is exactly the kind of line that gets "simplified" into
/// something that accepts 0.
@bare
u64 fatPowerOfTwo(u64 n) {
  if (n < u64(1)) {
    return u64(0);
  }
  if (n > u64(128)) {
    return u64(0);
  }
  if ((n & (n - u64(1))) > u64(0)) {
    return u64(0);
  }
  return u64(1);
}

/// Reads and validates the boot sector, computes the four region offsets and
/// the cluster count, and records all of it. Returns a refusal code.
///
/// **Idempotent and cheap**, which is why every command calls it rather than
/// depending on a `fs` having been run first: it is one cached sector read once
/// the boot sector is in the buffer, and it leaves the same twelve words behind
/// every time. That removes an entire class of ordering bug -- there is no
/// "mounted" state that a command can find stale, because there is no command
/// that runs without establishing it.
///
/// **Nothing is guessed.** Every field that is not what this driver can handle
/// is a distinct refusal code with its own sentence, and the two that decide
/// what kind of volume this is -- FAT12 and FAT32 -- are computed from the
/// cluster count rather than read out of `BS_FilSysType`.
@bare
u64 fatMount() {
  fatSetMeta(u64(fatMetaReady), u64(0));
  fatSetMeta(u64(fatMetaOpen), u64(0));
  if (fatReadCached(u64(0)) > u64(0)) {
    return u64(fatErrDiskBoot);
  }
  final u64 b = fatSectorBase();
  if (fatU16(b + u64(fatBpbSigOff)) != u64(fatBpbSig)) {
    return u64(fatErrSignature);
  }
  final u64 bps = fatU16(b + u64(fatBpbBytesPerSec));
  if (bps != u64(fatSectorBytes)) {
    return u64(fatErrSectorSize);
  }
  final u64 spc = fatU8(b + u64(fatBpbSecPerClus));
  if (fatPowerOfTwo(spc) < u64(1)) {
    return u64(fatErrClusterSize);
  }
  final u64 rsv = fatU16(b + u64(fatBpbRsvdSecCnt));
  if (rsv < u64(1)) {
    return u64(fatErrReserved);
  }
  final u64 nfat = fatU8(b + u64(fatBpbNumFats));
  if (nfat < u64(1)) {
    return u64(fatErrFatCount);
  }
  if (nfat > u64(2)) {
    return u64(fatErrFatCount);
  }
  // BPB_FATSz16 is 0 on FAT32, where the real size is in BPB_FATSz32 at offset
  // 36. This driver does not read offset 36 and does not want to: a zero here
  // is a FAT32 boot sector and gets its own refusal, BEFORE any arithmetic that
  // would divide the volume up wrongly.
  final u64 fatsz = fatU16(b + u64(fatBpbFatSz16));
  if (fatsz < u64(1)) {
    return u64(fatErrFat32Shape);
  }
  final u64 rootEnt = fatU16(b + u64(fatBpbRootEntCnt));
  if (rootEnt < u64(1)) {
    return u64(fatErrRootEntries);
  }
  // 512 / 32 = 16 entries per sector, so a root directory that is a whole
  // number of sectors is a multiple of 16 entries. Anything else would leave a
  // final partial sector this walk would either overrun or silently drop.
  if ((rootEnt & u64(15)) > u64(0)) {
    return u64(fatErrRootEntries);
  }
  u64 tot = fatU16(b + u64(fatBpbTotSec16));
  if (tot < u64(1)) {
    tot = fatU32(b + u64(fatBpbTotSec32));
  }
  if (tot < u64(1)) {
    return u64(fatErrTotalZero);
  }
  final u64 rootSectors = (rootEnt * u64(fatDirEntBytes)) >> u64(fatSectorShift);
  final u64 fatStart = rsv;
  final u64 rootStart = rsv + (nfat * fatsz);
  final u64 dataStart = rootStart + rootSectors;
  if (dataStart >= tot) {
    return u64(fatErrGeometry);
  }
  // THE ONE COMPUTED QUANTITY. Everything about "is this FAT16" is here.
  final u64 clusters = (tot - dataStart) ~/ spc;
  if (clusters < u64(fatFat12Max)) {
    return u64(fatErrFat12);
  }
  if (clusters >= u64(fatFat16Max)) {
    return u64(fatErrFat32);
  }
  // The FAT has to be able to HOLD one 16-bit entry per cluster, plus entries 0
  // and 1 which are not clusters. A volume whose FAT is short would produce
  // chain lookups that read past the FAT and into the root directory, and every
  // one of those would be a plausible cluster number.
  if ((fatsz * u64(fatEntriesPerSector)) < (clusters + u64(2))) {
    return u64(fatErrFatSize);
  }
  // FAT[0] and FAT[1], the two entries that are not clusters. FAT[0]'s low byte
  // must be BPB_Media and its high bits all ones; FAT[1] must be an end mark.
  // This is the one check that reads the FAT during a mount, and it is what
  // catches a boot sector that describes a volume the FAT does not.
  //
  // **`media` is read BEFORE the FAT sector replaces the boot sector in the
  // buffer.** Reading it afterwards compares FAT[0] against a byte of the FAT
  // itself, which is how the first build of this function failed: it reported
  // `fatErrMedia` on a volume `fsck_msdos` calls clean.
  final u64 media = fatU8(b + u64(fatBpbMedia));
  if (fatReadCached(fatStart) > u64(0)) {
    return u64(fatErrDiskFat);
  }
  if (fatU16(fatSectorBase()) != (u64(0xFF00) | media)) {
    return u64(fatErrMedia);
  }
  if (fatU16(fatSectorBase() + u64(2)) < u64(fatEocMin)) {
    return u64(fatErrMedia);
  }

  fatSetMeta(u64(fatMetaBytesPerSec), bps);
  fatSetMeta(u64(fatMetaSecPerClus), spc);
  fatSetMeta(u64(fatMetaReserved), rsv);
  fatSetMeta(u64(fatMetaNumFats), nfat);
  fatSetMeta(u64(fatMetaFatSectors), fatsz);
  fatSetMeta(u64(fatMetaRootEntries), rootEnt);
  fatSetMeta(u64(fatMetaTotalSectors), tot);
  fatSetMeta(u64(fatMetaFatStart), fatStart);
  fatSetMeta(u64(fatMetaRootStart), rootStart);
  fatSetMeta(u64(fatMetaRootSectors), rootSectors);
  fatSetMeta(u64(fatMetaDataStart), dataStart);
  fatSetMeta(u64(fatMetaClusters), clusters);
  fatSetMeta(u64(fatMetaReady), u64(1));
  return u64(fatErrOk);
}

// ---------------------------------------------------------------------------
// The FAT, and the chain.
// ---------------------------------------------------------------------------

/// The FAT entry for cluster [c], or `0x10000` -- a value no 16-bit entry can
/// take -- if the sector could not be read.
///
/// `c >> 8` and `c & 255` are the sector and the entry within it, and they are
/// shifts rather than divisions BECAUSE [fatMount] has already refused any
/// volume whose sectors are not 512 bytes: 512 / 2 = 256 entries per sector
/// exactly. On a volume with a different sector size these two lines would be
/// wrong, which is why that refusal is not a convenience.
@bare
u64 fatEntry(u64 c) {
  final u64 lba = fatMeta(u64(fatMetaFatStart)) + (c >> u64(8));
  if (fatReadCached(lba) > u64(0)) {
    return u64(0x10000);
  }
  return fatU16(fatSectorBase() + ((c & u64(255)) << u64(1)));
}

/// [fatErrOk] if [c] is a legal data cluster on this volume, or the refusal
/// that says why not.
///
/// The upper bound is `clusterCount + 2` and not `clusterCount`, because
/// clusters are numbered from 2. Getting that wrong by two is the kind of error
/// that makes the last two clusters of every volume unreadable and shows up as
/// "large files are corrupt".
@bare
u64 fatValidCluster(u64 c) {
  if (c == u64(fatFreeCluster)) {
    return u64(fatErrChainFree);
  }
  if (c == u64(fatBadCluster)) {
    return u64(fatErrChainBad);
  }
  if (c < u64(fatFirstCluster)) {
    return u64(fatErrChainRange);
  }
  if (c >= (fatMeta(u64(fatMetaClusters)) + u64(fatFirstCluster))) {
    return u64(fatErrChainRange);
  }
  return u64(fatErrOk);
}

/// 1 if cluster [c] already appears in chain entries `0 .. n)`.
///
/// A linear scan, because 256 is the bound and `n * n / 2` at 256 is 32,768
/// comparisons of registers -- against a chain walk that is one disk read per
/// FAT sector. A cycle in a FAT is what a corrupt volume looks like, and a
/// driver that only stopped at an end mark would follow one until the machine
/// was switched off.
@bare
u64 fatChainSeen(u64 c, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    if (fatChain(i) == c) {
      return u64(1);
    }
    i = i + u64(1);
  }
  return u64(0);
}

/// Walks the chain from [first] into the chain array and checks it against
/// [bytes], the size the directory entry claims. Returns a refusal code.
///
/// **The length is derived from the size and then REQUIRED, both ways.** The
/// walk runs for exactly as many clusters as `bytes` needs; if an end mark
/// arrives before that it is `fatErrChainShort`, and if the link after the last
/// one is not an end mark it is `fatErrChainLong`. A driver that stopped at the
/// end mark and believed whatever length that produced would read a file whose
/// directory entry and FAT disagree without noticing that they do.
@bare
u64 fatBuildChain(u64 first, u64 bytes) {
  final u64 cbytes = fatMeta(u64(fatMetaSecPerClus)) << u64(fatSectorShift);
  final u64 want = (bytes + cbytes - u64(1)) ~/ cbytes;
  if (want < u64(1)) {
    // A zero-length file has no cluster at all and is refused by the caller.
    return u64(fatErrEmpty);
  }
  if (want > u64(fatChainMax)) {
    return u64(fatErrTooBig);
  }
  u64 c = first;
  u64 n = u64(0);
  while (n < want) {
    final u64 v = fatValidCluster(c);
    if (v > u64(fatErrOk)) {
      return v;
    }
    if (fatChainSeen(c, n) > u64(0)) {
      return u64(fatErrChainCycle);
    }
    fatSetChain(n, c);
    n = n + u64(1);
    final u64 nxt = fatEntry(c);
    if (nxt > u64(0xFFFF)) {
      return u64(fatErrDiskFat);
    }
    if (n < want) {
      if (nxt >= u64(fatEocMin)) {
        return u64(fatErrChainShort);
      }
      c = nxt;
    } else {
      if (nxt < u64(fatEocMin)) {
        return u64(fatErrChainLong);
      }
    }
  }
  fatSetMeta(u64(fatMetaFileClusters), n);
  return u64(fatErrOk);
}

/// The absolute LBA of sector [i] of the open file, or 0 if there is no such
/// sector. **This is the function that makes the chain load-bearing.**
///
/// Sector 0 of a volume is its boot sector, so 0 is a safe "no" here: it is
/// never the answer for a data sector.
///
/// `(c - 2) * spc` is a multiply and not a shift on purpose. `spc` is a power
/// of two so a shift would work, but the shift amount would then have to be
/// derived from `spc` at every call site, and `m14-fat`'s volume has
/// `spc = 2` precisely so that a driver which had dropped the scale entirely
/// would read the wrong half of every cluster.
@bare
u64 fatFileSector(u64 i) {
  if (fatMeta(u64(fatMetaOpen)) < u64(1)) {
    return u64(0);
  }
  final u64 spc = fatMeta(u64(fatMetaSecPerClus));
  final u64 ci = i ~/ spc;
  if (ci >= fatMeta(u64(fatMetaFileClusters))) {
    return u64(0);
  }
  final u64 c = fatChain(ci);
  return fatMeta(u64(fatMetaDataStart)) + ((c - u64(fatFirstCluster)) * spc) +
      (i - (ci * spc));
}

/// 1 while the chain array describes a real open file. Read by `elf.dart`.
@bare
u64 fatOpenActive() {
  return fatMeta(u64(fatMetaOpen));
}

/// Forgets the open file. Called by the `run <lba>` path, so that the loader's
/// numeric form cannot pick up a chain a previous `cat` left behind.
@bare
void fatClose() {
  fatSetMeta(u64(fatMetaOpen), u64(0));
}

// ---------------------------------------------------------------------------
// The root directory.
// ---------------------------------------------------------------------------

/// The address of root-directory entry [i], with its sector loaded into the
/// shared buffer. 0 if the sector could not be read.
///
/// `i >> 4` and `i & 15` are 16 entries per 512-byte sector, which is exact
/// because an entry is 32 bytes and [fatMount] has refused any other sector
/// size.
///
/// **The returned address is only valid until the next read.** Every caller
/// below copies what it needs out of the entry before doing anything that
/// touches the FAT.
@bare
u64 fatDirEntry(u64 i) {
  final u64 lba = fatMeta(u64(fatMetaRootStart)) + (i >> u64(4));
  if (fatReadCached(lba) > u64(0)) {
    return u64(0);
  }
  return fatSectorBase() + ((i & u64(15)) << u64(5));
}

/// 1 if the 11 name bytes of the entry at [e] equal the ones in the name
/// buffer.
@bare
u64 fatNameEq(u64 e) {
  final u64 want = fatNameBase();
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    if (Pointer<u8>.fromAddress(e + i).value !=
        Pointer<u8>.fromAddress(want + i).value) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// `'a'..'z'` to upper case, everything else unchanged.
///
/// Not cosmetic: the shell has no shift handling on the letter keys (GAP-0055),
/// so every name a user can type arrives in lower case, and every name a FAT
/// directory stores is upper case. Without this, no file on any volume would
/// ever be found from this shell.
@bare
u8 fatUpper(u8 c) {
  if (c < u8(0x61)) {
    return c;
  }
  if (c > u8(0x7A)) {
    return c;
  }
  return c - u8(0x20);
}

/// Turns the line-buffer bytes from [from] to the end of the line into the 11
/// raw bytes of an 8.3 name, in the name buffer. Returns a refusal code.
///
/// **Eight-point-three, and a refusal for anything else.** A name that is too
/// long, has two dots, has an empty stem, or carries a byte outside the
/// printable range is [fatErrBadName] rather than a truncation. Truncating
/// would turn `PROGRAMME.ELF` into a lookup for `PROGRAMM.ELF`, which might
/// succeed -- and would then run a different file from the one that was asked
/// for.
/// The same parser, over an arbitrary [len]-byte range at [addr].
///
/// **M15 made this the only copy.** The typed line and a ring-3 program's
/// `open` argument are two sources for one grammar, and two copies of an 8.3
/// parser is two chances for `run PROGA.ELF` and `open("PROGA.ELF")` to
/// disagree about what a name is. [fatParseName] is now a two-line wrapper.
///
/// **[addr] is a KERNEL address by the time this is called.** Nothing here
/// validates it, and nothing here may: the ring-3 caller's pointer is checked
/// by `fileOwnsRead` in `core/kernel/file.dart` BEFORE the bytes are copied
/// into the kernel, and this function never sees a user pointer at all. ADR-0019
/// §5.
@bare
u64 fatParseAt(u64 addr, u64 len) {
  final u64 nb = fatNameBase();
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    Pointer<u8>.fromAddress(nb + i).value = u8(0x20);
    i = i + u64(1);
  }
  if (len < u64(1)) {
    return u64(fatErrBadName);
  }
  u64 p = u64(0);
  u64 ext = u64(0);
  u64 k = u64(0);
  while (p < len) {
    final u8 c = Pointer<u8>.fromAddress(addr + p).value;
    if (c < u8(0x21)) {
      return u64(fatErrBadName);
    }
    if (c > u8(0x7E)) {
      return u64(fatErrBadName);
    }
    if (c == u8(0x2E)) {
      if (ext > u64(0)) {
        return u64(fatErrBadName);
      }
      if (k < u64(1)) {
        return u64(fatErrBadName);
      }
      ext = u64(1);
      k = u64(0);
    } else {
      final u8 u = fatUpper(c);
      if (ext < u64(1)) {
        if (k >= u64(8)) {
          return u64(fatErrBadName);
        }
        Pointer<u8>.fromAddress(nb + k).value = u;
      } else {
        if (k >= u64(3)) {
          return u64(fatErrBadName);
        }
        Pointer<u8>.fromAddress(nb + u64(8) + k).value = u;
      }
      k = k + u64(1);
    }
    p = p + u64(1);
  }
  return u64(fatErrOk);
}

/// Turns the line-buffer bytes from [from] to the end of the line into the 11
/// raw bytes of an 8.3 name. Returns a refusal code.
///
/// Two lines, since M15: the grammar is [fatParseAt]'s and this only says where
/// the shell's bytes are.
@bare
u64 fatParseName(u64 from) {
  return fatParseNameAt(from, shellLen());
}

/// The same, over `[from, end)`. **M19.** `run WC.ELF ALPHA.TXT` must parse
/// `WC.ELF` and not `WC.ELF ALPHA.TXT`, which before M19 was
/// [fatErrBadName] because a space is below 0x21. `cat` and `open` still pass
/// [shellLen] and still mean "the rest of the line".
@bare
u64 fatParseNameAt(u64 from, u64 end) {
  if (end <= from) {
    return fatParseAt(shellLineBase(), u64(0)); // clears the buffer, refuses
  }
  return fatParseAt(shellLineBase() + from, end - from);
}

/// Finds the name already in the name buffer in the root directory, validates
/// the entry, walks its chain, and leaves the file open. Returns a refusal code.
///
/// **Volume labels and long-filename entries are invisible here**, and deleted
/// entries are too. A `cat` of a name that only a deleted entry carries is
/// [fatErrNotFound], which is the truth: the entry is a tombstone and the
/// clusters it names belong to whatever was allocated after it.
///
/// Split out of [fatOpen] at M15 so that the two ways of SAYING a name — a
/// typed line, and a byte range a ring-3 program handed to `open` — share every
/// byte of the actual lookup. `file.dart` calls [fatParseAt] and then this.
@bare
u64 fatLookup() {
  fatSetMeta(u64(fatMetaOpen), u64(0));
  final u64 m = fatMount();
  if (m > u64(fatErrOk)) {
    return m;
  }
  final u64 n = fatMeta(u64(fatMetaRootEntries));
  u64 i = u64(0);
  while (i < n) {
    final u64 e = fatDirEntry(i);
    if (e < u64(1)) {
      return u64(fatErrDiskDir);
    }
    final u64 c0 = fatU8(e);
    if (c0 == u64(fatDirFree)) {
      // The first free entry ends the directory: FAT guarantees nothing beyond
      // it has ever been used. Stopping here rather than walking all 512 slots
      // is not an optimisation -- the bytes past it are undefined.
      i = n;
    } else {
      u64 hit = u64(0);
      if (c0 != u64(fatDirDeleted)) {
        final u64 attr = fatU8(e + u64(fatDirOffAttr));
        if (attr != u64(fatAttrLongName)) {
          if ((attr & u64(fatAttrVolumeId)) < u64(1)) {
            if (fatNameEq(e) > u64(0)) {
              hit = u64(1);
              // Copied out of the sector buffer BEFORE the chain walk, which
              // reads FAT sectors into that same buffer.
              fatSetMeta(u64(fatMetaFileAttr), attr);
              fatSetMeta(u64(fatMetaFileEntry), i);
              fatSetMeta(u64(fatMetaFileFirst),
                  fatU16(e + u64(fatDirOffCluster)));
              fatSetMeta(u64(fatMetaFileBytes), fatU32(e + u64(fatDirOffSize)));
            }
          }
        }
      }
      if (hit > u64(0)) {
        if ((fatMeta(u64(fatMetaFileAttr)) & u64(fatAttrDirectory)) > u64(0)) {
          return u64(fatErrIsDir);
        }
        if (fatMeta(u64(fatMetaFileFirst)) < u64(fatFirstCluster)) {
          return u64(fatErrEmpty);
        }
        if (fatMeta(u64(fatMetaFileBytes)) < u64(1)) {
          return u64(fatErrEmpty);
        }
        final u64 ch = fatBuildChain(fatMeta(u64(fatMetaFileFirst)),
            fatMeta(u64(fatMetaFileBytes)));
        if (ch > u64(fatErrOk)) {
          return ch;
        }
        fatSetMeta(u64(fatMetaOpen), u64(1));
        return u64(fatErrOk);
      }
      i = i + u64(1);
    }
  }
  return u64(fatErrNotFound);
}

/// [fatErrReadOnly] if the entry the last [fatLookup] found is marked
/// read-only, [fatErrOk] otherwise.
///
/// **Only meaningful straight after a lookup that HIT.** [fatMetaFileAttr] is
/// written by [fatLookup] the moment a name matches and is not cleared on a
/// miss, so a caller must have established that the entry exists before asking
/// this. `fileMakeEmpty` does: every path that can reach the call has already
/// returned for [fatErrNotFound] and for every code that means the lookup
/// itself failed.
///
/// **This is a question about permission, and it is the only one this
/// filesystem can answer.** FAT has no owner, no group and no mode; bit 0 of
/// `DIR_Attr` is the entire access-control vocabulary of the volume format. So
/// this function is short because the format is poor, not because the check is
/// partial — see docs/decisions/0024-the-read-only-attribute.md.
@bare
u64 fatWritable() {
  if ((fatMeta(u64(fatMetaFileAttr)) & u64(fatAttrReadOnly)) > u64(0)) {
    return u64(fatErrReadOnly);
  }
  return u64(fatErrOk);
}

/// Parses [from]'s name out of the typed line and looks it up. Returns a
/// refusal code. The shell's whole entry point into the filesystem.
@bare
u64 fatOpen(u64 from) {
  return fatOpenAt(from, shellLen());
}

/// The same, over `[from, end)`. **M19**, for [fatParseNameAt]'s reason.
@bare
u64 fatOpenAt(u64 from, u64 end) {
  fatSetMeta(u64(fatMetaOpen), u64(0));
  final u64 pn = fatParseNameAt(from, end);
  if (pn > u64(fatErrOk)) {
    return pn;
  }
  return fatLookup();
}

/// The first cluster of the open file. 0 when nothing is open.
@bare
u64 fatFileFirst() {
  if (fatMeta(u64(fatMetaOpen)) < u64(1)) {
    return u64(0);
  }
  return fatMeta(u64(fatMetaFileFirst));
}

/// The size in bytes of the open file. 0 when nothing is open.
@bare
u64 fatFileBytes() {
  if (fatMeta(u64(fatMetaOpen)) < u64(1)) {
    return u64(0);
  }
  return fatMeta(u64(fatMetaFileBytes));
}

/// 1 if the chain array ALREADY describes the file `(first, bytes)` names.
///
/// Separate from [fatSelect] so that the caller can count the walks it caused
/// without [fatSelect] having to report two things at once — `@bare` DCDart
/// returns one value and has no out-parameters. `file.dart`'s
/// [fileMetaRebuilds] is the counter this exists for.
@bare
u64 fatSelected(u64 first, u64 bytes) {
  if (fatMeta(u64(fatMetaOpen)) < u64(1)) {
    return u64(0);
  }
  if (fatMeta(u64(fatMetaFileFirst)) != first) {
    return u64(0);
  }
  if (fatMeta(u64(fatMetaFileBytes)) != bytes) {
    return u64(0);
  }
  return u64(1);
}

/// Makes the chain array describe the file `(first, bytes)` names, walking the
/// FAT again if it does not already. Returns a refusal code.
///
/// **This is what turns "one open file" into "one chain, cached".** M14's chain
/// array holds exactly one chain (GAP-0116 item 5) and M15 did not make it
/// bigger; it made it re-derivable. A descriptor stores the two numbers a chain
/// can be rebuilt from — the first cluster and the size, both straight out of
/// the directory entry — so any descriptor can get its own chain back at the
/// cost of one FAT walk, which on a volume whose chains fit in one FAT sector
/// is one cached sector read.
///
/// **It does NOT re-read the directory**, which is the property that makes this
/// safe rather than merely convenient: the name was resolved once, at `open`,
/// and a later `read` cannot pick up a different file because a directory entry
/// changed. Nothing on this volume can change — there are no writes anywhere in
/// this kernel — but the ordering is the one a writable filesystem would need
/// and it costs nothing to have it now.
@bare
u64 fatSelect(u64 first, u64 bytes) {
  if (fatSelected(first, bytes) > u64(0)) {
    return u64(fatErrOk);
  }
  fatSetMeta(u64(fatMetaOpen), u64(0));
  final u64 m = fatMount();
  if (m > u64(fatErrOk)) {
    return m;
  }
  final u64 ch = fatBuildChain(first, bytes);
  if (ch > u64(fatErrOk)) {
    return ch;
  }
  fatSetMeta(u64(fatMetaFileFirst), first);
  fatSetMeta(u64(fatMetaFileBytes), bytes);
  fatSetMeta(u64(fatMetaOpen), u64(1));
  return u64(fatErrOk);
}

// ===========================================================================
// M16 (docs/decisions/0020-writing-to-a-disk.md): THE WRITE PATH.
//
// Everything above this line reads. Everything below it can change a volume,
// and the ordering rules are therefore the interesting part rather than the
// arithmetic.
//
// THE FIVE RULES THIS LAYER KEEPS, AND WHY EACH ONE MATTERS
// ---------------------------------------------------------------------------
// 1. BOTH FATs, ALWAYS, IN ONE FUNCTION. `BPB_NumFATs` is 2 on every volume
//    this driver will meet, and a driver that updated one copy produces a
//    volume `fsck_msdos` reports as "FATs differ" and macOS's `msdos` driver
//    may mount from EITHER copy — so the file would be there or not depending
//    on which one the reader picked. [fatSetEntry] is the ONLY function in this
//    kernel that changes a FAT entry and it writes every copy before returning.
//
// 2. THE NEW CLUSTER IS MARKED END-OF-CHAIN BEFORE IT IS LINKED. If the power
//    goes off between the two writes, the volume has a cluster marked in use
//    that no file points at — a leak, which `fsck` calls a lost chain and can
//    reclaim. The other order leaves a chain whose last link points at a
//    cluster marked FREE, which the next allocation will hand to a second file:
//    two files sharing a cluster is the corruption that a read test cannot see.
//
// 3. THE DIRECTORY ENTRY IS WRITTEN LAST. Size and first-cluster go to the disk
//    at `close`, after every FAT link and every data sector. Until then the
//    file on the volume is the old one (or, for a new file, an empty one), so
//    an interrupted write loses the new data instead of producing a directory
//    entry that claims bytes the FAT does not have.
//
// 4. NOTHING PARTIAL IS LEFT ON A REFUSAL. Every function here returns a
//    `fatErr*` code and returns it BEFORE the write that would have made the
//    change, not after. `fatErrFull` in particular is reached by [fatFindFree]
//    finding nothing, which happens before any FAT entry has been touched.
//
// 5. THE ONE-SECTOR CACHE IS TOLD. `fatSectorBase()` holds one sector under one
//    LBA; a write through it keeps the two in agreement, and a write of any
//    other buffer to the cached LBA — or a write that FAILED — invalidates it.
//    A cache that served bytes the drive rejected would make a failed write
//    look like a successful one to the very next read.
// ===========================================================================

/// Stores [v] as two little-endian bytes at [a]. The inverse of [fatU16], and
/// byte at a time for its reason: FAT's byte order is the FORMAT's, not the
/// host's, and DC-IR's `Store` carries no alignment attribute.
@bare
void fatPut16(u64 a, u64 v) {
  Pointer<u8>.fromAddress(a).value = (v & u64(0xFF)).toU8();
  Pointer<u8>.fromAddress(a + u64(1)).value = ((v >> u64(8)) & u64(0xFF)).toU8();
}

/// Stores [v] as four little-endian bytes at [a]. The inverse of [fatU32].
@bare
void fatPut32(u64 a, u64 v) {
  fatPut16(a, v & u64(0xFFFF));
  fatPut16(a + u64(2), (v >> u64(16)) & u64(0xFFFF));
}

/// Writes the 512 bytes at [src] to sector [lba], counting it, and keeps the
/// one-sector cache honest. Returns [fatErrOk] or [fatErrDiskWrite].
///
/// **Rule 5 lives here.** Three cases:
///   * the write failed — the drive's copy of [lba] is now unknown, so the
///     cache must not claim to hold it;
///   * the write succeeded and [src] IS the cache buffer — the two agree, and
///     the cache entry stays, which is what makes "read the FAT sector, patch
///     one entry, write it, patch another entry in the same sector" cost one
///     read instead of one per entry;
///   * the write succeeded from some other buffer — if that happened to be the
///     cached LBA the cache is now stale, so it goes.
///
/// **Every write in this kernel goes through this function.** `ataWriteFrom` is
/// called from exactly one place, which is what makes [fatMetaWrites] a
/// complete count rather than a sample.
@bare
u64 fatWriteSector(u64 lba, u64 src) {
  if (ataWriteFrom(lba, src) > u64(ataWriteOk)) {
    fatSetMeta(u64(fatMetaCached), u64(fatNoSector));
    return u64(fatErrDiskWrite);
  }
  fatSetMeta(u64(fatMetaWrites), fatMeta(u64(fatMetaWrites)) + u64(1));
  if (fatMeta(u64(fatMetaCached)) == lba) {
    if (src != fatSectorBase()) {
      fatSetMeta(u64(fatMetaCached), u64(fatNoSector));
    }
  }
  return u64(fatErrOk);
}

/// Sets FAT entry [c] to [v] in EVERY copy of the FAT. Returns a refusal code.
///
/// Rule 1. The sector is read once, patched once, and written `BPB_NumFATs`
/// times at the same offset into each copy — which is correct because every
/// copy of a FAT is byte-identical by definition and `BPB_FATSz16` is the
/// distance between them.
///
/// [c] is NOT range-checked here. Every caller has already established that it
/// is a data cluster: [fatAlloc] got it from [fatFindFree], which only ever
/// returns one, and [fatTruncate] checks the bound on every link before
/// following it. A check here would be a fourth place that knows what a legal
/// cluster is.
@bare
u64 fatSetEntry(u64 c, u64 v) {
  final u64 idx = c >> u64(8);
  final u64 lba = fatMeta(u64(fatMetaFatStart)) + idx;
  if (fatReadCached(lba) > u64(0)) {
    return u64(fatErrDiskFat);
  }
  fatPut16(fatSectorBase() + ((c & u64(255)) << u64(1)), v & u64(0xFFFF));
  final u64 copies = fatMeta(u64(fatMetaNumFats));
  final u64 span = fatMeta(u64(fatMetaFatSectors));
  u64 f = u64(0);
  while (f < copies) {
    final u64 dst = fatMeta(u64(fatMetaFatStart)) + (f * span) + idx;
    if (fatWriteSector(dst, fatSectorBase()) > u64(fatErrOk)) {
      return u64(fatErrDiskWrite);
    }
    f = f + u64(1);
  }
  return u64(fatErrOk);
}

/// The number of the first free cluster at or after the hint, wrapping once.
///
/// Returns a cluster number (>= 2), **0 when the volume is full**, or **1 when
/// a FAT sector could not be read**. Both sentinels are below
/// [fatFirstCluster], so a caller tests `< 2` once and then asks which.
///
/// **One pass over every cluster, modular, rather than two loops**, because the
/// pinned `dcc` cannot compile a `while` inside a `while` (GAP-0068) and
/// "scan to the end, then scan from the start" is two. The index arithmetic is
/// a subtraction rather than a `%` for the same reason [fatFileSector] uses a
/// multiply: the shape that is obviously right is worth more here than the
/// shape that is short.
///
/// **The hint cannot cause a wrong answer**, only a slower one: the loop runs
/// `clusterCount` times regardless of where it starts, so a hint left over from
/// a previous file — or a garbage one — finds exactly the same set of free
/// clusters.
@bare
u64 fatFindFree() {
  final u64 span = fatMeta(u64(fatMetaClusters));
  if (span < u64(1)) {
    return u64(0);
  }
  final u64 bound = span + u64(fatFirstCluster);
  u64 hint = fatMeta(u64(fatMetaNextFree));
  if (hint < u64(fatFirstCluster)) {
    hint = u64(fatFirstCluster);
  }
  if (hint >= bound) {
    hint = u64(fatFirstCluster);
  }
  u64 k = u64(0);
  while (k < span) {
    u64 c = hint + k;
    if (c >= bound) {
      c = c - span;
    }
    final u64 v = fatEntry(c);
    if (v > u64(0xFFFF)) {
      return u64(1);
    }
    if (v == u64(fatFreeCluster)) {
      return c;
    }
    k = k + u64(1);
  }
  return u64(0);
}

/// The refusal [fatAlloc]'s return value [c] means, or [fatErrOk] if it is a
/// real cluster.
///
/// **`@bare` DCDart returns one value**, so [fatAlloc] answers with a cluster
/// number or one of two sentinels below [fatFirstCluster], and this is where
/// those sentinels become the vocabulary the rest of the kernel speaks. Written
/// here rather than at the call site so that the meaning of "0" and "1" lives
/// in the file that produces them.
@bare
u64 fatAllocError(u64 c) {
  if (c >= u64(fatFirstCluster)) {
    return u64(fatErrOk);
  }
  if (c == u64(0)) {
    return u64(fatErrFull);
  }
  return u64(fatErrDiskWrite);
}

/// Allocates one cluster and links it after [last], or after nothing if [last]
/// is 0. Returns the new cluster number, **0 if the volume is full**, or **1 on
/// any drive or FAT failure**.
///
/// Rule 2: the new cluster is marked end-of-chain BEFORE [last] is made to
/// point at it. The two writes are not atomic and cannot be made so on this
/// hardware; what they can be is ordered so that the failure between them is
/// the recoverable one.
@bare
u64 fatAlloc(u64 last) {
  final u64 c = fatFindFree();
  if (c < u64(fatFirstCluster)) {
    return c; // 0 = full, 1 = could not read the FAT
  }
  if (fatSetEntry(c, u64(0xFFFF)) > u64(fatErrOk)) {
    return u64(1);
  }
  if (last >= u64(fatFirstCluster)) {
    if (fatSetEntry(last, c) > u64(fatErrOk)) {
      return u64(1);
    }
  }
  fatSetMeta(u64(fatMetaNextFree), c + u64(1));
  fatSetMeta(u64(fatMetaAllocs), fatMeta(u64(fatMetaAllocs)) + u64(1));
  return c;
}

/// Frees the whole cluster chain starting at [first]. Returns a refusal code.
/// [first] below 2 is [fatErrOk] — a zero-length file has no chain to free.
///
/// **Walks the FAT rather than the chain array**, deliberately: the array holds
/// at most [fatChainMax] clusters and is keyed on a size the directory entry
/// claims, and a file being truncated is exactly the case where that size may
/// be wrong. Reading each link before freeing it is one extra cached read per
/// cluster and makes the walk depend on nothing but the FAT itself.
///
/// **Bounded by the cluster count**, so a cyclic chain frees each of its
/// clusters and then reports [fatErrChainCycle] instead of running forever.
@bare
u64 fatTruncate(u64 first) {
  if (first < u64(fatFirstCluster)) {
    return u64(fatErrOk);
  }
  final u64 bound = fatMeta(u64(fatMetaClusters)) + u64(fatFirstCluster);
  u64 c = first;
  u64 n = u64(0);
  while (n < bound) {
    if (c < u64(fatFirstCluster)) {
      return u64(fatErrChainRange);
    }
    if (c >= bound) {
      return u64(fatErrChainRange);
    }
    final u64 nxt = fatEntry(c);
    if (nxt > u64(0xFFFF)) {
      return u64(fatErrDiskFat);
    }
    if (fatSetEntry(c, u64(fatFreeCluster)) > u64(fatErrOk)) {
      return u64(fatErrDiskWrite);
    }
    fatSetMeta(u64(fatMetaFrees), fatMeta(u64(fatMetaFrees)) + u64(1));
    if (nxt >= u64(fatEocMin)) {
      fatSetMeta(u64(fatMetaNextFree), first);
      return u64(fatErrOk);
    }
    if (nxt == u64(fatBadCluster)) {
      return u64(fatErrChainBad);
    }
    if (nxt == u64(fatFreeCluster)) {
      return u64(fatErrChainFree);
    }
    c = nxt;
    n = n + u64(1);
  }
  return u64(fatErrChainCycle);
}

/// Zeroes the 32 bytes of the directory entry at [e] in the sector buffer.
///
/// A separate function because its caller has a loop of its own and the pinned
/// `dcc` cannot nest one (GAP-0068).
@bare
void fatDirBlank(u64 e) {
  u64 i = u64(0);
  while (i < u64(fatDirEntBytes)) {
    Pointer<u8>.fromAddress(e + i).value = u8(0);
    i = i + u64(1);
  }
}

/// Copies the 11 raw name bytes from the name buffer into the entry at [e].
///
/// The name buffer and the sector buffer are two different regions of
/// `fat_store` (the storage seam's whole point), so nothing here can be
/// clobbered by the sector read that produced [e].
@bare
void fatDirName(u64 e) {
  final u64 nb = fatNameBase();
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    Pointer<u8>.fromAddress(e + u64(fatDirOffName) + i).value =
        Pointer<u8>.fromAddress(nb + i).value;
    i = i + u64(1);
  }
}

/// Writes [first] and [bytes] into root-directory entry [i] and puts the sector
/// back on the drive. Returns a refusal code.
///
/// Rule 3's mechanism. Touches exactly four bytes of size and two of first
/// cluster and leaves every other byte of the entry — name, attribute,
/// timestamps, the FAT32 high cluster word — exactly as it found them.
@bare
u64 fatDirWrite(u64 i, u64 first, u64 bytes) {
  if (i >= fatMeta(u64(fatMetaRootEntries))) {
    return u64(fatErrDiskDir);
  }
  final u64 lba = fatMeta(u64(fatMetaRootStart)) + (i >> u64(4));
  if (fatReadCached(lba) > u64(0)) {
    return u64(fatErrDiskDir);
  }
  final u64 e = fatSectorBase() + ((i & u64(15)) << u64(5));
  fatPut16(e + u64(fatDirOffCluster), first);
  fatPut32(e + u64(fatDirOffSize), bytes);
  return fatWriteSector(lba, fatSectorBase());
}

/// The index of the first reusable root-directory entry — free (0x00) or
/// deleted (0xE5). Returns `rootEntries` if the directory is full, or
/// `rootEntries + 1` if a directory sector could not be read.
@bare
u64 fatDirFreeSlot() {
  final u64 n = fatMeta(u64(fatMetaRootEntries));
  u64 i = u64(0);
  while (i < n) {
    final u64 e = fatDirEntry(i);
    if (e < u64(1)) {
      return n + u64(1);
    }
    final u64 c0 = fatU8(e);
    if (c0 == u64(fatDirFree)) {
      return i;
    }
    if (c0 == u64(fatDirDeleted)) {
      return i;
    }
    i = i + u64(1);
  }
  return n;
}

/// Makes sure entry [j] still reads as end-of-directory. Returns a refusal.
///
/// **This is the rule every FAT driver has to keep and most explanations skip.**
/// The first 0x00 entry ends a directory: everything after it is undefined and
/// no reader may look at it. When [fatDirCreate] consumes that entry, the entry
/// after it becomes the new terminator — and it is only a terminator if its
/// first byte is 0x00. On a freshly formatted volume it already is, so this
/// costs one cached read and no write; on a volume where it is not, this is the
/// difference between a directory that ends and one that runs into whatever the
/// formatter left behind.
@bare
u64 fatDirTerminate(u64 j) {
  if (j >= fatMeta(u64(fatMetaRootEntries))) {
    return u64(fatErrOk);
  }
  final u64 e = fatDirEntry(j);
  if (e < u64(1)) {
    return u64(fatErrDiskDir);
  }
  if (fatU8(e) == u64(fatDirFree)) {
    return u64(fatErrOk);
  }
  fatDirBlank(e);
  final u64 lba = fatMeta(u64(fatMetaRootStart)) + (j >> u64(4));
  return fatWriteSector(lba, fatSectorBase());
}

/// 1 if every byte of the name buffer is one a FAT short name may contain.
///
/// **This is checked on the WRITE path and NOT on the read path, and that is
/// deliberate rather than an oversight.** `fatParseAt` accepts any printable
/// byte (GAP-0117), which is laxer than the specification: a name with a `*` or
/// a `|` in it is not a legal FAT short name. Tightening the PARSER would make
/// a file some other formatter had put on a volume unreachable from this
/// kernel — refusing to name a file does not make it safer, it makes it
/// invisible. Tightening the CREATOR is the opposite: a name this kernel writes
/// into a directory is a name every other FAT implementation will have to live
/// with, and putting one there that the specification forbids is how a volume
/// becomes something only this kernel can use.
///
/// The forbidden set is FAT's own: `" * + , / : ; < = > ? [ \ ] |`, plus
/// anything below 0x20 or above 0x7E, plus 0xE5 as the first byte (which means
/// "deleted"). `.` and lower case cannot get here — `fatParseAt` consumes the
/// dot and upper-cases the rest.
@bare
u64 fatNameLegal() {
  final u64 nb = fatNameBase();
  if (Pointer<u8>.fromAddress(nb).value == u8(fatDirDeleted)) {
    return u64(0);
  }
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    final u8 c = Pointer<u8>.fromAddress(nb + i).value;
    if (c < u8(0x20)) {
      return u64(0);
    }
    if (c > u8(0x7E)) {
      return u64(0);
    }
    if (fatNameByteBad(c) > u64(0)) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// 1 if [c] is one of the fifteen bytes a FAT short name may not contain.
///
/// A chain of comparisons each ending in `return`, for GAP-0088's reason: a
/// dense chain becomes a jump table in a section this repo does not control.
@bare
u64 fatNameByteBad(u8 c) {
  if (c == u8(0x22)) {
    return u64(1); // "
  }
  if (c == u8(0x2A)) {
    return u64(1); // *
  }
  if (c == u8(0x2B)) {
    return u64(1); // +
  }
  if (c == u8(0x2C)) {
    return u64(1); // ,
  }
  if (c == u8(0x2E)) {
    return u64(1); // .
  }
  if (c == u8(0x2F)) {
    return u64(1); // /
  }
  if (c == u8(0x3A)) {
    return u64(1); // :
  }
  if (c == u8(0x3B)) {
    return u64(1); // ;
  }
  if (c == u8(0x3C)) {
    return u64(1); // <
  }
  if (c == u8(0x3D)) {
    return u64(1); // =
  }
  if (c == u8(0x3E)) {
    return u64(1); // >
  }
  if (c == u8(0x3F)) {
    return u64(1); // ?
  }
  if (c == u8(0x5B)) {
    return u64(1); // [
  }
  if (c == u8(0x5C)) {
    return u64(1); // backslash
  }
  if (c == u8(0x5D)) {
    return u64(1); // ]
  }
  if (c == u8(0x7C)) {
    return u64(1); // |
  }
  return u64(0);
}

/// Creates a root-directory entry for the name already in the name buffer: 11
/// name bytes, [fatAttrArchive], first cluster 0, size 0, every other byte
/// zero. Leaves the index in [fatMetaFileEntry]. Returns a refusal code.
///
/// **A zero-length file with first cluster 0 is a real, legal FAT file** — the
/// one `m15-fileio`'s volume already carried as `EMPTY.TXT` and which this
/// kernel refuses to `open` for reading (GAP-0122 item 13). Creating one and
/// then growing it is what makes "create" and "allocate" two separate steps
/// that can each fail on their own.
///
/// **No timestamps.** `DIR_CrtTime`, `DIR_WrtTime` and `DIR_LstAccDate` are
/// left as zero because this kernel has no wall clock (GAP-0058: the PIT is
/// masked at rest so `ticks` is reproducible, and there is no RTC driver). Zero
/// is what a FAT date field is allowed to be and what `fsck_msdos` and macOS's
/// `msdos` driver both accept; a made-up date would be worse than no date.
@bare
u64 fatDirCreate() {
  if (fatNameLegal() < u64(1)) {
    return u64(fatErrBadName);
  }
  final u64 n = fatMeta(u64(fatMetaRootEntries));
  final u64 i = fatDirFreeSlot();
  if (i > n) {
    return u64(fatErrDiskDir);
  }
  if (i == n) {
    return u64(fatErrNoDirSlot);
  }
  final u64 lba = fatMeta(u64(fatMetaRootStart)) + (i >> u64(4));
  if (fatReadCached(lba) > u64(0)) {
    return u64(fatErrDiskDir);
  }
  final u64 e = fatSectorBase() + ((i & u64(15)) << u64(5));
  final u64 wasEnd = fatU8(e);
  fatDirBlank(e);
  fatDirName(e);
  Pointer<u8>.fromAddress(e + u64(fatDirOffAttr)).value = u8(fatAttrArchive);
  final u64 w = fatWriteSector(lba, fatSectorBase());
  if (w > u64(fatErrOk)) {
    return w;
  }
  fatSetMeta(u64(fatMetaFileEntry), i);
  fatSetMeta(u64(fatMetaFileAttr), u64(fatAttrArchive));
  fatSetMeta(u64(fatMetaFileFirst), u64(0));
  fatSetMeta(u64(fatMetaFileBytes), u64(0));
  if (wasEnd == u64(fatDirFree)) {
    return fatDirTerminate(i + u64(1));
  }
  return u64(fatErrOk);
}

/// The absolute LBA of sector [k] of a cluster [c]. 0 if [c] is not a data
/// cluster or [k] is past the end of it.
///
/// `file.dart`'s append path needs this and cannot use [fatFileSector], which
/// answers through the cluster ARRAY — a structure a growing file does not
/// have, because its chain is being built one link at a time as the bytes
/// arrive.
@bare
u64 fatClusterSector(u64 c, u64 k) {
  if (fatValidCluster(c) > u64(fatErrOk)) {
    return u64(0);
  }
  final u64 spc = fatMeta(u64(fatMetaSecPerClus));
  if (k >= spc) {
    return u64(0);
  }
  return fatMeta(u64(fatMetaDataStart)) + ((c - u64(fatFirstCluster)) * spc) + k;
}

/// Bytes per cluster on the mounted volume.
@bare
u64 fatClusterBytes() {
  return fatMeta(u64(fatMetaSecPerClus)) << u64(fatSectorShift);
}

/// How many sectors this driver has written since boot. Read by
/// `file.dart`'s report and by nothing else.
@bare
u64 fatWrites() {
  return fatMeta(u64(fatMetaWrites));
}

/// Clusters allocated and clusters freed since boot.
@bare
u64 fatAllocs() {
  return fatMeta(u64(fatMetaAllocs));
}

@bare
u64 fatFrees() {
  return fatMeta(u64(fatMetaFrees));
}

// ---------------------------------------------------------------------------
// `FS ERR <code> <sentence>`
//
// **Every refusal names the field that was wrong.** A chain of comparisons
// rather than a table of pointers because `@bare` DCDart has no array of
// `@rodata` tables to index and no way to return an address and a length
// together (GAP-0060); written as separate `if`s each ending in `return` rather
// than as a dense chain, because LLVM turns a dense chain into a lookup table
// in a section this repo does not control (GAP-0088, GAP-0079).
//
// This function and the 29 tables above it were GENERATED from one list of
// (code, sentence) pairs, so a code without a sentence is not expressible.
// `tests/conformance/m14-fat/run.sh` requires every one of the 29 codes to be
// reachable from a `return` in this file and to have its own distinct sentence.
// ---------------------------------------------------------------------------
@bare
void fatReportError(u64 code) {
  fatSetMeta(u64(fatMetaStatus), code);
  uartWrite(Rodata.addressOf(fatStrErr), u64(7));
  uartPutHex(code, u64(2));
  uartSpace();
  if (code == u64(fatErrDiskBoot)) {
    uartWrite(Rodata.addressOf(fatStrE01), u64(57));
    return;
  }
  if (code == u64(fatErrSignature)) {
    uartWrite(Rodata.addressOf(fatStrE02), u64(58));
    return;
  }
  if (code == u64(fatErrSectorSize)) {
    uartWrite(Rodata.addressOf(fatStrE03), u64(68));
    return;
  }
  if (code == u64(fatErrClusterSize)) {
    uartWrite(Rodata.addressOf(fatStrE04), u64(60));
    return;
  }
  if (code == u64(fatErrReserved)) {
    uartWrite(Rodata.addressOf(fatStrE05), u64(78));
    return;
  }
  if (code == u64(fatErrFatCount)) {
    uartWrite(Rodata.addressOf(fatStrE06), u64(33));
    return;
  }
  if (code == u64(fatErrFat32Shape)) {
    uartWrite(Rodata.addressOf(fatStrE07), u64(57));
    return;
  }
  if (code == u64(fatErrRootEntries)) {
    uartWrite(Rodata.addressOf(fatStrE08), u64(53));
    return;
  }
  if (code == u64(fatErrTotalZero)) {
    uartWrite(Rodata.addressOf(fatStrE09), u64(41));
    return;
  }
  if (code == u64(fatErrGeometry)) {
    uartWrite(Rodata.addressOf(fatStrE10), u64(56));
    return;
  }
  if (code == u64(fatErrFat12)) {
    uartWrite(Rodata.addressOf(fatStrE11), u64(57));
    return;
  }
  if (code == u64(fatErrFat32)) {
    uartWrite(Rodata.addressOf(fatStrE12), u64(60));
    return;
  }
  if (code == u64(fatErrFatSize)) {
    uartWrite(Rodata.addressOf(fatStrE13), u64(51));
    return;
  }
  if (code == u64(fatErrMedia)) {
    uartWrite(Rodata.addressOf(fatStrE14), u64(67));
    return;
  }
  if (code == u64(fatErrDiskDir)) {
    uartWrite(Rodata.addressOf(fatStrE15), u64(42));
    return;
  }
  if (code == u64(fatErrNotFound)) {
    uartWrite(Rodata.addressOf(fatStrE16), u64(35));
    return;
  }
  if (code == u64(fatErrIsDir)) {
    uartWrite(Rodata.addressOf(fatStrE17), u64(66));
    return;
  }
  if (code == u64(fatErrEmpty)) {
    uartWrite(Rodata.addressOf(fatStrE18), u64(67));
    return;
  }
  if (code == u64(fatErrTooBig)) {
    uartWrite(Rodata.addressOf(fatStrE19), u64(57));
    return;
  }
  if (code == u64(fatErrChainRange)) {
    uartWrite(Rodata.addressOf(fatStrE20), u64(58));
    return;
  }
  if (code == u64(fatErrChainFree)) {
    uartWrite(Rodata.addressOf(fatStrE21), u64(63));
    return;
  }
  if (code == u64(fatErrChainBad)) {
    uartWrite(Rodata.addressOf(fatStrE22), u64(47));
    return;
  }
  if (code == u64(fatErrChainCycle)) {
    uartWrite(Rodata.addressOf(fatStrE23), u64(61));
    return;
  }
  if (code == u64(fatErrChainLong)) {
    uartWrite(Rodata.addressOf(fatStrE24), u64(60));
    return;
  }
  if (code == u64(fatErrChainShort)) {
    uartWrite(Rodata.addressOf(fatStrE25), u64(54));
    return;
  }
  if (code == u64(fatErrDiskFat)) {
    uartWrite(Rodata.addressOf(fatStrE26), u64(31));
    return;
  }
  if (code == u64(fatErrDiskData)) {
    uartWrite(Rodata.addressOf(fatStrE27), u64(32));
    return;
  }
  if (code == u64(fatErrFull)) {
    uartWrite(Rodata.addressOf(fatStrE29), u64(36));
    return;
  }
  if (code == u64(fatErrNoDirSlot)) {
    uartWrite(Rodata.addressOf(fatStrE30), u64(42));
    return;
  }
  if (code == u64(fatErrDiskWrite)) {
    uartWrite(Rodata.addressOf(fatStrE31), u64(43));
    return;
  }
  if (code == u64(fatErrReadOnly)) {
    uartWrite(Rodata.addressOf(fatStrE32), u64(52));
    return;
  }
  if (code == u64(fatErrBadName)) {
    uartWrite(Rodata.addressOf(fatStrE28), u64(66));
    return;
  }
  // THE FALL-THROUGH IS UNREACHABLE AND IS HERE ANYWAY. Every code 1..32 has
  // its own branch above; a value outside that range is not a `fatErr*` and
  // nothing in this kernel produces one. Until M16, [fatErrBadName] was the
  // last code and this line was its branch — M16 added three codes above it and
  // gave it one of its own, so that "the highest-numbered code is the one
  // without a branch" stopped being a rule the reporting depended on. GAP-0152
  // added a fourth above those and kept that property.
  uartWrite(Rodata.addressOf(fatStrE28), u64(66));
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// The 11 name bytes of the entry at [e], as `NNNNNNNN.EEE`.
///
/// Printed RAW, out of the directory, with the dot inserted between byte 7 and
/// byte 8 and nothing else changed. The padding spaces are printed too, so
/// every line in a listing has its columns in the same place and a name with a
/// trailing space in it -- which FAT allows and which is invisible in every
/// other tool -- is visible here.
@bare
void fatPrintName(u64 e) {
  uartWrite(e, u64(8));
  conPutc(u8(0x2E));
  uartWrite(e + u64(8), u64(3));
}

/// `FS ENT <i> NAME <name> ATTR <a> CLUS <c> SIZE <n>`, plus ` DIR` for a
/// subdirectory.
@bare
void fatEntryLine(u64 i, u64 e) {
  final u64 attr = fatU8(e + u64(fatDirOffAttr));
  uartWrite(Rodata.addressOf(fatStrEnt), u64(7));
  uartPutHex(i, u64(2));
  uartWrite(Rodata.addressOf(fatStrName), u64(6));
  fatPrintName(e);
  uartWrite(Rodata.addressOf(fatStrAttr), u64(6));
  uartPutHex(attr, u64(2));
  uartWrite(Rodata.addressOf(fatStrClus), u64(6));
  uartPutHex(fatU16(e + u64(fatDirOffCluster)), u64(4));
  uartWrite(Rodata.addressOf(fatStrSize), u64(6));
  uartPutHex(fatU32(e + u64(fatDirOffSize)), u64(8));
  if ((attr & u64(fatAttrDirectory)) > u64(0)) {
    uartWrite(Rodata.addressOf(fatStrDir), u64(4));
  }
  uartNewline();
}

/// Eight cluster numbers of the open file's chain, from [from].
///
/// Eight per line rather than all of them, because a 256-cluster chain on one
/// line is 1280 characters and this console is 80 columns wide. The line label
/// is repeated so that a capture can be diffed line by line.
@bare
void fatClusLine(u64 from, u64 upto) {
  uartWrite(Rodata.addressOf(fatStrClusL), u64(7));
  u64 i = from;
  while (i < upto) {
    uartSpace();
    uartPutHex(fatChain(i), u64(4));
    i = i + u64(1);
  }
  uartNewline();
}

/// `FS CHAIN LEN <n> FIRST <c> LAST <c>` and then the chain itself.
///
/// **The whole chain, not a summary.** This is the evidence that the FAT was
/// walked: on `m14-fat`'s volume the clusters are interleaved with another
/// file's, so a contiguous reader would print a run of consecutive numbers here
/// and the harness requires exactly the numbers `make-image.py` allocated.
@bare
void fatChainReport() {
  final u64 n = fatMeta(u64(fatMetaFileClusters));
  uartWrite(Rodata.addressOf(fatStrChain), u64(13));
  uartPutHex(n, u64(4));
  uartWrite(Rodata.addressOf(fatStrFirst), u64(7));
  uartPutHex(fatChain(u64(0)), u64(4));
  uartWrite(Rodata.addressOf(fatStrLast), u64(6));
  uartPutHex(fatChain(n - u64(1)), u64(4));
  uartNewline();
  u64 i = u64(0);
  while (i < n) {
    u64 upto = i + u64(8);
    if (upto > n) {
      upto = n;
    }
    fatClusLine(i, upto);
    i = upto;
  }
}

// ---------------------------------------------------------------------------
// The shell commands.
// ---------------------------------------------------------------------------

/// `fs` -- mount the volume and report what the boot sector said and what this
/// driver computed from it.
///
/// Two lines: the BPB as read, then the geometry as derived. They are separate
/// on purpose. The first is what is on the disk; the second is this driver's
/// arithmetic, and `tests/conformance/m14-fat/run.sh` checks the second against
/// the numbers `make-image.py` used rather than against the first.
@bare
void shellFatFs() {
  final u64 st = fatMount();
  if (st > u64(fatErrOk)) {
    fatReportError(st);
    return;
  }
  uartWrite(Rodata.addressOf(fatStrMount), u64(13));
  uartPutHex(fatMeta(u64(fatMetaBytesPerSec)), u64(4));
  uartWrite(Rodata.addressOf(fatStrSpc), u64(5));
  uartPutHex(fatMeta(u64(fatMetaSecPerClus)), u64(2));
  uartWrite(Rodata.addressOf(fatStrRsv), u64(5));
  uartPutHex(fatMeta(u64(fatMetaReserved)), u64(4));
  uartWrite(Rodata.addressOf(fatStrNfat), u64(6));
  uartPutHex(fatMeta(u64(fatMetaNumFats)), u64(2));
  uartWrite(Rodata.addressOf(fatStrFatsz), u64(7));
  uartPutHex(fatMeta(u64(fatMetaFatSectors)), u64(4));
  uartWrite(Rodata.addressOf(fatStrRootc), u64(6));
  uartPutHex(fatMeta(u64(fatMetaRootEntries)), u64(4));
  uartWrite(Rodata.addressOf(fatStrTot), u64(5));
  uartPutHex(fatMeta(u64(fatMetaTotalSectors)), u64(8));
  uartNewline();
  uartWrite(Rodata.addressOf(fatStrGeom), u64(12));
  uartPutHex(fatMeta(u64(fatMetaFatStart)), u64(8));
  uartWrite(Rodata.addressOf(fatStrRootc), u64(6));
  uartPutHex(fatMeta(u64(fatMetaRootStart)), u64(8));
  uartWrite(Rodata.addressOf(fatStrData), u64(6));
  uartPutHex(fatMeta(u64(fatMetaDataStart)), u64(8));
  uartWrite(Rodata.addressOf(fatStrClusters), u64(10));
  uartPutHex(fatMeta(u64(fatMetaClusters)), u64(8));
  uartWrite(Rodata.addressOf(fatStrType), u64(6));
  uartPutHex(u64(16), u64(2));
  uartNewline();
}

/// `ls` -- the root directory.
///
/// **Three kinds of entry are skipped and COUNTED rather than silently
/// dropped**: deleted entries (first byte 0xE5), long-filename entries
/// (attribute exactly 0x0F) and the volume label (attribute bit 0x08). The
/// closing line reports how many entries were walked, how many were listed and
/// how many were skipped, and the harness requires the three to add up -- a
/// driver that skipped nothing and a driver that skipped everything would both
/// print a plausible listing otherwise.
@bare
void shellFatLs() {
  final u64 st = fatMount();
  if (st > u64(fatErrOk)) {
    fatReportError(st);
    return;
  }
  fatSetMeta(u64(fatMetaEntries), u64(0));
  fatSetMeta(u64(fatMetaListed), u64(0));
  fatSetMeta(u64(fatMetaSkipped), u64(0));
  final u64 n = fatMeta(u64(fatMetaRootEntries));
  u64 i = u64(0);
  while (i < n) {
    final u64 e = fatDirEntry(i);
    if (e < u64(1)) {
      fatReportError(u64(fatErrDiskDir));
      return;
    }
    final u64 c0 = fatU8(e);
    if (c0 == u64(fatDirFree)) {
      i = n;
    } else {
      fatSetMeta(u64(fatMetaEntries), fatMeta(u64(fatMetaEntries)) + u64(1));
      final u64 attr = fatU8(e + u64(fatDirOffAttr));
      u64 skip = u64(0);
      if (c0 == u64(fatDirDeleted)) {
        skip = u64(1);
      }
      if (attr == u64(fatAttrLongName)) {
        skip = u64(1);
      }
      if ((attr & u64(fatAttrVolumeId)) > u64(0)) {
        skip = u64(1);
      }
      if (skip > u64(0)) {
        fatSetMeta(u64(fatMetaSkipped), fatMeta(u64(fatMetaSkipped)) + u64(1));
      } else {
        fatEntryLine(i, e);
        fatSetMeta(u64(fatMetaListed), fatMeta(u64(fatMetaListed)) + u64(1));
      }
      i = i + u64(1);
    }
  }
  uartWrite(Rodata.addressOf(fatStrList), u64(16));
  uartPutHex(fatMeta(u64(fatMetaEntries)), u64(4));
  uartWrite(Rodata.addressOf(fatStrListed), u64(8));
  uartPutHex(fatMeta(u64(fatMetaListed)), u64(4));
  uartWrite(Rodata.addressOf(fatStrSkipped), u64(9));
  uartPutHex(fatMeta(u64(fatMetaSkipped)), u64(4));
  uartNewline();
}

/// `FS OPEN <name> ATTR <a> CLUS <c> SIZE <n>` for the file that is open.
///
/// The name comes out of the NAME BUFFER rather than out of the directory,
/// because by the time this is called the sector buffer holds a FAT sector.
@bare
void fatOpenLine() {
  uartWrite(Rodata.addressOf(fatStrOpen), u64(8));
  fatPrintName(fatNameBase());
  uartWrite(Rodata.addressOf(fatStrAttr), u64(6));
  uartPutHex(fatMeta(u64(fatMetaFileAttr)), u64(2));
  uartWrite(Rodata.addressOf(fatStrClus), u64(6));
  uartPutHex(fatMeta(u64(fatMetaFileFirst)), u64(4));
  uartWrite(Rodata.addressOf(fatStrSize), u64(6));
  uartPutHex(fatMeta(u64(fatMetaFileBytes)), u64(8));
  uartNewline();
}

/// `cat <name>` -- the file's bytes, along its chain.
///
/// The bytes go out exactly as they arrive, with no translation of any kind: a
/// file with a NUL in it prints a NUL. There is no `write` to a file and no
/// pager; this is `cat` in the strict sense.
@bare
void shellFatCat(u64 from) {
  final u64 st = fatOpen(from);
  if (st > u64(fatErrOk)) {
    fatReportError(st);
    return;
  }
  fatOpenLine();
  fatChainReport();
  uartWrite(Rodata.addressOf(fatStrCat), u64(7));
  fatPrintName(fatNameBase());
  uartWrite(Rodata.addressOf(fatStrBytes), u64(7));
  uartPutHex(fatMeta(u64(fatMetaFileBytes)), u64(8));
  uartWrite(Rodata.addressOf(fatStrClusters), u64(10));
  uartPutHex(fatMeta(u64(fatMetaFileClusters)), u64(4));
  uartNewline();

  u64 left = fatMeta(u64(fatMetaFileBytes));
  u64 s = u64(0);
  while (left > u64(0)) {
    final u64 lba = fatFileSector(s);
    if (lba < u64(1)) {
      fatReportError(u64(fatErrDiskData));
      return;
    }
    if (fatReadCached(lba) > u64(0)) {
      fatReportError(u64(fatErrDiskData));
      return;
    }
    u64 k = left;
    if (k > u64(fatSectorBytes)) {
      k = u64(fatSectorBytes);
    }
    uartWrite(fatSectorBase(), k);
    left = left - k;
    s = s + u64(1);
  }
  uartWrite(Rodata.addressOf(fatStrCatEnd), u64(11));
  uartPutHex(fatMeta(u64(fatMetaFileBytes)), u64(8));
  uartNewline();
}

/// `cat` with no argument.
@bare
void shellFatCatUsage() {
  uartWrite(Rodata.addressOf(fatStrCatUsage), u64(59));
}
