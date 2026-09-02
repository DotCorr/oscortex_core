# ADR-0081 — DCDart calls the C paint module

**Status:** accepted, implemented, verified (`tests/conformance/cmod-ffi1/run.sh`)
**Date:** 2026-08-30
**Milestone:** CMOD-FFI1 (`docs/design/dcdart-c-ffi.md`)
**Files:** `core/plat/osgfx/osgfx.dart`, `osgfx_ffi.c`, `ffi_main.c`,
`core/scripts/build-preview-ui.sh`, `core/scripts/preview-ui.sh`
**Depends on** ADR-0080 (`osgfx.h` / Metal).
**Does not close** GAP-0313 items Graphite / Vulkan / Chromium.
**Number:** 0081 — 0080 is the C module; this is the DCDart call.

---

## 1. The question

The owner does not want a Mac UI program. The C module is oscortex.
DCDart calls it the way C calls Vulkan on this Mac. Preview is a
tool that shows the pixels.

## 2. The decision

1. **`osgfx.dart` `@extern`s `osgfx_ffi_*`.** Handles are `u64`
   (GAP-0025). `dcc --mode bare --target host` emits a Mach-O object.
   clang links it with `osgfx_metal.m`. One process, two compilers,
   a C ABI. That is JNI without Java.
2. **`osgfxFfiPaint` issues `create` / `clear` / `fill_rrect` /
   `flush` / `ppm`.** The harness PPM is that path, not a C scene
   hidden behind one call.
3. **`preview-ui.sh` runs `osgfx-ffi --preview` and `open -a Preview`
   on the PPM.** It does not launch a Cocoa desktop. `preview.html`
   stays leftover. `preview_main.m` is not the language.
4. **No syscall, no `.bss`, no `help` line.**

## 3. What this is not

It is not Skia Graphite. It is not Chromium. It is not a FRAME ELF.
It is not Flutter.

## 4. Verification

`core/tests/conformance/cmod-ffi1/run.sh` — Mach-O `osgfx_ffi.o`
names `osgfx_ffi_fill_rrect` and `osgfxFfiPaint`; the linked binary
names `osgfx_fill_rrect`; the PPM rrect corner is desktop.
