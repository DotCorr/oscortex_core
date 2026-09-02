part of 'kmain.dart';

// ---------------------------------------------------------------------------
// M21 -- SHARED MEMORY REGIONS, AND A CAPABILITY THAT CAN BE HANDED TO A PEER.
//
// ADR-0041. The rung above ADR-0027's channel, and the thing that ADR-0027
// deliberately refused to fake.
//
// WHY THIS EXISTS AT ALL, IN ONE PARAGRAPH. M20 capped a channel message at 64
// bytes IN THE KERNEL, and argued that a generous cap is the trap: an 800x600x32
// frame is 1,920,000 bytes against a total kernel mutable-static budget of
// 17,504, so a message primitive that could carry a frame would copy 1.92 MB
// through the kernel twice per frame at 60 Hz. That argument only holds if bulk
// data has somewhere else to go. THIS IS THAT SOMEWHERE ELSE. A message carries
// the NAME of a region; the region carries the bytes; and the two mechanisms
// compose without either of them changing (ADR-0027 §2.3 promised exactly that,
// and `chan.dart` is unmodified here apart from one read-only accessor).
//
// THE THREE THINGS THIS FILE HAS TO GET RIGHT
//
// 1. W^X, WHICH SHARED MEMORY IS THE CLASSIC PLACE TO GIVE BACK. A shared page
//    is never executable, and that is enforced twice on purpose: `vmShmMap` has
//    no `exec` parameter at all and sets NX unconditionally, so the state is not
//    expressible; and `shmSysMap` refuses a REQUEST for it by name
//    ([shmRetExec]) so that ring 3 is told rather than quietly given something
//    else. ADR-0012 bought W^X for the kernel and ADR-0014 refused a guest an
//    exemption from it; a page two processes share does not get one either.
//
// 2. A CAPABILITY THAT CANNOT BE FORGED. The table lives in the PROCESS SLOT
//    and is reached only through `procGet(procCurrent(), ...)`. A handle is an
//    index into the CALLER'S OWN table, so guessing one reaches only a
//    capability the kernel itself put there -- i.e. one this process was
//    granted. **The security does not rest on the number being hard to guess**,
//    which is the honest form of the claim; see ADR-0041 §4.
//
// 3. A LIFETIME STORY THAT SURVIVES A DEAD PEER. A region's frames are held by
//    the number of LIVE CAPABILITIES naming it, not by the number of address
//    spaces mapping it. So a creator can exit while its peer still holds a
//    capability, and the peer keeps reading -- which is the shared-memory
//    equivalent of ADR-0027 §5's "a dead sender's messages are still
//    delivered", and is the case `m21-shmem` runs.
//
// WHAT IS DELIBERATELY NOT HERE, each with a gap number so none of it is left
// as an impression:
//
//   * No involuntary revocation. A grantor cannot take a capability back;
//     `shmdrop` releases the CALLER'S own. GAP-0233, with the mechanism it
//     would take written out.
//   * Grow past the create size is ADR-0150 (`shmgrow`, syscall 34).
//     Shrink is ADR-0156 (`shmshrink`, syscall 35). Multi-mapper grow /
//     shrink updates every address space that holds a mapping (ADR-0158).
//     Partial / offset map is ADR-0160 (`shmmap` rdx range word).
//     mprotect + MAP_FIXED are ADR-0163 (syscall 36 + shmmap flag).
//     File backing + demand paging are ADR-0164 (syscall 37 shmfile).
//   * No atomicity across a region and no lock. One writer by construction
//     (a grant is READ-ONLY), which is most of why that is survivable.
//     GAP-0236.
//   * No blocking. A reader polls, exactly as ADR-0027's receiver does
//     (GAP-0200). Nothing on this machine can block.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Geometry.
// ---------------------------------------------------------------------------

/// How many regions can exist at once.
///
/// **Four.** Sit-in Start lists four named ELFs; a session that already
/// holds two resident surfaces must still be able to spawn SET or
/// STUDIO (ADR-0109). The window is still one page-directory entry
/// ([vmShmPages] 512). Four regions of 128 pages each divide
/// `[vmShmBase, vmShmEnd)` exactly. No new syscall; the table grew.
const int shmMax = 4;

/// Pages of window address space reserved per region SLOT, whatever the region
/// in it actually asked for.
///
/// **A region's virtual address is therefore a function of its slot alone, and
/// is the SAME NUMBER IN EVERY ADDRESS SPACE.** That is worth more than the
/// address space it wastes: a frame descriptor sent down a 64-byte channel
/// message can carry an OFFSET that means the same thing to both peers, and
/// neither side has to translate the other's pointers. A bump allocator would
/// have packed the window tighter and made a region's address depend on the
/// order regions happened to be created in, which is a difference two processes
/// would then have to agree about.
const int shmSlotPages = 128;

/// The largest region this kernel will create, in pages: one slot's worth.
/// 128 pages is 524,288 bytes.
///
/// **An 800x600x32 frame is 469 pages and does NOT fit**, and that is stated
/// here rather than discovered later. The window ([vmShmPages], 512) is large
/// enough for one; the SLOTTING is what caps it. Today's FRAME surfaces are
/// 38 pages (240x160). Configuring `shmMax` 1 / `shmSlotPages` 512 still
/// fits a full-screen frame and changes no ABI -- GAP-0237. ADR-0109 took
/// four slots so the DE can hold Start's apps, not one big slot.
/* A region may use the shared window's free extent. The two final vector
 * words are file metadata, leaving 510 physical-page entries. */
const int shmMaxPages = 510;
const int shmMapsMask = 0xFFFFFFFF;
const int shmBaseShift = 32;

// ---------------------------------------------------------------------------
// The storage. See ADR-0021 and `docs/design/memory.md` §2.4.
// ---------------------------------------------------------------------------

const int shmMetaWords = 16;
const int shmMetaBytes = 128;

const int shmRegOffset = 128;
const int shmRegWords = 8;
const int shmRegBytes = 64;

/// One bit per frame in the machine: 1 = this frame belongs to a live region.
///
/// **8192 bytes, matching the frame bitmap after ADR-0155's 256 MiB PMM
/// raise, and the shape is copied from it deliberately.** `docs/design/memory.md`
/// §2.4 measured the alternative: `freeFrame` is called once per managed
/// frame by `frames refill`, and a linear scan of even a 64-entry shared-frame
/// table there is millions of volatile loads. A bit-plane makes the test in
/// `freeFrame` ONE BIT-TEST, which is the same operation `pmmAllocatable`
/// already does on the same path.
const int shmPlaneOffset = 384; // 128 + 4 * 64
const int shmPlaneBytes = 8192;

/// Frames the plane can describe: `shmPlaneBytes * 8`. Equal to `pmmMaxFrames`,
/// and `m21-shmem/run.sh` asserts that equality rather than trusting it -- a
/// plane shorter than the bitmap would silently stop protecting the top of
/// memory.
const int shmPlaneFrames = 65536;

/// 128 + 4 * 64 + 8192.
const int shmStoreBytes = 8576;

// Global counter words.
const int shmMetaCreates = 0;
const int shmMetaGrants = 1;
const int shmMetaMaps = 2;
const int shmMetaDrops = 3;
const int shmMetaRefusals = 4;
const int shmMetaDestroys = 5;

/// How many times [freeFrame] has RETAINED a frame because a live region owned
/// it. **The visible form of the one branch in `freeFrame`**: a guard whose
/// effect is invisible is one nobody can tell is working, and `m21-shmem`
/// requires this to be non-zero on a boot where a process exits holding a
/// mapping.
const int shmMetaRetained = 6;

/// Monotonic generation counter. Never reset, never reused within a boot.
const int shmMetaGen = 7;

/// Frames returned to the allocator by [shmRegionDestroy], cumulative.
///
/// **The counterpart of [shmMetaRetained], and the pair is the whole lifetime
/// claim in two numbers**: how many frees this kernel declined because a region
/// still owned the frame, and how many frames it gave back when the region
/// finally died. `m21-shmem` requires both to be non-zero and requires the
/// second to account for every page the boot created.
const int shmMetaFreed = 8;

/// Clipboard selection (ADR-0183). Spare meta words — not a new `@bss`.
/// Compositor protocol in `wmext.dart`; storage here so `wmStore` stays 448.
const int shmMetaClipReg = 9;
const int shmMetaClipGen = 10;
const int shmMetaClipOwner = 11;
const int shmMetaClipLen = 12;

// Region record words.
const int shmRegState = 0;
const int shmRegOwner = 1;
const int shmRegPages = 2;
const int shmRegGen = 3;

/// Physical address of this region's FRAME VECTOR page -- one frame holding the
/// physical address of each of the region's pages, one `u64` each.
///
/// **The frames are remembered here rather than recovered from a page table,
/// and the difference is a leak.** `procSpaceFree` recovers a program's pages
/// from its own tables because the tables are what the CPU obeys. A region,
/// though, can legitimately be mapped by NO address space -- its creator has
/// exited and its grantee has not called `shmmap` yet -- and at that instant a
/// table-recovered teardown would find nothing to free. One frame per live
/// region, holding up to 512 addresses, is the cheapest honest answer and is
/// the "page-vector accessor" `docs/design/memory.md` §3.1(2) recommends.
const int shmRegVec = 4;

/// Live capabilities naming this region. **This, not the map count, is what
/// keeps the frames alive.**
const int shmRegRefs = 5;

/// Address spaces currently mapping this region. Reporting and the map/unmap
/// bookkeeping; nothing decides a lifetime from it.
const int shmRegMaps = 6;

/// Grants made from this region, a statistic.
const int shmRegGrants = 7;

const int shmRegFree = 0;
const int shmRegLive = 1;

/// Live region whose pages are filled on first touch from a FAT fd
/// (ADR-0164). Distinct from [shmRegLive] so grow/shrink/mprotect stay
/// on the eager anonymous door.
const int shmRegLiveFile = 2;

/// Capabilities a process can hold at once: slot words 24..27.
const int shmCapsPerProc = 4;

// ---------------------------------------------------------------------------
// Permissions, as ring 3 asks for them.
// ---------------------------------------------------------------------------

/// The two legal `shmmap` permission words, and the one illegal one that exists
/// SO THAT IT CAN BE REFUSED BY NAME.
///
/// [shmPermExec] is not a capability this kernel grants under any combination.
/// It is defined here because a refusal a program cannot ASK for is a refusal
/// nobody can test, and `m21-shmem`'s program asks for it and requires
/// [shmRetExec] back. That is the ring-3-observable half of the W^X argument;
/// the other half is that `vmShmMap` cannot express the state at all.
const int shmPermRead = 1;
const int shmPermWrite = 2;
const int shmPermExec = 4;

/// Read-only: what a GRANT conveys, always.
const int shmPermRo = 1;

/// Read-write: what a CREATOR holds, always.
const int shmPermRw = 3;

