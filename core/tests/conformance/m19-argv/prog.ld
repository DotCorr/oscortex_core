/* core/tests/conformance/m19-argv/prog.ld
 *
 * m15-fileio/prog.ld, copied rather than shared for m11-proc's reason: the
 * milestone that owns a harness owns its inputs. M19 changes NOTHING in it --
 * the initial process stack the kernel now builds lives on the stack page,
 * which no link script has ever described.
 *
 * Its own header, kept:
 *
 * core/tests/conformance/m14-fat/prog.ld
 *
 * M14 ADDS TWO SYMBOLS AND NOTHING ELSE: `__ro_start` and `__ro_end`, the
 * extent of the read-execute segment's file bytes. prog.c hashes that range at
 * run time and derive.py hashes the same bytes out of the ELF on the host, so a
 * program assembled out of the wrong clusters is caught by the program itself.
 *
 * m13-libc/prog.ld, copied rather than shared for m11-proc's reason:
 * the milestone that owns a harness owns its inputs, and a link script edited
 * for one milestone must not silently relayout another's programs.
 *
 * M13 NOTE. The program linked through this script now carries a C LIBRARY as
 * well as a program -- core/user/libc's four objects -- so its .text is larger
 * than any earlier milestone's and its heap base sits correspondingly higher.
 * Nothing here changes to accommodate that, deliberately: `malloc` asks `sbrk`
 * where the break is and `sbrk` computes it from the ELF's own PT_LOADs
 * (ADR-0016 §2), so a bigger program simply gets a smaller heap and nothing has
 * to be told about it. build-progs.sh still refuses a build with fewer than 400
 * pages of room, which is what would catch a libc that grew until it mattered.
 *
 * The link script for prog.c. TWO PT_LOAD segments and no third, because the
 * whole of what this milestone asserts about permissions is read out of
 * p_flags:
 *
 *   text  FLAGS(5) = PF_R | PF_X   .text + .rodata   -- never writable
 *   data  FLAGS(6) = PF_R | PF_W   .data + .bss      -- never executable
 *
 * A segment with FLAGS(7) would be W+X and core/kernel/elf.dart REFUSES it by
 * name. That is deliberate: this kernel enforces W^X on itself (ADR-0012) and
 * does not make an exception for a guest.
 *
 * 0x10000000 is 256MiB, and the address is not arbitrary. It is above
 * `vmMapBytes` (128MiB), so nothing in the kernel's identity map is anywhere
 * near it, and below 1GiB, so the page directory the kernel already built for
 * [0, 1GiB) is the one that gets the program's page table -- see ADR-0014 §3.
 * The kernel REJECTS a segment outside [0x10000000, 0x10200000) rather than
 * mapping it somewhere else.
 *
 * ALIGN(0x1000) plus -z max-page-size=0x1000 is what makes p_offset and
 * p_vaddr congruent modulo 4096 for both segments, which is the property
 * elfLoadSegment relies on and checks.
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

  /* .rodata BEFORE .text, and that is not a layout preference.
   *
   * With .text first, `_start` would be the very first byte of the very first
   * PT_LOAD -- so e_entry would equal p_vaddr would equal vmProgBase, and a
   * kernel that IGNORED e_entry and jumped to the start of the segment (or to
   * a hardcoded 0x10000000) would pass every check in m10-elf/run.sh for the
   * wrong reason. Putting .rodata first moves the entry point to a non-zero,
   * non-page-aligned offset inside the segment, so "the kernel jumped to
   * e_entry" is a claim only a kernel that read e_entry can satisfy.
   * build-prog.sh asserts the offset is non-zero. */
  __ro_start = .;
  .rodata : { *(.rodata) *(.rodata.*) } :text
  .text : { *(.text) *(.text.*) } :text
  /* M14: the exact extent of the R+X segment's FILE bytes, so the program can
   * checksum the image it was loaded from and derive.py can compute the same
   * number out of the ELF. This is what makes "the loader followed the cluster
   * chain" a claim the PROGRAM can make about itself. */
  __ro_end = .;

  /* NOT a plain ALIGN(0x1000): +0x40 puts the RW segment's p_vaddr at a
   * non-page-aligned address on purpose, so the loader's handling of a
   * segment that does not start on a page boundary is exercised by the
   * program that actually runs rather than by a case nobody tests. The
   * congruence p_offset == p_vaddr (mod 4096) still holds -- ld maintains it
   * -- and the 0x40 bytes below p_vaddr on that page must come out ZERO,
   * because the frame is zeroed before anything is copied into it. */
  . = ALIGN(0x1000) + 0x40;

  .data : { *(.data) *(.data.*) } :data
  .bss  : { *(.bss) *(.bss.*) *(COMMON) } :data

  /* M15: the end of the RW segment, which is the end of everything the kernel
   * maps for this program below the stack page at 0x101FF000. prog.c uses it to
   * aim a `read` at a range that STRADDLES the last mapped page and the
   * unmapped one after it -- the only way to make the kernel's write-side
   * pointer validator prove it walks EVERY page of a range rather than the
   * first. See run.sh CHECK 7f-bis and GAP-0124. */
  __rw_end = .;

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
