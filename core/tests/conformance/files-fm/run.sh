#!/usr/bin/env bash
# core/tests/conformance/files-fm/run.sh
#
# FILES — a FRAME client lists a FAT directory, cats a planted file,
# copies planted A → stem.CPY, and moves planted C → stem.MOV.
# docs/decisions/0100-a-file-manager-lists-the-root.md
# docs/decisions/0118-files-copies-and-moves-on-fat.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# FILES.ELF (osframe.h) is `proc spawn`ed. It opens `:ROOT` (existing
# open/read, no new syscall) and prints every listed 8.3 name the
# harness planted at test time, then open/reads that file's bytes.
# The first two listed .DAT names are copied and moved. Copy uses
# open / fdwrite (syscall 9). Move uses rename (syscall 32) so the
# source name leaves. Dest names are the source stem plus CPY or MOV.
# A second image prints its own name, bytes, and copy.
# A deleted GHOST.DAT is not listed; opening it is FILES MISS, not
# a plant. Empty dir lists only FILES.ELF. A raw OSCXPRG1 disk
# (no FAT) refuses :ROOT. Host fsck_msdos and a FAT walk see the
# dest bytes after boot A; the move source is gone.
#
# Anti-vacuity: plant name/bytes are not in files.c, file.dart, or
# fat.dart. Missing file ≠ plant. fatDiskRead still picks NVMe or ATA.
# 11 stays fdwait. No help line. Icons closed (ADR-0154 / files-ico/).
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
FILES_C="$CORE_DIR/user/frame/files.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "FILES-FM: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FILES-FM: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

# FILES.ELF paints its own pixels and talks FAT. The guest CRT heap is
# 12MiB and blows vmFineBytes (4MiB), so vmInit refuses and `proc spawn`
# prints PROC REFUSED 01. Omit Skia / CRT / FFmpeg for this boot.
export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

# Floor: ADR-0118 was 152; ADR-0149 flips move-source-gone checks; ADR-0192
# adds the four row-caption checks below. The floor was pinned at 154 against a
# run that reaches 152, so it was FAILING before ADR-0192 touched this harness
# -- re-derived from a run, which is how _lib/harness.sh says to update it.
ASSERTIONS_REQUIRED=161

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-files-fm.XXXXXX")" \
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
FAT_SRC="$CORE_DIR/kernel/fat.dart"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$FILES_C" ]] || setup_error "no files.c at $FILES_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"
ck; [[ -f "$FILE_SRC" ]] || setup_error "no file.dart"
ck; [[ -f "$FAT_SRC" ]] || setup_error "no fat.dart"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
# Snapshot: a sibling may relink kernel.elf (Skia CRT is 12MiB and
# blows vmFineBytes). Boot the image this harness just built.
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" \
  || fail "could not snapshot kernel.elf"
