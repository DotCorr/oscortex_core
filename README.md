# oscortex_core

A from-scratch modern operating system, written primarily in [DCDart](https://github.com/DotCorr/DCDart)
— a native systems language with Dart's syntax, ARC memory management, no VM.

Everything buildable lives under [`core/`](core/README.md). Start there.

## Status

**M0 — done.** A `@bare` DCDart kernel boots under QEMU (x86_64, Multiboot1) and proves it's alive
over COM1 serial output — verified end to end (`core/tests/conformance/m0-boot/run.sh`), not a stub.
See [`core/README.md`](core/README.md) for the details. Nothing past M0 is built yet.
