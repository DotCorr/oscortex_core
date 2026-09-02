// core/kernel/ota.dart
//
// ADR-0140. OTA signed plant on a NIC class: an RX plant (shell
// `ota feed <hex>`) is verified against a harness-planted FAT key
// and, on a good signature, written into SLOT.TXT. A bad signature
// leaves the slot unchanged. No Ethernet function → refuse.
//
// ADR-0151. `ota get <port>` fetches the same signed blob over plain
// TCP from 10.0.2.2 (SLIRP host). Same digest + SLOT.TXT apply.
// No listener / RST / timeout → OTA NOHOST, slot unchanged. Bad
// signature from the host → OTA BADSIG. Cleartext only.
//
// ADR-0154. `ota tls <port>` fetches over TLS 1.2 (AES128-SHA) via
// the otatls C mailbox. Planted OTACERT is the SHA-256 of the leaf
// DER (one-cert flight) or of the CA DER (ADR-0168 chain). Mismatch
// or bad chain → OTA BADCERT, slot unchanged. Not plat-tls / FSGS.
//
// ZERO donated `.bss`. Scratch is `allocFrame()`. Not last: D7 owns
// that. Not in `help`. Syscall 11 stays `fdwait`. Not Wi-Fi.

part of 'kmain.dart';

/// Plant blob: magic `OTA1`, BE paylen, 8-byte sig, then payload.
const int otaMagic0 = 0x4F; // 'O'
const int otaMagic1 = 0x54; // 'T'
const int otaMagic2 = 0x41; // 'A'
const int otaMagic3 = 0x31; // '1'
const int otaHdrLen = 14;
const int otaSigLen = 8;
const int otaKeyLen = 8;
const int otaPayMax = 64;
const int otaFeedPrefix = 9;
const int otaGetPrefix = 8;
const int otaTlsPrefix = 8;
const int otaTls13Prefix = 10;
const int otaIpProtoTcp = 6;
const int otaTcpHdrLen = 20;
const int otaTcpSport = 0xC000;
const int otaTcpFlagFin = 0x01;
const int otaTcpFlagSyn = 0x02;
const int otaTcpFlagRst = 0x04;
const int otaTcpFlagPsh = 0x08;
const int otaTcpFlagAck = 0x10;
const int otaTcpSynAck = 0x12;
const int otaTcpIsn = 0x0A014149;
const int otaTcpWin = 0x1000;
const int otaTxDesc2 = 32;
const int otaTxDesc3 = 48;
const int otaBlobMax = 78;
const int otaTlsBoxOff = 32960;
const int otaTlsOffMagic = 0;
const int otaTlsOffFlags = 8;
const int otaTlsOffTrust = 16;
const int otaTlsOffRxLen = 48;
const int otaTlsOffTxLen = 52;
const int otaTlsOffPlainLen = 56;
const int otaTlsOffStage = 60;
const int otaTlsOffRx = 64;
const int otaTlsOffTx = 4160;
const int otaTlsOffPlain = 5696;
const int otaTlsTrustLen = 32;
const int otaTlsRxMax = 4096;
const int otaTlsTxMax = 1536;
const int otaTlsPlainMax = 128;
const int otaTlsGo = 1;
const int otaTlsDone = 2;
const int otaTlsBadcert = 4;
const int otaTlsFail = 8;
const int otaTlsHaveTx = 16;
const int otaTlsWantRx = 32;
const int otaTlsMagicLo = 0x4C535631; // 'LSV1'
const int otaTlsMagicHi = 0x4F544154; // 'OTAT'

/// `"ota feed "` -- 9 bytes. Matched before bare names. Not in help.
@rodata
final List<u8> otaStrCmdFeed = const [
  u8(0x6F), u8(0x74), u8(0x61), u8(0x20),
  u8(0x66), u8(0x65), u8(0x65), u8(0x64), u8(0x20),
];

/// `"ota get "` -- 8 bytes. TCP fetch from 10.0.2.2:<port>. Not in help.
@rodata
final List<u8> otaStrCmdGet = const [
  u8(0x6F), u8(0x74), u8(0x61), u8(0x20),
  u8(0x67), u8(0x65), u8(0x74), u8(0x20),
];

/// `"ota tls "` -- 8 bytes. TLS 1.2 fetch from 10.0.2.2:<port>. Not in help.
@rodata
final List<u8> otaStrCmdTls13 = const [
  u8(0x6F), u8(0x74), u8(0x61), u8(0x20),
  u8(0x74), u8(0x6C), u8(0x73), u8(0x31), u8(0x33), u8(0x20),
];

/// `"ota tls "` -- 8 bytes. TLS 1.2 fetch from 10.0.2.2:<port>. Not in help.
@rodata
final List<u8> otaStrCmdTls = const [
  u8(0x6F), u8(0x74), u8(0x61), u8(0x20),
  u8(0x74), u8(0x6C), u8(0x73), u8(0x20),
];

/// `"OTACERT"` -- 7 bytes. SHA-256 of trusted leaf (ADR-0154) or CA
/// (ADR-0168) DER.
@rodata
final List<u8> otaStrCert = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x43),
  u8(0x45), u8(0x52), u8(0x54),
];

/// `"SLOT.TXT"` -- 8 bytes. Target slot on the planted FAT volume.
@rodata
final List<u8> otaStrSlot = const [
  u8(0x53), u8(0x4C), u8(0x4F), u8(0x54),
  u8(0x2E), u8(0x54), u8(0x58), u8(0x54),
];

/// `"OTAKEY"` -- 6 bytes. Harness-planted verification key file.
@rodata
final List<u8> otaStrKey = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x4B),
  u8(0x45), u8(0x59),
];

