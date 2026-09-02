# ADR-0195 — Titles and menus leave the session

**Status:** accepted, implemented
**Date:** 2026-08-31
**Milestone:** compositor composites; it does not invent a second painted DE
**Files:** `files.c` / `set.c` (CSD), `desk.c` (menu overlay),
`osgfx_session.c` (withdraw title+menu when `OSGFX_GUEST_PANEL`),
`osgfx_chrome.c` (title rows are a client hole under CSD), `wm.dart`
(`wmIsOverlay`, `wmWinOverlay` so `wmHit` skips the card, blit title
when DESK is up), `wmevent.dart` (type 5),
`wmext.dart` (`WM_SCREEN_POP` / `WM_SCREEN_LAUNCH`),
`osgfx_graphite_guest.cpp` (empty MakeVulkan skipped),
`osgfx_skia.cpp` (canvas destroyed before bump rewind),
`wmpace.dart` (chrome sig omits pop/overlay geom while the panel is up)
**Depends on** ADR-0192 (DESK owns the strip), ADR-0194 (hit-classed
right-click). Does not reopen ADR-0190–0194.
**Number:** 0195 — 0194 is the pointer and the hit class. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. Type 5 is a packed `wmevent`
on 25.

---

## 1. The question

ADR-0194 left titles, traffic lights, and boxed menus in
`osgfx_session_paint`. The owner said the compositor must not own a
parallel UI. File-row right-click refused the wallpaper menu and
enqueued a left press. First `wm de` compose still took `#GP`
(`FAULT 0D OP 488B`) and printed `FAULT RECOVERED`.

## 2. The measurement

* Session painted the pearl band and the two discs after DESK had
  already committed the only taskbar. Two titles, same as the two
  strips GAP-0329 named.
* `wmeventPack` is type 1. FILES never popped 25, so a row right-click
  could not become Open / Rename.
* First `wm de` compose printed `FAULT 0D OP 488B` then
  `FAULT RECOVERED`. The session tick leaves a `MakeRasterDirect`
  canvas in `g_one.owned`. `client_body` (pointer blit after `wm gfx`,
  and every `WM_OP_PAINT`) then rewound the shared bump heap while
  that canvas was still live. The next `owned.reset()` loaded a vptr
  from reclaimed scratch (`48 8B`). After the tick-only fix the same
  load moved to the idle IRQ0 tick that follows `WM FRAME`.

## 3. The decision

1. **CSD titles.** FILES and SET paint the pearl band, traffic lights
   and caption into their own shm through `osxui_app_csd` (osxui/Skia).
   `wm` still hit-tests the band (drag / close / min). Once
   `OSGFX_GUEST_PANEL` is set, session skips `paint_de_title_controls`
   and the title `osgfx_card`. `wmBlitRow` blits those 32 rows.
   `chrome_body_span` treats them as a client hole so the cache does
   not stamp wallpaper over CSD.
2. **DESK is the only compositor menu surface.** Wallpaper / launch /
   title / slot cards are a 160×88 overlay DESK attaches and moves
   (`WM_OP_MOVE`, already on 23). `WM_SCREEN_POP` publishes kind+xy;
   `WM_SCREEN_LAUNCH` publishes FAT stems. A short non-panel surface
   is `wmIsOverlay`: composed only while a popover is showing, never
   win0/win1, never a pill. Session paints those cards only when
   DESK is not up (the same fallback the strip already is).
3. **FILES owns the file menu.** Kind 4 enqueues `wmevent` type 5.
   FILES paints Open / Rename in its shm and runs the item. DESK
   does not invent a second file menu.
4. **Destroy every Skia canvas before every bump rewind.**
   `drop_skia_before_rewind` resets `g_one` and `client_g`, purges
   caches, then rewinds. Both `tick_body` and `client_body` call it.
   Empty `MakeVulkan` is also not called (Homebrew `NONE`; live door
   is `m->vk != 0`).

`wm` keeps route, blit, damage, z-order, focus. It does not paint a
second title or a second menu once DESK/CSD is attached.

## 4. Binary exit

`de-desk` 90, `de-session` 67, `de-retain` 36. New tokens:
`OSGFX SESSION CHROME CLIENT`, `FILES CSD`, `FILES MENU`,
`FILES OPEN` / `FILES RENAME`, `DESK MENU`. File-row right-click is
still `WM CTX FILE` and is not `WM WALL MENU`. Syscall 11 unchanged.
PNG at `core/build/tigervnc-live-now.png`.

## 5. Leftover

This is not a full DE. No widget tree, no layout, no Material.
CSD has a pearl sheen and a hairline; slot pills have modest
radius and a drop; DESK frost cards (radius 8) are the boxed
menus. Probe colours (Start `C87840`, strip edges) are unchanged.
Browse / studio / other FRAME apps do not paint CSD yet — without
DESK the session fallback still titles them; with DESK they have
a card stroke and no pearl band until they call `osxui_app_csd`.
Rename is stem.REN, not an in-place text field. The 16×20 pointer
is still compositor-placed. Overlay hide is "do not compose", not
a detach; `wmHit` skips the card so a parked overlay cannot steal
wallpaper or a file-row. When the panel is up, `wmGfxChromeSig`
omits pop and overlay geom so a Start or `WM_OP_MOVE` does not
kick a full generative desk (that raster held IF and raced
`drop_skia` — `FAULT 0D OP 488B`). Homebrew still cannot arm Venus.
