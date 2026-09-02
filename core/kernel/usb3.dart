// core/kernel/usb3.dart
//
// oscortex_core USB3: one xHCI transfer ring. Port reset, address
// device, GET_DESCRIPTOR / SET_CONFIGURATION / SET_PROTOCOL(0), one
// interrupt IN, one 8-byte HID boot report on the wire, then
// [usbHidApply]. The COM1 `usb feed` seam is USB2 and is not this
// path. The design is docs/design/usb-hid.md. The decision is
// ADR-0085.
//
// ---------------------------------------------------------------------------
// ZERO DONATED BSS. THAT IS THE WHOLE OF THE MERGE RULE.
// ---------------------------------------------------------------------------
// `part 'usb3.dart'` is appended after `part 'wmevent.dart'`. D7 still
// owns last place in `.bss`: this file donates none. Rings, contexts
// and the report buffer come from `allocFrame()` (identity-mapped).
// Previous-report state for the one report is locals -- the same
// shape USB2 used inside the COM1 feed seam. A `@bss` here would become the
// newest last block and move every harness that measures D7 to the
// end of `.bss`. USB0/USB1/USB2 stay in usb.dart and still donate
// nothing, so `kbdqStore` still abuts `wmeventStore`.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE DOES, AND WHAT IT DOES NOT
// ---------------------------------------------------------------------------
// Hidden command `usb hid`. Find qemu-xhci, set MEM|BME, reset the
// controller, program DCBAA / command ring / event ring, Run, walk
// PORTSC for a connected port, reset that port, Enable Slot, Address
// Device, three control transfers, Configure Endpoint, one Normal
// TRB on the interrupt ring, doorbell, poll the event ring.
//
// It does not attach a help line, does not add a syscall, does not
// write usb.dart, and does not run from `usbInit`. Bare `usb` is
// still USB0/USB1. `usb feed` is still USB2.

part of 'kmain.dart';

/// Command-register bits. USB3 DMAs, so MEM|BME both go on.
const int usb3CmdMem = 0x02;
const int usb3CmdBme = 0x04;
const int usb3CmdMemBme = 0x06;

/// Capability / operational offsets. CAPLENGTH is a byte at BAR+0.
const int usb3CapHcsparams1 = 0x04;
const int usb3CapHcsparams2 = 0x08;
const int usb3CapHccparams1 = 0x10;
const int usb3CapDboff = 0x14;
const int usb3CapRtsoff = 0x18;
const int usb3OpUsbcmd = 0x00;
const int usb3OpUsbsts = 0x04;
const int usb3OpPagesize = 0x08;
const int usb3OpCrcr = 0x18;
const int usb3OpDcbaap = 0x30;
const int usb3OpConfig = 0x38;
const int usb3OpPortsc = 0x400;

const int usb3CmdRs = 0x01;
const int usb3CmdHcrst = 0x02;
const int usb3StsHch = 0x01;
const int usb3StsCnr = 0x800;
const int usb3HccCsz = 0x04;
const int usb3HccPpc = 0x08;

const int usb3PortCcs = 0x01;
const int usb3PortPed = 0x02;
const int usb3PortPr = 0x10;
const int usb3PortPp = 0x200;
const int usb3PortSpeedShift = 10;
const int usb3PortW1c = 0x00FE0000;
const int usb3PortPrc = 0x200000;

const int usb3Im0 = 0x20;
const int usb3Erstsz = 0x08;
const int usb3Erstba = 0x10;
const int usb3Erdp = 0x18;
const int usb3ErdpEhb = 0x08;

const int usb3TrbCycle = 0x01;
const int usb3TrbTc = 0x02;
const int usb3TrbIoc = 0x20;
const int usb3TrbIdt = 0x40;
const int usb3TrbTypeShift = 10;
const int usb3TrbNormal = 1;
const int usb3TrbSetup = 2;
const int usb3TrbData = 3;
const int usb3TrbStatus = 4;
const int usb3TrbLink = 6;
const int usb3TrbEnableSlot = 9;
const int usb3TrbAddress = 11;
const int usb3TrbConfigEp = 12;
const int usb3TrbXferEvent = 32;
const int usb3TrbCmdEvent = 33;
const int usb3TrtIn = 3;
const int usb3TrtNone = 0;
const int usb3CcSuccess = 1;
const int usb3CcShort = 13;

