# DE-003 — Mouse-move teal trails / row warp on purple desk

**Status:** Linux cloud agent cannot apply — no Skia COMP / `plat/osgfx` on this host.  
**Owner agent:** pointer-trails  
**Severity:** P0  
**User demand:** pointer walks must leave **no** teal trails / row warp on the purple wallpaper (or dock edge).

## Host proof (this run)

| Field | Value |
|-------|-------|
| `uname -s` | **Linux** (not Darwin) |
| Workspace | `/workspace` (`milestones-m1-m6` lineage; fb console OS only) |
| `core/plat/osgfx/` | **MISSING** |
| `origin/compositor` | **MISSING** (`git ls-remote` has no `refs/heads/compositor`) |
| Live DE sit-in | Not possible here |
| Preferred Mac worker | `54470311-d074-5e4c-a8c1-e3cc777eac29` (connected / eligible this run) |

**Do not invent Skia / pointer / desk-cache code on `milestones-m1-m6`.**  
**Do not treat milestones `fb` console screenshots as a DE-003 fix.** This file is the patch plan only.

Parent Task must re-dispatch onto that Mac `workerId`. Nested Linux agents cannot re-home to Darwin.

## Symptom (evidence)

Mac sit-in QEMU window `oscortex-abs-pointer` (purple wallpaper):

- Thick **jagged teal** blocks follow the white arrow path across the desk.
- Trail segments show **row warp** / staggered blit (shifted rectangular stamps).
- Taskbar / dock edge can tear where damage restore hits chrome vs wallpaper.

Artifacts:

- `/opt/cursor/artifacts/DE-003-teal-trails-purple-desk.png`
- `/workspace/.cursor/artifacts/DE-003-teal-trails-purple-desk.png`
- Source capture also at `/opt/cursor/artifacts/oscortex-mac-de-alpha-trails-bug.png` (same frame; glass black surrounds are **DE-001**, out of scope)

Pixel sanity on the evidence PNG (1149×922 RGBA): wallpaper ≈ `(79,1–6,111)` purple; **5749** sampled pixels within ~40 of flat desk `0x00184060` (`rgb 24,64,96`) — the classic “blue/teal hole” colour. That is the trail ink, not wallpaper.

## Root cause (not GAP-0251)

GAP-0251 (`shellMouse` / kernel `mouse` command) deliberately leaves arrows with **no** save-under on the **fb console**. The screenshot is the **Skia DESK compositor** path. Trails here mean:

1. Pointer save-under restore wrote the **wrong** underlay (flat `wmColorDesktop` / `OSGFX_DESK = 0x00184060`), or  
2. Damage restore / `desk_blit` put flat desk (or wrong-stride rows) back instead of the generative / purple field, or  
3. Restore/place order skipped restore before the next draw (old arrow stamps accumulate).

ADR-0188 / `de-pace`: after a pointer walk, the vacated 12×16 (sprite footprint historically; live sprite is **16×20**) must hold **no** `0x00184060` and more than two distinct wallpaper colours.

## Locus (Mac COMP only)

COMP worktree (try in order):

1. `/private/tmp/claude-501/-Users-ghostportal-Desktop-dc-sys/0a8dccfa-95e0-46b8-8be8-f0687b1d2277/scratchpad/COMP`
2. `git -C ~/Desktop/dc_sys/oscortex_core worktree list` → compositor / COMP tree

**Confirm before editing:** `osgfx_desk.c` is the full desk-cache version (**hundreds of lines**, contains `desk_blit` + `desk_gen_rect` + `desk_nx[]`), not the ~79–104-line generative-only stub.

### Primary files

| File | Why |
|------|-----|
| `core/kernel/wm.dart` | Pointer save-under + menu overlay restore + drag vacated-rect order |
| `core/kernel/wmpace.dart` (and/or desk helpers in same kernel set) | `wmDeskPixel` / desk cache words that damage paint must read |
| `core/plat/osgfx/osgfx_desk.c` | `desk_blit` / `desk_gen_rect` wallpaper restore for damage |
| `core/plat/osgfx/osgfx.h` | `osgfx_pointer_raster` (16×20 ADR-0194); desk entry points |
| `core/plat/osgfx/osgfx_chrome.c` | `wmChromeCachePixel` fallback path for erase under chrome |
| `core/tests/conformance/de-pace/run.sh` | Structural + pixel walk asserts |

### Exact functions to change (DE-003)

Edit these **by name** on COMP. Callers that only need audit are listed second.

#### A. Pointer save-under (primary trail path) — `core/kernel/wm.dart`

| Function | Role / required fix |
|----------|---------------------|
| **`wmPointerRestore`** | Puts the last captured **16×20** back on scanout and clears `wmPageWPtrHave`. Must blit **saved pixels**, never flat `wmColorDesktop`. Wrong/missing restore → teal stamps. |
| **`wmPointerPlace`** | Capture-under → draw sprite at `(x,y)`. Must **restore previous** (via `wmPointerRestore`) **before** capturing/drawing the new position. |
| **`wmPointerEnsure`** | Alloc / validate pointer save buffer + sprite words (`wmPageWPtr*`). Failures that skip save-under fall through to erase-pixel / flat desk. |
| **`wmPointerSaved`** | Gate: returns `wmPage(wmPageWPtrHave)`. Callers must honour 0 (no fake “have”). |
| **`wmPointerErasePixel`** | Fallback when no save-under: `wmPixelAt` then **`wmChromeCachePixel` / desk**. Must not return `wmColorDesktop` over generative purple. |
| **`wmPointerTick`** | Compose/interrupt path that moves the arrow; must call restore→place in order (same contract as `wmComposeRect`). |

