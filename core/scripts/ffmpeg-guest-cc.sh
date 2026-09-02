#!/usr/bin/env bash
# clang wrapper: FFmpeg for kernel.elf (x86_64-unknown-none-elf). Not Mac.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
MEDIAINC="$CORE/plat/media/guest_inc"
INC="$CORE/plat/osgfx/guest_inc"
CLANGINC="$(clang -print-resource-dir)/include"
args=()
skip_next=0
for a in "$@"; do
  if [[ "$skip_next" == 1 ]]; then
    skip_next=0
    continue
  fi
  case "$a" in
    -target) skip_next=1 ;;
    x86_64-apple-macos*|arm64-apple-macos*|*-apple-macos*) ;;
    -isysroot) skip_next=1 ;;
    /Applications/Xcode.app/*) ;;
    -fPIC|-fpic|-fPIE|-fpie) ;;
    *) args+=("$a") ;;
  esac
done
exec clang --target=x86_64-unknown-none-elf \
  -isystem "$MEDIAINC" \
  -isystem "$INC" \
  -isystem "$CLANGINC" \
  -fno-pic -fno-pie -ffreestanding \
  -fno-stack-protector -mno-red-zone \
  -fno-asynchronous-unwind-tables \
  -Dsnprintf=osmedia_snprintf \
  -Dvsnprintf=osmedia_vsnprintf \
  -Dstatic_assert=_Static_assert \
  "${args[@]+"${args[@]}"}"
