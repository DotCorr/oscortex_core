// core/kernel/wmpace.dart
//
// ADR-0188: THE COMPOSITOR HAS A REFRESH RATE.
//
// ---------------------------------------------------------------------------
// WHAT WAS WRONG, MEASURED RATHER THAN SUSPECTED
// ---------------------------------------------------------------------------
// Before this file the answer to "what is the DE's frame rate" was **zero**,
// and not as a figure of speech: a live sit-in door that had been up for two
// hours had FOUR `WM FRAME` lines in its serial log, all four from startup.
// Frames were event-only — a client commit, a handful of shell commands, a
// decoded media frame — and with no client committing, nothing ever asked.
// There was no vsync, no vblank, no retrace, no frame budget and no throttle
// anywhere in `core/kernel` or `core/plat`. The timer arm bumped a counter and
// called `procTick`; it never composed.
//
// And when something DID ask, one 1280x720 frame cost 217-228 ms — 4.4 fps —
// of which the generative wallpaper was 126 ms (57%) and the DE chrome
// re-stamp 97 ms (44%). The client blit, the only part anybody had ever
// suspected, was 0.89 ms.
//
// ---------------------------------------------------------------------------
// THE POLICY, STATED PLAINLY
// ---------------------------------------------------------------------------
// 1. **A frame is presented because something changed.** Damage, not a clock,
//    is what makes a frame exist. An idle desktop with a still wallpaper and
//    no client activity presents NOTHING and burns no CPU. That is not a gap;
//    a compositor that repaints an unchanged screen sixty times a second is
//    the defect, not the feature.
//
// 2. **The clock is what stops damage from becoming a frame rate.** Damage is
//    COALESCED into one screen rectangle and presented at most once every
//    [wmPacePeriodDefault] PIT ticks. The PIT is 100 Hz (`pitInit`), so the
//    default cap is 50 frames per second and the period is a whole number of
//    ticks rather than a target the machine misses by a fraction. A client
//    committing a thousand times a second gets fifty presents and the other
//    nine hundred and fifty are folded into them. `wm pace 4` is 25 fps.
//
// 3. **The paced present is DART ONLY. Skia never runs in an interrupt.**
//    IRQ0 presents the coalesced rectangle through [wmRepaintRect], which
//    resolves every pixel through [wmPixelAt] — the client's shm, the cached
//    wallpaper, and [wmNoPixel] wherever the session's antialiased chrome
//    already owns the pixel. ADR-0172 established that `osgfx_guest_tick` runs
//    in shell context and not from an IRQ0 spin, and that has not changed.
//
// 4. **Chrome changes still go through the session tick.** [wmGfxChromeSig] is
//    a signature of everything `osgfx_session_paint` draws — the window set,
//    their geometry, the DE and popover state, the wallpaper mode. Keyboard
//    focus and TOP are not folded: a click-to-focus must not inherit the
//    next maximize regen. The 2px rings are a C-side cache patch plus dirty
//    title/border rects. While the sig holds still, damage is honoured.
//    That is the invariant that lets damage be honoured WITHOUT the paper-doodle
//    chrome stomping the gfx arm of `wmComposeCommit` was written to avoid.
//
// 5. **The pointer is not coalesced.** IRQ12 repaints the two 16x12 cursor
//    rectangles the moment a packet decodes, as it always has. Folding the
//    pointer into the pacer would ADD latency to the one thing a person can
//    feel, to save 384 pixels.
//
// 6. **The paced present is SILENT.** `WM FRAME` is ~4 ms of COM1 per frame at
//    the rates this file makes possible, which would make the serial line the
//    frame budget. Event-driven presents still print, so not one byte-exact
//    golden in this suite moves; paced presents count instead, and `wm pace`
//    reports the count. `wm pace log` turns the line back on for a debug run.
//
// ---------------------------------------------------------------------------
// WHERE THE STATE LIVES, AND WHY IT IS NOT `@bss`
// ---------------------------------------------------------------------------
// **This file declares no `@bss` and grows no existing block.** The 24-word
// `wmStore` meta block is FULL (words 0..23 all spoken for), and ten harnesses
// — m19-argv, m20-ipc, m21-shmem, d1-mouse, d2-compositor, d2-input, d7-click,
// d8-chrome, d8-title, d9-focus, osxui1-pop — assert the kernel's mutable
// static total to the byte, several of them by name as "no new @bss".
//
// So the state is a PAGE from the frame allocator, and its address is the one
// new word in the osgfx mailbox (`OsGfxGuestCmd.wmpage`, `.data`, offset 120,
// which takes that struct to exactly the 128 bytes the linker script already
// aligns to — so `mediaBoxOff` does not move either). That is also the only
// place a 3.5 MiB wallpaper cache could have come from.
//
// The page is a table of `u64` words. THIS FILE OWNS THE LAYOUT.
// `core/plat/osgfx/osgfx_guest.h` names the few words the desk cache in
// `osgfx_desk.c` reads or writes, and nothing else in C names any of them.

part of 'kmain.dart';

/// `'WMPAGE1'`. Checked by both sides before a single other word is believed:
/// [wmPageAddr] is an address Dart wrote into `.data`, and a zeroed frame is
/// the one thing neither side may mistake for a valid header.
const int wmPageMagic = 0x00574D5041474531;

/// Byte offset of `OsGfxGuestCmd.wmpage`. Repeated from `osgfx_guest.h`,
/// which is the same hand-repetition every other mailbox offset in
/// `wmpop.dart` and `wmgfx.dart` already is.
const int wmPageMailOff = 120;

// --- The word table -------------------------------------------------------

const int wmPageWMagic = 0;

/// bit 0 paced, bit 1 damage pending, bit 2 damage is the whole screen,
/// bit 3 print `WM FRAME` for paced presents too.
const int wmPageWFlags = 1;

/// PIT ticks between paced presents. 0 is read as [wmPacePeriodDefault].
const int wmPageWPeriod = 2;

/// `tick_count()` at the last paced present.
const int wmPageWLast = 3;

/// The coalesced damage rectangle, `[x0, x1) x [y0, y1)`, screen coordinates.
const int wmPageWDmgX0 = 4;
const int wmPageWDmgY0 = 5;
const int wmPageWDmgX1 = 6;
const int wmPageWDmgY1 = 7;

/// Frames the pacer presented, damage marks folded into them, and ticks on
/// which damage was pending and the budget said no. The last two are the
/// coalescing, in numbers: `COAL` far above `PRES` is the pacer doing its job.
const int wmPageWPresented = 8;
const int wmPageWCoalesced = 9;
const int wmPageWLate = 10;

/// The wallpaper cache: pixel buffer, capacity in pixels, and the frame count
/// it was allocated from. Written here, read by `osgfx_desk.c`.
const int wmPageWDeskBuf = 11;
const int wmPageWDeskPx = 12;
const int wmPageWDeskFrames = 13;

/// Written by `osgfx_desk.c`: the key the buffer holds (0 = nothing
/// trustworthy), and the extent it holds it at. **[wmDeskPixel] refuses to
/// read the buffer unless all three agree with the screen**, which is what
/// stops a damage repaint stamping last resolution's desktop.
const int wmPageWDeskHave = 14;
const int wmPageWDeskW = 15;
const int wmPageWDeskH = 16;
const int wmPageWDeskRegen = 17;
const int wmPageWDeskBlits = 18;

/// Pixels [wmDeskPixel] served out of the cache to a DAMAGE repaint.
///
/// The other two counters are `osgfx_desk.c`'s and they only see the session
/// tick. This one is the half that matters to ADR-0188 §2: it is the number of
/// desktop pixels Dart painted from the generative field, which before the
/// cache was a number that could only be zero — Dart had nothing to paint the
/// desktop WITH except one flat blue, and that is precisely why the gfx arm of
/// [wmComposeCommit] recomposed the world instead of honouring damage.
const int wmPageWDeskReads = 20;

/// [wmGfxChromeSig] as it was at the last full session compose. Damage is
/// honoured while this holds still. ADR-0188 §4.
const int wmPageWChromeSig = 19;

/// THE CHROME CACHE (ADR-0191). The session's whole output — the cached
/// wallpaper plus every antialiased Skia draw over it — in one full-screen
/// buffer, blitted per tick instead of rasterised per tick.
///
/// Same split as the wallpaper cache: these three are Dart's (the contiguous
/// run and its capacity), and `osgfx_chrome.c` owns the six below them.
/// `osgfx_guest.h` names all nine, and nothing else in C names any of them.
const int wmPageWChromeBuf = 21;
const int wmPageWChromePx = 22;
const int wmPageWChromeFrames = 23;

/// Written by `osgfx_chrome.c`: the key the buffer holds (0 = nothing
/// trustworthy) and the extent it holds it at.
const int wmPageWChromeHave = 24;
const int wmPageWChromeW = 25;
const int wmPageWChromeH = 26;

/// Written by `osgfx_chrome.c`: Skia chrome rasterisations, and session ticks
/// served by a blit out of the buffer. **The ratio is the whole of ADR-0191**,
/// measured in the running OS rather than in a stage timer.
const int wmPageWChromeRegen = 27;
const int wmPageWChromeBlits = 28;

/// Written here, read by `osgfx_chrome.c`: 1 to print `OSGFX CHROME REGEN`
/// per rasterisation. [wmPaceLogging]'s flag forwarded across the mailbox,
/// for [wmPaceQuiet]'s reason — a per-tick COM1 line at 115200 baud is about
/// a millisecond, which at a fifty-frame cap is the budget and not
/// instrumentation.
const int wmPageWChromeLog = 29;

/// Written by `osgfx_chrome.c`: glyph runs rasterised and glyph runs served
/// out of the A8 mask cache (GAP-0327).
const int wmPageWGlyphFill = 30;
const int wmPageWGlyphHit = 31;

/// THE TASKBAR GRADIENT BAND (ADR-0191 §5). A slice of the same contiguous run
/// as the chrome frame, holding the one `SkShaders::LinearGradient` fill that
/// measured at 88% of a chrome rasterisation. Dart writes the first two; the
/// rest are `osgfx_chrome.c`'s.
const int wmPageWBandBuf = 32;
const int wmPageWBandPx = 33;
const int wmPageWBandHave = 34;
const int wmPageWBandW = 35;
const int wmPageWBandH = 36;
const int wmPageWBandFill = 37;
const int wmPageWBandHit = 38;

/// THE SESSION DEBT (ADR-0190, GAP-0333). 1 while a session present has been
/// ASKED FOR and the client pixels it will overwrite have not been put back.
///
/// [wmGfxKick] sets it, because a kick is the only thing that makes
/// `osgfx_guest_tick` paint: the tick returns at `m->gen == last_gen` and a
/// kick is what moves `gen`. [wmSessionRestore] — which `isr_common` calls on
/// the instruction after the tick — clears it and re-blits after an uncached
/// direct paint. The chrome-cache blitter preserves client-body holes itself;
/// [wmCompose] clears the conservative debt because either path is settled.
const int wmPageWSessionOwed = 39;

/// Restores performed, client pixels they put back, and interrupts on which a
/// restore was owed and [wmMetaBusy] said no (the debt stays owed and the next
/// interrupt pays it). SKIP far above RESTORE would mean the guard is starving
/// the repair, which is the one way this could be wrong and quiet.
const int wmPageWRestores = 40;
const int wmPageWRestorePx = 41;
const int wmPageWRestoreSkip = 42;

/// POINTER SAVE-UNDER + SKIA SPRITE (ADR-0194).
///
/// [wmRepaintRect] cannot erase the arrow under `wm gfx`: title, border,
/// taskbar and popover all answer [wmNoPixel], so the vacated rect is left
/// alone (trails on the strip) or falls through to [wmDeskPixel] and stamps
/// wallpaper into a window. The pixels themselves are the only honest
/// restore. The sprite is Skia-rasterised once in compose (not IRQ12).
/// 16×20 = 320 u32s each; still in this page — no @bss.
const int wmPtrW = 16;
const int wmPtrH = 20;
const int wmPtrPixN = 320;
const int wmPageWPtrHave = 43;
const int wmPageWPtrX = 44;
const int wmPageWPtrY = 45;
const int wmPageWPtrPix = 46;
const int wmPageWPtrSpr = 206;
const int wmPageWPtrSprOn = 366;
const int wmPageWCtxKind = 367;
const int wmPageWCtxSlot = 368;
const int wmPageWPanelNoted = 369;
const int wmPageWLaunch0 = 370;
const int wmPageWPaintNoted = 374;

