#!/usr/bin/env bash
# core/tests/conformance/de-set/run.sh
#
# Settings — a FRAME client displays derived fb / chrome facts and
# one local toggle. docs/decisions/0105-settings-reads-derived-facts.md.
#
# SET.ELF is core/user/frame/set.c compiled against osframe.h (no
# private SYS_*). `proc spawn SET.ELF` starts it so the prompt returns
# (ADR-0053). Facts come from planted FACTS.DAT the host derived from
# fb.dart / wmchrome.dart / wm.dart. A click inside the toggle flips
# the chrome swatch and the control. A click outside does not. A
# truncated FACTS.DAT is SET BAD. No new syscall, no help, no kernel
# edit. Syscall 11 stays fdwait.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

SET_C="$CORE_DIR/user/frame/set.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "DE-SET: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-SET: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run (130 checks executed).
ASSERTIONS_REQUIRED=134

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-set.XXXXXX")" \
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

echo "=== BUILD ==="
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
  '$CORE_DIR/kernel/kbdq.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

WIN_W=$(d win_w); WIN_H=$(d win_h)
CTL_AREA=$(d ctl_area); AREA=$(d area); FB_AREA=$(d fb_area)
IDLE_N=$(d idle_probe_count); ARMED_N=$(d armed_probe_count)
FILL_HEX=$(d surf_fill_hex); OFF_HEX=$(d ctl_off_hex); ON_HEX=$(d ctl_on_hex)
DESK_HEX=$(d desk_hex); CHROME_HEX=$(d chrome_hex); TITLE_HEX=$(d title_hex)
RELS_HIT=$(d rels_to_hit); RELS_MISS=$(d rels_to_miss)
RELS_HIT_DESK=$(d rels_hit_to_desk); RELS_MISS_DESK=$(d rels_miss_to_desk)
KEY_LETTER=$(d key_letter)
FB_LINE=$(d fb_line); FB_MODE=$(d fb_mode)
CHROME_LINE=$(d chrome_line)
DESK_LINE=$(d desk_line); BAR_LINE=$(d bar_line); TITLE_LINE=$(d title_line)
TOGGLE_OFF=$(d toggle_off_line); TOGGLE_ON=$(d toggle_on_line)
FACTS_LEN=$(d facts_len); FACTS_TRUNC_LEN=$(d facts_trunc_len)
FACTS_HEX=$(d facts_hex); FACTS_TRUNC_HEX=$(d facts_trunc_hex)
SYS_WM=$(d syscall_wm); SYS_KBD=$(d syscall_kbd); SYS_EV=$(d syscall_ev)
FB_W=$(d fb_w); FB_H=$(d fb_h)

ck; [[ "$AREA" -gt 0 ]] || fail "derived surface area is $AREA — anti-vacuity"
ck; [[ "$CTL_AREA" -gt 0 ]] || fail "derived control area is $CTL_AREA — anti-vacuity"
ck; [[ "$CTL_AREA" -lt "$AREA" ]] \
  || fail "control area $CTL_AREA equals the surface $AREA"
ck; [[ "$FB_AREA" -gt 0 ]] || fail "derived fb area is $FB_AREA — anti-vacuity"
ck; [[ "$OFF_HEX" != "$ON_HEX" ]] \
  || fail "CTL_OFF $OFF_HEX equals CTL_ON $ON_HEX"
ck; [[ "$CHROME_HEX" != "$DESK_HEX" ]] \
  || fail "chrome colour $CHROME_HEX equals desktop $DESK_HEX"
ck; [[ "$CHROME_HEX" != "$TITLE_HEX" ]] \
  || fail "chrome colour equals title — the toggle swatch would be invisible"
ck; [[ "$IDLE_N" -gt 0 && "$ARMED_N" -gt 0 ]] \
  || fail "the model derives $IDLE_N idle and $ARMED_N armed probes"
ck; [[ "$FACTS_LEN" -gt 26 ]] \
  || fail "planted FACTS.DAT is $FACTS_LEN bytes — must be longer than FACTS_NEED"
ck; [[ "$FACTS_TRUNC_LEN" -lt 26 ]] \
  || fail "trunc FACTS.DAT is $FACTS_TRUNC_LEN bytes — not a truncate"
echo "DERIVED: fb ${FB_W}x${FB_H} win ${WIN_W}x${WIN_H} control $CTL_AREA px; desk $DESK_HEX bar $CHROME_HEX title $TITLE_HEX; facts $FACTS_LEN bytes"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$SET_C" \
  || fail "set.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$SET_C" \
  || fail "set.c copies SYS_* by hand — include osframe.h"
