#!/usr/bin/env bash
# core/scripts/build-uefi-image.sh
#
# Pack kernel.elf + Limine BOOTX64.EFI + limine-bios.sys + limine.conf
# into a Limine *hybrid* ISO: UEFI (OVMF) and legacy BIOS (SeaBIOS)
# both boot the same Multiboot1 kernel. Does not build the kernel.
# Does not invoke QEMU. ADR-0060 (UEFI), ADR-0072 (BIOS).
#
# Usage:
#   build-uefi-image.sh <kernel.elf> <out.iso>
#   LIMINE_DATADIR=...  override `limine --print-datadir`
#   LIMINE_CONF=...     override core/boot-uefi/limine.conf
#
# Exit: 0 on success, 1 on build failure, 2 on setup/usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "build-uefi-image: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-uefi-image: FAIL — $1" >&2; exit 2; }

KERNEL_ELF="${1:-}"
OUT_ISO="${2:-}"
[[ -n "$KERNEL_ELF" && -n "$OUT_ISO" ]] || setup_error "usage: build-uefi-image.sh <kernel.elf> <out.iso>"
[[ -f "$KERNEL_ELF" ]] || setup_error "no kernel at $KERNEL_ELF"

command -v xorriso >/dev/null 2>&1 || setup_error "xorriso not found on PATH (brew install xorriso)"
# Prefer Limine 12 (path:) over PATH Limine 8 (KERNEL_PATH). A standalone
# Limine 12 has no --print-datadir; find-limine.sh uses the binary's directory.
# shellcheck disable=SC1090
eval "$(bash "$SCRIPT_DIR/find-limine.sh")" || setup_error "limine not found (need Limine 12+ at /opt/cursor/limine-binary or on PATH)"
[[ -n "${LIMINE:-}" && -x "$LIMINE" ]] || setup_error "find-limine.sh did not export LIMINE"
[[ -d "${LIMINE_DATADIR:-}" ]] || setup_error "Limine datadir not found at ${LIMINE_DATADIR:-}"
[[ -f "$LIMINE_DATADIR/BOOTX64.EFI" ]] || setup_error "no BOOTX64.EFI in $LIMINE_DATADIR"
[[ -f "$LIMINE_DATADIR/limine-uefi-cd.bin" ]] || setup_error "no limine-uefi-cd.bin in $LIMINE_DATADIR"
[[ -f "$LIMINE_DATADIR/limine-bios-cd.bin" ]] || setup_error "no limine-bios-cd.bin in $LIMINE_DATADIR"
[[ -f "$LIMINE_DATADIR/limine-bios.sys" ]] || setup_error "no limine-bios.sys in $LIMINE_DATADIR"

LIMINE_CONF="${LIMINE_CONF:-$CORE_DIR/boot-uefi/limine.conf}"
[[ -f "$LIMINE_CONF" ]] || setup_error "no limine.conf at $LIMINE_CONF"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-uefi-iso.XXXXXX")" || setup_error "mktemp failed"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

mkdir -p "$WORKDIR/iso/EFI/BOOT" "$WORKDIR/iso/boot"
cp "$KERNEL_ELF" "$WORKDIR/iso/boot/kernel.elf" || fail "could not copy kernel.elf"
cp "$LIMINE_DATADIR/BOOTX64.EFI" "$WORKDIR/iso/EFI/BOOT/BOOTX64.EFI" || fail "could not copy BOOTX64.EFI"
cp "$LIMINE_DATADIR/limine-uefi-cd.bin" "$WORKDIR/iso/limine-uefi-cd.bin" || fail "could not copy limine-uefi-cd.bin"
cp "$LIMINE_DATADIR/limine-bios-cd.bin" "$WORKDIR/iso/limine-bios-cd.bin" || fail "could not copy limine-bios-cd.bin"
# Official hybrid recipe: bios.sys at ISO root so SeaBIOS El Torito
# and `limine bios-install` (MBR / -drive) both find stage 2.
cp "$LIMINE_DATADIR/limine-bios.sys" "$WORKDIR/iso/limine-bios.sys" || fail "could not copy limine-bios.sys"
cp "$LIMINE_CONF" "$WORKDIR/iso/limine.conf" || fail "could not copy limine.conf"

xorriso -as mkisofs -R -r -J \
  -b limine-bios-cd.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
  -apm-block-size 2048 --efi-boot limine-uefi-cd.bin \
  -efi-boot-part --efi-boot-image --protective-msdos-label \
  "$WORKDIR/iso" -o "$OUT_ISO"
XORRISO_STATUS=$?
[[ $XORRISO_STATUS -eq 0 ]] || fail "xorriso exited $XORRISO_STATUS"
[[ -f "$OUT_ISO" ]] || fail "xorriso reported success but $OUT_ISO was not produced"

# Stage 1/2 into the ISO MBR so QEMU SeaBIOS can boot `-cdrom` *or*
# `-drive` without OVMF and without `-kernel`. El Torito already
# carries limine-bios-cd.bin; this is the hybrid half.
"$LIMINE" bios-install "$OUT_ISO" || fail "limine bios-install exited $?"

echo "build-uefi-image: PASS — $OUT_ISO (Limine ${LIMINE_VERSION:-hybrid}, UEFI + BIOS)"
exit 0
