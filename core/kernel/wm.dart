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
//   * DAMAGE DRIVES THE COMMIT PASS. A commit paints the damage rectangle the
//     client named, mapped into screen space, and nothing else -- unless the
//     damage is the whole surface, in which case the decorated window (border
//     included) is what is painted, because the border is compositor-owned
//     and a first present has to put it on the screen. `wm on` and `wm draw`
//     still compose a full frame: they have no damage to honour. ADR-0052,
//     which is D6. The count that makes this falsifiable is [wmMetaPixels].
//   * A LEFT PRESS IS DELIVERED TO THE WINDOW UNDER THE POINTER. [wmGrab]
//     already hit-tests; D7 (ADR-0055) enqueues a packed surface-relative
//     event on that window's ring and ring 3 pops it through syscall 25.
//     A click on the desktop enqueues nothing. The same press also writes
//     keyboard focus (D9 / ADR-0062): [wmMetaFocus] is the hit window
//     PLUS ONE, or 0 after a desktop click or a reap. A RIGHT press is
//     compositor policy (ADR-0070): it paints a popover and does not
//     enqueue. Under `wm de`, attach / move / resize enqueue configure
//     and a focus change enqueues enter/leave (ADR-0142). Without
//     `wm de` the press queue is still press-only (d7-click).
//   * TITLE BARS ARE CHROME, OFF BY DEFAULT. When `wm chrome` is on, each
//     decorated window gets an 18-pixel compositor-drawn caption on the top
//     of its content (ADR-0075). Off, the picture is the border-only one
//     d2-compositor photographs. Under `wm de` a title press (not close
//     or min) starts a drag and a body press does not (ADR-0111). An SE
//     edge press resizes: geom w/h change, same shm, clip (ADR-0121).
//     Without `wm de` a press on the window still starts a drag, so
//     d2-compositor is unmoved. No font. Configure is ADR-0142.
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
/// **Four, and the number is DERIVED rather than picked.** A window's
/// pixels live in a shared region and [shmMax] is 4 (ADR-0109), so four
/// windows is the most that can simultaneously exist on this machine.
/// d2-compositor asserts the two numbers stay equal.
const int wmMaxWindows = 4;

/// Operations a descriptor's word 0 may carry.
const int wmOpAttach = 1;
const int wmOpCommit = 2;
// 3..8 live in wmext.dart (offer/take/sub/seat/move/seatget).

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

/// This process already has this region attached as a window. A second
/// ATTACH of the same handle is refused. A second *region* is allowed:
/// one client may own every [wmMaxWindows] slot (main + menu + more).
/// A fifth attach is [wmRetNoSpace].
const int wmRetTwice = 0xFFFFFFFFFFFFFFF4;

// ---------------------------------------------------------------------------
// Storage.
// ---------------------------------------------------------------------------

/// Meta words, then [wmMaxWindows] window records of [wmWinWords].
///
/// **This block sat immediately before `kbdqStore` until D7 (ADR-0055)
/// put `wmeventStore` last.** ADR-0031 §4.3 rule 5 asked for the newest
/// block to be last so that no earlier block moves. `part 'wm.dart'`
/// still comes after `part 'shm.dart'` in `kmain.dart`, and
/// `d2-compositor/run.sh` still measures this block to `kbdqStore`'s start.
const int wmMetaWords = 24;
const int wmMetaBytes = 192;
const int wmWinWords = 8;
const int wmWinBytes = 64;
const int wmWinOffset = 192;
const int wmStoreBytes = 448; // 192 + 4 * 64

@bss
final Bss wmStore = const Bss(bytes: wmStoreBytes);

// Meta word indices.

/// 1 while the compositor owns the framebuffer. Read by [fbPutc] on every byte
/// the kernel prints, so it is one load and a compare and nothing else.
const int wmMetaActive = 0;

/// Composition passes completed.
const int wmMetaFrames = 1;

/// Pixels written by the LAST pass. D6's number: a 16x16 commit must print
/// 256 here, not 480,000. ADR-0052.
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
/// under the cursor on the first motion. Under `wm de` a resize (ADR-0121)
/// sets bit 32 of grab-X ([wmResizeMark]); the low 32 bits stay the
/// in-window offset. Not a new word.
const int wmMetaGrabX = 9;
const int wmMetaGrabY = 10;

/// Bit 32 of [wmMetaGrabX]. Set when the armed drag is a resize, not
/// a move. Window offsets fit in 16 bits; this bit cannot collide.
const int wmResizeMark = 0x100000000;

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

/// Pixels written by the last pointer-driven partial repaint. Commits report
/// through [wmMetaPixels] instead: a commit is a frame, a drag step is not.
const int wmMetaRectPixels = 17;

/// Pointer ticks dropped because a composition was in progress. **A dropped
/// tick is a dropped FRAME, not a lost event** -- `mouseApplyX/Y` have already
/// moved the pointer, so the next tick sees the accumulated position.
const int wmMetaDropped = 18;

/// Keyboard focus. PLUS ONE, the same idiom as [wmMetaDrag]: 0 means the
/// shell (and any ring-3 reader) may drain syscall 24; window 0 is
/// expressible as 1. Chrome used word 19. D9 (ADR-0062). The popover
/// uses 21 (visible) and 22 (packed origin). Word 23 is guest osgfx
/// (ADR-0096). No new `@bss`.
const int wmMetaFocus = 20;

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
const int wmWinMin = 2;

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

/// The live seat-0 focus word, or 0 if nothing owns the keyboard.
///
/// **Stale focus is cleared here**, not only in [wmReapOne]: the drain
/// and syscall 24 both ask this, and a window that died between paints
/// must not keep the shell from the keys. PLUS ONE on the way in, 0
/// on the way out -- [kbdqDrainToShell] skips when the answer is not 0.
/// Seat 1 lives in the high byte (ADR-0186); this returns seat 0 only.
@bare
u64 wmFocusLive() {
  return wmSeatFocusLive(u64(0));
}

