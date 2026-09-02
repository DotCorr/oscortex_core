// core/kernel/wmchrome.dart
//
// Compositor-owned chrome: a bottom taskbar strip (ADR-0056) and a
// title strip on each decorated window (ADR-0075). Both share the
// existing [wmMetaChrome] flag. No new word. No `@bss`.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` compiles exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// THIS FILE HAS NO @bss. The on-flag lives in a spare word of the existing
// wmStore block (index [wmMetaChrome] = 19), so every harness that measures
// wmStore at 320 bytes, and the kernel's mutable-static total, is unmoved.
// D9 later took word 20 for keyboard focus; this file still donates none.
// The part is NOT last: D2's kbdq.dart (and D7's wmevent.dart, if present)
// stay at the end of the list.
//
// OFF BY DEFAULT. `wmInit` zeroes the whole block, so the first compose
// after `wm on` is still a full 800x600 desktop. `d2-compositor` derives
// pixel colours from that desktop; a 24-pixel bar or an 18-pixel title
// would move every probe that landed on those rows. `wm chrome` is what
// turns both decorations on.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Geometry and colour. Named so the host model in d8-chrome reads them
// rather than inventing a second answer.
// ---------------------------------------------------------------------------

/// Height of the taskbar, in pixels. Full width, bottom-aligned.
/// Tall enough that Start / slots / note read as a designed bar.
const int wmChromeH = 48;

/// Elevated slate strip. Not the desktop, so "chrome was drawn" and
/// "the desktop fill reached the bottom" are different pixels.
const int wmChromeColor = 0x00344050;

/// Height of the title strip on each decorated window, in pixels.
/// Tall enough for close/min (18) plus a readable caption glyph row.
const int wmTitleH = 32;

/// Pearl title. Not the desktop, not the taskbar, not either d2 fill,
/// so "chrome painted a caption" and "the client still owns this
/// row" are different pixels.
const int wmTitleColor = 0x00E8E0D0;

/// Spare word of the existing 24-word meta block. Words 0..18 are D4/D5b;
/// 20 is D9 keyboard focus; 21-22 are the right-click popover (ADR-0070);
/// 23 remains free. Not a new `@bss`.
const int wmMetaChrome = 19;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
// ---------------------------------------------------------------------------

///
/// `'wm chrome'` -- 9 bytes.
@rodata
final List<u8> wmStrCmdChrome = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x63), u8(0x68), u8(0x72), u8(0x6F), u8(0x6D),
  u8(0x65),
];

///
/// `'WM CHROME ON'` -- 12 bytes.
@rodata
final List<u8> wmStrChromeOn = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x48), u8(0x52), u8(0x4F), u8(0x4D),
  u8(0x45), u8(0x20), u8(0x4F), u8(0x4E),
];

// ---------------------------------------------------------------------------
// Draw and hit. [wmCompose] and [wmGrab] call the taskbar; [wmDrawWindow]
// and [wmWindowPixel] call the title. A damage pass sees the title
// through [wmPixelAt]. The taskbar still has that gap. GAP-0302.
// ---------------------------------------------------------------------------

/// Paints the strip if the flag is set. Returns the pixels written, or 0
/// when chrome is off -- so a default-off compose's count does not move.
@bare
u64 wmChromeDraw() {
  u64 px = u64(0);
  if (wmMeta(u64(wmMetaChrome)) > u64(0)) {
    if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
      wmFillRect(u64(0), fbGeomHeight() - u64(wmChromeH),
          fbGeomWidth(), u64(wmChromeH), u64(wmChromeColor));
      px = fbGeomWidth() * u64(wmChromeH);
    }
    px = px + wmDeChromeDraw();
  }
  return px;
}

