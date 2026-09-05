// core/kernel/wmprod.dart
//
// Round 33 desktop productivity: typeahead launcher, Alt-Tab MRU
// switcher, and DE shortcuts. No `@bss` — query / MRU / pref live in
// existing wmpage words 501..505.

part of 'kmain.dart';

const int wmLaunchSearchH = 36;
const int wmLaunchRowPitch = 24;
const int wmKbdBitAlt = 8;
const int wmKbdBitGui = 16;
const int wmScanEsc = 0x01;
const int wmScanTab = 0x0F;
const int wmScanEnter = 0x1C;
const int wmScanLCtrl = 0x1D;
const int wmScanLAlt = 0x38;
const int wmScanF4 = 0x3E;
const int wmScanBksp = 0x0E;
const int wmScanUp = 0x48;
const int wmScanDown = 0x50;
const int wmScanLGui = 0x5B;
const int wmScanF9 = 0x43;
const int wmScanF10 = 0x44;
const int wmScanF11 = 0x57;

/// `'WM LAUNCH SHOW '` -- 15 bytes.
@rodata
final List<u8> wmStrLaunchShow = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4C), u8(0x41), u8(0x55), u8(0x4E),
  u8(0x43), u8(0x48), u8(0x20), u8(0x53), u8(0x48), u8(0x4F), u8(0x57),
  u8(0x20),
];

/// `'WM LAUNCH FILT '` -- 15 bytes.
@rodata
final List<u8> wmStrLaunchFilt = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4C), u8(0x41), u8(0x55), u8(0x4E),
  u8(0x43), u8(0x48), u8(0x20), u8(0x46), u8(0x49), u8(0x4C), u8(0x54),
  u8(0x20),
];

/// `'WM LAUNCH GO '` -- 13 bytes.
@rodata
final List<u8> wmStrLaunchGo = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4C), u8(0x41), u8(0x55), u8(0x4E),
  u8(0x43), u8(0x48), u8(0x20), u8(0x47), u8(0x4F), u8(0x20),
];

/// `'WM SWITCH SHOW '` -- 15 bytes.
@rodata
final List<u8> wmStrSwitchShow = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x53), u8(0x57), u8(0x49), u8(0x54),
  u8(0x43), u8(0x48), u8(0x20), u8(0x53), u8(0x48), u8(0x4F), u8(0x57),
  u8(0x20),
];

/// `'WM SWITCH GO '` -- 13 bytes.
@rodata
final List<u8> wmStrSwitchGo = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x53), u8(0x57), u8(0x49), u8(0x54),
  u8(0x43), u8(0x48), u8(0x20), u8(0x47), u8(0x4F), u8(0x20),
];

/// `'WM KEY '` -- 7 bytes.
@rodata
final List<u8> wmStrKey = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4B), u8(0x45), u8(0x59), u8(0x20),
];

/// Launcher height from filtered row count. Search bar + rows + pad.
@bare
u64 wmLaunchBoxH() {
  u64 n = wmLaunchFiltN();
  if (n < u64(1)) {
    n = u64(1);
  }
  if (n > u64(8)) {
    n = u64(8);
  }
  return u64(wmLaunchSearchH) + (n * u64(wmLaunchRowPitch)) +
      u64(wmLaunchHPad);
}

/// Switcher width from ordinary-client count. Cards + pad.
@bare
u64 wmSwitchBoxW() {
  u64 n = wmSwitchCount();
  if (n < u64(1)) {
    n = u64(1);
  }
  if (n > u64(8)) {
    n = u64(8);
  }
  return (n * u64(64)) + u64(wmSwitchWPad);
}

@bare
u64 wmProdFold(u64 ch) {
  if (ch >= u64(0x61)) {
    if (ch <= u64(0x7A)) {
      return ch - u64(0x20);
    }
  }
  return ch;
}

@bare
u64 wmLaunchQLen() {
  if (wmPageAddr() < u64(1)) {
    return u64(0);
  }
  return (wmPage(u64(wmPageWLaunchSel)) >> u64(16)) & u64(0xFF);
}

