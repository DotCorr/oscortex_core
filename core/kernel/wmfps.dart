// core/kernel/wmfps.dart
//
// MEASUREMENT ONLY. Nothing here is on the presentation path; `wm fps`
// is a shell command that times the stages the path is already made of
// against the 100 Hz PIT and prints the iteration count next to the
// tick count, so ms-per-frame is a division a reader performs rather
// than a number this file rounds.
//
// The stages are the real functions, called in the real order, with no
// copy of their bodies here: [wmCompose] is the frame, `osgfx_guest_tick`
// is the session paint, [fbFill] is the solid desktop the session paint
// replaced, and [wmFpsBlitAll] is the client-blit half of a compose.
// A second copy of any of them would measure this file instead.
//
// The desk A/B is the mailbox, not a second desk: OSGFX_GUEST_WALL_IMG
// makes `osgfx_session_paint` take its solid-rect arm over the same
// rectangle with the same DE chrome after it, so the difference between
// stage 4 and stage 3 is the generative field maths and nothing else.

part of 'kmain.dart';

/// `osgfx_fill_desk_generative` (osgfx_desk.c). Declared here so the
/// generative desktop can be timed on its own.
///
/// **This is the one stage that had to be called directly rather than
/// reached through a mailbox flag.** The flag route — `OSGFX_GUEST_WALL_IMG`,
/// which makes `osgfx_session_paint` take its solid arm — sends a
/// full-screen `osgfx_fill_rect` through Graphite, and on Venus that is
/// the case `osgfx_session.c` already warns about ("Graphite-alone used
/// to repaint a full Venus 1200x720 desk every tick"); measured, it
/// `#GP`s. The generative fill writes the framebuffer directly and takes
/// no OsGfx, so calling it is the same work the session tick does.
///
/// C takes `int` / `uint32_t` for everything after `fb`; the low half of
/// each `u64` is what the callee reads, and the two stack-passed
/// arguments occupy the low four bytes of their eight-byte slots.
@extern
external void osgfx_fill_desk_generative(u64 fb, u64 pitch, u64 x, u64 y,
    u64 w, u64 h, u64 seed, u64 frame);

/// Tick budget per stage. The PIT is 100 Hz (`pitInit`), so 120 ticks is
/// ~1.2 s. Sized off the FIRST run rather than guessed: at 800x600 a
/// compose measured ~100 ms, and a 300 ms budget gave `N 3`, whose
/// quantisation is 33% of the answer. 1.2 s gives `N 12` and 8%.
const int wmFpsTicks = 120;

/// Iteration cap. A stage that costs nothing would otherwise print
/// hundreds of thousands of `WM FRAME` lines down the same serial line
/// the measurement is competing with.
const int wmFpsMaxIter = 3000;

const int wmFpsKindUart = 0;
const int wmFpsKindFill = 1;
const int wmFpsKindBlit = 2;
const int wmFpsKindDeskGen = 3;
const int wmFpsKindTickGen = 4;
const int wmFpsKindCompose = 5;
const int wmFpsKindTickSolid = 6;
const int wmFpsKindTickBare = 7;

/// `'wm fps'` -- 6 bytes.
@rodata
final List<u8> wmFpsStrCmd = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x66), u8(0x70), u8(0x73),
];

/// `'WM FPS K '` -- 9 bytes.
@rodata
final List<u8> wmFpsStrOut = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x46), u8(0x50), u8(0x53), u8(0x20),
  u8(0x4B), u8(0x20),
];

/// `' N '` -- 3 bytes.
@rodata
final List<u8> wmFpsStrN = const [
  u8(0x20), u8(0x4E), u8(0x20),
];

/// `' T '` -- 3 bytes.
@rodata
final List<u8> wmFpsStrT = const [
  u8(0x20), u8(0x54), u8(0x20),
];

/// The client-blit half of [wmCompose]: every usable window, bottom-up,
/// through the same [wmDrawWindow] a compose calls.
///
/// The pixel count is returned and folded into a meta word by the
/// caller rather than dropped, for [wmPointerTick]'s reason: `dcc`
/// refuses a non-void call as a statement.
@bare
u64 wmFpsBlitAll() {
  u64 px = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowUsable(i) > u64(0)) {
      px = px + wmDrawWindow(i, u64(0));
    }
    i = i + u64(1);
  }
  return px;
}

/// Arms the mailbox exactly as a frame does, then sets
/// `OSGFX_GUEST_WALL_IMG` so `osgfx_session_paint` takes its
/// `osgfx_fill_rect` arm for the desktop instead of
/// `osgfx_fill_desk_generative`. Window chrome, the DE strip and the
/// title controls are unchanged, because `OSGFX_GUEST_DE` is left set.
@bare
void wmFpsKickSolid() {
  wmGfxKick();
  final u64 mailbox = kernel_data_start();
  final u64 f = Pointer<u64>.fromAddress(mailbox + u64(8)).value;
  Pointer<u64>.fromAddress(mailbox + u64(8)).value =
      f | u64(osgfxGuestWallImg);
}

/// As [wmFpsKickSolid], and additionally clears `OSGFX_GUEST_DE` so
/// `osgfx_session_paint` skips `paint_de_strip` and the title controls
/// and stamps the chrome strip with one `osgfx_fill_rect` instead.
///
/// This is the floor of a session tick: two solid rectangles through the
/// osgfx path and nothing anti-aliased. Subtracting it from the
/// `WALL_IMG`-only stage is what puts a number on the DE chrome without
/// a second copy of the chrome living in this file.
@bare
void wmFpsKickBare() {
  wmFpsKickSolid();
  final u64 mailbox = kernel_data_start();
  final u64 f = Pointer<u64>.fromAddress(mailbox + u64(8)).value;
  Pointer<u64>.fromAddress(mailbox + u64(8)).value =
      f - (f & u64(osgfxGuestDe));
}

