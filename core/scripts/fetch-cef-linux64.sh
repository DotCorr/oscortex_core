#!/usr/bin/env bash
# Fetch the official Spotify-hosted CEF linux64 minimal binary.
# Same Chromium stamp as fetch-cef.sh (macosarm64). x86_64 ELF libcef.so
# is the object the QEMU platform blob can link. Not Mac CEF. Not a stub.
#
# Pin: CEF 144.0.34 / Chromium 144.0.7559.261, linux64 minimal.
# Index: https://cef-builds.spotifycdn.com/index.json
set -euo pipefail

CORE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$CORE/build/cef-linux64"
STAMP="$ROOT/READY"
CEF_STAMP="144.0.34+g8fc21c8+chromium-144.0.7559.261"
CEF_DIRNAME="cef_binary_${CEF_STAMP}_linux64_minimal"
CEF_FILE="${CEF_DIRNAME}.tar.bz2"
CEF_SHA1="db04c1ebb1f6dc5bb66ee38b7440c36596056937"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_FILE//+/%2B}"
DEST="$ROOT/$CEF_DIRNAME"
SO="$DEST/Release/libcef.so"

if [[ -f "$STAMP" && -f "$SO" ]]; then
  echo "cef-linux64: $DEST"
  cat "$STAMP"
  exit 0
fi

mkdir -p "$ROOT"
ARCHIVE="$ROOT/$CEF_FILE"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "fetch-cef-linux64: GET $CEF_URL" >&2
  if ! curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE.part" "$CEF_URL"; then
    rm -f "$ARCHIVE.part"
    echo "fetch-cef-linux64: HARD BLOCK — curl failed for official CEF linux64 minimal" >&2
    echo "fetch-cef-linux64: url=$CEF_URL" >&2
    exit 3
  fi
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

GOT="$(shasum -a 1 "$ARCHIVE" | awk '{print $1}')"
if [[ "$GOT" != "$CEF_SHA1" ]]; then
  echo "fetch-cef-linux64: HARD BLOCK — sha1 $GOT != $CEF_SHA1" >&2
  echo "fetch-cef-linux64: archive=$ARCHIVE" >&2
  exit 3
fi

if [[ ! -f "$SO" ]]; then
  echo "fetch-cef-linux64: extract libcef.so from $ARCHIVE" >&2
  # Only the x86_64 libcef.so — not the rest of the tree.
  tar -xjf "$ARCHIVE" -C "$ROOT" \
    "${CEF_DIRNAME}/Release/libcef.so" \
    "${CEF_DIRNAME}/include/capi/cef_app_capi.h" \
    "${CEF_DIRNAME}/include/cef_api_hash.h" \
    2>/dev/null || tar -xjf "$ARCHIVE" -C "$ROOT" "${CEF_DIRNAME}/Release/libcef.so"
fi

if [[ ! -f "$SO" ]]; then
  echo "fetch-cef-linux64: HARD BLOCK — extract did not produce $SO" >&2
  exit 3
fi

{
  echo "CEF_ROOT=$DEST"
  echo "CEF_STAMP=$CEF_STAMP"
  echo "CEF_SHA1=$CEF_SHA1"
  echo "CEF_LIB=$SO"
} >"$STAMP"

echo "cef-linux64: $DEST"
cat "$STAMP"
