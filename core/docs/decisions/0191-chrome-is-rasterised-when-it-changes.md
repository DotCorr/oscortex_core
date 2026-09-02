# ADR-0191 — Chrome is rasterised when it changes

**Status:** accepted, implemented (`core/plat/osgfx/osgfx_chrome.c` (new),
`core/plat/osgfx/osgfx_skia.cpp`, `core/plat/osgfx/osgfx_guest.h`,
`core/kernel/wmpace.dart`, `core/kernel/wmfps.dart`, `core/kernel/wm.dart`,
`core/scripts/build-kernel.sh`; harness
`core/tests/conformance/de-chrome-cache/run.sh` 57 checks, regressions
`core/tests/conformance/de-session/run.sh` 65 checks and
`core/tests/conformance/de-pace/run.sh` 63 checks, both re-run on the final
tree after the concurrent ADR-0189/ADR-0190 workers had landed in the same
files)
**Date:** 2026-08-31
**Depends on** ADR-0172 (Skia does not run in an interrupt), ADR-0181
(session tick generative desk), ADR-0183 (session chrome owns the gfx
pixels), ADR-0187 (chrome text is a live Skia outline), ADR-0188 (the
compositor has a refresh rate).
**Closes** GAP-0330. **Answers and does not close** GAP-0327 (§6): the glyph
cache it asks for is measured here and is not worth building yet, and the
measurement is wired into the OS as a counter so the next worker starts from
a number.
**Number:** 0191. 0189 and 0190 were taken by the concurrent resolution and
strip-ownership workers while this was in flight. **No new syscall** — 11
stays `fdwait`. **No new mailbox word**: `OsGfxGuestCmd` is still sixteen
words / 128 bytes and `de-pace` still re-derives `mediaBoxOff` from it.
**No new `@bss`, and none grown.**

---

## 0. The measurement this starts from

ADR-0188 §8 left this rung a sentence: after the wallpaper cache, the Skia
session tick was **40–47 ms of a 40–45 ms compose**. Not a component of the
frame — the frame.

Reproduced on this tree before any change, at 800x600 on `qemu64`, from
`wm fps` (`core/kernel/wmfps.dart`, `T` ticks over `N` iterations at 10 ms a
tick):

