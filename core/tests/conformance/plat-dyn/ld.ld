/* plat-dyn/ld.ld — one RX load in the 2 MiB window, above the dyn. */

ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
}

SECTIONS
{
  . = 0x10100000;

  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) *(.data*) *(.bss*) }
}