/// Damage-repaint scratch (ADR-0052 / GAP-0302). [wmRepaintRect] composes the
/// full clipped rectangle here before any store reaches scanout, so a drag step
/// does not paint half-resolved rows while the display is reading them.
const int wmPageWScratchBuf = 375;
const int wmPageWScratchPx = 376;
const int wmPageWScratchFrames = 377;

/// Pre-maximise geometry, one word per physical window slot. Zero = restored.
const int wmPageWMax0 = 378;

/// Guest-tick event→present (PIT `tick_count`, not UART wall time).
const int wmPageWEvTick = 382;
const int wmPageWEvKind = 383;
const int wmPageWPresTick = 384;
const int wmPageWEvToPres = 385;
const int wmPageWEvSeq = 386;

/// Mailbox win0/win1 caption codes (low 8 / next 8).
/// 1 FILES, 2 SET, 3 BROWSE, 4 PLAY, 5 STUDIO, 6 TAP, 7 PING.
const int wmPageWCapMail = 387;

/// Deferred WM op (Round 14): IRQ enqueues, syscall drains.
/// [wmPageWDefOp]: kind:8 | slot:8 | flags:8. Kind 1 = max/restore, 2 = focus.
/// Flags: bit0 pending, bit1 allow seq-0 body blit.
const int wmPageWDefOp = 388;
const int wmPageWDefOld = 389;
const int wmPageWDefNext = 390;
const int wmPageWDefEnqTick = 391;
const int wmPageWIrqDt = 392;
/// Two idle chrome preps (max + restore). Not the live chrome cache.
const int wmPageWPrepBuf = 393;
const int wmPageWPrepRest = 394;
const int wmPageWPrepPx = 395;
const int wmPageWPrepFrames = 396;
const int wmPageWPrepHave = 397;
const int wmPageWPrepWin0 = 398;
const int wmPageWPrepWin1 = 399;
/// Coalesced deferred damage union (x, y, w, h).
const int wmPageWDefUx = 400;
const int wmPageWDefUy = 401;
const int wmPageWDefUw = 402;
const int wmPageWDefUh = 403;
/// IF-hold: reason:8 | start tick in the rest.
const int wmPageWIfHold = 404;
/// Queue: enq:16 | coal:16 | depth:8.
const int wmPageWDefQ = 405;
/// Slot+1 last presented by deferred drain (skip redundant compose).
const int wmPageWDefPres = 406;

/// Discrete dirty regions (Round 19). AABB in DmgX0..X1 stays the union
/// for drag/max atomic present. Up to [wmDmgCap] non-overlapping rects
/// so pointer + a distant body do not restamp the wallpaper between them.
const int wmDmgCap = 4;
const int wmPageWDmgN = 407;
const int wmPageWDmgR0 = 408;
const int wmPageWDmgPx = 424;
const int wmPageWDmgFull = 425;
const int wmPageWDmgRegs = 426;
const int wmPageWPtrDmgX0 = 427;
const int wmPageWPtrDmgY0 = 428;
const int wmPageWPtrDmgX1 = 429;
const int wmPageWPtrDmgY1 = 430;
const int wmPageWPtrDmgX2 = 431;
const int wmPageWPtrDmgY2 = 432;
const int wmPageWPtrDmgX3 = 433;
const int wmPageWPtrDmgY3 = 434;
const int wmPageWPtrPx = 435;
const int wmPageWDmgCumPx = 436;
const int wmPageWDmgCumRegs = 437;
const int wmPageWDmgCumFull = 438;
const int wmPageWDmgCumPtr = 439;
const int wmPageWDmgCumCons = 440;
/// Sprite-only present seq. Independent of EvKind so pointer pairing
/// cannot stall behind a leftover drag/menu/focus stamp.
const int wmPageWSpriteSeq = 441;
/// Close/reap high-water (Round 22). No new .bss — words in the WM page.
const int wmPageWLifeShmHi = 442;
const int wmPageWLifeCacheHi = 443;
const int wmPageWLifeReap = 444;
const int wmPageWLifeClose = 445;
/// Round 23: committed (visible) vs pending geom. No new .bss.
/// Vis is what scanout and hit-test use. Pend is the client-requested
/// size while seq==0 (HOLD). Generation advances only on VIS publish.
const int wmPageWVis0 = 446;
const int wmPageWPend0 = 450;
const int wmPageWVisGen0 = 454;
/// Round 24: HOLD watchdog. Arm tick and kick/cancel count per slot.
/// Kick 0 = none, 1 = configure re-enqueue, 2 = timeout cancel.
const int wmPageWHoldArm0 = 458;
const int wmPageWHoldKick0 = 462;
/// 1 if the down-edge already fired a CSD button. Release must not
/// toggle max/close again (press() is down+up in 50 ms).
const int wmPageWCsdArmed = 466;
/// Slots 4–7 live past the four-wide banks at 370/378/446 so a
/// DESK + six dock apps do not smash paint/scratch/event words.
const int wmPageWLaunchHi = 467;
const int wmPageWMaxHi = 471;
const int wmPageWVisHi = 475;
const int wmPageWPendHi = 479;
const int wmPageWVisGenHi = 483;
const int wmPageWHoldArmHi = 487;
const int wmPageWHoldKickHi = 491;
const int wmHoldKickTicks = 50;
const int wmHoldForceTicks = 80;
const int wmHoldCancelTicks = 200;

const int wmDefKindNone = 0;
const int wmDefKindMax = 1;
const int wmDefKindFocus = 2;
const int wmDefKindMenu = 3;
const int wmDefKindDrag = 4;
const int wmDefFlagPending = 1;
const int wmDefFlagSeq0 = 2;
const int wmDefFlagGeomHold = 4;
const int wmDefSlotMenu = 0xFE;

const int wmIfReasonDrain = 1;
const int wmIfReasonCompose = 2;
const int wmIfReasonPrep = 3;
const int wmIfReasonSys = 4;

const int wmLatKindPtr = 1;
const int wmLatKindWheel = 2;
const int wmLatKindDrag = 3;
const int wmLatKindMenu = 4;
const int wmLatKindFocus = 5;

const int wmPageFlagPaced = 1;
const int wmPageFlagDamage = 2;
const int wmPageFlagFull = 4;
const int wmPageFlagLog = 8;
const int wmPageFlagPtrDmg = 16;

/// The tick rate the frame clock divides. `pitInit` programs channel 0 with a
/// divisor of 0x2E9C, and 1193182 / 11932 is 100.0 Hz to four figures — so
/// this is not a target, it is the divisor read back in the units a refresh
/// rate is quoted in. `HZ` on the `wm pace` line is this over the period.
const int wmPaceTickHz = 100;

/// Two PIT ticks. The PIT is 100 Hz, so this is a 50 fps cap and it is a
/// WHOLE number of ticks: a cap the clock can actually express is a cap the
/// machine either meets or reports missing, and `LATE` is where it reports.
const int wmPacePeriodDefault = 2;

/// Most frames the wallpaper cache may be allocated from: 8 MiB, which covers
/// a 2048x1024 desk. Above it [wmDeskEnsure] declines and `osgfx_desk.c`
/// generates straight into the scanout, slowly and correctly.
const int wmDeskMaxFrames = 2048;

/// Most frames the chrome frame plus its taskbar band may take: 10 MiB, which
/// covers a 2048x1024 screen and its 2048x48 band with room over. Above it
/// [wmChromeBufEnsure] declines, `osgfx_chrome_target` answers 0, and the
/// session tick rasterises straight into the scanout — slowly, and correctly.
const int wmChromeMaxFrames = 2560;

/// Two idle chrome preps (max + restore), 10 MiB. Separate from the live cache.
const int wmPrepMaxFrames = 2560;

/// Most frames a damage-repaint scratch may take: 2 MiB, which covers a
/// decorated 440×280 FRAME window (SET/FILES) and the vacated+new union of a
/// typical title-bar drag without falling back to the direct scanout path.
/// Above it [wmScratchEnsure] declines and [wmRepaintRect] falls back to the
/// direct scanout path — correct, but row-visible while it runs (GAP-0302).
const int wmScratchMaxFrames = 512;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040). Every byte
// count below is repeated at its call site by hand (GAP-0060).
// ---------------------------------------------------------------------------

/// `'wm pace'` -- 7 bytes.
@rodata
final List<u8> wmPaceStrCmd = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x70), u8(0x61), u8(0x63), u8(0x65),
];

/// `'wm pace off'` -- 11 bytes.
@rodata
final List<u8> wmPaceStrCmdOff = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x70), u8(0x61), u8(0x63), u8(0x65),
  u8(0x20), u8(0x6F), u8(0x66), u8(0x66),
];

/// `'wm pace log'` -- 11 bytes.
@rodata
final List<u8> wmPaceStrCmdLog = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x70), u8(0x61), u8(0x63), u8(0x65),
  u8(0x20), u8(0x6C), u8(0x6F), u8(0x67),
];

/// `'wm pace 4'` -- 9 bytes. 25 fps: the same policy at half the cap, so a
/// harness can prove the CAP is what bounds the rate rather than the cost.
@rodata
final List<u8> wmPaceStrCmd4 = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x70), u8(0x61), u8(0x63), u8(0x65),
  u8(0x20), u8(0x34),
];

/// `'WM PACE '` -- 8 bytes.
@rodata
final List<u8> wmPaceStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x41), u8(0x43), u8(0x45),
  u8(0x20),
];

/// `' HZ '` -- 4 bytes.
@rodata
final List<u8> wmPaceStrHz = const [
  u8(0x20), u8(0x48), u8(0x5A), u8(0x20),
];

/// `' P '` -- 3 bytes.
@rodata
final List<u8> wmPaceStrP = const [
  u8(0x20), u8(0x50), u8(0x20),
];

/// `' PRES '` -- 6 bytes.
@rodata
final List<u8> wmPaceStrPres = const [
  u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x53), u8(0x20),
];

/// `'WM LAT '` -- 7 bytes. Guest tick delta, not host wall time.
@rodata
final List<u8> wmLatStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4C), u8(0x41), u8(0x54), u8(0x20),
];

/// `' D '` -- 3 bytes.
@rodata
final List<u8> wmLatStrD = const [
  u8(0x20), u8(0x44), u8(0x20),
];

/// `' S '` -- 3 bytes.
@rodata
final List<u8> wmLatStrS = const [
  u8(0x20), u8(0x53), u8(0x20),
];

/// `' G '` -- chrome-cache regen count at present (TCG vs schedule).
@rodata
final List<u8> wmLatStrG = const [
  u8(0x20), u8(0x47), u8(0x20),
];

/// `' A '` -- coalesced damage area in pixels at present.
@rodata
final List<u8> wmLatStrA = const [
  u8(0x20), u8(0x41), u8(0x20),
];

/// `'WM PRES S '` -- 10 bytes. Host pairs injection with this present seq.
@rodata
final List<u8> wmPresStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x53),
  u8(0x20), u8(0x53), u8(0x20),
];

/// `'WM SPRITE S '` -- 12 bytes. Pointer sprite present; does not consume EvKind.
@rodata
final List<u8> wmSpriteStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x53), u8(0x50), u8(0x52), u8(0x49),
  u8(0x54), u8(0x45), u8(0x20), u8(0x53), u8(0x20),
];

/// `'WM OPID '` -- 8 bytes. Stamped on every LAT kind so the host pairs
/// this id, not the next PRES on a busy UART.
@rodata
final List<u8> wmOpidStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4F), u8(0x50), u8(0x49), u8(0x44),
  u8(0x20),
];

