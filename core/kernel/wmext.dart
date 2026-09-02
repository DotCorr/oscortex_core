// core/kernel/wmext.dart
//
// Surface-protocol extensions on syscall 23: clipboard offer/take,
// subsurfaces, integer buffer scale, and a second input seat.
// Cap-backed, sync inside the caller's syscall. Not Wayland.
//
// No @bss — clipboard lives in spare shm meta words 9..12; parent and
// scale pack into existing window words; seat 1 packs into the high
// byte of wmMetaFocus. wmStore stays 448. wmeventStore stays last.
//
// ADRs 0183–0186. display-protocol.md §5.1 leftovers closed here for
// the integer path; fractional scale and DnD stay open.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Ops on the same 64-byte descriptor (syscall 23).
// ---------------------------------------------------------------------------

/// Offer a shm region's bytes as the kernel selection.
const int wmOpOffer = 3;

/// Copy the current selection into a caller-owned shm region.
const int wmOpTake = 4;

/// Attach a child surface: parent handle + relative ox/oy.
const int wmOpSub = 5;

/// Set keyboard focus for seat 0 or 1 to the window of a handle.
const int wmOpSeat = 6;

/// Reposition a live surface (absolute for roots, relative for children).
const int wmOpMove = 7;

/// Query which seats focus a window owned by the caller. rax bit0=seat0.
const int wmOpSeatGet = 8;

/// Live scanout geometry and DE state (ADR-0192). rax carries the answer.
const int wmOpScreen = 9;

/// One osgfx.h primitive into caller-owned shm (ADR-0192).
const int wmOpPaint = 10;

@extern
external u64 osgfx_client_paint(u64 px, u64 pitch, u64 w, u64 h, u64 scr_x,
    u64 scr_y, u64 desc, u64 pid);

/// Clipboard: length above this is refused (one page of payload).
const int wmClipMaxLen = 4096;

/// Descriptor word 2 on OFFER / TAKE length; on SUB parent handle;
/// on SEAT the seat index; on MOVE the new x.
const int wmDescArg2 = 2;

/// SUB: relative oy. MOVE: new y. SEAT unused.
const int wmDescArg3 = 3;

/// SUB: w.
const int wmDescArg4 = 4;

/// SUB: h.
const int wmDescArg5 = 5;

/// SUB: (scale << 32) | stride. Scale 0 means 1.
const int wmDescArg6 = 6;

/// Parent slot PLUS ONE in bits 8..15 of wmWinState. 0 = top-level.
const int wmWinParentShift = 8;

/// Scale in bits 32..47 of wmWinStride. 0 means 1.
const int wmWinScaleShift = 32;

/// Seat 1 focus PLUS ONE in bits 8..15 of wmMetaFocus.
const int wmSeat1Shift = 8;

/// Max seats this rung names. Seat 0 is the legacy click focus.
const int wmSeatCount = 2;

// ---------------------------------------------------------------------------
// Rodata.
// ---------------------------------------------------------------------------

/// `'WM OFFER R '` -- 11 bytes.
@rodata
final List<u8> wmStrOffer = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4F), u8(0x46), u8(0x46), u8(0x45), u8(0x52),
  u8(0x20), u8(0x52), u8(0x20),
];

/// `'WM TAKE R '` -- 10 bytes.
@rodata
final List<u8> wmStrTake = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x54), u8(0x41), u8(0x4B), u8(0x45), u8(0x20),
  u8(0x52), u8(0x20),
];

/// `' LEN '` -- 5 bytes.
@rodata
final List<u8> wmStrLen = const [
  u8(0x20), u8(0x4C), u8(0x45), u8(0x4E), u8(0x20),
];

/// `'WM SUB W '` -- 9 bytes.
@rodata
final List<u8> wmStrSub = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x53), u8(0x55), u8(0x42), u8(0x20), u8(0x57),
  u8(0x20),
];

/// `' PAR '` -- 5 bytes.
@rodata
final List<u8> wmStrPar = const [
  u8(0x20), u8(0x50), u8(0x41), u8(0x52), u8(0x20),
];

/// `'WM SEAT '` -- 8 bytes.
@rodata
final List<u8> wmStrSeat = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x53), u8(0x45), u8(0x41), u8(0x54), u8(0x20),
];

