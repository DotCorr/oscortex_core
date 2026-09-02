# ADR-0006: A command shell — a line editor, a dispatcher, and a main loop that is not an interrupt handler

**Status:** decided — implemented and verified (`tests/conformance/m3-shell/run.sh`)
**Date:** 2026-08-21
**Milestone:** M3 (`ROADMAP.md`)

## Context

After M2 the kernel could draw on a screen and receive keystrokes, and it did exactly one thing with
them: translate and echo. Nothing survived a keystroke, so nothing could be *submitted*, so there was
nothing to submit to. `docs/known-gaps.md` GAP-0055 item 4 said it plainly — "a keystroke is echoed and
discarded, because there is nothing to hand it to yet."

M3 builds the thing to hand it to. A prompt, a line buffer, backspace that edits a line rather than a
screen, Enter that submits, five commands, and an error for anything else.

## 0. Was a shell the right M3? The alternative, argued rather than skipped

`ROADMAP.md`'s "what comes after M2" note said the physical memory manager is the larger structural
hole, and that M2's choice of visible-progress-over-foundations "should be revisited rather than
repeated." That note is correct and this milestone does not refute it. Two things are true at once:

**Why the shell was still worth doing first.** Everything the kernel could do was reachable only by
recompiling it. A shell is the first thing that makes the kernel *operable* — a way to ask it a
question at runtime and get an answer, which is the prerequisite for debugging every subsystem after
this one, the allocator included. `mem` is the demonstration: the memory map has been read and thrown
away since M0, and now there is a place to stand and ask for it, plus a total nothing has ever
computed. When the allocator exists, `mem` is where it will be inspected from.

**Why it does not close the hole, and made the case for closing it sharper.** This unit paid the tax
the note predicted, and the receipt is a number: donated `.bss` went from 16 bytes to **304**, because
a line editor needs a buffer and DCDart has neither mutable statics nor an array type. Every future
subsystem with state pays that same tax, and `kdata.S` becomes more of a junk drawer with each one.
The memory map is *still* read-and-discarded — `mem` re-walks it from the loader's structure on every
invocation, because there is still nowhere to put a parsed copy.

**Recommendation, recorded here so it is not re-litigated from scratch:** M4 should be the physical
memory manager, and the shell should be what proves it works (`mem` grows a page-allocator view, and
the first allocator bug is diagnosed at a prompt rather than by re-linking a kernel). The shell was
worth one milestone. It is not worth two.

## 1. Commands run in TASK context, not in the interrupt handler

This is the structural decision of the milestone, and it was forced by `ticks` rather than chosen for
elegance.

At M2 the IRQ1 handler *was* the program: `kbdHandle` translated and echoed, and the kernel's steady
state was `idle_forever` (`sti; hlt; jmp`) in assembly. The obvious M3 shape is to keep that and run
the command inside `kbdHandle` when Enter arrives.

**That shape cannot implement `ticks`.** Every IDT gate this kernel installs is an interrupt gate
(`0x8E`, ADR-0002) so IF is clear for the whole handler. A command that waits for the PIT counter to
advance would be waiting for an interrupt that cannot be delivered — a deadlock, and the symptom would
be a wedged kernel rather than an error.

So the split:

| | context | does |
|---|---|---|
| `kbdHandle` | interrupt, IF clear | line EDITING only: append, backspace, set a flag on Enter |
| `shellMain` | task, IF set | waits, then runs the command with nothing in the PIC's in-service register |

`isr.S` gains one routine for it: `idle_once` (`sti; hlt; ret`) — a single wake-up rather than a loop,
so the loop can live in DCDart where the flag test and the sleep are in the same language.
`idle_forever` is kept but no longer called; it is the correct primitive for a kernel with nothing to
dispatch, and deleting it would falsify ADR-0005's record.

