# ADR-0149 — FILES move consumes rename

**Status:** accepted, implemented (`do_move` in `core/user/frame/files.c`,
`SYS_RENAME` / `SYS_UNLINK` in `osframe.h`, harness
`core/tests/conformance/files-mv2`; `files-fm` updated)
**Date:** 2026-08-30
**Milestone:** GAP-0315 leftover after ADR-0147
**Depends on** ADR-0118 (FILES copy/move as write), ADR-0147
(`unlink` / `rename`).
**Closes** the FILES consumer half of GAP-0315 item 2: move leaves
no second copy. Icons stay leftover. Syscall 11 stays `fdwait`.
**Number:** 0149 — 0148 is setfs. Do not reuse 0147 or 0148.
No new syscall.

---

## 1. The question

ADR-0147 opened `unlink` (31) and `rename` (32). FILES.ELF still
moved by `fdwrite` onto stem.MOV and left the source (ADR-0118).
GAP-0315 named the consumer: call the new door so a move is not a
second copy. Inventing a third write path would leave the source.

## 2. The decision

1. **Move is `rename(src, stem.MOV)`.** Same dest spelling as
   ADR-0118. The source 8.3 leaves. Dest bytes are the plant. Copy
   stays open / fdwrite and keeps its source.
2. **`osframe.h` names 31 and 32.** FILES compiles against osframe,
   not oslibc. FRAME.H checksum moves with the planted bytes;
   FRAME1 derives expectations from the file.
3. **Anti-vacuity.** After boot the FAT walk and macOS msdos see
   the dest and do not see the source. Opening the old name after
   rename is a refusal inside FILES before it prints MOVE. A
   copy-only path fails the harness.
4. **No new number. No help line. 11 is still `fdwait`.**
   `shellStrHelp` stays 2511. `wmeventStore` stays last `.bss`.

### 2.1 What this is not

Not icons. Not `mkdir` / `rmdir`. Not shm grow past attach
(ADR-0142 leftover). Not `fdwait`. Not a guest OS.

## 3. Binary

`files-mv2/run.sh` plants two derived `.DAT`s and `proc spawn`s
`FILES.ELF`:

* serial carries `FILES COPY <A-stem>.CPY <hex>` and
  `FILES MOVE <C-stem>.MOV <hex>`
* FAT walk reads the MOV bytes; extract of the move source fails
* copy source remains; `fsck_msdos` is clean

`files-fm/run.sh` asserts the same source-gone rule so the older
door does not regress.
