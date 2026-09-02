# DE-001 — Glass / rrect black surrounds (wallpaper must show through)

**Status:** Linux cloud agent cannot apply — no Skia COMP / `plat/osgfx` on this host.  
**Owner agent:** alpha-glass  
**Severity:** P0  
**User demand:** rounded glass / rrect corners must show **wallpaper**, not black surrounds.

## Host proof (this run)

| Field | Value |
|-------|-------|
| `uname -s` | **Linux** (not Darwin) |
| Workspace | `/workspace` (`milestones-m1-m6` lineage; fb console OS only) |
| `core/plat/osgfx/` | **MISSING** |
| `origin/compositor` | **MISSING** (`git ls-remote` has no `refs/heads/compositor`) |
| Live DE sit-in | Not possible here |

**Do not invent Skia / glass / frost on `milestones-m1-m6`.** This file is the patch plan only.

**Mac worker (required to land the fix):**  
`54470311-d074-5e4c-a8c1-e3cc777eac29`  
`~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`  
Parent Task must bind that `workerId`. Nested Linux agents cannot re-home.

## Symptom (evidence)

Mac sit-in QEMU window `oscortex-abs-pointer` (purple wallpaper):

- Dock pill / island **outside-radius** fills are solid black instead of purple wallpaper.
- Top-left island: beige header + black body with black rectangular corner blocks outside the curve.
- Gap / chrome surrounds that should be transparent read as opaque black.

Artifacts (same PNG):

- `/opt/cursor/artifacts/DE-001-mac-black-glass-surrounds.png`
- `/workspace/.cursor/artifacts/DE-001-mac-black-glass-surrounds.png`
- Also: `/opt/cursor/artifacts/oscortex-mac-de-alpha-trails-bug.png` (same capture; trails are **DE-003**, out of scope)

Pixel sanity on the evidence PNG (1149×922 RGBA): wallpaper center ≈ `(79,6,111)` purple; large near-black regions at bottom strip and top-left island corners (`rgb` sum &lt; 30) where glass AA / outside-rrect should be transparent over purple.

## Root cause (hunt order on COMP)

Classic compositor black-halo stack. Fix **all** of these that fire; any one alone can leave black corners.

1. **Clear-to-black + SRC blit**  
   Glass / rrect chrome is painted into a scratch or guest shm cleared to opaque black (`0xFF000000` / Sk clear black). Soft AA leaves black outside the curve. Present then **SRC**-copies the whole AABB onto the desk, so black surrounds land on wallpaper.

2. **Forced opaque RGB**  
   Helpers like `sk_rgb()` that always `SkColorSetARGB(255, …)` drop intentional glass alpha. Outer rect stays black-cleared; result looks like opaque cards with black corner wedges.

3. **Straight alpha vs premul**  
   Soft AA / `osgfx_blend_px` coverage must write **premul ARGB** into N32Premul stores. Straight alpha + SRC_OVER → dark fringes. Zero-alpha pixels must be `0` (not “black RGB with A=0” mishandled on blit).

4. **Frost outside the rrect mask**  
   ADR-0198 `osgfx_glass_frost` (5×5 wallpaper blur + tint) must fill **only** covered samples. Outside the rrect mask must stay transparent (or never be blitted). Radius / `OSGFX_BLIT_INSET` / `wmGfxRadius` stay lockstep at **18** (ADR-0196/0198) — inset that is too small leaves black AA rings.

## Locus (Mac COMP only)

COMP worktree (try in order):

1. `/private/tmp/claude-501/.../scratchpad/COMP`  
   (known live path from Mac terminals:  
   `/private/tmp/claude-501/-Users-ghostportal-Desktop-dc-sys/0a8dccfa-95e0-46b8-8be8-f0687b1d2277/scratchpad/COMP`)
2. `git -C ~/Desktop/dc_sys/oscortex_core worktree list` → compositor / COMP tree

**Confirm before editing:** `osgfx_desk.c` is the full desk-cache / frost version (**hundreds of lines**, includes `osgfx_glass_frost`), not the ~100-line generative-only stub sometimes seen in cloud extracts.

### Primary files

| File | Why |
|------|-----|
| `core/plat/osgfx/osgfx_desk.c` | `osgfx_glass_frost`, desk/wallpaper sample cache, frost tint writes |
| `core/plat/osgfx/osgfx_skia.cpp` (and/or guest Skia paint path) | surface clear colour; `drawRRect`; canvas blend mode on present |
| `core/plat/osgfx/osgfx_chrome.c` | chrome-cache buffer clear + blit to scanout / desk |
| `core/plat/osgfx/osgfx_session.c` | session paint of glass islands / strip into fb (only alpha path — do **not** own DE-004 Start deletion here) |
| `core/plat/osgfx/osgfx.h` | `OSGFX_RADIUS` / `OSGFX_BLIT_INSET` (= 18); `osgfx_fill_rrect` / `osgfx_blend_px` contracts |
| `core/kernel/wmgfx.dart` (or sibling) | `wmGfxRadius` lockstep 18; paint kinds including `WM_PAINT_GLASS` |
| Guest DESK / osxui paint (`desk.c` / `osxui_app.h` per ADR-0198) | frost islands + dock pill paint that feed shm |

