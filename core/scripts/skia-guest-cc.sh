#!/usr/bin/env bash
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
INC="$CORE/plat/osgfx/guest_inc"
CLANGINC="$(clang -print-resource-dir)/include"
if [[ -z "${OSCORTEX_CANON_CFLAGS:-}" ]]; then
  OSCORTEX_CANON_CFLAGS="$(bash "$CORE/scripts/oscortex-canon-cflags.sh" \
    "$CORE=/oscortex" "$CORE/build/skia=/skia")"
fi
# shellcheck disable=SC2206
CANON_ARR=(${OSCORTEX_CANON_CFLAGS:-})
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
    -march=x86-64-v3|-march=x86-64-v4|-mtune=*) ;;
    *) args+=("$a") ;;
  esac
done
exec clang --target=x86_64-unknown-none-elf \
  "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
  -isystem "$INC" \
  -isystem "$CLANGINC" \
  -fno-pic -fno-pie -ffreestanding \
  -fno-stack-protector -mno-red-zone \
  -fno-asynchronous-unwind-tables \
  -march=x86-64 \
  -mno-avx -mno-avx2 -mno-fma -mno-avx512f \
  -DSK_BUILD_FOR_UNIX \
  -DSK_CPU_LIMIT_SSE2 \
  "${args[@]+"${args[@]}"}"
