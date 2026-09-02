# ADR-0150 — shmgrow extends a mapped region

**Status:** accepted, implemented (`shmSysGrow` in `shm.dart`,
syscall 34, harness `core/tests/conformance/shm-grow`)
**Date:** 2026-08-30
**Milestone:** ADR-0142 leftover after configure / SE resize clip
**Depends on** ADR-0041 (`shmcreate` / map), ADR-0051 (`wmsurface`),
ADR-0121 (resize clips to region).
**Closes** growing shm past the attach size for a single mapped
owner. Multi-mapper grow and shrink stay open. Syscall 11 stays
`fdwait`.
**Number:** 0150 — 0149 is FILES rename move. Do not reuse 0148.
**Number:** syscall 34. 33 is `setfs`.

---

## 1. The question

SE resize under `wm de` clips to the attach shm (ADR-0121).
Configure tells the client the clip (ADR-0142). A client that
needs more pixels still could not enlarge the region. Creating a
second region and re-attaching is a different surface. The leftover
was grow-in-place or an honest refuse.

## 2. The decision

1. **Syscall 34 is `shmgrow(handle, newPages) -> 0`.** Extends the
   region's frame vector up to `shmMaxPages`, zeroes the new
   frames, and maps them into the caller's address space. Same VA
   base (slot window). No `oslibc.h` name.
2. **Owner, mapped, alone.** RW capability, already mapped, and
   `shmRegMaps == 1`. A RO grant cannot grow. Two mappers would
   need a CR3 switch this path does not take — refuse
   `shmRetMapped`. Same size, shrink, or oversize is
   `shmRetBadLen`.
3. **Anti-vacuity.** After grow the new pages are writable. A
   no-op that returns 0 without mapping fails the fill. Grow after
   `wmsurface` attach is the leftover case.
4. **No help line. 11 is still `fdwait`.** `shellStrHelp` stays
   2511. `wmeventStore` stays last `.bss`.

### 2.1 What this is not

Not shrink. Not multi-mapper grow. Not a new attach. Not
partial/offset map (GAP-0234 remainder). Not `fdwait`. Not a
guest OS.

## 3. Binary

`shm-grow/run.sh` runs `PROG.ELF`:

* `shmcreate(2)` → fill → `shmgrow(…, 5)` → fill new pages → old
  pages intact
* same / shrink / 200 pages return `shmRetBadLen`
* second region: attach 64×32, `shmgrow(…, 6)`, write page 5
* serial carries `SHM GROW R … PAGES 0005`, `PAGES 0006`, and
  `SHM GROW OK`