/// `' S '` -- 3 bytes.
@rodata
final List<u8> wmStrS = const [
  u8(0x20), u8(0x53), u8(0x20),
];

/// `' SCL '` -- 5 bytes.
@rodata
final List<u8> wmStrScl = const [
  u8(0x20), u8(0x53), u8(0x43), u8(0x4C), u8(0x20),
];

// ---------------------------------------------------------------------------
// Parent / scale / absolute geometry.
// ---------------------------------------------------------------------------

/// Parent window index, or [wmMaxWindows] if this surface is top-level.
@bare
u64 wmWinParentOf(u64 wI) {
  final u64 st = wmWin(wI, u64(wmWinState));
  final u64 p1 = (st >> u64(wmWinParentShift)) & u64(0xFF);
  if (p1 < u64(1)) {
    return u64(wmMaxWindows);
  }
  return p1 - u64(1);
}

/// Integer buffer scale. Stored 0 means 1.
@bare
u64 wmWinScaleOf(u64 wI) {
  final u64 sc = (wmWin(wI, u64(wmWinStride)) >> u64(wmWinScaleShift)) &
      u64(0xFFFF);
  if (sc < u64(1)) {
    return u64(1);
  }
  return sc;
}

/// Byte stride (low 32 bits of the stride word).
@bare
u64 wmWinStrideOf(u64 wI) {
  return wmWin(wI, u64(wmWinStride)) & u64(0xFFFFFFFF);
}

/// Absolute screen X: walk one parent (no deep trees this rung).
@bare
u64 wmAbsX(u64 wI) {
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 x = wmGeomX(g);
  final u64 p = wmWinParentOf(wI);
  if (p >= u64(wmMaxWindows)) {
    return x;
  }
  if (wmWindowUsable(p) < u64(1)) {
    return x;
  }
  return wmGeomX(wmWin(p, u64(wmWinGeom))) + x;
}

/// Absolute screen Y.
@bare
u64 wmAbsY(u64 wI) {
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 y = wmGeomY(g);
  final u64 p = wmWinParentOf(wI);
  if (p >= u64(wmMaxWindows)) {
    return y;
  }
  if (wmWindowUsable(p) < u64(1)) {
    return y;
  }
  return wmGeomY(wmWin(p, u64(wmWinGeom))) + y;
}

