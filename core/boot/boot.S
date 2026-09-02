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
.set MB_VIDEO,    1 << 2          /* request a linear framebuffer (PORT1/PORT2, ADR-0060) */
.set MB_FLAGS,    MB_ALIGN | MB_MEMINFO | MB_VIDEO
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

.extern kmain

/* M9: GDT selectors, named once so the value and the meaning stay together.
 * The low two bits of a selector are its RPL, so the ring-3 selectors are
 * spelled with the |3 that `iretq` actually needs -- a bare 0x20 in the CS
 * slot of an `iretq` frame is a #GP, and the reason is invisible in hex. */
.set SEL_KCODE,     0x08
.set SEL_KDATA,     0x10
.set SEL_UDATA,     0x18 | 3      /* 0x1B */
.set SEL_UCODE,     0x20 | 3      /* 0x23 */
.set SEL_TSS,       0x28
/* A 64-bit TSS is 104 bytes; the limit is one less, and `iomap_base` is set to
 * the size itself so it lies PAST the limit, which is how x86 spells "there is
 * no I/O permission bitmap". */
.set TSS_SIZE,      104
.set TSS_LIMIT,     TSS_SIZE - 1
.set TSS_RSP0_OFF,  4
.set TSS_IOMAP_OFF, 102

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
    /* Address fields (offsets 12-28) are only valid if flags bit 16 is set.
     * It is not. They sit here as zeroes so the video fields occupy the
     * spec's offsets 32-44, which are valid because flags bit 2 IS set.
     *
     * WHY BIT 2 EXISTS AT ALL. Limine on UEFI refuses Multiboot1 text mode
     * ("Cannot use text mode with UEFI") -- there is no VGA text on that
     * firmware. The VIDEO request is what lets the same Multiboot1 header
     * boot under OVMF. QEMU's built-in `-kernel` loader does not implement
     * the video request and ignores these fields; that was measured
     * (ADR-0060), not assumed. Do not "simplify" them away: without them
     * the UEFI path is a Limine panic and the `-kernel` path is unchanged
     * only by coincidence of a loader that never looked.
     *
     * mode_type 0 = linear graphics. width/height 0 = no preference --
     * Limine's `resolution:` key (or the firmware GOP mode) fills them in.
     * depth 32 is what fb.dart already stores as 0x00RRGGBB. */
    .long 0                       /* header_addr (unused) */
    .long 0                       /* load_addr */
    .long 0                       /* load_end_addr */
    .long 0                       /* bss_end_addr */
    .long 0                       /* entry_addr */
    .long 0                       /* mode_type: 0 = graphics */
    .long 0                       /* width: 0 = no preference */
    .long 0                       /* height: 0 = no preference */
    .long 32                      /* depth */

/* ------------------------------------------------------------------
 * Page tables (PAE, 2MiB pages) -- identity-mapped, first 256MiB.
 *
 * M7 (ADR-0011) raised this from 16MiB to 128MiB. ADR-0155 raises it
 * again to 256MiB with `pmmMaxFrames`, so a named platform process can
 * plant the full 189 MiB CEF `.text` window. The number is not arbitrary:
 * it is the same as the page allocator's frame bound
 * (`pmmMaxFrames` = 65536 frames of 4KiB = 256MiB, core/kernel/pmm.dart),
 * and they have to be the same number for the allocator to mean anything:
 * a frame this kernel cannot ADDRESS is not a frame it can hand out.
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
 * Still not a real memory map here (OSCORTEX_SPEC.md §4): 128 entries of one
 * page directory, identity, present+writable, no NX, no permissions of any
 * kind. That is the correct shape for a bootstrap table and the wrong shape
 * for an address space, which is the whole subject of ADR-0012.
 * ------------------------------------------------------------------ */
/* Number of 2MiB identity pages mapped at 0. 128 * 2MiB = 256MiB. */
.set MAP_2MIB_PAGES, 128
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

