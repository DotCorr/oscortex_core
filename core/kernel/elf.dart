// core/kernel/elf.dart
//
// oscortex_core M10: LOAD AND RUN A REAL ELF BINARY FROM DISK. The first code
// this operating system has ever executed that it did not compile into itself
// -- a freestanding static ELF64 executable, built by a separate toolchain,
// written onto a disk, read off it a sector at a time, mapped at the addresses
// its own program headers name, and entered at its own `e_entry` in ring 3.
//
// The architecture is docs/decisions/0014-elf-loader.md; the binary exit
// criterion is ROADMAP.md's M10 and tests/conformance/m10-elf/run.sh.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS NARROWS: GAP-0085 ITEM 5, AND HALF OF ITEM 4
// ---------------------------------------------------------------------------
// M9's payloads are 136 bytes of hand-written machine code in this kernel's own
// `.rodata`, copied into a frame and jumped to. ADR-0013 §4 said that was the
// right scope for a milestone about privilege -- "building a loader to prove a
// privilege boundary would have made the loader the thing under test" -- and
// listed what it left undone. This is that list's fifth item.
//
// The difference is not size. It is that NOTHING HERE CHOSE THE ADDRESSES.
// M9's payload runs at whatever physical frame `allocFrame()` handed out, is
// position-independent because it has to be, and is entered at the frame's
// first byte because that is where the copy put it. A program in an ELF file
// was linked at addresses a linker on another machine picked; `e_entry` is a
// number this kernel reads out of the file and jumps to, and every `p_vaddr` is
// a number it must honour or the program's own pointers are wrong. That is why
// M10 needed `vmProgMap` -- a real `map(va, pa, flags)` -- and M9 did not.
//
// ---------------------------------------------------------------------------
// WHAT THIS IS NOT: THERE IS NO FILESYSTEM HERE, AND THAT IS DELIBERATE
// ---------------------------------------------------------------------------
// The program is at a KNOWN LBA. `run <lba>` is handed the sector number of a
// 32-byte header this repo's own test harness writes -- a magic, a byte count
// and the LBA the image starts at -- and everything after that is arithmetic on
// sector numbers. There is no directory, no name, no allocation, no free list,
// no metadata, no permissions, no writing, and no way to find a program you do
// not already know the sector number of.
//
// docs/known-gaps.md GAP-0090 lists what a real filesystem would have to add.
// It is written down rather than gestured at, because "we will add a filesystem
// later" is the kind of sentence that hides how much of one is missing.
//
// ---------------------------------------------------------------------------
// WHAT IS REJECTED, AND WHY EVERY REJECTION IS NAMED
// ---------------------------------------------------------------------------
// Twenty-five refusal codes, each with its own sentence. An ELF file is a
// structure this kernel did not produce and cannot trust: every field below is
// read from a disk, and a loader that guessed at a field it did not recognise
// would be jumping to an address chosen by whatever wrote that sector.
//
// The rule is: **if this loader does not understand something, it says which
// thing and stops.** Never a default, never a best effort. `ELF REFUSED 11
// PT_INTERP or PT_DYNAMIC: this loader does not link` is a useful sentence; a
// dynamically-linked binary that loaded anyway and jumped into a PLT stub full
// of zeroes is not.
//
// The two that matter most:
//
//   * a `PT_LOAD` with **both PF_W and PF_X** is refused, loudly, rather than
//     mapped. This kernel enforces W^X on itself (ADR-0012) and does not make
//     an exception for a program that arrived on a disk. `vmProgMap` refuses it
//     a second time, independently, so the check cannot be bypassed by a caller
//     that forgot;
//   * `e_entry` must land inside a page this load actually mapped **and made
//     executable**. Otherwise the first thing a malformed file would do is take
//     an instruction-fetch fault at an address nobody chose.
//
// ---------------------------------------------------------------------------
// THE STORAGE SEAM -- ONE ACCESSOR, ONE CALL SITE
// ---------------------------------------------------------------------------
// DCDart still has no mutable static data of any kind (docs/known-gaps.md
// GAP-0053), so this subsystem's state is assembly-donated `.bss` exactly as
// the allocator's, the address space's and the ring-3 subsystem's are: 128
// bytes in ONE symbol (`elf_store`, core/boot/kdata.S) behind ONE accessor
// (`elf_store_addr`) reached through exactly ONE function ([elfMetaBase]).
// ADR-0011 §0 is the pattern; `tests/conformance/m10-elf/run.sh` counts the
// call site the same way m8-paging counts vm.dart's and m9-ring3 counts
// user.dart's.
//
// ---------------------------------------------------------------------------
// WHAT IS STILL NOT HERE -- docs/known-gaps.md GAP-0089, GAP-0090, GAP-0091
// ---------------------------------------------------------------------------
// One address space, still the kernel's, with one 2MiB window temporarily
// carrying a program. No scheduler, no processes, no `fork`, no `exec`, no
// dynamic linking, no relocation, no filesystem, and one program at a time
// entered synchronously from a shell command. GAP-0085 is narrowed, not closed.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// GENERATED, not hand-typed: a `@rodata` table carries no length (GAP-0060), so
// every byte count below is repeated at its call site by hand, and getting one
// wrong prints the wrong number of bytes. `tests/conformance/m10-elf/run.sh`
// reads every symbol's real size out of `kmain.o` and compares it against what
// the call site passes.
// ---------------------------------------------------------------------------

/// Line label.
///
/// `'ELF DISK LBA '` -- 13 bytes.
@rodata
final List<u8> elfStrDisk = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x20), u8(0x4C), u8(0x42), u8(0x41),
  u8(0x20),
];

/// Field separator.
///
/// `' IMAGE '` -- 7 bytes.
@rodata
final List<u8> elfStrImage = const [
  u8(0x20), u8(0x49), u8(0x4D), u8(0x41), u8(0x47), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' BYTES '` -- 7 bytes.
@rodata
final List<u8> elfStrBytes = const [
  u8(0x20), u8(0x42), u8(0x59), u8(0x54), u8(0x45), u8(0x53), u8(0x20),
];

/// Line label.
///
/// `'ELF IDENT CLASS '` -- 16 bytes.
@rodata
final List<u8> elfStrIdent = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x49), u8(0x44), u8(0x45), u8(0x4E), u8(0x54), u8(0x20), u8(0x43), u8(0x4C),
  u8(0x41), u8(0x53), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' DATA '` -- 6 bytes.
@rodata
final List<u8> elfStrData = const [
  u8(0x20), u8(0x44), u8(0x41), u8(0x54), u8(0x41), u8(0x20),
];

/// Field separator.
///
/// `' TYPE '` -- 6 bytes.
@rodata
final List<u8> elfStrType = const [
  u8(0x20), u8(0x54), u8(0x59), u8(0x50), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' MACHINE '` -- 9 bytes.
@rodata
final List<u8> elfStrMachine = const [
  u8(0x20), u8(0x4D), u8(0x41), u8(0x43), u8(0x48), u8(0x49), u8(0x4E), u8(0x45), u8(0x20),
];

/// Line label.
///
/// `'ELF ENTRY '` -- 10 bytes.
@rodata
final List<u8> elfStrEntry = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x45), u8(0x4E), u8(0x54), u8(0x52), u8(0x59), u8(0x20),
];

/// Field separator.
///
/// `' PHOFF '` -- 7 bytes.
@rodata
final List<u8> elfStrPhoff = const [
  u8(0x20), u8(0x50), u8(0x48), u8(0x4F), u8(0x46), u8(0x46), u8(0x20),
];

/// Field separator.
///
/// `' PHNUM '` -- 7 bytes.
@rodata
final List<u8> elfStrPhnum = const [
  u8(0x20), u8(0x50), u8(0x48), u8(0x4E), u8(0x55), u8(0x4D), u8(0x20),
];

/// Line label.
///
/// `'ELF SEG '` -- 8 bytes.
@rodata
final List<u8> elfStrSeg = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x53), u8(0x45), u8(0x47), u8(0x20),
];

/// Field separator.
///
/// `' FLAGS '` -- 7 bytes.
@rodata
final List<u8> elfStrFlags = const [
  u8(0x20), u8(0x46), u8(0x4C), u8(0x41), u8(0x47), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' VADDR '` -- 7 bytes.
@rodata
final List<u8> elfStrVaddr = const [
  u8(0x20), u8(0x56), u8(0x41), u8(0x44), u8(0x44), u8(0x52), u8(0x20),
];

/// Field separator.
///
/// `' OFF '` -- 5 bytes.
@rodata
final List<u8> elfStrOff = const [
  u8(0x20), u8(0x4F), u8(0x46), u8(0x46), u8(0x20),
];

/// Field separator.
///
/// `' FILESZ '` -- 8 bytes.
@rodata
final List<u8> elfStrFilesz = const [
  u8(0x20), u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x53), u8(0x5A), u8(0x20),
];

/// Field separator.
///
/// `' MEMSZ '` -- 7 bytes.
@rodata
final List<u8> elfStrMemsz = const [
  u8(0x20), u8(0x4D), u8(0x45), u8(0x4D), u8(0x53), u8(0x5A), u8(0x20),
];

/// Line label.
///
/// `'ELF LOAD PAGES '` -- 15 bytes.
@rodata
final List<u8> elfStrLoad = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x4C), u8(0x4F), u8(0x41), u8(0x44), u8(0x20), u8(0x50), u8(0x41), u8(0x47),
  u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' SEGMENTS '` -- 10 bytes.
@rodata
final List<u8> elfStrSegments = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x47), u8(0x4D), u8(0x45), u8(0x4E), u8(0x54), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' ZEROED '` -- 8 bytes.
@rodata
final List<u8> elfStrZeroed = const [
  u8(0x20), u8(0x5A), u8(0x45), u8(0x52), u8(0x4F), u8(0x45), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' SECTORS '` -- 9 bytes.
@rodata
final List<u8> elfStrSectors = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x43), u8(0x54), u8(0x4F), u8(0x52), u8(0x53), u8(0x20),
];

/// Line label.
///
/// `'ELF PAGE '` -- 9 bytes.
@rodata
final List<u8> elfStrPage = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' PA '` -- 4 bytes.
@rodata
final List<u8> elfStrPa = const [
  u8(0x20), u8(0x50), u8(0x41), u8(0x20),
];

/// Line label.
///
/// `'ELF WINDOW PAGES '` -- 17 bytes.
@rodata
final List<u8> elfStrWindow = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x57), u8(0x49), u8(0x4E), u8(0x44), u8(0x4F), u8(0x57), u8(0x20), u8(0x50),
  u8(0x41), u8(0x47), u8(0x45), u8(0x53), u8(0x20),
];

/// Line label.
///
/// `'ELF ENTER RIP '` -- 14 bytes.
@rodata
final List<u8> elfStrEnter = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x45), u8(0x4E), u8(0x54), u8(0x45), u8(0x52), u8(0x20), u8(0x52), u8(0x49),
  u8(0x50), u8(0x20),
];