ck; grep -q '^#define SYS_SHMCREATE 16$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_SHMCREATE 16"
ck; grep -q '^#define SYS_WMSURFACE 23$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_WMSURFACE 23"
ck; grep -q '^#define SYS_KBDEVENT 24$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_KBDEVENT 24"
ck; grep -q '^#define SYS_WMEVENT 25$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_WMEVENT 25"
ck; [[ "$SYS_WM" -eq 23 ]] || fail "derive.py says wmsurface is $SYS_WM, expected 23"
ck; [[ "$SYS_KBD" -eq 24 ]] || fail "derive.py says kbdevent is $SYS_KBD, expected 24"
ck; [[ "$SYS_EV" -eq 25 ]] || fail "derive.py says wmevent is $SYS_EV, expected 25"
ck; ! grep -qE 'fdwait|SYS_FDWAIT' "$SET_C" \
  || fail "set.c names fdwait — 11 stays reserved"
ck; ! grep -qE '\b800\b|\b600\b' "$SET_C" \
  || fail "set.c bakes 800 or 600"
ck; grep -q 'Appearance' "$SET_C" || fail "SET has no Appearance"
ck; grep -q 'Devices' "$SET_C" || fail "SET has no Devices"
ck; grep -q 'SIDE_W' "$SET_C" || fail "SET has no glass sidebar width"
ck; grep -q 'CTL_ON 0x004080E0' "$SET_C" \
  || fail "SET accent is not glass blue"
ck; ! grep -qE 'CTL_ON 0x00E07020|CTL_OFF 0x00305070' "$SET_C" \
  || fail "SET still uses orange/green probe colours"
ck; ! grep -qiE 'guest OS' "$CORE_DIR/docs/decisions/0105-settings-reads-derived-facts.md" \
  || fail "ADR-0105 says guest OS"
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
ck; ! grep -F -e 'SET.ELF' -e 'FACTS.DAT' -e 'DE-SET' \
      "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a Settings name — no new help"
ck; ! grep -q '  set  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'set' help line has appeared in shell.dart"
ck; ! grep -F -e 'SET.ELF' -e 'set.c' -e 'FACTS.DAT' \
      "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart was rewritten for Settings"
ck; ! grep -F -e 'SET.ELF' -e 'set.c' -e 'FACTS.DAT' \
      "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart was rewritten for Settings"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  osframe.h only, syscalls 16/23/24/25 + open/read/fdwrite, no SET name in kernel, no help, no fdwait"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/set.elf" ]] || fail "no set.elf"

python3 -c "open('$WORKDIR/facts.bin','wb').write(bytes.fromhex('$FACTS_HEX'))" \
  || fail "could not write facts.bin"
python3 -c "open('$WORKDIR/facts.trunc','wb').write(bytes.fromhex('$FACTS_TRUNC_HEX'))" \
  || fail "could not write facts.trunc"
ck; [[ "$(wc -c < "$WORKDIR/facts.bin" | tr -d ' ')" -eq "$FACTS_LEN" ]] \
  || fail "facts.bin is not $FACTS_LEN bytes"
ck; [[ "$(wc -c < "$WORKDIR/facts.trunc" | tr -d ' ')" -eq "$FACTS_TRUNC_LEN" ]] \
  || fail "facts.trunc is not $FACTS_TRUNC_LEN bytes"

DISK_IMG="$WORKDIR/disk.img"
DISK_TRUNC="$WORKDIR/disk-trunc.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/set.elf" \
  "$WORKDIR/facts.bin" \
  || fail "make-image.py could not produce the full image"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_TRUNC" "$WORKDIR/set.elf" \
  "$WORKDIR/facts.trunc" \
  || fail "make-image.py could not produce the trunc image"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the full image"; }
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_TRUNC"
ck; [[ $FSCK2_STATUS -eq 0 ]] || { echo "$FSCK2_OUT" >&2; fail "fsck_msdos rejected the trunc image"; }

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the full image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/SET.ELF" ]] || fail "mounted volume has no SET.ELF"
  ck; [[ -f "$MOUNTPOINT/FACTS.DAT" ]] || fail "mounted volume has no FACTS.DAT"
  ck; [[ "$(wc -c < "$MOUNTPOINT/FACTS.DAT" | tr -d ' ')" -eq "$FACTS_LEN" ]] \
    || fail "mounted FACTS.DAT is not $FACTS_LEN bytes"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  SET.ELF + FACTS.DAT $FACTS_LEN bytes; trunc $FACTS_TRUNC_LEN"