/// Sets seat-0 keyboard focus to window [wI], or none when [wI] is
/// [wmMaxWindows]. Preserves seat 1. Under `wm de` a change is also a
/// wmevent enter/leave (ADR-0142). A dead slot is none.
@bare
void wmFocusTo(u64 wI) {
  wmSeatFocusSet(u64(0), wI);
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

/// Premultiplied SRC_OVER for the transparent DESK panel surface.
///
/// Ordinary FRAME clients predate alpha and remain direct copies. DESK clears
/// its full-width carrier to transparent zero and paints premultiplied glass
/// islands into it, so copying that carrier would turn every gap and rounded
/// corner black.
@bare
u64 wmPanelSrcOver(u64 src, u64 dst) {
  final u64 a = (src >> u64(24)) & u64(0xFF);
  if (a < u64(1)) {
    return dst & u64(0x00FFFFFF);
  }
  if (a >= u64(255)) {
    return src & u64(0x00FFFFFF);
  }
  final u64 inv = u64(255) - a;
  final u64 sr = (src >> u64(16)) & u64(0xFF);
  final u64 sg = (src >> u64(8)) & u64(0xFF);
  final u64 sb = src & u64(0xFF);
  final u64 dr = (dst >> u64(16)) & u64(0xFF);
  final u64 dg = (dst >> u64(8)) & u64(0xFF);
  final u64 db = dst & u64(0xFF);
  final u64 r = sr + ((dr * inv) ~/ u64(255));
  final u64 g = sg + ((dg * inv) ~/ u64(255));
  final u64 b = sb + ((db * inv) ~/ u64(255));
  return ((r & u64(0xFF)) << u64(16)) |
      ((g & u64(0xFF)) << u64(8)) |
      (b & u64(0xFF));
}

/// Blits row [py] of window [wI] from its region onto the framebuffer.
/// [py] is a surface row; buffer sampling multiplies by the window's
/// integer scale (ADR-0185).
@bare
void wmBlitRow(u64 wI, u64 py) {
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 x = wmAbsX(wI);
  final u64 y = wmAbsY(wI);
  final u64 w = wmGeomW(g);
  final u64 vec = shmReg(wmWin(wI, u64(wmWinReg)), u64(shmRegVec));
  final u64 scale = wmWinScaleOf(wI);
  final u64 stride = wmWinStrideOf(wI);
  final u64 rowOff = wmWin(wI, u64(wmWinOffsetW)) +
      ((py * scale) * stride);
  final u64 panel = wmIsPanel(wI);
  u64 x0 = u64(0);
  u64 x1 = w;
  u64 h = wmGeomH(g);
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    /* Desk strip (taskbar FRAME) is shorter than a titled window —
     * blit every row. Titled clients still skip the caption band. */
    if (h > u64(wmChromeH)) {
      if (py < u64(wmTitleH)) {
        x1 = u64(0);
      }
    }
    /* Corner inset must not reopen a title-band skip (x1==0). That
     * stamped client fill over Graphite pearl/glyphs for py < radius. */
    if (x1 > x0) {
      if (py < u64(wmGfxRadius)) {
        x0 = u64(wmGfxRadius);
        if (w > u64(wmGfxRadius)) {
          x1 = w - u64(wmGfxRadius);
        }
      }
      if (py >= (h - u64(wmGfxRadius))) {
        x0 = u64(wmGfxRadius);
        if (w > u64(wmGfxRadius)) {
          x1 = w - u64(wmGfxRadius);
        }
      }
    }
  }
  u64 px = x0;
  while (px < x1) {
    final u64 boff = rowOff + ((px * scale) << u64(2));
    final u64 src = wmRegionPixel(vec, boff);
    if (panel > u64(0)) {
      /* Resolve against the stable wallpaper layer, not the previous scanout
       * value. Repeated panel commits must be idempotent rather than building
       * alpha on top of last frame's glass. */
      u64 under = wmDeskPixel(x + px, y + py);
      if (under == u64(wmNoPixel)) {
        under =
            Volatile<u32>.fromAddress(fbPixelAddr(x + px, y + py)).value.toU64();
      }
      fbPutPixel(x + px, y + py, wmPanelSrcOver(src, under));
    } else {
      fbPutPixel(x + px, y + py, src);
    }
    px = px + u64(1);
  }
}

/// Draws window [wI] -- border first, then its client's pixels, then the
/// title strip if chrome is on -- and returns how many pixels it wrote.
///
/// [focus] selects the border colour. The border is the stacking statement;
/// the title (ADR-0075) is chrome and is off unless [wmMetaChrome] is set,
/// so a default-off compose's count and pixels do not move. Two windows
/// drawn from two client regions could in principle both be the same
/// colour by a client bug; a border the COMPOSITOR draws, in a colour that
/// is a function of stacking position, is the compositor's own statement
/// about which window is on top, in pixels, at a coordinate a harness
/// can name.
@bare
u64 wmDrawWindow(u64 wI, u64 focus) {
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 x = wmAbsX(wI);
  final u64 y = wmAbsY(wI);
  final u64 w = wmGeomW(g);
  final u64 h = wmGeomH(g);
  final u64 b = u64(wmBorder);
  // [wmBorderColor], not a second copy of the same two constants: the partial
  // repaint path resolves the same pixel through the same function, and a seam
  // between a composed frame and a repainted rectangle is exactly what two
  // copies of this would produce.
  final u64 c = wmBorderColor(focus);
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    wmFillRect(x - b, y - b, w + b + b, b, c); // top edge
    wmFillRect(x - b, y + h, w + b + b, b, c); // bottom edge
    wmFillRect(x - b, y, b, h, c); // left edge
    wmFillRect(x + w, y, b, h, c); // right edge
  }
  u64 py = u64(0);
  while (py < h) {
    wmBlitRow(wI, py);
    py = py + u64(1);
  }
  // Title overwrites the top content rows. Not added to the return: those
  // pixels were already counted in the blit, and a chrome-on compose of
  // a windowed desktop must not invent a second full-window bill.
  final u64 titlePx = wmTitleDraw(wI);
  return (w + b + b) * (h + b + b);
}

/// Records [px], releases the re-entrancy guard, and prints `WM FRAME`.
///
/// The pointer has already been drawn (or left alone) by the caller. This is
/// the one place a composition pass -- full or damage-limited -- becomes a
/// numbered frame, so a future path cannot print the line without also
/// publishing the count the harness derives.
@bare
void wmPublishFrameQ(u64 px, u64 quiet) {
  final u64 cx = mouseState(u64(mouseWordX));
  final u64 cy = mouseState(u64(mouseWordY));
  wmSetMeta(u64(wmMetaCurX), cx);
  wmSetMeta(u64(wmMetaCurY), cy);
  wmSetMeta(u64(wmMetaBusy), u64(0));
  wmSetMeta(u64(wmMetaPixels), px);
  wmBumpMeta(u64(wmMetaFrames));
  if (quiet > u64(0)) {
    return;
  }
  uartWrite(Rodata.addressOf(wmStrFrame), u64(11));
  uartPutHex(wmMeta(u64(wmMetaFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(px, u64(8));
  uartWrite(Rodata.addressOf(wmStrTop), u64(5));
  uartPutHex(wmMeta(u64(wmMetaTop)), u64(1));
  uartWrite(Rodata.addressOf(wmStrCur), u64(4));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(cx, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(cy, u64(4));
  uartNewline();
}

@bare
void wmPublishFrame(u64 px) {
  wmPublishFrameQ(px, u64(0));
}

/// One FULL composition pass: desktop, then every window bottom-up, then the
/// pointer.
///
/// Used by `wm on` and `wm draw`, which have no damage rectangle to honour.
/// A commit does NOT come through here -- it comes through [wmComposeRect],
/// which paints only what the client said changed. ADR-0052.
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
  u64 px = u64(0);
  /* ADR-0183: under `wm gfx`, session paints wallpaper (+ title/taskbar
   * overlays without body fill), then Dart blits every FRAME surface so
   * FILES/SET/DESK shm survives the tick. Without gfx, solid desk + blit. */
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    wmGfxKick();
    osgfx_guest_tick();
  } else {
    fbFill(u64(wmColorDesktop));
  }
  px = fbGeomWidth() * fbGeomHeight();
  final u64 top = wmMeta(u64(wmMetaTop));
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (i != top) {
      if (wmWinOverlay(i) < u64(1)) {
        px = px + wmDrawWindow(i, u64(0));
      }
    }
    i = i + u64(1);
  }
  if (top < u64(wmMaxWindows)) {
    if (wmWinOverlay(top) < u64(1)) {
      px = px + wmDrawWindow(top, u64(1));
    }
  }
  i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWinOverlay(i) > u64(0)) {
      if (wmOverlayParked(i) < u64(1)) {
        px = px + wmDrawWindow(i, u64(0));
      }
    }
    i = i + u64(1);
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    wmSessionOwedClear();
    wmGfxChromeStamp();
  }
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    px = px + wmChromeDraw();
    px = px + wmPopDraw();
    px = px + wmDePopDraw();
  }
  final u64 cx = mouseState(u64(mouseWordX));
  final u64 cy = mouseState(u64(mouseWordY));
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    wmPointerEnsure();
    wmPointerPlace(cx, cy);
  } else {
    mouseDrawCursor(cx, cy);
  }
  wmPublishFrame(px);
}

