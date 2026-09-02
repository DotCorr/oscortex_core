# ADR-0129 — Graphite MakeVulkan is the kernel door

**Status:** accepted, implemented, leftover recorded (`tests/conformance/de-graphite/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0313 leftover after ADR-0125 (CPU `drawRRect` stairs)
**Files:** `core/plat/osgfx/osgfx_graphite_guest.cpp`,
`osgfx_skia.cpp` (call site), `core/scripts/build-skia-guest-graphite.sh`,
`core/scripts/build-kernel.sh`, `core/tests/conformance/de-graphite/`
**Depends on** ADR-0082 (host Graphite) and ADR-0110 (CPU Skia in `kernel.elf`).
**Does not close** GAP-0313: no `VkDevice` / Venus / Metal in QEMU.
**Number:** 0129 — 0128 is mmap. Do not reuse 0128.

---

## 1. The question

Sit-in chrome looks like qemu64 CPU `drawRect` stairs because live
paint is CPU Skia. Graphite is the Skia redesign. Host Graphite is
arm64 Metal `libskia.a` — copying it into an x86_64 image is
refused. Virgl (G10/G11) is GL upload, not Graphite.

## 2. The decision

1. **Rebuild Graphite for `kernel.elf`'s triple.**
   `build-skia-guest-graphite.sh` compiles official Skia as ELF64
   `x86_64-unknown-none-elf` with `skia_enable_graphite=true` and
   `skia_use_vulkan=true`. Not Mach-O. Not arm64. Not Metal.
2. **`osgfx_graphite_guest.cpp` calls
   `skgpu::graphite::ContextFactory::MakeVulkan`.** The backend
   struct is empty: no `VkInstance`, no `VkDevice`, no `fGetProc`.
   A non-null context here would be a stub. This machine prints
   `OSGFX GRAPHITE NONE`. `OSGFX GRAPHITE OK` is reserved for a
   real context.
3. **Live paint stays CPU Skia** until MakeVulkan returns a
   context. `wm gfx` still prints `WM GFX ON`. Curved CPU FillPath
   is not this door.
4. **Anti-vacuity.** `OSGFX_SKIA=0` has no `MakeVulkan`, no
   `skgpu::graphite`, no `graphite-vk-try`. Homebrew no-GL QEMU
   must not print `OSGFX GRAPHITE OK`.

## 3. What this is not

It is not a Graphite pixel on sit-in. It is not Metal in QEMU. It
is not G11 upload labelled Graphite. It is not a host `.a`.

## 4. Binary

`de-graphite/run.sh` — `nm` of `kernel.elf` names `MakeVulkan` and
`skgpu::graphite`; `OSGFX_SKIA=0` has neither; `wm gfx` prints
`WM GFX ON` and `OSGFX GRAPHITE NONE`; no `OSGFX GRAPHITE OK`.

## 5. Leftover

A `VkDevice` (Venus / virtio-gpu vulkan, or a kernel Vulkan ICD)
so `MakeVulkan` returns a context and Graphite rasterises chrome.
This machine calls `MakeVulkan` and prints `OSGFX GRAPHITE NONE`.
Live sit-in paint is still CPU Skia `drawRect` stairs. Graphite's
`.init_array` (`VulkanQueueManager` `__cxx_global_var_init`) #GPs
here and is not walked.
