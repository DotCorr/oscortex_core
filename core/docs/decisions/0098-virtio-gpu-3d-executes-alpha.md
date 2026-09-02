# ADR-0098 — VirtIO-GPU 3D executes the pixel, including alpha

**Status:** accepted, implemented, verified (`tests/conformance/g10-virgl/run.sh`)
**Date:** 2026-08-30
**Milestone:** G10 / VIRGL0 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu3d.dart` (new), `core/kernel/kmain.dart`
(`part` + silent `virtgpu3dInit`), `core/kernel/shell.dart` (hidden
`virtgpug` / `virtgpuz`, no help line),
`core/tests/conformance/g10-virgl/run.sh`,
`core/scripts/build-qemu-gl.sh`
**Depends on** ADR-0097 (G9 GET_CAPSET_INFO) and ADR-0074 (control queue).
**Does not rewrite** G0–G9. G2 still accepts `VIRTIO_F_VERSION_1` only.
**Number:** 0098 — 0096 is sit-in Skia; 0097 is G9. Do not reuse those.

---

## 1. The question

G0–G8 are a mailbox: the CPU writes pixels, the device scans them
out. G9 sends `GET_CAPSET_INFO` on a machine whose Homebrew QEMU
offers `num_capsets=0`. UI transparency needs the **device** to
execute GPU work that produces a framebuffer with alpha.

## 2. The decision

1. **A new file, `core/kernel/virtgpu3d.dart`.** G0–G9 stay in
   `virtgpu.dart`. This file reuses their MMIO / virtqueue helpers
   and does its own feature walk so G2's `VERSION_1`-only negotiate
   is not rewritten.
2. **Accept `VIRTIO_GPU_F_VIRGL` when offered.** Bit 0 of feature
   word 0. Absent bit → `VIRTIO 3D NONE` and `VIRTIO PAINT 2D` (or
   `NONE` if there is no device). No `3D OK`.
3. **The submit form is `virtgpug`.** `CTX_CREATE`, two
   `RESOURCE_CREATE_3D`, attach backing on the dest only (zeroed —
   the kernel does not store the blended colour), `SUBMIT_3D` of a
   hand-built virgl stream: `CLEAR` navy `0x184060`, `CLEAR` 50%
   red, `BLIT` with `alpha_blend`, then `TRANSFER_FROM_HOST_3D` of
   one pixel inside the blit and `SET_SCANOUT`. Prints
   `VIRTIO 3D OK`, `VIRTIO PAINT 3D`, `VIRTIO 3D PIX`.
4. **`virtgpuz` probes and does not submit.** VIRGL may be
   offered. `VIRTIO 3D OK` must not print. That is the
   anti-vacuity on a 3D device.
5. **Paint fallback is GOP-shaped.** 3D GPU → else CPU raster of
   the same osgfx/Skia scene (sibling; this slice does not print
   `PAINT CPU`) → else G4–G8 2D mailbox. Never a blank desktop
   because there is no GPU.
6. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block.

## 3. What this is not

It is not Mesa. It is not Venus. It is not Mac Metal sit-in. It
is not a CPU blend written into BACK and flushed as "3D". It is
not amdgpu. G9's capset contract is not rewritten.

## 4. Binary

`g10-virgl/run.sh`:

* Homebrew `-vga std` and `-device virtio-gpu-pci`: `virtgpug`
  prints `VIRTIO 3D NONE`, no `3D OK`. `virtgpuc` never prints
  `3D OK`.
* 3D QEMU is `oscortex-qemu-gl:local` from
  `scripts/build-qemu-gl.sh` (Debian sid `qemu-system-x86` 11.1.0
  + `qemu-system-modules-opengl` + `libvirglrenderer1` + Xvfb).
  Homebrew 11.0.0 on this arm64 Mac has no `virtio-gpu-gl-pci`.
* On `virtio-gpu-gl-pci`: `virtgpug` prints `VIRTIO 3D OK`.
  BACK is a GPU-written translucent — 50% red `A=0x80` from the
  device CLEAR, or src-over of that red over navy if the host
  blends. Not navy, not full opaque red, not `0x00101018`.
* `virtgpuz` on that device prints no `3D OK`.

Anti-vacuity is G5-only flush, a no-submit walk, and a CPU store
of the blended dword in `virtgpu3d.dart`.
