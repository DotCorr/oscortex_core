#!/usr/bin/env bash
# Launch Round 39 leftover. Venus+scanout is BIOS -kernel + virtio-gpu-gl
# (UEFI + -vga none + virtio-gpu-gl was FB NONE / EGL_BAD_ACCESS).
# OSCORTEX_VENUS=0 is UEFI GOP. Host has no /dev/dri; llvmpipe only.
# zoom-to-fit=off so GTK follows the 1280×720 scanout instead of
# staying at the 640×480 default (R27 widget was 640×507).
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
RUN="${DRIVE_RUN:-$CORE_DIR/build/daily-drive-r39}"
mkdir -p "$RUN"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
SERPORT=$(python3 "$PICKER")
META="$CORE_DIR/build/BUILD.json"
HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
unset DRIVE_GIT_SHA
KERNEL_IN="${KERNEL_ELF:-}"
KERNEL_UEFI_IN="${KERNEL_UEFI:-}"
KERNEL_ELF=""
KERNEL_UEFI=""
if [[ -f "$CORE_DIR/build/kernel.elf" && -f "$META" ]]; then
  meta_git="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("git_sha",""))' "$META")"
  if [[ "$meta_git" == "$HEAD" ]]; then
    KERNEL_ELF="$CORE_DIR/build/kernel.elf"
    KERNEL_UEFI="$CORE_DIR/build/kernel-uefi.elf"
  fi
fi
if [[ -z "$KERNEL_ELF" && -n "$KERNEL_IN" && -f "$KERNEL_IN" ]]; then
  KERNEL_ELF="$KERNEL_IN"
fi
if [[ -z "$KERNEL_UEFI" && -n "$KERNEL_UEFI_IN" && -f "$KERNEL_UEFI_IN" ]]; then
  KERNEL_UEFI="$KERNEL_UEFI_IN"
fi
if [[ -z "$KERNEL_ELF" || ! -f "$KERNEL_ELF" ]]; then
  echo "launch-daily-drive-round39: promoting exact-tip core/build" >&2
  bash "$CORE_DIR/scripts/promote-core-build.sh"
  KERNEL_ELF="$CORE_DIR/build/kernel.elf"
  KERNEL_UEFI="$CORE_DIR/build/kernel-uefi.elf"
fi
[[ -f "$KERNEL_ELF" ]] || { echo "launch-daily-drive-round39: missing $KERNEL_ELF" >&2; exit 2; }
DISK="$RUN/disk.img"
ISO="$RUN/uefi.iso"
if [[ ! -f "$DISK" || "${FORCE_DISK:-0}" == "1" ]]; then
  if [[ -f "$CORE_DIR/build/disk.img" ]]; then
    cp "$CORE_DIR/build/disk.img" "$DISK"
  else
    bash "$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh" "$RUN"
  fi
fi
GIT_SHA="${DRIVE_GIT_SHA:-$HEAD}"
KERNEL_SHA="$(sha256sum "$KERNEL_ELF" | awk '{print $1}')"
echo "$GIT_SHA" >"$RUN/booted.git"
echo "$KERNEL_SHA" >"$RUN/kernel.sha256"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_SRC="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
VENUS="${OSCORTEX_VENUS:-1}"
BIOS="${OSCORTEX_BIOS:-}"
if [[ -z "$BIOS" ]]; then
  if [[ "$VENUS" == "1" ]]; then
    BIOS=1
  else
    BIOS=0
  fi
fi
if [[ "$BIOS" != "1" ]]; then
  [[ -f "$KERNEL_UEFI" ]] || { echo "launch-daily-drive-round39: missing $KERNEL_UEFI" >&2; exit 2; }
  need_iso=0
  if [[ "${FORCE_ISO:-0}" == "1" ]]; then
    need_iso=1
  elif [[ ! -f "$ISO" ]]; then
    need_iso=1
  elif [[ "$KERNEL_UEFI" -nt "$ISO" ]]; then
    need_iso=1
  fi
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
fi
echo "git=$GIT_SHA kernel_sha256=$KERNEL_SHA bios=$BIOS venus=$VENUS"
if [[ -f "$OVMF_CODE" && -f "$OVMF_VARS_SRC" ]]; then
  cp "$OVMF_VARS_SRC" "$RUN/OVMF_VARS.fd"
fi
: >"$RUN/serial.txt"
echo "$QMP" >"$RUN/qmp.port"
echo "$SERPORT" >"$RUN/serial.port"
if [[ -f "$RUN/qemu.pid" ]]; then
  old=$(cat "$RUN/qemu.pid" || true)
  if [[ -n "${old:-}" ]] && kill -0 "$old" 2>/dev/null; then
    if ps -p "$old" -o args= | grep -q 'oscortex-daily-drive-round39'; then
      kill "$old" 2>/dev/null || true
      sleep 0.4
    fi
  fi
fi

QEMU_BIN="${QEMU:-qemu-system-x86_64}"
PREFIX="${OSCORTEX_QEMU_VENUS_PREFIX:-/tmp/oscortex-qemu-venus}"
if [[ ! -x "$PREFIX/bin/qemu-system-x86_64" ]]; then
  PREFIX="${OSCORTEX_QEMU_VENUS_PREFIX:-$REPO_DIR/.qemu-venus}"
fi
if [[ "$VENUS" == "1" ]]; then
  if [[ -x "$PREFIX/bin/qemu-system-x86_64" ]]; then
    QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
  fi
  export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
  unset LD_PRELOAD
  export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
  export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
  export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
  if ! "$QEMU_BIN" -device virtio-gpu-gl-pci,help 2>&1 | grep -q 'venus'; then
    echo "launch-daily-drive-round39: OSCORTEX_VENUS=1 but no venus= property" >&2
    exit 2
  fi
fi
echo "$VENUS" >"$RUN/venus.flag"
echo "$BIOS" >"$RUN/bios.flag"
echo "$QEMU_BIN" >"$RUN/qemu.bin"

GPU_ARGS=()
# GOP path: zoom-to-fit off so a 1280 GOP surface is not letterboxed into 640.
DISPLAY_ARGS=(-display gtk,zoom-to-fit=off)
BOOT_ARGS=()
if [[ "$VENUS" == "1" ]]; then
  GPU_ARGS=(-vga none -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres=1280,yres=720)
  DISPLAY_ARGS=(-display gtk,gl=on,zoom-to-fit=off)
fi
if [[ "$BIOS" == "1" ]]; then
  BOOT_ARGS=(-kernel "$KERNEL_ELF")
else
  BOOT_ARGS=(
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$RUN/OVMF_VARS.fd"
    -cdrom "$ISO"
  )
fi

nohup "$QEMU_BIN" \
  -name oscortex-daily-drive-round39 \
  "${BOOT_ARGS[@]}" \
  -m 512M -cpu qemu64 \
  -chardev "socket,id=ser,host=127.0.0.1,port=${SERPORT},server=on,wait=off,logfile=${RUN}/serial.txt" \
  -serial chardev:ser \
  "${DISPLAY_ARGS[@]}" \
  "${GPU_ARGS[@]}" \
  -device virtio-tablet-pci \
  -drive "file=$DISK,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:${QMP},server,nowait" \
  -no-reboot \
  >"$RUN/qemu.log" 2>&1 </dev/null &
echo $! >"$RUN/qemu.pid"
echo "qmp=$QMP serial_sock=$SERPORT pid=$! iso=$ISO venus=$VENUS bios=$BIOS qemu=$QEMU_BIN"
