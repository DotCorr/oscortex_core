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
    .rodata    : { *(.rodata) }    :kernel
    .data      : { *(.data) }      :kernel
    .bss       : { *(COMMON) *(.bss) } :kernel
}
