// core/kernel/kbdq.dart
//
// oscortex_core D2 / D9: the keyboard input queue. IRQ1 is the producer;
// the shell and syscall 24 are the consumers. D9 (ADR-0062) gates the
// consumers on compositor focus: [kbdqDrainToShell] skips when
// [wmFocusLive] is not 0, and [kbdqSys] pops only for the focused
// window's owner. Raw scancode + edge, not ASCII.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// The architecture is docs/decisions/0054-input-is-a-queue.md. The design
// this implements is docs/design/display-protocol.md §4.2 and §6 D2.
//
// ---------------------------------------------------------------------------
// THIS FILE IS IMMEDIATELY BEFORE THE LAST `.bss` BLOCK
// ---------------------------------------------------------------------------
// Part order is wm, wmchrome, wmpop, kbdq, nic, wmevent last. `wmeventStore` (192)
// is last; `nic.dart` donates no `.bss`, so `kbdqStore` still abuts it.
// ADR-0031 s4.3 rule 5 and ADR-0033 s6.4: this was the fifth block to
// arrive under that rule and is now measured to `wmeventStore`'s START,
// which is why every harness that subtracts D2 still reads 288. Total
// mutable statics is 22816.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Layout. Four header words, then [kbdqDepth] event slots.
// ---------------------------------------------------------------------------

/// Usable slots. A named constant so the overflow test and the kernel agree
/// on one number, and so a host model with depth 1 can fail the same
/// assertion on purpose.
const int kbdqDepth = 32;

const int kbdqWordHead = 0;
const int kbdqWordTail = 1;
const int kbdqWordDropped = 2;
const int kbdqWordCount = 3;
const int kbdqWordEvents = 4;

const int kbdqMetaWords = 4;
const int kbdqStoreWords = 36; // 4 + 32
const int kbdqStoreBytes = 288;

/// Bit 8: this event is a break (key release). Bits 0-7 are the make
/// scancode either way.
const int kbdqBitBreak = 0x100;

/// Bit 9: the 0xE0 prefix preceded this byte. Arrow keys, right-hand
/// modifiers, keypad Enter. The shell consumer skips these, the way
/// `kbdHandle` used to consume them and do nothing.
const int kbdqBitExt = 0x200;

/// Empty [kbdqPop]. Scancode 0x00 is the 8042's "buffer overrun" code and
/// is never a real make, so a packed event of 0 cannot be confused with a
/// stored key.
const int kbdqEmpty = 0;

/// Syscall 24 -- `kbdevent`. See docs/syscall-registry.md.
///
/// **24 and not 21.** 20 is `mouse`, 23 is `wmsurface`, and 21/22 are taken
/// on other lines (`shmaddr`, `shmpublish`). 11 stays reserved for `fdwait`.
const int kbdqSysNo = 24;

/// `rdi` selectors for [kbdqSys].
const int kbdqOpPop = 0;
const int kbdqOpDropped = 1;
const int kbdqOpCount = 2;

/// Immediately before `wmeventStore` (last) in `kmain.o`'s `.bss`.
/// Four header words and 32 event slots.
@bss
final Bss kbdqStore = const Bss(bytes: kbdqStoreBytes);

/// Reads word [i].
@bare
u64 kbdqState(u64 i) {
  return Pointer<u64>.fromAddress(Bss.addressOf(kbdqStore) + (i * u64(8))).value;
}

/// Writes word [i].
@bare
void kbdqSetState(u64 i, u64 v) {
  Pointer<u64>.fromAddress(Bss.addressOf(kbdqStore) + (i * u64(8))).value = v;
}

/// Drops every queued event and the overflow counter. Called from
/// [shellRecover]: a queue that survives a fault with stale contents is a
/// queue that types a ghost command after the prompt comes back.
@bare
void kbdqReset() {
  kbdqSetState(u64(kbdqWordHead), u64(0));
  kbdqSetState(u64(kbdqWordTail), u64(0));
  kbdqSetState(u64(kbdqWordDropped), u64(0));
  kbdqSetState(u64(kbdqWordCount), u64(0));
}

/// Enqueues one packed event. Called from [kbdHandle] with IF already
/// clear. If the ring is full the event is dropped and the overflow
/// counter advances -- a missed key that is counted, not a mystery.
@bare
void kbdqPush(u64 ev) {
  final u64 n = kbdqState(u64(kbdqWordCount));
  if (n >= u64(kbdqDepth)) {
    kbdqSetState(u64(kbdqWordDropped),
        kbdqState(u64(kbdqWordDropped)) + u64(1));
    return;
  }
  final u64 tail = kbdqState(u64(kbdqWordTail));
  kbdqSetState(u64(kbdqWordEvents) + tail, ev);
  kbdqSetState(u64(kbdqWordTail), (tail + u64(1)) & u64(kbdqDepth - 1));
  kbdqSetState(u64(kbdqWordCount), n + u64(1));
}

