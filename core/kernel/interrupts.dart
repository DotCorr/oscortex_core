// core/kernel/interrupts.dart
//
// oscortex_core M1: IDT construction, PIC remapping, PIT programming, and
// every interrupt/exception handler body. The architecture is
// docs/decisions/0002-m1-interrupts-architecture.md; the binary exit
// criterion it has to satisfy is ROADMAP.md's M1.
//
// A `part of 'kmain.dart'` for the same reason uart.dart and multiboot.dart
// are: `dcc` compiles ONE library per object file, and a `@bare` function in
// an imported library is not compiled at all. That is no longer SILENT (dcc
// now rejects it by name with a message pointing at `part`/`part of`), but it
// is still a real constraint. See docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// THE SEAM
//
// Everything declared `@extern external` below lives in core/boot/isr.S.
// DCDart drives the whole sequence and calls into assembly for the four
// things it cannot do: execute a privileged instruction, execute `int3`, take
// the address of a symbol, and read a location without LLVM being entitled to
// cache the read.
//
// Extern signatures are scalars only (DCDart GAP-0025 -- `Pointer<T>` is not
// permitted in an extern signature yet), which is exactly why the accessors
// return a `u64` ADDRESS that this file then wraps in `Pointer<u64>` itself
// rather than passing pointers across the boundary.
// ---------------------------------------------------------------------------

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text — `@rodata` byte tables (DCDart ADR-0040).
//
// Same story as multiboot.dart's: these were runs of one `uartPutc` per
// character until static read-only data existed. Byte counts are repeated at
// the call sites because a `@rodata` table has no length word, and are checked
// byte-for-byte by tests/conformance/m1-interrupts/run.sh.
// ---------------------------------------------------------------------------

/// Line label: `"M1 IDT "` — 7 bytes.
@rodata
final List<u8> m1StrIdt = const [u8(0x4D), u8(0x31), u8(0x20), u8(0x49), u8(0x44), u8(0x54), u8(0x20)];

/// Line label: `"M1 EXC "` — 7 bytes.
@rodata
final List<u8> m1StrExc = const [u8(0x4D), u8(0x31), u8(0x20), u8(0x45), u8(0x58), u8(0x43), u8(0x20)];

/// Line label: `"M1 FAULT "` — 9 bytes.
@rodata
final List<u8> m1StrFault = const [u8(0x4D), u8(0x31), u8(0x20), u8(0x46), u8(0x41), u8(0x55), u8(0x4C), u8(0x54), u8(0x20)];

/// Line label: `"M1 PIC "` — 7 bytes.
@rodata
final List<u8> m1StrPic = const [u8(0x4D), u8(0x31), u8(0x20), u8(0x50), u8(0x49), u8(0x43), u8(0x20)];

/// Line label: `"M1 TICKS "` — 9 bytes.
@rodata
final List<u8> m1StrTicks = const [u8(0x4D), u8(0x31), u8(0x20), u8(0x54), u8(0x49), u8(0x43), u8(0x4B), u8(0x53), u8(0x20)];

/// Complete line: `"M1 END\n"` — 7 bytes.
@rodata
final List<u8> m1StrEnd = const [u8(0x4D), u8(0x31), u8(0x20), u8(0x45), u8(0x4E), u8(0x44), u8(0x0A)];


// ---------------------------------------------------------------------------
// M4 (ADR-0007): the RECOVERABLE-fault diagnostic.
//
// Separate tables from M1's `M1 FAULT ` above, deliberately. M1's is a
// one-shot boot-time event whose bytes are frozen inside a 544-byte golden
// that must not move; this is the line printed every time a fault is caught
// after the shell is up, and it says different things.
// ---------------------------------------------------------------------------

/// Fault-diagnostic line label, for a fault taken AFTER the shell is up. M1's
/// own `M1 FAULT ` label is deliberately a different table and a different
/// string: M1's is a one-shot boot-time event asserted by a 544-byte golden
/// that must not move, and this one is the recoverable-fault path.
///
/// `"FAULT "` -- 6 bytes.
@rodata
final List<u8> m1StrFaultHead = const [u8(0x46), u8(0x41), u8(0x55), u8(0x4C), u8(0x54), u8(0x20)];

