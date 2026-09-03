#!/usr/bin/env bash
# Fetch and build Skia Graphite + Metal for this arm64 Mac.
# Not brew graphite2 (font shaper). Not Flutter.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$CORE/build/skia"
SRC="$ROOT/src"
OUT="$ROOT/out/graphite"
LIB="$OUT/libskia.a"

if [[ -f "$LIB" ]]; then
  echo "skia: $LIB"
  exit 0
fi

mkdir -p "$ROOT"
if [[ ! -d "$SRC/.git" ]]; then
  # First verified drop: 3ae8e3d1e3358c2c805f17b1092d4d3ee5d4bb7b
  git clone --depth 1 --single-branch --branch main \
    https://github.com/google/skia.git "$SRC"
fi

if [[ "${SKIA_FETCH_ONLY:-0}" == 1 ]]; then
  echo "skia: source $SRC"
  exit 0
fi

if [[ ! -x "$SRC/bin/gn" ]]; then
  ( cd "$SRC" && python3 bin/fetch-gn )
fi

# No git-sync-deps: Graphite+Metal with codecs/fonts/Vulkan/Dawn off
# does not need third_party/externals.
ARGS='
is_official_build=true
is_debug=false
target_cpu="arm64"
skia_use_metal=true
skia_enable_graphite=true
skia_enable_ganesh=false
skia_use_gl=false
skia_use_vulkan=false
skia_use_dawn=false
skia_use_angle=false
skia_enable_pdf=false
skia_enable_svg=false
skia_enable_skottie=false
skia_use_icu=false
skia_use_harfbuzz=false
skia_use_freetype=false
skia_use_expat=false
skia_use_libjpeg_turbo_decode=false
skia_use_libjpeg_turbo_encode=false
skia_use_libpng_decode=false
skia_use_libpng_encode=false
skia_use_libwebp_decode=false
skia_use_libwebp_encode=false
skia_use_wuffs=false
skia_use_zlib=false
skia_use_piex=false
skia_use_perfetto=false
skia_use_partition_alloc=false
skia_enable_fontmgr_empty=true
skia_enable_precompile=false
skia_use_xps=false
skia_enable_tools=false
'
( cd "$SRC" && "$SRC/bin/gn" gen "$OUT" --args="$ARGS" )
ninja -C "$OUT" skia
[[ -f "$LIB" ]] || { echo "build-skia-graphite: no $LIB" >&2; exit 1; }
echo "skia: $LIB"
