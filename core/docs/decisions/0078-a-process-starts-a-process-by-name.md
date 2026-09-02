# ADR-0078 — A process starts a process by 8.3 name

**Status:** accepted, implemented (`core/kernel/proc.dart` `procSysSpawn`,
`core/user/frame/studio.c`, `core/tests/conformance/studio2`).
**Depends on** ADR-0053 (`proc spawn` residency) and apps1 (spawn-by-name
from the shell).
**Implements** `docs/design/osxstudio.md` STUDIO2 launch. The name-only
minimum of `applications.md` APP7; not `spawn(name, argv)`.
**Number:** 0078 — 0077 is A1 (AHCI sector). 11, 21 and 22 stay reserved.

---

## 1. The question

STUDIO1 lists planted `APPS.TXT`. Listing is not the product. The next
rung is: from `STUDIO.ELF`, a derived key or a hit-strip click starts
that catalog name as a resident process. Ring 3 had no spawn syscall.
The shell's `proc spawn <name>` cannot be called from a FRAME app.

## 2. The decision

1. **Syscall 26, `spawn(namePtr, nameLen) -> slot`.** Next free after
   25 (`wmevent`). Not 11 (`fdwait`), not 21/22 (taken on other lines).
   No `oslibc.h` name. `osframe.h` names `SYS_SPAWN`.
2. **Reuse the existing named load.** Bounce the 8.3 bytes through
   `fileBufBase`, then `fatParseAt` + `fatLookup` + `procCreate(..., 1)`.
   The child's image is `ELF FILE`, not an LBA.
3. **Restore the caller's CR3.** `procCreate` loads on the child's
   tables and returns on the kernel's. The syscall puts the caller's
   PML4 back before `iretq`.
4. **No new `.bss`.** `wmeventStore` stays last. No help line.
   `shellStrHelp` stays 2511.
5. **Not APP7 complete.** No argv pointer. A `run` program (no process
   slot) is `spawnRetNoProc`. Four slots still cap a fifth spawn.

The alternative — `STUDIO` writes `SPAWN.REQ` and the shell idle loop
proc-spawns it — was not taken. The syscall is the smaller seam once
the name is already in the caller's pages.

## 3. The printed lines

```
PROC SPAWN <slot>
USER WRITE STUDIO2 LAUNCH APP1.ELF
USER WRITE STUDIO2 OK <slot>
USER WRITE APPS1 APP1
USER WRITE APPS1 APP1 HEAP 1
```

`ELF FILE` and `FS OPEN` come from the named loader, as apps1.

## 4. Binary

`studio2/run.sh` plants `APPS.TXT` listing `APP1.ELF`, `proc spawn`s
`STUDIO.ELF`, focuses the strip, types derived `1`. Serial shows APP1
running and studio still listed (or the prompt already returned).
Negative: no key → APP1 does not start.

## 5. What this is not

Not live-edit of `@bare`. Not a guest Dart SDK. Not `opendir`. Not
`rename`. Not `fork` / `exec`. Not argv-from-spawn (APP7 remainder).
Not persist of `SEL.DAT` (a later data-only rung).
