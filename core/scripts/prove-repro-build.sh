#!/usr/bin/env bash
# Two isolated kernel builds at different absolute paths must be
# byte-identical. Writes /opt/cursor/artifacts/oscortex-round26-repro-build.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ART="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
mkdir -p "$ART"
export PATH="${PATH:-/opt/dart-sdk-3.12.2/bin:/tmp/oscortex-elf-tools:/usr/bin:/bin}"

fail() { echo "prove-repro-build: FAIL — $*" >&2; exit 1; }
say() { echo "prove-repro-build: $*" >&2; }

if [[ -z "${DCDART_HOME:-}" || ! -f "${DCDART_HOME:-}/core/dcc/bin/dcc.dart" ]]; then
  eval "$(bash "$SCRIPT_DIR/bootstrap-dcdart.sh" | tail -n 1)"
fi
export DCDART_HOME
export OSGFX_SKIA="${OSGFX_SKIA:-1}"
export OSMEDIA_FFMPEG="${OSMEDIA_FFMPEG:-0}"

A="${OSCORTEX_REPRO_A:-/tmp/oscortex-repro-a}"
B="${OSCORTEX_REPRO_B:-/tmp/oscortex-repro-b}"
rm -rf "$A" "$B"
mkdir -p "$A" "$B"
# Same source tree, two BUILD_DIR spellings + a second worktree so CORE_DIR differs.
git -C "$REPO_DIR" worktree add --detach "$B/src" HEAD >&2
ln -s "$CORE_DIR/build/skia" "$B/src/core/build/skia" 2>/dev/null || true

build_one() {
  local dest="$1" core="$2"
  mkdir -p "$dest"
  if [[ -d "$core/build/skia" && ! -e "$dest/skia" ]]; then
    ln -s "$core/build/skia" "$dest/skia"
  fi
  BUILD_DIR="$dest" DCDART_HOME="$DCDART_HOME" OSGFX_SKIA=1 OSMEDIA_FFMPEG=0 \
    bash "$core/scripts/build-kernel.sh"
  [[ -f "$dest/kernel.elf" && -f "$dest/kernel-uefi.elf" ]] \
    || fail "missing elves in $dest"
}

say "build A at $A (core=$CORE_DIR)"
build_one "$A" "$CORE_DIR"
say "build B at $B/kbuild (core=$B/src/core)"
build_one "$B/kbuild" "$B/src/core"

HA="$(sha256sum "$A/kernel.elf" | awk '{print $1}')"
HB="$(sha256sum "$B/kbuild/kernel.elf" | awk '{print $1}')"
UA="$(sha256sum "$A/kernel-uefi.elf" | awk '{print $1}')"
UB="$(sha256sum "$B/kbuild/kernel-uefi.elf" | awk '{print $1}')"
say "kernel.elf     A=$HA"
say "kernel.elf     B=$HB"
say "kernel-uefi    A=$UA"
say "kernel-uefi    B=$UB"

match_k=false
match_u=false
[[ "$HA" == "$HB" ]] && match_k=true
[[ "$UA" == "$UB" ]] && match_u=true

python3 - "$ART/oscortex-round26-repro-build.json" <<PY
import json, os, sys
out = {
  "round": 26,
  "core_a": "$CORE_DIR",
  "core_b": "$B/src/core",
  "build_a": "$A",
  "build_b": "$B/kbuild",
  "toolchain": os.environ.get("DCDART_HOME", ""),
  "kernel_elf_a": "$HA",
  "kernel_elf_b": "$HB",
  "kernel_uefi_a": "$UA",
  "kernel_uefi_b": "$UB",
  "kernel_elf_match": $match_k,
  "kernel_uefi_match": $match_u,
  "canon_cflags": True,
}
open(sys.argv[1], "w").write(json.dumps(out, indent=2) + "\n")
print("wrote", sys.argv[1])
PY

if [[ "$match_k" != true || "$match_u" != true ]]; then
  say "path leftovers A:"
  strings "$A/kernel.elf" | grep -E '/tmp/|/workspace/|/home/' | sort -u | head -20 >&2 || true
  say "path leftovers B:"
  strings "$B/kbuild/kernel.elf" | grep -E '/tmp/|/workspace/|/home/' | sort -u | head -20 >&2 || true
  fail "elves are not byte-identical"
fi
echo "prove-repro-build: PASS $HA"
git -C "$REPO_DIR" worktree remove --force "$B/src" 2>/dev/null || true