/* ------------------------------------------------------------------
 * M11 (docs/decisions/0015-processes-and-fpu-state.md): DOES THIS CPU HAVE
 * FXSAVE AND SSE?  1 if it does, 0 if it does not.
 *
 * EXACTLY `nx_flag`'s argument, for exactly `nx_flag`'s reason, and the M8
 * incident it records is the one this bit could repeat. CR4 bits 9 (OSFXSR)
 * and 10 (OSXMMEXCPT) are RESERVED on a CPU without SSE, and writing a
 * reserved CR4 bit is a #GP -- which, here, before any IDT exists, is a triple
 * fault and a silently rebooting VM with no output at all. That is precisely
 * what `EFER.NXE` would have done at M8 if it had been set unconditionally.
 * So the capability is ASKED FOR (CPUID leaf 1: EDX bit 24 = FXSR, EDX bit 25
 * = SSE) and the answer is written here.
 *
 * It is written rather than merely acted on because `core/kernel/proc.dart`
 * needs the same answer: `fxsave`/`fxrstor` are themselves SSE-era
 * instructions and executing one on a CPU that lacks them is a #UD. A process
 * on such a machine gets no FPU save area and `proc` prints `SSE 0` rather
 * than pretending -- the same shape of answer `vm` gives for `NX 0`.
 *
 * In boot.S's `.bss` and not kdata.S's, for `nx_flag`'s reason: it is a fact
 * the boot stub establishes about the machine, written exactly once. */
.align 8
sse_flag:
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
    /* 2MiB: AnalyticRRect SkSL→SPIR-V in Recorder::snap still #GP'd
     * on 512KiB (FAULT 0D OP 4C8B after CURVE C). Page tables sit
     * immediately below stack_bottom — overflow corrupts them into
     * non-canonical walks. CoverBounds (rect) fit in 16KiB; curves
     * need this headroom. kstack0 stays 16KiB. */
    .skip 2097152                 /* 2MiB boot stack */
stack_top:

/* ------------------------------------------------------------------
 * M9 (docs/decisions/0013-ring-3-and-the-syscall-boundary.md): THE TSS, AND THE
 * RING-0 STACK IT NAMES.
 *
 * WHERE RSP0 COMES FROM, STATED RATHER THAN INHERITED.
 * When the CPU takes an interrupt while CPL == 3 it does NOT keep using the
 * current stack: it reads RSP0 out of the TSS, loads it into RSP, and pushes
 * the five-word frame there. With no TSS loaded, or with RSP0 zero, that push
 * is to an unusable address, the page fault it raises cannot be delivered
 * either, and the machine triple-faults and reboots with no diagnostic. RSP0 is
 * therefore not bookkeeping; it is the whole reason a ring-3 program can be
 * interrupted at all -- and this kernel's payloads reach the kernel ONLY by
 * being interrupted, on their second instruction.
 *
 * WHY IT IS A SEPARATE STACK FROM `stack_top` ABOVE, AND NOT THE SAME ONE.
 * The boot stack is IN USE when a payload runs: the `user` shell command is a
 * frame on it, `shellMain` is a frame under that, and M4's recovery mark
 * (`shell_resume_rsp`) points into the middle of it. Setting RSP0 to
 * `stack_top` would make the first syscall push its interrupt frame over the
 * TOP of that stack -- i.e. over `shellMain`'s own frame -- and the corruption
 * would only become visible after control returned to the shell, which is the
 * worst possible time to discover it. 16KiB, the same size as the boot stack,
 * because a fault taken in ring 3 is delivered here too and gets the same
 * headroom the kernel's own faults get.
 *
 * IT IS IN boot.S's `.bss` AND NOT IN kdata.S, on purpose, for exactly the
 * reason `nx_flag` above is: `kdata.S` is DCDart's donated MUTABLE storage and
 * its byte count is a measurement of a language gap (docs/known-gaps.md
 * GAP-0053). A CPU stack is neither -- no DCDart code reads or writes it, and
 * DCDart cannot read RSP at all. It is also inside `[__kernel_start,
 * __kernel_end)`, so the M7 frame allocator already reserves it, and
 * `core/kernel/vm.dart` maps `.bss` writable and non-executable, which is
 * exactly what a kernel stack must be.
 *
 * THE TSS IS DECLARED BEFORE THE STACK, AND THE ORDER IS A CHOICE.
 * They are adjacent whichever way round they go, and there is no guard page
 * (docs/known-gaps.md GAP-0081 item 6 is still open). This way RSP0 is
 * `kstack0_top`, a distinct address from `tss_base()`, so the two are
 * distinguishable in the `USER TSS ... RSP0 ...` report -- with the other order
 * they are the SAME address and the report reads like a bug. It also puts the
 * TSS where a stack that overflows lands on it, which corrupts RSP0 and makes
 * the next entry from ring 3 a triple fault: loud, immediate, and attributable,
 * rather than silently overwriting the boot stack's live frames.
 * ------------------------------------------------------------------ */

