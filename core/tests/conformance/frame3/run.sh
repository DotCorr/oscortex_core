#!/usr/bin/env bash
# core/tests/conformance/frame3/run.sh
#
# FRAME3 — the kept surface client reads kbdevent and persists a colour.
# docs/design/app-framework.md FRAME3.
#
# SURF.ELF is core/user/frame/surf.c compiled against osframe.h with
# -DFRAME3=1 (no private SYS_*). `proc spawn SURF.ELF` starts it so the
# prompt returns (ADR-0053). The harness clicks the surface (D9: the
# spawned client is the consumer while focus is live; the shell drain
# skips). Two derived keys at 50 ms: 'a' then 'c'. The framebuffer's
# fill is COLOUR_C (the last make-scancode). THEME.DAT is four bytes of
# that u32; the host reads it back through fsck_msdos + msdos (M16).
#
# Anti-vacuity: KEY_A and KEY_C map to two different colours; a client
# that only handles 'a' cannot match COLOUR_C.
# Negative: NOKBD.ELF never calls kbdevent — fill stays SURF_FILL and
# there is no THEME.DAT. Host model: sizeof(buf)=64 is not 4 bytes.
#
# No new syscall, no help, no wm chrome, rename not required (new file).
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SURF_C="$CORE_DIR/user/frame/surf.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "FRAME3: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FRAME3: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=82

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-frame3.XXXXXX")" \
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
ck; [[ -f "$SURF_C" ]] || setup_error "no surf.c at $SURF_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SURF_C' \
  '$CORE_DIR/kernel/wm.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

WIN_W=$(d win_w); WIN_H=$(d win_h)
AREA=$(d area)
FILL_HEX=$(d surf_fill_hex)
CA_HEX=$(d colour_a_hex); CC_HEX=$(d colour_c_hex)
DESK_HEX=$(d desk_hex); INK_HEX=$(d ink_hex)
THEME=$(d theme_file)
PERSIST=$(d persist_bytes)
SIZEOF_BUF=$(d sizeof_buf)
RELS=$(d rels_to_click)
KEYS_IN=$(d keys)
PROBE_COUNT=$(d probe_count)

ck; [[ "$AREA" -gt 0 ]] || fail "derived surface area is $AREA — anti-vacuity"
ck; [[ "$CA_HEX" != "$CC_HEX" ]] \
  || fail "COLOUR_A $CA_HEX equals COLOUR_C $CC_HEX — two keys would be one colour"
ck; [[ "$PERSIST" -eq 4 ]] || fail "persist_bytes is $PERSIST, expected 4"
ck; [[ "$SIZEOF_BUF" -ne "$PERSIST" ]] \
  || fail "sizeof-buf $SIZEOF_BUF equals persist_bytes — the write-length control is vacuous"
ck; [[ "$THEME" == "THEME.DAT" ]] || fail "theme file is $THEME, expected THEME.DAT"
ck; [[ "$KEYS_IN" == "ac" ]] || fail "derived keys are $KEYS_IN, expected ac"
echo "DERIVED: ${WIN_W}x${WIN_H} keys $KEYS_IN -> last fill $CC_HEX, persist $THEME $PERSIST bytes; sizeof-buf $SIZEOF_BUF is the failing write length"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$SURF_C" \
  || fail "surf.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$SURF_C" \
  || fail "surf.c copies SYS_* by hand — include osframe.h"
ck; grep -q '^#define SYS_KBDEVENT 24$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_KBDEVENT 24"
ck; grep -q 'SYS_KBDEVENT' "$SURF_C" \
  || fail "surf.c never names SYS_KBDEVENT"
ck; grep -q 'SYS_FDWRITE' "$SURF_C" \
  || fail "surf.c never names SYS_FDWRITE"
ck; grep -q 'THEME.DAT' "$SURF_C" \
  || fail "surf.c does not name THEME.DAT"
