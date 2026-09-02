# ADR-0023 — `argv`, and the initial process stack

**Status:** Accepted (M19)
**Supersedes nothing. Narrows:** GAP-0113's last item, GAP-0122 item 8.
**Verified by:** `core/tests/conformance/m19-argv/run.sh`

---

## 0. The problem, stated as small as it actually is

Since M10 this operating system has loaded ELF binaries off a FAT16 volume, mapped them into private
address spaces, entered them at CPL 3, given them a heap, a C library, file descriptors and a
preemptive scheduler. And a program received **nothing**. It entered at `_start` with `RSP` pointing at
the top of an empty page and no argument of any kind, so every test program on this machine had its
inputs compiled into it — `m15-fileio`'s program has the string `"DATA.BIN"` in its own `.rodata`.

That is the wall every C program is on the wrong side of, because every C program begins

```c
int main(int argc, char **argv)
```

M19 is the two halves of that contract: the kernel builds the System V x86-64 **initial process
stack**, and the C library's `_start` unpacks it and calls `main`.

---

## 1. What the kernel builds, and where

`core/kernel/args.dart` writes this into the program's stack page, at the entry RSP:

```
RSP + 0x00           argc
RSP + 0x08           argv[0]
...
RSP + 8*argc         argv[argc-1]
RSP + 8*(argc+1)     NULL              terminates argv
RSP + 8*(argc+2)     NULL              terminates envp — WHICH IS EMPTY
RSP + 8*(argc+3)     0   \  one Elf64_auxv_t with a_type == AT_NULL, which is
RSP + 8*(argc+4)     0   /  what terminates an auxiliary vector with no entries
... zero padding ...
the argument strings, NUL-terminated, in argv order, ending at or just below vmProgStackTop
```

**`RSP` is 16-byte aligned.** That is the process-entry rule and it is not the function-entry rule: a
called function sees `RSP ≡ 8 (mod 16)` because a return address has been pushed. `_start` therefore
does **not** realign — a single `call` converts one state into the other exactly — and `build-progs.sh`
asserts by disassembly that `_start` contains no write to `%rsp` at all. An `andq $-16, %rsp` there,
which is what every pre-M19 `_start` on this OS did, would silently mask a kernel that had got the
alignment wrong. It is the most likely way to build this milestone and pass anyway, so it is checked
by name.

The arithmetic, in full, is four lines:

```
strVa = (vmProgStackTop - bytes) & ~7          the strings, 8-aligned down
words = argc + 5                               argc, argv[], NULL, NULL, AT_NULL pair
rsp   = (strVa - words*8) & ~15                and the vector, 16-aligned down
```

For the two-token line `run WC.ELF ALPHA.TXT` that is 17 bytes of text and 7 words: `RSP` lands
0x50 below the top of the page with 4016 bytes of stack left under it.

### Why the frame's physical address and not the virtual one

The block is written through `frame + (va - vmProgStackPage)` — the **physical** address of the stack
frame, which the kernel's identity map covers. `argsPhys` is the only place that conversion appears and
the harness requires it to be defined exactly once. Writing through the virtual address would have
worked too (the loader has just installed the window), but it would have made the kernel's ability to
write there depend on CR0.WP and on the page's user/writable bits, which is a coupling this needed
none of. The physical route is also what `vmZeroFrame` and `elfLoadSegment` already use, so the block
is written the same way the program's own segments are.

---

## 2. Where the strings live, and what happens to them

**In the program's own address space and nowhere else.** They are copied onto the stack page the loader
mapped for this program — user-readable, writable, NX — before ring 3 is entered. The kernel's staging
area, `argsStore`, is a `@bss` block that ring 3 cannot reach at all and that no `argv` pointer ever
names.

When the program exits or faults, `elfTeardown` frees that frame like any other page of the address
space, and the strings go with it. **Nothing in `argv` outlives the address space**, and `m19-argv`
brackets a three-program session with `frames`: the allocator's free count is identical, to the frame,
before and after.

---

## 3. The two bounds, and why they are refusals rather than truncations

* **`argsMaxCount = 8`** arguments, `argv[0]` included.
* **`argsMaxBytes = 128`** bytes of text, including one NUL per argument.

Both are checked **in the shell's parse, before a single frame is allocated**, so a rejected command
line costs the machine nothing and the shell prints one sentence and returns to the prompt. There is no
truncation anywhere, for `fatParseAt`'s reason: a truncated name looks up a different file, and a
truncated argument list runs a different program.

There are five distinct refusal values and four distinct sentences (`argsErrOk` has none, being the
absence of one). The harness requires the values to be distinct *and* the sentences to be distinct
byte-for-byte — M18's lesson, that an assertion a wrong value still satisfies is worthless, applied to
messages as well as numbers.

A third refusal, `argsErrBadByte`, exists for a byte outside `0x21..0x7E`. **It has never executed on a
boot**, because the line editor accepts only printable ASCII, so nothing that reaches `argsCollect` can
carry one. It is kept because the grammar is `fatParseAt`'s and the two should agree about what a byte
may be; it is named here rather than left to be discovered, exactly as GAP-0122 item 13 names
`fileRetNoOwner`. A fourth, `argsErrNoRoom`, is not reachable with the bounds above either — the worst
case is 240 bytes on a 4096-byte page — and is checked anyway because those bounds and the page size are
two numbers in two files.

