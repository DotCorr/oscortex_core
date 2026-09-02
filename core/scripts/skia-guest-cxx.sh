#!/usr/bin/env bash
# Compiler wrapper: Skia sources -> x86_64-elf. Not Mac Metal. Not arm64.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
INC="$CORE/plat/osgfx/guest_inc"
CFG="$INC/c++cfg"
LIBCXX="$(xcrun --show-sdk-path)/usr/include/c++/v1"
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
    -stdlib=libc++) ;;
    -march=x86-64-v3|-march=x86-64-v4|-mtune=*) ;;
    *) args+=("$a") ;;
  esac
done
exec clang++ --target=x86_64-unknown-none-elf \
  -nostdinc++ \
  -isystem "$CFG" \
  -isystem "$LIBCXX" \
  -isystem "$INC" \
  -isystem "$CLANGINC" \
  -std=c++20 \
  -fno-exceptions -fno-rtti -fno-pic -fno-pie -ffreestanding \
  -fno-stack-protector -mno-red-zone -fno-threadsafe-statics \
  -fno-use-cxa-atexit -fno-asynchronous-unwind-tables \
  -march=x86-64 \
  -mno-avx -mno-avx2 -mno-fma -mno-avx512f \
  -DSK_BUILD_FOR_UNIX \
  -DSK_CPU_LIMIT_SSE2 \
  "${args[@]+"${args[@]}"}"
