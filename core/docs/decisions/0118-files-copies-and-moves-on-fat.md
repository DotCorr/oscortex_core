# ADR-0118 — FILES copies and moves on FAT with open and fdwrite

**Status:** accepted, implemented (`core/user/frame/files.c` / `FILES.ELF`,
`core/tests/conformance/files-fm`)
**Depends on** ADR-0100 (list / cat / `:ROOT`), ADR-0019 (`open`/`read`),
ADR-0020 (`open(..., O_WRITE)` / `fdwrite`).
**Implements** GAP-0315 items 1–2: copy planted A → dest B and move
planted C → dest D with host-derived bytes. No new syscall.
**Number:** 0118 — 0114 is osgpu. Do not reuse 0114.

---

## 1. The question

ADR-0100 listed the FAT root and catted a planted file. A file manager
that cannot rearrange the volume is still a listing. GAP-0315 named
copy first, then move. `unlink` / `rename` are not syscalls (APP4,
GAP-0127 item 3). Inventing one would be a registry row this rung
does not need.

## 2. The decision

1. **Copy uses the syscalls that exist.** `FILES.ELF` `open`s the first
   listed `.DAT` that is not itself, `open(..., O_WRITE)` a dest whose
   8.3 is that stem plus `CPY`, `fdwrite`s the same bytes, and `close`s
   (the flush). Then it re-`open`s the dest and prints
   `FILES COPY <dest> <hex>`.
2. **Move is the same write onto stem plus `MOV`.** There is no
   `unlink`. The source stays. GAP-0315 said so: until APP4, a move
   is a copy plus a leftover. Dest bytes are still the plant.
3. **Dest names are derived, not planted.** `files.c` holds the
   extensions `CPY` and `MOV`. The stem comes from the volume.
   Plant names and plant bytes do not appear in `files.c`,
   `file.dart`, or `fat.dart`.
4. **`.DAT` only.** Copy/move skip `.ELF` so a sit-in volume that
   already has `FILES.ELF` / `SET.ELF` does not duplicate programs.
   An empty root and a one-plant image print `FILES COPY NONE` /
   `FILES MOVE NONE` when the matching source is missing.
5. **No new number, no help, no kernel `.bss`.** 11 stays `fdwait`.
   `fileStore` stays 2560. `wmeventStore` stays last. `shellStrHelp`
   stays 2511.

Same-name is refused (`cp A A` would truncate first). Short
`fdwrite` is a refusal. `fsck_msdos` and a host FAT walk must see
the dest bytes after boot.

## 3. The printed lines

After ADR-0100's list / cat, on a volume with two planted `.DAT`s:

```
USER WRITE FILES COPY Pxxxx.CPY <32 hex of A>
USER WRITE FILES MOVE Pyyyy.MOV <32 hex of C>
```

One plant: copy line, then `FILES MOVE NONE`.
No plant: `FILES COPY NONE` and `FILES MOVE NONE`.

## 4. Binary

`files-fm/run.sh` plants derived A and C on one FAT16 image and B
on a second. After `proc spawn FILES.ELF`:

* serial carries A's cat, `FILES COPY <A-stem>.CPY <A hex>`, and
  `FILES MOVE <C-stem>.MOV <C hex>`
* image B prints its own cat and copy, never A's
* empty dir still lists only `FILES.ELF`
* raw OSCXPRG1 still refuses `:ROOT`
* after boot A the volume hash changes; `fsck_msdos` is clean;
  dest files read back as the plants; sources are still there

Anti-vacuity: dest ≠ source; dest bytes equal the plant, not a
kernel constant; dest names were absent on the as-built volume.

## 5. What this is not

Not `unlink` / `rename` (APP4 / `m23-unlink`). Not icons (GAP-0315
item 3). Not subdirectories. Not `LS.ELF`. Not a new syscall.
Not a guest OS. Not Flutter.
