// core/kernel/chan.dart
//
// oscortex_core M20: THE FIRST IPC PRIMITIVE. Two ring-3 processes, in two
// different address spaces, exchange a message through the kernel, and neither
// one can name a byte of the other's memory.
//
// The architecture is docs/decisions/0027-the-first-ipc-primitive.md; the binary
// exit criterion is tests/conformance/m20-ipc/run.sh.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS IS, IN ONE PARAGRAPH
// ---------------------------------------------------------------------------
// A CHANNEL is a kernel object with exactly TWO endpoints and TWO independent
// rings, one per direction. Each ring holds up to [chanRingDepth] messages of at
// most [chanMsgBytes] bytes. `chansend` copies the caller's bytes INTO the ring
// and never blocks: a full ring is [chanRetFull], a refusal the sender sees.
// `chanrecv` copies bytes OUT of the ring and never blocks: an empty ring is
// [chanRetEmpty], a status the receiver sees. There is no rendezvous, no wait
// queue and no wakeup, so this milestone adds NO new scheduler state at all.
//
// ---------------------------------------------------------------------------
// WHAT IT DELIBERATELY IS NOT -- AND WHY THE 64-BYTE CAP IS THE DESIGN
// ---------------------------------------------------------------------------
// The client this exists for is a compositor, and a compositor moves two things
// with opposite requirements: SMALL INPUT EVENTS, which need ordering and
// guaranteed delivery, and LARGE PIXEL BUFFERS, which need neither and must
// never be copied. At 800x600x32 a frame is 1,920,000 bytes. This kernel's
// ENTIRE mutable static budget is 16,992 bytes with this file in it. A message
// channel that could carry a frame would have to copy 1.92 MB through the
// kernel twice per frame, at 60 Hz -- 230 MB/s of byte stores in a loop with
// interrupts disabled.
//
// So [chanMsgBytes] is 64 and it is a HARD BOUND CHECKED IN THE KERNEL, not a
// default. This primitive CANNOT be quietly widened into a frame transport,
// which is exactly the point: the frame path is forced to be what it has to be
// anyway, a shared region NAMED BY a message rather than carried IN one. A
// 64-byte message holds a region handle, an offset, a length, a width, a height,
// a stride, a sequence number and a damage rectangle with room to spare -- and
// because the kernel treats a message as OPAQUE BYTES, adding that descriptor in
// a later milestone costs this file nothing at all.
//
// Also not here, each with a gap number:
//
//   * NO RENDEZVOUS. L4/seL4-style synchronous IPC makes the compositor's
//     liveness depend on every client's: a `send` that blocks until the peer
//     receives lets one wedged client stop the display server. ADR-0027 section 2.
//   * NO BLOCKING RECEIVE. A receiver polls. GAP-0260.
//   * NO CAPABILITY OR HANDLE TRANSFER. A message is bytes; it cannot convey
//     authority. GAP-0261.
//   * NO NAMING. A port is a small integer both peers agree on by convention.
//     GAP-0262.
//   * NO MULTICAST. Exactly two endpoints. A compositor with N clients uses N
//     channels. GAP-0263.
//   * NOT A BYTE STREAM. Messages are discrete: never coalesced, never split.
//   * NOT AVAILABLE TO AN M9 PAYLOAD OR AN M10 `run` PROGRAM. An endpoint is
//     owned by a PROCESS ID, and neither of those two things has a process slot.
//     GAP-0264.
//
// ---------------------------------------------------------------------------
// THE ONE PLACE CORRECTNESS DEPENDS ON BEING SINGLE-CORE
// ---------------------------------------------------------------------------
// DCDart's mutable statics have no atomicity and no memory barriers (DCDart
// GAP-0039 and GAP-0033), so every read-modify-write below is a plain load, an
// add and a plain store. On this machine that is safe for a reason that has
// nothing to do with luck: every one of these functions runs inside a syscall
// entered through an INTERRUPT gate, so IF is clear, and there is one CPU. The
// whole of [chanSysSend] is a critical section by construction rather than by a
// lock.
//
// What is done so that the CORRECTNESS does not SILENTLY depend on that:
//
//   1. SINGLE PRODUCER, SINGLE CONSUMER, PER DIRECTION. [chanPortHead0] is
//      written only by side 0 and [chanPortTail0] only by side 1; direction 1 is
//      the mirror. No word in a ring has two writers. That is the one queue
//      discipline that is already correct with plain loads and stores, so on the
//      day this kernel has two cores the fix is two fences, not a redesign. A
//      shared "count" word, or a second producer, would have made it a rewrite.
//   2. THE COUNTERS ARE FREE-RUNNING, NOT MODULAR. Depth is `head - tail` and
//      the slot index is `counter & chanRingMask`. A STALE tail makes the
//      producer believe the ring is fuller than it is; a STALE head makes the
//      consumer believe it is emptier. Both errors are in the safe direction, so
//      a reordered pair of loads costs a delayed message and never a lost or a
//      duplicated one.
//   3. THE PUBLICATION ORDER IS WRITTEN DOWN AND OBEYED. The producer fills the
//      slot and its length word BEFORE advancing head; the consumer copies the
//      slot out BEFORE advancing tail. Both places are marked in the code as
//      where a release fence goes.
//   4. THE COUNTERS THAT ARE NOT SAFE ARE NOT LOAD-BEARING. [chanPortSends],
//      [chanMetaBytes] and the rest are STATISTICS. Nothing decides anything
//      from them; they are printed.
//
// **Stated plainly, so nobody has to infer it:** the single thing this file
// relies on that an SMP kernel would not give it is that no fence instruction is
// emitted. Everything else is already SMP-shaped. GAP-0265.
//
// ---------------------------------------------------------------------------
// WHAT IS VALIDATED, AND WHY EACH CHECK IS THERE
// ---------------------------------------------------------------------------
// IPC is the classic place to give back the protections the rest of this kernel
// paid for, so every one of these is a refusal with its own code:
//
//   * THE ENDPOINT IS AN ARGUMENT; THE OWNER IS NOT. A handle names a port and a
//     side; the OWNER of that side is compared against `procGet(procCurrent(),
//     procSlotId)`, which the caller cannot influence. A process cannot send on
//     another process's endpoint ([chanRetNotOwner]).
//   * THE LENGTH IS BOUNDED BEFORE ANY ARITHMETIC TOUCHES THE POINTER. DCDart
//     traps on overflow with a real `ud2`, so `chansend(ep, 0xFFFFFFFFFFFFFFFF,
//     64)` would otherwise let ring 3 choose which instruction the kernel
//     executes next -- inside the range check that was meant to stop it. M9's
//     [userOwns] carries the same note about the same hazard.
//   * THE DESTINATION OF A RECEIVE MUST BE WRITABLE BY RING 3, NOT MERELY
//     REACHABLE. [chanOwnsWrite] requires the W bit at every level. Without it a
//     program could hand `chanrecv` a pointer into its own read-only text
//     segment and have the KERNEL write there -- and although `CR0.WP` is set
//     (M8) so that store would fault rather than land, the fault would be a
//     KERNEL page fault at an address ring 3 chose. Refusing is the answer;
//     faulting is not.
//   * THE KERNEL NEVER TOUCHES ONE PROCESS'S MEMORY WHILE ANOTHER'S PAGE TABLES
//     ARE LOADED. This is the property that makes the whole thing safe, and it
//     is a consequence of the copying design: a message is copied user->kernel
//     on the sender's CR3 and kernel->user on the receiver's CR3, and the two
//     events are different syscalls. There is no moment at which a pointer from
//     one address space is dereferenced under another's tables.
//   * A SLOT IS ZEROED BEFORE IT IS FILLED. A 64-byte slot that previously held
//     a 64-byte message and now holds an 8-byte one would otherwise carry 56
//     bytes of the previous message. `chanrecv` copies only `len` bytes, so this
//     is belt and braces -- and it is 64 stores.
//   * A PORT IS WIPED WHEN IT GOES FREE. Undelivered bytes of a dead
//     conversation must not be readable by whoever opens that port number next.
//     [chanPortWipe] runs on every transition to [chanPortFree].
//   * A HALF-CLOSED PORT DOES NOT ADMIT A NEW PEER. When one side of an open
//     channel dies, the port goes to [chanPortHalfClosed] and `chanopen` REFUSES
//     it. Letting a third process take the dead side would let it join a
//     conversation in progress and read the survivor's traffic.
//
// ---------------------------------------------------------------------------
// OWNERSHIP AND LIFETIME
// ---------------------------------------------------------------------------
// A channel is never allocated and never freed: [chanPorts] port records live in
// this file's own `@bss`, so IPC costs the frame allocator nothing and cannot
// fail for want of memory. What is owned is an ENDPOINT, and it is owned by a
// PROCESS ID rather than by a slot index, because slots are reused and ids
// ([procSlotId], monotonic from `procHeadCreated`) are not.
//
//   free  --chanopen-->  half  --chanopen-->  open
//    ^                    |                    |
//    |   the owner exits  |   one owner exits  |
//    +--------------------+                    v
//    ^                                    halfClosed
//    +-----------------------------------------+   the survivor exits
//
// WHEN A PEER DIES HOLDING THE CHANNEL:
//
//   * ITS QUEUED MESSAGES ARE STILL DELIVERED. They were copied into KERNEL
//     memory at send time; the sender's death does not unsend them. `chanrecv`
//     DRAINS FIRST and returns [chanRetPeerGone] only once the ring is empty.
//     This is a real advantage of copying over sharing, and the harness proves
//     it: eight messages sent by a process that then exits are received, and
//     checked byte for byte, by a process whose peer no longer exists.
//   * A SEND TO A DEAD PEER IS REFUSED IMMEDIATELY rather than enqueued, because
//     nothing will ever drain it.
//   * THE RELEASE HAPPENS IN [procCleanup], the ONE function both the exit path
//     and the fault/kill path go through. A process that faults with a channel
//     open releases it exactly like one that exits. That is M15's finding
//     ([fileReleaseOwner]) applied to a second kind of resource.
//
// ---------------------------------------------------------------------------
// WHAT PRINTS, AND WHAT DOES NOT
// ---------------------------------------------------------------------------
// Every open, every accepted send, every delivered receive, every refusal and
// every release is a line on the serial console, because the kernel's account
// and the program's account have to be two independent statements a transcript
// can compare.
//
// [chanRetEmpty] is the ONE answer that is counted and not printed, and that is
// a decision rather than an omission: it is not a refusal. It is a successful
// query whose answer is "nothing yet", it is what a polling receiver gets on
// almost every call, and printing it would put thousands of lines between the
// ones that matter. The COUNT is in the exit report.
//
// [chanExitReport] prints NOTHING on a boot where no channel was ever opened, so
// not one byte-exact golden from M1 through M19 moves.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// GENERATED, not hand-typed: a `@rodata` table carries no length (GAP-0060), so
// every byte count below is repeated at its call site by hand, and getting one
// wrong prints the wrong number of bytes. `tests/conformance/m20-ipc/run.sh`
// reads every symbol's real size out of `kmain.o` and compares it against what
// the call site passes.
// ---------------------------------------------------------------------------

