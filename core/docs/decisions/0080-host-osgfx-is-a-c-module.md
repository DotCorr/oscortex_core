# ADR-0080 — Platform osgfx is a C module

**Status:** accepted, implemented, verified (`tests/conformance/gfx0-host/run.sh`)
**Date:** 2026-08-30
**Milestone:** GFX0 / CMOD1 (`docs/design/c-modules.md`)
**Files:** `core/plat/osgfx/osgfx.h`, `osgfx_metal.m`, `osgfx_scene.c`,
`headless_main.c`, `preview_main.m`, `core/scripts/build-preview-ui.sh`,
`core/scripts/preview-ui.sh`, `core/tests/conformance/gfx0-host/`
**Depends on** nothing in the kernel.
**Does not close** GAP-0313 (Graphite, Vulkan, Chromium WebView, DCDart FFI).
**Number:** 0080 — 0079 is G4; do not reuse 0074.

---

## 1. The question

The preview was an HTML canvas that restated compositor colours.
That file is not a UI language. The owner wants platform C/C++
(libc-class, then Skia Graphite, then Chromium as system WebView)
and DCDart able to call them the way Java calls JNI. This rung
cannot vendor Chromium. It can make the **paint ABI** real on the
GPU this Mac has.

## 2. The decision

1. **`osgfx.h` is the UI language.** Rounded rects, fills, vertical
   gradients, shadows. Colours are `0x00RRGGBB`. Platform clang.
   This is oscortex, not an app ELF.
2. **The first backend is Metal.** `MTLCreateSystemDefaultDevice`.
   Skia Graphite and MoltenVK are not installed (GAP-0313). Flutter
   is on PATH and is not linked (`dcdart.md`).
3. **`preview-ui.sh` builds and execs `osgfx-preview`.** It does not
   `open` `preview.html`.
4. **Headless writes a P6 PPM** so the harness does not need a
   screenshot golden. The AABB corner of the first window must be
   desktop, not title. `--square` uses `fill_rect` so the negative
   path is observed, not imagined.
5. **No syscall, no `.bss`, no `help` line.** FRAME apps still
   paint shm pixels (ADR-0051). They do not contain this module.

## 3. What this is not

It is not Skia Graphite. It is not Chromium. It is not an app.
It is not DCDart calling C (that is CMOD-FFI1, `dcdart-c-ffi.md`).
It is not Flutter. It is not a "guest" library.

## 4. Verification

`core/tests/conformance/gfx0-host/run.sh` — platform clang, Mach-O
arm64, `nm` has `osgfx_fill_rrect`, rrect PPM probe, square negative,
the two PPMs differ.
