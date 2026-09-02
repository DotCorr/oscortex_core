# ADR-0137 — Storage class is the FAT root

**Status:** accepted, implemented (`core/kernel/fat.dart`,
`core/kernel/ahci.dart`, `core/tests/conformance/nvm-root`)
**Date:** 2026-08-30
**Depends on** NVM5/NVM6 (ADR-0090, ADR-0092), A0/A1 (ADR-0069,
ADR-0077), ADR-0018 (FAT16) and ADR-0034 (one launch path).
**Implements** the leftover after NVM6: sit-in/boot still treated
ATA PIO as the only non-NVMe root. AHCI could find an HBA and read
LBA 7; FAT never used it.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), a block layer, NCQ, or
a change to `m6-disk`.
**Number:** 0137 — 0136 is panel hex. Do not reuse 0136.
No new syscall. 11 stays `fdwait`. Not in `help`.

---

## 1. The question

NVM6 made `elfDiskRead` the same door as FAT. A named ELF on
`-device nvme` loaded. A1 could DMA-read one planted sector on
class `01/06/01`. Sit-in and every IDE harness still went through
`ataReadInto` whenever NVMe was absent — even when an AHCI HBA
was the disk. Two backends, one filesystem, and only one of them
was a root.

Majority hardware is a **class**, not a SKU. Class `01/08/02` is
NVMe. Class `01/06/01` is AHCI. QEMU's `-device nvme` and
`-device ahci` are stand-ins. A Dell (or any other) vendor:device
is not the success condition.

## 2. The decision

1. **Same door, three arms.** `fatDiskPick` chooses by class:
   `nvmeFind` (01/08/02) → `nvmeIoRead`; else `ahciFind`
   (01/06/01) → `ahciIoRead`; else `ataReadInto`. `elfDiskRead`
   stays `fatDiskRead`. `ls` / `run` / `spawn` do not grow a
   second path. A present controller that fails to set up is a
   disk error, not a silent IDE fallback.
2. **AHCI I/O is persistent, arbitrary LBA.** `ahciIoSetup` keeps
   one `allocFrame` (list + FIS + table + bounce) and the BAR /
   port offset at 3072/3080. `ahciBuildIo` is not A1's LBA 7.
   `ahciIoWrite` is WRITE DMA EXT (0x35) with header W, so an
   AHCI root does not write through empty IDE. `ahci read` is
   unchanged.
3. **One print per DMA pick.** `FAT NVME` or `FAT AHCI` once.
   ATA prints nothing. `fat_store` stays 1824. Word 31 holds
   whichever session won. `wmeventStore` stays last. No new
   `.bss`. No help line.
4. **The bytes are a plant.** The harness compiles a program
   whose write string and exit are derived at test time, writes
   it onto one FAT16 volume with a hole in the chain, and
   `ls` + `run prog.elf` must print that list and that write
   through **both** backends. Either backend off misses that
   path.

## 3. The printed lines

NVMe boot:

```
FAT NVME
FS ENT 00 NAME PROG    .ELF ...
USER WRITE NVM6 <32 hex>
USER EXIT CODE <16 hex of the derived status> ...
```

AHCI boot: `FAT AHCI` instead of `FAT NVME`, same `FS ENT` and
same `USER WRITE` / `USER EXIT`.

Both off: `FS ERR 01`, no `FAT NVME`, no `FAT AHCI`, no plant.

## 4. Binary

`nvm-root/run.sh` attaches the same image as `-device nvme` and
as `-device ahci` + `ide-hd` on `ahci.0` (`if=none`, no IDE).
Printed write bytes and exit must equal the host plant on both.
Anti-vacuity: info pci judges **class** (`Class 0108` / `Class
0106`), not a laptop vendor:device; the plant is not in
`fat.dart` / `nvme.dart` / `ahci.dart` / `elf.dart`;
`fatDiskRead` names `nvmeIoRead`, `ahciIoRead`, and
`ataReadInto`. Negative: plain `-M pc` is `FS ERR 01`.
NVMe-only must not print `FAT AHCI`. AHCI-only must not print
`FAT NVME`. `nvm0`–`nvm6` and A0/A1 stay the proofs they were.
`m6-disk` / `m14-fat` stay on ATA PIO.

## 5. What this is not

Not uncached MMIO (GAP-0071). Not a block layer (`blk.dart`).
Not MSI-X. Not a SKU list. Not a change to `nvme`, `nvme id`,
`nvme rd`, `nvme wr`, `ahci`, `ahci read`, or `m6-disk`. Not a
Dell (or any other OEM) identity. A later metal smoke test may
attach a real disk; class is still the match.
