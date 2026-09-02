#!/usr/bin/env bash
# Host osxui module: widgets + an osgfx.h software backend.
# Not Graphite. Not a FRAME ELF. Same osxui.c the kernel triple compiles.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$CORE/plat/osxui"
GFX="$CORE/plat/osgfx"
OUT="$CORE/build"
mkdir -p "$OUT"

clang -O2 -Wall -Wextra -I "$GFX" -I "$SRC" \
  -c -o "$OUT/osxui.o" "$SRC/osxui.c"
clang -O2 -Wall -Wextra -I "$GFX" -I "$SRC" \
  -c -o "$OUT/osxui_fb.o" "$SRC/osxui_fb.c"
clang -O2 -Wall -Wextra -I "$GFX" \
  -c -o "$OUT/osxui_osgfx_cpu.o" "$SRC/osgfx_cpu.c"
clang -O2 -Wall -Wextra -I "$GFX" \
  -c -o "$OUT/osgfx_glyph.o" "$GFX/osgfx_glyph.c"
clang -O2 -Wall -Wextra -I "$GFX" -I "$SRC" \
  -c -o "$OUT/osxui_headless.o" "$SRC/headless_main.c"
clang -O2 -Wall -Wextra \
  -o "$OUT/osxui-headless" \
  "$OUT/osxui.o" "$OUT/osxui_fb.o" "$OUT/osxui_osgfx_cpu.o" \
  "$OUT/osgfx_glyph.o" "$OUT/osxui_headless.o"
echo "built $OUT/osxui-headless"
