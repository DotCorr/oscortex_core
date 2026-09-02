# ADR-0097 — GET_CAPSET_INFO is the first 3D-path command

**Status:** accepted, implemented, verified (`tests/conformance/g9-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G9 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (`virtgpui` / `virtgpuj`,
`num_capsets` + `GET_CAPSET_INFO`), `core/kernel/shell.dart`
(hidden dispatch), `core/tests/conformance/g9-virtgpu/run.sh`
**Depends on** ADR-0074 (G3 virtqueue) and ADR-0067 (DRIVER_OK).
**Supersedes** ADR-0096 as the product claim: Skia CPU raster in
the kernel image is not the UI, and sit-in does not use it.
**Number:** 0097 — 0096 was the withdrawn CPU-raster sit-in.

---

## 1. The question

VirtIO-GPU 2D (G0–G8) is a display device. The owner asked for
Skia / osgfx on the GPU: Graphite → Vulkan (or virtio-gpu 3D /
virgl / Venus) → the same scanout sit-in shows. Metal cannot
link into the OS image. Host Graphite is not the OS.

This Homebrew QEMU has no `virtio-gpu-gl-pci` and offers
`num_capsets=0`. A full Graphite/Vulkan paint cannot finish
on this machine. The first honest command on that ladder is
still sendable.

## 2. The decision

1. **Preview stays gone.** `preview-ui.sh`, `preview_main.m`,
   Preview.app, and `preview.html` are not the UI. Host
   harnesses (`gfx0` / `gfx1` / `gfx2-compose` / `cmod-ffi1`)
   still prove the module. `sit-in.sh` boots the OS.
2. **`virtgpui` submits `GET_CAPSET_INFO` (0x0108).** After the
   G3 walk it reads `num_capsets` from DEVICE_CFG +12 and
   sends capset index 0 on the same control queue. The kernel
   prints `VIRTIO CAPSETS` and `VIRTIO CAPINFO`. Feature
   negotiation stays `VIRTIO_F_VERSION_1` only (G2).
3. **`virtgpuj` prints the config word and does not submit.**
   `CAPINFO` must not print. That line is the virtqueue write,
   not a static string.
4. **sit-in uses `wm chrome`, not CPU Skia.** Exact-rect goldens
   (d2 / d8 / d7) stay on that path. Rounded chrome through
   Graphite on the GPU is the leftover.
5. **No help line. No new syscall.** 11 stays `fdwait`.
   `wmeventStore` stays last `.bss`. No commit in this slice.

## 3. What this is not

It is not Skia painting session chrome. It is not Graphite.
It is not Vulkan, virgl, or Venus. It is not a pixel on
scanout from a shader. It is not host Metal called sit-in.

## 4. Binary

`g9-virtgpu/run.sh`:

* preview files gone; sit-in does not set `OSGFX_GUEST=1`;
* boot `-vga none -device virtio-vga,xres=1088,yres=784`,
  type `virtgpui`;
* require G3 `RESP 00001101` and SCAN matching the launch mode;
* require one `VIRTIO CAPSETS` and one `VIRTIO CAPINFO` whose
  type is neither 0 nor `GET_DISPLAY_INFO`;
* `virtgpuj` prints CAPSETS and no CAPINFO;
* `-vga std` prints `VIRTIO NONE` and no capset lines;
* `fb` still prints `FB BAR` on the same device.