/// `' COAL '` -- 6 bytes.
@rodata
final List<u8> wmPaceStrCoal = const [
  u8(0x20), u8(0x43), u8(0x4F), u8(0x41), u8(0x4C), u8(0x20),
];

/// `' LATE '` -- 6 bytes.
@rodata
final List<u8> wmPaceStrLate = const [
  u8(0x20), u8(0x4C), u8(0x41), u8(0x54), u8(0x45), u8(0x20),
];

/// `'wm dmg'` -- 6 bytes. Snapshot last transferred pixels while DESK holds
/// the shell (no `wm pace` UART flood).
@rodata
final List<u8> wmDmgStrCmd = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x64), u8(0x6D), u8(0x67),
];

/// `'WM DMG '` -- 7 bytes. Discrete-region counters; not a WM PACE field.
@rodata
final List<u8> wmDmgStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x4D), u8(0x47),
  u8(0x20),
];

/// `' PTR '` -- 5 bytes.
@rodata
final List<u8> wmDmgStrPtr = const [
  u8(0x20), u8(0x50), u8(0x54), u8(0x52), u8(0x20),
];

/// `' RG '` -- 4 bytes.
@rodata
final List<u8> wmDmgStrRg = const [
  u8(0x20), u8(0x52), u8(0x47), u8(0x20),
];

/// `' FL '` -- 4 bytes.
@rodata
final List<u8> wmDmgStrFl = const [
  u8(0x20), u8(0x46), u8(0x4C), u8(0x20),
];

/// `' CUM '` -- 5 bytes.
@rodata
final List<u8> wmDmgStrCum = const [
  u8(0x20), u8(0x43), u8(0x55), u8(0x4D), u8(0x20),
];

/// `' CRG '` -- 5 bytes.
@rodata
final List<u8> wmDmgStrCrg = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x47), u8(0x20),
];

/// `' CFL '` -- 5 bytes.
@rodata
final List<u8> wmDmgStrCfl = const [
  u8(0x20), u8(0x43), u8(0x46), u8(0x4C), u8(0x20),
];

/// `' CPTR '` -- 6 bytes.
@rodata
final List<u8> wmDmgStrCptr = const [
  u8(0x20), u8(0x43), u8(0x50), u8(0x54), u8(0x52), u8(0x20),
];

/// `' CONS '` -- 6 bytes.
@rodata
final List<u8> wmDmgStrCons = const [
  u8(0x20), u8(0x43), u8(0x4F), u8(0x4E), u8(0x53), u8(0x20),
];

/// `'WM DESK '` -- 8 bytes.
@rodata
final List<u8> wmDeskStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x53), u8(0x4B),
  u8(0x20),
];

/// `'PX '` -- 3 bytes.
@rodata
final List<u8> wmDeskStrPx = const [
  u8(0x50), u8(0x58), u8(0x20),
];

/// `' FRM '` -- 5 bytes.
@rodata
final List<u8> wmDeskStrFrm = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x4D), u8(0x20),
];

/// `' AT '` -- 4 bytes.
@rodata
final List<u8> wmDeskStrAt = const [
  u8(0x20), u8(0x41), u8(0x54), u8(0x20),
];

/// `' REGEN '` -- 7 bytes.
@rodata
final List<u8> wmDeskStrRegen = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x47), u8(0x45), u8(0x4E), u8(0x20),
];

/// `' BLIT '` -- 6 bytes.
@rodata
final List<u8> wmDeskStrBlit = const [
  u8(0x20), u8(0x42), u8(0x4C), u8(0x49), u8(0x54), u8(0x20),
];

/// `' READ '` -- 6 bytes.
@rodata
final List<u8> wmDeskStrRead = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x20),
];


/// `'WM DESK NONE'` -- 12 bytes.
@rodata
final List<u8> wmDeskStrNone = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x53), u8(0x4B),
  u8(0x20), u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45),
];

/// `'WM CHROME '` -- 10 bytes.
@rodata
final List<u8> wmChromeStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x48), u8(0x52), u8(0x4F),
  u8(0x4D), u8(0x45), u8(0x20),
];

/// `'WM CHROME NONE'` -- 14 bytes.
@rodata
final List<u8> wmChromeStrNone = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x48), u8(0x52), u8(0x4F),
  u8(0x4D), u8(0x45), u8(0x20), u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45),
];

/// `' GLYPH '` -- 7 bytes.
@rodata
final List<u8> wmChromeStrGlyph = const [
  u8(0x20), u8(0x47), u8(0x4C), u8(0x59), u8(0x50), u8(0x48), u8(0x20),
];

/// `' HIT '` -- 5 bytes.
@rodata
final List<u8> wmChromeStrHit = const [
  u8(0x20), u8(0x48), u8(0x49), u8(0x54), u8(0x20),
];

/// `'WM BAND '` -- 8 bytes.
@rodata
final List<u8> wmBandStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x42), u8(0x41), u8(0x4E), u8(0x44),
  u8(0x20),
];

/// `' FILL '` -- 6 bytes.
@rodata
final List<u8> wmBandStrFill = const [
  u8(0x20), u8(0x46), u8(0x49), u8(0x4C), u8(0x4C), u8(0x20),
];

/// `'WM RESTORE N '` -- 13 bytes.
@rodata
final List<u8> wmRestoreStrLine = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x53), u8(0x54),
  u8(0x4F), u8(0x52), u8(0x45), u8(0x20), u8(0x4E), u8(0x20),
];

/// `' PX '` -- 4 bytes.
@rodata
final List<u8> wmRestoreStrPx = const [
  u8(0x20), u8(0x50), u8(0x58), u8(0x20),
];

/// `' SKIP '` -- 6 bytes.
@rodata
final List<u8> wmRestoreStrSkip = const [
  u8(0x20), u8(0x53), u8(0x4B), u8(0x49), u8(0x50), u8(0x20),
];

// ---------------------------------------------------------------------------
// The state page
// ---------------------------------------------------------------------------

/// Address of the state page, or 0 before one exists.
@bare
u64 wmPageAddr() {
  return Pointer<u64>.fromAddress(kernel_data_start() + u64(wmPageMailOff))
      .value;
}

@bare
u64 wmPage(u64 i) {
  final u64 p = wmPageAddr();
  if (p < u64(1)) {
    return u64(0);
  }
  return Pointer<u64>.fromAddress(p + (i << u64(3))).value;
}

@bare
void wmPageSet(u64 i, u64 v) {
  final u64 p = wmPageAddr();
  if (p < u64(1)) {
    return;
  }
  Pointer<u64>.fromAddress(p + (i << u64(3))).value = v;
}

/// Slot 0–3 stay on the original four-wide bank; 4–7 use the hi bank.
@bare
u64 wmPageSlotWord(u64 lo, u64 hi, u64 slot) {
  if (slot < u64(4)) {
    return lo + slot;
  }
  return hi + (slot - u64(4));
}

@bare
u64 wmPageLaunchOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWLaunch0), u64(wmPageWLaunchHi), slot);
}

@bare
u64 wmPageMaxOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWMax0), u64(wmPageWMaxHi), slot);
}

@bare
u64 wmPageVisOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWVis0), u64(wmPageWVisHi), slot);
}

@bare
u64 wmPagePendOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWPend0), u64(wmPageWPendHi), slot);
}

@bare
u64 wmPageVisGenOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWVisGen0), u64(wmPageWVisGenHi), slot);
}

@bare
u64 wmPageHoldArmOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWHoldArm0), u64(wmPageWHoldArmHi), slot);
}

@bare
u64 wmPageHoldKickOf(u64 slot) {
  return wmPageSlotWord(u64(wmPageWHoldKick0), u64(wmPageWHoldKickHi), slot);
}

/// Stamps the PIT tick and kind of an input that must present.
@bare
void wmLatStamp(u64 kind) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  if (kind < u64(1)) {
    return;
  }
  /* One pending event, one seq. A second stamp before present used to
   * skip a number and invent lat_seq_gaps / 3.5s wait_present timeouts. */
  if (wmPage(u64(wmPageWEvKind)) > u64(0)) {
    wmPageSet(u64(wmPageWEvTick), tick_count());
    wmPageSet(u64(wmPageWEvKind), kind);
    uartWrite(Rodata.addressOf(wmOpidStrLine), u64(8));
    uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
    uartNewline();
    return;
  }
  wmPageSet(u64(wmPageWEvTick), tick_count());
  wmPageSet(u64(wmPageWEvKind), kind);
  wmPageSet(u64(wmPageWEvSeq), wmPage(u64(wmPageWEvSeq)) + u64(1));
  uartWrite(Rodata.addressOf(wmOpidStrLine), u64(8));
  uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
  uartNewline();
}

/// Records present-tick minus event-tick. One UART line per pending event.
@bare
void wmLatNotePresent() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 kind = wmPage(u64(wmPageWEvKind));
  if (kind < u64(1)) {
    return;
  }
  final u64 now = tick_count();
  final u64 ev = wmPage(u64(wmPageWEvTick));
  u64 delta = u64(0);
  if (now >= ev) {
    delta = now - ev;
  }
  wmPageSet(u64(wmPageWPresTick), now);
  wmPageSet(u64(wmPageWEvToPres), delta);
  uartWrite(Rodata.addressOf(wmLatStrLine), u64(7));
  uartPutHex(kind, u64(2));
  uartWrite(Rodata.addressOf(wmLatStrD), u64(3));
  uartPutHex(delta, u64(4));
  uartWrite(Rodata.addressOf(wmLatStrS), u64(3));
  uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
  uartWrite(Rodata.addressOf(wmLatStrG), u64(3));
  uartPutHex(wmPage(u64(wmPageWChromeRegen)), u64(4));
  uartWrite(Rodata.addressOf(wmLatStrA), u64(3));
  u64 aw = u64(0);
  u64 ah = u64(0);
  if (wmPage(u64(wmPageWDmgX1)) > wmPage(u64(wmPageWDmgX0))) {
    aw = wmPage(u64(wmPageWDmgX1)) - wmPage(u64(wmPageWDmgX0));
  }
  if (wmPage(u64(wmPageWDmgY1)) > wmPage(u64(wmPageWDmgY0))) {
    ah = wmPage(u64(wmPageWDmgY1)) - wmPage(u64(wmPageWDmgY0));
  }
  uartPutHex(aw * ah, u64(8));
  uartNewline();
  uartWrite(Rodata.addressOf(wmPresStrLine), u64(10));
  uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
  uartNewline();
  wmPageSet(u64(wmPageWEvKind), u64(0));
}

/// Sprite transfer present. Never touches EvKind, so a leftover drag
/// or menu stamp is not closed and pointer host pairing still advances.
@bare
void wmLatNoteSprite() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWSpriteSeq), wmPage(u64(wmPageWSpriteSeq)) + u64(1));
  uartWrite(Rodata.addressOf(wmSpriteStrLine), u64(12));
  uartPutHex(wmPage(u64(wmPageWSpriteSeq)), u64(8));
  uartNewline();
}

