part of 'kmain.dart';

// ---------------------------------------------------------------------------
// D4/D5 -- THE COMPOSITOR. Two client processes, two shared regions, two
// windows on one screen, and a pointer drawn over the top of them.
//
// ADR-0050 (who owns the framebuffer) and ADR-0051 (the surface protocol).
// `docs/design/display-protocol.md` is the design this implements and, in two
// places, deliberately departs from; both departures are argued below and
// again in the ADRs.
//
// ---------------------------------------------------------------------------
// 1. WHY THE COMPOSITOR IS IN THE KERNEL, WHICH IS THE DECISION THIS FILE IS
// ---------------------------------------------------------------------------
// `display-protocol.md` §0.1 defines the compositor as "the one PROCESS allowed
// to touch the framebuffer", and §6 then says, in as many words, that until D3
// lands -- a process that outlives the shell command that started it --
// "there is nowhere for a compositor to live". D3 is not built. So a ring-3
// compositor is not a thing that can be written today, and the choice is not
// between a kernel compositor and a userland one; it is between a kernel
// compositor and no pixels.
//
// Three further facts make the kernel the RIGHT answer and not merely the
// available one, and none of them is about D3:
//
//   1. PRESENTATION IS ALREADY A KERNEL OPERATION AND ALWAYS WILL BE. The mode
//      and the scanout origin are set through I/O ports 0x1CE/0x1CF, ring 3
//      cannot execute `out`, and `m9-ring3` asserts the TSS has no I/O
//      permission bitmap. `display-protocol.md` §3.1 established this before
//      any of this file existed.
//   2. THE FRAMEBUFFER IS NOT SHAREABLE MEMORY. It is a 16 MiB PCI aperture at
//      an address discovered from BAR0, mapped supervisor and NX by
//      `vmBuild`. `shm.dart` shares FRAME-ALLOCATOR pages; there is no
//      mechanism in this kernel for handing a PCI aperture to ring 3, and
//      inventing one is a hard-to-reverse memory-layout decision that
//      `CLAUDE.md`'s escalation rule reserves for a human.
//   3. THE RING-3 WINDOW IS 2 MiB AND A FRAME IS 1.92 MB.
//      `display-protocol.md` §1.2 calls this the binding constraint, and §3.4
//      records that the author's first design -- map VRAM into the compositor
//      -- cannot work because two frames of VRAM are 3.84 MB. A compositor
//      that cannot hold a frame is a compositor that must be given one by the
//      kernel anyway.
//
// **So the compositor takes EXCLUSIVE ownership of the framebuffer while it is
// on, and the kernel text console gets it back when it is off.** That is the
// third of the three answers ADR-0050 considered (exclusive / console keeps a
// region / alternate by mode) and it is ALTERNATE BY MODE, with the mode
// visible in one word of `.bss` and enforced in exactly one place: [fbPutc]
// returns early while [wmActive] is set. The console is not disabled -- COM1
// and the 0xB8000 text buffer still receive every byte, which is what keeps
// every byte-exact serial golden from M1 onwards unmoved. What stops is
// GLYPHS BEING BLITTED OVER COMPOSED WINDOWS, which is the actual conflict.
//
// ---------------------------------------------------------------------------
// 2. THE PROTOCOL, AND THE THREE QUESTIONS IT HAS TO ANSWER
// ---------------------------------------------------------------------------
// One syscall, [wmSysSurfaceNo], carrying a 64-BYTE DESCRIPTOR by pointer. 64
// bytes is not a coincidence and not a round number: it is [chanMsgBytes].
// `chan.dart`'s header says a message "is enough for every frame descriptor a
// compositor needs" and ADR-0027 §2.3 promised the two mechanisms would
// compose without either changing. **This descriptor is byte-for-byte a legal
// channel message**, so when D3 lands and the compositor moves to ring 3, the
// identical eight words go through `chansend` and nothing about the wire format
// moves. That is the whole reason for choosing the size rather than, say, six
// words.
//
//   * WHAT A CLIENT SENDS TO GET A SURFACE -- `op = wmOpAttach`, naming a
//     capability HANDLE it already holds, plus a geometry. The reply in `rax`
//     is THE ADDRESS ITS OWN ADDRESS SPACE HAS THAT REGION AT.
//   * HOW IT SAYS THIS FRAME IS READY -- `op = wmOpCommit`, naming the same
//     handle and a damage rectangle.
//   * HOW THE COMPOSITOR SAYS IT IS DONE WITH THE BUFFER -- **the commit
//     syscall returns.** Composition happens synchronously, inside the
//     caller's own syscall, and the return is therefore not a promise that the
//     compositor will be finished later; it is the statement that it already
//     is. Nothing can block on this machine (GAP-0141), so a design in which
//     the answer arrives later would need a queue, a wakeup and a sixth
//     process state, none of which exist. GAP-0303 records the cost, which is
//     that a client pays for its own composite.
//
// ---------------------------------------------------------------------------
// 3. THE ABI RULE THIS FILE OBEYS: NO SLOT-DERIVED ADDRESSES, ANYWHERE
// ---------------------------------------------------------------------------
// The owner has ratified that a syscall returns a region's address so that
// userland stops deriving it from a slot number. This protocol is built so that
// the question cannot arise:
//
//   * A DESCRIPTOR NAMES A CAPABILITY HANDLE, NEVER AN ADDRESS. The kernel
//     resolves handle -> capability -> region -> frame vector -> physical
//     pages, through `shm.dart`'s own accessors, and validates the handle
//     against THE CALLER'S OWN capability table exactly as [shmSysMap] does. A
//     forged handle reaches nothing.
//   * WHERE THE CLIENT DRAWS IS SOMETHING IT IS TOLD, NOT SOMETHING IT
//     COMPUTES. `wmOpAttach` returns the address. Before this call existed a
//     region's CREATOR had no syscall that would tell it -- `shmcreate`
//     returns a handle and maps the region, and `shmmap` on that handle is
//     then refused as already-mapped -- so the only thing a creator could do
//     was write `vmShmBase` into its own source. `m21-shmem/prog.c` contains
//     that literal for exactly that reason. **The client in
//     `tests/conformance/d2-compositor/prog.c` contains no address at all.**
//   * PIXELS INSIDE A DESCRIPTOR ARE ADDRESSED BY OFFSET AND STRIDE, never by
//     pointer, so a descriptor stays meaningful when it crosses an address
//     space -- which is precisely what will happen to it when the compositor
//     moves to ring 3.
//
// This converges with `shmaddr` (ADR-0045), which is landing on another line
// and does the same job for `shm` generally. When it merges, `wmOpAttach`'s
// return value becomes a convenience rather than the only way; the wire format
// does not move either way, because it never carried an address.
//
// ---------------------------------------------------------------------------
// 4. WHAT THIS DOES NOT DO
// ---------------------------------------------------------------------------
//   * NO DAMAGE-DRIVEN PARTIAL REDRAW. The damage rectangle is carried,
//     validated, clamped and PRINTED, and then a full frame is composed
//     anyway. GAP-0301. Composing only the damage is D6 and it has its own
//     exit criterion (a pixel count that must be small); building it here
//     would have meant shipping the count without the harness that makes the
//     count mean something.
//   * NO INPUT ROUTING. The pointer is DRAWN by the compositor, on top, every
//     frame; no click is delivered to anybody. That is D7 and it needs D2's
//     event queue, which does not exist (`display-protocol.md` §4.1: "there is
//     no keystroke queue at all. Depth zero.").
//   * NO WINDOW MOVE. GAP-0302 records what it would take and why it is not
//     here.
//   * NO TITLE BAR AND NO FONT WORK. Windows are told apart by a BORDER whose
//     colour is a function of stacking position -- the top window's border is
//     bright, everything under it is dim -- which is the cheapest thing that
//     makes stacking order visible to a person AND assertable as a pixel.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040). GENERATED,
// not hand-typed: a `@rodata` table carries no length (GAP-0060), so every
// byte count below is repeated at its call site by hand and getting one wrong
// prints the wrong number of bytes. `d2-compositor/run.sh` reads every symbol's
// real size out of `kmain.o` and compares it against what the call site passes.
// ---------------------------------------------------------------------------

///
/// `'wm'` -- 2 bytes.
@rodata
final List<u8> wmStrCmd = const [
  u8(0x77), u8(0x6D),
];

///
/// `'wm on'` -- 5 bytes.
@rodata
final List<u8> wmStrCmdOn = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x6F), u8(0x6E),
];

///
/// `'wm off'` -- 6 bytes.
@rodata
final List<u8> wmStrCmdOff = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x6F), u8(0x66), u8(0x66),
];

///
/// `'wm draw'` -- 7 bytes.
@rodata
final List<u8> wmStrCmdDraw = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x64), u8(0x72), u8(0x61), u8(0x77),
];

///
/// `'WM ON BASE '` -- 11 bytes.
@rodata
final List<u8> wmStrOn = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4F), u8(0x4E), u8(0x20), u8(0x42), u8(0x41), u8(0x53),
  u8(0x45), u8(0x20),
];

///
/// `' PITCH '` -- 7 bytes.
@rodata
final List<u8> wmStrPitch = const [
  u8(0x20), u8(0x50), u8(0x49), u8(0x54), u8(0x43), u8(0x48), u8(0x20),
];