/// Line label.
///
/// `'CHAN OPEN P '` -- 12 bytes.
@rodata
final List<u8> chanStrOpen = const [
  u8(0x43), u8(0x48), u8(0x41), u8(0x4E), u8(0x20), u8(0x4F), u8(0x50), u8(0x45), u8(0x4E),
  u8(0x20), u8(0x50), u8(0x20),
];

/// Field separator: a SIDE, and a SENDS count.
///
/// `' S '` -- 3 bytes.
@rodata
final List<u8> chanStrS = const [
  u8(0x20), u8(0x53), u8(0x20),
];

/// Field separator: an endpoint handle.
///
/// `' EP '` -- 4 bytes.
@rodata
final List<u8> chanStrEp = const [
  u8(0x20), u8(0x45), u8(0x50), u8(0x20),
];

/// Field separator: the owning process id.
///
/// `' ID '` -- 4 bytes.
@rodata
final List<u8> chanStrId = const [
  u8(0x20), u8(0x49), u8(0x44), u8(0x20),
];

/// Field separator: the port's generation.
///
/// `' G '` -- 3 bytes.
@rodata
final List<u8> chanStrG = const [
  u8(0x20), u8(0x47), u8(0x20),
];

/// Line label.
///
/// `'CHAN SEND EP '` -- 13 bytes.
@rodata
final List<u8> chanStrSend = const [
  u8(0x43), u8(0x48), u8(0x41), u8(0x4E), u8(0x20), u8(0x53), u8(0x45), u8(0x4E), u8(0x44),
  u8(0x20), u8(0x45), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' LEN '` -- 5 bytes.
@rodata
final List<u8> chanStrLen = const [
  u8(0x20), u8(0x4C), u8(0x45), u8(0x4E), u8(0x20),
];

/// Field separator: the free-running producer counter.
///
/// `' SEQ '` -- 5 bytes.
@rodata
final List<u8> chanStrSeq = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x51), u8(0x20),
];

/// Line label.
///
/// `'CHAN RECV EP '` -- 13 bytes.
@rodata
final List<u8> chanStrRecv = const [
  u8(0x43), u8(0x48), u8(0x41), u8(0x4E), u8(0x20), u8(0x52), u8(0x45), u8(0x43), u8(0x56),
  u8(0x20), u8(0x45), u8(0x50), u8(0x20),
];

/// Line label: C is the syscall number that was refused.
///
/// `'CHAN REFUSE C '` -- 14 bytes.
@rodata
final List<u8> chanStrRefuse = const [
  u8(0x43), u8(0x48), u8(0x41), u8(0x4E), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55),
  u8(0x53), u8(0x45), u8(0x20), u8(0x43), u8(0x20),
];

/// Field separator: a refusal code, and a RECVS count.
///
/// `' R '` -- 3 bytes.
@rodata
final List<u8> chanStrR = const [
  u8(0x20), u8(0x52), u8(0x20),
];

/// Line label.
///
/// `'CHAN REL P '` -- 11 bytes.
@rodata
final List<u8> chanStrRel = const [
  u8(0x43), u8(0x48), u8(0x41), u8(0x4E), u8(0x20), u8(0x52), u8(0x45), u8(0x4C), u8(0x20),
  u8(0x50), u8(0x20),
];

/// Field separator: the port state AFTER the release.
///
/// `' ST '` -- 4 bytes.
@rodata
final List<u8> chanStrSt = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'CHAN TOTAL O '` -- 13 bytes.
@rodata
final List<u8> chanStrTotal = const [
  u8(0x43), u8(0x48), u8(0x41), u8(0x4E), u8(0x20), u8(0x54), u8(0x4F), u8(0x54), u8(0x41),
  u8(0x4C), u8(0x20), u8(0x4F), u8(0x20),
];

/// Field separator: bytes delivered.
///
/// `' B '` -- 3 bytes.
@rodata
final List<u8> chanStrB = const [
  u8(0x20), u8(0x42), u8(0x20),
];

/// Field separator: EMPTY answers.
///
/// `' E '` -- 3 bytes.
@rodata
final List<u8> chanStrE = const [
  u8(0x20), u8(0x45), u8(0x20),
];

/// Field separator: refusals.
///
/// `' X '` -- 3 bytes.
@rodata
final List<u8> chanStrX = const [
  u8(0x20), u8(0x58), u8(0x20),
];

// ---------------------------------------------------------------------------
// Constants.
// ---------------------------------------------------------------------------

/// Syscall 11 -- `chanopen(port)`.
const int chanSysOpenNo = 11;

/// Syscall 12 -- `chansend(ep, ptr, len)`.
const int chanSysSendNo = 12;

/// Syscall 13 -- `chanrecv(ep, ptr, cap)`.
const int chanSysRecvNo = 13;

/// How many channels can exist at once.
///
/// **Two, and the number is derived rather than picked.** A channel has exactly
/// two endpoints and [procMax] is 4, so two channels is the most that can be
/// simultaneously open on this machine. A larger table would be storage that
/// nothing on this kernel can currently reach.
const int chanPorts = 2;

/// The two sides of a channel.
const int chanSides = 2;

/// Endpoint handles are `(port << 1) | side`, so there are this many of them.
const int chanEndpoints = 4;

/// **The largest message this kernel will carry, and the design decision.**
///
/// See this file's header. A message is a NOTIFICATION AND A DESCRIPTOR, never a
/// payload; bulk data travels by reference in a shared region a later milestone
/// adds. 64 bytes is one cache line and it is enough for every frame descriptor
/// a compositor needs.
const int chanMsgBytes = 64;

/// Messages per direction. A power of two, because the slot index is a mask.
const int chanRingDepth = 8;

/// `counter & chanRingMask` is the slot index. [chanRingDepth] - 1.
const int chanRingMask = 7;

// Port record layout, in bytes from the start of the record. The regions tile
// exactly and `m20-ipc/run.sh` multiplies them out against [chanPortBytes].
const int chanHdrWords = 16;
const int chanHdrBytes = 128;
const int chanLenOffset = 128;
const int chanLenBytes = 128;   // chanSides * chanRingDepth * 8
const int chanDataOffset = 256;
const int chanDataBytes = 1024; // chanSides * chanRingDepth * chanMsgBytes
const int chanPortBytes = 1280;

// The block as a whole: eight words of global counters, then the port records.
const int chanMetaWords = 8;
const int chanMetaBytes = 64;
const int chanPortOffset = 64;
const int chanStoreBytes = 2624; // 64 + chanPorts * chanPortBytes

// Global counter word indices.
const int chanMetaOpens = 0;
const int chanMetaSends = 1;
const int chanMetaRecvs = 2;
const int chanMetaBytesW = 3;
const int chanMetaEmpty = 4;
const int chanMetaRefusals = 5;
const int chanMetaReleases = 6;
const int chanMetaCorrupt = 7;

// Port header word indices.
const int chanPortState = 0;
const int chanPortOwner0 = 1;
const int chanPortOwner1 = 2;

/// Producer counter for direction 0 (side 0 -> side 1). **Written only by side
/// 0.** See this file's header, point 1.
const int chanPortHead0 = 3;

/// Consumer counter for direction 0. **Written only by side 1.**
const int chanPortTail0 = 4;

/// Producer counter for direction 1 (side 1 -> side 0). **Written only by side
/// 1.**
const int chanPortHead1 = 5;

/// Consumer counter for direction 1. **Written only by side 0.**
const int chanPortTail1 = 6;

const int chanPortOpens = 7;
const int chanPortSends = 8;
const int chanPortRecvs = 9;
const int chanPortRefusals = 10;
const int chanPortEmptyW = 11;
const int chanPortReleases = 12;

/// Bumped every time this port goes from [chanPortFree] to [chanPortHalf].
///
/// **It is what makes "the same port number, a different conversation" a thing
/// the transcript can see.** Without it two sessions on port 0 are
/// indistinguishable in the log, and a stale-endpoint bug would look like a
/// working one.
const int chanPortGen = 13;

// Port states. The order is the lifetime and the numbers are printed.
const int chanPortFree = 0;
const int chanPortHalf = 1;
const int chanPortOpen = 2;

/// One side was bound and has since released; the other is still bound.
///
/// **Distinct from [chanPortHalf] on purpose and it is a security property, not
/// bookkeeping.** In [chanPortHalf] the port is still waiting for its first peer
/// and `chanopen` admits one. In [chanPortHalfClosed] a conversation has already
/// happened, and admitting a new process into the dead side would let it read
/// the survivor's traffic. `chanopen` refuses.
const int chanPortHalfClosed = 3;

// ---------------------------------------------------------------------------
// Return values. One floor, and every code above it distinct.
//
// The convention is `file.dart`'s (ADR-0019 section 3): one comparison separates
// an answer from a refusal, so a C wrapper that collapsed twelve refusals to -1
// would be throwing away the only diagnostic there is. `chanopen` returns a
// handle in `[0, chanEndpoints)`, `chansend` returns the length it accepted and
// `chanrecv` the length it delivered, all of which are far below the floor.
// ---------------------------------------------------------------------------

const int chanRetFloor = 0xFFFFFFFFFFFFFF00;

/// The port number is not in `[0, chanPorts)`.
const int chanRetBadPort = 0xFFFFFFFFFFFFFFFE;

/// The caller is not a process. An M9 payload and an M10 `run` program have no
/// process id, and an endpoint is owned by one. GAP-0264.
const int chanRetNoProc = 0xFFFFFFFFFFFFFFFD;

/// Both endpoints of the port are taken, or the port is [chanPortHalfClosed].
const int chanRetBusy = 0xFFFFFFFFFFFFFFFC;

/// This process already holds an endpoint on this port. **A process talking to
/// itself is refused**: it would own both sides, and every "the peer is a
/// different address space" claim on this machine would stop being true.
const int chanRetTwice = 0xFFFFFFFFFFFFFFFB;

/// The handle is not in `[0, chanEndpoints)`.
const int chanRetBadEp = 0xFFFFFFFFFFFFFFFA;

/// The handle is in range but the caller does not own that side.
const int chanRetNotOwner = 0xFFFFFFFFFFFFFFF9;

/// The buffer is not wholly inside the caller's own mapped, user-accessible --
/// and for a receive, WRITABLE -- memory.
const int chanRetBadPtr = 0xFFFFFFFFFFFFFFF8;

/// The length is 0 or is greater than [chanMsgBytes].
const int chanRetBadLen = 0xFFFFFFFFFFFFFFF7;

/// The ring in this direction already holds [chanRingDepth] messages. The
/// message was NOT enqueued and nothing was lost: the sender still has it.
const int chanRetFull = 0xFFFFFFFFFFFFFFF6;

/// Nothing is queued. **A status, not a refusal** -- counted, not printed, and
/// not added to [chanMetaRefusals]. See this file's header.
const int chanRetEmpty = 0xFFFFFFFFFFFFFFF5;

/// The port is [chanPortHalf]: nobody has joined yet.
const int chanRetNoPeer = 0xFFFFFFFFFFFFFFF4;

/// The peer released its endpoint and the ring is empty. **Returned only after
/// every message the dead peer sent has been delivered.**
const int chanRetPeerGone = 0xFFFFFFFFFFFFFFF3;

/// The queued message is longer than the buffer offered. **The message is NOT
/// consumed** -- the caller can ask again with a bigger one. Truncating would
/// lose data silently, which is the one thing a message queue must not do.
const int chanRetTooBig = 0xFFFFFFFFFFFFFFF2;

/// `head < tail` in a ring, which cannot happen. Counted in
/// [chanMetaCorrupt] and refused.
///
/// **This is here because DCDart traps on underflow with a real `ud2`.** Without
/// it a corrupted counter pair would be a #UD inside a syscall handler rather
/// than a refusal with a name -- the kernel executing an undefined instruction
/// because a ring index was wrong.
const int chanRetCorrupt = 0xFFFFFFFFFFFFFFF1;

// ---------------------------------------------------------------------------
// ===========================  THE STORAGE SEAM  ============================
//
// The ONLY three functions in this kernel that know where the channel table
// lives, and the only three places [chanStore]'s address is taken.
//
// ADR-0011 section 0's shape for ADR-0011's reason: this block has two regions
// with two different jobs, plus the per-port record arithmetic, so it gets three
// named functions and nothing else in the kernel names the symbol.
// `tests/conformance/m20-ipc/run.sh` counts the call sites and greps the rest of
// core/kernel/ for the name.
// ---------------------------------------------------------------------------

/// The 2624 bytes this subsystem owns.
///
/// **It is the LAST block in `kmain.o`'s `.bss` and that is not a filing
/// preference.** Every harness from M2 onward measures "the donated bytes from
/// MY block to the end of `.bss`", so a new block anywhere else would move every
/// one of those numbers at once. At the end, each older harness subtracts this
/// one first -- which is what M14, M15, M16 and M19 each did in turn, and what
/// `m19-argv/run.sh` now does for this block.
@bss
final Bss chanStore = const Bss(bytes: chanStoreBytes);

/// Base of the eight global counter words.
@bare
u64 chanMetaBase() {
  return Bss.addressOf(chanStore);
}

/// Base of port [p]'s 1280-byte record.
@bare
u64 chanPortBase(u64 p) {
  return Bss.addressOf(chanStore) + u64(chanPortOffset) + (p * u64(chanPortBytes));
}

/// The whole block, for the wipe loop.
@bare
u64 chanStoreBase() {
  return Bss.addressOf(chanStore);
}

// ======================  END OF THE STORAGE SEAM  ==========================

// ---------------------------------------------------------------------------
// Primitives. Everything below goes through the seam.
// ---------------------------------------------------------------------------

/// Reads global counter word [i].
@bare
u64 chanMeta(u64 i) {
  return Pointer<u64>.fromAddress(chanMetaBase() + (i << u64(3))).value;
}

/// Writes global counter word [i].
@bare
void chanSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(chanMetaBase() + (i << u64(3))).value = v;
}

