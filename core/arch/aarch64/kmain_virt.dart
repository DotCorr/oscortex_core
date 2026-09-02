// core/arch/aarch64/kmain_virt.dart
//
// A1 proof of life: a separate library root from core/kernel/kmain.dart.
// DCDart has no conditional compilation (arm64-port.md STEP 2), so arch
// selection is "which files are in this part list". This milestone has no
// parts and does not share the x86 kmain — that sharing is unverified and
// is the first thing a later rung must check, not this one.
//
// THE PRELUDE IMPORT GOES THROUGH `core/build/dcdart`, WHICH IS A SYMLINK
// TO $DCDART_HOME THAT `core/scripts/build-kernel-arm.sh` CREATES ON EVERY
// BUILD. Same ADR-0043 spelling rule as the x86 root; a different string
// here makes every @bare invisible.
import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';

// PSCI SYSTEM_OFF. DCDart cannot emit `hvc`; the body is in
// core/boot-arm/boot.S. After the call the machine is off — this is the
// path the harness asserts as QEMU exit 0.
@extern
external void psci_system_off();

// "OSCORTEX A64 OK\n" — 16 bytes. A1's serial golden, and the reason this
// file exists: the bytes must come from DCDart @rodata, not from .asciz in
// boot.S (arm64-port.md A1: "the message comes from DCDart rather than
// from .asciz").
@rodata
final List<u8> a64Banner = const [
  u8(0x4F),
  u8(0x53),
  u8(0x43),
  u8(0x4F),
  u8(0x52),
  u8(0x54),
  u8(0x45),
  u8(0x58),
  u8(0x20),
  u8(0x41),
  u8(0x36),
  u8(0x34),
  u8(0x20),
  u8(0x4F),
  u8(0x4B),
  u8(0x0A)
];

// QEMU -M virt PL011, measured in arm64-port.md STEP 3: 0x09000000.
// Register map is 32-bit MMIO. TXFF is UARTFR bit 5.
//
// Hardcoded this milestone: A2 is the device-tree walk that makes the
// address derived. A hardcoded 0x09000000 that still prints on -M virt
// is exactly A1.

@bare
void pl011Putc(u8 c) {
  // UARTFR.TXFF (bit 5) is SET when the FIFO is full — the opposite of
  // the 16550's LSR.THRE. Waiting while the bit is clear spins forever
  // on an empty FIFO; measured: that polarity hung QEMU with zero
  // serial bytes and no PSCI. Wait while full, then write UARTDR.
  u32 fr = Volatile<u32>.fromAddress(u64(0x09000018)).value;
  while ((fr & u32(0x20)) > u32(0)) {
    fr = Volatile<u32>.fromAddress(u64(0x09000018)).value;
  }
  Volatile<u32>.fromAddress(u64(0x09000000)).value = c.toU32();
}

@bare
void kmain() {
  // UARTCR: UARTEN | TXE. QEMU's PL011 often accepts a bare UARTDR write
  // anyway (the asm probe did); enabling the device is the honest driver.
  Volatile<u32>.fromAddress(u64(0x09000030)).value = u32(0x0101);

  final u64 base = Rodata.addressOf(a64Banner);
  u64 i = u64(0);
  while (i < u64(16)) {
    pl011Putc(Pointer<u8>.fromAddress(base + i).value);
    i = i + u64(1);
  }
  psci_system_off();
}
