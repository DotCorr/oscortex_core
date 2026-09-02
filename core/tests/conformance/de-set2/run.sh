#!/usr/bin/env bash
# core/tests/conformance/de-set2/run.sh
#
# Settings leftover — the toggle writes CHROME.DAT; under `wm de` the
# compositor notices that file and the notify strip / `WM DE SET ON`
# line change. A miss click does neither. de-set's 130 local-swatch
# path stays the honest local picture (no `wm de`).
# docs/decisions/0120-set-toggle-reaches-live-chrome.md
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
PARENT="$CORE_DIR/tests/conformance/de-set"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

SET_C="$CORE_DIR/user/frame/set.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "DE-SET2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-SET2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Pinned on the first green run.
ASSERTIONS_REQUIRED=75

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-set2.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "${ATTACHED:-}" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
ck; [[ -f "$PROBE" ]] || setup_error "probe.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$SET_C" ]] || setup_error "no set.c at $SET_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"
ck; [[ -f "$PARENT/run.sh" ]] || setup_error "no de-set/run.sh"
ck; [[ -f "$PARENT/build-progs.sh" ]] || setup_error "no de-set/build-progs.sh"
ck; [[ -f "$PARENT/make-image.py" ]] || setup_error "no de-set/make-image.py"

echo "=== BUILD ==="
# Exact-rect chrome does not need the 12MiB Skia CRT heap (vmFineBytes is 4MiB).
export OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSGFX_CRT=0
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SET_C' \
  '$CORE_DIR/kernel/fb.dart' '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/wmchrome.dart' '$CORE_DIR/kernel/wmevent.dart' \
  '$CORE_DIR/kernel/kbdq.dart' '$CORE_DIR/kernel/wmde.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

RELS_HIT=$(d rels_to_hit); RELS_MISS=$(d rels_to_miss)
RELS_HIT_DESK=$(d rels_hit_to_desk); RELS_MISS_DESK=$(d rels_miss_to_desk)
TOGGLE_ON=$(d toggle_on_line); TOGGLE_OFF=$(d toggle_off_line)
FACTS_LEN=$(d facts_len); FACTS_HEX=$(d facts_hex)
NOTE_HEX=$(d note_hex); PREF_HEX=$(d pref_hex)
DE_LINE=$(d de_line); PREF_NAME=$(d pref_name)
FB_LINE=$(d fb_line); CHROME_LINE=$(d chrome_line)

ck; [[ -n "$RELS_HIT" && -n "$RELS_MISS" ]] || fail "derive.py omitted click steps"
ck; [[ "$NOTE_HEX" != "$PREF_HEX" ]] || fail "note $NOTE_HEX equals pref $PREF_HEX"
ck; [[ "$DE_LINE" == "WM DE SET ON" ]] || fail "derived de line is $DE_LINE"
ck; [[ "$PREF_NAME" == "CHROME.DAT" ]] || fail "derived pref name is $PREF_NAME"
ck; [[ "$FACTS_LEN" -gt 26 ]] || fail "planted FACTS.DAT is $FACTS_LEN bytes"
echo "DERIVED: note $NOTE_HEX -> pref $PREF_HEX; file $PREF_NAME; $DE_LINE"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'CHROME.DAT' "$SET_C" || fail "set.c does not write CHROME.DAT"
ck; grep -q 'SYS_FDWRITE' "$SET_C" || fail "set.c does not call fdwrite"
ck; grep -q 'wmDePrefApply' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart does not apply the pref file"
ck; grep -q 'wmStrPrefName' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart does not name the pref 8.3 bytes"
# NO KERNEL *CODE* NAMES Settings / SET. Comments are stripped first, and that is not
# a loophole: wmgfx.dart's only mention of `SET.ELF` today is a comment recording which
# window a compositor bug left without chrome --- prose, not reach. A check that fires on a
# sentence describing the rule cannot distinguish it from a violation of the
# rule, so it is asked of code -- and of directives under any spelling, which
# the raw grep could not see separately at all.
capture_sh PURITY_OUT PURITY_STATUS -- "python3 - '$CORE_DIR/kernel' <<'PY'
import pathlib, re, sys
NAMES = ['set.c', 'SET.ELF', 'FACTS.DAT', 'DE-SET']
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.dart')):
    src = re.sub(r'/[*].*?[*]/', '', f.read_text(), flags=re.S)
    for n, line in enumerate(src.split('\n'), 1):
        code = line.split('//', 1)[0]
        for name in NAMES:
            if name in code:
                bad.append('%s:%d: %s' % (f.name, n, code.strip()))
            if re.search(r'(import|include|part)\\b.*' + re.escape(name), line):
                bad.append('%s:%d: names it in a directive: %s'
                           % (f.name, n, line.strip()))
