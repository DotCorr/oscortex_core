# ADR-0188 — The compositor has a refresh rate

**Status:** accepted, implemented (`core/kernel/wmpace.dart`,
`core/plat/osgfx/osgfx_desk.c`, `core/kernel/wm.dart`,
`core/kernel/wmfps.dart`, `core/kernel/interrupts.dart`,
`core/kernel/keyboard.dart`, `core/kernel/shell.dart`,
`core/kernel/wmpop.dart`, `core/plat/osgfx/osgfx_guest.h`,
`core/plat/osgfx/osgfx_cmd.c`, `core/plat/osgfx/osgfx_session.c`;
harness `core/tests/conformance/de-pace/run.sh` 63 checks, regression
`core/tests/conformance/de-session/run.sh` 60 checks)
**Date:** 2026-08-31
**Depends on** ADR-0052 (damage drives the commit), ADR-0110, ADR-0153,
ADR-0181 (session tick generative desk), ADR-0183 (session chrome owns the
gfx pixels), ADR-0187 (chrome text is a live Skia outline).
**Retires** ADR-0183's refusal to honour a damage rectangle under `wm gfx`,
which was correct when it was written and is now unnecessary (§3).
**Closes** "the DE has no frame rate" as a statement of fact about this OS.
**Number:** 0188. No new syscall — 11 stays `fdwait`. One new mailbox word
(`OsGfxGuestCmd.wmpage`, offset 120, taking that struct to exactly the 128
bytes the linker already aligns `.osmedia_cmd` to, so `mediaBoxOff` does not
move). **No new `@bss`, and none grown**: `wmStore`'s 24-word meta block is
untouched and the pacer's state is a page from the frame allocator (§5).

---

## 0. The measurement this starts from

A sibling worker instrumented the render path with a `wm fps` shell command
and reported, from the live sit-in door:

* **Steady state was zero frames per second**, and not as a figure of speech.
  A door that had been up for two hours had **four** `WM FRAME` lines in its
  serial log, all four from startup. Frames were event-only — a client commit,
  a handful of shell commands, a decoded media frame — and with no client
  committing, nothing ever asked.
* There was no vsync, no vblank, no retrace, no frame budget and no throttle
  anywhere in `core/kernel` or `core/plat`. The IRQ0 arm bumped a counter and
  called `procTick`; it never composed.
* When something did ask, one 1280x720 frame cost **217–228 ms (4.4 fps)**, of
  which the generative wallpaper was **126 ms (57%)** at 146 ns/px against
  13 ns/px for a plain store, and the DE chrome re-stamp **97 ms (44%)**. The
  client blit — the only part anybody had suspected — was **0.89 ms**.
* **Damage tracking existed and was bypassed.** `wmComposeCommit` checked the
  `wm gfx` flag and, when set, discarded the damage rectangle and called a
  full `wmCompose()`. A 16x16 dirty rect regenerated 921,600 wallpaper pixels
  and re-stamped every piece of chrome on the screen.

Three of those four are what this ADR is about. The fourth — the chrome
re-stamp — is deliberately left to the worker rewriting it (§8, GAP-0330).

---

## 1. Decision

1. **The generative wallpaper is generated once and blitted per frame.**
   `osgfx_desk.c` splits its single loop into `desk_gen_rect` (the field
   maths, run when the field's KEY changes) and `desk_blit` (one 32-bit load
   and one 32-bit store per pixel, no arithmetic). The buffer is the
   compositor's, handed over through a state page.

2. **The wallpaper is a still, not an animation.** Both the seed and the
   phase used to come from `cmd->gen`, which the compositor bumps once per
   tick — so the desktop was a different field every frame. That is
   television static at four frames a second, and it is a field no cache
   could ever hold. The seed is now the owner's choice (the `desk` mailbox
   word, which `Regen` and `WALL.DAT` write) and the phase is pinned to zero.
   Advancing the phase is still how an animated desk would be expressed; it
   costs a regenerate per phase and therefore has to be a decision rather
   than a side effect of counting ticks.

3. **The damage rectangle is honoured under `wm gfx`.** `wmComposeCommit`'s
   gfx arm now reaches `wmComposeCommitGfx`, which paints one screen
   rectangle. §3 is the whole of how that is done without bringing back the
   chrome stomping it was written to prevent.

4. **There is a frame clock, and it is the PIT.** `wmFrameTick` runs from the
   IRQ0 arm of `isrDispatch`. Damage is coalesced into one screen rectangle
   and presented at most once every `wmPacePeriod` ticks. The PIT is 100 Hz,
   the default period is **2 ticks, so the cap is 50 fps**, and the cap is a
   whole number of ticks rather than a target the machine misses by a
   fraction.

