#!/usr/bin/env bash
# Launch the Round 4 daily-drive QEMU. Leaves it running.
# Usage: launch-daily-drive-round4.sh [800x600|1280x720]
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-800x600}"
RUN="$CORE_DIR/build/daily-drive-r4"
if [[ "$MODE" == "1280x720" ]]; then
  RUN="$CORE_DIR/build/daily-drive-r4-hd"
fi
mkdir -p "$RUN"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
SERPORT=$(python3 "$PICKER")
KERNEL="$CORE_DIR/build/kernel.elf"
DISK="$RUN/disk.img"
if [[ ! -f "$DISK" ]]; then
  bash "$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh" "$RUN"
fi
: >"$RUN/serial.txt"
echo "$QMP" >"$RUN/qmp.port"
echo "$SERPORT" >"$RUN/serial.port"
# Kill only a same-named leftover, never sibling QEMUs.
pkill -f 'oscortex-daily-drive-round4' 2>/dev/null || true
sleep 0.3
NAME="oscortex-daily-drive-round4"
DISPLAY_ARG="-display gtk,zoom-to-fit=on"
if [[ "$MODE" == "1280x720" ]]; then
  NAME="oscortex-daily-drive-round4-hd"
  # GOP via std VGA is still 800 on Bochs. UEFI ISO is the 1280 path.
  echo "1280 launch expects a prebuilt UEFI ISO at $RUN/view-uefi.iso" >&2
fi
nohup qemu-system-x86_64 \
  -name "$NAME" \
  -machine q35,accel=tcg -cpu qemu64 -m 256 \
  -kernel "$KERNEL" \
  -drive "file=$DISK,format=raw,if=ide,index=0,media=disk" \
  -device virtio-tablet-pci \
  $DISPLAY_ARG \
  -chardev "socket,id=ser,host=127.0.0.1,port=${SERPORT},server=on,wait=off,logfile=${RUN}/serial.txt" \
  -serial chardev:ser \
  -qmp "tcp:127.0.0.1:${QMP},server,nowait" \
  -no-reboot \
  >"$RUN/qemu.log" 2>&1 </dev/null &
echo $! >"$RUN/qemu.pid"
echo "qmp=$QMP serial_sock=$SERPORT pid=$! disk=$DISK"
