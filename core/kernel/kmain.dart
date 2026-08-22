// core/kernel/kmain.dart
//
// oscortex_core kernel entry point (OSCORTEX_SPEC.md §2). Called from
// core/boot/boot.S via a plain C-ABI call, once the CPU is in 64-bit long
// mode with paging enabled -- the exact same call shape DCDart's own
// m0-seam/m1-pointer conformance harnesses already prove works.
//
// This file is the LIBRARY ROOT. `uart.dart`, `multiboot.dart` and
// `interrupts.dart` are `part` files, not imports: `dcc` compiles ONE library
// per object file, and a `@bare` function in an imported library is not
// compiled at all. That used to be SILENT (the only symptom was an undefined
// symbol at link time); it is now a hard error naming the offending functions
// and pointing at `part`/`part of`. The constraint itself is unchanged -- see
// docs/known-gaps.md GAP-0004 item 4.
//
// Import path assumes the sibling-checkout convention (../../../DCDart)
// documented in core/README.md -- same "only works from this exact layout"
// limitation DCDart's own dcc/README.md already accepts for itself (no real
// library resolver exists yet on either side). See known-gaps GAP-0003.
import '../../../DCDart/core/runtime/dc-core-bare/prelude.dart';

part 'uart.dart';
part 'multiboot.dart';
part 'interrupts.dart';
part 'vga.dart';
part 'keyboard.dart';
part 'shell.dart';
part 'pci.dart';
part 'fb.dart';
part 'ata.dart';
part 'pmm.dart';
part 'vm.dart';
part 'user.dart';
part 'elf.dart';
part 'proc.dart';

