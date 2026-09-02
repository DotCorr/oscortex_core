# ADR-0198 — Frosted glass blur, mockup radius, Settings Appearance

**Status:** accepted, implemented
**Date:** 2026-09-01
**Milestone:** compositor composites; the desk shell paints the DE
**Files:** `osgfx_desk.c` (`osgfx_glass_frost`), `osgfx.h` /
`wmgfx.dart` (radius 18 lockstep), `wmext.dart` / `osframe.h`
(`WM_PAINT_GLASS`), `osxui_app.h` / `desk.c` (frost islands + icon
glyphs), `set.c` (Appearance / Devices glass chrome, blue accent),
`de-desk` / `de-deskboot` / `de-set` / `gfx0` / `gfx2` / `de-session`
**Depends on** ADR-0197 (glass language, boot-to-desk). Does not
reopen ADR-0196’s lesson: radius, blit inset, and `wmGfxRadius` move
together.
**Number:** 0198 — 0197 is boot-to-desk. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall.

---

## 1. The question

ADR-0197 left islands as a flat `F4F6FA` fill, window cards at radius
8, dock icons as coloured squares, and Settings still orange/green
because `de-set` probed those hexes. The attached mockups want real
frost (wallpaper through the panel), ~16–24 corner radius, readable
dock glyphs, and Appearance / Devices pages.

## 2. The measurement

* Island pixels were one colour; `DESK ISLE` reported the fill stamp.
* `OSGFX_RADIUS` / `OSGFX_BLIT_INSET` / `wmGfxRadius` were 8.
* Dock icons were `osxui_app_icon_btn` solid rrects.
* `CTL_ON` / `CTL_OFF` were `E07020` / `305070`.

## 3. The decision

1. **`WM_PAINT_GLASS`.** One paint kind. The compositor packs the
   surface’s screen origin into the colour word; `osgfx_glass_frost`
   (always linked in `osgfx_desk.c`) samples the wallpaper cache (or
   generative fallback), 5×5 box-blurs, tints, and writes the caller’s
   shm. Skip-0 blit still shows wallpaper *between* islands.
2. **Radius 18** in `OSGFX_RADIUS`, `OSGFX_BLIT_INSET`, and
   `wmGfxRadius`. CSD uses the same card radius.
3. **Dock glyphs.** Gear / folder / globe / note / paper / tools from
   stacked rrects — not random coloured squares.
4. **Settings.** Sidebar + Appearance (theme grid, mode, accent) and
   Devices cards. Accent toggle is glass blue (`4080E0`) vs slate idle.
   `de-set` / `de-set2` derive the new hexes; they no longer pin orange.

## 4. Binary exit

`de-deskboot` — frost vary line, dock launches, Appearance/Devices in
`set.c`. `de-desk` — blur proof (island samples not one flat colour),
radius lockstep 18, icon glyphs. `de-set` — blue accent toggle still
flips; miss leaves it idle. `de-retain` still PASS. PNG
`core/build/tigervnc-live-now.png`. Syscall 11 unchanged.

## 5. Leftover

Live clock/weather still static strings. Dashboard widgets and
browser chrome are not this file. Skia `SkImageFilters` backdrop blur
is not linked — frost is a 5×5 box blur of sampled wallpaper (same
visual claim, CPU). Window body fill in SET is light opaque cards,
not sampled frost (toggle probes need exact hexes). Devices list is
planted labels, not live HID inventory. Soft-shadow elevate stays
capped at radius 8 even when the card is 18 — larger MaskFilter
elevate #GP'd `SkResourceCache` under wall-menu presents (de-retain).
