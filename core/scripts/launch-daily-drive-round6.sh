#!/usr/bin/env bash
# Launch the Round 6 daily-drive QEMU: UEFI GOP 1280×720 + virtio-tablet.
# Leaves it running. Usage: launch-daily-drive-round6.sh
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$CORE_DIR/build/daily-drive-r6"
mkdir -p "$RUN"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
SERPORT=$(python3 "$PICKER")
DISK="$RUN/disk.img"
ISO="$RUN/uefi.iso"
KERNEL_UEFI="$CORE_DIR/build/kernel-uefi.elf"
if [[ ! -f "$KERNEL_UEFI" ]]; then
  echo "launch-daily-drive-round6: missing $KERNEL_UEFI (build-kernel OSGFX_SKIA=1)" >&2
  exit 2
fi
if [[ ! -f "$DISK" ]]; then
  bash "$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh" "$RUN"
fi
if [[ ! -f "$ISO" ]]; then
  if ! eval "$(bash "$CORE_DIR/scripts/find-limine.sh")"; then
    echo "launch-daily-drive-round6: limine not found" >&2
    exit 2
  fi
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
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_SRC="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
[[ -f "$OVMF_CODE" ]] || { echo "no OVMF CODE" >&2; exit 2; }
[[ -f "$OVMF_VARS_SRC" ]] || { echo "no OVMF VARS" >&2; exit 2; }
cp "$OVMF_VARS_SRC" "$RUN/OVMF_VARS.fd"
: >"$RUN/serial.txt"
echo "$QMP" >"$RUN/qmp.port"
echo "$SERPORT" >"$RUN/serial.port"
# Kill only a same-named leftover. Do not pkill a broader daily-drive pattern
# from a command line that contains that pattern.
if [[ -f "$RUN/qemu.pid" ]]; then
  old=$(cat "$RUN/qemu.pid" || true)
  if [[ -n "${old:-}" ]] && kill -0 "$old" 2>/dev/null; then
    if ps -p "$old" -o args= | grep -q 'oscortex-daily-drive-round6'; then
      kill "$old" 2>/dev/null || true
      sleep 0.4
    fi
  fi
fi
nohup qemu-system-x86_64 \
  -name oscortex-daily-drive-round6 \
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
