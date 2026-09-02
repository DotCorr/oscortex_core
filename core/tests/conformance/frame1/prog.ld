/* core/tests/conformance/frame1/prog.ld
 *
 * m15-fileio/prog.ld, copied rather than shared: the milestone that owns
 * a harness owns its inputs. FRAME1 adds no new segment and no new
 * symbol the program hashes.
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

  __ro_start = .;
  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text
  __ro_end = .;

  . = ALIGN(0x1000) + 0x40;

  .data : { *(.data) *(.data.*) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data
  __rw_end = .;

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
