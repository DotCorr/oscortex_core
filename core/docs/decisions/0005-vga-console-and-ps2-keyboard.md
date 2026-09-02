# ADR-0005: A VGA text console and a PS/2 keyboard — making the kernel visible and interactive

**Status:** decided — implemented and verified (`tests/conformance/m2-console/run.sh`)
**Date:** 2026-08-21
**Milestone:** M2 (`ROADMAP.md`)

## Context

Everything this kernel had done through M1 was invisible unless you read a serial capture. The
project owner's stated want is to *see* the OS running. That is not a cosmetic request: a kernel with
no screen and no input is a program that prints a report and stops, and every milestone after this one
(a shell, a scheduler, anything a user drives) needs an input device and a place to draw.

Two capabilities, in order: a VGA text console at `0xB8000`, and a PS/2 keyboard on IRQ1.

## 1. This does NOT overturn `OSCORTEX_SPEC.md` §3

§3 chose COM1 serial *over* VGA, with a real justification: VGA text mode does not exist on most
modern machines' primary boot path, while a serial or debug UART does.

**That reasoning still stands and is not weakened here.** Serial remains the PRIMARY output. All three
pre-existing conformance harnesses assert serial bytes and nothing else, and this change moved none of
them. What is added is a SECOND, development-time output path that exists because under QEMU the text
buffer at `0xB8000` is the shortest path from "the kernel is alive" to "here is a picture of it."

**What real hardware would actually need, stated plainly:** a framebuffer console. A modern machine
boots UEFI, has no VGA text mode, and gives the loader a linear RGB framebuffer. The honest port is to
request the Multiboot framebuffer tag (which needs Multiboot**2** — this kernel is Multiboot1 today),
take the address/pitch/bpp the loader reports, and render glyphs from a font in `.rodata`. Recorded as
`docs/known-gaps.md` GAP-0054, not implied to be nearly-done.

§3 has been amended in place with a pointer here, rather than left to read as though VGA were still
rejected outright.

## 2. Serial output could not change by one byte, and that shaped the design

`tests/conformance/m1-interrupts/run.sh` asserts the ENTIRE 544-byte serial capture, ending with the
newline after `M1 END`. Any M2 byte on COM1 before a key is pressed breaks a green milestone.

Three consequences, all of them forced rather than chosen:

1. **The mirror is a layer above the UART driver, not a change inside it.** `conPutc(u8)` writes COM1
   first and unconditionally, then the screen. `uartPutc` stays a pure 16550 driver that knows nothing
   about a screen. Every fixed-message and hex-digit emitter in `uart.dart`, `multiboot.dart` and
   `interrupts.dart` was repointed from `uartPutc` to `conPutc`; the byte stream is produced by the
   same code in the same order it always was.

2. **M2's own banner goes to the screen only** (`vgaWrite`, never `conPutc`). It is the only text in
   the kernel that is deliberately not mirrored, and the reason is in its doc comment.

3. **The keyboard echo is the first M2 byte COM1 ever sees.** That is what makes the milestone
   testable: a screenshot needs a human, a byte-exact serial capture does not.

## 3. M2 is entered from a fault handler, and that is not a hack

