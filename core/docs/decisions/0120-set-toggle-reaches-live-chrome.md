# ADR-0120 — Settings toggle reaches live compositor chrome

**Status:** accepted, implemented, verified (`tests/conformance/de-set2/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE Settings leftover after ADR-0105
**Files:** `core/user/frame/set.c` (`SET.ELF`), `core/kernel/wmde.dart`
(pref bit on the existing chrome word), `core/tests/conformance/de-set2/`
**Depends on** ADR-0105 (derived facts + local toggle), ADR-0106 (`wm de`
already walks the FAT root), ADR-0056 / ADR-0075 (chrome word).
**Does not allocate a syscall.** 11 stays `fdwait`.
**Does not edit** title-drag (`wmTitleHit` / `wmGrab`), osgfx, or Skia.
**Number:** 0120 — 0114 is osgpu. Do not reuse 0105.

---

## 1. The question

ADR-0105's toggle flipped a client swatch and printed `SET TOGGLE ON`.
That is a local picture. A person sitting at the machine who hits
Settings expects the *compositor* to change: a taskbar pixel, or a
`WM DE` / `wm chrome` line. A new syscall would be a registry row
this leftover does not need.

---

## 2. The decision

1. **The toggle writes a file the compositor already knows how to
   walk.** `SET.ELF` `open`s `CHROME.DAT` (`O_WRITE`) and `fdwrite`s
   one byte, then commits. Those are syscalls 5 and 9. No private
   `SYS_*`. `de-set` still photographs the local swatch; it does not
   type `wm de`.
2. **`wm de` notices the file on the existing commit path.** Start
   already walks the FAT root. `wmComposeCommit` (one line) calls the
   same walk for the 8.3 pref name. On the first hit it sets spare bit
   4 of the existing chrome word (`wmDePrefMask`), prints
   `WM DE SET ON`, and paints the notify strip `wmDeSetColor`. Damage
   does not otherwise visit the strip. Title-drag does not read the
   bit. Gated on `wm de` so a `wm on` boot (de-set's 130 path) stays
   a local swatch. `wm chrome` alone (level 1) does not walk the file.
3. **A miss writes nothing.** No file, no bit, no line, notify stays
   `wmNoteColor`. Hit and miss use separate volume copies so a written
   pref cannot leak.
4. **No help line, no new number, no SET name in the kernel.** The
   kernel names `CHROME.DAT` bytes, not `SET.ELF`. `de-set`'s 130
   path stays the local-swatch harness.

### 2.1 What this is not

It is not persist across `unlink` / `rename` (still missing). It is
not `wm chrome` from ring 3. It is not a title-drag change.

---

## 3. Binary

`de-set2/run.sh`:

* `fb` / `wm on` / `wm de` / `proc spawn SET.ELF`. After an in-control
  click, serial carries `WM DE SET ON` and the notify pixel is
  `wmDeSetColor`. The volume holds a non-empty `CHROME.DAT`.
* A press on the surface but outside the control prints `SET MISS`,
  does not print `WM DE SET ON`, leaves the notify at `wmNoteColor`,
  and writes no `CHROME.DAT`.
* `de-set/run.sh` still pins `ASSERTIONS_REQUIRED=130`.

Negative: the miss click. Anti-vacuity: idle notify is not already
the pref colour; two volume copies; two distinct note colours.
