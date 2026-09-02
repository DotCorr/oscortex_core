# ADR-0154 — OTA fetches a signed blob over TLS 1.2

**Status:** accepted, implemented (`core/plat/otatls/`,
`core/kernel/ota.dart`, `core/tests/conformance/ota-tls/`).
**Date:** 2026-08-30
**Number:** 0154 — 0153 is chrome-rrect. 0151 is plain TCP OTA.
0152 is tiny libc. Do not reuse those. Syscall 11 stays `fdwait`.
This is the **TLS record layer** leftover from ADR-0151 — not
plat-tls / FSGS (`setfs`, ADR-0148).

---

## 1. The question

ADR-0151 proved signed apply from a real host over cleartext TCP to
`10.0.2.2`. A portable update path that stops at cleartext is a
half-eaten apple. The next binary is a TLS 1.2 session to the same
host endpoint: ClientHello on the wire, leaf fingerprint check,
encrypted application data carrying the same `OTA1` plant. Falling
back to plain TCP and calling it TLS is forbidden.

## 2. The decision

1. **`ota tls <port>` is the TLS fetch.** Connects to
   `10.0.2.2:<port>` (SLIRP host). The harness starts a real TLS
   1.2 listener (`ssl.PROTOCOL_TLS_SERVER`, cipher `AES128-SHA`)
   and serves the signed `OTA1` blob as application data. Not in
   `help`. No new syscall.
2. **C mailbox `otatls`.** Freestanding TLS 1.2 client
   (`TLS_RSA_WITH_AES_128_CBC_SHA`) in `core/plat/otatls/otatls.c`,
   section `.otatls_cmd` at `kernel_data_start + 32960`. Dart owns
   TCP; `tick_count` drives `otatls_guest_tick` (shell context, not
   a long IRQ). Same `otaApplyPlant` as feed/get.
3. **`OTACERT` is the leaf trust.** FAT file holds the SHA-256 of
   the expected leaf DER. Mismatch → `OTA BADCERT`, slot unchanged.
4. **Anti-vacuity.** No listener → `OTA NOHOST`. Bad signature from
   the host → `OTA BADSIG`. Bad cert → `OTA BADCERT`. A plain TCP
   listener on the same port must not produce `OTA OK`.
5. **ZERO donated `.bss`.** TLS session state lives in `.otatls_cmd`
   `.data`. `wmeventStore` stays last. Not plat-tls / FSGS. Not
   Graphite / MakeVulkan / Venus. Not Wi-Fi.

## 3. Binary exit

`ota-tls/run.sh`:

* Derives key, payload, signature, and a 2048-bit leaf outside the
  kernel; plants `OTAKEY`, `OTACERT`, `SLOT.TXT` on FAT16.
* TLS listener serves the good blob; guest `ota tls <port>` →
  `OTA OK`, host slot = payload.
* Flipped-sig blob → `OTA BADSIG`, slot still `OLD!`.
* Wrong leaf cert → `OTA BADCERT`, slot unchanged.
* No listener → `OTA NOHOST`.
* Plain TCP on the port (no TLS) → not `OTA OK` (anti-vacuity).
* Structural: `otatls_guest_cmd` linked, ClientHello / `0x002f` in
  `otatls.c`, syscall 11 is `fdwait`, `ota get` still cleartext,
  `ota0/` and `ota-host/` remain.

## 4. What this is not

Not TLS 1.3. Not a general cert store / CA chain. Not Wi-Fi. Not
Dell SKU. Not Graphite / MakeVulkan / Venus. Not `setfs` / FSGS.
Not `fdwait`. Those leftovers stay named.

## 5. Leftover

~~Cert store / chain verify~~ closed by ADR-0168 (`ota-cert/`).
Remaining: TLS 1.3 record once a 1.3 cipher/handshake fits the same
mailbox door. This rung proved real host TLS fetch + fingerprint
refuse + signed apply.
