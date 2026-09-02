# ADR-0194 — The pointer is a Skia sprite, and a right-click is a hit class

**Status:** accepted, implemented
**Date:** 2026-08-31
**Milestone:** compositor composites; it does not invent a second painted DE
**Files:** `osgfx_skia.cpp` (`osgfx_pointer_raster`), `wm.dart`
(`wmPointerBlit` / `wmPointerEnsure`), `wmpop.dart` (`wmContextShow`),
`osgfx_session.c` (launch / title / slot menus), `desk.c` (named pills),
`proc.dart` (`procSlotName`), `wmext.dart` (`WM_SCREEN_NAME`)
**Depends on** ADR-0183 / ADR-0192 (DESK owns the strip), ADR-0187
(Skia outlines), ADR-0190 (session-debt; do not kick on every move),
ADR-0191 (chrome cache), ADR-0193 (abs tablet).
**Number:** 0194 — 0193 is the tablet door. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall.

---

## 1. The question

The owner still saw cursor dents after save-under, a global “set
background” menu on every right-click, and a compositor that painted
GUI (12×16 Dart arrow, Dart popover fills) next to Skia chrome.
DESK already owned the taskbar pixels. Titles, Start list, and
menus still lived in `wm` / session fallback as a parallel DE.

## 2. The measurement

* `wmPixelAt` answers `wmNoPixel` on session chrome. A 12×16
  save-under that missed a first walk, or a damage erase through
  `wmRepaintRect`, left the black/white bitmap bits on the title and
  the strip. That is the trail. Kicking the session to erase it
  reopens GAP-0333.
* `wmPopShow` ran on every right press. Empty desk, file row, title,
  and dead chrome were the same wallpaper menu.
* `mouseDrawCursor` is D1’s 12×16 bit stamp. It is not Skia.

## 3. The decision

1. **`osgfx_pointer_raster` once, blit after.** Skia draws a 16×20 AA
   arrow into the compositor state page during compose (shell /
   syscall). IRQ12 only blends the bitmap. Alpha 0 is skipped, so the
   sprite is not a slab. `d1-mouse` still uses `mouseDrawCursor` when
   the compositor is off.
2. **Save-under is 16×20, matching the sprite.** Restore puts those
   pixels back. When there is no capture, erase is `wmPixelAt` then
   the chrome cache — never a wallpaper stamp into a window. Every client
   damage path restores the sprite before resolving changed pixels and
   captures again only after the repaint; reversing that order writes stale
   pre-commit pixels over the client and can capture pointer AA as underlay.
3. **`wmContextShow` classifies the hit.** Empty desk → wallpaper
   (Regen / Image). Title → Close / Raise. Bar pill → Raise / Close.
   Window body → `WM CTX FILE` and a client click; no wallpaper menu.
   Start / note / dead chrome → nothing. Without `wm de`, ADR-0070’s
   empty box is unchanged (`osxui1-pop`).
4. **Session paints boxed menus in Skia.** Dart fills are skipped
   under `wm gfx`. Once DESK is attached, the session still does not
   paint a second taskbar or a second Start *button*. The Start *menu*
   is the launch popover (kind 2), Skia, with FAT stems from the
   state page. Wallpaper menu is only kind 1.
5. **DESK pills use real names.** Named spawn stamps `procSlotName`.
   `WM_SCREEN_NAME` returns the 8-byte stem. Fallback `W0` only when
   the stem is empty.

`wm` keeps input route, blit, damage, z-order, focus slots. It does
not invent a second painted taskbar.

## 4. Binary exit

`de-desk`, `de-session`, `de-retain` PASS. New tokens: `WM PTR SKIA`,
`WM CTX FILE` / `TITLE` / `SLOT` / `NONE`, `WM WALL MENU` only on
empty desk. Start still prints `WM DE START` and spawn-by-name is
`wmDeSpawnRow`. PNG at `core/build/tigervnc-live-now.png`.
Syscall 11 unchanged.

## 5. Leftover

This is not Flutter: no widget tree, no Material, no layout. File-row
*actions* (rename / open) are still the client’s left-click path;
right-click on a row only refuses the wallpaper menu and enqueues the
press. Title chrome (pearl band, traffic lights) is still session
Skia, not a DESK surface. A 16×20 sprite is still compositor-placed,
not a client surface. After M1, `isr_common` masks IRQ0 and STI
around `osgfx_guest_tick` so a popover kick does not freeze the
8042 for the length of a Skia present.
