/* core/boot/kdata.S
 *
 * oscortex_core M2/M3: DONATED MUTABLE STORAGE.
 *
 * WHY THIS FILE EXISTS (and why it is not a design choice)
 * ------------------------------------------------------------------
 * DCDart has no mutable static data of ANY kind. `@rodata` (DCDart ADR-0040)
 * gives read-only tables and nothing else; there is no `static`, no global,
 * no `var` outside a function body. Every byte of kernel state that must
 * outlive a call therefore has to be donated by assembly and reached from
 * DCDart through a `u64` address — exactly the pattern `isr.S` already uses
 * for the IDT and the tick counter (ADR-0002), and recorded as a real
 * language gap in docs/known-gaps.md (GAP-0004 item 1, GAP-0053).
 *
 * M1 could hide that inside isr.S, because the only state it needed WAS
 * interrupt state. M2's console cursor is not interrupt state, and putting it
 * in isr.S would have made "the interrupt file" quietly mean "the file where
 * we keep globals." A separate file named for what it is keeps the workaround
 * legible, and keeps the count of donated words visible in one place: when
 * DCDart grows mutable statics, this whole file is what gets deleted.
 *
 * NOT ZEROED HERE. `.bss` is not cleared by anything in this kernel — boot.S
 * zeroes only the three page-table pages, by explicit address range. Every
 * word below is initialized by DCDart through its address before first use
 * (`vgaInit()` for the cursor, `m2Enter()` for the phase word, `shellInit()`
 * for the whole M3 block). Assuming `.bss` is zero would be a real bug on
 * this kernel, not a portability nit.
 *
 * SIZE, AND WHY IT IS TRACKED. M5 adds 32 bytes for the framebuffer console's
 * state (base, pitch, cursor column, cursor row), taking the total to **424**.
 * M5's OTHER subsystem, PCI enumeration, added zero -- it prints as it walks
 * and retains nothing -- so the 32 bytes are precisely the cost of a console
 * having a cursor. `tests/conformance/m5-pci/run.sh` asserts the total.
 *
 * M7 TAKES IT TO 5096, AND THAT IS THE MILESTONE THIS FILE WAS WAITING FOR.
 * `pmm_store` (below) is 4672 bytes -- a 4KiB frame bitmap, 64 bytes of
 * allocator metadata and a 512-byte self-test ledger -- which is eleven times
 * everything M2 through M6 donated put together. It is deliberately ONE symbol
 * behind ONE accessor, so that when DCDart grows mutable statics the migration
 * is a three-function change in core/kernel/pmm.dart rather than a rewrite of
 * the allocator; the block's own comment states that as a rule.
 * `tests/conformance/m7-frames/run.sh` asserted the 5096 total and owned it
 * until M8; it now asserts 5096 EXCLUDING `vm_store`, which is the same claim
 * stated so that a later milestone cannot dilute it.
 *
 * M8 TAKES IT TO 5224. `vm_store` (below) is 128 bytes -- sixteen words for the
 * virtual-memory subsystem: the PML4 it built, the six frames it took from the
 * allocator, the page counts it mapped, the page-fault it last reported, and
 * one deliberately WRITABLE scratch word that exists so `vmtest rw` can be the
 * control for `vmtest ro`. It is ONE symbol behind ONE accessor called from ONE
 * function, which is the tightest storage seam in this kernel;
 * `tests/conformance/m8-paging/run.sh` asserts the 5224 total and owns it now.
 *
 * M9 TAKES IT TO 5368. `user_store` (below) is 128 bytes -- sixteen words for the
 * ring-3 subsystem: which payload is loaded, the two frames it is running in,
 * the CS/SS/RFLAGS the CPU pushed on its last syscall, the counters, and the
 * canary word `user pf` aims at and must not reach. It is ONE symbol behind ONE
 * accessor called from ONE function, the same seam `vm_store` uses.
 * `user_resume_rsp` and `user_resume_ok` add 16 more and are DIFFERENT IN KIND:
 * they hold a stack pointer and its guard, DCDart cannot read or write RSP, and
 * they will still be assembly-owned on the day DCDart grows mutable statics --
 * exactly like M4's `shell_resume_rsp`. `tests/conformance/m9-ring3/run.sh`
 * asserts the 5368 total and owns it now.
 *
 * M6 ADDS NOTHING, AND THAT WAS A CHOICE RATHER THAN AN ABSENCE OF NEED.
 * An ATA PIO driver's obvious shape is `read(lba, buffer)` and the buffer is
 * 512 bytes, which would have taken this file from 424 to 936 -- more than
 * doubling in one milestone, for one command. core/kernel/ata.dart hexdumps
 * each 16-bit word as it arrives off the data port instead, so there is no
 * sector buffer anywhere in this kernel. The cost is that the driver can SHOW
 * you a sector and cannot GIVE you one (docs/known-gaps.md GAP-0074 item 1).
 * `tests/conformance/m6-disk/run.sh` asserts that this total did NOT move.
 *
 * M2 donated 16 bytes (two words). M3's line
 * editor needs a BUFFER, and DCDart has no array type either, so the total went
 * to 304 bytes: 16 + 256 (line buffer) + 8 (length) + 8 (shell state) + 8
 * (Multiboot pointer copy) + 8 (0xE0-prefix flag). M4 adds 88 more — 64 for the
 * CPUID result strings, and 24 for the three words fault recovery needs — so
 * the total is 392 at M4 and **424** at M5 (see above).
 * `tests/conformance/m4-fault/run.sh` and `m5-pci/run.sh` assert their own
 * milestone's number exactly, so it moves only as a deliberate edit — it is the running
 * measure of what DCDart's missing mutable statics cost downstream
 * (docs/known-gaps.md GAP-0053).
 *
 * WHO WRITES WHAT, at M4. Every word through `kbd_prefix` is written only by
 * DCDart, through the accessors below. The M4 block is the first that is
 * written by ASSEMBLY as well: `cpu_info` is filled by `cpu_probe` in isr.S
 * (DCDart cannot execute `cpuid`), and `shell_resume_rsp`/`shell_resume_ok` are
 * written by `shell_run_forever` in isr.S (DCDart cannot read RSP). DCDart
 * still initializes them, and that ordering is what makes the recovery guard
 * mean anything — see `shell_resume_ok` below.
 */

