# ADR-0133 — OSXUI button paints live DE chrome

**Status:** accepted, implemented, verified (`tests/conformance/de-osxui/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE chrome / OSXUI-kit (`docs/design/osx-ui.md`, GAP-0318)
**Files:** `core/plat/osxui/osxui.h`, `osxui.c`, `osxui_fb.c`,
`headless_main.c`, `core/kernel/wmde.dart`,
`core/scripts/build-osxui.sh`, `core/scripts/build-kernel.sh`,
`core/plat/osgfx/osgfx_glyph.c` (weak `osxui_button_fb` for
`OSGFX_SKIA=0`), `core/tests/conformance/de-osxui/`
**Depends on** ADR-0113 (osxui through osgfx), ADR-0106 (`wm de`),
ADR-0117 (scanout `_fb` door).
**Does not close** title-bar / panel pid strings (GAP-0318 leftover 1).
**Number:** 0133 — 0130 is clone; 0131–0132 are reserved for parallel
rungs. No new syscall. 11 stays `fdwait`.

---

## 1. The question

`osxui_button` existed and called `osgfx_fill_rrect`. Live DE chrome
still painted Start / close / min with `wmFillRect`. Headers in
`core/plat` are not the OS. The running compositor has to call the
widget ABI on a live surface.

## 2. The decision

1. **`osxui_button_fb` is the scanout door.** Packed u64s (GAP-0025),
   same shape as `osxui_label_fb`. It calls `osxui_button` with a
   null `OsGfx`. That path calls `osxui_scan_button` (`osxui_fb.c`),
   which stores an rrect. A non-null `OsGfx` still calls
   `osgfx_fill_rrect` so `osxui4` is unmoved.
2. **`wm de` paints Start, close, and min through that door.**
   `wmOsxuiButton` in `wmde.dart`. Hit tests stay AABB so a click
   on the tile still works. Pixel restore uses `wmRrectHit` so the
   AABB corner stays chrome / title.
3. **Start is the named live control.** Radius `wmStartR` /
   `OSXUI_START_R` (4). Interior is `wmStartColor`. AABB corner is
   the strip. A leftover square blit paints the corner START and
   fails. A click still prints `WM DE START`.
4. **Anti-vacuity.** `OSXUI_STUB_BUTTON=1` makes `osxui_button` a
   no-op; the host Start interior stays chrome. `OSGFX_SKIA=0`
   keeps a weak `osxui_button_fb` so the link does not invent
   `osgfx_fill_rrect`.
5. **No new syscall. No help line. No second toolkit.** Graphite
   / Skia backend selection is untouched.

## 3. What this is not

It is not title-bar strings. It is not Graphite. It is not Flutter.
It is not `BTN.ELF`. Close / min also go through the same door so
`de-chrome` centre probes stay the button colour.

## 4. Verification

`core/tests/conformance/de-osxui/run.sh` — host `--chrome-start`
AABB is chrome and interior is START; stub button misses the
interior; after `wm de` the live framebuffer matches; a Start
click prints `WM DE START`.
