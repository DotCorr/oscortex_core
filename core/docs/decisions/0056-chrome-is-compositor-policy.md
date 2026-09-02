# ADR-0056 — Chrome is compositor policy, and it is off by default

**Status:** accepted, implemented (`core/kernel/wmchrome.dart`, hooks in `wm.dart`,
`core/tests/conformance/d8-chrome`).
**Depends on ADR-0050** (the compositor owns the framebuffer).
**Does not close GAP-0302.** A taskbar strip is the start of window-manager chrome,
not close, resize, or keyboard focus.

---

## 1. The question

A composed desktop is a field of windows and a pointer. A person sitting at the
machine also expects a *reserved strip* that belongs to the compositor: a place
that is not a window, that does not start a drag, and that later chrome (close,
raise-from-list) can grow into. That strip is policy, not protocol.

`d2-compositor` derives every pixel colour from a full 800×600 desktop. A 24-pixel
bar painted on every `wm on` would move those probes. So the strip has to exist
and it has to be **off unless asked for**.

---

## 2. The decision

1. **A spare word, not a new block.** `wmMetaChrome` is index 19 of the existing
   24-word `wmStore` meta block. Words 0–18 are D4/D5b; 20 is D9 keyboard
   focus (ADR-0062); 21–23 remain free.
   `wmInit` already zeroes the block, so the flag is 0 on every boot. No `@bss`,
   so chrome does not move the kernel's mutable-static total (D7's later
   `wmeventStore`, if present, is that line's number) and every harness that
   measures `wmStore` at 320 is unmoved.
2. **One shell command, `wm chrome`.** It sets the flag, prints
   `WM CHROME ON H <height> PX <strip pixels>`, and recomposes if the compositor
   is already on. Not a syscall. Not a client descriptor field. Not a `help`
   line (GAP-0304).
3. **Geometry is compositor-owned.** The strip is the bottom `wmChromeH` (24)
   rows, full `fbWidth` (800), colour `wmChromeColor` (`0x00C09048`). Drawn
   after the windows and before the pointer, by `wmChromeDraw` from `wmCompose`.
4. **A press on the strip is consumed.** `wmGrab` asks `wmChromeHit` first. A
   hit does not raise and does not start a drag. The click is not delivered to
   a client either — that is D7, and chrome is compositor policy either way.

### 2.1 What this is not

It is not close, minimise, resize, or keyboard focus. Title bars landed as
ADR-0075 on the same flag: off unless `wm chrome`. A damage pass does not
paint the taskbar strip: only a full compose does. A window that is
dragged onto the bar will overwrite those pixels until the next `wm draw` /
`wm chrome`. GAP-0302 keeps close, resize, and minimise.

---

## 3. Why no syscall

ADR-0051's descriptor is a legal channel message and names a capability plus
a geometry or a damage rectangle. Chrome is not a surface. Putting an on-flag
in that descriptor would make every client carry compositor decoration policy
and would be a protocol change the moment the compositor moved to ring 3.
The flag is a word the shell sets. When the compositor becomes a process, the
same word is a field of that process's own state.

---

## 4. The harness

`d8-chrome` types `fb`, `wm on`, `wm chrome`, reads the framebuffer back with
`pmemsave` at the address the kernel reported, and asserts a host-derived
colour on the bottom strip. The serial line carries the same height and pixel
count the host computed. A second boot types only `fb` / `wm on` and requires
the strip to still be the desktop colour — chrome is off unless asked.
`d2-compositor` is the same default-off contract on the two-window picture;
on this branch it currently dies in STRUCTURAL because D7 moved last-block
to `wmeventStore`, not because chrome painted.
