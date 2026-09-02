#!/usr/bin/env bash
# CPU Skia for kernel.elf (x86_64-unknown-none-elf). Not Mac arm64 Metal.
# Not Graphite. canvas->drawRRect into the Bochs/GOP scanout.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$CORE/build/skia/src"
OUT="$CORE/build/skia/out/guest-elf"
LIB="$OUT/libskia.a"
PLAT="$CORE/plat/osgfx"
CC="$CORE/scripts/skia-guest-cc.sh"
CXX="$CORE/scripts/skia-guest-cxx.sh"
AR="$(command -v x86_64-elf-ar)"

if [[ ! -d "$SRC/.git" ]]; then
  echo "build-skia-guest: fetching Skia source (host Graphite tree)" >&2
  SKIA_FETCH_ONLY=1 bash "$CORE/scripts/build-skia-graphite.sh"
fi
[[ -d "$SRC/.git" ]] || { echo "build-skia-guest: no Skia source" >&2; exit 1; }
[[ -x "$AR" ]] || { echo "build-skia-guest: need x86_64-elf-ar" >&2; exit 1; }

if [[ ! -x "$SRC/bin/gn" ]]; then
  ( cd "$SRC" && python3 bin/fetch-gn )
fi

if [[ ! -f "$LIB" ]]; then
  mkdir -p "$OUT"
  ARGS="
is_official_build=true
is_debug=false
target_cpu=\"x64\"
cc=\"$CC\"
cxx=\"$CXX\"
ar=\"$AR\"
skia_use_metal=false
skia_enable_graphite=false
skia_enable_ganesh=false
skia_use_gl=false
skia_gl_standard=\"\"
skia_use_fonthost_mac=false
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
extra_cflags=[\"-DSK_CPU_LIMIT_SSE2\",\"-DSKCMS_FORCE_BASELINE\"]
"
  ( cd "$SRC" && "$SRC/bin/gn" gen "$OUT" --args="$ARGS" )
  # GN's Mac toolchain archives with libtool. Objects are ELF; use elf ar.
  python3 - "$OUT/toolchain.ninja" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
t = t.replace(
    "command = libtool -static -o ${out} -no_warning_for_no_symbols ${in}",
    "command = rm -f ${out} && x86_64-elf-ar crs ${out} ${in}",
)
p.write_text(t)
PY
  python3 - "$OUT" "$PLAT/osgfx_skia_skip.cpp" "$PLAT/osgfx_skia_skip_cg.cpp" <<'PY'
import pathlib, sys
out, skip, skip_cg = map(pathlib.Path, sys.argv[1:])
skip, skip_cg = skip.resolve(), skip_cg.resolve()
repl = {
    "SkShaderUtils.cpp": skip,
    "SkHdrMetadata.cpp": skip,
    "SkImageGeneratorCG": skip_cg,
    "SkImageGeneratorWIC": skip,
    "SkImageGeneratorNDK": skip,
    "SkSLString.cpp": skip,
    "SkSLDebugTracePriv.cpp": skip,
    "SkOSFile_posix.cpp": skip,
}
for ninja in out.rglob("*.ninja"):
    t = ninja.read_text()
    orig = t
    for needle, dest in repl.items():
        if needle in t:
            # rewrite cxx source path on matching build lines
            lines = []
            for line in t.splitlines(True):
                if needle in line and ": cxx " in line:
                    left, _, _ = line.partition(": cxx ")
                    line = left + ": cxx " + str(dest) + "\n"
                lines.append(line)
            t = "".join(lines)
    if t != orig:
        ninja.write_text(t)
PY
  ninja -C "$OUT" skia
fi
[[ -f "$LIB" ]] || { echo "build-skia-guest: no $LIB" >&2; exit 1; }

# Consume the archive listing completely. With pipefail, `grep | head -1`
# intermittently makes `ar` die on SIGPIPE and turns an intact cached archive
# into a failed kernel build.
SAMPLE=$(x86_64-elf-ar t "$LIB" | awk '
  /\.o$/ && first == "" { first = $0 }
  END { print first }
')
[[ -n "$SAMPLE" ]] || { echo "build-skia-guest: archive has no object" >&2; exit 1; }
x86_64-elf-ar p "$LIB" "$SAMPLE" >"$CORE/build/skia-guest-sample.o"
if file "$CORE/build/skia-guest-sample.o" | grep -qi 'arm64'; then
  echo "build-skia-guest: archive is arm64 — refused" >&2
  exit 1
fi
if file "$CORE/build/skia-guest-sample.o" | grep -qi 'Mach-O'; then
  echo "build-skia-guest: archive is Mach-O — refused" >&2
  exit 1
fi
if ! file "$CORE/build/skia-guest-sample.o" | grep -qi 'ELF'; then
  echo "build-skia-guest: sample object is not ELF" >&2
  exit 1
fi

clang -c -target x86_64-unknown-none-elf -ffreestanding -fno-stack-protector \
  -fno-pic -mno-red-zone -O2 -Wall -I "$PLAT" \
  -DCRT_HEAP=4194304 \
  -o "$CORE/build/osgfx_guest_crt.o" "$PLAT/osgfx_guest_crt.c"

bash "$CXX" -c -O2 -Wall \
  -I "$PLAT" -I "$SRC" \
  -o "$CORE/build/osgfx_skia.o" "$PLAT/osgfx_skia.cpp"
bash "$CXX" -c -O2 -Wall \
  -I "$PLAT" -I "$SRC" \
  -o "$CORE/build/osgfx_cxxrt.o" "$PLAT/osgfx_cxxrt.cpp"

echo "skia-guest: $LIB"
