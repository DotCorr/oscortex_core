// core/kernel/wmevent.dart
//
// oscortex_core D7: a click reaches the client under the pointer.
// IRQ12 hit-tests on left PRESS; the owning window's ring holds the
// event; syscall 25 pops it. Surface-relative x,y -- not screen.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// The architecture is docs/decisions/0055-a-click-reaches-the-client.md.
// The design this implements is docs/design/display-protocol.md §6 D7.
//
// ---------------------------------------------------------------------------
// THIS FILE IS LAST IN .bss ON PURPOSE
// ---------------------------------------------------------------------------
// `part 'wmevent.dart'` comes after `part 'kbdq.dart'` in kmain.dart.
// ADR-0031 s4.3 rule 5 asks for the newest block to be last so no earlier
// block's arithmetic moves; ADR-0033 s6.4 recorded that last is necessary
// but not sufficient, and this is the sixth block to arrive under that
// rule. `kbdqStore` is now measured to this block's START rather than to
// the end of `.bss`, which is why every harness that subtracts D2 first
// still reads 288.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Layout. One ring per window slot. Four windows is [wmMaxWindows], which
// is derived from [shmMax] -- a fifth ring would be storage nothing can
// attach a surface to.
// ---------------------------------------------------------------------------

/// Usable slots per window. A named constant so a host model and the
/// kernel agree on one number.
const int wmeventDepth = 8;

const int wmeventWordHead = 0;
const int wmeventWordTail = 1;
const int wmeventWordDropped = 2;
const int wmeventWordCount = 3;
const int wmeventWordEvents = 4;

const int wmeventMetaWords = 4;
const int wmeventSlotWords = 12; // 4 + 8
const int wmeventSlotBytes = 96;
const int wmeventSlots = 4; // == wmMaxWindows; d7-click asserts the equality
const int wmeventStoreWords = 48;
const int wmeventStoreBytes = 384;

/// Packed-event field: bits 0-7. 1 is a left press. 2 is configure
/// (ADR-0142). 3 is enter, 4 is leave. 0 is empty, and is never stored
/// -- a pop of 0 means the ring had nothing for this caller.
const int wmeventTypePress = 1;
const int wmeventTypeConfigure = 2;
const int wmeventTypeEnter = 3;
const int wmeventTypeLeave = 4;

/// Right-press on a client body (ADR-0194). FILES row menu door.
const int wmeventTypeContext = 5;

/// Pointer-axis scroll over a client body. The signed 8-bit wheel delta is
/// stored in bits 48..55: 0xff is one step up, 0x01 one step down.
const int wmeventTypeScroll = 6;

/// Empty [wmeventPop]. Type 0 is not a stored event.
const int wmeventEmpty = 0;

/// Syscall 25 -- `wmevent`. See docs/syscall-registry.md.
///
/// **25 and not 21.** 20 is `mouse`, 23 is `wmsurface`, 24 is `kbdevent`,
/// and 21/22 are taken on other lines (`shmaddr`, `shmpublish`). 11 stays
/// reserved for `fdwait`.
const int wmeventSysNo = 25;

/// `rdi` selectors for [wmeventSys].
const int wmeventOpPop = 0;
const int wmeventOpDropped = 1;
const int wmeventOpCount = 2;

/// LAST in `kmain.o`'s `.bss`. Four per-window rings.
@bss
final Bss wmeventStore = const Bss(bytes: wmeventStoreBytes);

/// Byte address of window [w]'s ring.
@bare
u64 wmeventSlotBase(u64 w) {
  return Bss.addressOf(wmeventStore) + (w * u64(wmeventSlotBytes));
}

/// Reads word [i] of window [w]'s ring.
@bare
u64 wmeventState(u64 w, u64 i) {
  return Pointer<u64>.fromAddress(wmeventSlotBase(w) + (i * u64(8))).value;
}

/// Writes word [i] of window [w]'s ring.
@bare
void wmeventSetState(u64 w, u64 i, u64 v) {
  Pointer<u64>.fromAddress(wmeventSlotBase(w) + (i * u64(8))).value = v;
}

/// Zeroes both rings. `.bss` is not zeroed by anything in this kernel and
/// this prints nothing -- `m1-interrupts` asserts the entire 544-byte boot
/// capture. Same argument as [wmInit] and [kbdqReset].
@bare
void wmeventInit() {
  final u64 base = Bss.addressOf(wmeventStore);
  u64 o = u64(0);
  while (o < u64(wmeventStoreBytes)) {
    Pointer<u64>.fromAddress(base + o).value = u64(0);
    o = o + u64(8);
  }
}

