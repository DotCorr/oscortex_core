# DE-visual-polish — DE-002 + DE-007..DE-015

**Status:** Linux cloud agent cannot apply COMP edits — no Darwin / no `plat/osgfx` / `origin/compositor` missing.  
**Owner agent:** radius-aa + dock-chrome + island-card + panel-metrics + icon-polish + wallpaper + frame-pace + abs-pointer + menus + visual-polish  
**Severity:** DE-002 P0; DE-007..DE-012 P1; DE-013..DE-015 P2  
**Bar:** zero leniency — DE must not look crayon-drawn.

## Host proof (this run)

| Field | Value |
|-------|-------|
| `uname` | Linux (not Darwin) |
| This run | `bc-46dcbde8-f7d2-5bb5-b947-c32a652e6497` (DE-007..015 crayon UI polish) |
| Workspace | `/workspace` — milestones fb console only |
| `core/plat/osgfx/*` | **MISSING** |
| `origin/compositor` | **MISSING** (`git ls-remote` empty) |
| Mac worker | `54470311-d074-5e4c-a8c1-e3cc777eac29` connected, idle, `eligibleForSubagent=true` |
| COMP extract | `/tmp/comp-extract` — **stubs only** (`osgfx_desk.c` 79/104 lines; not full desk-cache) |

Parent Task must bind that `workerId`. Nested Linux agents cannot re-home.

## Evidence screenshots (baseline — pre-fix)

From Mac sit-in `QEMU oscortex-abs-pointer` (synced bug PNG):

| Artifact | Shows |
|----------|-------|
| `/opt/cursor/artifacts/DE-visual-baseline-mac-sitin.png` | Full DE: trails + black glass + crayon chrome |
| `/opt/cursor/artifacts/DE-visual-overview-crayon.png` | Same overview |
| `/opt/cursor/artifacts/DE-visual-dock-ends.png` | Dock tip black block, jagged pill AA, crayon icons |
| `/opt/cursor/artifacts/DE-visual-island-card.png` | Beige header + black body/corners, pixel shadow |
| `/opt/cursor/artifacts/DE-visual-panel-metrics.png` | Clock island mis-metrics, black corner AA hole |
| `/opt/cursor/artifacts/DE-visual-crayon-icons.png` | Dock glyph squircles look hand-stamped |
| `/opt/cursor/artifacts/DE-visual-wallpaper-banding.png` | Purple field corduroy / banding |

Copies also under `.cursor/artifacts/`.

---

## Coordination with P0 (do not fight)

Apply **after / with** these Mac commits; rebase onto `origin/compositor` tip before editing:

| ID | Agent | Touch points we must not clobber |
|----|-------|----------------------------------|
| DE-001 | alpha-glass | transparent clear, SRC_OVER premul, frost outside mask = 0 |
| DE-003 | pointer-trails | `wmOverlayRestore`, pointer save-under, `desk_blit` damage |
| DE-004 | kill-fallback | delete `paint_de_strip` / Start flash |
| DE-005/006 | win-drag / win-minmax | scratch compose order, damage union |

Our polish depends on DE-001 glass math. Soft AA without SRC_OVER still paints black rings.

---

## Apply order on Darwin COMP (priority)

COMP path (try in order):

1. `/private/tmp/claude-501/.../scratchpad/COMP`
2. `git -C ~/Desktop/dc_sys/oscortex_core worktree list` → compositor / COMP

```bash
source ~/Desktop/dc_sys/env.sh
export OSGFX_SKIA=1
cd "$COMP"
git fetch origin compositor || true
# If tip exists: rebase/pull onto it before any polish commits.
# Confirm osgfx_desk.c is hundreds of lines (desk_blit + frost), not ~100-line stub.
```

### Wave A — foundation (blocks everything that looks “crayon”)

1. **DE-002** soft radius AA (`rrect_cover` / Sk AA / premul blend)
2. **DE-001** glass clear + SRC_OVER (owned by alpha-glass; verify corners show wallpaper)
3. **DE-011** wallpaper precision + ordered dither (kills banding under motion)

### Wave B — chrome geometry

4. **DE-007** dock frost width / inset / tip artifacts  
5. **DE-008** island card: frost body + transparent outside radius  
6. **DE-009** panel/clock island metrics + AA edge pixels  

### Wave C — content polish

7. **DE-010** icon glyphs (real AA, padding, not muddy stamps)  
8. **DE-015** shadows / vgrads / traffic lights  

### Wave D — interaction finish

9. **DE-012** frame pace (`de-pace`, chrome cache, PurgeAllCaches, vsync arm)  
10. **DE-014** menu/overlay damage restore  
11. **DE-013** abs pointer / host cursor fight (`sit-in-view --abs`)

---

## Per-defect patch notes

### DE-002 — Corner radius crayon / blocky (P0)

**Symptom:** Stair-stepped rrect corners on dock pill, islands, window cards.  
**Likely locus:** `osgfx_fill_rrect` → `rrect_cover` / `osgfx_blend_px` in `osgfx_skia.cpp`; Sk `drawRRect` with `paint.setAntiAlias(true)`. Guest path `osgfx_guest_skia.cpp` also draws rrects.