if bad:
    raise SystemExit('\n'.join(bad))
print('    (no kernel source names Settings / SET outside a comment)')
PY"
ck; [[ $PURITY_STATUS -eq 0 ]] || { echo "$PURITY_OUT" >&2; fail "kernel CODE names Settings / SET — it must not touch the kernel: $PURITY_OUT"; }
ck; ! grep -q '  set  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'set' help line has appeared in shell.dart"
ck; ! grep -qiE 'guest OS' "$SET_C" \
  || fail "set.c says guest OS"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall"
ck; grep -q 'ASSERTIONS_REQUIRED=134' "$PARENT/run.sh" \
  || fail "de-set 130 path was rewritten — keep that harness honest"
ck; ! grep -q 'WM DE SET ON' "$PARENT/run.sh" \
  || fail "de-set started claiming live chrome — that is this harness"
ck; ! grep -q 'wmTitleHit' "$SET_C" \
  || fail "set.c names title-drag"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  CHROME.DAT + wmde pref bit, no new syscall, no help, de-set stays 130"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$PARENT/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/set.elf" ]] || fail "no set.elf"

python3 -c "open('$WORKDIR/facts.bin','wb').write(bytes.fromhex('$FACTS_HEX'))" \
  || fail "could not write facts.bin"
DISK_SRC="$WORKDIR/disk.img"
ck; python3 "$PARENT/make-image.py" "$DISK_SRC" "$WORKDIR/set.elf" \
  "$WORKDIR/facts.bin" \
  || fail "make-image.py could not produce the image"
command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_SRC"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
cp "$DISK_SRC" "$WORKDIR/disk-hit.img" || fail "could not copy hit image"
cp "$DISK_SRC" "$WORKDIR/disk-miss.img" || fail "could not copy miss image"
echo "IMAGE: pass  SET.ELF + FACTS.DAT; two copies so a hit file cannot leak"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

drive_boot() {
  local outdir="$1" keys="$2" settle="$3" label="$4"
  local keys2="$5" settle2="$6" fb2="$7" png2="$8" img="$9"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local fb="$outdir/fb.bin"
  local png="$outdir/shot.png"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local extra=()
  if [[ -n "$keys2" ]]; then
    extra+=(--keys2 "$keys2")
    extra+=(--settle2-for "$settle2")
    extra+=(--fb-out2 "$fb2" --png2 "$png2")
  fi
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --keys "$keys" \
    --settle-for "$settle" \
    --settle-timeout 60 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$fb" \
    --png "$png" \
    ${extra[@]+"${extra[@]}"}
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "comp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
  ck; [[ -s "$fb" ]] || fail "the $label boot produced no first framebuffer dump"
  if [[ -n "$fb2" ]]; then
    ck; [[ -s "$fb2" ]] || fail "the $label boot produced no second framebuffer dump"
  fi
}

KEYS_SPAWN="$(typekeys 'fb'),ret,wait:1500"
KEYS_SPAWN="$KEYS_SPAWN,$(typekeys 'wm on'),ret,wait:2500"
KEYS_SPAWN="$KEYS_SPAWN,$(typekeys 'wm de'),ret,wait:800"
KEYS_SPAWN="$KEYS_SPAWN,$(typekeys 'proc spawn SET.ELF'),ret"

KEYS2_HIT="$RELS_HIT,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_HIT_DESK,wait:200"
KEYS2_MISS="$RELS_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_MISS_DESK,wait:200"

mkdir -p "$CORE_DIR/build"

drive_boot "$WORKDIR/hit" "$KEYS_SPAWN" "USER WRITE SET READY" "HIT" \
  "$KEYS2_HIT" "$DE_LINE" \
  "$WORKDIR/hit/fb2.bin" "$CORE_DIR/build/de-set2-hit.png" "$WORKDIR/disk-hit.img"
SER_HIT="$WORKDIR/hit/serial.txt"
FB_IDLE="$WORKDIR/hit/fb.bin"
FB_HIT="$WORKDIR/hit/fb2.bin"

