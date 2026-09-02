# ADR-0018 — A read-only FAT16 filesystem, and programs run by name

**Status:** accepted, implemented, verified (`core/tests/conformance/m14-fat/run.sh`)
**Date:** 2026-08-22
**Depends on:** ADR-0010 (ATA PIO), ADR-0011 (frames, and the storage seam), ADR-0014 (the ELF loader).
**Narrows:** GAP-0090 items 1, 2, 5 (partly), 6 (partly) and 8 (partly). **Does not touch** items 3,
4, 7 or 9 — see §9 and GAP-0116.

---

## 0. What this replaces

Until this milestone, "putting a program on the disk" meant a Python script writing 32 bytes —
`"OSCXPRG1"`, a length, an LBA — at a sector number it then told the harness, and `run 20` meant
**sector 0x20**. That is the whole of GAP-0090: no names, no directory, no allocation, no way to ask a
disk what is on it.

M14 adds names, a directory and a chain. It adds no writes.

---

## 1. FAT16 rather than a format of our own

A custom format would have been a hundred lines shorter and would have proved nothing. FAT16 was
chosen for three properties none of which a private format has:

* **It is checkable by tools that have never heard of this repo.** `m14-fat/run.sh` runs
  `fsck_msdos` — Apple's, from FreeBSD — against the image, and then MOUNTS it with macOS's own
  `msdos` driver and requires both programs to read back byte-for-byte along their fragmented chains.
  A volume only this kernel can read is not evidence about this kernel.
* **The harness can build one in plain Python.** No `newfs_msdos`, no mtools, no dependency the next
  machine might not have. `make-image.py` writes the boot sector, two FATs, a 512-entry root
  directory and a 5000-cluster data region byte by byte, and then walks its own output back.
* **A real host can inspect the result**, which is what makes a failure diagnosable rather than
  mysterious.

FAT16 rather than FAT12 or FAT32 because it is the variant whose on-disk numbers are all 16-bit —
one entry size, no nibble packing, no `BPB_FATSz32`, no cluster-2 root directory — and because the
other two are then two *refusals* rather than two code paths.

---

## 2. The type is COMPUTED. `BS_FilSysType` is never read

`BS_FilSysType` at offset 54 spells `"FAT16   "` on this volume and whatever the formatter felt like
on the next one. Microsoft's specification is explicit that the variant is determined by one computed
quantity:

```
CountOfClusters = (TotalSectors - DataStart) / SectorsPerCluster

    < 4085   ->  FAT12
    < 65525  ->  FAT16
    else     ->  FAT32
```

`fatMount` computes it and refuses FAT12 and FAT32 **by name**, with two different refusal codes. It
never looks at the string, and `m14-fat/run.sh` greps the source to make sure it never starts: a
driver that trusted the string would read a FAT12 volume as FAT16, and every 12-bit chain entry would
be a plausible 16-bit cluster number pointing somewhere else. That failure mode produces a corrupt
file, not an error.

Every other field that is not what this driver can handle is its own refusal with its own sentence:
a sector size that is not 512, a `BPB_SecPerClus` that is not a power of two in 1..128, a reserved
count of 0, a FAT count that is neither 1 nor 2, `BPB_FATSz16 == 0` (the FAT32 shape), a root-entry
count that is 0 or not a multiple of 16, a total-sector count of 0 in both fields, a data region
starting past the end of the volume, a FAT too small to hold one entry per cluster, and a FAT[0] whose
low byte is not `BPB_Media` or a FAT[1] that is not an end mark. **Twenty-eight refusal codes, each
with its own sentence, and the harness requires every one to be reachable.**

---

## 3. Mount is idempotent, and every command does it

There is no `mount` state a command can find stale, because there is no command that runs without
establishing it. `fatMount` is one cached sector read once the boot sector is in the buffer, and it
leaves the same twelve words behind every time. `fs`, `ls`, `cat` and `run <name>` each call it and
each report its refusal in their own vocabulary.

That removes an entire class of ordering bug for the price of a comparison, and it is why nothing
mounts at boot: mounting at boot would either print a diagnostic into the middle of m1-interrupts'
544-byte golden or swallow one.

---

## 4. The chain is walked, and the volume is built to punish a driver that does not

A file on a freshly-written volume is contiguous, so a driver that ignores the FAT entirely and reads
`size` bytes forward from the first cluster passes every test anybody writes by accident. So nothing
on `m14-fat`'s volume is contiguous:

* `PROGA.ELF` takes the **odd** clusters and `PROGB.ELF` takes the **even** ones, from cluster 3 and 4
  respectively. The two are interleaved 1KiB slab by 1KiB slab. A contiguous reader does not get
  garbage — it gets a plausible-looking executable that is half a different program.