/// A DAMAGE-LIMITED pass: one screen rectangle, resolved through [wmPixelAt],
/// and the pointer only if it intersects that rectangle.
///
/// This is D6. [wmRepaintRect] is the painter D5b already had for a drag;
/// a commit is the same picture over a rectangle the CLIENT named rather than
/// one the pointer vacated. The pointer is redrawn only on intersection
/// because a full-frame compose is the thing that erases it -- a damage rect
/// that misses it leaves the pixels IRQ12 already put there.
///
/// **No flip, so the per-buffer trap in `display-protocol.md` §3.5 does not
/// apply.** This compositor writes the visible scanout in place. Damage is
/// therefore "what changed in the one buffer", not "what the back buffer is
/// missing from two frames ago."
@bare
void wmComposeRect(u64 x, u64 y, u64 w, u64 h) {
  if (wmActive() < u64(1)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmReap();
  final u64 px = wmRepaintRect(x, y, w, h);
  wmMaybeDrawPointer(x, y, w, h);
  wmPublishFrame(px);
}

/// Redraws the pointer if its bounding box intersects ([x], [y], [w], [h]).
///
/// A damage pass that misses the cursor leaves the pixels IRQ12 already put
/// there; one that hits it has just overwritten part of the arrow.
@bare
void wmMaybeDrawPointer(u64 x, u64 y, u64 w, u64 h) {
  final u64 cx = mouseState(u64(mouseWordX));
  final u64 cy = mouseState(u64(mouseWordY));
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    final u64 cw = u64(wmPtrW);
    final u64 ch = u64(wmPtrH);
    if ((cx + cw) > x) {
      if ((cy + ch) > y) {
        if (cx < (x + w)) {
          if (cy < (y + h)) {
            wmPointerPlace(cx, cy);
          }
        }
      }
    }
  } else {
    final u64 cw = u64(mouseCursorCols);
    final u64 ch = u64(mouseCursorRows);
    if ((cx + cw) > x) {
      if ((cy + ch) > y) {
        if (cx < (x + w)) {
          if (cy < (y + h)) {
            mouseDrawCursor(cx, cy);
          }
        }
      }
    }
  }
}

/// Damage-limited gfx commit (ADR-0188 §3).
@bare
void wmComposeCommitGfx(u64 slot, u64 full, u64 dx, u64 dy, u64 dw, u64 dh) {
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmReap();
  wmDePrefApply();
  u64 px = u64(0);
  u64 rx = u64(0);
  u64 ry = u64(0);
  u64 rw = u64(0);
  u64 rh = u64(0);
  if (full > u64(0)) {
    px = wmRepaintWindow(slot);
    final u64 g = wmWin(slot, u64(wmWinGeom));
    if (wmIsPanel(slot) > u64(0)) {
      rx = wmAbsX(slot);
      ry = wmAbsY(slot);
      rw = wmGeomW(g);
      rh = wmGeomH(g);
    } else {
      rx = wmAbsX(slot) - u64(wmBorder);
      ry = wmAbsY(slot) - u64(wmBorder);
      rw = wmGeomW(g) + u64(wmBorder) + u64(wmBorder);
      rh = wmGeomH(g) + u64(wmBorder) + u64(wmBorder);
    }
    if (wmMeta(u64(wmMetaTop)) == slot) {
      u64 i = u64(0);
      while (i < u64(wmMaxWindows)) {
        if (i != slot) {
          if (wmWindowUsable(i) > u64(0)) {
            if (wmWinOverlay(i) < u64(1)) {
              px = px + wmRepaintWindow(i);
            }
          }
        }
        i = i + u64(1);
      }
    }
  } else {
    if (wmWindowUsable(slot) > u64(0)) {
      rx = wmAbsX(slot) + dx;
      ry = wmAbsY(slot) + dy;
      rw = dw;
      rh = dh;
      px = wmRepaintRect(rx, ry, rw, rh);
    }
  }
  if (wmPaced() > u64(0)) {
    wmDamageRect(rx, ry, rw, rh);
    wmSetMeta(u64(wmMetaBusy), u64(0));
    return;
  }
  wmPointerRestore();
  wmPointerPlace(mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)));
  wmPublishFrame(px);
}

/// A commit's composition pass. [full] is 1 when the damage is the whole
/// surface: paint this window's decorated rectangle, and -- if this window is
/// on top -- every other live window too, so the window that just lost the
/// top has its border go from bright to dim. That restack is what a full
/// compose used to do for free and what a damage pass of only the new window
/// would leave stale. A partial damage paints one screen rectangle and does
/// not touch anyone else's border.
@bare
void wmComposeCommit(u64 slot, u64 full, u64 dx, u64 dy, u64 dw, u64 dh) {
  if (wmActive() < u64(1)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  /* Under `wm gfx`, honour damage when chrome is fresh; else full compose. */
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (wmGfxChromeFresh() > u64(0)) {
      wmComposeCommitGfx(slot, full, dx, dy, dw, dh);
      return;
    }
    wmCompose();
    return;
  }
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmReap();
  wmDePrefApply();
  u64 px = u64(0);
  if (full > u64(0)) {
    px = wmRepaintWindow(slot);
    if (wmWindowUsable(slot) > u64(0)) {
      final u64 g = wmWin(slot, u64(wmWinGeom));
      final u64 b = u64(wmBorder);
      if (wmIsPanel(slot) > u64(0)) {
        wmMaybeDrawPointer(
            wmAbsX(slot), wmAbsY(slot), wmGeomW(g), wmGeomH(g));
      } else {
        wmMaybeDrawPointer(wmAbsX(slot) - b, wmAbsY(slot) - b,
            wmGeomW(g) + b + b, wmGeomH(g) + b + b);
      }
    }
    if (wmMeta(u64(wmMetaTop)) == slot) {
      u64 i = u64(0);
      while (i < u64(wmMaxWindows)) {
        if (i != slot) {
          if (wmWindowUsable(i) > u64(0)) {
            px = px + wmRepaintWindow(i);
            final u64 g = wmWin(i, u64(wmWinGeom));
            final u64 b = u64(wmBorder);
            if (wmIsPanel(i) > u64(0)) {
              wmMaybeDrawPointer(
                  wmAbsX(i), wmAbsY(i), wmGeomW(g), wmGeomH(g));
            } else {
              wmMaybeDrawPointer(wmAbsX(i) - b, wmAbsY(i) - b,
                  wmGeomW(g) + b + b, wmGeomH(g) + b + b);
            }
          }
        }
        i = i + u64(1);
      }
    }
  } else {
    if (wmWindowUsable(slot) > u64(0)) {
      final u64 x = wmAbsX(slot) + dx;
      final u64 y = wmAbsY(slot) + dy;
      px = wmRepaintRect(x, y, dw, dh);
      wmMaybeDrawPointer(x, y, dw, dh);
    }
  }
  wmPublishFrame(px);
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
  /* Panel strip (ADR-0192): full width, flush bottom, chrome-tall — no border. */
  if (x == u64(0)) {
    if (w == fbGeomWidth()) {
      if (h <= u64(wmChromeH)) {
        if ((y + h) == fbGeomHeight()) {
          return u64(1);
        }
      }
    }
  }
  if (x < u64(wmBorder)) {
    return u64(0);
  }
  if (y < u64(wmBorder)) {
    return u64(0);
  }
  if ((x + w + u64(wmBorder)) > fbGeomWidth()) {
    return u64(0);
  }
  if ((y + h + u64(wmBorder)) > fbGeomHeight()) {
    return u64(0);
  }
  return u64(1);
}