### Grep seeds (run on COMP)

```bash
cd "$COMP"
rg -n '0xFF000000|SK_ColorBLACK|clear\(|kSrc[^O]|kSrcOver|SkColorSetARGB\(255|sk_rgb|osgfx_glass_frost|osgfx_fill_rrect|rrect_cover|osgfx_blend_px|OSGFX_BLIT_INSET|wmGfxRadius|WM_PAINT_GLASS|desk_blit|SRC_OVER|N32Premul' \
  core/plat/osgfx core/kernel core/user core/plat/osxui 2>/dev/null
```

## Required Darwin edits (DE-001 only)

### 1. Transparent clear

- Clear glass/chrome scratch buffers and guest glass shm to **transparent 0** (`0x00000000`), never opaque black.
- Skia: `canvas->clear(SK_ColorTRANSPARENT)` (or equivalent ARGB 0) on any surface whose AABB includes outside-rrect samples that will be composited.

### 2. Present / blit with SRC_OVER (premul)

- `desk_blit`, chrome-cache blit, glass shm present: blend **SRC_OVER** (premul) onto wallpaper.
- Never SRC-copy a rect that still contains outside-rrect black/cleared pixels.
- If a blit must stay SRC for opaque wallpaper tiles, keep that path separate from glass/chrome AABBs.

### 3. Soft AA writes real coverage alpha

- `osgfx_fill_rrect` / Sk `drawRRect`: corner coverage via `rrect_cover` / soft AA → `osgfx_blend_px` with cov in `[0,255]`.
- Glass tints use non-255 A where intended; do not force A=255 in `sk_rgb`-style helpers used by frost/glass.
- Premul: for coverage `c` and colour `(r,g,b,a)`, store premul channels; fully uncovered → `0`.

### 4. Frost stays inside the mask

- `osgfx_glass_frost`: sample wallpaper (or generative fallback), 5×5 box-blur, tint, write **only** where rrect coverage &gt; 0.
- Outside mask: leave transparent (or skip write).
- Keep `OSGFX_RADIUS` == `OSGFX_BLIT_INSET` == `wmGfxRadius` == **18** (ADR-0198). If changing radius, move all three together — but DE-001 prefers fixing clear/blend/mask first; do not casually retune radius unless inset/AA ring proves mismatched.

### 5. Out of scope for this defect

- **DE-002** crayon radius AA polish beyond what is required for transparent corners.
- **DE-003** teal mouse trails / `wmOverlayRestore`.
- **DE-004** deleting `paint_de_strip` Start flash.
- Do not bundle those into the DE-001 commit unless a one-line dependency is unavoidable; prefer a DE-001-only commit message.

## Verify (Mac COMP)

```bash
source ~/Desktop/dc_sys/env.sh
cd "$COMP"
export OSGFX_SKIA=1
bash core/scripts/build-kernel.sh

# Harnesses that already know frost / chrome (names from ADR-0198 + backlog)
# Expect green; frost ink must not be flat; corners must not be black.
bash core/tests/conformance/de-chrome/run.sh      # or de-chrome-cache if that is the local name
bash core/tests/conformance/de-desk/run.sh
bash core/tests/conformance/de-session/run.sh
bash core/tests/conformance/view-door/run.sh       # frost ink not flat; gap ≠ island

bash core/scripts/sit-in-view.sh --abs
# Interact enough for dock + island to paint; screendump guest FB
```

**Pass criteria (visual):**

- Dock pill corners: **purple wallpaper** visible through outside-radius (no black wedges).
- Island / session cards: outside-rrect shows wallpaper, not black blocks.
- Gap between islands / dock segments shows desk field (view-door already rejects gap==island).

**Pass criteria (automation):**

- `de-desk` / `de-session` / `view-door` green.
- Sit-in PNG under `/opt/cursor/artifacts/DE-001-fixed-*.png` (and `core/build/sit-in-view.png`) shows purple through glass corners.

## Screenshot + push

```bash
# After sit-in proves purple through dock corners:
cp core/build/sit-in-view.png /opt/cursor/artifacts/DE-001-fixed-purple-through-glass.png

git add -A   # exclude secrets / huge out/ trees
git commit -m "DE-001: glass clear+SRC_OVER premul; frost outside-mask transparent"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

Also push the working branch if using a named feature branch, but **`origin/compositor` must advance** so cloud can fetch the real osgfx tree.

## Done when

- No black halos on glass / rrect chrome over purple wallpaper.
- Harnesses above green; sit-in artifact saved.
- `origin/compositor` exists and contains the fix.

## Cloud follow-up (after Mac push)

```bash
git fetch origin compositor
git checkout -B compositor origin/compositor
# Only then may cloud agents build / sit-in against Skia DE
```

Until that fetch works: stop. Do not reimplement frost on milestones.