ck; ! grep -q 'surf\.c\|SURF\.ELF\|FRAME3\|THEME\.DAT' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names FRAME3 / THEME — FRAME3 must not touch the kernel"
ck; ! grep -E 'SURF|FRAME3|THEME|osframe' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a FRAME3 name — no new help"
ck; ! grep -q '  theme  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'theme' help line has appeared in shell.dart"
# Do not touch wm chrome.
ck; ! grep -q 'FRAME3\|THEME.DAT\|surf.c' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart grew a FRAME3 name — do not touch wm chrome"
ck; ! grep -q 'FRAME3\|THEME.DAT' "$CORE_DIR/kernel/wmpop.dart" \
  || fail "wmpop.dart grew a FRAME3 name"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  osframe.h only, kbdevent+fdwrite, no kernel edit, no help, no chrome"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/surf.elf" ]] || fail "no surf.elf"
ck; [[ -s "$WORKDIR/nokbd.elf" ]] || fail "no nokbd.elf"

DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/surf.elf" "$WORKDIR/nokbd.elf" \
  || fail "make-image.py could not produce a verified image"
cp "$DISK_IMG" "$WORKDIR/disk-nokbd.img" \
  || fail "could not copy the as-built image for the NOKBD boot"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the as-built image"; }
echo "IMAGE: pass  fsck_msdos accepts the volume"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the as-built image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/SURF.ELF" ]] || fail "mounted volume has no SURF.ELF"
  ck; [[ -f "$MOUNTPOINT/NOKBD.ELF" ]] || fail "mounted volume has no NOKBD.ELF"
  ck; [[ ! -e "$MOUNTPOINT/THEME.DAT" ]] \
    || fail "THEME.DAT is already on the as-built volume — the guest creating it would prove nothing"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver reads SURF.ELF / NOKBD.ELF; no THEME.DAT"
else
  fail "hdiutil not found; this harness will not certify a written volume that macOS's own msdos driver has not mounted"
fi

echo
echo "=== NEGATIVE (host model, sizeof buf) ==="
ck; [[ "$SIZEOF_BUF" -gt "$PERSIST" ]] \
  || fail "sizeof-buf $SIZEOF_BUF is not larger than persist_bytes $PERSIST"
echo "NEGATIVE: pass  a client that fdwrite()s sizeof(buf)=$SIZEOF_BUF cannot match the $PERSIST-byte host read-back"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

drive_boot() {
  local outdir="$1" keys="$2" keys2="$3" settle="$4" settle2="$5" label="$6" img="$7"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local fb="$outdir/fb.bin"
  local fb2="$outdir/fb2.bin"
  local png="$outdir/shot.png"
  local png2="$outdir/shot2.png"
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
  local drive_status
  local extra=()
  if [[ -n "$keys2" ]]; then
    extra+=(--keys2 "$keys2")
  fi
  if [[ -n "$settle2" ]]; then
    extra+=(--settle2-for "$settle2" --fb-out2 "$fb2" --png2 "$png2")
  else
    extra+=(--fb-out2 "$fb2" --png2 "$png2")
  fi
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
  ck; [[ -s "$fb2" ]] || fail "the $label boot produced no second framebuffer dump"
}

KEYS_SURF="$(typekeys 'fb'),ret,wait:1500"
KEYS_SURF="$KEYS_SURF,$(typekeys 'wm on'),ret,wait:2500"
KEYS_SURF="$KEYS_SURF,$(typekeys 'proc spawn SURF.ELF'),ret"
KEYS2_SURF="$RELS,wait:400,btn:left:down,wait:400,btn:left:up,wait:200"
KEYS2_SURF="$KEYS2_SURF,a,wait:50,c"

drive_boot "$WORKDIR/surf" "$KEYS_SURF" "$KEYS2_SURF" \
  "USER WRITE FRAME2 COMMIT" "USER WRITE FRAME3 THEME" "SURF" "$DISK_IMG"
SER="$WORKDIR/surf/serial.txt"
FB_BIN="$WORKDIR/surf/fb.bin"
FB2_BIN="$WORKDIR/surf/fb2.bin"

