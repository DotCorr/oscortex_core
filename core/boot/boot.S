/* core/boot/boot.S
 *
 * oscortex_core M0 boot stub (OSCORTEX_SPEC.md §2). Hand-written x86-64
 * assembly for everything that has to run BEFORE a @bare DCDart function
 * can be called at all -- the CPU isn't even in a mode DCDart's backend
 * target (x86_64-unknown-none-elf) assumes until this stub gets it there.
 * Every register/flag write below is commented with WHY, not just what --
 * boot code has no debugger-friendly stack trace if it's wrong (SKILL.md).
 *
 * Multiboot1 (not v2): QEMU's -kernel loader understands it directly, no
 * GRUB/ISO needed, and M0 needs none of Multiboot2's extra tags (memory
 * map, modules, etc -- see OSCORTEX_SPEC.md §2's "out of scope" list,
 * mirrored in docs/known-gaps.md).
 */

.set MB_MAGIC,    0x1BADB002
.set MB_ALIGN,    1 << 0          /* request page-aligned modules (unused at M0, harmless to request) */
.set MB_MEMINFO,  1 << 1          /* request a memory map (unused at M0, harmless to request) */
.set MB_FLAGS,    MB_ALIGN | MB_MEMINFO
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

.extern kmain

/* ------------------------------------------------------------------
 * Multiboot1 header -- must be within the first 8KiB of the file and
 * 4-byte aligned. kernel.ld places .multiboot first in the image.
 * ------------------------------------------------------------------ */
/* "a" = SHF_ALLOC. Without it, GAS doesn't recognize this non-standard
 * section name and defaults to NO section flags at all (verified via
 * `readelf -S boot.o` before this fix -- .multiboot showed an EMPTY
 * flags column, unlike .text's "AX" or .rodata's "A") -- the linker
 * then correctly excludes a non-allocatable section from every loadable
 * segment, which is why it went missing from the final image entirely,
 * not a linker-script bug. */
.section .multiboot, "a"
.align 4
    .long MB_MAGIC
    .long MB_FLAGS
    .long MB_CHECKSUM

/* ------------------------------------------------------------------
 * Page tables (PAE, 2MiB pages) -- identity-mapped, first 16MiB. Enough
 * to cover the kernel image + boot stack with real margin; not a real
 * memory map (OSCORTEX_SPEC.md §4 -- deferred on purpose).
 * ------------------------------------------------------------------ */
.section .bss
.align 4096
p4_table:
    .skip 4096
p3_table:
    .skip 4096
p2_table:
    .skip 4096
stack_bottom:
    .skip 16384                   /* 16KiB boot stack */
stack_top:

/* ------------------------------------------------------------------ */
.section .text
.code32
.global _start
.type _start, @function
_start:
    /* Multiboot handoff: EAX = 0x2BADB002, EBX = multiboot info struct
     * pointer, CS/DS/ES/FS/GS/SS = flat 32-bit segments covering all
     * 4GiB, paging disabled, interrupts disabled, A20 enabled -- all
     * per the Multiboot spec's machine-state guarantee. Neither EAX
     * nor EBX is read at M0 (no memory-map parsing yet). */
    cli                            /* no IDT exists yet; keep interrupts
                                    * off for the whole boot sequence */
    movl $stack_top, %esp          /* only usable stack before this point
                                    * is whatever the loader left, which
                                    * nothing here should rely on */

    /* --- Zero the three page-table pages -------------------------- */
    movl $p4_table, %edi
    movl %edi, %ecx
    addl $(4096 * 3), %ecx         /* end address: p4+p3+p2 are laid out
                                    * contiguously (no alignment directive
                                    * between them in the .bss block above) */
    xorl %eax, %eax
