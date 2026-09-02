# Mac DE critical fixes (fallback flash + mouse trails)

Cloud Linux (`milestones-m1-m6`) has **no** Skia COMP tree. Screenshot
`QEMU oscortex-abs-pointer` with purple wallpaper + glass dock is Mac-only.
`origin/compositor` is still missing — push COMP first.

**Mac worker:** `54470311-d074-5e4c-a8c1-e3cc777eac29`
(`~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`)

**COMP path:** `/private/tmp/claude-501/.../scratchpad/COMP` (or `git worktree list`)

## 1) DELETE old fallback UI (Start strip flash)

User hates the pre-DESK fallback chrome (Start button / legacy strip / dual taskbar).

In `core/plat/osgfx/osgfx_session.c` the session still does:

```c
/* ADR-0183: DESK.ELF blits the real strip after this tick. Session
 * still paints a fallback strip so Start exists before DESK attaches. */
paint_de_strip(g, fb, pitch, cmd, hh - OSGFX_CHROME_H, ww, hh);
```

ADR-0192 / GAP-0329: once DESK commits the panel, session must **stop**
(`OSGFX_GUEST_PANEL`). User demand goes further: **remove the fallback path**
so boot never flashes Start / old chrome.

Required Mac edits:

- Delete or never-call `paint_de_strip` (and any sibling Start / legacy shell
  chrome) on the boot→desk path.
- Honour `OSGFX_GUEST_PANEL`: when set, session paints **no** taskbar.
- Prefer empty desk / clean splash until DESK.ELF attaches; do not show old UI.
- Confirm with `de-deskboot` / `de-session` / sit-in: no Start flash, one dock.

## 2) Fix mouse-move trails / smear / row warping

Screenshot: thick teal jagged trails on purple wallpaper + taskbar edge tear =
damage / save-under / desk blit failure (not kernel `mouseDrawCursor`).

Hunt and fix on Mac COMP:

- `wmOverlayRestore` / pointer save-under (`wmPointerSaved`, 16×20 under arrow,
  `wmPointerErasePixel` → `wmChromeCachePixel` / desk cache).
- `desk_blit` damage restore must put wallpaper back (not flat / wrong stride).
- `wmDragStep` vacated-rect order (repaint where window **was** after geom update).
- Cursor move: restore previous underlay **before** drawing new pointer.
- Harness: `de-pace` (pointer walk across desk), sit-in-view `--abs` visual check.

## 3) Sync

```bash
cd "$COMP"
# confirm osgfx_desk.c is hundreds of lines (desk_blit), not a ~100-line stub
git add -A   # exclude secrets / huge build trees
git commit -m "DE: remove fallback Start strip; fix pointer/desk damage trails"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

Do **not** reinvent this stack on cloud `milestones-m1-m6`.
