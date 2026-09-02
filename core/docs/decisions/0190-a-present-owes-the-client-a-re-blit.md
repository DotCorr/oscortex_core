# ADR-0190 — A present owes the client a re-blit

**Status:** accepted, implemented (`wmSessionOwe`, `wmSessionOwed`,
`wmSessionOwedClear`, `wmSessionRestore`, `wmRestoreReportLine` in
`wmpace.dart`; the debt recorded in `wmGfxKick` in `wmgfx.dart`; the
pointer gate and the settle in `wm.dart`; the call site in `isr.S`)
**Date:** 2026-08-31
**Depends on** ADR-0051, ADR-0172, ADR-0183, ADR-0188, ADR-0189.
**Closes** GAP-0333.
**Number:** 0190. No new syscall. 11 stays `fdwait`.
**Harness:** `core/tests/conformance/de-retain` — PASS, 34 checks,
135 seconds of wall clock.

---

## 1. Decision

**A present that paints over a mapped client's rectangle owes that
client a re-blit, and owes it inside the same present.** The session's
present is the whole scanout, so its debt is every live window. The
debt is recorded where the present is *caused* — `wmGfxKick`, the only
thing that moves the mailbox generation the session tick keys on — and
it is paid on the instruction after the tick, in
`wmSessionRestore`.

The second half of the decision is the one that keeps ADR-0188's win:
**a pointer move that would make Skia draw exactly the same picture
does not kick.** `wmGfxChromeSig` already answers "would
`osgfx_session_paint` draw something different", and it deliberately
does not include the pointer, because Dart draws the arrow.

## 2. Root cause of GAP-0333

`isr_common` calls `osgfx_guest_tick` on the instruction after
`isrDispatch` (`core/boot/isr.S:297`), on **every** interrupt — every
vector, not just IRQ0. The tick returns immediately while
`m->gen == last_gen`, so what actually decides whether the session
paints is who last moved `gen`, and the only thing that moves it is
`wmGfxKick` (`core/kernel/wmgfx.dart`). When the tick does paint it
writes the whole scanout: the ADR-0188 cached generative field, then
every antialiased Skia draw over it, or one full-screen blit out of the
ADR-0189 chrome frame.

**Nothing in that path reads a client's shared memory.** The only code
on this machine that blits a client's shm into the framebuffer is
`wmDrawWindow` (`core/kernel/wm.dart:857`), and it is reached from
`wmCompose` and from nowhere else.

So a kick that was *not* part of a compose handed the screen to Skia
and left every mapped client's body painted over with wallpaper. It did
not come back: the compositor does not poll clients, and a client that
has committed once has nothing more to say. `wmPointerTick` made
exactly such a kick, **unconditionally, on every pointer packet**. One
pointer walk across the desk was enough, and the windows it emptied
stayed empty. That is the `SET` card with no listing and the `FILES`
title bar with no body, and it is why the symptom is idle-dependent
rather than size-dependent: it needs an interrupt after a kick, not a
resolution.

**This is not, strictly, an ADR-0188 regression.** `wmPointerTick`
kicked before the pacing work too. What ADR-0188 changed is that a
`wmComposeCommit` under `wm gfx` now honours damage instead of always
full-composing, which removed the accidental full re-blit that used to
paper over the wipe on the next client commit — and for a client that
commits once and then idles, there is no next commit at all. The defect
was latent, ADR-0188 removed the thing that was hiding it, and the
first application to sit still exposed it.

### 2.1 What was ruled out

- **Damage honouring in `wmComposeCommit` (`wm.dart:1112`).** Not
  implicated. Its damage-limited path repaints the window's own
  decorated rectangle and blits the client into it; the signature test
  above it already forces a full compose on any chrome change. The
  bodies vanish on machines where no commit happens at all.
- **The wallpaper cache.** It is the *content* of the overwrite, not
  the cause. Removing it would make the session paint slower and still
  paint over the client.
- **`wmFrameTick`'s paced present.** It composes from Dart and does
  re-blit clients. It never lost anything.
- **The client.** Both harness clients hold a correct, unchanged shm
  frame for the whole run. The compositor overwrote pixels it had
  already presented and never went back to the source it still had.

## 3. The fix

### 3.1 The debt (`wmgfx.dart:248`)

`wmGfxKick` calls `wmPageEnsure()` and `wmSessionOwe()` before it moves
`gen`. The debt is one word in the ADR-0188 state page — **no new
`@bss`**, because eleven harnesses assert the kernel's mutable static
total to the byte.

### 3.2 The payment (`wmpace.dart:990`, called from `isr.S:310`)

`wmSessionRestore` runs on the instruction after `call
osgfx_guest_tick`, with nothing between them, because the two halves
are one present and between them the screen is wrong. It is **Dart
only** — `wmDrawWindow` reads shm frame vectors and writes the
framebuffer and touches no Skia heap — which is what ADR-0172 requires
of anything in an interrupt, and it is the same licence `wmFrameTick`
runs under.

It reaps first, blits every live window bottom-up with the top slot
last (`wmCompose`'s order, and it has to be the same order or two
overlapping windows would resolve differently in a restore than in a
compose), then redraws the arrow.

Three things it deliberately does **not** do:

- **It does not stamp `wmGfxChromeSig`.** ADR-0188 §3.3 makes
  `wmCompose` the one place entitled to claim the chrome on screen is
  current, and an interrupt that cannot distinguish a completed
  `tick_body` from an early return is not entitled to.
