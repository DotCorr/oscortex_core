# ADR-0196 — One Skia AA card, CSD on FRAME apps, proved rename

**Status:** accepted, implemented
**Date:** 2026-09-01
**Milestone:** compositor composites; it does not invent a second painted DE
**Files:** `osgfx.h` / `wmgfx.dart` (modest radius 8, lockstep),
`osgfx_chrome.c` (top-corner hole matches the card), `osgfx_session.c`
(all four card corners), `osxui_app.h` (frost CSD), `files.c` (rename
updates the list), `set.c` / `tap.c` / `browse.c` / `studio.c` /
`ping.c` (`osxui_app_csd`), `desk.c` (space; hide notes), `wm.dart`
(`wmOverlayRestore`)
**Depends on** ADR-0195 (CSD door, DESK menus). Does not reopen
ADR-0190–0195.
**Number:** 0196 — 0195 is titles leaving the session. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall.

---

## 1. The question

ADR-0195 left a card-stroke / blit-inset fight: CSD made the title a
full-width client hole while `wmBlitRow` still inset the top corners,
so wallpaper showed as teeth at the radius. Only FILES and SET painted
CSD. Rename existed as `stem.REN` but was not driven. Overlay hide was
“do not compose.” The owner still saw junk.

## 2. The measurement

* `OSGFX_RADIUS` was 12, `OSGFX_BLIT_INSET` / `wmGfxRadius` were 14.
  A square 14×14 cutout against a 12px stroke is wallpaper teeth.
* `chrome_body_span` with `OSGFX_GUEST_PANEL` treated the whole title
  as a hole, so `paint_body_corners` (bottom only) never closed the
  top pair after chrome present.
* FILES `do_file_rename` issued syscall 32 and printed `FILES RENAME`
  only if a harness clicked Rename — de-desk clicked Open only, and
  the on-screen list kept the old stem.
* `wmDrawWindow` skipped the 160×88 overlay when pop was off and did
  not restore the rectangle. MOVE parked the card at (8,8).

## 3. The decision

1. **One modest AA card.** Radius is 8 in `OSGFX_RADIUS`,
   `OSGFX_BLIT_INSET`, and `wmGfxRadius`. Session paints all four
   `osgfx_card_corners` (top pair pearl). Chrome present insets the
   top corners even under CSD so the cache owns the curve. The outline
   is still one `osgfx_card_stroke`.
2. **CSD on every titled FRAME app that attaches a window.** Same
   `osxui_app_csd` door: FILES, SET, TAP, BROWSE, STUDIO, PING.
   Session still withdraws titles when `OSGFX_GUEST_PANEL`. PLAY stays
   64×64 — `kmedia` finds that size; it is not a titled card.
3. **Rename runs.** File-row Rename commits `stem.REN`, updates
   `dotted[]`, and FILES repaints the new name. de-desk clicks the
   second menu row and greps `FILES RENAME`.
4. **Frost, not a widget tree.** CSD is a rounded pearl vgrad +
   glass sheen (elevate blur stays on the strip/menus — a per-app
   blur starved the 3MiB bump). File rows and PING fill are slate,
   not stamp-orange. Start stays `C87840` and identifiable; the strip
   has more inset and slot gap. Client paint reclaims the bump past
   half so Open+Rename cannot print `OSGFX OOM` (not on the pointer
   blit — that purge held IF; only after the Graphite watermark, and
   only when <384KiB remains). The Skia bump is 4MiB so a session
   wall-menu present with two titled cards still fits.
5. **Overlay hide restores pixels.** `wmOverlayRestore` walks overlay
   slots and `wmRepaintRect`s them from `wmPixelAt` when pop turns
   off. Token `WM OVERLAY CLEAR`.

## 4. Binary exit

`de-desk` 100, `de-session` 70, `de-retain` 36. New tokens:
`SET CSD`, `TAP CSD`, `BROWSE CSD`, `STUDIO CSD`, `PING CSD`,
`FILES RENAME`, `WM OVERLAY CLEAR`. Corner AA probe on FILES and on
session window A. Syscall 11 unchanged. PNG at
`core/build/tigervnc-live-now.png`.

## 5. Leftover

PLAY is still a 64×64 media surface (overlay-sized) with no CSD.
Rename is stem.REN, not an in-place field. No widget tree. Start is
still the probe copper. Pointer is still compositor-placed. Homebrew
still cannot arm Venus. Glass is one sheen step, not a material.
