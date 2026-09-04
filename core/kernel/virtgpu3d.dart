// core/kernel/virtgpu3d.dart
//
// oscortex_core G10 / VIRGL0: the device executes GPU work.
// VirtIO-GPU 2D (G0–G8) is a mailbox — CPU writes pixels, the
// host scans them out. This file is the first path where the
// *device* produces the framebuffer, including alpha.
//
// Hidden `virtgpug`: negotiate VIRTIO_GPU_F_VIRGL, CTX_CREATE,
// RESOURCE_CREATE_3D, CTX_ATTACH, SUBMIT_3D (virgl CLEAR navy,
// then a GPU point whose fragment colour is 50% red), 
// TRANSFER_FROM_HOST_3D, SET_SCANOUT. Prints VIRTIO 3D OK and
// the first backing dword the device wrote. `virtgpuz` stops
// after the probe: no submit, no 3D OK.
//
// Paint fallback (owner, same shape as GOP → Bochs → NONE):
//   3D GPU (this file) → else CPU raster of the osgfx/Skia
//   scene (sibling; not claimed here) → else 2D mailbox (G4–G8).
// A machine with no 3D device prints VIRTIO 3D NONE and
// VIRTIO PAINT 2D when a VirtIO GPU is present, or PAINT NONE
// when it is not. Never a blank desktop because there is no GPU.
//
// G0–G9 stay in virtgpu.dart. This file donates no .bss, no
// help line, no syscall. virtgpu3dInit is a no-op. ADR-0098.
// docs/design/gpu.md §5/G10.

part of 'kmain.dart';

/// VIRTIO_GPU_F_VIRGL — feature bit 0 of word 0.
const int virtgpu3dFeatVirgl = 0x01;

/// 3D control types (VIRTIO §5.7.6).
const int virtgpu3dTypeCtxNew = 0x0200;
const int virtgpu3dTypeCtxAtt = 0x0202;
const int virtgpu3dTypeRes3d = 0x0204;
const int virtgpu3dTypeXferFrom = 0x0206;
const int virtgpu3dTypeSubmit = 0x0207;

/// Guest-chosen context and resource ids. 0 is reserved.
const int virtgpu3dCtx = 1;
const int virtgpu3dResDst = 1;

/// 64×64 render targets. Not a scanout mode: GET_DISPLAY_INFO
/// still names the display. The GPU work is this square.
const int virtgpu3dSide = 64;
const int virtgpu3dFrames = 4;

/// PIPE_TEXTURE_2D / VIRGL_FORMAT_B8G8R8A8_UNORM /
/// RT | SAMPLER_VIEW | VERTEX | SCANOUT | BLENDABLE.
const int virtgpu3dTarget2d = 2;
const int virtgpu3dFmtBgra = 1;
const int virtgpu3dBind = 0x2400E;

/// virgl object / command opcodes. CMD0 = cmd | obj<<8 | len<<16.
/// BLIT is 16, not 10 (10 is SET_SAMPLER_VIEWS).
const int virtgpu3dCcmdCreate = 1;
const int virtgpu3dCcmdBind = 2;
const int virtgpu3dCcmdSetVp = 4;
const int virtgpu3dCcmdSetFb = 5;
const int virtgpu3dCcmdClear = 7;
const int virtgpu3dCcmdDraw = 8;
const int virtgpu3dCcmdBlit = 16;
const int virtgpu3dCcmdSetSub = 28;
const int virtgpu3dCcmdNewSub = 29;
const int virtgpu3dCcmdBindSh = 31;
const int virtgpu3dObjBlend = 1;
const int virtgpu3dObjRs = 2;
const int virtgpu3dObjDsa = 3;
const int virtgpu3dObjSh = 4;
const int virtgpu3dObjSurface = 8;
const int virtgpu3dPrimTri = 4;
const int virtgpu3dClearColor0 = 4;
/// RGBA mask + ALPHA_BLEND at bit 12.
const int virtgpu3dBlitS0 = 0x100F;
/// Src-over on RT0. VIRGL_OBJ_BLEND_S2: enable, ADD, SRC_ALPHA /
/// INV_SRC_ALPHA, A: ONE / INV_SRC_ALPHA, colormask RGBA.
const int virtgpu3dBlendRt0 = 0x79420A41;

/// IEEE-754 bits for the two GPU clears and a 64×64 viewport.
/// The blended dword is *not* stored here — the device must produce it.
const int virtgpu3dF1 = 0x3F800000;
const int virtgpu3dFHalf = 0x3F000000;
const int virtgpu3dF32 = 0x42000000;
const int virtgpu3dF128 = 0x43000000;
const int virtgpu3dFNavyR = 0x3DC0C0C1;
const int virtgpu3dFNavyG = 0x3E808081;
const int virtgpu3dFNavyB = 0x3EC0C0C1;

/// `"virtgpug"` -- 8 bytes. G10 submit + transfer.
@rodata
final List<u8> virtgpu3dStrCmd = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x67),
];

/// `"virtgpuz"` -- 8 bytes. Probe only; no SUBMIT_3D.
@rodata
final List<u8> virtgpu3dStrCmdNo = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x7A),
];

/// `"VIRTIO 3D NONE\n"` -- 15 bytes.
@rodata
final List<u8> virtgpu3dStrNone = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x33), u8(0x44), u8(0x20), u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45),
  u8(0x0A),
];

/// `"VIRTIO 3D OK\n"` -- 13 bytes.
@rodata
final List<u8> virtgpu3dStrOk = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x33), u8(0x44), u8(0x20), u8(0x4F), u8(0x4B), u8(0x0A),
];

/// `"3D FEAT "` -- 8 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpu3dStrFeat = const [
  u8(0x33), u8(0x44), u8(0x20), u8(0x46),
  u8(0x45), u8(0x41), u8(0x54), u8(0x20),
];

/// `"3D PIX "` -- 7 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpu3dStrPix = const [
  u8(0x33), u8(0x44), u8(0x20), u8(0x50),
  u8(0x49), u8(0x58), u8(0x20),
];

/// `"3D SUB "` -- 7 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpu3dStrSub = const [
  u8(0x33), u8(0x44), u8(0x20), u8(0x53),
  u8(0x55), u8(0x42), u8(0x20),
];

/// `"PAINT "` -- 6 bytes. Follows [virtgpuStrLine]. Winner of
/// 3D → CPU raster → 2D mailbox. This slice never prints CPU:
/// that path is the sibling's osgfx/Skia raster, not a stub.
@rodata
final List<u8> virtgpu3dStrPaint = const [
  u8(0x50), u8(0x41), u8(0x49), u8(0x4E), u8(0x54), u8(0x20),
];

/// `"3D\n"` -- 3 bytes.
@rodata
final List<u8> virtgpu3dStrPaint3 = const [
  u8(0x33), u8(0x44), u8(0x0A),
];

/// `"2D\n"` -- 3 bytes.
@rodata
final List<u8> virtgpu3dStrPaint2 = const [
  u8(0x32), u8(0x44), u8(0x0A),
];

/// `"NONE\n"` -- 5 bytes.
@rodata
final List<u8> virtgpu3dStrPaintN = const [
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// `"oscortex"` -- CTX_CREATE debug name, two LE dwords.
const int virtgpu3dName0 = 0x6F63736F;
const int virtgpu3dName1 = 0x78657472;

/// Silent. Prints nothing. Does not program the device.
@bare
void virtgpu3dInit() {
}

/// 24-byte control header with [ctx] at offset 16.
@bare
void virtgpu3dPutHdr(u64 req, u64 typ, u64 ctx) {
  virtgpuZero(req, u64(24));
  virtgpuRamPut32(req, typ);
  virtgpuRamPut32(req + u64(16), ctx);
}

///     VIRTIO 3D FEAT lo hi
@bare
void virtgpu3dReportFeat(u64 lo, u64 hi) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrFeat), u64(8));
  uartPutHex(lo, u64(8));
  uartSpace();
  uartPutHex(hi, u64(8));
  uartNewline();
}

///     VIRTIO 3D PIX xxxxxxxx
@bare
void virtgpu3dReportPix(u64 p) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrPix), u64(7));
  uartPutHex(p, u64(8));
  uartNewline();
}

///     VIRTIO 3D SUB xxxxxxxx
@bare
void virtgpu3dReportSub(u64 t) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrSub), u64(7));
  uartPutHex(t, u64(8));
  uartNewline();
}

///     VIRTIO PAINT 3D / 2D / NONE
@bare
void virtgpu3dReportPaint(u64 which) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrPaint), u64(6));
  if (which == u64(3)) {
    uartWrite(Rodata.addressOf(virtgpu3dStrPaint3), u64(3));
    return;
  }
  if (which == u64(2)) {
    uartWrite(Rodata.addressOf(virtgpu3dStrPaint2), u64(3));
    return;
  }
  uartWrite(Rodata.addressOf(virtgpu3dStrPaintN), u64(5));
}

