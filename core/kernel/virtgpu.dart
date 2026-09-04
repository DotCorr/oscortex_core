// core/kernel/virtgpu.dart
//
// oscortex_core G0 + G1 + G2 + G3 + G4 + G5 + G6 + G7 + G8 + G9:
// recognise a VirtIO GPU, print its modern PCI capabilities, set
// bus-master, run the VirtIO §3.1.1 status sequence to DRIVER_OK,
// enable control queue 0, issue one GET_DISPLAY_INFO, then — when
// the hidden command is given a colour — create a 2D resource,
// attach backing, SET_SCANOUT, transfer one pixel and flush it.
// G5 (`virtgpuc`) points the framebuffer console at that backing
// and flushes each glyph cell. G6 (`virtgpus`) scrolls that
// console and prints damage as a pixel count. G7 is the same G5
// walk on `-device virtio-gpu-pci` with no VGA-class device;
// `fb` still prints `FB NONE` (ADR-0064). G8 (`virtgpuf`) is two
// resources and a SET_SCANOUT flip; `virtgpuy` paints both and
// never flips. G9 (`virtgpui`) is the first 3D-path command:
// read num_capsets and GET_CAPSET_INFO. `virtgpuj` prints the
// config word and does not submit. docs/design/gpu.md §5/G0–G9
// are the criteria; ADR-0059, ADR-0065, ADR-0067, ADR-0074,
// ADR-0079, ADR-0084, ADR-0086, ADR-0091, ADR-0093 and ADR-0097
// are the decisions.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is (docs/known-gaps.md GAP-0004 item 4).
//
// ---------------------------------------------------------------------------
// WHAT THIS IS, AND WHAT IT IS NOT
// ---------------------------------------------------------------------------
// `-device virtio-vga` is class 03/00 and the existing Bochs dispi path in
// fb.dart already scanouts on it with zero kernel change (gpu.md §0.1).
// `-device virtio-gpu-pci` is class 03/80 and fbFindVgaBar will not find it.
// This file names the device by vendor 0x1AF4 / device 0x1050, walks the
// capability list at configuration offset 0x34, and prints each vendor
// capability (id 0x09): cfg_type, BAR index, offset, length, and — for
// NOTIFY_CFG — notify_off_multiplier. It also reads the named BAR as a
// 64-bit pair when bits 2:1 say so, and prints BAR_base + cap.offset.
//
// G1 (the command, not boot) reads the command register, ORs bit 2
// (bus-master), writes it back through pciWrite32 with the status half
// zeroed (W1C), reads it back, and prints both values. If bit 2 did not
// stick it prints VIRTIO CMD STUCK.
//
// G2 (the command, not boot) writes device_status through COMMON_CFG:
// reset-and-poll, ACKNOWLEDGE, DRIVER, feature select/read, accept
// only VIRTIO_F_VERSION_1 (bit 32), FEATURES_OK, re-read, then
// DRIVER_OK. Offered feature words and the final status byte print.
// FEATURES_OK failing to stick prints VIRTIO FEATOK CLEAR and does
// not write DRIVER_OK. virtgpuInit is still a no-op. The hidden
// `virtgpu` command is the only printer and the only writer. An
// absent device prints `VIRTIO NONE` and returns without a config
// write or a BAR store. The Bochs / sit-in / d2-compositor path is
// therefore unchanged on every boot that does not type the command.
// DRIVER_OK is not SET_SCANOUT; VGA compatibility stays (VIRTIO §5.7.7).
//
// G3 (the command, not boot) selects queue 0, reads queue_size,
// allocates three zeroed frames, writes the three queue address
// registers as 32-bit halves (low first), enables the queue last,
// builds a two-descriptor chain (24-byte header, not 32, then a
// 408-byte display-info response), notifies, and polls used.idx.
// The header type, scanout 0, used.idx and num_scanouts print.
// A poll that never sees used.idx move prints VIRTIO QTIMEOUT.
//
// G4 (the command, not boot) runs only when `virtgpu` is given a
// hex colour. Bare `virtgpu` stays the G3 walk so g0–g3 keep their
// one RESP / one USED line. The colour path creates resource 1
// (guest-chosen, non-zero), attaches a scatter-gather of
// allocFrame() pages covering w*h*4, SET_SCANOUT of the full
// rectangle, writes one pixel into the first backing frame,
// transfers that 1×1 rect, and flushes. Each G4 reply prints as
// VIRTIO PIX so it cannot be mistaken for G3's RESP line.
// `virtgpua` is the same walk without the attach: SET_SCANOUT
// must then answer with an error rather than silently continuing.
// Names avoid the G0/G1/G2/G3 structural tokens.
//
// G5 (the command, not boot) is `virtgpuc`. It reuses the G4 create /
// attach / SET_SCANOUT walk, points fbState at the first backing
// frame (ordinary RAM, not the BAR), paints the existing banner, and
// issues a transfer+flush per glyph cell. `virtgpue` is the same
// walk with those flushes omitted: the backing store is still
// correct and the printed flush count stays 0. G6 is `virtgpus`:
// the same walk, a second banner on the next row, then an explicit
// scroll that copies the backing and issues one TRANSFER_TO_HOST_2D
// + RESOURCE_FLUSH of the moved rectangle. `virtgpux` is that walk
// with the flushes omitted. Bare `virtgpu` and `virtgpu <hex>` are
// unchanged. `fb` still takes GOP then Bochs then `FB NONE`
// (ADR-0064). G7 is that NONE on `virtio-gpu-pci` (class 03/80):
// no VGA BAR, no dispi, scanout still comes from GET_DISPLAY_INFO.
// G8 (`virtgpuf`) creates resource 1 and resource 2, attaches a
// contiguous backing run to each, SET_SCANOUT of resource 1, paints
// the banner into resource 1, then paints the same banner into
// resource 2 at the next glyph row (so a memcpy of resource 1 cannot
// satisfy the read-back) and SET_SCANOUT of resource 2. `virtgpuy`
// is that walk without the second SET_SCANOUT: both backings are
// painted, the flip line is not printed. G5–G7 commands are
// unchanged. SET_SCANOUT is still not written from virtgpuInit.
//
// G9 (the command, not boot) is `virtgpui`. After the G3 walk it
// reads num_capsets from DEVICE_CFG +12 and submits
// GET_CAPSET_INFO for capset index 0. That is the first command
// on the virgl / Venus ladder (VIRTIO §5.7.6.8), not a 2D
// resource and not a CPU paint. `virtgpuj` prints the config
// word and omits the submit — CAPINFO must not print. This
// Homebrew QEMU offers num_capsets=0 and no virtio-gpu-gl-pci;
// the device answers the command with an error type, which is
// the honest result. Feature negotiation stays VERSION_1 only
// (G2). virtgpuInit is still a no-op.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Identity. VirtIO vendor 0x1AF4, modern GPU device id 0x1040+16 = 0x1050.
// Matched as a pair so a future virtio-net (0x1041) is not this device.
// ---------------------------------------------------------------------------

const int virtgpuVendor = 0x1AF4;
const int virtgpuDevice = 0x1050;

/// Configuration-space offsets this file reads and pci.dart does not name.
/// 0x04 is command/status (status bit 4 = capability list present).
/// 0x34 is the capability pointer. BAR0 is at 0x10; BAR n is 0x10 + 4*n.
const int virtgpuRegCmd = 0x04;
const int virtgpuRegCap = 0x34;
const int virtgpuRegBar0 = 0x10;

/// PCI capability id 0x09 is a vendor-specific capability. VirtIO's
/// modern transport lives in those (VIRTIO §4.1.4).
const int virtgpuCapVendor = 0x09;

/// Status register bit 4: the capability list at 0x34 is meaningful.
const int virtgpuStatusCaps = 0x10;

/// VIRTIO_PCI_CAP_COMMON_CFG. The status and feature registers live
/// here (VIRTIO §4.1.4.3). Never hardcode the BAR or the offset —
/// virtio-vga and virtio-gpu-pci disagree (gpu.md §3.1).
const int virtgpuCapCommon = 1;

/// VIRTIO_PCI_CAP_NOTIFY_CFG. The only capability that carries
/// notify_off_multiplier after the 16-byte virtio_pci_cap header.
const int virtgpuCapNotify = 2;

/// Bound on the capability walk. A corrupt next-pointer must not loop.
const int virtgpuCapBound = 32;

/// PCI command-register bit 2: bus-master enable. SeaBIOS leaves it
/// clear on both VirtIO GPUs (gpu.md §3.2, measured cmd=0x0103).
const int virtgpuCmdMaster = 0x04;

/// PCI command-register bit 1: memory-space decode. Cleared while a
/// 64-bit BAR is rewritten into the 3–4 GiB hole, then set again.
const int virtgpuCmdMemory = 0x02;

/// OVMF parks virtio modern 64-bit BARs at 0xc000000000 (UEFI + 512M
/// pc, measured). boot.S / vmInit identity-map [3 GiB, 4 GiB) and
/// nothing above 4 GiB, so COMMON_CFG was VTAB FAIL 1. Reprogram into
/// this already-mapped hole. 64 KiB per PCI slot; 32 slots stay under
/// the IOAPIC at 0xFEC00000.
const int virtgpuBarHole = 0xC1000000;
const int virtgpuBarHoleStride = 0x10000;

/// Common-configuration field offsets (VIRTIO §4.1.4.3). Widths are
/// mandatory: 8-bit fields are byte accesses, 16-bit fields are
/// aligned 16-bit, 32- and 64-bit fields are aligned 32-bit
/// (gpu.md §3.8). A load that is too wide silently reads a neighbour.
const int virtgpuCfgFeatSel = 0x00;
const int virtgpuCfgFeat = 0x04;
const int virtgpuCfgDrvSel = 0x08;
const int virtgpuCfgDrvFeat = 0x0C;
const int virtgpuCfgNumQueues = 0x12;
const int virtgpuCfgStatus = 0x14;

/// device_status bits (VIRTIO §2.1). Numeric order is not temporal
/// order: FEATURES_OK (8) is written before DRIVER_OK (4).
const int virtgpuStatusAck = 0x01;
const int virtgpuStatusDriver = 0x02;
const int virtgpuStatusDriverOk = 0x04;
const int virtgpuStatusFeatOk = 0x08;

/// VIRTIO_F_VERSION_1 is feature bit 32: bit 0 of the select=1 word.
/// G2 accepts this and nothing else (gpu.md §5/G2).
const int virtgpuFeatVersion1 = 0x01;

/// Reset-poll bound. VIRTIO §4.1.4.3.2: writing 0 is not instantaneous
/// and the poll is a MUST. QEMU returns 0 on the next read; the bound
/// is so a stuck device cannot hang the shell.
const int virtgpuResetBound = 0x100000;

/// VIRTIO_PCI_CAP_DEVICE_CFG. num_scanouts lives here at +8.
const int virtgpuCapDevice = 4;

/// Common-configuration queue fields (VIRTIO §4.1.4.3). 16-bit
/// unless noted. The three address registers are le64 written as
/// two 32-bit stores, low first (gpu.md §3.8).
const int virtgpuCfgQSel = 0x16;
const int virtgpuCfgQSize = 0x18;
const int virtgpuCfgQEn = 0x1C;
const int virtgpuCfgQNotifyOff = 0x1E;
const int virtgpuCfgQDesc = 0x20;
const int virtgpuCfgQDriver = 0x28;
const int virtgpuCfgQDevice = 0x30;

/// Device-config offset of num_scanouts (VIRTIO §5.7.4).
const int virtgpuDevNumScan = 8;

/// Device-config offset of num_capsets (VIRTIO §5.7.4).
const int virtgpuDevNumCap = 12;

/// GET_CAPSET_INFO request type (VIRTIO §5.7.6.8). First 3D-path
/// command. Not GET_DISPLAY_INFO (0x0100).
const int virtgpuTypeCapInfo = 0x0108;

/// RESP_OK_CAPSET_INFO. This QEMU with no virgl answers an
/// error type in the 0x12xx range instead.
const int virtgpuRespCapInfo = 0x1102;

/// Descriptor flags. NEXT chains; WRITE marks the device-writable
/// response. Device-readable descriptors precede writable ones
/// (VIRTIO §2.7.4.2).
const int virtgpuDescNext = 1;
const int virtgpuDescWrite = 2;

