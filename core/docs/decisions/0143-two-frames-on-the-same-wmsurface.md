# ADR-0143 — Two different frames on the same wmsurface

**Status:** accepted, implemented, verified (`tests/conformance/de-movie/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0316 leftover after ADR-0135 (one still)
**Files:** `core/plat/media/osmedia_guest.c` (second decode),
`osmedia.c` (annex-B multi-NAL), `osmedia.h` (`OSMEDIA_FRAME2`),
`core/tests/conformance/de-movie/`
**Depends on** ADR-0135 (`wmsurface` still), ADR-0131 (sit-in blit),
ADR-0116 (hidden `play`).
**Does not close** Graphite / Venus paint of the buffer, a decode
syscall, or audio.
**Number:** 0143 — 0142 is configure-to-client. 0144 is dlopen.
Do not reuse 0135. No new syscall. 11 stays `fdwait`.

---

## 1. The question

ADR-0135 planted one decoded still on a shm window at (200, 80).
A movie is more than one still. The same `wmsurface` must show a
second colour after a later tick. A second window or a second
blit origin would be a new surface, not a movie.

## 2. The decision

1. **Keep the decoder open across ticks.** After the first
   `osmedia_decode_frame` + `wmMediaFill`, hold the `OsMedia*`
   and decode again after a short tick budget. Serial prints
   `OSMEDIA MOV <pix>` for the second still.
2. **Same window, same geom.** `wmMediaFill` commits into the
   live 64×64 surface. The body pixel at
   `(WIN_X+WIN_PX, WIN_Y+WIN_PY)` changes from `OSMEDIA_FRAME`
   to `OSMEDIA_FRAME2`.
3. **MP4 plant carries two IDRs.** The planted `CLIP.MP4` is a
   real `ftyp` MP4 with two different solid colours. Annex-B is
   leftover (open path exists; padding/decode still fails for
   some plants).
4. **`OSMEDIA_NO_MOVIE=1` is the miss.** First PIX and window
   FRAME land; no `OSMEDIA MOV`; the body stays FRAME.
5. **No new syscall. No help line.** 11 stays `fdwait`.
   `wmeventStore` stays last `.bss`. Not Graphite. Not osgfx
   Skia.

## 3. What this is not

It is not a video player UI. It is not audio. It is not Venus.
It is not a second `wmsurface`. Live chrome paint is untouched.

## 4. Verification

`de-movie/run.sh` — planted two-colour annex-B: serial PIX is
FRAME, serial MOV is FRAME2, the window body ends as FRAME2,
the raw Bochs tile is still FRAME (first still). With
`OSMEDIA_NO_MOVIE=1` there is PIX and no MOV, and the window
body stays FRAME.