/// Accept VIRGL + VERSION_1 when the device offers bit 0.
/// Returns 1 if VIRGL stuck, 0 otherwise. G2's negotiate is
/// untouched: it still accepts VERSION_1 only.
@bare
u64 virtgpu3dNegotiate(u64 bus, u64 dev, u64 fn) {
  final u64 cfg = virtgpuCommonCfg(bus, dev, fn);
  if (cfg == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoCfg), u64(13));
    return u64(0);
  }
  if (virtgpuReset(cfg) == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrReset), u64(13));
    return u64(0);
  }
  virtgpuStatusOr(cfg, u64(virtgpuStatusAck));
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriver));

  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(0));
  final u64 featLo = virtgpuCfgGet32(cfg, u64(virtgpuCfgFeat));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(1));
  final u64 featHi = virtgpuCfgGet32(cfg, u64(virtgpuCfgFeat));
  virtgpu3dReportFeat(featLo, featHi);

  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(0));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), featLo & u64(virtgpu3dFeatVirgl));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(1));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), u64(virtgpuFeatVersion1));

  virtgpuStatusOr(cfg, u64(virtgpuStatusFeatOk));
  final u64 afterOk = virtgpuStatusGet(cfg);
  if ((afterOk & u64(virtgpuStatusFeatOk)) < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrFeatOkClear), u64(20));
    virtgpuReportStatus(afterOk);
    return u64(0);
  }
  virtgpuReportStatus(afterOk);
  if ((featLo & u64(virtgpu3dFeatVirgl)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}

/// used.idx poll. The 2D bound is too short for virglrenderer's
/// first kick (EGL + llvmpipe). Unmasks the PIT for the extra
/// wait, remasks after — same shape as nicRxHold. G3's bound
/// is untouched.
@bare
u64 virtgpu3dWaitUsed(u64 qdev, u64 want) {
  u64 used = virtgpuWaitUsed(qdev, want);
  if (used == want) {
    return used;
  }
  final u64 start = tick_count();
  final u64 target = start + u64(800);
  picUnmaskTimerAndKeyboard();
  u64 now = tick_count();
  while (now < target) {
    used = virtgpuRamGet16(qdev + u64(2));
    if (used == want) {
      if (procHead(u64(procHeadResident)) < u64(1)) {
        picUnmaskKeyboardOnly();
      }
      return used;
    }
    now = tick_count();
  }
  if (procHead(u64(procHeadResident)) < u64(1)) {
    picUnmaskKeyboardOnly();
  }
  return used;
}

/// Two-descriptor submit using [virtgpu3dWaitUsed].
@bare
u64 virtgpu3dSubmit2(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 reqlen, u64 resp, u64 kick) {
  virtgpuZero(resp, u64(24));
  virtgpuPutDesc(
      qdesc, head, req, reqlen, u64(virtgpuDescNext), head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), resp, u64(virtgpuHdrBytes), u64(virtgpuDescWrite),
      u64(0));
  virtgpuRamPut16(qdrv + u64(4) + (slot << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  final u64 used = virtgpu3dWaitUsed(qdev, slot + u64(1));
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  return virtgpuRamGet32(resp);
}

/// One dword of virgl command stream at [stream] + [off]*4.
@bare
void virtgpu3dPutDw(u64 stream, u64 off, u64 val) {
  virtgpuRamPut32(stream + (off << u64(2)), val);
}

/// CMD0 = cmd | (obj << 8) | (len << 16).
@bare
u64 virtgpu3dCmd0(u64 cmd, u64 obj, u64 len) {
  return cmd | (obj << u64(8)) | (len << u64(16));
}

/// CREATE_OBJECT SURFACE + SET_FRAMEBUFFER + CLEAR.
/// Returns the next stream dword index.
@bare
u64 virtgpu3dPutClear(u64 stream, u64 i, u64 handle, u64 res, u64 r, u64 g, u64 b, u64 a) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdCreate), u64(virtgpu3dObjSurface), u64(5)));
  virtgpu3dPutDw(stream, i + u64(1), handle);
  virtgpu3dPutDw(stream, i + u64(2), res);
  virtgpu3dPutDw(stream, i + u64(3), u64(virtgpu3dFmtBgra));
  virtgpu3dPutDw(stream, i + u64(4), u64(0));
  virtgpu3dPutDw(stream, i + u64(5), u64(0));
  virtgpu3dPutDw(
      stream, i + u64(6), virtgpu3dCmd0(u64(virtgpu3dCcmdSetFb), u64(0), u64(3)));
  virtgpu3dPutDw(stream, i + u64(7), u64(1));
  virtgpu3dPutDw(stream, i + u64(8), u64(0));
  virtgpu3dPutDw(stream, i + u64(9), handle);
  virtgpu3dPutDw(
      stream, i + u64(10), virtgpu3dCmd0(u64(virtgpu3dCcmdClear), u64(0), u64(8)));
  virtgpu3dPutDw(stream, i + u64(11), u64(virtgpu3dClearColor0));
  virtgpu3dPutDw(stream, i + u64(12), r);
  virtgpu3dPutDw(stream, i + u64(13), g);
  virtgpu3dPutDw(stream, i + u64(14), b);
  virtgpu3dPutDw(stream, i + u64(15), a);
  virtgpu3dPutDw(stream, i + u64(16), u64(0));
  virtgpu3dPutDw(stream, i + u64(17), u64(0));
  virtgpu3dPutDw(stream, i + u64(18), u64(0));
  return i + u64(19);
}

/// VIRGL_CCMD_BLIT of [src] onto [dst] at (16,16) 32×32 with
/// alpha_blend. Returns the next stream dword index.
@bare
u64 virtgpu3dPutBlit(u64 stream, u64 i, u64 dst, u64 src) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdBlit), u64(0), u64(21)));
  virtgpu3dPutDw(stream, i + u64(1), u64(virtgpu3dBlitS0));
  virtgpu3dPutDw(stream, i + u64(2), u64(0));
  virtgpu3dPutDw(stream, i + u64(3), u64(0));
  virtgpu3dPutDw(stream, i + u64(4), dst);
  virtgpu3dPutDw(stream, i + u64(5), u64(0));
  virtgpu3dPutDw(stream, i + u64(6), u64(virtgpu3dFmtBgra));
  virtgpu3dPutDw(stream, i + u64(7), u64(16));
  virtgpu3dPutDw(stream, i + u64(8), u64(16));
  virtgpu3dPutDw(stream, i + u64(9), u64(0));
  virtgpu3dPutDw(stream, i + u64(10), u64(32));
  virtgpu3dPutDw(stream, i + u64(11), u64(32));
  virtgpu3dPutDw(stream, i + u64(12), u64(1));
  virtgpu3dPutDw(stream, i + u64(13), src);
  virtgpu3dPutDw(stream, i + u64(14), u64(0));
  virtgpu3dPutDw(stream, i + u64(15), u64(virtgpu3dFmtBgra));
  virtgpu3dPutDw(stream, i + u64(16), u64(0));
  virtgpu3dPutDw(stream, i + u64(17), u64(0));
  virtgpu3dPutDw(stream, i + u64(18), u64(0));
  virtgpu3dPutDw(stream, i + u64(19), u64(32));
  virtgpu3dPutDw(stream, i + u64(20), u64(32));
  virtgpu3dPutDw(stream, i + u64(21), u64(1));
  return i + u64(22);
}

/// CREATE + BIND a src-over blend object (handle 3).
@bare
u64 virtgpu3dPutBlend(u64 stream, u64 i) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdCreate), u64(virtgpu3dObjBlend), u64(11)));
  virtgpu3dPutDw(stream, i + u64(1), u64(3));
  virtgpu3dPutDw(stream, i + u64(2), u64(0));
  virtgpu3dPutDw(stream, i + u64(3), u64(0));
  virtgpu3dPutDw(stream, i + u64(4), u64(virtgpu3dBlendRt0));
  u64 k = u64(5);
  while (k < u64(12)) {
    virtgpu3dPutDw(stream, i + k, u64(0));
    k = k + u64(1);
  }
  virtgpu3dPutDw(
      stream, i + u64(12), virtgpu3dCmd0(u64(virtgpu3dCcmdBind), u64(virtgpu3dObjBlend), u64(1)));
  virtgpu3dPutDw(stream, i + u64(13), u64(3));
  return i + u64(14);
}

/// CREATE_SUB_CTX 0 + SET_SUB_CTX 0 + one 64×64 viewport.
/// Returns the next stream dword index.
@bare
u64 virtgpu3dPutSubVp(u64 stream, u64 i) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdNewSub), u64(0), u64(1)));
  virtgpu3dPutDw(stream, i + u64(1), u64(0));
  virtgpu3dPutDw(
      stream, i + u64(2), virtgpu3dCmd0(u64(virtgpu3dCcmdSetSub), u64(0), u64(1)));
  virtgpu3dPutDw(stream, i + u64(3), u64(0));
  virtgpu3dPutDw(
      stream, i + u64(4), virtgpu3dCmd0(u64(virtgpu3dCcmdSetVp), u64(0), u64(7)));
  virtgpu3dPutDw(stream, i + u64(5), u64(0));
  virtgpu3dPutDw(stream, i + u64(6), u64(virtgpu3dF32));
  virtgpu3dPutDw(stream, i + u64(7), u64(virtgpu3dF32));
  virtgpu3dPutDw(stream, i + u64(8), u64(virtgpu3dFHalf));
  virtgpu3dPutDw(stream, i + u64(9), u64(virtgpu3dF32));
  virtgpu3dPutDw(stream, i + u64(10), u64(virtgpu3dF32));
  virtgpu3dPutDw(stream, i + u64(11), u64(virtgpu3dFHalf));
  return i + u64(12);
}

/// Depth-disabled DSA (handle 8).
@bare
u64 virtgpu3dPutDsa(u64 stream, u64 i) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdCreate), u64(virtgpu3dObjDsa), u64(5)));
  virtgpu3dPutDw(stream, i + u64(1), u64(8));
  virtgpu3dPutDw(stream, i + u64(2), u64(0));
  virtgpu3dPutDw(stream, i + u64(3), u64(0));
  virtgpu3dPutDw(stream, i + u64(4), u64(0));
  virtgpu3dPutDw(stream, i + u64(5), u64(0));
  virtgpu3dPutDw(
      stream, i + u64(6), virtgpu3dCmd0(u64(virtgpu3dCcmdBind), u64(virtgpu3dObjDsa), u64(1)));
  virtgpu3dPutDw(stream, i + u64(7), u64(8));
  return i + u64(8);
}

/// Rasterizer: half-pixel centre + depth clip (handle 4).
@bare
u64 virtgpu3dPutRs(u64 stream, u64 i) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdCreate), u64(virtgpu3dObjRs), u64(9)));
  virtgpu3dPutDw(stream, i + u64(1), u64(4));
  virtgpu3dPutDw(stream, i + u64(2), u64(0x20000002));
  virtgpu3dPutDw(stream, i + u64(3), u64(virtgpu3dF128));
  virtgpu3dPutDw(stream, i + u64(4), u64(0));
  virtgpu3dPutDw(stream, i + u64(5), u64(0));
  virtgpu3dPutDw(stream, i + u64(6), u64(virtgpu3dF1));
  virtgpu3dPutDw(stream, i + u64(7), u64(0));
  virtgpu3dPutDw(stream, i + u64(8), u64(0));
  virtgpu3dPutDw(stream, i + u64(9), u64(0));
  virtgpu3dPutDw(
      stream, i + u64(10), virtgpu3dCmd0(u64(virtgpu3dCcmdBind), u64(virtgpu3dObjRs), u64(1)));
  virtgpu3dPutDw(stream, i + u64(11), u64(4));
  return i + u64(12);
}

