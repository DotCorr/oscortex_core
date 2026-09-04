// core/kernel/virtab.dart
//
// ADR-0193. VirtIO-tablet (virtio-input, PCI 0x1AF4:0x1052): one
// eventq of 8-byte virtio_input_event, ABS_X / ABS_Y scaled into
// screen pixels, then [mouseAbsPlace]. SET, not accumulate.
//
// ZERO donated `.bss`. Rings and the event buffers live in one
// allocFrame(); last-used / pending / abs-max sit in that frame's
// header. Reuses virtgpu's modern-transport helpers (COMMON_CFG,
// notify, VERSION_1). Not a rewrite of mouse.dart's 8042 path.
// Keyboard stays on the 8042. No help line. No syscall.
//
// Bring-up is [virtabInit] from [mouseEnable] (silent) and the
// hidden `vtab` command (prints). Poll is [virtabPoll] on IRQ0
// once [mouseFlagTablet] is set — the PIT stays unmasked for that
// bit so a session that never typed `wm pace` still sees the
// pointer.

part of 'kmain.dart';

/// Modern virtio-input PCI device id: 0x1040 + 18.
const int virtabVendor = 0x1AF4;
const int virtabDevice = 0x1052;

const int virtabRegCmd = 0x04;
const int virtabCmdMemBme = 0x06;

const int virtabCfgSelect = 0x00;
const int virtabCfgSubsel = 0x01;
const int virtabCfgAbsMax = 0x0C;
const int virtabCfgAbsInfo = 0x12;
const int virtabAbsX = 0;
const int virtabAbsY = 1;

/*
 * A host pointer can report faster than the 100 Hz PIT poll. Sixteen event
 * slots held only five X/Y/SYN reports, so a short fast sweep exhausted the
 * ring and the final absolute position could be dropped. Sixty-four slots
 * still fit comfortably in the one donated page:
 *
 *   desc  000..3ff   avail 400..483   used 500..703
 *   event 800..9ff   header a00..
 */
const int virtabQSize = 64;
const int virtabOffAvail = 0x400;
const int virtabOffUsed = 0x500;
const int virtabOffEvt = 0x800;
const int virtabOffHdr = 0xA00;
const int virtabMagic = 0x54414231;

const int virtabEvSyn = 0x00;
const int virtabEvKey = 0x01;
const int virtabEvRel = 0x02;
const int virtabEvAbs = 0x03;
const int virtabAbsCodeX = 0x00;
const int virtabAbsCodeY = 0x01;
const int virtabRelWheel = 0x08;
const int virtabBtnLeft = 0x110;
const int virtabBtnRight = 0x111;
const int virtabBtnMiddle = 0x112;
const int virtabDefaultMax = 32767;
const int virtabPollCap = 64;

/// `"vtab"` -- 4 bytes.
@rodata
final List<u8> virtabStrCmd = const [
  u8(0x76), u8(0x74), u8(0x61), u8(0x62),
];

/// `"vtab feed "` -- 10 bytes.
@rodata
final List<u8> virtabStrCmdFeed = const [
  u8(0x76), u8(0x74), u8(0x61), u8(0x62), u8(0x20),
  u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20),
];

/// `"VTAB NONE\n"` -- 10 bytes.
@rodata
final List<u8> virtabStrNone = const [
  u8(0x56), u8(0x54), u8(0x41), u8(0x42), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// `"VTAB OK "` -- 8 bytes.
@rodata
final List<u8> virtabStrOk = const [
  u8(0x56), u8(0x54), u8(0x41), u8(0x42), u8(0x20),
  u8(0x4F), u8(0x4B), u8(0x20),
];

/// `"VTAB FAIL "` -- 10 bytes. Then a one-nibble reason.
@rodata
final List<u8> virtabStrFail = const [
  u8(0x56), u8(0x54), u8(0x41), u8(0x42), u8(0x20),
  u8(0x46), u8(0x41), u8(0x49), u8(0x4C), u8(0x20),
];

/// `"VTAB FEED "` -- 10 bytes.
@rodata
final List<u8> virtabStrFeed = const [
  u8(0x56), u8(0x54), u8(0x41), u8(0x42), u8(0x20),
  u8(0x46), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// Prints `VTAB FAIL <n>` when [announce] is set.
@bare
void virtabFail(u64 announce, u64 why) {
  if (announce < u64(1)) {
    return;
  }
  uartWrite(Rodata.addressOf(virtabStrFail), u64(10));
  uartPutHex(why, u64(1));
  uartNewline();
}

/// PCI slot of virtio-tablet, or 32.
@bare
u64 virtabFind() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtabVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtabDevice)) {
        return dev;
      }
    }
    dev = dev + u64(1);
  }
  return u64(32);
}

