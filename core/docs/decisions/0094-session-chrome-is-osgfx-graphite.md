# ADR-0094 — Session chrome is painted through osgfx Graphite

**Status:** accepted, implemented, verified (`tests/conformance/gfx2-compose/run.sh`)
**Date:** 2026-08-30
**Milestone:** COMPOSE0 / GFX-COMPOSE (`docs/design/c-modules.md`, `docs/design/osx-ui.md`)
**Files:** `core/plat/osgfx/osgfx.h`, `osgfx_scene.c`, `osgfx_scene.h`,
`headless_main.c`, `osgfx_ffi.c`, `osgfx.dart`,
`core/tests/conformance/gfx2-compose/`
**Depends on** ADR-0080 (`osgfx.h`), ADR-0081 (DCDart FFI), ADR-0082 (Graphite).
**Does not close** GAP-0313 leftover: Graphite / Vulkan **in the running OS
image**. Sit-in still fills axis-aligned rects in `wm.dart` /
`wmchrome.dart` / `wmpop.dart`.
**Number:** 0094 — 0092 is NVM6; 0093 is G8. Do not reuse 0082.

---

## 1. The question

GFX0/GFX1 proved `osgfx.h` on Graphite with two rounded windows. The
session a person sits in — desktop, taskbar, title bars, two windows,
focus/unfocus borders, popover — was still a second CPU box painter
in the kernel, or a preview scene that omitted compositor policy.
The owner wants that chrome painted **only** through `osgfx.h`
(Graphite). Apps stay 64 KiB ELFs. They do not embed Skia.

This Mac cannot link Metal/Graphite into `kernel.elf`. Claiming
sit-in is Graphite would be a lie.

## 2. The decision

1. **`osgfx_scene_compose` is the session.** Same colours and sizes
   as the kernel compositor: desktop `0x00184060`, chrome
   `0x00C09048` H=24, title `0x00D8B060` H=18, popover `0x00C04088`
   96×64, focus `0x00F0F0F0`, unfocus `0x00505860`, border=3,
   radius 14. Windows and the popover are `fill_rrect` + `shadow`.
   `--square` is the axis-aligned negative.
2. **The assigned binary is the host harness**, not QEMU.
   `gfx2-compose/` runs `osgfx-headless --compose`, requires
   `BACKEND graphite`, `nm` names `skgpu::graphite`, and samples
   derived policy pixels. `OSGFX_FORCE_METAL=1` is the negative
   that must not count as this PASS.
3. **Preview is the same scene.** `osgfxFfiPreview` calls
   `osgfx_ffi_scene_compose`. `preview-ui.sh` still opens a PPM.
   It is not a Cocoa desktop.
4. **Sit-in goldens do not move.** `d2-compositor`, `d8-chrome`,
   `d8-title`, `d7-click` keep exact-rect CPU fills. No guest path
   is turned on. No new syscall. 11 stays `fdwait`. No help line.
   No last `.bss`.

## 3. What this is not

It is not Graphite in `kernel.elf`. It is not Vulkan (GFX2 in
`c-modules.md` is still MoltenVK). It is not Flutter. It is not
`preview.html`. It is not a FRAME ELF that contains Skia.

## 4. Verification

`core/tests/conformance/gfx2-compose/run.sh` — Mach-O arm64,
`nm` has `osgfx_scene_compose` and a Graphite symbol, default
`--compose` prints `BACKEND graphite` and policy pixels match,
`--square` AABB is title, `OSGFX_FORCE_METAL=1` is metal.