/// ADR-0163 — `MAP_FIXED` bit in the `shmmap` perms word. When set, `rcx`
/// must equal the slot VA of the first mapped page. Wrong address is
/// [shmRetBadFixed]; already-mapped is still [shmRetMapped].
const int shmMapFixed = 0x100;

// ---------------------------------------------------------------------------
// Syscall numbers. See docs/syscall-registry.md -- the registry is the
// allocator, and 16..19 are the first free numbers after M20 and S0 (GAP-0213).
// ---------------------------------------------------------------------------

const int shmSysCreateNo = 16;
const int shmSysGrantNo = 17;
const int shmSysMapNo = 18;
const int shmSysDropNo = 19;

/// ADR-0150 — syscall 34, `shmgrow(handle, newPages) -> 0`.
/// 11 stays `fdwait`. 33 is `setfs`.
const int shmSysGrowNo = 34;

/// ADR-0156 — syscall 35, `shmshrink(handle, newPages) -> 0`.
/// 11 stays `fdwait`. 34 is `shmgrow`.
const int shmSysShrinkNo = 35;

/// ADR-0163 — syscall 36, `mprotect(handle, perms) -> 0`.
/// Downgrade (or confirm) live mapping permissions. 11 stays `fdwait`.
const int shmSysMprotectNo = 36;

/// ADR-0164 — syscall 37, `shmfile(fd) -> handle`.
/// File-backed region; pages demand-filled from the open FAT fd.
/// 11 stays `fdwait`. 36 is `mprotect`.
const int shmSysFileNo = 37;

/// Trailer in the page-vector frame: file byte size (ADR-0164).
const int shmVecFileSizeOff = 4080;

/// Trailer: `(row << 8) | (fd + 1)`. Zero means not file-backed.
const int shmVecFilePackOff = 4088;

// ---------------------------------------------------------------------------
// Return values. `file.dart`'s convention (ADR-0019 §3): one floor, every code
// above it distinct, so ONE comparison separates an answer from a refusal.
// A handle is `(capIndex << 32) | generation` and a mapped address is inside
// `[vmShmBase, vmShmEnd)`; both are far below the floor.
// ---------------------------------------------------------------------------

const int shmRetFloor = 0xFFFFFFFFFFFFFF00;

/// The caller is not a process. An endpoint, a capability table and a page
/// directory all belong to a process slot, and an M9 payload has none.
const int shmRetNoProc = 0xFFFFFFFFFFFFFFFE;

/// `pages` is 0 or greater than [shmMaxPages].
const int shmRetBadLen = 0xFFFFFFFFFFFFFFFD;

/// Every region slot is live.
const int shmRetNoSpace = 0xFFFFFFFFFFFFFFFC;

/// The frame allocator, or the page-table allocation, could not be satisfied.
/// **Everything already taken on this path has been given back** before this is
/// returned; see [shmCreateRollback].
const int shmRetNoMem = 0xFFFFFFFFFFFFFFFB;

/// The relevant capability table is full ([shmCapsPerProc] entries).
const int shmRetNoCap = 0xFFFFFFFFFFFFFFFA;

/// The handle's index is out of range, or names an EMPTY capability slot.
/// **This is what a forged handle gets**, and it is the common case rather than
/// the exotic one: a number a program invented names a slot the kernel never
/// filled.
const int shmRetBadCap = 0xFFFFFFFFFFFFFFF9;

/// The handle's index names a live capability whose GENERATION does not match
/// -- a handle to a region that has since died and whose slot was reused.
/// Distinct from [shmRetBadCap] because a client acts differently: a stale
/// handle means "that region is gone", a bad one means "you never had it".
const int shmRetStale = 0xFFFFFFFFFFFFFFF8;

/// The endpoint argument to `shmgrant` is not one this process owns.
const int shmRetBadEp = 0xFFFFFFFFFFFFFFF7;

/// The channel named by the endpoint has no peer -- nobody has taken the other
/// side, or the peer has exited.
const int shmRetNoPeer = 0xFFFFFFFFFFFFFFF6;

/// The peer already holds a capability for this region.
const int shmRetTwice = 0xFFFFFFFFFFFFFFF5;

/// This capability is already mapped in this address space.
const int shmRetMapped = 0xFFFFFFFFFFFFFFF4;

/// **An executable mapping was requested.** W^X, refused by name.
const int shmRetExec = 0xFFFFFFFFFFFFFFF3;

/// The permission word is not one of the legal ones, or asks for more than the
/// capability carries -- a READ-ONLY capability asking to be mapped writable.
/// **That is a privilege-escalation attempt expressed as an argument**, and it
/// is refused rather than clamped.
const int shmRetBadPerm = 0xFFFFFFFFFFFFFFF2;

/// The window's page table could not be reached or installed.
const int shmRetNoTable = 0xFFFFFFFFFFFFFFF1;

/// A mapping operation was refused by `vmShmMap` for a reason above -- an
/// address already occupied. Counted separately so a kernel bug does not
/// masquerade as a caller error.
const int shmRetMapFail = 0xFFFFFFFFFFFFFFF0;

/// `MAP_FIXED` was set and `rcx` is not the slot VA of the first mapped
/// page (ADR-0163). Distinct from [shmRetMapped] (overlap) and
/// [shmRetBadLen] (range).
const int shmRetBadFixed = 0xFFFFFFFFFFFFFFEF;

/// The refusal line's opening: `'SHM REFUSE C '` -- 13 bytes.
@rodata
final List<u8> shmStrRefuse = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53),
  u8(0x45), u8(0x20), u8(0x43), u8(0x20),
];

/// Field separator: a ring-3 handle. `' H '` -- 3 bytes.
@rodata
final List<u8> shmStrH = const [
  u8(0x20), u8(0x48), u8(0x20),
];

/// Field separator: a refusal code, or a region index. `' R '` -- 3 bytes.
@rodata
final List<u8> shmStrR = const [
  u8(0x20), u8(0x52), u8(0x20),
];

/// `'SHM CREATE R '` -- 13 bytes.
@rodata
final List<u8> shmStrCreate = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x43), u8(0x52), u8(0x45), u8(0x41), u8(0x54),
  u8(0x45), u8(0x20), u8(0x52), u8(0x20),
];

/// Field separator: a region generation. `' GEN '` -- 5 bytes.
@rodata
final List<u8> shmStrGen = const [
  u8(0x20), u8(0x47), u8(0x45), u8(0x4E), u8(0x20),
];

/// Field separator: a page count. `' PAGES '` -- 7 bytes.
@rodata
final List<u8> shmStrPages = const [
  u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator: a window virtual address. `' VA '` -- 4 bytes.
@rodata
final List<u8> shmStrVa = const [
  u8(0x20), u8(0x56), u8(0x41), u8(0x20),
];

/// `'SHM GRANT R '` -- 12 bytes.
@rodata
final List<u8> shmStrGrant = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x47), u8(0x52), u8(0x41), u8(0x4E), u8(0x54),
  u8(0x20), u8(0x52), u8(0x20),
];

/// Field separator: the grantee's process id. `' TO '` -- 4 bytes.
@rodata
final List<u8> shmStrTo = const [
  u8(0x20), u8(0x54), u8(0x4F), u8(0x20),
];

/// `'SHM PAGE '` -- 9 bytes.
@rodata
final List<u8> shmStrPage = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x20),
];

/// `' P '` -- 3 bytes.
@rodata
final List<u8> shmStrP = const [
  u8(0x20), u8(0x50), u8(0x20),
];

/// `' U '` -- 3 bytes.
@rodata
final List<u8> shmStrU = const [
  u8(0x20), u8(0x55), u8(0x20),
];

/// `' W '` -- 3 bytes.
@rodata
final List<u8> shmStrW = const [
  u8(0x20), u8(0x57), u8(0x20),
];

/// `' X '` -- 3 bytes.
@rodata
final List<u8> shmStrX = const [
  u8(0x20), u8(0x58), u8(0x20),
];

/// `' PA '` -- 4 bytes.
@rodata
final List<u8> shmStrPa = const [
  u8(0x20), u8(0x50), u8(0x41), u8(0x20),
];

/// `'SHM MAP R '` -- 10 bytes.
@rodata
final List<u8> shmStrMap = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x4D), u8(0x41), u8(0x50), u8(0x20), u8(0x52),
  u8(0x20),
];

/// `'SHM DROP R '` -- 11 bytes.
@rodata
final List<u8> shmStrDrop = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x44), u8(0x52), u8(0x4F), u8(0x50), u8(0x20),
  u8(0x52), u8(0x20),
];

/// `'SHM GROW R '` -- 11 bytes.
@rodata
final List<u8> shmStrGrow = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x47), u8(0x52), u8(0x4F), u8(0x57), u8(0x20),
  u8(0x52), u8(0x20),
];

/// `'SHM SHRINK R '` -- 13 bytes.
@rodata
final List<u8> shmStrShrink = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x53), u8(0x48), u8(0x52), u8(0x49), u8(0x4E),
  u8(0x4B), u8(0x20), u8(0x52), u8(0x20),
];

/// `'SHM PROT R '` -- 11 bytes.
@rodata
final List<u8> shmStrProt = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x50), u8(0x52), u8(0x4F), u8(0x54), u8(0x20),
  u8(0x52), u8(0x20),
];

/// Field separator: a region's live capability count. `' REFS '` -- 6 bytes.
@rodata
final List<u8> shmStrRefs = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x53), u8(0x20),
];

/// Field separator: address spaces currently mapping. `' MAPS '` -- 6 bytes.
@rodata
final List<u8> shmStrMaps = const [
  u8(0x20), u8(0x4D), u8(0x41), u8(0x50), u8(0x53), u8(0x20),
];

/// `'SHM DEAD R '` -- 11 bytes.
@rodata
final List<u8> shmStrDead = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x41), u8(0x44), u8(0x20),
  u8(0x52), u8(0x20),
];

/// Field separator: frames actually returned. `' FREED '` -- 7 bytes.
@rodata
final List<u8> shmStrFreed = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// Field separator: the permission word. `' PERM '` -- 6 bytes.
@rodata
final List<u8> shmStrPerm = const [
  u8(0x20), u8(0x50), u8(0x45), u8(0x52), u8(0x4D), u8(0x20),
];

/// Field separator: a partial-map page offset. `' OFF '` -- 5 bytes.
@rodata
final List<u8> shmStrOff = const [
  u8(0x20), u8(0x4F), u8(0x46), u8(0x46), u8(0x20),
];

/// Field separator: a partial-map page count. `' COUNT '` -- 7 bytes.
@rodata
final List<u8> shmStrCount = const [
  u8(0x20), u8(0x43), u8(0x4F), u8(0x55), u8(0x4E), u8(0x54), u8(0x20),
];

/// `'SHM FILE R '` -- 11 bytes. ADR-0164.
@rodata
final List<u8> shmStrFile = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x20),
  u8(0x52), u8(0x20),
];