KERNEL_ELF="$WORKDIR/kernel.elf"
KERN_END=$(x86_64-elf-nm "$KERNEL_ELF" | awk '$3=="__kernel_end"{print $1; exit}')
ck; [[ -n "$KERN_END" ]] || fail "snapshot kernel has no __kernel_end"
ck; [[ $((16#$KERN_END)) -le 4194304 ]] \
  || fail "snapshot kernel __kernel_end is 0x$KERN_END, above vmFineBytes 4MiB"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$FILES_C" \
  || fail "files.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$FILES_C" \
  || fail "files.c copies SYS_* by hand — include osframe.h"
ck; grep -q ':ROOT' "$FILES_C" \
  || fail "files.c does not open :ROOT"
ck; grep -q 'SYS_FDWRITE' "$FILES_C" \
  || fail "files.c does not fdwrite — copy/move are missing"
ck; grep -q 'MODE_WRITE 1UL' "$FILES_C" \
  || fail "files.c has no O_WRITE = 1"
ck; grep -q '"CPY"' "$FILES_C" \
  || fail "files.c has no CPY dest extension"
ck; grep -q '"MOV"' "$FILES_C" \
  || fail "files.c has no MOV dest extension"
ck; grep -q 'SYS_RENAME' "$FILES_C" \
  || fail "files.c does not rename — move still copies"
ck; grep -q 'SYS_RENAME 32' "$FRAME_H" \
  || fail "osframe.h does not name SYS_RENAME 32"
ck; grep -q 'fileIsRootName' "$FILE_SRC" \
  || fail "file.dart has no fileIsRootName — :ROOT is missing"
ck; grep -q 'const int fileFdRoot = 4;' "$FILE_SRC" \
  || fail "file.dart has no fileFdRoot = 4"
ck; grep -q 'fileIsRootName(buf, len)' "$FILE_SRC" \
  || fail "fileSysOpen does not call fileIsRootName"
ck; ! grep -q 'fileIsRootName\|:ROOT\|fileFdRoot' "$FAT_SRC" \
  || fail "fat.dart names :ROOT — the branch must stay in fileSysOpen"
ck; ! grep -q 'fileIsRootName' "$CORE_DIR/kernel/fat.dart" \
  || fail "fatLookup grew a :ROOT branch"
ck; grep -q 'u64 fatDiskRead(' "$FAT_SRC" \
  || fail "fatDiskRead is gone"
ck; grep -q 'nvmeIoRead' "$FAT_SRC" \
  || fail "fat.dart lost nvmeIoRead — nvm5 would fail"
ck; grep -q 'ataReadInto' "$FAT_SRC" \
  || fail "fat.dart lost ataReadInto — m14 would fail"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -qE 'fileFdRoot|FILES\.ELF|:ROOT' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "the registry grew a FILES row — no new syscall"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — no help line"
ck; ! grep -qE 'FILES\.ELF|files\.c|:ROOT' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a FILES name — no new help"
ck; grep -q 'const int fileStoreBytes = 2560;' "$FILE_SRC" \
  || fail "fileStoreBytes is no longer 2560"
FILE_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="fileStore"{print $3+0; exit}')
ck; [[ "$FILE_STORE" -eq 2560 ]] || fail "fileStore is ${FILE_STORE:-missing} bytes, expected 2560"
EV_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="wmeventStore"{print $3+0; exit}')
EV_OFF=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="wmeventStore"{print $2; exit}')
ck; [[ "$EV_SIZE" -eq 384 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 384"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — FILES stole D7's slot"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
ck; grep -q 'WMEVENT_TYPE_SCROLL' "$FRAME_H" \
  || fail "osframe.h has no WMEVENT_TYPE_SCROLL"
ck; grep -q 'FILES SCROLL' "$FILES_C" \
  || fail "files.c does not print FILES SCROLL"
ck; grep -q 'scroll_off' "$FILES_C" \
  || fail "files.c has no scroll_off"
ck; grep -q 'wmeventTypeScroll' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "wmevent.dart has no scroll type"
ck; grep -q 'wmeventEnqueueScroll' "$CORE_DIR/kernel/mouse.dart" \
  || fail "mouse.dart does not enqueue scroll"
echo "STRUCTURAL: pass  :ROOT in fileSysOpen, fdwrite copy, rename move, no fatLookup branch, no help, fileStore 2560, wmeventStore last, wheel scroll"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/files.elf" ]] || fail "no files.elf"

echo
echo "=== PLANTS ==="
python3 - "$WORKDIR" "$FILES_C" "$FILE_SRC" "$FAT_SRC" <<'PY' || fail "could not derive three plants"
import os, random, string, sys
wd, files_c, file_src, fat_src = sys.argv[1:]
src = open(files_c, encoding="utf-8").read() + open(file_src, encoding="utf-8").read() + open(fat_src, encoding="utf-8").read()
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
        return name, hx

a, ha = one("plantA")
b, hb = one("plantB")
c, hc = one("plantC")
if len({a, b, c}) != 3 or len({ha, hb, hc}) != 3:
    sys.exit("plants collided")
print("DERIVE: plant A %s %s" % (a, ha))
print("DERIVE: plant B %s %s" % (b, hb))
print("DERIVE: plant C %s %s" % (c, hc))
PY
NAME_A=$(tr -d '\n' < "$WORKDIR/plantA.name")
HEX_A=$(tr -d '\n' < "$WORKDIR/plantA.hex")
NAME_B=$(tr -d '\n' < "$WORKDIR/plantB.name")
HEX_B=$(tr -d '\n' < "$WORKDIR/plantB.hex")
NAME_C=$(tr -d '\n' < "$WORKDIR/plantC.name")
HEX_C=$(tr -d '\n' < "$WORKDIR/plantC.hex")
COPY_A="${NAME_A%.DAT}.CPY"
MOVE_C="${NAME_C%.DAT}.MOV"
ck; [[ -n "$NAME_A" && -n "$NAME_B" && -n "$NAME_C" ]] || fail "no plant names"
ck; [[ "$NAME_A" != "$NAME_B" && "$NAME_A" != "$NAME_C" && "$NAME_B" != "$NAME_C" ]] \
  || fail "plant names collided"
ck; [[ "$HEX_A" != "$HEX_B" && "$HEX_A" != "$HEX_C" && "$HEX_B" != "$HEX_C" ]] \
  || fail "plant bytes collided"
ck; ! grep -Fqi "$HEX_A" "$FILES_C" \
  || fail "plant A appears in files.c"
ck; ! grep -Fqi "$HEX_B" "$FILES_C" \
  || fail "plant B appears in files.c"
ck; ! grep -Fqi "$HEX_C" "$FILES_C" \
  || fail "plant C appears in files.c"
ck; ! grep -Fqi "$HEX_A" "$FILE_SRC" \
  || fail "plant A appears in file.dart"
ck; ! grep -Fqi "$NAME_A" "$FILES_C" \
  || fail "plant name A is baked into files.c"
ck; ! grep -Fqi "$NAME_C" "$FILES_C" \
  || fail "plant name C is baked into files.c"
ck; ! grep -Fqi "$COPY_A" "$FILES_C" \
  || fail "copy dest $COPY_A is baked into files.c"
ck; ! grep -Fqi "$MOVE_C" "$FILES_C" \
  || fail "move dest $MOVE_C is baked into files.c"

IMG_A="$WORKDIR/fullA.img"
IMG_B="$WORKDIR/fullB.img"
IMG_E="$WORKDIR/empty.img"
IMG_R="$WORKDIR/raw.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_A" "$WORKDIR/files.elf" \
  --variant=full --plant-name="$NAME_A" --plant-hex="$HEX_A" \
  --plant2-name="$NAME_C" --plant2-hex="$HEX_C" \
  || fail "make-image A failed"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_B" "$WORKDIR/files.elf" \
  --variant=full --plant-name="$NAME_B" --plant-hex="$HEX_B" \
  || fail "make-image B failed"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_E" "$WORKDIR/files.elf" \
  --variant=empty \
  || fail "make-image empty failed"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_R" "$WORKDIR/files.elf" \
  --variant=raw \
  || fail "make-image raw failed"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$IMG_A"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected image A"; }
echo "IMAGE: pass  fsck_msdos accepts the planted volume"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$IMG_A"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount image A"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/FILES.ELF" ]] || fail "mounted volume has no FILES.ELF"
  ck; [[ -f "$MOUNTPOINT/$NAME_A" ]] || fail "mounted volume has no $NAME_A"
  ck; [[ -f "$MOUNTPOINT/$NAME_C" ]] || fail "mounted volume has no $NAME_C"
  ck; [[ ! -f "$MOUNTPOINT/GHOST.DAT" ]] || fail "deleted GHOST.DAT is visible"
  ck; [[ ! -f "$MOUNTPOINT/$COPY_A" ]] || fail "copy dest $COPY_A is already on the as-built volume"
  ck; [[ ! -f "$MOUNTPOINT/$MOVE_C" ]] || fail "move dest $MOVE_C is already on the as-built volume"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver sees FILES.ELF, $NAME_A, $NAME_C and no dests"
fi

DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$NAME_A" "$HEX_A" "$NAME_B" "$HEX_B" \
  "$NAME_C" "$HEX_C" \
  > "$DERIVED" || fail "derive.py failed"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
ck; [[ "$(d plant_name)" == "$NAME_A" ]] || fail "derive lost plant A"

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
                print("FILES-FM: QEMU", hello.get("QMP", {}).get("version", {}))
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

KEYS_RAW="$(typekeys 'fb'),ret,wait:1500"
KEYS_RAW="$KEYS_RAW,$(typekeys 'wm on'),ret,wait:2500"
KEYS_RAW="$KEYS_RAW,$(typekeys 'proc spawn 20'),ret,until:USER WRITE FILES READY,wait:400"

echo
echo "=== BOOT A — planted $NAME_A copy and $NAME_C move ==="
drive_session "$WORKDIR/bootA" "$KEYS" "plant-A" "$IMG_A"
echo
echo "=== BOOT B — planted $NAME_B ==="
drive_session "$WORKDIR/bootB" "$KEYS" "plant-B" "$IMG_B"
echo
echo "=== BOOT empty ==="
drive_session "$WORKDIR/empty" "$KEYS" "empty" "$IMG_E"
echo
echo "=== BOOT raw (no FAT) ==="
drive_session "$WORKDIR/raw" "$KEYS_RAW" "raw" "$IMG_R"

SER_A="$WORKDIR/bootA/serial.txt"
SER_B="$WORKDIR/bootB/serial.txt"
SER_E="$WORKDIR/empty/serial.txt"
SER_R="$WORKDIR/raw/serial.txt"

echo
echo "=== ASSERT ==="
have() { ck; grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the $3 transcript does not contain: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$2" && fail "the $3 transcript contains what it must not: $1"; }

have "PROC SPAWN" "$SER_A" "A"
have "$(d self_line)" "$SER_A" "A"
have "$(d name_line)" "$SER_A" "A"
have "$(d move_src_line)" "$SER_A" "A"
have "$(d names_line)" "$SER_A" "A"
have "$(d cat_line)" "$SER_A" "A"
have "$(d copy_line)" "$SER_A" "A"
have "$(d move_line)" "$SER_A" "A"
have "$(d miss_line)" "$SER_A" "A"
have "$(d list_line)" "$SER_A" "A"
have "$(d ready_line)" "$SER_A" "A"
havenot "FILES NAME GHOST.DAT" "$SER_A" "A"
havenot "FILES NAME OSCORTEX" "$SER_A" "A"
havenot "$(d other_name_line)" "$SER_A" "A"
havenot "$(d other_cat)" "$SER_A" "A"
havenot "$(d other_copy_line)" "$SER_A" "A"
havenot "$(d copy_none)" "$SER_A" "A"
havenot "$(d move_none)" "$SER_A" "A"
# ---------------------------------------------------------------------------
# THE ROW CAPTIONS ARE THE OS'S OUTLINES, NOT A PRIVATE 8x16 CELL (ADR-0192).
#
# This boot is deliberately the OSGFX_SKIA=0 anti-vacuity link: there is no
# rasteriser in the image AT ALL, which is why its session chrome is blank too.
# So the advance FILES reports must be 0 while the cell width it prints beside
# it must not be -- `8 * n` would mean FILES had kept the bitmap cell, and any
# other non-zero number would mean it had found a second painter of its own.
# The non-zero case is de-desk's and de-session's to assert, on the image that
# has Skia in it.
# ---------------------------------------------------------------------------
have "FILES ROW OUTLINE ADV" "$SER_A" "A"
ROW_LINE=$(grep -o 'FILES ROW OUTLINE ADV [0-9]* CELL [0-9]*' "$SER_A" | tail -1)
ck; [[ -n "$ROW_LINE" ]] || fail "no FILES ROW OUTLINE line in boot A"
ck; [[ "$(printf '%s' "$ROW_LINE" | awk '{print $5}')" == "0" ]] \
  || fail "FILES reported a non-zero advance on a link with no rasteriser: $ROW_LINE"
ck; [[ "$(printf '%s' "$ROW_LINE" | awk '{print $7}')" -gt 0 ]] \
  || fail "FILES did not print the cell width it is being compared against: $ROW_LINE"

ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_A" \
  || { sed -n '/M1 END/,$p' "$SER_A" >&2; fail "something faulted during boot A"; }
echo "ASSERT: pass  image A listed $NAME_A / $NAME_C, catted $NAME_A, copied to $COPY_A, moved to $MOVE_C"

have "PROC SPAWN" "$SER_B" "B"
have "$(d other_name_line)" "$SER_B" "B"
have "$(d other_cat)" "$SER_B" "B"
have "$(d other_copy_line)" "$SER_B" "B"
have "$(d move_none)" "$SER_B" "B"
havenot "$(d name_line)" "$SER_B" "B"
havenot "$(d cat_line)" "$SER_B" "B"
havenot "$(d copy_line)" "$SER_B" "B"
havenot "$(d move_line)" "$SER_B" "B"
echo "ASSERT: pass  image B listed $NAME_B, copied its own plant, and did not invent A's plant"

have "$(d self_line)" "$SER_E" "empty"
have "$(d empty_names)" "$SER_E" "empty"
have "$(d cat_none)" "$SER_E" "empty"
have "$(d copy_none)" "$SER_E" "empty"
have "$(d move_none)" "$SER_E" "empty"
havenot "$(d name_line)" "$SER_E" "empty"
havenot "$(d other_name_line)" "$SER_E" "empty"
havenot "$(d cat_line)" "$SER_E" "empty"
havenot "$(d other_cat)" "$SER_E" "empty"
havenot "$(d copy_line)" "$SER_E" "empty"
havenot "$(d move_line)" "$SER_E" "empty"
echo "ASSERT: pass  empty dir listed only FILES.ELF and copied nothing"

have "$(d open_refused)" "$SER_R" "raw"
have "$(d ready_line)" "$SER_R" "raw"
havenot "$(d name_line)" "$SER_R" "raw"
havenot "$(d other_name_line)" "$SER_R" "raw"
havenot "$(d cat_line)" "$SER_R" "raw"
havenot "$(d copy_line)" "$SER_R" "raw"
havenot "$(d move_line)" "$SER_R" "raw"
havenot "FILES NAME FILES.ELF" "$SER_R" "raw"
echo "ASSERT: pass  no-FAT disk refused :ROOT"

SHA_AFTER=$(shasum -a 256 "$IMG_A" | cut -d' ' -f1)
ck; [[ "$SHA_BEFORE" != "$SHA_AFTER" ]] \
  || fail "boot A left the volume unchanged — copy/move wrote nothing"
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$IMG_A"
ck; [[ $FSCK2_STATUS -eq 0 ]] || fail "fsck_msdos rejected the volume after boot A"
ck; GOT_COPY=$(python3 "$SCRIPT_DIR/make-image.py" --extract="$COPY_A" "$IMG_A") \
  || fail "FAT walk could not read copy dest $COPY_A"
ck; GOT_MOVE=$(python3 "$SCRIPT_DIR/make-image.py" --extract="$MOVE_C" "$IMG_A") \
  || fail "FAT walk could not read move dest $MOVE_C"
ck; GOT_SRC_A=$(python3 "$SCRIPT_DIR/make-image.py" --extract="$NAME_A" "$IMG_A") \
  || fail "FAT walk lost copy source $NAME_A"
ck; ! python3 "$SCRIPT_DIR/make-image.py" --extract="$NAME_C" "$IMG_A" >/dev/null 2>&1 \
  || fail "FAT walk still sees move source $NAME_C — rename did not remove it"
ck; [[ "$GOT_COPY" == "$HEX_A" ]] \
  || fail "copy dest $COPY_A is $GOT_COPY, expected $HEX_A"
ck; [[ "$GOT_MOVE" == "$HEX_C" ]] \
  || fail "move dest $MOVE_C is $GOT_MOVE, expected $HEX_C"
ck; [[ "$GOT_SRC_A" == "$HEX_A" ]] \
  || fail "copy source $NAME_A changed to $GOT_SRC_A"
ck; [[ "$COPY_A" != "$NAME_A" ]] || fail "copy dest equals source"
ck; [[ "$MOVE_C" != "$NAME_C" ]] || fail "move dest equals source"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH2_OUT ATTACH2_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$IMG_A"
  ck; [[ $ATTACH2_STATUS -eq 0 ]] \
    || { echo "$ATTACH2_OUT" >&2; fail "hdiutil could not remount image A after copy/move"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH2_OUT")"
  ck; [[ -f "$MOUNTPOINT/$COPY_A" ]] || fail "mounted volume has no copy dest $COPY_A"
  ck; [[ -f "$MOUNTPOINT/$MOVE_C" ]] || fail "mounted volume has no move dest $MOVE_C"
  ck; [[ -f "$MOUNTPOINT/$NAME_A" ]] || fail "mounted volume lost copy source $NAME_A"
  ck; [[ ! -f "$MOUNTPOINT/$NAME_C" ]] \
    || fail "mounted volume still has move source $NAME_C"
  HOST_COPY=$(xxd -p -u "$MOUNTPOINT/$COPY_A" | tr -d '\n')
  HOST_MOVE=$(xxd -p -u "$MOUNTPOINT/$MOVE_C" | tr -d '\n')
  ck; [[ "$HOST_COPY" == "$HEX_A" ]] \
    || fail "msdos driver read $COPY_A as $HOST_COPY, expected $HEX_A"
  ck; [[ "$HOST_MOVE" == "$HEX_C" ]] \
    || fail "msdos driver read $MOVE_C as $HOST_MOVE, expected $HEX_C"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "CHECK: pass  macOS msdos sees $COPY_A=$HEX_A and $MOVE_C=$HEX_C; $NAME_C gone"
fi
echo "CHECK: pass  volume A mutated; dest bytes equal the plants; move source gone; fsck_msdos clean"

require_assertions "$ASSERTIONS_REQUIRED"
echo "FILES-FM: PASS — FILES.ELF listed planted $NAME_A and $NAME_C, catted $HEX_A, copied to $COPY_A, renamed $NAME_C to $MOVE_C ($HEX_C, source gone); image B printed its own plant and copy; empty dir had no plant; raw OSCXPRG1 refused :ROOT; GHOST.DAT was a miss; rename 32 consumed; icons ADR-0154"
exit 0
