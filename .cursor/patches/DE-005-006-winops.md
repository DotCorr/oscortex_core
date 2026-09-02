# DE-005 / DE-006 — Window drag tear+lag and min/max/restore chrome corruption

**Status:** Linux cloud agent cannot apply — no COMP / `plat/osgfx` / Skia DE on this host.  
**Owner agent:** win-drag + win-minmax (this patch owns both).  
**Severity:** P0 each.  
**Rule:** no fake Skia DE on `milestones-m1-m6`. Fix lands only on Mac COMP → `origin/compositor`.

## Host proof (this run)

| Field | Value |
|-------|-------|
| `bcId` | `bc-d79874b7-4ebb-512d-a3f2-1760419cb648` |
| `uname` | Linux (not Darwin) |
| `privateWorkerId` / `usePrivateWorker` | `null` / `false` |
| Workspace | `/workspace` (milestones lineage; fb console OS only) |
| `core/plat/osgfx/` | **MISSING** |
| `origin/compositor` | **MISSING** (`git ls-remote` empty) |
| Live DE sit-in | Not possible here |

**Mac worker (required to land the fix):**  
`54470311-d074-5e4c-a8c1-e3cc777eac29`  
`~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`  
Connected + `eligibleForSubagent: true` + `sharedAssignmentAllowed: true`.

Parent Task must bind that `workerId` (`usePrivateWorker`). Nested Linux agents cannot re-home.

**COMP path (try in order):**

1. `/private/tmp/claude-501/-Users-ghostportal-Desktop-dc-sys/0a8dccfa-95e0-46b8-8be8-f0687b1d2277/scratchpad/COMP`
2. `git -C ~/Desktop/dc_sys/oscortex_core worktree list` → compositor / COMP tree

**Gate before editing:** `wc -l core/plat/osgfx/osgfx_desk.c` must be **hundreds** (full desk-cache with `desk_blit`), not a ~100-line gen-only stub. Cloud `/tmp/comp-extract` copies are stubs/partials — do not treat them as the live tree.

---

## Before evidence (already staged)

| Artifact | Meaning |
|----------|---------|
| `/opt/cursor/artifacts/DE-005-before-mac-de-desk.png` | Mac QEMU `oscortex-abs-pointer`: purple desk + **teal drag/move trails** + row warp (DE-005 class) |
| `/opt/cursor/artifacts/DE-005-before-drag-desk-tear-source.png` | Same screendump source copy |
| `/opt/cursor/artifacts/DE-006-before-mac-de-chrome.png` | Same shot: **black window body / black dock ends / chrome damage** (DE-006 class) |
| `/opt/cursor/artifacts/DE-005-linux-host-fb-console-only.png` | This Linux host: milestones `fb` console only — **not** DE proof |
| `/opt/cursor/artifacts/DE-006-linux-host-fb-console-only.png` | Same |

After Mac fix, add `DE-005-after-*.png` / `DE-006-after-*.png` from sit-in-view screendumps (drag mid-motion clean; min→max→restore clean).

---

## DE-005 — Window drag tears / smears / lags whole desk

### Symptom

Dragging a window leaves teal/desk smears, vacated underlay wrong, and/or the whole desk hitch-lags each step. Same damage class as pointer trails (DE-003) but for **window** vacated rects + present pace.

### Locus (Mac COMP)

| Area | Files / symbols |
|------|-----------------|
| Vacated-rect order | `core/kernel/wm.dart` → `wmDragStep` / `wmResizeStep` |
| Damage compose | `wmRepaintRect`, `wmRepaintWindow`, `wmCompose` / `wmComposeCommit` |
| Desk restore under vacated rect | `wmDeskPixel`, `desk_blit` in `core/plat/osgfx/osgfx_desk.c` |
| Scratch / present | state-page scratch words (`wmPageWScratch*`), paced present (`wmpace.dart`), `osgfx_guest_tick` |
| Chrome while dragging | `osgfx_chrome.c` key must track geom; miss → regen; hit must not blit stale geom |

### Exact vacated-rect contract (already documented in COMP `wmDragStep`)

From the COMP extract of `wm.dart` (keep this order — do not “simplify”):

1. Read old geom `g`.
2. Compute clamped new origin `(cx, cy)`.
3. If unchanged after clamp → return (no paint).
4. **Install new geom first:** `wmSetWin(... wmPackGeom(cx,cy,w,h))` + configure event.
5. **Then** `wmRepaintRect(oldX-border, oldY-border, w+2b, h+2b)` — vacated rect with **new** geom already installed so `wmPixelAt` does **not** paint the window back into the hole.
6. **Then** `wmRepaintWindow(wI)` for the new location.
7. Bump move / pixel counters.