5. **The policy, stated plainly, because "what triggers a frame" is the
   question this ADR exists to answer:**

   * **A frame is presented because something changed.** Damage, not a clock,
     is what makes a frame exist. An idle desktop with a still wallpaper and
     no client activity presents **nothing** and burns no CPU. That is not a
     gap. A compositor that repaints an unchanged screen sixty times a second
     is the defect, not the feature.
   * **The clock is what stops damage from becoming a frame rate.** With the
     pacer armed, a client committing a thousand times a second gets fifty
     presents and the other nine hundred and fifty are folded into them.
   * **With the pacer disarmed, a commit presents inside its own syscall**,
     exactly where a commit's frame has always happened. Nothing that does
     not type `wm pace` changes behaviour at all.
   * **The pointer is never coalesced.** IRQ12 repaints the two cursor
     rectangles the moment a packet decodes, as it always has. Folding the
     pointer into the pacer would add latency to the one thing a person can
     feel, to save 384 pixels.

6. **The paced hot path is silent.** `WM FRAME` and `WM COMMIT` are together
   about four milliseconds of COM1 per frame, which at a fifty-frame cap is
   not instrumentation, it is the budget. Both are suppressed while the frame
   clock is armed and `wm pace log` is off. Event-driven presents still print
   every line they always printed, which is why no byte-exact golden in this
   suite moves (§6).

---

## 2. Before and after, measured

Same binary, same host, same resolution, same boot. `wm fps` stage `K 8`
clears the wallpaper cache before every iteration, so it does exactly what the
code did before this ADR; `K 3` is the same stage with the cache serving it.
`K 9` and `K 5` are the same pair for a whole compose. Four runs at 800x600 on
`-cpu qemu64` (TCG) with `-vga std`:

| stage | before | after | ratio |
|---|---|---|---|
| generative wallpaper (`K 8` / `K 3`) | 8.3–10.9 ms | **0.41–0.55 ms** | **17–23x** |
| full compose (`K 9` / `K 5`) | 48.4–55.9 ms (17.9–20.7 fps) | **40.3–44.6 ms (22.4–24.8 fps)** | 1.18–1.25x |
| a client update (`K 9` / `K A`) | 48.4–55.9 ms | **2.7–3.0 ms** | **17–19x** |

The third row is the one that matters, and it needs saying carefully. Before
this ADR a client's 16x16 commit under `wm gfx` **was** the first column: the
gfx arm threw the rectangle away and recomposed the world. It is now a
damage-limited present, which is the fourth stage `wm fps` grew for this ADR
(`K A`, a 64x64 rectangle through `wmRepaintRect` — what the frame clock
actually does on a tick).

The second row is small on purpose and the reason is §8: a full compose is now
**almost entirely the Skia session tick** (`K 4`, 40–47 ms of a 40–45 ms
frame). The wallpaper was 57% of a frame and is now under 2% of one; the
chrome re-stamp is what is left, and it is not this ADR's to move.

`wm fps` also had a measurement defect that had to be fixed before any of the
above could be believed: its iteration cap left the loop by assigning
`now = target`, so a stage that hit the cap printed the **whole budget** as
its elapsed time. A stage that gets fast enough to hit the cap is precisely
the stage the command exists to detect — cached `K 3` reached 3000 iterations
in a fraction of the budget and reported the full 120 ticks, which reads as
"unchanged" and was in fact a twentyfold speed-up. The exit is a flag now and
the printed tick count is the measured one on both exits.

The paced rate itself is measured out of the running OS rather than out of a
stage timer. `de-pace/run.sh` brackets a wall-clock window with two `WM PACE`
reports while a resident client floods the compositor:

```
paced window: 8.368s   PRES 416   COAL 226586
presented 49.7 fps against a stated 50 fps cap
```

226,586 damage marks folded into 416 presents is a coalescing ratio of 545:1,
and 49.7 fps against a 50 fps cap is the cap being met rather than approached.

**And the cap is what bounds it, not the cost of a present.** That distinction
needs its own measurement, because if a paced frame simply took 20 ms then
"50 fps cap" would be a coincidence and the policy would be a fiction. So the
harness halves the period in the same boot, with the same client committing at
the same rate:

```
paced window: 8.354s   PRES 416   COAL 220729
halved cap:   5.352s   PRES 134   COAL 144935
50 fps cap -> 49.8 fps; 25 fps cap -> 25.0 fps; ratio 1.99
```

A present costs 2.7–3.0 ms (`K A`), so the clock has about 17 ms of slack per
frame at the 50 fps cap and 37 ms at the 25 fps cap. The rate follows the
period, which is what a cap means.

---

## 3. Honouring damage without stomping the chrome

