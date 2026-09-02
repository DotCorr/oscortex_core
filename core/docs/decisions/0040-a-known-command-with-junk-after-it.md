# ADR-0040 — A known command with junk after it says so, and `help` states the mode in the base `fb` prints

**Status:** accepted (shakedown)
**Depends on:** ADR-0007 (the shell and fault recovery)
**Related:** GAP-0057 item 3 (there is still no tokenizer), GAP-0246 (`help` growing)

---

## 1. Two T1 findings, both about the listing and the behaviour disagreeing

The shakedown's T1 sweep typed every documented form of every command and every malformed
neighbour of one. Nothing was broken. Two things were **wrong in a way a user meets**, and both are
places where `help` — the only documentation this shell has, since there is no man page, no tab
completion and no `--help` — did not match what the machine did.

### 1a. A typo on a zero-argument command read as an unknown command

```
oscortex> help now
oscortex: unknown command: help now
```

Every zero-argument command is dispatched by **whole-line exact match** (`shellIsCmd` compares a
length as well as bytes), so anything trailing the name falls through to the unknown-command path and
the message names the whole line as if `help now` were a command nobody had heard of.

**The refusal was correct** — the shell survived, it did not guess, and every malformed test in T1
passed. The defect is in the *quality* of the refusal: a user who mistypes the most basic command
there is, is told the command does not exist.

**It is one decision, not eleven bugs.** It was uniform across every zero-argument form.

### 1b. `help` stated the video mode in decimal and `fb` printed it in hex

```
help:  fb            framebuffer console: BAR0, 800x600x32, 8x16 font
fb:    FB BAR FD000000 MODE 0320x0258x20 OK
```

0x320 = 800, 0x258 = 600, 0x20 = 32. **The mode is correct and the command works.** The two lines are
the same three numbers in two bases and nothing said which base either was in. It is the one place in
the whole listing where a stated value did not textually appear in the command's output — so a user
who read `help`, ran `fb`, and saw `0320x0258x20` had no way to tell a working framebuffer from a
broken one.

## 2. The decision on 1a

**A zero-argument command with words after it gets its own refusal, and the commands that take
arguments are the model.**

`disk`, `frames`, `vmtest`, `user`, `crash`, `proc`, `run` and `cat` each already keep a trailing
PREFIX matcher whose only job is to answer a malformed invocation with a usage line — the *"<cmd> IS
a command, it just needs to be told what to do"* path this shell names in six places. A
zero-argument command has no usage line to print, because there is nothing to tell it. What it has to
say is that the words after it are not its:

```
oscortex> help now
oscortex: help takes no argument
```

**The name is echoed out of the line buffer** rather than printed from a table, so one message serves
all eleven and no command's name is written twice.

**A space is required.** `lsx` is still an unknown command; `ls -l` is not. A word that merely starts
with a command's letters is a different word, which is the rule `echo` already applies to `echonow`.

**Which commands.** Exactly the eleven exact-match forms with no prefix matcher behind them: `help`,
`clear`, `mem`, `ticks`, `cpu`, `pci`, `fb`, `alloc`, `vm`, `fs`, `ls`. `disk id`, `frames test`,
`vmtest ro`, `user gp`, `crash ud` and the rest already land on their own family's usage line and
never reach this code.

**Where in the chain.** LAST, after every real dispatch has declined and immediately before
`shellUnknown`. That ordering is what keeps it from shadowing anything: a line that is a real command
is dispatched as one, and this only ever sees lines that were going to be refused anyway. It cannot
change the answer to any line the shell previously accepted.

## 3. The decision on 1b

**`help` states the mode in the base the command prints it in, and names the decimal beside it.**

```
  fb            framebuffer console: BAR0, mode 0320x0258x20 hex = 800x600x32
```

The alternative was to make `fb` print decimal. It was rejected: **every number this kernel prints
goes through `uartPutHex`**, without exception, and that uniformity is worth more than one line's
readability. Introducing a decimal printer for a single field would make the transcript's number
format depend on which subsystem wrote it, which is exactly the property that makes a hex-only
transcript mechanically comparable. The honest reading of the finding is that `help`'s line was the
odd one out, not the output.

So the listing now contains the bytes `fb` actually emits — a user can match them character for
character — and the decimal is kept, labelled, because 800x600x32 is what the mode *is*.

## 4. Cost

Two `@rodata` tables (`shellStrOscortex`, 10 bytes; `shellStrNoArg`, 19), one range writer, and a
chain of eleven prefix tests on the path to `shellUnknown` — which is the path a line takes only when
it is about to be refused, so it costs nothing a user waits on.

`shellStrOscortex` duplicates the first ten bytes of `shellStrUnknown` rather than being a prefix of
it. That is deliberate: a `@rodata` table carries no length word, `m16-filewrite/run.sh` §2g compares
every call site's length against the symbol's size, and printing a prefix of a longer table is
exactly the shape GAP-0060 records going wrong.

## 5. What now fails without each half

* `m3-shell/run.sh` types `help now` and `ls -l` and requires `oscortex: help takes no argument` and
  `oscortex: ls takes no argument` in the byte-exact serial golden — and requires that
  `unknown command: help now` does **not** appear. Before this change the first two strings did not
  exist in the kernel at all.
* The `fb` line is inside `shellStrHelp`, which is byte-exact in five goldens and size-pinned by
  twelve harnesses, so the corrected text cannot drift back silently.