/* The 64-bit Task State Segment. 104 bytes, and this kernel uses exactly one
 * field of it -- RSP0, at offset 4.
 *
 * Long mode deleted hardware task switching, so a TSS is no longer a saved
 * context: it is a table of stack pointers (RSP0-2) and interrupt-stack-table
 * entries (IST1-7), plus the I/O permission bitmap base. There is no IST here
 * (isr.S's header records why M1 removed it and what would bring it back), and
 * there is no I/O bitmap -- `iomap_base` is set to 104, i.e. PAST the segment
 * limit, which is the architecturally-defined way to say "no bitmap, so every
 * `in`/`out` from CPL > IOPL is a #GP". That is a permission this milestone
 * wants: a ring-3 payload must not be able to reach a device port.
 *
 * ZEROED EXPLICITLY by `_start` below. `.bss` is not cleared by anything in
 * this kernel, and a garbage RSP1/RSP2/IST word is harmless only until
 * something uses it, while a garbage `iomap_base` pointing INSIDE the segment
 * would hand ring 3 whatever `.bss` happened to contain as an I/O permission
 * bitmap. */
.align 16
tss64:
    .skip 104

/* The ring-0 stack RSP0 points at. See the note above for why it is separate
 * from the boot stack and why it sits above the TSS. */
.align 16
kstack0_bottom:
    .skip 16384                   /* 16KiB */
kstack0_top:

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
                                    * largest product is 127 * 2MiB =
                                    * 0xFE00000, which fits in 32 bits. A
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

    /* --- M9: build the TSS, and the GDT descriptor that names it ------
     * DONE HERE, IN 32-BIT MODE, BEFORE PAGING, for two reasons that happen to
     * coincide: the descriptor needs `tss64`'s address split across three
     * non-adjacent byte-fields (no ELF relocation can express that -- see the
     * GDT at the bottom of this file), and `.rodata` stops being writable the
     * moment core/kernel/vm.dart installs its tables. This is the last window
     * in which both are true.
     *
     * Nothing here loads the task register. `ltr` runs later, from DCDart,
     * once an IDT exists -- see `tss_load` in core/boot/isr.S for why a #GP on
     * a malformed descriptor is worth a diagnostic instead of a triple fault. */

    /* Zero all 104 bytes of the TSS. `.bss` is not cleared by anything in this
     * kernel; a garbage `iomap_base` inside the limit would hand ring 3
     * whatever `.bss` contained as an I/O permission bitmap. */
    movl $tss64, %edi
    movl %edi, %ecx
    addl $TSS_SIZE, %ecx
    xorl %eax, %eax