/// Adds one to global counter word [i].
@bare
void chanBumpMeta(u64 i) {
  chanSetMeta(i, chanMeta(i) + u64(1));
}

/// Reads header word [w] of port [p].
@bare
u64 chanPort(u64 p, u64 w) {
  return Pointer<u64>.fromAddress(chanPortBase(p) + (w << u64(3))).value;
}

/// Writes header word [w] of port [p].
@bare
void chanSetPort(u64 p, u64 w, u64 v) {
  Pointer<u64>.fromAddress(chanPortBase(p) + (w << u64(3))).value = v;
}

/// Adds one to header word [w] of port [p].
@bare
void chanBumpPort(u64 p, u64 w) {
  chanSetPort(p, w, chanPort(p, w) + u64(1));
}

/// The header word holding the length of port [p]'s direction-[d] slot [i].
@bare
u64 chanLenAddr(u64 p, u64 d, u64 i) {
  return chanPortBase(p) + u64(chanLenOffset) +
      (((d * u64(chanRingDepth)) + i) << u64(3));
}

/// The first byte of port [p]'s direction-[d] slot [i].
@bare
u64 chanSlotAddr(u64 p, u64 d, u64 i) {
  return chanPortBase(p) + u64(chanDataOffset) +
      (((d * u64(chanRingDepth)) + i) * u64(chanMsgBytes));
}