@bare
u64 wmLaunchSel() {
  if (wmPageAddr() < u64(1)) {
    return u64(0);
  }
  return wmPage(u64(wmPageWLaunchSel)) & u64(0xFF);
}

@bare
u64 wmLaunchFiltN() {
  if (wmPageAddr() < u64(1)) {
    return wmDeLaunchN();
  }
  final u64 n = (wmPage(u64(wmPageWLaunchSel)) >> u64(8)) & u64(0xFF);
  if (n > u64(0)) {
    return n;
  }
  return wmDeLaunchN();
}

@bare
void wmLaunchWriteSel(u64 sel, u64 n, u64 qlen) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 gen =
      ((wmPage(u64(wmPageWLaunchSel)) >> u64(24)) + u64(1)) & u64(0xFF);
  wmPageSet(u64(wmPageWLaunchSel),
      (sel & u64(0xFF)) | ((n & u64(0xFF)) << u64(8)) |
          ((qlen & u64(0xFF)) << u64(16)) | (gen << u64(24)));
}

@bare
void wmLaunchReset() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  if (wmLaunchQLen() < u64(1)) {
    if (wmLaunchSel() < u64(1)) {
      final u64 n = (wmPage(u64(wmPageWLaunchSel)) >> u64(8)) & u64(0xFF);
      if (n == wmDeLaunchN()) {
        return;
      }
    }
  }
  wmPageSet(u64(wmPageWLaunchQ), u64(0));
  wmLaunchWriteSel(u64(0), wmDeLaunchN(), u64(0));
}

@bare
u64 wmLaunchNameMatch(u64 row, u64 q, u64 qlen) {
  if (qlen < u64(1)) {
    return u64(1);
  }
  if (row >= wmDeLaunchN()) {
    return u64(0);
  }
  final u64 idx = wmDeLaunchIdx(row);
  final u64 e = fatDirEntry(idx);
  if (e < u64(1)) {
    return u64(0);
  }
  u64 i = u64(0);
  while (i < qlen) {
    final u64 want = wmProdFold((q >> (i << u64(3))) & u64(0xFF));
    final u64 have = wmProdFold(fatU8(e + i));
    if (want != have) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

@bare
void wmLaunchRefilt() {
  u64 q = u64(0);
  u64 qlen = u64(0);
  if (wmPageAddr() > u64(0)) {
    q = wmPage(u64(wmPageWLaunchQ));
    qlen = wmLaunchQLen();
  }
  u64 n = u64(0);
  u64 row = u64(0);
  while (row < wmDeLaunchN()) {
    if (wmLaunchNameMatch(row, q, qlen) > u64(0)) {
      n = n + u64(1);
    }
    row = row + u64(1);
  }
  u64 sel = wmLaunchSel();
  if (n < u64(1)) {
    sel = u64(0);
  } else {
    if (sel >= n) {
      sel = n - u64(1);
    }
  }
  wmLaunchWriteSel(sel, n, qlen);
}

@bare
u64 wmLaunchFiltAt(u64 vis) {
  u64 q = u64(0);
  u64 qlen = u64(0);
  if (wmPageAddr() > u64(0)) {
    q = wmPage(u64(wmPageWLaunchQ));
    qlen = wmLaunchQLen();
  }
  u64 n = u64(0);
  u64 row = u64(0);
  while (row < wmDeLaunchN()) {
    if (wmLaunchNameMatch(row, q, qlen) > u64(0)) {
      if (n == vis) {
        return row;
      }
      n = n + u64(1);
    }
    row = row + u64(1);
  }
  return u64(0xFF);
}

@bare
u64 wmLaunchRowAt(u64 y) {
  final u64 oy = wmLaunchY() + u64(wmLaunchSearchH);
  if (y < oy) {
    return u64(0);
  }
  u64 d = y - oy;
  u64 row = u64(0);
  while (d >= u64(wmLaunchRowPitch)) {
    d = d - u64(wmLaunchRowPitch);
    row = row + u64(1);
  }
  return row;
}

@bare
void wmLaunchBumpPop() {
  final u64 sel = wmLaunchSel();
  wmSetMeta(u64(wmMetaPop),
      u64(wmPopLaunch) | ((sel & u64(0xFF)) << u64(8)) |
          ((wmLaunchQLen() & u64(0xFF)) << u64(16)));
  wmSetMeta(u64(wmMetaPopXY), (wmLaunchX() << u64(32)) | wmLaunchY());
}

@bare
void wmLaunchType(u64 ch) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  u64 qlen = wmLaunchQLen();
  if (qlen >= u64(8)) {
    return;
  }
  u64 q = wmPage(u64(wmPageWLaunchQ));
  q = q | ((ch & u64(0xFF)) << (qlen << u64(3)));
  wmPageSet(u64(wmPageWLaunchQ), q);
  wmLaunchWriteSel(wmLaunchSel(), wmLaunchFiltN(), qlen + u64(1));
  wmLaunchRefilt();
  wmLaunchBumpPop();
  uartWrite(Rodata.addressOf(wmStrLaunchFilt), u64(15));
  uartPutHex(wmLaunchFiltN(), u64(2));
  uartWrite(Rodata.addressOf(wmStrS), u64(3));
  uartPutHex(ch, u64(2));
  uartNewline();
}

@bare
void wmLaunchBksp() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  u64 qlen = wmLaunchQLen();
  if (qlen < u64(1)) {
    return;
  }
  qlen = qlen - u64(1);
  u64 q = wmPage(u64(wmPageWLaunchQ));
  u64 nq = u64(0);
  u64 i = u64(0);
  while (i < qlen) {
    nq = nq | (((q >> (i << u64(3))) & u64(0xFF)) << (i << u64(3)));
    i = i + u64(1);
  }
  wmPageSet(u64(wmPageWLaunchQ), nq);
  wmLaunchWriteSel(wmLaunchSel(), wmLaunchFiltN(), qlen);
  wmLaunchRefilt();
  wmLaunchBumpPop();
  uartWrite(Rodata.addressOf(wmStrLaunchFilt), u64(15));
  uartPutHex(wmLaunchFiltN(), u64(2));
  uartNewline();
}

