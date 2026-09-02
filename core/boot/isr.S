/* core/boot/isr.S
 *
 * oscortex_core M1 (interrupts): 256 interrupt/exception entry stubs, the IDT
 * they are installed into, the timer tick counter, and the handful of
 * privileged-instruction and address-of-symbol helpers DCDart cannot express.
 *
 * WHY ASSEMBLY (CLAUDE.md rule 4)
 * ------------------------------------------------------------------
 * Everything here is something DCDart genuinely cannot do, not something that
 * was merely easier in asm:
 *
 *   - An interrupt entry point must have no compiler-generated prologue and
 *     must return with `iretq`, not `ret`. DCDart has no `@naked`.
 *   - `lidt`, `cli`, `sti`, `int3`, `hlt` are privileged or control-flow
 *     instructions with no DCDart primitive.
 *   - DCDart has no static or global data of any kind, so the IDT, the IDTR
 *     and the tick counter live here.
 *   - DCDart cannot take the address of a symbol. `isr_stub_table` turns 256
 *     code addresses into ordinary DATA, and the `*_addr` accessors below
 *     hand out the addresses of everything else.
 *
 * THE SEAM (docs/decisions/0002-m1-interrupts-architecture.md)
 * ------------------------------------------------------------------
 * DCDart drives. Every routine below the stubs is an ordinary C-ABI function
 * that DCDart calls through `@extern` (DCDart ADR-0038), so `kmain()`
 * sequences the whole of M1 in one readable function instead of the
 * boot.S-arms-after-kmain-returns dance an earlier revision of this file
 * needed. `boot.S` is unchanged by M1 and still just calls `kmain(mbInfo)`.
 *
 * Extern signatures are scalars only (DCDart GAP-0025: no `Pointer<T>` in an
 * extern signature), which is exactly why the accessors return a `u64`
 * ADDRESS that DCDart then wraps in `Pointer<u64>` itself, rather than taking
 * or returning a pointer directly.
 *
 * NO TSS, NO IST -- AND WHY THAT CHANGED
 * ------------------------------------------------------------------
 * An earlier revision of this file set up a TSS with a dedicated IST stack and
 * gave every gate a non-zero IST index. The stated reason was that DCDart's
 * backend emitted red-zone-using code, so an interrupt taken without a stack
 * switch would push its 40-byte frame straight through the interrupted
 * function's live locals.
 *
 * That bug is FIXED upstream (DCDart ADR-0039, commit 0f5374e:
 * `DCTarget.forbidsRedZone => isFreestanding`, setting both `-mno-red-zone`
 * and the `noredzone` IR attribute). Re-verified here against real kernel
 * output, not taken on trust: `uartPutc` now opens with `sub $0x2,%rsp` where
 * it used to write `-0x2(%rsp)` with no adjustment, and there is not one
 * negative-`%rsp` access anywhere in `kmain.o`.
 *
 * So the IST is gone, deliberately. Its remaining merits are real -- surviving
 * a double fault taken on an exhausted or corrupt stack, and NMI -- but M1
 * exercises none of them: every interrupt it takes is delivered while the
 * healthy 16KiB boot stack is current. Keeping ~60 lines of TSS-descriptor
 * bit-packing and `ltr` that no test ever executes, justified by a scenario
 * this milestone does not create, is exactly the speculative building
 * CLAUDE.md rule 3 forbids. It comes back with the milestone that adds a real
 * double-fault test and can prove it works.
 *
 * M9 BROUGHT THE TSS BACK -- AND ONLY THE TSS. `core/boot/boot.S` now builds a
 * 104-byte TSS and loads it, because a ring-3 program cannot be interrupted at
 * all without RSP0: the CPU reads it out of the TSS and switches to it on every
 * entry from CPL 3. That is a scenario M9 DOES create, on the payload's second
 * instruction, which is precisely the test the paragraph above said would have
 * to exist first.
 *
 * THE IST IS STILL GONE, and the argument above is unchanged: every gate this
 * kernel installs still has IST 0, every interrupt is still delivered on a
 * healthy stack, and there is still no double-fault test. `m9-ring3/run.sh`
 * asserts IST 0 on all 256 gates so that stays a decision rather than a drift.
 *
 * WHAT M4 ADDED, AND WHY IT IS STILL THIS FILE
 * ------------------------------------------------------------------
 * Four routines, each one squarely inside the charter above -- something
 * DCDart genuinely cannot express, not something that was easier in asm:
 *
 *   shell_run_forever / fault_resume   read and WRITE RSP. DCDart cannot read
 *                                      a register, let alone switch stacks.
 *   divide_by_zero                     executes a `div` with a zero divisor.
 *                                      DCDart's own `~/` cannot produce a #DE
 *                                      -- it emits a zero check and a `ud2`
 *                                      instead (known-gaps GAP-0063).
 *   cpu_probe                          executes `cpuid`. No DCDart primitive,
 *                                      and no general inline asm.
 *
 * WHAT M9 ADDED (docs/decisions/0013-ring-3-and-the-syscall-boundary.md)
 * ------------------------------------------------------------------
 *   enter_user    writes segment registers, builds an interrupt frame by hand
 *                 and executes `iretq`. DCDart has none of the three.
 *   user_return   sets RSP to a recorded value and returns onto a stack
 *                 belonging to a different call -- fault_resume's sibling.
 *   tr_read       `str`, so the report reads the task register rather than
 *                 restating the selector this kernel meant to load.
 *   tlb_invlpg    `invlpg`. Privileged, no DCDart primitive, and the first
 *                 thing in this kernel that has ever needed it (GAP-0083).
 *
 * `ltr` is NOT here. It writes the busy bit into the TSS descriptor, which
 * since M8 is on a read-only page, so it has to run in `boot.S` before
 * `vm.dart` installs the real tables -- see ADR-0013 §2 and GAP-0086.
 *
 * STATUS: LIVE. Unlike this file's first revision, it is assembled and linked
 * by core/scripts/build-kernel.sh and executed by
 * core/tests/conformance/m1-interrupts/run.sh under real QEMU.
 */

.extern isrDispatch

