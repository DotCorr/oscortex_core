# ADR-0192 — The desk shell paints the only taskbar, and an app's text is the OS's outlines

**Status:** accepted, implemented (`wmOpScreen` / `wmOpPaint` in
`core/kernel/wmext.dart`; `wmIsPanel` / `wmDecoX` / `wmDecoY` and the
panel case in `wmBlitRow` / `wmGfxCornerHole` in `core/kernel/wm.dart`;
`wmPanelStrip` + `osgfxGuestPanel` in `core/kernel/wmgfx.dart`;
`OSGFX_GUEST_PANEL` honoured in `core/plat/osgfx/osgfx_session.c`;
`core/user/frame/osxui_app.h`; `OSFRAME_START` in
`core/user/frame/osframe.h`; `core/user/frame/desk.c`, `files.c`, `set.c`)
**Date:** 2026-08-31
**Depends on** ADR-0051, ADR-0053, ADR-0106, ADR-0111, ADR-0183,
ADR-0187, ADR-0188, ADR-0189, ADR-0191.
**Finishes** ADR-0183, whose "the DE owns the strip" was recorded as
UNFINISHED because the strip was `osgfx_session.c`'s.
**Extends** ADR-0187 from chrome text to *client* text.
**Closes** GAP-0329 (two taskbars).
**Opens** GAP-0339 (a FRAME `_start` was 8 mod 16 and any SSE spill in
the call tree raised #GP — that is what "`osxui_button_fb` hangs in-ELF"
actually was).
**Number:** 0192. No new syscall. 23 stays `wmsurface`, 11 stays
`fdwait`.

---

## 1. Decision

**The taskbar is `DESK.ELF`'s pixels, at whatever size the screen is,
and the compositor's own strip is a fallback that withdraws when a
client has taken the slot.** Three statements, each of which was
missing:

1. **A client may ask how big the screen is.** `wmsurface` op 9
   (`wmOpScreen`) answers `(w << 32) | h` for the LIVE scanout in `rax`,
   and `WM_SCREEN_TASKS` answers the window table as four packed bytes.
   Before this a FRAME app could not know either, which is why `desk.c`
   froze `SURF_Y 549` / `WIN_W 794` — the 800x600 bottom slot — and why
   its bar hung in the middle of a 1280x720 desktop.
2. **A client may draw with the OS's rasteriser.** `wmsurface` op 10
   (`wmOpPaint`) takes one `osgfx.h` primitive — AA rrect, vertical
   `SkShaders::LinearGradient`, `SkMaskFilter::MakeBlur` elevation,
   a Roboto outline run, or a measure — and applies it to a surface the
   caller already owns. Same rasteriser, same font table, same
   antialiasing as the compositor's chrome.
