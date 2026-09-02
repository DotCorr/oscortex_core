// core/kernel/virtnet.dart
//
// ADR-0145. VirtIO-net is a second NIC class beside e1000. Find
// vendor 0x1AF4 / device 0x1041, resolve VIRTIO_PCI_CAP_DEVICE_CFG,
// read the six-byte MAC from the device config, print
// `NIC VIRTIO aa:bb:cc:dd:ee:ff`. ZERO donated `.bss`. Not a
// rewrite of nic.dart's e1000 path. Not an e1000 relabel. Not Wi-Fi.
// Syscall 11 stays fdwait. Not in help.
//
// QEMU `-device virtio-net-pci` is the stand-in. A laptop vendor:device
// is not the match. Feature negotiation / virtqueues / TX are a
// later rung.

part of 'kmain.dart';

const int virtnetVendor = 0x1AF4;
const int virtnetDevice = 0x1041;
const int virtnetRegCmd = 0x04;
const int virtnetRegCap = 0x34;
const int virtnetRegBar0 = 0x10;
const int virtnetCapVendor = 0x09;
const int virtnetStatusCaps = 0x10;
const int virtnetCapDevice = 4;
const int virtnetCapBound = 32;
const int virtnetCmdMem = 0x02;

/// `"nic virtio"` -- 10 bytes. Longest-first before bare `nic`.
@rodata
final List<u8> virtnetStrCmd = const [
  u8(0x6E), u8(0x69), u8(0x63), u8(0x20),
  u8(0x76), u8(0x69), u8(0x72), u8(0x74), u8(0x69), u8(0x6F),
];

/// `"NIC VIRTIO "` -- 11 bytes.
@rodata
final List<u8> virtnetStrTag = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
];

/// `"NIC VIRTIO NONE\n"` -- 16 bytes.
@rodata
final List<u8> virtnetStrNone = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x4E), u8(0x45), u8(0x0A),
];

/// `"NIC VIRTIO NOCFG\n"` -- 17 bytes.
@rodata
final List<u8> virtnetStrNoCfg = const [
  u8(0x4E), u8(0x49), u8(0x43), u8(0x20),
  u8(0x56), u8(0x49), u8(0x52), u8(0x54), u8(0x49), u8(0x4F), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x43), u8(0x46), u8(0x47), u8(0x0A),
];

/// BAR [bar]'s MMIO base, or 0. Same shape as virtgpuBarBase.
@bare
u64 virtnetBarBase(u64 bus, u64 dev, u64 fn, u64 bar) {
  if (bar > u64(5)) {
    return u64(0);
  }
  final u64 raw = pciRead32(bus, dev, fn, u64(virtnetRegBar0) + (bar << u64(2)));
  if ((raw & u64(1)) > u64(0)) {
    return u64(0);
  }
  return raw & u64(0xFFFFFFF0);
}

/// DEVICE_CFG MMIO window, or 0.
@bare
u64 virtnetDeviceCfg(u64 bus, u64 dev, u64 fn) {
  final u64 status = (pciRead32(bus, dev, fn, u64(virtnetRegCmd)) >> u64(16)) &
      u64(0xFFFF);
  if ((status & u64(virtnetStatusCaps)) < u64(1)) {
    return u64(0);
  }
  u64 off = pciRead32(bus, dev, fn, u64(virtnetRegCap)) & u64(0xFF);
  u64 guard = u64(0);
  while (off > u64(0)) {
    if (guard > u64(virtnetCapBound)) {
      return u64(0);
    }
    guard = guard + u64(1);
    final u64 dw0 = pciRead32(bus, dev, fn, off);
    final u64 id = dw0 & u64(0xFF);
    final u64 next = (dw0 >> u64(8)) & u64(0xFF);
    if (id == u64(virtnetCapVendor)) {
      final u64 cfgType = (dw0 >> u64(24)) & u64(0xFF);
      if (cfgType == u64(virtnetCapDevice)) {
        final u64 dw1 = pciRead32(bus, dev, fn, off + u64(4));
        final u64 bar = dw1 & u64(0xFF);
        final u64 capOff = pciRead32(bus, dev, fn, off + u64(8));
        final u64 base = virtnetBarBase(bus, dev, fn, bar);
        if (base < u64(1)) {
          return u64(0);
        }
        return base + capOff;
      }
    }
    off = next;
  }
  return u64(0);
}

/// Print one MAC byte as two hex digits, then a colon unless last.
@bare
void virtnetPutMacByte(u64 b, u64 last) {
  uartPutHex(b & u64(0xFF), u64(2));
  if (last < u64(1)) {
    conPutc(u8(0x3A));
  }
}

/// `nic virtio` -- find VirtIO-net, print its device-config MAC.
@bare
void virtnetReport() {
  u64 dev = u64(0);
  while (dev < u64(32)) {
    final u64 id = pciRead32(u64(0), dev, u64(0), u64(0));
    if ((id & u64(0xFFFF)) == u64(virtnetVendor)) {
      if (((id >> u64(16)) & u64(0xFFFF)) == u64(virtnetDevice)) {
        final u64 cmd = pciRead32(u64(0), dev, u64(0), u64(virtnetRegCmd));
        if ((cmd & u64(virtnetCmdMem)) < u64(1)) {
          pciWrite32(u64(0), dev, u64(0), u64(virtnetRegCmd),
              (cmd & u64(0xFFFF)) | u64(virtnetCmdMem));
        }
        final u64 cfg = virtnetDeviceCfg(u64(0), dev, u64(0));
        if (cfg < u64(1)) {
          uartWrite(Rodata.addressOf(virtnetStrNoCfg), u64(17));
          return;
        }
        uartWrite(Rodata.addressOf(virtnetStrTag), u64(11));
        u64 i = u64(0);
        while (i < u64(6)) {
          final u64 b = Volatile<u8>.fromAddress(cfg + i).value.toU64();
          u64 last = u64(0);
          if (i == u64(5)) {
            last = u64(1);
          }
          virtnetPutMacByte(b, last);
          i = i + u64(1);
        }
        uartNewline();
        return;
      }
    }
    dev = dev + u64(1);
  }
  uartWrite(Rodata.addressOf(virtnetStrNone), u64(16));
}

/// Silent. Retains nothing.
@bare
void virtnetInit() {}