/* M4 (ADR-0007). The fault-recovery seam runs in the OPPOSITE direction to
 * every other call in this file: DCDart's handler calls fault_resume() and
 * never gets control back, because fault_resume abandons its caller's stack
 * and calls BACK into DCDart on a stack recorded before the fault happened.
 * Both of these are ordinary C-ABI DCDart functions in core/kernel/shell.dart. */
.extern shellMain
.extern shellRecover

/* M4: donated storage in core/boot/kdata.S, written from here because DCDart
 * can neither read RSP nor execute `cpuid`. */
.extern shell_resume_rsp
.extern shell_resume_ok
.extern cpu_info

/* ==================================================================
 * Storage.
 * ================================================================== */
.section .bss

/* The IDT: 256 gate descriptors x 16 bytes. Page-aligned -- only 8-byte
 * alignment is architecturally required, but a page keeps it off a shared
 * cache line and makes it trivial to find in a memory dump. */
.align 4096
idt:
    .skip 4096

/* Timer tick counter. Written by the DCDart tick handler through a
 * Pointer<u64>, read back by DCDart through tick_count() below. .bss is not
 * zeroed by anything in this kernel, so idt_load() zeroes it explicitly --
 * see the note there. */
.align 8
tick_counter:
    .skip 8

/* ==================================================================
 * IDTR.
 * ================================================================== */
.section .data
.align 8
idtr:
    .word 4095                    /* limit = 256 gates * 16 bytes - 1 */
    .quad idt                     /* base, resolved by the linker */

/* ==================================================================
 * The 256 entry stubs.
 *
 * Generated with .rept/.set arithmetic rather than .altmacro string pasting:
 * no macro expansion means no dependence on how a given assembler spells `%i`
 * substitution, and every stub sits at a computable address, which is what
 * lets isr_stub_table be plain arithmetic instead of 256 hand-written labels.
 *
 * Each stub is padded to a 16-byte stride, so stub N is exactly
 * `isr_stubs + N*16`. The body is 9-12 bytes, so the padding is real slack.
 *
 * ERROR CODES: ten vectors -- 8 (double fault), 10-14 (invalid TSS, segment
 * not present, stack fault, general protection, page fault), 17 (alignment
 * check), 21 (control protection), 29 (VMM communication), 30 (security) --
 * push a real error code before the handler runs; every other vector pushes
 * nothing. The stub pushes a zero placeholder ONLY for the vectors that
 * don't, so isr_common always sees an identical frame and the `add $16,%rsp`
 * on the way out is always right.
 * ================================================================== */
.section .text
.code64

.align 16
isr_stubs:
.set isr_i, 0
.rept 256
    .align 16
    .if (isr_i == 8) || (isr_i == 10) || (isr_i == 11) || (isr_i == 12) || \
        (isr_i == 13) || (isr_i == 14) || (isr_i == 17) || (isr_i == 21) || \
        (isr_i == 29) || (isr_i == 30)
        /* CPU already pushed a real error code -- push nothing. The `nop`
         * keeps every stub's first instruction boundary identical when
         * disassembling, which is how the "the right vectors were
         * suppressed" check is made by eye. */
        nop
    .else
        pushq $0                  /* placeholder error code */
    .endif
    pushq $isr_i                  /* vector number */
    jmp isr_common
.set isr_i, isr_i + 1
.endr

/* ------------------------------------------------------------------
 * Common dispatcher.
 *
 * Stack on entry (lowest address first), after the CPU's push and the stub's
 * two:
 *
 *     rsp+0    vector          (pushed by the stub)
 *     rsp+8    error code      (the CPU's real one, or the stub's zero)
 *     rsp+16   rip             \
 *     rsp+24   cs               |
 *     rsp+32   rflags           | pushed by the CPU
 *     rsp+40   rsp (interrupted)|
 *     rsp+48   ss              /
 *
 * ABI alignment, worked out rather than hoped for: in 64-bit mode the CPU
 * aligns RSP to 16 before pushing its 40-byte frame, leaving RSP == 8 (mod
 * 16). The stub's two pushes add 16, so still 8 (mod 16). The 15 pushes below
 * add 120, and 8 - 120 == 0 (mod 16). RSP is therefore exactly 16-byte
 * aligned at the `call`, which is what the System V AMD64 ABI requires and
 * what DCDart's backend assumes, since it targets that ABI. Getting this
 * wrong would stay silent until the first SSE spill.
 *
 * RSP itself is not pushed (the interrupted value is already in the CPU frame),
 * which is why the count is 15 and not 16.
 * ------------------------------------------------------------------ */
.align 16
isr_common:
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    /* isrDispatch(vector, errorCode, rip, frameAddr), System V AMD64 order.
     *
     * frameAddr is passed because a DCDart handler cannot otherwise reach any
     * of the interrupted state: DCDart has no way to read a register, so the
     * only way to hand it the CPU context is as an address it can walk with
     * Pointer<u64>. That is also why all 15 registers are saved rather than
     * just the callee-saved ones -- the frame is a data structure for the
     * handler, not merely a save area.
     *
     * Offsets are from RSP after all 15 pushes. */
    movq 120(%rsp), %rdi          /* vector */
    movq 128(%rsp), %rsi          /* error code */
    movq 136(%rsp), %rdx          /* interrupted rip */
    movq %rsp, %rcx               /* saved-register frame base */

    call isrDispatch

    /* osgfx trampoline. Mailbox is zero unless `wm gfx`. */
    call osgfx_guest_tick
    call wmSessionRestore
    /* decoder mailbox. Zero unless hidden `play`. */
    call osmedia_guest_tick

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp                /* drop vector + error code */
    iretq

/* ==================================================================
 * C-ABI helpers, all called from DCDart via @extern (DCDart ADR-0038).
 *
 * Every address-materializing instruction below uses RIP-relative `leaq`
 * rather than `movq $symbol, %reg`. That is deliberate: `movq $sym,%reg`
 * assembles to a `movabs` needing a 64-bit absolute relocation, and this
 * kernel links into an `elf32-i386` container (ADR-0001 -- QEMU's Multiboot
 * loader rejects a 64-bit ELF). RIP-relative `leaq` needs only a 32-bit
 * PC-relative relocation, which that container handles without question.
 * ================================================================== */

