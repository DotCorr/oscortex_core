#!/usr/bin/env bash
# Platform clang + official FFmpeg. Not an app ELF. Not Flutter. Not osgfx.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$CORE/plat/media"
OUT="$CORE/build"
mkdir -p "$OUT"

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "build-osmedia: pkg-config not on PATH" >&2
  exit 2
fi
for mod in libavcodec libavformat libavutil libswscale; do
  if ! pkg-config --exists "$mod"; then
    echo "build-osmedia: $mod not found (brew install ffmpeg)" >&2
    exit 2
  fi
done

FF_CFLAGS="$(pkg-config --cflags libavcodec libavformat libavutil libswscale)"
FF_LIBS="$(pkg-config --libs libavcodec libavformat libavutil libswscale)"

# Planted solid-colour clip. Derived colour is OSMEDIA_FRAME (0xC04088).
# Real H.264 in a real container — not a hand-rolled parser.
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "build-osmedia: ffmpeg CLI not on PATH (needed to plant the clip)" >&2
  exit 2
fi
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0xC04088:s=64x64:d=0.2:r=10" \
  -frames:v 2 -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
  "$OUT/osmedia-clip.mp4"

clang -O2 -Wall -Wextra -Werror -I "$SRC" $FF_CFLAGS \
  -c -o "$OUT/osmedia.o" "$SRC/osmedia.c"

clang -O2 -Wall -Wextra -Werror -I "$SRC" \
  -c -o "$OUT/osmedia_headless_main.o" "$SRC/headless_main.c"

clang -O2 -o "$OUT/osmedia-headless" \
  "$OUT/osmedia.o" "$OUT/osmedia_headless_main.o" \
  $FF_LIBS
echo "built $OUT/osmedia-headless"

if [[ "${1:-}" == "--headless" ]]; then
  exit 0
fi

# --- DCDart @extern FFI (optional sibling, same FFmpeg). ---
REPO="$(cd "$CORE/.." && pwd)"
DCDART_HOME="${DCDART_HOME:-$REPO/../DCDart}"
if [[ ! -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]]; then
  echo "build-osmedia: no DCDart at $DCDART_HOME (C headless is the floor)"
  exit 0
fi
HOST_DART="$OUT/host-dart/dart-sdk/bin/dart"
if [[ -x "$HOST_DART" ]]; then
  DART="$HOST_DART"
elif command -v dart >/dev/null 2>&1; then
  DART="$(command -v dart)"
else
  echo "build-osmedia: dart not on PATH (C headless is the floor)"
  exit 0
fi

DCDART_LINK="$OUT/dcdart"
if [[ -L "$DCDART_LINK" ]]; then
  rm -f "$DCDART_LINK"
elif [[ -e "$DCDART_LINK" ]]; then
  echo "build-osmedia: $DCDART_LINK exists and is not a symlink" >&2
  exit 2
fi
ln -s "$DCDART_HOME" "$DCDART_LINK"
PRELUDE="$DCDART_LINK/core/runtime/dc-core-bare/prelude.dart"
EXPECTED="import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';"
if ! grep -qxF -- "$EXPECTED" "$SRC/osmedia.dart"; then
  echo "build-osmedia: osmedia.dart prelude import is not ADR-0043" >&2
  exit 2
fi

if ! ( cd "$SRC" && "$DART" "$DCDART_HOME/core/dcc/bin/dcc.dart" build --mode bare --target host \
    --prelude "$PRELUDE" osmedia.dart -o "$OUT/osmedia_ffi.o" ); then
  echo "build-osmedia: dcc failed (C headless is the floor)"
  exit 0
fi

clang -O2 -Wall -Wextra -Werror -I "$SRC" -c -o "$OUT/osmedia_ffi_abi.o" "$SRC/osmedia_ffi.c"
clang -O2 -Wall -Wextra -Werror -I "$SRC" -c -o "$OUT/osmedia_ffi_main.o" "$SRC/ffi_main.c"
clang -O2 -o "$OUT/osmedia-ffi" \
  "$OUT/osmedia.o" "$OUT/osmedia_ffi_abi.o" "$OUT/osmedia_ffi_main.o" \
  "$OUT/osmedia_ffi.o" \
  $FF_LIBS
echo "built $OUT/osmedia-ffi"