ADR-0183 set the gfx arm of `wmComposeCommit` to full-compose **on purpose**.
The reason was real and is worth restating, because the temptation is to read
it as an oversight: a Dart damage repaint stamped solid pearl over the
session's antialiased title band and solid red over its blurred close button,
and Dart had no way at all to put the generative desktop back. Under those
conditions a full compose was the only faithful answer, and paying 220 ms for
a 256-pixel change was the price of being right.

Three things had to become true before the rectangle could be believed again.
All three now are, and each is checked by the harness rather than asserted
here:

1. **Dart can paint the desktop.** `wmDeskPixel` reads the cached generative
   field. Before the cache, Dart's only desktop colour was one flat
   `wmColorDesktop`, and stamping that into a damage rectangle painted a blue
   hole in the field. `de-pace` walks the pointer across the desktop in twenty
   steps and then asserts that the 12x16 rectangle the arrow vacated holds no
   `0x00184060` at all and more than two distinct colours — 117 of them, in
   192 pixels, in the run recorded above.

2. **Dart declines every pixel the session owns.** `wmTitlePixel`,
   `wmChromePixel`, `wmWindowPixel`'s border arm, the new `wmGfxCornerHole`
   (which mirrors `wmBlitRow`'s corner inset, so a damage pass cannot reopen
   the hole ADR-0187 closed) and `wmPixelAt`'s popover arm all answer
   `wmNoPixel` under gfx. A damage pass paints client shm and cached
   wallpaper and **nothing else**.

3. **The chrome on the screen is known to be current.** `wmGfxChromeSig` folds
   every input `osgfx_session_paint` reads — the window set and their
   geometry, the top slot, keyboard focus, the DE and popover state and
   position, the wallpaper mode — into one word. `wmCompose` stamps it
   **after** the session tick, so a fault inside Skia leaves it stale.
   `wmGfxChromeFresh` compares it, and while it holds still, damage is
   honoured. A raise, a map, a minimise, a focus change, a popover or a
   wallpaper change moves it and the next present is a full compose, which is
   the only thing that can repaint chrome.

That third point is the load-bearing one, and it is why this is not a
regression of ADR-0183 but a discharge of its condition. ADR-0183's claim was
"Dart must not paint where the session paints". That claim is still enforced,
by (2). What has changed is that there is now a *test* for whether the
session's output is stale, so "recompose the world" stops being the only safe
answer to "something small changed".

`de-session/run.sh` (60 checks) is the regression that says the chrome
survived: after this change it still finds the Skia vertical gradient in the
title band, the Start pill, the close button's antialiased fringe and the
proportional outline caption. `de-pace/run.sh` re-probes all four **after
14,246 damage-limited presents**, which is the interesting version of the same
question.

---

## 4. The paced present is Dart only, and Skia never runs in an interrupt

`wmFrameTick` presents through `wmRepaintRect`, which resolves every pixel
through `wmPixelAt`: the client's shm, the cached wallpaper, and `wmNoPixel`
wherever chrome owns the pixel. It does not call `osgfx_guest_tick`.

This is not squeamishness. ADR-0172 established that the guest Skia heap is
not reentrant and that the session tick runs in shell context; calling it from
IRQ0 would let a timer land in the middle of a `wm de` compose and corrupt the
allocator. So chrome changes go where they always went — through a full
compose in process or shell context — and the clock's job is confined to what
is safe to do from an interrupt.

Two guards make that concrete:

* **`wmMetaBusy`.** A commit composes inside a syscall with interrupts on, and
  two painters in one framebuffer is a torn frame. A tick that finds the guard
  set returns, leaves the damage pending, and the next tick presents it. This
  is `wmPointerTick`'s existing rule, applied to the clock.
* **Order within the IRQ0 arm.** `wmFrameTick()` is called **before**
  `procTick(frame)`, because `procTick` on one path does not return — it
  switches into a process — and a clock called after it would stop for the
  duration of every session.

---

## 5. Where the state lives, and why it is not `@bss`

The 24-word `wmStore` meta block is full, and eleven harnesses — m19-argv,
m20-ipc, m21-shmem, d1-mouse, d2-compositor, d2-input, d7-click, d8-chrome,
d8-title, d9-focus, osxui1-pop — assert the kernel's mutable static total **to
the byte**, several of them by name as "no new `@bss`". A pacer that donated a
block would move all eleven for a reason none of them is about. And a 3.5 MiB
wallpaper cache could not have come from static storage in any case.

So the state is **one page from the frame allocator**, and its address is the
one new word in the osgfx mailbox: `OsGfxGuestCmd.wmpage`, in `.data`, at
offset 120. That word takes the struct to sixteen words — exactly the 128
bytes the linker script already aligns `.osmedia_cmd` to — so `mediaBoxOff` in
`kmedia.dart` still points at the media mailbox. `de-pace` counts the struct's
words and re-derives that arithmetic, so a seventeenth word is a FAIL rather
than a silently relocated media box.

