# ADR-0096 — Skia CPU raster is not the product (withdrawn)

**Status:** superseded by ADR-0097. CPU raster in the kernel image
is a workaround the owner rejected. Sit-in no longer builds it.
Preview deletion in §2.1 still holds.
**Was:** accepted, implemented, verified (`tests/conformance/gfx3-guest/run.sh`)
**Date:** 2026-08-30
**Milestone:** GUEST0 (`docs/design/c-modules.md`, `docs/design/osx-ui.md`)
**Files:** `core/plat/osgfx/osgfx_guest_skia.cpp`, `osgfx_cmd.c`,
`osgfx_guest_crt.c`, `core/kernel/wmgfx.dart`,
`core/scripts/build-skia-guest.sh`, `core/scripts/sit-in.sh`,
`core/tests/conformance/gfx3-guest/`
**Depends on** ADR-0080 (`osgfx.h`), ADR-0094 (compose policy).
**Does not close** GAP-0313 leftover: Graphite / Metal / Vulkan **in the
guest**. This is Skia **CPU raster** in the OS image, x86_64-elf, not
the Mac arm64 Metal `libskia.a`.
**Number:** 0096 — 0093 is G8, 0094 compose, 0095 chrome FFI.

---

## 1. The question

Sit-in was axis-aligned boxes. Host Graphite preview was a second
window the owner was told to look at instead of QEMU. Metal cannot
link into `kernel.elf`. A Dart software rrect labeled “Skia” would
be a lie.

## 2. The decision

1. **Preview is gone.** `preview-ui.sh`, `preview_main.m`, and
   Preview.app as the UI are deleted. Host harnesses
   (`gfx0` / `gfx1` / `gfx2-compose` / `cmod-ffi1`) still prove the
   module. `sit-in.sh` boots the OS.
2. **`wm gfx` is the guest path.** `wm chrome` stays exact rects
   (d2 / d8 / d7). `wm gfx` sets chrome plus spare word 23, fills a
   mailbox at `kernel_data_start()`, and does not add an `@extern`
   (44 stay 44). IRQ0 in `isr.S` calls `osgfx_guest_tick`.
3. **Skia CPU raster writes the scanout.** `osgfx_guest_skia.cpp`
   calls `SkCanvas::drawRRect` into the guest framebuffer. The
   archive is `build/skia/out/guest/libskia.a` built
   `--target=x86_64-unknown-none-elf`. Client ELF pixels stay;
   chrome (title, border, shadow, taskbar) is Skia.
4. **No help line. No new syscall.** 11 stays `fdwait`.
   `wmeventStore` stays last `.bss`. No commit in this slice.

## 3. What this is not

It is not Graphite in QEMU. It is not Metal. It is not the host
`libskia.a`. It is not a Dart fill_rect.

## 4. Verification

`core/tests/conformance/gfx3-guest/run.sh` — guest `kernel.elf`
`nm` names a Skia / `drawRRect` symbol; `wm gfx` AABB corner is
desktop; title and taskbar match policy; `wm chrome` on the same
kernel still has a square title corner.
