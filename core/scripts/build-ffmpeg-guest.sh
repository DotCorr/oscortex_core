#!/usr/bin/env bash
# Official FFmpeg static libs for kernel.elf (x86_64-unknown-none-elf).
# Not a Mac dylib. Not an app ELF. libavcodec + libavformat + libavutil,
# H.264 + mov only.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$CORE/build/ffmpeg/src"
OUT="$CORE/build/ffmpeg/out/guest-elf"
CC="$CORE/scripts/ffmpeg-guest-cc.sh"
LD="$CORE/scripts/ffmpeg-guest-ld.sh"
AR="$(command -v x86_64-elf-ar)"
RANLIB="$(command -v x86_64-elf-ranlib)"
VER="${FFMPEG_GUEST_VER:-7.1.1}"
TARBALL="$CORE/build/ffmpeg/ffmpeg-${VER}.tar.xz"
URL="https://ffmpeg.org/releases/ffmpeg-${VER}.tar.xz"

[[ -x "$CC" ]] || { echo "build-ffmpeg-guest: no $CC" >&2; exit 1; }
[[ -x "$LD" ]] || { echo "build-ffmpeg-guest: no $LD" >&2; exit 1; }
[[ -x "$AR" ]] || { echo "build-ffmpeg-guest: need x86_64-elf-ar" >&2; exit 1; }
[[ -x "$RANLIB" ]] || { echo "build-ffmpeg-guest: need x86_64-elf-ranlib" >&2; exit 1; }

mkdir -p "$CORE/build/ffmpeg"
if [[ ! -f "$SRC/configure" ]]; then
  if [[ ! -f "$TARBALL" ]]; then
    echo "build-ffmpeg-guest: fetching FFmpeg ${VER}" >&2
    curl -L --fail --retry 3 -o "$TARBALL" "$URL"
  fi
  rm -rf "$CORE/build/ffmpeg/src-tmp" "$SRC"
  mkdir -p "$CORE/build/ffmpeg/src-tmp"
  tar -xJf "$TARBALL" -C "$CORE/build/ffmpeg/src-tmp"
  mv "$CORE/build/ffmpeg/src-tmp"/ffmpeg-* "$SRC"
  rmdir "$CORE/build/ffmpeg/src-tmp"
fi
[[ -f "$SRC/configure" ]] || { echo "build-ffmpeg-guest: no configure" >&2; exit 1; }

if [[ -f "$OUT/libavcodec.a" && -f "$OUT/libavformat.a" && -f "$OUT/libavutil.a" ]]; then
  echo "build-ffmpeg-guest: using $OUT"
  exit 0
fi

mkdir -p "$OUT"
# Configure in the source tree once; objects land in $OUT via --prefix.
# Cross: no host libc, no programs, H.264 + ISO BMFF only.
( cd "$SRC" && ./configure \
  --prefix="$OUT" \
  --enable-cross-compile \
  --arch=x86_64 \
  --target-os=none \
  --cc="$CC" \
  --ld="$LD" \
  --ar="$AR" \
  --ranlib="$RANLIB" \
  --enable-static \
  --disable-shared \
  --disable-asm \
  --disable-inline-asm \
  --disable-x86asm \
  --disable-mmx \
  --disable-sse \
  --disable-avx \
  --disable-programs \
  --disable-doc \
  --disable-htmlpages \
  --disable-manpages \
  --disable-podpages \
  --disable-txtpages \
  --disable-network \
  --disable-autodetect \
  --disable-pthreads \
  --disable-w32threads \
  --disable-os2threads \
  --disable-everything \
  --disable-debug \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --disable-avdevice \
  --disable-avfilter \
  --disable-swscale \
  --disable-swresample \
  --disable-postproc \
  --enable-decoder=h264 \
  --enable-parser=h264 \
  --enable-demuxer=mov \
  --extra-cflags="-ffreestanding -fno-builtin -fno-pic -fno-pie -mno-red-zone -fno-stack-protector" \
  --extra-ldflags="-nostdlib" \
)

make -C "$SRC" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
  libavcodec/libavcodec.a libavformat/libavformat.a libavutil/libavutil.a
mkdir -p "$OUT"
cp -f "$SRC/libavcodec/libavcodec.a" "$OUT/libavcodec.a"
cp -f "$SRC/libavformat/libavformat.a" "$OUT/libavformat.a"
cp -f "$SRC/libavutil/libavutil.a" "$OUT/libavutil.a"
mkdir -p "$OUT/include"
# Headers stay in $SRC; osmedia.c -I that tree.
echo "build-ffmpeg-guest: PASS — $OUT"
