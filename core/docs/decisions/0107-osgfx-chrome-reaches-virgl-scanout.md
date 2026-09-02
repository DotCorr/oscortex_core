# ADR-0107 — osgfx session chrome reaches VIRGL scanout

**Status:** accepted, implemented, verified (`tests/conformance/g11-osgfx-gl/run.sh`)
**Date:** 2026-08-30
**Milestone:** G11 (`docs/design/gpu.md` §5/G11)
**Files:** `core/kernel/virtgpu3d.dart` (append), `core/kernel/shell.dart`
(hidden `virtgpuk`, no help line), `core/tests/conformance/g11-osgfx-gl/`
**Depends on** ADR-0098 (G10 VIRGL CLEAR) and ADR-0104 (osgfx_sw in
`kernel.elf`).
**Does not rewrite** G10 CLEAR / `virtgpug` / `virtgpuz`. Does not
rewrite DE chrome (`wm de`, ADR-0106).
**Number:** 0107 — 0106 is DE chrome. Do not reuse that.

---

## 1. The question

`osgfx_sw` / `osgfx_scene_compose` already paint rounded session
chrome (`wm gfx`, de-osgfx PASS). G10 already has the device
execute a virgl CLEAR on `virtio-gpu-gl-pci`. Sit-in still
scanouts that chrome on Bochs. The same compose buffer must
reach **that** GPU scanout.

## 2. The decision

1. **Append to `virtgpu3d.dart`.** Hidden `virtgpuk` negotiates
   `VIRTIO_GPU_F_VIRGL`, `CTX_CREATE`, `RESOURCE_CREATE_3D` of
   the GET_DISPLAY_INFO rectangle, attaches backing (reuses the
   live G5/osgfx compose pages when they already sit in low
   RAM), `TRANSFER_TO_HOST_3D` of that buffer, `TRANSFER_FROM_HOST_3D`
   of two probe pixels (AABB corner and title interior),
   `SET_SCANOUT`. Prints `VIRTIO 3D OK`, `VIRTIO PAINT 3D`,
   `VIRTIO OSGFX 3D`, `VIRTIO OSGFX AABB`, `VIRTIO OSGFX TITLE`.
2. **G10 is untouched.** `virtgpu3dFillStream` / `virtgpu3dPaint`
   / `virtgpug` / `virtgpuz` stay. This is not a CLEAR rewrite.
3. **Not Graphite.** No Mac `libskia.a`. The paint is still
   `osgfx_sw.c`. The GPU path is upload + bind + scanout.
4. **No help, no syscall, no `.bss`.** `shellStrHelp` stays
   2511. `wmeventStore` stays last. 11 stays `fdwait`.

## 3. What this is not

It is not Skia Graphite on virgl. It is not Vulkan / Venus.
It is not a G5 2D mailbox labelled 3D. It is not DE chrome
widgets (ADR-0106). It is not a new syscall.

## 4. Binary

`g11-osgfx-gl/run.sh`:

* Docker `oscortex-qemu-gl:local` + `virtio-gpu-gl-pci`: `virtgpuk`
  creates the 3D scanout, kicks `osgfx_guest_tick` (session rrect
  if no live window — two READY clients steal the shell), then
  prints `VIRTIO OSGFX 3D` and `VIRTIO 3D OK`. AABB is desktop
  `0x184060`; title interior is title. Those dwords come from
  `TRANSFER_FROM_HOST_3D` after a zero of the sample slot — not
  a CPU store of the expected colour.
* Homebrew `-vga std` and `virtio-gpu-pci`: `virtgpuk` prints
  `VIRTIO 3D NONE`, no `3D OK`, no `OSGFX 3D`. `wm gfx` on
  Bochs still prints `WM GFX ON`.
* `virtgpuc` (G5) never prints `OSGFX 3D`. `g10-virgl` and
  `de-osgfx` stay PASS.
