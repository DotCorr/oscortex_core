# DE-004 — Kill Start / fallback strip flash before DESK

**Status:** Linux cloud agent cannot apply — no `plat/osgfx` on this host.  
**Owner agent:** kill-fallback  
**Severity:** P0  
**User demand:** delete that shit (`paint_de_strip` / old Start fallback flash before DESK).

## Host proof (this run)

| Field | Value |
|-------|-------|
| `uname` | Linux (not Darwin) |
| Workspace | `/workspace` (`milestones-m1-m6` lineage; fb console OS only) |
| `core/plat/osgfx/osgfx_session.c` | **MISSING** |
| `origin/compositor` | **MISSING** |
| Live DE screenshot | Not possible here (no Skia COMP / sit-in) |

**Mac worker (required to land the fix):**  
`54470311-d074-5e4c-a8c1-e3cc777eac29`  
`~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`

Parent Task must bind that `workerId`. Nested Linux agents cannot re-home.

## Symptom

Boot path paints legacy Start / fallback taskbar strip **before** DESK.ELF attaches, so the user sees a flash of old chrome (dual taskbar / Start button) then the real DESK panel. User wants that path gone entirely — not gated, not delayed: **deleted**.

## Locus (Mac COMP only)

File: `core/plat/osgfx/osgfx_session.c`

Known call (ADR-0183-era comment still in tree):

```c
/* ADR-0183: DESK.ELF blits the real strip after this tick. Session
 * still paints a fallback strip so Start exists before DESK attaches. */
paint_de_strip(g, fb, pitch, cmd, hh - OSGFX_CHROME_H, ww, hh);
```

Related: ADR-0192 / GAP-0329 — once DESK commits the panel, session must stop painting taskbar when `OSGFX_GUEST_PANEL` is set. User demand goes further: remove the fallback so boot **never** flashes Start.

## Required Darwin edits (apply on COMP worktree)

COMP path (try in order):

1. `/private/tmp/claude-501/.../scratchpad/COMP`
2. `git -C ~/Desktop/dc_sys/oscortex_core worktree list` → compositor / COMP tree

### 1. Delete fallback path

- Remove the call to `paint_de_strip(...)` on the boot→desk / session paint path.
- Delete `paint_de_strip` itself (and any sibling Start / legacy shell chrome helpers that exist only for the pre-DESK flash), **or** leave a stub that is never referenced — prefer full delete if nothing else needs it.
- Prefer empty desk / clean splash until DESK.ELF attaches. Do **not** show old Start UI for any frame.

### 2. Honour `OSGFX_GUEST_PANEL`

- When `OSGFX_GUEST_PANEL` is set, session paints **no** taskbar / strip / Start chrome.
- After DESK commits the panel, session must not paint a second bar (ADR-0192 / GAP-0329).
- Grep for other callers of `paint_de_strip` / Start-strip paint and kill those on the session path too.

### 3. Verify

```bash
source ~/Desktop/dc_sys/env.sh
export OSGFX_SKIA=1
bash core/scripts/build-kernel.sh
# harness cluster
# de-deskboot / de-session / de-desk — no Start flash, one dock after DESK
bash core/scripts/sit-in-view.sh --abs
```

**Pass criteria:**

- Boot → desk: **no** Start / legacy strip flash (any frame).
- Single modern dock/panel after DESK attaches (no dual taskbar).
- `OSGFX_GUEST_PANEL` set ⇒ session paints no taskbar.

### 4. Screenshot + push

```bash
# Screendump after clean boot (no Start flash) → copy to:
#   /opt/cursor/artifacts/DE-004-no-start-flash.png
# Also sync under .cursor/artifacts/ when convenient.

cd "$COMP"
git add -A   # exclude secrets / huge build trees
git commit -m "DE-004: delete paint_de_strip Start fallback flash before DESK"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

## Cloud Linux (this host) — out of scope

- Do **not** invent `osgfx_session.c` or a parallel Skia stack on `milestones-m1-m6`.
- Do **not** treat milestones `fb` console screendumps as DE-004 proof.
- This patch file is the only Linux deliverable for DE-004.

## Done when (Mac)

- [ ] `paint_de_strip` removed or never called on boot→desk path
- [ ] `OSGFX_GUEST_PANEL` honoured (no session taskbar when set)
- [ ] sit-in / harness: no Start flash
- [ ] `/opt/cursor/artifacts/DE-004-*.png` captured
- [ ] `git push origin HEAD:compositor` landed