/// Fault diagnostic: separator before the CPU error code.
///
/// `" ERR "` -- 5 bytes.
@rodata
final List<u8> m1StrFaultErr = const [u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20)];

/// Fault diagnostic: separator before the first two bytes of the faulting
/// instruction, read through the RIP the CPU pushed.
///
/// `" OP "` -- 4 bytes.
@rodata
final List<u8> m1StrFaultOp = const [u8(0x20), u8(0x4F), u8(0x50), u8(0x20)];

/// Printed instead of the opcode bytes when the faulting RIP is outside the
/// 16MiB `boot.S` identity-maps. Reading it would fault INSIDE the fault
/// handler, which is a double fault and then a triple fault -- the one failure
/// this milestone must not create while diagnosing another.
///
/// `"----"` -- 4 bytes.
@rodata
final List<u8> m1StrFaultOpUnmapped = const [u8(0x2D), u8(0x2D), u8(0x2D), u8(0x2D)];



/// Address of `isr.S`'s 256-entry table of stub addresses.
@extern
external u64 isr_stub_table_addr();

/// Address of the 4096-byte IDT in `isr.S`'s `.bss`, for this file to fill.
@extern
external u64 idt_base();

/// Address of the timer tick counter, so the tick handler can increment it
/// through a `Pointer<u64>`.
@extern
external u64 tick_counter_addr();

/// Reads the tick counter through an opaque call.
///
/// Load-bearing that this is an extern call and not a plain `Pointer<u64>`
/// load: DC-IR's `Load` has no volatile semantics (DCDart GAP-0006), so a
/// loop that reloads one address with nothing opaque in between is one LLVM
/// may legally hoist — the wait below would then spin on a stale register
/// forever. LLVM cannot prove an external call leaves memory alone, so the
/// value is genuinely re-read every iteration.
@extern
external u64 tick_count();

/// `lidt`. Also zeroes the tick counter — see `isr.S` for why that belongs
/// there rather than here.
@extern
external void idt_load();

/// `sti`.
@extern
external void interrupts_enable();

/// `cli`.
@extern
external void interrupts_disable();

/// `int3` — the interrupt-delivery self-test.
@extern
external void debug_break();

/// `cli; hlt;` forever. Never returns.
@extern
external void halt_forever();

// ---------------------------------------------------------------------------
// Port numbers. Named `const int`s (DCDart ADR-0037) rather than bare literals
// — `dcc-lower` accepts a named const where it used to demand a literal.
// ---------------------------------------------------------------------------

/// Master 8259 PIC: command port, then data/mask port.
const int picMasterCmd = 0x20;
const int picMasterData = 0x21;

/// Slave 8259 PIC.
const int picSlaveCmd = 0xA0;
const int picSlaveData = 0xA1;

/// 8253/8254 PIT: channel 0 data port, and the mode/command register.
const int pitChannel0 = 0x40;
const int pitCommand = 0x43;

/// Vector the remapped master PIC delivers IRQ0 (the PIT) on.
const int vectorTimer = 0x20;

// ---------------------------------------------------------------------------
// IDT construction
// ---------------------------------------------------------------------------