/* ==================================================================
 * Storage.
 * ================================================================== */
.section .bss

/* VGA text-console cursor, as a LINEAR CELL INDEX (row * 80 + column), not a
 * row/column pair — one word is one store, and every operation the console
 * performs (advance, newline, backspace, scroll) is arithmetic on the linear
 * index. Range 0..1999 for an 80x25 screen; core/kernel/vga.dart maintains
 * that invariant and is the only writer.
 *
 * Initialized by vgaInit(). */
.align 8
vga_cursor:
    .skip 8
    .size vga_cursor, 8
    .type vga_cursor, @object

/* M2 phase word. 0 = M2 has not been entered; 1 = it has.
 *
 * Load-bearing, not bookkeeping: M2 is entered from the FAULT path of
 * isrDispatch (M1's last act is a deliberate #UD, and a fault handler cannot
 * `iretq` back to a faulting instruction — see core/kernel/vga.dart's
 * m2Enter). That path is also where a genuine, unexpected fault during M2
 * would land, so without this word a fault inside the console would re-enter
 * the console recursively instead of stopping. Initialized by m2Enter()
 * itself, whose first act is to read it. */
.align 8
m2_phase:
    .skip 8
    .size m2_phase, 8
    .type m2_phase, @object

/* ------------------------------------------------------------------
 * M3 (ADR-0006): the shell's state.
 *
 * This is the block that turned GAP-0053 from "awkward" into "expensive."
 * M2 needed two words; a line editor needs a BUFFER, and there is no way to
 * spell one in DCDart at all -- no array type, no mutable static, no
 * allocator. 256 bytes of assembly-donated .bss is what `static u8
 * line[256];` costs in this language today.
 *
 * Every word here is initialized by shellInit() through its address, called
 * from kmain() alongside vgaInit(). .bss is NOT zeroed by anything in this
 * kernel: a garbage shell_len would make the first keystroke store hundreds
 * of bytes past the end of the buffer, and a garbage kbd_prefix would swallow
 * the first real key.
 * ------------------------------------------------------------------ */