/// Takes one frame for the state page and publishes it in the mailbox.
/// Idempotent: a page that already carries the magic is kept, so nothing here
/// ever hands out a second page and orphans the first.
///
/// Returns 1 when a page exists afterwards.
@bare
u64 wmPageEnsure() {
  final u64 have = wmPageAddr();
  if (have > u64(0)) {
    if (Pointer<u64>.fromAddress(have + u64(wmPageWMagic << 3)).value ==
        u64(wmPageMagic)) {
      return u64(1);
    }
  }
  final u64 f = allocFrame();
  if (f < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(f);
  Pointer<u64>.fromAddress(f + u64(wmPageWMagic << 3)).value =
      u64(wmPageMagic);
  Pointer<u64>.fromAddress(kernel_data_start() + u64(wmPageMailOff)).value = f;
  return u64(1);
}

// ---------------------------------------------------------------------------
// The wallpaper cache
// ---------------------------------------------------------------------------

/// Pixels the generative desk covers: the whole screen.
///
/// The legacy session strip is gone. DESK's panel is a transparent carrier,
/// so its gaps and rounded ends need cached wallpaper beneath them too.
@bare
u64 wmDeskPixels() {
  return fbGeomWidth() * fbGeomHeight();
}

/// Allocates a CONTIGUOUS run of [n] frames and returns the first, or 0.
///
/// **Contiguous, and checked rather than assumed.** `allocFrame` is next-fit
/// from a cursor, so consecutive calls normally return consecutive frames —
/// normally is not a property. Every frame is compared against the run it is
/// supposed to extend, and the first one that is not gives the whole run back
/// and returns 0. Both callers then leave their cache off and paint the slow,
/// correct way instead of reading somebody else's page.
///
/// Two caches now want a megabyte-scale run — the wallpaper (ADR-0188) and the
/// chrome frame (ADR-0191) — and the check is the same check, so it is one
/// function. A second copy of it is a second place for the run to be believed
/// contiguous without being it.
@bare
u64 wmRunAlloc(u64 n) {
  u64 first = u64(0);
  u64 i = u64(0);
  while (i < n) {
    final u64 f = allocFrame();
    if (f < u64(1)) {
      wmDeskGiveBack(first, i);
      return u64(0);
    }
    if (i == u64(0)) {
      first = f;
    }
    if (f != (first + (i << u64(12)))) {
      wmDeskGiveBack(first, i);
      return u64(0);
    }
    i = i + u64(1);
  }
  return first;
}

/// Frames a run of [px] 32-bit pixels needs.
@bare
u64 wmRunFrames(u64 px) {
  return ((px << u64(2)) + u64(4095)) >> u64(12);
}

/// Allocates the generative desk's buffer, once, and records it in the state
/// page. Returns 1 when a usable cache exists afterwards.
@bare
u64 wmDeskEnsure() {
  if (wmPageEnsure() < u64(1)) {
    return u64(0);
  }
  final u64 want = wmDeskPixels();
  if (want < u64(1)) {
    return u64(0);
  }
  if (wmPage(u64(wmPageWDeskPx)) >= want) {
    return u64(1);
  }
  // A screen that GREW past the buffer we hold. Give the old run back before
  // taking a new one, or the resolution change is a permanent leak.
  wmDeskFree();
  final u64 n = wmRunFrames(want);
  if (n > u64(wmDeskMaxFrames)) {
    return u64(0);
  }
  final u64 first = wmRunAlloc(n);
  if (first < u64(1)) {
    return u64(0);
  }
  wmPageSet(u64(wmPageWDeskBuf), first);
  wmPageSet(u64(wmPageWDeskPx), (n << u64(12)) >> u64(2));
  wmPageSet(u64(wmPageWDeskFrames), n);
  wmPageSet(u64(wmPageWDeskHave), u64(0));
  wmPageSet(u64(wmPageWDeskW), u64(0));
  wmPageSet(u64(wmPageWDeskH), u64(0));
  wmDeskLine();
  return u64(1);
}

/// Returns [n] frames of a half-built contiguous run.
@bare
void wmDeskGiveBack(u64 first, u64 n) {
  if (first < u64(1)) {
    return;
  }
  u64 i = u64(0);
  while (i < n) {
    final u64 unused = freeFrame(first + (i << u64(12)));
    i = i + u64(1);
  }
}

/// Gives the whole cache back and marks it absent. The buffer's own frames
/// are the only thing this releases; the state page stays.
@bare
void wmDeskFree() {
  final u64 buf = wmPage(u64(wmPageWDeskBuf));
  if (buf < u64(1)) {
    return;
  }
  wmDeskGiveBack(buf, wmPage(u64(wmPageWDeskFrames)));
  wmPageSet(u64(wmPageWDeskBuf), u64(0));
  wmPageSet(u64(wmPageWDeskPx), u64(0));
  wmPageSet(u64(wmPageWDeskFrames), u64(0));
  wmPageSet(u64(wmPageWDeskHave), u64(0));
}

/// Gives the damage-repaint scratch back. Pair of [wmScratchEnsure].
@bare
void wmScratchFree() {
  final u64 buf = wmPage(u64(wmPageWScratchBuf));
  if (buf < u64(1)) {
    return;
  }
  wmDeskGiveBack(buf, wmPage(u64(wmPageWScratchFrames)));
  wmPageSet(u64(wmPageWScratchBuf), u64(0));
  wmPageSet(u64(wmPageWScratchPx), u64(0));
  wmPageSet(u64(wmPageWScratchFrames), u64(0));
}

/// Allocates a scratch buffer holding at least [px] 32-bit pixels, once, and
/// returns its base. 0 when no usable buffer exists — [wmRepaintRect] then
/// paints the scanout directly.
@bare
u64 wmScratchEnsure(u64 px) {
  if (wmPageEnsure() < u64(1)) {
    return u64(0);
  }
  if (px < u64(1)) {
    return u64(0);
  }
  if (wmPage(u64(wmPageWScratchPx)) >= px) {
    return wmPage(u64(wmPageWScratchBuf));
  }
  wmScratchFree();
  final u64 n = wmRunFrames(px);
  if (n > u64(wmScratchMaxFrames)) {
    return u64(0);
  }
  final u64 first = wmRunAlloc(n);
  if (first < u64(1)) {
    return u64(0);
  }
  wmPageSet(u64(wmPageWScratchBuf), first);
  wmPageSet(u64(wmPageWScratchPx), (n << u64(12)) >> u64(2));
  wmPageSet(u64(wmPageWScratchFrames), n);
  return first;
}

/// Marks the cached field stale WITHOUT giving the buffer back, so the next
/// session tick regenerates into the same pages. This is what `Regen` and a
/// wallpaper change want: the pixels are wrong, the memory is fine.
@bare
void wmDeskInvalidate() {
  wmPageSet(u64(wmPageWDeskHave), u64(0));
}

/// `WM DESK PX <px> FRM <n> AT <addr>`, once per allocation.
@bare
void wmDeskLine() {
  uartWrite(Rodata.addressOf(wmDeskStrLine), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrPx), u64(3));
  uartPutHex(wmPage(u64(wmPageWDeskPx)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrFrm), u64(5));
  uartPutHex(wmPage(u64(wmPageWDeskFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrAt), u64(4));
  uartPutHex(wmPage(u64(wmPageWDeskBuf)), u64(16));
  uartNewline();
}

/// The wallpaper colour at ([x], [y]), or [wmNoPixel].
///
/// **This is the whole reason the cache exists twice over.** It makes a frame
/// cheap, and it makes a DAMAGE-LIMITED frame possible at all: before it, the
/// only thing Dart could put on the desktop was the solid [wmColorDesktop],
/// and stamping that into a damage rectangle under `wm gfx` painted a flat
/// blue hole in the generative field. The gfx arm of [wmComposeCommit]
/// answered that by discarding the damage and recomposing the world.
///
/// Three refusals, and each is a picture that would otherwise be wrong:
///
///   * a solid-image wallpaper — the mailbox `wall` colour is what the session
///     filled, so that is what comes back, and the cache is not consulted;
///   * a cache whose key or extent does not match the screen — [wmNoPixel],
///     which leaves the framebuffer alone. A damage pass that cannot know
///     what the desktop looks like must not guess.
@bare
u64 wmDeskPixel(u64 x, u64 y) {
  if (wmWallMode() > u64(0)) {
    return Pointer<u64>.fromAddress(
                kernel_data_start() + u64(wmPopMailWall))
            .value &
        u64(0x00FFFFFF);
  }
  if (wmPage(u64(wmPageWDeskHave)) < u64(1)) {
    return u64(wmNoPixel);
  }
  final u64 dw = wmPage(u64(wmPageWDeskW));
  final u64 dh = wmPage(u64(wmPageWDeskH));
  if (dw != fbGeomWidth()) {
    return u64(wmNoPixel);
  }
  if (y >= dh) {
    return u64(wmNoPixel);
  }
  if (x >= dw) {
    return u64(wmNoPixel);
  }
  final u64 buf = wmPage(u64(wmPageWDeskBuf));
  if (buf < u64(1)) {
    return u64(wmNoPixel);
  }
  wmPageSet(u64(wmPageWDeskReads), wmPage(u64(wmPageWDeskReads)) + u64(1));
  return Pointer<u32>.fromAddress(buf + (((y * dw) + x) << u64(2)))
          .value
          .toU64() &
      u64(0x00FFFFFF);
}

/// Session chrome-cache pixel at ([x], [y]), or [wmNoPixel].
///
/// The save-under is the honest restore. This is the fallback when there
/// is no capture yet: [wmPixelAt] answers [wmNoPixel] on title/strip, which
/// is how a first pointer walk left arrow bits on chrome (the trail).
@bare
u64 wmChromeCachePixel(u64 x, u64 y) {
  if (wmPageAddr() < u64(1)) {
    return u64(wmNoPixel);
  }
  if (wmPage(u64(wmPageWChromeHave)) < u64(1)) {
    return u64(wmNoPixel);
  }
  final u64 cw = wmPage(u64(wmPageWChromeW));
  final u64 ch = wmPage(u64(wmPageWChromeH));
  if (cw != fbGeomWidth()) {
    return u64(wmNoPixel);
  }
  if (y >= ch) {
    return u64(wmNoPixel);
  }
  if (x >= cw) {
    return u64(wmNoPixel);
  }
  final u64 buf = wmPage(u64(wmPageWChromeBuf));
  if (buf < u64(1)) {
    return u64(wmNoPixel);
  }
  return Pointer<u32>.fromAddress(buf + (((y * cw) + x) << u64(2)))
          .value
          .toU64() &
      u64(0x00FFFFFF);
}

// ---------------------------------------------------------------------------
// The chrome frame cache (ADR-0191)
//
// ADR-0188 took the generative wallpaper out of the per-frame cost and said,
// in §8, what was left: the Skia session tick was 40-47 ms of a 40-45 ms
// compose, i.e. essentially the whole frame, and every chrome change paid it.
// The wallpaper's answer was "generate once, blit per frame". This is the same
// answer one layer up, applied to everything the session paints.
//
// **What Dart owns here is the memory and nothing else.** The buffer is a
// contiguous run from the frame allocator, exactly as the wallpaper's is and
// for the same two reasons (§5 of ADR-0188): eleven harnesses assert the
// kernel's mutable static total to the byte, and a full-screen frame is
// megabytes. What is IN the buffer, and the key that says whether it is still
// current, belong to `osgfx_chrome.c` — because the only honest key is a fold
// of the mailbox words `osgfx_session_paint` actually reads, and C is the side
// that reads them.
//
// [wmGfxChromeSig] is NOT that key, and the distinction is worth stating
// because GAP-0330 proposed using it. The signature answers a Dart question
// ("may a damage repaint be honoured?") and is deliberately coarse: it folds
// the window set, focus, the top slot, the DE and popover state and the
// wallpaper mode. The paint additionally reads the client edge TONES, which
// change when a client commits new content in its bottom corners, and the
// generative field's own cache key. A cache keyed on the signature would hold
// a stale corner colour. So the key is C's, the signature stays Dart's, and
// they are checked against each other by the harness rather than merged.
// ---------------------------------------------------------------------------

/// Pixels the session paints: the WHOLE screen. Not [wmDeskPixels], which
/// stops above the taskbar — the session owns the strip too, and the cache is
/// the session's output.
@bare
u64 wmChromeFramePixels() {
  return fbGeomWidth() * fbGeomHeight();
}

/// Pixels the taskbar gradient band occupies (ADR-0191 §5).
@bare
u64 wmChromeBandPixels() {
  return fbGeomWidth() * u64(wmChromeH);
}

/// The whole run: one screen for the chrome frame, one taskbar band after it.
///
/// **One allocation and not two**, so there is one contiguity check, one
/// failure mode and one thing to give back. The band is a slice of the run and
/// its address is published separately, so nothing in C does arithmetic on
/// Dart's idea of the layout.
@bare
u64 wmChromeBufPixels() {
  return wmChromeFramePixels() + wmChromeBandPixels();
}

/// Allocates the chrome frame buffer, once, and records it in the state page.
///
/// Called from [wmCompose] under `wm de` only, on [wmDeskEnsure]'s terms and
/// for its reason: `wm de` is the only flag combination under which
/// `osgfx_session_paint` paints antialiased chrome at all, so `de-osgfx` —
/// which never types it — takes no frames from the allocator and its baseline
/// does not move.
///
/// Returns 1 when a usable buffer exists afterwards.
@bare
u64 wmChromeBufEnsure() {
  if (wmPageEnsure() < u64(1)) {
    return u64(0);
  }
  final u64 want = wmChromeBufPixels();
  if (want < u64(1)) {
    return u64(0);
  }
  // `wm pace log`'s flag, forwarded to the C side every compose so the cache's
  // per-regen note follows the one switch the owner already has. Off, this is
  // one store; on, `osgfx_chrome.c` prints a line per rasterisation, which is
  // how a reader watches the key move while clicking around.
  wmPageSet(u64(wmPageWChromeLog), wmPaceLogging());
  if (wmPage(u64(wmPageWChromePx)) >= want) {
    wmChromeBandPublish();
    return u64(1);
  }
  wmChromeBufFree();
  final u64 n = wmRunFrames(want);
  if (n > u64(wmChromeMaxFrames)) {
    return u64(0);
  }
  final u64 first = wmRunAlloc(n);
  if (first < u64(1)) {
    return u64(0);
  }
  wmPageSet(u64(wmPageWChromeBuf), first);
  wmPageSet(u64(wmPageWChromePx), (n << u64(12)) >> u64(2));
  wmPageSet(u64(wmPageWChromeFrames), n);
  wmPageSet(u64(wmPageWChromeHave), u64(0));
  wmPageSet(u64(wmPageWChromeW), u64(0));
  wmPageSet(u64(wmPageWChromeH), u64(0));
  wmChromeBandPublish();
  wmChromeBufLine();
  return u64(1);
}

/// Points the band words at the slice of the run that follows the frame.
///
/// **Recomputed on EVERY ensure, not only on allocation**, because the offset
/// is the frame's pixel count and a resolution change moves it while leaving
/// the run big enough to keep. A band pointer that stayed where last
/// resolution put it would have Skia rasterising the taskbar into the middle
/// of the cached frame.
@bare
void wmChromeBandPublish() {
  final u64 buf = wmPage(u64(wmPageWChromeBuf));
  if (buf < u64(1)) {
    return;
  }
  final u64 frame = wmChromeFramePixels();
  final u64 band = wmChromeBandPixels();
  if ((frame + band) > wmPage(u64(wmPageWChromePx))) {
    wmPageSet(u64(wmPageWBandBuf), u64(0));
    wmPageSet(u64(wmPageWBandPx), u64(0));
    return;
  }
  final u64 at = buf + (frame << u64(2));
  if (wmPage(u64(wmPageWBandBuf)) != at) {
    // The slice MOVED, so whatever is in it is not the band it claims to be.
    wmPageSet(u64(wmPageWBandHave), u64(0));
  }
  wmPageSet(u64(wmPageWBandBuf), at);
  wmPageSet(u64(wmPageWBandPx), band);
}

/// Gives the buffer's frames back and marks it absent. The state page stays.
@bare
void wmChromeBufFree() {
  final u64 buf = wmPage(u64(wmPageWChromeBuf));
  if (buf < u64(1)) {
    return;
  }
  wmDeskGiveBack(buf, wmPage(u64(wmPageWChromeFrames)));
  wmPageSet(u64(wmPageWChromeBuf), u64(0));
  wmPageSet(u64(wmPageWChromePx), u64(0));
  wmPageSet(u64(wmPageWChromeFrames), u64(0));
  wmPageSet(u64(wmPageWChromeHave), u64(0));
  // The band is a slice of the run that just went back, so its pointer is now
  // somebody else's memory. Both words go with it.
  wmPageSet(u64(wmPageWBandBuf), u64(0));
  wmPageSet(u64(wmPageWBandPx), u64(0));
  wmPageSet(u64(wmPageWBandHave), u64(0));
  wmPrepBufFree();
}

/// Allocates two full-screen idle chrome preps (max + restore).
@bare
u64 wmPrepBufEnsure() {
  if (wmPageEnsure() < u64(1)) {
    return u64(0);
  }
  final u64 want = wmChromeFramePixels() + wmChromeFramePixels();
  if (want < u64(1)) {
    return u64(0);
  }
  if (wmPage(u64(wmPageWPrepPx)) >= wmChromeFramePixels()) {
    if (wmPage(u64(wmPageWPrepBuf)) > u64(0)) {
      if (wmPage(u64(wmPageWPrepRest)) > u64(0)) {
        return u64(1);
      }
    }
  }
  wmPrepBufFree();
  final u64 n = wmRunFrames(want);
  if (n > u64(wmPrepMaxFrames)) {
    return u64(0);
  }
  final u64 first = wmRunAlloc(n);
  if (first < u64(1)) {
    return u64(0);
  }
  final u64 frameB = wmChromeFramePixels() << u64(2);
  wmPageSet(u64(wmPageWPrepBuf), first);
  wmPageSet(u64(wmPageWPrepRest), first + frameB);
  wmPageSet(u64(wmPageWPrepPx), wmChromeFramePixels());
  wmPageSet(u64(wmPageWPrepFrames), n);
  wmPageSet(u64(wmPageWPrepHave), u64(0));
  return u64(1);
}

@bare
void wmPrepBufFree() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 buf = wmPage(u64(wmPageWPrepBuf));
  if (buf > u64(0)) {
    wmDeskGiveBack(buf, wmPage(u64(wmPageWPrepFrames)));
  }
  wmPageSet(u64(wmPageWPrepBuf), u64(0));
  wmPageSet(u64(wmPageWPrepRest), u64(0));
  wmPageSet(u64(wmPageWPrepPx), u64(0));
  wmPageSet(u64(wmPageWPrepFrames), u64(0));
  wmPageSet(u64(wmPageWPrepHave), u64(0));
}

