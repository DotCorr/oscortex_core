# ADR-0016 — A growable user heap: `sbrk`, one guard page, and no `free`

**Status:** accepted (M12)
**Date:** 2026-08-22
**Supersedes:** nothing. **Narrows:** GAP-0089 item 5, GAP-0096 item 6.
**Depends on:** ADR-0011 (frame allocator), ADR-0012 (paging, W^X), ADR-0013 (the syscall
boundary), ADR-0014 (the program window), ADR-0015 (processes and two address spaces).

---

## 0. The problem, stated so the scope is obvious

At M11 a process's address space was exactly what its ELF asked for plus one stack page, for the whole
life of the process. There was no `brk`, no `mmap`, and no syscall that returned a page (GAP-0096
item 6).

That is the wall `malloc` is on the wrong side of. `malloc` is not a library problem — every
implementation of it, from `dlmalloc` to `jemalloc`, ends in a call that asks the kernel for more
address space, and a kernel that has no such call cannot host one however good its C library is. So
no real C program can run on M11's machine, and "we will add a libc later" would have been hiding a
kernel gap behind a userland one.

M12 adds the smallest kernel-side thing that removes that wall.

---

## 1. `sbrk`, not `brk`, and not `mmap`

All three were on the table. The decision is `sbrk(increment) -> old break`.

**`mmap` was rejected as an interface this kernel cannot honestly implement yet.** It is six
arguments — address hint, length, protection, flags, file descriptor, offset — and every one of them
implies machinery that does not exist here. `MAP_FIXED` needs a way to say "unmap whatever is there",
`PROT_*` needs per-region permissions, `MAP_ANONYMOUS` vs a file mapping needs a file, and the whole
thing needs a **list of regions** per process so that two mappings can be tracked, split and merged.
This kernel has one page table per process and no region list at all. An `mmap` that accepted only
`(NULL, len, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0)` and refused everything else would be
`sbrk` with five ignored arguments and a misleading name, and the misleading name is the part that
costs later: somebody would write code against the signature rather than against what it does.

**`brk(addr) -> 0 or -1` was rejected as the same thing with a worse first call.** It sets an absolute
break, so a program has to know where its break already is before it can move it — which means either
a second syscall to ask, or a linker-provided `_end` symbol that the program trusts to match what the
kernel actually mapped. The second is exactly the kind of agreement that is right until the day it is
not.

**`sbrk` is one argument in, one value out, and the value out is the base of the memory just
granted** — which is the thing a `malloc` needs and would otherwise have to compute. It is also
naturally monotone, which matches what this implementation actually is (§4).

The refusals are return values rather than a signed `-1`, because `@bare` DCDart has no signed type
(GAP-0023) and neither does the syscall ABI here. `heapRetFloor` is `0xFFFFFFFFFFFFF000`; anything
above it is a refusal, and the program window ends at 258MiB, so no legal break comes within eight
billion of the floor. A program tests with one comparison.

Three distinct refusals, not one:

| value | meaning | reachable |
|---|---|---|
| `0xFFFFFFFFFFFFFFFD` `heapRetNoSpace` | the window has no room left | yes — the test program walks it |
| `0xFFFFFFFFFFFFFFFE` `heapRetBadArg` | an increment larger than the whole window | yes — including `sbrk(-1)`'s bit pattern |
| `0xFFFFFFFFFFFFFFFC` `heapRetNoMem` | the frame allocator ran out part-way | **no boot here reaches it — GAP-0108** |

They are distinct because "the machine is out of memory" and "your address space is full" are
different facts with different remedies, and a program that cannot tell them apart cannot do anything
sensible about either.

---

## 2. Where the heap lives: the existing window, and a guard page

**The address window was NOT extended.** `[vmProgBase, vmProgEnd)` is still 2MiB, still one
page-directory entry, still one page table (ADR-0014). The heap goes in the space that has been
sitting unused inside it since M10:

```
0x10000000  +----------------------------+
            |  the program's PT_LOADs    |   mapped by the loader, p_flags honoured
   elfHi -> +----------------------------+ <- the heap BASE, computed by the loader
            |                            |
            |  the heap, growing up      |   sbrk maps pages here, user + W + NX
            |                            |
     brk -> +----------------------------+
            |  unmapped                  |
0x101FE000  +----------------------------+ <- heapTop == the GUARD PAGE, never mapped
0x101FF000  +----------------------------+
            |  the stack, one page       |   mapped by the loader, W + NX
0x10200000  +----------------------------+
```

**The base is `elfMetaHi`** — one past the highest page the loader mapped, a number the loader
computed from the file's own `p_vaddr`s. Not a constant. `m12-heap/run.sh` recomputes it from the ELF
independently and requires the kernel's first `sbrk(0)` to return exactly that.

**The guard page is the load-bearing part of this section.** The heap stops one page short of the
stack, and that page is never mapped by anything. Without it a heap grown to its limit would abut the
stack page, and a program that overran its stack downward would land in its own heap and corrupt it
silently. With it the overrun is a `#PF` at a page nothing maps, which this kernel already reports and
already tears the process down for. The stack still does not grow (GAP-0096 item 5); the guard is what
makes "it does not grow" a fault rather than a corruption.

**Why not extend the window instead.** A second page-directory entry would have been two more lines
and would have made the exhaustion path untestable in practice: the point of a bounded heap is that
the bound is REACHED by this milestone's own test program, in eight seconds, rather than being a
number nobody ever gets near. m11-proc's harness found a refusal code that no `return` could produce;
a refusal path that no boot can walk is the same failure one step later. 507 pages is a real bound
that a real program hits, and extending the window is a change to make when something needs the
memory, with its own exit criterion.

---

## 3. Permissions: user, writable, NX, and no exception for a guest

Every heap page is mapped `present | user | writable | NX`, through the same `vmProgMap` an ELF
segment goes through. That function refuses `write && exec` by name (`vmProgWx`), so a heap page
cannot be executable even if a future caller asks: ADR-0012 bought W^X for the kernel and ADR-0014
refused to give a guest an exemption from it, and a page the guest can *write at runtime* is precisely
the page an exemption would matter for.

The permissions are not asserted from the source. `m12-heap/run.sh` walks the live page tables out of
guest physical memory, with the process still on the CPU at CPL 3, and reads present/user/W/NX off
every one of the ~500 leaves — and reads the SAME walk against a dump taken from the same binary
stopped two instructions earlier, where every one of those pages is absent.

---

## 4. It is a monotonic page-granular break with no shrink and no reuse, and that is said in its own name

The break only ever moves up. There is no `free`, no shrink, no coalescing, no free list. A process
that grows its heap and stops using it holds those frames until it exits.

**That is a bump pointer.** It is the interface a first `malloc` wants — `malloc` is expected to keep
its own free list on top of it, which is what every real one does — and it is not an allocator.
GAP-0107 is the accounting.

A negative increment is not expressible: RDI arrives as a `u64`, so a C program's `sbrk(-1)` becomes
`0xFFFFFFFFFFFFFFFF`, which is larger than the window and is refused as `heapRetBadArg`. That is
checked by the test program rather than reasoned about.

---

## 5. Failure is atomic, and the order of the checks is the whole argument

```
sbrk(inc):
  inc == 0                -> return the break. NO SIDE EFFECT AT ALL.
  inc > the whole window  -> BADARG.   BEFORE the round-up, which is the addition that overflows.
  round up to pages
  pages don't fit         -> NOSPACE.  BEFORE the first allocFrame, so an impossible request
                                       never touches the allocator.
  for each page:
      allocFrame          -> fail: ROLL BACK every page THIS CALL mapped, then NOMEM.
      vmZeroFrame         -> BEFORE the mapping, not after.
      vmProgMap
  advance the break
  return the OLD break
```