/// Kernel entry point.
///
/// [mbInfo] is the Multiboot1 information-structure pointer the loader left
/// in EBX. boot.S stashes it at `_start` and moves it into EDI immediately
/// before this call, so it arrives as the first System V AMD64 integer
/// argument (RDI), zero-extended from the 32-bit value -- an ordinary C-ABI
/// argument, needing nothing new from DCDart.
///
/// Serial output contract, asserted byte-for-byte by three harnesses:
///
///   line 1        `OSCORTEX M0 OK`      -- tests/conformance/m0-boot/run.sh
///                                          asserts EXACTLY this first line
///   `MB ...`      Multiboot report      -- tests/conformance/mb-info/run.sh
///                                          asserts everything up to `MB END`
///   `M1 ...`      interrupts report     -- tests/conformance/m1-interrupts/
///                                          run.sh asserts the WHOLE capture
///
/// This function never returns. It ends in a deliberate fault whose handler
/// halts -- see the end of the body.
@bare
void kmain(u64 mbInfo) {
  // The VGA console FIRST, before anything can print. Two reasons, and the
  // second one is a correctness requirement rather than an ordering
  // preference:
  //
  //   1. every byte printed from here on is mirrored to the screen, so the
  //      screen has to exist before the first byte;
  //   2. the console cursor lives in `core/boot/kdata.S`'s `.bss`, nothing in
  //      this kernel zeroes `.bss`, and a garbage cursor would scatter stores
  //      across memory at `0xB8000 + 2 * garbage`. vgaInit() is what gives it
  //      a known value.
  //
  // It prints nothing itself, so M0's banner is still the first byte on COM1.
  vgaInit();

  // M3: the same argument, for the same reason. `shellInit` gives every word
  // of the shell's donated `.bss` (core/boot/kdata.S) a known value -- a
  // garbage line length would make the first keystroke store hundreds of bytes
  // past the end of a 256-byte buffer, and a garbage 0xE0-prefix flag would
  // swallow the first real key. It also stashes [mbInfo], which is the only
  // reason the `mem` command can re-walk the memory map long after this
  // function's frame is gone. Prints nothing.
  shellInit(mbInfo);

  // M5: the framebuffer console's donated state, for the third time the same
  // argument. A garbage base address would make the first glyph blit scatter
  // 32-bit stores at an address nothing chose; zero is the "no framebuffer"
  // value every writer checks. Prints nothing and touches no hardware -- the
  // mode is not set until the `fb` command asks for it.
  fbInit();

  // M7: the physical memory manager. Builds the frame bitmap out of the
  // Multiboot memory map -- the map this kernel has read and thrown away on
  // every boot since M0 now becomes 4KiB of retained state instead of a
  // printed report.
  //
  // ORDER IS LOAD-BEARING TWICE OVER, and neither reason is style:
  //
  //   * AFTER shellInit(), because pmmInit() reads the Multiboot pointer out
  //     of the word shellInit() stashes it in. Called before it, the allocator
  //     would parse whatever `.bss` happened to contain and mark a bitmap from
  //     it.
  //   * BEFORE the first byte of output, because it prints NOTHING and must
  //     keep printing nothing: `tests/conformance/m1-interrupts/run.sh`
  //     asserts the ENTIRE 544-byte serial capture, and one diagnostic line
  //     here would break a green milestone. The allocator is reported by the
  //     `frames` command, from a prompt, not at boot.
  //
  // It is also the fourth time the same `.bss`-is-not-zeroed argument applies:
  // the bitmap starts as garbage and pmmInit() fills it with 0xFF before it
  // frees anything, so a frame is only ever free because the loader's memory
  // map said so.
  pmmInit();

  // M8: the kernel's real address space. Builds a 4-level page table out of six
  // frames from the allocator above, with per-section permissions and NX, and
  // installs it in CR3 -- replacing the flat, writable, executable 2MiB
  // identity map `boot.S` has been running on since M0 (docs/known-gaps.md
  // GAP-0050).
  //
  // ORDER IS LOAD-BEARING THREE TIMES OVER:
  //
  //   * AFTER pmmInit(), because the page tables come from allocFrame(). This
  //     is the first thing in the kernel that ALLOCATES rather than merely
  //     addressing memory it was compiled to know about, and it is why M7 was
  //     a prerequisite rather than a neighbour.
  //   * AFTER fbInit() and shellInit() for no reason of its own, but BEFORE
  //     anything can fault: it maps the pages every one of those subsystems
  //     already wrote to, and a mistake in it is a triple fault rather than a
  //     diagnostic. vmSelfCheck() walks the new tables for every address the
  //     kernel is standing on and REFUSES to switch if any of them is wrong,
  //     leaving the machine on boot.S's bootstrap tables.
  //   * BEFORE the first byte of output, because it prints NOTHING and must
  //     keep printing nothing -- `tests/conformance/m1-interrupts/run.sh`
  //     asserts the ENTIRE 544-byte serial capture. The address space is
  //     reported by `vm`, from a prompt.
  //
  // It also re-takes the allocator's baseline, because six frames are now
  // permanently spoken for and that is the address space rather than a leak.
  vmInit();

  // M9: the ring-3 subsystem's donated state. Sixteen words, and the same
  // `.bss`-is-not-zeroed argument as every init above it -- with one addition
  // that makes it the earliest of them in spirit if not in order.
  //
  // `userOnFault` reads the "a payload is live" word on EVERY FAULT THIS KERNEL
  // TAKES, including M1's own deliberate #UD a few dozen lines below. A garbage
  // word would make that fault try to tear down a payload that has never
  // existed: unmapping and freeing two frame numbers read out of `.bss` litter,
  // in the middle of diagnosing something else. So this runs before anything can
  // fault, which means before `uartInit()` and therefore before the first byte
  // of output -- and it prints nothing, for the reason pmmInit() and vmInit()
  // print nothing (`tests/conformance/m1-interrupts/run.sh` asserts the entire
  // 544-byte capture).
  //
  // It does NOT load the task register or touch the IDT. Both of those happen
  // after `idt_load()` below, so that a malformed TSS descriptor is a reported
  // #GP instead of a triple fault.
  userInit();

  // M10: the ELF loader's donated state, and the same argument one more time.
  // `userOnFault` asks [elfLive] on EVERY fault this kernel takes, so a garbage
  // word here would make the first fault of the boot -- M1's own deliberate #UD
  // a few dozen lines below -- try to tear down a program that has never
  // existed: walking a 2MiB window through a page-directory entry read out of
  // `.bss` litter and freeing whatever frame numbers it found. Prints nothing,
  // for the reason every init above it prints nothing
  // (`tests/conformance/m1-interrupts/run.sh` asserts the entire 544-byte
  // capture).
  elfInit();

  // M11: the process table's donated state, and the same argument for the sixth
  // time. `userOnFault` asks [procLive] on EVERY fault this kernel takes --
  // including M1's own deliberate #UD a few dozen lines below -- so a garbage
  // header word would make the first fault of the boot try to tear down four
  // address spaces read out of `.bss` litter, freeing whatever frame numbers it
  // found while diagnosing something else.
  //
  // It also has a reason of its own that no init above it has: it writes a legal
  // MXCSR image into each of the four FXSAVE areas. `fxrstor` raises #GP if the
  // MXCSR field has a reserved bit set, so an area left as `.bss` litter is a
  // general protection fault INSIDE A CONTEXT SWITCH -- and the fault handler
  // would then be running with the FPU half-restored.
  //
  // Prints nothing, for the reason every init above it prints nothing
  // (`tests/conformance/m1-interrupts/run.sh` asserts the entire 544-byte
  // capture).
  procInit();

  uartInit();
  uartPutBanner(); // includes its own trailing newline (a @rodata table now)

  // ---- M0's follow-up work: what the loader told us about memory ----
  mbReport(mbInfo);

  // ---- M1: interrupts ----
  //
  // Ordering here is the whole protocol, and every step depends on the one
  // before it:
  //
  //   1. fill the IDT           -- gates must be valid BEFORE lidt, or the
  //                                CPU is armed with 256 gates pointing at
  //                                whatever .bss happened to contain
  //   2. lidt                   -- arms them
  //   3. int3                   -- delivery self-test, with interrupts still
  //                                masked so nothing else can interleave
  //   4. remap the PIC          -- BEFORE sti, or IRQ0 arrives on vector 8
  //                                and is indistinguishable from #DF
  //   5. program the PIT        -- starts the timer counting down
  //   6. sti                    -- only now can an IRQ actually be delivered
  final u64 installed = idtInstallAll();
  m1ReportIdt(installed);

  // M9: gate 0x80 is rewritten with DPL 3, so that -- and only that -- one
  // vector can be reached by `int` from ring 3. A second pass rather than a
  // special case inside the loop above, so `M1 IDT 0100` keeps meaning "the
  // loop installed 256 gates" exactly as it always has. Prints nothing.
  idtSetUserGate();

  idt_load();
  debug_break(); // -> vector 3 -> isrDispatch -> "M1 EXC 03 ..." -> iretq

  picRemap();
  pitInit();
  interrupts_enable();

  // ---- Wait for 100 ticks ----
  //
  // The COUNT is the trigger, not a duration, so the output is identical
  // regardless of how fast the host is. tick_count() is an @extern call
  // rather than a Pointer<u64> load precisely so this loop re-reads memory
  // every iteration -- see interrupts.dart's declaration for why a plain
  // load would be hoistable and would spin forever.
  u64 ticks = tick_count();
  while (ticks < u64(100)) {
    ticks = tick_count();
  }
  m1ReportTicks(ticks);

  // ---- The deliberate fault: M1's actual point ----
  //
  // Mask every IRQ and clear IF first, so a tick cannot arrive mid-diagnostic
  // and interleave output into the middle of a line.
  picMaskAll();
  interrupts_disable();

  // `ticks` is >= 100 and came from an opaque extern call, so adding
  // 0xFFFFFFFFFFFFFFFF to it overflows a u64 for certain. It is spelled this
  // way ON PURPOSE rather than as a constant expression: DCDart's arithmetic
  // traps on overflow (DCDART_SPEC §4.1) by emitting a real conditional
  // `ud2`, and with two constants LLVM would be free to fold the whole thing
  // at compile time -- potentially into `unreachable`, which would delete the
  // surrounding code rather than trap at runtime. An opaque operand forces a
  // genuine runtime check. Verified by disassembly, not assumed.
  //
  // The resulting #UD (vector 6) lands in isrDispatch, which prints
  // "M1 FAULT 06 ...", then "M1 END", then halts. At M0 this same fault would
  // have triple-faulted the VM and printed nothing at all -- that difference
  // IS the milestone.
  final u64 boom = ticks + u64(0xFFFFFFFFFFFFFFFF);

  // Not reached. Consuming `boom` keeps the overflowing add from being dead
  // code that a future optimizer could drop.
  uartPutHex(boom, u64(16));
  halt_forever();
}
