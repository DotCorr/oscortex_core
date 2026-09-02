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

/// Width of the popover, in pixels.
const int wmPopW = 96;

/// Height of the popover, in pixels.
const int wmPopH = 64;

/// Offset from the pointer to the popover origin. Positive is right and down.
const int wmPopGap = 8;

/// The fill. Not the desktop and not the chrome strip, so "the popover
/// was drawn" is a different pixel from either.
const int wmPopColor = 0x00C04088;

/// Wallpaper-menu row fill (DE on). Distinct from [wmPopColor] and desk.
const int wmPopRow0 = 0x00304878;

/// Second row fill.
const int wmPopRow1 = 0x00283868;

/// Label ink on a menu row.
const int wmPopLabelFg = 0x00F0F8FF;

/// Top pad inside the popover before row 0.
const int wmPopRowPad = 4;

/// Row height for Regen / Image.
const int wmPopRowH = 24;

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

/// `'WM RAISE W '` -- 11 bytes.
@rodata
final List<u8> wmStrRaise = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x41), u8(0x49), u8(0x53),
  u8(0x45), u8(0x20), u8(0x57), u8(0x20),
];

// ---------------------------------------------------------------------------
// Draw, hit, show, hide. [wmCompose], [wmPixelAt], [wmPointerTick] and
// [wmGrab] are the callers. GAP-0302: this is the start of a right-click
// policy, not close or resize.
// ---------------------------------------------------------------------------

/// 1 if the popover is showing.
@bare
u64 wmPopOn() {
  return wmMeta(u64(wmMetaPop));
}

/// 1 if [k] is a compositor-owned two-row card (wall / window / dock).
@bare
u64 wmPopIsCard(u64 k) {
  if (k == u64(wmPopWall)) {
    return u64(1);
  }
  if (k == u64(wmPopWin)) {
    return u64(1);
  }
  if (k == u64(wmPopDock)) {
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
  final u64 unused = wmRepaintWindow(wI);
}

/// 1 if the popover is showing and ([x], [y]) is inside it.
@bare
u64 wmPopHit(u64 x, u64 y) {
  u64 hit = u64(0);
  if (wmPopIsCard(wmMeta(u64(wmMetaPop))) > u64(0)) {
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
  if (row > u64(1)) {
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
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
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
  final u64 k = wmMeta(u64(wmMetaPop));
  wmFillRect(ox + u64(4), oy + u64(wmPopRowPad), u64(wmPopW) - u64(8),
      u64(wmPopRowH) - u64(2), u64(wmPopRow0));
  wmFillRect(ox + u64(4), oy + u64(wmPopRowPad) + u64(wmPopRowH),
      u64(wmPopW) - u64(8), u64(wmPopRowH) - u64(2), u64(wmPopRow1));
  if (k == u64(wmPopWin)) {
    wmPopLabel(ox, oy, u64(0), Rodata.addressOf(wmStrPopClose));
    wmPopLabel(ox, oy, u64(1), Rodata.addressOf(wmStrPopRaise));
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
  if (wmPopIsCard(wmMeta(u64(wmMetaPop))) > u64(0)) {
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
    if (wmPanelStrip() < u64(1)) {
      wmChromeBufInvalidate();
      wmGfxKick();
      osgfx_guest_tick();
      if (wmActive() > u64(0)) {
        wmCompose();
      }
      return;
    }
  }
  final u64 unused = wmRepaintRect(x, y, w, h);
}

@bare
void wmPopHide() {
  if (wmPopIsCard(wmMeta(u64(wmMetaPop))) > u64(0)) {
    final u64 packed = wmMeta(u64(wmMetaPopXY));
    final u64 ox = packed >> u64(32);
    final u64 oy = packed & u64(0xFFFFFFFF);
    wmSetMeta(u64(wmMetaPop), u64(0));
    wmPopDamageRestore(ox, oy, u64(wmPopW), u64(wmPopH));
  }
}

/// Places a 96x64 rectangle near ([x], [y]) and paints it. A popover that
/// was already showing is hidden first so a second right-click moves it
/// rather than leaving a stale fill. Under `wm de` the fill is a menu.
/// GAP-0352: under `wm gfx` with no DESK panel, kick+tick+CPU fill the
/// card before `WM WALL MENU` so the fb dump sees row colours.
@bare
void wmPopShowKind(u64 x, u64 y, u64 kind) {
  if (wmPopIsCard(wmMeta(u64(wmMetaPop))) > u64(0)) {
    wmPopHide();
  }
  if (wmMeta(u64(wmMetaPop)) > u64(1)) {
    wmDePopHide();
  }
  u64 ox = x + u64(wmPopGap);
  u64 oy = y + u64(wmPopGap);
  if (ox + u64(wmPopW) > fbGeomWidth()) {
    ox = fbGeomWidth() - u64(wmPopW);
  }
  if (oy + u64(wmPopH) > fbGeomHeight()) {
    oy = fbGeomHeight() - u64(wmPopH);
  }
  wmSetMeta(u64(wmMetaPop), kind);
  wmSetMeta(u64(wmMetaPopXY), (ox << u64(32)) | oy);
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (wmPanelStrip() < u64(1)) {
      wmGfxKick();
      osgfx_guest_tick();
      if (wmActive() > u64(0)) {
        wmCompose();
      }
    }
  }
  wmFillRect(ox, oy, u64(wmPopW), u64(wmPopH), u64(wmPopColor));
  if (wmDeOn() > u64(0)) {
    wmPopMenuDraw(ox, oy);
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
  }
}

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
  wmFocusTo(hit);
  if (oldTop != hit) {
    wmSetMeta(u64(wmMetaTop), hit);
    wmBumpMeta(u64(wmMetaRaises));
  }
  u64 chromeChanged = u64(0);
  if (oldFocus != hit + u64(1)) {
    chromeChanged = u64(1);
  }
  if (oldTop != hit) {
    chromeChanged = u64(1);
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (chromeChanged > u64(0)) {
      wmGfxKick();
      osgfx_guest_tick();
      if (wmActive() > u64(0)) {
        wmCompose();
      }
    }
    return;
  }
  if (oldTop != hit) {
    u64 px = wmRepaintWindow(oldTop);
    px = px + wmRepaintWindow(hit);
    wmSetMeta(
        u64(wmMetaRectPixels), wmMeta(u64(wmMetaRectPixels)) + px);
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
  final u64 k = wmMeta(u64(wmMetaPop));
  final u64 row = wmPopRowAt(x, y);
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
