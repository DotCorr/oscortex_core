#!/usr/bin/env bash
# Launch Round 25 daily-drive: exact-tip core/build UEFI by default.
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
RUN="$CORE_DIR/build/daily-drive-r25"
mkdir -p "$RUN"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
SERPORT=$(python3 "$PICKER")
META="$CORE_DIR/build/BUILD.json"
HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
# Inherited KERNEL_UEFI from an older daily-drive must not silently
# boot a stale ELF. Exact-tip BUILD.json wins unless FORCE_KERNEL_UEFI=1.
KERNEL_UEFI_IN="${KERNEL_UEFI:-}"
KERNEL_UEFI=""
if [[ "${FORCE_KERNEL_UEFI:-0}" == "1" && -n "$KERNEL_UEFI_IN" && -f "$KERNEL_UEFI_IN" ]]; then
  KERNEL_UEFI="$KERNEL_UEFI_IN"
elif [[ -f "$CORE_DIR/build/kernel-uefi.elf" && -f "$META" ]]; then
  meta_git="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("git_sha",""))' "$META")"
  if [[ "$meta_git" == "$HEAD" ]]; then
    KERNEL_UEFI="$CORE_DIR/build/kernel-uefi.elf"
  fi
fi
if [[ -z "$KERNEL_UEFI" && -n "$KERNEL_UEFI_IN" && -f "$KERNEL_UEFI_IN" ]]; then
  KERNEL_UEFI="$KERNEL_UEFI_IN"
fi
if [[ -z "$KERNEL_UEFI" || ! -f "$KERNEL_UEFI" ]]; then
  echo "launch-daily-drive-round25: promoting exact-tip core/build" >&2
  bash "$CORE_DIR/scripts/promote-core-build.sh"
  KERNEL_UEFI="$CORE_DIR/build/kernel-uefi.elf"
fi
[[ -f "$KERNEL_UEFI" ]] || { echo "launch-daily-drive-round25: missing $KERNEL_UEFI" >&2; exit 2; }
DISK="$RUN/disk.img"
ISO="$RUN/uefi.iso"
if [[ ! -f "$DISK" || "${FORCE_DISK:-0}" == "1" ]]; then
  if [[ -f "$CORE_DIR/build/disk.img" ]]; then
    cp "$CORE_DIR/build/disk.img" "$DISK"
  else
    bash "$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh" "$RUN"
  fi
fi
need_iso=0
if [[ "${FORCE_ISO:-0}" == "1" ]]; then
  need_iso=1
elif [[ ! -f "$ISO" ]]; then
  need_iso=1
elif [[ "$KERNEL_UEFI" -nt "$ISO" ]]; then
  need_iso=1
fi
GIT_SHA="${DRIVE_GIT_SHA:-$HEAD}"
KERNEL_SHA="$(sha256sum "$KERNEL_UEFI" | awk '{print $1}')"
echo "$GIT_SHA" >"$RUN/booted.git"
echo "$KERNEL_SHA" >"$RUN/kernel.sha256"
if [[ "$need_iso" == "1" ]]; then
  eval "$(bash "$CORE_DIR/scripts/find-limine.sh")"
  export LIMINE LIMINE_DATADIR LIMINE_MAJOR
  cat >"$RUN/limine.conf" <<EOF
timeout: 0

/oscortex
    protocol: multiboot
    path: boot():/boot/kernel.elf
    KERNEL_PATH: boot():/boot/kernel.elf
    resolution: 1280x720x32
EOF
  LIMINE_CONF="$RUN/limine.conf" \
    bash "$CORE_DIR/scripts/build-uefi-image.sh" "$KERNEL_UEFI" "$ISO"
fi
ISO_SHA="$(sha256sum "$ISO" | awk '{print $1}')"
echo "$ISO_SHA" >"$RUN/uefi.sha256"
echo "git=$GIT_SHA kernel_sha256=$KERNEL_SHA iso_sha256=$ISO_SHA"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_SRC="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
[[ -f "$OVMF_CODE" ]] || { echo "no OVMF CODE" >&2; exit 2; }
[[ -f "$OVMF_VARS_SRC" ]] || { echo "no OVMF VARS" >&2; exit 2; }
cp "$OVMF_VARS_SRC" "$RUN/OVMF_VARS.fd"
: >"$RUN/serial.txt"
echo "$QMP" >"$RUN/qmp.port"
echo "$SERPORT" >"$RUN/serial.port"
if [[ -f "$RUN/qemu.pid" ]]; then
  old=$(cat "$RUN/qemu.pid" || true)
  if [[ -n "${old:-}" ]] && kill -0 "$old" 2>/dev/null; then
    if ps -p "$old" -o args= | grep -q 'oscortex-daily-drive-round25'; then
      kill "$old" 2>/dev/null || true
      sleep 0.4
    fi
  fi
fi
nohup qemu-system-x86_64 \
  -name oscortex-daily-drive-round25 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$RUN/OVMF_VARS.fd" \
  -cdrom "$ISO" \
  -m 512M -cpu qemu64 \
  -chardev "socket,id=ser,host=127.0.0.1,port=${SERPORT},server=on,wait=off,logfile=${RUN}/serial.txt" \
  -serial chardev:ser \
  -display gtk,zoom-to-fit=on \
  -device virtio-tablet-pci \
  -drive "file=$DISK,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:${QMP},server,nowait" \
  -no-reboot \
  >"$RUN/qemu.log" 2>&1 </dev/null &
echo $! >"$RUN/qemu.pid"
echo "qmp=$QMP serial_sock=$SERPORT pid=$! iso=$ISO"