/// Writes one 64-bit interrupt gate at [vector].
///
/// A gate is 16 bytes, written as two `u64` stores:
///
/// | bytes | field | value |
/// |---|---|---|
/// | 0–1 | offset 15:0 | handler low half |
/// | 2–3 | segment selector | `0x08` — `boot.S`'s `gdt64_code` |
/// | 4 | IST index | `0` — see below |
/// | 5 | type/attributes | `0x8E` — present, DPL 0, 64-bit interrupt gate |
/// | 6–7 | offset 31:16 | |
/// | 8–11 | offset 63:32 | |
/// | 12–15 | reserved | zero |
///
/// **IST index 0 (no stack switch), deliberately.** An earlier revision of
/// this design set a non-zero IST on every gate to dodge a DCDart backend bug
/// that emitted red-zone-using code — an interrupt without a stack switch
/// would have pushed its frame through the interrupted function's live
/// locals. That bug is fixed (DCDart ADR-0039) and re-verified here against
/// real kernel output, so the mitigation is gone with it. See ADR-0002's
/// "The red zone" section for the full reasoning and what would bring an IST
/// back.
///
/// **Interrupt gate (`0x8E`), not trap gate (`0x8F`).** An interrupt gate
/// clears IF on entry, so a handler cannot be re-entered by the next tick
/// while it is still running. With no way to write a critical section in
/// DCDart (that needs runtime `cli`/`sti`, which is only reachable through
/// the externs above), non-reentrancy is the only thing making the tick
/// counter safe to touch. This is the mechanism, not a default.
@bare
void idtSetGate(u64 idtBase, u64 vector, u64 handler) {
  final u64 gate = idtBase + (vector * u64(16));
  final u64 low = (handler & u64(0xFFFF)) |
      (u64(0x08) << u64(16)) |
      (u64(0x00) << u64(32)) |
      (u64(0x8E) << u64(40)) |
      (((handler >> u64(16)) & u64(0xFFFF)) << u64(48));
  final u64 high = (handler >> u64(32)) & u64(0xFFFFFFFF);
  Pointer<u64>.fromAddress(gate).value = low;
  Pointer<u64>.fromAddress(gate + u64(8)).value = high;
}

/// Installs all 256 gates and returns how many were written.
///
/// The count is returned rather than assumed so `M1 IDT 0100` reports what the
/// loop actually did. A hard-coded `256` in the output would prove nothing.
@bare
u64 idtInstallAll() {
  final u64 idt = idt_base();
  final u64 table = isr_stub_table_addr();
  u64 installed = u64(0);
  while (installed < u64(256)) {
    // Each stub's address, read out of isr.S's table as ordinary DATA. This
    // indirection exists because DCDart cannot take the address of a code
    // symbol — see ADR-0002.
    final u64 handler = Pointer<u64>.fromAddress(table + (installed * u64(8))).value;
    idtSetGate(idt, installed, handler);
    installed = installed + u64(1);
  }
  return installed;
}

// ---------------------------------------------------------------------------
// 8259 PIC
// ---------------------------------------------------------------------------

/// Remaps both PICs so the master delivers IRQ0–7 on vectors 0x20–0x27 and the
/// slave IRQ8–15 on 0x28–0x2F, then masks everything except IRQ0.
///
/// **Not optional and not cosmetic.** At power-on the master PIC delivers
/// IRQ0–7 to vectors 0x08–0x0F, which in long mode are CPU exception vectors
/// 8–15: double fault, invalid TSS, segment-not-present, stack fault, general
/// protection, page fault. Without this remap a spurious IRQ is
/// indistinguishable from a page fault, and the handlers that most need to be
/// trustworthy are exactly the ones that get corrupted.
///
/// Standard ICW1–ICW4 initialization sequence. Both PICs are initialized even
/// though only the master's IRQ0 is used, because ICW3 cascade wiring has to
/// agree on both sides or the master mis-routes.
@bare
void picRemap() {
  // ICW1: begin initialization, expect ICW4.
  Port.outb(u16(picMasterCmd), u8(0x11));
  Port.outb(u16(picSlaveCmd), u8(0x11));
  // ICW2: vector offsets. This is the remap itself.
  Port.outb(u16(picMasterData), u8(0x20));
  Port.outb(u16(picSlaveData), u8(0x28));
  // ICW3: cascade wiring — slave is on the master's IRQ2 line.
  Port.outb(u16(picMasterData), u8(0x04)); // master: bit 2 set
  Port.outb(u16(picSlaveData), u8(0x02)); // slave: cascade identity 2
  // ICW4: 8086/88 mode.
  Port.outb(u16(picMasterData), u8(0x01));
  Port.outb(u16(picSlaveData), u8(0x01));
  // Masks: master leaves only IRQ0 (the PIT) unmasked; slave fully masked.
  Port.outb(u16(picMasterData), u8(0xFE));
  Port.outb(u16(picSlaveData), u8(0xFF));
}

