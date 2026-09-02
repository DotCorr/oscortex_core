# ADR-0165 — A named platform ELF may load thirty-two FAT DT_NEEDED .so files

**Status:** accepted, implemented, verified (`tests/conformance/plat-need5/run.sh`)
**Date:** 2026-08-30
**Milestone:** finish the DT_NEEDED stand-in chain after ADR-0163
**Files:** `core/kernel/elf.dart` (`xc_fn`..`ld_fn` resolve), `docs/syscall-registry.md`
(no new number), `tests/conformance/plat-need5/`, GAP-0322
**Depends on** ADR-0124 (platform window), ADR-0127 (`PT_DYNAMIC`),
ADR-0144 (`dlopen`), ADR-0152 (tiny `LIBC.SO` / `write`),
ADR-0157 (two-stand-in walk), ADR-0160 (four-stand-in walk),
ADR-0162 (eight-stand-in walk), ADR-0163 (sixteen-stand-in walk).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or libcef.
**Number:** 0165 — 0163 is DT_NEEDED-sixteen (and mmap-prot double-claim).
0164 is reserved for file-map. Do not reuse those. Syscall 11 stays
`fdwait`. No new syscall — 29 is still `dlopen`.

---

## 1. The question

ADR-0163 walked **sixteen** FAT `DT_NEEDED` and satisfied **16 of 32**
CEF slots. Official `libcef.so` still carries **32** `DT_NEEDED`. The
leftover named `libXcomposite.so.1` … `ld-linux-x86-64.so.2`. The next
binary is to **finish the chain** — walk **all 32** of OUR FAT-resident
stand-ins with a derived call from each. Not glibc. Not a pretend CEF
`OnPaint`.

A fake success that invents `LINE32` without mapping `LIBLD.SO`, or that
hardcodes thirty-two names while skipping `DT_NEEDED`, fails the harness.
A volume without the thirty-second `.so` must refuse that name and must
not print the thirty-second derived line.

## 2. The decision

1. **Syscall 29 still is `dlopen`.** It now also resolves `xc_fn`,
   `xd_fn`, `xe_fn`, `xf_fn`, `xr_fn`, `gm_fn`, `ex_fn`, `xb_fn`,
   `xk_fn`, `ca_fn`, `pg_fn`, `ud_fn`, `as_fn`, `ap_fn`, `gc_fn`, and
   `ld_fn` (ADR-0165) after `write` / `need_fn` / `dl_fn` / `pt_fn` /
   `gb_fn` / `go_fn` / `np_fn` / `ns_fn` / `nu_fn` / `sm_fn` /
   `db_fn` / `gi_fn` / `at_fn` / `ab_fn` / `cu_fn` / `x1_fn`, before
   `so_mark` (ADR-0144). 11 stays `fdwait`. No new number.
2. **`PLAT.ELF` carries `PT_DYNAMIC` with thirty-two `DT_NEEDED`.** The
   sonames are OUR 8.3 FAT names:
   - ADR-0163's sixteen: `LIBC.SO` … `LIBX1.SO`
   - `LIBXC.SO` — stand-in for CEF `libXcomposite.so.1`
   - `LIBXD.SO` — stand-in for CEF `libXdamage.so.1`
   - `LIBXE.SO` — stand-in for CEF `libXext.so.6`
   - `LIBXF.SO` — stand-in for CEF `libXfixes.so.3`
   - `LIBXR.SO` — stand-in for CEF `libXrandr.so.2`
   - `LIBGM.SO` — stand-in for CEF `libgbm.so.1`
   - `LIBEX.SO` — stand-in for CEF `libexpat.so.1`
   - `LIBXB.SO` — stand-in for CEF `libxcb.so.1`
   - `LIBXK.SO` — stand-in for CEF `libxkbcommon.so.0`
   - `LIBCA.SO` — stand-in for CEF `libcairo.so.2`
   - `LIBPG.SO` — stand-in for CEF `libpango-1.0.so.0`
   - `LIBUD.SO` — stand-in for CEF `libudev.so.1`
   - `LIBAS.SO` — stand-in for CEF `libasound.so.2`
   - `LIBAP.SO` — stand-in for CEF `libatspi.so.0`
   - `LIBGC.SO` — stand-in for CEF `libgcc_s.so.1`
   - `LIBLD.SO` — stand-in for CEF `ld-linux-x86-64.so.2`
   The program walks its own `DT_NEEDED` / `DT_STRTAB` and
   `dlopen`s each name. `ASK.ELF` planted as the same bytes is
   still `ELF REFUSED 11` (ADR-0127).
3. **Derived call from each.** `LINE1`..`LINE32` are `MARK ^ MIX`
   through `write` / `need_fn` / … / `ld_fn`. X LOADs stay remapped
   R+X (ADR-0152).
4. **Anti-vacuity.** Missing `LIBLD.SO` is `elfDlopenRetNotFound`
   and cannot invent `LINE32`. `LINE1`..`LINE31` still print.
5. **Counts.** Satisfies **32 of 32** CEF `DT_NEEDED` stand-ins.
   Content `OnPaint` remains leftover (GAP-0322). TAP/FILES stay
   64 KiB / 2 MiB. No help line. Graphite / Venus fenced.

## 3. What this is not

It is not glibc. It is not the real `libXcomposite.so.1` …
`ld-linux-x86-64.so.2` / libcef. It is not the other CEF rungs
(189 MiB `.text`, 1,336 UND, POSIX). It is not raising `de-browse`
floor 87. `drawRRect` still owns `osgfx_skia`. It is not `OnPaint`.

## 4. What remains (GAP-0322 leftovers)

Content `OnPaint`. This decision finishes the thirty-two-stand-in
`DT_NEEDED` door. It is not that rung.

## 5. Verification

`core/tests/conformance/plat-need5/run.sh` — `PLAT.ELF` walks thirty-two
`DT_NEEDED`, dlopens `LIBC.SO` … `LIBLD.SO`, prints derived
`LINE1`..`LINE32`. A volume without `LIBLD.SO` prints `LINE1`..`LINE31`
only and `ERR …F9` for the thirty-second name. `ASK.ELF` is the same
bytes and is `ELF REFUSED 11`. `elfImageMax` is still 65,536. Syscall 11
is still `fdwait`. `de-browse/` stays at floor 87.