echo
echo "=== TRANSCRIPT ==="
have() { ck; grep -qF -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript does not contain: $1"; }; }
havere() { ck; grep -qE -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript matches nothing against: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SER" && fail "the transcript contains what it must not: $1"; }

havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$'
havere '^PROC SPAWN '
havere '^ELF FILE '
have "USER WRITE FRAME2 ATTACH"
have "USER WRITE FRAME2 COMMIT"
have "USER WRITE FRAME3 KEY"
have "USER WRITE FRAME3 THEME"
KEY_N=$(grep -cF "USER WRITE FRAME3 KEY" "$SER" | tr -d ' ')
ck; [[ "$KEY_N" -ge 2 ]] \
  || fail "FRAME3 KEY appears $KEY_N times, expected at least 2 (a and c)"
havent "WM REAP W "
havent "PROC END"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "something faulted during the SURF boot"; }
echo "TRANSCRIPT: pass  spawn SURF.ELF, ATTACH, COMMIT, two KEY, THEME, no REAP"

echo
echo "=== PIXELS ==="
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"

# After spawn, before keys: fill is still SURF_FILL.
set -- $(sed -n 's/^probe=fill //p' "$MODEL")
FILL_X="$1"; FILL_Y="$2"
capture PRE_OUT PRE_STATUS -- python3 "$PROBE" "$FB_BIN" "$PITCH" "$FILL_X" "$FILL_Y" "$FILL_HEX" "pre_fill"
ck; [[ $PRE_STATUS -eq 0 ]] \
  || { echo "$PRE_OUT" >&2; fail "before keys the fill was not SURF_FILL $FILL_HEX"; }
echo "$PRE_OUT"

PROBES_RUN=0
while IFS= read -r line; do
  set -- $line
  PROBES_RUN=$(( PROBES_RUN + 1 ))
  ck; python3 "$PROBE" "$FB2_BIN" "$PITCH" "$2" "$3" "$4" "$1" \
    || fail "pixel probe '$1' failed — SURF.ELF did not put that colour there after the keys"
done < <(sed -n 's/^probe=//p' "$MODEL")
ck; [[ "$PROBES_RUN" -eq "$PROBE_COUNT" ]] \
  || fail "the probe loop ran $PROBES_RUN times and the model derives $PROBE_COUNT probes"

# A client that only handled 'a' would leave COLOUR_A in the fill.
capture A_OUT A_STATUS -- python3 "$PROBE" "$FB2_BIN" "$PITCH" "$FILL_X" "$FILL_Y" "$CA_HEX" "not_colour_a"
ck; [[ $A_STATUS -eq 1 ]] \
  || fail "the fill is COLOUR_A — the last key was 'c'; a one-key client passed"
echo "PIXELS: pass  $PROBES_RUN probes after keys, fill $CC_HEX (not $CA_HEX), pre-key fill $FILL_HEX"

echo
echo "=== PERSIST (host read-back) ==="
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK2_STATUS -eq 0 ]] \
  || { echo "$FSCK2_OUT" >&2; fail "fsck_msdos rejected the volume after the guest wrote"; }
mkdir -p "$MOUNTPOINT"
capture ATTACH2_OUT ATTACH2_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
  -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
ck; [[ $ATTACH2_STATUS -eq 0 ]] \
  || { echo "$ATTACH2_OUT" >&2; fail "hdiutil could not mount the image the guest wrote"; }
ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH2_OUT")"
ck; [[ -f "$MOUNTPOINT/$THEME" ]] || fail "the mounted volume has no $THEME"
THEME_PATH="$WORKDIR/theme.dat"
cp "$MOUNTPOINT/$THEME" "$THEME_PATH" || fail "could not copy $THEME off the volume"
hdiutil detach "$ATTACHED" >/dev/null 2>&1
ATTACHED=""

THEME_N=$(wc -c <"$THEME_PATH" | tr -d ' ')
ck; [[ "$THEME_N" -eq "$PERSIST" ]] \
  || fail "$THEME is $THEME_N bytes, expected $PERSIST — a sizeof(buf) write would be $SIZEOF_BUF"
capture_sh TH_OUT TH_STATUS -- "python3 - '$THEME_PATH' '$CC_HEX' '$PERSIST' <<'PY'
import sys
blob = open(sys.argv[1], 'rb').read()
want = int(sys.argv[2], 16) & 0xFFFFFF
n = int(sys.argv[3])
if len(blob) != n:
    raise SystemExit('%s is %d bytes, expected %d' % (sys.argv[1], len(blob), n))