3. **A panel is a first-class geometry.** `wmIsPanel` grants exactly one
   shape — full scanout width, flush bottom, no taller than the chrome
   band — and the compositor stops treating that surface as a card:
   no border, no title band, and (this ADR's last fix) no rounded-corner
   blit inset.

## 2. Why not the other split

The alternative was to keep the strip in `osgfx_session.c` and delete
DESK's. It would have looked identical and it is the wrong answer for a
reflective OS: the compositor would keep *inventing* chrome no program
asked for, and the SDK an app is supposed to use to build a shell would
still be untested by the shell. ADR-0183 already argued this. What was
missing was not the argument, it was op 9 and op 10.

The fallback strip is **kept**, because `Start` has to be on the screen
between `wm de` and the first `DESK.ELF` commit, and on a boot with no
`DESK.ELF` on the volume at all. `de-session` asserts it is still there
when no client panel is up; `de-desk` asserts it is gone when one is.

## 3. How "exactly one" is decided, in pixels rather than by policy

`wmPanelStrip` (`wmgfx.dart`) scans the window table for a *usable*
window that has committed at least one frame (`wmWinSeq > 0`) and whose
geometry satisfies `wmIsPanel`. If there is one, `wmGfxKick` sets bit 3
(`OSGFX_GUEST_PANEL`) in the mailbox flags. `paint_de_strip` is then
skipped and the desk wallpaper is extended down to the bottom edge, so
the region under DESK's surface is desktop rather than a second bar.
The compositor says so on COM1 once:

    OSGFX SESSION STRIP CLIENT

The test is committed pixels, not "a process called DESK exists": a
client that attaches a panel and dies before committing does not take
the strip away, and one that exits gives it back.

## 4. An app's text is the OS's outlines

`FILES.ELF`'s rows and `SET.ELF`'s labels called `osxui_label_fb`: an
8x16 bitmap cell per character, one fixed advance, inside a window whose
title bar ADR-0187 had already made a live outline. They now call
`osxui_app_label_box`, which measures through `wmOpPaint`
(`WM_PAINT_MEASURE`) and fills through `WM_PAINT_TEXT`.

The proof is arithmetic a harness can read, not a screenshot judgement.
An 8x16 cell makes an `n`-character run exactly `8 * n` pixels wide and
nothing else can. Both programs print what the OS laid down beside what
the cell would have been:

| run | glyphs | cell would be | outline advance |
|---|--:|--:|--:|
| `FACTS.DAT` (`FILES.ELF` row, 14px regular) | 9 | 72 | **62** |
| `Start` (`DESK.ELF`, 14px medium) | 5 | 40 | **30** |

`de-desk` fails if the advance is 0 (nothing drawn) or equal to the cell
(still a bitmap). The compositor prints `OSGFX CLIENT TEXT OUTLINE ADV n
PX` from inside the rasteriser for the same reason.

## 5. `osxui_button_fb` does not hang, and `sqrtf` was never the cause

`desk.c`'s header said the call "HUNG in-ELF" and its pills were
hand-written solid spans because of it. ADR-0187 fixed an infinite
`sqrtf` recursion and that was the obvious suspect. It is not the cause:
there is no float anywhere on the path, which is `osxui_button` →
`osxui_scan_button` → an integer `rrect_hit` span walk.

What happened is that clang vectorises that span walk and spills the
hoisted vector constants with `movdqa %xmm0,-0xc0(%rbp)`. A FRAME app's
`_start` was a plain C function, so it assumed a `call` had pushed a
return address; the kernel enters ring 3 by `iretq` with a 16-aligned
RSP, so `%rbp` came out 8 mod 16 and that aligned store raised #GP(0)
the first time it executed:

    FAULT 0D ERR 0000000000000000 OP 660F
    USER FAULT VEC 0D ... RIP 0000000010002C62 CPL 3
    PROC KILL SLOT 00

The process was reaped. From outside, a killed process and a wedged one
are the same silence, which is how this got recorded as a hang.
`OSFRAME_START` (`osframe.h`) is now the entry: a three-instruction shim
that hands the initial stack pointer to a C function through RDI and
`call`s it, which is what leaves RSP where the ABI says. `DESK.ELF`
calls `osxui_button_fb` on every boot, reads the pixel back and prints
it:

    DESK BTNFB ENTER
    DESK BTNFB RETURN
    DESK BTNFB PIXELS FF00FF

`de-desk` requires all three. ENTER without RETURN is the hang, and it
would fail.

## 6. A panel is not a card

Under `wm gfx`, `wmBlitRow` insets a client's first and last
`wmGfxRadius` rows by that many columns, so a square client body cannot
stamp over the rounded card `paint_window_chrome` strokes around it
(ADR-0188). A panel gets no card — that function returns early for
anything no taller than the chrome band — so the inset was pure loss: 14
columns off both ends of the taskbar on 28 of its 48 rows, with
wallpaper showing through at the screen edge. `wmBlitRow` and
`wmGfxCornerHole` (the damage path, which must agree with it pixel for
pixel) now both skip the inset for a panel. `de-desk` probes all four
corners of the strip.

## 7. Binary

| claim | evidence |
|---|---|
| DESK reads the screen instead of assuming it | `DESK SCREEN 0320 H 0258` at 800x600, `DESK SCREEN 0500 H 02D0` at 1280x720 |
| its strip is the full width, flush to the bottom | `DESK ATT OK X 0000 Y 0228 W 0320 H 0030` |
| exactly one strip | `OSGFX SESSION STRIP CLIENT` with DESK up; absent, and the fallback probed, in `de-session` |
| the strip touches both edges | four corner probes in `de-desk` |
| its captions are outlines | `DESK TEXT ADV 001E CELL 0028` → `DESK TEXT OUTLINE PROPORTIONAL` |
| its pills are AA Skia | `OSGFX CLIENT SHAPE SKIA RRECT` |
| an app's rows are outlines | `FILES ROW OUTLINE ADV 62 CELL 72` |
| `osxui_button_fb` returns and paints | `DESK BTNFB PIXELS FF00FF` |

`de-desk` PASS (53 checks, `OSGFX_SKIA=1`), `de-session` PASS,
`files-fm` PASS. The 1280x720 picture is
`core/build/de-one-taskbar-1280x720.png`, taken on the Venus Graphite
path in a container of this ADR's own, with the live door untouched.

## 8. What is NOT claimed

- **Not a widget toolkit.** `osxui_app.h` is five draws and a measure.
  No layout, no events, no retained scene.
- **Not hit-testing.** The slot pills are drawn from the window table;
  clicking one does nothing. Focus and raise are still DE policy in
  `wmchrome.dart` (ADR-0111, ADR-0121).
- **Not a per-window title on the bar.** The pills say `W0`..`W3` — the
  same thing the fallback strip said. The table carries a PID, not a
  name.
- **Not a fix for the shell going deaf after two resident clients**
  (GAP-0334). It is why the 1280x720 shot is driven with every spawn
  typed before `DESK.ELF`: after two resident FRAME apps the console
  never gets another line, so no `wm draw` can be typed to force a full
  compose.
- **Not a change to how damage is paced.** A repaint that lands while
  the frame budget is spent leaves part of a client's surface showing
  its previous commit; that is ADR-0190/GAP-0333 territory and this ADR
  neither fixes nor touches it. It was visible here as a slot pill whose
  top 26 rows were one commit old.
