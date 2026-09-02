/* core/link/kernel.ld
 *
 * oscortex_core link script (OSCORTEX_SPEC.md §4). Load base 0x100000
 * (1MiB) -- the conventional Multiboot load address, avoids the first
 * 1MiB reserved for real-mode/BIOS-era structures.
 *
 * Three real bugs were found and fixed here at M0, all verified against the
 * actual toolchain (readelf/QEMU output), not assumed correct from reading
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
 * 3. `.got`/`.got.plt` are placed EXPLICITLY, ahead of ever being emitted.
 *    DCDart emits no globals today, so `kmain.o` currently has zero GOT
 *    relocations and `kernel.elf` has no `.got` at all -- verified with
 *    readelf, not assumed. But `backend/m0-target.md` §1 deliberately emits no
 *    `dso_local`, which makes taking a global's address produce
 *    `R_X86_64_REX_GOTPCRELX` (the code loads the address from a GOT slot
 *    rather than computing it). ld.lld and GNU ld both usually RELAX that to a
 *    plain `leaq`, so a `.got` may well never appear -- but "usually" is not a
 *    guarantee, and an unplaced `.got` would be an ORPHAN section whose
 *    placement is up to the linker's heuristics rather than to this script.
 *    Bug 2 above is exactly what an orphan landing outside the loadable
 *    segment looks like, and it cost real debugging time. Naming them costs
 *    nothing and removes the class.
 *
 *    **M8 moved them INSIDE `.rodata`'s output section** rather than leaving
 *    them as two separate (empty, discarded) output sections. Two reasons, and
 *    the second one is the load-bearing one:
 *      - a GOT in a statically linked, non-PIE image is fully resolved at link
 *        time and nothing writes it at runtime, so read-only is the correct
 *        permission for it, and `.rodata`'s segment is where read-only lives;
 *      - `m1-interrupts/run.sh` asserts `kernel.elf` has NO `.got`/`.got.plt`
 *        output section, and an empty output section carrying only a symbol
 *        assignment is not reliably discarded by ld. Collecting the input
 *        sections into `.rodata` keeps that assertion true whether or not a
 *        GOT is ever emitted, and puts any future GOT on a read-only page.
 *
 * 4. `__kernel_start` / `__kernel_end` (M7, ADR-0011) are the image's own
 *    extents, exported so the physical memory manager can RESERVE the frames
 *    the kernel is running in rather than hardcoding a guess about how big it
 *    is. They are defined INSIDE output sections, deliberately: a symbol
 *    assigned between sections is SHN_ABS, and `leaq __kernel_end(%rip)` on an
 *    absolute symbol is not a relocation this `elf32-i386` container can carry
 *    (the same class of problem note 1 records for `movabs`). Defined inside
 *    `.multiboot` and `.bss` they are section-relative and reach DCDart through
 *    two ordinary RIP-relative accessors in `core/boot/boot.S`.
 *
 *    `__kernel_end` is after `.bss` ON PURPOSE and not after `.data`: `.bss`
 *    holds the boot stack, the bootstrap page-table pages and every donated
 *    word in `kdata.S` -- including the page allocator's own bitmap. A
 *    reservation that stopped at `.data` would let the allocator hand out the
 *    frames its own bitmap lives in.
 *
 * ===========================================================================
 * M8 (docs/decisions/0012-paging-and-w-xor-x.md): THREE SEGMENTS, NOT ONE.
 * ===========================================================================
 *
 * Until M8 this script forced every section into ONE `PT_LOAD` with `FLAGS(7)`
 * -- read, write AND execute on everything. `.text` was writable and `.rodata`
 * was writable, and `core/boot/boot.S`'s bootstrap identity map (2MiB pages,
 * present+writable, no NX) honoured exactly that. A stray pointer could rewrite
 * code, and a store through a pointer derived from a constant global corrupted
 * read-only data with no fault at all. That was docs/known-gaps.md GAP-0050,
 * filed with the program-header evidence, and GAP-0079 added a second reason
 * when LLVM put a jump table in `.rodata`: the kernel acquired data whose
 * integrity IS control-flow integrity.
 *
 * There are now three segments with three different sets of flags:
 *
 *     text    R E   .multiboot  .text
 *     rodata  R     .rodata (including any future .got/.got.plt)
 *     data    RW    .data  .bss
 *
 * **The segment flags alone would be theatre.** Nothing in an x86-64 machine
 * enforces a `PT_LOAD`'s flags; the page tables do. `core/kernel/vm.dart`
 * builds a fresh 4-level table out of frames from the M7 allocator and honours
 * these boundaries with real PTE bits (`.text` RW=0/NX=0, `.rodata` RW=0/NX=1,
 * `.data`+`.bss` RW=1/NX=1), and `core/tests/conformance/m8-paging/run.sh`
 * asserts both halves -- the program headers here, and the live page tables
 * read back out of guest physical memory. GAP-0050 said explicitly that this
 * must NOT be done as a link-script-only change, because separate segments
 * without page-table enforcement look like protection while providing none.
 *
 * THE 4KiB ALIGNMENT IS THE WHOLE MECHANISM, not tidiness. A page is the unit
 * permissions come in. If `.text` and `.rodata` shared a page, that page would
 * need one set of bits for both, and the only safe choice would be the union
 * of what each needs -- writable-and-executable again, in the one place it
 * matters most. `. = ALIGN(4096)` between the three groups is what makes it
 * possible for them to differ at all. It costs up to 8KiB of image padding.
 *
 * THE FOUR NEW SYMBOLS are the section boundaries `vm.dart` maps against, and
 * they are here for the same reason `__kernel_start`/`__kernel_end` are: the
 * linker is the only thing that knows where `.text` ends, and it changes every
 * time anything is added to this kernel. Nothing in `vm.dart` hardcodes an
 * address. They are likewise defined INSIDE output sections (note 4 above).
 *
 *   __text_end       one past the last byte of `.text`
 *   __rodata_start   first byte of `.rodata`  -- page-aligned, by construction
 *   __rodata_end     one past the last byte of `.rodata`
 *   __data_start     first byte of `.data`    -- page-aligned, by construction
 *
 * The two page-aligned ones are the boundaries the mapping actually uses:
 *   text pages   = [__kernel_start,  __rodata_start)
 *   rodata pages = [__rodata_start,  __data_start)
 *   data pages   = [__data_start,    round-up(__kernel_end))
 * The other two are reported by the `vm` command so the exact section sizes are
 * visible next to the page-rounded ones, and so the harness can check that the
 * rounding never puts a byte of one section on another section's page.
 */
