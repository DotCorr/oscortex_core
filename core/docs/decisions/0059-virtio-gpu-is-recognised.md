# ADR-0059 — The VirtIO GPU is recognised, and that is all G0 claims

**Status:** accepted, implemented, verified (`tests/conformance/g0-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G0 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (new), `core/kernel/kmain.dart` (`part` + silent
`virtgpuInit`), `core/kernel/shell.dart` (hidden `virtgpu` command, no help line),
`core/tests/conformance/g0-virtgpu/run.sh`
**Does not close** GAP-0067 item 2 (config writes / bus-master — that is G1), item 1
(nothing is retained), or any of G1–G7.
**Number:** 0059, not 0055 — D7 already took 0055 (`0055-a-click-reaches-the-client.md`);
0056 is chrome, 0057 is A1, 0058 is N0.

---

## 1. The question

`docs/design/gpu.md` is honest about real GPUs: Intel, AMD and NVIDIA are not
reachable from this kernel (signed firmware + Mesa). The reachable path is
VirtIO-GPU 2D, and the first rung on that ladder is **recognise the device**.

Two facts were already measured with no kernel change (`gpu.md` §0.1):

* `-vga virtio` / `-device virtio-vga` is class `03/00`. `fbFindVgaBar` finds
  it and the existing Bochs dispi path scanouts. That is a migration bridge,
  not a VirtIO driver.
* `-device virtio-gpu-pci` is class `03/80`. `fb` prints `FB NONE`. Claiming
  a framebuffer there without driving the device would be a lie.

G0 is the first of those that is still unmeasured from *this* kernel: walk
the PCI capability list, print the five VirtIO vendor capabilities, and
resolve each one against the BAR QEMU assigned.

## 2. The decision

1. **A new file, `core/kernel/virtgpu.dart`.** The e1000 work owns PCI for
   its own reasons. This file uses `pciRead32` and nothing else from
   `pci.dart`. It does not add `pciWrite32`. It donates no `.bss`.
2. **Discovery is vendor `0x1AF4` device `0x1050`**, not class `03/00`.
   Class-based discovery is `fb.dart`'s job and would miss `virtio-gpu-pci`
   when G7 wants it.
3. **The capability walk is the product.** For each vendor capability
   (`id = 0x09`) the kernel prints `cfg_type`, BAR index, offset, length,
   the resolved `BAR_base + offset`, and — for `NOTIFY_CFG` — 
   `notify_off_multiplier`. 64-bit BARs are read as a pair; a non-zero
   upper dword is refused (the identity map stops at 4 GiB).
4. **Init is a no-op.** `virtgpuInit` prints nothing and programs nothing,
   present or absent. A boot-time `SET_SCANOUT` would leave VGA
   compatibility mode (VIRTIO §5.7.7) and break sit-in / d2-compositor /
   every `-vga std` golden. The hidden `virtgpu` command is the only
   printer. An absent device prints `VIRTIO NONE`.
5. **No help line, no syscall, not last in `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 owns the last `@bss` block (`wmeventStore`).

## 3. What this is not

It is not bus-master (G1), not `DRIVER_OK` (G2), not a virtqueue (G3), not
a pixel (G4), not virgl, and not a claim that `virtio-gpu-pci` has a
linear framebuffer. Feature bits are not printed: they live in the common
configuration MMIO region, and reading that is G2.

## 4. Binary

`g0-virtgpu/run.sh`:

* boot `-vga virtio`, type `virtgpu` then `fb`;
* parse QEMU `info pci` for `1af4:1050` BAR bases;
* require five vendor capabilities, `cfg_type` 1–5 exactly once,
  `notify_off_multiplier = 4`, every `AT` inside the named BAR;
* `fb` still reports `MODE 0320x0258x20 OK` on that boot;
* the same kernel on `-vga std` prints `VIRTIO NONE`, no capability
  table, and `fb` still works.

Anti-vacuity is the five-cap floor. The negative control is the std-VGA
boot. The coexistence check is `fb` on both machines.
