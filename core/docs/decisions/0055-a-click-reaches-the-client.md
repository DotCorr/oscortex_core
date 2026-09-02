# ADR-0055 — A click reaches the client under the pointer

**Status:** accepted, implemented (`core/kernel/wmevent.dart`, `core/kernel/wm.dart`,
`core/tests/conformance/d7-click`).
**Depends on ADR-0050** (the compositor hit-tests), **ADR-0051** (a process owns a
surface), **and ADR-0054** (the queue shape).
**Narrows** GAP-0308 (a left press now reaches the owning client). It does **not**
close configure or enter/leave. Keyboard-focus is ADR-0062.

---

## 1. The question

`wmGrab` already hit-tests a left press and raises/drags. Nothing told the
client. `display-protocol.md` §6 D7 is the exit criterion: a click in the
overlap is reported by the owner of the top surface, with surface-relative
coordinates, and by no other; a click on the desktop is reported by neither.

ADR-0051 is still one-way for everything except this press. The compositor
stays in the kernel. A new syscall is the available transport; waiting for
a ring-3 compositor is not.

---

## 2. The decision

1. **The same shape as D2's keyboard queue.** `wmeventStore` is 192 bytes: two
   per-window rings (head, tail, dropped, count, 8 event slots). Overflow
   drops the newest event and counts it. The newest `@bss` block is last, so
   every earlier harness subtracts it first and D2's 288 still means what it
   meant.
2. **IRQ12 only enqueues on the down edge.** `wmPointerTick` already
   distinguishes press from hold from release. `wmGrab` calls `wmeventEnqueue`
   after `wmHit` finds a window. A desktop click (no hit) enqueues nothing.
   Chrome is a different hit and returns before this call.
3. **Coordinates are surface-relative.** The packed word is type in bits 0–7
   (1 = press), window slot in 8–15, `x - origin` in 16–31, `y - origin` in
   32–47. A client that has to know its screen position to interpret a click
   is a client that breaks when the compositor moves it.
4. **Syscall 25 `wmevent`.** `rdi = 0` pops the calling process's window, `1`
   reads dropped, `2` reads count. No `oslibc.h` name. Empty pop is 0. A
   caller that is not a process, or that holds no window, pops 0. Only the
   owning slot sees its events.
5. **25 and not 21.** 20 is `mouse`, 23 is `wmsurface`, 24 is `kbdevent`,
   21/22 are taken on other lines, 11 stays reserved for `fdwait`.

---

## 3. What this is not

It is not a configure event, not enter/leave, not keyboard focus, and not
the compositor moving to ring 3. The protocol is still one-way for
everything except a left press. GAP-0308 records the rest.

---

## 4. Binary

`d7-click/run.sh`: two overlapping surfaces, red behind, blue on top. A click
injected in the overlap is printed by the top client with the host-derived
surface-relative coordinates, and the bottom client prints NONE for that
click. A click outside both surfaces is printed by neither.