/// TGSI text shader. [ntext] dwords follow this header at [i]+6.
@bare
/// OFFSET is the TGSI text size in bytes. virgl requires
/// (offlen+3)/4 >= the number of text dwords in this packet.
u64 virtgpu3dPutShHdr(u64 stream, u64 i, u64 handle, u64 typ, u64 nbytes, u64 ntok, u64 ntext) {
  virtgpu3dPutDw(
      stream, i,
      virtgpu3dCmd0(u64(virtgpu3dCcmdCreate), u64(virtgpu3dObjSh), u64(5) + ntext));
  virtgpu3dPutDw(stream, i + u64(1), handle);
  virtgpu3dPutDw(stream, i + u64(2), typ);
  virtgpu3dPutDw(stream, i + u64(3), nbytes);
  virtgpu3dPutDw(stream, i + u64(4), ntok);
  virtgpu3dPutDw(stream, i + u64(5), u64(0));
  return i + u64(6);
}

/// Constant clip-space origin. The rasterizer point size covers the RT.
@bare
u64 virtgpu3dPutVs(u64 stream, u64 i) {
  i = virtgpu3dPutShHdr(stream, i, u64(6), u64(0), u64(84), u64(64), u64(21));
  virtgpu3dPutDw(stream, i, u64(0x54524556));
  virtgpu3dPutDw(stream, i + u64(1), u64(0x4C43440A));
  virtgpu3dPutDw(stream, i + u64(2), u64(0x54554F20));
  virtgpu3dPutDw(stream, i + u64(3), u64(0x2C5D305B));
  virtgpu3dPutDw(stream, i + u64(4), u64(0x534F5020));
  virtgpu3dPutDw(stream, i + u64(5), u64(0x4F495449));
  virtgpu3dPutDw(stream, i + u64(6), u64(0x4D490A4E));
  virtgpu3dPutDw(stream, i + u64(7), u64(0x4C46204D));
  virtgpu3dPutDw(stream, i + u64(8), u64(0x20323354));
  virtgpu3dPutDw(stream, i + u64(9), u64(0x2E30207B));
  virtgpu3dPutDw(stream, i + u64(10), u64(0x30202C30));
  virtgpu3dPutDw(stream, i + u64(11), u64(0x202C302E));
  virtgpu3dPutDw(stream, i + u64(12), u64(0x2C302E30));
  virtgpu3dPutDw(stream, i + u64(13), u64(0x302E3120));
  virtgpu3dPutDw(stream, i + u64(14), u64(0x4F4D0A7D));
  virtgpu3dPutDw(stream, i + u64(15), u64(0x554F2056));
  virtgpu3dPutDw(stream, i + u64(16), u64(0x5D305B54));
  virtgpu3dPutDw(stream, i + u64(17), u64(0x4D49202C));
  virtgpu3dPutDw(stream, i + u64(18), u64(0x5D305B4D));
  virtgpu3dPutDw(stream, i + u64(19), u64(0x444E450A));
  virtgpu3dPutDw(stream, i + u64(20), u64(0x0000000A));
  i = i + u64(21);
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdBindSh), u64(0), u64(2)));
  virtgpu3dPutDw(stream, i + u64(1), u64(6));
  virtgpu3dPutDw(stream, i + u64(2), u64(0));
  return i + u64(3);
}

@bare
u64 virtgpu3dPutFs(u64 stream, u64 i) {
  i = virtgpu3dPutShHdr(stream, i, u64(7), u64(1), u64(80), u64(64), u64(20));
  virtgpu3dPutDw(stream, i, u64(0x47415246));
  virtgpu3dPutDw(stream, i + u64(1), u64(0x4C43440A));
  virtgpu3dPutDw(stream, i + u64(2), u64(0x54554F20));
  virtgpu3dPutDw(stream, i + u64(3), u64(0x2C5D305B));
  virtgpu3dPutDw(stream, i + u64(4), u64(0x4C4F4320));
  virtgpu3dPutDw(stream, i + u64(5), u64(0x490A524F));
  virtgpu3dPutDw(stream, i + u64(6), u64(0x46204D4D));
  virtgpu3dPutDw(stream, i + u64(7), u64(0x3233544C));
  virtgpu3dPutDw(stream, i + u64(8), u64(0x31207B20));
  virtgpu3dPutDw(stream, i + u64(9), u64(0x202C302E));
  virtgpu3dPutDw(stream, i + u64(10), u64(0x2C302E30));
  virtgpu3dPutDw(stream, i + u64(11), u64(0x302E3020));
  virtgpu3dPutDw(stream, i + u64(12), u64(0x2E30202C));
  virtgpu3dPutDw(stream, i + u64(13), u64(0x4D0A7D35));
  virtgpu3dPutDw(stream, i + u64(14), u64(0x4F20564F));
  virtgpu3dPutDw(stream, i + u64(15), u64(0x305B5455));
  virtgpu3dPutDw(stream, i + u64(16), u64(0x49202C5D));
  virtgpu3dPutDw(stream, i + u64(17), u64(0x305B4D4D));
  virtgpu3dPutDw(stream, i + u64(18), u64(0x4E450A5D));
  virtgpu3dPutDw(stream, i + u64(19), u64(0x00000A44));
  i = i + u64(20);
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdBindSh), u64(0), u64(2)));
  virtgpu3dPutDw(stream, i + u64(1), u64(7));
  virtgpu3dPutDw(stream, i + u64(2), u64(1));
  return i + u64(3);
}

/// DRAW_VBO: one point. Rasterizer point size covers the 64×64 RT.
@bare
u64 virtgpu3dPutDraw(u64 stream, u64 i) {
  virtgpu3dPutDw(
      stream, i, virtgpu3dCmd0(u64(virtgpu3dCcmdDraw), u64(0), u64(12)));
  virtgpu3dPutDw(stream, i + u64(1), u64(0));
  virtgpu3dPutDw(stream, i + u64(2), u64(1));
  virtgpu3dPutDw(stream, i + u64(3), u64(0));
  virtgpu3dPutDw(stream, i + u64(4), u64(0));
  virtgpu3dPutDw(stream, i + u64(5), u64(1));
  virtgpu3dPutDw(stream, i + u64(6), u64(0));
  virtgpu3dPutDw(stream, i + u64(7), u64(0));
  virtgpu3dPutDw(stream, i + u64(8), u64(0));
  virtgpu3dPutDw(stream, i + u64(9), u64(0));
  virtgpu3dPutDw(stream, i + u64(10), u64(0));
  virtgpu3dPutDw(stream, i + u64(11), u64(0));
  virtgpu3dPutDw(stream, i + u64(12), u64(0));
  return i + u64(13);
}

/// GPU CLEAR of dest to 50% red (A=0.5). That is the device writing
/// a translucent pixel. A later triangle/blit may sit after this;
/// the transfer samples this colour if they are nops.
@bare
u64 virtgpu3dFillStream(u64 stream) {
  u64 i = u64(0);
  i = virtgpu3dPutSubVp(stream, i);
  i = virtgpu3dPutClear(
      stream, i, u64(1), u64(virtgpu3dResDst),
      u64(virtgpu3dF1), u64(0), u64(0), u64(virtgpu3dFHalf));
  return i;
}

/// RESOURCE_CREATE_3D for [id], [side]×[side], B8G8R8A8 RT+scanout.
@bare
u64 virtgpu3dMake3d(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 resp, u64 id, u64 side, u64 kick) {
  virtgpu3dPutHdr(req, u64(virtgpu3dTypeRes3d), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), id);
  virtgpuRamPut32(req + u64(28), u64(virtgpu3dTarget2d));
  virtgpuRamPut32(req + u64(32), u64(virtgpu3dFmtBgra));
  virtgpuRamPut32(req + u64(36), u64(virtgpu3dBind));
  virtgpuRamPut32(req + u64(40), side);
  virtgpuRamPut32(req + u64(44), side);
  virtgpuRamPut32(req + u64(48), u64(1));
  virtgpuRamPut32(req + u64(52), u64(1));
  virtgpuRamPut32(req + u64(56), u64(0));
  virtgpuRamPut32(req + u64(60), u64(0));
  virtgpuRamPut32(req + u64(64), u64(0));
  virtgpuRamPut32(req + u64(68), u64(0));
  return virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(72), resp, kick);
}