/* uint64_t isr_stub_table_addr(void)
 * Address of the 256-entry stub address table. This is the pivot of the whole
 * design: DCDart cannot name a code symbol, but it can read a u64 out of
 * memory, so 256 code addresses become data it can install into the IDT. */
.align 16
.global isr_stub_table_addr
.type isr_stub_table_addr, @function
isr_stub_table_addr:
    leaq isr_stub_table(%rip), %rax
    ret

/* uint64_t idt_base(void) -- address of the IDT, for DCDart to fill. */
.align 16
.global idt_base
.type idt_base, @function
idt_base:
    leaq idt(%rip), %rax
    ret

/* uint64_t tick_counter_addr(void) -- address of the tick counter, so the
 * DCDart tick handler can increment it through a Pointer<u64>. */
.align 16
.global tick_counter_addr
.type tick_counter_addr, @function
tick_counter_addr:
    leaq tick_counter(%rip), %rax
    ret

/* uint64_t tick_count(void) -- read the tick counter.
 *
 * This exists as a separate accessor, rather than letting the waiting loop in
 * DCDart just load through tick_counter_addr(), for one specific reason:
 * DC-IR's Load carries no volatile semantics (DCDart GAP-0006), so a loop
 * that repeatedly loads the same address with nothing opaque in between is
 * one LLVM is entitled to hoist -- the spin would never observe an update and
 * would hang forever. An @extern call is opaque: LLVM cannot prove it does
 * not write memory, so the value must be re-read on every iteration.
 *
 * That makes the wait correct by the call boundary rather than by a volatile
 * guarantee DCDart does not make. Verified structurally, not assumed -- the
 * disassembly of the wait loop shows the `call tick_count` inside the back
 * edge. */
.align 16
.global tick_count
.type tick_count, @function
tick_count:
    /* ADR-0154: drive OTA TLS mailbox from shell waits (not IRQ). */
    call otatls_guest_tick
    movq tick_counter(%rip), %rax
    ret

/* Weak stub if otatls.o is omitted from the link. */
.align 16
.weak otatls_guest_tick
.type otatls_guest_tick, @function
otatls_guest_tick:
    ret

/* void idt_load(void) -- lidt.
 *
 * Also zeroes the tick counter. .bss is not cleared by anything in this
 * kernel (boot.S zeroes only the three page-table pages, by explicit address
 * range), so the counter's initial value is whatever the loader left in
 * memory. Zeroing it HERE rather than in DCDart is not arbitrary: this is the
 * last moment before interrupts can possibly be armed, so there is no window
 * in which a tick could be counted and then erased. */
.align 16
.global idt_load
.type idt_load, @function
idt_load:
    movq $0, tick_counter(%rip)
    lidt idtr(%rip)
    ret

/* void interrupts_enable(void) */
.align 16
.global interrupts_enable
.type interrupts_enable, @function
interrupts_enable:
    sti
    ret

/* void interrupts_disable(void) */
.align 16
.global interrupts_disable
.type interrupts_disable, @function
interrupts_disable:
    cli
    ret

/* void debug_break(void) -- execute int3.
 *
 * The M1 interrupt-delivery self-test. A breakpoint is the right instrument
 * for it: `int3` is a TRAP, so the pushed RIP already points at the following
 * instruction and `iretq` resumes normally. A FAULT (#UD, #DE, #PF) pushes
 * the address of the faulting instruction itself, so returning from one
 * re-executes it forever unless the handler fixes the cause. */
.align 16
.global debug_break
.type debug_break, @function
debug_break:
    int3
    ret

/* void halt_forever(void) -- never returns.
 *
 * Called by the DCDart fault handler after it has printed its diagnostic.
 * Necessary because M1's deliberate fault is a #UD (from DCDart's own
 * overflow-trap `ud2`), and #UD is a FAULT: returning would re-execute the
 * `ud2` and loop forever printing. `cli` first so the still-unmasked timer
 * cannot resurrect execution through an interrupt. */
.align 16
.global halt_forever
.type halt_forever, @function
halt_forever:
    cli
    hlt
    jmp halt_forever              /* hlt can wake on NMI; loop to be sure */

/* void idle_forever(void) -- never returns.
 *
 * M2's idle loop, and the exact opposite of halt_forever above: `sti` FIRST,
 * so interrupts stay enabled, then `hlt` until one arrives. That is what makes
 * the kernel interactive rather than merely alive -- every keystroke is an
 * IRQ1, and this is the state the CPU sits in between them.
 *
 * `sti` is inside the loop, not before it, so a handler that returns with IF
 * somehow clear cannot wedge the machine in a permanent `hlt`. Costs one
 * instruction per wake-up and removes an entire class of "it stopped
 * responding" failure.
 *
 * Separate from halt_forever rather than a parameter: these are two different
 * terminal states with opposite interrupt semantics, and a kernel that halts
 * when it meant to idle (or idles when it meant to halt after a fault) is
 * exactly the confusion a shared implementation would invite. */
.align 16
.global idle_forever
.type idle_forever, @function
idle_forever:
    sti
    hlt
    jmp idle_forever

/* void idle_once(void) -- sti; hlt; RETURN.
 *
 * M3 (ADR-0006). The shell's steady state is a loop in DCDart, not in
 * assembly: it has to WAKE UP, look at a flag, and run a command. A routine
 * that never returns cannot do that, so idle_forever above is no longer
 * called by anything (kept, not deleted -- it is the correct primitive for a
 * kernel with no work to dispatch, and ADR-0005 records it).
 *
 * The two instructions are ADJACENT on purpose and must stay that way. x86
 * delivers no interrupt between `sti` and the instruction after it, so a
 * keystroke that arrives in that window wakes the `hlt` instead of being
 * missed. The caller therefore does `cli`, tests its flag, and calls this only
 * if there is nothing to do -- which is the classic fix for sleeping through
 * the event you were waiting for. Splitting `sti` and `hlt` across a call
 * boundary would reintroduce exactly that race. */
