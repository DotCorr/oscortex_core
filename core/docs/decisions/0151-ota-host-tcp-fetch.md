# ADR-0151 — OTA fetches a signed blob from a real host over TCP

**Status:** accepted, implemented (`core/kernel/ota.dart`,
`core/tests/conformance/ota-host/`).
**Date:** 2026-08-30
**Number:** 0151 — 0148 is plat-tls (FSGS / `setfs`). 0149 is FILES
move/rename. 0150 is `shmgrow`. 0140 is the COM1 hex plant. Do not
reuse those numbers. Syscall 11 stays `fdwait`.
This is **transport** TLS leftover naming only — not HTTPS yet, and
not the platform thread-local door.

---

## 1. The question

ADR-0140 proved signed apply from an RX plant typed on COM1. That is
not a host fetch. A portable update path has to pull a signed blob
from an endpoint the QEMU NIC can reach, verify it with the same
keyed digest, and refuse when the signature is wrong or the host is
unreachable — leaving `SLOT.TXT` unchanged. HTTPS/TLS record layer is
larger than this rung; plain TCP is the door.

## 2. The decision

1. **`ota get <port>` is the host fetch.** Connects to
   `10.0.2.2:<port>` (SLIRP's host). The harness starts a listener on
   that port and serves the signed `OTA1` blob. Not in `help`. No new
   syscall.
2. **Same plant and apply as ADR-0140.** Magic, BE paylen, 8-byte
   keyed XOR signature, payload into `SLOT.TXT`. `otaApplyPlant` is
   shared with `ota feed`.
3. **Minimal TCP client in the kernel.** ARP for the gateway, SYN /
   SYN-ACK / ACK, then one data segment. Checksums use `nicCsum` /
   a TCP pseudo-header fold. Stop-and-wait; one outstanding segment.
   No `netTick`, no IRQ 11, no socket syscall.
4. **Anti-vacuity.** No listener (RST or RX timeout) → `OTA NOHOST`,
   slot unchanged. Bad signature from the host → `OTA BADSIG`, slot
   unchanged. Good fetch → `OTA OK` and host image readback matches.
5. **ZERO donated `.bss`.** Frames from `allocFrame()`.
   `wmeventStore` stays last.

## 3. Binary exit

`ota-host/run.sh`:

* Derives key, payload, signature outside the kernel (absent from
  `ota.dart`).
* Host TCP listener serves the good blob; guest `ota get <port>` →
  `OTA OK`, `SLOT.TXT` = payload.
* Same listener serves a flipped-sig blob → `OTA BADSIG`, slot
  still `OLD!`.
* No listener on the port → `OTA NOHOST`, slot unchanged.
* Structural: no `@bss` in `ota.dart`, no help line, syscall 11 is
  still `fdwait`, not Wi-Fi, not plat-tls / FSGS, plant bytes absent
  from `ota.dart`. `ota0/` remains the COM1 plant harness.

## 4. What this is not

Not HTTPS / TLS 1.2 record layer. Not Wi-Fi. Not Dell SKU. Not
Graphite / MakeVulkan / Venus. Not `setfs` / FSGS (ADR-0148). Not
`fdwait`. Those leftovers stay named.

## 5. Leftover

~~HTTPS (or a TLS door that is not cleartext TCP)~~ closed by
ADR-0154 (`ota tls` / `ota-tls/`). Remaining: cert store / TLS 1.3.
This rung proves real host TCP fetch + signed apply + unreachable
refusal.
