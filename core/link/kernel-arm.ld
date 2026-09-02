/* core/link/kernel-arm.ld
 *
 * A1 aarch64 virt link script. QEMU `-M virt -kernel` accepts a plain
 * 64-bit aarch64 ELF and jumps to its entry (arm64-port.md STEP 3,
 * measured). No elf32-i386 container, no Multiboot header, no GNU-ld
 * requirement — ld.lld is sufficient.
 *
 * Load base 0x40080000: virt RAM starts at 0x40000000 (1 GiB), and the
 * 0x40080000 text address is the one the design-doc probe linked at and
 * booted. A2 will read the real /memory base from the device tree; A1
 * does not.
 */

OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    text   PT_LOAD FLAGS(5);   /* R + E */
    rodata PT_LOAD FLAGS(4);   /* R     */
    data   PT_LOAD FLAGS(6);   /* R + W */
}

SECTIONS
{
    . = 0x40080000;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(4096);
    .rodata : {
        *(.rodata .rodata.*)
        *(.got) *(.got.plt)
    } :rodata

    . = ALIGN(4096);
    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    } :data
}
