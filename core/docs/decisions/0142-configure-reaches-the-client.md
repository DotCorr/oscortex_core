# ADR-0142 — Configure and enter/leave reach the client

**Status:** accepted, implemented (`wmeventEnqueueConfigure` /
`wmeventEnqueueEnter` / `wmeventEnqueueLeave` in `wmevent.dart`,
`wmFocusTo` in `wm.dart`, harness `core/tests/conformance/de-cfg`)
**Date:** 2026-08-30
**Milestone:** GAP-0308 leftover after ADR-0136
**Depends on** ADR-0055 (`wmevent` press queue), ADR-0062 (focus
word), ADR-0106 (`wm de`), ADR-0121 (resize clip).
**Closes** configure and enter/leave on the press queue (GAP-0308).
Growing the shm past the attach region is ADR-0150
(`shm-grow/`). `unlink` / `rename` (APP4) closed at ADR-0147;
FILES move consumes rename at ADR-0149.
**Number:** 0142 — 0136 is panel hex. 0137–0141 are unused. Do not
reuse 0055. No new syscall. 11 stays `fdwait`.

---

## 1. The question

A left press already reaches the owning client (ADR-0055). Keyboard
focus already names a window (ADR-0062). Title-drag and SE resize
already change geom under `wm de` (ADR-0111, ADR-0121). The client
was still not told. `display-protocol.md` §1.1 says position is
compositor policy; a compositor that can override a requested
position must be able to say so. A client cannot stop drawing a
hover it can no longer see.

The press queue is the available transport. A new syscall is not.
`fdwait` keeps 11.

---

## 2. The decision

1. **Same ring, new types.** Type 1 stays press. Type 2 is
   configure: window in 8–15, 12-bit x/y/w/h in the rest. Type 3
   is enter, type 4 is leave (same x/y layout as press). Empty pop
   is still 0. Syscall 25 is still `wmevent`. No `oslibc.h` name.
2. **Gated on `wm de`.** Attach, move, and resize enqueue
   configure. A focus change enqueues leave on the old window and
   enter on the new. Without `wm de` the ring is still press-only,
   so `d7-click` still pops a press first.
3. **Coalesce consecutive configures.** Overflow drops the newest
   event. A resize drag would otherwise fill eight slots and lose
   the last size. The newest configure is overwritten in place.
4. **Anti-vacuity.** Without `wm de` the compositor still attaches
   and the client pops NONE. A wrong host geom does not match the
   line the client prints. No send is not compositor-only.
5. **No new syscall. No help line. 11 is still `fdwait`.**
   `wmeventStore` stays last `.bss`. `osframe.h` is not edited
   (FRAME.H checksum). Existing FRAME clients already ignore
   `type != press`.

### 2.1 What this is not

It is not a new region. Growing past the attach shm is ADR-0150.
It is not `fdwait`. It is not Flutter. It is not a help line.

---

## 3. The harness

`de-cfg/` builds a FAT volume with `WIN.ELF`, types `fb`, `wm on`,
`wm de`, `proc spawn WIN.ELF`, and asserts:

* the client prints the host-derived attach configure
* an SE shrink prints the host-derived resize configure
* focus prints ENTER; a desktop click prints LEAVE
* a wrong geom line does not appear

A second boot types `wm on` only. The compositor still prints
`WM ATTACH`; the client prints `DE CFG NONE`.
