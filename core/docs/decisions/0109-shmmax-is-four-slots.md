# ADR-0109 — shmMax is four slots so Start can spawn

**Status:** accepted, implemented (`shm.dart` / `wm.dart` / `wmevent.dart`,
harness `core/tests/conformance/de-shm`).
**Depends on ADR-0041** (shared regions), **ADR-0051** (`wmsurface`),
**ADR-0106** (`wm de` start), **ADR-0108** (sit-in FAT names).
**Does not change** syscalls 16–19 or 23. **11 stays `fdwait`.**
**Number:** 0109 — 0106 is DE chrome. 0107 is osgfx-gl (sibling).
0108 is sit-in FAT. Do not reuse those.

---

## 1. The question

Sit-in Start lists `FILES.ELF`, `SET.ELF`, `PING.ELF`, `STUDIO.ELF`
(ADR-0108). A session that already holds two surfaces (`FILES` +
`PING`) refused the next attach with `wmRetNoSpace` / `shmRetNoSpace`
because `shmMax` was 2 and `wmMaxWindows` was derived from it.

Growing the existing tables is enough. A new syscall is not.

---

## 2. The decision

1. **`shmMax = 4`.** Four region records. `shmCapsPerProc` was already
   4, so one process can hold one capability for each region.
2. **The window stays one page-directory entry.** `vmShmPages` is still
   512. Four slots of `shmSlotPages = 128` tile `[vmShmBase, vmShmEnd)`.
   Today's FRAME surfaces are 38 pages (240×160). A full-screen 469-page
   frame still does not fit (GAP-0237). No `vmShmLeafSlot` rewrite. No
   virtgpu rewrite.
3. **`wmMaxWindows = 4` and `wmeventSlots = 4`.** A window's pixels
   live in a region, so the three numbers stay equal. `d2-compositor`
   and `d7-click` keep asserting that.
4. **`.bss` grew in place, last stays last.** `shmStore` 4352 → 4480
   (+128). `wmStore` 320 → 448 (+128). `wmeventStore` 192 → 384 (+192).
   Total 22816 → 23264. `wmeventStore` is still last (ADR-0031 §4.3
   rule 5 / newest-last). No new `@bss` symbol.
5. **No help line. No new syscall. 11 is still `fdwait`.**

### 2.1 What this is not

It is not glyphs on Start rows (those are still colour bands). It is
not a second page-directory entry. It is not virtio-gpu / osgfx-gl
(0107). It is not a guest OS.

---

## 3. The harness

`de-shm/` builds a FAT16 volume with three derived ELFs (`A.ELF`,
`B.ELF`, `C.ELF`). Each attaches a surface of a distinct derived
colour and yields. After `fb`, `wm on`, `wm de`, Start clicks the
three launch rows (typed spawn after the first attach would lose
keys to keyboard focus, ADR-0062):

* serial carries `DE SHM A`, `DE SHM B`, `DE SHM C` and three commits
* `WM ATTACH` count ≥ 3
* framebuffer probes at the three derived centres still hold those
  fills — a table that dropped the first two to make room for the
  third fails A and B

`d2-compositor`, `d7-click`, `d8-chrome`, `d8-title`, `d9-focus`,
`de-chrome`, and `de-sitfat` stay on their pictures: two-window
boots still use two of four slots.
