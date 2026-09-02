# ADR-0139 — 802.11 first class door (OPEN leftover)

**Status:** OPEN — not implemented. Honest leftover.
**Date:** 2026-08-30
**Number:** 0139 — reserved for the first Wi-Fi class door.
Syscall 11 stays `fdwait`.

---

## 1. Why this is not a PASS

QEMU 11.0.0 on this Mac exposes **no 802.11 / Wi-Fi device**
(`qemu-system-x86_64 -device help` has no wlan/ath/iwl/802.11
backend). Relabeling e1000 or virtio-net as "wifi" would be a stub
PASS and is refused.

Metal Wi-Fi needs signed firmware the same way `gpu.md` described
for vendor GPUs. That is not a weekend class door under QEMU.

## 2. Binary next step (when a device exists)

1. Name a **class** probe (PCI class / subclass / prog-IF, or a
   documented VirtIO/USB WLAN id), not a Dell SKU.
2. Harness attaches that device (or a measured emulator) and
   requires a derived refuse or a derived MAC/SSID plant.
3. Anti-vacuity: e1000 / virtio-net boots must not satisfy the
   Wi-Fi harness.

Until then: leave OPEN. Do not claim ADR-0139 implemented.
