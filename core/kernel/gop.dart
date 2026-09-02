// core/kernel/gop.dart
//
// PORT2 (ADR-0060 probe, ADR-0061 map+paint) plus the scanout
// fallback (ADR-0064) plus the session on that aperture (ADR-0141):
// read a Multiboot1 framebuffer tag the loader filled from UEFI GOP,
// identity-map that aperture with 2MiB leaves in the LIVE tables, and
// paint. A tag that cannot be mapped returns 0 -- no store, no
// `FB GOP` line -- so `shellFb` falls through to Bochs or `FB NONE`.
// Session chrome (`wm on` / `wm chrome`) composes through [fbGeomWidth]
// / [fbGeomHeight], which trust GOP geometry only while [gopIsLive].
// Unmapped GOP is not a session: compose never stores there.
// No donated .bss -- the four numbers are locals, the page directory
// is one `allocFrame` taken only when a GOP tag exists AND the map
// succeeds. Not last: D7 owns `wmeventStore`.
//
// This is NOT a GPU driver. It does not talk to amdgpu, i915, or
// nouveau. It does not program a mode. Firmware already did that; the
// loader named the aperture. Linux calls the same early path efifb.
//
// Discovery is Multiboot1 info flags bit 12 (offset 88 and following).
// QEMU's `-kernel` loader does not set that bit -- measured, ADR-0060 --
// so the existing Bochs path in fb.dart stays the `-kernel` / sit-in
// path. A hang or a #PF on a missing or unmappable tag is a bug; the
// caller treats 0 as "no GOP" and continues. The map is isolated here
// so vm.dart goldens (which boot `-kernel` and never take this path)
// do not move.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Multiboot1 framebuffer fields (spec offsets), valid if flags bit 12.
//
//   +88  framebuffer_addr    u64
//   +96  framebuffer_pitch   u32
//   +100 framebuffer_width   u32
//   +104 framebuffer_height  u32
//   +108 framebuffer_bpp     u8
//   +109 framebuffer_type    u8   1 = RGB
// ---------------------------------------------------------------------------

const int mbFbFlagBit = 0x1000;
const int mbFbAddrOff = 88;
const int mbFbPitchOff = 96;
const int mbFbWidthOff = 100;
const int mbFbHeightOff = 104;
const int mbFbBppOff = 108;
const int mbFbTypeOff = 109;
const int mbFbTypeRgb = 1;

/// `"FB GOP "` -- 7 bytes.
@rodata
final List<u8> gopStrTag = const [
  u8(0x46), u8(0x42), u8(0x20), u8(0x47), u8(0x4F), u8(0x50), u8(0x20),
];

/// `"WM GOP "` -- 7 bytes. Session compose on the live GOP aperture
/// (ADR-0141). Not a help line. Printed only after [wmCompose] when
/// [gopIsLive] is 1.
@rodata
final List<u8> gopStrSess = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x47), u8(0x4F), u8(0x50), u8(0x20),
];

