# ADR-0117 — Glyphs through osgfx: Start and osxui show 8.3 names

**Status:** accepted, implemented, verified (`tests/conformance/de-glyph/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-glyph (`docs/design/osx-ui.md`, GAP-0317 / GAP-0318)
**Files:** `core/plat/osgfx/osgfx_glyph.c`, `osgfx.h`,
`core/plat/osxui/osxui.h`, `osxui.c`, `headless_main.c`,
`core/kernel/wmde.dart`, `core/scripts/build-osxui.sh`,
`core/scripts/build-kernel.sh`,
`core/tests/conformance/de-glyph/`
**Depends on** ADR-0113 (osxui through osgfx), ADR-0108 (Start lists
FAT names), ADR-0106 (`wm de`).
**Does not close** a full caption kit (title strings, panel pids).
**Number:** 0117 — 0114–0116 are osgpu / parallel rungs.

---

## 1. The question

Start rows and the osxui label strip were colour bands. The 8.3
names were on serial. A second blit toolkit (Dart `wmFillRect` per
pixel, or a widget store) would not survive Skia replacing
`osgfx_sw.c`. Glyphs have to go through `osgfx.h`.

## 2. The decision

1. **`osgfx_fill_glyph` is the text hook.** New `.c` linked beside
   the software/Skia backends. Those files are not edited. The
   hook walks `fbFont8x16` bits and calls `osgfx_fill_rect(1,1)`
   per set pixel. Same packing as the console.
2. **`osxui_label` calls that hook.** Not `put_px`, not shm, not
   Flutter. `osxui_panel` stays a colour tile so `osxui4` AABB
   probes do not move. `--label ABCD` paints the stem on the strip.
3. **Start paints the 8.3 stem.** `wmLaunchDraw` calls
   `osxui_label_fb` (packed u64s, GAP-0025) after the row band.
   Glyphs sit at `wmLabelPadX/Y` so the row-centre colour probe
   (`de-sitfat`, `de-chrome`) stays the band. No `wm.dart` policy
   change. No new syscall. No help line.
4. **Anti-vacuity.** A link without `osgfx_fill_glyph` fails.
   Matching `WXYZ` or a bit-reversed font against planted `ABCD`
   fails. A colour tile has MATCH 0.

## 3. What this is not

It is not Skia text. It is not `String` (GAP-0035). It is not a
second box toolkit. It is not compositor chrome policy (ADR-0106).
Title-bar strings stay leftover.

## 4. Verification

`core/tests/conformance/de-glyph/run.sh` — host `--label ABCD`
matches `fbFont8x16` on the PPM; QEMU Start after `wm de` matches
the planted `ABCD.ELF` stem on the framebuffer; wrong font does
not; `osxui4` / `de-chrome` stay green.