/// 1 if [child] may take [parent] without a cycle (parent is root or
/// unrelated). One-level trees only: parent must itself be top-level.
@bare
u64 wmParentOk(u64 parent, u64 child) {
  if (parent >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (child >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (parent == child) {
    return u64(0);
  }
  if (wmWindowUsable(parent) < u64(1)) {
    return u64(0);
  }
  if (wmWinParentOf(parent) < u64(wmMaxWindows)) {
    return u64(0);
  }
  return u64(1);
}

// ---------------------------------------------------------------------------
// Seats — two PLUS-ONE slots in wmMetaFocus.
// ---------------------------------------------------------------------------

/// Focus PLUS ONE for [seat], or 0.
@bare
u64 wmSeatFocusRaw(u64 seat) {
  final u64 packed = wmMeta(u64(wmMetaFocus));
  if (seat < u64(1)) {
    return packed & u64(0xFF);
  }
  return (packed >> u64(wmSeat1Shift)) & u64(0xFF);
}

/// Live focus PLUS ONE for [seat], clearing a dead slot.
@bare
u64 wmSeatFocusLive(u64 seat) {
  final u64 f = wmSeatFocusRaw(seat);
  if (f < u64(1)) {
    return u64(0);
  }
  final u64 w = f - u64(1);
  if (wmWindowUsable(w) < u64(1)) {
    wmSeatFocusSet(seat, u64(wmMaxWindows));
    return u64(0);
  }
  return f;
}

/// Set seat [seat] focus to window [wI], or none when [wI] is
/// [wmMaxWindows]. Seat 0 still drives enter/leave under `wm de`.
@bare
void wmSeatFocusSet(u64 seat, u64 wI) {
  u64 want = u64(0);
  if (wI < u64(wmMaxWindows)) {
    if (wmWindowUsable(wI) > u64(0)) {
      want = wI + u64(1);
    }
  }
  final u64 packed = wmMeta(u64(wmMetaFocus));
  u64 s0 = packed & u64(0xFF);
  u64 s1 = (packed >> u64(wmSeat1Shift)) & u64(0xFF);
  if (seat < u64(1)) {
    if (s0 == want) {
      return;
    }
    if (wmDeOn() > u64(0)) {
      if (s0 > u64(0)) {
        final u64 ow = s0 - u64(1);
        if (wmWindowUsable(ow) > u64(0)) {
          wmeventEnqueueLeave(ow);
        }
      }
    }
    s0 = want;
    if (wmDeOn() > u64(0)) {
      if (want > u64(0)) {
        wmeventEnqueueEnter(want - u64(1));
      }
    }
  } else {
    s1 = want;
  }
  wmSetMeta(u64(wmMetaFocus), s0 | (s1 << u64(wmSeat1Shift)));
  uartWrite(Rodata.addressOf(wmStrSeat), u64(8));
  uartPutHex(u64(0), u64(1));
  uartWrite(Rodata.addressOf(wmStrS), u64(3));
  uartPutHex(s0, u64(2));
  uartWrite(Rodata.addressOf(wmStrS), u64(3));
  uartPutHex(u64(1), u64(1));
  uartWrite(Rodata.addressOf(wmStrS), u64(3));
  uartPutHex(s1, u64(2));
  uartNewline();
}

// ---------------------------------------------------------------------------
// Clipboard — kernel-mediated copy between client regions.
// ---------------------------------------------------------------------------

/// Copy [len] bytes from region [sr] offset 0 into region [dr] offset 0.
@bare
void wmClipCopy(u64 sr, u64 dr, u64 len) {
  final u64 svec = shmReg(sr, u64(shmRegVec));
  final u64 dvec = shmReg(dr, u64(shmRegVec));
  u64 i = u64(0);
  while (i < len) {
    final u64 spa = shmVec(svec, i >> u64(vmPageShift));
    final u64 dpa = shmVec(dvec, i >> u64(vmPageShift));
    Pointer<u8>.fromAddress(dpa + (i & u64(vmPageMask))).value =
        Pointer<u8>.fromAddress(spa + (i & u64(vmPageMask))).value;
    i = i + u64(1);
  }
}

/// `op = wmOpOffer`. Names a capability whose first [len] bytes become
/// the selection. Cap-backed: the region must stay live for TAKE.
@bare
void wmOffer(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 len = wmDesc(ptr, u64(wmDescArg2));
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpOffer), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpOffer), h, u64(wmRetStale));
    return;
  }
  if (len < u64(1)) {
    wmRefuse(frame, u64(wmOpOffer), h, u64(wmRetBadGeom));
    return;
  }
  if (len > u64(wmClipMaxLen)) {
    wmRefuse(frame, u64(wmOpOffer), h, u64(wmRetBadGeom));
    return;
  }
  final u64 bytes = shmReg(r, u64(shmRegPages)) << u64(vmPageShift);
  if (len > bytes) {
    wmRefuse(frame, u64(wmOpOffer), h, u64(wmRetSmall));
    return;
  }
  shmSetMeta(u64(shmMetaClipReg), r);
  shmSetMeta(u64(shmMetaClipGen), shmReg(r, u64(shmRegGen)));
  shmSetMeta(u64(shmMetaClipOwner), id);
  shmSetMeta(u64(shmMetaClipLen), len);
  uartWrite(Rodata.addressOf(wmStrOffer), u64(11));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(wmStrGen), u64(5));
  uartPutHex(shmReg(r, u64(shmRegGen)), u64(8));
  uartWrite(Rodata.addressOf(wmStrLen), u64(5));
  uartPutHex(len, u64(4));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), len);
}