---

## 4. The tokeniser, which is one function and no more

`argsTokenEnd` finds the first space at or after an offset. `argsCollect` skips runs of spaces and
takes what is between them. **That is the entire grammar**: no quoting, no escapes, no globbing, no
redirection, no `--`, and no way to pass an argument containing a space. GAP-0145.

`run` is the only command that has one. `cat`, `echo` and every other command still take "the rest of
the line" and GAP-0057 item 3 is unchanged for them. The hex parser and the 8.3 name parser each grew a
range-taking form (`ataParseLbaAt`, `fatParseNameAt`) rather than being copied, so `run 2A` and
`run 2A x` cannot disagree about what `2A` is.

**`argv[0]` is the token the user typed to name the program** — a name for `run WC.ELF`, the LBA text
for `run 2A`. Uniform, and it is what `argv[0]` means everywhere else.

---

## 5. `_start`, and why it is in the library rather than in the program

`core/user/libc/start.c` is the sixth object in the C library and the only one that defines `_start`.
It reads `argc` from `(%rsp)` and `argv` from `8(%rsp)`, zeroes `%rbp` so an unwinder stops at the
outermost frame, and calls a C trampoline that calls `main` and passes its return value to `exit`.

**The programs that predate M19 keep their own hand-written `_start`.** m10's are assembly with no
library at all; m13's, m15's and m16's call a `progMain(void)`. Converting them would have moved every
one of those harnesses' goldens and their derived self-hashes for no gain to this milestone. So the
honest statement is: **`start.c` is the entry contract for programs written against it, and four older
test programs still supply their own.** They are not broken by M19 — an initial stack they ignore is
harmless — but they are not evidence for it either, which is why M19 has its own program.

---

## 6. What `main` returns is what the process exits with

`libcStart` calls `exit((unsigned long)(int)main(argc, argv))`. `m19-argv`'s program returns a status
derived from all three of the counts it computed, `derive.py` evaluates the same expression on the
host, and the kernel's `USER EXIT CODE` line is required to carry it. The two runs of the same binary
over two different files exit with two different statuses.

---

## 7. What this is not

* **There is no `envp`.** The kernel writes a NULL where `envp[0]` goes; there is no environment, no
  `getenv`, no `setenv`, no `environ`, and `main` takes two parameters. GAP-0146. `check-stack.py`
  asserts that NULL out of guest memory rather than assuming it.
* **There is no auxiliary vector** beyond the AT_NULL that terminates one: no `AT_PHDR`, `AT_PAGESZ`,
  `AT_ENTRY`, `AT_RANDOM`, `AT_HWCAP`. GAP-0147. The two zero words are there because an ABI-conformant
  `_start` may walk past `envp`'s NULL looking for the vector, and finding a terminator is the
  difference between "empty" and "absent".
* **There is no `.init_array` walk, no `atexit`, no C++ static constructors, no TLS and no `errno`
  location.** GAP-0148.
* **`proc run` passes no arguments.** It takes an LBA, and it enters ring 3 with `RSP` at the top of an
  empty page exactly as before M19 — so `m11-proc`'s and `m18-preempt`'s goldens do not move, and a
  program built against `start.c` started that way faults on its first instruction with a diagnostic.
  GAP-0149.
* **The shell still has no `exec`, no `fork`, no pipes and no redirection.** `argv` is a thing the shell
  hands the loader, not a thing a process can hand another process.

---

## 7b. One thing this milestone does NOT prove, found by mutating it

Reserving `argc + 3` words instead of `argc + 5` — dropping `envp`'s NULL and the AT_NULL auxiliary
entry from the reservation — produces a stack whose **bytes are identical**. `elfLoad` zeroes the
stack frame before mapping it, so the words where those terminators belong read zero whether
`argsBuild` wrote them or not. The mutant is caught, but only because RSP moves by sixteen bytes and
RSP is in a byte-exact golden.

So the precise claim is: **M19 proves the terminators are THERE** — `check-stack.py` reads all four
words out of guest physical memory and requires them zero — **and does not prove that `argsBuild` is
what put them there.** On a kernel that did not zero the frame this would be a real bug, and this
suite would still catch it only by that same accident. Whoever removes the zeroing, or reuses a frame
without it, should come back to this paragraph first.

## 8. What moved that this project promised would not move quietly

* **`.bss` went 14112 → 14368 bytes.** All 256 of it is `argsStore`, and `args.dart` is the **last**
  `part` in `kmain.dart`, so `argsStore` is the last block in `.bss`. That is deliberate and it is the
  same convention M14, M15 and M16 each followed: every earlier harness measures "the donated bytes from
  my block to the end", so a block anywhere other than the end would move all of those numbers at once.
  Each older harness now subtracts this one first and its own number is unchanged. `m19-argv` asserts
  that `argsStore` ends exactly at the end of `kmain.o`'s `.bss` — if a later milestone puts a block
  after it, that check fails rather than the accounting drifting.
* **`ELF ENTER ... RSP` moved** from `0000000010200000` to the computed value, in every golden that
  carries the line. It now differs between command lines, which is evidence rather than noise.
* **`m1-interrupts`' 544-byte golden did not move**, and is still asserted as a byte-exact prefix by
  every harness that boots past M1, M19's included.
* **44 declared externs, unchanged.** M19 adds no assembly and no new `@extern`.
