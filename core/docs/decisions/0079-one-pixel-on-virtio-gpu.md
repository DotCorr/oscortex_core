# ADR-0079 — One pixel on VirtIO-GPU

**Status:** accepted, implemented, verified (`tests/conformance/g4-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G4 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (create / attach / SET_SCANOUT /
one filled pixel / transfer / flush), `core/kernel/shell.dart`
(colour-argument dispatch), `core/tests/conformance/g4-virtgpu/run.sh`
**Depends on** ADR-0074 (GET_DISPLAY_INFO).
**Does not close** scrolling / double buffering (G6) or
`virtio-gpu-pci` without VGA (G7). G5 (ADR-0084) moved the console.
**Number:** 0079 — 0074 is G3's virtqueue; 0078 is spawn-by-name.

---

## 1. The question

G3 proved DMA: queue 0 answers `GET_DISPLAY_INFO`. A pixel still is
not on the host scanout. G4 is the five-command walk that creates a
resource, backs it, leaves VGA compatibility, and puts one derived
colour where `pmemsave` and `screendump` can both read it.

## 2. The decision

1. **The colour form is `virtgpu <hex>`.** Bare `virtgpu` stays the
   G3 walk so g0–g3 keep their one `RESP` / one `USED` line.
   `virtgpuInit` stays a no-op. An absent device still prints
   `VIRTIO NONE`.
2. **Dimensions come from scanout 0**, not from a constant. Resource
   id 1, format `B8G8R8X8` (2). Backing is one `allocFrame()` per
   4 KiB of `w*h*4`, described by a chained attach-entry list.
3. **One fill.** The first backing word is the typed colour. Transfer
   and flush are a 1×1 rectangle at (0, 0). That is the proven pixel.
4. **Each G4 reply prints `VIRTIO PIX`, not `VIRTIO RESP`.** G3's
   line count must not move on the colour path's extra commands.
5. **`virtgpua` omits attach.** `SET_SCANOUT` must then return
   `ERR_UNSPEC` / `ERR_INVALID_RESOURCE_ID` / `ERR_INVALID_PARAMETER`
   rather than `0x1100`.
6. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block. The tokens
   `RESOURCE_CREATE_2D`, `VIRTIO_GPU_CMD` and `queue_enable=` stay
   out of this file so g0–g3 remain green.

`SET_SCANOUT` leaves VGA compatibility mode (VIRTIO §5.7.7). The
existing `fb` / sit-in / d2-compositor path is untouched on every
boot that does not type the colour form.

## 3. What this is not

It is not the framebuffer console running on VirtIO (G5). The
cursor queue is not touched. `fb.dart` is not rewritten.

## 4. Binary

`g4-virtgpu/run.sh`:

* boot `-vga none -device virtio-vga,xres=1136,yres=848`, type
  `virtgpu` plus a colour derived from that geometry;
* require five `VIRTIO PIX 00001100` lines, `FRAMES` equal to
  `ceil(1136*848*4/4096)`, and `COLOUR` equal to the typed value;
* `pmemsave` of the printed `BACK` address has that colour at word 0;
* screendump pixel (0, 0) is the same colour;
* a second boot with a second derived colour changes both dumps;
* `virtgpua` prints no `BACK` and `SET_SCANOUT`'s PIX is an error;
* `-vga std` still prints `VIRTIO NONE`.

Anti-vacuity is a zero colour, a colour equal to `fbColorBg`, a
frame count of one page, and two boots that would agree. 1136×848
does not appear in `virtgpu.dart`.
