# ADR-0020 — Writing to a disk. **A program can create a file and put bytes in it; the write descriptor is APPEND-ONLY and starts EMPTY, and there is no way to ask for anything else.**

**Status:** accepted, implemented, verified (`core/tests/conformance/m16-filewrite/run.sh`) —
**18/18 harnesses, including against the pinned DCDart in an isolated sandbox (GAP-0132); 20 mutants,
16 killed, 4 survived, all four for one reason (GAP-0129)**
**Date:** 2026-08-22
**Supersedes:** nothing. **Narrows:** GAP-0090 items 3 and 4, GAP-0122 item 1 (see §9).
**Obsoletes six greps making four claims across two earlier harnesses, deliberately and in the open** (see §8).

---

## 0. The one-sentence summary, put where a footnote would hide it

**`open(name, O_WRITE)` creates the file or empties it, and the descriptor it returns can only append.**
There is no writing at an offset, no keeping what a file already had, no `seek` on a write descriptor
and no read-write mode. That is a smaller thing than POSIX `O_WRONLY` and the difference is the whole
of the design decision: a general write needs the cluster chain of a file that is being modified while
it is being walked, which is exactly the case where a wrong FAT update joins two files together — the
corruption a passing read test cannot see. Append-only means the only cluster the code ever needs is
the one at the end, the only FAT entry it ever changes is that one's, and "which cluster holds offset
X" is never a question anything has to answer.

**If that narrowing is the interesting part of this ADR, so is what it bought:** the volume the guest
writes is accepted by `fsck_msdos` and mounted and read back byte-for-byte by macOS's own `msdos`
driver, on a volume whose free space is fragmented so that a contiguous writer destroys a file that is
already there — and the bytes are still there after the machine has been switched off and on.

Everything below is detail.

---

## 1. What was built

| Piece | Where | What |
|---|---|---|
| `WRITE SECTORS` (0x30) | `ata.dart`, `ataWriteFrom` | one LBA28 sector, PIO, primary master |
| `FLUSH CACHE` (0xE7) | `ata.dart`, `ataFlushCache` | issued after **every** sector write |
| `fatWriteSector` | `fat.dart` | the ONLY caller of `ataWriteFrom`; keeps the sector cache honest |
| `fatSetEntry` | `fat.dart` | changes one FAT entry in **every copy of the FAT** |
| `fatFindFree` | `fat.dart` | first free cluster at or after a hint, wrapping once |
| `fatAlloc` / `fatTruncate` | `fat.dart` | extend a chain by one; free a whole chain |
| `fatDirCreate` / `fatDirWrite` / `fatDirTerminate` | `fat.dart` | a new entry; a size and first cluster; the end-of-directory marker |
| `fatNameLegal` | `fat.dart` | the fifteen bytes a FAT short name may not contain — **on the write path only** (§5) |
| `open(namePtr, nameLen, mode)` | syscall 5, extended | `mode` in RDX; 0 is read, 1 is create+truncate+append |
| `fdwrite(fd, buf, len)` | syscall 9 | up to 512 bytes at the descriptor's offset, which advances |
| `close(fd)` | syscall 7, extended | **flushes the directory entry** for a write descriptor |
| `fileOwnsRead` | `file.dart` | the read-side twin of M15's `fileOwnsWrite` (§4) |
| `openmode` / `create` / `fdwrite` | `core/user/libc/syscall.c` | the raw wrappers |

Donated `.bss`: **12768 → 14048** bytes (`file_store`, 1280 → 2560; `fat_store` **unmoved** at 1824).
Declared externs: **60 → 60** — M16 adds none, because `port_outw` has been in `core/boot/portio.S`
since M5 and the write path is the third subsystem to want it. `shellStrHelp`: **2147 bytes,
unchanged** — M16 adds no shell command, so not one of the goldens that assert the help text moves.

---

## 2. Why `WRITE SECTORS` and not `WRITE DMA`, and why the flush is not optional