const int usb3RingTrbs = 256;
const int usb3RingBytes = 4096;
const int usb3PollLimit = 0x200000;
const int usb3HidPoll = 0x800000;
const int usb3TimedOut = 0x100000000;
// Register waits (usb3WaitBits) OR the last MMIO value onto this
// sentinel, so those callers compare with >=. Event waits return
// either this exact value or a packed event whose dequeue index
// lives in bits 47:40 -- that word is >= the sentinel on every
// real completion, so those callers must compare with ==.

/// Frame 0 layout: DCBAA (512) then ERST (16) then a scratch word.
const int usb3OffDcbaa = 0;
const int usb3OffErst = 512;
const int usb3OffDevctx = 0;
const int usb3OffInctx = 2048;
const int usb3OffEp0 = 0;
const int usb3OffInt = 2048;
const int usb3OffBuf = 3072;
const int usb3OffRpt = 3584;

const int usb3EpTypeCtrl = 4;
const int usb3EpTypeIntIn = 7;
const int usb3DciEp0 = 1;
const int usb3DciIntIn = 3;

/// `"usb hid"` -- 7 bytes. Longest-first so `usb` cannot swallow it.
@rodata
final List<u8> usb3StrCmdHid = const [
  u8(0x75), u8(0x73), u8(0x62), u8(0x20),
  u8(0x68), u8(0x69), u8(0x64),
];

/// `"USB HID NONE\n"` -- 13 bytes.
@rodata
final List<u8> usb3StrNone = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// `"USB HID WAIT\n"` -- 13 bytes. Posted after the interrupt TRB
/// and the doorbell, so a harness can inject a USB key into a live
/// transfer, not into a canned apply.
@rodata
final List<u8> usb3StrWait = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x57), u8(0x41), u8(0x49), u8(0x54), u8(0x0A),
];

/// `"USB HID TMO\n"` -- 12 bytes.
@rodata
final List<u8> usb3StrTmo = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x54), u8(0x4D), u8(0x4F), u8(0x0A),
];

/// `"USB HID FAIL "` -- 13 bytes.
@rodata
final List<u8> usb3StrFail = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x46), u8(0x41), u8(0x49), u8(0x4C), u8(0x20),
];

/// `"USB HID PORT "` -- 13 bytes.
@rodata
final List<u8> usb3StrPort = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x50), u8(0x4F), u8(0x52), u8(0x54), u8(0x20),
];

/// `"USB HID DESC "` -- 13 bytes.
@rodata
final List<u8> usb3StrDesc = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x44), u8(0x45), u8(0x53), u8(0x43), u8(0x20),
];

/// `"USB HID RPT "` -- 12 bytes. The eight wire bytes, then the
/// translated kbdq events. Not `USB FEED`.
@rodata
final List<u8> usb3StrRpt = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x52), u8(0x50), u8(0x54), u8(0x20),
];

/// `"USB HID"` -- 7 bytes. Event dump prefix, same shape as USB FEED.
@rodata
final List<u8> usb3StrHid = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44),
];

/// `"USB CMD STUCK\n"` -- 14 bytes.
@rodata
final List<u8> usb3StrStuck = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x43), u8(0x4D), u8(0x44), u8(0x20),
  u8(0x53), u8(0x54), u8(0x55), u8(0x43),
  u8(0x4B), u8(0x0A),
];

/// `"USB HID NOFRM\n"` -- 14 bytes.
@rodata
final List<u8> usb3StrNofrm = const [
  u8(0x55), u8(0x53), u8(0x42), u8(0x20),
  u8(0x48), u8(0x49), u8(0x44), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x46), u8(0x52),
  u8(0x4D), u8(0x0A),
];

/// Called from `kmain`. No `.bss` to zero. Prints nothing.
@bare
void usb3Init() {}

/// 32-bit MMIO store. Twin of [usbRegGet], kept out of usb.dart so
/// USB1's "no Volatile store" contract stays true.
@bare
void usb3RegPut(u64 bar, u64 off, u64 val) {
  Volatile<u32>.fromAddress(bar + off).value = val.toU32();
}

/// 64-bit MMIO store as a low/high pair. Identity map is under 4 GiB,
/// so the high dword is zero for every frame we hand the controller.
@bare
void usb3RegPut64(u64 bar, u64 off, u64 val) {
  usb3RegPut(bar, off, val & u64(0xFFFFFFFF));
  usb3RegPut(bar, off + u64(4), val >> u64(32));
}

/// One 16-byte TRB. Four Volatile dwords so the store is not hoisted
/// (ADR-0044 / GAP-0071).
@bare
void usb3TrbPut(u64 addr, u64 p0, u64 p1, u64 st, u64 ctl) {
  Volatile<u32>.fromAddress(addr + u64(0)).value = p0.toU32();
  Volatile<u32>.fromAddress(addr + u64(4)).value = p1.toU32();
  Volatile<u32>.fromAddress(addr + u64(8)).value = st.toU32();
  Volatile<u32>.fromAddress(addr + u64(12)).value = ctl.toU32();
}

