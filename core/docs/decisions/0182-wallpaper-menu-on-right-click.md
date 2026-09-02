# ADR-0182: Wallpaper menu on right-click

## Status

Accepted.

## Context

ADR-0070 painted an empty coloured popover on right-click. ADR-0181
added generative desk paint in `osgfx_desk.c` / `osgfx_session.c` but
left "wallpaper right-click menu" as Phase 3. Sit-in needed a way to
regenerate the field and to override it with a planted FAT image
without a shell help line or a new syscall.

## Decision

1. **Under `wm de` only**, the context popover (kind 1) is a two-row
   wallpaper menu: **Regen** and **Image**. Without `wm de` the empty
   `wmPopColor` box is unchanged (`osxui1-pop`).
2. **Policy in DCDart** (`wmpop.dart`): hit-test rows, bump seed,
   load `WALL.RAW`, persist `WALL.DAT`. **Paint under `wm gfx`** also
   in `osgfx_session.c` (`paint_wall_menu`) so IRQ ticks do not wipe
   Dart labels.
3. **Mailbox** `OsGfxGuestCmd.desk` / `.wall` carry seed, mode, and
   solid RGB. Flag `OSGFX_GUEST_WALL_IMG`. No new `@bss`.
4. **`WALL.DAT`** (16 bytes: magic `WALL`, seed, mode, rgb) is loaded
   on `wm de` and rewritten on Regen / Image when the file exists.
5. **`de-wall/run.sh`** proves menu row colours, two distinct
   `WM WALL REGEN` seeds, and solid desk after `WM WALL IMG`.

## Consequences

- Auto-interval regenerate remains deferred.
- Start menu still caches at most `wmDeLaunchMax` apps.
- Syscall 11 stays `fdwait`; no help line.
