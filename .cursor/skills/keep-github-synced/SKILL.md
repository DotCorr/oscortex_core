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
- Self-hosted Mac worker for this repo has been: display name `~/Desktop/dc_sys/oscortex_core @ Tahiru's MacBook Pro`. Task/subagents from managed Linux often **do not** bind that worker — if `uname` is Linux and there is no COMP tree, you are not on the Mac.

## What belongs on the push

Include: `core/` kernel + osgfx + wm, sit-in / sit-in-view scripts, DE harnesses, related ADRs, this skill.

Exclude: secrets, credentials, huge `out/` / object trees unless the repo already tracks them by design.

## Why this skill exists

A cloud session on `milestones-m1-m6` cannot see unpushed COMP commits. That wasted loops re-discovering drag-row blit, wallpaper dither, `de-pace`, glass dock, abs pointer QMP, Venus 1280×720, and empty-desk boot — all already done on the Mac. **GitHub lag is a correctness bug for multi-agent workflows.**
