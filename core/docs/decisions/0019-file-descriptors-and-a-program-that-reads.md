# ADR-0019 — File descriptors, four syscalls, and a C program that reads a file. **Up to four files can be open at once, and the filesystem still holds exactly one cluster chain.**

**Status:** accepted, implemented, verified (`core/tests/conformance/m15-fileio/run.sh`)
**Date:** 2026-08-22
**Supersedes:** nothing. **Narrows:** GAP-0113 (see §9). **Unblocks:** nothing yet — see §10.

---

## 0. The one-sentence summary, put where a footnote would hide it

`fat.dart` holds **one** cluster chain and M15 did **not** make it hold more. What M15 does is store,
in every file descriptor, the two numbers a chain can be rebuilt from — the first cluster and the size
— so that any descriptor can re-select its own chain at the cost of one FAT walk. **Four files can be
open at once and read in any order**; the cost is that alternating between two of them rebuilds a
chain on every read, and the kernel prints the count so that cost is a number rather than a
disclaimer. `m15-fileio`'s program alternates twelve times and the kernel reports exactly 24 rebuilds,
which `derive.py` computes as `2 * ALTN`.

That is the whole of the design decision that was actually hard. Everything below is detail.

---

## 1. What was built

| Piece | Where | What |
|---|---|---|
| `open(namePtr, nameLen)` | syscall 5 | an 8.3 name in the ROOT directory → a descriptor 0..3 |
| `read(fd, buf, len)` | syscall 6 | up to 512 bytes at the descriptor's offset, which advances |
| `close(fd)` | syscall 7 | releases the descriptor; a second close is a refusal |
| `seek(fd, off)` | syscall 8 | absolute, and the only form |
| descriptor table | `file_store + 128` | 5 rows × 4 descriptors × 4 words |
| bounce buffer | `file_store + 768` | one sector; no user pointer ever names it |
| `open/read/close/seek` | `core/user/libc/syscall.c` | the raw wrappers |
| `RFILE`, `rfopen`/`rfread`/`rfgets`/`rfseek`/`rfclose` | `core/user/libc/rfile.c` | a buffered read-only file |

Donated `.bss`: **11488 → 12768** bytes (`file_store`, 1280). Declared externs: **59 → 60**
(`file_store_addr`). `shellStrHelp`: **2147 bytes, unchanged** — M15 adds no shell command, so none of
the five goldens that assert the help text moves.

---

## 2. Why `read` is the first syscall that needed a THIRD argument, and why there is still one `int $0x80`

`write(ptr, len)`, `sbrk(inc)`, `yield()`, `exit(code)` and `who()` all fit in two registers.
`read(fd, buf, len)` does not. m13-libc requires **exactly one `int $0x80` instruction in the whole
library** and it was right to: the three test programs before M13 each carried their own stub and
their own spelling of the syscall numbers, and a disagreement showed up as a program that faulted
rather than as a build error.

So the three-argument form became the real one and `sys_call` became a C call to it with a zero third
argument. RDX is caller-saved in the System V AMD64 ABI and `isr_common` saves all fifteen
general-purpose registers regardless, so a syscall that ignores its third argument is unaffected by
one being passed.

**This cost two goldens.** `syscall.o` grew, so m13-libc's and m14-fat's programs are a few bytes
bigger, so m13's heap base and m14's self-hash both moved, and both harnesses' `expected.txt` and
`expected-screen.txt` were regenerated. That is a real cost and it is recorded rather than absorbed:
GAP-0123 has the accounting. **It is safe** in exactly the way those two harnesses were built to make
it safe — every expectation in both is *derived* from the binaries and the volume, so `--regen`
enshrines a capture only if every derived check passes against it, which is why m14-fat's own header
documents the flag.

The alternative — a second `int $0x80` in a second file — was rejected: it would have made m13's
sentence false in substance while leaving its grep green, which is the worst of both.

