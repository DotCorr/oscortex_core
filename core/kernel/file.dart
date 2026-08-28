// core/kernel/file.dart
//
// oscortex_core M15: FILE DESCRIPTORS, AND A PROGRAM THAT CAN READ. The four
// syscalls -- `open`, `read`, `close`, `seek` -- that connect M14's read-only
// FAT16 filesystem to M13's C library, and the per-program descriptor table
// that holds the offset between one `read` and the next.
//
// oscortex_core M16: AND A PROGRAM THAT CAN WRITE. `open` grew a MODE, syscall
// 9 is `fdwrite`, and `close` became the thing that puts a file in a directory.
// The architecture is docs/decisions/0020-writing-to-a-disk.md; the binary exit
// criterion is ROADMAP.md's M16 and tests/conformance/m16-filewrite/run.sh.
//
// **A WRITE DESCRIPTOR IS APPEND-ONLY AND STARTS EMPTY.** `open(name, O_WRITE)`
// creates the file or empties it; `seek` on the descriptor it returns is
// refused, and so is `read`. That is a smaller thing than POSIX `O_WRONLY` and
// ADR-0020 §0 gives the reason. GAP-0127 lists, in sixteen items, everything a
// program therefore still cannot do to a file.
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
// **What is still absent is written down in docs/known-gaps.md GAP-0122 and
// GAP-0127 rather than implied by silence**: at M15 there were no writes
// anywhere, and M16 changed that and nothing else on the list -- no
// directories, no `stat`, no `dup`, no `stdin`, no console input, no `errno`,
// no VFS and no second filesystem. `open` takes an 8.3 name in the root
// directory and nothing else; there is no path, because there is nowhere for a
// path to lead.
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

/// Per-refusal line label — the one [fileRefuse] prints, once per refusal.
///
/// **Not the same string as [fileStrRefused], deliberately.** That one is a
/// FIELD SEPARATOR on the exit aggregate (` REFUSED 0000000E`), which says how
/// many refusals happened and nothing about which. This one begins a LINE that
/// names the code, and the two are kept apart so that a transcript's per-call
/// evidence and its total are never the same bytes.
///
/// `'FILE REFUSED '` -- 13 bytes.
@rodata
final List<u8> fileStrRefuseLine = const [
  u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x45), u8(0x44),
  u8(0x20),
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

/// `'FILEW WRITES '` -- 13 bytes.
@rodata
final List<u8> fileStrWrites = const [
  u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x57), u8(0x20), u8(0x57), u8(0x52), u8(0x49), u8(0x54), u8(0x45), u8(0x53),
  u8(0x20),
];

/// `' CREATED '` -- 9 bytes.
@rodata
final List<u8> fileStrCreated = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x45), u8(0x41), u8(0x54), u8(0x45), u8(0x44), u8(0x20),
];

/// `' TRUNC '` -- 7 bytes.
@rodata
final List<u8> fileStrTrunc = const [
  u8(0x20), u8(0x54), u8(0x52), u8(0x55), u8(0x4E), u8(0x43), u8(0x20),
];

/// `' FLUSH '` -- 7 bytes.
@rodata
final List<u8> fileStrFlush = const [
  u8(0x20), u8(0x46), u8(0x4C), u8(0x55), u8(0x53), u8(0x48), u8(0x20),
];

/// `' DISKW '` -- 7 bytes.
@rodata
final List<u8> fileStrDiskW = const [
  u8(0x20), u8(0x44), u8(0x49), u8(0x53), u8(0x4B), u8(0x57), u8(0x20),
];

/// `' ALLOC '` -- 7 bytes.
@rodata
final List<u8> fileStrAlloc = const [
  u8(0x20), u8(0x41), u8(0x4C), u8(0x4C), u8(0x4F), u8(0x43), u8(0x20),
];

/// `' FREED '` -- 7 bytes.
@rodata
final List<u8> fileStrFreed = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

// ---------------------------------------------------------------------------
// Constants. Every one of the FIVE syscall numbers and every one of the THIRTEEN
// refusal values below is read back OUT OF THIS FILE by
// `tests/conformance/m16-filewrite/run.sh` and compared against userland's copy,
// so the two cannot disagree about what a refusal LOOKS LIKE.
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

/// M16 — syscall 9, `fdwrite(fd, buf, len)`.
///
/// **It is not called `write` and the name is the interface.** Syscall 1 is
/// `write(buf, len)` and it prints on the console; six byte-exact goldens
/// contain its output and it takes no descriptor. Calling this one `write` too
/// would mean two syscalls with one name distinguished by arity, in a C library
/// where the console one has been `write` since M13. `fdwrite` writes to a file
/// descriptor and says so. GAP-0128 records what a real `write(1, ...)` would
/// cost and why it was not this milestone's business.
const int fileSysWriteNo = 9;

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

/// The largest single `fdwrite`. One sector, for [fileReadMax]'s reason and one
/// more: the bytes are copied out of the caller's pages into the kernel BEFORE
/// any of them reaches the drive, and the buffer they are copied into is one
/// sector. A program writes more by calling again.
const int fileWriteMax = 512;

/// Donated storage: 2560 bytes in FOUR regions. See `core/boot/kdata.S`.
///
/// M16 took this from 1280: the metadata doubled to 32 words (M16 has six
/// counters of its own), a descriptor doubled from four words to eight (an
/// entry index, a last cluster, a mode and a spare), and a SECOND 512-byte
/// sector buffer appeared — see [fileSecBase] for why one is not enough.
const int fileStoreBytes = 2560;
const int fileMetaOffset = 0;
const int fileTableOffset = 256;
const int fileBufOffset = 1536;
const int fileSecOffset = 2048;

/// Thirty-two metadata words.
const int fileMetaWords = 32;

/// Eight words per descriptor, four descriptors per row.
const int fileFdWords = 8;
const int fileRowWords = 32;

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
// M16's six. Every one of them is printed by [fileWriteReport].
const int fileMetaWrites = 11;
const int fileMetaWBytes = 12;
const int fileMetaWSectors = 13;
const int fileMetaCreates = 14;
const int fileMetaTruncs = 15;
const int fileMetaFlushes = 16;

