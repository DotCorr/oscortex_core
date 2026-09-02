# ADR-0111 — Title-drag is DE policy: origin moves, surface follows

**Status:** accepted, implemented (`wmTitleHit` in `wmchrome.dart`,
gate in `wmGrab`, harness `core/tests/conformance/de-wm`).
**Depends on ADR-0075** (title bars) and **ADR-0106** (`wm de`).
**Does not close** resize, or configure / enter/leave (GAP-0308).
**Number:** 0111 — 0106 is DE chrome. 0109 is `shmMax` 4. Do not
reuse those. 11 stays `fdwait`.

---

## 1. The question

Close, min, start, and the reflection panel landed behind `wm de`
(ADR-0106). A person sitting at the machine also expects to *move* a
window by dragging its title. Without DE, a press anywhere on the
window starts a drag (`d2-compositor`). That is the wrong policy once
the client owns the body: a click in the fill would steal the press
as a move.

Resize is the other missing GAP-0302 piece. It needs a new geom and
a client that can be told. Title-drag does not.

---

## 2. The decision

1. **Under `wm de`, only the title strip starts a drag.**
   `wmTitleHit` is the caption rectangle. Close and min sit inside
   it; `wmDeGrab` consumes those first. A title press focuses, raises,
   and arms `wmMetaDrag`. It is not enqueued to the client — the
   caption is chrome.
2. **A body press still reaches the client.** Focus and raise stay.
   Drag does not start. `d7-click` never types `wm de`, so its body
   press still enqueues and still arms a drag.
3. **Without `wm de` the old path is unmoved.** Any window hit
   enqueues and starts a drag. `d2-compositor`, `d8-chrome`,
   `d8-title`, and `d9-focus` never type `wm de`.
4. **No new syscall. No help line. 11 is still `fdwait`.**
   `shmMax` stays ≥ 4. `wmStore` is not shrunk. Sit-in already types
   `wm gfx` then `wm de`.

### 2.1 What this is not

It is not resize. It is not configure / enter/leave. The client is
still not told it moved. The pixels move because the compositor
paints the same region at a new origin.

---

## 3. The harness

`de-wm/` builds a FAT volume with `WIN.ELF`, types `fb`, `wm on`,
`wm de`, `proc spawn WIN.ELF`, and drives a derived title grab:

* serial carries `WM MOVE W 0 X <new> Y <new> FROM <old>`
* the vacated origin is desktop
* the caption and the client fill land at the derived new origin
* a body press plus the same delta prints no `WM MOVE` and leaves
  the fill where it was
* the reflection panel lists the live name after spawn and lists
  zero after close

`d7-click`, `d8-chrome`, `d8-title`, `d9-focus`, and `de-chrome`
stay on their pictures because they never type this path's new
gate, or they type `wm de` and only click (no title drag).