zero_tss:
    movb %al, (%edi)
    incl %edi
    cmpl %ecx, %edi
    jl zero_tss

    /* RSP0 -- the stack an interrupt taken in ring 3 is delivered on. Written
     * as two dwords because the field is 64 bits and this is 32-bit code; the
     * high half is zero because every address in this image is below 4GiB. */
    movl $kstack0_top, %eax
    movl %eax, tss64 + TSS_RSP0_OFF
    movl $0, tss64 + TSS_RSP0_OFF + 4

    /* iomap_base = 104: past the limit, so there is no bitmap and every `in`
     * or `out` from CPL 3 (IOPL is 0) is a #GP. */
    movw $TSS_SIZE, tss64 + TSS_IOMAP_OFF

    /* The 16-byte system descriptor at gdt64_tss:
     *
     *   bytes 0-1  limit 15:0                       = 103
     *   bytes 2-3  base 15:0
     *   byte  4    base 23:16
     *   byte  5    P(1) DPL(00) S(0) type(1001)     = 0x89, available 64-bit TSS
     *   byte  6    G(0) 0 0 AVL(0) limit 19:16(0)   = 0
     *   byte  7    base 31:24
     *   bytes 8-11 base 63:32                       = 0
     *   bytes 12-15 reserved                        = 0
     *
     * S = 0 is what makes it a SYSTEM descriptor rather than a code/data one,
     * and it is the bit that makes the descriptor sixteen bytes wide instead of
     * eight. Type 9 (not 11) is "available"; the CPU sets it to 11 (busy) when
     * `ltr` loads it, and loading a descriptor that is ALREADY busy is a #GP --
     * which is why this must be written as 9 even though a dump taken after
     * boot will read 11. */
    movl $tss64, %eax
    movl %eax, %ecx
    shll $16, %ecx                 /* base 15:0 into bits 31:16 */
    orl $TSS_LIMIT, %ecx           /* limit 15:0 into bits 15:0 */
    movl %ecx, gdt64_tss
    movl %eax, %ecx
    shrl $16, %ecx
    andl $0xFF, %ecx               /* base 23:16 -> byte 4 */
    orl $0x8900, %ecx              /* byte 5: present, DPL 0, system, type 9 */
    movl %eax, %edx
    andl $0xFF000000, %edx         /* base 31:24 -> byte 7 */
    orl %edx, %ecx
    movl %ecx, gdt64_tss + 4
    movl $0, gdt64_tss + 8         /* base 63:32 */
    movl $0, gdt64_tss + 12        /* reserved; a non-zero value here is a #GP
                                    * on `ltr`, so it is written rather than
                                    * inherited from .rodata's file bytes */

    /* --- M11: does this CPU have FXSAVE and SSE? ---------------------
     * CPUID leaf 1, EDX bit 24 (FXSR) and EDX bit 25 (SSE). Leaf 1 exists on
     * every CPU that can reach this code at all -- the Multiboot handoff
     * already guarantees a 486-or-later in protected mode, and leaf 0 is
     * asked first anyway so that "maximum leaf is 0" is handled rather than
     * assumed.
     *
     * BOTH bits are required, and not because one implies the other on any
     * real part. They are two different needs: SSE is what the PROGRAM uses
     * (clang emits `movups`/`movaps` for a struct copy at -O2), and FXSR is
     * what the KERNEL uses to save it (`fxsave`/`fxrstor`). Enabling
     * CR4.OSFXSR is a promise to the CPU that the OS can do the second; a
     * kernel that made that promise with no `fxsave` behind it would be
     * telling the truth about the bit and lying about the state.
     *
     * `cpuid` clobbers EAX/EBX/ECX/EDX. EBX held the Multiboot info pointer
     * at entry and has already been stashed to memory above -- exactly the
     * class of accident that stash exists to prevent. */
    movl $0, sse_flag              /* assume not, until proven otherwise */
    movl $0, sse_flag + 4          /* the whole u64: nothing zeroes .bss */
    xorl %eax, %eax
    xorl %ecx, %ecx
    cpuid
    testl %eax, %eax
    jz no_sse                      /* leaf 1 does not exist */
    movl $1, %eax
    xorl %ecx, %ecx
    cpuid
    testl $(1 << 24), %edx         /* EDX[24] = FXSR */
    jz no_sse
    testl $(1 << 25), %edx         /* EDX[25] = SSE */
    jz no_sse
    movl $1, sse_flag
