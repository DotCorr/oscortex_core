// core/kernel/file.dart
//
// oscortex_core M15: FILE DESCRIPTORS, AND A PROGRAM THAT CAN READ. The four
// syscalls -- `open`, `read`, `close`, `seek` -- that connect M14's read-only
// FAT16 filesystem to M13's C library, and the per-program descriptor table
// that holds the offset between one `read` and the next.
//
// The architecture is
// docs/decisions/0019-file-descriptors-and-a-program-that-reads.md; the binary
// exit criterion is ROADMAP.md's M15 and tests/conformance/m15-fileio/run.sh.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS NARROWS: GAP-0113, AND EXACTLY THAT MUCH
// ---------------------------------------------------------------------------
// M14 built a filesystem and M13 built a C library and the two never met: the
// kernel could read a file, and no *program* could. `run <name>` was the shell
// loading a program, not a program doing I/O. After this file a C program can
// name a file, read it in pieces, and compute something from what it read.
//
// **What is still absent is written down in docs/known-gaps.md GAP-0122 rather
// than implied by silence**: there are no writes anywhere (GAP-0116 item 1 is
// unchanged), no directories, no `stat`, no `dup`, no `stdin`, no console
// input, no `errno`, no VFS and no second filesystem. `open` takes an 8.3 name
// in the root directory and nothing else; there is no path, because there is
// nowhere for a path to lead.
//
// ---------------------------------------------------------------------------
// ONE CHAIN, FOUR DESCRIPTORS, AND THE WORD THAT MAKES THAT SOUND
// ---------------------------------------------------------------------------
// `fat.dart` holds ONE cluster chain (GAP-0116 item 5): the chain array in
// `fat_store` describes one file at a time and there is no room for a second.
// This file does NOT inherit that as a one-open-file-at-a-time restriction, and
// it does not lift it by making the chain array bigger either. It makes the
// chain array a CACHE OF ONE:
//
//   * a descriptor stores the file's FIRST CLUSTER and SIZE, which is all a
//     chain can be rebuilt from;
//   * `fileChainFor` asks `fatSelect` to make the chain array describe this
//     descriptor's file, which is free when it already does and one FAT walk
//     when it does not;
//   * every switch between two open files is COUNTED, in [fileMetaRebuilds],
//     and the count is printed, so the cost is a number rather than a claim.
//
// The consequence is stated rather than hidden: **two programs alternating
// reads between two files pay one chain walk per switch.** A chain walk on this
// volume is one cached FAT sector read (ADR-0018 §7), so the cost is small and
// it is real, and the alternative -- four chain arrays, four kilobytes of
// donated `.bss` per descriptor -- was rejected as buying speed with the one
// resource this kernel has least of.
//
// ---------------------------------------------------------------------------
// THE POINTER RULE, WHICH IS THE WHOLE OF THE SECURITY ARGUMENT HERE
// ---------------------------------------------------------------------------
// M9 established that the kernel validates a ring-3 pointer before it
// dereferences one (ADR-0013 §5), and every syscall before this one only ever
// READ through such a pointer. `read` is the first syscall in this kernel that
// WRITES through one, and a range test that was good enough to read from is not
// good enough to write to: the program's own R+X segment is user-accessible and
// is not writable, and a kernel that wrote a file into it would be punching a
// hole in the W^X property M8 and M10 exist to enforce.
//
// So [fileOwnsWrite] requires BOTH the user bit AND the writable bit out of the
// live page tables, page by page, for every page the range touches, before one
// byte is copied. `m15-fileio`'s program hands `read` a pointer into its own
// `.rodata` on purpose and must get [fileRetBadPtr] back with the bytes there
// unchanged -- which it proves by hashing its own R+X segment before and after
// and getting the same number.
//
// **There is exactly one store to a caller-supplied address in this file**, in
// [fileCopyOut], and its only caller validates first. Nothing else here
// dereferences anything a program chose.
//
// ---------------------------------------------------------------------------
// THE STORAGE SEAM -- ONE ACCESSOR, THREE CALL SITES
// ---------------------------------------------------------------------------
// DCDart still has no mutable static data of any kind (docs/known-gaps.md
// GAP-0053), so this subsystem's state is assembly-donated `.bss` exactly as
// the allocator's, the address space's, the loader's and the filesystem's are:
// 1280 bytes in ONE symbol (`file_store`, core/boot/kdata.S) behind ONE
// accessor (`file_store_addr`) reached through exactly THREE functions.
// ADR-0011 §0 is the pattern; `tests/conformance/m15-fileio/run.sh` counts the
// call sites the same way m7, m8, m9, m10, m11 and m14 count theirs.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// A `@rodata` table carries no length (GAP-0060), so every byte count below is
// repeated at its call site by hand. `tests/conformance/m15-fileio/run.sh`
// reads every symbol's real size out of `kmain.o` and compares it against what
// the call site passes.
// ---------------------------------------------------------------------------

