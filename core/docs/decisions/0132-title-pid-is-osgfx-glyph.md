# ADR-0132 — Title-bar PID is an osgfx glyph

**Status:** accepted, implemented, verified (`tests/conformance/de-title/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-title leftover after ADR-0117 (`docs/design/osx-ui.md`,
GAP-0318)
**Files:** `core/kernel/wmde.dart`,
`core/tests/conformance/de-title/`
**Depends on** ADR-0117 (`osgfx_fill_glyph` / `osxui_label_fb`),
ADR-0075 (title bars), ADR-0106 (`wm de`).
**Does not close** live hex pids on the reflection panel, or
`osxui_button` on a client surface.
**Number:** 0132 — 0130 is clone. 0131 is unused. Do not reuse 0117.

---

## 1. The question

Start rows show 8.3 stems through `osgfx_fill_glyph` (ADR-0117). The
title strip was still a colour band. A second blit (`put_px`, Dart
per-pixel `wmFillRect`) would not survive Skia replacing the software
backend. The caption has to go through the same hook.

`d8-title` photographs `wm chrome` alone. `sit-in` / `de-resize` /
`de-wm` sample the gold fill at `x+20` and `x+40`. Glyphs that land
there move those probes.

## 2. The decision

1. **`PID` is the title stem.** Three `@rodata` bytes. Not `String`
   (GAP-0035). `wmTitleLabelDraw` calls `osxui_label_fb` after the
   close/min buttons. Same packed u64s as Start (GAP-0025).
2. **Gated on `wm de`, skipped under `wm gfx`.** `wm chrome` alone
   stays the exact-rect caption (`d8-title`). Sit-in rrect title
   probes stay the fill. No new syscall. 11 stays `fdwait`. TAP/FILES
   stay 64 KiB / 2 MiB. No help line.
3. **Pad is compositor policy.** `wmTitlePadX = 48`, `wmTitlePadY = 1`,
   dark ink `0x00101820`. Past the sit-in / de-resize / de-wm colour
   probes. Left of close/min. Host model reads the constants.
4. **Anti-vacuity.** Host `--label` off: the sample is the gold
   title/panel fill, not the letter. Wrong font / `WXYZ` do not match.
   A link without `osgfx_fill_glyph` still fails (ADR-0117).

## 3. What this is not

It is not Skia text. It is not Graphite. It is not `put_px`. It is not
a live hex pid on the reflection panel. It is not a configure event
(GAP-0308).

## 4. Verification

`core/tests/conformance/de-title/run.sh` — host `--label PID` matches
`fbFont8x16` on the gold strip; without the label the same pixel is
the fill; QEMU after `wm de` + `WIN.ELF` matches `PID` on the title
bar; sit-in / de-wm probes stay the title colour.
