// core/kernel/wmde.dart
//
// Compositor DE chrome: close/min, start/spotlight, reflection panel
// (ADR-0106). Panel hex pids are ADR-0136 (`osxui_hex_fb`). Title-drag
// (not body-drag) is ADR-0111, gated on `wm de`
// so d2-compositor's body-drag picture is unmoved. SE-corner resize
// (ADR-0121) is the same gate: geom w/h change, same shm, clip.
// `wm chrome` alone (d8-chrome / d8-title) keeps its exact-rect picture.
//
// No `@bss`. Level and the FAT launch-index cache live in the existing
// chrome word (low nibble = level; bit 4 = pref file; bits 8+ = launch
// list). Start and panel reuse the popover kind in word 21 (2 = start,
// 3 = panel). Right-click kind 1 is unmoved (ADR-0070). Close tears
// down the surface/slot; spawn is the existing named load (syscall
// 26's guts). Not last: D7 owns that. Title-drag is unmoved.

part of 'kmain.dart';

/// `wm chrome` writes 1. `wm de` writes this. Existing draw/hit tests
/// `> 0`, so titles and the strip still paint.
const int wmDeLevel = 2;

/// Close / min button size, inside the title strip.
const int wmBtnS = 18;

/// Gap from the title's right edge and between the two buttons.
const int wmBtnGap = 8;

/// Title-control origin Y inset. Lockstep with SESS_BTN_PAD_Y (osgfx_session.c).
/// Paint and hit-test share this; wmBtnGap stays the X pitch.
const int wmBtnPadY = 7;

/// Close affordance. Soft red — not a neon stamp.
const int wmCloseColor = 0x00D45050;

/// Min affordance.
const int wmMinColor = 0x00D4A840;

/// Start hit on the left of the taskbar. Wide enough for `Start` glyph.
const int wmStartW = 96;

const int wmStartColor = 0x00C87840;

/// Caption inset on the Start pill (`Start` = 5×8 px glyphs).
const int wmStartPadX = 28;

const int wmStartPadY = 16;

const int wmStartStemN = 5;

/// Slot caption inset (`W0` / `W1`).
const int wmSlotPadX = 12;

const int wmSlotPadY = 12;

const int wmSlotStemN = 2;

/// Notification / reflection hit on the right of the taskbar.
const int wmNoteW = 64;

const int wmNoteColor = 0x0038A070;

/// Spare bit of the chrome word. A FAT pref file (CHROME.DAT) sets it
/// on compose under `wm de`. Not a new word. Title-drag does not
/// read it.
const int wmDePrefMask = 0x10;

/// Notify strip after the pref file is present. Not the idle note,
/// not the desktop, not the start tile.
const int wmDeSetColor = 0x00F05030;

/// Start pill inset from the left screen edge (lockstep with SESS_START_MX).
const int wmStartMX = 8;

/// Hamburger Start on the left glass island (ADR-0197 / desk.c LEFT_X+HAM_OFF).
const int wmHamMX = 244;

/// Hamburger hit width (desk.c HAM_W).
const int wmHamW = 36;

/// Gap between the Start pill and the first taskbar slot.
const int wmSlotGap = 8;

/// One taskbar slot per held window (live or minimised).
/// Sized to sit in DESK's island gap (desk.c LEFT_X+LEFT_W+8).
const int wmIsleLeftX = 16;
const int wmIsleLeftW = 268;
const int wmIsleGapPad = 8;
const int wmSlotW = 72;
const int wmSlotPitch = 80;

const int wmSlot0Color = 0x00586878;

const int wmSlot1Color = 0x00485868;

/// Start / spotlight popover. Dynamic height; width lockstep with desk.c.
const int wmLaunchW = 280;

/// Typical 6-row launcher height (search + rows + pad). Live size is
/// [wmLaunchBoxH]. Kept as a const so de-* derive scripts still bind.
const int wmLaunchH = 196;

const int wmLaunchHPad = 16;

/// Alt-Tab switcher card. Dynamic width; height lockstep with desk.c.
const int wmSwitchWPad = 16;

/// Typical 6-card switcher width. Live size is [wmSwitchBoxW].
const int wmSwitchW = 400;

const int wmSwitchH = 88;

const int wmLaunchColor = 0x00C86828;

const int wmLaunchRowH = 20;

const int wmLaunchRow0 = 0x00E08040;

const int wmLaunchRow1 = 0x00D07030;

/// Reflection panel.
const int wmPanelW = 180;

const int wmPanelH = 80;

const int wmPanelColor = 0x00406080;

const int wmPanelRow0 = 0x007090B0;

const int wmPanelRow1 = 0x00507090;

/// Hex pid inset. Past the de-chrome / de-wm row-centre probe at +10.
const int wmPanelPadX = 16;

/// Same inset as Start stems: one pixel into the row band.
const int wmPanelPadY = 5;

/// Light on the blue row. Not the row, not the panel, not the desktop.
const int wmPanelFg = 0x00F0F8FF;

/// Eight hex digits, same width as uartPutHex(owner, 8).
const int wmPanelStemN = 8;

const int wmPopLaunch = 2;

const int wmPopPanel = 3;

const int wmDeLaunchMax = 6;

/// 8.3 stem inset on a launch row. Leaves the row-centre colour probe
/// (de-sitfat / de-chrome) on the band.
const int wmLabelPadX = 6;

const int wmLabelPadY = 5;

/// Light on the orange launch rows. Not the row colour.
const int wmLabelFg = 0x00F8F0E0;

/// Caption inset on the title strip. Past sit-in / de-resize (x+20)
/// and the de-wm grab probe (x+40). Left of close/min.
const int wmTitlePadX = 14;

/// 16-pixel glyph centred in a 32-pixel title.
const int wmTitlePadY = 8;

/// Dark on the pearl title. Not the title fill, not the desktop.
const int wmTitleFg = 0x00202830;

/// Three letters of `'App'` (designed caption; not a PID blob).
const int wmTitleStemN = 3;

/// Scanout label. osgfx_glyph.c. Packed u64s (GAP-0025).
@extern
external void osxui_label_fb(u64 fb, u64 pitch, u64 wh, u64 xy, u64 text, u64 nrgb);

/// Scanout hex pid. osxui.c → osxui_label. Packed u64s (GAP-0025).
@extern
external void osxui_hex_fb(u64 fb, u64 pitch, u64 wh, u64 xy, u64 value, u64 nrgb);

/// Scanout button. osxui_fb.c → osxui_button. Packed u64s (GAP-0025).
@extern
external void osxui_button_fb(u64 fb, u64 pitch, u64 fwh, u64 xy, u64 sz, u64 rrgb);

/// Close / min corner radius. Circle when wmBtnR == wmBtnS/2.
const int wmBtnR = 9;

/// Start corner radius. Pill when ~ half of Start height.
const int wmStartR = 18;

/// SE-corner resize handle, in pixels. Inside the decorated window
/// (content plus border). Not the title, not close/min. ADR-0121.
const int wmResizeEdge = 8;

/// Smallest geom after a resize. Title plus a body strip; close/min
/// still fit. Growing past the attach shm is refused (clip).
const int wmResizeMinW = 80;

const int wmResizeMinH = 64;

/// `'wm de'` -- 5 bytes.
@rodata
final List<u8> wmStrCmdDe = const [
  u8(0x77), u8(0x6D), u8(0x20), u8(0x64), u8(0x65),
];

/// `'WM DE ON'` -- 8 bytes.
@rodata
final List<u8> wmStrDeOn = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x20), u8(0x4F),
  u8(0x4E),
];

/// `'WM DE SET ON'` -- 12 bytes. Printed once when the pref file is
/// first seen under `wm de`.
@rodata
final List<u8> wmStrDeSetOn = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x20), u8(0x53),
  u8(0x45), u8(0x54), u8(0x20), u8(0x4F), u8(0x4E),
];

/// 8.3 `CHROME.DAT` as a directory name. Walked the same way start
/// already walks the root.
@rodata
final List<u8> wmStrPrefName = const [
  u8(0x43), u8(0x48), u8(0x52), u8(0x4F), u8(0x4D), u8(0x45), u8(0x20),
  u8(0x20), u8(0x44), u8(0x41), u8(0x54),
];

/// `'CHROME.DAT'` -- 10 bytes. fatParseAt path form.
@rodata
final List<u8> wmStrPrefPath = const [
  u8(0x43), u8(0x48), u8(0x52), u8(0x4F), u8(0x4D), u8(0x45), u8(0x2E),
  u8(0x44), u8(0x41), u8(0x54),
];

/// `'WM PREF '` -- 8 bytes.
@rodata
final List<u8> wmStrPref = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x46),
  u8(0x20),
];

/// `'WM PREF ACK '` -- 12 bytes.
@rodata
final List<u8> wmStrPrefAck = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x46),
  u8(0x20), u8(0x41), u8(0x43), u8(0x4B), u8(0x20),
];

/// `'WM CLOSE W '` -- 11 bytes.
@rodata
final List<u8> wmStrClose = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x4C), u8(0x4F), u8(0x53),
  u8(0x45), u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM CSDHIT '` -- 10 bytes. Live geom + control AABB + pointer at press.
@rodata
final List<u8> wmStrCsdHit = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x43), u8(0x53), u8(0x44), u8(0x48),
  u8(0x49), u8(0x54), u8(0x20),
];

/// `'WM LIFE '` -- 8 bytes. Slot / SHM / chrome reclaim after close.
@rodata
final List<u8> wmStrLife = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4C), u8(0x49), u8(0x46), u8(0x45),
  u8(0x20),
];

/// `' SHM '` -- 5 bytes.
@rodata
final List<u8> wmStrShm = const [
  u8(0x20), u8(0x53), u8(0x48), u8(0x4D), u8(0x20),
];

/// `' CH '` -- 4 bytes. Chrome-cache key present (0 = reclaimed).
@rodata
final List<u8> wmStrCh = const [
  u8(0x20), u8(0x43), u8(0x48), u8(0x20),
];

/// `' LV '` -- 4 bytes. Live titled+panel window count.
@rodata
final List<u8> wmStrLv = const [
  u8(0x20), u8(0x4C), u8(0x56), u8(0x20),
];

/// `' T '` -- 3 bytes. Top window id on a CSDHIT line.
@rodata
final List<u8> wmStrT = const [
  u8(0x20), u8(0x54), u8(0x20),
];

/// `' HIT '` -- 5 bytes.
@rodata
final List<u8> wmStrHit = const [
  u8(0x20), u8(0x48), u8(0x49), u8(0x54), u8(0x20),
];

/// `' GH '` -- 4 bytes. wmDeGeomHit result.
@rodata
final List<u8> wmStrGh = const [
  u8(0x20), u8(0x47), u8(0x48), u8(0x20),
];

/// `' CX '` -- 4 bytes. Close-control origin X.
@rodata
final List<u8> wmStrCx = const [
  u8(0x20), u8(0x43), u8(0x58), u8(0x20),
];

/// `' CY '` -- 4 bytes. Close-control origin Y.
@rodata
final List<u8> wmStrCy = const [
  u8(0x20), u8(0x43), u8(0x59), u8(0x20),
];

/// `' PX '` -- 4 bytes. Pointer X at the press.
@rodata
final List<u8> wmStrPxCsd = const [
  u8(0x20), u8(0x50), u8(0x58), u8(0x20),
];

/// `' PY '` -- 4 bytes. Pointer Y at the press.
@rodata
final List<u8> wmStrPyCsd = const [
  u8(0x20), u8(0x50), u8(0x59), u8(0x20),
];

/// `' D '` -- 3 bytes. wmMetaDrag.
@rodata
final List<u8> wmStrD = const [
  u8(0x20), u8(0x44), u8(0x20),
];

/// `' K '` -- 3 bytes. Chrome-cache key (low 16).
@rodata
final List<u8> wmStrK = const [
  u8(0x20), u8(0x4B), u8(0x20),
];

/// `'WM MIN W '` -- 9 bytes.
@rodata
final List<u8> wmStrMin = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4D), u8(0x49), u8(0x4E), u8(0x20),
  u8(0x57), u8(0x20),
];

/// `'WM MAX W '` -- 9 bytes.
@rodata
final List<u8> wmStrMax = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x4D), u8(0x41), u8(0x58), u8(0x20),
  u8(0x57), u8(0x20),
];

/// `'WM HOLD W '` -- 10 bytes. Request is pending; scanout stays on VIS.
@rodata
final List<u8> wmStrHold = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x48), u8(0x4F), u8(0x4C), u8(0x44),
  u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM REQ W '` -- 9 bytes. Requested/logical geom (client configure).
@rodata
final List<u8> wmStrReq = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x51),
  u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM PEND W '` -- 10 bytes. Not visible; hit-test stays on VIS.
@rodata
final List<u8> wmStrPendTok = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x45), u8(0x4E), u8(0x44),
  u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM VIS W '` -- 9 bytes. Committed present generation + AABB.
@rodata
final List<u8> wmStrVis = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x56), u8(0x49), u8(0x53),
  u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM PHZ MAX'` -- 10 bytes.
@rodata
final List<u8> wmStrPhzMax = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x48), u8(0x5A), u8(0x20),
  u8(0x4D), u8(0x41), u8(0x58),
];

