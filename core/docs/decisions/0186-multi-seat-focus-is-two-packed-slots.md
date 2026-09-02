# ADR-0186 — Multi-seat focus is two packed slots

**Status:** accepted, implemented (`wmOpSeat` / `wmOpSeatGet` in
`wmext.dart`, seat1 in high byte of `wmMetaFocus`, harness
`core/tests/conformance/wm-seat`)
**Date:** 2026-08-31
**Depends on** ADR-0062, ADR-0183.
**Closes** a second input focus slot from `display-protocol.md` §5.1.
Per-seat pointer hardware and seat-routed `kbdevent` are leftover.
**Number:** 0186. No new syscall. 11 stays `fdwait`. `wmStore` stays 448.

---

## 1. Decision

1. **`wmMetaFocus` packs two PLUS-ONE slots.** Bits 0..7 seat 0 (legacy
   click focus); bits 8..15 seat 1. [wmFocusTo] / [wmFocusLive] keep
   the seat-0 contract for D9 / `kbdq`.
2. **`wmOpSeat = 6`.** Word 2 is the seat index; handle names the
   caller's window (0 clears). Prints `WM SEAT`.
3. **`wmOpSeatGet = 8`.** `rax` bits: which seats focus a window owned
   by the caller.
4. **Two seats this rung.** More seats and independent pointer devices
   are leftover.

## 2. Binary

`wm-seat/`: one PROG attaches two surfaces, sets seat 0 → first and
seat 1 → second, prints `WM SEAT BITS 3` and `WM SEAT OK`. Kernel
`WM SEAT` lines name both slots.
