# ADR-0065 — Bus mastering is a configuration-space write

**Status:** accepted, implemented, verified (`tests/conformance/g1-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G1 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/pci.dart` (`pciWrite32`), `core/kernel/virtgpu.dart`
(command-path bus-master + before/after print), `core/tests/conformance/g1-virtgpu/run.sh`
**Closes** GAP-0067 item 2 (configuration space is writable; bus-master can be set).
**Does not close** item 1 (nothing is retained), item 6 (the two port accesses
are still not atomic), or any of G2–G7.
**Number:** 0065 — G0 is 0059; N1's frame is 0063 and depends on this write.

---

## 1. The question

G0 (ADR-0059) found the VirtIO GPU and printed its capability table. A VirtIO
device reads virtqueues out of guest RAM by bus-master DMA, and SeaBIOS leaves
bit 2 of the command register **clear** on both `virtio-vga` and
`virtio-gpu-pci` (measured `cmd=0x0103`, `gpu.md` §3.2). Without a
configuration-space write, every later DMA looks perfect and transfers nothing.

`pciWrite32` is the five-line twin of `pciRead32`. Every future DMA device
needs it — virtio-net, virtio-blk, AHCI, bus-master IDE. Graphics is what
surfaced it (`gpu.md` Q3).

## 2. The decision

1. **`pciWrite32` lives in `pci.dart`.** It is a PCI facility, not a graphics
   one. The NIC does not call it (N0 is still a read; `n0-mac` asserts that).
   The `pci` command still only reads, so m5-pci goldens do not move.
2. **The write is `outl` to 0xCFC after the same selector `pciRead32` uses.**
   No new extern, no `portio.S` growth. Callers writing offset `0x04` must
   zero the status half: those bits are write-1-to-clear.
3. **G1 sets bit 2 from the `virtgpu` command, not from `virtgpuInit`.** Init
   stays a no-op, present or absent. A boot-time write would surprise every
   golden that never typed the command. An absent device still prints
   `VIRTIO NONE` and does not touch 0xCFC, so sit-in / Bochs / `-vga std`
   keep working.
4. **Print before and after; refuse if bit 2 did not stick.**
   `VIRTIO CMD BEFORE` / `VIRTIO CMD AFTER` plus `VIRTIO CMD STUCK` on COM1.
   Setting BME does not leave VGA compatibility mode — `SET_SCANOUT` does
   (VIRTIO §5.7.7), and that is G4.
5. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays 2511 bytes.
   D7 still owns the last `@bss` block.

## 3. What this is not

It is not `DRIVER_OK` (G2), not a virtqueue (G3), not a pixel (G4), not
virgl, and not a claim that the device has been reset or has negotiated
features. The common-configuration MMIO region is not touched.

## 4. Binary

`g1-virtgpu/run.sh`:

* boot `-machine q35 -vga virtio`, dump every slot's command register
  through the q35 ECAM window (`xp/1xw` at `0xb0000000 + (dev << 15) + 4`)
  **before** the keystrokes, then type `virtgpu` then `fb`;
* require the kernel's `CMD BEFORE` to equal that ECAM dword, with bit 2
  **clear**, and `CMD AFTER` to have bit 2 **set**;
* anti-vacuity: the two printed values must differ;
* `fb` still reports `MODE 0320x0258x20 OK` on that boot;
* the same kernel on `-vga std` prints `VIRTIO NONE`, no `CMD` line, and
  `fb` still works.

A kernel that never writes cannot pass the after-bit assertion. The
read-back refusal (`VIRTIO CMD STUCK`) must print if bit 2 does not stick.