/// Field separator: file byte size. `' SIZE '` -- 6 bytes.
@rodata
final List<u8> shmStrSize = const [
  u8(0x20), u8(0x53), u8(0x49), u8(0x5A), u8(0x45), u8(0x20),
];

/// `'SHM DEMAND R '` -- 13 bytes. ADR-0164 first-touch fill.
@rodata
final List<u8> shmStrDemand = const [
  u8(0x53), u8(0x48), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x4D), u8(0x41), u8(0x4E),
  u8(0x44), u8(0x20), u8(0x52), u8(0x20),
];

/// Field separator: demand page index. `' PAGE '` -- 6 bytes.
@rodata
final List<u8> shmStrDemandPage = const [
  u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x20),
];

// ---------------------------------------------------------------------------
// The storage seam. ADR-0011 §0: this symbol is named in exactly the four
// accessors below and nowhere else in `core/kernel/`, which `m21-shmem/run.sh`
// counts with a column-anchored grep.
// ---------------------------------------------------------------------------

/// The 4480 bytes this subsystem owns.
///
/// **It is the LAST block in `kmain.o`'s `.bss` and that is not a filing
/// preference.** Every earlier harness measures its own block's size as "bytes
/// from my symbol to the end of `.bss`", so a new block anywhere but the end
/// changes arithmetic in twelve run.sh files. Going last means exactly one
/// block's measurement changes -- S0's, which was last until now and
/// gains a subtraction step. ADR-0031 §4.3 rule 5 said the ioctl bounce buffer
/// must be last so that no earlier block moves; ADR-0033 §6.3(a) corrected that
/// wording ("last is necessary but not sufficient") after M20 and S0 each hit
/// this, and this block is the third instance of the corrected rule.
@bss
final Bss shmStore = const Bss(bytes: shmStoreBytes);

/// Base of the eight global counter words.
@bare
u64 shmMetaBase() {
  return Bss.addressOf(shmStore);
}

/// Base of region [r]'s 64-byte record.
@bare
u64 shmRegBase(u64 r) {
  return Bss.addressOf(shmStore) + u64(shmRegOffset) + (r * u64(shmRegBytes));
}

/// Base of the shared-frame bit-plane.
@bare
u64 shmPlaneBase() {
  return Bss.addressOf(shmStore) + u64(shmPlaneOffset);
}

/// The whole block, for [shmInit].
@bare
u64 shmStoreBase() {
  return Bss.addressOf(shmStore);
}

/// Zeroes the block. `.bss` is not zeroed by anything in this kernel, and this
/// prints nothing -- `m1-interrupts` asserts the entire 544-byte boot capture.
@bare
void shmInit() {
  final u64 base = shmStoreBase();
  u64 o = u64(0);
  while (o < u64(shmStoreBytes)) {
    Pointer<u64>.fromAddress(base + o).value = u64(0);
    o = o + u64(8);
  }
}

// ---------------------------------------------------------------------------
// Accessors. Read / write / bump, the shape `chan.dart` and `user.dart` use.
// ---------------------------------------------------------------------------

@bare
u64 shmMeta(u64 i) {
  return Pointer<u64>.fromAddress(shmMetaBase() + (i << u64(3))).value;
}

@bare
void shmSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(shmMetaBase() + (i << u64(3))).value = v;
}

@bare
void shmBumpMeta(u64 i) {
  shmSetMeta(i, shmMeta(i) + u64(1));
}

@bare
u64 shmReg(u64 r, u64 w) {
  return Pointer<u64>.fromAddress(shmRegBase(r) + (w << u64(3))).value;
}

@bare
void shmSetReg(u64 r, u64 w, u64 v) {
  Pointer<u64>.fromAddress(shmRegBase(r) + (w << u64(3))).value = v;
}

// ---------------------------------------------------------------------------
// The shared-frame bit-plane. `pmm.dart`'s bitmap idiom, verbatim.
// ---------------------------------------------------------------------------

/// 1 if the frame containing [addr] belongs to a live region.
///
/// **Called from `freeFrame` on every single free in the machine**, so it is
/// one shift, one load and one mask and nothing else. Takes a byte ADDRESS
/// rather than a frame number because its caller has one and because the caller
/// has already checked the alignment that makes the shift exact.
@bare
u64 shmFrameShared(u64 addr) {
  final u64 f = addr >> u64(vmPageShift);
  if (f >= u64(shmPlaneFrames)) {
    return u64(0);
  }
  final u8 b = Pointer<u8>.fromAddress(shmPlaneBase() + (f >> u64(3))).value;
  return (b.toU64() >> (f & u64(7))) & u64(1);
}

/// Marks the frame containing [addr] as owned by a live region.
@bare
void shmFrameMark(u64 addr) {
  final u64 f = addr >> u64(vmPageShift);
  if (f >= u64(shmPlaneFrames)) {
    return;
  }
  final u64 a = shmPlaneBase() + (f >> u64(3));
  final u8 old = Pointer<u8>.fromAddress(a).value;
  Pointer<u8>.fromAddress(a).value = old | (u64(1) << (f & u64(7))).toU8();
}

/// Unmarks it. **Always called BEFORE the matching [freeFrame]**, because the
/// mark is exactly what makes `freeFrame` refuse to free it.
@bare
void shmFrameUnmark(u64 addr) {
  final u64 f = addr >> u64(vmPageShift);
  if (f >= u64(shmPlaneFrames)) {
    return;
  }
  final u64 a = shmPlaneBase() + (f >> u64(3));
  final u8 old = Pointer<u8>.fromAddress(a).value;
  Pointer<u8>.fromAddress(a).value =
      old & (u64(0xFF) ^ (u64(1) << (f & u64(7)))).toU8();
}

// ---------------------------------------------------------------------------
// The frame vector.
// ---------------------------------------------------------------------------

/// Physical address of page [i] of the region whose vector page is at [vec].
@bare
u64 shmVec(u64 vec, u64 i) {
  return Pointer<u64>.fromAddress(vec + (i << u64(3))).value;
}

@bare
void shmSetVec(u64 vec, u64 i, u64 v) {
  Pointer<u64>.fromAddress(vec + (i << u64(3))).value = v;
}

@bare
u64 shmVecFileSize(u64 vec) {
  return Pointer<u64>.fromAddress(vec + u64(shmVecFileSizeOff)).value;
}

@bare
void shmSetVecFileSize(u64 vec, u64 sz) {
  Pointer<u64>.fromAddress(vec + u64(shmVecFileSizeOff)).value = sz;
}

/// Packed `(row << 8) | (fd + 1)`. Zero = no file.
@bare
u64 shmVecFilePack(u64 vec) {
  return Pointer<u64>.fromAddress(vec + u64(shmVecFilePackOff)).value;
}

@bare
void shmSetVecFilePack(u64 vec, u64 pack) {
  Pointer<u64>.fromAddress(vec + u64(shmVecFilePackOff)).value = pack;
}

// ---------------------------------------------------------------------------
// Geometry helpers.
// ---------------------------------------------------------------------------

/// Stable page offset allocated to region [r], packed above its map count.
@bare
u64 shmRegionBasePage(u64 r) {
  return shmReg(r, u64(shmRegMaps)) >> u64(shmBaseShift);
}

@bare
u64 shmRegionMaps(u64 r) {
  return shmReg(r, u64(shmRegMaps)) & u64(shmMapsMask);
}

@bare
void shmSetRegionMaps(u64 r, u64 maps) {
  shmSetReg(r, u64(shmRegMaps),
      (shmRegionBasePage(r) << u64(shmBaseShift)) |
          (maps & u64(shmMapsMask)));
}

/// The stable virtual address allocated to region [r].
@bare
u64 shmRegionVa(u64 r) {
  return u64(vmShmBase) + (shmRegionBasePage(r) * u64(vmPageBytes));
}

/// First-fit contiguous extent in the 512-page shared window.
@bare
u64 shmVaFind(u64 pages) {
  u64 at = u64(0);
  while ((at + pages) <= u64(vmShmPages)) {
    u64 moved = u64(0);
    u64 r = u64(0);
    while (r < u64(shmMax)) {
      if (shmReg(r, u64(shmRegState)) > u64(shmRegFree)) {
        final u64 lo = shmRegionBasePage(r);
        final u64 hi = lo + shmReg(r, u64(shmRegPages));
        if (at < hi) {
          if ((at + pages) > lo) {
            at = hi;
            moved = u64(1);
          }
        }
      }
      r = r + u64(1);
    }
    if (moved < u64(1)) {
      return at;
    }
  }
  return u64(vmShmPages);
}

@bare
u64 shmVaCanGrow(u64 region, u64 pages) {
  final u64 lo = shmRegionBasePage(region);
  final u64 hi = lo + pages;
  if (hi > u64(vmShmPages)) {
    return u64(0);
  }
  u64 r = u64(0);
  while (r < u64(shmMax)) {
    if (r != region) {
      if (shmReg(r, u64(shmRegState)) > u64(shmRegFree)) {
        final u64 otherLo = shmRegionBasePage(r);
        final u64 otherHi = otherLo + shmReg(r, u64(shmRegPages));
        if (lo < otherHi) {
          if (hi > otherLo) {
            return u64(0);
          }
        }
      }
    }
    r = r + u64(1);
  }
  return u64(1);
}

/// The calling process's id, or 0 if the caller is not a process.
/// [chanCallerId], for its reason: the one place "who is asking" is decided,
/// and it is decided from the scheduler's own state.
@bare
u64 shmCallerId() {
  if (procLive() < u64(1)) {
    return u64(0);
  }
  return procGet(procCurrent(), u64(procSlotId));
}

// ---------------------------------------------------------------------------
// Capabilities.
//
// One packed word per capability, in the PROCESS SLOT:
//
//   bits  0..3   region index + 1   (0 means the slot is empty)
//   bits  4..7   permissions        (shmPermRo or shmPermRw)
//   bit   8      mapped in this address space
//   bit   9      whole map (1) or partial/offset (0) — ADR-0160
//   bits 10..17  map offset in pages (partial only)
//   bits 18..25  map count in pages (partial only)
//   bits 32..63  the region's generation at the time the capability was made
//
// A ring-3 HANDLE is `(capIndex << 32) | generation` and carries no region
// index at all -- which is the point. See ADR-0041 §4.
// ---------------------------------------------------------------------------

@bare
u64 shmCap(u64 s, u64 i) {
  return procGet(s, u64(procSlotShmCaps) + i);
}

@bare
void shmSetCap(u64 s, u64 i, u64 v) {
  procSet(s, u64(procSlotShmCaps) + i, v);
}

/// The region a non-empty capability word names. **The caller must have tested
/// the word for emptiness first**; on an empty word this underflows the `- 1`,
/// which DCDart traps as a real `ud2`. Every call site below tests first, and
/// `m21-shmem/run.sh` reads them and requires it.
@bare
u64 shmCapReg(u64 c) {
  return (c & u64(15)) - u64(1);
}

