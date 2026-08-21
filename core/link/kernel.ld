/* core/link/kernel.ld
 *
 * oscortex_core M0 link script (OSCORTEX_SPEC.md §4). Load base 0x100000
 * (1MiB) -- the conventional Multiboot load address, avoids the first
 * 1MiB reserved for real-mode/BIOS-era structures.
 *
 * Two real bugs found and fixed here, both verified against the actual
 * toolchain (readelf/QEMU output), not assumed correct from reading
 * documentation:
 *
 * 1. QEMU's built-in Multiboot loader (used by -kernel) rejects a
 *    64-bit ELF container outright: "Cannot load x86-64 image, give a
 *    32bit one." (the exact error hit before this fix). `elf32-x86-64`
 *    (32-bit container, x86-64 relocations) was tried first and did
 *    NOT satisfy QEMU either -- only genuine `elf32-i386` did. The
 *    64-bit relocations DCDart's backend emits for kmain.o still link
 *    fine into an i386-formatted output (the ELF format is loader
 *    metadata only; it doesn't restrict what raw instruction bytes
 *    .text actually contains, so the real 64-bit code after the
 *    long-mode transition is unaffected).
 * 2. `.multiboot`'s own `.section` directive in boot.S needs an
 *    explicit "a" (SHF_ALLOC) flag -- GAS doesn't recognize this
 *    non-standard section name and otherwise defaults to NO section
 *    flags at all, which made ld correctly (per the flags it saw)
 *    exclude a non-allocatable section from every loadable segment,
 *    silently dropping the Multiboot header from the final image
 *    entirely. Confirmed via `readelf -S boot.o` showing an EMPTY
 *    flags column before the fix.
 *
 * 3. `.got`/`.got.plt` are placed EXPLICITLY below, ahead of ever being
 *    emitted. DCDart emits no globals today, so `kmain.o` currently has zero
 *    GOT relocations and `kernel.elf` has no `.got` at all -- verified with
 *    readelf, not assumed. But `backend/m0-target.md` §1 deliberately emits no
 *    `dso_local`, which makes taking a global's address produce
 *    `R_X86_64_REX_GOTPCRELX` (the code loads the address from a GOT slot
 *    rather than computing it). ld.lld and GNU ld both usually RELAX that to a
 *    plain `leaq`, so a `.got` may well never appear -- but "usually" is not a
 *    guarantee, and an unplaced `.got` would be an ORPHAN section whose
 *    placement is up to the linker's heuristics rather than to this script.
 *    Bug 2 above is exactly what an orphan landing outside the loadable
 *    segment looks like, and it cost real debugging time. Naming them costs
 *    nothing (ld discards an empty output section) and removes the class.
 *    This becomes live the moment DCDart's static-data work lands.
 *
 * PHDRS below forces every section into ONE PT_LOAD segment (FLAGS(7)
 * = RWX -- fine for M0, no fine-grained page permissions exist yet, see
 * boot.S's identity-mapping comment). Tested WITHOUT it too, after both
 * bugs above were fixed: ld's default orphan-section handling puts
 * `.bss` in its own second segment instead, which also boots correctly
 * -- PHDRS is kept as a deliberate simplification (one segment is
 * simpler to reason about), not because it was itself load-bearing.
 */
OUTPUT_FORMAT(elf32-i386)

ENTRY(_start)

PHDRS
{
    kernel PT_LOAD FLAGS(7);
}

SECTIONS
{
    . = 1M;

    .multiboot : { *(.multiboot) } :kernel
    .text      : { *(.text) }      :kernel
    .rodata    : { *(.rodata) *(.rodata.*) } :kernel

    /* Explicitly placed, not orphaned -- see note 3 in the header. Empty
       today; ld discards an empty output section, so this is free. */
    .got       : { *(.got) }       :kernel
    .got.plt   : { *(.got.plt) }   :kernel
    .data      : { *(.data) }      :kernel
    .bss       : { *(COMMON) *(.bss) } :kernel
}