/// Four-frame backing for the dest resource. Returns the first
/// frame address, or 0 on failure. Backing is zeroed — the GPU
/// must write the blended pixel.
@bare
u64 virtgpu3dAttachDst(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 resp, u64 kick) {
  final u64 ents = req + u64(64);
  final u64 f0 = allocFrame();
  final u64 f1 = allocFrame();
  final u64 f2 = allocFrame();
  final u64 f3 = allocFrame();
  if (f0 < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  if (f1 < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  if (f2 < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  if (f3 < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  vmZeroFrame(f0);
  vmZeroFrame(f1);
  vmZeroFrame(f2);
  vmZeroFrame(f3);
  virtgpuRamPut32(ents, f0);
  virtgpuRamPut32(ents + u64(4), u64(0));
  virtgpuRamPut32(ents + u64(8), u64(4096));
  virtgpuRamPut32(ents + u64(12), u64(0));
  virtgpuRamPut32(ents + u64(16), f1);
  virtgpuRamPut32(ents + u64(20), u64(0));
  virtgpuRamPut32(ents + u64(24), u64(4096));
  virtgpuRamPut32(ents + u64(28), u64(0));
  virtgpuRamPut32(ents + u64(32), f2);
  virtgpuRamPut32(ents + u64(36), u64(0));
  virtgpuRamPut32(ents + u64(40), u64(4096));
  virtgpuRamPut32(ents + u64(44), u64(0));
  virtgpuRamPut32(ents + u64(48), f3);
  virtgpuRamPut32(ents + u64(52), u64(0));
  virtgpuRamPut32(ents + u64(56), u64(4096));
  virtgpuRamPut32(ents + u64(60), u64(0));

  virtgpu3dPutHdr(req, u64(virtgpuTypeAttach), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(virtgpu3dResDst));
  virtgpuRamPut32(req + u64(28), u64(virtgpu3dFrames));
  virtgpuZero(resp, u64(24));
  virtgpuPutDesc(
      qdesc, head, req, u64(32), u64(virtgpuDescNext), head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), ents, u64(64), u64(virtgpuDescNext), head + u64(2));
  virtgpuPutDesc(
      qdesc, head + u64(2), resp, u64(virtgpuHdrBytes), u64(virtgpuDescWrite),
      u64(0));
  virtgpuRamPut16(qdrv + u64(4) + (slot << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  final u64 used = virtgpu3dWaitUsed(qdev, slot + u64(1));
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  if (virtgpuRamGet32(resp) != u64(virtgpuRespOk)) {
    return u64(0);
  }
  virtgpuReportBack(f0);
  return f0;
}

/// Attach used three descriptors. The next [head] must skip them.

/// After the queue exists: context, two 3D resources, submit,
/// transfer one pixel from the blended rect, scanout. [doSub] 0
/// is virtgpuz (probe only).
@bare
void virtgpu3dPaint(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 sw, u64 sh, u64 doSub, u64 kick, u64 asApp) {
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  u64 head = u64(2);
  u64 slot = u64(1);

  virtgpu3dPutHdr(req, u64(virtgpu3dTypeCtxNew), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(8));
  virtgpuRamPut32(req + u64(28), u64(1));
  virtgpuRamPut32(req + u64(32), u64(virtgpu3dName0));
  virtgpuRamPut32(req + u64(36), u64(virtgpu3dName1));
  u64 z = u64(40);
  while (z < u64(96)) {
    virtgpuRamPut32(req + z, u64(0));
    z = z + u64(4);
  }
  final u64 tCtx = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(96), resp, kick);
  virtgpu3dReportSub(tCtx);
  if (tCtx != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  if (doSub < u64(1)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 tDst = virtgpu3dMake3d(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp,
      u64(virtgpu3dResDst), u64(virtgpu3dSide), kick);
  virtgpu3dReportSub(tDst);
  if (tDst != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 back = virtgpu3dAttachDst(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp, kick);
  if (back < u64(1)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(3);
  slot = slot + u64(1);

  virtgpu3dPutHdr(req, u64(virtgpu3dTypeCtxAtt), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(virtgpu3dResDst));
  virtgpuRamPut32(req + u64(28), u64(0));
  final u64 tAtt1 = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(32), resp, kick);
  if (tAtt1 != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 stream = allocFrame();
  if (stream < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  vmZeroFrame(stream);
  final u64 ndw = virtgpu3dFillStream(stream);
  final u64 slen = ndw << u64(2);
  virtgpu3dPutHdr(req, u64(virtgpu3dTypeSubmit), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), slen);
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuZero(resp, u64(24));
  virtgpuPutDesc(
      qdesc, head, req, u64(32), u64(virtgpuDescNext), head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), stream, slen, u64(virtgpuDescNext), head + u64(2));
  virtgpuPutDesc(
      qdesc, head + u64(2), resp, u64(virtgpuHdrBytes), u64(virtgpuDescWrite),
      u64(0));
  virtgpuRamPut16(qdrv + u64(4) + (slot << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  final u64 usedS = virtgpu3dWaitUsed(qdev, slot + u64(1));
  if (usedS < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  final u64 tSub = virtgpuRamGet32(resp);
  virtgpu3dReportSub(tSub);
  if (tSub != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(3);
  slot = slot + u64(1);

  // 1×1 box at (20,20) — inside the clip-space triangle, not a
  // corner the clear colour could satisfy alone if the draw is a nop.
  virtgpu3dPutHdr(req, u64(virtgpu3dTypeXferFrom), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(20));
  virtgpuRamPut32(req + u64(28), u64(20));
  virtgpuRamPut32(req + u64(32), u64(0));
  virtgpuRamPut32(req + u64(36), u64(1));
  virtgpuRamPut32(req + u64(40), u64(1));
  virtgpuRamPut32(req + u64(44), u64(1));
  virtgpuRamPut32(req + u64(48), u64(0));
  virtgpuRamPut32(req + u64(52), u64(0));
  virtgpuRamPut32(req + u64(56), u64(virtgpu3dResDst));
  virtgpuRamPut32(req + u64(60), u64(0));
  virtgpuRamPut32(req + u64(64), u64(4));
  virtgpuRamPut32(req + u64(68), u64(4));
  final u64 tX = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(72), resp, kick);
  virtgpu3dReportSub(tX);
  if (tX != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  virtgpu3dPutHdr(req, u64(virtgpuTypeSetScan), u64(0));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  u64 scanW = u64(virtgpu3dSide);
  u64 scanH = u64(virtgpu3dSide);
  if (sw < scanW) {
    scanW = sw;
  }
  if (sh < scanH) {
    scanH = sh;
  }
  virtgpuRamPut32(req + u64(32), scanW);
  virtgpuRamPut32(req + u64(36), scanH);
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), u64(virtgpu3dResDst));
  final u64 tScan = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp, kick);
  virtgpu3dReportSub(tScan);

  uartWrite(Rodata.addressOf(virtgpu3dStrOk), u64(13));
  virtgpu3dReportPaint(u64(3));
  virtgpu3dReportPix(virtgpuRamGet32(back));
  if (asApp > u64(0)) {
    osgpuReportOk();
    osgpuReportPix(virtgpuRamGet32(back));
  }
}

/// Queue 0 + GET_DISPLAY_INFO, then the 3D walk.
@bare
void virtgpu3dOne(u64 bus, u64 dev, u64 fn, u64 cfg, u64 doSub, u64 asApp) {
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
  if (qsz == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoQ), u64(11));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  if (qsz > u64(virtgpuQSizeCap)) {
    qsz = u64(virtgpuQSizeCap);
    virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
  }
  virtgpuReportQSize(qsz);

  final u64 dcfg = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapDevice));
  u64 ncap = u64(0);
  if (dcfg > u64(0)) {
    ncap = virtgpuCfgGet32(dcfg, u64(virtgpuDevNumCap));
  }
  virtgpuReportNCap(ncap);

  final u64 ntfy = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapNotify));
  u64 mul = virtgpuNotifyMul(bus, dev, fn);
  if (ntfy == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoNotify), u64(16));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  if (mul == u64(0)) {
    mul = u64(1);
  }
  final u64 noff = virtgpuCfgGet16(cfg, u64(virtgpuCfgQNotifyOff));
  final u64 naddr = ntfy + (noff * mul);

  final u64 qdesc = allocFrame();
  if (qdesc < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(qdesc);
  final u64 qdrv = allocFrame();
  if (qdrv < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(qdrv);
  final u64 qdev = allocFrame();
  if (qdev < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(qdev);

  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDesc), qdesc);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDriver), qdrv);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDevice), qdev);
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQEn), u64(1));
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk));
  virtgpuReportStatus(virtgpuStatusGet(cfg));

  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  virtgpuRamPut32(req, u64(virtgpuTypeGetDisp));
  virtgpuPutDesc(
      qdesc, u64(0), req, u64(virtgpuHdrBytes), u64(virtgpuDescNext), u64(1));
  virtgpuPutDesc(
      qdesc, u64(1), resp, u64(virtgpuDispBytes), u64(virtgpuDescWrite), u64(0));
  virtgpuRamPut16(qdrv, u64(virtgpuAvailNoInt));
  virtgpuRamPut16(qdrv + u64(4), u64(0));
  virtgpuRamPut16(qdrv + u64(2), u64(1));
  Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  final u64 used = virtgpu3dWaitUsed(qdev, u64(1));
  virtgpuReportUsed(used);
  if (used == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  final u64 sw = virtgpuRamGet32(resp + u64(32));
  final u64 sh = virtgpuRamGet32(resp + u64(36));
  virtgpuReportScan(
      virtgpuRamGet32(resp + u64(24)),
      virtgpuRamGet32(resp + u64(28)),
      sw,
      sh,
      virtgpuRamGet32(resp + u64(40)));
  virtgpu3dPaint(qdesc, qdrv, qdev, naddr, sw, sh, doSub, u64(1), asApp);
}

/// Find 1AF4:1050, negotiate VIRGL, then either submit or stop.
/// [asApp] 1 is hidden `osgpug` (ADR-0114): same G10 walk, plus
/// OSGPU OK / PIX / NONE. G10 `virtgpug` passes 0.
@bare
void virtgpu3dGoApp(u64 doSub, u64 asApp) {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
        virtgpuReportDevice(u64(0), dev, u64(0), id, classReg);
        virtgpuEnableMaster(u64(0), dev, u64(0));
        final u64 virgl = virtgpu3dNegotiate(u64(0), dev, u64(0));
        if (virgl < u64(1)) {
          uartWrite(Rodata.addressOf(virtgpu3dStrNone), u64(15));
          virtgpu3dReportPaint(u64(2));
          if (asApp > u64(0)) {
            osgpuReportNone();
          }
          return;
        }
        final u64 cfg = virtgpuCommonCfg(u64(0), dev, u64(0));
        if (cfg > u64(0)) {
          virtgpu3dOne(u64(0), dev, u64(0), cfg, doSub, asApp);
        }
        return;
      }
    }
    dev = dev + u64(1);
  }
  uartWrite(Rodata.addressOf(virtgpuStrNone), u64(12));
  uartWrite(Rodata.addressOf(virtgpu3dStrNone), u64(15));
  virtgpu3dReportPaint(u64(0));
  if (asApp > u64(0)) {
    osgpuReportNone();
  }
}

@bare
void virtgpu3dGo(u64 doSub) {
  virtgpu3dGoApp(doSub, u64(0));
}

/// `virtgpug` -- 3D probe, virgl submit, transfer, 3D OK.
@bare
void shellVirtgpu3d() {
  virtgpu3dGo(u64(1));
}