/// Drops every queued event and the overflow counter on window [w].
/// A reused slot that kept a press would hand it to the next owner.
@bare
void wmeventResetSlot(u64 w) {
  if (w < u64(wmeventSlots)) {
    wmeventSetState(w, u64(wmeventWordHead), u64(0));
    wmeventSetState(w, u64(wmeventWordTail), u64(0));
    wmeventSetState(w, u64(wmeventWordDropped), u64(0));
    wmeventSetState(w, u64(wmeventWordCount), u64(0));
  }
}

/// Drops every queued event on both rings. Called from [shellRecover]
/// the same way [kbdqReset] is: a ring that survives a fault with a
/// stale press is a ring that delivers a ghost click.
@bare
void wmeventReset() {
  u64 w = u64(0);
  while (w < u64(wmeventSlots)) {
    wmeventResetSlot(w);
    w = w + u64(1);
  }
}

/// Packs a left-press at surface-relative ([rx], [ry]) on window [wI].
@bare
u64 wmeventPack(u64 wI, u64 rx, u64 ry) {
  return u64(wmeventTypePress)
      | ((wI & u64(0xFF)) << u64(8))
      | ((rx & u64(0xFFFF)) << u64(16))
      | ((ry & u64(0xFFFF)) << u64(32));
}

/// Packs a configure: type 2, window, then 12-bit x/y/w/h. The screen
/// is 800x600; 12 bits is enough and one word is the ring's slot.
@bare
u64 wmeventPackConfigure(u64 wI, u64 x, u64 y, u64 w, u64 h) {
  return u64(wmeventTypeConfigure)
      | ((wI & u64(0xFF)) << u64(8))
      | ((x & u64(0xFFF)) << u64(16))
      | ((y & u64(0xFFF)) << u64(28))
      | ((w & u64(0xFFF)) << u64(40))
      | ((h & u64(0xFFF)) << u64(52));
}

/// Packs enter (3) or leave (4) the same way a press is packed.
@bare
u64 wmeventPackEdge(u64 typ, u64 wI, u64 rx, u64 ry) {
  return (typ & u64(0xFF))
      | ((wI & u64(0xFF)) << u64(8))
      | ((rx & u64(0xFFFF)) << u64(16))
      | ((ry & u64(0xFFFF)) << u64(32));
}

/// Enqueues one packed event on window [w]'s ring. Called from [wmGrab]
/// with IF already clear (IRQ12). If the ring is full the event is
/// dropped and the overflow counter advances -- a missed click that is
/// counted, not a mystery.
@bare
void wmeventPush(u64 w, u64 ev) {
  if (w >= u64(wmeventSlots)) {
    return;
  }
  final u64 n = wmeventState(w, u64(wmeventWordCount));
  if (n >= u64(wmeventDepth)) {
    wmeventSetState(w, u64(wmeventWordDropped),
        wmeventState(w, u64(wmeventWordDropped)) + u64(1));
    return;
  }
  final u64 tail = wmeventState(w, u64(wmeventWordTail));
  wmeventSetState(w, u64(wmeventWordEvents) + tail, ev);
  wmeventSetState(w, u64(wmeventWordTail), (tail + u64(1)) & u64(wmeventDepth - 1));
  wmeventSetState(w, u64(wmeventWordCount), n + u64(1));
}

/// Pushes [ev], or overwrites the newest slot when that slot is already
/// a configure. A resize drag would otherwise fill the ring and drop
/// the last size (overflow drops the newest).
@bare
void wmeventPushCoalesceConfigure(u64 w, u64 ev) {
  if (w >= u64(wmeventSlots)) {
    return;
  }
  final u64 n = wmeventState(w, u64(wmeventWordCount));
  if (n > u64(0)) {
    final u64 tail = wmeventState(w, u64(wmeventWordTail));
    final u64 prevI = (tail + u64(wmeventDepth) - u64(1)) & u64(wmeventDepth - 1);
    final u64 prev = wmeventState(w, u64(wmeventWordEvents) + prevI);
    if ((prev & u64(0xFF)) == u64(wmeventTypeConfigure)) {
      wmeventSetState(w, u64(wmeventWordEvents) + prevI, ev);
      return;
    }
  }
  wmeventPush(w, ev);
}