/// Line label.
///
/// `'FILE OPENS '` -- 11 bytes.
@rodata
final List<u8> fileStrOpens = const [
  u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x20), u8(0x4F), u8(0x50), u8(0x45), u8(0x4E), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' READS '` -- 7 bytes.
@rodata
final List<u8> fileStrReads = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' CLOSES '` -- 8 bytes.
@rodata
final List<u8> fileStrCloses = const [
  u8(0x20), u8(0x43), u8(0x4C), u8(0x4F), u8(0x53), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' SEEKS '` -- 7 bytes.
@rodata
final List<u8> fileStrSeeks = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x45), u8(0x4B), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' REFUSED '` -- 9 bytes.
@rodata
final List<u8> fileStrRefused = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x45), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' BYTES '` -- 7 bytes.
@rodata
final List<u8> fileStrBytes = const [
  u8(0x20), u8(0x42), u8(0x59), u8(0x54), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' SECTORS '` -- 9 bytes.
@rodata
final List<u8> fileStrSectors = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x43), u8(0x54), u8(0x4F), u8(0x52), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' CHAINS '` -- 8 bytes.
@rodata
final List<u8> fileStrChains = const [
  u8(0x20), u8(0x43), u8(0x48), u8(0x41), u8(0x49), u8(0x4E), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' PEAK '` -- 6 bytes.
@rodata
final List<u8> fileStrPeak = const [
  u8(0x20), u8(0x50), u8(0x45), u8(0x41), u8(0x4B), u8(0x20),
];

/// Field separator.
///
/// `' FSERR '` -- 7 bytes.
@rodata
final List<u8> fileStrFsErr = const [
  u8(0x20), u8(0x46), u8(0x53), u8(0x45), u8(0x52), u8(0x52), u8(0x20),
];

/// Line label.
///
/// `'FILE ORPHANS '` -- 13 bytes.
@rodata
final List<u8> fileStrOrphans = const [
  u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x20), u8(0x4F), u8(0x52), u8(0x50), u8(0x48), u8(0x41), u8(0x4E), u8(0x53),
  u8(0x20),
];

// ---------------------------------------------------------------------------
// Constants. Every one of the four syscall numbers and every one of the eleven
// refusal values below is read back OUT OF THIS FILE by
// `tests/conformance/m15-fileio/run.sh` and compared against userland's copy, so
// the two cannot disagree about what a refusal LOOKS LIKE.
//
// **Nothing in core/kernel/ names the C library**, and m13-libc greps for that:
// a kernel that knew the name of its userland's header would be a kernel with a
// userland in it. The comparison is the harness's job, in both directions.
// ---------------------------------------------------------------------------

/// Syscall 5 — `open(namePtr, nameLen)`.
const int fileSysOpenNo = 5;

/// Syscall 6 — `read(fd, buf, len)`.
const int fileSysReadNo = 6;

/// Syscall 7 — `close(fd)`.
const int fileSysCloseNo = 7;

/// Syscall 8 — `seek(fd, offset)`. Absolute, and the only form there is.
const int fileSysSeekNo = 8;

/// Descriptors per program. FOUR, and the number is a bound rather than a
/// budget: a fifth `open` is [fileRetNoSlot] with nothing allocated and nothing
/// leaked, and `m15-fileio`'s program opens five files to prove it.
const int fileMaxFds = 4;

/// Descriptor rows. FIVE, because two different things can be in ring 3 on this
/// machine and only one of them is a process: rows 0..3 are the four process
/// slots and row 4 is the `run <name>` program, which has no slot.
const int fileRows = 5;

/// The row a `run <name>` program uses. Equal to `procMax` by construction —
/// the row indices below it are exactly the process slots — and asserted equal
/// to it by the harness rather than left as a coincidence.
const int fileRunRow = 4;

/// The largest single `read`. One sector, deliberately: the bounce buffer is
/// one sector, and a bound that equals the buffer means the loop below cannot
/// be wrong about how many times it has to go round.
///
/// **This is NOT a bound on the file.** A program reads a larger file by
/// calling `read` again, which is the whole point of the offset living in the
/// descriptor.
const int fileReadMax = 512;

