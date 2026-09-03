// core/kernel/wmgfx.dart
//
// Sit-in / `wm gfx` path (ADR-0104). Sets spare word 23 so compose
// skips the square blit and osgfx_guest_tick calls osgfx_fill_rrect.
// `wm chrome` stays the exact-rect blit (d2 / d8). No @extern.
//
// No @bss. Flag is spare wmStore word 23. The mailbox is the first
// words of .data (kernel_data_start), not a donated block.

part of 'kmain.dart';

@extern
external void osgfx_guest_tick();

@extern
external u64 osgfx_vk_spirv_ready();

@extern
external u64 osgfx_vk_venus_encode();

const int wmGfxRadius = 18;

const int wmMetaGfx = 23;

const int osgfxGuestMagic = 0x4F534746585F7631;

const int osgfxGuestOn = 1;

const int osgfxGuestDe = 2;

const int osgfxGuestTopShift = 8;

const int osgfxGuestHeld0 = 0x10000;

const int osgfxGuestHeld1 = 0x20000;

/// Bit 2: solid image wallpaper (mailbox wall RGB).
const int osgfxGuestWallImg = 4;

/// Bits 4..5: popover kind (1 = context / wallpaper menu).
const int osgfxGuestPopShift = 4;

/// Bit 3: a client panel owns the taskbar strip (ADR-0192).
const int osgfxGuestPanel = 8;

/// `'wm gfx'` -- 6 bytes.
@bare
u64 wmIsPanel(u64 wI) {
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  if (wmWin(wI, u64(wmWinSeq)) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 w = wmGeomW(g);
  final u64 h = wmGeomH(g);
  final u64 x = wmGeomX(g);
  final u64 y = wmGeomY(g);
  if (w != fbGeomWidth()) {
    return u64(0);
  }
  if (h > u64(wmChromeH)) {
    return u64(0);
  }
  if ((y + h) != fbGeomHeight()) {
    return u64(0);
  }
  if (x > u64(0)) {
    return u64(0);
  }
  return u64(1);
}

/// 1 while a committed client panel owns the strip.
@bare
u64 wmPanelStrip() {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmIsPanel(i) > u64(0)) {
      return u64(1);
    }
    i = i + u64(1);
  }
  return u64(0);
}

/// The live panel window slot, or [wmMaxWindows].
@bare
u64 wmPanelWindow() {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmIsPanel(i) > u64(0)) {
      return i;
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// `'wm gfx'` -- 6 bytes.
@rodata
final List<u8> wmStrCmdGfx = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x67), u8(0x66), u8(0x78),
];

/// `'WM GFX ON'` -- 9 bytes.
@rodata
final List<u8> wmStrGfxOn = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x47), u8(0x46), u8(0x58), u8(0x20),
  u8(0x4F), u8(0x4E),
];

@bare
u64 wmGfxOn() {
  return wmMeta(u64(wmMetaGfx));
}

