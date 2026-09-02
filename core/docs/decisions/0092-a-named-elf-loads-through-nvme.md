# ADR-0092 — A named ELF loads through the NVMe I/O pair

**Status:** accepted, implemented (`core/kernel/elf.dart`,
`core/tests/conformance/nvm6`)
**Date:** 2026-08-30
**Depends on** NVM5 (ADR-0090), ADR-0014 (the loader), ADR-0018
(FAT16 names) and ADR-0034 (one launch path).
**Implements** the loader leftover named in ADR-0090 / GAP-0314.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), a block layer, or a
change to `m6-disk` / AHCI.
**Number:** 0092 — 0090 is FAT-on-NVMe. 0091 is G7 (`virtio-gpu-pci`
without VGA). Do not reuse 0090 or 0091.

---

## 1. The question

NVM5 put FAT sector I/O on the NVMe I/O pair. `cat` of a planted
file worked on a volume attached as `-device nvme` with no IDE.
`run` / `spawn` of a named ELF still called `ataReadInto` twice
(`elfReadHeader`, `elfReadSectors`). A program sitting on that
same volume could not load: FAT found the file, then the loader
asked ATA for sectors a machine without IDE does not have.

## 2. The decision

1. **Same door as FAT.** `elfDiskRead` is `fatDiskRead`.
   `elfReadHeader` and `elfReadSectors` call it. `nvmeFind` still
   chooses: class `01/08/02` present → `nvmeIoRead` on the I/O pair
   NVM5 already set up; absent → `ataReadInto`. A present NVMe that
   fails to set up is a disk error, not a silent IDE fallback.
   nvm6 attaches the FAT image with `if=none` and no IDE drive, so
   ATA cannot satisfy the plant.
2. **Existing launch path.** `run <name>` and `proc spawn <name>`
   and syscall 26 (`spawn`) already go through `elfLoadFile` →
   `elfReadSectors`. They do not grow a second path. No new
   syscall. 11 stays `fdwait`. 26 stays `spawn`. Not in `help`.
3. **Still zero new `.bss`.** The session pointer and the device
   choice stay in `fat_store` words 30 and 31. `wmeventStore` stays
   last (ADR-0033 §6.4).
4. **The bytes are a plant, not a kernel constant.** The harness
   compiles a program whose write string and exit code are derived
   at test time, writes it onto a FAT16 volume as `PROG.ELF` with a
   hole in the chain (cluster 2, then 20…), and `run prog.elf`
   must print that string and that exit. A contiguous reader after
   the first cluster, or an LBA-7 reader, cannot pass. A second
   image must print its own plant, not the first.
5. **ATA-only machines stay on PIO.** `m10-elf`, `m11-proc` and
   `m14-fat` have no NVMe, so `fatDiskPick` still chooses
   `ataReadInto`. Their goldens do not move.

## 3. The printed lines

```
FAT NVME
FS OPEN PROG    .ELF ATTR .. CLUS 0002 SIZE ........
ELF FILE PROG    .ELF IMAGE ........ BYTES ........
...
USER WRITE NVM6 <32 hex>
USER EXIT CODE <16 hex of the derived status> SYSCALLS ........ REFUSALS 00000000
```

Absent NVMe and absent ATA: `FS ERR 01` (boot sector unreadable),
no `FAT NVME`, no `ELF FILE`, no `USER WRITE NVM6`.

## 4. Binary

`nvm6/run.sh` types `run prog.elf` against a FAT16 image attached
as `-device nvme`. Printed write bytes and exit code must equal
the host plant. A second image must print the second plant.
Anti-vacuity: info pci contains `1b36:0010`; the plant is not in
`elf.dart`, `fat.dart` or `nvme.dart`; `elfDiskRead` names
`fatDiskRead`; `elfReadSectors` does not call `ataReadInto`; the
second cluster is not LBA 7. Negative control: plain `-M pc` (no
NVMe, no IDE disk) prints `FS ERR 01` and no plant. `nvm0`–`nvm5`
and both AHCI harnesses still pass. `m10-elf` / `m11-proc` /
`m14-fat` stay on ATA PIO.

## 5. What this is not

Not uncached MMIO (GAP-0071), not a block layer (`blk.dart`),
not MSI-X, and not a change to `nvme`, `nvme id`, `nvme rd`,
`nvme wr`, or `m6-disk`.
