/* core/boot/kdata.S
 *
 * oscortex_core: THE 96 BYTES OF DONATED STORAGE THAT ASSEMBLY ITSELF WRITES.
 *
 * WHAT THIS FILE WAS, AND WHY IT IS 96 BYTES INSTEAD OF 14048
 * ------------------------------------------------------------------
 * From M2 to M16 this file held EVERY mutable byte in the kernel, because
 * DCDart had no mutable static data of any kind: `@rodata` (DCDart ADR-0040)
 * gave read-only tables and nothing else, and there was no `static`, no global,
 * no `var` outside a function body. Every byte of kernel state that had to
 * outlive a call was donated here and reached from DCDart through a `u64`
 * address returned by an `@extern` accessor. It reached **14048 bytes across
 * twenty-one symbols and sixteen accessors** (docs/known-gaps.md GAP-0053).
 *
 * DCDart grew mutable statics (its ADR-0051, `@bss`). M17 (ADR-0021) moved
 * **13952 of those bytes** into the DCDart source files that own them, and
 * deleted sixteen `@extern` accessors and the assembly behind them. The kernel
 * declares 44 externs where it declared 60.
 *
 * WHAT IS LEFT, AND WHY IT IS NOT A LANGUAGE GAP
 * ------------------------------------------------------------------
 * A DCDart `@bss` symbol is emitted with LOCAL binding. Assembly cannot name a
 * local symbol in another object file. So any storage that ASSEMBLY ITSELF
 * writes, by name, cannot be a `@bss` block — and all five words below are
 * exactly that:
 *
 *   cpu_info          64  written by `cpu_probe` in isr.S: `leaq cpu_info(%rip)`
 *                         then four `cpuid` leaves stored through it. DCDart
 *                         cannot execute `cpuid` and cannot return 12 bytes.
 *   shell_resume_rsp   8  written by `shell_run_forever`, read by
 *   shell_resume_ok    8  `fault_resume` — both in isr.S, at fault time, with
 *                         no caller to pass an address in from. The RSP word is
 *                         a stack pointer, which DCDart cannot read or write at
 *                         all.
 *   user_resume_rsp    8  the same pair for the ring-3 entry/return path
 *   user_resume_ok     8  (`enter_user` / `user_return`).
 *
 * ADR-0013 and ADR-0007 both predicted, years of milestones before the language
 * feature existed, that these four resume words would still be here on the day
 * DCDart grew mutable statics. They were right. `cpu_info` is the one that
 * COULD move, at the price of changing `cpu_probe`'s signature to take a
 * destination pointer — a change to an assembly function rather than to a
 * storage seam, which is not what M17 was for. Recorded as GAP-0134.
 *
 * The residue is therefore not a measure of a missing language feature and
 * GAP-0053's running total is no longer counting one. It is the true size of
 * the DCDart/assembly boundary in this kernel.
 *
 * NOT ZEROED HERE. `.bss` is not cleared by anything in this kernel — boot.S
 * zeroes only the three page-table pages, by explicit address range. Every word
 * below is initialized before first use, and for `shell_resume_ok` /
 * `user_resume_ok` that ordering is the whole guard — see their notes below.
 * The same is true of the `@bss` blocks that left this file: DCDart's `@bss` is
 * zero-initialized by the ELF loader in principle, but nothing in this kernel's
 * Multiboot boot path zeroes `.bss`, so the initialization those subsystems
 * already did in their `init()` functions is still load-bearing and was not
 * removed. GAP-0135.
 *
 * WHO WRITES WHAT. All five words below are written by isr.S. DCDart reads
 * `cpu_info` through `cpu_info_addr()` and clears the two `_ok` guards through
 * `shell_resume_ok_addr()` / `user_resume_ok_addr()`; nothing in DCDart touches
 * either RSP word, and nothing should.
 *
 * `tests/conformance/m4-fault/run.sh` and `m9-ring3/run.sh` assert that these
 * words are still DEFINED IN THIS OBJECT rather than merely present somewhere,
 * because "somewhere" would mean a local symbol assembly cannot reach.
 */

/* ==================================================================
 * Storage.
 * ================================================================== */
.section .bss

/* CPUID result strings, as ONE 64-byte block:
 *
 *     +0   12 bytes  vendor  (leaf 0: EBX, EDX, ECX, in that order)
 *     +12   4 bytes  NUL pad, written by cpu_probe so the block is defined
 *     +16  48 bytes  brand   (leaves 0x80000002..0x80000004)
 *
 * ONE block with fixed offsets rather than two symbols with two accessors,
 * because each accessor is another `@extern` declaration on the DCDart side
 * and the offsets are a fixed part of CPUID's own contract anyway.
 *
 * This is what "return a 12-byte string across the DCDart/asm boundary" costs
 * in a language with no string type, no array type, and no `Pointer<T>` in an
 * extern signature (DCDart GAP-0025): the string cannot be RETURNED at all.
 * It is written into donated .bss by the assembly that produced it and read
 * back a byte at a time by DCDart through an address. See docs/known-gaps.md
 * GAP-0061. */

