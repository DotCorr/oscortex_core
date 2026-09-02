/* core/tests/conformance/apps1/prog.ld
 *
 * Same two-PT_LOAD W^X script as frame1 / d3-session. The kernel refuses
 * a segment outside [0x10000000, 0x10200000) and refuses W+X.
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
