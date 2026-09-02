# ADR-0199 — The abs pointer door carries e1000 + OTA keys

**Status:** accepted, implemented (`scripts/sit-in-view.sh --abs`)
**Date:** 2026-09-02
**Number:** 0199 — 0198 is frosted glass. Do not reuse.
Syscall 11 stays `fdwait`. No sshd.

---

## 1. The question

ADR-0193 made `sit-in-view.sh --abs` the clickable cocoa door
(`oscortex-abs-pointer` + `virtio-tablet-pci`). That launch omitted a
NIC and the sit-in FAT had no `OTAKEY` / `SLOT.TXT`, so live
`ota get` (ADR-0151) could not run on the door the owner clicks.
Harness `ota-host/` already PASSed headless with SLIRP + e1000.

## 2. The decision

1. **`--abs` attaches the same net as `ota-host/`.**
   `-net none -netdev user,id=n0,net=10.0.2.0/24`
   `-device e1000,netdev=n0,mac=52:54:00:0A:14:49,romfile=`.
   The OS reaches the host at `10.0.2.2:<port>`.
2. **Sit-in FAT for abs plants `OTAKEY` + `SLOT.TXT`.** Appended
   after `de-sitfat` ELFs so Start's first-four launch floor is
   unchanged. Blob + meta live under `build/sit-in-view/`.
3. **`--abs` replaces the door by name.** Ordinary `--kill` still
   leaves abs up (GAP-0355); `--abs` / `--kill-all` tear it down so
   the disk unlocks for relaunch.
4. **Prove:** host listener serves `ota-blob.bin`; QMP types
   `ota get <port>` **before** the Start click (shell still owns
   kbdq); serial `OTA OK`; Start click still works afterward.

## 3. Binary exit

Live `oscortex-abs-pointer` with e1000; serial `OTA OK <paylen>` from
`ota get` typed **before** the Start click (D9: focused clients own
kbdq — shell keys must run while focus is none); post-OTA
`MOUSE ABS` + `WM DE START` still land. No SSH. Tablet + cocoa
unchanged.

## 4. What this is not

Not Wi-Fi. Not TLS (`ota tls` stays ADR-0154). Not DHCP/DNS beyond
SLIRP. Not inventing sshd. Owner re-trigger after Start: click empty
desk (returns keyboard to the shell), serve `ota-blob.bin` on a host
port, type `ota get <port>`.