/* Current line buffer. Holds the bytes typed since the last Enter, WITHOUT
 * the prompt and without the terminating newline -- the prompt is screen
 * output, not part of the line, which is exactly why backspace cannot erase
 * it (core/kernel/shell.dart's shellKey stops at length 0). */
.align 8
shell_line:
    .skip 256
    .size shell_line, 256
    .type shell_line, @object

/* Number of valid bytes in shell_line, 0..256. */
.align 8
shell_len:
    .skip 8
    .size shell_len, 8
    .type shell_len, @object

/* Shell state: 0 = accepting input, 1 = a line was submitted and is waiting
 * to run, 2 = a command is running.
 *
 * State 2 is not bookkeeping. Commands run in TASK context with interrupts
 * enabled, so an IRQ1 can arrive in the middle of one; without a state the
 * handler would append to shell_line and bump shell_len while shellExecute
 * was walking them. The cost is that type-ahead during a command is dropped
 * -- there is still no input queue (GAP-0055 item 4). */
.align 8
shell_state:
    .skip 8
    .size shell_state, 8
    .type shell_state, @object

/* The Multiboot1 information-structure pointer, copied here by shellInit()
 * from the argument boot.S passes to kmain().
 *
 * A COPY rather than an accessor for boot.S's own stash, deliberately:
 * exporting multiboot_info_ptr and taking its address from here would give
 * kdata.o an undefined symbol, and kdata.o passing verify-freestanding.sh
 * standalone is a documented property (docs/known-gaps.md GAP-0056). Eight
 * bytes is the price of keeping it. */
.align 8
shell_mbinfo:
    .skip 8
    .size shell_mbinfo, 8
    .type shell_mbinfo, @object

/* "The previous scancode was 0xE0." One word for a one-byte state machine,
 * because a word is the smallest thing an accessor can hand back cleanly.
 *
 * This closes GAP-0055 item 2, which was a WRONG behaviour rather than a
 * missing one: extended keys (arrows, right-hand modifiers, keypad Enter)
 * send 0xE0 and then an ordinary-looking make code in a second interrupt. The
 * driver used to ignore the 0xE0 and then translate its follower as if it
 * were a normal key, so the up arrow (0xE0 0x48) typed `8`. */
.align 8
kbd_prefix:
    .skip 8
    .size kbd_prefix, 8
    .type kbd_prefix, @object

/* ------------------------------------------------------------------
 * M4 (ADR-0007): CPUID results, and the fault-recovery resume point.
 * ------------------------------------------------------------------ */

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

/* How many faults the kernel has caught and RECOVERED from since boot.
 *
 * Incremented by the DCDart fault handler and printed by shellRecover(), so
 * `FAULT RECOVERED 0002` is a count the kernel kept rather than a constant it
 * prints. M1's own boot-time deliberate #UD is NOT counted: it is not
 * recovered from, it is the event that brings the console up. */
.align 8
fault_count:
    .skip 8
    .size fault_count, 8
    .type fault_count, @object

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

/* ------------------------------------------------------------------
 * M5 (ADR-0009): the framebuffer console's state.
 * ------------------------------------------------------------------ */

/* Linear-framebuffer console state, as ONE 32-byte block:
 *
 *     +0   u64  base physical address of the framebuffer, or 0 = none
 *     +8   u64  bytes per scanline (pitch)
 *     +16  u64  cursor column, in 8-pixel glyph cells
 *     +24  u64  cursor row, in 16-pixel glyph cells
 *
 * ONE block with fixed offsets rather than four symbols with four accessors,
 * for the reason cpu_info's own comment gives: each accessor is another
 * `@extern external` declaration on the DCDart side and another `leaq` here.
 *
 * A base address of 0 is the "no framebuffer" state and EVERY writer checks
 * it, which is why fbInit() zeroing this block is a correctness requirement
 * and not hygiene: .bss is not zeroed by anything in this kernel, so a garbage
 * base would make the first glyph blit scatter 32-bit stores across memory at
 * an address nothing chose.
 *
 * THIS IS 32 OF THE 424 DONATED BYTES, and it is the first growth since M4.
 * PCI enumeration (ADR-0008) added none because it retains nothing; a console
 * has a cursor and cannot. docs/known-gaps.md GAP-0053. */