M1's last act is a deliberate `u64` overflow, which DCDart's overflow-trap codegen turns into a `ud2`
(#UD, vector 6). #UD is a **fault**: the pushed RIP is the address of the `ud2` itself, so `iretq`
would re-execute it forever. The handler cannot return. Before M2 it called `halt_forever()`.

To keep the kernel alive, the only options were:

| Option | Why not |
|---|---|
| Move M1's deliberate fault to the end of M2 | Reorders M1's serial output. Breaks a green milestone. |
| Return from the handler after fixing up RIP | Needs to write the interrupt frame, which needs the frame layout hard-coded in DCDart. Real work, no test would exercise it, and it would make M1's `M1 FAULT` line stop meaning "this fault was terminal." |
| Continue forward from inside the handler | Chosen. |

So `isrDispatch`'s fault path now ends in `m2Enter()`, which never returns. The kernel runs the console
on the boot stack roughly 200 bytes deeper than `kmain`'s frame (the stack is 16 KiB); keyboard IRQs
nest on top of that and unwind normally.

**The `m2_phase` guard is load-bearing, not bookkeeping.** A *genuine* fault during M2 lands on the
same path. Without the guard it would print its diagnostic and then restart the console over the top
of it. With it, the second arrival halts and the diagnostic survives.

## 4. Mutable state: `core/boot/kdata.S`

DCDart has no mutable static data of **any** kind. `@rodata` (DCDart ADR-0040) gives read-only tables
and nothing else. A console cursor must outlive a call, so it has to be donated by assembly and
reached from DCDart through a `u64` address — the same pattern `isr.S` already uses for the IDT and
the tick counter.

M1 could hide that inside `isr.S`, because the only state it needed *was* interrupt state. A console
cursor is not interrupt state, and putting it there would have quietly turned "the interrupt file"
into "the file where we keep globals." `kdata.S` is named for what it is, and its `.bss` size is
asserted at exactly 16 bytes by the harness — that number is the running measure of how much state
DCDart cannot express, and it should move only deliberately. See `docs/known-gaps.md` GAP-0053.

`.bss` is not zeroed by anything in this kernel. Both words are initialized through their address
before first use (`vgaInit()` for the cursor, `m2Enter()` for the phase word). `vgaInit()` is
therefore the FIRST call in `kmain()` — a garbage cursor would scatter 16-bit stores across memory at
`0xB8000 + 2 * garbage`.

## 5. The MMIO hazard: what changed on the day this was written

This console is a large new consumer of MMIO — roughly 2000 cell stores per clear, 1920 load/store
pairs per scroll, plus four port writes per cursor update. Until 2026-08-21 that was a live hazard:

- DC-IR's `Load`/`Store` carried **no volatile semantics** (DCDart's GAP-0006), so a store to a screen
  cell nobody reads back is textbook dead code, and
- `dcc` passed **no `-O` flag at all**, so everything shipped `-O0` and the hazard never fired.

Both halves changed while this unit was in flight: DCDart **ADR-0041** made every `Pointer<T>.value`
access volatile, and DCDart **ADR-0042** turned on `-O2` by default. So the brief for this work — "note
that VGA will need `@volatile` before `-O` is ever enabled" — was overtaken: VGA is a *current*
consumer of a feature that is one commit old, and `-O2` is on.

**Verified here rather than trusted.** `x86_64-elf-objdump -d --disassemble=vgaClear` on the `-O2`
object shows the loop unrolled 5× with all five `movw $0xf20` stores intact and **no** vector stores —
which is exactly ADR-0041's documented consequence (LLVM may not merge or vectorize volatile
accesses). `vgaScroll` likewise keeps a real `movzwl`/`mov %cx` pair per cell. `tests/conformance/
m2-console/run.sh` asserts both properties structurally, on the ACCESS rather than the value, because
a value check passed throughout the period the bug was live upstream.

**Port I/O is a different code path and is covered differently.** `Port.outb`/`Port.inb` lower to LLVM
`asm sideeffect` inline assembly (DCDart ADR-0029), not to `Load`/`Store`, so ADR-0041 does not apply
to them and does not need to: `sideeffect` asm cannot be deleted and cannot be hoisted out of a loop.
Confirmed in the disassembly of `uartPutc`, whose Line-Status-Register poll keeps its `in (%dx),%al`
**inside** the loop's back edge at `-O2`. That mattered enormously — a hoisted LSR read would have made
the UART spin on a stale value and hang the kernel — and it is why all three older harnesses still
pass. See `docs/known-gaps.md` GAP-0052.

## 6. Keyboard: what was built and what was deliberately not

Built: IRQ1 unmasked on the master PIC (mask `0xFD`), vector `0x21` dispatched in `isrDispatch`,
scancode read from port `0x60`, translated through a **`@rodata final List<u8>`** of exactly 128
entries, echoed through `conPutc` to both outputs, hardware cursor updated.

- **128 entries, not 256.** A make code always has bit 7 clear, and `kbdHandle` rejects everything with
  bit 7 set *before* it indexes. The lookup is in range **by construction** — there is no bounds check
  and none is skipped.
