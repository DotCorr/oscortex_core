#!/usr/bin/env bash
# Print clang -f{debug,file,macro}-prefix-map flags so objects do not
# embed host-absolute paths. Diagnostics stay; only the prefix is
# canonical. Used by build-kernel.sh and the Skia guest wrappers.
#
# Usage:
#   CANON_CFLAGS="$(bash oscortex-canon-cflags.sh [root=canon]...)"
# Extra roots can be passed as /abs/path=/canon
set -euo pipefail

emit() {
  local src="$1" dst="$2"
  [[ -n "$src" && -n "$dst" ]] || return 0
  # clang matches the longest prefix; both the caller spelling and the
  # physical path must map when they differ (symlink BUILD_DIR, etc.).
  printf -- ' -fdebug-prefix-map=%s=%s' "$src" "$dst"
  printf -- ' -ffile-prefix-map=%s=%s' "$src" "$dst"
  printf -- ' -fmacro-prefix-map=%s=%s' "$src" "$dst"
  if [[ -d "$src" ]]; then
    local phys
    phys="$(cd "$src" && pwd -P)"
    if [[ "$phys" != "$src" ]]; then
      printf -- ' -fdebug-prefix-map=%s=%s' "$phys" "$dst"
      printf -- ' -ffile-prefix-map=%s=%s' "$phys" "$dst"
      printf -- ' -fmacro-prefix-map=%s=%s' "$phys" "$dst"
    fi
  fi
}

if [[ $# -eq 0 ]]; then
  echo "oscortex-canon-cflags: usage: $0 /abs/root=/canon ..." >&2
  exit 2
fi

for spec in "$@"; do
  src="${spec%%=*}"
  dst="${spec#*=}"
  if [[ "$src" == "$spec" || -z "$dst" ]]; then
    echo "oscortex-canon-cflags: expected src=/canon, got $spec" >&2
    exit 2
  fi
  emit "$src" "$dst"
done
printf '\n'