no_sse:

    /* --- GAP-0153: DOES THIS CPU HAVE SMEP? --------------------------
     * CPUID leaf 7, SUBLEAF 0, EBX bit 7. The answer is left in ESI and
     * consumed by the single CR4 write twelve instructions below; it is NOT
     * written to `.bss`.
     *
     * WHY A REGISTER AND NOT A FLAG BESIDE `nx_flag` AND `sse_flag`. Those
     * two are stored because DCDart READS them -- `vm.dart` must know whether
     * bit 63 of a page-table entry is NX or a reserved-bit violation, and
     * `proc.dart` must know whether `fxsave` is a #UD. Nothing in this kernel
     * needs to know whether SMEP is on: SMEP changes no code path, it only
     * makes one impossible. Storing the answer would have meant an eight-byte
     * `.bss` symbol and an `smep_enabled()` accessor -- a new extern, which
     * eight harnesses assert the count of -- for a fact with no reader. A
     * declared constant with no reader is exactly the defect GAP-0152 was, and
     * it is not worth repeating it here to make a probe look symmetrical.
     * `cr4_read()` already exists and reports the bit as the CPU holds it,
     * which is a better answer than a copy of what we intended.
     *
     * SUBLEAF 0 IS NOT OPTIONAL. Leaf 7 is subleaf-selected through ECX, and
     * `cpuid` reads whatever ECX happens to hold. The leaf-0 call above left
     * ECX zero, and it is zeroed again anyway rather than inherited -- the
     * cost is one instruction and the failure mode is reading a subleaf that
     * reports different bits entirely.
     *
     * THE MAXIMUM-LEAF CHECK IS THE M8 TRAP. CR4 bit 20 is RESERVED on a CPU
     * without SMEP, and writing a reserved CR4 bit is a #GP -- here, before
     * any IDT exists, a triple fault and a silently rebooting VM with no
     * output at all. That is what `EFER.NXE` would have done at M8 had it
     * been set unconditionally, and what CR4 bits 9/10 would do without
     * `sse_flag`. `cpuid` leaf 7 does not exist below Ivy Bridge, and asking
     * for a leaf above the maximum returns the HIGHEST leaf's data rather
     * than zeroes -- so the maximum is read first and compared, exactly as
     * the NX probe compares 0x80000001 against the maximum extended leaf.
     *
     * SMAP (EBX bit 20, CR4 bit 21) IS DELIBERATELY NOT PROBED HERE, because
     * nothing may act on the answer yet: this kernel dereferences a ring-3
     * VIRTUAL address at CPL=0 in four places (user.dart:1393,
     * file.dart:1398, file.dart:975, file.dart:811) and every one of them
     * would #PF with SMAP on. See docs/decisions/0025-smep.md §3 and
     * GAP-0153. */
    xorl %esi, %esi                /* assume no SMEP, until proven otherwise */
    xorl %eax, %eax
    xorl %ecx, %ecx
    cpuid
    cmpl $7, %eax                  /* EAX = highest standard leaf */
    jb no_smep                     /* leaf 7 does not exist on this CPU */
    movl $7, %eax
    xorl %ecx, %ecx                /* SUBLEAF 0 */
    cpuid
    testl $(1 << 7), %ebx          /* EBX[7] = SMEP */
    jz no_smep
    movl $1, %esi
no_smep:

    /* --- Enable PAE (CR4 bit 5), and OSFXSR|OSXMMEXCPT if we may -----
     * ONE CR4 write, not two, for the reason the EFER write below is one
     * rdmsr/wrmsr pair: a second read-modify-write of the same control
     * register is a second chance to clobber a bit that is already in it.
     *
     * bit 9  OSFXSR      -- "this OS saves and restores SSE state with
     *                        fxsave/fxrstor". Without it, every SSE
     *                        instruction is a #UD, in ring 0 and ring 3
     *                        alike (docs/known-gaps.md GAP-0092).
     * bit 10 OSXMMEXCPT  -- unmasked SSE numeric exceptions are delivered as
     *                        #XF (vector 19) rather than as #UD. This kernel
     *                        masks everything in MXCSR, so it changes no
     *                        behaviour today; it is set because the
     *                        alternative is a #UD whose cause names the wrong
     *                        thing entirely if a program ever unmasks one.
     * bit 20 SMEP        -- GAP-0153. A supervisor INSTRUCTION FETCH from a
     *                        page whose U/S bit is set is a #PF instead of a
     *                        jump. It is set only if the probe above found
     *                        the feature, and it is folded into THIS write
     *                        rather than added in a second one, because the
     *                        "one CR4 write" rule above is the whole reason
     *                        this register is not a source of accidents. */
    movl %cr4, %eax
    orl $0x20, %eax
    cmpl $0, sse_flag
    je skip_osfxsr
    orl $0x600, %eax               /* bit 9 OSFXSR, bit 10 OSXMMEXCPT */
