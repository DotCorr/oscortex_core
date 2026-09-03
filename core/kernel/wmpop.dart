// core/kernel/wmpop.dart
//
// Compositor-owned right-click popover. ADR-0070. OSXUI1.
// ADR-0182: under `wm de` the popover is a wallpaper menu (Regenerate /
// Set image), with prefs in WALL.DAT and the osgfx mailbox desk/wall
// words. Without `wm de` the empty coloured box is unchanged (osxui1-pop).
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` compiles exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// THIS FILE HAS NO @bss. Visibility is spare word [wmMetaPop] = 21 of the
// existing wmStore meta block; the origin is packed in word 22. Chrome is
// 19, focus is 20, word 23 is gfx. Seed/mode live in the .osgfx_cmd mailbox
// (not .bss). No new block, so every harness that measures wmStore at 448
// bytes, and D7's last place, is unmoved.
//
// ON WHEN THE COMPOSITOR IS ON. [wmPointerTick] already returns if wm is
// off, so sit-in sees the popover without typing `wm chrome`. There is no
// shell command and no help line (GAP-0304).

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Geometry and colour. Named so the host model in osxui1-pop / de-wall
// reads them rather than inventing a second answer.
// ---------------------------------------------------------------------------

/// Measured card width: 5-char labels at 8px plus pad, hover inset, radius.
const int wmPopW = 168;

/// Two action rows plus pad. Variable via [wmPopRows] × [wmPopRowH].
const int wmPopH = 80;

/// Soft shadow painted at content+(ox,oy). Session / Skia use the same pair.
const int wmPopShadowOffX = 4;

/// Soft shadow painted at content+(ox,oy).
const int wmPopShadowOffY = 6;

/// Blur passed to osgfx_shadow. Guest Skia uses blur/6 spread, clamped 1..3.
const int wmPopShadowBlur = 14;

/// Guest Skia shadow spread for [wmPopShadowBlur] (14/6 → 2).
const int wmPopShadowSpread = 2;

/// Skia rrect AA halo outside the content rect. ~3px/side.
const int wmPopAA = 3;

/// Visual pad west of content (AA). Hit-test stays [wmPopW]×[wmPopH].
const int wmPopVisL = 3;

/// Visual pad north of content (AA).
const int wmPopVisT = 3;

/// Visual pad east of content (AA + shadow ox/spread).
const int wmPopVisR = 3;

/// Visual pad south of content (AA + shadow oy + spread). 80+3+10 = 93.
const int wmPopVisB = 10;

/// Near-white card bbox including AA/shadow bleed. Not the hit-test size.
const int wmPopVisW = 174;

/// Near-white card bbox including AA/shadow bleed. Measured 174×93.
const int wmPopVisH = 93;

/// Offset from the pointer to the popover origin. Positive is right and down.
const int wmPopGap = 8;

/// How many action rows the compositor cards paint.
const int wmPopRows = 2;

/// Light card fill. Distinct from desk wallpaper and the title band.
const int wmPopColor = 0x00F4F6FA;

/// First row fill (DE on).
const int wmPopRow0 = 0x00FFFFFF;

/// Second row fill.
const int wmPopRow1 = 0x00EEF2F6;

/// Label ink on a menu row.
const int wmPopLabelFg = 0x00202830;

/// 1px edge / separator.
const int wmPopEdge = 0x00C8D0D8;

/// Soft shadow along the card's south/east edge.
const int wmPopShadow = 0x00687888;

/// Top pad inside the popover before row 0.
const int wmPopRowPad = 8;

/// Row height for Regen / Image / Close / Raise.
const int wmPopRowH = 28;

/// Hover / keyboard selection fill.
const int wmPopHover = 0x00D0E4F8;

/// Disabled label ink.
const int wmPopDisabled = 0x0090A0B0;

/// Label pad inside a row.
const int wmPopLabelPadX = 8;

/// Label pad Y inside a row.
const int wmPopLabelPadY = 4;

/// Spare word of the existing 24-word meta block. 1 while the popover is
/// showing. Words 0..18 are D4/D5b; 19 is chrome; 20 is focus; 23 is gfx.
/// Not a new `@bss`.
const int wmMetaPop = 21;

/// Packed origin `(x << 32) | y` while [wmMetaPop] is 1. Ignored when 0.
const int wmMetaPopXY = 22;

/// Mailbox offset of `desk` (seed | mode<<32). After vk at +80.
const int wmPopMailDesk = 88;

/// Mailbox offset of `wall` (solid RGB when mode is image).
const int wmPopMailWall = 96;

/// WALL.DAT record: magic.
const int wmWallMagic = 0x4C4C4157;

/// WALL.DAT bytes on disk.
const int wmWallBytes = 16;

/// `'WALL.DAT'` -- 8 bytes. fatParseAt path form.
@rodata
final List<u8> wmStrWallPath = const [
  u8(0x57), u8(0x41), u8(0x4C), u8(0x4C), u8(0x2E), u8(0x44), u8(0x41),
  u8(0x54),
];

/// `'WALL.RAW'` -- 8 bytes. Solid ARGB plant for Set image.
@rodata
final List<u8> wmStrWallRawPath = const [
  u8(0x57), u8(0x41), u8(0x4C), u8(0x4C), u8(0x2E), u8(0x52), u8(0x41),
  u8(0x57),
];

/// `'Regen'` -- 5 bytes. Menu label.
@rodata
final List<u8> wmStrPopRegen = const [
  u8(0x52), u8(0x65), u8(0x67), u8(0x65), u8(0x6E),
];

/// `'Image'` -- 5 bytes. Menu label.
@rodata
final List<u8> wmStrPopImage = const [
  u8(0x49), u8(0x6D), u8(0x61), u8(0x67), u8(0x65),
];

/// `'Close'` -- 5 bytes. Title/dock context row.
@rodata
final List<u8> wmStrPopClose = const [
  u8(0x43), u8(0x6C), u8(0x6F), u8(0x73), u8(0x65),
];

/// `'Raise'` -- 5 bytes. Title/dock context row.
@rodata
final List<u8> wmStrPopRaise = const [
  u8(0x52), u8(0x61), u8(0x69), u8(0x73), u8(0x65),
];

/// Compositor card kinds. 2/3 are DESK launch/panel (wmde.dart).
const int wmPopWall = 1;
const int wmPopWin = 4;
const int wmPopDock = 5;

/// `'WM WALL REGEN '` -- 14 bytes.
@rodata
final List<u8> wmStrWallRegen = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x57), u8(0x41), u8(0x4C), u8(0x4C),
  u8(0x20), u8(0x52), u8(0x45), u8(0x47), u8(0x45), u8(0x4E), u8(0x20),
];

/// `'WM WALL IMG '` -- 12 bytes.
@rodata
final List<u8> wmStrWallImg = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x57), u8(0x41), u8(0x4C), u8(0x4C),
  u8(0x20), u8(0x49), u8(0x4D), u8(0x47), u8(0x20),
];

/// `'WM WALL MISS'` -- 12 bytes.
@rodata
final List<u8> wmStrWallMiss = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x57), u8(0x41), u8(0x4C), u8(0x4C),
  u8(0x20), u8(0x4D), u8(0x49), u8(0x53), u8(0x53),
];

/// `'WM WALL MENU'` -- 12 bytes.
@rodata
final List<u8> wmStrWallMenu = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x57), u8(0x41), u8(0x4C), u8(0x4C),
  u8(0x20), u8(0x4D), u8(0x45), u8(0x4E), u8(0x55),
];

/// `'WM CTX FILE'` -- 11 bytes.
@rodata
final List<u8> wmStrCtxFile = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x54), u8(0x58), u8(0x20),
  u8(0x46), u8(0x49), u8(0x4C), u8(0x45),
];

/// `'WM CTX TITLE'` -- 12 bytes.
@rodata
final List<u8> wmStrCtxTitle = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x54), u8(0x58), u8(0x20),
  u8(0x54), u8(0x49), u8(0x54), u8(0x4C), u8(0x45),
];

/// `'WM CTX SLOT'` -- 11 bytes.
@rodata
final List<u8> wmStrCtxSlot = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x54), u8(0x58), u8(0x20),
  u8(0x53), u8(0x4C), u8(0x4F), u8(0x54),
];

/// `'WM CTX NONE'` -- 11 bytes.
@rodata
final List<u8> wmStrCtxNone = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x54), u8(0x58), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45),
];

/// `'WM CTX DOCK'` -- 11 bytes.
@rodata
final List<u8> wmStrCtxDock = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x54), u8(0x58), u8(0x20),
  u8(0x44), u8(0x4F), u8(0x43), u8(0x4B),
];

/// `'WM WIN MENU'` -- 11 bytes.
@rodata
final List<u8> wmStrWinMenu = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x57), u8(0x49), u8(0x4E), u8(0x20),
  u8(0x4D), u8(0x45), u8(0x4E), u8(0x55),
];

/// `'WM DOCK MENU'` -- 12 bytes.
@rodata
final List<u8> wmStrDockMenu = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x4F), u8(0x43), u8(0x4B),
  u8(0x20), u8(0x4D), u8(0x45), u8(0x4E), u8(0x55),
];

// ---------------------------------------------------------------------------
// Draw, hit, show, hide. [wmCompose], [wmPixelAt], [wmPointerTick] and
// [wmGrab] are the callers. GAP-0302: this is the start of a right-click
// policy, not close or resize.
// ---------------------------------------------------------------------------

/// Kind in the low 8 bits of [wmMetaPop]. Hover row lives in bits 8..15.
@bare
u64 wmPopKind() {
  return wmMeta(u64(wmMetaPop)) & u64(0xFF);
}

/// Hover / keyboard row, or 0xFF when none.
@bare
u64 wmPopHoverRow() {
  return (wmMeta(u64(wmMetaPop)) >> u64(8)) & u64(0xFF);
}

@bare
void wmPopSetHover(u64 row) {
  final u64 k = wmPopKind();
  if (wmPopIsCard(k) < u64(1)) {
    return;
  }
  wmSetMeta(u64(wmMetaPop), k | ((row & u64(0xFF)) << u64(8)));
}

/// 1 if the popover is showing.
@bare
u64 wmPopOn() {
  return wmPopKind();
}

/// 1 if [row] is disabled on the showing card (no usable target).
@bare
u64 wmPopRowDisabled(u64 row) {
  final u64 k = wmPopKind();
  if (k == u64(wmPopWin)) {
    if (wmPopTarget() >= u64(wmMaxWindows)) {
      return u64(1);
    }
  }
  if (k == u64(wmPopDock)) {
    if (wmPopTarget() >= u64(wmMaxWindows)) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Kind, hover, and disabled bits into the session mailbox.
@bare
void wmPopWritePage() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWCtxKind), wmPopKind());
  u64 slot = wmPopHoverRow();
  if (wmPopRowDisabled(u64(0)) > u64(0)) {
    slot = slot | (u64(1) << u64(8));
  }
  if (wmPopRowDisabled(u64(1)) > u64(0)) {
    slot = slot | (u64(1) << u64(9));
  }
  wmPageSet(u64(wmPageWCtxSlot), slot);
}

/// 1 if [k] is a compositor-owned two-row card (wall / window / dock).
@bare
u64 wmPopIsCard(u64 k) {
  final u64 kind = k & u64(0xFF);
  if (kind == u64(wmPopWall)) {
    return u64(1);
  }
  if (kind == u64(wmPopWin)) {
    return u64(1);
  }
  if (kind == u64(wmPopDock)) {
    return u64(1);
  }
  return u64(0);
}

/// Focused or top usable non-panel window, else [wmMaxWindows].
@bare
u64 wmPopTarget() {
  final u64 f = wmFocusLive();
  if (f > u64(0)) {
    final u64 w = f - u64(1);
    if (wmWindowUsable(w) > u64(0)) {
      if (wmIsPanel(w) < u64(1)) {
        return w;
      }
    }
  }
  final u64 t = wmMeta(u64(wmMetaTop));
  if (t < u64(wmMaxWindows)) {
    if (wmWindowUsable(t) > u64(0)) {
      if (wmIsPanel(t) < u64(1)) {
        return t;
      }
    }
  }
  return u64(wmMaxWindows);
}

/// Raise [wI] and print `WM RAISE`.
@bare
void wmPopRaise(u64 wI) {
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  wmSetMeta(u64(wmMetaTop), wI);
  wmFocusTo(wI);
  uartWrite(Rodata.addressOf(wmStrRaise), u64(11));
  uartPutHex(wI, u64(1));
  uartNewline();
  if (wmPageAddr() > u64(0)) {
    wmDefEnqueue(u64(wmDefKindFocus), wI, wmWin(wI, u64(wmWinGeom)),
        wmWin(wI, u64(wmWinGeom)));
  } else {
    final u64 unused = wmRepaintWindow(wI);
  }
}

/// 1 if the popover is showing and ([x], [y]) is inside it.
@bare
u64 wmPopHit(u64 x, u64 y) {
  u64 hit = u64(0);
  if (wmPopIsCard(wmPopKind()) > u64(0)) {
    final u64 packed = wmMeta(u64(wmMetaPopXY));
    final u64 ox = packed >> u64(32);
    final u64 oy = packed & u64(0xFFFFFFFF);
    if (x >= ox) {
      if (y >= oy) {
        if (x < (ox + u64(wmPopW))) {
          if (y < (oy + u64(wmPopH))) {
            hit = u64(1);
          }
        }
      }
    }
  }
  return hit;
}

/// Menu row under ([x], [y]), or 2 if outside the row band.
@bare
u64 wmPopRowAt(u64 x, u64 y) {
  if (wmPopHit(x, y) < u64(1)) {
    return u64(2);
  }
  final u64 packed = wmMeta(u64(wmMetaPopXY));
  final u64 oy = packed & u64(0xFFFFFFFF);
  if (y < (oy + u64(wmPopRowPad))) {
    return u64(2);
  }
  final u64 row = (y - (oy + u64(wmPopRowPad))) ~/ u64(wmPopRowH);
  if (row >= u64(wmPopRows)) {
    return u64(2);
  }
  return row;
}

/// Colour of the popover pixel at ([x], [y]), or [wmPopColor].
@bare
u64 wmPopPixel(u64 x, u64 y) {
  if (wmPopHit(x, y) < u64(1)) {
    return u64(wmPopColor);
  }
  if (wmDeOn() < u64(1)) {
    return u64(wmPopColor);
  }
  final u64 row = wmPopRowAt(x, y);
  if (row == wmPopHoverRow()) {
    return u64(wmPopHover);
  }
  if (row == u64(0)) {
    return u64(wmPopRow0);
  }
  if (row == u64(1)) {
    return u64(wmPopRow1);
  }
  return u64(wmPopColor);
}

/// Paints one 5-char label into the live fb when base is armed.
@bare
void wmPopLabel(u64 ox, u64 oy, u64 row, u64 text) {
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  osxui_label_fb(
      fbState(u64(fbStateBase)),
      fbState(u64(fbStatePitch)),
      (fbGeomWidth() << u64(32)) | fbGeomHeight(),
      ((ox + u64(wmPopLabelPadX)) << u64(32)) |
          (oy + u64(wmPopRowPad) + (row * u64(wmPopRowH)) +
              u64(wmPopLabelPadY)),
      text,
      (u64(5) << u64(32)) | u64(wmPopLabelFg));
}

/// Paints the wallpaper menu rows + labels when `wm de` is on.
@bare
void wmPopMenuDraw(u64 ox, u64 oy) {
  final u64 k = wmPopKind();
  final u64 hover = wmPopHoverRow();
  u64 r0 = u64(wmPopRow0);
  u64 r1 = u64(wmPopRow1);
  if (hover == u64(0)) {
    r0 = u64(wmPopHover);
  }
  if (hover == u64(1)) {
    r1 = u64(wmPopHover);
  }
  wmFillRect(ox + u64(2), oy + u64(wmPopH) - u64(1), u64(wmPopW), u64(2),
      u64(wmPopShadow));
  wmFillRect(ox + u64(wmPopW) - u64(1), oy + u64(2), u64(2), u64(wmPopH),
      u64(wmPopShadow));
  wmFillRect(ox, oy, u64(wmPopW), u64(1), u64(wmPopEdge));
  wmFillRect(ox, oy, u64(1), u64(wmPopH), u64(wmPopEdge));
  wmFillRect(ox + u64(6), oy + u64(wmPopRowPad), u64(wmPopW) - u64(12),
      u64(wmPopRowH) - u64(2), r0);
  wmFillRect(ox + u64(10), oy + u64(wmPopRowPad) + u64(wmPopRowH) - u64(1),
      u64(wmPopW) - u64(20), u64(1), u64(wmPopEdge));
  wmFillRect(ox + u64(6), oy + u64(wmPopRowPad) + u64(wmPopRowH),
      u64(wmPopW) - u64(12), u64(wmPopRowH) - u64(2), r1);
  if (k == u64(wmPopWin)) {
    wmPopLabel(ox, oy, u64(0), Rodata.addressOf(wmStrPopClose));
    wmPopLabel(ox, oy, u64(1), Rodata.addressOf(wmStrPopRaise));
    if (wmPopRowDisabled(u64(0)) > u64(0)) {
      wmFillRect(ox + u64(6), oy + u64(wmPopRowPad), u64(wmPopW) - u64(12),
          u64(1), u64(wmPopDisabled));
    }
    return;
  }
  if (k == u64(wmPopDock)) {
    wmPopLabel(ox, oy, u64(0), Rodata.addressOf(wmStrPopRaise));
    wmPopLabel(ox, oy, u64(1), Rodata.addressOf(wmStrPopClose));
    return;
  }
  wmPopLabel(ox, oy, u64(0), Rodata.addressOf(wmStrPopRegen));
  wmPopLabel(ox, oy, u64(1), Rodata.addressOf(wmStrPopImage));
}

/// Paints the popover if it is showing. Returns the pixels written, or 0
/// when it is off -- so a compose that never saw a right-click does not
/// move its count.
@bare
u64 wmPopDraw() {
  u64 px = u64(0);
  if (wmPopIsCard(wmPopKind()) > u64(0)) {
    final u64 packed = wmMeta(u64(wmMetaPopXY));
    final u64 ox = packed >> u64(32);
    final u64 oy = packed & u64(0xFFFFFFFF);
    wmFillRect(ox, oy, u64(wmPopW), u64(wmPopH), u64(wmPopColor));
    if (wmDeOn() > u64(0)) {
      wmPopMenuDraw(ox, oy);
    }
    px = u64(wmPopW) * u64(wmPopH);
  }
  return px;
}

/// Clears the flag and restores the rectangle from [wmPixelAt]. No-op if
/// the popover is already off.
///
/// Under gfx the chrome cache includes the popover. Repainting from that
/// cache after clearing the flag merely copied the old menu back onto the
/// screen. Regenerate the session frame first; [wmCompose] then restores live
/// client bodies over the new no-pop chrome frame.
@bare
void wmPopDamageRestore(u64 x, u64 y, u64 w, u64 h) {
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    /* HIT restores the vacated card from the chrome cache. Do not
     * wmCompose a 1280×720 restamp to hide a 168×80 menu. */
    wmGfxKick();
    osgfx_guest_tick();
    wmGfxChromeStamp();
    return;
  }
  final u64 unused = wmRepaintRect(x, y, w, h);
}

@bare
void wmPopPaintCard() {
  final u64 packed = wmMeta(u64(wmMetaPopXY));
  final u64 ox = packed >> u64(32);
  final u64 oy = packed & u64(0xFFFFFFFF);
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    /* Prewarmed card is a HIT overlay. Hover labels stay CPU-side. */
    wmGfxKick();
    osgfx_guest_tick();
    wmGfxChromeStamp();
  }
  wmFillRect(ox, oy, u64(wmPopW), u64(wmPopH), u64(wmPopColor));
  if (wmDeOn() > u64(0)) {
    wmPopMenuDraw(ox, oy);
  }
}

@bare
void wmPopDrainPaint(u64 oldG, u64 nextG) {
  if (nextG < u64(1)) {
    wmPopDamageRestore(wmGeomX(oldG), wmGeomY(oldG), u64(wmPopW), u64(wmPopH));
    return;
  }
  if (wmPopIsCard(wmPopKind()) > u64(0)) {
    wmPopPaintCard();
  } else {
    wmPopDamageRestore(wmGeomX(oldG), wmGeomY(oldG), u64(wmPopW), u64(wmPopH));
  }
}

@bare
void wmPopHide() {
  if (wmPopIsCard(wmPopKind()) > u64(0)) {
    final u64 packed = wmMeta(u64(wmMetaPopXY));
    final u64 ox = packed >> u64(32);
    final u64 oy = packed & u64(0xFFFFFFFF);
    wmSetMeta(u64(wmMetaPop), u64(0));
    if (wmPageAddr() > u64(0)) {
      final u64 g = wmPackGeom(ox, oy, u64(wmPopW), u64(wmPopH));
      wmDefEnqueue(u64(wmDefKindMenu), u64(wmDefSlotMenu), g, u64(0));
    } else {
      wmPopDamageRestore(ox, oy, u64(wmPopW), u64(wmPopH));
    }
  }
}

/// 1 when the 168×80 card at ([ox], [oy]) overlaps an ordinary client.
@bare
u64 wmPopClientHit(u64 ox, u64 oy) {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowUsable(i) > u64(0)) {
      if (wmIsPanel(i) < u64(1)) {
        if (wmIsOverlay(i) < u64(1)) {
          final u64 g = wmWin(i, u64(wmWinGeom));
          final u64 cx = wmGeomX(g);
          final u64 cy = wmGeomY(g);
          final u64 cw = wmGeomW(g);
          final u64 ch = wmGeomH(g);
          if (ox < (cx + cw)) {
            if (oy < (cy + ch)) {
              if ((ox + u64(wmPopW)) > cx) {
                if ((oy + u64(wmPopH)) > cy) {
                  return u64(1);
                }
              }
            }
          }
        }
      }
    }
    i = i + u64(1);
  }
  return u64(0);
}

/// 1 when the card stays on-screen and off ordinary clients.
@bare
u64 wmPopFits(u64 ox, u64 oy) {
  if ((ox + u64(wmPopW)) > fbGeomWidth()) {
    return u64(0);
  }
  if ((oy + u64(wmPopH)) > fbGeomHeight()) {
    return u64(0);
  }
  if (wmPopClientHit(ox, oy) > u64(0)) {
    return u64(0);
  }
  return u64(1);
}

/// Lowest y below every ordinary client, or 16 when that would clip.
@bare
u64 wmPopBelowClients() {
  u64 below = u64(16);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowUsable(i) > u64(0)) {
      if (wmIsPanel(i) < u64(1)) {
        if (wmIsOverlay(i) < u64(1)) {
          final u64 g = wmWin(i, u64(wmWinGeom));
          final u64 y2 = wmGeomY(g) + wmGeomH(g) + u64(8);
          if (y2 > below) {
            below = y2;
          }
        }
      }
    }
    i = i + u64(1);
  }
  if ((below + u64(wmPopH) + u64(wmChromeH)) > fbGeomHeight()) {
    below = u64(16);
  }
  return below;
}

/// Places a measured card near ([x], [y]) and paints it. Flips to the
/// pointer's left/above when the default gap would leave the screen.
/// Also walks off ordinary client rects so a wallpaper card is not
/// buried under FILES/SET. A popover that was already showing is hidden
/// first so a second right-click moves it rather than leaving a stale fill.
@bare
void wmPopShowKind(u64 x, u64 y, u64 kind) {
  if (wmPopIsCard(wmPopKind()) > u64(0)) {
    wmPopHide();
  }
  if (wmPopKind() > u64(1)) {
    wmDePopHide();
  }
  u64 ox = x + u64(wmPopGap);
  u64 oy = y + u64(wmPopGap);
  if ((ox + u64(wmPopW)) > fbGeomWidth()) {
    if (x > u64(wmPopW)) {
      ox = x - u64(wmPopW);
    } else {
      ox = fbGeomWidth() - u64(wmPopW);
    }
  }
  if ((oy + u64(wmPopH)) > fbGeomHeight()) {
    if (y > u64(wmPopH)) {
      oy = y - u64(wmPopH);
    } else {
      oy = fbGeomHeight() - u64(wmPopH);
    }
  }
  if (wmPopFits(ox, oy) < u64(1)) {
    u64 lx = u64(0);
    if (x > u64(wmPopW)) {
      lx = x - u64(wmPopW);
    }
    u64 ay = u64(0);
    if (y > u64(wmPopH)) {
      ay = y - u64(wmPopH);
    }
    if (wmPopFits(lx, oy) > u64(0)) {
      ox = lx;
    } else {
      if (wmPopFits(ox, ay) > u64(0)) {
        oy = ay;
      } else {
        if (wmPopFits(lx, ay) > u64(0)) {
          ox = lx;
          oy = ay;
        } else {
          final u64 by = wmPopBelowClients();
          if (wmPopFits(u64(16), by) > u64(0)) {
            ox = u64(16);
            oy = by;
          } else {
            if (wmPopFits(u64(16), u64(16)) > u64(0)) {
              ox = u64(16);
              oy = u64(16);
            }
          }
        }
      }
    }
  }
  wmLatStamp(u64(wmLatKindMenu));
  wmSetMeta(u64(wmMetaPop), kind | (u64(0xFF) << u64(8)));
  wmSetMeta(u64(wmMetaPopXY), (ox << u64(32)) | oy);
  wmPopWritePage();
  if (kind == u64(wmPopWin)) {
    uartWrite(Rodata.addressOf(wmStrWinMenu), u64(11));
    uartNewline();
  } else {
    if (kind == u64(wmPopDock)) {
      uartWrite(Rodata.addressOf(wmStrDockMenu), u64(12));
      uartNewline();
    } else {
      uartWrite(Rodata.addressOf(wmStrWallMenu), u64(12));
      uartNewline();
    }
  }
  /* IRQ: state + enqueue. Paint in drain (syscall/tick). */
  if (wmPageAddr() > u64(0)) {
    final u64 g = wmPackGeom(ox, oy, u64(wmPopW), u64(wmPopH));
    wmDefEnqueue(u64(wmDefKindMenu), u64(wmDefSlotMenu), g, g);
  } else {
    wmPopPaintCard();
  }
}

@bare
void wmPopShow(u64 x, u64 y) {
  wmPopShowKind(x, y, u64(wmPopWall));
}

/// Classify a right press (ADR-0194). Wallpaper menu only on empty desk.
@bare
void wmContextFocus(u64 hit) {
  if (wmIsPanel(hit) > u64(0)) {
    return;
  }
  final u64 oldFocus = wmFocusLive();
  final u64 oldTop = wmMeta(u64(wmMetaTop));
  if (oldTop != hit) {
    wmSetMeta(u64(wmMetaTop), hit);
    wmBumpMeta(u64(wmMetaRaises));
  }
  wmFocusTo(hit);
  u64 chromeChanged = u64(0);
  if (oldFocus != hit + u64(1)) {
    chromeChanged = u64(1);
  }
  if (oldTop != hit) {
    chromeChanged = u64(1);
  }
  if (chromeChanged > u64(0)) {
    if (wmPageAddr() > u64(0)) {
      wmDefEnqueue(u64(wmDefKindFocus), hit, wmWin(hit, u64(wmWinGeom)),
          wmWin(hit, u64(wmWinGeom)));
    } else {
      if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
        wmGfxKick();
        osgfx_guest_tick();
        wmGfxChromeStamp();
      } else {
        if (oldTop != hit) {
          u64 px = wmRepaintWindow(oldTop);
          px = px + wmRepaintWindow(hit);
          wmSetMeta(
              u64(wmMetaRectPixels), wmMeta(u64(wmMetaRectPixels)) + px);
        }
      }
    }
  }
}

@bare
void wmContextShow(u64 x, u64 y) {
  if (wmChromeHit(x, y) > u64(0)) {
    if (wmDeOn() > u64(0)) {
      if (x >= (fbGeomWidth() ~/ u64(2))) {
        uartWrite(Rodata.addressOf(wmStrCtxDock), u64(11));
        uartNewline();
        wmPopShowKind(x, y, u64(wmPopDock));
        return;
      }
    }
    uartWrite(Rodata.addressOf(wmStrCtxNone), u64(11));
    uartNewline();
    return;
  }
  final u64 slot = wmSlotHit(x, y);
  if (slot < u64(wmMaxWindows)) {
    uartWrite(Rodata.addressOf(wmStrCtxSlot), u64(11));
    uartNewline();
    return;
  }
  u64 hit = wmHit(x, y);
  if (wmDeOn() > u64(0)) {
    final u64 geomHit = wmDeGeomHit(x, y);
    if (geomHit < u64(wmMaxWindows)) {
      hit = geomHit;
    }
  }
  if (hit >= u64(wmMaxWindows)) {
    if (wmDeOn() > u64(0)) {
      wmPopShow(x, y);
    } else {
      wmPopShow(x, y);
    }
    return;
  }
  if (wmDeOn() > u64(0)) {
    if (wmTitleHit(hit, x, y) > u64(0)) {
      wmContextFocus(hit);
      uartWrite(Rodata.addressOf(wmStrCtxTitle), u64(12));
      uartNewline();
      wmPopShowKind(x, y, u64(wmPopWin));
      return;
    }
    wmContextFocus(hit);
    uartWrite(Rodata.addressOf(wmStrCtxFile), u64(11));
    uartNewline();
    final u64 wx = wmAbsX(hit);
    final u64 wy = wmAbsY(hit);
    final u64 rx = x - wx;
    final u64 ry = y - wy;
    wmeventPush(hit,
        wmeventPackEdge(u64(wmeventTypeContext), hit, rx, ry));
    return;
  }
  wmPopShow(x, y);
}

/// Current desk seed from the mailbox (low 32 of desk).
@bare
u64 wmWallSeed() {
  final u64 mailbox = kernel_data_start();
  return Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value &
      u64(0xFFFFFFFF);
}

/// Wallpaper mode: 0 generative, 1 solid image colour.
@bare
u64 wmWallMode() {
  final u64 mailbox = kernel_data_start();
  return (Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value >>
          u64(32)) &
      u64(0xFF);
}

/// Writes seed + mode into the mailbox desk word. Preserves wall colour.
@bare
void wmWallSetDesk(u64 seed, u64 mode) {
  final u64 mailbox = kernel_data_start();
  final u64 desk =
      (seed & u64(0xFFFFFFFF)) | ((mode & u64(0xFF)) << u64(32));
  Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value = desk;
}

/// Writes solid RGB into the mailbox wall word.
@bare
void wmWallSetColor(u64 rgb) {
  final u64 mailbox = kernel_data_start();
  Pointer<u64>.fromAddress(mailbox + u64(wmPopMailWall)).value =
      rgb & u64(0x00FFFFFF);
}

/// Loads WALL.DAT into the mailbox when the volume holds it.
@bare
void wmWallLoad() {
  final u64 pn = fatParseAt(Rodata.addressOf(wmStrWallPath), u64(8));
  if (pn > u64(fatErrOk)) {
    return;
  }
  final u64 st = fatLookup();
  if (st > u64(fatErrOk)) {
    return;
  }
  if (fatFileBytes() < u64(wmWallBytes)) {
    return;
  }
  final u64 lba = fatFileSector(u64(0));
  if (lba < u64(1)) {
    return;
  }
  if (fatReadCached(lba) > u64(0)) {
    return;
  }
  final u64 base = fatSectorBase();
  final u64 magic = fatU32(base);
  if (magic != u64(wmWallMagic)) {
    return;
  }
  final u64 seed = fatU32(base + u64(4));
  final u64 mode = fatU32(base + u64(8)) & u64(0xFF);
  final u64 rgb = fatU32(base + u64(12)) & u64(0x00FFFFFF);
  wmWallSetDesk(seed, mode);
  wmWallSetColor(rgb);
}

/// Persists the mailbox desk/wall into WALL.DAT when the file exists.
@bare
void wmWallSave() {
  final u64 pn = fatParseAt(Rodata.addressOf(wmStrWallPath), u64(8));
  if (pn > u64(fatErrOk)) {
    return;
  }
  final u64 st = fatLookup();
  if (st > u64(fatErrOk)) {
    return;
  }
  if (fatFileBytes() < u64(wmWallBytes)) {
    return;
  }
  final u64 lba = fatFileSector(u64(0));
  if (lba < u64(1)) {
    return;
  }
  if (fatReadCached(lba) > u64(0)) {
    return;
  }
  final u64 base = fatSectorBase();
  final u64 mailbox = kernel_data_start();
  final u64 desk =
      Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value;
  final u64 wall =
      Pointer<u64>.fromAddress(mailbox + u64(wmPopMailWall)).value;
  fatPut32(base, u64(wmWallMagic));
  fatPut32(base + u64(4), desk & u64(0xFFFFFFFF));
  fatPut32(base + u64(8), (desk >> u64(32)) & u64(0xFF));
  fatPut32(base + u64(12), wall & u64(0x00FFFFFF));
  final u64 unused = fatWriteSector(lba, base);
}

/// Bumps the generative seed, clears image mode, saves, prints token.
@bare
void wmWallRegen() {
  u64 seed = wmWallSeed();
  if (seed < u64(1)) {
    seed = u64(0xA11E0001);
  } else {
    seed = seed + u64(0x9E3779B9);
  }
  if ((seed & u64(0xFFFFFFFF)) < u64(1)) {
    seed = u64(0xA11E0002);
  }
  wmWallSetDesk(seed, u64(0));
  wmWallSave();
  uartWrite(Rodata.addressOf(wmStrWallRegen), u64(14));
  uartPutHex(seed & u64(0xFFFFFFFF), u64(8));
  uartNewline();
}

/// Reads WALL.RAW first pixel as solid desk colour. Miss prints MISS.
@bare
void wmWallImage() {
  final u64 pn = fatParseAt(Rodata.addressOf(wmStrWallRawPath), u64(8));
  if (pn > u64(fatErrOk)) {
    uartWrite(Rodata.addressOf(wmStrWallMiss), u64(12));
    uartNewline();
    return;
  }
  final u64 st = fatLookup();
  if (st > u64(fatErrOk)) {
    uartWrite(Rodata.addressOf(wmStrWallMiss), u64(12));
    uartNewline();
    return;
  }
  if (fatFileBytes() < u64(4)) {
    uartWrite(Rodata.addressOf(wmStrWallMiss), u64(12));
    uartNewline();
    return;
  }
  final u64 lba = fatFileSector(u64(0));
  if (lba < u64(1)) {
    uartWrite(Rodata.addressOf(wmStrWallMiss), u64(12));
    uartNewline();
    return;
  }
  if (fatReadCached(lba) > u64(0)) {
    uartWrite(Rodata.addressOf(wmStrWallMiss), u64(12));
    uartNewline();
    return;
  }
  final u64 rgb = fatU32(fatSectorBase()) & u64(0x00FFFFFF);
  wmWallSetColor(rgb);
  wmWallSetDesk(wmWallSeed(), u64(1));
  wmWallSave();
  uartWrite(Rodata.addressOf(wmStrWallImg), u64(12));
  uartPutHex(rgb, u64(6));
  uartNewline();
}

/// Left-click on a showing compositor card. Returns 1 if consumed.
@bare
u64 wmPopWallClick(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmPopHit(x, y) < u64(1)) {
    return u64(0);
  }
  final u64 k = wmPopKind();
  final u64 row = wmPopRowAt(x, y);
  if (wmPopRowDisabled(row) > u64(0)) {
    return u64(1);
  }
  wmPopHide();
  if (k == u64(wmPopWin)) {
    final u64 w = wmPopTarget();
    if (w < u64(wmMaxWindows)) {
      if (row == u64(0)) {
        wmCloseWindow(w);
      }
      if (row == u64(1)) {
        wmPopRaise(w);
      }
    }
  } else {
    if (k == u64(wmPopDock)) {
      final u64 w = wmPopTarget();
      if (w < u64(wmMaxWindows)) {
        if (row == u64(0)) {
          wmPopRaise(w);
        }
        if (row == u64(1)) {
          wmCloseWindow(w);
        }
      }
    } else {
      if (row == u64(0)) {
        wmWallRegen();
      }
      if (row == u64(1)) {
        wmWallImage();
      }
    }
  }
  if (wmActive() > u64(0)) {
    wmCompose();
  }
  return u64(1);
}

/// Pointer-near hover. Returns 1 if the highlight moved.
@bare
u64 wmPopHoverTick(u64 x, u64 y) {
  if (wmPopIsCard(wmPopKind()) < u64(1)) {
    return u64(0);
  }
  final u64 row = wmPopRowAt(x, y);
  if (row == wmPopHoverRow()) {
    return u64(0);
  }
  wmPopSetHover(row);
  wmPopWritePage();
  if (wmPageAddr() > u64(0)) {
    final u64 packed = wmMeta(u64(wmMetaPopXY));
    final u64 g = wmPackGeom(packed >> u64(32), packed & u64(0xFFFFFFFF),
        u64(wmPopW), u64(wmPopH));
    wmDefEnqueue(u64(wmDefKindMenu), u64(wmDefSlotMenu), g, g);
  } else {
    wmPopMenuDraw(wmMeta(u64(wmMetaPopXY)) >> u64(32),
        wmMeta(u64(wmMetaPopXY)) & u64(0xFFFFFFFF));
  }
  return u64(1);
}

/// Activates [row] on the showing card. Returns 1 if handled.
@bare
u64 wmPopActivate(u64 row) {
  final u64 k = wmPopKind();
  if (wmPopIsCard(k) < u64(1)) {
    return u64(0);
  }
  if (wmPopRowDisabled(row) > u64(0)) {
    return u64(1);
  }
  wmPopHide();
  if (k == u64(wmPopWin)) {
    final u64 w = wmPopTarget();
    if (w < u64(wmMaxWindows)) {
      if (row == u64(0)) {
        wmCloseWindow(w);
      }
      if (row == u64(1)) {
        wmPopRaise(w);
      }
    }
  } else {
    if (k == u64(wmPopDock)) {
      final u64 w = wmPopTarget();
      if (w < u64(wmMaxWindows)) {
        if (row == u64(0)) {
          wmPopRaise(w);
        }
        if (row == u64(1)) {
          wmCloseWindow(w);
        }
      }
    } else {
      if (row == u64(0)) {
        wmWallRegen();
      }
      if (row == u64(1)) {
        wmWallImage();
      }
    }
  }
  if (wmActive() > u64(0)) {
    wmCompose();
  }
  return u64(1);
}

/// Keyboard on a showing compositor card. Returns 1 if consumed.
@bare
u64 wmPopKey(u64 ev) {
  if (wmPopIsCard(wmPopKind()) < u64(1)) {
    return u64(0);
  }
  if ((ev & u64(kbdqBitBreak)) > u64(0)) {
    return u64(0);
  }
  final u64 scan = ev & u64(0x7F);
  if (scan == u64(0x01)) {
    wmPopHide();
    return u64(1);
  }
  if (scan == u64(0x1C)) {
    u64 row = wmPopHoverRow();
    if (row > u64(1)) {
      row = u64(0);
    }
    return wmPopActivate(row);
  }
  if ((ev & u64(kbdqBitExt)) > u64(0)) {
    u64 row = wmPopHoverRow();
    if (row > u64(1)) {
      row = u64(0);
    }
    if (scan == u64(0x48)) {
      if (row > u64(0)) {
        row = row - u64(1);
      }
      wmPopSetHover(row);
      wmPopWritePage();
      if (wmPageAddr() > u64(0)) {
        final u64 packed = wmMeta(u64(wmMetaPopXY));
        final u64 g = wmPackGeom(packed >> u64(32), packed & u64(0xFFFFFFFF),
            u64(wmPopW), u64(wmPopH));
        wmDefEnqueue(u64(wmDefKindMenu), u64(wmDefSlotMenu), g, g);
      } else {
        wmPopMenuDraw(wmMeta(u64(wmMetaPopXY)) >> u64(32),
            wmMeta(u64(wmMetaPopXY)) & u64(0xFFFFFFFF));
      }
      return u64(1);
    }
    if (scan == u64(0x50)) {
      if (row < u64(1)) {
        row = u64(1);
      }
      wmPopSetHover(row);
      wmPopWritePage();
      if (wmPageAddr() > u64(0)) {
        final u64 packed = wmMeta(u64(wmMetaPopXY));
        final u64 g = wmPackGeom(packed >> u64(32), packed & u64(0xFFFFFFFF),
            u64(wmPopW), u64(wmPopH));
        wmDefEnqueue(u64(wmDefKindMenu), u64(wmDefSlotMenu), g, g);
      } else {
        wmPopMenuDraw(wmMeta(u64(wmMetaPopXY)) >> u64(32),
            wmMeta(u64(wmMetaPopXY)) & u64(0xFFFFFFFF));
      }
      return u64(1);
    }
  }
  return u64(0);
}