/// 1 if ([px], [py]) is inside the rounded rect. Same test as osgfx_sw.c.
@bare
u64 wmRrectHit(u64 px, u64 py, u64 x, u64 y, u64 w, u64 h, u64 r) {
  u64 hit = u64(0);
  u64 rr = r;
  u64 cx = u64(0);
  u64 cy = u64(0);
  u64 dx = u64(0);
  u64 dy = u64(0);
  u64 corner = u64(0);
  if (w > u64(0)) {
    if (h > u64(0)) {
      if (px >= x) {
        if (py >= y) {
          if (px < (x + w)) {
            if (py < (y + h)) {
              if (rr < u64(1)) {
                hit = u64(1);
              } else {
                if ((rr + rr) > w) {
                  rr = w >> u64(1);
                }
                if ((rr + rr) > h) {
                  rr = h >> u64(1);
                }
                if (px < (x + rr)) {
                  if (py < (y + rr)) {
                    cx = x + rr;
                    cy = y + rr;
                    corner = u64(1);
                  }
                }
                if (px >= ((x + w) - rr)) {
                  if (py < (y + rr)) {
                    cx = (x + w) - u64(1) - rr;
                    cy = y + rr;
                    corner = u64(1);
                  }
                }
                if (px < (x + rr)) {
                  if (py >= ((y + h) - rr)) {
                    cx = x + rr;
                    cy = (y + h) - u64(1) - rr;
                    corner = u64(1);
                  }
                }
                if (px >= ((x + w) - rr)) {
                  if (py >= ((y + h) - rr)) {
                    cx = (x + w) - u64(1) - rr;
                    cy = (y + h) - u64(1) - rr;
                    corner = u64(1);
                  }
                }
                if (corner < u64(1)) {
                  hit = u64(1);
                } else {
                  if (px < cx) {
                    dx = cx - px;
                  } else {
                    dx = px - cx;
                  }
                  if (py < cy) {
                    dy = cy - py;
                  } else {
                    dy = py - cy;
                  }
                  if (((dx * dx) + (dy * dy)) <= (rr * rr)) {
                    hit = u64(1);
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  return hit;
}

@bare
void wmGfxKick() {
  u64 mailbox = u64(0);
  u64 win0 = u64(0);
  u64 win1 = u64(0);
  u64 win0Slot = u64(wmMaxWindows);
  u64 win1Slot = u64(wmMaxWindows);
  u64 pop = u64(0);
  u64 packed = u64(0);
  u64 gen = u64(0);
  u64 flags = u64(0);
  u64 desk = u64(0);
  u64 wall = u64(0);
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    mailbox = kernel_data_start();
    final u64 _pageOk = wmPageEnsure();
    if (_pageOk > u64(0)) {
      wmSessionOwe();
    }
    desk = Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value;
    wall = Pointer<u64>.fromAddress(mailbox + u64(wmPopMailWall)).value;
    /* Two ordinary FRAME clients (FILES then SET), never the panel.
     * The dock is a separate full-width hole in chrome_blit when
     * OSGFX_GUEST_PANEL is set. Putting DESK in win0 used to leave SET
     * without a title or body hole, so its rect showed stale FILES pixels. */
    u64 i = u64(0);
    while (i < u64(wmMaxWindows)) {
      if (wmWindowUsable(i) > u64(0)) {
        if (wmIsPanel(i) < u64(1)) {
          if (wmIsOverlay(i) < u64(1)) {
            if (win0Slot >= u64(wmMaxWindows)) {
              win0Slot = i;
              win0 = wmWin(i, u64(wmWinGeom));
            } else if (win1Slot >= u64(wmMaxWindows)) {
              win1Slot = i;
              win1 = wmWin(i, u64(wmWinGeom));
            }
          }
        }
      }
      i = i + u64(1);
    }
    if (wmMeta(u64(wmMetaPop)) > u64(0)) {
      packed = wmMeta(u64(wmMetaPopXY));
      pop = packed;
    }
    flags = u64(osgfxGuestOn);
    if (wmDeOn() > u64(0)) {
      flags = flags | u64(osgfxGuestDe);
    }
    if ((desk >> u64(32)) > u64(0)) {
      flags = flags | u64(osgfxGuestWallImg);
    }
    u64 chromeTop = u64(0);
    if (wmMeta(u64(wmMetaTop)) == win1Slot) {
      chromeTop = u64(1);
    }
    flags = flags | (chromeTop << u64(osgfxGuestTopShift));
    flags = flags |
        ((wmMeta(u64(wmMetaPop)) & u64(3)) << u64(osgfxGuestPopShift));
    if (win0Slot < u64(wmMaxWindows)) {
      flags = flags | u64(osgfxGuestHeld0);
    }
    if (win1Slot < u64(wmMaxWindows)) {
      flags = flags | u64(osgfxGuestHeld1);
    }
    if (wmPanelStrip() > u64(0)) {
      flags = flags | u64(osgfxGuestPanel);
    }
    if (wmPageAddr() > u64(0)) {
      u64 mail = u64(0);
      if (win0Slot < u64(wmMaxWindows)) {
        mail = wmPage(u64(wmPageWLaunch0) + win0Slot) & u64(0xFF);
      }
      if (win1Slot < u64(wmMaxWindows)) {
        mail = mail |
            ((wmPage(u64(wmPageWLaunch0) + win1Slot) & u64(0xFF)) << u64(8));
      }
      wmPageSet(u64(wmPageWCapMail), mail);
    }
    Pointer<u64>.fromAddress(mailbox + u64(wmPageMailOff)).value =
        wmPageAddr();
    Pointer<u64>.fromAddress(mailbox).value = u64(osgfxGuestMagic);
    Pointer<u64>.fromAddress(mailbox + u64(8)).value = flags;
    Pointer<u64>.fromAddress(mailbox + u64(16)).value =
        fbState(u64(fbStateBase));
    Pointer<u64>.fromAddress(mailbox + u64(24)).value =
        fbState(u64(fbStatePitch));
    Pointer<u64>.fromAddress(mailbox + u64(32)).value = fbGeomWidth();
    Pointer<u64>.fromAddress(mailbox + u64(40)).value = fbGeomHeight();
    Pointer<u64>.fromAddress(mailbox + u64(48)).value = win0;
    Pointer<u64>.fromAddress(mailbox + u64(56)).value = win1;
    Pointer<u64>.fromAddress(mailbox + u64(64)).value = pop;
    gen = Pointer<u64>.fromAddress(mailbox + u64(72)).value + u64(1);
    Pointer<u64>.fromAddress(mailbox + u64(72)).value = gen;
    Pointer<u64>.fromAddress(mailbox + u64(wmPopMailDesk)).value = desk;
    Pointer<u64>.fromAddress(mailbox + u64(wmPopMailWall)).value = wall;
  }
}

/// `wm gfx` -- chrome plus the osgfx C ABI. Prints `WM GFX ON`. No help line.
/// ADR-0172: call osgfx_guest_tick from shell context (not IRQ0 spin), then
/// Venus-encode retained SPIR-V.
@bare
void wmGfxCmd() {
  wmSetMeta(u64(wmMetaChrome), u64(1));
  wmSetMeta(u64(wmMetaGfx), u64(1));
  uartWrite(Rodata.addressOf(wmStrGfxOn), u64(9));
  uartNewline();
  /* Arm the mailbox even if no client is up so the Graphite
   * MakeVulkan door runs on the next osgfx tick. */
  wmGfxKick();
  if (wmActive() > u64(0)) {
    wmCompose();
  }
  /* Plant host SPIR-V via tick in shell context, then Venus-encode. */
  osgfx_guest_tick();
  if (osgfx_vk_spirv_ready() > u64(0)) {
    final u64 enc = osgfx_vk_venus_encode();
    if (enc == u64(0)) {
      /* fail token printed by wire */
    }
  }
}