`wmpace.dart` owns the page's word layout; `osgfx_guest.h` names only the five
words `osgfx_desk.c` reads or writes. Both sides check a `'WMPAGE1'` magic
before believing any other word, because `wmpage` is an address Dart wrote and
a zeroed frame is the one thing neither side may mistake for a valid header.

**The wallpaper buffer is a contiguous run, and the contiguity is checked
rather than assumed.** `allocFrame` is next-fit from a cursor, so consecutive
calls normally return consecutive frames — and *normally* is not a property.
`wmDeskEnsure` compares every frame against the run it is meant to extend and
gives the whole run back at the first one that is not, leaving the cache off;
`osgfx_desk.c` then generates straight into the scanout, slower and correct.
A screen that grows past the buffer frees the old run before taking a new one,
so a resolution change is not a permanent leak.

The cache is allocated only under `wm de`, because that is the only flag
combination under which `osgfx_session_paint` reaches the generative desk at
all. `de-osgfx`, which never types it, takes no frames from the allocator and
its baseline does not move.

---

## 6. Why cutting the serial line moves no golden

`wmPublishFrame` now forwards to `wmPublishFrameQ(px, 0)`, and the pixel count
is published to the meta words either way — **only the line is optional**. The
`WM COMMIT` line is guarded by `wmPaceQuiet`, which is one load and one
compare and returns 0 unless the frame clock is armed with logging off.

Nothing in this suite types `wm pace`. Every harness that counts `WM FRAME` or
`WM COMMIT` lines therefore sees exactly the lines it always saw, and
`de-pace` asserts both halves of that: that the pacer suppresses, and that
`wmPublishFrame(px)` still exists on the event-driven paths.

The same conditional protects GAP-0058's still tick counter.
`picUnmaskKeyboardOnly` — which runs at the end of `ticks`, at the end of
every process session, and from `wm fps` — has masked IRQ0 since M2, and that
is what lets `ticks` print a byte-exact number. It now masks IRQ0 **unless the
pacer is armed**. A machine that has not typed `wm pace` reads one word out of
`.data`, finds zero, and masks the timer exactly as it has since M2.

---

## 7. Shell surface

| command | effect |
|---|---|
| `wm pace` | arms the frame clock at 2 ticks (50 fps), unmasks IRQ0, prints `WM PACE` + `WM DESK` |
| `wm pace 4` | the same policy at 4 ticks (25 fps). Not a convenience: §2's halved-cap measurement is the only thing that distinguishes a cap from a cost, and it needs this command |
| `wm pace off` | disarms, restores the PIC mask the shell keeps unless a process is resident, prints the report |
| `wm pace log` | arms, and prints `WM FRAME` / `WM COMMIT` for paced frames too. A debug run, not a default |

`WM PACE <armed> HZ <hz> P <period> PRES <n> COAL <n> LATE <n>` followed by
`WM DESK PX <n> FRM <n> REGEN <n> BLIT <n> READ <n>`. One report, so a reader
can divide: `PRES` over wall time is the achieved rate, `COAL` over `PRES` is
the coalescing, `LATE` is ticks on which damage was pending and the budget
said no, `REGEN` is how many times the field maths ran (**1**, for the life of
a boot), `BLIT` how many session paints one generate served, and `READ` how
many desktop pixels a damage repaint took out of the cache.

---

## 8. What this ADR does not do

**The DE chrome re-stamp.** It was 44% of a frame before this change and it is
now essentially all of one: 40–47 ms of a 40–45 ms compose. It is left alone
deliberately, because a sibling worker is concurrently rewriting chrome to use
real Skia text and shapes in `osgfx_session.c` and the osxui FRAME paint path,
and two workers restructuring the same paint is how both changes get reverted.
The opportunity is recorded as **GAP-0330** with the shape it should take:
`wmGfxChromeSig` already exists and already answers "would Skia draw something
different", so a chrome cache has its invalidation condition written and
tested. That is the ADR's contribution to the problem it did not solve.

**A real vsync.** The clock is the PIT, not the display. There is no vblank
interrupt from stdvga or virtio-gpu on this path and no fence on the Venus
one, so "present" means "the compositor finished writing the scanout it shares
with the host", and tearing against the host's own read is possible and
unmeasured. The cap is expressible only in whole PIT ticks, so the rates this
policy can name are 100, 50, 33, 25 and so on — 60 is not one of them.
Recorded as **GAP-0331**.

**Coalescing is a union, not a list.** Two damaged rectangles at opposite
corners present as the bounding box that contains both. A list is a queue that
can overflow and then has to decide what to drop; the union of everything that
changed is never wrong, only sometimes bigger than it had to be. `COAL` and
`PRES` are printed so that how much bigger is a number a reader has rather
than a worry. Recorded as **GAP-0332**.
