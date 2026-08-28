# ADR-0050 — The compositor owns the framebuffer, and it lives in the kernel

**Status:** accepted, implemented (`core/kernel/wm.dart`, `core/tests/conformance/d2-compositor`).
**Supersedes nothing. Departs from `docs/design/display-protocol.md` §0.1 in one place, deliberately,
and §6 predicted the departure would have to happen.**

---

## 1. The question

`fb.dart` gives this kernel a text console that blits 8×16 glyphs into a linear framebuffer at a
cursor it advances itself. A compositor puts windows in the same pixels. **They cannot both have it.**
Three answers were on the table:

| | answer | what it costs |
|---|---|---|
| a | the compositor takes the framebuffer permanently | the console is gone the moment a compositor exists, including for diagnostics |
| b | the console keeps a region of the screen | every window is clipped against a console rectangle forever, and the clip is in the compositor's inner loop |
| c | **they alternate by mode** | one branch per printed character, and a mode somebody has to be in |

**(c), and the mode is one word of `.bss`.** `wmActive()` is 1 between `wm on` and `wm off`, and
[fbPutc] returns early while it is set — **one branch, in one function, and `d2-compositor/run.sh`
asserts there is exactly one.**

### 1.1 What does NOT change, and it is the reason (c) is cheap

`conPutc` writes COM1 **first and unconditionally** and only then picks a screen (`vga.dart`). The
gate is below that, inside `fbPutc`. So **not one byte of serial output moves**, and the twenty-odd
byte-exact goldens from M1 onwards are produced by the same code in the same order they always were.
What stops is *glyphs being blitted over composed windows*, which is the actual conflict; what does
not stop is *output*. `d2-compositor/run.sh` asserts that `vga.dart` does not mention `wmActive` at
all, so a future edit cannot quietly move the gate up a layer and take the goldens with it.

---

## 2. The decision that is really being made: the compositor is in the KERNEL

`display-protocol.md` §0.1 defines a compositor as *"the one **process** allowed to touch the
framebuffer"*, and §6 then says, in as many words, that until **D3** lands — a process that outlives
the shell command that started it — *"there is nowhere for a compositor to live."* **D3 is not
built.** So the choice was never between a kernel compositor and a userland one. It was between a
kernel compositor and no pixels.

Three further facts make the kernel the *right* answer and not merely the available one, and none of
them is about D3:

1. **Presentation is already a kernel operation and always will be.** The mode and the scanout origin
   are programmed through I/O ports `0x1CE`/`0x1CF`; ring 3 cannot execute `out`; `m9-ring3` asserts
   the TSS carries no I/O permission bitmap. `display-protocol.md` §3.1 established this before any of
   this existed and called it *"a property of the hardware rather than a policy anyone chose."*
2. **The framebuffer is not shareable memory.** It is a 16 MiB PCI aperture at an address discovered
   from BAR0, mapped supervisor and NX by `vmBuild`. `shm.dart` shares *frame-allocator* pages. There
   is no mechanism in this kernel for handing a PCI aperture to ring 3, and inventing one is a
   hard-to-reverse memory-layout decision that `CLAUDE.md`'s escalation rule reserves for a human.
3. **The ring-3 window is 2 MiB and a frame is 1.92 MB.** `display-protocol.md` §1.2 calls this the
   binding constraint on the whole design, and §3.4 records that the author's *first* proposal — map
   VRAM into the compositor — cannot work, because two frames of VRAM are 3.84 MB. **A compositor
   that cannot hold a frame has to be given one by the kernel anyway.**

### 2.1 What this forecloses, stated plainly

It forecloses nothing, and that is the point of writing the protocol the way ADR-0051 writes it. The
descriptor is a legal channel message and carries no address; when D3 lands, the same eight words go
through `chansend` to a ring-3 compositor and the *only* thing that has to move is who reads them.
**The thing a kernel compositor makes permanent is the final blit, and that was already permanent
for a reason nobody chose (point 1).**

### 2.2 What it costs today

* **A client pays for its own composite**, inside its own syscall, with interrupts on but the
  scheduler not consulted. GAP-0303.
* **Compositor policy is kernel code.** Stacking order is "the newest surface is on top", it is one
  line, and it is not something ring 3 can change. `display-protocol.md` §0.1 is explicit that window
  management is compositor policy rather than protocol, so this is policy in the wrong *place* rather
  than policy in the protocol. GAP-0302.
* **There is no way to turn a compositor off from inside itself.** `wm off` is a shell command.

---

## 2.3 D5b — the pointer, and the one place a drag can be noticed

`wmPointerTick` is called from `mouseComplete`, on the IRQ12 path. **That is not where anybody would
put a compositor by choice; it is the only place a drag can happen on this machine.**