const int fileMetaSpare17 = 17;
const int fileMetaSpare18 = 18;
const int fileMetaSpare19 = 19;
const int fileMetaSpare20 = 20;
const int fileMetaSpare21 = 21;
const int fileMetaSpare22 = 22;
const int fileMetaSpare23 = 23;
const int fileMetaSpare24 = 24;
const int fileMetaSpare25 = 25;
const int fileMetaSpare26 = 26;
const int fileMetaSpare27 = 27;
const int fileMetaSpare28 = 28;
const int fileMetaSpare29 = 29;
const int fileMetaSpare30 = 30;
const int fileMetaSpare31 = 31;

// **THERE IS NO WORD HERE THAT NOTHING READS.** Every one of 0..16 is either
// printed by [fileExitReport] or [fileWriteReport] or load-bearing
// ([fileMetaLive] is what [fileMetaPeak] is computed from), and the spares are
// declared as spares. m14's mutation round found that an unread counter is a
// mutation survivor by construction (GAP-0120, `fatMetaHits`), so neither M15
// nor M16 has one.

// Descriptor word indices, within a row.
const int fileFdState = 0;
const int fileFdFirst = 1;
const int fileFdSize = 2;
const int fileFdPos = 3;

/// M16. The root-directory entry index this descriptor came from, the LAST
/// cluster of its chain, and a spare.
///
/// **[fileFdLast] is what makes appending cost no FAT walk.** A write-mode
/// descriptor is append-only (see [fileSysWrite]), so the only cluster it ever
/// needs is the one at the end, and it is the one [fatAlloc] just returned.
/// `fat.dart`'s chain array is never consulted on the write path at all.
const int fileFdEntry = 4;
const int fileFdLast = 5;

/// How many BYTES of cluster this descriptor has allocated. Always a multiple
/// of the cluster size, and always at least the file's size.
///
/// **This word is what makes a failed write retryable without leaking a
/// cluster.** [fileWriteChunk] says why the obvious test — "is the offset on a
/// cluster boundary" — is not the same question.
const int fileFdAlloc = 6;

/// S0 (ADR-0033). Which DEVICE this descriptor names, when its state is
/// [fileFdDevice]. Meaningless — and zero, because [fileClearFd] zeroes the
/// row — for every other state.
///
/// **This was `fileFdSpare7` and it is now spoken for**, which is what the
/// spares were declared for (see the note above: this file has no word nothing
/// reads). A device descriptor has no cluster chain, no size and no position,
/// so words 1..6 stay zero for one and the only thing that distinguishes
/// `/dev/dri/card0` from `/dev/dri/renderD128` lives here.
const int fileFdDevIndex = 7;

/// A descriptor slot nobody has opened.
const int fileFdFree = 0;

/// A descriptor slot holding a file open FOR READING.
const int fileFdOpen = 1;

/// M16 — a descriptor slot holding a file open FOR WRITING. A different value
/// rather than a flag word, so that every `state >= fileFdOpen` test in this
/// file keeps meaning "there is a file here" and every operation that cares
/// which kind compares for equality.
const int fileFdWrite = 2;

/// S0 (ADR-0033) — a descriptor slot holding a DEVICE, not a file.
///
/// **Above [fileFdWrite] on purpose, so that every existing test in this file
/// does the right thing with one without being told about devices.**
/// `state >= fileFdOpen` still means "there is something here", so
/// [fileFreeFd], [fileReleaseOwner] and [fileSysClose] handle a device
/// descriptor correctly with no change at all. And `read`, `seek` and
/// `fdwrite` all compare for EQUALITY against the state they need
/// ([fileFdOpen] or [fileFdWrite]), so all three refuse a device descriptor
/// with [fileRetBadMode] — which is the right answer and was already written.
/// [fileFlushFd]'s first line is `!= fileFdWrite`, so closing a device writes
/// no directory entry.
///
/// The only thing that had to be added is the branch in [fileSysOpen] that
/// creates one, and `ioctl.dart`'s check that a descriptor it is handed IS
/// one.
const int fileFdDevice = 3;

/// The two values `open`'s third argument may take. Anything else is
/// [fileRetBadMode], refused before the name is even parsed.
const int fileOpenRead = 0;
const int fileOpenWrite = 1;

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

/// M16 — the descriptor is open for the OTHER thing. `fdwrite` to a read
/// descriptor, `read` or `seek` on a write descriptor, or an `open` mode that
/// is neither [fileOpenRead] nor [fileOpenWrite].
///
/// A read-only descriptor and a write-only descriptor are two different objects
/// here and this is the refusal that says so. There is no read-write mode: see
/// GAP-0127 item 2.
const int fileRetBadMode = 0xFFFFFFFFFFFFFFF3;

/// M16 — the volume is full: [fatFindFree] scanned every cluster and found none
/// free, or the root directory has no reusable entry.
///
/// **Nothing was changed when this is returned.** It is produced before the FAT
/// entry that would have consumed the cluster is written, which is what makes
/// "the disk filled up" a refusal rather than a corruption.
const int fileRetNoSpace = 0xFFFFFFFFFFFFFFF2;

/// GAP-0152 — the file is marked read-only on the volume, so `open(name,
/// O_WRITE)` is refused.
///
/// **Nothing was changed when this is returned, and that is the whole point.**
/// The refusal is produced by [fileMakeEmpty] before [fatClose], before
/// [fatTruncate] and before [fatDirWrite], so the chain, the FAT and the
/// directory entry are all exactly as they were. A refusal that still truncated
/// would satisfy a test that only looked at the return value, which is why
/// m16-filewrite compares the file's bytes back through the host's own `msdos`
/// driver afterwards rather than trusting this number.
///
/// It is the fourteenth refusal and the first that is about PERMISSION. See
/// docs/decisions/0024-the-read-only-attribute.md.
const int fileRetReadOnly = 0xFFFFFFFFFFFFFFF1;