.align 16
.global idle_once
.type idle_once, @function
idle_once:
    sti
    hlt
    ret

/* ==================================================================
 * M4 (docs/decisions/0007-fault-recovery-and-cpuid.md): fault recovery.
 *
 * A fault handler cannot `iretq` back to the instruction that faulted -- the
 * pushed RIP IS that instruction, so returning re-executes it forever. The
 * kernel therefore has exactly two honest options, and this pair implements
 * the second:
 *
 *   1. advance the return RIP past the faulting instruction. Correct only if
 *      you know its length, which for an x86 instruction in general you do not
 *      without a decoder. Rejected -- see the ADR.
 *   2. ABANDON the faulting computation and resume a context that was known
 *      good before the fault. That is what a real OS does when it kills a
 *      process, and it is what these two routines do.
 *
 * There is no third option here. Resuming the FAILED computation after
 * repairing its cause -- the condition-system model this project is aiming at
 * -- needs language support that does not exist on either side (DCDart
 * docs/escalations/0005-condition-system.md).
 * ================================================================== */

/* void shell_run_forever(void) -- record the resume point, then run the shell.
 * NEVER RETURNS.
 *
 * Called from m2Enter() in place of a direct DCDart call to shellMain(). The
 * only thing it adds is the two stores, and they have to be here because
 * DCDart cannot read RSP.
 *
 * ALIGNMENT, worked out rather than hoped for. This is reached by `call`, so
 * at the label RSP == 8 (mod 16); the System V AMD64 ABI wants RSP == 0
 * (mod 16) at a call SITE. `andq $-16` lowers RSP by exactly 8 here and makes
 * the following `call` correct without depending on that arithmetic -- and
 * fault_resume re-derives the same aligned value from the same recorded word,
 * so the shell runs on an identical stack pointer before and after a fault.
 * Getting this wrong stays silent until the first SSE spill. */
.align 16
.global shell_run_forever
.type shell_run_forever, @function
shell_run_forever:
    movq %rsp, shell_resume_rsp(%rip)
    movq $1, shell_resume_ok(%rip)
    andq $-16, %rsp
    call shellMain
    jmp halt_forever              /* shellMain never returns; if it ever did,
                                   * stop rather than run off the end */

/* void fault_resume(void) -- NEVER RETURNS.
 *
 * Called by the DCDart fault handler AFTER it has printed its diagnostic.
 * Discards the faulting computation and every frame under it, and re-enters
 * the shell on the stack `shell_run_forever` recorded.
 *
 * `cli` first: RSP is about to stop describing the stack the current frame
 * lives on, and an interrupt delivered in the middle of that would push its
 * frame somewhere arbitrary. The shell re-enables interrupts itself, in
 * idle_once, one loop iteration later.
 *
 * THE GUARD IS NOT DECORATION. `.bss` is not zeroed by anything in this
 * kernel, so shell_resume_rsp is garbage until shell_run_forever runs.
 * shellInit() clears shell_resume_ok at the very top of kmain(); without the
 * check, a fault taken between `m2Enter()` claiming the console and the shell
 * actually starting would load a garbage RSP and triple-fault the machine
 * WHILE REPORTING A FAULT. Falling back to halt_forever loses the machine but
 * keeps the diagnostic that was already printed, which is strictly the better
 * of two bad outcomes.
 *
 * The one thing this does NOT restore is the PIC. See picEoiMaster() at the
 * DCDart call site and docs/known-gaps.md GAP-0062. */
.align 16
.global fault_resume
.type fault_resume, @function
fault_resume:
    cli
    cmpq $1, shell_resume_ok(%rip)
    jne halt_forever
    /* M9: put the kernel's own segment selectors back before switching stacks.
     *
     * A fault taken in RING 3 arrives here with DS/ES/FS/GS holding the ring-3
     * data selector `enter_user` loaded, and with SS NULL (the CPU nulls it on
     * a privilege-changing interrupt in long mode). None of that is harmful in
     * long mode -- segmentation is off for data -- and none of it was harmful
     * before M9 either, because a fault could only ever come from ring 0. It is
     * reloaded anyway, because "the shell is running on a ring-3 stack selector
     * because something faulted forty commands ago" is exactly the kind of
     * inherited state that is fine until the day it is not. On a ring-0 fault
     * these five writes store the values that are already there. */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    movq shell_resume_rsp(%rip), %rsp
    andq $-16, %rsp
    call shellRecover             /* DCDart: reset shell state, say so, prompt */
    call shellMain
    jmp halt_forever

/* void divide_by_zero(void) -- NEVER RETURNS (it faults).
 *
 * `crash div` needs a genuine #DE (vector 0), and DCDart CANNOT PRODUCE ONE.
 * Verified by compiling and disassembling `a ~/ b`, not assumed: dcc emits an
 * explicit `test %rsi,%rsi; je <ud2>` zero-divisor check in front of the
 * `div`, so a DCDart division by zero traps as #UD (vector 6) -- the same
 * vector `crash ud` already produces, from the same `ud2`. Recorded as
 * docs/known-gaps.md GAP-0063.
 *
 * So the divide error is executed here, in the same category and for the same
 * reason `debug_break` executes `int3`: an instruction DCDart cannot emit,
 * behind a C-ABI function. RDX:RAX = 0:1 divided by RCX = 0.
 *
 * The encoding is hand-written and therefore FIXED (`48 f7 f1`), which is what
 * lets the fault diagnostic's ` OP 48F7` field be a byte-exact golden value
 * rather than a hostage to register allocation. */
.align 16
.global divide_by_zero
.type divide_by_zero, @function
divide_by_zero:
    xorl %ecx, %ecx
    xorl %edx, %edx
    movl $1, %eax
    divq %rcx                     /* 48 f7 f1 -- #DE, vector 0 */
    ret                           /* not reached */

