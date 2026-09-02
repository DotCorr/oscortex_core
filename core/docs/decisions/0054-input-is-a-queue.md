# ADR-0054 — Input is a queue: IRQ1 produces, the shell and ring 3 consume

**Status:** accepted, implemented (`core/kernel/kbdq.dart`, `core/kernel/keyboard.dart`,
`core/kernel/shell.dart`, `core/boot/isr.S`, `core/tests/conformance/d2-input`).
**Depends on ADR-0006** (the shell is a task-context consumer) **and ADR-0053**
(`shellMain` must not inline a walk).
**Closes** GAP-0055 item 4 (type-ahead while a command runs was zero bytes).
**Does not close** GAP-0308's configure/enter/leave remainder. Keyboard
focus is ADR-0062 (D9): this queue is still the transport; the compositor
now names who may pop it.

---

## 1. The question

`kbdHandle` used to translate a scancode and call `shellKey` inside the IRQ.
While a command ran, `shellState() > 0` dropped every keystroke. There was no
ring, no overflow counter, and no way for ring 3 to see a key. A surface that
wants a key identity and an edge cannot be built on that.

`display-protocol.md` §4.2 is the specification this ADR implements.

---

## 2. The decision

1. **A ring in `@bss`.** `kbdqStore` is 288 bytes: four header words (head, tail,
   dropped, count) and 32 event slots. It is the last block in `kmain.o`'s
   `.bss`, so every earlier harness subtracts it first and D4's 320 still means
   what it meant.
2. **IRQ1 only enqueues.** The packed word is make-scancode in bits 0–7, break
   in bit 8, `0xE0`-extended in bit 9. The `0xE0` prefix itself is not stored.
   Translation, the break skip, and the "command is running" guard all moved
   to the consumer.
3. **Overflow drops the newest event and counts it.** A queue that drops the
   oldest silently turns a missed key into a mystery. The counter is readable
   through syscall 24 `op = 1` and is reset in `shellRecover`.
4. **`shellRecover` and `shellInit` reset the ring.** A queue that survives a
   fault with stale contents types a ghost command after the prompt comes back.
5. **The shell is a consumer.** `shellMain` calls `kbd_drain_gate` under `cli`.
   That trampoline exists for ADR-0053's reason: an inlined walk next to the
   prompt printer `#UD`s. The drain translates make codes, skips breaks and
   extended keys, and stops on Enter.
6. **Syscall 24 `kbdevent`.** `rdi = 0` pops, `1` reads dropped, `2` reads
   count. No `oslibc.h` name. No process slot required — same reason as
   `mouse`. While a program runs (`shellState == 2`) the drain does not
   consume, so the events belong to whoever reads the syscall.

---

## 3. What this is not

It is not input focus, not mouse events, not serial type-ahead, and not a
click reaching a client. Serial still drops when a command is running
(GAP-0309): a COM1 byte is not a scancode. The mouse is still syscall 20's
level poll (GAP-0252). Routing is D7.

---

## 4. Binary

`d2-input/run.sh`: with a ring-3 program on the CPU, inject N keys at 50 ms;
the program reads exactly the derived make+break sequence. Then inject
`depth + 3` press-only events faster than they are drained; the program
reads `depth` events and a dropped count of exactly 3. Negative control: a
host model with depth 1 fails the first assertion.