**It also found a bug that had been green for two milestones.** `m14-fat/derive.py` formatted
`PROGB.ELF`'s expected exit status with `%02x` and `run.sh` greps the transcript for it literally,
while `uartPutHex` prints upper case — so the check only worked for a status whose two hex digits are
both decimal, which both programs' happened to be. Growing the library moved PROGB's status to `0x3E`
and the check failed against a capture that plainly contained it. One character; GAP-0125.

---

## 3. One 8.3 parser, two callers

M14's `fatParseName(from)` read the typed shell line a byte at a time through `shellLineByte`. `open`
needs the same grammar over a byte range that came from a ring-3 pointer. Two copies of an 8.3 parser
is two chances for `run PROGA.ELF` and `open("PROGA.ELF")` to disagree about what a name is — and the
disagreement would be silent, because a name that parses differently simply is not found.

So `fatParseAt(addr, len)` is now the parser and `fatParseName(from)` is a two-line wrapper over
`shellLineBase() + from`. `fatOpen(from)` splits the same way: `fatParseAt` + `fatLookup()`, where
`fatLookup` is the directory search that both callers share.

`m15-fileio` types `cat small.txt` at the shell in the same boot in which the program calls
`open("SMALL.TXT")`, and requires the shell's output to be the file byte-for-byte. The refactor is
checked by a boot, not by a grep.

---

## 4. Five descriptor rows, because only some things in ring 3 are processes

Two different things can be in ring 3 on this machine and only one of them is a process: `proc run`
creates one (slots 0..3, ADR-0015) and `run <name>` does not (ADR-0014). `sbrk` deals with this by
refusing unless a process is live — which is right for `sbrk`, whose heap lives in a process slot, and
would be wrong here, because `run <name>` is *the command that loads a program off the filesystem* and
a file API it could not use would be an odd thing to have built.

So the table has **five rows**: 0..3 are the process slots and row 4 is the `run <name>` program.
`fileOwnerRow()` is the only function that decides which is current, and it asks the two questions in
the same order `userOwns` asks them. An M9 payload — two pages in the identity window, no image, no
name — owns no row and gets `fileRetNoOwner`; it can reach the gate because the gate is DPL 3.

`fileRunRow` is asserted equal to `procMax` by the harness rather than left as a coincidence.

---

## 5. The pointer rule, which is the only part of this with a security argument

**`read` is the first syscall in this kernel that WRITES through a ring-3 pointer.** Every syscall
before it only read through one. That difference is not cosmetic:

* `elfOwns` (M10) answers *may ring 3 read this* — it requires the U bit out of the live page tables,
  page by page.
* The program's own R+X segment **passes that test**. It is user-accessible; it is not writable.
* A kernel that used `elfOwns` for `read` would let a program ask the filesystem to write a file into
  its own instructions, which is a hole straight through the W^X property ADR-0012 and ADR-0014 exist
  to enforce.

`fileOwnsWrite` therefore requires **both** the U bit and the W bit, page by page, for every page the
range touches. The bound on `ptr` comes first, before any arithmetic on it, for ADR-0013 §5's reason:
DCDart traps on overflow with a real `ud2`, so `read(fd, 0xFFFFFFFFFFFFFFFF, 512)` would otherwise
take a #UD *inside the syscall handler* — a ring-3 program choosing which instruction the kernel
executes next, using the very test meant to stop it.

**How this was verified, precisely:**

1. *By construction.* There is exactly **one** store to a caller-supplied address in `file.dart`, in
   `fileCopyOut`, and its only caller runs `fileOwnsWrite` over exactly that range first. The harness
   **counts** the `Pointer<u8>.fromAddress(dst` sites and requires the count to be 1.
2. *By structure.* The harness parses `fileOwnsWrite`'s body and requires it to consult `vmEffective`,
   to test bit 1 **and** bit 2, to advance page by page, and to bound `ptr` before doing arithmetic on
   it. A version that checked only the first page, or only the U bit, fails without booting.