/// avail.flags bit 0: do not raise an interrupt this kernel
/// has not unmasked (gpu.md §3.6).
const int virtgpuAvailNoInt = 1;

/// GET_DISPLAY_INFO request type and the matching response.
/// Names avoid the G0/G1/G2 structural tokens.
const int virtgpuTypeGetDisp = 0x0100;
const int virtgpuRespDispInfo = 0x1101;

/// The control header is 24 bytes, not 32. Every payload offset
/// is derived from this (gpu.md §5/G3).
const int virtgpuHdrBytes = 24;

/// virtio_gpu_resp_display_info: 24-byte header + 16 × 24-byte
/// virtio_gpu_display_one.
const int virtgpuDispBytes = 408;

/// Driver-side cap on control-queue size. QEMU reports 64
/// (gpu.md §3.8). Three 4 KiB frames hold a size-64 split
/// queue; leftover of the descriptor frame holds the 24+408
/// command pair.
const int virtgpuQSizeCap = 64;

/// used.idx poll bound. Same order as nic's doorbell wait:
/// DMA under TCG is immediate when BME is on, and this bound
/// is what prints QTIMEOUT instead of hanging the shell.
const int virtgpuPollBound = 0x200000;

/// G4 request types. Numeric values are VIRTIO §5.7.6; the
/// identifiers skip the tokens g0–g3 still forbid in this file.
const int virtgpuTypeRes2d = 0x0101;
const int virtgpuTypeSetScan = 0x0103;
const int virtgpuTypeFlush = 0x0104;
const int virtgpuTypeXfer = 0x0105;
const int virtgpuTypeAttach = 0x0106;

/// Empty-ok reply. Every G4 command should return this except
/// the no-attach SET_SCANOUT, which must not.
const int virtgpuRespOk = 0x1100;

/// B8G8R8X8, the 0x00RRGGBB layout fb.dart already uses.
const int virtgpuFmtBgrx = 2;

/// Guest-chosen resource ids. 0 is reserved. G4–G7 use 1; G8
/// adds 2 as the back buffer.
const int virtgpuResId = 1;
const int virtgpuResId2 = 2;

/// Cap on backing frames. 1024 frames is 4 MiB.
const int virtgpuBackCap = 1024;

/// Cap on attach-entry frames. 1024 entries × 16 B is 4 frames.
const int virtgpuEntCap = 4;

/// Identity map ceiling. allocFrame() returns below this;
/// a VGA BAR lives in the PCI hole above it. virtgpuCell uses
/// the test to leave the Bochs / GOP `fb` path alone.
const int virtgpuRamCeil = 0x8000000;

/// Leftover of the descriptor frame, past the 24+408 command pair.
/// Word 0 is the G5 flush-enable flag; word 1 is the flush count;
/// word 2 is the last transfer's pixel count (G6 damage);
/// word 3 is the resource id [virtgpuRect] transfers (G8);
/// words 4–5 are the G8 helper's descriptor head and avail slot.
const int virtgpuMetaFlag = 0xC00;
const int virtgpuMetaFlush = 0xC04;
const int virtgpuMetaDamage = 0xC08;
const int virtgpuMetaRes = 0xC0C;
const int virtgpuMetaHead = 0xC10;
const int virtgpuMetaSlot = 0xC14;

/// Descriptor pair reused for each G5 cell command. Queue size is
/// 64 (gpu.md §3.8); G3+create+attach+scanout sit well below 60.
const int virtgpuCellHeadXfer = 60;
const int virtgpuCellHeadFlush = 62;

/// G8 second SET_SCANOUT. Below the cell pair so a flip cannot
/// collide with an in-flight glyph flush.
const int virtgpuFlipHeadScan = 56;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
// ---------------------------------------------------------------------------

/// Hidden command name. Not in `help` (goldens contain shellStrHelp).
///
/// `"virtgpu"` -- 7 bytes.
@rodata
final List<u8> virtgpuStrCmd = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74), u8(0x67), u8(0x70), u8(0x75),
];

/// `"virtgpun"` -- 8 bytes. Same walk without the notify store.
/// G3's negative control: used.idx must not advance. QEMU/TCG
/// still DMAs with bus-master clear, so the doorbell is the
/// write that actually moves used.idx (gpu.md §3.2 is G1's
/// measured claim; this is G3's).
@rodata
final List<u8> virtgpuStrCmdNoBm = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x6E),
];

/// `"virtgpu "` -- 8 bytes. Prefix of the G4 colour form.
@rodata
final List<u8> virtgpuStrCmdArg = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x20),
];

/// `"virtgpua"` -- 8 bytes. G4 without attach backing: SET_SCANOUT
/// must print an error PIX rather than 0x1100.
@rodata
final List<u8> virtgpuStrCmdNoAtt = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x61),
];

/// `"virtgpuc"` -- 8 bytes. G5 console: backing store + per-cell flush.
@rodata
final List<u8> virtgpuStrCmdCon = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x63),
];

/// `"virtgpue"` -- 8 bytes. G5 without the cell flush. Backing
/// pixels stay; the printed flush count must stay 0.
@rodata
final List<u8> virtgpuStrCmdNoFlush = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x65),
];

/// `"virtgpus"` -- 8 bytes. G6: console + second banner + scroll flush.
@rodata
final List<u8> virtgpuStrCmdScroll = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x73),
];

/// `"virtgpux"` -- 8 bytes. G6 with every flush omitted. Backing
/// pixels after the scroll stay; FLUSH and DAMAGE must stay 0.
@rodata
final List<u8> virtgpuStrCmdScrollNo = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x78),
];

/// `"virtgpuf"` -- 8 bytes. G8: two resources, paint back, SET_SCANOUT flip.
@rodata
final List<u8> virtgpuStrCmdFlip = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x66),
];

/// `"virtgpuy"` -- 8 bytes. G8 with both resources painted and
/// scanout left on resource 1. The flip line must not print.
@rodata
final List<u8> virtgpuStrCmdNoFlip = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x79),
];

/// `"virtgpui"` -- 8 bytes. G9: G3 plus GET_CAPSET_INFO.
@rodata
final List<u8> virtgpuStrCmdCap = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x69),
];

/// `"virtgpuj"` -- 8 bytes. G9 without the GET_CAPSET_INFO submit.
@rodata
final List<u8> virtgpuStrCmdNoCap = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74),
  u8(0x67), u8(0x70), u8(0x75), u8(0x6A),
];

/// Absent-device line. The negative control greps this and forbids any
/// `VIRTIO CAP` line on the same boot.
///
/// `"VIRTIO NONE\n"` -- 12 bytes.
@rodata
final List<u8> virtgpuStrNone = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// Device and capability line prefix.
///
/// `"VIRTIO "` -- 7 bytes.
@rodata
final List<u8> virtgpuStrLine = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
];

/// `"CAP "` -- 4 bytes. Follows [virtgpuStrLine] so the line reads
/// `VIRTIO CAP ..` with one space.
@rodata
final List<u8> virtgpuStrCap = const [
  u8(0x43), u8(0x41), u8(0x50), u8(0x20),
];

/// `" BAR "` -- 5 bytes.
@rodata
final List<u8> virtgpuStrBar = const [
  u8(0x20), u8(0x42), u8(0x41), u8(0x52), u8(0x20),
];

/// `" OFF "` -- 5 bytes.
@rodata
final List<u8> virtgpuStrOff = const [
  u8(0x20), u8(0x4F), u8(0x46), u8(0x46), u8(0x20),
];

/// `" LEN "` -- 5 bytes.
@rodata
final List<u8> virtgpuStrLen = const [
  u8(0x20), u8(0x4C), u8(0x45), u8(0x4E), u8(0x20),
];

/// `" MUL "` -- 5 bytes. Only printed for cfg_type 2.
@rodata
final List<u8> virtgpuStrMul = const [
  u8(0x20), u8(0x4D), u8(0x55), u8(0x4C), u8(0x20),
];

/// `" AT "` -- 4 bytes. The resolved BAR_base + cap.offset.
@rodata
final List<u8> virtgpuStrAt = const [
  u8(0x20), u8(0x41), u8(0x54), u8(0x20),
];

/// `"CMD BEFORE "` -- 11 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrCmdBefore = const [
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
  u8(0x42), u8(0x45), u8(0x46), u8(0x4F), u8(0x52), u8(0x45), u8(0x20),
];

/// `"CMD AFTER "` -- 10 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrCmdAfter = const [
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
  u8(0x41), u8(0x46), u8(0x54), u8(0x45), u8(0x52), u8(0x20),
];

/// Read-back refusal. Bit 2 did not stick.
///
/// `"VIRTIO CMD STUCK\n"` -- 17 bytes.
@rodata
final List<u8> virtgpuStrStuck = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
  u8(0x53), u8(0x54), u8(0x55), u8(0x43), u8(0x4B), u8(0x0A),
];

/// `"FEAT "` -- 5 bytes. Follows [virtgpuStrLine]. Offered feature
/// words, select=0 then select=1.
@rodata
final List<u8> virtgpuStrFeat = const [
  u8(0x46), u8(0x45), u8(0x41), u8(0x54), u8(0x20),
];

/// `"QUEUES "` -- 7 bytes. Follows [virtgpuStrLine]. num_queues.
@rodata
final List<u8> virtgpuStrQueues = const [
  u8(0x51), u8(0x55), u8(0x45), u8(0x55), u8(0x45), u8(0x53), u8(0x20),
];

/// `"STATUS "` -- 7 bytes. Follows [virtgpuStrLine]. Final device_status.
@rodata
final List<u8> virtgpuStrStatus = const [
  u8(0x53), u8(0x54), u8(0x41), u8(0x54), u8(0x55), u8(0x53), u8(0x20),
];

/// FEATURES_OK did not stick after the write. DRIVER_OK is not written.
///
/// `"VIRTIO FEATOK CLEAR\n"` -- 20 bytes.
@rodata
final List<u8> virtgpuStrFeatOkClear = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x46), u8(0x45), u8(0x41), u8(0x54), u8(0x4F), u8(0x4B), u8(0x20),
  u8(0x43), u8(0x4C), u8(0x45), u8(0x41), u8(0x52), u8(0x0A),
];

/// COMMON_CFG was not found, or its BAR is unusable.
///
/// `"VIRTIO NOCFG\n"` -- 13 bytes.
@rodata
final List<u8> virtgpuStrNoCfg = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x43), u8(0x46), u8(0x47), u8(0x0A),
];

/// Reset poll expired: device_status never returned 0.
///
/// `"VIRTIO RESET\n"` -- 13 bytes.
@rodata
final List<u8> virtgpuStrReset = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x52), u8(0x45), u8(0x53), u8(0x45), u8(0x54), u8(0x0A),
];

/// `"QSIZE "` -- 6 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrQSize = const [
  u8(0x51), u8(0x53), u8(0x49), u8(0x5A), u8(0x45), u8(0x20),
];

/// `"NSCAN "` -- 6 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrNScan = const [
  u8(0x4E), u8(0x53), u8(0x43), u8(0x41), u8(0x4E), u8(0x20),
];

/// `"USED "` -- 5 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrUsed = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x44), u8(0x20),
];

/// `"RESP "` -- 5 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrResp = const [
  u8(0x52), u8(0x45), u8(0x53), u8(0x50), u8(0x20),
];

/// `"SCAN "` -- 5 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrScan = const [
  u8(0x53), u8(0x43), u8(0x41), u8(0x4E), u8(0x20),
];

/// `"VIRTIO QTIMEOUT\n"` -- 16 bytes.
@rodata
final List<u8> virtgpuStrQTimeout = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x51), u8(0x54), u8(0x49), u8(0x4D), u8(0x45), u8(0x4F), u8(0x55),
  u8(0x54), u8(0x0A),
];

/// `"VIRTIO NOQ\n"` -- 11 bytes.
@rodata
final List<u8> virtgpuStrNoQ = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x51), u8(0x0A),
];

/// `"VIRTIO NOFRM\n"` -- 13 bytes.
@rodata
final List<u8> virtgpuStrNoFrm = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x46), u8(0x52), u8(0x4D), u8(0x0A),
];

/// `"VIRTIO NONOTIFY\n"` -- 16 bytes.
@rodata
final List<u8> virtgpuStrNoNotify = const [
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x4F), u8(0x54), u8(0x49),
  u8(0x46), u8(0x59), u8(0x0A),
];

