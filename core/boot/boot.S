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
 * Page tables (PAE, 2MiB pages) -- identity-mapped, first 128MiB.
 *
 * M7 (ADR-0011) RAISED THIS FROM 16MiB, AND THE NUMBER IS NOT ARBITRARY.
 * It is the same number as the page allocator's frame bound
 * (`pmmMaxFrames` = 32768 frames of 4KiB = 128MiB, core/kernel/pmm.dart),
 * and they have to be the same number for the allocator to mean anything:
 * a frame this kernel cannot ADDRESS is not a frame it can hand out. With
 * eight entries the allocator would have managed 128MiB of RAM and been
 * able to write to 16MiB of it, and the difference would have surfaced as
 * a page fault inside whatever first used a high frame -- not as a
 * diagnosable allocator bug.
 *
 * So the invariant, stated once and asserted by
 * `tests/conformance/m7-frames/run.sh`: MAP_2MIB_PAGES * 2MiB ==
 * pmmMaxFrames * 4KiB. Raising the allocator's bound means raising this,
 * and the harness fails if only one of them moves.
 *
 * M8 MAKES THESE THE *BOOTSTRAP* TABLES, AND THAT IS ALL THEY ARE NOW.
 * `core/kernel/vm.dart` builds a second, real 4-level table out of frames from
 * the M7 allocator -- with per-section permissions and NX -- and installs it in
 * CR3 during `kmain()`. These four pages are what gets the CPU into long mode
 * and keeps it alive until that switch succeeds, which is exactly the job
 * CLAUDE.md rule 4 assigns to boot-time assembly, and no more than that.
 *
 * THEY ARE DELIBERATELY LEFT INTACT AFTER THE SWITCH. They cost 16KiB of
 * `.bss` that is never reused, and in exchange the machine has a known-good
 * table to fall back on and `vm.dart` can decline to switch (a malformed
 * layout, a frame allocation that failed) and leave a running kernel rather
 * than a half-built address space. Freeing them would also require them to
 * stop being inside `[__kernel_start, __kernel_end)`, which is the range the
 * page allocator reserves -- i.e. it would be a change to M7, for 16KiB.
 *
 * Still not a real memory map here (OSCORTEX_SPEC.md §4): 64 entries of one
 * page directory, identity, present+writable, no NX, no permissions of any
 * kind. That is the correct shape for a bootstrap table and the wrong shape
 * for an address space, which is the whole subject of ADR-0012.
 * ------------------------------------------------------------------ */
/* Number of 2MiB identity pages mapped at 0. 64 * 2MiB = 128MiB. */
.set MAP_2MIB_PAGES, 64
.section .bss
.align 4096
p4_table:
    .skip 4096
p3_table:
    .skip 4096
p2_table:
    .skip 4096
/* M5 (ADR-0009): a SECOND page directory, for the 3-4GiB region.
 *
 * WHY. A PCI device's registers and framebuffer live wherever the firmware's
 * BAR allocator put them, and on this machine that is the "PCI hole" just
 * below 4GiB -- QEMU's std VGA gets its 16MiB linear framebuffer at
 * 0xFD000000. The eight 2MiB pages above cover 0..16MiB and nothing else, so
 * until this page existed a store to a BAR address was a page fault, which is
 * the same class of silent wall OSCORTEX_SPEC.md §3 predicts for 0xB8000 on
 * real hardware -- except this one faults instead of doing nothing.
 *
 * WHY THE WHOLE GIGABYTE, rather than just the framebuffer. The alternative is
 * to map exactly the BAR, which means DCDart would have to write page-table
 * entries at runtime -- a second, much larger capability (a page-table walker,
 * TLB invalidation, and a decision about where new tables come from with no
 * allocator to ask). Identity-mapping 3-4GiB up front is 512 entries in one
 * loop, is where the PCI hole always is on a PC, and needs nothing new. It is
 * a boot-time decision made in boot-time assembly, which is what CLAUDE.md
 * rule 4 asks for.
 *
 * WHAT IT IS NOT. It is not a memory manager and it does not make these pages
 * safe: they are mapped writable, cacheable and identity, with no permissions
 * and no MTRR/PAT setup. Cacheable is wrong in principle for MMIO and right in
 * practice for a linear framebuffer; docs/known-gaps.md GAP-0071 says so
 * rather than leaving it to be discovered. */