State-page words (must stay consistent with `wmpace.dart` / `OSGFX_WMPAGE_W_*`):

- `wmPageWPtrHave`, `wmPageWPtrX`, `wmPageWPtrY`
- `wmPageWPtrPix` (16×20 underlay)
- `wmPageWPtrSpr`, `wmPageWPtrSprOn` (sprite / ADR-0194 raster)

#### B. Damage / wallpaper restore — desk + compose

| Function | File | Role / required fix |
|----------|------|---------------------|
| **`static void desk_blit(...)`** | `osgfx_desk.c` | Damage restore from desk cache. **No `/` in blit body**; correct pitch/stride (row warp = bad row advance). |
| **`desk_gen_rect`** (or equivalent regenerator keyed on `OSGFX_WMPAGE_W_DESK_HAVE`) | `osgfx_desk.c` | Regenerate cache when key/extent changes so blit is not stale/flat. |
| **`wmDeskPixel`** | `wmpace.dart` / desk kernel | Damage painter’s wallpaper sample. Must read cache, not stamp `wmColorDesktop`. Refuse taskbar band (`wmNoPixel`). |
| **`wmRepaintRect`** | `wm.dart` | Damage-limited paint via `wmPixelAt` / desk / chrome. Pointer must be restored around the rect (see call pattern below). |
| **`wmComposeRect`** | `wm.dart` | Known order: `wmPointerRestore()` → `wmRepaintRect(...)` → `wmPointerPlace(mouseX, mouseY)` → publish. Preserve that order. |
| **`wmChromeCachePixel`** | chrome / wm gfx | Honest erase under session chrome when `wmPixelAt` returns `wmNoPixel`. |

#### C. Related (audit; fix only if trails/warp still reproduce)

| Function | Why |
|----------|-----|
| **`wmOverlayRestore`** | Restores **DESK menu cards** via `wmRepaintRect` (`WM OVERLAY CLEAR`) — not the 16×20 pointer buffer. Fix if menu hide leaves teal holes; do not confuse with pointer save-under. |
| **`wmDragStep`** | Vacated-rect order: install **new** geom first, then `wmRepaintRect` where window **was**, then `wmRepaintWindow`. Wrong order → smear/warp (DE-005 adjacent; only touch if needed for pointer path). |
| **`osgfx_pointer_raster`** | ADR-0194 16×20 premul sprite into buffer used by place/draw. Size must match save-under footprint. |

### Call-order invariant (must hold)

```text
wmPointerRestore();                          // put underlay back; clear PtrHave
… damage / session / window paint …
wmPointerEnsure();
wmPointerPlace(mouseWordX, mouseWordY);      // save-under + draw
wmPublishFrame(...);
```

Any path that draws the arrow without a prior restore of the previous underlay will leave teal (or sprite) trails.

### Grep seeds (run on COMP)

```bash
cd "$COMP"
rg -n 'wmPointerRestore|wmPointerPlace|wmPointerEnsure|wmPointerErasePixel|wmPointerTick|wmPointerSaved|wmPageWPtr|wmOverlayRestore|desk_blit|desk_gen_rect|wmDeskPixel|wmColorDesktop|0x00184060|osgfx_pointer_raster|wmComposeRect|wmDragStep' \
  core/kernel core/plat/osgfx core/tests/conformance/de-pace 2>/dev/null
# confirm desk is not a stub:
wc -l core/plat/osgfx/osgfx_desk.c
rg -n 'static void desk_blit' core/plat/osgfx/osgfx_desk.c
```

## Required Darwin edits (DE-003 only)

1. **Restore before place** on every pointer move / compose rect / pace tick.  
2. **Save-under pixels** must be the true underlay (wallpaper / window / chrome cache), never flat `0x00184060`.  
3. **`desk_blit` damage** must copy wallpaper with correct pitch; regenerate via `desk_gen_rect` when cache key missing.  
4. **`wmPointerErasePixel`** fallback must resolve through `wmDeskPixel` / chrome cache, not `wmColorDesktop`.  
5. Out of scope: DE-001 glass SRC_OVER, DE-004 `paint_de_strip`, DE-005 full drag polish (unless one-line order fix shared with pointer).

## Verify (Mac COMP)

```bash
source ~/Desktop/dc_sys/env.sh
export OSGFX_SKIA=1
cd "$COMP"
bash core/scripts/build-kernel.sh
bash core/tests/conformance/de-pace/run.sh
bash core/scripts/sit-in-view.sh --abs
# Walk mouse across purple desk + along dock edge; screendump
# Expect: no teal trail; vacated under-arrow matches wallpaper; no row warp
```

Harness gate: `de-pace` pointer walk — vacated sprite rect has **zero** `0x00184060` and &gt;2 distinct colours.

Push:

```bash
cd "$COMP"
git add -A   # exclude secrets / huge build trees
git commit -m "DE-003: fix pointer save-under / desk_blit trails"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

## Cloud Linux reality (this agent)

- Wrote this patch plan + copied evidence PNG.  
- Did **not** change milestones fb, did **not** claim a DE fix.  
- Mac worker was available but this nested agent runs on Linux and cannot bind Darwin.
