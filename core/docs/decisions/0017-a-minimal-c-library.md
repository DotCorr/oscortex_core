# ADR-0017 — A minimal C library: one `int $0x80`, a first-fit free list, and a `printf` that says when it cannot

**Status:** accepted (M13)
**Date:** 2026-08-22
**Supersedes:** nothing. **Narrows:** GAP-0107 item 3.
**Depends on:** ADR-0013 (the syscall boundary), ADR-0014 (the ELF loader and the program window),
ADR-0015 (processes), ADR-0016 (`sbrk`).

---

## 0. The problem, stated so the scope is obvious

M12 ended with a kernel that can give a process pages at runtime, and with this sentence in
GAP-0107: *"A `malloc` is therefore still entirely userland's problem, which is the normal division
of labour and is stated because it is the reason this milestone exists."*

Userland at that moment consisted of three test programs, each of which hand-rolled its own
`int $0x80` stub, its own hex formatter and its own byte loops. There was no `malloc`, no `printf`,
no `strlen`. **No ordinary C source could be compiled for this operating system** — not because the
kernel lacked anything, but because the C that people write calls functions that did not exist here.

M13 writes them. It changes **no kernel code at all**: donated `.bss` is still 9664, `kmain.o` still
declares 58 externs, `shellStrHelp` is still 1871 bytes, and `m13-libc/run.sh` asserts all three
rather than the commit message claiming them.

---

## 1. Where it lives, and why not in the harness

`core/user/libc/` — one header and four `.c` files, outside `core/tests/`.

The repo's standing rule is that *the milestone that owns a harness owns its inputs* (m11-proc's
reason for copying `prog.ld` rather than sharing it). A library is the exception, and it is the
exception for the reason the rule exists: `prog.ld` is copied so that editing one milestone's layout
cannot silently relayout another's, whereas a `malloc` that each milestone copied would be four
`malloc`s, three of which nobody runs. The whole value of a library is that the next program does
not write one.

There is **no archive, no install step and no checked-in object**. Every harness that wants the
library compiles it from source, with the same flags as the program that uses it, in
`build-progs.sh`. So "the libc works" can never decay into "the libc worked when somebody last built
it".

---

## 2. Five syscalls, one `int $0x80`

`syscall.c` holds the only `int $0x80` instruction in the library, and `m13-libc/run.sh` counts
them. `malloc` reaches the kernel through `sbrk` and `printf` through `write`; neither may reach it
any other way, and that is a structural check rather than a convention.

The five syscall numbers, the four `sbrk` refusal values, the syscall refusal value and the write
limit in `oslibc.h` are **all checked against the kernel's own sources at harness time** —
`userSysExitNo`, `userSysWriteNo`, `userSysWhoNo`, `userRefused` and `userWriteMax` out of
`user.dart`, `procSysYieldNo` out of `proc.dart`, and `heapSysSbrkNo`, `heapRetFloor`,
`heapRetNoMem`, `heapRetNoSpace` and `heapRetBadArg` out of `heap.dart`. Eleven numbers. Before M13 there were three copies of these numbers
in three test programs; a fourth copy that was *not* checked would have been worse than three that
were not.

`sbrk()` returns `NULL` on refusal and keeps the raw value in `sbrk_last_error()`. ADR-0016 §1 made
the three refusals distinct on purpose — "your address space is full" and "the machine is out of
memory" are different facts with different remedies — and a wrapper that collapsed them to `NULL`
and threw them away would have spent that.

---

## 3. `printf` is one call, one `write`, one line

This OS has no file descriptors, no buffering, no `stdout` and no `\n` convention.
`userSysWrite` prints `USER WRITE `, the bytes, and a newline of its own; `elfOwns` **refuses** a
length above `userWriteMax` (128). Those are properties of the kernel, not tastes, and the library
is shaped by them: `printf` formats into a 120-byte buffer and issues exactly one `write`.

