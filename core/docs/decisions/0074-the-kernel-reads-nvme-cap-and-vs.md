# ADR-0074 — The kernel reads NVMe CAP and VS

**Status:** accepted, implemented (`core/kernel/nvme.dart`,
`core/tests/conformance/nvm1`)
**Date:** 2026-08-30
**Depends on** NVM0 (ADR-0071) and ADR-0044 (`Volatile<T>` MMIO).
**Implements** the first *device* read named as leftover in ADR-0071.
**Does not close** GAP-0071 (MMIO is still cacheable), an admin queue,
Identify, or a sector.
**Number:** 0074 — 0073 is USB2 HID. NVM0 is 0071.

---

## 1. The question

NVM0 found class `01/08/02` and printed BDF + BAR0. A printed BDF can
be a walk. CAP at BAR0+0 and VS at BAR0+8 live in the controller's
MMIO, not in configuration space. A printed CAP that equals QEMU `xp`
of that BAR, and a VS whose major is a documented NVM Express version,
cannot be a walk.

## 2. The decision

1. **Same file, still zero `.bss`.** `nvme.dart` grows the `nvme`
   command. CAP, VS, MQES and TO are locals. `part 'nvme.dart'` stays
   after `usb.dart` and before `ahci.dart`, so D7 keeps last place
   (ADR-0033 §6.4).
2. **CAP is two `Volatile<u32>` loads at BAR0+0 / BAR0+4; VS is one
   load at BAR0+8** [NVM Express Base, Controller Properties].
   Memory-decode is checked and not written. NVM1 does not write CC.EN
   and does not create a queue.
3. **The NVM0 lines are unchanged.** `NVME <bdf> …` and `NVME BAR
   <addr>` stay so `nvm0` still passes. NVM1 adds one line.
4. **The print is still the hidden `nvme` command.** `nvmeInit()` stays
   a no-op. An absent controller still prints `NVME NONE` and no CAP
   line. `nvme` is not in `help`.
5. **IDE is untouched.** `ata.dart` is not imported, not called, and
   not edited. `m6-disk` stays the proof that PIO still works.

## 3. The printed lines

```
NVME 00:04.0 1B36:0010 01/08/02
NVME BAR FEBF0000
NVME CAP 000000200F0107FF VS 00020000 MQES 07FF TO 0F
```

Absent device: `NVME NONE`, and no BDF / BAR / CAP line.
`NVME NOCMD` / `NVME NOBAR` if memory-decode is clear or BAR0 is
unusable.

## 4. Binary

`nvm1/run.sh` types `nvme` on the same QEMU attach NVM0 used
(`-device nvme,serial=foo,drive=nvme0`). The printed BAR must equal
QEMU `info pci` BAR0 for `1b36:0010`. Printed CAP and VS must equal
QEMU `xp /3xw` of that BAR. MQES and TO must equal the fields in that
CAP. VS major must be a documented NVM Express version (`0001` /
`0002`). CAP.CSS bit 0 (NVM command set) must be set. CAP of 0 is a
fail. Negative control: plain `-M pc` prints `NVME NONE` and no CAP
line. `nvm0` still passes: NVM0's device and BAR lines are unchanged.

Anti-vacuity is the `xp` match. A canned CAP cannot equal a live dump
of a BAR QEMU assigned.

## 5. What this is not

Not an admin queue, not Identify (opcode 06h), not an I/O queue, not
a sector, not `pciWrite32`, and not a change to the `pci` command's
line format (m5-pci goldens are untouched). Identify is the first
device read that needs a queue.