///
/// `' BG '` -- 4 bytes.
@rodata
final List<u8> wmStrBg = const [
  u8(0x20), u8(0x42), u8(0x47), u8(0x20),
];

///
/// `'WM OFF FRAMES '` -- 14 bytes.
@rodata
final List<u8> wmStrOff = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4F), u8(0x46), u8(0x46), u8(0x20), u8(0x46), u8(0x52),
  u8(0x41), u8(0x4D), u8(0x45), u8(0x53), u8(0x20),
];

///
/// `'WM ATTACH W '` -- 12 bytes.
@rodata
final List<u8> wmStrAttach = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x41), u8(0x54), u8(0x54), u8(0x41), u8(0x43), u8(0x48),
  u8(0x20), u8(0x57), u8(0x20),
];

///
/// `' R '` -- 3 bytes.
@rodata
final List<u8> wmStrR = const [
  u8(0x20), u8(0x52), u8(0x20),
];

///
/// `' GEN '` -- 5 bytes.
@rodata
final List<u8> wmStrGen = const [
  u8(0x20), u8(0x47), u8(0x45), u8(0x4E), u8(0x20),
];

///
/// `' X '` -- 3 bytes.
@rodata
final List<u8> wmStrX = const [
  u8(0x20), u8(0x58), u8(0x20),
];

///
/// `' Y '` -- 3 bytes.
@rodata
final List<u8> wmStrY = const [
  u8(0x20), u8(0x59), u8(0x20),
];

///
/// `' W '` -- 3 bytes.
@rodata
final List<u8> wmStrW = const [
  u8(0x20), u8(0x57), u8(0x20),
];

///
/// `' H '` -- 3 bytes.
@rodata
final List<u8> wmStrH = const [
  u8(0x20), u8(0x48), u8(0x20),
];

///
/// `' VA '` -- 4 bytes.
@rodata
final List<u8> wmStrVa = const [
  u8(0x20), u8(0x56), u8(0x41), u8(0x20),
];

///
/// `'WM COMMIT W '` -- 12 bytes.
@rodata
final List<u8> wmStrCommit = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x4F), u8(0x4D), u8(0x4D), u8(0x49), u8(0x54),
  u8(0x20), u8(0x57), u8(0x20),
];

///
/// `' SEQ '` -- 5 bytes.
@rodata
final List<u8> wmStrSeq = const [
  u8(0x20), u8(0x53), u8(0x45), u8(0x51), u8(0x20),
];

/// Field separator: the damage rectangle's opening, INCLUDING its `X` label.
/// The three fields after it are labelled ` Y `, ` W ` and ` H ` and are shared
/// with every other line in this file; only the first needed a label of its
/// own, and it is here rather than as a bare ` DMG ` so that the line does not
/// print `DMG 0000 Y 0000` and leave the reader to work out that the first
/// number was the x.
///
/// `' DMG X '` -- 7 bytes.
@rodata
final List<u8> wmStrDmg = const [
  u8(0x20), u8(0x44), u8(0x4D), u8(0x47), u8(0x20), u8(0x58), u8(0x20),
];

///
/// `'WM FRAME N '` -- 11 bytes.
@rodata
final List<u8> wmStrFrame = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x46), u8(0x52), u8(0x41), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x4E), u8(0x20),
];

///
/// `' PX '` -- 4 bytes.
@rodata
final List<u8> wmStrPx = const [
  u8(0x20), u8(0x50), u8(0x58), u8(0x20),
];

/// Field separator: the pointer position the frame was composed with. **No
/// trailing space, because a ` X ` follows it** -- the first cut of this line
/// had both and printed `CUR  X`, which a field-splitting reader gets wrong.
///
/// `' CUR'` -- 4 bytes.
@rodata
final List<u8> wmStrCur = const [
  u8(0x20), u8(0x43), u8(0x55), u8(0x52),
];

///
/// `' TOP '` -- 5 bytes.
@rodata
final List<u8> wmStrTop = const [
  u8(0x20), u8(0x54), u8(0x4F), u8(0x50), u8(0x20),
];

///
/// `'WM REFUSE C '` -- 12 bytes.
@rodata
final List<u8> wmStrRefuse = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x45),
  u8(0x20), u8(0x43), u8(0x20),
];

///
/// `' OP '` -- 4 bytes.
@rodata
final List<u8> wmStrOp = const [
  u8(0x20), u8(0x4F), u8(0x50), u8(0x20),
];

///
/// `' H '` -- 3 bytes.
@rodata
final List<u8> wmStrHandle = const [
  u8(0x20), u8(0x48), u8(0x20),
];

///
/// `' R '` -- 3 bytes.
@rodata
final List<u8> wmStrRet = const [
  u8(0x20), u8(0x52), u8(0x20),
];

///
/// `'WM STATE A '` -- 11 bytes.
@rodata
final List<u8> wmStrState = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x54), u8(0x45), u8(0x20),
  u8(0x41), u8(0x20),
];

///
/// `' WINS '` -- 6 bytes.
@rodata
final List<u8> wmStrWins = const [
  u8(0x20), u8(0x57), u8(0x49), u8(0x4E), u8(0x53), u8(0x20),
];

///
/// `'wm on | wm off | wm draw\n'` -- 25 bytes.
@rodata
final List<u8> wmStrUsage = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x6F), u8(0x6E), u8(0x20), u8(0x7C), u8(0x20), u8(0x77),
  u8(0x6D), u8(0x20), u8(0x6F), u8(0x66), u8(0x66), u8(0x20), u8(0x7C), u8(0x20), u8(0x77),
  u8(0x6D), u8(0x20), u8(0x64), u8(0x72), u8(0x61), u8(0x77), u8(0x0A),
];


///
/// `'WM PROBE '` -- 9 bytes.
@rodata
final List<u8> wmStrProbe = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x52), u8(0x4F), u8(0x42), u8(0x45), u8(0x20),
];

// ---------------------------------------------------------------------------
// Constants.
// ---------------------------------------------------------------------------

/// Syscall 23 -- `wmsurface(descPtr) -> address | count | refusal`.
///
/// **23 and not 21, and the registry is why.** 20 is `mouse` (ADR-0042), and
/// `docs/syscall-registry.md` records that 21 (`shmaddr`, ADR-0045) and 22
/// (`shmpublish`, ADR-0046) are taken by two lines that had not merged when
/// this one forked. 23 is the first number no branch, no worktree and no
/// uncommitted tree claims. This is the fourth time this table has settled a
/// collision the same way, and the rule is the one it has applied three times
/// already: the cheaper move is the correct one, and the number is not the
/// interface.
const int wmSysSurfaceNo = 23;

/// Windows the compositor can hold at once.
///
/// **Two, and the number is DERIVED rather than picked**, exactly as
/// [chanPorts] is. A window's pixels live in a shared region and [shmMax] is 2,
/// so two windows is the most that can simultaneously exist on this machine. A
/// larger table would be storage nothing on this kernel can reach.
const int wmMaxWindows = 2;

/// Operations a descriptor's word 0 may carry.
const int wmOpAttach = 1;
const int wmOpCommit = 2;

/// Words in a descriptor. 8 x u64 = 64 = [chanMsgBytes], and see this file's
/// header §2 for why that equality is the point rather than a coincidence.
const int wmDescWords = 8;
const int wmDescBytes = 64;

// Descriptor word indices. ATTACH and COMMIT overlay words 2..5 because a
// geometry and a damage rectangle are the same four numbers; which one a word
// means is decided by word 0 and by nothing else.
const int wmDescOp = 0;
const int wmDescHandle = 1;
const int wmDescX = 2;
const int wmDescY = 3;
const int wmDescW = 4;
const int wmDescH = 5;

/// ATTACH: bytes per row inside the region. 0 means "w * 4", which is what a
/// client that has nothing to say about padding sends.
const int wmDescStride = 6;

/// ATTACH: byte offset of pixel (0, 0) within the region. **An OFFSET and not
/// a pointer** -- see this file's header §3.
const int wmDescOffset = 7;

/// COMMIT: the client's own frame counter, echoed into the transcript so that
/// "the compositor composed the frame the client thought it committed" is a
/// comparison of two independently produced numbers.
const int wmDescSeq = 6;

/// Border drawn around every window, in pixels, on all four sides.
const int wmBorder = 3;

/// The desktop. Not black, so that "nothing was drawn" and "the background was
/// drawn" are different pixels: a harness that expected a window and found
/// 0x00000000 would otherwise be unable to tell a compositor that did nothing
/// from one that filled correctly with black.
const int wmColorDesktop = 0x00184060;

/// The border of the window on TOP, and of everything under it. The difference
/// is what makes stacking order a pixel a person can see and a harness can
/// assert.
const int wmColorFocus = 0x00F0F0F0;
const int wmColorUnfocus = 0x00505860;

// ---------------------------------------------------------------------------
// Return values. `file.dart`'s convention (ADR-0019 §3) and `shm.dart`'s: one
// floor, every code above it distinct, so ONE comparison separates an answer
// from a refusal. An ATTACH answer is an address inside [vmShmBase, vmShmEnd)
// and a COMMIT answer is a frame count; both are far below the floor.
// ---------------------------------------------------------------------------

