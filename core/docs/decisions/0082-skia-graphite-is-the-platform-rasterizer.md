# ADR-0082 — Skia Graphite is the platform rasterizer

**Status:** accepted, implemented, verified (`tests/conformance/gfx1-graphite/run.sh`)
**Date:** 2026-08-30
**Milestone:** GFX1 (`docs/design/c-modules.md`)
**Files:** `core/plat/osgfx/osgfx_graphite.mm`, `osgfx_metal.h`,
`osgfx_metal.m` (fallback), `core/scripts/build-skia-graphite.sh`,
`core/scripts/build-preview-ui.sh`, `core/tests/conformance/gfx1-graphite/`
**Depends on** ADR-0080 (`osgfx.h`) and ADR-0081 (DCDart FFI).
**Does not close** GAP-0313 items Vulkan / Chromium.
**Number:** 0082 — 0081 is the DCDart call; this is Graphite behind the same header.

---

## 1. The question

GFX0 painted `osgfx.h` on Metal because this Mac had Metal and did
not have Skia Graphite installed. brew `graphite2` is a font shaper.
Flutter is on PATH and is not an embedder. GFX1 is the platform C++
rasterizer: `osgfx_fill_rrect` is Graphite.

## 2. The decision

1. **Fetch Skia and build Graphite + Metal** with
   `core/scripts/build-skia-graphite.sh`. Shallow clone of
   `github.com/google/skia` at `3ae8e3d1e3358c2c805f17b1092d4d3ee5d4bb7b`,
   `bin/fetch-gn`, no `git-sync-deps` (codecs, ICU, HarfBuzz, Ganesh,
   Vulkan, Dawn, zlib are off). Output is
   `core/build/skia/out/graphite/libskia.a`.
2. **`osgfx_graphite.mm` implements `osgfx.h`.** It calls
   `skgpu::graphite::ContextFactory::MakeMetal` and
   `SkCanvas::drawRRect`. Same colours, same rrect probe.
3. **Metal stays as fallback** if Graphite device create fails, or
   when `OSGFX_FORCE_METAL=1`. The harness default path must print
   `BACKEND graphite`. The force-metal path is the negative that
   proves Graphite is still in the binary (`nm` still names
   `skgpu::graphite`).
4. **A stub `.cpp` that only exports `osgfx_backend_graphite` and
   calls Metal is a fail.** The harness requires both the C symbol
   and a mangled Graphite symbol, and greps the `.mm` for
   `MakeMetal` and `drawRRect`.
5. **No syscall, no `.bss`, no `help` line.** FRAME apps still
   paint shm pixels. They do not contain libskia.

## 3. What this is not

It is not Chromium. It is not Flutter. It is not an app ELF.
It is not brew `graphite2`. It is not a Cocoa desktop.

## 4. Verification

`core/tests/conformance/gfx1-graphite/run.sh` — Mach-O arm64,
`nm` has `osgfx_fill_rrect` and a `skgpu::graphite` symbol,
default PPM `BACKEND graphite` and rrect corner is desktop,
`--square` negative, `OSGFX_FORCE_METAL=1` is metal and still
rrects, Graphite symbols remain.