/// `'WM HOLD WD W '` -- 13 bytes. Watchdog re-enqueue.
@rodata
final List<u8> wmStrHoldWd = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x48), u8(0x4F), u8(0x4C), u8(0x44),
  u8(0x20), u8(0x57), u8(0x44), u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM HOLD RE W '` -- 13 bytes. Retry an unpublished HOLD.
@rodata
final List<u8> wmStrHoldRe = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x48), u8(0x4F), u8(0x4C), u8(0x44),
  u8(0x20), u8(0x52), u8(0x45), u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM HOLD TO W '` -- 13 bytes. Timeout cancel; VIS restored.
@rodata
final List<u8> wmStrHoldTo = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x48), u8(0x4F), u8(0x4C), u8(0x44),
  u8(0x20), u8(0x54), u8(0x4F), u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM REST W '` -- 10 bytes.
@rodata
final List<u8> wmStrRest = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x53), u8(0x54),
  u8(0x20), u8(0x57), u8(0x20),
];

/// `'WM DEFN ENQ '` -- 12 bytes.
@rodata
final List<u8> wmStrDefEnq = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x46), u8(0x4E),
  u8(0x20), u8(0x45), u8(0x4E), u8(0x51), u8(0x20),
];

/// `'WM DEFN BEGIN '` -- 14 bytes.
@rodata
final List<u8> wmStrDefBegin = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x46), u8(0x4E),
  u8(0x20), u8(0x42), u8(0x45), u8(0x47), u8(0x49), u8(0x4E), u8(0x20),
];

/// `'WM DEFN COMMIT '` -- 15 bytes.
@rodata
final List<u8> wmStrDefCommit = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x46), u8(0x4E),
  u8(0x20), u8(0x43), u8(0x4F), u8(0x4D), u8(0x4D), u8(0x49), u8(0x54),
  u8(0x20),
];

/// `'WM IRQ '` -- 7 bytes. PIT ticks spent in the input enqueue.
@rodata
final List<u8> wmStrIrq = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x49), u8(0x52), u8(0x51), u8(0x20),
];

/// `'WM PREP MAX'` -- 11 bytes. Idle chrome prep, no visible toggle.
@rodata
final List<u8> wmStrPrepMax = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x50),
  u8(0x20), u8(0x4D), u8(0x41), u8(0x58),
];

/// `'WM IFHOLD '` -- 10 bytes. reason + PIT ticks of a long IF-clear.
@rodata
final List<u8> wmStrIfHold = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x49), u8(0x46), u8(0x48), u8(0x4F),
  u8(0x4C), u8(0x44), u8(0x20),
];

/// `'WM IFSTI '` -- 9 bytes. Syscall opened interrupts for long work.
@rodata
final List<u8> wmStrIfSti = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x49), u8(0x46), u8(0x53), u8(0x54),
  u8(0x49), u8(0x20),
];

/// `'WM FOCUS '` -- 9 bytes.
@rodata
final List<u8> wmStrFocus = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x46), u8(0x4F), u8(0x43), u8(0x55),
  u8(0x53), u8(0x20),
];

/// `'WM DE START '` -- 12 bytes.
@rodata
final List<u8> wmStrDeStart = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x20), u8(0x53),
  u8(0x54), u8(0x41), u8(0x52), u8(0x54), u8(0x20),
];

/// `'WM DE LIST '` -- 11 bytes.
@rodata
final List<u8> wmStrDeList = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x20), u8(0x4C),
  u8(0x49), u8(0x53), u8(0x54), u8(0x20),
];

/// `'WM DE SURF '` -- 11 bytes.
@rodata
final List<u8> wmStrDeSurf = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x20), u8(0x53),
  u8(0x55), u8(0x52), u8(0x46), u8(0x20),
];

/// `'WM DE SPAWN '` -- 12 bytes.
@rodata
final List<u8> wmStrDeSpawn = const [
  u8(0x57), u8(0x4D), u8(0x20), u8(0x44), u8(0x45), u8(0x20), u8(0x53),
  u8(0x50), u8(0x41), u8(0x57), u8(0x4E), u8(0x20),
];

/// `' App '` -- 5 bytes.
@rodata
final List<u8> wmStrPid = const [
  u8(0x20), u8(0x41), u8(0x70), u8(0x70), u8(0x20),
];

/// `'App'` -- 3 bytes. Title-bar stem through osxui_label_fb.
@rodata
final List<u8> wmStrTitlePid = const [
  u8(0x41), u8(0x70), u8(0x70),
];

/// `'Start'` -- 5 bytes. Taskbar Start tile through osxui_label_fb.
@rodata
final List<u8> wmStrStartTile = const [
  u8(0x53), u8(0x74), u8(0x61), u8(0x72), u8(0x74),
];

/// `'W0'` -- 2 bytes. Taskbar slot 0 caption (unknown).
@rodata
final List<u8> wmStrSlot0 = const [
  u8(0x57), u8(0x30),
];

/// `'W1'` -- 2 bytes. Taskbar slot 1 caption (unknown).
@rodata
final List<u8> wmStrSlot1 = const [
  u8(0x57), u8(0x31),
];

/// Eight-byte zero-padded stems for WM_SCREEN_NAME / task pills.
@rodata
final List<u8> wmStrCapFiles = const [
  u8(0x46), u8(0x49), u8(0x4C), u8(0x45), u8(0x53), u8(0), u8(0), u8(0),
];
@rodata
final List<u8> wmStrCapSet = const [
  u8(0x53), u8(0x45), u8(0x54), u8(0), u8(0), u8(0), u8(0), u8(0),
];
@rodata
final List<u8> wmStrCapBrowse = const [
  u8(0x42), u8(0x52), u8(0x4F), u8(0x57), u8(0x53), u8(0x45), u8(0), u8(0),
];
@rodata
final List<u8> wmStrCapPlay = const [
  u8(0x50), u8(0x4C), u8(0x41), u8(0x59), u8(0), u8(0), u8(0), u8(0),
];
@rodata
final List<u8> wmStrCapStudio = const [
  u8(0x53), u8(0x54), u8(0x55), u8(0x44), u8(0x49), u8(0x4F), u8(0), u8(0),
];
@rodata
final List<u8> wmStrCapTap = const [
  u8(0x54), u8(0x41), u8(0x50), u8(0), u8(0), u8(0), u8(0), u8(0),
];
@rodata
final List<u8> wmStrCapPing = const [
  u8(0x50), u8(0x49), u8(0x4E), u8(0x47), u8(0), u8(0), u8(0), u8(0),
];

@bare
u64 wmCapStem(u64 cap) {
  if (cap == u64(2)) {
    return Rodata.addressOf(wmStrCapSet);
  }
  if (cap == u64(3)) {
    return Rodata.addressOf(wmStrCapBrowse);
  }
  if (cap == u64(4)) {
    return Rodata.addressOf(wmStrCapPlay);
  }
  if (cap == u64(5)) {
    return Rodata.addressOf(wmStrCapStudio);
  }
  if (cap == u64(6)) {
    return Rodata.addressOf(wmStrCapTap);
  }
  if (cap == u64(7)) {
    return Rodata.addressOf(wmStrCapPing);
  }
  if (cap == u64(1)) {
    return Rodata.addressOf(wmStrCapFiles);
  }
  return Rodata.addressOf(wmStrSlot0);
}

/// 1 if `wm de` is on.
@bare
u64 wmDeOn() {
  if ((wmMeta(u64(wmMetaChrome)) & u64(0xF)) >= u64(wmDeLevel)) {
    return u64(1);
  }
  return u64(0);
}

