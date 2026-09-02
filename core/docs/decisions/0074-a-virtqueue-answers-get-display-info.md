# ADR-0074 — A virtqueue answers GET_DISPLAY_INFO

**Status:** accepted, implemented, verified (`tests/conformance/g3-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G3 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (control queue 0 + one command),
`core/tests/conformance/g3-virtgpu/run.sh`
**Depends on** ADR-0059 (the device is found), ADR-0065 (bus-master is
on), and ADR-0067 (DRIVER_OK).
**Does not close** a pixel (G4), or any of G5–G7.
**Number:** 0074 — 0067 is G2 DRIVER_OK; 0073 is a HID report.

---

## 1. The question

G2 wrote `DRIVER_OK`. A VirtIO device still will not move a request
until a virtqueue exists and the driver has published a descriptor
chain and rung notify. G3 is that first command: queue 0, three
frames, `GET_DISPLAY_INFO`. It is not a pixel and it is not
`SET_SCANOUT`.

## 2. The decision

1. **The sequence runs from the `virtgpu` command, after G2.**
   `virtgpuInit` stays a no-op. An absent device still prints
   `VIRTIO NONE` and touches neither configuration space nor a
   frame.
2. **Queue 0 only.** Write `queue_select = 0`, read `queue_size`
   (0 means the queue does not exist), cap at 64, allocate three
   `allocFrame()` frames and zero them, write `queue_desc` /
   `queue_driver` / `queue_device` as pairs of 32-bit halves
   (low first), then the enable field last.
3. **The header is 24 bytes, not 32.** A two-descriptor chain:
   a 24-byte `virtio_gpu_ctrl_hdr` with type `0x0100`, `NEXT`,
   then a 408-byte write-only `virtio_gpu_resp_display_info`.
4. **Poll `used.idx`.** Notify is
   `BAR[notify] + offset + queue_notify_off * multiplier`, a
   16-bit store of the queue index. A bound that expires prints
   `VIRTIO QTIMEOUT` rather than hanging the shell.
5. **Print `QSIZE`, `NSCAN`, `USED`, `RESP`, and scanout 0's
   rectangle and `enabled`.** `num_scanouts` comes from DEVICE_CFG
   + 8, not from a constant.
6. **`virtgpun` omits the notify store.** Same walk, same queue,
   same command. QEMU/TCG still performs virtqueue DMA with
   bus-master clear, so omitting BME is not a usable control here
   (G1 already proved the bit sticks). Omitting the doorbell
   leaves `used.idx` at 0 and prints `VIRTIO QTIMEOUT`. That is
   the measured claim that the notify write is what moved.
7. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block. Frames come
   from `allocFrame()`.

`GET_DISPLAY_INFO` does not leave VGA compatibility mode.
`SET_SCANOUT` does (VIRTIO §5.7.7), and that is G4.

## 3. What this is not

It is not a pixel (G4), not a resource, not virgl, and not a
claim that the host is displaying the guest's framebuffer. The
cursor queue is not touched.

## 4. Binary

`g3-virtgpu/run.sh`:

* boot `-vga none -device virtio-vga,xres=1136,yres=848`, type
  `virtgpu` then `fb`;
* require `VIRTIO RESP 00001101`, scanout 0 enabled with width
  1136 and height 848, `NSCAN 00000001`, and `USED` non-zero;
* `fb` still reports `MODE 0320x0258x20 OK` on that boot;
* the same kernel on `-vga std` prints `VIRTIO NONE` and no
  `QSIZE` / `USED` / `RESP`;
* `virtgpun` on the same device (notify omitted) prints
  `VIRTIO QTIMEOUT` and `USED 0000`.

Anti-vacuity is a zero dimension and a `used.idx` that never
moved. The 1136×848 pair is not QEMU's default, not the kernel's
compiled-in mode, and not the specification's fallback, and it
does not appear in `virtgpu.dart`.