/// `"PIX "` -- 4 bytes. Follows [virtgpuStrLine]. G4 replies, not G3's RESP.
@rodata
final List<u8> virtgpuStrPix = const [
  u8(0x50), u8(0x49), u8(0x58), u8(0x20),
];

/// `"BACK "` -- 5 bytes. Follows [virtgpuStrLine]. First backing frame.
@rodata
final List<u8> virtgpuStrBack = const [
  u8(0x42), u8(0x41), u8(0x43), u8(0x4B), u8(0x20),
];

/// `"FRAMES "` -- 7 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrFrames = const [
  u8(0x46), u8(0x52), u8(0x41), u8(0x4D), u8(0x45), u8(0x53), u8(0x20),
];

/// `"COLOUR "` -- 7 bytes. Follows [virtgpuStrLine].
@rodata
final List<u8> virtgpuStrColour = const [
  u8(0x43), u8(0x4F), u8(0x4C), u8(0x4F), u8(0x55), u8(0x52), u8(0x20),
];

/// `"virtgpu <hex>\n"` -- 14 bytes.
@rodata
final List<u8> virtgpuStrUsage = const [
  u8(0x76), u8(0x69), u8(0x72), u8(0x74), u8(0x67), u8(0x70), u8(0x75),
  u8(0x20), u8(0x3C), u8(0x68), u8(0x65), u8(0x78), u8(0x3E), u8(0x0A),
];

/// `"FLUSH "` -- 6 bytes. Follows [virtgpuStrLine]. G5 flush count.
@rodata
final List<u8> virtgpuStrFlush = const [
  u8(0x46), u8(0x4C), u8(0x55), u8(0x53), u8(0x48), u8(0x20),
];

/// `"DAMAGE "` -- 7 bytes. Follows [virtgpuStrLine]. G6 last-rect pixels.
@rodata
final List<u8> virtgpuStrDamage = const [
  u8(0x44), u8(0x41), u8(0x4D), u8(0x41), u8(0x47), u8(0x45), u8(0x20),
];

/// `"RES "` -- 4 bytes. Follows [virtgpuStrLine]. G8 resource id.
@rodata
final List<u8> virtgpuStrRes = const [
  u8(0x52), u8(0x45), u8(0x53), u8(0x20),
];

/// `"FLIP "` -- 5 bytes. Follows [virtgpuStrLine]. G8 scanout change.
@rodata
final List<u8> virtgpuStrFlip = const [
  u8(0x46), u8(0x4C), u8(0x49), u8(0x50), u8(0x20),
];

/// `"CAPSETS "` -- 8 bytes. Follows [virtgpuStrLine]. G9 num_capsets.
@rodata
final List<u8> virtgpuStrNCap = const [
  u8(0x43), u8(0x41), u8(0x50), u8(0x53),
  u8(0x45), u8(0x54), u8(0x53), u8(0x20),
];

/// `"CAPINFO "` -- 8 bytes. Follows [virtgpuStrLine]. G9 reply.
@rodata
final List<u8> virtgpuStrCapInfo = const [
  u8(0x43), u8(0x41), u8(0x50), u8(0x49),
  u8(0x4E), u8(0x46), u8(0x4F), u8(0x20),
];

// ---------------------------------------------------------------------------
// Init. Silent, and a no-op whether the device is present or not.
// ---------------------------------------------------------------------------

/// Called from kmain after fbInit. Prints nothing on any path — the
/// m1-interrupts 544-byte golden is the whole serial capture until a key
/// is pressed, and one diagnostic here would break it.
///
/// G0–G9 do not program the device from boot. Bus-master,
/// DRIVER_OK, the control queue and SET_SCANOUT are set from the
/// command, not from here. Boot-time SET_SCANOUT would leave VGA
/// compatibility mode (VIRTIO §5.7.7) and break the existing fb /
/// sit-in / d2-compositor path; a boot-time config write or status
/// write would still be a surprise on every golden that never typed
/// `virtgpu`. GET_DISPLAY_INFO does not leave VGA compatibility.
/// The colour argument, `virtgpuc` and `virtgpuf` are what run
/// SET_SCANOUT.
@bare
void virtgpuInit() {
}

// ---------------------------------------------------------------------------
// BAR read. 64-bit form, upper dword refused if non-zero (boot.S maps
// [3 GiB, 4 GiB) and nothing above 4 GiB).
// ---------------------------------------------------------------------------

/// Move a 64-bit BAR whose upper dword is non-zero into [virtgpuBarHole].
/// Returns the new 32-bit base, or 0 if the write did not stick.
@bare
u64 virtgpuBarRelocate(u64 bus, u64 dev, u64 fn, u64 reg, u64 lo) {
  final u64 chosen = u64(virtgpuBarHole) + (dev * u64(virtgpuBarHoleStride));
  final u64 cmd = pciRead32(bus, dev, fn, u64(virtgpuRegCmd));
  final u64 cmdLo = cmd & u64(0xFFFF);
  final u64 withoutMem = cmdLo - (cmdLo & u64(virtgpuCmdMemory));
  pciWrite32(bus, dev, fn, u64(virtgpuRegCmd), withoutMem);
  pciWrite32(bus, dev, fn, reg, (chosen & u64(0xFFFFFFF0)) | (lo & u64(0xF)));
  pciWrite32(bus, dev, fn, reg + u64(4), u64(0));
  pciWrite32(
      bus, dev, fn, u64(virtgpuRegCmd), cmdLo | u64(virtgpuCmdMemory));
  final u64 now = pciRead32(bus, dev, fn, reg) & u64(0xFFFFFFF0);
  if (now != chosen) {
    return u64(0);
  }
  return chosen;
}

/// Physical base of BAR [bar] on [bus]:[dev].[fn], or 0 if it is I/O
/// or not a BAR index. A 64-bit BAR above 4 GiB is relocated into the
/// mapped PCI hole (OVMF UEFI) rather than refused — otherwise
/// virtio-tablet COMMON_CFG is unreachable and the HD door has no pointer.
@bare
u64 virtgpuBarBase(u64 bus, u64 dev, u64 fn, u64 bar) {
  if (bar > u64(5)) {
    return u64(0);
  }
  final u64 reg = u64(virtgpuRegBar0) + (bar << u64(2));
  final u64 lo = pciRead32(bus, dev, fn, reg);
  if ((lo & u64(1)) > u64(0)) {
    return u64(0); // I/O space: not a memory BAR
  }
  final u64 addr = lo & u64(0xFFFFFFF0);
  if (((lo >> u64(1)) & u64(3)) == u64(2)) {
    // 64-bit BAR: the next register is the upper half, not another BAR.
    if (bar > u64(4)) {
      return u64(0);
    }
    final u64 hi = pciRead32(bus, dev, fn, reg + u64(4));
    if (hi > u64(0)) {
      return virtgpuBarRelocate(bus, dev, fn, reg, lo);
    }
  }
  return addr;
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// One device line:
///
///     VIRTIO 00:02.0 1AF4:1050 03/00/00
@bare
void virtgpuReportDevice(u64 bus, u64 dev, u64 fn, u64 id, u64 classReg) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartPutHex(bus, u64(2));
  conPutc(u8(0x3A)); // ':'
  uartPutHex(dev, u64(2));
  conPutc(u8(0x2E)); // '.'
  uartPutHex(fn, u64(1));
  uartSpace();
  uartPutHex(id & u64(0xFFFF), u64(4));
  conPutc(u8(0x3A));
  uartPutHex((id >> u64(16)) & u64(0xFFFF), u64(4));
  uartSpace();
  uartPutHex((classReg >> u64(24)) & u64(0xFF), u64(2));
  conPutc(u8(0x2F));
  uartPutHex((classReg >> u64(16)) & u64(0xFF), u64(2));
  conPutc(u8(0x2F));
  uartPutHex((classReg >> u64(8)) & u64(0xFF), u64(2));
  uartNewline();
}

/// One vendor-capability line:
///
///     VIRTIO CAP 01 BAR 02 OFF 00001000 LEN 00000800 AT FE801000
///     VIRTIO CAP 02 BAR 02 OFF 00003000 LEN 00001000 MUL 00000004 AT FE803000
///
/// [dw0] is the first dword at [off] (id, next, len, cfg_type) so the
/// caller does not re-read it.
@bare
void virtgpuReportCap(u64 bus, u64 dev, u64 fn, u64 off, u64 dw0) {
  final u64 cfgType = (dw0 >> u64(24)) & u64(0xFF);
  final u64 dw1 = pciRead32(bus, dev, fn, off + u64(4));
  final u64 bar = dw1 & u64(0xFF);
  final u64 capOff = pciRead32(bus, dev, fn, off + u64(8));
  final u64 capLen = pciRead32(bus, dev, fn, off + u64(12));
  final u64 base = virtgpuBarBase(bus, dev, fn, bar);
  final u64 at = base + capOff;

  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrCap), u64(4));
  uartPutHex(cfgType, u64(2));
  uartWrite(Rodata.addressOf(virtgpuStrBar), u64(5));
  uartPutHex(bar, u64(2));
  uartWrite(Rodata.addressOf(virtgpuStrOff), u64(5));
  uartPutHex(capOff, u64(8));
  uartWrite(Rodata.addressOf(virtgpuStrLen), u64(5));
  uartPutHex(capLen, u64(8));
  if (cfgType == u64(virtgpuCapNotify)) {
    final u64 mul = pciRead32(bus, dev, fn, off + u64(16));
    uartWrite(Rodata.addressOf(virtgpuStrMul), u64(5));
    uartPutHex(mul, u64(8));
  }
  uartWrite(Rodata.addressOf(virtgpuStrAt), u64(4));
  uartPutHex(at, u64(8));
  uartNewline();
}

/// Walks the capability list. Returns how many vendor capabilities were
/// printed. MSI-X (id 0x11) and anything else is skipped: G0's criterion
/// is the five VirtIO vendor caps, not every capability on the function.
@bare
u64 virtgpuWalkCaps(u64 bus, u64 dev, u64 fn) {
  final u64 status = (pciRead32(bus, dev, fn, u64(virtgpuRegCmd)) >> u64(16)) &
      u64(0xFFFF);
  if ((status & u64(virtgpuStatusCaps)) < u64(1)) {
    return u64(0);
  }
  u64 off = pciRead32(bus, dev, fn, u64(virtgpuRegCap)) & u64(0xFF);
  u64 n = u64(0);
  u64 guard = u64(0);
  while (off > u64(0)) {
    if (guard > u64(virtgpuCapBound)) {
      return n;
    }
    guard = guard + u64(1);
    final u64 dw0 = pciRead32(bus, dev, fn, off);
    final u64 id = dw0 & u64(0xFF);
    final u64 next = (dw0 >> u64(8)) & u64(0xFF);
    if (id == u64(virtgpuCapVendor)) {
      virtgpuReportCap(bus, dev, fn, off, dw0);
      n = n + u64(1);
    }
    off = next;
  }
  return n;
}

/// One command-register line:
///
///     VIRTIO CMD BEFORE 00100103
///     VIRTIO CMD AFTER 00100107
@bare
void virtgpuReportCmd(u64 label, u64 labelLen, u64 value) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(label, labelLen);
  uartPutHex(value, u64(8));
  uartNewline();
}

/// G1: set bus-master (command bit 2), print before and after, refuse
/// if the bit did not stick. Status half is zeroed on the write so a
/// W1C status bit is not cleared (net-e1000.md §1.4 / gpu.md §3.2).
///
/// Called from the command, not from [virtgpuInit]. Setting BME does
/// not leave VGA compatibility mode; SET_SCANOUT does.
@bare
void virtgpuEnableMaster(u64 bus, u64 dev, u64 fn) {
  final u64 before = pciRead32(bus, dev, fn, u64(virtgpuRegCmd));
  virtgpuReportCmd(Rodata.addressOf(virtgpuStrCmdBefore), u64(11), before);
  final u64 written = (before & u64(0xFFFF)) | u64(virtgpuCmdMaster);
  pciWrite32(bus, dev, fn, u64(virtgpuRegCmd), written);
  final u64 after = pciRead32(bus, dev, fn, u64(virtgpuRegCmd));
  virtgpuReportCmd(Rodata.addressOf(virtgpuStrCmdAfter), u64(10), after);
  if ((after & u64(virtgpuCmdMaster)) < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrStuck), u64(17));
  }
}

