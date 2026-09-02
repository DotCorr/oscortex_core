# ADR-0038 — A refusal that does not name itself is not a refusal the operator can act on

**Status:** accepted (shakedown)
**Depends on:** ADR-0019 (the file syscalls), ADR-0020 (writing to a disk)
**Closes:** two of the eight defects the shakedown campaign recorded — the `file` module's silent
refusals, and the codes `m16-filewrite` reached on every run and observed nowhere.

---

## 1. The two defects, which are one defect seen from two ends

### 1a. `fileRefuse` wrote nothing to the UART

`core/kernel/file.dart`'s `fileRefuse()` is the single funnel through which all fourteen `fileRet*`
refusals pass, and it had **43 call sites** and a three-line body:

```dart
void fileRefuse(u64 frame, u64 code) {
  fileBump(u64(fileMetaRefusals));
  userSetFrame(frame, u64(userFrameRax), code);
}
```

It counted, it set RAX, and it said nothing. Every other module in this kernel narrates:

| module | funnel | line | codes | sentences |
|---|---|---|---|---|
| `fat` | `fatReportError` | `FS ERR <hh> <sentence>` | 32 | 32 |
| `elf` | `elfReportError` | `ELF REFUSED <hh> <sentence>` | 25 | 25 |
| `proc` | `procRefuse` | `PROC REFUSED <hh> <sentence>` | 9 | 9 |
| `chan` | `chanRefuse` | `CHAN REFUSE C <hh> EP <..> R <code>` | 14 | code only |
| `ioctl` | `ioctlRefuse` | `IOCTL REFUSED <code>` | 10 | code only |
| **`file`** | **`fileRefuse`** | **nothing** | **14** | **none** |

**This was NOT unobservability, and calling it that would over-claim it.** Each of the fourteen is a
distinct 64-bit value in RAX — `0xFF..FE` down to `0xFF..F1` — and a ring-3 program reads it
directly. `m15-fileio/prog.c` prints them and `m15-fileio/expected.txt:84` pins the line
`USER WRITE M15 REFUSE OPEN fffffff9 fffffff8 fffffffa fffffffc`. That is a strong test of the ABI.

It is not a test of the kernel's transcript, **and the transcript is where an operator without a
purpose-built program has to look.** All such an operator got was the exit aggregate,
` REFUSED 0000000E`, plus an `FSERR` field carrying the *FAT-level* code and not this one. The
accurate name for the defect is **reachable, distinct to the caller, unnarrated to the operator** —
a real defect, and a lesser one than unobservability. It is why 23 green harnesses did not catch it:
every one of them asserted on the ring-3 program's output, and nothing required the kernel to expose
anything.

### 1b. Six codes fired on every `m16-filewrite` run and nothing recorded which

The campaign's write-up listed seven: `fatErrFull` (1D), `fatErrNoDirSlot` (1E),
`fatErrDiskWrite` (1F), `fatErrReadOnly` (20), `fileRetBadMode` (F3), `fileRetNoSpace` (F2),
`fileRetReadOnly` (F1). **Six of them are right and the seventh is not** — see §5.

The capture said `REFUSED 0000000F` — fifteen refusals — and `FSERR 20`. So the codes were reached.
And then:

```
$ grep -c '^FS ERR' <capture>                          -> 0
$ grep -o 'fffffff3\|fffffff2\|fffffff1' <capture>     -> nothing
$ grep -rl 'fffffff3' core/tests/conformance/*/expected*.txt -> nothing
```

Three of them had **never appeared in any golden in the repository**, and `m16`'s program — unlike
`m15`'s — does not print the value it got. So for these the two halves compounded: the kernel did not
say which refusal it gave and neither did the only program that provokes them.

**That is the category worth counting separately: reached, and unobservable.** `m16-filewrite` was
green, it exercised all six, and it would have stayed green if any of them had started returning a
different code, or the same code for a different reason, or stopped being returned at all. A test
that passes against a code while proving nothing about it is the thing this whole campaign exists to
detect.

## 2. The decision

**Two lines, in two funnels, and no new vocabulary.**

