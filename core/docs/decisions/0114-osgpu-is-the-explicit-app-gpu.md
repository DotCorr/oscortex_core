# ADR-0114 — osgpu is the explicit app GPU

**Status:** accepted, implemented, verified (`tests/conformance/gpu-app0/run.sh`)
**Date:** 2026-08-30
**Milestone:** G12 (`docs/design/gpu.md` § two uses / G12)
**Files:** `core/user/gpu/osgpu.h`, `osgpu.c`, `gpuapp.c`,
`core/kernel/virtgpu3d.dart` (append), `core/kernel/shell.dart`
(hidden `osgpug`), `core/tests/conformance/gpu-app0/`
**Depends on** ADR-0098 (G10 virgl CLEAR + transfer).
**Does not allocate a syscall.** 11 stays `fdwait` and is not built.
**Number:** 0114 — 0111–0113 are title-drag / FRAME / OSXUI-kit.

---

## 1. The question

The GPU is already on the compositor path (G10–G11). A second
author still needed a written split: UI must not ask an app to
pick GPU vs CPU, and a game that needs a GPU must have a C
header, like osframe, that is not DCDart-become-C++.

## 2. The decision

1. **Two uses. Do not mix them.** Implicit: UI / osgfx / wm
   decide GPU vs CPU Skia. Apps do not pick. Explicit: games
   call `osgpu.h`. UI never requires the app to call osgpu.
2. **`osgpu.h` is the games ABI.** `osgpu_create`,
   `osgpu_submit` (CLEAR or triangle), `osgpu_readback`. C,
   like osframe. DCDart does not become C++. C++ only behind
   the fence if the impl is Vulkan/virgl.
3. **Hidden `osgpug` hits G10.** Same virgl CLEAR +
   `TRANSFER_FROM_HOST_3D`. Prints `OSGPU OK` / `OSGPU PIX` or
   `OSGPU NONE`. The C stub returns `OSGPU_NONE` until a later
   syscall wraps those three functions. No number is taken.
4. **No help line, no kernel `.bss`, no wm in C++.**
   `shellStrHelp` stays 2511 bytes. G10 CLEAR stays.

## 3. What this is not

It is not osgfx. It is not a compositor pick. It is not a
swapchain. It is not a shader ABI. It is not a syscall. It is
not guest Skia.

## 4. Binary

`gpu-app0/run.sh` compiles `osgpu.c` / `gpuapp.c` for the
kernel triple, types hidden `osgpug` on `virtio-gpu-gl-pci`,
and requires `OSGPU OK` plus a derived `OSGPU PIX` (alpha or
colour ≠ CPU blit constant). Negative: no 3D device prints
`OSGPU NONE`; `wm gfx` still prints `WM GFX ON`.
Anti-vacuity: `virtgpuc` does not print `OSGPU OK`; wm /
osgfx_sw / osxui do not include `osgpu.h`.
