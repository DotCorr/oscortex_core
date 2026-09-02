# ADR-0024 — The read-only attribute. **`open(name, O_WRITE)` on a file the volume marks read-only is refused, and the file still has its bytes afterwards.**

**Status:** accepted, implemented, verified (`core/tests/conformance/m16-filewrite/run.sh`, BOOT 1 and
the host `msdos` read-back)
**Date:** 2026-08-23
**Part of:** a fix batch, not a milestone. No `ROADMAP.md` entry — see §6.
**Fixes:** GAP-0152. **Narrows:** GAP-0127 (M16's list of what the write path does not do).

---

## 0. The defect, in one sentence

`fatAttrReadOnly` was defined in `core/kernel/fat.dart` at M14 and **appeared nowhere else in the
tree**. `fileMakeEmpty` — the function `open(name, O_WRITE)` reaches before it has a descriptor —
checked `fatErrIsDir` and nothing else in the attribute byte, so **any ring-3 program could empty a
file the volume marks read-only**, and the refusal it should have got did not exist to be returned.

It is reachable from ring 3, it destroys data, and it needed six lines of kernel to close.

---

## 1. What was built

| Piece | Where | What |
|---|---|---|
| `fatErrReadOnly = 32` | `fat.dart` | the fourth write refusal, and the first about **permission** |
| `fatStrE32` | `fat.dart` | its sentence, 52 bytes, and its branch in `fatReportError` |
| `fatWritable()` | `fat.dart` | `fatErrReadOnly` if the last lookup's entry has bit 0 of `DIR_Attr` |
| `fileRetReadOnly` | `file.dart` | `0xFFFFFFFFFFFFFFF1` — the fourteenth refusal ring 3 can see |
| the guard | `file.dart`, `fileMakeEmpty` | four lines, placed **before the first destructive call** |
| `FILE_EREADONLY` | `oslibc.h` | the same value, checked against the kernel's by m15 and m16 |

## 2. Why the check is in `fat.dart` and the refusal is returned from `file.dart`

`file.dart` is not entitled to know that bit 0 of `DIR_Attr` means anything: the attribute byte is the
volume format's vocabulary and `fat.dart` owns it. So the *question* — "may this entry be emptied?" —
is asked by `fatWritable()`, and `file.dart` only translates the answer through the `fileFromFat`
mapping that already exists for every other FAT-level code.

That split is also what makes the refusal satisfy `m14-fat`'s standing check that **every `fatErr*`
code is returned from somewhere in `fat.dart`**, has its own branch in `fatReportError`, and has a
sentence no other code shares. A refusal code checked only in `file.dart` would have been a code
`fat.dart` never produces — dead by that harness's definition, and rightly so.

## 3. Where the guard sits, and why that exact line

```
  lookup                                  <- fatMetaFileAttr becomes meaningful HERE, on a hit
  not-found            -> create, return
  is-a-directory       -> refuse
  any other lookup err -> refuse
  READ-ONLY            -> refuse          <-- the guard
  fatClose / fatTruncate / fatDirWrite    <- the first thing that changes the volume
```

Two constraints pin it to that line and nowhere else:

* **It must be after the hit is established.** `fatLookup` writes `fatMetaFileAttr` the moment a name
  matches and does *not* clear it on a miss, so asking earlier would read a previous lookup's
  attribute. Every branch above the guard has already returned for `fatErrNotFound` and for every code
  that means the lookup itself failed.
* **It must be before `fatTruncate`.** `fatTruncate` returns the chain's clusters to the free pool and
  `fatDirWrite` zeroes the entry's first cluster and size. A check after either of those would be a
  refusal reported over a file that had already been destroyed — which is exactly the failure mode the
  test in §4 is built to catch.

## 4. The test, and why the obvious version of it would have passed a broken fix

`m16-filewrite`'s volume now carries **`RO.TXT`, 1024 bytes with attribute `0x21`** (archive +
read-only), taking one cluster off the end of `FILL.BIN`'s run rather than out of the guest's free
pool — the same trick `SUB` already uses, so not one cluster of the allocation the harness predicts
moves. `prog.c` calls `create("RO.TXT")` from ring 3 and prints the refusal.

