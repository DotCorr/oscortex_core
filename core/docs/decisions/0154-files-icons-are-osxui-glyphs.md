# ADR-0154 — FILES icons are osxui glyphs

**Status:** accepted, implemented (`osgfx_icon_rows` /
`osxui_icon` / `osxui_icon_fb`, `files.c` strip paint, harness
`core/tests/conformance/files-ico`)
**Date:** 2026-08-30
**Milestone:** GAP-0315 leftover after ADR-0149
**Depends on** ADR-0100 (FILES strip), ADR-0117 (`osgfx_fill_glyph`),
ADR-0113 (`osxui.h`).
**Closes** the icons leftover of GAP-0315. Subdirectories stay open
if named elsewhere. Syscall 11 stays `fdwait`.
**Number:** 0154 — 0153 is Graphite chrome rrect. 0149 is FILES move.
0150 is shmgrow. Do not reuse those. No new syscall.

---

## 1. The question

FILES listed, copied, and moved. The strip was per-name colour tiles
only. GAP-0315 named a glyph blit from `.rodata` (not `String`) as
the next visible step — not a PNG, not a theme pack. Text-only rows
are still a listing.

## 2. The decision

1. **`osgfx_icon_rows` is the document silhouette.** Sixteen bytes in
   `osgfx_glyph.c` `.rodata`. Same cell as an 8×16 glyph. Not a
   letter. Not a `String`.
2. **`osxui_icon` / `osxui_icon_fb` paint it.** Host widgets call
   `osgfx_fill_glyph`. FILES.ELF links the same `osgfx_glyph.c` and
   calls `osxui_icon_fb` into its surface after the band fill.
3. **One icon per listed name.** Left pad `OSXUI_ICON_PAD_X` /
   `ICON_PAD_X`, colour `OSXUI_ICON_FG` / `ICON_FG` (`0x00F8F0E0`).
   Serial carries `FILES ICON` when icons land.
4. **Anti-vacuity: `FILES_NO_ICON=1`.** The same client without the
   icon path leaves the band colour at the icon coordinates. Host
   `osxui-headless --no-icon` mirrors that miss.
5. **No new number, no help, no Graphite/Venus edit.** 11 stays
   `fdwait`. `shellStrHelp` stays 2511. Copy / move / rename paths
   are unchanged.

## 3. Binary

`files-ico/run.sh` boots FILES.ELF with icons and without. The icon
boot's framebuffer has `ICON_FG` on a derived set bit of
`osgfx_icon_doc`. The no-icon boot has `SURF_BAND0` there. Host
`--icon` / `--no-icon` agree.

## 4. What this is not

Not subdirectories. Not a PNG pack. Not Graphite / MakeVulkan /
Venus (file fence). Not `fdwait`. Not a guest OS.