.align 8
fb_state:
    .skip 32
    .size fb_state, 32
    .type fb_state, @object

/* ------------------------------------------------------------------
 * M7 (ADR-0011): the physical memory manager's ENTIRE mutable state.
 *
 * ONE SYMBOL, ONE ACCESSOR, AND THAT IS THE WHOLE POINT.
 *
 * This block is 4672 bytes -- eleven times everything above it put together
 * -- and it is the block that a previous unit correctly argued should not be
 * built on this workaround, because doing so would make assembly-donated
 * `.bss` load-bearing for the kernel's most important subsystem and turn the
 * eventual DCDart mutable-statics fix into a rewrite.
 *
 * The answer is the shape rather than the wait. There is exactly ONE symbol
 * and exactly ONE accessor for the whole allocator, and `core/kernel/pmm.dart`
 * routes every read and write of every byte below through three functions
 * (`pmmBitmapBase`, `pmmMetaBase`, `pmmLedgerBase`) that call it. Nothing else
 * in the allocator knows this file exists. When DCDart grows mutable statics,
 * those three functions change and nothing else does -- which is a deletion,
 * not a rewrite, and is exactly the property that was at risk.
 *
 * WHAT MUST NOT HAPPEN, stated so it is a rule and not a hope: do not scatter
 * `@extern` address calls through the allocator. A second call site for
 * `pmm_store_addr` outside the seam is the moment the migration stops being a
 * three-function change.
 *
 * LAYOUT -- fixed offsets, the same "one block, no extra accessors" pattern
 * `cpu_info` and `fb_state` already use:
 *
 *     +0     4096 bytes  frame bitmap. One bit per 4KiB physical frame,
 *                        1 = in use or reserved, 0 = free. 4096 bytes is
 *                        32768 frames is 128MiB of RAM, which is also the
 *                        extent boot.S identity-maps -- see below.
 *     +4096    64 bytes  eight u64 words of metadata: ready flag, frames
 *                        managed, free count, baseline free count, the
 *                        allocation cursor, the count of usable frames ABOVE
 *                        the bound, the rejected-operation count, and the
 *                        lifetime allocation count.
 *     +4160   512 bytes  the self-test's allocation ledger: 64 physical
 *                        addresses. `frames test` allocates 64 frames and has
 *                        to hold them all at once to prove they are pairwise
 *                        distinct and to give every one of them back; there is
 *                        no array type and no allocator to ask (the allocator
 *                        IS what is being tested).
 *
 * WHY 128MiB AND NOT MORE. The bound has to be picked, not discovered, and
 * three things want to be the same number: the bitmap's size, the identity
 * map's extent, and the largest machine this kernel claims to manage. 4096
 * bytes of bitmap is exactly one page and exactly 128MiB of RAM at 4KiB
 * granularity, and boot.S maps exactly 128MiB (MAP_2MIB_PAGES = 64), so a
 * frame that is tracked is a frame that can be written. Raising it is
 * mechanical and costs `.bss` linearly: 4GiB would be 128KiB of bitmap and
 * 2048 page-directory entries.
 *
 * EXCEEDING IT IS LOUD, NOT SILENT. Usable frames above the bound are COUNTED
 * at init and reported by `frames` as `OVER nnnnnnnn CAPPED`; they are never
 * marked free, so they cannot be handed out.
 *
 * NOT ZEROED HERE -- the same rule as every word above. `pmmInit()` fills the
 * whole bitmap with 0xFF (everything reserved) before it frees anything, which
 * is the safe direction to be wrong in: a garbage bitmap read as free would
 * hand out the kernel's own image.
 *
 * `.global` because `tests/conformance/m7-frames/run.sh` reads this symbol's
 * LINK-TIME ADDRESS out of `kernel.elf` and compares it against the address the
 * kernel prints, then dumps the bitmap out of guest memory at that address and
 * checks it bit-for-bit against one the harness computes itself. The storage
 * seam is checked from outside rather than taken on the kernel's word.
 *
 * THIS TAKES DONATED `.bss` FROM 424 BYTES TO 5096. docs/known-gaps.md
 * GAP-0053 carries the running total and the reason.
 * ------------------------------------------------------------------ */
