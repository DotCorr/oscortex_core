# ADR-0125 — Live `drawRRect` is the sit-in paint path

**Status:** accepted, implemented, verified (`tests/conformance/de-osgfx/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-osgfx leftover (`docs/design/c-modules.md`, ADR-0110)
**Files:** `core/plat/osgfx/osgfx_skia.cpp`, `osgfx_cxxrt.cpp`,
`osgfx_guest_crt.c`, `core/scripts/skia-guest-cc.sh`,
`skia-guest-cxx.sh`, `core/tests/conformance/de-osgfx/`
**Depends on** ADR-0110 (Skia CPU raster already linked).
**Does not close** GAP-0313 leftover: Graphite / Vulkan paint on G10 virgl.
**Number:** 0125 — 0124 is the platform process window. Do not reuse 0124.

---

## 1. The question

ADR-0110 linked official Skia into `kernel.elf` and named
`SkCanvas::drawRRect`. Live paint was `SkRRect::contains` + stores
because `drawRRect` did not return from IRQ0 on Homebrew `qemu64`.
That is not the rasterizer. Sit-in chrome must be Skia drawing.

## 2. The decision

1. **`osgfx_fill_rrect` calls `SkCanvas::drawRRect`.** AA-off, so
   AABB (100,120) stays exact desktop `0x184060`. The path token is
   `skia-draw`. `contains` + stores is not the paint. Guest Skia is
   rebuilt SSE2-only so the scan converter has no VEX on qemu64.
   Curved `SkScan::FillPath` (oval / rrect) still does not return
   from IRQ0 on Homebrew `qemu64`; the live `drawRRect` is the
   rect-type fast path (delegates to `drawRect`) and rounded pixels
   are `SkCanvas::drawRect` spans. That is Skia raster, not stores.
2. **qemu64 has no AVX / OSXSAVE.** `SkCpu::CacheRuntimeFeatures` in
   `osgfx_cxxrt.cpp` reports SSE2 only and never `xgetbv` (CR4 bit 18
   is unset; a #UD in IRQ0 looks like a hang). `skcms_DisableRuntimeCPUDetection`
   runs before Skia ctors so `skcms` `cpu_type()` stays Baseline.
   `Init_ml3` / `Init_ml4` / `Init_Memset_avx` stay empty. Guest
   clang wrappers force `-march=x86-64 -mno-avx` and `SK_CPU_LIMIT_SSE2`.
3. **No new syscall. d8 stays `wm chrome`.** 11 stays `fdwait`.
   `sit-in.sh` stays `wm gfx`. `vmFineBytes` stays 12 MiB.
4. **Anti-vacuity.** `OSGFX_SKIA=0` still has no `osgfx_fill_rrect` /
   `SkCanvas` / `drawRRect`. A `contains` body fails the DRAW line.

## 3. What this is not

It is not Graphite on virgl. It is not Metal. It is not `osgfx_sw.c`.
It is not shrinking the kernel map. It is not a guest OS.

## 4. Verification

`core/tests/conformance/de-osgfx/run.sh` — `osgfx_fill_rrect` calls
`drawRRect` and does not `contains`; `nm` / strings name `skia` +
`skia-draw`; `OSGFX_SKIA=0` has neither; sit-in / `wm gfx` AABB
(100,120) is desktop `0x184060` and the QEMU session returns
(timeout harness).