A formatted string longer than 120 bytes is therefore not a thing this OS can print in one call.
The library says so — the line ends in `%!OVF` and the call returns `-1` — rather than truncating.
`PRINTF_MAX + 5` must stay inside `userWriteMax` or the overflow line would itself be refused and
the marker would never be seen; that arithmetic is a harness check.

**Why not chunk a long line into several writes.** It was the first design. It produces several
`USER WRITE` lines on the console for one logical line, which reads as a bug in the program's output
and is one in every golden file that captures it. A cap that is visible beats a wrap that is not.

---

## 4. `memcpy` and `memset` are not optional, and the `volatile` in the loops is a guard this toolchain does not need

clang at `-O2` emits **calls** to `memcpy` and `memset` from C that names neither — a struct
assignment, a large zero-initialiser — and `-ffreestanding -fno-builtin` does not stop it: those
flags stop it treating a call the *source* wrote as known, not stop it emitting one of its own.
`m13-libc/build-progs.sh` requires `progL.o` to have undefined references to both, so this paragraph
cannot quietly become false when a compiler changes.

The first version of the struct in `prog.c` was 56 bytes and clang copied it with inline moves,
emitting no call at all. The check caught the claim before the claim shipped. The struct is 296
bytes now.

**The five string functions loop through `volatile` pointers, and the honest version of why is not
the one this ADR was first drafted with.** The hazard is real: a loop-idiom recogniser rewrites
`while (n--) *d++ = c;` into a call to `memset`, and if the loop it is looking at *is* the body of
`memset` the result calls itself forever and blows the one-page stack a process gets here. GCC does
it through `-ftree-loop-distribute-patterns`.

**It was then measured on this toolchain and does not happen.** Apple clang 17 at `-O2` for
`x86_64-unknown-none-elf` emits no call from the plain non-volatile versions, with `-fno-builtin` and
without it; LLVM's `LoopIdiomRecognize` declines to rewrite a loop into a call to the function
containing it. A mutation that stripped every `volatile` from `string.c` was run through the whole
harness **with the golden regenerated and SURVIVED** — nothing here can tell the two versions apart
except code size. GAP-0114 records it as one of two survivors.

The `volatile` stays as a cheap portable guard against a compiler this project does not use today,
and its cost is stated rather than hidden: byte-at-a-time loops with volatile accesses, several times
slower than a word-at-a-time `memcpy`. Nothing here is throughput-bound.

`build-progs.sh` disassembles all five and requires **not one `call` instruction** inside any of
them. That check is correct and would catch the hazard the day a toolchain introduced it; on this
toolchain it currently has nothing to catch, and saying so is the point of this paragraph.

---

## 5. `printf` implements exactly five conversions, and the sixth is loud

`%s`, `%d`, `%x`, `%c`, `%%`. Anything else after a `%` — a width (`%5d`), a flag, a length modifier
(`%ld`), an unimplemented conversion (`%u`, `%p`, `%f`, `%o`), or a `%` at the very end of the format
— emits the two characters `%!` and consumes the offending character. **No argument is consumed**,
because the library has no idea what size the argument for an unknown conversion would be and
guessing would put every later conversion in the same call out of step.

This is the part of the design worth arguing for. The cheap way to write a `printf` subset is to
skip what you do not understand, and the result is a program that prints `Total: ` where it meant
`Total: 42`, and a golden file that enshrines it. A `%!` in a serial capture is a diff, a failed
harness and a five-second diagnosis. `run.sh` reads the set of implemented conversions **out of
printf.c** and requires it to be exactly those five with a marking `else`, and the test program
formats four unsupported conversions in one line so that the marker is measured rather than
promised.

`%x` is lowercase, which is what C says, and which makes ring-3 output trivially distinguishable
from the kernel's own uppercase `uartPutHex` in a capture.

---

## 6. `malloc` is a first-fit free list with splitting and coalescing — and that name is exact

ADR-0016 §4 was careful to call the kernel's `sbrk` **a bump pointer rather than an allocator**,
because the break only moves up and nothing is reused. The honest counterpart is to say precisely
what sits on top of it.