/// MEM|BME. Status half zeroed so a W1C bit is not cleared.
@bare
void virtabEnableMaster(u64 bus, u64 dev, u64 fn) {
  final u64 before = pciRead32(bus, dev, fn, u64(virtabRegCmd));
  final u64 written = (before & u64(0xFFFF)) | u64(virtabCmdMemBme);
  pciWrite32(bus, dev, fn, u64(virtabRegCmd), written);
}

/// DEVICE_CFG abs max for [axis], or [virtabDefaultMax].
@bare
u64 virtabAbsMax(u64 bus, u64 dev, u64 fn, u64 axis) {
  final u64 dcfg = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapDevice));
  if (dcfg < u64(1)) {
    return u64(virtabDefaultMax);
  }
  Volatile<u8>.fromAddress(dcfg + u64(virtabCfgSelect)).value =
      u64(virtabCfgAbsInfo).toU8();
  Volatile<u8>.fromAddress(dcfg + u64(virtabCfgSubsel)).value = axis.toU8();
  final u64 mx = virtgpuCfgGet32(dcfg, u64(virtabCfgAbsMax));
  if (mx < u64(1)) {
    return u64(virtabDefaultMax);
  }
  return mx;
}

/// [value] in 0..[mx] onto 0..[span]-1.
@bare
u64 virtabScale(u64 value, u64 mx, u64 span) {
  if (span < u64(2)) {
    return u64(0);
  }
  if (mx < u64(1)) {
    return u64(0);
  }
  u64 v = value;
  if (v > mx) {
    v = mx;
  }
  return (v * (span - u64(1))) ~/ mx;
}

/// Fill the eventq with [n] device-writable 8-byte slots.
@bare
void virtabPostAll(u64 frame, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    virtgpuPutDesc(
        frame,
        i,
        frame + u64(virtabOffEvt) + (i << u64(3)),
        u64(8),
        u64(virtgpuDescWrite),
        u64(0));
    virtgpuRamPut16(frame + u64(virtabOffAvail) + u64(4) + (i << u64(1)), i);
    i = i + u64(1);
  }
  virtgpuRamPut16(frame + u64(virtabOffAvail), u64(virtgpuAvailNoInt));
  virtgpuRamPut16(frame + u64(virtabOffAvail) + u64(2), n);
}