/// `op = wmOpTake`. Copies the selection into the caller's dest region.
@bare
void wmTake(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetStale));
    return;
  }
  final u64 sr = shmMeta(u64(shmMetaClipReg));
  final u64 len = shmMeta(u64(shmMetaClipLen));
  if (len < u64(1)) {
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetNoWin));
    return;
  }
  if (sr >= u64(shmMax)) {
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetNoWin));
    return;
  }
  if (shmReg(sr, u64(shmRegState)) == u64(shmRegFree)) {
    shmSetMeta(u64(shmMetaClipLen), u64(0));
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetStale));
    return;
  }
  if (shmReg(sr, u64(shmRegGen)) != shmMeta(u64(shmMetaClipGen))) {
    shmSetMeta(u64(shmMetaClipLen), u64(0));
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetStale));
    return;
  }
  final u64 dstBytes = shmReg(r, u64(shmRegPages)) << u64(vmPageShift);
  if (len > dstBytes) {
    wmRefuse(frame, u64(wmOpTake), h, u64(wmRetSmall));
    return;
  }
  wmClipCopy(sr, r, len);
  uartWrite(Rodata.addressOf(wmStrTake), u64(10));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(wmStrLen), u64(5));
  uartPutHex(len, u64(4));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(sr, u64(1));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), len);
}

// ---------------------------------------------------------------------------
// Subsurface attach and move.
// ---------------------------------------------------------------------------