**Wrong order** (repaint vacated *before* geom update) paints the window back into the vacated hole → smear/ghost. That is the classic DE-005 bug if any path still does it (resize, anim, overlay restore, or a second drag entry).

### Required Darwin edits — DE-005

1. **Audit every move path for vacated-rect order**
   - `wmDragStep` (move arm) — confirm order above is live.
   - `wmResizeStep` — same: geom update **before** vacated union paint.
   - Any overlay / pointer erase that runs mid-drag: restore underlay **before** drawing new chrome/pointer (shared with DE-003).
   - Grep for other `wmSetWin(...wmWinGeom...)` + `wmRepaintRect` pairs; every one must follow the same order.

2. **Scratch compose must not skip desk restore**
   - Vacated rects under `wm gfx` must pull wallpaper via `wmDeskPixel` → `desk_blit` cache, **not** solid `wmColorDesktop` (ADR-0188 §3 — blue/purple hole / smear).
   - Confirm `osgfx_desk.c` has `desk_blit` with **no division in the blit body** (`de-pace` structural check).
   - Confirm `OSGFX_WMPAGE_W_DESK_HAVE` keys the cache; invalidate only when field inputs change (`wmDeskInvalidate`).

3. **Chrome cache during drag**
   - Drag changes window geometry every step → chrome mailbox key **must** miss (geometry words in `chrome_key` / `wmGfxChromeSig`).
   - After miss: `osgfx_chrome_begin` → `osgfx_session_paint` → `osgfx_chrome_done` regenerates; tick must not blit a **HAVE** buffer whose key still matches old geom.
   - Present path blits chrome cache with correct damage union (old∪new), not full-screen SRC of a stale frame.

4. **Present pace / lag**
   - Drag steps enqueue damage; paced present (`ADR-0188`) coalesces — OK.
   - Lag that feels like “whole desk hitch” usually means full compose every step because damage path refused (`wmNoPixel` / missing desk cache / chrome sig stale forever).
   - Fix by making damage-limited compose faithful again (desk + chrome rules above), not by raising the fps cap.
   - Avoid `SkGraphics::PurgeAllCaches` on every drag tick (only where `de-skia-text` requires it at frame begin — do not purge per `wmDragStep`).

5. **Scratch buffer / double-buffer damage**
   - If compose goes through a scratch then present: damage is per-buffer (display-protocol §3.5). After flip, back buffer is two frames stale — union damage across both or full-compose the back buffer after large moves. Missing this → trails that survive one present.

### Verify — DE-005

```bash
source ~/Desktop/dc_sys/env.sh
export OSGFX_SKIA=1
cd "$COMP"
bash core/scripts/build-kernel.sh
bash core/tests/conformance/de-pace/run.sh      # desk_blit + vacated pointer walk
bash core/tests/conformance/de-wm/run.sh        # if present
bash core/tests/conformance/de-resize/run.sh
bash core/scripts/sit-in-view.sh --abs
# Daily-drive: grab title bar, drag across purple desk in loops; no teal smear, no desk lag spike
# QMP screendump mid-drag and after release → DE-005-after-drag-clean.png
```

**Pass criteria:**

- Mid-drag and post-release: vacated region shows wallpaper (many distinct colours), **not** solid desktop / teal ghost / window stamp.
- No whole-desk hitch on each drag step once desk+chrome caches are warm (`wm fps` / pace counters stable).
- `de-pace` green; resize harness green.

---

## DE-006 — Minimize / maximize / restore corrupts chrome or desk

### Symptom

Min / max / restore leaves black chrome bodies, torn title bands, dock/island damage, or desk holes. Often same shot as DE-005 before-evidence (black window body top-left + black dock ends).

### Locus (Mac COMP)

| Area | Files / symbols |
|------|-----------------|
| Min/max/restore geom jumps | `wm.dart` / `wmde.dart` — maximize, minimize, restore (incl. any `wmStartMX` / anim frame helpers named in harness notes) |
| Damage union | old geom ∪ new geom ∪ border; must cover full jump, not 1-step delta |
| Chrome cache invalidation | `osgfx_chrome.c` (`osgfx-chrome-cache`), `de-chrome-cache/run.sh` |
| Session chrome paint | `osgfx_session_paint` / title controls |
| Anim frames | intermediate frames must damage + invalidate chrome each step |

### Exact chrome-cache contract (ADR-0191 / extract)

