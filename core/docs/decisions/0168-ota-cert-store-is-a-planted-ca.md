# ADR-0168 — OTA cert store is a planted CA

**Status:** accepted, implemented (`core/plat/otatls/`,
`core/kernel/ota.dart`, `core/tests/conformance/ota-cert/`).
**Date:** 2026-08-30
**Number:** 0168 — 0167 is measured libcef slice. 0154 is the TLS
1.2 record layer (leaf fingerprint). Do not reuse those. Syscall 11
stays `fdwait`. This is the **cert store / chain verify** leftover
from ADR-0154 — not plat-tls / FSGS, not TLS 1.3, not Wi-Fi.

---

## 1. The question

ADR-0154 trusts a SHA-256 of the leaf DER. That is a fingerprint pin,
not a store. A portable update path that cannot plant a CA and refuse
a wrong chain is a half-eaten apple. The next binary is: OTACERT holds
the CA digest; the host presents leaf+CA; the client verifies the
leaf signature under that CA; a chain that does not meet the planted
CA leaves `SLOT.TXT` unchanged.

## 2. The decision

1. **`OTACERT` is the trust anchor digest.** Same FAT name as
   ADR-0154. One-cert flights still mean SHA-256(leaf) (ota-tls/
   unchanged). Two-or-more-cert flights mean SHA-256(CA): the CA
   DER must appear after the leaf in the Certificate list, and the
   leaf's RSA-PKCS1-SHA256 signature must verify under that CA's
   public key. Then the leaf key encrypts the premaster as before.
2. **Same `ota tls <port>` door.** No new shell command, no new
   syscall, not in `help`. Chain verify lives in `otatls.c`
   (`trust_cert_list`).
3. **Anti-vacuity.** Wrong CA chain → `OTA BADCERT`, slot
   unchanged. Right chain → `OTA OK` and host slot = payload. A
   leaf-only flight whose digest is not the planted CA still
   refuses (cannot stub "CA present" without a match).
4. **ZERO donated `.bss`.** Handshake transcript grows in the
   existing `.otatls_cmd` mailbox (`hs[4096]`). Offset 32960 stays.
5. **Not TLS 1.3.** That leftover stays named. Not Graphite /
   MakeVulkan / Venus. Not Wi-Fi. Not plat-tls / FSGS.

## 3. Binary exit

`ota-cert/run.sh`:

* Derives key/payload outside the kernel; builds a CA and a leaf
  signed by that CA (`rsa:1024`, SHA-256 — enough for chain shape,
  fast enough under QEMU TCG); plants `OTACERT` = SHA-256(CA DER),
  `OTAKEY`, `SLOT.TXT`.
* TLS 1.2 listener serves leaf+CA chain and the signed blob →
  `OTA OK`, host slot = payload.
* Same blob over a chain whose CA is not the planted one →
  `OTA BADCERT`, slot still `OLD!`.
* Structural: `trust_cert_list` / `rsa_pkcs1_sha256_verify` in
  `otatls.c`, ADR-0168 present, `ota-tls/` / `ota-host/` / `ota0/`
  remain, syscall 11 is `fdwait`, no help line, not Wi-Fi, not
  plat-tls / FSGS, not Graphite.

## 4. What this is not

Not TLS 1.3. Not a general multi-CA store UI. Not Wi-Fi. Not Dell
SKU. Not Graphite / MakeVulkan / Venus. Not `setfs` / FSGS. Not
`fdwait`. Leaf-fingerprint `ota-tls/` stays.

## 5. Leftover

TLS 1.3 record once a 1.3 cipher/handshake fits the same mailbox
door. This rung proves planted-CA chain verify + wrong-chain refuse.
