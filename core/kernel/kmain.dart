// core/kernel/kmain.dart
//
// oscortex_core M0 kernel entry point (OSCORTEX_SPEC.md §2). Called from
// core/boot/boot.S via a plain C-ABI call, once the CPU is in 64-bit long
// mode with paging enabled -- the exact same call shape DCDart's own
// m0-seam/m1-pointer conformance harnesses already prove works.
//
// Initializes COM1 (16550 UART) and writes a fixed proof-of-life message,
// one byte at a time -- @bare has no String/array type yet, so there is
// no other way to spell this. The UART init sequence mirrors DCDart's own
// core/examples/m2-port/port_io.dart exactly (already verified there).
//
// KNOWN GAP (see docs/known-gaps.md): no busy-wait on the Line Status
// Register's Transmit-Holding-Register-Empty bit before each write --
// DCDart has no bitwise AND operator yet (DCDART_SPEC.md's own "Cut"
// list), so a real "wait until ready" check isn't expressible. The
// message below is 15 bytes, safely under the 16550's 16-byte TX FIFO
// (enabled by the init sequence), so every byte is queued in one shot
// without overflow -- fragile for a longer message, fine for M0.
//
// Import path assumes the sibling-checkout convention (../../../DCDart)
// documented in core/README.md -- same "only works from this exact
// layout" limitation DCDart's own dcc/README.md already accepts for
// itself (no real library resolver exists yet on either side).
import '../../../DCDart/core/runtime/dc-core-bare/prelude.dart';

@bare
void kmain() {
  // --- COM1 (0x3F8) init -- identical sequence to core/examples/m2-port/
  // port_io.dart's initCom1() in the DCDart repo, reused rather than
  // reinvented.
  Port.outb(u16(0x3F9), u8(0x00)); // disable interrupts
  Port.outb(u16(0x3FB), u8(0x80)); // enable DLAB (divisor-latch access)
  Port.outb(u16(0x3F8), u8(0x03)); // divisor low byte (38400 baud)
  Port.outb(u16(0x3F9), u8(0x00)); // divisor high byte
  Port.outb(u16(0x3FB), u8(0x03)); // 8 bits, no parity, one stop bit
  Port.outb(u16(0x3FA), u8(0xC7)); // enable FIFO, clear, 14-byte threshold
  Port.outb(u16(0x3FC), u8(0x0B)); // IRQs enabled, RTS/DSR set

  // --- Proof of life: "OSCORTEX M0 OK\n" (15 bytes), one Port.outb per
  // byte -- see core/tests/conformance/m0-boot/run.sh for what asserts
  // against this exact sequence.
  Port.outb(u16(0x3F8), u8(0x4F)); // 'O'
  Port.outb(u16(0x3F8), u8(0x53)); // 'S'
  Port.outb(u16(0x3F8), u8(0x43)); // 'C'
  Port.outb(u16(0x3F8), u8(0x4F)); // 'O'
  Port.outb(u16(0x3F8), u8(0x52)); // 'R'
  Port.outb(u16(0x3F8), u8(0x54)); // 'T'
  Port.outb(u16(0x3F8), u8(0x45)); // 'E'
  Port.outb(u16(0x3F8), u8(0x58)); // 'X'
  Port.outb(u16(0x3F8), u8(0x20)); // ' '
  Port.outb(u16(0x3F8), u8(0x4D)); // 'M'
  Port.outb(u16(0x3F8), u8(0x30)); // '0'
  Port.outb(u16(0x3F8), u8(0x20)); // ' '
  Port.outb(u16(0x3F8), u8(0x4F)); // 'O'
  Port.outb(u16(0x3F8), u8(0x4B)); // 'K'
  Port.outb(u16(0x3F8), u8(0x0A)); // '\n'
}
