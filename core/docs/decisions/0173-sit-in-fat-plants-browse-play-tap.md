# ADR-0173 — Sit-in FAT plants BROWSE PLAY TAP

**Status:** accepted, implemented (`de-sitfat/build-disk.sh`, `sit-in.sh`)
**Date:** 2026-08-31
**Depends on** ADR-0108 (sit-in FAT Start), ADR-0112 (`TAP.ELF`),
ADR-0115 (`BROWSE.ELF`), ADR-0135 (`PLAY.ELF`).
**Does not change** `wmDeLaunchMax`, chrome-word packing, Graphite /
Venus / lavapipe, or de-sitfat Start floors.
**Number:** 0173 — 0172 is Venus SPIR-V / CEF UND×50 (siblings). Do not
reuse. Syscall 11 stays `fdwait`. No help line. No new syscall.

---

## 1. The question

`BROWSE.ELF`, `PLAY.ELF`, and `TAP.ELF` existed only as harness
plants (`de-browse/`, `de-vwin`/`de-movie/`, `de-apps/`). Sit-in's
boot volume carried FILES SET PING STUDIO (+ APP1). The owner wants
those apps preinstalled on the running image, not harness-only.

---

## 2. The decision

1. **`de-sitfat/build-disk.sh` plants them.** Directory order after
   STUDIO: `BROWSE.ELF`, `PLAY.ELF`, `TAP.ELF`, then `APPS.TXT` /
   `APP1.ELF`. Same builder `sit-in.sh` (and any Venus path that
   shares it) already calls. Not OSCXPRG1.
2. **Start stays 04.** `wmDeLaunchMax = 4` and `wmLaunchH = 80`
   (four rows). Chrome-word packing holds at most six 8-bit dir
   indices from bit 16. Raising Start for seven launch ELFs needs
   packing + popover work — not this ADR. Serial still
   `WM DE START 04` with FILES SET PING STUDIO. PING row geometry
   and de-sitfat floors are unmoved.
3. **Full FAT vs Start.** FILES list / `proc spawn` / hidden `go`
   see every planted 8.3 ELF. Start caches only the first four.
   Same pattern APP1 already had (companion after the Start floor).
4. **Honest leftovers.** BROWSE is still stand-in OnPaint (ADR-0166
   floor). PLAY is still the media attach client (decode is
   `play` / CLIP.MP4 / IRQ0). TAP is still the osframe contract
   plant. No Graphite / Venus touch.

### 2.1 What this is not

It is not raising `wmDeLaunchMax`. It is not planting `CLIP.MP4`.
It is not Content OnPaint for real. It is not a new syscall.

---

## 3. The harness

`de-sitfat/build-disk.sh` layout.json carries `BROWSE.ELF`,
`PLAY.ELF`, `TAP.ELF`. `model.txt` still `start_count=04` /
`elves=FILES.ELF,SET.ELF,PING.ELF,STUDIO.ELF`. `de-sitfat/run.sh`
asserts the three names on the image and keeps the Start 04 boot.