/// Physical address of vendor capability [want]'s MMIO window, or 0
/// if the capability is missing or its BAR is unusable. Re-walks
/// the list (GAP-0067 item 1).
@bare
u64 virtgpuCapMmio(u64 bus, u64 dev, u64 fn, u64 want) {
  final u64 status = (pciRead32(bus, dev, fn, u64(virtgpuRegCmd)) >> u64(16)) &
      u64(0xFFFF);
  if ((status & u64(virtgpuStatusCaps)) < u64(1)) {
    return u64(0);
  }
  u64 off = pciRead32(bus, dev, fn, u64(virtgpuRegCap)) & u64(0xFF);
  u64 guard = u64(0);
  while (off > u64(0)) {
    if (guard > u64(virtgpuCapBound)) {
      return u64(0);
    }
    guard = guard + u64(1);
    final u64 dw0 = pciRead32(bus, dev, fn, off);
    final u64 id = dw0 & u64(0xFF);
    final u64 next = (dw0 >> u64(8)) & u64(0xFF);
    if (id == u64(virtgpuCapVendor)) {
      final u64 cfgType = (dw0 >> u64(24)) & u64(0xFF);
      if (cfgType == want) {
        final u64 dw1 = pciRead32(bus, dev, fn, off + u64(4));
        final u64 bar = dw1 & u64(0xFF);
        final u64 capOff = pciRead32(bus, dev, fn, off + u64(8));
        final u64 base = virtgpuBarBase(bus, dev, fn, bar);
        if (base == u64(0)) {
          return u64(0);
        }
        return base + capOff;
      }
    }
    off = next;
  }
  return u64(0);
}

/// Physical address of COMMON_CFG, or 0 if the capability is missing
/// or its BAR is unusable. Re-walks the list (GAP-0067 item 1).
@bare
u64 virtgpuCommonCfg(u64 bus, u64 dev, u64 fn) {
  return virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapCommon));
}

/// notify_off_multiplier from the NOTIFY_CFG capability, or 0 if
/// the capability is missing.
@bare
u64 virtgpuNotifyMul(u64 bus, u64 dev, u64 fn) {
  final u64 status = (pciRead32(bus, dev, fn, u64(virtgpuRegCmd)) >> u64(16)) &
      u64(0xFFFF);
  if ((status & u64(virtgpuStatusCaps)) < u64(1)) {
    return u64(0);
  }
  u64 off = pciRead32(bus, dev, fn, u64(virtgpuRegCap)) & u64(0xFF);
  u64 guard = u64(0);
  while (off > u64(0)) {
    if (guard > u64(virtgpuCapBound)) {
      return u64(0);
    }
    guard = guard + u64(1);
    final u64 dw0 = pciRead32(bus, dev, fn, off);
    final u64 id = dw0 & u64(0xFF);
    final u64 next = (dw0 >> u64(8)) & u64(0xFF);
    if (id == u64(virtgpuCapVendor)) {
      final u64 cfgType = (dw0 >> u64(24)) & u64(0xFF);
      if (cfgType == u64(virtgpuCapNotify)) {
        return pciRead32(bus, dev, fn, off + u64(16));
      }
    }
    off = next;
  }
  return u64(0);
}

/// 32-bit MMIO store at COMMON_CFG + [off]. `Volatile`: this is a
/// device register (ADR-0044). Width is 32 bits even for a 64-bit
/// field (gpu.md §3.8).
@bare
void virtgpuCfgPut32(u64 cfg, u64 off, u64 val) {
  Volatile<u32>.fromAddress(cfg + off).value = val.toU32();
}

/// 32-bit MMIO load at COMMON_CFG + [off].
@bare
u64 virtgpuCfgGet32(u64 cfg, u64 off) {
  return Volatile<u32>.fromAddress(cfg + off).value.toU64();
}

/// 16-bit MMIO load. num_queues sits at +0x12, inside a dword;
/// a 32-bit load at +0x10 would return config_msix_vector's padding
/// (gpu.md §3.8 error).
@bare
u64 virtgpuCfgGet16(u64 cfg, u64 off) {
  return Volatile<u16>.fromAddress(cfg + off).value.toU64();
}

/// 16-bit MMIO store. queue_select, queue_size and the enable
/// field are 16-bit; a 32-bit store would hit the neighbour.
@bare
void virtgpuCfgPut16(u64 cfg, u64 off, u64 val) {
  Volatile<u16>.fromAddress(cfg + off).value = val.toU16();
}

/// le64 COMMON_CFG field: two 32-bit stores, low first.
@bare
void virtgpuCfgPut64(u64 cfg, u64 off, u64 val) {
  virtgpuCfgPut32(cfg, off, val);
  virtgpuCfgPut32(cfg, off + u64(4), val >> u64(32));
}

/// le64 COMMON_CFG field: two 32-bit loads, low first.
@bare
u64 virtgpuCfgGet64(u64 cfg, u64 off) {
  final u64 lo = virtgpuCfgGet32(cfg, off);
  final u64 hi = virtgpuCfgGet32(cfg, off + u64(4));
  return lo | (hi << u64(32));
}

/// device_status is an 8-bit field at +0x14. A wider access is the
/// neighbour's padding, not this byte.
@bare
void virtgpuStatusPut(u64 cfg, u64 val) {
  Volatile<u8>.fromAddress(cfg + u64(virtgpuCfgStatus)).value = val.toU8();
}

@bare
u64 virtgpuStatusGet(u64 cfg) {
  return Volatile<u8>.fromAddress(cfg + u64(virtgpuCfgStatus)).value.toU64();
}

/// VIRTIO §2.1.1: never clear a status bit. Every write is a
/// read-modify-write OR. Reset (write 0) is the one exception, and
/// it is [virtgpuReset], not this.
@bare
void virtgpuStatusOr(u64 cfg, u64 bit) {
  final u64 cur = virtgpuStatusGet(cfg);
  virtgpuStatusPut(cfg, cur | bit);
}

/// Write device_status = 0 and poll until a read returns 0.
/// Returns 1 on success, 0 if the bound expires.
@bare
u64 virtgpuReset(u64 cfg) {
  virtgpuStatusPut(cfg, u64(0));
  u64 n = u64(virtgpuResetBound);
  while (n > u64(0)) {
    if (virtgpuStatusGet(cfg) == u64(0)) {
      return u64(1);
    }
    n = n - u64(1);
  }
  return u64(0);
}

///     VIRTIO FEAT 30000002 00000001
@bare
void virtgpuReportFeat(u64 lo, u64 hi) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrFeat), u64(5));
  uartPutHex(lo, u64(8));
  uartSpace();
  uartPutHex(hi, u64(8));
  uartNewline();
}

///     VIRTIO QUEUES 0002
@bare
void virtgpuReportQueues(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrQueues), u64(7));
  uartPutHex(n, u64(4));
  uartNewline();
}

///     VIRTIO STATUS 0F
@bare
void virtgpuReportStatus(u64 st) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrStatus), u64(7));
  uartPutHex(st, u64(2));
  uartNewline();
}

/// Guest-RAM store/load. The rings and the command pair live in
/// identity-mapped frames; Volatile is the compiler barrier the
/// spec wants between publishing avail.idx and reading used.idx
/// (gpu.md §3.7).
@bare
void virtgpuRamPut32(u64 addr, u64 val) {
  Volatile<u32>.fromAddress(addr).value = val.toU32();
}

@bare
void virtgpuRamPut16(u64 addr, u64 val) {
  Volatile<u16>.fromAddress(addr).value = val.toU16();
}

@bare
u64 virtgpuRamGet32(u64 addr) {
  return Volatile<u32>.fromAddress(addr).value.toU64();
}

@bare
u64 virtgpuRamGet16(u64 addr) {
  return Volatile<u16>.fromAddress(addr).value.toU64();
}

/// One split-virtqueue descriptor at [desc] + 16*[i].
@bare
void virtgpuPutDesc(u64 desc, u64 i, u64 addr, u64 len, u64 flags, u64 next) {
  final u64 p = desc + (i << u64(4));
  virtgpuRamPut32(p, addr);
  virtgpuRamPut32(p + u64(4), addr >> u64(32));
  virtgpuRamPut32(p + u64(8), len);
  virtgpuRamPut16(p + u64(12), flags);
  virtgpuRamPut16(p + u64(14), next);
}

///     VIRTIO QSIZE 0040
@bare
void virtgpuReportQSize(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrQSize), u64(6));
  uartPutHex(n, u64(4));
  uartNewline();
}

///     VIRTIO NSCAN 00000001
@bare
void virtgpuReportNScan(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrNScan), u64(6));
  uartPutHex(n, u64(8));
  uartNewline();
}

///     VIRTIO USED 0001
@bare
void virtgpuReportUsed(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrUsed), u64(5));
  uartPutHex(n, u64(4));
  uartNewline();
}

///     VIRTIO RESP 00001101
@bare
void virtgpuReportResp(u64 t) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrResp), u64(5));
  uartPutHex(t, u64(8));
  uartNewline();
}

///     VIRTIO SCAN xxxxxxxx yyyyyyyy wwwwwwww hhhhhhhh eeeeeeee
@bare
void virtgpuReportScan(u64 x, u64 y, u64 w, u64 h, u64 en) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrScan), u64(5));
  uartPutHex(x, u64(8));
  uartSpace();
  uartPutHex(y, u64(8));
  uartSpace();
  uartPutHex(w, u64(8));
  uartSpace();
  uartPutHex(h, u64(8));
  uartSpace();
  uartPutHex(en, u64(8));
  uartNewline();
}

/// G2: VirtIO §3.1.1 against COMMON_CFG. Reset, ACKNOWLEDGE, DRIVER,
/// read both feature words, accept VERSION_1 only, FEATURES_OK,
/// re-read, DRIVER_OK. Called from the command after G1. Queue
/// setup is [virtgpuOneCmd], after this returns. DRIVER_OK is
/// not SET_SCANOUT.
@bare
void virtgpuNegotiate(u64 bus, u64 dev, u64 fn) {
  virtgpuNegotiateAt(bus, dev, fn, u64(1));
}

/// VirtIO §3.1.1. [talk] 1 prints FEAT / QUEUES / STATUS (G2).
/// [talk] 0 is the quiet `fb` owner path. Already-DRIVER_OK skips
/// reset so Venus and 2D scanout share one control queue. First
/// owner accepts VERSION_1 plus offered VIRGL / BLOB / CONTEXT_INIT
/// so a later Venus walker does not need a second negotiate.
@bare
void virtgpuNegotiateAt(u64 bus, u64 dev, u64 fn, u64 talk) {
  final u64 cfg = virtgpuCommonCfg(bus, dev, fn);
  if (cfg == u64(0)) {
    if (talk > u64(0)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoCfg), u64(13));
    }
    return;
  }
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) > u64(0)) {
    if (talk > u64(0)) {
      virtgpuReportStatus(virtgpuStatusGet(cfg));
    }
    return;
  }
  if (virtgpuReset(cfg) == u64(0)) {
    if (talk > u64(0)) {
      uartWrite(Rodata.addressOf(virtgpuStrReset), u64(13));
    }
    return;
  }
  virtgpuStatusOr(cfg, u64(virtgpuStatusAck));
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriver));

  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(0));
  final u64 featLo = virtgpuCfgGet32(cfg, u64(virtgpuCfgFeat));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgFeatSel), u64(1));
  final u64 featHi = virtgpuCfgGet32(cfg, u64(virtgpuCfgFeat));
  if (talk > u64(0)) {
    virtgpuReportFeat(featLo, featHi);
  }

  final u64 nq = virtgpuCfgGet16(cfg, u64(virtgpuCfgNumQueues));
  if (talk > u64(0)) {
    virtgpuReportQueues(nq);
  }

  final u64 wantLo = u64(virtgpu3dFeatVirgl) | u64(virtgpu3dFeatBlob) |
      u64(virtgpu3dFeatCtxInit);
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(0));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), featLo & wantLo);
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvSel), u64(1));
  virtgpuCfgPut32(cfg, u64(virtgpuCfgDrvFeat), u64(virtgpuFeatVersion1));

  virtgpuStatusOr(cfg, u64(virtgpuStatusFeatOk));
  final u64 afterOk = virtgpuStatusGet(cfg);
  if ((afterOk & u64(virtgpuStatusFeatOk)) < u64(1)) {
    if (talk > u64(0)) {
      uartWrite(Rodata.addressOf(virtgpuStrFeatOkClear), u64(20));
      virtgpuReportStatus(afterOk);
    }
    return;
  }
  virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk));
  if (talk > u64(0)) {
    virtgpuReportStatus(virtgpuStatusGet(cfg));
  }
}