/// Marks the cached frame stale WITHOUT giving the buffer back, so the next
/// session tick rasterises into the same pages.
///
/// **Nothing on the normal path needs this**, and that is the point of keying
/// the cache on what the paint reads: a raise, a focus change, a popover, a
/// wallpaper pick and a client's new edge tone all move the key by themselves.
/// It exists for the two callers that cannot be expressed as a mailbox word —
/// `wm fps`'s before/after stage, which has to make the tick do what it did
/// before this cache existed, and a screen whose pixels were overwritten by
/// something outside the compositor.
@bare
void wmChromeBufInvalidate() {
  wmPageSet(u64(wmPageWChromeHave), u64(0));
}

/// Marks the cached taskbar band stale as well as the frame, so the next
/// session tick runs the gradient shader over the strip again.
///
/// This is the ONLY reconstruction of a pre-ADR-0191 session tick, and `wm
/// fps` needs it to have a before column at all: with the band cached, a
/// chrome repaint is 4.6 ms rather than the 36 ms it cost when every tick ran
/// the shader. Nothing on the normal path calls this — the band's inputs are
/// the screen width, the band height and two constants, so at a fixed
/// resolution it is correct for the life of a boot.
@bare
void wmChromeAllInvalidate() {
  wmChromeBufInvalidate();
  wmPageSet(u64(wmPageWBandHave), u64(0));
}

/// `WM CHROME PX <px> FRM <n> AT <addr>`, once per allocation.
@bare
void wmChromeBufLine() {
  uartWrite(Rodata.addressOf(wmChromeStrLine), u64(10));
  uartWrite(Rodata.addressOf(wmDeskStrPx), u64(3));
  uartPutHex(wmPage(u64(wmPageWChromePx)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrFrm), u64(5));
  uartPutHex(wmPage(u64(wmPageWChromeFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrAt), u64(4));
  uartPutHex(wmPage(u64(wmPageWChromeBuf)), u64(16));
  uartNewline();
}

// ---------------------------------------------------------------------------
// The chrome signature
// ---------------------------------------------------------------------------

/// A fold of everything `osgfx_session_paint` draws that Dart cannot repaint:
/// the window set and their geometry, which one is on top, keyboard focus, the
/// DE and popover state, and the wallpaper mode.
///
/// **While this holds still, damage can be honoured.** Every pixel the session
/// paints — the card stroke, the shadow, the pearl title band with its real
/// outline caption, the taskbar gradient, the traffic lights — is a function of
/// exactly these inputs, so an unchanged signature is a promise that the
/// chrome on the screen is still the right chrome. The moment it moves, the
/// next present is a full compose and Skia draws the chrome again. That is how
/// ADR-0183's refusal to honour damage under `wm gfx` is retired without
/// bringing back the solid stamps it was protecting against.
@bare
u64 wmGfxChromeSig() {
  u64 s = u64(0);
  u64 popBits = wmMeta(u64(wmMetaPop)) & u64(7);
  u64 popXY = wmMeta(u64(wmMetaPopXY));
  u64 i = u64(0);
  /* Focus/TOP are a C-side 2px border patch (osgfx_chrome_is_focus_only).
   * Folding them here forced a full wmCompose + Skia shadow regen on
   * every click-to-focus. Raise still dirties the two title/border
   * rects; the session tick is not required for a ring colour flip. */
  s = (s << u64(1)) | (wmDeOn() & u64(1));
  s = (s << u64(1)) | (wmMeta(u64(wmMetaChrome)) & u64(1));
  /* ADR-0195: once DESK owns the strip, session does not paint menus or
   * titles. Folding pop / overlay geom into this sig kicked a full
   * generative desk on every Start or MOVE — IF clear for the whole
   * raster, tablet press dropped, and drop_skia raced DESK paint
   * (FAULT 0D OP 488B). */
  if (wmPanelStrip() > u64(0)) {
    popBits = u64(0);
    popXY = u64(0);
  }
  s = (s << u64(3)) | popBits;
  s = (s << u64(1)) | (wmWallMode() & u64(1));
  /* DESK's first commit flips the panel bit without moving geom. Attach
   * already xor'd the strip rectangle; without this the chrome cache stays
   * "fresh" and the session keeps painting a second bar (GAP-0329). */
  s = (s << u64(1)) | (wmPanelStrip() & u64(1));
  s = s ^ (popXY << u64(11));
  while (i < u64(wmMaxWindows)) {
    u64 g = u64(0);
    if (wmWindowHeld(i) > u64(0)) {
      if (wmWinOverlay(i) < u64(1)) {
        g = wmViewGeom(i) | u64(1);
      }
    }
    s = s ^ (g << (i & u64(3)));
    s = s ^ (g >> u64(17));
    i = i + u64(1);
  }
  return s;
}

/// 1 if the chrome on the screen is still the chrome the current state asks
/// for, so a damage-limited present is faithful.
@bare
u64 wmGfxChromeFresh() {
  if (wmPageAddr() < u64(1)) {
    return u64(0);
  }
  if (wmPage(u64(wmPageWChromeSig)) != wmGfxChromeSig()) {
    return u64(0);
  }
  return u64(1);
}

// ---------------------------------------------------------------------------
// THE SESSION DEBT -- ADR-0190, GAP-0333
// ---------------------------------------------------------------------------
//
// WHAT WAS WRONG. `isr_common` calls `osgfx_guest_tick` on the instruction
// after `isrDispatch`, on EVERY interrupt (`core/boot/isr.S`). That tick
// returns immediately while `m->gen == last_gen`, so what actually decides
// whether the session paints is who last moved `gen` -- and the only thing
// that moves it is [wmGfxKick]. When the tick does paint it writes the WHOLE
// scanout: the cached generative field, then every antialiased Skia draw over
// it, or one full-screen blit out of the ADR-0191 chrome frame.
//
// **Nothing put the client pixels back.** The only code on this machine that
// reads a client's shm into the framebuffer is [wmDrawWindow], and it is
// reached from [wmCompose] and from nowhere else. So a kick that was not part
// of a compose -- [wmPointerTick]'s, `wm fps`'s, `virtgpuk`'s -- handed the
// screen to the session and left every mapped client's body painted over with
// wallpaper. It did not come back on its own, because the compositor does not
// poll clients and a client that has committed once has nothing more to say.
// One pointer packet was enough, and the window it emptied stayed empty.
//
// THE RULE THIS ADDS, and it is the rule GAP-0333 said was missing: **a
// present must re-blit every mapped client it covered.** The session's present
// is the whole screen, so the restore is every live window.
//
// It is Dart only and it runs in an interrupt, which is allowed for exactly
// [wmFrameTick]'s reason (ADR-0188 §4): [wmDrawWindow] reads shm frame vectors
// and writes the framebuffer, and touches no Skia heap. What it must NOT do is
// stamp [wmGfxChromeSig] -- ADR-0188 §3.3 makes [wmCompose] the one place
// entitled to claim the chrome on the screen is current, and an interrupt that
// cannot tell a completed `tick_body` from an early return is not entitled to.

/// 1 while a session present has been asked for and its client pixels have not
/// been put back.
@bare
u64 wmSessionOwed() {
  return wmPage(u64(wmPageWSessionOwed));
}

/// Records that a session present is coming. Called by [wmGfxKick], which is
/// the only thing that moves the mailbox generation the tick keys on.
@bare
void wmSessionOwe() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWSessionOwed), u64(1));
}

