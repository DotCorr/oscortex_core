# DE defect backlog (daily-drive, zero leniency)

Source: user reports + `QEMU oscortex-abs-pointer` screenshot
(`.cursor/artifacts/oscortex-mac-de-alpha-trails-bug.png`).

**Rule:** every row gets its own agent. Fix → sit-in screenshot → commit →
`git push origin HEAD:compositor`. No “good enough.”

| ID | Severity | Symptom | Likely locus | Agent owns |
|----|----------|---------|--------------|------------|
| DE-001 | P0 | Glass / rrect shows **black surroundings** instead of wallpaper | clear-to-black, SRC vs SRC_OVER, premul, frost outside mask | alpha-glass |
| DE-002 | P0 | Corner radius looks crayon / blocky, not soft AA | `osgfx_fill_rrect` / `rrect_cover` / Sk drawRRect | radius-aa |
| DE-003 | P0 | Mouse move leaves **teal trails** / row warp | `wmOverlayRestore`, pointer save-under, `desk_blit` | pointer-trails |
| DE-004 | P0 | Boot **flashes old Start / fallback strip** before DESK | `paint_de_strip` in `osgfx_session.c` | kill-fallback |
| DE-005 | P0 | Window **drag** tears / smears / lags whole desk | scratch compose, vacated-rect order, present pace | win-drag — Linux plan in `.cursor/patches/DE-005-006-winops.md` (Mac COMP apply) |
| DE-006 | P0 | **Minimize / maximize / restore** corrupts chrome or desk | damage union, chrome cache, anim frames | win-minmax — same patch file; Mac worker `54470311-…` |
| DE-007 | P1 | Dock ends: black bars, orphan semicircle artifacts | dock frost blit inset / width | dock-chrome |
| DE-008 | P1 | Top-left island: beige header + black body, black corner blocks | session card / island paint | island-card |
| DE-009 | P1 | Taskbar/clock island misaligned borders, stray black pixels | panel layout / AA edges | panel-metrics |
| DE-010 | P1 | Icons look crayon (no AA, wrong padding, muddy glyphs) | icon atlas / Skia text / glyph AA | icon-polish |
| DE-011 | P1 | Wallpaper banding / corduroy under motion | desk field precision / dither | wallpaper |
| DE-012 | P1 | Present stutter / whole-OS hitch on any interaction | `de-pace`, vsync, PurgeAllCaches, frame arm | frame-pace |
| DE-013 | P2 | Cursor visibility / abs pointer fight with host mouse | sit-in-view QMP abs+click | abs-pointer |
| DE-014 | P2 | Menu / overlay pixels wrong after open/close | menu damage restore | menus |
| DE-015 | P2 | Overall “3yo crayon” look: shadows, gradients, traffic lights | chrome polish pass | visual-polish |

## Daily-drive script (Mac COMP)

```bash
source ~/Desktop/dc_sys/env.sh
export OSGFX_SKIA=1
bash core/scripts/build-kernel.sh
bash core/scripts/sit-in-view.sh --abs   # or --venus
# Interact: move mouse, drag, min, max, open dock apps, menus
# Screendump after each interaction class
```

## Done when

- No black halos on glass
- No pointer trails
- No Start flash
- Drag / min / max clean
- Dock + island look modern (real AA, wallpaper through glass)
- Harnesses: `de-pace` `de-wall` `de-desk` `de-wm` `de-resize` `de-chrome` `de-session` green