/// Pushes a scroll event, coalescing adjacent same-direction wheel reports.
///
/// A physical wheel and a touchpad can outpace a FRAME client's polling loop.
/// Keeping the newest accumulated delta avoids filling the eight-slot ring
/// with motion while preserving button/configure ordering. Opposite directions
/// stay separate so a down/up pair is observable instead of cancelling.
@bare
void wmeventPushCoalesceScroll(u64 w, u64 ev) {
  if (w >= u64(wmeventSlots)) {
    return;
  }
  final u64 n = wmeventState(w, u64(wmeventWordCount));
  if (n > u64(0)) {
    final u64 tail = wmeventState(w, u64(wmeventWordTail));
    final u64 prevI =
        (tail + u64(wmeventDepth) - u64(1)) & u64(wmeventDepth - 1);
    final u64 prev = wmeventState(w, u64(wmeventWordEvents) + prevI);
    if ((prev & u64(0xFFFF)) ==
        (ev & u64(0xFFFF))) {
      final u64 a = (prev >> u64(48)) & u64(0xFF);
      final u64 b = (ev >> u64(48)) & u64(0xFF);
      final u64 aNeg = a & u64(0x80);
      final u64 bNeg = b & u64(0x80);
      u64 sameDirection = u64(0);
      if (aNeg > u64(0)) {
        if (bNeg > u64(0)) {
          sameDirection = u64(1);
        }
      } else {
        if (bNeg < u64(1)) {
          sameDirection = u64(1);
        }
      }
      if (sameDirection > u64(0)) {
        u64 sum = u64(0);
        if (aNeg > u64(0)) {
          u64 mag = (u64(0x100) - a) + (u64(0x100) - b);
          if (mag > u64(127)) {
            mag = u64(127);
          }
          sum = u64(0x100) - mag;
        } else {
          sum = a + b;
          if (sum > u64(127)) {
            sum = u64(127);
          }
        }
        wmeventSetState(w, u64(wmeventWordEvents) + prevI,
            (ev & u64(0x00FFFFFFFFFFFFFF)) | (sum << u64(48)));
        return;
      }
    }
  }
  wmeventPush(w, ev);
}

/// Pops the oldest event on window [w]'s ring, or 0 if empty.
@bare
u64 wmeventPop(u64 w) {
  if (w >= u64(wmeventSlots)) {
    return u64(wmeventEmpty);
  }
  final u64 n = wmeventState(w, u64(wmeventWordCount));
  if (n < u64(1)) {
    return u64(wmeventEmpty);
  }
  final u64 head = wmeventState(w, u64(wmeventWordHead));
  final u64 ev = wmeventState(w, u64(wmeventWordEvents) + head);
  wmeventSetState(w, u64(wmeventWordHead), (head + u64(1)) & u64(wmeventDepth - 1));
  wmeventSetState(w, u64(wmeventWordCount), n - u64(1));
  return ev;
}

/// Overflow counter for window [w]. Readable; not cleared by a pop.
@bare
u64 wmeventDropped(u64 w) {
  if (w >= u64(wmeventSlots)) {
    return u64(0);
  }
  return wmeventState(w, u64(wmeventWordDropped));
}

/// How many events are waiting on window [w].
@bare
u64 wmeventCount(u64 w) {
  if (w >= u64(wmeventSlots)) {
    return u64(0);
  }
  return wmeventState(w, u64(wmeventWordCount));
}

/// The calling process's first window, or [wmMaxWindows] if it has none.
///
/// Empty pop is 0 for a caller with no window -- the same answer as an
/// empty ring, because "you have no events" is what both mean. One
/// process may own two windows; [wmeventPopOwned] drains both.
@bare
u64 wmeventCallerWindow() {
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    return u64(wmMaxWindows);
  }
  return wmWindowOf(id);
}

/// Pops the oldest event on any live window owned by [id], or empty.
/// Slot order, lowest first. The packed word still names the window
/// (bits 8-15) so the client can tell main from menu.
@bare
u64 wmeventPopOwned(u64 id) {
  u64 i = u64(0);
  while (i < u64(wmeventSlots)) {
    if (wmWin(i, u64(wmWinState)) == u64(wmWinLive)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        if (wmeventCount(i) > u64(0)) {
          return wmeventPop(i);
        }
      }
    }
    i = i + u64(1);
  }
  return u64(wmeventEmpty);
}

/// Sum of overflow counters on every live window owned by [id].
@bare
u64 wmeventDroppedOwned(u64 id) {
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmeventSlots)) {
    if (wmWin(i, u64(wmWinState)) == u64(wmWinLive)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        n = n + wmeventDropped(i);
      }
    }
    i = i + u64(1);
  }
  return n;
}