/// The longest name `open` will accept: `12345678.123` is twelve characters.
/// A longer one is [fileRetBadName] and is refused before it is copied.
const int fileNameMax = 12;

/// Donated storage: 1280 bytes in three regions. See `core/boot/kdata.S`.
const int fileStoreBytes = 1280;
const int fileMetaOffset = 0;
const int fileTableOffset = 128;
const int fileBufOffset = 768;

/// Sixteen metadata words.
const int fileMetaWords = 16;

/// Four words per descriptor, four descriptors per row.
const int fileFdWords = 4;
const int fileRowWords = 16;

// Metadata word indices. The layout is documented once, in kdata.S.
const int fileMetaOpens = 0;
const int fileMetaReads = 1;
const int fileMetaCloses = 2;
const int fileMetaSeeks = 3;
const int fileMetaRefusals = 4;
const int fileMetaBytes = 5;
const int fileMetaSectors = 6;
const int fileMetaRebuilds = 7;
const int fileMetaStatus = 8;
const int fileMetaLive = 9;
const int fileMetaPeak = 10;
const int fileMetaSpare11 = 11;
const int fileMetaSpare12 = 12;
const int fileMetaSpare13 = 13;
const int fileMetaSpare14 = 14;
const int fileMetaSpare15 = 15;

// **THERE IS NO WORD HERE THAT NOTHING READS.** Every one of 0..10 is either
// printed by [fileExitReport] or load-bearing ([fileMetaLive] is what
// [fileMetaPeak] is computed from), and the five spares are declared as spares.
// m14's mutation round found that an unread counter is a mutation survivor by
// construction (GAP-0120, `fatMetaHits`), so M15 does not have one.

// Descriptor word indices, within a row.
const int fileFdState = 0;
const int fileFdFirst = 1;
const int fileFdSize = 2;
const int fileFdPos = 3;

/// A descriptor slot nobody has opened.
const int fileFdFree = 0;

/// A descriptor slot holding an open file.
const int fileFdOpen = 1;

// ---------------------------------------------------------------------------
// Refusal values.
//
// ADR-0016 §1's shape, reused because it worked: every refusal is a value at or
// above ONE FLOOR, so a caller distinguishes "an answer" from "a refusal" with
// ONE comparison and only then has to care which refusal it was. A byte count,
// a descriptor number and a file offset are all far below the floor, and
// `core/kernel/user.dart`'s [userRefused] — which is what a syscall this kernel
// does not have returns — is above it, so a program built against a kernel
// without these syscalls sees a refusal rather than an address.
// ---------------------------------------------------------------------------

/// At or above this is a refusal, not a result.
const int fileRetFloor = 0xFFFFFFFFFFFFFF00;

/// The descriptor number is out of range, or names a slot nothing opened.
const int fileRetBadFd = 0xFFFFFFFFFFFFFFFE;

/// The buffer failed [fileOwnsWrite] (or, for `open`, `elfOwns`): it is not
/// wholly inside pages this program owns, or — for `read` — not writable.
const int fileRetBadPtr = 0xFFFFFFFFFFFFFFFD;

/// A zero length, or one above [fileReadMax]; or a name above [fileNameMax].
const int fileRetBadLen = 0xFFFFFFFFFFFFFFFC;

/// All four descriptors are in use.
const int fileRetNoSlot = 0xFFFFFFFFFFFFFFFB;

/// The bytes are not an 8.3 name (`fatErrBadName`).
const int fileRetBadName = 0xFFFFFFFFFFFFFFFA;

/// No entry with that name in the root directory (`fatErrNotFound`).
const int fileRetNotFound = 0xFFFFFFFFFFFFFFF9;

/// The name is a subdirectory (`fatErrIsDir`). GAP-0116 item 2.
const int fileRetIsDir = 0xFFFFFFFFFFFFFFF8;

/// The entry has no clusters (`fatErrEmpty`). A zero-length file is a real
/// thing on a real volume and it is refused rather than opened, because every
/// `read` of it would be a zero at offset zero and this kernel would rather say
/// so once.
const int fileRetEmpty = 0xFFFFFFFFFFFFFFF7;

/// The volume, the chain or the drive refused. The FAT-level code is kept in
/// [fileMetaStatus] and printed by [fileExitReport], so the transcript still
/// names the field that was wrong even though the ABI does not.
const int fileRetIo = 0xFFFFFFFFFFFFFFF6;

/// A seek past the end of the file. Seeking exactly TO the end is legal and
/// returns the size: it is where a program that has read everything already is.
const int fileRetBadSeek = 0xFFFFFFFFFFFFFFF5;