Considered and rejected: running commands in the handler and issuing `sti` inside `ticks` only. It
works — an in-service IRQ1 blocks IRQ1 while allowing the higher-priority IRQ0 to nest — but it makes
correctness depend on 8259 priority ordering that nothing tests, on one command, forever. The task
context is also the shape every milestone after this one needs.

## 2. The sleeping race, and why a structural check asserts `sti; hlt` adjacency

The idle path is `cli` → test the state word → `idle_once`. The `cli` is not defensive coding:

- with interrupts already enabled, a keystroke landing between the test and the `hlt` would leave the
  kernel asleep **with a submitted line**, until the next keystroke woke it;
- x86 delivers no interrupt between `sti` and the instruction after it, so `sti; hlt` **adjacent**
  means an interrupt arriving in that window wakes the `hlt` instead of being lost.

Both halves are invisible in a passing boot — the failure is occasional and looks like "it stopped
responding." So `tests/conformance/m3-shell/run.sh` disassembles `idle_once` and asserts it is exactly
`sti`, `hlt`, `ret`, in that order. A check that only fires when someone breaks it is the only kind
that can protect this.

## 3. Three states, because a command can be interrupted

`shell_state` is 0 = accepting input, 1 = a line was submitted, 2 = a command is running.
`kbdHandle` drops every keystroke unless the state is 0.

State 2 is load-bearing. Commands run with IF set, so an IRQ1 can arrive in the middle of one; without
it the handler would append to `shell_line` and bump `shell_len` while `shellExecute` was walking
them, and the command would observe its own input changing. The cost is that type-ahead during a
command is **lost** — there is still no input queue, and a queue is another donated buffer
(`docs/known-gaps.md` GAP-0055 item 4, GAP-0057).

This is also why the conformance harness needed a `wait:<ms>` element in its key list: `ticks`
deliberately takes 160 ms, and without an explicit pause the harness would inject keys into a running
command, have them dropped, and silently be testing a shorter session than it wrote.

## 4. The prompt is uneraseable because the editor's model is the buffer, not the screen

`shellKey` refuses backspace when `shell_len` is 0. That single guard is the whole mechanism, and it
is right for a reason worth stating: the prompt is *screen output*, not part of the line, so
backspacing at an empty prompt is not "move the cursor left one cell", it is nothing at all. No
screen-column arithmetic is involved, which means it stays correct after the line wraps a row, after
the screen scrolls, and after `clear`.

Asserted two ways, because one of them could pass on a coincidence: the harness types three
backspaces at an empty prompt and requires **zero bytes** on COM1 between the prompt and the next
command, and the framebuffer golden then shows that same prompt intact at row 0.

## 5. `mem`: a real result the boot report does not produce

`mem` re-walks the Multiboot structure from the pointer `boot.S` stashed, reusing `mbReport`
unchanged, and then sums the `type == 1` regions — the total nothing has ever computed, because at
boot there was nowhere to put a running total and nobody to ask.

Two details that are not incidental:

- **The 64-bit `length` field is read as two `u32` loads recombined**, not one `u64` load. Multiboot1
  guarantees 4-byte alignment and nothing more; `length` sits at `entry+12`, and DC-IR's `Load`
  carries no alignment attribute. That is the same reasoning `multiboot.dart`'s header already records
  for every other field it reads.
- **The Multiboot pointer is COPIED into `kdata.S`**, not reached through an accessor for `boot.S`'s
  own stash. Exporting `multiboot_info_ptr` would give `kdata.o` an undefined symbol, and `kdata.o`
  passing `verify-freestanding.sh` *standalone* is a documented data point (GAP-0056: it is the
  evidence that the `boot.o`/`isr.o` failures are about cross-object references, not about assembly
  being unanalysable). Eight bytes is the price of keeping that true.

The harness asserts something stronger than the bytes: it extracts **both** memory-map dumps from the
same capture — the boot-time one and the `mem` one — and requires them identical. That compares the
kernel against itself: the structure is still there, still parseable, and still says the same thing
after interrupts, a deliberate fault and a console have happened on top of it.

