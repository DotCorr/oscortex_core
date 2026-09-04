#!/usr/bin/env bash
# Disk-image conformance for SYS_MKDIR / fatMkdir / subdirectory create.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
FILES_FM="$CORE_DIR/tests/conformance/files-fm"

fail() { echo "FILES-MKDIR: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FILES-MKDIR: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0
export PATH="/opt/dart-sdk-3.12.2/bin:/tmp/oscortex-elf-tools:${PATH:-/usr/bin:/bin}"

ASSERTIONS_REQUIRED=18

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-files-mkdir.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

LIVE_KERNEL="$CORE_DIR/build/kernel.elf"
if [[ -f "$LIVE_KERNEL" ]]; then
  LIVE_SHA=$(sha256sum "$LIVE_KERNEL" | awk '{print $1}')
else
  LIVE_SHA=""
fi

echo "=== BUILD (isolated OSGFX_SKIA=0) ==="
export BUILD_DIR="$WORKDIR/kbuild"
mkdir -p "$BUILD_DIR"
capture_sh BUILD_OUT BUILD_STATUS -- "BUILD_DIR='$BUILD_DIR' bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
KERNEL_ELF="$BUILD_DIR/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no isolated kernel.elf"
if [[ -n "$LIVE_SHA" ]]; then
  NOW_LIVE=$(sha256sum "$LIVE_KERNEL" | awk '{print $1}')
  ck; [[ "$NOW_LIVE" == "$LIVE_SHA" ]] || fail "live kernel.elf changed"
else
  ck; [[ ! -f "$LIVE_KERNEL" ]] || fail "live kernel appeared"
fi

ck; grep -q 'SYS_MKDIR 38' "$CORE_DIR/user/frame/osframe.h" \
  || fail "osframe.h missing SYS_MKDIR 38"
ck; grep -q 'fileSysMkdirNo = 38' "$CORE_DIR/kernel/file.dart" \
  || fail "file.dart missing fileSysMkdirNo"
ck; grep -q 'u64 fatMkdir()' "$CORE_DIR/kernel/fat.dart" \
  || fail "fat.dart missing fatMkdir"

CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2
  -Wall -Wextra -Werror
  -I"$CORE_DIR/user/frame"
)
clang "${CFLAGS[@]}" "$SCRIPT_DIR/probe.c" -o "$WORKDIR/probe.o" \
  || fail "clang could not compile probe.c"
x86_64-elf-ld -T "$FILES_FM/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$WORKDIR/files.elf" "$WORKDIR/probe.o" \
  || fail "ld could not link probe"
ck; [[ -s "$WORKDIR/files.elf" ]] || fail "no files.elf"

IMG="$WORKDIR/disk.img"
ck; python3 "$FILES_FM/make-image.py" "$IMG" "$WORKDIR/files.elf" --variant=empty \
  || fail "make-image failed"

PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
SERPORT=$(python3 "$PICKER")
SER="$WORKDIR/serial.txt"
: >"$SER"

qemu-system-x86_64 -kernel "$KERNEL_ELF" -m 256M -cpu qemu64 \
  -drive "file=$IMG,format=raw,if=ide,index=0,media=disk" \
  -display none \
  -chardev "socket,id=ser,host=127.0.0.1,port=${SERPORT},server=on,wait=off,logfile=${SER}" \
  -serial chardev:ser \
  -qmp "tcp:127.0.0.1:${QMP},server,nowait" \
  -no-reboot \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!
sleep 0.4

python3 - "$QMP" "$SER" <<'PY' || fail "session driver failed"
import json, os, socket, sys, time
port, serial = int(sys.argv[1]), sys.argv[2]

class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("qmp: %s" % last)

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

def wait_marker(path, marker, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path) and marker.encode("latin-1") in open(path, "rb").read():
            return True
        time.sleep(0.1)
    return False

def type_line(q, s):
    for ch in s:
        if ch == " ":
            data = "spc"
        elif ch == ".":
            data = "dot"
        else:
            data = ch
        q.cmd("send-key", keys=[{"type": "qcode", "data": data}])
        time.sleep(0.03)
    q.cmd("send-key", keys=[{"type": "qcode", "data": "ret"}])

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("no M1 END")
time.sleep(0.4)
type_line(q, "fb")
time.sleep(0.8)
type_line(q, "proc spawn files.elf")
if not wait_marker(serial, "MKDIR OK", timeout=20):
    raise SystemExit("no MKDIR OK")
time.sleep(0.4)
q.cmd("quit")
PY
wait "$QEMU_PID" || true

ck; grep -q "MKDIR OK" "$SER" || { tail -80 "$SER" >&2; fail "serial has no MKDIR OK"; }
ck; ! grep -q "MKDIR FAIL" "$SER" || fail "probe printed MKDIR FAIL"

ck; python3 - "$IMG" <<'PY' || fail "FAT walk did not see NEWDIR / IN.DAT"
import struct, sys
img = open(sys.argv[1], "rb").read()
bps = 512
spc = img[13]
reserved = struct.unpack_from("<H", img, 14)[0]
nfats = img[16]
fat_sec = struct.unpack_from("<H", img, 22)[0]
root_ent = struct.unpack_from("<H", img, 17)[0]
root_start = reserved + nfats * fat_sec
root = img[root_start * bps:root_start * bps + root_ent * 32]
found_dir = False
found_in = False
for i in range(0, len(root), 32):
    e = root[i:i+32]
    if not e or e[0] in (0x00, 0xE5):
        continue
    name = e[0:8].decode("ascii", "replace").rstrip()
    ext = e[8:11].decode("ascii", "replace").rstrip()
    attr = e[11]
    if name == "NEWDIR" and (attr & 0x10):
        found_dir = True
        first = struct.unpack_from("<H", e, 26)[0]
        data_start = root_start + (root_ent * 32) // bps
        lba = data_start + (first - 2) * spc
        sub = img[lba * bps:(lba + spc) * bps]
        for j in range(0, len(sub), 32):
            se = sub[j:j+32]
            if not se or se[0] in (0x00, 0xE5, 0x2E):
                continue
            sname = se[0:8].decode("ascii", "replace").rstrip()
            sext = se[8:11].decode("ascii", "replace").rstrip()
            if sname == "IN" and sext == "DAT":
                found_in = True
if not found_dir:
    raise SystemExit("NEWDIR missing or not ATTR_DIR")
if not found_in:
    raise SystemExit("IN.DAT missing inside NEWDIR")
print("WALK: NEWDIR ATTR_DIR and IN.DAT present")
PY

if command -v fsck.fat >/dev/null 2>&1; then
  capture FSCK_OUT FSCK_STATUS -- fsck.fat -n "$IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || fail "fsck.fat rejected the volume"
elif command -v fsck.msdos >/dev/null 2>&1; then
  capture FSCK_OUT FSCK_STATUS -- fsck.msdos -n "$IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || fail "fsck.msdos rejected the volume"
else
  ck; true
fi

if [[ -n "$LIVE_SHA" ]]; then
  END_LIVE=$(sha256sum "$LIVE_KERNEL" | awk '{print $1}')
  ck; [[ "$END_LIVE" == "$LIVE_SHA" ]] || fail "live kernel changed"
else
  ck; [[ ! -f "$LIVE_KERNEL" ]] || fail "created a live kernel.elf"
fi

require_assertions "$ASSERTIONS_REQUIRED"
echo "FILES-MKDIR: PASS — SYS_MKDIR created NEWDIR; IN.DAT landed inside it; host FAT walk agrees"
exit 0