/// The first window slot owned by process [id], or [wmMaxWindows] if it
/// has none. A process may own two slots; this returns the lowest
/// index. Prefer [wmWindowOfRegion] when the handle is known.
@bare
u64 wmWindowOf(u64 id) {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowHeld(i) > u64(0)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        return i;
      }
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// The live window owned by [id] that is attached to region [r], or
/// [wmMaxWindows]. One process can hold two windows; commit and the
/// second attach name the region, not "the" window.
@bare
u64 wmWindowOfRegion(u64 id, u64 r) {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowHeld(i) > u64(0)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        if (wmWin(i, u64(wmWinReg)) == r) {
          return i;
        }
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
    if (wmWindowHeld(i) < u64(1)) {
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
  // to say about layout sends. High 32 bits are the integer buffer scale
  // (0 means 1). ADR-0185.
  u64 rawStride = wmDesc(ptr, u64(wmDescStride));
  u64 scale = rawStride >> u64(32);
  if (scale < u64(1)) {
    scale = u64(1);
  }
  u64 stride = rawStride & u64(0xFFFFFFFF);
  if (stride < u64(1)) {
    stride = (w * scale) << u64(2);
  }
  if (stride < ((w * scale) << u64(2))) {
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
  // Buffer is (w*scale) by (h*scale) when scale > 1.
  final u64 need =
      off + (((hh * scale) - u64(1)) * stride) + ((w * scale) << u64(2));
  if (need > (shmReg(r, u64(shmRegPages)) << u64(vmPageShift))) {
    wmRefuse(frame, u64(wmOpAttach), h, u64(wmRetSmall));
    return;
  }
  // Same region already a live window for this process. A second
  // *region* is a second window. The same handle twice is not.
  if (wmWindowOfRegion(id, r) < u64(wmMaxWindows)) {
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
  wmSetWin(slot, u64(wmWinStride), (scale << u64(32)) | stride);
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
  uartWrite(Rodata.addressOf(wmStrScl), u64(5));
  uartPutHex(scale, u64(1));
  uartWrite(Rodata.addressOf(wmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartNewline();
  // ADR-0142: under `wm de` the granted geom travels the press
  // queue. Without `wm de` the client is not told (d7-click).
  wmeventEnqueueConfigure(slot);
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
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetStale));
    return;
  }
  // Find the window this handle is attached as. One process may own two
  // windows; [wmWindowOf] would always name the first and refuse the menu.
  final u64 slot = wmWindowOfRegion(id, r);
  if (slot >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetNoWin));
    return;
  }
  if (wmWin(slot, u64(wmWinGen)) != shmReg(r, u64(shmRegGen))) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetStale));
    return;
  }
  final u64 seq = wmDesc(ptr, u64(wmDescSeq));
  final u64 g = wmWin(slot, u64(wmWinGeom));
  final u64 ww = wmGeomW(g);
  final u64 hh = wmGeomH(g);
  final u64 dx = wmDesc(ptr, u64(wmDescX));
  final u64 dy = wmDesc(ptr, u64(wmDescY));
  final u64 dw = wmDesc(ptr, u64(wmDescW));
  final u64 dh = wmDesc(ptr, u64(wmDescH));
  // REFUSED RATHER THAN CLAMPED, same as a geometry on attach. A clamp would
  // turn a client's off-by-one into a compositor that paints the wrong
  // rectangle and reports it as the right one. The overflow-safe order is
  // "origin inside, then extent no larger than what remains".
  if (dx >= ww) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadGeom));
    return;
  }
  if (dy >= hh) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadGeom));
    return;
  }
  if (dw < u64(1)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadGeom));
    return;
  }
  if (dh < u64(1)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadGeom));
    return;
  }
  if (dw > (ww - dx)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadGeom));
    return;
  }
  if (dh > (hh - dy)) {
    wmRefuse(frame, u64(wmOpCommit), h, u64(wmRetBadGeom));
    return;
  }
  wmSetWin(slot, u64(wmWinSeq), seq);
  wmBumpMeta(u64(wmMetaCommits));
  uartWrite(Rodata.addressOf(wmStrCommit), u64(12));
  uartPutHex(slot, u64(1));
  uartWrite(Rodata.addressOf(wmStrSeq), u64(5));
  uartPutHex(seq, u64(8));
  uartWrite(Rodata.addressOf(wmStrDmg), u64(7));
  uartPutHex(dx, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(dy, u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(dw, u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(dh, u64(4));
  uartNewline();
  // THE WHOLE SURFACE means the window is new or fully dirty: paint the
  // decorated rectangle so the compositor-owned border appears with it.
  // Anything smaller is the damage the client named, in screen space, and
  // is the count D6 exists to make small.
  if (dx == u64(0)) {
    if (dy == u64(0)) {
      if (dw == ww) {
        if (dh == hh) {
          wmComposeCommit(slot, u64(1), u64(0), u64(0), u64(0), u64(0));
          userSetFrame(frame, u64(userFrameRax), wmMeta(u64(wmMetaFrames)));
          return;
        }
      }
    }
  }
  wmComposeCommit(slot, u64(0), dx, dy, dw, dh);
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
  if (wmExtDispatch(frame, ptr, id, op) > u64(0)) {
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
  gopSessAnnounce();
}

/// Gives the framebuffer back to the text console. The console's cursor is
/// homed, because the pixels under it are the compositor's and not the
/// console's -- leaving the cursor where it was would have the next line of
/// output appear in the middle of a composed frame.
@bare
void wmOff() {
  wmSetMeta(u64(wmMetaActive), u64(0));
  wmSetMeta(u64(wmMetaFocus), u64(0));
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
  if ((wmWin(i, u64(wmWinState)) & u64(0xFF)) != u64(wmWinLive)) {
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
/// `'WM RESIZE W '` -- 12 bytes.
@rodata
final List<u8> wmStrResize = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x53), u8(0x49), u8(0x5A),
  u8(0x45), u8(0x20), u8(0x57), u8(0x20),
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
  // it here; `wmStore` sits immediately before `kbdqStore`, so an unbounded index reads
  // off the end of the kernel's mutable statics. Found by reading the code.
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if ((wmWin(wI, u64(wmWinState)) & u64(0xFF)) != u64(wmWinLive)) {
    return u64(0);
  }
  return wmWindowRegionLive(wI);
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
  if (wmWindowHeld(i) < u64(1)) {
    return;
  }
  if (wmWindowRegionLive(i) > u64(0)) {
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
  final u64 f0 = wmSeatFocusRaw(u64(0));
  final u64 f1 = wmSeatFocusRaw(u64(1));
  if (f0 == (i + u64(1))) {
    wmSeatFocusSet(u64(0), u64(wmMaxWindows));
  }
  if (f1 == (i + u64(1))) {
    wmSeatFocusSet(u64(1), u64(wmMaxWindows));
  }
  uartWrite(Rodata.addressOf(wmStrReap), u64(10));
  uartPutHex(i, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(wmWin(i, u64(wmWinReg)), u64(1));
  uartWrite(Rodata.addressOf(wmStrGen), u64(5));
  uartPutHex(wmWin(i, u64(wmWinGen)), u64(8));
  uartNewline();
}

@extern
external u64 osgfx_pointer_raster(u64 out, u64 w, u64 h);

/// `'WM PTR SKIA'` -- 11 bytes.
@rodata
final List<u8> wmStrPtrSkia = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x54), u8(0x52), u8(0x20),
  u8(0x53), u8(0x4B), u8(0x49), u8(0x41),
];

/// Decorated origin X — 0 for panels (ADR-0192).
@bare
u64 wmDecoX(u64 wI) {
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 x = wmGeomX(g);
  if (wmIsPanel(wI) > u64(0)) {
    return u64(0);
  }
  if (x < u64(wmBorder)) {
    return u64(0);
  }
  return x - u64(wmBorder);
}

/// Decorated origin Y — 0 for panels.
@bare
u64 wmDecoY(u64 wI) {
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 y = wmGeomY(g);
  if (wmIsPanel(wI) > u64(0)) {
    return u64(0);
  }
  if (y < u64(wmBorder)) {
    return u64(0);
  }
  return y - u64(wmBorder);
}

/// DESK menu card size — lockstep with desk.c MENU_W / MENU_H (ADR-0195).
const int wmOverlayW = 160;
const int wmOverlayH = 88;

/// `'WM OVERLAY CLEAR'` -- 16 bytes.
@rodata
final List<u8> wmStrOverlayClear = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4F), u8(0x56), u8(0x45), u8(0x52),
  u8(0x4C), u8(0x41), u8(0x59), u8(0x20), u8(0x43), u8(0x4C), u8(0x45),
  u8(0x41), u8(0x52),
];

/// 1 when overlay [wI] is parked off-screen at (8,8) by DESK hide.
@bare
u64 wmOverlayParked(u64 wI) {
  if (wmAbsX(wI) == u64(8)) {
    if (wmAbsY(wI) == u64(8)) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Repaint every visible overlay slot from [wmPixelAt] (ADR-0196).
@bare
void wmOverlayRestore() {
  u64 i = u64(0);
  u64 any = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmIsOverlay(i) > u64(0)) {
      if (wmOverlayParked(i) < u64(1)) {
        final u64 ax = wmAbsX(i);
        final u64 ay = wmAbsY(i);
        final u64 g = wmWin(i, u64(wmWinGeom));
        final u64 ww = wmGeomW(g);
        final u64 hh = wmGeomH(g);
        final u64 b = u64(wmBorder);
        final u64 unused =
            wmRepaintRect(ax - b, ay - b, ww + b + b, hh + b + b);
        any = u64(1);
      }
    }
    i = i + u64(1);
  }
  if (any > u64(0)) {
    uartWrite(Rodata.addressOf(wmStrOverlayClear), u64(16));
    uartNewline();
  }
}

/// 1 for DESK's 160×88 menu overlay (ADR-0195 / ADR-0196).
@bare
u64 wmIsOverlay(u64 wI) {
  if (wmWinParentOf(wI) >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (wmIsPanel(wI) > u64(0)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  if (wmGeomW(g) != u64(wmOverlayW)) {
    return u64(0);
  }
  if (wmGeomH(g) != u64(wmOverlayH)) {
    return u64(0);
  }
  return u64(1);
}

@bare
u64 wmWinOverlay(u64 wI) {
  return wmIsOverlay(wI);
}

/// 1 if ([x],[y]) is in a gfx corner margin wmBlitRow leaves to chrome.
@bare
u64 wmGfxCornerHole(u64 wI, u64 x, u64 y) {
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  if (wmIsPanel(wI) > u64(0)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 wx = wmAbsX(wI);
  final u64 wy = wmAbsY(wI);
  final u64 ww = wmGeomW(g);
  final u64 wh = wmGeomH(g);
  if (wh <= u64(wmChromeH)) {
    return u64(0);
  }
  if (x < wx) {
    return u64(0);
  }
  if (y < wy) {
    return u64(0);
  }
  if (x >= wx + ww) {
    return u64(0);
  }
  if (y >= wy + wh) {
    return u64(0);
  }
  final u64 py = y - wy;
  final u64 px = x - wx;
  final u64 r = u64(wmGfxRadius);
  if (py < r) {
    if (px < r) {
      return u64(1);
    }
    if (px >= ww - r) {
      return u64(1);
    }
  }
  if (py >= wh - r) {
    if (px < r) {
      return u64(1);
    }
    if (px >= ww - r) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Alpha-blend the Skia pointer sprite at ([x], [y]).
@bare
void wmPointerBlit(u64 x, u64 y) {
  if (wmPage(u64(wmPageWPtrSprOn)) < u64(1)) {
    return;
  }
  final u64 spr = wmPage(u64(wmPageWPtrSpr));
  if (spr < u64(1)) {
    return;
  }
  u64 row = u64(0);
  while (row < u64(wmPtrH)) {
    u64 col = u64(0);
    while (col < u64(wmPtrW)) {
      final u64 sx = x + col;
      final u64 sy = y + row;
      if (sx < fbGeomWidth()) {
        if (sy < fbGeomHeight()) {
          final u64 pix = Pointer<u32>.fromAddress(
                  spr + (((row * u64(wmPtrW)) + col) << u64(2)))
              .value
              .toU64();
          final u64 a = (pix >> u64(24)) & u64(0xFF);
          if (a > u64(0)) {
            final u64 dst = Volatile<u32>.fromAddress(fbPixelAddr(sx, sy))
                .value
                .toU64();
            final u64 rb = dst & u64(0x00FF0000);
            final u64 gb = dst & u64(0x0000FF00);
            final u64 bb = dst & u64(0x000000FF);
            final u64 rs = (pix >> u64(16)) & u64(0xFF);
            final u64 gs = (pix >> u64(8)) & u64(0xFF);
            final u64 bs = pix & u64(0xFF);
            final u64 inv = u64(255) - a;
            final u64 r = ((rs * a) + ((rb >> u64(16)) * inv)) ~/ u64(255);
            final u64 g = ((gs * a) + ((gb >> u64(8)) * inv)) ~/ u64(255);
            final u64 b = ((bs * a) + (bb * inv)) ~/ u64(255);
            fbPutPixel(sx, sy,
                (r << u64(16)) | (g << u64(8)) | b);
          }
        }
      }
      col = col + u64(1);
    }
    row = row + u64(1);
  }
}

/// Rasterise the sprite once (shell / compose context).
@bare
void wmPointerEnsure() {
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  if (wmPage(u64(wmPageWPtrSprOn)) > u64(0)) {
    return;
  }
  if (wmPage(u64(wmPageWPtrSpr)) < u64(1)) {
    final u64 buf = wmRunAlloc(u64(1));
    if (buf < u64(1)) {
      return;
    }
    wmPageSet(u64(wmPageWPtrSpr), buf);
  }
  if (wmPage(u64(wmPageWPtrPix)) < u64(1)) {
    final u64 buf = wmRunAlloc(u64(1));
    if (buf < u64(1)) {
      return;
    }
    wmPageSet(u64(wmPageWPtrPix), buf);
  }
  final u64 spr = wmPage(u64(wmPageWPtrSpr));
  if (osgfx_pointer_raster(spr, u64(wmPtrW), u64(wmPtrH)) == u64(0)) {
    wmPageSet(u64(wmPageWPtrSprOn), u64(1));
    uartWrite(Rodata.addressOf(wmStrPtrSkia), u64(11));
    uartNewline();
  }
}

/// Put save-under pixels back at the last pointer origin.
@bare
void wmPointerRestore() {
  if (wmPage(u64(wmPageWPtrHave)) < u64(1)) {
    return;
  }
  /* Clear first: a missing/corrupt backing page must not leave a permanent
   * fake HAVE that makes every later move believe stale pixels were saved. */
  wmPageSet(u64(wmPageWPtrHave), u64(0));
  final u64 buf = wmPage(u64(wmPageWPtrPix));
  if (buf < u64(1)) {
    return;
  }
  final u64 ox = wmPage(u64(wmPageWPtrX));
  final u64 oy = wmPage(u64(wmPageWPtrY));
  u64 row = u64(0);
  while (row < u64(wmPtrH)) {
    u64 col = u64(0);
    while (col < u64(wmPtrW)) {
      final u64 x = ox + col;
      final u64 y = oy + row;
      if (x < fbGeomWidth()) {
        if (y < fbGeomHeight()) {
          final u64 c = Pointer<u32>.fromAddress(
                  buf + (((row * u64(wmPtrW)) + col) << u64(2)))
              .value
              .toU64() &
              u64(0x00FFFFFF);
          fbPutPixel(x, y, c);
        }
      }
      col = col + u64(1);
    }
    row = row + u64(1);
  }
}

/// Capture save-under and draw the sprite at ([x], [y]).
@bare
void wmPointerPlace(u64 x, u64 y) {
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    mouseDrawCursor(x, y);
    return;
  }
  /* Place owns the ordering invariant, so no caller can stamp a second arrow
   * without first putting back the pixels under the previous one. */
  wmPointerRestore();
  wmPointerEnsure();
  final u64 buf = wmPage(u64(wmPageWPtrPix));
  if (buf < u64(1)) {
    return;
  }
  u64 row = u64(0);
  while (row < u64(wmPtrH)) {
    u64 col = u64(0);
    while (col < u64(wmPtrW)) {
      final u64 px = x + col;
      final u64 py = y + row;
      u64 c = u64(wmColorDesktop);
      if (px < fbGeomWidth()) {
        if (py < fbGeomHeight()) {
          /* Save what is actually visible. Re-resolving wmPixelAt here loses
           * session AA, premultiplied panel edges, and freshly painted chrome,
           * which made restore stamp flat teal holes into those pixels. */
          c = Volatile<u32>.fromAddress(fbPixelAddr(px, py)).value.toU64() &
              u64(0x00FFFFFF);
        }
      }
      Pointer<u32>.fromAddress(buf + (((row * u64(wmPtrW)) + col) << u64(2)))
          .value = c.toU32();
      col = col + u64(1);
    }
    row = row + u64(1);
  }
  wmPageSet(u64(wmPageWPtrX), x);
  wmPageSet(u64(wmPageWPtrY), y);
  wmPageSet(u64(wmPageWPtrHave), u64(1));
  wmPointerBlit(x, y);
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
  final u64 wx = wmAbsX(wI);
  final u64 wy = wmAbsY(wI);
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
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (wmGfxCornerHole(wI, x, y) > u64(0)) {
      return u64(wmNoPixel);
    }
    if (x < wx) {
      return u64(wmNoPixel);
    }
    if (y < wy) {
      return u64(wmNoPixel);
    }
    if (x >= wx + ww) {
      return u64(wmNoPixel);
    }
    if (y >= wy + wh) {
      return u64(wmNoPixel);
    }
  } else {
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
  }
  // Chrome-on title, then DE close/min if those are on.
  final u64 title = wmTitlePixel(wI, x, y);
  if (title != u64(wmNoPixel)) {
    return title;
  }
  /* Button holes under gfx are wmNoPixel — do not fall through to shm. */
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (wmTitleHit(wI, x, y) > u64(0)) {
      return u64(wmNoPixel);
    }
  }
  final u64 scale = wmWinScaleOf(wI);
  final u64 stride = wmWinStrideOf(wI);
  final u64 vec = shmReg(wmWin(wI, u64(wmWinReg)), u64(shmRegVec));
  final u64 off = wmWin(wI, u64(wmWinOffsetW)) +
      (((y - wy) * scale) * stride) + (((x - wx) * scale) << u64(2));
  final u64 src = wmRegionPixel(vec, off);
  if (wmIsPanel(wI) > u64(0)) {
    final u64 under = wmDeskPixel(x, y);
    if (under != u64(wmNoPixel)) {
      return wmPanelSrcOver(src, under);
    }
  }
  return src;
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
  final u64 dePop = wmDePopPixel(x, y);
  if (dePop != u64(wmNoPixel)) {
    return dePop;
  }
  if (wmPopHit(x, y) > u64(0)) {
    if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
      return u64(wmNoPixel);
    }
    return wmPopPixel(x, y);
  }
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
  final u64 chrome = wmChromePixel(x, y);
  if (chrome != u64(wmNoPixel)) {
    return chrome;
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return wmDeskPixel(x, y);
  }
  return u64(wmColorDesktop);
}

/// Repaints one scanline segment from [wmPixelAt] into scratch at [sbase].
@bare
void wmRepaintScratchRow(
    u64 sbase, u64 x, u64 y, u64 w, u64 sw, u64 scratchY) {
  u64 i = u64(0);
  while (i < w) {
    final u64 c = wmPixelAt(x + i, y);
    if (c != u64(wmNoPixel)) {
      Pointer<u32>.fromAddress(
              sbase + (((scratchY * sw) + i) << u64(2)))
          .value = c.toU32();
    } else {
      /* Session-owned AA/chrome means "keep the visible pixel", not "leave
       * this reused scratch cell untouched". Blitting an untouched cell
       * resurrected pixels from an older damage rectangle. */
      Pointer<u32>.fromAddress(
              sbase + (((scratchY * sw) + i) << u64(2)))
          .value = Volatile<u32>.fromAddress(fbPixelAddr(x + i, y)).value;
    }
    i = i + u64(1);
  }
}

/// Blits one scratch row to scanout.
@bare
void wmRepaintBlitRow(
    u64 sbase, u64 x, u64 y, u64 w, u64 sw, u64 scratchY) {
  u64 i = u64(0);
  while (i < w) {
    final u64 c = Pointer<u32>.fromAddress(
            sbase + (((scratchY * sw) + i) << u64(2)))
        .value
        .toU64();
    fbPutPixel(x + i, y, c);
    i = i + u64(1);
  }
}

/// Union of two rectangles, one scratch compose + blit (ADR-0052 / GAP-0302).
@bare
u64 wmRepaintUnion2(u64 x0, u64 y0, u64 w0, u64 h0, u64 x1, u64 y1, u64 w1,
    u64 h1) {
  u64 ux = x0;
  if (x1 < ux) {
    ux = x1;
  }
  u64 uy = y0;
  if (y1 < uy) {
    uy = y1;
  }
  u64 x0e = x0 + w0;
  u64 x1e = x1 + w1;
  u64 ux1 = x0e;
  if (x1e > ux1) {
    ux1 = x1e;
  }
  u64 y0e = y0 + h0;
  u64 y1e = y1 + h1;
  u64 uy1 = y0e;
  if (y1e > uy1) {
    uy1 = y1e;
  }
  return wmRepaintRect(ux, uy, ux1 - ux, uy1 - uy);
}

/// Repaints one scanline segment from [wmPixelAt].
/// `wmNoPixel` means leave the framebuffer alone (session soft chrome).
@bare
void wmRepaintRow(u64 x, u64 y, u64 w) {
  u64 i = u64(0);
  while (i < w) {
    final u64 c = wmPixelAt(x + i, y);
    if (c != u64(wmNoPixel)) {
      fbPutPixel(x + i, y, c);
    }
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
  if (x >= fbGeomWidth()) {
    return u64(0);
  }
  if (y >= fbGeomHeight()) {
    return u64(0);
  }
  u64 ww = w;
  if (x + ww > fbGeomWidth()) {
    ww = fbGeomWidth() - x;
  }
  u64 hh = h;
  if (y + hh > fbGeomHeight()) {
    hh = fbGeomHeight() - y;
  }
  final u64 area = ww * hh;
  final u64 scratch = wmScratchEnsure(area);
  if (scratch > u64(0)) {
    u64 j = u64(0);
    while (j < hh) {
      /* Scratch is a compact ww×hh rectangle. Indexing it by the absolute
       * screen row wrote far beyond the allocation during drag/resize and
       * then blitted unrelated rows back as teal warp. */
      wmRepaintScratchRow(scratch, x, y + j, ww, ww, j);
      wmRepaintBlitRow(scratch, x, y + j, ww, ww, j);
      j = j + u64(1);
    }
    return area;
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
  if (wmIsPanel(wI) > u64(0)) {
    return wmRepaintRect(
        wmAbsX(wI), wmAbsY(wI), wmGeomW(g), wmGeomH(g));
  }
  final u64 b = u64(wmBorder);
  return wmRepaintRect(wmAbsX(wI) - b, wmAbsY(wI) - b,
      wmGeomW(g) + b + b, wmGeomH(g) + b + b);
}

/// The topmost live window covering ([x], [y]), or [wmMaxWindows].
///
/// **"Topmost window under the cursor" is the whole of this compositor's
/// pointer-hit policy**, and `display-protocol.md` §0.1 is explicit that
/// window management is compositor policy rather than protocol. Keyboard
/// focus is the last [wmHit] that succeeded: [wmGrab] writes it, a
/// desktop click or a reap clears it, and it does not follow the pointer.
/// Escape is not special. ADR-0062.
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
  if (cx + w + b > fbGeomWidth()) {
    cx = fbGeomWidth() - b - w;
  }
  if (cy + h + b > fbGeomHeight()) {
    cy = fbGeomHeight() - b - h;
  }
  return (cx << u64(32)) | cy;
}

/// A left-button PRESS: raise the window under the pointer and, unless
/// `wm de` is on and the press is in the client body, start a drag.
///
/// The grab offset is `cursor - origin`, so the window does not jump: the point
/// under the pointer stays under the pointer for the whole drag, which is the
/// one behaviour a person notices immediately when it is wrong.
///
/// ADR-0111: under `wm de` only the title strip starts a move. ADR-0121:
/// the SE handle starts a resize. A body press still focuses, still
/// raises, and still reaches the client (ADR-0055). d2-compositor never
/// types `wm de`, so its body-drag picture is unmoved.
@bare
void wmGrab(u64 x, u64 y) {
  if (wmDeGrab(x, y) > u64(0)) {
    return;
  }
  if (wmPopOn() > u64(0)) {
    final u64 onPop = wmPopHit(x, y);
    if (onPop > u64(0)) {
      if (wmPopWallClick(x, y) > u64(0)) {
        return;
      }
      wmPopHide();
      return;
    }
    wmPopHide();
  }
  if (wmChromeHit(x, y) > u64(0)) {
    return;
  }
  final u64 hit = wmHit(x, y);
  if (hit >= u64(wmMaxWindows)) {
    // D9: a desktop click returns the keyboard to the shell. Focus
    // is the last [wmHit] window until it dies or this path runs.
    // ADR-0142: under `wm de` that is also a leave.
    wmFocusTo(u64(wmMaxWindows));
    return;
  }
  final u64 de = wmDeOn();
  u64 title = u64(0);
  u64 resize = u64(0);
  if (de > u64(0)) {
    title = wmTitleHit(hit, x, y);
    resize = wmResizeHit(hit, x, y);
  }
  // D7: the press reaches the client that owns this window, with
  // coordinates relative to the surface origin. A desktop click never
  // gets here. Hold and release do not -- [wmPointerTick] calls this
  // only on the down edge. A chrome hit returned above, so the taskbar
  // does not steal a client's click by also enqueueing it. Under
  // `wm de` a title press is chrome (ADR-0111) and is not enqueued.
  // An SE resize press is chrome (ADR-0121) and is not enqueued.
  if (de < u64(1)) {
    wmeventEnqueue(hit, x, y);
  } else {
    if (title < u64(1)) {
      if (resize < u64(1)) {
        wmeventEnqueue(hit, x, y);
      }
    }
  }
  // D9: click-to-focus. PLUS ONE so window 0 is expressible.
  // ADR-0142: under `wm de` a change is enter/leave on the ring.
  wmFocusTo(hit);
  final u64 was = wmMeta(u64(wmMetaTop));
  final u64 g = wmWin(hit, u64(wmWinGeom));
  u64 drag = u64(1);
  if (de > u64(0)) {
    drag = u64(0);
    if (title > u64(0)) {
      drag = u64(1);
    }
    if (resize > u64(0)) {
      drag = u64(1);
    }
  }
  if (drag > u64(0)) {
    // Subsurfaces move with their parent; do not start a body drag
    // on a child (relative geom would be corrupted).
    if (wmWinParentOf(hit) < u64(wmMaxWindows)) {
      drag = u64(0);
    }
  }
  if (drag > u64(0)) {
    final u64 ax = wmAbsX(hit);
    final u64 ay = wmAbsY(hit);
    u64 gx = x - ax;
    u64 gy = y - ay;
    if (resize > u64(0)) {
      // Distance from the pointer to the SE, so later steps do not
      // depend on the shrinking geom. UNSIGNED: a press on the
      // border past the content is a zero offset.
      gx = u64(0);
      gy = u64(0);
      if ((ax + wmGeomW(g)) > x) {
        gx = (ax + wmGeomW(g)) - x;
      }
      if ((ay + wmGeomH(g)) > y) {
        gy = (ay + wmGeomH(g)) - y;
      }
      gx = gx | u64(wmResizeMark);
    }
    wmSetMeta(u64(wmMetaGrabX), gx);
    wmSetMeta(u64(wmMetaGrabY), gy);
    wmSetMeta(u64(wmMetaDrag), hit + u64(1));
  }
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

/// Clamps a proposed size so the window stays on screen WITH its
/// border, at least [wmResizeMinW] x [wmResizeMinH], and at most the
/// attached shm (stride/4 by region/stride). Clip, not a new region.
@bare
u64 wmClampSize(u64 wI, u64 ox, u64 oy, u64 nw, u64 nh) {
  u64 w = nw;
  u64 h = nh;
  if (w < u64(wmResizeMinW)) {
    w = u64(wmResizeMinW);
  }
  if (h < u64(wmResizeMinH)) {
    h = u64(wmResizeMinH);
  }
  final u64 stride = wmWinStrideOf(wI);
  u64 maxW = u64(wmResizeMinW);
  if (stride >= u64(4)) {
    maxW = stride >> u64(2);
  }
  final u64 pages = shmReg(wmWin(wI, u64(wmWinReg)), u64(shmRegPages));
  final u64 bytes = pages << u64(vmPageShift);
  final u64 off = wmWin(wI, u64(wmWinOffsetW));
  final u64 scale = wmWinScaleOf(wI);
  u64 maxH = u64(wmResizeMinH);
  if (bytes > off) {
    if (stride > u64(0)) {
      maxH = (bytes - off) ~/ stride;
    }
  }
  if (scale > u64(1)) {
    maxW = maxW ~/ scale;
    maxH = maxH ~/ scale;
  }
  if (w > maxW) {
    w = maxW;
  }
  if (h > maxH) {
    h = maxH;
  }
  final u64 b = u64(wmBorder);
  if ((ox + w + b) > fbGeomWidth()) {
    w = fbGeomWidth() - b - ox;
  }
  if ((oy + h + b) > fbGeomHeight()) {
    h = fbGeomHeight() - b - oy;
  }
  if (w < u64(1)) {
    w = u64(1);
  }
  if (h < u64(1)) {
    h = u64(1);
  }
  return (w << u64(32)) | h;
}

/// One resize step: SE follows the pointer, origin stays, geom w/h
/// change. Same shm. The compositor clips the paint to the new rect.
/// Under `wm de` the client is told (ADR-0142). ADR-0121.
@bare
void wmResizeStep(u64 x, u64 y) {
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
  final u64 ox = wmGeomX(g);
  final u64 oy = wmGeomY(g);
  final u64 ow = wmGeomW(g);
  final u64 oh = wmGeomH(g);
  final u64 gx = wmMeta(u64(wmMetaGrabX)) & u64(0xFFFFFFFF);
  final u64 gy = wmMeta(u64(wmMetaGrabY));
  // Grab is the distance from the pointer to the SE. New right edge
  // is pointer + that offset; origin stays. UNSIGNED: a pointer left
  // of the origin wants a zero width, then the min clamp.
  u64 wantW = u64(0);
  if ((x + gx) > ox) {
    wantW = (x + gx) - ox;
  }
  u64 wantH = u64(0);
  if ((y + gy) > oy) {
    wantH = (y + gy) - oy;
  }
  final u64 packed = wmClampSize(wI, ox, oy, wantW, wantH);
  final u64 nw = packed >> u64(32);
  final u64 nh = packed & u64(0xFFFFFFFF);
  if (nw == ow) {
    if (nh == oh) {
      return;
    }
  }
  final u64 b = u64(wmBorder);
  final u64 rx = ox - b;
  final u64 ry = oy - b;
  final u64 rw = ow + b + b;
  final u64 rh = oh + b + b;
  wmSetWin(wI, u64(wmWinGeom), wmPackGeom(ox, oy, nw, nh));
  wmeventEnqueueConfigure(wI);
  /* Compose old∪new once. Two independent repaints exposed an intermediate
   * frame and reused the damage scratch with two different extents. */
  final u64 px = wmRepaintUnion2(
      rx, ry, rw, rh, ox - b, oy - b, nw + b + b, nh + b + b);
  wmSetMeta(u64(wmMetaRectPixels), px);
  uartWrite(Rodata.addressOf(wmStrResize), u64(12));
  uartPutHex(wI, u64(1));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(nw, u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(nh, u64(4));
  uartWrite(Rodata.addressOf(wmStrFrom), u64(6));
  uartPutHex(ow, u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(oh, u64(4));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(px, u64(8));
  uartNewline();
}

/// One drag step: move the dragged window so the grabbed point follows the
/// pointer, and repaint where it WAS and where it now IS. A marked grab
/// is a resize (ADR-0121), not a move.
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
  if ((wmMeta(u64(wmMetaGrabX)) & u64(wmResizeMark)) > u64(0)) {
    wmResizeStep(x, y);
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
  final u64 ow = w + b + b;
  final u64 oh = h + b + b;
  wmSetWin(wI, u64(wmWinGeom), wmPackGeom(cx, cy, w, h));
  wmeventEnqueueConfigure(wI);
  u64 px = wmRepaintUnion2(ox, oy, ow, oh, cx - b, cy - b, ow, oh);
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
  u64 erased = u64(0);
  /* Interaction handlers below may repaint, move, minimise, or open chrome.
   * Remove the old sprite before any of them changes its saved underlay. */
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (wmPage(u64(wmPageWPtrHave)) > u64(0)) {
      erased = u64(wmPtrW) * u64(wmPtrH);
    }
    wmPointerRestore();
  }
  final u64 bits = mouseState(u64(mouseWordButtons));
  final u64 left = bits & u64(1);
  final u64 right = (bits >> u64(1)) & u64(1);
  final u64 was = wmMeta(u64(wmMetaButtons));
  final u64 wasLeft = was & u64(1);
  final u64 wasRight = (was >> u64(1)) & u64(1);
  // Right PRESS: compositor consumes it. No drag, no client click.
  // ADR-0070. Middle (bit 2) is still ignored.
  if (right > u64(0)) {
    if (wasRight < u64(1)) {
      wmContextShow(x, y);
    }
  }
  if (left > u64(0)) {
    if (wasLeft < u64(1)) {
      wmGrab(x, y);
    }
  } else {
    wmSetMeta(u64(wmMetaDrag), u64(0));
  }
  wmSetMeta(u64(wmMetaButtons), (right << u64(1)) | left);
  wmDragStep(x, y);
  final u64 ox = wmMeta(u64(wmMetaCurX));
  final u64 oy = wmMeta(u64(wmMetaCurY));
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    wmPointerPlace(x, y);
    wmSetMeta(u64(wmMetaCurX), x);
    wmSetMeta(u64(wmMetaCurY), y);
    if (wmGfxChromeFresh() < u64(1)) {
      wmGfxKick();
    }
  } else {
    if (ox != x) {
      erased = wmRepaintRect(ox, oy, u64(mouseCursorCols), u64(mouseCursorRows));
    } else {
      if (oy != y) {
        erased = wmRepaintRect(ox, oy, u64(mouseCursorCols), u64(mouseCursorRows));
      }
    }
    mouseDrawCursor(x, y);
    wmSetMeta(u64(wmMetaCurX), x);
    wmSetMeta(u64(wmMetaCurY), y);
  }
  wmSetMeta(u64(wmMetaRectPixels),
      wmMeta(u64(wmMetaRectPixels)) + erased);
  wmSetMeta(u64(wmMetaBusy), u64(0));
}