/// Masks every IRQ on both PICs. Used before the deliberate fault, so a tick
/// cannot arrive in the middle of the fault diagnostic and interleave output.
@bare
void picMaskAll() {
  Port.outb(u16(picMasterData), u8(0xFF));
  Port.outb(u16(picSlaveData), u8(0xFF));
}

/// End-of-interrupt to the master PIC.
///
/// Without this the PIC never re-asserts and exactly ONE timer interrupt ever
/// arrives — which is why `M1 TICKS` reaching 0x64 proves the EOI path works
/// and not merely that one interrupt was delivered.
@bare
void picEoiMaster() {
  Port.outb(u16(picMasterCmd), u8(0x20)); // OCW2: non-specific EOI
}

// ---------------------------------------------------------------------------
// 8253/8254 PIT
// ---------------------------------------------------------------------------

/// Programs PIT channel 0 to ~100 Hz in rate-generator mode.
///
/// The PIT's input frequency is 1193182 Hz; a divisor of 11932 (0x2E9C) gives
/// 1193182 / 11932 = 100.0 Hz to four figures. Written low byte first, then
/// high byte, which is what access mode `lo/hi` in the command byte selects.
///
/// Command byte 0x36 = channel 0, access lo/hi, mode 3 (square wave), binary.
///
/// The divisor is spelled as two `u8` literals rather than computed and split.
/// It could be computed now (`.toU8()` exists — DCDart ADR-0037), but the
/// frequency is fixed and a literal pair is what the hardware actually
/// receives; deriving it would add arithmetic whose only purpose is to
/// reproduce two constants.
@bare
void pitInit() {
  Port.outb(u16(pitCommand), u8(0x36));
  Port.outb(u16(pitChannel0), u8(0x9C)); // divisor low  (0x2E9C & 0xFF)
  Port.outb(u16(pitChannel0), u8(0x2E)); // divisor high (0x2E9C >> 8)
}

// ---------------------------------------------------------------------------
// Handler bodies
// ---------------------------------------------------------------------------


/// `M1 EXC <vector:2> <errorCode:16>`
@bare
void m1ReportException(u64 vector, u64 errorCode) {
  uartWrite(Rodata.addressOf(m1StrExc), u64(7));
  uartPutHex(vector, u64(2));
  uartSpace();
  uartPutHex(errorCode, u64(16));
  uartNewline();
}

/// `M1 FAULT <vector:2> <errorCode:16>` — the diagnostic that GAP-0001 said
/// did not exist. At M0 a fault triple-faulted the VM and printed nothing.
@bare
void m1ReportFault(u64 vector, u64 errorCode) {
  uartWrite(Rodata.addressOf(m1StrFault), u64(9));
  uartPutHex(vector, u64(2));
  uartSpace();
  uartPutHex(errorCode, u64(16));
  uartNewline();
}

/// `M1 PIC <vector:2>` — printed by the FIRST timer interrupt, reporting the
/// vector it was actually delivered on.
///
/// This is the honest proof that the remap took. An 8259 cannot be asked what
/// vector base it was programmed with — ICW2 is write-only — so printing back
/// the constant this kernel sent would prove nothing about the hardware. What
/// CAN be observed is where the interrupt lands: `20` here means the PIT's
/// IRQ0 arrived on vector 0x20 rather than the power-on default 0x08.
@bare
void m1ReportPic(u64 vector) {
  uartWrite(Rodata.addressOf(m1StrPic), u64(7));
  uartPutHex(vector, u64(2));
  uartNewline();
}