@bare
u64 usb3TrbGet(u64 addr, u64 word) {
  return Volatile<u32>.fromAddress(addr + (word << u64(2))).value.toU64();
}

@bare
u64 usb3WaitBits(u64 bar, u64 off, u64 mask, u64 want) {
  u64 n = u64(usb3PollLimit);
  u64 v = u64(0);
  while (u64(0) < n) {
    v = usbRegGet(bar, off);
    if ((v & mask) == want) {
      return v;
    }
    n = n - u64(1);
  }
  return u64(usb3TimedOut) | v;
}

/// Clear the last TRB of a 256-TRB page and install a Link TRB that
/// wraps to [ring] with TC set. Cycle bit of the Link is 1 -- the
/// first pass.
@bare
void usb3RingLink(u64 ring) {
  final u64 last = ring + u64(usb3RingBytes) - u64(16);
  usb3TrbPut(
      last, ring, u64(0), u64(0),
      u64(usb3TrbCycle) | u64(usb3TrbTc) |
          (u64(usb3TrbLink) << u64(usb3TrbTypeShift)));
}

/// Consume one event-ring TRB if its cycle matches [ccs]. Returns 0
/// if the ring is empty, else packs type (8), completion code (8),
/// slot (8), and endpoint id (8) into a word, and writes the four
/// TRB dwords to [out] (16 bytes). Advances ERDP.
@bare
u64 usb3EventTake(u64 ev, u64 deq, u64 ccs, u64 rt, u64 out) {
  final u64 addr = ev + (deq << u64(4));
  final u64 ctl = usb3TrbGet(addr, u64(3));
  if ((ctl & u64(1)) != ccs) {
    return u64(0);
  }
  Volatile<u32>.fromAddress(out + u64(0)).value =
      usb3TrbGet(addr, u64(0)).toU32();
  Volatile<u32>.fromAddress(out + u64(4)).value =
      usb3TrbGet(addr, u64(1)).toU32();
  Volatile<u32>.fromAddress(out + u64(8)).value =
      usb3TrbGet(addr, u64(2)).toU32();
  Volatile<u32>.fromAddress(out + u64(12)).value = ctl.toU32();
  u64 next = deq + u64(1);
  u64 nccs = ccs;
  if (next == u64(usb3RingTrbs)) {
    next = u64(0);
    nccs = ccs ^ u64(1);
  }
  final u64 erdp = ev + (next << u64(4));
  usb3RegPut64(rt, u64(usb3Im0) + u64(usb3Erdp), erdp | u64(usb3ErdpEhb));
  final u64 typ = (ctl >> u64(usb3TrbTypeShift)) & u64(0x3F);
  final u64 st = usb3TrbGet(addr, u64(2));
  final u64 cc = (st >> u64(24)) & u64(0xFF);
  final u64 slot = (ctl >> u64(24)) & u64(0xFF);
  final u64 epid = (ctl >> u64(16)) & u64(0x1F);
  return u64(1) |
      (typ << u64(8)) |
      (cc << u64(16)) |
      (slot << u64(24)) |
      (epid << u64(32)) |
      (next << u64(40)) |
      (nccs << u64(48));
}

/// Drain Port Status Change events and return the first command or
/// transfer event, or [usb3TimedOut]. [state] holds deq at +0 and
/// ccs at +8; both are updated.
@bare
u64 usb3WaitEvent(u64 ev, u64 state, u64 rt, u64 want, u64 limit) {
  u64 n = limit;
  while (u64(0) < n) {
    final u64 deq = Volatile<u64>.fromAddress(state + u64(0)).value;
    final u64 ccs = Volatile<u64>.fromAddress(state + u64(8)).value;
    final u64 got = usb3EventTake(ev, deq, ccs, rt, state + u64(16));
    if (got > u64(0)) {
      Volatile<u64>.fromAddress(state + u64(0)).value = (got >> u64(40)) & u64(0xFF);
      Volatile<u64>.fromAddress(state + u64(8)).value = (got >> u64(48)) & u64(1);
      final u64 typ = (got >> u64(8)) & u64(0xFF);
      if (typ == want) {
        return got;
      }
    }
    n = n - u64(1);
  }
  return u64(usb3TimedOut);
}