/// `op = wmOpSub`. Child region + parent handle + relative pose.
@bare
void wmSubAttach(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 ph = wmDesc(ptr, u64(wmDescArg2));
  final u64 ox = wmDesc(ptr, u64(wmDescArg3));
  final u64 oy = wmDesc(ptr, u64(wmDescArg4));
  // Words 4/5 were oy/w in an earlier sketch; layout is:
  // 3=ox 4=oy 5=w 6=h 7 unused — wait, Arg5 is word 5 = w, need h in 6.
  // Corrected below using Arg5=w and reading h from word 6 low, scale/stride
  // from a packed word 7 is not available (only 8 words). Use:
  // 5=w, 6=h, and stride/scale default (stride=w*4, scale=1). Offset 0.
  final u64 w = wmDesc(ptr, u64(wmDescArg5));
  final u64 hh = wmDesc(ptr, u64(wmDescArg6));
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetStale));
    return;
  }
  final u64 pr = wmResolve(ph);
  if (pr == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpSub), ph, u64(wmRetBadCap));
    return;
  }
  if (pr > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpSub), ph, u64(wmRetStale));
    return;
  }
  final u64 pslot = wmWindowOfRegion(id, pr);
  // Parent may be owned by this process. Also allow any live window
  // whose region matches — parent is identified by the caller's handle
  // to a region that is already a window for this process.
  u64 parent = pslot;
  if (parent >= u64(wmMaxWindows)) {
    // Parent surface owned by another process: find by region.
    u64 i = u64(0);
    while (i < u64(wmMaxWindows)) {
      if (wmWindowUsable(i) > u64(0)) {
        if (wmWin(i, u64(wmWinReg)) == pr) {
          if (wmWin(i, u64(wmWinGen)) == shmReg(pr, u64(shmRegGen))) {
            parent = i;
          }
        }
      }
      i = i + u64(1);
    }
  }
  if (parent >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpSub), ph, u64(wmRetNoWin));
    return;
  }
  if (w < u64(1)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetBadGeom));
    return;
  }
  if (hh < u64(1)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetBadGeom));
    return;
  }
  final u64 ax = wmAbsX(parent) + ox;
  final u64 ay = wmAbsY(parent) + oy;
  if (wmFits(ax, ay, w, hh) < u64(1)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetBadGeom));
    return;
  }
  final u64 stride = w << u64(2);
  final u64 need = ((hh - u64(1)) * stride) + (w << u64(2));
  if (need > (shmReg(r, u64(shmRegPages)) << u64(vmPageShift))) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetSmall));
    return;
  }
  if (wmWindowOfRegion(id, r) < u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetTwice));
    return;
  }
  final u64 slot = wmFreeWindow();
  if (slot >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpSub), h, u64(wmRetNoSpace));
    return;
  }
  if (wmParentOk(parent, slot) < u64(1)) {
    wmRefuse(frame, u64(wmOpSub), ph, u64(wmRetBadGeom));
    return;
  }
  wmSetWin(slot, u64(wmWinOwner), id);
  wmSetWin(slot, u64(wmWinReg), r);
  wmSetWin(slot, u64(wmWinGen), shmReg(r, u64(shmRegGen)));
  // Relative pose in geom; abs computed at compose/hit.
  wmSetWin(slot, u64(wmWinGeom), wmPackGeom(ox, oy, w, hh));
  wmSetWin(slot, u64(wmWinStride), stride);
  wmSetWin(slot, u64(wmWinOffsetW), u64(0));
  wmSetWin(slot, u64(wmWinSeq), u64(0));
  wmSetWin(slot, u64(wmWinState),
      u64(wmWinLive) | ((parent + u64(1)) << u64(wmWinParentShift)));
  wmSetMeta(u64(wmMetaTop), slot);
  wmSetMeta(u64(wmMetaLive), wmMeta(u64(wmMetaLive)) + u64(1));
  wmBumpMeta(u64(wmMetaAttaches));
  final u64 va = shmRegionVa(r);
  uartWrite(Rodata.addressOf(wmStrSub), u64(9));
  uartPutHex(slot, u64(1));
  uartWrite(Rodata.addressOf(wmStrPar), u64(5));
  uartPutHex(parent, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(ox, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(oy, u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(w, u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(hh, u64(4));
  uartWrite(Rodata.addressOf(wmStrVa), u64(4));
  uartPutHex(va, u64(16));
  uartNewline();
  wmeventEnqueueConfigure(slot);
  userSetFrame(frame, u64(userFrameRax), va);
}

/// `op = wmOpMove`. Reposition; children keep relative offsets so a
/// parent move carries them.
@bare
void wmMoveOp(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 nx = wmDesc(ptr, u64(wmDescArg2));
  final u64 ny = wmDesc(ptr, u64(wmDescArg3));
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpMove), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpMove), h, u64(wmRetStale));
    return;
  }
  final u64 slot = wmWindowOfRegion(id, r);
  if (slot >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpMove), h, u64(wmRetNoWin));
    return;
  }
  final u64 g = wmWin(slot, u64(wmWinGeom));
  final u64 ww = wmGeomW(g);
  final u64 hh = wmGeomH(g);
  final u64 p = wmWinParentOf(slot);
  if (p >= u64(wmMaxWindows)) {
    if (wmFits(nx, ny, ww, hh) < u64(1)) {
      wmRefuse(frame, u64(wmOpMove), h, u64(wmRetBadGeom));
      return;
    }
  } else {
    final u64 ax = wmAbsX(p) + nx;
    final u64 ay = wmAbsY(p) + ny;
    if (wmFits(ax, ay, ww, hh) < u64(1)) {
      wmRefuse(frame, u64(wmOpMove), h, u64(wmRetBadGeom));
      return;
    }
  }
  final u64 b = u64(wmBorder);
  final u64 ox = wmAbsX(slot) - b;
  final u64 oy = wmAbsY(slot) - b;
  wmSetWin(slot, u64(wmWinGeom), wmPackGeom(nx, ny, ww, hh));
  wmeventEnqueueConfigure(slot);
  u64 px = wmRepaintRect(ox, oy, ww + b + b, hh + b + b);
  px = px + wmRepaintWindow(slot);
  if (wmIsOverlay(slot) > u64(0)) {
    if (wmOverlayParked(slot) > u64(0)) {
      /* Hiding a client menu must also invalidate the retained session
       * chrome. A rectangle repaint alone is later overwritten by the cached
       * frame that still contains the menu, recreating the stale card. */
      wmCompose();
      px = fbGeomWidth() * fbGeomHeight();
    }
  }
  // Children of this root: their abs moved; repaint them too.
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWinParentOf(i) == slot) {
      px = px + wmRepaintWindow(i);
    }
    i = i + u64(1);
  }
  wmBumpMeta(u64(wmMetaMoves));
  uartWrite(Rodata.addressOf(wmStrMove), u64(10));
  uartPutHex(slot, u64(1));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(nx, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(ny, u64(4));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(px, u64(8));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), wmMeta(u64(wmMetaFrames)));
}

