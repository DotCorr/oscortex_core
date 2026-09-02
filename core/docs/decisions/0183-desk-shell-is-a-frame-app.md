# ADR-0183: Desk shell is a FRAME app; compositor composites

## Status

Accepted.

## Context

Owner rejected the sit-in picture as “cheap tricks” that “can never be
Skia.” Honest inventory against the live frame:

| Layer | What it actually was | Looks like Skia? |
|---|---|---|
| Generative wallpaper | `osgfx_fill_desk_generative` / Graphite desk | **Yes** |
| Window bodies under `wm gfx` | Solid `OSGFX_WIN_FILL` in `osgfx_session_paint` — **client shm not blitted** | No — fake interiors |
| Title / close / Start / text | Session C stamps: `fill_rrect` + **8×16 bitmap glyphs** (`osgfx_glyph.c` from `fb.dart`) via `osxui_label` | Partially Graphite rrects; **text is not Skia text** |
| Taskbar | Compositor policy painted into the scanout (ADR-0181), not a client | Kit-shaped stamps, not an app |

The product goal (reflection + osxui SDK): **`wm` composites**; desktop
chrome and apps are built with the **same** FRAME + `osxui` → `osgfx`
APIs used at app-dev time. Init spawns the desk shell and startup apps.
The compositor is not a second abstract UI painter that cosplays the kit.

## Decision

1. **Under `wm gfx`, compose order is:** session wallpaper → **blit every
   live client surface** (`wmDrawWindow`) → chrome overlays that must not
   wipe bodies → cursor. `wmPublishFrame` does **not** re-run a tick that
   fills window interiors.
2. **`osgfx_session_paint` stops filling window bodies** with
   `OSGFX_WIN_FILL`. Title band / close / Start may remain compositor
   overlays until the desk shell owns them; body pixels are the client's.
3. **`DESK.ELF`** is a FRAME app: attaches a bottom strip, paints the
   taskbar through `osxui` into its shm, commits. Sit-in / `wm de` spawn
   it with FILES / SET. Same plant path as other FAT ELFs.
4. **Honesty:** bitmap 8×16 labels are still not Skia text; Venus ICD AA
   limits remain. Next rungs: desk owns Start/slots fully; CSD titles via
   osxui; Graphite (or SkFont) for labels.

## Consequences

- `de-desk/` proves DESK.ELF plants, attaches, and a body-band pixel from
  FILES survives a gfx session tick (no solid wipe).
- ADR-0181 still owns generative desk; this ADR corrects the compose lie.
- GAP-0325 binary next step (blit under chrome) is this decision.