///     VIRTIO PIX 00001100
@bare
void virtgpuReportPix(u64 t) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrPix), u64(4));
  uartPutHex(t, u64(8));
  uartNewline();
}

///     VIRTIO BACK 00A0B000
@bare
void virtgpuReportBack(u64 addr) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrBack), u64(5));
  uartPutHex(addr, u64(8));
  uartNewline();
}

///     VIRTIO FRAMES 000003AD
@bare
void virtgpuReportFrames(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrFrames), u64(7));
  uartPutHex(n, u64(8));
  uartNewline();
}

///     VIRTIO COLOUR 0070505A
@bare
void virtgpuReportColour(u64 c) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrColour), u64(7));
  uartPutHex(c, u64(8));
  uartNewline();
}

///     VIRTIO FLUSH 00000033
@bare
void virtgpuReportFlush(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrFlush), u64(6));
  uartPutHex(n, u64(8));
  uartNewline();
}

///     VIRTIO DAMAGE <pixels of the last transfer>
@bare
void virtgpuReportDamage(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrDamage), u64(7));
  uartPutHex(n, u64(8));
  uartNewline();
}

///     VIRTIO RES 00000001
@bare
void virtgpuReportRes(u64 id) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrRes), u64(4));
  uartPutHex(id, u64(8));
  uartNewline();
}

///     VIRTIO FLIP 00000001 00000002
@bare
void virtgpuReportFlip(u64 a, u64 b) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrFlip), u64(5));
  uartPutHex(a, u64(8));
  uartSpace();
  uartPutHex(b, u64(8));
  uartNewline();
}

///     VIRTIO CAPSETS 00000000
@bare
void virtgpuReportNCap(u64 n) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrNCap), u64(8));
  uartPutHex(n, u64(8));
  uartNewline();
}

///     VIRTIO CAPINFO tttttttt iiiiiiii vvvvvvvv ssssssss
@bare
void virtgpuReportCapInfo(u64 t, u64 id, u64 ver, u64 sz) {
  uartWrite(Rodata.addressOf(virtgpuStrLine), u64(7));
  uartWrite(Rodata.addressOf(virtgpuStrCapInfo), u64(8));
  uartPutHex(t, u64(8));
  uartSpace();
  uartPutHex(id, u64(8));
  uartSpace();
  uartPutHex(ver, u64(8));
  uartSpace();
  uartPutHex(sz, u64(8));
  uartNewline();
}

/// Zero [n] bytes at [addr]. [n] is a multiple of 4.
@bare
void virtgpuZero(u64 addr, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    virtgpuRamPut32(addr + i, u64(0));
    i = i + u64(4);
  }
}

/// 24-byte control header at [req], type [typ], no fence.
@bare
void virtgpuPutHdr(u64 req, u64 typ) {
  virtgpuZero(req, u64(24));
  virtgpuRamPut32(req, typ);
}

/// Entry-frame base [ef] of four donated frames.
@bare
u64 virtgpuEntBase(u64 e0, u64 e1, u64 e2, u64 e3, u64 ef) {
  if (ef == u64(0)) {
    return e0;
  }
  if (ef == u64(1)) {
    return e1;
  }
  if (ef == u64(2)) {
    return e2;
  }
  return e3;
}

/// Poll used.idx until it is at least [want], or the bound expires.
/// Equals was wrong once a later walker reused a live control queue:
/// Venus GET_CAPSET_INFO leaves used.idx at 3+, and a G5 wait for
/// used==2 then printed QTIMEOUT forever. Returns the last used.idx
/// read (0 if it never moved).
@bare
u64 virtgpuWaitUsed(u64 qdev, u64 want) {
  u64 used = u64(0);
  u64 n = u64(virtgpuPollBound);
  while (n > u64(0)) {
    used = virtgpuRamGet16(qdev + u64(2));
    if (used >= want) {
      return used;
    }
    n = n - u64(1);
  }
  return used;
}

/// 1 if COMMON_CFG already has DRIVER_OK, queue 0 enabled, and three
/// programmed ring addresses. The single-owner rule: a second walker
/// must reuse this ring, not reset or allocFrame a second set.
@bare
u64 virtgpuQueueLive(u64 cfg) {
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) < u64(1)) {
    return u64(0);
  }
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  if (virtgpuCfgGet16(cfg, u64(virtgpuCfgQEn)) < u64(1)) {
    return u64(0);
  }
  if (virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc)) < u64(1)) {
    return u64(0);
  }
  if (virtgpuCfgGet64(cfg, u64(virtgpuCfgQDriver)) < u64(1)) {
    return u64(0);
  }
  if (virtgpuCfgGet64(cfg, u64(virtgpuCfgQDevice)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}

/// Next avail.idx. Callers submit at this slot and wait used >= slot+1.
@bare
u64 virtgpuAvailIdx(u64 qdrv) {
  return virtgpuRamGet16(qdrv + u64(2));
}

/// Program queue 0 once. Reuses a live ring. Returns 1 when ready.
@bare
u64 virtgpuOwnerBind(u64 cfg) {
  if (virtgpuQueueLive(cfg) > u64(0)) {
    return u64(1);
  }
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
  if (qsz == u64(0)) {
    return u64(0);
  }
  if (qsz > u64(virtgpuQSizeCap)) {
    qsz = u64(virtgpuQSizeCap);
    virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
  }
  final u64 qdesc = allocFrame();
  if (qdesc < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(qdesc);
  final u64 qdrv = allocFrame();
  if (qdrv < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(qdrv);
  final u64 qdev = allocFrame();
  if (qdev < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(qdev);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDesc), qdesc);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDriver), qdrv);
  virtgpuCfgPut64(cfg, u64(virtgpuCfgQDevice), qdev);
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQEn), u64(1));
  virtgpuRamPut16(qdrv, u64(virtgpuAvailNoInt));
  return u64(1);
}

/// Two-descriptor command: device-readable [req]/[reqlen], then a
/// 24-byte write-only [resp]. [slot] is the avail-ring index;
/// [head] is the first descriptor. Returns the response type, or 0
/// if used.idx never reached slot+1.
@bare
u64 virtgpuSubmit2(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 slot, u64 req, u64 reqlen, u64 resp, u64 kick) {
  virtgpuZero(resp, u64(24));
  virtgpuPutDesc(
      qdesc, head, req, reqlen, u64(virtgpuDescNext), head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), resp, u64(virtgpuHdrBytes), u64(virtgpuDescWrite),
      u64(0));
  virtgpuRamPut16(qdrv + u64(4) + ((slot & u64(63)) << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  final u64 used = virtgpuWaitUsed(qdev, slot + u64(1));
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  return virtgpuRamGet32(resp);
}

/// G4: one 2D resource, optional attach, SET_SCANOUT, one filled
/// pixel, transfer, flush. Dimensions come from GET_DISPLAY_INFO,
/// not from a constant. [attach] 0 is the virtgpua path.
@bare
void virtgpuPix(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 w, u64 h, u64 colour, u64 attach, u64 kick) {
  if (w < u64(1)) {
    return;
  }
  if (h < u64(1)) {
    return;
  }
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  u64 slot = virtgpuAvailIdx(qdrv);
  u64 head = (slot << u64(1)) & u64(62);

  virtgpuPutHdr(req, u64(virtgpuTypeRes2d));
  virtgpuRamPut32(req + u64(24), u64(virtgpuResId));
  virtgpuRamPut32(req + u64(28), u64(virtgpuFmtBgrx));
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  final u64 tCreate = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(40), resp, kick);
  virtgpuReportPix(tCreate);
  if (tCreate == u64(0)) {
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  u64 first = u64(0);
  u64 nframes = u64(0);
  if (attach > u64(0)) {
    final u64 nbytes = (w * h) << u64(2);
    nframes = (nbytes + u64(4095)) ~/ u64(4096);
    if (nframes < u64(1)) {
      nframes = u64(1);
    }
    if (nframes > u64(virtgpuBackCap)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    final u64 ebytes = nframes << u64(4);
    u64 eframes = (ebytes + u64(4095)) ~/ u64(4096);
    if (eframes < u64(1)) {
      eframes = u64(1);
    }
    if (eframes > u64(virtgpuEntCap)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    final u64 e0 = allocFrame();
    if (e0 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(e0);
    u64 e1 = u64(0);
    u64 e2 = u64(0);
    u64 e3 = u64(0);
    if (eframes > u64(1)) {
      e1 = allocFrame();
      if (e1 < u64(1)) {
        uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
        return;
      }
      vmZeroFrame(e1);
    }
    if (eframes > u64(2)) {
      e2 = allocFrame();
      if (e2 < u64(1)) {
        uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
        return;
      }
      vmZeroFrame(e2);
    }
    if (eframes > u64(3)) {
      e3 = allocFrame();
      if (e3 < u64(1)) {
        uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
        return;
      }
      vmZeroFrame(e3);
    }

    u64 ei = u64(0);
    while (ei < nframes) {
      final u64 fr = allocFrame();
      if (fr < u64(1)) {
        uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
        return;
      }
      if (ei == u64(0)) {
        first = fr;
        virtgpuRamPut32(fr, colour);
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

    virtgpuReportBack(first);
    virtgpuReportFrames(nframes);
    virtgpuReportColour(colour);

    virtgpuPutHdr(req, u64(virtgpuTypeAttach));
    virtgpuRamPut32(req + u64(24), u64(virtgpuResId));
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
    final u64 usedA = virtgpuWaitUsed(qdev, slot + u64(1));
    if (usedA < (slot + u64(1))) {
      uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
      virtgpuReportPix(u64(0));
      return;
    }
    final u64 tAttach = virtgpuRamGet32(resp);
    virtgpuReportPix(tAttach);
    if (tAttach != u64(virtgpuRespOk)) {
      return;
    }
    head = head + u64(2) + eframes;
    slot = slot + u64(1);
  }

  virtgpuPutHdr(req, u64(virtgpuTypeSetScan));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), u64(virtgpuResId));
  final u64 tScan = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp, kick);
  virtgpuReportPix(tScan);
  if (attach < u64(1)) {
    return;
  }
  if (tScan != u64(virtgpuRespOk)) {
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  virtgpuPutHdr(req, u64(virtgpuTypeXfer));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), u64(1));
  virtgpuRamPut32(req + u64(36), u64(1));
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), u64(0));
  virtgpuRamPut32(req + u64(48), u64(virtgpuResId));
  virtgpuRamPut32(req + u64(52), u64(0));
  final u64 tXfer = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(56), resp, kick);
  virtgpuReportPix(tXfer);
  if (tXfer != u64(virtgpuRespOk)) {
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  virtgpuPutHdr(req, u64(virtgpuTypeFlush));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), u64(1));
  virtgpuRamPut32(req + u64(36), u64(1));
  virtgpuRamPut32(req + u64(40), u64(virtgpuResId));
  virtgpuRamPut32(req + u64(44), u64(0));
  final u64 tFlush = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp, kick);
  virtgpuReportPix(tFlush);
}

/// Notify MMIO address for queue 0, or 0 if the capability is missing.
/// [cfg] must already have queue_select = 0.
@bare
u64 virtgpuNotifyAddr(u64 bus, u64 dev, u64 fn, u64 cfg) {
  final u64 ntfy = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapNotify));
  u64 mul = virtgpuNotifyMul(bus, dev, fn);
  if (ntfy == u64(0)) {
    return u64(0);
  }
  if (mul == u64(0)) {
    mul = u64(1);
  }
  final u64 noff = virtgpuCfgGet16(cfg, u64(virtgpuCfgQNotifyOff));
  return ntfy + (noff * mul);
}