@bare
void wmLaunchMove(u64 dir) {
  u64 n = wmLaunchFiltN();
  if (n < u64(1)) {
    return;
  }
  u64 sel = wmLaunchSel();
  if (dir > u64(0)) {
    sel = sel + u64(1);
    if (sel >= n) {
      sel = u64(0);
    }
  } else {
    if (sel < u64(1)) {
      sel = n - u64(1);
    } else {
      sel = sel - u64(1);
    }
  }
  wmLaunchWriteSel(sel, n, wmLaunchQLen());
  wmLaunchBumpPop();
}

@bare
void wmLaunchGo() {
  final u64 vis = wmLaunchSel();
  final u64 row = wmLaunchFiltAt(vis);
  wmDePopHide();
  if (row >= wmDeLaunchN()) {
    return;
  }
  uartWrite(Rodata.addressOf(wmStrLaunchGo), u64(13));
  uartPutHex(row, u64(2));
  uartNewline();
  wmDeSpawnRow(row);
}

@bare
u64 wmIsOrdinary(u64 wI) {
  if (wmWindowHeld(wI) < u64(1)) {
    return u64(0);
  }
  if (wmIsPanel(wI) > u64(0)) {
    return u64(0);
  }
  if (wmWinOverlay(wI) > u64(0)) {
    return u64(0);
  }
  return u64(1);
}

@bare
void wmMruTouch(u64 wI) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  if (wmIsOrdinary(wI) < u64(1)) {
    return;
  }
  u64 packed = wmPage(u64(wmPageWMru));
  u64 out = wI & u64(0xFF);
  u64 shift = u64(8);
  u64 i = u64(0);
  while (i < u64(7)) {
    final u64 b = (packed >> (i << u64(3))) & u64(0xFF);
    if (b != (wI & u64(0xFF))) {
      if (b < u64(wmMaxWindows)) {
        out = out | (b << shift);
        shift = shift + u64(8);
      }
    }
    i = i + u64(1);
  }
  wmPageSet(u64(wmPageWMru), out);
}