/// Enqueue one command TRB at [idx] with cycle [ccs], ring doorbell 0,
/// wait for a Command Completion Event. Returns the packed event word
/// (see [usb3EventTake]) or [usb3TimedOut]. Updates [state] deq/ccs
/// and writes the next command index/cycle to [state]+32/+40.
@bare
u64 usb3Command(
    u64 cmd, u64 idx, u64 ccs, u64 ev, u64 state, u64 rt, u64 db, u64 p0, u64 ctlHi) {
  final u64 addr = cmd + (idx << u64(4));
  final u64 ctl = ccs | ctlHi;
  usb3TrbPut(addr, p0, u64(0), u64(0), ctl);
  u64 nidx = idx + u64(1);
  u64 nccs = ccs;
  if (nidx == u64(usb3RingTrbs) - u64(1)) {
    nidx = u64(0);
    nccs = ccs ^ u64(1);
  }
  Volatile<u64>.fromAddress(state + u64(32)).value = nidx;
  Volatile<u64>.fromAddress(state + u64(40)).value = nccs;
  usb3RegPut(db, u64(0), u64(0));
  return usb3WaitEvent(ev, state, rt, u64(usb3TrbCmdEvent), u64(usb3PollLimit));
}

/// One control transfer on EP0: Setup (IDT), optional Data, Status.
/// [trt] is 0 (no data) or 3 (IN). [len] is the data stage length.
@bare
u64 usb3Control(
    u64 ep0,
    u64 eidx,
    u64 eccs,
    u64 ev,
    u64 state,
    u64 rt,
    u64 db,
    u64 slot,
    u64 setup0,
    u64 setup1,
    u64 data,
    u64 len,
    u64 trt) {
  final u64 s0 = ep0 + (eidx << u64(4));
  final u64 setupCtl = eccs |
      u64(usb3TrbIdt) |
      (u64(usb3TrbSetup) << u64(usb3TrbTypeShift)) |
      (trt << u64(16));
  usb3TrbPut(s0, setup0, setup1, u64(8), setupCtl);
  u64 idx = eidx + u64(1);
  u64 ccs = eccs;
  if (idx == u64(usb3RingTrbs) - u64(1)) {
    idx = u64(0);
    ccs = eccs ^ u64(1);
  }
  if (len > u64(0)) {
    final u64 d0 = ep0 + (idx << u64(4));
    final u64 dataCtl = ccs |
        (u64(usb3TrbData) << u64(usb3TrbTypeShift)) |
        (u64(1) << u64(16));
    usb3TrbPut(d0, data, u64(0), len, dataCtl);
    idx = idx + u64(1);
    if (idx == u64(usb3RingTrbs) - u64(1)) {
      idx = u64(0);
      ccs = ccs ^ u64(1);
    }
  }
  final u64 st0 = ep0 + (idx << u64(4));
  u64 dir = u64(1);
  if (trt == u64(usb3TrtIn)) {
    dir = u64(0);
  }
  final u64 stCtl = ccs |
      u64(usb3TrbIoc) |
      (u64(usb3TrbStatus) << u64(usb3TrbTypeShift)) |
      (dir << u64(16));
  usb3TrbPut(st0, u64(0), u64(0), u64(0), stCtl);
  idx = idx + u64(1);
  if (idx == u64(usb3RingTrbs) - u64(1)) {
    idx = u64(0);
    ccs = ccs ^ u64(1);
  }
  Volatile<u64>.fromAddress(state + u64(48)).value = idx;
  Volatile<u64>.fromAddress(state + u64(56)).value = ccs;
  usb3RegPut(db, slot << u64(2), u64(usb3DciEp0));
  return usb3WaitEvent(ev, state, rt, u64(usb3TrbXferEvent), u64(usb3PollLimit));
}

/// Fill Slot + EP0 of an Address Device input context. [csz] is 32 or 64.
@bare
void usb3FillAddress(u64 inctx, u64 csz, u64 port, u64 speed, u64 ep0) {
  u64 i = u64(0);
  while (i < u64(2048)) {
    Volatile<u32>.fromAddress(inctx + i).value = u64(0).toU32();
    i = i + u64(4);
  }
  Volatile<u32>.fromAddress(inctx + u64(4)).value = u64(0x03).toU32();
  final u64 slot = inctx + csz;
  final u64 dw0 = (speed << u64(20)) | (u64(1) << u64(27));
  Volatile<u32>.fromAddress(slot + u64(0)).value = dw0.toU32();
  Volatile<u32>.fromAddress(slot + u64(4)).value = (port << u64(16)).toU32();
  final u64 ep = slot + csz;
  u64 mps = u64(8);
  if (speed == u64(3)) {
    mps = u64(64);
  }
  if (speed == u64(4)) {
    mps = u64(512);
  }
  Volatile<u32>.fromAddress(ep + u64(4)).value =
      (u64(3) << u64(1) | (u64(usb3EpTypeCtrl) << u64(3)) | (mps << u64(16)))
          .toU32();
  Volatile<u32>.fromAddress(ep + u64(8)).value = (ep0 | u64(1)).toU32();
  Volatile<u32>.fromAddress(ep + u64(12)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ep + u64(16)).value = u64(8).toU32();
}