* `HELLO.TXT`'s two clusters are **2 and 100**, with 98 clusters of a recognisable background pattern
  in between.

And the programs **hash themselves**: `prog.c` runs FNV-1a over its own R+X segment (bracketed by
`__ro_start`/`__ro_end` from the link script) and prints it, and `derive.py` hashes the same bytes of
the ELF on the host. FNV-1a rather than a checksum **because a checksum is invariant under a
permutation of clusters**, which is exactly the corruption being looked for. `derive.py` also computes
what the same program *would* hash if the loader had assumed contiguity, and the harness requires that
number not to appear anywhere in the capture.

The chain is materialised once, at `fatOpen`, into a 256-entry array. That is not an optimisation; it
is what puts all four integrity checks in one place:

| condition | refusal |
|---|---|
| a cluster outside `[2, clusterCount + 2)` | `fatErrChainRange` |
| a link to cluster 0 (FREE) | `fatErrChainFree` |
| a link to 0xFFF7 (BAD) | `fatErrChainBad` |
| a cluster already in the chain | `fatErrChainCycle` |
| an end mark before the size says | `fatErrChainShort` |
| no end mark after the size says | `fatErrChainLong` |
| more than 256 clusters | `fatErrTooBig` |

The length is derived from the directory entry's size and then **required in both directions**. A
driver that stopped at the end mark and believed whatever length that produced would read a file whose
directory entry and FAT disagree without noticing that they do. A driver that only stopped at an end
mark would follow a cyclic FAT until the machine was switched off — so the `badchains` volume has a
2-cycle in it and the kernel is required to name it as one.

---

## 5. Eight-point-three only, and it is a refusal rather than a truncation

Long-filename entries (attribute exactly `0x0F`) are skipped by `ls` and invisible to the lookup. A
file whose only human name is its long one is reachable here **only by its 8.3 alias**, which is what
the directory actually stores. The volume carries three real LFN entries in front of `PROGB.ELF` —
real enough that macOS resolves `program-b-with-a-long-name.elf` from them, which the harness checks —
precisely so that a driver printing them as 8.3 names would print three lines of UTF-16 rendered as
Latin-1.

A typed name that is too long, has two dots, has an empty stem or carries a byte outside
`0x21..0x7E` is `fatErrBadName` rather than a truncation. Truncating would turn `PROGRAMME.ELF` into a
lookup for `PROGRAMM.ELF`, which might succeed — and would then run a different file from the one that
was asked for.

Names are upper-cased on the way in, because the shell has no shift handling (GAP-0055) and a FAT
directory stores upper case. Without that, no file on any volume would ever be found from this shell.

**A finding from the mutation round, recorded because it is the kind of thing that reads as a test
gap and is not one.** Deleting the `attr == 0x0F` check entirely changes NOTHING observable. The LFN
attribute is `0x01 | 0x02 | 0x04 | 0x08`, and that last bit is `ATTR_VOLUME_ID` — so an entry skipped
for being a long-filename entry is already skipped for looking like a volume label. That is not an
accident of this driver; it is why the LFN designers chose `0x0F` in the first place, so that drivers
predating long filenames would skip them. The explicit check stays because it names the intent and
because a future `ls -l` will want to distinguish the two, but **it is not independently testable and
this harness does not pretend to test it.** GAP-0120 lists it among the survivors.

---

## 6. `run <name>`, and how it coexists with `run <lba>`

`shellElfRunCmd` calls `ataParseLba`, which returns a value above `ataLba28Max` for anything that is
not one to seven hex digits. Above the bound, the argument is looked up as a filename; at or below it,
it is a sector. **That is the whole of the disambiguation** — one comparison, no new parser, and every
earlier harness's `run <lba>` keeps working unchanged.

The ambiguity is real and is not hidden: a file whose 8.3 name is one to seven hex digits and nothing
else — `CAFE`, `20` — is reachable by `cat` and not by `run`. GAP-0119 records it, with the reason a
separate spelling was not worth four goldens.

Inside the loader, M14 changed **one function**. `elfReadSectors` used to add an image-relative sector
index to a base LBA; it now goes through `elfImageLba`, which asks `fat.dart` whether a file is open
and, if one is, returns `fatFileSector(i)`. The decision lives in `fat.dart`'s own word rather than
being copied into the loader's metadata, so there is exactly one place that knows which of the two a
load is, and it is the place that set it. `shellElfRun` and `procCreateAt` each call `fatClose()`
first, because both are numeric by construction and a `cat` earlier in the session would otherwise
leave a chain for them to read through.

