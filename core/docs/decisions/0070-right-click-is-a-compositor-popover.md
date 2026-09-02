# ADR-0070 — Right-click is a compositor-owned popover

**Status:** accepted, implemented (`core/kernel/wmpop.dart`, hooks in `wm.dart`,
`core/tests/conformance/osxui1-pop`).
**Depends on ADR-0050** (the compositor owns the framebuffer and hit-tests).
**Does not close GAP-0302.** A popover is the start of a native desktop UI
primitive, not close, resize, live-edit, or reflection.
**Number:** 0070 — 0067 is G2 DRIVER_OK; this file was the other 0067.

---

## 1. The question

D1 decodes three button bits. `wmPointerTick` kept only bit 0. A left press
raises, drags, and (ADR-0055) enqueues. Right and middle were ignored. A
person sitting at the machine expects a right press to *do something that
belongs to the compositor*: a small rectangle near the pointer, not a client
click and not a drag.

The first inspector will attach here later. This milestone is pixels and a
hit region. It is not live-edit.

---

## 2. The decision

1. **Spare words, not a new block.** `wmMetaPop` is index 21 of the existing
   24-word `wmStore` meta block (1 while showing). `wmMetaPopXY` is index 22,
   packed `(x << 32) | y`. Chrome is 19. Focus is 20. Word 23 remains free.
   `wmInit` already zeroes the block. No `@bss`, so `wmeventStore` stays last
   and every harness that measures `wmStore` at 320 is unmoved.
2. **On whenever the compositor is on.** `wmPointerTick` already returns if
   `wm` is off. Sit-in types `wm on` and can show the popover without
   `wm chrome`. No shell command. No help line (GAP-0304). No syscall.
3. **Geometry is compositor-owned.** 96×64, origin at pointer + `wmPopGap`
   (8) on each axis, clamped to the framebuffer. Colour `wmPopColor`
   (`0x00C04088`): not the desktop (`0x00184060`) and not the chrome strip
   (`0x00C09048`). Drawn after chrome and before the pointer. Named so the
   host model reads them.
4. **Right PRESS shows it. Left press dismisses it.** `wmPointerTick` edge-
   detects bit 1 separately from bit 0. A right down-edge calls `wmPopShow`
   and does not call `wmGrab`. A left down-edge that finds the popover
   showing hides it; a hit on the popover itself is consumed (no raise, no
   drag, no `wmevent`). A left press elsewhere dismisses and then proceeds
   as a normal grab. Middle is still ignored.
5. **The popover is in `wmPixelAt`.** A cursor erase or a damage pass that
   intersects the rectangle must put the popover colour back, or the arrow
   punches a hole. Chrome still has that gap; the popover does not.

### 2.1 What this is not

It is not a menu of items, not close, not resize, not live-edit, and not
reflection. The rectangle has no text. A later inspector attaches to the
same hit region. GAP-0302 keeps the rest.

---

## 3. Why chrome does not consume the right-click

Chrome already consumes a *left* press on the strip. The popover is a
different policy: a right press anywhere, while `wm` is on, is the
compositor's. Putting it behind `wm chrome` would hide it from sit-in.
The strip and the popover can both be on; they do not share a word.

---

## 4. The harness

`osxui1-pop` types `fb`, `wm on`, injects a host-derived motion and
`btn:right:down` / `btn:right:up` through the same QMP vocabulary D1 uses,
reads the framebuffer back with `pmemsave`, and asserts the derived colour
at the derived popover centre. Phase two left-clicks the desktop (outside
the rectangle) and requires that colour gone. A second boot left-clicks
only and requires the popover colour nowhere at those coordinates.

No new `.bss`. `wmeventStore` stays last. `shellStrHelp` is untouched.
