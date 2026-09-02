# ADR-0071 — NVMe is recognised, and that is all NVM0 claims

**Status:** accepted, implemented (`core/kernel/nvme.dart`, `core/tests/conformance/nvm0`)
**Date:** 2026-08-30
**Depends on ADR-0008** (PCI configuration-space *read*).
**Does not close** GAP-0067 item 1 (nothing is retained), GAP-0071 (MMIO is still
cacheable), or any admin/I/O queue.
**Number:** 0071 — 0068 is USB1 xHCI; 0067 is G2. This file was one of
the 0068s. Sibling AHCI keeps its own helpers out of `pci.dart`; NVM0
does the same.

---

## 1. The question

A modern laptop disk is NVMe, class `01/08/02`. Every disk harness this kernel
already has attaches PIIX3 IDE (`storage.md` fact 15). That controller is not
in the machine PORT is aimed at. The first thing that can be true of NVMe
without a queue, without MSI, and without touching the IDE path is: **the
kernel finds the function and prints the BAR QEMU assigned.**

## 2. The decision

1. **A new file, `core/kernel/nvme.dart`, `part of 'kmain.dart'`.** Zero
   donated `.bss`. `part 'nvme.dart'` sits after `usb.dart` and before
   `wmevent.dart`, so D7 keeps last place (ADR-0033 §6.4).
2. **Discovery is class `01/08/02`**, the NVM Express I/O-controller
   prog-IF. A class-only match would claim NVMHCI (`01`) or Fabrics (`03`).
   The walk is bus 0 function 0, the same walk as `pciFindByClass`. The
   find and the 64-bit BAR0 reader live in this file, not in `pci.dart`.
3. **BAR0 is a configuration-space read.** QEMU's `-device nvme` is a
   64-bit MMIO BAR. A non-zero upper dword is refused (the identity map
   stops at 4 GiB). Memory-decode is checked and not written. NVM0 does
   not load CAP or VS, does not write CC.EN, and does not create a queue.
4. **The print is a command, not a boot line.** The default machine has
   no NVMe. A boot-time `NVME NONE` would sit in every session golden
   after `M1 END`. `nvme` is not in `help`. `nvmeInit()` prints nothing.
5. **IDE is untouched.** `ata.dart` is not imported, not called, and not
   edited. `m6-disk` stays the proof that PIO still works.

## 3. The printed lines

```
NVME 00:04.0 1B36:0010 01/08/02
NVME BAR FEBF0000
```

Absent device: `NVME NONE`, and no BDF line and no `NVME BAR` line.
`NVME NOCMD` / `NVME NOBAR` if memory-decode is clear or BAR0 is unusable.

## 4. Binary

`nvm0/run.sh` types `nvme` on a boot whose QEMU line includes
`-drive file=…,if=none,id=nvme0` and `-device nvme,serial=foo,drive=nvme0`.
The printed BDF and BAR0 must equal QEMU `info pci` for `1b36:0010`.
Anti-vacuity: that info pci must contain `1b36:0010`. Negative control:
plain `-M pc` prints `NVME NONE` and no BDF / BAR line, and info pci
lacks `1b36:0010`. `m6-disk` is required to still PASS on the same kernel.

## 5. What this is not

Not an admin queue, not Identify, not an I/O queue, not a sector, not
MSI-X, not `pciWrite32`, and not a change to the `pci` command's line
format (m5-pci goldens are untouched). CAP at BAR0+0 and VS at BAR0+8
landed as NVM1 (ADR-0074). Identify (admin opcode 06h) is the first
device read that needs a queue.