/// Nothing that owns a descriptor table is in ring 3. An M9 payload — two pages
/// in the identity window, no process, no program image — can reach this gate
/// and gets this.
const int fileRetNoOwner = 0xFFFFFFFFFFFFFFF4;

// ======================  THE STORAGE SEAM  ======================
//
// `file_store` in core/boot/kdata.S is 1280 bytes of assembly-donated `.bss`.
// It is the ONLY place this subsystem's mutable state lives, and the THREE
// functions below are the ONLY call sites of `file_store_addr`.
//
// Do NOT call `file_store_addr()` anywhere else, and do NOT add a second
// `@extern` accessor for a piece of descriptor state. Either one turns the
// migration below from a three-line rewrite into an audit of the whole file. If
// a new piece of state is needed, give it one of the four spare metadata words
// — that is what they are for.
//
// The migration plan, when DCDart grows mutable statics (GAP-0053):
//
//   1. declare the metadata, the descriptor table and the bounce buffer as
//      DCDart mutable statics in this file;
//   2. rewrite the three seam functions to take their addresses;
//   3. delete `file_store` and `file_store_addr` from core/boot/kdata.S, and
//      the `@extern` declaration below.
//
// `tests/conformance/m15-fileio/run.sh` COUNTS exactly three
// `return file_store_addr()` in this file and zero anywhere else in
// core/kernel/.

/// Base of the donated block. See `core/boot/kdata.S`.
@extern
external u64 file_store_addr();

/// The 16 metadata words.
@bare
u64 fileMetaBase() {
  return file_store_addr();
}

/// The 5 x 4 x 4 descriptor words.
@bare
u64 fileTableBase() {
  return file_store_addr() + u64(fileTableOffset);
}

/// The one-sector bounce buffer. **No user pointer ever names this address.**
@bare
u64 fileBufBase() {
  return file_store_addr() + u64(fileBufOffset);
}

// ========================  END OF THE STORAGE SEAM  ========================