skip_osfxsr:
    testl %esi, %esi               /* ESI = the SMEP probe's answer */
    jz skip_smep
    orl $0x100000, %eax            /* bit 20 SMEP */
skip_smep:
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
     * strength of this comment.
     *
     * M11: CR0.MP (bit 1) SET and CR0.EM (bit 2) CLEAR, and only on a CPU
     * that said yes above. EM ("emulate coprocessor") makes every x87 AND
     * every SSE instruction raise #UD no matter what CR4 says, so CR4.OSFXSR
     * without EM clear is a bit that changes nothing. MP pairs with TS for
     * lazy FPU switching, which this kernel does NOT do -- it saves eagerly
     * (ADR-0015 §2) -- and is set because MP=0 with EM=0 is the one
     * combination Intel documents as reserved-for-nothing-good: `wait`/`fwait`
     * would then ignore a pending unmasked x87 exception.
     *
     * The power-on value of EM is 0 and of MP is 0, so on QEMU this changes
     * exactly one bit. It is written anyway rather than inherited, because
     * "the reset state happens to be right" is not a property this kernel
     * gets to depend on and `cr0_read()` prints the answer back.
     */
    movl %cr0, %eax
    orl $0x80010000, %eax          /* bit 31 PG, bit 16 WP */
    cmpl $0, sse_flag
    je skip_sse_cr0
    orl $0x00000002, %eax          /* bit 1 MP */
    andl $0xFFFFFFFB, %eax         /* bit 2 EM clear */
skip_sse_cr0:
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

    /* --- M9: load the task register ---------------------------------
     * =================================================================
     * THIS IS HERE BECAUSE `ltr` WRITES TO THE GDT, AND THAT WAS MEASURED.
     * =================================================================
     * `ltr` does not merely load a register. It sets the BUSY bit in the TSS
     * descriptor it loads -- type 9 (available) becomes type 11 (busy) -- so it
     * is a STORE INTO THE GDT, and this kernel's GDT is in `.rodata`.
     *
     * Since M8 that is a read-only page with `CR0.WP` set, and the first
     * revision of this milestone called `ltr` from DCDart after `idt_load()`,
     * on the deliberate theory that a malformed descriptor should produce a
     * reported #GP rather than a triple fault. What it produced instead was:
     *
     *     M1 FAULT 0E 0000000000000003
     *
     * -- a page fault, present + write + supervisor, on the descriptor itself.
     * The descriptor was fine. The page was read-only, and W^X was working
     * exactly as ADR-0012 says it does.
     *
     * The two available fixes were "move the GDT into `.data`" and "load the
     * task register before the address space is installed". The second one is
     * taken, because the first one gives up a property M8 paid for: the GDT is
     * a table the CPU re-reads on every privilege transition and every
     * interrupt, and it has no business being writable. Here, paging is on but
     * `core/kernel/vm.dart` has not run, so the bootstrap tables -- which mark
     * everything present and writable -- are still what the MMU is walking. The
     * busy bit is written once, in the only window in which it can be, and the
     * GDT is immutable from the CR3 switch onwards.
     *
     * What is given up is a diagnostic: a malformed TSS descriptor is a #GP
     * here, before any IDT exists, which is a triple fault and a silently
     * rebooting VM. That is the same risk every other line in this stub carries
     * and it is why CLAUDE.md rule 4 puts GDT setup here in the first place.
     * `tr_read()` (core/boot/isr.S) lets the kernel print the selector back out
     * of the register afterwards, and `tests/conformance/m9-ring3/run.sh` reads
     * the descriptor out of guest physical memory and asserts its type is 11 --
     * busy -- which is a state only `ltr` can produce. */
    movw $SEL_TSS, %ax
    ltr %ax

    /* --- M11: bring the FPU to a known state -------------------------
     * `fninit` sets the x87 control word to 0x037F (all exceptions masked,
     * 64-bit extended precision), clears the status word, and marks all eight
     * x87 registers empty. It is the first instruction in this kernel that
     * could execute on the FPU at all, and it has to run before anything can
     * `fxsave`: the save area a process is given is built from a KNOWN state
     * (ADR-0015 §2), and "known" means this one.
     *
     * Guarded by the same flag CR4 and CR0 were, because with CR0.EM still set
     * -- which is what the flag being 0 means -- `fninit` is a #UD, here,
     * before any IDT exists.
     *
     * MXCSR is deliberately NOT touched here. `fninit` does not affect it, its
     * reset value is 0x1F80 (every SSE exception masked), and each process's
     * save area names 0x1F80 explicitly rather than inheriting whatever the
     * last program left in the register -- which is the whole point of the
     * save area existing. */
    cmpq $0, sse_flag(%rip)
    je skip_fninit
    fninit
