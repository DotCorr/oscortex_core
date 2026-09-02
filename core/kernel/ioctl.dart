// core/kernel/ioctl.dart
//
// oscortex_core S0: `ioctl` -- SYSCALL 12, AND THE DEVICE NAMESPACE IT IS
// ISSUED AGAINST.
//
// The architecture is docs/decisions/0031-libdrm-is-the-first-c-library-...md
// SECTION 4, which is a SPECIFICATION and not a description: it was written by
// the unit that compiled libdrm 2.4.134 from unmodified source, measured what
// the DRM ABI actually asks a kernel for, and then deliberately implemented
// none of it. This file is that specification carried out. Where this file
// departs from §4 it says so at the point of departure and
// docs/decisions/0033-ioctl-is-syscall-12-...md §4 argues it. There is exactly
// ONE such place and it is [ioctlOwnsRead]/[ioctlOwnsWrite] -- the two
// validators' LENGTH CAPS, which belong to their original callers and not to
// the page walk `ioctl` needs.
//
// **THE WHOLE POINT OF THIS FILE IS THAT IT IS A HOLE IN THE KERNEL.**
// `ioctl` is the first syscall on this machine that takes a length AND a
// direction AND a pointer, all three chosen by ring 3, and then copies with
// kernel privilege in whichever direction ring 3 asked for. Every other
// syscall here copies one way and the kernel picks which. The kernel enforces
// W^X, NX, a ring-3 boundary and (since e1381f8) sets SMEP's bit -- and
// GAP-0153 records that NOTHING PROVES SMEP BLOCKS A FETCH on this machine, so
// there is no hardware backstop to fall back on. Every check in this file is a
// SOFTWARE check and is the only thing standing there.
//
// The seven rules of §4.3, in the order this file applies them:
//
//   1. `_IOC_TYPE` first, before any arithmetic on any other field.
//   2. `_IOC_SIZE` non-zero for a direction that carries a payload, and at
//      most [ioctlMaxPayload]. REFUSED, never truncated.
//   3. `_IOC_SIZE` must be in the descriptor's SET of legal sizes for that
//      `(type, nr)`. REFUSED, never zero-extended.
//   4. `argp` through M16's two mutation-tested validators -- read-side for
//      `_IOC_WRITE`, WRITE-side for `_IOC_READ`, BOTH for `_IOWR`, and both
//      BEFORE EITHER COPY.
//   5. The copy goes through [ioctlBufBase], a bounce buffer in this kernel's
//      own `.bss`. A driver never holds a ring-3 pointer.
//   6. The out-copy happens ONLY on success.
//   7. `ioctl` on a FAT16 file is [ioctlRetNotDev] -- a refusal from this
//      file's vocabulary, distinct from every one of file.dart's fourteen.
//
// **AND THE DISPATCH IS ON `_IOC_NR`, NEVER ON THE WHOLE REQUEST WORD.** That
// is not a style preference and ADR-0031 §3.2 is the evidence: `struct
// drm_syncobj_handle` grew a `__u64 point` after Linux 6.12, 16 bytes became
// 24, `_IOC_SIZE` carries the size, and so `DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD` is
// `0xc01864c1` in libdrm 2.4.134 and `0xc01064c1` in Linux 6.12. A kernel
// written as `switch (request)` over today's constants stops recognising that
// request the day somebody upgrades libdrm, WITH NO COMPILE ERROR ANYWHERE.
// [ioctlDescFind] takes `(type, nr)` and nothing else, and the size is checked
// against a SET afterwards -- which is how both of those numbers are served by
// one row (see [ioctlDescAltSize]).

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The syscall number.
// ---------------------------------------------------------------------------

/// Syscall 12 — `ioctl(fd, request, argp)`.
///
/// **Allocated by `docs/syscall-registry.md`, which exists because this call
/// was at least the third thing to reach for "the next number".** `fdwait`
/// keeps 11: it was named first and in three separate design documents
/// (`blocking-and-threads.md` §3, `display-protocol.md` §2.4,
/// `time-and-power.md` §5), and moving it would break three documents to save
/// one number. ADR-0031 §5.
const int ioctlSysNo = 12;

// ---------------------------------------------------------------------------
// The `_IOC` encoding. LINUX's, served from our own <sys/ioccom.h>.
//
//    bit  31 30 | 29 ............ 16 | 15 ...... 8 | 7 ...... 0
//         dir   |       size         |    type     |     nr
//         (2)   |       (14)         |     (8)     |     (8)
//
// ADR-0031 §3 is why this is Linux's and not BSD's, and it is worth restating
// here because this file is the other half of that decision: `drm.h` line 38
// is `#if defined(__linux__)`, which is FALSE on x86_64-unknown-none-elf, so
// the header takes its BSD branch and reaches for <sys/ioccom.h> -- ours to
// write. Writing BSD's real encoding there compiles, produces byte-identical
// structs, and changes 29 of the 121 DRM request numbers, including
// GEM_CLOSE, SET_CLIENT_CAP, SET_MASTER and DROP_MASTER. It leaves all 92
// `_IOWR` ones alone, so a ladder would have climbed four rungs before finding
// out. The harness keeps that mistake as a negative control.
// ---------------------------------------------------------------------------

const int ioctlNrShift = 0;
const int ioctlTypeShift = 8;
const int ioctlSizeShift = 16;
const int ioctlDirShift = 30;

const int ioctlNrMask = 0xFF;
const int ioctlTypeMask = 0xFF;
const int ioctlSizeMask = 0x3FFF;
const int ioctlDirMask = 0x3;

/// **The direction is from USERSPACE's point of view, and getting it backwards
/// is the classic bug.**
///
/// `_IOC_WRITE` means *userspace writes the payload and the kernel reads it*.
/// `_IOC_READ` means *the kernel writes and userspace reads*. It is invisible
/// on an `_IOWR`, which is 92 of the 121 DRM requests -- so a kernel that had
/// them backwards would pass almost every test anybody thought to write. The
/// harness's `_IOC_READ` negative control targets exactly this: it aims an
/// `_IOC_READ` at a page ring 3 may read and may NOT write, and requires a
/// refusal. A kernel with the directions swapped would run the read-side
/// validator there, pass, and then write to it.
const int ioctlDirNone = 0;
const int ioctlDirWrite = 1;
const int ioctlDirRead = 2;
const int ioctlDirBoth = 3;

/// `'d'`. Every one of the 121 `DRM_IOCTL_*` requests carries it, and a
/// request of another type is not ours.
const int ioctlTypeDrm = 0x64;

/// The encoding's own ceiling: `_IOC_SIZE` is 14 bits.
///
/// **This kernel does not RELY on it and that is the point.** A 14-bit field
/// cannot carry a length that wraps [ioctlMaxPayload]'s arithmetic, which is a
/// genuinely useful property -- and a kernel whose only length bound was "the
/// field is 14 bits wide" would happily bounce 16383 bytes through a 256-byte
/// buffer. The ceiling is recorded, reported, and checked against
/// [ioctlMaxPayload] by the harness, which reads both constants out of this
/// file and requires the first to be strictly below the second. The bound that
/// DOES the work is [ioctlMaxPayload].
const int ioctlEncMaxSize = 16383;