3. *By a boot.* The program aims a `read` at `__ro_start` — its own read-only segment — and must get
   `fileRetBadPtr` back, and it hashes its whole R+X segment **before and after** and both hashes must
   equal the one `derive.py` computed from the ELF on the host. A partial write would change it.
4. *By a second boot pointer.* It also aims a `read` at `0x100000`, a kernel address, and must get the
   same refusal. And `open`'s NAME pointer is validated the same way and proved so the same way, with
   a raw `sys_call` rather than the library wrapper — the wrapper calls `strlen` first and would fault
   in ring 3 before the syscall happened.
5. *By a boot, over a range that SPANS TWO PAGES with different permissions.* This one exists because
   a mutation survived without it. `prog.ld` exports `__rw_end`, the end of the image's RW segment;
   the program aims a 64-byte `read` at `align_up(__rw_end) - 8`, whose first page is the last mapped
   page of the image and whose second page is not mapped at all (the stack is at `0x101FF000`, far
   above). A validator that looked only at the first page accepted it, and every other check in the
   harness passed — because every buffer the program otherwise uses lies inside one writable region.
   GAP-0124 records it.

The name is validated the same way and then **copied into the kernel before it is parsed**:
`fatParseAt` walks the bytes several times and compares them against directory sectors, and doing that
through a pointer ring 3 still owns would be a validator with a window in it.

---

## 6. Bounds, and what each one refuses

| bound | value | what a violation gets |
|---|---|---|
| descriptors per program | 4 | `fileRetNoSlot` — and the program opens five to prove it |
| bytes per `read` | 512 | `fileRetBadLen` |
| name length | 12 | `fileRetBadLen` |
| offset | ≤ file size | `fileRetBadSeek` (exactly AT the size is legal) |
| clusters per file | 256, M14's | `fileRetIo` (`fatErrTooBig` underneath) |

Eleven refusal values, all at or above one floor (`fileRetFloor`), so a caller separates a result from
a refusal with **one comparison** — ADR-0016 §1's shape, reused because it worked. A byte count, a
descriptor number and a file offset are all far below the floor; `userRefused` — what a kernel
*without* these syscalls hands back — is above it, so a program built against an older kernel sees a
refusal rather than a length. All nineteen numbers in `oslibc.h` are read back out of `file.dart` by
the harness.

**`read` returns a SHORT COUNT at the end of the file and the caller is required to notice.** That is
the most commonly mishandled part of a read loop and it is only visible on the last read of a file
whose size is not a multiple of the chunk, so `m15-fileio` builds the program **twice** — the second
ignoring the count — and requires the second to produce a different, also derived, hash and a
different, also derived, exit status.

---

## 7. `RFILE`, and why it is not called `FILE`

The buffered layer is real: one 512-byte buffer per open file, filled by one `read` syscall, drained
by `rfgets` a line at a time and by `rfread` a request at a time. Reading a 20 KiB file a line at a
time costs 40 syscalls instead of one per line, and `m15-fileio` proves the two paths agree by
requiring `rfread`'s FNV-1a over a 512-byte window to equal the raw loop's over a 173-byte one.

It is **not** called `FILE` and `rfopen` is **not** called `fopen`, because C's `FILE` reads *and
writes*, has three of itself open before `main`, keeps error and EOF indicators that `ferror` and
`feof` report separately, flushes, can be re-pointed by `freopen`, and can be told to be unbuffered.
This does one of those things. Naming it `FILE` would make ordinary C compile against it and then
behave differently, which is the exact failure ADR-0017 §5 built printf's loud `%!` marker to avoid.

There is **no `malloc` in it**, and that is forced rather than chosen: `sbrk` is refused unless a
process is live, and `run <name>` — the command that loads a program off the very filesystem this
exists to read — does not create one. So the `RFILE`s are a fixed array of two in `.bss`, which the
ELF loader zeroes, and `rfopen` returns NULL when both are taken.

---

## 8. The storage seam, for the sixth time