@bare
void wmSessionOwedClear() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWSessionOwed), u64(0));
}

/// **THE CLIENT PIXELS THE SESSION JUST PAINTED OVER, PUT BACK.** Called from
/// `isr_common`, on the instruction after `call osgfx_guest_tick`.
///
/// The first test is one load of `.data` and a compare, so a machine that
/// never typed `wm gfx` pays that and nothing else on every interrupt it
/// takes. The second is one load out of the state page.
///
/// **[wmMetaBusy] leaves the debt OWED.** A compose running in a syscall with
/// interrupts on is going to do the blit itself; one that is interrupted
/// half-way through is not, and two painters in one framebuffer is a torn
/// frame either way. So a busy interrupt counts a skip and returns, and the
/// next interrupt after the guard drops pays the debt. That is [wmFrameTick]'s
/// rule and it is here for the same reason.
@bare
void wmSessionRestore() {
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    return;
  }
  if (wmSessionOwed() < u64(1)) {
    return;
  }
  if (wmActive() < u64(1)) {
    wmSessionOwedClear();
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    wmSessionOwedClear();
    return;
  }
  if (wmMeta(u64(wmMetaBusy)) > u64(0)) {
    wmPageSet(u64(wmPageWRestoreSkip),
        wmPage(u64(wmPageWRestoreSkip)) + u64(1));
    return;
  }
  wmSessionOwedClear();
  wmSetMeta(u64(wmMetaBusy), u64(1));
  // THE LIFETIME CHECK, before anything reads a frame vector. [wmReap].
  wmReap();
  // Bottom-up, top last, which is [wmCompose]'s order and has to be: two
  // overlapping windows resolve by who was blitted last, and a restore that
  // disagreed with the compose would put the wrong one in front.
  // Overlay cards last — same as [wmCompose]: menus above every FRAME body.
  final u64 top = wmMeta(u64(wmMetaTop));
  u64 px = u64(0);
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
  // The session painted over the arrow too. [wmCompose] draws it last for the
  // same reason: it is on top of everything and it is never read back.
  // Save-under first so the next pointer packet can put these pixels back
  // without asking [wmPixelAt] (which declines every session-owned pixel).
  wmPointerRestore();
  wmPointerPlace(mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)));
  wmPageSet(u64(wmPageWRestores), wmPage(u64(wmPageWRestores)) + u64(1));
  wmPageSet(u64(wmPageWRestorePx), wmPage(u64(wmPageWRestorePx)) + px);
  /* After the session tick and the client restore — the real present.
   * Noting here (not at stamp) is what keeps focus/raise LAT honest. */
  wmLatNotePresent();
  // NOT [wmPublishFrame]. This is the second half of the frame the session
  // tick started, not a frame of its own, and ten byte-exact harnesses count
  // `WM FRAME` lines. The count is in the state page and `wm pace` prints it.
  wmSetMeta(u64(wmMetaBusy), u64(0));
}

/// Records the signature a full compose just satisfied. Called from
/// [wmCompose], which is the one place the session tick runs inside a frame.
@bare
void wmGfxChromeStamp() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWChromeSig), wmGfxChromeSig());
}

// ---------------------------------------------------------------------------
// Damage
// ---------------------------------------------------------------------------

@bare
u64 wmPacePeriod() {
  final u64 p = wmPage(u64(wmPageWPeriod));
  if (p < u64(1)) {
    return u64(wmPacePeriodDefault);
  }
  return p;
}

/// 1 while IRQ0 is allowed to present. Read by `picUnmaskKeyboardOnly`, which
/// is the one function that would otherwise silence the clock this depends on.
@bare
u64 wmPaced() {
  return (wmPage(u64(wmPageWFlags)) >> u64(0)) & u64(1);
}

@bare
u64 wmPaceLogging() {
  return (wmPage(u64(wmPageWFlags)) >> u64(3)) & u64(1);
}

/// 1 when the hot path should say nothing: the frame clock is armed and
/// `wm pace log` is off.
///
/// **This is the debug flag the per-frame logging now sits behind, and it is
/// deliberately narrow.** `WM FRAME` and `WM COMMIT` together are about four
/// milliseconds of COM1 per frame at 115200 baud, which at a fifty-frame cap
/// is not instrumentation, it is the budget. But those two lines are also what
/// ten byte-exact harnesses in this suite count, so the flag that silences
/// them is the pacer's own arm bit: a machine that never typed `wm pace` reads
/// one word out of the mailbox, finds 0, and prints every line it ever did.
@bare
u64 wmPaceQuiet() {
  if (wmPaced() < u64(1)) {
    return u64(0);
  }
  if (wmPaceLogging() > u64(0)) {
    return u64(0);
  }
  return u64(1);
}

/// Folds ([x], [y], [w], [h]) into the pending damage set.
///
/// AABB in DmgX0..X1 is the union (drag/max atomic). Discrete slots
/// [wmDmgCap] keep disjoint marks from restamping the gap. Overlap or
/// an 8px halo merges. A fifth mark collapses to the AABB and counts
/// as a full fallback when the union covers most of the screen.
@bare
void wmDmgStore(u64 i, u64 x0, u64 y0, u64 x1, u64 y1) {
  final u64 b = u64(wmPageWDmgR0) + (i * u64(4));
  wmPageSet(b, x0);
  wmPageSet(b + u64(1), y0);
  wmPageSet(b + u64(2), x1);
  wmPageSet(b + u64(3), y1);
}

@bare
u64 wmDmgNear(u64 ax0, u64 ay0, u64 ax1, u64 ay1, u64 bx0, u64 by0, u64 bx1,
    u64 by1) {
  u64 a0 = ax0;
  u64 a1 = ax1;
  u64 b0 = bx0;
  u64 b1 = bx1;
  if (a0 > u64(8)) {
    a0 = a0 - u64(8);
  } else {
    a0 = u64(0);
  }
  a1 = a1 + u64(8);
  if (b0 > u64(8)) {
    b0 = b0 - u64(8);
  } else {
    b0 = u64(0);
  }
  b1 = b1 + u64(8);
  if (a1 <= b0) {
    return u64(0);
  }
  if (b1 <= a0) {
    return u64(0);
  }
  u64 c0 = ay0;
  u64 c1 = ay1;
  u64 d0 = by0;
  u64 d1 = by1;
  if (c0 > u64(8)) {
    c0 = c0 - u64(8);
  } else {
    c0 = u64(0);
  }
  c1 = c1 + u64(8);
  if (d0 > u64(8)) {
    d0 = d0 - u64(8);
  } else {
    d0 = u64(0);
  }
  d1 = d1 + u64(8);
  if (c1 <= d0) {
    return u64(0);
  }
  if (d1 <= c0) {
    return u64(0);
  }
  return u64(1);
}

