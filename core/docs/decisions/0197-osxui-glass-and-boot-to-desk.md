# ADR-0197 — osxui glass language and boot-to-desk

**Status:** accepted, implemented
**Date:** 2026-09-01
**Milestone:** compositor composites; the desk shell paints the DE
**Files:** `osxui.h` / `osxui.c` / `osxui_app.h` (glass, island, icon
button, clock), `desk.c` (split dock + `spawn`), `set.c` / `files.c`
(glass chrome), `wm.dart` (panel skip-0 blit, dock `wmevent`),
`wmde.dart` (hamburger Start; no note/slot steal), `wmgfx.dart`
(`wmPanelSlot`), `sit-in.sh` / `sit-in-view.sh` (DESK only),
`de-desk/` / `de-deskboot/`
**Depends on** ADR-0196 (one AA card, CSD). Does not reopen
ADR-0187–0196.
**Number:** 0197 — 0196 is the modest card. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall.

---

## 1. The question

The owner attached five mockups. Those are the osxui language: frosted
glass panels, a floating **split dock**, large radii on islands, airy
padding, colourful simple icons, glass windows with sidebar + pane.
Cold boot was FILES (and SET) already open on an orange Start strip.
That is not a desktop.

## 2. The measurement

* `sit-in.sh` / `sit-in-view.sh` typed `proc spawn FILES.ELF` and
  `SET.ELF` after DESK. The first frame was a file manager.
* DESK painted a full-width slate band and a copper `Start` pill
  (`C87840`). `wmBlitRow` copied every panel pixel, so the strip
  occluded wallpaper edge-to-edge.
* `wmChromeHit` swallowed the whole band; DESK never saw icon presses.
* SET was orange/green toggle bars. FILES rows were slate bands.

## 3. The decision

1. **Glass is osxui.** `osxui_glass` / `osxui_island` / `osxui_icon_btn`
   / `osxui_clock` (C ABI) and the same names on `osxui_app.h` (FRAME
   paint ops). Elevation + light vgrad + hairline. Not Dart-stamped
   chrome. `wm` composites.
2. **Split dock.** DESK still attaches the panel slot (full width,
   `h <= 48`, flush bottom) so the session fallback withdraws. It
   paints two islands and leaves the rest 0. `wmBlitRow` skips 0 on a
   panel so wallpaper shows between them.
3. **Cold boot is empty.** sit-in and sit-in-view spawn `DESK.ELF`
   only. FILES / SET / BROWSE / PLAY / STUDIO / TAP open from dock
   icons via syscall 26. de-session may still spawn its own clients.
4. **Hamburger is Start.** With a panel, `wmStartHit` is the left-island
   menu (x 244–280). Note and slot hits are off so they do not steal
   icons. Other strip presses enqueue to DESK.
5. **Window card radius stays 8** (ADR-0196 lockstep). Islands use
   radius 20. Settings gets a sidebar + Appearance/facts pane in the
   same glass CSD. FILES rows are light glass cards.

## 4. Binary exit

`de-deskboot` — no FILES surface until a dock click; dock hit launches
FILES; SET opens glass settings. `de-desk` still PASS (CSD, rename,
contextual, Start). `de-retain` still PASS. PNG
`core/build/tigervnc-live-now.png` is wallpaper + glass islands.
Syscall 11 unchanged.

## 5. Leftover

True backdrop blur landed in ADR-0198 (`osgfx_glass_frost`). Live
clock/weather are still static mockup strings. Dashboard / browser
chrome remain later. Window chrome radius moved to 18 with ADR-0198.
