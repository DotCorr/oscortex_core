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
// of zeroes is not. ADR-0126 opens one named exception: a **platform**
// `PLAT.ELF` may carry `PT_INTERP` pointing at an 8.3 loader on the volume
// (`LD.SO`). ADR-0127 opens `PT_DYNAMIC` on that same name so the interp
// can apply RELA. Missing the interp is still 11, not a silent static run.
// A TAP/FILES ELF with `PT_INTERP` or `PT_DYNAMIC` is still 11. `libc.so.6`
// is not this door.
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

/// `'PROC DLOPEN '` -- 12 bytes. ADR-0144.
@rodata
final List<u8> elfStrDlopen = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x44), u8(0x4C),
  u8(0x4F), u8(0x50), u8(0x45), u8(0x4E), u8(0x20),
];

/// `'so_mark'` plus NUL -- 8 bytes. ADR-0144 resolves this data word.
@rodata
final List<u8> elfStrSoMark = const [
  u8(0x73), u8(0x6F), u8(0x5F), u8(0x6D), u8(0x61), u8(0x72), u8(0x6B),
  u8(0x00),
];

/// `'write'` plus NUL -- 6 bytes. ADR-0152 resolves this POSIX face
/// from our tiny FAT `LIBC.SO`. Not glibc.
@rodata
final List<u8> elfStrWrite = const [
  u8(0x77), u8(0x72), u8(0x69), u8(0x74), u8(0x65), u8(0x00),
];

/// `'memset'` plus NUL -- 7 bytes. ADR-0169 / ADR-0170 resolves this
/// face from our tiny FAT `LIBC.SO` and binds it into official
/// `memset@plt`. Not glibc. Not OnPaint.
@rodata
final List<u8> elfStrMemset = const [
  u8(0x6D), u8(0x65), u8(0x6D), u8(0x73), u8(0x65), u8(0x74),
  u8(0x00),
];

/// `'memcpy'` plus NUL -- 7 bytes. ADR-0170 high-traffic UND batch.
@rodata
final List<u8> elfStrMemcpy = const [
  u8(0x6D), u8(0x65), u8(0x6D), u8(0x63), u8(0x70), u8(0x79),
  u8(0x00),
];

/// `'memmove'` plus NUL -- 8 bytes. ADR-0170 high-traffic UND batch.
@rodata
final List<u8> elfStrMemmove = const [
  u8(0x6D), u8(0x65), u8(0x6D), u8(0x6D), u8(0x6F), u8(0x76),
  u8(0x65), u8(0x00),
];

/// `'strlen'` plus NUL -- 7 bytes. ADR-0170 high-traffic UND batch.
@rodata
final List<u8> elfStrStrlen = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x6C), u8(0x65), u8(0x6E),
  u8(0x00),
];

/// `'memcmp'` plus NUL -- 7 bytes. ADR-0170 high-traffic UND batch.
@rodata
final List<u8> elfStrMemcmp = const [
  u8(0x6D), u8(0x65), u8(0x6D), u8(0x63), u8(0x6D), u8(0x70),
  u8(0x00),
];

/// `'bcmp'` plus NUL -- 5 bytes. ADR-0171 expanded UND batch.
@rodata
final List<u8> elfStrBcmp = const [
  u8(0x62), u8(0x63), u8(0x6D), u8(0x70), u8(0x00),
];

/// `'memchr'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrMemchr = const [
  u8(0x6D), u8(0x65), u8(0x6D), u8(0x63), u8(0x68), u8(0x72),
  u8(0x00),
];

/// `'strncmp'` plus NUL -- 8 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrncmp = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x6E), u8(0x63), u8(0x6D),
  u8(0x70), u8(0x00),
];

/// `'strcpy'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrcpy = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x63), u8(0x70), u8(0x79),
  u8(0x00),
];

/// `'strcmp'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrcmp = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x63), u8(0x6D), u8(0x70),
  u8(0x00),
];

/// `'strnlen'` plus NUL -- 8 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrnlen = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x6E), u8(0x6C), u8(0x65),
  u8(0x6E), u8(0x00),
];

/// `'strncpy'` plus NUL -- 8 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrncpy = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x6E), u8(0x63), u8(0x70),
  u8(0x79), u8(0x00),
];

/// `'strchr'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrchr = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x63), u8(0x68), u8(0x72),
  u8(0x00),
];

/// `'strrchr'` plus NUL -- 8 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrrchr = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x72), u8(0x63), u8(0x68),
  u8(0x72), u8(0x00),
];

/// `'strstr'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrstr = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x73), u8(0x74), u8(0x72),
  u8(0x00),
];

/// `'strcat'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrcat = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x63), u8(0x61), u8(0x74),
  u8(0x00),
];

/// `'strspn'` plus NUL -- 7 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrspn = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x73), u8(0x70), u8(0x6E),
  u8(0x00),
];

/// `'strcspn'` plus NUL -- 8 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrcspn = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x63), u8(0x73), u8(0x70),
  u8(0x6E), u8(0x00),
];

/// `'strncat'` plus NUL -- 8 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrncat = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x6E), u8(0x63), u8(0x61),
  u8(0x74), u8(0x00),
];

/// `'strcasecmp'` plus NUL -- 11 bytes. ADR-0171.
@rodata
final List<u8> elfStrStrcasecmp = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x63), u8(0x61), u8(0x73),
  u8(0x65), u8(0x63), u8(0x6D), u8(0x70), u8(0x00),
];

/// ADR-0172 expanded UND batch (faces 20..49).
@rodata
final List<u8> elfStrStrncasecmp = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x6E), u8(0x63), u8(0x61),
  u8(0x73), u8(0x65), u8(0x63), u8(0x6D), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrWcsncmp = const [
  u8(0x77), u8(0x63), u8(0x73), u8(0x6E), u8(0x63), u8(0x6D),
  u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrWcslen = const [
  u8(0x77), u8(0x63), u8(0x73), u8(0x6C), u8(0x65), u8(0x6E),
  u8(0x00),
];
@rodata
final List<u8> elfStrWmemchr = const [
  u8(0x77), u8(0x6D), u8(0x65), u8(0x6D), u8(0x63), u8(0x68),
  u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrWcscmp = const [
  u8(0x77), u8(0x63), u8(0x73), u8(0x63), u8(0x6D), u8(0x70),
  u8(0x00),
];
@rodata
final List<u8> elfStrWmemcmp = const [
  u8(0x77), u8(0x6D), u8(0x65), u8(0x6D), u8(0x63), u8(0x6D),
  u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrWcschr = const [
  u8(0x77), u8(0x63), u8(0x73), u8(0x63), u8(0x68), u8(0x72),
  u8(0x00),
];
@rodata
final List<u8> elfStrIswdigit = const [
  u8(0x69), u8(0x73), u8(0x77), u8(0x64), u8(0x69), u8(0x67),
  u8(0x69), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrIswalnum = const [
  u8(0x69), u8(0x73), u8(0x77), u8(0x61), u8(0x6C), u8(0x6E),
  u8(0x75), u8(0x6D), u8(0x00),
];
@rodata
final List<u8> elfStrWcspbrk = const [
  u8(0x77), u8(0x63), u8(0x73), u8(0x70), u8(0x62), u8(0x72),
  u8(0x6B), u8(0x00),
];
@rodata
final List<u8> elfStrWcscpy = const [
  u8(0x77), u8(0x63), u8(0x73), u8(0x63), u8(0x70), u8(0x79),
  u8(0x00),
];
@rodata
final List<u8> elfStrTowupper = const [
  u8(0x74), u8(0x6F), u8(0x77), u8(0x75), u8(0x70), u8(0x70),
  u8(0x65), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrTowlower = const [
  u8(0x74), u8(0x6F), u8(0x77), u8(0x6C), u8(0x6F), u8(0x77),
  u8(0x65), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrStrtol = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x74), u8(0x6F), u8(0x6C),
  u8(0x00),
];
@rodata
final List<u8> elfStrStrtoul = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x74), u8(0x6F), u8(0x75),
  u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrStrtoll = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x74), u8(0x6F), u8(0x6C),
  u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrStrtoull = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x74), u8(0x6F), u8(0x75),
  u8(0x6C), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrSchedYield = const [
  u8(0x73), u8(0x63), u8(0x68), u8(0x65), u8(0x64), u8(0x5F),
  u8(0x79), u8(0x69), u8(0x65), u8(0x6C), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrGetpid = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x70), u8(0x69), u8(0x64),
  u8(0x00),
];
@rodata
final List<u8> elfStrGetpagesize = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x70), u8(0x61), u8(0x67),
  u8(0x65), u8(0x73), u8(0x69), u8(0x7A), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrNanf = const [
  u8(0x6E), u8(0x61), u8(0x6E), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrNan = const [
  u8(0x6E), u8(0x61), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrGetenv = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x65), u8(0x6E), u8(0x76),
  u8(0x00),
];
@rodata
final List<u8> elfStrGetauxval = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x61), u8(0x75), u8(0x78),
  u8(0x76), u8(0x61), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrTime = const [
  u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrUsleep = const [
  u8(0x75), u8(0x73), u8(0x6C), u8(0x65), u8(0x65), u8(0x70),
  u8(0x00),
];
@rodata
final List<u8> elfStrGetuid = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x75), u8(0x69), u8(0x64),
  u8(0x00),
];
@rodata
final List<u8> elfStrIsatty = const [
  u8(0x69), u8(0x73), u8(0x61), u8(0x74), u8(0x74), u8(0x79),
  u8(0x00),
];
@rodata
final List<u8> elfStrRand = const [
  u8(0x72), u8(0x61), u8(0x6E), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrGeteuid = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x65), u8(0x75), u8(0x69),
  u8(0x64), u8(0x00),
];


