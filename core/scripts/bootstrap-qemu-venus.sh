#!/usr/bin/env bash
# User-local virglrenderer (venus=true) + QEMU 9.2 with venus=on.
# Does not replace the distro qemu. Prefix default: $REPO/.qemu-venus
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
PREFIX="${OSCORTEX_QEMU_VENUS_PREFIX:-$REPO_DIR/.qemu-venus}"
SRC="$PREFIX/src"
# Pinned public tags. SHAs recorded after clone.
VIRGL_TAG="${OSCORTEX_VIRGL_TAG:-virglrenderer-1.1.0}"
QEMU_TAG="${OSCORTEX_QEMU_TAG:-v9.2.0}"
VIRGL_REPO="https://gitlab.freedesktop.org/virgl/virglrenderer.git"
QEMU_REPO="https://gitlab.com/qemu-project/qemu.git"

fail() { echo "bootstrap-qemu-venus: FAIL — $*" >&2; exit 1; }
say() { echo "bootstrap-qemu-venus: $*" >&2; }

if [[ -x "$PREFIX/bin/qemu-system-x86_64" ]]; then
  if "$PREFIX/bin/qemu-system-x86_64" -device virtio-gpu-gl-pci,help 2>&1 \
      | grep -q 'venus'; then
    say "already present with venus= at $PREFIX"
    echo "QEMU=$PREFIX/bin/qemu-system-x86_64"
    exit 0
  fi
fi

command -v git >/dev/null || fail "git missing"
command -v ninja >/dev/null || fail "ninja missing"
if ! command -v meson >/dev/null 2>&1; then
  say "installing meson via pip --user"
  python3 -m pip install --user meson >/dev/null
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v meson >/dev/null || fail "meson missing"
[[ -f /usr/include/vulkan/vulkan.h ]] || fail "libvulkan-dev headers missing"
command -v pkg-config >/dev/null || fail "pkg-config missing"

mkdir -p "$SRC"
if [[ ! -d "$SRC/virglrenderer/.git" ]]; then
  say "cloning $VIRGL_REPO @$VIRGL_TAG"
  git clone --depth 1 --branch "$VIRGL_TAG" "$VIRGL_REPO" "$SRC/virglrenderer" >&2
fi
VIRGL_SHA="$(git -C "$SRC/virglrenderer" rev-parse HEAD)"
say "virglrenderer $VIRGL_TAG $VIRGL_SHA"
if [[ ! -f "$PREFIX/lib/pkgconfig/virglrenderer.pc" && \
      ! -f "$PREFIX/lib/x86_64-linux-gnu/pkgconfig/virglrenderer.pc" ]]; then
  say "building virglrenderer -Dvenus=true"
  meson setup "$SRC/virglrenderer/build" "$SRC/virglrenderer" \
    --prefix="$PREFIX" -Dvenus=true -Dtests=false >&2 \
    || fail "meson setup virglrenderer"
  meson compile -C "$SRC/virglrenderer/build" >&2 || fail "compile virglrenderer"
  meson install -C "$SRC/virglrenderer/build" >&2 || fail "install virglrenderer"
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

if [[ ! -d "$SRC/qemu/.git" ]]; then
  say "cloning $QEMU_REPO @$QEMU_TAG (this is large)"
  git clone --depth 1 --branch "$QEMU_TAG" --recurse-submodules --shallow-submodules \
    "$QEMU_REPO" "$SRC/qemu" >&2 \
    || git clone --depth 1 --branch "$QEMU_TAG" "$QEMU_REPO" "$SRC/qemu" >&2
fi
QEMU_SHA="$(git -C "$SRC/qemu" rev-parse HEAD)"
say "qemu $QEMU_TAG $QEMU_SHA"

if [[ ! -x "$PREFIX/bin/qemu-system-x86_64" ]]; then
  say "configuring qemu (virgl + opengl, user prefix)"
  mkdir -p "$SRC/qemu/build"
  (
    cd "$SRC/qemu/build"
    GTK_FLAG=()
    if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
      say "gtk+-3.0 not present — egl-headless needs a DRM node; GTK+GLX does not"
    fi
    if pkg-config --exists gtk+-3.0 2>/dev/null; then
      GTK_FLAG=(--enable-gtk)
    fi
    ../configure --prefix="$PREFIX" --target-list=x86_64-softmmu \
      --enable-virglrenderer --enable-opengl --enable-slirp --disable-docs \
      --disable-user --disable-werror \
      "${GTK_FLAG[@]}" \
      --extra-cflags="-I$PREFIX/include" \
      --extra-ldflags="-L$PREFIX/lib -L$PREFIX/lib/x86_64-linux-gnu" \
      >&2
  ) || fail "qemu configure"
  say "compiling qemu (several minutes)"
  ninja -C "$SRC/qemu/build" qemu-system-x86_64 >&2 || fail "qemu ninja"
  ninja -C "$SRC/qemu/build" install >&2 || fail "qemu install"
fi

[[ -x "$PREFIX/bin/qemu-system-x86_64" ]] || fail "qemu binary missing"
if ! "$PREFIX/bin/qemu-system-x86_64" -device virtio-gpu-gl-pci,help 2>&1 \
    | grep -q 'venus'; then
  "$PREFIX/bin/qemu-system-x86_64" -device virtio-gpu-gl-pci,help >&2 || true
  fail "built qemu still has no venus= property"
fi
mkdir -p "${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
cat >"${ARTIFACTS_DIR:-/opt/cursor/artifacts}/oscortex-round26-qemu-venus.json" <<EOF
{
  "ok": true,
  "prefix": "$PREFIX",
  "virgl_tag": "$VIRGL_TAG",
  "virgl_sha": "$VIRGL_SHA",
  "qemu_tag": "$QEMU_TAG",
  "qemu_sha": "$QEMU_SHA",
  "venus_property": true
}
EOF
say "PASS qemu=$PREFIX/bin/qemu-system-x86_64 venus= yes"
echo "QEMU=$PREFIX/bin/qemu-system-x86_64"