/// The largest payload this kernel will bounce, in bytes. **A request above it
/// is REFUSED, NEVER TRUNCATED.**
///
/// ADR-0031 §9 explicitly left this value undecided -- *"§4.3 says 'one page
/// is the natural first value' and does not fix it"*. **256, and here is the
/// argument.** The measured largest DRM payload across all 121 requests is
/// **248 bytes** (`DRM_IOCTL_GET_STATS`), so 256 is the smallest power of two
/// that serves the whole measured ABI with nothing to spare and nothing
/// wasted. A page would be 4096 bytes of `.bss` that no measured request can
/// fill, and — because [ioctlOwnsRead] validates in windows of
/// [userWriteMax] — it would also be 32 validator calls where 2 suffice.
///
/// **Truncating instead of refusing is the failure this constant exists to
/// prevent**, and it is worth naming: a truncating kernel turns a too-large
/// request into a SUCCESSFUL one that read the wrong number of bytes, and the
/// caller has no way to notice. The refusal is [ioctlRetBadSize] and the
/// harness's oversize negative control requires exactly it.
const int ioctlMaxPayload = 256;

// ---------------------------------------------------------------------------
// The return convention: file.dart's, not POSIX's.
// ---------------------------------------------------------------------------

/// One comparison separates a result from a refusal, exactly as
/// [fileRetFloor] and `SBRK_ERR_FLOOR` do.
///
/// **ADR-0031 §4.1 forbids the alternative by name.** A libc `ioctl()` that
/// presents libdrm's expected `-1`-and-`errno` face is a LIBC problem
/// (GAP-0170), and it must not be solved by making the kernel return `-1`:
/// this kernel's whole refusal discipline is that a refusal is a distinct
/// value carrying a reason. ADR-0033 §2 decides where that face is built
/// instead -- `core/user/libc/posix.c`, and nowhere in `core/kernel/`.
const int ioctlRetFloor = 0xFFFFFFFFFFFFFF00;

// The refusals occupy 0xE0..0xEF, a band of their own BELOW file.dart's
// 0xF1..0xFE. That is §4.3 rule 7 made mechanical rather than promised: an
// `ioctl` refusal and a `file.dart` refusal can never be the same number, so
// `m15-fileio` and `m16-filewrite` keep meaning exactly what they meant and a
// program cannot mistake [ioctlRetBadFd] for [fileRetBadFd].

/// No such open descriptor.
const int ioctlRetBadFd = 0xFFFFFFFFFFFFFFEF;

/// **`ENOTTY`'s equivalent: the descriptor is a FAT16 file, not a device.**
/// §4.3 rule 7. A program that calls `ioctl` on a file it opened by name gets
/// this and not one of file.dart's fourteen.
const int ioctlRetNotDev = 0xFFFFFFFFFFFFFFEE;

/// `_IOC_TYPE` is not a type this kernel serves. **Checked first, before any
/// other field is looked at** (§4.3 rule 1).
const int ioctlRetBadType = 0xFFFFFFFFFFFFFFED;

/// `_IOC_SIZE` is zero on a request that carries a payload, or is above
/// [ioctlMaxPayload]. **Refused, not truncated.**
const int ioctlRetBadSize = 0xFFFFFFFFFFFFFFEC;

/// `_IOC_DIR` disagrees with the descriptor's.
const int ioctlRetBadDir = 0xFFFFFFFFFFFFFFEB;

/// `argp` failed the read-side validator, the write-side one, or both.
const int ioctlRetBadPtr = 0xFFFFFFFFFFFFFFEA;

/// No descriptor for this `(type, nr)`. The kernel does not serve the request.
const int ioctlRetBadNr = 0xFFFFFFFFFFFFFFE9;

/// **The `(type, nr)` is served and the SIZE is not one this kernel accepts
/// for it.** Distinct from [ioctlRetBadSize] on purpose: that one means "no
/// request could be this big", this one means "both sides disagree about the
/// struct". ADR-0031 §3.2's finding is exactly this refusal, and it is
/// REFUSED rather than accepted-and-zero-extended -- see [ioctlDescAltSize].
const int ioctlRetSizeSkew = 0xFFFFFFFFFFFFFFE8;

/// Nothing that owns descriptors is running. file.dart's [fileOwnerRow] said
/// so; this is that answer in this file's vocabulary.
const int ioctlRetNoOwner = 0xFFFFFFFFFFFFFFE7;

/// The device index in the descriptor names no device this kernel has. Not
/// reachable today; it exists so that [ioctlDevServe] has a total answer.
const int ioctlRetNoDev = 0xFFFFFFFFFFFFFFE6;

// ---------------------------------------------------------------------------
// The device namespace. ADR-0031 §6, correcting design/drm-abi.md S1.
// ---------------------------------------------------------------------------

/// The longest device path this kernel recognises. `/dev/dri/renderD128` is
/// nineteen characters and there is no twentieth.
///
/// **This is bigger than [fileNameMax] and that is the whole reason it is a
/// separate constant.** `fileSysOpen` bounded its name length by
/// [fileNameMax] (12) before this existed, and a fourteen-character
/// `/dev/dri/card0` would have been [fileRetBadLen] before the bytes were ever
/// copied. So the bound moved out one level: `fileSysOpen` now bounds by
/// [ioctlDevNameMax], copies, and THEN decides which namespace the name is in
/// -- and a FAT name still cannot be longer than [fileNameMax], because
/// `fatParseAt` is reached only through the non-device arm.
const int ioctlDevNameMax = 24;

/// `/dev/dri/card0` — the primary node. Fourteen bytes.
const int ioctlDevCard0 = 0;

/// `/dev/dri/renderD128` — the render node. Nineteen bytes.
const int ioctlDevRender = 1;

/// How many device names this kernel serves.
const int ioctlDevCount = 2;

// ---------------------------------------------------------------------------
// Storage. ONE `@bss` block, and it goes LAST.
//
// ADR-0031 §4.3 rule 5 requires the bounce buffer to be the last thing in
// `.bss` so that every existing harness's "bytes from my block to the end"
// arithmetic is unchanged -- ADR-0021's rule. `part 'ioctl.dart'` is therefore
// the last part in kmain.dart, and `tests/conformance/drm-abi/run.sh` reads
// `core/build/kernel.map` and requires this block to start at a higher address
// than every other kernel `@bss` block rather than believing the ordering.
//
// The buffer is at the END of the block, after the metadata words, so that the
// LAST BYTE OF `.bss` is the last byte of the bounce buffer. That is the
// strongest form of the rule and it costs nothing.
// ---------------------------------------------------------------------------

const int ioctlStoreBytes = 512;
const int ioctlMetaOffset = 0;
const int ioctlBufOffset = 256;

const int ioctlMetaWords = 32;

