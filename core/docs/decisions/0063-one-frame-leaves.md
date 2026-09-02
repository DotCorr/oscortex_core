# ADR-0063 — One Ethernet frame leaves the machine

**Status:** accepted, implemented (`core/kernel/nic.dart`, `core/tests/conformance/n1-frame`).
**Depends on ADR-0058** (MAC from `RAL0`/`RAH0`) and on `pciWrite32` (G1 / ADR-0065).
**Implements** `docs/design/net-stack.md` §9 N1.
**Number:** 0063 — 0065 is G1's bus-master write; this is the packet.

---

## 1. The question

N1 is the first network milestone that causes an effect outside the
kernel: one Ethernet frame on the wire. The expectation comes from
outside the kernel — the `mac=` string the harness typed, plus a
broadcast header and a reserved ethertype the harness reconstructed
from the kernel's own named constants.

## 2. The decision

1. **TX, not RX.** `net-stack.md` §9 N1 is "one frame leaves the
   machine": a TX ring, one frame from `allocFrame()`, one descriptor,
   one `TDT` write, one `DD` poll. Reception is N2 (ARP).
2. **A broadcast frame with ethertype `0x88B5`**, not ARP or IPv4.
   IEEE 802.1 Local Experimental Ethertype 1 is reserved. The body is
   eight `@rodata` bytes (`N1FRAME!`); the rest of the 60-byte minimum
   is zeros from `vmZeroFrame`. The harness builds the same 60 bytes
   from `mac=` and those constants. No IP, no ARP, no TCP.
3. **`nic send`, not a boot line and not a syscall.** `nic` still
   prints the MAC (n0-mac unchanged). `nic send` programs the card and
   transmits. Neither is in `help`.
4. **DMA buffers from `allocFrame()`, zero new `.bss`.** One frame for
   the 8-descriptor TX ring, one for the packet. Identity map: the
   physical address is the virtual address. Frames are never freed.
   `wmeventStore` stays last.
5. **`pciWrite32` sets MEM|BME before the first DMA.** With `romfile=`
   the option ROM never ran, so SeaBIOS left bit 2 clear. The write
   keeps the command half and zeros the status half (W1C). The `pci`
   command's line format does not change.
6. **Poll `DD`. Do not use IRQ 11.** The interrupt is on the slave PIC.

## 3. The printed lines

```
NIC MAC XX:XX:XX:XX:XX:XX
NIC TX 003C
```

Timeout: `NIC TXTMO`. Absent device / no decode / no BAR / no frame:
the N0 refusals, plus `NIC NOFRM`.

## 4. Binary

`n1-frame/run.sh` types `nic send` on a boot whose QEMU line includes
`-netdev user,id=n0 -device e1000,netdev=n0,mac=<derived>,romfile=`
and `-object filter-dump`. The pcap must contain **exactly one**
packet, equal byte-for-byte to the 60-byte frame the harness built
(FCS excluded). Source MAC equals `mac=`.

Negative control: the same flags, no `nic send` → **zero** packets.
Anti-vacuity: a zero-packet pcap fails the positive assertion.
`romfile=` is why that control is honest.

## 5. What this is not

Not ARP, IP, ICMP, UDP, TCP, a socket, a `/net` descriptor, or a
slave-PIC path. Not an RX ring. Not a change to the `pci` command.
Not a help line.
