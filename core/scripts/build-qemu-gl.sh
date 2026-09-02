#!/usr/bin/env bash
# core/scripts/build-qemu-gl.sh
#
# Homebrew QEMU on this arm64 Mac (11.0.0) has no virtio-gpu-gl-pci
# and was not linked against virglrenderer. There is no brew option
# that adds it: the bottle is cocoa-only (none/curses/cocoa/dbus).
#
# 3D QEMU for G10: Debian sid's qemu-system-modules-opengl +
# libvirglrenderer1, run under Docker Desktop (linux/aarch64) with
# Xvfb and llvmpipe. x11vnc is included so sit-in-view.sh --venus can
# mirror the Xvfb to the Mac (QEMU -vnc cannot share a GL context;
# ADR-0175).
#
#   bash scripts/build-qemu-gl.sh
#   docker run --rm oscortex-qemu-gl:local \
#     qemu-system-x86_64 -device virtio-gpu-gl-pci,help
#
# Proven: QEMU 11.1.0 (Debian 1:11.1.0+ds-2), virtio-gpu-gl-pci
# present, VIRTIO_GPU_F_VIRGL offered, num_capsets=2.

set -euo pipefail

IMAGE="${OSCORTEX_QEMU_GL_IMAGE:-oscortex-qemu-gl:local}"

docker rm -f oscortex-qemu-gl-build >/dev/null 2>&1 || true
docker run --name oscortex-qemu-gl-build debian:sid-slim bash -c \
  'set -e
   apt-get update -qq
   DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
     qemu-system-x86 qemu-system-modules-opengl qemu-system-gui \
     libvirglrenderer1 libegl1 libgl1-mesa-dri xvfb x11vnc'
docker commit oscortex-qemu-gl-build "$IMAGE"
docker rm oscortex-qemu-gl-build >/dev/null
echo "build-qemu-gl: $IMAGE"
docker run --rm "$IMAGE" qemu-system-x86_64 -version
docker run --rm "$IMAGE" qemu-system-x86_64 -device help | grep -E 'virtio-gpu-gl'
