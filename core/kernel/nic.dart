// core/kernel/nic.dart
//
// oscortex_core N0 + N1 + N2 + N3: the kernel finds the e1000, reads
// its MAC, transmits one Ethernet frame, resolves the gateway by ARP,
// and exchanges an ICMP echo with 10.0.2.2.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is -- `dcc` lowers exactly one library per object file.
// See docs/known-gaps.md GAP-0004 item 4.
//
// The architecture is docs/decisions/0058-the-kernel-reads-the-e1000-mac.md,
// docs/decisions/0063-one-frame-leaves.md,
// docs/decisions/0066-arp-resolves-the-gateway.md, and
// docs/decisions/0076-icmp-echo-reaches-the-gateway.md. The design is
// docs/design/net-stack.md §9 N0/N1/N2/N3 and docs/design/net-e1000.md §2–§4.
//
// ---------------------------------------------------------------------------
// ZERO DONATED `.bss`. THAT IS THE WHOLE OF THE MERGE RULE.
// ---------------------------------------------------------------------------
// `part 'nic.dart'` sits AFTER `part 'kbdq.dart'` and BEFORE
// `part 'wmevent.dart'`. D7 owns last place: `wmeventStore` is the newest
// `@bss` block, and stealing that slot would move every harness that
// measures D7 to the end of `.bss`. N0 prints from locals. N1/N2/N3 DMA
// buffers come from `allocFrame()` (identity-mapped, so the physical
// address IS the virtual address). Nothing here donates `.bss`.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE DOES, AND WHAT IT DOES NOT
// ---------------------------------------------------------------------------
// N0: walk bus 0 for class 02/00, read the command register, read BAR0,
// read `RAL0`/`RAH0` through MMIO. That is the MAC the device will
// match incoming frames against.
//
// N1: set bus-master through `pciWrite32` (with `romfile=` the option
// ROM never ran, so SeaBIOS left bit 2 clear), program one TX ring and
// one TX buffer from `allocFrame()`, write one legacy descriptor, ring
// `TDT`, poll `DD`. The frame is broadcast, ethertype 0x88B5 (IEEE
// 802.1 local experimental), body from `@rodata`. No IP, no ARP, no
// RX ring, no IRQ 11, no EEPROM, no `/net`.
//
// N2: `nic arp` programs an RX ring in the same frame as the TX ring,
// posts four 2048-byte receive buffers, sends a 60-byte ARP request
// for 10.0.2.2, polls RX `DD`, and accepts a reply only when the ARP
// opcode is 2. The printed MAC is the reply's sender hardware address.
// No IP, no ICMP, no IRQ 11, no `/net`. The gateway MAC is not a
// constant in this file — it comes off the wire.
//
// N3: `nic ping` does N2's ARP, then sends an IPv4 ICMP echo request
// to 10.0.2.2 (dest MAC from the reply, not a constant). The IP and
// ICMP checksums are the one's-complement of the folded 16-bit sum;
// omit that complement and SLIRP drops the request. The printed line
// is the echo-reply source IP, identifier, and sequence as read off
// the wire. No TCP, no Wi-Fi, no IRQ 11, no `/net`.
//
// QEMU copies the `mac=` property into the receive-address registers at
// realize/reset, so the bytes are there without an EEPROM cycle. N0
// checks memory-decode (needed for the BAR0 load) and refuses if it is
// clear. N1 writes MEM|BME before the first DMA.
//
// ---------------------------------------------------------------------------
// WHY THE PRINT IS A COMMAND, NOT A BOOT LINE
// ---------------------------------------------------------------------------
// QEMU's default machine already has an e1000 (net-stack.md §0.2 fact 2).
// A boot-time MAC or TX line would appear in every session golden after
// `M1 END`. The prints are [nicReport] (`nic`), [nicSend] (`nic send`),
// [nicArp] (`nic arp`), and [nicPing] (`nic ping`), none of which is
// in `help` (GAP-0105 / GAP-0115). [nicInit] is called from `kmain`
// and prints nothing, so `m1-interrupts`' 544-byte golden is untouched.

part of 'kmain.dart';

/// PCI class 0x02 subclass 0x00 is an Ethernet controller.
const int nicClassEthernet = 0x02;
const int nicSubclassEthernet = 0x00;

/// Command-register bit 1: memory decode. N0 reads `RAL0` through BAR0
/// MMIO, so this bit must be set. Bit 2 (bus-master) is a DMA fact and
/// is not required to read a register; with `romfile=` SeaBIOS leaves
/// it clear (GAP-0067 item 2 / GAP-0311). N1 writes MEM|BME.
const int nicCmdMem = 0x02;
const int nicCmdBme = 0x04;
const int nicCmdMemBme = 0x06;

/// e1000 receive-address registers. `RAL0` holds bytes 0–3 little-endian;
/// `RAH0` bits 15:0 hold bytes 4–5. Offsets confirmed against QEMU's
/// `e1000_regs.h` (net-e1000.md §2.1).
const int nicRegRal0 = 0x5400;
const int nicRegRah0 = 0x5404;

/// TX and bring-up registers. Offsets from QEMU `e1000_regs.h`
/// (net-e1000.md §2.1–§2.2). All accesses are 32-bit.
const int nicRegCtrl = 0x0000;
const int nicRegImc = 0x00D8;
const int nicRegTctl = 0x0400;
const int nicRegTipg = 0x0410;
const int nicRegFcal = 0x0028;
const int nicRegFcah = 0x002C;
const int nicRegFct = 0x0030;
const int nicRegFcttv = 0x0170;
const int nicRegTdbal = 0x3800;
const int nicRegTdbah = 0x3804;
const int nicRegTdlen = 0x3808;
const int nicRegTdh = 0x3810;
const int nicRegTdt = 0x3818;
const int nicRegRctl = 0x0100;
const int nicRegRdbal = 0x2800;
const int nicRegRdbah = 0x2804;
const int nicRegRdlen = 0x2808;
const int nicRegRdh = 0x2810;
const int nicRegRdt = 0x2818;
const int nicRegRdtr = 0x2820;
const int nicRegMta = 0x5200;

const int nicCtrlSlu = 0x40;
const int nicCtrlAsde = 0x20;
const int nicCtrlRst = 0x04000000;

/// TCTL = EN | PSP | CT(0x10 << 4) | COLD(0x40 << 12).
const int nicTctlVal = 0x4010A;
const int nicTipgVal = 0x0060200A;
const int nicTdlen = 128;