skip_fninit:

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

/* uint64_t tss_base(void) -- the address of the 104-byte TSS.
 *
 * M9. Handed to DCDart so `user` can report RSP0 by READING IT BACK OUT OF THE
 * TSS the CPU is using, rather than by reprinting the constant this file wrote
 * -- the same discipline `cr0_read` gives WP and `cr3_read` gives the PML4. A
 * kernel that printed `kstack0_top` would say nothing about whether the
 * descriptor, the zeroing loop and `ltr` all did what they were supposed to.
 *
 * It is also how the conformance harness gets a start address for reading the
 * TSS out of guest physical memory, though it cross-checks that against the
 * link-time symbol rather than trusting this. */
.align 16
.global tss_base
.type tss_base, @function
tss_base:
    leaq tss64(%rip), %rax
    ret

/* uint64_t gdt_base(void) -- the address of the GDT.
 *
 * M9, and for the same reason: the DPL bits in the two user descriptors are
 * what makes ring 3 possible at all, and the harness reads them out of guest
 * memory at the base the CPU's own GDTR reports. This accessor lets the kernel
 * print the base it built so the two can be compared. */
.align 16
.global gdt_base
.type gdt_base, @function
gdt_base:
    leaq gdt64(%rip), %rax
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

/* uint64_t sse_enabled(void) -- 1 if CR4.OSFXSR|OSXMMEXCPT were set at boot
 * and CR0.EM was cleared, else 0.
 *
 * Reads the word `_start` wrote after probing CPUID leaf 1. See `sse_flag`'s
 * declaration above for why the capability is probed rather than assumed. It
 * is the SAME word the boot stub branched on for CR4, CR0 and `fninit`, so a
 * kernel that reads 1 here is standing on a CPU where all four of those
 * happened -- it is not an independent claim and does not pretend to be. The
 * independent claim is `cr4_read()`, which `proc` prints beside it. */
.align 16
.global sse_enabled
.type sse_enabled, @function
sse_enabled:
    movq sse_flag(%rip), %rax
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
 *
 * ===================================================================
 * M9: THREE MORE DESCRIPTORS, AND THE PRIVILEGE FIELD IS THE POINT.
 * ===================================================================
 * Everything above ran at CPL 0 because there was no descriptor in this table
 * that could produce any other CPL. A segment's DPL is where the privilege
 * level of running code comes from: `iretq` loads CS from a descriptor and the
 * CPL becomes that descriptor's DPL (RPL, for a conforming/non-conforming
 * check). So "run something unprivileged" is, first and last, "have a code
 * descriptor with DPL 3 to load".
 *
 *   0x18  user data, DPL 3  -- loaded as 0x1B (selector | RPL 3) into SS and
 *                              the data selectors
 *   0x20  user code, DPL 3  -- loaded as 0x23 by `iretq`; the L bit makes it
 *                              64-bit, exactly as the kernel's own does
 *   0x28  the TSS, 16 bytes -- a SYSTEM descriptor, which in long mode is two
 *                              GDT entries wide (it carries a 64-bit base),
 *                              so it occupies 0x28 and 0x30
 *
 * ORDER IS NOT SIGNIFICANT HERE and that is worth saying, because it usually
 * is: `syscall`/`sysret` require the user descriptors to sit at fixed offsets
 * from `IA32_STAR`, in the order data-then-code. This kernel enters and leaves
 * ring 3 with `iretq` and `int 0x80` (ADR-0013 §4 says why), which read the
 * selector out of the stack frame and the IDT gate respectively, so any order
 * would work. The `sysret` order is used anyway, so that adding `syscall`
 * later is a new instruction and not a GDT rearrangement.
 *
 * THE TSS DESCRIPTOR IS PATCHED AT RUNTIME, IN 32-BIT MODE, BY `_start`.
 * It cannot be written here: it needs `tss64`'s ADDRESS deposited into three
 * separate bit-fields (base 15:0, base 23:16, base 31:24), and an ELF
 * relocation can add a constant to a symbol but cannot shift it or split it
 * across non-adjacent bytes. `_start` builds it with ordinary shifts before
 * paging is enabled, which is also the last moment at which this page is
 * writable at all -- `core/kernel/vm.dart` maps `.rodata` read-only, so the
 * GDT is immutable from the CR3 switch onwards. That is the right property for
 * a table the CPU re-reads on every privilege transition, and it is why the
 * placeholder is here rather than in `.data`.
 * ------------------------------------------------------------------ */