/// Line label.
///
/// `'ELF STACK '` -- 10 bytes.
@rodata
final List<u8> elfStrStack = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x43), u8(0x4B), u8(0x20),
];

/// Field separator.
///
/// `' FRAME '` -- 7 bytes.
@rodata
final List<u8> elfStrFrame = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x41), u8(0x4D), u8(0x45), u8(0x20),
];

/// Line label.
///
/// `'ELF DONE EXIT '` -- 14 bytes.
@rodata
final List<u8> elfStrDone = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x44), u8(0x4F), u8(0x4E), u8(0x45), u8(0x20), u8(0x45), u8(0x58), u8(0x49),
  u8(0x54), u8(0x20),
];

/// Field separator.
///

/// Line label.
///
/// `'ELF TEARDOWN FREED '` -- 19 bytes.
@rodata
final List<u8> elfStrTeardown = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x54), u8(0x45), u8(0x41), u8(0x52), u8(0x44), u8(0x4F), u8(0x57), u8(0x4E),
  u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' TABLE '` -- 7 bytes.
@rodata
final List<u8> elfStrTable = const [
  u8(0x20), u8(0x54), u8(0x41), u8(0x42), u8(0x4C), u8(0x45), u8(0x20),
];

/// Line label: a refusal, with its code.
///
/// `'ELF REFUSED '` -- 12 bytes.
@rodata
final List<u8> elfStrRefused = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x45), u8(0x44), u8(0x20),
];

/// The label the M14 named form prints instead of `ELF DISK LBA`. The filename
/// follows it, then the same ` IMAGE ` and ` BYTES ` columns the numeric form
/// prints, so the two transcripts line up.
///
/// `'ELF FILE '` -- 9 bytes.
@rodata
final List<u8> elfStrFile = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x20),
];

/// Command name.
///
/// `'run'` -- 3 bytes.
@rodata
final List<u8> elfCmdRun = const [
  u8(0x72), u8(0x75), u8(0x6E),
];

/// Command prefix, space included.
///
/// `'run '` -- 4 bytes.
@rodata
final List<u8> elfCmdRunSp = const [
  u8(0x72), u8(0x75), u8(0x6E), u8(0x20),
];

/// Complete line.
///
/// `'run: usage: run <lba>   (the LBA of the program's header sector, in hex)\n'` -- 73 bytes.
@rodata
final List<u8> elfStrUsage = const [
  u8(0x72), u8(0x75), u8(0x6E), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A), u8(0x20),
  u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x3E), u8(0x20), u8(0x20), u8(0x20),
  u8(0x28), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x4C), u8(0x42), u8(0x41), u8(0x20), u8(0x6F), u8(0x66), u8(0x20),
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72), u8(0x61), u8(0x6D), u8(0x27),
  u8(0x73), u8(0x20), u8(0x68), u8(0x65), u8(0x61), u8(0x64), u8(0x65), u8(0x72), u8(0x20), u8(0x73), u8(0x65), u8(0x63),
  u8(0x74), u8(0x6F), u8(0x72), u8(0x2C), u8(0x20), u8(0x69), u8(0x6E), u8(0x20), u8(0x68), u8(0x65), u8(0x78), u8(0x29),
  u8(0x0A),
];

// ---------------------------------------------------------------------------
// The refusal texts, one per code, in [elfErrNotReady]..[elfErrEntry] order.
//
// One sentence each, naming the FIELD that was wrong rather than the fact that
// something was. An ELF file arrives from outside this repo; "could not load"
// tells whoever produced it nothing at all.
// ---------------------------------------------------------------------------

/// Refusal text.
///
/// `'the address space is not installed, vm READY 0\n'` -- 47 bytes.
@rodata
final List<u8> elfStrE01 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x20),
  u8(0x73), u8(0x70), u8(0x61), u8(0x63), u8(0x65), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74),
  u8(0x20), u8(0x69), u8(0x6E), u8(0x73), u8(0x74), u8(0x61), u8(0x6C), u8(0x6C), u8(0x65), u8(0x64), u8(0x2C), u8(0x20),
  u8(0x76), u8(0x6D), u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x59), u8(0x20), u8(0x30), u8(0x0A),
];

/// Refusal text.
///
/// `'a program is already running\n'` -- 29 bytes.
@rodata
final List<u8> elfStrE02 = const [
  u8(0x61), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72), u8(0x61), u8(0x6D), u8(0x20), u8(0x69), u8(0x73),
  u8(0x20), u8(0x61), u8(0x6C), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x79), u8(0x20), u8(0x72), u8(0x75), u8(0x6E),
  u8(0x6E), u8(0x69), u8(0x6E), u8(0x67), u8(0x0A),
];

/// Refusal text.
///
/// `'no free frame\n'` -- 14 bytes.
@rodata
final List<u8> elfStrE03 = const [
  u8(0x6E), u8(0x6F), u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D),
  u8(0x65), u8(0x0A),
];

/// Refusal text.
///
/// `'the header sector would not read\n'` -- 33 bytes.
@rodata
final List<u8> elfStrE04 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x68), u8(0x65), u8(0x61), u8(0x64), u8(0x65), u8(0x72), u8(0x20), u8(0x73),
  u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x77), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20),
  u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x0A),
];

/// Refusal text.
///
/// `'the header sector does not begin with OSCXPRG1\n'` -- 47 bytes.
@rodata
final List<u8> elfStrE05 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x68), u8(0x65), u8(0x61), u8(0x64), u8(0x65), u8(0x72), u8(0x20), u8(0x73),
  u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x64), u8(0x6F), u8(0x65), u8(0x73), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x74), u8(0x20), u8(0x62), u8(0x65), u8(0x67), u8(0x69), u8(0x6E), u8(0x20), u8(0x77), u8(0x69), u8(0x74),
  u8(0x68), u8(0x20), u8(0x4F), u8(0x53), u8(0x43), u8(0x58), u8(0x50), u8(0x52), u8(0x47), u8(0x31), u8(0x0A),
];

/// Refusal text.
///
/// `'the header sector's byte count is zero or too large\n'` -- 52 bytes.
@rodata
final List<u8> elfStrE06 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x68), u8(0x65), u8(0x61), u8(0x64), u8(0x65), u8(0x72), u8(0x20), u8(0x73),
  u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x27), u8(0x73), u8(0x20), u8(0x62), u8(0x79), u8(0x74), u8(0x65),
  u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x7A), u8(0x65),
  u8(0x72), u8(0x6F), u8(0x20), u8(0x6F), u8(0x72), u8(0x20), u8(0x74), u8(0x6F), u8(0x6F), u8(0x20), u8(0x6C), u8(0x61),
  u8(0x72), u8(0x67), u8(0x65), u8(0x0A),
];

/// Refusal text.
///
/// `'a sector of the image would not read\n'` -- 37 bytes.
@rodata
final List<u8> elfStrE07 = const [
  u8(0x61), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x6F), u8(0x66), u8(0x20),
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x69), u8(0x6D), u8(0x61), u8(0x67), u8(0x65), u8(0x20), u8(0x77), u8(0x6F),
  u8(0x75), u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64),
  u8(0x0A),
];

/// Refusal text.
///
/// `'e_ident does not begin with 7F 45 4C 46\n'` -- 40 bytes.
@rodata
final List<u8> elfStrE08 = const [
  u8(0x65), u8(0x5F), u8(0x69), u8(0x64), u8(0x65), u8(0x6E), u8(0x74), u8(0x20), u8(0x64), u8(0x6F), u8(0x65), u8(0x73),
  u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x62), u8(0x65), u8(0x67), u8(0x69), u8(0x6E), u8(0x20), u8(0x77),
  u8(0x69), u8(0x74), u8(0x68), u8(0x20), u8(0x37), u8(0x46), u8(0x20), u8(0x34), u8(0x35), u8(0x20), u8(0x34), u8(0x43),
  u8(0x20), u8(0x34), u8(0x36), u8(0x0A),
];

/// Refusal text.
///
/// `'e_ident[EI_CLASS] is not 2 (ELFCLASS64)\n'` -- 40 bytes.
@rodata
final List<u8> elfStrE09 = const [
  u8(0x65), u8(0x5F), u8(0x69), u8(0x64), u8(0x65), u8(0x6E), u8(0x74), u8(0x5B), u8(0x45), u8(0x49), u8(0x5F), u8(0x43),
  u8(0x4C), u8(0x41), u8(0x53), u8(0x53), u8(0x5D), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74),
  u8(0x20), u8(0x32), u8(0x20), u8(0x28), u8(0x45), u8(0x4C), u8(0x46), u8(0x43), u8(0x4C), u8(0x41), u8(0x53), u8(0x53),
  u8(0x36), u8(0x34), u8(0x29), u8(0x0A),
];

/// Refusal text.
///
/// `'e_ident[EI_DATA] is not 1 (little-endian)\n'` -- 42 bytes.
@rodata
final List<u8> elfStrE10 = const [
  u8(0x65), u8(0x5F), u8(0x69), u8(0x64), u8(0x65), u8(0x6E), u8(0x74), u8(0x5B), u8(0x45), u8(0x49), u8(0x5F), u8(0x44),
  u8(0x41), u8(0x54), u8(0x41), u8(0x5D), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20),
  u8(0x31), u8(0x20), u8(0x28), u8(0x6C), u8(0x69), u8(0x74), u8(0x74), u8(0x6C), u8(0x65), u8(0x2D), u8(0x65), u8(0x6E),
  u8(0x64), u8(0x69), u8(0x61), u8(0x6E), u8(0x29), u8(0x0A),
];

/// Refusal text.
///
/// `'e_ident[EI_VERSION] is not 1\n'` -- 29 bytes.
@rodata
final List<u8> elfStrE11 = const [
  u8(0x65), u8(0x5F), u8(0x69), u8(0x64), u8(0x65), u8(0x6E), u8(0x74), u8(0x5B), u8(0x45), u8(0x49), u8(0x5F), u8(0x56),
  u8(0x45), u8(0x52), u8(0x53), u8(0x49), u8(0x4F), u8(0x4E), u8(0x5D), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x74), u8(0x20), u8(0x31), u8(0x0A),
];

/// Refusal text.
///
/// `'e_type is not 2 (ET_EXEC)\n'` -- 26 bytes.
@rodata
final List<u8> elfStrE12 = const [
  u8(0x65), u8(0x5F), u8(0x74), u8(0x79), u8(0x70), u8(0x65), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F),
  u8(0x74), u8(0x20), u8(0x32), u8(0x20), u8(0x28), u8(0x45), u8(0x54), u8(0x5F), u8(0x45), u8(0x58), u8(0x45), u8(0x43),
  u8(0x29), u8(0x0A),
];

/// Refusal text.
///
/// `'e_machine is not 3E (EM_X86_64)\n'` -- 32 bytes.
@rodata
final List<u8> elfStrE13 = const [
  u8(0x65), u8(0x5F), u8(0x6D), u8(0x61), u8(0x63), u8(0x68), u8(0x69), u8(0x6E), u8(0x65), u8(0x20), u8(0x69), u8(0x73),
  u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x33), u8(0x45), u8(0x20), u8(0x28), u8(0x45), u8(0x4D), u8(0x5F),
  u8(0x58), u8(0x38), u8(0x36), u8(0x5F), u8(0x36), u8(0x34), u8(0x29), u8(0x0A),
];

