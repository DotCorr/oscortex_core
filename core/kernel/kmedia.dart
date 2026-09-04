// core/kernel/kmedia.dart
//
// DE-media (ADR-0116) + sit-in blit (ADR-0131) + wmsurface window
// (ADR-0135) + movie (ADR-0143). Hidden `play` copies a planted 8.3
// clip into the .osmedia_cmd mailbox. IRQ0 decodes through the C ABI;
// `fbBlitArgb` stores the RGB tile on the live scanout; `wmMediaFill`
// commits those bytes through a shm-backed window, then a second
// still on a later tick. Serial PIX is not the floor.
//
// ZERO donated `.bss`. Mailbox is .data at kernel_data_start+128.
// Not last: D7 owns that. No @extern (44 stay 44). No help line.
//
// part of kmain.dart — dcc lowers one library per object.

part of 'kmain.dart';

const int mediaBoxOff = 128;
const int mediaOffMagic = 0;
const int mediaOffFlags = 8;
const int mediaOffLen = 16;
const int mediaOffClip = 64;
const int mediaClipMax = 32768;
const int mediaMagic = 0x4F534D45445F7631;
const int mediaPlay = 1;
const int mediaMiss = 2;

/// `'play'` -- 4 bytes.
@rodata
final List<u8> mediaCmdPlay = const [
  u8(0x70), u8(0x6C), u8(0x61), u8(0x79),
];

/// `'play '` -- 5 bytes.
@rodata
final List<u8> mediaCmdPlaySp = const [
  u8(0x70), u8(0x6C), u8(0x61), u8(0x79), u8(0x20),
];

/// `'CLIP.MP4'` -- 8 bytes.
@rodata
final List<u8> mediaStrClip = const [
  u8(0x43), u8(0x4C), u8(0x49), u8(0x50), u8(0x2E), u8(0x4D), u8(0x50),
  u8(0x34),
];

/// 8.3 `PLAY.ELF` -- 11 bytes. Start spawn of this name kicks play.
@rodata
final List<u8> mediaStrPlay83 = const [
  u8(0x50), u8(0x4C), u8(0x41), u8(0x59), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x45), u8(0x4C), u8(0x46),
];

/// `'OSMEDIA WIN '` -- 12 bytes.
@rodata
final List<u8> mediaStrWin = const [
  u8(0x4F), u8(0x53), u8(0x4D), u8(0x45), u8(0x44), u8(0x49), u8(0x41),
  u8(0x20), u8(0x57), u8(0x49), u8(0x4E), u8(0x20),
];

/// Video window geometry. Same numbers as osmedia.h OSMEDIA_WIN_*.
const int mediaWinX = 200;
const int mediaWinY = 80;
const int mediaWinW = 64;
const int mediaWinH = 64;
const int mediaWinPages = 4;

@bare
u64 mediaBox() {
  return kernel_data_start() + u64(mediaBoxOff);
}

@bare
void mediaKickMiss() {
  final u64 box = mediaBox();
  Pointer<u64>.fromAddress(box + u64(mediaOffMagic)).value = u64(mediaMagic);
  Pointer<u64>.fromAddress(box + u64(mediaOffLen)).value = u64(0);
  Pointer<u64>.fromAddress(box + u64(mediaOffFlags)).value = u64(mediaMiss);
}

@bare
void mediaCopyOpen() {
  final u64 box = mediaBox();
  final u64 dest = box + u64(mediaOffClip);
  u64 left = fatMeta(u64(fatMetaFileBytes));
  u64 s = u64(0);
  u64 o = u64(0);
  if (left > u64(mediaClipMax)) {
    mediaKickMiss();
    return;
  }
  Pointer<u64>.fromAddress(box + u64(mediaOffMagic)).value = u64(mediaMagic);
  Pointer<u64>.fromAddress(box + u64(mediaOffLen)).value = left;
  while (left > u64(0)) {
    final u64 lba = fatFileSector(s);
    if (lba < u64(1)) {
      mediaKickMiss();
      return;
    }
    if (fatReadCached(lba) > u64(0)) {
      mediaKickMiss();
      return;
    }
    u64 k = left;
    if (k > u64(fatSectorBytes)) {
      k = u64(fatSectorBytes);
    }
    u64 i = u64(0);
    while (i < k) {
      Pointer<u8>.fromAddress(dest + o + i).value =
          Pointer<u8>.fromAddress(fatSectorBase() + i).value;
      i = i + u64(1);
    }
    o = o + k;
    left = left - k;
    s = s + u64(1);
  }
  Pointer<u64>.fromAddress(box + u64(mediaOffFlags)).value = u64(mediaPlay);
}

