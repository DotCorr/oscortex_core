# Applications — what programs would make this usable, and what each one needs that does not exist

**Status: DESIGN. Not an ADR, not numbered, nothing implemented.** Written 2026-08-23 against
`core/user/libc/oslibc.h`, `core/kernel/file.dart`, `core/kernel/shell.dart`, `core/kernel/elf.dart`,
`core/kernel/user.dart`, `core/kernel/heap.dart`, `core/kernel/args.dart` and `core/kernel/vm.dart` at
M19, and against the thirteen sibling documents indexed by `core/docs/design/README.md`.

`README.md`'s own table lists **applications** among the things the corpus does not cover. This is that
document. It is the answer to one question — *what would a person actually run on this machine, and
what stops them* — and it is deliberately the one document in the corpus written from the outside in.

**It cites rather than re-derives.** The cross-cutting blockers (the eight PIC-mask writes, the syscall
registry, the 41 stale comments, `vm.dart:1958`) are `README.md`'s and are not restated here. The
address-space numbers are `memory.md`'s, the loader's caps are `exec-format.md`'s, the libc counts are
`libc-roadmap.md`'s, the input queue is `display-protocol.md` §4's, the blocked state is
`blocking-and-threads.md` B1's, and the device sigil is `namespace.md`'s. Where this document adds a
number it says so.

---

### The five things this document lands on, for a reader in a hurry

1. **The two ways to start a program on this machine have disjoint capabilities, and no program can
   have both halves.** `run <name> args...` gives a program `argv` and four file descriptors and
   **refuses `sbrk`**, so `malloc` returns `NULL` for every program `run` can start. `proc run <lba>
   <lba>` gives a program a heap and takes **no arguments at all**, and a program built against
   `core/user/libc/start.c` started that way **page-faults at `_start + 2`** (GAP-0149). *There is
   currently no way to run a C program on this operating system that has both a command line and a
   heap.* That is §1.1, and it is the single cheapest thing on this ladder to fix.
2. **The most useful program writable today is `cp`,** and it needs nothing that does not exist. It is
   also the first thing this OS would gain that the ring-0 shell **cannot do at all**: `shellFatCat`
   can show you a file and there is no kernel command that copies one. Its exit criterion already
   exists — M16's host read-back. §1.3.
3. **`shellExecute`'s 48 arms are not 48 shell commands.** Counted and classified in §2.1: **8 are
   usage lines that exist only because there is no tokeniser**, **33 are kernel and hardware
   introspection that can never be a ring-3 program without device files**, and **7** — `help`,
   `clear`, `echo`, `fs`, `ls`, `cat`, `run` — are what a Unix shell would call commands. Moving "the
   shell" to userland does not empty `shell.dart`. It **splits** it, and the 33 want `namespace.md`'s
   `:` sigil, not deletion.
4. **`ls` is impossible today and that is the most embarrassing gap in the tier list.** There is no
   `opendir`, no `readdir`, and no way for ring 3 to enumerate the volume at all (GAP-0122 item 2). The
   most-typed command on any operating system cannot be a program on this one. The fix that costs
   **zero new syscalls** is `namespace.md`'s device branch: `open(":ROOT")` and `read` it. §3, tier 1.
5. **Self-hosting, honestly, is not one goal but two, and only the second is reachable.** The kernel is
   DCDart compiled by `dcc`, which is a Dart program requiring exactly Dart 3.12.2 — *this OS building
   itself means running a Dart SDK on it*, and that is not a milestone, it is a different project. The
   reachable goal is **"the machine can build a program that runs on it"**, and it is gated on four
   caps — a **4096-byte stack**, a **65,536-byte image**, a **2 MiB address space** and a **root
   directory with 8.3 names** — none of which is a compiler problem. §4.

### And the four findings that surprised me

* **`malloc` is in the library and no program that can be given a filename can call it.** `user.dart:
  1585–1591` refuses syscall 4 unless `procLive() > 0`; `run` enters ring 3 through `elf.dart:1939`'s
  `enter_user` with no process slot; `sbrk` therefore returns `userRefused`, which is above
  `SBRK_ERR_FLOOR`, so `sbrk()` returns `NULL` and `malloc()` returns `NULL`. **Every one of M12's and
  M13's allocator properties is unreachable from a program that has `argv`.** This is not written down
  anywhere: GAP-0149 records the *other* half (a `start.c` program cannot be `proc run`), and nobody
  wrote down that the half which *does* work has no heap.
* **A program has no heap and can still have a megabyte of memory.** `elfImageMax` (65,536) bounds the
  bytes read **off the disk**; `.bss` is `p_memsz`, not `p_filesz`, and the loader maps up to
  `vmProgEnd`. So a program today may declare a several-hundred-kilobyte static buffer and get it
  zeroed and mapped for free. This is derived from the loader's bounds and **has not been demonstrated
  by a boot** — it is the first thing APP1 should incidentally prove, because if it is true it changes
  what is writable today, and if it is false the loader has a bound nobody has named.
* **An editor on this OS cannot save a file safely, and the fix is `rename`, not a write path.**
  `O_WRITE` is create + truncate + append, indivisibly (GAP-0127 item 1), and there is no `rename`
  (item 3), so GAP-0127 item 8's sentence — *"write a new version and swap it in" is not expressible* —
  means **the moment an editor writes the first byte of a save, the user's old file is already gone.**
  A general write-at-offset path is a large milestone; `unlink` + `rename` is, by GAP-0127 item 3's own
  estimate, twenty lines. **The twenty lines buy the safety and the large milestone does not.**
* **Two more milestone-prefix collisions, of exactly the class `README.md` already caught for `N` —
  and the second one happened while this document was being written.** `text.md` numbers its ladder
  **T1–T8** and `time-and-power.md` numbers its ladder **T1–T3**: "T1" is the shift key and it is also
  the free-running PIT. And `arm64-port.md` — which landed in this directory during this session —
  numbers its ladder **A0–A…**, which is the prefix this document had already taken. Single letters
  are exhausted enough that they are now a hazard rather than a convention: **`A`, `B`, `D`, `G`, `L`,
  `N`, `P`, `S`, `T` and `X` are all in use, three of them by more than one document.** This ladder is
  therefore numbered **`APP1`–`APP10`**, and the recommendation to the coordinator is that every future
  ladder use a multi-letter prefix (`MEM` is the only one that already does, and it is the only one
  that has never collided).

---

## 0. What is true today, with citations

Nine facts. Every number is read out of the tree, and the file and line are given so that a reader who
believes one of them has changed can check in one command.

| fact | value | citation |
|---|---|---|
| syscalls | **eleven**, 0–10: `exit write who yield sbrk open read close seek fdwrite preempts` | `user.dart:731-733`, `proc.dart`, `heap.dart:142`, `file.dart:256-276` |
| descriptors | **4 per owner**, 5 owner rows (4 process slots + `fileRunRow = 4` for `run`) | `file.dart:281,286,291` |
| one `read` | **512 bytes**; more is `fileRetBadLen` | `file.dart:300` |
| one `fdwrite` | **512 bytes**; more is `fileRetBadLen` | `file.dart:310` |
| one console `write` | **128 bytes** (`userWriteMax`), and `printf` caps itself at **120** | `user.dart:738`, `oslibc.h` |
| names | **8.3, twelve characters, root directory only, no path component** | `file.dart:304`, GAP-0122 item 2 |
| write mode | **create + truncate + append-only**, indivisibly; `seek` on a write fd is `FILE_EBADMODE` | `file.dart:413-414`, GAP-0127 item 1 |
| `printf` | **five conversions** `%s %d %x %c %%`; anything else — a width, a flag, `%f`, `%p`, `%u` — emits `%!` | `oslibc.h` §4 |
| input | **none.** No `stdin`, no `getchar`, no console-input syscall of any kind | GAP-0122 item 7 |

And four bounds from the sibling documents, reproduced because every section below hits at least one of
them:

* **image**: `elfImageMax = 65536` bytes = 128 sectors (`elf.dart:767`, `exec-format.md` §0 fact 2);
* **file**: `fatChainMax = 256` clusters = **262,144 bytes** — a file larger than 256 KiB is
  `fatErrTooBig` and is *not* truncated (`fat.dart:202`);
* **address space**: one 2 MiB page-directory entry, `[0x10000000, 0x10200000)`, 512 pages
  (`vm.dart:1976,1980`);