else
  fail "hdiutil not found; this harness will not certify a volume macOS has not mounted"
fi

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
KEYS_SPAWN="$KEYS_SPAWN,$(typekeys 'proc spawn SET.ELF'),ret"

KEYS2_HIT="$RELS_HIT,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_HIT_DESK,wait:200"
KEYS2_MISS="$RELS_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_MISS_DESK,wait:200"

mkdir -p "$CORE_DIR/build"

drive_boot "$WORKDIR/hit" "$KEYS_SPAWN" "USER WRITE SET READY" "HIT" \
  "$KEYS2_HIT" "USER WRITE $TOGGLE_ON" \
  "$WORKDIR/hit/fb2.bin" "$CORE_DIR/build/de-set-hit.png" "$DISK_IMG"
SER_HIT="$WORKDIR/hit/serial.txt"
FB_IDLE="$WORKDIR/hit/fb.bin"
FB_HIT="$WORKDIR/hit/fb2.bin"

echo
echo "=== HIT ==="
have() { ck; grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript does not contain: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$2" && fail "the transcript contains what it must not: $1"; }
havere() { ck; grep -qE -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript matches nothing against: $1"; }; }

havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$' "$SER_HIT"
havere '^PROC SPAWN ' "$SER_HIT"
havere "MODE ${FB_MODE}" "$SER_HIT"
have "USER WRITE $FB_LINE" "$SER_HIT"
have "USER WRITE $CHROME_LINE" "$SER_HIT"
have "USER WRITE $DESK_LINE" "$SER_HIT"
have "USER WRITE $BAR_LINE" "$SER_HIT"
have "USER WRITE $TITLE_LINE" "$SER_HIT"
have "USER WRITE SET READY" "$SER_HIT"
have "USER WRITE $TOGGLE_OFF" "$SER_HIT"
have "USER WRITE $TOGGLE_ON" "$SER_HIT"
havenot "USER WRITE SET MISS" "$SER_HIT"
havenot "USER WRITE SET BAD" "$SER_HIT"
havere '^WM ATTACH W ' "$SER_HIT"
havere '^WM COMMIT W ' "$SER_HIT"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_HIT" \
  || { sed -n '/M1 END/,$p' "$SER_HIT" >&2; fail "something faulted during the HIT boot"; }

# App SET FB must match the kernel fb probe the harness already typed.
ck; python3 - "$SER_HIT" "$FB_LINE" "$FB_MODE" <<'PY' || fail "SET FB does not match the kernel MODE line"
import sys
blob = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
line, mode = sys.argv[2], sys.argv[3]
if line not in blob or mode not in blob:
    raise SystemExit(1)
# MODE 0320x0258 is a prefix of MODE 0320x0258x20
if mode not in line.replace("SET FB ", ""):
    raise SystemExit(1)
PY

PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_HIT" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"

probe_loop() {
  local fb="$1" prefix="$2" expect="$3" label="$4"
  local n=0
  while IFS= read -r line; do
    set -- $line
    n=$(( n + 1 ))
    ck; python3 "$PROBE" "$fb" "$PITCH" "$2" "$3" "$4" "$1" \
      || fail "pixel probe '$1' failed on the $label dump — expected $4"
  done < <(sed -n "s/^${prefix}=//p" "$MODEL")
  ck; [[ "$n" -eq "$expect" ]] \
    || fail "the $label probe loop ran $n times and the model derives $expect"
  echo "    $label: $n probes matched"
}

echo "IDLE (before the in-control click):"
probe_loop "$FB_IDLE" "idle_probe" "$IDLE_N" "idle"
CTL_IDLE=$(sed -n 's/^control_idle=//p' "$MODEL")
set -- $CTL_IDLE
capture CIDLE_OUT CIDLE_STATUS -- python3 "$PROBE" "$FB_IDLE" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CIDLE_STATUS -eq 1 ]] \
  || fail "the idle control asserted ON $ON_HEX and passed — the flip would be vacuous"
BAR_IDLE=$(sed -n 's/^control_bar_idle=//p' "$MODEL")
set -- $BAR_IDLE
capture BIDLE_OUT BIDLE_STATUS -- python3 "$PROBE" "$FB_IDLE" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $BIDLE_STATUS -eq 1 ]] \
  || fail "the idle chrome swatch is already title $TITLE_HEX — the toggle would be vacuous"