/* ==================================================================
 * M4: CPUID.
 *
 * uint64_t cpu_probe(void)
 *
 * Fills core/boot/kdata.S's 64-byte `cpu_info` block -- 12-byte vendor at +0,
 * 48-byte brand at +16 -- and returns
 *
 *     (highest extended leaf << 32) | (highest standard leaf)
 *
 * ONE routine and ONE return value rather than two of each, because every
 * extra entry point is another `@extern external` declaration on the DCDart
 * side, and both numbers fall out of CPUID calls this has to make anyway.
 *
 * WHY THE STRINGS GO THROUGH MEMORY. An extern signature is scalars only
 * (DCDart GAP-0025), and `@bare` DCDart has no String and no array type, so a
 * 12-byte vendor string cannot be RETURNED in any form -- not as a value, not
 * as a pointer, not as two `u64`s the caller could reassemble into something
 * printable, because there would be nothing to reassemble it INTO. Donated
 * .bss plus an address accessor is the only shape available. GAP-0061.
 *
 * RBX is callee-saved in System V AMD64 and `cpuid` clobbers it, so it is
 * pushed and popped. R8/R9 are caller-saved and free.
 * ================================================================== */
.align 16
.global cpu_probe
.type cpu_probe, @function
cpu_probe:
    pushq %rbx
    leaq cpu_info(%rip), %r8

    /* Leaf 0: EAX = highest standard leaf, EBX:EDX:ECX = "GenuineIntel" order */
    xorl %eax, %eax
    xorl %ecx, %ecx
    cpuid
    movl %ebx, 0(%r8)
    movl %edx, 4(%r8)
    movl %ecx, 8(%r8)
    movl $0, 12(%r8)              /* NUL pad: the vendor is 12 bytes, not 16 */
    movl %eax, %r9d               /* stash the standard limit across the rest */

    /* Leaf 0x80000000: EAX = highest extended leaf. The brand string lives in
     * 0x80000002..4 and does not exist on every CPU, so it is asked for rather
     * than assumed. */
    movl $0x80000000, %eax
    xorl %ecx, %ecx
    cpuid
    movl %eax, %r10d              /* extended limit */
    cmpl $0x80000004, %eax
    jb cpu_probe_no_brand

    movl $0x80000002, %eax
    xorl %ecx, %ecx
    cpuid
    movl %eax, 16(%r8)
    movl %ebx, 20(%r8)
    movl %ecx, 24(%r8)
    movl %edx, 28(%r8)
    movl $0x80000003, %eax
    xorl %ecx, %ecx
    cpuid
    movl %eax, 32(%r8)
    movl %ebx, 36(%r8)
    movl %ecx, 40(%r8)
    movl %edx, 44(%r8)
    movl $0x80000004, %eax
    xorl %ecx, %ecx
    cpuid
    movl %eax, 48(%r8)
    movl %ebx, 52(%r8)
    movl %ecx, 56(%r8)
    movl %edx, 60(%r8)
    jmp cpu_probe_done

    /* No brand leaves: NUL the whole 48 bytes so the DCDart side prints an
     * empty brand rather than whatever the loader left in .bss. Writing
     * nothing at all would be the one way this could put garbage on a screen. */
cpu_probe_no_brand:
    xorl %ecx, %ecx
cpu_probe_blank:
    movb $0, 16(%r8,%rcx,1)
    incl %ecx
    cmpl $48, %ecx
    jb cpu_probe_blank

cpu_probe_done:
    movl %r9d, %eax               /* low  32: highest standard leaf */
    shlq $32, %r10
    orq %r10, %rax                /* high 32: highest extended leaf */
    popq %rbx
    ret

/* ==================================================================
 * M8 (docs/decisions/0012-paging-and-w-xor-x.md): the control registers, and
 * the two instruction-fetch probes.
 *
 * WHY HERE AND NOT IN A FIFTH OBJECT FILE. `portio.S` set the precedent that a
 * missing primitive can get its own file when it is a MISSING LANGUAGE
 * PRIMITIVE standing in for itself. These are not that. They are the same
 * category this file already exists for and states in its header: "privileged
 * or control-flow instructions with no DCDart primitive", called from DCDart
 * through the C ABI. `cpu_probe` (CPUID) is already here on exactly that
 * argument, and `cr2_read` in particular belongs beside `isr_common` because
 * the page-fault handler is the only thing that reads it. A fifth object file
 * would have to be threaded through build-kernel.sh and eight harnesses to say
 * something this file's header already says.
 *
 * WHY DCDART CANNOT DO ANY OF IT: `mov %cr3,%reg` and `mov %reg,%cr3` are
 * privileged and have no DCDart primitive; CR2 is not addressable memory;
 * and an indirect call through a computed address is a function pointer, which
 * DCDart has none of (the same absence that makes `isrDispatch` a branch chain
 * and `shellExecute` an if-chain).
 * ================================================================== */

/* uint64_t cr3_read(void) -- the physical address of the live PML4.
 *
 * Read back rather than remembered, so `vm` reports what the CPU is ACTUALLY
 * using rather than what vm.dart believes it installed. The harness compares
 * this against QEMU's own `info registers` CR3, which is a third opinion. */
.align 16
.global cr3_read
.type cr3_read, @function
cr3_read:
    movq %cr3, %rax
    ret

/* uint64_t cr0_read(void) -- CR0, so `vm` can print WP back off the register.
 *
 * CR0.WP (bit 16) is the difference between a read-only page-table entry that
 * the CPU obeys and one it ignores for ring-0 stores. `boot.S` sets it; this is
 * how the report proves it rather than asserting it. See boot.S's CR0 write for
 * the measurement that made this necessary. */
.align 16
.global cr0_read
.type cr0_read, @function
cr0_read:
    movq %cr0, %rax
    ret

/* uint64_t cr4_read(void) -- M11.
 *
 * Read for three bits: PAE (5), OSFXSR (9) and OSXMMEXCPT (10). `sse_enabled()`
 * reports what boot.S DECIDED; this reports what the CPU is actually holding,
 * and `proc` prints both. They are not the same claim -- the first is a word in
 * `.bss` that the stub wrote, the second is the control register -- and a
 * milestone whose whole first third is "set two CR4 bits" has no business
 * asserting the register's contents from a memory flag.
 *
 * Same discipline `cr0_read` gives WP and `cr3_read` gives the PML4. */
