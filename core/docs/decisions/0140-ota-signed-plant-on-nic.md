# ADR-0140 — OTA signed plant on NIC

**Status:** accepted, implemented (`core/kernel/ota.dart`,
`core/tests/conformance/ota0/`).
**Date:** 2026-08-30
**Number:** 0140. Syscall 11 stays `fdwait`.

---

## 1. The question

A portable OS needs a signed update path. Shipping an unsigned blob
over e1000 and printing `OTA OK` would be a stub. The plant must be
derived outside the kernel, delivered on a NIC class already proven
(e1000 / virtio-net class door), verified against a harness-planted
key, and refused when the signature is wrong — leaving the FAT slot
unchanged.

## 2. The decision

1. **`ota feed <hex>` is the RX plant.** Same shape as `usb feed`:
   the harness types a derived plant onto the shell line. The plant
   is the update blob as if it had arrived on the wire. Not in
   `help`. No new syscall.
2. **NIC class gate.** `pciFindByClass(02/00)` must find an Ethernet
   function (e1000 or virtio-net). Absent → `OTA NONIC`. That is the
   anti-vacuity for "over a NIC class."
3. **Blob layout.** `OTA1` magic, BE `paylen`, 8-byte signature,
   then `paylen` payload bytes (1..64). Signature is an 8-byte keyed
   XOR mix of `OTAKEY` and the payload (DCDart traps on u64 overflow,
   so no wide FNV accumulator).
4. **Apply.** Good signature → overwrite planted `SLOT.TXT` with the
   payload and update its directory size. Bad signature →
   `OTA BADSIG` and the slot's bytes are untouched.
5. **ZERO donated `.bss`.** One `allocFrame()` holds the plant and
   the key copy. `wmeventStore` stays last.

## 3. Binary exit

`ota0/run.sh`:

* Derives key, payload, and signature at test time (not kernel
  constants).
* Plants `OTAKEY` + `SLOT.TXT` (= `OLD!`) on a FAT16 IDE image.
* Good feed → serial `OTA OK`, `cat slot.txt` prints the payload,
  host image readback matches the payload.
* Bad feed (one flipped sig byte) → `OTA BADSIG`, host readback
  still `OLD!`.
* `-net none` → `OTA NONIC`, slot unchanged.
* Structural: no `@bss` in `ota.dart`, no help line, syscall 11 is
  still `fdwait`, plant bytes absent from `ota.dart`.

## 4. What this is not

Not TLS. Not HTTPS to a real host. Not Wi-Fi join. Not Dell SKU.
Not Graphite / MakeVulkan / Venus. Those leftovers stay named.

## 5. Leftover

~~Real host fetch~~ closed by ADR-0151 (`ota get` over plain TCP to
`10.0.2.2`). Remaining: HTTPS / TLS record layer to the same host
endpoint. This rung proves signed apply + NIC-class gate + bad-sig
refusal.
