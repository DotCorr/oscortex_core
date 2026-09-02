# ADR-0158 — two mappers grow and shrink on one shm

**Status:** accepted, implemented (`shmMapRangeAll` / `shmUnmapRangeAll`
in `shm.dart`, harness `core/tests/conformance/shm-multi`)
**Date:** 2026-08-30
**Milestone:** GAP-0234 remainder after ADR-0150 grow and ADR-0156 shrink
**Depends on** ADR-0041 (`shmcreate` / grant / map), ADR-0150
(`shmgrow`), ADR-0156 (`shmshrink`).
**Closes** multi-mapper grow and shrink for a region mapped in more
than one address space. Partial / offset map is ADR-0160.
Syscall 11 stays `fdwait`. No new syscall number.
**Number:** 0158 — 0157 is `DT_NEEDED` two FAT `.so`s. 0156 is
`shmshrink`. Do not reuse those.

---

## 1. The question

ADR-0150 and ADR-0156 grew and shrank a mapped region for a **single**
mapper. With two mappers (owner RW + grant RO), both paths refused
`shmRetMapped` because `vmShmMap` only edits the live CR3. A
compositor peer that already mapped would see stale page counts. The
leftover was update every mapper, or stay refused forever.

## 2. The decision

1. **Same syscalls 34 / 35.** `shmgrow` and `shmshrink` keep their
   numbers and alone-owner / RW / mapped checks. The alone-mapper
   refuse is removed. No `oslibc.h` name. 11 stays `fdwait`.
2. **Every mapper's SHM page table.** `procSlotShmPt` names each
   process's `PD[129]` frame. Grow maps new leaves into every live
   mapped capability (owner W, grant RO). Shrink unmaps trailing
   leaves from every mapper before freeing frames. No CR3 switch;
   `invlpg` only for the live table.
3. **Anti-vacuity.** A grow that only updates the owner fails the
   peer's RO read of new marks. A shrink that leaves the peer mapped
   prints `MULTI PEER STILL MAPPED` and fails. Harness requires
   `MAPS 0002` on grow and shrink lines.
4. **No help line.** `shellStrHelp` stays 2511. Not Graphite / Venus.

### 2.1 What this is not

Not partial map. Not offset map (GAP-0234 remainder). Not a new
attach. Not `fdwait`. Not a guest OS. Not Graphite / MakeVulkan /
Venus.

## 3. Binary

`shm-multi/run.sh` runs one ELF in two `proc coop` slots:

* producer: `shmcreate(3)` → grant → wait peer map → `shmgrow(…, 6)`
  → fill → `shmshrink(…, 2)`
* consumer: `shmmap` RO → read grown marks → probe freed page → `#PF`
* serial carries `SHM MAP … MAPS 0002`, `SHM GROW … PAGES 0006 MAPS
  0002`, `SHM SHRINK … PAGES 0002 MAPS 0002`, `SHM MULTI PEER GROW
  OK`, peer shrink probe, and a user fault