/// The generative desktop over the same rectangle the session tick
/// gives it: the full width, and the height above the chrome strip.
/// The seed and frame come from the mailbox, so the field this paints is
/// the field the session paints.
@bare
void wmFpsDeskGen() {
  final u64 mailbox = kernel_data_start();
  final u64 w = fbGeomWidth();
  final u64 h = fbGeomHeight();
  u64 deskH = h - u64(wmChromeH);
  if (deskH < u64(1)) {
    deskH = h;
  }
  final u64 desk =
      Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value;
  final u64 gen = Pointer<u64>.fromAddress(mailbox + u64(72)).value;
  u64 seed = desk & u64(0xFFFFFFFF);
  if (seed < u64(1)) {
    seed = u64(0xD074A17);
  }
  osgfx_fill_desk_generative(fbState(u64(fbStateBase)),
      fbState(u64(fbStatePitch)), u64(0), u64(0), w, deskH, seed,
      gen & u64(0xFFFFFFFF));
}

/// One `WM FRAME`-shaped line, so the serial cost every real frame pays
/// in [wmPublishFrame] has a stage of its own and does not hide inside
/// the compose number.
@bare
void wmFpsLine() {
  uartWrite(Rodata.addressOf(wmStrFrame), u64(11));
  uartPutHex(u64(0), u64(8));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(u64(0), u64(8));
  uartNewline();
}

/// One iteration of stage [kind].
@bare
void wmFpsWork(u64 kind) {
  if (kind == u64(wmFpsKindCompose)) {
    wmCompose();
    return;
  }
  if (kind == u64(wmFpsKindTickGen)) {
    wmGfxKick();
    osgfx_guest_tick();
    return;
  }
  if (kind == u64(wmFpsKindTickSolid)) {
    wmFpsKickSolid();
    osgfx_guest_tick();
    return;
  }
  if (kind == u64(wmFpsKindTickBare)) {
    wmFpsKickBare();
    osgfx_guest_tick();
    return;
  }
  if (kind == u64(wmFpsKindDeskGen)) {
    wmFpsDeskGen();
    return;
  }
  if (kind == u64(wmFpsKindFill)) {
    fbFill(u64(wmColorDesktop));
    return;
  }
  if (kind == u64(wmFpsKindBlit)) {
    final u64 px = wmFpsBlitAll();
    wmSetMeta(u64(wmMetaRectPixels),
        wmMeta(u64(wmMetaRectPixels)) + px);
    return;
  }
  wmFpsLine();
}

/// Runs stage [kind] until the tick counter has advanced [wmFpsTicks],
/// then prints `WM FPS K <kind> N <iterations> T <ticks>`.
///
/// The printed tick count is the MEASURED one, not [wmFpsTicks]: a
/// stage whose single iteration outlasts the budget reports `N 1` and
/// the ticks it actually took, which is the case that matters most and
/// the one a fixed denominator would hide.
@bare
void wmFpsRun(u64 kind) {
  final u64 t0 = tick_count();
  final u64 target = t0 + u64(wmFpsTicks);
  u64 n = u64(0);
  u64 now = t0;
  while (now < target) {
    wmFpsWork(kind);
    n = n + u64(1);
    now = tick_count();
    if (n >= u64(wmFpsMaxIter)) {
      now = target;
    }
  }
  uartWrite(Rodata.addressOf(wmFpsStrOut), u64(9));
  uartPutHex(kind, u64(1));
  uartWrite(Rodata.addressOf(wmFpsStrN), u64(3));
  uartPutHex(n, u64(8));
  uartWrite(Rodata.addressOf(wmFpsStrT), u64(3));
  uartPutHex(now - t0, u64(8));
  uartNewline();
}

/// `wm fps` -- six timed stages, cheapest first.
///
/// **IRQ0 is unmasked for the whole command and re-masked on the way
/// out**, on [shellTicks]'s terms and for its reason: the tick counter
/// is the clock, and with the PIT masked at rest every loop below would
/// spin forever. The re-mask is conditional on there being no resident
/// process for [shellTicks]'s other reason — a spawned process can only
/// leave the CPU through a tick.
///
/// Cheapest first so the expensive stages inherit a framebuffer the
/// cheap ones already dirtied, and so a run that times out has still
/// printed the numbers that bound the ones it did not reach.
@bare
void wmFpsCmd() {
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  picUnmaskTimerAndKeyboard();
  wmFpsRun(u64(wmFpsKindUart));
  // Compose FIRST as well as last. The first run of this command showed
  // a compose costing more than the session tick it is almost entirely
  // made of, which is either a real cost outside the tick or drift
  // across the run. Two numbers for one stage, at opposite ends,
  // is what tells those two apart.
  wmFpsRun(u64(wmFpsKindCompose));
  wmFpsRun(u64(wmFpsKindFill));
  wmFpsRun(u64(wmFpsKindBlit));
  wmFpsRun(u64(wmFpsKindDeskGen));
  wmFpsRun(u64(wmFpsKindTickGen));
  wmFpsRun(u64(wmFpsKindCompose));
  // LAST, because on Venus this one takes a full-screen osgfx_fill_rect
  // through Graphite and #GPs — measured. Every number above it is
  // already printed when it does.
  wmFpsRun(u64(wmFpsKindTickSolid));
  if (procHead(u64(procHeadResident)) < u64(1)) {
    picUnmaskKeyboardOnly();
  }
}