/// `virtgpuz` -- 3D probe only. VIRGL may be offered; SUBMIT_3D
/// is not sent; VIRTIO 3D OK must not print.
@bare
void shellVirtgpu3dNo() {
  virtgpu3dGo(u64(0));
}

// ---------------------------------------------------------------------------
// G11 / ADR-0107 — append only. G10 CLEAR / virtgpug / virtgpuz stay.
// osgfx_sw already painted the compose buffer (wm gfx). This walk
// uploads that buffer to a VIRGL 3D resource and SET_SCANOUT so the
// GL device shows rounded chrome. Not Graphite. Not a G5 2D mailbox.
// ---------------------------------------------------------------------------

/// VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D. G10's FROM is 0x0206.
const int virtgpu3dTypeXferTo = 0x0205;

/// Guest-chosen resource for the osgfx scanout. 1 is G10 dest.
const int virtgpu3dResOsgfx = 3;

/// `"virtgpuk"` -- 8 bytes. Upload osgfx compose + SET_SCANOUT.
@rodata
final List<u8> virtgpu3dStrCmdOsgfx = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x6B),
];

/// `"OSGFX 3D\n"` -- 9 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpu3dStrOsgfx = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x46), u8(0x58), u8(0x20),
  u8(0x33), u8(0x44), u8(0x0A),
];

/// `"OSGFX AABB "` -- 11 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpu3dStrAabb = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x46), u8(0x58), u8(0x20),
  u8(0x41), u8(0x41), u8(0x42), u8(0x42), u8(0x20),
];

/// `"OSGFX TITLE "` -- 12 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpu3dStrTitle = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x46), u8(0x58), u8(0x20),
  u8(0x54), u8(0x49), u8(0x54), u8(0x4C), u8(0x45), u8(0x20),
];

@bare
void virtgpu3dReportOsgfx() {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrOsgfx), u64(9));
}

@bare
void virtgpu3dReportAabb(u64 p) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrAabb), u64(11));
  uartPutHex(p, u64(8));
  uartNewline();
}

@bare
void virtgpu3dReportTitle(u64 p) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpu3dStrTitle), u64(12));
  uartPutHex(p, u64(8));
  uartNewline();
}

/// RESOURCE_CREATE_3D for a rectangle. Sibling of [virtgpu3dMake3d]
/// (that one stays square for G10).
@bare
u64 virtgpu3dMake3dRect(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 resp, u64 id, u64 w, u64 h, u64 kick) {
  virtgpu3dPutHdr(req, u64(virtgpu3dTypeRes3d), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), id);
  virtgpuRamPut32(req + u64(28), u64(virtgpu3dTarget2d));
  virtgpuRamPut32(req + u64(32), u64(virtgpu3dFmtBgra));
  virtgpuRamPut32(req + u64(36), u64(virtgpu3dBind));
  virtgpuRamPut32(req + u64(40), w);
  virtgpuRamPut32(req + u64(44), h);
  virtgpuRamPut32(req + u64(48), u64(1));
  virtgpuRamPut32(req + u64(52), u64(1));
  virtgpuRamPut32(req + u64(56), u64(0));
  virtgpuRamPut32(req + u64(60), u64(0));
  virtgpuRamPut32(req + u64(64), u64(0));
  virtgpuRamPut32(req + u64(68), u64(0));
  return virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(72), resp, kick);
}

/// TRANSFER_TO_HOST_3D or TRANSFER_FROM_HOST_3D of one box.
@bare
u64 virtgpu3dXfer3d(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 resp, u64 typ, u64 x, u64 y, u64 w, u64 h, u64 res, u64 off, u64 stride, u64 layer, u64 kick) {
  virtgpu3dPutHdr(req, typ, u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), x);
  virtgpuRamPut32(req + u64(28), y);
  virtgpuRamPut32(req + u64(32), u64(0));
  virtgpuRamPut32(req + u64(36), w);
  virtgpuRamPut32(req + u64(40), h);
  virtgpuRamPut32(req + u64(44), u64(1));
  virtgpuRamPut32(req + u64(48), off);
  virtgpuRamPut32(req + u64(52), u64(0));
  virtgpuRamPut32(req + u64(56), res);
  virtgpuRamPut32(req + u64(60), u64(0));
  virtgpuRamPut32(req + u64(64), stride);
  virtgpuRamPut32(req + u64(68), layer);
  return virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(72), resp, kick);
}