/// `"OTA OK "` -- 7 bytes.
@rodata
final List<u8> otaStrOk = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x4F), u8(0x4B), u8(0x20),
];

/// `"OTA BADSIG\n"` -- 11 bytes. Signature mismatch; slot untouched.
@rodata
final List<u8> otaStrBadsig = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x42), u8(0x41), u8(0x44), u8(0x53),
  u8(0x49), u8(0x47), u8(0x0A),
];

/// `"OTA NONIC\n"` -- 10 bytes. No class 02/00 Ethernet on bus 0.
@rodata
final List<u8> otaStrNonic = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x49),
  u8(0x43), u8(0x0A),
];

/// `"OTA NOKEY\n"` -- 10 bytes.
@rodata
final List<u8> otaStrNokey = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4B), u8(0x45),
  u8(0x59), u8(0x0A),
];

/// `"OTA NOSLOT\n"` -- 11 bytes.
@rodata
final List<u8> otaStrNoslot = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x53), u8(0x4C),
  u8(0x4F), u8(0x54), u8(0x0A),
];

/// `"OTA SHORT\n"` -- 10 bytes.
@rodata
final List<u8> otaStrShort = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x53), u8(0x48), u8(0x4F), u8(0x52),
  u8(0x54), u8(0x0A),
];

/// `"OTA BADMAGIC\n"` -- 13 bytes.
@rodata
final List<u8> otaStrBadmagic = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x42), u8(0x41), u8(0x44), u8(0x4D),
  u8(0x41), u8(0x47), u8(0x49), u8(0x43), u8(0x0A),
];

/// `"OTA NOFRM\n"` -- 10 bytes. allocFrame failed.
@rodata
final List<u8> otaStrNofrm = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x46), u8(0x52),
  u8(0x4D), u8(0x0A),
];

/// `"OTA IO\n"` -- 7 bytes.
@rodata
final List<u8> otaStrIo = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x49), u8(0x4F), u8(0x0A),
];

/// `"OTA NOHOST\n"` -- 11 bytes. TCP connect failed (no listener / RST).
@rodata
final List<u8> otaStrNohost = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x48), u8(0x4F),
  u8(0x53), u8(0x54), u8(0x0A),
];

/// `"OTA BADPORT\n"` -- 12 bytes. Port argument missing or out of range.
@rodata
final List<u8> otaStrBadport = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x42), u8(0x41), u8(0x44), u8(0x50),
  u8(0x4F), u8(0x52), u8(0x54), u8(0x0A),
];

/// `"OTA BADCERT\n"` -- 12 bytes. Leaf / CA chain trust failure.
@rodata
final List<u8> otaStrBadcert = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x42), u8(0x41), u8(0x44), u8(0x43),
  u8(0x45), u8(0x52), u8(0x54), u8(0x0A),
];

/// `"OTA TLSFAIL\n"` -- 12 bytes. Handshake / record failure.
@rodata
final List<u8> otaStrTlsfail = const [
  u8(0x4F), u8(0x54), u8(0x41), u8(0x20),
  u8(0x54), u8(0x4C), u8(0x53), u8(0x46),
  u8(0x41), u8(0x49), u8(0x4C), u8(0x0A),
];

/// How many complete hex bytes follow `ota feed `.
@bare
u64 otaFeedByteCount() {
  final u64 len = shellLen();
  u64 i = u64(otaFeedPrefix);
  u64 pending = u64(0x100);
  u64 n = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        n = n + u64(1);
        pending = u64(0x100);
      }
    }
    i = i + u64(1);
  }
  return n;
}

/// Packs the hex argument into [dst]. Returns how many bytes written.
@bare
u64 otaFeedPack(u64 dst) {
  final u64 len = shellLen();
  u64 i = u64(otaFeedPrefix);
  u64 pending = u64(0x100);
  u64 n = u64(0);
  while (i < len) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d < u64(0x10)) {
      if (pending > u64(0xF)) {
        pending = d;
      } else {
        Pointer<u8>.fromAddress(dst + n).value =
            ((pending << u64(4)) | d).toU8();
        n = n + u64(1);
        pending = u64(0x100);
      }
    }
    i = i + u64(1);
  }
  return n;
}

/// Writes the 8-byte keyed digest of [payLen] bytes at [pay] with
/// the 8-byte key at [key] into [out]. Byte XOR only — DCDart traps
/// on u64 add/mul overflow, so no wide accumulator.
@bare
void otaDigest(u64 pay, u64 payLen, u64 key, u64 out) {
  u64 i = u64(0);
  while (i < u64(otaSigLen)) {
    final u64 k = Pointer<u8>.fromAddress(key + i).value.toU64();
    final u64 b0 = Pointer<u8>.fromAddress(pay + (i % payLen)).value.toU64();
    final u64 b1 =
        Pointer<u8>.fromAddress(pay + ((i * u64(3)) % payLen)).value.toU64();
    final u64 v = k ^ b0 ^ b1 ^ (payLen & u64(0xFF)) ^ i;
    Pointer<u8>.fromAddress(out + i).value = v.toU8();
    i = i + u64(1);
  }
}

/// Returns 1 iff the 8 bytes at [got] equal the 8 bytes at [want].
@bare
u64 otaSigEq(u64 got, u64 want) {
  u64 i = u64(0);
  u64 ok = u64(1);
  while (i < u64(otaSigLen)) {
    if (Pointer<u8>.fromAddress(got + i).value.toU64() !=
        Pointer<u8>.fromAddress(want + i).value.toU64()) {
      ok = u64(0);
    }
    i = i + u64(1);
  }
  return ok;
}

