# ADR-0068 — The kernel reads the xHCI capability and operational registers

**Status:** accepted, implemented, verified (`tests/conformance/u1-xhci/run.sh`)
**Date:** 2026-08-30
**Depends on** USB0 (`core/kernel/usb.dart` PCI walk, `tests/conformance/u0-xhci`).
**Implements** `docs/design/usb-hid.md` USB1.
**Number:** 0068 — N2 ARP is 0066; G2 DRIVER_OK is 0067. This file was
the other 0066 (USB1 xHCI MMIO). N0's MAC MMIO read is 0058; G0's
capability walk is 0059; this is the same shape for the laptop
keyboard's host controller.

---

## 1. The question

USB0 found qemu-xhci on PCI and printed the function. USB1 is the first
*device* read: capability and operational registers live in BAR0 MMIO, not
in configuration space. A printed BDF can be a walk; a printed `CAPLENGTH`
that matches a BAR QEMU assigned, and a port count the harness chose, cannot.

## 2. The decision

1. **Same file, still zero `.bss`.** `usb.dart` grows the `usb` command.
   BAR0, the capability dword, `HCSPARAMS1`, `DBOFF`, `RTSOFF`, `USBCMD`
   and `USBSTS` are locals. `part 'usb.dart'` stays after `nic.dart` and
   before `wmevent.dart`, so D7 keeps last place (ADR-0033 §6.4).
2. **BAR0 is a 64-bit pair.** qemu-xhci is a 64-bit MMIO BAR (`peripherals.md`
   A4). The upper dword is refused if non-zero: `boot.S` maps
   `[3 GiB, 4 GiB)` and nothing above 4 GiB (same refusal as G0).
3. **The numbers come from `Volatile<u32>` loads at BAR0.** Capability
   registers sit at BAR0+0 **[spec]**; operational registers sit at
   `BAR0 + CAPLENGTH`. Memory-decode is checked and not written. USB1
   does not set Run/Stop and does not reset.
4. **The print is still the hidden `usb` command.** `usbInit()` stays a
   no-op. An absent controller still prints `USB NONE` and no capability
   line. `usb` is not in `help`.
5. **No syscall, no interrupt, no HID, no `usb-kbd`.** Attaching
   `usb-kbd` on this boot would steal QEMU `send-key` from the 8042
   (`usb-hid.md` §1). USB2 owns that machine.

## 3. The printed lines

```
USB XHCI 00:04.0 1B36:000D 0C/03/30
USB BAR FEBF0000 CAPLENGTH 40 HCIVERSION 0100 SLOTS 40 INTRS 0010 PORTS 05
USB DBOFF 00002000 RTSOFF 00001000 USBCMD 00000000 USBSTS 00000001
```

Absent device: `USB NONE`, and no `USB BAR` / `USB DBOFF` line.
`USB NOCMD` / `USB NOBAR` if memory-decode is clear or BAR0 is unusable.

## 4. Binary

`u1-xhci/run.sh` types `usb` on a boot whose QEMU line includes
`-device qemu-xhci,id=xhci,p2=2,p3=3` (not the default 4+4). The printed
BAR must equal QEMU `info pci` BAR0. `CAPLENGTH`, `DBOFF` and `RTSOFF`
must be non-zero and land inside that BAR. `HCIVERSION` must be a
documented xHCI BCD (`0100` / `0110` / `0120`). Printed `PORTS` must
equal the harness `p2+p3`. `USBCMD` Run/Stop must still be clear.
Negative control: plain `-M pc` prints `USB NONE` and no capability line.
`u0-xhci` still passes: USB0's device line is unchanged.

Anti-vacuity is the non-default port count. A kernel that printed
qemu-xhci's default `PORTS 08` without reading `HCSPARAMS1` fails.

## 5. What this is not

Not a host-controller bring-up, not a transfer ring, not a HID report,
not `pciWrite32`, and not a change to the `pci` command's line format
(m5-pci goldens are untouched). USB2 is the next rung.
