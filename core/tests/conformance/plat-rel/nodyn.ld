/* plat-rel/nodyn.ld — ET_EXEC with PT_INTERP, no PT_DYNAMIC. */

ENTRY(_start)

PHDRS
{
  interp PT_INTERP;
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x10000000;

  .interp : { *(.interp) } :interp :text
  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text

  . = ALIGN(0x1000) + 0x40;

  .data : { *(.data) *(.data.*) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
