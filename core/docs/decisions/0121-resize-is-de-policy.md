# ADR-0121 — Resize is DE policy: geom w/h change, same shm, clip

**Status:** accepted, implemented (`wmResizeHit` in `wmde.dart`,
`wmResizeStep` / `wmClampSize` in `wm.dart`, harness
`core/tests/conformance/de-resize`).
**Depends on ADR-0111** (title-drag under `wm de`) and **ADR-0106**
(`wm de`).
**Does not close** configure / enter/leave (GAP-0308). The client is
not told the new size. Growing the shm is leftover.
**Number:** 0121 — 0120 is the settings toggle. Do not reuse 0111.

---

## 1. The question

Title-drag under `wm de` moves the origin (ADR-0111). A person sitting
at the machine also expects to *resize* a window by dragging an edge.
Without a new geom the compositor can only paint the attach rectangle.
A new syscall so the client can grow its shm is the other half, and
it is not this slice.

---

## 2. The decision

1. **Under `wm de`, the SE corner starts a resize.**
   `wmResizeHit` is the last `wmResizeEdge` pixels of the content plus
   the border. Close and min sit in the title; `wmDeGrab` consumes
   those first. An SE press focuses, raises, and arms a marked grab
   (`wmResizeMark` on the existing grab-X word). It is not enqueued —
   the handle is chrome.
2. **Geom w/h change. Origin stays.** `wmResizeStep` writes a new
   packed geom. The same region is painted; `wmBlitRow` already walks
   the current w/h, so the client fill is clipped to the new rect.
   Max size is the attach stride / region (no shm grow). Min size is
   `wmResizeMinW` × `wmResizeMinH`.
3. **Title-drag still moves.** A caption press arms an unmarked grab
   and prints `WM MOVE`. It does not print `WM RESIZE`. A body press
   does neither.
4. **Without `wm de` the old path is unmoved.** Any window hit
   enqueues and starts a drag. `d7-click`, `d8-chrome`, `d8-title`,
   and `d9-focus` never type `wm de`.
5. **No new syscall. No help line. 11 is still `fdwait`.**
   `shmMax` stays ≥ 4. `wmStore` is not shrunk. Sit-in already types
   `wm de`. SET may keep its chrome-word bit; this slice does not
   touch word 19.

### 2.1 What this is not

It is not configure. The client still paints the attach size into the
same shm and is not told the clip. Growing past that shm is GAP-0308.
It is not a `plat/osgfx` rewrite.

---

## 3. The harness

`de-resize/` builds a FAT volume with `WIN.ELF`, types `fb`, `wm on`,
`wm de`, `proc spawn WIN.ELF`, and drives a derived SE grab:

* serial carries `WM RESIZE W 0 W <new> H <new> FROM <old> H <old>`
* vacated old SE is desktop; title origin is unmoved
* a fill pixel inside the new rect is still the client colour
* a title-drag of the same window prints `WM MOVE` and not
  `WM RESIZE`; the origin changes and w/h do not
* a body press plus the same delta prints neither line and leaves
  the fill where it was

`d7-click`, `d8-chrome`, `d8-title`, `d9-focus`, `de-chrome`, and
`de-wm` stay on their pictures because they never type this path's
new hit, or they type `wm de` and do not grab the SE handle.
