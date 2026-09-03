#!/usr/bin/env bash
# Resolve a writable artifacts directory without destroying platform paths.
#
# /opt/cursor/artifacts may be a platform-owned symlink. Never `rm -f` it.
# Prefer it when it is a real writable directory; otherwise print a fallback
# under core/build/artifacts and warn on stderr.
#
# Usage: artifacts-dir.sh [fallback]
# Prints the chosen path. Exit 0 if writable, 1 if nothing can be written.
set -euo pipefail

prefer="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
fallback="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

writable_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  # A dangling or unwritable symlink must not be treated as OK.
  if [[ -L "$d" ]]; then
    local tgt
    tgt="$(readlink -f "$d" 2>/dev/null || true)"
    [[ -n "$tgt" && -d "$tgt" ]] || return 1
  fi
  local probe="$d/.artifacts-write-test.$$"
  if ! ( : >"$probe" ) 2>/dev/null; then
    return 1
  fi
  rm -f "$probe"
  return 0
}

if writable_dir "$prefer"; then
  echo "$prefer"
  exit 0
fi

if [[ -L "$prefer" ]]; then
  echo "artifacts-dir: $prefer is a symlink and is not writable; using fallback" >&2
elif [[ -e "$prefer" ]]; then
  echo "artifacts-dir: $prefer exists but is not a writable directory; using fallback" >&2
else
  if mkdir -p "$prefer" 2>/dev/null && writable_dir "$prefer"; then
    echo "$prefer"
    exit 0
  fi
  echo "artifacts-dir: cannot create $prefer; using fallback" >&2
fi

if [[ -z "$fallback" ]]; then
  fallback="$(cd "$SCRIPT_DIR/.." && pwd)/build/artifacts"
fi
mkdir -p "$fallback" || {
  echo "artifacts-dir: fallback $fallback not creatable" >&2
  exit 1
}
if ! writable_dir "$fallback"; then
  echo "artifacts-dir: fallback $fallback not writable" >&2
  exit 1
fi
echo "$fallback"
exit 0