OUTPUT_FORMAT(elf32-i386)

ENTRY(_start)

PHDRS
{
    text   PT_LOAD FLAGS(5);   /* R + E  -- executable, NOT writable */
    rodata PT_LOAD FLAGS(4);   /* R      -- neither writable nor executable */
    data   PT_LOAD FLAGS(6);   /* R + W  -- writable, NOT executable */
}

SECTIONS
{
    . = 1M;

    /* --- Executable ------------------------------------------------------
     * `.multiboot` shares this segment with `.text`. It is 12 bytes of header
     * the loader reads before the kernel runs, it is read-only, and it sits at
     * the image's first byte -- so it is on `.text`'s first page whatever we
     * do about it. Giving it its own read-only segment would cost a page of
     * padding to protect twelve bytes that nothing can reach at runtime. */
    .multiboot : { __kernel_start = .; *(.multiboot) } :text
    .text      : { *(.text) *(.text.*) __text_end = .; } :text

    /* --- Read-only, non-executable --------------------------------------- */
    . = ALIGN(4096);
    .rodata : {
        __rodata_start = .;
        *(.rodata) *(.rodata.*)
        /* See note 3: input sections only, so no empty output section is
           created and `m1-interrupts/run.sh`'s "no .got in kernel.elf" check
           stays true, while any GOT that does appear lands read-only. */
        *(.got) *(.got.plt)
        __rodata_end = .;
    } :rodata

    /* --- Writable, non-executable ---------------------------------------- */
    . = ALIGN(4096);
    .data : {
        __data_start = .;
        KEEP(*(.osgfx_cmd))
        . = ALIGN(128);
        KEEP(*(.osmedia_cmd))
        . = ALIGN(64);
        KEEP(*(.otatls_cmd))
        *(.data) *(.data.*)
        __init_array_start = .;
        KEEP(*(.init_array))
        KEEP(*(.init_array.*))
        __init_array_end = .;
    } :data
    .bss  : { *(COMMON) *(.bss) *(.bss.*) __kernel_end = .; } :data

    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.note.*) *(.comment) *(.interp) }
}
