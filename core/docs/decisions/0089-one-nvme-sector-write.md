# ADR-0089 — One NVMe I/O-queue sector write

**Status:** accepted, implemented (`core/kernel/nvme.dart`,
`core/tests/conformance/nvm4`)
**Date:** 2026-08-30
**Depends on** NVM0 (ADR-0071), NVM1 (ADR-0074), NVM2 (ADR-0087),
NVM3 (ADR-0088), ADR-0065 (`pciWrite32`) and ADR-0044 (`Volatile<T>`
MMIO).
**Implements** the write leftover named in ADR-0088 / GAP-0314.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), FAT-on-NVMe, or a change
to the IDE / AHCI paths.
**Number:** 0089 — 0088 is one sector read. Do not reuse 0088.

---

## 1. The question

NVM3 created an I/O queue pair and DMA-read one planted sector at
LBA 7. A printed DATA line can no longer be a canned string. A
sector still can, on the way out: nothing had issued NVM Write
(opcode 01h). Until that lands, the only sector this kernel *puts*
on a disk is ATA PIO.

## 2. The decision

1. **Same file, still zero `.bss`.** `nvme.dart` grows a fourth
   command. The same six `allocFrame()` calls hold the admin SQ,
   admin CQ, Identify buffer, I/O SQ, I/O CQ and the 512-byte
   sector. Identity map: physical address equals virtual address.
   `part 'nvme.dart'` stays after `usb.dart` and before `ahci.dart`,
   so D7 keeps last place (ADR-0033 §6.4).
2. **`nvme wr`, not a boot line and not a change to `nvme`,
   `nvme id`, or `nvme rd`.** NVM0/NVM1 still only print BDF, BAR,
   CAP and VS. NVM2 still only Identifies. NVM3 still only reads
   LBA 7. Longest-first dispatch, same as `ahci read`. Not in
   `help`. `nvmeInit()` still prints nothing.
3. **Reuse the NVM3 I/O pair.** Identify, then Create I/O CQ (05h)
   + Create I/O SQ (01h) for QID 1. The I/O queues are four entries
   (`nvmeIoQid4`) so NVM Read of the plant plus NVM Write do not
   wrap the phase bit. `nvme rd` still programmes two-entry I/O
   queues.
4. **The bytes are a plant, not a kernel constant.** The harness
   writes 16 random bytes at LBA 7 at test time. `nvme wr` DMA-reads
   that sector into the PRP frame, then issues NVM Write (01h) of
   the same PRP to LBA 11, NSID=1, NLB=0. After QEMU exits, the
   harness reads LBA 11 from the raw image and requires those bytes.
5. **Completion is the CQ phase bit.** Same `Volatile<u32>` poll
   and 2²¹ bound as NVM3 (GAP-0071).
6. **IDE and AHCI are untouched.** `ata.dart` and `ahci.dart` are
   not imported, not called, and not edited. `m6-disk` stays the
   PIO proof. FAT and the loader stay on ATA PIO.

## 3. The printed lines

```
NVME WR 0000000B DATA <16 planted bytes as hex>
```

Absent device: `NVME NONE`, and no `NVME WR ` line.
Timeout: `NVME TMO`. Non-zero CQ status: `NVME STS <field>`.
No frame: `NVME NOFRM`. BME did not stick: `NVME CMD STUCK`.

## 4. Binary

`nvm4/run.sh` types `nvme wr` on the same QEMU attach NVM0 used,
except the backing image has 16 random bytes at LBA 7 that do not
appear in `nvme.dart`, and a different decoy at LBA 11. After QEMU
exits, LBA 11 on the raw image must equal the plant. A second image
with a different plant must carry the second plant at LBA 11, not
the first. Anti-vacuity: info pci contains `1b36:0010`, the plant is
not all zeros, LBA 10 and LBA 12 still hold their decoys, and NVM
Write (01h) is named in the driver. Negative control: plain `-M pc`
prints `NVME NONE` and no `NVME WR ` line. `nvm0`–`nvm3` still pass.

## 5. What this is not

Not FAT-on-NVMe, not MSI-X, not uncached MMIO (GAP-0071), and not a
change to `nvme`, `nvme id`, `nvme rd`, or `m6-disk`.
