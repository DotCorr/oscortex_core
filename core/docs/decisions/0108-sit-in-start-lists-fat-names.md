# ADR-0108 — Sit-in Start lists FAT 8.3 names

**Status:** accepted, implemented (`core/tests/conformance/de-sitfat`,
`sit-in.sh` builds that FAT volume).
**Depends on ADR-0106** (`wm de` start / spawn) and ADR-0018 (FAT16).
**Does not change** `wmde.dart` contracts, syscall 26, or help.
**Number:** 0108 — 0106 is DE chrome policy. 0107 is osgfx-gl (sibling).
Do not reuse those.

---

## 1. The question

`wm de` Start walks the FAT root and caches `.ELF` 8.3 names
(ADR-0106 §2.4). Sit-in still planted an OSCXPRG1 LBA disk
(d3-session `make-image.py`). `fatMount` sees no volume, the launch
cache stays empty, and a start click prints `WM DE START 00`.

The programs already exist: `FILES.ELF`, `SET.ELF`, `STUDIO.ELF`,
and de-chrome's `PING.ELF`. Start was empty because the disk was
the wrong shape, not because DE chrome was missing.

---

## 2. The decision

1. **Sit-in's disk is a FAT16 volume.** Same geometry as de-chrome /
   apps1 / m14 (`fsck_msdos` accepts it). Directory order is the
   launch-row order: `FILES.ELF`, `SET.ELF`, `PING.ELF`,
   `STUDIO.ELF`. Companions `FACTS.DAT` and `APPS.TXT` / `APP1.ELF`
   sit on the volume so SET and Studio are the programs they already
   are. Not OSCXPRG1. No new syscall.
2. **`sit-in.sh` spawns by 8.3 name.** `proc spawn FILES.ELF` (or
   `SURF.ELF` on `SITIN_FRAME2=1`). Start click, then the derived
   PING row. Serial carries `WM DE START 0N` with N≥1, a derived
   name (`FILES NAME …` / `FS OPEN PING    .ELF`), and
   `DE CHROME PING`.
3. **`wm de` is unmoved.** Close / min / start / panel stay ADR-0106.
   de-chrome's WIN.ELF + PING.ELF volume is unchanged.
4. **No help line. No guest OS.** Same reasons as ADR-0106 §3.

### 2.1 What this is not

It is not a `wmde.dart` rewrite. It is not glyphs on the launch
rows (those are still colour bands). It is not `shmMax` > 2. It is
not virtio-gpu / osgfx-gl (0107).

---

## 3. The harness

`de-sitfat/` builds the volume, types `fb`, `wm on`, `wm de`,
`proc spawn FILES.ELF`, clicks start, then the PING row:

* serial `WM DE START 04` (four cached ELF names)
* `FILES NAME SET.ELF` and `FILES NAME PING.ELF`
* `FS OPEN PING    .ELF`, `DE CHROME PING`, `WM DE SPAWN`
* launch-row 0 pixel is the derived row colour

Anti-vacuity: the image must not begin with `OSCXPRG1`; sit-in.sh
must call `de-sitfat/build-disk.sh` and must not call
`d3-session/make-image.py`.