/// Refusal text.
///
/// `'e_phentsize is not 56\n'` -- 22 bytes.
@rodata
final List<u8> elfStrE14 = const [
  u8(0x65), u8(0x5F), u8(0x70), u8(0x68), u8(0x65), u8(0x6E), u8(0x74), u8(0x73), u8(0x69), u8(0x7A), u8(0x65), u8(0x20),
  u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x35), u8(0x36), u8(0x0A),
];

/// Refusal text.
///
/// `'e_phnum is zero or larger than 16\n'` -- 34 bytes.
@rodata
final List<u8> elfStrE15 = const [
  u8(0x65), u8(0x5F), u8(0x70), u8(0x68), u8(0x6E), u8(0x75), u8(0x6D), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x7A),
  u8(0x65), u8(0x72), u8(0x6F), u8(0x20), u8(0x6F), u8(0x72), u8(0x20), u8(0x6C), u8(0x61), u8(0x72), u8(0x67), u8(0x65),
  u8(0x72), u8(0x20), u8(0x74), u8(0x68), u8(0x61), u8(0x6E), u8(0x20), u8(0x31), u8(0x36), u8(0x0A),
];

/// Refusal text.
///
/// `'the program headers are not inside the first 4096 bytes\n'` -- 56 bytes.
@rodata
final List<u8> elfStrE16 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72), u8(0x61), u8(0x6D), u8(0x20),
  u8(0x68), u8(0x65), u8(0x61), u8(0x64), u8(0x65), u8(0x72), u8(0x73), u8(0x20), u8(0x61), u8(0x72), u8(0x65), u8(0x20),
  u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x69), u8(0x6E), u8(0x73), u8(0x69), u8(0x64), u8(0x65), u8(0x20), u8(0x74),
  u8(0x68), u8(0x65), u8(0x20), u8(0x66), u8(0x69), u8(0x72), u8(0x73), u8(0x74), u8(0x20), u8(0x34), u8(0x30), u8(0x39),
  u8(0x36), u8(0x20), u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x73), u8(0x0A),
];

/// Refusal text.
///
/// `'PT_INTERP or PT_DYNAMIC: this loader does not link\n'` -- 51 bytes.
@rodata
final List<u8> elfStrE17 = const [
  u8(0x50), u8(0x54), u8(0x5F), u8(0x49), u8(0x4E), u8(0x54), u8(0x45), u8(0x52), u8(0x50), u8(0x20), u8(0x6F), u8(0x72),
  u8(0x20), u8(0x50), u8(0x54), u8(0x5F), u8(0x44), u8(0x59), u8(0x4E), u8(0x41), u8(0x4D), u8(0x49), u8(0x43), u8(0x3A),
  u8(0x20), u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x6C), u8(0x6F), u8(0x61), u8(0x64), u8(0x65), u8(0x72),
  u8(0x20), u8(0x64), u8(0x6F), u8(0x65), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x6C), u8(0x69),
  u8(0x6E), u8(0x6B), u8(0x0A),
];

/// Refusal text.
///
/// `'a PT_LOAD is both writable and executable\n'` -- 42 bytes.
@rodata
final List<u8> elfStrE18 = const [
  u8(0x61), u8(0x20), u8(0x50), u8(0x54), u8(0x5F), u8(0x4C), u8(0x4F), u8(0x41), u8(0x44), u8(0x20), u8(0x69), u8(0x73),
  u8(0x20), u8(0x62), u8(0x6F), u8(0x74), u8(0x68), u8(0x20), u8(0x77), u8(0x72), u8(0x69), u8(0x74), u8(0x61), u8(0x62),
  u8(0x6C), u8(0x65), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x65), u8(0x78), u8(0x65), u8(0x63), u8(0x75),
  u8(0x74), u8(0x61), u8(0x62), u8(0x6C), u8(0x65), u8(0x0A),
];

/// Refusal text.
///
/// `'there is no PT_LOAD header\n'` -- 27 bytes.
@rodata
final List<u8> elfStrE19 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x72), u8(0x65), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20),
  u8(0x50), u8(0x54), u8(0x5F), u8(0x4C), u8(0x4F), u8(0x41), u8(0x44), u8(0x20), u8(0x68), u8(0x65), u8(0x61), u8(0x64),
  u8(0x65), u8(0x72), u8(0x0A),
];

/// Refusal text.
///
/// `'p_offset and p_vaddr are not congruent modulo 4096\n'` -- 51 bytes.
@rodata
final List<u8> elfStrE20 = const [
  u8(0x70), u8(0x5F), u8(0x6F), u8(0x66), u8(0x66), u8(0x73), u8(0x65), u8(0x74), u8(0x20), u8(0x61), u8(0x6E), u8(0x64),
  u8(0x20), u8(0x70), u8(0x5F), u8(0x76), u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x20), u8(0x61), u8(0x72), u8(0x65),
  u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x63), u8(0x6F), u8(0x6E), u8(0x67), u8(0x72), u8(0x75), u8(0x65),
  u8(0x6E), u8(0x74), u8(0x20), u8(0x6D), u8(0x6F), u8(0x64), u8(0x75), u8(0x6C), u8(0x6F), u8(0x20), u8(0x34), u8(0x30),
  u8(0x39), u8(0x36), u8(0x0A),
];

/// Refusal text.
///
/// `'a PT_LOAD lies outside the program window\n'` -- 42 bytes.
@rodata
final List<u8> elfStrE21 = const [
  u8(0x61), u8(0x20), u8(0x50), u8(0x54), u8(0x5F), u8(0x4C), u8(0x4F), u8(0x41), u8(0x44), u8(0x20), u8(0x6C), u8(0x69),
  u8(0x65), u8(0x73), u8(0x20), u8(0x6F), u8(0x75), u8(0x74), u8(0x73), u8(0x69), u8(0x64), u8(0x65), u8(0x20), u8(0x74),
  u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72), u8(0x61), u8(0x6D), u8(0x20), u8(0x77),
  u8(0x69), u8(0x6E), u8(0x64), u8(0x6F), u8(0x77), u8(0x0A),
];

/// Refusal text.
///
/// `'p_filesz is larger than p_memsz\n'` -- 32 bytes.
@rodata
final List<u8> elfStrE22 = const [
  u8(0x70), u8(0x5F), u8(0x66), u8(0x69), u8(0x6C), u8(0x65), u8(0x73), u8(0x7A), u8(0x20), u8(0x69), u8(0x73), u8(0x20),
  u8(0x6C), u8(0x61), u8(0x72), u8(0x67), u8(0x65), u8(0x72), u8(0x20), u8(0x74), u8(0x68), u8(0x61), u8(0x6E), u8(0x20),
  u8(0x70), u8(0x5F), u8(0x6D), u8(0x65), u8(0x6D), u8(0x73), u8(0x7A), u8(0x0A),
];

/// Refusal text.
///
/// `'two PT_LOAD segments want the same page\n'` -- 40 bytes.
@rodata
final List<u8> elfStrE23 = const [
  u8(0x74), u8(0x77), u8(0x6F), u8(0x20), u8(0x50), u8(0x54), u8(0x5F), u8(0x4C), u8(0x4F), u8(0x41), u8(0x44), u8(0x20),
  u8(0x73), u8(0x65), u8(0x67), u8(0x6D), u8(0x65), u8(0x6E), u8(0x74), u8(0x73), u8(0x20), u8(0x77), u8(0x61), u8(0x6E),
  u8(0x74), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x73), u8(0x61), u8(0x6D), u8(0x65), u8(0x20), u8(0x70),
  u8(0x61), u8(0x67), u8(0x65), u8(0x0A),
];

/// Refusal text.
///
/// `'the mapping was refused\n'` -- 24 bytes.
@rodata
final List<u8> elfStrE24 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x6D), u8(0x61), u8(0x70), u8(0x70), u8(0x69), u8(0x6E), u8(0x67), u8(0x20),
  u8(0x77), u8(0x61), u8(0x73), u8(0x20), u8(0x72), u8(0x65), u8(0x66), u8(0x75), u8(0x73), u8(0x65), u8(0x64), u8(0x0A),
];

/// Refusal text.
///
/// `'e_entry is not inside a mapped executable page\n'` -- 47 bytes.
@rodata
final List<u8> elfStrE25 = const [
  u8(0x65), u8(0x5F), u8(0x65), u8(0x6E), u8(0x74), u8(0x72), u8(0x79), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x74), u8(0x20), u8(0x69), u8(0x6E), u8(0x73), u8(0x69), u8(0x64), u8(0x65), u8(0x20), u8(0x61), u8(0x20),
  u8(0x6D), u8(0x61), u8(0x70), u8(0x70), u8(0x65), u8(0x64), u8(0x20), u8(0x65), u8(0x78), u8(0x65), u8(0x63), u8(0x75),
  u8(0x74), u8(0x61), u8(0x62), u8(0x6C), u8(0x65), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x0A),
];

// ---------------------------------------------------------------------------
// The ELF64 structures, from the System V gABI and the x86-64 psABI.
//
// Every offset is a byte offset into a structure this kernel did NOT write, so
// each one is named rather than spelled inline: a wrong constant here reads a
// different field of a real file and produces a plausible wrong answer.
// `tests/conformance/m10-elf/run.sh` checks each of them against the same
// field's offset as `x86_64-elf-readelf` reports it for the program it built.
// ---------------------------------------------------------------------------

/// `e_ident` bytes. EI_MAG0..3 are 0x7F 'E' 'L' 'F'.
const int elfIdentMag0 = 0x7F;
const int elfIdentMag1 = 0x45;
const int elfIdentMag2 = 0x4C;
const int elfIdentMag3 = 0x46;

/// `e_ident[EI_CLASS]`, offset 4. 2 is ELFCLASS64 and it is the only one this
/// kernel can run: a 32-bit executable's program headers are a different size
/// and its addresses are a different width.
const int elfOffClass = 4;
const int elfClass64 = 2;

/// `e_ident[EI_DATA]`, offset 5. 1 is ELFDATA2LSB. **Checked before any
/// multi-byte field is decoded**, because the decode below assumes it.
const int elfOffData = 5;
const int elfData2Lsb = 1;

/// `e_ident[EI_VERSION]`, offset 6.
const int elfOffVersion = 6;
const int elfVersionCurrent = 1;

/// `e_type`, offset 16, 2 bytes. 2 is ET_EXEC. ET_DYN (3) is a
/// position-independent executable and needs relocation this kernel does not
/// do; it is refused by this check rather than loaded at the wrong address.
const int elfOffType = 16;
const int elfTypeExec = 2;

/// `e_machine`, offset 18, 2 bytes. 0x3E is EM_X86_64.
const int elfOffMachine = 18;
const int elfMachineX8664 = 0x3E;

/// `e_entry`, offset 24, 8 bytes. **The number this whole milestone is about.**
const int elfOffEntry = 24;