| stage | ms / iteration | what it is |
|---|---|---|
| `K 4` | **32.703** | the Skia session tick |
| `K 5` | **32.973** | a full compose |
| `K 9` | 40.333 | a full compose with the wallpaper cache turned off |
| `K 8` | 8.392 | the wallpaper, regenerated |
| `K 3` | 0.412 | the wallpaper, blitted (ADR-0188's 20x) |
| `K A` | 2.797 | a 64x64 damage repaint |

So a compose was 33 ms and 32.7 ms of it was the session tick, and every one
of those ticks re-scan-converted a picture whose inputs had not moved: the
rounded window bodies, the gradient title bands, the blurred elevation rings,
the traffic lights, the Start pill, the taskbar strip and the outline
captions.

**GAP-0330 and the rung brief both predicted the glyph outlines were "likely a
large share" of that.** §6 is the measurement that says they are 0.7% of it,
and what turned out to be 88% instead.

---

## 1. Decision

1. **The session paints into a cached full-screen buffer, and a tick whose
   inputs have not changed is one blit.** `tick_body` gains a hit arm above
   the paint it always did; the miss arm points the paint at the cache instead
   of the scanout and presents the result.

2. **The key is a fold of the mailbox words `osgfx_session_paint` reads, taken
   on the side that reads them.** Not `wmGfxChromeSig`, which GAP-0330
   proposed — §3.

3. **The taskbar gradient is cached separately, because it is 88% of a
   rasterisation on its own** (§5). The frame cache makes an *unchanged* tick
   cheap; the band cache makes a *changed* one cheap. Those are different
   claims and the harness proves them separately.

   The 88% is a within-run figure and it is the one number in this ADR that
   the §2 spread does not undermine, because it comes from two builds measured
   back to back rather than from two stages of one ladder.

4. **No glyph cache** (§6), and the reason is a measurement rather than a
   preference.

5. **The memory is the compositor's**, out of the frame allocator, on
   ADR-0188 §5's terms; the contents and the key are C's (§4).

---

## 2. The numbers

`wm fps` grew three stages so that the before column is taken **out of the
same binary, at the same resolution, seconds apart, on the same dirty
framebuffer** — because a before/after across two builds on two boots is a
comparison of two machines as much as of two code paths.

* `K D` invalidates BOTH keys per iteration: chrome and taskbar band are
  rasterised every time. **This is the pre-ADR-0191 tick, reconstructed.**
* `K B` invalidates only the chrome key: the chrome is rasterised, the band is
  blitted. This is what a *changed* frame now costs.
* `K 4` invalidates nothing: one blit.
* `K C` and `K 5` are the same for a full compose.

**SIX RUNS, NOT ONE, AND THE SPREAD IS REPORTED BECAUSE IT IS LARGE.** This
host was shared all afternoon with a concurrent worker's harnesses and a live
QEMU door, and the absolute milliseconds move by ±50% run to run as a result.
Quoting the best run would have been quoting the host's idle moment. Three of
these are `de-chrome-cache` PASS runs; three are `wm fps` alone, same binary.

| stage (ms/iter) | 1 | 2 | 3 | 4 | 5 | 6 | median |
|---|---|---|---|---|---|---|---|
| `K D` tick, nothing cached | 43.929 | 42.069 | 35.294 | 64.737 | 42.857 | 48.077 | **43.4** |
| `K B` tick, band cached only | 5.000 | 6.091 | 4.396 | 9.375 | 8.054 | 6.186 | **6.14** |
| `K 4` tick, both cached | 0.602 | 2.048 | 0.581 | 0.982 | 0.650 | 0.838 | **0.74** |
| `K C` compose, chrome rasterised | 9.677 | 5.911 | 4.724 | 10.526 | 7.895 | 10.714 | **8.79** |
| `K 5` compose, both cached | 1.026 | 0.796 | 0.725 | 0.923 | 0.889 | 0.958 | **0.91** |
| **tick ratio** | 73.0x | 20.5x | 60.8x | 65.9x | 66.0x | 57.4x | **63x** |
| **compose ratio** | 9.4x | 7.4x | 6.5x | 11.4x | 8.9x | 11.2x | **9.2x** |
| **band ratio on a miss** | 8.8x | 6.9x | 8.0x | 6.9x | 5.3x | 7.8x | **7.4x** |

**At the median: the session tick is 63x cheaper, a full compose 9.2x, and a
frame that genuinely changed 7.4x.**

Run 2 is the outlier and it is left in. Its `K 4` of 2.048 ms is three times
every other run's, and in the same run `K 4` came out *more expensive than the
`K 5` compose that contains it* — which is the drift `wmfps.dart` measures
compose twice to detect, and it detected it. It is a contended host, not a code
path. **The harness's asserted floors are 10x on the tick, 5x on the compose
and 3x on the band**, chosen well under the worst run so that a FAIL means the
cache stopped working rather than that the Mac was busy.

Against the pre-change binary in §0, which is the honest cross-build number
and the smaller one:

| | before | after (median) | |
|---|---|---|---|
| session tick (`K 4`) | 32.703 ms | **0.74 ms** | **44x** |
| full compose (`K 5`) | 32.973 ms | **0.91 ms** | **36x** |

A compose is now under a PIT tick, so ADR-0188's 50 fps cap is a cap again
rather than a description of what the frame cost. `de-pace` measures **49.9
fps against the stated 50** after this change, and 24.7 against 25 at `wm
pace 4`.

**The ratio in the running OS, not in a benchmark.** `wm pace off` prints
`WM CHROME PX <n> FRM <n> REGEN <n> BLIT <n> GLYPH <n> HIT <n>` and
`WM BAND PX <n> FILL <n> HIT <n>`. On the harness boot, twelve `wm draw` full
composes moved `BLIT` from 1 to 13 and `REGEN` **not at all**.

---

## 3. Why the key is not `wmGfxChromeSig`

GAP-0330's proposal was to reuse the signature ADR-0188 built, and it would
have been subtly wrong in a way worth writing down, because the two look
interchangeable and one of them is a chrome cache's key.

* The **signature** answers a Dart question — "may a damage-limited repaint be
  honoured?" — and folds the window set and geometry, the top slot, focus, the
  DE and popover state, and the wallpaper mode.
* `osgfx_session_paint` reads all of that **and `tone0`/`tone1`**, the
  client's own bottom-corner colours, which the compositor re-samples out of
  client shm on every kick. A cache keyed on the signature would hold a stale
  corner tone for the whole time a client's bottom edge was changing colour,
  and that corner is chrome's to paint (ADR-0187 §4).

So `chrome_key` folds the eleven mailbox words the paint reads, plus the
generative field's own cache key — which closes the one hole a mailbox-only
key would leave, since `wmDeskInvalidate` can mark the wallpaper stale without
changing the seed and a chrome frame that did not notice would blit last
wallpaper for ever. `gen` is deliberately absent: it is the tick counter, and
folding it in would make the key an expensive way to spell "always miss".

**The signature stays Dart's and the key stays C's, and the harness checks one
against the other rather than merging them.**
`de-chrome-cache/keycover.py` reads every `cmd->FIELD` out of
`osgfx_session.c` and every `m->FIELD` out of `chrome_key`, and FAILS if the
first set is not a subset of the second. Four fields are exempt and each
exemption is a claim: `fb` and `pitch` are the paint's *destination* (a moved
or restrided scanout is caught by `osgfx_chrome_fresh`'s explicit W/H test and
`osgfx_chrome_present`'s `pitch < w * 4` refusal), `gen` is the tick counter,
`magic` is refused before the paint is reached.

That check is the difference between a structural assertion and a structural
decoration. Add a field to the paint without adding it to the key and it
fails; it was verified by deleting one fold and watching it fail.

---

## 4. Where the cache lives, and what clears the key when

**Dart owns the memory; C owns the contents and the key.** One contiguous run
from the frame allocator — 519,168 pixels in 507 frames at 800x600, one screen
for the frame plus one taskbar band after it. **One allocation, not two**, so
there is one contiguity check, one failure mode and one thing to give back;
the band's address is published as a separate word so nothing in C does
arithmetic on Dart's idea of the layout. `wmChromeBandPublish` recomputes that
offset on **every** ensure rather than only on allocation, because the offset
is the frame's pixel count and a resolution change moves it while leaving the
run big enough to keep.

Allocated only under `wm de`, on `wmDeskEnsure`'s terms and for its reason:
that is the only flag combination under which the session paints antialiased
chrome at all, so `de-osgfx` and the Graphite proof stamps take no frames and
their baselines do not move. With no page and no buffer, `osgfx_chrome_target`
returns 0 and the tick paints straight into the scanout exactly as it did
before this file existed — slower, and not wrong.

**The key is cleared BEFORE the paint and stamped after it.**
`osgfx_chrome_begin` zeroes it; a `#GP` or a reset half way through a scan
conversion therefore leaves a torn frame marked untrustworthy rather than
current. This is `osgfx_desk.c`'s rule and the stronger version of its reason:
the compositor blits this buffer to the *visible* scanout. `de-chrome-cache`
derives `begin < paint < done` out of `tick_body`'s source rather than reading
it by eye.

**The key is recomputed in `osgfx_chrome_done` rather than carried from
`begin`**, and that is what makes the count 1 instead of 2: the paint has one
side effect that lands in the key — a wallpaper regenerate writes
`OSGFX_WMPAGE_W_DESK_HAVE` — so a key taken before the paint would disagree
with the next tick's and the boot would show two rasterisations where one
happened.

**Skia does not run in an interrupt** (ADR-0172). Dart never calls into
`osgfx_chrome.c`; it sets and clears state-page words, and the fill happens on
the session tick in process context. `de-chrome-cache` asserts that no `.dart`
file names any `osgfx_chrome_*` entry point.

The state page grew eleven words for the frame cache (21..31) and seven for the
band (32..38), and `de-chrome-cache` cross-checks the C `#define` table against
the Dart `const int` table by name: 25 shared words, all agreeing, no C-only
word.

---

## 5. The taskbar gradient was 88% of a rasterisation

This is the part nobody predicted, and it was found by stubbing things out one
at a time rather than by reading the code.

A chrome rasterisation with the frame cache in and nothing else was **35.882
ms**. Then, on the same host the same afternoon:

| build | `K B` ms | what it says |
|---|---|---|
| chrome cache only | 35.882 | the baseline for this table |
| gradient `setAntiAlias(false)` | 39.7 | **the coverage pass is not the cost** |
| all `osgfx_text` stubbed out | 41.0 | **the glyph outlines are not the cost** |
| taskbar band cached | **4.461** | the gradient shader was 31.4 ms — **87.6%** |
| gradient replaced by a flat fill, band cached | 4.461 | indistinguishable, so the band cache captured all of it |
| that, and text stubbed too | 4.211 | **text is 0.25 ms** |

One `SkShaders::LinearGradient` fill over the 800x48 strip was ~820 ns/px.
Turning its antialiasing off changed nothing, so the cost is the gradient
*shader* and not the coverage walk — the freestanding build calls
`skcms_DisableRuntimeCPUDetection()` and gets a scalar raster pipeline.

So the band gets its own cache, keyed on width, height and the two colours.
Those never change for the life of a boot at a fixed resolution, which makes
this the one piece of chrome that is not merely *usually* unchanged.

**It is cached only for `radius == 0`, and that is a correctness condition
rather than a simplification.** A radius-0 fill covers every pixel of its
rectangle completely, so the cached pixels are the gradient and nothing else.
With a radius, the antialiased corners would have blended against whatever the
band buffer happened to hold, and pasting that over the real destination would
put a ring of the wrong colour around the corners. The one caller in the live
path — `paint_de_strip` — passes 0. `de-chrome-cache` asserts the gate.

**The draw call is the same draw call.** On a miss the canvas is bound to the
band buffer and *translated by (-x, -y)*, so the rrect and the gradient's two
points are still expressed in the caller's coordinates. That is what makes the
cached pixels the ones Skia would have written straight to the destination
rather than merely similar to them, and it is why `de-session`'s
`title_gradient` probe reads the same `F3EFE7 -> E9E1D1 over 32 rows, 27
shades` after this change as before it.

---

## 6. No glyph cache, and GAP-0327 answered with a number

GAP-0327 asks for a glyph cache and the rung brief expected it to be most of
the 40–47 ms. **Text is 0.25 ms of a 4.46 ms rasterisation** — 5.6% of a cheap
frame, 0.7% of the frame this ADR started from. Stubbing every `osgfx_text`
call out of a rasterising build made the tick *slower* (41.0 ms against 35.9),
which is measurement noise around zero.

A cache keyed by char + size + colour would therefore buy at most 0.25 ms of a
0.74 ms cached tick and nothing at all of the 4.46 ms miss, and it would cost
a keyed A8 mask store, an eviction policy and a correctness argument about
subpixel positioning. **That is not worth building against these numbers, and
saying so is the finding rather than a deferral.**

What landed instead is the counter, so the next worker starts from a
measurement:
`osgfx_text` calls `osgfx_chrome_glyph_count(0)` per run and `wm pace off`
prints `GLYPH <n> HIT <n>`. The two harness boots read **471 runs across 469
rasterisations** and **513 across 511**, 0 served either time — one outline run
per frame on a bare desktop, every one a miss, honestly reported.
`de-chrome-cache` asserts `GLYPH >= REGEN` (the counter is wired) and
`HIT == 0` (no cache exists), so the day one lands the assertion is what has to
be edited to say so.

**This is a claim about a bare desktop and it does not generalise.** A screen
full of window titles scan-converts one run per title per rasterisation, and
`GLYPH` over `REGEN` is the number that will say when that stops being cheap.
GAP-0327 stays open with these numbers attached.

---

## 7. The per-tick serial lines

The rung brief asked for two `com1_puts` lines in `osgfx_session.c` — 0.86–1.35
ms each, two of them 5% of the frame budget — to go behind a debug flag. They
were already gone: ADR-0187's rewrite of that file replaced them with
once-per-boot latched notes, and the two that remain (`OSGFX SESSION CHROME`,
and ADR-0190's `OSGFX SESSION STRIP CLIENT`) are both latched on a file-static
`*_noted` flag.

`de-chrome-cache` asserts the **property** rather than a list of permitted
strings, because that file is shared with concurrent work: every `com1_puts`
in it must have a `_noted == 0` test within the preceding 240 characters. A
latch further away than that is a latch a reader cannot see either. The first
draft of this check was a string allowlist and it failed within four minutes,
on a correctly-latched line a sibling had just added.

The cache's own note is behind the flag the owner already has:
`wmChromeBufEnsure` forwards `wmPaceLogging()` into
`OSGFX_WMPAGE_W_CHROME_LOG` every compose, so `wm pace log` prints
`OSGFX CHROME REGEN` per rasterisation and nothing else does. Off, it is one
load and one compare.

---

## 8. How the harness proves a cache rather than a speed-up

**A chrome cache that never invalidates is fast, produces a picture that
passes every pixel probe `de-session` owns, and is wrong.** Every AA-fringe,
gradient and outline-caption assertion in this suite would pass against a
frame frozen at boot. So `de-chrome-cache` brackets the serve and the
invalidation separately, and the serve window is also the control that makes
the invalidation window mean anything:

| window | what moved | assertion |
|---|---|---|
| 12 x `wm draw` (full composes, nothing changed) | `BLIT` 1 -> 13, `REGEN` 1 -> **1** | `REGEN` moved by **zero**, and `BLIT` by at least 12 |
| click the Start pill (`WM DE START` observed) | `REGEN` 1 -> **2** | the popover invalidates (`pop`) |
| click empty desktop | `REGEN` 2 -> **3** | closing it invalidates too |
| `proc spawn A` | `REGEN` 468 -> **469** | geometry invalidates (`win0`, `tone0`, `tone1`) |

The `REGEN` moved by *zero* is asserted rather than "moved by little": one
rasterisation across twelve identical composes would mean the key folds
something that changes per tick, which is the one bug that would make the
whole cache a slower way of not caching.

**The popover CLOSING is the harder half and it is the assertion worth
keeping.** `wmDePopHide` clears `wmMetaPop` through a *damage repaint* rather
than a compose, so that leg only passes if the KEY noticed the state going
back — not the compose path.

Only ONE client is spawned. Two leave two resident processes round-robin
preempting with IRQ0 unmasked, the serial fills with `PROC PREEMPT`, and the
shell never reads the next line. That is a real property of the OS at this
rung (GAP-0334) and the harness is shaped around it rather than typing harder.

Faithfulness is asserted on the framebuffer `pmemsave` took after all of the
above, which the OS last wrote through `osgfx_chrome_present` — a blit, not
Skia. `close_aa` is the assertion that matters most there: a cache that
quantised, dithered or lost the alpha ramp would still be a rounded red button
and would still fail it. It reads `fringe 00A74A49 mid 00D45050`, identical to
`de-session`'s.

---

## 9. What this ADR does not do

**The 4.46 ms miss is not analysed past the gradient.** With the band cached,
a rasterisation is 4.46 ms and text is 0.25 ms of it; the other 4.2 ms is
rrects, the blurred elevation rings and `SkGraphics::PurgeAllCaches()` per
tick, and nobody has taken it apart. It matters only when chrome changes every
frame, which is dragging a window. Recorded as **GAP-0335**.

**The band cache is one band.** There is exactly one full-width radius-0
vertical gradient in the chrome, so a one-entry cache keyed on
(w, h, top, bot) is a complete cache of the thing it caches. A second gradient
strip of a different height or colour pair would thrash it — and the mitigation
is that it would not be quiet about it: `WM BAND FILL` climbing in step with
`REGEN` is exactly what thrashing looks like, and the harness asserts
`FILL < REGEN`, so adding that strip is a FAIL rather than a slow boot.
Recorded as **GAP-0336**.

**A cached frame is a full-screen blit even for a one-pixel change.** 480,000
pixels of load/store per tick, which is the 0.74 ms. ADR-0188's damage path
already avoids composing at all for a client commit; what is not done is a
*damage-limited blit out of the chrome cache*, which would make a cursor move
cost its own rectangle rather than the screen. Recorded as **GAP-0337**.

**Nothing here is validated at 1200x720 or on Venus.** Every number in this
ADR is 800x600 stdvga on `qemu64`. The buffer is sized from `fbGeom*` and the
band offset is recomputed per ensure, so a resolution change is *handled*, but
"handled" is a code-reading claim and not a measurement — and the worker
fixing `GET_DISPLAY_INFO` (ADR-0189, GAP-0328) is changing the resolution
underneath this. Recorded as **GAP-0338**.