const int wmRetFloor = 0xFFFFFFFFFFFFFF00;

/// The caller is not a process. A capability table belongs to a process slot
/// and an M9 payload has none.
const int wmRetNoProc = 0xFFFFFFFFFFFFFFFE;

/// The compositor is not running. **A client is told rather than quietly
/// ignored**: "there is no display server" is a different situation from "your
/// arguments were wrong" and a client that could not tell them apart would
/// retry forever.
const int wmRetOff = 0xFFFFFFFFFFFFFFFD;

/// The descriptor pointer is not readable from ring 3.
const int wmRetBadPtr = 0xFFFFFFFFFFFFFFFC;

/// Word 0 is not an operation this kernel knows.
const int wmRetBadOp = 0xFFFFFFFFFFFFFFFB;

/// The handle's index is out of range, or names an EMPTY capability slot.
/// **This is what a forged handle gets.**
const int wmRetBadCap = 0xFFFFFFFFFFFFFFFA;

/// The handle names a live capability whose generation does not match the
/// region's -- authority over a region that has since died.
const int wmRetStale = 0xFFFFFFFFFFFFFFF9;

/// The geometry is zero, or does not fit on the screen with its border.
const int wmRetBadGeom = 0xFFFFFFFFFFFFFFF8;

/// Every window slot is taken.
const int wmRetNoSpace = 0xFFFFFFFFFFFFFFF7;

/// A COMMIT for a handle that was never attached, or whose window has since
/// been taken over by a different region.
const int wmRetNoWin = 0xFFFFFFFFFFFFFFF6;

/// **The region is too small for the geometry the descriptor claims.** The
/// last byte the compositor would read, `offset + (h - 1) * stride + w * 4`,
/// is past the end of the region. Refused rather than clamped, because a
/// clamp would turn a client's arithmetic error into a kernel that reads
/// whatever the next region happens to hold.
const int wmRetSmall = 0xFFFFFFFFFFFFFFF5;

/// This process already holds a window and asks for a second one. One surface
/// per client, which is all [wmMaxWindows] can honestly promise with two
/// clients.
const int wmRetTwice = 0xFFFFFFFFFFFFFFF4;

// ---------------------------------------------------------------------------
// Storage.
// ---------------------------------------------------------------------------

/// Meta words, then [wmMaxWindows] window records of [wmWinWords].
///
/// **This block is LAST in `kmain.o`'s `.bss`, and that is the rule rather than
/// an accident.** ADR-0031 §4.3 rule 5 asked for the newest block to be last so
/// that no earlier block moves, and ADR-0033 §6.3(a) corrected the wording
/// after M20 and S0 each hit it. `shmStore` was last until now; `part 'wm.dart'`
/// comes after `part 'shm.dart'` in `kmain.dart` for exactly this reason, and
/// `d2-compositor/run.sh` asserts the total rather than trusting it.
const int wmMetaWords = 24;
const int wmMetaBytes = 192;
const int wmWinWords = 8;
const int wmWinBytes = 64;
const int wmWinOffset = 192;
const int wmStoreBytes = 320; // 192 + 2 * 64

@bss
final Bss wmStore = const Bss(bytes: wmStoreBytes);

// Meta word indices.

/// 1 while the compositor owns the framebuffer. Read by [fbPutc] on every byte
/// the kernel prints, so it is one load and a compare and nothing else.
const int wmMetaActive = 0;

/// Composition passes completed.
const int wmMetaFrames = 1;

/// Pixels written by the LAST pass. A number, so that D6's damage milestone has
/// something to make smaller (GAP-0301).
const int wmMetaPixels = 2;

/// Accepted attaches, accepted commits, refusals.
const int wmMetaAttaches = 3;
const int wmMetaCommits = 4;
const int wmMetaRefusals = 5;

/// The window currently on top. `wmMaxWindows` means "nothing is".
const int wmMetaTop = 6;

/// Live windows.
const int wmMetaLive = 7;

// --- D5b: the pointer, and what it is doing to a window -------------------

/// The window being dragged, PLUS ONE, so that 0 means "none" and window 0 is
/// expressible. The idiom `procCurrent` uses for the same reason.
const int wmMetaDrag = 8;

/// Where inside the dragged window the pointer grabbed it. The window origin is
/// `pointer - grab` for the whole drag, which is what stops the window jumping
/// under the cursor on the first motion.
const int wmMetaGrabX = 9;
const int wmMetaGrabY = 10;

/// Where the pointer was when this compositor last painted it. **Not the same
/// as `mouseWordX/Y`**, which is where the pointer IS: the difference between
/// the two is the rectangle that has to be repainted, and keeping the painted
/// position here rather than reading the live one twice is what makes the
/// erase-then-draw pair use the same coordinates.
const int wmMetaCurX = 11;
const int wmMetaCurY = 12;

/// Drag steps applied, and raises performed. Counters, so `wm` can report that
/// the pointer did something rather than that it could have.
const int wmMetaMoves = 13;
const int wmMetaRaises = 14;

/// The button bitmap at the last tick, so a PRESS can be told from being HELD.
/// A grab must happen on the edge; a grab on every packet would re-grab the
/// window under the pointer mid-drag and the drag would slip.
const int wmMetaButtons = 15;

/// **The re-entrancy guard.** Held for the whole of a frame by the two painter
/// ENTRY POINTS -- [wmCompose] and [wmPointerTick] -- and checked by
/// [wmPointerTick]. Everything they call runs underneath it. See the D5b section header for why one word is a real
/// mutual exclusion on this kernel and what it becomes on two cores.
const int wmMetaBusy = 16;

/// Pixels written by the last PARTIAL repaint, as [wmMetaPixels] is for a full
/// frame. The number D6 exists to make small, measured on the path that already
/// makes it small.
const int wmMetaRectPixels = 17;

/// Pointer ticks dropped because a composition was in progress. **A dropped
/// tick is a dropped FRAME, not a lost event** -- `mouseApplyX/Y` have already
/// moved the pointer, so the next tick sees the accumulated position.
const int wmMetaDropped = 18;

// Window record word indices.
const int wmWinState = 0;
const int wmWinOwner = 1;
const int wmWinReg = 2;
const int wmWinGen = 3;
const int wmWinGeom = 4; // (x << 48) | (y << 32) | (w << 16) | h
const int wmWinStride = 5;
const int wmWinOffsetW = 6;
const int wmWinSeq = 7;

const int wmWinFree = 0;
const int wmWinLive = 1;

// ---------------------------------------------------------------------------
// Accessors. The shape `shm.dart`, `chan.dart` and `user.dart` all use.
// ---------------------------------------------------------------------------

@bare
u64 wmMetaBase() {
  return Bss.addressOf(wmStore);
}

@bare
u64 wmWinBase(u64 w) {
  return Bss.addressOf(wmStore) + u64(wmWinOffset) + (w * u64(wmWinBytes));
}

@bare
u64 wmMeta(u64 i) {
  return Pointer<u64>.fromAddress(wmMetaBase() + (i << u64(3))).value;
}

@bare
void wmSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(wmMetaBase() + (i << u64(3))).value = v;
}

@bare
void wmBumpMeta(u64 i) {
  wmSetMeta(i, wmMeta(i) + u64(1));
}

@bare
u64 wmWin(u64 w, u64 i) {
  return Pointer<u64>.fromAddress(wmWinBase(w) + (i << u64(3))).value;
}

@bare
void wmSetWin(u64 w, u64 i, u64 v) {
  Pointer<u64>.fromAddress(wmWinBase(w) + (i << u64(3))).value = v;
}

/// Zeroes the block. `.bss` is not zeroed by anything in this kernel and this
/// prints nothing -- `m1-interrupts` asserts the entire 544-byte boot capture,
/// so one diagnostic line here would break a green milestone. Same argument as
/// [fbInit], [shmInit] and [shellInit] before it.
@bare
void wmInit() {
  final u64 base = Bss.addressOf(wmStore);
  u64 o = u64(0);
  while (o < u64(wmStoreBytes)) {
    Pointer<u64>.fromAddress(base + o).value = u64(0);
    o = o + u64(8);
  }
  wmSetMeta(u64(wmMetaTop), u64(wmMaxWindows));
}

/// 1 while the compositor owns the framebuffer.
///
/// **[fbPutc] calls this on every byte the kernel prints.** It is a load, a
/// shift and a compare, and it is why the gate lives in one word of `.bss`
/// rather than in a flag somebody has to remember to pass.
@bare
u64 wmActive() {
  return wmMeta(u64(wmMetaActive));
}

// ---------------------------------------------------------------------------
// Geometry, packed four-to-a-word.
//
// One word rather than four, because a window record is 8 words and 4 of them
// spent on numbers that never exceed 800 would leave no room for the stride,
// the offset and the sequence number. Every field is 16 bits and the screen is
// 800x600, so nothing here can overflow -- and [wmSysSurface] refuses a
// geometry that does not fit the SCREEN long before it packs it, so the 16-bit
// field is not what enforces the bound.
// ---------------------------------------------------------------------------

@bare
u64 wmPackGeom(u64 x, u64 y, u64 w, u64 h) {
  return (x << u64(48)) | (y << u64(32)) | (w << u64(16)) | h;
}

@bare
u64 wmGeomX(u64 g) {
  return (g >> u64(48)) & u64(0xFFFF);
}

