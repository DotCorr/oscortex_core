#!/usr/bin/env bash
# Launch the Round 5 daily-drive QEMU. Leaves it running.
# Usage: launch-daily-drive-round5.sh [800x600|1280x720]
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-800x600}"
RUN="$CORE_DIR/build/daily-drive-r5"
if [[ "$MODE" == "1280x720" ]]; then
  RUN="$CORE_DIR/build/daily-drive-r5-hd"
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
# Kill only a same-named leftover and the obsolete Round 4 sit-in.
pkill -f 'oscortex-daily-drive-round5' 2>/dev/null || true
pkill -f 'oscortex-daily-drive-round4' 2>/dev/null || true
sleep 0.3
NAME="oscortex-daily-drive-round5"
DISPLAY_ARG="-display gtk,zoom-to-fit=on"
EXTRA=()
if [[ "$MODE" == "1280x720" ]]; then
  NAME="oscortex-daily-drive-round5-hd"
  # Bochs stdvga stays 800. virtio-gpu advertises the requested mode.
  EXTRA=(-device virtio-gpu-pci,xres=1280,yres=720)
fi
nohup qemu-system-x86_64 \
  -name "$NAME" \
  -machine q35,accel=tcg -cpu qemu64 -m 256 \
  -kernel "$KERNEL" \
  -drive "file=$DISK,format=raw,if=ide,index=0,media=disk" \
  -device virtio-tablet-pci \
  $DISPLAY_ARG \
  "${EXTRA[@]}" \
  -chardev "socket,id=ser,host=127.0.0.1,port=${SERPORT},server=on,wait=off,logfile=${RUN}/serial.txt" \
  -serial chardev:ser \
  -qmp "tcp:127.0.0.1:${QMP},server,nowait" \
  -no-reboot \
  >"$RUN/qemu.log" 2>&1 </dev/null &
echo $! >"$RUN/qemu.pid"
echo "qmp=$QMP serial_sock=$SERPORT pid=$! disk=$DISK mode=$MODE"
