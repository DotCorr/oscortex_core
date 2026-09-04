#!/usr/bin/env bash
# Launch the Round 22 daily-drive QEMU: UEFI GOP 1280×720 + virtio-tablet.
# Isolated KERNEL_UEFI only — never writes core/build/kernel*.elf.
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$CORE_DIR/build/daily-drive-r22"
mkdir -p "$RUN"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
SERPORT=$(python3 "$PICKER")
DISK="$RUN/disk.img"
ISO="$RUN/uefi.iso"
KERNEL_UEFI="${KERNEL_UEFI:-/tmp/oscortex-r22-kbuild/kernel-uefi.elf}"
if [[ ! -f "$KERNEL_UEFI" ]]; then
  echo "launch-daily-drive-round22: missing $KERNEL_UEFI" >&2
  exit 2
fi
if [[ ! -f "$DISK" ]] || [[ "${FORCE_DISK:-0}" == "1" ]]; then
  if [[ -f "$CORE_DIR/build/daily-drive-r21/disk.img" && "${FORCE_DISK:-0}" != "1" ]]; then
    cp "$CORE_DIR/build/daily-drive-r21/disk.img" "$DISK"
  elif [[ -f "$CORE_DIR/build/daily-drive-r20/disk.img" && "${FORCE_DISK:-0}" != "1" ]]; then
    cp "$CORE_DIR/build/daily-drive-r20/disk.img" "$DISK"
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
REPO_ROOT="$(cd "$CORE_DIR/.." && pwd)"
GIT_SHA="${DRIVE_GIT_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)}"
if [[ -z "$GIT_SHA" ]]; then
  GIT_SHA="$(git -C "$CORE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
fi
KERNEL_SHA="$(sha256sum "$KERNEL_UEFI" | awk '{print $1}')"
echo "$GIT_SHA" >"$RUN/booted.git"
echo "$KERNEL_SHA" >"$RUN/kernel.sha256"
if [[ "$need_iso" == "1" ]]; then
  if ! eval "$(bash "$CORE_DIR/scripts/find-limine.sh")"; then
    echo "launch-daily-drive-round22: limine not found" >&2
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
    if ps -p "$old" -o args= | grep -q 'oscortex-daily-drive-round22'; then
      kill "$old" 2>/dev/null || true
      sleep 0.4
    fi
  fi
fi
nohup qemu-system-x86_64 \
  -name oscortex-daily-drive-round22 \
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
