#!/usr/bin/env bash
# Isolated kernel+UEFI+FAT build, then atomic promote into core/build.
# Does not commit *.elf (gitignored). Writes BUILD.json metadata.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIVE="$CORE_DIR/build"
STAGE="${OSCORTEX_PROMOTE_STAGE:-/tmp/oscortex-core-build-stage}"
ART="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"

fail() { echo "promote-core-build: FAIL — $*" >&2; exit 1; }
say() { echo "promote-core-build: $*" >&2; }

mkdir -p "$STAGE" "$ART" "$LIVE"
if [[ -d "$LIVE/skia" && ! -e "$STAGE/skia" ]]; then
  ln -s "$LIVE/skia" "$STAGE/skia"
fi

if [[ -z "${DCDART_HOME:-}" || ! -f "${DCDART_HOME:-}/core/dcc/bin/dcc.dart" ]]; then
  eval "$(bash "$SCRIPT_DIR/bootstrap-dcdart.sh" | tail -n 1)"
fi
export DCDART_HOME
export OSGFX_SKIA="${OSGFX_SKIA:-1}"
export OSMEDIA_FFMPEG="${OSMEDIA_FFMPEG:-0}"

GIT_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
TOOL_ID="$(tr -d '[:space:]' <"$DCDART_HOME/.oscortex-dcdart-identity" 2>/dev/null || true)"
[[ -n "$TOOL_ID" ]] || TOOL_ID="$(git -C "$DCDART_HOME" rev-parse HEAD 2>/dev/null || echo unknown)"

say "building isolated at $STAGE (git=$GIT_SHA toolchain=$TOOL_ID)"
BUILD_DIR="$STAGE" bash "$CORE_DIR/scripts/build-kernel.sh" \
  || fail "isolated kernel build failed"
[[ -f "$STAGE/kernel.elf" ]] || fail "no kernel.elf"
[[ -f "$STAGE/kernel-uefi.elf" ]] || fail "no kernel-uefi.elf"

# Fresh FAT with current FILES.ELF (MENU ESC newline).
DISK_STAGE="$STAGE/disk"
mkdir -p "$DISK_STAGE"
bash "$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh" "$DISK_STAGE" \
  || fail "sitfat disk build failed"
[[ -f "$DISK_STAGE/disk.img" ]] || fail "no disk.img"

K_SHA="$(sha256sum "$STAGE/kernel.elf" | awk '{print $1}')"
U_SHA="$(sha256sum "$STAGE/kernel-uefi.elf" | awk '{print $1}')"
D_SHA="$(sha256sum "$DISK_STAGE/disk.img" | awk '{print $1}')"

# Atomic promote: write into a sibling then rename.
PROMO="$LIVE.promote.$$"
rm -rf "$PROMO"
mkdir -p "$PROMO"
cp -a "$STAGE/kernel.elf" "$PROMO/kernel.elf"
cp -a "$STAGE/kernel-uefi.elf" "$PROMO/kernel-uefi.elf"
cp -a "$DISK_STAGE/disk.img" "$PROMO/disk.img"
if [[ -d "$LIVE/skia" ]]; then
  ln -s "$LIVE/skia" "$PROMO/skia"
fi
cat >"$PROMO/BUILD.json" <<EOF
{
  "git_sha": "$GIT_SHA",
  "toolchain_identity": "$TOOL_ID",
  "dcdart_home": "$DCDART_HOME",
  "kernel_elf_sha256": "$K_SHA",
  "kernel_uefi_sha256": "$U_SHA",
  "disk_img_sha256": "$D_SHA",
  "osgfx_skia": "$OSGFX_SKIA"
}
EOF

# Replace elves/disk/metadata only; keep daily-drive run dirs.
cp -a "$PROMO/kernel.elf" "$LIVE/kernel.elf"
cp -a "$PROMO/kernel-uefi.elf" "$LIVE/kernel-uefi.elf"
cp -a "$PROMO/disk.img" "$LIVE/disk.img"
cp -a "$PROMO/BUILD.json" "$LIVE/BUILD.json"
rm -rf "$PROMO"

cp -a "$LIVE/BUILD.json" "$ART/oscortex-round41-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round40-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round39-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round33-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round32-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round31-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round30-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round29-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round27-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round26-build.json"
cp -a "$LIVE/BUILD.json" "$ART/oscortex-round25-build.json"
say "promoted kernel=$K_SHA uefi=$U_SHA git=$GIT_SHA"
echo "PROMOTED=$LIVE"
