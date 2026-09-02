# ADR-0164 — shmfile demand-fills from a FAT file

**Status:** accepted, implemented (`shmSysFile` syscall 37,
`shmDemandTry` on `#PF` NOTPRES, harness
`core/tests/conformance/mmap-file`)
**Date:** 2026-08-30
**Milestone:** GAP-0235 file backing + demand paging after ADR-0163
**Depends on** ADR-0041 (`shmcreate` / map), ADR-0019 (`open`),
ADR-0163 (`mprotect` / `MAP_FIXED`).
**Closes** file backing and demand paging for GAP-0235.
Syscall 11 stays `fdwait`.
**Number:** 0164 — 0163 is mprotect / need4. Do not reuse those.
**Number:** syscall 37. 36 is `mprotect`.

---

## 1. The question

A shm region was anonymous and eagerly allocated. There was no way
to name a FAT file as the backing store, and no `#PF` path that
could install a missing leaf and resume. GAP-0235's last two doors.

## 2. The decision

1. **Syscall 37 is `shmfile(fd) -> handle`.** `fd` is an open
   read-only FAT descriptor. Region page count is
   `ceil(size / 4096)`, capped at `shmMaxPages`. Capability is RO
   and marked mapped; **no frames and no present leaves** at create.
   Live state is `shmRegLiveFile` so grow/shrink/mprotect stay on
   the eager anonymous door. Trailer in the vector page holds size
   and `(row << 8) | (fd + 1)`. No `oslibc.h` name.
2. **Demand fill on `#PF` NOTPRES.** `isrDispatch` asks
   `shmDemandTry` before `userOnFault`. A user not-present fault
   inside a file-backed window allocates a frame, copies that page
   from the FAT fd through the existing sector path, maps RO, prints
   `SHM DEMAND`, and returns so `iretq` retries. Present / write /
   supervisor faults still kill.
3. **Anti-vacuity.** Create prints `SHM PAGE … P 0` for every
   leaf. First touch must emit `SHM DEMAND` before the plant bytes
   are readable. Plant magics must match. RO store after fill must
   `#PF` (`USER FAULT`). Eager pre-fault at create would fail the
   `P 0` check.
4. **No help line. 11 is still `fdwait`.** `shellStrHelp` stays
   2511. 36 stays `mprotect`. Not Graphite / Venus.

### 2.1 What this is not

Not anonymous lazy `shmcreate`. Not write-through `MAP_SHARED`.
Not `fdwait`. Not a guest OS. Not Graphite / MakeVulkan / Venus.

## 3. Binary

`mmap-file/run.sh` runs `PROG.ELF` against planted `PLANT.DAT`:

* `open(PLANT.DAT)` → `shmfile(fd)` → `SHM FILE … PAGES 0002`
* page report shows `P 0` before any demand
* touch page 0 → `SHM DEMAND … PAGE 0000` → `MMAPFILE` magic
* touch page 1 → `SHM DEMAND … PAGE 0001` → `DEMANDPG` magic
* RO store → `#PF`