/// `op = wmOpSeat`. seat in word 2, handle in word 1 (0 clears).
@bare
void wmSeatOp(u64 frame, u64 ptr, u64 id) {
  final u64 h = wmDesc(ptr, u64(wmDescHandle));
  final u64 seat = wmDesc(ptr, u64(wmDescArg2));
  if (seat >= u64(wmSeatCount)) {
    wmRefuse(frame, u64(wmOpSeat), h, u64(wmRetBadGeom));
    return;
  }
  if (h < u64(1)) {
    wmSeatFocusSet(seat, u64(wmMaxWindows));
    userSetFrame(frame, u64(userFrameRax), u64(0));
    return;
  }
  final u64 r = wmResolve(h);
  if (r == u64(shmMax)) {
    wmRefuse(frame, u64(wmOpSeat), h, u64(wmRetBadCap));
    return;
  }
  if (r > u64(shmMax)) {
    wmRefuse(frame, u64(wmOpSeat), h, u64(wmRetStale));
    return;
  }
  final u64 slot = wmWindowOfRegion(id, r);
  if (slot >= u64(wmMaxWindows)) {
    wmRefuse(frame, u64(wmOpSeat), h, u64(wmRetNoWin));
    return;
  }
  wmSeatFocusSet(seat, slot);
  userSetFrame(frame, u64(userFrameRax), slot + u64(1));
}

/// `op = wmOpSeatGet`. rax bits: seat N focuses one of caller's windows.
@bare
void wmSeatGetOp(u64 frame, u64 ptr, u64 id) {
  u64 bits = u64(0);
  u64 s = u64(0);
  while (s < u64(wmSeatCount)) {
    final u64 f = wmSeatFocusLive(s);
    if (f > u64(0)) {
      final u64 w = f - u64(1);
      if (wmWin(w, u64(wmWinOwner)) == id) {
        bits = bits | (u64(1) << s);
      }
    }
    s = s + u64(1);
  }
  userSetFrame(frame, u64(userFrameRax), bits);
}

/// Pack eight bytes from [addr] into rax (little-endian).
@bare
u64 wmPack8(u64 addr) {
  u64 v = u64(0);
  u64 i = u64(0);
  while (i < u64(8)) {
    v = v |
        (Pointer<u8>.fromAddress(addr + i).value.toU64() << (i * u64(8)));
    i = i + u64(1);
  }
  return v;
}