p2_pci_table:
    .skip 4096
/* Multiboot1 information-structure pointer, as handed to us in EBX. Stashed
 * in memory rather than kept in a register because EVERY register is fair
 * game for the long-mode transition below (the page-table loops clobber
 * eax/ecx/edi, rdmsr/wrmsr clobber eax/ecx/edx, and cr0/cr3/cr4 writes go
 * through eax) -- a stash that survives by inspection today would be a
 * silent, hard-to-find corruption the first time someone adds a step here.
 * A .bss dword costs nothing and cannot be clobbered by accident.
 *
 * Written before ANY of that runs; read back immediately before `call
 * kmain`. .bss is not zeroed by anything at this point -- it does not need
 * to be, this location is written before it is ever read. */
multiboot_info_ptr:
    .skip 4

/* M8: "this CPU has NX and EFER.NXE is set."  1 = yes, 0 = no.
 *
 * WHY IT IS A RECORDED FACT RATHER THAN AN ASSUMPTION. `EFER.NXE` (MSR
 * 0xC0000080 bit 11) is only architecturally present if CPUID leaf
 * 0x80000001 reports EDX bit 20. Setting a reserved bit in EFER on a CPU
 * that does not have it raises #GP, and a #GP here -- before any IDT exists
 * -- is a triple fault and a silently rebooting VM with no diagnostic. So
 * the bit is ASKED FOR, and the answer is written here.
 *
 * And it is written here rather than merely acted on, because
 * `core/kernel/vm.dart` needs the same answer: a page-table entry with bit
 * 63 set is a RESERVED-bit violation when NXE is clear, which faults on
 * every access to that page rather than protecting it. `nx_enabled()` below
 * is how DCDart asks. On a CPU without NX the kernel still gets W^X for
 * `.text` (a read-only page cannot be rewritten) and still gets a read-only
 * `.rodata`; what it loses is "not executable", and `vm` says `NX 0` rather
 * than pretending.
 *
 * In boot.S's `.bss` and not `kdata.S`'s for the same reason
 * `multiboot_info_ptr` is: it is a fact the boot stub establishes about the
 * machine before any DCDart code exists, written exactly once, never written
 * again. `kdata.S` is DCDart's donated MUTABLE storage and its total is a
 * measurement (docs/known-gaps.md GAP-0053); this is neither. */
.align 8
nx_flag:
    .skip 8
/* .align 16 is load-bearing, not decoration: the System V AMD64 ABI (the
 * calling convention DCDart's x86_64-unknown-none-elf backend targets)
 * requires RSP to be 16-byte aligned at every `call` site. Before this
 * 4-byte stash existed, stack_top happened to be 4096-aligned by accident
 * of p4/p3/p2 each being exactly 4096 bytes; adding an odd-sized object
 * above it would silently have made it 4-mod-16. Align explicitly so the
 * property is stated, not inherited. */
