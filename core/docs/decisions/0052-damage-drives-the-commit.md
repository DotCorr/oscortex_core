# ADR-0052 — Damage drives the commit: a 16×16 present is 256 pixels, not 480,000

**Status:** accepted, implemented (`core/kernel/wm.dart`, `core/tests/conformance/d2-compositor`).
**Depends on ADR-0050** (the compositor owns the framebuffer) **and ADR-0051** (the surface
protocol already carries a damage rectangle).
**Closes GAP-0301.** D6 in `docs/design/display-protocol.md` §6.

---

## 1. The question

Every `wmOpCommit` already named a damage rectangle. ADR-0051 printed it and then composed a full
frame — 480,000 desktop stores plus every window — because D6's exit criterion is a *small*
pixels-per-frame count, and shipping the mechanism without the harness that makes the number mean
something is how a milestone becomes unfalsifiable. `wmMetaPixels` was that number, waiting.

D5b then built `wmRepaintRect`: the same picture `wmCompose` paints, one pixel at a time, over a
rectangle. A drag uses it. A commit had no reason not to.

**So the decision is one sentence: a commit paints the damage the client named, and the count on
that frame is the area of that rectangle.**

---

## 2. Two sizes of damage, and why they are different

| what the client sends | what is painted | why |
|---|---|---|
| the whole surface `(0, 0, w, h)` | the **decorated** window, and every other live window if this one is on top | the border is compositor-owned; a first present has to put it on the screen. Repainting the others is what turns the previous top's border from bright to dim — a full compose did that for free, a damage pass of only the new window would leave it stale |
| anything smaller | that rectangle, in **screen space** (`origin + damage`) | that is the count D6 exists to make small |

Refused rather than clamped if the rectangle does not fit the surface, for ADR-0051's reason: a
clamp turns a client's off-by-one into a compositor that paints the wrong pixels and reports them
as the right ones. The overflow-safe order is *origin inside, then extent no larger than what
remains*.

`wm on` and `wm draw` still compose a full frame. They have no damage to honour.

---

## 3. The trap that does not apply here

`display-protocol.md` §3.5 says the single most likely bug in a first damage implementation is
composing only the current damage into a *back* buffer that is two frames stale. **This compositor
does not flip.** It writes the visible scanout in place (ADR-0050: ring 3 cannot execute `out`,
and the framebuffer is a PCI aperture, not a shareable GEM object). Damage is therefore "what
changed in the one buffer", not "what the back buffer is missing from two frames ago."

If a flip ever lands, this ADR's rule becomes insufficient and the union-of-both-buffers rule in
§3.5 has to be built. That is a new ADR, not a silent edit of this one.

---

## 4. The pointer

A full compose erases the pointer (it fills the desktop) and redraws it last. A damage rect that
misses the cursor leaves the pixels IRQ12 already put there; redrawing would be a second copy of
the same arrow. A damage rect that intersects the cursor overwrites part of it, so the arrow is
redrawn. The cursor's pixels are **not** added to `wmMetaPixels` — `wmCompose` never counted them
either, and D6's number is the damage, not the decoration the compositor puts on top of it.

---

## 5. What the harness asserts, so the number means something

`d2-compositor/prog.c` already committed the whole surface twice. It now commits a third time: a
16×16 of a colour that is nowhere else on the surface, from side 1, after the full present.

`derive.py` computes four counts from the same constants:

* frame 1 (`wm on`) = 800 × 600
* frame 2 (A's first present, only window) = one decorated window
* frame 3 (B's first present, now on top) = two decorated windows — B, and A so A's border goes dim
* frame 4 (the 16×16) = 256

and refuses to emit any of them if the 16×16 is empty, if its colour matches what it overwrites, or
if 256 is not strictly smaller than a decorated window which is not strictly smaller than the
desktop. A compositor that still composed a full frame on commit would print `00075300` on frame 4
and fail. A compositor that ignored the 16×16 and painted the whole window would print the
decorated count and fail the same line.

The framebuffer dump is taken after that fourth frame. Probe `b_damage` is the centre of the 16×16,
the colour `prog.c` wrote there. A compositor that painted the right *count* of the wrong *pixels*
fails that probe.

---

## 6. What this does not close

* **Exact regions.** A bounding box over-draws. `display-protocol.md` §3.5 and §6 say an exact
  region needs a data structure `@bare` DCDart cannot express yet. GAP-0301's *cost* is closed;
  the *shape* (a box, not a region) remains.
* **D3, D7.** A client is still never told it was damaged, moved, or clicked (GAP-0308). A commit
  is still paid for by the caller (GAP-0303), just a much smaller bill.
* **Intersection subtraction on a drag.** A one-pixel move still paints two window-sized
  rectangles. That is GAP-0302, not this file.
