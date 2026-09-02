#!/usr/bin/env bash
# core/tests/conformance/files-unl/run.sh
#
# APP4 / ADR-0147 — FAT unlink and rename.
#
# PROG.ELF creates KILL.DAT, lists it via :ROOT, unlinks it (gone from
# the list), unlinks a missing name (FILE_ENOTFOUND), and renames
# A.TMP over A.TXT. Host fsck_msdos must accept the volume afterwards.
# Syscall 11 stays fdwait. No help line. No plant of KILL.DAT.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "FILES-UNL: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FILES-UNL: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

# Floor pinned on the first green run.
ASSERTIONS_REQUIRED=46

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-files-unl.XXXXXX")" \
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
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
FILE_SRC="$CORE_DIR/kernel/file.dart"
FAT_SRC="$CORE_DIR/kernel/fat.dart"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$FILE_SRC" ]] || setup_error "no file.dart"
ck; [[ -f "$FAT_SRC" ]] || setup_error "no fat.dart"

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
ck; grep -q 'const int fileSysUnlinkNo = 31;' "$FILE_SRC" \
  || fail "fileSysUnlinkNo is not 31"
ck; grep -q 'const int fileSysRenameNo = 32;' "$FILE_SRC" \
  || fail "fileSysRenameNo is not 32"
ck; grep -q 'u64 fatUnlink(' "$FAT_SRC" || fail "fat.dart has no fatUnlink"
ck; grep -q 'u64 fatRenameTo(' "$FAT_SRC" || fail "fat.dart has no fatRenameTo"
ck; grep -q 'u64 fatDirFind(' "$FAT_SRC" || fail "fat.dart has no fatDirFind"
ck; grep -q '#define SYS_UNLINK 31' "$LIBC_DIR/oslibc.h" \
  || fail "oslibc.h SYS_UNLINK is not 31"
ck; grep -q '#define SYS_RENAME 32' "$LIBC_DIR/oslibc.h" \
  || fail "oslibc.h SYS_RENAME is not 32"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; grep -q '| 31 | `unlink`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry has no unlink row"
ck; grep -q '| 32 | `rename`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry has no rename row"
ck; grep -q '| 30 | `futex`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry lost futex 30 — collision"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — no help line"
ck; ! grep -qiE 'unlink|rename' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew an unlink/rename help string"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
ck; grep -q 'userFrameRcx = 96' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart has no userFrameRcx for rename's fourth arg"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" \
  || fail "verify-syscall-registry.sh failed"
echo "STRUCTURAL: pass  unlink=31 rename=32 fdwait=11 help=2511"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/files-unl.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/prog.elf" \
  || fail "make-image.py could not write the volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the as-built image"; }
echo "IMAGE: pass  fsck_msdos accepts the volume"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

echo
echo "=== BOOT — run prog.elf ==="
KEYS="$(typekeys 'run prog.elf'),ret,wait:30000"
mkdir -p "$WORKDIR/boot"
SER="$WORKDIR/boot/serial.txt"
: >"$SER"
ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" \
  >"$WORKDIR/boot/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$WORKDIR/boot/shot.png" --screen-text "$WORKDIR/boot/screen.txt" \
  --keys "$KEYS"
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  echo "--- serial (tail) ---" >&2
  tail -80 "$SER" >&2
  fail "qmp-drive.py exited $drive_status"
fi
ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  fail "qemu exited $qemu_status"
fi
ck; [[ -s "$SER" ]] || fail "boot captured no serial"

echo
echo "=== ASSERT ==="
python3 - "$SER" <<'PY' || fail "serial does not satisfy unlink/rename"
import sys
ser = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []

def need(s):
    if s not in ser:
        fails.append("missing %r" % s)

need("USER WRITE UNL MAKE 0")
need("USER WRITE UNL BEFORE 1")
need("USER WRITE UNL OK 0")
need("USER WRITE UNL AFTER 0")
need("USER WRITE UNL MISS fff9")
need("USER WRITE UNL REN 0")
need("USER WRITE UNL TMPGONE 0")
need("USER WRITE UNL TXTKEEP 1")
need("USER WRITE UNL PASS")
if "UNL BADHASH" in ser:
    fails.append("hash mismatch on rename-over contents")
if "UNL BEFORE 0" in ser:
    fails.append("KILL.DAT was not listed before unlink")
if "UNL AFTER 1" in ser:
    fails.append("KILL.DAT still listed after unlink")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-60:]), file=sys.stderr)
    raise SystemExit(1)
print("ASSERT: pass  unlink listed→gone, miss=f9, rename-over, UNL PASS")
PY

echo
echo "=== HOST VOLUME ==="
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK2_STATUS -eq 0 ]] \
  || { echo "$FSCK2_OUT" >&2; fail "fsck_msdos rejected the post-boot volume"; }
if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount post-boot image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ ! -f "$MOUNTPOINT/KILL.DAT" ]] \
    || fail "macOS still sees KILL.DAT after unlink"
  ck; [[ ! -f "$MOUNTPOINT/A.TMP" ]] \
    || fail "macOS still sees A.TMP after rename-over"
  ck; [[ -f "$MOUNTPOINT/A.TXT" ]] \
    || fail "macOS does not see A.TXT after rename-over"
  ck; [[ "$(wc -c <"$MOUNTPOINT/A.TXT" | tr -d ' ')" -eq 40 ]] \
    || fail "A.TXT is not 40 bytes on the host"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "HOST: pass  fsck clean, KILL gone, A.TMP gone, A.TXT 40 bytes"
fi

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "FILES-UNL: PASS — unlink+rename (ADR-0147), miss fails, list drops name, fsck clean"
exit 0
