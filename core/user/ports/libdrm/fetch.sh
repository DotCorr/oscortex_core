#!/usr/bin/env bash
# core/user/ports/libdrm/fetch.sh
#
# Puts the PINNED libdrm source tree somewhere build.sh can compile it. Nothing
# in this repository vendors libdrm: `PIN.txt` carries the URL and the exact
# commit, and this script is the only thing that turns that into files.
#
#   fetch.sh <dest-dir>     -> <dest-dir> is a checkout at PIN.txt's commit
#
# IT IS A NETWORK OPERATION AND IT MAY FAIL, and a harness that cannot fetch
# must report a SETUP ERROR (exit 2) rather than a failure (exit 1): "no
# network today" is not evidence about this operating system. Once fetched the
# tree is reusable and this script is a no-op.
#
# Exit status: 0 fetched or already present, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

setup_error() { echo "fetch: SETUP ERROR — $1" >&2; exit 2; }

DEST="${1:-}"
[[ -n "$DEST" ]] || setup_error "usage: fetch.sh <dest-dir>"

[[ -f "$SCRIPT_DIR/PIN.txt" ]] || setup_error "no PIN.txt beside $0"
URL=$(sed -n '1p' "$SCRIPT_DIR/PIN.txt")
SHA=$(sed -n '2p' "$SCRIPT_DIR/PIN.txt")
[[ -n "$URL" && -n "$SHA" ]] || setup_error "PIN.txt is malformed (want URL on line 1, commit on line 2)"

command -v git >/dev/null 2>&1 || setup_error "git not found on PATH"

if [[ -d "$DEST/.git" ]]; then
  have=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)
  if [[ "$have" == "$SHA" ]]; then
    echo "fetch: already at $SHA — $DEST"
    exit 0
  fi
  echo "fetch: $DEST is at ${have:-unknown}, want $SHA — refetching"
  rm -rf "$DEST"
fi

mkdir -p "$(dirname "$DEST")" || setup_error "could not create $(dirname "$DEST")"

# A shallow clone cannot be rewound to an arbitrary commit, so fetch that one
# object directly. This is the form that works against GitLab without cloning
# the whole history.
git init -q "$DEST" >/dev/null 2>&1 || setup_error "git init failed in $DEST"
git -C "$DEST" remote add origin "$URL" >/dev/null 2>&1 || setup_error "git remote add failed"
if ! git -C "$DEST" fetch -q --depth 1 origin "$SHA" >/dev/null 2>&1; then
  # Some servers refuse fetch-by-sha; fall back to a full-history fetch.
  git -C "$DEST" fetch -q origin >/dev/null 2>&1 \
    || setup_error "could not fetch $URL (no network?)"
fi
git -C "$DEST" checkout -q "$SHA" >/dev/null 2>&1 \
  || setup_error "commit $SHA is not in the fetched history of $URL"

got=$(git -C "$DEST" rev-parse HEAD)
[[ "$got" == "$SHA" ]] || setup_error "checked out $got, wanted $SHA"

echo "fetch: $SHA -> $DEST"
exit 0
