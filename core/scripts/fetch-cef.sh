#!/usr/bin/env bash
# Fetch the official Spotify-hosted CEF macosarm64 minimal binary.
# Not a Chromium-from-source build. Not Flutter. Not WebKit.
#
# Pin: CEF 144.0.34 / Chromium 144.0.7559.261, macosarm64 minimal.
# Index: https://cef-builds.spotifycdn.com/index.json
set -euo pipefail

CORE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$CORE/build/cef"
STAMP="$ROOT/READY"
# Official filename uses '+' (Chromium version stamp). The CDN needs %2B.
CEF_STAMP="144.0.34+g8fc21c8+chromium-144.0.7559.261"
CEF_DIRNAME="cef_binary_${CEF_STAMP}_macosarm64_minimal"
CEF_FILE="${CEF_DIRNAME}.tar.bz2"
CEF_SHA1="4527b3dadfa0f8116286c8c77d5f600e8f78746d"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_FILE//+/%2B}"
DEST="$ROOT/$CEF_DIRNAME"

if [[ -f "$STAMP" && -d "$DEST/include" && -d "$DEST/Release/Chromium Embedded Framework.framework" ]]; then
  echo "cef: $DEST"
  cat "$STAMP"
  exit 0
fi

mkdir -p "$ROOT"
ARCHIVE="$ROOT/$CEF_FILE"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "fetch-cef: GET $CEF_URL" >&2
  if ! curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE.part" "$CEF_URL"; then
    rm -f "$ARCHIVE.part"
    echo "fetch-cef: HARD BLOCK — curl failed for official CEF macosarm64 minimal" >&2
    echo "fetch-cef: url=$CEF_URL" >&2
    echo "fetch-cef: next: retry the same GET, or take the standard tarball of the same stamp" >&2
    exit 3
  fi
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

GOT="$(shasum -a 1 "$ARCHIVE" | awk '{print $1}')"
if [[ "$GOT" != "$CEF_SHA1" ]]; then
  echo "fetch-cef: HARD BLOCK — sha1 $GOT != $CEF_SHA1" >&2
  echo "fetch-cef: archive=$ARCHIVE" >&2
  exit 3
fi

if [[ ! -d "$DEST/include" ]]; then
  echo "fetch-cef: extract $ARCHIVE" >&2
  tar -xjf "$ARCHIVE" -C "$ROOT"
fi

if [[ ! -d "$DEST/include" || ! -d "$DEST/Release/Chromium Embedded Framework.framework" ]]; then
  echo "fetch-cef: HARD BLOCK — extract did not produce $DEST" >&2
  exit 3
fi

# Downloaded Chromium is quarantined; ad-hoc sign later in build-oschrome.sh.
xattr -cr "$DEST" 2>/dev/null || true

{
  echo "CEF_ROOT=$DEST"
  echo "CEF_STAMP=$CEF_STAMP"
  echo "CEF_SHA1=$CEF_SHA1"
} >"$STAMP"

echo "cef: $DEST"
cat "$STAMP"
