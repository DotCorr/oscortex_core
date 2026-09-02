# ADR-0053 — The shell is the idle context: a process outlives `proc spawn`

**Status:** accepted, implemented (`core/kernel/proc.dart`, `core/kernel/shell.dart`,
`core/boot/isr.S`, `core/tests/conformance/d3-resident`).
**Depends on ADR-0022** (preemption already saves a 22-word frame).
**Closes** the structural half of GAP-0085 (a process that never exits no longer
owns the machine) **and** `display-protocol.md` §6 D3.
**Does not close** B1's blocked state or D2's input queue.

---

## 1. The question

`proc run` calls `enter_user` and does not return until every process has
exited. That is a session, not a desktop. A compositor, a network stack, a
shell that can type `ticks` while a window is live — all of them need a
process that stays READY while the kernel is back at the prompt.

`blocking-and-threads.md` §1.8 Option D is the same missing piece seen from
the other end: the sound way to leave a process and come back is the door
`user_return` already is. Build it once.

---

## 2. The decision

1. **`proc spawn <lba>`** creates one process via `procCreate` and returns.
   The first spawn of a session resets the table, sets `procHeadResident`
   (header word 14), and unmasks IRQ0. Later spawns add a slot.
2. **`shellMain`'s idle branch** is the idle context. If a resident READY
   process exists, it calls `procResume`; otherwise `idle_once`.
3. **`resume_user`** in `isr.S` records the caller's RSP (so `user_return`
   lands in that idle branch) and `iretq`s from the slot's saved 22-word
   frame. It does not scrub registers and does not restart at the entry
   point — that is why it is not `enter_user`. First entry of a spawned
   slot still goes through `enter_user`.
3b. **`proc_idle_gate`** is an `@extern` trampoline. `shellMain` must not
   inline the slot walk: DCDart's overflow checks live in callee-saved
   registers, and an inlined walk next to the prompt printer `#UD`s
   (vector 6, opcode `0F0B`).
4. **A lone resident quantum** saves the process, marks it READY, bumps its
   preempt counter, and `user_return`s. A classic `proc run` session still
   keeps a lone process on the CPU (`m18-preempt` is that session).
5. **IRQ0 stays unmasked only while resident processes exist.** `ticks` at a
   bare prompt still remasks, so `m3-shell`'s golden does not move
   (GAP-0058). `ticks` during a spawn session leaves the timer on, because
   remasking would park the resident process forever.

---

## 3. What this is not

It is not a blocked state, not `fdwait`, not an input queue, and not a
compositor in ring 3. Those are B1, D2, and the move GAP-0300 still names.
This ADR only makes "a process is live and the shell has the CPU" expressible.

---

## 4. Binary

`d3-resident/run.sh`: spawn a program that never exits; type `ticks`; the
slot's preempt counter printed by `proc sched` is strictly greater after
than before. Negative control: a program that exits immediately; `ticks`
still works; the counter does not advance.
