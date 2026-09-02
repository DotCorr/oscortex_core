# ADR-0134 — Graphite MakeVulkan needs a VkDevice

**Status:** accepted, implemented, leftover recorded (`tests/conformance/de-graphite2/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0313 leftover after ADR-0129 (empty MakeVulkan)
**Files:** `core/plat/osgfx/osgfx_vk.c`, `osgfx_vk.h`,
`osgfx_graphite_guest.cpp`, `osgfx_guest.h`, `osgfx_skia.cpp`,
`core/kernel/virtgpu3d.dart` (`virtgpuv`), `core/kernel/shell.dart`,
`core/scripts/build-kernel.sh`, `core/tests/conformance/de-graphite2/`
**Depends on** ADR-0129 (MakeVulkan is linked). Does not revert that call.
**Does not close** GAP-0313: SPIR-V coverage / Venus command stream.
**Number:** 0134 — 0129 is the call. 0130–0133 are sibling doors.
Do not reuse those.

---

## 1. The question

ADR-0129 called `ContextFactory::MakeVulkan` with an empty
`VulkanBackendContext`. Serial was `OSGFX GRAPHITE NONE`. A call
with a null context is a stub. Graphite is the OS renderer. Chrome
must not be labelled Graphite until MakeVulkan returns a live
context and at least one pixel is Graphite GPU work.

Homebrew QEMU has no virtio-gpu GL/Vulkan. Docker
`oscortex-qemu-gl` offers `virtio-gpu-gl-pci,venus=on`. G10/G11
are virgl, not Graphite.

## 2. The decision

1. **Venus capset is the arming door.** Hidden `virtgpuv` walks
   `GET_CAPSET_INFO`. Capset id 4 (`VIRTIO_GPU_CAPSET_VENUS`)
   writes mailbox word `vk`. Homebrew / `virtio-gpu-pci` / no
   `venus=on` leave `vk=0`.
2. **Kernel ICD `osgfx_vk.c` is the VkDevice.** When `vk=1`,
   `osgfx_graphite_try` creates a Vulkan 1.1 instance, physical
   device, device, queue, `fGetProc`, and a
   `VulkanMemoryAllocator`. `MakeVulkan` is called with those
   handles. A non-null context prints `OSGFX GRAPHITE OK`.
   `vk=0` still calls MakeVulkan with an empty backend and
   prints `OSGFX GRAPHITE NONE`.
3. **One Graphite GPU pixel.** The live context records a 16×16
   `canvas->clear` of `0x00E24A18`, `insertRecording`, submit,
   `asyncRescaleAndReadPixels`. That dword is stamped at
   framebuffer (8,8). Serial `OSGFX GRAPHITE PIX`. Not CPU
   `drawRect`, not a virgl CLEAR, not a G11 upload of a CPU
   buffer. Sit-in chrome stays CPU Skia rrect spans.
4. **Anti-vacuity.** Homebrew `-vga std` never offers Venus.
   `OSGFX GRAPHITE OK` and `PIX 00E24A18` are forbidden there.
   `OSGFX_SKIA=0` still has no MakeVulkan.
5. **No new syscall.** 11 stays `fdwait`. No help line.
   `wmeventStore` stays last. No usb-kbd on 8042.

## 3. What this is not

It is not Mesa Venus encode. It is not SPIR-V shader execution.
It is not Graphite chrome (title / menu bar still CPU
`drawRect` spans). It is not Metal. It is not G10/G11 relabelled.
It is not a host `.a`.

## 4. Binary

`de-graphite2/run.sh`:

* `nm` of `kernel.elf` names `MakeVulkan`, `osgfx-vk-icd`,
  `graphite-vk-try`. `OSGFX_SKIA=0` has none.
* Homebrew `-vga std`: `wm gfx` prints `WM GFX ON` and
  `OSGFX GRAPHITE NONE`. No `OSGFX GRAPHITE OK`. No
  `PIX 00E24A18`. `virtgpuv` prints `VIRTIO VENUS NONE`.
  `D3S COMMIT` still lands.
* Docker `virtio-gpu-gl-pci,venus=on`: `virtgpuv` prints
  `VIRTIO VENUS OK`. `wm gfx` prints `OSGFX GRAPHITE OK` and
  `OSGFX GRAPHITE PIX 00E24A18`. Screen (8,8) is that colour.

## 5. Leftover

Venus command stream (CONTEXT_INIT + blob + host lavapipe) so
Graphite's SPIR-V coverage paints chrome rrects on the host
GPU. This machine's ICD executes render-pass clears and copies.
`vkCmdDraw` does not run SPIR-V. Do not call chrome Graphite
until that leftover lands.