`ataReadInto` has been PIO since M6 for a reason ADR-0010 sets out: PIO needs no bus-master DMA, no
physically-contiguous buffer and no PRDT, so it needed no physical memory manager. The write path has
the same shape for the same reason and adds nothing.

**`FLUSH CACHE` is the one thing a write path needs that a read path does not.** ATA/ATAPI-6 §6.8
allows `WRITE SECTORS` to report completion when the data is in the drive's volatile write cache. From
the host side, "the sector reached the medium" and "the sector reached a cache the drive will lose"
are indistinguishable until the power goes off — and M16's entire claim is about what is on the image
afterwards. So `ataWriteFrom` ends with `return ataFlushCache();` and the harness requires it to,
structurally, by reading the function's last statement.

**AND HERE IS WHAT THAT COSTS TO VERIFY, MEASURED RATHER THAN ASSUMED.** The mutation that removes
the flush was run again with the structural check disabled, and **it passes every one of the seven
boots**: QEMU persists a write to a raw image whether or not the drive's cache is flushed, so no test
that could be written for this emulator distinguishes a driver that flushes from one that does not.
**The flush is verified structurally and only structurally.** GAP-0129 records the experiment. On real
hardware with a write-back cache and a power cut it is the difference between a file and nothing,
which is exactly why it is in the code and why the check that guards it is a grep rather than a boot.

**One flush per sector, not one per file.** That is more conservative than it needs to be and it is
the right default for a driver whose caller is a filesystem with no journal: the cost is a command
per sector on a PIO path that is already a command per sector, and the benefit is that there is no
window in which the FAT is on the medium and the data is not, or the reverse.

**No retries.** A failed write returns a code and the caller decides. A driver that retried would turn
one bad sector into several attempts at it and would still not know whether the first attempt landed.

---

## 3. The five ordering rules the FAT layer keeps

These are the interesting part of `fat.dart`'s new half. Each one is a rule about **when** rather than
**what**, and each one exists because getting it wrong produces a volume that this kernel reads back
perfectly.

1. **BOTH FATs, ALWAYS, IN ONE FUNCTION.** `BPB_NumFATs` is 2 on every volume this driver will meet.
   A driver that updated one copy produces a volume `fsck_msdos` reports as "FATs differ" and that
   macOS's `msdos` driver may read from *either* — so the file would be there or not depending on
   which copy the reader picked. `fatSetEntry` is the only function in this kernel that changes a FAT
   entry and it writes every copy before returning. The harness derives the total sector count the
   session must produce (302), which a one-copy driver would miss by 53.

2. **THE NEW CLUSTER IS MARKED END-OF-CHAIN BEFORE IT IS LINKED.** If the power goes off between the
   two writes, the volume has a cluster marked in use that no file points at — a leak, which `fsck`
   calls a lost chain and can reclaim. The other order leaves a chain whose last link points at a
   cluster marked FREE, which the next allocation hands to a second file. Two files sharing a cluster
   is the corruption a read test cannot see.

3. **THE DIRECTORY ENTRY IS WRITTEN LAST.** Size and first cluster reach the disk at `close`, after
   every FAT link and every data sector. Until then the file on the volume is the old one, or for a
   new file an empty one, so an interrupted write loses the new data instead of producing a directory
   entry that claims bytes the FAT does not have.

4. **NOTHING PARTIAL IS LEFT ON A REFUSAL.** Every function returns its refusal *before* the write
   that would have made the change. `fatErrFull` in particular is produced by `fatFindFree` finding
   nothing, which happens before any FAT entry has been touched. The harness checks this the hardest
   way available: on a volume where `SEED.TXT`'s chain is a cycle, `open(..., O_WRITE)` is refused and
   **the image comes back byte-for-byte identical** — a truncate that started walking before it had
   validated the chain would have freed part of one it did not understand.