.align 16
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
     * per the Multiboot spec's machine-state guarantee. EAX is still not
     * read (nothing needs to re-confirm the magic the loader already
     * matched to get here); EBX IS, now -- it is the information-struct
     * pointer core/kernel/multiboot.dart parses. */
    cli                            /* no IDT exists yet; keep interrupts
                                    * off for the whole boot sequence */
    movl $stack_top, %esp          /* only usable stack before this point
                                    * is whatever the loader left, which
                                    * nothing here should rely on */

    /* Stash EBX before anything else touches a register. See the
     * multiboot_info_ptr declaration above for why this goes to memory
     * rather than being parked in a callee-saved register. */
    movl %ebx, multiboot_info_ptr  /* bare symbol = absolute disp32 memory
                                    * operand -- see the p4_table store
                                    * below for why NOT "(multiboot_info_ptr)" */

    /* --- Zero the four page-table pages ---------------------------- */
    movl $p4_table, %edi
    movl %edi, %ecx
    addl $(4096 * 4), %ecx         /* end address: p4+p3+p2+p2_pci are laid
                                    * out contiguously (no alignment directive
                                    * between them in the .bss block above).
                                    * FOUR pages as of M5 -- the fourth is the
                                    * 3-4GiB page directory. Getting this
                                    * count wrong would leave a page directory
                                    * full of whatever the loader left in
                                    * memory and then mark every one of those
                                    * entries present. */
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

    /* --- PD[0..MAP_2MIB_PAGES-1] -> 2MiB huge pages, identity -------
     * (physical address == virtual address). Each entry's low 21 bits
     * are flag bits for a PS=1 (huge page) entry; every base address
     * here is already 2MiB-aligned (i * 0x200000), so ORing in the
     * flags below never corrupts the address bits.
     *
     * MAPPING PAST THE END OF INSTALLED RAM IS SAFE AND IS NOT AN
     * ACCIDENT. On a machine with less than 128MiB the high entries
     * point at addresses no DIMM answers, and nothing ever touches them:
     * the page allocator marks a frame free only if the loader's memory
     * map calls it type-1 usable, so an address that is not RAM is never
     * handed out. A present PTE is not a promise that memory is there;
     * it is only the removal of one of the two reasons a store could
     * fail. The memory map removes the other one. */
    movl $0, %ecx
map_p2_table:
    movl $0x200000, %eax           /* 2MiB */
    mull %ecx                      /* eax = 2MiB * ecx. edx is unused and
                                    * that is checked, not assumed: the
                                    * largest product is 63 * 2MiB =
                                    * 0x7E00000, which fits in 32 bits. A
                                    * MAP_2MIB_PAGES above 2048 would
                                    * overflow into edx and silently map
                                    * the wrong pages. */
    orl $0x83, %eax                /* bit0 present, bit1 writable, bit7 PS (huge page) */
    movl %eax, p2_table(, %ecx, 8) /* each PD entry is 8 bytes; upper 32
                                    * bits of the entry stay zero from the
                                    * zeroing loop above, which is correct
                                    * since every address here is <32 bits */
    incl %ecx
    cmpl $MAP_2MIB_PAGES, %ecx
    jl map_p2_table

    /* --- PDPT[3] -> the 3-4GiB page directory (present, writable) ----
     * M5. PDPT entry N covers [N GiB, N+1 GiB), so entry 3 is 0xC0000000..
     * 0xFFFFFFFF -- the PC's PCI hole, where the firmware puts BARs. Entry 3
     * is at byte offset 3*8 = 24 in the PDPT. */
    movl $p2_pci_table, %eax
    orl $0x3, %eax
    movl %eax, p3_table + 24

    /* --- PD[0..511] of that directory -> 2MiB huge pages, identity ---
     * Virtual 0xC0000000 + i*2MiB maps to the same physical address. The
     * base for entry i is 0xC0000000 + i * 0x200000, which is 2MiB-aligned
     * for every i, so ORing the flag bits in never disturbs an address bit.
     *
     * `mull` is avoided here: 0xC0000000 + 511*0x200000 = 0xFFE00000 still
     * fits in 32 bits, but the running base is kept in a register and added
     * to rather than recomputed, so there is no multiply whose high half
     * would need thinking about. */
    movl $0, %ecx
    movl $0xC0000083, %eax         /* base 0xC0000000 | present | writable | PS */