/// 1 if the pref bit is already set on the chrome word.
@bare
u64 wmDePrefOn() {
  if ((wmMeta(u64(wmMetaChrome)) & u64(wmDePrefMask)) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

/// Notify colour: idle note, or the pref colour after CHROME.DAT.
@bare
u64 wmDeNoteColor() {
  if (wmDePrefOn() > u64(0)) {
    return u64(wmDeSetColor);
  }
  return u64(wmNoteColor);
}

/// How many spawnable ELF names `wm de` cached.
@bare
u64 wmDeLaunchN() {
  return (wmMeta(u64(wmMetaChrome)) >> u64(8)) & u64(0xFF);
}

/// Directory index of launch row [row], or 0xFF if empty.
@bare
u64 wmDeLaunchIdx(u64 row) {
  return (wmMeta(u64(wmMetaChrome)) >> (u64(16) + (row << u64(3)))) &
      u64(0xFF);
}

/// 1 if window [wI] is held (live or minimised). Low byte is the
/// state; bits 8+ may name a subsurface parent (ADR-0184).
@bare
u64 wmWindowHeld(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  final u64 st = wmWin(wI, u64(wmWinState)) & u64(0xFF);
  if (st == u64(wmWinLive)) {
    return u64(1);
  }
  if (st == u64(wmWinMin)) {
    return u64(1);
  }
  return u64(0);
}

/// 1 if the region named by window [wI] is still that region.
@bare
u64 wmWindowRegionLive(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  final u64 r = wmWin(wI, u64(wmWinReg));
  if (r >= u64(shmMax)) {
    return u64(0);
  }
  if (shmReg(r, u64(shmRegState)) != u64(shmRegLive)) {
    return u64(0);
  }
  if (shmReg(r, u64(shmRegGen)) != wmWin(wI, u64(wmWinGen))) {
    return u64(0);
  }
  return u64(1);
}

/// Close-button origin X for window [wI].
/// Absolute origin + live width: same formula as session paint
/// (`win_close_x`) so a cache blit cannot leave the vacated disc live.
@bare
u64 wmCloseX(u64 wI) {
  final u64 g = wmHitGeom(wI);
  return wmHitAbsX(wI) + wmGeomW(g) - u64(wmBtnGap) - u64(wmBtnS);
}

/// Min-button origin X for window [wI].
@bare
u64 wmMinX(u64 wI) {
  return wmCloseX(wI) - u64(wmBtnGap) - u64(wmBtnS);
}

/// Maximise-button origin X for window [wI].
@bare
u64 wmMaxX(u64 wI) {
  return wmMinX(wI) - u64(wmBtnGap) - u64(wmBtnS);
}

/// Title-button origin Y for window [wI].
/// [wmBtnPadY] matches SESS_BTN_PAD_Y. Absolute Y matches [wmTitleHit].
@bare
u64 wmBtnY(u64 wI) {
  final u64 g = wmHitGeom(wI);
  u64 y = wmHitAbsY(wI) + u64(wmBtnPadY);
  u64 th = u64(wmTitleH);
  if (th > wmGeomH(g)) {
    th = wmGeomH(g);
  }
  if (y + u64(wmBtnS) > wmHitAbsY(wI) + th) {
    y = wmHitAbsY(wI);
  }
  return y;
}

/// 1 if DE is on and ([x], [y]) is on window [wI]'s close affordance.
@bare
u64 wmCloseHit(u64 wI, u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 bx = wmCloseX(wI);
  final u64 by = wmBtnY(wI);
  if (x < bx) {
    return u64(0);
  }
  if (y < by) {
    return u64(0);
  }
  if (x >= (bx + u64(wmBtnS))) {
    return u64(0);
  }
  if (y >= (by + u64(wmBtnS))) {
    return u64(0);
  }
  return u64(1);
}

/// 1 if DE is on and ([x], [y]) is on window [wI]'s min affordance.
@bare
u64 wmMinHit(u64 wI, u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 bx = wmMinX(wI);
  final u64 by = wmBtnY(wI);
  if (x < bx) {
    return u64(0);
  }
  if (y < by) {
    return u64(0);
  }
  if (x >= (bx + u64(wmBtnS))) {
    return u64(0);
  }
  if (y >= (by + u64(wmBtnS))) {
    return u64(0);
  }
  return u64(1);
}

@bare
u64 wmMaxHit(u64 wI, u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 bx = wmMaxX(wI);
  final u64 by = wmBtnY(wI);
  if (x < bx) {
    return u64(0);
  }
  if (y < by) {
    return u64(0);
  }
  if (x >= (bx + u64(wmBtnS))) {
    return u64(0);
  }
  if (y >= (by + u64(wmBtnS))) {
    return u64(0);
  }
  return u64(1);
}

/// UART the live title-control source of truth at this press.
@bare
void wmCsdNote(u64 hit, u64 geomHit, u64 x, u64 y) {
  final u64 top = wmMeta(u64(wmMetaTop));
  u64 gx = u64(0);
  u64 gy = u64(0);
  u64 gw = u64(0);
  u64 gh = u64(0);
  u64 cx = u64(0);
  u64 cy = u64(0);
  u64 key = u64(0);
  u64 slot = hit;
  if (slot >= u64(wmMaxWindows)) {
    slot = geomHit;
  }
  if (slot < u64(wmMaxWindows)) {
    final u64 g = wmViewGeom(slot);
    gx = wmAbsX(slot);
    gy = wmAbsY(slot);
    gw = wmGeomW(g);
    gh = wmGeomH(g);
    cx = wmCloseX(slot);
    cy = wmBtnY(slot);
  }
  if (wmPageAddr() > u64(0)) {
    key = wmPage(u64(wmPageWChromeHave));
  }
  uartWrite(Rodata.addressOf(wmStrCsdHit), u64(10));
  uartWrite(Rodata.addressOf(wmStrT), u64(3));
  uartPutHex(top, u64(1));
  uartWrite(Rodata.addressOf(wmStrHit), u64(5));
  uartPutHex(hit, u64(1));
  uartWrite(Rodata.addressOf(wmStrGh), u64(4));
  uartPutHex(geomHit, u64(1));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(gx, u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(gy, u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(gw, u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(gh, u64(4));
  uartWrite(Rodata.addressOf(wmStrCx), u64(4));
  uartPutHex(cx, u64(4));
  uartWrite(Rodata.addressOf(wmStrCy), u64(4));
  uartPutHex(cy, u64(4));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(x, u64(4));
  uartWrite(Rodata.addressOf(wmStrPyCsd), u64(4));
  uartPutHex(y, u64(4));
  uartWrite(Rodata.addressOf(wmStrD), u64(3));
  uartPutHex(wmMeta(u64(wmMetaDrag)), u64(2));
  uartWrite(Rodata.addressOf(wmStrK), u64(3));
  uartPutHex(key, u64(4));
  uartNewline();
}

/// Live windows, SHM pages, chrome key, close/reap high-water.
@bare
void wmLifeNote() {
  u64 shm = shmLivePages();
  u64 ch = u64(0);
  u64 closes = u64(0);
  u64 reaps = u64(0);
  u64 shmHi = shm;
  if (wmPageAddr() > u64(0)) {
    if (wmPage(u64(wmPageWChromeHave)) > u64(0)) {
      ch = u64(1);
    }
    closes = wmPage(u64(wmPageWLifeClose));
    reaps = wmPage(u64(wmPageWLifeReap));
    shmHi = wmPage(u64(wmPageWLifeShmHi));
    if (shm > shmHi) {
      shmHi = shm;
      wmPageSet(u64(wmPageWLifeShmHi), shmHi);
    }
    if (ch > wmPage(u64(wmPageWLifeCacheHi))) {
      wmPageSet(u64(wmPageWLifeCacheHi), ch);
    }
  }
  uartWrite(Rodata.addressOf(wmStrLife), u64(8));
  uartWrite(Rodata.addressOf(wmStrLv), u64(4));
  uartPutHex(wmMeta(u64(wmMetaLive)), u64(2));
  uartWrite(Rodata.addressOf(wmStrShm), u64(5));
  uartPutHex(shm, u64(4));
  uartWrite(Rodata.addressOf(wmStrCh), u64(4));
  uartPutHex(ch, u64(1));
  uartWrite(Rodata.addressOf(wmStrR), u64(3));
  uartPutHex(reaps, u64(4));
  uartWrite(Rodata.addressOf(wmStrC), u64(3));
  uartPutHex(closes, u64(4));
  uartNewline();
}

/// Packed geom the compositor last presented for [wI], or requested if
/// none has been published yet.
@bare
u64 wmVisGeom(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (wmPageAddr() < u64(1)) {
    return wmWin(wI, u64(wmWinGeom));
  }
  final u64 v = wmPage(wmPageVisOf(wI));
  if (v < u64(1)) {
    return wmWin(wI, u64(wmWinGeom));
  }
  return v;
}

/// Pending requested geom, or 0 when scanout matches the client.
@bare
u64 wmPendGeomOf(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (wmPageAddr() < u64(1)) {
    return u64(0);
  }
  return wmPage(wmPagePendOf(wI));
}

/// Compose / blit destination: VIS while a size HOLD is open (pend set
/// and client seq==0). After COMMIT the client buffer matches requested,
/// so paint uses that AABB. Hit-test must not follow this jump — see
/// [wmHitGeom].
@bare
u64 wmViewGeom(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  final u64 pend = wmPendGeomOf(wI);
  if (pend > u64(0)) {
    if (wmWin(wI, u64(wmWinSeq)) < u64(1)) {
      return wmVisGeom(wI);
    }
  }
  return wmWin(wI, u64(wmWinGeom));
}

/// Hit-test / focus / CSD controls: last presented AABB while a HOLD
/// is armed, including the COMMIT-to-publish window. Input must not
/// jump to the pending size before VIS + generation publish.
@bare
u64 wmHitGeom(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (wmPendGeomOf(wI) > u64(0)) {
    return wmVisGeom(wI);
  }
  return wmWin(wI, u64(wmWinGeom));
}

/// Absolute origin of [wmHitGeom] (one parent, same as [wmAbsX]).
@bare
u64 wmHitAbsX(u64 wI) {
  final u64 g = wmHitGeom(wI);
  final u64 x = wmGeomX(g);
  final u64 p = wmWinParentOf(wI);
  if (p >= u64(wmMaxWindows)) {
    return x;
  }
  if (wmWindowUsable(p) < u64(1)) {
    return x;
  }
  return wmGeomX(wmHitGeom(p)) + x;
}

@bare
u64 wmHitAbsY(u64 wI) {
  final u64 g = wmHitGeom(wI);
  final u64 y = wmGeomY(g);
  final u64 p = wmWinParentOf(wI);
  if (p >= u64(wmMaxWindows)) {
    return y;
  }
  if (wmWindowUsable(p) < u64(1)) {
    return y;
  }
  return wmGeomY(wmHitGeom(p)) + y;
}

@bare
void wmGeomNote(u64 hdr, u64 hdrN, u64 wI, u64 g, u64 gen) {
  uartWrite(hdr, hdrN);
  uartPutHex(wI, u64(1));
  uartWrite(Rodata.addressOf(wmStrX), u64(3));
  uartPutHex(wmGeomX(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(wmGeomY(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(wmGeomW(g), u64(4));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(wmGeomH(g), u64(4));
  uartWrite(Rodata.addressOf(wmLatStrG), u64(3));
  uartPutHex(gen, u64(4));
  uartNewline();
}

/// Arm HOLD: client is configured to [next]; scanout+hit-test stay on VIS.
@bare
void wmPendArm(u64 wI, u64 next) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  final u64 vis = wmVisGeom(wI);
  if (vis < u64(1)) {
    wmPageSet(wmPageVisOf(wI), wmWin(wI, u64(wmWinGeom)));
  }
  wmPageSet(wmPagePendOf(wI), next);
  wmPageSet(wmPageHoldArmOf(wI), tick_count());
  wmPageSet(wmPageHoldKickOf(wI), u64(0));
  final u64 gen = wmPage(wmPageVisGenOf(wI));
  wmGeomNote(Rodata.addressOf(wmStrReq), u64(9), wI, next, gen);
  wmGeomNote(Rodata.addressOf(wmStrPendTok), u64(10), wI, next, gen);
}

/// Atomic publish after body+CSD are on scanout.
@bare
void wmVisPublish(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  wmPageSet(wmPageVisOf(wI), g);
  wmPageSet(wmPagePendOf(wI), u64(0));
  wmPageSet(wmPageHoldArmOf(wI), u64(0));
  wmPageSet(wmPageHoldKickOf(wI), u64(0));
  final u64 gen = wmPage(wmPageVisGenOf(wI)) + u64(1);
  wmPageSet(wmPageVisGenOf(wI), gen);
  wmGeomNote(Rodata.addressOf(wmStrVis), u64(9), wI, g, gen);
}

@bare
void wmVisClear(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(wmPageVisOf(wI), u64(0));
  wmPageSet(wmPagePendOf(wI), u64(0));
  wmPageSet(wmPageHoldArmOf(wI), u64(0));
  wmPageSet(wmPageHoldKickOf(wI), u64(0));
  final u64 gen = wmPage(wmPageVisGenOf(wI)) + u64(1);
  wmPageSet(wmPageVisGenOf(wI), gen);
  wmGeomNote(Rodata.addressOf(wmStrVis), u64(9), wI, u64(0), gen);
}

/// Publish VIS when scanout now matches requested geom (first present,
/// HOLD complete, or translate-only move). Same geom + no pend is a
/// body-only commit and must not bump the generation.
@bare
void wmVisMaybePublish(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  if (wmWin(wI, u64(wmWinSeq)) < u64(1)) {
    return;
  }
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 raw = wmPage(wmPageVisOf(wI));
  final u64 pend = wmPage(wmPagePendOf(wI));
  if (pend > u64(0)) {
    wmVisPublish(wI);
    return;
  }
  if (raw < u64(1)) {
    wmVisPublish(wI);
    return;
  }
  if (raw != g) {
    wmVisPublish(wI);
  }
}

/// Drop the chrome cache so a HOLD completion cannot geom-only uncover
/// sibling titles with wallpaper (SET title after FILES max/restore).
@bare
void wmChromeInvalidate() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWChromeHave), u64(0));
}

@bare
void wmVisMaybePublishAll() {
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    wmVisMaybePublish(i);
    i = i + u64(1);
  }
}

/// Re-enqueue configure so a dropped HOLD cannot sit at seq==0.
@bare
void wmHoldKick(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmPendGeomOf(wI) < u64(1)) {
    return;
  }
  wmSetWin(wI, u64(wmWinSeq), u64(0));
  wmeventEnqueueConfigure(wI);
  wmPageSet(wmPageHoldKickOf(wI), u64(1));
  uartWrite(Rodata.addressOf(wmStrHoldWd), u64(13));
  uartPutHex(wI, u64(1));
  uartNewline();
}

/// Timeout recovery: revert requested geom to last VIS and restash
/// a restore target so the next max click is not a PHZ no-op.
@bare
void wmHoldCancel(u64 wI) {
  if (wI >= u64(wmMaxWindows)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  final u64 pend = wmPendGeomOf(wI);
  final u64 vis = wmVisGeom(wI);
  if (vis > u64(0)) {
    wmSetWin(wI, u64(wmWinGeom), vis);
  }
  if (wmWin(wI, u64(wmWinSeq)) < u64(1)) {
    wmSetWin(wI, u64(wmWinSeq), u64(1));
  }
  wmPageSet(wmPagePendOf(wI), u64(0));
  wmPageSet(wmPageHoldArmOf(wI), u64(0));
  wmPageSet(wmPageHoldKickOf(wI), u64(2));
  if (pend > u64(0)) {
    if (vis > u64(0)) {
      if (pend != vis) {
        final u64 saved = wmPage(wmPageMaxOf(wI));
        if (saved < u64(1)) {
          if (wmGeomW(pend) < wmGeomW(vis)) {
            wmPageSet(wmPageMaxOf(wI), pend);
          }
        }
      }
    }
  }
  uartWrite(Rodata.addressOf(wmStrHoldTo), u64(13));
  uartPutHex(wI, u64(1));
  uartNewline();
  if (wmPage(u64(wmPageWEvKind)) > u64(0)) {
    wmLatNotePresent();
  }
}

/// Every armed HOLD reaches VIS publish or an explicit cancel/timeout.
@bare
void wmHoldWatch() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  if (wmActive() < u64(1)) {
    return;
  }
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmPendGeomOf(i) > u64(0)) {
      if (wmWindowUsable(i) > u64(0)) {
        final u64 armed = wmPage(wmPageHoldArmOf(i));
        final u64 kicks = wmPage(wmPageHoldKickOf(i));
        final u64 now = tick_count();
        u64 age = u64(0);
        if (now >= armed) {
          age = now - armed;
        }
        if (wmWin(i, u64(wmWinSeq)) > u64(0)) {
          if (age > u64(wmHoldForceTicks)) {
            /* Commit already ran in syscall context. Do not Skia-compose
             * from the PIT tick (ADR-0172). Publish VIS only after a
             * compose stamped chrome for this geom — otherwise VIS
             * lies ahead of scanout (maxed AABB, tiled pixels). */
            u64 ready = u64(0);
            if (wmPage(u64(wmPageWChromeHave)) > u64(0)) {
              if (wmGfxChromeFresh() > u64(0)) {
                ready = u64(1);
              }
            }
            if (ready > u64(0)) {
              wmVisMaybePublish(i);
            }
          }
        } else {
          if (age > u64(wmHoldCancelTicks)) {
            wmHoldCancel(i);
          } else {
            if (age > u64(wmHoldKickTicks)) {
              if (kicks < u64(1)) {
                wmHoldKick(i);
              }
            }
          }
        }
      }
    }
    i = i + u64(1);
  }
}

/// Start-button origin Y (taskbar top).
@bare
u64 wmStartY() {
  return fbGeomHeight() - u64(wmChromeH);
}

/// 1 if DE is on and ([x], [y]) is on the start hit.
/// With a DESK panel strip, Start is the hamburger (x 244–280), not the
/// copper pill under the left island (ADR-0197).
@bare
u64 wmStartHit(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (y < wmStartY()) {
    return u64(0);
  }
  if (y >= fbGeomHeight()) {
    return u64(0);
  }
  if (wmPanelStrip() > u64(0)) {
    if (x < u64(wmHamMX)) {
      return u64(0);
    }
    if (x >= (u64(wmHamMX) + u64(wmHamW))) {
      return u64(0);
    }
    return u64(1);
  }
  if (x < u64(wmStartMX)) {
    return u64(0);
  }
  if (x >= (u64(wmStartMX) + u64(wmStartW))) {
    return u64(0);
  }
  return u64(1);
}

/// Notify-button origin X.
@bare
u64 wmNoteX() {
  return fbGeomWidth() - u64(wmNoteW);
}

/// 1 if DE is on and ([x], [y]) is on the notify hit.
/// Off while a panel owns the strip so right-island icons are not stolen.
@bare
u64 wmNoteHit(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmPanelStrip() > u64(0)) {
    return u64(0);
  }
  if (x < wmNoteX()) {
    return u64(0);
  }
  if (x >= fbGeomWidth()) {
    return u64(0);
  }
  if (y < wmStartY()) {
    return u64(0);
  }
  if (y >= fbGeomHeight()) {
    return u64(0);
  }
  return u64(1);
}