## 6. `ticks` reports a starting value and a delta, not a live count

A raw live counter is a duration, and a duration is not reproducible, so it could never appear in a
byte-exact golden. M1 hit this exact problem and answered it the same way: "the COUNT is the trigger,
not a duration, so the output is identical regardless of how fast the host is."

`ticks` therefore reads the counter, unmasks IRQ0, waits until it reaches `start + 0x10`, re-masks,
and prints `TICKS <start> +0010 LIVE`. The evidence is that ` LIVE` is printed **after** a loop whose
only exit is the counter advancing. A dead timer does not print a wrong number; it never prints at
all, and the harness fails on a timeout.

**The PIT stays masked at rest**, which M2 chose because nothing needed a timer and 100 interrupts a
second would only add jitter between keystrokes. M3 gets a second benefit from it — with the counter
holding still, `start` is a fixed value (100, the count M1 stopped at) rather than a function of how
long the operator took to type. That makes the line assertable at all, and it means "live" here means
"advances when asked", not "free-running". Stated as a limitation in `docs/known-gaps.md` GAP-0058
rather than left for a reader to discover.

## 7. `clear` is screen-only, and that is not a shortcut

There is no way to un-print bytes that already went down a serial line. A screenful of newlines or an
ANSI escape sequence would be a *different operation wearing this one's name*, and the serial golden
would then contain 25 newlines that mean nothing. So the capture shows the echoed `clear` and the next
prompt with nothing between them, which is exactly what happened. The framebuffer golden is what
asserts the screen was actually blanked.

## 8. Parsing, given that no strings exist

`@bare` DCDart has no String, no array type, no function pointers and no dynamic dispatch. So:

- each command name is a `@rodata final List<u8>` (DCDart ADR-0040) and matching is a loop over two
  byte ranges;
- dispatch is a chain of `if`s, for the same reason `isrDispatch` branches on the vector instead of
  indexing — a `{name, handler}` table is not expressible in this language;
- `shellMatch` returns `u64` 0/1 rather than `bool`, because there are no boolean operators at all
  (no `&&`, no `||`, no `!` — DCDart GAP-0023), so a `u64` composes with the `if` chain without them.

With five commands the chain costs nothing worth noting. The point at which it does is the point at
which function pointers stop being optional, and that is recorded upstream (GAP-0002) rather than
worked around here.

`echo` matches as a prefix and requires the following byte to be a space, so `echonow` falls through
to the unknown-command path instead of being silently read as `echo now`.

## 9. GAP-0055 item 2 is fixed, and it was a wrong answer rather than a missing feature

Extended keys send `0xE0` and then a second byte, in two separate interrupts. The old driver ignored
the `0xE0` and then translated its follower as an ordinary make code, so the up arrow (`0xE0 0x48`)
typed `8` — `0x48` is keypad-8 in the table. `kbdHandle` now consumes the pair as a unit, using one
donated word.

The flag is cleared for the follower whether it is a make or a break code, because both halves of an
extended key press carry the prefix; ignoring only the make would leave the flag set and swallow the
next ordinary key.

**Narrowed, not closed.** `0xE1` (Pause, a six-byte sequence) is still mishandled in exactly the old
way. GAP-0055 item 2 stays open for that, with the arrow-key half struck out rather than the whole
entry deleted.

Asserted: four arrow presses at an empty prompt must produce zero bytes on COM1. At M2 that same
sequence produced `8`, `2`, `4`, `6`.

## 10. M2's goldens were regenerated. That was deliberate and it is not the same as making a test green

`tests/conformance/m2-console/`'s two goldens recorded the *echo box*: type `oscortex 2026`, see
`oscortex 2026`. M3 replaces the echo box with a line editor, so that recording is of behaviour the
kernel deliberately no longer has. Re-recording was the only honest option; the alternative was to
keep asserting something the change was designed to remove.

What was **not** touched, and this is the part that matters:

- **M1's 544-byte golden did not move by one byte**, and m2-console still checks it mechanically as a
  prefix of its own capture.
