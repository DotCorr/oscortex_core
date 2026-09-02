# ADR-0160 — partial / offset map is a range word

**Status:** accepted, implemented (`shmSysMap` rdx range + capability
window bits in `shm.dart`, harness `core/tests/conformance/shm-part`)
**Date:** 2026-08-30
**Milestone:** GAP-0234 remainder after ADR-0158 multi-mapper grow/shrink
**Depends on** ADR-0041 (`shmcreate` / grant / map), ADR-0158
(multi-mapper page-table edits).
**Closes** partial map and offset map for a live shm capability.
Syscall 11 stays `fdwait`. No new syscall number — extends 18.
**Number:** 0160 — 0159 is desktop Graphite fill. 0158 is two-mappers
shm. Do not reuse those.

---

## 1. The question

`shmmap` mapped every page of a region at the slot window. A client
that wanted one tile either created a one-tile region or mapped the
whole surface. Grow/shrink and multi-mapper updates already walked
page ranges; the leftover was naming a sub-range at map time.

## 2. The decision

1. **Syscall 18 gains `rdx`.** `shmmap(handle, perms, range)` where
   `range = (offset << 16) | count`. `count == 0` maps the whole
   region (every existing harness passes `rdx = 0`). `count > 0`
   maps pages `[offset, offset+count)` only. Out-of-range offset or
   count is `shmRetBadLen`. Return value is the VA of the first
   mapped page (`slotBase + offset * 4096`). No `oslibc.h` name.
2. **Capability word carries the window.** Bit 9 = whole; bits
   10..17 = offset; bits 18..25 = count. Drop and multi-mapper
   grow/shrink intersect with that window so a partial peer does
   not gain or keep leaves outside it. Whole maps still track the
   live page count.
3. **Anti-vacuity.** Out-of-range offset must refuse. Mapped pages
   must be readable. An unmapped hole in the slot window must `#PF`
   — a whole map disguised as partial prints `PART STILL MAPPED`.
4. **No help line. 11 is still `fdwait`.** `shellStrHelp` stays
   2511. Grow 34 / shrink 35 unchanged. Not Graphite / Venus.

### 2.1 What this is not

Not a new syscall number. Not `fdwait`. Not grow/shrink ABI change.
Not Graphite / MakeVulkan / Venus. Not a guest OS.

## 3. Binary

`shm-part/run.sh` runs one ELF in two `proc coop` slots:

* producer: `shmcreate(4)` → fill distinct marks → grant → wait ack
* consumer: `shmmap` with offset past end → `shmRetBadLen`; then
  `shmmap` `[1,3)` RO → read marks → probe page 0 → `#PF`
* serial carries `SHM PART BAD OFF OK`, `SHM MAP … OFF 0001 COUNT
  0002`, `SHM PART MAP OK`, hole probe, and a user fault