/// 1 if window [wI] is not a task-slot card (panel, overlay, or free).
@bare
u64 wmSlotSkip(u64 wI) {
  if (wmWindowHeld(wI) < u64(1)) {
    return u64(1);
  }
  if (wmIsPanel(wI) > u64(0)) {
    return u64(1);
  }
  if (wmWinOverlay(wI) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

/// Packed index among task-slot cards, or [wmMaxWindows].
@bare
u64 wmSlotOrd(u64 wI) {
  if (wmSlotSkip(wI) > u64(0)) {
    return u64(wmMaxWindows);
  }
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmSlotSkip(i) < u64(1)) {
      if (i == wI) {
        return n;
      }
      n = n + u64(1);
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// Taskbar-slot origin X for window [wI] — island gap, packed cards only.
@bare
u64 wmSlotX(u64 wI) {
  return u64(wmIsleLeftX) + u64(wmIsleLeftW) + u64(wmIsleGapPad) +
      (wmSlotOrd(wI) * u64(wmSlotPitch));
}

/// The held window whose taskbar slot contains ([x], [y]), or
/// [wmMaxWindows]. With DESK up these slots occupy the clear gap between its
/// left and right islands, providing a restore target without a second bar.
@bare
u64 wmSlotHit(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(wmMaxWindows);
  }
  if (y < wmStartY()) {
    return u64(wmMaxWindows);
  }
  if (y >= fbGeomHeight()) {
    return u64(wmMaxWindows);
  }
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmSlotSkip(i) < u64(1)) {
      final u64 sx = wmSlotX(i);
      if (x >= sx) {
        if (x < (sx + u64(wmSlotW))) {
          return i;
        }
      }
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// Paints one chrome control through osxui_button (null OsGfx scanout).
@bare
void wmOsxuiButton(u64 x, u64 y, u64 w, u64 h, u64 radius, u64 rgb) {
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  osxui_button_fb(
      fbState(u64(fbStateBase)),
      fbState(u64(fbStatePitch)),
      (fbGeomWidth() << u64(32)) | fbGeomHeight(),
      (x << u64(32)) | y,
      (w << u64(32)) | h,
      (radius << u64(32)) | rgb);
}

/// Paints close/min on window [wI] when DE is on.
@bare
void wmTitleButtonsDraw(u64 wI) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  final u64 by = wmBtnY(wI);
  wmOsxuiButton(wmMinX(wI), by, u64(wmBtnS), u64(wmBtnS), u64(wmBtnR),
      u64(wmMinColor));
  wmOsxuiButton(wmCloseX(wI), by, u64(wmBtnS), u64(wmBtnS), u64(wmBtnR),
      u64(wmCloseColor));
  wmTitleLabelDraw(wI);
}

/// `PID` on the title strip through osxui_label_fb. Not put_px.
/// Skipped under `wm gfx` so the rrect title probes stay the fill.
@bare
void wmTitleLabelDraw(u64 wI) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  final u64 g = wmViewGeom(wI);
  final u64 x = wmGeomX(g) + u64(wmTitlePadX);
  final u64 y = wmGeomY(g) + u64(wmTitlePadY);
  if ((x + (u64(wmTitleStemN) * u64(8))) >= wmMinX(wI)) {
    return;
  }
  osxui_label_fb(
      fbState(u64(fbStateBase)),
      fbState(u64(fbStatePitch)),
      (fbGeomWidth() << u64(32)) | fbGeomHeight(),
      (x << u64(32)) | y,
      Rodata.addressOf(wmStrTitlePid),
      (u64(wmTitleStemN) << u64(32)) | u64(wmTitleFg));
}

/// Button colour at ([x], [y]) on window [wI], or [wmNoPixel].
/// Under `wm gfx`, session C owns title widgets — returning a solid
/// close/min here lets damage/commit stamp binary discs over soft AA.
@bare
u64 wmDeTitlePixel(u64 wI, u64 x, u64 y) {
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return u64(wmNoPixel);
  }
  if (wmCloseHit(wI, x, y) > u64(0)) {
    if (wmRrectHit(x, y, wmCloseX(wI), wmBtnY(wI), u64(wmBtnS), u64(wmBtnS),
            u64(wmBtnR)) >
        u64(0)) {
      return u64(wmCloseColor);
    }
  }
  if (wmMinHit(wI, x, y) > u64(0)) {
    if (wmRrectHit(x, y, wmMinX(wI), wmBtnY(wI), u64(wmBtnS), u64(wmBtnS),
            u64(wmBtnR)) >
        u64(0)) {
      return u64(wmMinColor);
    }
  }
  return wmTitleLabelPixel(wI, x, y);
}

/// [wmTitleFg] if ([x], [y]) is a set bit of the title `PID` stem.
/// Damage / commit use [wmPixelAt]; without this the gold fill wins.
@bare
u64 wmTitleLabelPixel(u64 wI, u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(wmNoPixel);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(wmNoPixel);
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return u64(wmNoPixel);
  }
  final u64 g = wmViewGeom(wI);
  final u64 ox = wmGeomX(g) + u64(wmTitlePadX);
  final u64 oy = wmGeomY(g) + u64(wmTitlePadY);
  if (x < ox) {
    return u64(wmNoPixel);
  }
  if (y < oy) {
    return u64(wmNoPixel);
  }
  if (y >= (oy + u64(glyphHeight))) {
    return u64(wmNoPixel);
  }
  final u64 dx = x - ox;
  if (dx >= (u64(wmTitleStemN) * u64(glyphWidth))) {
    return u64(wmNoPixel);
  }
  if ((ox + (u64(wmTitleStemN) * u64(glyphWidth))) >= wmMinX(wI)) {
    return u64(wmNoPixel);
  }
  final u64 i = dx >> u64(3);
  final u64 col = dx & u64(7);
  final u8 ch = Pointer<u8>.fromAddress(
      Rodata.addressOf(wmStrTitlePid) + i).value;
  final u64 glyph = fbGlyphAddr(ch);
  final u64 bits = Pointer<u8>.fromAddress(glyph + (y - oy)).value.toU64();
  if (((bits >> (u64(7) - col)) & u64(1)) > u64(0)) {
    return u64(wmTitleFg);
  }
  return u64(wmNoPixel);
}

/// Slot colour for window [wI].
@bare
u64 wmSlotColor(u64 wI) {
  if (wI == u64(0)) {
    return u64(wmSlot0Color);
  }
  return u64(wmSlot1Color);
}

/// Paints start, notify, and one slot per held window. Called from
/// [wmChromeDraw] after the strip fill, only when DE is on.
@bare
u64 wmDeChromeDraw() {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return u64(0);
  }
  wmDePrefApply();
  final u64 y = wmStartY();
  wmOsxuiButton(u64(wmStartMX), y, u64(wmStartW), u64(wmChromeH), u64(wmStartR),
      u64(wmStartColor));
  if (fbState(u64(fbStateBase)) > u64(0)) {
    osxui_label_fb(
        fbState(u64(fbStateBase)),
        fbState(u64(fbStatePitch)),
        (fbGeomWidth() << u64(32)) | fbGeomHeight(),
        ((u64(wmStartMX) + u64(wmStartPadX)) << u64(32)) |
            (y + u64(wmStartPadY)),
        Rodata.addressOf(wmStrStartTile),
        (u64(wmStartStemN) << u64(32)) | u64(wmLabelFg));
  }
  wmFillRect(wmNoteX(), y, u64(wmNoteW), u64(wmChromeH), wmDeNoteColor());
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmSlotSkip(i) < u64(1)) {
      final u64 sx = wmSlotX(i);
      wmOsxuiButton(sx, y, u64(wmSlotW), u64(wmChromeH), u64(wmStartR),
          wmSlotColor(i));
      if (fbState(u64(fbStateBase)) > u64(0)) {
        u64 stem = Rodata.addressOf(wmStrSlot0);
        if (i != u64(0)) {
          stem = Rodata.addressOf(wmStrSlot1);
        }
        osxui_label_fb(
            fbState(u64(fbStateBase)),
            fbState(u64(fbStatePitch)),
            (fbGeomWidth() << u64(32)) | fbGeomHeight(),
            ((sx + u64(wmSlotPadX)) << u64(32)) | (y + u64(wmSlotPadY)),
            stem,
            (u64(wmSlotStemN) << u64(32)) | u64(wmLabelFg));
      }
      n = n + u64(1);
    }
    i = i + u64(1);
  }
  return u64(wmStartW) * u64(wmChromeH) +
      u64(wmNoteW) * u64(wmChromeH) +
      (n * u64(wmSlotW) * u64(wmChromeH));
}

/// Strip-widget colour at ([x], [y]), or [wmNoPixel].
@bare
u64 wmDeChromePixel(u64 x, u64 y) {
  if (wmStartHit(x, y) > u64(0)) {
    if (wmRrectHit(x, y, u64(wmStartMX), wmStartY(), u64(wmStartW),
            u64(wmChromeH), u64(wmStartR)) >
        u64(0)) {
      return u64(wmStartColor);
    }
  }
  if (wmNoteHit(x, y) > u64(0)) {
    return wmDeNoteColor();
  }
  final u64 s = wmSlotHit(x, y);
  if (s < u64(wmMaxWindows)) {
    return wmSlotColor(s);
  }
  return u64(wmNoPixel);
}

/// Chrome-strip colour at ([x], [y]), or [wmNoPixel]. DE widgets win
/// over the plain strip. Under `wm gfx`, session C owns the strip —
/// solid returns here stamp over soft-AA Start / slots on damage.
@bare
u64 wmChromePixel(u64 x, u64 y) {
  if (wmChromeHit(x, y) < u64(1)) {
    return u64(wmNoPixel);
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return u64(wmNoPixel);
  }
  final u64 de = wmDeChromePixel(x, y);
  if (de != u64(wmNoPixel)) {
    return de;
  }
  return u64(wmChromeColor);
}

/// Launch-popover origin X (centred, edge-safe).
@bare
u64 wmLaunchX() {
  final u64 sw = fbGeomWidth();
  if (sw <= u64(wmLaunchW)) {
    return u64(8);
  }
  u64 x = (sw - u64(wmLaunchW)) >> u64(1);
  if ((x + u64(wmLaunchW) + u64(8)) > sw) {
    x = sw - u64(wmLaunchW) - u64(8);
  }
  if (x < u64(8)) {
    x = u64(8);
  }
  return x;
}

/// Launch-popover origin Y (above the dock, edge-safe).
@bare
u64 wmLaunchY() {
  final u64 sh = fbGeomHeight();
  u64 y = sh - u64(wmChromeH) - wmLaunchBoxH() - u64(8);
  if (y < u64(8)) {
    y = u64(8);
  }
  return y;
}

/// Panel origin X (flush right, above the strip).
@bare
u64 wmPanelX() {
  return fbGeomWidth() - u64(wmPanelW);
}

/// Panel origin Y.
@bare
u64 wmPanelY() {
  return fbGeomHeight() - u64(wmChromeH) - u64(wmPanelH);
}

/// 1 if the start popover is showing and ([x], [y]) is inside it.
@bare
u64 wmLaunchHit(u64 x, u64 y) {
  if (wmMeta(u64(wmMetaPop)) != u64(wmPopLaunch)) {
    return u64(0);
  }
  if (x < wmLaunchX()) {
    return u64(0);
  }
  if (y < wmLaunchY()) {
    return u64(0);
  }
  if (x >= (wmLaunchX() + u64(wmLaunchW))) {
    return u64(0);
  }
  if (y >= (wmLaunchY() + wmLaunchBoxH())) {
    return u64(0);
  }
  return u64(1);
}

/// 1 if the panel is showing and ([x], [y]) is inside it.
@bare
u64 wmPanelHit(u64 x, u64 y) {
  if (wmMeta(u64(wmMetaPop)) != u64(wmPopPanel)) {
    return u64(0);
  }
  if (x < wmPanelX()) {
    return u64(0);
  }
  if (y < wmPanelY()) {
    return u64(0);
  }
  if (x >= (wmPanelX() + u64(wmPanelW))) {
    return u64(0);
  }
  if (y >= (wmPanelY() + u64(wmPanelH))) {
    return u64(0);
  }
  return u64(1);
}

/// Hides start or panel and restores the rectangle. Kind 1 still goes
/// through [wmPopHide].
@bare
void wmDePopHide() {
  final u64 k = wmMeta(u64(wmMetaPop));
  if (k == u64(wmPopLaunch)) {
    wmSetMeta(u64(wmMetaPop), u64(0));
    wmPopDamageRestore(
        wmLaunchX(), wmLaunchY(), u64(wmLaunchW), wmLaunchBoxH());
  }
  if (k == u64(wmPopPanel)) {
    wmSetMeta(u64(wmMetaPop), u64(0));
    wmPopDamageRestore(
        wmPanelX(), wmPanelY(), u64(wmPanelW), u64(wmPanelH));
  }
  if (k == u64(wmPopSwitch)) {
    wmSetMeta(u64(wmMetaPop), u64(0));
    wmPopDamageRestore(wmSwitchX(), wmSwitchY(), wmSwitchBoxW(),
        u64(wmSwitchH));
  }
}