@bare
u64 shmCapPerms(u64 c) {
  return (c >> u64(4)) & u64(15);
}

@bare
u64 shmCapMapped(u64 c) {
  return (c >> u64(8)) & u64(1);
}

@bare
u64 shmCapWhole(u64 c) {
  return (c >> u64(9)) & u64(1);
}

@bare
u64 shmCapOff(u64 c) {
  return (c >> u64(10)) & u64(255);
}

@bare
u64 shmCapCount(u64 c) {
  return (c >> u64(18)) & u64(255);
}

@bare
u64 shmCapGen(u64 c) {
  return c >> u64(32);
}

@bare
u64 shmCapPack(u64 reg, u64 perms, u64 mapped, u64 whole, u64 off, u64 count,
    u64 gen) {
  u64 w = (reg + u64(1)) & u64(15);
  w = w | ((perms & u64(15)) << u64(4));
  w = w | ((mapped & u64(1)) << u64(8));
  w = w | ((whole & u64(1)) << u64(9));
  w = w | ((off & u64(255)) << u64(10));
  w = w | ((count & u64(255)) << u64(18));
  return w | (gen << u64(32));
}

@bare
u64 shmHandle(u64 i, u64 gen) {
  return (i << u64(32)) | gen;
}

@bare
u64 shmHandleIndex(u64 h) {
  return h >> u64(32);
}

@bare
u64 shmHandleGen(u64 h) {
  return h & u64(0xFFFFFFFF);
}

/// The first empty capability index in slot [s], or [shmCapsPerProc].
@bare
u64 shmCapFree(u64 s) {
  u64 i = u64(0);
  while (i < u64(shmCapsPerProc)) {
    if ((shmCap(s, i) & u64(15)) < u64(1)) {
      return i;
    }
    i = i + u64(1);
  }
  return u64(shmCapsPerProc);
}

/// 1 if slot [s] already holds a capability for region [r].
@bare
u64 shmCapHolds(u64 s, u64 r) {
  u64 i = u64(0);
  while (i < u64(shmCapsPerProc)) {
    final u64 c = shmCap(s, i);
    if ((c & u64(15)) > u64(0)) {
      if (shmCapReg(c) == r) {
        return u64(1);
      }
    }
    i = i + u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Reporting. Every refusal goes through [shmRefuse], which is the only place
// this file writes a syscall return value on a failing path.
// ---------------------------------------------------------------------------

@bare
void shmRefuse(u64 frame, u64 no, u64 h, u64 code) {
  shmBumpMeta(u64(shmMetaRefusals));
  uartWrite(Rodata.addressOf(shmStrRefuse), u64(13));
  uartPutHex(no, u64(2));
  uartWrite(Rodata.addressOf(shmStrH), u64(3));
  uartPutHex(h, u64(16));
  uartWrite(Rodata.addressOf(shmStrR), u64(3));
  uartPutHex(code, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), code);
}

// ---------------------------------------------------------------------------
// The page table for the shared window, allocated lazily.
// ---------------------------------------------------------------------------

/// Makes sure the calling process has a page table for `[vmShmBase, vmShmEnd)`.
/// Returns 0 on success or a `shmRet*` refusal.
///
/// **Lazy, so a process that never touches shared memory is not charged a
/// frame.** `vmShmTableInstall`'s doc comment argues why that is safe here and
/// is not safe for the load window.
@bare
u64 shmEnsureTable(u64 s) {
  if (vmShmTable() > u64(0)) {
    return u64(0);
  }
  final u64 f = allocFrame();
  if (f < u64(1)) {
    return u64(shmRetNoMem);
  }
  // Zeroed HERE as well as inside `vmShmTableInstall`. The install zeroes it
  // because a page table full of allocator litter is 512 mappings the CPU will
  // believe; this line is what keeps `m7-frames`' "every allocFrame call site
  // names its frame to vmZeroFrame in the same file" check (ADR-0026) true
  // without adding a delegating exemption for one call site.
  vmZeroFrame(f);
  if (vmShmTableInstall(f) != u64(vmShmOk)) {
    final u64 back = freeFrame(f);
    if (back != u64(pmmFreeOk)) {
      // Nothing this function can do about it, and it is counted where every
      // other allocator error is: `pmmMetaErrors`, which `frames` prints.
      shmBumpMeta(u64(shmMetaRefusals));
    }
    return u64(shmRetNoTable);
  }
  procSet(s, u64(procSlotShmPt), f);
  return u64(0);
}

// ---------------------------------------------------------------------------
// Region creation and destruction.
// ---------------------------------------------------------------------------

/// The first free region slot, or [shmMax].
@bare
u64 shmRegionFree() {
  u64 r = u64(0);
  while (r < u64(shmMax)) {
    if (shmReg(r, u64(shmRegState)) == u64(shmRegFree)) {
      return r;
    }
    r = r + u64(1);
  }
  return u64(shmMax);
}

/// Gives back the first [n] frames of a half-built region and its vector page.
///
/// **Unmark before free, every time.** The mark is exactly what makes
/// `freeFrame` decline, so a rollback that freed first would silently retain
/// every frame it was trying to release.
@bare
void shmCreateRollback(u64 vec, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    final u64 pa = shmVec(vec, i);
    if (pa > u64(0)) {
      shmFrameUnmark(pa);
      final u64 b = freeFrame(pa);
      if (b != u64(pmmFreeOk)) {
        shmBumpMeta(u64(shmMetaRefusals));
      }
    }
    i = i + u64(1);
  }
  final u64 bv = freeFrame(vec);
  if (bv != u64(pmmFreeOk)) {
    shmBumpMeta(u64(shmMetaRefusals));
  }
}

/// Frees every frame region [r] owns and returns the record to [shmRegFree].
///
/// **The only place a region's frames go back to the allocator**, and it runs
/// when the LAST capability naming the region is released -- not when the last
/// mapping goes away. See ADR-0041 §5.
@bare
void shmRegionDestroy(u64 r) {
  final u64 vec = shmReg(r, u64(shmRegVec));
  final u64 pages = shmReg(r, u64(shmRegPages));
  u64 freed = u64(0);
  u64 i = u64(0);
  while (i < pages) {
    final u64 pa = shmVec(vec, i);
    if (pa > u64(0)) {
      shmFrameUnmark(pa);
      if (freeFrame(pa) == u64(pmmFreeOk)) {
        freed = freed + u64(1);
      }
    }
    i = i + u64(1);
  }
  if (vec > u64(0)) {
    if (freeFrame(vec) == u64(pmmFreeOk)) {
      freed = freed + u64(1);
    }
  }
  uartWrite(Rodata.addressOf(shmStrDead), u64(11));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrGen), u64(5));
  uartPutHex(shmReg(r, u64(shmRegGen)), u64(8));
  uartWrite(Rodata.addressOf(shmStrFreed), u64(7));
  uartPutHex(freed, u64(8));
  uartNewline();
  // The record is wiped AFTER the line is printed, so the report describes the
  // region that existed rather than the blank one that replaced it --
  // `chanPortWipe`'s ordering, and its reason.
  u64 w = u64(0);
  while (w < u64(shmRegWords)) {
    shmSetReg(r, w, u64(0));
    w = w + u64(1);
  }
  shmBumpMeta(u64(shmMetaDestroys));
  shmSetMeta(u64(shmMetaFreed), shmMeta(u64(shmMetaFreed)) + freed);
}

/// Maps pages [lo, hi) of region [r] into the LIVE address space at the
/// slot window, with [write] deciding W. Returns 0 or a refusal, and on a
/// refusal has unmapped everything it mapped in this call.
@bare
u64 shmMapPages(u64 r, u64 write, u64 lo, u64 hi) {
  final u64 vec = shmReg(r, u64(shmRegVec));
  final u64 va = shmRegionVa(r);
  u64 i = lo;
  while (i < hi) {
    final u64 pa = shmVec(vec, i);
    // ADR-0164: file-backed pages stay unmapped until first touch.
    if (pa > u64(0)) {
      if (vmShmMap(va + (i * u64(vmPageBytes)), pa, write) != u64(vmShmOk)) {
        u64 j = lo;
        while (j < i) {
          if (shmVec(vec, j) > u64(0)) {
            final u64 u = vmShmUnmap(va + (j * u64(vmPageBytes)));
            if (u != u64(vmShmOk)) {
              shmBumpMeta(u64(shmMetaRefusals));
            }
          }
          j = j + u64(1);
        }
        return u64(shmRetMapFail);
      }
    }
    i = i + u64(1);
  }
  return u64(0);
}

/// Changes W on pages [lo, hi) of region [r] in the LIVE address space.
/// Returns 0 or [shmRetMapFail].
@bare
u64 shmProtectPages(u64 r, u64 write, u64 lo, u64 hi) {
  final u64 va = shmRegionVa(r);
  u64 i = lo;
  while (i < hi) {
    if (vmShmProtect(va + (i * u64(vmPageBytes)), write) != u64(vmShmOk)) {
      return u64(shmRetMapFail);
    }
    i = i + u64(1);
  }
  return u64(0);
}

/// Prints one line per page of region [r] AS THE LIVE PAGE TABLES DESCRIBE IT.
///
/// **Read out of the tables through [vmEffective], never out of the arguments
/// the mapping was made with.** This is `elfPageReport`'s discipline and its
/// reason: a report derived from what the kernel MEANT to do cannot catch the
/// kernel doing something else. `vmEffective` walks from CR3 down, ANDing U and
/// W across all four levels and treating NX as a veto, so each line is the
/// permission the CPU will actually enforce for that address in the address
/// space that is loaded right now.
///
/// **The physical address is on the line, and that is what makes SHARING
/// checkable.** `m21-shmem` reads both processes' reports and requires the same
/// virtual address to carry the SAME physical frame in both -- a fact no
/// single-process bug can fabricate, and the exact inverse of `m11-proc`'s
/// isolation check, which requires every commonly-mapped address to be a
/// DIFFERENT frame. It also requires `X 0` on every line in both, which is
/// the W^X claim asserted against the live tables rather than against a source
/// comment.
@bare
void shmPageReport(u64 r) {
  final u64 pages = shmReg(r, u64(shmRegPages));
  final u64 va = shmRegionVa(r);
  u64 i = u64(0);
  while (i < pages) {
    final u64 a = va + (i * u64(vmPageBytes));
    final u64 e = vmEffective(a);
    uartWrite(Rodata.addressOf(shmStrPage), u64(9));
    uartPutHex(a, u64(16));
    uartWrite(Rodata.addressOf(shmStrP), u64(3));
    uartPutHex(e & u64(1), u64(1));
    uartWrite(Rodata.addressOf(shmStrU), u64(3));
    uartPutHex((e >> u64(1)) & u64(1), u64(1));
    uartWrite(Rodata.addressOf(shmStrW), u64(3));
    uartPutHex((e >> u64(2)) & u64(1), u64(1));
    uartWrite(Rodata.addressOf(shmStrX), u64(3));
    uartPutHex((e >> u64(3)) & u64(1), u64(1));
    uartWrite(Rodata.addressOf(shmStrPa), u64(4));
    uartPutHex(vmEntryAddr(vmShmLeaf(a)), u64(16));
    uartNewline();
    i = i + u64(1);
  }
}