got = int.from_bytes(blob[:4], 'little') & 0xFFFFFF
if got != want:
    raise SystemExit('THEME.DAT is %06X, expected last-key colour %06X' % (got, want))
print('    THEME.DAT %d bytes = %06X (COLOUR_C)' % (n, got))
PY"
ck; [[ $TH_STATUS -eq 0 ]] || { echo "$TH_OUT" >&2; fail "THEME.DAT does not hold the last-key colour"; }
echo "$TH_OUT"
echo "PERSIST: pass  $THEME is $PERSIST bytes of $CC_HEX, fsck_msdos clean, msdos mounted"

echo
echo "=== NOKBD ==="
KEYS_NO="$(typekeys 'fb'),ret,wait:1500"
KEYS_NO="$KEYS_NO,$(typekeys 'wm on'),ret,wait:2500"
KEYS_NO="$KEYS_NO,$(typekeys 'proc spawn NOKBD.ELF'),ret"
KEYS2_NO="$RELS,wait:400,btn:left:down,wait:400,btn:left:up,wait:200"
KEYS2_NO="$KEYS2_NO,a,wait:50,c,wait:3000"

drive_boot "$WORKDIR/nokbd" "$KEYS_NO" "$KEYS2_NO" \
  "USER WRITE FRAME2 COMMIT" "" "NOKBD" "$WORKDIR/disk-nokbd.img"
NSER="$WORKDIR/nokbd/serial.txt"
NFB2="$WORKDIR/nokbd/fb2.bin"

ck; grep -qF "USER WRITE FRAME2 ATTACH" "$NSER" \
  || fail "the nokbd boot never attached"
ck; grep -qF "USER WRITE FRAME3 KEY" "$NSER" \
  && fail "the nokbd boot printed FRAME3 KEY — it must not pop kbdevent"
ck; grep -qF "USER WRITE FRAME3 THEME" "$NSER" \
  && fail "the nokbd boot printed FRAME3 THEME — it must not persist"

NPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$NSER" | awk '{print $NF}')))
ck; [[ "$NPITCH" -gt 0 ]] || fail "could not read the nokbd pitch"
set -- $(sed -n 's/^nokbd_fill=//p' "$MODEL")
NX="$1"; NY="$2"; NCOL="$3"
capture NCTL_OUT NCTL_STATUS -- python3 "$PROBE" "$NFB2" "$NPITCH" "$NX" "$NY" "$NCOL" "nokbd_fill"
ck; [[ $NCTL_STATUS -eq 0 ]] \
  || { echo "$NCTL_OUT" >&2; fail "nokbd left ($NX,$NY) not SURF_FILL — a client that never calls kbdevent must not change the colour"; }
capture NFILL_OUT NFILL_STATUS -- python3 "$PROBE" "$NFB2" "$NPITCH" "$NX" "$NY" "$CC_HEX" "nokbd_cc"
ck; [[ $NFILL_STATUS -eq 1 ]] \
  || fail "nokbd has COLOUR_C at the surface — the kbdevent-less control failed"

mkdir -p "$MOUNTPOINT"
capture ATTACH3_OUT ATTACH3_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
  -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$WORKDIR/disk-nokbd.img"
ck; [[ $ATTACH3_STATUS -eq 0 ]] \
  || { echo "$ATTACH3_OUT" >&2; fail "hdiutil could not mount the nokbd image"; }
ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH3_OUT")"
ck; [[ ! -e "$MOUNTPOINT/$THEME" ]] \
  || fail "nokbd created $THEME — the persist negative is vacuous"
hdiutil detach "$ATTACHED" >/dev/null 2>&1
ATTACHED=""
echo "NOKBD: pass  no kbdevent, fill stayed $FILL_HEX, no $THEME"

require_assertions "$ASSERTIONS_REQUIRED"
echo "FRAME3: PASS — SURF.ELF (osframe.h, kbdevent 24, no SYS_* copy) spawned, focused, two keys, fill $CC_HEX, $THEME $PERSIST bytes of that u32 via msdos; nokbd left $FILL_HEX and no file; no kernel .bss, no help, no chrome, no new syscall"
exit 0