* **stack**: **one page**, `[0x101FF000, 0x10200000)` = 4096 bytes, with the heap's guard page
  immediately below it at `0x101FE000` (`vm.dart:1997,1998`, `heap.dart:148,158`).

---

## 1. WHAT A PROGRAM CAN DO TODAY, HONESTLY

### 1.1 There are two doors into ring 3 and they lead to different operating systems

This is the finding of §1 and it is not recorded in any gap entry.

A real ELF program reaches ring 3 by one of exactly two paths, and the path decides which syscalls it
is allowed to make.

**Door one — `run <name|lba> [args...]`.** `shell.dart:1444` → `elf.dart:1972` `shellElfRunCmd` →
`shellElfRunName` → `shellElfLoadAndEnter(0, 1)` → `elf.dart:1939` `enter_user`. **No `procCreate` is
called anywhere in `elf.dart`.** The program is `elfLive()`, not `procLive()`.

**Door two — `proc run <lbaA> <lbaB>`.** `shell.dart` → `proc.dart:1780` `procCreate`, which at
`proc.dart:1856` calls `heapInit(s, elfMeta(elfMetaHi))` and gives the slot a break.

`userSyscall` (`user.dart:1529`) then discriminates. Three syscalls are refused unless a **process** is
live, each with its own comment saying why:

```
user.dart:1556   yield      (3)   procLive() < 1  → userRefuse
user.dart:1573   preempts  (10)   procLive() < 1  → userRefuse
user.dart:1585   sbrk       (4)   procLive() < 1  → userRefuse
```

and four are deliberately **not** so restricted, because `fileOwnerRow` (`file.dart:648`) hands a
`run` program row 4:

```
user.dart:1600+  open read close seek fdwrite  → fileOwnerRow(), fileRetNoOwner only for an M9 payload
```

Put the two doors beside each other:

| | `run NAME.ELF a b c` | `proc run <lbaA> <lbaB>` |
|---|---|---|
| `argv` | **yes** (M19) | **no** — GAP-0149; a `start.c` program page-faults at `_start + 2` |
| name resolution | by 8.3 name off FAT | LBA only (GAP-0119) |
| `open/read/close/seek/fdwrite` | **yes**, four descriptors, row 4 | **yes**, four descriptors, own row |
| console `write`, `exit` | yes | yes |
| **`sbrk`, and therefore `malloc`** | **REFUSED** | yes |
| `yield`, `preempts` | REFUSED | yes |
| preemption | n/a — nothing else is runnable | yes (M18) |
| how many at once | one (`elfErrLive` refuses a second) | two, and only two — GAP-0096 item 1, GAP-0101 |

**The consequence, stated plainly: `malloc` is a function in this operating system's C library that no
program which can be told its own arguments is able to call.** `sbrk()` sees `userRefused`
(`0xFFFF...FF`), which is above `SBRK_ERR_FLOOR`, returns `NULL`, and `malloc` returns `NULL` for every
size. A program that checks its `malloc` — which is the correct thing for a program to do — exits
cleanly and does nothing. A program that does not check it dereferences `NULL`, takes a page fault at
address 0, and the kernel tears it down and prints why. **Neither failure is silent, which is the only
good thing about this.**

M13 and M12 both work. They work because their test programs are started through door two and have no
arguments to be told.

**The escape hatch, and the reason `cp` and `wc` are writable anyway.** `elfImageMax` bounds the bytes
the loader reads **off the disk**. A `PT_LOAD` segment's `p_memsz` may exceed its `p_filesz`, and
`elfCheckPhdr` bounds the *virtual* range by `vmProgEnd` rather than by `elfImageMax`. So a program
that needs 64 KiB of buffer declares it in `.bss`, costs zero disk bytes, and is zeroed by the loader.
**Static allocation is the memory model of this operating system's userland right now, and it should be
written down as such rather than rediscovered.** Every program in §1.3 and §3's tier 0 is written that
way on purpose.

Caveat, stated because I have not booted it: the `.bss` claim is *derived* from the loader's bounds and
is **not** demonstrated by any harness. APP1's program should carry a buffer large enough to prove it, so
that the claim is measured or falsified rather than repeated.

### 1.2 The complete list of what a program can do

Positively, and this is more than it sounds:

* be told up to **8 arguments** totalling **128 bytes** including terminators (`argsMaxCount`,
  `argsMaxBytes`), with `argv[0]` the word the user typed;
* `open` up to **four** files at once by 8.3 name in the root directory, in read mode or write mode;
* `read` them 512 bytes at a time, with the offset kept in the descriptor, `seek` absolutely inside
  them, and get a **short count at end of file** — the interface tells the truth about the tail;
* `create` a file, `fdwrite` up to 512 bytes at a time onto the end of it, and `close` it — and the
  bytes are on the volume after the machine is switched off and on, and **host tools believe the
  volume** (M16 verified by `fsck_msdos` and by macOS's own `msdos` driver, not by this kernel reading
  back what this kernel wrote);
* `printf` with `%s %d %x %c %%`, up to 120 bytes per call;
* hold a large static buffer in `.bss` (§1.1);
* `exit` with a status the shell prints.

Negatively, and the citation is the point:

| cannot | citation |
|---|---|
| read a key, or be asked a question | GAP-0122 item 7 |
| list a directory, or learn any name it was not given | GAP-0122 item 2 |
| ask how big a file is without reading all of it | GAP-0122 item 3 |
| `seek` from the end | GAP-0122 item 4 (needs item 3) |
| write at an offset, or keep what a file already had | GAP-0127 items 1, 2 |
| delete, rename, or replace a file atomically | GAP-0127 items 3, 8 |
| allocate memory, *if it has arguments* | §1.1 — new here |
| create another process, or wait for one | GAP-0096 item 7, GAP-0141 |
| know the time | GAP-0127 item 4, GAP-0058 |
| print a float, a width, a zero-pad, or a pointer | `oslibc.h` §4 — `%!` |
| use `errno` | GAP-0122 item 6 (a choice, not an omission) |
| block on anything | GAP-0141, `display-protocol.md` §0 constraint 4 |

### 1.3 The most useful program currently writable: `cp`

**`cp SRC DST` needs nothing that does not exist**, and it is the right first program for three
reasons that are not about `cp`.

*It adds a capability the kernel does not have.* `shellFatCat` prints a file. Nothing in
`shellExecute`'s 48 arms copies one, moves one, or produces a new file at all. **`cp` is the first
thing this operating system could do that its own shell cannot** — which is the whole argument for
userland, made in about forty lines of C.

*It fits every bound exactly, without arithmetic.* Two descriptors of four. One 512-byte `.bss` buffer,
matching `READ_MAX` and `WRITE_FILE_MAX` — the two caps are the same number, so the loop has no
partial-buffer case. No heap, so §1.1's split does not bite. Two arguments, well inside eight. `argv`
is what makes it possible at all, which is why this program could not have been written before M19.

*Its exit criterion already exists and is not this kernel's own opinion.* M16 established the method:
run the guest, pull the image, and have **`fsck_msdos` and macOS's `msdos` driver** read the result.
`cp` is the ideal exercise of it, because the correct answer is "byte-identical to a file the host
wrote", and the host has that file.

The shape, written out because the bounds are the design:

```c
#include "oslibc.h"
static unsigned char buf[512];              /* .bss — no malloc, and none available (§1.1) */

int main(int argc, char **argv) {
  if (argc != 3) { printf("cp: usage: cp SRC DST\n"); return 2; }
  unsigned long in = open(argv[1]);
  if (in > FILE_ERR_FLOOR) { printf("cp: %s: %x\n", argv[1], (int)in); return 1; }
  unsigned long out = create(argv[2]);      /* CREATES AND TRUNCATES. See below. */
  if (out > FILE_ERR_FLOOR) { close(in); printf("cp: %s: %x\n", argv[2], (int)out); return 1; }
  unsigned long total = 0;
  for (;;) {
    unsigned long n = read(in, buf, sizeof buf);
    if (n > FILE_ERR_FLOOR) { close(in); close(out); return 1; }
    if (n == 0) break;                      /* short read is normal; 0 is EOF */
    unsigned long w = fdwrite(out, buf, n); /* n, NOT sizeof buf — the negative control */
    if (w > FILE_ERR_FLOOR) { close(in); close(out); return 1; }
    if (w < n) { close(in); close(out); printf("cp: full after %d\n", (int)(total + w)); return 1; }
    total += w;
  }
  close(in);
  close(out);                               /* THE FLUSH. Not optional — GAP-0127 item 6. */
  printf("cp: %d bytes\n", (int)total);
  return 0;
}
```

