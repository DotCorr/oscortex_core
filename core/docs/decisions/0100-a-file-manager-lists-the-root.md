# ADR-0100 — A file manager lists the FAT root and opens a planted file

**Status:** accepted, implemented (`core/kernel/file.dart` `:ROOT`,
`core/user/frame/files.c` / `FILES.ELF`,
`core/tests/conformance/files-fm`)
**Depends on** ADR-0018 (FAT16), ADR-0019 (`open`/`read`), ADR-0051
(surfaces), ADR-0053 (`proc spawn` residency).
**Implements** the FRAME file-manager rung: list a FAT directory,
show host-derived names, open/cat a planted file. Uses
`applications.md` APP3's transport (`open(":ROOT")`), not a new
syscall. Not `LS.ELF` and not APP3 complete.
**Number:** 0100 — 0098 is virtio-gpu 3D alpha. 11 stays `fdwait`.

---

## 1. The question

Ring 3 could open a name it already knew. It could not enumerate the
root. STUDIO1 lists a planted catalog. A file manager that prints a
baked name, or that treats a missing file as the plant, is a stub.

## 2. The decision

1. **`open(":ROOT")` in `fileSysOpen`, never in `fatLookup`.** After
   the bounce-buffer copy, before `fatParseAt`. Same placement as the
   `/dev` branch (ADR-0033). `fileMakeEmpty`, `shellFatCat`, and
   `shellElfRunName` do not see the sigil. Write mode is
   `fileRetBadMode`.
2. **`fileFdRoot = 4`.** `read` returns whole 32-byte FAT directory
   entries, skipping deleted / LFN / volume-label the way `ls` does,
   and 0 at the end. `seek` and `fdwrite` refuse it. No new `.bss`.
   `fileStore` stays 2560. `wmeventStore` stays last.
3. **Existing open/read only.** No `readdir`, no `opendir`, no row in
   the registry. 11 stays `fdwait`. Not in `help`. `shellStrHelp`
   stays 2511.
4. **`FILES.ELF` is a FRAME client.** `proc spawn` starts it
   (ADR-0053). It lists every record as `FILES NAME <8.3>`, opens the
   first name that is not itself, prints `FILES CAT <hex>`, and paints
   a swatch from the first three bytes. `open("GHOST.DAT")` on a
   deleted or absent entry is `FILES MISS`, not a plant.
5. **ATA or NVMe is already `fatDiskRead`.** This ADR does not pick
   a transport. m14 and nvm5 stay the proofs they were.

The alternative — a planted `LIST.TXT` sidecar — was not taken. That
is STUDIO1. An empty directory and a missing name would still print
the sidecar.

## 3. The printed lines

```
USER WRITE FILES NAME FILES.ELF
USER WRITE FILES NAME Pxxxx.DAT
USER WRITE FILES NAMES 2
USER WRITE FILES LIST
USER WRITE FILES CAT <32 hex>
USER WRITE FILES MISS GHOST.DAT
USER WRITE FILES READY
```

No disk / not a FAT volume:

```
USER WRITE FILES OPEN REFUSED <code>
USER WRITE FILES READY
```

Empty root (only `FILES.ELF`):

```
USER WRITE FILES NAME FILES.ELF
USER WRITE FILES NAMES 1
USER WRITE FILES CAT NONE
```

## 4. Binary

`files-fm/run.sh` plants a derived 8.3 name and 16 random bytes on a
FAT16 image, `proc spawn`s `FILES.ELF`, and requires that name and
those bytes on COM1. A second image must print its own plant. A
deleted `GHOST.DAT` must not appear as a name. Empty dir has no
plant. A raw OSCXPRG1 disk (spawn by LBA) refuses `:ROOT`.
`fsck_msdos` accepts the volume before and after.

## 5. What this is not

Not copy, not move, not icons, not subdirectories, not `unlink` /
`rename` (APP4). Not `LS.ELF` (APP3 remainder). Not a new syscall.
Not a guest OS. Not Flutter.