/// The header word holding direction [d]'s producer counter.
@bare
u64 chanHeadWord(u64 d) {
  if (d < u64(1)) {
    return u64(chanPortHead0);
  }
  return u64(chanPortHead1);
}

/// The header word holding direction [d]'s consumer counter.
@bare
u64 chanTailWord(u64 d) {
  if (d < u64(1)) {
    return u64(chanPortTail0);
  }
  return u64(chanPortTail1);
}

/// The header word holding side [s]'s owning process id.
@bare
u64 chanOwnerWord(u64 s) {
  if (s < u64(1)) {
    return u64(chanPortOwner0);
  }
  return u64(chanPortOwner1);
}

/// Gives every byte of port [p]'s record except its generation a known value.
///
/// **Called on every transition to [chanPortFree], and that is a
/// confidentiality requirement rather than hygiene.** A port that went free with
/// undelivered messages still in its rings would hand those bytes to whichever
/// process opened that port number next -- a process the dead conversation never
/// agreed to talk to. The generation survives, because it is what distinguishes
/// one conversation on a port number from the next.
@bare
void chanPortWipe(u64 p) {
  final u64 gen = chanPort(p, u64(chanPortGen));
  final u64 base = chanPortBase(p);
  u64 o = u64(0);
  while (o < u64(chanPortBytes)) {
    Pointer<u64>.fromAddress(base + o).value = u64(0);
    o = o + u64(8);
  }
  chanSetPort(p, u64(chanPortGen), gen);
}

