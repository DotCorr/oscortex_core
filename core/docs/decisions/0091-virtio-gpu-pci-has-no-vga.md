# ADR-0091 — `virtio-gpu-pci` has no VGA, and scanout still works

**Status:** accepted, implemented, verified (`tests/conformance/g7-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G7 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (vendor `0x1AF4` / device `0x1050`
walk — unchanged from G0; G5 `virtgpuc` on class `03/80`),
`core/kernel/fb.dart` (`FB NONE` via `fbStrNoDev` — ADR-0064),
`core/tests/conformance/g7-virtgpu/run.sh`
**Depends on** ADR-0084 (G5 console on VirtIO) and ADR-0064 (scanout
fallback).
**Does not close** two-resource `SET_SCANOUT` flip (GAP-0070 item 6).
**Number:** 0091 — 0086 is G6; 0089 is NVM4; 0090 is FAT-on-NVMe.
Do not reuse 0086 or 0090.

---

## 1. The question

G0–G6 proved the driver on `-device virtio-vga` (class `03/00`).
That device still has a Bochs BAR, so `fb` can quietly substitute
dispi for VirtIO and the harness would still see pixels. G7 is the
machine that cannot: `-device virtio-gpu-pci` is class `03/80`,
has no linear framebuffer BAR, no dispi, and no VGA BIOS.
`fbFindVgaBar` must not find it. Scanout must still come from
`GET_DISPLAY_INFO` and the G5 walk.

## 2. The decision

1. **No new command.** `virtgpuc` / `virtgpue` stay the G5 walks.
   Bare `virtgpu` and `virtgpu <hex>` stay G3 / G4. `virtgpus` /
   `virtgpux` stay G6. `virtgpuInit` stays a no-op. Discovery is
   already vendor `0x1AF4` / device `0x1050` (ADR-0059); a subclass
   `0x00` filter would print `VIRTIO NONE` on this device.
2. **`fb` prints `FB NONE`.** ADR-0064's chain is GOP, then Bochs,
   then `fbStrNoDev`. This machine has no GOP tag (`-kernel`) and
   no VGA-class BAR, so the existing line is
   `FB NONE -- no VGA-class device with a memory BAR0 on bus 0`.
   `FB NOVBE` is the other existing spelling, and it means a VGA
   BAR answered and dispi did not. Inventing a third string, or
   printing `NOVBE` here, would be a lie.
3. **`-vga none` is how QEMU is told not to attach stdvga.**
   Omitting `-vga` entirely still gets a VGA-class device on
   `pc`/`q35`. The harness asserts QEMU's `info pci` contains
   zero `VGA controller` lines, not that the argv omitted `-vga`.
4. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block. No
   two-resource flip.

## 3. What this is not

It is not two resources and a `SET_SCANOUT` flip (GAP-0070 item 6).
It does not rewrite G5 cell-flush or G6 damage contracts. g0–g6
still boot `virtio-vga` / VGA.

## 4. Binary

`g7-virtgpu/run.sh`:

* boot `-vga none -device virtio-gpu-pci,xres=864,yres=640`, type
  `virtgpuc`;
* require `info pci` to list zero `VGA controller` devices and
  one `1af4:1050`;
* require the kernel device line to be class `03/80`, `VIRTIO BACK`
  in low RAM, `FRAMES` equal to `ceil(864*640*4/4096)`, and
  `FLUSH` equal to 51;
* `xp` of the sixteen banner scanlines at `BACK` matches
  `fbFont8x16` (m5 form, not a PNG);
* `virtgpue` matches the same pixels and prints `FLUSH 0`;
* `fb` on the same device prints `FB NONE -- no VGA-class device
  with a memory BAR0 on bus 0` and not `FB BAR` / `FB NOVBE` /
  `FB GOP`;
* `-vga std` still prints `VIRTIO NONE`.

Anti-vacuity is a VGA-class device on the positive boot, a flush
count of zero, and `FB BAR` / `FB NOVBE` on a machine with no VGA
class. 864×640 does not appear in `virtgpu.dart`.