1280 bytes in ONE symbol (`file_store`) behind ONE accessor (`file_store_addr`) reached through
exactly THREE functions — ADR-0011 §0's pattern, unchanged. `m15-fileio/run.sh` counts exactly three
`return file_store_addr()` in `file.dart` and zero anywhere else in `core/kernel/`, and multiplies the
three region offsets out against the block's own size so that a region running past the end is a
structural failure rather than silent `.bss` corruption.

**No metadata word is unread.** M14's mutation round found that a counter nothing reads back is a
mutation survivor by construction (`fatMetaHits`, GAP-0120). Every one of words 0..10 here is either
printed by `fileExitReport` or is what another printed word is computed from, and the five spares are
declared as spares. Two counters that would have been dead — an attempt count and an orphan total —
were deleted before this shipped rather than left to be found.

The bounce buffer is a **separate** 512 bytes from `fat.dart`'s sector buffer, on purpose: `fat.dart`'s
buffer is a cache keyed by LBA for FAT and directory sectors, and pushing file DATA through it would
make a data sector look like a cached FAT sector to `fatReadCached`.

`fileInit()` zeroes all 96 words from `kmain()` before the first byte of output, and it must:
`fileExitReport` reads the "has anything ever opened a file" word on **every** exit from ring 3,
including the exits of five existing harnesses' programs, and a garbage word there would print a line
into the middle of five byte-exact goldens.

---

## 9. What this narrows, exactly

**GAP-0113 is narrowed and not closed.** `open`, `read`, `close`, `seek`, a per-program descriptor
table and a buffered reader now exist; a C program on this OS can name a file, read it in pieces at
offsets it chooses, and compute something from it. What GAP-0113 still covers, and what GAP-0122
enumerates: no writes at any layer, no directories, no `stat`, no `dup`, no `errno`, no `stdin` and no
console-input syscall at all, no `argc`/`argv`, no VFS and no second filesystem, no `SEEK_CUR` or
`SEEK_END`, and nothing that blocks.

**GAP-0116 item 5 is narrowed**: there IS a file descriptor now and a program CAN read a file. The
sentence that remains true is the one about the chain array, and §0 says how that is lived with.

**GAP-0116 item 6 moves**: the largest file this has ever been read from is now **20000 bytes on 20
clusters**, up from 9632 on ten. The 256-cluster bound is still untested.

---

## 10. What was deliberately not built

* **No writes.** Not a "not yet": there is no ATA write opcode, no free-cluster search, no directory
  update and no FAT update, and `m15-fileio` re-greps for all four. GAP-0116 item 1 is unchanged.
* **No `whence`.** `SEEK_CUR` is the offset the descriptor already keeps and `SEEK_END` needs a size
  this interface cannot ask for. One form, one argument, no enumeration to get wrong — and GAP-0122
  item 4 records the cost, which is that a program cannot find a file's size without reading to the
  end of it.
* **No `stat`, no `dup`, no `fcntl`, no O_ modes.** Each would be an interface with no caller.
* **No blocking, and no way to have one.** GAP-0097 is unchanged: this scheduler is cooperative and
  cannot suspend a process inside a syscall. Every `read` here completes or refuses.
* **No inheritance across `proc run`.** A new process gets an empty row. There is no `fork`, so there
  is nothing for a descriptor to be inherited *by*.

---

## 11. One thing the program does on purpose that looks like a bug

**It leaves a descriptor open when it exits.** `fd3` — the second descriptor on `DATA.BIN` — is never
closed, so the kernel's teardown closes it and prints `FILE ORPHANS 01`, and the harness requires that
line. A program that tidied up perfectly could not show that the kernel tidies up after one that does
not, and the teardown path is the one shared with the FAULT path: `elfTeardown` and `procCleanup` are
where descriptors are released precisely because two of their callers are failures. Without this, a
`fileReleaseOwner` that did nothing at all passed every check in the harness — it was a surviving
mutant until the program stopped being polite (GAP-0124).
