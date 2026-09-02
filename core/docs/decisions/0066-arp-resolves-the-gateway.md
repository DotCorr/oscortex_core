# ADR-0066 — ARP resolves the gateway

**Status:** accepted, implemented (`core/kernel/nic.dart`, `core/tests/conformance/n2-arp`).
**Depends on ADR-0063** (TX one frame) and ADR-0058 (MAC from `RAL0`/`RAH0`).
**Implements** `docs/design/net-stack.md` §9 N2.
**Number:** 0066 — 0062 is focus, 0063 is N1, 0064 is scanout, 0065 is G1.
USB1 xHCI is 0068; G2 is 0067.

---

## 1. The question

N2 is the first network milestone that *receives*: a frame arrives, and
the kernel understood it. The expectation comes from outside the kernel
— the `mac=` and `net=` strings the harness typed, plus the ARP reply
SLIRP wrote into the pcap.

## 2. The decision

1. **RX ring plus one ARP request, not a host inject.** `net-stack.md`
   §9 N2: SLIRP answers ARP for `net|2` itself, so this milestone needs
   no helper on the host. `nic arp` posts four 2048-byte RX buffers,
   sends a 60-byte broadcast ARP request for 10.0.2.2, polls RX `DD`,
   and prints the reply's sender hardware address.
2. **Opcode 2 only.** `nicArpOpcodeOk` accepts `nicArpOperReply`. A
   build that inverts that comparison prints `NIC ARPMISS 0001` and
   resolves nothing. That is the load-bearing check.
3. **`nic arp`, not a boot line and not a syscall.** `nic` still prints
   the MAC (n0-mac unchanged). `nic send` still sends 0x88B5 (n1-frame
   unchanged). Neither N-command is in `help`.
4. **DMA buffers from `allocFrame()`, zero new `.bss`.** One frame holds
   both rings (TX at 0, RX at 256). One TX buffer, two RX buffer frames
   (four 2048-byte slots). Identity map. Frames are never freed.
   `wmeventStore` stays last.
5. **Poll `DD` in the command. Do not use IRQ 11. Do not call
   `netTick`.** N0–N3 do not need IRQ0 permanently unmasked
   (`net-stack.md` §4.4): the harness is driving and the command spins.
   QEMU's `set_rx_control` arms a 1000 ms flush timer; until it fires
   `e1000_can_receive` is false. `nicRxHold` unmasks the PIT for 110
   ticks (1.1 s) after `RCTL.EN`, then remasks — same shape as
   `ticks`. Without that wait the reply is on the pcap and never in
   the ring.
6. **No IP, no ICMP, no TCP.** The addresses 10.0.2.15 / 10.0.2.2 are
   static constants so the request can be built. They are not a stack.
   The gateway MAC is not a constant — it comes off the wire.

## 3. The printed lines

```
NIC MAC XX:XX:XX:XX:XX:XX
NIC TX 003C
NIC ARP YY:YY:YY:YY:YY:YY
```

Timeouts: `NIC TXTMO`, `NIC RXTMO`. Miss (frame arrived, opcode not 2):
`NIC ARPMISS 0001`. Absent device / no decode / no BAR / no frame: the
N0 refusals, plus `NIC NOFRM`.

## 4. Binary

`n2-arp/run.sh` types `nic arp` on a boot whose QEMU line includes
`-netdev user,id=n0,net=<derived> -device e1000,netdev=n0,mac=<derived>,romfile=`
and `-object filter-dump`. The pcap must contain an ARP request from
`mac=` for `net|2`, then a reply. The printed MAC must equal the
reply's source MAC as read out of the pcap, **and** equal `52:55`
concatenated with the four address bytes of `net|2`. A disagreement
between those two observers fails.

Negative control: the same flags, no `nic arp` → **zero** packets.
Anti-vacuity: a zero-packet pcap fails the positive assertion.
`romfile=` is why that control is honest.

## 5. What this is not

Not ICMP, IP, UDP, TCP, a socket, a `/net` descriptor, or a slave-PIC
path. Not `netTick`. Not a change to `nic` or `nic send`. Not a help
line. Not a `.bss` block.