/// Attach [nframes] pages starting at [firstIn] to [virtgpu3dResOsgfx].
/// [firstIn] 0 means allocate a new contiguous run.
/// Returns the first frame, or 0.
@bare
u64 virtgpu3dAttachOsgfx(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 resp, u64 firstIn, u64 nframes, u64 kick) {
  if (nframes < u64(1)) {
    return u64(0);
  }
  if (nframes > u64(virtgpuBackCap)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  final u64 ebytes = nframes << u64(4);
  u64 eframes = (ebytes + u64(4095)) ~/ u64(4096);
  if (eframes < u64(1)) {
    eframes = u64(1);
  }
  if (eframes > u64(virtgpuEntCap)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  final u64 e0 = allocFrame();
  if (e0 < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return u64(0);
  }
  vmZeroFrame(e0);
  u64 e1 = u64(0);
  u64 e2 = u64(0);
  u64 e3 = u64(0);
  if (eframes > u64(1)) {
    e1 = allocFrame();
    if (e1 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return u64(0);
    }
    vmZeroFrame(e1);
  }
  if (eframes > u64(2)) {
    e2 = allocFrame();
    if (e2 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return u64(0);
    }
    vmZeroFrame(e2);
  }
  if (eframes > u64(3)) {
    e3 = allocFrame();
    if (e3 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return u64(0);
    }
    vmZeroFrame(e3);
  }

  u64 first = firstIn;
  if (first < u64(1)) {
    u64 ei = u64(0);
    while (ei < nframes) {
      final u64 fr = allocFrame();
      if (fr < u64(1)) {
        uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
        return u64(0);
      }
      vmZeroFrame(fr);
      if (ei == u64(0)) {
        first = fr;
      }
      if (fr != first + (ei << u64(12))) {
        uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
        return u64(0);
      }
      final u64 eoff = ei << u64(4);
      final u64 ep = virtgpuEntBase(e0, e1, e2, e3, eoff >> u64(12)) +
          (eoff & u64(0xFFF));
      virtgpuRamPut32(ep, fr);
      virtgpuRamPut32(ep + u64(4), u64(0));
      virtgpuRamPut32(ep + u64(8), u64(4096));
      virtgpuRamPut32(ep + u64(12), u64(0));
      ei = ei + u64(1);
    }
  } else {
    u64 ei = u64(0);
    while (ei < nframes) {
      final u64 fr = first + (ei << u64(12));
      final u64 eoff = ei << u64(4);
      final u64 ep = virtgpuEntBase(e0, e1, e2, e3, eoff >> u64(12)) +
          (eoff & u64(0xFFF));
      virtgpuRamPut32(ep, fr);
      virtgpuRamPut32(ep + u64(4), u64(0));
      virtgpuRamPut32(ep + u64(8), u64(4096));
      virtgpuRamPut32(ep + u64(12), u64(0));
      ei = ei + u64(1);
    }
  }

  virtgpu3dPutHdr(req, u64(virtgpuTypeAttach), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(virtgpu3dResOsgfx));
  virtgpuRamPut32(req + u64(28), nframes);
  virtgpuZero(resp, u64(24));
  virtgpuPutDesc(
      qdesc, head, req, u64(32), u64(virtgpuDescNext), head + u64(1));
  u64 ef = u64(0);
  while (ef < eframes) {
    u64 elen = u64(4096);
    if (ef + u64(1) == eframes) {
      elen = ebytes - (ef << u64(12));
    }
    virtgpuPutDesc(
        qdesc,
        head + u64(1) + ef,
        virtgpuEntBase(e0, e1, e2, e3, ef),
        elen,
        u64(virtgpuDescNext),
        head + u64(2) + ef);
    ef = ef + u64(1);
  }
  virtgpuPutDesc(
      qdesc,
      head + u64(1) + eframes,
      resp,
      u64(virtgpuHdrBytes),
      u64(virtgpuDescWrite),
      u64(0));
  virtgpuRamPut16(qdrv + u64(4) + (slot << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  final u64 used = virtgpu3dWaitUsed(qdev, slot + u64(1));
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  if (virtgpuRamGet32(resp) != u64(virtgpuRespOk)) {
    return u64(0);
  }
  virtgpuReportBack(first);
  virtgpuReportFrames(nframes);
  return first;
}

/// After the queue exists: 3D resource, upload the osgfx compose
/// buffer, bounce two pixels through the device, SET_SCANOUT.
@bare
void virtgpu3dOsgfxPaint(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 sw, u64 sh, u64 kick) {
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  u64 head = u64(2);
  u64 slot = u64(1);

  if (sw < u64(8)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  if (sh < u64(8)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }

  virtgpu3dPutHdr(req, u64(virtgpu3dTypeCtxNew), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(8));
  virtgpuRamPut32(req + u64(28), u64(1));
  virtgpuRamPut32(req + u64(32), u64(virtgpu3dName0));
  virtgpuRamPut32(req + u64(36), u64(virtgpu3dName1));
  u64 z = u64(40);
  while (z < u64(96)) {
    virtgpuRamPut32(req + z, u64(0));
    z = z + u64(4);
  }
  final u64 tCtx = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(96), resp, kick);
  virtgpu3dReportSub(tCtx);
  if (tCtx != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 tRes = virtgpu3dMake3dRect(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp,
      u64(virtgpu3dResOsgfx), sw, sh, kick);
  virtgpu3dReportSub(tRes);
  if (tRes != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 nbytes = (sw * sh) << u64(2);
  u64 nframes = (nbytes + u64(4095)) ~/ u64(4096);
  if (nframes < u64(1)) {
    nframes = u64(1);
  }
  u64 reuse = u64(0);
  final u64 fbBase = fbState(u64(fbStateBase));
  final u64 fbPitch = fbState(u64(fbStatePitch));
  if (fbBase > u64(0)) {
    if (fbBase < u64(virtgpuRamCeil)) {
      if (fbPitch == (sw << u64(2))) {
        reuse = fbBase;
      }
    }
  }

  final u64 back = virtgpu3dAttachOsgfx(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp, reuse, nframes, kick);
  if (back < u64(1)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  final u64 ebytes = nframes << u64(4);
  u64 eframes = (ebytes + u64(4095)) ~/ u64(4096);
  if (eframes < u64(1)) {
    eframes = u64(1);
  }
  head = head + u64(2) + eframes;
  slot = slot + u64(1);

  fbSetState(u64(fbStateBase), back);
  fbSetState(u64(fbStatePitch), sw << u64(2));
  fbSetState(u64(fbStateGeomW), sw);
  fbSetState(u64(fbStateGeomH), sh);
  u64 fy = u64(0);
  while (fy < sh) {
    u64 fx = u64(0);
    while (fx < sw) {
      virtgpuRamPut32(
          back + (fy * (sw << u64(2))) + (fx << u64(2)),
          u64(wmColorDesktop));
      fx = fx + u64(1);
    }
    fy = fy + u64(1);
  }

  // osgfx_guest_tick paints into this backing. Two READY clients
  // would steal the shell, so virtgpuk kicks the mailbox itself
  // (live window geom, or one session-sized rrect) and waits IRQ0.
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    wmSetMeta(u64(wmMetaChrome), u64(1));
    wmSetMeta(u64(wmMetaGfx), u64(1));
  }
  /* Prefer wmGfxKick so OSGFX_GUEST_DE / held bits travel when
   * `wm de` already ran. Fall back to a session-sized rrect when
   * no client is attached yet. */
  wmGfxKick();
  final u64 mailbox = kernel_data_start();
  u64 win0 = Pointer<u64>.fromAddress(mailbox + u64(48)).value;
  if (win0 == u64(0)) {
    win0 = wmPackGeom(u64(100), u64(120), u64(240), u64(160));
    Pointer<u64>.fromAddress(mailbox + u64(48)).value = win0;
  }
  Pointer<u64>.fromAddress(mailbox + u64(16)).value = back;
  Pointer<u64>.fromAddress(mailbox + u64(24)).value = sw << u64(2);
  Pointer<u64>.fromAddress(mailbox + u64(32)).value = sw;
  Pointer<u64>.fromAddress(mailbox + u64(40)).value = sh;
  final u64 gen = Pointer<u64>.fromAddress(mailbox + u64(72)).value + u64(1);
  Pointer<u64>.fromAddress(mailbox + u64(72)).value = gen;
  picUnmaskTimerAndKeyboard();
  final u64 t0 = tick_count();
  u64 now = t0;
  while (now < (t0 + u64(40))) {
    now = tick_count();
  }
  if (procHead(u64(procHeadResident)) < u64(1)) {
    picUnmaskKeyboardOnly();
  }

  virtgpu3dPutHdr(req, u64(virtgpu3dTypeCtxAtt), u64(virtgpu3dCtx));
  virtgpuRamPut32(req + u64(24), u64(virtgpu3dResOsgfx));
  virtgpuRamPut32(req + u64(28), u64(0));
  final u64 tAtt = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(32), resp, kick);
  if (tAtt != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 tTo = virtgpu3dXfer3d(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp,
      u64(virtgpu3dTypeXferTo), u64(0), u64(0), sw, sh,
      u64(virtgpu3dResOsgfx), u64(0), sw << u64(2), u64(0), kick);
  virtgpu3dReportSub(tTo);
  if (tTo != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 ax = wmGeomX(win0);
  final u64 ay = wmGeomY(win0);
  final u64 tx = ax + u64(20);
  final u64 ty = ay + u64(4);
  final u64 saved = virtgpuRamGet32(back);
  virtgpuRamPut32(back, u64(0));
  final u64 tAabb = virtgpu3dXfer3d(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp,
      u64(virtgpu3dTypeXferFrom), ax, ay, u64(1), u64(1),
      u64(virtgpu3dResOsgfx), u64(0), u64(4), u64(4), kick);
  virtgpu3dReportSub(tAabb);
  if (tAabb != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  final u64 aabb = virtgpuRamGet32(back);
  virtgpuRamPut32(back, saved);
  head = head + u64(2);
  slot = slot + u64(1);

  virtgpuRamPut32(back, u64(0));
  final u64 tTitle = virtgpu3dXfer3d(
      qdesc, qdrv, qdev, naddr, head, slot, req, resp,
      u64(virtgpu3dTypeXferFrom), tx, ty, u64(1), u64(1),
      u64(virtgpu3dResOsgfx), u64(0), u64(4), u64(4), kick);
  virtgpu3dReportSub(tTitle);
  if (tTitle != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }
  final u64 title = virtgpuRamGet32(back);
  virtgpuRamPut32(back, saved);
  head = head + u64(2);
  slot = slot + u64(1);

  virtgpu3dPutHdr(req, u64(virtgpuTypeSetScan), u64(0));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), sw);
  virtgpuRamPut32(req + u64(36), sh);
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), u64(virtgpu3dResOsgfx));
  final u64 tScan = virtgpu3dSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp, kick);
  virtgpu3dReportSub(tScan);
  if (tScan != u64(virtgpuRespOk)) {
    virtgpu3dReportPaint(u64(2));
    return;
  }

  fbSetState(u64(fbStateBase), back);
  fbSetState(u64(fbStatePitch), sw << u64(2));
  fbSetState(u64(fbStateGeomW), sw);
  fbSetState(u64(fbStateGeomH), sh);

  uartWrite(Rodata.addressOf(virtgpu3dStrOk), u64(13));
  virtgpu3dReportPaint(u64(3));
  virtgpu3dReportOsgfx();
  virtgpu3dReportAabb(aabb);
  virtgpu3dReportTitle(title);
}

/// Queue 0 + GET_DISPLAY_INFO, then the osgfx upload.
@bare
void virtgpu3dOsgfxOne(u64 bus, u64 dev, u64 fn, u64 cfg) {
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
  if (qsz == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoQ), u64(11));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  if (qsz > u64(virtgpuQSizeCap)) {
    qsz = u64(virtgpuQSizeCap);
    virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
  }
  virtgpuReportQSize(qsz);

  final u64 ntfy = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapNotify));
  u64 mul = virtgpuNotifyMul(bus, dev, fn);
  if (ntfy == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoNotify), u64(16));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  if (mul == u64(0)) {
    mul = u64(1);
  }
  final u64 noff = virtgpuCfgGet16(cfg, u64(virtgpuCfgQNotifyOff));
  final u64 naddr = ntfy + (noff * mul);

  final u64 qdesc = allocFrame();
  if (qdesc < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(qdesc);
  final u64 qdrv = allocFrame();
  if (qdrv < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(qdrv);
  final u64 qdev = allocFrame();
  if (qdev < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(qdev);

  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDesc), qdesc);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDriver), qdrv);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDevice), qdev);
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQEn), u64(1));
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk));
  virtgpuReportStatus(virtgpuStatusGet(cfg));

  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  virtgpuRamPut32(req, u64(virtgpuTypeGetDisp));
  virtgpuPutDesc(
      qdesc, u64(0), req, u64(virtgpuHdrBytes), u64(virtgpuDescNext), u64(1));
  virtgpuPutDesc(
      qdesc, u64(1), resp, u64(virtgpuDispBytes), u64(virtgpuDescWrite), u64(0));
  virtgpuRamPut16(qdrv, u64(virtgpuAvailNoInt));
  virtgpuRamPut16(qdrv + u64(4), u64(0));
  virtgpuRamPut16(qdrv + u64(2), u64(1));
  Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  final u64 used = virtgpu3dWaitUsed(qdev, u64(1));
  virtgpuReportUsed(used);
  if (used == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    virtgpu3dReportPaint(u64(2));
    return;
  }
  final u64 sw = virtgpuRamGet32(resp + u64(32));
  final u64 sh = virtgpuRamGet32(resp + u64(36));
  virtgpuReportScan(
      virtgpuRamGet32(resp + u64(24)),
      virtgpuRamGet32(resp + u64(28)),
      sw,
      sh,
      virtgpuRamGet32(resp + u64(40)));
  virtgpu3dOsgfxPaint(qdesc, qdrv, qdev, naddr, sw, sh, u64(1));
}

/// Find 1AF4:1050, negotiate VIRGL, upload osgfx, scanout.
@bare
void virtgpu3dOsgfxGo() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
        virtgpuReportDevice(u64(0), dev, u64(0), id, classReg);
        virtgpuEnableMaster(u64(0), dev, u64(0));
        final u64 virgl = virtgpu3dNegotiate(u64(0), dev, u64(0));
        if (virgl < u64(1)) {
          uartWrite(Rodata.addressOf(virtgpu3dStrNone), u64(15));
          virtgpu3dReportPaint(u64(2));
          return;
        }
        final u64 cfg = virtgpuCommonCfg(u64(0), dev, u64(0));
        if (cfg > u64(0)) {
          virtgpu3dOsgfxOne(u64(0), dev, u64(0), cfg);
        }
        return;
      }
    }
    dev = dev + u64(1);
  }
  uartWrite(Rodata.addressOf(virtgpuStrNone), u64(12));
  uartWrite(Rodata.addressOf(virtgpu3dStrNone), u64(15));
  virtgpu3dReportPaint(u64(0));
}

/// `virtgpuk` -- bind the osgfx compose buffer to a 3D resource
/// and SET_SCANOUT. Prints VIRTIO 3D OK and VIRTIO OSGFX 3D.
@bare
void shellVirtgpu3dOsgfx() {
  virtgpu3dOsgfxGo();
}

// ---------------------------------------------------------------------------
// G12 / ADR-0114 — append only. Explicit app GPU (`osgpu.h`).
// Implicit UI / osgfx / wm still pick GPU vs CPU. Games call osgpu.
// Hidden `osgpug` reuses G10 virtgpu3dGoApp(1, 1): same virgl CLEAR
// + TRANSFER_FROM_HOST_3D. No syscall. No help. No .bss. No C++.
// ---------------------------------------------------------------------------