/// Arm the eventq. [announce] 1 prints `VTAB OK` / `VTAB NONE`.
@bare
void virtabInit(u64 announce) {
  final u64 found = virtabFind();
  if (found > u64(31)) {
    if (announce > u64(0)) {
      uartWrite(Rodata.addressOf(virtabStrNone), u64(10));
    }
    return;
  }
  virtabEnableMaster(u64(0), found, u64(0));
  final u64 cfg = virtgpuCommonCfg(u64(0), found, u64(0));
  if (cfg < u64(1)) {
    virtabFail(announce, u64(1));
    return;
  }
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) > u64(0)) {
    mouseFlag(u64(mouseFlagTablet));
    picUnmaskLine(u64(0));
    if (announce > u64(0)) {
      uartWrite(Rodata.addressOf(virtabStrOk), u64(8));
      uartPutHex(found, u64(2));
      uartNewline();
    }
    return;
  }
  if (virtgpuReset(cfg) < u64(1)) {
    virtabFail(announce, u64(2));
    return;
  }
  virtgpuStatusOr(cfg, u64(virtgpuStatusAck));
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriver));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(0));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(0));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), u64(0));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(1));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(1));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), u64(virtgpuFeatVersion1));
  virtgpuStatusOr(cfg, u64(virtgpuStatusFeatOk));
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusFeatOk)) < u64(1)) {
    virtabFail(announce, u64(3));
    return;
  }
  final u64 frame = allocFrame();
  if (frame < u64(1)) {
    virtabFail(announce, u64(4));
    return;
  }
  virtgpuZero(frame, u64(4096));
  final u64 maxX = virtabAbsMax(u64(0), found, u64(0), u64(virtabAbsX));
  final u64 maxY = virtabAbsMax(u64(0), found, u64(0), u64(virtabAbsY));
  virtgpuRamPut32(frame + u64(virtabOffHdr), u64(virtabMagic));
  virtgpuRamPut32(frame + u64(virtabOffHdr) + u64(16), maxX);
  virtgpuRamPut32(frame + u64(virtabOffHdr) + u64(20), maxY);

  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
  if (qsz > u64(virtabQSize)) {
    qsz = u64(virtabQSize);
  }
  if (qsz < u64(1)) {
    virtabFail(announce, u64(5));
    return;
  }
  virtgpuRamPut32(frame + u64(virtabOffHdr) + u64(32), qsz);
  /* Last announced pixel xy. 0xFFFFFFFF = never, so the first place prints. */
  virtgpuRamPut32(frame + u64(virtabOffHdr) + u64(36), u64(0xFFFFFFFF));
  virtgpuRamPut32(frame + u64(virtabOffHdr) + u64(40), u64(0xFFFFFFFF));
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDesc), frame);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDriver), frame + u64(virtabOffAvail));
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDevice), frame + u64(virtabOffUsed));
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQEn), u64(1));
  virtabPostAll(frame, qsz);
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk));
  final u64 naddr = virtgpuNotifyAddr(u64(0), found, u64(0), cfg);
  if (naddr > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  mouseFlag(u64(mouseFlagTablet));
  picUnmaskLine(u64(0));
  if (announce > u64(0)) {
    uartWrite(Rodata.addressOf(virtabStrOk), u64(8));
    uartPutHex(found, u64(2));
    uartSpace();
    uartPutHex(maxX, u64(4));
    uartSpace();
    uartPutHex(maxY, u64(4));
    uartNewline();
  }
}

/// One SYN_REPORT: scale pending abs into pixels and SET the pointer.
@bare
void virtabCommit(u64 hdr) {
  final u64 maxX = virtgpuRamGet32(hdr + u64(16));
  final u64 maxY = virtgpuRamGet32(hdr + u64(20));
  final u64 rawX = virtgpuRamGet32(hdr + u64(8));
  final u64 rawY = virtgpuRamGet32(hdr + u64(12));
  final u64 buttons = virtgpuRamGet32(hdr + u64(24));
  final u64 prev = virtgpuRamGet32(hdr + u64(28));
  final u64 x = virtabScale(rawX, maxX, fbGeomWidth());
  final u64 y = virtabScale(rawY, maxY, fbGeomHeight());
  // Every SYN would flood COM1. Print on a button edge or when the
  // pointer has moved at least 12px from the last announced sample
  // so bare place/drag proves ABS without a button edge.
  u64 announce = u64(0);
  final u64 lastX = virtgpuRamGet32(hdr + u64(36));
  final u64 lastY = virtgpuRamGet32(hdr + u64(40));
  if (buttons != prev) {
    announce = u64(1);
    virtgpuRamPut32(hdr + u64(28), buttons);
  }
  if (lastX == u64(0xFFFFFFFF)) {
    announce = u64(1);
  } else {
    u64 dx = u64(0);
    u64 dy = u64(0);
    if (x > lastX) {
      dx = x - lastX;
    } else {
      dx = lastX - x;
    }
    if (y > lastY) {
      dy = y - lastY;
    } else {
      dy = lastY - y;
    }
    if (dx >= u64(12)) {
      announce = u64(1);
    }
    if (dy >= u64(12)) {
      announce = u64(1);
    }
  }
  if (announce > u64(0)) {
    virtgpuRamPut32(hdr + u64(36), x);
    virtgpuRamPut32(hdr + u64(40), y);
  }
  mouseAbsPlace(x, y, buttons, announce);
}