- **`0x00` means "no character"** and is ignored rather than printed. Without that, every shift press
  would put a NUL glyph on the screen.
- **The buffer is drained before IRQ1 is unmasked.** The 8042 will not raise another IRQ1 until its
  one-byte output buffer is read; a key pressed while the kernel was still doing M0/M1 work would
  otherwise leave the keyboard permanently and silently dead. The drain is bounded at 16 iterations,
  because an unbounded poll on stuck hardware would hang before the console ever came up.

Not built, and recorded rather than hidden (`docs/known-gaps.md` GAP-0055): **no shift, caps lock or
control** (output is always the unshifted US-QWERTY character), **no `0xE0` prefix handling** (so an
arrow key types whatever its second byte maps to — a real wrong behaviour, not a no-op), **no
controller programming at all** (no self-test, no set-scancode-set, no LEDs), and **no input buffer** —
a keystroke is echoed and discarded, because there is nothing to hand it to yet.

Every one of those needs mutable state, a command/response handshake with timeouts, or a consumer.
Building them now would be untested code pretending to be a feature.

## 7. Verification: three assertions of three different kinds

`tests/conformance/m2-console/run.sh`. QMP `send-key` drives QEMU's emulated PS/2 controller, which
synthesizes real make and break scancodes into the 8042, which raises a real IRQ1, delivered through
this kernel's own IDT to its own DCDart handler. Nothing on the path is stubbed.

1. **Serial, byte-for-byte, 603 bytes.** Its first 544 bytes are m1-interrupts' golden, and the
   harness checks that relationship *mechanically* (as a prefix compare against M1's own file) rather
   than documenting it — so regenerating M2's golden after a serial change still fails and still names
   M1. Its tail is the echo of 59 injected keystrokes.
2. **The framebuffer, byte-for-byte.** The VGA text buffer is read out of **guest physical memory** via
   the monitor's `xp` command and decoded to 25 lines. This is what the video hardware would display,
   not a re-render of what the kernel meant. It asserts what serial cannot: that backspace **edits the
   screen** (serial sees `ab\bc`, the screen shows `ac`), and that scrolling works — the typed lines
   push the boot banner off the top, so the golden's first line is `MB UPP ...`, not `OSCORTEX M0 OK`.
3. **A PNG at `core/build/screenshot.png`**, from QEMU's own `screendump`. Deliberately **not**
   asserted — a pixel comparison would break on a font or palette change that says nothing about the
   kernel — but its absence is a failure.

QMP keystroke injection proved **reliable**, not marginal: identical captures across repeated runs, so
no fallback to a weaker criterion was needed. Negative control run by hand: booting the same kernel and
injecting a *different* key sequence makes both goldens fail, and the serial divergence starts at byte
545 — exactly one past M1's 544. A check that cannot fail is not a check.

Both PNG and text rendering are produced by `qmp-drive.py`, a real file rather than a bash heredoc:
QMP is line-framed JSON over a socket, and doing that in bash would be more fragile than the thing
being tested. The QMP endpoint is TCP, not a UNIX socket, because macOS caps a socket path at 104
bytes and the default `TMPDIR` there is already most of that.

## Consequences

- The kernel is visible and interactive. The screenshot is a real artefact of a real boot.
- `OSCORTEX_SPEC.md` §3 gains an amendment, not a reversal.
- One more file of donated `.bss` (16 bytes) exists, and its size is now asserted, which turns "DCDart
  has no mutable statics" from folklore into a number that moves only on purpose.
- The kernel no longer halts. It idles with interrupts enabled (`idle_forever`, `sti; hlt; jmp`), which
  is the state every future milestone needs and the exact opposite of `halt_forever`'s semantics — kept
  as two separate routines for that reason.
- `verify-freestanding.sh` passes on `kdata.o` standalone, on `kmain.o` (now 12 declared externs, up
  from 9) and on `kernel.elf`. `boot.o` and `isr.o` still fail in isolation and still legitimately so:
  each references one symbol only the link resolves (`kmain`, `isrDispatch`), they are assembly so
  there is no `dcc` to write them a manifest, and `kernel.elf` covers them.
