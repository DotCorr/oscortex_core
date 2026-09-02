/* plat-futex/prog.ld — same two-PT_LOAD W^X script as plat-clone.
 * The ELF still loads in the 2 MiB app window. The child stack
 * and the shared gate are .bss. futex is syscall 30, not these
 * segments.
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