/// Add the interrupt IN endpoint (DCI 3) to an already-addressed slot.
@bare
void usb3FillConfig(u64 inctx, u64 csz, u64 port, u64 speed, u64 ep0, u64 intep) {
  u64 i = u64(0);
  while (i < u64(2048)) {
    Volatile<u32>.fromAddress(inctx + i).value = u64(0).toU32();
    i = i + u64(4);
  }
  Volatile<u32>.fromAddress(inctx + u64(4)).value = u64(0x09).toU32();
  final u64 slot = inctx + csz;
  final u64 dw0 = (speed << u64(20)) | (u64(3) << u64(27));
  Volatile<u32>.fromAddress(slot + u64(0)).value = dw0.toU32();
  Volatile<u32>.fromAddress(slot + u64(4)).value = (port << u64(16)).toU32();
  final u64 ep = inctx + (csz * u64(4));
  Volatile<u32>.fromAddress(ep + u64(0)).value = (u64(7) << u64(16)).toU32();
  Volatile<u32>.fromAddress(ep + u64(4)).value =
      (u64(3) << u64(1) | (u64(usb3EpTypeIntIn) << u64(3)) | (u64(8) << u64(16)))
          .toU32();
  Volatile<u32>.fromAddress(ep + u64(8)).value = (intep | u64(1)).toU32();
  Volatile<u32>.fromAddress(ep + u64(12)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ep + u64(16)).value = u64(8).toU32();
}

/// Power every port, then return the 1-based index of the first port
/// with CCS, or 0.
@bare
u64 usb3FindPort(u64 op, u64 ports, u64 ppc) {
  u64 p = u64(1);
  while (p <= ports) {
    final u64 off = u64(usb3OpPortsc) + ((p - u64(1)) << u64(4));
    final u64 cur = usbRegGet(op, off);
    if (ppc > u64(0)) {
      if ((cur & u64(usb3PortPp)) < u64(usb3PortPp)) {
        usb3RegPut(op, off, (cur & u64(0xFF01FFFF)) | u64(usb3PortPp));
      }
    }
    p = p + u64(1);
  }
  u64 spin = u64(0x10000);
  while (u64(0) < spin) {
    spin = spin - u64(1);
  }
  p = u64(1);
  while (p <= ports) {
    final u64 off = u64(usb3OpPortsc) + ((p - u64(1)) << u64(4));
    final u64 cur = usbRegGet(op, off);
    if ((cur & u64(usb3PortCcs)) > u64(0)) {
      return p;
    }
    p = p + u64(1);
  }
  return u64(0);
}

/// Port reset. Returns 0 on PED, 1 on timeout / no enable.
@bare
u64 usb3PortReset(u64 op, u64 port) {
  final u64 off = u64(usb3OpPortsc) + ((port - u64(1)) << u64(4));
  final u64 cur = usbRegGet(op, off);
  usb3RegPut(
      op, off, (cur & u64(0xFF01FFFF)) | u64(usb3PortPp) | u64(usb3PortPr));
  u64 n = u64(usb3PollLimit);
  u64 v = u64(0);
  while (u64(0) < n) {
    v = usbRegGet(op, off);
    if ((v & u64(usb3PortPr)) == u64(0)) {
      if ((v & u64(usb3PortW1c)) > u64(0)) {
        usb3RegPut(op, off, (v & u64(0xFF01FFFF)) | (v & u64(usb3PortW1c)));
      }
      if ((v & u64(usb3PortPed)) > u64(0)) {
        return u64(0);
      }
    }
    n = n - u64(1);
  }
  return u64(1);
}

/// Print `USB HID FAIL <hex>\n`.
@bare
void usb3Fail(u64 code) {
  uartWrite(Rodata.addressOf(usb3StrFail), u64(13));
  uartPutHex(code, u64(8));
  uartNewline();
}