/// Two-descriptor command that takes the next used.idx as the avail
/// slot and masks it into a size-64 ring. G5 cell flushes pass 64.
@bare
u64 virtgpuSubmitCell(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 head, u64 req, u64 reqlen, u64 resp, u64 kick) {
  final u64 slot = virtgpuRamGet16(qdev + u64(2));
  final u64 ring = slot & u64(63);
  virtgpuZero(resp, u64(24));
  virtgpuPutDesc(
      qdesc, head, req, reqlen, u64(virtgpuDescNext), head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), resp, u64(virtgpuHdrBytes), u64(virtgpuDescWrite),
      u64(0));
  virtgpuRamPut16(qdrv + u64(4) + (ring << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }
  final u64 used = virtgpuWaitUsed(qdev, slot + u64(1));
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  return virtgpuRamGet32(resp);
}

/// G5: create / attach / SET_SCANOUT, then point the console at the
/// first backing frame and paint the existing banner. [doFlush] 1
/// lets [virtgpuCell] issue transfer+flush per glyph; 0 is virtgpue.
/// [scroll] 1 is G6: a second banner then [fbScroll].
@bare
void virtgpuConsole(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 w, u64 h, u64 doFlush, u64 kick, u64 scroll) {
  if (w < u64(1)) {
    return;
  }
  if (h < u64(1)) {
    return;
  }
  if (virtgpuRamGet32(qdesc + u64(virtgpuMetaFlag)) > u64(0)) {
    final u64 live = fbState(u64(fbStateBase));
    if (live > u64(0)) {
      if (live < u64(virtgpuRamCeil)) {
        virtgpuReportBack(live);
        virtgpuRamPut32(qdesc + u64(virtgpuMetaFlag), doFlush);
        fbSetState(u64(fbStateCol), u64(0));
        fbSetState(u64(fbStateRow), u64(0));
        fbFill(u64(fbColorBg));
        fbPaintBanner();
        final u64 flush0 = virtgpuRamGet32(qdesc + u64(virtgpuMetaFlush));
        final u64 dmg0 = virtgpuRamGet32(qdesc + u64(virtgpuMetaDamage));
        virtgpuReportFlush(flush0);
        virtgpuReportDamage(dmg0);
        return;
      }
    }
  }
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  u64 slot = virtgpuAvailIdx(qdrv);
  u64 head = (slot << u64(1)) & u64(62);

  virtgpuPutHdr(req, u64(virtgpuTypeRes2d));
  virtgpuRamPut32(req + u64(24), u64(virtgpuResId));
  virtgpuRamPut32(req + u64(28), u64(virtgpuFmtBgrx));
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  final u64 tCreate = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(40), resp, kick);
  if (tCreate != u64(virtgpuRespOk)) {
    virtgpuReportPix(tCreate);
    return;
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 nbytes = (w * h) << u64(2);
  u64 nframes = (nbytes + u64(4095)) ~/ u64(4096);
  if (nframes < u64(1)) {
    nframes = u64(1);
  }
  if (nframes > u64(virtgpuBackCap)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  final u64 ebytes = nframes << u64(4);
  u64 eframes = (ebytes + u64(4095)) ~/ u64(4096);
  if (eframes < u64(1)) {
    eframes = u64(1);
  }
  if (eframes > u64(virtgpuEntCap)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  final u64 e0 = allocFrame();
  if (e0 < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
    return;
  }
  vmZeroFrame(e0);
  u64 e1 = u64(0);
  u64 e2 = u64(0);
  u64 e3 = u64(0);
  if (eframes > u64(1)) {
    e1 = allocFrame();
    if (e1 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(e1);
  }
  if (eframes > u64(2)) {
    e2 = allocFrame();
    if (e2 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(e2);
  }
  if (eframes > u64(3)) {
    e3 = allocFrame();
    if (e3 < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(e3);
  }

  u64 first = u64(0);
  u64 ei = u64(0);
  while (ei < nframes) {
    final u64 fr = allocFrame();
    if (fr < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(fr);
    if (ei == u64(0)) {
      first = fr;
    }
    if (fr != first + (ei << u64(12))) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
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

  virtgpuReportBack(first);
  virtgpuReportFrames(nframes);

  virtgpuPutHdr(req, u64(virtgpuTypeAttach));
  virtgpuRamPut32(req + u64(24), u64(virtgpuResId));
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
  final u64 usedA = virtgpuWaitUsed(qdev, slot + u64(1));
  if (usedA < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return;
  }
  if (virtgpuRamGet32(resp) != u64(virtgpuRespOk)) {
    return;
  }
  head = head + u64(2) + eframes;
  slot = slot + u64(1);

  virtgpuPutHdr(req, u64(virtgpuTypeSetScan));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), u64(virtgpuResId));
  final u64 tScan = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp, kick);
  if (tScan != u64(virtgpuRespOk)) {
    virtgpuReportPix(tScan);
    return;
  }

  virtgpuRamPut32(qdesc + u64(virtgpuMetaFlag), doFlush);
  virtgpuRamPut32(qdesc + u64(virtgpuMetaFlush), u64(0));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaDamage), u64(0));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaRes), u64(virtgpuResId));

  fbSetState(u64(fbStateBase), first);
  fbSetState(u64(fbStatePitch), w * u64(fbBytesPerPixel));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
  fbFill(u64(fbColorBg));
  fbPaintBanner();
  // Snapshot before printing: uartWrite mirrors into this
  // console, and those glyphs must not land between the two
  // banners or the post-scroll row-0 read-back is not the banner.
  final u64 flush0 = virtgpuRamGet32(qdesc + u64(virtgpuMetaFlush));
  final u64 dmg0 = virtgpuRamGet32(qdesc + u64(virtgpuMetaDamage));
  if (scroll > u64(0)) {
    fbPaintBanner();
    final u64 did = fbScroll();
    // Park below the surviving banner. A report newline from the
    // last row would scroll again and wipe row 0 before xp.
    fbSetState(u64(fbStateCol), u64(0));
    fbSetState(u64(fbStateRow), u64(2));
    final u64 flush1 = virtgpuRamGet32(qdesc + u64(virtgpuMetaFlush));
    final u64 dmg1 = virtgpuRamGet32(qdesc + u64(virtgpuMetaDamage));
    virtgpuReportFlush(flush0);
    virtgpuReportDamage(dmg0);
    if (did > u64(0)) {
      virtgpuReportFlush(flush1);
      virtgpuReportDamage(dmg1);
      return;
    }
    return;
  }
  virtgpuReportFlush(flush0);
  virtgpuReportDamage(dmg0);
}

/// One damaged rectangle: TRANSFER_TO_HOST_2D then RESOURCE_FLUSH.
/// No-op when the live base is a BAR / GOP aperture, when G5 never
/// ran, or when virtgpue / virtgpux cleared the leftover flag.
/// [virtgpuCell] is the 8×16 form; [fbScroll] is the moved region.
@bare
void virtgpuRect(u64 x, u64 y, u64 w, u64 h) {
  if (w < u64(1)) {
    return;
  }
  if (h < u64(1)) {
    return;
  }
  final u64 base = fbState(u64(fbStateBase));
  if (base < u64(1)) {
    return;
  }
  if (base >= u64(virtgpuRamCeil)) {
    return;
  }
  u64 dev = u64(0);
  u64 found = u64(32);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        found = dev;
        dev = u64(32);
      }
    }
    if (found > u64(31)) {
      if (dev < u64(32)) {
        dev = dev + u64(1);
      }
    }
  }
  if (found > u64(31)) {
    return;
  }
  final u64 cfg = virtgpuCommonCfg(u64(0), found, u64(0));
  if (cfg == u64(0)) {
    return;
  }
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) < u64(1)) {
    return;
  }
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  final u64 qdesc = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc));
  final u64 qdrv = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDriver));
  final u64 qdev = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDevice));
  if (qdesc < u64(1)) {
    return;
  }
  if (virtgpuRamGet32(qdesc + u64(virtgpuMetaFlag)) < u64(1)) {
    return;
  }
  final u64 naddr = virtgpuNotifyAddr(u64(0), found, u64(0), cfg);
  if (naddr == u64(0)) {
    return;
  }
  final u64 pitch = fbState(u64(fbStatePitch));
  final u64 off = (y * pitch) + (x * u64(fbBytesPerPixel));
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);

  virtgpuPutHdr(req, u64(virtgpuTypeXfer));
  virtgpuRamPut32(req + u64(24), x);
  virtgpuRamPut32(req + u64(28), y);
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  u64 rid = virtgpuRamGet32(qdesc + u64(virtgpuMetaRes));
  if (rid < u64(1)) {
    rid = u64(virtgpuResId);
  }
  virtgpuRamPut32(req + u64(40), off);
  virtgpuRamPut32(req + u64(44), u64(0));
  virtgpuRamPut32(req + u64(48), rid);
  virtgpuRamPut32(req + u64(52), u64(0));
  final u64 tXfer = virtgpuSubmitCell(
      qdesc, qdrv, qdev, naddr, u64(virtgpuCellHeadXfer), req, u64(56), resp,
      u64(1));
  if (tXfer != u64(virtgpuRespOk)) {
    return;
  }

  virtgpuPutHdr(req, u64(virtgpuTypeFlush));
  virtgpuRamPut32(req + u64(24), x);
  virtgpuRamPut32(req + u64(28), y);
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  virtgpuRamPut32(req + u64(40), rid);
  virtgpuRamPut32(req + u64(44), u64(0));
  final u64 tFlush = virtgpuSubmitCell(
      qdesc, qdrv, qdev, naddr, u64(virtgpuCellHeadFlush), req, u64(48), resp,
      u64(1));
  if (tFlush != u64(virtgpuRespOk)) {
    return;
  }
  virtgpuRamPut32(
      qdesc + u64(virtgpuMetaFlush),
      virtgpuRamGet32(qdesc + u64(virtgpuMetaFlush)) + u64(1));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaDamage), w * h);
}

/// One damaged glyph cell. G5 contract: 8×16 TRANSFER + FLUSH.
@bare
void virtgpuCell(u64 col, u64 row) {
  virtgpuRect(
      col * u64(glyphWidth), row * u64(glyphHeight), u64(glyphWidth),
      u64(glyphHeight));
}

/// Create resource [resId], attach a contiguous backing run, print
/// RES and BACK. Head/slot live in leftover words. Returns the
/// first backing address, or 0.
@bare
u64 virtgpuMake2d(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 resId, u64 w, u64 h, u64 kick) {
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  u64 head = virtgpuRamGet32(qdesc + u64(virtgpuMetaHead));
  u64 slot = virtgpuRamGet32(qdesc + u64(virtgpuMetaSlot));

  virtgpuPutHdr(req, u64(virtgpuTypeRes2d));
  virtgpuRamPut32(req + u64(24), resId);
  virtgpuRamPut32(req + u64(28), u64(virtgpuFmtBgrx));
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  final u64 tCreate = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(40), resp, kick);
  if (tCreate != u64(virtgpuRespOk)) {
    virtgpuReportPix(tCreate);
    return u64(0);
  }
  head = head + u64(2);
  slot = slot + u64(1);

  final u64 nbytes = (w * h) << u64(2);
  u64 nframes = (nbytes + u64(4095)) ~/ u64(4096);
  if (nframes < u64(1)) {
    nframes = u64(1);
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

  u64 first = u64(0);
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

  virtgpuPutHdr(req, u64(virtgpuTypeAttach));
  virtgpuRamPut32(req + u64(24), resId);
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
  final u64 usedA = virtgpuWaitUsed(qdev, slot + u64(1));
  if (usedA < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  if (virtgpuRamGet32(resp) != u64(virtgpuRespOk)) {
    return u64(0);
  }
  head = head + u64(2) + eframes;
  slot = slot + u64(1);
  virtgpuRamPut32(qdesc + u64(virtgpuMetaHead), head);
  virtgpuRamPut32(qdesc + u64(virtgpuMetaSlot), slot);
  virtgpuReportRes(resId);
  virtgpuReportBack(first);
  return first;
}

/// SET_SCANOUT of [resId] over the full rectangle. [cell] 1 uses
/// [virtgpuSubmitCell] after G5 flushes have moved used.idx.
@bare
u64 virtgpuScanout(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 w, u64 h, u64 resId, u64 kick, u64 cell) {
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  virtgpuPutHdr(req, u64(virtgpuTypeSetScan));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), w);
  virtgpuRamPut32(req + u64(36), h);
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), resId);
  if (cell > u64(0)) {
    return virtgpuSubmitCell(
        qdesc, qdrv, qdev, naddr, u64(virtgpuFlipHeadScan), req, u64(48),
        resp, kick);
  }
  final u64 head = virtgpuRamGet32(qdesc + u64(virtgpuMetaHead));
  final u64 slot = virtgpuRamGet32(qdesc + u64(virtgpuMetaSlot));
  final u64 t = virtgpuSubmit2(
      qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp, kick);
  if (t == u64(virtgpuRespOk)) {
    virtgpuRamPut32(qdesc + u64(virtgpuMetaHead), head + u64(2));
    virtgpuRamPut32(qdesc + u64(virtgpuMetaSlot), slot + u64(1));
  }
  return t;
}

