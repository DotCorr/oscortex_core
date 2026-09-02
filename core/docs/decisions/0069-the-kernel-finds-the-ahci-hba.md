# ADR-0069 — The kernel finds the AHCI HBA

**Status:** accepted, implemented (`core/kernel/ahci.dart`,
`core/tests/conformance/a0-ahci/run.sh`)
**Date:** 2026-08-30
**Depends on ADR-0008** (PCI configuration-space *read*) and ADR-0044
(`Volatile<T>` MMIO).
**Implements** the first rung of real-disk reach in
`docs/design/storage.md` §2.2 and `docs/design/portable-hardware.md` §6.4.
**Does not close** GAP-0071 (MMIO is still cacheable), a command list,
or a sector.
**Number:** 0069 — 0068 is USB1 xHCI. NVM0 is 0071; PORT4 BIOS is 0072.

---

## 1. The question

Every disk harness this kernel already has attaches PIIX3 IDE
(`storage.md` fact 15). That controller is not in a modern laptop.
AHCI is the first SATA path a real disk would use. The first thing
that can be true of AHCI without a command list, without DMA, and
without touching the IDE path is: **the kernel finds class `01/06/01`
(or the QEMU ICH9 id) and prints ABAR and CAP.**

## 2. The decision

1. **A new file, `core/kernel/ahci.dart`, `part of 'kmain.dart'`.** Zero
   donated `.bss`. `part 'ahci.dart'` sits after `nvme.dart` and before
   `wmevent.dart`, so D7 keeps last place (ADR-0033 §6.4).
2. **Discovery is class `01/06/01`**, the SATA AHCI prog-IF, or the
   QEMU ids `8086:2922` (ich9-ahci / `-device ahci`) and `1B36:0001`.
   A class-only match would claim vendor-specific SATA (`prog-IF 00`).
   The walk is bus 0; function 0, then 1..7 if the slot is
   multi-function (ICH9 on `-M q35` is `00:1f.2`). Helpers stay in
   this file, not in `pci.dart` (hot-files.md; NVM0 did the same).
3. **ABAR is BAR5, a configuration-space read.** CAP at ABAR+0 is a
   `Volatile<u32>` load. PORTS is `CAP.NP + 1`. Memory-decode is
   checked and not written. A0 does not write GHC, does not start a
   port, and does not build a command list.
4. **The print is a command, not a boot line.** The default machine
   has no AHCI. A boot-time `AHCI NONE` would sit in every session
   golden after `M1 END`. `ahci` is not in `help`. `ahciInit()` prints
   nothing.
5. **IDE is untouched.** `ata.dart` is not imported, not called, and
   not edited. `m6-disk` stays the proof that PIO still works. This
   is a second path.

## 3. The printed lines

```
AHCI 00:04.0 8086:2922 01/06/01
AHCI BAR FEBF1000 CAP C0141F05 PORTS 06
```

Absent device: `AHCI NONE`, and no BDF line and no `AHCI BAR` line.
`AHCI NOCMD` / `AHCI NOBAR` if memory-decode is clear or BAR5 is
unusable.

## 4. Binary

`a0-ahci/run.sh` types `ahci` on a boot whose QEMU line includes
`-device ahci` and a disk on `ahci.0` (`if=none`). The printed BDF,
vendor:device, and BAR5 must equal QEMU `info pci` for `8086:2922`.
Printed CAP must equal QEMU `xp` of that BAR. PORTS must equal
`CAP.NP + 1`. Anti-vacuity: that info pci must contain `8086:2922`,
and CAP must be non-zero. Negative control: plain `-M pc` prints
`AHCI NONE` and no BDF / BAR line, and info pci lacks `8086:2922`.

## 5. What this is not

Not a port start, not a command list, not a Register H2D FIS, not a
sector, not `pciWrite32`, and not a change to the `pci` command's
line format (m5-pci goldens are untouched). One sector read is the
leftover: stop the port, point `PxCLB`/`PxFB` at one frame, issue
`READ DMA EXT`, wait on `PxCI` while watching `PxIS.TFES`.