@bare
void wmMruDrop(u64 wI) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  u64 packed = wmPage(u64(wmPageWMru));
  u64 out = u64(0);
  u64 shift = u64(0);
  u64 i = u64(0);
  while (i < u64(8)) {
    final u64 b = (packed >> (i << u64(3))) & u64(0xFF);
    if (b != (wI & u64(0xFF))) {
      if (b < u64(wmMaxWindows)) {
        out = out | (b << shift);
        shift = shift + u64(8);
      }
    }
    i = i + u64(1);
  }
  wmPageSet(u64(wmPageWMru), out);
}

@bare
u64 wmSwitchX() {
  final u64 sw = fbGeomWidth();
  if (sw <= wmSwitchBoxW()) {
    return u64(8);
  }
  return (sw - wmSwitchBoxW()) >> u64(1);
}

@bare
u64 wmSwitchY() {
  final u64 sh = fbGeomHeight();
  u64 y = (sh - u64(wmSwitchH)) >> u64(1);
  if (y < u64(8)) {
    y = u64(8);
  }
  return y;
}

@bare
u64 wmSwitchHit(u64 x, u64 y) {
  if (wmMeta(u64(wmMetaPop)) != u64(wmPopSwitch)) {
    return u64(0);
  }
  if (x < wmSwitchX()) {
    return u64(0);
  }
  if (y < wmSwitchY()) {
    return u64(0);
  }
  if (x >= (wmSwitchX() + wmSwitchBoxW())) {
    return u64(0);
  }
  if (y >= (wmSwitchY() + u64(wmSwitchH))) {
    return u64(0);
  }
  return u64(1);
}

@bare
u64 wmSwitchCount() {
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmIsOrdinary(i) > u64(0)) {
      n = n + u64(1);
    }
    i = i + u64(1);
  }
  return n;
}

@bare
u64 wmSwitchAt(u64 vis) {
  if (wmPageAddr() < u64(1)) {
    return u64(wmMaxWindows);
  }
  u64 packed = wmPage(u64(wmPageWMru));
  u64 seen = u64(0);
  u64 i = u64(0);
  while (i < u64(8)) {
    final u64 b = (packed >> (i << u64(3))) & u64(0xFF);
    if (wmIsOrdinary(b) > u64(0)) {
      if (seen == vis) {
        return b;
      }
      seen = seen + u64(1);
    }
    i = i + u64(1);
  }
  u64 w = u64(0);
  while (w < u64(wmMaxWindows)) {
    if (wmIsOrdinary(w) > u64(0)) {
      u64 already = u64(0);
      u64 j = u64(0);
      while (j < u64(8)) {
        if (((packed >> (j << u64(3))) & u64(0xFF)) == w) {
          already = u64(1);
        }
        j = j + u64(1);
      }
      if (already < u64(1)) {
        if (seen == vis) {
          return w;
        }
        seen = seen + u64(1);
      }
    }
    w = w + u64(1);
  }
  return u64(wmMaxWindows);
}

@bare
void wmSwitchWrite(u64 sel, u64 n) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 alt = (wmPage(u64(wmPageWSwitch)) >> u64(16)) & u64(0xFF);
  final u64 gui = (wmPage(u64(wmPageWSwitch)) >> u64(24)) & u64(0xFF);
  wmPageSet(u64(wmPageWSwitch),
      (sel & u64(0xFF)) | ((n & u64(0xFF)) << u64(8)) |
          ((alt & u64(0xFF)) << u64(16)) | (gui << u64(24)));
}