.align 8
.global cpu_info
cpu_info:
    .skip 64
    .size cpu_info, 64
    .type cpu_info, @object

/* The stack pointer the shell loop runs on, recorded ONCE by
 * `shell_run_forever` (core/boot/isr.S) at the moment the shell is entered.
 *
 * This is the whole of the recovery mechanism's state. A fault handler cannot
 * `iretq` back to a faulting instruction, so recovery abandons the faulting
 * computation entirely: `fault_resume` sets RSP back to this value and calls
 * the shell's entry point again. Every frame between the mark and the fault --
 * the command, the interrupt frame, whatever the command had called -- is
 * discarded by that one store, which is also why N faults cost no stack.
 *
 * DCDart never reads or writes this word; it cannot read RSP at all. */

.align 8
.global shell_resume_rsp
shell_resume_rsp:
    .skip 8
    .size shell_resume_rsp, 8
    .type shell_resume_rsp, @object

/* 1 once `shell_resume_rsp` holds a real value; 0 before that.
 *
 * NOT defensive decoration. `.bss` is not zeroed by anything in this kernel,
 * so before `shell_run_forever` runs, `shell_resume_rsp` contains whatever the
 * loader left in memory. A fault in the window between `m2Enter()` claiming
 * the console and the shell actually starting would otherwise set RSP to
 * garbage and triple-fault the machine -- while diagnosing a fault, which is
 * the one failure this milestone must not introduce.
 *
 * shellInit() zeroes it at the top of kmain(), long before anything can fault;
 * shell_run_forever sets it to 1 in the same breath as recording RSP;
 * fault_resume refuses to switch stacks unless it reads exactly 1. */

.align 8
.global shell_resume_ok
shell_resume_ok:
    .skip 8
    .size shell_resume_ok, 8
    .type shell_resume_ok, @object

/* The stack pointer `shellUser` was running on when it called `enter_user`,
 * recorded by `enter_user` (core/boot/isr.S) at the moment it is called.
 *
 * The `exit` syscall's return path. The handler runs in interrupt context on
 * the RING-0 stack, so it cannot simply return: the frames between it and the
 * shell command belong to a different stack entirely. `user_return` sets RSP
 * back to this value and `ret`s, which lands in `shellUser` immediately after
 * its call -- the same one-store abandonment `shell_resume_rsp` performs for a
 * fault, with the difference that nothing here went wrong.
 *
 * DCDart never reads or writes this word; it cannot read RSP at all. */

.align 8
.global user_resume_rsp
user_resume_rsp:
    .skip 8
    .size user_resume_rsp, 8
    .type user_resume_rsp, @object

/* 1 once `user_resume_rsp` holds a real value; 0 otherwise.
 *
 * `shell_resume_ok`'s argument, verbatim: `.bss` is not zeroed by anything in
 * this kernel, so loading `user_resume_rsp` into RSP without this guard would
 * put a garbage stack pointer in RSP and triple-fault the machine. Unlike the
 * shell's, this one is also CLEARED on every return -- an `exit` syscall is a
 * one-shot event and a second one, from ring 0, from a payload that has already
 * finished, has nothing to return to. */

.align 8
.global user_resume_ok
user_resume_ok:
    .skip 8
    .size user_resume_ok, 8
    .type user_resume_ok, @object

.section .text
.code64

/* uint64_t shell_line_addr(void) */
/* uint64_t shell_len_addr(void) */
/* uint64_t shell_state_addr(void) */
/* uint64_t shell_mbinfo_addr(void) */
/* uint64_t kbd_prefix_addr(void) */
/* uint64_t cpu_info_addr(void) -- base of the 64-byte CPUID block. Vendor at
 * +0 (12 bytes), brand at +16 (48 bytes). */
.align 16
.global cpu_info_addr
.type cpu_info_addr, @function
cpu_info_addr:
    leaq cpu_info(%rip), %rax
    ret

/* uint64_t fault_count_addr(void) */
/* uint64_t shell_resume_ok_addr(void) -- so shellInit() can clear the guard
 * before anything is able to fault. The RSP word itself gets no accessor: no
 * DCDart code has any business reading or writing a stack pointer. */
.align 16
.global shell_resume_ok_addr
.type shell_resume_ok_addr, @function
shell_resume_ok_addr:
    leaq shell_resume_ok(%rip), %rax
    ret

/* uint64_t fb_state_addr(void) -- base of the 32-byte framebuffer console
 * state block. Base at +0, pitch at +8, cursor column at +16, row at +24. */
/* uint64_t pmm_store_addr(void) -- base of the 4672-byte physical-memory-
 * manager storage block. Bitmap at +0 (4096 bytes), metadata at +4096 (64),
 * self-test ledger at +4160 (512).
 *
 * THE ENTIRE STORAGE SEAM FOR THE PAGE ALLOCATOR IS THIS ONE FUNCTION. It is
 * called from exactly three places, all of them in core/kernel/pmm.dart's
 * "storage seam" section. Adding a fourth call site anywhere else is the
 * change this design exists to prevent -- see the comment on `pmm_store`. */