/// Sum of queued events on every live window owned by [id].
@bare
u64 wmeventCountOwned(u64 id) {
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmeventSlots)) {
    if (wmWin(i, u64(wmWinState)) == u64(wmWinLive)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        n = n + wmeventCount(i);
      }
    }
    i = i + u64(1);
  }
  return n;
}

/// Drops every queued event on every live window owned by [id].
@bare
void wmeventResetOwned(u64 id) {
  u64 i = u64(0);
  while (i < u64(wmeventSlots)) {
    if (wmWin(i, u64(wmWinState)) == u64(wmWinLive)) {
      if (wmWin(i, u64(wmWinOwner)) == id) {
        wmeventResetSlot(i);
      }
    }
    i = i + u64(1);
  }
}

/// Called from [wmGrab] on a left PRESS that [wmHit] resolved to a
/// window. Coordinates are converted to surface-relative here, so a
/// client never has to know where the compositor placed it.
///
/// A click on the desktop never reaches this function: [wmGrab] returns
/// before calling it when [wmHit] finds nothing.
@bare
void wmeventEnqueue(u64 wI, u64 x, u64 y) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  final u64 rx = x - wmAbsX(wI);
  final u64 ry = y - wmAbsY(wI);
  wmeventPush(wI, wmeventPack(wI, rx, ry));
}

/// Routes a signed wheel delta to the client body currently under the pointer.
///
/// Scrolling follows hover, not keyboard focus. Desktop, title chrome, resize
/// handles, and the panel intentionally consume no client scroll event.
@bare
void wmeventEnqueueScroll(u64 x, u64 y, u64 delta) {
  if (wmActive() < u64(1)) {
    return;
  }
  final u64 d = delta & u64(0xFF);
  if (d < u64(1)) {
    return;
  }
  final u64 hit = wmHit(x, y);
  if (hit >= u64(wmMaxWindows)) {
    return;
  }
  if (wmIsPanel(hit) > u64(0)) {
    return;
  }
  if (wmDeOn() > u64(0)) {
    if (wmTitleHit(hit, x, y) > u64(0)) {
      return;
    }
    if (wmResizeHit(hit, x, y) > u64(0)) {
      return;
    }
  }
  final u64 rx = x - wmAbsX(hit);
  final u64 ry = y - wmAbsY(hit);
  final u64 ev = u64(wmeventTypeScroll)
      | ((hit & u64(0xFF)) << u64(8))
      | ((rx & u64(0xFFFF)) << u64(16))
      | ((ry & u64(0xFFFF)) << u64(32))
      | (d << u64(48));
  wmLatStamp(u64(wmLatKindWheel));
  wmeventPushCoalesceScroll(hit, ev);
}

/// Tells window [wI]'s owner the compositor geom. Gated on `wm de` so
/// d7-click still pops a press first. ADR-0142 / GAP-0308.
@bare
void wmeventEnqueueConfigure(u64 wI) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  wmeventPushCoalesceConfigure(
      wI,
      wmeventPackConfigure(
          wI, wmAbsX(wI), wmAbsY(wI), wmGeomW(g), wmGeomH(g)));
}

/// Pointer entered [wI]. Same `wm de` gate as configure.
@bare
void wmeventEnqueueEnter(u64 wI) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  wmeventPush(wI, wmeventPackEdge(u64(wmeventTypeEnter), wI, u64(0), u64(0)));
}

/// Pointer left [wI]. Same `wm de` gate as configure.
@bare
void wmeventEnqueueLeave(u64 wI) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  wmeventPush(wI, wmeventPackEdge(u64(wmeventTypeLeave), wI, u64(0), u64(0)));
}

/// Syscall 25. `rdi` selects the read: 0 pops one event for THIS
/// process's windows, 1 returns those windows' overflow counters, 2
/// returns their queued count. Anything else is refused.
///
/// **Per-process.** A process sees the rings of every window it owns
/// (one or two). The packed word names the slot so the client can
/// tell which handle the press landed on. A caller that is not a
/// process, or that holds no window, pops 0.
@bare
void wmeventSys(u64 frame) {
  final u64 op = userFrame(frame, u64(userFrameRdi));
  final u64 id = shmCallerId();
  if (op == u64(wmeventOpPop)) {
    if (id < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(wmeventEmpty));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), wmeventPopOwned(id));
    return;
  }
  if (op == u64(wmeventOpDropped)) {
    if (id < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), wmeventDroppedOwned(id));
    return;
  }
  if (op == u64(wmeventOpCount)) {
    if (id < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), wmeventCountOwned(id));
    return;
  }
  userRefuse(frame, u64(wmeventSysNo), op, u64(0));
}
