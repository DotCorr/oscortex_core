# ADR-0058 — The kernel reads the e1000 MAC address

**Status:** accepted, implemented (`core/kernel/nic.dart`, `core/tests/conformance/n0-mac`).
**Depends on ADR-0008** (PCI configuration-space *read*).
**Does not close GAP-0067 item 2** (still no `port_outl` to `0xCFC`).
**Implements** `docs/design/net-stack.md` §9 N0.
**Number:** 0058, not 0057 — A1 already took 0057; D7 took 0055.

---

## 1. The question

N0 is the first network milestone: the kernel finds the e1000 and prints the
MAC it read from the device. The expectation comes from outside the kernel —
the `mac=` string the harness itself typed on the QEMU command line.

## 2. The decision

1. **A new file, `nic.dart`, `part of 'kmain.dart'`.** Zero donated `.bss`.
   The MAC is printed from locals after a PCI walk. `part 'nic.dart'` sits
   after `kbdq.dart` and before `wmevent.dart`, so D7 keeps last place in
   `.bss` (ADR-0033 §6.4).
2. **Configuration space is still read-only.** `pciFindByClass` and
   `pciReadBar` are two more readers. SeaBIOS has already set memory-decode
   and bus-master (`cfg[0x04] = 0x0107` on this machine). N0 checks both
   bit 1 (memory decode) and prints `NIC NOCMD` if it is clear. Bit 2
   (bus-master) is a DMA fact; N0 does not DMA, and an explicit
   `-device e1000` often has it clear. It does not write `0xCFC`.
3. **The MAC comes from `RAL0`/`RAH0` over BAR0 MMIO.** QEMU copies `mac=`
   into the receive-address registers at realize/reset. An EEPROM (`EERD`)
   cycle is not needed on this machine and is a named successor.
4. **The print is a command, not a boot line.** QEMU's default machine
   already has an e1000 (net-stack.md §0.2 fact 2). A boot-time MAC line
   would appear in every session golden after `M1 END`. `nic` is not in
   `help`. `nicInit()` is called from `kmain` and prints nothing, so
   `m1-interrupts`' 544-byte golden does not move.
5. **No syscall, no interrupt, no packet.** IRQ 11 is on the slave PIC and
   is not this milestone.

## 3. The printed line

```
NIC MAC XX:XX:XX:XX:XX:XX
```

Six bytes, uppercase hex, colon-separated — the same shape QEMU's `mac=`
argument uses. Absent device: `NIC NONE`, and no `NIC MAC` line.

## 4. Binary

`n0-mac/run.sh` types `nic` on a boot whose QEMU line includes
`-nic user,model=e1000,mac=<derived>,romfile=`. The printed MAC must equal
the `mac=` string the harness typed. `romfile=` is mandatory: without it
the option ROM's DHCP contaminates later pcaps. Negative control: `-nic none`
prints `NIC NONE` and no MAC line. Anti-vacuity: the harness refuses an
empty expected MAC.

## 5. What this is not

Not ARP, IP, TCP, a socket, a `/net` descriptor, or a slave-PIC path.
Not `pciWrite32`. Not a change to the `pci` command's line format
(m5-pci goldens are untouched).