// ======================  THE STORAGE SEAM  ======================
//
// `fileStore` is 2560 bytes of DCDart `@bss` mutable static, declared here in
// the file that owns it. Until M17 (ADR-0021) it was 2560 bytes of
// assembly-donated `.bss` in core/boot/kdata.S reached through
// `@extern u64 file_store_addr()`; the migration was the declaration below plus
// four `return file_store_addr()` becoming four `return
// Bss.addressOf(fileStore)`, AND NOTHING ELSE IN THIS FILE.
//
// It is still the ONLY place this subsystem's mutable state lives, and the FOUR
// functions below are still the only things that know where it is. Do NOT name
// `fileStore` anywhere else. If a new piece of state is needed, give it one of
// the four spare metadata words — that is what they are for.
//
// `tests/conformance/m16-filewrite/run.sh` COUNTS exactly four
// `return Bss.addressOf(fileStore)` in this file and zero anywhere else in
// core/kernel/, and m15-fileio counts the same four.

/// The 2560 bytes this subsystem owns, as a DCDart mutable static.
@bss
final Bss fileStore = const Bss(bytes: fileStoreBytes);

/// The 32 metadata words.
@bare
u64 fileMetaBase() {
  return Bss.addressOf(fileStore);
}

/// The 5 x 4 x 8 descriptor words.
@bare
u64 fileTableBase() {
  return Bss.addressOf(fileStore) + u64(fileTableOffset);
}

/// The one-sector bounce buffer. **No user pointer ever names this address.**
///
/// Both directions land here: `read` fills it off the drive and copies out of
/// it, and `fdwrite` copies the caller's bytes INTO it before one of them
/// reaches the FAT layer. That ordering is the whole of M16's pointer-safety
/// argument — see [fileSysWrite].
@bare
u64 fileBufBase() {
  return Bss.addressOf(fileStore) + u64(fileBufOffset);
}