map_p2_pci_table:
    movl %eax, p2_pci_table(, %ecx, 8)
    addl $0x200000, %eax           /* next 2MiB frame; flags ride along in the
                                    * low bits and are unaffected by the add */
    incl %ecx
    cmpl $512, %ecx
    jl map_p2_pci_table

    /* --- Enable PAE (CR4 bit 5) -------------------------------------- */
    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4

    /* --- Load PML4 physical address into CR3 -------------------------- */
    movl $p4_table, %eax
    movl %eax, %cr3

    /* --- M8: does this CPU have NX? ----------------------------------
     * CPUID leaf 0x80000001, EDX bit 20 (NX / execute-disable). The
     * extended leaves do not exist on every x86 CPU, so leaf 0x80000000 is
     * asked FIRST for the highest extended leaf and 0x80000001 is only
     * executed if it is within range -- executing an unsupported leaf
     * returns whatever the highest supported one returns, which is garbage
     * that could easily have bit 20 set.
     *
     * `cpuid` clobbers EAX/EBX/ECX/EDX. EBX held the Multiboot info
     * pointer at entry and has already been stashed to memory above, which
     * is exactly the class of accident that stash exists to prevent.
     *
     * The answer is left in EDI (which the page-table loops have finished
     * with) so the EFER write below can consume it, AND is written to
     * `nx_flag` for `core/kernel/vm.dart` to read through `nx_enabled()`. */
    movl $0, %edi                  /* assume no NX until proven otherwise */
    movl $0x80000000, %eax
    xorl %ecx, %ecx
    cpuid
    cmpl $0x80000001, %eax
    jb no_nx                       /* extended leaf 1 does not exist here */
    movl $0x80000001, %eax
    xorl %ecx, %ecx
    cpuid
    testl $(1 << 20), %edx         /* EDX[20] = NX */
    jz no_nx
    movl $1, %edi
no_nx:
    movl %edi, nx_flag             /* bare symbol = absolute disp32 memory
                                    * operand -- see the p4_table store
                                    * above for why NOT "(nx_flag)" */
    movl $0, nx_flag + 4           /* the whole u64, so DCDart reading eight
                                    * bytes never sees .bss garbage in the
                                    * upper half (nothing zeroes .bss) */

    /* --- Set EFER.LME (long mode enable), MSR 0xC0000080, bit 8 -------
     * ...and EFER.NXE (bit 11) in the SAME write, if and only if the probe
     * above said the CPU has it. One rdmsr/wrmsr pair rather than two,
     * because EFER is one register and a second read-modify-write of it
     * would be a second chance to clobber LME.
     *
     * NXE MUST BE SET BEFORE ANY PAGE-TABLE ENTRY WITH BIT 63 IS LOADED.
     * With NXE clear, bit 63 of a PTE is a RESERVED bit, and touching a page
     * whose entry has a reserved bit set is a page fault with the RSVD bit
     * in the error code -- i.e. the entry that was supposed to protect the
     * page instead makes it unusable. Setting it here, in the boot stub, is
     * the earliest point at which it can be set at all, and it costs
     * nothing: the bootstrap tables built above have bit 63 clear
     * everywhere, so this changes no behaviour until vm.dart installs a
     * table that uses it. */
    movl $0xC0000080, %ecx
    rdmsr
    orl $(1 << 8), %eax            /* LME */
    testl %edi, %edi
    jz skip_nxe
    orl $(1 << 11), %eax           /* NXE */