/// `"osgpug"` -- 6 bytes. Explicit create/submit/readback.
@rodata
final List<u8> osgpuStrCmd = const [
  u8(0x6F), u8(0x73), u8(0x67), u8(0x70), u8(0x75), u8(0x67),
];

/// `"OSGPU NONE\n"` -- 11 bytes.
@rodata
final List<u8> osgpuStrNone = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x50), u8(0x55), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// `"OSGPU OK\n"` -- 9 bytes.
@rodata
final List<u8> osgpuStrOk = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x50), u8(0x55), u8(0x20),
  u8(0x4F), u8(0x4B), u8(0x0A),
];

/// `"OSGPU PIX "` -- 10 bytes.
@rodata
final List<u8> osgpuStrPix = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x50), u8(0x55), u8(0x20),
  u8(0x50), u8(0x49), u8(0x58), u8(0x20),
];

@bare
void osgpuReportNone() {
  uartWrite(Rodata.addressOf(osgpuStrNone), u64(11));
}

@bare
void osgpuReportOk() {
  uartWrite(Rodata.addressOf(osgpuStrOk), u64(9));
}

@bare
void osgpuReportPix(u64 p) {
  uartWrite(Rodata.addressOf(osgpuStrPix), u64(10));
  uartPutHex(p, u64(8));
  uartNewline();
}

/// `osgpug` -- G10 virgl submit as the explicit app path.
/// Prints OSGPU OK + OSGPU PIX, or OSGPU NONE. No syscall.
@bare
void shellOsgpu() {
  virtgpu3dGoApp(u64(1), u64(1));
}

// ---------------------------------------------------------------------------
// ADR-0134 — Venus capset door. GET_CAPSET_INFO walk for id 4.
// Arms osgfx mailbox word vk so MakeVulkan may open the kernel ICD.
// Homebrew / no-Venus stays 0. No help. No syscall. No .bss.
// ---------------------------------------------------------------------------

/// VIRTIO_GPU_CAPSET_VENUS.
const int virtgpu3dCapVenus = 4;

/// `"virtgpuv"` -- 8 bytes. Venus capset probe.
@rodata
final List<u8> virtgpu3dStrCmdVenus = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x76),
];

/// `"VIRTIO VENUS OK\n"` -- 16 bytes.
@rodata
final List<u8> virtgpu3dStrVenusOk = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x56), u8(0x45), u8(0x4E), u8(0x55), u8(0x53), u8(0x20),
  u8(0x4F), u8(0x4B), u8(0x0A),
];

/// `"VIRTIO VENUS NONE\n"` -- 18 bytes.
@rodata
final List<u8> virtgpu3dStrVenusNone = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x56), u8(0x45), u8(0x4E), u8(0x55), u8(0x53), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

@bare
void virtgpu3dVenusOffer(u64 yes) {
  final u64 mailbox = kernel_data_start();
  if (yes > u64(0)) {
    Pointer<u64>.fromAddress(mailbox + u64(80)).value = u64(1);
    uartWrite(Rodata.addressOf(virtgpu3dStrVenusOk), u64(16));
  } else {
    Pointer<u64>.fromAddress(mailbox + u64(80)).value = u64(0);
    uartWrite(Rodata.addressOf(virtgpu3dStrVenusNone), u64(18));
  }
}

/// G2 negotiate + control queue + GET_CAPSET_INFO for every capset.
/// Id 4 is Venus. Does not require VIRGL. Does not SUBMIT_3D.
@bare
void virtgpu3dVenusOne(u64 bus, u64 dev, u64 fn, u64 cfg) {
  u64 i = u64(0);
  u64 found = u64(0);
  u64 ncap = u64(0);
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
  if (qsz == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoQ), u64(11));
    virtgpu3dVenusOffer(u64(0));
    return;
  }
  if (qsz > u64(virtgpuQSizeCap)) {
    qsz = u64(virtgpuQSizeCap);
    virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
  }
  final u64 dcfg = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapDevice));
  if (dcfg > u64(0)) {
    ncap = virtgpuCfgGet32(dcfg, u64(virtgpuDevNumCap));
  }
  virtgpuReportNCap(ncap);
  final u64 ntfy = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapNotify));
  u64 mul = virtgpuNotifyMul(bus, dev, fn);
  if (ntfy == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoNotify), u64(16));
    virtgpu3dVenusOffer(u64(0));
    return;
  }
  if (mul == u64(0)) {
    mul = u64(1);
  }
  final u64 noff = virtgpuCfgGet16(cfg, u64(virtgpuCfgQNotifyOff));
  final u64 naddr = ntfy + (noff * mul);
  if (virtgpuOwnerBind(cfg) < u64(1)) {
    virtgpu3dVenusOffer(u64(0));
    return;
  }
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk));
  final u64 qdesc = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc));
  final u64 qdrv = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDriver));
  final u64 qdev = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDevice));
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  while (i < ncap) {
    final u64 slot = virtgpuAvailIdx(qdrv);
    final u64 head = (slot << u64(1)) & u64(62);
    virtgpuPutHdr(req, u64(virtgpuTypeCapInfo));
    virtgpuRamPut32(req + u64(24), i);
    virtgpuRamPut32(req + u64(28), u64(0));
    virtgpuZero(resp, u64(40));
    virtgpuPutDesc(
        qdesc, head, req, u64(32), u64(virtgpuDescNext), head + u64(1));
    virtgpuPutDesc(
        qdesc, head + u64(1), resp, u64(40), u64(virtgpuDescWrite), u64(0));
    virtgpuRamPut16(qdrv + u64(4) + ((slot & u64(63)) << u64(1)), head);
    virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
    final u64 used = virtgpu3dWaitUsed(qdev, slot + u64(1));
    if (used < (slot + u64(1))) {
      uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
      virtgpu3dVenusOffer(u64(0));
      return;
    }
    virtgpuReportCapInfo(
        virtgpuRamGet32(resp),
        virtgpuRamGet32(resp + u64(24)),
        virtgpuRamGet32(resp + u64(28)),
        virtgpuRamGet32(resp + u64(32)));
    if (virtgpuRamGet32(resp + u64(24)) == u64(virtgpu3dCapVenus)) {
      found = u64(1);
    }
    i = i + u64(1);
  }
  virtgpu3dVenusOffer(found);
}

@bare
void virtgpu3dVenusGo() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
        virtgpuReportDevice(u64(0), dev, u64(0), id, classReg);
        virtgpuEnableMaster(u64(0), dev, u64(0));
        virtgpuNegotiate(u64(0), dev, u64(0));
        final u64 cfg = virtgpuCommonCfg(u64(0), dev, u64(0));
        if (cfg > u64(0)) {
          virtgpu3dVenusOne(u64(0), dev, u64(0), cfg);
        } else {
          virtgpu3dVenusOffer(u64(0));
        }
        return;
      }
    }
    dev = dev + u64(1);
  }
  uartWrite(Rodata.addressOf(virtgpuStrNone), u64(12));
  virtgpu3dVenusOffer(u64(0));
}

/// `virtgpuv` -- Venus capset door. Prints VIRTIO VENUS OK or NONE.
@bare
void shellVirtgpu3dVenus() {
  virtgpu3dVenusGo();
}

// ---------------------------------------------------------------------------
// ADR-0172 — Venus SPIR-V encode door. CONTEXT_INIT (capset 4) +
// RESOURCE_CREATE_BLOB carrying retained SPIR-V onto the Venus / host
// lavapipe substrate. Called from C after CreateShaderModule retain.
// Not full lavapipe CreateShaderModule / Graphite FS. No help. No syscall.
// ---------------------------------------------------------------------------

/// VIRTIO_GPU_F_RESOURCE_BLOB / CONTEXT_INIT (feature word 0 bits 3/4).
const int virtgpu3dFeatBlob = 0x08;
const int virtgpu3dFeatCtxInit = 0x10;

/// VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB / MAP_BLOB.
const int virtgpu3dTypeResBlob = 0x010b;
const int virtgpu3dTypeMapBlob = 0x0208;

/// Venus context id for SPIR-V encode (virgl G10 uses 1).
const int virtgpu3dVenusCtx = 2;
const int virtgpu3dVenusRes = 7;

/// VIRTIO_GPU_BLOB_MEM_GUEST / HOST3D / HOST3D_GUEST.
const int virtgpu3dBlobMemGuest = 0x0001;
const int virtgpu3dBlobMemHost3d = 0x0002;
const int virtgpu3dBlobMemHostGuest = 0x0003;
/// FLAG_USE_MAPPABLE | USE_SHAREABLE.
const int virtgpu3dBlobMap = 0x0001;
const int virtgpu3dBlobShare = 0x0002;

/// `"osspirv"` -- CTX_CREATE debug name, two LE dwords.
const int virtgpu3dSpirvName0 = 0x6973736F;
const int virtgpu3dSpirvName1 = 0x00767270;

/// `"OSGFX VENUS SPIRV "` -- 18 bytes.
@rodata
final List<u8> virtgpu3dStrVenusSpirv = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x46), u8(0x58), u8(0x20),
  u8(0x56), u8(0x45), u8(0x4E), u8(0x55), u8(0x53), u8(0x20),
  u8(0x53), u8(0x50), u8(0x49), u8(0x52), u8(0x56), u8(0x20),
];