@bare
u64 wmGeomY(u64 g) {
  return (g >> u64(32)) & u64(0xFFFF);
}

@bare
u64 wmGeomW(u64 g) {
  return (g >> u64(16)) & u64(0xFFFF);
}

@bare
u64 wmGeomH(u64 g) {
  return g & u64(0xFFFF);
}

// ---------------------------------------------------------------------------
// Drawing.
//
// EVERY LOOP HERE IS ONE LEVEL DEEP, and that is a language constraint rather
// than a style: `dcc` rejects syntactically nested `while` loops
// (docs/known-gaps.md GAP-0068). `fb.dart` met this first and answered it with
// [fbFillRow] plus [fbFill]; this file answers it the same way three more
// times -- rect over row, window over rect, frame over window.
// ---------------------------------------------------------------------------

/// Fills the axis-aligned rectangle ([x], [y], [w], [h]) with [color].
///
/// No bounds check: every caller has already been through [wmFits], which
/// refuses a geometry that does not fit the screen WITH its border, so a
/// rectangle that reaches here is inside the visible area by construction.
@bare
void wmFillRect(u64 x, u64 y, u64 w, u64 h, u64 color) {
  u64 i = u64(0);
  while (i < h) {
    fbFillRow(x, y + i, w, color);
    i = i + u64(1);
  }
}

/// Reads the pixel at byte offset [off] within the region whose frame vector is
/// at [vec].
///
/// **This is the one place a client's memory is read, and it goes through the
/// FRAME VECTOR rather than through any address space.** The compositor is in
/// the kernel and the kernel's low 128 MiB is identity-mapped, so a region's
/// physical page is directly addressable here; the client's own mapping of that
/// same region is irrelevant and is never consulted. That is what makes this
/// safe while `shmpublish`'s handoff is landing on another line: a region that
/// is mapped in NO address space still has frames, and this reads the frames.
///
/// **A pixel never straddles a page**, because [wmAttach] refuses a stride or
/// an offset that is not a multiple of 4 and 4096 is. Without that refusal this
/// function would need a second page lookup for the high bytes and would be
/// silently wrong for exactly one pixel per page.
@bare
u64 wmRegionPixel(u64 vec, u64 off) {
  final u64 phys = shmVec(vec, off >> u64(vmPageShift));
  return Pointer<u32>.fromAddress(phys + (off & u64(vmPageMask))).value.toU64();
}

/// Blits row [py] of window [wI] from its region onto the framebuffer.
@bare
void wmBlitRow(u64 wI, u64 py) {
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 x = wmGeomX(g);
  final u64 y = wmGeomY(g);
  final u64 w = wmGeomW(g);
  final u64 vec = shmReg(wmWin(wI, u64(wmWinReg)), u64(shmRegVec));
  final u64 rowOff =
      wmWin(wI, u64(wmWinOffsetW)) + (py * wmWin(wI, u64(wmWinStride)));
  u64 px = u64(0);
  while (px < w) {
    fbPutPixel(x + px, y + py, wmRegionPixel(vec, rowOff + (px << u64(2))));
    px = px + u64(1);
  }
}

/// Draws window [wI] -- border first, then its client's pixels -- and returns
/// how many pixels it wrote.
///
/// [focus] selects the border colour, and the border is the whole of this
/// compositor's window decoration. **It is not ornament.** Two windows drawn
/// from two client regions could in principle both be the same colour by a
/// client bug; a border the COMPOSITOR draws, in a colour that is a function of
/// stacking position, is the compositor's own statement about which window is
/// on top, in pixels, at a coordinate a harness can name.
@bare
u64 wmDrawWindow(u64 wI, u64 focus) {
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 x = wmGeomX(g);
  final u64 y = wmGeomY(g);
  final u64 w = wmGeomW(g);
  final u64 h = wmGeomH(g);
  final u64 b = u64(wmBorder);
  // [wmBorderColor], not a second copy of the same two constants: the partial
  // repaint path resolves the same pixel through the same function, and a seam
  // between a composed frame and a repainted rectangle is exactly what two
  // copies of this would produce.
  final u64 c = wmBorderColor(focus);
  wmFillRect(x - b, y - b, w + b + b, b, c); // top edge
  wmFillRect(x - b, y + h, w + b + b, b, c); // bottom edge
  wmFillRect(x - b, y, b, h, c); // left edge
  wmFillRect(x + w, y, b, h, c); // right edge
  u64 py = u64(0);
  while (py < h) {
    wmBlitRow(wI, py);
    py = py + u64(1);
  }
  return (w + b + b) * (h + b + b);
}

