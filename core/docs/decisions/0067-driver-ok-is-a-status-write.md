# ADR-0067 — DRIVER_OK is a status-byte write

**Status:** accepted, implemented, verified (`tests/conformance/g2-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G2 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (COMMON_CFG walk + §3.1.1 sequence),
`core/tests/conformance/g2-virtgpu/run.sh`
**Depends on** ADR-0059 (the device is found) and ADR-0065 (bus-master is on).
**Does not close** a virtqueue (G3), a pixel (G4), or any of G5–G7.
**Number:** 0067 — 0065 is G1's bus-master write; 0066 is N2 ARP;
USB1 xHCI is 0068.

---

## 1. The question

G1 set command bit 2. A VirtIO device still will not process a virtqueue
until it has walked VIRTIO §3.1.1 and the driver has written `DRIVER_OK`.
G2 is that walk: reset, acknowledge, features, `FEATURES_OK`, re-read,
`DRIVER_OK`. It is not a pixel and it is not Mesa.

## 2. The decision

1. **The sequence runs from the `virtgpu` command, after G1's bus-master
   write.** `virtgpuInit` stays a no-op. An absent device still prints
   `VIRTIO NONE` and touches neither configuration space nor the BAR.
2. **COMMON_CFG is found by walking the vendor capabilities**, reading
   `cap.bar` and `cap.offset`. The BAR index is not hardcoded:
   `virtio-vga` and `virtio-gpu-pci` disagree (gpu.md §3.1).
3. **Access widths follow VIRTIO §4.1.3.1.** `device_status` is a byte
   at +0x14; `num_queues` is a 16-bit load at +0x12; feature words are
   32-bit. A load that is too wide is a neighbour's padding (gpu.md §3.8).
   MMIO is `Volatile<T>` (ADR-0044).
4. **Reset is write 0, then poll until a read returns 0**
   (§4.1.4.3.2). Every later status write is a read-modify-write OR
   (§2.1.1). Numeric order is not temporal order: `FEATURES_OK` (8)
   is written before `DRIVER_OK` (4).
5. **The driver accepts `VIRTIO_F_VERSION_1` (bit 32) and nothing else.**
   Indirect descriptors, event-idx and packed rings stay off.
6. **Print the offered feature words, `num_queues`, and the final
   status byte.** If `FEATURES_OK` does not stick, print
   `VIRTIO FEATOK CLEAR` and do not write `DRIVER_OK`.
7. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays 2511
   bytes. D7 still owns the last `@bss` block. No virtqueue.

`DRIVER_OK` does not leave VGA compatibility mode. `SET_SCANOUT` does
(VIRTIO §5.7.7), and that is G4. Sit-in / Bochs / `-vga std` keep
working on boots that never type the command, and `fb` still works
after it.

## 3. What this is not

It is not a virtqueue (G3), not a pixel (G4), not virgl, and not a
claim that the device has been told a mode. `queue_enable` is not
written. The common-configuration region is touched; the notify BAR
is not.

## 4. Binary

`g2-virtgpu/run.sh`:

* boot `-vga virtio`, type `virtgpu` then `fb`;
* require `VIRTIO STATUS 0F`, offered feature bit 32 set, `num_queues`
  ≥ 2, and both offered-feature words not zero;
* `FAILED` and `DEVICE_NEEDS_RESET` clear;
* `fb` still reports `MODE 0320x0258x20 OK` on that boot;
* the same kernel on `-vga std` prints `VIRTIO NONE`, no `FEAT` /
  `QUEUES` / `STATUS` line, and `fb` still works.

Anti-vacuity is the two feature words. The source must write
`FEATURES_OK` before `DRIVER_OK` and must carry the refusal string
between those writes — a reversed pair is what the device rejects.