/// ADR-0178 expanded UND batch (faces 50..99).
@rodata
final List<u8> elfStrFloorf = const [
  u8(0x66), u8(0x6C), u8(0x6F), u8(0x6F), u8(0x72), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrCeilf = const [
  u8(0x63), u8(0x65), u8(0x69), u8(0x6C), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrTruncf = const [
  u8(0x74), u8(0x72), u8(0x75), u8(0x6E), u8(0x63), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrRoundf = const [
  u8(0x72), u8(0x6F), u8(0x75), u8(0x6E), u8(0x64), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFloor = const [
  u8(0x66), u8(0x6C), u8(0x6F), u8(0x6F), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrCeil = const [
  u8(0x63), u8(0x65), u8(0x69), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrTrunc = const [
  u8(0x74), u8(0x72), u8(0x75), u8(0x6E), u8(0x63), u8(0x00),
];
@rodata
final List<u8> elfStrRound = const [
  u8(0x72), u8(0x6F), u8(0x75), u8(0x6E), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrPutchar = const [
  u8(0x70), u8(0x75), u8(0x74), u8(0x63), u8(0x68), u8(0x61), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrPuts = const [
  u8(0x70), u8(0x75), u8(0x74), u8(0x73), u8(0x00),
];
@rodata
final List<u8> elfStrSrand = const [
  u8(0x73), u8(0x72), u8(0x61), u8(0x6E), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrGetppid = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x70), u8(0x70), u8(0x69), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrSleep = const [
  u8(0x73), u8(0x6C), u8(0x65), u8(0x65), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrRead = const [
  u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrAbort = const [
  u8(0x61), u8(0x62), u8(0x6F), u8(0x72), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrExit = const [
  u8(0x65), u8(0x78), u8(0x69), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrUExit = const [
  u8(0x5F), u8(0x65), u8(0x78), u8(0x69), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrUnlink = const [
  u8(0x75), u8(0x6E), u8(0x6C), u8(0x69), u8(0x6E), u8(0x6B), u8(0x00),
];
@rodata
final List<u8> elfStrRename = const [
  u8(0x72), u8(0x65), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrMkdir = const [
  u8(0x6D), u8(0x6B), u8(0x64), u8(0x69), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrRmdir = const [
  u8(0x72), u8(0x6D), u8(0x64), u8(0x69), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrAccess = const [
  u8(0x61), u8(0x63), u8(0x63), u8(0x65), u8(0x73), u8(0x73), u8(0x00),
];
@rodata
final List<u8> elfStrChmod = const [
  u8(0x63), u8(0x68), u8(0x6D), u8(0x6F), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrFileno = const [
  u8(0x66), u8(0x69), u8(0x6C), u8(0x65), u8(0x6E), u8(0x6F), u8(0x00),
];
@rodata
final List<u8> elfStrFeof = const [
  u8(0x66), u8(0x65), u8(0x6F), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFerror = const [
  u8(0x66), u8(0x65), u8(0x72), u8(0x72), u8(0x6F), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrFflush = const [
  u8(0x66), u8(0x66), u8(0x6C), u8(0x75), u8(0x73), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrGethostname = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x68), u8(0x6F), u8(0x73), u8(0x74), u8(0x6E),
  u8(0x61), u8(0x6D), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrMunmap = const [
  u8(0x6D), u8(0x75), u8(0x6E), u8(0x6D), u8(0x61), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrMprotect = const [
  u8(0x6D), u8(0x70), u8(0x72), u8(0x6F), u8(0x74), u8(0x65), u8(0x63), u8(0x74),
  u8(0x00),
];
@rodata
final List<u8> elfStrAlarm = const [
  u8(0x61), u8(0x6C), u8(0x61), u8(0x72), u8(0x6D), u8(0x00),
];
@rodata
final List<u8> elfStrPause = const [
  u8(0x70), u8(0x61), u8(0x75), u8(0x73), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrKill = const [
  u8(0x6B), u8(0x69), u8(0x6C), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrDup = const [
  u8(0x64), u8(0x75), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrDup2 = const [
  u8(0x64), u8(0x75), u8(0x70), u8(0x32), u8(0x00),
];
@rodata
final List<u8> elfStrPipe = const [
  u8(0x70), u8(0x69), u8(0x70), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrGetpriority = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x70), u8(0x72), u8(0x69), u8(0x6F), u8(0x72),
  u8(0x69), u8(0x74), u8(0x79), u8(0x00),
];
@rodata
final List<u8> elfStrSetpriority = const [
  u8(0x73), u8(0x65), u8(0x74), u8(0x70), u8(0x72), u8(0x69), u8(0x6F), u8(0x72),
  u8(0x69), u8(0x74), u8(0x79), u8(0x00),
];
@rodata
final List<u8> elfStrSinf = const [
  u8(0x73), u8(0x69), u8(0x6E), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrCosf = const [
  u8(0x63), u8(0x6F), u8(0x73), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrTanf = const [
  u8(0x74), u8(0x61), u8(0x6E), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrExpf = const [
  u8(0x65), u8(0x78), u8(0x70), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrLogf = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrPowf = const [
  u8(0x70), u8(0x6F), u8(0x77), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFmodf = const [
  u8(0x66), u8(0x6D), u8(0x6F), u8(0x64), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrSocket = const [
  u8(0x73), u8(0x6F), u8(0x63), u8(0x6B), u8(0x65), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrSysconf = const [
  u8(0x73), u8(0x79), u8(0x73), u8(0x63), u8(0x6F), u8(0x6E), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrHypotf = const [
  u8(0x68), u8(0x79), u8(0x70), u8(0x6F), u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrNearbyintf = const [
  u8(0x6E), u8(0x65), u8(0x61), u8(0x72), u8(0x62), u8(0x79), u8(0x69), u8(0x6E),
  u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrSin = const [
  u8(0x73), u8(0x69), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrCos = const [
  u8(0x63), u8(0x6F), u8(0x73), u8(0x00),
];
@rodata
final List<u8> elfStrTan = const [
  u8(0x74), u8(0x61), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrAsin = const [
  u8(0x61), u8(0x73), u8(0x69), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrAcos = const [
  u8(0x61), u8(0x63), u8(0x6F), u8(0x73), u8(0x00),
];
@rodata
final List<u8> elfStrAtan = const [
  u8(0x61), u8(0x74), u8(0x61), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrAtan2 = const [
  u8(0x61), u8(0x74), u8(0x61), u8(0x6E), u8(0x32), u8(0x00),
];
@rodata
final List<u8> elfStrExp = const [
  u8(0x65), u8(0x78), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrLog = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x00),
];
@rodata
final List<u8> elfStrExp2 = const [
  u8(0x65), u8(0x78), u8(0x70), u8(0x32), u8(0x00),
];
@rodata
final List<u8> elfStrLog2 = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x32), u8(0x00),
];
@rodata
final List<u8> elfStrPow = const [
  u8(0x70), u8(0x6F), u8(0x77), u8(0x00),
];
@rodata
final List<u8> elfStrHypot = const [
  u8(0x68), u8(0x79), u8(0x70), u8(0x6F), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrSinh = const [
  u8(0x73), u8(0x69), u8(0x6E), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrCosh = const [
  u8(0x63), u8(0x6F), u8(0x73), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrTanh = const [
  u8(0x74), u8(0x61), u8(0x6E), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrAsinf = const [
  u8(0x61), u8(0x73), u8(0x69), u8(0x6E), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrAcosf = const [
  u8(0x61), u8(0x63), u8(0x6F), u8(0x73), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrAtanf = const [
  u8(0x61), u8(0x74), u8(0x61), u8(0x6E), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrAtan2f = const [
  u8(0x61), u8(0x74), u8(0x61), u8(0x6E), u8(0x32), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrSinhf = const [
  u8(0x73), u8(0x69), u8(0x6E), u8(0x68), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrCoshf = const [
  u8(0x63), u8(0x6F), u8(0x73), u8(0x68), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrTanhf = const [
  u8(0x74), u8(0x61), u8(0x6E), u8(0x68), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrExp2f = const [
  u8(0x65), u8(0x78), u8(0x70), u8(0x32), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrLog2f = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x32), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrLog10 = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x31), u8(0x30), u8(0x00),
];
@rodata
final List<u8> elfStrLog10f = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x31), u8(0x30), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrRint = const [
  u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrRintf = const [
  u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrNearbyint = const [
  u8(0x6E), u8(0x65), u8(0x61), u8(0x72), u8(0x62), u8(0x79), u8(0x69), u8(0x6E),
  u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrFma = const [
  u8(0x66), u8(0x6D), u8(0x61), u8(0x00),
];
@rodata
final List<u8> elfStrFmaf = const [
  u8(0x66), u8(0x6D), u8(0x61), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrModf = const [
  u8(0x6D), u8(0x6F), u8(0x64), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrModff = const [
  u8(0x6D), u8(0x6F), u8(0x64), u8(0x66), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFrexp = const [
  u8(0x66), u8(0x72), u8(0x65), u8(0x78), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrFrexpf = const [
  u8(0x66), u8(0x72), u8(0x65), u8(0x78), u8(0x70), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrLdexp = const [
  u8(0x6C), u8(0x64), u8(0x65), u8(0x78), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrLdexpf = const [
  u8(0x6C), u8(0x64), u8(0x65), u8(0x78), u8(0x70), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrCbrt = const [
  u8(0x63), u8(0x62), u8(0x72), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrCbrtf = const [
  u8(0x63), u8(0x62), u8(0x72), u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrNextafter = const [
  u8(0x6E), u8(0x65), u8(0x78), u8(0x74), u8(0x61), u8(0x66), u8(0x74), u8(0x65),
  u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrNextafterf = const [
  u8(0x6E), u8(0x65), u8(0x78), u8(0x74), u8(0x61), u8(0x66), u8(0x74), u8(0x65),
  u8(0x72), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrAcosh = const [
  u8(0x61), u8(0x63), u8(0x6F), u8(0x73), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrAcoshf = const [
  u8(0x61), u8(0x63), u8(0x6F), u8(0x73), u8(0x68), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrAsinh = const [
  u8(0x61), u8(0x73), u8(0x69), u8(0x6E), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrAsinhf = const [
  u8(0x61), u8(0x73), u8(0x69), u8(0x6E), u8(0x68), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrAtanh = const [
  u8(0x61), u8(0x74), u8(0x61), u8(0x6E), u8(0x68), u8(0x00),
];
@rodata
final List<u8> elfStrAtanhf = const [
  u8(0x61), u8(0x74), u8(0x61), u8(0x6E), u8(0x68), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrScalbn = const [
  u8(0x73), u8(0x63), u8(0x61), u8(0x6C), u8(0x62), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrRemainder = const [
  u8(0x72), u8(0x65), u8(0x6D), u8(0x61), u8(0x69), u8(0x6E), u8(0x64), u8(0x65),
  u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrIlogbf = const [
  u8(0x69), u8(0x6C), u8(0x6F), u8(0x67), u8(0x62), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrErf = const [
  u8(0x65), u8(0x72), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrErff = const [
  u8(0x65), u8(0x72), u8(0x66), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrLog1p = const [
  u8(0x6C), u8(0x6F), u8(0x67), u8(0x31), u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrExpm1f = const [
  u8(0x65), u8(0x78), u8(0x70), u8(0x6D), u8(0x31), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFread = const [
  u8(0x66), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrFwrite = const [
  u8(0x66), u8(0x77), u8(0x72), u8(0x69), u8(0x74), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrFseek = const [
  u8(0x66), u8(0x73), u8(0x65), u8(0x65), u8(0x6B), u8(0x00),
];
@rodata
final List<u8> elfStrFtell = const [
  u8(0x66), u8(0x74), u8(0x65), u8(0x6C), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrFgets = const [
  u8(0x66), u8(0x67), u8(0x65), u8(0x74), u8(0x73), u8(0x00),
];
@rodata
final List<u8> elfStrFclose = const [
  u8(0x66), u8(0x63), u8(0x6C), u8(0x6F), u8(0x73), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrFputs = const [
  u8(0x66), u8(0x70), u8(0x75), u8(0x74), u8(0x73), u8(0x00),
];
@rodata
final List<u8> elfStrPrintf = const [
  u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrSnprintf = const [
  u8(0x73), u8(0x6E), u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x66),
  u8(0x00),
];
@rodata
final List<u8> elfStrVsnprintf = const [
  u8(0x76), u8(0x73), u8(0x6E), u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74),
  u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFprintf = const [
  u8(0x66), u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrSprintf = const [
  u8(0x73), u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrFputc = const [
  u8(0x66), u8(0x70), u8(0x75), u8(0x74), u8(0x63), u8(0x00),
];
@rodata
final List<u8> elfStrGetc = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x63), u8(0x00),
];
@rodata
final List<u8> elfStrUngetc = const [
  u8(0x75), u8(0x6E), u8(0x67), u8(0x65), u8(0x74), u8(0x63), u8(0x00),
];
@rodata
final List<u8> elfStrSetvbuf = const [
  u8(0x73), u8(0x65), u8(0x74), u8(0x76), u8(0x62), u8(0x75), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrRewind = const [
  u8(0x72), u8(0x65), u8(0x77), u8(0x69), u8(0x6E), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrSetbuf = const [
  u8(0x73), u8(0x65), u8(0x74), u8(0x62), u8(0x75), u8(0x66), u8(0x00),
];
@rodata
final List<u8> elfStrSigaction = const [
  u8(0x73), u8(0x69), u8(0x67), u8(0x61), u8(0x63), u8(0x74), u8(0x69), u8(0x6F),
  u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrRaise = const [
  u8(0x72), u8(0x61), u8(0x69), u8(0x73), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrNanosleep = const [
  u8(0x6E), u8(0x61), u8(0x6E), u8(0x6F), u8(0x73), u8(0x6C), u8(0x65), u8(0x65),
  u8(0x70), u8(0x00),
];
@rodata
final List<u8> elfStrClockGettime = const [
  u8(0x63), u8(0x6C), u8(0x6F), u8(0x63), u8(0x6B), u8(0x5F), u8(0x67), u8(0x65),
  u8(0x74), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrSignal = const [
  u8(0x73), u8(0x69), u8(0x67), u8(0x6E), u8(0x61), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrStrerror = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x65), u8(0x72), u8(0x72), u8(0x6F), u8(0x72),
  u8(0x00),
];
@rodata
final List<u8> elfStrStrerrorR = const [
  u8(0x73), u8(0x74), u8(0x72), u8(0x65), u8(0x72), u8(0x72), u8(0x6F), u8(0x72),
  u8(0x5F), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrUname = const [
  u8(0x75), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrOpendir = const [
  u8(0x6F), u8(0x70), u8(0x65), u8(0x6E), u8(0x64), u8(0x69), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrClosedir = const [
  u8(0x63), u8(0x6C), u8(0x6F), u8(0x73), u8(0x65), u8(0x64), u8(0x69), u8(0x72),
  u8(0x00),
];
@rodata
final List<u8> elfStrMadvise = const [
  u8(0x6D), u8(0x61), u8(0x64), u8(0x76), u8(0x69), u8(0x73), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrTzset = const [
  u8(0x74), u8(0x7A), u8(0x73), u8(0x65), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrFork = const [
  u8(0x66), u8(0x6F), u8(0x72), u8(0x6B), u8(0x00),
];
@rodata
final List<u8> elfStrChdir = const [
  u8(0x63), u8(0x68), u8(0x64), u8(0x69), u8(0x72), u8(0x00),
];
@rodata
final List<u8> elfStrPoll = const [
  u8(0x70), u8(0x6F), u8(0x6C), u8(0x6C), u8(0x00),
];
@rodata
final List<u8> elfStrQsort = const [
  u8(0x71), u8(0x73), u8(0x6F), u8(0x72), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrBind = const [
  u8(0x62), u8(0x69), u8(0x6E), u8(0x64), u8(0x00),
];
@rodata
final List<u8> elfStrListen = const [
  u8(0x6C), u8(0x69), u8(0x73), u8(0x74), u8(0x65), u8(0x6E), u8(0x00),
];
@rodata
final List<u8> elfStrShutdown = const [
  u8(0x73), u8(0x68), u8(0x75), u8(0x74), u8(0x64), u8(0x6F), u8(0x77), u8(0x6E),
  u8(0x00),
];
@rodata
final List<u8> elfStrConnect = const [
  u8(0x63), u8(0x6F), u8(0x6E), u8(0x6E), u8(0x65), u8(0x63), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrAccept = const [
  u8(0x61), u8(0x63), u8(0x63), u8(0x65), u8(0x70), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrWritev = const [
  u8(0x77), u8(0x72), u8(0x69), u8(0x74), u8(0x65), u8(0x76), u8(0x00),
];
@rodata
final List<u8> elfStrSetsockopt = const [
  u8(0x73), u8(0x65), u8(0x74), u8(0x73), u8(0x6F), u8(0x63), u8(0x6B), u8(0x6F),
  u8(0x70), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrGetsockopt = const [
  u8(0x67), u8(0x65), u8(0x74), u8(0x73), u8(0x6F), u8(0x63), u8(0x6B), u8(0x6F),
  u8(0x70), u8(0x74), u8(0x00),
];
@rodata
final List<u8> elfStrGmtime = const [
  u8(0x67), u8(0x6D), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x00),
];
@rodata
final List<u8> elfStrGmtimeR = const [
  u8(0x67), u8(0x6D), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x5F), u8(0x72),
  u8(0x00),
];
@rodata
final List<u8> elfStrMktime = const [
  u8(0x6D), u8(0x6B), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x00),
];

/// ADR-0180 expanded UND batch (face 200).
@rodata
final List<u8> elfStrSelect = const [
  u8(115), u8(101), u8(108), u8(101), u8(99), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 201).
@rodata
final List<u8> elfStrIoctl = const [
  u8(105), u8(111), u8(99), u8(116), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 202).
@rodata
final List<u8> elfStrStrdup = const [
  u8(115), u8(116), u8(114), u8(100), u8(117), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 203).
@rodata
final List<u8> elfStrStrtod = const [
  u8(115), u8(116), u8(114), u8(116), u8(111), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 204).
@rodata
final List<u8> elfStrStrftime = const [
  u8(115), u8(116), u8(114), u8(102), u8(116), u8(105), u8(109), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 205).
@rodata
final List<u8> elfStrFcntl = const [
  u8(102), u8(99), u8(110), u8(116), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 206).
@rodata
final List<u8> elfStrPrctl = const [
  u8(112), u8(114), u8(99), u8(116), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 207).
@rodata
final List<u8> elfStrSigemptyset = const [
  u8(115), u8(105), u8(103), u8(101), u8(109), u8(112), u8(116), u8(121), u8(115), u8(101), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 208).
@rodata
final List<u8> elfStrSigfillset = const [
  u8(115), u8(105), u8(103), u8(102), u8(105), u8(108), u8(108), u8(115), u8(101), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 209).
@rodata
final List<u8> elfStrSigaddset = const [
  u8(115), u8(105), u8(103), u8(97), u8(100), u8(100), u8(115), u8(101), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 210).
@rodata
final List<u8> elfStrSigdelset = const [
  u8(115), u8(105), u8(103), u8(100), u8(101), u8(108), u8(115), u8(101), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 211).
@rodata
final List<u8> elfStrSigprocmask = const [
  u8(115), u8(105), u8(103), u8(112), u8(114), u8(111), u8(99), u8(109), u8(97), u8(115), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 212).
@rodata
final List<u8> elfStrSigaltstack = const [
  u8(115), u8(105), u8(103), u8(97), u8(108), u8(116), u8(115), u8(116), u8(97), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 213).
@rodata
final List<u8> elfStrSemInit = const [
  u8(115), u8(101), u8(109), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 214).
@rodata
final List<u8> elfStrSemWait = const [
  u8(115), u8(101), u8(109), u8(95), u8(119), u8(97), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 215).
@rodata
final List<u8> elfStrSemPost = const [
  u8(115), u8(101), u8(109), u8(95), u8(112), u8(111), u8(115), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 216).
@rodata
final List<u8> elfStrSemDestroy = const [
  u8(115), u8(101), u8(109), u8(95), u8(100), u8(101), u8(115), u8(116), u8(114), u8(111), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 217).
@rodata
final List<u8> elfStrSemTimedwait = const [
  u8(115), u8(101), u8(109), u8(95), u8(116), u8(105), u8(109), u8(101), u8(100), u8(119), u8(97), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 218).
@rodata
final List<u8> elfStrMmap64 = const [
  u8(109), u8(109), u8(97), u8(112), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 219).
@rodata
final List<u8> elfStrOpen64 = const [
  u8(111), u8(112), u8(101), u8(110), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 220).
@rodata
final List<u8> elfStrOpenat64 = const [
  u8(111), u8(112), u8(101), u8(110), u8(97), u8(116), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 221).
@rodata
final List<u8> elfStrFopen64 = const [
  u8(102), u8(111), u8(112), u8(101), u8(110), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 222).
@rodata
final List<u8> elfStrFdopen = const [
  u8(102), u8(100), u8(111), u8(112), u8(101), u8(110), u8(0),
];
/// ADR-0180 expanded UND batch (face 223).
@rodata
final List<u8> elfStrLseek64 = const [
  u8(108), u8(115), u8(101), u8(101), u8(107), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 224).
@rodata
final List<u8> elfStrPread64 = const [
  u8(112), u8(114), u8(101), u8(97), u8(100), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 225).
@rodata
final List<u8> elfStrPwrite64 = const [
  u8(112), u8(119), u8(114), u8(105), u8(116), u8(101), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 226).
@rodata
final List<u8> elfStrFtruncate64 = const [
  u8(102), u8(116), u8(114), u8(117), u8(110), u8(99), u8(97), u8(116), u8(101), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 227).
@rodata
final List<u8> elfStrFseeko64 = const [
  u8(102), u8(115), u8(101), u8(101), u8(107), u8(111), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 228).
@rodata
final List<u8> elfStrFtello64 = const [
  u8(102), u8(116), u8(101), u8(108), u8(108), u8(111), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 229).
@rodata
final List<u8> elfStrMkstemp64 = const [
  u8(109), u8(107), u8(115), u8(116), u8(101), u8(109), u8(112), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 230).
@rodata
final List<u8> elfStrMkostemp64 = const [
  u8(109), u8(107), u8(111), u8(115), u8(116), u8(101), u8(109), u8(112), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 231).
@rodata
final List<u8> elfStrMkdtemp = const [
  u8(109), u8(107), u8(100), u8(116), u8(101), u8(109), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 232).
@rodata
final List<u8> elfStrReaddir64 = const [
  u8(114), u8(101), u8(97), u8(100), u8(100), u8(105), u8(114), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 233).
@rodata
final List<u8> elfStrGetgrnam = const [
  u8(103), u8(101), u8(116), u8(103), u8(114), u8(110), u8(97), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 234).
@rodata
final List<u8> elfStrGetgrgid = const [
  u8(103), u8(101), u8(116), u8(103), u8(114), u8(103), u8(105), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 235).
@rodata
final List<u8> elfStrGetpwuid = const [
  u8(103), u8(101), u8(116), u8(112), u8(119), u8(117), u8(105), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 236).
@rodata
final List<u8> elfStrEventfd = const [
  u8(101), u8(118), u8(101), u8(110), u8(116), u8(102), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 237).
@rodata
final List<u8> elfStrTimerfdCreate = const [
  u8(116), u8(105), u8(109), u8(101), u8(114), u8(102), u8(100), u8(95), u8(99), u8(114), u8(101), u8(97), u8(116), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 238).
@rodata
final List<u8> elfStrTimerfdSettime = const [
  u8(116), u8(105), u8(109), u8(101), u8(114), u8(102), u8(100), u8(95), u8(115), u8(101), u8(116), u8(116), u8(105), u8(109), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 239).
@rodata
final List<u8> elfStrSchedSetscheduler = const [
  u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(115), u8(101), u8(116), u8(115), u8(99), u8(104), u8(101), u8(100), u8(117), u8(108), u8(101), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 240).
@rodata
final List<u8> elfStrSchedGetscheduler = const [
  u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(103), u8(101), u8(116), u8(115), u8(99), u8(104), u8(101), u8(100), u8(117), u8(108), u8(101), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 241).
@rodata
final List<u8> elfStrSchedGetparam = const [
  u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(103), u8(101), u8(116), u8(112), u8(97), u8(114), u8(97), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 242).
@rodata
final List<u8> elfStrSchedGetaffinity = const [
  u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(103), u8(101), u8(116), u8(97), u8(102), u8(102), u8(105), u8(110), u8(105), u8(116), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 243).
@rodata
final List<u8> elfStrNewlocale = const [
  u8(110), u8(101), u8(119), u8(108), u8(111), u8(99), u8(97), u8(108), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 244).
@rodata
final List<u8> elfStrFreelocale = const [
  u8(102), u8(114), u8(101), u8(101), u8(108), u8(111), u8(99), u8(97), u8(108), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 245).
@rodata
final List<u8> elfStrUselocale = const [
  u8(117), u8(115), u8(101), u8(108), u8(111), u8(99), u8(97), u8(108), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 246).
@rodata
final List<u8> elfStrStrtodL = const [
  u8(115), u8(116), u8(114), u8(116), u8(111), u8(100), u8(95), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 247).
@rodata
final List<u8> elfStrSetlocale = const [
  u8(115), u8(101), u8(116), u8(108), u8(111), u8(99), u8(97), u8(108), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 248).
@rodata
final List<u8> elfStrLocaleconv = const [
  u8(108), u8(111), u8(99), u8(97), u8(108), u8(101), u8(99), u8(111), u8(110), u8(118), u8(0),
];
/// ADR-0180 expanded UND batch (face 249).
@rodata
final List<u8> elfStrSetenv = const [
  u8(115), u8(101), u8(116), u8(101), u8(110), u8(118), u8(0),
];
/// ADR-0180 expanded UND batch (face 250).
@rodata
final List<u8> elfStrUnsetenv = const [
  u8(117), u8(110), u8(115), u8(101), u8(116), u8(101), u8(110), u8(118), u8(0),
];
/// ADR-0180 expanded UND batch (face 251).
@rodata
final List<u8> elfStrSetsid = const [
  u8(115), u8(101), u8(116), u8(115), u8(105), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 252).
@rodata
final List<u8> elfStrReadlink = const [
  u8(114), u8(101), u8(97), u8(100), u8(108), u8(105), u8(110), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 253).
@rodata
final List<u8> elfStrSetpgid = const [
  u8(115), u8(101), u8(116), u8(112), u8(103), u8(105), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 254).
@rodata
final List<u8> elfStrExecvp = const [
  u8(101), u8(120), u8(101), u8(99), u8(118), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 255).
@rodata
final List<u8> elfStrExeclp = const [
  u8(101), u8(120), u8(101), u8(99), u8(108), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 256).
@rodata
final List<u8> elfStrExecv = const [
  u8(101), u8(120), u8(101), u8(99), u8(118), u8(0),
];
/// ADR-0180 expanded UND batch (face 257).
@rodata
final List<u8> elfStrSystem = const [
  u8(115), u8(121), u8(115), u8(116), u8(101), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 258).
@rodata
final List<u8> elfStrClone = const [
  u8(99), u8(108), u8(111), u8(110), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 259).
@rodata
final List<u8> elfStrVfprintf = const [
  u8(118), u8(102), u8(112), u8(114), u8(105), u8(110), u8(116), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 260).
@rodata
final List<u8> elfStrFchmod = const [
  u8(102), u8(99), u8(104), u8(109), u8(111), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 261).
@rodata
final List<u8> elfStrFreeaddrinfo = const [
  u8(102), u8(114), u8(101), u8(101), u8(97), u8(100), u8(100), u8(114), u8(105), u8(110), u8(102), u8(111), u8(0),
];
/// ADR-0180 expanded UND batch (face 262).
@rodata
final List<u8> elfStrSocketpair = const [
  u8(115), u8(111), u8(99), u8(107), u8(101), u8(116), u8(112), u8(97), u8(105), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 263).
@rodata
final List<u8> elfStrGetsockname = const [
  u8(103), u8(101), u8(116), u8(115), u8(111), u8(99), u8(107), u8(110), u8(97), u8(109), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 264).
@rodata
final List<u8> elfStrInetNtop = const [
  u8(105), u8(110), u8(101), u8(116), u8(95), u8(110), u8(116), u8(111), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 265).
@rodata
final List<u8> elfStrSendmsg = const [
  u8(115), u8(101), u8(110), u8(100), u8(109), u8(115), u8(103), u8(0),
];
/// ADR-0180 expanded UND batch (face 266).
@rodata
final List<u8> elfStrRecvmsg = const [
  u8(114), u8(101), u8(99), u8(118), u8(109), u8(115), u8(103), u8(0),
];
/// ADR-0180 expanded UND batch (face 267).
@rodata
final List<u8> elfStrGaiStrerror = const [
  u8(103), u8(97), u8(105), u8(95), u8(115), u8(116), u8(114), u8(101), u8(114), u8(114), u8(111), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 268).
@rodata
final List<u8> elfStrGetifaddrs = const [
  u8(103), u8(101), u8(116), u8(105), u8(102), u8(97), u8(100), u8(100), u8(114), u8(115), u8(0),
];
/// ADR-0180 expanded UND batch (face 269).
@rodata
final List<u8> elfStrFreeifaddrs = const [
  u8(102), u8(114), u8(101), u8(101), u8(105), u8(102), u8(97), u8(100), u8(100), u8(114), u8(115), u8(0),
];
/// ADR-0180 expanded UND batch (face 270).
@rodata
final List<u8> elfStrMremap = const [
  u8(109), u8(114), u8(101), u8(109), u8(97), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 271).
@rodata
final List<u8> elfStrPpoll = const [
  u8(112), u8(112), u8(111), u8(108), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 272).
@rodata
final List<u8> elfStrOpenMemstream = const [
  u8(111), u8(112), u8(101), u8(110), u8(95), u8(109), u8(101), u8(109), u8(115), u8(116), u8(114), u8(101), u8(97), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 273).
@rodata
final List<u8> elfStrEpollCreate1 = const [
  u8(101), u8(112), u8(111), u8(108), u8(108), u8(95), u8(99), u8(114), u8(101), u8(97), u8(116), u8(101), u8(49), u8(0),
];
/// ADR-0180 expanded UND batch (face 274).
@rodata
final List<u8> elfStrEpollCreate = const [
  u8(101), u8(112), u8(111), u8(108), u8(108), u8(95), u8(99), u8(114), u8(101), u8(97), u8(116), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 275).
@rodata
final List<u8> elfStrEpollCtl = const [
  u8(101), u8(112), u8(111), u8(108), u8(108), u8(95), u8(99), u8(116), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 276).
@rodata
final List<u8> elfStrEpollWait = const [
  u8(101), u8(112), u8(111), u8(108), u8(108), u8(95), u8(119), u8(97), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 277).
@rodata
final List<u8> elfStrMsync = const [
  u8(109), u8(115), u8(121), u8(110), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 278).
@rodata
final List<u8> elfStrPosixFallocate64 = const [
  u8(112), u8(111), u8(115), u8(105), u8(120), u8(95), u8(102), u8(97), u8(108), u8(108), u8(111), u8(99), u8(97), u8(116), u8(101), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 279).
@rodata
final List<u8> elfStrPosixFadvise64 = const [
  u8(112), u8(111), u8(115), u8(105), u8(120), u8(95), u8(102), u8(97), u8(100), u8(118), u8(105), u8(115), u8(101), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 280).
@rodata
final List<u8> elfStrFallocate64 = const [
  u8(102), u8(97), u8(108), u8(108), u8(111), u8(99), u8(97), u8(116), u8(101), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 281).
@rodata
final List<u8> elfStrSendfile64 = const [
  u8(115), u8(101), u8(110), u8(100), u8(102), u8(105), u8(108), u8(101), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 282).
@rodata
final List<u8> elfStrFdatasync = const [
  u8(102), u8(100), u8(97), u8(116), u8(97), u8(115), u8(121), u8(110), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 283).
@rodata
final List<u8> elfStrUtimensat = const [
  u8(117), u8(116), u8(105), u8(109), u8(101), u8(110), u8(115), u8(97), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 284).
@rodata
final List<u8> elfStrFutimens = const [
  u8(102), u8(117), u8(116), u8(105), u8(109), u8(101), u8(110), u8(115), u8(0),
];
/// ADR-0180 expanded UND batch (face 285).
@rodata
final List<u8> elfStrGetrlimit64 = const [
  u8(103), u8(101), u8(116), u8(114), u8(108), u8(105), u8(109), u8(105), u8(116), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 286).
@rodata
final List<u8> elfStrSetrlimit64 = const [
  u8(115), u8(101), u8(116), u8(114), u8(108), u8(105), u8(109), u8(105), u8(116), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 287).
@rodata
final List<u8> elfStrInotifyInit = const [
  u8(105), u8(110), u8(111), u8(116), u8(105), u8(102), u8(121), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 288).
@rodata
final List<u8> elfStrInotifyAddWatch = const [
  u8(105), u8(110), u8(111), u8(116), u8(105), u8(102), u8(121), u8(95), u8(97), u8(100), u8(100), u8(95), u8(119), u8(97), u8(116), u8(99), u8(104), u8(0),
];
/// ADR-0180 expanded UND batch (face 289).
@rodata
final List<u8> elfStrInotifyRmWatch = const [
  u8(105), u8(110), u8(111), u8(116), u8(105), u8(102), u8(121), u8(95), u8(114), u8(109), u8(95), u8(119), u8(97), u8(116), u8(99), u8(104), u8(0),
];
/// ADR-0180 expanded UND batch (face 290).
@rodata
final List<u8> elfStrTcflush = const [
  u8(116), u8(99), u8(102), u8(108), u8(117), u8(115), u8(104), u8(0),
];
/// ADR-0180 expanded UND batch (face 291).
@rodata
final List<u8> elfStrTcdrain = const [
  u8(116), u8(99), u8(100), u8(114), u8(97), u8(105), u8(110), u8(0),
];
/// ADR-0180 expanded UND batch (face 292).
@rodata
final List<u8> elfStrSyscall = const [
  u8(115), u8(121), u8(115), u8(99), u8(97), u8(108), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 293).
@rodata
final List<u8> elfStrRemove = const [
  u8(114), u8(101), u8(109), u8(111), u8(118), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 294).
@rodata
final List<u8> elfStrPathconf = const [
  u8(112), u8(97), u8(116), u8(104), u8(99), u8(111), u8(110), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 295).
@rodata
final List<u8> elfStrFsync = const [
  u8(102), u8(115), u8(121), u8(110), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 296).
@rodata
final List<u8> elfStrLink = const [
  u8(108), u8(105), u8(110), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 297).
@rodata
final List<u8> elfStrSymlink = const [
  u8(115), u8(121), u8(109), u8(108), u8(105), u8(110), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 298).
@rodata
final List<u8> elfStrUnlinkat = const [
  u8(117), u8(110), u8(108), u8(105), u8(110), u8(107), u8(97), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 299).
@rodata
final List<u8> elfStrGetcwd = const [
  u8(103), u8(101), u8(116), u8(99), u8(119), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 300).
@rodata
final List<u8> elfStrRealpath = const [
  u8(114), u8(101), u8(97), u8(108), u8(112), u8(97), u8(116), u8(104), u8(0),
];
/// ADR-0180 expanded UND batch (face 301).
@rodata
final List<u8> elfStrGettimeofday = const [
  u8(103), u8(101), u8(116), u8(116), u8(105), u8(109), u8(101), u8(111), u8(102), u8(100), u8(97), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 302).
@rodata
final List<u8> elfStrDifftime = const [
  u8(100), u8(105), u8(102), u8(102), u8(116), u8(105), u8(109), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 303).
@rodata
final List<u8> elfStrTimegm = const [
  u8(116), u8(105), u8(109), u8(101), u8(103), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 304).
@rodata
final List<u8> elfStrWcstol = const [
  u8(119), u8(99), u8(115), u8(116), u8(111), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 305).
@rodata
final List<u8> elfStrSwprintf = const [
  u8(115), u8(119), u8(112), u8(114), u8(105), u8(110), u8(116), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 306).
@rodata
final List<u8> elfStrVswprintf = const [
  u8(118), u8(115), u8(119), u8(112), u8(114), u8(105), u8(110), u8(116), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 307).
@rodata
final List<u8> elfStrVasprintf = const [
  u8(118), u8(97), u8(115), u8(112), u8(114), u8(105), u8(110), u8(116), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 308).
@rodata
final List<u8> elfStrFmod = const [
  u8(102), u8(109), u8(111), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 309).
@rodata
final List<u8> elfStrLog1pf = const [
  u8(108), u8(111), u8(103), u8(49), u8(112), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 310).
@rodata
final List<u8> elfStrLround = const [
  u8(108), u8(114), u8(111), u8(117), u8(110), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 311).
@rodata
final List<u8> elfStrLroundf = const [
  u8(108), u8(114), u8(111), u8(117), u8(110), u8(100), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 312).
@rodata
final List<u8> elfStrLlround = const [
  u8(108), u8(108), u8(114), u8(111), u8(117), u8(110), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 313).
@rodata
final List<u8> elfStrLlroundf = const [
  u8(108), u8(108), u8(114), u8(111), u8(117), u8(110), u8(100), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 314).
@rodata
final List<u8> elfStrGetoptLong = const [
  u8(103), u8(101), u8(116), u8(111), u8(112), u8(116), u8(95), u8(108), u8(111), u8(110), u8(103), u8(0),
];
/// ADR-0180 expanded UND batch (face 315).
@rodata
final List<u8> elfStrWaitpid = const [
  u8(119), u8(97), u8(105), u8(116), u8(112), u8(105), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 316).
@rodata
final List<u8> elfStrWaitid = const [
  u8(119), u8(97), u8(105), u8(116), u8(105), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 317).
@rodata
final List<u8> elfStrPipe2 = const [
  u8(112), u8(105), u8(112), u8(101), u8(50), u8(0),
];
/// ADR-0180 expanded UND batch (face 318).
@rodata
final List<u8> elfStrFlock = const [
  u8(102), u8(108), u8(111), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 319).
@rodata
final List<u8> elfStrLchown = const [
  u8(108), u8(99), u8(104), u8(111), u8(119), u8(110), u8(0),
];
/// ADR-0180 expanded UND batch (face 320).
@rodata
final List<u8> elfStrUmask = const [
  u8(117), u8(109), u8(97), u8(115), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 321).
@rodata
final List<u8> elfStrMincore = const [
  u8(109), u8(105), u8(110), u8(99), u8(111), u8(114), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 322).
@rodata
final List<u8> elfStrDirfd = const [
  u8(100), u8(105), u8(114), u8(102), u8(100), u8(0),
];
/// ADR-0180 expanded UND batch (face 323).
@rodata
final List<u8> elfStrOpenlog = const [
  u8(111), u8(112), u8(101), u8(110), u8(108), u8(111), u8(103), u8(0),
];
/// ADR-0180 expanded UND batch (face 324).
@rodata
final List<u8> elfStrSyslog = const [
  u8(115), u8(121), u8(115), u8(108), u8(111), u8(103), u8(0),
];
/// ADR-0180 expanded UND batch (face 325).
@rodata
final List<u8> elfStrCloselog = const [
  u8(99), u8(108), u8(111), u8(115), u8(101), u8(108), u8(111), u8(103), u8(0),
];
/// ADR-0180 expanded UND batch (face 326).
@rodata
final List<u8> elfStrStatvfs64 = const [
  u8(115), u8(116), u8(97), u8(116), u8(118), u8(102), u8(115), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 327).
@rodata
final List<u8> elfStrStatfs64 = const [
  u8(115), u8(116), u8(97), u8(116), u8(102), u8(115), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 328).
@rodata
final List<u8> elfStrFstatfs64 = const [
  u8(102), u8(115), u8(116), u8(97), u8(116), u8(102), u8(115), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 329).
@rodata
final List<u8> elfStrFnmatch = const [
  u8(102), u8(110), u8(109), u8(97), u8(116), u8(99), u8(104), u8(0),
];
/// ADR-0180 expanded UND batch (face 330).
@rodata
final List<u8> elfStrCreat64 = const [
  u8(99), u8(114), u8(101), u8(97), u8(116), u8(54), u8(52), u8(0),
];
/// ADR-0180 expanded UND batch (face 331).
@rodata
final List<u8> elfStrFdopendir = const [
  u8(102), u8(100), u8(111), u8(112), u8(101), u8(110), u8(100), u8(105), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 332).
@rodata
final List<u8> elfStrWcrtomb = const [
  u8(119), u8(99), u8(114), u8(116), u8(111), u8(109), u8(98), u8(0),
];
/// ADR-0180 expanded UND batch (face 333).
@rodata
final List<u8> elfStrMbrtowc = const [
  u8(109), u8(98), u8(114), u8(116), u8(111), u8(119), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 334).
@rodata
final List<u8> elfStrWcsftime = const [
  u8(119), u8(99), u8(115), u8(102), u8(116), u8(105), u8(109), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 335).
@rodata
final List<u8> elfStrStrndup = const [
  u8(115), u8(116), u8(114), u8(110), u8(100), u8(117), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 336).
@rodata
final List<u8> elfStrRandR = const [
  u8(114), u8(97), u8(110), u8(100), u8(95), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 337).
@rodata
final List<u8> elfStrInitstateR = const [
  u8(105), u8(110), u8(105), u8(116), u8(115), u8(116), u8(97), u8(116), u8(101), u8(95), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 338).
@rodata
final List<u8> elfStrRandomR = const [
  u8(114), u8(97), u8(110), u8(100), u8(111), u8(109), u8(95), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 339).
@rodata
final List<u8> elfStrLongjmp = const [
  u8(108), u8(111), u8(110), u8(103), u8(106), u8(109), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 340).
@rodata
final List<u8> elfStrUSetjmp = const [
  u8(95), u8(115), u8(101), u8(116), u8(106), u8(109), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 341).
@rodata
final List<u8> elfStrPthreadSelf = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(115), u8(101), u8(108), u8(102), u8(0),
];
/// ADR-0180 expanded UND batch (face 342).
@rodata
final List<u8> elfStrPthreadOnce = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(111), u8(110), u8(99), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 343).
@rodata
final List<u8> elfStrPthreadMutexInit = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 344).
@rodata
final List<u8> elfStrPthreadMutexLock = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(95), u8(108), u8(111), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 345).
@rodata
final List<u8> elfStrPthreadMutexUnlock = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(95), u8(117), u8(110), u8(108), u8(111), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 346).
@rodata
final List<u8> elfStrPthreadMutexDestroy = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(95), u8(100), u8(101), u8(115), u8(116), u8(114), u8(111), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 347).
@rodata
final List<u8> elfStrPthreadMutexTrylock = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(95), u8(116), u8(114), u8(121), u8(108), u8(111), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 348).
@rodata
final List<u8> elfStrPthreadMutexattrInit = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(97), u8(116), u8(116), u8(114), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 349).
@rodata
final List<u8> elfStrPthreadMutexattrDestroy = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(109), u8(117), u8(116), u8(101), u8(120), u8(97), u8(116), u8(116), u8(114), u8(95), u8(100), u8(101), u8(115), u8(116), u8(114), u8(111), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 350).
@rodata
final List<u8> elfStrPthreadCondInit = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 351).
@rodata
final List<u8> elfStrPthreadCondWait = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(95), u8(119), u8(97), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 352).
@rodata
final List<u8> elfStrPthreadCondTimedwait = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(95), u8(116), u8(105), u8(109), u8(101), u8(100), u8(119), u8(97), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 353).
@rodata
final List<u8> elfStrPthreadCondSignal = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(95), u8(115), u8(105), u8(103), u8(110), u8(97), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 354).
@rodata
final List<u8> elfStrPthreadCondBroadcast = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(95), u8(98), u8(114), u8(111), u8(97), u8(100), u8(99), u8(97), u8(115), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 355).
@rodata
final List<u8> elfStrPthreadCondDestroy = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(95), u8(100), u8(101), u8(115), u8(116), u8(114), u8(111), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 356).
@rodata
final List<u8> elfStrPthreadCondattrInit = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(97), u8(116), u8(116), u8(114), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 357).
@rodata
final List<u8> elfStrPthreadCondattrSetclock = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(97), u8(116), u8(116), u8(114), u8(95), u8(115), u8(101), u8(116), u8(99), u8(108), u8(111), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 358).
@rodata
final List<u8> elfStrPthreadCondattrDestroy = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(111), u8(110), u8(100), u8(97), u8(116), u8(116), u8(114), u8(95), u8(100), u8(101), u8(115), u8(116), u8(114), u8(111), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 359).
@rodata
final List<u8> elfStrPthreadKeyCreate = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(107), u8(101), u8(121), u8(95), u8(99), u8(114), u8(101), u8(97), u8(116), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 360).
@rodata
final List<u8> elfStrPthreadKeyDelete = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(107), u8(101), u8(121), u8(95), u8(100), u8(101), u8(108), u8(101), u8(116), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 361).
@rodata
final List<u8> elfStrPthreadGetspecific = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(103), u8(101), u8(116), u8(115), u8(112), u8(101), u8(99), u8(105), u8(102), u8(105), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 362).
@rodata
final List<u8> elfStrPthreadSetspecific = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(115), u8(101), u8(116), u8(115), u8(112), u8(101), u8(99), u8(105), u8(102), u8(105), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 363).
@rodata
final List<u8> elfStrPthreadAttrInit = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(116), u8(114), u8(95), u8(105), u8(110), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 364).
@rodata
final List<u8> elfStrPthreadAttrDestroy = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(116), u8(114), u8(95), u8(100), u8(101), u8(115), u8(116), u8(114), u8(111), u8(121), u8(0),
];
/// ADR-0180 expanded UND batch (face 365).
@rodata
final List<u8> elfStrPthreadAttrSetstacksize = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(116), u8(114), u8(95), u8(115), u8(101), u8(116), u8(115), u8(116), u8(97), u8(99), u8(107), u8(115), u8(105), u8(122), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 366).
@rodata
final List<u8> elfStrPthreadAttrSetdetachstate = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(116), u8(114), u8(95), u8(115), u8(101), u8(116), u8(100), u8(101), u8(116), u8(97), u8(99), u8(104), u8(115), u8(116), u8(97), u8(116), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 367).
@rodata
final List<u8> elfStrPthreadAttrGetstack = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(116), u8(114), u8(95), u8(103), u8(101), u8(116), u8(115), u8(116), u8(97), u8(99), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 368).
@rodata
final List<u8> elfStrPthreadAttrGetstacksize = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(116), u8(114), u8(95), u8(103), u8(101), u8(116), u8(115), u8(116), u8(97), u8(99), u8(107), u8(115), u8(105), u8(122), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 369).
@rodata
final List<u8> elfStrPthreadCreate = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(99), u8(114), u8(101), u8(97), u8(116), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 370).
@rodata
final List<u8> elfStrPthreadJoin = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(106), u8(111), u8(105), u8(110), u8(0),
];
/// ADR-0180 expanded UND batch (face 371).
@rodata
final List<u8> elfStrPthreadDetach = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(100), u8(101), u8(116), u8(97), u8(99), u8(104), u8(0),
];
/// ADR-0180 expanded UND batch (face 372).
@rodata
final List<u8> elfStrPthreadSigmask = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(115), u8(105), u8(103), u8(109), u8(97), u8(115), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 373).
@rodata
final List<u8> elfStrPthreadGetschedparam = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(103), u8(101), u8(116), u8(115), u8(99), u8(104), u8(101), u8(100), u8(112), u8(97), u8(114), u8(97), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 374).
@rodata
final List<u8> elfStrPthreadSetnameNp = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(115), u8(101), u8(116), u8(110), u8(97), u8(109), u8(101), u8(95), u8(110), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 375).
@rodata
final List<u8> elfStrPthreadGetnameNp = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(103), u8(101), u8(116), u8(110), u8(97), u8(109), u8(101), u8(95), u8(110), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 376).
@rodata
final List<u8> elfStrPthreadKill = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(107), u8(105), u8(108), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 377).
@rodata
final List<u8> elfStrPthreadGetattrNp = const [
  u8(112), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(103), u8(101), u8(116), u8(97), u8(116), u8(116), u8(114), u8(95), u8(110), u8(112), u8(0),
];
/// ADR-0180 expanded UND batch (face 378).
@rodata
final List<u8> elfStrPkeyMprotect = const [
  u8(112), u8(107), u8(101), u8(121), u8(95), u8(109), u8(112), u8(114), u8(111), u8(116), u8(101), u8(99), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 379).
@rodata
final List<u8> elfStrPkeyAlloc = const [
  u8(112), u8(107), u8(101), u8(121), u8(95), u8(97), u8(108), u8(108), u8(111), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 380).
@rodata
final List<u8> elfStrPkeySet = const [
  u8(112), u8(107), u8(101), u8(121), u8(95), u8(115), u8(101), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 381).
@rodata
final List<u8> elfStrXCxaFinalize = const [
  u8(95), u8(95), u8(99), u8(120), u8(97), u8(95), u8(102), u8(105), u8(110), u8(97), u8(108), u8(105), u8(122), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 382).
@rodata
final List<u8> elfStrXCxaAtexit = const [
  u8(95), u8(95), u8(99), u8(120), u8(97), u8(95), u8(97), u8(116), u8(101), u8(120), u8(105), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 383).
@rodata
final List<u8> elfStrXErrnoLocation = const [
  u8(95), u8(95), u8(101), u8(114), u8(114), u8(110), u8(111), u8(95), u8(108), u8(111), u8(99), u8(97), u8(116), u8(105), u8(111), u8(110), u8(0),
];
/// ADR-0180 expanded UND batch (face 384).
@rodata
final List<u8> elfStrXCtypeBLoc = const [
  u8(95), u8(95), u8(99), u8(116), u8(121), u8(112), u8(101), u8(95), u8(98), u8(95), u8(108), u8(111), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 385).
@rodata
final List<u8> elfStrXCtypeTolowerLoc = const [
  u8(95), u8(95), u8(99), u8(116), u8(121), u8(112), u8(101), u8(95), u8(116), u8(111), u8(108), u8(111), u8(119), u8(101), u8(114), u8(95), u8(108), u8(111), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 386).
@rodata
final List<u8> elfStrXCtypeToupperLoc = const [
  u8(95), u8(95), u8(99), u8(116), u8(121), u8(112), u8(101), u8(95), u8(116), u8(111), u8(117), u8(112), u8(112), u8(101), u8(114), u8(95), u8(108), u8(111), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 387).
@rodata
final List<u8> elfStrXXpgStrerrorR = const [
  u8(95), u8(95), u8(120), u8(112), u8(103), u8(95), u8(115), u8(116), u8(114), u8(101), u8(114), u8(114), u8(111), u8(114), u8(95), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 388).
@rodata
final List<u8> elfStrXCtypeGetMbCurMax = const [
  u8(95), u8(95), u8(99), u8(116), u8(121), u8(112), u8(101), u8(95), u8(103), u8(101), u8(116), u8(95), u8(109), u8(98), u8(95), u8(99), u8(117), u8(114), u8(95), u8(109), u8(97), u8(120), u8(0),
];
/// ADR-0180 expanded UND batch (face 389).
@rodata
final List<u8> elfStrXCxaThreadAtexitImpl = const [
  u8(95), u8(95), u8(99), u8(120), u8(97), u8(95), u8(116), u8(104), u8(114), u8(101), u8(97), u8(100), u8(95), u8(97), u8(116), u8(101), u8(120), u8(105), u8(116), u8(95), u8(105), u8(109), u8(112), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 390).
@rodata
final List<u8> elfStrXGetdelim = const [
  u8(95), u8(95), u8(103), u8(101), u8(116), u8(100), u8(101), u8(108), u8(105), u8(109), u8(0),
];
/// ADR-0180 expanded UND batch (face 391).
@rodata
final List<u8> elfStrXLongjmpChk = const [
  u8(95), u8(95), u8(108), u8(111), u8(110), u8(103), u8(106), u8(109), u8(112), u8(95), u8(99), u8(104), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 392).
@rodata
final List<u8> elfStrXMbrlen = const [
  u8(95), u8(95), u8(109), u8(98), u8(114), u8(108), u8(101), u8(110), u8(0),
];
/// ADR-0180 expanded UND batch (face 393).
@rodata
final List<u8> elfStrXRegisterAtfork = const [
  u8(95), u8(95), u8(114), u8(101), u8(103), u8(105), u8(115), u8(116), u8(101), u8(114), u8(95), u8(97), u8(116), u8(102), u8(111), u8(114), u8(107), u8(0),
];
/// ADR-0180 expanded UND batch (face 394).
@rodata
final List<u8> elfStrXSchedCpualloc = const [
  u8(95), u8(95), u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(99), u8(112), u8(117), u8(97), u8(108), u8(108), u8(111), u8(99), u8(0),
];
/// ADR-0180 expanded UND batch (face 395).
@rodata
final List<u8> elfStrXSchedCpucount = const [
  u8(95), u8(95), u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(99), u8(112), u8(117), u8(99), u8(111), u8(117), u8(110), u8(116), u8(0),
];
/// ADR-0180 expanded UND batch (face 396).
@rodata
final List<u8> elfStrXSchedCpufree = const [
  u8(95), u8(95), u8(115), u8(99), u8(104), u8(101), u8(100), u8(95), u8(99), u8(112), u8(117), u8(102), u8(114), u8(101), u8(101), u8(0),
];
/// ADR-0180 expanded UND batch (face 397).
@rodata
final List<u8> elfStrXStackChkFail = const [
  u8(95), u8(95), u8(115), u8(116), u8(97), u8(99), u8(107), u8(95), u8(99), u8(104), u8(107), u8(95), u8(102), u8(97), u8(105), u8(108), u8(0),
];
/// ADR-0180 expanded UND batch (face 398).
@rodata
final List<u8> elfStrXTlsGetAddr = const [
  u8(95), u8(95), u8(116), u8(108), u8(115), u8(95), u8(103), u8(101), u8(116), u8(95), u8(97), u8(100), u8(100), u8(114), u8(0),
];
/// ADR-0180 expanded UND batch (face 399).
@rodata
final List<u8> elfStrXUdivti3 = const [
  u8(95), u8(95), u8(117), u8(100), u8(105), u8(118), u8(116), u8(105), u8(51), u8(0),
];

/// `'need_fn'` plus NUL -- 8 bytes. ADR-0157 resolves this face from
/// our tiny FAT second `DT_NEEDED` (e.g. `LIBM.SO`). Not libm.so.6.
@rodata
final List<u8> elfStrNeedFn = const [
  u8(0x6E), u8(0x65), u8(0x65), u8(0x64), u8(0x5F), u8(0x66),
  u8(0x6E), u8(0x00),
];

/// `'dl_fn'` plus NUL -- 6 bytes. ADR-0160 resolves this face from
/// our tiny FAT third `DT_NEEDED` (`LIBDL.SO`). ADR-0174 maps the
/// real Linux soname `libdl.so.2` onto this face via planted
/// `SOMAP.TXT` (FAT cannot store that string as 8.3).
@rodata
final List<u8> elfStrDlFn = const [
  u8(0x64), u8(0x6C), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'pt_fn'` plus NUL -- 6 bytes. ADR-0160 resolves this face from
/// our tiny FAT fourth `DT_NEEDED` (`LIBPT.SO`). Not libpthread.
@rodata
final List<u8> elfStrPtFn = const [
  u8(0x70), u8(0x74), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'gb_fn'` plus NUL -- 6 bytes. ADR-0162 resolves this face from
/// our tiny FAT fifth `DT_NEEDED` (`LIBGB.SO`). Not libglib.
@rodata
final List<u8> elfStrGbFn = const [
  u8(0x67), u8(0x62), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'go_fn'` plus NUL -- 6 bytes. ADR-0162 resolves this face from
/// our tiny FAT sixth `DT_NEEDED` (`LIBGO.SO`). Not libgobject.
@rodata
final List<u8> elfStrGoFn = const [
  u8(0x67), u8(0x6F), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'np_fn'` plus NUL -- 6 bytes. ADR-0162 resolves this face from
/// our tiny FAT seventh `DT_NEEDED` (`LIBNP.SO`). Not libnspr4.
@rodata
final List<u8> elfStrNpFn = const [
  u8(0x6E), u8(0x70), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ns_fn'` plus NUL -- 6 bytes. ADR-0162 resolves this face from
/// our tiny FAT eighth `DT_NEEDED` (`LIBNS.SO`). Not libnss3.
@rodata
final List<u8> elfStrNsFn = const [
  u8(0x6E), u8(0x73), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'nu_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT ninth `DT_NEEDED` (`LIBNU.SO`). Not libnssutil3.
@rodata
final List<u8> elfStrNuFn = const [
  u8(0x6E), u8(0x75), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'sm_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT tenth `DT_NEEDED` (`LIBSM.SO`). Not libsmime3.
@rodata
final List<u8> elfStrSmFn = const [
  u8(0x73), u8(0x6D), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'db_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT eleventh `DT_NEEDED` (`LIBDB.SO`). Not libdbus.
@rodata
final List<u8> elfStrDbFn = const [
  u8(0x64), u8(0x62), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'gi_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT twelfth `DT_NEEDED` (`LIBGI.SO`). Not libgio.
@rodata
final List<u8> elfStrGiFn = const [
  u8(0x67), u8(0x69), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'at_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT thirteenth `DT_NEEDED` (`LIBAT.SO`). Not libatk.
@rodata
final List<u8> elfStrAtFn = const [
  u8(0x61), u8(0x74), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ab_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT fourteenth `DT_NEEDED` (`LIBAB.SO`). Not atk-bridge.
@rodata
final List<u8> elfStrAbFn = const [
  u8(0x61), u8(0x62), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'cu_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT fifteenth `DT_NEEDED` (`LIBCU.SO`). Not libcups.
@rodata
final List<u8> elfStrCuFn = const [
  u8(0x63), u8(0x75), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'x1_fn'` plus NUL -- 6 bytes. ADR-0163 resolves this face from
/// our tiny FAT sixteenth `DT_NEEDED` (`LIBX1.SO`). Not libX11.
@rodata
final List<u8> elfStrX1Fn = const [
  u8(0x78), u8(0x31), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xc_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT seventeenth `DT_NEEDED` (`LIBXC.SO`). Not libXcomposite.
@rodata
final List<u8> elfStrXcFn = const [
  u8(0x78), u8(0x63), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xd_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT eighteenth `DT_NEEDED` (`LIBXD.SO`). Not libXdamage.
@rodata
final List<u8> elfStrXdFn = const [
  u8(0x78), u8(0x64), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xe_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT nineteenth `DT_NEEDED` (`LIBXE.SO`). Not libXext.
@rodata
final List<u8> elfStrXeFn = const [
  u8(0x78), u8(0x65), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xf_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twentieth `DT_NEEDED` (`LIBXF.SO`). Not libXfixes.
@rodata
final List<u8> elfStrXfFn = const [
  u8(0x78), u8(0x66), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xr_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-first `DT_NEEDED` (`LIBXR.SO`). Not libXrandr.
@rodata
final List<u8> elfStrXrFn = const [
  u8(0x78), u8(0x72), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'gm_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-second `DT_NEEDED` (`LIBGM.SO`). Not libgbm.
@rodata
final List<u8> elfStrGmFn = const [
  u8(0x67), u8(0x6D), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ex_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-third `DT_NEEDED` (`LIBEX.SO`). Not libexpat.
@rodata
final List<u8> elfStrExFn = const [
  u8(0x65), u8(0x78), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xb_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-fourth `DT_NEEDED` (`LIBXB.SO`). Not libxcb.
@rodata
final List<u8> elfStrXbFn = const [
  u8(0x78), u8(0x62), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'xk_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-fifth `DT_NEEDED` (`LIBXK.SO`). Not libxkbcommon.
@rodata
final List<u8> elfStrXkFn = const [
  u8(0x78), u8(0x6B), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ca_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-sixth `DT_NEEDED` (`LIBCA.SO`). Not libcairo.
@rodata
final List<u8> elfStrCaFn = const [
  u8(0x63), u8(0x61), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'pg_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-seventh `DT_NEEDED` (`LIBPG.SO`). Not libpango.
@rodata
final List<u8> elfStrPgFn = const [
  u8(0x70), u8(0x67), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ud_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-eighth `DT_NEEDED` (`LIBUD.SO`). Not libudev.
@rodata
final List<u8> elfStrUdFn = const [
  u8(0x75), u8(0x64), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'as_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT twenty-ninth `DT_NEEDED` (`LIBAS.SO`). Not libasound.
@rodata
final List<u8> elfStrAsFn = const [
  u8(0x61), u8(0x73), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ap_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT thirtieth `DT_NEEDED` (`LIBAP.SO`). Not libatspi.
@rodata
final List<u8> elfStrApFn = const [
  u8(0x61), u8(0x70), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'gc_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT thirty-first `DT_NEEDED` (`LIBGC.SO`). Not libgcc_s.
@rodata
final List<u8> elfStrGcFn = const [
  u8(0x67), u8(0x63), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'ld_fn'` plus NUL -- 6 bytes. ADR-0165 resolves this face from
/// our tiny FAT thirty-second `DT_NEEDED` (`LIBLD.SO`). Not ld-linux.
@rodata
final List<u8> elfStrLdFn = const [
  u8(0x6C), u8(0x64), u8(0x5F), u8(0x66), u8(0x6E), u8(0x00),
];

/// `'cef_initialize'` plus NUL -- 15 bytes. ADR-0167 resolves this
/// face from the measured official `CEF.SO` slice (bytes from
/// linux64 `libcef.so`). Not a handwritten stub. Not OnPaint.
@rodata
final List<u8> elfStrCefInit = const [
  u8(0x63), u8(0x65), u8(0x66), u8(0x5F), u8(0x69), u8(0x6E),
  u8(0x69), u8(0x74), u8(0x69), u8(0x61), u8(0x6C), u8(0x69),
  u8(0x7A), u8(0x65), u8(0x00),
];

/// `'CEF LOAD RO '` -- 12 bytes. ADR-0168 prints official RO filesz.
@rodata
final List<u8> elfStrCefLoadRo = const [
  u8(0x43), u8(0x45), u8(0x46), u8(0x20), u8(0x4C), u8(0x4F),
  u8(0x41), u8(0x44), u8(0x20), u8(0x52), u8(0x4F), u8(0x20),
];

/// `' RX '` -- 4 bytes.
@rodata
final List<u8> elfStrCefLoadRx = const [
  u8(0x20), u8(0x52), u8(0x58), u8(0x20),
];

/// `'CEF PLT MEMSET '` -- 15 bytes. ADR-0169: official PLT bound.
@rodata
final List<u8> elfStrCefPltMemset = const [
  u8(0x43), u8(0x45), u8(0x46), u8(0x20), u8(0x50), u8(0x4C),
  u8(0x54), u8(0x20), u8(0x4D), u8(0x45), u8(0x4D), u8(0x53),
  u8(0x45), u8(0x54), u8(0x20),
];

/// `'CEF UND BATCH '` -- 14 bytes. ADR-0170: high-traffic UND count.
@rodata
final List<u8> elfStrCefUndBatch = const [
  u8(0x43), u8(0x45), u8(0x46), u8(0x20), u8(0x55), u8(0x4E),
  u8(0x44), u8(0x20), u8(0x42), u8(0x41), u8(0x54), u8(0x43),
  u8(0x48), u8(0x20),
];

/// `'LIBC.SO'` -- 7 bytes. ADR-0169 opens this face during CEF plant map.
@rodata
final List<u8> elfStrLibcSo = const [
  u8(0x4C), u8(0x49), u8(0x42), u8(0x43), u8(0x2E), u8(0x53),
  u8(0x4F),
];

/// `'SOMAP.TXT'` -- 9 bytes. ADR-0174 planted Linux-soname → FAT 8.3 map.
@rodata
final List<u8> elfStrSomapTxt = const [
  u8(0x53), u8(0x4F), u8(0x4D), u8(0x41), u8(0x50), u8(0x2E),
  u8(0x54), u8(0x58), u8(0x54),
];

/// `'PROC DLOPEN ALIAS '` -- 18 bytes. ADR-0174: non-8.3 soname resolved.
@rodata
final List<u8> elfStrDlopenAlias = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x44),
  u8(0x4C), u8(0x4F), u8(0x50), u8(0x45), u8(0x4E), u8(0x20),
  u8(0x41), u8(0x4C), u8(0x49), u8(0x41), u8(0x53), u8(0x20),
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

/// Line label. ADR-0126: the interp path after a named platform `PT_INTERP`.
///
/// `'ELF INTERP '` -- 11 bytes.
@rodata
final List<u8> elfStrInterp = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x49), u8(0x4E), u8(0x54), u8(0x45), u8(0x52),
  u8(0x50), u8(0x20),
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
/// do on the spawn path; it is refused by [elfCheckHeader] rather than
/// loaded at the wrong address. ADR-0144 maps a named platform
/// `dlopen` of our own tiny ET_DYN through [elfSysDlopen], not here.
const int elfOffType = 16;
const int elfTypeExec = 2;
const int elfTypeDyn = 3;

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
/// dynamic linker". `PT_INTERP` and `PT_DYNAMIC` are refused unless
/// [elfInterpPermit] says this is a named platform spawn (ADR-0126 / ADR-0127).
const int elfPtLoad = 1;
const int elfPtDynamic = 2;
const int elfPtInterp = 3;

/// Byte offset in the header frame where [elfHonorInterp] parks the 11-byte
/// 8.3 name of the program it will reopen. Program headers live in the first
/// ~1 KiB of that frame; 2032 is past them for any file this loader accepts.
const int elfInterpNameSave = 2032;

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

/// Syscall 29 — `dlopen(namePtr, nameLen) -> va` for a named platform
/// process (ADR-0144 / ADR-0152 / ADR-0157 / ADR-0160 / ADR-0162 /
/// ADR-0163 / ADR-0165 / ADR-0167). Maps our FAT-resident tiny
/// ET_DYN and returns the VA of `write` (libc), `need_fn` (LIBM),
/// `dl_fn` (LIBDL), `pt_fn` (LIBPT), `gb_fn` (LIBGB), `go_fn`
/// (LIBGO), `np_fn` (LIBNP), `ns_fn` (LIBNS), `nu_fn` (LIBNU),
/// `sm_fn` (LIBSM), `db_fn` (LIBDB), `gi_fn` (LIBGI), `at_fn`
/// (LIBAT), `ab_fn` (LIBAB), `cu_fn` (LIBCU), `x1_fn` (LIBX1),
/// `xc_fn` (LIBXC), `xd_fn` (LIBXD), `xe_fn` (LIBXE), `xf_fn`
/// (LIBXF), `xr_fn` (LIBXR), `gm_fn` (LIBGM), `ex_fn` (LIBEX),
/// `xb_fn` (LIBXB), `xk_fn` (LIBXK), `ca_fn` (LIBCA), `pg_fn`
/// (LIBPG), `ud_fn` (LIBUD), `as_fn` (LIBAS), `ap_fn` (LIBAP),
/// `gc_fn` (LIBGC), `ld_fn` (LIBLD), `so_mark` (dl door), or
/// `cef_initialize` (ADR-0167 measured official `CEF.SO` slice).
/// Executable LOAD pages are remapped R+X so a call through those
/// faces does not #PF on NX. 11 stays `fdwait`. 21 and 22 stay
/// reserved. 26 is `spawn`, 27 is `mmap`, 28 is `clone`. ASK.ELF
/// of the same bytes with `PT_DYNAMIC` is still 11 (ADR-0127).
/// Missing file is [elfDlopenRetNotFound]. No `oslibc.h` name —
/// a libc `dlopen()` would be glibc's.
const int elfSysDlopenNo = 29;

/// Official linux64 libcef.so LOAD sizes (Spotify CEF 144.0.34).
/// ADR-0168 / cef-load/. The 12 KiB measured slice is not enough.
const int elfCefRoFilesz = 42593760;
const int elfCefRxFilesz = 189117488;
const int elfCefInitVaddr = 0x2CE7700;

/// Host-backed plant: first RO+RX file bytes of official libcef.so,
/// loaded by QEMU `-device loader` at this PA. 1.5 GiB full file cannot
/// sit on FAT (`fatChainMax` = 256 KiB). Alias-mapped, not copied.
const int elfCefPlantPa = 0x1000000;
const int elfCefPlantBytes = 231711248;

/// Official high-traffic `@plt` stub VAs / file offsets inside the
/// RO+RX plant (measured JUMP_SLOT order). ADR-0169 bound memset;
/// ADR-0170 bound five via trampolines; ADR-0171 grows the list to
/// twenty (extras optional when LIBC.SO lacks them so cef-plt /
/// cef-und keep PASSing with the five-face LIBC). Face slab sits on
/// unused PLT idx ≥ 511 (past strncat@plt). GOT stays unmapped —
/// unbound stubs still #PF on `jmp *GOT`. `malloc` is absent from
/// official libcef PLT (Chromium allocator) — not in this batch.
const int elfCefMemsetPltVaddr = 0xDCFB1E0;
const int elfCefMemsetPltOff = 0xDCFA1E0;
const int elfCefMemcpyPltVaddr = 0xDCFB030;
const int elfCefMemcpyPltOff = 0xDCFA030;
const int elfCefMemmovePltVaddr = 0xDCFB1F0;
const int elfCefMemmovePltOff = 0xDCFA1F0;
const int elfCefStrlenPltVaddr = 0xDCF5E20;
const int elfCefStrlenPltOff = 0xDCF4E20;
const int elfCefMemcmpPltVaddr = 0xDCF5E60;
const int elfCefMemcmpPltOff = 0xDCF4E60;
const int elfCefBcmpPltVaddr = 0xDCF5FA0;
const int elfCefBcmpPltOff = 0xDCF4FA0;
const int elfCefMemchrPltVaddr = 0xDCF6090;
const int elfCefMemchrPltOff = 0xDCF5090;
const int elfCefStrncmpPltVaddr = 0xDCF60D0;
const int elfCefStrncmpPltOff = 0xDCF50D0;
const int elfCefStrcpyPltVaddr = 0xDCF63A0;
const int elfCefStrcpyPltOff = 0xDCF53A0;
const int elfCefStrcmpPltVaddr = 0xDCF6450;
const int elfCefStrcmpPltOff = 0xDCF5450;
const int elfCefStrnlenPltVaddr = 0xDCF64A0;
const int elfCefStrnlenPltOff = 0xDCF54A0;
const int elfCefStrncpyPltVaddr = 0xDCF64B0;
const int elfCefStrncpyPltOff = 0xDCF54B0;
const int elfCefStrchrPltVaddr = 0xDCF66D0;
const int elfCefStrchrPltOff = 0xDCF56D0;
const int elfCefStrrchrPltVaddr = 0xDCF6960;
const int elfCefStrrchrPltOff = 0xDCF5960;
const int elfCefStrstrPltVaddr = 0xDCF6CA0;
const int elfCefStrstrPltOff = 0xDCF5CA0;
const int elfCefStrcatPltVaddr = 0xDCF7870;
const int elfCefStrcatPltOff = 0xDCF6870;
const int elfCefStrspnPltVaddr = 0xDCF6C80;
const int elfCefStrspnPltOff = 0xDCF5C80;
const int elfCefStrcspnPltVaddr = 0xDCF6C90;
const int elfCefStrcspnPltOff = 0xDCF5C90;
const int elfCefStrncatPltVaddr = 0xDCF7DC0;
const int elfCefStrncatPltOff = 0xDCF6DC0;
const int elfCefStrcasecmpPltVaddr = 0xDCF6530;
const int elfCefStrcasecmpPltOff = 0xDCF5530;
/// ADR-0172 faces 20..49 (PLT stubs outside the face slab).
const int elfCefStrncasecmpPltVaddr = 0xDCF7580;
const int elfCefStrncasecmpPltOff = 0xDCF6580;
const int elfCefWcsncmpPltVaddr = 0xDCF60C0;
const int elfCefWcsncmpPltOff = 0xDCF50C0;
const int elfCefWcslenPltVaddr = 0xDCF62B0;
const int elfCefWcslenPltOff = 0xDCF52B0;
const int elfCefWmemchrPltVaddr = 0xDCF62C0;
const int elfCefWmemchrPltOff = 0xDCF52C0;
const int elfCefWcscmpPltVaddr = 0xDCF7810;
const int elfCefWcscmpPltOff = 0xDCF6810;
const int elfCefWmemcmpPltVaddr = 0xDCF7820;
const int elfCefWmemcmpPltOff = 0xDCF6820;
const int elfCefWcschrPltVaddr = 0xDCF7880;
const int elfCefWcschrPltOff = 0xDCF6880;
const int elfCefIswdigitPltVaddr = 0xDCF77F0;
const int elfCefIswdigitPltOff = 0xDCF67F0;
const int elfCefIswalnumPltVaddr = 0xDCF78A0;
const int elfCefIswalnumPltOff = 0xDCF68A0;
const int elfCefWcspbrkPltVaddr = 0xDCFAA20;
const int elfCefWcspbrkPltOff = 0xDCF9A20;
const int elfCefWcscpyPltVaddr = 0xDCFAA30;
const int elfCefWcscpyPltOff = 0xDCF9A30;
const int elfCefTowupperPltVaddr = 0xDCFAA60;
const int elfCefTowupperPltOff = 0xDCF9A60;
const int elfCefTowlowerPltVaddr = 0xDCFAA70;
const int elfCefTowlowerPltOff = 0xDCF9A70;
const int elfCefStrtolPltVaddr = 0xDCF61D0;
const int elfCefStrtolPltOff = 0xDCF51D0;
const int elfCefStrtoulPltVaddr = 0xDCF6690;
const int elfCefStrtoulPltOff = 0xDCF5690;
const int elfCefStrtollPltVaddr = 0xDCF6410;
const int elfCefStrtollPltOff = 0xDCF5410;
const int elfCefStrtoullPltVaddr = 0xDCF6920;
const int elfCefStrtoullPltOff = 0xDCF5920;
const int elfCefSchedYieldPltVaddr = 0xDCF6390;
const int elfCefSchedYieldPltOff = 0xDCF5390;
const int elfCefGetpidPltVaddr = 0xDCF6190;
const int elfCefGetpidPltOff = 0xDCF5190;
const int elfCefGetpagesizePltVaddr = 0xDCF6470;
const int elfCefGetpagesizePltOff = 0xDCF5470;
const int elfCefNanfPltVaddr = 0xDCF6290;
const int elfCefNanfPltOff = 0xDCF5290;
const int elfCefNanPltVaddr = 0xDCF6280;
const int elfCefNanPltOff = 0xDCF5280;
const int elfCefGetenvPltVaddr = 0xDCF6440;
const int elfCefGetenvPltOff = 0xDCF5440;
const int elfCefGetauxvalPltVaddr = 0xDCF6480;
const int elfCefGetauxvalPltOff = 0xDCF5480;
const int elfCefTimePltVaddr = 0xDCF6520;
const int elfCefTimePltOff = 0xDCF5520;
const int elfCefUsleepPltVaddr = 0xDCF67C0;
const int elfCefUsleepPltOff = 0xDCF57C0;
const int elfCefGetuidPltVaddr = 0xDCF7680;
const int elfCefGetuidPltOff = 0xDCF6680;
const int elfCefIsattyPltVaddr = 0xDCF68D0;
const int elfCefIsattyPltOff = 0xDCF58D0;
const int elfCefRandPltVaddr = 0xDCF7650;
const int elfCefRandPltOff = 0xDCF6650;
const int elfCefGeteuidPltVaddr = 0xDCF66A0;
const int elfCefGeteuidPltOff = 0xDCF56A0;
/// ADR-0178 faces 50..99; ADR-0179 faces 100..199; ADR-0180 faces 200..399.
const int elfCefFloorfPltVaddr = 0xDCF6CB0;
const int elfCefFloorfPltOff = 0xDCF5CB0;
const int elfCefCeilfPltVaddr = 0xDCF7610;
const int elfCefCeilfPltOff = 0xDCF6610;
const int elfCefTruncfPltVaddr = 0xDCF7620;
const int elfCefTruncfPltOff = 0xDCF6620;
const int elfCefRoundfPltVaddr = 0xDCF6CC0;
const int elfCefRoundfPltOff = 0xDCF5CC0;
const int elfCefFloorPltVaddr = 0xDCFB070;
const int elfCefFloorPltOff = 0xDCFA070;
const int elfCefCeilPltVaddr = 0xDCFB0E0;
const int elfCefCeilPltOff = 0xDCFA0E0;
const int elfCefTruncPltVaddr = 0xDCFB110;
const int elfCefTruncPltOff = 0xDCFA110;
const int elfCefRoundPltVaddr = 0xDCFB060;
const int elfCefRoundPltOff = 0xDCFA060;
const int elfCefPutcharPltVaddr = 0xDCF78F0;
const int elfCefPutcharPltOff = 0xDCF68F0;
const int elfCefPutsPltVaddr = 0xDCF6130;
const int elfCefPutsPltOff = 0xDCF5130;
const int elfCefSrandPltVaddr = 0xDCF7640;
const int elfCefSrandPltOff = 0xDCF6640;
const int elfCefGetppidPltVaddr = 0xDCF68B0;
const int elfCefGetppidPltOff = 0xDCF58B0;
const int elfCefSleepPltVaddr = 0xDCFA490;
const int elfCefSleepPltOff = 0xDCF9490;
const int elfCefWritePltVaddr = 0xDCF65D0;
const int elfCefWritePltOff = 0xDCF55D0;
const int elfCefReadPltVaddr = 0xDCF61C0;
const int elfCefReadPltOff = 0xDCF51C0;
const int elfCefAbortPltVaddr = 0xDCF6250;
const int elfCefAbortPltOff = 0xDCF5250;
const int elfCefExitPltVaddr = 0xDCF6590;
const int elfCefExitPltOff = 0xDCF5590;
const int elfCefUExitPltVaddr = 0xDCF6560;
const int elfCefUExitPltOff = 0xDCF5560;
const int elfCefUnlinkPltVaddr = 0xDCF67A0;
const int elfCefUnlinkPltOff = 0xDCF57A0;
const int elfCefRenamePltVaddr = 0xDCF6170;
const int elfCefRenamePltOff = 0xDCF5170;
const int elfCefMkdirPltVaddr = 0xDCF6600;
const int elfCefMkdirPltOff = 0xDCF5600;
const int elfCefRmdirPltVaddr = 0xDCF6610;
const int elfCefRmdirPltOff = 0xDCF5610;
const int elfCefAccessPltVaddr = 0xDCF6620;
const int elfCefAccessPltOff = 0xDCF5620;
const int elfCefChmodPltVaddr = 0xDCF66B0;
const int elfCefChmodPltOff = 0xDCF56B0;
const int elfCefFilenoPltVaddr = 0xDCF65E0;
const int elfCefFilenoPltOff = 0xDCF55E0;
const int elfCefFeofPltVaddr = 0xDCF6010;
const int elfCefFeofPltOff = 0xDCF5010;
const int elfCefFerrorPltVaddr = 0xDCF62E0;
const int elfCefFerrorPltOff = 0xDCF52E0;
const int elfCefFflushPltVaddr = 0xDCF6030;
const int elfCefFflushPltOff = 0xDCF5030;
const int elfCefGethostnamePltVaddr = 0xDCF7660;
const int elfCefGethostnamePltOff = 0xDCF6660;
const int elfCefMunmapPltVaddr = 0xDCF63D0;
const int elfCefMunmapPltOff = 0xDCF53D0;
const int elfCefMprotectPltVaddr = 0xDCF66E0;
const int elfCefMprotectPltOff = 0xDCF56E0;
const int elfCefAlarmPltVaddr = 0xDCF6500;
const int elfCefAlarmPltOff = 0xDCF5500;
const int elfCefPausePltVaddr = 0xDCF7590;
const int elfCefPausePltOff = 0xDCF6590;
const int elfCefKillPltVaddr = 0xDCF6890;
const int elfCefKillPltOff = 0xDCF5890;
const int elfCefDupPltVaddr = 0xDCF68E0;
const int elfCefDupPltOff = 0xDCF58E0;
const int elfCefDup2PltVaddr = 0xDCF6840;
const int elfCefDup2PltOff = 0xDCF5840;
const int elfCefPipePltVaddr = 0xDCF6720;
const int elfCefPipePltOff = 0xDCF5720;
const int elfCefGetpriorityPltVaddr = 0xDCF6770;
const int elfCefGetpriorityPltOff = 0xDCF5770;
const int elfCefSetpriorityPltVaddr = 0xDCF6740;
const int elfCefSetpriorityPltOff = 0xDCF5740;
const int elfCefSinfPltVaddr = 0xDCFA4A0;
const int elfCefSinfPltOff = 0xDCF94A0;
const int elfCefCosfPltVaddr = 0xDCFA4B0;
const int elfCefCosfPltOff = 0xDCF94B0;
const int elfCefTanfPltVaddr = 0xDCFA4C0;
const int elfCefTanfPltOff = 0xDCF94C0;
const int elfCefExpfPltVaddr = 0xDCFA530;
const int elfCefExpfPltOff = 0xDCF9530;
const int elfCefLogfPltVaddr = 0xDCFA540;
const int elfCefLogfPltOff = 0xDCF9540;
const int elfCefPowfPltVaddr = 0xDCFB190;
const int elfCefPowfPltOff = 0xDCFA190;
const int elfCefFmodfPltVaddr = 0xDCFB1B0;
const int elfCefFmodfPltOff = 0xDCFA1B0;
const int elfCefSocketPltVaddr = 0xDCF6A00;
const int elfCefSocketPltOff = 0xDCF5A00;
const int elfCefSysconfPltVaddr = 0xDCF63E0;
const int elfCefSysconfPltOff = 0xDCF53E0;
const int elfCefHypotfPltVaddr = 0xDCF7790;
const int elfCefHypotfPltOff = 0xDCF6790;
const int elfCefNearbyintfPltVaddr = 0xDCF7630;
const int elfCefNearbyintfPltOff = 0xDCF6630;
const int elfCefSinPltVaddr = 0xDCF9620;
const int elfCefSinPltOff = 0xDCF8620;
const int elfCefCosPltVaddr = 0xDCF9630;
const int elfCefCosPltOff = 0xDCF8630;
const int elfCefTanPltVaddr = 0xDCF9640;
const int elfCefTanPltOff = 0xDCF8640;
const int elfCefAsinPltVaddr = 0xDCF9650;
const int elfCefAsinPltOff = 0xDCF8650;
const int elfCefAcosPltVaddr = 0xDCF9660;
const int elfCefAcosPltOff = 0xDCF8660;
const int elfCefAtanPltVaddr = 0xDCF9670;
const int elfCefAtanPltOff = 0xDCF8670;
const int elfCefAtan2PltVaddr = 0xDCF96C0;
const int elfCefAtan2PltOff = 0xDCF86C0;
const int elfCefExpPltVaddr = 0xDCF9680;
const int elfCefExpPltOff = 0xDCF8680;
const int elfCefLogPltVaddr = 0xDCF9690;
const int elfCefLogPltOff = 0xDCF8690;
const int elfCefExp2PltVaddr = 0xDCF96A0;
const int elfCefExp2PltOff = 0xDCF86A0;
const int elfCefLog2PltVaddr = 0xDCF96B0;
const int elfCefLog2PltOff = 0xDCF86B0;
const int elfCefPowPltVaddr = 0xDCF96D0;
const int elfCefPowPltOff = 0xDCF86D0;
const int elfCefHypotPltVaddr = 0xDCF96E0;
const int elfCefHypotPltOff = 0xDCF86E0;
const int elfCefSinhPltVaddr = 0xDCF9700;
const int elfCefSinhPltOff = 0xDCF8700;
const int elfCefCoshPltVaddr = 0xDCF9710;
const int elfCefCoshPltOff = 0xDCF8710;
const int elfCefTanhPltVaddr = 0xDCF9720;
const int elfCefTanhPltOff = 0xDCF8720;
const int elfCefAsinfPltVaddr = 0xDCFA4D0;
const int elfCefAsinfPltOff = 0xDCF94D0;
const int elfCefAcosfPltVaddr = 0xDCFA4E0;
const int elfCefAcosfPltOff = 0xDCF94E0;
const int elfCefAtanfPltVaddr = 0xDCFA4F0;
const int elfCefAtanfPltOff = 0xDCF94F0;
const int elfCefAtan2fPltVaddr = 0xDCFB0A0;
const int elfCefAtan2fPltOff = 0xDCFA0A0;
const int elfCefSinhfPltVaddr = 0xDCFA500;
const int elfCefSinhfPltOff = 0xDCF9500;
const int elfCefCoshfPltVaddr = 0xDCFA510;
const int elfCefCoshfPltOff = 0xDCF9510;
const int elfCefTanhfPltVaddr = 0xDCFA520;
const int elfCefTanhfPltOff = 0xDCF9520;
const int elfCefExp2fPltVaddr = 0xDCFA550;
const int elfCefExp2fPltOff = 0xDCF9550;
const int elfCefLog2fPltVaddr = 0xDCFB0B0;
const int elfCefLog2fPltOff = 0xDCFA0B0;
const int elfCefLog10PltVaddr = 0xDCFB090;
const int elfCefLog10PltOff = 0xDCFA090;
const int elfCefLog10fPltVaddr = 0xDCFB040;
const int elfCefLog10fPltOff = 0xDCFA040;
const int elfCefRintPltVaddr = 0xDCFB0C0;
const int elfCefRintPltOff = 0xDCFA0C0;
const int elfCefRintfPltVaddr = 0xDCFB100;
const int elfCefRintfPltOff = 0xDCFA100;
const int elfCefNearbyintPltVaddr = 0xDCFB130;
const int elfCefNearbyintPltOff = 0xDCFA130;
const int elfCefFmaPltVaddr = 0xDCFB120;
const int elfCefFmaPltOff = 0xDCFA120;
const int elfCefFmafPltVaddr = 0xDCFB0D0;
const int elfCefFmafPltOff = 0xDCFA0D0;
const int elfCefModfPltVaddr = 0xDCFB170;
const int elfCefModfPltOff = 0xDCFA170;
const int elfCefModffPltVaddr = 0xDCFB140;
const int elfCefModffPltOff = 0xDCFA140;
const int elfCefFrexpPltVaddr = 0xDCF62A0;
const int elfCefFrexpPltOff = 0xDCF52A0;
const int elfCefFrexpfPltVaddr = 0xDCFB150;
const int elfCefFrexpfPltOff = 0xDCFA150;
const int elfCefLdexpPltVaddr = 0xDCF6270;
const int elfCefLdexpPltOff = 0xDCF5270;
const int elfCefLdexpfPltVaddr = 0xDCF7AA0;
const int elfCefLdexpfPltOff = 0xDCF6AA0;
const int elfCefCbrtPltVaddr = 0xDCF6C50;
const int elfCefCbrtPltOff = 0xDCF5C50;
const int elfCefCbrtfPltVaddr = 0xDCF6BE0;
const int elfCefCbrtfPltOff = 0xDCF5BE0;
const int elfCefNextafterPltVaddr = 0xDCF6A60;
const int elfCefNextafterPltOff = 0xDCF5A60;
const int elfCefNextafterfPltVaddr = 0xDCF6C70;
const int elfCefNextafterfPltOff = 0xDCF5C70;
const int elfCefAcoshPltVaddr = 0xDCF74F0;
const int elfCefAcoshPltOff = 0xDCF64F0;
const int elfCefAcoshfPltVaddr = 0xDCF7500;
const int elfCefAcoshfPltOff = 0xDCF6500;
const int elfCefAsinhPltVaddr = 0xDCF7510;
const int elfCefAsinhPltOff = 0xDCF6510;
const int elfCefAsinhfPltVaddr = 0xDCF7520;
const int elfCefAsinhfPltOff = 0xDCF6520;
const int elfCefAtanhPltVaddr = 0xDCF7530;
const int elfCefAtanhPltOff = 0xDCF6530;
const int elfCefAtanhfPltVaddr = 0xDCF7540;
const int elfCefAtanhfPltOff = 0xDCF6540;
const int elfCefScalbnPltVaddr = 0xDCF7720;
const int elfCefScalbnPltOff = 0xDCF6720;
const int elfCefRemainderPltVaddr = 0xDCF9040;
const int elfCefRemainderPltOff = 0xDCF8040;
const int elfCefIlogbfPltVaddr = 0xDCF9100;
const int elfCefIlogbfPltOff = 0xDCF8100;
const int elfCefErfPltVaddr = 0xDCF6BD0;
const int elfCefErfPltOff = 0xDCF5BD0;
const int elfCefErffPltVaddr = 0xDCF9110;
const int elfCefErffPltOff = 0xDCF8110;
const int elfCefLog1pPltVaddr = 0xDCF7710;
const int elfCefLog1pPltOff = 0xDCF6710;
const int elfCefExpm1fPltVaddr = 0xDCF6BC0;
const int elfCefExpm1fPltOff = 0xDCF5BC0;
const int elfCefFreadPltVaddr = 0xDCF5FE0;
const int elfCefFreadPltOff = 0xDCF4FE0;
const int elfCefFwritePltVaddr = 0xDCF6020;
const int elfCefFwritePltOff = 0xDCF5020;
const int elfCefFseekPltVaddr = 0xDCF5FF0;
const int elfCefFseekPltOff = 0xDCF4FF0;
const int elfCefFtellPltVaddr = 0xDCF6000;
const int elfCefFtellPltOff = 0xDCF5000;
const int elfCefFgetsPltVaddr = 0xDCF6070;
const int elfCefFgetsPltOff = 0xDCF5070;
const int elfCefFclosePltVaddr = 0xDCF6080;
const int elfCefFclosePltOff = 0xDCF5080;
const int elfCefFputsPltVaddr = 0xDCF6160;
const int elfCefFputsPltOff = 0xDCF5160;
const int elfCefPrintfPltVaddr = 0xDCF60E0;
const int elfCefPrintfPltOff = 0xDCF50E0;
const int elfCefSnprintfPltVaddr = 0xDCF62D0;
const int elfCefSnprintfPltOff = 0xDCF52D0;
const int elfCefVsnprintfPltVaddr = 0xDCF6260;
const int elfCefVsnprintfPltOff = 0xDCF5260;
const int elfCefFprintfPltVaddr = 0xDCF6580;
const int elfCefFprintfPltOff = 0xDCF5580;
const int elfCefSprintfPltVaddr = 0xDCF7910;
const int elfCefSprintfPltOff = 0xDCF6910;
const int elfCefFputcPltVaddr = 0xDCF6BF0;
const int elfCefFputcPltOff = 0xDCF5BF0;
const int elfCefGetcPltVaddr = 0xDCF9780;
const int elfCefGetcPltOff = 0xDCF8780;
const int elfCefUngetcPltVaddr = 0xDCFAEA0;
const int elfCefUngetcPltOff = 0xDCF9EA0;
const int elfCefSetvbufPltVaddr = 0xDCF75A0;
const int elfCefSetvbufPltOff = 0xDCF65A0;
const int elfCefRewindPltVaddr = 0xDCF75B0;
const int elfCefRewindPltOff = 0xDCF65B0;
const int elfCefSetbufPltVaddr = 0xDCFAE90;
const int elfCefSetbufPltOff = 0xDCF9E90;
const int elfCefSigactionPltVaddr = 0xDCF6110;
const int elfCefSigactionPltOff = 0xDCF5110;
const int elfCefRaisePltVaddr = 0xDCF6120;
const int elfCefRaisePltOff = 0xDCF5120;
const int elfCefNanosleepPltVaddr = 0xDCF61E0;
const int elfCefNanosleepPltOff = 0xDCF51E0;
const int elfCefClockGettimePltVaddr = 0xDCF61F0;
const int elfCefClockGettimePltOff = 0xDCF51F0;
const int elfCefSignalPltVaddr = 0xDCF6510;
const int elfCefSignalPltOff = 0xDCF5510;
const int elfCefStrerrorPltVaddr = 0xDCF65A0;
const int elfCefStrerrorPltOff = 0xDCF55A0;
const int elfCefStrerrorRPltVaddr = 0xDCF6570;
const int elfCefStrerrorRPltOff = 0xDCF5570;
const int elfCefUnamePltVaddr = 0xDCF65B0;
const int elfCefUnamePltOff = 0xDCF55B0;
const int elfCefOpendirPltVaddr = 0xDCF6630;
const int elfCefOpendirPltOff = 0xDCF5630;
const int elfCefClosedirPltVaddr = 0xDCF66C0;
const int elfCefClosedirPltOff = 0xDCF56C0;
const int elfCefMadvisePltVaddr = 0xDCF66F0;
const int elfCefMadvisePltOff = 0xDCF56F0;
const int elfCefTzsetPltVaddr = 0xDCF67D0;
const int elfCefTzsetPltOff = 0xDCF57D0;
const int elfCefForkPltVaddr = 0xDCF6810;
const int elfCefForkPltOff = 0xDCF5810;
const int elfCefChdirPltVaddr = 0xDCF6830;
const int elfCefChdirPltOff = 0xDCF5830;
const int elfCefPollPltVaddr = 0xDCF6860;
const int elfCefPollPltOff = 0xDCF5860;
const int elfCefQsortPltVaddr = 0xDCF6B90;
const int elfCefQsortPltOff = 0xDCF5B90;
const int elfCefBindPltVaddr = 0xDCF69A0;
const int elfCefBindPltOff = 0xDCF59A0;
const int elfCefListenPltVaddr = 0xDCF69B0;
const int elfCefListenPltOff = 0xDCF59B0;
const int elfCefShutdownPltVaddr = 0xDCF69C0;
const int elfCefShutdownPltOff = 0xDCF59C0;
const int elfCefConnectPltVaddr = 0xDCF6A10;
const int elfCefConnectPltOff = 0xDCF5A10;
const int elfCefAcceptPltVaddr = 0xDCF6A40;
const int elfCefAcceptPltOff = 0xDCF5A40;
const int elfCefWritevPltVaddr = 0xDCF6940;
const int elfCefWritevPltOff = 0xDCF5940;
const int elfCefSetsockoptPltVaddr = 0xDCF6990;
const int elfCefSetsockoptPltOff = 0xDCF5990;
const int elfCefGetsockoptPltVaddr = 0xDCF69F0;
const int elfCefGetsockoptPltOff = 0xDCF59F0;
const int elfCefGmtimePltVaddr = 0xDCF6A50;
const int elfCefGmtimePltOff = 0xDCF5A50;
const int elfCefGmtimeRPltVaddr = 0xDCF6460;
const int elfCefGmtimeRPltOff = 0xDCF5460;
const int elfCefSelectPltVaddr = 0xDCF74E0;
const int elfCefSelectPltOff = 0xDCF64E0;
const int elfCefIoctlPltVaddr = 0xDCF6CD0;
const int elfCefIoctlPltOff = 0xDCF5CD0;
const int elfCefStrdupPltVaddr = 0xDCF6490;
const int elfCefStrdupPltOff = 0xDCF5490;
const int elfCefStrtodPltVaddr = 0xDCF6C00;
const int elfCefStrtodPltOff = 0xDCF5C00;
const int elfCefStrftimePltVaddr = 0xDCF6430;
const int elfCefStrftimePltOff = 0xDCF5430;
const int elfCefFcntlPltVaddr = 0xDCF64D0;
const int elfCefFcntlPltOff = 0xDCF54D0;
const int elfCefPrctlPltVaddr = 0xDCF6400;
const int elfCefPrctlPltOff = 0xDCF5400;
const int elfCefSigemptysetPltVaddr = 0xDCF6100;
const int elfCefSigemptysetPltOff = 0xDCF5100;
const int elfCefSigfillsetPltVaddr = 0xDCF6200;
const int elfCefSigfillsetPltOff = 0xDCF5200;
const int elfCefSigaddsetPltVaddr = 0xDCF6F20;
const int elfCefSigaddsetPltOff = 0xDCF5F20;
const int elfCefSigdelsetPltVaddr = 0xDCF7770;
const int elfCefSigdelsetPltOff = 0xDCF6770;
const int elfCefSigprocmaskPltVaddr = 0xDCF6F30;
const int elfCefSigprocmaskPltOff = 0xDCF5F30;
const int elfCefSigaltstackPltVaddr = 0xDCF64F0;
const int elfCefSigaltstackPltOff = 0xDCF54F0;
const int elfCefSemInitPltVaddr = 0xDCF6350;
const int elfCefSemInitPltOff = 0xDCF5350;
const int elfCefSemWaitPltVaddr = 0xDCF6370;
const int elfCefSemWaitPltOff = 0xDCF5370;
const int elfCefSemPostPltVaddr = 0xDCF6380;
const int elfCefSemPostPltOff = 0xDCF5380;
const int elfCefSemDestroyPltVaddr = 0xDCF6C60;
const int elfCefSemDestroyPltOff = 0xDCF5C60;
const int elfCefSemTimedwaitPltVaddr = 0xDCF6360;
const int elfCefSemTimedwaitPltOff = 0xDCF5360;
const int elfCefMmap64PltVaddr = 0xDCF63F0;
const int elfCefMmap64PltOff = 0xDCF53F0;
const int elfCefOpen64PltVaddr = 0xDCF61B0;
const int elfCefOpen64PltOff = 0xDCF51B0;
const int elfCefOpenat64PltVaddr = 0xDCF7730;
const int elfCefOpenat64PltOff = 0xDCF6730;
const int elfCefFopen64PltVaddr = 0xDCF6060;
const int elfCefFopen64PltOff = 0xDCF5060;
const int elfCefFdopenPltVaddr = 0xDCF6150;
const int elfCefFdopenPltOff = 0xDCF5150;
const int elfCefLseek64PltVaddr = 0xDCF65F0;
const int elfCefLseek64PltOff = 0xDCF55F0;
const int elfCefPread64PltVaddr = 0xDCF64C0;
const int elfCefPread64PltOff = 0xDCF54C0;
const int elfCefPwrite64PltVaddr = 0xDCF7AE0;
const int elfCefPwrite64PltOff = 0xDCF6AE0;
const int elfCefFtruncate64PltVaddr = 0xDCF6950;
const int elfCefFtruncate64PltOff = 0xDCF5950;
const int elfCefFseeko64PltVaddr = 0xDCF7550;
const int elfCefFseeko64PltOff = 0xDCF6550;
const int elfCefFtello64PltVaddr = 0xDCF7560;
const int elfCefFtello64PltOff = 0xDCF6560;
const int elfCefMkstemp64PltVaddr = 0xDCF6140;
const int elfCefMkstemp64PltOff = 0xDCF5140;
const int elfCefMkostemp64PltVaddr = 0xDCF6F50;
const int elfCefMkostemp64PltOff = 0xDCF5F50;
const int elfCefMkdtempPltVaddr = 0xDCF67B0;
const int elfCefMkdtempPltOff = 0xDCF57B0;
const int elfCefReaddir64PltVaddr = 0xDCF6640;
const int elfCefReaddir64PltOff = 0xDCF5640;
const int elfCefGetgrnamPltVaddr = 0xDCF6650;
const int elfCefGetgrnamPltOff = 0xDCF5650;
const int elfCefGetgrgidPltVaddr = 0xDCF93D0;
const int elfCefGetgrgidPltOff = 0xDCF83D0;
const int elfCefGetpwuidPltVaddr = 0xDCF7670;
const int elfCefGetpwuidPltOff = 0xDCF6670;
const int elfCefEventfdPltVaddr = 0xDCF65C0;
const int elfCefEventfdPltOff = 0xDCF55C0;
const int elfCefTimerfdCreatePltVaddr = 0xDCF6700;
const int elfCefTimerfdCreatePltOff = 0xDCF5700;
const int elfCefTimerfdSettimePltVaddr = 0xDCF6710;
const int elfCefTimerfdSettimePltOff = 0xDCF5710;
const int elfCefSchedSetschedulerPltVaddr = 0xDCF6730;
const int elfCefSchedSetschedulerPltOff = 0xDCF5730;
const int elfCefSchedGetschedulerPltVaddr = 0xDCF6750;
const int elfCefSchedGetschedulerPltOff = 0xDCF5750;
const int elfCefSchedGetparamPltVaddr = 0xDCF6760;
const int elfCefSchedGetparamPltOff = 0xDCF5760;
const int elfCefSchedGetaffinityPltVaddr = 0xDCF7BD0;
const int elfCefSchedGetaffinityPltOff = 0xDCF6BD0;
const int elfCefNewlocalePltVaddr = 0xDCF6780;
const int elfCefNewlocalePltOff = 0xDCF5780;
const int elfCefFreelocalePltVaddr = 0xDCF9130;
const int elfCefFreelocalePltOff = 0xDCF8130;
const int elfCefUselocalePltVaddr = 0xDCF9120;
const int elfCefUselocalePltOff = 0xDCF8120;
const int elfCefStrtodLPltVaddr = 0xDCF6790;
const int elfCefStrtodLPltOff = 0xDCF5790;
const int elfCefSetlocalePltVaddr = 0xDCF7760;
const int elfCefSetlocalePltOff = 0xDCF6760;
const int elfCefLocaleconvPltVaddr = 0xDCF9170;
const int elfCefLocaleconvPltOff = 0xDCF8170;
const int elfCefSetenvPltVaddr = 0xDCF67F0;
const int elfCefSetenvPltOff = 0xDCF57F0;
const int elfCefUnsetenvPltVaddr = 0xDCF6800;
const int elfCefUnsetenvPltOff = 0xDCF5800;
const int elfCefSetsidPltVaddr = 0xDCF6820;
const int elfCefSetsidPltOff = 0xDCF5820;
const int elfCefReadlinkPltVaddr = 0xDCF6850;
const int elfCefReadlinkPltOff = 0xDCF5850;
const int elfCefSetpgidPltVaddr = 0xDCF68A0;
const int elfCefSetpgidPltOff = 0xDCF58A0;
const int elfCefExecvpPltVaddr = 0xDCF68C0;
const int elfCefExecvpPltOff = 0xDCF58C0;
const int elfCefExeclpPltVaddr = 0xDCF60F0;
const int elfCefExeclpPltOff = 0xDCF50F0;
const int elfCefExecvPltVaddr = 0xDCF78D0;
const int elfCefExecvPltOff = 0xDCF68D0;
const int elfCefSystemPltVaddr = 0xDCF6180;
const int elfCefSystemPltOff = 0xDCF5180;
const int elfCefClonePltVaddr = 0xDCF78C0;
const int elfCefClonePltOff = 0xDCF68C0;
const int elfCefVfprintfPltVaddr = 0xDCF68F0;
const int elfCefVfprintfPltOff = 0xDCF58F0;
const int elfCefFchmodPltVaddr = 0xDCF6930;
const int elfCefFchmodPltOff = 0xDCF5930;
const int elfCefFreeaddrinfoPltVaddr = 0xDCF6970;
const int elfCefFreeaddrinfoPltOff = 0xDCF5970;
const int elfCefSocketpairPltVaddr = 0xDCF6980;
const int elfCefSocketpairPltOff = 0xDCF5980;
const int elfCefGetsocknamePltVaddr = 0xDCF69D0;
const int elfCefGetsocknamePltOff = 0xDCF59D0;
const int elfCefInetNtopPltVaddr = 0xDCF69E0;
const int elfCefInetNtopPltOff = 0xDCF59E0;
const int elfCefSendmsgPltVaddr = 0xDCF6A20;
const int elfCefSendmsgPltOff = 0xDCF5A20;
const int elfCefRecvmsgPltVaddr = 0xDCF6A30;
const int elfCefRecvmsgPltOff = 0xDCF5A30;
const int elfCefGaiStrerrorPltVaddr = 0xDCF6AB0;
const int elfCefGaiStrerrorPltOff = 0xDCF5AB0;
const int elfCefGetifaddrsPltVaddr = 0xDCF6AC0;
const int elfCefGetifaddrsPltOff = 0xDCF5AC0;
const int elfCefFreeifaddrsPltVaddr = 0xDCF6AD0;
const int elfCefFreeifaddrsPltOff = 0xDCF5AD0;
const int elfCefMremapPltVaddr = 0xDCF6BA0;
const int elfCefMremapPltOff = 0xDCF5BA0;
const int elfCefPpollPltVaddr = 0xDCF6E40;
const int elfCefPpollPltOff = 0xDCF5E40;
const int elfCefOpenMemstreamPltVaddr = 0xDCF6E50;
const int elfCefOpenMemstreamPltOff = 0xDCF5E50;
const int elfCefEpollCreate1PltVaddr = 0xDCF6E60;
const int elfCefEpollCreate1PltOff = 0xDCF5E60;
const int elfCefEpollCreatePltVaddr = 0xDCF6E70;
const int elfCefEpollCreatePltOff = 0xDCF5E70;
const int elfCefEpollCtlPltVaddr = 0xDCF7CF0;
const int elfCefEpollCtlPltOff = 0xDCF6CF0;
const int elfCefEpollWaitPltVaddr = 0xDCF7D00;
const int elfCefEpollWaitPltOff = 0xDCF6D00;
const int elfCefMsyncPltVaddr = 0xDCF6E80;
const int elfCefMsyncPltOff = 0xDCF5E80;
const int elfCefPosixFallocate64PltVaddr = 0xDCF6F40;
const int elfCefPosixFallocate64PltOff = 0xDCF5F40;
const int elfCefPosixFadvise64PltVaddr = 0xDCF7C80;
const int elfCefPosixFadvise64PltOff = 0xDCF6C80;
const int elfCefFallocate64PltVaddr = 0xDCF7C60;
const int elfCefFallocate64PltOff = 0xDCF6C60;
const int elfCefSendfile64PltVaddr = 0xDCF7C90;
const int elfCefSendfile64PltOff = 0xDCF6C90;
const int elfCefFdatasyncPltVaddr = 0xDCF6670;
const int elfCefFdatasyncPltOff = 0xDCF5670;
const int elfCefUtimensatPltVaddr = 0xDCF7570;
const int elfCefUtimensatPltOff = 0xDCF6570;
const int elfCefFutimensPltVaddr = 0xDCF7AF0;
const int elfCefFutimensPltOff = 0xDCF6AF0;
const int elfCefGetrlimit64PltVaddr = 0xDCF64E0;
const int elfCefGetrlimit64PltOff = 0xDCF54E0;
const int elfCefSetrlimit64PltVaddr = 0xDCF7CD0;
const int elfCefSetrlimit64PltOff = 0xDCF6CD0;
const int elfCefInotifyInitPltVaddr = 0xDCF76C0;
const int elfCefInotifyInitPltOff = 0xDCF66C0;
const int elfCefInotifyAddWatchPltVaddr = 0xDCF76D0;
const int elfCefInotifyAddWatchPltOff = 0xDCF66D0;
const int elfCefInotifyRmWatchPltVaddr = 0xDCF76E0;
const int elfCefInotifyRmWatchPltOff = 0xDCF66E0;
const int elfCefTcflushPltVaddr = 0xDCF76F0;
const int elfCefTcflushPltOff = 0xDCF66F0;
const int elfCefTcdrainPltVaddr = 0xDCF7700;
const int elfCefTcdrainPltOff = 0xDCF6700;
const int elfCefSyscallPltVaddr = 0xDCF61A0;
const int elfCefSyscallPltOff = 0xDCF51A0;
const int elfCefRemovePltVaddr = 0xDCF7860;
const int elfCefRemovePltOff = 0xDCF6860;
const int elfCefPathconfPltVaddr = 0xDCF7C70;
const int elfCefPathconfPltOff = 0xDCF6C70;
const int elfCefFsyncPltVaddr = 0xDCF7840;
const int elfCefFsyncPltOff = 0xDCF6840;
const int elfCefLinkPltVaddr = 0xDCF9140;
const int elfCefLinkPltOff = 0xDCF8140;
const int elfCefSymlinkPltVaddr = 0xDCF7C40;
const int elfCefSymlinkPltOff = 0xDCF6C40;
const int elfCefUnlinkatPltVaddr = 0xDCF7740;
const int elfCefUnlinkatPltOff = 0xDCF6740;
const int elfCefGetcwdPltVaddr = 0xDCF78E0;
const int elfCefGetcwdPltOff = 0xDCF68E0;
const int elfCefRealpathPltVaddr = 0xDCF7C30;
const int elfCefRealpathPltOff = 0xDCF6C30;
const int elfCefGettimeofdayPltVaddr = 0xDCF77E0;
const int elfCefGettimeofdayPltOff = 0xDCF67E0;
const int elfCefDifftimePltVaddr = 0xDCFA560;
const int elfCefDifftimePltOff = 0xDCF9560;
const int elfCefTimegmPltVaddr = 0xDCF7D30;
const int elfCefTimegmPltOff = 0xDCF6D30;
const int elfCefWcstolPltVaddr = 0xDCFA9F0;
const int elfCefWcstolPltOff = 0xDCF99F0;
const int elfCefSwprintfPltVaddr = 0xDCF7800;
const int elfCefSwprintfPltOff = 0xDCF6800;
const int elfCefVswprintfPltVaddr = 0xDCF7830;
const int elfCefVswprintfPltOff = 0xDCF6830;
const int elfCefVasprintfPltVaddr = 0xDCF9180;
const int elfCefVasprintfPltOff = 0xDCF8180;
const int elfCefFmodPltVaddr = 0xDCFB1A0;
const int elfCefFmodPltOff = 0xDCFA1A0;
const int elfCefLog1pfPltVaddr = 0xDCFAE70;
const int elfCefLog1pfPltOff = 0xDCF9E70;
const int elfCefLroundPltVaddr = 0xDCFB050;
const int elfCefLroundPltOff = 0xDCFA050;
const int elfCefLroundfPltVaddr = 0xDCFB0F0;
const int elfCefLroundfPltOff = 0xDCFA0F0;
const int elfCefLlroundPltVaddr = 0xDCFB080;
const int elfCefLlroundPltOff = 0xDCFA080;
const int elfCefLlroundfPltVaddr = 0xDCFB160;
const int elfCefLlroundfPltOff = 0xDCFA160;
const int elfCefGetoptLongPltVaddr = 0xDCFAE80;
const int elfCefGetoptLongPltOff = 0xDCF9E80;
const int elfCefWaitpidPltVaddr = 0xDCF7780;
const int elfCefWaitpidPltOff = 0xDCF6780;
const int elfCefWaitidPltVaddr = 0xDCF97A0;
const int elfCefWaitidPltOff = 0xDCF87A0;
const int elfCefPipe2PltVaddr = 0xDCF77B0;
const int elfCefPipe2PltOff = 0xDCF67B0;
const int elfCefFlockPltVaddr = 0xDCF77A0;
const int elfCefFlockPltOff = 0xDCF67A0;
const int elfCefLchownPltVaddr = 0xDCFAA10;
const int elfCefLchownPltOff = 0xDCF9A10;
const int elfCefUmaskPltVaddr = 0xDCFA9E0;
const int elfCefUmaskPltOff = 0xDCF99E0;
const int elfCefMincorePltVaddr = 0xDCF7900;
const int elfCefMincorePltOff = 0xDCF6900;
const int elfCefDirfdPltVaddr = 0xDCF7930;
const int elfCefDirfdPltOff = 0xDCF6930;
const int elfCefOpenlogPltVaddr = 0xDCF7AB0;
const int elfCefOpenlogPltOff = 0xDCF6AB0;
const int elfCefSyslogPltVaddr = 0xDCF7AC0;
const int elfCefSyslogPltOff = 0xDCF6AC0;
const int elfCefCloselogPltVaddr = 0xDCF7AD0;
const int elfCefCloselogPltOff = 0xDCF6AD0;
const int elfCefStatvfs64PltVaddr = 0xDCF7C00;
const int elfCefStatvfs64PltOff = 0xDCF6C00;
const int elfCefStatfs64PltVaddr = 0xDCF7C10;
const int elfCefStatfs64PltOff = 0xDCF6C10;
const int elfCefFstatfs64PltVaddr = 0xDCF7CC0;
const int elfCefFstatfs64PltOff = 0xDCF6CC0;
const int elfCefFnmatchPltVaddr = 0xDCF7C20;
const int elfCefFnmatchPltOff = 0xDCF6C20;
const int elfCefCreat64PltVaddr = 0xDCF7C50;
const int elfCefCreat64PltOff = 0xDCF6C50;
const int elfCefFdopendirPltVaddr = 0xDCF7CA0;
const int elfCefFdopendirPltOff = 0xDCF6CA0;
const int elfCefWcrtombPltVaddr = 0xDCF7D10;
const int elfCefWcrtombPltOff = 0xDCF6D10;
const int elfCefMbrtowcPltVaddr = 0xDCF7D20;
const int elfCefMbrtowcPltOff = 0xDCF6D20;
const int elfCefWcsftimePltVaddr = 0xDCF7890;
const int elfCefWcsftimePltOff = 0xDCF6890;
const int elfCefStrndupPltVaddr = 0xDCF9190;
const int elfCefStrndupPltOff = 0xDCF8190;
const int elfCefRandRPltVaddr = 0xDCF9730;
const int elfCefRandRPltOff = 0xDCF8730;
const int elfCefInitstateRPltVaddr = 0xDCF9150;
const int elfCefInitstateRPltOff = 0xDCF8150;
const int elfCefRandomRPltVaddr = 0xDCF9160;
const int elfCefRandomRPltOff = 0xDCF8160;
const int elfCefLongjmpPltVaddr = 0xDCF77C0;
const int elfCefLongjmpPltOff = 0xDCF67C0;
const int elfCefUSetjmpPltVaddr = 0xDCF77D0;
const int elfCefUSetjmpPltOff = 0xDCF67D0;
const int elfCefPthreadSelfPltVaddr = 0xDCF63C0;
const int elfCefPthreadSelfPltOff = 0xDCF53C0;
const int elfCefPthreadOncePltVaddr = 0xDCF6B80;
const int elfCefPthreadOncePltOff = 0xDCF5B80;
const int elfCefPthreadMutexInitPltVaddr = 0xDCF62F0;
const int elfCefPthreadMutexInitPltOff = 0xDCF52F0;
const int elfCefPthreadMutexLockPltVaddr = 0xDCF6340;
const int elfCefPthreadMutexLockPltOff = 0xDCF5340;
const int elfCefPthreadMutexUnlockPltVaddr = 0xDCF5FC0;
const int elfCefPthreadMutexUnlockPltOff = 0xDCF4FC0;
const int elfCefPthreadMutexDestroyPltVaddr = 0xDCF6BB0;
const int elfCefPthreadMutexDestroyPltOff = 0xDCF5BB0;
const int elfCefPthreadMutexTrylockPltVaddr = 0xDCF5FB0;
const int elfCefPthreadMutexTrylockPltOff = 0xDCF4FB0;
const int elfCefPthreadMutexattrInitPltVaddr = 0xDCF7B40;
const int elfCefPthreadMutexattrInitPltOff = 0xDCF6B40;
const int elfCefPthreadMutexattrDestroyPltVaddr = 0xDCF7B50;
const int elfCefPthreadMutexattrDestroyPltOff = 0xDCF6B50;
const int elfCefPthreadCondInitPltVaddr = 0xDCF6300;
const int elfCefPthreadCondInitPltOff = 0xDCF5300;
const int elfCefPthreadCondWaitPltVaddr = 0xDCF6320;
const int elfCefPthreadCondWaitPltOff = 0xDCF5320;
const int elfCefPthreadCondTimedwaitPltVaddr = 0xDCF6310;
const int elfCefPthreadCondTimedwaitPltOff = 0xDCF5310;
const int elfCefPthreadCondSignalPltVaddr = 0xDCF6330;
const int elfCefPthreadCondSignalPltOff = 0xDCF5330;
const int elfCefPthreadCondBroadcastPltVaddr = 0xDCF6E30;
const int elfCefPthreadCondBroadcastPltOff = 0xDCF5E30;
const int elfCefPthreadCondDestroyPltVaddr = 0xDCF6E20;
const int elfCefPthreadCondDestroyPltOff = 0xDCF5E20;
const int elfCefPthreadCondattrInitPltVaddr = 0xDCF7B10;
const int elfCefPthreadCondattrInitPltOff = 0xDCF6B10;
const int elfCefPthreadCondattrSetclockPltVaddr = 0xDCF7B20;
const int elfCefPthreadCondattrSetclockPltOff = 0xDCF6B20;
const int elfCefPthreadCondattrDestroyPltVaddr = 0xDCF7B30;
const int elfCefPthreadCondattrDestroyPltOff = 0xDCF6B30;
const int elfCefPthreadKeyCreatePltVaddr = 0xDCF6240;
const int elfCefPthreadKeyCreatePltOff = 0xDCF5240;
const int elfCefPthreadKeyDeletePltVaddr = 0xDCF6900;
const int elfCefPthreadKeyDeletePltOff = 0xDCF5900;
const int elfCefPthreadGetspecificPltVaddr = 0xDCF6230;
const int elfCefPthreadGetspecificPltOff = 0xDCF5230;
const int elfCefPthreadSetspecificPltVaddr = 0xDCF6220;
const int elfCefPthreadSetspecificPltOff = 0xDCF5220;
const int elfCefPthreadAttrInitPltVaddr = 0xDCF7B80;
const int elfCefPthreadAttrInitPltOff = 0xDCF6B80;
const int elfCefPthreadAttrDestroyPltVaddr = 0xDCF7BB0;
const int elfCefPthreadAttrDestroyPltOff = 0xDCF6BB0;
const int elfCefPthreadAttrSetstacksizePltVaddr = 0xDCF7BA0;
const int elfCefPthreadAttrSetstacksizePltOff = 0xDCF6BA0;
const int elfCefPthreadAttrSetdetachstatePltVaddr = 0xDCF7B90;
const int elfCefPthreadAttrSetdetachstatePltOff = 0xDCF6B90;
const int elfCefPthreadAttrGetstackPltVaddr = 0xDCF75F0;
const int elfCefPthreadAttrGetstackPltOff = 0xDCF65F0;
const int elfCefPthreadAttrGetstacksizePltVaddr = 0xDCF7D40;
const int elfCefPthreadAttrGetstacksizePltOff = 0xDCF6D40;
const int elfCefPthreadCreatePltVaddr = 0xDCF6880;
const int elfCefPthreadCreatePltOff = 0xDCF5880;
const int elfCefPthreadJoinPltVaddr = 0xDCF7B60;
const int elfCefPthreadJoinPltOff = 0xDCF6B60;
const int elfCefPthreadDetachPltVaddr = 0xDCF7B70;
const int elfCefPthreadDetachPltOff = 0xDCF6B70;
const int elfCefPthreadSigmaskPltVaddr = 0xDCF6210;
const int elfCefPthreadSigmaskPltOff = 0xDCF5210;
const int elfCefPthreadGetschedparamPltVaddr = 0xDCF63B0;
const int elfCefPthreadGetschedparamPltOff = 0xDCF53B0;
const int elfCefPthreadSetnameNpPltVaddr = 0xDCF6870;
const int elfCefPthreadSetnameNpPltOff = 0xDCF5870;
const int elfCefPthreadGetnameNpPltVaddr = 0xDCF6910;
const int elfCefPthreadGetnameNpPltOff = 0xDCF5910;
const int elfCefPthreadKillPltVaddr = 0xDCF75C0;
const int elfCefPthreadKillPltOff = 0xDCF65C0;
const int elfCefPthreadGetattrNpPltVaddr = 0xDCF75E0;
const int elfCefPthreadGetattrNpPltOff = 0xDCF65E0;
const int elfCefPkeyMprotectPltVaddr = 0xDCF9740;
const int elfCefPkeyMprotectPltOff = 0xDCF8740;
const int elfCefPkeyAllocPltVaddr = 0xDCF9760;
const int elfCefPkeyAllocPltOff = 0xDCF8760;
const int elfCefPkeySetPltVaddr = 0xDCF9750;
const int elfCefPkeySetPltOff = 0xDCF8750;
const int elfCefXCxaFinalizePltVaddr = 0xDCF5DF0;
const int elfCefXCxaFinalizePltOff = 0xDCF4DF0;
const int elfCefXCxaAtexitPltVaddr = 0xDCF6050;
const int elfCefXCxaAtexitPltOff = 0xDCF5050;
const int elfCefXErrnoLocationPltVaddr = 0xDCF5FD0;
const int elfCefXErrnoLocationPltOff = 0xDCF4FD0;
const int elfCefXCtypeBLocPltVaddr = 0xDCF6420;
const int elfCefXCtypeBLocPltOff = 0xDCF5420;
const int elfCefXCtypeTolowerLocPltVaddr = 0xDCF60A0;
const int elfCefXCtypeTolowerLocPltOff = 0xDCF50A0;
const int elfCefXCtypeToupperLocPltVaddr = 0xDCF75D0;
const int elfCefXCtypeToupperLocPltOff = 0xDCF65D0;
const int elfCefXXpgStrerrorRPltVaddr = 0xDCF96F0;
const int elfCefXXpgStrerrorRPltOff = 0xDCF86F0;
const int elfCefXCtypeGetMbCurMaxPltVaddr = 0xDCFAA80;
const int elfCefXCtypeGetMbCurMaxPltOff = 0xDCF9A80;
const int elfCefXCxaThreadAtexitImplPltVaddr = 0xDCFAFF0;
const int elfCefXCxaThreadAtexitImplPltOff = 0xDCF9FF0;
const int elfCefXGetdelimPltVaddr = 0xDCF6F60;
const int elfCefXGetdelimPltOff = 0xDCF5F60;
const int elfCefXLongjmpChkPltVaddr = 0xDCF7850;
const int elfCefXLongjmpChkPltOff = 0xDCF6850;
const int elfCefXMbrlenPltVaddr = 0xDCFAF40;
const int elfCefXMbrlenPltOff = 0xDCF9F40;
const int elfCefXRegisterAtforkPltVaddr = 0xDCFB1D0;
const int elfCefXRegisterAtforkPltOff = 0xDCFA1D0;
const int elfCefXSchedCpuallocPltVaddr = 0xDCF7BC0;
const int elfCefXSchedCpuallocPltOff = 0xDCF6BC0;
const int elfCefXSchedCpucountPltVaddr = 0xDCF7BE0;
const int elfCefXSchedCpucountPltOff = 0xDCF6BE0;
const int elfCefXSchedCpufreePltVaddr = 0xDCF7BF0;
const int elfCefXSchedCpufreePltOff = 0xDCF6BF0;
const int elfCefXStackChkFailPltVaddr = 0xDCFB020;
const int elfCefXStackChkFailPltOff = 0xDCFA020;
const int elfCefXTlsGetAddrPltVaddr = 0xDCFB200;
const int elfCefXTlsGetAddrPltOff = 0xDCFA200;
const int elfCefXUdivti3PltVaddr = 0xDCFB000;
const int elfCefXUdivti3PltOff = 0xDCFA000;
const int elfCefMktimePltVaddr = 0xDCF6040;
const int elfCefMktimePltOff = 0xDCF5040;
/// Face slab: PLT idx 511 .. (unused run past strncat) holds OUR bodies.
const int elfCefUndFaceVaddr = 0xDCF7DD0;
const int elfCefUndFaceOff = 0xDCF6DD0;
const int elfCefUndFaceMax = 4976;
/// ADR-0180 batch-3 bodies (phases 200..399) — post-PLT hole before heap top.
const int elfCefUnd3FaceVaddr = 0xDCFB800;
const int elfCefUnd3FaceOff = 0xDCFA800;
const int elfCefUnd3FaceMax = 2048;
/// ADR-0170 floor: first five faces are required.
const int elfCefUndBatchWant = 5;
/// ADR-0172 expanded list size (extras bind when LIBC exports them).
/// ADR-0172 was 50; ADR-0178 was 100; ADR-0179 was 200; ADR-0180 grows to ≥400.
const int elfCefUnd2BatchWant = 400;
const int elfCefUndTotal = 1336;
/// Max bytes copied per face body into the slab.
const int elfCefMemsetBodyMax = 160;
/// ADR-0180: faces 200..399 copy at most eight bytes into the slab.
const int elfCefUnd3BodyMax = 8;
const int elfCefPltTrampolineBytes = 12;
const int elfDlopenRetFloor = 0xFFFFFFFFFFFFFF00;
const int elfDlopenRetBadArg = 0xFFFFFFFFFFFFFFFE;
const int elfDlopenRetBadPtr = 0xFFFFFFFFFFFFFFFC;
const int elfDlopenRetNotFound = 0xFFFFFFFFFFFFFFF9;
const int elfDlopenRetBadSo = 0xFFFFFFFFFFFFFFF6;
/// ADR-0174: planted `SOMAP.TXT` must fit one page (anti-vacuity table).
const int elfSomapMax = 4096;
/// ADR-0176: `dlopen` name length for real Linux sonames (e.g.
/// `ld-linux-x86-64.so.2`). FAT `fileNameMax` stays 12; this bound is
/// only the SOMAP / `DT_NEEDED` door. Longest CEF soname is 22.
const int elfDlopenNameMax = 64;

const int elfDtHash = 4;
const int elfDtStrtab = 5;
const int elfDtSymtab = 6;
const int elfDtStrsz = 10;
const int elfSymSize = 24;
const int elfDynSize = 16;
/// ADR-0180: four hundred LIBC exports + STN_UNDEF headroom.
const int elfDlopenSymMax = 512;

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
  elfCefPlantReserve();
}

/// 1 if [pa] lies inside the host-backed CEF LOAD plant.
@bare
u64 elfCefPlantOwns(u64 pa) {
  if (pa < u64(elfCefPlantPa)) {
    return u64(0);
  }
  if (pa >= (u64(elfCefPlantPa) + u64(elfCefPlantBytes))) {
    return u64(0);
  }
  return u64(1);
}

/// 1 if QEMU planted official ELF bytes at [elfCefPlantPa].
@bare
u64 elfCefPlantReady() {
  if (elfU8(u64(elfCefPlantPa)) != u64(elfIdentMag0)) {
    return u64(0);
  }
  if (elfU8(u64(elfCefPlantPa) + u64(1)) != u64(elfIdentMag1)) {
    return u64(0);
  }
  if (elfU8(u64(elfCefPlantPa) + u64(2)) != u64(elfIdentMag2)) {
    return u64(0);
  }
  if (elfU8(u64(elfCefPlantPa) + u64(3)) != u64(elfIdentMag3)) {
    return u64(0);
  }
  if (elfU8(u64(elfCefPlantPa) + u64(elfOffClass)) != u64(elfClass64)) {
    return u64(0);
  }
  if (elfU16(u64(elfCefPlantPa) + u64(elfOffType)) != u64(elfTypeDyn)) {
    return u64(0);
  }
  return u64(1);
}

/// Takes plant frames out of the free pool when the host loader put
/// official bytes there. No-op when the plant is absent (other
/// harnesses). Alias maps reuse these PAs; freeFrame must not return
/// them (see [elfCefPlantOwns] at teardown).
@bare
void elfCefPlantReserve() {
  if (elfCefPlantReady() < u64(1)) {
    return;
  }
  final u64 first = u64(elfCefPlantPa) >> u64(pmmFrameShift);
  final u64 lastEx = (u64(elfCefPlantPa) + u64(elfCefPlantBytes) +
          u64(pmmFrameMask)) >>
      u64(pmmFrameShift);
  u64 f = first;
  u64 took = u64(0);
  while (f < lastEx) {
    if (f < u64(pmmMaxFrames)) {
      if (pmmBitGet(f) < u64(1)) {
        pmmBitSet(f);
        took = took + u64(1);
      }
    }
    f = f + u64(1);
  }
  if (took > u64(0)) {
    final u64 free = pmmMeta(u64(pmmMetaFree));
    if (free >= took) {
      pmmSetMeta(u64(pmmMetaFree), free - took);
    }
  }
}

/// 1 if the open FAT 8.3 name is CEF.SO.
@bare
u64 elfCefNameIsCef() {
  final u64 nb = fatNameBase();
  if (elfU8(nb) != u64(0x43)) {
    return u64(0);
  }
  if (elfU8(nb + u64(1)) != u64(0x45)) {
    return u64(0);
  }
  if (elfU8(nb + u64(2)) != u64(0x46)) {
    return u64(0);
  }
  if (elfU8(nb + u64(8)) != u64(0x53)) {
    return u64(0);
  }
  if (elfU8(nb + u64(9)) != u64(0x4F)) {
    return u64(0);
  }
  return u64(1);
}

/// Prints `CEF LOAD RO <filesz> RX <filesz>`.
@bare
void elfCefLoadLine(u64 ro, u64 rx) {
  uartWrite(Rodata.addressOf(elfStrCefLoadRo), u64(12));
  uartPutHex(ro, u64(16));
  uartWrite(Rodata.addressOf(elfStrCefLoadRx), u64(4));
  uartPutHex(rx, u64(16));
  uartNewline();
}

/// Prints `CEF PLT MEMSET <va>` after binding the official PLT.
@bare
void elfCefPltMemsetLine(u64 va) {
  uartWrite(Rodata.addressOf(elfStrCefPltMemset), u64(15));
  uartPutHex(va, u64(16));
  uartNewline();
}

/// Prints `CEF UND BATCH <count>` after the high-traffic bind.
@bare
void elfCefUndBatchLine(u64 n) {
  uartWrite(Rodata.addressOf(elfStrCefUndBatch), u64(14));
  uartPutHex(n, u64(16));
  uartNewline();
}

/// Writes a 12-byte `movabs rax,imm64; jmp rax` trampoline at [dstPa].
@bare
void elfCefWritePltTrampoline(u64 dstPa, u64 targetVa) {
  Pointer<u8>.fromAddress(dstPa).value = u8(0x48);
  Pointer<u8>.fromAddress(dstPa + u64(1)).value = u8(0xB8);
  u64 i = u64(0);
  while (i < u64(8)) {
    Pointer<u8>.fromAddress(dstPa + u64(2) + i).value =
        ((targetVa >> (i << u64(3))) & u64(0xFF)).toU8();
    i = i + u64(1);
  }
  Pointer<u8>.fromAddress(dstPa + u64(10)).value = u8(0xFF);
  Pointer<u8>.fromAddress(dstPa + u64(11)).value = u8(0xE0);
  // Pad the rest of the 16-byte PLT slot with INT3.
  i = u64(12);
  while (i < u64(16)) {
    Pointer<u8>.fromAddress(dstPa + i).value = u8(0xCC);
    i = i + u64(1);
  }
}

/// Opens FAT `LIBC.SO`, plants OUR high-traffic UND face bodies into
/// an RX face slab (unused PLT slots at idx ≥ 511), and writes
/// trampolines over the official `@plt` stubs. First five faces
/// (ADR-0170) are required; ADR-0171 extras bind when exported.
/// Records the bound memset PLT VA at [bias] + [elfCefMemsetPltVaddr].
/// Missing `LIBC.SO` / missing any required face is refusal
/// (anti-vacuity). Measured: `malloc` is not in official libcef PLT.

/// ADR-0179: map a VA inside the LIBC RX image (≤3 pages) onto the
/// scratch / scratch2 / scratch3 striping used by [elfCefPlaceLibcMemset].
@bare
u64 elfDlopenRxPa(
    u64 s0, u64 s1, u64 s2, u64 s3, u64 s4, u64 s5, u64 textVa, u64 va) {
  final u64 off = va - textVa;
  if (off < u64(vmPageBytes)) {
    return s0 + off;
  }
  if (off < (u64(vmPageBytes) + u64(vmPageBytes))) {
    return s1 + (off - u64(vmPageBytes));
  }
  if (off < (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {
    return s2 + (off - u64(vmPageBytes) - u64(vmPageBytes));
  }
  if (off <
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes))) {
    return s3 +
        (off - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes));
  }
  if (off <
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes) + u64(vmPageBytes))) {
    return s4 +
        (off - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes) -
            u64(vmPageBytes));
  }
  return s5 +
      (off - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes) -
          u64(vmPageBytes) - u64(vmPageBytes));
}

@bare
u64 elfCefPlaceLibcMemset(u64 s, u64 bias) {
  fatClose();
  final u64 buf = fileBufBase();
  u64 i = u64(0);
  while (i < u64(7)) {
    Pointer<u8>.fromAddress(buf + i).value =
        Pointer<u8>.fromAddress(Rodata.addressOf(elfStrLibcSo) + i).value;
    i = i + u64(1);
  }
  final u64 pn = fatParseAt(buf, u64(7));
  if (pn > u64(fatErrOk)) {
    return u64(elfDlopenRetBadArg);
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    fatReportError(fs);
    return u64(elfDlopenRetNotFound);
  }
  fatOpenLine();
  final u64 hdr = allocFrame();
  if (hdr < u64(1)) {
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch = allocFrame();
  if (scratch < u64(1)) {
    final u64 back = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), back);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  vmZeroFrame(hdr);
  vmZeroFrame(scratch);
  final u64 bytes = fatMeta(u64(fatMetaFileBytes));
  if (bytes < u64(64)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  if (bytes > u64(elfImageMax)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  u64 want = bytes;
  if (want > u64(vmPageBytes)) {
    want = u64(vmPageBytes);
  }
  if (elfReadSectors(
          u64(0), (want + u64(511)) >> u64(elfSectorShift), hdr) >
      u64(0)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 cs = elfDlopenCheckHdr(hdr);
  if (cs > u64(0)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return cs;
  }
  // Resolve faces from the RX LOAD. Our tiny LIBC keeps hash /
  // dynsym / dynstr / dynamic / text in one LOAD; the file offset
  // may be 0x1000 while vaddr is 0 — copy that LOAD into [scratch].
  final u64 phoff = elfU64(hdr + u64(elfOffPhoff));
  final u64 phnum = elfU16(hdr + u64(elfOffPhnum));
  u64 dynVa = u64(0);
  u64 dynsz = u64(0);
  u64 textOff = u64(0);
  u64 textVa = u64(0);
  u64 textFsz = u64(0);
  i = u64(0);
  while (i < phnum) {
    final u64 ph = hdr + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtDynamic)) {
      dynVa = elfU64(ph + u64(elfPhOffVaddr));
      dynsz = elfU64(ph + u64(elfPhOffFilesz));
    }
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 flags = elfU32(ph + u64(elfPhOffFlags));
      if ((flags & u64(elfPfX)) > u64(0)) {
        textOff = elfU64(ph + u64(elfPhOffOffset));
        textVa = elfU64(ph + u64(elfPhOffVaddr));
        textFsz = elfU64(ph + u64(elfPhOffFilesz));
      }
    }
    i = i + u64(1);
  }
  if (dynsz < u64(elfDynSize)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  if (dynsz > u64(2048)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  if (textFsz < u64(1)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  // ADR-0180: four-hundred-face LIBC RX may span six pages.
  // Cap at 24 KiB. Bodies are read via offset, not a contiguous img VA.
  if (textFsz >
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch2 = allocFrame();
  if (scratch2 < u64(1)) {
    final u64 b1 = freeFrame(scratch);
    final u64 b2 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b1 + b2);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch3 = allocFrame();
  if (scratch3 < u64(1)) {
    final u64 b0 = freeFrame(scratch3);
    final u64 b1 = freeFrame(scratch2);
    final u64 b2 = freeFrame(scratch);
    final u64 b3 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  vmZeroFrame(scratch);
  vmZeroFrame(scratch2);
  vmZeroFrame(scratch3);
  final u64 scratch4 = allocFrame();
  if (scratch4 < u64(1)) {
    final u64 b0 = freeFrame(scratch4);
    final u64 b1 = freeFrame(scratch3);
    final u64 b2 = freeFrame(scratch2);
    final u64 b3 = freeFrame(scratch);
    final u64 b4 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch5 = allocFrame();
  if (scratch5 < u64(1)) {
    final u64 b0 = freeFrame(scratch5);
    final u64 b1 = freeFrame(scratch4);
    final u64 b2 = freeFrame(scratch3);
    final u64 b3 = freeFrame(scratch2);
    final u64 b4 = freeFrame(scratch);
    final u64 b5 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch6 = allocFrame();
  if (scratch6 < u64(1)) {
    final u64 b0 = freeFrame(scratch6);
    final u64 b1 = freeFrame(scratch5);
    final u64 b2 = freeFrame(scratch4);
    final u64 b3 = freeFrame(scratch3);
    final u64 b4 = freeFrame(scratch2);
    final u64 b5 = freeFrame(scratch);
    final u64 b6 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  vmZeroFrame(scratch4);
  vmZeroFrame(scratch5);
  vmZeroFrame(scratch6);
  // [hdr] is expendable now — phdr fields are in locals. Use it as the
  // sector scratch for elfDlopenCopy.
  u64 page0 = textFsz;
  if (page0 > u64(vmPageBytes)) {
    page0 = u64(vmPageBytes);
  }
  if (elfDlopenCopy(scratch, textOff, page0, hdr) > u64(0)) {
    final u64 b0 = freeFrame(scratch3);
    final u64 b1 = freeFrame(scratch2);
    final u64 b2 = freeFrame(scratch);
    final u64 b3 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  if (textFsz > u64(vmPageBytes)) {
    u64 page1 = textFsz - u64(vmPageBytes);
    if (page1 > u64(vmPageBytes)) {
      page1 = u64(vmPageBytes);
    }
    if (elfDlopenCopy(scratch2, textOff + u64(vmPageBytes), page1, hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch3);
      final u64 b1 = freeFrame(scratch2);
      final u64 b2 = freeFrame(scratch);
      final u64 b3 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  if (textFsz > (u64(vmPageBytes) + u64(vmPageBytes))) {
    u64 page2 = textFsz - u64(vmPageBytes) - u64(vmPageBytes);
    if (page2 > u64(vmPageBytes)) {
      page2 = u64(vmPageBytes);
    }
    if (elfDlopenCopy(
            scratch3,
            textOff + u64(vmPageBytes) + u64(vmPageBytes),
            page2,
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  if (textFsz > (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {
    u64 page3 = textFsz - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes);
    if (page3 > u64(vmPageBytes)) {
      page3 = u64(vmPageBytes);
    }
    if (elfDlopenCopy(
            scratch4,
            textOff + u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes),
            page3,
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  if (textFsz >
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes))) {
    u64 page4 = textFsz - u64(vmPageBytes) - u64(vmPageBytes) -
        u64(vmPageBytes) - u64(vmPageBytes);
    if (page4 > u64(vmPageBytes)) {
      page4 = u64(vmPageBytes);
    }
    if (elfDlopenCopy(
            scratch5,
            textOff + u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
                u64(vmPageBytes),
            page4,
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  if (textFsz >
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes) + u64(vmPageBytes))) {
    if (elfDlopenCopy(
            scratch6,
            textOff + u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
                u64(vmPageBytes) + u64(vmPageBytes),
            textFsz - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes) -
                u64(vmPageBytes) - u64(vmPageBytes),
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  // LOAD image base: VA textVa sits at scratch for offsets < 4 KiB.
  // ADR-0180: metadata may span page0..page3 (≤16 KiB); .text may reach page5.
  final u64 img = scratch - textVa;
  final u64 metaPages = u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
      u64(vmPageBytes);
  if ((dynVa + dynsz) > (textVa + metaPages)) {
    final u64 b0 = freeFrame(scratch6);
    final u64 b1 = freeFrame(scratch5);
    final u64 b2 = freeFrame(scratch4);
    final u64 b3 = freeFrame(scratch3);
    final u64 b4 = freeFrame(scratch2);
    final u64 b5 = freeFrame(scratch);
    final u64 b6 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  u64 strtab = u64(0);
  u64 symtab = u64(0);
  u64 strsz = u64(0);
  u64 nsym = u64(0);
  u64 t = u64(0);
  while ((t + u64(elfDynSize)) <= dynsz) {
    final u64 tag = elfU64(
        elfDlopenRxPa(scratch, scratch2, scratch3, scratch4, scratch5, scratch6, textVa, dynVa + t));
    final u64 val = elfU64(elfDlopenRxPa(
        scratch, scratch2, scratch3, scratch4, scratch5, scratch6, textVa, dynVa + t + u64(8)));
    if (tag < u64(1)) {
      t = dynsz;
    } else {
      if (tag == u64(elfDtStrtab)) {
        strtab = val;
      }
      if (tag == u64(elfDtSymtab)) {
        symtab = val;
      }
      if (tag == u64(elfDtStrsz)) {
        strsz = val;
      }
      if (tag == u64(elfDtHash)) {
        nsym = elfU32(elfDlopenRxPa(
            scratch, scratch2, scratch3, scratch4, scratch5, scratch6, textVa, val + u64(4)));
      }
      t = t + u64(elfDynSize);
    }
  }
  if (strsz < u64(8)) {
    final u64 b0 = freeFrame(scratch3);
    final u64 b1 = freeFrame(scratch2);
    final u64 b2 = freeFrame(scratch);
    final u64 b3 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  if (nsym < u64(2)) {
    nsym = u64(elfDlopenSymMax);
  }
  if (nsym > u64(elfDlopenSymMax)) {
    nsym = u64(elfDlopenSymMax);
  }
  // Bind measured high-traffic UND (ADR-0170 five required; ADR-0172
  // expands to fifty — extras skip when LIBC.SO lacks the export so
  // cef-plt / cef-und keep PASSing). Bodies live in the face slab;
  // each official PLT slot gets a 12-byte trampoline.
  final u64 facePa = u64(elfCefPlantPa) + u64(elfCefUndFaceOff);
  final u64 face3Pa = u64(elfCefPlantPa) + u64(elfCefUnd3FaceOff);
  u64 faceUsed = u64(0);
  u64 face3Used = u64(0);
  u64 bound = u64(0);
  u64 phase = u64(0);
  while (phase < u64(elfCefUnd2BatchWant)) {
    u64 namePtr = u64(0);
    u64 nameLen = u64(0);
    u64 pltOff = u64(0);
    u64 pltVa = u64(0);
    if (phase == u64(0)) {
      namePtr = Rodata.addressOf(elfStrMemset);
      nameLen = u64(7);
      pltOff = u64(elfCefMemsetPltOff);
      pltVa = u64(elfCefMemsetPltVaddr);
    }
    if (phase == u64(1)) {
      namePtr = Rodata.addressOf(elfStrMemcpy);
      nameLen = u64(7);
      pltOff = u64(elfCefMemcpyPltOff);
      pltVa = u64(elfCefMemcpyPltVaddr);
    }
    if (phase == u64(2)) {
      namePtr = Rodata.addressOf(elfStrMemmove);
      nameLen = u64(8);
      pltOff = u64(elfCefMemmovePltOff);
      pltVa = u64(elfCefMemmovePltVaddr);
    }
    if (phase == u64(3)) {
      namePtr = Rodata.addressOf(elfStrStrlen);
      nameLen = u64(7);
      pltOff = u64(elfCefStrlenPltOff);
      pltVa = u64(elfCefStrlenPltVaddr);
    }
    if (phase == u64(4)) {
      namePtr = Rodata.addressOf(elfStrMemcmp);
      nameLen = u64(7);
      pltOff = u64(elfCefMemcmpPltOff);
      pltVa = u64(elfCefMemcmpPltVaddr);
    }
    if (phase == u64(5)) {
      namePtr = Rodata.addressOf(elfStrBcmp);
      nameLen = u64(5);
      pltOff = u64(elfCefBcmpPltOff);
      pltVa = u64(elfCefBcmpPltVaddr);
    }
    if (phase == u64(6)) {
      namePtr = Rodata.addressOf(elfStrMemchr);
      nameLen = u64(7);
      pltOff = u64(elfCefMemchrPltOff);
      pltVa = u64(elfCefMemchrPltVaddr);
    }
    if (phase == u64(7)) {
      namePtr = Rodata.addressOf(elfStrStrncmp);
      nameLen = u64(8);
      pltOff = u64(elfCefStrncmpPltOff);
      pltVa = u64(elfCefStrncmpPltVaddr);
    }
    if (phase == u64(8)) {
      namePtr = Rodata.addressOf(elfStrStrcpy);
      nameLen = u64(7);
      pltOff = u64(elfCefStrcpyPltOff);
      pltVa = u64(elfCefStrcpyPltVaddr);
    }
    if (phase == u64(9)) {
      namePtr = Rodata.addressOf(elfStrStrcmp);
      nameLen = u64(7);
      pltOff = u64(elfCefStrcmpPltOff);
      pltVa = u64(elfCefStrcmpPltVaddr);
    }
    if (phase == u64(10)) {
      namePtr = Rodata.addressOf(elfStrStrnlen);
      nameLen = u64(8);
      pltOff = u64(elfCefStrnlenPltOff);
      pltVa = u64(elfCefStrnlenPltVaddr);
    }
    if (phase == u64(11)) {
      namePtr = Rodata.addressOf(elfStrStrncpy);
      nameLen = u64(8);
      pltOff = u64(elfCefStrncpyPltOff);
      pltVa = u64(elfCefStrncpyPltVaddr);
    }
    if (phase == u64(12)) {
      namePtr = Rodata.addressOf(elfStrStrchr);
      nameLen = u64(7);
      pltOff = u64(elfCefStrchrPltOff);
      pltVa = u64(elfCefStrchrPltVaddr);
    }
    if (phase == u64(13)) {
      namePtr = Rodata.addressOf(elfStrStrrchr);
      nameLen = u64(8);
      pltOff = u64(elfCefStrrchrPltOff);
      pltVa = u64(elfCefStrrchrPltVaddr);
    }
    if (phase == u64(14)) {
      namePtr = Rodata.addressOf(elfStrStrstr);
      nameLen = u64(7);
      pltOff = u64(elfCefStrstrPltOff);
      pltVa = u64(elfCefStrstrPltVaddr);
    }
    if (phase == u64(15)) {
      namePtr = Rodata.addressOf(elfStrStrcat);
      nameLen = u64(7);
      pltOff = u64(elfCefStrcatPltOff);
      pltVa = u64(elfCefStrcatPltVaddr);
    }
    if (phase == u64(16)) {
      namePtr = Rodata.addressOf(elfStrStrspn);
      nameLen = u64(7);
      pltOff = u64(elfCefStrspnPltOff);
      pltVa = u64(elfCefStrspnPltVaddr);
    }
    if (phase == u64(17)) {
      namePtr = Rodata.addressOf(elfStrStrcspn);
      nameLen = u64(8);
      pltOff = u64(elfCefStrcspnPltOff);
      pltVa = u64(elfCefStrcspnPltVaddr);
    }
    if (phase == u64(18)) {
      namePtr = Rodata.addressOf(elfStrStrncat);
      nameLen = u64(8);
      pltOff = u64(elfCefStrncatPltOff);
      pltVa = u64(elfCefStrncatPltVaddr);
    }
    if (phase == u64(19)) {
      namePtr = Rodata.addressOf(elfStrStrcasecmp);
      nameLen = u64(11);
      pltOff = u64(elfCefStrcasecmpPltOff);
      pltVa = u64(elfCefStrcasecmpPltVaddr);
    }
    if (phase == u64(20)) {
      namePtr = Rodata.addressOf(elfStrStrncasecmp);
      nameLen = u64(12);
      pltOff = u64(elfCefStrncasecmpPltOff);
      pltVa = u64(elfCefStrncasecmpPltVaddr);
    }
    if (phase == u64(21)) {
      namePtr = Rodata.addressOf(elfStrWcsncmp);
      nameLen = u64(8);
      pltOff = u64(elfCefWcsncmpPltOff);
      pltVa = u64(elfCefWcsncmpPltVaddr);
    }
    if (phase == u64(22)) {
      namePtr = Rodata.addressOf(elfStrWcslen);
      nameLen = u64(7);
      pltOff = u64(elfCefWcslenPltOff);
      pltVa = u64(elfCefWcslenPltVaddr);
    }
    if (phase == u64(23)) {
      namePtr = Rodata.addressOf(elfStrWmemchr);
      nameLen = u64(8);
      pltOff = u64(elfCefWmemchrPltOff);
      pltVa = u64(elfCefWmemchrPltVaddr);
    }
    if (phase == u64(24)) {
      namePtr = Rodata.addressOf(elfStrWcscmp);
      nameLen = u64(7);
      pltOff = u64(elfCefWcscmpPltOff);
      pltVa = u64(elfCefWcscmpPltVaddr);
    }
    if (phase == u64(25)) {
      namePtr = Rodata.addressOf(elfStrWmemcmp);
      nameLen = u64(8);
      pltOff = u64(elfCefWmemcmpPltOff);
      pltVa = u64(elfCefWmemcmpPltVaddr);
    }
    if (phase == u64(26)) {
      namePtr = Rodata.addressOf(elfStrWcschr);
      nameLen = u64(7);
      pltOff = u64(elfCefWcschrPltOff);
      pltVa = u64(elfCefWcschrPltVaddr);
    }
    if (phase == u64(27)) {
      namePtr = Rodata.addressOf(elfStrIswdigit);
      nameLen = u64(9);
      pltOff = u64(elfCefIswdigitPltOff);
      pltVa = u64(elfCefIswdigitPltVaddr);
    }
    if (phase == u64(28)) {
      namePtr = Rodata.addressOf(elfStrIswalnum);
      nameLen = u64(9);
      pltOff = u64(elfCefIswalnumPltOff);
      pltVa = u64(elfCefIswalnumPltVaddr);
    }
    if (phase == u64(29)) {
      namePtr = Rodata.addressOf(elfStrWcspbrk);
      nameLen = u64(8);
      pltOff = u64(elfCefWcspbrkPltOff);
      pltVa = u64(elfCefWcspbrkPltVaddr);
    }
    if (phase == u64(30)) {
      namePtr = Rodata.addressOf(elfStrWcscpy);
      nameLen = u64(7);
      pltOff = u64(elfCefWcscpyPltOff);
      pltVa = u64(elfCefWcscpyPltVaddr);
    }
    if (phase == u64(31)) {
      namePtr = Rodata.addressOf(elfStrTowupper);
      nameLen = u64(9);
      pltOff = u64(elfCefTowupperPltOff);
      pltVa = u64(elfCefTowupperPltVaddr);
    }
    if (phase == u64(32)) {
      namePtr = Rodata.addressOf(elfStrTowlower);
      nameLen = u64(9);
      pltOff = u64(elfCefTowlowerPltOff);
      pltVa = u64(elfCefTowlowerPltVaddr);
    }
    if (phase == u64(33)) {
      namePtr = Rodata.addressOf(elfStrStrtol);
      nameLen = u64(7);
      pltOff = u64(elfCefStrtolPltOff);
      pltVa = u64(elfCefStrtolPltVaddr);
    }
    if (phase == u64(34)) {
      namePtr = Rodata.addressOf(elfStrStrtoul);
      nameLen = u64(8);
      pltOff = u64(elfCefStrtoulPltOff);
      pltVa = u64(elfCefStrtoulPltVaddr);
    }
    if (phase == u64(35)) {
      namePtr = Rodata.addressOf(elfStrStrtoll);
      nameLen = u64(8);
      pltOff = u64(elfCefStrtollPltOff);
      pltVa = u64(elfCefStrtollPltVaddr);
    }
    if (phase == u64(36)) {
      namePtr = Rodata.addressOf(elfStrStrtoull);
      nameLen = u64(9);
      pltOff = u64(elfCefStrtoullPltOff);
      pltVa = u64(elfCefStrtoullPltVaddr);
    }
    if (phase == u64(37)) {
      namePtr = Rodata.addressOf(elfStrSchedYield);
      nameLen = u64(12);
      pltOff = u64(elfCefSchedYieldPltOff);
      pltVa = u64(elfCefSchedYieldPltVaddr);
    }
    if (phase == u64(38)) {
      namePtr = Rodata.addressOf(elfStrGetpid);
      nameLen = u64(7);
      pltOff = u64(elfCefGetpidPltOff);
      pltVa = u64(elfCefGetpidPltVaddr);
    }
    if (phase == u64(39)) {
      namePtr = Rodata.addressOf(elfStrGetpagesize);
      nameLen = u64(12);
      pltOff = u64(elfCefGetpagesizePltOff);
      pltVa = u64(elfCefGetpagesizePltVaddr);
    }
    if (phase == u64(40)) {
      namePtr = Rodata.addressOf(elfStrNanf);
      nameLen = u64(5);
      pltOff = u64(elfCefNanfPltOff);
      pltVa = u64(elfCefNanfPltVaddr);
    }
    if (phase == u64(41)) {
      namePtr = Rodata.addressOf(elfStrNan);
      nameLen = u64(4);
      pltOff = u64(elfCefNanPltOff);
      pltVa = u64(elfCefNanPltVaddr);
    }
    if (phase == u64(42)) {
      namePtr = Rodata.addressOf(elfStrGetenv);
      nameLen = u64(7);
      pltOff = u64(elfCefGetenvPltOff);
      pltVa = u64(elfCefGetenvPltVaddr);
    }
    if (phase == u64(43)) {
      namePtr = Rodata.addressOf(elfStrGetauxval);
      nameLen = u64(10);
      pltOff = u64(elfCefGetauxvalPltOff);
      pltVa = u64(elfCefGetauxvalPltVaddr);
    }
    if (phase == u64(44)) {
      namePtr = Rodata.addressOf(elfStrTime);
      nameLen = u64(5);
      pltOff = u64(elfCefTimePltOff);
      pltVa = u64(elfCefTimePltVaddr);
    }
    if (phase == u64(45)) {
      namePtr = Rodata.addressOf(elfStrUsleep);
      nameLen = u64(7);
      pltOff = u64(elfCefUsleepPltOff);
      pltVa = u64(elfCefUsleepPltVaddr);
    }
    if (phase == u64(46)) {
      namePtr = Rodata.addressOf(elfStrGetuid);
      nameLen = u64(7);
      pltOff = u64(elfCefGetuidPltOff);
      pltVa = u64(elfCefGetuidPltVaddr);
    }
    if (phase == u64(47)) {
      namePtr = Rodata.addressOf(elfStrIsatty);
      nameLen = u64(7);
      pltOff = u64(elfCefIsattyPltOff);
      pltVa = u64(elfCefIsattyPltVaddr);
    }
    if (phase == u64(48)) {
      namePtr = Rodata.addressOf(elfStrRand);
      nameLen = u64(5);
      pltOff = u64(elfCefRandPltOff);
      pltVa = u64(elfCefRandPltVaddr);
    }
    if (phase == u64(49)) {
      namePtr = Rodata.addressOf(elfStrGeteuid);
      nameLen = u64(8);
      pltOff = u64(elfCefGeteuidPltOff);
      pltVa = u64(elfCefGeteuidPltVaddr);
    }
    if (phase == u64(50)) {
      namePtr = Rodata.addressOf(elfStrFloorf);
      nameLen = u64(7);
      pltOff = u64(elfCefFloorfPltOff);
      pltVa = u64(elfCefFloorfPltVaddr);
    }
    if (phase == u64(51)) {
      namePtr = Rodata.addressOf(elfStrCeilf);
      nameLen = u64(6);
      pltOff = u64(elfCefCeilfPltOff);
      pltVa = u64(elfCefCeilfPltVaddr);
    }
    if (phase == u64(52)) {
      namePtr = Rodata.addressOf(elfStrTruncf);
      nameLen = u64(7);
      pltOff = u64(elfCefTruncfPltOff);
      pltVa = u64(elfCefTruncfPltVaddr);
    }
    if (phase == u64(53)) {
      namePtr = Rodata.addressOf(elfStrRoundf);
      nameLen = u64(7);
      pltOff = u64(elfCefRoundfPltOff);
      pltVa = u64(elfCefRoundfPltVaddr);
    }
    if (phase == u64(54)) {
      namePtr = Rodata.addressOf(elfStrFloor);
      nameLen = u64(6);
      pltOff = u64(elfCefFloorPltOff);
      pltVa = u64(elfCefFloorPltVaddr);
    }
    if (phase == u64(55)) {
      namePtr = Rodata.addressOf(elfStrCeil);
      nameLen = u64(5);
      pltOff = u64(elfCefCeilPltOff);
      pltVa = u64(elfCefCeilPltVaddr);
    }
    if (phase == u64(56)) {
      namePtr = Rodata.addressOf(elfStrTrunc);
      nameLen = u64(6);
      pltOff = u64(elfCefTruncPltOff);
      pltVa = u64(elfCefTruncPltVaddr);
    }
    if (phase == u64(57)) {
      namePtr = Rodata.addressOf(elfStrRound);
      nameLen = u64(6);
      pltOff = u64(elfCefRoundPltOff);
      pltVa = u64(elfCefRoundPltVaddr);
    }
    if (phase == u64(58)) {
      namePtr = Rodata.addressOf(elfStrPutchar);
      nameLen = u64(8);
      pltOff = u64(elfCefPutcharPltOff);
      pltVa = u64(elfCefPutcharPltVaddr);
    }
    if (phase == u64(59)) {
      namePtr = Rodata.addressOf(elfStrPuts);
      nameLen = u64(5);
      pltOff = u64(elfCefPutsPltOff);
      pltVa = u64(elfCefPutsPltVaddr);
    }
    if (phase == u64(60)) {
      namePtr = Rodata.addressOf(elfStrSrand);
      nameLen = u64(6);
      pltOff = u64(elfCefSrandPltOff);
      pltVa = u64(elfCefSrandPltVaddr);
    }
    if (phase == u64(61)) {
      namePtr = Rodata.addressOf(elfStrGetppid);
      nameLen = u64(8);
      pltOff = u64(elfCefGetppidPltOff);
      pltVa = u64(elfCefGetppidPltVaddr);
    }
    if (phase == u64(62)) {
      namePtr = Rodata.addressOf(elfStrSleep);
      nameLen = u64(6);
      pltOff = u64(elfCefSleepPltOff);
      pltVa = u64(elfCefSleepPltVaddr);
    }
    if (phase == u64(63)) {
      namePtr = Rodata.addressOf(elfStrWrite);
      nameLen = u64(6);
      pltOff = u64(elfCefWritePltOff);
      pltVa = u64(elfCefWritePltVaddr);
    }
    if (phase == u64(64)) {
      namePtr = Rodata.addressOf(elfStrRead);
      nameLen = u64(5);
      pltOff = u64(elfCefReadPltOff);
      pltVa = u64(elfCefReadPltVaddr);
    }
    if (phase == u64(65)) {
      namePtr = Rodata.addressOf(elfStrAbort);
      nameLen = u64(6);
      pltOff = u64(elfCefAbortPltOff);
      pltVa = u64(elfCefAbortPltVaddr);
    }
    if (phase == u64(66)) {
      namePtr = Rodata.addressOf(elfStrExit);
      nameLen = u64(5);
      pltOff = u64(elfCefExitPltOff);
      pltVa = u64(elfCefExitPltVaddr);
    }
    if (phase == u64(67)) {
      namePtr = Rodata.addressOf(elfStrUExit);
      nameLen = u64(6);
      pltOff = u64(elfCefUExitPltOff);
      pltVa = u64(elfCefUExitPltVaddr);
    }
    if (phase == u64(68)) {
      namePtr = Rodata.addressOf(elfStrUnlink);
      nameLen = u64(7);
      pltOff = u64(elfCefUnlinkPltOff);
      pltVa = u64(elfCefUnlinkPltVaddr);
    }
    if (phase == u64(69)) {
      namePtr = Rodata.addressOf(elfStrRename);
      nameLen = u64(7);
      pltOff = u64(elfCefRenamePltOff);
      pltVa = u64(elfCefRenamePltVaddr);
    }
    if (phase == u64(70)) {
      namePtr = Rodata.addressOf(elfStrMkdir);
      nameLen = u64(6);
      pltOff = u64(elfCefMkdirPltOff);
      pltVa = u64(elfCefMkdirPltVaddr);
    }
    if (phase == u64(71)) {
      namePtr = Rodata.addressOf(elfStrRmdir);
      nameLen = u64(6);
      pltOff = u64(elfCefRmdirPltOff);
      pltVa = u64(elfCefRmdirPltVaddr);
    }
    if (phase == u64(72)) {
      namePtr = Rodata.addressOf(elfStrAccess);
      nameLen = u64(7);
      pltOff = u64(elfCefAccessPltOff);
      pltVa = u64(elfCefAccessPltVaddr);
    }
    if (phase == u64(73)) {
      namePtr = Rodata.addressOf(elfStrChmod);
      nameLen = u64(6);
      pltOff = u64(elfCefChmodPltOff);
      pltVa = u64(elfCefChmodPltVaddr);
    }
    if (phase == u64(74)) {
      namePtr = Rodata.addressOf(elfStrFileno);
      nameLen = u64(7);
      pltOff = u64(elfCefFilenoPltOff);
      pltVa = u64(elfCefFilenoPltVaddr);
    }
    if (phase == u64(75)) {
      namePtr = Rodata.addressOf(elfStrFeof);
      nameLen = u64(5);
      pltOff = u64(elfCefFeofPltOff);
      pltVa = u64(elfCefFeofPltVaddr);
    }
    if (phase == u64(76)) {
      namePtr = Rodata.addressOf(elfStrFerror);
      nameLen = u64(7);
      pltOff = u64(elfCefFerrorPltOff);
      pltVa = u64(elfCefFerrorPltVaddr);
    }
    if (phase == u64(77)) {
      namePtr = Rodata.addressOf(elfStrFflush);
      nameLen = u64(7);
      pltOff = u64(elfCefFflushPltOff);
      pltVa = u64(elfCefFflushPltVaddr);
    }
    if (phase == u64(78)) {
      namePtr = Rodata.addressOf(elfStrGethostname);
      nameLen = u64(12);
      pltOff = u64(elfCefGethostnamePltOff);
      pltVa = u64(elfCefGethostnamePltVaddr);
    }
    if (phase == u64(79)) {
      namePtr = Rodata.addressOf(elfStrMunmap);
      nameLen = u64(7);
      pltOff = u64(elfCefMunmapPltOff);
      pltVa = u64(elfCefMunmapPltVaddr);
    }
    if (phase == u64(80)) {
      namePtr = Rodata.addressOf(elfStrMprotect);
      nameLen = u64(9);
      pltOff = u64(elfCefMprotectPltOff);
      pltVa = u64(elfCefMprotectPltVaddr);
    }
    if (phase == u64(81)) {
      namePtr = Rodata.addressOf(elfStrAlarm);
      nameLen = u64(6);
      pltOff = u64(elfCefAlarmPltOff);
      pltVa = u64(elfCefAlarmPltVaddr);
    }
    if (phase == u64(82)) {
      namePtr = Rodata.addressOf(elfStrPause);
      nameLen = u64(6);
      pltOff = u64(elfCefPausePltOff);
      pltVa = u64(elfCefPausePltVaddr);
    }
    if (phase == u64(83)) {
      namePtr = Rodata.addressOf(elfStrKill);
      nameLen = u64(5);
      pltOff = u64(elfCefKillPltOff);
      pltVa = u64(elfCefKillPltVaddr);
    }
    if (phase == u64(84)) {
      namePtr = Rodata.addressOf(elfStrDup);
      nameLen = u64(4);
      pltOff = u64(elfCefDupPltOff);
      pltVa = u64(elfCefDupPltVaddr);
    }
    if (phase == u64(85)) {
      namePtr = Rodata.addressOf(elfStrDup2);
      nameLen = u64(5);
      pltOff = u64(elfCefDup2PltOff);
      pltVa = u64(elfCefDup2PltVaddr);
    }
    if (phase == u64(86)) {
      namePtr = Rodata.addressOf(elfStrPipe);
      nameLen = u64(5);
      pltOff = u64(elfCefPipePltOff);
      pltVa = u64(elfCefPipePltVaddr);
    }
    if (phase == u64(87)) {
      namePtr = Rodata.addressOf(elfStrGetpriority);
      nameLen = u64(12);
      pltOff = u64(elfCefGetpriorityPltOff);
      pltVa = u64(elfCefGetpriorityPltVaddr);
    }
    if (phase == u64(88)) {
      namePtr = Rodata.addressOf(elfStrSetpriority);
      nameLen = u64(12);
      pltOff = u64(elfCefSetpriorityPltOff);
      pltVa = u64(elfCefSetpriorityPltVaddr);
    }
    if (phase == u64(89)) {
      namePtr = Rodata.addressOf(elfStrSinf);
      nameLen = u64(5);
      pltOff = u64(elfCefSinfPltOff);
      pltVa = u64(elfCefSinfPltVaddr);
    }
    if (phase == u64(90)) {
      namePtr = Rodata.addressOf(elfStrCosf);
      nameLen = u64(5);
      pltOff = u64(elfCefCosfPltOff);
      pltVa = u64(elfCefCosfPltVaddr);
    }
    if (phase == u64(91)) {
      namePtr = Rodata.addressOf(elfStrTanf);
      nameLen = u64(5);
      pltOff = u64(elfCefTanfPltOff);
      pltVa = u64(elfCefTanfPltVaddr);
    }
    if (phase == u64(92)) {
      namePtr = Rodata.addressOf(elfStrExpf);
      nameLen = u64(5);
      pltOff = u64(elfCefExpfPltOff);
      pltVa = u64(elfCefExpfPltVaddr);
    }
    if (phase == u64(93)) {
      namePtr = Rodata.addressOf(elfStrLogf);
      nameLen = u64(5);
      pltOff = u64(elfCefLogfPltOff);
      pltVa = u64(elfCefLogfPltVaddr);
    }
    if (phase == u64(94)) {
      namePtr = Rodata.addressOf(elfStrPowf);
      nameLen = u64(5);
      pltOff = u64(elfCefPowfPltOff);
      pltVa = u64(elfCefPowfPltVaddr);
    }
    if (phase == u64(95)) {
      namePtr = Rodata.addressOf(elfStrFmodf);
      nameLen = u64(6);
      pltOff = u64(elfCefFmodfPltOff);
      pltVa = u64(elfCefFmodfPltVaddr);
    }
    if (phase == u64(96)) {
      namePtr = Rodata.addressOf(elfStrSocket);
      nameLen = u64(7);
      pltOff = u64(elfCefSocketPltOff);
      pltVa = u64(elfCefSocketPltVaddr);
    }
    if (phase == u64(97)) {
      namePtr = Rodata.addressOf(elfStrSysconf);
      nameLen = u64(8);
      pltOff = u64(elfCefSysconfPltOff);
      pltVa = u64(elfCefSysconfPltVaddr);
    }
    if (phase == u64(98)) {
      namePtr = Rodata.addressOf(elfStrHypotf);
      nameLen = u64(7);
      pltOff = u64(elfCefHypotfPltOff);
      pltVa = u64(elfCefHypotfPltVaddr);
    }
    if (phase == u64(99)) {
      namePtr = Rodata.addressOf(elfStrNearbyintf);
      nameLen = u64(11);
      pltOff = u64(elfCefNearbyintfPltOff);
      pltVa = u64(elfCefNearbyintfPltVaddr);
    }
    if (phase == u64(100)) {
      namePtr = Rodata.addressOf(elfStrSin);
      nameLen = u64(3);
      pltOff = u64(elfCefSinPltOff);
      pltVa = u64(elfCefSinPltVaddr);
    }
    if (phase == u64(101)) {
      namePtr = Rodata.addressOf(elfStrCos);
      nameLen = u64(3);
      pltOff = u64(elfCefCosPltOff);
      pltVa = u64(elfCefCosPltVaddr);
    }
    if (phase == u64(102)) {
      namePtr = Rodata.addressOf(elfStrTan);
      nameLen = u64(3);
      pltOff = u64(elfCefTanPltOff);
      pltVa = u64(elfCefTanPltVaddr);
    }
    if (phase == u64(103)) {
      namePtr = Rodata.addressOf(elfStrAsin);
      nameLen = u64(4);
      pltOff = u64(elfCefAsinPltOff);
      pltVa = u64(elfCefAsinPltVaddr);
    }
    if (phase == u64(104)) {
      namePtr = Rodata.addressOf(elfStrAcos);
      nameLen = u64(4);
      pltOff = u64(elfCefAcosPltOff);
      pltVa = u64(elfCefAcosPltVaddr);
    }
    if (phase == u64(105)) {
      namePtr = Rodata.addressOf(elfStrAtan);
      nameLen = u64(4);
      pltOff = u64(elfCefAtanPltOff);
      pltVa = u64(elfCefAtanPltVaddr);
    }
    if (phase == u64(106)) {
      namePtr = Rodata.addressOf(elfStrAtan2);
      nameLen = u64(5);
      pltOff = u64(elfCefAtan2PltOff);
      pltVa = u64(elfCefAtan2PltVaddr);
    }
    if (phase == u64(107)) {
      namePtr = Rodata.addressOf(elfStrExp);
      nameLen = u64(3);
      pltOff = u64(elfCefExpPltOff);
      pltVa = u64(elfCefExpPltVaddr);
    }
    if (phase == u64(108)) {
      namePtr = Rodata.addressOf(elfStrLog);
      nameLen = u64(3);
      pltOff = u64(elfCefLogPltOff);
      pltVa = u64(elfCefLogPltVaddr);
    }
    if (phase == u64(109)) {
      namePtr = Rodata.addressOf(elfStrExp2);
      nameLen = u64(4);
      pltOff = u64(elfCefExp2PltOff);
      pltVa = u64(elfCefExp2PltVaddr);
    }
    if (phase == u64(110)) {
      namePtr = Rodata.addressOf(elfStrLog2);
      nameLen = u64(4);
      pltOff = u64(elfCefLog2PltOff);
      pltVa = u64(elfCefLog2PltVaddr);
    }
    if (phase == u64(111)) {
      namePtr = Rodata.addressOf(elfStrPow);
      nameLen = u64(3);
      pltOff = u64(elfCefPowPltOff);
      pltVa = u64(elfCefPowPltVaddr);
    }
    if (phase == u64(112)) {
      namePtr = Rodata.addressOf(elfStrHypot);
      nameLen = u64(5);
      pltOff = u64(elfCefHypotPltOff);
      pltVa = u64(elfCefHypotPltVaddr);
    }
    if (phase == u64(113)) {
      namePtr = Rodata.addressOf(elfStrSinh);
      nameLen = u64(4);
      pltOff = u64(elfCefSinhPltOff);
      pltVa = u64(elfCefSinhPltVaddr);
    }
    if (phase == u64(114)) {
      namePtr = Rodata.addressOf(elfStrCosh);
      nameLen = u64(4);
      pltOff = u64(elfCefCoshPltOff);
      pltVa = u64(elfCefCoshPltVaddr);
    }
    if (phase == u64(115)) {
      namePtr = Rodata.addressOf(elfStrTanh);
      nameLen = u64(4);
      pltOff = u64(elfCefTanhPltOff);
      pltVa = u64(elfCefTanhPltVaddr);
    }
    if (phase == u64(116)) {
      namePtr = Rodata.addressOf(elfStrAsinf);
      nameLen = u64(5);
      pltOff = u64(elfCefAsinfPltOff);
      pltVa = u64(elfCefAsinfPltVaddr);
    }
    if (phase == u64(117)) {
      namePtr = Rodata.addressOf(elfStrAcosf);
      nameLen = u64(5);
      pltOff = u64(elfCefAcosfPltOff);
      pltVa = u64(elfCefAcosfPltVaddr);
    }
    if (phase == u64(118)) {
      namePtr = Rodata.addressOf(elfStrAtanf);
      nameLen = u64(5);
      pltOff = u64(elfCefAtanfPltOff);
      pltVa = u64(elfCefAtanfPltVaddr);
    }
    if (phase == u64(119)) {
      namePtr = Rodata.addressOf(elfStrAtan2f);
      nameLen = u64(6);
      pltOff = u64(elfCefAtan2fPltOff);
      pltVa = u64(elfCefAtan2fPltVaddr);
    }
    if (phase == u64(120)) {
      namePtr = Rodata.addressOf(elfStrSinhf);
      nameLen = u64(5);
      pltOff = u64(elfCefSinhfPltOff);
      pltVa = u64(elfCefSinhfPltVaddr);
    }
    if (phase == u64(121)) {
      namePtr = Rodata.addressOf(elfStrCoshf);
      nameLen = u64(5);
      pltOff = u64(elfCefCoshfPltOff);
      pltVa = u64(elfCefCoshfPltVaddr);
    }
    if (phase == u64(122)) {
      namePtr = Rodata.addressOf(elfStrTanhf);
      nameLen = u64(5);
      pltOff = u64(elfCefTanhfPltOff);
      pltVa = u64(elfCefTanhfPltVaddr);
    }
    if (phase == u64(123)) {
      namePtr = Rodata.addressOf(elfStrExp2f);
      nameLen = u64(5);
      pltOff = u64(elfCefExp2fPltOff);
      pltVa = u64(elfCefExp2fPltVaddr);
    }
    if (phase == u64(124)) {
      namePtr = Rodata.addressOf(elfStrLog2f);
      nameLen = u64(5);
      pltOff = u64(elfCefLog2fPltOff);
      pltVa = u64(elfCefLog2fPltVaddr);
    }
    if (phase == u64(125)) {
      namePtr = Rodata.addressOf(elfStrLog10);
      nameLen = u64(5);
      pltOff = u64(elfCefLog10PltOff);
      pltVa = u64(elfCefLog10PltVaddr);
    }
    if (phase == u64(126)) {
      namePtr = Rodata.addressOf(elfStrLog10f);
      nameLen = u64(6);
      pltOff = u64(elfCefLog10fPltOff);
      pltVa = u64(elfCefLog10fPltVaddr);
    }
    if (phase == u64(127)) {
      namePtr = Rodata.addressOf(elfStrRint);
      nameLen = u64(4);
      pltOff = u64(elfCefRintPltOff);
      pltVa = u64(elfCefRintPltVaddr);
    }
    if (phase == u64(128)) {
      namePtr = Rodata.addressOf(elfStrRintf);
      nameLen = u64(5);
      pltOff = u64(elfCefRintfPltOff);
      pltVa = u64(elfCefRintfPltVaddr);
    }
    if (phase == u64(129)) {
      namePtr = Rodata.addressOf(elfStrNearbyint);
      nameLen = u64(9);
      pltOff = u64(elfCefNearbyintPltOff);
      pltVa = u64(elfCefNearbyintPltVaddr);
    }
    if (phase == u64(130)) {
      namePtr = Rodata.addressOf(elfStrFma);
      nameLen = u64(3);
      pltOff = u64(elfCefFmaPltOff);
      pltVa = u64(elfCefFmaPltVaddr);
    }
    if (phase == u64(131)) {
      namePtr = Rodata.addressOf(elfStrFmaf);
      nameLen = u64(4);
      pltOff = u64(elfCefFmafPltOff);
      pltVa = u64(elfCefFmafPltVaddr);
    }
    if (phase == u64(132)) {
      namePtr = Rodata.addressOf(elfStrModf);
      nameLen = u64(4);
      pltOff = u64(elfCefModfPltOff);
      pltVa = u64(elfCefModfPltVaddr);
    }
    if (phase == u64(133)) {
      namePtr = Rodata.addressOf(elfStrModff);
      nameLen = u64(5);
      pltOff = u64(elfCefModffPltOff);
      pltVa = u64(elfCefModffPltVaddr);
    }
    if (phase == u64(134)) {
      namePtr = Rodata.addressOf(elfStrFrexp);
      nameLen = u64(5);
      pltOff = u64(elfCefFrexpPltOff);
      pltVa = u64(elfCefFrexpPltVaddr);
    }
    if (phase == u64(135)) {
      namePtr = Rodata.addressOf(elfStrFrexpf);
      nameLen = u64(6);
      pltOff = u64(elfCefFrexpfPltOff);
      pltVa = u64(elfCefFrexpfPltVaddr);
    }
    if (phase == u64(136)) {
      namePtr = Rodata.addressOf(elfStrLdexp);
      nameLen = u64(5);
      pltOff = u64(elfCefLdexpPltOff);
      pltVa = u64(elfCefLdexpPltVaddr);
    }
    if (phase == u64(137)) {
      namePtr = Rodata.addressOf(elfStrLdexpf);
      nameLen = u64(6);
      pltOff = u64(elfCefLdexpfPltOff);
      pltVa = u64(elfCefLdexpfPltVaddr);
    }
    if (phase == u64(138)) {
      namePtr = Rodata.addressOf(elfStrCbrt);
      nameLen = u64(4);
      pltOff = u64(elfCefCbrtPltOff);
      pltVa = u64(elfCefCbrtPltVaddr);
    }
    if (phase == u64(139)) {
      namePtr = Rodata.addressOf(elfStrCbrtf);
      nameLen = u64(5);
      pltOff = u64(elfCefCbrtfPltOff);
      pltVa = u64(elfCefCbrtfPltVaddr);
    }
    if (phase == u64(140)) {
      namePtr = Rodata.addressOf(elfStrNextafter);
      nameLen = u64(9);
      pltOff = u64(elfCefNextafterPltOff);
      pltVa = u64(elfCefNextafterPltVaddr);
    }
    if (phase == u64(141)) {
      namePtr = Rodata.addressOf(elfStrNextafterf);
      nameLen = u64(10);
      pltOff = u64(elfCefNextafterfPltOff);
      pltVa = u64(elfCefNextafterfPltVaddr);
    }
    if (phase == u64(142)) {
      namePtr = Rodata.addressOf(elfStrAcosh);
      nameLen = u64(5);
      pltOff = u64(elfCefAcoshPltOff);
      pltVa = u64(elfCefAcoshPltVaddr);
    }
    if (phase == u64(143)) {
      namePtr = Rodata.addressOf(elfStrAcoshf);
      nameLen = u64(6);
      pltOff = u64(elfCefAcoshfPltOff);
      pltVa = u64(elfCefAcoshfPltVaddr);
    }
    if (phase == u64(144)) {
      namePtr = Rodata.addressOf(elfStrAsinh);
      nameLen = u64(5);
      pltOff = u64(elfCefAsinhPltOff);
      pltVa = u64(elfCefAsinhPltVaddr);
    }
    if (phase == u64(145)) {
      namePtr = Rodata.addressOf(elfStrAsinhf);
      nameLen = u64(6);
      pltOff = u64(elfCefAsinhfPltOff);
      pltVa = u64(elfCefAsinhfPltVaddr);
    }
    if (phase == u64(146)) {
      namePtr = Rodata.addressOf(elfStrAtanh);
      nameLen = u64(5);
      pltOff = u64(elfCefAtanhPltOff);
      pltVa = u64(elfCefAtanhPltVaddr);
    }
    if (phase == u64(147)) {
      namePtr = Rodata.addressOf(elfStrAtanhf);
      nameLen = u64(6);
      pltOff = u64(elfCefAtanhfPltOff);
      pltVa = u64(elfCefAtanhfPltVaddr);
    }
    if (phase == u64(148)) {
      namePtr = Rodata.addressOf(elfStrScalbn);
      nameLen = u64(6);
      pltOff = u64(elfCefScalbnPltOff);
      pltVa = u64(elfCefScalbnPltVaddr);
    }
    if (phase == u64(149)) {
      namePtr = Rodata.addressOf(elfStrRemainder);
      nameLen = u64(9);
      pltOff = u64(elfCefRemainderPltOff);
      pltVa = u64(elfCefRemainderPltVaddr);
    }
    if (phase == u64(150)) {
      namePtr = Rodata.addressOf(elfStrIlogbf);
      nameLen = u64(6);
      pltOff = u64(elfCefIlogbfPltOff);
      pltVa = u64(elfCefIlogbfPltVaddr);
    }
    if (phase == u64(151)) {
      namePtr = Rodata.addressOf(elfStrErf);
      nameLen = u64(3);
      pltOff = u64(elfCefErfPltOff);
      pltVa = u64(elfCefErfPltVaddr);
    }
    if (phase == u64(152)) {
      namePtr = Rodata.addressOf(elfStrErff);
      nameLen = u64(4);
      pltOff = u64(elfCefErffPltOff);
      pltVa = u64(elfCefErffPltVaddr);
    }
    if (phase == u64(153)) {
      namePtr = Rodata.addressOf(elfStrLog1p);
      nameLen = u64(5);
      pltOff = u64(elfCefLog1pPltOff);
      pltVa = u64(elfCefLog1pPltVaddr);
    }
    if (phase == u64(154)) {
      namePtr = Rodata.addressOf(elfStrExpm1f);
      nameLen = u64(6);
      pltOff = u64(elfCefExpm1fPltOff);
      pltVa = u64(elfCefExpm1fPltVaddr);
    }
    if (phase == u64(155)) {
      namePtr = Rodata.addressOf(elfStrFread);
      nameLen = u64(5);
      pltOff = u64(elfCefFreadPltOff);
      pltVa = u64(elfCefFreadPltVaddr);
    }
    if (phase == u64(156)) {
      namePtr = Rodata.addressOf(elfStrFwrite);
      nameLen = u64(6);
      pltOff = u64(elfCefFwritePltOff);
      pltVa = u64(elfCefFwritePltVaddr);
    }
    if (phase == u64(157)) {
      namePtr = Rodata.addressOf(elfStrFseek);
      nameLen = u64(5);
      pltOff = u64(elfCefFseekPltOff);
      pltVa = u64(elfCefFseekPltVaddr);
    }
    if (phase == u64(158)) {
      namePtr = Rodata.addressOf(elfStrFtell);
      nameLen = u64(5);
      pltOff = u64(elfCefFtellPltOff);
      pltVa = u64(elfCefFtellPltVaddr);
    }
    if (phase == u64(159)) {
      namePtr = Rodata.addressOf(elfStrFgets);
      nameLen = u64(5);
      pltOff = u64(elfCefFgetsPltOff);
      pltVa = u64(elfCefFgetsPltVaddr);
    }
    if (phase == u64(160)) {
      namePtr = Rodata.addressOf(elfStrFclose);
      nameLen = u64(6);
      pltOff = u64(elfCefFclosePltOff);
      pltVa = u64(elfCefFclosePltVaddr);
    }
    if (phase == u64(161)) {
      namePtr = Rodata.addressOf(elfStrFputs);
      nameLen = u64(5);
      pltOff = u64(elfCefFputsPltOff);
      pltVa = u64(elfCefFputsPltVaddr);
    }
    if (phase == u64(162)) {
      namePtr = Rodata.addressOf(elfStrPrintf);
      nameLen = u64(6);
      pltOff = u64(elfCefPrintfPltOff);
      pltVa = u64(elfCefPrintfPltVaddr);
    }
    if (phase == u64(163)) {
      namePtr = Rodata.addressOf(elfStrSnprintf);
      nameLen = u64(8);
      pltOff = u64(elfCefSnprintfPltOff);
      pltVa = u64(elfCefSnprintfPltVaddr);
    }
    if (phase == u64(164)) {
      namePtr = Rodata.addressOf(elfStrVsnprintf);
      nameLen = u64(9);
      pltOff = u64(elfCefVsnprintfPltOff);
      pltVa = u64(elfCefVsnprintfPltVaddr);
    }
    if (phase == u64(165)) {
      namePtr = Rodata.addressOf(elfStrFprintf);
      nameLen = u64(7);
      pltOff = u64(elfCefFprintfPltOff);
      pltVa = u64(elfCefFprintfPltVaddr);
    }
    if (phase == u64(166)) {
      namePtr = Rodata.addressOf(elfStrSprintf);
      nameLen = u64(7);
      pltOff = u64(elfCefSprintfPltOff);
      pltVa = u64(elfCefSprintfPltVaddr);
    }
    if (phase == u64(167)) {
      namePtr = Rodata.addressOf(elfStrFputc);
      nameLen = u64(5);
      pltOff = u64(elfCefFputcPltOff);
      pltVa = u64(elfCefFputcPltVaddr);
    }
    if (phase == u64(168)) {
      namePtr = Rodata.addressOf(elfStrGetc);
      nameLen = u64(4);
      pltOff = u64(elfCefGetcPltOff);
      pltVa = u64(elfCefGetcPltVaddr);
    }
    if (phase == u64(169)) {
      namePtr = Rodata.addressOf(elfStrUngetc);
      nameLen = u64(6);
      pltOff = u64(elfCefUngetcPltOff);
      pltVa = u64(elfCefUngetcPltVaddr);
    }
    if (phase == u64(170)) {
      namePtr = Rodata.addressOf(elfStrSetvbuf);
      nameLen = u64(7);
      pltOff = u64(elfCefSetvbufPltOff);
      pltVa = u64(elfCefSetvbufPltVaddr);
    }
    if (phase == u64(171)) {
      namePtr = Rodata.addressOf(elfStrRewind);
      nameLen = u64(6);
      pltOff = u64(elfCefRewindPltOff);
      pltVa = u64(elfCefRewindPltVaddr);
    }
    if (phase == u64(172)) {
      namePtr = Rodata.addressOf(elfStrSetbuf);
      nameLen = u64(6);
      pltOff = u64(elfCefSetbufPltOff);
      pltVa = u64(elfCefSetbufPltVaddr);
    }
    if (phase == u64(173)) {
      namePtr = Rodata.addressOf(elfStrSigaction);
      nameLen = u64(9);
      pltOff = u64(elfCefSigactionPltOff);
      pltVa = u64(elfCefSigactionPltVaddr);
    }
    if (phase == u64(174)) {
      namePtr = Rodata.addressOf(elfStrRaise);
      nameLen = u64(5);
      pltOff = u64(elfCefRaisePltOff);
      pltVa = u64(elfCefRaisePltVaddr);
    }
    if (phase == u64(175)) {
      namePtr = Rodata.addressOf(elfStrNanosleep);
      nameLen = u64(9);
      pltOff = u64(elfCefNanosleepPltOff);
      pltVa = u64(elfCefNanosleepPltVaddr);
    }
    if (phase == u64(176)) {
      namePtr = Rodata.addressOf(elfStrClockGettime);
      nameLen = u64(13);
      pltOff = u64(elfCefClockGettimePltOff);
      pltVa = u64(elfCefClockGettimePltVaddr);
    }
    if (phase == u64(177)) {
      namePtr = Rodata.addressOf(elfStrSignal);
      nameLen = u64(6);
      pltOff = u64(elfCefSignalPltOff);
      pltVa = u64(elfCefSignalPltVaddr);
    }
    if (phase == u64(178)) {
      namePtr = Rodata.addressOf(elfStrStrerror);
      nameLen = u64(8);
      pltOff = u64(elfCefStrerrorPltOff);
      pltVa = u64(elfCefStrerrorPltVaddr);
    }
    if (phase == u64(179)) {
      namePtr = Rodata.addressOf(elfStrStrerrorR);
      nameLen = u64(10);
      pltOff = u64(elfCefStrerrorRPltOff);
      pltVa = u64(elfCefStrerrorRPltVaddr);
    }
    if (phase == u64(180)) {
      namePtr = Rodata.addressOf(elfStrUname);
      nameLen = u64(5);
      pltOff = u64(elfCefUnamePltOff);
      pltVa = u64(elfCefUnamePltVaddr);
    }
    if (phase == u64(181)) {
      namePtr = Rodata.addressOf(elfStrOpendir);
      nameLen = u64(7);
      pltOff = u64(elfCefOpendirPltOff);
      pltVa = u64(elfCefOpendirPltVaddr);
    }
    if (phase == u64(182)) {
      namePtr = Rodata.addressOf(elfStrClosedir);
      nameLen = u64(8);
      pltOff = u64(elfCefClosedirPltOff);
      pltVa = u64(elfCefClosedirPltVaddr);
    }
    if (phase == u64(183)) {
      namePtr = Rodata.addressOf(elfStrMadvise);
      nameLen = u64(7);
      pltOff = u64(elfCefMadvisePltOff);
      pltVa = u64(elfCefMadvisePltVaddr);
    }
    if (phase == u64(184)) {
      namePtr = Rodata.addressOf(elfStrTzset);
      nameLen = u64(5);
      pltOff = u64(elfCefTzsetPltOff);
      pltVa = u64(elfCefTzsetPltVaddr);
    }
    if (phase == u64(185)) {
      namePtr = Rodata.addressOf(elfStrFork);
      nameLen = u64(4);
      pltOff = u64(elfCefForkPltOff);
      pltVa = u64(elfCefForkPltVaddr);
    }
    if (phase == u64(186)) {
      namePtr = Rodata.addressOf(elfStrChdir);
      nameLen = u64(5);
      pltOff = u64(elfCefChdirPltOff);
      pltVa = u64(elfCefChdirPltVaddr);
    }
    if (phase == u64(187)) {
      namePtr = Rodata.addressOf(elfStrPoll);
      nameLen = u64(4);
      pltOff = u64(elfCefPollPltOff);
      pltVa = u64(elfCefPollPltVaddr);
    }
    if (phase == u64(188)) {
      namePtr = Rodata.addressOf(elfStrQsort);
      nameLen = u64(5);
      pltOff = u64(elfCefQsortPltOff);
      pltVa = u64(elfCefQsortPltVaddr);
    }
    if (phase == u64(189)) {
      namePtr = Rodata.addressOf(elfStrBind);
      nameLen = u64(4);
      pltOff = u64(elfCefBindPltOff);
      pltVa = u64(elfCefBindPltVaddr);
    }
    if (phase == u64(190)) {
      namePtr = Rodata.addressOf(elfStrListen);
      nameLen = u64(6);
      pltOff = u64(elfCefListenPltOff);
      pltVa = u64(elfCefListenPltVaddr);
    }
    if (phase == u64(191)) {
      namePtr = Rodata.addressOf(elfStrShutdown);
      nameLen = u64(8);
      pltOff = u64(elfCefShutdownPltOff);
      pltVa = u64(elfCefShutdownPltVaddr);
    }
    if (phase == u64(192)) {
      namePtr = Rodata.addressOf(elfStrConnect);
      nameLen = u64(7);
      pltOff = u64(elfCefConnectPltOff);
      pltVa = u64(elfCefConnectPltVaddr);
    }
    if (phase == u64(193)) {
      namePtr = Rodata.addressOf(elfStrAccept);
      nameLen = u64(6);
      pltOff = u64(elfCefAcceptPltOff);
      pltVa = u64(elfCefAcceptPltVaddr);
    }
    if (phase == u64(194)) {
      namePtr = Rodata.addressOf(elfStrWritev);
      nameLen = u64(6);
      pltOff = u64(elfCefWritevPltOff);
      pltVa = u64(elfCefWritevPltVaddr);
    }
    if (phase == u64(195)) {
      namePtr = Rodata.addressOf(elfStrSetsockopt);
      nameLen = u64(10);
      pltOff = u64(elfCefSetsockoptPltOff);
      pltVa = u64(elfCefSetsockoptPltVaddr);
    }
    if (phase == u64(196)) {
      namePtr = Rodata.addressOf(elfStrGetsockopt);
      nameLen = u64(10);
      pltOff = u64(elfCefGetsockoptPltOff);
      pltVa = u64(elfCefGetsockoptPltVaddr);
    }
    if (phase == u64(197)) {
      namePtr = Rodata.addressOf(elfStrGmtime);
      nameLen = u64(6);
      pltOff = u64(elfCefGmtimePltOff);
      pltVa = u64(elfCefGmtimePltVaddr);
    }
    if (phase == u64(198)) {
      namePtr = Rodata.addressOf(elfStrGmtimeR);
      nameLen = u64(8);
      pltOff = u64(elfCefGmtimeRPltOff);
      pltVa = u64(elfCefGmtimeRPltVaddr);
    }
    if (phase == u64(199)) {
      namePtr = Rodata.addressOf(elfStrMktime);
      nameLen = u64(6);
      pltOff = u64(elfCefMktimePltOff);
      pltVa = u64(elfCefMktimePltVaddr);
    }
    if (phase == u64(200)) {
      namePtr = Rodata.addressOf(elfStrSelect);
      nameLen = u64(6);
      pltOff = u64(elfCefSelectPltOff);
      pltVa = u64(elfCefSelectPltVaddr);
    }
    if (phase == u64(201)) {
      namePtr = Rodata.addressOf(elfStrIoctl);
      nameLen = u64(5);
      pltOff = u64(elfCefIoctlPltOff);
      pltVa = u64(elfCefIoctlPltVaddr);
    }
    if (phase == u64(202)) {
      namePtr = Rodata.addressOf(elfStrStrdup);
      nameLen = u64(6);
      pltOff = u64(elfCefStrdupPltOff);
      pltVa = u64(elfCefStrdupPltVaddr);
    }
    if (phase == u64(203)) {
      namePtr = Rodata.addressOf(elfStrStrtod);
      nameLen = u64(6);
      pltOff = u64(elfCefStrtodPltOff);
      pltVa = u64(elfCefStrtodPltVaddr);
    }
    if (phase == u64(204)) {
      namePtr = Rodata.addressOf(elfStrStrftime);
      nameLen = u64(8);
      pltOff = u64(elfCefStrftimePltOff);
      pltVa = u64(elfCefStrftimePltVaddr);
    }
    if (phase == u64(205)) {
      namePtr = Rodata.addressOf(elfStrFcntl);
      nameLen = u64(5);
      pltOff = u64(elfCefFcntlPltOff);
      pltVa = u64(elfCefFcntlPltVaddr);
    }
    if (phase == u64(206)) {
      namePtr = Rodata.addressOf(elfStrPrctl);
      nameLen = u64(5);
      pltOff = u64(elfCefPrctlPltOff);
      pltVa = u64(elfCefPrctlPltVaddr);
    }
    if (phase == u64(207)) {
      namePtr = Rodata.addressOf(elfStrSigemptyset);
      nameLen = u64(11);
      pltOff = u64(elfCefSigemptysetPltOff);
      pltVa = u64(elfCefSigemptysetPltVaddr);
    }
    if (phase == u64(208)) {
      namePtr = Rodata.addressOf(elfStrSigfillset);
      nameLen = u64(10);
      pltOff = u64(elfCefSigfillsetPltOff);
      pltVa = u64(elfCefSigfillsetPltVaddr);
    }
    if (phase == u64(209)) {
      namePtr = Rodata.addressOf(elfStrSigaddset);
      nameLen = u64(9);
      pltOff = u64(elfCefSigaddsetPltOff);
      pltVa = u64(elfCefSigaddsetPltVaddr);
    }
    if (phase == u64(210)) {
      namePtr = Rodata.addressOf(elfStrSigdelset);
      nameLen = u64(9);
      pltOff = u64(elfCefSigdelsetPltOff);
      pltVa = u64(elfCefSigdelsetPltVaddr);
    }
    if (phase == u64(211)) {
      namePtr = Rodata.addressOf(elfStrSigprocmask);
      nameLen = u64(11);
      pltOff = u64(elfCefSigprocmaskPltOff);
      pltVa = u64(elfCefSigprocmaskPltVaddr);
    }
    if (phase == u64(212)) {
      namePtr = Rodata.addressOf(elfStrSigaltstack);
      nameLen = u64(11);
      pltOff = u64(elfCefSigaltstackPltOff);
      pltVa = u64(elfCefSigaltstackPltVaddr);
    }
    if (phase == u64(213)) {
      namePtr = Rodata.addressOf(elfStrSemInit);
      nameLen = u64(8);
      pltOff = u64(elfCefSemInitPltOff);
      pltVa = u64(elfCefSemInitPltVaddr);
    }
    if (phase == u64(214)) {
      namePtr = Rodata.addressOf(elfStrSemWait);
      nameLen = u64(8);
      pltOff = u64(elfCefSemWaitPltOff);
      pltVa = u64(elfCefSemWaitPltVaddr);
    }
    if (phase == u64(215)) {
      namePtr = Rodata.addressOf(elfStrSemPost);
      nameLen = u64(8);
      pltOff = u64(elfCefSemPostPltOff);
      pltVa = u64(elfCefSemPostPltVaddr);
    }
    if (phase == u64(216)) {
      namePtr = Rodata.addressOf(elfStrSemDestroy);
      nameLen = u64(11);
      pltOff = u64(elfCefSemDestroyPltOff);
      pltVa = u64(elfCefSemDestroyPltVaddr);
    }
    if (phase == u64(217)) {
      namePtr = Rodata.addressOf(elfStrSemTimedwait);
      nameLen = u64(13);
      pltOff = u64(elfCefSemTimedwaitPltOff);
      pltVa = u64(elfCefSemTimedwaitPltVaddr);
    }
    if (phase == u64(218)) {
      namePtr = Rodata.addressOf(elfStrMmap64);
      nameLen = u64(6);
      pltOff = u64(elfCefMmap64PltOff);
      pltVa = u64(elfCefMmap64PltVaddr);
    }
    if (phase == u64(219)) {
      namePtr = Rodata.addressOf(elfStrOpen64);
      nameLen = u64(6);
      pltOff = u64(elfCefOpen64PltOff);
      pltVa = u64(elfCefOpen64PltVaddr);
    }
    if (phase == u64(220)) {
      namePtr = Rodata.addressOf(elfStrOpenat64);
      nameLen = u64(8);
      pltOff = u64(elfCefOpenat64PltOff);
      pltVa = u64(elfCefOpenat64PltVaddr);
    }
    if (phase == u64(221)) {
      namePtr = Rodata.addressOf(elfStrFopen64);
      nameLen = u64(7);
      pltOff = u64(elfCefFopen64PltOff);
      pltVa = u64(elfCefFopen64PltVaddr);
    }
    if (phase == u64(222)) {
      namePtr = Rodata.addressOf(elfStrFdopen);
      nameLen = u64(6);
      pltOff = u64(elfCefFdopenPltOff);
      pltVa = u64(elfCefFdopenPltVaddr);
    }
    if (phase == u64(223)) {
      namePtr = Rodata.addressOf(elfStrLseek64);
      nameLen = u64(7);
      pltOff = u64(elfCefLseek64PltOff);
      pltVa = u64(elfCefLseek64PltVaddr);
    }
    if (phase == u64(224)) {
      namePtr = Rodata.addressOf(elfStrPread64);
      nameLen = u64(7);
      pltOff = u64(elfCefPread64PltOff);
      pltVa = u64(elfCefPread64PltVaddr);
    }
    if (phase == u64(225)) {
      namePtr = Rodata.addressOf(elfStrPwrite64);
      nameLen = u64(8);
      pltOff = u64(elfCefPwrite64PltOff);
      pltVa = u64(elfCefPwrite64PltVaddr);
    }
    if (phase == u64(226)) {
      namePtr = Rodata.addressOf(elfStrFtruncate64);
      nameLen = u64(11);
      pltOff = u64(elfCefFtruncate64PltOff);
      pltVa = u64(elfCefFtruncate64PltVaddr);
    }
    if (phase == u64(227)) {
      namePtr = Rodata.addressOf(elfStrFseeko64);
      nameLen = u64(8);
      pltOff = u64(elfCefFseeko64PltOff);
      pltVa = u64(elfCefFseeko64PltVaddr);
    }
    if (phase == u64(228)) {
      namePtr = Rodata.addressOf(elfStrFtello64);
      nameLen = u64(8);
      pltOff = u64(elfCefFtello64PltOff);
      pltVa = u64(elfCefFtello64PltVaddr);
    }
    if (phase == u64(229)) {
      namePtr = Rodata.addressOf(elfStrMkstemp64);
      nameLen = u64(9);
      pltOff = u64(elfCefMkstemp64PltOff);
      pltVa = u64(elfCefMkstemp64PltVaddr);
    }
    if (phase == u64(230)) {
      namePtr = Rodata.addressOf(elfStrMkostemp64);
      nameLen = u64(10);
      pltOff = u64(elfCefMkostemp64PltOff);
      pltVa = u64(elfCefMkostemp64PltVaddr);
    }
    if (phase == u64(231)) {
      namePtr = Rodata.addressOf(elfStrMkdtemp);
      nameLen = u64(7);
      pltOff = u64(elfCefMkdtempPltOff);
      pltVa = u64(elfCefMkdtempPltVaddr);
    }
    if (phase == u64(232)) {
      namePtr = Rodata.addressOf(elfStrReaddir64);
      nameLen = u64(9);
      pltOff = u64(elfCefReaddir64PltOff);
      pltVa = u64(elfCefReaddir64PltVaddr);
    }
    if (phase == u64(233)) {
      namePtr = Rodata.addressOf(elfStrGetgrnam);
      nameLen = u64(8);
      pltOff = u64(elfCefGetgrnamPltOff);
      pltVa = u64(elfCefGetgrnamPltVaddr);
    }
    if (phase == u64(234)) {
      namePtr = Rodata.addressOf(elfStrGetgrgid);
      nameLen = u64(8);
      pltOff = u64(elfCefGetgrgidPltOff);
      pltVa = u64(elfCefGetgrgidPltVaddr);
    }
    if (phase == u64(235)) {
      namePtr = Rodata.addressOf(elfStrGetpwuid);
      nameLen = u64(8);
      pltOff = u64(elfCefGetpwuidPltOff);
      pltVa = u64(elfCefGetpwuidPltVaddr);
    }
    if (phase == u64(236)) {
      namePtr = Rodata.addressOf(elfStrEventfd);
      nameLen = u64(7);
      pltOff = u64(elfCefEventfdPltOff);
      pltVa = u64(elfCefEventfdPltVaddr);
    }
    if (phase == u64(237)) {
      namePtr = Rodata.addressOf(elfStrTimerfdCreate);
      nameLen = u64(14);
      pltOff = u64(elfCefTimerfdCreatePltOff);
      pltVa = u64(elfCefTimerfdCreatePltVaddr);
    }
    if (phase == u64(238)) {
      namePtr = Rodata.addressOf(elfStrTimerfdSettime);
      nameLen = u64(15);
      pltOff = u64(elfCefTimerfdSettimePltOff);
      pltVa = u64(elfCefTimerfdSettimePltVaddr);
    }
    if (phase == u64(239)) {
      namePtr = Rodata.addressOf(elfStrSchedSetscheduler);
      nameLen = u64(18);
      pltOff = u64(elfCefSchedSetschedulerPltOff);
      pltVa = u64(elfCefSchedSetschedulerPltVaddr);
    }
    if (phase == u64(240)) {
      namePtr = Rodata.addressOf(elfStrSchedGetscheduler);
      nameLen = u64(18);
      pltOff = u64(elfCefSchedGetschedulerPltOff);
      pltVa = u64(elfCefSchedGetschedulerPltVaddr);
    }
    if (phase == u64(241)) {
      namePtr = Rodata.addressOf(elfStrSchedGetparam);
      nameLen = u64(14);
      pltOff = u64(elfCefSchedGetparamPltOff);
      pltVa = u64(elfCefSchedGetparamPltVaddr);
    }
    if (phase == u64(242)) {
      namePtr = Rodata.addressOf(elfStrSchedGetaffinity);
      nameLen = u64(17);
      pltOff = u64(elfCefSchedGetaffinityPltOff);
      pltVa = u64(elfCefSchedGetaffinityPltVaddr);
    }
    if (phase == u64(243)) {
      namePtr = Rodata.addressOf(elfStrNewlocale);
      nameLen = u64(9);
      pltOff = u64(elfCefNewlocalePltOff);
      pltVa = u64(elfCefNewlocalePltVaddr);
    }
    if (phase == u64(244)) {
      namePtr = Rodata.addressOf(elfStrFreelocale);
      nameLen = u64(10);
      pltOff = u64(elfCefFreelocalePltOff);
      pltVa = u64(elfCefFreelocalePltVaddr);
    }
    if (phase == u64(245)) {
      namePtr = Rodata.addressOf(elfStrUselocale);
      nameLen = u64(9);
      pltOff = u64(elfCefUselocalePltOff);
      pltVa = u64(elfCefUselocalePltVaddr);
    }
    if (phase == u64(246)) {
      namePtr = Rodata.addressOf(elfStrStrtodL);
      nameLen = u64(8);
      pltOff = u64(elfCefStrtodLPltOff);
      pltVa = u64(elfCefStrtodLPltVaddr);
    }
    if (phase == u64(247)) {
      namePtr = Rodata.addressOf(elfStrSetlocale);
      nameLen = u64(9);
      pltOff = u64(elfCefSetlocalePltOff);
      pltVa = u64(elfCefSetlocalePltVaddr);
    }
    if (phase == u64(248)) {
      namePtr = Rodata.addressOf(elfStrLocaleconv);
      nameLen = u64(10);
      pltOff = u64(elfCefLocaleconvPltOff);
      pltVa = u64(elfCefLocaleconvPltVaddr);
    }
    if (phase == u64(249)) {
      namePtr = Rodata.addressOf(elfStrSetenv);
      nameLen = u64(6);
      pltOff = u64(elfCefSetenvPltOff);
      pltVa = u64(elfCefSetenvPltVaddr);
    }
    if (phase == u64(250)) {
      namePtr = Rodata.addressOf(elfStrUnsetenv);
      nameLen = u64(8);
      pltOff = u64(elfCefUnsetenvPltOff);
      pltVa = u64(elfCefUnsetenvPltVaddr);
    }
    if (phase == u64(251)) {
      namePtr = Rodata.addressOf(elfStrSetsid);
      nameLen = u64(6);
      pltOff = u64(elfCefSetsidPltOff);
      pltVa = u64(elfCefSetsidPltVaddr);
    }
    if (phase == u64(252)) {
      namePtr = Rodata.addressOf(elfStrReadlink);
      nameLen = u64(8);
      pltOff = u64(elfCefReadlinkPltOff);
      pltVa = u64(elfCefReadlinkPltVaddr);
    }
    if (phase == u64(253)) {
      namePtr = Rodata.addressOf(elfStrSetpgid);
      nameLen = u64(7);
      pltOff = u64(elfCefSetpgidPltOff);
      pltVa = u64(elfCefSetpgidPltVaddr);
    }
    if (phase == u64(254)) {
      namePtr = Rodata.addressOf(elfStrExecvp);
      nameLen = u64(6);
      pltOff = u64(elfCefExecvpPltOff);
      pltVa = u64(elfCefExecvpPltVaddr);
    }
    if (phase == u64(255)) {
      namePtr = Rodata.addressOf(elfStrExeclp);
      nameLen = u64(6);
      pltOff = u64(elfCefExeclpPltOff);
      pltVa = u64(elfCefExeclpPltVaddr);
    }
    if (phase == u64(256)) {
      namePtr = Rodata.addressOf(elfStrExecv);
      nameLen = u64(5);
      pltOff = u64(elfCefExecvPltOff);
      pltVa = u64(elfCefExecvPltVaddr);
    }
    if (phase == u64(257)) {
      namePtr = Rodata.addressOf(elfStrSystem);
      nameLen = u64(6);
      pltOff = u64(elfCefSystemPltOff);
      pltVa = u64(elfCefSystemPltVaddr);
    }
    if (phase == u64(258)) {
      namePtr = Rodata.addressOf(elfStrClone);
      nameLen = u64(5);
      pltOff = u64(elfCefClonePltOff);
      pltVa = u64(elfCefClonePltVaddr);
    }
    if (phase == u64(259)) {
      namePtr = Rodata.addressOf(elfStrVfprintf);
      nameLen = u64(8);
      pltOff = u64(elfCefVfprintfPltOff);
      pltVa = u64(elfCefVfprintfPltVaddr);
    }
    if (phase == u64(260)) {
      namePtr = Rodata.addressOf(elfStrFchmod);
      nameLen = u64(6);
      pltOff = u64(elfCefFchmodPltOff);
      pltVa = u64(elfCefFchmodPltVaddr);
    }
    if (phase == u64(261)) {
      namePtr = Rodata.addressOf(elfStrFreeaddrinfo);
      nameLen = u64(12);
      pltOff = u64(elfCefFreeaddrinfoPltOff);
      pltVa = u64(elfCefFreeaddrinfoPltVaddr);
    }
    if (phase == u64(262)) {
      namePtr = Rodata.addressOf(elfStrSocketpair);
      nameLen = u64(10);
      pltOff = u64(elfCefSocketpairPltOff);
      pltVa = u64(elfCefSocketpairPltVaddr);
    }
    if (phase == u64(263)) {
      namePtr = Rodata.addressOf(elfStrGetsockname);
      nameLen = u64(11);
      pltOff = u64(elfCefGetsocknamePltOff);
      pltVa = u64(elfCefGetsocknamePltVaddr);
    }
    if (phase == u64(264)) {
      namePtr = Rodata.addressOf(elfStrInetNtop);
      nameLen = u64(9);
      pltOff = u64(elfCefInetNtopPltOff);
      pltVa = u64(elfCefInetNtopPltVaddr);
    }
    if (phase == u64(265)) {
      namePtr = Rodata.addressOf(elfStrSendmsg);
      nameLen = u64(7);
      pltOff = u64(elfCefSendmsgPltOff);
      pltVa = u64(elfCefSendmsgPltVaddr);
    }
    if (phase == u64(266)) {
      namePtr = Rodata.addressOf(elfStrRecvmsg);
      nameLen = u64(7);
      pltOff = u64(elfCefRecvmsgPltOff);
      pltVa = u64(elfCefRecvmsgPltVaddr);
    }
    if (phase == u64(267)) {
      namePtr = Rodata.addressOf(elfStrGaiStrerror);
      nameLen = u64(12);
      pltOff = u64(elfCefGaiStrerrorPltOff);
      pltVa = u64(elfCefGaiStrerrorPltVaddr);
    }
    if (phase == u64(268)) {
      namePtr = Rodata.addressOf(elfStrGetifaddrs);
      nameLen = u64(10);
      pltOff = u64(elfCefGetifaddrsPltOff);
      pltVa = u64(elfCefGetifaddrsPltVaddr);
    }
    if (phase == u64(269)) {
      namePtr = Rodata.addressOf(elfStrFreeifaddrs);
      nameLen = u64(11);
      pltOff = u64(elfCefFreeifaddrsPltOff);
      pltVa = u64(elfCefFreeifaddrsPltVaddr);
    }
    if (phase == u64(270)) {
      namePtr = Rodata.addressOf(elfStrMremap);
      nameLen = u64(6);
      pltOff = u64(elfCefMremapPltOff);
      pltVa = u64(elfCefMremapPltVaddr);
    }
    if (phase == u64(271)) {
      namePtr = Rodata.addressOf(elfStrPpoll);
      nameLen = u64(5);
      pltOff = u64(elfCefPpollPltOff);
      pltVa = u64(elfCefPpollPltVaddr);
    }
    if (phase == u64(272)) {
      namePtr = Rodata.addressOf(elfStrOpenMemstream);
      nameLen = u64(14);
      pltOff = u64(elfCefOpenMemstreamPltOff);
      pltVa = u64(elfCefOpenMemstreamPltVaddr);
    }
    if (phase == u64(273)) {
      namePtr = Rodata.addressOf(elfStrEpollCreate1);
      nameLen = u64(13);
      pltOff = u64(elfCefEpollCreate1PltOff);
      pltVa = u64(elfCefEpollCreate1PltVaddr);
    }
    if (phase == u64(274)) {
      namePtr = Rodata.addressOf(elfStrEpollCreate);
      nameLen = u64(12);
      pltOff = u64(elfCefEpollCreatePltOff);
      pltVa = u64(elfCefEpollCreatePltVaddr);
    }
    if (phase == u64(275)) {
      namePtr = Rodata.addressOf(elfStrEpollCtl);
      nameLen = u64(9);
      pltOff = u64(elfCefEpollCtlPltOff);
      pltVa = u64(elfCefEpollCtlPltVaddr);
    }
    if (phase == u64(276)) {
      namePtr = Rodata.addressOf(elfStrEpollWait);
      nameLen = u64(10);
      pltOff = u64(elfCefEpollWaitPltOff);
      pltVa = u64(elfCefEpollWaitPltVaddr);
    }
    if (phase == u64(277)) {
      namePtr = Rodata.addressOf(elfStrMsync);
      nameLen = u64(5);
      pltOff = u64(elfCefMsyncPltOff);
      pltVa = u64(elfCefMsyncPltVaddr);
    }
    if (phase == u64(278)) {
      namePtr = Rodata.addressOf(elfStrPosixFallocate64);
      nameLen = u64(17);
      pltOff = u64(elfCefPosixFallocate64PltOff);
      pltVa = u64(elfCefPosixFallocate64PltVaddr);
    }
    if (phase == u64(279)) {
      namePtr = Rodata.addressOf(elfStrPosixFadvise64);
      nameLen = u64(15);
      pltOff = u64(elfCefPosixFadvise64PltOff);
      pltVa = u64(elfCefPosixFadvise64PltVaddr);
    }
    if (phase == u64(280)) {
      namePtr = Rodata.addressOf(elfStrFallocate64);
      nameLen = u64(11);
      pltOff = u64(elfCefFallocate64PltOff);
      pltVa = u64(elfCefFallocate64PltVaddr);
    }
    if (phase == u64(281)) {
      namePtr = Rodata.addressOf(elfStrSendfile64);
      nameLen = u64(10);
      pltOff = u64(elfCefSendfile64PltOff);
      pltVa = u64(elfCefSendfile64PltVaddr);
    }
    if (phase == u64(282)) {
      namePtr = Rodata.addressOf(elfStrFdatasync);
      nameLen = u64(9);
      pltOff = u64(elfCefFdatasyncPltOff);
      pltVa = u64(elfCefFdatasyncPltVaddr);
    }
    if (phase == u64(283)) {
      namePtr = Rodata.addressOf(elfStrUtimensat);
      nameLen = u64(9);
      pltOff = u64(elfCefUtimensatPltOff);
      pltVa = u64(elfCefUtimensatPltVaddr);
    }
    if (phase == u64(284)) {
      namePtr = Rodata.addressOf(elfStrFutimens);
      nameLen = u64(8);
      pltOff = u64(elfCefFutimensPltOff);
      pltVa = u64(elfCefFutimensPltVaddr);
    }
    if (phase == u64(285)) {
      namePtr = Rodata.addressOf(elfStrGetrlimit64);
      nameLen = u64(11);
      pltOff = u64(elfCefGetrlimit64PltOff);
      pltVa = u64(elfCefGetrlimit64PltVaddr);
    }
    if (phase == u64(286)) {
      namePtr = Rodata.addressOf(elfStrSetrlimit64);
      nameLen = u64(11);
      pltOff = u64(elfCefSetrlimit64PltOff);
      pltVa = u64(elfCefSetrlimit64PltVaddr);
    }
    if (phase == u64(287)) {
      namePtr = Rodata.addressOf(elfStrInotifyInit);
      nameLen = u64(12);
      pltOff = u64(elfCefInotifyInitPltOff);
      pltVa = u64(elfCefInotifyInitPltVaddr);
    }
    if (phase == u64(288)) {
      namePtr = Rodata.addressOf(elfStrInotifyAddWatch);
      nameLen = u64(17);
      pltOff = u64(elfCefInotifyAddWatchPltOff);
      pltVa = u64(elfCefInotifyAddWatchPltVaddr);
    }
    if (phase == u64(289)) {
      namePtr = Rodata.addressOf(elfStrInotifyRmWatch);
      nameLen = u64(16);
      pltOff = u64(elfCefInotifyRmWatchPltOff);
      pltVa = u64(elfCefInotifyRmWatchPltVaddr);
    }
    if (phase == u64(290)) {
      namePtr = Rodata.addressOf(elfStrTcflush);
      nameLen = u64(7);
      pltOff = u64(elfCefTcflushPltOff);
      pltVa = u64(elfCefTcflushPltVaddr);
    }
    if (phase == u64(291)) {
      namePtr = Rodata.addressOf(elfStrTcdrain);
      nameLen = u64(7);
      pltOff = u64(elfCefTcdrainPltOff);
      pltVa = u64(elfCefTcdrainPltVaddr);
    }
    if (phase == u64(292)) {
      namePtr = Rodata.addressOf(elfStrSyscall);
      nameLen = u64(7);
      pltOff = u64(elfCefSyscallPltOff);
      pltVa = u64(elfCefSyscallPltVaddr);
    }
    if (phase == u64(293)) {
      namePtr = Rodata.addressOf(elfStrRemove);
      nameLen = u64(6);
      pltOff = u64(elfCefRemovePltOff);
      pltVa = u64(elfCefRemovePltVaddr);
    }
    if (phase == u64(294)) {
      namePtr = Rodata.addressOf(elfStrPathconf);
      nameLen = u64(8);
      pltOff = u64(elfCefPathconfPltOff);
      pltVa = u64(elfCefPathconfPltVaddr);
    }
    if (phase == u64(295)) {
      namePtr = Rodata.addressOf(elfStrFsync);
      nameLen = u64(5);
      pltOff = u64(elfCefFsyncPltOff);
      pltVa = u64(elfCefFsyncPltVaddr);
    }
    if (phase == u64(296)) {
      namePtr = Rodata.addressOf(elfStrLink);
      nameLen = u64(4);
      pltOff = u64(elfCefLinkPltOff);
      pltVa = u64(elfCefLinkPltVaddr);
    }
    if (phase == u64(297)) {
      namePtr = Rodata.addressOf(elfStrSymlink);
      nameLen = u64(7);
      pltOff = u64(elfCefSymlinkPltOff);
      pltVa = u64(elfCefSymlinkPltVaddr);
    }
    if (phase == u64(298)) {
      namePtr = Rodata.addressOf(elfStrUnlinkat);
      nameLen = u64(8);
      pltOff = u64(elfCefUnlinkatPltOff);
      pltVa = u64(elfCefUnlinkatPltVaddr);
    }
    if (phase == u64(299)) {
      namePtr = Rodata.addressOf(elfStrGetcwd);
      nameLen = u64(6);
      pltOff = u64(elfCefGetcwdPltOff);
      pltVa = u64(elfCefGetcwdPltVaddr);
    }
    if (phase == u64(300)) {
      namePtr = Rodata.addressOf(elfStrRealpath);
      nameLen = u64(8);
      pltOff = u64(elfCefRealpathPltOff);
      pltVa = u64(elfCefRealpathPltVaddr);
    }
    if (phase == u64(301)) {
      namePtr = Rodata.addressOf(elfStrGettimeofday);
      nameLen = u64(12);
      pltOff = u64(elfCefGettimeofdayPltOff);
      pltVa = u64(elfCefGettimeofdayPltVaddr);
    }
    if (phase == u64(302)) {
      namePtr = Rodata.addressOf(elfStrDifftime);
      nameLen = u64(8);
      pltOff = u64(elfCefDifftimePltOff);
      pltVa = u64(elfCefDifftimePltVaddr);
    }
    if (phase == u64(303)) {
      namePtr = Rodata.addressOf(elfStrTimegm);
      nameLen = u64(6);
      pltOff = u64(elfCefTimegmPltOff);
      pltVa = u64(elfCefTimegmPltVaddr);
    }
    if (phase == u64(304)) {
      namePtr = Rodata.addressOf(elfStrWcstol);
      nameLen = u64(6);
      pltOff = u64(elfCefWcstolPltOff);
      pltVa = u64(elfCefWcstolPltVaddr);
    }
    if (phase == u64(305)) {
      namePtr = Rodata.addressOf(elfStrSwprintf);
      nameLen = u64(8);
      pltOff = u64(elfCefSwprintfPltOff);
      pltVa = u64(elfCefSwprintfPltVaddr);
    }
    if (phase == u64(306)) {
      namePtr = Rodata.addressOf(elfStrVswprintf);
      nameLen = u64(9);
      pltOff = u64(elfCefVswprintfPltOff);
      pltVa = u64(elfCefVswprintfPltVaddr);
    }
    if (phase == u64(307)) {
      namePtr = Rodata.addressOf(elfStrVasprintf);
      nameLen = u64(9);
      pltOff = u64(elfCefVasprintfPltOff);
      pltVa = u64(elfCefVasprintfPltVaddr);
    }
    if (phase == u64(308)) {
      namePtr = Rodata.addressOf(elfStrFmod);
      nameLen = u64(4);
      pltOff = u64(elfCefFmodPltOff);
      pltVa = u64(elfCefFmodPltVaddr);
    }
    if (phase == u64(309)) {
      namePtr = Rodata.addressOf(elfStrLog1pf);
      nameLen = u64(6);
      pltOff = u64(elfCefLog1pfPltOff);
      pltVa = u64(elfCefLog1pfPltVaddr);
    }
    if (phase == u64(310)) {
      namePtr = Rodata.addressOf(elfStrLround);
      nameLen = u64(6);
      pltOff = u64(elfCefLroundPltOff);
      pltVa = u64(elfCefLroundPltVaddr);
    }
    if (phase == u64(311)) {
      namePtr = Rodata.addressOf(elfStrLroundf);
      nameLen = u64(7);
      pltOff = u64(elfCefLroundfPltOff);
      pltVa = u64(elfCefLroundfPltVaddr);
    }
    if (phase == u64(312)) {
      namePtr = Rodata.addressOf(elfStrLlround);
      nameLen = u64(7);
      pltOff = u64(elfCefLlroundPltOff);
      pltVa = u64(elfCefLlroundPltVaddr);
    }
    if (phase == u64(313)) {
      namePtr = Rodata.addressOf(elfStrLlroundf);
      nameLen = u64(8);
      pltOff = u64(elfCefLlroundfPltOff);
      pltVa = u64(elfCefLlroundfPltVaddr);
    }
    if (phase == u64(314)) {
      namePtr = Rodata.addressOf(elfStrGetoptLong);
      nameLen = u64(11);
      pltOff = u64(elfCefGetoptLongPltOff);
      pltVa = u64(elfCefGetoptLongPltVaddr);
    }
    if (phase == u64(315)) {
      namePtr = Rodata.addressOf(elfStrWaitpid);
      nameLen = u64(7);
      pltOff = u64(elfCefWaitpidPltOff);
      pltVa = u64(elfCefWaitpidPltVaddr);
    }
    if (phase == u64(316)) {
      namePtr = Rodata.addressOf(elfStrWaitid);
      nameLen = u64(6);
      pltOff = u64(elfCefWaitidPltOff);
      pltVa = u64(elfCefWaitidPltVaddr);
    }
    if (phase == u64(317)) {
      namePtr = Rodata.addressOf(elfStrPipe2);
      nameLen = u64(5);
      pltOff = u64(elfCefPipe2PltOff);
      pltVa = u64(elfCefPipe2PltVaddr);
    }
    if (phase == u64(318)) {
      namePtr = Rodata.addressOf(elfStrFlock);
      nameLen = u64(5);
      pltOff = u64(elfCefFlockPltOff);
      pltVa = u64(elfCefFlockPltVaddr);
    }
    if (phase == u64(319)) {
      namePtr = Rodata.addressOf(elfStrLchown);
      nameLen = u64(6);
      pltOff = u64(elfCefLchownPltOff);
      pltVa = u64(elfCefLchownPltVaddr);
    }
    if (phase == u64(320)) {
      namePtr = Rodata.addressOf(elfStrUmask);
      nameLen = u64(5);
      pltOff = u64(elfCefUmaskPltOff);
      pltVa = u64(elfCefUmaskPltVaddr);
    }
    if (phase == u64(321)) {
      namePtr = Rodata.addressOf(elfStrMincore);
      nameLen = u64(7);
      pltOff = u64(elfCefMincorePltOff);
      pltVa = u64(elfCefMincorePltVaddr);
    }
    if (phase == u64(322)) {
      namePtr = Rodata.addressOf(elfStrDirfd);
      nameLen = u64(5);
      pltOff = u64(elfCefDirfdPltOff);
      pltVa = u64(elfCefDirfdPltVaddr);
    }
    if (phase == u64(323)) {
      namePtr = Rodata.addressOf(elfStrOpenlog);
      nameLen = u64(7);
      pltOff = u64(elfCefOpenlogPltOff);
      pltVa = u64(elfCefOpenlogPltVaddr);
    }
    if (phase == u64(324)) {
      namePtr = Rodata.addressOf(elfStrSyslog);
      nameLen = u64(6);
      pltOff = u64(elfCefSyslogPltOff);
      pltVa = u64(elfCefSyslogPltVaddr);
    }
    if (phase == u64(325)) {
      namePtr = Rodata.addressOf(elfStrCloselog);
      nameLen = u64(8);
      pltOff = u64(elfCefCloselogPltOff);
      pltVa = u64(elfCefCloselogPltVaddr);
    }
    if (phase == u64(326)) {
      namePtr = Rodata.addressOf(elfStrStatvfs64);
      nameLen = u64(9);
      pltOff = u64(elfCefStatvfs64PltOff);
      pltVa = u64(elfCefStatvfs64PltVaddr);
    }
    if (phase == u64(327)) {
      namePtr = Rodata.addressOf(elfStrStatfs64);
      nameLen = u64(8);
      pltOff = u64(elfCefStatfs64PltOff);
      pltVa = u64(elfCefStatfs64PltVaddr);
    }
    if (phase == u64(328)) {
      namePtr = Rodata.addressOf(elfStrFstatfs64);
      nameLen = u64(9);
      pltOff = u64(elfCefFstatfs64PltOff);
      pltVa = u64(elfCefFstatfs64PltVaddr);
    }
    if (phase == u64(329)) {
      namePtr = Rodata.addressOf(elfStrFnmatch);
      nameLen = u64(7);
      pltOff = u64(elfCefFnmatchPltOff);
      pltVa = u64(elfCefFnmatchPltVaddr);
    }
    if (phase == u64(330)) {
      namePtr = Rodata.addressOf(elfStrCreat64);
      nameLen = u64(7);
      pltOff = u64(elfCefCreat64PltOff);
      pltVa = u64(elfCefCreat64PltVaddr);
    }
    if (phase == u64(331)) {
      namePtr = Rodata.addressOf(elfStrFdopendir);
      nameLen = u64(9);
      pltOff = u64(elfCefFdopendirPltOff);
      pltVa = u64(elfCefFdopendirPltVaddr);
    }
    if (phase == u64(332)) {
      namePtr = Rodata.addressOf(elfStrWcrtomb);
      nameLen = u64(7);
      pltOff = u64(elfCefWcrtombPltOff);
      pltVa = u64(elfCefWcrtombPltVaddr);
    }
    if (phase == u64(333)) {
      namePtr = Rodata.addressOf(elfStrMbrtowc);
      nameLen = u64(7);
      pltOff = u64(elfCefMbrtowcPltOff);
      pltVa = u64(elfCefMbrtowcPltVaddr);
    }
    if (phase == u64(334)) {
      namePtr = Rodata.addressOf(elfStrWcsftime);
      nameLen = u64(8);
      pltOff = u64(elfCefWcsftimePltOff);
      pltVa = u64(elfCefWcsftimePltVaddr);
    }
    if (phase == u64(335)) {
      namePtr = Rodata.addressOf(elfStrStrndup);
      nameLen = u64(7);
      pltOff = u64(elfCefStrndupPltOff);
      pltVa = u64(elfCefStrndupPltVaddr);
    }
    if (phase == u64(336)) {
      namePtr = Rodata.addressOf(elfStrRandR);
      nameLen = u64(6);
      pltOff = u64(elfCefRandRPltOff);
      pltVa = u64(elfCefRandRPltVaddr);
    }
    if (phase == u64(337)) {
      namePtr = Rodata.addressOf(elfStrInitstateR);
      nameLen = u64(11);
      pltOff = u64(elfCefInitstateRPltOff);
      pltVa = u64(elfCefInitstateRPltVaddr);
    }
    if (phase == u64(338)) {
      namePtr = Rodata.addressOf(elfStrRandomR);
      nameLen = u64(8);
      pltOff = u64(elfCefRandomRPltOff);
      pltVa = u64(elfCefRandomRPltVaddr);
    }
    if (phase == u64(339)) {
      namePtr = Rodata.addressOf(elfStrLongjmp);
      nameLen = u64(7);
      pltOff = u64(elfCefLongjmpPltOff);
      pltVa = u64(elfCefLongjmpPltVaddr);
    }
    if (phase == u64(340)) {
      namePtr = Rodata.addressOf(elfStrUSetjmp);
      nameLen = u64(7);
      pltOff = u64(elfCefUSetjmpPltOff);
      pltVa = u64(elfCefUSetjmpPltVaddr);
    }
    if (phase == u64(341)) {
      namePtr = Rodata.addressOf(elfStrPthreadSelf);
      nameLen = u64(12);
      pltOff = u64(elfCefPthreadSelfPltOff);
      pltVa = u64(elfCefPthreadSelfPltVaddr);
    }
    if (phase == u64(342)) {
      namePtr = Rodata.addressOf(elfStrPthreadOnce);
      nameLen = u64(12);
      pltOff = u64(elfCefPthreadOncePltOff);
      pltVa = u64(elfCefPthreadOncePltVaddr);
    }
    if (phase == u64(343)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexInit);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadMutexInitPltOff);
      pltVa = u64(elfCefPthreadMutexInitPltVaddr);
    }
    if (phase == u64(344)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexLock);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadMutexLockPltOff);
      pltVa = u64(elfCefPthreadMutexLockPltVaddr);
    }
    if (phase == u64(345)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexUnlock);
      nameLen = u64(20);
      pltOff = u64(elfCefPthreadMutexUnlockPltOff);
      pltVa = u64(elfCefPthreadMutexUnlockPltVaddr);
    }
    if (phase == u64(346)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexDestroy);
      nameLen = u64(21);
      pltOff = u64(elfCefPthreadMutexDestroyPltOff);
      pltVa = u64(elfCefPthreadMutexDestroyPltVaddr);
    }
    if (phase == u64(347)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexTrylock);
      nameLen = u64(21);
      pltOff = u64(elfCefPthreadMutexTrylockPltOff);
      pltVa = u64(elfCefPthreadMutexTrylockPltVaddr);
    }
    if (phase == u64(348)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexattrInit);
      nameLen = u64(22);
      pltOff = u64(elfCefPthreadMutexattrInitPltOff);
      pltVa = u64(elfCefPthreadMutexattrInitPltVaddr);
    }
    if (phase == u64(349)) {
      namePtr = Rodata.addressOf(elfStrPthreadMutexattrDestroy);
      nameLen = u64(25);
      pltOff = u64(elfCefPthreadMutexattrDestroyPltOff);
      pltVa = u64(elfCefPthreadMutexattrDestroyPltVaddr);
    }
    if (phase == u64(350)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondInit);
      nameLen = u64(17);
      pltOff = u64(elfCefPthreadCondInitPltOff);
      pltVa = u64(elfCefPthreadCondInitPltVaddr);
    }
    if (phase == u64(351)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondWait);
      nameLen = u64(17);
      pltOff = u64(elfCefPthreadCondWaitPltOff);
      pltVa = u64(elfCefPthreadCondWaitPltVaddr);
    }
    if (phase == u64(352)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondTimedwait);
      nameLen = u64(22);
      pltOff = u64(elfCefPthreadCondTimedwaitPltOff);
      pltVa = u64(elfCefPthreadCondTimedwaitPltVaddr);
    }
    if (phase == u64(353)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondSignal);
      nameLen = u64(19);
      pltOff = u64(elfCefPthreadCondSignalPltOff);
      pltVa = u64(elfCefPthreadCondSignalPltVaddr);
    }
    if (phase == u64(354)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondBroadcast);
      nameLen = u64(22);
      pltOff = u64(elfCefPthreadCondBroadcastPltOff);
      pltVa = u64(elfCefPthreadCondBroadcastPltVaddr);
    }
    if (phase == u64(355)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondDestroy);
      nameLen = u64(20);
      pltOff = u64(elfCefPthreadCondDestroyPltOff);
      pltVa = u64(elfCefPthreadCondDestroyPltVaddr);
    }
    if (phase == u64(356)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondattrInit);
      nameLen = u64(21);
      pltOff = u64(elfCefPthreadCondattrInitPltOff);
      pltVa = u64(elfCefPthreadCondattrInitPltVaddr);
    }
    if (phase == u64(357)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondattrSetclock);
      nameLen = u64(25);
      pltOff = u64(elfCefPthreadCondattrSetclockPltOff);
      pltVa = u64(elfCefPthreadCondattrSetclockPltVaddr);
    }
    if (phase == u64(358)) {
      namePtr = Rodata.addressOf(elfStrPthreadCondattrDestroy);
      nameLen = u64(24);
      pltOff = u64(elfCefPthreadCondattrDestroyPltOff);
      pltVa = u64(elfCefPthreadCondattrDestroyPltVaddr);
    }
    if (phase == u64(359)) {
      namePtr = Rodata.addressOf(elfStrPthreadKeyCreate);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadKeyCreatePltOff);
      pltVa = u64(elfCefPthreadKeyCreatePltVaddr);
    }
    if (phase == u64(360)) {
      namePtr = Rodata.addressOf(elfStrPthreadKeyDelete);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadKeyDeletePltOff);
      pltVa = u64(elfCefPthreadKeyDeletePltVaddr);
    }
    if (phase == u64(361)) {
      namePtr = Rodata.addressOf(elfStrPthreadGetspecific);
      nameLen = u64(19);
      pltOff = u64(elfCefPthreadGetspecificPltOff);
      pltVa = u64(elfCefPthreadGetspecificPltVaddr);
    }
    if (phase == u64(362)) {
      namePtr = Rodata.addressOf(elfStrPthreadSetspecific);
      nameLen = u64(19);
      pltOff = u64(elfCefPthreadSetspecificPltOff);
      pltVa = u64(elfCefPthreadSetspecificPltVaddr);
    }
    if (phase == u64(363)) {
      namePtr = Rodata.addressOf(elfStrPthreadAttrInit);
      nameLen = u64(17);
      pltOff = u64(elfCefPthreadAttrInitPltOff);
      pltVa = u64(elfCefPthreadAttrInitPltVaddr);
    }
    if (phase == u64(364)) {
      namePtr = Rodata.addressOf(elfStrPthreadAttrDestroy);
      nameLen = u64(20);
      pltOff = u64(elfCefPthreadAttrDestroyPltOff);
      pltVa = u64(elfCefPthreadAttrDestroyPltVaddr);
    }
    if (phase == u64(365)) {
      namePtr = Rodata.addressOf(elfStrPthreadAttrSetstacksize);
      nameLen = u64(25);
      pltOff = u64(elfCefPthreadAttrSetstacksizePltOff);
      pltVa = u64(elfCefPthreadAttrSetstacksizePltVaddr);
    }
    if (phase == u64(366)) {
      namePtr = Rodata.addressOf(elfStrPthreadAttrSetdetachstate);
      nameLen = u64(27);
      pltOff = u64(elfCefPthreadAttrSetdetachstatePltOff);
      pltVa = u64(elfCefPthreadAttrSetdetachstatePltVaddr);
    }
    if (phase == u64(367)) {
      namePtr = Rodata.addressOf(elfStrPthreadAttrGetstack);
      nameLen = u64(21);
      pltOff = u64(elfCefPthreadAttrGetstackPltOff);
      pltVa = u64(elfCefPthreadAttrGetstackPltVaddr);
    }
    if (phase == u64(368)) {
      namePtr = Rodata.addressOf(elfStrPthreadAttrGetstacksize);
      nameLen = u64(25);
      pltOff = u64(elfCefPthreadAttrGetstacksizePltOff);
      pltVa = u64(elfCefPthreadAttrGetstacksizePltVaddr);
    }
    if (phase == u64(369)) {
      namePtr = Rodata.addressOf(elfStrPthreadCreate);
      nameLen = u64(14);
      pltOff = u64(elfCefPthreadCreatePltOff);
      pltVa = u64(elfCefPthreadCreatePltVaddr);
    }
    if (phase == u64(370)) {
      namePtr = Rodata.addressOf(elfStrPthreadJoin);
      nameLen = u64(12);
      pltOff = u64(elfCefPthreadJoinPltOff);
      pltVa = u64(elfCefPthreadJoinPltVaddr);
    }
    if (phase == u64(371)) {
      namePtr = Rodata.addressOf(elfStrPthreadDetach);
      nameLen = u64(14);
      pltOff = u64(elfCefPthreadDetachPltOff);
      pltVa = u64(elfCefPthreadDetachPltVaddr);
    }
    if (phase == u64(372)) {
      namePtr = Rodata.addressOf(elfStrPthreadSigmask);
      nameLen = u64(15);
      pltOff = u64(elfCefPthreadSigmaskPltOff);
      pltVa = u64(elfCefPthreadSigmaskPltVaddr);
    }
    if (phase == u64(373)) {
      namePtr = Rodata.addressOf(elfStrPthreadGetschedparam);
      nameLen = u64(21);
      pltOff = u64(elfCefPthreadGetschedparamPltOff);
      pltVa = u64(elfCefPthreadGetschedparamPltVaddr);
    }
    if (phase == u64(374)) {
      namePtr = Rodata.addressOf(elfStrPthreadSetnameNp);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadSetnameNpPltOff);
      pltVa = u64(elfCefPthreadSetnameNpPltVaddr);
    }
    if (phase == u64(375)) {
      namePtr = Rodata.addressOf(elfStrPthreadGetnameNp);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadGetnameNpPltOff);
      pltVa = u64(elfCefPthreadGetnameNpPltVaddr);
    }
    if (phase == u64(376)) {
      namePtr = Rodata.addressOf(elfStrPthreadKill);
      nameLen = u64(12);
      pltOff = u64(elfCefPthreadKillPltOff);
      pltVa = u64(elfCefPthreadKillPltVaddr);
    }
    if (phase == u64(377)) {
      namePtr = Rodata.addressOf(elfStrPthreadGetattrNp);
      nameLen = u64(18);
      pltOff = u64(elfCefPthreadGetattrNpPltOff);
      pltVa = u64(elfCefPthreadGetattrNpPltVaddr);
    }
    if (phase == u64(378)) {
      namePtr = Rodata.addressOf(elfStrPkeyMprotect);
      nameLen = u64(13);
      pltOff = u64(elfCefPkeyMprotectPltOff);
      pltVa = u64(elfCefPkeyMprotectPltVaddr);
    }
    if (phase == u64(379)) {
      namePtr = Rodata.addressOf(elfStrPkeyAlloc);
      nameLen = u64(10);
      pltOff = u64(elfCefPkeyAllocPltOff);
      pltVa = u64(elfCefPkeyAllocPltVaddr);
    }
    if (phase == u64(380)) {
      namePtr = Rodata.addressOf(elfStrPkeySet);
      nameLen = u64(8);
      pltOff = u64(elfCefPkeySetPltOff);
      pltVa = u64(elfCefPkeySetPltVaddr);
    }
    if (phase == u64(381)) {
      namePtr = Rodata.addressOf(elfStrXCxaFinalize);
      nameLen = u64(14);
      pltOff = u64(elfCefXCxaFinalizePltOff);
      pltVa = u64(elfCefXCxaFinalizePltVaddr);
    }
    if (phase == u64(382)) {
      namePtr = Rodata.addressOf(elfStrXCxaAtexit);
      nameLen = u64(12);
      pltOff = u64(elfCefXCxaAtexitPltOff);
      pltVa = u64(elfCefXCxaAtexitPltVaddr);
    }
    if (phase == u64(383)) {
      namePtr = Rodata.addressOf(elfStrXErrnoLocation);
      nameLen = u64(16);
      pltOff = u64(elfCefXErrnoLocationPltOff);
      pltVa = u64(elfCefXErrnoLocationPltVaddr);
    }
    if (phase == u64(384)) {
      namePtr = Rodata.addressOf(elfStrXCtypeBLoc);
      nameLen = u64(13);
      pltOff = u64(elfCefXCtypeBLocPltOff);
      pltVa = u64(elfCefXCtypeBLocPltVaddr);
    }
    if (phase == u64(385)) {
      namePtr = Rodata.addressOf(elfStrXCtypeTolowerLoc);
      nameLen = u64(19);
      pltOff = u64(elfCefXCtypeTolowerLocPltOff);
      pltVa = u64(elfCefXCtypeTolowerLocPltVaddr);
    }
    if (phase == u64(386)) {
      namePtr = Rodata.addressOf(elfStrXCtypeToupperLoc);
      nameLen = u64(19);
      pltOff = u64(elfCefXCtypeToupperLocPltOff);
      pltVa = u64(elfCefXCtypeToupperLocPltVaddr);
    }
    if (phase == u64(387)) {
      namePtr = Rodata.addressOf(elfStrXXpgStrerrorR);
      nameLen = u64(16);
      pltOff = u64(elfCefXXpgStrerrorRPltOff);
      pltVa = u64(elfCefXXpgStrerrorRPltVaddr);
    }
    if (phase == u64(388)) {
      namePtr = Rodata.addressOf(elfStrXCtypeGetMbCurMax);
      nameLen = u64(22);
      pltOff = u64(elfCefXCtypeGetMbCurMaxPltOff);
      pltVa = u64(elfCefXCtypeGetMbCurMaxPltVaddr);
    }
    if (phase == u64(389)) {
      namePtr = Rodata.addressOf(elfStrXCxaThreadAtexitImpl);
      nameLen = u64(24);
      pltOff = u64(elfCefXCxaThreadAtexitImplPltOff);
      pltVa = u64(elfCefXCxaThreadAtexitImplPltVaddr);
    }
    if (phase == u64(390)) {
      namePtr = Rodata.addressOf(elfStrXGetdelim);
      nameLen = u64(10);
      pltOff = u64(elfCefXGetdelimPltOff);
      pltVa = u64(elfCefXGetdelimPltVaddr);
    }
    if (phase == u64(391)) {
      namePtr = Rodata.addressOf(elfStrXLongjmpChk);
      nameLen = u64(13);
      pltOff = u64(elfCefXLongjmpChkPltOff);
      pltVa = u64(elfCefXLongjmpChkPltVaddr);
    }
    if (phase == u64(392)) {
      namePtr = Rodata.addressOf(elfStrXMbrlen);
      nameLen = u64(8);
      pltOff = u64(elfCefXMbrlenPltOff);
      pltVa = u64(elfCefXMbrlenPltVaddr);
    }
    if (phase == u64(393)) {
      namePtr = Rodata.addressOf(elfStrXRegisterAtfork);
      nameLen = u64(17);
      pltOff = u64(elfCefXRegisterAtforkPltOff);
      pltVa = u64(elfCefXRegisterAtforkPltVaddr);
    }
    if (phase == u64(394)) {
      namePtr = Rodata.addressOf(elfStrXSchedCpualloc);
      nameLen = u64(16);
      pltOff = u64(elfCefXSchedCpuallocPltOff);
      pltVa = u64(elfCefXSchedCpuallocPltVaddr);
    }
    if (phase == u64(395)) {
      namePtr = Rodata.addressOf(elfStrXSchedCpucount);
      nameLen = u64(16);
      pltOff = u64(elfCefXSchedCpucountPltOff);
      pltVa = u64(elfCefXSchedCpucountPltVaddr);
    }
    if (phase == u64(396)) {
      namePtr = Rodata.addressOf(elfStrXSchedCpufree);
      nameLen = u64(15);
      pltOff = u64(elfCefXSchedCpufreePltOff);
      pltVa = u64(elfCefXSchedCpufreePltVaddr);
    }
    if (phase == u64(397)) {
      namePtr = Rodata.addressOf(elfStrXStackChkFail);
      nameLen = u64(16);
      pltOff = u64(elfCefXStackChkFailPltOff);
      pltVa = u64(elfCefXStackChkFailPltVaddr);
    }
    if (phase == u64(398)) {
      namePtr = Rodata.addressOf(elfStrXTlsGetAddr);
      nameLen = u64(14);
      pltOff = u64(elfCefXTlsGetAddrPltOff);
      pltVa = u64(elfCefXTlsGetAddrPltVaddr);
    }
    if (phase == u64(399)) {
      namePtr = Rodata.addressOf(elfStrXUdivti3);
      nameLen = u64(9);
      pltOff = u64(elfCefXUdivti3PltOff);
      pltVa = u64(elfCefXUdivti3PltVaddr);
    }
    u64 stVal = u64(0xFFFFFFFFFFFFFFFF);
    u64 stSize = u64(0);
    u64 sidx = u64(1);
    while (sidx < nsym) {
      final u64 entVa = symtab + (sidx * u64(elfSymSize));
      final u64 ent = elfDlopenRxPa(scratch, scratch2, scratch3, scratch4, scratch5, scratch6, textVa, entVa);
      final u64 name = elfU32(ent);
      if ((name + nameLen) <= strsz) {
        final u64 nmPa = elfDlopenRxPa(
            scratch, scratch2, scratch3, scratch4, scratch5, scratch6, textVa, strtab + name);
        if (elfDlopenNameEq(nmPa, namePtr, nameLen) > u64(0)) {
          stVal = elfU64(ent + u64(8));
          stSize = elfU64(ent + u64(16));
          sidx = nsym;
        }
      }
      sidx = sidx + u64(1);
    }
    if (stVal > u64(0x7FFFFFFF)) {
      // Required first five refuse; extras are optional.
      if (phase < u64(elfCefUndBatchWant)) {
        final u64 b0 = freeFrame(scratch3);
        final u64 b1 = freeFrame(scratch2);
        final u64 b2 = freeFrame(scratch);
        final u64 b3 = freeFrame(hdr);
        elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
        fatClose();
        return u64(elfDlopenRetBadSo);
      }
      phase = phase + u64(1);
    } else {
      if (stVal < textVa) {
        final u64 b0 = freeFrame(scratch3);
        final u64 b1 = freeFrame(scratch2);
        final u64 b2 = freeFrame(scratch);
        final u64 b3 = freeFrame(hdr);
        elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
        fatClose();
        return u64(elfDlopenRetBadSo);
      }
      final u64 bodyOff = stVal - textVa;
      u64 bodyLen = stSize;
      if (bodyLen < u64(8)) {
        bodyLen = u64(8);
      }
      if (bodyLen > u64(elfCefMemsetBodyMax)) {
        bodyLen = u64(elfCefMemsetBodyMax);
      }
      if (phase >= u64(200)) {
        if (bodyLen > u64(elfCefUnd3BodyMax)) {
          bodyLen = u64(elfCefUnd3BodyMax);
        }
      }
      if ((bodyOff + bodyLen) > textFsz) {
        // Clamp to RX filesz — min-8 bump on a trailing leaf must not
        // BadSo the whole plant (ADR-0178). Zero remaining → treat as
        // missing for extras; required still refuses.
        if (bodyOff >= textFsz) {
          bodyLen = u64(0);
        } else {
          bodyLen = textFsz - bodyOff;
        }
      }
      if (bodyLen < u64(1)) {
        if (phase < u64(elfCefUndBatchWant)) {
          final u64 b0 = freeFrame(scratch3);
          final u64 b1 = freeFrame(scratch2);
          final u64 b2 = freeFrame(scratch);
          final u64 b3 = freeFrame(hdr);
          elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
          fatClose();
          return u64(elfDlopenRetBadSo);
        }
        phase = phase + u64(1);
      } else if (phase >= u64(200)) {
        if ((face3Used + bodyLen) > u64(elfCefUnd3FaceMax)) {
          final u64 b0 = freeFrame(scratch3);
          final u64 b1 = freeFrame(scratch2);
          final u64 b2 = freeFrame(scratch);
          final u64 b3 = freeFrame(hdr);
          elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
          fatClose();
          return u64(elfDlopenRetBadSo);
        }
        if ((pltOff + u64(elfCefPltTrampolineBytes)) >
            u64(elfCefPlantBytes)) {
          final u64 b0 = freeFrame(scratch3);
          final u64 b1 = freeFrame(scratch2);
          final u64 b2 = freeFrame(scratch);
          final u64 b3 = freeFrame(hdr);
          elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
          fatClose();
          return u64(elfDlopenRetBadSo);
        }
        final u64 dstBody = face3Pa + face3Used;
        i = u64(0);
        while (i < bodyLen) {
          final u64 srcVa = textVa + bodyOff + i;
          final u64 srcPa = elfDlopenRxPa(
              scratch,
              scratch2,
              scratch3,
              scratch4,
              scratch5,
              scratch6,
              textVa,
              srcVa);
          Pointer<u8>.fromAddress(dstBody + i).value =
              Pointer<u8>.fromAddress(srcPa).value;
          i = i + u64(1);
        }
        final u64 targetVa = bias + u64(elfCefUnd3FaceVaddr) + face3Used;
        elfCefWritePltTrampoline(u64(elfCefPlantPa) + pltOff, targetVa);
        face3Used = face3Used + bodyLen;
        while ((face3Used & u64(3)) > u64(0)) {
          face3Used = face3Used + u64(1);
        }
        bound = bound + u64(1);
        phase = phase + u64(1);
      } else if ((faceUsed + bodyLen) > u64(elfCefUndFaceMax)) {
        final u64 b0 = freeFrame(scratch3);
        final u64 b1 = freeFrame(scratch2);
        final u64 b2 = freeFrame(scratch);
        final u64 b3 = freeFrame(hdr);
        elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
        fatClose();
        return u64(elfDlopenRetBadSo);
      } else if ((pltOff + u64(elfCefPltTrampolineBytes)) >
          u64(elfCefPlantBytes)) {
        final u64 b0 = freeFrame(scratch3);
        final u64 b1 = freeFrame(scratch2);
        final u64 b2 = freeFrame(scratch);
        final u64 b3 = freeFrame(hdr);
        elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
        fatClose();
        return u64(elfDlopenRetBadSo);
      } else {
        // Copy body into the RX face slab (may span LIBC page0/page1).
        final u64 dstBody = facePa + faceUsed;
        i = u64(0);
        while (i < bodyLen) {
          final u64 srcVa = textVa + bodyOff + i;
          final u64 srcPa = elfDlopenRxPa(
              scratch,
              scratch2,
              scratch3,
              scratch4,
              scratch5,
              scratch6,
              textVa,
              srcVa);
          Pointer<u8>.fromAddress(dstBody + i).value =
              Pointer<u8>.fromAddress(srcPa).value;
          i = i + u64(1);
        }
        final u64 targetVa = bias + u64(elfCefUndFaceVaddr) + faceUsed;
        elfCefWritePltTrampoline(u64(elfCefPlantPa) + pltOff, targetVa);
        faceUsed = faceUsed + bodyLen;
        // Align next body to 4 bytes.
        while ((faceUsed & u64(3)) > u64(0)) {
          faceUsed = faceUsed + u64(1);
        }
        bound = bound + u64(1);
        phase = phase + u64(1);
      }
    }
  }
  final u64 b0 = freeFrame(scratch6);
  final u64 b1 = freeFrame(scratch5);
  final u64 b2 = freeFrame(scratch4);
  final u64 b3 = freeFrame(scratch3);
  final u64 b4 = freeFrame(scratch2);
  final u64 b5 = freeFrame(scratch);
  final u64 b6 = freeFrame(hdr);
  elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
  fatClose();
  // Floor: first five required (cef-und). ADR-0180 four-hundred is
  // asserted by cef-und2 serial — missing extras skip, do not BadSo.
  if (bound < u64(elfCefUndBatchWant)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 va = bias + u64(elfCefMemsetPltVaddr);
  procSet(s, u64(procSlotCefMemset), va);
  elfCefPltMemsetLine(va);
  elfCefUndBatchLine(bound);
  return u64(0);
}

/// Alias-maps official RO+RX LOADs from the host plant into the
/// platform window. FAT holds only a ticket name; bytes come from
/// [elfCefPlantPa]. Anti-vacuity: sizes must match the official
/// readelf pins, not the 12 KiB slice.
@bare
u64 elfDlopenMapPlant(u64 s) {
  final u64 plant = u64(elfCefPlantPa);
  final u64 cs = elfDlopenCheckHdr(plant);
  if (cs > u64(0)) {
    return cs;
  }
  final u64 phoff = elfU64(plant + u64(elfOffPhoff));
  final u64 phnum = elfU16(plant + u64(elfOffPhnum));
  u64 roSz = u64(0);
  u64 rxSz = u64(0);
  u64 minVa = u64(0xFFFFFFFFFFFFFFFF);
  u64 maxVa = u64(0);
  u64 loads = u64(0);
  u64 i = u64(0);
  while (i < phnum) {
    final u64 ph = plant + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 flags = elfU32(ph + u64(elfPhOffFlags));
      if ((flags & u64(elfPfW)) > u64(0)) {
        if ((flags & u64(elfPfX)) > u64(0)) {
          return u64(elfDlopenRetBadSo);
        }
      }
      final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
      final u64 offset = elfU64(ph + u64(elfPhOffOffset));
      final u64 filesz = elfU64(ph + u64(elfPhOffFilesz));
      final u64 memsz = elfU64(ph + u64(elfPhOffMemsz));
      if (filesz > memsz) {
        return u64(elfDlopenRetBadSo);
      }
      if ((offset + filesz) > u64(elfCefPlantBytes)) {
        // RW LOADs live past the plant; skip them for this door.
        if ((flags & u64(elfPfX)) > u64(0)) {
          return u64(elfDlopenRetBadSo);
        }
        if ((flags & u64(elfPfW)) < u64(1)) {
          return u64(elfDlopenRetBadSo);
        }
      } else {
        if ((flags & u64(elfPfX)) > u64(0)) {
          rxSz = filesz;
        } else {
          if ((flags & u64(elfPfW)) < u64(1)) {
            roSz = filesz;
          }
        }
        if (vaddr < minVa) {
          minVa = vaddr;
        }
        if ((vaddr + memsz) > maxVa) {
          maxVa = vaddr + memsz;
        }
        loads = loads + u64(1);
      }
    }
    i = i + u64(1);
  }
  if (loads < u64(2)) {
    return u64(elfDlopenRetBadSo);
  }
  if (roSz != u64(elfCefRoFilesz)) {
    return u64(elfDlopenRetBadSo);
  }
  if (rxSz != u64(elfCefRxFilesz)) {
    return u64(elfDlopenRetBadSo);
  }
  if (maxVa <= minVa) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 lo = minVa & u64(heapPageAlignMask);
  final u64 hi = (maxVa + u64(vmPageMask)) & u64(heapPageAlignMask);
  if (hi <= lo) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 span = hi - lo;
  if (span > u64(heapPlatMaxInc)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 mapBase = procGet(s, u64(heapSlotBrk));
  if (mapBase != u64(vmPlatBase)) {
    // Must be the first plat map so bias matches the plant layout.
    return u64(elfDlopenRetBadSo);
  }
  if (span > heapRoom(s)) {
    return u64(elfDlopenRetBadSo);
  }
  // Alias each LOAD page: plat VA -> plant PA + file offset.
  i = u64(0);
  while (i < phnum) {
    final u64 ph = plant + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 flags = elfU32(ph + u64(elfPhOffFlags));
      final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
      final u64 offset = elfU64(ph + u64(elfPhOffOffset));
      final u64 filesz = elfU64(ph + u64(elfPhOffFilesz));
      if ((offset + filesz) <= u64(elfCefPlantBytes)) {
        if (filesz > u64(0)) {
          if ((flags & u64(elfPfW)) < u64(1)) {
            u64 done = u64(0);
            while (done < filesz) {
              final u64 pageOff = (vaddr + done) & u64(vmPageMask);
              final u64 chunk = u64(vmPageBytes) - pageOff;
              u64 n = chunk;
              if ((done + n) > filesz) {
                n = filesz - done;
              }
              final u64 va =
                  (mapBase - lo + vaddr + done) & u64(heapPageAlignMask);
              final u64 pa =
                  (plant + offset + done) & u64(heapPageAlignMask);
              final u64 ex = flags & u64(elfPfX);
              // First touch may already be present from a prior partial
              // page; only map if empty.
              final u64 slot = vmPlatLeafSlot(va);
              if (slot < u64(1)) {
                return u64(elfDlopenRetBadSo);
              }
              final u64 old = Pointer<u64>.fromAddress(slot).value;
              if ((old & u64(vmPresent)) < u64(1)) {
                final u64 m = vmPlatMap(va, pa, u64(0), ex);
                if (m > u64(0)) {
                  return u64(elfDlopenRetBadSo);
                }
              }
              done = done + n;
            }
          }
        }
      }
    }
    i = i + u64(1);
  }
  // Advance the platform break over the whole span so teardown walks it.
  final u64 pages = span >> u64(vmPageShift);
  procSet(s, u64(heapSlotBrk), mapBase + span);
  procSet(s, u64(heapSlotPages),
      procGet(s, u64(heapSlotPages)) + pages);
  // Flip RX pages to R+X (alias PA preserved).
  i = u64(0);
  while (i < phnum) {
    final u64 ph = plant + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 flags = elfU32(ph + u64(elfPhOffFlags));
      if ((flags & u64(elfPfX)) > u64(0)) {
        final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
        final u64 memsz = elfU64(ph + u64(elfPhOffMemsz));
        final u64 st =
            elfDlopenMakeExec(mapBase - lo + vaddr, memsz);
        if (st > u64(0)) {
          return st;
        }
      }
    }
    i = i + u64(1);
  }
  elfCefLoadLine(roSz, rxSz);
  // ADR-0169/0170: pull OUR LIBC.SO faces into an RX PLT face slab
  // and trampoline official high-traffic @plt stubs. Full CEF span
  // leaves no heapRoom for a second ET_DYN map.
  final u64 bs = elfCefPlaceLibcMemset(s, mapBase - lo);
  if (bs > u64(0)) {
    return bs;
  }
  // Official cef_initialize VA — dynsym walk cannot search 1,336 UND.
  return mapBase - lo + u64(elfCefInitVaddr);
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

/// One image sector through the same door FAT uses.
///
/// [fatDiskRead] is [fatDiskPick]: NVMe ([nvmeIoRead]) when [nvmeFind]
/// sees class 01/08/02, AHCI ([ahciIoRead]) when [ahciFind] sees
/// class 01/06/01, otherwise ATA PIO. Named `run` / `spawn` and
/// `run <lba>` both come through here, so a FAT volume on either
/// class can load a program without an IDE drive, and m10-elf /
/// m14-fat stay on PIO on machines with neither. A present
/// controller that fails to set up is a disk error, not a silent
/// IDE fallback.
@bare
u64 elfDiskRead(u64 lba, u64 dst) {
  return fatDiskRead(lba, dst);
}

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
  if (elfDiskRead(lba, buf) > u64(0)) {
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
    if (elfDiskRead(lba, buf + (i << u64(elfSectorShift))) > u64(0)) {
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

/// 1 if a `PT_INTERP` header on the file now open may be honoured.
///
/// **Name, not a flag in the ELF.** Only a named `PLAT.ELF` (the same
/// 8.3 [procPlatNameMatch] uses for the 16 MiB window) gets the door.
/// An LBA load has no open FAT file. `ASK.ELF` / TAP / FILES keep 11.
@bare
u64 elfInterpPermit() {
  if (fatOpenActive() < u64(1)) {
    return u64(0);
  }
  return procPlatNameMatch();
}

/// Copies an 11-byte 8.3 name. Used to reopen the program after the
/// interp file has been the open chain.
@bare
void elfNameSave(u64 dst, u64 src) {
  u64 i = u64(0);
  while (i < u64(11)) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// 1 if [entry] is inside a page this load mapped executable and user.
@bare
u64 elfEntryMapped(u64 entry) {
  if (entry < u64(vmProgBase)) {
    return u64(0);
  }
  if (entry >= u64(vmProgEnd)) {
    return u64(0);
  }
  final u64 eff = vmEffective(entry & u64(0xFFFFFFFFFFFFF000));
  if ((eff & u64(1)) < u64(1)) {
    return u64(0);
  }
  if ((eff & u64(2)) < u64(1)) {
    return u64(0);
  }
  if ((eff & u64(8)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}

/// Maps every `PT_LOAD` in the header at [h] through the open file.
@bare
u64 elfMapLoads(u64 h, u64 scratch) {
  final u64 phoff = elfU64(h + u64(elfOffPhoff));
  final u64 phnum = elfU16(h + u64(elfOffPhnum));
  u64 i = u64(0);
  while (i < phnum) {
    final u64 ph = h + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 st = elfLoadSegment(ph, scratch);
      if (st > u64(0)) {
        return st;
      }
      elfSetMeta(u64(elfMetaSegments), elfMeta(u64(elfMetaSegments)) + u64(1));
    }
    i = i + u64(1);
  }
  return u64(elfErrOk);
}

/// Opens the 8.3 file [PT_INTERP] names, maps that loader, restores the
/// program file. Missing or unparseable interp is [elfErrDynamic] — 11,
/// not a static run of the program. ADR-0126.
@bare
u64 elfHonorInterp(u64 hdr, u64 scratch, u64 interpPh) {
  final u64 dynEntry = elfMeta(u64(elfMetaEntry));
  final u64 off = elfU64(interpPh + u64(elfPhOffOffset));
  final u64 n = elfU64(interpPh + u64(elfPhOffFilesz));
  if (n < u64(2)) {
    return u64(elfErrDynamic);
  }
  if (n > u64(16)) {
    return u64(elfErrDynamic);
  }
  if ((off + n) > elfMeta(u64(elfMetaImageBytes))) {
    return u64(elfErrDynamic);
  }
  // The string may sit past the first page (ld page-aligns `.interp`).
  // Two sectors cover a 16-byte path that straddles a sector boundary.
  u64 path = hdr + off;
  if ((off + n) > u64(vmPageBytes)) {
    final u64 sec = off >> u64(elfSectorShift);
    final u64 rs = elfReadSectors(sec, u64(2), scratch);
    if (rs > u64(0)) {
      return rs;
    }
    path = scratch + (off & u64(511));
  }
  u64 nlen = u64(0);
  while (nlen < n) {
    if (Pointer<u8>.fromAddress(path + nlen).value == u8(0)) {
      break;
    }
    nlen = nlen + u64(1);
  }
  if (nlen < u64(1)) {
    return u64(elfErrDynamic);
  }
  u64 skip = u64(0);
  while (skip < nlen) {
    if (Pointer<u8>.fromAddress(path + skip).value != u8(0x2F)) {
      break;
    }
    skip = skip + u64(1);
  }
  if (skip >= nlen) {
    return u64(elfErrDynamic);
  }
  elfNameSave(hdr + u64(elfInterpNameSave), fatNameBase());
  fatClose();
  if (fatParseAt(path + skip, nlen - skip) > u64(0)) {
    return u64(elfErrDynamic);
  }
  if (fatLookup() > u64(0)) {
    return u64(elfErrDynamic);
  }
  uartWrite(Rodata.addressOf(elfStrInterp), u64(11));
  fatPrintName(fatNameBase());
  uartNewline();
  final u64 bytes = fatMeta(u64(fatMetaFileBytes));
  if (bytes < u64(64)) {
    return u64(elfErrImageSize);
  }
  if (bytes > u64(elfImageMax)) {
    return u64(elfErrImageSize);
  }
  elfSetMeta(u64(elfMetaImageBytes), bytes);
  elfSetMeta(u64(elfMetaImageLba), fatFileSector(u64(0)));
  uartWrite(Rodata.addressOf(elfStrFile), u64(9));
  fatPrintName(fatNameBase());
  uartWrite(Rodata.addressOf(elfStrImage), u64(7));
  uartPutHex(elfMeta(u64(elfMetaImageLba)), u64(8));
  uartWrite(Rodata.addressOf(elfStrBytes), u64(7));
  uartPutHex(bytes, u64(8));
  uartNewline();
  final u64 ih = allocFrame();
  if (ih < u64(1)) {
    return u64(elfErrNoFrames);
  }
  vmZeroFrame(ih);
  u64 want = bytes;
  if (want > u64(vmPageBytes)) {
    want = u64(vmPageBytes);
  }
  final u64 rs =
      elfReadSectors(u64(0), (want + u64(511)) >> u64(elfSectorShift), ih);
  if (rs > u64(0)) {
    final u64 back = freeFrame(ih);
    elfSetMeta(u64(elfMetaStatus), back);
    return rs;
  }
  final u64 cs = elfCheckHeader(ih);
  if (cs > u64(0)) {
    final u64 back = freeFrame(ih);
    elfSetMeta(u64(elfMetaStatus), back);
    return cs;
  }
  final u64 interpEntry = elfMeta(u64(elfMetaEntry));
  final u64 iphoff = elfU64(ih + u64(elfOffPhoff));
  final u64 iphnum = elfU16(ih + u64(elfOffPhnum));
  u64 loads = u64(0);
  u64 i = u64(0);
  while (i < iphnum) {
    final u64 ph = ih + iphoff + (i * u64(elfPhdrSize));
    elfSegLine(i, ph);
    final u64 st = elfCheckPhdr(ph);
    if (st > u64(0)) {
      final u64 back = freeFrame(ih);
      elfSetMeta(u64(elfMetaStatus), back);
      return st;
    }
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      loads = loads + u64(1);
    }
    i = i + u64(1);
  }
  if (loads < u64(1)) {
    final u64 back = freeFrame(ih);
    elfSetMeta(u64(elfMetaStatus), back);
    return u64(elfErrNoLoad);
  }
  final u64 ms = elfMapLoads(ih, scratch);
  if (ms > u64(0)) {
    final u64 back = freeFrame(ih);
    elfSetMeta(u64(elfMetaStatus), back);
    return ms;
  }
  final u64 back = freeFrame(ih);
  elfSetMeta(u64(elfMetaStatus), back);
  fatClose();
  elfNameSave(fatNameBase(), hdr + u64(elfInterpNameSave));
  if (fatLookup() > u64(0)) {
    return u64(elfErrDynamic);
  }
  elfSetMeta(u64(elfMetaImageBytes), fatMeta(u64(fatMetaFileBytes)));
  elfSetMeta(u64(elfMetaImageLba), fatFileSector(u64(0)));
  elfSetMeta(u64(elfMetaEntry), interpEntry);
  elfSetMeta(u64(elfMetaExit), dynEntry);
  return u64(elfErrOk);
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
    if (elfInterpPermit() < u64(1)) {
      return u64(elfErrDynamic);
    }
    return u64(elfErrOk);
  }
  if (type == u64(elfPtDynamic)) {
    if (elfInterpPermit() < u64(1)) {
      return u64(elfErrDynamic);
    }
    return u64(elfErrOk);
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
///
/// **M21 moved the upper bound from [vmProgEnd] to [vmUserEnd], and the ONLY
/// reason that is safe is the per-page walk below.** Ring 3 can now reach a
/// second window, `[vmShmBase, vmShmEnd)`, and between the load region and it
/// there is nothing -- a 512-page span that is mapped only where a shared
/// region has been mapped in. A validator that tested lo/hi would now accept
/// every address in that span and the kernel would fault dereferencing one.
/// This one asks [vmEffective] about every page, so an unmapped page in the new
/// span is refused exactly as an unmapped page in the load region's gaps
/// already was. That is the property M16's mutation round established
/// (GAP-0124) -- the two mutations that survived a lo/hi test and died against
/// the walk were "a page inside the window that is not mapped" and "a range
/// whose first page is mapped and whose second is not", which is precisely this
/// case -- and `m21-shmem/run.sh` re-reads all six validator bodies and fails
/// if any one of them stops walking.
@bare
u64 elfOwns(u64 ptr, u64 len) {
  if (ptr < u64(vmProgBase)) {
    return u64(0);
  }
  if (ptr >= u64(vmUserEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(userWriteMax)) {
    return u64(0);
  }
  if ((ptr + len) > u64(vmUserEnd)) {
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

/// `PROC DLOPEN <s> VA <va>`, or `PROC DLOPEN <s> ERR <ret>`. ADR-0144.
@bare
void elfDlopenLine(u64 s, u64 r) {
  uartWrite(Rodata.addressOf(elfStrDlopen), u64(12));
  uartPutHex(s, u64(2));
  if (r > u64(elfDlopenRetFloor)) {
    uartWrite(Rodata.addressOf(vmStrErr), u64(5));
    uartPutHex(r, u64(16));
    uartNewline();
    return;
  }
  uartWrite(Rodata.addressOf(heapStrVa), u64(4));
  uartPutHex(r, u64(16));
  uartNewline();
}

/// 1 if [p] matches [want] for [n] bytes (including a trailing NUL).
@bare
u64 elfDlopenNameEq(u64 p, u64 want, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    if (Pointer<u8>.fromAddress(p + i).value !=
        Pointer<u8>.fromAddress(want + i).value) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// 1 if [p] is `write\0` (ADR-0152), `need_fn\0` (ADR-0157),
/// `dl_fn\0` / `pt_fn\0` (ADR-0160), `gb_fn\0` / `go_fn\0` /
/// `np_fn\0` / `ns_fn\0` (ADR-0162), `nu_fn\0` / `sm_fn\0` /
/// `db_fn\0` / `gi_fn\0` / `at_fn\0` / `ab_fn\0` / `cu_fn\0` /
/// `x1_fn\0` (ADR-0163), `xc_fn\0`..`ld_fn\0` (ADR-0165), or
/// `so_mark\0` (ADR-0144). Prefer `write`, then `need_fn`, then
/// `dl_fn`, then `pt_fn`, then `gb_fn`..`ns_fn`, then
/// `nu_fn`..`x1_fn`, then `xc_fn`..`ld_fn`.
@bare
u64 elfDlopenMarkName(u64 p) {
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrWrite), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrMemset), u64(7)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrNeedFn), u64(8)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrDlFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrPtFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrGbFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrGoFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrNpFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrNsFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrNuFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrSmFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrDbFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrGiFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrAtFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrAbFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrCuFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrX1Fn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXcFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXdFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXeFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXfFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXrFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrGmFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrExFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXbFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrXkFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrCaFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrPgFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrUdFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrAsFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrApFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrGcFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrLdFn), u64(6)) > u64(0)) {
    return u64(1);
  }
  if (elfDlopenNameEq(p, Rodata.addressOf(elfStrSoMark), u64(8)) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

/// Remaps [bytes] at [va] from the heapSbrk RW+NX mapping to R+X
/// so a call into a LOAD with [elfPfX] does not #PF. PA is taken
/// from the live leaf. W^X stays: write is cleared, exec is set.
@bare
u64 elfDlopenMakeExec(u64 va, u64 bytes) {
  if (bytes < u64(1)) {
    return u64(0);
  }
  u64 at = va & u64(heapPageAlignMask);
  final u64 end = (va + bytes + u64(vmPageMask)) & u64(heapPageAlignMask);
  while (at < end) {
    final u64 slot = vmPlatLeafSlot(at);
    if (slot < u64(1)) {
      return u64(elfDlopenRetBadSo);
    }
    final u64 e = Pointer<u64>.fromAddress(slot).value;
    if ((e & u64(vmPresent)) < u64(1)) {
      return u64(elfDlopenRetBadSo);
    }
    final u64 pa = vmEntryAddr(e);
    if (vmPlatUnmap(at) > u64(0)) {
      return u64(elfDlopenRetBadSo);
    }
    final u64 m = vmPlatMap(at, pa, u64(0), u64(1));
    if (m > u64(0)) {
      return u64(elfDlopenRetBadSo);
    }
    at = at + u64(vmPageBytes);
  }
  return u64(0);
}

/// Copies [n] image bytes starting at file offset [fileOff] onto
/// already-mapped [dest]. [scratch] is one sector frame.
@bare
u64 elfDlopenCopy(u64 dest, u64 fileOff, u64 n, u64 scratch) {
  u64 done = u64(0);
  while (done < n) {
    final u64 pos = fileOff + done;
    final u64 sec = pos >> u64(elfSectorShift);
    final u64 lo = pos & u64(511);
    u64 chunk = u64(512) - lo;
    if ((done + chunk) > n) {
      chunk = n - done;
    }
    if (elfReadSectors(sec, u64(1), scratch) > u64(0)) {
      return u64(elfDlopenRetBadSo);
    }
    u64 k = u64(0);
    while (k < chunk) {
      Pointer<u8>.fromAddress(dest + done + k).value =
          Pointer<u8>.fromAddress(scratch + lo + k).value;
      k = k + u64(1);
    }
    done = done + chunk;
  }
  return u64(0);
}

/// ET_DYN header at [h], or a [elfDlopenRet*] refusal. Spawn still
/// uses [elfCheckHeader] and still refuses type 3.
@bare
u64 elfDlopenCheckHdr(u64 h) {
  if (elfU8(h) != u64(elfIdentMag0)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU8(h + u64(1)) != u64(elfIdentMag1)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU8(h + u64(2)) != u64(elfIdentMag2)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU8(h + u64(3)) != u64(elfIdentMag3)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU8(h + u64(elfOffClass)) != u64(elfClass64)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU8(h + u64(elfOffData)) != u64(elfData2Lsb)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU16(h + u64(elfOffType)) != u64(elfTypeDyn)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU16(h + u64(elfOffMachine)) != u64(elfMachineX8664)) {
    return u64(elfDlopenRetBadSo);
  }
  if (elfU16(h + u64(elfOffPhentsize)) != u64(elfPhdrSize)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 phnum = elfU16(h + u64(elfOffPhnum));
  if (phnum < u64(1)) {
    return u64(elfDlopenRetBadSo);
  }
  if (phnum > u64(elfPhdrMax)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 phoff = elfU64(h + u64(elfOffPhoff));
  if (phoff < u64(64)) {
    return u64(elfDlopenRetBadSo);
  }
  if ((phoff + (phnum * u64(elfPhdrSize))) > u64(vmPageBytes)) {
    return u64(elfDlopenRetBadSo);
  }
  return u64(0);
}

/// Walks mapped dynsym at [bias] for `write` (ADR-0152),
/// `memset` (ADR-0169), `need_fn` (ADR-0157), `dl_fn` / `pt_fn`
/// (ADR-0160), `gb_fn` / `go_fn` / `np_fn` / `ns_fn` (ADR-0162),
/// `nu_fn` / `sm_fn` / `db_fn` / `gi_fn` / `at_fn` / `ab_fn` /
/// `cu_fn` / `x1_fn` (ADR-0163), `xc_fn`..`ld_fn` (ADR-0165),
/// or `so_mark` (ADR-0144), or `cef_initialize` (ADR-0167). [h]
/// is the header frame. Returns the symbol VA or a refusal.
/// Prefer `write`, then `memset`, then `need_fn`, then
/// `dl_fn`..`ns_fn`, then `nu_fn`..`x1_fn`, then `xc_fn`..`ld_fn`,
/// then `so_mark`, then `cef_initialize`.
@bare
u64 elfDlopenFindMark(u64 bias, u64 h) {
  final u64 phoff = elfU64(h + u64(elfOffPhoff));
  final u64 phnum = elfU16(h + u64(elfOffPhnum));
  u64 dyn = u64(0);
  u64 dynsz = u64(0);
  u64 i = u64(0);
  while (i < phnum) {
    final u64 ph = h + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtDynamic)) {
      dyn = bias + elfU64(ph + u64(elfPhOffVaddr));
      dynsz = elfU64(ph + u64(elfPhOffFilesz));
    }
    i = i + u64(1);
  }
  if (dyn < bias) {
    return u64(elfDlopenRetBadSo);
  }
  if (dynsz < u64(elfDynSize)) {
    return u64(elfDlopenRetBadSo);
  }
  // ADR-0167: official CEF DYNAMIC is 0x3b0; a measured slice with
  // 32 DT_NEEDED plus reloc tags sits under 2 KiB. Old 512 refused
  // the official NEEDED list.
  if (dynsz > u64(2048)) {
    return u64(elfDlopenRetBadSo);
  }
  u64 strtab = u64(0);
  u64 symtab = u64(0);
  u64 strsz = u64(0);
  u64 nsym = u64(0);
  u64 t = u64(0);
  while ((t + u64(elfDynSize)) <= dynsz) {
    final u64 tag = elfU64(dyn + t);
    final u64 val = elfU64(dyn + t + u64(8));
    if (tag < u64(1)) {
      t = dynsz;
    } else {
      if (tag == u64(elfDtStrtab)) {
        strtab = bias + val;
      }
      if (tag == u64(elfDtSymtab)) {
        symtab = bias + val;
      }
      if (tag == u64(elfDtStrsz)) {
        strsz = val;
      }
      if (tag == u64(elfDtHash)) {
        nsym = elfU32(bias + val + u64(4));
      }
      t = t + u64(elfDynSize);
    }
  }
  if (strtab < bias) {
    return u64(elfDlopenRetBadSo);
  }
  if (symtab < bias) {
    return u64(elfDlopenRetBadSo);
  }
  if (strsz < u64(6)) {
    return u64(elfDlopenRetBadSo);
  }
  if (strsz > u64(4096)) {
    return u64(elfDlopenRetBadSo);
  }
  if (nsym < u64(2)) {
    nsym = u64(elfDlopenSymMax);
  }
  if (nsym > u64(elfDlopenSymMax)) {
    nsym = u64(elfDlopenSymMax);
  }
  // Pass 0 write .. 15 x1_fn, 16..31 xc_fn..ld_fn, 32 so_mark,
  // 33 cef_initialize (ADR-0167).
  u64 pass = u64(0);
  while (pass < u64(34)) {
    u64 want = u64(0);
    u64 nlen = u64(0);
    if (pass < u64(1)) {
      want = Rodata.addressOf(elfStrWrite);
      nlen = u64(6);
    }
    if (pass < u64(2)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrNeedFn);
        nlen = u64(8);
      }
    }
    if (pass < u64(3)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrDlFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(4)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrPtFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(5)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrGbFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(6)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrGoFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(7)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrNpFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(8)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrNsFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(9)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrNuFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(10)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrSmFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(11)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrDbFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(12)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrGiFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(13)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrAtFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(14)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrAbFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(15)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrCuFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(16)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrX1Fn);
        nlen = u64(6);
      }
    }
    if (pass < u64(17)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXcFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(18)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXdFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(19)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXeFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(20)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXfFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(21)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXrFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(22)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrGmFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(23)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrExFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(24)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXbFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(25)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrXkFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(26)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrCaFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(27)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrPgFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(28)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrUdFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(29)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrAsFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(30)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrApFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(31)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrGcFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(32)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrLdFn);
        nlen = u64(6);
      }
    }
    if (pass < u64(33)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrSoMark);
        nlen = u64(8);
      }
    }
    if (pass < u64(34)) {
      if (nlen < u64(1)) {
        want = Rodata.addressOf(elfStrCefInit);
        nlen = u64(15);
      }
    }
    u64 s = u64(1);
    while (s < nsym) {
      final u64 ent = symtab + (s * u64(elfSymSize));
      final u64 name = elfU32(ent);
      if (nlen > u64(0)) {
        if ((name + nlen) <= strsz) {
          if (elfDlopenNameEq(strtab + name, want, nlen) > u64(0)) {
            return bias + elfU64(ent + u64(8));
          }
        }
      }
      s = s + u64(1);
    }
    // ADR-0169: after write miss, try memset before the stand-in ladder.
    if (pass < u64(1)) {
      want = Rodata.addressOf(elfStrMemset);
      nlen = u64(7);
      s = u64(1);
      while (s < nsym) {
        final u64 ent = symtab + (s * u64(elfSymSize));
        final u64 name = elfU32(ent);
        if ((name + nlen) <= strsz) {
          if (elfDlopenNameEq(strtab + name, want, nlen) > u64(0)) {
            return bias + elfU64(ent + u64(8));
          }
        }
        s = s + u64(1);
      }
    }
    pass = pass + u64(1);
  }
  return u64(elfDlopenRetBadSo);
}

/// Walks mapped dynsym at [bias] for one name. Returns the symbol
/// VA or [elfDlopenRetBadSo]. Used to stash `memset` even when
/// `write` won the prefer ladder (ADR-0169).
@bare
u64 elfDlopenFindSym(u64 bias, u64 h, u64 want, u64 nlen) {
  final u64 phoff = elfU64(h + u64(elfOffPhoff));
  final u64 phnum = elfU16(h + u64(elfOffPhnum));
  u64 dyn = u64(0);
  u64 dynsz = u64(0);
  u64 i = u64(0);
  while (i < phnum) {
    final u64 ph = h + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtDynamic)) {
      dyn = bias + elfU64(ph + u64(elfPhOffVaddr));
      dynsz = elfU64(ph + u64(elfPhOffFilesz));
    }
    i = i + u64(1);
  }
  if (dyn < bias) {
    return u64(elfDlopenRetBadSo);
  }
  if (dynsz < u64(elfDynSize)) {
    return u64(elfDlopenRetBadSo);
  }
  if (dynsz > u64(2048)) {
    return u64(elfDlopenRetBadSo);
  }
  u64 strtab = u64(0);
  u64 symtab = u64(0);
  u64 strsz = u64(0);
  u64 nsym = u64(0);
  u64 t = u64(0);
  while ((t + u64(elfDynSize)) <= dynsz) {
    final u64 tag = elfU64(dyn + t);
    final u64 val = elfU64(dyn + t + u64(8));
    if (tag < u64(1)) {
      t = dynsz;
    } else {
      if (tag == u64(elfDtStrtab)) {
        strtab = bias + val;
      }
      if (tag == u64(elfDtSymtab)) {
        symtab = bias + val;
      }
      if (tag == u64(elfDtStrsz)) {
        strsz = val;
      }
      if (tag == u64(elfDtHash)) {
        nsym = elfU32(bias + val + u64(4));
      }
      t = t + u64(elfDynSize);
    }
  }
  if (strtab < bias) {
    return u64(elfDlopenRetBadSo);
  }
  if (symtab < bias) {
    return u64(elfDlopenRetBadSo);
  }
  if (strsz < nlen) {
    return u64(elfDlopenRetBadSo);
  }
  if (strsz > u64(4096)) {
    return u64(elfDlopenRetBadSo);
  }
  if (nsym < u64(2)) {
    nsym = u64(elfDlopenSymMax);
  }
  if (nsym > u64(elfDlopenSymMax)) {
    nsym = u64(elfDlopenSymMax);
  }
  u64 s = u64(1);
  while (s < nsym) {
    final u64 ent = symtab + (s * u64(elfSymSize));
    final u64 name = elfU32(ent);
    if ((name + nlen) <= strsz) {
      if (elfDlopenNameEq(strtab + name, want, nlen) > u64(0)) {
        return bias + elfU64(ent + u64(8));
      }
    }
    s = s + u64(1);
  }
  return u64(elfDlopenRetBadSo);
}

/// Maps the open FAT ET_DYN into the platform heap and returns
/// `write`, `need_fn`, `dl_fn`, `pt_fn`, `gb_fn`, `go_fn`,
/// `np_fn`, `ns_fn`, `nu_fn`, `sm_fn`, `db_fn`, `gi_fn`,
/// `at_fn`, `ab_fn`, `cu_fn`, `x1_fn`, `xc_fn`..`ld_fn`, or
/// `so_mark`. Caller has already proved the slot is platform
/// and the name is open. X LOAD pages are remapped R+X after
/// the copy so a call does not #PF on the heapSbrk NX bit.
@bare
u64 elfDlopenMap(u64 s, u64 hdr, u64 scratch) {
  final u64 bytes = fatMeta(u64(fatMetaFileBytes));
  if (bytes < u64(64)) {
    return u64(elfDlopenRetBadSo);
  }
  if (bytes > u64(elfImageMax)) {
    return u64(elfDlopenRetBadSo);
  }
  elfSetMeta(u64(elfMetaImageBytes), bytes);
  elfSetMeta(u64(elfMetaImageLba), fatFileSector(u64(0)));
  u64 want = bytes;
  if (want > u64(vmPageBytes)) {
    want = u64(vmPageBytes);
  }
  if (elfReadSectors(
          u64(0), (want + u64(511)) >> u64(elfSectorShift), hdr) >
      u64(0)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 cs = elfDlopenCheckHdr(hdr);
  if (cs > u64(0)) {
    return cs;
  }
  final u64 phoff = elfU64(hdr + u64(elfOffPhoff));
  final u64 phnum = elfU16(hdr + u64(elfOffPhnum));
  u64 minVa = u64(0xFFFFFFFFFFFFFFFF);
  u64 maxVa = u64(0);
  u64 loads = u64(0);
  u64 i = u64(0);
  while (i < phnum) {
    final u64 ph = hdr + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 flags = elfU32(ph + u64(elfPhOffFlags));
      if ((flags & u64(elfPfW)) > u64(0)) {
        if ((flags & u64(elfPfX)) > u64(0)) {
          return u64(elfDlopenRetBadSo);
        }
      }
      final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
      final u64 offset = elfU64(ph + u64(elfPhOffOffset));
      final u64 filesz = elfU64(ph + u64(elfPhOffFilesz));
      final u64 memsz = elfU64(ph + u64(elfPhOffMemsz));
      if (filesz > memsz) {
        return u64(elfDlopenRetBadSo);
      }
      if (memsz > u64(elfImageMax)) {
        return u64(elfDlopenRetBadSo);
      }
      if ((offset + filesz) > bytes) {
        return u64(elfDlopenRetBadSo);
      }
      if (vaddr < minVa) {
        minVa = vaddr;
      }
      if ((vaddr + memsz) > maxVa) {
        maxVa = vaddr + memsz;
      }
      loads = loads + u64(1);
    }
    i = i + u64(1);
  }
  if (loads < u64(1)) {
    return u64(elfDlopenRetBadSo);
  }
  if (maxVa <= minVa) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 lo = minVa & u64(heapPageAlignMask);
  final u64 hi = (maxVa + u64(vmPageMask)) & u64(heapPageAlignMask);
  if (hi <= lo) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 span = hi - lo;
  if (span > u64(elfImageMax)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 mapBase = heapSbrk(s, span);
  if (mapBase > u64(heapRetFloor)) {
    return u64(elfDlopenRetBadSo);
  }
  final u64 bias = mapBase - lo;
  i = u64(0);
  while (i < phnum) {
    final u64 ph = hdr + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
      final u64 offset = elfU64(ph + u64(elfPhOffOffset));
      final u64 filesz = elfU64(ph + u64(elfPhOffFilesz));
      if (filesz > u64(0)) {
        final u64 st =
            elfDlopenCopy(bias + vaddr, offset, filesz, scratch);
        if (st > u64(0)) {
          return st;
        }
      }
    }
    i = i + u64(1);
  }
  // After the copy, flip X LOADs to R+X. heapSbrk mapped RW+NX.
  i = u64(0);
  while (i < phnum) {
    final u64 ph = hdr + phoff + (i * u64(elfPhdrSize));
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtLoad)) {
      final u64 flags = elfU32(ph + u64(elfPhOffFlags));
      if ((flags & u64(elfPfX)) > u64(0)) {
        final u64 vaddr = elfU64(ph + u64(elfPhOffVaddr));
        final u64 memsz = elfU64(ph + u64(elfPhOffMemsz));
        final u64 st = elfDlopenMakeExec(bias + vaddr, memsz);
        if (st > u64(0)) {
          return st;
        }
      }
    }
    i = i + u64(1);
  }
  // Stash memset if this SO exports it (ADR-0169), even when write
  // wins the prefer ladder — CEF PLT bind needs the face VA.
  final u64 ms = elfDlopenFindSym(
      bias, hdr, Rodata.addressOf(elfStrMemset), u64(7));
  if (ms < u64(elfDlopenRetFloor)) {
    procSet(s, u64(procSlotCefMemset), ms);
  }
  return elfDlopenFindMark(bias, hdr);
}

/// Syscall 29. `rdi` is a pointer to an 8.3 name, `rsi` is its
/// length. Returns the mapped face VA (`write` / `need_fn` /
/// `dl_fn` / `pt_fn` / `gb_fn` / `go_fn` / `np_fn` / `ns_fn` /
/// `nu_fn` / `sm_fn` / `db_fn` / `gi_fn` / `at_fn` / `ab_fn` /
/// `cu_fn` / `x1_fn` / `xc_fn`..`ld_fn` / `so_mark`) or a
/// [elfDlopenRet*] refusal.
///
/// **The flag is the name.** Only [heapIsPlat] may honour it.
/// A volume without the named file is [elfDlopenRetNotFound] and
/// cannot print the derived line — that is the anti-vacuity for a
/// missing `DT_NEEDED` (ADR-0157 / ADR-0160 / ADR-0162 /
/// ADR-0163 / ADR-0165). Not glibc. Not CEF. 11 stays `fdwait`.
@bare
/// ADR-0174 / ADR-0176 — resolve a Linux soname through planted `SOMAP.TXT`.
///
/// Format is one mapping per line: `libdl.so.2=LIBDL.SO\n` (ADR-0176
/// plants all 32 official CEF sonames). FAT cannot store most of those
/// strings as 8.3; the planted table is the honest door. A few CEF
/// names (`libnspr4.so`, `libnss3.so`) parse as 8.3 but are not our
/// faces — callers also consult SOMAP after a NotFound lookup.
/// Missing `SOMAP.TXT` or a missing entry is [elfDlopenRetNotFound]
/// (anti-vacuity: no invented alias). On success the FAT name buffer
/// holds the 8.3 target and the caller proceeds to [fatLookup].
@bare
u64 elfDlopenSomapApply(u64 want, u64 wantLen) {
  fatClose();
  final u64 pn = fatParseAt(Rodata.addressOf(elfStrSomapTxt), u64(9));
  if (pn > u64(fatErrOk)) {
    return u64(elfDlopenRetNotFound);
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    fatReportError(fs);
    return u64(elfDlopenRetNotFound);
  }
  fatOpenLine();
  final u64 bytes = fatMeta(u64(fatMetaFileBytes));
  if (bytes < u64(12)) {
    fatClose();
    return u64(elfDlopenRetNotFound);
  }
  if (bytes > u64(elfSomapMax)) {
    fatClose();
    return u64(elfDlopenRetNotFound);
  }
  final u64 map = allocFrame();
  if (map < u64(1)) {
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  vmZeroFrame(map);
  final u64 nsec = (bytes + u64(511)) >> u64(elfSectorShift);
  if (elfReadSectors(u64(0), nsec, map) > u64(0)) {
    final u64 back = freeFrame(map);
    elfSetMeta(u64(elfMetaStatus), back);
    fatClose();
    return u64(elfDlopenRetNotFound);
  }
  fatClose();
  u64 i = u64(0);
  while (i < bytes) {
    // Line must start at offset 0 or after LF.
    u64 atLine = u64(0);
    if (i < u64(1)) {
      atLine = u64(1);
    } else {
      if (Pointer<u8>.fromAddress(map + i - u64(1)).value == u8(0x0A)) {
        atLine = u64(1);
      }
    }
    if (atLine > u64(0)) {
      if ((i + wantLen + u64(1)) <= bytes) {
        u64 j = u64(0);
        u64 eq = u64(1);
        while (j < wantLen) {
          if (Pointer<u8>.fromAddress(map + i + j).value !=
              Pointer<u8>.fromAddress(want + j).value) {
            eq = u64(0);
          }
          j = j + u64(1);
        }
        if (eq > u64(0)) {
          if (Pointer<u8>.fromAddress(map + i + wantLen).value ==
              u8(0x3D)) {
            final u64 t = i + wantLen + u64(1);
            u64 te = t;
            while (te < bytes) {
              final u8 c = Pointer<u8>.fromAddress(map + te).value;
              if (c == u8(0x0A)) {
                break;
              }
              if (c == u8(0x0D)) {
                break;
              }
              if (c == u8(0x20)) {
                break;
              }
              te = te + u64(1);
            }
            if (te > t) {
              final u64 tp = fatParseAt(map + t, te - t);
              if (tp < u64(1)) {
                uartWrite(Rodata.addressOf(elfStrDlopenAlias), u64(18));
                fatPrintName(fatNameBase());
                uartNewline();
                final u64 back = freeFrame(map);
                elfSetMeta(u64(elfMetaStatus), back);
                return u64(0);
              }
            }
          }
        }
      }
    }
    i = i + u64(1);
  }
  final u64 back = freeFrame(map);
  elfSetMeta(u64(elfMetaStatus), back);
  return u64(elfDlopenRetNotFound);
}

@bare
void elfSysDlopen(u64 frame) {
  if (procLive() < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadArg));
    return;
  }
  final u64 caller = procCurrent();
  final u64 ptr = userFrame(frame, u64(userFrameRdi));
  final u64 len = userFrame(frame, u64(userFrameRsi));
  if (heapIsPlat(caller) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadArg));
    elfDlopenLine(caller, u64(elfDlopenRetBadArg));
    return;
  }
  if (len < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadArg));
    elfDlopenLine(caller, u64(elfDlopenRetBadArg));
    return;
  }
  if (len > u64(elfDlopenNameMax)) {
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadArg));
    elfDlopenLine(caller, u64(elfDlopenRetBadArg));
    return;
  }
  if (elfOwns(ptr, len) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadPtr));
    elfDlopenLine(caller, u64(elfDlopenRetBadPtr));
    return;
  }
  final u64 buf = fileBufBase();
  u64 i = u64(0);
  while (i < len) {
    Pointer<u8>.fromAddress(buf + i).value =
        Pointer<u8>.fromAddress(ptr + i).value;
    i = i + u64(1);
  }
  final u64 pn = fatParseAt(buf, len);
  u64 have = u64(0);
  if (pn < u64(1)) {
    final u64 hit = fatLookup();
    if (hit < u64(1)) {
      have = u64(1);
    }
  }
  if (have < u64(1)) {
    // Non-8.3 Linux soname, or an accidental 8.3 CEF name
    // (libnspr4.so / libnss3.so) whose FAT face is not the parse
    // result — planted SOMAP.TXT only.
    final u64 ar = elfDlopenSomapApply(buf, len);
    if (ar > u64(0)) {
      userSetFrame(frame, u64(userFrameRax), ar);
      elfDlopenLine(caller, ar);
      return;
    }
    final u64 fs = fatLookup();
    if (fs > u64(fatErrOk)) {
      fatReportError(fs);
      userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetNotFound));
      elfDlopenLine(caller, u64(elfDlopenRetNotFound));
      return;
    }
  }
  fatOpenLine();
  final u64 hdr = allocFrame();
  if (hdr < u64(1)) {
    fatClose();
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadSo));
    elfDlopenLine(caller, u64(elfDlopenRetBadSo));
    return;
  }
  final u64 scratch = allocFrame();
  if (scratch < u64(1)) {
    final u64 back = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), back);
    fatClose();
    userSetFrame(frame, u64(userFrameRax), u64(elfDlopenRetBadSo));
    elfDlopenLine(caller, u64(elfDlopenRetBadSo));
    return;
  }
  vmZeroFrame(hdr);
  vmZeroFrame(scratch);
  u64 r = u64(0);
  if (elfCefPlantReady() > u64(0)) {
    if (elfCefNameIsCef() > u64(0)) {
      r = elfDlopenMapPlant(caller);
    } else {
      r = elfDlopenMap(caller, hdr, scratch);
    }
  } else {
    r = elfDlopenMap(caller, hdr, scratch);
  }
  final u64 b1 = freeFrame(scratch);
  final u64 b2 = freeFrame(hdr);
  elfSetMeta(u64(elfMetaStatus), b1 + b2);
  fatClose();
  userSetFrame(frame, u64(userFrameRax), r);
  elfDlopenLine(caller, r);
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
  elfSetMeta(u64(elfMetaExit), u64(0));
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
  // allocated or mapped. A `PT_INTERP` on a named platform ELF is recorded
  // here and honoured only after the page table exists — and only if the
  // named loader is on the volume. Missing that file is still 11.
  u64 loads = u64(0);
  u64 interpPh = u64(0);
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
    if (elfU32(ph + u64(elfPhOffType)) == u64(elfPtInterp)) {
      interpPh = ph;
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
  if (interpPh > u64(0)) {
    final u64 hs = elfHonorInterp(hdr, scratch, interpPh);
    if (hs > u64(0)) {
      return hs;
    }
  }
  final u64 ms = elfMapLoads(hdr, scratch);
  if (ms > u64(0)) {
    return ms;
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
  if (elfEntryMapped(entry) < u64(1)) {
    return u64(elfErrEntry);
  }
  final u64 dyn = elfMeta(u64(elfMetaExit));
  if (dyn > u64(0)) {
    if (elfEntryMapped(dyn) < u64(1)) {
      return u64(elfErrEntry);
    }
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