.align 16
.global cr4_read
.type cr4_read, @function
cr4_read:
    movq %cr4, %rax
    ret

/* void fx_save(uint64_t area) -- M11. `fxsave (%rdi)`.
 *
 * Writes 512 bytes of x87 + SSE state -- the control/status/tag words, the
 * eight x87 registers, MXCSR, and all sixteen XMM registers -- to [area].
 *
 * THE ADDRESS MUST BE 16-BYTE ALIGNED. `fxsave` on a misaligned operand is a
 * #GP, not a slow path, and it is the caller's job: `core/kernel/proc.dart`
 * hands an offset into a `.align 16` block in kdata.S and
 * `tests/conformance/m11-proc/run.sh` reads the alignment out of the linked
 * image rather than trusting the directive.
 *
 * IT IS ALSO A #UD ON A CPU WITHOUT FXSR, which is why every caller checks
 * `sse_enabled()` first. That is not defensive decoration -- it is the same
 * probe-before-you-use rule `nx_enabled()` exists for (M8), applied to the
 * instruction rather than to the page-table bit. */
.align 16
.global fx_save
.type fx_save, @function
fx_save:
    fxsave (%rdi)
    ret

/* void fx_restore(uint64_t area) -- M11. `fxrstor (%rdi)`.
 *
 * The inverse, and the more dangerous of the two: `fxrstor` raises #GP if the
 * MXCSR image in the area has any RESERVED bit set (anything outside
 * 0x0000FFFF & ~0x003F's mask, in practice bits above 15). A save area built
 * from allocator litter would therefore be a #GP in the middle of a context
 * switch. `procFxInit` writes MXCSR 0x1F80 into every area before any process
 * can run, and never lets an area exist that was not either initialised or
 * written by `fxsave` itself. */
.align 16
.global fx_restore
.type fx_restore, @function
fx_restore:
    fxrstor (%rdi)
    ret

/* uint64_t cr2_read(void) -- the linear address that caused the last #PF.
 *
 * The CPU writes CR2 on every page fault and nothing else touches it, so it is
 * still valid when the DCDart handler runs. It must be read BEFORE any further
 * page fault, which is why the handler's own diagnostic never dereferences an
 * address it has not bounds-checked -- a fault inside the fault handler would
 * overwrite the value being reported and then double-fault. */
.align 16
.global cr2_read
.type cr2_read, @function
cr2_read:
    movq %cr2, %rax
    ret

/* void paging_install(uint64_t pml4_physical) -- THE SWITCH.
 *
 * One instruction, and it is the most dangerous instruction in this kernel: if
 * the table at `pml4_physical` does not map the very next instruction, the
 * stack RSP points at, and the code that returns to the caller, the machine
 * triple-faults and QEMU reboots with no diagnostic at all. `vm.dart` checks
 * every one of those before calling this (see `vmSelfCheck`).
 *
 * Writing CR3 also flushes every non-global TLB entry, which is why nothing
 * here has to invalidate anything: there are no global pages in either table
 * (PGE is never enabled) so the entire old mapping is gone the moment this
 * returns. `invlpg` and TLB shootdown belong to the milestone that changes a
 * mapping while it is live; this one only ever installs a whole address space
 * once. docs/known-gaps.md GAP-0083.
 *
 * The `ret` immediately after is itself the first proof the switch worked: the
 * return address is on the stack and points into `.text`, so if either were
 * unmapped this function could not get back to DCDart. */
.align 16
.global paging_install
.type paging_install, @function
paging_install:
    movq %rdi, %cr3
    ret

/* uint64_t vm_exec_probe(uint64_t addr) -- CALL THROUGH AN ADDRESS.
 *
 * `vmtest nx`'s whole mechanism. An instruction fetch from `addr` either
 * happens or raises #PF with the instruction-fetch bit set in the error code;
 * there is no third outcome, and the difference between the two is exactly
 * what a non-executable page means.
 *
 * A `call` and not a `jmp`, so that a target which DOES return (see
 * `vm_exec_ok` below) comes back here and this function can return normally.
 * The return value is 1 -- "the fetch happened" -- which the caller only ever
 * observes when the page was executable, because otherwise the #PF never comes
 * back to this frame at all (the fault handler abandons the stack).
 *
 * IT IS NOT AN ARBITRARY-CODE PRIMITIVE and must not become one. `vm.dart`
 * passes it exactly two addresses: `vm_exec_ok`, and the address of a
 * `@rodata` table. Both are in this image and both are known. */
.align 16
.global vm_exec_probe
.type vm_exec_probe, @function
vm_exec_probe:
    pushq %rbx                    /* keeps RSP 16-byte aligned at the `call`:
                                   * it is 8 (mod 16) on entry, and one push
                                   * makes it 0 (mod 16), which is what the
                                   * System V AMD64 ABI requires. RBX is
                                   * callee-saved, so pushing it is free and
                                   * correct rather than merely convenient. */
    movq $1, %rbx
    call *%rdi                    /* the instruction fetch under test */
    movq %rbx, %rax
    popq %rbx
    ret

/* void vm_exec_ok(void) -- a single `ret`, and nothing else, in `.text`.
 *
 * THE CONTROL FOR `vmtest nx`. Handing `vm_exec_probe` an address on an
 * executable page must NOT fault; handing it an address on a `.rodata` page
 * must. Without this half, "the indirect call faulted" would be equally
 * consistent with "indirect calls fault", which proves nothing about page
 * permissions. It is in `.text` because that is the section under test. */
.align 16
.global vm_exec_ok
.type vm_exec_ok, @function
vm_exec_ok:
    ret

/* uint64_t vm_exec_ok_addr(void) -- the address of the `ret` above, as DATA.
 *
 * The same pivot `isr_stub_table_addr` is: DCDart cannot name a code symbol,
 * so a code address has to be handed to it as an ordinary integer. */
.align 16
.global vm_exec_ok_addr
.type vm_exec_ok_addr, @function
vm_exec_ok_addr:
    leaq vm_exec_ok(%rip), %rax
    ret

