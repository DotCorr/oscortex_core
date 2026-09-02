/* plat-map/prog.ld — same two-PT_LOAD W^X script as plat-proc.
 * The ELF still loads in the 2 MiB app window. The mapped pages
 * are syscall 27, not these segments.
 */

ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);   /* PF_R | PF_X */
  data PT_LOAD FLAGS(6);   /* PF_R | PF_W */
}

SECTIONS
{
  . = 0x10000000;

  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text

  . = ALIGN(0x1000) + 0x40;

  .data : { *(.data) *(.data.*) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