/// Gives every word of the block a known value. **Prints nothing, and must keep
/// printing nothing:** `tests/conformance/m1-interrupts/run.sh` asserts the
/// entire 544-byte serial capture.
///
/// Called from `kmain()` after [fileInit], for the reason every init there is
/// called where it is: `.bss` is not zeroed by anything in this kernel, and
/// [chanReleaseOwner] is reached from [procCleanup] on EVERY process teardown --
/// including those of m11's, m18's and m19's programs, none of which has ever
/// opened a channel. A garbage owner word would make the first of those print a
/// release line into the middle of a byte-exact golden, and a garbage state word
/// would make it wipe a port record that a live process was using.
@bare
void chanInit() {
  final u64 base = chanStoreBase();
  u64 o = u64(0);
  while (o < u64(chanStoreBytes)) {
    Pointer<u64>.fromAddress(base + o).value = u64(0);
    o = o + u64(8);
  }
}

// ---------------------------------------------------------------------------
// Validation.
// ---------------------------------------------------------------------------

/// 1 if `[ptr, ptr+len)` is wholly inside the calling process's own mapped,
/// user-accessible memory.
///
/// **The bound on [len] comes FIRST, before any arithmetic on [ptr], and that is
/// a correctness requirement rather than an ordering preference.** DCDart's
/// arithmetic traps on overflow (DCDART_SPEC section 4.1) by emitting a real
/// `ud2`, and `ptr` is a value ring 3 chose: `chansend(ep, 0xFFFFFFFFFFFFFFFF,
/// 64)` would make `ptr + len` overflow inside this function and take a #UD *in
/// the syscall handler*. A ring-3 program must not be able to choose which
/// instruction the kernel executes next, and the range test that was supposed to
/// stop it would have been the thing it used. M9's [userOwns] carries the same
/// note.
///
/// The walk is per PAGE and reads the LIVE tables through [vmEffective], which
/// walks from CR3 -- and CR3 is the caller's, because a syscall does not switch
/// address spaces. So "the caller's own memory" is a property of the machine at
/// this instant rather than of a remembered list.
@bare
u64 chanOwnsRead(u64 ptr, u64 len) {
  if (ptr < u64(vmProgBase)) {
    return u64(0);
  }
  if (ptr >= u64(vmProgEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(chanMsgBytes)) {
    return u64(0);
  }
  if ((ptr + len) > u64(vmProgEnd)) {
    return u64(0);
  }
  u64 a = ptr & u64(0xFFFFFFFFFFFFF000);
  final u64 last = (ptr + len - u64(1)) & u64(0xFFFFFFFFFFFFF000);
  while (a <= last) {
    if ((vmEffective(a) & u64(2)) < u64(1)) {
      return u64(0); // not reachable from ring 3 at all
    }
    a = a + u64(vmPageBytes);
  }
  return u64(1);
}

/// 1 if `[ptr, ptr+len)` is inside the caller's own memory AND ring 3 may WRITE
/// every page of it.
///
/// **The W bit is the whole difference from [chanOwnsRead], and it is the check
/// that stops IPC from undoing W^X.** A program can legally ask the kernel to
/// SEND out of its own read-only text or rodata -- `m20-ipc`'s program does
/// exactly that -- but a RECEIVE writes, and a destination that ring 3 cannot
/// write is one the kernel must not write on its behalf. `CR0.WP` is set (M8) so
/// the store would fault rather than land, but a kernel page fault at an address
/// ring 3 picked is not an answer; a refusal is.
///
/// This is `file.dart`'s [fileOwnsWrite] with [chanMsgBytes] as the bound, kept
/// as a separate function rather than shared for the reason M16 kept two: the
/// two subsystems' length bounds are different numbers and one of them changing
/// must not silently change the other.
@bare
u64 chanOwnsWrite(u64 ptr, u64 len) {
  if (ptr < u64(vmProgBase)) {
    return u64(0);
  }
  if (ptr >= u64(vmProgEnd)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(chanMsgBytes)) {
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

/// The calling process's id, or 0 if the caller is not a process.
///
/// **The one place "who is asking" is decided, and it is decided from the
/// kernel's own scheduler state.** No syscall argument reaches it, so no ring-3
/// program can claim to be another.
@bare
u64 chanCallerId() {
  if (procLive() < u64(1)) {
    return u64(0);
  }
  return procGet(procCurrent(), u64(procSlotId));
}

// ---------------------------------------------------------------------------
// The copies. These are the ONLY two functions in this file that dereference an
// address ring 3 chose, and each of them has exactly one caller which has
// already validated exactly the range being passed.
//
// Nothing between the check and the copy can change the tables: the gate is an
// INTERRUPT gate so IF is clear, this kernel is single-CPU, and it does not
// preempt inside a syscall. `file.dart`'s [fileCopyOut] carries the same note.
// ---------------------------------------------------------------------------

/// Copies [n] bytes from the caller's [src] into the ring slot at [dst], after
/// zeroing the whole slot.
///
/// The zeroing is what makes a short message short: without it the tail of the
/// previous message in that slot would still be sitting there. `chanrecv` copies
/// only `len` bytes so it could not be read anyway -- this removes the class of
/// bug rather than the instance.
@bare
void chanCopyIn(u64 dst, u64 src, u64 n) {
  u64 z = u64(0);
  while (z < u64(chanMsgBytes)) {
    Pointer<u64>.fromAddress(dst + z).value = u64(0);
    z = z + u64(8);
  }
  u64 i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(dst + i).value = Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Copies [n] bytes from the ring slot at [src] to the caller's [dst].
@bare
void chanCopyOut(u64 dst, u64 src, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(dst + i).value = Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// Records a refusal, prints it, and hands [code] back to ring 3 in RAX.
///
/// **A refusal is printed and counted, never silent** -- M9's [userRefuse] and
/// ADR-0011 section 4's argument, applied here: a subsystem that reports zero
/// refusals is making a claim only if a refusal would have been recorded.
///
/// [chanRetEmpty] does NOT come through here. It is not a refusal; see this
/// file's header.
@bare
void chanRefuse(u64 frame, u64 no, u64 ep, u64 code) {
  chanBumpMeta(u64(chanMetaRefusals));
  uartWrite(Rodata.addressOf(chanStrRefuse), u64(14));
  uartPutHex(no, u64(2));
  uartWrite(Rodata.addressOf(chanStrEp), u64(4));
  uartPutHex(ep, u64(16));
  uartWrite(Rodata.addressOf(chanStrR), u64(3));
  uartPutHex(code, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), code);
}

/// `CHAN TOTAL O <opens> S <sends> R <recvs> B <bytes> E <empty> X <refusals>`
///
/// **Prints nothing at all if no channel was ever opened on this boot**, which
/// is what keeps every byte-exact golden from M1 through M19 exactly where it
/// was. `fileExitReport` established the pattern at M15 and this is the same
/// argument for the same reason.
@bare
void chanExitReport() {
  if (chanMeta(u64(chanMetaOpens)) < u64(1)) {
    return;
  }
  uartWrite(Rodata.addressOf(chanStrTotal), u64(13));
  uartPutHex(chanMeta(u64(chanMetaOpens)), u64(8));
  uartWrite(Rodata.addressOf(chanStrS), u64(3));
  uartPutHex(chanMeta(u64(chanMetaSends)), u64(8));
  uartWrite(Rodata.addressOf(chanStrR), u64(3));
  uartPutHex(chanMeta(u64(chanMetaRecvs)), u64(8));
  uartWrite(Rodata.addressOf(chanStrB), u64(3));
  uartPutHex(chanMeta(u64(chanMetaBytesW)), u64(8));
  uartWrite(Rodata.addressOf(chanStrE), u64(3));
  uartPutHex(chanMeta(u64(chanMetaEmpty)), u64(8));
  uartWrite(Rodata.addressOf(chanStrX), u64(3));
  uartPutHex(chanMeta(u64(chanMetaRefusals)), u64(8));
  uartNewline();
}

// ---------------------------------------------------------------------------
// Lifetime.
// ---------------------------------------------------------------------------

/// Releases every endpoint owned by process id [id].
///
/// **Returns nothing, and prints one line per endpoint instead.** A count would
/// be the weaker statement: `CHAN REL P 00 S 00 ID 00000001 ST 03` says which
/// port, which side, whose, and what state the port was left in, and it is the
/// evidence `m20-ipc/run.sh` matches against its own model of the lifetime.
///
/// **Called from [procCleanup], which is the ONE function both the exit path and
/// the fault/kill path go through.** A process that faults with a channel open
/// releases it exactly like one that exits -- M15's [fileReleaseOwner] finding,
/// applied to a second kind of resource. There is no other caller and there must
/// not be: an endpoint that outlived its owner would be one a later process in
/// the same slot inherited.
///
/// Release by ID and not by slot, and the guard on `id < 1` is load-bearing:
/// [procCleanup] also runs on the LOAD-REFUSAL path, where the slot's id word
/// still holds whatever the previous occupant had, or 0 on a slot that has never
/// been used. 0 is [chanPortFree]'s "unbound" value, so an unguarded release
/// would free every unbound endpoint in the table.
@bare
void chanReleaseOwner(u64 id) {
  if (id < u64(1)) {
    return;
  }
  u64 p = u64(0);
  while (p < u64(chanPorts)) {
    u64 s = u64(0);
    while (s < u64(chanSides)) {
      if (chanPort(p, chanOwnerWord(s)) == id) {
        chanSetPort(p, chanOwnerWord(s), u64(0));
        final u64 was = chanPort(p, u64(chanPortState));
        u64 now = u64(chanPortFree);
        if (was == u64(chanPortOpen)) {
          // The PEER IS STILL HERE. The port must not go free: its rings still
          // hold messages this process sent, and the survivor is entitled to
          // every one of them. See this file's header.
          now = u64(chanPortHalfClosed);
        }
        chanSetPort(p, u64(chanPortState), now);
        chanBumpPort(p, u64(chanPortReleases));
        chanBumpMeta(u64(chanMetaReleases));
        uartWrite(Rodata.addressOf(chanStrRel), u64(11));
        uartPutHex(p, u64(2));
        uartWrite(Rodata.addressOf(chanStrS), u64(3));
        uartPutHex(s, u64(1));
        uartWrite(Rodata.addressOf(chanStrId), u64(4));
        uartPutHex(id, u64(8));
        uartWrite(Rodata.addressOf(chanStrSt), u64(4));
        uartPutHex(now, u64(1));
        uartNewline();
        // The WIPE happens AFTER the line is printed and only on the transition
        // to free, so the report describes the port that existed rather than the
        // blank one that replaced it.
        if (now == u64(chanPortFree)) {
          chanPortWipe(p);
        }
      }
      s = s + u64(1);
    }
    p = p + u64(1);
  }
}

// ---------------------------------------------------------------------------
// The syscalls.
// ---------------------------------------------------------------------------

/// Syscall 11 -- `chanopen(port)`. Returns an endpoint handle `(port << 1) |
/// side`, or a refusal.
///
/// **The SIDE is assigned by the kernel, in arrival order, and it is the only
/// thing that distinguishes the two peers.** `m20-ipc` runs the SAME BINARY
/// twice and each copy discovers which end of the conversation it is from this
/// return value alone -- so "the two processes behaved differently" is a claim
/// about the kernel rather than about two different programs.
@bare
void chanSysOpen(u64 frame) {
  final u64 port = userFrame(frame, u64(userFrameRdi));
  final u64 id = chanCallerId();
  if (id < u64(1)) {
    chanRefuse(frame, u64(chanSysOpenNo), port, u64(chanRetNoProc));
    return;
  }
  if (port >= u64(chanPorts)) {
    chanRefuse(frame, u64(chanSysOpenNo), port, u64(chanRetBadPort));
    return;
  }
  final u64 state = chanPort(port, u64(chanPortState));
  // ALREADY-MINE IS ANSWERED FIRST, AND BEFORE THE STATE IS CONSULTED.
  //
  // THIS ORDER WAS A BUG AND THE HARNESS FOUND IT. The check used to live
  // inside the [chanPortHalf] arm, so a process that already held side 0 of an
  // OPEN port was told [chanRetBusy] -- "somebody else has both ends" -- when
  // the truth was "you are one of them". Those are different facts and a client
  // acts differently on them: BUSY means back off and try another port, TWICE
  // means you already have the handle you are asking for. A compositor client
  // that re-opened by mistake would have gone looking for a free port it did not
  // need.
  //
  // Owner words hold 0 when unbound and every process id is >= 1, so an unbound
  // side can never match.
  if (chanPort(port, u64(chanPortOwner0)) == id) {
    chanRefuse(frame, u64(chanSysOpenNo), port, u64(chanRetTwice));
    return;
  }
  if (chanPort(port, u64(chanPortOwner1)) == id) {
    chanRefuse(frame, u64(chanSysOpenNo), port, u64(chanRetTwice));
    return;
  }
  u64 side = u64(0);
  if (state == u64(chanPortFree)) {
    // A FRESH CONVERSATION. Wipe first, then bump the generation: the wipe is
    // what stops a previous conversation's undelivered bytes from being readable
    // here, and the generation is what makes this one distinguishable from it in
    // the transcript.
    chanPortWipe(port);
    chanSetPort(port, u64(chanPortGen), chanPort(port, u64(chanPortGen)) + u64(1));
    chanSetPort(port, u64(chanPortOwner0), id);
    chanSetPort(port, u64(chanPortState), u64(chanPortHalf));
    side = u64(0);
  } else {
    if (state == u64(chanPortHalf)) {
      // The already-mine test above has already refused the case where this is
      // the same process arriving twice -- which is what stops a process from
      // owning both sides and talking to itself, and with it every "the peer is
      // a different address space" claim on this machine.
      chanSetPort(port, u64(chanPortOwner1), id);
      chanSetPort(port, u64(chanPortState), u64(chanPortOpen));
      side = u64(1);
    } else {
      // OPEN or HALF-CLOSED. The half-closed case is the one that matters: a
      // third process must not be able to take a dead peer's seat and read the
      // survivor's traffic.
      chanRefuse(frame, u64(chanSysOpenNo), port, u64(chanRetBusy));
      return;
    }
  }
  final u64 ep = (port << u64(1)) | side;
  chanBumpPort(port, u64(chanPortOpens));
  chanBumpMeta(u64(chanMetaOpens));
  uartWrite(Rodata.addressOf(chanStrOpen), u64(12));
  uartPutHex(port, u64(2));
  uartWrite(Rodata.addressOf(chanStrS), u64(3));
  uartPutHex(side, u64(1));
  uartWrite(Rodata.addressOf(chanStrEp), u64(4));
  uartPutHex(ep, u64(2));
  uartWrite(Rodata.addressOf(chanStrId), u64(4));
  uartPutHex(id, u64(8));
  uartWrite(Rodata.addressOf(chanStrG), u64(3));
  uartPutHex(chanPort(port, u64(chanPortGen)), u64(8));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), ep);
}

/// Syscall 12 -- `chansend(ep, ptr, len)`. Returns [len], or a refusal.
///
/// **Never blocks.** A full ring is [chanRetFull] and the message is not
/// enqueued, so the sender still has it and can decide what to do -- retry,
/// coalesce, or drop. That decision belongs to the sender and not to the kernel,
/// and it is the whole reason this is a bounded queue rather than a rendezvous:
/// a compositor cannot afford to be stopped by a client that is not reading.
///
/// **The order of the checks is the security argument, top to bottom:** who is
/// asking, then what they are allowed to touch, then how big it is, then where
/// it is. Every one of them happens before a single byte is read from [ptr].
@bare
void chanSysSend(u64 frame) {
  final u64 ep = userFrame(frame, u64(userFrameRdi));
  final u64 ptr = userFrame(frame, u64(userFrameRsi));
  final u64 len = userFrame(frame, u64(userFrameRdx));
  final u64 id = chanCallerId();
  if (id < u64(1)) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetNoProc));
    return;
  }
  if (ep >= u64(chanEndpoints)) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetBadEp));
    return;
  }
  final u64 port = ep >> u64(1);
  final u64 side = ep & u64(1);
  if (chanPort(port, chanOwnerWord(side)) != id) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetNotOwner));
    return;
  }
  final u64 state = chanPort(port, u64(chanPortState));
  if (state == u64(chanPortHalf)) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetNoPeer));
    return;
  }
  if (state != u64(chanPortOpen)) {
    // HALF-CLOSED. Not enqueued, because nothing will ever drain it.
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetPeerGone));
    return;
  }
  if (len < u64(1)) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetBadLen));
    return;
  }
  if (len > u64(chanMsgBytes)) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetBadLen));
    return;
  }
  if (chanOwnsRead(ptr, len) < u64(1)) {
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetBadPtr));
    return;
  }
  // Direction s is the one side s PRODUCES into. This is the only place the
  // mapping is written down, and it is what makes each ring single-producer.
  final u64 d = side;
  final u64 head = chanPort(port, chanHeadWord(d));
  final u64 tail = chanPort(port, chanTailWord(d));
  if (head < tail) {
    chanBumpMeta(u64(chanMetaCorrupt));
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetCorrupt));
    return;
  }
  if ((head - tail) >= u64(chanRingDepth)) {
    chanBumpPort(port, u64(chanPortRefusals));
    chanRefuse(frame, u64(chanSysSendNo), ep, u64(chanRetFull));
    return;
  }
  final u64 slot = head & u64(chanRingMask);
  chanCopyIn(chanSlotAddr(port, d, slot), ptr, len);
  Pointer<u64>.fromAddress(chanLenAddr(port, d, slot)).value = len;
  // ---- THE PUBLICATION POINT ----
  // Everything the consumer will read has been written. On an SMP kernel a
  // RELEASE FENCE goes here, between the last store to the slot and the store
  // that advances head; on this single-core kernel the interrupt gate's cleared
  // IF is what serialises it. See this file's header, point 3, and GAP-0265.
  chanSetPort(port, chanHeadWord(d), head + u64(1));
  chanBumpPort(port, u64(chanPortSends));
  chanBumpMeta(u64(chanMetaSends));
  uartWrite(Rodata.addressOf(chanStrSend), u64(13));
  uartPutHex(ep, u64(2));
  uartWrite(Rodata.addressOf(chanStrLen), u64(5));
  uartPutHex(len, u64(2));
  uartWrite(Rodata.addressOf(chanStrSeq), u64(5));
  uartPutHex(head, u64(8));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), len);
}