/* ==================================================================
 * M9 (docs/decisions/0013-ring-3-and-the-syscall-boundary.md): THE PRIVILEGE
 * BOUNDARY. Four routines, and every one of them is something DCDart cannot
 * express in the strict sense this file's header means:
 *
 *   tr_read       `str` -- reads the task register, which DCDart cannot name.
 *   enter_user    writes SS:RSP:RFLAGS:CS:RIP onto the stack and executes
 *                 `iretq`. DCDart cannot write a segment register, cannot
 *                 construct a stack frame, and has no `iretq`.
 *   user_return   sets RSP to a recorded value and returns onto a stack whose
 *                 frames belong to a different call. Same category as
 *                 `fault_resume` above, and it is a deliberate sibling of it.
 *   tlb_invlpg    `invlpg` -- privileged, no DCDart primitive.
 *
 * WHY NOT `syscall`/`sysret`. `int 0x80` needs one IDT gate whose DPL this
 * kernel already knows how to write, and it lands in `isr_common`, which
 * already saves all fifteen registers into the frame a DCDart handler reads.
 * `syscall` needs three MSRs, a stack switch this kernel would have to write
 * itself (SYSCALL does not change RSP), and a separate entry path. It is
 * faster and it is a different milestone -- ADR-0013 §8.
 * ================================================================== */

/* M9: the resume point the `exit` syscall returns to, in core/boot/kdata.S.
 * Written from here because DCDart cannot read RSP -- the same reason
 * `shell_resume_rsp` is written from `shell_run_forever` above. */
.extern user_resume_rsp
.extern user_resume_ok

/* uint64_t tr_read(void) -- `str`, the task register's current selector.
 *
 * Read BACK rather than remembered, the same discipline `cr0_read` and
 * `cr3_read` follow: `user pages` prints what the CPU is actually using as its
 * TSS, so the report says the task register was loaded rather than that
 * `tss_load` was called. Zero here means `ltr` never ran, and zero is exactly
 * what the register holds after reset. */
.align 16
.global tr_read
.type tr_read, @function
tr_read:
    xorl %eax, %eax               /* `str` writes only the low 16 bits */
    str %ax
    ret

/* void enter_user(uint64_t rip, uint64_t rsp, uint64_t arg,
 *                 uint64_t cs, uint64_t ss)  -- DOES NOT RETURN NORMALLY.
 *
 * The transition. `iretq` is the only instruction that lowers CPL on this
 * machine without `sysret`, and it does it by loading CS from the stack: the
 * new CPL is that descriptor's DPL. Everything below is the frame `iretq`
 * consumes, pushed in the order it pops.
 *
 *     rsp+32  SS       user data selector, RPL 3
 *     rsp+24  RSP      the payload's own stack, in ITS page
 *     rsp+16  RFLAGS   0x202
 *     rsp+8   CS       user code selector, RPL 3
 *     rsp+0   RIP      the payload's first instruction
 *
 * RFLAGS = 0x202 IS THREE DECISIONS, not a magic number:
 *   bit 1  reserved, and it must be 1. A zero here is not ignored.
 *   bit 9  IF -- INTERRUPTS STAY ENABLED IN RING 3, on purpose. A payload that
 *          ran with interrupts off would never exercise RSP0, which is the one
 *          field of the TSS this kernel fills and the one whose absence
 *          triple-faults. With IF set, a timer or keyboard IRQ taken while the
 *          payload is running is delivered on the ring-0 stack and `iretq`s
 *          back to ring 3 -- the mechanism working, unprompted.
 *   bits 12-13  IOPL = 0. `in`/`out` from CPL 3 is therefore a #GP, and the
 *          TSS has no I/O permission bitmap to override it.
 *
 * THE REGISTER SCRUB IS NOT TIDINESS. Whatever is in a register at the moment
 * of the `iretq` is readable by the payload, and at this point the registers
 * hold kernel addresses -- the return address, the frame this function was
 * called with, pointers into donated `.bss`. Ring 3 is supposed to know nothing
 * it was not handed. Every general-purpose register is zeroed and exactly one,
 * RDI, is given the argument, which is the only channel in.
 *
 * The resume point is recorded FIRST, before `cli`, because `user_return`
 * cannot be reached until the payload makes a syscall and the payload cannot
 * run until the `iretq` below. */
.align 16
.global enter_user
.type enter_user, @function
enter_user:
    movq %rsp, user_resume_rsp(%rip)
    movq $1, user_resume_ok(%rip)
    cli                           /* RSP is about to stop describing this stack
                                   * for the interrupted-from-ring-3 case; an
                                   * IRQ in the middle of building the frame
                                   * would push into the middle of it */
    movq %rdi, %r9                /* rip */
    movq %rsi, %r10               /* user rsp */
    movq %rdx, %r11               /* arg -> the payload's RDI */

    movq %r8, %rax                /* the user data selector */
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs

    pushq %r8                     /* SS     */
    pushq %r10                    /* RSP    */
    pushq $0x202                  /* RFLAGS */
    pushq %rcx                    /* CS     */
    pushq %r9                     /* RIP    */

    movq %r11, %rdi               /* the one thing ring 3 is told */
    xorl %eax, %eax
    xorl %ebx, %ebx
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    xorl %ebp, %ebp
    xorl %r8d, %r8d
    xorl %r9d, %r9d
    xorl %r10d, %r10d
    xorl %r11d, %r11d
    xorl %r12d, %r12d
    xorl %r13d, %r13d
    xorl %r14d, %r14d
    xorl %r15d, %r15d
    iretq                         /* CPL 0 -> CPL 3 */