- Cache key = fold of **every mailbox word** `osgfx_session_paint` reads (geom, top, focus, DE/popover, wall mode, desk HAVE, tone corners) — **not** `gen`, **not** a Dart-only `wmGfxChromeSig` subset that omits client corner tones.
- `OSGFX_WMPAGE_W_CHROME_HAVE == 0` means untrustworthy; key must never collide with 0.
- Serve path: unchanged key → **blit only** (BLIT++, REGEN unchanged).
- Invalidate path: open/close popover, map window, **geom change (min/max/restore)** → REGEN++.
- `de-chrome-cache` requires: twelve `wm draw` → BLIT+12 REGEN+0; popover/map → REGEN moves; cached tick ≥10× uncached; FB still has AA/gradient/caption.

### Required Darwin edits — DE-006

1. **Min / max / restore = large vacated union**
   - On maximize: save restore-geom; set new geom; **invalidate chrome** (`CHROME_HAVE=0` or key change via geom words); `wmRepaintRect` on **union(old,new)** expanded by border; then `wmRepaintWindow`.
   - On restore: same with restored geom.
   - On minimize: vacated = full old chrome+body; desk restore via `wmDeskPixel`/`desk_blit`; chrome cache must miss so dock/panel is not stamped from a buffer that still contains the window.

2. **Anim frames (`wmStartMX` / tween if present)**
   - Each intermediate frame: update geom → invalidate chrome → damage union(prev,curr) → present.
   - Do **not** blit chrome cache across anim frames when geom words changed but HAVE left set.
   - End of anim: one final regen + full window repaint; clear anim state so a later drag does not use stale scratch.

3. **Chrome corruption specifics**
   - Black window body / black rrect surrounds after restore: same alpha class as DE-001 (clear scratch to **0**, blit **SRC_OVER** premul) — ensure min/max path does not SRC-copy a black-cleared chrome scratch.
   - Title band / traffic-light damage: session owns AA chrome; Dart damage must return `wmNoPixel` for those pixels (ADR-0188 §3.2) and let chrome cache / session tick own them after invalidation.
   - After restore, force one session tick with chrome begin/done so title controls (`paint_de_title_controls`) match live geom.

4. **Wire tick path**
   - `osgfx_skia.cpp` `tick_body`: when chrome fresh → blit; else `osgfx_chrome_begin` / `osgfx_session_paint` / `osgfx_chrome_done`.
   - Confirm `osgfx_chrome.o` is linked (`build-kernel.sh`) — extract notes chrome existed but was sometimes **not linked**.

### Verify — DE-006

```bash
export OSGFX_SKIA=1
bash core/tests/conformance/de-chrome-cache/run.sh
bash core/tests/conformance/de-chrome/run.sh      # if present
bash core/tests/conformance/de-session/run.sh
bash core/tests/conformance/de-resize/run.sh
bash core/scripts/sit-in-view.sh --abs
# Daily-drive: maximize → restore → minimize → restore on FILES/chrome win
# Screendumps: DE-006-after-maximize.png DE-006-after-restore.png
```

**Pass criteria:**

- After max/restore/min: no black body, no torn title, no desk hole in vacated region.
- Chrome cache: idle draws blit; geom jumps regen; harness green.
- Dock / island not left with black end caps from stale chrome blit (coordinate with DE-007 if residual).

---

## Push compositor (Mac only)

```bash
cd "$COMP"
# confirm osgfx_desk.c is full desk-cache (hundreds of lines)
git status -sb
git add -A   # exclude secrets / huge out/ trees
git commit -m "DE-005/006: vacated-rect drag order; chrome cache invalidate on min/max/restore"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

Also copy after screendumps to `/opt/cursor/artifacts/DE-005-after-*.png` and `DE-006-after-*.png`.

---

## Cloud Linux (this host) — out of scope

- Do **not** invent `osgfx_desk.c` / chrome cache / Skia session on `milestones-m1-m6`.
- Do **not** push a fake `compositor` branch from stubs in `/tmp/comp-extract`.
- Do **not** treat milestones `fb` console PNGs as DE-005/006 after-proof.
- This patch file + before artifacts are the Linux deliverable until a Mac-bound agent lands the COMP fix.

## Done when (Mac)

- [ ] `wmDragStep` / resize / any twin paths: geom install **before** vacated `wmRepaintRect`
- [ ] Vacated desk pixels from `desk_blit` / `wmDeskPixel` (no solid desktop smear)
- [ ] Scratch/present damage union correct across buffers
- [ ] Min/max/restore: damage union(old,new) + chrome cache forced regen
- [ ] Anim frames invalidate chrome each step
- [ ] `de-pace`, `de-resize`, `de-chrome-cache`, `de-session` green
- [ ] `/opt/cursor/artifacts/DE-005-after-*.png` and `DE-006-after-*.png` captured
- [ ] `git push origin HEAD:compositor` landed (`git ls-remote` shows tip)
