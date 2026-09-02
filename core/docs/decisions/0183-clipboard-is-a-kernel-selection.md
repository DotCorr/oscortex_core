# ADR-0183 — Clipboard is a kernel selection, not wl_data_device

**Status:** accepted, implemented (`wmOpOffer` / `wmOpTake` in
`wmext.dart`, spare `shmMetaClip*` words, harness
`core/tests/conformance/wm-clip`)
**Date:** 2026-08-31
**Depends on** ADR-0051 (`wmsurface`), ADR-0041 (`shmcreate`).
**Closes** the clipboard half of `display-protocol.md` §5.1 for a
cap-backed offer/take. Drag-and-drop beyond the selection is leftover.
**Number:** 0183 — after 0182 wallpaper menu. No new syscall. 11 stays
`fdwait`.

---

## 1. The question

Two clients need to move a small byte string without inventing sockets
or fd-passing. Wayland's answer is `wl_data_device` over a connection
this machine does not have. The surface protocol already names regions
by capability handle. The selection should be the same shape.

## 2. The decision

1. **Same syscall, two ops.** `wmOpOffer = 3` and `wmOpTake = 4` on
   syscall 23. Offer: handle + length. Take: dest handle; kernel copies
   into the caller's region and returns the length in `rax`.
2. **Cap-backed, not a bounce buffer.** Spare shm meta words 9..12 hold
   region, generation, owner, length. `wmStore` stays 448. No `@bss`.
   `wmeventStore` stays last.
3. **Sync copy.** TAKE finishes inside the caller's syscall. Nothing
   waits (GAP-0141). Stale gen or a dead offer region is `wmRetStale`.
4. **Max 4096 bytes this rung.** Larger payloads and mime types are
   leftover. DnD gestures are leftover.
5. **No help line. 11 is still `fdwait`.**

### 2.1 What this is not

Not Wayland. Not a pipe. Not drag-and-drop. Not a new syscall.

## 3. Binary

`wm-clip/`: `proc spawn A.ELF` offers `CLIPOK`; `proc spawn B.ELF`
takes into its own region and prints `WM CLIP B GOT CLIPOK`. Serial
also carries `WM OFFER` and `WM TAKE`.