/// `e_phoff`, offset 32, 8 bytes.
const int elfOffPhoff = 32;

/// `e_phentsize`, offset 54, 2 bytes; `e_phnum`, offset 56, 2 bytes.
const int elfOffPhentsize = 54;
const int elfOffPhnum = 56;

/// The size of one 64-bit program header, and the most this loader will read.
const int elfPhdrSize = 56;
const int elfPhdrMax = 16;

/// Program-header field offsets.
const int elfPhOffType = 0;
const int elfPhOffFlags = 4;
const int elfPhOffOffset = 8;
const int elfPhOffVaddr = 16;
const int elfPhOffFilesz = 32;
const int elfPhOffMemsz = 40;

/// `p_type` values this loader recognises. Everything else is ignored, which is
/// what the gABI says to do -- except the two that mean "this file needs a
/// dynamic linker", which are refused by name.
const int elfPtLoad = 1;
const int elfPtDynamic = 2;
const int elfPtInterp = 3;

/// `p_flags` bits.
const int elfPfX = 1;
const int elfPfW = 2;
const int elfPfR = 4;

// ---------------------------------------------------------------------------
// The header sector. NOT A FILESYSTEM -- see this file's header.
// ---------------------------------------------------------------------------

/// `'OSCXPRG1'` as a little-endian `u64`, which is how the first eight bytes of
/// the header sector read back. Written by
/// `tests/conformance/m10-elf/make-image.py`, and the ONLY thing that
/// distinguishes a header sector from any other 512 bytes on the disk.
const int elfHeaderMagic = 0x314752505843534F;

/// Byte offsets inside the header sector.
const int elfHdrOffMagic = 0;
const int elfHdrOffBytes = 8;
const int elfHdrOffLba = 16;

/// The largest image this loader will read: 64KiB. A bound rather than a limit
/// of principle -- but an unbounded one would let a corrupt byte count spend
/// the rest of the boot reading sectors.
const int elfImageMax = 65536;

/// Bytes per sector, and the shift that divides by it.
const int elfSectorBytes = 512;
const int elfSectorShift = 9;
const int elfSectorsPerPage = 8;

// ---------------------------------------------------------------------------
// Refusal codes. Every one of them is a sentence in [elfReportError].
// ---------------------------------------------------------------------------
const int elfErrOk = 0;
const int elfErrNotReady = 1;
const int elfErrLive = 2;
const int elfErrNoFrames = 3;
const int elfErrDiskHeader = 4;
const int elfErrHeaderMagic = 5;
const int elfErrImageSize = 6;
const int elfErrDiskImage = 7;
const int elfErrMagic = 8;
const int elfErrClass = 9;
const int elfErrData = 10;
const int elfErrVersion = 11;
const int elfErrType = 12;
const int elfErrMachine = 13;
const int elfErrPhEntSize = 14;
const int elfErrPhNum = 15;
const int elfErrPhOff = 16;
const int elfErrDynamic = 17;
const int elfErrWx = 18;
const int elfErrNoLoad = 19;
const int elfErrCongruence = 20;
const int elfErrRange = 21;
const int elfErrFileSz = 22;
const int elfErrOverlap = 23;
const int elfErrMap = 24;
const int elfErrEntry = 25;

// Donated storage: sixteen `u64` words. See `core/boot/kdata.S`.
const int elfStoreBytes = 128;
const int elfStoreWords = 16;

// Metadata word indices. The layout is documented once, in kdata.S.
const int elfMetaLive = 0;
const int elfMetaHeaderLba = 1;
const int elfMetaImageLba = 2;
const int elfMetaImageBytes = 3;
const int elfMetaEntry = 4;
const int elfMetaPtFrame = 5;
const int elfMetaScratch = 6;
const int elfMetaPages = 7;
const int elfMetaSegments = 8;
const int elfMetaLo = 9;
const int elfMetaHi = 10;
const int elfMetaExit = 11;
const int elfMetaStatus = 12;
const int elfMetaSectors = 13;
const int elfMetaStackFrame = 14;
const int elfMetaZeroed = 15;

// ---------------------------------------------------------------------------
// ===========================  THE STORAGE SEAM  ============================
//
// The ONLY function in this kernel that knows where the ELF loader's mutable
// state lives, and the ONLY call site of `elf_store_addr`.
//
// Read this file's header before changing anything here. A second call site, or
// a second `@extern` accessor for loader state, is the change that turns the
// mutable-statics migration from one function into an audit.
// `tests/conformance/m10-elf/run.sh` counts it.
// ---------------------------------------------------------------------------

/// The 128 bytes this subsystem owns, as a DCDart mutable static.
///
/// Until M17 (ADR-0021) this was `elf_store` in core/boot/kdata.S, reached through
/// `@extern u64 elf_store_addr()`. DCDart grew `@bss` (its ADR-0051), so the storage is
/// declared here, in the file that owns it, and the assembly and its accessor
/// are gone. The seam function below  is unchanged in name, arity and meaning;
/// only the expression it returns moved. That is the whole of ADR-0011 section
/// 0's claim, tested.
@bss
final Bss elfStore = const Bss(bytes: elfStoreBytes);

/// Base of the sixteen-word metadata block.
@bare
u64 elfMetaBase() {
  return Bss.addressOf(elfStore);
}

// ======================  END OF THE STORAGE SEAM  ==========================

