# ADR-0177 — OTA fetches a signed blob over TLS 1.3

**Status:** accepted, implemented (`core/plat/otatls/`,
`core/kernel/ota.dart`, `core/tests/conformance/ota-tls13/`).
**Date:** 2026-08-30
**Number:** 0177 — 0169 is memset-plt; 0168 is ota-cert / full-libcef.
Syscall 11 stays `fdwait`. Not plat-tls / FSGS.

---

## 1. The question

ADR-0154 and ADR-0168 proved TLS 1.2 fetch with leaf fingerprint or
planted-CA chain verify. The named OTA leftover was TLS 1.3: a modern
record layer on the same mailbox door without breaking the 1.2 path.

## 2. The decision

1. **`ota tls13 <port>` is the TLS 1.3 fetch.** Not in `help`. Matched
   before `ota tls` in `shell.dart`. Sets `stage=10` before GO.
2. **Same `.otatls_cmd` mailbox at offset 32960.** Stage 0..5 stays
   TLS 1.2 AES128-SHA byte-identical. Stage >= 10 is TLS 1.3:
   `TLS_AES_128_GCM_SHA256` (0x1301), X25519, HKDF-SHA256, AES-GCM,
   RSA-PSS-SHA256 CertificateVerify.
3. **OTACERT unchanged.** Leaf fingerprint or planted CA (ADR-0168).
4. **Anti-vacuity.** Plain TCP or TLS 1.2-only on the port must not
   produce `OTA OK`.

## 3. Binary exit

`ota-tls13/run.sh`:

* Python `ssl` TLS 1.3-only server (`minimum=maximum=TLSv1_3`,
  cipher `TLS_AES_128_GCM_SHA256`).
* Good → `OTA OK`, slot = payload.
* Bad leaf → `OTA BADCERT`, slot `OLD!`.
* Plain TCP or TLS 1.2-only → not `OTA OK`.
* `ota-tls/`, `ota-cert/`, `ota-host/`, `ota0/` remain PASS.

## 4. Leftover

OTA TLS closed. Remaining portable-hardware leftover: Wi-Fi only.