/// `usb hid` -- one real xHCI HID boot report into [usbHidApply].
///
/// Runs in TASK context. Five frames from `allocFrame()`. Never
/// freed: 20 KiB of 128 MiB, held for the boot. The doorbell store
/// is the kick. The printed WAIT line is the harness sync: a USB
/// key injected before that line can miss the posted TRB.
@bare
void usb3Hid() {
  final u64 bdf = usbFindXhci();
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(usbStrNone), u64(9));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(usb3CmdMem)) < u64(usb3CmdMem)) {
    uartWrite(Rodata.addressOf(usbStrNocmd), u64(10));
    return;
  }
  pciWrite32(
      bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(usb3CmdMemBme));
  final u64 after = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((after & u64(usb3CmdBme)) < u64(usb3CmdBme)) {
    uartWrite(Rodata.addressOf(usb3StrStuck), u64(14));
    return;
  }
  final u64 bar = usbReadBar0(bus, dev, fn);
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(usbStrNobar), u64(10));
    return;
  }

  final u64 cap0 = usbRegGet(bar, u64(0));
  final u64 caplength = cap0 & u64(0xFF);
  final u64 hcs1 = usbRegGet(bar, u64(usb3CapHcsparams1));
  final u64 slots = hcs1 & u64(0xFF);
  final u64 ports = (hcs1 >> u64(24)) & u64(0xFF);
  final u64 hcc1 = usbRegGet(bar, u64(usb3CapHccparams1));
  final u64 dboff = usbRegGet(bar, u64(usb3CapDboff)) & u64(0xFFFFFFE0);
  final u64 rtsoff = usbRegGet(bar, u64(usb3CapRtsoff)) & u64(0xFFFFFFE0);
  u64 csz = u64(32);
  if ((hcc1 & u64(usb3HccCsz)) > u64(0)) {
    csz = u64(64);
  }
  u64 ppc = u64(0);
  if ((hcc1 & u64(usb3HccPpc)) > u64(0)) {
    ppc = u64(1);
  }
  final u64 op = bar + caplength;
  final u64 db = bar + dboff;
  final u64 rt = bar + rtsoff;

  final u64 cnr0 = usb3WaitBits(op, u64(usb3OpUsbsts), u64(usb3StsCnr), u64(0));
  if (cnr0 >= u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  usb3RegPut(op, u64(usb3OpUsbcmd), u64(usb3CmdHcrst));
  final u64 rst = usb3WaitBits(op, u64(usb3OpUsbcmd), u64(usb3CmdHcrst), u64(0));
  if (rst >= u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 cnr1 = usb3WaitBits(op, u64(usb3OpUsbsts), u64(usb3StsCnr), u64(0));
  if (cnr1 >= u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }

  final u64 page0 = allocFrame();
  final u64 cmdRing = allocFrame();
  final u64 evRing = allocFrame();
  final u64 ctxPage = allocFrame();
  final u64 xferPage = allocFrame();
  if (page0 < u64(1)) {
    uartWrite(Rodata.addressOf(usb3StrNofrm), u64(14));
    return;
  }
  if (cmdRing < u64(1)) {
    uartWrite(Rodata.addressOf(usb3StrNofrm), u64(14));
    return;
  }
  if (evRing < u64(1)) {
    uartWrite(Rodata.addressOf(usb3StrNofrm), u64(14));
    return;
  }
  if (ctxPage < u64(1)) {
    uartWrite(Rodata.addressOf(usb3StrNofrm), u64(14));
    return;
  }
  if (xferPage < u64(1)) {
    uartWrite(Rodata.addressOf(usb3StrNofrm), u64(14));
    return;
  }
  vmZeroFrame(page0);
  vmZeroFrame(cmdRing);
  vmZeroFrame(evRing);
  vmZeroFrame(ctxPage);
  vmZeroFrame(xferPage);

  final u64 dcbaa = page0 + u64(usb3OffDcbaa);
  final u64 erst = page0 + u64(usb3OffErst);
  final u64 state = page0 + u64(640);
  final u64 devctx = ctxPage + u64(usb3OffDevctx);
  final u64 inctx = ctxPage + u64(usb3OffInctx);
  final u64 ep0 = xferPage + u64(usb3OffEp0);
  final u64 intep = xferPage + u64(usb3OffInt);
  final u64 buf = xferPage + u64(usb3OffBuf);
  final u64 rpt = xferPage + u64(usb3OffRpt);

  usb3RingLink(cmdRing);
  usb3RingLink(ep0);
  usb3RingLink(intep);

  Volatile<u64>.fromAddress(erst + u64(0)).value = evRing;
  Volatile<u32>.fromAddress(erst + u64(8)).value = u64(usb3RingTrbs).toU32();
  Volatile<u32>.fromAddress(erst + u64(12)).value = u64(0).toU32();

  u64 maxEn = slots;
  if (maxEn < u64(1)) {
    maxEn = u64(1);
  }
  if (maxEn > u64(64)) {
    maxEn = u64(64);
  }
  usb3RegPut(op, u64(usb3OpConfig), maxEn);
  usb3RegPut64(op, u64(usb3OpDcbaap), dcbaa);
  usb3RegPut64(op, u64(usb3OpCrcr), cmdRing | u64(1));
  usb3RegPut(rt, u64(usb3Im0) + u64(usb3Erstsz), u64(1));
  usb3RegPut64(rt, u64(usb3Im0) + u64(usb3Erstba), erst);
  usb3RegPut64(rt, u64(usb3Im0) + u64(usb3Erdp), evRing | u64(usb3ErdpEhb));

  usb3RegPut(op, u64(usb3OpUsbcmd), u64(usb3CmdRs));
  final u64 run = usb3WaitBits(op, u64(usb3OpUsbsts), u64(usb3StsHch), u64(0));
  if (run >= u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }

  final u64 port = usb3FindPort(op, ports, ppc);
  if (port < u64(1)) {
    uartWrite(Rodata.addressOf(usb3StrNone), u64(13));
    return;
  }
  if (usb3PortReset(op, port) > u64(0)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 portsc = usbRegGet(
      op, u64(usb3OpPortsc) + ((port - u64(1)) << u64(4)));
  final u64 speed = (portsc >> u64(usb3PortSpeedShift)) & u64(0xF);
  uartWrite(Rodata.addressOf(usb3StrPort), u64(13));
  uartPutHex(port, u64(2));
  uartSpace();
  uartPutHex(speed, u64(1));
  uartNewline();

  Volatile<u64>.fromAddress(state + u64(0)).value = u64(0);
  Volatile<u64>.fromAddress(state + u64(8)).value = u64(1);
  Volatile<u64>.fromAddress(state + u64(32)).value = u64(0);
  Volatile<u64>.fromAddress(state + u64(40)).value = u64(1);
  Volatile<u64>.fromAddress(state + u64(48)).value = u64(0);
  Volatile<u64>.fromAddress(state + u64(56)).value = u64(1);

  final u64 en = usb3Command(
      cmdRing,
      u64(0),
      u64(1),
      evRing,
      state,
      rt,
      db,
      u64(0),
      u64(usb3TrbEnableSlot) << u64(usb3TrbTypeShift));
  if (en == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 enCc = (en >> u64(16)) & u64(0xFF);
  if (enCc != u64(usb3CcSuccess)) {
    usb3Fail(enCc);
    return;
  }
  final u64 slot = (en >> u64(24)) & u64(0xFF);
  if (slot < u64(1)) {
    usb3Fail(u64(0));
    return;
  }
  Volatile<u64>.fromAddress(dcbaa + (slot << u64(3))).value = devctx;

  usb3FillAddress(inctx, csz, port, speed, ep0);
  final u64 cidx = Volatile<u64>.fromAddress(state + u64(32)).value;
  final u64 ccs = Volatile<u64>.fromAddress(state + u64(40)).value;
  final u64 ad = usb3Command(
      cmdRing,
      cidx,
      ccs,
      evRing,
      state,
      rt,
      db,
      inctx,
      (u64(usb3TrbAddress) << u64(usb3TrbTypeShift)) | (slot << u64(24)));
  if (ad == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 adCc = (ad >> u64(16)) & u64(0xFF);
  if (adCc != u64(usb3CcSuccess)) {
    usb3Fail(adCc);
    return;
  }

  u64 eidx = Volatile<u64>.fromAddress(state + u64(48)).value;
  u64 eccs = Volatile<u64>.fromAddress(state + u64(56)).value;
  final u64 gd = usb3Control(
      ep0,
      eidx,
      eccs,
      evRing,
      state,
      rt,
      db,
      slot,
      u64(0x01000680),
      u64(0x00120000),
      buf,
      u64(18),
      u64(usb3TrtIn));
  if (gd == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 gdCc = (gd >> u64(16)) & u64(0xFF);
  if (gdCc != u64(usb3CcSuccess)) {
    if (gdCc != u64(usb3CcShort)) {
      usb3Fail(gdCc);
      return;
    }
  }
  final u64 blen = Volatile<u8>.fromAddress(buf + u64(0)).value.toU64();
  final u64 btype = Volatile<u8>.fromAddress(buf + u64(1)).value.toU64();
  final u64 vid = Volatile<u8>.fromAddress(buf + u64(8)).value.toU64() |
      (Volatile<u8>.fromAddress(buf + u64(9)).value.toU64() << u64(8));
  final u64 pid = Volatile<u8>.fromAddress(buf + u64(10)).value.toU64() |
      (Volatile<u8>.fromAddress(buf + u64(11)).value.toU64() << u64(8));
  uartWrite(Rodata.addressOf(usb3StrDesc), u64(13));
  uartPutHex(blen, u64(2));
  uartSpace();
  uartPutHex(btype, u64(2));
  uartSpace();
  uartPutHex(vid, u64(4));
  conPutc(u8(0x3A));
  uartPutHex(pid, u64(4));
  uartNewline();

  eidx = Volatile<u64>.fromAddress(state + u64(48)).value;
  eccs = Volatile<u64>.fromAddress(state + u64(56)).value;
  final u64 sc = usb3Control(
      ep0,
      eidx,
      eccs,
      evRing,
      state,
      rt,
      db,
      slot,
      u64(0x00010900),
      u64(0),
      u64(0),
      u64(0),
      u64(usb3TrtNone));
  if (sc == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 scCc = (sc >> u64(16)) & u64(0xFF);
  if (scCc != u64(usb3CcSuccess)) {
    usb3Fail(scCc);
    return;
  }

  eidx = Volatile<u64>.fromAddress(state + u64(48)).value;
  eccs = Volatile<u64>.fromAddress(state + u64(56)).value;
  final u64 sp = usb3Control(
      ep0,
      eidx,
      eccs,
      evRing,
      state,
      rt,
      db,
      slot,
      u64(0x00000B21),
      u64(0),
      u64(0),
      u64(0),
      u64(usb3TrtNone));
  if (sp == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 spCc = (sp >> u64(16)) & u64(0xFF);
  if (spCc != u64(usb3CcSuccess)) {
    usb3Fail(spCc);
    return;
  }

  usb3FillConfig(inctx, csz, port, speed, ep0, intep);
  final u64 kidx = Volatile<u64>.fromAddress(state + u64(32)).value;
  final u64 kccs = Volatile<u64>.fromAddress(state + u64(40)).value;
  final u64 cfg = usb3Command(
      cmdRing,
      kidx,
      kccs,
      evRing,
      state,
      rt,
      db,
      inctx,
      (u64(usb3TrbConfigEp) << u64(usb3TrbTypeShift)) | (slot << u64(24)));
  if (cfg == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 cfgCc = (cfg >> u64(16)) & u64(0xFF);
  if (cfgCc != u64(usb3CcSuccess)) {
    usb3Fail(cfgCc);
    return;
  }

  u64 r = u64(0);
  while (r < u64(8)) {
    Volatile<u8>.fromAddress(rpt + r).value = u8(0);
    r = r + u64(1);
  }
  final u64 nctl = u64(1) |
      u64(usb3TrbIoc) |
      (u64(usb3TrbNormal) << u64(usb3TrbTypeShift));
  usb3TrbPut(intep, rpt, u64(0), u64(8), nctl);
  usb3RegPut(db, slot << u64(2), u64(usb3DciIntIn));
  uartWrite(Rodata.addressOf(usb3StrWait), u64(13));

  final u64 xfer =
      usb3WaitEvent(evRing, state, rt, u64(usb3TrbXferEvent), u64(usb3HidPoll));
  if (xfer == u64(usb3TimedOut)) {
    uartWrite(Rodata.addressOf(usb3StrTmo), u64(12));
    return;
  }
  final u64 xCc = (xfer >> u64(16)) & u64(0xFF);
  if (xCc != u64(usb3CcSuccess)) {
    if (xCc != u64(usb3CcShort)) {
      usb3Fail(xCc);
      return;
    }
  }

  final u64 mods = Volatile<u8>.fromAddress(rpt + u64(0)).value.toU64();
  final u64 usage = Volatile<u8>.fromAddress(rpt + u64(2)).value.toU64();
  uartWrite(Rodata.addressOf(usb3StrRpt), u64(12));
  u64 b = u64(0);
  while (b < u64(8)) {
    uartPutHex(Volatile<u8>.fromAddress(rpt + b).value.toU64(), u64(2));
    b = b + u64(1);
  }
  uartNewline();

  uartWrite(Rodata.addressOf(usb3StrHid), u64(7));
  usbHidApply(mods, usage, u64(0), u64(0), u64(1));
  uartNewline();
}
