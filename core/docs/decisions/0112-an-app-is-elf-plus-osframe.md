# ADR-0112 — An app is an ELF plus osframe

**Status:** accepted, implemented, verified (`tests/conformance/de-apps/run.sh`)
**Date:** 2026-08-30
**Milestone:** closed application-system contract (`docs/design/app-system.md`)
**Files:** `core/user/frame/tap.c` (`TAP.ELF`), `core/user/frame/osframe.h`,
`core/tests/conformance/de-apps/`
**Depends on** ADR-0051 (surfaces), ADR-0052 (damage), ADR-0053
(residency), ADR-0054 / ADR-0055 (queues), ADR-0078 (spawn 26),
ADR-0099 (hidden `go NAME`).
**Does not allocate a syscall.** 11 stays `fdwait` and is not built.
**Number:** 0112 — 0109 is shmMax four slots. Do not reuse 0109.

---

## 1. The question

FILES, Settings, FRAME2, and OSXUI2 already attach, paint, and read
events against `osframe.h`. A second author still needed a written
contract that those four steps *are* an app, that chrome is not a
second toolkit, and that launch is the door that already exists.

## 2. The decision

1. **An app is an ELF + `osframe.h`.** Freestanding C (or `@bare`
   DCDart with the sibling literals). Optional `oslibc.h`. Never Flutter.
   The program `#include`s the header and does not paste `SYS_*`.
2. **Chrome is wm.** Title bars, start, focus, popovers stay
   compositor policy. A FRAME client does not grow a widget kit.
3. **Paint is osgfx** (Skia when that agent lands). Today the client
   writes `0x00RRGGBB` into the region `wmsurface` told it. That is
   the same ABI; osgfx is the engine, not a second syscall.
4. **The four steps are the contract.** `shmcreate` → `wmsurface`
   attach → paint → `wmsurface` commit; then `kbdevent` (24) and/or
   `wmevent` (25) in a yield loop. Launch is `go NAME` / spawn 26
   from the FAT 8.3 root, or `proc spawn` / `run`.
5. **No help line, no kernel `.bss`, no new number.** `TAP.ELF` is a
   kept client, not a kernel name.

## 3. What this is not

It is not a second toolkit. It is not a hosted libc. It is not a
web view. It is not APP5 (argv and heap on one door). It is not
argv-from-spawn. It is not persist. It is not guest Skia in this
file.

## 4. Binary

`de-apps/run.sh` plants `TAP.ELF` on FAT16, types `fb` / `wm on` /
hidden `go tap.elf`, and requires `GO`, `PROC SPAWN`, `TAP READY`,
attach, and commit. A left press inside the control flips a derived
pixel and prints `TAP HIT`. A press on the surface but outside the
control prints `TAP MISS` and leaves the control. Negative: `go
ghost.elf` prints `GO` and `no such name in the root directory` and
never `TAP READY`.

Anti-vacuity: control area is not the whole surface; off ≠ on ≠ fill
≠ desktop. `tap.c` has no private `SYS_*`.