/// Highest physical address `core/boot/boot.S` identity-maps (16MiB, as eight
/// 2MiB PAE pages). A load above this is not merely wrong, it FAULTS.
const int mappedLimit = 0x1000000;

/// `FAULT <vector:2> ERR <errorCode:16> OP <first two bytes at RIP>`
///
/// The diagnostic for a fault taken after the shell is up — the one the kernel
/// is going to survive rather than stop at.
///
/// **Why the faulting address is USED but not PRINTED.** [rip] is the address
/// the CPU pushed, handed over by `isr_common`, and this function dereferences
/// it — the `OP` field is the first two bytes of the instruction that actually
/// faulted (`0F0B` for a `ud2`, `48F7` for the `div` behind `crash div`). That
/// is a stronger claim than printing the address would be, because reading
/// through it proves the handler really has it.
///
/// The absolute value is deliberately left out of the output. Every byte this
/// kernel prints is asserted by a byte-exact golden, and an absolute code
/// address moves whenever *any* kernel code changes — so printing it would
/// guarantee that every future milestone had to regenerate this one's golden
/// for a reason that says nothing about correctness. Two opcode bytes are
/// position-independent and identify the instruction. Recorded as a real
/// limitation in docs/known-gaps.md GAP-0064, not as a preference.
///
/// **The bounds check is not decoration either.** If [rip] is outside the
/// 16MiB `boot.S` maps, loading through it faults — inside a fault handler,
/// which is a double fault and then a triple fault. Diagnosing a fault must not
/// be the thing that kills the machine, so an unmapped RIP prints `----`.
@bare
void faultReport(u64 vector, u64 errorCode, u64 rip) {
  uartWrite(Rodata.addressOf(m1StrFaultHead), u64(6));
  uartPutHex(vector, u64(2));
  uartWrite(Rodata.addressOf(m1StrFaultErr), u64(5));
  uartPutHex(errorCode, u64(16));
  uartWrite(Rodata.addressOf(m1StrFaultOp), u64(4));
  if (rip < u64(mappedLimit)) {
    uartPutHexByteAt(rip);
    uartPutHexByteAt(rip + u64(1));
  } else {
    uartWrite(Rodata.addressOf(m1StrFaultOpUnmapped), u64(4));
  }
  uartNewline();
}

/// `M1 IDT <count:4>`
@bare
void m1ReportIdt(u64 installed) {
  uartWrite(Rodata.addressOf(m1StrIdt), u64(7));
  uartPutHex(installed, u64(4));
  uartNewline();
}

/// `M1 TICKS <count:16>`
@bare
void m1ReportTicks(u64 ticks) {
  uartWrite(Rodata.addressOf(m1StrTicks), u64(9));
  uartPutHex(ticks, u64(16));
  uartNewline();
}

/// `M1 END`
@bare
void m1End() {
  uartWrite(Rodata.addressOf(m1StrEnd), u64(7));
}