1. `fileRefuse` prints `FILE REFUSED <16 hex>` and a newline, once per refusal. The shape is
   `ioctlRefuse`'s exactly (`IOCTL REFUSED <16 hex>`), because consistency with the module that
   already got this right is worth more than a shorter line. All fourteen `fileRet*` codes become
   narrated at once, for every present and future caller.

2. A new one-line funnel, `fileFatStatus(code)`, replaces the twenty bare
   `fileSetMeta(u64(fileMetaStatus), X)` assignments. It records the FAT-level code exactly as
   before **and calls `fatReportError`**, so the same `FS ERR <hh> <sentence>` line appears whether
   the failure arrived through `cat` or through `fdwrite`.

## 3. Why the second funnel is necessary and `FILE REFUSED` alone is not

Because the file layer's vocabulary is **lossy in both directions**, and these codes are exactly
where it loses:

* `fatErrFull` and `fatErrNoDirSlot` **both** become `fileRetNoSpace`. A `FILE REFUSED F2` cannot
  tell a full volume from a full root directory.
* `fatErrDiskWrite` becomes `fileRetIo`, which eight other conditions also become.
* A **short write** reports a byte count and refuses nothing at all — so `fatErrFull` is reachable on
  a call that never enters `fileRefuse`.

So the FAT code has to name itself where it is *recorded*, not where it is returned. `fatReportError`
is the function `fat.dart` already uses for that, with a distinct sentence for all 32 codes.

An alternative was considered and rejected: printing ` FAT <hh>` on the `FILE REFUSED` line, read out
of `fileMetaStatus`. It is one line instead of two, and it is **wrong for every purely-file
refusal** — BadFd, BadPtr, BadLen, NoSlot, BadSeek, NoOwner and BadMode, which do not touch the
filesystem at all and would have printed whatever the last FAT-level failure happened to be. A field
that is right most of the time and stale the rest is worse than no field: it is a number a reader
will believe.

## 4. What `fileRefuse` still does not do, deliberately

**It does not write `fileMetaStatus`.** That word holds the last *FAT-level* refusal, which is a
different vocabulary, and it is the only place the filesystem's own account of what was wrong
survives to the exit line. Writing this file's value into it would make `FSERR` print the number the
program already has in RAX, and lose the one it does not.

**The fourteen codes still have no sentences.** `file`, `chan` and `ioctl` now all narrate a bare hex
number; `fat`, `elf` and `proc` narrate a number and a sentence. 38 of the kernel's 105 refusal codes
have no sentence anywhere. That is recorded, not fixed here: it is a separate change with a separate
cost (38 more `@rodata` tables), and it is a smaller defect than silence — a number can be looked up,
and nothing could be looked up before.

## 5. What now fails if either half is removed

* `m16-filewrite/run.sh` CHECK 13 asserts **six of the seven** by name, in the boot that provokes
  each: `fatErrReadOnly`/`fileRetReadOnly` and `fileRetBadMode` on the main boot,
  `fatErrFull`/`fileRetNoSpace` on the full-volume boot, and `fatErrNoDirSlot` on the dirfull boot —
  which is the pair `FILE REFUSED` alone could never separate. Before this change none of the six
  appeared anywhere in that harness's capture, and three appeared in no golden in the repository.

  **The seventh was mis-categorised by the campaign's own write-up and is corrected here.**
  `fatErrDiskWrite` (1F) is produced only by a failing `ataWriteFrom` — a drive that does not take
  the sector — and QEMU's IDE model on a writable image never does that. It is not *reached and
  unobservable*; it is unreachable while the hardware works, which is a different row of the census.
  CHECK 13 asserts its **absence** instead, which is a real claim: if a healthy volume ever started
  reporting device write failures, every write this harness then checks would be suspect.
* `m15-fileio/run.sh` asserts that the kernel's own transcript names the four `open` refusals its
  program already prints, so the two accounts of the same event must agree.
* Both goldens now carry `FILE REFUSED` and `FS ERR` lines, so a kernel that stopped printing them
  fails a byte-exact comparison as well as a grep.
