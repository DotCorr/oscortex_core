# ADR-0090 — FAT sectors move through the NVMe I/O queue

**Status:** accepted, implemented (`core/kernel/fat.dart`,
`core/kernel/nvme.dart`, `core/tests/conformance/nvm5`)
**Date:** 2026-08-30
**Depends on** NVM0–NVM4 (ADR-0071, ADR-0074, ADR-0087, ADR-0088,
ADR-0089), ADR-0018 (FAT16), ADR-0020 (the write path), ADR-0065
(`pciWrite32`) and ADR-0044 (`Volatile<T>` MMIO).
**Implements** the FAT leftover named in ADR-0089 / GAP-0314.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), the ELF loader's ATA PIO
path, or a change to `m6-disk` / AHCI.
**Number:** 0090 — 0089 is one sector write. Do not reuse 0089.
0086 is G6 (virtio-gpu), in flight elsewhere.

---

## 1. The question

NVM4 can DMA-read a planted sector and DMA-write it so the host image
is the judge. FAT and `open`/`read`/`cat` still called `ataReadInto`
and `ataWriteFrom`. A volume sitting on QEMU's `-device nvme` was
invisible to every file operation. Until that lands, "the disk is
NVMe" is a probe and two test commands, not a filesystem.

## 2. The decision

1. **Existing file ops, switched at the sector door.**
   `fatReadCached` / `fatReadSector` / `fatWriteSector` go through
   `fatDiskRead` / a write arm in `fatWriteSector`. `cat`, `fs`,
   `ls`, `open`, and `read` do not grow a second path. No new
   syscall. 11 stays `fdwait`. Not in `help`.
2. **NVMe if the controller is there, otherwise ATA PIO.**
   `fatDiskPick` calls `nvmeFind`. Class `01/08/02` present: set up
   one I/O pair (`nvmeIoSetup`) and keep it. Absent: `ataReadInto` /
   `ataWriteFrom` exactly as before. A present NVMe that fails to
   set up is a disk error, not a silent IDE fallback — nvm5 attaches
   the FAT image with `if=none` and no IDE drive, so ATA cannot
   satisfy the plant.
3. **Still zero new `.bss`.** Queues and the bounce buffer are six
   `allocFrame()` calls. The session pointer and the device choice
   live in two spare `fat_store` words (30 and 31). `fat_store`
   stays 1824 bytes. `part 'nvme.dart'` stays after `usb.dart` and
   before `ahci.dart`. `wmeventStore` stays last (ADR-0033 §6.4).
4. **Arbitrary LBA, not 7 and 11.** `nvmeBuildRead` / `nvmeBuildWrite`
   stay hardcoded for NVM3/NVM4. FAT uses `nvmeBuildIo` +
   `nvmeIoRead` / `nvmeIoWrite` on a 64-entry I/O pair. Completion
   is still the CQ phase bit (`Volatile<u32>`, 2²¹ bound).
5. **The bytes are a plant, not a kernel constant.** The harness
   writes a FAT16 volume at test time. `PLANT.TXT` is two clusters
   with a hole: cluster 2 holds a filler, cluster 20 holds 16 random
   bytes. `cat plant.txt` must print both, in that order. An LBA-7
   reader and a contiguous reader both fail. A second image must
   print its own plant, not the first.
6. **One print, and only on the NVMe path.** `FAT NVME` once, when
   the I/O pair comes up. ATA prints nothing, so m14's golden does
   not move. `ataWriteFrom(lba, src)` stays inside `fatWriteSector`
   so m16's structural grep still sees the one PIO write site.

## 3. The printed lines

```
FAT NVME
FS OPEN PLANT   .TXT ATTR .. CLUS 0002 SIZE 00000210
...
FS CAT PLANT   .TXT BYTES 00000210 CLUSTERS 0002
<512 filler bytes><16 planted bytes>
FS CAT END 00000210
```

Absent NVMe and absent ATA: `FS ERR 01` (boot sector unreadable),
and no `FAT NVME` line.

## 4. Binary

`nvm5/run.sh` types `cat plant.txt` against a FAT16 image attached
as `-device nvme`. Printed file bytes must equal the host plant.
A second image must print the second plant. Anti-vacuity: info pci
contains `1b36:0010`; the plant is not in `fat.dart` or `nvme.dart`;
`fatDiskRead` names both `nvmeIoRead` and `ataReadInto`; the second
cluster is not LBA 7. Negative control: plain `-M pc` (no NVMe, no
IDE disk) prints `FS ERR 01` and no `FAT NVME`. `nvm0`–`nvm4` and
both AHCI harnesses still pass. `m6-disk` / `m14-fat` / `m15` /
`m16` stay on ATA PIO.

## 5. What this is not

Not uncached MMIO (GAP-0071), not the ELF loader on NVMe
(`elf.dart` still calls `ataReadInto`), not MSI-X, and not a
change to `nvme`, `nvme id`, `nvme rd`, `nvme wr`, or `m6-disk`.