@bare
void wmSwitchShow() {
  final u64 n = wmSwitchCount();
  if (n < u64(1)) {
    return;
  }
  final u64 oldk = wmPopKind();
  if (oldk > u64(0)) {
    if (oldk == u64(wmPopLaunch)) {
      wmSetMeta(u64(wmMetaPop), u64(0));
    } else {
      if (wmPopIsCard(oldk) > u64(0)) {
        wmPopHide();
      } else {
        if (oldk != u64(wmPopSwitch)) {
          wmDePopHide();
        } else {
          wmSetMeta(u64(wmMetaPop), u64(0));
        }
      }
    }
  }
  u64 sel = u64(1);
  if (n < u64(2)) {
    sel = u64(0);
  }
  wmSwitchWrite(sel, n);
  wmSetMeta(u64(wmMetaPop),
      u64(wmPopSwitch) | ((sel & u64(0xFF)) << u64(8)));
  wmSetMeta(u64(wmMetaPopXY), (wmSwitchX() << u64(32)) | wmSwitchY());
  uartWrite(Rodata.addressOf(wmStrSwitchShow), u64(15));
  uartPutHex(n, u64(2));
  uartNewline();
  wmOverlayPresentKind(wmSwitchX(), wmSwitchY(), wmSwitchBoxW(),
      u64(wmSwitchH), u64(wmOpKindSwitch));
}

@bare
void wmSwitchCycle() {
  if (wmPopKind() != u64(wmPopSwitch)) {
    wmSwitchShow();
    return;
  }
  u64 n = wmSwitchCount();
  if (n < u64(1)) {
    return;
  }
  u64 sel = u64(0);
  if (wmPageAddr() > u64(0)) {
    sel = wmPage(u64(wmPageWSwitch)) & u64(0xFF);
  }
  sel = sel + u64(1);
  if (sel >= n) {
    sel = u64(0);
  }
  wmSwitchWrite(sel, n);
  wmSetMeta(u64(wmMetaPop),
      u64(wmPopSwitch) | ((sel & u64(0xFF)) << u64(8)));
  wmSetMeta(u64(wmMetaPopXY), (wmSwitchX() << u64(32)) | wmSwitchY());
  uartWrite(Rodata.addressOf(wmStrSwitchShow), u64(15));
  uartPutHex(n, u64(2));
  uartNewline();
  wmOverlayPresentKind(wmSwitchX(), wmSwitchY(), wmSwitchBoxW(),
      u64(wmSwitchH), u64(wmOpKindSwitch));
}

@bare
void wmSwitchCommit() {
  u64 sel = u64(0);
  if (wmPageAddr() > u64(0)) {
    sel = wmPage(u64(wmPageWSwitch)) & u64(0xFF);
  }
  final u64 w = wmSwitchAt(sel);
  wmDePopHide();
  if (w >= u64(wmMaxWindows)) {
    return;
  }
  uartWrite(Rodata.addressOf(wmStrSwitchGo), u64(13));
  uartPutHex(w, u64(1));
  uartNewline();
  if (wmWin(w, u64(wmWinState)) == u64(wmWinMin)) {
    wmRestWindow(w);
  }
  wmSetMeta(u64(wmMetaTop), w);
  wmFocusTo(w);
  wmMruTouch(w);
  if (wmPageAddr() > u64(0)) {
    wmDefEnqueue(u64(wmDefKindFocus), w, wmWin(w, u64(wmWinGeom)),
        wmWin(w, u64(wmWinGeom)));
  }
}

@bare
void wmPrefNote(u64 theme, u64 accent, u64 wall) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 gen =
      ((wmPage(u64(wmPageWPref)) >> u64(24)) + u64(1)) & u64(0xFF);
  wmPageSet(u64(wmPageWPref),
      (theme & u64(0xFF)) | ((accent & u64(0xFF)) << u64(8)) |
          ((wall & u64(0xFF)) << u64(16)) | (gen << u64(24)));
}

