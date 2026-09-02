# ADR-0163 — mprotect and MAP_FIXED are shm doors

**Status:** accepted, implemented (`shmSysMprotect` syscall 36,
`shmMapFixed` on `shmmap`, `vmShmProtect` in `vm.dart`, harness
`core/tests/conformance/mmap-prot`)
**Date:** 2026-08-30
**Milestone:** GAP-0235 first doors after ADR-0160 partial map
**Depends on** ADR-0041 (`shmcreate` / map), ADR-0160 (range word).
**Closes** `mprotect` and `MAP_FIXED` for live shm mappings.
File backing and demand paging stay GAP-0235.
Syscall 11 stays `fdwait`.
**Number:** 0163 — 0160 is shm-part / need2. 0161 is curved
MakeRectXY. 0162 is DT_NEEDED×8. Do not reuse those.
**Number:** syscall 36. 35 is `shmshrink`.

---

## 1. The question

A shm region was mapped with permissions fixed at create / map
time. A creator could not downgrade itself to read-only after
publishing — the one of GAP-0235's four a compositor client wants.
Addresses were always kernel-chosen; a caller could not propose
one, so there was no overlap refuse either.

## 2. The decision

1. **Syscall 36 is `mprotect(handle, perms) -> 0`.** Changes W on
   the caller's already-mapped capability window. Legal perms are
   `RO` / `RW`. `EXEC` is `shmRetExec`. Escalate past the capability
   is `shmRetBadPerm`. Not mapped is `shmRetMapped` (same code,
   "must be mapped" sense as grow). Cap perms update so a later
   escalate or grow sees the downgrade. No `oslibc.h` name.
2. **`shmmap` gains `MAP_FIXED`.** Perms bit `0x100`; `rcx` is the
   proposed VA of the first mapped page. Must equal
   `slotBase + offset*4096` or `shmRetBadFixed`. Checked before the
   already-mapped refuse so a wrong address is visible even on a
   live mapping. Correct fixed on an already-mapped handle is still
   `shmRetMapped` (overlap refuse). Existing callers pass `rcx=0`
   and no bit — unchanged.
3. **Anti-vacuity.** After RO downgrade a store must `#PF`. Exec
   and escalate must refuse by name. Wrong fixed VA must refuse.
   Fixed overlap must refuse. A no-op protect that left W set would
   print `PROT STILL WRITABLE`.
4. **No help line. 11 is still `fdwait`.** `shellStrHelp` stays
   2511. Grow 34 / shrink 35 / partial 18 unchanged. Not Graphite /
   Venus.

### 2.1 What this is not

Not file-backed map. Not demand paging. Not anonymous `mmap`
`mprotect`. Not `fdwait`. Not a guest OS. Not Graphite / MakeVulkan /
Venus.

## 3. Binary

`mmap-prot/run.sh` runs `PROG.ELF`:

* `shmcreate(2)` → fill → `shmmap(FIXED|RW, wrong VA)` → BadFixed
* `shmmap(FIXED|RW, slot VA)` → Mapped (overlap)
* `mprotect(RO)` → OK; `mprotect(EXEC)` → Exec; `mprotect(RW)` →
  BadPerm
* after `MMAP PROT OK`, store probe → `#PF`
* serial carries `SHM PROT R …`, fixed refuses, probe, user fault
