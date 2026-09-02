# The oscortex namespace — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered, nothing implemented.** Companion to
`docs/design/display-protocol.md`, which asks the question this document answers (its §2.4 and its
Q1). When a piece is built it gets its own numbered ADR; this file is the thing those ADRs will point
back at.

**Everything here is a proposal.** Where I checked something against the source I cite `file:line`.
Where I am unsure I say so and give the options rather than picking silently. **One thing in
`known-gaps.md` turned out to be wrong when I checked it against the code, and §3.1 says which.**

### The five things this recommends, for a reader in a hurry

| | recommendation | where |
|---|---|---|
| **The immediate question** | **The idea is right and the location is a trap.** One reserved name, no new syscall — but the branch belongs in `fileSysOpen` (`file.dart:1360`), **not** in `fatLookup` (`fat.dart:1507`). `fatLookup` has four callers and two of them would be handed a device by accident; one of those two **writes to the volume**. | §1 |
| **The general shape** | **Two name spaces that never overlap, not one tree.** A flat, immutable, kernel-declared device table, disjoint from the volume's names *by construction*. Plan 9's file-server *interface* without Plan 9's per-process *namespace* — the second one needs `fork`, and `fork` does not exist. | §2 |
| **Paths** | **Not now, and the device sigil is chosen specifically so that display never needs them.** A named trigger condition instead of a date. The cost is not the grammar; it is that a FAT directory entry stores **size 0** for a directory, so `fatBuildChain`'s length-agreement check — the whole integrity argument of ADR-0018 — has no input. | §3 |
| **The table** | **The table is constant, so it is `@rodata`; the only mutable thing is a session, and sessions live in the descriptor table that already exists.** Names are one `N × 11` byte blob indexed by arithmetic, exactly as `userCodeLen` (`user.dart:1220`) indexes `userCodeSizes`. Handlers are an `if`-chain that *calls*, never one that *returns constants* — that distinction is the whole of GAP-0088. | §4 |
| **Dispatch** | **Add a third descriptor state and the default behaviour of every existing path is refusal.** `fileFdDev = 3` is refused by `read`, `fdwrite` and `seek` today, with **no line changed**, because every one of those tests is `!= fileFdOpen` or `!= fileFdWrite`. Four one-line insertions turn refusal into routing. | §5 |

**And the finding that surprised me most**, which is not about display at all:

> **`open("SUB/X.TXT")` does not do what GAP-0122 item 2 says it does.** The entry says it is
> `fileRetBadName` "because `/` is not a character an 8.3 name may contain here." It is not.
> `fatParseAt` (`fat.dart:1423`) accepts every byte in `0x21..0x7E` except `.`, and `/` is `0x2F`.
> The name parses to `SUB/X   TXT` and gets `fileRetNotFound`. The entry is right about the **write**
> path — `fatNameByteBad` (`fat.dart:2074`) forbids `0x2F` — and wrong about the read path.
> **`/` is not rejected by the grammar today; it is silently folded into a name**, which is worse
> than rejecting it and is §3's real starting point.

---

## 0. What this has to be true of

Five properties of this machine, not tastes. Every recommendation below is downstream of them.

1. **There is one store, and it is the whole disk.** One partition (GAP-0116 item 7), one device
   (item 8), one filesystem driver. A mount table today would have exactly one entry.
2. **There is no `fork` and no `exec`.** GAP-0141. Five descriptor rows, and nothing that can make
   two of them differ in what they can name.
3. **There is no `String`, no array type, no function pointer, no `switch` and no `&&`.** Everything
   in §4 has to be built out of `@rodata` byte tables, pointer arithmetic and chains of single-test
   `if`s. This is not a hardship, it is the shape every table in this kernel already has.
4. **`open`/`read`/`fdwrite`/`close`/`seek` are the most heavily verified code in this kernel.** Two
   pointer validators, eleven refusals above one floor, teardown on the fault path, and a mutation
   round each at M15 and M16. Anything that reuses them inherits all of it; anything that does not
   has to re-earn it.
5. **NOTHING CAN BLOCK.** GAP-0097/GAP-0141. A device `read` that has nothing to say returns 0 and
   returns immediately. This is display-protocol §2.2's constraint and it is the namespace's too.

---

## 1. THE IMMEDIATE QUESTION: is one branch in `fatLookup` the right first step?

`display-protocol.md` §2.4 proposes that `open("WSYS")` return a session to the compositor, and that
the narrowest version of that is *"`fatLookup` gains one branch that recognises a single reserved
name before it touches the volume."*

**The idea is right. The location is a trap, and it is a trap with a volume-corrupting path in it.**

### 1.1 What the idea gets right, and it is most of the argument

§2.4's arithmetic is correct and I want to restate it before I disagree with the second half:
a reserved name buys **open, read, write, close, the refusal floor, both pointer validators, the
four-descriptor budget, and teardown on the fault path** for the cost of one name. A dedicated
syscall buys the transport and none of the rest. §1.4 costs that alternative properly. **Nothing
below is an argument for a syscall; it is an argument about which function the branch goes in.**

### 1.2 `fatLookup` has four callers and only one of them wants a device

I checked. `fatLookup` is reached from:

| caller | via | what a reserved name would mean there |
|---|---|---|
| `fileSysOpen` read path (`file.dart:1393`) | direct | **the one we want** |
| `fileMakeEmpty` (`file.dart:1043`) | direct, from `open(name, O_WRITE)` | **see §1.3 — this is the dangerous one** |
| `shellFatCat` (`fat.dart:2588`) | `fatOpen` → `fatOpenAt` | `cat WSYS` would try to print a compositor |
| `shellElfRunName` (`elf.dart:1810`) | `fatOpenAt` | `run WSYS` would hand the ELF loader a device |

Three of those four have no business knowing that devices exist. Two of them are shell commands whose
byte-exact goldens are asserted by five harnesses.

### 1.3 The write path is not merely wrong, it writes

This is the part that makes it a trap rather than a layering complaint.

`fileMakeEmpty` (`file.dart:1042`) calls `fatLookup` and then interprets the result:

* `fatErrNotFound` → create a directory entry;
* `fatErrOk` or `fatErrEmpty` → **"THE ENTRY IS THERE"**, and it then reads `fatMetaFileEntry` and
  `fatMetaFileFirst` out of `fat_store` and calls `fatTruncate(first)` and `fatDirWrite(entry, 0, 0)`.

A branch in `fatLookup` that returns `fatErrOk` for a device must leave *something* in those two
metadata words. Whatever it leaves, `open(":WSYS", O_WRITE)` from ring 3 then **truncates a cluster
chain and rewrites a root-directory entry at that index**. That is a ring-3-reachable volume
corruption behind one syscall, produced by a branch whose author was thinking about display.

Returning `fatErrNotFound` for a device instead is worse: `open("WSYS", O_WRITE)` then **creates a
real file called `WSYS` on the volume**, which the next boot's device branch shadows. The volume now
contains a permanently unreachable file.

There is no return value from `fatLookup` that is safe for all four callers, because the four callers
disagree about what its return values mean. That is the definition of the wrong layer.

### 1.4 Two more reasons, smaller but real

**The invariant.** `fatLookup` ending in success means *the chain array in `fat_store` describes this
file*, and `fatSetMeta(fatMetaOpen, 1)` is the flag that says so. `elf.dart:1156` reads
`fatOpenActive()` to decide whether the loader fetches sectors through the chain or contiguously.
A device has no chain, no first cluster and no size. Setting `fatMetaOpen` for one makes
`fatFileSector` (`fat.dart:1318`) return garbage to whoever asks next; not setting it makes
`fatLookup` return success while its documented postcondition is false.

**The seam.** `fat.dart` is one filesystem driver, and `m14-fat/run.sh` counts its `@bss` call sites
and asserts the four-region layout of `fat_store`. A device concept inside it either needs new state
in `fat_store` — moving `.bss` accounting in every harness that subtracts it — or reaches outside the
seam, which the harness fails by construction.

**And the analogy in §2.4 cuts the other way.** ADR-0029 added *one port primitive* rather than
inline assembly — at the layer that owns ports. A reserved name in `fatLookup` is one name added at
the layer that owns FAT16. The narrowness is right; the address is wrong.

### 1.5 Where it goes instead, which is still one branch

`fileSysOpen` (`file.dart:1328`) already does, in this order:

```
   mode check → len check → elfOwns(ptr, len) → copy the bytes into the bounce buffer
   → fatParseAt(buf, len)          ← file.dart:1360
```

**The branch goes between the copy and the parse.** At that point:

* the caller's pointer has already been validated by `elfOwns` (`elf.dart:1548`);
* the bytes are already **in the kernel**, in `fileBufBase()`, so the device resolver never sees a
  user pointer — ADR-0019 §5's ordering, inherited rather than restated;
* nothing has touched the volume, so a device costs zero disk reads and the harness can prove it by
  bracketing `fatMetaReads`;
* `fatParseAt`, `fatLookup`, `fatOpenAt`, `shellFatCat`, `shellElfRunName` and `fileMakeEmpty` are
  **all unchanged**, and every one of their goldens holds.

It is the same one branch. It costs the same zero syscalls. It leaks into nothing.

### 1.6 The alternative, costed honestly: a dedicated syscall

Worth writing out, because §2.4 flipped its recommendation once and a reader deserves the ledger.

**What a dedicated syscall buys.**

* No name grammar question at all, and therefore no collision question (§2.3 solves that differently
  and more cheaply).
* A **request/reply in one syscall**. Through the file interface a client pays two — `fdwrite` the
  batch, `read` the events. For a compositor that is two syscalls per frame instead of one; at
  60 Hz that is 60 extra `int $0x80` per second, which on this machine is not a number worth
  designing around.
* Freedom from `fileReadMax`/`fileWriteMax` (512 each, `file.dart:300`, `file.dart:310`). Note that
  display-protocol §2.3 has already accepted 512 as the batch size and built batching around it.

**What a dedicated syscall costs, itemised.**

| | cost |
|---|---|
| a **third** pointer-validation site | `fileOwnsRead`/`fileOwnsWrite` are twelve lines each and were written out twice deliberately (`file.dart:752`, `file.dart:916`). A third caller is a third chance to pick the wrong one. M15's mutation round found a validator bug that only a two-page range exposed (GAP-0124) |
| a **session registry that is not the descriptor table** | new `@bss`, a new seam, new call-site counting in a new harness |
| **teardown on the fault path** | `fileReleaseOwner` (`file.dart:667`) runs from `elfTeardown` and `procCleanup`, both of which are fault paths. A bespoke registry has to be wired into both, and a session that leaks on a client crash is exactly the failure a compositor cannot survive |
| **it does not compose** | the second server needs a second syscall, or an opcode multiplexed onto the first — which is an `ioctl`, which is the thing nobody wants and which no amount of naming avoids |
| **a new refusal vocabulary** | eleven refusals above one floor already exist and `oslibc.h` reads all nineteen numbers back out of `file.dart`. A second vocabulary is a second floor to get wrong |

**Recommendation: the reserved name, in `fileSysOpen`.** The syscall's only real advantage is the
single-syscall round trip, and this OS pays two syscalls for a frame far more cheaply than it pays
for a second copy of the pointer rule.

### 1.7 One thing the file interface gives the display protocol that a syscall would not

`fileFdOpen` and `fileFdWrite` are **mutually exclusive** states and there is no read-write descriptor
on this machine (GAP-0127 item 2). A display session needs both directions on one descriptor.

A device descriptor is state 3 — neither of those — so it is **the first read-write descriptor this
kernel has ever had, and that is legitimate precisely because it is not a file.** The reason `open`
refuses a read-write *file* is the FAT write path's append-only invariant (ADR-0020 §0); none of that
applies to a session. Worth saying out loud in the ADR that builds it, because "the rule we spent M16
enforcing does not apply here" is the kind of sentence that has to be argued rather than assumed.