const int ioctlMetaCalls = 0;
const int ioctlMetaServed = 1;
const int ioctlMetaRefusals = 2;
const int ioctlMetaInBytes = 3;
const int ioctlMetaOutBytes = 4;
const int ioctlMetaLastReq = 5;
const int ioctlMetaLastCode = 6;
const int ioctlMetaOpens = 7;

/// The 512 bytes this subsystem owns, as a DCDart mutable static.
///
/// **No user pointer ever names any address inside this block**, which is the
/// property the whole of §4.3 rule 5 rests on.
@bss
final Bss ioctlStore = const Bss(bytes: ioctlStoreBytes);

/// The 32 metadata words.
@bare
u64 ioctlMetaBase() {
  return Bss.addressOf(ioctlStore);
}

/// **The bounce buffer, and the reason a driver on this OS structurally cannot
/// hold a ring-3 pointer.**
///
/// §4.3 rule 5 gives two reasons and says the second is the load-bearing one:
///
///   * the validated range must not be re-read after validation from a page
///     another CPU or another process could have changed -- this kernel is
///     uniprocessor today and will not always be;
///   * **a driver that dereferences `argp` directly is one page-table switch
///     away from reading somebody else's memory, and the compiler will not
///     stop it.** The bounce buffer makes that impossible rather than merely
///     discouraged: [ioctlDevServe] is handed an OFFSET INTO THIS BLOCK and a
///     length, and is never told `argp` at all. There is no ring-3 address in
///     scope anywhere below [ioctlSysIoctl].
@bare
u64 ioctlBufBase() {
  return Bss.addressOf(ioctlStore) + u64(ioctlBufOffset);
}

/// Reads metadata word [i].
@bare
u64 ioctlMeta(u64 i) {
  return Pointer<u64>.fromAddress(ioctlMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void ioctlSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(ioctlMetaBase() + (i << u64(3))).value = v;
}

/// Adds one to metadata word [i].
@bare
void ioctlBump(u64 i) {
  ioctlSetMeta(i, ioctlMeta(i) + u64(1));
}

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// A `@rodata` table carries no length (GAP-0060), so every byte count below is
// repeated at its call site by hand, and `tests/conformance/drm-abi/run.sh`
// reads every symbol's real size out of `kmain.o` and compares it against what
// the call site passes -- the same check m15-fileio makes for file.dart's.
// ---------------------------------------------------------------------------

/// `IOCTL REQ `
@rodata
final List<u8> ioctlStrReq = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x52), u8(0x45), u8(0x51), u8(0x20),
];

/// ` DIR `
@rodata
final List<u8> ioctlStrDir = const [
  u8(0x20), u8(0x44), u8(0x49), u8(0x52), u8(0x20),
];

/// ` SIZE `
@rodata
final List<u8> ioctlStrSize = const [
  u8(0x20), u8(0x53), u8(0x49), u8(0x5A), u8(0x45), u8(0x20),
];

/// ` TYPE `
@rodata
final List<u8> ioctlStrType = const [
  u8(0x20), u8(0x54), u8(0x59), u8(0x50), u8(0x45), u8(0x20),
];

/// ` NR `
@rodata
final List<u8> ioctlStrNr = const [
  u8(0x20), u8(0x4E), u8(0x52), u8(0x20),
];

/// `IOCTL REFUSED `
@rodata
final List<u8> ioctlStrRefused = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x52), u8(0x45), u8(0x46),
  u8(0x55), u8(0x53), u8(0x45), u8(0x44), u8(0x20),
];

/// `IOCTL OK IN `
@rodata
final List<u8> ioctlStrOkIn = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x4F), u8(0x4B), u8(0x20),
  u8(0x49), u8(0x4E), u8(0x20),
];

/// ` OUT `
@rodata
final List<u8> ioctlStrOut = const [
  u8(0x20), u8(0x4F), u8(0x55), u8(0x54), u8(0x20),
];

/// `IOCTL CALLS `
@rodata
final List<u8> ioctlStrCalls = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x43), u8(0x41), u8(0x4C),
  u8(0x4C), u8(0x53), u8(0x20),
];

/// ` SERVED `
@rodata
final List<u8> ioctlStrServed = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x52), u8(0x56), u8(0x45), u8(0x44), u8(0x20),
];

/// ` REFUSALS `
@rodata
final List<u8> ioctlStrRefusals = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x41), u8(0x4C), u8(0x53), u8(0x20),
];

/// `IOCTL BYTES IN `
@rodata
final List<u8> ioctlStrBytesIn = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x42), u8(0x59), u8(0x54),
  u8(0x45), u8(0x53), u8(0x20), u8(0x49), u8(0x4E), u8(0x20),
];

/// `IOCTL DEV OPENS `
@rodata
final List<u8> ioctlStrDevOpens = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x44), u8(0x45), u8(0x56),
  u8(0x20), u8(0x4F), u8(0x50), u8(0x45), u8(0x4E), u8(0x53), u8(0x20),
];

/// `IOCTL MAXPAYLOAD `
@rodata
final List<u8> ioctlStrMaxPayload = const [
  u8(0x49), u8(0x4F), u8(0x43), u8(0x54), u8(0x4C), u8(0x20), u8(0x4D), u8(0x41), u8(0x58),
  u8(0x50), u8(0x41), u8(0x59), u8(0x4C), u8(0x4F), u8(0x41), u8(0x44), u8(0x20),
];

/// ` CEIL `
@rodata
final List<u8> ioctlStrCeil = const [
  u8(0x20), u8(0x43), u8(0x45), u8(0x49), u8(0x4C), u8(0x20),
];

/// ` DESCS `
@rodata
final List<u8> ioctlStrDescs = const [
  u8(0x20), u8(0x44), u8(0x45), u8(0x53), u8(0x43), u8(0x53), u8(0x20),
];

// `/dev/dri/card0` -- fourteen bytes, LITERALLY, and not design/drm-abi.md
// S1's `:DRI0`. ADR-0031 §6 checked whether libdrm can be told a name of our
// own and the answer is no: `xf86drm.h` hardcodes DRM_DIR_NAME "/dev/dri" and
// builds "%s/card%d" with sprintf, and `drmOpenByName` additionally stats the
// result and compares major()/minor() against DRM_MAJOR 226. Telling libdrm a
// different name means EDITING libdrm, which is the one thing the port exists
// not to do. The disjointness argument S1 made survives intact: `fatNameByteBad`
// forbids `/` in an 8.3 name exactly as it forbids `:`, so `/` is as good a
// sigil and it is the one libdrm already emits.
@rodata
final List<u8> ioctlStrCard0 = const [
  u8(0x2F), u8(0x64), u8(0x65), u8(0x76), u8(0x2F), u8(0x64), u8(0x72), //  /dev/dr
  u8(0x69), u8(0x2F), u8(0x63), u8(0x61), u8(0x72), u8(0x64), u8(0x30), //  i/card0
];

/// `/dev/dri/renderD128` — nineteen bytes.
@rodata
final List<u8> ioctlStrRender = const [
  u8(0x2F), u8(0x64), u8(0x65), u8(0x76), u8(0x2F), u8(0x64), u8(0x72), //  /dev/dr
  u8(0x69), u8(0x2F), u8(0x72), u8(0x65), u8(0x6E), u8(0x64), u8(0x65), //  i/rende
  u8(0x72), u8(0x44), u8(0x31), u8(0x32), u8(0x38), //                      rD128
];