.align 8
.global pmm_store
pmm_store:
    .skip 4672
    .size pmm_store, 4672
    .type pmm_store, @object

/* ------------------------------------------------------------------
 * M8 (ADR-0012): the virtual-memory subsystem's ENTIRE mutable state.
 *
 * 128 bytes, sixteen `u64` words, ONE symbol, ONE accessor -- the same shape
 * `pmm_store` above uses and for the same reason, taken one step tighter:
 * `core/kernel/vm.dart` reaches this block through exactly ONE function
 * (`vmMetaBase`), which is the only place in the kernel that calls
 * `vm_store_addr`. `tests/conformance/m8-paging/run.sh` counts that call site
 * the way `m7-frames/run.sh` counts the allocator's three, and for the same
 * reason: it is what keeps the eventual DCDart mutable-statics migration a
 * one-function change instead of an audit.
 *
 * WHY IT IS SIXTEEN WORDS AND NOT FOUR. Words 0..9 are what the subsystem
 * needs; 10..15 are the page-table frame addresses it holds, which have to be
 * kept because they are the answer to a question the page allocator asks on
 * every `free` and every `frames refill`: "is this frame one the kernel's own
 * address space is standing on?" Before M8 the allocator's reserved set was
 * the memory map, the first megabyte and `[__kernel_start, __kernel_end)`; the
 * page tables are the first permanently-owned kernel memory that is NOT inside
 * the image, because they come out of `allocFrame()`. `pmmAllocatable` gained
 * one clause and `vm.dart` answers it from these six words.
 *
 * LAYOUT -- fixed offsets, the same "one block, no extra accessors" pattern
 * `cpu_info`, `fb_state` and `pmm_store` already use:
 *
 *     +0    u64  ready:      0 until the new CR3 is live, 1 after
 *     +8    u64  status:     why it refused, if it refused (a vmStatus* code)
 *     +16   u64  pml4:       physical address of the PML4 this kernel built
 *     +24   u64  frames:     how many frames the page tables consumed
 *     +32   u64  pages4k:    4KiB pages mapped
 *     +40   u64  pages2m:    2MiB pages mapped
 *     +48   u64  scratch:    `vmtest rw`'s target -- a WRITABLE word, so that
 *                            the control for the read-only test is a store of
 *                            exactly the same shape to a different page
 *     +56   u64  faults:     page faults reported since boot (vector 14 only)
 *     +64   u64  lastCr2:    the faulting address of the most recent one
 *     +72   u64  lastErr:    its error code
 *     +80.. u64  frame[0..5] the six page-table frames, in allocation order
 *
 * NOT ZEROED HERE -- the same rule as every word above. `vmInit()` writes all
 * sixteen before anything reads them, and it runs from `kmain()` before the
 * first byte of output.
 *
 * `.global` because `tests/conformance/m8-paging/run.sh` reads this symbol's
 * LINK-TIME ADDRESS out of `kernel.elf` and compares it against the address
 * the kernel prints, exactly as m7-frames does for `pmm_store`.
 *
 * THIS TAKES DONATED `.bss` FROM 5096 BYTES TO 5224. docs/known-gaps.md
 * GAP-0053 carries the running total and the reason. m5-pci, m6-disk and
 * m7-frames each still assert their own milestone's number by SUBTRACTING the
 * blocks that came after theirs, so no older claim is weakened by this.
 * ------------------------------------------------------------------ */