```
[ 16-byte header | payload ]  header = { size, next }
```

* **First fit.** A linear scan from the head takes the first block that fits. There are no bins and
  no best fit, so a long free list costs a long walk: O(free blocks) per `malloc`.
* **Splitting.** A block at least `need + 16 + 16` bytes long is split and the tail goes back on the
  list. Without it the first page would be handed out entire to a five-byte request.
* **Coalescing.** The list is kept in **address order** for exactly one reason: so that a freed block
  can be merged with whichever of its neighbours it physically abuts. The test is
  `end of one == start of the other`, exact rather than approximate, so two free blocks with one byte
  between them are not merged into one that claims a byte it does not own.
* **`free` is a real `free`.** It is not a no-op. A freed block comes back from the next `malloc` of
  a size that fits, at the same address.

**What it is not**, so that nothing is inferred: no `realloc`, no `calloc`, no size classes, no
thread safety, no double-free detection, no guard bytes. And **memory is never returned to the
kernel** — `sbrk` cannot shrink (GAP-0107 item 1), so `free` returns memory to the *program*, not to
the machine. GAP-0111 is the accounting.

**The header size, the alignment and the minimum split are exported as `volatile const` words**
(`mallocHdrBytes`, `mallocAlign`, `mallocMinSplit`), spelled as the macros themselves rather than as
copies of them, and `m13-libc/derive.py` reads all three **out of the ELF** to recompute where every
block must land. An earlier version wrote `= 16` three times, which was noticed while writing the
mutation set rather than by running one: a mutation of `ALIGN` would have changed the allocator while
leaving the harness reading a 16 that no code obeyed, and the block offsets would only have caught it
by luck of the arithmetic. Spelling them as the macros makes the exported words unable to disagree
with the code, so that mutation is not in the set because it is no longer expressible.

---

## 7. The negative control is a second build of the same source

`progN` is `progL` with `free()` disabled by **one `volatile const` word** — not an `#ifdef`, so the
two binaries have byte-identical segment geometry, the same entry point and the same heap base, and
every difference between their two serial transcripts is attributable to `free` and to nothing else.
m12-heap's one-source-two-builds argument, pointed at a different question.

The test program therefore **does not assert that memory is reused**. It measures whether it is and
reports which:

| | progL | progN |
|---|---|---|
| a freed block comes back at the same address | `REUSE 1` | `REUSE 0` |
| two freed neighbours merge | `COALESCE 1` | `COALESCE 0` |
| everything freed, all six allocated again onto the same six addresses | `ROUND2 1` | `ROUND2 0` |
| bytes taken from the kernel | `0x3000` | `0x5000` |

and `run.sh` then runs **progL's expectations against progN's transcript and requires them to fail**.
A reuse check that passes for a program with no `free` at all is measuring nothing, and that is the
exact shape of the one wrong-for-the-right-reason check that m10, m11 and m12 each found in their own
harness.

---

## 8. What was deliberately not done

* **No shell command, and therefore no new `help` line.** `shellStrHelp` is unchanged at 1871 bytes
  and m3–m6's goldens did not move. GAP-0105's incident, designed around again.
* **No kernel change of any kind.** A library that needed one would have been a different milestone
  with its own ADR.
* **No `realloc`, no `calloc`.** GAP-0111.
* **No `open`, no `read`, no `FILE`, no `errno`.** There is no filesystem to put behind them
  (GAP-0090, which this milestone does not narrow) and an `errno` that only `sbrk` ever set would be
  a convention pretending to be an interface. GAP-0113.
* **No `%u`, `%p`, `%f`, `%ld`, no widths and no precision.** GAP-0112.
* **No demonstration of `malloc` under a heap that runs out mid-program.** The program shows a
  4 MiB request refused with `heapRetBadArg` and keeps running; a request refused with
  `heapRetNoSpace` part-way through a grow needs the window nearly full, which is m12-heap's
  eight-second growth loop and its own harness. GAP-0111 item 7.