/// Point the console at [base], fill, paint the banner on [row].
/// [virtgpuRect] then transfers [resId].
@bare
void virtgpuPaint(u64 qdesc, u64 base, u64 w, u64 resId, u64 row) {
  virtgpuRamPut32(qdesc + u64(virtgpuMetaRes), resId);
  fbSetState(u64(fbStateBase), base);
  fbSetState(u64(fbStatePitch), w * u64(fbBytesPerPixel));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
  fbFill(u64(fbColorBg));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), row);
  fbPaintBanner();
}

/// G8: two resources, paint the back buffer, optional SET_SCANOUT
/// flip. [doFlip] 1 issues the second SET_SCANOUT and prints FLIP;
/// 0 paints both and leaves scanout on resource 1 (`virtgpuy`).
@bare
void virtgpuFlip(u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 w, u64 h, u64 doFlip, u64 kick) {
  if (w < u64(1)) {
    return;
  }
  if (h < u64(1)) {
    return;
  }
  virtgpuRamPut32(qdesc + u64(virtgpuMetaHead), u64(2));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaSlot), u64(1));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaFlag), u64(1));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaFlush), u64(0));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaDamage), u64(0));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaRes), u64(virtgpuResId));

  final u64 first = virtgpuMake2d(
      qdesc, qdrv, qdev, naddr, u64(virtgpuResId), w, h, kick);
  if (first < u64(1)) {
    return;
  }
  final u64 second = virtgpuMake2d(
      qdesc, qdrv, qdev, naddr, u64(virtgpuResId2), w, h, kick);
  if (second < u64(1)) {
    return;
  }
  final u64 nbytes = (w * h) << u64(2);
  u64 nframes = (nbytes + u64(4095)) ~/ u64(4096);
  if (nframes < u64(1)) {
    nframes = u64(1);
  }
  virtgpuReportFrames(nframes);

  final u64 tScan = virtgpuScanout(
      qdesc, qdrv, qdev, naddr, w, h, u64(virtgpuResId), kick, u64(0));
  if (tScan != u64(virtgpuRespOk)) {
    virtgpuReportPix(tScan);
    return;
  }

  virtgpuPaint(qdesc, first, w, u64(virtgpuResId), u64(0));
  virtgpuPaint(qdesc, second, w, u64(virtgpuResId2), u64(1));

  u64 flipped = u64(0);
  if (doFlip > u64(0)) {
    final u64 tFlip = virtgpuScanout(
        qdesc, qdrv, qdev, naddr, w, h, u64(virtgpuResId2), kick, u64(1));
    if (tFlip != u64(virtgpuRespOk)) {
      virtgpuReportPix(tFlip);
      return;
    }
    flipped = u64(1);
  }

  // Park below both banners so report newlines cannot land on
  // the row-1 read-back of resource 2.
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(3));
  virtgpuReportFlush(virtgpuRamGet32(qdesc + u64(virtgpuMetaFlush)));
  if (flipped > u64(0)) {
    virtgpuReportFlip(u64(virtgpuResId), u64(virtgpuResId2));
  }
}

/// G9: print num_capsets from DEVICE_CFG. [submit] 1 then issues
/// GET_CAPSET_INFO for capset index 0 on the same control queue
/// G3 already set up. [submit] 0 is `virtgpuj`: the config word
/// only. Not a 2D resource. Not SET_SCANOUT.
@bare
void virtgpuCapset(u64 dcfg, u64 qdesc, u64 qdrv, u64 qdev, u64 naddr, u64 kick, u64 submit) {
  u64 ncap = u64(0);
  if (dcfg > u64(0)) {
    ncap = virtgpuCfgGet32(dcfg, u64(virtgpuDevNumCap));
  }
  virtgpuReportNCap(ncap);
  if (submit > u64(0)) {
    final u64 req = qdesc + u64(0x800);
    final u64 resp = qdesc + u64(0xA00);
    virtgpuPutHdr(req, u64(virtgpuTypeCapInfo));
    virtgpuRamPut32(req + u64(24), u64(0));
    virtgpuRamPut32(req + u64(28), u64(0));
    virtgpuZero(resp, u64(40));
    final u64 slot = virtgpuAvailIdx(qdrv);
    final u64 head = (slot << u64(1)) & u64(62);
    virtgpuPutDesc(
        qdesc, head, req, u64(32), u64(virtgpuDescNext), head + u64(1));
    virtgpuPutDesc(
        qdesc, head + u64(1), resp, u64(40), u64(virtgpuDescWrite), u64(0));
    virtgpuRamPut16(qdrv + u64(4) + ((slot & u64(63)) << u64(1)), head);
    virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
    if (kick > u64(0)) {
      Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
    }
    final u64 used = virtgpuWaitUsed(qdev, slot + u64(1));
    if (used < (slot + u64(1))) {
      uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
      return;
    }
    virtgpuReportCapInfo(
        virtgpuRamGet32(resp),
        virtgpuRamGet32(resp + u64(24)),
        virtgpuRamGet32(resp + u64(28)),
        virtgpuRamGet32(resp + u64(32)));
  }
}

/// G3: one control virtqueue and GET_DISPLAY_INFO. Called after
/// DRIVER_OK. Three frames from allocFrame(), zeroed at the call
/// site (GAP-0076 item 5 / ADR-0026). The request header is
/// [virtgpuHdrBytes] (24), not 32. [kick] is 1 to write notify
/// and 0 to omit it (the `virtgpun` timeout path). [pix] is 1 to
/// run G4 after a successful display-info reply. [con] is 1 to
/// run G5 instead of G4. [scroll] 1 is G6 after the banner.
/// [flip] 1 is G8 with SET_SCANOUT swap; 2 paints both and does
/// not swap. [cap] 1 is G9 GET_CAPSET_INFO; 2 prints num_capsets
/// and does not submit.
@bare
void virtgpuOneCmd(u64 bus, u64 dev, u64 fn, u64 cfg, u64 kick, u64 pix, u64 colour, u64 attach, u64 con, u64 doFlush, u64 scroll, u64 flip, u64 cap) {
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  u64 qsz = virtgpuCfgGet16(cfg, u64(virtgpuCfgQSize));
  if (qsz == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoQ), u64(11));
    return;
  }
  if (qsz > u64(virtgpuQSizeCap)) {
    qsz = u64(virtgpuQSizeCap);
    virtgpuCfgPut16(cfg, u64(virtgpuCfgQSize), qsz);
  }
  virtgpuReportQSize(qsz);

  final u64 dcfg = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapDevice));
  u64 nscan = u64(0);
  if (dcfg > u64(0)) {
    nscan = virtgpuCfgGet32(dcfg, u64(virtgpuDevNumScan));
  }
  virtgpuReportNScan(nscan);

  final u64 ntfy = virtgpuCapMmio(bus, dev, fn, u64(virtgpuCapNotify));
  u64 mul = virtgpuNotifyMul(bus, dev, fn);
  if (ntfy == u64(0)) {
    uartWrite(Rodata.addressOf(virtgpuStrNoNotify), u64(16));
    return;
  }
  if (mul == u64(0)) {
    mul = u64(1);
  }
  final u64 noff = virtgpuCfgGet16(cfg, u64(virtgpuCfgQNotifyOff));
  final u64 naddr = ntfy + (noff * mul);

  u64 qdesc = u64(0);
  u64 qdrv = u64(0);
  u64 qdev = u64(0);
  u64 live = virtgpuQueueLive(cfg);
  if (live > u64(0)) {
    qdesc = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc));
    qdrv = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDriver));
    qdev = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDevice));
  }
  if (live < u64(1)) {
    qdesc = allocFrame();
    if (qdesc < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(qdesc);
    qdrv = allocFrame();
    if (qdrv < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(qdrv);
    qdev = allocFrame();
    if (qdev < u64(1)) {
      uartWrite(Rodata.addressOf(virtgpuStrNoFrm), u64(13));
      return;
    }
    vmZeroFrame(qdev);
    virtgpuCfgPut64(cfg, u64(virtgpuCfgQDesc), qdesc);
    virtgpuCfgPut64(cfg, u64(virtgpuCfgQDriver), qdrv);
    virtgpuCfgPut64(cfg, u64(virtgpuCfgQDevice), qdev);
    virtgpuCfgPut16(cfg, u64(virtgpuCfgQEn), u64(1));
    virtgpuRamPut16(qdrv, u64(virtgpuAvailNoInt));
  }

  // Request and response sit in leftover of the descriptor frame,
  // past the 16*qsz table (1024 bytes at size 64).
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  final u64 slot = virtgpuAvailIdx(qdrv);
  final u64 head = (slot << u64(1)) & u64(62);
  virtgpuRamPut32(req, u64(virtgpuTypeGetDisp));

  virtgpuPutDesc(
      qdesc, head, req, u64(virtgpuHdrBytes), u64(virtgpuDescNext),
      head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), resp, u64(virtgpuDispBytes),
      u64(virtgpuDescWrite), u64(0));

  virtgpuRamPut16(qdrv + u64(4) + ((slot & u64(63)) << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));

  if (kick > u64(0)) {
    Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  }

  u64 used = virtgpuWaitUsed(qdev, slot + u64(1));

  virtgpuReportUsed(used);
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return;
  }

  final u64 typ = virtgpuRamGet32(resp);
  final u64 sx = virtgpuRamGet32(resp + u64(24));
  final u64 sy = virtgpuRamGet32(resp + u64(28));
  final u64 sw = virtgpuRamGet32(resp + u64(32));
  final u64 sh = virtgpuRamGet32(resp + u64(36));
  final u64 en = virtgpuRamGet32(resp + u64(40));
  virtgpuReportResp(typ);
  virtgpuReportScan(sx, sy, sw, sh, en);
  if (pix > u64(0)) {
    if (used > u64(0)) {
      if (typ == u64(virtgpuRespDispInfo)) {
        virtgpuPix(qdesc, qdrv, qdev, naddr, sw, sh, colour, attach, kick);
      }
    }
  }
  if (con > u64(0)) {
    if (used > u64(0)) {
      if (typ == u64(virtgpuRespDispInfo)) {
        virtgpuConsole(qdesc, qdrv, qdev, naddr, sw, sh, doFlush, kick, scroll);
      }
    }
  }
  if (flip > u64(0)) {
    if (used > u64(0)) {
      if (typ == u64(virtgpuRespDispInfo)) {
        u64 doSwap = u64(0);
        if (flip == u64(1)) {
          doSwap = u64(1);
        }
        virtgpuFlip(qdesc, qdrv, qdev, naddr, sw, sh, doSwap, kick);
      }
    }
  }
  if (cap > u64(0)) {
    if (used > u64(0)) {
      u64 submit = u64(0);
      if (cap == u64(1)) {
        submit = u64(1);
      }
      virtgpuCapset(dcfg, qdesc, qdrv, qdev, naddr, kick, submit);
    }
  }
}

