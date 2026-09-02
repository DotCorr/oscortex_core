/* plat-rel/plat.ld — ET_EXEC with PT_INTERP + PT_DYNAMIC + one RELA.
 * FILEHDR+PHDRS sit in the first LOAD so LD.SO can parse at 0x10000000.
 * R_X86_64_64 writes dynsym[1].st_value (SIG) into reloc_word.
 * The word is 0 in the file. Not libc. */

ENTRY(_start)

PHDRS
{
  interp PT_INTERP;
  dynamic PT_DYNAMIC;
  text PT_LOAD FILEHDR PHDRS FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x10000000 + SIZEOF_HEADERS;

  .interp : { *(.interp) } :interp :text
  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text

  . = ALIGN(0x1000) + 0x40;

  .relocword : { *(.relocword) } :data
  .data : { *(.data) *(.data.*) } :data

  .dynstr : ALIGN(8) {
    dynstr_off = .;
    BYTE(0);
    BYTE(0x72); BYTE(0x65); BYTE(0x6C); BYTE(0x6F); BYTE(0x63);
    BYTE(0x5F); BYTE(0x73); BYTE(0x69); BYTE(0x67); BYTE(0);
  } :data

  .dynsym : ALIGN(8) {
    dynsym_off = .;
    /* index 0 — dummy */
    LONG(0); BYTE(0); BYTE(0); SHORT(0); QUAD(0); QUAD(0);
    /* index 1 — reloc_sig, STB_GLOBAL|STT_OBJECT|SHN_ABS, st_value = SIG */
    LONG(1); BYTE(0x11); BYTE(0); SHORT(0xFFF1);
    QUAD(0xA1270000C0DE0001); QUAD(8);
  } :data

  .rela.dyn : ALIGN(8) {
    rela_dyn = .;
    QUAD(reloc_word);
    QUAD(0x0000000100000001); /* sym 1, R_X86_64_64 */
    QUAD(0);
    rela_dyn_end = .;
  } :data

  .dynamic : ALIGN(8) {
    QUAD(5); QUAD(dynstr_off);              /* DT_STRTAB */
    QUAD(6); QUAD(dynsym_off);              /* DT_SYMTAB */
    QUAD(7); QUAD(rela_dyn);                /* DT_RELA */
    QUAD(8); QUAD(rela_dyn_end - rela_dyn); /* DT_RELASZ */
    QUAD(9); QUAD(24);                      /* DT_RELAENT */
    QUAD(11); QUAD(24);                     /* DT_SYMENT */
    QUAD(0); QUAD(0);
  } :dynamic :data

  .bss : { *(.bss) *(.bss.*) *(COMMON) } :data

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