**Four honest limitations, named rather than discovered.**

1. **`cp A A` destroys `A`.** `create` truncates before anything is read (GAP-0127 item 1), and there is
   no way to ask whether two 8.3 names denote the same file except to compare the names — which is
   sound here only because names are folded to upper case and there are no paths, links or aliases.
   The comparison is three lines and it must be in the program.
2. **The source is capped at 256 KiB** by `fatChainMax`, not by `cp`.
3. **A failure part-way leaves a truncated destination**, and cannot leave anything else: with no
   `rename` (GAP-0127 item 3) there is no temp-and-swap. The program can report it and nothing more.
4. **The count is not a summary, it is the interface.** `fdwrite` returns short exactly when the volume
   fills (`oslibc.h`), and `read` returns short on the last read of every file whose size is not a
   multiple of 512 — which is most of them. A `cp` that passes `sizeof buf` to `fdwrite` instead of `n`
   works on every file whose length happens to be a multiple of 512 and corrupts every other one. That
   is the negative control APP1 must build.

### 1.4 The runners-up, and why one of them is worse than the kernel's version

**`wc FILE` — second, and it is the one M19's own header already imagines** ("`run WC.ELF DATA.BIN
lines`"). Everything it needs exists: `argv`, a read loop, `%d`. Its value is that its answer is
*derivable on the host* from the same file, which makes it the cheapest non-vacuous exit criterion in
this document. Its limitation is that a `wc` given nine names cannot be given nine names — and
`oslibc.h` exports `ARGS_MAX_COUNT` precisely so it can say so instead of being refused with no
explanation.

**`hexdump FILE` — third, and it is the best demonstration of what `printf` costs.** Sixteen bytes per
line at three characters each is 48 bytes, comfortably inside the 120-byte `printf` cap and the
128-byte `write` cap. But **`%02x` is not a thing this library has**: any width or flag emits `%!`
(`oslibc.h` §4, ADR-0017 §5). So `hexdump` must build each byte's two nibbles itself out of a 16-byte
lookup table and `%c`, or emit a stream of `%x`es whose columns do not line up. It works, it is useful,
and it is the program whose source most clearly demands `libc-roadmap.md`'s L4.

**`cat FILE` — writable, and *worse than the ring-0 `cat` that already exists*.** This deserves its own
sentence because it is the counter-example to "userland is better". A ring-3 `cat` cannot reproduce a
file's bytes on the console, for three independent reasons, none of which is about `cat`:

* `userWriteMax` is **128**, so a 512-byte read is four writes;
* `userSysWrite` prints the literal prefix `USER WRITE ` before the bytes **and a newline of its own
  after them** (`oslibc.h` §"ONE printf CALL IS ONE write IS ONE LINE"), so the output is annotated and
  re-broken at 128-byte boundaries that have nothing to do with the file;
* there is no `stdout` and no way to ask for a raw write.

**A userland `cat` is therefore blocked on a raw console write, not on the filesystem** — and that is
the same decision `display-protocol.md` §4.3/Q3 declines to make about who owns the console. It should
be made once, for both.

---

## 2. THE SHELL IS IN RING 0

### 2.1 First, what the 48 arms actually are

`shellExecute` (`shell.dart:1260`) is a flat chain of `shellIsCmd`/`shellStartsWith` tests. There are
**48** of them (counted mechanically over lines 1260–1560). They are not 48 shell commands, and the
classification changes what "move the shell to userland" means:

| class | count | the arms | can it be a ring-3 program? |
|---|---|---|---|
| **usage lines** | **8** | `disk`, `frames`, `vmtest`, `user`, `run`, `cat`, `proc`, `crash` bare forms | They are not commands. They exist because there is no tokeniser (GAP-0057 item 3, GAP-0145) and every command that takes an argument needs an arm for "given none". **A real tokeniser deletes all eight.** |
| **kernel / hardware introspection** | **33** | `mem` `ticks` `cpu` `pci` `fb` `disk id` `disk read` `frames`×4 `alloc` `free` `vm` `vmtest`×4 `user`×7 `proc`×6 `crash`×2 | **Not without device files.** Each reads or writes something ring 3 cannot name: config space, BARs, page tables, the frame allocator, the process table, a deliberate fault. |
| **shell commands** | **7** | `help` `clear` `echo` `fs` `ls` `cat` `run` | Yes — and `ls` is the one that cannot be written today at all (§3). |

**So the honest framing is: `shell.dart` is about 85% kernel debug monitor and 15% shell, and the
userland question applies to the 15%.** The 33 do not want to be deleted and do not want to be ported;
they want `namespace.md`'s device branch, so that `pci` becomes a ring-3 program that reads `:PCI`,
`frames` reads `:PMM`, and `proc` reads `:PROC`. That is the same mechanism `display-protocol.md` §2.4
proposes for `:WSYS` and it costs **zero new syscalls** because `open`/`read` already exist. It is also
the one change that makes the diagnostics *composable* — `run WC.ELF :PCI` counts the devices — which
is the argument for Unix in one line and this machine cannot currently make it.

**And the 33 must keep a ring-0 spelling regardless**, because they are how the machine is debugged
when userland is broken. `display-protocol.md` §4.3's Q3 reaches the same conclusion from the other
side: *"a compositor that crashes should not take the keyboard with it."* The kernel monitor is not
technical debt. It is the recovery console.

### 2.2 What "the shell is a program" actually requires

Six things. Two are the hard blockers the brief names, one is a third blocker that no document has
named as such, and three are ordinary work.

1. **`stdin`** — §2.3.
2. **A way to start a program from a program** — §2.4.
3. **A way to be resident, and to get the CPU back** — §2.5. *This is the one nobody has costed as a
   shell problem.*
4. A tokeniser worth the name. `GAP-0145`: *"The shell's tokeniser is runs of spaces, and there is
   nothing else."* `argsCollect` already does this much for `run`; a userland shell wants quoting, and
   quoting is a userland problem the moment the shell is userland. **Free.**
5. Line editing — a buffer, backspace, and eventually history. Ordinary C, and `shell.dart` already has
   the 256-byte buffer to copy the semantics from. **Free**, except that `text.md` T1 is a prerequisite
   for the shell being able to *type* a capital letter at all (*"this machine cannot type a capital
   `A`"*), which matters the day a file name has to be typed in a case the FAT layer does not fold.
6. A decision about what `help` says, which `GAP-0142` shows is already a maintenance problem inside the
   kernel and stops being one outside it.

### 2.3 Blocker one — there is no `stdin`, and the keyboard is not merely "owned by the shell"

The usual phrasing understates it. The keyboard is not stored anywhere. `display-protocol.md` §4.1 is
titled **"There is no keystroke queue at all. Depth zero."** `kbdHandle` (`keyboard.dart:222`) reads
port 0x60 and calls `shellKey`, which appends to the shell's line buffer and echoes to the screen
**inside the interrupt handler, before the EOI**. And `keyboard.dart:263` is `if (shellState() > 0)
return;` — so **while any command is running, every keystroke is discarded silently.** Type-ahead
capacity while a program is on the CPU is **zero bytes** (GAP-0055 item 4).

`display-protocol.md` §4.2 is the specification and this document adopts it without change:

* a **ring buffer in `@bss`**, head and tail, written by the IRQ handler and drained in task context
  with the `cli`-around-the-test discipline `shellMain` already uses (`shell.dart:1626`);
* a **defined overflow rule with a visible counter** — drop, count, make the count readable;
* **a reset in `shellRecover`** (`shell.dart:1594`), because a queue not reset there survives a fault
  with stale contents;
* **raw events, not characters** — scancode and edge, translated at the consumer, *"an event queue that
  stores translated ASCII cannot ever support a shift key"*;
* **the ring-0 shell becomes a consumer of the queue**, or there are two input paths that disagree.

And the transport is **not a new syscall**. §2 of that document withdraws its own syscall-11 proposal
(*"My first proposal was a new syscall 11 carrying a fixed request and reply. It is withdrawn."*) in
favour of `open(":WSYS")` / `read` returning fixed-width event records and **0 when there are none**,
with the branch in `fileSysOpen` and never in `fatLookup`. Syscall 11 belongs to `fdwait`
(`blocking-and-threads.md`), and `README.md`'s second pre-code fix — the syscall registry — exists
because these two nearly collided.

**What that leaves for a shell specifically, and it is new design rather than a citation.**
`display-protocol.md` never proposes a userland shell, a terminal, a tty layer, line discipline or echo
— its ~30 uses of "shell" all mean the ring-0 one. So three things have to be decided here:

* **Echo.** Today the IRQ handler echoes. A userland shell must echo its own input, which means it must
  be able to write a character *without* `USER WRITE ` and without a forced newline (§1.4). **The raw
  console write is a shell blocker as much as a `cat` blocker.**
* **Who gets input when.** `display-protocol.md` §4.3 leaves this open as Q3 and leans toward the
  kernel keeping *"a notion of 'input goes here now', which is a small piece of policy in ring 0."* For
  a shell the minimum viable policy is one word: the owner row of the process that currently has the
  console, defaulting to the ring-0 monitor when nothing is resident. That is smaller than focus, and a
  compositor can supersede it later without changing it.
* **Ctrl-C.** There is no signal mechanism and `GAP-0140` records that *the only thing in this kernel
  that can stop a runaway is a quantum budget typed at the shell*. A userland shell that cannot
  interrupt its child is a shell that can be hung by its child. This is not a blocker for APP9 but it
  must be written into that milestone's known cost rather than found by a user.

### 2.4 Blocker two — there is no `exec`, and the right answer is not to build one

`GAP-0141`: *"A process still comes from exactly one place: `proc run`/`proc spin` and a disk LBA.
There is no way for a program to create one."* `GAP-0096` item 7: *"A process cannot create a process.
No `fork`, no `exec`, no `spawn."*