/// Row colour for launch row [row].
@bare
u64 wmLaunchRowColor(u64 row) {
  if ((row & u64(1)) == u64(0)) {
    return u64(wmLaunchRow0);
  }
  return u64(wmLaunchRow1);
}

/// Paints the start popover and its cached ELF rows.
@bare
u64 wmLaunchDraw() {
  if (wmMeta(u64(wmMetaPop)) != u64(wmPopLaunch)) {
    return u64(0);
  }
  final u64 ox = wmLaunchX();
  final u64 oy = wmLaunchY();
  wmFillRect(ox, oy, u64(wmLaunchW), wmLaunchBoxH(), u64(wmLaunchColor));
  final u64 n = wmDeLaunchN();
  u64 i = u64(0);
  while (i < n) {
    if (i < u64(wmDeLaunchMax)) {
      wmFillRect(ox + u64(4), oy + u64(4) + (i * u64(wmLaunchRowH)),
          u64(wmLaunchW) - u64(8), u64(wmLaunchRowH) - u64(2),
          wmLaunchRowColor(i));
      if (fbState(u64(fbStateBase)) > u64(0)) {
        final u64 idx = wmDeLaunchIdx(i);
        final u64 e = fatDirEntry(idx);
        if (e > u64(0)) {
          osxui_label_fb(
              fbState(u64(fbStateBase)),
              fbState(u64(fbStatePitch)),
              (fbGeomWidth() << u64(32)) | fbGeomHeight(),
              ((ox + u64(wmLabelPadX)) << u64(32)) |
                  (oy + u64(wmLabelPadY) + (i * u64(wmLaunchRowH))),
              e,
              (u64(8) << u64(32)) | u64(wmLabelFg));
        }
      }
    }
    i = i + u64(1);
  }
  return u64(wmLaunchW) * wmLaunchBoxH();
}

/// How many held windows (live or min).
@bare
u64 wmHeldCount() {
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowHeld(i) > u64(0)) {
      n = n + u64(1);
    }
    i = i + u64(1);
  }
  return n;
}

/// Window index of held row [row], or [wmMaxWindows].
@bare
u64 wmHeldAt(u64 row) {
  u64 n = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowHeld(i) > u64(0)) {
      if (n == row) {
        return i;
      }
      n = n + u64(1);
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// Hex digit for nibble [nib] (`0`..`9`, `A`..`F`).
@bare
u8 wmHexDigit(u64 nib) {
  final u64 n = nib & u64(0xF);
  if (n < u64(10)) {
    return u8(0x30) + n.toU8();
  }
  return u8(0x37) + n.toU8();
}

/// Live owner hex on panel row [row] through osxui_hex_fb. Not put_px.
/// Skipped under `wm gfx` so sit-in scanout stays the row fill.
@bare
void wmPanelPidDraw(u64 row, u64 pid) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return;
  }
  if (fbState(u64(fbStateBase)) < u64(1)) {
    return;
  }
  final u64 x = wmPanelX() + u64(wmPanelPadX);
  final u64 y = wmPanelY() + u64(wmPanelPadY) + (row * u64(wmLaunchRowH));
  if ((x + (u64(wmPanelStemN) * u64(glyphWidth))) > (wmPanelX() + u64(wmPanelW))) {
    return;
  }
  osxui_hex_fb(
      fbState(u64(fbStateBase)),
      fbState(u64(fbStatePitch)),
      (fbGeomWidth() << u64(32)) | fbGeomHeight(),
      (x << u64(32)) | y,
      pid,
      (u64(wmPanelStemN) << u64(32)) | u64(wmPanelFg));
}

/// [wmPanelFg] if ([x], [y]) is a set bit of a live hex pid.
/// Damage / commit use [wmPixelAt]; without this the row fill wins.
@bare
u64 wmPanelLabelPixel(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(wmNoPixel);
  }
  if (wmMeta(u64(wmMetaPop)) != u64(wmPopPanel)) {
    return u64(wmNoPixel);
  }
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    return u64(wmNoPixel);
  }
  final u64 row = wmDeRowAt(y, wmPanelY());
  if (row >= wmHeldCount()) {
    return u64(wmNoPixel);
  }
  final u64 wI = wmHeldAt(row);
  if (wI >= u64(wmMaxWindows)) {
    return u64(wmNoPixel);
  }
  final u64 ox = wmPanelX() + u64(wmPanelPadX);
  final u64 oy = wmPanelY() + u64(wmPanelPadY) + (row * u64(wmLaunchRowH));
  if (x < ox) {
    return u64(wmNoPixel);
  }
  if (y < oy) {
    return u64(wmNoPixel);
  }
  if (y >= (oy + u64(glyphHeight))) {
    return u64(wmNoPixel);
  }
  final u64 dx = x - ox;
  if (dx >= (u64(wmPanelStemN) * u64(glyphWidth))) {
    return u64(wmNoPixel);
  }
  final u64 i = dx >> u64(3);
  final u64 col = dx & u64(7);
  final u64 pid = wmWin(wI, u64(wmWinOwner));
  final u64 nib =
      (pid >> ((u64(wmPanelStemN) - u64(1) - i) << u64(2))) & u64(0xF);
  final u8 ch = wmHexDigit(nib);
  final u64 glyph = fbGlyphAddr(ch);
  final u64 bits = Pointer<u8>.fromAddress(glyph + (y - oy)).value.toU64();
  if (((bits >> (u64(7) - col)) & u64(1)) > u64(0)) {
    return u64(wmPanelFg);
  }
  return u64(wmNoPixel);
}

/// Paints the reflection panel and prints one serial row per held surface.
@bare
u64 wmPanelDraw() {
  if (wmMeta(u64(wmMetaPop)) != u64(wmPopPanel)) {
    return u64(0);
  }
  final u64 ox = wmPanelX();
  final u64 oy = wmPanelY();
  wmFillRect(ox, oy, u64(wmPanelW), u64(wmPanelH), u64(wmPanelColor));
  u64 row = u64(0);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmWindowHeld(i) > u64(0)) {
      u64 c = u64(wmPanelRow0);
      if ((row & u64(1)) > u64(0)) {
        c = u64(wmPanelRow1);
      }
      wmFillRect(ox + u64(4), oy + u64(4) + (row * u64(wmLaunchRowH)),
          u64(wmPanelW) - u64(8), u64(wmLaunchRowH) - u64(2), c);
      wmPanelPidDraw(row, wmWin(i, u64(wmWinOwner)));
      uartWrite(Rodata.addressOf(wmStrDeSurf), u64(11));
      uartPutHex(i, u64(1));
      uartWrite(Rodata.addressOf(wmStrPid), u64(5));
      uartPutHex(wmWin(i, u64(wmWinOwner)), u64(8));
      uartNewline();
      row = row + u64(1);
    }
    i = i + u64(1);
  }
  return u64(wmPanelW) * u64(wmPanelH);
}

/// Paints start or panel. Kind 1 stays in [wmPopDraw].
@bare
u64 wmDePopDraw() {
  u64 px = wmLaunchDraw();
  px = px + wmPanelDraw();
  return px;
}

/// Row index for a point [y] in a band that starts at [origin]+4.
@bare
u64 wmDeRowAt(u64 y, u64 origin) {
  if (y < (origin + u64(4))) {
    return u64(0xFF);
  }
  u64 d = y - origin - u64(4);
  u64 row = u64(0);
  while (d >= u64(wmLaunchRowH)) {
    d = d - u64(wmLaunchRowH);
    row = row + u64(1);
  }
  return row;
}

/// Colour of a showing DE popover at ([x], [y]), or [wmNoPixel].
@bare
u64 wmDePopPixel(u64 x, u64 y) {
  if (wmLaunchHit(x, y) > u64(0)) {
    final u64 n = wmDeLaunchN();
    final u64 row = wmDeRowAt(y, wmLaunchY());
    if (row < n) {
      return wmLaunchRowColor(row);
    }
    return u64(wmLaunchColor);
  }
  if (wmPanelHit(x, y) > u64(0)) {
    final u64 ink = wmPanelLabelPixel(x, y);
    if (ink != u64(wmNoPixel)) {
      return ink;
    }
    final u64 row = wmDeRowAt(y, wmPanelY());
    if (row < wmHeldCount()) {
      if ((row & u64(1)) > u64(0)) {
        return u64(wmPanelRow1);
      }
      return u64(wmPanelRow0);
    }
    return u64(wmPanelColor);
  }
  return u64(wmNoPixel);
}

/// 1 if directory entry [e] is the 8.3 pref name.
@bare
u64 wmDePrefNameEq(u64 e) {
  final u64 want = Rodata.addressOf(wmStrPrefName);
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    if (Pointer<u8>.fromAddress(e + i).value !=
        Pointer<u8>.fromAddress(want + i).value) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// 1 if the root holds a non-empty pref file. Same walk start uses.
@bare
u64 wmDePrefFind() {
  fatSetMeta(u64(fatMetaCached), u64(fatNoSector));
  final u64 st = fatMount();
  if (st > u64(fatErrOk)) {
    return u64(0);
  }
  final u64 nent = fatMeta(u64(fatMetaRootEntries));
  u64 i = u64(0);
  while (i < nent) {
    final u64 e = fatDirEntry(i);
    if (e < u64(1)) {
      return u64(0);
    }
    final u64 c0 = fatU8(e);
    if (c0 == u64(fatDirFree)) {
      return u64(0);
    }
    if (c0 != u64(fatDirDeleted)) {
      final u64 attr = fatU8(e + u64(fatDirOffAttr));
      if (attr != u64(fatAttrLongName)) {
        if ((attr & u64(fatAttrVolumeId)) < u64(1)) {
          if ((attr & u64(fatAttrDirectory)) < u64(1)) {
            if (wmDePrefNameEq(e) > u64(0)) {
              if (fatU32(e + u64(fatDirOffSize)) > u64(0)) {
                return u64(1);
              }
            }
          }
        }
      }
    }
    i = i + u64(1);
  }
  return u64(0);
}

/// Load CHROME.DAT bytes 0..3 into the page pref word and apply wall.
@bare
void wmDePrefLoad() {
  final u64 pn = fatParseAt(Rodata.addressOf(wmStrPrefPath), u64(10));
  if (pn > u64(fatErrOk)) {
    return;
  }
  final u64 st = fatLookup();
  if (st > u64(fatErrOk)) {
    return;
  }
  if (fatFileBytes() < u64(1)) {
    return;
  }
  final u64 lba = fatFileSector(u64(0));
  if (lba < u64(1)) {
    return;
  }
  if (fatReadCached(lba) > u64(0)) {
    return;
  }
  final u64 base = fatSectorBase();
  final u64 chrome = fatU8(base);
  final u64 theme = fatU8(base + u64(1));
  final u64 accent = fatU8(base + u64(2));
  final u64 wall = fatU8(base + u64(3));
  u64 prev = u64(0);
  if (wmPageAddr() > u64(0)) {
    prev = wmPage(u64(wmPageWPref)) & u64(0x00FFFFFF);
  }
  wmPrefNote(theme, accent, wall);
  if (chrome > u64(0)) {
    if (wmDePrefOn() < u64(1)) {
      wmSetMeta(u64(wmMetaChrome),
          wmMeta(u64(wmMetaChrome)) | u64(wmDePrefMask));
    }
  }
  final u64 now = (theme & u64(0xFF)) | ((accent & u64(0xFF)) << u64(8)) |
      ((wall & u64(0xFF)) << u64(16));
  if (now != prev) {
    uartWrite(Rodata.addressOf(wmStrPref), u64(8));
    uartPutHex(now, u64(6));
    uartNewline();
    if (wall > u64(0)) {
      wmWallSetDesk(u64(0xA11E0001) + wall, wall & u64(3));
    }
  }
}

/// If the pref file is new, set bit 4, print `WM DE SET ON`, and
/// paint the notify strip. Gated on `wm de` so a local-only boot
/// (de-set) does not turn chrome on. Called from commit as well as
/// a full chrome draw — damage does not otherwise visit the strip.
@bare
void wmDePrefApply() {
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wmDePrefFind() < u64(1)) {
    return;
  }
  if (wmDePrefOn() < u64(1)) {
    wmSetMeta(u64(wmMetaChrome),
        wmMeta(u64(wmMetaChrome)) | u64(wmDePrefMask));
    uartWrite(Rodata.addressOf(wmStrDeSetOn), u64(12));
    uartNewline();
    if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
      wmFillRect(wmNoteX(), wmStartY(), u64(wmNoteW), u64(wmChromeH),
          u64(wmDeSetColor));
    }
  }
  wmDePrefLoad();
}