/// Load OTAKEY's first 8 bytes into [dst]. Returns 0 on success.
@bare
u64 otaLoadKey(u64 dst) {
  final u64 pn = fatParseAt(Rodata.addressOf(otaStrKey), u64(6));
  if (pn > u64(fatErrOk)) {
    return u64(1);
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    return u64(1);
  }
  final u64 lba = fatFileSector(u64(0));
  if (lba < u64(1)) {
    return u64(1);
  }
  if (fatReadCached(lba) > u64(0)) {
    return u64(1);
  }
  if (fatMeta(u64(fatMetaFileBytes)) < u64(otaKeyLen)) {
    return u64(1);
  }
  u64 i = u64(0);
  while (i < u64(otaKeyLen)) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(fatSectorBase() + i).value;
    i = i + u64(1);
  }
  return u64(0);
}

/// Overwrite SLOT.TXT's first cluster with [n] bytes from [src] and
/// update the directory size. Returns 0 on success.
@bare
u64 otaWriteSlot(u64 src, u64 n) {
  final u64 pn = fatParseAt(Rodata.addressOf(otaStrSlot), u64(8));
  if (pn > u64(fatErrOk)) {
    return u64(1);
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    return u64(1);
  }
  final u64 entry = fatMeta(u64(fatMetaFileEntry));
  final u64 first = fatMeta(u64(fatMetaFileFirst));
  final u64 lba = fatClusterSector(first, u64(0));
  if (lba < u64(1)) {
    return u64(1);
  }
  u64 i = u64(0);
  while (i < u64(fatSectorBytes)) {
    Pointer<u8>.fromAddress(fatSectorBase() + i).value = u8(0);
    i = i + u64(1);
  }
  i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(fatSectorBase() + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
  if (fatWriteSector(lba, fatSectorBase()) > u64(fatErrOk)) {
    return u64(1);
  }
  if (fatDirWrite(entry, first, n) > u64(fatErrOk)) {
    return u64(1);
  }
  return u64(0);
}

/// Verify plant at [buf] ([n] bytes) and write SLOT.TXT on a good
/// signature. Prints the same OTA lines as `ota feed`.
@bare
void otaApplyPlant(u64 buf, u64 n) {
  if (n < u64(otaHdrLen)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  if (n > (u64(otaHdrLen) + u64(otaPayMax))) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  if (Pointer<u8>.fromAddress(buf).value.toU64() != u64(otaMagic0)) {
    uartWrite(Rodata.addressOf(otaStrBadmagic), u64(13));
    return;
  }
  if (Pointer<u8>.fromAddress(buf + u64(1)).value.toU64() != u64(otaMagic1)) {
    uartWrite(Rodata.addressOf(otaStrBadmagic), u64(13));
    return;
  }
  if (Pointer<u8>.fromAddress(buf + u64(2)).value.toU64() != u64(otaMagic2)) {
    uartWrite(Rodata.addressOf(otaStrBadmagic), u64(13));
    return;
  }
  if (Pointer<u8>.fromAddress(buf + u64(3)).value.toU64() != u64(otaMagic3)) {
    uartWrite(Rodata.addressOf(otaStrBadmagic), u64(13));
    return;
  }
  final u64 payLen =
      (Pointer<u8>.fromAddress(buf + u64(4)).value.toU64() << u64(8)) |
      Pointer<u8>.fromAddress(buf + u64(5)).value.toU64();
  if (payLen < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  if (payLen > u64(otaPayMax)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  if (n != (u64(otaHdrLen) + payLen)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  // Key lives at the end of the same frame (past the plant).
  final u64 key = buf + u64(256);
  if (otaLoadKey(key) > u64(0)) {
    uartWrite(Rodata.addressOf(otaStrNokey), u64(10));
    return;
  }
  final u64 pay = buf + u64(otaHdrLen);
  final u64 expect = buf + u64(280);
  otaDigest(pay, payLen, key, expect);
  if (otaSigEq(buf + u64(6), expect) < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrBadsig), u64(11));
    return;
  }
  final u64 pn = fatParseAt(Rodata.addressOf(otaStrSlot), u64(8));
  if (pn > u64(fatErrOk)) {
    uartWrite(Rodata.addressOf(otaStrNoslot), u64(11));
    return;
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    uartWrite(Rodata.addressOf(otaStrNoslot), u64(11));
    return;
  }
  if (otaWriteSlot(pay, payLen) > u64(0)) {
    uartWrite(Rodata.addressOf(otaStrIo), u64(7));
    return;
  }
  uartWrite(Rodata.addressOf(otaStrOk), u64(7));
  uartPutHex(payLen, u64(4));
  uartNewline();
}

/// `ota feed <hex>` — RX plant of a signed update blob.
///
/// Requires a class-02/00 NIC (e1000 or virtio-net). Verifies the
/// planted signature against FAT `OTAKEY`. Good → write payload into
/// `SLOT.TXT`. Bad → print `OTA BADSIG` and leave the slot alone.
@bare
void otaFeed() {
  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  final u64 n = otaFeedByteCount();
  if (n < u64(otaHdrLen)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  if (n > (u64(otaHdrLen) + u64(otaPayMax))) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  final u64 buf = allocFrame();
  if (buf == u64(0)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  final u64 got = otaFeedPack(buf);
  if (got != n) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  otaApplyPlant(buf, n);
}

/// Decimal port after `ota get ` or `ota tls `. 0 if missing or > 65535.
@bare
u64 otaParsePortFrom(u64 prefix) {
  final u64 len = shellLen();
  u64 i = prefix;
  u64 n = u64(0);
  u64 digits = u64(0);
  while (i < len) {
    final u64 c = shellLineByte(i).toU64();
    if (c < u64(0x30)) {
      break;
    }
    if (c > u64(0x39)) {
      break;
    }
    n = (n * u64(10)) + (c - u64(0x30));
    if (n > u64(0xFFFF)) {
      return u64(0);
    }
    digits = digits + u64(1);
    i = i + u64(1);
  }
  if (digits < u64(1)) {
    return u64(0);
  }
  return n;
}

/// Decimal port after `ota get `.
@bare
u64 otaParsePort() {
  return otaParsePortFrom(u64(otaGetPrefix));
}

/// Store [val] as a 32-bit big-endian word at [addr].
@bare
void otaPutBe32(u64 addr, u64 val) {
  nicPutBe16(addr, (val >> u64(16)) & u64(0xFFFF));
  nicPutBe16(addr + u64(2), val & u64(0xFFFF));
}

/// Load a 32-bit big-endian word at [addr].
@bare
u64 otaGetBe32(u64 addr) {
  return (nicGetBe16(addr) << u64(16)) | nicGetBe16(addr + u64(2));
}

/// TCP checksum over [tcpLen] bytes at [tcp], with IPv4 addrs at
/// [ip]+12/[ip]+16 and protocol 6. Pseudo-header is folded in.
@bare
u64 otaTcpCsum(u64 ip, u64 tcp, u64 tcpLen) {
  u64 sum = nicCsumFold(tcp, tcpLen);
  sum = sum + nicGetBe16(ip + u64(12));
  sum = sum + nicGetBe16(ip + u64(14));
  sum = sum + nicGetBe16(ip + u64(16));
  sum = sum + nicGetBe16(ip + u64(18));
  sum = sum + u64(otaIpProtoTcp);
  sum = sum + tcpLen;
  while (u64(0) < (sum >> u64(16))) {
    sum = (sum & u64(0xFFFF)) + (sum >> u64(16));
  }
  return u64(0xFFFF) - (sum & u64(0xFFFF));
}

/// Ethernet + IPv4 + TCP headers at [buf]. [payloadLen] bytes follow
/// the 20-byte TCP header. [flags] is the TCP flags byte.
@bare
void otaPutTcp(u64 buf, u64 ral, u64 rah, u64 dstMac, u64 dport, u64 seq,
    u64 ack, u64 flags, u64 payloadLen, u64 ipId) {
  nicCopy6(buf, dstMac);
  nicPutMacAt(buf + u64(6), ral, rah);
  Volatile<u8>.fromAddress(buf + u64(12)).value = u8(nicEtherIpHi);
  Volatile<u8>.fromAddress(buf + u64(13)).value = u8(nicEtherIpLo);
  final u64 ip = buf + u64(14);
  final u64 ipLen = u64(nicIpHdrLen) + u64(otaTcpHdrLen) + payloadLen;
  Volatile<u8>.fromAddress(ip).value = u8(nicIpVerIhl);
  Volatile<u8>.fromAddress(ip + u64(1)).value = u8(0);
  nicPutBe16(ip + u64(2), ipLen);
  nicPutBe16(ip + u64(4), ipId);
  nicPutBe16(ip + u64(6), u64(0));
  Volatile<u8>.fromAddress(ip + u64(8)).value = u8(nicIpTtl);
  Volatile<u8>.fromAddress(ip + u64(9)).value = u8(otaIpProtoTcp);
  nicPutBe16(ip + u64(10), u64(0));
  Volatile<u8>.fromAddress(ip + u64(12)).value = u8(nicIpUs0);
  Volatile<u8>.fromAddress(ip + u64(13)).value = u8(nicIpUs1);
  Volatile<u8>.fromAddress(ip + u64(14)).value = u8(nicIpUs2);
  Volatile<u8>.fromAddress(ip + u64(15)).value = u8(nicIpUs3);
  Volatile<u8>.fromAddress(ip + u64(16)).value = u8(nicIpGw0);
  Volatile<u8>.fromAddress(ip + u64(17)).value = u8(nicIpGw1);
  Volatile<u8>.fromAddress(ip + u64(18)).value = u8(nicIpGw2);
  Volatile<u8>.fromAddress(ip + u64(19)).value = u8(nicIpGw3);
  final u64 tcp = ip + u64(nicIpHdrLen);
  nicPutBe16(tcp, u64(otaTcpSport));
  nicPutBe16(tcp + u64(2), dport);
  otaPutBe32(tcp + u64(4), seq);
  otaPutBe32(tcp + u64(8), ack);
  Volatile<u8>.fromAddress(tcp + u64(12)).value = u8(0x50);
  Volatile<u8>.fromAddress(tcp + u64(13)).value = flags.toU8();
  nicPutBe16(tcp + u64(14), u64(otaTcpWin));
  nicPutBe16(tcp + u64(16), u64(0));
  nicPutBe16(tcp + u64(18), u64(0));
  nicPutBe16(ip + u64(10), nicCsum(ip, u64(nicIpHdrLen)));
  nicPutBe16(tcp + u64(16),
      otaTcpCsum(ip, tcp, u64(otaTcpHdrLen) + payloadLen));
}

/// Program one TX descriptor at [ring]+[descOff] for [len] bytes at
/// [txbuf], then ring TDT to [tdt].
@bare
void otaTxKick(u64 bar, u64 ring, u64 descOff, u64 txbuf, u64 len, u64 tdt) {
  Volatile<u32>.fromAddress(ring + descOff).value = txbuf.toU32();
  Volatile<u32>.fromAddress(ring + descOff + u64(4)).value = u64(0).toU32();
  Volatile<u32>.fromAddress(ring + descOff + u64(8)).value =
      (len | (u64(nicTxCmd) << u64(24))).toU32();
  Volatile<u32>.fromAddress(ring + descOff + u64(12)).value = u64(0).toU32();
  nicRegPut(bar, u64(nicRegTdt), tdt);
}

/// 1 if [buf]/[len] is IPv4 TCP from the gateway to our ephemeral port.
@bare
u64 otaTcpFrameOk(u64 buf, u64 len, u64 dport) {
  if (len < (u64(14) + u64(nicIpHdrLen) + u64(otaTcpHdrLen))) {
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
  if (Volatile<u8>.fromAddress(buf + u64(14) + u64(9)).value.toU64() !=
      u64(otaIpProtoTcp)) {
    return u64(0);
  }
  if (len < (u64(14) + ihl + u64(otaTcpHdrLen))) {
    return u64(0);
  }
  final u64 tcp = buf + u64(14) + ihl;
  if (nicGetBe16(tcp + u64(2)) != u64(otaTcpSport)) {
    return u64(0);
  }
  if (nicGetBe16(tcp) != dport) {
    return u64(0);
  }
  return u64(1);
}

/// Poll RX for a TCP segment to our ephemeral port. Returns the frame
/// buffer, 2 if an RST arrived, 1 if noise was seen, or 0 on timeout.
@bare
u64 otaTcpFromRing(u64 rxring, u64 n, u64 dport, u64 wantFlags, u64 wantMask,
    u64 needPayload) {
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
        if (u64(0) < otaTcpFrameOk(buf, len, dport)) {
          final u64 verIhl =
              Volatile<u8>.fromAddress(buf + u64(14)).value.toU64();
          final u64 ihl = (verIhl & u64(0x0F)) << u64(2);
          final u64 tcp = buf + u64(14) + ihl;
          final u64 flags =
              Volatile<u8>.fromAddress(tcp + u64(13)).value.toU64();
          if ((flags & u64(otaTcpFlagRst)) == u64(otaTcpFlagRst)) {
            return u64(2);
          }
          final u64 doff =
              (Volatile<u8>.fromAddress(tcp + u64(12)).value.toU64() >>
                      u64(4)) <<
                  u64(2);
          final u64 ipTotal = nicGetBe16(buf + u64(14) + u64(2));
          final u64 payLen = ipTotal - ihl - doff;
          if ((flags & wantMask) == wantFlags) {
            if (needPayload < u64(1)) {
              return buf;
            }
            if (payLen > u64(0)) {
              return buf;
            }
          }
          seen = u64(1);
        }
      }
      i = i + u64(1);
    }
    spins = spins - u64(1);
  }
  return seen;
}

/// `ota get <port>` — TCP fetch of a signed blob from 10.0.2.2:<port>.
///
/// Same plant layout and signature check as `ota feed`. A missing
/// listener (RST / timeout) prints `OTA NOHOST` and leaves SLOT.TXT
/// alone. Cleartext TCP only — session crypto stays named.
@bare
void otaGet() {
  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  final u64 port = otaParsePort();
  if (port < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrBadport), u64(12));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nicCmdMem)) < u64(nicCmdMem)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  pciWrite32(bus, dev, fn, u64(pciRegCommand),
      (cmd & u64(0xFFFF)) | u64(nicCmdMemBme));
  final u64 bar = pciReadBar(bdf, u64(0));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  nicLinkUp(bar);
  final u64 ral = nicRegGet(bar, u64(nicRegRal0));
  final u64 rah = nicRegGet(bar, u64(nicRegRah0));
  nicRegPut(bar, u64(nicRegRah0), (rah & u64(0xFFFF)) | u64(nicRahAv));

  final u64 ring = allocFrame();
  if (ring < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(ring);
  final u64 txbuf = allocFrame();
  if (txbuf < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(txbuf);
  final u64 rxf0 = allocFrame();
  if (rxf0 < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  final u64 rxf1 = allocFrame();
  if (rxf1 < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  final u64 plant = allocFrame();
  if (plant < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(plant);

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
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  final u64 arp = nicArpFromRing(rxring, u64(nicRxScan));
  if (arp < u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  final u64 dstMac = arp + u64(22);

  // SYN
  vmZeroFrame(txbuf);
  otaPutTcp(txbuf, ral, rah, dstMac, port, u64(otaTcpIsn), u64(0),
      u64(otaTcpFlagSyn), u64(0), u64(0x4F31));
  final u64 synLen = u64(nicFrameLen);
  otaTxKick(bar, ring, u64(nicTxDesc1), txbuf, synLen, u64(2));
  final u64 staSyn =
      nicWaitByte(ring + u64(nicTxDesc1) + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (staSyn > u64(0xFF)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  final u64 synack = otaTcpFromRing(rxring, u64(nicRxScan), port,
      u64(otaTcpSynAck), u64(otaTcpSynAck), u64(0));
  if (synack < u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  if (synack == u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  final u64 saIhl =
      (Volatile<u8>.fromAddress(synack + u64(14)).value.toU64() & u64(0x0F)) <<
          u64(2);
  final u64 saTcp = synack + u64(14) + saIhl;
  final u64 serverSeq = otaGetBe32(saTcp + u64(4));
  final u64 clientSeq = u64(otaTcpIsn) + u64(1);

  // ACK the SYN
  vmZeroFrame(txbuf);
  otaPutTcp(txbuf, ral, rah, dstMac, port, clientSeq, serverSeq + u64(1),
      u64(otaTcpFlagAck), u64(0), u64(0x4F32));
  otaTxKick(bar, ring, u64(otaTxDesc2), txbuf, synLen, u64(3));
  final u64 staAck =
      nicWaitByte(ring + u64(otaTxDesc2) + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (staAck > u64(0xFF)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  final u64 data = otaTcpFromRing(rxring, u64(nicRxScan), port,
      u64(otaTcpFlagAck), u64(otaTcpFlagAck), u64(1));
  if (data < u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  if (data == u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  final u64 dIhl =
      (Volatile<u8>.fromAddress(data + u64(14)).value.toU64() & u64(0x0F)) <<
          u64(2);
  final u64 dTcp = data + u64(14) + dIhl;
  final u64 dOff =
      (Volatile<u8>.fromAddress(dTcp + u64(12)).value.toU64() >> u64(4)) <<
          u64(2);
  final u64 ipTotal = nicGetBe16(data + u64(14) + u64(2));
  final u64 payLen = ipTotal - dIhl - dOff;
  if (payLen < u64(otaHdrLen)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  if (payLen > u64(otaBlobMax)) {
    uartWrite(Rodata.addressOf(otaStrShort), u64(10));
    return;
  }
  final u64 payload = dTcp + dOff;
  u64 i = u64(0);
  while (i < payLen) {
    Pointer<u8>.fromAddress(plant + i).value =
        Volatile<u8>.fromAddress(payload + i).value;
    i = i + u64(1);
  }

  // ACK the data so the peer can FIN cleanly (optional for apply).
  final u64 dataSeq = otaGetBe32(dTcp + u64(4));
  vmZeroFrame(txbuf);
  otaPutTcp(txbuf, ral, rah, dstMac, port, clientSeq, dataSeq + payLen,
      u64(otaTcpFlagAck), u64(0), u64(0x4F33));
  otaTxKick(bar, ring, u64(otaTxDesc3), txbuf, synLen, u64(4));
  final u64 staData =
      nicWaitByte(ring + u64(otaTxDesc3) + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (staData > u64(0xFF)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  otaApplyPlant(plant, payLen);
}

@bare
u64 otaTlsBox() {
  return kernel_data_start() + u64(otaTlsBoxOff);
}

/// Load OTACERT's 32-byte SHA-256 into [dst]. Returns 0 on success.
@bare
u64 otaLoadCert(u64 dst) {
  final u64 pn = fatParseAt(Rodata.addressOf(otaStrCert), u64(7));
  if (pn > u64(fatErrOk)) {
    return u64(1);
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    return u64(1);
  }
  final u64 lba = fatFileSector(u64(0));
  if (lba < u64(1)) {
    return u64(1);
  }
  if (fatReadCached(lba) > u64(0)) {
    return u64(1);
  }
  if (fatMeta(u64(fatMetaFileBytes)) < u64(otaTlsTrustLen)) {
    return u64(1);
  }
  u64 i = u64(0);
  while (i < u64(otaTlsTrustLen)) {
    Pointer<u8>.fromAddress(dst + i).value =
        Pointer<u8>.fromAddress(fatSectorBase() + i).value;
    i = i + u64(1);
  }
  return u64(0);
}

/// Send [len] bytes from [src] as one TCP segment. Returns 0 on TX ok.
@bare
u64 otaTcpSendBytes(u64 bar, u64 ring, u64 descOff, u64 tdt, u64 txbuf,
    u64 ral, u64 rah, u64 dstMac, u64 dport, u64 seq, u64 ack, u64 src,
    u64 len, u64 ipId) {
  vmZeroFrame(txbuf);
  u64 i = u64(0);
  while (i < len) {
    Volatile<u8>.fromAddress(txbuf + u64(54) + i).value =
        Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
  otaPutTcp(txbuf, ral, rah, dstMac, dport, seq, ack,
      u64(otaTcpFlagAck) | u64(otaTcpFlagPsh), len, ipId);
  u64 ethLen = u64(54) + len;
  if (ethLen < u64(60)) {
    ethLen = u64(60);
  }
  otaTxKick(bar, ring, descOff, txbuf, ethLen, tdt);
  final u64 sta = nicWaitByte(ring + descOff + u64(12), u64(nicTxDd), u64(nicTxDd));
  if (sta > u64(0xFF)) {
    return u64(1);
  }
  return u64(0);
}

/// Poll for a TCP data segment; copy payload into [dst] (capacity [cap]).
/// Returns payload length, 0 on timeout, or 0xFFFFFFFF on RST.
/// [spins] bounds the poll (TLS uses a short bound so plain TCP fails fast).
@bare
u64 otaTcpRecvBytes(u64 rxring, u64 n, u64 dport, u64 dst, u64 cap,
    u64 expectAck, u64 spins) {
  while (u64(0) < spins) {
    final u64 _tick = tick_count();
    spins = spins - u64(1) - (_tick >> u64(63));
    u64 i = u64(0);
    while (i < n) {
      final u64 d = rxring + (i << u64(4));
      final u64 sta = Volatile<u8>.fromAddress(d + u64(12)).value.toU64();
      if ((sta & u64(nicRxDd)) == u64(nicRxDd)) {
        final u64 buf = Volatile<u32>.fromAddress(d).value.toU64();
        final u64 len = Volatile<u16>.fromAddress(d + u64(8)).value.toU64();
        if (u64(0) < otaTcpFrameOk(buf, len, dport)) {
          final u64 verIhl =
              Volatile<u8>.fromAddress(buf + u64(14)).value.toU64();
          final u64 ihl = (verIhl & u64(0x0F)) << u64(2);
          final u64 tcp = buf + u64(14) + ihl;
          final u64 flags =
              Volatile<u8>.fromAddress(tcp + u64(13)).value.toU64();
          if ((flags & u64(otaTcpFlagRst)) == u64(otaTcpFlagRst)) {
            return u64(0xFFFFFFFF);
          }
          final u64 doff =
              (Volatile<u8>.fromAddress(tcp + u64(12)).value.toU64() >>
                      u64(4)) <<
                  u64(2);
          final u64 ipTotal = nicGetBe16(buf + u64(14) + u64(2));
          final u64 payLen = ipTotal - ihl - doff;
          if (payLen > u64(0)) {
            if (payLen > cap) {
              return u64(0);
            }
            u64 j = u64(0);
            while (j < payLen) {
              Pointer<u8>.fromAddress(dst + j).value =
                  Volatile<u8>.fromAddress(tcp + doff + j).value;
              j = j + u64(1);
            }
            // Drop DD so the same buffer can be reused.
            Volatile<u8>.fromAddress(d + u64(12)).value = u8(0);
            Pointer<u64>.fromAddress(expectAck).value =
                otaGetBe32(tcp + u64(4)) + payLen;
            return payLen;
          }
        }
      }
      i = i + u64(1);
    }
    spins = spins - u64(1);
  }
  return u64(0);
}

/// `ota tls <port>` — TLS 1.2 fetch of a signed blob from 10.0.2.2:<port>.
///
/// C mailbox drives ClientHello / AES128-SHA / RSA. OTACERT trusts a
/// leaf fingerprint (one-cert) or a planted CA (chain + RSA-SHA256
/// verify, ADR-0168). Bad cert → BADCERT; no listener → NOHOST;
/// good → same otaApplyPlant as feed/get.
@bare
void otaTlsFetch(u64 prefix, u64 initStage) {

  final u64 bdf = pciFindByClass(u64(nicClassEthernet), u64(nicSubclassEthernet));
  if (bdf == u64(pciBdfNone)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  final u64 port = otaParsePortFrom(prefix);
  if (port < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrBadport), u64(12));
    return;
  }
  final u64 bus = (bdf >> u64(16)) & u64(0xFF);
  final u64 dev = (bdf >> u64(11)) & u64(0x1F);
  final u64 fn = (bdf >> u64(8)) & u64(0x07);
  final u64 cmd = pciRead32(bus, dev, fn, u64(pciRegCommand));
  if ((cmd & u64(nicCmdMem)) < u64(nicCmdMem)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  pciWrite32(bus, dev, fn, u64(pciRegCommand),
      (cmd & u64(0xFFFF)) | u64(nicCmdMemBme));
  final u64 bar = pciReadBar(bdf, u64(0));
  if (bar == u64(0)) {
    uartWrite(Rodata.addressOf(otaStrNonic), u64(10));
    return;
  }
  nicLinkUp(bar);
  final u64 ral = nicRegGet(bar, u64(nicRegRal0));
  final u64 rah = nicRegGet(bar, u64(nicRegRah0));
  nicRegPut(bar, u64(nicRegRah0), (rah & u64(0xFFFF)) | u64(nicRahAv));

  final u64 ring = allocFrame();
  if (ring < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(ring);
  final u64 txbuf = allocFrame();
  if (txbuf < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(txbuf);
  final u64 rxf0 = allocFrame();
  if (rxf0 < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  final u64 rxf1 = allocFrame();
  if (rxf1 < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  final u64 ackSlot = allocFrame();
  if (ackSlot < u64(1)) {
    uartWrite(Rodata.addressOf(otaStrNofrm), u64(10));
    return;
  }
  vmZeroFrame(ackSlot);

  final u64 box = otaTlsBox();
  // Clear the whole mailbox (.data may hold a prior session).
  // sizeof(OtaTlsCmd) == 10596 with hs[4096]; do not overrun into .data.
  u64 z = u64(0);
  while (z < u64(10596)) {
    Pointer<u8>.fromAddress(box + z).value = u8(0);
    z = z + u64(1);
  }
  if (otaLoadCert(box + u64(otaTlsOffTrust)) > u64(0)) {
    uartWrite(Rodata.addressOf(otaStrNokey), u64(10));
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
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));
  final u64 arp = nicArpFromRing(rxring, u64(nicRxScan));
  if (arp < u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  final u64 dstMac = arp + u64(22);

  // SYN / SYN-ACK / ACK — no TLS GO yet (otaTcpFromRing calls tick_count).
  vmZeroFrame(txbuf);
  otaPutTcp(txbuf, ral, rah, dstMac, port, u64(otaTcpIsn), u64(0),
      u64(otaTcpFlagSyn), u64(0), u64(0x4F41));
  otaTxKick(bar, ring, u64(nicTxDesc1), txbuf, u64(nicFrameLen), u64(2));
  if (nicWaitByte(ring + u64(nicTxDesc1) + u64(12), u64(nicTxDd), u64(nicTxDd)) >
      u64(0xFF)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));
  final u64 synack = otaTcpFromRing(rxring, u64(nicRxScan), port,
      u64(otaTcpSynAck), u64(otaTcpSynAck), u64(0));
  if (synack < u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  if (synack == u64(2)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  final u64 saIhl =
      (Volatile<u8>.fromAddress(synack + u64(14)).value.toU64() & u64(0x0F)) <<
          u64(2);
  final u64 saTcp = synack + u64(14) + saIhl;
  u64 serverAck = otaGetBe32(saTcp + u64(4)) + u64(1);
  u64 clientSeq = u64(otaTcpIsn) + u64(1);
  vmZeroFrame(txbuf);
  otaPutTcp(txbuf, ral, rah, dstMac, port, clientSeq, serverAck,
      u64(otaTcpFlagAck), u64(0), u64(0x4F42));
  otaTxKick(bar, ring, u64(otaTxDesc2), txbuf, u64(nicFrameLen), u64(3));
  if (nicWaitByte(ring + u64(otaTxDesc2) + u64(12), u64(nicTxDd), u64(nicTxDd)) >
      u64(0xFF)) {
    uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
    return;
  }
  nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));

  // TCP is up — start the TLS state machine.
  Pointer<u64>.fromAddress(box + u64(otaTlsOffMagic)).value =
      (u64(otaTlsMagicHi) << u64(32)) | u64(otaTlsMagicLo);
  Pointer<u32>.fromAddress(box + u64(otaTlsOffRxLen)).value = u64(0).toU32();
  Pointer<u32>.fromAddress(box + u64(otaTlsOffTxLen)).value = u64(0).toU32();
  Pointer<u32>.fromAddress(box + u64(otaTlsOffPlainLen)).value = u64(0).toU32();
  Pointer<u32>.fromAddress(box + u64(otaTlsOffStage)).value = initStage.toU32();
  Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value = u64(otaTlsGo);

  u64 tdt = u64(4);
  u64 desc = u64(otaTxDesc3);
  u64 ipId = u64(0x4F50);
  u64 rounds = u64(0);
  while (rounds < u64(4096)) {
    final u64 _tick = tick_count();
    rounds = rounds + (_tick >> u64(63));
    final u64 flags = Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value;
    if ((flags & u64(otaTlsBadcert)) == u64(otaTlsBadcert)) {
      uartWrite(Rodata.addressOf(otaStrBadcert), u64(12));
      return;
    }
    if ((flags & u64(otaTlsFail)) == u64(otaTlsFail)) {
      uartWrite(Rodata.addressOf(otaStrTlsfail), u64(12));
      return;
    }
    if ((flags & u64(otaTlsDone)) == u64(otaTlsDone)) {
      final u64 plen =
          Pointer<u32>.fromAddress(box + u64(otaTlsOffPlainLen)).value.toU64();
      otaApplyPlant(box + u64(otaTlsOffPlain), plen);
      return;
    }
    if ((flags & u64(otaTlsHaveTx)) == u64(otaTlsHaveTx)) {
      final u64 txLen =
          Pointer<u32>.fromAddress(box + u64(otaTlsOffTxLen)).value.toU64();
      if (txLen > u64(otaTlsTxMax)) {
        uartWrite(Rodata.addressOf(otaStrTlsfail), u64(12));
        return;
      }
      if (otaTcpSendBytes(bar, ring, desc, tdt, txbuf, ral, rah, dstMac, port,
              clientSeq, serverAck, box + u64(otaTlsOffTx), txLen, ipId) >
          u64(0)) {
        uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
        return;
      }
      clientSeq = clientSeq + txLen;
      ipId = ipId + u64(1);
      tdt = tdt + u64(1);
      if (tdt > u64(7)) {
        tdt = u64(1);
      }
      desc = ((tdt - u64(1)) & u64(7)) << u64(4);
      Pointer<u32>.fromAddress(box + u64(otaTlsOffTxLen)).value = u64(0).toU32();
      Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value =
          flags & (u64(0xFFFFFFFFFFFFFFFF) - u64(otaTlsHaveTx));
      nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));
    }
    final u64 flags2 = Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value;
    if ((flags2 & u64(otaTlsWantRx)) == u64(otaTlsWantRx)) {
      final u64 rxLen =
          Pointer<u32>.fromAddress(box + u64(otaTlsOffRxLen)).value.toU64();
      if (rxLen >= u64(otaTlsRxMax)) {
        uartWrite(Rodata.addressOf(otaStrTlsfail), u64(12));
        return;
      }
      final u64 got = otaTcpRecvBytes(rxring, u64(nicRxScan), port,
          box + u64(otaTlsOffRx) + rxLen, u64(otaTlsRxMax) - rxLen, ackSlot,
          u64(nicPollLimit));
      if (got == u64(0xFFFFFFFF)) {
        uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
        return;
      }
      if (got > u64(0)) {
        Pointer<u32>.fromAddress(box + u64(otaTlsOffRxLen)).value =
            (rxLen + got).toU32();
        serverAck = Pointer<u64>.fromAddress(ackSlot).value;
        // ACK the segment.
        vmZeroFrame(txbuf);
        otaPutTcp(txbuf, ral, rah, dstMac, port, clientSeq, serverAck,
            u64(otaTcpFlagAck), u64(0), ipId);
        otaTxKick(bar, ring, desc, txbuf, u64(nicFrameLen), tdt);
        final u64 _ackSta =
            nicWaitByte(ring + desc + u64(12), u64(nicTxDd), u64(nicTxDd));
        if (_ackSta > u64(0xFF)) {
          uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
          return;
        }
        tdt = tdt + u64(1);
        if (tdt > u64(7)) {
          tdt = u64(1);
        }
        desc = ((tdt - u64(1)) & u64(7)) << u64(4);
        ipId = ipId + u64(1);
        Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value =
            (flags2 & (u64(0xFFFFFFFFFFFFFFFF) - u64(otaTlsWantRx))) |
                u64(otaTlsGo);
        nicRegPut(bar, u64(nicRegRdt), u64(nicRxTail));
      } else if (rxLen > u64(0)) {
        Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value =
            flags2 | u64(otaTlsGo);
      }
    }
    if ((Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value &
            (u64(otaTlsHaveTx) | u64(otaTlsWantRx) | u64(otaTlsGo) |
                u64(otaTlsDone) | u64(otaTlsFail) | u64(otaTlsBadcert))) <
        u64(1)) {
      Pointer<u64>.fromAddress(box + u64(otaTlsOffFlags)).value = u64(otaTlsGo);
    }
    rounds = rounds + u64(1);
  }
  uartWrite(Rodata.addressOf(otaStrNohost), u64(11));
}

/// `ota tls13 <port>` — TLS 1.3 fetch (AES-128-GCM / X25519). Not in help.
@bare
void otaTls() {
  otaTlsFetch(u64(otaTlsPrefix), u64(0));
}

@bare
void otaTls13() {
  otaTlsFetch(u64(otaTls13Prefix), u64(10));
}
