#!/usr/bin/env bash
# core/tests/conformance/files-mv2/run.sh
#
# ADR-0149 — FILES.ELF move consumes rename (32): source name is gone.
# docs/decisions/0149-files-move-consumes-rename.md
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# FILES.ELF renames the second planted .DAT onto stem.MOV. After boot the
# FAT walk and macOS msdos see the dest bytes and do NOT see the source
# name. Copy still leaves its source. files-fm stays green on the same
# consumer. 11 stays fdwait. No help line.
#
# Anti-vacuity: a second copy left behind fails. Plant bytes are not in
# files.c. SYS_RENAME must appear in files.c and osframe.h.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
FILES_C="$CORE_DIR/user/frame/files.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "FILES-MV2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FILES-MV2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=60

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-files-mv2.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "$ATTACHED" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
FILE_SRC="$CORE_DIR/kernel/file.dart"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$FILES_C" ]] || setup_error "no files.c"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h"
ck; [[ -f "$CORE_DIR/docs/decisions/0149-files-move-consumes-rename.md" ]] \
  || fail "ADR-0149 is missing"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" || fail "could not snapshot kernel.elf"
KERNEL_ELF="$WORKDIR/kernel.elf"
KERN_END=$(x86_64-elf-nm "$KERNEL_ELF" | awk '$3=="__kernel_end"{print $1; exit}')
ck; [[ -n "$KERN_END" ]] || fail "snapshot kernel has no __kernel_end"
ck; [[ $((16#$KERN_END)) -le 4194304 ]] \
  || fail "snapshot kernel __kernel_end is 0x$KERN_END, above vmFineBytes 4MiB"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'SYS_RENAME' "$FILES_C" \
  || fail "files.c does not call SYS_RENAME — move still copies"
ck; grep -q 'do_move' "$FILES_C" \
  || fail "files.c has no do_move"
ck; ! grep -q 'do_copy_or_move' "$FILES_C" \
  || fail "files.c still shares copy/move as one copy path"
ck; grep -q 'SYS_RENAME 32' "$FRAME_H" \
  || fail "osframe.h does not name SYS_RENAME 32"
ck; grep -q 'SYS_UNLINK 31' "$FRAME_H" \
  || fail "osframe.h does not name SYS_UNLINK 31"
ck; grep -q 'fileSysRenameNo = 32' "$FILE_SRC" \
  || fail "file.dart lost rename 32"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  rename move, osframe 31/32, fdwait 11, help 2511"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/files.elf" ]] || fail "no files.elf"

echo
echo "=== PLANTS ==="
python3 - "$WORKDIR" "$FILES_C" "$FILE_SRC" <<'PY' || fail "could not derive plants"
import os, random, string, sys
wd, files_c, file_src = sys.argv[1:]
src = open(files_c, encoding="utf-8").read() + open(file_src, encoding="utf-8").read()
used_names = set()
used_hex = set()

def one(tag):
    while True:
        stem = "P" + "".join(random.choice(string.ascii_uppercase + string.digits) for _ in range(4))
        name = stem + ".DAT"
        blob = os.urandom(16)
        hx = blob.hex().upper()
        if name in ("FILES.ELF", "GHOST.DAT") or name in used_names:
            continue
        if hx.lower() in src.lower() or name in src or hx in used_hex:
            continue
        if blob == bytes(16) or blob[:3] == b"\x00\x00\x00":
            continue
        used_names.add(name)
        used_hex.add(hx)
        open(os.path.join(wd, tag + ".name"), "w").write(name)
        open(os.path.join(wd, tag + ".hex"), "w").write(hx)
        return

one("plantA")
one("plantC")
print("DERIVE: ok")
PY
NAME_A=$(tr -d '\n' < "$WORKDIR/plantA.name")
HEX_A=$(tr -d '\n' < "$WORKDIR/plantA.hex")
NAME_C=$(tr -d '\n' < "$WORKDIR/plantC.name")
HEX_C=$(tr -d '\n' < "$WORKDIR/plantC.hex")
COPY_A="${NAME_A%.DAT}.CPY"
MOVE_C="${NAME_C%.DAT}.MOV"
ck; [[ "$NAME_A" != "$NAME_C" ]] || fail "plant names collided"
ck; [[ "$HEX_A" != "$HEX_C" ]] || fail "plant bytes collided"
ck; ! grep -Fqi "$NAME_C" "$FILES_C" || fail "move source baked into files.c"
ck; ! grep -Fqi "$MOVE_C" "$FILES_C" || fail "move dest baked into files.c"

IMG_A="$WORKDIR/fullA.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_A" "$WORKDIR/files.elf" \
  --variant=full --plant-name="$NAME_A" --plant-hex="$HEX_A" \
  --plant2-name="$NAME_C" --plant2-hex="$HEX_C" \
  || fail "make-image A failed"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$IMG_A"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected image A"; }

DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$NAME_A" "$HEX_A" "" "" \
  "$NAME_C" "$HEX_C" \
  > "$DERIVED" || fail "derive.py failed"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }

SHA_BEFORE=$(shasum -a 256 "$IMG_A" | cut -d' ' -f1)

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3" img="$4"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
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
  run_status drive_status -- python3 - "$port" "$ser" "$keys" <<'PY'
import json, os, socket, sys, time

port, serial, keys = int(sys.argv[1]), sys.argv[2], sys.argv[3]

class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                hello = json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                print("FILES-MV2: QEMU", hello.get("QMP", {}).get("version", {}))
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("could not connect to QMP: %s" % last)

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    raise SystemExit("QMP %s: %s" % (execute, msg["error"]))
                return msg["return"]

def count_marker(path, marker):
    if not os.path.exists(path):
        return 0
    return open(path, "rb").read().count(marker.encode("latin-1"))

def wait_marker(path, marker, timeout=25, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.5)
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        if not wait_marker(serial, marker, timeout=25):
            raise SystemExit("never saw %s" % marker)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(0.4)
q.cmd("quit")
PY
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "session driver exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
}

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn files.elf'),ret,until:USER WRITE FILES READY,wait:400"

