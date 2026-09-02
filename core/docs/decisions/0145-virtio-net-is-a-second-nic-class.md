# ADR-0145 — VirtIO-net is a second NIC class

**Status:** accepted, implemented (`core/kernel/virtnet.dart`,
`core/tests/conformance/net-virtio`)
**Date:** 2026-08-30
**Depends on** N0 (ADR-0058), VirtIO PCI cap walk (ADR-0059 shape).
**Does not close** TX/RX rings, ARP/ICMP on VirtIO, Wi-Fi, or OTA.
**Number:** 0145 — 0142 is configure-to-client; 11 stays `fdwait`.
Not in `help`.

---

## 1. The question

N0–N3 drive the e1000 that QEMU's default machine already has. A
portable net path cannot be "only 8086:100E". VirtIO-net is the
hypervisor NIC class (vendor `1AF4`, device `1041`). Matching an
e1000 SKU and renaming the print is not a second class.

## 2. The decision

1. **New file `virtnet.dart`, appended after `virtgpu3d.dart`.**
   Zero `@bss`. Re-walks bus 0 for `1AF4:1041`. Resolves
   `VIRTIO_PCI_CAP_DEVICE_CFG` and reads the six-byte MAC. Does not
   rewrite `nic.dart`.
2. **Hidden command `nic virtio`.** Longest-first before `nic ping` /
   `nic send` / `nic arp` / `nic`. Prints `NIC VIRTIO aa:bb:…` or
   `NIC VIRTIO NONE` / `NIC VIRTIO NOCFG`.
3. **Class is the VirtIO-net device id, not a laptop OEM.** QEMU
   `-device virtio-net-pci` is the stand-in. e1000 stays N0.

## 3. Binary

`net-virtio/run.sh` attaches `-device virtio-net-pci,mac=<derived>`
(and may keep the default e1000). `nic virtio` prints that MAC.
Anti-vacuity: info pci has `1af4:1041`; the MAC is not in
`virtnet.dart` / `nic.dart`; plain `-M pc` without VirtIO prints
`NIC VIRTIO NONE`. Bare `nic` still prints the e1000 MAC when that
device is present.

## 4. What this is not

Not TX. Not ARP/ICMP on VirtIO. Not Wi-Fi. Not OTA. Not an e1000
relabel. Not Graphite.
