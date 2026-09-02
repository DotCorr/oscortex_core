# ADR-0077 — One AHCI sector read

**Status:** accepted, implemented (`core/kernel/ahci.dart`,
`core/tests/conformance/a1-ahci-read/run.sh`)
**Date:** 2026-08-30
**Depends on ADR-0069** (AHCI HBA probe), **ADR-0065** (`pciWrite32`),
and **ADR-0044** (`Volatile<T>` MMIO).
**Implements** the first sector on the AHCI path in
`docs/design/storage.md` §2.2.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), DMA writes, NCQ, or a
change to the IDE path.
**Number:** 0077 — 0074 is already claimed (G3 virtqueue, NVM1, N3).
A0 is 0069.

---

## 1. The question

A0 found class `01/06/01` / `8086:2922` and printed ABAR and CAP. The
leftover was a command list, a port start, and one `READ DMA EXT`.
Until that lands, ATA PIO is still the only path that moves a sector.

## 2. The decision

1. **Same file, `core/kernel/ahci.dart`.** Zero donated `.bss`. One
   `allocFrame()` holds the command list (offset 0), Received FIS
   (1024), command table (2048) and the 512-byte sector (2560).
   Identity map: physical address equals virtual address.
   `part 'ahci.dart'` stays after `nvme.dart` and before `wmevent.dart`.
2. **`ahci read`, not a boot line and not a change to `ahci`.** A0
   still only prints BDF and CAP. Longest-first dispatch, same as
   `nic send`. Not in `help`. `ahciInit()` still prints nothing.
3. **Bus-master is a write.** `pciWrite32` ORs MEM|BME into the
   command register and refuses `AHCI CMD STUCK` if bit 2 does not
   stick. GHC.AE is set. The first implemented port with
   `PxSSTS.DET==3`, `IPM==1` and `PxSIG==0x00000101` is started.
4. **Completion is `PxCI` with `PxIS.TFES` on every iteration.** Both
   loads are `Volatile<u32>` (GAP-0071). A loop that only watches
   `PxCI` hangs on a task-file error. Bound is 2²¹, same as `ataWait`.
5. **The binary is a plant, not a golden.** LBA 7. The harness writes
   16 random bytes there at test time. The kernel prints
   `AHCI READ 00000007 PRDBC <n> DATA <32 hex>`. PRDBC must be 512
   (the HBA wrote it). Sectors 0, 6 and 8 hold different decoys, so
   an LBA off-by-one cannot pass.
6. **IDE is untouched.** `ata.dart` is not imported, not called, and
   not edited. `m6-disk` stays the PIO proof. This is a second path.

## 3. The printed lines

```
AHCI READ 00000007 PRDBC 00000200 DATA <16 planted bytes as hex>
```

Absent device: `AHCI NONE`. No port: `AHCI NOPORT`. Timeout: `AHCI TMO`.
Task-file error: `AHCI TFES <PxTFD>`. No frame: `AHCI NOFRM`. BME
did not stick: `AHCI CMD STUCK`.

## 4. Binary

`a1-ahci-read/run.sh` types `ahci read` on a boot whose QEMU line
includes `-device ahci` and a disk on `ahci.0` (`if=none`) whose LBA 7
was planted by the harness. Printed DATA must equal the plant.
PRDBC must be `00000200`. Anti-vacuity: info pci contains `8086:2922`,
the plant is not all zeros and does not appear in `ahci.dart`.
Negative control: plain `-M pc` prints `AHCI NONE` and no READ line.

## 5. What this is not

Not a write, not NCQ, not uncached MMIO (GAP-0071 item 1 is still
open; Volatile only stops the compiler from hoisting), not a FAT
path, and not a change to `ahci` or to `m6-disk`.