/// Apply one virtio_input_event at [ev] against header [hdr].
@bare
void virtabApply(u64 hdr, u64 ev) {
  final u64 typ = virtgpuRamGet16(ev);
  final u64 code = virtgpuRamGet16(ev + u64(2));
  final u64 value = virtgpuRamGet32(ev + u64(4));
  if (typ == u64(virtabEvAbs)) {
    if (code == u64(virtabAbsCodeX)) {
      virtgpuRamPut32(hdr + u64(8), value);
      return;
    }
    if (code == u64(virtabAbsCodeY)) {
      virtgpuRamPut32(hdr + u64(12), value);
    }
    return;
  }
  if (typ == u64(virtabEvKey)) {
    u64 bits = virtgpuRamGet32(hdr + u64(24));
    u64 mask = u64(0);
    if (code == u64(virtabBtnLeft)) {
      mask = u64(1);
    }
    if (code == u64(virtabBtnRight)) {
      mask = u64(2);
    }
    if (code == u64(virtabBtnMiddle)) {
      mask = u64(4);
    }
    if (mask < u64(1)) {
      return;
    }
    if (value > u64(0)) {
      bits = bits | mask;
    } else {
      bits = bits & (u64(0xFF) - mask);
    }
    virtgpuRamPut32(hdr + u64(24), bits);
    return;
  }
  if (typ == u64(virtabEvRel)) {
    if (code == u64(virtabRelWheel)) {
      /*
       * Linux REL_WHEEL is positive for up, while PS/2 (and the FRAME wire)
       * is negative for up. Normalize here: QEMU emits +1/-1, and the client
       * receives 0xff/0x01 respectively. Keep it until SYN_REPORT so pending
       * ABS axes and the wheel target are one coherent report.
       */
      final u64 low = value & u64(0xFF);
      if (low > u64(0)) {
        if ((low & u64(0x80)) > u64(0)) {
          u64 magnitude = u64(0x100) - low;
          if (magnitude > u64(127)) {
            magnitude = u64(127);
          }
          virtgpuRamPut32(hdr + u64(44), magnitude);
        } else {
          u64 magnitude = low;
          if (magnitude > u64(127)) {
            magnitude = u64(127);
          }
          virtgpuRamPut32(hdr + u64(44), u64(0x100) - magnitude);
        }
      }
    }
    return;
  }
  if (typ == u64(virtabEvSyn)) {
    if (code == u64(0)) {
      /* Wheel is hdr+44. hdr+40 is last announced Y — treating Y as a
       * REL_WHEEL fired FILES paint_all on the first body SYN after
       * drag (cold 120 ms). */
      final u64 wheel = virtgpuRamGet32(hdr + u64(44));
      if (wheel > u64(0)) {
        virtgpuRamPut32(hdr + u64(44), u64(0));
        virtabCommit(hdr);
        wmeventEnqueueScroll(
            mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)), wheel);
        return;
      }
      final u64 buttons = virtgpuRamGet32(hdr + u64(24));
      final u64 prev = virtgpuRamGet32(hdr + u64(28));
      if (buttons != prev) {
        /*
         * Never coalesce a button edge: its X/Y and button state are one
         * atomic report and press+release may both arrive in one PIT period.
         */
        virtgpuRamPut32(hdr + u64(36), u64(0));
        virtabCommit(hdr);
      } else {
        /*
         * Bare motion is last-position-wins. Painting every queued SYN made
         * one IRQ perform up to five save-under cycles and exposed all those
         * intermediate positions as visible jitter.
         */
        virtgpuRamPut32(hdr + u64(36), u64(1));
      }
    }
  }
}