/* uint64_t vm_store_addr(void) -- base of the 128-byte virtual-memory state
 * block. See `vm_store` above for the word layout.
 *
 * THE ENTIRE STORAGE SEAM FOR THE PAGE-TABLE BUILDER IS THIS ONE FUNCTION, and
 * it is called from exactly ONE place: `vmMetaBase()` in core/kernel/vm.dart.
 * Adding a second call site anywhere is the change this design exists to
 * prevent -- the same rule `pmm_store_addr` states, one call site tighter
 * because this block has one accessor's worth of structure rather than three.
 * `tests/conformance/m8-paging/run.sh` counts it. */
/* uint64_t user_store_addr(void) -- base of the 128-byte ring-3 state block.
 * See `user_store` above for the word layout.
 *
 * THE ENTIRE STORAGE SEAM FOR THE RING-3 SUBSYSTEM IS THIS ONE FUNCTION, and it
 * is called from exactly ONE place: `userMetaBase()` in core/kernel/user.dart.
 * The same rule `vm_store_addr` states, and `tests/conformance/m9-ring3/run.sh`
 * counts it the same way. */
/* uint64_t user_resume_ok_addr(void) -- so `userInit()` can clear the guard
 * before anything can enter ring 3. The RSP word itself gets no accessor, for
 * the reason `shell_resume_rsp` gets none: no DCDart code has any business
 * reading or writing a stack pointer. */
.align 16
.global user_resume_ok_addr
.type user_resume_ok_addr, @function
user_resume_ok_addr:
    leaq user_resume_ok(%rip), %rax
    ret

/* uint64_t elf_store_addr(void) -- base of the 128-byte ELF-loader state block.
 * See `elf_store` above for the word layout.
 *
 * THE ENTIRE STORAGE SEAM FOR THE ELF LOADER IS THIS ONE FUNCTION, and it is
 * called from exactly ONE place: `elfMetaBase()` in core/kernel/elf.dart. The
 * same rule `vm_store_addr` and `user_store_addr` state, and
 * `tests/conformance/m10-elf/run.sh` counts it the same way. */
/* uint64_t proc_store_addr(void) -- base of the 4160-byte process-table block.
 * See `proc_store` above for the three regions and their offsets.
 *
 * THE ENTIRE STORAGE SEAM FOR THE PROCESS TABLE IS THIS ONE FUNCTION, and it is
 * called from exactly THREE places, all in core/kernel/proc.dart:
 * `procHeadBase()`, `procTableBase()` and `procFxBase()`. That is ADR-0011's
 * shape rather than `user_store_addr`'s, because this block has three regions
 * with three different jobs -- and three named offsets behind three named
 * functions is what keeps the eventual migration to DCDart mutable statics a
 * three-line rewrite instead of an audit.
 * `tests/conformance/m11-proc/run.sh` counts the call sites. */
/* uint64_t fat_store_addr(void) -- base of the 1824-byte filesystem block.
 * See `fat_store` above for the four regions and their offsets.
 *
 * THE ENTIRE STORAGE SEAM FOR THE FILESYSTEM IS THIS ONE FUNCTION, and it is
 * called from exactly FOUR places, all in core/kernel/fat.dart:
 * `fatMetaBase()`, `fatChainBase()`, `fatSectorBase()` and `fatNameBase()`.
 * That is ADR-0011's shape, for the same reason `proc_store_addr` has it: this
 * block has four regions with four different jobs, and four named offsets
 * behind four named functions is what keeps the eventual migration to DCDart
 * mutable statics a four-line rewrite instead of an audit.
 * `tests/conformance/m14-fat/run.sh` counts the call sites. */
/* uint64_t file_store_addr(void) -- base of the file-descriptor
 * block (5760 bytes: 17 rows). See file.dart fileStoreBytes.
 *
 * ONE accessor for THREE regions, and THREE call sites in
 * `core/kernel/file.dart` and nowhere else. Same rule, same reason, sixth
 * time. `tests/conformance/m15-fileio/run.sh` counts the call sites. */
/* Mark the stack non-executable. Nothing here needs an executable stack, and
 * without this note GNU ld warns (and, historically, silently marked the
 * whole image's stack executable).
 *
 * M8: this stopped being cosmetic. Until M8 the whole image was one RWX
 * `PT_LOAD` (known-gaps GAP-0050) so the note protected nothing. The image is
 * now three segments -- R E, R, RW -- and `core/kernel/vm.dart` maps the boot
 * stack (which lives in `.bss`, inside the RW segment) writable and NX, so a
 * fetch from the stack is a #PF and not a jump into whatever was pushed. */
.section .note.GNU-stack,"",@progbits