/* void user_return(void) -- NEVER RETURNS TO ITS CALLER.
 *
 * The `exit` syscall's second half. Called by the DCDart syscall handler while
 * it is still running in interrupt context on the RING-0 stack, having decided
 * the payload is finished. It abandons that stack -- the interrupt frame, the
 * handler's frames, everything the syscall was standing on -- and RETURNS INTO
 * `shellUser`, at the instruction after its `call enter_user`.
 *
 * This is `fault_resume`'s shape with one deliberate difference: it is not a
 * recovery. Nothing went wrong, the payload ran to completion, and the shell
 * command that started it gets to print what happened and clean up. That is why
 * it `ret`s rather than calling `shellMain`: the frame it returns to is still
 * live and still wants to run.
 *
 * SS IS RELOADED BECAUSE THE CPU NULLED IT. On an interrupt from CPL 3 in long
 * mode the processor loads SS with the null selector; that is legal at CPL 0
 * and the kernel has been running that way since the `int 0x80`, but leaving it
 * null after this point would mean the shell ran with a null stack segment for
 * the rest of the boot for no reason. DS/ES/FS/GS still hold the ring-3 data
 * selector `enter_user` put there, which is equally harmless in long mode and
 * equally worth not leaving behind.
 *
 * THE GUARD IS THE SAME GUARD `fault_resume` HAS, and for the same reason:
 * `.bss` is not zeroed by anything in this kernel, so `user_resume_rsp` is
 * garbage until `enter_user` writes it, and loading garbage into RSP triple-
 * faults the machine. `userInit()` clears the flag at the top of `kmain()`. */
.align 16
.global user_return
.type user_return, @function
user_return:
    cli
    cmpq $1, user_resume_ok(%rip)
    jne halt_forever
    movq $0, user_resume_ok(%rip)
    movw $0x10, %ax               /* the kernel data selector, gdt64_data */
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    movq user_resume_rsp(%rip), %rsp
    ret

/* void resume_user(uint64_t frame, uint64_t ss) -- DOES NOT RETURN NORMALLY.
 *
 * D3: re-enter ring 3 from a 22-word saved interrupt frame WITHOUT replacing
 * the resume point `enter_user` records. `enter_user` is the first-entry
 * door: it scrubs registers and starts at a RIP. A resident process that has
 * already run has a saved frame, and loading that frame through `enter_user`
 * would restart it. This function copies the 22 words onto the ring-0 stack
 * and takes the same pop/`iretq` path `isr_common` does.
 *
 * THE RESUME POINT IS RECORDED FIRST, at this function's own RSP, so
 * `user_return` `ret`s into the caller (the shell idle loop) rather than
 * into the copied frame. Same order `enter_user` uses, for the same reason.
 *
 * `ss` is the user data selector, loaded into DS/ES/FS/GS the way
 * `enter_user` loads them: whatever is in those registers at the `iretq` is
 * what ring 3 sees. */
.align 16
.global resume_user
.type resume_user, @function
resume_user:
    movq %rsp, user_resume_rsp(%rip)
    movq $1, user_resume_ok(%rip)
    cli
    movq %rsi, %rax               /* user data selector */
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    cld
    movq %rdi, %rsi               /* source: 22-word saved frame */
    subq $176, %rsp
    movq %rsp, %rdi
    movq $22, %rcx
    rep movsq
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    addq $16, %rsp                /* drop vector + error code */
    iretq

/* void proc_idle_gate(void) -- tail-calls procIdle.
 *
 * D3: shellMain must not inline the resident-slot walk. DCDart's overflow
 * checks live in callee-saved registers; an inlined walk next to the prompt
 * printer #UD's (vector 6, opcode 0F0B) the moment those registers are
 * leftover-nonzero. An @extern call cannot be inlined. */
.extern procIdle
.align 16
.global proc_idle_gate
.type proc_idle_gate, @function
proc_idle_gate:
    jmp procIdle

/* void kbd_drain_gate(void) -- tail-calls kbdqDrainToShell.
 *
 * D2: shellMain must not inline the queue walk. Same overflow-check #UD
 * as proc_idle_gate (ADR-0053). An @extern call cannot be inlined. */
.extern kbdqDrainToShell
.align 16
.global kbd_drain_gate
.type kbd_drain_gate, @function
kbd_drain_gate:
    jmp kbdqDrainToShell

/* void tlb_invlpg(uint64_t va) -- invalidate one page's TLB entries.
 *
 * docs/known-gaps.md GAP-0083 said this becomes necessary "the moment anything
 * EDITS a live mapping", and M9 is that moment: `user` gives two already-mapped
 * pages new permission bits while the CPU is running on the table they are in.
 * Without this the CPU may keep using a cached translation that says
 * supervisor-only, and the payload's first instruction fetch would fault for a
 * reason that no longer exists in the tables.
 *
 * ONE PAGE, NOT A CR3 RELOAD. Rewriting CR3 flushes everything and would also
 * work; `invlpg` is what the edit actually needs, it says which page changed,
 * and it does not throw away the other 1600 translations to change two. The
 * shootdown half of GAP-0083 -- an IPI to other CPUs -- is still absent and
 * still needs a second CPU to matter. */
.align 16
.global tlb_invlpg
.type tlb_invlpg, @function
tlb_invlpg:
    invlpg (%rdi)
    ret

/* void msr_write(uint64_t msr, uint64_t value) -- ADR-0148.
 *
 * One `wrmsr`: ECX = MSR index, EDX:EAX = value. Scoped for
 * IA32_FS_BASE (the TLS door). Not general MSR access from ring 3.
 * `boot.S` already uses rdmsr/wrmsr for EFER; this is the same
 * privilege, exposed as one C-ABI stub so DCDart can plant FS.base
 * on switch without opening a second MSR path. */
.align 16
.global msr_write
.type msr_write, @function
msr_write:
    movl %edi, %ecx
    movq %rsi, %rax
    movq %rsi, %rdx
    shrq $32, %rdx
    wrmsr
    ret

/* ==================================================================
 * The stub address table.
 *
 * `isr_stubs + (n * 16)` is a link-time constant expression over one symbol
 * plus a constant -- an ordinary relocation with an addend, not the kind of
 * symbol arithmetic (shifts, bit-field deposits) that ELF relocations cannot
 * express.
 * ================================================================== */
.section .rodata
.align 8
isr_stub_table:
.set isr_i, 0
.rept 256
    .quad isr_stubs + (isr_i * 16)
.set isr_i, isr_i + 1
.endr

/* Mark the stack non-executable (see kdata.S for the full note). */
.section .note.GNU-stack,"",@progbits