/// 1 if the Multiboot1 information structure at [info] carries a
/// framebuffer tag (flags bit 12). 0 if [info] is unusable or the bit
/// is clear. Does not print. Does not touch a device.
@bare
u64 gopHasTag(u64 info) {
  if ((info & u64(3)) > u64(0)) {
    return u64(0);
  }
  if (info < u64(1)) {
    return u64(0);
  }
  final u64 flags = mbU32(info);
  if ((flags & u64(mbFbFlagBit)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}

/// The Multiboot1 info pointer `shellInit` stashed, or 0.
@bare
u64 gopInfo() {
  return Pointer<u64>.fromAddress(shell_mbinfo_addr()).value;
}

/// Physical address from the framebuffer tag at [info]. Caller has
/// already established [gopHasTag]. One return: the two u32 halves
/// concatenated. Does not map. Does not print.
@bare
u64 gopTagAddr(u64 info) {
  final u64 addrLo = mbU32(info + u64(mbFbAddrOff));
  final u64 addrHi = mbU32(info + u64(mbFbAddrOff) + u64(4));
  return addrLo + (addrHi << u64(32));
}

/// 1 if the live [fbState] base is the mapped GOP aperture. 0 if the
/// tag is absent, the base is zero, or a Bochs/NONE win left the tag
/// behind (ADR-0064). Does not print. Does not map.
@bare
u64 gopIsLive() {
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return u64(0);
  }
  final u64 info = gopInfo();
  if (gopHasTag(info) < u64(1)) {
    return u64(0);
  }
  if (fbState(u64(fbStateBase)) != gopTagAddr(info)) {
    return u64(0);
  }
  return u64(1);
}

/// Serial `WM GOP <w>x<h> <addr>` after a session compose that actually
/// targeted the mapped GOP aperture. No-op when GOP is not live -- an
/// unmapped tag must not claim the session (ADR-0141).
@bare
void gopSessAnnounce() {
  if (gopIsLive() < u64(1)) {
    return;
  }
  final u64 info = gopInfo();
  uartWrite(Rodata.addressOf(gopStrSess), u64(7));
  uartPutHex(fbGeomWidth(), u64(4));
  uartWrite(Rodata.addressOf(fbStrBy), u64(1));
  uartPutHex(fbGeomHeight(), u64(4));
  uartSpace();
  uartPutHex(gopTagAddr(info), u64(16));
  uartNewline();
}

/// Marker colour from the loader's geometry, not a compiled-in mode.
/// R = width>>4, G = height>>4, B = 0xA5. The harness recomputes the
/// same three bits from the resolution it wrote into limine.conf.
@bare
u64 gopMarkColor(u64 width, u64 height) {
  return ((width >> u64(4)) << u64(16)) |
      ((height >> u64(4)) << u64(8)) |
      u64(0xA5);
}

/// Origin of the 16x16 marker: 32 pixels in from the bottom-right.
/// Chosen so a GOP larger than the compiled-in 800x600 Bochs rectangle
/// paints outside it -- a fill that still used fbWidth/fbHeight would
/// miss the mark.
@bare
u64 gopMarkOrigin(u64 extent) {
  return extent - u64(32);
}

/// Page-directory physical address for PDPT slot [pdptIdx], allocating
/// and zeroing one frame if that slot is empty. Returns 0 if the walk
/// cannot proceed, if the slot is a 1GiB leaf, or if the allocator is
/// empty. Does not touch PDPT[0] (the low gigabyte vm.dart owns) or
/// PDPT[3] (the PCI hole).
@bare
u64 gopEnsurePd(u64 pdptIdx) {
  u64 pd = u64(0);
  if (pdptIdx < u64(1)) {
    return pd;
  }
  if (pdptIdx > u64(2)) {
    return pd;
  }
  final u64 pml4 = vmEntryAddr(cr3_read());
  final u64 e4 = vmGetEntry(pml4, u64(0));
  if ((e4 & u64(vmPresent)) < u64(1)) {
    return pd;
  }
  final u64 pdpt = vmEntryAddr(e4);
  final u64 e3 = vmGetEntry(pdpt, pdptIdx);
  if ((e3 & u64(vmPresent)) > u64(0)) {
    if ((e3 & u64(vmHuge)) > u64(0)) {
      return pd;
    }
    pd = vmEntryAddr(e3);
    return pd;
  }
  pd = allocFrame();
  if (pd < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(pd);
  vmSetEntry(pdpt, pdptIdx, pd | u64(vmPresent) | u64(vmWritable) | vmNxBit());
  return pd;
}

/// Identity-map [addr, addr+nbytes) with 2MiB present+writable+NX leaves
/// in the LIVE tables. Returns how many leaf entries were written, or 1
/// if the range was already present, or 0 on refusal.
///
/// Already-mapped ranges (the 0-128MiB identity window, the 3-4GiB PCI
/// hole) are left alone. A GOP at 0x80000000 needs PDPT[2] plus two
/// 2MiB leaves -- three page-table writes, none of them in vm.dart.
@bare
u64 gopMap(u64 addr, u64 nbytes) {
  u64 wrote = u64(0);
  if (addr < u64(1)) {
    return wrote;
  }
  if (nbytes < u64(1)) {
    return wrote;
  }
  if (addr >= u64(vmPciBase)) {
    if (addr < u64(vmPciEnd)) {
      wrote = u64(1);
      return wrote;
    }
  }
  if (addr < u64(vmMapBytes)) {
    wrote = u64(1);
    return wrote;
  }
  final u64 pml4 = vmEntryAddr(cr3_read());
  if ((vmWalk(pml4, addr) & u64(vmPresent)) > u64(0)) {
    wrote = u64(1);
    return wrote;
  }
  final u64 mask = u64(vmBigBytes) - u64(1);
  final u64 start = addr - (addr & mask);
  final u64 raw = addr + nbytes;
  final u64 frac = raw & mask;
  u64 end = raw;
  if (frac > u64(0)) {
    end = raw - frac + u64(vmBigBytes);
  }
  if (end <= start) {
    return wrote;
  }
  if ((start >> u64(30)) != ((end - u64(1)) >> u64(30))) {
    return wrote;
  }
  final u64 pdptIdx = (start >> u64(30)) & u64(511);
  final u64 pd = gopEnsurePd(pdptIdx);
  if (pd < u64(1)) {
    return wrote;
  }
  final u64 nx = vmNxBit();
  final u64 bits = u64(vmPresent) | u64(vmWritable) | u64(vmHuge) | nx;
  u64 va = start;
  while (va < end) {
    final u64 idx = (va >> u64(vmBigShift)) & u64(511);
    vmSetEntry(pd, idx, va | bits);
    tlb_invlpg(va);
    wrote = wrote + u64(1);
    va = va + u64(vmBigBytes);
  }
  return wrote;
}

/// Paints a 16x16 marker at the derived origin in the GOP aperture.
/// [fbState] must already name that aperture. One while, calling
/// [fbFillRow] -- nested loops are rejected (GAP-0068).
@bare
void gopPaintMark(u64 x, u64 y, u64 color) {
  u64 i = u64(0);
  while (i < u64(16)) {
    fbFillRow(x, y + i, u64(16), color);
    i = i + u64(1);
  }
}

/// If the loader handed a GOP framebuffer AND this kernel can
/// identity-map that aperture, publish it through [fbState], paint one
/// derived rectangle, print `FB GOP <width>x<height> <pitch> <addr>`
/// (all hex) and return 1. Otherwise return 0 and print nothing -- the
/// caller takes Bochs or `FB NONE`.
///
/// Width, height, pitch, addr are read from the Multiboot1 tag, not
/// from Bochs dispi and not from a compiled-in 800x600. A zero width,
/// height, or address is treated as "no GOP" rather than painted, so a
/// malformed tag cannot take the PORT2 path by accident.
///
/// **A tag that cannot be mapped is not GOP.** [gopMap] returning 0
/// means this kernel has no leaf it is willing to write for that
/// range. Claiming the path anyway would either page-fault on the
/// first store or lie with `FB GOP` and skip Bochs. ADR-0064: return
/// 0, print nothing, leave [fbState] at zero.
///
/// Does not write ports `0x1CE`/`0x1CF`. Does not walk PCI. Does not
/// donate storage. The map runs only when this tag is present.
@bare
u64 gopTry() {
  final u64 info = gopInfo();
  if (gopHasTag(info) < u64(1)) {
    return u64(0);
  }

  final u64 addr = gopTagAddr(info);
  final u64 pitch = mbU32(info + u64(mbFbPitchOff));
  final u64 width = mbU32(info + u64(mbFbWidthOff));
  final u64 height = mbU32(info + u64(mbFbHeightOff));
  final u64 bpp = Pointer<u8>.fromAddress(info + u64(mbFbBppOff)).value.toU64();
  final u64 fbType = Pointer<u8>.fromAddress(info + u64(mbFbTypeOff)).value.toU64();

  if (addr < u64(1)) {
    return u64(0);
  }
  if (width < u64(32)) {
    return u64(0);
  }
  if (height < u64(32)) {
    return u64(0);
  }
  if (pitch < (width * u64(fbBytesPerPixel))) {
    return u64(0);
  }
  if (fbType < u64(mbFbTypeRgb)) {
    return u64(0);
  }
  if (fbType > u64(mbFbTypeRgb)) {
    return u64(0);
  }
  if (bpp < u64(1)) {
    return u64(0);
  }

  final u64 bytes = height * pitch;
  if (gopMap(addr, bytes) < u64(1)) {
    return u64(0);
  }

  fbSetState(u64(fbStateBase), addr);
  fbSetState(u64(fbStatePitch), pitch);
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
  gopPaintMark(gopMarkOrigin(width), gopMarkOrigin(height),
      gopMarkColor(width, height));

  uartWrite(Rodata.addressOf(gopStrTag), u64(7));
  uartPutHex(width, u64(4));
  uartWrite(Rodata.addressOf(fbStrBy), u64(1));
  uartPutHex(height, u64(4));
  uartSpace();
  uartPutHex(pitch, u64(8));
  uartSpace();
  uartPutHex(addr, u64(16));
  uartNewline();
  return u64(1);
}
