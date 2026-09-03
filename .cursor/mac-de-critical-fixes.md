# Mac DE critical fixes (fallback flash + mouse trails + alpha/glass)

Cloud Linux (`milestones-m1-m6`) has **no** Skia COMP tree. Screenshot
`QEMU oscortex-abs-pointer` with purple wallpaper + glass dock is Mac-only.
`origin/compositor` is still missing — push COMP first.

**Mac worker:** `54470311-d074-5e4c-a8c1-e3cc777eac29`
(`~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`)

**COMP path:** `/private/tmp/claude-501/.../scratchpad/COMP` (or `git worktree list`)

## 0) Alpha compositing / rounded glass shows black surroundings

User: corner radius looks wrong; transparency is not understood — rounded
corners / glass show as **black surroundings** instead of see-through
wallpaper/desktop. Classic black halo around dock pill and island cards.

Evidence (Mac sit-in, not cloud):
`/opt/cursor/artifacts/oscortex-mac-de-alpha-trails-bug.png`
(also under `.cursor/artifacts/` when synced). Dock ends and island
outside-radius are solid black; wallpaper does not show through.

### Likely causes (hunt on COMP)

1. **Clear-to-black + SRC blit.** Glass / rrect chrome is painted into a
   scratch or shm surface cleared to opaque black (`0xFF000000` / Sk clear
   black). Soft AA leaves black outside the curve. Present then uses
   **SRC** (opaque copy) instead of **SRC_OVER**, so black surrounds land
   on the desk.
2. **Forced opaque RGB.** Paths like `sk_rgb()` that always
   `SkColorSetARGB(255, …)` drop glass alpha; frosted panels become opaque
   cards with black-filled corners if the outer rect is still cleared.
3. **Straight vs premul.** Soft AA / `osgfx_blend_px` coverage must write
   **premul ARGB** into N32Premul stores. Straight alpha + SRC_OVER =
   dark fringes; zero-alpha pixels must be `0`, not black RGB with A=0
   mishandled on blit.
4. **Frost sample path.** ADR-0198 `osgfx_glass_frost` (5×5 wallpaper
   blur + tint) must fill *only* covered samples; outside the rrect mask
   must stay transparent (or never be blitted). Radius / `OSGFX_BLIT_INSET`
   / `wmGfxRadius` stay lockstep (ADR-0196/0198) — inset that is too small
   leaves black AA rings.

### Required Mac edits

- Clear glass/chrome scratch and guest shm to **transparent 0**, not black.
- Present / `desk_blit` / chrome cache blit: **SRC_OVER** (premul) onto
  wallpaper; never SRC-copy a rect that includes outside-rrect black.
- `osgfx_fill_rrect` / Sk `drawRRect`: real coverage alpha on corners
  (`rrect_cover` / soft AA); glass tints use non-255 A where intended.
- Harness: `de-chrome`, `de-desk`, `de-session`, `view-door` (frost ink
  not flat), sit-in-view — dock/island corners show purple wallpaper,
  not black.

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
git commit -m "DE: glass SRC_OVER alpha; remove fallback Start; fix pointer trails"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

Do **not** reinvent this stack on cloud `milestones-m1-m6`.

## Cloud Linux reality (this host)

- `uname`: Linux — framebuffer shell only (`fb` console). No `plat/osgfx`.
- Live QEMU proof on milestones: `/opt/cursor/artifacts/oscortex-milestones-fb-console.png`
  (800×600 `fb` console after `FB BAR … OK`).
- Alpha / Start-flash / trails fixes require Mac COMP + `origin/compositor`.