Three of those orderings are correctness requirements rather than preferences, and
`m12-heap/run.sh` reads all four out of the source with a parser rather than trusting this document:

* **the oversize refusal before the round-up.** DCDart traps on arithmetic overflow with a real `ud2`
  (DCDART_SPEC §4.1). `inc + 4095` with `inc = 0xFFFFFFFFFFFFFFFF` would execute that `ud2` *inside a
  syscall handler*, which takes the machine down instead of the request. A ring-3 program must not be
  able to choose which instruction the kernel executes next — the same lesson `userOwns` learned at
  M9, in the same shape.
* **zero before map.** `allocFrame()` hands back whatever the frame last held (GAP-0076 item 5) and
  this kernel recycles frames between processes. Zeroing after the mapping would leave an instant in
  which a page holding a dead process's data is reachable from ring 3.
* **roll back before returning NOMEM.** The break has not moved when the rollback runs, so the pages
  being undone are ones no ring-3 instruction has ever been able to reach. Unmapping them is invisible
  to the program, which is what makes the failure atomic and a retry a clean retry.

---

## 6. The pages come back because the tables are what a teardown is checked against

`heap.dart` contains no teardown code at all, and that is the point.

M11's `procSpaceFree` already walks the process's OWN window page table and frees every present leaf
it finds — rather than a remembered list, because the tables are what the CPU obeys, so they are what
a teardown has to be checked against (ADR-0015). A heap page is a present leaf in that table. It
therefore goes back through exactly the path a program page goes back through, on the exit path and
on the fault path, with no new code and no new list to get out of step.

`m12-heap/run.sh` checks this two ways: `PROC KILL SLOT n FREED c` is compared against a number derived
from the ELF (program pages + 1 stack + heap pages + 4 table frames), and the PMM's free count is
required to be **identical, to the frame**, before and after a session in which one process took 507
heap pages and the other took 5.

---

## 7. Storage: four words in a slot M11 already donated

Per-process heap state is base, break, page count and call count. They live in **words 16..19 of the
process's own table slot**, reached through `procGet`/`procSet` and therefore through proc.dart's
existing three-function storage seam (ADR-0011 §0).

So M12 adds **zero bytes of donated `.bss`** (still 9664) and **zero new externs** (still 58). M11
deliberately left slot words 16..31 unused so that a later field would land somewhere somebody chose;
this is that field. Both numbers are asserted rather than claimed — a heap that had reached for its
own `@extern` would have made the mutable-statics migration a four-line plan instead of a three-line
one, and that is exactly the kind of drift ADR-0011 exists to catch.

`heap.dart` contains no `Pointer<u64>.fromAddress` of its own; the harness checks for that too.

---

## 8. What was deliberately not done

* **No shell command, and therefore no new `help` line.** The heap is a syscall; the shell has nothing
  to say about it that `proc run` does not already say. That is why `shellStrHelp` is unchanged at
  1871 bytes and m3/m4/m5/m6's goldens — which contain `help` output and have no `--regen` — did not
  have to move. GAP-0105's incident is the reason that mattered enough to design around.
* **No `free`, no shrink.** GAP-0107.
* **No second window, no `mmap`, no shared memory.** §1, §2.
* **No zero-fill-on-demand and no lazy mapping.** Every page is allocated and mapped when it is asked
  for. A demand-paged heap needs a `#PF` handler that can distinguish "this address is in a region
  the process owns" from "this address is nowhere", which needs the region list §1 rejected.

---

## 9. Consequences

* A `malloc` can now be written for this machine, in userland, with no further kernel work. It is
  still the case that there is no libc, no `printf` and no `free` beneath it (GAP-0107).
* The exhaustion path is a real, walked path, which means the next change to the window geometry has
  a test that will notice.
* A process can now consume nearly all of a machine's frames by itself, and nothing limits it. There
  is no per-process quota. GAP-0107 item 5.