/// RCTL = EN | UPE | BAM | SECRC | SZ_2048. UPE is belt-and-suspenders
/// for the unicast reply (net-e1000.md §4.3); ring 3 still never sees
/// a frame. SECRC so the descriptor length is the frame, not the
/// frame plus FCS. RDT = N-1 = 7: device owns [0, 7).
const int nicRctlVal = 0x0400800A;
const int nicRdlen = 128;
const int nicRxTail = 7;
const int nicRxScan = 8;
const int nicRxBufSize = 2048;
const int nicRxDd = 0x01;
const int nicRahAv = 0x80000000;
const int nicRingRxOff = 256;

/// QEMU's `set_rx_control` arms a 1000 ms virtual-time flush timer
/// (`hw/net/e1000.c`). Until it fires, `e1000_can_receive` is false
/// and an ARP reply that arrives during `TDT` is dropped. 110 PIT
/// ticks is 1.1 s at 100 Hz — just over that timer.
const int nicRxHoldTicks = 110;

/// Legacy TX CMD byte: EOP | IFCS | RS. IFCS asks the NIC to append
/// the FCS so the driver does not compute a CRC32. RS requests DD
/// writeback (net-e1000.md §4.1).
const int nicTxCmd = 0x0B;
const int nicTxDd = 0x01;

/// 60-byte minimum Ethernet frame, FCS excluded. Broadcast dest,
/// IEEE 802.1 Local Experimental Ethertype 1 (0x88B5) — reserved,
/// not IPv4/ARP/IPv6. Body is [nicFrameBody], rest zeros.
const int nicFrameLen = 60;
const int nicEtherTypeHi = 0x88;
const int nicEtherTypeLo = 0xB5;
const int nicFrameBodyLen = 8;
const int nicMtaWords = 128;
const int nicPollLimit = 0x200000;
const int nicTimedOut = 0x100000000;

/// ARP: ethertype 0x0806, HTYPE 1, PTYPE 0x0800, HLEN 6, PLEN 4.
/// Opcode 1 is request, 2 is reply. [nicArpReplyOk] accepts 2 only —
/// that comparison is the load-bearing check (net-stack.md §9 N2).
const int nicEtherArpHi = 0x08;
const int nicEtherArpLo = 0x06;
const int nicArpHtypeLo = 0x01;
const int nicArpPtypeHi = 0x08;
const int nicArpHlen = 6;
const int nicArpPlen = 4;
const int nicArpOperRequest = 1;
const int nicArpOperReply = 2;
const int nicArpMinLen = 42;

/// Static host address for N2. DHCP is a program (net-stack.md §1.5).
/// 10.0.2.15 is SLIRP's default guest; 10.0.2.2 is the gateway.
const int nicIpUs0 = 10;
const int nicIpUs1 = 0;
const int nicIpUs2 = 2;
const int nicIpUs3 = 15;
const int nicIpGw0 = 10;
const int nicIpGw1 = 0;
const int nicIpGw2 = 2;
const int nicIpGw3 = 2;

/// IPv4 + ICMP echo. Ethertype 0x0800, proto 1, type 8 request / 0 reply.
/// Identifier 0x4E33 is "N3"; sequence 1. Payload is [nicIcmpBody].
/// The type-0 check is load-bearing (net-stack.md §9 N3).
const int nicEtherIpHi = 0x08;
const int nicEtherIpLo = 0x00;
const int nicIpProtoIcmp = 1;
const int nicIpTtl = 64;
const int nicIpHdrLen = 20;
const int nicIpVerIhl = 0x45;
const int nicIcmpEchoReply = 0;
const int nicIcmpEchoRequest = 8;
const int nicIcmpHdrLen = 8;
const int nicIcmpBodyLen = 8;
const int nicIcmpIdent = 0x4E33;
const int nicIcmpSeq = 1;
const int nicIpTotalLen = 36;
const int nicIcmpMinLen = 42;
const int nicTxDesc1 = 16;

/// `"nic"` -- 3 bytes. Not in `help`. See the file header.
@rodata
final List<u8> nicStrCmd = const [
  u8(0x6E), u8(0x69), u8(0x63),
];

/// `"nic send"` -- 8 bytes. N1. Not in `help`.
@rodata
final List<u8> nicStrCmdSend = const [
  u8(0x6E), u8(0x69), u8(0x63), u8(0x20),
  u8(0x73), u8(0x65), u8(0x6E), u8(0x64),
];

/// `"nic arp"` -- 7 bytes. N2. Not in `help`.
@rodata
final List<u8> nicStrCmdArp = const [
  u8(0x6E), u8(0x69), u8(0x63), u8(0x20),
  u8(0x61), u8(0x72), u8(0x70),
];

/// `"nic ping"` -- 8 bytes. N3. Not in `help`.
@rodata
final List<u8> nicStrCmdPing = const [
  u8(0x6E), u8(0x69), u8(0x63), u8(0x20),
  u8(0x70), u8(0x69), u8(0x6E), u8(0x67),
];

/// `"NIC MAC "` -- 8 bytes.
@rodata
final List<u8> nicStrMac = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x4D), u8(0x41), u8(0x43), u8(0x20),
];

/// `"NIC NONE\n"` -- 9 bytes. No Ethernet function on bus 0.
@rodata
final List<u8> nicStrNone = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// `"NIC NOCMD\n"` -- 10 bytes. Memory decode is clear.
@rodata
final List<u8> nicStrNocmd = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x43), u8(0x4D), u8(0x44), u8(0x0A),
];

/// `"NIC NOBAR\n"` -- 10 bytes. BAR0 is I/O or unimplemented.
@rodata
final List<u8> nicStrNobar = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x42), u8(0x41), u8(0x52), u8(0x0A),
];

/// `"NIC NOFRM\n"` -- 10 bytes. `allocFrame` returned 0.
@rodata
final List<u8> nicStrNofrm = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x46), u8(0x52), u8(0x4D), u8(0x0A),
];

/// `"NIC TX "` -- 7 bytes. Followed by the 4-digit frame length.
@rodata
final List<u8> nicStrTx = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x54), u8(0x58), u8(0x20),
];

/// `"NIC TXTMO\n"` -- 10 bytes. DD poll expired.
@rodata
final List<u8> nicStrTxtmo = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x54), u8(0x58), u8(0x54), u8(0x4D), u8(0x4F), u8(0x0A),
];