/// Every interrupt and exception in the system arrives here.
///
/// Called from `isr_common` in `core/boot/isr.S` through the plain C ABI, with
/// all 15 general-purpose registers already saved. [frame] is the address of
/// that saved-register block — passed because DCDart cannot read a register,
/// so an address it can walk with `Pointer<u64>` is the only way to hand it
/// the interrupted CPU state. It is still unused and still named rather than
/// dropped, because the parameter is part of the asm side's contract.
///
/// **[rip] became load-bearing at M4.** It is the address the CPU pushed —
/// for a fault, the address of the faulting instruction itself — and
/// [faultReport] dereferences it to print the first two opcode bytes. That is
/// what makes the ` OP 0F0B` / ` OP 48F7` field evidence rather than
/// decoration: those bytes cannot be right unless this handler really has the
/// faulting address.
///
/// Dispatch is a branch chain on the vector, not a table: DCDart has no
/// function pointers and no dynamic dispatch of any kind, so a table is not
/// expressible. With three interesting vectors that is not a cost worth
/// noting; at thirty it would be.
@bare
void isrDispatch(u64 vector, u64 errorCode, u64 rip, u64 frame) {
  // --- Timer (IRQ0, remapped to 0x20) ---
  if (vector == u64(vectorTimer)) {
    final u64 counter = tick_counter_addr();
    final u64 ticks = Pointer<u64>.fromAddress(counter).value + u64(1);
    Pointer<u64>.fromAddress(counter).value = ticks;
    // The first tick reports the vector it arrived on — the observable proof
    // that picRemap() took effect. Only the first: this handler runs 100
    // times and the output has to stay byte-exact.
    if (ticks == u64(1)) {
      m1ReportPic(vector);
    }
    picEoiMaster();
    return;
  }

  // --- Keyboard (IRQ1, remapped to 0x21) — M2 ---
  //
  // Unmasked only once the console is up (picUnmaskKeyboardOnly), so this arm
  // is unreachable during M0/M1 and the three byte-exact serial goldens are
  // unaffected by its existence.
  //
  // The EOI is sent AFTER the echo rather than before. Both orders work here
  // because the gate is an interrupt gate (IF is clear for the whole handler,
  // so the PIC cannot re-deliver into a half-finished echo), but sending it
  // last keeps the rule "acknowledge the device once you are actually done
  // with it" true, which stops being cosmetic the moment a handler can be
  // interrupted.
  if (vector == u64(vectorKeyboard)) {
    kbdHandle();
    picEoiMaster();
    return;
  }

  // --- Breakpoint (int3), the delivery self-test ---
  //
  // A TRAP: the pushed RIP already points past the `int3`, so returning from
  // here resumes normally. That is the whole point of using a breakpoint for
  // the self-test rather than a fault.
  if (vector == u64(3)) {
    m1ReportException(vector, errorCode);
    return;
  }

  // --- Everything else: a real fault. ---
  //
  // NOT returning, and it is not a shortcut: a fault pushes the address of the
  // faulting instruction ITSELF, so `iretq` would re-execute it and loop
  // forever printing the same line. That constraint is what makes the two arms
  // below different from each other, and it is the whole subject of ADR-0007.
  //
  // ARM 1 -- BEFORE THE CONSOLE EXISTS (phase 0). This is M1's own deliberate
  // `u64` overflow, which DCDart's overflow-trap codegen turns into a `ud2`
  // (#UD, vector 6). At M0 it triple-faulted the VM with no output at all;
  // since M1 it prints a diagnostic; since M2 it hands control to m2Enter(),
  // which brings up the console and never returns. Those bytes are frozen:
  // tests/conformance/m1-interrupts/run.sh asserts the WHOLE capture against a
  // 544-byte golden whose last byte is the newline after `M1 END`, so this arm
  // is byte-for-byte what it has always been and M4 did not touch it.
  //
  // ARM 2 -- AFTER THE SHELL IS UP (phase 1). M4. Until now this case halted:
  // m2Enter()'s phase guard saw it had already been entered and stopped, which
  // was correct and honest ("the console is up, something faulted, do not
  // restart the console over the diagnostic") but it was not RECOVERY. The
  // kernel changed phase rather than continuing.
  //
  // Now it continues. The diagnostic is printed here, in interrupt context,
  // and then fault_resume() abandons this stack -- this handler's frame, the
  // faulting command's frame, and everything between them -- and re-enters the
  // shell on the stack recorded before the command ever ran.
  //
  // Stated plainly, because the difference matters: the faulting COMPUTATION
  // is not resumed and cannot be. It is abandoned. Resuming it after repairing
  // its cause is the condition-system model this project is aiming at, and it
  // needs language support that exists on neither side (DCDart
  // docs/escalations/0005-condition-system.md). See ADR-0007.
  final u64 phase = m2Phase();
  if (phase < u64(1)) {
    m1ReportFault(vector, errorCode);
    m1End();
    m2Enter();
    return; // not reached: m2Enter() never returns
  }
  faultCountBump();
  faultReport(vector, errorCode, rip);
  fault_resume(); // never returns; control reappears in shellRecover()
}