/// Drain the eventq. No-op unless [mouseFlagTablet] is set.
@bare
void virtabPoll() {
  if ((mouseInitFlags() & u64(mouseFlagTablet)) < u64(1)) {
    return;
  }
  final u64 found = virtabFind();
  if (found > u64(31)) {
    return;
  }
  final u64 cfg = virtgpuCommonCfg(u64(0), found, u64(0));
  if (cfg < u64(1)) {
    return;
  }
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) < u64(1)) {
    return;
  }
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  final u64 frame = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc));
  if (frame < u64(1)) {
    return;
  }
  final u64 hdr = frame + u64(virtabOffHdr);
  if (virtgpuRamGet32(hdr) != u64(virtabMagic)) {
    return;
  }
  final u64 qsz = virtgpuRamGet32(hdr + u64(32));
  if (qsz < u64(1)) {
    return;
  }
  if (qsz > u64(virtabQSize)) {
    return;
  }
  final u64 used = virtgpuRamGet16(frame + u64(virtabOffUsed) + u64(2));
  u64 last = virtgpuRamGet16(hdr + u64(4));
  u64 n = u64(0);
  while (last != used) {
    if (n >= u64(virtabPollCap)) {
      virtgpuRamPut16(hdr + u64(4), last);
      return;
    }
    final u64 slot = last % qsz;
    final u64 descId =
        virtgpuRamGet32(frame + u64(virtabOffUsed) + u64(4) + (slot << u64(3)));
    if (descId < qsz) {
      virtabApply(hdr, frame + u64(virtabOffEvt) + (descId << u64(3)));
      final u64 aidx = virtgpuRamGet16(frame + u64(virtabOffAvail) + u64(2));
      virtgpuRamPut16(
          frame + u64(virtabOffAvail) + u64(4) + ((aidx % qsz) << u64(1)),
          descId);
      virtgpuRamPut16(frame + u64(virtabOffAvail) + u64(2), aidx + u64(1));
    }
    last = (last + u64(1)) & u64(0xFFFF);
    n = n + u64(1);
  }
  if (n < u64(1)) {
    return;
  }
  virtgpuRamPut16(hdr + u64(4), last);
  final u64 naddr = virtgpuNotifyAddr(u64(0), found, u64(0), cfg);
  if (naddr > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  if (virtgpuRamGet32(hdr + u64(36)) > u64(0)) {
    virtgpuRamPut32(hdr + u64(36), u64(0));
    virtabCommit(hdr);
  }
}

/// `vtab` -- find / arm / report.
@bare
void shellVtab() {
  virtabInit(u64(1));
}

/// `vtab feed <hex>` -- SET the pointer from COM1. Five bytes:
/// xlo xhi ylo yhi buttons (little-endian 16-bit axes).
@bare
void shellVtabFeed() {
  final u64 len = shellLen();
  u64 i = u64(10);
  u64 pending = u64(0x100);
  u64 n = u64(0);
  u64 b0 = u64(0);
  u64 b1 = u64(0);
  u64 b2 = u64(0);
  u64 b3 = u64(0);
  u64 b4 = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        final u64 cur = (pending << u64(4)) | d;
        pending = u64(0x100);
        if (n == u64(0)) {
          b0 = cur;
        }
        if (n == u64(1)) {
          b1 = cur;
        }
        if (n == u64(2)) {
          b2 = cur;
        }
        if (n == u64(3)) {
          b3 = cur;
        }
        if (n == u64(4)) {
          b4 = cur;
        }
        n = n + u64(1);
      }
    }
    i = i + u64(1);
  }
  if (n > u64(4)) {
    final u64 x = b0 | (b1 << u64(8));
    final u64 y = b2 | (b3 << u64(8));
    mouseAbsPlace(x, y, b4, u64(1));
  }
  uartWrite(Rodata.addressOf(virtabStrFeed), u64(10));
  uartPutHex(n, u64(2));
  uartNewline();
}