.align 8
.global vm_store
vm_store:
    .skip 128
    .size vm_store, 128
    .type vm_store, @object

/* ------------------------------------------------------------------
 * M9 (ADR-0013): the ring-3 subsystem's ENTIRE mutable state.
 *
 * 128 bytes, sixteen `u64` words, ONE symbol, ONE accessor -- `vm_store`'s
 * shape exactly, for `vm_store`'s exact reason. `core/kernel/user.dart` reaches
 * this block through ONE function (`userMetaBase`), the only place in the
 * kernel that calls `user_store_addr`, and
 * `tests/conformance/m9-ring3/run.sh` counts that call site.
 *
 * LAYOUT -- fixed offsets, the same "one block, no extra accessors" pattern
 * `cpu_info`, `fb_state`, `pmm_store` and `vm_store` already use:
 *
 *     +0    u64  live:       1 while a payload is executing in ring 3
 *     +8    u64  mode:       which payload is loaded (a userMode* code)
 *     +16   u64  codeFrame:  physical frame the payload's code is in, or 0
 *     +24   u64  stackFrame: physical frame the payload's stack is in, or 0
 *     +32   u64  entries:    ring-3 entries since boot
 *     +40   u64  syscalls:   syscalls serviced since boot
 *     +48   u64  lastCs:     the CS the CPU pushed on the last syscall. Its low
 *                            two bits ARE the CPL the payload was running at,
 *                            and reading them out of the interrupt frame is the
 *                            only honest way to know it
 *     +56   u64  lastSs:     likewise SS
 *     +64   u64  lastFlags:  likewise RFLAGS
 *     +72   u64  exitCode:   what the last `exit` syscall was given
 *     +80   u64  refusals:   syscalls the kernel REFUSED (a bad pointer, an
 *                            unknown number, a caller that was not in ring 3)
 *     +88   u64  written:    bytes accepted by the `write` syscall
 *     +96   u64  aborts:     payloads killed by a fault instead of exiting
 *     +104  u64  canary:     THE TARGET of `user pf`. A word in supervisor
 *                            `.bss` that ring 3 tries to store into and must
 *                            not reach. Its value is set before the attempt and
 *                            checked after, so "the store did not land" is a
 *                            comparison rather than the absence of a fault
 *     +112  u64  lastRip:    the RIP the CPU pushed on the last fault taken in
 *                            ring 3, so the report can say WHERE in the payload
 *     +120  u64  lastErr:    that fault's error code
 *
 * NOT ZEROED HERE -- the same rule as every word above. `userInit()` writes all
 * sixteen from `kmain()` before the first byte of output.
 *
 * THIS TAKES DONATED `.bss` FROM 5224 BYTES TO 5368: 128 here and 16 more in
 * the two asm-owned resume words below. docs/known-gaps.md GAP-0053 carries the
 * running total. m5-pci, m6-disk, m7-frames and m8-paging each still assert
 * their own milestone's number by SUBTRACTING the blocks that came after
 * theirs, so no older claim is weakened by this.
 * ------------------------------------------------------------------ */
.align 8
.global user_store
user_store:
    .skip 128
    .size user_store, 128
    .type user_store, @object

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

/* ==================================================================
 * C-ABI address accessors, called from DCDart via @extern (DCDart ADR-0038).
 *
 * RIP-relative `leaq`, not `movq $symbol`, for the same reason isr.S uses it:
 * `movq $sym,%reg` assembles to a `movabs` needing a 64-bit absolute
 * relocation, and this kernel links into an `elf32-i386` container (ADR-0001).
 *
 * These return an ADDRESS rather than taking or returning a `Pointer<T>`
 * because DCDart still forbids `Pointer<T>` in an extern signature
 * (DCDart GAP-0025).
 * ================================================================== */
.section .text
.code64

/* uint64_t vga_cursor_addr(void) */
.align 16
.global vga_cursor_addr
.type vga_cursor_addr, @function
vga_cursor_addr:
    leaq vga_cursor(%rip), %rax
    ret

