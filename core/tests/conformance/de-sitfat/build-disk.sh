#!/usr/bin/env bash
# core/tests/conformance/de-sitfat/build-disk.sh
#
# Builds FILES.ELF, SET.ELF, PING.ELF, STUDIO.ELF, BROWSE.ELF, PLAY.ELF,
# TAP.ELF (and companions) and writes the sit-in FAT16 volume.
#
# Directory order: FILES, FACTS.DAT, SET, PING, STUDIO, BROWSE, PLAY,
# TAP, APPS.TXT, APP1.  Start caches only the first wmDeLaunchMax (4)
# ELF names — FILES SET PING STUDIO — so de-sitfat floors stay
# (WM DE START 04, PING row). BROWSE / PLAY / TAP are full FAT plants:
# `proc spawn` / `go` / FILES list. ADR-0173. APP1 stays a Studio
# companion (not a Start row).
#
#   build-disk.sh <outdir> [--surf]
#
# Writes <outdir>/disk.img, <outdir>/layout.json, <outdir>/model.txt.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FILES="$CORE_DIR/tests/conformance/files-fm"
SET="$CORE_DIR/tests/conformance/de-set"
CHROME="$CORE_DIR/tests/conformance/de-chrome"
STUDIO="$CORE_DIR/tests/conformance/studio2"
BROWSE="$CORE_DIR/tests/conformance/de-browse"
APPS="$CORE_DIR/tests/conformance/de-apps"
FRAME2="$CORE_DIR/tests/conformance/frame2"
PLAY_C="$CORE_DIR/user/frame/play.c"
PLAY_LD="$FRAME2/prog.ld"

fail() { echo "build-disk: FAIL — $1" >&2; exit 1; }

OUT="${1:-}"
[[ -n "$OUT" ]] || fail "usage: build-disk.sh <outdir> [--surf]"
shift
WANT_SURF=0
if [[ "${1:-}" == "--surf" ]]; then
  WANT_SURF=1
fi
mkdir -p "$OUT" || fail "could not create $OUT"
OUT="$(cd "$OUT" && pwd -P)"

bash "$FILES/build-progs.sh" "$OUT/files" \
  || fail "FILES.ELF failed to build"
bash "$SET/build-progs.sh" "$OUT/set" "$CORE_DIR/kernel" \
  || fail "SET.ELF failed to build"
bash "$CHROME/build-progs.sh" "$OUT/chrome" \
  || fail "PING.ELF failed to build"
bash "$STUDIO/build-progs.sh" "$OUT/studio" \
  || fail "STUDIO.ELF failed to build"
bash "$BROWSE/build-progs.sh" "$OUT/browse" "$CORE_DIR/kernel" \
  || fail "BROWSE.ELF failed to build"
bash "$APPS/build-progs.sh" "$OUT/apps" "$CORE_DIR/kernel" \
  || fail "TAP.ELF failed to build"
bash "$CORE_DIR/tests/conformance/de-desk/build-progs.sh" "$OUT/desk" \
  || fail "DESK.ELF failed to build"

# PLAY.ELF — same link as de-vwin / de-movie (osframe only, no decode).
mkdir -p "$OUT/play" || fail "could not create play outdir"
[[ -f "$PLAY_C" ]] || fail "no play.c"
[[ -f "$PLAY_LD" ]] || fail "no frame2/prog.ld"
CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror
  -I"$CORE_DIR/user/frame"
)
clang "${CFLAGS[@]}" "$PLAY_C" -o "$OUT/play/play.o" \
  || fail "clang could not compile play.c"
x86_64-elf-ld -T "$PLAY_LD" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/play/play.elf" "$OUT/play/play.o" \
  || fail "ld could not link PLAY.ELF"
[[ -s "$OUT/play/play.elf" ]] || fail "PLAY.ELF is empty"

python3 "$SET/derive.py" \
  "$CORE_DIR/user/frame/set.c" \
  "$CORE_DIR/kernel/fb.dart" \
  "$CORE_DIR/kernel/wm.dart" \
  "$CORE_DIR/kernel/wmchrome.dart" \
  "$CORE_DIR/kernel/wmevent.dart" \
  "$CORE_DIR/kernel/kbdq.dart" >"$OUT/set-model.txt" \
  || fail "de-set derive.py failed"
python3 -c "
import sys
hexs = ''
for line in open(sys.argv[1]):
    if line.startswith('facts_hex='):
        hexs = line.split('=', 1)[1].strip()
        break
if not hexs:
    raise SystemExit('no facts_hex')
open(sys.argv[2], 'wb').write(bytes.fromhex(hexs))
" "$OUT/set-model.txt" "$OUT/FACTS.DAT" \
  || fail "could not plant FACTS.DAT"
printf 'APP1.ELF\n' >"$OUT/APPS.TXT"

PAIRS=(
  "FILES.ELF=$OUT/files/files.elf"
  "FACTS.DAT=$OUT/FACTS.DAT"
  "SET.ELF=$OUT/set/set.elf"
  "PING.ELF=$OUT/chrome/ping.elf"
  "STUDIO.ELF=$OUT/studio/studio.elf"
  "DESK.ELF=$OUT/desk/desk.elf"
  "BROWSE.ELF=$OUT/browse/browse.elf"
  "PLAY.ELF=$OUT/play/play.elf"
  "TAP.ELF=$OUT/apps/tap.elf"
  "APPS.TXT=$OUT/APPS.TXT"
  "APP1.ELF=$OUT/studio/app1.elf"
)
if [[ "$WANT_SURF" == 1 ]]; then
  bash "$FRAME2/build-progs.sh" "$OUT/frame2" "$CORE_DIR/kernel" \
    || fail "SURF.ELF failed to build"
  PAIRS+=("SURF.ELF=$OUT/frame2/surf.elf")
fi

python3 "$SCRIPT_DIR/make-image.py" "$OUT/disk.img" --json \
  "${PAIRS[@]}" >"$OUT/layout.json" \
  || fail "make-image.py failed"

# Start model stays the first-four launch floor (ADR-0108 / ADR-0173).
python3 "$SCRIPT_DIR/derive.py" \
  "$CORE_DIR/kernel/wmde.dart" \
  "$CORE_DIR/kernel/wmchrome.dart" \
  "$CORE_DIR/kernel/fb.dart" \
  FILES.ELF SET.ELF PING.ELF STUDIO.ELF >"$OUT/model.txt" \
  || fail "derive.py failed"

python3 -c "
import json, sys
lay = json.load(open(sys.argv[1]))
need = ['BROWSE.ELF', 'PLAY.ELF', 'TAP.ELF', 'FILES.ELF', 'SET.ELF',
        'PING.ELF', 'STUDIO.ELF', 'APP1.ELF', 'DESK.ELF']
miss = [n for n in need if n not in lay['order']]
if miss:
    raise SystemExit('layout missing %s' % miss)
elves = lay['elves']
# First four ELF names are the Start cache (wmDeLaunchMax).
if elves[:4] != ['FILES.ELF', 'SET.ELF', 'PING.ELF', 'STUDIO.ELF']:
    raise SystemExit('Start floor order drifted: %s' % elves[:4])
for n in ('BROWSE.ELF', 'PLAY.ELF', 'TAP.ELF', 'DESK.ELF'):
    if n not in elves:
        raise SystemExit('%s not among ELF plants' % n)
print('build-disk: FAT plants %s; Start floor %s' %
      (','.join(elves), ','.join(elves[:4])))
" "$OUT/layout.json" || fail "layout anti-vacuity failed"

echo "build-disk: PASS — $OUT/disk.img"
exit 0