Neither `exec-format.md` nor `memory.md` designs, sizes or ladders it; `exec-format.md`'s only mention
of `fork` is in the pthreads row (*"MISSING entirely"*), and `memory.md`'s two mentions are about the
refcount *shape* a future COW would want (a byte-per-frame plane, 32 KB of `@bss`, *"take this the day
COW or `fork` arrives"*) and an open question that says plainly: *"Nobody has told me whether `fork` is
planned."*

**This document's recommendation: build `spawn`, not `exec`, and never build `fork`.**

*Why not `exec`.* `exec` replaces the caller's address space **while executing on it**. On this kernel
that means tearing down `[vmProgBase, vmProgEnd)` — including the stack the syscall frame is standing
on — from inside a syscall, which is precisely the unsoundness `blocking-and-threads.md` identifies for
parking inside a syscall (the frame sits below RSP0) and which `README.md`'s Tier 1 resolves by leaving
through the door a resident process needs anyway. `exec` is the same hazard with none of the payoff.

*Why not `fork`.* It needs COW, which needs a refcount plane, which `memory.md` §2.4 correctly declines
to build for an OS with four process slots and no workload. And a shell does not need it: `fork` exists
in Unix so that a shell can set up a child's descriptors between the fork and the exec, and **this OS
has nothing to set up** — no inherited descriptors (GAP-0122 item 5: *"There is no `fork` and no `exec`,
so there is nothing for a descriptor to be inherited by. `proc run` gives a new process an EMPTY row"*),
no environment (GAP-0146), no redirection.

*What `spawn` is.* One syscall:

```
spawn(namePtr, argvPtr) -> slot, or a refusal
```

and it is **`procCreate` with three pieces bolted on that already exist separately**:

| piece | where it already is |
|---|---|
| resolve an 8.3 name to a chain | `fatOpenAt`, used by `run <name>` today (`elf.dart:1810`) |
| load the ELF from a file rather than an LBA | `elfLoadFile`, used by `shellElfLoadAndEnter(_, 1)` |
| build the initial stack | `argsBuild` (`args.dart:526`), used by `run` today |
| allocate a slot, install CR3, `heapInit` | `procCreate` (`proc.dart:1780,1856`) |

**Nothing in that list has to be invented.** The work is the seam: `procCreate` takes an LBA, `run`
takes a name, and the two paths have never met. Closing GAP-0149 is the same seam from the other side —
which is why §6 makes **APP5** a prerequisite of **APP7** rather than a separate idea.

*The refusals `spawn` needs, because they are the interface:* no free slot (`procErrNoSlot` — four
slots, GAP-0096 item 1); the name did not resolve; the image was refused (any of the loader's 25 named
refusals); the argument vector exceeded `argsMaxCount`/`argsMaxBytes`; **and a caller that is not itself
a process** — because a `run` program has no slot to be a parent (§1.1).

### 2.5 Blocker three, which no document names as a shell blocker — the shell must be resident

A shell that exits after each command is not a shell. On this machine that is not a figure of speech:

* `display-protocol.md` D3: *"the shell does not get the CPU back until the whole session tears down."*
* `display-protocol.md` D3 consequence 5: `shellProcRun` *"creates exactly two processes, refuses
  `lbaA == lbaB`, refuses to start while anything is live, and wipes all four slots at each start.
  **There is no single-program form at all.**"*
* `elf.dart:1830-1837`: a second `run` while anything is live is `elfErrLive`.
* `GAP-0141`: nothing blocks, so there is no `wait`.

So a userland shell needs **(a)** to exist while its child runs, which is `display-protocol.md` D3 —
and D3 *is* `blocking-and-threads.md` B1, asserted as an identity rather than a dependency: *"Whoever
builds either one has built both; they should not be scheduled as two units"* — and **(b)** to be told
when the child is finished, which is `wait`, which needs the blocked state B1 provides. **`waitpid` is
free once B1 exists and impossible before it.**

That D3/B1 is *also* what a compositor needs, and *also* what a display server needs, is why
`README.md` puts it in Tier 1 and calls it *"the milestone that should be built first of all of
these."* This document adds one more constituency to it and changes nothing about the ordering.

### 2.6 Sizing it

**Four structural kernel milestones and one small userland program.** In dependency order, with the
sibling milestone each one *is*, so that nobody builds it twice:

| # | what | = which sibling milestone | cost |
|---|---|---|---|
| 1 | a resident process + a blocked state | **D3 ≡ B1** — already Tier 1 in `README.md` | the corpus's largest uncosted item; moves `m3-shell`'s `ticks` golden (IRQ0 stays unmasked) |
| 2 | an input queue ring 3 can read | **D2** | *"Blocked on: work only, but it collides with the argv unit — sequence it after argv lands"* |
| 3 | `argv` and a heap in the same program | **new — APP5**, closing GAP-0149 | small; moves `m11-proc` and `m18-preempt` goldens |
| 4 | `spawn` + `wait` | **new — APP7, APP8**; `wait` is free given (1) | one syscall each; every part already exists (§2.4) |
| 5 | the shell program itself | **APP9** | a few hundred lines of C, and the smallest item on this list |

**Plus two things that are not milestones and will be found anyway:** a raw console write (§1.4), and a
policy word for who owns input (§2.3). Both are small; both are currently nobody's.

**The honest headline: the shell is four kernel milestones away, three of which are already on other
people's ladders for other reasons, and the shell itself is the cheap part.** That is a better position
than it sounds — but it means **nobody should start by writing the shell**, and it means APP1–APP5 below
are all more valuable per unit of work than APP9.

---

## 3. THE TIER LIST

Nine programs, each with what it needs and which gap blocks it. Ordered by how much kernel has to exist
first, not by how useful the program is.

### Tier 0 — writable today, no kernel change at all

| program | needs | status |
|---|---|---|
| **`cp SRC DST`** | `argv`, 2 descriptors, one 512-byte `.bss` buffer | **Nothing missing.** §1.3. Adds a capability the kernel lacks. |
| **`wc FILE`** | `argv`, 1 descriptor, `%d` | **Nothing missing.** Host-derivable answer. |
| **`hexdump FILE`** | as `wc`, plus a nibble table | **Nothing missing**, but `%02x` is `%!` — the program pays for `printf` (`libc-roadmap.md` L4). |
| **`head -n FILE`** | as `wc` | **Nothing missing.** (`tail` is tier 1 — it needs a size.) |
| **`cmp A B`** | 2 descriptors, 2 buffers | **Nothing missing.** The natural companion to `cp`, and the natural in-guest half of APP1's check. |
| **`cat FILE`** | — | **Writable and strictly worse than the ring-0 `cat`.** Blocked on a raw console write, not on files. §1.4. |

### Tier 1 — one named kernel gap each

| program | blocked by | what closes it |
|---|---|---|
| **`ls`** | **GAP-0122 item 2** — no `opendir`, no `readdir`, *"no way for a program to enumerate the volume at all — the shell's `ls` is ring-0 code and is not reachable from ring 3"* | Either a `readdir` syscall returning fixed-width records, **or** — better — `namespace.md`'s device branch in `fileSysOpen`: `open(":ROOT")` and `read` it as fixed-width records. **Zero new syscalls**, reuses the validator, and the sigil argument is already settled (`:`, not `/`). |
| **`stat`, `ls -l`, `tail`, `du`** | **GAP-0122 item 3** — no `stat`/`fstat`, so no way to ask a file's size | One syscall returning a number, not a struct — which is what GAP-0122 item 3 says was the reason it was skipped, and the reason to do it that way now. `libc-roadmap.md` §8 calls this *"the highest value-per-line kernel item in this whole document and it is not currently on any roadmap"*: it unblocks `SEEK_END`, `stdio`'s buffering decisions, and any libc port at all. |
| **`rm`, `mv`** | **GAP-0127 item 3** — no `unlink`, no `rename`, no `mkdir`, no `rmdir` | *"Marking a directory entry 0xE5 and freeing its chain is twenty lines"*, and `m16-filewrite`'s volume already carries a deleted entry the kernel **reuses** — *"the half of the mechanism that is built"*. `rename` additionally unlocks GAP-0127 item 8 and therefore every safe save. |
| **`sort`, `uniq`, `grep`** | `argv` + a heap, which no program can have together — **§1.1 / GAP-0149** | APP5. Or write them against a `.bss` buffer today and accept a fixed capacity, which is a legitimate choice on a machine with a 2 MiB address space. |

### Tier 2 — a text editor

**Five gaps, and the interesting one is not the one people expect.**

| it needs | blocked by |
|---|---|
| to read keys | GAP-0122 item 7; `display-protocol.md` **D2** |
| a **raw** terminal — no echo, no line discipline | undecided; `libc-roadmap.md` §2.1: *"this kernel's keyboard belongs to the ring-0 shell entirely. That is a bigger decision than a syscall: it is deciding who owns the console."* |
| a cursor and scrolling | `text.md` §5.2 items 2 and 3; GAP-0070 items 1 and 5 |
| a buffer, therefore a heap, therefore `argv`-and-heap | **§1.1 / GAP-0149** → APP5 |
| `setjmp`/`longjmp` for its error path | `libc-roadmap.md` tier A / **L8** (~40 lines) |
| **to save without destroying the file it is editing** | **GAP-0127 items 1, 2, 8** |

**That last row is the one that matters and it is usually missed.** `libc-roadmap.md` §2.1 states it
exactly: *"today `O_WRITE` is create+truncate+append-only, so an editor **cannot save over a file** — it
can only write a new one."* And GAP-0127 item 8 completes the trap: with no `rename`, *"'write a new
version and swap it in' is not expressible."* So the sequence "user presses save, machine loses power
one second later" **loses the file**, not the edit.

**The fix is `rename` (twenty lines, tier 1), not a general write-at-offset path (a milestone).** An
editor that writes `FOO.TMP` and renames it over `FOO.TXT` is safe on an append-only filesystem. This
should be stated in GAP-0127 itself: item 3 is currently ranked below item 1, and for applications it
is the more valuable of the two by a wide margin.

Honest verdict: **the editor is not the next thing to build.** It sits behind D2, B1/D3, APP5 and `rename`,
and every one of those is more useful on its own than the editor is.

### Tier 3 — a shell

§2. Four kernel milestones (D3≡B1, D2, APP5, spawn+wait), then a few hundred lines of C. And the
classification in §2.1 means the deliverable is not "shell.dart is deleted" but "seven arms move out,
thirty-three become device files, eight disappear into a tokeniser."

### Tier 4 — an assembler

The cheapest path to *anything* being built on the machine: text in, bytes out, no floating point, no
`libm`, no `strtod`.

| it needs | status |
|---|---|
| `argv`, `read`, `create`/`fdwrite` | **have** |
| a symbol table | `.bss` today (fixed capacity), or a heap after APP5 |
| two passes over the source | **have** — `seek` is absolute and re-reading is legal |
| **to backpatch a forward reference** | **BLOCKED.** A write descriptor is append-only and `seek` on it is `FILE_EBADMODE` (GAP-0127 items 1, 2). |
| to emit something `run` will load | see below |

**The backpatch problem is the whole milestone**, and it has exactly two solutions: buffer the entire
output in memory and write it once (works today, bounded by the address space — a 2 MiB window means a
64 KiB program's object file fits comfortably), or write at an offset (`exec-format.md` **X5**). **The
first works now.** An assembler for this machine should be written output-buffered on purpose, and the
buffer size becomes a documented limit rather than a bug.

**What it must emit.** `run <name>` reads a FAT file and calls `elfLoadFile` — the `OSCXPRG1` header
sector (`elfHeaderMagic`, `elf.dart:757`) is on the **`run <lba>`** path only. So an assembler must emit
a plain `ET_EXEC` ELF with at most 16 program headers, all within the first 4096 bytes, obeying **W^X**
(`elfErrWx` is a named refusal, not a warning), under 65,536 bytes, and it must be a *linker* too, since
there is nothing to link with. That is a real constraint but a bounded one, and `exec-format.md`'s 25
named refusals mean every way of getting it wrong has a sentence attached.

### Tier 5 — a C compiler

`libc-roadmap.md` tier B, and its verdict should be quoted rather than paraphrased: **"Tier B is an
ELF-and-filesystem milestone wearing a libc costume, and the honest ordering is that tier B should be
attempted *after* the address space is fixed, not before."**

| it needs | size |
|---|---|
| libc tier B | ~120–150 symbols; **+2 syscalls** (`getcwd`, `chdir`) *and only if tcc is the target* |
| `strtod` | *"a C compiler must parse floating literals"* — `libc-roadmap.md` §3.3 puts it at tier **B**, one tier earlier than most people expect. ~900 lines imported from musl. |
| subdirectories and paths | `#include <sys/types.h>` has nowhere to come from on a root-only 8.3 volume |
| **32 descriptors** | four today; *"a compiler with 20 nested includes open"* |
| **a stack bigger than one page** | `exec-format.md` **X3** |
| **an image bigger than 64 KiB** | `exec-format.md` **X1** — chibicc is ~9k lines; tcc is ~60k with its own assembler and linker, *"so it needs no `exec`"* |
| **several MiB of address space** | `exec-format.md` **X2** / `memory.md` **MEM-1** — *"tcc's own working set is a few MiB before it compiles anything"* |
| `exec` + `wait`, if chibicc | it shells out to `as`/`ld`. **tcc does not** — which makes tcc the better target for *this* machine despite being 7× the source. |

---

## 4. SELF-HOSTING

### 4.1 The question has to be split, because one half of it is not a milestone

**"Build this OS on itself" means building `kernel.elf`.** `kernel.elf` is DCDart, compiled by `dcc`,
which is **a Dart program that requires exactly Dart 3.12.2** — `README.md`'s environment-trap section
records that 3.11.0 and a 3.13.0-dev Flutter SDK both fail, differently. Self-hosting the kernel
therefore means **running a Dart SDK on oscortex**: a JIT or AOT runtime, a garbage collector, threads,
`mmap`, sockets for the analysis server, and a filesystem with directories. `libc-roadmap.md` puts a
GTK-class port at *"700–900 symbols, ~20 syscalls, do not attempt"* and calls it *"not a libc port, it
is a Linux personality"*; a Dart SDK is above that line, not below it.

**So the answer to "can this OS build itself" is no, and it is no for a reason that has nothing to do
with this OS's quality.** The kernel is cross-built from macOS and should be, permanently, unless
DCDart itself gains a native self-hosting story — which `README.md` already assigns to the DCDart repo
(*"the compiler question comes first and belongs to the DCDart repo"*).

**The reachable goal, which is worth having and should be named differently so the two never get
confused: *the machine can build a program that runs on it*.** Call it **in-guest development**. It is
the thing tier B is really about, it is what `libc-roadmap.md` means by *"The OS can build a program
without a macOS host in the loop. This is the tier that changes what the project is"*, and it is
achievable.

### 4.2 What in-guest development actually costs

Six caps, in the order they bite. **Five of the six are kernel, and none of them is a compiler
problem.**

| # | cap | today | needed | milestone |
|---|---|---|---|---|
| 1 | **stack** | **4096 bytes, one page** | tens of KiB — a recursive-descent parser recurses once per level of expression nesting, and `exec-format.md` calls a too-small stack *"the most likely silent failure on this list"* | **X3** |
| 2 | **image** | **65,536 bytes** | chibicc at `-O2` is well past it; tcc is several hundred KiB | **X1** |
| 3 | **address space** | **2 MiB total**, code + data + heap + stack | several MiB before compiling anything | **X2 / MEM-1** (`vmUserEnd = 0x14000000`, 64 MiB, as a *second region* — `memory.md` is explicit that widening `vmProgEnd` in place *"is strictly more expensive and buys nothing"* and keeps 47 goldens still) |
| 4 | **file size** | **262,144 bytes** (`fatChainMax`) | the compiler binary itself, and every source file it reads | storage / FAT |
| 5 | **names** | **8.3, root only, no path** | an include tree | `namespace.md` + storage; `libc-roadmap.md`: *"or the shell can never `cd`"* |
| 6 | **`argv` and a heap together** | **impossible** (§1.1) | obviously required | **APP5** |

Plus three that are ordinary work: `unlink` (a compiler makes temporaries and must remove them),
`rename` (atomic output replacement), and **32 descriptors** where there are four.

And only then the libc: `libc-roadmap.md`'s **L3** (`string.h`, `ctype.h`, the integer half of
`stdlib.h` — ~50 symbols, 0 syscalls), **L4** (`stdio`, `FILE`, three streams, the integer `printf`
engine — ~35 symbols, ~3 syscalls, *"~2100 lines, of which ~500 should be imported. Call it three
milestones"*), and **L5**'s `strtod`.

### 4.3 The honest number

**Twelve to eighteen milestones, of which nine or ten are kernel.** Reading the ladders as they stand:
X1, X2/MEM-1, X3, X5, APP5, `unlink`+`rename`, descriptors 4→32, subdirectories, L3, L4, L5, then an
assembler, then a compiler. At `README.md`'s measured 3–4 milestones/day *when integration keeps up*
that is not long in wall clock — **and `README.md`'s own warning applies twice here, because ten of
these touch `elf.dart`, `vm.dart`, `file.dart` and `fat.dart`, which is exactly the hot-file
contention `hot-files.md` is about.** This is the least parallelisable ladder in the corpus.

**The ordering advice, which is the useful part.** Do **not** start with the compiler, and do not start
with the libc. Start with X3 and X1 — a bigger stack and a bigger image — because *every* item in tiers
3, 4 and 5 sits behind them, they move no goldens that a derived harness cannot re-derive, and they are
the two cheapest entries on `exec-format.md`'s ladder. Then APP5, because it is small and it deletes an
entire class of "why does `malloc` return `NULL`" confusion. **The assembler before the compiler**, not
because anyone needs an assembler, but because it is the smallest program that proves the whole
pipeline — file in, file out, and the output runs — and it needs no floating point, no `libm` and no
`strtod`.

---

## 5. WHAT THIS OS SHOULD NEVER GROW, AND WHAT IT EVENTUALLY MUST

### 5.1 Never

| never | why |
|---|---|
| **`fork`** | §2.4. It exists so a shell can set up a child between fork and exec, and there is nothing here to set up: no inherited descriptors (GAP-0122 item 5), no environment (GAP-0146), no redirection. It costs COW, which costs a refcount plane `memory.md` §2.4 correctly declines to build. |
| **`exec` (replace-in-place)** | §2.4. Tears down the address space the syscall frame stands on. `spawn` is strictly smaller and strictly safer. |
| **A POSIX signal implementation** | `libc-roadmap.md` sizes real signals at *"~200 lines + ~6 syscalls (+800 kernel)"*. Stubs are ~30 lines and are what tier A actually needs. |
| **`errno`, as a global set by everything** | GAP-0122 item 6's argument is right and this document does not reopen it. `libc-roadmap.md` **L2** puts an `errno` behind the *library*, mapping the kernel's own refusals; the kernel keeps returning them. |
| **An environment** | GAP-0146. A `getenv` with nothing to get is a convention pretending to be an interface. Add it the day there is a second thing that reads it. |
| **Job control, process groups, terminals as objects** | Four process slots. There is no third job to control. |
| **A dynamic linker, before X10** | `exec-format.md` X11 is gated on `mmap`, and X10 (shared read-only text) delivers most of the benefit with none of the resolver. |
| **Shell scripting with a real language** | Whatever it is, it will be written before there is a `for` loop's worth of programs to iterate over. |

### 5.2 Eventually must, ordered by when each becomes the thing in the way

1. **`argv` and a heap in one program** (APP5). Today's answer to "why is my `malloc` NULL" is a table in
   a design document, which is the wrong place for it.
2. **A file's size** — one syscall, and `libc-roadmap.md` §8 already calls it the highest
   value-per-line kernel item in that whole document.
3. **`unlink` and `rename`** — twenty lines that make saving a file safe.
4. **Directory enumeration**, because `ls` is not optional on a usable OS.
5. **A raw console write**, because `cat`, `hexdump`, an editor and a shell all need to put a byte on
   the screen without `USER WRITE ` in front of it.
6. **The input queue** (D2) and **the resident process** (D3 ≡ B1).
7. **A bigger stack** (X3) — the first thing that breaks silently rather than loudly.
8. **`spawn` and `wait`.**
9. **Paths and subdirectories.** Every tier-B item waits behind this and it is a storage milestone.
10. **`printf` with widths**, because `%02x` is where every program that formats anything gives up.

---

## 6. THE MILESTONE LADDER

Milestones are numbered **APP**, a multi-letter prefix chosen because every single letter this ladder
would naturally have taken is already claimed, `A` included (§ "four findings"). Each criterion follows this repo's rules for a derived expectation — compute the expectation from a
source the kernel does not control, restate the kernel's constants in the harness and assert them
against the kernel's source, guard against a vacuous pass, and carry a negative control that must fail.

**Ordered by usefulness per unit of work, which is not the same as dependency order.** APP1 and APP2 depend
on nothing.

---

### APP1 — Two programs exist that the kernel cannot be

**Blocked on: nothing.** Harness `m20-userprogs`. Touches no kernel file at all — which is the point:
it is the first milestone in this project's history whose deliverable is entirely in `core/user/`.

Build `CP.ELF` and `WC.ELF` against `core/user/libc`, place them on the volume beside a text file the
host generated, and run them.

*Binary:* with `ALPHA.TXT` on the volume and `BETA.TXT` **asserted absent by `make-image.py`**,
`run CP.ELF ALPHA.TXT BETA.TXT` then `run WC.ELF BETA.TXT` produces on COM1 a byte count, a line count
and a word count **equal to the values `derive.py` computed from `ALPHA.TXT` on the host**; and after
the boot, `BETA.TXT` extracted from the image by **`fsck_msdos` plus macOS's own `msdos` driver**
(M16's method, not this kernel reading back its own writes) is **byte-identical to `ALPHA.TXT`**, and
`fsck_msdos` reports the volume clean.

*Anti-vacuity:* the check fails if `ALPHA.TXT` is empty, if its length is a multiple of 512, or if it
is smaller than 512 bytes — all three would let a wrong copy loop pass. And `CP.ELF` carries a `.bss`
buffer of at least 64 KiB, of which it touches the first and last byte, so **§1.1's `.bss` claim is
measured by this milestone rather than assumed.**

*Negative control:* a second build of `CP.ELF` whose loop passes `sizeof buf` to `fdwrite` instead of
the count `read` returned must produce a `BETA.TXT` that differs from `ALPHA.TXT`, and the harness must
fail on it. (This is `m15-fileio`'s and `m16-filewrite`'s own negative-control pattern, applied to a
program that is meant to be kept.)

*Also proves, incidentally:* that `run` passes `argv` to a program built from `start.c` (M19, from the
application side rather than the kernel side), and that a program may hold two descriptors of four.

---

### APP2 — A program can ask how big a file is

**Blocked on: nothing.** Harness `m21-filesize`. One new syscall — **and the syscall registry
(`README.md` fix 2) must exist first**, because `fdwait` has already claimed 11 and this is the third
document to want a number.

Return a **number, not a struct.** GAP-0122 item 3 says a `stat` worth having returns a structure and
that copying one out to ring 3 is the pointer-validation problem `read` already solved. That reasoning
is right and it is also the reason to ship the number now: one `u64` in RAX needs no validator, no ABI
and no versioning, and `SEEK_END` — the thing everyone actually wants — needs nothing more.

*Binary:* a program prints the size of **five** files whose sizes were chosen by `make-image.py` — one
empty, one under a cluster, one exactly one cluster, one spanning a FAT-sector boundary, one at
`fatChainMax` — and every value equals the FAT directory entry as read on the **host** by a tool this
kernel did not write. The empty file reports **0** and not a refusal (`FILE_EEMPTY` is what `open`
returns for it today, so this milestone must decide and state which call answers for a zero-length
file). A 13-character name is `FILE_EBADLEN`; a fifth open is `FILE_ENOSLOT`.

*Anti-vacuity:* the five sizes must be pairwise distinct and at least one must exceed 65,536, so a
build that returns a constant cannot pass.

*Negative control:* a build that returns the descriptor's current **offset** instead of its size passes
trivially on a freshly opened file and must fail on a file the program has already read half of — so
the program must read half of one of the five before asking.

*Unblocks:* `SEEK_END`, `stdio`'s buffering decisions, `ls -l`, `tail`, and — per `libc-roadmap.md` §8
— *any libc port at all*.

---

### APP3 — `ls` is a program

**Blocked on: `namespace.md`'s device branch (its N1), which is where the `:` sigil is decided.**
Harness `m22-readdir`.

Take `namespace.md`'s spelling, not a new syscall: the branch goes in **`fileSysOpen`** and **never** in
`fatLookup` — that document calls a `fatLookup` branch *"a ring-3-reachable volume corruption"*, and it
is right. `open(":ROOT")` yields a read descriptor over fixed-width records; `read` returns whole
records and 0 at the end, exactly as it does for a file. **Zero new syscalls, zero new validators, and
one of `fileMaxFds` while it is open.**

*Binary:* `run LS.ELF` prints exactly the names that `mdir` (or `fsck_msdos`'s listing) reports on the
host, in directory order. The volume is built to contain, in this order: a normal file, **a deleted
entry** (which must **not** appear), a zero-length file (which **must**), a subdirectory (which must
appear and be marked as one), and a name using every legal 8.3 character class.

*Anti-vacuity:* the expected listing must have at least five entries and at least one non-appearing
entry, so a program that prints nothing, or prints everything, fails.

*Negative control:* a build whose record loop stops one record early must fail; and a build that
branches in `fatLookup` instead of `fileSysOpen` must fail a structural grep, before boot.

---

### APP4 — A file can be removed and renamed, and a save is therefore safe

**Blocked on: work only.** Harness `m23-unlink`. GAP-0127 item 3's own estimate is twenty lines, and
`m16-filewrite`'s volume already carries a deleted entry that this kernel **reuses**, so half the
mechanism is built and tested.

*Binary:* four sequences, each ending with `fsck_msdos` reporting the volume clean and macOS's `msdos`
driver reading it: **(a)** create a two-cluster file, `unlink` it, create another and confirm the
**same clusters** are reused (the free-count before and after are equal, derived); **(b)** `rename` over
an existing name and confirm the old chain is freed and the new name resolves to the new chain;
**(c)** the atomic-save idiom — write `X.TMP`, `rename` it over `X.TXT` — leaves `X.TXT` with the new
contents and **no `X.TMP`**; **(d)** `unlink` of a subdirectory is refused **by name**, and `rename`
onto a subdirectory is refused by name.

*Anti-vacuity:* (a) fails if the file is one cluster (a single-cluster reuse can happen by luck).

*Negative control:* a build that marks the directory entry `0xE5` but does not free the chain must fail
`fsck_msdos`, which will report a lost chain — proving the check is sensitive to the FAT update and not
only to the directory update.

---

### APP5 — One program has both a command line and a heap

**Blocked on: work only.** Harness `m24-argvheap`. Closes **GAP-0149** and §1.1 together.

Two spellings, and this document recommends the second: **(i)** `procCreate` calls `argsBuild` and
`proc run` grows a name form — which is what GAP-0149 itself proposes; or **(ii)** **`run <name>` stops
using the `elfLive` path and creates a process slot**, which deletes the two-doors split entirely
rather than papering over it, makes `fileRunRow` unnecessary, and makes `yield` and `preempts` reachable
from a `run` program as a side effect. (ii) is more disruptive and is the right shape.

*Cost, named:* `m11-proc`'s and `m18-preempt`'s goldens move — GAP-0149 predicts exactly which line
(`PROC START SLOT 00 ENTRY ... RSP 0000000010200000`) — and both harnesses' programs are hand-written
assembly that never reads `(%rsp)`, so they must gain a zero-argument block or an explicit exemption.
Under (ii), `fileRunRow`'s equality with `procMax` — which `file.dart:288` says is asserted by a harness
rather than left as a coincidence — is either deleted or restated.

*Binary:* **one** program, started **one** way, is given three arguments, `malloc`s a block, frees it,
`malloc`s a block of the same size, and gets **the same address back** — the address being one
`derive.py` computed from the allocator's exported constants and the program's own `elfMetaHi`, exactly
as `m13-libc` already does. It then prints `argv[2]`, and the harness passes two different values on two
boots and requires two different transcripts.

*Anti-vacuity:* the two boots' argument strings must differ in length as well as content, so a program
that prints a constant cannot pass.

*Negative control:* a build in which `run` still enters through `elf.dart:1939` must fail the `malloc`
assertion with `sbrk` refused — proving the test is sensitive to the door and not to the allocator.

---

### APP6 — Input is a queue and a program can read a key

**This is `display-protocol.md` D2 and is not restated here.** Its specification is §4.2 of that
document, its exit criterion is D2's, and this ladder adds only one requirement to it: **the records
`read(":WSYS")` returns must be readable by a program built from `core/user/libc` with no new library
function beyond a struct definition** — because the first consumer of this queue will be APP9's shell,
and an event format that needs a parser is an event format that will get two parsers.

*Sequencing note from that document, repeated because it matters here:* *"Blocked on: work only, but it
collides with the argv unit — sequence it after argv lands."* Argv has landed (M19).

---

### APP7 — A program can start a program

**Blocked on: APP5, and on the syscall registry.** Harness `m25-spawn`. §2.4 is the specification: one
syscall, `spawn(name, argv) -> slot`, assembled from `fatOpenAt` + `elfLoadFile` + `argsBuild` +
`procCreate`, all four of which exist and none of which currently meets the others.

*Binary:* a parent program spawns a child by **name**, passing two arguments; the child writes a file
whose contents are derived from those arguments; the parent exits immediately; the shell reports both
exits; and the file on the volume, read by the host, matches the derived contents. Then the parent
spawns until refused and the refusal is **`procErrNoSlot` by name** at exactly the fifth process
(GAP-0096 item 1's four slots, asserted against `proc.dart`). Then a `run`-door program (if door (ii)
of APP5 was not taken) spawning anything is refused **by its own named code**, because it has no slot to
be a parent.

*Anti-vacuity:* the child's output must depend on **both** arguments, so a `spawn` that drops `argv`
past the first cannot pass.

*Negative control:* a build whose `spawn` passes the name as `argv[0]` but no further arguments must
fail — the same class of check `m19-argv` already makes for `run`.

---

### APP8 — A program can wait for the program it started

**Blocked on: APP7 and on `blocking-and-threads.md` B1 (≡ `display-protocol.md` D3).** Harness
`m26-wait`. Given B1, this is one syscall and a state transition; before B1 it is impossible, and the
temporary form is `display-protocol.md` §2.2's non-blocking poll plus `yield` — *"the correct answer for
this OS and not a workaround"* — which APP9 may ship against and must not depend on forever.

*Binary:* a parent spawns a child that runs for a **measured** number of quanta, waits for it, and
prints the child's exit status; the status is one `derive.py` computed; and `proc sched`'s per-slot
preempt counter shows the **parent accumulated no quanta while blocked** — which is the difference
between waiting and spinning, and is the only assertion that distinguishes them.

*Negative control:* a build in which `wait` is a `yield` loop must fail the preempt-counter assertion
while passing the exit-status one.

---

### APP9 — The shell is a program

**Blocked on: APP6, APP7, APP8, and a raw console write.** Harness `m27-usershell`.

Deliverable: `SH.ELF`, resident, reading `:WSYS`, echoing its own input, tokenising with quoting,
spawning by name, waiting, and reporting exit status. **Plus the split of `shell.dart` described in
§2.1**: the seven shell arms move out, the eight usage arms disappear into the tokeniser, and the
thirty-three kernel arms stay exactly where they are and remain reachable — the ring-0 monitor is the
recovery console and is not deleted by this milestone or any later one.

*Binary:* the harness injects, as keystrokes, a session that **the ring-0 shell could not have run**:
`cp ALPHA.TXT BETA.TXT` then `wc BETA.TXT` then `ls`, with a quoted argument containing a space, and
COM1 carries exactly the derived transcript. Then, **while `SH.ELF` is still resident**, the harness
proves the ring-0 monitor still works by a route the shell does not own, and `proc sched` shows
`SH.ELF`'s preempt counter strictly greater afterwards — D3's own criterion, inherited.

*Anti-vacuity:* the session must include at least one command whose output depends on a **quoted**
argument, so a tokeniser that splits on spaces alone cannot pass.

*Negative control:* a build in which `SH.ELF` exits after its first command must fail the residency
assertion.

*Known cost, written into the milestone rather than discovered:* there is no `Ctrl-C` and no signal
mechanism (GAP-0140), so this shell can be hung by its child, and the only remedy is the quantum budget
typed at the ring-0 monitor. That is acceptable and it must be documented in `help`.

---

### APP10 — Something is built on the machine

**Blocked on: X1, X3, and APP5.** Harness `m28-assembler`. The capstone that is actually reachable; the
compiler is not, and §4.1 says why.

*Binary:* `AS.ELF`, running on the guest, reads a `.s` file from the volume and writes an `ET_EXEC`
ELF; `run` loads that ELF and it exits with a status `derive.py` computed from the assembly source; and
the emitted ELF, extracted to the host, is **byte-identical to what the host's `clang -c` + `ld`
produce from the same source** (or, if that is too strong for a first assembler, produces byte-identical
`.text` under `objcopy -O binary`, with the difference in ELF metadata enumerated and each item
explained).

*Anti-vacuity:* the source must contain at least one **forward** reference, so an assembler that cannot
backpatch cannot pass — which is the constraint §3 tier 4 identifies as the whole milestone.

*Negative control:* a build whose output buffer is one byte short must fail, proving the emitted length
is checked and not merely the prefix.

---

### Capstone, with no binary criterion — a C compiler on the machine

Stated precisely so that it is not attempted. `libc-roadmap.md` tier B is ~120–150 libc symbols and
*"Tier B is an ELF-and-filesystem milestone wearing a libc costume"*; §4.2's six caps are all kernel;
`exec-format.md`'s X1, X2 and X3 are all prerequisites. **This entry exists to say so precisely rather
than to be attempted**, which is the form `libc-roadmap.md`'s own ffmpeg capstone takes and the right
form for this one.

---

## 7. WHAT I DID NOT DECIDE, AND WOULD RATHER BE TOLD

1. **Is in-guest development (§4.1) a goal at all, or is cross-compiling from macOS permanent?**
   `libc-roadmap.md` §7 asks the same question and says the answer *"changes L3's and L4's priority
   substantially"*. It changes this ladder more: if the answer is "permanent", APP10 and everything in
   tier 5 comes off, and APP1–APP9 are the whole document.
2. **Who owns the console when there is no compositor?** `display-protocol.md` Q3 leaves it open and
   leans toward the kernel keeping a policy word. A shell needs the same word for a different reason
   (§2.3). **It should be decided once, by an owner, and it is one word of `@bss`.**
3. **`spawn` or `exec`?** §2.4 argues for `spawn` and I am confident about it, but it is a decision
   with a long tail — every program ever written for this OS inherits it — and it is the kind of thing
   `CLAUDE.md`'s escalation rule is about ("memory layout that userland will eventually depend on").
4. **Should `run` become `proc`'s door (APP5 option (ii)) or should `proc run` grow a name form (option
   (i))?** (ii) is architecturally right and moves more goldens. GAP-0149 proposes (i). I recommend
   (ii) and would not overrule the person who has to move the goldens.
5. **What is the record format for `:ROOT` and `:WSYS`?** Both want fixed-width records read through
   the existing `read`. Whether they share a record header — so that one program can read either — is a
   `namespace.md` question I am not qualified to close, but the answer should be the same for both.
6. **Does a zero-length file have a size or a refusal?** Today `open` on one is `FILE_EEMPTY`
   (`file.dart:457`) — a legal FAT file this kernel refuses to open. APP2 has to decide whether the size
   call answers 0 for a file `open` will not open, which is a small inconsistency with a real
   consequence for `ls` and for any libc port.

---

## 8. NOTES FOR THE COORDINATOR TO FOLD IN ELSEWHERE

* **Two more milestone-prefix collisions, and a recommendation.** `text.md` uses **T1–T8**;
  `time-and-power.md` uses **T1–T3**. `arm64-port.md` uses **A0–A…**, which collided with this
  document's first draft mid-session. `README.md` names the `N` collision across three documents and
  names neither of these. **Single-letter prefixes are exhausted**: `A B D G L N P S T X` are all
  taken, three of them twice. This ladder is `APP1`–`APP10`, and the recommendation is that every
  future ladder use a multi-letter prefix — `MEM` is the only existing one that does and the only one
  that has never collided.
* **A new entry for `known-gaps.md`, and it is the finding of §1.1.** *No program on this operating
  system can have both `argv` and a heap.* GAP-0149 records one half (a `start.c` program started by
  `proc run` page-faults); nothing records the other half (a program started by `run` has `sbrk`
  refused, so `malloc` returns `NULL` unconditionally). It deserves its own number, it belongs beside
  GAP-0149, and its closer is **APP5**.
* **GAP-0127's items 1 and 3 are ranked backwards for applications.** Item 1 (append-only writes) is
  correctly described as *"the single largest thing M16 did not build"* from the kernel's point of
  view. From an application's, **item 3 (`unlink`/`rename`) is worth more per line by a wide margin**,
  because it is what makes saving a file safe (item 8), and item 3's own estimate is twenty lines
  against item 1's milestone. A sentence to that effect in GAP-0127 would change what somebody builds
  next.
* **`libc-roadmap.md` §8's `_fstat` note and this document's APP2 are the same milestone.** That document
  calls it *"the highest value-per-line kernel item in this whole document and it is not currently on
  any roadmap."* It is on this one, as **APP2**, and it should be counted once.
* **`display-protocol.md` D2 and this document's APP6 are the same milestone.** Counted once. The only
  thing APP6 adds is a constraint on the record format.
* **`display-protocol.md` D3 ≡ `blocking-and-threads.md` B1 gains a third constituency.** Those two
  documents already assert the identity. A userland shell is the third thing that cannot exist without
  it, after the compositor and the resident process. **It does not change the ordering; it strengthens
  `README.md`'s existing recommendation that it be built first.**
* **A raw console write is nobody's milestone and three tiers need it.** `cat` (§1.4), an editor
  (§3 tier 2) and the shell's echo (§2.3) all need to put a byte on the screen without `USER WRITE `
  and without a forced newline. It is small, it moves whatever goldens print `USER WRITE`, and it
  should be assigned rather than discovered three times.
* **The count in `README.md` moves.** This document adds **10** specified milestones (APP1–APP10) across a
  thirteenth ladder, and **three of them are identities with milestones already counted** (APP6 ≡ D2;
  APP2 ≡ `libc-roadmap.md` §8's `_fstat` item, which is not itself in that document's L-ladder; APP8's
  prerequisite is D3 ≡ B1). The honest increment to "97 milestones across 12 ladders" is **+9 across a
  13th**, and `applications` should come out of the "not yet specified" column.