/// Walks the FAT root and caches up to [wmDeLaunchMax] ELF directory
/// indices in the chrome word. Task context only (`wm de`).
@bare
void wmDeScanLaunch() {
  u64 packed = u64(wmDeLevel);
  final u64 st = fatMount();
  if (st > u64(fatErrOk)) {
    wmSetMeta(u64(wmMetaChrome), packed);
    return;
  }
  final u64 nent = fatMeta(u64(fatMetaRootEntries));
  u64 i = u64(0);
  u64 n = u64(0);
  while (i < nent) {
    if (n >= u64(wmDeLaunchMax)) {
      i = nent;
    } else {
      final u64 e = fatDirEntry(i);
      if (e < u64(1)) {
        i = nent;
      } else {
        final u64 c0 = fatU8(e);
        if (c0 == u64(fatDirFree)) {
          i = nent;
        } else {
          u64 keep = u64(0);
          if (c0 != u64(fatDirDeleted)) {
            final u64 attr = fatU8(e + u64(fatDirOffAttr));
            if (attr != u64(fatAttrLongName)) {
              if ((attr & u64(fatAttrVolumeId)) < u64(1)) {
                if ((attr & u64(fatAttrDirectory)) < u64(1)) {
                  if (Pointer<u8>.fromAddress(e + u64(8)).value == u8(0x45)) {
                    if (Pointer<u8>.fromAddress(e + u64(9)).value ==
                        u8(0x4C)) {
                      if (Pointer<u8>.fromAddress(e + u64(10)).value ==
                          u8(0x46)) {
                        keep = u64(1);
                      }
                    }
                  }
                }
              }
            }
          }
          if (keep > u64(0)) {
            packed = packed | (i << (u64(16) + (n << u64(3))));
            n = n + u64(1);
          }
          i = i + u64(1);
        }
      }
    }
  }
  packed = packed | (n << u64(8));
  wmSetMeta(u64(wmMetaChrome), packed);
}

/// Copies 11 name bytes from [src] into the FAT name buffer.
@bare
void wmDeNameCopy(u64 src) {
  final u64 dst = fatNameBase();
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Opens the start popover. Uses the ELF list `wm de` already cached.
@bare
void wmDeStartShow() {
  wmOverlayRestore();
  if (wmPopKind() > u64(0)) {
    if (wmPopIsCard(wmPopKind()) > u64(0)) {
      wmPopHide();
    } else {
      wmDePopHide();
    }
  }
  wmLaunchReset();
  wmSetMeta(u64(wmMetaPop), u64(wmPopLaunch));
  wmSetMeta(u64(wmMetaPopXY),
      (wmLaunchX() << u64(32)) | wmLaunchY());
  final u64 n = wmDeLaunchN();
  uartWrite(Rodata.addressOf(wmStrDeStart), u64(12));
  uartPutHex(n, u64(2));
  uartNewline();
  uartWrite(Rodata.addressOf(wmStrLaunchShow), u64(15));
  uartPutHex(n, u64(2));
  uartNewline();
  if (wmPanelStrip() < u64(1)) {
    final u64 unused = wmLaunchDraw();
  }
}

/// Opens the reflection panel and prints the live list.
@bare
void wmDePanelShow() {
  if (wmPopKind() > u64(0)) {
    if (wmPopIsCard(wmPopKind()) > u64(0)) {
      wmPopHide();
    } else {
      wmDePopHide();
    }
  }
  wmSetMeta(u64(wmMetaPop), u64(wmPopPanel));
  wmSetMeta(u64(wmMetaPopXY),
      ((fbGeomWidth() - u64(wmPanelW) - u64(8)) << u64(32)) |
          wmPanelY());
  uartWrite(Rodata.addressOf(wmStrDeList), u64(11));
  uartPutHex(wmHeldCount(), u64(2));
  uartNewline();
  if (wmPanelStrip() < u64(1)) {
    final u64 unused = wmPanelDraw();
  }
}

/// Spawns the ELF cached at launch row [row] through the named load
/// (same guts as syscall 26). No new syscall.
@bare
void wmDeSpawnRow(u64 row) {
  if (row >= wmDeLaunchN()) {
    return;
  }
  final u64 idx = wmDeLaunchIdx(row);
  final u64 e = fatDirEntry(idx);
  if (e < u64(1)) {
    return;
  }
  wmDeNameCopy(e);
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    fatReportError(fs);
    return;
  }
  fatOpenLine();
  fatChainReport();
  final u64 slot = procFreeSlot();
  if (slot == u64(procMax)) {
    return;
  }
  u64 saved = u64(0);
  u64 have = u64(0);
  if (procLive() > u64(0)) {
    saved = procGet(procCurrent(), u64(procSlotPml4));
    have = u64(1);
  }
  if (procHead(u64(procHeadResident)) < u64(1)) {
    procSetHead(u64(procHeadResident), u64(1));
    procSessionTimerOn();
  }
  final u64 st = procCreate(u64(0), u64(1));
  if (have > u64(0)) {
    paging_install(saved);
  }
  if (st > u64(0)) {
    return;
  }
  uartWrite(Rodata.addressOf(wmStrDeSpawn), u64(12));
  uartPutHex(slot, u64(2));
  uartNewline();
  // PLAY.ELF is the Start video name (ADR-0135). Hidden `play` still
  // copies CLIP.MP4; the client attaches a 64×64 shm and IRQ0 fills it.
  if (mediaNameIsPlay() > u64(0)) {
    shellMediaPlayDefault();
  }
}

/// Tears down window [wI] and kills its owner when that is safe.
@bare
void wmCloseWindow(u64 wI) {
  if (wmWindowHeld(wI) < u64(1)) {
    return;
  }
  final u64 owner = wmWin(wI, u64(wmWinOwner));
  /* Uncover the last presented AABB, not the pending max size. */
  u64 g = wmVisGeom(wI);
  if (g < u64(1)) {
    g = wmWin(wI, u64(wmWinGeom));
  }
  final u64 b = u64(wmBorder);
  final u64 ox = wmGeomX(g) - b;
  final u64 oy = wmGeomY(g) - b;
  final u64 ow = wmGeomW(g) + b + b;
  final u64 oh = wmGeomH(g) + b + b;
  wmeventResetSlot(wI);
  if (wmPageAddr() > u64(0)) {
    wmPageSet(wmPageLaunchOf(wI), u64(0));
    wmPageSet(wmPageMaxOf(wI), u64(0));
    wmVisClear(wI);
    wmDefClear(wI);
    wmPageSet(wmPageHoldArmOf(wI), u64(0));
    wmPageSet(wmPageHoldKickOf(wI), u64(0));
    wmPageSet(u64(wmPageWLifeClose),
        wmPage(u64(wmPageWLifeClose)) + u64(1));
  }
  wmSetWin(wI, u64(wmWinState), u64(wmWinFree));
  wmSetWin(wI, u64(wmWinSeq), u64(0));
  if (wmMeta(u64(wmMetaLive)) > u64(0)) {
    wmSetMeta(u64(wmMetaLive), wmMeta(u64(wmMetaLive)) - u64(1));
  }
  if (wmMeta(u64(wmMetaTop)) == wI) {
    wmSetMeta(u64(wmMetaTop), u64(wmMaxWindows));
  }
  if (wmMeta(u64(wmMetaDrag)) == (wI + u64(1))) {
    wmSetMeta(u64(wmMetaDrag), u64(0));
  }
  if (wmMeta(u64(wmMetaFocus)) == (wI + u64(1))) {
    wmSetMeta(u64(wmMetaFocus), u64(0));
  }
  wmMruDrop(wI);
  uartWrite(Rodata.addressOf(wmStrClose), u64(11));
  uartPutHex(wI, u64(1));
  uartWrite(Rodata.addressOf(wmStrPid), u64(5));
  uartPutHex(owner, u64(8));
  uartNewline();
  procKillId(owner);
  wmLifeNote();
  /* Punch wallpaper into the live chrome cache + FB. Dropping HAVE
   * forced the next commit down CPATH 3 and left a black vacated card. */
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    /* Mail the post-close set (no FILES) so a later cache blit holes
     * nothing at this AABB. Do not kick: a gen bump restamps the
     * session over the vacated wallpaper and the next attach. */
    wmGfxMail();
    final u64 vacated = osgfx_chrome_vacate_geom(wmPackGeom(ox, oy, ow, oh));
    if (vacated > u64(0)) {
      wmOpBegin(u64(wmOpKindBody));
      final u64 fpx = wmPresentClipped(ox, oy, ow, oh);
      wmPublishFrameNoted(fpx);
      wmPublishFrameLine(fpx, mouseState(u64(mouseWordX)),
          mouseState(u64(mouseWordY)));
      wmOpDone(fpx);
    } else {
      final u64 unused = wmRepaintRect(ox, oy, ow, oh);
    }
    wmGfxMail();
  } else {
    final u64 unused = wmRepaintRect(ox, oy, ow, oh);
  }
}

/// Minimises window [wI]: held, not painted.
@bare
void wmMinWindow(u64 wI) {
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  final u64 g = wmWin(wI, u64(wmWinGeom));
  final u64 b = u64(wmBorder);
  wmSetWin(wI, u64(wmWinState), u64(wmWinMin));
  if (wmMeta(u64(wmMetaTop)) == wI) {
    wmSetMeta(u64(wmMetaTop), u64(wmMaxWindows));
  }
  if (wmMeta(u64(wmMetaDrag)) == (wI + u64(1))) {
    wmSetMeta(u64(wmMetaDrag), u64(0));
  }
  if (wmMeta(u64(wmMetaFocus)) == (wI + u64(1))) {
    wmSetMeta(u64(wmMetaFocus), u64(0));
  }
  uartWrite(Rodata.addressOf(wmStrMin), u64(9));
  uartPutHex(wI, u64(1));
  uartNewline();
  final u64 unused = wmRepaintRect(wmGeomX(g) - b, wmGeomY(g) - b,
      wmGeomW(g) + b + b, wmGeomH(g) + b + b);
  if (wmDeOn() > u64(0)) {
    final u64 strip = wmDeChromeDraw();
  }
}

/// Restores a minimised window from its taskbar slot.
@bare
void wmRestWindow(u64 wI) {
  if (wmWin(wI, u64(wmWinState)) != u64(wmWinMin)) {
    return;
  }
  if (wmWindowRegionLive(wI) < u64(1)) {
    return;
  }
  wmSetWin(wI, u64(wmWinState), u64(wmWinLive));
  wmSetMeta(u64(wmMetaTop), wI);
  uartWrite(Rodata.addressOf(wmStrRest), u64(10));
  uartPutHex(wI, u64(1));
  uartNewline();
  final u64 unused = wmRepaintWindow(wI);
}

/// Toggle saved geometry against the largest rectangle the attached backing
/// store can safely supply. [wmClampSize] keeps this inside stride/pages.
@bare
u64 wmDefMaxGeom(u64 wI) {
  final u64 b = u64(wmBorder);
  final u64 size = wmClampSize(
      wI, b, b, fbGeomWidth() - b - b,
      fbGeomHeight() - u64(wmChromeH) - b - b);
  return wmPackGeom(b, b, size >> u64(32), size & u64(0xFFFFFFFF));
}

@bare
void wmIfHoldBegin(u64 reason) {
  /* Compose/drain/prep only. Caller holds wmMetaBusy first so a pointer
   * IRQ is enqueue-only. osxui/SHM/UART syscalls stay IF-clear: STI on
   * every syscall nested pointer Skia inside FILES prefill and starved
   * DESK (no SET dock PRESS). */
  interrupts_enable();
  if (wmPageAddr() < u64(1)) {
    return;
  }
  wmPageSet(u64(wmPageWIfHold), reason | (tick_count() << u64(8)));
}

@bare
void wmIfHoldEnd() {
  interrupts_disable();
  if (wmPageAddr() < u64(1)) {
    return;
  }
  final u64 packed = wmPage(u64(wmPageWIfHold));
  if (packed < u64(1)) {
    return;
  }
  final u64 dt = tick_count() - (packed >> u64(8));
  wmPageSet(u64(wmPageWIfHold), u64(0));
  if (dt < u64(1)) {
    return;
  }
  uartWrite(Rodata.addressOf(wmStrIfHold), u64(10));
  uartPutHex(packed & u64(0xFF), u64(2));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(dt, u64(4));
  uartNewline();
}

@bare
void wmIfSysOpen() {
  interrupts_enable();
}

@bare
void wmIfSysClose() {
  interrupts_disable();
}

@bare
void wmDefUnionExpand(u64 g) {
  final u64 b = u64(wmBorder);
  u64 x = wmGeomX(g);
  u64 y = wmGeomY(g);
  u64 w = wmGeomW(g);
  u64 h = wmGeomH(g);
  if (x >= b) {
    x = x - b;
  } else {
    x = u64(0);
  }
  if (y >= b) {
    y = y - b;
  } else {
    y = u64(0);
  }
  w = w + b + b;
  h = h + b + b;
  final u64 ux = wmPage(u64(wmPageWDefUx));
  final u64 uy = wmPage(u64(wmPageWDefUy));
  final u64 uw = wmPage(u64(wmPageWDefUw));
  final u64 uh = wmPage(u64(wmPageWDefUh));
  if (uw < u64(1)) {
    wmPageSet(u64(wmPageWDefUx), x);
    wmPageSet(u64(wmPageWDefUy), y);
    wmPageSet(u64(wmPageWDefUw), w);
    wmPageSet(u64(wmPageWDefUh), h);
    return;
  }
  u64 nx = ux;
  u64 ny = uy;
  if (x < ux) {
    nx = x;
  }
  if (y < uy) {
    ny = y;
  }
  u64 x1 = ux + uw;
  u64 y1 = uy + uh;
  if ((x + w) > x1) {
    x1 = x + w;
  }
  if ((y + h) > y1) {
    y1 = y + h;
  }
  wmPageSet(u64(wmPageWDefUx), nx);
  wmPageSet(u64(wmPageWDefUy), ny);
  wmPageSet(u64(wmPageWDefUw), x1 - nx);
  wmPageSet(u64(wmPageWDefUh), y1 - ny);
}

