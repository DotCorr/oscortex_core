---
name: keep-github-synced
description: "Keep DotCorr/oscortex_core GitHub branches current during Mac compositor / Skia DE work so cloud agents never redo finished local work. Use when finishing Mac desktop graphics changes, before starting a cloud agent on DE/compositor, when GitHub looks stale vs a local worktree, or when the user complains about out-of-date remotes."
---

# Keep GitHub Synced (oscortex_core)

Cloud agents only see **what is on GitHub**. Local Mac worktrees (especially COMP / `compositor`) are invisible until you **commit and push**. Stale remotes cause cloud to rebuild Skia DE work that is already done on the Mac.

## Hard rules

1. **Push before cloud continues.** After any meaningful Mac compositor / DE / sit-in / harness fix, commit and push **before** yielding to a cloud agent or assuming GitHub is the source of truth.
2. **Do not wait for the user to type git.** On long polish loops: commit + `git push` periodically (after each green harness cluster or clear visual win), not only at the end of the day.
3. **Skia DE source of truth is `origin/compositor` (or the branch you pushed), not `milestones-m1-m6`.** The cloud `milestones-m1-m6` checkout is framebuffer/shell OS only. Never treat it as the Skia desktop tree.
4. **Before starting DE work in cloud:** `git fetch origin compositor` (or the active DE branch). If the tip is missing or behind the Mac, **stop and sync Mac → GitHub first** instead of re-implementing.
5. **Never redo finished Mac work from a stale cloud tree.** If harness names, ADRs, or files exist only on the Mac worktree, push that tree; do not recreate from memory on `milestones-m1-m6`.

## Mac → GitHub checklist

Preferred COMP worktree (try in order):

- `/private/tmp/claude-501/.../scratchpad/COMP`
- `git -C ~/Desktop/dc_sys/oscortex_core worktree list` and use the compositor / COMP path

Then:

```bash
cd "$COMP"
git status -sb
# Confirm osgfx_desk.c is the full desk-cache version (hundreds of lines), not a stub
git add -A   # exclude secrets / huge build artifacts if present
git commit -m "Describe the DE win (desk blit, pace, dock, sit-in-view, …)"
git push -u origin HEAD:compositor
git ls-remote origin refs/heads/compositor
```

If already on a named local branch that tracks something else, still ensure **`origin/compositor`** (or the agreed DE branch) advances so cloud can `fetch` it.

## Cloud agent checklist

```bash
git fetch origin compositor
git checkout -B compositor origin/compositor   # only when that remote exists
# Then build / sit-in / harnesses against THIS tree
```

If `origin/compositor` does not exist:

- Do **not** invent a parallel Skia stack on `milestones-m1-m6`.
- Get a Mac/self-hosted agent (or human) to push COMP first.
- Self-hosted Mac worker: display name `~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`, workerId `54470311-d074-5e4c-a8c1-e3cc777eac29`. Parent Task must bind `usePrivateWorker` / that workerId. Nested Linux agents **cannot** re-home — if `uname` is Linux and there is no COMP tree, stop and dispatch Mac.

## Critical DE bugs that only live on Mac COMP

See `.cursor/mac-de-critical-fixes.md`. Screenshot proof: QEMU
`oscortex-abs-pointer` purple wallpaper with teal mouse trails + Start flash
+ **black surrounds on rounded glass** (dock / islands). Cloud milestones can
only screendump the `fb` text console — never treat that as DE proof.

1. **Alpha / glass black halo** — rounded corners and frosted chrome show
   black surroundings instead of wallpaper. Clear scratch to transparent 0;
   blit with **SRC_OVER** (premul), not SRC; soft AA corners must be real
   alpha (`osgfx_blend_px` / `rrect_cover`), not black fill outside the
   curve. ADR-0198 `osgfx_glass_frost` + radius lockstep.
2. **Fallback Start strip** — `osgfx_session.c` `paint_de_strip` before DESK
   attaches (ADR-0192 / GAP-0329). **Delete** that path; boot must not flash
   old Start / legacy chrome.
3. **Mouse trails / smear / row warp** — pointer save-under /
   `wmOverlayRestore` / `desk_blit` damage restore. Cursor and window moves
   must restore underlay cleanly (no teal trails on wallpaper / dock tear).

## What belongs on the push

Include: `core/` kernel + osgfx + wm, sit-in / sit-in-view scripts, DE harnesses, related ADRs, this skill, `.cursor/mac-de-critical-fixes.md`.

Exclude: secrets, credentials, huge `out/` / object trees unless the repo already tracks them by design.

## Why this skill exists

A cloud session on `milestones-m1-m6` cannot see unpushed COMP commits. That wasted loops re-discovering drag-row blit, wallpaper dither, `de-pace`, glass dock, abs pointer QMP, Venus 1280×720, and empty-desk boot — all already done on the Mac. **GitHub lag is a correctness bug for multi-agent workflows.**