**Which mode does the client pass?** Recommendation: the device table declares each device's
directionality, and a duplex device accepts **mode 0 only** — one spelling, so there is no question
of what `open(":WSYS", O_WRITE)` means. Anything else is `fileRetBadMode`, refused by the table
rather than by the device.

---

## 2. THE GENERAL SHAPE: what this OS actually wants

Four candidates were named. Taking them in order of how badly they fit.

### 2.1 Not a Unix mount tree

A mount tree's value is that **heterogeneous stores appear under one root**. This machine has one
store: one partition, which is the whole disk and whose MBR is overwritten by the boot sector
(GAP-0116 item 7); one drive, primary master (item 8); one filesystem.

A mount table today would be a data structure with exactly one entry, and it would cost the entire
path grammar of §3 to express the one thing it can say. The day there is a second filesystem — a
ramdisk, a second partition, a network store — this becomes a real question. It is not one now, and
building it now means building the expensive half (paths) to enable the cheap half (a table).

### 2.2 Not, *yet*, a Plan 9 per-process namespace — and the reason is precise

I want to be careful here, because the brief is right that Plan 9's model is unusually well matched to
an OS whose IPC wants to be file-shaped. **Two separate ideas travel under the name "Plan 9" and this
OS wants exactly one of them.**

**Idea one: a server is reached through `open`/`read`/`write`/`close` and nothing else.** This is
right, it is free here, and it is what §1 recommends adopting. It is the idea that makes `/dev/draw`
a display protocol rather than a display API, and display-protocol §1.3 already took the drawing-verb
half of it.

**Idea two: each process has its own mutable name-to-server mapping, built with `bind` and `mount`
and inherited across `rfork`.** This is the one that does not fit, and the reason is not that it is
big — it is that **its entire value is per-process difference, and nothing here can produce one.**

* Namespaces differ because they are *inherited and then modified*. `rfork(RFNAMEG)` gives a child a
  private copy; the child rebinds; parent and child now see different worlds. **There is no `fork` and
  no `exec` on this machine** (GAP-0141), and `proc run` creates two slots from the shell with no
  parent-child relationship at all.
* So all five descriptor rows would hold identical tables, forever, by construction. That is a global
  table wearing a per-process costume, plus two syscalls (`bind`, `mount`), plus a mutable per-row
  table in `@bss`, plus a resolution walk — to express "everybody sees the same thing."
* And the per-process table would have to be *reset* somewhere, on the fault path, exactly as
  `fileReleaseOwner` resets descriptors. That is real work with no observable consequence.

**Take the interface, leave the namespace.** And name the condition under which the second idea
becomes worth building, so that nobody has to re-derive it: **when there is a `spawn` or a `fork`
AND a reason for two processes to see different sets of names.** The obvious first reason is
sandboxing — a client that can name `:WSYS` and nothing else — and that is a real want, but it is a
want that arrives with D3 (display-protocol §6) and not before.

### 2.3 Not a flat device table *merged into* the volume's names — two name spaces, disjoint

This is the recommendation and it is a slightly different thing from "a flat device table."

The naive flat table asks a question at every `open`: **does the device table win, or does the
volume?** Every answer is bad.

* *Devices first:* a file called `WSYS` on the volume becomes permanently unreachable, and nothing
  tells anyone. `fatDirCreate` will happily make one.
* *Volume first:* anyone who can write a file to the volume can shadow the compositor. On an OS with
  no permissions (GAP-0116 item 4) that is anyone.
* *Refuse the collision:* now `open` has a refusal whose cause is on the disk, and the volume has a
  name that cannot be created, and `fatDirCreate` has to learn about devices — §1.2's problem again.

**Delete the question instead.** Make the two name spaces disjoint *by construction*: a device name
begins with a byte that **a FAT16 short name may not contain**, so no volume this kernel can write —
and no volume any conforming formatter can write — can hold a colliding name.

`fatNameByteBad` (`fat.dart:2074`) already enumerates the fifteen forbidden bytes:
`" * + , . / : ; < = > ? [ \ ] |`. Any of them works. **Recommendation: a leading `:` —
`open(":WSYS")`.**

Why `:` and not the two obvious alternatives:

* **Not `#`** (Plan 9's own device sigil). `#` is `0x23` and is **legal** in a FAT short name, so
  `#WSYS` is a file `fatDirCreate` can create. It fails the one test the sigil exists to pass.
* **Not `/`.** It is forbidden in FAT, so it passes that test — but it is the one byte that §3's
  eventual path grammar needs. If devices are `/WSYS`, then the day paths exist `/WSYS` means "the
  root directory's entry `WSYS`", and the collision is back with interest.
* **`:` is forbidden in FAT, will never be a path separator in any grammar this OS would adopt, and
  has forty years of "this is a device, not a file" behind it** (`CON:`, `DF0:`, `SYS:`).

**Leading rather than trailing**, because byte 0 is the whole test: one comparison, decided before
anything is copied, parsed or normalised. A trailing sigil requires knowing the length first.

**What the sigil costs:** one character in a C string literal. `":WSYS"` is 5 bytes, and
`fileNameMax` is 12 (`file.dart:304`), so nothing moves. `fatParseAt`'s grammar is **completely
untouched** — the sigil is tested and consumed in `fileSysOpen` before the parser is called, so the
8.3 parser never sees a byte it does not already accept. That is what makes this cheaper than the
alternative rather than more expensive.

**The decision that has to be taken now is the smaller one:** *reserved names are distinguishable
from disk names by their first byte.* Which byte is a revisable detail. That the two spaces are
disjoint is not.

### 2.4 So: the shape, in one paragraph

**A flat, immutable, kernel-declared device table, in its own file, whose names are disjoint from the
volume's by construction, resolved in exactly one function that takes the owner row as an argument.**
The row argument is not speculative — `devOpen` needs it to record the session — and it is also
precisely the hook a per-process namespace attaches to on the day §2.2's condition is met, because
per-process resolution is then a filter on a function that already knows whose process is asking.

---

## 3. PATHS

### 3.1 What `/` does today, which is not what the gap entry says

**GAP-0122 item 2 is wrong on the read path and right on the write path, and the error is worth
correcting because it makes the current state sound safer than it is.**

The entry says `open("SUB/X.TXT")` is `fileRetBadName` "because `/` is not a character an 8.3 name may
contain here." Reading `fatParseAt` (`fat.dart:1423`): it refuses `c < 0x21`, refuses `c > 0x7E`,
treats `0x2E` as the dot, and **upper-cases and stores everything else**. `/` is `0x2F`. So
`SUB/X.TXT` parses cleanly into the 11 bytes `SUB/X   TXT`, `fatLookup` does not find it, and the
program gets **`fileRetNotFound`**.

On the write path the entry is correct: `fatDirCreate` calls `fatNameLegal` (`fat.dart:2047`), which
calls `fatNameByteBad`, which forbids `0x2F` — so `open("SUB/X.TXT", O_WRITE)` really is
`fileRetBadName`. GAP-0117 already records that the read-side parser does not enforce FAT's forbidden
set and calls it "harmless *here*". It is harmless in the sense that the lookup cannot succeed. It is
not harmless in the sense the gap entry implies, because **the refusal a program sees for a path is
"no such file", which is exactly the refusal that invites a retry rather than a fix.**

**The first thing any path work must do is make the parser refuse `/` explicitly**, so that "this OS
has no paths" is a sentence the kernel says rather than one a failed lookup implies. That is one
`if` and it is worth doing whether or not paths ever arrive.

### 3.2 What breaks when `/` becomes meaningful

| what | why |
|---|---|
| `fileNameMax = 12` | it is exactly `12345678.123`. Any path needs a new bound, a new refusal boundary, and `oslibc.h`'s `FILE_NAME_MAX` moves — a number the harness reads back out of `file.dart` |
| `elfOwns` on the name pointer | `fileSysOpen` validates the name with `elfOwns` (`elf.dart:1548`), which refuses `len > 128`. A path bound above 128 needs a different validator, i.e. a fourth caller of the pointer rule |
| the bounce buffer | the name is copied into `fileBufBase()` — 512 bytes, shared with `read` and `fdwrite` data. A long path is fine there; a path *plus* a component-at-a-time normalisation is a second buffer |
| `fatParseAt`'s single-name contract | it fills an 11-byte buffer in `fat_store`. Path resolution needs to fill it once per component, which means the *caller* loops and `fat_store`'s name buffer is live across a directory read |
| `shellStrHelp` | any new shell command (`cd`, `ls <dir>`) moves the help text, which moves five harnesses' byte-exact goldens. M19 paid this for one line; it is a known, budgetable cost, not a surprise |
| `m14-fat`'s `SUB` | the volume carries a real `SUB` directory with real `.` and `..` entries **solely so that `fatErrIsDir` is produced by a boot** (GAP-0116 item 2). The day `SUB` is openable, that refusal has no producer and three harnesses' expectations change |

### 3.3 What a subdirectory costs inside `fat.dart` — and it is not the code

The brief's framing is exactly right and worth sharpening: **`fat.dart` can walk any cluster chain
today and refuses a directory by name.** `fatLookup` finds the entry, reads the `0x10` attribute, and
returns `fatErrIsDir` (`fat.dart:1547`). The chain machinery does not care what the clusters hold.

So why is this not a small change? Four reasons, and the third is the real one.

**1. Directory traversal is hardwired to the root region, arithmetically.**
`fatDirEntry(i)` (`fat.dart:1360`) is:

```
   lba = fatMeta(fatMetaRootStart) + (i >> 4)
```

The FAT16 root directory is a **fixed, contiguous region** with a known entry count
(`fatMetaRootEntries`). A subdirectory is a **cluster chain** whose entries live at
`dataStart + (c - 2) * spc + k`. Every one of `fatLookup`, `shellFatLs` (`fat.dart:2513`),
`fatDirWrite`, `fatDirFreeSlot`, `fatDirTerminate` and `fatDirCreate` indexes through that one
arithmetic function. Generalising it means every directory operation takes a *directory identity*
(a first cluster, or a sentinel meaning "root") instead of nothing.

**2. The one chain array is already a cache of one, and a directory walk evicts a file.**
`fat_store` holds one chain (GAP-0116 item 5), and `fileChainFor` (`file.dart:843`) rebuilds it from
the descriptor's first-cluster and size, counting rebuilds in `fileMetaRebuilds`. Walking a
subdirectory's chain during a lookup evicts whatever chain was there, so an `open` inside a directory
costs **two** chain builds where a root `open` costs one. That is a real cost and it is already
measurable — which is good news: the ladder can assert the number rather than claim the property.

**3. A FAT directory entry stores SIZE 0 for a directory, and `fatBuildChain` cannot work without a
size.** This is the one that turns a refactor into a design decision.

`fatBuildChain(first, bytes)` (`fat.dart:1265`) derives the expected cluster count from `bytes` and
then **requires the chain to agree with it in both directions** — `fatErrChainShort` if an end mark
comes early, `fatErrChainLong` if the link after the last expected cluster is not an end mark. ADR-0018
makes that the centre of its integrity argument: *"a driver that stopped at the end mark and believed
whatever length that produced would read a file whose directory entry and FAT disagree without
noticing that they do."*

**FAT requires `DIR_FileSize` to be 0 for a directory.** There is no length to derive. Fed a
directory's entry, `fatBuildChain` computes `want = 0` and returns `fatErrEmpty` at its first branch.

So subdirectories require a **second chain-walk mode with a strictly weaker invariant** — walk to the
end mark, believe the result, bounded only by `fatChainMax` and the cycle check. That mode is
precisely the one ADR-0018 refused. It is defensible (there is no other way to walk a directory, and
the range/free/bad/cycle checks all still apply), but it must be *argued in an ADR and named in the
code*, not slipped in as a second parameter. **A shared function that sometimes checks the length and
sometimes does not is how the checked path stops being checked.**

**4. A subdirectory grows and the root does not.** `fatDirFreeSlot` returning nothing is
`fatErrNoDirSlot` — a hard refusal, because the root's entry count is fixed. A subdirectory that is
full **allocates another cluster**, so "directory full" stops being a refusal and becomes an
allocation with its own failure mode, its own ordering rules against the FAT, and its own crash
window. That is ADR-0020's five ordering rules applied to a new object.

Plus the small ones: `.` and `..` are real entries with the `0x10` attribute at indices 0 and 1 and
must be skipped or resolved; the descriptor's `fileFdEntry` word is a *root index* today and would
have to become a (directory cluster, index) pair — `fileFdSpare7` exists for exactly this.

### 3.4 Recommendation: not now, with a named trigger

**Nothing in the display protocol needs a path, and §2.3's sigil is chosen so that it never will.**
The volume currently holds tens of files in a 512-entry root.

**The trigger condition is either of:** a second filesystem or store exists (so there is somewhere for
a mount point to lead), **or** the root directory's entry count becomes a real bound. Neither is close.

**And do the one-line piece now anyway:** make `fatParseAt` refuse `0x2F` explicitly, so the kernel
says "this is not a name" instead of "there is no such file". §3.1.

---

## 4. THE DEVICE TABLE, with no arrays, no `String` and no function pointers

This is the part the brief calls the hard part. I think it is the easy part once one observation is
made, and the observation is worth stating before the mechanics:

> **The table is constant, so it needs no mutable storage at all. The only mutable thing in the whole
> design is a session, and a session already has somewhere to live: the descriptor table.**

Everything below follows from that. There is no device `@bss` block, no seam to count, no `.bss`
accounting to move in eleven harnesses.

### 4.1 Names: one `@rodata` blob, indexed by arithmetic

DCDart has no array type, but `@rodata final List<u8>` plus `Rodata.addressOf` plus pointer arithmetic
is an indexable table, and this kernel already does exactly that. `userCodeLen` (`user.dart:1220`) is
the precedent, and it exists *because* GAP-0088 required the table LLVM wanted to synthesise to be
written out by hand:

```dart
  return Pointer<u8>.fromAddress(Rodata.addressOf(userCodeSizes) + mode).value.toU64();
```

So:

```dart
/// How many devices exist. The bound on every index below.
const int devCount = 2;

/// The longest device name, not counting the sigil.
const int devNameMax = 11;

/// `devCount` fixed-width records of `devNameMax` bytes, space-padded, upper
/// case. `':NULL'` is `'NULL' + 7 spaces`. 22 bytes.
@rodata
final List<u8> devNames = const [
  u8(0x4E), u8(0x55), u8(0x4C), u8(0x4C), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x5A), u8(0x45), u8(0x52), u8(0x4F), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
];

/// The real length of each name. Parallel to [devNames]. 2 bytes.
@rodata
final List<u8> devNameLens = const [ u8(4), u8(4) ];
```

Fixed-width records mean the address of record `i` is `base + i * devNameMax` — one multiply, the
same shape `fileFd(row, fd, w)` already uses to index the descriptor table.

**Structural criterion, before any boot:** `sizeof(devNames) == devCount * devNameMax` and
`sizeof(devNameLens) == devCount`, read out of `kmain.o` by the harness. That is ADR-0040/GAP-0060's
discipline — a `@rodata` table carries no length, so the byte count at the call site is checked
against the symbol's real size — applied from the start rather than retrofitted.

### 4.2 Resolution: exact bytes, no second grammar

```dart
/// The device index for the `len` bytes at `addr`, or [devCount] for none.
/// [addr] is a KERNEL address: `fileSysOpen` has already validated the user
/// pointer and copied the bytes into the bounce buffer.
@bare
u64 devLookup(u64 addr, u64 len) { ... }
```

Two nested loops and a byte compare — `shellMatch` (`shell.dart:898`) generalised over an index.

**No normalisation, no upper-casing, no 8.3 parsing.** Exact length, exact bytes. ADR-0019 §3 argued
hard against a second copy of the 8.3 parser, and it was right; the answer here is not to share the
parser but to **not have a grammar at all**. A device name is an opaque byte string of a known length
and there is nothing for two copies to disagree about. Lower case simply does not match, which is
correct and which the shell cannot produce anyway (GAP-0055).

Sharing `fatParseAt` here would be actively wrong for a second reason: it writes into `fat_store`'s
name buffer, so a device resolution would scribble on the filesystem's state to look up something
that is not on the filesystem.

### 4.3 Per-device attributes: parallel tables, one per column

There are no structs in signatures (GAP-0025), so a struct-of-arrays is what is expressible — and it
is indexable with the one mechanism §4.1 uses:

```dart
/// Bit 0: readable. Bit 1: writable. Bit 2: duplex — one descriptor, both
/// directions, and mode must be 0 (§1.7). Parallel to [devNames].
@rodata
final List<u8> devFlags = const [ u8(0x03), u8(0x01) ];
```

Every attribute a device has that is *fixed at build time* is a byte in a parallel table:
directionality, whether more than one session is allowed, the fixed record size a `read` delivers.
Every one of them gets the same `sizeof == devCount` structural assertion.

**This is where the mode check moves.** §1.7's "a duplex device accepts mode 0 only" is a test against
`devFlags`, in one place, for every device — not a rule each device re-implements.

### 4.4 Handlers: an `if`-chain that CALLS, never one that RETURNS CONSTANTS

The brief's "no function pointers" is the real constraint, and the answer is the shape
`userSyscall` (`user.dart:1529`) already has — a ten-way chain of `if (no == X) { f(frame); return; }`:

```dart
@bare
void devRead(u64 frame, u64 row, u64 fd) {
  final u64 d = fileFd(row, fd, u64(fileFdFirst));   // the device index
  if (d == u64(devNull))  { devNullRead(frame, row, fd);  return; }
  if (d == u64(devZero))  { devZeroRead(frame, row, fd);  return; }
  fileRefuse(frame, u64(fileRetBadFd));
}
```

Three such chains (`devOpen`, `devRead`, `devWrite`) plus one for `devClose`. `devCount` arms each.

**GAP-0088 does not bite here, and it is worth being precise about why, because the gap entry is
usually cited as "dense `if`-chains are dangerous" and that is not what it says.** Both recorded
incidents — `pmmFreeStatus` (GAP-0079) and `userCodeLen` (GAP-0088) — are chains that **return
constants**, which LLVM lowers to a data table in a section this repo does not control. `userSyscall`
is a dense chain that **calls functions** and has never produced one across ten arms.

**So the rule, stated once and applied everywhere in this design:** *constants live in explicit
`@rodata` tables; control flow lives in `if`-chains that call.* §4.1 and §4.3 are the first half;
§4.4 is the second. And `m1-interrupts/run.sh`'s existing assertion — every `OBJECT` symbol `dcc`
emits lives in `.rodata`'s section index — remains the tripwire if the backend ever disagrees.

### 4.5 Mutable state: there is none, at this layer

The table is `@rodata`. A **session** is mutable, and it lives in the descriptor row that
`fileOwnerRow` (`file.dart:648`) already selects:

| descriptor word | file meaning | device meaning |
|---|---|---|
| `fileFdState` (0) | 1 = read, 2 = write | **3 = device** |
| `fileFdFirst` (1) | first cluster | **device index** |
| `fileFdSize` (2) | file size | **session handle**, if the device has more than one |
| `fileFdPos` (3) | offset | **per-session cursor**, if the device wants one |
| `fileFdEntry` (4), `fileFdLast` (5), `fileFdAlloc` (6), `fileFdSpare7` (7) | write bookkeeping | **free for the device** |

Eight words per descriptor, four per row, already zeroed by `fileClearFd` and already released on the
fault path. **A device that needs no more than four words of per-session state needs no new storage
in this kernel at all.** A device that needs more — the compositor will — declares its own `@bss`
block in its own file behind its own accessor, ADR-0021's pattern, and keys it by the session handle
in `fileFdSize`. That is the compositor's storage seam and not the namespace's.

**Counters.** `file.dart:351` begins fifteen declared spare metadata words and a rule attached to them:
*"THERE IS NO WORD HERE THAT NOTHING READS."* Device opens, reads and writes take three of the spares
and **must be printed** by `fileExitReport` or `fileWriteReport`, or M14's mutation finding applies
(GAP-0120: an unread counter is a mutation survivor by construction).

### 4.6 Discoverability

`ls` enumerates the volume and is ring-0 code (GAP-0122 item 2). It should **not** learn about
devices — that is §2.3's disjointness surviving into the shell.

A one-line `devs` command that prints the table is worth it (GAP-0115: a capability not in `help` is
undiscoverable), and it has a side benefit: **the table's contents become assertable from a byte-exact
golden**, which is a stronger check on `devNames` than any structural grep. The cost is known and
budgetable — `shellStrHelp` grows and five harnesses' goldens move, exactly as M19 paid for one line.

---

## 5. HOW DESCRIPTORS ROUTE

`fileSysRead` (`file.dart:1429`) assumes a FAT file. Here is what dispatch looks like, and the point
of this section is how little of it is new.

### 5.1 The property to exploit: adding a state is refusal everywhere, for free

Every existing test on `fileFdState` is one of two shapes:

* `state < fileFdOpen` → "nothing is open here" → `fileRetBadFd`;
* `state != fileFdOpen` (read, seek) or `state != fileFdWrite` (write) → `fileRetBadMode`.

`file.dart:406` says this was deliberate: *"a different value rather than a flag word, so that every
`state >= fileFdOpen` test in this file keeps meaning 'there is a file here'."*

So `const int fileFdDev = 3;` — **with no other line changed** — produces a descriptor that `read`,
`fdwrite` and `seek` all refuse with `fileRetBadMode`, that `close` accepts and releases, and that
`fileFlushFd` (`file.dart:1008`) already leaves alone because its first test is
`!= fileFdWrite`.

**That is a milestone on its own** (§6, N1's first half): the default behaviour of the new state is
refusal, and it can be asserted before any device does anything.

### 5.2 Four insertions turn refusal into routing

**`fileSysOpen`** — one branch, `file.dart:1360`, between the copy and `fatParseAt`:

```dart
  if (Pointer<u8>.fromAddress(buf).value == u8(devSigil)) {
    devSysOpen(frame, row, buf + u64(1), len - u64(1), mode);
    return;
  }
```

`devSysOpen` allocates the descriptor with `fileFreeFd` — the same four-slot budget, the same
`fileRetNoSlot` — sets state 3 and the device index, bumps `fileMetaOpens` and `fileMetaLive`, and
returns the fd. A device that refuses (unknown name, wrong mode, no session available) refuses through
`fileRefuse`, at the same floor, and is counted in `fileMetaRefusals` like everything else.

**`fileSysRead`** — one branch, placed **after** the fd checks, the length checks and
`fileOwnsWrite(dst, len)`, and before `fileChainFor`:

```dart
  if (state == u64(fileFdDev)) { devRead(frame, row, fd); return; }
```

**The placement is the whole safety argument.** Below that line the pointer has been validated by
the same validator, and the device handler delivers its bytes by filling `fileBufBase()` and calling
`fileCopyOut(dst + done, off, n)` — so **`fileCopyOut` remains the only store to a caller-supplied
address in `file.dart`**, and M15's structural assertion that counts exactly one such site
(ADR-0019 §5, verification 1) holds **unchanged**. A device that copied to `dst` itself would break
that count, and the harness would say so before a boot.

**`fileSysWrite`** — one branch, after `fileCopyIn(src, len)`:

```dart
  if (state == u64(fileFdDev)) { devWrite(frame, row, fd, len); return; }
```

Same argument in the other direction: the bytes are already in the kernel's bounce buffer, validated
by `fileOwnsRead`, so **no device handler ever sees a ring-3 address.** ADR-0020's ordering, inherited
rather than restated.

**`fileSysClose` and `fileReleaseOwner`** — one branch each:

```dart
  if (state == u64(fileFdDev)) { devClose(row, fd); }
```

`fileReleaseOwner` (`file.dart:667`) is the important one and it is why §1.6's ledger comes out the
way it does: **it runs on the fault path**, from `elfTeardown` and `procCleanup`. A client that
crashes with a display session open has that session released, and prints `FILE ORPHANS 01` while
doing it. Nothing new has to be built for that, and it is the single most valuable thing the
descriptor table gives a compositor.

**`fileSysSeek` — nothing.** It refuses state 3 today with `fileRetBadMode`, which is correct: a
device has no offset. Leave it.

### 5.3 What `read` returning 0 means on a device

For a file, 0 is end of file. For a device it is **"nothing right now"**, which is exactly
display-protocol §2.2's non-blocking contract:

```c
   while (read(fd, ev, sizeof ev) == 0) yield();
```

There is no ambiguity to resolve, because a device never ends. Worth writing into the ADR anyway,
because it is the one place where the file interface's vocabulary means something different on the
other side of the dispatch.

**One rule that must be stated before the first queue-shaped device:** a `read` delivers **whole
records or nothing**. A partial event record is unrecoverable by a client that has no way to ask for
the rest, and a `len` below one record is `fileRetBadLen` rather than a short read. §6's N4 asserts
both halves.

### 5.4 One new refusal

`fileRetNoDev = 0xFFFFFFFFFFFFFFF1` — the next value below `fileRetNoSpace` — for a sigil-prefixed
name that is not in the table. It has to be distinct from `fileRetNotFound`: "there is no such device"
and "there is no such file" send a program to two different places, and the sigil is exactly what
makes them distinguishable without a lookup. `oslibc.h` gains `FILE_ENODEV` and the harness reads the
number back out of `file.dart` with the other nineteen.

---

## 6. THE MILESTONE LADDER

Written to this repo's rules for a derived expectation, restated here because display-protocol §6
restated them and the next agent has to follow them either way: compute the expectation from a source
the kernel does not control; restate the kernel's rules in the harness rather than importing them;
assert every copied constant against the kernel's source; **guard against a vacuous pass**; structural
checks before boot checks; and a negative control that must fail.

Smallest first. **N1 and N2 together are smaller than D1.**

---

### N1 — A name that is not on the volume opens, and nothing else changes

**Blocked on: work only.** Touches `file.dart` (five insertions, §5.2) and one new `dev.dart`.
Independent of the entire display ladder.

The sigil test, `devLookup`, the `@rodata` tables, and **one device: `:NULL`.** Read returns 0
forever; write accepts and discards. Chosen first because its semantics are unarguable, it depends on
no other subsystem, and it exercises open/read/write/close on a non-file end to end.

**Structural, before boot:** `sizeof(devNames) == devCount * devNameMax`; `sizeof(devNameLens) ==
sizeof(devFlags) == devCount`; the store-to-caller-address count in `file.dart` is **still exactly
one**; `devSigil` is a byte `fatNameByteBad` forbids, asserted by reading both constants out of the
source; `devLookup` is reached from exactly one place.

*Binary:* a ring-3 program opens `:NULL` and gets fd 0; `read(fd, buf, 512)` returns exactly 0;
`fdwrite(fd, buf, 512)` returns exactly 512; `close` returns 0; `seek` returns `FILE_EBADMODE`;
`open(":NOPE")` returns `FILE_ENODEV`; `open("NULL")` returns `FILE_ENOTFOUND`. And the one that makes
it a *namespace* milestone rather than a stub: **`fatMetaReads` and `fatMetaWrites` are identical
before and after the whole sequence**, derived from a boot of the same program with the device calls
removed — proving the device path touched no disk.

*Anti-vacuity:* the harness fails if the derived expected `fdwrite` count is zero.
*Negative control:* a build with the sigil test removed must fail the first assertion.

---

### N2 — A session survives a client that does not

**Blocked on: N1.**

The milestone that earns §1.6's whole argument. `devClose` from `fileSysClose` **and** from
`fileReleaseOwner`, and a device with exactly one session so that failing to release it is
observable.

*Binary:* a program opens `:NULL`, then faults deliberately — the M15 trick of writing through a
pointer into its own R+X segment, or a `#GP`. The transcript shows the fault line and
`FILE ORPHANS 01`; `pmm`'s free count is identical to its pre-session baseline; and **a second
program then opens the same device and succeeds**, which is what proves the session slot came back on
the fault path rather than on the polite one.

*Negative control:* a build whose `devClose` is a no-op must leave the second `open` refused. Without
that control, a `devClose` that does nothing passes every other assertion — which is precisely the
mutant `fileReleaseOwner` survived at M15 until the test program stopped being polite (GAP-0124).

---

### N3 — Two devices, and the table is what routes

**Blocked on: N1.**

Add `:ZERO`: `read` fills with `0x00`, `fdwrite` is refused by `devFlags`. Now the chain has two arms
and the tables have two rows.

*Binary:* the program reads 512 bytes from `:ZERO` and FNV-1a's them; the hash is computed on the host
over 512 zero bytes. `fdwrite` to `:ZERO` is `FILE_EBADMODE` **from the flags table**, not from the
handler. `read` from `:NULL` is still 0. Both devices are open simultaneously — two of the four
descriptors — and interleaved.

*Negative control, and this is the one worth having:* **swap the two rows of `devNames` and require
the hash assertion to fail.** That is what proves name→index and index→handler are actually connected,
rather than the second device working because the chain happened to fall through to it.

---

### N4 — A device that is a queue, and the read contract that goes with it

**Blocked on: N3, and on display-protocol's D2** (there is no input queue at all today — that ladder's
D2 is the hard prerequisite and it is a different unit's work).

`:KBD`: `read` delivers whole fixed-width event records from D2's ring, or 0.

**This is where the namespace stops being a demonstration.** It is display-protocol §2.2's event
discipline, tested with no compositor, no surfaces and no framebuffer.

*Binary:* N keystrokes injected at 50 ms intervals; the program reads back **exactly** the derived
sequence, in order, none lost, none partial. A `read` with `len` below one record size is
`FILE_EBADLEN` and **consumes nothing** — asserted by the next read returning the record that was
there. A `read` with `len` of 2.5 records delivers exactly 2.
*Negative control:* a build whose `read` delivers a partial trailing record must fail the third
assertion.

---

### N5 — `:WSYS`, and the display protocol has its transport

**Blocked on: N3, and on display-protocol's D3** (a resident process — there is nowhere for a
compositor to live until it exists).

One duplex device, one session, mode 0 only. **Nothing about the wire format is decided here.** The
criterion is that a batch of bytes goes in and event records come out on one descriptor, and that
closing it releases whatever the server allocated.

*Binary:* the compositor process opens nothing; a client opens `:WSYS`, `fdwrite`s a derived byte
pattern, and the compositor reports having received exactly those bytes in order across two batches
that straddle the 512-byte boundary; the client `read`s and gets a derived event record; the client
exits without closing and the compositor observes the session ending.
*Negative control:* a second client opening `:WSYS` while the first holds it must be refused by its
own refusal, so the single-session rule is sensitive.

---

### N6 — Paths and subdirectories

**Blocked on nothing, and deliberately last.** It is the only item on this ladder that requires
changing the name grammar, adding a second chain-walk mode with a weaker invariant (§3.3), teaching
six directory functions what directory they are in, and moving four harnesses' goldens. **Nothing
above it needs any of that**, and §2.3's sigil exists so that nothing above it ever will.

**Do §3.1's one line now, though**, in whatever milestone is next: make `fatParseAt` refuse `0x2F`
explicitly, and correct GAP-0122 item 2. One `if`, one gap-entry edit, and the kernel stops implying
"no such file" when it means "this OS has no paths."

---

## 7. What I did not decide, and would rather be told

**Q1 — Confirm the location, which is the only thing in §1 that is a real disagreement.** I agree with
display-protocol §2.4 that the reserved name is right and the syscall is wrong. I disagree that the
branch goes in `fatLookup`, and §1.3 is the reason: `fileMakeEmpty` reaches `fatLookup` from
`open(..., O_WRITE)` and would truncate a chain and rewrite a directory entry for a device.
`fileSysOpen` is the same one branch with none of that.

**Q2 — Is a sigil worth one character?** §2.3 recommends `open(":WSYS")` over `open("WSYS")`, on the
grounds that a byte FAT forbids makes the two name spaces disjoint by construction and deletes the
entire shadowing question. The cost is one character and one comparison. **The decision that matters
is "distinguishable by the first byte"; which byte is a detail I would happily be overruled on.**

**Q3 — Should a device be visible to the shell at all?** §4.6 proposes a `devs` command and *no*
change to `ls`. The `devs` command costs five harnesses' goldens (`shellStrHelp` grows), which is a
real, budgetable price for discoverability. It also makes the table assertable from a byte-exact
golden, which is worth more than the grep it replaces.

**Q4 — Per-process namespaces: is the trigger condition in §2.2 the right one?** I have proposed
building none of it until there is a `spawn`/`fork` **and** a reason for two processes to see
different names — with sandboxing a display client as the first plausible reason. The counter-argument
is that resolution is much easier to make per-process on the day it is written than on the day it is
retrofitted. **My mitigation is to give `devLookup`/`devSysOpen` the owner row as an argument from the
first line** — which they need anyway for session accounting, so it costs nothing and is where a
future filter attaches.

---

## 8. Notes for the coordinator to fold in elsewhere

**A correction to `known-gaps.md`, checked against the code rather than repeated on trust.**
GAP-0122 item 2 says `open("SUB/X.TXT")` is `fileRetBadName` because `/` is not a legal character.
On the **read** path that is false: `fatParseAt` (`fat.dart:1423`) accepts `0x2F`, folds it into the
11-byte name, and the program gets `fileRetNotFound`. On the **write** path it is true, via
`fatNameByteBad` (`fat.dart:2074`). GAP-0117 already records the underlying fact — the read-side
parser does not enforce FAT's forbidden set — and calls it "harmless *here*", which it is in the sense
that the lookup cannot succeed and is not in the sense that item 2 implies. The fix is one `if` and a
two-line edit to item 2.

**A hazard that deserves an entry whether or not any of this is built.** `fatLookup`'s return values
mean different things to its four callers, and `fileMakeEmpty` (`file.dart:1042`) turns `fatErrOk`
into *truncate this chain and rewrite this directory entry* using two metadata words the lookup left
behind. Any future change that makes `fatLookup` succeed for something that is not a file on the
volume is a ring-3-reachable volume corruption. That is a property of the code today, not of this
proposal, and nothing currently records it.

**A property worth preserving explicitly in whatever ADR builds §5.** `fileCopyOut` (`file.dart:792`)
is the only store to a caller-supplied address in `file.dart`, and `m15-fileio` **counts** the sites
and requires the count to be 1. §5.2's placement keeps it at 1 by having device handlers fill the
bounce buffer rather than the caller's buffer. A device written the other way passes every functional
test and fails the structural one — which is the harness working, and it should be documented as the
reason for the placement rather than discovered as an obstacle.

**A note for whoever builds display's D3.** §5.1's observation that `fileFdDev = 3` is refused
everywhere by existing code is only true while every state test in `file.dart` keeps its current
shape. `file.dart:406` states that as a deliberate invariant. It is worth asserting: a structural
grep requiring every `fileFdState` comparison to be `< fileFdOpen`, `== fileFdOpen`, `== fileFdWrite`,
`!= fileFdOpen` or `!= fileFdWrite` — and nothing else — would keep it true.

**Three gaps this document is upstream of, and which currently read as filesystem limitations rather
than as the namespace question they are:** GAP-0122 item 2 (no paths, no directories — §3),
GAP-0116 item 2 (no subdirectories — §3.3), and GAP-0116 items 7 and 8 (one partition, one device —
§2.1, which is why a mount tree has nothing to mount).

**What this document does not touch.** `known-gaps.md` and `ROADMAP.md` are unedited, per the same
instruction display-protocol.md was written under. Everything above that belongs in them is in this
section.
