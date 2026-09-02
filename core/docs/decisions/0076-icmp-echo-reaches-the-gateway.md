# ADR-0076 — ICMP echo reaches the gateway

**Status:** accepted, implemented (`core/kernel/nic.dart`, `core/tests/conformance/n3-ping`).
**Depends on ADR-0066** (ARP for 10.0.2.2) and ADR-0063 (TX one frame).
**Implements** `docs/design/net-stack.md` §9 N3.
**Number:** 0076 — after listing 0060–0069 (0066 is N2), 0070–0075
are taken (0074 collided across G3/A1/NVM1; 0075 is title bars).
This is the next unique number.

---

## 1. The question

N3 is the first network milestone that is *on a network* rather than
*on a wire*. An IPv4 datagram leaves, SLIRP answers it, and the kernel
understood the reply as ICMP. The expectation comes from outside the
kernel — the `net=` string the harness typed, plus IP and ICMP
checksums the host recomputes.

## 2. The decision

1. **`nic ping`, not `ping <n>` and not a syscall.** One echo, N = 1.
   `nic` still prints the MAC (n0-mac unchanged). `nic send` still
   sends 0x88B5 (n1-frame unchanged). `nic arp` still resolves and
   stops (n2-arp unchanged). None of the N-commands is in `help`.
2. **ARP first, then echo.** The dest MAC is the reply SHA from the
   wire, not a constant. 10.0.2.2 is the only target — SLIRP answers
   that address inside libslirp. Not 8.8.8.8.
3. **Checksums are the one's-complement of the folded 16-bit sum.**
   `nicCsumFold` adds and folds. `nicCsum` subtracts from `0xFFFF`.
   Omit that subtraction and SLIRP drops the request. The host
   recomputes both the IPv4 header checksum and the ICMP checksum
   on the pcap; that arithmetic is not the kernel's.
4. **Type 0 only.** `nicIcmpTypeOk` accepts `nicIcmpEchoReply`. A
   build that compares against `nicIcmpEchoRequest` prints
   `NIC ICMPMISS 0008` and reports nothing. That is the load-bearing
   check.
5. **DMA buffers from `allocFrame()`, zero new `.bss`.** Same four
   frames as N2 (shared TX+RX ring, TX buffer, two RX buffer frames).
   The ICMP request reuses the TX buffer after ARP `DD`. Identity
   map. Frames are never freed. `wmeventStore` stays last.
6. **Poll `DD` in the command. Do not use IRQ 11. Do not call
   `netTick`.** Same `nicRxHold` as N2 so QEMU's flush timer can
   fire. No TCP. No Wi-Fi.

## 3. The printed lines

```
NIC MAC XX:XX:XX:XX:XX:XX
NIC TX 003C
NIC ARP YY:YY:YY:YY:YY:YY
NIC TX 003C
NIC PING 0A000202 4E33 0001
```

The `NIC PING` fields are the echo-reply source IP (eight hex
octets), identifier, and sequence, all read off the wire. Timeouts:
`NIC TXTMO`, `NIC RXTMO`. Miss (frame arrived, type not 0):
`NIC ICMPMISS 0008`. Absent device / no decode / no BAR / no frame:
the N0 refusals, plus `NIC NOFRM`.

## 4. Binary

`n3-ping/run.sh` types `nic ping` on a boot whose QEMU line includes
`-netdev user,id=n0,net=<derived> -device e1000,netdev=n0,mac=<derived>,romfile=`
and `-object filter-dump`. The pcap must contain an ARP pair and then
an ICMP echo request to `net|2` plus a reply. The host verifies every
outbound IPv4 header checksum and every ICMP checksum. The printed
IP must equal the reply's source IP as read out of the pcap, **and**
equal the four address bytes of `net|2`. Identifier and sequence
must match pairwise (request, reply, printed line, kernel constants).

Negative control: the same flags, no `nic ping` → **zero** packets.
Anti-vacuity: a zero-packet pcap fails the positive assertion.
`romfile=` is why that control is honest.

## 5. What this is not

Not TCP, UDP, DHCP, Wi-Fi, a socket, a `/net` descriptor, or a
slave-PIC path. Not `netTick`. Not a change to `nic`, `nic send`, or
`nic arp`. Not a help line. Not a `.bss` block.