echo
echo "=== HIT ==="
have() { ck; grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript does not contain: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$2" && fail "the transcript contains what it must not: $1"; }
havere() { ck; grep -qE -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript matches nothing against: $1"; }; }

havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$' "$SER_HIT"
havere '^WM DE ON' "$SER_HIT"
havere '^PROC SPAWN ' "$SER_HIT"
have "USER WRITE SET READY" "$SER_HIT"
have "USER WRITE $TOGGLE_OFF" "$SER_HIT"
have "USER WRITE $TOGGLE_ON" "$SER_HIT"
have "$DE_LINE" "$SER_HIT"
havenot "USER WRITE SET MISS" "$SER_HIT"
havenot "USER WRITE SET BAD" "$SER_HIT"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_HIT" \
  || { sed -n '/M1 END/,$p' "$SER_HIT" >&2; fail "something faulted during the HIT boot"; }

PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_HIT" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"

NOTE_IDLE=$(sed -n 's/^note_idle=//p' "$MODEL")
set -- $NOTE_IDLE
ck; python3 "$PROBE" "$FB_IDLE" "$PITCH" "$2" "$3" "$4" "$1" \
  || fail "idle notify strip is not $NOTE_HEX"
NOTE_NOT=$(sed -n 's/^note_not_pref=//p' "$MODEL")
set -- $NOTE_NOT
capture NIDLE_OUT NIDLE_STATUS -- python3 "$PROBE" "$FB_IDLE" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $NIDLE_STATUS -eq 1 ]] \
  || fail "the idle notify strip is already pref $PREF_HEX — the toggle would be vacuous"

NOTE_ARM=$(sed -n 's/^note_armed=//p' "$MODEL")
set -- $NOTE_ARM
ck; python3 "$PROBE" "$FB_HIT" "$PITCH" "$2" "$3" "$4" "$1" \
  || fail "after the toggle the notify strip is not pref $PREF_HEX"
NOTE_STAY=$(sed -n 's/^note_not_idle=//p' "$MODEL")
set -- $NOTE_STAY
capture NARM_OUT NARM_STATUS -- python3 "$PROBE" "$FB_HIT" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $NARM_STATUS -eq 1 ]] \
  || fail "after the toggle the notify strip is still idle $NOTE_HEX"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$WORKDIR/disk-hit.img"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the hit image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/$PREF_NAME" ]] || fail "hit volume has no $PREF_NAME"
  ck; [[ "$(wc -c < "$MOUNTPOINT/$PREF_NAME" | tr -d ' ')" -gt 0 ]] \
    || fail "hit $PREF_NAME is empty"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
else
  fail "hdiutil not found; this harness will not certify a volume macOS has not mounted"
fi
echo "HIT: pass  $DE_LINE; notify $NOTE_HEX -> $PREF_HEX; $PREF_NAME on the volume"

echo
echo "=== MISS ==="
drive_boot "$WORKDIR/miss" "$KEYS_SPAWN" "USER WRITE SET READY" "MISS" \
  "$KEYS2_MISS" "USER WRITE SET MISS" \
  "$WORKDIR/miss/fb2.bin" "$CORE_DIR/build/de-set2-miss.png" "$WORKDIR/disk-miss.img"
SER_MISS="$WORKDIR/miss/serial.txt"
FB_MISS="$WORKDIR/miss/fb2.bin"

havere '^WM DE ON' "$SER_MISS"
have "USER WRITE SET READY" "$SER_MISS"
have "USER WRITE SET MISS" "$SER_MISS"
havenot "$DE_LINE" "$SER_MISS"
havenot "USER WRITE $TOGGLE_ON" "$SER_MISS"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_MISS" \
  || { sed -n '/M1 END/,$p' "$SER_MISS" >&2; fail "something faulted during the MISS boot"; }

MPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_MISS" | awk '{print $NF}')))
ck; [[ "$MPITCH" -gt 0 ]] || fail "could not read the miss-boot pitch"
set -- $NOTE_IDLE
ck; python3 "$PROBE" "$FB_MISS" "$MPITCH" "$2" "$3" "$4" "$1" \
  || fail "miss click moved the notify strip off $NOTE_HEX"
set -- $NOTE_NOT
capture NMISS_OUT NMISS_STATUS -- python3 "$PROBE" "$FB_MISS" "$MPITCH" "$2" "$3" "$4" "$1"
ck; [[ $NMISS_STATUS -eq 1 ]] \
  || fail "miss click left the notify strip at pref $PREF_HEX"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH2_OUT ATTACH2_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$WORKDIR/disk-miss.img"
  ck; [[ $ATTACH2_STATUS -eq 0 ]] \
    || { echo "$ATTACH2_OUT" >&2; fail "hdiutil could not mount the miss image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH2_OUT")"
  ck; [[ ! -f "$MOUNTPOINT/$PREF_NAME" ]] \
    || fail "miss volume grew $PREF_NAME — a miss must not write the pref"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
else
  fail "hdiutil not found; this harness will not certify a volume macOS has not mounted"
fi
echo "MISS: pass  outside click printed SET MISS, no $DE_LINE, notify stayed $NOTE_HEX"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-SET2: PASS — SET.ELF wrote $PREF_NAME on toggle; $DE_LINE and notify $NOTE_HEX -> $PREF_HEX; miss did neither; de-set stays 130; no new syscall, no help"
exit 0