/// Reads metadata word [i].
@bare
u64 fileMeta(u64 i) {
  return Pointer<u64>.fromAddress(fileMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void fileSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(fileMetaBase() + (i << u64(3))).value = v;
}

/// Adds one to metadata word [i].
@bare
void fileBump(u64 i) {
  fileSetMeta(i, fileMeta(i) + u64(1));
}

/// Reads word [w] of descriptor [fd] of row [row].
@bare
u64 fileFd(u64 row, u64 fd, u64 w) {
  final u64 off = (row * u64(fileRowWords)) + (fd * u64(fileFdWords)) + w;
  return Pointer<u64>.fromAddress(fileTableBase() + (off << u64(3))).value;
}

/// Writes word [w] of descriptor [fd] of row [row].
@bare
void fileSetFd(u64 row, u64 fd, u64 w, u64 v) {
  final u64 off = (row * u64(fileRowWords)) + (fd * u64(fileFdWords)) + w;
  Pointer<u64>.fromAddress(fileTableBase() + (off << u64(3))).value = v;
}

/// Zeroes every metadata word and every descriptor word.
///
/// Called from [kmain] before the first byte of output, and it MUST be: this
/// kernel does not clear `.bss` (kdata.S's own note), and [fileExitReport] reads
/// [fileMetaOpens] on EVERY exit from ring 3 — including the exits of the six
/// existing harnesses' programs, none of which has ever opened a file. A garbage
/// word there would print a line into the middle of six byte-exact goldens.
///
/// Prints NOTHING, and must keep printing nothing:
/// `tests/conformance/m1-interrupts/run.sh` asserts the entire 544-byte serial
/// capture and its last byte is the newline after `M1 END`.
@bare
void fileInit() {
  u64 i = u64(0);
  while (i < u64(fileMetaWords)) {
    fileSetMeta(i, u64(0));
    i = i + u64(1);
  }
  u64 r = u64(0);
  while (r < u64(fileRows)) {
    u64 f = u64(0);
    while (f < u64(fileMaxFds)) {
      fileSetFd(r, f, u64(fileFdState), u64(fileFdFree));
      fileSetFd(r, f, u64(fileFdFirst), u64(0));
      fileSetFd(r, f, u64(fileFdSize), u64(0));
      fileSetFd(r, f, u64(fileFdPos), u64(0));
      f = f + u64(1);
    }
    r = r + u64(1);
  }
}

/// Which descriptor row the thing currently in ring 3 owns, or [fileRows] if
/// nothing that can own one is there.
///
/// **This is the only function that decides whose descriptors a syscall sees**,
/// and the order of the two questions is the same order [userOwns] asks them in
/// (ADR-0015 §4): a process wins, because a process and a `run <name>` program
/// cannot both be live and the process is the one with an address space of its
/// own. An M9 payload owns no row at all — it has two pages in the identity
/// window, no image and no name — and gets [fileRetNoOwner].
@bare
u64 fileOwnerRow() {
  if (procLive() > u64(0)) {
    return procCurrent();
  }
  if (elfLive() > u64(0)) {
    return u64(fileRunRow);
  }
  return u64(fileRows);
}

/// Closes every descriptor row [row] holds. Returns how many were still open,
/// which the caller prints — see [fileOrphanLine].
///
/// **Called from the TEARDOWN path, not from the exit syscall**, so that a
/// program which faults with three files open leaks nothing either. `elf.dart`'s
/// [elfTeardown] and `proc.dart`'s [procCleanup] are the two callers and both of
/// them run on the fault path as well as the normal one — which is the property
/// M9 established for pages and this extends to descriptors.
@bare
u64 fileReleaseOwner(u64 row) {
  if (row >= u64(fileRows)) {
    return u64(0);
  }
  u64 n = u64(0);
  u64 f = u64(0);
  while (f < u64(fileMaxFds)) {
    if (fileFd(row, f, u64(fileFdState)) > u64(fileFdFree)) {
      n = n + u64(1);
      fileSetFd(row, f, u64(fileFdState), u64(fileFdFree));
      fileSetFd(row, f, u64(fileFdFirst), u64(0));
      fileSetFd(row, f, u64(fileFdSize), u64(0));
      fileSetFd(row, f, u64(fileFdPos), u64(0));
    }
    f = f + u64(1);
  }
  if (n > u64(0)) {
    fileSetMeta(u64(fileMetaLive), fileMeta(u64(fileMetaLive)) - n);
  }
  return n;
}

/// `FILE ORPHANS <n>`
///
/// Printed by the teardown paths when a program went away with descriptors
/// still open. **This is not an error and it does not mean a leak** — it means
/// the opposite: the kernel closed what the program did not, and says how many.
/// A program that closes everything it opened never produces this line, which
/// is why `m15-fileio`'s main program does not and its fault variant would.
@bare
void fileOrphanLine(u64 n) {
  uartWrite(Rodata.addressOf(fileStrOrphans), u64(13));
  uartPutHex(n, u64(2));
  uartNewline();
}

/// The lowest free descriptor in [row], or [fileMaxFds] if the row is full.
@bare
u64 fileFreeFd(u64 row) {
  u64 f = u64(0);
  while (f < u64(fileMaxFds)) {
    if (fileFd(row, f, u64(fileFdState)) < u64(fileFdOpen)) {
      return f;
    }
    f = f + u64(1);
  }
  return u64(fileMaxFds);
}

/// 1 if `[ptr, ptr+len)` lies wholly inside pages the current program owns
/// **and can write to**.
///
/// **This is the function M15 exists to get right.** [elfOwns] answers "may
/// ring 3 read this", which is what every syscall before `read` needed; this
/// answers "may ring 3 WRITE this", and the difference is one bit out of
/// [vmEffective] and the whole of W^X. The program's R+X segment passes
/// [elfOwns] and fails this, on purpose, and `m15-fileio`'s program aims a
/// `read` at its own `.rodata` to prove it.
///
/// The bound on [ptr] comes FIRST, before any arithmetic on it, for
/// [userOwns]'s exact reason (ADR-0013 §5): DCDart's arithmetic traps on
/// overflow with a real `ud2`, and `ptr` is a value ring 3 chose, so
/// `read(fd, 0xFFFFFFFFFFFFFFFF, 512)` would otherwise take a #UD *inside the
/// syscall handler* — a ring-3 program choosing which instruction the kernel
/// executes next, using the very test that was meant to stop it.
///
/// Written out rather than folded into [elfOwns] with a flag because `@bare`
/// DCDart has no boolean parameters and no default arguments, and because a
/// validator whose meaning depends on an argument is a validator somebody will
/// eventually call with the wrong one.
@bare
u64 fileOwnsWrite(u64 ptr, u64 len) {
  if (ptr < u64(vmProgBase)) {
    return u64(0);
  }
  if (ptr >= u64(vmProgEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(fileReadMax)) {
    return u64(0);
  }
  if ((ptr + len) > u64(vmProgEnd)) {
    return u64(0);
  }
  u64 a = ptr & u64(0xFFFFFFFFFFFFF000);
  final u64 last = (ptr + len - u64(1)) & u64(0xFFFFFFFFFFFFF000);
  while (a <= last) {
    final u64 e = vmEffective(a);
    if ((e & u64(2)) < u64(1)) {
      return u64(0); // not reachable from ring 3 at all
    }
    if ((e & u64(4)) < u64(1)) {
      return u64(0); // reachable, but read-only: W^X says no
    }
    a = a + u64(vmPageBytes);
  }
  return u64(1);
}

/// Copies [n] bytes from the bounce buffer at `[fileBufBase() + from)` to
/// `[dst, dst+n)`.
///
/// **This is the only store to a caller-supplied address in this file**, and
/// its only caller has already run [fileOwnsWrite] over exactly `[dst, dst+n)`.
/// Nothing between that check and this copy can change the tables: the gate is
/// an interrupt gate, so interrupts are off, and this kernel is single-CPU and
/// does not preempt inside a syscall.
@bare
void fileCopyOut(u64 dst, u64 from, u64 n) {
  final u64 src = fileBufBase() + from;
  u64 i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Records a refusal and hands [code] back to ring 3 in RAX.
///
/// Counted, always, so that "the program said it was refused" and "the kernel
/// refused" are two independent statements a transcript can compare.
/// **[fileMetaStatus] is NOT written here**, deliberately: it holds the last
/// FAT-level refusal, which is a different vocabulary from this one and is the
/// only place the filesystem's own account of what was wrong survives. Writing
/// this file's value into it would make `FSERR` print the same number the
/// program already has.
@bare
void fileRefuse(u64 frame, u64 code) {
  fileBump(u64(fileMetaRefusals));
  userSetFrame(frame, u64(userFrameRax), code);
}

/// Turns a `fatErr*` code into this file's vocabulary, keeping the FAT-level
/// code in [fileMetaStatus] so the transcript can still name the field.
///
/// A chain of comparisons each ending in `return` rather than a dense chain,
/// for GAP-0088's reason: LLVM turns a dense chain into a jump table in a
/// section this repo does not control.
@bare
u64 fileFromFat(u64 code) {
  if (code == u64(fatErrNotFound)) {
    return u64(fileRetNotFound);
  }
  if (code == u64(fatErrIsDir)) {
    return u64(fileRetIsDir);
  }
  if (code == u64(fatErrBadName)) {
    return u64(fileRetBadName);
  }
  if (code == u64(fatErrEmpty)) {
    return u64(fileRetEmpty);
  }
  return u64(fileRetIo);
}

/// Makes the chain array describe descriptor [fd] of [row], counting the walk
/// if one was needed. Returns a `fatErr*` code.
@bare
u64 fileChainFor(u64 row, u64 fd) {
  final u64 first = fileFd(row, fd, u64(fileFdFirst));
  final u64 size = fileFd(row, fd, u64(fileFdSize));
  if (fatSelected(first, size) < u64(1)) {
    fileBump(u64(fileMetaRebuilds));
  }
  return fatSelect(first, size);
}

/// Syscall 5 — `open(namePtr, nameLen)`. Returns a descriptor number, 0..3, or
/// a refusal.
///
/// **The name is copied into the kernel before it is parsed, and that ordering
/// is the point.** `fatParseAt` walks the bytes several times and compares them
/// against directory entries; doing that through a pointer ring 3 still owns
/// would be a validator with a window in it. So: bound the length, validate the
/// range with [elfOwns], copy into [fileBufBase], and from there on the bytes
/// are the kernel's.
///
/// A descriptor is taken only after the file has been found and its chain
/// walked, so a refused `open` leaves the table exactly as it was.
@bare
void fileSysOpen(u64 frame) {
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    fileRefuse(frame, u64(fileRetNoOwner));
    return;
  }
  final u64 ptr = userFrame(frame, u64(userFrameRdi));
  final u64 len = userFrame(frame, u64(userFrameRsi));
  if (len < u64(1)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  if (len > u64(fileNameMax)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  if (elfOwns(ptr, len) < u64(1)) {
    fileRefuse(frame, u64(fileRetBadPtr));
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
  if (pn > u64(fatErrOk)) {
    fileSetMeta(u64(fileMetaStatus), pn);
    fileRefuse(frame, u64(fileRetBadName));
    return;
  }
  final u64 fd = fileFreeFd(row);
  if (fd >= u64(fileMaxFds)) {
    fileRefuse(frame, u64(fileRetNoSlot));
    return;
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    fileSetMeta(u64(fileMetaStatus), fs);
    fileRefuse(frame, fileFromFat(fs));
    return;
  }
  fileSetFd(row, fd, u64(fileFdFirst), fatFileFirst());
  fileSetFd(row, fd, u64(fileFdSize), fatFileBytes());
  fileSetFd(row, fd, u64(fileFdPos), u64(0));
  fileSetFd(row, fd, u64(fileFdState), u64(fileFdOpen));
  fileBump(u64(fileMetaOpens));
  fileSetMeta(u64(fileMetaLive), fileMeta(u64(fileMetaLive)) + u64(1));
  if (fileMeta(u64(fileMetaPeak)) < fileMeta(u64(fileMetaLive))) {
    fileSetMeta(u64(fileMetaPeak), fileMeta(u64(fileMetaLive)));
  }
  userSetFrame(frame, u64(userFrameRax), fd);
}

/// Syscall 6 — `read(fd, buf, len)`. Returns how many bytes were delivered —
/// which may be fewer than [len], and is 0 at end of file — or a refusal.
///
/// **A short read is not an error and the program is required to notice.** The
/// count is `min(len, size - pos)`, so the last read of a file that is not a
/// multiple of the chunk size returns the remainder; `m15-fileio` builds a
/// second copy of its program that IGNORES the returned count and hashes the
/// whole chunk anyway, and requires that program to produce a different, also
/// derived, answer. That is what makes the count load-bearing rather than
/// decorative.
///
/// The loop is per SECTOR, not per cluster and not per byte: the offset inside
/// the file is turned into a sector index, [fatFileSector] turns that into an
/// LBA THROUGH THE CLUSTER CHAIN, and the piece of that sector the request wants
/// is copied out. A read that starts mid-sector and ends mid-sector in another
/// cluster is therefore three lines rather than a special case.
@bare
void fileSysRead(u64 frame) {
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    fileRefuse(frame, u64(fileRetNoOwner));
    return;
  }
  final u64 fd = userFrame(frame, u64(userFrameRdi));
  final u64 dst = userFrame(frame, u64(userFrameRsi));
  final u64 len = userFrame(frame, u64(userFrameRdx));
  if (fd >= u64(fileMaxFds)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  if (fileFd(row, fd, u64(fileFdState)) < u64(fileFdOpen)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  if (len < u64(1)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  if (len > u64(fileReadMax)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  if (fileOwnsWrite(dst, len) < u64(1)) {
    fileRefuse(frame, u64(fileRetBadPtr));
    return;
  }
  final u64 size = fileFd(row, fd, u64(fileFdSize));
  final u64 pos = fileFd(row, fd, u64(fileFdPos));
  if (pos >= size) {
    userSetFrame(frame, u64(userFrameRax), u64(0));
    return;
  }
  u64 want = len;
  if ((size - pos) < want) {
    want = size - pos;
  }
  final u64 cs = fileChainFor(row, fd);
  if (cs > u64(fatErrOk)) {
    fileSetMeta(u64(fileMetaStatus), cs);
    fileRefuse(frame, u64(fileRetIo));
    return;
  }
  u64 done = u64(0);
  while (done < want) {
    final u64 off = pos + done;
    final u64 inSec = off & u64(511);
    u64 n = u64(fatSectorBytes) - inSec;
    if (n > (want - done)) {
      n = want - done;
    }
    final u64 lba = fatFileSector(off >> u64(fatSectorShift));
    if (lba < u64(1)) {
      fileSetMeta(u64(fileMetaStatus), u64(fatErrChainRange));
      fileRefuse(frame, u64(fileRetIo));
      return;
    }
    if (fatReadSector(lba, fileBufBase()) > u64(0)) {
      fileSetMeta(u64(fileMetaStatus), u64(fatErrDiskData));
      fileRefuse(frame, u64(fileRetIo));
      return;
    }
    fileBump(u64(fileMetaSectors));
    fileCopyOut(dst + done, inSec, n);
    done = done + n;
  }
  fileSetFd(row, fd, u64(fileFdPos), pos + done);
  fileBump(u64(fileMetaReads));
  fileSetMeta(u64(fileMetaBytes), fileMeta(u64(fileMetaBytes)) + done);
  userSetFrame(frame, u64(userFrameRax), done);
}

/// Syscall 7 — `close(fd)`. Returns 0, or [fileRetBadFd].
///
/// Closing twice is a refusal and not a no-op, deliberately: a program that
/// closes a descriptor it does not hold has a bug, and this is the only place
/// that can tell it so.
@bare
void fileSysClose(u64 frame) {
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    fileRefuse(frame, u64(fileRetNoOwner));
    return;
  }
  final u64 fd = userFrame(frame, u64(userFrameRdi));
  if (fd >= u64(fileMaxFds)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  if (fileFd(row, fd, u64(fileFdState)) < u64(fileFdOpen)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  fileSetFd(row, fd, u64(fileFdState), u64(fileFdFree));
  fileSetFd(row, fd, u64(fileFdFirst), u64(0));
  fileSetFd(row, fd, u64(fileFdSize), u64(0));
  fileSetFd(row, fd, u64(fileFdPos), u64(0));
  fileBump(u64(fileMetaCloses));
  fileSetMeta(u64(fileMetaLive), fileMeta(u64(fileMetaLive)) - u64(1));
  userSetFrame(frame, u64(userFrameRax), u64(0));
}

/// Syscall 8 — `seek(fd, offset)`. Absolute. Returns the new offset, or
/// [fileRetBadSeek].
///
/// **There is no `whence`.** SEEK_SET is what a program needs to re-read a
/// piece of a file it has already measured, SEEK_CUR is the offset the
/// descriptor already keeps and SEEK_END is `size` — which a program cannot ask
/// for here, and that is a real gap, recorded in GAP-0122 item 4 rather than
/// papered over. One form, one argument, no enumeration to get wrong.
@bare
void fileSysSeek(u64 frame) {
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    fileRefuse(frame, u64(fileRetNoOwner));
    return;
  }
  final u64 fd = userFrame(frame, u64(userFrameRdi));
  final u64 to = userFrame(frame, u64(userFrameRsi));
  if (fd >= u64(fileMaxFds)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  if (fileFd(row, fd, u64(fileFdState)) < u64(fileFdOpen)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  if (to > fileFd(row, fd, u64(fileFdSize))) {
    fileRefuse(frame, u64(fileRetBadSeek));
    return;
  }
  fileSetFd(row, fd, u64(fileFdPos), to);
  fileBump(u64(fileMetaSeeks));
  userSetFrame(frame, u64(userFrameRax), to);
}

/// `FILE OPENS <n> READS <n> CLOSES <n> SEEKS <n> REFUSED <n> BYTES <n>
/// SECTORS <n> CHAINS <n> PEAK <n> FSERR <n>`
///
/// Printed from the exit path, and **only if something ever opened a file**.
/// That guard is not tidiness: six existing harnesses assert a byte-exact
/// serial capture of a session in which a program runs and exits, and none of
/// their programs has ever called `open`. A line printed unconditionally here
/// would move six goldens for nothing.
///
/// The counters are CUMULATIVE OVER THE BOOT rather than per-program, which is
/// the honest description of where they live: one donated block, one machine.
/// `m15-fileio` boots once and runs one program, so its numbers are that
/// program's, and the harness derives every one of them from the image it built.
@bare
void fileExitReport() {
  if (fileMeta(u64(fileMetaOpens)) < u64(1)) {
    return;
  }
  uartWrite(Rodata.addressOf(fileStrOpens), u64(11));
  uartPutHex(fileMeta(u64(fileMetaOpens)), u64(8));
  uartWrite(Rodata.addressOf(fileStrReads), u64(7));
  uartPutHex(fileMeta(u64(fileMetaReads)), u64(8));
  uartWrite(Rodata.addressOf(fileStrCloses), u64(8));
  uartPutHex(fileMeta(u64(fileMetaCloses)), u64(8));
  uartWrite(Rodata.addressOf(fileStrSeeks), u64(7));
  uartPutHex(fileMeta(u64(fileMetaSeeks)), u64(8));
  uartWrite(Rodata.addressOf(fileStrRefused), u64(9));
  uartPutHex(fileMeta(u64(fileMetaRefusals)), u64(8));
  uartWrite(Rodata.addressOf(fileStrBytes), u64(7));
  uartPutHex(fileMeta(u64(fileMetaBytes)), u64(8));
  uartWrite(Rodata.addressOf(fileStrSectors), u64(9));
  uartPutHex(fileMeta(u64(fileMetaSectors)), u64(8));
  uartWrite(Rodata.addressOf(fileStrChains), u64(8));
  uartPutHex(fileMeta(u64(fileMetaRebuilds)), u64(8));
  uartWrite(Rodata.addressOf(fileStrPeak), u64(6));
  uartPutHex(fileMeta(u64(fileMetaPeak)), u64(2));
  uartWrite(Rodata.addressOf(fileStrFsErr), u64(7));
  uartPutHex(fileMeta(u64(fileMetaStatus)), u64(2));
  uartNewline();
}