/// `"NIC ARP "` -- 8 bytes. Followed by the resolved MAC.
@rodata
final List<u8> nicStrArp = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x41), u8(0x52), u8(0x50), u8(0x20),
];

/// `"NIC RXTMO\n"` -- 10 bytes. RX DD never appeared.
@rodata
final List<u8> nicStrRxtmo = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x52), u8(0x58), u8(0x54), u8(0x4D), u8(0x4F), u8(0x0A),
];

/// `"NIC ARPMISS "` -- 12 bytes. A frame arrived but opcode was not 2.
@rodata
final List<u8> nicStrArpmiss = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x41), u8(0x52), u8(0x50), u8(0x4D),
  u8(0x49), u8(0x53), u8(0x53), u8(0x20),
];

/// `"NIC PING "` -- 9 bytes. Followed by reply SIP, ident, seq.
@rodata
final List<u8> nicStrPing = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x50), u8(0x49), u8(0x4E), u8(0x47), u8(0x20),
];

/// `"NIC ICMPMISS "` -- 13 bytes. A frame arrived but type was not 0.
@rodata
final List<u8> nicStrIcmpmiss = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x49), u8(0x43), u8(0x4D), u8(0x50),
  u8(0x4D), u8(0x49), u8(0x53), u8(0x53), u8(0x20),
];

/// Body of the N1 broadcast frame. Eight bytes; the remaining 38 of
/// the 46-byte payload are zeros from `vmZeroFrame`. The harness
/// reconstructs the same 60-byte frame from `mac=` plus these bytes.
/// `"N1FRAME!"`
@rodata
final List<u8> nicFrameBody = const [
  u8(0x4E), u8(0x31), u8(0x46), u8(0x52),
  u8(0x41), u8(0x4D), u8(0x45), u8(0x21),
];

/// Body of the N3 echo request. Eight bytes; SLIRP echoes them back.
/// `"N3ECHO!!"`
@rodata
final List<u8> nicIcmpBody = const [
  u8(0x4E), u8(0x33), u8(0x45), u8(0x43),
  u8(0x48), u8(0x4F), u8(0x21), u8(0x21),
];

/// Called from `kmain` with the other silent inits. N0 has no `.bss` to
/// zero and must print nothing: `m1-interrupts` asserts the entire
/// 544-byte capture, and a default e1000 would put a MAC line in every
/// later golden. The print is [nicReport].
@bare
void nicInit() {
}

/// One MAC line:
///
///     NIC MAC XX:XX:XX:XX:XX:XX
///
/// Six bytes, uppercase hex, colon-separated. [ral] is `RAL0` (bytes 0–3
/// little-endian); [rah] is `RAH0` (bytes 4–5 in bits 15:0). The format
/// is the same shape QEMU's `mac=` argument uses, so the harness can
/// compare the printed line against the string it typed on the command
/// line without a second encoding.
@bare
void nicPutMac(u64 ral, u64 rah) {
  uartWrite(Rodata.addressOf(nicStrMac), u64(8));
  uartPutHex(ral & u64(0xFF), u64(2));
  conPutc(u8(0x3A));
  uartPutHex((ral >> u64(8)) & u64(0xFF), u64(2));
  conPutc(u8(0x3A));
  uartPutHex((ral >> u64(16)) & u64(0xFF), u64(2));
  conPutc(u8(0x3A));
  uartPutHex((ral >> u64(24)) & u64(0xFF), u64(2));
  conPutc(u8(0x3A));
  uartPutHex(rah & u64(0xFF), u64(2));
  conPutc(u8(0x3A));
  uartPutHex((rah >> u64(8)) & u64(0xFF), u64(2));
  uartNewline();
}

/// `nic` -- find the Ethernet controller, read its MAC, print it.
///
/// Runs in TASK context with interrupts enabled, like every other
/// command (ADR-0006). It is a handful of configuration reads and two
/// MMIO loads. Nothing here waits on a device and nothing is retained.
@bare
void nicReport() {
  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nicStrNone), u64(9));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nicCmdMem)) < u64(nicCmdMem)) {
    uartWrite(Rodata.addressOf(nicStrNocmd), u64(10));
    return;
  }
  final u64 bar = pciReadBar(bdf, u64(0));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nicStrNobar), u64(10));
    return;
  }
  final u64 ral = Volatile<u32>.fromAddress(bar + u64(nicRegRal0)).value.toU64();
  final u64 rah = Volatile<u32>.fromAddress(bar + u64(nicRegRah0)).value.toU64();
  nicPutMac(ral, rah);
}

/// 32-bit MMIO store at [bar] + [off]. Every `Volatile` access is
/// emitted volatile (ADR-0041), which is what MMIO needs.
@bare
void nicRegPut(u64 bar, u64 off, u64 val) {
  Volatile<u32>.fromAddress(bar + off).value = val.toU32();
}

/// 32-bit MMIO load at [bar] + [off].
@bare
u64 nicRegGet(u64 bar, u64 off) {
  return Volatile<u32>.fromAddress(bar + off).value.toU64();
}

/// Zero the 128-dword multicast table. QEMU already resets it; hardware
/// does not promise that (net-e1000.md §4.3 step 7).
@bare
void nicClearMta(u64 bar) {
  u64 i = u64(0);
  while (i < u64(nicMtaWords)) {
    nicRegPut(bar, u64(nicRegMta) + (i << u64(2)), u64(0));
    i = i + u64(1);
  }
}

/// Poll the byte at [addr] until `(value & mask) == want`, or the
/// iteration bound expires. Returns the last value, or [nicTimedOut]
/// with the last value in the low bits. Same shape as `ataWait`.
@bare
u64 nicWaitByte(u64 addr, u64 mask, u64 want) {
  u64 n = u64(nicPollLimit);
  u64 v = u64(0);
  while (u64(0) < n) {
    v = Volatile<u8>.fromAddress(addr).value.toU64();
    if ((v & mask) == want) {
      return v;
    }
    n = n - u64(1);
  }
  return u64(nicTimedOut) | v;
}