@bare
void wmDamageRect(u64 x, u64 y, u64 w, u64 h) {
  if (w < u64(1)) {
    return;
  }
  if (h < u64(1)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  u64 nx0 = x;
  u64 ny0 = y;
  u64 nx1 = x + w;
  u64 ny1 = y + h;
  if (nx1 > fbGeomWidth()) {
    nx1 = fbGeomWidth();
  }
  if (ny1 > fbGeomHeight()) {
    ny1 = fbGeomHeight();
  }
  if (nx0 >= nx1) {
    return;
  }
  if (ny0 >= ny1) {
    return;
  }
  final u64 f = wmPage(u64(wmPageWFlags));
  u64 ux0 = nx0;
  u64 uy0 = ny0;
  u64 ux1 = nx1;
  u64 uy1 = ny1;
  if ((f & u64(wmPageFlagDamage)) > u64(0)) {
    if (wmPage(u64(wmPageWDmgX0)) < ux0) {
      ux0 = wmPage(u64(wmPageWDmgX0));
    }
    if (wmPage(u64(wmPageWDmgY0)) < uy0) {
      uy0 = wmPage(u64(wmPageWDmgY0));
    }
    if (wmPage(u64(wmPageWDmgX1)) > ux1) {
      ux1 = wmPage(u64(wmPageWDmgX1));
    }
    if (wmPage(u64(wmPageWDmgY1)) > uy1) {
      uy1 = wmPage(u64(wmPageWDmgY1));
    }
  }
  wmPageSet(u64(wmPageWDmgX0), ux0);
  wmPageSet(u64(wmPageWDmgY0), uy0);
  wmPageSet(u64(wmPageWDmgX1), ux1);
  wmPageSet(u64(wmPageWDmgY1), uy1);
  u64 n = wmPage(u64(wmPageWDmgN));
  u64 merged = u64(0);
  u64 i = u64(0);
  while (i < n) {
    if (i < u64(wmDmgCap)) {
      final u64 b = u64(wmPageWDmgR0) + (i * u64(4));
      final u64 rx0 = wmPage(b);
      final u64 ry0 = wmPage(b + u64(1));
      final u64 rx1 = wmPage(b + u64(2));
      final u64 ry1 = wmPage(b + u64(3));
      if (wmDmgNear(rx0, ry0, rx1, ry1, nx0, ny0, nx1, ny1) > u64(0)) {
        u64 mx0 = rx0;
        u64 my0 = ry0;
        u64 mx1 = rx1;
        u64 my1 = ry1;
        if (nx0 < mx0) {
          mx0 = nx0;
        }
        if (ny0 < my0) {
          my0 = ny0;
        }
        if (nx1 > mx1) {
          mx1 = nx1;
        }
        if (ny1 > my1) {
          my1 = ny1;
        }
        wmDmgStore(i, mx0, my0, mx1, my1);
        merged = u64(1);
      }
    }
    i = i + u64(1);
  }
  if (merged < u64(1)) {
    if (n < u64(wmDmgCap)) {
      wmDmgStore(n, nx0, ny0, nx1, ny1);
      wmPageSet(u64(wmPageWDmgN), n + u64(1));
    } else {
      /* Cap: collapse to the AABB. Count full when the union is large. */
      wmDmgStore(u64(0), ux0, uy0, ux1, uy1);
      wmPageSet(u64(wmPageWDmgN), u64(1));
      final u64 area = (ux1 - ux0) * (uy1 - uy0);
      final u64 screen = fbGeomWidth() * fbGeomHeight();
      if ((area + area) > screen) {
        wmPageSet(u64(wmPageWDmgFull),
            wmPage(u64(wmPageWDmgFull)) + u64(1));
      }
    }
  }
  wmPageSet(u64(wmPageWFlags), f | u64(wmPageFlagDamage));
  wmPageSet(u64(wmPageWCoalesced), wmPage(u64(wmPageWCoalesced)) + u64(1));
}

/// The whole screen changed. Still a rectangle, because the pacer presents
/// rectangles: "full" is the screen's own.
@bare
void wmDamageAll() {
  wmDamageRect(u64(0), u64(0), fbGeomWidth(), fbGeomHeight());
}

/// Drag/max must present the vacated∪live AABB, not a cursor-sized slice.
/// Geom is installed in the IRQ before drain; a pointer-only present then
/// stamps a corner of the new window onto the old one (ghost trail).
@bare
void wmDamageDragUnion() {
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  final u64 uw = wmPage(u64(wmPageWDefUw));
  if (uw > u64(0)) {
    wmDamageRect(wmPage(u64(wmPageWDefUx)), wmPage(u64(wmPageWDefUy)), uw,
        wmPage(u64(wmPageWDefUh)));
    return;
  }
  final u64 drag = wmMeta(u64(wmMetaDrag));
  if (drag < u64(1)) {
    return;
  }
  final u64 wI = drag - u64(1);
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 b = u64(wmBorder);
  u64 x = wmGeomX(g);
  u64 y = wmGeomY(g);
  if (x >= b) {
    x = x - b;
  } else {
    x = u64(0);
  }
  if (y >= b) {
    y = y - b;
  } else {
    y = u64(0);
  }
  wmDamageRect(x, y, wmGeomW(g) + b + b, wmGeomH(g) + b + b);
}

@bare
u64 wmDamageNeedAtomic() {
  final u64 op = wmPage(u64(wmPageWDefOp));
  if (((op >> u64(16)) & u64(wmDefFlagPending)) > u64(0)) {
    final u64 kind = op & u64(0xFF);
    if (kind == u64(wmDefKindMax)) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Pointer-only dirty rects. Never unions into the window region list, so a
/// cursor packet cannot inherit leftover window AABB and report 100k px.
@bare
void wmDamagePtr(u64 x, u64 y, u64 w, u64 h) {
  if (w < u64(1)) {
    return;
  }
  if (h < u64(1)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  u64 x1 = x + w;
  u64 y1 = y + h;
  if (x1 > fbGeomWidth()) {
    x1 = fbGeomWidth();
  }
  if (y1 > fbGeomHeight()) {
    y1 = fbGeomHeight();
  }
  if (x >= x1) {
    return;
  }
  if (y >= y1) {
    return;
  }
  final u64 f = wmPage(u64(wmPageWFlags));
  if ((f & u64(wmPageFlagPtrDmg)) < u64(1)) {
    wmPageSet(u64(wmPageWPtrDmgX0), x);
    wmPageSet(u64(wmPageWPtrDmgY0), y);
    wmPageSet(u64(wmPageWPtrDmgX1), x1);
    wmPageSet(u64(wmPageWPtrDmgY1), y1);
    wmPageSet(u64(wmPageWPtrDmgX2), x);
    wmPageSet(u64(wmPageWPtrDmgY2), y);
    wmPageSet(u64(wmPageWPtrDmgX3), x1);
    wmPageSet(u64(wmPageWPtrDmgY3), y1);
  } else {
    wmPageSet(u64(wmPageWPtrDmgX2), x);
    wmPageSet(u64(wmPageWPtrDmgY2), y);
    wmPageSet(u64(wmPageWPtrDmgX3), x1);
    wmPageSet(u64(wmPageWPtrDmgY3), y1);
  }
  wmPageSet(u64(wmPageWFlags), f | u64(wmPageFlagPtrDmg));
}

@bare
void wmDamageClear() {
  final u64 f = wmPage(u64(wmPageWFlags));
  wmPageSet(u64(wmPageWFlags),
      f - (f & (u64(wmPageFlagDamage) | u64(wmPageFlagFull))));
  wmPageSet(u64(wmPageWDmgN), u64(0));
}

@bare
u64 wmDamagePending() {
  return (wmPage(u64(wmPageWFlags)) >> u64(1)) & u64(1);
}


// ---------------------------------------------------------------------------
// The pacer
// ---------------------------------------------------------------------------

/// Monotonic accumulate. Pending words may go to zero after consume.
@bare
void wmDmgAcc(u64 px, u64 regs, u64 ptrPx, u64 consumed) {
  wmPageSet(u64(wmPageWDmgCumPx), wmPage(u64(wmPageWDmgCumPx)) + px);
  wmPageSet(u64(wmPageWDmgCumRegs), wmPage(u64(wmPageWDmgCumRegs)) + regs);
  wmPageSet(u64(wmPageWDmgCumPtr), wmPage(u64(wmPageWDmgCumPtr)) + ptrPx);
  wmPageSet(u64(wmPageWDmgCumCons), wmPage(u64(wmPageWDmgCumCons)) + consumed);
  /* DESK owns the keyboard, so typed `wm dmg` never reaches the shell.
   * A 16-consume summary is the queryable cumulative path. */
  if ((wmPage(u64(wmPageWDmgCumCons)) & u64(15)) == u64(0)) {
    wmDmgLine();
  }
}

/// Presents pending dirty region(s) and clears them. Dart only.
/// Snapshot the discrete list before [wmDamageClear] zeros N.
@bare
void wmDmgLine() {
  uartWrite(Rodata.addressOf(wmDmgStrLine), u64(7));
  uartPutHex(wmPage(u64(wmPageWDmgPx)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrRg), u64(4));
  uartPutHex(wmPage(u64(wmPageWDmgRegs)), u64(2));
  uartWrite(Rodata.addressOf(wmDmgStrFl), u64(4));
  uartPutHex(wmPage(u64(wmPageWDmgFull)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrPtr), u64(5));
  uartPutHex(wmPage(u64(wmPageWPtrPx)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrCum), u64(5));
  uartPutHex(wmPage(u64(wmPageWDmgCumPx)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrCrg), u64(5));
  uartPutHex(wmPage(u64(wmPageWDmgCumRegs)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrCfl), u64(5));
  uartPutHex(wmPage(u64(wmPageWDmgCumFull)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrCptr), u64(6));
  uartPutHex(wmPage(u64(wmPageWDmgCumPtr)), u64(8));
  uartWrite(Rodata.addressOf(wmDmgStrCons), u64(6));
  uartPutHex(wmPage(u64(wmPageWDmgCumCons)), u64(8));
  uartNewline();
}

@bare
void wmDmgCmd() {
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  wmDmgLine();
}

@bare
void wmPacePresent() {
  final u64 flags0 = wmPage(u64(wmPageWFlags));
  u64 ptrOnly = u64(0);
  if ((flags0 & u64(wmPageFlagPtrDmg)) > u64(0)) {
    if (wmDamagePending() < u64(1)) {
      ptrOnly = u64(1);
    }
    wmPageSet(u64(wmPageWFlags), flags0 - (flags0 & u64(wmPageFlagPtrDmg)));
  }
  if (ptrOnly > u64(0)) {
    u64 ptrPx = u64(0);
    final u64 ax0 = wmPage(u64(wmPageWPtrDmgX0));
    final u64 ay0 = wmPage(u64(wmPageWPtrDmgY0));
    final u64 ax1 = wmPage(u64(wmPageWPtrDmgX1));
    final u64 ay1 = wmPage(u64(wmPageWPtrDmgY1));
    final u64 bx0 = wmPage(u64(wmPageWPtrDmgX2));
    final u64 by0 = wmPage(u64(wmPageWPtrDmgY2));
    final u64 bx1 = wmPage(u64(wmPageWPtrDmgX3));
    final u64 by1 = wmPage(u64(wmPageWPtrDmgY3));
    if (ax1 > ax0) {
      if (ay1 > ay0) {
        ptrPx = ptrPx + ((ax1 - ax0) * (ay1 - ay0));
      }
    }
    if (bx1 > bx0) {
      if (by1 > by0) {
        ptrPx = ptrPx + ((bx1 - bx0) * (by1 - by0));
      }
    }
    wmPageSet(u64(wmPageWPtrPx), ptrPx);
    wmPageSet(u64(wmPageWDmgPx), ptrPx);
    wmPageSet(u64(wmPageWDmgRegs), u64(2));
    wmDmgAcc(ptrPx, u64(2), ptrPx, u64(1));
    wmPointerPlace(mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)));
    if (ax1 > ax0) {
      if (ay1 > ay0) {
        virtgpuPresent(ax0, ay0, ax1 - ax0, ay1 - ay0);
      }
    }
    if (bx1 > bx0) {
      if (by1 > by0) {
        virtgpuPresent(bx0, by0, bx1 - bx0, by1 - by0);
      }
    }
    wmPageSet(u64(wmPageWPresented), wmPage(u64(wmPageWPresented)) + u64(1));
    wmLatNotePresent();
    return;
  }
  if (wmDamagePending() < u64(1)) {
    return;
  }
  final u64 x0 = wmPage(u64(wmPageWDmgX0));
  final u64 y0 = wmPage(u64(wmPageWDmgY0));
  final u64 x1 = wmPage(u64(wmPageWDmgX1));
  final u64 y1 = wmPage(u64(wmPageWDmgY1));
  u64 regs = wmPage(u64(wmPageWDmgN));
  u64 r0x0 = u64(0);
  u64 r0y0 = u64(0);
  u64 r0x1 = u64(0);
  u64 r0y1 = u64(0);
  u64 r1x0 = u64(0);
  u64 r1y0 = u64(0);
  u64 r1x1 = u64(0);
  u64 r1y1 = u64(0);
  u64 r2x0 = u64(0);
  u64 r2y0 = u64(0);
  u64 r2x1 = u64(0);
  u64 r2y1 = u64(0);
  u64 r3x0 = u64(0);
  u64 r3y0 = u64(0);
  u64 r3x1 = u64(0);
  u64 r3y1 = u64(0);
  if (regs > u64(0)) {
    r0x0 = wmPage(u64(wmPageWDmgR0));
    r0y0 = wmPage(u64(wmPageWDmgR0) + u64(1));
    r0x1 = wmPage(u64(wmPageWDmgR0) + u64(2));
    r0y1 = wmPage(u64(wmPageWDmgR0) + u64(3));
  }
  if (regs > u64(1)) {
    r1x0 = wmPage(u64(wmPageWDmgR0) + u64(4));
    r1y0 = wmPage(u64(wmPageWDmgR0) + u64(5));
    r1x1 = wmPage(u64(wmPageWDmgR0) + u64(6));
    r1y1 = wmPage(u64(wmPageWDmgR0) + u64(7));
  }
  if (regs > u64(2)) {
    r2x0 = wmPage(u64(wmPageWDmgR0) + u64(8));
    r2y0 = wmPage(u64(wmPageWDmgR0) + u64(9));
    r2x1 = wmPage(u64(wmPageWDmgR0) + u64(10));
    r2y1 = wmPage(u64(wmPageWDmgR0) + u64(11));
  }
  if (regs > u64(3)) {
    r3x0 = wmPage(u64(wmPageWDmgR0) + u64(12));
    r3y0 = wmPage(u64(wmPageWDmgR0) + u64(13));
    r3x1 = wmPage(u64(wmPageWDmgR0) + u64(14));
    r3y1 = wmPage(u64(wmPageWDmgR0) + u64(15));
  }
  wmDamageClear();
  if (x1 <= x0) {
    return;
  }
  if (y1 <= y0) {
    return;
  }
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmReap();
  wmPointerRestore();
  u64 px = u64(0);
  final u64 unionA = (x1 - x0) * (y1 - y0);
  final u64 screen = fbGeomWidth() * fbGeomHeight();
  /* Drag/max: always the AABB (no discrete cursor slice). Full fallback
   * only when the union covers most of the scanout. */
  if (wmDamageNeedAtomic() > u64(0)) {
    px = wmRepaintRect(x0, y0, x1 - x0, y1 - y0);
    regs = u64(1);
  } else if ((unionA + unionA + unionA) > (screen + screen)) {
    px = wmRepaintRect(x0, y0, x1 - x0, y1 - y0);
    regs = u64(1);
    wmPageSet(u64(wmPageWDmgFull), wmPage(u64(wmPageWDmgFull)) + u64(1));
    wmPageSet(u64(wmPageWDmgCumFull), wmPage(u64(wmPageWDmgCumFull)) + u64(1));
  } else {
    if (regs < u64(1)) {
      px = wmRepaintRect(x0, y0, x1 - x0, y1 - y0);
      regs = u64(1);
    } else {
      if (r0x1 > r0x0) {
        if (r0y1 > r0y0) {
          px = px + wmRepaintRect(r0x0, r0y0, r0x1 - r0x0, r0y1 - r0y0);
        }
      }
      if (regs > u64(1)) {
        if (r1x1 > r1x0) {
          if (r1y1 > r1y0) {
            px = px + wmRepaintRect(r1x0, r1y0, r1x1 - r1x0, r1y1 - r1y0);
          }
        }
      }
      if (regs > u64(2)) {
        if (r2x1 > r2x0) {
          if (r2y1 > r2y0) {
            px = px + wmRepaintRect(r2x0, r2y0, r2x1 - r2x0, r2y1 - r2y0);
          }
        }
      }
      if (regs > u64(3)) {
        if (r3x1 > r3x0) {
          if (r3y1 > r3y0) {
            px = px + wmRepaintRect(r3x0, r3y0, r3x1 - r3x0, r3y1 - r3y0);
          }
        }
      }
    }
  }
  wmPageSet(u64(wmPageWDmgPx), px);
  wmPageSet(u64(wmPageWDmgRegs), regs);
  wmDmgAcc(px, regs, u64(0), u64(1));
  if (wmPaceLogging() > u64(0)) {
    wmDmgLine();
  }
  wmPointerPlace(mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)));
  wmPageSet(u64(wmPageWPresented), wmPage(u64(wmPageWPresented)) + u64(1));
  wmLatNotePresent();
  if (x1 > x0) {
    if (y1 > y0) {
      wmPublishFrameQ(px, u64(1) - wmPaceLogging(), x0, y0, x1 - x0, y1 - y0);
    } else {
      wmPublishFrameQ(px, u64(1) - wmPaceLogging(), u64(0), u64(0), u64(0),
          u64(0));
    }
  } else {
    wmPublishFrameQ(px, u64(1) - wmPaceLogging(), u64(0), u64(0), u64(0),
        u64(0));
  }
  wmSetMeta(u64(wmMetaBusy), u64(0));
}