@bare
void wmDefEnqueue(u64 kind, u64 slot, u64 oldG, u64 nextG) {
  final u64 t0 = tick_count();
  u64 flags = u64(wmDefFlagPending);
  final u64 prev = wmPage(u64(wmPageWDefOp));
  final u64 q = wmPage(u64(wmPageWDefQ));
  u64 enq = q & u64(0xFFFF);
  u64 coal = (q >> u64(16)) & u64(0xFFFF);
  u64 depth = (q >> u64(32)) & u64(0xFF);
  if (((prev >> u64(16)) & u64(wmDefFlagPending)) > u64(0)) {
    /* Last-wins on the same slot. Keep first vacated rect; expand union. */
    if (((prev >> u64(8)) & u64(0xFF)) == slot) {
      oldG = wmPage(u64(wmPageWDefOld));
      coal = coal + u64(1);
      if (depth > u64(0)) {
        depth = depth - u64(1);
      }
    } else {
      flags = flags | ((prev >> u64(16)) & u64(wmDefFlagGeomHold));
    }
  }
  wmDefUnionExpand(oldG);
  wmDefUnionExpand(nextG);
  wmPageSet(u64(wmPageWDefOp), kind | (slot << u64(8)) | (flags << u64(16)));
  wmPageSet(u64(wmPageWDefOld), oldG);
  wmPageSet(u64(wmPageWDefNext), nextG);
  wmPageSet(u64(wmPageWDefEnqTick), t0);
  enq = enq + u64(1);
  depth = depth + u64(1);
  if (depth > u64(1)) {
    depth = u64(1);
  }
  wmPageSet(u64(wmPageWDefQ), enq | (coal << u64(16)) | (depth << u64(32)));
  final u64 dt = tick_count() - t0;
  wmPageSet(u64(wmPageWIrqDt), dt);
  uartWrite(Rodata.addressOf(wmStrDefEnq), u64(12));
  uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
  uartWrite(Rodata.addressOf(wmStrY), u64(3));
  uartPutHex(kind, u64(1));
  uartWrite(Rodata.addressOf(wmStrW), u64(3));
  uartPutHex(slot, u64(1));
  uartNewline();
  uartWrite(Rodata.addressOf(wmStrIrq), u64(7));
  uartPutHex(dt, u64(2));
  uartNewline();
}

@bare
void wmDefClear(u64 slot) {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  if (slot >= u64(wmMaxWindows)) {
    return;
  }
  final u64 op = wmPage(u64(wmPageWDefOp));
  if (((op >> u64(8)) & u64(0xFF)) == slot) {
    wmPageSet(u64(wmPageWDefOp), u64(0));
    wmPageSet(u64(wmPageWDefUw), u64(0));
  }
  wmPageSet(u64(wmPageWPrepHave), u64(0));
  wmPageSet(u64(wmPageWDefPres), u64(0));
}

@bare
void wmIdlePrep(u64 fromSlot) {
  if (wmMeta(u64(wmMetaGfx)) < u64(1)) {
    return;
  }
  if (wmDeOn() < u64(1)) {
    return;
  }
  if (wmPageAddr() < u64(1)) {
    return;
  }
  /* BIOS de-desk is narrower; skip Skia idle prep so scroll is not held. */
  if (fbGeomWidth() < u64(1200)) {
    return;
  }
  if (((wmPage(u64(wmPageWDefOp)) >> u64(16)) & u64(wmDefFlagPending)) >
      u64(0)) {
    return;
  }
  /* Bit 4: this attach already paid idle max+restore chrome. */
  if ((wmPage(u64(wmPageWPrepHave)) & u64(16)) > u64(0)) {
    return;
  }
  if (fromSlot >= u64(wmMaxWindows)) {
    return;
  }
  final u64 fromCap = wmPage(wmPageLaunchOf(fromSlot));
  if (fromCap < u64(1)) {
    return;
  }
  if (fromCap > u64(2)) {
    return;
  }
  if (wmPrepBufEnsure() < u64(1)) {
    return;
  }
  if (wmPage(u64(wmPageWChromeHave)) < u64(1)) {
    return;
  }
  u64 slot = u64(wmMaxWindows);
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (wmPage(wmPageLaunchOf(i)) == u64(1)) {
      if (wmWindowUsable(i) > u64(0)) {
        if (wmGeomW(wmWin(i, u64(wmWinGeom))) >= u64(400)) {
          slot = i;
        }
      }
    }
    i = i + u64(1);
  }
  if (slot >= u64(wmMaxWindows)) {
    return;
  }
  final u64 have = wmPage(u64(wmPageWPrepHave));
  final u64 maxG = wmDefMaxGeom(slot);
  u64 win0 = u64(0);
  u64 win1 = u64(0);
  u64 win0Slot = u64(wmMaxWindows);
  u64 win1Slot = u64(wmMaxWindows);
  u64 i2 = u64(0);
  while (i2 < u64(wmMaxWindows)) {
    if (wmWindowUsable(i2) > u64(0)) {
      if (wmIsPanel(i2) < u64(1)) {
        if (wmIsOverlay(i2) < u64(1)) {
          u64 g = wmWin(i2, u64(wmWinGeom));
          if (i2 == slot) {
            g = maxG;
          }
          if (win0Slot >= u64(wmMaxWindows)) {
            win0Slot = i2;
            win0 = g;
          } else {
            if (win1Slot >= u64(wmMaxWindows)) {
              win1Slot = i2;
              win1 = g;
            }
          }
        }
      }
    }
    i2 = i2 + u64(1);
  }
  if ((have & u64(3)) == u64(3)) {
    wmPageSet(u64(wmPageWPrepHave), have | u64(16));
    return;
  }
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmIfHoldBegin(u64(wmIfReasonPrep));
  if ((have & u64(2)) < u64(1)) {
    final u64 rest = osgfx_chrome_prep_rest();
  }
  if (osgfx_chrome_prep(win0, win1) < u64(1)) {
    wmSetMeta(u64(wmMetaBusy), u64(0));
    wmIfHoldEnd();
    return;
  }
  wmPageSet(u64(wmPageWPrepHave), wmPage(u64(wmPageWPrepHave)) | u64(16));
  uartWrite(Rodata.addressOf(wmStrPrepMax), u64(11));
  uartNewline();
  wmSetMeta(u64(wmMetaBusy), u64(0));
  wmIfHoldEnd();
}

@bare
void wmDefDrain() {
  if (wmPageAddr() < u64(1)) {
    return;
  }
  if (wmActive() < u64(1)) {
    return;
  }
  if (wmMeta(u64(wmMetaBusy)) > u64(0)) {
    return;
  }
  final u64 packed = wmPage(u64(wmPageWDefOp));
  if (((packed >> u64(16)) & u64(wmDefFlagPending)) < u64(1)) {
    return;
  }
  final u64 kind = packed & u64(0xFF);
  final u64 slot = (packed >> u64(8)) & u64(0xFF);
  final u64 oldG = wmPage(u64(wmPageWDefOld));
  final u64 nextG = wmPage(u64(wmPageWDefNext));
  wmSetMeta(u64(wmMetaBusy), u64(1));
  wmIfHoldBegin(u64(wmIfReasonDrain));
  uartWrite(Rodata.addressOf(wmStrDefBegin), u64(14));
  uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
  uartNewline();
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    wmPointerRestore();
  }
  if (((packed >> u64(16)) & u64(wmDefFlagGeomHold)) > u64(0)) {
    if (slot < u64(wmMaxWindows)) {
      wmSetWin(slot, u64(wmWinGeom), nextG);
      wmSetWin(slot, u64(wmWinSeq), u64(0));
      wmSetMeta(u64(wmMetaTop), slot);
      wmeventEnqueueConfigure(slot);
    }
  }
  if (kind == u64(wmDefKindMax)) {
    /* HOLD: keep the last presented AABB on scanout. prep_present
     * punches wallpaper holes at old∪new; Seq0 lets blit paint an
     * uncommitted body. Client COMMIT + compose publishes VIS. */
    wmPageSet(u64(wmPageWDefOp), u64(0));
    if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
      wmPointerPlace(
          mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)));
    }
    wmSetMeta(u64(wmMetaBusy), u64(0));
    wmPageSet(u64(wmPageWDefUw), u64(0));
    uartWrite(Rodata.addressOf(wmStrDefCommit), u64(15));
    uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
    uartNewline();
    wmIfHoldEnd();
    return;
  } else {
    if (kind == u64(wmDefKindFocus)) {
      /* Rings are a HIT overlay from wmFocusTo. A decorated wmRepaintWindow
       * was the 1.1 s TCG hitch on every other raise. Client blit only
       * so a raise still stacks overlapping bodies. */
      if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
        if (slot < u64(wmMaxWindows)) {
          final u64 body = wmDrawWindow(slot, u64(1));
        }
      } else {
        if (slot < u64(wmMaxWindows)) {
          final u64 unused = wmRepaintWindow(slot);
        }
      }
    } else {
      if (kind == u64(wmDefKindMenu)) {
        wmPopDrainPaint(oldG, nextG);
      } else {
        if (kind == u64(wmDefKindDrag)) {
          u64 hold = u64(0);
          if (slot < u64(wmMaxWindows)) {
            if (wmWin(slot, u64(wmWinSeq)) < u64(1)) {
              hold = u64(1);
            }
          }
          if (hold > u64(0)) {
            /* Size HOLD: scanout + VIS stay put. Do not blit pending. */
            wmDamageClear();
          } else {
            if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
              /* Mailbox win0/win1 = live Dart geoms before the cache blit
               * so paint + chrome_key + hit-test share one origin.
               * Mail only — a gen bump owed a session tick that then
               * wmCompose'd 1.1 Mpx after every PresentPair. */
              wmGfxMail();
              final u64 dpx = osgfx_chrome_drag_step(oldG, nextG);
              /* Body travels with the cache/scanout move. A decorated
               * DrawWindow here was the 200 ms first-step TCG. */
              wmPageSet(u64(wmPageWDmgPx), dpx);
              wmDmgAcc(dpx, u64(2), u64(0), u64(1));
              wmGfxChromeStamp();
              /* Vacated strips + new window. Never a 1280×720 SCAN. */
              wmOpBegin(u64(wmOpKindDrag));
              final u64 vpx = wmPresentMove(
                  wmGeomX(oldG), wmGeomY(oldG), wmGeomW(oldG), wmGeomH(oldG),
                  wmGeomX(nextG), wmGeomY(nextG), wmGeomW(nextG),
                  wmGeomH(nextG));
              wmOpDone(vpx);
            } else {
              u64 ux = wmPage(u64(wmPageWDefUx));
              u64 uy = wmPage(u64(wmPageWDefUy));
              u64 uw = wmPage(u64(wmPageWDefUw));
              u64 uh = wmPage(u64(wmPageWDefUh));
              if (uw < u64(1)) {
                final u64 px = wmRepaintUnion2(
                    wmGeomX(oldG), wmGeomY(oldG), wmGeomW(oldG), wmGeomH(oldG),
                    wmGeomX(nextG), wmGeomY(nextG), wmGeomW(nextG),
                    wmGeomH(nextG));
              } else {
                final u64 px = wmRepaintRect(ux, uy, uw, uh);
              }
            }
            /* Discrete old/new already on scanout. Do not leave an AABB
             * for the pointer path to inherit. */
            wmDamageClear();
            if (slot < u64(wmMaxWindows)) {
              wmVisMaybePublish(slot);
            }
          }
        }
      }
    }
  }
  if (slot < u64(wmMaxWindows)) {
    wmPageSet(u64(wmPageWDefPres), slot + u64(1));
  }
  wmPageSet(u64(wmPageWDefOp), u64(0));
  wmPageSet(u64(wmPageWDefUw), u64(0));
  wmPageSet(
      u64(wmPageWDefQ), wmPage(u64(wmPageWDefQ)) & u64(0xFFFFFFFF));
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    wmPointerPlace(
        mouseState(u64(mouseWordX)), mouseState(u64(mouseWordY)));
  }
  wmSetMeta(u64(wmMetaBusy), u64(0));
  uartWrite(Rodata.addressOf(wmStrDefCommit), u64(15));
  uartPutHex(wmPage(u64(wmPageWEvSeq)), u64(8));
  uartNewline();
  wmLatNotePresent();
  wmIfHoldEnd();
}

