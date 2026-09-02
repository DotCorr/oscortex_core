# ADR-0105 — Settings reads derived facts and toggles a local setting

**Status:** accepted, implemented, verified (`tests/conformance/de-set/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE Settings (`docs/design/osx-ui.md` client kit)
**Files:** `core/user/frame/set.c` (`SET.ELF`), planted `FACTS.DAT`,
`core/tests/conformance/de-set/`
**Depends on** ADR-0051 (surfaces), ADR-0052 (damage), ADR-0053
(`proc spawn`), ADR-0054 / ADR-0055 (queues), ADR-0056 / ADR-0075
(chrome and title colours as compositor policy).
**Does not allocate a syscall.** 11 stays `fdwait` and is not built.
**Number:** 0105 — 0099 is hidden `go NAME`. 0103 is FFmpeg. 0104 is
the OS calling osgfx. Do not reuse 0099.

---

## 1. The question

A desktop needs a Settings surface that shows *this machine's* facts,
not a second copy of `fbWidth = 800` baked into the client. Chrome
on/off is compositor policy (ADR-0056) and is not a ring-3 register.
A new "get geometry" syscall would be a registry row this rung does
not need.

## 2. The decision

1. **`SET.ELF` is a kept FRAME client** against `osframe.h`. `proc spawn`
   starts it so the prompt returns (ADR-0053). No private `SYS_*`.
   Syscall 11 is not named.
2. **Facts are a planted 8.3 record.** Host `derive.py` reads `fbWidth` /
   `fbHeight` from `fb.dart`, `wmChromeColor` / `wmTitleColor` /
   `wmChromeH` from `wmchrome.dart`, and `wmColorDesktop` from `wm.dart`,
   and plants `FACTS.DAT` (magic `SET1`, little-endian fields, a xor
   checksum, padding past 26 bytes). The client `open`s / `read`s that
   file. A one-field truncate is `SET BAD` and attaches nothing.
3. **Display is serial plus swatches.** `SET FB 0320x0258` must match
   the kernel's existing `fb` probe `MODE` line. `SET CHROME OFF` is
   the planted default (chrome is off unless `wm chrome`). Desk / bar /
   title colours are painted as 40×24 swatches, not `#define`d in
   `set.c`.
4. **The control is a local setting.** A hit rectangle (or the derived
   make-scancode) flips a preview: the chrome swatch becomes the title
   colour and the control flips. That is a derived pixel and a
   `SET TOGGLE ON` line. It does not call `wm chrome` and does not
   edit `wm*.dart`.
5. **No help line, no kernel `.bss`, no new number.**

## 3. What this is not

It is not a live read of `wmMetaChrome`. It is not compositor chrome
on. It is not persist of the toggle (`unlink` / `rename` still missing).
It is not glyph labels. It is not a hosted control panel.

## 4. Binary

`de-set/run.sh`:

* `proc spawn SET.ELF` after `fb` / `wm on`. Serial carries the host-
  derived `SET FB` / `SET CHROME OFF` / colour lines. The framebuffer
  holds the three swatches and the idle control.
* A left press inside the control, or the derived key after a focusing
  miss, flips the chrome swatch and the control. A press on the surface
  but outside the control prints `SET MISS` and leaves the swatch.
* A volume whose `FACTS.DAT` was truncated before the chrome field
  prints `SET BAD` and never `SET FB` / `SET TOGGLE`.

Anti-vacuity: planted file longer than 26 bytes; two distinct policy
colours; control area is not the whole surface; `set.c` does not contain
`800`, `600`, or the chrome colour literals.
Negative: truncate, and the outside click.