skip_nxe:
    wrmsr

    /* --- Enable paging (CR0 bit 31) AND write protection (CR0 bit 16) --
     * PE (bit 0) is already set -- the Multiboot handoff guarantees
     * protected mode. Setting PG is the instruction that actually
     * activates long mode (the CPU only becomes a true 64-bit CPU once
     * PG and LME are both set).
     *
     * ===================================================================
     * M8: CR0.WP, AND IT IS NOT AN EXTRA. IT IS HALF THE MILESTONE.
     * ===================================================================
     * A page-table entry with RW=0 does NOT stop a write from ring 0
     * unless CR0.WP is set. With WP clear -- which is the power-on state,
     * and which is what this kernel ran with until now -- supervisor code
     * may write to ANY present page regardless of the entry's RW bit. The
     * bit is there to make copy-on-write work for a kernel touching a
     * user page; the side effect is that a kernel which never sets it has
     * a read-only `.rodata` that is not read-only.
     *
     * THIS WAS MEASURED, NOT LOOKED UP. With the new three-segment image
     * and `core/kernel/vm.dart`'s real page tables in CR3, `vm` reported
     * `VM RODATA ... W 00` -- every page's entry said not-writable -- and
     * `vmtest ro` still printed
     *
     *     VM TEST RO SURVIVED -- THE WRITE LANDED
     *
     * with the canary changed to DEADBEEF in the next report. The entries
     * were right and the CPU was ignoring them. `vmtest nx` faulted
     * correctly in the same session, because NX is enforced whatever WP
     * says -- which is exactly the shape of bug that would have shipped as
     * "W^X works" if only the NX half had been tested. docs/known-gaps.md
     * GAP-0080.
     *
     * Set HERE, with PG, rather than in vm.dart: it is a CPU-mode fact
     * like LME and NXE, it has no effect while the bootstrap tables (which
     * mark everything writable) are live, and CLAUDE.md rule 4 puts mode
     * setup in the boot stub. `cr0_read()` lets `vm` print it back, so the
     * report says WP 1 on the evidence of the register rather than on the
     * strength of this comment. */
    movl %cr0, %eax
    orl $0x80010000, %eax          /* bit 31 PG, bit 16 WP */
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
    /* First (and only) integer argument goes in RDI, per the System V
     * AMD64 ABI. `movl ..., %edi` (32-bit) is deliberate, not an
     * oversight: writing a 32-bit register zero-extends into the full
     * 64-bit register on x86-64, which is exactly what is wanted here --
     * the Multiboot info pointer is a 32-bit physical address and the
     * upper 32 bits of RDI must be zero for kmain()'s `u64` parameter to
     * be the address and not address-plus-garbage. */
    movl multiboot_info_ptr, %edi

    call kmain                      /* @bare DCDart, C ABI: one u64 arg
                                     * (the Multiboot info pointer), no
                                     * return value -- OSCORTEX_SPEC.md §2 */

halt_forever:
    cli
    hlt
    jmp halt_forever                /* hlt can wake on NMI; loop to be sure */

/* ------------------------------------------------------------------
 * M7 (ADR-0011): the kernel image's own extents, for the page allocator.
 *
 * `__kernel_start` and `__kernel_end` are defined by core/link/kernel.ld,
 * which is the only place that knows the real answer -- `.text`, `.rodata`
 * and `.bss` all move whenever anything is added to this kernel, and a
 * hardcoded "the kernel is N bytes" would be wrong the next time someone
 * edits it. The allocator has to reserve these frames: handing out a frame
 * the kernel is executing from, or one holding the allocator's own bitmap,
 * is the failure this pair exists to prevent.
 *
 * IN boot.S RATHER THAN kdata.S, on purpose. `kdata.S` currently passes
 * `verify-freestanding.sh` standalone with zero undefined symbols, which
 * docs/known-gaps.md GAP-0056 records as a real data point; referencing a
 * linker-script symbol from there would end that. This file already has an
 * undefined `kmain`, and the image's layout is a link-time fact, which
 * makes boot.S where it belongs (CLAUDE.md rule 4).
 *
 * RIP-relative `leaq`, not `movq $sym`, for the reason ADR-0001 gives:
 * `movabs` needs a 64-bit absolute relocation and this image links into an
 * `elf32-i386` container. The link script defines both symbols INSIDE
 * output sections so they are section-relative and this relocation is
 * expressible at all.
 * ------------------------------------------------------------------ */