/// One composition pass: desktop, then every window bottom-up, then the
/// pointer.
///
/// **A FULL FRAME, EVERY TIME, and GAP-0301 records that as a cost rather than
/// a design.** The damage rectangle a client commits is carried, validated and
/// printed and then not used to make this smaller. Composing only the damage is
/// D6 in `docs/design/display-protocol.md`, and its exit criterion is a
/// pixels-per-frame count that must come out SMALL -- [wmMetaPixels] is that
/// count, printed on every frame, so the milestone that makes it small has
/// something to make smaller and a harness that can see it happen.
///
/// **The pointer is drawn LAST and is not part of any window.** It is composed
/// on top of everything and it is never read back into a client's region, so
/// there is no save-under to get wrong. `mouseDrawCursor` is D1's, unchanged.
@bare
void wmCompose() {
  if (wmActive() < u64(1)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  // THE RE-ENTRANCY GUARD, held for the whole frame. IRQ12 can fire in the
  // middle of this -- a commit composes inside a syscall with interrupts on --
  // and [wmPointerTick] returns without painting while it is set.
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmReap();
  fbFill(u64(wmColorDesktop));
  u64 px = u64(fbWidth) * u64(fbHeight);
  final u64 top = wmMeta(u64(wmMetaTop));
  // Bottom-up. Everything that is NOT the top window, in slot order, and then
  // the top window over all of it -- which is what makes the overlap show the
  // top window's pixels and is the whole of D5.
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (i != top) {
      px = px + wmDrawWindow(i, u64(0));
    }
    i = i + u64(1);
  }
  if (top < u64(wmMaxWindows)) {
    px = px + wmDrawWindow(top, u64(1));
  }
  final u64 cx = mouseState(u64(mouseWordX));
  final u64 cy = mouseState(u64(mouseWordY));
  mouseDrawCursor(cx, cy);
  wmSetMeta(u64(wmMetaCurX), cx);
  wmSetMeta(u64(wmMetaCurY), cy);
  wmSetMeta(u64(wmMetaBusy), u64(0));
  wmSetMeta(u64(wmMetaPixels), px);
  wmBumpMeta(u64(wmMetaFrames));
  uartWrite(Rodata.addressOf(wmStrFrame), u64(11));
  uartPutHex(wmMeta(u64(wmMetaFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(px, u64(8));
  uartWrite(Rodata.addressOf(wmStrTop), u64(5));
  uartPutHex(top, u64(1));
  uartWrite(Rodata.addressOf(wmStrCur), u64(4));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(cx, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(cy, u64(4));
  uartNewline();
}

// ---------------------------------------------------------------------------
// Syscall 23 -- wmsurface(descPtr)
// ---------------------------------------------------------------------------

/// Reads word [i] of the 64-byte descriptor at ring-3 address [ptr].
///
/// Safe because the CALLER'S page tables are still installed inside a syscall
/// -- the same fact `chanCopyIn` relies on -- and because [chanOwnsRead] has
/// already proved every page of the range is reachable from ring 3.
@bare
u64 wmDesc(u64 ptr, u64 i) {
  return Pointer<u64>.fromAddress(ptr + (i << u64(3))).value;
}

/// `'WM REFUSE C 17 OP <op> H <handle> R <code>'`, and the refusal in `rax`.
///
/// Every refusal prints, exactly as `shm.dart`'s and `chan.dart`'s do, so that
/// the kernel's account and the program's account are two independent
/// statements a transcript can compare.
@bare
void wmRefuse(u64 frame, u64 op, u64 h, u64 code) {
  wmBumpMeta(u64(wmMetaRefusals));
  uartWrite(Rodata.addressOf(wmStrRefuse), u64(12));
  uartPutHex(u64(wmSysSurfaceNo), u64(2));
  uartWrite(Rodata.addressOf(wmStrOp), u64(4));
  uartPutHex(op, u64(16));
  uartWrite(Rodata.addressOf(wmStrHandle), u64(3));
  uartPutHex(h, u64(16));
  uartWrite(Rodata.addressOf(wmStrRet), u64(3));
  uartPutHex(code, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), code);
}

/// Resolves a ring-3 handle against THE CALLER'S OWN capability table and
/// returns the region index, or [wmMaxWindows] and above on failure.
///
/// **This is [shmSysMap]'s validation, read-only and in the same order**, and
/// it is deliberately a re-derivation rather than a call into `shm.dart`: this
/// path installs nothing, maps nothing and changes no capability, so it must
/// not go through a function whose job is to do all three. What it borrows is
/// the ORDER -- index in range, slot non-empty, generation matches the
/// capability, region live, generation matches the region -- because that order
/// is what makes a forged handle land on [wmRetBadCap] and a handle to a dead
/// region land on [wmRetStale], which are different things a client acts on
/// differently.
///
/// Returns [shmMax] for "bad capability" and [shmMax] + 1 for "stale", which
/// the two callers turn into the two refusal codes. A `u64` out-parameter would
/// be the honest shape and `@bare` DCDart has no out-parameters (GAP-0023's
/// family), so the sentinel is the idiom `vmWalk` and `fbFindVgaBar` already
/// use.
@bare
u64 wmResolve(u64 h) {
  final u64 s = procCurrent();
  final u64 ci = shmHandleIndex(h);
  if (ci >= u64(shmCapsPerProc)) {
    return u64(shmMax);
  }
  final u64 c = shmCap(s, ci);
  if ((c & u64(15)) < u64(1)) {
    return u64(shmMax);
  }
  if (shmCapGen(c) != shmHandleGen(h)) {
    return u64(shmMax) + u64(1);
  }
  final u64 r = shmCapReg(c);
  if (r >= u64(shmMax)) {
    return u64(shmMax);
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    return u64(shmMax) + u64(1);
  }
  if (shmReg(r, u64(shmRegGen)) != shmCapGen(c)) {
    return u64(shmMax) + u64(1);
  }
  return r;
}

/// 1 if a window of [w] x [h] at ([x], [y]) fits on the screen WITH its border.
///
/// The border is part of the bound and not an afterthought: a window flush
/// against the left edge would have [wmDrawWindow] fill a rectangle starting at
/// `x - wmBorder`, and `x - wmBorder` in unsigned arithmetic is not a small
/// negative number, it is 2^64 minus three. That is the bug this function
/// exists to make unreachable.
@bare
u64 wmFits(u64 x, u64 y, u64 w, u64 h) {
  if (w < u64(1)) {
    return u64(0);
  }
  if (h < u64(1)) {
    return u64(0);
  }
  if (x < u64(wmBorder)) {
    return u64(0);
  }
  if (y < u64(wmBorder)) {
    return u64(0);
  }
  if ((x + w + u64(wmBorder)) > u64(fbWidth)) {
    return u64(0);
  }
  if ((y + h + u64(wmBorder)) > u64(fbHeight)) {
    return u64(0);
  }
  return u64(1);
}

/// The window slot owned by process [id], or [wmMaxWindows] if it has none.
@bare
u64 wmWindowOf(u64 id) {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWin(i, u64(wmWinState)) == u64(wmWinLive)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        return i;
      }
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// The first free window slot, or [wmMaxWindows].
@bare
u64 wmFreeWindow() {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWin(i, u64(wmWinState)) != u64(wmWinLive)) {
      return i;
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// `op = wmOpAttach`. Gives the calling process a window and tells it where its
/// own address space has the region it drew the descriptor's handle from.
///
/// **The answer is an ADDRESS THE KERNEL COMPUTED AND HANDED OVER**, not one
/// the client derived. See this file's header §3: that is the whole reason this
/// operation exists rather than the client simply committing.
@bare
void wmAttach(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 x = wmDesc(ptr, u64(wmDescX));
  final u64 y = wmDesc(ptr, u64(wmDescY));
  final u64 w = wmDesc(ptr, u64(wmDescW));
  final u64 hh = wmDesc(ptr, u64(wmDescH));
  final u64 off = wmDesc(ptr, u64(wmDescOffset));
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetStale));
    return;
  }
  if (wmFits(x, y, w, hh) < u64(1)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetBadGeom));
    return;
  }
  // A stride of 0 means "no padding", which is what a client that has nothing
  // to say about layout sends. Anything else must be at least a row wide.
  u64 stride = wmDesc(ptr, u64(wmDescStride));
  if (stride < u64(1)) {
    stride = w << u64(2);
  }
  if (stride < (w << u64(2))) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetBadGeom));
    return;
  }
  // 4-BYTE ALIGNMENT IS A CORRECTNESS REQUIREMENT, not tidiness. See
  // [wmRegionPixel]: it is what makes a pixel unable to straddle a page.
  if ((stride & u64(3)) > u64(0)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetBadGeom));
    return;
  }
  if ((off & u64(3)) > u64(0)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetBadGeom));
    return;
  }
  // THE LAST BYTE THIS COMPOSITOR WOULD READ MUST BE INSIDE THE REGION.
  // Refused rather than clamped: a clamp would turn a client's arithmetic
  // error into a kernel that reads whatever the next region happens to hold.
  final u64 need = off + ((hh - u64(1)) * stride) + (w << u64(2));
  if (need > (shmReg(r, u64(shmRegPages)) << u64(vmPageShift))) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetSmall));
    return;
  }
  if (wmWindowOf(id) < u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetTwice));
    return;
  }
  final u64 slot = wmFreeWindow();
  if (slot >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetNoSpace));
    return;
  }
  wmSetWin(slot, u64(wmWinOwner), id);
  wmSetWin(slot, u64(wmWinReg), r);
  wmSetWin(slot, u64(wmWinGen), shmReg(r, u64(shmRegGen)));
  wmSetWin(slot, u64(wmWinGeom), wmPackGeom(x, y, w, hh));
  wmSetWin(slot, u64(wmWinStride), stride);
  wmSetWin(slot, u64(wmWinOffsetW), off);
  wmSetWin(slot, u64(wmWinSeq), u64(0));
  wmSetWin(slot, u64(wmWinState), u64(wmWinLive));
  // THE NEWEST SURFACE IS ON TOP. That is the whole of this compositor's
  // stacking policy, it is one line, and `display-protocol.md` §0.1 is explicit
  // that window management is compositor policy and not protocol.
  wmSetMeta(u64(wmMetaTop), slot);
  wmSetMeta(u64(wmMetaLive), wmMeta(u64(wmMetaLive)) + u64(1));
  wmBumpMeta(u64(wmMetaAttaches));
  final u64 va = shmRegionVa(r);
  uartWrite(Rodata.addressOf(wmStrAttach), u64(12));
  uartPutHex(slot, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(wmStrGen), u64(5));
  uartPutHex(shmReg(r, u64(shmRegGen)), u64(8));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(x, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(y, u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(w, u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(hh, u64(4));
  uartWrite(Rodata.addressOf(wmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), va);
}

/// `op = wmOpCommit`. "This frame is ready." Composes, and returns.
///
/// **THE RETURN IS THE RELEASE.** See this file's header §2: composition
/// happens inside the caller's own syscall, so by the time `rax` is written the
/// compositor has finished reading the region and the client may draw into it
/// again. Nothing on this machine can block (GAP-0141), so the alternative --
/// telling the client later -- would need a queue, a wakeup and a sixth process
/// state, and none of the three exists. GAP-0303 records what that costs.
@bare
void wmCommit(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 slot = wmWindowOf(id);
  if (slot >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetNoWin));
    return;
  }
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetStale));
    return;
  }
  // The handle must name the region this window was attached from. A client
  // that created a second region and committed it against the first window's
  // slot would otherwise have the compositor read the wrong pixels and report
  // the right ones.
  if (wmWin(slot, u64(wmWinReg)) != r) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetNoWin));
    return;
  }
  if (wmWin(slot, u64(wmWinGen)) != shmReg(r, u64(shmRegGen))) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetStale));
    return;
  }
  final u64 seq = wmDesc(ptr, u64(wmDescSeq));
  wmSetWin(slot, u64(wmWinSeq), seq);
  wmBumpMeta(u64(wmMetaCommits));
  uartWrite(Rodata.addressOf(wmStrCommit), u64(12));
  uartPutHex(slot, u64(1));
  uartWrite(Rodata.addressOf(wmStrSeq), u64(5));
  uartPutHex(seq, u64(8));
  uartWrite(Rodata.addressOf(wmStrDmg), u64(7));
  uartPutHex(wmDesc(ptr, u64(wmDescX)), u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(wmDesc(ptr, u64(wmDescY)), u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(wmDesc(ptr, u64(wmDescW)), u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(wmDesc(ptr, u64(wmDescH)), u64(4));
  uartNewline();
  wmCompose();
  userSetFrame(frame, u64(userFrameRax), wmMeta(u64(wmMetaFrames)));
}

/// The syscall itself.
///
/// **No guard in `user.dart`'s dispatcher, exactly as M20's three and M21's
/// four have none**: this handler asks [shmCallerId] itself and refuses with
/// [wmRetNoProc], so "the caller is not a process" reaches ring 3 as a NAMED
/// value rather than as M9's opaque all-ones. A capability table belongs to a
/// process slot and an M9 payload has none.
@bare
void wmSysSurface(u64 frame) {
  final u64 ptr = userFrame(frame, u64(userFrameRdi));
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    wmRefuse(frame, u64(0), ptr, u64(wmRetNoProc));
    return;
  }
  if (wmActive() < u64(1)) {
    wmRefuse(frame, u64(0), ptr, u64(wmRetOff));
    return;
  }
  // [chanOwnsRead] and not a private copy of it. The check is "every page of
  // this range is reachable from ring 3", it is the same question `chansend`
  // asks of the same size of buffer, and a second implementation of a
  // privilege check is a second thing that can go stale. The size agreement is
  // structural rather than lucky: [wmDescBytes] IS [chanMsgBytes] (header §2).
  if (chanOwnsRead(ptr, u64(wmDescBytes)) < u64(1)) {
    wmRefuse(frame, u64(0), ptr, u64(wmRetBadPtr));
    return;
  }
  final u64 op = wmDesc(ptr, u64(wmDescOp));
  if (op == u64(wmOpAttach)) {
    wmAttach(frame, ptr, id);
    return;
  }
  if (op == u64(wmOpCommit)) {
    wmCommit(frame, ptr, id);
    return;
  }
  wmRefuse(frame, op, wmDesc(ptr, u64(wmDescHandle)), u64(wmRetBadOp));
}

// ---------------------------------------------------------------------------
// The shell face: `wm on`, `wm off`, `wm draw`, `wm`.
//
// **THERE IS NO `help` LINE FOR IT, AND THAT IS DELIBERATE.** `shellStrHelp` is
// 2224 bytes and five byte-exact serial goldens plus `m3-shell`'s screen golden
// contain it verbatim (GAP-0105, GAP-0115), so one line here moves six goldens
// by substitution. M18 added three commands with no help line, M20 added none
// and D1 did the same; this does too, and GAP-0304 records the cost, which is
// that the command is undiscoverable from the shell itself.
// ---------------------------------------------------------------------------

/// Takes the framebuffer. Prints `WM ON BASE <base> PITCH <pitch> BG <colour>`,
/// which is what a harness reads to know where to dump pixels from -- the
/// address THE KERNEL FOUND, never one the harness assumed. `m5-pci` and
/// `d1-mouse` established that discipline.
@bare
void wmOn() {
  if (fbState(u64(fbStateBase)) < u64(1)) {
    uartWrite(Rodata.addressOf(fbStrNoDev), u64(11));
    uartNewline();
    return;
  }
  wmSetMeta(u64(wmMetaActive), u64(1));
  uartWrite(Rodata.addressOf(wmStrOn), u64(11));
  uartPutHex(fbState(u64(fbStateBase)), u64(8));
  uartWrite(Rodata.addressOf(wmStrPitch), u64(7));
  uartPutHex(fbState(u64(fbStatePitch)), u64(8));
  uartWrite(Rodata.addressOf(wmStrBg), u64(4));
  uartPutHex(u64(wmColorDesktop), u64(8));
  uartNewline();
  wmCompose();
}

/// Gives the framebuffer back to the text console. The console's cursor is
/// homed, because the pixels under it are the compositor's and not the
/// console's -- leaving the cursor where it was would have the next line of
/// output appear in the middle of a composed frame.
@bare
void wmOff() {
  wmSetMeta(u64(wmMetaActive), u64(0));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
  uartWrite(Rodata.addressOf(wmStrOff), u64(14));
  uartPutHex(wmMeta(u64(wmMetaFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(wmMeta(u64(wmMetaPixels)), u64(8));
  uartNewline();
}

/// `WM STATE A <active> WINS <live> N <frames> PX <lastpixels> TOP <top>`, plus
/// one line per live window.
@bare
void wmReport() {
  wmReap();
  uartWrite(Rodata.addressOf(wmStrState), u64(11));
  uartPutHex(wmActive(), u64(1));
  uartWrite(Rodata.addressOf(wmStrWins), u64(6));
  uartPutHex(wmMeta(u64(wmMetaLive)), u64(1));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(wmMeta(u64(wmMetaPixels)), u64(8));
  uartWrite(Rodata.addressOf(wmStrTop), u64(5));
  uartPutHex(wmMeta(u64(wmMetaTop)), u64(1));
  uartWrite(Rodata.addressOf(wmStrMoves), u64(7));
  uartPutHex(wmMeta(u64(wmMetaMoves)), u64(8));
  uartWrite(Rodata.addressOf(wmStrRaises), u64(8));
  uartPutHex(wmMeta(u64(wmMetaRaises)), u64(8));
  uartWrite(Rodata.addressOf(wmStrDrops), u64(7));
  uartPutHex(wmMeta(u64(wmMetaDropped)), u64(8));
  uartNewline();
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    wmReportWindow(i);
    i = i + u64(1);
  }
}

/// One `WM ATTACH`-shaped line per live window, so that the state a harness
/// asserts after the fact has the same field names as the events it asserted
/// while they happened.
@bare
void wmReportWindow(u64 i) {
  if (wmWin(i, u64(wmWinState)) != u64(wmWinLive)) {
    return;
  }
  final u64 g = wmWin(i, u64(wmWinGeom));
  uartWrite(Rodata.addressOf(wmStrAttach), u64(12));
  uartPutHex(i, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(wmWin(i, u64(wmWinReg)), u64(1));
  uartWrite(Rodata.addressOf(wmStrGen), u64(5));
  uartPutHex(wmWin(i, u64(wmWinGen)), u64(8));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(wmGeomX(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(wmGeomY(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(wmGeomW(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(wmGeomH(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrSeq), u64(5));
  uartPutHex(wmWin(i, u64(wmWinSeq)), u64(8));
  uartNewline();
}

/// `wm draw` -- recompose without a client having committed anything. Exists so
/// that a harness can move the pointer and then ask for a frame, which is what
/// puts the cursor at a DERIVED position on a screen whose windows were
/// composed earlier.
@bare
void wmDrawCmd() {
  if (wmActive() < u64(1)) {
    wmRefuseOff();
    return;
  }
  wmCompose();
}

/// `WM STATE A 0 ...` and nothing drawn -- the answer to `wm draw` while the
/// compositor is off. A refusal a person can read, rather than silence.
@bare
void wmRefuseOff() {
  wmBumpMeta(u64(wmMetaRefusals));
  uartWrite(Rodata.addressOf(wmStrRefuse), u64(12));
  uartPutHex(u64(wmSysSurfaceNo), u64(2));
  uartWrite(Rodata.addressOf(wmStrOp), u64(4));
  uartPutHex(u64(0), u64(16));
  uartWrite(Rodata.addressOf(wmStrHandle), u64(3));
  uartPutHex(u64(0), u64(16));
  uartWrite(Rodata.addressOf(wmStrRet), u64(3));
  uartPutHex(u64(wmRetOff), u64(16));
  uartNewline();
}

/// `wm ...` usage.
@bare
void wmUsage() {
  uartWrite(Rodata.addressOf(wmStrUsage), u64(25));
}
///
/// `'WM MOVE W '` -- 10 bytes.
@rodata
final List<u8> wmStrMove = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4D), u8(0x4F), u8(0x56), u8(0x45), u8(0x20), u8(0x57),
  u8(0x20),
];

///
/// `'WM REAP W '` -- 10 bytes.
@rodata
final List<u8> wmStrReap = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x50), u8(0x20), u8(0x57),
  u8(0x20),
];

/// `'WM RAISE W '` -- 11 bytes.
@rodata
final List<u8> wmStrRaise = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x41), u8(0x49), u8(0x53), u8(0x45), u8(0x20),
  u8(0x57), u8(0x20),
];

///
/// `' FROM '` -- 6 bytes.
@rodata
final List<u8> wmStrFrom = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x4F), u8(0x4D), u8(0x20),
];

///
/// `' MOVES '` -- 7 bytes.
@rodata
final List<u8> wmStrMoves = const [
  u8(0x20), u8(0x4D), u8(0x4F), u8(0x56), u8(0x45), u8(0x53), u8(0x20),
];

///
/// `' RAISES '` -- 8 bytes.
@rodata
final List<u8> wmStrRaises = const [
  u8(0x20), u8(0x52), u8(0x41), u8(0x49), u8(0x53), u8(0x45), u8(0x53), u8(0x20),
];

///
/// `' DROPS '` -- 7 bytes.
@rodata
final List<u8> wmStrDrops = const [
  u8(0x20), u8(0x44), u8(0x52), u8(0x4F), u8(0x50), u8(0x53), u8(0x20),
];


// ---------------------------------------------------------------------------
// D5b -- WINDOW MOVE AND RAISE, DRIVEN BY THE POINTER.
//
// ---------------------------------------------------------------------------
// WHERE THIS RUNS, AND WHY IT COULD NOT RUN ANYWHERE ELSE
// ---------------------------------------------------------------------------
// [wmPointerTick] is called from [mouseComplete], which is called from the
// IRQ12 handler. That is not where anybody would put a compositor by choice;
// it is the only place a drag can be noticed on this machine.
//
// The shell is NOT RUNNING while a client is. `shellProcRun` calls `procStart`
// and does not return until every process it launched has exited, so between
// "two surfaces are on the screen" and "the clients are gone" there is no
// command loop to poll a pointer from. Timer and pointer interrupts are the
// only code that runs in that window. A compositor that could only act from a
// shell command could only move a window when there was nothing on the screen
// to move.
//
// **So this is a partial repaint or it is nothing.** A full frame is 480,000
// pixel stores plus the windows (GAP-0301) and a pointer emits packets at
// roughly 100 Hz. [wmRepaintRect] exists for that reason, and the drag path
// repaints TWO window-sized rectangles -- where the window was and where it now
// is -- rather than the screen.
//
// ---------------------------------------------------------------------------
// THE ONE RE-ENTRANCY HAZARD, AND THE ONE WORD THAT CLOSES IT
// ---------------------------------------------------------------------------
// IRQ12 can fire while [wmCompose] is halfway through a frame, because a
// commit's composition runs in a syscall with interrupts ON. Two painters in
// one framebuffer produce a torn frame; worse, a pointer tick that changed
// [wmMetaTop] or a window's geometry mid-compose would have the second half of
// the frame drawn against a different stacking order than the first.
//
// [wmMetaBusy] is held for the whole of a frame by the two painter ENTRY POINTS
// -- [wmCompose] and [wmPointerTick] -- and checked by [wmPointerTick], which
// returns immediately if it is set. **On this single-core kernel that is a real
// mutual exclusion and not an approximation**: the interrupt gate clears IF, so
// the tick's test-and-return cannot itself be interrupted, and there is no
// second CPU to observe a stale value. GAP-0307 records what it becomes on two
// cores, which is the same thing `chan.dart`'s publication point becomes
// (GAP-0205): a real acquire/release pair.
//
// **A dropped tick is a dropped MOVE, not a lost EVENT.** `mouseApplyX/Y` have
// already updated the pointer position by the time this is called, so the next
// packet's tick sees the accumulated position and the window catches up. What
// is lost is an intermediate frame.
// ---------------------------------------------------------------------------

/// "no window covers this pixel". A colour is 24 bits, so all-ones cannot be
/// one; the alternative shape -- an out-parameter -- is not expressible in
/// `@bare` DCDart (GAP-0023's family) and `vmWalk` and `fbFindVgaBar` already
/// use a sentinel for the same reason.
const int wmNoPixel = 0xFFFFFFFFFFFFFFFF;

/// 1 if window [wI] is live AND the region it was attached to is still that
/// region.
///
/// **THIS IS NOT DEFENSIVE PROGRAMMING, IT IS A LIFETIME.** A region dies with
/// its LAST CAPABILITY (`shm.dart`), and a client's capability goes when the
/// client does -- `procCleanup` drops it on the exit path and on the fault path
/// alike. This compositor holds no capability of its own (ADR-0050 §4: it reads
/// the frame vector, it does not map the region), so **the instant a client
/// exits, its window's pixels are gone and the frames are back in the
/// allocator.** Reading `shmRegVec` of a dead region then is reading a freed
/// page as a table of physical addresses, and the first thing it produced when
/// this was missing was a `FAULT 0D` at the shell prompt, from a pointer packet
/// that arrived one second after `PROC END`.
///
/// The GENERATION is checked and not only the state, because a region slot is
/// reused: a window still naming slot 0 after slot 0 has died and been recreated
/// by somebody else would render a stranger's pixels.
@bare
u64 wmWindowUsable(u64 wI) {
  // THE BOUND, and it is here rather than at the call sites because this is the
  // one function every painter goes through. `wmMetaTop` is `wmMaxWindows` when
  // nothing is on top, `wmGrab` reads that into `was`, and one path then passes
  // it here; `wmStore` is the LAST block in .bss, so an unbounded index reads
  // off the end of the kernel's mutable statics. Found by reading the code.
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (wmWin(wI, u64(wmWinState)) != u64(wmWinLive)) {
    return u64(0);
  }
  final u64 r = wmWin(wI, u64(wmWinReg));
  if (r >= u64(shmMax)) {
    return u64(0);
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    return u64(0);
  }
  if (shmReg(r, u64(shmRegGen)) != wmWin(wI, u64(wmWinGen))) {
    return u64(0);
  }
  return u64(1);
}

/// Closes every window whose region has died, and is called at the top of every
/// painter.
///
/// **Lazily, at paint time, rather than from `procCleanup`.** Hooking the
/// teardown path would be the tidier design and it is the wrong trade here:
/// `proc.dart` is a file three other lines are editing, the hook would have to
/// fire on the exit path AND the fault path AND the kill path, and the property
/// wanted is not "the window is closed promptly" but "nothing ever paints from
/// a dead region". A check at the top of the painters is exactly that property,
/// in one place, and it cannot be bypassed by a teardown path nobody hooked.
@bare
void wmReap() {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    wmReapOne(i);
    i = i + u64(1);
  }
}

/// One window's half of [wmReap].
@bare
void wmReapOne(u64 i) {
  if (wmWin(i, u64(wmWinState)) != u64(wmWinLive)) {
    return;
  }
  if (wmWindowUsable(i) > u64(0)) {
    return;
  }
  wmSetWin(i, u64(wmWinState), u64(wmWinFree));
  wmSetMeta(u64(wmMetaLive), wmMeta(u64(wmMetaLive)) - u64(1));
  if (wmMeta(u64(wmMetaTop)) == i) {
    wmSetMeta(u64(wmMetaTop), u64(wmMaxWindows));
  }
  if (wmMeta(u64(wmMetaDrag)) == (i + u64(1))) {
    wmSetMeta(u64(wmMetaDrag), u64(0));
  }
  uartWrite(Rodata.addressOf(wmStrReap), u64(10));
  uartPutHex(i, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(wmWin(i, u64(wmWinReg)), u64(1));
  uartWrite(Rodata.addressOf(wmStrGen), u64(5));
  uartPutHex(wmWin(i, u64(wmWinGen)), u64(8));
  uartNewline();
}

/// The colour window [wI] puts at ([x], [y]), or [wmNoPixel] if it does not
/// cover that pixel.
///
/// **The comparisons are written to survive unsigned arithmetic.** `x + b < wx`
/// rather than `x < wx - b`: `wx - b` where `wx < b` is not a small negative
/// number, it is 2^64 minus something, and the whole rectangle would test as
/// covering the screen. [wmFits] refuses a geometry with `x < wmBorder` so the
/// bad case cannot arise, but a bound that is only correct because of a check
/// somewhere else is a bound that breaks when that check moves.
@bare
u64 wmWindowPixel(u64 wI, u64 x, u64 y, u64 focus) {
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(wmNoPixel);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 wx = wmGeomX(g);
  final u64 wy = wmGeomY(g);
  final u64 ww = wmGeomW(g);
  final u64 wh = wmGeomH(g);
  final u64 b = u64(wmBorder);
  if (x + b < wx) {
    return u64(wmNoPixel);
  }
  if (y + b < wy) {
    return u64(wmNoPixel);
  }
  if (x >= wx + ww + b) {
    return u64(wmNoPixel);
  }
  if (y >= wy + wh + b) {
    return u64(wmNoPixel);
  }
  // Inside the decorated rectangle. Border or content?
  if (x < wx) {
    return wmBorderColor(focus);
  }
  if (y < wy) {
    return wmBorderColor(focus);
  }
  if (x >= wx + ww) {
    return wmBorderColor(focus);
  }
  if (y >= wy + wh) {
    return wmBorderColor(focus);
  }
  final u64 vec = shmReg(wmWin(wI, u64(wmWinReg)), u64(shmRegVec));
  final u64 off = wmWin(wI, u64(wmWinOffsetW)) +
      ((y - wy) * wmWin(wI, u64(wmWinStride))) + ((x - wx) << u64(2));
  return wmRegionPixel(vec, off);
}

/// Bright for the window on top, dim for everything under it.
@bare
u64 wmBorderColor(u64 focus) {
  if (focus > u64(0)) {
    return u64(wmColorFocus);
  }
  return u64(wmColorUnfocus);
}

/// What belongs at ([x], [y]) with the current stack: the topmost window that
/// covers it, or the desktop.
///
/// **This is the same picture [wmCompose] paints, resolved one pixel at a time
/// instead of one window at a time**, and the two must agree or a partial
/// repaint leaves a seam. They agree by construction rather than by inspection:
/// both read the border colour from [wmBorderColor], both read content through
/// [wmRegionPixel], and `d2-compositor/run.sh` probes pixels inside a repainted
/// rectangle against the same host model it probes a composed frame with.
@bare
u64 wmPixelAt(u64 x, u64 y) {
  final u64 top = wmMeta(u64(wmMetaTop));
  u64 c = u64(wmNoPixel);
  if (top < u64(wmMaxWindows)) {
    c = wmWindowPixel(top, x, y, u64(1));
  }
  if (c != u64(wmNoPixel)) {
    return c;
  }
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (i != top) {
      c = wmWindowPixel(i, x, y, u64(0));
      if (c != u64(wmNoPixel)) {
        return c;
      }
    }
    i = i + u64(1);
  }
  return u64(wmColorDesktop);
}

/// Repaints one scanline segment from [wmPixelAt].
@bare
void wmRepaintRow(u64 x, u64 y, u64 w) {
  u64 i = u64(0);
  while (i < w) {
    fbPutPixel(x + i, y, wmPixelAt(x + i, y));
    i = i + u64(1);
  }
}

/// Repaints the rectangle ([x], [y], [w], [h]), clipped to the screen, and
/// returns how many pixels it wrote.
///
/// **Clipped rather than refused**, unlike everything in `wmAttach`: a repaint
/// rectangle is not a caller's argument, it is a rectangle this file computed
/// from a window that has just moved, and the honest thing to do with the part
/// of it that is off-screen is not to draw it.
@bare
u64 wmRepaintRect(u64 x, u64 y, u64 w, u64 h) {
  if (x >= u64(fbWidth)) {
    return u64(0);
  }
  if (y >= u64(fbHeight)) {
    return u64(0);
  }
  u64 ww = w;
  if (x + ww > u64(fbWidth)) {
    ww = u64(fbWidth) - x;
  }
  u64 hh = h;
  if (y + hh > u64(fbHeight)) {
    hh = u64(fbHeight) - y;
  }
  u64 j = u64(0);
  while (j < hh) {
    wmRepaintRow(x, y + j, ww);
    j = j + u64(1);
  }
  return ww * hh;
}

/// Repaints the whole of window [wI]'s DECORATED rectangle -- border included.
@bare
u64 wmRepaintWindow(u64 wI) {
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 b = u64(wmBorder);
  return wmRepaintRect(wmGeomX(g) - b, wmGeomY(g) - b,
      wmGeomW(g) + b + b, wmGeomH(g) + b + b);
}

/// The topmost live window covering ([x], [y]), or [wmMaxWindows].
///
/// **"Topmost window under the cursor" is the whole of this compositor's input
/// policy**, and `display-protocol.md` §0.1 is explicit that window management
/// is compositor policy rather than protocol. There is no focus that survives
/// the pointer leaving, no click-to-focus versus focus-follows-mouse, and no
/// keyboard focus at all -- the keyboard still belongs to the shell.
@bare
u64 wmHit(u64 x, u64 y) {
  final u64 top = wmMeta(u64(wmMetaTop));
  if (top < u64(wmMaxWindows)) {
    if (wmWindowPixel(top, x, y, u64(1)) != u64(wmNoPixel)) {
      return top;
    }
  }
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (i != top) {
      if (wmWindowPixel(i, x, y, u64(0)) != u64(wmNoPixel)) {
        return i;
      }
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// Clamps a proposed window origin so the window stays wholly on screen WITH
/// its border, and returns it packed as `(x << 32) | y`.
///
/// Packed because `@bare` DCDart has no tuples and no out-parameters, and two
/// functions returning half an answer each would read the drag state twice.
@bare
u64 wmClampOrigin(u64 x, u64 y, u64 w, u64 h) {
  final u64 b = u64(wmBorder);
  u64 cx = x;
  u64 cy = y;
  if (cx < b) {
    cx = b;
  }
  if (cy < b) {
    cy = b;
  }
  if (cx + w + b > u64(fbWidth)) {
    cx = u64(fbWidth) - b - w;
  }
  if (cy + h + b > u64(fbHeight)) {
    cy = u64(fbHeight) - b - h;
  }
  return (cx << u64(32)) | cy;
}

/// A left-button PRESS: raise the window under the pointer and start a drag.
///
/// The grab offset is `cursor - origin`, so the window does not jump: the point
/// under the pointer stays under the pointer for the whole drag, which is the
/// one behaviour a person notices immediately when it is wrong.
@bare
void wmGrab(u64 x, u64 y) {
  final u64 hit = wmHit(x, y);
  if (hit >= u64(wmMaxWindows)) {
    return;
  }
  final u64 was = wmMeta(u64(wmMetaTop));
  final u64 g = wmWin(hit, u64(wmWinGeom));
  wmSetMeta(u64(wmMetaGrabX), x - wmGeomX(g));
  wmSetMeta(u64(wmMetaGrabY), y - wmGeomY(g));
  wmSetMeta(u64(wmMetaDrag), hit + u64(1));
  if (was == hit) {
    return; // already on top: nothing changed on screen
  }
  wmSetMeta(u64(wmMetaTop), hit);
  wmBumpMeta(u64(wmMetaRaises));
  // RAISING CHANGES BOTH WINDOWS: the one coming up, and the one whose border
  // just went from bright to dim. Repainting both decorated rectangles is the
  // smallest correct answer with two windows and it is what `wmMaxWindows`
  // being 2 buys.
  u64 px = wmRepaintWindow(was);
  px = px + wmRepaintWindow(hit);
  wmSetMeta(u64(wmMetaRectPixels), px);
  uartWrite(Rodata.addressOf(wmStrRaise), u64(11));
  uartPutHex(hit, u64(1));
  uartWrite(Rodata.addressOf(wmStrFrom), u64(6));
  uartPutHex(was, u64(1));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(px, u64(8));
  uartNewline();
}

/// One drag step: move the dragged window so the grabbed point follows the
/// pointer, and repaint where it WAS and where it now IS.
@bare
void wmDragStep(u64 x, u64 y) {
  final u64 drag = wmMeta(u64(wmMetaDrag));
  if (drag < u64(1)) {
    return;
  }
  final u64 wI = drag - u64(1);
  if (wmWindowUsable(wI) < u64(1)) {
    wmSetMeta(u64(wmMetaDrag), u64(0));
    return;
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 w = wmGeomW(g);
  final u64 h = wmGeomH(g);
  final u64 gx = wmMeta(u64(wmMetaGrabX));
  final u64 gy = wmMeta(u64(wmMetaGrabY));
  // UNSIGNED: a pointer left of the grab offset means the window wants a
  // negative origin, which is 0 here and then the clamp's minimum.
  u64 nx = u64(0);
  if (x > gx) {
    nx = x - gx;
  }
  u64 ny = u64(0);
  if (y > gy) {
    ny = y - gy;
  }
  final u64 packed = wmClampOrigin(nx, ny, w, h);
  final u64 cx = packed >> u64(32);
  final u64 cy = packed & u64(0xFFFFFFFF);
  if (cx == wmGeomX(g)) {
    if (cy == wmGeomY(g)) {
      return; // the clamp put it back where it was: nothing to repaint
    }
  }
  // REPAINT WHERE IT WAS FIRST, WITH THE NEW GEOMETRY ALREADY INSTALLED. The
  // order matters and it is the opposite of the obvious one: [wmPixelAt] asks
  // where the window IS, so a repaint of the vacated rectangle done BEFORE the
  // move would paint the window back into it.
  final u64 b = u64(wmBorder);
  final u64 ox = wmGeomX(g) - b;
  final u64 oy = wmGeomY(g) - b;
  wmSetWin(wI, u64(wmWinGeom), wmPackGeom(cx, cy, w, h));
  u64 px = wmRepaintRect(ox, oy, w + b + b, h + b + b);
  px = px + wmRepaintWindow(wI);
  wmSetMeta(u64(wmMetaRectPixels), px);
  wmBumpMeta(u64(wmMetaMoves));
  uartWrite(Rodata.addressOf(wmStrMove), u64(10));
  uartPutHex(wI, u64(1));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(cx, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(cy, u64(4));
  uartWrite(Rodata.addressOf(wmStrFrom), u64(6));
  uartPutHex(wmGeomX(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(wmGeomY(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(px, u64(8));
  uartNewline();
}

/// Called from [mouseComplete], on the IRQ12 path, once per decoded packet.
///
/// **Silent and immediate when the compositor is off**, which is every boot
/// that never types `wm on`: one load of [wmMetaActive] and a return. `d1-mouse`
/// injects twelve packets through this path and its byte-exact transcript does
/// not move.
@bare
void wmPointerTick() {
  if (wmActive() < u64(1)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  // THE RE-ENTRANCY GUARD. See this section's header: a commit's composition
  // runs in a syscall with interrupts on, and two painters in one framebuffer
  // is a torn frame drawn against two different stacking orders.
  if (wmMeta(u64(wmMetaBusy)) > u64(0)) {
    wmBumpMeta(u64(wmMetaDropped));
    return;
  }
  wmSetMeta(u64(wmMetaBusy), u64(1));
  // THE LIFETIME CHECK, before anything reads a frame vector. See [wmReap].
  wmReap();
  final u64 x = mouseState(u64(mouseWordX));
  final u64 y = mouseState(u64(mouseWordY));
  final u64 btn = mouseState(u64(mouseWordButtons)) & u64(1);
  final u64 was = wmMeta(u64(wmMetaButtons));
  if (btn > u64(0)) {
    if (was < u64(1)) {
      wmGrab(x, y);
    }
  } else {
    wmSetMeta(u64(wmMetaDrag), u64(0));
  }
  wmSetMeta(u64(wmMetaButtons), btn);
  wmDragStep(x, y);
  // THE POINTER ITSELF. The rectangle it vacated is repainted from
  // [wmPixelAt] -- there is no save-under, so what was under the arrow is
  // recomputed rather than remembered, and an arrow that moved over a window
  // leaves the window rather than a hole.
  final u64 ox = wmMeta(u64(wmMetaCurX));
  final u64 oy = wmMeta(u64(wmMetaCurY));
  //
  // The count is BOUND rather than discarded, because `dcc` refuses a
  // non-void call as a statement -- and the rule is right here: the erase is
  // the one repaint whose pixel count nobody would otherwise look at, and it is
  // the one that runs on every packet.
  u64 erased = u64(0);
  if (ox != x) {
    erased = wmRepaintRect(ox, oy, u64(mouseCursorCols), u64(mouseCursorRows));
  } else {
    if (oy != y) {
      erased = wmRepaintRect(ox, oy, u64(mouseCursorCols), u64(mouseCursorRows));
    }
  }
  wmSetMeta(u64(wmMetaRectPixels),
      wmMeta(u64(wmMetaRectPixels)) + erased);
  mouseDrawCursor(x, y);
  wmSetMeta(u64(wmMetaCurX), x);
  wmSetMeta(u64(wmMetaCurY), y);
  wmSetMeta(u64(wmMetaBusy), u64(0));
}
