/* plat-need/prog.ld — ET_EXEC with PT_DYNAMIC for DT_NEEDED.
 * W^X. No PT_INTERP — the program walks NEEDED itself.
 */

ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);   /* PF_R | PF_X */
  data PT_LOAD FLAGS(6);   /* PF_R | PF_W */
  dynamic PT_DYNAMIC FLAGS(6);
}

SECTIONS
{
  . = 0x10000000;

  .hash : { *(.hash) } :text
  .dynsym : { *(.dynsym) } :text
  .dynstr : { *(.dynstr) } :text
  .rela.dyn : { *(.rela.dyn) } :text
  .rela.plt : { *(.rela.plt) } :text
  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text

  . = ALIGN(0x1000) + 0x40;

  .data : { *(.data) *(.data.*) } :data
  .dynamic : { *(.dynamic) } :data :dynamic
  .got : { *(.got) *(.got.plt) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) *(.interp) }
}