- **It does not call `wmPublishFrame`.** This is the second half of the
  session's frame, not a frame of its own, and ten byte-exact harnesses
  count `WM FRAME` lines. The count lives in the state page and
  `wm pace` prints it as `WM RESTORE N ... PX ... SKIP ...`.
- **It does not pay while `wmMetaBusy` is set.** A compose running in a
  syscall is going to do the blit itself; two painters in one
  framebuffer is a torn frame either way. A busy interrupt counts a
  skip, **leaves the debt owed**, and the next interrupt after the
  guard drops pays it.

### 3.3 The settle (`wm.dart:1011`)

`wmCompose` calls `wmSessionOwedClear()` after its own blits: the
session tick ran inside that frame and the window blits above it are
the re-blit the restore would otherwise owe.

### 3.4 The gate (`wm.dart:2758`)

`wmPointerTick` now kicks only when `wmGfxChromeFresh() < 1`. With the
restore alone a pointer move would be *correct* but would still hand
the whole scanout to Skia for an arrow that moved twelve pixels. Both
halves are needed and neither is sufficient: the gate stops the
common case from costing anything, the restore keeps every case that
does present honest.

## 4. Why this does not spend ADR-0188's win

The 17–19x is damage honouring in `wmComposeCommit` and the paced
present in `wmFrameTick`. **Neither is touched.** No full compose was
added and no damage path was widened.

The restore's cost is bounded by when it can run at all:

| condition | cost |
|---|---|
| no `wm gfx` | one load of `.data` and a compare, per interrupt |
| `wm gfx`, no debt | one extra load out of the state page |
| debt outstanding | one client blit, ~0.89 ms/1280x720 (ADR-0188 §5) |

And the debt only exists when Skia actually repainted the screen, which
after §3.4 no longer includes plain pointer motion. In the harness run:
60 pointer packets produced **zero** session presents, and the 40
restores were caused by the 10 popover cycles that genuinely changed
the picture. The measured net is *fewer* Skia presents than before this
ADR, not more.

## 5. The harness — `de-retain`

Every compositor harness in this repo probed the first frame, and the
two that run for any length of time (`de-pace`, `de-session`) drive a
client that **commits in a loop** — so its window is re-blitted
hundreds of times a second and its body cannot be observed to rot.
That is precisely why this shipped green.

`de-retain` is the other shape on purpose. Two `d3-session` clients
that commit **once** and then only yield — which is what every real
application does between one redraw and the next. Their interior blocks
are read out of guest physical memory with `pmemsave` at T0 and after
every stage and compared **byte for byte**:

| stage | at | what happened | A | B |
|---|---|---|---|---|
| move | +2.8s | 20 pointer packets across bare desktop | intact | intact |
| menu | +15.1s | 10 popover open/close cycles | intact | intact |
| settle | +45.1s | 30s paced, no input | intact | intact |
| idle | +135.1s | 90s more of nothing at all | intact | intact |

with, over the run: frame clock armed, 60 pointer packets, 10
popovers, desk `BLIT` 3 → 23, **restores 40, 3 266 880 pixels put back,
1 deferred, 0 owed at the end**.

The counters are read straight out of the state page in guest physical
memory rather than off the serial line, because two resident clients
ping-pong through `procTick` and the shell never runs again after the
second spawn — so no command can ask for the report. `osgfx_guest_cmd`
is located with `nm`, `pmemsave`d, and the page address read out of it.

The harness refuses to pass on a boot that proved nothing: it asserts
the run exceeded 120 seconds, that the clock was armed for it, that the
session actually presented after T0, that `wmSessionRestore` actually
ran and moved pixels, that no debt was left standing at the end, and
that restores exceeded deferrals (an always-deferred repair is a repair
that never runs).

## 6. It was shown to catch the defect

`DE_RETAIN_NOFIX=1` skips the source-reading structural section only;
everything after it runs unchanged. With `call wmSessionRestore` backed
out of `isr.S` and `wmPointerTick`'s kick made unconditional again, the
same harness on the same clients:

    DE-retain: move   +   2.8s  A LOST 7200 px B LOST 12800 px
    DE-retain: menu   +  15.1s  A LOST 7200 px B LOST 12800 px
    DE-retain: settle +  45.1s  A LOST 7200 px B LOST 12800 px
    DE-retain: idle   + 135.2s  A LOST 7200 px B LOST 12800 px
    restores 0, pixels 0, deferred 0, owed at end 1
    DE-retain: FAIL

Both bodies die on the **first** pointer stage and never come back,
which is GAP-0333 exactly: it is not a slow decay, it is one packet,
and the two minutes on the door were just how long it took the owner to
move the mouse and then look.

## 7. What this does not fix

- **`wmGfxEdgeTone` is not in `wmGfxChromeSig`.** A client that changes
  only the tone of its own bottom edge will not move the signature, so
  under §3.4 a pointer move will no longer kick a repaint of it. This
  is pre-existing — the signature never covered it — but §3.4 removes
  the accidental pointer-driven repaint that used to hide it. It
  corrects on the next compose.
- **An exhausted frame allocator.** If `wmPageEnsure()` cannot get its
  one 4 KiB page, `wmGfxKick` still kicks (chrome correctness wins) and
  the restore cannot be recorded. A machine in that state has larger
  problems, but the corner is real and stated rather than papered over.
- **The restore is the whole screen's worth of clients, not the
  presented rectangle.** That is correct today because the session's
  present is always the whole scanout. A future partial session present
  would want the debt to carry a rectangle.
