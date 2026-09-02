# ADR-0156 — shmshrink truncates a mapped region

**Status:** accepted, implemented (`shmSysShrink` in `shm.dart`,
syscall 35, harness `core/tests/conformance/shm-shrink`)
**Date:** 2026-08-30
**Milestone:** GAP-0234 remainder after ADR-0150 grow
**Depends on** ADR-0041 (`shmcreate` / map), ADR-0051 (`wmsurface`),
ADR-0150 (`shmgrow`).
**Closes** shrink past create / past attach for a single mapped
owner. Multi-mapper grow/shrink and partial/offset map stay open.
Syscall 11 stays `fdwait`.
**Number:** 0156 — 0154 was claimed twice (plat-huge fraction and
files-ico). 0155 is the full CEF `.text` mmap. Do not reuse those.
**Number:** syscall 35. 34 is `shmgrow`.

---

## 1. The question

ADR-0150 grew a mapped region in place. A client that attached a
generous shm and later needs fewer pages still could not give frames
back. Dropping and recreating is a different capability. The leftover
was shrink-in-place or an honest refuse.

## 2. The decision

1. **Syscall 35 is `shmshrink(handle, newPages) -> 0`.** Truncates
   the region's page count to `newPages` (≥ 1, strictly less than
   current). Unmaps the trailing pages from the caller's address
   space, unmarks and frees those frames, clears their vector
   slots. Same VA base. No `oslibc.h` name.
2. **Owner, mapped, alone.** RW capability, already mapped, and
   `shmRegMaps == 1`. A RO grant cannot shrink. Two mappers refuse
   `shmRetMapped` (same CR3 reason as grow). Same size, grow, or
   zero pages is `shmRetBadLen`.
3. **Anti-vacuity.** After shrink the trailing VA must fault on
   store. A no-op that returns 0 without unmapping leaves the old
   mark reachable — the harness requires `SHM SHRINK OK`, then a
   probe announcement, then a ring-3 `#PF`, and refuses
   `SHRINK STILL MAPPED`. Shrink after `wmsurface` attach is the
   leftover attach case.
4. **No help line. 11 is still `fdwait`.** `shellStrHelp` stays
   2511. `wmeventStore` stays last `.bss`.

### 2.1 What this is not

Not multi-mapper grow or shrink. Not a new attach. Not
partial/offset map (GAP-0234 remainder). Not `fdwait`. Not a
guest OS. Not Graphite / MakeVulkan / Venus.

## 3. Binary

`shm-shrink/run.sh` runs `PROG.ELF`:

* `shmcreate(5)` → fill → `shmshrink(…, 2)` → old pages 0–1 intact
* same / grow / 0 return `shmRetBadLen`
* second region: attach 64×32 on 6 pages, `shmshrink(…, 2)`,
  remaining pages intact
* after `SHM SHRINK OK`, probe a freed page → `#PF`
* serial carries `SHM SHRINK R … PAGES 0002` (twice), `SHM SHRINK OK`,
  probe, and a user fault