echo "    idle control is not $ON_HEX; chrome swatch is not $TITLE_HEX"

echo "ARMED (after the in-control click):"
probe_loop "$FB_HIT" "armed_probe" "$ARMED_N" "armed"
CTL_FILL=$(sed -n 's/^control_fill=//p' "$MODEL")
set -- $CTL_FILL
capture CFILL_OUT CFILL_STATUS -- python3 "$PROBE" "$FB_HIT" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CFILL_STATUS -eq 1 ]] \
  || fail "the fill band is $ON_HEX after the flip — a client that paints the whole surface cannot pass"
echo "HIT: pass  facts $FB_LINE $CHROME_LINE; toggle $OFF_HEX -> $ON_HEX; chrome swatch $CHROME_HEX -> $TITLE_HEX"

echo
echo "=== MISS ==="
drive_boot "$WORKDIR/miss" "$KEYS_SPAWN" "USER WRITE SET READY" "MISS" \
  "$KEYS2_MISS" "USER WRITE SET MISS" \
  "$WORKDIR/miss/fb2.bin" "$CORE_DIR/build/de-set-miss.png" "$DISK_IMG"
SER_MISS="$WORKDIR/miss/serial.txt"
FB_MISS="$WORKDIR/miss/fb2.bin"

havere '^PROC SPAWN ' "$SER_MISS"
have "USER WRITE SET READY" "$SER_MISS"
have "USER WRITE $FB_LINE" "$SER_MISS"
have "USER WRITE $CHROME_LINE" "$SER_MISS"
have "USER WRITE SET MISS" "$SER_MISS"
havenot "USER WRITE $TOGGLE_ON" "$SER_MISS"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_MISS" \
  || { sed -n '/M1 END/,$p' "$SER_MISS" >&2; fail "something faulted during the MISS boot"; }

MPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_MISS" | awk '{print $NF}')))
ck; [[ "$MPITCH" -gt 0 ]] || fail "could not read the miss-boot pitch"
PITCH="$MPITCH"
probe_loop "$FB_MISS" "idle_probe" "$IDLE_N" "miss"
CTL_MISS=$(sed -n 's/^control_miss=//p' "$MODEL")
set -- $CTL_MISS
capture CMISS_OUT CMISS_STATUS -- python3 "$PROBE" "$FB_MISS" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CMISS_STATUS -eq 1 ]] \
  || fail "the miss click left the control at $ON_HEX — a client that treats any wmevent as a hit fails this probe"
echo "MISS: pass  outside click printed SET MISS and left the control at $OFF_HEX"

echo
echo "=== TRUNC ==="
KEYS_TRUNC="$(typekeys 'fb'),ret,wait:1500"
KEYS_TRUNC="$KEYS_TRUNC,$(typekeys 'wm on'),ret,wait:2500"
KEYS_TRUNC="$KEYS_TRUNC,$(typekeys 'proc spawn SET.ELF'),ret"
drive_boot "$WORKDIR/trunc" "$KEYS_TRUNC" "USER WRITE SET BAD" "TRUNC" \
  "" "" "" "" "$DISK_TRUNC"
SER_TRUNC="$WORKDIR/trunc/serial.txt"

havere '^PROC SPAWN ' "$SER_TRUNC"
have "USER WRITE SET BAD" "$SER_TRUNC"
havenot "USER WRITE $FB_LINE" "$SER_TRUNC"
havenot "USER WRITE $CHROME_LINE" "$SER_TRUNC"
havenot "USER WRITE SET READY" "$SER_TRUNC"
havenot "USER WRITE $TOGGLE_ON" "$SER_TRUNC"
havenot "USER WRITE $TOGGLE_OFF" "$SER_TRUNC"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_TRUNC" \
  || { sed -n '/M1 END/,$p' "$SER_TRUNC" >&2; fail "something faulted during the TRUNC boot"; }
echo "TRUNC: pass  short FACTS.DAT printed SET BAD and no SET FB / SET TOGGLE"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-SET: PASS — SET.ELF (osframe.h) spawned, read derived FACTS.DAT (${FB_W}x${FB_H}, chrome off, desk $DESK_HEX bar $CHROME_HEX title $TITLE_HEX); in-control click flipped the chrome swatch to $TITLE_HEX and the control to $ON_HEX; outside click did not; truncated facts refused; no kernel .bss, no help, no new syscall, fdwait stays 11"
exit 0