/// Unmaps pages [lo, hi) of region [r] from the LIVE address space. Frees
/// nothing: the frames belong to the region. Empty leaves are success.
@bare
void shmUnmapPages(u64 r, u64 lo, u64 hi) {
  final u64 va = shmRegionVa(r);
  u64 i = lo;
  while (i < hi) {
    final u64 u = vmShmUnmap(va + (i * u64(vmPageBytes)));
    if (u != u64(vmShmOk)) {
      shmBumpMeta(u64(shmMetaRefusals));
    }
    i = i + u64(1);
  }
}

/// Low page index of capability [c]'s mapping window (0 when whole).
@bare
u64 shmCapLo(u64 c) {
  if (shmCapWhole(c) > u64(0)) {
    return u64(0);
  }
  return shmCapOff(c);
}

/// High page index (exclusive) of capability [c]'s mapping for a region
/// of [pages] pages. Whole maps track the live page count; partial maps
/// keep their create-time window (clamped to [pages] on shrink leftovers).
@bare
u64 shmCapHi(u64 c, u64 pages) {
  if (shmCapWhole(c) > u64(0)) {
    return pages;
  }
  final u64 hi = shmCapOff(c) + shmCapCount(c);
  if (hi > pages) {
    return pages;
  }
  return hi;
}

// ---------------------------------------------------------------------------
// Multi-mapper grow / shrink — edit every SHM page table that maps [r].
// ADR-0158. Tables are reached through [procSlotShmPt]; no CR3 switch.
// ---------------------------------------------------------------------------

/// 1 if slot [s] can hold a live SHM mapping (READY / RUNNING / BLOCKED).
@bare
u64 shmProcActive(u64 s) {
  final u64 st = procGet(s, u64(procSlotState));
  if (st == u64(procStateReady)) {
    return u64(1);
  }
  if (st == u64(procStateRunning)) {
    return u64(1);
  }
  if (st == u64(procStateBlocked)) {
    return u64(1);
  }
  return u64(0);
}

/// Address of the leaf entry for [va] inside SHM page-table frame [pt], or 0.
@bare
u64 shmPtLeaf(u64 pt, u64 va) {
  if (pt < u64(1)) {
    return u64(0);
  }
  if (va < u64(vmShmBase)) {
    return u64(0);
  }
  if (va >= u64(vmShmEnd)) {
    return u64(0);
  }
  return pt + (((va >> u64(vmPageShift)) & u64(511)) << u64(3));
}

/// Install one leaf in [pt]. [live] is 1 when [pt] is the loaded SHM table.
@bare
u64 shmPtMapOne(u64 pt, u64 va, u64 pa, u64 write, u64 live) {
  final u64 slot = shmPtLeaf(pt, va);
  if (slot < u64(1)) {
    return u64(shmRetMapFail);
  }
  final u64 old = Pointer<u64>.fromAddress(slot).value;
  if ((old & u64(vmPresent)) > u64(0)) {
    return u64(shmRetMapFail);
  }
  u64 bits = u64(vmPresent) | u64(vmUser) | vmNxBit();
  if (write > u64(0)) {
    bits = bits | u64(vmWritable);
  }
  Pointer<u64>.fromAddress(slot).value = pa | bits;
  if (live > u64(0)) {
    tlb_invlpg(va);
  }
  return u64(0);
}

/// Clear one leaf in [pt]. Empty is success (same contract as [vmShmUnmap]).
@bare
u64 shmPtUnmapOne(u64 pt, u64 va, u64 live) {
  final u64 slot = shmPtLeaf(pt, va);
  if (slot < u64(1)) {
    return u64(shmRetMapFail);
  }
  Pointer<u64>.fromAddress(slot).value = u64(0);
  if (live > u64(0)) {
    tlb_invlpg(va);
  }
  return u64(0);
}

/// Unmap pages [lo, hi) of region [r] from every address space that maps it.
/// Each capability only loses leaves inside its own window (ADR-0160).
@bare
void shmUnmapRangeAll(u64 r, u64 lo, u64 hi) {
  final u64 va0 = shmRegionVa(r);
  final u64 livePt = vmShmTable();
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (shmProcActive(s) > u64(0)) {
      u64 ci = u64(0);
      while (ci < u64(shmCapsPerProc)) {
        final u64 c = shmCap(s, ci);
        if ((c & u64(15)) > u64(0)) {
          if (shmCapReg(c) == r) {
            if (shmCapMapped(c) > u64(0)) {
              final u64 pt = procGet(s, u64(procSlotShmPt));
              if (pt > u64(0)) {
                u64 live = u64(0);
                if (pt == livePt) {
                  live = u64(1);
                }
                final u64 clo = shmCapLo(c);
                // Partial windows do not grow with the region; [hi] here is
                // the caller's range (shrink's freed span), so use that as
                // the whole-map ceiling for intersection.
                u64 chi = hi;
                if (shmCapWhole(c) < u64(1)) {
                  chi = shmCapOff(c) + shmCapCount(c);
                }
                u64 i = lo;
                while (i < hi) {
                  if (i >= clo) {
                    if (i < chi) {
                      final u64 u = shmPtUnmapOne(
                          pt, va0 + (i * u64(vmPageBytes)), live);
                      if (u > u64(0)) {
                        shmBumpMeta(u64(shmMetaRefusals));
                      }
                    }
                  }
                  i = i + u64(1);
                }
              }
            }
          }
        }
        ci = ci + u64(1);
      }
    }
    s = s + u64(1);
  }
}

/// Map pages [lo, hi) of region [r] into every address space that maps it.
/// Each capability keeps its own W bit (owner RW, grant RO) and only gains
/// leaves inside its window. On failure, rolls back every leaf this call
/// installed via [shmUnmapRangeAll].
@bare
u64 shmMapRangeAll(u64 r, u64 lo, u64 hi) {
  final u64 vec = shmReg(r, u64(shmRegVec));
  final u64 va0 = shmRegionVa(r);
  final u64 livePt = vmShmTable();
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (shmProcActive(s) > u64(0)) {
      u64 ci = u64(0);
      while (ci < u64(shmCapsPerProc)) {
        final u64 c = shmCap(s, ci);
        if ((c & u64(15)) > u64(0)) {
          if (shmCapReg(c) == r) {
            if (shmCapMapped(c) > u64(0)) {
              final u64 pt = procGet(s, u64(procSlotShmPt));
              if (pt < u64(1)) {
                shmUnmapRangeAll(r, lo, hi);
                return u64(shmRetNoTable);
              }
              u64 live = u64(0);
              if (pt == livePt) {
                live = u64(1);
              }
              u64 write = u64(0);
              if (shmCapPerms(c) == u64(shmPermRw)) {
                write = u64(1);
              }
              final u64 clo = shmCapLo(c);
              u64 chi = hi;
              if (shmCapWhole(c) < u64(1)) {
                chi = shmCapOff(c) + shmCapCount(c);
              }
              u64 i = lo;
              while (i < hi) {
                if (i >= clo) {
                  if (i < chi) {
                    final u64 pa = shmVec(vec, i);
                    if (pa > u64(0)) {
                      final u64 me = shmPtMapOne(
                          pt,
                          va0 + (i * u64(vmPageBytes)),
                          pa,
                          write,
                          live);
                      if (me > u64(0)) {
                        shmUnmapRangeAll(r, lo, hi);
                        return me;
                      }
                    }
                  }
                }
                i = i + u64(1);
              }
            }
          }
        }
        ci = ci + u64(1);
      }
    }
    s = s + u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Syscall 16 -- shmcreate(pages) -> handle
// ---------------------------------------------------------------------------

/// Creates a region of [pages] pages, maps it READ-WRITE into the caller, and
/// returns a capability handle for it.
///
/// **The creator is the region's only writer, for its whole life.** A grant
/// conveys [shmPermRo] and `shmSysMap` refuses to widen it, so a region has
/// exactly one writer by construction. That is most of why the absence of any
/// lock (§ADR-0041 §6) is survivable rather than merely undetected.
///
/// The check order below IS the security argument, top to bottom, and it is
/// `chanSysSend`'s discipline: who is asking, then the length, then resources,
/// then the mapping.
@bare
void shmSysCreate(u64 frame) {
  final u64 pages = userFrame(frame, u64(userFrameRdi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoProc));
    return;
  }
  // THE LENGTH IS BOUNDED BEFORE ANY ARITHMETIC USES IT. `pages` is a value
  // ring 3 chose and it is about to be multiplied by 4096; DCDart traps on
  // overflow with a real `ud2`, so an unbounded `pages` would let a ring-3
  // program choose which instruction the kernel executes next -- `elfOwns`'
  // hazard, in the one other shape it takes. GAP-0124's ordering rule.
  if (pages < u64(1)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetBadLen));
    return;
  }
  if (pages > u64(shmMaxPages)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetBadLen));
    return;
  }
  final u64 s = procCurrent();
  final u64 r = shmRegionFree();
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoSpace));
    return;
  }
  final u64 ci = shmCapFree(s);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoCap));
    return;
  }
  final u64 basePage = shmVaFind(pages);
  if ((basePage + pages) > u64(vmShmPages)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoSpace));
    return;
  }
  final u64 gen = shmMeta(u64(shmMetaGen)) + u64(1);
  if (gen > u64(0xFFFFFFFF)) {
    // A handle carries a 32-bit generation. Unreachable on any real boot --
    // it needs four billion creations -- and refused rather than allowed to
    // wrap into a value that would alias a live capability.
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoSpace));
    return;
  }
  final u64 te = shmEnsureTable(s);
  if (te > u64(0)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, te);
    return;
  }
  final u64 vec = allocFrame();
  if (vec < u64(1)) {
    shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoMem));
    return;
  }
  vmZeroFrame(vec);
  u64 i = u64(0);
  while (i < pages) {
    final u64 pa = allocFrame();
    if (pa < u64(1)) {
      shmCreateRollback(vec, i);
      shmRefuse(frame, u64(shmSysCreateNo), pages, u64(shmRetNoMem));
      return;
    }
    // ZEROED BEFORE IT IS MAPPED, NEVER AFTER. `heapSbrk`'s discipline and its
    // exact reason: between the mapping and the zeroing there is a window in
    // which the PREVIOUS OWNER'S BYTES are reachable from ring 3, and a shared
    // region is the one place two processes are looking.
    vmZeroFrame(pa);
    shmFrameMark(pa);
    shmSetVec(vec, i, pa);
    i = i + u64(1);
  }
  shmSetReg(r, u64(shmRegVec), vec);
  shmSetReg(r, u64(shmRegPages), pages);
  shmSetReg(r, u64(shmRegGen), gen);
  shmSetReg(r, u64(shmRegOwner), id);
  shmSetReg(r, u64(shmRegRefs), u64(1));
  shmSetReg(r, u64(shmRegMaps), basePage << u64(shmBaseShift));
  shmSetReg(r, u64(shmRegGrants), u64(0));
  shmSetReg(r, u64(shmRegState), u64(shmRegLive));
  final u64 me = shmMapPages(r, u64(1), u64(0), pages);
  if (me > u64(0)) {
    shmSetReg(r, u64(shmRegState), u64(shmRegFree));
    shmCreateRollback(vec, pages);
    shmRefuse(frame, u64(shmSysCreateNo), pages, me);
    return;
  }
  shmSetRegionMaps(r, u64(1));
  shmSetMeta(u64(shmMetaGen), gen);
  shmSetCap(s, ci, shmCapPack(r, u64(shmPermRw), u64(1), u64(1), u64(0), pages, gen));
  shmBumpMeta(u64(shmMetaCreates));
  uartWrite(Rodata.addressOf(shmStrCreate), u64(13));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrGen), u64(5));
  uartPutHex(gen, u64(8));
  uartWrite(Rodata.addressOf(shmStrPages), u64(7));
  uartPutHex(pages, u64(4));
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(shmRegionVa(r), u64(16));
  uartNewline();
  shmPageReport(r);
  userSetFrame(frame, u64(userFrameRax), shmHandle(ci, gen));
}