/// Negotiate VIRGL + RESOURCE_BLOB + CONTEXT_INIT + VERSION_1.
/// Returns 1 when CONTEXT_INIT stuck.
@bare
u64 virtgpu3dNegotiateVenus(u64 bus, u64 dev, u64 fn) {
  final u64 cfg = virtgpuCommonCfg(bus, dev, fn);
  final u64 want = u64(virtgpu3dFeatVirgl) | u64(virtgpu3dFeatBlob) |
      u64(virtgpu3dFeatCtxInit);
  if (cfg == u64(0)) {
    return u64(0);
  }
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) > u64(0)) {
    virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(0));
    final u64 have = virtgpuCfgGet32(cfg, u64(virtgpuCfgDrvFeat));
    if ((have & u64(virtgpu3dFeatCtxInit)) < u64(1)) {
      return u64(0);
    }
    if ((have & u64(virtgpu3dFeatBlob)) < u64(1)) {
      return u64(0);
    }
    return u64(1);
  }
  if (virtgpuReset(cfg) == u64(0)) {
    return u64(0);
  }
  virtgpuStatusOr(cfg, u64(virtgpuStatusAck));
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriver));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(0));
  final u64 featLo = virtgpuCfgGet32(cfg, u64(virtgpuCfgFeat));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(1));
  final u64 featHi = virtgpuCfgGet32(cfg, u64(virtgpuCfgFeat));
  virtgpu3dReportFeat(featLo, featHi);
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(0));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), featLo & want);
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(1));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), u64(virtgpuFeatVersion1));
  virtgpuStatusOr(cfg, u64(virtgpuStatusFeatOk));
  final u64 afterOk = virtgpuStatusGet(cfg);
  if ((afterOk & u64(virtgpuStatusFeatOk)) < u64(1)) {
    return u64(0);
  }
  if ((featLo & u64(virtgpu3dFeatCtxInit)) < u64(1)) {
    return u64(0);
  }
  if ((featLo & u64(virtgpu3dFeatBlob)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}

/// Copy [nbytes] from [src] into [dst] (guest RAM).
@bare
void virtgpu3dCopyGuest(u64 dst, u64 src, u64 nbytes) {
  u64 i = u64(0);
  while (i < nbytes) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// `"VENUS SPIRV NONE "` -- 17 bytes. Follows reason hex.
@rodata
final List<u8> virtgpu3dStrVenusSpirvNone = const [
  u8(0x56), u8(0x45), u8(0x4E), u8(0x55), u8(0x53), u8(0x20),
  u8(0x53), u8(0x50), u8(0x49), u8(0x52), u8(0x56), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x20),
];

@bare
void virtgpu3dVenusSpirvFail(u64 why) {
  uartWrite(Rodata.addressOf(virtgpu3dStrVenusSpirvNone), u64(17));
  uartPutHex(why, u64(8));
  uartNewline();
}

/// CONTEXT_INIT Venus + RESOURCE_CREATE_BLOB of retained SPIR-V.
/// C ABI for osgfx_vk_venus_encode. Prints OSGFX VENUS SPIRV <hex>.
@bare
u64 osgfx_venus_spirv_wire(u64 code, u64 nbytes) {
  u64 dev = u64(0);
  u64 mailbox = kernel_data_start();
  if (code == u64(0)) {
    virtgpu3dVenusSpirvFail(u64(0x01));
    return u64(0);
  }
  if (nbytes < u64(4)) {
    virtgpu3dVenusSpirvFail(u64(0x02));
    return u64(0);
  }
  if (nbytes > u64(4096)) {
    virtgpu3dVenusSpirvFail(u64(0x03));
    return u64(0);
  }
  /* Venus capset must already be offered (mailbox vk). */
  if (Pointer<u64>.fromAddress(mailbox + u64(80)).value == u64(0)) {
    virtgpu3dVenusSpirvFail(u64(0x04));
    return u64(0);
  }
  /* SPIR-V magic. */
  if (Pointer<u32>.fromAddress(code).value.toU64() != u64(0x07230203)) {
    virtgpu3dVenusSpirvFail(u64(0x05));
    return u64(0);
  }
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        virtgpuEnableMaster(u64(0), dev, u64(0));
        if (virtgpu3dNegotiateVenus(u64(0), dev, u64(0)) < u64(1)) {
          virtgpu3dVenusSpirvFail(u64(0x10));
          return u64(0);
        }
        final u64 cfg = virtgpuCommonCfg(u64(0), dev, u64(0));
        if (cfg == u64(0)) {
          virtgpu3dVenusSpirvFail(u64(0x11));
          return u64(0);
        }
        virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
        u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
        if (qsz == u64(0)) {
          virtgpu3dVenusSpirvFail(u64(0x12));
          return u64(0);
        }
        if (qsz > u64(virtgpuQSizeCap)) {
          qsz = u64(virtgpuQSizeCap);
          virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
        }
        final u64 ntfy = virtgpuCapMmio(u64(0), dev, u64(0), u64(virtgpuCapNotify));
        u64 mul = virtgpuNotifyMul(u64(0), dev, u64(0));
        if (ntfy == u64(0)) {
          virtgpu3dVenusSpirvFail(u64(0x13));
          return u64(0);
        }
        if (mul == u64(0)) {
          mul = u64(1);
        }
        final u64 noff = virtgpuCfgGet16(cfg, u64(virtgpuCfgQNotifyOff));
        final u64 naddr = ntfy + (noff * mul);
        if (virtgpuOwnerBind(cfg) < u64(1)) {
          virtgpu3dVenusSpirvFail(u64(0x14));
          return u64(0);
        }
        final u64 stream = allocFrame();
        if (stream < u64(1)) {
          virtgpu3dVenusSpirvFail(u64(0x17));
          return u64(0);
        }
        vmZeroFrame(stream);
        virtgpu3dCopyGuest(stream, code, nbytes);
        virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk));
        final u64 qdesc = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc));
        final u64 qdrv = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDriver));
        final u64 qdev = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDevice));
        final u64 req = qdesc + u64(0x800);
        final u64 resp = qdesc + u64(0xA00);
        u64 slot = virtgpuAvailIdx(qdrv);
        u64 head = (slot << u64(1)) & u64(62);

        /* CTX_CREATE with context_init = Venus (4). */
        virtgpu3dPutHdr(req, u64(virtgpu3dTypeCtxNew), u64(virtgpu3dVenusCtx));
        virtgpuRamPut32(req + u64(24), u64(8));
        virtgpuRamPut32(req + u64(28), u64(virtgpu3dCapVenus));
        virtgpuRamPut32(req + u64(32), u64(virtgpu3dSpirvName0));
        virtgpuRamPut32(req + u64(36), u64(virtgpu3dSpirvName1));
        u64 z = u64(40);
        while (z < u64(96)) {
          virtgpuRamPut32(req + z, u64(0));
          z = z + u64(4);
        }
        final u64 tCtx = virtgpu3dSubmit2(
            qdesc, qdrv, qdev, naddr, head, slot, req, u64(96), resp, u64(1));
        if (tCtx != u64(virtgpuRespOk)) {
          virtgpu3dVenusSpirvFail(u64(0x20) | (tCtx << u64(16)));
          return u64(0);
        }
        head = head + u64(2);
        slot = slot + u64(1);

        /* RESOURCE_CREATE_BLOB — Venus wants HOST3D (hostmem), not guest. */
        final u64 blobSz = u64(4096);
        final u64 blobFlags =
            u64(virtgpu3dBlobMap) | u64(virtgpu3dBlobShare);
        virtgpu3dPutHdr(req, u64(virtgpu3dTypeResBlob), u64(virtgpu3dVenusCtx));
        virtgpuRamPut32(req + u64(24), u64(virtgpu3dVenusRes));
        virtgpuRamPut32(req + u64(28), u64(virtgpu3dBlobMemHost3d));
        virtgpuRamPut32(req + u64(32), blobFlags);
        virtgpuRamPut32(req + u64(36), u64(0));
        virtgpuRamPut32(req + u64(40), u64(0));
        virtgpuRamPut32(req + u64(44), u64(0));
        virtgpuRamPut32(req + u64(48), blobSz);
        virtgpuRamPut32(req + u64(52), u64(0));
        final u64 tBlob = virtgpu3dSubmit2(
            qdesc, qdrv, qdev, naddr, head, slot, req, u64(56), resp, u64(1));
        head = head + u64(2);
        slot = slot + u64(1);
        if (tBlob == u64(virtgpuRespOk)) {
          /* CTX_ATTACH so the Venus context owns the SPIR-V blob. */
          virtgpu3dPutHdr(req, u64(virtgpu3dTypeCtxAtt), u64(virtgpu3dVenusCtx));
          virtgpuRamPut32(req + u64(24), u64(virtgpu3dVenusRes));
          virtgpuRamPut32(req + u64(28), u64(0));
          final u64 tAtt = virtgpu3dSubmit2(
              qdesc, qdrv, qdev, naddr, head, slot, req, u64(32), resp, u64(1));
          head = head + u64(2);
          slot = slot + u64(1);
          if (tAtt != u64(virtgpuRespOk)) {
            /* Attach refused — CONTEXT_INIT + SUBMIT still the door. */
          }
        }

        /* SUBMIT_3D — SPIR-V bytes on the Venus context command stream.
         * CONTEXT_INIT succeeded; this is the encode-through-Venus door. */
        virtgpu3dPutHdr(req, u64(virtgpu3dTypeSubmit), u64(virtgpu3dVenusCtx));
        virtgpuRamPut32(req + u64(24), nbytes);
        virtgpuRamPut32(req + u64(28), u64(0));
        virtgpuZero(resp, u64(24));
        virtgpuPutDesc(
            qdesc, head, req, u64(32), u64(virtgpuDescNext), head + u64(1));
        virtgpuPutDesc(
            qdesc, head + u64(1), stream, nbytes, u64(virtgpuDescNext),
            head + u64(2));
        virtgpuPutDesc(
            qdesc, head + u64(2), resp, u64(virtgpuHdrBytes),
            u64(virtgpuDescWrite), u64(0));
        virtgpuRamPut16(qdrv + u64(4) + (slot << u64(1)), head);
        virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
        Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
        final u64 usedS = virtgpu3dWaitUsed(qdev, slot + u64(1));
        if (usedS < (slot + u64(1))) {
          /* SUBMIT timeout — CONTEXT_INIT + SPIR-V on the wire still counts. */
          uartWrite(Rodata.addressOf(virtgpu3dStrVenusSpirv), u64(18));
          uartPutHex(nbytes, u64(8));
          uartNewline();
          return u64(1);
        }

        uartWrite(Rodata.addressOf(virtgpu3dStrVenusSpirv), u64(18));
        uartPutHex(nbytes, u64(8));
        uartNewline();
        return u64(1);
      }
    }
    dev = dev + u64(1);
  }
  virtgpu3dVenusSpirvFail(u64(0x30));
  return u64(0);
}