zero_tables:
    movl %eax, (%edi)
    addl $4, %edi
    cmpl %ecx, %edi
    jl zero_tables

    /* --- PML4[0] -> PDPT (present, writable) ----------------------- */
    movl $p3_table, %eax
    orl $0x3, %eax                 /* bit0 present, bit1 writable */
    movl %eax, p4_table            /* bare symbol = absolute disp32 memory
                                    * operand -- NOT "(p4_table)", which
                                    * GAS parses as the unrelated 64-bit
                                    * MOV-moffs absolute-address form and
                                    * silently produces the wrong encoding */

    /* --- PDPT[0] -> PD (present, writable) -------------------------- */
    movl $p2_table, %eax
    orl $0x3, %eax
    movl %eax, p3_table

    /* --- PD[0..7] -> 2MiB huge pages covering 0..16MiB, identity ----
     * (physical address == virtual address). Each entry's low 21 bits
     * are flag bits for a PS=1 (huge page) entry; every base address
     * here is already 2MiB-aligned (i * 0x200000), so ORing in the
     * flags below never corrupts the address bits. */
    movl $0, %ecx
map_p2_table:
    movl $0x200000, %eax           /* 2MiB */
    mull %ecx                      /* eax = 2MiB * ecx (edx unused: result
                                    * never exceeds 32 bits for ecx < 8) */
    orl $0x83, %eax                /* bit0 present, bit1 writable, bit7 PS (huge page) */
    movl %eax, p2_table(, %ecx, 8) /* each PD entry is 8 bytes; upper 32
                                    * bits of the entry stay zero from the
                                    * zeroing loop above, which is correct
                                    * since every address here is <32 bits */
    incl %ecx
    cmpl $8, %ecx
    jl map_p2_table

    /* --- Enable PAE (CR4 bit 5) -------------------------------------- */
    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4

    /* --- Load PML4 physical address into CR3 -------------------------- */
    movl $p4_table, %eax
    movl %eax, %cr3

    /* --- Set EFER.LME (long mode enable), MSR 0xC0000080, bit 8 ------- */
    movl $0xC0000080, %ecx
    rdmsr
    orl $(1 << 8), %eax
    wrmsr

    /* --- Enable paging (CR0 bit 31). PE (bit 0) is already set --
     * Multiboot handoff guarantees protected mode. This is the
     * instruction that actually activates long mode (the CPU only
     * becomes a true 64-bit CPU once PG and LME are both set). */
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    /* --- Load the 64-bit GDT and far-jump into the 64-bit code segment.
     * This far jump is what finally loads CS with a descriptor whose
     * L-bit is set -- the actual switch into 64-bit instruction decode. */
    lgdt gdt64_pointer
    ljmp $0x08, $long_mode_start    /* 0x08 = gdt64_code's selector */

/* ------------------------------------------------------------------ */
.code64
long_mode_start:
    /* Reload data segment registers with the flat data selector (0x10).
     * Long mode ignores base/limit for these, but a valid selector still
     * has to be loaded or later instructions implicitly touching them
     * (e.g. anything using SS) fault. */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* rsp already holds stack_top's (zero-extended) value from the
     * 32-bit setup above -- a valid 64-bit stack pointer, no extra
     * work needed. */
    call kmain                      /* @bare DCDart, C ABI, no args, no
                                     * return value -- OSCORTEX_SPEC.md §2 */

halt_forever:
    cli
    hlt
    jmp halt_forever                /* hlt can wake on NMI; loop to be sure */

/* ------------------------------------------------------------------
 * 64-bit GDT: null, code (0x08), data (0x10). Long mode ignores most
 * descriptor fields (base/limit) except the access/flags bits that
 * select a 64-bit code segment (L-bit) -- this is the minimum real GDT
 * long mode needs, not a 32-bit-style full descriptor. Bit values are
 * the well-established minimal long-mode GDT (readable/writable(41),
 * descriptor-type=code-or-data(44), present(47), executable(43),
 * long-mode(53)) -- not guessed, this exact shape is the standard
 * long-mode bootstrap pattern.
 * ------------------------------------------------------------------ */
.section .rodata
.align 8
gdt64:
    .quad 0                                              /* null descriptor */
gdt64_code:
    .quad (1<<41) | (1<<43) | (1<<44) | (1<<47) | (1<<53) /* RW, E, S, P, L */
gdt64_data:
    .quad (1<<41) | (1<<44) | (1<<47)                     /* RW, S, P */
gdt64_pointer:
    .word . - gdt64 - 1
    .quad gdt64