.section .rodata
.align 8
/* =====================================================================
 * BIT 40 -- THE ACCESSED BIT -- IS PRE-SET ON ALL FOUR, AND THAT WAS MEASURED.
 * =====================================================================
 * The CPU SETS BIT 40 IN A DESCRIPTOR THE FIRST TIME IT IS LOADED into a
 * segment register. That is a write into the GDT, and since M8 the GDT is on a
 * read-only page with `CR0.WP` set. The kernel's own two descriptors have
 * always had it set by the CPU during `long_mode_start`, before paging
 * protections existed, so nothing ever noticed.
 *
 * The user descriptors are first loaded much later -- `enter_user` writes the
 * user data selector into DS, and `iretq` loads the user code selector into CS
 * -- long after `core/kernel/vm.dart` has made this page read-only. The first
 * revision of this milestone got, from `mov %eax,%ds`:
 *
 *     FAULT 0E ERR 0000000000000003 OP 8ED8
 *     PF CR2 000000000011701C ERR 00000003 PRESENT WRITE SUPER DATA
 *
 * CR2 is `gdt64 + 0x1C`: byte 4 of the user data descriptor. The descriptor was
 * correct; the CPU was trying to stamp it as accessed and the page said no.
 *
 * This is the SECOND instance of the same class in this file -- `ltr` writes the
 * busy bit, a segment load writes the accessed bit -- and the lesson is the one
 * ADR-0012 §2 already stated in a different key: **a table can be correct and
 * the hardware can still refuse to use it, for a reason that is nowhere in the
 * table.** Both are fixed by making the write unnecessary rather than by making
 * the page writable, so the GDT stays read-only, which is what a table the CPU
 * consults on every privilege transition should be.
 * ===================================================================== */
gdt64:
    .quad 0                                              /* null descriptor */
gdt64_code:
    .quad (1<<40) | (1<<41) | (1<<43) | (1<<44) | (1<<47) | (1<<53)
                                                          /* A, RW, E, S, P, L */
gdt64_data:
    .quad (1<<40) | (1<<41) | (1<<44) | (1<<47)           /* A, RW, S, P */
gdt64_user_data:
    .quad (1<<40) | (1<<41) | (1<<44) | (3<<45) | (1<<47) /* A, RW, S, DPL 3, P */
gdt64_user_code:
    .quad (1<<40) | (1<<41) | (1<<43) | (1<<44) | (3<<45) | (1<<47) | (1<<53)
                                                          /* A, RW, E, S, DPL 3, P, L */
gdt64_tss:
    .quad 0                       /* patched by _start: limit/base/type/P */
    .quad 0                       /* patched by _start: base 63:32 */
gdt64_pointer:
    .word . - gdt64 - 1
    .quad gdt64

/* Mark the stack non-executable (see kdata.S for the full note). */
.section .note.GNU-stack,"",@progbits