/// DE shortcuts and overlay keys. Returns 1 if the event is consumed.
@bare
u64 wmDeKey(u64 ev) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  final u64 scan = ev & u64(0x7F);
  final u64 brk = ev & u64(kbdqBitBreak);
  if (scan == u64(wmScanLAlt)) {
    if (wmPageAddr() > u64(0)) {
      u64 packed = wmPage(u64(wmPageWSwitch));
      if (brk > u64(0)) {
        packed = packed & u64(0xFFFFFFFFFF00FFFF);
        wmPageSet(u64(wmPageWSwitch), packed);
        if (wmPopKind() == u64(wmPopSwitch)) {
          wmSwitchCommit();
          return u64(1);
        }
      } else {
        packed = packed | (u64(1) << u64(16));
        wmPageSet(u64(wmPageWSwitch), packed);
      }
    }
    return u64(0);
  }
  if (scan == u64(wmScanLGui)) {
    if (brk < u64(1)) {
      if (wmPopKind() == u64(wmPopLaunch)) {
        wmDePopHide();
      } else {
        wmDeStartShow();
      }
      uartWrite(Rodata.addressOf(wmStrKey), u64(7));
      uartPutHex(scan, u64(2));
      uartNewline();
      return u64(1);
    }
    return u64(0);
  }
  if (brk > u64(0)) {
    return u64(0);
  }
  u64 alt = u64(0);
  if (wmPageAddr() > u64(0)) {
    alt = (wmPage(u64(wmPageWSwitch)) >> u64(16)) & u64(0xFF);
  }
  if (scan == u64(wmScanTab)) {
    if (alt > u64(0)) {
      wmSwitchCycle();
      uartWrite(Rodata.addressOf(wmStrKey), u64(7));
      uartPutHex(scan, u64(2));
      uartNewline();
      return u64(1);
    }
    if (wmPopKind() == u64(wmPopLaunch)) {
      wmLaunchMove(u64(1));
      return u64(1);
    }
    return u64(0);
  }
  if (scan == u64(wmScanF4)) {
    if (alt > u64(0)) {
      final u64 f = wmFocusLive();
      if (f > u64(0)) {
        wmCloseWindow(f - u64(1));
      }
      uartWrite(Rodata.addressOf(wmStrKey), u64(7));
      uartPutHex(scan, u64(2));
      uartNewline();
      return u64(1);
    }
    if (wmPopKind() == u64(wmPopLaunch)) {
      wmDePopHide();
    } else {
      wmDeStartShow();
    }
    uartWrite(Rodata.addressOf(wmStrKey), u64(7));
    uartPutHex(scan, u64(2));
    uartNewline();
    return u64(1);
  }
  if (scan == u64(wmScanF9)) {
    if (alt > u64(0)) {
      final u64 f = wmFocusLive();
      if (f > u64(0)) {
        wmMinWindow(f - u64(1));
      }
      uartWrite(Rodata.addressOf(wmStrKey), u64(7));
      uartPutHex(scan, u64(2));
      uartNewline();
      return u64(1);
    }
  }
  if (scan == u64(wmScanF10)) {
    if (alt > u64(0)) {
      final u64 f = wmFocusLive();
      if (f > u64(0)) {
        wmToggleMaxWindow(f - u64(1));
      }
      uartWrite(Rodata.addressOf(wmStrKey), u64(7));
      uartPutHex(scan, u64(2));
      uartNewline();
      return u64(1);
    }
  }
  if (wmPopKind() == u64(wmPopLaunch)) {
    if (scan == u64(wmScanEsc)) {
      wmDePopHide();
      return u64(1);
    }
    if (scan == u64(wmScanEnter)) {
      wmLaunchGo();
      return u64(1);
    }
    if (scan == u64(wmScanBksp)) {
      wmLaunchBksp();
      return u64(1);
    }
    if ((ev & u64(kbdqBitExt)) > u64(0)) {
      if (scan == u64(wmScanUp)) {
        wmLaunchMove(u64(0));
        return u64(1);
      }
      if (scan == u64(wmScanDown)) {
        wmLaunchMove(u64(1));
        return u64(1);
      }
    }
    final u8 c = Pointer<u8>.fromAddress(
      Rodata.addressOf(kbdSet1Ascii) + scan,
    ).value;
    if (c >= u8(0x20)) {
      if (c < u8(0x7F)) {
        wmLaunchType(c.toU64());
        return u64(1);
      }
    }
    return u64(1);
  }
  if (wmPopKind() == u64(wmPopSwitch)) {
    if (scan == u64(wmScanEsc)) {
      wmDePopHide();
      return u64(1);
    }
    if (scan == u64(wmScanEnter)) {
      wmSwitchCommit();
      return u64(1);
    }
    return u64(1);
  }
  return u64(0);
}
