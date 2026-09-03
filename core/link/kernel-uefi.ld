/* core/link/kernel-uefi.ld
 *
 * Same three PT_LOAD layout as kernel.ld, linked at 9MiB instead of 1MiB.
 *
 * WHY. Limine 12's Multiboot1 loader calls check_usable_memory() on the
 * closed span [min_paddr, max_paddr). OVMF + this Limine mark
 * 0x800000..0x900000 as non-usable (type 4 islands in the MB map).
 * A Skia image that starts at 1MiB and ends at ~12.6MiB crosses that
 * island → `Executable load address is not usable memory`. The noskia
 * image ends below 8MiB and boots. The large usable run starts at 9MiB.
 *
 * QEMU `-kernel` and m7/m8 keep kernel.ld at 1MiB. This file is only
 * for the UEFI/GOP ISO (sit-in-view --uefi-hd). vm.dart accepts a
 * page-aligned start >= 1MiB and maps the gap as ordinary RAM.
 */
OUTPUT_FORMAT(elf32-i386)

ENTRY(_start)

PHDRS
{
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 9M;

    .multiboot : { __kernel_start = .; *(.multiboot) } :text
    .text      : { *(.text) *(.text.*) __text_end = .; } :text

    . = ALIGN(4096);
    .rodata : {
        __rodata_start = .;
        *(.rodata) *(.rodata.*)
        *(.got) *(.got.plt)
        __rodata_end = .;
    } :rodata

    . = ALIGN(4096);
    .data : {
        __data_start = .;
        KEEP(*(.osgfx_cmd))
        . = ALIGN(128);
        KEEP(*(.osmedia_cmd))
        . = ALIGN(64);
        KEEP(*(.otatls_cmd))
        *(.data) *(.data.*)
        __init_array_start = .;
        KEEP(*(.init_array))
        KEEP(*(.init_array.*))
        __init_array_end = .;
    } :data
    .bss  : { *(COMMON) *(.bss) *(.bss.*) __kernel_end = .; } :data

    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.note.*) *(.comment) *(.interp) }
}