@bare
void wmToggleMaxWindow(u64 wI) {
  if (wmWindowUsable(wI) < u64(1)) {
    return;
  }
  if (wmPageEnsure() < u64(1)) {
    return;
  }
  /* Dismiss a wallpaper/dock menu before the resize HOLD so the
   * client is not stuck painting a modal over seq==0. */
  if (wmPopOn() > u64(0)) {
    wmPopHide();
  }
  /* Consume a leftover stamp so maximize LAT is this geom change, not a
   * prior wallpaper click. Kind 5 is the chrome-interaction bucket. */
  if (wmPage(u64(wmPageWEvKind)) > u64(0)) {
    wmLatNotePresent();
  }
  wmLatStamp(u64(wmLatKindFocus));
  final u64 at = wmPageMaxOf(wI);
  final u64 old = wmWin(wI, u64(wmWinGeom));
  final u64 saved = wmPage(at);
  final u64 vis = wmVisGeom(wI);
  final u64 pend = wmPendGeomOf(wI);
  final u64 b = u64(wmBorder);
  u64 next = saved;
  if (saved < u64(1)) {
    wmPageSet(at, old);
    next = wmDefMaxGeom(wI);
  } else {
    wmPageSet(at, u64(0));
  }
  if (next == old) {
    /* Unpublished HOLD for this geom: kick, do not PHZ no-op. */
    if (pend > u64(0)) {
      wmHoldKick(wI);
      uartWrite(Rodata.addressOf(wmStrHoldRe), u64(13));
      uartPutHex(wI, u64(1));
      uartNewline();
      return;
    }
    if (vis > u64(0)) {
      if (vis != old) {
        wmSetWin(wI, u64(wmWinSeq), u64(0));
        wmeventEnqueueConfigure(wI);
        wmPendArm(wI, old);
        uartWrite(Rodata.addressOf(wmStrHoldRe), u64(13));
        uartPutHex(wI, u64(1));
        uartNewline();
        return;
      }
    }
    /* Stamp already took a seq. Close it so wait_present is not a 3s
     * timeout on a clamped no-op max (same 400×280 backing). */
    wmLatNotePresent();
    uartWrite(Rodata.addressOf(wmStrPhzMax), u64(10));
    uartNewline();
    return;
  }
  /* Requested geom for the client. VIS/hit-test stay on the last
   * presented AABB until COMMIT + compose publishes the generation. */
  wmSetWin(wI, u64(wmWinGeom), next);
  wmSetWin(wI, u64(wmWinSeq), u64(0));
  wmSetMeta(u64(wmMetaTop), wI);
  wmeventEnqueueConfigure(wI);
  wmPendArm(wI, next);
  uartWrite(Rodata.addressOf(wmStrHold), u64(10));
  uartPutHex(wI, u64(1));
  uartNewline();
  uartWrite(Rodata.addressOf(wmStrPhzMax), u64(10));
  uartNewline();
  wmDefEnqueue(u64(wmDefKindMax), wI, old, next);
  if (wmMeta(u64(wmMetaBusy)) > u64(0)) {
    final u64 op = wmPage(u64(wmPageWDefOp));
    wmPageSet(u64(wmPageWDefOp),
        op | (u64(wmDefFlagGeomHold) << u64(16)));
  }
  wmSetMeta(u64(wmMetaRectPixels), u64(wmRectComposePending));
  uartWrite(Rodata.addressOf(wmStrMax), u64(9));
  uartPutHex(wI, u64(1));
  uartNewline();
}

/// 1 if `wm de` is on and ([x], [y]) is on window [wI]'s SE resize
/// handle. The handle is the last [wmResizeEdge] pixels of the
/// content plus the border. Title-drag and close/min sit at the top;
/// this sits at the bottom-right. ADR-0121.
@bare
u64 wmResizeHit(u64 wI, u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmWindowUsable(wI) < u64(1)) {
    return u64(0);
  }
  final u64 g = wmHitGeom(wI);
  final u64 wx = wmHitAbsX(wI);
  final u64 wy = wmHitAbsY(wI);
  final u64 ww = wmGeomW(g);
  final u64 wh = wmGeomH(g);
  final u64 edge = u64(wmResizeEdge);
  final u64 b = u64(wmBorder);
  if (ww < edge) {
    return u64(0);
  }
  if (wh < edge) {
    return u64(0);
  }
  // UNSIGNED: `x < wx + ww - edge` is `x + edge < wx + ww`.
  if ((x + edge) < (wx + ww)) {
    return u64(0);
  }
  if (x >= (wx + ww + b)) {
    return u64(0);
  }
  if ((y + edge) < (wy + wh)) {
    return u64(0);
  }
  if (y >= (wy + wh + b)) {
    return u64(0);
  }
  return u64(1);
}

/// Topmost window whose compositor-owned title or resize geometry contains
/// ([x], [y]). Under gfx those pixels deliberately return [wmNoPixel] from
/// [wmWindowPixel] because session Skia owns their raster; input must still
/// hit the geometry rather than fall through to the desktop.
@bare
u64 wmDeGeomHit(u64 x, u64 y) {
  final u64 top = wmMeta(u64(wmMetaTop));
  if (top < u64(wmMaxWindows)) {
    if (wmTitleHit(top, x, y) > u64(0)) {
      return top;
    }
    if (wmResizeHit(top, x, y) > u64(0)) {
      return top;
    }
  }
  u64 i = u64(0);
  while (i < u64(wmMaxWindows)) {
    if (i != top) {
      if (wmTitleHit(i, x, y) > u64(0)) {
        return i;
      }
      if (wmResizeHit(i, x, y) > u64(0)) {
        return i;
      }
    }
    i = i + u64(1);
  }
  return u64(wmMaxWindows);
}

/// Tab / Shift-Tab: next or previous live non-panel window.
@bare
void wmFocusCycle(u64 back) {
  if (wmDeOn() < u64(1)) {
    return;
  }
  final u64 n = u64(wmMaxWindows);
  u64 cur = u64(0);
  final u64 start = wmFocusLive();
  if (start > u64(0)) {
    cur = start - u64(1);
  }
  u64 i = u64(0);
  while (i < n) {
    u64 cand = u64(0);
    if (back > u64(0)) {
      if (cur < u64(1)) {
        cand = n - u64(1);
      } else {
        cand = cur - u64(1);
      }
    } else {
      cand = cur + u64(1);
      if (cand >= n) {
        cand = u64(0);
      }
    }
    cur = cand;
    if (wmWindowUsable(cand) > u64(0)) {
      if (wmIsPanel(cand) < u64(1)) {
        if (wmWinOverlay(cand) < u64(1)) {
          wmSetMeta(u64(wmMetaTop), cand);
          wmFocusTo(cand);
          uartWrite(Rodata.addressOf(wmStrFocus), u64(9));
          uartPutHex(cand, u64(1));
          uartNewline();
          if (wmPageAddr() > u64(0)) {
            wmDefEnqueue(u64(wmDefKindFocus), cand,
                wmWin(cand, u64(wmWinGeom)), wmWin(cand, u64(wmWinGeom)));
          } else {
            final u64 unused = wmRepaintWindow(cand);
          }
          return;
        }
      }
    }
    i = i + u64(1);
  }
}

/// Left-press DE policy. Returns 1 if the press was consumed.
@bare
u64 wmDeGrab(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  final u64 k = wmMeta(u64(wmMetaPop));
  if (k == u64(wmPopLaunch)) {
    if (wmLaunchHit(x, y) > u64(0)) {
      final u64 row = wmLaunchRowAt(y);
      wmDePopHide();
      if (row < wmLaunchFiltN()) {
        wmDeSpawnRow(wmLaunchFiltAt(row));
      }
      return u64(1);
    }
    wmDePopHide();
  }
  if (k == u64(wmPopSwitch)) {
    if (wmSwitchHit(x, y) > u64(0)) {
      wmSwitchCommit();
      return u64(1);
    }
    wmDePopHide();
  }
  if (k == u64(wmPopPanel)) {
    if (wmPanelHit(x, y) > u64(0)) {
      return u64(1);
    }
    wmDePopHide();
  }
  if (wmStartHit(x, y) > u64(0)) {
    wmDeStartShow();
    return u64(1);
  }
  if (wmNoteHit(x, y) > u64(0)) {
    wmDePanelShow();
    return u64(1);
  }
  final u64 slot = wmSlotHit(x, y);
  if (slot < u64(wmMaxWindows)) {
    if (wmWin(slot, u64(wmWinState)) == u64(wmWinMin)) {
      wmRestWindow(slot);
    } else {
      wmSetMeta(u64(wmMetaTop), slot);
      wmFocusTo(slot);
      if (wmPageAddr() > u64(0)) {
        wmLatStamp(u64(wmLatKindFocus));
        wmDefEnqueue(u64(wmDefKindFocus), slot, wmWin(slot, u64(wmWinGeom)),
            wmWin(slot, u64(wmWinGeom)));
        wmSetMeta(u64(wmMetaRectPixels), u64(wmRectComposePending));
      } else {
        final u64 unused = wmRepaintWindow(slot);
      }
    }
    return u64(1);
  }
  /* CSD buttons belong to the topmost title under the pointer. Client
   * CSD makes wmWindowPixel a hole in the title band, so wmHit alone
   * falls through to the window underneath. wmDeGeomHit is the same
   * title/resize override wmGrab uses. A buried FILES min must not
   * fire through SET's title. */
  u64 hit = wmHit(x, y);
  final u64 geomHit = wmDeGeomHit(x, y);
  if (geomHit < u64(wmMaxWindows)) {
    hit = geomHit;
  }
  return wmDeCsdButtons(hit, geomHit, x, y);
}

/// Fire close/max/min from live abs geom. Same layout paint uses.
@bare
u64 wmDeCsdButtons(u64 hit, u64 geomHit, u64 x, u64 y) {
  wmCsdNote(hit, geomHit, x, y);
  if (hit >= u64(wmMaxWindows)) {
    return u64(0);
  }
  if (wmIsPanel(hit) > u64(0)) {
    return u64(0);
  }
  if (wmWinOverlay(hit) > u64(0)) {
    return u64(0);
  }
  if (wmCloseHit(hit, x, y) > u64(0)) {
    if (wmPageAddr() > u64(0)) {
      wmPageSet(u64(wmPageWCsdArmed), u64(1));
    }
    wmCloseWindow(hit);
    return u64(1);
  }
  if (wmMaxHit(hit, x, y) > u64(0)) {
    if (wmPageAddr() > u64(0)) {
      wmPageSet(u64(wmPageWCsdArmed), u64(1));
    }
    wmToggleMaxWindow(hit);
    return u64(1);
  }
  if (wmMinHit(hit, x, y) > u64(0)) {
    if (wmPageAddr() > u64(0)) {
      wmPageSet(u64(wmPageWCsdArmed), u64(1));
    }
    wmMinWindow(hit);
    return u64(1);
  }
  return u64(0);
}

/// Left-up CSD: a press that missed the down-edge (busy / sticky grab)
/// still closes when the pointer is on the live control disc. If the
/// down-edge already fired a button, do not toggle again.
@bare
u64 wmDeCsdRelease(u64 x, u64 y) {
  if (wmDeOn() < u64(1)) {
    return u64(0);
  }
  if (wmPageAddr() > u64(0)) {
    if (wmPage(u64(wmPageWCsdArmed)) > u64(0)) {
      wmPageSet(u64(wmPageWCsdArmed), u64(0));
      return u64(1);
    }
  }
  u64 hit = wmHit(x, y);
  final u64 geomHit = wmDeGeomHit(x, y);
  if (geomHit < u64(wmMaxWindows)) {
    hit = geomHit;
  }
  return wmDeCsdButtons(hit, geomHit, x, y);
}

/// `'OSGFX SESSION CHROME'` -- 20 bytes. Same token as osgfx_session.c.
@rodata
final List<u8> wmStrSessionChrome = const [
  u8(0x4F), u8(0x53), u8(0x47), u8(0x46), u8(0x58), u8(0x20),
  u8(0x53), u8(0x45), u8(0x53), u8(0x53), u8(0x49), u8(0x4F),
  u8(0x4E), u8(0x20), u8(0x43), u8(0x48), u8(0x52), u8(0x4F),
  u8(0x4D), u8(0x45),
];

/// `wm de` -- chrome plus DE widgets. Prints `WM DE ON` and scans
/// spawnable ELF names. No help line.
@bare
void wmDeCmd() {
  wmDeScanLaunch();
  wmWallLoad();
  uartWrite(Rodata.addressOf(wmStrDeOn), u64(8));
  uartWrite(Rodata.addressOf(wmStrH), u64(3));
  uartPutHex(u64(wmChromeH), u64(4));
  uartWrite(Rodata.addressOf(wmStrPx), u64(4));
  uartPutHex(fbGeomWidth() * u64(wmChromeH), u64(8));
  uartNewline();
  if (wmActive() > u64(0)) {
    wmCompose();
  } else if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    /* Mailbox + tick even before `wm on` so Venus DE chrome lands. */
    wmGfxKick();
    osgfx_guest_tick();
  }
  /* Serial door for de-session / sit-in: C tick may run on a private
   * stack where com1_puts races Graphite; Dart UART is reliable. */
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    if (wmDeOn() > u64(0)) {
      uartWrite(Rodata.addressOf(wmStrSessionChrome), u64(20));
      uartNewline();
    }
  }
}
