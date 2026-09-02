# ADR-0147 — A FAT name can be unlinked and renamed

**Status:** accepted, implemented (`fatUnlink` / `fatRenameTo` in
`fat.dart`, `fileSysUnlink` / `fileSysRename` in `file.dart`,
harness `core/tests/conformance/files-unl`)
**Date:** 2026-08-30
**Milestone:** APP4 (`applications.md`), GAP-0127 item 3
**Depends on** ADR-0019 (`open`/`read`/`close`), ADR-0020
(`open(..., O_WRITE)` / `fdwrite`), ADR-0100 (`:ROOT`).
**Closes** the no-delete / no-rename half of GAP-0127 item 3 for
root files. `mkdir` / `rmdir` stay open. Syscall 11 stays `fdwait`.
**Number:** 0147 — 0146 is futex. Do not reuse 0146. Futex kept 30.

---

## 1. The question

`O_WRITE` is create + truncate + append. Without `unlink` and
`rename`, a save destroys the previous file and a FILES move leaves
the source (ADR-0118). GAP-0127 item 3 and APP4 named the fix:
mark the directory entry 0xE5, free the chain, and allow rename-over
so write-temp-and-rename is expressible. Half the mechanism was
already built — `fatDirFreeSlot` reuses 0xE5 and `fatTruncate`
frees a chain.

## 2. The decision

1. **Syscall 31 is `unlink(namePtr, nameLen) -> 0`.** Marks the
   root entry deleted, then frees its cluster chain. Directory
   first, then FAT — a crash between them is a lost chain
   `fsck_msdos` can reclaim. A subdirectory is `FILE_EISDIR`. A
   missing name is `FILE_ENOTFOUND`.
2. **Syscall 32 is `rename(oldPtr, oldLen, newPtr, newLen) -> 0`.**
   Fourth length is RCX (`userFrameRcx`). An existing dest file is
   unlinked first; the source entry's 11 name bytes become the
   dest. Rename onto a subdirectory is `FILE_EISDIR`.
3. **`fatDirFind` is the shared hit without a chain walk.** Empty
   files are hits. `fatLookup` still refuses empty on `open` for
   read. No help line. `shellStrHelp` stays 2511.
   `wmeventStore` stays last `.bss`. 11 stays `fdwait`. 30 stays
   `futex`.

## 3. Binary

`files-unl/run.sh` plants only `PROG.ELF`. The program:

* creates two-cluster `KILL.DAT`, sees it in `:ROOT`, `unlink`s
  it, sees it gone
* `unlink` of a missing name returns `FILE_ENOTFOUND` (low 16
  `fff9`)
* write `A.TXT` / `A.TMP`, `rename` TMP over TXT — TMP gone, TXT
  holds the new bytes
* host `fsck_msdos` is clean; macOS `msdos` agrees

Anti-vacuity: `KILL.DAT` is not planted; missing ≠ success; list
after unlink cannot show the name.

## 4. What this is not

Not `mkdir` / `rmdir`. Not subdirectories as a write path.
FILES move consuming rename is ADR-0149. shm grow is ADR-0150.
Not icons. Not `fdwait`. Not a guest OS.