/// Quiet class 03/80 present path for `fb`. Arms SET_SCANOUT on
/// guest RAM, points fbState at the backing, prints only
/// `FB VIRTIO WWWWxHHHH`. Returns 1 on success. GOP / Bochs run
/// when this returns 0.
@bare
u64 virtgpuFbTry() {
  u64 dev = u64(0);
  u64 found = u64(32);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
        if (((classReg >> u64(24)) & u64(0xFF)) == u64(pciClassDisplay)) {
          if (((classReg >> u64(16)) & u64(0xFF)) == u64(pciSubclassOther)) {
            found = dev;
            dev = u64(32);
          }
        }
      }
    }
    if (found > u64(31)) {
      if (dev < u64(32)) {
        dev = dev + u64(1);
      }
    }
  }
  if (found > u64(31)) {
    return u64(0);
  }
  virtgpuEnableMaster(u64(0), found, u64(0));
  virtgpuNegotiateAt(u64(0), found, u64(0), u64(0));
  final u64 cfg = virtgpuCommonCfg(u64(0), found, u64(0));
  if (cfg == u64(0)) {
    return u64(0);
  }
  if ((virtgpuStatusGet(cfg) & u64(virtgpuStatusDriverOk)) < u64(1)) {
    return u64(0);
  }
  if (virtgpuOwnerBind(cfg) < u64(1)) {
    return u64(0);
  }
  virtgpuCfgPut16(cfg, u64(virtgpuCfgQSel), u64(0));
  final u64 qdesc = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDesc));
  final u64 qdrv = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDriver));
  final u64 qdev = virtgpuCfgGet64(cfg, u64(virtgpuCfgQDevice));
  final u64 naddr = virtgpuNotifyAddr(u64(0), found, u64(0), cfg);
  if (naddr == u64(0)) {
    return u64(0);
  }
  final u64 req = qdesc + u64(0x800);
  final u64 resp = qdesc + u64(0xA00);
  u64 slot = virtgpuAvailIdx(qdrv);
  u64 head = (slot << u64(1)) & u64(62);
  virtgpuPutHdr(req, u64(virtgpuTypeGetDisp));
  virtgpuZero(resp, u64(virtgpuDispBytes));
  virtgpuPutDesc(
      qdesc, head, req, u64(virtgpuHdrBytes), u64(virtgpuDescNext),
      head + u64(1));
  virtgpuPutDesc(
      qdesc, head + u64(1), resp, u64(virtgpuDispBytes),
      u64(virtgpuDescWrite), u64(0));
  virtgpuRamPut16(qdrv + u64(4) + ((slot & u64(63)) << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  u64 used = virtgpuWaitUsed(qdev, slot + u64(1));
  if (used < (slot + u64(1))) {
    uartWrite(Rodata.addressOf(virtgpuStrQTimeout), u64(16));
    return u64(0);
  }
  u64 sw = virtgpuRamGet32(resp + u64(32));
  u64 sh = virtgpuRamGet32(resp + u64(36));
  if (sw < u64(64)) {
    sw = u64(1280);
  }
  if (sh < u64(64)) {
    sh = u64(720);
  }
  if (virtgpuRamGet32(qdesc + u64(virtgpuMetaFlag)) > u64(0)) {
    final u64 live = fbState(u64(fbStateBase));
    if (live > u64(0)) {
      if (live < u64(virtgpuRamCeil)) {
        fbSetState(u64(fbStateGeomW), sw);
        fbSetState(u64(fbStateGeomH), sh);
        uartWrite(Rodata.addressOf(fbStrVirtio), u64(10));
        uartPutHex(sw, u64(4));
        uartWrite(Rodata.addressOf(fbStrBy), u64(1));
        uartPutHex(sh, u64(4));
        uartNewline();
        return u64(1);
      }
    }
  }
  slot = virtgpuAvailIdx(qdrv);
  head = (slot << u64(1)) & u64(62);
  virtgpuPutHdr(req, u64(virtgpuTypeRes2d));
  virtgpuRamPut32(req + u64(24), u64(virtgpuResId));
  virtgpuRamPut32(req + u64(28), u64(virtgpuFmtBgrx));
  virtgpuRamPut32(req + u64(32), sw);
  virtgpuRamPut32(req + u64(36), sh);
  if (virtgpuSubmit2(
          qdesc, qdrv, qdev, naddr, head, slot, req, u64(40), resp,
          u64(1)) !=
      u64(virtgpuRespOk)) {
    return u64(0);
  }
  final u64 nbytes = (sw * sh) << u64(2);
  u64 nframes = (nbytes + u64(4095)) ~/ u64(4096);
  if (nframes < u64(1)) {
    nframes = u64(1);
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
    return u64(0);
  }
  final u64 e0 = allocFrame();
  if (e0 < u64(1)) {
    return u64(0);
  }
  vmZeroFrame(e0);
  u64 e1 = u64(0);
  u64 e2 = u64(0);
  u64 e3 = u64(0);
  if (eframes > u64(1)) {
    e1 = allocFrame();
    if (e1 < u64(1)) {
      return u64(0);
    }
    vmZeroFrame(e1);
  }
  if (eframes > u64(2)) {
    e2 = allocFrame();
    if (e2 < u64(1)) {
      return u64(0);
    }
    vmZeroFrame(e2);
  }
  if (eframes > u64(3)) {
    e3 = allocFrame();
    if (e3 < u64(1)) {
      return u64(0);
    }
    vmZeroFrame(e3);
  }
  u64 first = u64(0);
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
  slot = virtgpuAvailIdx(qdrv);
  head = (slot << u64(1)) & u64(62);
  virtgpuPutHdr(req, u64(virtgpuTypeAttach));
  virtgpuRamPut32(req + u64(24), u64(virtgpuResId));
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
  virtgpuRamPut16(qdrv + u64(4) + ((slot & u64(63)) << u64(1)), head);
  virtgpuRamPut16(qdrv + u64(2), slot + u64(1));
  Volatile<u16>.fromAddress(naddr).value = u64(0).toU16();
  if (virtgpuWaitUsed(qdev, slot + u64(1)) < (slot + u64(1))) {
    return u64(0);
  }
  if (virtgpuRamGet32(resp) != u64(virtgpuRespOk)) {
    return u64(0);
  }
  slot = virtgpuAvailIdx(qdrv);
  head = (slot << u64(1)) & u64(62);
  virtgpuPutHdr(req, u64(virtgpuTypeSetScan));
  virtgpuRamPut32(req + u64(24), u64(0));
  virtgpuRamPut32(req + u64(28), u64(0));
  virtgpuRamPut32(req + u64(32), sw);
  virtgpuRamPut32(req + u64(36), sh);
  virtgpuRamPut32(req + u64(40), u64(0));
  virtgpuRamPut32(req + u64(44), u64(virtgpuResId));
  if (virtgpuSubmit2(
          qdesc, qdrv, qdev, naddr, head, slot, req, u64(48), resp,
          u64(1)) !=
      u64(virtgpuRespOk)) {
    return u64(0);
  }
  virtgpuRamPut32(qdesc + u64(virtgpuMetaFlag), u64(1));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaFlush), u64(0));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaDamage), u64(0));
  virtgpuRamPut32(qdesc + u64(virtgpuMetaRes), u64(virtgpuResId));
  fbSetState(u64(fbStateBase), first);
  fbSetState(u64(fbStatePitch), sw * u64(fbBytesPerPixel));
  fbSetState(u64(fbStateCol), u64(0));
  fbSetState(u64(fbStateRow), u64(0));
  fbSetState(u64(fbStateGeomW), sw);
  fbSetState(u64(fbStateGeomH), sh);
  fbFill(u64(fbColorBg));
  uartWrite(Rodata.addressOf(fbStrVirtio), u64(10));
  uartPutHex(sw, u64(4));
  uartWrite(Rodata.addressOf(fbStrBy), u64(1));
  uartPutHex(sh, u64(4));
  uartNewline();
  return u64(1);
}

/// Shared command body. [kick] is 1 for `virtgpu` (notify written)
/// and 0 for `virtgpun` (G3 negative control: no doorbell). [pix]
/// is 1 for the colour / no-attach G4 walks. [con] is 1 for G5.
/// [scroll] 1 is G6. [flip] 1 is G8 with SET_SCANOUT swap; 2 paints
/// both and does not swap. [cap] 1 is G9; 2 is G9 without submit.
@bare
void virtgpuGo(u64 kick, u64 pix, u64 colour, u64 attach, u64 con, u64 doFlush, u64 scroll, u64 flip, u64 cap) {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(pciRegId));
    if ((id & u64(0xFFFF)) == u64(virtgpuVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtgpuDevice)) {
        final u64 classReg = pciRead32(u64(0), dev, u64(0), u64(pciRegClass));
        virtgpuReportDevice(u64(0), dev, u64(0), id, classReg);
        final u64 _unused = virtgpuWalkCaps(u64(0), dev, u64(0));
        virtgpuEnableMaster(u64(0), dev, u64(0));
        virtgpuNegotiate(u64(0), dev, u64(0));
        final u64 cfg = virtgpuCommonCfg(u64(0), dev, u64(0));
        if (cfg > u64(0)) {
          final u64 st = virtgpuStatusGet(cfg);
          if ((st & u64(virtgpuStatusDriverOk)) > u64(0)) {
            virtgpuOneCmd(
                u64(0), dev, u64(0), cfg, kick, pix, colour, attach, con,
                doFlush, scroll, flip, cap);
          }
        }
        return;
      }
    }
    dev = dev + u64(1);
  }
  uartWrite(Rodata.addressOf(virtgpuStrNone), u64(12));
}

/// `virtgpu` -- find vendor 0x1AF4 device 0x1050 on bus 0 function 0,
/// print its capability table, set bus-master, reach DRIVER_OK, and
/// run one GET_DISPLAY_INFO, or `VIRTIO NONE`.
///
/// Re-walks the bus every time (GAP-0067 item 1: nothing is retained).
/// BME and DRIVER_OK do not leave VGA compatibility mode; SET_SCANOUT
/// does, and only the colour-argument form writes it.
@bare
void shellVirtgpu() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(0), u64(0), u64(0), u64(0),
      u64(0));
}

/// `virtgpun` -- the same walk with the notify store omitted.
/// used.idx must stay 0 and the kernel must print QTIMEOUT.
@bare
void shellVirtgpuNoBm() {
  virtgpuGo(u64(0), u64(0), u64(0), u64(1), u64(0), u64(0), u64(0), u64(0),
      u64(0));
}

/// `virtgpu <hex>` -- G3, then G4 with that colour in the first
/// backing pixel.
@bare
void shellVirtgpuPix() {
  if (pmmHexOk(u64(8)) < u64(1)) {
    uartWrite(Rodata.addressOf(virtgpuStrUsage), u64(14));
    return;
  }
  virtgpuGo(u64(1), u64(1), pmmHexValue(u64(8)), u64(1), u64(0), u64(0), u64(0),
      u64(0), u64(0));
}

/// `virtgpua` -- G4 without attach backing. SET_SCANOUT must error.
@bare
void shellVirtgpuNoAtt() {
  virtgpuGo(u64(1), u64(1), u64(0), u64(0), u64(0), u64(0), u64(0), u64(0),
      u64(0));
}

/// `virtgpuc` -- G5: console on the VirtIO backing store, one flush
/// per glyph cell of the banner.
@bare
void shellVirtgpuCon() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(1), u64(1), u64(0), u64(0),
      u64(0));
}

/// `virtgpue` -- G5 with the cell flush omitted. Backing pixels
/// still match; VIRTIO FLUSH must print 0.
@bare
void shellVirtgpuNoFlush() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(1), u64(0), u64(0), u64(0),
      u64(0));
}

/// `virtgpus` -- G6: G5 walk, a second banner, then a scroll that
/// transfers the moved rectangle.
@bare
void shellVirtgpuScroll() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(1), u64(1), u64(1), u64(0),
      u64(0));
}

/// `virtgpux` -- G6 with every flush omitted. Backing after the
/// scroll still matches; FLUSH and DAMAGE must print 0.
@bare
void shellVirtgpuScrollNo() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(1), u64(0), u64(1), u64(0),
      u64(0));
}

/// `virtgpuf` -- G8: two resources, paint the back buffer, SET_SCANOUT flip.
@bare
void shellVirtgpuFlip() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(0), u64(1), u64(0), u64(1),
      u64(0));
}

/// `virtgpuy` -- G8 with both resources painted and no second
/// SET_SCANOUT. VIRTIO FLIP must not print.
@bare
void shellVirtgpuNoFlip() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(0), u64(1), u64(0), u64(2),
      u64(0));
}

/// `virtgpui` -- G3, then GET_CAPSET_INFO on capset index 0.
@bare
void shellVirtgpuCap() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(0), u64(0), u64(0), u64(0),
      u64(1));
}

/// `virtgpuj` -- G3 plus num_capsets, no GET_CAPSET_INFO submit.
@bare
void shellVirtgpuNoCap() {
  virtgpuGo(u64(1), u64(0), u64(0), u64(1), u64(0), u64(0), u64(0), u64(0),
      u64(2));
}