/// Build the 60-byte N1 frame at [buf]. Dest is broadcast, source is
/// [ral]/[rah], ethertype is 0x88B5, body is [nicFrameBody]. The rest
/// of the payload is whatever `vmZeroFrame` left (zeros).
@bare
void nicPutFrame(u64 buf, u64 ral, u64 rah) {
  Volatile<u8>.fromAddress(buf + u64(0)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(1)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(2)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(3)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(4)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(5)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(6)).value = (ral & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(buf + u64(7)).value = ((ral >> u64(8)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(buf + u64(8)).value = ((ral >> u64(16)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(buf + u64(9)).value = ((ral >> u64(24)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(buf + u64(10)).value = (rah & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(buf + u64(11)).value = ((rah >> u64(8)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(buf + u64(12)).value = u8(nicEtherTypeHi);
  Volatile<u8>.fromAddress(buf + u64(13)).value = u8(nicEtherTypeLo);
  final u64 body = Rodata.addressOf(nicFrameBody);
  u64 i = u64(0);
  while (i < u64(nicFrameBodyLen)) {
    Volatile<u8>.fromAddress(buf + u64(14) + i).value =
        Pointer<u8>.fromAddress(body + i).value;
    i = i + u64(1);
  }
}

/// `nic send` -- one broadcast frame onto the wire.
///
/// Runs in TASK context. Two frames from `allocFrame()` (TX ring, TX
/// buffer), never freed: 8 KiB of 128 MiB, held for the boot. The
/// `TDT` store is the doorbell; without it the pcap stays empty.
@bare
void nicSend() {
  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nicStrNone), u64(9));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nicCmdMem)) < u64(nicCmdMem)) {
    uartWrite(Rodata.addressOf(nicStrNocmd), u64(10));
    return;
  }
  // Keep the command half, zero the status half (W1C), set MEM|BME.
  pciWrite32(bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nicCmdMemBme));
  final u64 bar = pciReadBar(bdf, u64(0));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nicStrNobar), u64(10));
    return;
  }
  final u64 ral = nicRegGet(bar, u64(nicRegRal0));
  final u64 rah = nicRegGet(bar, u64(nicRegRah0));
  nicPutMac(ral, rah);

  nicRegPut(bar, u64(nicRegImc), u64(0xFFFFFFFF));
  final u64 ctrl = nicRegGet(bar, u64(nicRegCtrl));
  nicRegPut(bar, u64(nicRegCtrl), ctrl | u64(nicCtrlSlu) | u64(nicCtrlAsde));
  nicRegPut(bar, u64(nicRegFcal), u64(0));
  nicRegPut(bar, u64(nicRegFcah), u64(0));
  nicRegPut(bar, u64(nicRegFct), u64(0));
  nicRegPut(bar, u64(nicRegFcttv), u64(0));
  nicClearMta(bar);

  final u64 ring = allocFrame();
  if (ring < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(ring);
  final u64 buf = allocFrame();
  if (buf < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(buf);
  nicPutFrame(buf, ral, rah);

  // Legacy TX descriptor at ring[0]: buffer, length, CMD = EOP|IFCS|RS.
  Volatile<u32>.fromAddress(ring + u64(0)).value = buf.toU32();
  Volatile<u32>.fromAddress(ring + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ring + u64(8)).value =
      (u64(nicFrameLen) | (u64(nicTxCmd) << u64(24))).toU32();
  Volatile<u32>.fromAddress(ring + u64(12)).value = u64(0).toU32();

  nicRegPut(bar, u64(nicRegTdbal), ring);
  nicRegPut(bar, u64(nicRegTdbah), u64(0));
  nicRegPut(bar, u64(nicRegTdlen), u64(nicTdlen));
  nicRegPut(bar, u64(nicRegTdh), u64(0));
  nicRegPut(bar, u64(nicRegTdt), u64(0));
  nicRegPut(bar, u64(nicRegTipg), u64(nicTipgVal));
  nicRegPut(bar, u64(nicRegTctl), u64(nicTctlVal));
  // The doorbell. A build that omits this store produces a zero-packet
  // pcap (net-stack.md §9 N1 negative control).
  nicRegPut(bar, u64(nicRegTdt), u64(1));

  final u64 sta = nicWaitByte(ring + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (sta > u64(0xFF)) {
    uartWrite(Rodata.addressOf(nicStrTxtmo), u64(10));
    return;
  }
  uartWrite(Rodata.addressOf(nicStrTx), u64(7));
  uartPutHex(u64(nicFrameLen), u64(4));
  uartNewline();
}

/// Write six MAC bytes from [ral]/[rah] at [dst].
@bare
void nicPutMacAt(u64 dst, u64 ral, u64 rah) {
  Volatile<u8>.fromAddress(dst + u64(0)).value = (ral & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(dst + u64(1)).value = ((ral >> u64(8)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(dst + u64(2)).value = ((ral >> u64(16)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(dst + u64(3)).value = ((ral >> u64(24)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(dst + u64(4)).value = (rah & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(dst + u64(5)).value = ((rah >> u64(8)) & u64(0xFF)).toU8();
}

/// Build the 60-byte ARP request at [buf]: broadcast dest, our MAC,
/// ethertype 0x0806, opcode 1, SPA 10.0.2.15, TPA 10.0.2.2.
@bare
void nicPutArpReq(u64 buf, u64 ral, u64 rah) {
  Volatile<u8>.fromAddress(buf + u64(0)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(1)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(2)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(3)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(4)).value = u8(0xFF);
  Volatile<u8>.fromAddress(buf + u64(5)).value = u8(0xFF);
  nicPutMacAt(buf + u64(6), ral, rah);
  Volatile<u8>.fromAddress(buf + u64(12)).value = u8(nicEtherArpHi);
  Volatile<u8>.fromAddress(buf + u64(13)).value = u8(nicEtherArpLo);
  Volatile<u8>.fromAddress(buf + u64(14)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(15)).value = u8(nicArpHtypeLo);
  Volatile<u8>.fromAddress(buf + u64(16)).value = u8(nicArpPtypeHi);
  Volatile<u8>.fromAddress(buf + u64(17)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(18)).value = u8(nicArpHlen);
  Volatile<u8>.fromAddress(buf + u64(19)).value = u8(nicArpPlen);
  Volatile<u8>.fromAddress(buf + u64(20)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(21)).value = u8(nicArpOperRequest);
  nicPutMacAt(buf + u64(22), ral, rah);
  Volatile<u8>.fromAddress(buf + u64(28)).value = u8(nicIpUs0);
  Volatile<u8>.fromAddress(buf + u64(29)).value = u8(nicIpUs1);
  Volatile<u8>.fromAddress(buf + u64(30)).value = u8(nicIpUs2);
  Volatile<u8>.fromAddress(buf + u64(31)).value = u8(nicIpUs3);
  Volatile<u8>.fromAddress(buf + u64(32)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(33)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(34)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(35)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(36)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(37)).value = u8(0);
  Volatile<u8>.fromAddress(buf + u64(38)).value = u8(nicIpGw0);
  Volatile<u8>.fromAddress(buf + u64(39)).value = u8(nicIpGw1);
  Volatile<u8>.fromAddress(buf + u64(40)).value = u8(nicIpGw2);
  Volatile<u8>.fromAddress(buf + u64(41)).value = u8(nicIpGw3);
}

/// One RX descriptor at [ring][i]: buffer address, status cleared.
@bare
void nicRxDesc(u64 ring, u64 i, u64 buf) {
  final u64 d = ring + (i << u64(4));
  Volatile<u32>.fromAddress(d).value = buf.toU32();
  Volatile<u32>.fromAddress(d + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(d + u64(8)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(d + u64(12)).value = u64(0).toU32();
}

/// Post eight RX descriptors from two frames (offset 0 and 2048,
/// wrapped). RDT will be 7 so the device owns seven of them.
@bare
void nicRxReady(u64 ring, u64 f0, u64 f1) {
  nicRxDesc(ring, u64(0), f0);
  nicRxDesc(ring, u64(1), f0 + u64(nicRxBufSize));
  nicRxDesc(ring, u64(2), f1);
  nicRxDesc(ring, u64(3), f1 + u64(nicRxBufSize));
  nicRxDesc(ring, u64(4), f0);
  nicRxDesc(ring, u64(5), f0 + u64(nicRxBufSize));
  nicRxDesc(ring, u64(6), f1);
  nicRxDesc(ring, u64(7), f1 + u64(nicRxBufSize));
}

/// ARP opcode at [buf]+20, big-endian.
@bare
u64 nicArpOp(u64 buf) {
  final u64 hi = Volatile<u8>.fromAddress(buf + u64(20)).value.toU64();
  final u64 lo = Volatile<u8>.fromAddress(buf + u64(21)).value.toU64();
  return (hi << u64(8)) | lo;
}

/// Load-bearing opcode check. Accepts [nicArpOperReply] only. A build
/// that inverts this comparison prints ARPMISS and resolves nothing.
@bare
u64 nicArpOpcodeOk(u64 op) {
  if (op == u64(nicArpOperReply)) {
    return u64(1);
  }
  return u64(0);
}

/// 1 if [buf] is an Ethernet ARP reply of at least 42 bytes.
@bare
u64 nicArpReplyOk(u64 buf, u64 len) {
  if (len < u64(nicArpMinLen)) {
    return u64(0);
  }
  if (Volatile<u8>.fromAddress(buf + u64(12)).value.toU64() != u64(nicEtherArpHi)) {
    return u64(0);
  }
  if (Volatile<u8>.fromAddress(buf + u64(13)).value.toU64() != u64(nicEtherArpLo)) {
    return u64(0);
  }
  return nicArpOpcodeOk(nicArpOp(buf));
}

/// Poll the posted RX descriptors. Returns the buffer address of the
/// first ARP reply, 1 if a frame arrived that was not a reply, or 0
/// if DD never appeared.
@bare
u64 nicArpFromRing(u64 rxring, u64 n) {
  u64 seen = u64(0);
  u64 spins = u64(nicPollLimit);
  while (u64(0) < spins) {
    u64 i = u64(0);
    while (i < n) {
      final u64 d = rxring + (i << u64(4));
      final u64 sta = Volatile<u8>.fromAddress(d + u64(12)).value.toU64();
      if ((sta & u64(nicRxDd)) == u64(nicRxDd)) {
        seen = u64(1);
        final u64 buf = Volatile<u32>.fromAddress(d).value.toU64();
        final u64 len = Volatile<u16>.fromAddress(d + u64(8)).value.toU64();
        if (u64(0) < nicArpReplyOk(buf, len)) {
          return buf;
        }
      }
      i = i + u64(1);
    }
    spins = spins - u64(1);
  }
  return seen;
}

/// Print six colon-separated uppercase hex octets from [p].
@bare
void nicPutColonMac(u64 p) {
  u64 i = u64(0);
  while (i < u64(6)) {
    if (u64(0) < i) {
      conPutc(u8(0x3A));
    }
    uartPutHex(Volatile<u8>.fromAddress(p + i).value.toU64(), u64(2));
    i = i + u64(1);
  }
}

/// Device reset, then IMC, SLU|ASDE, LRST clear, flow-control off,
/// multicast table cleared. Reset is what arms the RX unit on this
/// QEMU; N1 skipped it because TX does not need it.
@bare
void nicLinkUp(u64 bar) {
  nicRegPut(bar, u64(nicRegImc), u64(0xFFFFFFFF));
  nicRegPut(bar, u64(nicRegCtrl), nicRegGet(bar, u64(nicRegCtrl)) | u64(nicCtrlRst));
  u64 n = u64(nicPollLimit);
  while (u64(0) < n) {
    if ((nicRegGet(bar, u64(nicRegCtrl)) & u64(nicCtrlRst)) == u64(0)) {
      break;
    }
    n = n - u64(1);
  }
  nicRegPut(bar, u64(nicRegImc), u64(0xFFFFFFFF));
  final u64 ctrl = nicRegGet(bar, u64(nicRegCtrl));
  nicRegPut(bar, u64(nicRegCtrl), (ctrl | u64(nicCtrlSlu) | u64(nicCtrlAsde)) & u64(0xFFFFFFF7));
  nicRegPut(bar, u64(nicRegFcal), u64(0));
  nicRegPut(bar, u64(nicRegFcah), u64(0));
  nicRegPut(bar, u64(nicRegFct), u64(0));
  nicRegPut(bar, u64(nicRegFcttv), u64(0));
  nicClearMta(bar);
}

/// Wait [nicRxHoldTicks] after `RCTL.EN` so QEMU's flush timer can
/// fire. Unmasks IRQ0 for the wait, remasks after — same shape as
/// `shellTicks`. N2 does not leave the PIT on.
@bare
void nicRxHold() {
  final u64 start = tick_count();
  final u64 target = start + u64(nicRxHoldTicks);
  picUnmaskTimerAndKeyboard();
  u64 now = tick_count();
  while (now < target) {
    now = tick_count();
  }
  if (procHead(u64(procHeadResident)) < u64(1)) {
    picUnmaskKeyboardOnly();
  }
}

/// `nic arp` -- ARP request for 10.0.2.2, print the reply's SHA.
///
/// Runs in TASK context. Four frames from `allocFrame()` (shared
/// TX+RX ring, TX buffer, two RX buffer frames), never freed. The
/// RX ring is programmed before `TDT` so the reply has somewhere
/// to land. Opcode 2 is the only accepted reply.
@bare
void nicArp() {
  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nicStrNone), u64(9));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nicCmdMem)) < u64(nicCmdMem)) {
    uartWrite(Rodata.addressOf(nicStrNocmd), u64(10));
    return;
  }
  pciWrite32(bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nicCmdMemBme));
  final u64 bar = pciReadBar(bdf, u64(0));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nicStrNobar), u64(10));
    return;
  }
  nicLinkUp(bar);
  final u64 ral = nicRegGet(bar, u64(nicRegRal0));
  final u64 rah = nicRegGet(bar, u64(nicRegRah0));
  nicPutMac(ral, rah);
  nicRegPut(bar, u64(nicRegRah0), (rah & u64(0xFFFF)) | u64(nicRahAv));

  final u64 ring = allocFrame();
  if (ring < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(ring);
  final u64 txbuf = allocFrame();
  if (txbuf < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(txbuf);
  final u64 rxf0 = allocFrame();
  if (rxf0 < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  final u64 rxf1 = allocFrame();
  if (rxf1 < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  final u64 rxring = ring + u64(nicRingRxOff);
  nicRxReady(rxring, rxf0, rxf1);
  nicPutArpReq(txbuf, ral, rah);

  Volatile<u32>.fromAddress(ring + u64(0)).value = txbuf.toU32();
  Volatile<u32>.fromAddress(ring + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ring + u64(8)).value =
      (u64(nicFrameLen) | (u64(nicTxCmd) << u64(24))).toU32();
  Volatile<u32>.fromAddress(ring + u64(12)).value = u64(0).toU32();

  nicRegPut(bar, u64(nicRegRdbal), rxring);
  nicRegPut(bar, u64(nicRegRdbah), u64(0));
  nicRegPut(bar, u64(nicRegRdlen), u64(nicRdlen));
  nicRegPut(bar, u64(nicRegRdh), u64(0));
  nicRegPut(bar, u64(nicRegRdt), u64(0));
  nicRegPut(bar, u64(nicRegRdtr), u64(0));
  nicRegPut(bar, u64(nicRegRctl), u64(nicRctlVal));
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  nicRegPut(bar, u64(nicRegTdbal), ring);
  nicRegPut(bar, u64(nicRegTdbah), u64(0));
  nicRegPut(bar, u64(nicRegTdlen), u64(nicTdlen));
  nicRegPut(bar, u64(nicRegTdh), u64(0));
  nicRegPut(bar, u64(nicRegTdt), u64(0));
  nicRegPut(bar, u64(nicRegTipg), u64(nicTipgVal));
  nicRegPut(bar, u64(nicRegTctl), u64(nicTctlVal));
  nicRxHold();
  nicRegPut(bar, u64(nicRegTdt), u64(1));

  final u64 sta = nicWaitByte(ring + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (sta > u64(0xFF)) {
    uartWrite(Rodata.addressOf(nicStrTxtmo), u64(10));
    return;
  }
  uartWrite(Rodata.addressOf(nicStrTx), u64(7));
  uartPutHex(u64(nicFrameLen), u64(4));
  uartNewline();
  // Kick RDT again so QEMU flushes a reply that was queued during
  // the TDT write (slirp answers inside start_xmit).
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  final u64 got = nicArpFromRing(rxring, u64(nicRxScan));
  if (got < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrRxtmo), u64(10));
    return;
  }
  if (got < u64(2)) {
    uartWrite(Rodata.addressOf(nicStrArpmiss), u64(12));
    uartPutHex(u64(1), u64(4));
    uartNewline();
    return;
  }
  uartWrite(Rodata.addressOf(nicStrArp), u64(8));
  nicPutColonMac(got + u64(22));
  uartNewline();
}

/// Store [val] as a 16-bit big-endian word at [addr].
@bare
void nicPutBe16(u64 addr, u64 val) {
  Volatile<u8>.fromAddress(addr).value = ((val >> u64(8)) & u64(0xFF)).toU8();
  Volatile<u8>.fromAddress(addr + u64(1)).value = (val & u64(0xFF)).toU8();
}

/// Load a 16-bit big-endian word at [addr].
@bare
u64 nicGetBe16(u64 addr) {
  final u64 hi = Volatile<u8>.fromAddress(addr).value.toU64();
  final u64 lo = Volatile<u8>.fromAddress(addr + u64(1)).value.toU64();
  return (hi << u64(8)) | lo;
}

/// Folded 16-bit one's-complement sum over [len] bytes at [addr],
/// without the final complement. The complement is [nicCsum]: omit
/// it and SLIRP drops the datagram (net-stack.md §9 N3).
@bare
u64 nicCsumFold(u64 addr, u64 len) {
  u64 sum = u64(0);
  u64 i = u64(0);
  while (i + u64(1) < len) {
    final u64 hi = Volatile<u8>.fromAddress(addr + i).value.toU64();
    final u64 lo = Volatile<u8>.fromAddress(addr + i + u64(1)).value.toU64();
    sum = sum + ((hi << u64(8)) | lo);
    i = i + u64(2);
  }
  if (i < len) {
    sum = sum + (Volatile<u8>.fromAddress(addr + i).value.toU64() << u64(8));
  }
  while (u64(0) < (sum >> u64(16))) {
    sum = (sum & u64(0xFFFF)) + (sum >> u64(16));
  }
  return sum & u64(0xFFFF);
}

/// Internet checksum: one's complement of [nicCsumFold]. The
/// subtraction from 0xFFFF is the load-bearing complement.
@bare
u64 nicCsum(u64 addr, u64 len) {
  return u64(0xFFFF) - nicCsumFold(addr, len);
}

/// Copy six bytes from [src] to [dst].
@bare
void nicCopy6(u64 dst, u64 src) {
  u64 i = u64(0);
  while (i < u64(6)) {
    Volatile<u8>.fromAddress(dst + i).value =
        Volatile<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

/// Build the 60-byte ICMP echo request at [buf]. Dest MAC is the
/// six bytes at [dstMac] (the ARP reply SHA). IP dest is 10.0.2.2.
/// Checksum fields are written after the headers, via [nicCsum].
@bare
void nicPutIcmpReq(u64 buf, u64 ral, u64 rah, u64 dstMac) {
  nicCopy6(buf, dstMac);
  nicPutMacAt(buf + u64(6), ral, rah);
  Volatile<u8>.fromAddress(buf + u64(12)).value = u8(nicEtherIpHi);
  Volatile<u8>.fromAddress(buf + u64(13)).value = u8(nicEtherIpLo);
  final u64 ip = buf + u64(14);
  Volatile<u8>.fromAddress(ip).value = u8(nicIpVerIhl);
  Volatile<u8>.fromAddress(ip + u64(1)).value = u8(0);
  nicPutBe16(ip + u64(2), u64(nicIpTotalLen));
  nicPutBe16(ip + u64(4), u64(nicIcmpIdent));
  nicPutBe16(ip + u64(6), u64(0));
  Volatile<u8>.fromAddress(ip + u64(8)).value = u8(nicIpTtl);
  Volatile<u8>.fromAddress(ip + u64(9)).value = u8(nicIpProtoIcmp);
  nicPutBe16(ip + u64(10), u64(0));
  Volatile<u8>.fromAddress(ip + u64(12)).value = u8(nicIpUs0);
  Volatile<u8>.fromAddress(ip + u64(13)).value = u8(nicIpUs1);
  Volatile<u8>.fromAddress(ip + u64(14)).value = u8(nicIpUs2);
  Volatile<u8>.fromAddress(ip + u64(15)).value = u8(nicIpUs3);
  Volatile<u8>.fromAddress(ip + u64(16)).value = u8(nicIpGw0);
  Volatile<u8>.fromAddress(ip + u64(17)).value = u8(nicIpGw1);
  Volatile<u8>.fromAddress(ip + u64(18)).value = u8(nicIpGw2);
  Volatile<u8>.fromAddress(ip + u64(19)).value = u8(nicIpGw3);
  final u64 icmp = ip + u64(nicIpHdrLen);
  Volatile<u8>.fromAddress(icmp).value = u8(nicIcmpEchoRequest);
  Volatile<u8>.fromAddress(icmp + u64(1)).value = u8(0);
  nicPutBe16(icmp + u64(2), u64(0));
  nicPutBe16(icmp + u64(4), u64(nicIcmpIdent));
  nicPutBe16(icmp + u64(6), u64(nicIcmpSeq));
  final u64 body = Rodata.addressOf(nicIcmpBody);
  u64 i = u64(0);
  while (i < u64(nicIcmpBodyLen)) {
    Volatile<u8>.fromAddress(icmp + u64(nicIcmpHdrLen) + i).value =
        Pointer<u8>.fromAddress(body + i).value;
    i = i + u64(1);
  }
  nicPutBe16(ip + u64(10), nicCsum(ip, u64(nicIpHdrLen)));
  nicPutBe16(icmp + u64(2), nicCsum(icmp, u64(nicIpTotalLen) - u64(nicIpHdrLen)));
}

/// Load-bearing ICMP type check. Accepts [nicIcmpEchoReply] only.
/// A build that compares against [nicIcmpEchoRequest] prints ICMPMISS.
@bare
u64 nicIcmpTypeOk(u64 typ) {
  if (typ == u64(nicIcmpEchoReply)) {
    return u64(1);
  }
  return u64(0);
}

/// 1 if [buf] is an IPv4 ICMP echo reply of at least 42 bytes.
@bare
u64 nicIcmpReplyOk(u64 buf, u64 len) {
  if (len < u64(nicIcmpMinLen)) {
    return u64(0);
  }
  if (Volatile<u8>.fromAddress(buf + u64(12)).value.toU64() != u64(nicEtherIpHi)) {
    return u64(0);
  }
  if (Volatile<u8>.fromAddress(buf + u64(13)).value.toU64() != u64(nicEtherIpLo)) {
    return u64(0);
  }
  final u64 verIhl = Volatile<u8>.fromAddress(buf + u64(14)).value.toU64();
  final u64 ihl = (verIhl & u64(0x0F)) << u64(2);
  if (ihl < u64(nicIpHdrLen)) {
    return u64(0);
  }
  if (len < (u64(14) + ihl + u64(nicIcmpHdrLen))) {
    return u64(0);
  }
  if (Volatile<u8>.fromAddress(buf + u64(14) + u64(9)).value.toU64() != u64(nicIpProtoIcmp)) {
    return u64(0);
  }
  final u64 typ = Volatile<u8>.fromAddress(buf + u64(14) + ihl).value.toU64();
  return nicIcmpTypeOk(typ);
}

/// Poll the posted RX descriptors. Returns the buffer of the first
/// ICMP echo reply, 1 if a frame arrived that was not a reply, or 0
/// if DD never appeared.
@bare
u64 nicIcmpFromRing(u64 rxring, u64 n) {
  u64 seen = u64(0);
  u64 spins = u64(nicPollLimit);
  while (u64(0) < spins) {
    u64 i = u64(0);
    while (i < n) {
      final u64 d = rxring + (i << u64(4));
      final u64 sta = Volatile<u8>.fromAddress(d + u64(12)).value.toU64();
      if ((sta & u64(nicRxDd)) == u64(nicRxDd)) {
        final u64 buf = Volatile<u32>.fromAddress(d).value.toU64();
        final u64 len = Volatile<u16>.fromAddress(d + u64(8)).value.toU64();
        if (u64(0) < nicIcmpReplyOk(buf, len)) {
          return buf;
        }
        // ARP already sits on the ring. Only an IPv4 frame that is
        // not an echo reply counts as a miss.
        if (Volatile<u8>.fromAddress(buf + u64(12)).value.toU64() == u64(nicEtherIpHi)) {
          if (Volatile<u8>.fromAddress(buf + u64(13)).value.toU64() == u64(nicEtherIpLo)) {
            seen = u64(1);
          }
        }
      }
      i = i + u64(1);
    }
    spins = spins - u64(1);
  }
  return seen;
}

/// Print four uppercase hex octets from [p] with no separator.
@bare
void nicPutIpHex(u64 p) {
  uartPutHex(Volatile<u8>.fromAddress(p).value.toU64(), u64(2));
  uartPutHex(Volatile<u8>.fromAddress(p + u64(1)).value.toU64(), u64(2));
  uartPutHex(Volatile<u8>.fromAddress(p + u64(2)).value.toU64(), u64(2));
  uartPutHex(Volatile<u8>.fromAddress(p + u64(3)).value.toU64(), u64(2));
}

/// `nic ping` -- ARP for 10.0.2.2, then ICMP echo, print the reply.
///
/// Runs in TASK context. Same four `allocFrame()` buffers as N2,
/// never freed, zero new `.bss`. Dest MAC comes off the ARP reply.
/// Type 0 is the only accepted ICMP reply.
@bare
void nicPing() {
  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(nicStrNone), u64(9));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nicCmdMem)) < u64(nicCmdMem)) {
    uartWrite(Rodata.addressOf(nicStrNocmd), u64(10));
    return;
  }
  pciWrite32(bus, dev, fn, u64(pciRegCommand), (cmd & u64(0xFFFF)) | u64(nicCmdMemBme));
  final u64 bar = pciReadBar(bdf, u64(0));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(nicStrNobar), u64(10));
    return;
  }
  nicLinkUp(bar);
  final u64 ral = nicRegGet(bar, u64(nicRegRal0));
  final u64 rah = nicRegGet(bar, u64(nicRegRah0));
  nicPutMac(ral, rah);
  nicRegPut(bar, u64(nicRegRah0), (rah & u64(0xFFFF)) | u64(nicRahAv));

  final u64 ring = allocFrame();
  if (ring < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(ring);
  final u64 txbuf = allocFrame();
  if (txbuf < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(txbuf);
  final u64 rxf0 = allocFrame();
  if (rxf0 < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  final u64 rxf1 = allocFrame();
  if (rxf1 < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrNofrm), u64(10));
    return;
  }
  final u64 rxring = ring + u64(nicRingRxOff);
  nicRxReady(rxring, rxf0, rxf1);
  nicPutArpReq(txbuf, ral, rah);

  Volatile<u32>.fromAddress(ring + u64(0)).value = txbuf.toU32();
  Volatile<u32>.fromAddress(ring + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ring + u64(8)).value =
      (u64(nicFrameLen) | (u64(nicTxCmd) << u64(24))).toU32();
  Volatile<u32>.fromAddress(ring + u64(12)).value = u64(0).toU32();

  nicRegPut(bar, u64(nicRegRdbal), rxring);
  nicRegPut(bar, u64(nicRegRdbah), u64(0));
  nicRegPut(bar, u64(nicRegRdlen), u64(nicRdlen));
  nicRegPut(bar, u64(nicRegRdh), u64(0));
  nicRegPut(bar, u64(nicRegRdt), u64(0));
  nicRegPut(bar, u64(nicRegRdtr), u64(0));
  nicRegPut(bar, u64(nicRegRctl), u64(nicRctlVal));
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  nicRegPut(bar, u64(nicRegTdbal), ring);
  nicRegPut(bar, u64(nicRegTdbah), u64(0));
  nicRegPut(bar, u64(nicRegTdlen), u64(nicTdlen));
  nicRegPut(bar, u64(nicRegTdh), u64(0));
  nicRegPut(bar, u64(nicRegTdt), u64(0));
  nicRegPut(bar, u64(nicRegTipg), u64(nicTipgVal));
  nicRegPut(bar, u64(nicRegTctl), u64(nicTctlVal));
  nicRxHold();
  nicRegPut(bar, u64(nicRegTdt), u64(1));

  final u64 sta = nicWaitByte(ring + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (sta > u64(0xFF)) {
    uartWrite(Rodata.addressOf(nicStrTxtmo), u64(10));
    return;
  }
  uartWrite(Rodata.addressOf(nicStrTx), u64(7));
  uartPutHex(u64(nicFrameLen), u64(4));
  uartNewline();
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  final u64 got = nicArpFromRing(rxring, u64(nicRxScan));
  if (got < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrRxtmo), u64(10));
    return;
  }
  if (got < u64(2)) {
    uartWrite(Rodata.addressOf(nicStrArpmiss), u64(12));
    uartPutHex(u64(1), u64(4));
    uartNewline();
    return;
  }
  uartWrite(Rodata.addressOf(nicStrArp), u64(8));
  nicPutColonMac(got + u64(22));
  uartNewline();

  vmZeroFrame(txbuf);
  nicPutIcmpReq(txbuf, ral, rah, got + u64(22));
  Volatile<u32>.fromAddress(ring + u64(nicTxDesc1)).value = txbuf.toU32();
  Volatile<u32>.fromAddress(ring + u64(nicTxDesc1) + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ring + u64(nicTxDesc1) + u64(8)).value =
      (u64(nicFrameLen) | (u64(nicTxCmd) << u64(24))).toU32();
  Volatile<u32>.fromAddress(ring + u64(nicTxDesc1) + u64(12)).value = u64(0).toU32();
  nicRegPut(bar, u64(nicRegTdt), u64(2));

  final u64 sta2 = nicWaitByte(ring + u64(nicTxDesc1) + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (sta2 > u64(0xFF)) {
    uartWrite(Rodata.addressOf(nicStrTxtmo), u64(10));
    return;
  }
  uartWrite(Rodata.addressOf(nicStrTx), u64(7));
  uartPutHex(u64(nicFrameLen), u64(4));
  uartNewline();
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  final u64 echo = nicIcmpFromRing(rxring, u64(nicRxScan));
  if (echo < u64(1)) {
    uartWrite(Rodata.addressOf(nicStrRxtmo), u64(10));
    return;
  }
  if (echo < u64(2)) {
    uartWrite(Rodata.addressOf(nicStrIcmpmiss), u64(13));
    uartPutHex(u64(8), u64(4));
    uartNewline();
    return;
  }
  final u64 verIhl = Volatile<u8>.fromAddress(echo + u64(14)).value.toU64();
  final u64 ihl = (verIhl & u64(0x0F)) << u64(2);
  final u64 icmp = echo + u64(14) + ihl;
  uartWrite(Rodata.addressOf(nicStrPing), u64(9));
  nicPutIpHex(echo + u64(26));
  conPutc(u8(0x20));
  uartPutHex(nicGetBe16(icmp + u64(4)), u64(4));
  conPutc(u8(0x20));
  uartPutHex(nicGetBe16(icmp + u64(6)), u64(4));
  uartNewline();
}