`shellProcRun` calls `procStart` and does not return until every process it launched has exited. So
between *"two surfaces are on the screen"* and *"the clients are gone"* there is no command loop to
poll a pointer from — timer and pointer interrupts are the only code that runs in that window. **A
compositor that could only act from a shell command could only move a window when there was nothing
on the screen to move.**

Three things follow, and each is a decision rather than a consequence:

1. **The repaint had to become partial.** A full frame is 480,000 pixel stores plus the windows, and
   a pointer emits packets at roughly 100 Hz. `wmRepaintRect` resolves the picture **one pixel at a
   time** through `wmPixelAt` instead of one window at a time through `wmDrawWindow`, and the two
   must agree or a partial repaint leaves a seam. They agree by construction: both read the border
   colour from `wmBorderColor` and the content through `wmRegionPixel`, and `d2-compositor` probes
   pixels inside a repainted rectangle against the same host model it probes a composed frame with.
   The harness also asserts that a drag step painted **fewer pixels than a bare desktop fill**, so a
   fall back to full frames would look right and still fail.
2. **A re-entrancy guard was needed, and one word is enough here.** IRQ12 can fire while `wmCompose`
   is halfway through a frame, because a commit composes inside a syscall with interrupts on. Two
   painters in one framebuffer is a torn frame drawn against two different stacking orders.
   `wmMetaBusy` is set by every painter and checked by the tick. On this single-core kernel that is a
   real mutual exclusion — the interrupt gate clears IF, so the tick's test-and-return cannot itself
   be interrupted. GAP-0307 records what it becomes on two cores. **A dropped tick is a dropped
   FRAME, not a lost event**: `mouseApplyX/Y` have already moved the pointer, so the next tick sees
   the accumulated position and the window catches up.
3. **A lifetime check was needed, and it found a real fault.** A region dies with its last
   capability, and this compositor holds none. Without `wmWindowUsable`/`wmReap` the first pointer
   packet after `PROC END` read a freed page as a frame vector and the machine took a `FAULT 0D` at
   the shell prompt. The check is at the top of every painter rather than on a teardown path, because
   the property wanted is not *"the window is closed promptly"* but *"nothing ever paints from a dead
   region"* — and a check in the painters cannot be bypassed by a teardown path nobody hooked.
   GAP-0306.

**Input policy is one sentence: the topmost window under the cursor.** No click-to-focus versus
focus-follows-mouse, no focus that survives the pointer leaving, no keyboard focus at all. The brief
for this work said not to build input focus policy beyond that, and `display-protocol.md` §0.1 says
window management is compositor policy rather than protocol, so it is one function (`wmHit`) and it
is replaceable.

---

## 3. Storage

`wmStore` is **320 bytes**: nineteen state words in a 24-word block -- counters, the drag and its
grab offset, the pointer position this compositor last painted, and the re-entrancy guard D5b needs --
then two 64-byte window records. Two, because a
window's pixels live in a shared region and `shmMax` is 2 — **the number is derived, not picked**, the
way `chanPorts` is derived from `procMax`.

It is **LAST** in `kmain.o`'s `.bss`, which is ADR-0031 §4.3 rule 5 as ADR-0033 §6.3(a) corrected it
(*"last is necessary but not sufficient"*). This is the fourth block to arrive under that rule, and it
moved the previously-last block's own to-the-end measurement exactly as ADR-0033 §6.4 predicts:
sixteen harnesses that subtracted `shmStore` first now subtract `wmStore` first and measure `shmStore`
to `wmStore`'s start. The kernel's mutable static total goes **22016 → 22336**. GAP-0053.

---

## 4. What was rejected

* **A compositor process with a channel endpoint owned by the kernel.** `chanopen` assigns a *process
  id* to a port owner word and `shmgrant` installs a capability into a *process slot*; a kernel
  endpoint would need a fake process id and a capability table for it. That is a change to `chan.dart`
  and `shm.dart`, both of which are being modified on other lines right now, to buy something D3 will
  make unnecessary.
* **Reading client regions without any authority at all.** The compositor is in the kernel and could
  simply walk `shmRegVec` for every live region. It does not: ADR-0051's descriptor names a capability
  handle and the handle is validated against *the caller's own* table. The capability model is worth
  more than the two dozen lines it saves.
* **A `wm` line in `help`.** `shellStrHelp` is 2511 bytes and sits verbatim inside five byte-exact
  serial goldens plus `m3-shell`'s screen golden. One line moves six goldens by substitution. M18
  added three commands with no help line, M20 added none and D1 did the same. GAP-0304.
