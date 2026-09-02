# ADR-0062 — Keyboard focus is a compositor slot: keys reach the focused surface

**Status:** accepted, implemented (`core/kernel/wm.dart`, `core/kernel/kbdq.dart`,
`core/tests/conformance/d9-focus`).
**Depends on ADR-0050** (the compositor hit-tests), **ADR-0051** (a process owns a
surface), **ADR-0054** (the queue and syscall 24), **and ADR-0055** (a click
already names the window under the pointer).
**Closes** the keyboard-focus half of GAP-0308 and narrows GAP-0253. It does
**not** close configure or enter/leave.

---

## 1. The question

IRQ1 enqueues; the shell drains when idle; syscall 24 `kbdevent` pops. A
surface that wants a key still shared that queue with every other reader
and with the prompt. `display-protocol.md` §4.3 said the compositor owns
focus. D7 delivered a click. This is the next display rung: a keystroke
reaches the focused surface and nobody else.

---

## 2. The decision

1. **A spare word, not a new block.** `wmMetaFocus` is index 20 of the
   existing 24-word `wmStore` meta block. Chrome used 19. Words 21–23
   remain free. PLUS ONE, the same idiom as `wmMetaDrag`: 0 means the
   shell (and any ring-3 reader) may drain syscall 24; window 0 is
   expressible as 1. `wmInit` already zeroes the block. No `@bss`, so
   `wmeventStore` stays last and every harness that measures `wmStore`
   at 320 is unmoved.
2. **Focus is the last `wmHit` window until it dies.** `wmGrab` writes
   `hit + 1` on a window press and writes 0 on a desktop press. A reap
   or `wm off` clears the same word. Escape is not special. Chrome is
   a different hit and leaves the slot alone.
3. **`kbdqDrainToShell` skips when `wmFocusLive() != 0`.** The shell
   does not consume while a surface is focused. A dead window is
   cleared inside `wmFocusLive` so a stale slot cannot keep the prompt
   from the keys.
4. **Syscall 24 is enough.** When focus is live, `kbdqSys` pops only
   for the process that owns that window. Everyone else pops 0 — the
   same answer as an empty ring. When focus is 0 the queue is still
   global, which is why `d2-input` did not move. No new syscall. 11,
   21 and 22 stay reserved.

### 2.1 What this is not

It is not a configure event, not enter/leave, not a focus-follows-mouse
policy, and not a compositor in ring 3. The protocol is still one-way
for everything except a left press and, now, the keyboard queue's
reader. GAP-0308 keeps configure and enter/leave. GAP-0253 keeps the
mouse as a global poll.

---

## 3. Why not a new syscall, and why not `wmevent`

A key is already a packed scancode+edge on `kbdqStore`. Putting the
same word on a per-window ring would duplicate the queue D2 built and
would force every client that already reads 24 to grow a second path.
Gating the existing pop is the cheaper move, and the number is not the
interface.

`wmevent` stays last in `.bss` and stays a click queue.

---

## 4. Binary

`d9-focus/run.sh`: two surfaces, red and blue. A click injected at a
host-derived point that is only inside the blue window; then `xyz`
via QMP `send-key`. The blue client prints the derived make+break
sequence on syscall 24; the red client prints NONE; the shell does
not consume those keys. Negative control: a host model that delivered
the sequence to the red client produces a different line.