/* uint64_t kernel_image_start(void) -- first byte of the loaded image. */
.align 16
.global kernel_image_start
.type kernel_image_start, @function
kernel_image_start:
    leaq __kernel_start(%rip), %rax
    ret

/* uint64_t kernel_image_end(void) -- one past the last byte, AFTER .bss.
 * `.bss` is where the boot stack, the four page-table pages and every
 * donated word in kdata.S live, so stopping short of it would let the
 * allocator hand out its own bitmap. */
.align 16
.global kernel_image_end
.type kernel_image_end, @function
kernel_image_end:
    leaq __kernel_end(%rip), %rax
    ret

/* ------------------------------------------------------------------
 * M8 (ADR-0012): the image's PER-SECTION extents, for the page-table builder.
 *
 * Same argument as the pair above, one level finer. `core/kernel/vm.dart` maps
 * `.text` read+execute, `.rodata` read-only and `.data`/`.bss` read+write, and
 * the only thing that knows where those boundaries are is `core/link/kernel.ld`
 * -- they move whenever anything is added to this kernel. A hardcoded address
 * would be wrong on the next edit, and wrong here means either a writable
 * `.text` (the gap this milestone closes) or a #PF on the first instruction
 * fetch after the CR3 switch, which is a triple fault.
 *
 * `__rodata_start` and `__data_start` are 4KiB-aligned by construction (the
 * link script puts `. = ALIGN(4096)` in front of each) and are the boundaries
 * the mapping actually uses. `__text_end` and `__rodata_end` are the exact,
 * unrounded section ends; `vm` prints them, and m8-paging/run.sh uses them to
 * assert that the page rounding never lands a byte of one section on another
 * section's page.
 *
 * Four accessors and not one block-with-offsets (the `cpu_info` / `fb_state`
 * pattern) because these are LINK-TIME CONSTANTS, not storage: there is no
 * block. Each is one `leaq` and one `ret`.
 * ------------------------------------------------------------------ */

/* uint64_t kernel_text_end(void) -- one past the last byte of `.text`. */
.align 16
.global kernel_text_end
.type kernel_text_end, @function
kernel_text_end:
    leaq __text_end(%rip), %rax
    ret

/* uint64_t kernel_rodata_start(void) -- first byte of `.rodata`, page-aligned.
 * ALSO one past the last text PAGE: the mapping uses [__kernel_start, this)
 * as the read+execute range, so the tail padding of `.text`'s last page is
 * executable and read-only, which is what padding should be. */
.align 16
.global kernel_rodata_start
.type kernel_rodata_start, @function
kernel_rodata_start:
    leaq __rodata_start(%rip), %rax
    ret

/* uint64_t kernel_rodata_end(void) -- one past the last byte of `.rodata`. */
.align 16
.global kernel_rodata_end
.type kernel_rodata_end, @function
kernel_rodata_end:
    leaq __rodata_end(%rip), %rax
    ret

/* uint64_t kernel_data_start(void) -- first byte of `.data`, page-aligned, and
 * one past the last read-only PAGE. */
.align 16
.global kernel_data_start
.type kernel_data_start, @function
kernel_data_start:
    leaq __data_start(%rip), %rax
    ret

/* uint64_t nx_enabled(void) -- 1 if EFER.NXE was set at boot, else 0.
 *
 * Reads the word `_start` wrote after probing CPUID leaf 0x80000001. See
 * `nx_flag`'s declaration above for why the capability is probed rather than
 * assumed, and why the answer has to reach DCDart rather than only being acted
 * on here. */
.align 16
.global nx_enabled
.type nx_enabled, @function
nx_enabled:
    movq nx_flag(%rip), %rax
    ret

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

/* Mark the stack non-executable (see kdata.S for the full note). */
.section .note.GNU-stack,"",@progbits