@bare
void shellMediaPlayDefault() {
  // Same mount ls uses so the first `play` is not a cold ATA miss.
  if (fatMount() > u64(fatErrOk)) {
    mediaKickMiss();
    return;
  }
  final u64 pn = fatParseAt(Rodata.addressOf(mediaStrClip), u64(8));
  if (pn > u64(fatErrOk)) {
    mediaKickMiss();
    return;
  }
  final u64 st = fatLookup();
  if (st > u64(fatErrOk)) {
    mediaKickMiss();
    return;
  }
  mediaCopyOpen();
}

@bare
void shellMediaPlay(u64 from) {
  final u64 st = fatOpen(from);
  if (st > u64(fatErrOk)) {
    mediaKickMiss();
    return;
  }
  mediaCopyOpen();
}

/// 1 if fatNameBase holds the 8.3 name PLAY.ELF.
@bare
u64 mediaNameIsPlay() {
  final u64 n = fatNameBase();
  final u64 p = Rodata.addressOf(mediaStrPlay83);
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    if (Pointer<u8>.fromAddress(n + i).value.toU64() !=
        Pointer<u8>.fromAddress(p + i).value.toU64()) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// Next PLAY surface at or after [start], or [wmMaxWindows].
/// Caption 4 is the titled 280×200 PLAY card; 64×64 remains the
/// hidden `play` / kmedia find key.
@bare
u64 wmMediaFindNext(u64 start) {
  u64 i = start;
  while (i < u64(wmMaxWindows)) {
    if (wmWindowUsable(i) > u64(0)) {
      u64 hit = u64(0);
      if (wmPageAddr() > u64(0)) {
        if (wmPage(wmPageLaunchOf(i)) == u64(4)) {
          hit = u64(1);
        }
      }
      if (hit < u64(1)) {
        final u64 g = wmWin(i, u64(wmWinGeom));
        if (wmGeomW(g) == u64(mediaWinW)) {
          if (wmGeomH(g) == u64(mediaWinH)) {
            hit = u64(1);
          }
        }
      }
      if (hit > u64(0)) {
        return i;
      }
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// Allocates [pages] identity-mapped frames into [vec]. 0 on miss.
@bare
u64 wmMediaAllocPages(u64 vec, u64 pages) {
  u64 i = u64(0);
  while (i < pages) {
    final u64 pa = allocFrame();
    if (pa < u64(1)) {
      shmCreateRollback(vec, i);
      return u64(0);
    }
    vmZeroFrame(pa);
    shmFrameMark(pa);
    shmSetVec(vec, i, pa);
    i = i + u64(1);
  }
  return u64(1);
}

/// Kernel shm + window at the video geom. Same records as wmAttach.
@bare
u64 wmMediaCreate() {
  if (wmActive() < u64(1)) {
    return u64(wmMaxWindows);
  }
  if (wmFits(u64(mediaWinX), u64(mediaWinY), u64(mediaWinW), u64(mediaWinH)) <
      u64(1)) {
    return u64(wmMaxWindows);
  }
  final u64 slot = wmFreeWindow();
  if (slot >= u64(wmMaxWindows)) {
    return u64(wmMaxWindows);
  }
  final u64 r = shmRegionFree();
  if (r >= u64(shmMax)) {
    return u64(wmMaxWindows);
  }
  final u64 vec = allocFrame();
  if (vec < u64(1)) {
    return u64(wmMaxWindows);
  }
  vmZeroFrame(vec);
  if (wmMediaAllocPages(vec, u64(mediaWinPages)) < u64(1)) {
    return u64(wmMaxWindows);
  }
  final u64 gen = shmMeta(u64(shmMetaGen)) + u64(1);
  shmSetReg(r, u64(shmRegVec), vec);
  shmSetReg(r, u64(shmRegPages), u64(mediaWinPages));
  shmSetReg(r, u64(shmRegGen), gen);
  shmSetReg(r, u64(shmRegOwner), u64(0));
  shmSetReg(r, u64(shmRegRefs), u64(1));
  shmSetReg(r, u64(shmRegMaps), u64(0));
  shmSetReg(r, u64(shmRegGrants), u64(0));
  shmSetReg(r, u64(shmRegState), u64(shmRegLive));
  shmSetMeta(u64(shmMetaGen), gen);
  shmBumpMeta(u64(shmMetaCreates));
  wmSetWin(slot, u64(wmWinOwner), u64(0));
  wmSetWin(slot, u64(wmWinReg), r);
  wmSetWin(slot, u64(wmWinGen), gen);
  wmSetWin(slot, u64(wmWinGeom),
      wmPackGeom(u64(mediaWinX), u64(mediaWinY), u64(mediaWinW),
          u64(mediaWinH)));
  wmSetWin(slot, u64(wmWinStride), u64(mediaWinW) << u64(2));
  wmSetWin(slot, u64(wmWinOffsetW), u64(0));
  wmSetWin(slot, u64(wmWinSeq), u64(0));
  wmSetWin(slot, u64(wmWinState), u64(wmWinLive));
  wmSetMeta(u64(wmMetaTop), slot);
  wmSetMeta(u64(wmMetaLive), wmMeta(u64(wmMetaLive)) + u64(1));
  wmBumpMeta(u64(wmMetaAttaches));
  uartWrite(Rodata.addressOf(wmStrAttach), u64(12));
  uartPutHex(slot, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(r, u64(1));
  uartWrite(Rodata.addressOf(wmStrGen), u64(5));
  uartPutHex(gen, u64(8));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(u64(mediaWinX), u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(u64(mediaWinY), u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(u64(mediaWinW), u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(u64(mediaWinH), u64(4));
  uartWrite(Rodata.addressOf(wmStrVa), u64(4));
  uartPutHex(shmRegionVa(r), u64(16));
  uartNewline();
  return slot;
}

/// One row of decoder RGB into window [slot]'s frame vector.
@bare
void wmMediaBlitRow(u64 src, u64 w, u64 vec, u64 stride, u64 py, u64 dx, u64 dy) {
  u64 i = u64(0);
  while (i < w) {
    final u64 pix =
        Pointer<u32>.fromAddress(src + ((py * w + i) * u64(4))).value.toU64();
    final u64 off = ((dy + py) * stride) + ((dx + i) << u64(2));
    final u64 phys = shmVec(vec, off >> u64(vmPageShift));
    Pointer<u32>.fromAddress(phys + (off & u64(vmPageMask))).value = pix.toU32();
    i = i + u64(1);
  }
}

/// Copies [src] into window [slot] and composes it.
@bare
void wmMediaBlitSlot(u64 src, u64 slot) {
  final u64 r = wmWin(slot, u64(wmWinReg));
  final u64 vec = shmReg(r, u64(shmRegVec));
  final u64 stride = wmWin(slot, u64(wmWinStride)) & u64(0xFFFFFFFF);
  final u64 g = wmWin(slot, u64(wmWinGeom));
  u64 dx = u64(0);
  u64 dy = u64(0);
  if (wmGeomW(g) > u64(mediaWinW)) {
    dx = u64(16);
  }
  if (wmGeomH(g) > u64(mediaWinH)) {
    dy = u64(40);
  }
  u64 py = u64(0);
  while (py < u64(mediaWinH)) {
    wmMediaBlitRow(src, u64(mediaWinW), vec, stride, py, dx, dy);
    py = py + u64(1);
  }
  wmBumpMeta(u64(wmMetaCommits));
  wmComposeCommit(slot, u64(1), u64(0), u64(0), u64(0), u64(0));
}

/// C-callable. Find or attach a 64×64 shm window, blit [src], commit.
/// No dest (`wm` off) skips — that is the no-attach miss.
@bare
void wmMediaFill(u64 src, u64 w, u64 h) {
  if (wmActive() < u64(1)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  if (src < u64(1)) {
    return;
  }
  if (w != u64(mediaWinW)) {
    return;
  }
  if (h != u64(mediaWinH)) {
    return;
  }
  u64 i = u64(0);
  u64 n = u64(0);
  while (i < u64(wmMaxWindows)) {
    final u64 slot = wmMediaFindNext(i);
    if (slot >= u64(wmMaxWindows)) {
      i = u64(wmMaxWindows);
    } else {
      wmMediaBlitSlot(src, slot);
      n = n + u64(1);
      i = slot + u64(1);
    }
  }
  if (n < u64(1)) {
    final u64 slot = wmMediaCreate();
    if (slot < u64(wmMaxWindows)) {
      wmMediaBlitSlot(src, slot);
      n = u64(1);
    }
  }
  if (n < u64(1)) {
    return;
  }
  uartWrite(Rodata.addressOf(mediaStrWin), u64(12));
  uartPutHex(n, u64(1));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(u64(mediaWinX), u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(u64(mediaWinY), u64(4));
  uartNewline();
}