echo
echo "=== BOOT A — rename $NAME_C → $MOVE_C ==="
drive_session "$WORKDIR/bootA" "$KEYS" "plant-A" "$IMG_A"
SER_A="$WORKDIR/bootA/serial.txt"

echo
echo "=== ASSERT ==="
have() { ck; grep -qF -- "$1" "$SER_A" || { sed -n '/M1 END/,$p' "$SER_A" >&2; fail "missing: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$SER_A" && fail "must not contain: $1"; }

have "PROC SPAWN"
have "$(d move_src_line)"
have "$(d copy_line)"
have "$(d move_line)"
have "$(d ready_line)"
havenot "$(d move_none)"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_A" \
  || { sed -n '/M1 END/,$p' "$SER_A" >&2; fail "fault during boot A"; }
echo "ASSERT: pass  serial carried COPY and MOVE lines"

SHA_AFTER=$(shasum -a 256 "$IMG_A" | cut -d' ' -f1)
ck; [[ "$SHA_BEFORE" != "$SHA_AFTER" ]] \
  || fail "boot A left the volume unchanged"
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$IMG_A"
ck; [[ $FSCK2_STATUS -eq 0 ]] || fail "fsck_msdos rejected volume after boot A"
ck; GOT_COPY=$(python3 "$SCRIPT_DIR/make-image.py" --extract="$COPY_A" "$IMG_A") \
  || fail "FAT walk could not read copy dest $COPY_A"
ck; GOT_MOVE=$(python3 "$SCRIPT_DIR/make-image.py" --extract="$MOVE_C" "$IMG_A") \
  || fail "FAT walk could not read move dest $MOVE_C"
ck; GOT_SRC_A=$(python3 "$SCRIPT_DIR/make-image.py" --extract="$NAME_A" "$IMG_A") \
  || fail "FAT walk lost copy source $NAME_A"
ck; ! python3 "$SCRIPT_DIR/make-image.py" --extract="$NAME_C" "$IMG_A" >/dev/null 2>&1 \
  || fail "FAT walk still sees move source $NAME_C — second copy left behind"
ck; [[ "$GOT_COPY" == "$HEX_A" ]] || fail "copy dest wrong"
ck; [[ "$GOT_MOVE" == "$HEX_C" ]] || fail "move dest wrong"
ck; [[ "$GOT_SRC_A" == "$HEX_A" ]] || fail "copy source changed"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH2_OUT ATTACH2_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$IMG_A"
  ck; [[ $ATTACH2_STATUS -eq 0 ]] \
    || { echo "$ATTACH2_OUT" >&2; fail "hdiutil remount failed"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH2_OUT")"
  ck; [[ -f "$MOUNTPOINT/$MOVE_C" ]] || fail "msdos missing move dest"
  ck; [[ -f "$MOUNTPOINT/$NAME_A" ]] || fail "msdos lost copy source"
  ck; [[ ! -f "$MOUNTPOINT/$NAME_C" ]] \
    || fail "msdos still has move source $NAME_C"
  HOST_MOVE=$(xxd -p -u "$MOUNTPOINT/$MOVE_C" | tr -d '\n')
  ck; [[ "$HOST_MOVE" == "$HEX_C" ]] || fail "msdos move bytes wrong"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "CHECK: pass  msdos sees $MOVE_C; $NAME_C gone"
fi

require_assertions "$ASSERTIONS_REQUIRED"
echo "FILES-MV2: PASS — FILES.ELF renamed $NAME_C → $MOVE_C ($HEX_C); source gone; copy $NAME_A kept; ADR-0149"