// ---------------------------------------------------------------------------
// The decode. Four fields, and nothing here dereferences anything.
// ---------------------------------------------------------------------------

/// `_IOC_DIR(request)` — 0 none, 1 write, 2 read, 3 both.
@bare
u64 ioctlDir(u64 req) {
  return (req >> u64(ioctlDirShift)) & u64(ioctlDirMask);
}

/// `_IOC_SIZE(request)` — 14 bits, so this cannot exceed [ioctlEncMaxSize].
@bare
u64 ioctlSize(u64 req) {
  return (req >> u64(ioctlSizeShift)) & u64(ioctlSizeMask);
}

/// `_IOC_TYPE(request)`.
@bare
u64 ioctlType(u64 req) {
  return (req >> u64(ioctlTypeShift)) & u64(ioctlTypeMask);
}

/// `_IOC_NR(request)`.
@bare
u64 ioctlNr(u64 req) {
  return (req >> u64(ioctlNrShift)) & u64(ioctlNrMask);
}

// ---------------------------------------------------------------------------
// THE DESCRIPTOR TABLE. `(type, nr)` in, shape out. NEVER the request word.
//
// design/drm-abi.md §4.2 wants a build-time generator that reads the uAPI
// headers and emits one of these per request; ADR-0031 §7 built the name-table
// half of it and GAP-0175 records that the descriptor half is not built,
// because nothing consumed a descriptor until this file existed. **This table
// is hand-written, it is SIX rows, and that is a deliberate scope statement
// rather than an oversight** -- see ADR-0033 §5 and GAP-0177. Six rows is
// enough to exercise every direction, both the single-size and the
// multiple-size cases, and the version-skew case that motivated the whole
// dispatch rule; 121 rows written by hand would be 121 chances to transcribe a
// number wrongly, which is the exact failure design/drm-abi.md §4.2 wants a
// generator for.
//
// Written as a chain of comparisons each ending in `return`, rather than a
// dense chain, for GAP-0088's reason: LLVM turns a dense chain into a jump
// table in a section this repo does not control.
// ---------------------------------------------------------------------------

/// How many rows the table has. **Reported, never used as a bound** — see
/// [ioctlDescNone] for why the index is not a row number.
const int ioctlDescRows = 6;

/// **THE DESCRIPTOR INDEX IS THE `_IOC_NR` ITSELF, AND THAT IS FORCED BY
/// GAP-0088 RATHER THAN CHOSEN FOR ELEGANCE.**
///
/// This table was first written with a dense index 0..5 and three accessors
/// keyed on it. LLVM turned every one of those `if` chains into a **lookup
/// table in `.rodata`** — 100 bytes of it — and `m1-interrupts` caught it:
/// that harness requires `kmain.o`'s `.rodata` to be "elements only, no
/// header" (ADR-0040), which is to say every byte of it must belong to a
/// declared `@rodata` table. A compiler-generated table in a section this repo
/// does not control is GAP-0088 exactly, and it is why `fileFromFat` is written
/// as a chain over sparse constants.
///
/// Keying on `_IOC_NR` makes the keys `0x00 0x02 0x09 0x0C 0x1E 0xC1` — a span
/// of 194 for six values, far too sparse for LLVM to build a table from. **The
/// sparsity is the mechanism and it must survive**: adding rows until the keys
/// are dense would bring the lookup table back, and `m1-interrupts` is what
/// would say so.
///
/// It is also simply truer. A descriptor IS a command number; the intermediate
/// index was a second name for one.
const int ioctlDescNone = 0x100;

// The six rows, by index. The names are the DRM ones and the numbers are what
// libdrm 2.4.134's headers produce on this target under Linux's `_IOC` --
// re-derived on every run by `tests/conformance/drm-abi/oracle.py` from
// Linux's own asm-generic/ioctl.h, and compared against these constants by
// the harness. Nothing here is transcribed and trusted.

/// `DRM_IOCTL_VERSION` = `DRM_IOWR(0x00, struct drm_version)`, 64 bytes.
/// `0xc0406400`.
const int ioctlDescVersion = 0x00;

/// `DRM_IOCTL_GET_MAGIC` = `DRM_IOR(0x02, struct drm_auth)`, **4 bytes**.
/// `0x80046402`. **The only `_IOC_READ`-ONLY row**, and the one the write-side
/// validator negative control is aimed at.
///
/// **FOUR, NOT EIGHT, AND THIS TABLE SAID EIGHT UNTIL IT WAS CHECKED.**
/// `drm_magic_t` is `unsigned int` on the branch `drm.h` takes here, so
/// `struct drm_auth` is 4 bytes and the request is `0x80046402`. Eight was a
/// plausible guess -- `drm_handle_t` IS `unsigned long` on this same branch
/// (ADR-0031 §3), so "the BSD branch widens things" is a real pattern and it
/// does not apply to this struct. The value was read out of a compiled object
/// rather than reasoned about, which is the only reason it is right, and it is
/// the whole argument for design/drm-abi.md §4.2's generator: SIX rows written
/// by hand produced one wrong number.
const int ioctlDescGetMagic = 0x02;

/// `DRM_IOCTL_GEM_CLOSE` = `DRM_IOW(0x09, struct drm_gem_close)`, 8 bytes.
/// `0x40086409`. **One of the 29 requests BSD's encoding would have moved**
/// (to `0x80086409`) and one of the five core render ioctls, which is why
/// ADR-0031 §3 calls the encoding choice "one line from being silently wrong".
const int ioctlDescGemClose = 0x09;

/// `DRM_IOCTL_GET_CAP` = `DRM_IOWR(0x0c, struct drm_get_cap)`, 16 bytes.
/// `0xc010640c`.
const int ioctlDescGetCap = 0x0C;

/// `DRM_IOCTL_SET_MASTER` = `DRM_IO(0x1e)`, NO PAYLOAD. `0x0000641e`.
/// **One of the four requests of 121 that carry none**, and the row that
/// proves `_IOC_NONE` is served rather than falling through a size check that
/// assumes a payload.
const int ioctlDescSetMaster = 0x1E;

/// `DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD` = `DRM_IOWR(0xc1, struct drm_syncobj_handle)`.
///
/// **THE ROW THIS WHOLE FILE'S DISPATCH RULE EXISTS FOR.** libdrm 2.4.134 says
/// 24 bytes and `0xc01864c1`; Linux 6.12 says 16 bytes and `0xc01064c1`,
/// because `struct drm_syncobj_handle` grew a `__u64 point` field between the
/// two. 119 of 121 requests agree between those releases; these two are real
/// skew between two real projects. This row carries BOTH sizes -- see
/// [ioctlDescAltSize] -- and a kernel that had switched on the request word
/// would serve exactly one of them.
const int ioctlDescSyncobjH2F = 0xC1;