/// Syscall 13 -- `chanrecv(ep, ptr, cap)`. Returns the number of bytes
/// delivered, [chanRetEmpty], [chanRetPeerGone], or a refusal.
///
/// **Never blocks, and DRAINS BEFORE IT MOURNS.** A dead peer's messages were
/// copied into kernel memory when they were sent; its death does not unsend
/// them. So [chanRetPeerGone] is returned only when the ring is EMPTY and the
/// peer is gone -- the two conditions in that order, and the harness proves it
/// by having one process send eight messages and exit before the other has read
/// any of them.
@bare
void chanSysRecv(u64 frame) {
  final u64 ep = userFrame(frame, u64(userFrameRdi));
  final u64 ptr = userFrame(frame, u64(userFrameRsi));
  final u64 cap = userFrame(frame, u64(userFrameRdx));
  final u64 id = chanCallerId();
  if (id < u64(1)) {
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetNoProc));
    return;
  }
  if (ep >= u64(chanEndpoints)) {
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetBadEp));
    return;
  }
  final u64 port = ep >> u64(1);
  final u64 side = ep & u64(1);
  if (chanPort(port, chanOwnerWord(side)) != id) {
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetNotOwner));
    return;
  }
  if (cap < u64(1)) {
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetBadLen));
    return;
  }
  if (cap > u64(chanMsgBytes)) {
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetBadLen));
    return;
  }
  // THE DESTINATION MUST BE WRITABLE BY RING 3. This is the check that stops IPC
  // from being a way to write through a read-only user mapping from ring 0.
  if (chanOwnsWrite(ptr, cap) < u64(1)) {
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetBadPtr));
    return;
  }
  // Side s CONSUMES the direction the other side produces.
  final u64 d = u64(1) - side;
  // ---- THE ACQUIRE POINT ----
  // head is read FIRST. A stale head makes this ring look emptier than it is,
  // which costs a delayed message and never a wrong one; the reverse order would
  // let the slot be read before its contents were published. On an SMP kernel an
  // ACQUIRE FENCE goes here. GAP-0265.
  final u64 head = chanPort(port, chanHeadWord(d));
  final u64 tail = chanPort(port, chanTailWord(d));
  if (head < tail) {
    chanBumpMeta(u64(chanMetaCorrupt));
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetCorrupt));
    return;
  }
  if (head == tail) {
    final u64 state = chanPort(port, u64(chanPortState));
    if (state == u64(chanPortHalf)) {
      chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetNoPeer));
      return;
    }
    if (state != u64(chanPortOpen)) {
      // HALF-CLOSED AND DRAINED. This is the only path that reports a dead peer,
      // and it is reachable only after every message that peer sent has been
      // handed over.
      chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetPeerGone));
      return;
    }
    // NOT A REFUSAL. Counted, not printed, not added to chanMetaRefusals.
    chanBumpPort(port, u64(chanPortEmptyW));
    chanBumpMeta(u64(chanMetaEmpty));
    userSetFrame(frame, u64(userFrameRax), u64(chanRetEmpty));
    return;
  }
  final u64 slot = tail & u64(chanRingMask);
  final u64 n = Pointer<u64>.fromAddress(chanLenAddr(port, d, slot)).value;
  if (n > cap) {
    // THE MESSAGE IS NOT CONSUMED. Truncating would lose data silently, which is
    // the one thing a message queue must not do; the caller can ask again with a
    // bigger buffer and the message will still be here.
    chanRefuse(frame, u64(chanSysRecvNo), ep, u64(chanRetTooBig));
    return;
  }
  chanCopyOut(ptr, chanSlotAddr(port, d, slot), n);
  // ---- THE RELEASE POINT ----
  // The slot has been copied out before tail is advanced, so the producer cannot
  // overwrite it while it is being read. On an SMP kernel a RELEASE FENCE goes
  // here. GAP-0265.
  chanSetPort(port, chanTailWord(d), tail + u64(1));
  chanBumpPort(port, u64(chanPortRecvs));
  chanBumpMeta(u64(chanMetaRecvs));
  chanSetMeta(u64(chanMetaBytesW), chanMeta(u64(chanMetaBytesW)) + n);
  uartWrite(Rodata.addressOf(chanStrRecv), u64(13));
  uartPutHex(ep, u64(2));
  uartWrite(Rodata.addressOf(chanStrLen), u64(5));
  uartPutHex(n, u64(2));
  uartWrite(Rodata.addressOf(chanStrSeq), u64(5));
  uartPutHex(tail, u64(8));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), n);
}
