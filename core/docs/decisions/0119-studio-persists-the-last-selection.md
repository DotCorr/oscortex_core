# ADR-0119 — Studio persists the last selection as SEL.DAT

**Status:** accepted, implemented (`core/user/frame/studio.c`,
`core/tests/conformance/studio2b`).
**Depends on** ADR-0078 (STUDIO2 launch) and ADR-0020 (`create` /
`fdwrite` / `close`).
**Implements** `docs/design/osxstudio.md` STUDIO2b persist.
**Number:** 0119 — 0114 is osgpu; 0115 is oschrome. This rung is
data-only persist, not a syscall.

---

## 1. The question

STUDIO2 starts a catalog name. A second Studio start forgot which
row was launched. The design already named the file: `SEL.DAT`,
four bytes, a row index. Destroy-on-save is accepted
(`app-framework.md` §4). `unlink` / `rename` are not in this
rung.

## 2. The decision

1. **On select, write `SEL.DAT`.** The same derived key or hit
   strip that `spawn`s row K `open`s `SEL.DAT` with `O_WRITE`,
   `fdwrite`s exactly `SEL_BYTES` (4) of a little-endian `u32`
   row index, and `close`s. A `sizeof buf` write is the APP1
   negative (FRAME3's THEME.DAT control).
2. **On a later start, read it.** After `APPS.TXT` is parsed,
   Studio `open`s `SEL.DAT` and, if the `u32` names a catalog
   row, writes `STUDIO2 SEL` plus that derived 8.3 name. No
   catalog token is a literal in `studio.c`.
3. **No kernel hook.** Persist is ring 3. No help line. No new
   syscall. `wmeventStore` stays last. `shellStrHelp` stays 2511.
4. **Not atomic.** The write truncates. APP4 `rename` is the
   later safe idiom. This ADR does not claim it.

The alternative — persist the 8.3 name bytes — was not required.
The row index plus the planted catalog is enough to exhibit the
name, and the host can read the `u32` back.

## 3. The printed lines

```
USER WRITE STUDIO2 LAUNCH APP1.ELF
USER WRITE STUDIO2 SAVE
USER WRITE STUDIO2 OK <slot>
USER WRITE APPS1 APP1 HEAP 1
```

Second Studio start, same volume:

```
USER WRITE STUDIO2 SEL APP1.ELF
USER WRITE STUDIO2 READY
```

`STUDIO2 SEL APP2.ELF` must not appear when row 0 was persisted.

## 4. Binary

`studio2b/run.sh` plants `APPS.TXT` listing `APP1.ELF` and
`APP2.ELF`. Boot A: `proc spawn studio.elf`, derived key `1`.
Host `fsck_msdos` + msdos reads `SEL.DAT` as the derived `u32`
0. Boot B (same image): second Studio start exhibits
`STUDIO2 SEL APP1.ELF`. Anti-vacuity: `APP2.ELF` is planted and
does not appear selected. Negative: no key → no `SEL.DAT`, no
`SEL` exhibit. First boot must not exhibit `SEL` (the file did
not exist yet) so a client that always prints catalog[0] fails.

`studio1/`, `studio2/`, and `de-studio/` stay launch/list
harnesses; their boots copy the planted image so a persist
write cannot dirty the volume-unchanged SHA.

## 5. What this is not

Not a builder. Not a compiler. Not live-edit of `@bare`. Not a
Dart SDK. Not `opendir`. Not `rename`. Not argv-from-spawn.
Not reflection / emit (GAP-0166, leftover).
