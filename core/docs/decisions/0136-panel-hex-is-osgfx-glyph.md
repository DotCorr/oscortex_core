# ADR-0136 — Reflection-panel hex pid is an osgfx glyph

**Status:** accepted, implemented, verified (`tests/conformance/de-panel/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-panel leftover after ADR-0132 (`docs/design/osx-ui.md`,
GAP-0318)
**Files:** `core/kernel/wmde.dart`, `core/plat/osxui/osxui.h`,
`osxui.c`, `headless_main.c`, `core/plat/osgfx/osgfx_glyph.c`
(`osxui_hex_fb` next to `osxui_label_fb`),
`core/tests/conformance/de-panel/`
**Depends on** ADR-0117 (`osgfx_fill_glyph` / `osxui_label`),
ADR-0132 (title-bar `PID`), ADR-0106 (`wm de`).
**Does not close** configure-to-client (GAP-0308), or Graphite text.
**Number:** 0136 — 0132 is title `PID`. 0133 is live Start. 0134–0135
are unused. Do not reuse 0132. No new syscall. 11 stays `fdwait`.

---

## 1. The question

Title-bar `PID` is three `@rodata` bytes through `osxui_label_fb`
(ADR-0132). The reflection panel still printed the live owner as
serial `WM DE SURF … PID …` and left the row a colour tile. A second
blit (`put_px`, Dart per-pixel `wmFillRect`) would not survive Skia
replacing the software backend. The hex has to go through the same
hook.

`de-chrome` / `de-wm` sample the row fill at `panel_x+10`. Glyphs
that land there move those probes.

## 2. The decision

1. **`osxui_hex` formats eight digits and calls `osxui_label`.** Not
   `String` (GAP-0035). `wmPanelPidDraw` calls `osxui_hex_fb` after
   the row fill. Same packed u64s as Start / title (GAP-0025). The
   value is `wmWinOwner`, eight digits, same as `uartPutHex(owner, 8)`.
2. **Gated on `wm de`, skipped under `wm gfx`.** Sit-in rrect / row
   probes stay the fill. No new syscall. 11 stays `fdwait`. TAP/FILES
   stay 64 KiB / 2 MiB. No help line.
3. **Pad is compositor policy.** `wmPanelPadX = 16`, `wmPanelPadY = 5`,
   light ink `0x00F0F8FF`. Past the de-chrome / de-wm colour probe at
   `+10`. Host model reads the constants; `osxui.h` `OSXUI_REFL*`
   matches.
4. **Anti-vacuity.** Host `--panel` without `--label`: the sample is
   the panel/row fill, not the letter. Wrong font / `WXYZ` do not
   match. A link without `osgfx_fill_glyph` still fails (ADR-0117).

## 3. What this is not

It is not Skia text. It is not Graphite. It is not `put_px`. It is not
the title-bar stem (ADR-0132). It is not a configure event (GAP-0308).

## 4. Verification

`core/tests/conformance/de-panel/run.sh` — host `--panel --label DEADBEEF`
matches `fbFont8x16` on the blue row; without the label the same pixel
is the row fill; QEMU after `wm de` + `WIN.ELF` + notify click matches
the serial hex pid on the panel; de-chrome row probe stays the fill.
