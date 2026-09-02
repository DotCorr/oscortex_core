/* cef-plt/libc.ld — tiny ET_DYN exporting memset. Everything the
 * kernel reads (hash/dynsym/dynstr/dynamic/text) stays in the first
 * page so elfCefPlaceLibcMemset can resolve without a multi-page map.
 * RX text, optional RW page. W^X.
 */

ENTRY(memset)

PHDRS
{
  text PT_LOAD FLAGS(5);   /* PF_R | PF_X */
  data PT_LOAD FLAGS(6);   /* PF_R | PF_W */
  dynamic PT_DYNAMIC FLAGS(5);
}

SECTIONS
{
  . = 0x0;

  .hash : { *(.hash) } :text
  .dynsym : { *(.dynsym) } :text
  .dynstr : { *(.dynstr) } :text
  .dynamic : { *(.dynamic) } :text :dynamic
  .rela.dyn : { *(.rela.dyn) } :text
  .text : { *(.text) *(.text.*) } :text
  .rodata : { *(.rodata) *(.rodata.*) } :text

  . = ALIGN(0x1000);

  .data : { *(.data) *(.data.*) } :data
  .got : { *(.got) *(.got.plt) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
