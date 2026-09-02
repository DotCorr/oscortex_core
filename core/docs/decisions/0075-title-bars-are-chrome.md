# ADR-0075 — Title bars are compositor chrome, and they share `wm chrome`

**Status:** accepted, implemented (`core/kernel/wmchrome.dart`, decorate
hooks in `wm.dart`, `core/tests/conformance/d8-title`).
**Depends on ADR-0056** (chrome is compositor policy and off by default).
**Does not close GAP-0302.** A caption strip is the next piece of
window-manager chrome, not close, resize, or minimise.
**Number:** 0075 — 0074 is already claimed twice (N3 ICMP echo; NVM1
CAP/VS). This file is the first 0075.

---

## 1. The question

A composed window is a client rectangle and a 3-pixel border. A person
sitting at the machine also expects a *caption*: a reserved strip at
the top of each window that belongs to the compositor, that a drag
still starts from, and that later chrome (a close hit, a title string)
can grow into. That strip is policy, not protocol.

`d2-compositor` derives every pixel colour from the client's fill and
the border. An 18-pixel bar painted on every attach would move those
probes. So the caption has to exist and it has to be **off unless
`wm chrome` is on**.

---

## 2. The decision

1. **The same flag, not a new word.** Title bars read `wmMetaChrome`
   (index 19). ADR-0056 already zeroes it on boot. No `@bss`. Word 23
   remains free. `wmStore` stays 320. `wmeventStore` stays last.
2. **Geometry is compositor-owned.** `wmTitleH` is 18 (inside 16–20).
   The strip is the top 18 rows of each live window's *content*
   rectangle, colour `wmTitleColor` (`0x00D8B060`): not the desktop
   (`0x00184060`), not the taskbar (`0x00C09048`), not either
   d2-compositor fill. Named so the host model reads them.
3. **Decorate path, two call sites.** `wmDrawWindow` blits the client
   and then calls `wmTitleDraw`. `wmWindowPixel` asks `wmTitlePixel`
   before it reads the region, so a damage pass and a cursor erase
   put the caption back. A default-off compose writes the same pixels
   it wrote yesterday; the title functions return 0 / `wmNoPixel`.
4. **A press on the title is still a window press.** The strip sits
   inside the surface, so `wmHit` / `wmGrab` already raise and start
   a drag. Chrome's taskbar is the consumed hit; the caption is not.
   No close hit: an 8×8 reap would be a third policy and would have
   to prove it does not break `d3-session`. GAP-0302 keeps it.
5. **No syscall. No help line.** Same reasons as ADR-0056 §3 and
   GAP-0304.

### 2.1 What this is not

It is not text, not a font, not close, not minimise, not resize, and
not a client-painted caption (that is OSXUI2's shape). A FRAME client
that paints its own top rows still loses them when chrome is on —
the compositor owns those pixels for the same reason it owns the
border.

---

## 3. Why not a strip above the surface

Putting the caption *outside* the content rectangle would extend
`wmFits`, `wmClampOrigin`, and the decorated hit box. Windows
already attach at `y >= wmBorder`. Growing the top margin when
chrome turns on would either refuse existing geometries or clip
the strip off the screen. Painting the top of the content keeps
every attach that is legal today legal after `wm chrome`, and a
press on the caption has a well-defined grab offset (`y - origin`
is non-negative).

---

## 4. The harness

`d8-title` builds d2-compositor's two-window disk, types `fb`,
`wm on`, `wm chrome`, then `proc coop`, reads the framebuffer back
with `pmemsave`, and asserts the host-derived title colour on the
top row of window A. A second boot types only `fb` / `wm on` /
`proc coop` and requires that row to still be the client's fill —
titles are off unless asked. `d8-chrome` is unmoved: its chrome-on
boot has no windows, and its default-off boot still photographs a
bare desktop.
