/* plat-libc/libc.ld — tiny ET_DYN. RX text, RW data. W^X.
 * Default shared-script vaddrs are fine; bias is applied at
 * dlopen time.
 */

ENTRY(write)

PHDRS
{
  text PT_LOAD FLAGS(5);   /* PF_R | PF_X */
  data PT_LOAD FLAGS(6);   /* PF_R | PF_W */
  dynamic PT_DYNAMIC FLAGS(6);
}

SECTIONS
{
  . = 0x0;

  .hash : { *(.hash) } :text
  .dynsym : { *(.dynsym) } :text
  .dynstr : { *(.dynstr) } :text
  .rela.dyn : { *(.rela.dyn) } :text
  .rela.plt : { *(.rela.plt) } :text
  .text : { *(.text) *(.text.*) } :text
  .rodata : { *(.rodata) *(.rodata.*) } :text

  . = ALIGN(0x1000);

  .data : { *(.data) *(.data.*) } :data
  .dynamic : { *(.dynamic) } :data :dynamic
  .got : { *(.got) *(.got.plt) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