/// The descriptor for `(type, nr)` — which IS the `nr` — or [ioctlDescNone] if
/// this kernel does not serve that request.
///
/// **This function is handed `nr` and `type`. It is never handed the request
/// word, and that is the API being the argument.** A `switch (request)` cannot
/// be written against this interface without first taking the request apart,
/// at which point the size is already separate and checking it is the obvious
/// next line.
@bare
u64 ioctlDescFind(u64 type, u64 nr) {
  if (type != u64(ioctlTypeDrm)) {
    return u64(ioctlDescNone);
  }
  if (nr == u64(0x00)) {
    return u64(ioctlDescVersion);
  }
  if (nr == u64(0x02)) {
    return u64(ioctlDescGetMagic);
  }
  if (nr == u64(0x09)) {
    return u64(ioctlDescGemClose);
  }
  if (nr == u64(0x0C)) {
    return u64(ioctlDescGetCap);
  }
  if (nr == u64(0x1E)) {
    return u64(ioctlDescSetMaster);
  }
  if (nr == u64(0xC1)) {
    return u64(ioctlDescSyncobjH2F);
  }
  return u64(ioctlDescNone);
}

/// The direction this kernel expects for descriptor [d].
@bare
u64 ioctlDescDir(u64 d) {
  if (d == u64(ioctlDescVersion)) {
    return u64(ioctlDirBoth);
  }
  if (d == u64(ioctlDescGetMagic)) {
    return u64(ioctlDirRead);
  }
  if (d == u64(ioctlDescGemClose)) {
    return u64(ioctlDirWrite);
  }
  if (d == u64(ioctlDescGetCap)) {
    return u64(ioctlDirBoth);
  }
  if (d == u64(ioctlDescSetMaster)) {
    return u64(ioctlDirNone);
  }
  if (d == u64(ioctlDescSyncobjH2F)) {
    return u64(ioctlDirBoth);
  }
  return u64(ioctlDirNone);
}

/// The primary legal payload size for descriptor [d], in bytes.
@bare
u64 ioctlDescSize(u64 d) {
  if (d == u64(ioctlDescVersion)) {
    return u64(64);
  }
  if (d == u64(ioctlDescGetMagic)) {
    return u64(4);
  }
  if (d == u64(ioctlDescGemClose)) {
    return u64(8);
  }
  if (d == u64(ioctlDescGetCap)) {
    return u64(16);
  }
  if (d == u64(ioctlDescSetMaster)) {
    return u64(0);
  }
  if (d == u64(ioctlDescSyncobjH2F)) {
    return u64(24);
  }
  return u64(0);
}

/// The SECOND legal payload size for descriptor [d], or 0 if it has only one.
///
/// **This is what "the descriptor carries the SET" means in §4.3 rule 3, and
/// it is deliberately a set of at most two rather than a range.**
///
/// A range would be a policy — *"anything between 16 and 24 is fine"* — and
/// the policy that a range implies is Linux's: accept a short struct and
/// zero-extend it. **This kernel refuses instead**, and design/libdrm-port.md
/// §5 gives the reason in one sentence: *"zero-extending by default is how a
/// caller's uninitialised field becomes a kernel default nobody chose."* A
/// size is legal here only because somebody deliberately wrote it in this
/// table, one uAPI version at a time. Today exactly one row has two, and it is
/// the one that was MEASURED to need two.
@bare
u64 ioctlDescAltSize(u64 d) {
  if (d == u64(ioctlDescSyncobjH2F)) {
    // Linux 6.12's `struct drm_syncobj_handle`, before it grew `__u64 point`.
    // Accepted because the skew was measured between two real releases, not
    // because short structs are generally welcome.
    return u64(16);
  }
  return u64(0);
}

/// 1 if [size] is in descriptor [d]'s set of legal sizes.
///
/// **Refused, not zero-extended** — the return is consumed by
/// [ioctlSysIoctl], which turns a 0 here into [ioctlRetSizeSkew] and stops.
@bare
u64 ioctlDescSizeOk(u64 d, u64 size) {
  if (size == ioctlDescSize(d)) {
    return u64(1);
  }
  final u64 alt = ioctlDescAltSize(d);
  if (alt < u64(1)) {
    return u64(0);
  }
  if (size == alt) {
    return u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// The pointer validators.
//
// **§4.3 RULE 4 SAYS "ioctl USES THEM UNCHANGED", AND THESE TWO FUNCTIONS ARE
// THE ONE PLACE THIS FILE DEPARTS FROM ADR-0031 §4. ADR-0033 §4 argues it and
// this comment states it at the point of departure rather than only there.**
//
// The departure, precisely: `elfOwns` refuses any length above [userWriteMax],
// which is 128, and `fileOwnsWrite` refuses any length above [fileReadMax],
// which is 512. Those two numbers are the POLICY BOUNDS OF THEIR ORIGINAL
// CALLERS -- `write`'s console limit and `read`'s per-call limit -- folded
// into the validators years before `ioctl` existed. They are not properties of
// the page walk, which is the part `ioctl` needs and the part GAP-0124
// mutation-tested.
//
// So a 248-byte `DRM_IOCTL_GET_STATS` -- the measured largest DRM payload --
// passes rule 2's [ioctlMaxPayload] check and is then refused by `elfOwns` for
// being longer than a console write. Reporting that as [ioctlRetBadPtr] would
// be a length problem wearing a pointer problem's name, which is precisely the
// class of silent wrongness this whole unit exists to close.
//
// Three ways out were available and the third is taken:
//
//   A. RAISE `elfOwns`' cap. **REJECTED.** `userSysWrite` relies on that cap
//      to enforce [userWriteMax]; raising it would silently let `write` print
//      more than 128 bytes and would weaken a mutation-tested validator to
//      serve a caller it knows nothing about.
//   B. WRITE ioctl'S OWN PAGE WALK. **REJECTED, and it is the tempting one.**
//      It would be twenty lines and it would be a SECOND implementation of the
//      check GAP-0124 exists to keep correct -- a third silent-wrongness path
//      in a unit whose brief was not to leave one.
//   C. **WINDOW THE RANGE AND CALL THE UNCHANGED VALIDATOR ON EACH WINDOW.**
//      Taken. `elfOwns([p, p+128))` walks every page of that sub-range; a
//      chain of consecutive sub-ranges covering `[argp, argp+size)` therefore
//      walks every page of the union, which is exactly what the whole-range
//      call would have walked. The validators are not touched, not copied, and
//      not weakened, and ioctl's own bound is re-imposed by rule 2 before
//      either of these functions is reached.
// ---------------------------------------------------------------------------

/// 1 if ring 3 may READ every byte of `[ptr, ptr+len)`.
///
/// Used for `_IOC_WRITE` — userspace writes the payload, the kernel reads it.
/// Reaches [elfOwns] unchanged, in windows of at most [userWriteMax].
///
/// [len] is bounded by [ioctlMaxPayload] before this is called, so the window
/// count is at most `ioctlMaxPayload / userWriteMax` = 2 and the addition
/// below cannot overflow: `ptr` has already been range-checked by the first
/// [elfOwns] call, which bounds it below [vmProgEnd].
@bare
u64 ioctlOwnsRead(u64 ptr, u64 len) {
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(ioctlMaxPayload)) {
    return u64(0);
  }
  u64 done = u64(0);
  while (done < len) {
    u64 n = len - done;
    if (n > u64(userWriteMax)) {
      n = u64(userWriteMax);
    }
    if (elfOwns(ptr + done, n) < u64(1)) {
      return u64(0);
    }
    done = done + n;
  }
  return u64(1);
}

/// 1 if ring 3 may WRITE every byte of `[ptr, ptr+len)`.
///
/// Used for `_IOC_READ` — the kernel writes and userspace reads. **This is the
/// stricter of the two**, because the kernel is about to write there, and the
/// difference between it and [ioctlOwnsRead] is one bit out of [vmEffective]
/// and the whole of W^X: a program's R+X segment passes the read-side
/// validator and fails this one, on purpose.
///
/// Reaches [fileOwnsWrite] unchanged, in windows of at most [fileReadMax].
/// [ioctlMaxPayload] is below [fileReadMax] today, so the loop runs exactly
/// once; it is a loop anyway so that raising [ioctlMaxPayload] later cannot
/// silently turn this into a validator that refuses everything.
@bare
u64 ioctlOwnsWrite(u64 ptr, u64 len) {
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(ioctlMaxPayload)) {
    return u64(0);
  }
  u64 done = u64(0);
  while (done < len) {
    u64 n = len - done;
    if (n > u64(fileReadMax)) {
      n = u64(fileReadMax);
    }
    if (fileOwnsWrite(ptr + done, n) < u64(1)) {
      return u64(0);
    }
    done = done + n;
  }
  return u64(1);
}