**Asserting the refusal is not enough.** A guard placed one line too low returns exactly the same
number and leaves an empty file behind. So the harness also:

1. requires `RO.TXT`'s directory entry to still read `ATTR 21 CLUS <c> SIZE 00000400` in the kernel's
   own `ls` after the program has run, and
2. **mounts the image with macOS's own `msdos` driver and compares `RO.TXT`'s 1024 bytes against the
   bytes `make-image.py` generated** — the same judge M16 already uses for `KEEP.BIN`.

A refusal that still truncated fails (2) and would fail (1). That is the difference between testing a
return value and testing an outcome.

## 4b. Which goldens this moved, measured

Four: `m16-filewrite`'s (deliberately — its program grew a phase and its volume grew a file), and
`m8-paging`'s, `m9-ring3`'s and `m10-elf`'s, which move for a reason that has nothing to do with
filesystems. Those three print a `VM SECT` line carrying the kernel's own section extents, and this
fix adds **240 bytes of `.text`** (`fatWritable`, the guard, the dispatch branch) and **92 bytes of
`.rodata`** (`fatStrE32` plus alignment). `.bss` is unchanged at 71728.

`m8-paging` moves by more than one line, and the extra lines are worth naming rather than waving
through: `VM TEST X ADDR` (the address of `vm_exec_ok` in `isr.S`) moves by exactly **0x30** — the 48
bytes ADR-0025's probe adds to `boot.S`, which links ahead of it — and `VM TEST RO/NX ADDR`, its two
`PF CR2` lines and `VM FAULTS` all move by **0x28**, the shift of `vmCanary` in `.rodata` behind
`fatStrE32`. Every changed line in all four goldens is an address, and every one of them is accounted
for by a byte count measured from the link.

Every golden was regenerated only after two independent runs produced a **byte-identical** diff and
every derived check in the harness had passed on both — `--regen` in these harnesses runs after all of
them, which is what makes it safe here. `m16`'s golden contains no `RFLAGS` line at all, so GAP-0133's
flake cannot reach it; `m10-elf`'s and `m9-ring3`'s do, so for those the regeneration additionally
required the diff to contain **nothing but the `VM SECT` line**, which is the check that the run being
enshrined carried the same `RFLAGS` the previous golden did.

## 5. What this does *not* do

* **It is not a permission system.** FAT has no owner, no group and no mode. Bit 0 of `DIR_Attr` is
  the entire access-control vocabulary of the volume format, and this kernel has no user identity to
  compare it against. Any program in ring 3 may still create, truncate and write any file that is not
  marked read-only.
* **It does not make the bit settable.** There is no `chmod`, no `attrib`, and `fatDirCreate` still
  writes `fatAttrArchive` and nothing else. A read-only file gets onto the volume from the host.
* **It does not cover a delete or a rename**, because this kernel has neither.
* **`fatAttrHidden` and `fatAttrSystem` are still read by nothing**, deliberately: neither is a
  protection bit, and inventing a meaning for them here would be this kernel making up policy the
  format does not have.

## 6. The note this ADR exists to record: a design limit and an omission are different things

M16 shipped GAP-0127, a nineteen-item list of what its write path deliberately does not do. **This
defect was not on it.** The list is not careless — it is careless about one specific thing, and naming
that thing is worth more than the fix.

GAP-0127 enumerates **design limits**: things the author decided not to build, each with a reason. It
was written by asking *what did I choose not to do?*, and the answer to that question is bounded by
what the author was thinking about. An **omission** is different in kind: it is a case the author never
brought to mind at all, so it cannot appear in an answer to that question, however honestly the
question is answered. A read-only file is not something M16 decided not to honour. It is something M16
did not notice existed, in a constant its own file declares.

The practical consequence: **a gap list written by its author enumerates the boundary of their
intent, and the boundary of their intent is not the boundary of the code.** Nineteen items of "what I
deliberately did not do" is evidence of care and is not evidence of coverage, and it should never again
be cited as though it were. The thing that found this was an audit asking a different question —
*which declared constants does nothing read?* — which is a question no author asks about their own
work, because to them every constant they wrote had a purpose.

There is no `ROADMAP.md` entry for this change. It is a fix batch: this ADR, GAP-0152, and the
harness that owns the area are where it is recorded.