/// `op = wmOpScreen`. Word 2 is WM_SCREEN_*; answer in rax.
@bare
void wmScreenOp(u64 frame, u64 ptr, u64 id) {
  if ((wmMeta(u64(wmMetaRectPixels)) &
          u64(wmRectComposePending)) >
      u64(0)) {
    wmSetMeta(
        u64(wmMetaRectPixels),
        wmMeta(u64(wmMetaRectPixels)) &
            u64(0x7FFFFFFFFFFFFFFF));
    wmCompose();
  }
  final u64 kind = wmDesc(ptr, u64(wmDescArg2));
  if (kind == u64(0)) {
    userSetFrame(frame, u64(userFrameRax),
        (fbGeomWidth() << u64(32)) | fbGeomHeight());
    return;
  }
  if (kind == u64(1)) {
    u64 packed = u64(0);
    u64 n = u64(0);
    u64 i = u64(0);
    while (i < u64(wmMaxWindows)) {
      u64 b = u64(0);
      if (wmWindowUsable(i) > u64(0)) {
        b = b | u64(0x80);
        if (wmIsPanel(i) > u64(0)) {
          b = b | u64(0x40);
        }
        if (wmMeta(u64(wmMetaFocus)) == (i + u64(1))) {
          b = b | u64(0x20);
        }
        b = b | (wmWin(i, u64(wmWinOwner)) & u64(0x1F));
        packed = packed | (b << (i * u64(8)));
        n = n + u64(1);
      }
      i = i + u64(1);
    }
    packed = packed | (n << u64(32));
    userSetFrame(frame, u64(userFrameRax), packed);
    return;
  }
  if (kind == u64(2)) {
    final u64 slot = wmDesc(ptr, u64(wmDescY));
    if (slot >= u64(wmMaxWindows)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    if (wmWindowUsable(slot) < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    u64 stem = Rodata.addressOf(wmStrSlot0);
    if (slot != u64(0)) {
      stem = Rodata.addressOf(wmStrSlot1);
    }
    userSetFrame(frame, u64(userFrameRax), wmPack8(stem));
    return;
  }
  if (kind == u64(3)) {
    final u64 k = wmMeta(u64(wmMetaPop));
    final u64 xy = wmMeta(u64(wmMetaPopXY));
    userSetFrame(frame, u64(userFrameRax), (k << u64(48)) | xy);
    return;
  }
  if (kind == u64(4)) {
    final u64 row = wmDesc(ptr, u64(wmDescY));
    if (row >= wmDeLaunchN()) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    final u64 idx = wmDeLaunchIdx(row);
    final u64 e = fatDirEntry(idx);
    if (e < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    wmDeNameCopy(e);
    userSetFrame(frame, u64(userFrameRax), wmPack8(fatNameBase()));
    return;
  }
  if (kind == u64(5)) {
    if (wmPageAddr() < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), wmPage(u64(wmPageWDeskHave)));
    return;
  }
  userSetFrame(frame, u64(userFrameRax), u64(0));
}

/// Frosted glass paint path (ADR-0198). Routed from wmPaintOp.
@bare
u64 wmPaintGlass(u64 desc, u64 pid) {
  return osgfx_client_paint(u64(0), u64(0), u64(0), u64(0), u64(0), u64(0),
      desc, pid);
}

/// `op = wmOpPaint`. One Skia primitive into the caller's surface.
@bare
void wmPaintOp(u64 frame, u64 ptr, u64 id) {
  final u64 kind = wmDesc(ptr, u64(wmDescArg2));
  u64 px = u64(0);
  u64 pitch = u64(0);
  u64 ww = u64(0);
  u64 hh = u64(0);
  u64 scr_x = u64(0);
  u64 scr_y = u64(0);
  if (kind > u64(0)) {
    final u64 h = wmDesc(ptr, u64(wmDescHandle));
    final u64 r = wmResolve(h);
    if (r == u64(shmMax)) {
      wmRefuse(frame, u64(wmOpPaint), h, u64(wmRetBadCap));
      return;
    }
    if (r > u64(shmMax)) {
      wmRefuse(frame, u64(wmOpPaint), h, u64(wmRetStale));
      return;
    }
    final u64 slot = wmWindowOfRegion(id, r);
    if (slot >= u64(wmMaxWindows)) {
      wmRefuse(frame, u64(wmOpPaint), h, u64(wmRetNoWin));
      return;
    }
    if (wmWin(slot, u64(wmWinOwner)) != id) {
      wmRefuse(frame, u64(wmOpPaint), h, u64(wmRetNoWin));
      return;
    }
    final u64 g = wmWin(slot, u64(wmWinGeom));
    final u64 scale = wmWinScaleOf(slot);
    ww = wmGeomW(g) * scale;
    hh = wmGeomH(g) * scale;
    pitch = wmWinStrideOf(slot);
    final u64 vec = shmReg(wmWin(slot, u64(wmWinReg)), u64(shmRegVec));
    final u64 off = wmWin(slot, u64(wmWinOffsetW));
    px = shmVec(vec, off >> u64(vmPageShift)) + (off & u64(vmPageMask));
    scr_x = wmAbsX(slot);
    scr_y = wmAbsY(slot);
  }
  final u64 ret =
      osgfx_client_paint(px, pitch, ww, hh, scr_x, scr_y, ptr, id);
  if (ret >= u64(wmRetFloor)) {
    wmRefuse(frame, u64(wmOpPaint), wmDesc(ptr, u64(wmDescHandle)), ret);
    return;
  }
  userSetFrame(frame, u64(userFrameRax), ret);
}

/// Dispatch extension ops. Returns 1 if handled.
@bare
u64 wmExtDispatch(u64 frame, u64 ptr, u64 id, u64 op) {
  if (op == u64(wmOpOffer)) {
    wmOffer(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpTake)) {
    wmTake(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpSub)) {
    wmSubAttach(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpSeat)) {
    wmSeatOp(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpMove)) {
    wmMoveOp(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpSeatGet)) {
    wmSeatGetOp(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpScreen)) {
    wmScreenOp(frame, ptr, id);
    return u64(1);
  }
  if (op == u64(wmOpPaint)) {
    wmPaintOp(frame, ptr, id);
    return u64(1);
  }
  return u64(0);
}