5. **THE ONE-SECTOR CACHE IS TOLD.** `fat_store`'s sector buffer holds one sector under one LBA. A
   write *through* it keeps the two in agreement (which is what makes "read a FAT sector, patch one
   entry, write it, patch another entry in the same sector" cost one read); a write of any other
   buffer to the cached LBA, or a write that FAILED, invalidates it. A cache that served bytes the
   drive had rejected would make a failed write look like a successful one to the very next read.

**And one rule about directories that most explanations skip.** The first 0x00 entry ends a FAT
directory: everything after it is undefined and no reader may look at it. When `fatDirCreate` consumes
that entry, the entry *after* it becomes the new terminator — and it is only a terminator if its first
byte is 0x00. `fatDirTerminate` makes sure of it, at the cost of one cached read and, on a freshly
formatted volume, no write at all.

---

## 4. `fdwrite` is the first syscall that READS through a ring-3 pointer, and the validator is not M15's

M15's whole pointer-safety story was `fileOwnsWrite`: `read` **writes** through a ring-3 pointer, so
the destination page must carry the USER bit *and* the WRITABLE bit, and a `read` aimed into the
program's own R+X segment is refused. That was the check M15 existed to get right.

`fdwrite` goes the other way. It **reads** through a ring-3 pointer, so the source page must carry the
USER bit and **must not** be required to carry WRITABLE — because a program writing out a string
literal is writing out `.rodata`, and a validator that demanded WRITABLE would refuse the most
ordinary call there is. `fileOwnsRead` is the same twelve lines as `fileOwnsWrite` with one test
different.

**Written out twice rather than sharing a flag**, for `fileOwnsWrite`'s own stated reason: `@bare`
DCDart has no boolean parameters and no default arguments, and a validator whose meaning depends on an
argument is a validator somebody will eventually call with the wrong one.

**Bounded by `fileWriteMax` and not by `userWriteMax`.** `elfOwns` already exists and would have been
the obvious thing to call — and it refuses any length above 128, because that is the console `write`
syscall's kernel-side limit. Reusing it would have silently capped every file write at 128 bytes.

**How this was verified**, since the question "did you actually check the property or just the code?"
is the one worth answering — and every one of these four was confirmed by a MUTATION that dies to it
(GAP-0129, mutants 12 and 13):

* **Structurally.** The harness parses both function bodies and requires: the first statement to be a
  comparison on `ptr`; every arithmetic use of `ptr` to come after the bound; a page-by-page walk;
  `vmEffective` to be the source of the permissions; the USER test in both; the WRITABLE test in
  `fileOwnsWrite` and **the absence of it** in `fileOwnsRead`; and the two different length bounds.
* **By running, in the direction that must be refused — three ways, not one.** The program aims
  `fdwrite` at address 1 (outside the window), at `0x10100000` (INSIDE the window and not mapped —
  the address a validator that checked only `vmProgBase`/`vmProgEnd` would accept), and at a range
  that STRADDLES the last mapped page of the image and the unmapped page after it (the one a
  validator that looked at the first page only would accept, and which was m15-fileio's surviving
  mutant until its program grew the same check). All three are `FILE_EBADPTR`.
* **By running, in the direction that must SUCCEED.** The program writes 64 bytes of `__ro_start` —
  a page that is present, user-accessible and read-only — into `SCRATCH.BIN`, and the harness reads
  `SCRATCH.BIN` back **through macOS's msdos driver** and compares it against the first 64 bytes of
  `prog.elf`'s R+X segment on the host. If the write-side validator had been reused here, that call
  would have been refused and the file would be empty.
* **By the program hashing its own R+X segment before and after** and requiring both to be the derived
  value, which is M15's check kept.

The bytes stop being the caller's before any of them reaches the FAT layer: `fileCopyIn` copies the
whole request into the kernel's bounce buffer immediately after validation, and from there on nothing
in the FAT layer, the ATA driver or `file.dart` dereferences an address ring 3 chose. That is
ADR-0019 §5's ordering applied to a longer path, and the harness requires `fileCopyIn` to have exactly
one call site, inside `fileSysWrite`, after `fileOwnsRead`.

---

## 5. A name this kernel writes is a name every other FAT implementation has to live with

`fatParseAt` accepts any printable byte (GAP-0117), which is laxer than the FAT specification: a name
with a `*` or a `|` in it is not a legal short name. **The write path refuses those and the read path
still does not**, and the asymmetry is deliberate:

* Tightening the **parser** would make a file some other formatter had put on a volume unreachable
  from this kernel. Refusing to name a file does not make it safer; it makes it invisible.
* Tightening the **creator** is the opposite. Putting a name the specification forbids into a
  directory is how a volume becomes something only this kernel can use.

`fatNameLegal` is checked in `fatDirCreate` and nowhere else. It was added because the first version of
this milestone's test program asked for `BAD*NAME.X` expecting a refusal, **got a descriptor**, and put
that name on the volume. `fsck_msdos` accepted it, which is the point: the host tools do not check name
characters, so nothing but this rule would have caught it.

---

## 6. Why the byte count `fdwrite` returns is load-bearing, and why it is better than `read`'s

A short write is not an error. If the volume fills up half way through a request, the bytes that got
there are on the drive, the descriptor's size counts them, and the return value is that count; calling
again returns `FILE_ENOSPACE` with nothing written. That is POSIX's shape, and it is deliberately
**better than what `read` does**: GAP-0122 item 14 records that a `read` failing part way through has
already written into the caller's buffer with no count to say so. The write path was built after that
entry and did not have to repeat it.

The unit of failure is a **sector**: `fileWriteChunk` either got 512 bytes onto the drive and flushed
them, or reports zero and has changed nothing about the descriptor.

**The negative control is exactly this mistake.** `PROGN.ELF` is the same source with one `#if`
different — it adds the length it *asked* for to its running total instead of the count `fdwrite`
*returned*. On the ordinary volume the two builds behave identically, which is why the harness runs
the control on the `full` variant, where the volume runs out. The control
reports 8304 bytes, the real program reports 8192, and **the two boots leave byte-for-byte identical
volumes** — so the disk sides with the kernel and the difference is confined to userland.

---

## 7. The storage, and the two things that made a descriptor twice as big

`file_store` went from 1280 bytes to 2560, in three pieces:

* **Sixteen more metadata words.** Six are M16's counters — writes, bytes, data sectors, files created,
  files truncated, directory flushes — and the rest are declared spares. The block had 16 words with 11
  in use, so M16 could have had five for free and would then have had none.
* **Four more words per descriptor.** A write descriptor remembers which root-directory entry it came
  from (so `close` writes the right one without looking the name up again — nothing that happens to the
  directory in between can make it write a different file's entry), which cluster is currently last (so
  appending never walks a chain), and **how many bytes of cluster it has allocated**. That last one is
  not obvious: the natural test for "do I need another cluster" is `offset % clusterBytes == 0`, and it
  is wrong after a *failed* write — the cluster was allocated, `pos` did not move, and the retry
  allocates a second one and leaks the first. A descriptor that records how much it owns cannot get
  that wrong.
* **A second sector buffer.** A write that does not start and end on a sector boundary must have the
  caller's bytes and the sector already on the drive in memory at the same time. One buffer for both
  would mean the read destroyed the data being written — on every write whose length is not a multiple
  of 512, which is most of them. `fat_store`'s buffer is not available either, for the reason its own
  note gives: it is a cache keyed by LBA, and putting a data sector through it would make the next FAT
  read believe a data sector was a FAT sector.

Still **one symbol** behind **four** seam functions (ADR-0011 §0), and the harness counts exactly four
`return file_store_addr()` in `file.dart` and none anywhere else. `fat_store` did not move: the write
path reuses the four regions M14 donated, which is why the harness asserts 1824 as well as 14048.

**`fatWrites`, `fatAllocs` and `fatFrees` are the only three functions `file.dart` calls to read
`fat.dart`'s counters**, and they exist so that the exit report can print a number the FAT layer owns
without a second accessor into its storage.

---

## 8. Six greps in two earlier harnesses are now false, and what replaced them

`m14-fat` and `m15-fileio` between them ran **six greps making four claims**: no ATA write opcode
(`0x30`/`0x34` absent from `ata.dart`'s command constants — grepped by both), no `port_outw` aimed
anywhere but the framebuffer (m14), no write function by name (grepped by both, over different file
lists), and no open mode in `oslibc.h` (m15). **They were correct and they are now obsolete.** Deleting them would have been a quiet loss of coverage, so
each was replaced by something that still constrains:

| was | is |
|---|---|
| m14: no `0x30`, no `port_outw` outside `fb.dart`, no write function by name | `ataWriteFrom` is **defined once and called from exactly one place** (`fatWriteSector`), and the only `port_outw` aimed at 0x1F0 is inside it. "Can this code path write a sector?" still has one place to look. |
| m14: (nothing — this claim did not exist) | **every image m14 boots is byte-for-byte identical afterwards**, checked by SHA-256, including all five broken-volume boots |
| m15: no write opcode, no write function, no open mode | **a mode-less `open()` is still `O_READ`**, plus the same SHA-256 check across all four m15 boots |

The measurement is strictly stronger than the greps for what was being claimed: a kernel that *can*
write and does not still passes, and a kernel that quietly wrote one sector does not. What the greps actually protected — that
the read path is a read path — is now checked by running rather than by what is spellable.

`m16-filewrite` adds the structural half in the same act, over the same code, so the two together are
"the write path exists in exactly one place" and "the read paths do not go near it".

**One thing was lost and it is named rather than absorbed.** The old greps would have caught a write
path added to `elf.dart` or `shell.dart` *even if no test ever executed it*. The replacement catches
an unused one only through the "defined once, called once" structural check, which a determinedly
evasive author could satisfy by routing a second caller through `fatWriteSector`. GAP-0130 records
that reduction in reach.

---

## 9. What this narrows

**GAP-0090 item 3 (Allocation) and item 4 (A write path)** — both were `UNCHANGED` at M14 and both
move. Item 4's "everything downstream of that is absent by construction" is now false for the first
three things it names: there is a free-cluster search, a directory update and a FAT update. A journal
and crash consistency are still absent, now by choice rather than by construction, and GAP-0127 item 7
says exactly what an interruption costs.

**GAP-0122 item 1** — "THERE ARE NO WRITES, AT ANY LAYER" — is replaced item by item. What is left of
it, and everything M16 deliberately did not build, is GAP-0127.

**GAP-0116 item 1**, which GAP-0122 item 1 restated, goes with it.

---

## 10. What M16 does NOT do, in one place

GAP-0127 is the accounting; this is the list so nobody has to go looking. **No writing at an offset**
(a write descriptor is append-only and starts empty; `seek` on one is refused). **No `O_APPEND` that
keeps what a file had.** **No read-write mode.** **No `unlink`, `rename`, `mkdir` or `rmdir`.** **No
timestamps** — this kernel has no wall clock, and a made-up date is worse than none. **No `fsync`
separate from `close`.** **No subdirectory can be written to, and no file outside the root.** **No
journal, no ordering guarantee across two files, and no way to tell whether the last boot ended
cleanly.** **Nothing is concurrent.**

**The sharpest single hazard is GAP-0127 item 17 and it belongs in this file too**: a descriptor open
for READING while the same file is opened for WRITING will read rubbish. The read descriptor holds the
first cluster and size the directory entry had at `open`; the write path frees that chain and hands
the clusters out again. There is no open-file table keyed by name, no sharing mode and no reference
count, because descriptors are per-program rows in a fixed table and nothing indexes them by what they
point at. **M16 did not introduce a check for this and did not pretend to**; an open-file layer is a
milestone rather than a patch.

And the one that matters most for anyone reading this later: **a write is only as safe as the last
`close`.** The FAT links and the data sectors reach the drive as they are produced; the directory entry
that makes them a file reaches it at `close`, or at teardown if the program faults first. There is no
third path.