// ---------------------------------------------------------------------------
// Syscall 17 -- shmgrant(ep, handle) -> the GRANTEE's handle
// ---------------------------------------------------------------------------

/// Installs a READ-ONLY capability for the caller's region in the process on
/// the other side of channel endpoint [ep], and returns the handle THAT PROCESS
/// will use for it.
///
/// **This is the whole of "capability transfer", and it is a syscall rather
/// than a message on purpose.** The 64-byte channel message that follows
/// carries the returned NUMBER; the AUTHORITY was installed here, by the
/// kernel, in the peer's own slot. So ADR-0027 §3's "a message is bytes; it
/// cannot convey authority" survives intact: a program that forges the number
/// into a message reaches nothing, because the number is only meaningful
/// against a capability table entry the kernel wrote.
///
/// The peer is NAMED by the channel and not chosen by the caller -- there is no
/// "grant to process id N" -- so a process can only ever grant to somebody it
/// is already in a conversation with.
@bare
void shmSysGrant(u64 frame) {
  final u64 ep = userFrame(frame, u64(userFrameRdi));
  final u64 h = userFrame(frame, u64(userFrameRsi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetNoProc));
    return;
  }
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetBadCap));
    return;
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetStale));
    return;
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetStale));
    return;
  }
  if (shmReg(r, u64(shmRegGen)) != shmCapGen(c)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetStale));
    return;
  }
  // The peer, named by the channel. `chanPeerId` re-checks that THIS process
  // owns `ep` against the scheduler's own state, so a grant cannot be aimed
  // down a channel the caller is not party to.
  final u64 peer = chanPeerId(ep, id);
  if (peer >= u64(chanRetFloor)) {
    if (peer == u64(chanRetNoPeer)) {
      shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetNoPeer));
      return;
    }
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetBadEp));
    return;
  }
  final u64 ps = procSlotOfId(peer);
  if (ps >= u64(procMax)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetNoPeer));
    return;
  }
  if (shmCapHolds(ps, r) > u64(0)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetTwice));
    return;
  }
  final u64 pi = shmCapFree(ps);
  if (pi >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysGrantNo), h, u64(shmRetNoCap));
    return;
  }
  final u64 gen = shmReg(r, u64(shmRegGen));
  // READ-ONLY, ALWAYS. ADR-0027 §8 asked whether a region should be read-write
  // to one side and read-only to the other and answered "for a compositor it
  // should be"; this is that answer, and it is not a parameter. A grant that
  // could convey write access would make the number of writers a property of
  // the caller's argument rather than of the design, and every claim in
  // ADR-0041 §6 about there being one writer would become conditional.
  shmSetCap(ps, pi, shmCapPack(r, u64(shmPermRo), u64(0), u64(0), u64(0), u64(0), gen));
  shmSetReg(r, u64(shmRegRefs), shmReg(r, u64(shmRegRefs)) + u64(1));
  shmSetReg(r, u64(shmRegGrants), shmReg(r, u64(shmRegGrants)) + u64(1));
  shmBumpMeta(u64(shmMetaGrants));
  uartWrite(Rodata.addressOf(shmStrGrant), u64(12));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrTo), u64(4));
  uartPutHex(peer, u64(8));
  uartWrite(Rodata.addressOf(shmStrRefs), u64(6));
  uartPutHex(shmReg(r, u64(shmRegRefs)), u64(4));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), shmHandle(pi, gen));
}

// ---------------------------------------------------------------------------
// Syscall 18 -- shmmap(handle, perms, range) -> virtual address
//
// range (rdx) = (offset << 16) | count. count == 0 maps the whole region
// (ADR-0041 / every existing harness passes 0). count > 0 maps pages
// [offset, offset+count) only (ADR-0160). Out-of-range is shmRetBadLen.
// ---------------------------------------------------------------------------

/// Maps the region a capability names into the CALLING address space and
/// returns the virtual address of the first mapped page.
///
/// **Three refusals here are the milestone's negative controls and every one is
/// reachable from ring 3 as a return value:**
///
///   * [shmRetExec] -- the permission word asks for execute. W^X. Checked
///     BEFORE anything else about the permissions, so that "you may not have an
///     executable shared page" is never confused with "that is not a legal
///     permission word".
///   * [shmRetBadPerm] -- a READ-ONLY capability asking to be mapped writable.
///     Privilege escalation expressed as an argument, refused rather than
///     clamped, because a caller that asked for write and silently got read
///     would discover it by faulting later.
///   * [shmRetBadCap] -- a handle naming an empty slot in the caller's own
///     table. This is what a FORGED handle gets.
///   * [shmRetBadLen] -- offset/count outside the live region (ADR-0160).
@bare
void shmSysMap(u64 frame) {
  final u64 h = userFrame(frame, u64(userFrameRdi));
  final u64 rawPerms = userFrame(frame, u64(userFrameRsi));
  final u64 range = userFrame(frame, u64(userFrameRdx));
  final u64 wantVa = userFrame(frame, u64(userFrameRcx));
  u64 fixed = u64(0);
  if ((rawPerms & u64(shmMapFixed)) > u64(0)) {
    fixed = u64(1);
  }
  // Clear bit 8 without `~` (DCDart). 0x100 is shmMapFixed.
  final u64 perms = rawPerms & u64(0xFFFFFFFFFFFFFEFF);
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetNoProc));
    return;
  }
  // W^X FIRST. See the doc comment.
  if ((perms & u64(shmPermExec)) > u64(0)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetExec));
    return;
  }
  if (perms != u64(shmPermRo)) {
    if (perms != u64(shmPermRw)) {
      shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetBadPerm));
      return;
    }
  }
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetBadCap));
    return;
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetStale));
    return;
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetStale));
    return;
  }
  if (shmReg(r, u64(shmRegGen)) != shmCapGen(c)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetStale));
    return;
  }
  // A CAPABILITY CANNOT BE WIDENED BY THE ARGUMENT THAT USES IT.
  if (perms == u64(shmPermRw)) {
    if (shmCapPerms(c) != u64(shmPermRw)) {
      shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetBadPerm));
      return;
    }
  }
  final u64 pages = shmReg(r, u64(shmRegPages));
  final u64 off = range >> u64(16);
  final u64 count = range & u64(0xFFFF);
  u64 lo = u64(0);
  u64 hi = pages;
  u64 whole = u64(1);
  if (count > u64(0)) {
    whole = u64(0);
    if (off >= pages) {
      shmRefuse(frame, u64(shmSysMapNo), range, u64(shmRetBadLen));
      return;
    }
    if (count > (pages - off)) {
      shmRefuse(frame, u64(shmSysMapNo), range, u64(shmRetBadLen));
      return;
    }
    lo = off;
    hi = off + count;
  } else {
    if (off > u64(0)) {
      shmRefuse(frame, u64(shmSysMapNo), range, u64(shmRetBadLen));
      return;
    }
  }
  final u64 expectVa = shmRegionVa(r) + (lo * u64(vmPageBytes));
  // MAP_FIXED before the mapped check so a wrong address is BadFixed even
  // when the capability is already mapped (anti-vacuity for the flag).
  if (fixed > u64(0)) {
    if (wantVa != expectVa) {
      shmRefuse(frame, u64(shmSysMapNo), wantVa, u64(shmRetBadFixed));
      return;
    }
  }
  if (shmCapMapped(c) > u64(0)) {
    shmRefuse(frame, u64(shmSysMapNo), h, u64(shmRetMapped));
    return;
  }
  final u64 te = shmEnsureTable(s);
  if (te > u64(0)) {
    shmRefuse(frame, u64(shmSysMapNo), h, te);
    return;
  }
  u64 write = u64(0);
  if (perms == u64(shmPermRw)) {
    write = u64(1);
  }
  final u64 me = shmMapPages(r, write, lo, hi);
  if (me > u64(0)) {
    shmRefuse(frame, u64(shmSysMapNo), h, me);
    return;
  }
  u64 packCount = count;
  if (whole > u64(0)) {
    packCount = pages;
  }
  shmSetCap(
      s,
      ci,
      shmCapPack(r, shmCapPerms(c), u64(1), whole, lo, packCount, shmCapGen(c)));
  shmSetRegionMaps(r, shmRegionMaps(r) + u64(1));
  shmBumpMeta(u64(shmMetaMaps));
  final u64 va = expectVa;
  uartWrite(Rodata.addressOf(shmStrMap), u64(10));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrPerm), u64(6));
  uartPutHex(perms, u64(1));
  if (whole < u64(1)) {
    uartWrite(Rodata.addressOf(shmStrOff), u64(5));
    uartPutHex(lo, u64(4));
    uartWrite(Rodata.addressOf(shmStrCount), u64(7));
    uartPutHex(hi - lo, u64(4));
  }
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartWrite(Rodata.addressOf(shmStrMaps), u64(6));
  uartPutHex(shmRegionMaps(r), u64(4));
  uartNewline();
  shmPageReport(r);
  userSetFrame(frame, u64(userFrameRax), va);
}

// ---------------------------------------------------------------------------
// Syscall 19 -- shmdrop(handle) -> 0
// ---------------------------------------------------------------------------