/// **THE FRAME CLOCK.** Called from the IRQ0 arm of `isrDispatch`, before
/// `procTick` — which on one path does not return.
///
/// Everything expensive is behind a test that is one load and a compare, so an
/// unarmed or undamaged system pays exactly that per tick and nothing else.
/// Note the order: `paced` first, because a machine that never typed
/// `wm pace` must not touch the state page at all.
@bare
void wmFrameTick() {
  /* Tick context, not the input IRQ: drain coalesced menu/drag/max. */
  if (wmActive() > u64(0)) {
    if (wmMeta(u64(wmMetaBusy)) < u64(1)) {
      wmDefDrain();
      wmHoldWatch();
    }
  }
  if (wmPaced() < u64(1)) {
    return;
  }
  if (wmDamagePending() < u64(1)) {
    /* Pointer-only dirty is not compose damage. Without this the
     * frame clock dropped sprite presents and SCAN pairing saw no
     * RESOURCE_FLUSH (R27 pointer fps was an OPID token). */
    if ((wmPage(u64(wmPageWFlags)) & u64(wmPageFlagPtrDmg)) < u64(1)) {
      return;
    }
  }
  if (wmActive() < u64(1)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  // THE RE-ENTRANCY GUARD, on [wmPointerTick]'s terms: a commit composes
  // inside a syscall with interrupts on, and two painters in one framebuffer
  // is a torn frame. A tick that finds one running leaves the damage pending
  // and the next tick presents it.
  if (wmMeta(u64(wmMetaBusy)) > u64(0)) {
    return;
  }
  final u64 now = tick_count();
  final u64 last = wmPage(u64(wmPageWLast));
  if (now >= last) {
    if ((now - last) < wmPacePeriod()) {
      wmPageSet(u64(wmPageWLate), wmPage(u64(wmPageWLate)) + u64(1));
      return;
    }
  }
  wmPageSet(u64(wmPageWLast), now);
  wmPacePresent();
}

// ---------------------------------------------------------------------------
// `wm pace`
// ---------------------------------------------------------------------------

/// `WM PACE <armed:2> HZ <hz:4> P <period:4> PRES <n:8> COAL <n:8> LATE <n:8>`
/// then the desk-cache line. One report, so a reader can divide.
@bare
void wmPaceLine() {
  uartWrite(Rodata.addressOf(wmPaceStrLine), u64(8));
  uartPutHex(wmPaced(), u64(2));
  uartWrite(Rodata.addressOf(wmPaceStrHz), u64(4));
  uartPutHex(u64(wmPaceTickHz) ~/ wmPacePeriod(), u64(4));
  uartWrite(Rodata.addressOf(wmPaceStrP), u64(3));
  uartPutHex(wmPacePeriod(), u64(4));
  uartWrite(Rodata.addressOf(wmPaceStrPres), u64(6));
  uartPutHex(wmPage(u64(wmPageWPresented)), u64(8));
  uartWrite(Rodata.addressOf(wmPaceStrCoal), u64(6));
  uartPutHex(wmPage(u64(wmPageWCoalesced)), u64(8));
  uartWrite(Rodata.addressOf(wmPaceStrLate), u64(6));
  uartPutHex(wmPage(u64(wmPageWLate)), u64(8));
  uartNewline();
  wmDmgLine();
  if (wmPage(u64(wmPageWDeskBuf)) < u64(1)) {
    uartWrite(Rodata.addressOf(wmDeskStrNone), u64(12));
    uartNewline();
    wmChromeReportLine();
    return;
  }
  uartWrite(Rodata.addressOf(wmDeskStrLine), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrPx), u64(3));
  uartPutHex(wmPage(u64(wmPageWDeskPx)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrFrm), u64(5));
  uartPutHex(wmPage(u64(wmPageWDeskFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrRegen), u64(7));
  uartPutHex(wmPage(u64(wmPageWDeskRegen)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrBlit), u64(6));
  uartPutHex(wmPage(u64(wmPageWDeskBlits)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrRead), u64(6));
  uartPutHex(wmPage(u64(wmPageWDeskReads)), u64(8));
  uartNewline();
  wmChromeReportLine();
}

/// `WM CHROME PX <px> FRM <n> REGEN <n> BLIT <n> GLYPH <n> HIT <n>`.
///
/// REGEN over BLIT is ADR-0191's whole claim as a number out of the running
/// OS: how many times Skia rasterised the chrome against how many session
/// ticks one rasterisation served. GLYPH over HIT is the same ratio for the
/// A8 run masks inside a rasterisation (GAP-0327).
@bare
void wmChromeReportLine() {
  if (wmPage(u64(wmPageWChromeBuf)) < u64(1)) {
    uartWrite(Rodata.addressOf(wmChromeStrNone), u64(14));
    uartNewline();
    wmRestoreReportLine();
    return;
  }
  uartWrite(Rodata.addressOf(wmChromeStrLine), u64(10));
  uartWrite(Rodata.addressOf(wmDeskStrPx), u64(3));
  uartPutHex(wmPage(u64(wmPageWChromePx)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrFrm), u64(5));
  uartPutHex(wmPage(u64(wmPageWChromeFrames)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrRegen), u64(7));
  uartPutHex(wmPage(u64(wmPageWChromeRegen)), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrBlit), u64(6));
  uartPutHex(wmPage(u64(wmPageWChromeBlits)), u64(8));
  uartWrite(Rodata.addressOf(wmChromeStrGlyph), u64(7));
  uartPutHex(wmPage(u64(wmPageWGlyphFill)), u64(8));
  uartWrite(Rodata.addressOf(wmChromeStrHit), u64(5));
  uartPutHex(wmPage(u64(wmPageWGlyphHit)), u64(8));
  uartNewline();
  // `WM BAND FILL <n> HIT <n>` -- the taskbar gradient, which measured at 88%
  // of a chrome rasterisation. FILL is how many times Skia ran the gradient
  // shader over the strip; HIT is how many rasterisations blitted its output.
  uartWrite(Rodata.addressOf(wmBandStrLine), u64(8));
  uartWrite(Rodata.addressOf(wmDeskStrPx), u64(3));
  uartPutHex(wmPage(u64(wmPageWBandPx)), u64(8));
  uartWrite(Rodata.addressOf(wmBandStrFill), u64(6));
  uartPutHex(wmPage(u64(wmPageWBandFill)), u64(8));
  uartWrite(Rodata.addressOf(wmChromeStrHit), u64(5));
  uartPutHex(wmPage(u64(wmPageWBandHit)), u64(8));
  uartNewline();
  wmRestoreReportLine();
}

/// `WM RESTORE N <n> PX <n> SKIP <n>` -- ADR-0190.
///
/// N is how many uncached session presents needed a following client re-blit,
/// PX is the client pixels those restores put back, and SKIP is how many were
/// deferred to the next interrupt because a compose held [wmMetaBusy]. N may
/// remain zero when every present used the chrome-cache blitter, which cuts
/// holes for live client bodies before touching the scanout.
@bare
void wmRestoreReportLine() {
  uartWrite(Rodata.addressOf(wmRestoreStrLine), u64(13));
  uartPutHex(wmPage(u64(wmPageWRestores)), u64(8));
  uartWrite(Rodata.addressOf(wmRestoreStrPx), u64(4));
  uartPutHex(wmPage(u64(wmPageWRestorePx)), u64(8));
  uartWrite(Rodata.addressOf(wmRestoreStrSkip), u64(6));
  uartPutHex(wmPage(u64(wmPageWRestoreSkip)), u64(8));
  uartNewline();
}

/// `wm pace` -- arm the frame clock at [period] ticks and report.
///
/// **UNMASKS IRQ0 AND MEANS IT.** The PIT has been masked at rest since M2
/// (`picUnmaskKeyboardOnly`), for a reason that was completely right at the
/// time — nothing needed a timer, and the still counter is what let `ticks`
/// print a byte-exact number (GAP-0058). A compositor with a refresh rate
/// needs the clock, so this turns it on and [picUnmaskKeyboardOnly] now leaves
/// it on while the pacer is armed. Nothing that does not type this command
/// sees any change at all, which is why every `ticks` golden still holds.
@bare
void wmPaceArm(u64 period) {
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWPeriod), period);
  wmPageSet(u64(wmPageWFlags),
      wmPage(u64(wmPageWFlags)) | u64(wmPageFlagPaced));
  wmPageSet(u64(wmPageWLast), tick_count());
  picUnmaskTimerAndKeyboard();
  wmPaceLine();
}

@bare
void wmPaceCmd() {
  wmPaceArm(u64(wmPacePeriodDefault));
}

@bare
void wmPaceCmd4() {
  wmPaceArm(u64(4));
}

/// `wm pace off` -- disarm, and put the PIC mask back the way the shell keeps
/// it unless a process is resident (which is [shellTicks]'s condition, and for
/// its reason: a spawned process can only leave the CPU through a tick).
@bare
void wmPaceOffCmd() {
  if (wmPageAddr() > u64(0)) {
    final u64 f = wmPage(u64(wmPageWFlags));
    wmPageSet(u64(wmPageWFlags), f - (f & u64(wmPageFlagPaced)));
  }
  if (procHead(u64(procHeadResident)) < u64(1)) {
    picUnmaskKeyboardOnly();
  }
  wmPaceLine();
}

/// `wm pace log` -- arm, and print `WM FRAME` for paced presents too. A debug
/// run, not a default: at 50 fps that line is the frame budget.
@bare
void wmPaceLogCmd() {
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWFlags),
      wmPage(u64(wmPageWFlags)) | u64(wmPageFlagLog));
  wmPaceArm(u64(wmPacePeriodDefault));
}