/// Pops the oldest event, or 0 if the ring is empty. Called with IF clear
/// -- from [kbdqDrainToShell] under `cli`, and from [kbdqSys] inside the
/// syscall gate.
@bare
u64 kbdqPop() {
  final u64 n = kbdqState(u64(kbdqWordCount));
  if (n < u64(1)) {
    return u64(kbdqEmpty);
  }
  final u64 head = kbdqState(u64(kbdqWordHead));
  final u64 ev = kbdqState(u64(kbdqWordEvents) + head);
  kbdqSetState(u64(kbdqWordHead), (head + u64(1)) & u64(kbdqDepth - 1));
  kbdqSetState(u64(kbdqWordCount), n - u64(1));
  return ev;
}

/// The overflow counter. Readable; not cleared by a pop.
@bare
u64 kbdqDropped() {
  return kbdqState(u64(kbdqWordDropped));
}

/// How many events are waiting.
@bare
u64 kbdqCount() {
  return kbdqState(u64(kbdqWordCount));
}

/// Task-context consumer: drain the queue into the line editor while the
/// shell is accepting input and no surface holds keyboard focus.
///
/// D9: [wmFocusLive] != 0 means the focused client's [kbdqSys] owns
/// the events. This function returns without popping.
///
/// Translation happens HERE, not in the IRQ. Break codes and extended
/// keys are skipped, the way `kbdHandle` used to drop them before it
/// called [shellKey]. Enter stops the drain so a submitted line is not
/// followed by the type-ahead that belongs to the NEXT prompt.
///
/// Reached only through `kbd_drain_gate` in `isr.S`. An inlined walk
/// next to the prompt printer in [shellMain] `#UD`s -- that is how D3
/// learned this, and this drain is the same shape of walk.
@bare
void kbdqDrainToShell() {
  if (wmFocusLive() > u64(0)) {
    return;
  }
  u64 going = u64(1);
  while (going > u64(0)) {
    if (shellState() > u64(0)) {
      going = u64(0);
    } else {
      final u64 ev = kbdqPop();
      if (ev == u64(kbdqEmpty)) {
        going = u64(0);
      } else {
        if ((ev & u64(kbdqBitBreak | kbdqBitExt)) > u64(0)) {
          going = going;
        } else {
          final u64 sc = ev & u64(0x7F);
          final u8 c = Pointer<u8>.fromAddress(
            Rodata.addressOf(kbdSet1Ascii) + sc,
          ).value;
          if (c < u8(1)) {
            going = going;
          } else {
            shellKey(c);
            vgaUpdateHwCursor();
            if (c == u8(0x0A)) {
              going = u64(0);
            }
          }
        }
      }
    }
  }
}

/// 1 if this caller may read the queue.
///
/// No focus: anyone, the D2 contract. A live focus: only the process
/// that owns that window. An unfocused client pops 0, the same answer
/// as an empty ring -- "you have no events" is what both mean.
@bare
u64 kbdqCallerMayRead() {
  final u64 f = wmFocusLive();
  if (f < u64(1)) {
    return u64(1);
  }
  final u64 id = shmCallerId();
  if (id < u64(1)) {
    return u64(0);
  }
  final u64 w = f - u64(1);
  if (wmWin(w, u64(wmWinOwner)) == id) {
    return u64(1);
  }
  return u64(0);
}

/// Syscall 24. `rdi` selects the read: 0 pops one event, 1 returns the
/// overflow counter, 2 returns the queued count. Anything else is
/// refused. Writing the queue from ring 3 is not offered.
///
/// **D9:** when [wmFocusLive] is not 0, only the focused window's
/// owner sees events. Everyone else pops 0. When focus is 0 the
/// queue is still global -- that is why `d2-input` did not move.
@bare
void kbdqSys(u64 frame) {
  final u64 op = userFrame(frame, u64(userFrameRdi));
  if (op == u64(kbdqOpPop)) {
    if (kbdqCallerMayRead() < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(kbdqEmpty));
      return;
    }
    final u64 ev = kbdqPop();
    if (wmDeKey(ev) > u64(0)) {
      userSetFrame(frame, u64(userFrameRax), u64(kbdqEmpty));
      return;
    }
    if (wmPopKey(ev) > u64(0)) {
      userSetFrame(frame, u64(userFrameRax), u64(kbdqEmpty));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), ev);
    return;
  }
  if (op == u64(kbdqOpDropped)) {
    if (kbdqCallerMayRead() < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), kbdqDropped());
    return;
  }
  if (op == u64(kbdqOpCount)) {
    if (kbdqCallerMayRead() < u64(1)) {
      userSetFrame(frame, u64(userFrameRax), u64(0));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), kbdqCount());
    return;
  }
  userRefuse(frame, u64(kbdqSysNo), op, u64(0));
}
