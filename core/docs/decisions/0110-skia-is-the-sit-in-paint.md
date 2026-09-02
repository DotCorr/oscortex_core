# ADR-0110 — Sit-in paint is Skia CPU raster

**Status:** accepted, implemented, verified (`tests/conformance/de-osgfx/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-osgfx leftover (`docs/design/c-modules.md`, `docs/design/osx-ui.md`)
**Files:** `core/plat/osgfx/osgfx_skia.cpp`, `osgfx_cxxrt.cpp`,
`osgfx_guest_crt.c`, `osgfx.h`, `core/scripts/build-skia-guest.sh`,
`skia-guest-cc.sh`, `skia-guest-cxx.sh`, `core/scripts/build-kernel.sh`,
`core/link/kernel.ld` (`.text.*` / `.init_array`),
`core/tests/conformance/de-osgfx/`
**Depends on** ADR-0080 (`osgfx.h`), ADR-0104 (the OS already calls that ABI).
**Does not close** GAP-0313 leftover: Graphite / Vulkan paint on G10 virgl.
**Number:** 0110 — 0109 is shmMax. 0111+ are parallel rungs. Do not reuse those.

---

## 1. The question

ADR-0104 linked `osgfx_sw.c` into `kernel.elf`. The C ABI ran. The
pixels were rounded. That was not Skia. Host Graphite is arm64 Metal
`libskia.a` — copying it into an x86_64 image is rejected. The owner
wants Skia as the UI renderer (GPU if present, Skia CPU raster if not).
Same `osgfx.h`. Sit-in on Homebrew QEMU must not wait for Docker GL.

## 2. The decision

1. **Rebuild Skia for `kernel.elf`'s triple.** `build-skia-guest.sh`
   compiles official Skia as ELF64 `x86_64-unknown-none-elf` CPU raster
   (no Metal, no Graphite, no Ganesh, no GL). `libskia.a` is that
   archive. Not a Mach-O. Not arm64.
2. **`osgfx_fill_rrect` is `SkCanvas::drawRRect`.**
   `osgfx_skia.cpp` implements `osgfx.h`. ADR-0125 made the live
   path `drawRRect` (AA-off). The ADR-0110 `contains` + store
   workaround is withdrawn. `osgfx_backend_name` is `"skia"`.
   `osgfx_backend_graphite` is 0.
3. **`osgfx_sw.c` is not Skia.** It stays in-tree (g11 / gfx3 grep
   the source). It is not the default link. `OSGFX_SKIA=0` (and the
   old `OSGFX_SW=0` alias) omits the Skia `.o` and `libskia.a`.
4. **No Mac Metal in `kernel.elf`. No new syscall.** 11 stays
   `fdwait`. `sit-in.sh` stays `wm gfx`. d8 / d2 stay `wm chrome`.
5. **Anti-vacuity.** A build without the Skia `.o` has no `SkCanvas`
   / `drawRRect` / `SkRRect` and fails the “skia backend” line.

## 3. What this is not

It is not Graphite on virgl. It is not Metal. It is not
`osgfx_sw.c` renamed. Host `gfx0` / `gfx1` / `gfx2-compose` stay
host-only.

## 4. Verification

`core/tests/conformance/de-osgfx/run.sh` — `nm` names `SkCanvas` /
`drawRRect` / `osgfx_fill_rrect` in `kernel.elf`; `OSGFX_SKIA=0`
does not; sit-in / `wm gfx` AABB (100,120) is desktop `0x184060`.
