# ADR-0181: Session tick paints generative desk and DE chrome

## Status

Accepted.

## Context

Sit-in `wm gfx` called `osgfx_guest_tick` with a partial paint: solid
desktop, window borders/titles only, and a taskbar fill that wiped DE
widgets painted by `wmDeChromeDraw`. Skia Graphite proofs (ADR-0153,
0159, 0161, 0172) stayed on init-time stamps; the live session still
looked like solid blue plus client-coloured boxes.

## Decision

1. **`osgfx_session_paint`** in `osgfx_session.c` is the sit-in compose
   body: generative desktop (`osgfx_fill_desk_generative` when `wm de`
   or Graphite is armed), rrect window chrome matching `osgfx_scene`,
   taskbar, DE Start/slots via `osxui_button_fb`, close/min when DE
   is on, and popover shadow/rrect.
2. **`osgfx_fill_desk_generative`** in `osgfx_desk.c` replaces the
   solid `OSGFX_DESK` / Graphite desk fill for the session backing.
   Seed comes from mailbox `gen`; frame counter is `gen`. Serial:
   `OSGFX DESK GEN`. Init-time Graphite DESK proof (001C6A38) is
   unchanged.
3. **Mailbox flags** carry `OSGFX_GUEST_DE`, top window index, and
   held-slot bits so C paints DE without new syscalls. Dart skips
   `wmDeChromeDraw` / `wmTitleButtonsDraw` when `wm gfx` owns the
   strip.
4. **`de-session/run.sh`** proves Homebrew + Venus Docker: serial
   `OSGFX DESK GEN`, desktop pixel variety, title + Start probes.

## Consequences

- `de-osgfx` keeps solid desktop (no `wm de`); structural grep follows
  `osgfx_session.c`.
- Wallpaper right-click menu is ADR-0182 (`de-wall`).
- Sit-in PNG refreshes when session boots with `wm de`.