/// M16 — the read-modify-write sector. **No user pointer ever names this one
/// either.**
///
/// **Why a fourth region and not a fourth use of [fileBufBase].** A `fdwrite`
/// that does not start and end on a sector boundary has to read the sector that
/// is already there, splice the caller's bytes into it, and write the whole
/// sector back. That needs the caller's bytes and the drive's bytes in memory
/// at the same time, in two different buffers. Using one buffer for both would
/// mean the read off the drive destroyed the data being written — which is a
/// bug that only shows up on a write whose length is not a multiple of 512,
/// which is most of them.
///
/// `fat.dart`'s own sector buffer is not available for this either, and for the
/// reason its note already gives: that buffer is a CACHE keyed by LBA, and
/// putting a data sector through it would make the next FAT read believe a data
/// sector was a FAT sector.
@bare
u64 fileSecBase() {
  return Bss.addressOf(fileStore) + u64(fileSecOffset);
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

/// Puts descriptor [fd] of [row] back to "nobody has opened this".
///
/// **Every one of the eight words, every time.** M16 doubled a descriptor from
/// four words to eight, and the three places that release one — [fileInit],
/// [fileReleaseOwner] and [fileSysClose] — each cleared four of them by hand.
/// One function, called from all three, is why adding a ninth word later cannot
/// leave a stale value behind in two of them.
@bare
void fileClearFd(u64 row, u64 fd) {
  fileSetFd(row, fd, u64(fileFdState), u64(fileFdFree));
  fileSetFd(row, fd, u64(fileFdFirst), u64(0));
  fileSetFd(row, fd, u64(fileFdSize), u64(0));
  fileSetFd(row, fd, u64(fileFdPos), u64(0));
  fileSetFd(row, fd, u64(fileFdEntry), u64(0));
  fileSetFd(row, fd, u64(fileFdLast), u64(0));
  fileSetFd(row, fd, u64(fileFdAlloc), u64(0));
  fileSetFd(row, fd, u64(fileFdDevIndex), u64(0));
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
      fileClearFd(r, f);
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
      // M16: A WRITE DESCRIPTOR IS FLUSHED BEFORE IT IS DROPPED, EVEN HERE.
      // This path runs on the FAULT path as well as the normal one, and the
      // alternative is worse than losing the data: the FAT links and the data
      // sectors are already on the drive, and only the directory entry's size
      // and first cluster are not. Dropping the descriptor without writing them
      // leaves a chain of clusters marked in use that no directory entry points
      // at — which is precisely what `fsck_msdos` calls a lost chain. Flushing
      // turns "the program crashed" into "the file has the bytes it had written
      // when it crashed", which is both truthful and a clean volume.
      // There is nobody left to hand a refusal to on this path, so a failed
      // flush is COUNTED instead: [fileMetaRefusals] is printed by the exit
      // report and [fileMetaStatus] carries the FAT-level code. A teardown that
      // could not write a directory entry is a thing the transcript has to say.
      final u64 fl = fileFlushFd(row, f);
      if (fl > u64(fatErrOk)) {
        fileBump(u64(fileMetaRefusals));
      }
      fileClearFd(row, f);
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
  if (ptr >= u64(vmUserEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(fileReadMax)) {
    return u64(0);
  }
  if ((ptr + len) > u64(vmUserEnd)) {
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

/// Records a refusal, NAMES IT ON THE CONSOLE, and hands [code] back to ring 3
/// in RAX.
///
/// Counted, always, so that "the program said it was refused" and "the kernel
/// refused" are two independent statements a transcript can compare.
/// **[fileMetaStatus] is NOT written here**, deliberately: it holds the last
/// FAT-level refusal, which is a different vocabulary from this one and is the
/// only place the filesystem's own account of what was wrong survives. Writing
/// this file's value into it would make `FSERR` print the same number the
/// program already has.
///
/// **THE `uartWrite` IS THE FIX FOR A DEFECT, NOT DECORATION.** Until it was
/// added this function's whole body was the two lines above it, and all 43 call
/// sites (file.dart:1258-1716) were silent. Ring 3 could tell the fourteen
/// codes apart — each is a distinct 64-bit value in RAX — but the OPERATOR
/// reading the serial transcript could not: the only thing the kernel said
/// about a refusal was the aggregate ` REFUSED <n>` at exit, and the `FSERR`
/// field beside it carries the FAT-level code rather than this one. Three of
/// the fourteen had never appeared in any golden in the repository.
///
/// The line is `FILE REFUSED <16 hex>` because that is the shape
/// [ioctlRefuse] already prints (`IOCTL REFUSED <16 hex>`), and consistency
/// with the module that already got this right is worth more than a shorter
/// line. docs/decisions/0038-a-refusal-that-does-not-name-itself.md.
@bare
void fileRefuse(u64 frame, u64 code) {
  fileBump(u64(fileMetaRefusals));
  uartWrite(Rodata.addressOf(fileStrRefuseLine), u64(13));
  uartPutHex(code, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), code);
}

/// Records a FAT-level failure in [fileMetaStatus] **and narrates it**.
///
/// The second half is the other end of the same defect [fileRefuse]'s comment
/// describes. Four of `fat.dart`'s codes — `fatErrFull` (1D),
/// `fatErrNoDirSlot` (1E), `fatErrDiskWrite` (1F) and `fatErrReadOnly` (20) —
/// are reached ONLY through this file's syscalls, and this file translates them
/// into its own vocabulary before ring 3 ever sees them. That translation is
/// lossy in both directions:
///
///   * `fatErrFull` and `fatErrNoDirSlot` BOTH become [fileRetNoSpace], so the
///     file-level code cannot tell a full volume from a full directory;
///   * `fatErrDiskWrite` becomes [fileRetIo], which eight other conditions also
///     become; and
///   * a SHORT write reports a byte count and refuses nothing at all, so
///     `fatErrFull` can be reached on a call that never calls [fileRefuse].
///
/// So the FAT code has to name itself where it is RECORDED rather than where it
/// is returned. [fatReportError] is the function `fat.dart` already uses for
/// exactly this, with a distinct sentence for all 32 codes, and calling it here
/// puts the same `FS ERR <hh> <sentence>` line in the transcript whether the
/// failure arrived through `cat` or through `fdwrite`.
@bare
void fileFatStatus(u64 code) {
  fileSetMeta(u64(fileMetaStatus), code);
  fatReportError(code);
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
  if (code == u64(fatErrReadOnly)) {
    return u64(fileRetReadOnly);
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

// ===========================================================================
// M16 (docs/decisions/0020-writing-to-a-disk.md): THE WRITE SYSCALL.
//
// WHAT A WRITE DESCRIPTOR IS, STATED ONCE
// ---------------------------------------------------------------------------
// `open(name, O_WRITE)` gives back a descriptor that is APPEND-ONLY AND STARTS
// EMPTY. If the name is not in the root directory it is created; if it is, the
// file is truncated to zero length and its clusters are returned to the FAT
// before one byte of the new contents is written. Its offset begins at 0, every
// `fdwrite` puts its bytes at the offset and advances it, and `seek` on it is
// [fileRetBadMode].
//
// **That is a smaller thing than POSIX `O_WRONLY` and the difference is the
// point.** A general write — at an arbitrary offset, into the middle of an
// existing chain, changing a size that may shrink — needs the cluster chain of
// a file that is being modified while it is being walked, which is the case
// where a wrong FAT update silently joins two files together. Append-only means
// the only cluster the code ever needs is the one at the end, the only FAT
// entry it ever changes is that one's, and "which cluster holds offset X" is
// never a question that has to be answered by walking anything. GAP-0127 item 1
// records exactly what is missing and what it would cost.
//
// THE POINTER-SAFETY PROPERTY, AND HOW IT DIFFERS FROM M15's
// ---------------------------------------------------------------------------
// `read` WRITES through a ring-3 pointer, so [fileOwnsWrite] requires the page
// to carry the USER bit *and* the WRITABLE bit — refusing a read aimed into the
// program's own R+X segment, which is the check M15 exists to get right.
//
// `fdwrite` READS through a ring-3 pointer, so [fileOwnsRead] requires the USER
// bit and DOES NOT require WRITABLE. That is not a relaxation, it is the
// correct question: a program writing out a string literal is writing out
// `.rodata`, and a validator that demanded WRITABLE would refuse the most
// ordinary call there is. The two validators are the same twelve lines with one
// test different, written out twice rather than sharing a flag argument, for
// [fileOwnsWrite]'s own stated reason.
//
// **The bytes stop being the caller's before any of them reaches the drive.**
// [fileCopyIn] copies the whole request into the kernel's bounce buffer
// immediately after validation, and from there on nothing in the FAT layer, the
// ATA driver or this file ever dereferences an address ring 3 chose. That is
// `open`'s ordering (ADR-0019 §5) applied to a longer path.
// ===========================================================================

/// 1 if `[ptr, ptr+len)` lies wholly inside pages the current program owns
/// **and can read**.
///
/// The read-side twin of [fileOwnsWrite]. Same bound-before-arithmetic ordering
/// — `ptr` is a value ring 3 chose and DCDart's arithmetic traps on overflow
/// with a real `ud2`, so `fdwrite(fd, 0xFFFFFFFFFFFFFFFF, 512)` must be refused
/// by a comparison and never by an addition. Same page-by-page walk, because a
/// range can start on a page ring 3 owns and end on one it does not.
///
/// **Does NOT require the WRITABLE bit**, and the paragraph above says why.
/// `m16-filewrite`'s program writes bytes straight out of its own `.rodata` —
/// a page that is present, user-accessible and read-only — and the harness
/// requires that call to SUCCEED, which is what makes this a different
/// validator rather than a copy of one.
///
/// **Bounded by [fileWriteMax] and not by [userWriteMax].** `elfOwns` exists and
/// would have been the obvious thing to call; it refuses any length above 128,
/// because it was written for the console `write` syscall whose kernel-side
/// limit that is. Reusing it here would have silently capped every file write at
/// 128 bytes.
@bare
u64 fileOwnsRead(u64 ptr, u64 len) {
  if (ptr < u64(vmProgBase)) {
    return u64(0);
  }
  if (ptr >= u64(vmUserEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(fileWriteMax)) {
    return u64(0);
  }
  if ((ptr + len) > u64(vmUserEnd)) {
    return u64(0);
  }
  u64 a = ptr & u64(0xFFFFFFFFFFFFF000);
  final u64 last = (ptr + len - u64(1)) & u64(0xFFFFFFFFFFFFF000);
  while (a <= last) {
    final u64 e = vmEffective(a);
    if ((e & u64(2)) < u64(1)) {
      return u64(0); // not reachable from ring 3 at all
    }
    a = a + u64(vmPageBytes);
  }
  return u64(1);
}

/// Copies [n] bytes from the caller's `[src, src+n)` into the bounce buffer.
///
/// **This is the only load from a caller-supplied address in this file**, and
/// its only caller has already run [fileOwnsRead] over exactly that range.
/// Nothing between the check and the copy can change the tables: the gate is an
/// interrupt gate so interrupts are off, and this kernel is single-CPU and does
/// not preempt inside a syscall — [fileCopyOut]'s argument, in the other
/// direction.
@bare
void fileCopyIn(u64 src, u64 n) {
  final u64 dst = fileBufBase();
  u64 i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Fills the read-modify-write sector with zeroes.
///
/// Called for a sector the file has not occupied before, so that the bytes past
/// the end of what is being written are DEFINED. Nothing reads them — a FAT
/// file is its directory entry's size, and everything after it in the last
/// cluster is slack — but an image whose slack is whatever the drive had there
/// before is an image whose hash is not reproducible, and a harness that
/// compares images byte-for-byte is exactly what M16 is verified with.
@bare
void fileZeroSector() {
  final u64 b = fileSecBase();
  u64 i = u64(0);
  while (i < u64(fileReadMax)) {
    Pointer<u8>.fromAddress(b + i).value = u8(0);
    i = i + u64(1);
  }
}

/// Splices [n] bytes at offset [from] of the bounce buffer into the
/// read-modify-write sector at byte [at].
@bare
void fileSplice(u64 at, u64 from, u64 n) {
  final u64 dst = fileSecBase() + at;
  final u64 src = fileBufBase() + from;
  u64 i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Writes descriptor [fd] of [row]'s size and first cluster into its directory
/// entry. Returns a `fatErr*` code. Does nothing at all for a read descriptor.
///
/// **Rule 3 of the FAT write layer, at the syscall boundary.** Until this runs,
/// the volume's idea of the file is the empty one `open` left behind: the FAT
/// links and the data sectors are already on the drive, and the directory entry
/// is what makes them a file. So `close` is not a courtesy here — a write-mode
/// descriptor that is never closed and never torn down is bytes on a disk that
/// nothing points at.
///
/// Called from [fileSysClose] and from [fileReleaseOwner], which is the fault
/// path as well as the normal one.
@bare
u64 fileFlushFd(u64 row, u64 fd) {
  if (fileFd(row, fd, u64(fileFdState)) != u64(fileFdWrite)) {
    return u64(fatErrOk);
  }
  final u64 m = fatMount();
  if (m > u64(fatErrOk)) {
    fileFatStatus(m);
    return m;
  }
  final u64 w = fatDirWrite(fileFd(row, fd, u64(fileFdEntry)),
      fileFd(row, fd, u64(fileFdFirst)), fileFd(row, fd, u64(fileFdSize)));
  if (w > u64(fatErrOk)) {
    fileFatStatus(w);
    return w;
  }
  fileBump(u64(fileMetaFlushes));
  return u64(fatErrOk);
}

/// Makes the name already in the name buffer exist as an EMPTY file, creating
/// its directory entry or truncating what is there. Leaves the entry index in
/// `fatMetaFileEntry`. Returns 0, or a `fileRet*` refusal.
///
/// **A file being opened for writing is looked up exactly once**, here, and the
/// descriptor keeps the entry index from then on. A later flush does not go
/// looking for the name again, so nothing that happens to the directory in
/// between can make `close` write a different file's entry.
///
/// **A file whose chain is broken is REFUSED, not repaired.** `fatLookup`
/// returning a cycle, a bad cluster or a short chain means the volume disagrees
/// with itself about this file, and truncating it would be this kernel deciding
/// which of the two accounts to believe. It is [fileRetIo] and the FAT-level
/// code is in [fileMetaStatus]. GAP-0127 item 5.
///
/// **A file marked read-only is REFUSED, not emptied.** [fileRetReadOnly], and
/// the volume is untouched. Until GAP-0152 this function looked at
/// [fatAttrDirectory] and at nothing else in the attribute byte, so
/// `open(name, O_WRITE)` on a read-only file destroyed it from ring 3.
@bare
u64 fileMakeEmpty() {
  final u64 fs = fatLookup();
  if (fs == u64(fatErrNotFound)) {
    final u64 cr = fatDirCreate();
    if (cr > u64(fatErrOk)) {
      fileFatStatus(cr);
      if (cr == u64(fatErrNoDirSlot)) {
        return u64(fileRetNoSpace);
      }
      if (cr == u64(fatErrBadName)) {
        // The name PARSED as 8.3 and is still not one a FAT directory may hold
        // — see [fatNameLegal]. Reported as a bad name rather than as an I/O
        // failure, because that is what it is and because the program can fix
        // it by choosing a different one.
        return u64(fileRetBadName);
      }
      return u64(fileRetIo);
    }
    fileBump(u64(fileMetaCreates));
    return u64(0);
  }
  if (fs == u64(fatErrIsDir)) {
    fileFatStatus(fs);
    return u64(fileRetIsDir);
  }
  // [fatErrOk] is a file with a chain and [fatErrEmpty] is an entry without a
  // usable one; both mean THE ENTRY IS THERE, which is all this needs. Every
  // other code means the lookup itself failed and is handed back.
  if (fs > u64(fatErrOk)) {
    if (fs != u64(fatErrEmpty)) {
      fileFatStatus(fs);
      return fileFromFat(fs);
    }
  }
  // A FILE THE VOLUME MARKS READ-ONLY IS NOT EMPTIED. GAP-0152.
  //
  // This is the last question asked before the first destructive act. Every
  // line below it changes the volume: [fatTruncate] returns the chain's
  // clusters to the free pool and [fatDirWrite] zeroes the entry's first
  // cluster and size. So the check is HERE and not in `fileSysOpen`, not in
  // `fileFlushFd`, and not folded in beside the [fatErrIsDir] branch above --
  // it has to sit after the lookup has been established as a HIT (which is
  // what makes [fatMetaFileAttr] meaningful, see [fatWritable]) and before
  // anything has been undone.
  //
  // The attribute belongs to fat.dart, so the question is asked there; this
  // file only translates the answer into the vocabulary ring 3 sees.
  final u64 ro = fatWritable();
  if (ro > u64(fatErrOk)) {
    fileFatStatus(ro);
    return fileFromFat(ro);
  }
  final u64 entry = fatMeta(u64(fatMetaFileEntry));
  final u64 first = fatMeta(u64(fatMetaFileFirst));
  fatClose();
  final u64 tr = fatTruncate(first);
  if (tr > u64(fatErrOk)) {
    fileFatStatus(tr);
    return u64(fileRetIo);
  }
  final u64 dw = fatDirWrite(entry, u64(0), u64(0));
  if (dw > u64(fatErrOk)) {
    fileFatStatus(dw);
    return u64(fileRetIo);
  }
  fatSetMeta(u64(fatMetaFileEntry), entry);
  fileBump(u64(fileMetaTruncs));
  return u64(0);
}

/// Writes as much of the pending request as fits in ONE sector, allocating a
/// cluster first if the offset needs one. Returns the byte count, or 0 with the
/// reason in [fileMetaStatus].
///
/// [from] is the offset into the bounce buffer; [remaining] is how much of the
/// request is left. The descriptor's offset and size are advanced by exactly
/// what reached the drive, so a failure half way through a multi-sector request
/// leaves a descriptor that describes what is actually there — which is the
/// property GAP-0122 item 14 records the READ path as not having.
///
/// **The allocation test is `pos >= allocated`, not `pos % clusterBytes == 0`.**
/// The two agree on every successful call and disagree after a failed one: if
/// the cluster was allocated and the data sector write then failed, `pos` has
/// not moved, and the modular test would allocate a SECOND cluster on the retry
/// and leak the first. A descriptor that records how many bytes of cluster it
/// owns cannot get that wrong.
@bare
u64 fileWriteChunk(u64 row, u64 fd, u64 from, u64 remaining) {
  final u64 cbytes = fatClusterBytes();
  if (cbytes < u64(1)) {
    fileFatStatus(u64(fatErrClusterSize));
    return u64(0);
  }
  final u64 pos = fileFd(row, fd, u64(fileFdPos));
  if (pos >= fileFd(row, fd, u64(fileFdAlloc))) {
    final u64 c = fatAlloc(fileFd(row, fd, u64(fileFdLast)));
    final u64 ae = fatAllocError(c);
    if (ae > u64(fatErrOk)) {
      fileFatStatus(ae);
      return u64(0);
    }
    if (fileFd(row, fd, u64(fileFdLast)) < u64(fatFirstCluster)) {
      fileSetFd(row, fd, u64(fileFdFirst), c);
    }
    fileSetFd(row, fd, u64(fileFdLast), c);
    fileSetFd(row, fd, u64(fileFdAlloc),
        fileFd(row, fd, u64(fileFdAlloc)) + cbytes);
  }
  // The cluster in [fileFdLast] covers `[alloc - cbytes, alloc)` of the file,
  // which contains `pos` because the branch above ran if it did not.
  final u64 base = fileFd(row, fd, u64(fileFdAlloc)) - cbytes;
  final u64 k = (pos - base) >> u64(fatSectorShift);
  final u64 lba = fatClusterSector(fileFd(row, fd, u64(fileFdLast)), k);
  if (lba < u64(1)) {
    fileFatStatus(u64(fatErrChainRange));
    return u64(0);
  }
  final u64 inSec = pos & u64(511);
  u64 n = u64(fatSectorBytes) - inSec;
  if (n > remaining) {
    n = remaining;
  }
  if (inSec > u64(0)) {
    // This sector already holds bytes of this file, so it is read back and
    // spliced rather than overwritten. A `fdwrite` whose length is not a
    // multiple of 512 — which is most of them — leaves the offset mid-sector,
    // and a driver that skipped this would zero everything the previous call
    // had put in the same sector.
    if (fatReadSector(lba, fileSecBase()) > u64(0)) {
      fileFatStatus(u64(fatErrDiskData));
      return u64(0);
    }
  } else {
    fileZeroSector();
  }
  fileSplice(inSec, from, n);
  if (fatWriteSector(lba, fileSecBase()) > u64(fatErrOk)) {
    fileFatStatus(u64(fatErrDiskWrite));
    return u64(0);
  }
  fileBump(u64(fileMetaWSectors));
  fileSetFd(row, fd, u64(fileFdPos), pos + n);
  fileSetFd(row, fd, u64(fileFdSize), pos + n);
  return n;
}

/// Syscall 9 — `fdwrite(fd, buf, len)`. Returns how many bytes reached the
/// drive — which may be fewer than [len] — or a refusal.
///
/// **A SHORT WRITE IS NOT AN ERROR AND THE PROGRAM IS REQUIRED TO NOTICE.** If
/// the volume fills up half way through a request, the bytes that got there are
/// on the drive, the descriptor's size counts them, and the return value is
/// that count. Calling again returns [fileRetNoSpace] with nothing written.
/// That is POSIX's shape and it is deliberately BETTER than what `read` does
/// (GAP-0122 item 14, where a failure part way through leaves bytes in the
/// caller's buffer with no count to say so) — the write path was written after
/// that entry and did not have to repeat it.
///
/// **Nothing here can produce a partly-written SECTOR.** The unit of failure is
/// a sector: [fileWriteChunk] either got 512 bytes onto the drive and flushed
/// them, or reports zero and has changed nothing about the descriptor.
@bare
void fileSysWrite(u64 frame) {
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    fileRefuse(frame, u64(fileRetNoOwner));
    return;
  }
  final u64 fd = userFrame(frame, u64(userFrameRdi));
  final u64 src = userFrame(frame, u64(userFrameRsi));
  final u64 len = userFrame(frame, u64(userFrameRdx));
  if (fd >= u64(fileMaxFds)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  final u64 state = fileFd(row, fd, u64(fileFdState));
  if (state < u64(fileFdOpen)) {
    fileRefuse(frame, u64(fileRetBadFd));
    return;
  }
  if (state != u64(fileFdWrite)) {
    fileRefuse(frame, u64(fileRetBadMode));
    return;
  }
  if (len < u64(1)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  if (len > u64(fileWriteMax)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  if (fileOwnsRead(src, len) < u64(1)) {
    fileRefuse(frame, u64(fileRetBadPtr));
    return;
  }
  fileCopyIn(src, len);
  final u64 m = fatMount();
  if (m > u64(fatErrOk)) {
    fileFatStatus(m);
    fileRefuse(frame, u64(fileRetIo));
    return;
  }
  u64 done = u64(0);
  u64 stop = u64(0);
  // `stop` is 0 while there is work, 1 when a chunk refused, 2 when the whole
  // request is on the drive. A flag rather than a `break`, because `@bare`
  // DCDart has no `break` and the loop's exit condition is not a comparison on
  // `done` alone.
  while (stop < u64(1)) {
    if (done >= len) {
      stop = u64(2);
    } else {
      final u64 n = fileWriteChunk(row, fd, done, len - done);
      if (n < u64(1)) {
        stop = u64(1);
      } else {
        done = done + n;
      }
    }
  }
  if (stop == u64(1)) {
    if (done < u64(1)) {
      if (fileMeta(u64(fileMetaStatus)) == u64(fatErrFull)) {
        fileRefuse(frame, u64(fileRetNoSpace));
        return;
      }
      fileRefuse(frame, u64(fileRetIo));
      return;
    }
  }
  fileBump(u64(fileMetaWrites));
  fileSetMeta(u64(fileMetaWBytes), fileMeta(u64(fileMetaWBytes)) + done);
  userSetFrame(frame, u64(userFrameRax), done);
}

/// `FILEW WRITES <n> BYTES <n> SECTORS <n> CREATED <n> TRUNC <n> FLUSH <n>
/// DISKW <n> ALLOC <n> FREED <n>`
///
/// **A SECOND LINE, PRINTED ONLY IF SOMETHING EVER WROTE**, rather than nine
/// more fields on `FILE OPENS ...`. Seventeen harnesses assert byte-exact
/// serial captures and `m15-fileio`'s contains that line in full; widening it
/// would have moved a golden in a milestone whose entire claim is about not
/// silently changing what is already on a disk. The guard is the same one
/// [fileExitReport] uses and it is checked the same way.
///
/// The last three numbers come from `fat.dart` rather than from this file, and
/// that is the check they are here for: [fileMetaWSectors] counts the data
/// sectors THIS file wrote, `fatWrites()` counts every sector the whole kernel
/// wrote — data, FAT copies and directory — so the difference is the metadata
/// cost of the write, and the harness derives both.
@bare
void fileWriteReport() {
  if (fileMeta(u64(fileMetaWrites)) < u64(1)) {
    if (fileMeta(u64(fileMetaCreates)) < u64(1)) {
      if (fileMeta(u64(fileMetaTruncs)) < u64(1)) {
        return;
      }
    }
  }
  uartWrite(Rodata.addressOf(fileStrWrites), u64(13));
  uartPutHex(fileMeta(u64(fileMetaWrites)), u64(8));
  uartWrite(Rodata.addressOf(fileStrBytes), u64(7));
  uartPutHex(fileMeta(u64(fileMetaWBytes)), u64(8));
  uartWrite(Rodata.addressOf(fileStrSectors), u64(9));
  uartPutHex(fileMeta(u64(fileMetaWSectors)), u64(8));
  uartWrite(Rodata.addressOf(fileStrCreated), u64(9));
  uartPutHex(fileMeta(u64(fileMetaCreates)), u64(8));
  uartWrite(Rodata.addressOf(fileStrTrunc), u64(7));
  uartPutHex(fileMeta(u64(fileMetaTruncs)), u64(8));
  uartWrite(Rodata.addressOf(fileStrFlush), u64(7));
  uartPutHex(fileMeta(u64(fileMetaFlushes)), u64(8));
  uartWrite(Rodata.addressOf(fileStrDiskW), u64(7));
  uartPutHex(fatWrites(), u64(8));
  uartWrite(Rodata.addressOf(fileStrAlloc), u64(7));
  uartPutHex(fatAllocs(), u64(8));
  uartWrite(Rodata.addressOf(fileStrFreed), u64(7));
  uartPutHex(fatFrees(), u64(8));
  uartNewline();
}

/// Syscall 5 — `open(namePtr, nameLen, mode)`. Returns a descriptor number,
/// 0..3, or a refusal.
///
/// **M16 added the third argument and it is backwards-compatible by
/// construction.** `mode` arrives in RDX, and the C library's two-argument
/// `sys_call` has passed a zero RDX since M15 (ADR-0019 §3) — so a program
/// built before this syscall grew a mode asks for [fileOpenRead], which is
/// exactly what it used to get. Anything other than [fileOpenRead] or
/// [fileOpenWrite] is [fileRetBadMode], refused before the name is parsed:
/// there is no "unknown modes are read" fallback, because a program asking for
/// a mode this kernel does not have and silently getting a read-only descriptor
/// would discover it on the first write.
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
  final u64 mode = userFrame(frame, u64(userFrameRdx));
  if (mode > u64(fileOpenWrite)) {
    fileRefuse(frame, u64(fileRetBadMode));
    return;
  }
  if (len < u64(1)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  // S0 (ADR-0033): the OUTER bound is now the DEVICE name length, not
  // [fileNameMax]. `/dev/dri/card0` is fourteen characters and
  // `/dev/dri/renderD128` is nineteen, so bounding by [fileNameMax] here —
  // which is what this line did until S0 — refused every device name before
  // its bytes were ever copied. The FAT bound has not been relaxed: it moved
  // down into the non-device arm below, and `fatParseAt` is reached only
  // through that arm.
  if (len > u64(ioctlDevNameMax)) {
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
  // ---------------------------------------------------------------------
  // S0 — THE DEVICE NAMESPACE. ADR-0031 §6, GAP-0174.
  //
  // **HERE, AND NOT IN `fatLookup`.** That placement is the whole of the
  // safety argument and design/display-protocol.md §2.1 recorded why: this
  // point is AFTER the pointer-validated bounce-buffer copy — so the bytes
  // being examined are the kernel's own — and BEFORE `fatParseAt`, so a
  // device name never becomes a FAT name. A device branch inside `fatLookup`
  // would also be reached by `fileMakeEmpty`, which would treat the device
  // name as a real directory entry and truncate and rewrite it. **That is a
  // ring-3-reachable volume corruption**, and it is avoided by where this
  // block sits rather than by anything inside it.
  //
  // The two namespaces are disjoint BY CONSTRUCTION: `fatNameByteBad`
  // forbids `/` in an 8.3 name, so nothing that reaches this branch could
  // ever have named a file, and nothing on the volume can ever reach
  // [ioctlDevLookup]. A `/`-name that is not a device this kernel serves is
  // [fileRetNotFound] and is NEVER retried as a FAT name — falling through
  // would turn a missing device into a plausible 8.3 parse failure.
  if (ioctlIsDevName(buf, len) > u64(0)) {
    // A device is opened for READING. [fileOpenWrite] means create + truncate
    // + append-only on this OS (ADR-0020 §0), and none of those three verbs
    // means anything to a device node; `ioctl` is how a device is written to.
    // Refused rather than silently accepted, so a program asking for
    // something this kernel does not have finds out at `open`.
    if (mode != u64(fileOpenRead)) {
      fileRefuse(frame, u64(fileRetBadMode));
      return;
    }
    final u64 dev = ioctlDevLookup(buf, len);
    if (dev >= u64(ioctlDevCount)) {
      fileRefuse(frame, u64(fileRetNotFound));
      return;
    }
    final u64 dfd = fileFreeFd(row);
    if (dfd >= u64(fileMaxFds)) {
      fileRefuse(frame, u64(fileRetNoSlot));
      return;
    }
    fileClearFd(row, dfd);
    fileSetFd(row, dfd, u64(fileFdDevIndex), dev);
    fileSetFd(row, dfd, u64(fileFdState), u64(fileFdDevice));
    fileBump(u64(fileMetaOpens));
    ioctlNoteOpen();
    fileSetMeta(u64(fileMetaLive), fileMeta(u64(fileMetaLive)) + u64(1));
    if (fileMeta(u64(fileMetaPeak)) < fileMeta(u64(fileMetaLive))) {
      fileSetMeta(u64(fileMetaPeak), fileMeta(u64(fileMetaLive)));
    }
    userSetFrame(frame, u64(userFrameRax), dfd);
    return;
  }
  // Not a device name, so it must be an 8.3 name — and [fileNameMax] is
  // enforced HERE, on the arm that reaches `fatParseAt`, exactly as it was
  // enforced above before S0 widened the outer bound.
  if (len > u64(fileNameMax)) {
    fileRefuse(frame, u64(fileRetBadLen));
    return;
  }
  final u64 pn = fatParseAt(buf, len);
  if (pn > u64(fatErrOk)) {
    fileFatStatus(pn);
    fileRefuse(frame, u64(fileRetBadName));
    return;
  }
  final u64 fd = fileFreeFd(row);
  if (fd >= u64(fileMaxFds)) {
    fileRefuse(frame, u64(fileRetNoSlot));
    return;
  }
  if (mode == u64(fileOpenWrite)) {
    // M16. The volume is changed HERE, at `open`, and not lazily at the first
    // write: an `open` for writing that succeeds has already created or emptied
    // the file, so a program that opens and then writes nothing leaves a
    // zero-length file behind — which is what `open(..., O_WRONLY|O_TRUNC)`
    // means everywhere else and is a real, legal FAT file.
    final u64 mk = fileMakeEmpty();
    if (mk > u64(0)) {
      fileRefuse(frame, mk);
      return;
    }
    fileClearFd(row, fd);
    fileSetFd(row, fd, u64(fileFdEntry), fatMeta(u64(fatMetaFileEntry)));
    fileSetFd(row, fd, u64(fileFdState), u64(fileFdWrite));
    fileBump(u64(fileMetaOpens));
    fileSetMeta(u64(fileMetaLive), fileMeta(u64(fileMetaLive)) + u64(1));
    if (fileMeta(u64(fileMetaPeak)) < fileMeta(u64(fileMetaLive))) {
      fileSetMeta(u64(fileMetaPeak), fileMeta(u64(fileMetaLive)));
    }
    userSetFrame(frame, u64(userFrameRax), fd);
    return;
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    fileFatStatus(fs);
    fileRefuse(frame, fileFromFat(fs));
    return;
  }
  fileClearFd(row, fd);
  fileSetFd(row, fd, u64(fileFdFirst), fatFileFirst());
  fileSetFd(row, fd, u64(fileFdSize), fatFileBytes());
  fileSetFd(row, fd, u64(fileFdEntry), fatMeta(u64(fatMetaFileEntry)));
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
  // M16: a write descriptor is not a read descriptor. There is no read-write
  // mode on this OS (GAP-0127 item 2), so this is a refusal and not a seek to
  // the start followed by a read.
  if (fileFd(row, fd, u64(fileFdState)) != u64(fileFdOpen)) {
    fileRefuse(frame, u64(fileRetBadMode));
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
    fileFatStatus(cs);
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
      fileFatStatus(u64(fatErrChainRange));
      fileRefuse(frame, u64(fileRetIo));
      return;
    }
    if (fatReadSector(lba, fileBufBase()) > u64(0)) {
      fileFatStatus(u64(fatErrDiskData));
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
  // M16: CLOSING A WRITE DESCRIPTOR IS WHAT PUTS THE FILE IN THE DIRECTORY.
  // Every data sector and every FAT link is already on the drive by now — the
  // size and the first cluster are not, and a `close` that failed to write them
  // has to say so rather than report success and leave a chain nothing points
  // at. The descriptor is released either way: there is no second `close` that
  // could retry, and a descriptor left open would be leaked instead.
  final u64 fl = fileFlushFd(row, fd);
  fileClearFd(row, fd);
  fileBump(u64(fileMetaCloses));
  if (fl > u64(fatErrOk)) {
    fileSetMeta(u64(fileMetaLive), fileMeta(u64(fileMetaLive)) - u64(1));
    fileRefuse(frame, u64(fileRetIo));
    return;
  }
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
  // M16: a write descriptor is append-only and cannot be seeked. Moving the
  // offset of one would mean a write at an arbitrary place in a chain, which is
  // the thing this milestone deliberately did not build (GAP-0127 item 1).
  if (fileFd(row, fd, u64(fileFdState)) != u64(fileFdOpen)) {
    fileRefuse(frame, u64(fileRetBadMode));
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