/// Releases the CALLER'S OWN capability: unmaps the region here if it was
/// mapped, and destroys the region if this was the last capability naming it.
///
/// **This is the whole of revocation, and it only ever points at the caller.**
/// A grantor cannot take a capability back from a grantee. GAP-0233 records
/// what involuntary revocation would take and why M21 does not have it.
@bare
void shmSysDrop(u64 frame) {
  final u64 h = userFrame(frame, u64(userFrameRdi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysDropNo), h, u64(shmRetNoProc));
    return;
  }
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysDropNo), h, u64(shmRetBadCap));
    return;
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    shmRefuse(frame, u64(shmSysDropNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    shmRefuse(frame, u64(shmSysDropNo), h, u64(shmRetStale));
    return;
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysDropNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    shmRefuse(frame, u64(shmSysDropNo), h, u64(shmRetStale));
    return;
  }
  if (shmCapMapped(c) > u64(0)) {
    final u64 pages = shmReg(r, u64(shmRegPages));
    shmUnmapPages(r, shmCapLo(c), shmCapHi(c, pages));
    shmSetRegionMaps(r, shmRegionMaps(r) - u64(1));
  }
  shmSetCap(s, ci, u64(0));
  final u64 refs = shmReg(r, u64(shmRegRefs)) - u64(1);
  shmSetReg(r, u64(shmRegRefs), refs);
  shmBumpMeta(u64(shmMetaDrops));
  uartWrite(Rodata.addressOf(shmStrDrop), u64(11));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrRefs), u64(6));
  uartPutHex(refs, u64(4));
  uartWrite(Rodata.addressOf(shmStrMaps), u64(6));
  uartPutHex(shmRegionMaps(r), u64(4));
  uartNewline();
  if (refs < u64(1)) {
    shmRegionDestroy(r);
  }
  userSetFrame(frame, u64(userFrameRax), u64(0));
}

// ---------------------------------------------------------------------------
// Syscall 34 -- shmgrow(handle, newPages) -> 0
// ---------------------------------------------------------------------------

/// Extends a live region in place up to [shmMaxPages]. Same VA base
/// (slot-sized window). Maps the new pages into EVERY address space that
/// currently maps the region (owner RW, grant RO). ADR-0150 + ADR-0158.
@bare
void shmSysGrow(u64 frame) {
  final u64 h = userFrame(frame, u64(userFrameRdi));
  final u64 want = userFrame(frame, u64(userFrameRsi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetNoProc));
    return;
  }
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetBadCap));
    return;
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetStale));
    return;
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetStale));
    return;
  }
  if (shmReg(r, u64(shmRegGen)) != shmCapGen(c)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetStale));
    return;
  }
  // Owner only: a RO grant must not grow the writer's region.
  if (shmCapPerms(c) != u64(shmPermRw)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetBadPerm));
    return;
  }
  final u64 old = shmReg(r, u64(shmRegPages));
  if (want <= old) {
    shmRefuse(frame, u64(shmSysGrowNo), want, u64(shmRetBadLen));
    return;
  }
  if (want > u64(shmMaxPages)) {
    shmRefuse(frame, u64(shmSysGrowNo), want, u64(shmRetBadLen));
    return;
  }
  if (shmVaCanGrow(r, want) < u64(1)) {
    shmRefuse(frame, u64(shmSysGrowNo), want, u64(shmRetNoSpace));
    return;
  }
  // Caller must already have this region mapped. Other mappers are
  // updated in place via [shmMapRangeAll] (ADR-0158).
  if (shmCapMapped(c) < u64(1)) {
    shmRefuse(frame, u64(shmSysGrowNo), h, u64(shmRetMapped));
    return;
  }
  final u64 vec = shmReg(r, u64(shmRegVec));
  u64 i = old;
  while (i < want) {
    final u64 pa = allocFrame();
    if (pa < u64(1)) {
      u64 j = old;
      while (j < i) {
        final u64 p = shmVec(vec, j);
        if (p > u64(0)) {
          shmFrameUnmark(p);
          final u64 b = freeFrame(p);
          if (b != u64(pmmFreeOk)) {
            shmBumpMeta(u64(shmMetaRefusals));
          }
          shmSetVec(vec, j, u64(0));
        }
        j = j + u64(1);
      }
      shmRefuse(frame, u64(shmSysGrowNo), want, u64(shmRetNoMem));
      return;
    }
    vmZeroFrame(pa);
    shmFrameMark(pa);
    shmSetVec(vec, i, pa);
    i = i + u64(1);
  }
  final u64 va = shmRegionVa(r);
  final u64 me = shmMapRangeAll(r, old, want);
  if (me > u64(0)) {
    u64 k = old;
    while (k < want) {
      final u64 p = shmVec(vec, k);
      if (p > u64(0)) {
        shmFrameUnmark(p);
        final u64 b = freeFrame(p);
        if (b != u64(pmmFreeOk)) {
          shmBumpMeta(u64(shmMetaRefusals));
        }
        shmSetVec(vec, k, u64(0));
      }
      k = k + u64(1);
    }
    shmRefuse(frame, u64(shmSysGrowNo), want, me);
    return;
  }
  shmSetReg(r, u64(shmRegPages), want);
  uartWrite(Rodata.addressOf(shmStrGrow), u64(11));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrPages), u64(7));
  uartPutHex(want, u64(4));
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartWrite(Rodata.addressOf(shmStrMaps), u64(6));
  uartPutHex(shmRegionMaps(r), u64(4));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), u64(0));
}

// ---------------------------------------------------------------------------
// Syscall 35 -- shmshrink(handle, newPages) -> 0
// ---------------------------------------------------------------------------

/// Truncates a live region in place down to [want] pages (at least 1).
/// Unmaps the trailing pages from EVERY address space that maps the region
/// and returns their frames to the allocator. ADR-0156 + ADR-0158.
@bare
void shmSysShrink(u64 frame) {
  final u64 h = userFrame(frame, u64(userFrameRdi));
  final u64 want = userFrame(frame, u64(userFrameRsi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetNoProc));
    return;
  }
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetBadCap));
    return;
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetStale));
    return;
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetStale));
    return;
  }
  if (shmReg(r, u64(shmRegGen)) != shmCapGen(c)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetStale));
    return;
  }
  if (shmCapPerms(c) != u64(shmPermRw)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetBadPerm));
    return;
  }
  final u64 old = shmReg(r, u64(shmRegPages));
  if (want < u64(1)) {
    shmRefuse(frame, u64(shmSysShrinkNo), want, u64(shmRetBadLen));
    return;
  }
  if (want >= old) {
    shmRefuse(frame, u64(shmSysShrinkNo), want, u64(shmRetBadLen));
    return;
  }
  if (shmCapMapped(c) < u64(1)) {
    shmRefuse(frame, u64(shmSysShrinkNo), h, u64(shmRetMapped));
    return;
  }
  final u64 va = shmRegionVa(r);
  final u64 vec = shmReg(r, u64(shmRegVec));
  shmUnmapRangeAll(r, want, old);
  u64 freed = u64(0);
  u64 i = want;
  while (i < old) {
    final u64 pa = shmVec(vec, i);
    if (pa > u64(0)) {
      shmFrameUnmark(pa);
      if (freeFrame(pa) == u64(pmmFreeOk)) {
        freed = freed + u64(1);
      } else {
        shmBumpMeta(u64(shmMetaRefusals));
      }
      shmSetVec(vec, i, u64(0));
    }
    i = i + u64(1);
  }
  shmSetReg(r, u64(shmRegPages), want);
  if (freed > u64(0)) {
    shmSetMeta(u64(shmMetaFreed), shmMeta(u64(shmMetaFreed)) + freed);
  }
  uartWrite(Rodata.addressOf(shmStrShrink), u64(13));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrPages), u64(7));
  uartPutHex(want, u64(4));
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartWrite(Rodata.addressOf(shmStrMaps), u64(6));
  uartPutHex(shmRegionMaps(r), u64(4));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), u64(0));
}

// ---------------------------------------------------------------------------
// Syscall 36 -- mprotect(handle, perms) -> 0
//
// Changes W on the caller's already-mapped window. Downgrade RW→RO is the
// compositor door (GAP-0235). Escalate past the capability, or EXEC, refuses.
// ---------------------------------------------------------------------------

/// Changes live mapping permissions for capability [h]'s window.
@bare
void shmSysMprotect(u64 frame) {
  final u64 h = userFrame(frame, u64(userFrameRdi));
  final u64 perms = userFrame(frame, u64(userFrameRsi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetNoProc));
    return;
  }
  if ((perms & u64(shmPermExec)) > u64(0)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetExec));
    return;
  }
  if (perms != u64(shmPermRo)) {
    if (perms != u64(shmPermRw)) {
      shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetBadPerm));
      return;
    }
  }
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetBadCap));
    return;
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetStale));
    return;
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetBadCap));
    return;
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetStale));
    return;
  }
  if (shmReg(r, u64(shmRegGen)) != shmCapGen(c)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetStale));
    return;
  }
  if (shmCapMapped(c) < u64(1)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetMapped));
    return;
  }
  // Cannot escalate past what the capability currently carries.
  if (perms == u64(shmPermRw)) {
    if (shmCapPerms(c) != u64(shmPermRw)) {
      shmRefuse(frame, u64(shmSysMprotectNo), h, u64(shmRetBadPerm));
      return;
    }
  }
  final u64 pages = shmReg(r, u64(shmRegPages));
  final u64 lo = shmCapLo(c);
  final u64 hi = shmCapHi(c, pages);
  u64 write = u64(0);
  if (perms == u64(shmPermRw)) {
    write = u64(1);
  }
  final u64 pe = shmProtectPages(r, write, lo, hi);
  if (pe > u64(0)) {
    shmRefuse(frame, u64(shmSysMprotectNo), h, pe);
    return;
  }
  shmSetCap(
      s,
      ci,
      shmCapPack(r, perms, u64(1), shmCapWhole(c), shmCapOff(c),
          shmCapCount(c), shmCapGen(c)));
  uartWrite(Rodata.addressOf(shmStrProt), u64(11));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrPerm), u64(6));
  uartPutHex(perms, u64(1));
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(shmRegionVa(r) + (lo * u64(vmPageBytes)), u64(16));
  uartNewline();
  shmPageReport(r);
  userSetFrame(frame, u64(userFrameRax), u64(0));
}

// ---------------------------------------------------------------------------
// Syscall 37 -- shmfile(fd) -> handle
//
// Creates a RO region sized to the open FAT file. Pages are NOT allocated or
// mapped present at create time; the first #PF NOTPRES in the window fills
// from the file (ADR-0164 / GAP-0235).
// ---------------------------------------------------------------------------

