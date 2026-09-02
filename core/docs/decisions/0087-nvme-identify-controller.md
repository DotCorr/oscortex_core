# ADR-0087 — One NVMe Identify Controller command

**Status:** accepted, implemented (`core/kernel/nvme.dart`,
`core/tests/conformance/nvm2`)
**Date:** 2026-08-30
**Depends on** NVM0 (ADR-0071), NVM1 (ADR-0074), ADR-0065 (`pciWrite32`)
and ADR-0044 (`Volatile<T>` MMIO).
**Implements** the Identify leftover named in ADR-0074.
**Does not close** GAP-0071 (MMIO is still cacheable; the poll is
`Volatile` so it cannot hoist under QEMU), an I/O queue, or a sector.
**Number:** 0087 — 0086 is G6 virtio-gpu. NVM1 is 0074. Do not reuse
0074.

---

## 1. The question

NVM1 loaded CAP and VS through BAR0. Those are controller properties
the host can read without a queue. Identify Controller (admin opcode
06h, CNS=1) is the first device read that needs an admin submission
queue, an admin completion queue, CC.EN, and a DMA of 4096 bytes.
Until that lands, a printed serial can be a canned string.

## 2. The decision

1. **Same file, still zero `.bss`.** `nvme.dart` grows a second
   command. Three `allocFrame()` calls hold the admin SQ (page
   aligned), the admin CQ (page aligned) and the Identify buffer.
   Identity map: physical address equals virtual address.
   `part 'nvme.dart'` stays after `usb.dart` and before `ahci.dart`,
   so D7 keeps last place (ADR-0033 §6.4).
2. **`nvme id`, not a boot line and not a change to `nvme`.** NVM0
   and NVM1 still only print BDF, BAR, CAP and VS. Longest-first
   dispatch, same as `ahci read`. Not in `help`. `nvmeInit()` still
   prints nothing.
3. **Bus-master is a write.** `pciWrite32` ORs MEM|BME into the
   command register and refuses `NVME CMD STUCK` if bit 2 does not
   stick. INTMS is written all-ones so a completion interrupt is
   not the path. AQA programmes two-entry queues. ASQ/ACQ are the
   two frames. CC is `EN | IOSQES=6 | IOCQES=4`.
4. **Completion is the CQ phase bit.** Slot 0 starts phase 0 because
   the frame was zeroed. The controller writes phase 1. The load is
   `Volatile<u32>` (GAP-0071). Bound is 2²¹, same as `ataWait`.
5. **The binary is a derived serial, not a golden.** QEMU
   `-device nvme,serial=<8 hex>` is chosen at test time. The kernel
   prints the 20-byte SN field (space-padded) as 40 hex digits.
   VID must equal the PCI vendor QEMU reports for `1b36:0010`. NN
   must be at least 1. A canned SN cannot equal a serial the
   harness invented after the kernel was compiled.
6. **IDE is untouched.** `ata.dart` is not imported, not called, and
   not edited. `m6-disk` stays the PIO proof. `nvm0` and `nvm1` still
   type `nvme` only.

## 3. The printed lines

```
NVME ID SN <40 hex> VID 1B36 NN 00000001
```

Absent device: `NVME NONE`, and no `NVME ID ` line.
Timeout: `NVME TMO`. Non-zero CQ status: `NVME STS <field>`.
No frame: `NVME NOFRM`. BME did not stick: `NVME CMD STUCK`.

## 4. Binary

`nvm2/run.sh` types `nvme id` on the same QEMU attach NVM0 used,
except `serial=` is eight random hex digits the harness writes at
test time and that do not appear in `nvme.dart`. Printed SN must
equal that serial space-padded to 20 bytes. Printed VID must equal
the PCI vendor from QEMU `info pci`. NN must be ≥ 1. Anti-vacuity:
info pci contains `1b36:0010`, and the serial is not a constant in
the kernel. Negative control: plain `-M pc` prints `NVME NONE` and
no `NVME ID ` line. `nvm0` and `nvm1` still pass.

## 5. What this is not

Not an I/O queue, not a namespace Identify (CNS=0), not a sector,
not MSI-X, and not a change to `nvme` or to `m6-disk`. A sector
on this path needs an I/O queue after Identify.