/// Paints the title strip on window [wI] if chrome is on. The strip
/// is the top [wmTitleH] rows of the client's content. A press there
/// is still a [wmHit]. Under `wm de` (ADR-0111) it is the only press
/// that starts a drag; a body press goes to the client. Returns
/// pixels written, or 0 when chrome is off -- a default-off
/// [wmDrawWindow] count does not move.
@bare
u64 wmTitleDraw(u64 wI) {
  u64 px = u64(0);
  if (wmMeta(u64(wmMetaChrome)) > u64(0)) {
    if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
      if (wmWindowUsable(wI) > u64(0)) {
        final u64 g = wmWin(wI, u64(wmWinGeom));
        final u64 x = wmAbsX(wI);
        final u64 y = wmAbsY(wI);
        final u64 w = wmGeomW(g);
        u64 h = u64(wmTitleH);
        if (h > wmGeomH(g)) {
          h = wmGeomH(g);
        }
        wmFillRect(x, y, w, h, u64(wmTitleColor));
        px = w * h;
      }
    }
    wmTitleButtonsDraw(wI);
  }
  return px;
}

/// [wmTitleColor] if chrome is on and ([x], [y]) is on window [wI]'s
/// title strip, else [wmNoPixel]. [wmWindowPixel] asks so a damage
/// pass and a cursor erase put the caption back.
@bare
u64 wmTitlePixel(u64 wI, u64 x, u64 y) {
  u64 c = u64(wmNoPixel);
  if (wmMeta(u64(wmMetaChrome)) > u64(0)) {
    if (wmWindowUsable(wI) > u64(0)) {
      final u64 g = wmWin(wI, u64(wmWinGeom));
      final u64 wx = wmAbsX(wI);
      final u64 wy = wmAbsY(wI);
      final u64 ww = wmGeomW(g);
      final u64 wh = wmGeomH(g);
      u64 th = u64(wmTitleH);
      if (th > wh) {
        th = wh;
      }
      if (x >= wx) {
        if (x < (wx + ww)) {
          if (y >= wy) {
            if (y < (wy + th)) {
              if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
                /* Session owns the whole title band (pearl, glyphs, soft
                 * close/min). Stamping wmTitleColor here wiped FILES/SET
                 * and paper-doodled over Graphite AA on cursor/damage. */
                c = u64(wmNoPixel);
              } else {
                c = wmDeTitlePixel(wI, x, y);
                if (c == u64(wmNoPixel)) {
                  c = u64(wmTitleColor);
                }
              }
            }
          }
        }
      }
    }
  }
  return c;
}

/// 1 if chrome is on and ([x], [y]) is on window [wI]'s title strip.
/// Close / min sit inside this rectangle; [wmDeGrab] consumes those
/// first. ADR-0111: under `wm de` this hit is what starts a drag.
@bare
u64 wmTitleHit(u64 wI, u64 x, u64 y) {
  if (wmMeta(u64(wmMetaChrome)) < u64(1)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 wx = wmAbsX(wI);
  final u64 wy = wmAbsY(wI);
  final u64 ww = wmGeomW(g);
  final u64 wh = wmGeomH(g);
  u64 th = u64(wmTitleH);
  if (th > wh) {
    th = wh;
  }
  if (x < wx) {
    return u64(0);
  }
  if (y < wy) {
    return u64(0);
  }
  if (x >= (wx + ww)) {
    return u64(0);
  }
  if (y >= (wy + th)) {
    return u64(0);
  }
  return u64(1);
}

/// 1 if chrome is on and ([x], [y]) is inside the strip. A press that
/// hits here is compositor policy: consumed, no drag.
@bare
u64 wmChromeHit(u64 x, u64 y) {
  u64 hit = u64(0);
  if (wmMeta(u64(wmMetaChrome)) > u64(0)) {
    if (x < fbGeomWidth()) {
      if (y >= (fbGeomHeight() - u64(wmChromeH))) {
        hit = u64(1);
      }
    }
  }
  return hit;
}

/// `wm chrome` -- set the flag, print `WM CHROME ON H <h> PX <strip>`, and
/// recompose if the compositor already owns the framebuffer.
@bare
void wmChromeCmd() {
  wmSetMeta(u64(wmMetaChrome), u64(1));
  uartWrite(Rodata.addressOf(wmStrChromeOn), u64(12));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(u64(wmChromeH), u64(4));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(fbGeomWidth() * u64(wmChromeH), u64(8));
  uartNewline();
  if (wmActive() > u64(0)) {
    wmCompose();
    gopSessAnnounce();
  }
}