**Required edits:**

- Soft coverage AA: partial cover writes **premul** ARGB via `osgfx_blend_px` (cov 0..255), not hard in/out pixels.
- Outside-curve samples must stay **transparent 0** (pairs with DE-001). Never black RGB with A=0 mishandled.
- Prefer Sk `drawRRect` AA path for chrome; CPU `rrect_cover` must match visually at `OSGFX_RADIUS` 18 (ADR-0198 lockstep with `OSGFX_BLIT_INSET` / `wmGfxRadius`).
- Do **not** force `SkColorSetARGB(255,…)` for glass fills (`sk_rgb` bug) — glass tints need non-255 A.

**Verify:** `de-session` (requires `rrect_cover` + `c->drawRRect`); sit-in zoom on dock tip + island corners — no jaggies, wallpaper through soft fringe.

---

### DE-007 — Dock ends: black bars / orphan semicircles (P1)

**Symptom:** Black blocks / orphan arcs at dock pill left/right tips.  
**Likely locus:** dock frost blit inset / width vs pill radius; `osgfx_glass_frost` + `OSGFX_BLIT_INSET`; DESK dock paint in `osxui` / desk shell.

**Required edits:**

- Frost/blit width must cover full pill including soft AA fringe (`OSGFX_BLIT_INSET` ≥ radius, lockstep ADR-0196/0198).
- Clear dock scratch to transparent 0; present with SRC_OVER.
- Kill any opaque black rect under the semicircle ends (common when width truncates before AA ring).
- `view-door` already asserts frosted dock samples ≠ flat + gap ≠ island.

**Verify:** crop dock tips — purple wallpaper through glass ends, no black bar/semicircle.

---

### DE-008 — Top-left island: beige header + black body / corner blocks (P1)

**Symptom:** Cream rounded header over solid black body; black corner blocks outside curve.  
**Likely locus:** session / DESK island paint (`osxui_island` / `osxui_glass` per ADR-0197/0198); glass frost not applied to body; clear-to-black + SRC.

**Required edits:**

- Island body must use `WM_PAINT_GLASS` / `osgfx_glass_frost` (5×5 wallpaper blur + tint), not opaque black fill.
- Outside-rrect region transparent; soft AA on all four corners.
- Beige header: either frost+tint or real vgrad — not a flat stamp sitting on a black card.
- Shadow under island: real `osgfx_shadow` / `SkMaskFilter::MakeBlur` (see DE-015); kill pixel-block “shadow”.

**Verify:** `de-desk` / `view-door` frost vary (island samples not one flat colour); sit-in — wallpaper visible through island glass, no black corner blocks.

---

### DE-009 — Taskbar / clock island misaligned borders, stray black pixels (P1)

**Symptom:** Clock/date island borders off by 1px; black AA holes at corners; cramped layout.  
**Likely locus:** panel layout metrics in DESK / `osgfx_session` chrome; AA edges of clock rrect.

**Required edits:**

- Integer layout: padding, text baseline (`osgfx_text_center_y`), icon slots consistent with island radius.
- Borders drawn with same radius as fill; no 1px black fringe from mismatched clip vs stroke.
- Clock/date via `osgfx_text` outlines (not 8×16 `osgfx_fill_glyph` stamps) — `de-skia-text` forbids glyph cells in session.

**Verify:** sit-in bottom-left island — clean AA corners, aligned text, no stray black pixels.

---

### DE-010 — Icons look crayon (P1)

**Symptom:** Dock glyphs blocky, muddy, wrong padding; look hand-stamped.  
**Likely locus:** dock icon atlas / stacked rrects in `osxui_app_icon_*` / desk shell; glyph AA (`osgfx_glyph.c` soft-AA door `osgfx-glyph-aa`).

**Required edits:**

- ADR-0198: dock glyphs = stacked rrects with soft AA (gear/folder/globe/note/paper/tools) — not coloured squares, not 1×1 paper stamps.
- Consistent icon cell padding inside dock pill; optical centering.
- Prefer outline / Skia AA paths over bitmap 8×16 where chrome already has `osgfx_text`.
- No muddy premul (straight alpha on glass = dark fringes around glyphs).

**Verify:** `de-desk` icon glyph checks; sit-in dock crop — readable modern glyphs, soft edges.

---

### DE-011 — Wallpaper banding / corduroy under motion (P1)

**Symptom:** Horizontal banding / corduroy on purple generative desk.  
**Likely locus:** `osgfx_desk.c` field precision; stub path still does per-pixel `/w` `/h` at scale 1024 with bit-shift noise.

**Required edits (full desk-cache, not stub):**

- `OSGFX_DESK_SCALE 8192`, smooth field (no corduroy bit-shift noise), **ordered dither**.
- `desk_nx[]` column table; `desk_rgb_n(nx,ny)` without `/w` `/h` in hot path.
- `desk_gen_rect` + `desk_blit` (no division in blit body) — required by `de-pace`.
- Key on `OSGFX_WMPAGE_W_DESK_HAVE`; bump REGEN/BLIT counters.

