/* core/tests/conformance/d2-input/prog.ld
 *
 * Same two-PT_LOAD shape as m10-elf/d3-resident: W^X, load at 0x10000000,
 * .rodata first so e_entry is not the segment base.
 */

ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
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
