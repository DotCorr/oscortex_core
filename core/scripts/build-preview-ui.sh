#!/usr/bin/env bash
# Host osgfx module + DCDart @extern link (gfx0/gfx1/gfx2/cmod-ffi).
# Rasterizer is Skia Graphite. Darwin: Metal fallback (OSGFX_FORCE_METAL=1).
# Linux: Vulkan Graphite (lavapipe). Not a Cocoa window. Not sit-in.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$CORE/.." && pwd)"
SRC="$CORE/plat/osgfx"
OUT="$CORE/build"
mkdir -p "$OUT"

# shellcheck source=skia-host-cxx-flags.sh
source "$CORE/scripts/skia-host-cxx-flags.sh"
skia_host_cxx_flags

bash "$CORE/scripts/build-skia-graphite.sh"
SKIA_SRC="$OUT/skia/src"
SKIA_LIB="$OUT/skia/out/graphite/libskia.a"
[[ -f "$SKIA_LIB" ]] || { echo "build-preview-ui: no libskia.a" >&2; exit 2; }

HOST="$(uname -s)"

# Host objects MUST NOT share names with build-kernel.sh's guest-elf
# outputs (osgfx_scene.o, osgfx_graphite.o).
if [[ "$HOST" == "Darwin" ]]; then
  FW=(
    -framework Metal -framework Foundation -framework QuartzCore
    -framework CoreFoundation -framework CoreGraphics -framework CoreText
    -framework CoreServices -framework ImageIO
  )
  clang++ -fobjc-arc -std=c++17 -O2 -Wall -Wextra \
    -I "$SRC" -I "$SKIA_SRC" \
    -c -o "$OUT/osgfx_graphite_host.o" "$SRC/osgfx_graphite.mm"
  clang -fobjc-arc -O2 -Wall -Wextra \
    -I "$SRC" \
    -c -o "$OUT/osgfx_metal_host.o" "$SRC/osgfx_metal.m"
  HOST_OBJS=("$OUT/osgfx_graphite_host.o" "$OUT/osgfx_metal_host.o")
  HOST_LIBS=("${FW[@]}" -lc++)
else
  clang++ -std=c++17 -O2 -Wall -Wextra \
    "${SKIA_HOST_CXX_FLAGS[@]}" \
    -I "$SRC" -I "$SKIA_SRC" \
    -c -o "$OUT/osgfx_graphite_host.o" "$SRC/osgfx_graphite_linux.cpp"
  HOST_OBJS=("$OUT/osgfx_graphite_host.o")
  HOST_LIBS=("${SKIA_HOST_CXX_FLAGS[@]}" -lvulkan -lc++)
fi

clang -O2 -Wall -Wextra \
  -I "$SRC" \
  -c -o "$OUT/osgfx_scene_host.o" "$SRC/osgfx_scene.c"
clang -O2 -Wall -Wextra \
  -I "$SRC" \
  -c -o "$OUT/headless_main.o" "$SRC/headless_main.c"

clang++ -O2 \
  -o "$OUT/osgfx-headless" \
  "${HOST_OBJS[@]}" \
  "$OUT/osgfx_scene_host.o" \
  "$OUT/headless_main.o" "$SKIA_LIB" \
  "${HOST_LIBS[@]}"
echo "built $OUT/osgfx-headless"

if [[ "${1:-}" == "--headless" ]]; then
  exit 0
fi

DCDART_HOME="${DCDART_HOME:-$REPO/../DCDart}"
if [[ ! -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]]; then
  echo "build-preview-ui: no DCDart at $DCDART_HOME (set DCDART_HOME)" >&2
  exit 2
fi
HOST_DART="$OUT/host-dart/dart-sdk/bin/dart"
if [[ -x "$HOST_DART" ]]; then
  DART="$HOST_DART"
elif command -v dart >/dev/null 2>&1; then
  DART="$(command -v dart)"
else
  echo "build-preview-ui: dart not on PATH (source env.sh)" >&2
  exit 2
fi

DCDART_LINK="$OUT/dcdart"
if [[ -L "$DCDART_LINK" ]]; then
  rm -f "$DCDART_LINK"
elif [[ -e "$DCDART_LINK" ]]; then
  echo "build-preview-ui: $DCDART_LINK exists and is not a symlink" >&2
  exit 2
fi
ln -s "$DCDART_HOME" "$DCDART_LINK"
PRELUDE="$DCDART_LINK/core/runtime/dc-core-bare/prelude.dart"
EXPECTED="import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';"
if ! grep -qxF -- "$EXPECTED" "$SRC/osgfx.dart"; then
  echo "build-preview-ui: osgfx.dart prelude import is not ADR-0043" >&2
  exit 2
fi

if ! ( cd "$SRC" && "$DART" "$DCDART_HOME/core/dcc/bin/dcc.dart" build --mode bare --target host \
    --prelude "$PRELUDE" osgfx.dart -o "$OUT/osgfx_ffi.o" ); then
  if [[ -f "$OUT/osgfx_ffi.o" ]]; then
    echo "build-preview-ui: dcc failed; reusing $OUT/osgfx_ffi.o"
  else
    echo "build-preview-ui: dcc failed and no osgfx_ffi.o to reuse" >&2
    exit 2
  fi
fi
clang -O2 -Wall -Wextra -I "$SRC" -c -o "$OUT/osgfx_ffi_abi.o" "$SRC/osgfx_ffi.c"
clang -O2 -Wall -Wextra -I "$SRC" -c -o "$OUT/ffi_main.o" "$SRC/ffi_main.c"
clang++ -O2 \
  -o "$OUT/osgfx-ffi" \
  "${HOST_OBJS[@]}" \
  "$OUT/osgfx_scene_host.o" \
  "$OUT/osgfx_ffi_abi.o" "$OUT/ffi_main.o" "$OUT/osgfx_ffi.o" \
  "$SKIA_LIB" \
  "${HOST_LIBS[@]}"
echo "built $OUT/osgfx-ffi"