**Verify:** `de-pace` / `de-wall` / `de-desk`; sit-in under mouse motion — no corduroy bands.

---

### DE-012 — Present stutter / whole-OS hitch (P1)

**Symptom:** Any interaction hitch; frame budget blown.  
**Likely locus:** `wmpace.dart` / chrome cache / `osgfx_skia.cpp` tick; missing `SkGraphics::PurgeAllCaches`; regenerating chrome every tick.

**Required edits:**

- Chrome cache path: `osgfx_chrome_begin` / `osgfx_chrome_done` around `osgfx_session_paint` when fresh (ADR-0191).
- `SkGraphics::PurgeAllCaches` in `osgfx_heap_frame_begin` (`de-skia-text` structural).
- Desk cache blit, not full generative field per frame (ADR-0188).
- Frame arm / vsync: honour compositor refresh (ADR-0188); don’t Purge in a way that stalls every move.

**Verify:** `de-pace` green; sit-in — pointer move / dock click without whole-OS hitch.

---

### DE-013 — Cursor visibility / abs pointer vs host mouse (P2)

**Symptom:** Guest cursor fights host mouse; abs tablet mapping off.  
**Likely locus:** `sit-in-view.sh --abs` (QEMU cocoa `oscortex-abs-pointer` + virtio-tablet); pointer raster `osgfx_pointer_raster` (ADR-0194).

**Required edits:**

- Abs path: one cursor authority — guest sprite OR host, not both fighting.
- After DE-003 restore path is solid, verify abs QMP click hit-tests dock/icons.
- Keep `--venus` path working for harnesses.

**Verify:** `bash core/scripts/sit-in-view.sh --abs` — single visible cursor, accurate clicks.

---

### DE-014 — Menu / overlay pixels wrong after open/close (P2)

**Symptom:** Wall menu / popover leaves wrong pixels after dismiss.  
**Likely locus:** popover path in `osgfx_session.c` (`osgfx_shadow` + `osgfx_fill_rrect` + `paint_wall_menu`); damage restore vs chrome cache / desk blit.

**Required edits:**

- On pop close: invalidate chrome cache key (popover word in fold) and restore desk under vacated rect.
- Don’t SRC-blit opaque black under dismissed menu.
- Soft AA popover corners same as DE-002.

**Verify:** open/close wall menu repeatedly — wallpaper intact, no ghost pixels.

---

### DE-015 — Overall crayon look: shadows / gradients / traffic lights (P2)

**Symptom:** Flat chrome; pixel-block shadows; missing or crude window controls.  
**Likely locus:** `osgfx_shadow`, `osgfx_fill_rrect_vgrad`, `paint_de_title_controls` / CSD traffic lights; ADR-0198 leftover: soft-shadow elevate capped at radius 8 (larger MaskFilter #GP’d under wall-menu — `de-retain`).

**Required edits:**

- Elevation via `SkMaskFilter::MakeBlur` (`de-skia-text` requires it) within safe radius that doesn’t #GP SkResourceCache.
- Title / island vgrads via `osgfx_fill_rrect_vgrad` (multi-shade Graphite title — `view-door` wants ≥4 pearl shades).
- Traffic lights: real circular controls with soft AA + correct hit targets (not square stamps).
- Kill any remaining flat copper Start / gold title stamps (`view-door` rejects `0xC87840` / `0xD8B060`).

**Verify:** `de-chrome` / `de-session` / `view-door` / sit-in — modern glass DE, not crayon.

---

## Harness gate (Mac, after Waves A–D)

```bash
# Structural + sit-in cluster (must stay green; do not regress P0)
for h in de-pace de-wall de-desk de-deskboot de-wm de-resize \
         de-chrome de-session de-skia-text de-osxui de-panel view-door; do
  bash "core/tests/conformance/$h/run.sh" || exit 1
done
bash core/scripts/sit-in-view.sh --abs
# Screendumps after: idle desk, dock tips, island, panel, menu open/close, pointer walk
# → /opt/cursor/artifacts/DE-visual-*.png (post-fix names; do not overwrite baseline)
```

## Push

```bash
cd "$COMP"
git add -A   # exclude secrets / huge build trees
git commit -m "DE: radius AA, dock/island glass tips, icons, dither, pace, chrome polish"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

Do **not** invent a parallel Skia stack on `milestones-m1-m6`.

---

## Cloud Linux deliverable checklist

- [x] Prioritized patch notes (this file)
- [x] Baseline + crop screenshots under `/opt/cursor/artifacts/DE-visual-*.png`
- [x] Document Mac worker bind requirement
- [ ] COMP code fixes (blocked — not Darwin)
- [ ] Post-fix sit-in screenshots (blocked — not Darwin)
- [ ] `git push origin HEAD:compositor` with real COMP fixes (blocked)

## Done when (Mac)

- Soft AA radii; wallpaper through glass corners (no black halos/tips)
- Dock + island + panel look modern (frost, metrics, glyphs)
- Wallpaper smooth under motion (dithered field)
- Interaction paced (`de-pace`); menus restore clean; abs pointer usable
- Shadows / vgrads / traffic lights present without crayon stamps
- Harnesses green; compositor tip pushed