/// Copies one page of the open file described by [pack] into physical [pa].
/// Zeroes the frame first. Short last page leaves the tail zero.
@bare
u64 shmFileFillPage(u64 pack, u64 page, u64 pa, u64 fileSize) {
  final u64 row = pack >> u64(8);
  final u64 fd = (pack & u64(0xFF)) - u64(1);
  if (row >= u64(fileRows)) {
    return u64(1);
  }
  if (fd >= u64(fileMaxFds)) {
    return u64(1);
  }
  if (fileFd(row, fd, u64(fileFdState)) != u64(fileFdOpen)) {
    return u64(1);
  }
  vmZeroFrame(pa);
  final u64 off0 = page * u64(vmPageBytes);
  if (off0 >= fileSize) {
    return u64(0);
  }
  u64 want = u64(vmPageBytes);
  if ((fileSize - off0) < want) {
    want = fileSize - off0;
  }
  final u64 cs = fileChainFor(row, fd);
  if (cs > u64(fatErrOk)) {
    return u64(1);
  }
  u64 done = u64(0);
  while (done < want) {
    final u64 off = off0 + done;
    final u64 inSec = off & u64(511);
    u64 n = u64(fatSectorBytes) - inSec;
    if (n > (want - done)) {
      n = want - done;
    }
    final u64 lba = fatFileSector(off >> u64(fatSectorShift));
    if (lba < u64(1)) {
      return u64(1);
    }
    if (fatReadSector(lba, fileBufBase()) > u64(0)) {
      return u64(1);
    }
    u64 k = u64(0);
    while (k < n) {
      Pointer<u8>.fromAddress(pa + done + k).value =
          Pointer<u8>.fromAddress(fileBufBase() + inSec + k).value;
      k = k + u64(1);
    }
    done = done + n;
  }
  return u64(0);
}

/// First-touch fill for a file-backed shm page. Returns 1 when the fault
/// was handled and the interrupted instruction should be retried; 0 to
/// fall through to the ordinary kill path.
@bare
u64 shmDemandTry(u64 errorCode) {
  if ((errorCode & u64(vmPfPresent)) > u64(0)) {
    return u64(0);
  }
  if ((errorCode & u64(vmPfUser)) < u64(1)) {
    return u64(0);
  }
  if (procLive() < u64(1)) {
    return u64(0);
  }
  final u64 cr2 = cr2_read();
  if (cr2 < u64(vmShmBase)) {
    return u64(0);
  }
  if (cr2 >= u64(vmShmEnd)) {
    return u64(0);
  }
  final u64 r =
      (cr2 - u64(vmShmBase)) ~/ (u64(shmSlotPages) * u64(vmPageBytes));
  if (r >= u64(shmMax)) {
    return u64(0);
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLiveFile)) {
    return u64(0);
  }
  final u64 pages = shmReg(r, u64(shmRegPages));
  final u64 va0 = shmRegionVa(r);
  final u64 page = (cr2 - va0) >> u64(vmPageShift);
  if (page >= pages) {
    return u64(0);
  }
  final u64 vec = shmReg(r, u64(shmRegVec));
  final u64 pack = shmVecFilePack(vec);
  if (pack < u64(1)) {
    return u64(0);
  }
  u64 pa = shmVec(vec, page);
  if (pa < u64(1)) {
    pa = allocFrame();
    if (pa < u64(1)) {
      return u64(0);
    }
    final u64 fe =
        shmFileFillPage(pack, page, pa, shmVecFileSize(vec));
    if (fe > u64(0)) {
      final u64 b = freeFrame(pa);
      if (b != u64(pmmFreeOk)) {
        shmBumpMeta(u64(shmMetaRefusals));
      }
      return u64(0);
    }
    shmFrameMark(pa);
    shmSetVec(vec, page, pa);
  }
  final u64 s = procCurrent();
  final u64 pt = procGet(s, u64(procSlotShmPt));
  if (pt < u64(1)) {
    return u64(0);
  }
  final u64 va = va0 + (page * u64(vmPageBytes));
  final u64 slot = shmPtLeaf(pt, va);
  if (slot < u64(1)) {
    return u64(0);
  }
  final u64 old = Pointer<u64>.fromAddress(slot).value;
  if ((old & u64(vmPresent)) < u64(1)) {
    final u64 livePt = vmShmTable();
    u64 live = u64(0);
    if (pt == livePt) {
      live = u64(1);
    }
    final u64 me = shmPtMapOne(pt, va, pa, u64(0), live);
    if (me > u64(0)) {
      return u64(0);
    }
  }
  vmSetMeta(u64(vmMetaCr2), cr2);
  vmSetMeta(u64(vmMetaErr), errorCode);
  uartWrite(Rodata.addressOf(shmStrDemand), u64(13));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrDemandPage), u64(6));
  uartPutHex(page, u64(4));
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartNewline();
  return u64(1);
}

/// `shmfile(fd) -> handle`. RO capability; leaves stay not-present until
/// [shmDemandTry] fills them from the FAT file.
@bare
void shmSysFile(u64 frame) {
  final u64 fd = userFrame(frame, u64(userFrameRdi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetNoProc));
    return;
  }
  final u64 row = fileOwnerRow();
  if (row >= u64(fileRows)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetNoProc));
    return;
  }
  if (fd >= u64(fileMaxFds)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetBadCap));
    return;
  }
  if (fileFd(row, fd, u64(fileFdState)) != u64(fileFdOpen)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetBadCap));
    return;
  }
  final u64 fileSize = fileFd(row, fd, u64(fileFdSize));
  if (fileSize < u64(1)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetBadLen));
    return;
  }
  u64 pages = (fileSize + u64(vmPageBytes) - u64(1)) >> u64(vmPageShift);
  if (pages < u64(1)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetBadLen));
    return;
  }
  if (pages > u64(shmMaxPages)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetBadLen));
    return;
  }
  final u64 s = procCurrent();
  final u64 r = shmRegionFree();
  if (r >= u64(shmMax)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetNoSpace));
    return;
  }
  final u64 ci = shmCapFree(s);
  if (ci >= u64(shmCapsPerProc)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetNoCap));
    return;
  }
  final u64 basePage = shmVaFind(pages);
  if ((basePage + pages) > u64(vmShmPages)) {
    shmRefuse(frame, u64(shmSysFileNo), pages, u64(shmRetNoSpace));
    return;
  }
  final u64 gen = shmMeta(u64(shmMetaGen)) + u64(1);
  if (gen > u64(0xFFFFFFFF)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetNoSpace));
    return;
  }
  final u64 te = shmEnsureTable(s);
  if (te > u64(0)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, te);
    return;
  }
  final u64 vec = allocFrame();
  if (vec < u64(1)) {
    shmRefuse(frame, u64(shmSysFileNo), fd, u64(shmRetNoMem));
    return;
  }
  vmZeroFrame(vec);
  shmSetVecFileSize(vec, fileSize);
  shmSetVecFilePack(vec, (row << u64(8)) | (fd + u64(1)));
  shmSetReg(r, u64(shmRegVec), vec);
  shmSetReg(r, u64(shmRegPages), pages);
  shmSetReg(r, u64(shmRegGen), gen);
  shmSetReg(r, u64(shmRegOwner), id);
  shmSetReg(r, u64(shmRegRefs), u64(1));
  shmSetReg(r, u64(shmRegMaps),
      (basePage << u64(shmBaseShift)) | u64(1));
  shmSetReg(r, u64(shmRegGrants), u64(0));
  shmSetReg(r, u64(shmRegState), u64(shmRegLiveFile));
  shmSetMeta(u64(shmMetaGen), gen);
  shmSetCap(s, ci,
      shmCapPack(r, u64(shmPermRo), u64(1), u64(1), u64(0), pages, gen));
  shmBumpMeta(u64(shmMetaCreates));
  uartWrite(Rodata.addressOf(shmStrFile), u64(11));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(shmStrGen), u64(5));
  uartPutHex(gen, u64(8));
  uartWrite(Rodata.addressOf(shmStrPages), u64(7));
  uartPutHex(pages, u64(4));
  uartWrite(Rodata.addressOf(shmStrSize), u64(6));
  uartPutHex(fileSize, u64(8));
  uartWrite(Rodata.addressOf(shmStrVa), u64(4));
  uartPutHex(shmRegionVa(r), u64(16));
  uartNewline();
  shmPageReport(r);
  userSetFrame(frame, u64(userFrameRax), shmHandle(ci, gen));
}

// ---------------------------------------------------------------------------
// Release on exit -- the one call site, in `procCleanup`.
// ---------------------------------------------------------------------------

/// Releases every capability slot [s] holds. Called from `procCleanup` and
/// NOWHERE ELSE, which `m21-shmem/run.sh` asserts by counting call sites.
///
/// **`procCleanup` is the function both the exit path and the fault/kill path
/// go through**, so a process that dies mid-write releases its capability
/// exactly as one that exits politely does. That is M15's descriptor-release
/// finding and M20's endpoint-release finding applied to a third kind of
/// resource, and it is what stops a killed process from pinning a region's
/// frames for the rest of the boot.
///
/// (Those two are named by what they do rather than by their symbols on
/// purpose: `m15-fileio` and `m20-ipc` each grep `core/kernel/` for their own
/// release function and require it to appear in exactly two files, which is
/// ADR-0011 s0's seam discipline made mechanical. A doc comment that spells the
/// symbol fails somebody else's harness -- and it did, once, before this
/// parenthesis existed.)
///
/// **It does not unmap anything**, because `procSpaceFree` has already run and
/// this slot's page tables are gone. It decrements what those mappings stood
/// for and destroys the region if this was its last capability.
@bare
void shmReleaseOwner(u64 s) {
  u64 i = u64(0);
  while (i < u64(shmCapsPerProc)) {
    final u64 c = shmCap(s, i);
    if ((c & u64(15)) > u64(0)) {
      final u64 r = shmCapReg(c);
      if (r < u64(shmMax)) {
        if (shmReg(r, u64(shmRegState)) == u64(shmRegLive)) {
          if (shmCapMapped(c) > u64(0)) {
            final u64 m = shmRegionMaps(r);
            if (m > u64(0)) {
              shmSetRegionMaps(r, m - u64(1));
            }
          }
          final u64 refs = shmReg(r, u64(shmRegRefs));
          if (refs > u64(0)) {
            shmSetReg(r, u64(shmRegRefs), refs - u64(1));
          }
          uartWrite(Rodata.addressOf(shmStrDrop), u64(11));
          uartPutHex(r, u64(1));
          uartWrite(Rodata.addressOf(shmStrRefs), u64(6));
          uartPutHex(shmReg(r, u64(shmRegRefs)), u64(4));
          uartWrite(Rodata.addressOf(shmStrMaps), u64(6));
          uartPutHex(shmRegionMaps(r), u64(4));
          uartNewline();
          if (shmReg(r, u64(shmRegRefs)) < u64(1)) {
            shmRegionDestroy(r);
          }
        }
      }
      shmSetCap(s, i, u64(0));
    }
    i = i + u64(1);
  }
}