`elfLoad` was split in two: `elfLoad` (header sector, then the rest) and `elfLoadFile` (the directory
entry's size, then the rest), sharing `elfLoadImage`. There is no `"OSCXPRG1"` header on the FAT path
and there does not need to be — that sector existed to carry a length and a starting LBA because
nothing else on the disk could. The two bounds it was checked against (64 bytes, `elfImageMax`) are
applied to the directory's size in the same order and with the same refusal codes, because they are
bounds on what this loader can hold and not on where the number came from.

---

## 7. The storage seam, for the fifth time

DCDart has no mutable static data of any kind (GAP-0053), so every byte of filesystem state is
assembly-donated `.bss`: **one symbol**, `fat_store`, 1824 bytes, four regions, reached through **one**
`@extern` accessor called from exactly **four** places.

| region | offset | size | what |
|---|---|---|---|
| metadata | 0 | 256 | 32 `u64` words: geometry, the open file, two counters |
| chain | 256 | 1024 | the open file's cluster chain, 256 × `u32` |
| sector | 1280 | 512 | one sector buffer — every FAT and directory read |
| name | 1792 | 32 | the 11 raw bytes of the 8.3 name being looked up |

`m14-fat/run.sh` counts exactly four `return fat_store_addr()` in `fat.dart` and zero anywhere else in
`core/kernel/`, and multiplies the four offsets out against the block's own size so a region that ran
past the end is caught rather than corrupting whatever `.bss` follows. Donated `.bss` goes 9664 →
**11488**; `proc_store` ends at a multiple of 16 so the `.align 8` costs nothing.

`.bss` is not zeroed by anything in this kernel, so `fatInit()` writes all 32 metadata words from
`kmain()` before the first byte of output. It must: `elfReadSectors` reads the "a file is open" word on
every sector of every `run`, including `run <lba>`.

**The sector buffer is deliberately not the loader's.** `elf.dart` reads file data straight into the
frame it owns and never through this buffer; the buffer exists for the FAT and the root directory,
which are read repeatedly and are not the caller's business. One sector of cache turns a chain confined
to one FAT sector — which is what every chain on a small volume is — into one disk read instead of one
per link, and `fatMetaReads`/`fatMetaHits` make the difference a number rather than a claim. **The cache
is invalidated before the read and repopulated after it**, so a failed `ataReadInto` cannot leave the
buffer claiming to hold a sector it does not.

---

## 8. What the help text cost, and how the goldens moved

`help` grew 1871 → **2147** bytes: `run <name>`, `fs`, `ls`, `cat <name>`. A command that is not in
`help` is undiscoverable, so this is not optional.

m3-shell's, m4-fault's, m5-pci's and m6-disk's serial goldens were **not regenerated**. The four lines
were inserted mechanically after the `run <lba>` line in each file and the kernel was then required to
reproduce the result byte-for-byte — which it did, at 5511, 4012, 3796 and 8306 bytes. m3's 80×25
screen golden was rebuilt the same way: four lines inserted, four dropped off the top, which is exactly
what four more lines of `help` do to a buffer that is already scrolling. A substitution that produced a
file the kernel does not print fails immediately, which is the whole reason this is substitution and
not a fresh capture.

m7 through m13 moved because the **image grew** — GAP-0078 exercised again — and were regenerated with
`--regen`, with each harness's derived checks recomputing every address from the boot's own memory map
and `kernel.elf`'s extents. **m1-interrupts' 544 bytes are byte-for-byte identical**, and so are
m0-boot's, mb-info's and m2-console's: `fatInit()` prints nothing.

---

## 9. What this is NOT

Stated here as well as in GAP-0116, because it would be easy to oversell.

* **No writes.** `WRITE SECTORS` (0x30) is not implemented, there is no allocator, no free-space
  management, no directory update and no crash consistency. The harness greps for an ATA write opcode,
  for any `port_outw` aimed anywhere but the framebuffer's VBE pair, and for a write function by name.
* **No subdirectories.** `SUB` is on the volume, with real `.` and `..` entries, so that "a
  subdirectory is refused" is a boot rather than a claim.
* **No long filenames, no timestamps, no ownership, no permissions.**
* **One volume, one device, one open file at a time.** The chain array holds one file's chain.
* **One partition, and it is the whole disk.** The MBR is still unread (GAP-0090 item 6).
* **The largest file this has ever been tested on is 9632 bytes, ten clusters.** The 256-cluster bound
  is a refusal with its own sentence, and it has never been reached by a test.