// ---------------------------------------------------------------------------
// The device: name matching, and the "driver".
// ---------------------------------------------------------------------------

/// Compares [len] bytes at [buf] against the `@rodata` table at [str] of
/// length [n]. Returns 1 if they are the same bytes.
///
/// [buf] is [fileBufBase] — the kernel's own bounce buffer, holding a copy
/// `fileSysOpen` already made through a validated pointer. **Nothing here
/// dereferences a ring-3 address**, which is why this can afford to walk the
/// bytes without re-validating.
@bare
u64 ioctlNameIs(u64 buf, u64 len, u64 str, u64 n) {
  if (len != n) {
    return u64(0);
  }
  u64 i = u64(0);
  while (i < n) {
    if (Pointer<u8>.fromAddress(buf + i).value !=
        Pointer<u8>.fromAddress(str + i).value) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// The device index for the [len] bytes at [buf], or [ioctlDevCount] if those
/// bytes are not a device name this kernel serves.
///
/// **Called from `fileSysOpen` AFTER the pointer-validated bounce-buffer copy
/// and BEFORE `fatParseAt`, and never from `fatLookup`.** That placement is
/// ADR-0031 §6's, and design/display-protocol.md §2.1 recorded why: a device
/// branch inside `fatLookup` is reached by `fileMakeEmpty` too, which would
/// treat the device name as a real directory entry and truncate and rewrite
/// it. **That is a ring-3-reachable volume corruption**, and it is avoided
/// here by where this function is called from rather than by anything inside
/// it.
@bare
u64 ioctlDevLookup(u64 buf, u64 len) {
  if (ioctlNameIs(buf, len, Rodata.addressOf(ioctlStrCard0), u64(14)) > u64(0)) {
    return u64(ioctlDevCard0);
  }
  if (ioctlNameIs(buf, len, Rodata.addressOf(ioctlStrRender), u64(19)) > u64(0)) {
    return u64(ioctlDevRender);
  }
  return u64(ioctlDevCount);
}

/// 1 if the [len] bytes at [buf] begin with `/`, i.e. are in the DEVICE
/// namespace rather than the FAT16 one.
///
/// **The two namespaces are disjoint by construction and this is the whole of
/// the argument**: `fatNameByteBad` forbids `/` in an 8.3 name, so no name
/// this returns 1 for can ever name a file on the volume, and no name on the
/// volume can ever reach [ioctlDevLookup]. A name starting with `/` that is
/// not one of the two served devices is [fileRetNotFound] and is NEVER
/// attempted as a FAT name — falling through to `fatParseAt` would make
/// `/nosuch` a plausible 8.3 parse failure instead of a missing device.
@bare
u64 ioctlIsDevName(u64 buf, u64 len) {
  if (len < u64(1)) {
    return u64(0);
  }
  if (Pointer<u8>.fromAddress(buf).value != u8(0x2F)) {
    return u64(0);
  }
  return u64(1);
}

/// Records that a device descriptor was opened.
@bare
void ioctlNoteOpen() {
  ioctlBump(u64(ioctlMetaOpens));
}

/// **The "driver". It is handed an OFFSET INTO [ioctlBufBase] and a length,
/// and it is never handed `argp`.**
///
/// That signature is §4.3 rule 5 enforced by the type system rather than by
/// discipline: there is no ring-3 address in scope in this function or
/// anything it calls, so a driver on this OS *cannot* dereference one by
/// accident. When a real DRM driver arrives it inherits this shape.
///
/// **What it is NOT: a GPU, or any DRM semantics whatsoever.** It fills the
/// read-side payload with a deterministic pattern derived from the descriptor
/// index and the device index, which the harness predicts from outside the
/// kernel. GAP-0177 records that plainly so that nobody reads "ioctl works"
/// as "DRM works": what works is the MEMBRANE — decode, validate, bounce,
/// dispatch on `_IOC_NR`, refuse on skew — and the membrane is the rung
/// design/drm-abi.md S0 asked for.
///
/// Returns 0, or a refusal at or above [ioctlRetFloor].
@bare
u64 ioctlDevServe(u64 dev, u64 d, u64 dir, u64 size) {
  if (dev >= u64(ioctlDevCount)) {
    return u64(ioctlRetNoDev);
  }
  if (dir == u64(ioctlDirNone)) {
    return u64(0);
  }
  if (dir == u64(ioctlDirWrite)) {
    // Userspace wrote it, the kernel read it, and there is nothing to send
    // back. The bytes are in the bounce buffer and this rung does not act on
    // them; a real driver would.
    return u64(0);
  }
  // A read-side direction: the kernel writes the payload. The pattern is
  // `(desc << 4) | dev` in every byte, XORed with the byte's own index, so
  // that a harness comparing it can tell a right answer from a zeroed buffer
  // AND from an off-by-one in the length.
  final u64 seed = (d << u64(4)) | dev;
  final u64 base = ioctlBufBase();
  u64 i = u64(0);
  while (i < size) {
    Pointer<u8>.fromAddress(base + i).value = ((seed ^ i) & u64(0xFF)).toU8();
    i = i + u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// `IOCTL REQ <req> DIR <d> SIZE <ssss> TYPE <tt> NR <nn>`
///
/// **The decode, printed from inside the kernel, and it is the milestone's
/// central assertion.** ADR-0031 §4.4 requires the harness to compare all four
/// fields against values *it* computes from the `_IOC` macros transcribed from
/// Linux's own `include/uapi/asm-generic/ioctl.h` — NOT read back out of the
/// kernel. So this line is the kernel's claim and `oracle.py` is the
/// independent one, and the harness requires them to agree.
@bare
void ioctlDecodeLine(u64 req) {
  uartWrite(Rodata.addressOf(ioctlStrReq), u64(10));
  uartPutHex(req, u64(8));
  uartWrite(Rodata.addressOf(ioctlStrDir), u64(5));
  uartPutHex(ioctlDir(req), u64(1));
  uartWrite(Rodata.addressOf(ioctlStrSize), u64(6));
  uartPutHex(ioctlSize(req), u64(4));
  uartWrite(Rodata.addressOf(ioctlStrType), u64(6));
  uartPutHex(ioctlType(req), u64(2));
  uartWrite(Rodata.addressOf(ioctlStrNr), u64(4));
  uartPutHex(ioctlNr(req), u64(2));
  uartNewline();
}

/// Records a refusal, prints it, and hands [code] back to ring 3 in RAX.
///
/// **A refusal is printed and counted, never silent** — [userRefuse]'s reason
/// and `frames`' ERRORS word's reason (ADR-0011 §4): a subsystem that reports
/// zero refusals is making a claim only if a refusal would have been recorded.
/// The four negative controls this unit is judged on all read their result off
/// this line.
@bare
void ioctlRefuse(u64 frame, u64 code) {
  ioctlBump(u64(ioctlMetaRefusals));
  ioctlSetMeta(u64(ioctlMetaLastCode), code);
  uartWrite(Rodata.addressOf(ioctlStrRefused), u64(14));
  uartPutHex(code, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), code);
}

/// `IOCTL OK IN <n> OUT <n>`
///
/// **The in- and out- byte counts are printed separately and that is an
/// anti-vacuity requirement**, not decoration: ADR-0031 §4.4 requires them to
/// DIFFER for a `_IOC_WRITE`-only call. A kernel that ignored `_IOC_DIR` and
/// copied both ways would print the same number twice and the harness would
/// catch it.
@bare
void ioctlOkLine(u64 inBytes, u64 outBytes) {
  uartWrite(Rodata.addressOf(ioctlStrOkIn), u64(12));
  uartPutHex(inBytes, u64(4));
  uartWrite(Rodata.addressOf(ioctlStrOut), u64(5));
  uartPutHex(outBytes, u64(4));
  uartNewline();
}

/// Four lines of totals, printed by the exit report — **and NOTHING AT ALL
/// unless this boot actually opened a device or issued an `ioctl`.**
///
/// `IOCTL CALLS <n> SERVED <n> REFUSALS <n>`
/// `IOCTL BYTES IN <n> OUT <n>`
/// `IOCTL DEV OPENS <n>`
/// `IOCTL MAXPAYLOAD <n> CEIL <n> DESCS <n>`
///
/// **The silence is load-bearing and it is [fileExitReport]'s discipline
/// exactly.** Every harness before this unit boots a kernel that never issues
/// an `ioctl`, and there are twenty-one of them, several asserting a
/// byte-exact serial capture — `m1-interrupts` asserts the entire 544-byte
/// one. A line printed unconditionally at boot, or unconditionally at exit,
/// would move every golden in the repo to report a zero. So the constants line
/// is here, inside the guard, rather than in an init at boot where it was
/// first written -- that version moved every golden in the repo to report a
/// zero, which is how the guard came to exist.
@bare
void ioctlReport() {
  if (ioctlMeta(u64(ioctlMetaCalls)) < u64(1)) {
    if (ioctlMeta(u64(ioctlMetaOpens)) < u64(1)) {
      return;
    }
  }
  uartWrite(Rodata.addressOf(ioctlStrCalls), u64(12));
  uartPutHex(ioctlMeta(u64(ioctlMetaCalls)), u64(4));
  uartWrite(Rodata.addressOf(ioctlStrServed), u64(8));
  uartPutHex(ioctlMeta(u64(ioctlMetaServed)), u64(4));
  uartWrite(Rodata.addressOf(ioctlStrRefusals), u64(10));
  uartPutHex(ioctlMeta(u64(ioctlMetaRefusals)), u64(4));
  uartNewline();
  uartWrite(Rodata.addressOf(ioctlStrBytesIn), u64(15));
  uartPutHex(ioctlMeta(u64(ioctlMetaInBytes)), u64(4));
  uartWrite(Rodata.addressOf(ioctlStrOut), u64(5));
  uartPutHex(ioctlMeta(u64(ioctlMetaOutBytes)), u64(4));
  uartNewline();
  uartWrite(Rodata.addressOf(ioctlStrDevOpens), u64(16));
  uartPutHex(ioctlMeta(u64(ioctlMetaOpens)), u64(4));
  uartNewline();
  // `IOCTL MAXPAYLOAD <n> CEIL <n> DESCS <n>`
  //
  // **The harness requires MAXPAYLOAD to be strictly below CEIL**, which is
  // the check that [ioctlMaxPayload] is really "well under the 14-bit ceiling"
  // (ADR-0031 §4.3) rather than a second name for it. Both numbers are read
  // off this line and compared by the harness against the constants it parses
  // out of this file, so neither can drift without the other.
  uartWrite(Rodata.addressOf(ioctlStrMaxPayload), u64(17));
  uartPutHex(u64(ioctlMaxPayload), u64(4));
  uartWrite(Rodata.addressOf(ioctlStrCeil), u64(6));
  uartPutHex(u64(ioctlEncMaxSize), u64(4));
  uartWrite(Rodata.addressOf(ioctlStrDescs), u64(7));
  uartPutHex(u64(ioctlDescRows), u64(2));
  uartNewline();
}

// ---------------------------------------------------------------------------
// THE SYSCALL.
// ---------------------------------------------------------------------------

/// Syscall 12 — `ioctl(fd, request, argp)`. Returns 0, or a refusal at or
/// above [ioctlRetFloor].
///
/// **Read this function as a sequence and the order is the specification.**
/// §4.3's seven rules are applied in the order §4.3 gives them, and two of
/// those orderings are load-bearing rather than tidy:
///
///   * **`_IOC_TYPE` is checked before `_IOC_SIZE` or `_IOC_DIR` are used for
///     anything.** A kernel that decoded size and direction first would be
///     doing arithmetic on a word it has not established is for it.
///   * **BOTH validators run before EITHER copy**, on an `_IOWR`. Validating
///     the read side, copying in, then validating the write side would leave a
///     window in which the kernel has already acted on a request it has not
///     finished checking — and the out-copy would then be the second half of a
///     transaction whose first half already happened.
///
/// The out-copy happens only after [ioctlDevServe] returns 0. A refused
/// request must not write anything into the caller's buffer: a program that
/// reads its `argp` after a refusal must find what it put there, not half a
/// kernel structure.
@bare
void ioctlSysIoctl(u64 frame) {
  ioctlBump(u64(ioctlMetaCalls));
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    ioctlRefuse(frame, u64(ioctlRetNoOwner));
    return;
  }
  final u64 fd = userFrame(frame, u64(userFrameRdi));
  final u64 req = userFrame(frame, u64(userFrameRsi));
  final u64 argp = userFrame(frame, u64(userFrameRdx));
  ioctlSetMeta(u64(ioctlMetaLastReq), req);
  if (fd >= u64(fileMaxFds)) {
    ioctlRefuse(frame, u64(ioctlRetBadFd));
    return;
  }
  final u64 state = fileFd(row, fd, u64(fileFdState));
  if (state < u64(fileFdOpen)) {
    ioctlRefuse(frame, u64(ioctlRetBadFd));
    return;
  }
  // §4.3 rule 7 — ENOTTY's equivalent. A FAT16 descriptor is not a device, and
  // this refusal is from THIS file's vocabulary so that m15-fileio and
  // m16-filewrite keep meaning what they meant.
  if (state != u64(fileFdDevice)) {
    ioctlRefuse(frame, u64(ioctlRetNotDev));
    return;
  }
  final u64 dev = fileFd(row, fd, u64(fileFdDevIndex));

  // The decode is printed BEFORE the checks, so that a refused request still
  // says what it was. A transcript in which a refusal names no request is a
  // transcript that cannot distinguish "the kernel refused the right thing"
  // from "the kernel refused everything".
  ioctlDecodeLine(req);

  // ---- rule 1: TYPE FIRST, before any other field is used. ---------------
  final u64 type = ioctlType(req);
  if (type != u64(ioctlTypeDrm)) {
    ioctlRefuse(frame, u64(ioctlRetBadType));
    return;
  }

  final u64 nr = ioctlNr(req);
  final u64 dir = ioctlDir(req);
  final u64 size = ioctlSize(req);

  // ---- rule 2: SIZE non-zero for a direction that carries one, and at most
  //      ioctlMaxPayload. REFUSED, NEVER TRUNCATED. --------------------------
  if (dir == u64(ioctlDirNone)) {
    if (size > u64(0)) {
      // `_IOC_NONE` with a size is not a request this kernel can make sense
      // of: there is no direction to copy it in. Refused rather than treated
      // as "no payload after all", which would be a silent reinterpretation of
      // what the caller asked for.
      ioctlRefuse(frame, u64(ioctlRetBadSize));
      return;
    }
  } else {
    if (size < u64(1)) {
      ioctlRefuse(frame, u64(ioctlRetBadSize));
      return;
    }
    if (size > u64(ioctlMaxPayload)) {
      ioctlRefuse(frame, u64(ioctlRetBadSize));
      return;
    }
  }

  // ---- DISPATCH ON `_IOC_NR`. NEVER ON THE REQUEST WORD. ------------------
  final u64 d = ioctlDescFind(type, nr);
  if (d >= u64(ioctlDescNone)) {
    ioctlRefuse(frame, u64(ioctlRetBadNr));
    return;
  }
  if (dir != ioctlDescDir(d)) {
    ioctlRefuse(frame, u64(ioctlRetBadDir));
    return;
  }

  // ---- rule 3: the size must be in the descriptor's SET. Refused, NOT
  //      zero-extended. -----------------------------------------------------
  if (ioctlDescSizeOk(d, size) < u64(1)) {
    ioctlRefuse(frame, u64(ioctlRetSizeSkew));
    return;
  }

  // ---- rule 4: argp through M16's validators. BOTH, BEFORE EITHER COPY. ---
  //
  // The zero-size `_IOC_NONE` case takes neither: there is no range to
  // validate, and running a validator over a zero-length range would ask
  // `elfOwns` a question it deliberately answers "no" to.
  if (size > u64(0)) {
    if (dir == u64(ioctlDirWrite)) {
      if (ioctlOwnsRead(argp, size) < u64(1)) {
        ioctlRefuse(frame, u64(ioctlRetBadPtr));
        return;
      }
    }
    if (dir == u64(ioctlDirRead)) {
      if (ioctlOwnsWrite(argp, size) < u64(1)) {
        ioctlRefuse(frame, u64(ioctlRetBadPtr));
        return;
      }
    }
    if (dir == u64(ioctlDirBoth)) {
      if (ioctlOwnsRead(argp, size) < u64(1)) {
        ioctlRefuse(frame, u64(ioctlRetBadPtr));
        return;
      }
      if (ioctlOwnsWrite(argp, size) < u64(1)) {
        ioctlRefuse(frame, u64(ioctlRetBadPtr));
        return;
      }
    }
  }

  // ---- rule 5: the copy IN, through the bounce buffer. --------------------
  //
  // The buffer is cleared over the whole payload first. Without that, a
  // request whose direction is read-only would hand ring 3 whatever the
  // PREVIOUS ioctl left in the buffer -- which is a kernel-memory disclosure
  // from one call to the next, inside one process, and would never show up as
  // a validator failure.
  final u64 buf = ioctlBufBase();
  u64 z = u64(0);
  while (z < u64(ioctlMaxPayload)) {
    Pointer<u8>.fromAddress(buf + z).value = u8(0);
    z = z + u64(1);
  }
  u64 inBytes = u64(0);
  if (size > u64(0)) {
    if (dir != u64(ioctlDirRead)) {
      // `_IOC_WRITE` and `_IOWR`: userspace wrote it, the kernel reads it.
      u64 i = u64(0);
      while (i < size) {
        Pointer<u8>.fromAddress(buf + i).value =
            Pointer<u8>.fromAddress(argp + i).value;
        i = i + u64(1);
      }
      inBytes = size;
    }
  }

  // ---- the driver. Handed an offset and a length, never `argp`. -----------
  final u64 s = ioctlDevServe(dev, d, dir, size);
  if (s > u64(0)) {
    ioctlRefuse(frame, s);
    return;
  }

  // ---- rule 6: the out-copy, ONLY ON SUCCESS. -----------------------------
  u64 outBytes = u64(0);
  if (size > u64(0)) {
    if (dir != u64(ioctlDirWrite)) {
      // `_IOC_READ` and `_IOWR`: the kernel writes and userspace reads. The
      // range was validated with the WRITE-side validator above, before
      // anything was copied in either direction.
      u64 j = u64(0);
      while (j < size) {
        Pointer<u8>.fromAddress(argp + j).value =
            Pointer<u8>.fromAddress(buf + j).value;
        j = j + u64(1);
      }
      outBytes = size;
    }
  }

  ioctlBump(u64(ioctlMetaServed));
  ioctlSetMeta(u64(ioctlMetaInBytes),
      ioctlMeta(u64(ioctlMetaInBytes)) + inBytes);
  ioctlSetMeta(u64(ioctlMetaOutBytes),
      ioctlMeta(u64(ioctlMetaOutBytes)) + outBytes);
  ioctlSetMeta(u64(ioctlMetaLastCode), u64(0));
  ioctlOkLine(inBytes, outBytes);
  userSetFrame(frame, u64(userFrameRax), u64(0));
}
