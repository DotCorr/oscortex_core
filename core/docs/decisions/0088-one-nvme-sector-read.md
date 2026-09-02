# ADR-0088 — One NVMe I/O-queue sector read

**Status:** accepted, implemented (`core/kernel/nvme.dart`,
`core/tests/conformance/nvm3`)
**Date:** 2026-08-30
**Depends on** NVM0 (ADR-0071), NVM1 (ADR-0074), NVM2 (ADR-0087),
ADR-0065 (`pciWrite32`) and ADR-0044 (`Volatile<T>` MMIO).
**Implements** the I/O-queue leftover named in ADR-0087 / GAP-0314.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), an NVMe write, or a change
to the IDE / AHCI paths.
**Number:** 0088 — 0087 is Identify Controller. Do not reuse 0087.

---

## 1. The question

NVM2 enabled an admin pair and DMA-read Identify Controller. A printed
serial can no longer be a canned string. A sector still can: nothing
had created an I/O completion queue, an I/O submission queue, or
issued NVM Read (opcode 02h). Until that lands, the only sector this
kernel moves is ATA PIO or AHCI.

## 2. The decision

1. **Same file, still zero `.bss`.** `nvme.dart` grows a third
   command. Six `allocFrame()` calls hold the admin SQ, admin CQ,
   Identify buffer, I/O SQ, I/O CQ and the 512-byte sector. Identity
   map: physical address equals virtual address.
   `part 'nvme.dart'` stays after `usb.dart` and before `ahci.dart`,
   so D7 keeps last place (ADR-0033 §6.4).
2. **`nvme rd`, not a boot line and not a change to `nvme` or
   `nvme id`.** NVM0/NVM1 still only print BDF, BAR, CAP and VS.
   NVM2 still only Identifies. Longest-first dispatch, same as
   `ahci read`. Not in `help`. `nvmeInit()` still prints nothing.
3. **Identify first, then the I/O pair.** The admin queue is
   programmed with four entries (AQA `0x00030003`) so Identify +
   Create I/O CQ (05h) + Create I/O SQ (01h) do not wrap the phase
   bit. QID 1, two entries, PC=1, IEN=0. Then one NVM Read of LBA 7,
   NSID=1, NLB=0, PRP1 = the sector frame.
4. **Completion is the CQ phase bit.** Admin slots 0..2 and I/O slot
   0 start phase 0 because the frames were zeroed. The controller
   writes phase 1. The load is `Volatile<u32>` (GAP-0071). Bound is
   2²¹, same as `ataWait`.
5. **The binary is a plant, not a golden.** LBA 7. The harness writes
   16 random bytes there at test time. The kernel prints
   `NVME RD 00000007 DATA <32 hex>`. Those bytes come from the
   sector frame, not from Identify. Sectors 0, 6 and 8 hold different
   decoys, so an LBA off-by-one cannot pass. A second image with a
   different plant must print that plant, not the first.
6. **IDE and AHCI are untouched.** `ata.dart` and `ahci.dart` are not
   imported, not called, and not edited. `m6-disk` stays the PIO
   proof. `a1-ahci-read` stays the AHCI proof.

## 3. The printed lines

```
NVME RD 00000007 DATA <16 planted bytes as hex>
```

Absent device: `NVME NONE`, and no `NVME RD ` line.
Timeout: `NVME TMO`. Non-zero CQ status: `NVME STS <field>`.
No frame: `NVME NOFRM`. BME did not stick: `NVME CMD STUCK`.

## 4. Binary

`nvm3/run.sh` types `nvme rd` on the same QEMU attach NVM0 used,
except the backing image has 16 random bytes at LBA 7 that do not
appear in `nvme.dart`. Printed DATA must equal that plant. A second
boot with a different plant must print the second plant, not the
first. Anti-vacuity: info pci contains `1b36:0010`, the plant is not
all zeros, and Create CQ / Create SQ / NVM Read (05h / 01h / 02h) are
named in the driver. Negative control: plain `-M pc` prints
`NVME NONE` and no `NVME RD ` line. `nvm0`, `nvm1` and `nvm2` still
pass.

## 5. What this is not

Not a write, not MSI-X, not uncached MMIO (GAP-0071), not a FAT path,
and not a change to `nvme`, `nvme id`, or `m6-disk`.