- **The key sequence is unchanged.** Same 59 keystrokes.
- **Every property m2-console asserts is unchanged in kind**, and one is now stronger: backspace
  editing the screen used to be shown by `ab\bc` on the wire versus `ac` on screen, and is now *also*
  shown by the command the shell dispatches on being `ac` rather than `abc` — the buffer was edited,
  not just the display.
- Its exact-`.bss`-size assertion moved to m3-shell rather than being deleted, because one place
  should own that number and it is the milestone that grew it. m2-console still asserts its own two
  words are 8 bytes each.

Recorded in `docs/known-gaps.md` GAP-0059 so the regeneration is a fact on the record rather than a
diff someone has to notice.

## 11. Verification

`tests/conformance/m3-shell/run.sh`, which **reuses** m2-console's `qmp-drive.py` rather than growing
a second driver. Five structural checks, `verify-freestanding.sh` on `kmain.o`, `kdata.o` and
`kernel.elf`, then a real boot driving a real session, then a second real boot for the negative
control.

Asserted:

1. **Serial, byte-for-byte** (1691 bytes). First 544 bytes are M1's golden, checked mechanically as a
   prefix against M1's own file.
2. **Zero bytes** from three backspaces and four arrow presses at an empty prompt.
3. **The `mem` re-walk equals the boot dump**, extracted from the same capture.
4. **The framebuffer, byte-for-byte**, read out of guest physical memory at `0xB8000` with `xp`.
5. **A PNG** at `core/build/screenshot-shell.png` — produced, not pixel-compared.
6. **A negative control, in the harness rather than by hand.** A second boot with a different key
   sequence must fail *both* goldens, and the serial divergence must start past byte 544 (otherwise
   the goldens would be failing for a reason unrelated to what was typed). Measured: byte 545, exactly
   one past M1's golden.

Structural: `kdata.o` donates exactly 304 bytes of `.bss`; `shell_line` is 256 bytes and
`shell.dart`'s `shellLineMax` says the same (a disagreement there is a silent overflow of donated
`.bss`); all eight shell `@rodata` tables are exactly the sizes the dispatcher compares; `idle_once`
is exactly `sti; hlt; ret`; `kbdSet1Ascii` is still 128 bytes.

`kmain.o` now carries **17** declared externs (up from 12): five `kdata.S` accessors and `idle_once`
added, `idle_forever` removed.

m1-interrupts' `.rodata` exact-size check still holds at 640 bytes = the sum of 31 table sizes,
because every new table is a `List<u8>` and therefore 1-byte aligned. It was **not** relaxed. If a
wider table is ever added it will legitimately trip, and relaxing it then should be its own decision.

**Verified against a clean, pinned DCDart.** The sibling `DCDart` checkout was mid-edit during this
work (two commits past the pin plus an uncommitted change to `dcc-lower/lib/lower.dart`), so all five
harnesses were re-run against a fresh clone of `9e836a3` in a mirrored directory layout — the mirror
being necessary because `kmain.dart` reaches the prelude by a hard-coded relative path and
`DCDART_HOME` cannot redirect it (GAP-0003). All five pass there, and `kmain.o` and `kernel.elf` are
**byte-identical** to the ones built against the working checkout. `DCDART_PIN.txt` is unchanged and
truthful.

## Consequences

- The kernel is operable. You can ask it something and it answers.
- Donated `.bss` is 304 bytes and the number is asserted. GAP-0053 stops being an argument and starts
  being a measurement.
- The steady state is a DCDart loop in task context. Every future long-running or blocking operation
  has somewhere to live that is not an interrupt handler.
- `kbdHandle` no longer echoes; the line editor does. A keystroke now changes *state*, and the screen
  is a consequence of that state rather than the only record of it.
- One documented wrong behaviour (arrow keys typing digits) is gone; one remains (Pause), named.
- M2's goldens were re-recorded, deliberately, with M1's untouched.