/// Reads metadata word [i].
@bare
u64 elfMeta(u64 i) {
  return Pointer<u64>.fromAddress(elfMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void elfSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(elfMetaBase() + (i << u64(3))).value = v;
}

/// 1 while a loaded program is executing in ring 3.
///
/// Read by `userSyscall`, `userOwns` and `userOnFault` to decide which of the
/// two things that can be running in ring 3 on this machine is running now.
@bare
u64 elfLive() {
  return elfMeta(u64(elfMetaLive));
}

/// Gives every word of the donated block a known value.
///
/// Called from `kmain()` immediately after [userInit], for exactly [userInit]'s
/// reason: `.bss` is not zeroed by anything in this kernel, `userOnFault` reads
/// [elfLive] on EVERY fault the kernel takes, and a garbage flag would make the
/// first fault of the boot tear down a program that does not exist -- unmapping
/// a window nobody built and freeing frame numbers read out of `.bss` litter.
///
/// Prints NOTHING, and must keep printing nothing:
/// `tests/conformance/m1-interrupts/run.sh` asserts the entire 544-byte serial
/// capture.
@bare
void elfInit() {
  u64 i = u64(0);
  while (i < u64(elfStoreWords)) {
    elfSetMeta(i, u64(0));
    i = i + u64(1);
  }
}

// ---------------------------------------------------------------------------
// Little-endian decode, byte at a time.
//
// NOT a `u64` load through a cast, and that is a correctness requirement twice
// over. First, alignment: DC-IR's `Load` carries no alignment attribute and
// these offsets are into a structure this kernel did not lay out -- `e_phoff`
// is at byte 32 of a header that may itself start anywhere. Second, and more
// to the point: THIS IS THE LITTLE-ENDIAN DECODE `e_ident[EI_DATA]` PROMISES.
// Writing it out is what makes the check on that byte mean something; a wide
// load would be trusting the host's byte order to match the file's.
// ---------------------------------------------------------------------------

/// One byte of the buffer at [a].
@bare
u64 elfU8(u64 a) {
  return Pointer<u8>.fromAddress(a).value.toU64();
}

/// Two bytes, low first.
@bare
u64 elfU16(u64 a) {
  return elfU8(a) | (elfU8(a + u64(1)) << u64(8));
}

/// Four bytes, low first.
@bare
u64 elfU32(u64 a) {
  return elfU16(a) | (elfU16(a + u64(2)) << u64(16));
}

/// Eight bytes, low first.
@bare
u64 elfU64(u64 a) {
  return elfU32(a) | (elfU32(a + u64(4)) << u64(32));
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// `ELF REFUSED <code> <sentence>`
///
/// **Every refusal names the field.** A chain of comparisons rather than a
/// table of pointers because `@bare` DCDart has no array of `@rodata` tables to
/// index and no way to return an address and a length together (GAP-0060);
/// written as separate `if`s each ending in `return` rather than as a dense
/// chain, because LLVM turns a dense chain into a lookup table in a section
/// this repo does not control (GAP-0088, GAP-0079).
@bare
void elfReportError(u64 code) {
  elfSetMeta(u64(elfMetaStatus), code);
  uartWrite(Rodata.addressOf(elfStrRefused), u64(12));
  uartPutHex(code, u64(2));
  uartSpace();
  if (code == u64(elfErrNotReady)) {
    uartWrite(Rodata.addressOf(elfStrE01), u64(47));
    return;
  }
  if (code == u64(elfErrLive)) {
    uartWrite(Rodata.addressOf(elfStrE02), u64(29));
    return;
  }
  if (code == u64(elfErrNoFrames)) {
    uartWrite(Rodata.addressOf(elfStrE03), u64(14));
    return;
  }
  if (code == u64(elfErrDiskHeader)) {
    uartWrite(Rodata.addressOf(elfStrE04), u64(33));
    return;
  }
  if (code == u64(elfErrHeaderMagic)) {
    uartWrite(Rodata.addressOf(elfStrE05), u64(47));
    return;
  }
  if (code == u64(elfErrImageSize)) {
    uartWrite(Rodata.addressOf(elfStrE06), u64(52));
    return;
  }
  if (code == u64(elfErrDiskImage)) {
    uartWrite(Rodata.addressOf(elfStrE07), u64(37));
    return;
  }
  if (code == u64(elfErrMagic)) {
    uartWrite(Rodata.addressOf(elfStrE08), u64(40));
    return;
  }
  if (code == u64(elfErrClass)) {
    uartWrite(Rodata.addressOf(elfStrE09), u64(40));
    return;
  }
  if (code == u64(elfErrData)) {
    uartWrite(Rodata.addressOf(elfStrE10), u64(42));
    return;
  }
  if (code == u64(elfErrVersion)) {
    uartWrite(Rodata.addressOf(elfStrE11), u64(29));
    return;
  }
  if (code == u64(elfErrType)) {
    uartWrite(Rodata.addressOf(elfStrE12), u64(26));
    return;
  }
  if (code == u64(elfErrMachine)) {
    uartWrite(Rodata.addressOf(elfStrE13), u64(32));
    return;
  }
  if (code == u64(elfErrPhEntSize)) {
    uartWrite(Rodata.addressOf(elfStrE14), u64(22));
    return;
  }
  if (code == u64(elfErrPhNum)) {
    uartWrite(Rodata.addressOf(elfStrE15), u64(34));
    return;
  }
  if (code == u64(elfErrPhOff)) {
    uartWrite(Rodata.addressOf(elfStrE16), u64(56));
    return;
  }
  if (code == u64(elfErrDynamic)) {
    uartWrite(Rodata.addressOf(elfStrE17), u64(51));
    return;
  }
  if (code == u64(elfErrWx)) {
    uartWrite(Rodata.addressOf(elfStrE18), u64(42));
    return;
  }
  if (code == u64(elfErrNoLoad)) {
    uartWrite(Rodata.addressOf(elfStrE19), u64(27));
    return;
  }
  if (code == u64(elfErrCongruence)) {
    uartWrite(Rodata.addressOf(elfStrE20), u64(51));
    return;
  }
  if (code == u64(elfErrRange)) {
    uartWrite(Rodata.addressOf(elfStrE21), u64(42));
    return;
  }
  if (code == u64(elfErrFileSz)) {
    uartWrite(Rodata.addressOf(elfStrE22), u64(32));
    return;
  }
  if (code == u64(elfErrOverlap)) {
    uartWrite(Rodata.addressOf(elfStrE23), u64(40));
    return;
  }
  if (code == u64(elfErrMap)) {
    uartWrite(Rodata.addressOf(elfStrE24), u64(24));
    return;
  }
  uartWrite(Rodata.addressOf(elfStrE25), u64(47));
}

/// One mapped page's effective permissions, read out of the LIVE tables:
/// `ELF PAGE <va> P <n> U <n> W <n> X <n> PA <pa>`
///
/// The permission bits come from [vmEffective], i.e. the AND across all four
/// levels, and the physical address comes from the leaf entry -- so this line
/// is a walk of the tables the CPU walks, not a restatement of what
/// [elfLoadSegment] intended to write. `tests/conformance/m10-elf/run.sh`
/// performs the same walk a third time out of guest physical memory and
/// requires the W and X columns to be the ones `p_flags` asked for.
@bare
void elfPageLine(u64 va) {
  final u64 e = vmEffective(va);
  final u64 leaf = vmProgLeaf(va);
  uartWrite(Rodata.addressOf(elfStrPage), u64(9));
  uartPutHex(va, u64(16));
  uartWrite(Rodata.addressOf(vmStrP), u64(3));
  uartPutHex(e & u64(1), u64(1));
  uartWrite(Rodata.addressOf(userStrU), u64(3));
  uartPutHex((e >> u64(1)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(vmStrW), u64(3));
  uartPutHex((e >> u64(2)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(vmStrX), u64(3));
  uartPutHex((e >> u64(3)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(elfStrPa), u64(4));
  uartPutHex(vmEntryAddr(leaf), u64(16));
  uartNewline();
}

/// `ELF WINDOW PAGES <total> USER <count>`, then one [elfPageLine] per mapped
/// page.
///
/// **A COUNT over the whole window, for `userWindowLine`'s reason.** Before a
/// program is loaded it must be 0 -- not "the pages I checked were unmapped",
/// but *none of the 512*. While one is running it is exactly the number the
/// load reported. After it exits or dies it is 0 again, and the page table
/// itself is gone.
@bare
void elfWindowLine() {
  uartWrite(Rodata.addressOf(elfStrWindow), u64(17));
  uartPutHex(u64(vmProgPages), u64(8));
  uartWrite(Rodata.addressOf(userStrUserFld), u64(6));
  uartPutHex(vmCountUser(u64(vmProgBase), u64(vmProgEnd)), u64(8));
  uartNewline();
}

/// Every mapped page of the window, in ascending order.
@bare
void elfPageReport() {
  u64 a = u64(vmProgBase);
  while (a < u64(vmProgEnd)) {
    if ((vmProgLeaf(a) & u64(vmPresent)) > u64(0)) {
      elfPageLine(a);
    }
    a = a + u64(vmPageBytes);
  }
}

// ---------------------------------------------------------------------------
// The loader.
// ---------------------------------------------------------------------------

/// Reads the 32-byte header sector at [lba] into [buf] and records what it
/// says. Returns a refusal code or [elfErrOk].
///
/// **This is the whole of what stands in for a filesystem**, and it is four
/// fields: a magic, a byte count and a starting LBA. It exists so that `run`
/// takes ONE number instead of three, and so that pointing `run` at an
/// arbitrary sector of an arbitrary disk is a diagnostic rather than a jump
/// into whatever was there.
@bare
u64 elfReadHeader(u64 lba, u64 buf) {
  if (ataReadInto(lba, buf) > u64(0)) {
    return u64(elfErrDiskHeader);
  }
  if (elfU64(buf + u64(elfHdrOffMagic)) != u64(elfHeaderMagic)) {
    return u64(elfErrHeaderMagic);
  }
  final u64 bytes = elfU64(buf + u64(elfHdrOffBytes));
  if (bytes < u64(64)) {
    return u64(elfErrImageSize); // shorter than one ELF64 header
  }
  if (bytes > u64(elfImageMax)) {
    return u64(elfErrImageSize);
  }
  elfSetMeta(u64(elfMetaImageBytes), bytes);
  elfSetMeta(u64(elfMetaImageLba), elfU64(buf + u64(elfHdrOffLba)));
  return u64(elfErrOk);
}

/// The absolute LBA of image-relative sector [i], or 0 if there is none.
///
/// **THIS IS WHERE M14 CHANGED THE LOADER, AND IT IS THE WHOLE OF THE CHANGE.**
/// Before M14 the image was a run of consecutive sectors starting at the LBA a
/// 32-byte header sector named, and `elfReadSectors` added. It still is, for
/// `run <lba>`. For `run <name>` the image is a FAT16 file whose sectors are
/// wherever the chain says, and `fatFileSector` is what says.
///
/// The decision is read out of `fat.dart`'s own "a file is open" word rather
/// than duplicated into the loader's metadata, so there is exactly one place
/// that knows which of the two a load is, and it is the place that set it.
///
/// Sector 0 of the disk is the boot sector on any volume and the MBR on any
/// image this repo builds, so 0 is a safe "no": it is never a legal answer.
@bare
u64 elfImageLba(u64 i) {
  if (fatOpenActive() > u64(0)) {
    return fatFileSector(i);
  }
  return elfMeta(u64(elfMetaImageLba)) + i;
}

/// Reads [n] sectors of the image starting at image-relative sector [from] into
/// [buf]. Counts every sector read.
@bare
u64 elfReadSectors(u64 from, u64 n, u64 buf) {
  u64 i = u64(0);
  while (i < n) {
    final u64 lba = elfImageLba(from + i);
    if (lba < u64(1)) {
      return u64(elfErrDiskImage);
    }
    if (ataReadInto(lba, buf + (i << u64(elfSectorShift))) > u64(0)) {
      return u64(elfErrDiskImage);
    }
    elfSetMeta(u64(elfMetaSectors), elfMeta(u64(elfMetaSectors)) + u64(1));
    i = i + u64(1);
  }
  return u64(elfErrOk);
}

/// Validates the ELF header at [h] and records `e_entry`. Returns a refusal
/// code or [elfErrOk].
///
/// **Order is the design.** `e_ident` first, because until EI_CLASS and EI_DATA
/// are known nothing else in the file has a defined size or byte order; then
/// `e_type` and `e_machine`, because a file for another machine may be
/// perfectly well-formed; then the program-header geometry, because the walk
/// after this indexes with it.
@bare
u64 elfCheckHeader(u64 h) {
  if (elfU8(h) != u64(elfIdentMag0)) {
    return u64(elfErrMagic);
  }
  if (elfU8(h + u64(1)) != u64(elfIdentMag1)) {
    return u64(elfErrMagic);
  }
  if (elfU8(h + u64(2)) != u64(elfIdentMag2)) {
    return u64(elfErrMagic);
  }
  if (elfU8(h + u64(3)) != u64(elfIdentMag3)) {
    return u64(elfErrMagic);
  }
  if (elfU8(h + u64(elfOffClass)) != u64(elfClass64)) {
    return u64(elfErrClass);
  }
  if (elfU8(h + u64(elfOffData)) != u64(elfData2Lsb)) {
    return u64(elfErrData);
  }
  if (elfU8(h + u64(elfOffVersion)) != u64(elfVersionCurrent)) {
    return u64(elfErrVersion);
  }
  if (elfU16(h + u64(elfOffType)) != u64(elfTypeExec)) {
    return u64(elfErrType);
  }
  if (elfU16(h + u64(elfOffMachine)) != u64(elfMachineX8664)) {
    return u64(elfErrMachine);
  }
  if (elfU16(h + u64(elfOffPhentsize)) != u64(elfPhdrSize)) {
    return u64(elfErrPhEntSize);
  }
  final u64 phnum = elfU16(h + u64(elfOffPhnum));
  if (phnum < u64(1)) {
    return u64(elfErrPhNum);
  }
  if (phnum > u64(elfPhdrMax)) {
    return u64(elfErrPhNum);
  }
  // The bound is the SMALLER of one page and the image's own length: the
  // program headers have to be inside the bytes this loader actually read, and
  // a file shorter than a page has not filled the rest of the frame with
  // anything but zeroes.
  u64 limit = elfMeta(u64(elfMetaImageBytes));
  if (limit > u64(vmPageBytes)) {
    limit = u64(vmPageBytes);
  }
  final u64 phoff = elfU64(h + u64(elfOffPhoff));
  if (phoff > limit) {
    return u64(elfErrPhOff);
  }
  // `phnum <= elfPhdrMax` and `phoff <= limit <= 4096`, both already checked,
  // so this addition cannot overflow -- which matters, because DCDart's
  // arithmetic traps and both operands came off a disk.
  if ((phoff + (phnum * u64(elfPhdrSize))) > limit) {
    return u64(elfErrPhOff);
  }
  elfSetMeta(u64(elfMetaEntry), elfU64(h + u64(elfOffEntry)));
  return u64(elfErrOk);
}

/// `ELF SEG <n> TYPE <t> FLAGS <f> VADDR <v> OFF <o> FILESZ <s> MEMSZ <m>`
@bare
void elfSegLine(u64 i, u64 ph) {
  uartWrite(Rodata.addressOf(elfStrSeg), u64(8));
  uartPutHex(i, u64(2));
  uartWrite(Rodata.addressOf(elfStrType), u64(6));
  uartPutHex(elfU32(ph + u64(elfPhOffType)), u64(8));
  uartWrite(Rodata.addressOf(elfStrFlags), u64(7));
  uartPutHex(elfU32(ph + u64(elfPhOffFlags)), u64(8));
  uartWrite(Rodata.addressOf(elfStrVaddr), u64(7));
  uartPutHex(elfU64(ph + u64(elfPhOffVaddr)), u64(16));
  uartWrite(Rodata.addressOf(elfStrOff), u64(5));
  uartPutHex(elfU64(ph + u64(elfPhOffOffset)), u64(16));
  uartWrite(Rodata.addressOf(elfStrFilesz), u64(8));
  uartPutHex(elfU64(ph + u64(elfPhOffFilesz)), u64(16));
  uartWrite(Rodata.addressOf(elfStrMemsz), u64(7));
  uartPutHex(elfU64(ph + u64(elfPhOffMemsz)), u64(16));
  uartNewline();
}

/// Checks ONE program header without loading it. Returns a refusal code.
///
/// **The whole pre-flight happens before a single frame is allocated**, so a
/// file this loader will not run costs nothing and leaves nothing behind. That
/// is not tidiness: `elfLoadSegment` maps as it goes, so a rejection discovered
/// half-way through would leave a partially-mapped window that the refusal path
/// would then have to unpick.
@bare
u64 elfCheckPhdr(u64 ph) {
  final u64 type = elfU32(ph + u64(elfPhOffType));
  if (type == u64(elfPtInterp)) {
    return u64(elfErrDynamic);
  }
  if (type == u64(elfPtDynamic)) {
    return u64(elfErrDynamic);
  }
  if (type != u64(elfPtLoad)) {
    return u64(elfErrOk); // ignored, per the gABI
  }
  final u64 flags = elfU32(ph + u64(elfPhOffFlags));
  if ((flags & u64(elfPfW)) > u64(0)) {
    if ((flags & u64(elfPfX)) > u64(0)) {
      return u64(elfErrWx);
    }
  }
  final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
  final u64 offset = elfU64(ph + u64(elfPhOffOffset));
  final u64 filesz = elfU64(ph + u64(elfPhOffFilesz));
  final u64 memsz = elfU64(ph + u64(elfPhOffMemsz));
  if (filesz > memsz) {
    return u64(elfErrFileSz);
  }
  if ((offset & u64(vmPageMask)) != (vaddr & u64(vmPageMask))) {
    return u64(elfErrCongruence);
  }
  // Bounds BEFORE arithmetic, for userOwns' reason: `vaddr` and `memsz` are
  // numbers off a disk, and `vaddr + memsz` on a malformed file would overflow
  // a u64 inside the very check meant to reject it -- and DCDart's arithmetic
  // traps on overflow with a real `ud2` (DCDART_SPEC §4.1), so the trap would
  // be in the kernel rather than in the file.
  if (vaddr < u64(vmProgBase)) {
    return u64(elfErrRange);
  }
  if (vaddr >= u64(vmProgStackPage)) {
    return u64(elfErrRange);
  }
  if (memsz > u64(vmProgBytes)) {
    return u64(elfErrRange);
  }
  if ((vaddr + memsz) > u64(vmProgStackPage)) {
    return u64(elfErrRange);
  }
  // Bounded before they are added, for the reason two checks above: both are
  // numbers off a disk and `offset + filesz` would otherwise be free to
  // overflow inside the test meant to reject it.
  if (offset > u64(elfImageMax)) {
    return u64(elfErrImageSize);
  }
  if (filesz > u64(elfImageMax)) {
    return u64(elfErrImageSize);
  }
  if ((offset + filesz) > elfMeta(u64(elfMetaImageBytes))) {
    return u64(elfErrImageSize);
  }
  return u64(elfErrOk);
}

/// Copies the file bytes of one page of a segment into [frame].
///
/// [pageFileOff] is the 4096-aligned file offset of the page (which exists
/// BECAUSE `p_offset` and `p_vaddr` are congruent modulo 4096, checked in
/// [elfCheckPhdr]); [lo] and [hi] are byte offsets within the page bounding the
/// part that comes from the file. Sectors are read into [scratch] and then
/// copied, rather than read straight into [frame], so the zeroes
/// [elfLoadSegment] already put there survive: a page whose file part is 8
/// bytes must not have the other 4088 overwritten with whatever followed on the
/// disk.
@bare
u64 elfCopyPageBytes(u64 frame, u64 scratch, u64 pageFileOff, u64 lo, u64 hi) {
  final u64 pageSector = pageFileOff >> u64(elfSectorShift);
  final u64 first = (pageFileOff + lo) >> u64(elfSectorShift);
  final u64 last = (pageFileOff + hi - u64(1)) >> u64(elfSectorShift);
  u64 s = first;
  while (s <= last) {
    if (elfReadSectors(s, u64(1), scratch + ((s - pageSector) << u64(elfSectorShift))) >
        u64(0)) {
      return u64(elfErrDiskImage);
    }
    s = s + u64(1);
  }
  userCopy(frame + lo, scratch + lo, hi - lo);
  return u64(elfErrOk);
}

/// Loads one `PT_LOAD` segment: a frame per page, the file bytes copied in, the
/// `p_memsz - p_filesz` tail left zero, and the page mapped with the
/// permissions [flags] asks for.
///
/// **The tail is not zeroed; the page is zeroed and then partly overwritten.**
/// `vmZeroFrame` runs on every frame before anything is copied into it, so
/// `.bss` is zero because the frame is zero, and a page entirely past
/// `p_filesz` needs no disk access at all. Zeroing afterwards would need the
/// same arithmetic run backwards and would get it wrong on the page that
/// contains the `p_filesz` boundary -- which is the only page where it matters.
@bare
u64 elfLoadSegment(u64 ph, u64 scratch) {
  final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
  final u64 offset = elfU64(ph + u64(elfPhOffOffset));
  final u64 filesz = elfU64(ph + u64(elfPhOffFilesz));
  final u64 memsz = elfU64(ph + u64(elfPhOffMemsz));
  final u64 flags = elfU32(ph + u64(elfPhOffFlags));
  u64 write = u64(0);
  if ((flags & u64(elfPfW)) > u64(0)) {
    write = u64(1);
  }
  u64 exec = u64(0);
  if ((flags & u64(elfPfX)) > u64(0)) {
    exec = u64(1);
  }

  final u64 lo = vaddr & u64(0xFFFFFFFFFFFFF000);
  final u64 hi = (vaddr + memsz + u64(vmPageMask)) & u64(0xFFFFFFFFFFFFF000);
  final u64 fileEnd = vaddr + filesz;
  final u64 pageBase = offset & u64(0xFFFFFFFFFFFFF000);

  u64 va = lo;
  while (va < hi) {
    final u64 frame = allocFrame();
    if (frame < u64(1)) {
      return u64(elfErrNoFrames);
    }
    vmZeroFrame(frame);

    // The part of THIS page that comes from the file: the intersection of
    // [va, va + 4096) with [vaddr, vaddr + filesz).
    u64 fromLo = va;
    if (vaddr > fromLo) {
      fromLo = vaddr;
    }
    u64 fromHi = va + u64(vmPageBytes);
    if (fileEnd < fromHi) {
      fromHi = fileEnd;
    }
    if (fromLo < fromHi) {
      final u64 st = elfCopyPageBytes(
          frame, scratch, pageBase + (va - lo), fromLo - va, fromHi - va);
      if (st > u64(0)) {
        // `dcc` refuses to let a value-returning call stand alone as a
        // statement (ADR-0013 §8), so the free's status is bound. It is parked
        // in the status word rather than dropped: on this path the refusal code
        // returned below is what gets reported, and a `freeFrame` that ALSO
        // failed here would otherwise be invisible.
        final u64 back = freeFrame(frame);
        elfSetMeta(u64(elfMetaStatus), back);
        return st;
      }
      elfSetMeta(u64(elfMetaZeroed),
          elfMeta(u64(elfMetaZeroed)) + (u64(vmPageBytes) - (fromHi - fromLo)));
    } else {
      elfSetMeta(u64(elfMetaZeroed), elfMeta(u64(elfMetaZeroed)) + u64(vmPageBytes));
    }

    final u64 m = vmProgMap(va, frame, write, exec);
    if (m > u64(0)) {
      final u64 back = freeFrame(frame);
      elfSetMeta(u64(elfMetaStatus), back);
      if (m == u64(vmProgBusy)) {
        return u64(elfErrOverlap);
      }
      if (m == u64(vmProgWx)) {
        return u64(elfErrWx);
      }
      return u64(elfErrMap);
    }
    elfSetMeta(u64(elfMetaPages), elfMeta(u64(elfMetaPages)) + u64(1));
    if (elfMeta(u64(elfMetaLo)) > va) {
      elfSetMeta(u64(elfMetaLo), va);
    }
    if (elfMeta(u64(elfMetaHi)) < (va + u64(vmPageBytes))) {
      elfSetMeta(u64(elfMetaHi), va + u64(vmPageBytes));
    }
    va = va + u64(vmPageBytes);
  }
  return u64(elfErrOk);
}

/// Unmaps everything in the window, frees every frame behind it, takes the page
/// table back out of the page directory and frees that too.
///
/// Returns the number of frames it handed back. **Safe on a half-built window**
/// -- it walks the leaves rather than a list, so a load that failed on its
/// fourth page frees the three that succeeded.
@bare
u64 elfUnload() {
  u64 freed = u64(0);
  u64 a = u64(vmProgBase);
  while (a < u64(vmProgEnd)) {
    final u64 e = vmProgLeaf(a);
    if ((e & u64(vmPresent)) > u64(0)) {
      final u64 st = vmProgUnmap(a);
      if (st == u64(vmProgOk)) {
        if (freeFrame(vmEntryAddr(e)) == u64(pmmFreeOk)) {
          freed = freed + u64(1);
        }
      }
    }
    a = a + u64(vmPageBytes);
  }
  final u64 pt = elfMeta(u64(elfMetaPtFrame));
  if (pt > u64(0)) {
    final u64 r = vmProgTableRemove();
    elfSetMeta(u64(elfMetaStatus), r);
    if (freeFrame(pt) == u64(pmmFreeOk)) {
      freed = freed + u64(1);
    }
    elfSetMeta(u64(elfMetaPtFrame), u64(0));
  }
  elfSetMeta(u64(elfMetaPages), u64(0));
  elfSetMeta(u64(elfMetaStackFrame), u64(0));
  return freed;
}

/// `ELF TEARDOWN FREED <n> TABLE <pt>` then the window count.
///
/// **Every exit from a loaded program comes through here** -- the `exit`
/// syscall and the fault path both -- for `userTeardown`'s reason: a boundary
/// that is open whenever something went wrong is not a boundary, and a program
/// that dies with a #GP must not leave three user-accessible pages and a live
/// page table behind for the rest of the boot.
///
/// The window is walked and reported AFTER the teardown, so "nothing is mapped"
/// is read out of the tables rather than inferred from the frames having been
/// freed.
@bare
void elfReclaim() {
  // The page table's frame is read BEFORE the unmap, because [elfUnload] frees
  // it and clears the word. Printing it afterwards would report 0 for a table
  // that existed, which is the difference between a report and a habit.
  final u64 pt = elfMeta(u64(elfMetaPtFrame));
  final u64 freed = elfUnload();
  uartWrite(Rodata.addressOf(elfStrTeardown), u64(19));
  uartPutHex(freed, u64(8));
  uartWrite(Rodata.addressOf(elfStrTable), u64(7));
  uartPutHex(pt, u64(16));
  uartNewline();
  elfWindowLine();
}

@bare
void elfTeardown() {
  elfReclaim();
  // M15: and every file descriptor this program held. Here rather than in the
  // `exit` syscall for this function's own reason, one layer down: three of the
  // paths that reach it are faults, and a descriptor table that were only
  // cleaned up when the program was polite would let a faulting program leave a
  // row full of open files for the next `run` to inherit.
  final u64 orphans = fileReleaseOwner(u64(fileRunRow));
  if (orphans > u64(0)) {
    fileOrphanLine(orphans);
  }
  elfSetMeta(u64(elfMetaLive), u64(0));
}

/// 1 if `[ptr, ptr+len)` lies wholly inside pages this program has mapped.
///
/// Called by `userOwns` in place of M9's payload check whenever a loaded
/// program is the thing in ring 3. It is a STRONGER check than M9's, and it has
/// to be: M9's payload owns two pages that are adjacent to nothing, while a
/// loaded program owns a handful of pages with unmapped gaps between them --
/// the whole point of `[vmProgBase, vmProgEnd)` being 512 pages and the program
/// using four. A range test against lo/hi would accept a pointer into a gap and
/// the kernel would then take a page fault dereferencing it, which is a ring-3
/// program choosing which instruction the kernel executes next.
///
/// So every page the range touches is checked against the LIVE tables for the
/// user bit. The bound on [ptr] comes first, before any arithmetic on it, for
/// `userOwns`' exact reason (ADR-0013 §5).
@bare
u64 elfOwns(u64 ptr, u64 len) {
  if (ptr < u64(vmProgBase)) {
    return u64(0);
  }
  if (ptr >= u64(vmProgEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(userWriteMax)) {
    return u64(0);
  }
  if ((ptr + len) > u64(vmProgEnd)) {
    return u64(0);
  }
  u64 a = ptr & u64(0xFFFFFFFFFFFFF000);
  final u64 last = (ptr + len - u64(1)) & u64(0xFFFFFFFFFFFFF000);
  while (a <= last) {
    if ((vmEffective(a) & u64(2)) < u64(1)) {
      return u64(0);
    }
    a = a + u64(vmPageBytes);
  }
  return u64(1);
}

// ---------------------------------------------------------------------------
// The shell command.
// ---------------------------------------------------------------------------

/// The load, from the header sector to a mapped, entry-point-checked program.
///
/// Returns a refusal code. Everything it allocates on a failing path is freed
/// by [elfUnload] in the caller, which is why this function never has to.
@bare
u64 elfLoad(u64 headerLba, u64 hdr, u64 scratch) {
  final u64 hs = elfReadHeader(headerLba, hdr);
  if (hs > u64(0)) {
    return hs;
  }
  uartWrite(Rodata.addressOf(elfStrDisk), u64(13));
  uartPutHex(headerLba, u64(8));
  uartWrite(Rodata.addressOf(elfStrImage), u64(7));
  uartPutHex(elfMeta(u64(elfMetaImageLba)), u64(8));
  uartWrite(Rodata.addressOf(elfStrBytes), u64(7));
  uartPutHex(elfMeta(u64(elfMetaImageBytes)), u64(8));
  uartNewline();
  return elfLoadImage(hdr, scratch);
}

/// The M14 half of [elfLoad]: the image is the FAT16 file `fat.dart` has open,
/// and its length is the directory entry's size rather than a header sector's.
///
/// **There is no `"OSCXPRG1"` header on this path and there does not need to
/// be.** That 32-byte sector existed to carry a length and a starting LBA
/// because nothing else on the disk could; a directory entry carries both, and
/// carries a name as well. The two bounds the header sector's length was
/// checked against are applied here to the directory's size, in the same order
/// and with the same two refusal codes, because they are bounds on what this
/// loader can hold and not on where the number came from.
@bare
u64 elfLoadFile(u64 hdr, u64 scratch) {
  final u64 bytes = fatMeta(u64(fatMetaFileBytes));
  if (bytes < u64(64)) {
    return u64(elfErrImageSize); // shorter than one ELF64 header
  }
  if (bytes > u64(elfImageMax)) {
    return u64(elfErrImageSize);
  }
  elfSetMeta(u64(elfMetaImageBytes), bytes);
  // The FIRST sector of the file, for the report only. Nothing reads this word
  // on the FAT path -- [elfImageLba] goes through the chain -- and printing it
  // is what makes a capture comparable with the numeric path's `IMAGE` column.
  elfSetMeta(u64(elfMetaImageLba), fatFileSector(u64(0)));
  uartWrite(Rodata.addressOf(elfStrFile), u64(9));
  fatPrintName(fatNameBase());
  uartWrite(Rodata.addressOf(elfStrImage), u64(7));
  uartPutHex(elfMeta(u64(elfMetaImageLba)), u64(8));
  uartWrite(Rodata.addressOf(elfStrBytes), u64(7));
  uartPutHex(bytes, u64(8));
  uartNewline();
  return elfLoadImage(hdr, scratch);
}

/// Everything after the image's length and location are known: the ELF header,
/// the pre-flight, the page table, the segments, the stack and the entry-point
/// check.
///
/// Split out of [elfLoad] at M14 so that the two ways of naming an image -- a
/// header sector, or a filename -- share every byte of the actual loading.
@bare
u64 elfLoadImage(u64 hdr, u64 scratch) {
  // The first 4096 bytes of the image: the ELF header and, by [elfCheckHeader]'s
  // bound, the whole program-header table. Read into a frame of its own so the
  // sector reads [elfLoadSegment] performs into `scratch` cannot walk over the
  // headers this function is still indexing.
  u64 want = elfMeta(u64(elfMetaImageBytes));
  if (want > u64(vmPageBytes)) {
    want = u64(vmPageBytes);
  }
  final u64 rs =
      elfReadSectors(u64(0), (want + u64(511)) >> u64(elfSectorShift), hdr);
  if (rs > u64(0)) {
    return rs;
  }
  final u64 cs = elfCheckHeader(hdr);
  if (cs > u64(0)) {
    return cs;
  }
  final u64 phoff = elfU64(hdr + u64(elfOffPhoff));
  final u64 phnum = elfU16(hdr + u64(elfOffPhnum));
  uartWrite(Rodata.addressOf(elfStrIdent), u64(16));
  uartPutHex(elfU8(hdr + u64(elfOffClass)), u64(1));
  uartWrite(Rodata.addressOf(elfStrData), u64(6));
  uartPutHex(elfU8(hdr + u64(elfOffData)), u64(1));
  uartWrite(Rodata.addressOf(elfStrType), u64(6));
  uartPutHex(elfU16(hdr + u64(elfOffType)), u64(4));
  uartWrite(Rodata.addressOf(elfStrMachine), u64(9));
  uartPutHex(elfU16(hdr + u64(elfOffMachine)), u64(4));
  uartNewline();
  uartWrite(Rodata.addressOf(elfStrEntry), u64(10));
  uartPutHex(elfMeta(u64(elfMetaEntry)), u64(16));
  uartWrite(Rodata.addressOf(elfStrPhoff), u64(7));
  uartPutHex(phoff, u64(16));
  uartWrite(Rodata.addressOf(elfStrPhnum), u64(7));
  uartPutHex(phnum, u64(4));
  uartNewline();

  // PRE-FLIGHT: every header is reported and checked before anything is
  // allocated or mapped.
  u64 loads = u64(0);
  u64 i = u64(0);
  while (i < phnum) {
    final u64 ph = hdr + phoff + (i * u64(elfPhdrSize));
    elfSegLine(i, ph);
    final u64 st = elfCheckPhdr(ph);
    if (st > u64(0)) {
      return st;
    }
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      loads = loads + u64(1);
    }
    i = i + u64(1);
  }
  if (loads < u64(1)) {
    return u64(elfErrNoLoad);
  }

  // The page table for the window. One frame, installed once.
  final u64 pt = allocFrame();
  if (pt < u64(1)) {
    return u64(elfErrNoFrames);
  }
  elfSetMeta(u64(elfMetaPtFrame), pt);
  final u64 ti = vmProgTableInstall(pt);
  if (ti > u64(0)) {
    elfSetMeta(u64(elfMetaStatus), ti);
    return u64(elfErrMap);
  }

  elfSetMeta(u64(elfMetaLo), u64(0xFFFFFFFFFFFFFFFF));
  elfSetMeta(u64(elfMetaHi), u64(0));
  i = u64(0);
  while (i < phnum) {
    final u64 ph = hdr + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 st = elfLoadSegment(ph, scratch);
      if (st > u64(0)) {
        return st;
      }
      elfSetMeta(u64(elfMetaSegments), elfMeta(u64(elfMetaSegments)) + u64(1));
    }
    i = i + u64(1);
  }

  // The stack: one page at the top of the window, writable and NOT executable.
  // It is mapped through the same `vmProgMap` the segments went through, so a
  // stack that were executable would be a W+X request and would be refused.
  final u64 sf = allocFrame();
  if (sf < u64(1)) {
    return u64(elfErrNoFrames);
  }
  vmZeroFrame(sf);
  elfSetMeta(u64(elfMetaStackFrame), sf);
  final u64 sm = vmProgMap(u64(vmProgStackPage), sf, u64(1), u64(0));
  if (sm > u64(0)) {
    elfSetMeta(u64(elfMetaStatus), sm);
    final u64 back = freeFrame(sf);
    elfSetMeta(u64(elfMetaStackFrame), back);
    return u64(elfErrMap);
  }
  elfSetMeta(u64(elfMetaPages), elfMeta(u64(elfMetaPages)) + u64(1));

  // THE ENTRY POINT MUST BE SOMEWHERE THIS LOAD ACTUALLY PUT CODE.
  //
  // Read back out of the live tables rather than compared against the segment
  // list: `e_entry` is a number off a disk, and "it is inside the range of a
  // PT_LOAD I saw" is a weaker claim than "the page it is on is present, is
  // reachable from ring 3, and is executable".
  final u64 entry = elfMeta(u64(elfMetaEntry));
  if (entry < u64(vmProgBase)) {
    return u64(elfErrEntry);
  }
  if (entry >= u64(vmProgEnd)) {
    return u64(elfErrEntry);
  }
  final u64 eff = vmEffective(entry & u64(0xFFFFFFFFFFFFF000));
  if ((eff & u64(1)) < u64(1)) {
    return u64(elfErrEntry);
  }
  if ((eff & u64(2)) < u64(1)) {
    return u64(elfErrEntry);
  }
  if ((eff & u64(8)) < u64(1)) {
    return u64(elfErrEntry);
  }
  return u64(elfErrOk);
}

/// `run <lba>` -- load the ELF at that header sector and enter it in ring 3.
///
/// The sequence, and every step is printed so a boot that stops part-way says
/// where:
///
///   1. two scratch frames: one for the file's first page (its header and
///      program headers), one for the sector reads the segment loader performs.
///      Both are freed before ring 3 is entered -- the program never sees them.
///   2. [elfLoad]: header sector, ELF header, pre-flight, page table, segments,
///      stack, entry-point check. Any refusal returns a code and a sentence.
///   3. the permissions READ BACK out of the live tables, page by page, plus the
///      window count.
///   4. `enter_user` at `e_entry`, which does not return except through the
///      `exit` syscall.
///
/// **Every refusal before step 4 leaves the machine exactly as it was**:
/// [elfUnload] walks the window, frees every frame it finds and takes the page
/// table out, so a file rejected at its third segment costs nothing.
@bare
void shellElfRun(u64 headerLba) {
  // M14: the numeric form must read CONTIGUOUS sectors. A `cat` or a
  // `run <name>` earlier in the session leaves a cluster chain open, and
  // [elfImageLba] would send these reads through it. Closed here, in the one
  // place that knows this load is a numeric one.
  fatClose();
  shellElfLoadAndEnter(headerLba, u64(0));
}

/// `run <name>` -- load the FAT16 file [from] names and enter it in ring 3.
///
/// **This is M14's milestone, and the sector number is gone from it entirely.**
/// The file is found by name in the root directory, its chain is walked and
/// checked, and the loader then reads image-relative sectors through that
/// chain. Nothing anywhere in this path knows an LBA that a human typed.
///
/// The refusal comes from the FILESYSTEM's vocabulary when the filesystem
/// refuses and from the LOADER's when the loader does, and the two are printed
/// by two different functions with two different prefixes, because "no such
/// file" and "that file is not an ELF this kernel will run" are not the same
/// answer and a user who confuses them looks in the wrong place.
@bare
void shellElfRunName(u64 from, u64 end) {
  final u64 fs = fatOpenAt(from, end);
  if (fs > u64(fatErrOk)) {
    fatReportError(fs);
    return;
  }
  fatOpenLine();
  fatChainReport();
  shellElfLoadAndEnter(u64(0), u64(1));
}

/// The body both forms share. [named] chooses which of [elfLoad] and
/// [elfLoadFile] provides the image, and it is passed straight through to
/// [procCreate], which is the one function on this machine that turns a file on
/// a disk into something that can be entered in ring 3.
///
/// ---------------------------------------------------------------------------
/// M20 (ADR-0034): `run` LAUNCHES A PROCESS NOW, AND THAT IS THE WHOLE CHANGE.
/// ---------------------------------------------------------------------------
/// Until M20 this function did its own load and its own `enter_user`, and
/// `proc run` did a DIFFERENT load through [procCreate]. The two had drifted
/// into having one half each of what a program needs:
///
///   * this path built a System V initial stack (M19) and entered ring 3 with
///     no process slot -- so `sbrk` was refused, because a heap's bookkeeping
///     lives in a slot (`heapSlotBase`..`heapSlotCalls`) and there was none.
///     **argv but no heap: `malloc` could not work.**
///   * [procCreate] built a slot, an address space and a heap, and entered with
///     RSP at the top of an EMPTY page. **A heap but no argv.**
///
/// So no program could have both, which is the thing a real C program needs
/// first. The fix is not to teach this function about heaps -- that would be a
/// second copy of the process machinery, and the copy is what let the two drift
/// in the first place. It is to DELETE this path's launch and call the other
/// one, so there is exactly one function that loads a program and exactly one
/// that starts it.
///
/// **The refusal that used to make this impossible is gone by construction.**
/// [procErrElfLive] exists because an M10 `run` program owns page-directory
/// entry 128 of the KERNEL's directory while a process owns its own; the two
/// could not both be live. This function no longer creates the first kind, so
/// the conflict it guarded against cannot arise from here.
///
/// The session is COOPERATIVE ([procPolicyCoop]) and that is deliberate: `run`
/// starts one program, there is nobody to preempt it for, and a preemptive
/// session would unmask the PIT and move every later `ticks` reading in the
/// shell (ADR-0022, GAP-0058).
@bare
void shellElfLoadAndEnter(u64 headerLba, u64 named) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    elfReportError(u64(elfErrNotReady));
    return;
  }
  // THE `elfLive()` GUARD THAT USED TO STAND HERE IS DELETED. ADR-0039.
  //
  // It asked whether an M10 window program was already running. ADR-0034
  // deleted the only code that started one, and with it the only assignment of
  // a non-zero value to `elfMetaLive` -- `elfInit` and `elfTeardown` both write
  // 0 and nothing writes anything else -- so `elfLive()` is a compile-time zero
  // and the branch was dead. `m10-elf/run.sh` §2i now asserts that no such
  // guard comes back while the flag has no writer, because a guard on a
  // constant is indistinguishable from a guard that works.
  //
  // The `userMetaLive` question below is a DIFFERENT question and is NOT dead:
  // `shellUser` really does set that flag, so an M9 payload really can be in
  // ring 3. It is unreachable from this shell only because the shell is
  // synchronous (docs/known-gaps.md GAP-0243), and it is kept for the caller
  // that is not this shell.
  if (userMeta(u64(userMetaLive)) > u64(0)) {
    elfReportError(u64(elfErrLive));
    return;
  }
  // A process needs somewhere to keep its FPU state, and a machine with no
  // FXSR has nowhere. `proc run` has refused this since M11 (GAP-0092); now
  // that `run` creates a process too, it refuses it in the same words rather
  // than starting a program whose XMM registers nobody owns.
  if (procHead(u64(procHeadSse)) < u64(1)) {
    procRefuse(u64(procErrNoSse));
    return;
  }
  // Live, and unreachable for the reason `shellProcRun`'s twin is: this shell is
  // synchronous. ADR-0039 §4, docs/known-gaps.md GAP-0243.
  if (procLive() > u64(0)) {
    procRefuse(u64(procErrBusy));
    return;
  }

  procSessionReset();
  procSetHead(u64(procHeadPolicy), u64(procPolicyCoop));

  // The arguments are ALREADY STAGED -- `shellElfRunCmd` collected them from
  // the command line before anything was loaded, and [procCreate] builds them
  // onto the stack page the loader maps. Nothing is reset here, which is the
  // one thing that separates this launcher from `proc run`'s.
  final u64 st = procCreate(headerLba, named);
  if (st > u64(0)) {
    procRefuse(st);
    procSessionReset();
    procEndLine();
    return;
  }

  // -------------------------------------------------------------------------
  // THE LOADER'S OWN REPORT, WHICH IS THE LAUNCHER'S TO PRINT.
  //
  // These are the lines m10, m14 and m15 assert the loader by, and they survive
  // ADR-0034 unchanged: they describe the IMAGE, which is still loaded by
  // elf.dart out of `elfMeta`, and not the launch, which is now `proc.dart`'s.
  // They are printed HERE rather than inside [procCreate] because `proc run`
  // does not print them and moving them there would put a `run` command's
  // diagnostics into every process the scheduler creates.
  // -------------------------------------------------------------------------
  uartWrite(Rodata.addressOf(elfStrLoad), u64(15));
  uartPutHex(elfMeta(u64(elfMetaPages)), u64(8));
  uartWrite(Rodata.addressOf(elfStrSegments), u64(10));
  uartPutHex(elfMeta(u64(elfMetaSegments)), u64(8));
  uartWrite(Rodata.addressOf(elfStrZeroed), u64(8));
  uartPutHex(elfMeta(u64(elfMetaZeroed)), u64(8));
  uartWrite(Rodata.addressOf(elfStrSectors), u64(9));
  uartPutHex(elfMeta(u64(elfMetaSectors)), u64(8));
  uartNewline();
  uartWrite(Rodata.addressOf(elfStrStack), u64(10));
  uartPutHex(u64(vmProgStackTop), u64(16));
  uartWrite(Rodata.addressOf(elfStrFrame), u64(7));
  uartPutHex(elfMeta(u64(elfMetaStackFrame)), u64(16));
  uartWrite(Rodata.addressOf(elfStrTable), u64(7));
  uartPutHex(elfMeta(u64(elfMetaPtFrame)), u64(16));
  uartNewline();
  // Printed after the load, because the addresses in it are addresses in the
  // stack page the load allocated.
  argsReport();

  uartWrite(Rodata.addressOf(elfStrEnter), u64(14));
  uartPutHex(elfMeta(u64(elfMetaEntry)), u64(16));
  uartWrite(Rodata.addressOf(userStrRsp), u64(5));
  uartPutHex(procGet(u64(0), u64(procSlotRsp)), u64(16));
  uartNewline();

  procStart(u64(0)); // returns only through `user_return`

  procToKernel();

  // Reached only through `user_return`, i.e. only if the program called `exit`.
  // A program that faulted came back to the shell through `fault_resume` and
  // this frame no longer exists.
  //
  // The exit code comes from `userMetaExit`, which `userSysExit` writes BEFORE
  // it hands control to the process layer -- see the note there. Reading it out
  // of the process slot does not work: `procCleanup` has released the slot by
  // the time this line runs. m14, m15 and m16 assert this line by name.
  // NO PAGE COUNT HERE ANY MORE, and the reason is the whole of ADR-0034 seen
  // from the other end. Before M20 the program's window lived in the KERNEL's
  // page directory, so counting the user pages still mapped in it after the
  // teardown was a question the shell could answer on its own CR3. It is not
  // any more: the window belonged to the PROCESS, and by this line the
  // process's address space has been freed entirely. `vmCountUser` would be
  // walking a page directory entry that is no longer there.
  //
  // The number it used to report is reported better by `PROC KILL SLOT n
  // FREED m`, which counts what actually came back rather than what is left.
  uartWrite(Rodata.addressOf(elfStrDone), u64(14));
  uartPutHex(userMeta(u64(userMetaExit)), u64(16));
  uartNewline();

  procEndLine();
  procPdLine();
}

/// `run` with no argument, or with one this shell cannot parse as an LBA.
@bare
void shellElfUsage() {
  uartWrite(Rodata.addressOf(elfStrUsage), u64(73));
  uartWrite(Rodata.addressOf(fatStrRunUsage), u64(59));
}

/// `run <lba>` from the shell: parse, bound-check, then load.
/// `run <lba>` or `run <name>` from the shell.
///
/// **The two forms are told apart by [ataParseLba], and by nothing else.** It
/// returns a value above `ataLba28Max` for anything that is not one to seven
/// hex digits, so `run 20` is still sector 0x20 and `run PROGA.ELF` is a name.
/// That keeps every earlier harness's `run <lba>` working unchanged and costs
/// one comparison.
///
/// **The ambiguity is real and is not hidden**: a file whose 8.3 name is one to
/// seven hex digits and nothing else -- `CAFE`, `20` -- is reachable by `cat`
/// and not by `run`. docs/known-gaps.md GAP-0119 records it, with the reason a
/// separate spelling was not worth four goldens.
@bare
void shellElfRunCmd() {
  // M19: THE LINE IS TOKENISED NOW, and this is the only place it is. The first
  // token names the program -- an LBA or an 8.3 name, told apart exactly as
  // before -- and the whole of the rest of the line, THE FIRST TOKEN INCLUDED,
  // is the program's `argv`. `argv[0]` is therefore the word the user typed to
  // name the program, which is what `argv[0]` means everywhere else.
  //
  // The arguments are staged BEFORE the load, so a command line this shell will
  // not accept costs nothing: no frame is taken, no sector is read, and the
  // shell prints one sentence and comes back to the prompt.
  final u64 end = argsTokenEnd(u64(4));
  final u64 as = argsCollect(u64(4));
  if (as > u64(argsErrOk)) {
    argsReportError(as);
    return;
  }
  final u64 lba = ataParseLbaAt(u64(4), end);
  if (lba > u64(ataLba28Max)) {
    shellElfRunName(u64(4), end);
    return;
  }
  shellElfRun(lba);
}
