# ADR-0106 — DE chrome is compositor policy: close, min, start, panel

**Status:** accepted, implemented (`core/kernel/wmde.dart`, hooks in
`wm.dart` / `wmchrome.dart` / `wmpop.dart` / `shell.dart` / `proc.dart`,
`core/tests/conformance/de-chrome`, `sit-in.sh` types `wm de` and clicks
start). Sit-in's disk is a FAT volume with 8.3 ELFs (ADR-0108).
**Depends on ADR-0056** (chrome flag) and ADR-0075 (title bars).
**Does not close** resize, or configure / enter/leave (GAP-0308).
**Number:** 0106 — listed `decisions/` after 0098 (G9 is 0097). 0100 is
the file manager; 0103 is FFmpeg; 0104 is osgfx; 0105 is settings.
Right-click kind 1 is unmoved (ADR-0070).

---

## 1. The question

`wm chrome` paints a strip and titles. A person sitting at the machine
also expects to *close* a window, *minimise* it to the strip, *start*
another program from a list of names, and *see* which surfaces are
live. Those are compositor policy, not a new syscall and not a
protocol field.

`d8-chrome` and `d8-title` photograph `wm chrome` alone. Painting
buttons on every chrome-on compose would move those exact-rect probes.

---

## 2. The decision

1. **A second level on the same word, not a new block.** `wm chrome`
   writes 1. `wm de` writes level 2 in the low nibble of word 19 and
   packs up to four FAT directory indices above it. Existing draw/hit
   tests `> 0`, so titles and the strip still paint. DE widgets only
   when `(chrome & 0xF) >= 2`. No `@bss`. `wmStore` stays 320.
   `wmeventStore` stays last.
2. **Close tears down the surface/slot.** No new syscall. The compositor
   frees the window, reprints the desktop, and kills the owner
   (`procKillId`). If that process is on the CPU, it is marked
   `procStateKilled` and reaped on the next yield or tick.
3. **Min is a held state that does not paint.** `wmWinMin = 2`.
   `wmWindowUsable` stays LIVE-only. A taskbar slot restores it.
4. **Start lists spawnable 8.3 ELF names** cached during `wm de` (task
   context, not IRQ). Activating a row is the same guts as syscall 26
   (`fatLookup` + `procCreate(0,1)`). Kind 2 on the existing popover
   word. Kind 1 (right-click) is unmoved.
5. **The reflection panel lists live slots and pids** from `wm`
   (kind 3). After a spawn the count rises; after a close it falls.
6. **No help line. No syscall.** Same reasons as ADR-0056 §3 and
   GAP-0304. 11 is still `fdwait`.

### 2.1 What this is not

It is not resize. It is not configure / enter/leave. It is not a
`plat/osgfx` rewrite. Sit-in still shows boxes until GPU lands.

---

## 3. The harness

`de-chrome/` builds a FAT volume with `WIN.ELF` and `PING.ELF`, types
`fb`, `wm on`, `wm de`, `proc spawn WIN.ELF`, and drives derived
pixels:

* close colour at the derived close probe; after click, desktop there
  and `PROC KILL`; a body click does neither
* min hides the fill; the slot restores it
* start + PING row prints `DE CHROME PING`; the panel lists two
  surfaces, then zero after close

`d8-chrome`, `d8-title`, `d7-click`, `d9-focus`, and `osxui1-pop` stay
on their pictures because they never type `wm de`.