/* uint64_t m2_phase_addr(void) */
.align 16
.global m2_phase_addr
.type m2_phase_addr, @function
m2_phase_addr:
    leaq m2_phase(%rip), %rax
    ret

/* uint64_t shell_line_addr(void) */
.align 16
.global shell_line_addr
.type shell_line_addr, @function
shell_line_addr:
    leaq shell_line(%rip), %rax
    ret

/* uint64_t shell_len_addr(void) */
.align 16
.global shell_len_addr
.type shell_len_addr, @function
shell_len_addr:
    leaq shell_len(%rip), %rax
    ret

/* uint64_t shell_state_addr(void) */
.align 16
.global shell_state_addr
.type shell_state_addr, @function
shell_state_addr:
    leaq shell_state(%rip), %rax
    ret

/* uint64_t shell_mbinfo_addr(void) */
.align 16
.global shell_mbinfo_addr
.type shell_mbinfo_addr, @function
shell_mbinfo_addr:
    leaq shell_mbinfo(%rip), %rax
    ret

/* uint64_t kbd_prefix_addr(void) */
.align 16
.global kbd_prefix_addr
.type kbd_prefix_addr, @function
kbd_prefix_addr:
    leaq kbd_prefix(%rip), %rax
    ret

/* uint64_t cpu_info_addr(void) -- base of the 64-byte CPUID block. Vendor at
 * +0 (12 bytes), brand at +16 (48 bytes). */
.align 16
.global cpu_info_addr
.type cpu_info_addr, @function
cpu_info_addr:
    leaq cpu_info(%rip), %rax
    ret

/* uint64_t fault_count_addr(void) */
.align 16
.global fault_count_addr
.type fault_count_addr, @function
fault_count_addr:
    leaq fault_count(%rip), %rax
    ret

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
.align 16
.global fb_state_addr
.type fb_state_addr, @function
fb_state_addr:
    leaq fb_state(%rip), %rax
    ret

/* uint64_t pmm_store_addr(void) -- base of the 4672-byte physical-memory-
 * manager storage block. Bitmap at +0 (4096 bytes), metadata at +4096 (64),
 * self-test ledger at +4160 (512).
 *
 * THE ENTIRE STORAGE SEAM FOR THE PAGE ALLOCATOR IS THIS ONE FUNCTION. It is
 * called from exactly three places, all of them in core/kernel/pmm.dart's
 * "storage seam" section. Adding a fourth call site anywhere else is the
 * change this design exists to prevent -- see the comment on `pmm_store`. */
.align 16
.global pmm_store_addr
.type pmm_store_addr, @function
pmm_store_addr:
    leaq pmm_store(%rip), %rax
    ret

/* uint64_t vm_store_addr(void) -- base of the 128-byte virtual-memory state
 * block. See `vm_store` above for the word layout.
 *
 * THE ENTIRE STORAGE SEAM FOR THE PAGE-TABLE BUILDER IS THIS ONE FUNCTION, and
 * it is called from exactly ONE place: `vmMetaBase()` in core/kernel/vm.dart.
 * Adding a second call site anywhere is the change this design exists to
 * prevent -- the same rule `pmm_store_addr` states, one call site tighter
 * because this block has one accessor's worth of structure rather than three.
 * `tests/conformance/m8-paging/run.sh` counts it. */
.align 16
.global vm_store_addr
.type vm_store_addr, @function
vm_store_addr:
    leaq vm_store(%rip), %rax
    ret

/* uint64_t user_store_addr(void) -- base of the 128-byte ring-3 state block.
 * See `user_store` above for the word layout.
 *
 * THE ENTIRE STORAGE SEAM FOR THE RING-3 SUBSYSTEM IS THIS ONE FUNCTION, and it
 * is called from exactly ONE place: `userMetaBase()` in core/kernel/user.dart.
 * The same rule `vm_store_addr` states, and `tests/conformance/m9-ring3/run.sh`
 * counts it the same way. */
.align 16
.global user_store_addr
.type user_store_addr, @function
user_store_addr:
    leaq user_store(%rip), %rax
    ret

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
