// core/kernel/shell.dart
//
// oscortex_core M3: a real command shell -- a line editor, a prompt, a
// command dispatcher, and a main loop that is NOT an interrupt handler.
// M4 (ADR-0007): plus `cpu`, two commands that fault ON PURPOSE, and the
// function control lands in after one does.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel
// source file here is: `dcc` lowers exactly ONE library per object file, so a
// `@bare` function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT CHANGED FROM M2, AND WHY IT IS A STRUCTURAL CHANGE RATHER THAN A FEATURE
// ---------------------------------------------------------------------------
// At M2 a keystroke was translated and echoed inside the IRQ1 handler, and the
// kernel's steady state was `idle_forever` (`sti; hlt; jmp`) in assembly. There
// was no consumer of input and no place for one: the handler WAS the program.
//
// M3 splits that in two:
//
//   * `kbdHandle` (still in interrupt context, IF clear because the gate is an
//     interrupt gate) does line EDITING only -- append, backspace, and on Enter
//     set a one-word flag. It never runs a command.
//
//   * `shellMain` (task context, IF set) is the steady state. It waits with
//     `sti; hlt`, and when the flag says a line is ready it executes the
//     command with interrupts ENABLED and nothing in the PIC's in-service
//     register.
//
// That split is not architectural taste, it is what `ticks` forces. An
// interrupt gate clears IF for the whole handler, so a command that runs inside
// `kbdHandle` cannot receive a timer interrupt -- a wait for the PIT counter to
// advance would deadlock, with the kernel spinning on a value nothing can
// increment. Running commands in task context makes the timer observable,
// makes any future long-running command interruptible, and is the shape every
// milestone after this one needs.
//
// ---------------------------------------------------------------------------
// THE THREE-STATE FLAG, AND THE RACE IT CLOSES
// ---------------------------------------------------------------------------
// `shell_ready` is 0 = accepting input, 1 = a line was submitted and is waiting
// to run, 2 = a command is running. `kbdHandle` drops every keystroke unless
// the state is 0.
//
// Without state 2 the race is real, not theoretical: a key pressed while
// `shellExecute` is walking the line buffer would append at `shell_len` and
// bump it, so the command would observe the length changing underneath it. The
// cost of closing it this way is that type-ahead during a command is LOST --
// there is no input queue (docs/known-gaps.md GAP-0055 item 4 is still open,
// and a queue is another donated buffer, GAP-0053).
//
// The idle path is `cli` / test / `sti; hlt` rather than test / `sti; hlt`,
// which is the classic sleeping-race fix: if the flag were tested with
// interrupts already enabled, a keystroke landing between the test and the
// `hlt` would leave the kernel asleep with a submitted line, until the NEXT
// keystroke woke it. `idle_once` puts `sti` and `hlt` adjacent so the wake-up
// cannot be missed (x86 delivers no interrupt between `sti` and the very next
// instruction).
//
// ---------------------------------------------------------------------------
// WHAT M4 ADDED, AND WHY IT IS ALSO STRUCTURAL RATHER THAN A FEATURE
// ---------------------------------------------------------------------------
// M3 made the kernel operable. M4 makes it operable AFTER IT BREAKS.
//
// `crash ud` and `crash div` fault on purpose, on two different vectors. The
// handler cannot `iretq` back -- a fault pushes the address of the faulting
// instruction itself -- so recovery ABANDONS the faulting computation:
// `fault_resume` (core/boot/isr.S) resets RSP to a mark `shell_run_forever`
// recorded before the loop started, and calls [shellRecover] and then
// [shellMain] on it. Every frame the command was standing on disappears in one
// store.
//
// The three-state flag below is what makes that safe to do from the middle of a
// command: [shellRecover] puts the state back to 0, so the keyboard starts
// being listened to again. Without it the shell would print a prompt and then
// ignore every key, which looks exactly like a hang.
//
// Stated here as well as in the ADR, because it would be easy to oversell: this
// is fault SURVIVAL with abandonment, not resumption. The command that faulted
// is gone. Resuming a failed computation after repairing its cause is a
// condition system and needs language support that exists on neither side --
// DCDart docs/escalations/0005-condition-system.md. See
// docs/decisions/0007-fault-recovery-and-cpuid.md.
//
// ---------------------------------------------------------------------------
// NO STRINGS EXIST, SO "PARSING" IS TWO BYTE RANGES AND A LOOP
// ---------------------------------------------------------------------------
// `@bare` DCDart has no String, no array type, no function pointers, and no
// dynamic dispatch. A command table is therefore a `@rodata final List<u8>`
// per name (DCDart ADR-0040) and dispatch is a chain of `if`s over a
// byte-compare loop. With five commands that is not a cost worth noting; the
// point at which it becomes one is the point at which function pointers stop
// being optional.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// Byte counts are repeated at every call site because a `@rodata` table has no
// length word. A wrong count is not a silent corruption: every byte the shell
// prints is asserted byte-for-byte by tests/conformance/m3-shell/run.sh.
// ---------------------------------------------------------------------------

/// Shell entry banner. **Screen only, never serial** -- same hard requirement
/// the M2 banner had: `tests/conformance/m1-interrupts/run.sh` asserts the
/// ENTIRE serial capture and its last byte is the newline after `M1 END`, so
/// anything on COM1 before a key is pressed breaks a green milestone.
///
/// Ends WITHOUT a newline: `kbdInit()` appends the drained-byte count and the
/// newline, so the banner reads as one line.
///
/// `"\nOSCORTEX M3 SHELL  VGA 80x25 + PS/2 IRQ1  8042 drained: "` -- 57 bytes.
@rodata
final List<u8> shellStrBanner = const [
  u8(0x0A), u8(0x4F), u8(0x53), u8(0x43), u8(0x4F), u8(0x52), u8(0x54), u8(0x45), u8(0x58), u8(0x20), u8(0x4D), u8(0x33),
  u8(0x20), u8(0x53), u8(0x48), u8(0x45), u8(0x4C), u8(0x4C), u8(0x20), u8(0x20), u8(0x56), u8(0x47), u8(0x41), u8(0x20),
  u8(0x38), u8(0x30), u8(0x78), u8(0x32), u8(0x35), u8(0x20), u8(0x2B), u8(0x20), u8(0x50), u8(0x53), u8(0x2F), u8(0x32),
  u8(0x20), u8(0x49), u8(0x52), u8(0x51), u8(0x31), u8(0x20), u8(0x20), u8(0x38), u8(0x30), u8(0x34), u8(0x32), u8(0x20),
  u8(0x64), u8(0x72), u8(0x61), u8(0x69), u8(0x6E), u8(0x65), u8(0x64), u8(0x3A), u8(0x20),
];

/// The prompt. Its LENGTH is what backspace must never erase past, and that is
/// enforced by the line buffer's own length word rather than by counting screen
/// cells -- see [shellKey].
///
/// `"oscortex> "` -- 10 bytes.
@rodata
final List<u8> shellStrPrompt = const [
  u8(0x6F), u8(0x73), u8(0x63), u8(0x6F), u8(0x72), u8(0x74), u8(0x65), u8(0x78), u8(0x3E), u8(0x20),
];

/// Unknown-command prefix. The typed line is echoed after it, so the error names
/// what was actually typed instead of failing silently.
///
/// `"oscortex: unknown command: "` -- 27 bytes.
@rodata
final List<u8> shellStrUnknown = const [
  u8(0x6F), u8(0x73), u8(0x63), u8(0x6F), u8(0x72), u8(0x74), u8(0x65), u8(0x78), u8(0x3A), u8(0x20), u8(0x75), u8(0x6E),
  u8(0x6B), u8(0x6E), u8(0x6F), u8(0x77), u8(0x6E), u8(0x20), u8(0x63), u8(0x6F), u8(0x6D), u8(0x6D), u8(0x61), u8(0x6E),
  u8(0x64), u8(0x3A), u8(0x20),
];

/// The `oscortex: ` that begins a refusal this shell makes about a command it
/// DOES know. A separate table from [shellStrUnknown] rather than its first ten
/// bytes, because a `@rodata` table has no length word, every call site must
/// pass the whole size, and printing a prefix of a longer table is exactly the
/// shape GAP-0060 records going wrong -- `m16-filewrite/run.sh` §2g compares
/// every call site's length against the symbol's size and would reject it.
///
/// `'oscortex: '` -- 10 bytes.
@rodata
final List<u8> shellStrOscortex = const [
  u8(0x6F), u8(0x73), u8(0x63), u8(0x6F), u8(0x72), u8(0x74), u8(0x65), u8(0x78), u8(0x3A), u8(0x20),
];

/// The rest of that line, printed after the command's own name is echoed back
/// out of the line buffer.
///
/// `' takes no argument\n'` -- 19 bytes.
@rodata
final List<u8> shellStrNoArg = const [
  u8(0x20), u8(0x74), u8(0x61), u8(0x6B), u8(0x65), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x61), u8(0x72),
  u8(0x67), u8(0x75), u8(0x6D), u8(0x65), u8(0x6E), u8(0x74), u8(0x0A),
];

/// `help` output. ONE table with embedded newlines rather than one table per
/// line: a `@rodata` table is a flat byte run (DCDart ADR-0040) and `\n` is an
/// ordinary byte in it, so fifteen tables and fifteen call sites would buy
/// nothing.
///
/// **1658 bytes at M10**, up from 1589 at M9, 1155 at M8, 1028 at M7, 621 at M6,
/// 498 at M5, 395 at M4 and 237 at M3.
/// That number is the single hand-maintained literal in [shellHelp] below, and
/// it is the number that went wrong at M4 -- see docs/known-gaps.md GAP-0060.
/// The table's bytes and its length are both GENERATED from the string, and
/// `tests/conformance/m7-frames/run.sh` reads the symbol's real size out of the
/// object file and compares it against what the call site passes.
///
/// M7 added six lines -- the frame allocator's commands. A command that is not
/// in this list is undiscoverable, which is why `help` growing is not optional
/// and why three earlier goldens moved with it (docs/known-gaps.md GAP-0075).
/// M9 added seven (GAP-0087) and M10 adds one, `run <lba>`, which moves four
/// serial goldens and m3-shell's screen golden again (docs/known-gaps.md
/// GAP-0093). The substitution is mechanical and the kernel is then required to
/// reproduce the result byte-for-byte, which is what makes it safe.
///
/// **M14 took it to 2147 and M19 takes it to 2224**, by one line: the words
/// after a program's name are now its `argv` (ADR-0023), and a command whose
/// new capability is not in this list is undiscoverable exactly as a missing
/// command is (GAP-0115). That one line moved five serial goldens and
/// m3-shell's screen golden, every one of them by SUBSTITUTING the line and
/// then requiring the kernel to reproduce the file byte-for-byte.
///
/// **THE SHAKEDOWN TOOK IT TO 2511, BY FIVE LINES, AND THAT IS GAP-0142 BEING
/// PAID RATHER THAN DEFERRED AGAIN.** Four of the five are commands that were
/// dispatched and undocumented:
///
///   * `proc sched`, `proc coop <a> <b>` and `proc spin <a> <b> <quanta>` --
///     M18's three. They were booted and shown working, and the only place
///     they appeared was `procStrUsage2`, which a user sees ONLY by typing
///     `proc` wrong. Discovering a feature by making a mistake is not
///     discoverability, and the second usage table is what proves the omission
///     was an oversight rather than a decision: somebody documented them, in a
///     place the listing does not reach. GAP-0142 said exactly what closing it
///     would take -- "one commit that adds the three lines and regenerates the
///     five goldens" -- and this is that commit.
///   * `frames leave <n>`, which is new here, and exists because
///     `elfErrNoFrames` had no reachable caller without it (ADR-0039).
///
/// The fifth is the `fb` line, which stated the video mode in DECIMAL
/// (`800x600x32`) while the command prints it in HEX (`0320x0258x20`) and
/// nothing said which base either was in. It now carries the bytes the command
/// actually prints, and the decimal beside them, labelled.
@rodata
final List<u8> shellStrHelp = const [
  u8(0x63), u8(0x6F), u8(0x6D), u8(0x6D), u8(0x61), u8(0x6E), u8(0x64), u8(0x73), u8(0x3A), u8(0x0A), u8(0x20), u8(0x20),
  u8(0x68), u8(0x65), u8(0x6C), u8(0x70), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x6C), u8(0x69), u8(0x73), u8(0x74), u8(0x0A),
  u8(0x20), u8(0x20), u8(0x63), u8(0x6C), u8(0x65), u8(0x61), u8(0x72), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x63), u8(0x6C), u8(0x65), u8(0x61), u8(0x72), u8(0x20), u8(0x74), u8(0x68),
  u8(0x65), u8(0x20), u8(0x73), u8(0x63), u8(0x72), u8(0x65), u8(0x65), u8(0x6E), u8(0x2C), u8(0x20), u8(0x68), u8(0x6F),
  u8(0x6D), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x63), u8(0x75), u8(0x72), u8(0x73), u8(0x6F),
  u8(0x72), u8(0x0A), u8(0x20), u8(0x20), u8(0x6D), u8(0x65), u8(0x6D), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x6D), u8(0x75), u8(0x6C), u8(0x74), u8(0x69), u8(0x62),
  u8(0x6F), u8(0x6F), u8(0x74), u8(0x20), u8(0x6D), u8(0x65), u8(0x6D), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x6D),
  u8(0x61), u8(0x70), u8(0x20), u8(0x2B), u8(0x20), u8(0x74), u8(0x6F), u8(0x74), u8(0x61), u8(0x6C), u8(0x20), u8(0x75),
  u8(0x73), u8(0x61), u8(0x62), u8(0x6C), u8(0x65), u8(0x20), u8(0x52), u8(0x41), u8(0x4D), u8(0x0A), u8(0x20), u8(0x20),
  u8(0x74), u8(0x69), u8(0x63), u8(0x6B), u8(0x73), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x76), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20),
  u8(0x50), u8(0x49), u8(0x54), u8(0x20), u8(0x74), u8(0x69), u8(0x63), u8(0x6B), u8(0x20), u8(0x63), u8(0x6F), u8(0x75),
  u8(0x6E), u8(0x74), u8(0x65), u8(0x72), u8(0x20), u8(0x61), u8(0x64), u8(0x76), u8(0x61), u8(0x6E), u8(0x63), u8(0x65),
  u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x63), u8(0x70), u8(0x75), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x43), u8(0x50), u8(0x55), u8(0x49), u8(0x44), u8(0x20),
  u8(0x76), u8(0x65), u8(0x6E), u8(0x64), u8(0x6F), u8(0x72), u8(0x2C), u8(0x20), u8(0x62), u8(0x72), u8(0x61), u8(0x6E),
  u8(0x64), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x6C), u8(0x65), u8(0x61), u8(0x66), u8(0x20), u8(0x6C),
  u8(0x69), u8(0x6D), u8(0x69), u8(0x74), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x70), u8(0x63), u8(0x69), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x65), u8(0x6E),
  u8(0x75), u8(0x6D), u8(0x65), u8(0x72), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20),
  u8(0x50), u8(0x43), u8(0x49), u8(0x20), u8(0x62), u8(0x75), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x66), u8(0x62),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x62), u8(0x75), u8(0x66), u8(0x66), u8(0x65), u8(0x72), u8(0x20),
  u8(0x63), u8(0x6F), u8(0x6E), u8(0x73), u8(0x6F), u8(0x6C), u8(0x65), u8(0x3A), u8(0x20), u8(0x42), u8(0x41), u8(0x52),
  u8(0x30), u8(0x2C), u8(0x20), u8(0x6D), u8(0x6F), u8(0x64), u8(0x65), u8(0x20), u8(0x30), u8(0x33), u8(0x32), u8(0x30),
  u8(0x78), u8(0x30), u8(0x32), u8(0x35), u8(0x38), u8(0x78), u8(0x32), u8(0x30), u8(0x20), u8(0x68), u8(0x65), u8(0x78),
  u8(0x20), u8(0x3D), u8(0x20), u8(0x38), u8(0x30), u8(0x30), u8(0x78), u8(0x36), u8(0x30), u8(0x30), u8(0x78), u8(0x33),
  u8(0x32), u8(0x0A), u8(0x20), u8(0x20), u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x69), u8(0x64), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x41), u8(0x54), u8(0x41), u8(0x20), u8(0x50), u8(0x49),
  u8(0x4F), u8(0x20), u8(0x49), u8(0x44), u8(0x45), u8(0x4E), u8(0x54), u8(0x49), u8(0x46), u8(0x59), u8(0x3A), u8(0x20),
  u8(0x6D), u8(0x6F), u8(0x64), u8(0x65), u8(0x6C), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x73), u8(0x65),
  u8(0x63), u8(0x74), u8(0x6F), u8(0x72), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x0A), u8(0x20),
  u8(0x20), u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x20), u8(0x3C),
  u8(0x6E), u8(0x3E), u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x20), u8(0x6F), u8(0x6E), u8(0x65), u8(0x20),
  u8(0x35), u8(0x31), u8(0x32), u8(0x2D), u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x20), u8(0x73), u8(0x65), u8(0x63),
  u8(0x74), u8(0x6F), u8(0x72), u8(0x2C), u8(0x20), u8(0x68), u8(0x65), u8(0x78), u8(0x64), u8(0x75), u8(0x6D), u8(0x70),
  u8(0x65), u8(0x64), u8(0x20), u8(0x61), u8(0x73), u8(0x20), u8(0x69), u8(0x74), u8(0x20), u8(0x61), u8(0x72), u8(0x72),
  u8(0x69), u8(0x76), u8(0x65), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65),
  u8(0x73), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x70), u8(0x68), u8(0x79),
  u8(0x73), u8(0x69), u8(0x63), u8(0x61), u8(0x6C), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x20),
  u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F), u8(0x63), u8(0x61), u8(0x74), u8(0x6F), u8(0x72), u8(0x3A), u8(0x20), u8(0x74),
  u8(0x6F), u8(0x74), u8(0x61), u8(0x6C), u8(0x73), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x69), u8(0x74),
  u8(0x73), u8(0x20), u8(0x6F), u8(0x77), u8(0x6E), u8(0x20), u8(0x66), u8(0x6F), u8(0x6F), u8(0x74), u8(0x70), u8(0x72),
  u8(0x69), u8(0x6E), u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73),
  u8(0x20), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20), u8(0x20), u8(0x20), u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F),
  u8(0x63), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x36), u8(0x34), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D),
  u8(0x65), u8(0x73), u8(0x2C), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x76), u8(0x65), u8(0x20), u8(0x74), u8(0x68),
  u8(0x65), u8(0x6D), u8(0x20), u8(0x64), u8(0x69), u8(0x73), u8(0x74), u8(0x69), u8(0x6E), u8(0x63), u8(0x74), u8(0x2C),
  u8(0x20), u8(0x67), u8(0x69), u8(0x76), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x6D), u8(0x20), u8(0x62),
  u8(0x61), u8(0x63), u8(0x6B), u8(0x0A), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73),
  u8(0x20), u8(0x64), u8(0x72), u8(0x61), u8(0x69), u8(0x6E), u8(0x20), u8(0x20), u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F),
  u8(0x63), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x65), u8(0x76), u8(0x65), u8(0x72), u8(0x79), u8(0x20), u8(0x66),
  u8(0x72), u8(0x65), u8(0x65), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x2C), u8(0x20), u8(0x74),
  u8(0x68), u8(0x65), u8(0x6E), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x76), u8(0x65), u8(0x20), u8(0x74), u8(0x68),
  u8(0x65), u8(0x20), u8(0x6E), u8(0x65), u8(0x78), u8(0x74), u8(0x20), u8(0x6F), u8(0x6E), u8(0x65), u8(0x20), u8(0x66),
  u8(0x61), u8(0x69), u8(0x6C), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65),
  u8(0x73), u8(0x20), u8(0x6C), u8(0x65), u8(0x61), u8(0x76), u8(0x65), u8(0x20), u8(0x20), u8(0x3C), u8(0x6E), u8(0x3E),
  u8(0x3A), u8(0x20), u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F), u8(0x63), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x75),
  u8(0x6E), u8(0x74), u8(0x69), u8(0x6C), u8(0x20), u8(0x65), u8(0x78), u8(0x61), u8(0x63), u8(0x74), u8(0x6C), u8(0x79),
  u8(0x20), u8(0x3C), u8(0x6E), u8(0x3E), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20),
  u8(0x61), u8(0x72), u8(0x65), u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x0A), u8(0x20), u8(0x20), u8(0x66),
  u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x72), u8(0x65), u8(0x66), u8(0x69), u8(0x6C), u8(0x6C),
  u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20), u8(0x65), u8(0x76), u8(0x65), u8(0x72), u8(0x79), u8(0x20),
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x20), u8(0x64), u8(0x72), u8(0x61), u8(0x69), u8(0x6E), u8(0x20),
  u8(0x74), u8(0x6F), u8(0x6F), u8(0x6B), u8(0x2C), u8(0x20), u8(0x62), u8(0x61), u8(0x63), u8(0x6B), u8(0x20), u8(0x74),
  u8(0x6F), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x62), u8(0x61), u8(0x73), u8(0x65), u8(0x6C), u8(0x69),
  u8(0x6E), u8(0x65), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x61),
  u8(0x6C), u8(0x6C), u8(0x6F), u8(0x63), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F), u8(0x63), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x6F), u8(0x6E),
  u8(0x65), u8(0x20), u8(0x34), u8(0x4B), u8(0x69), u8(0x42), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65),
  u8(0x2C), u8(0x20), u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x20), u8(0x69), u8(0x74), u8(0x73), u8(0x20),
  u8(0x70), u8(0x68), u8(0x79), u8(0x73), u8(0x69), u8(0x63), u8(0x61), u8(0x6C), u8(0x20), u8(0x61), u8(0x64), u8(0x64),
  u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20),
  u8(0x3C), u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x3E), u8(0x20), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x65),
  u8(0x65), u8(0x20), u8(0x6F), u8(0x6E), u8(0x65), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x20),
  u8(0x62), u8(0x79), u8(0x20), u8(0x70), u8(0x68), u8(0x79), u8(0x73), u8(0x69), u8(0x63), u8(0x61), u8(0x6C), u8(0x20),
  u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x76), u8(0x6D),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x6B), u8(0x65), u8(0x72), u8(0x6E), u8(0x65), u8(0x6C), u8(0x27), u8(0x73),
  u8(0x20), u8(0x6F), u8(0x77), u8(0x6E), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x20), u8(0x74), u8(0x61),
  u8(0x62), u8(0x6C), u8(0x65), u8(0x73), u8(0x3A), u8(0x20), u8(0x73), u8(0x69), u8(0x7A), u8(0x65), u8(0x73), u8(0x20),
  u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x70), u8(0x65), u8(0x72), u8(0x6D), u8(0x69), u8(0x73), u8(0x73), u8(0x69),
  u8(0x6F), u8(0x6E), u8(0x73), u8(0x0A), u8(0x20), u8(0x20), u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74),
  u8(0x20), u8(0x3C), u8(0x77), u8(0x68), u8(0x61), u8(0x74), u8(0x3E), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x76),
  u8(0x65), u8(0x20), u8(0x57), u8(0x5E), u8(0x58), u8(0x3A), u8(0x20), u8(0x72), u8(0x6F), u8(0x20), u8(0x6E), u8(0x78),
  u8(0x20), u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20), u8(0x66), u8(0x61), u8(0x75), u8(0x6C), u8(0x74), u8(0x2C),
  u8(0x20), u8(0x72), u8(0x77), u8(0x20), u8(0x78), u8(0x20), u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20), u8(0x6E),
  u8(0x6F), u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x61),
  u8(0x20), u8(0x72), u8(0x69), u8(0x6E), u8(0x67), u8(0x2D), u8(0x33), u8(0x20), u8(0x70), u8(0x61), u8(0x79), u8(0x6C),
  u8(0x6F), u8(0x61), u8(0x64), u8(0x3A), u8(0x20), u8(0x73), u8(0x79), u8(0x73), u8(0x63), u8(0x61), u8(0x6C), u8(0x6C),
  u8(0x20), u8(0x69), u8(0x6E), u8(0x2C), u8(0x20), u8(0x73), u8(0x79), u8(0x73), u8(0x63), u8(0x61), u8(0x6C), u8(0x6C),
  u8(0x20), u8(0x6F), u8(0x75), u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20),
  u8(0x67), u8(0x70), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x72), u8(0x69), u8(0x6E),
  u8(0x67), u8(0x20), u8(0x33), u8(0x20), u8(0x65), u8(0x78), u8(0x65), u8(0x63), u8(0x75), u8(0x74), u8(0x65), u8(0x73),
  u8(0x20), u8(0x6D), u8(0x6F), u8(0x76), u8(0x20), u8(0x25), u8(0x63), u8(0x72), u8(0x33), u8(0x20), u8(0x2D), u8(0x2D),
  u8(0x20), u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20), u8(0x23), u8(0x47), u8(0x50), u8(0x0A), u8(0x20), u8(0x20),
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x70), u8(0x66), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x72), u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x33), u8(0x20), u8(0x73), u8(0x74), u8(0x6F),
  u8(0x72), u8(0x65), u8(0x73), u8(0x20), u8(0x69), u8(0x6E), u8(0x74), u8(0x6F), u8(0x20), u8(0x6B), u8(0x65), u8(0x72),
  u8(0x6E), u8(0x65), u8(0x6C), u8(0x20), u8(0x6D), u8(0x65), u8(0x6D), u8(0x6F), u8(0x72), u8(0x79), u8(0x20), u8(0x2D),
  u8(0x2D), u8(0x20), u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20), u8(0x23), u8(0x50), u8(0x46), u8(0x20), u8(0x55),
  u8(0x53), u8(0x45), u8(0x52), u8(0x0A), u8(0x20), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x62),
  u8(0x61), u8(0x64), u8(0x69), u8(0x6E), u8(0x74), u8(0x20), u8(0x20), u8(0x20), u8(0x72), u8(0x69), u8(0x6E), u8(0x67),
  u8(0x20), u8(0x33), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x73), u8(0x20), u8(0x61), u8(0x20), u8(0x44), u8(0x50),
  u8(0x4C), u8(0x2D), u8(0x30), u8(0x20), u8(0x67), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x2D), u8(0x2D), u8(0x20),
  u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20), u8(0x23), u8(0x47), u8(0x50), u8(0x0A), u8(0x20), u8(0x20), u8(0x75),
  u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x62), u8(0x61), u8(0x64), u8(0x70), u8(0x74), u8(0x72), u8(0x20), u8(0x20),
  u8(0x20), u8(0x72), u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x33), u8(0x20), u8(0x68), u8(0x61), u8(0x6E), u8(0x64),
  u8(0x73), u8(0x20), u8(0x77), u8(0x72), u8(0x69), u8(0x74), u8(0x65), u8(0x20), u8(0x61), u8(0x20), u8(0x6B), u8(0x65),
  u8(0x72), u8(0x6E), u8(0x65), u8(0x6C), u8(0x20), u8(0x70), u8(0x6F), u8(0x69), u8(0x6E), u8(0x74), u8(0x65), u8(0x72),
  u8(0x20), u8(0x2D), u8(0x2D), u8(0x20), u8(0x72), u8(0x65), u8(0x66), u8(0x75), u8(0x73), u8(0x65), u8(0x64), u8(0x0A),
  u8(0x20), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x68), u8(0x6F), u8(0x6C), u8(0x64), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x61), u8(0x20), u8(0x72), u8(0x69),
  u8(0x6E), u8(0x67), u8(0x2D), u8(0x33), u8(0x20), u8(0x70), u8(0x61), u8(0x79), u8(0x6C), u8(0x6F), u8(0x61), u8(0x64),
  u8(0x20), u8(0x74), u8(0x68), u8(0x61), u8(0x74), u8(0x20), u8(0x6E), u8(0x65), u8(0x76), u8(0x65), u8(0x72), u8(0x20),
  u8(0x65), u8(0x78), u8(0x69), u8(0x74), u8(0x73), u8(0x20), u8(0x28), u8(0x6C), u8(0x61), u8(0x73), u8(0x74), u8(0x20),
  u8(0x63), u8(0x6F), u8(0x6D), u8(0x6D), u8(0x61), u8(0x6E), u8(0x64), u8(0x29), u8(0x0A), u8(0x20), u8(0x20), u8(0x75),
  u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x73), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x54), u8(0x53), u8(0x53), u8(0x2C), u8(0x20), u8(0x67), u8(0x61), u8(0x74), u8(0x65), u8(0x20), u8(0x44),
  u8(0x50), u8(0x4C), u8(0x73), u8(0x2C), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x68), u8(0x6F), u8(0x77),
  u8(0x20), u8(0x6D), u8(0x61), u8(0x6E), u8(0x79), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x73), u8(0x20),
  u8(0x72), u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x33), u8(0x20), u8(0x63), u8(0x61), u8(0x6E), u8(0x20), u8(0x72),
  u8(0x65), u8(0x61), u8(0x63), u8(0x68), u8(0x0A), u8(0x20), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x3C),
  u8(0x6C), u8(0x62), u8(0x61), u8(0x3E), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x6C), u8(0x6F), u8(0x61),
  u8(0x64), u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x70), u8(0x72), u8(0x6F),
  u8(0x67), u8(0x72), u8(0x61), u8(0x6D), u8(0x20), u8(0x66), u8(0x72), u8(0x6F), u8(0x6D), u8(0x20), u8(0x74), u8(0x68),
  u8(0x61), u8(0x74), u8(0x20), u8(0x64), u8(0x69), u8(0x73), u8(0x6B), u8(0x20), u8(0x73), u8(0x65), u8(0x63), u8(0x74),
  u8(0x6F), u8(0x72), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x69),
  u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x3C), u8(0x6E), u8(0x61), u8(0x6D),
  u8(0x65), u8(0x3E), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x6C), u8(0x6F), u8(0x61), u8(0x64), u8(0x20), u8(0x61),
  u8(0x6E), u8(0x20), u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72), u8(0x61),
  u8(0x6D), u8(0x20), u8(0x66), u8(0x72), u8(0x6F), u8(0x6D), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x66),
  u8(0x69), u8(0x6C), u8(0x65), u8(0x73), u8(0x79), u8(0x73), u8(0x74), u8(0x65), u8(0x6D), u8(0x20), u8(0x62), u8(0x79),
  u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x72), u8(0x75),
  u8(0x6E), u8(0x20), u8(0x69), u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x74), u8(0x68), u8(0x65),
  u8(0x20), u8(0x77), u8(0x6F), u8(0x72), u8(0x64), u8(0x73), u8(0x20), u8(0x61), u8(0x66), u8(0x74), u8(0x65), u8(0x72),
  u8(0x20), u8(0x3C), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x3E), u8(0x20), u8(0x62), u8(0x65), u8(0x63), u8(0x6F),
  u8(0x6D), u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72),
  u8(0x61), u8(0x6D), u8(0x27), u8(0x73), u8(0x20), u8(0x61), u8(0x72), u8(0x67), u8(0x76), u8(0x20), u8(0x28), u8(0x61),
  u8(0x74), u8(0x20), u8(0x6D), u8(0x6F), u8(0x73), u8(0x74), u8(0x20), u8(0x38), u8(0x29), u8(0x0A), u8(0x20), u8(0x20),
  u8(0x66), u8(0x73), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x31), u8(0x36), u8(0x3A), u8(0x20), u8(0x6D), u8(0x6F), u8(0x75),
  u8(0x6E), u8(0x74), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x69), u8(0x6D), u8(0x61),
  u8(0x72), u8(0x79), u8(0x20), u8(0x6D), u8(0x61), u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x20), u8(0x61), u8(0x6E),
  u8(0x64), u8(0x20), u8(0x72), u8(0x65), u8(0x70), u8(0x6F), u8(0x72), u8(0x74), u8(0x20), u8(0x69), u8(0x74), u8(0x73),
  u8(0x20), u8(0x67), u8(0x65), u8(0x6F), u8(0x6D), u8(0x65), u8(0x74), u8(0x72), u8(0x79), u8(0x0A), u8(0x20), u8(0x20),
  u8(0x6C), u8(0x73), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x6C), u8(0x69), u8(0x73), u8(0x74), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72),
  u8(0x6F), u8(0x6F), u8(0x74), u8(0x20), u8(0x64), u8(0x69), u8(0x72), u8(0x65), u8(0x63), u8(0x74), u8(0x6F), u8(0x72),
  u8(0x79), u8(0x3A), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x2C), u8(0x20), u8(0x73), u8(0x69), u8(0x7A),
  u8(0x65), u8(0x2C), u8(0x20), u8(0x66), u8(0x69), u8(0x72), u8(0x73), u8(0x74), u8(0x20), u8(0x63), u8(0x6C), u8(0x75),
  u8(0x73), u8(0x74), u8(0x65), u8(0x72), u8(0x0A), u8(0x20), u8(0x20), u8(0x63), u8(0x61), u8(0x74), u8(0x20), u8(0x3C),
  u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x3E), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x69),
  u8(0x6E), u8(0x74), u8(0x20), u8(0x61), u8(0x20), u8(0x66), u8(0x69), u8(0x6C), u8(0x65), u8(0x2C), u8(0x20), u8(0x66),
  u8(0x6F), u8(0x6C), u8(0x6C), u8(0x6F), u8(0x77), u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x69), u8(0x74), u8(0x73),
  u8(0x20), u8(0x46), u8(0x41), u8(0x54), u8(0x20), u8(0x63), u8(0x6C), u8(0x75), u8(0x73), u8(0x74), u8(0x65), u8(0x72),
  u8(0x20), u8(0x63), u8(0x68), u8(0x61), u8(0x69), u8(0x6E), u8(0x0A), u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F),
  u8(0x63), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x74),
  u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x65), u8(0x73), u8(0x73), u8(0x20), u8(0x74),
  u8(0x61), u8(0x62), u8(0x6C), u8(0x65), u8(0x2C), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x43), u8(0x52),
  u8(0x34), u8(0x20), u8(0x53), u8(0x53), u8(0x45), u8(0x20), u8(0x62), u8(0x69), u8(0x74), u8(0x73), u8(0x2C), u8(0x20),
  u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x65), u8(0x61), u8(0x63), u8(0x68), u8(0x20), u8(0x73), u8(0x6C), u8(0x6F),
  u8(0x74), u8(0x0A), u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x72), u8(0x75), u8(0x6E),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E),
  u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E), u8(0x3A), u8(0x20), u8(0x74), u8(0x77), u8(0x6F),
  u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x65), u8(0x73), u8(0x73), u8(0x65), u8(0x73), u8(0x2C), u8(0x20),
  u8(0x74), u8(0x77), u8(0x6F), u8(0x20), u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x20),
  u8(0x73), u8(0x70), u8(0x61), u8(0x63), u8(0x65), u8(0x73), u8(0x2C), u8(0x20), u8(0x79), u8(0x69), u8(0x65), u8(0x6C),
  u8(0x64), u8(0x0A), u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x63), u8(0x72), u8(0x6F),
  u8(0x73), u8(0x73), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E),
  u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E), u8(0x3A), u8(0x20), u8(0x74), u8(0x68), u8(0x65),
  u8(0x20), u8(0x73), u8(0x61), u8(0x6D), u8(0x65), u8(0x2C), u8(0x20), u8(0x62), u8(0x75), u8(0x74), u8(0x20), u8(0x42),
  u8(0x20), u8(0x72), u8(0x65), u8(0x61), u8(0x64), u8(0x73), u8(0x20), u8(0x41), u8(0x27), u8(0x73), u8(0x20), u8(0x70),
  u8(0x61), u8(0x67), u8(0x65), u8(0x20), u8(0x2D), u8(0x2D), u8(0x20), u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20),
  u8(0x23), u8(0x50), u8(0x46), u8(0x0A), u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x63),
  u8(0x6F), u8(0x6F), u8(0x70), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61),
  u8(0x41), u8(0x3E), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E), u8(0x3A), u8(0x20), u8(0x63),
  u8(0x6F), u8(0x6F), u8(0x70), u8(0x65), u8(0x72), u8(0x61), u8(0x74), u8(0x69), u8(0x76), u8(0x65), u8(0x20), u8(0x2D),
  u8(0x2D), u8(0x20), u8(0x6F), u8(0x6E), u8(0x6C), u8(0x79), u8(0x20), u8(0x60), u8(0x79), u8(0x69), u8(0x65), u8(0x6C),
  u8(0x64), u8(0x60), u8(0x20), u8(0x73), u8(0x77), u8(0x69), u8(0x74), u8(0x63), u8(0x68), u8(0x65), u8(0x73), u8(0x0A),
  u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x70), u8(0x69), u8(0x6E), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E), u8(0x20), u8(0x3C),
  u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E), u8(0x20), u8(0x3C), u8(0x71), u8(0x75), u8(0x61), u8(0x6E), u8(0x74),
  u8(0x61), u8(0x3E), u8(0x3A), u8(0x20), u8(0x70), u8(0x72), u8(0x65), u8(0x65), u8(0x6D), u8(0x70), u8(0x74), u8(0x69),
  u8(0x76), u8(0x65), u8(0x2C), u8(0x20), u8(0x65), u8(0x6E), u8(0x64), u8(0x73), u8(0x20), u8(0x61), u8(0x66), u8(0x74),
  u8(0x65), u8(0x72), u8(0x20), u8(0x3C), u8(0x71), u8(0x75), u8(0x61), u8(0x6E), u8(0x74), u8(0x61), u8(0x3E), u8(0x0A),
  u8(0x20), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x63), u8(0x68), u8(0x65), u8(0x64),
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x73), u8(0x63), u8(0x68), u8(0x65),
  u8(0x64), u8(0x75), u8(0x6C), u8(0x65), u8(0x72), u8(0x27), u8(0x73), u8(0x20), u8(0x70), u8(0x6F), u8(0x6C), u8(0x69),
  u8(0x63), u8(0x79), u8(0x2C), u8(0x20), u8(0x71), u8(0x75), u8(0x61), u8(0x6E), u8(0x74), u8(0x75), u8(0x6D), u8(0x20),
  u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x70), u8(0x65), u8(0x72), u8(0x2D), u8(0x73), u8(0x6C), u8(0x6F), u8(0x74),
  u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6E), u8(0x74), u8(0x65), u8(0x72), u8(0x73), u8(0x0A), u8(0x20), u8(0x20),
  u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x20), u8(0x75), u8(0x64), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x66), u8(0x61), u8(0x75), u8(0x6C), u8(0x74), u8(0x20), u8(0x6F), u8(0x6E), u8(0x20), u8(0x70),
  u8(0x75), u8(0x72), u8(0x70), u8(0x6F), u8(0x73), u8(0x65), u8(0x20), u8(0x28), u8(0x23), u8(0x55), u8(0x44), u8(0x29),
  u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x63), u8(0x6F), u8(0x6D), u8(0x65), u8(0x20), u8(0x62), u8(0x61),
  u8(0x63), u8(0x6B), u8(0x0A), u8(0x20), u8(0x20), u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x20), u8(0x64),
  u8(0x69), u8(0x76), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x66), u8(0x61), u8(0x75), u8(0x6C), u8(0x74),
  u8(0x20), u8(0x6F), u8(0x6E), u8(0x20), u8(0x70), u8(0x75), u8(0x72), u8(0x70), u8(0x6F), u8(0x73), u8(0x65), u8(0x20),
  u8(0x28), u8(0x23), u8(0x44), u8(0x45), u8(0x29), u8(0x20), u8(0x61), u8(0x6E), u8(0x64), u8(0x20), u8(0x63), u8(0x6F),
  u8(0x6D), u8(0x65), u8(0x20), u8(0x62), u8(0x61), u8(0x63), u8(0x6B), u8(0x0A), u8(0x20), u8(0x20), u8(0x65), u8(0x63),
  u8(0x68), u8(0x6F), u8(0x20), u8(0x3C), u8(0x72), u8(0x65), u8(0x73), u8(0x74), u8(0x3E), u8(0x20), u8(0x20), u8(0x20),
  u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x72), u8(0x65),
  u8(0x73), u8(0x74), u8(0x20), u8(0x6F), u8(0x66), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x6C), u8(0x69),
  u8(0x6E), u8(0x65), u8(0x0A),
];

/// Command name, compared byte-by-byte against the line buffer.
///
/// `"help"` -- 4 bytes.
@rodata
final List<u8> shellCmdHelp = const [
  u8(0x68), u8(0x65), u8(0x6C), u8(0x70),
];

/// Command name.
///
/// `"clear"` -- 5 bytes.
@rodata
final List<u8> shellCmdClear = const [
  u8(0x63), u8(0x6C), u8(0x65), u8(0x61), u8(0x72),
];

/// Command name.
///
/// `"mem"` -- 3 bytes.
@rodata
final List<u8> shellCmdMem = const [
  u8(0x6D), u8(0x65), u8(0x6D),
];

/// Command name.
///
/// `"ticks"` -- 5 bytes.
@rodata
final List<u8> shellCmdTicks = const [
  u8(0x74), u8(0x69), u8(0x63), u8(0x6B), u8(0x73),
];

/// Command name. Matched as a PREFIX too -- see [shellExecute].
///
/// `"echo"` -- 4 bytes.
@rodata
final List<u8> shellCmdEcho = const [
  u8(0x65), u8(0x63), u8(0x68), u8(0x6F),
];

/// `mem` label: total bytes of type-1 (usable) RAM, as 16 hex digits.
///
/// `"MEM USABLE "` -- 11 bytes.
@rodata
final List<u8> shellStrUsable = const [
  u8(0x4D), u8(0x45), u8(0x4D), u8(0x20), u8(0x55), u8(0x53), u8(0x41), u8(0x42), u8(0x4C), u8(0x45), u8(0x20),
];

/// `mem` label: the same total in whole MiB, as 8 hex digits.
///
/// `"MEM MIB "` -- 8 bytes.
@rodata
final List<u8> shellStrMib = const [
  u8(0x4D), u8(0x45), u8(0x4D), u8(0x20), u8(0x4D), u8(0x49), u8(0x42), u8(0x20),
];

/// `ticks` label.
///
/// `"TICKS "` -- 6 bytes.
@rodata
final List<u8> shellStrTicksLbl = const [
  u8(0x54), u8(0x49), u8(0x43), u8(0x4B), u8(0x53), u8(0x20),
];

/// `ticks` separator before the delta this command waited for.
///
/// `" +"` -- 2 bytes.
@rodata
final List<u8> shellStrPlus = const [
  u8(0x20), u8(0x2B),
];

/// `ticks` terminator. Only reachable AFTER the wait loop exits, which is what
/// makes it evidence rather than decoration.
///
/// `" LIVE\n"` -- 6 bytes.
@rodata
final List<u8> shellStrLive = const [
  u8(0x20), u8(0x4C), u8(0x49), u8(0x56), u8(0x45), u8(0x0A),
];

// ---------------------------------------------------------------------------
// M4 (ADR-0007): the `cpu` and `crash` commands, and the recovery notice.
// ---------------------------------------------------------------------------

/// Command name.
///
/// `"cpu"` -- 3 bytes.
@rodata
final List<u8> shellCmdCpu = const [u8(0x63), u8(0x70), u8(0x75)];

/// Command name.
///
///  -- 3 bytes.
@rodata
final List<u8> shellCmdPci = const [u8(0x70), u8(0x63), u8(0x69)];

/// Command name, matched as a PREFIX for the usage message.
///
/// `"crash"` -- 5 bytes.
@rodata
final List<u8> shellCmdCrash = const [u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68)];

/// Whole-line command name. There is no tokenizer (GAP-0057 item 3), so the
/// argument is part of the name the dispatcher compares.
///
/// `"crash ud"` -- 8 bytes.
@rodata
final List<u8> shellCmdCrashUd = const [u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x20), u8(0x75), u8(0x64)];

/// Whole-line command name -- see [shellCmdCrashUd].
///
/// `"crash div"` -- 9 bytes.
@rodata
final List<u8> shellCmdCrashDiv = const [u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x20), u8(0x64), u8(0x69), u8(0x76)];

/// `crash` with no argument, or with one this shell does not know.
///
/// `"crash: usage: crash ud | crash div\n"` -- 35 bytes.
@rodata
final List<u8> shellStrCrashUsage = const [
  u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65),
  u8(0x3A), u8(0x20), u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x20), u8(0x75), u8(0x64), u8(0x20), u8(0x7C),
  u8(0x20), u8(0x63), u8(0x72), u8(0x61), u8(0x73), u8(0x68), u8(0x20), u8(0x64), u8(0x69), u8(0x76), u8(0x0A),
];

/// Printed BEFORE the fault, so the capture shows the kernel meant to do it.
///
/// `"CRASH: executing an invalid opcode (#UD)\n"` -- 41 bytes.
@rodata
final List<u8> shellStrCrashUd = const [
  u8(0x43), u8(0x52), u8(0x41), u8(0x53), u8(0x48), u8(0x3A), u8(0x20), u8(0x65), u8(0x78), u8(0x65), u8(0x63), u8(0x75),
  u8(0x74), u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x69), u8(0x6E), u8(0x76), u8(0x61),
  u8(0x6C), u8(0x69), u8(0x64), u8(0x20), u8(0x6F), u8(0x70), u8(0x63), u8(0x6F), u8(0x64), u8(0x65), u8(0x20), u8(0x28),
  u8(0x23), u8(0x55), u8(0x44), u8(0x29), u8(0x0A),
];

/// Printed BEFORE the fault.
///
/// `"CRASH: dividing by zero (#DE)\n"` -- 30 bytes.
@rodata
final List<u8> shellStrCrashDiv = const [
  u8(0x43), u8(0x52), u8(0x41), u8(0x53), u8(0x48), u8(0x3A), u8(0x20), u8(0x64), u8(0x69), u8(0x76), u8(0x69), u8(0x64),
  u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x62), u8(0x79), u8(0x20), u8(0x7A), u8(0x65), u8(0x72), u8(0x6F), u8(0x20),
  u8(0x28), u8(0x23), u8(0x44), u8(0x45), u8(0x29), u8(0x0A),
];

/// `cpu` label: the 12-byte CPUID leaf-0 vendor string.
///
/// `"CPU VENDOR "` -- 11 bytes.
@rodata
final List<u8> shellStrCpuVendor = const [u8(0x43), u8(0x50), u8(0x55), u8(0x20), u8(0x56), u8(0x45), u8(0x4E), u8(0x44), u8(0x4F), u8(0x52), u8(0x20)];

/// `cpu` label: the 48-byte CPUID extended brand string.
///
/// `"CPU BRAND "` -- 10 bytes.
@rodata
final List<u8> shellStrCpuBrand = const [u8(0x43), u8(0x50), u8(0x55), u8(0x20), u8(0x42), u8(0x52), u8(0x41), u8(0x4E), u8(0x44), u8(0x20)];

/// `cpu` label: highest standard CPUID leaf.
///
/// `"CPU LEAF "` -- 9 bytes.
@rodata
final List<u8> shellStrCpuLeaf = const [u8(0x43), u8(0x50), u8(0x55), u8(0x20), u8(0x4C), u8(0x45), u8(0x41), u8(0x46), u8(0x20)];

/// `cpu` separator: highest extended CPUID leaf.
///
/// `" EXT "` -- 5 bytes.
@rodata
final List<u8> shellStrCpuExt = const [u8(0x20), u8(0x45), u8(0x58), u8(0x54), u8(0x20)];

/// Printed by [shellRecover] on the RECOVERED stack, after the faulting
/// computation has been abandoned. Its position in the capture is the evidence:
/// nothing prints it except a shell that got control back.
///
/// `"FAULT RECOVERED "` -- 16 bytes.
@rodata
final List<u8> shellStrRecovered = const [
  u8(0x46), u8(0x41), u8(0x55), u8(0x4C), u8(0x54), u8(0x20), u8(0x52), u8(0x45), u8(0x43), u8(0x4F), u8(0x56), u8(0x45),
  u8(0x52), u8(0x45), u8(0x44), u8(0x20),
];

/// Tail of the recovery line. Says what this is and is not: the computation is
/// GONE, not repaired and not resumed.
///
/// `" -- faulting computation abandoned, shell resumed\n"` -- 50 bytes.
@rodata
final List<u8> shellStrAbandoned = const [
  u8(0x20), u8(0x2D), u8(0x2D), u8(0x20), u8(0x66), u8(0x61), u8(0x75), u8(0x6C), u8(0x74), u8(0x69), u8(0x6E), u8(0x67),
  u8(0x20), u8(0x63), u8(0x6F), u8(0x6D), u8(0x70), u8(0x75), u8(0x74), u8(0x61), u8(0x74), u8(0x69), u8(0x6F), u8(0x6E),
  u8(0x20), u8(0x61), u8(0x62), u8(0x61), u8(0x6E), u8(0x64), u8(0x6F), u8(0x6E), u8(0x65), u8(0x64), u8(0x2C), u8(0x20),
  u8(0x73), u8(0x68), u8(0x65), u8(0x6C), u8(0x6C), u8(0x20), u8(0x72), u8(0x65), u8(0x73), u8(0x75), u8(0x6D), u8(0x65),
  u8(0x64), u8(0x0A),
];


// ---------------------------------------------------------------------------
// Mutable storage.
//
// Until M17 (ADR-0021) every word below was hand-donated `.bss` in
// `core/boot/kdata.S`, because DCDart had no mutable static data of any kind
// (docs/known-gaps.md GAP-0053). DCDart grew `@bss` (its ADR-0051) and they are
// now DCDart mutable statics, declared here, in the file that uses them. The
// line buffer is the one that shows what the gap was costing: 256 bytes of
// hand-written assembly to express what `const Bss(bytes: shellLineMax)` now
// says in one line, and the bound is now the SAME CONSTANT the editor checks
// against rather than a second copy of it.
//
// THE ACCESSOR NAMES DID NOT CHANGE, deliberately. `shell_line_addr()` and its
// five siblings are called from seventeen places across two files; keeping the
// names made this a change to six declarations and six one-line bodies and to
// NOTHING ELSE, which is the property ADR-0011 section 0 was written to make
// measurable. They read as C names because they used to be C symbols; renaming
// them is cosmetic and belongs to whoever wants it, not to this migration.
// `tests/conformance/m3-shell/run.sh` still asserts the total.
// ---------------------------------------------------------------------------

/// The 256-byte line buffer, sized from [shellLineMax] itself.
@bss
final Bss shellLineBuf = const Bss(bytes: shellLineMax);

/// Address of the block above. **The whole storage seam for this word.**
@bare
u64 shell_line_addr() {
  return Bss.addressOf(shellLineBuf);
}

/// The line-length word (bytes currently in the buffer).
@bss
final Bss shellLenWord = const Bss(bytes: 8);

/// Address of the block above. **The whole storage seam for this word.**
@bare
u64 shell_len_addr() {
  return Bss.addressOf(shellLenWord);
}

/// The shell state word: 0 = accepting, 1 = line submitted,
/// 2 = command running.
@bss
final Bss shellStateWord = const Bss(bytes: 8);

/// Address of the block above. **The whole storage seam for this word.**
@bare
u64 shell_state_addr() {
  return Bss.addressOf(shellStateWord);
}

/// The word holding the Multiboot information-structure pointer.
///
/// `boot.S` stashes that pointer in ITS own `.bss` and hands it to `kmain()`
/// as an ordinary C-ABI argument. The shell needs it again, long after
/// `kmain`'s frame is gone, so `shellInit()` copies it here.
///
/// Deliberately a COPY rather than an accessor for `boot.S`'s own stash: an
/// accessor in `kdata.S` would need `multiboot_info_ptr` made global and would
/// give `kdata.o` an undefined symbol, which would break the one assembly
/// object that currently passes `verify-freestanding.sh` standalone
/// (docs/known-gaps.md GAP-0056 records that pass as a real data point). Eight
/// bytes is the honest price of keeping it.
@bss
final Bss shellMbinfoWord = const Bss(bytes: 8);

/// Address of the block above. **The whole storage seam for this word.**
@bare
u64 shell_mbinfo_addr() {
  return Bss.addressOf(shellMbinfoWord);
}

/// The one-byte "an 0xE0 prefix was seen" flag -- GAP-0055 item 2.
@bss
final Bss kbdPrefixWord = const Bss(bytes: 8);

/// Address of the block above. **The whole storage seam for this word.**
@bare
u64 kbd_prefix_addr() {
  return Bss.addressOf(kbdPrefixWord);
}

/// Address of the 64-byte CPUID result block: a 12-byte vendor string at +0
/// and a 48-byte brand string at +16.
///
/// **This accessor is the whole answer to "how do you return a 12-byte string
/// across the DCDart/assembly boundary?"** You do not. An extern signature is
/// scalars only (DCDart GAP-0025), `@bare` DCDart has no String type and no
/// array type, and `@rodata` is read-only, so there is nothing a `cpuid`
/// result could be returned *as* and nothing it could be stored *into*.
/// `cpu_probe()` writes the bytes into donated `.bss` and this hands back the
/// address they landed at. Cost recorded in docs/known-gaps.md GAP-0061.
///
/// **STILL DONATED AFTER M17, deliberately (ADR-0021 section 4).** `cpu_probe`
/// in `core/boot/isr.S` writes this block by name — `leaq cpu_info(%rip), %r8`
/// — and a DCDart `@bss` symbol is LOCAL to `kmain.o`, so assembly cannot name
/// one. Migrating it would mean changing `cpu_probe`'s signature to take a
/// destination pointer, which is a change to an assembly function rather than
/// to a storage seam, and it is not what this milestone was for. 64 of the 96
/// bytes left in `kdata.S` are this block. See GAP-0134.
@extern
external u64 cpu_info_addr();

/// The count of faults caught and recovered from since boot.
@bss
final Bss faultCountWord = const Bss(bytes: 8);

/// Address of the block above. **The whole storage seam for this word.**
@bare
u64 fault_count_addr() {
  return Bss.addressOf(faultCountWord);
}

/// Address of the "the shell's resume point is valid" guard word.
///
/// Written 1 by `shell_run_forever` in `core/boot/isr.S` at the instant it
/// records the stack pointer, and checked by `fault_resume` before it switches
/// stacks. [shellInit] zeroes it, which is the half that matters: `.bss` is not
/// zeroed by anything in this kernel, so without this a fault taken before the
/// shell ever started would resume onto a garbage stack pointer and triple-fault
/// the machine *while reporting a fault*.
///
/// **STILL DONATED AFTER M17, and it always will be (ADR-0021 section 4).**
/// `shell_run_forever` writes this word and `shell_resume_rsp` beside it, both
/// by name, from `core/boot/isr.S`, at the instant a fault is taken. A `@bss`
/// symbol is LOCAL to `kmain.o`; assembly cannot name one, and there is nowhere
/// to pass an address in from at fault time. `user.dart` says the same thing
/// about `user_resume_ok`.
@extern
external u64 shell_resume_ok_addr();

/// Fills the CPUID block and returns `(highest extended leaf << 32) |
/// (highest standard leaf)`.
///
/// `cpuid` has no DCDart primitive and DCDart has no general inline `asm()`
/// (GAP-0002), so it lives in `core/boot/isr.S` behind a C-ABI call — the same
/// boundary `lidt`, `int3` and `hlt` already use.
@extern
external u64 cpu_probe();

/// Executes a `div` with a zero divisor. **Never returns** — it faults.
///
/// In assembly because DCDart *cannot* produce a #DE: `dcc` emits an explicit
/// zero-divisor check in front of every `~/` and `%` and traps with `ud2`
/// instead, so a DCDart division by zero is a #UD (vector 6), not a divide
/// error (vector 0). Verified by disassembling real `dcc` output, not assumed.
/// docs/known-gaps.md GAP-0063.
@extern
external void divide_by_zero();

/// Records the stack pointer the shell runs on, then runs [shellMain].
/// **Never returns.**
///
/// Replaces a direct call to [shellMain] from `m2Enter()`, and the only thing
/// it adds is that one store — which has to be in assembly, because DCDart
/// cannot read RSP. That single word is the entire state of fault recovery.
@extern
external void shell_run_forever();

/// Abandons the faulting computation and resumes the shell. **Never returns.**
///
/// Called from the fault arm of [isrDispatch] *after* the diagnostic has been
/// printed. Sets RSP back to the value [shell_run_forever] recorded, which
/// discards every frame between the shell loop and the fault in one store, and
/// calls [shellRecover] and then [shellMain] on that stack.
///
/// **What this is:** fault survival with abandonment of the faulting
/// computation. **What it is not:** resumption of it. The command that faulted
/// is gone — not repaired, not retried, not resumed. See ADR-0007.
@extern
external void fault_resume();

/// `sti; hlt; ret` -- ONE wake-up, not a loop.
///
/// The loop lives in [shellMain] where DCDart can see it, so the flag test and
/// the sleep are in the same language. `idle_forever` (M2's `sti; hlt; jmp`)
/// still exists in `isr.S` but nothing calls it any more: a shell has to wake
/// up and do something, which is precisely what a routine that never returns
/// cannot do.
@extern
external void idle_once();

/// Reads the line length.
@bare
u64 shellLen() {
  return Pointer<u64>.fromAddress(shell_len_addr()).value;
}

/// Writes the line length.
@bare
void shellSetLen(u64 n) {
  Pointer<u64>.fromAddress(shell_len_addr()).value = n;
}

/// Reads the shell state word.
@bare
u64 shellState() {
  return Pointer<u64>.fromAddress(shell_state_addr()).value;
}

/// Writes the shell state word.
@bare
void shellSetState(u64 s) {
  Pointer<u64>.fromAddress(shell_state_addr()).value = s;
}

/// Reads byte [i] of the line buffer. Callers keep `i < shellLen()`.
@bare
u8 shellLineByte(u64 i) {
  return Pointer<u8>.fromAddress(shell_line_addr() + i).value;
}

/// The address of the line buffer's first byte.
///
/// M15: `fat.dart`'s 8.3-name parser now has TWO sources -- the typed line, and
/// a byte range a ring-3 program handed to `open` -- and it would be a bad
/// trade to keep two copies of a parser so that one of them could keep reading
/// the line a byte at a time. One parser, two callers, and this is how the
/// shell's caller names its bytes. See ADR-0019 §3.
@bare
u64 shellLineBase() {
  return shell_line_addr();
}

/// Reads the saved 0xE0-prefix flag.
@bare
u64 kbdPrefix() {
  return Pointer<u64>.fromAddress(kbd_prefix_addr()).value;
}

/// Writes the 0xE0-prefix flag.
@bare
void kbdSetPrefix(u64 v) {
  Pointer<u64>.fromAddress(kbd_prefix_addr()).value = v;
}

/// Initializes every donated word the shell owns, and stores the Multiboot
/// information pointer for `mem` to re-walk later.
///
/// Called FIRST from `kmain()`, next to `vgaInit()`, and for the same reason:
/// nothing in this kernel zeroes `.bss`, so a garbage `shell_len` would make
/// the first keystroke store hundreds of bytes past the buffer, and a garbage
/// `kbd_prefix` would swallow the first real key. Prints nothing, so M0's
/// banner is still the first byte on COM1.
@bare
void shellInit(u64 mbInfo) {
  shellSetLen(u64(0));
  shellSetState(u64(0));
  kbdSetPrefix(u64(0));
  Pointer<u64>.fromAddress(shell_mbinfo_addr()).value = mbInfo;
  // M4. Both of these must be zero before ANYTHING in this kernel is able to
  // fault, which is why they are set here, in the first call kmain() makes,
  // rather than next to the code that uses them:
  //
  //   fault_count      would otherwise print whatever .bss held;
  //   shell_resume_ok  would otherwise let `fault_resume` load a garbage RSP
  //                    and triple-fault the machine while reporting a fault.
  Pointer<u64>.fromAddress(fault_count_addr()).value = u64(0);
  Pointer<u64>.fromAddress(shell_resume_ok_addr()).value = u64(0);
}

/// Reads the count of faults recovered from since boot.
@bare
u64 faultCount() {
  return Pointer<u64>.fromAddress(fault_count_addr()).value;
}

/// Records one more recovered fault. Called from the fault handler, in
/// interrupt context, before the stack is abandoned.
@bare
void faultCountBump() {
  Pointer<u64>.fromAddress(fault_count_addr()).value = faultCount() + u64(1);
}

// ---------------------------------------------------------------------------
// The line editor. Runs in INTERRUPT context (called from kbdHandle).
// ---------------------------------------------------------------------------

/// Maximum bytes the line buffer holds. Matches `core/boot/kdata.S` exactly;
/// `tests/conformance/m3-shell/run.sh` asserts the donated size, so the two
/// cannot drift apart silently.
const int shellLineMax = 256;

/// Prints the prompt to BOTH outputs and parks the hardware cursor after it.
@bare
void shellPrompt() {
  uartWrite(Rodata.addressOf(shellStrPrompt), u64(10));
  vgaUpdateHwCursor();
}

/// Handles one translated character from the keyboard.
///
/// Three cases, and the middle one is the whole point of this milestone:
///
///   * **Enter (0x0A)** -- echo the newline and mark the line submitted. The
///     command is NOT run here; `shellMain` runs it in task context.
///   * **Backspace (0x08)** -- only when the buffer is non-empty. That single
///     guard is what makes the prompt uneraseable: backspacing at an empty
///     prompt is not "move the cursor left", it is nothing at all, because the
///     editor's model of the line is the buffer and the buffer is empty. No
///     screen-column arithmetic is involved, so it stays correct after the
///     line wraps a row or the screen scrolls.
///   * **Anything else** -- append and echo, unless the buffer is full, in
///     which case the key is dropped WITHOUT an echo. Echoing a character that
///     was not stored would put the screen and the buffer permanently out of
///     step, which is worse than a keystroke that visibly does nothing.
@bare
void shellKey(u8 c) {
  if (c == u8(0x0A)) {
    conPutc(u8(0x0A));
    shellSetState(u64(1));
    return;
  }
  if (c == u8(0x08)) {
    final u64 n = shellLen();
    if (n < u64(1)) {
      return; // at the prompt: nothing to erase, and the prompt is not ours
    }
    shellSetLen(n - u64(1));
    conPutc(u8(0x08));
    return;
  }
  final u64 n = shellLen();
  if (n < u64(shellLineMax)) {
    Pointer<u8>.fromAddress(shell_line_addr() + n).value = c;
    shellSetLen(n + u64(1));
    conPutc(c);
  }
}

// ---------------------------------------------------------------------------
// Command matching. Two byte ranges and a loop -- there are no strings.
// ---------------------------------------------------------------------------

/// Returns 1 if the first [n] bytes of the line buffer equal the [n] bytes at
/// [tbl], else 0. `u64` rather than `bool` because DCDart has no boolean
/// operators at all (GAP-0023) and a `u64` composes with the `if` chains
/// below without needing any.
@bare
u64 shellMatch(u64 tbl, u64 n) {
  final u64 line = shell_line_addr();
  u64 i = u64(0);
  while (i < n) {
    final u8 a = Pointer<u8>.fromAddress(line + i).value;
    final u8 b = Pointer<u8>.fromAddress(tbl + i).value;
    if (a == b) {
      i = i + u64(1);
    } else {
      return u64(0);
    }
  }
  return u64(1);
}

/// Whole-line match: the line is exactly the [n]-byte name at [tbl].
@bare
u64 shellIsCmd(u64 tbl, u64 n) {
  if (shellLen() == n) {
    return shellMatch(tbl, n);
  }
  return u64(0);
}

/// Prefix match: the line begins with the [n]-byte name at [tbl].
@bare
u64 shellStartsWith(u64 tbl, u64 n) {
  if (shellLen() < n) {
    return u64(0);
  }
  return shellMatch(tbl, n);
}

/// Writes the line buffer's bytes from [from] to the end, to both outputs.
@bare
void shellWriteLineFrom(u64 from) {
  final u64 len = shellLen();
  u64 i = from;
  while (i < len) {
    conPutc(shellLineByte(i));
    i = i + u64(1);
  }
}

// ---------------------------------------------------------------------------
// Commands.
// ---------------------------------------------------------------------------

/// `help`
///
/// The length is 1028 because the table is 1028 bytes. It was 237 until M4 added
/// two commands, and the first build after that change printed 237 bytes of a
/// 395-byte table -- `cpu           CPUID vendor, brand and lea` and then the
/// next prompt. That is docs/known-gaps.md GAP-0060 happening, not a typo: a
/// `@rodata` table carries no length, so this number is maintained by hand at
/// every call site, and the only thing that catches a wrong one is that every
/// byte this kernel prints is in a byte-exact golden.
@bare
void shellHelp() {
  uartWrite(Rodata.addressOf(shellStrHelp), u64(2511));
}

/// `clear` -- blank the screen and home the cursor.
///
/// Screen-only by nature: there is no way to un-print bytes that already went
/// down a serial line, and pretending otherwise (a screenful of newlines, an
/// ANSI escape) would be a different operation wearing this one's name. The
/// serial capture therefore shows the echoed `clear` and the next prompt and
/// nothing between them, which is exactly what happened.
@bare
void shellClear() {
  vgaSetCursor(u64(0));
  vgaClear();
  vgaUpdateHwCursor();
}

/// `echo <rest>` -- print the line from [from] to the end, then a newline.
@bare
void shellEcho(u64 from) {
  shellWriteLineFrom(from);
  uartNewline();
}

/// Sums the lengths of every type-1 (usable RAM) region in the Multiboot
/// memory map, in bytes.
///
/// This is the result the boot-time dump does not produce: `mbReport` prints
/// each region, but nothing has ever added them up, because at boot there was
/// nowhere to put a running total and no one to ask.
///
/// Reads the 64-bit `length` field as TWO `u32` loads recombined rather than
/// one `u64` load, deliberately. Multiboot1 guarantees 4-byte alignment and
/// nothing more; `length` sits at entry+12, which is 4-aligned but need not be
/// 8-aligned, and DC-IR's `Load` carries no alignment attribute (the same
/// reasoning `multiboot.dart`'s header records for every other field it
/// reads).
///
/// Returns 0 rather than a wrong number if the structure is unusable -- the
/// same structural guards `mbReport` applies, in the same order.
@bare
u64 mbUsableTotal(u64 info) {
  if ((info & u64(3)) > u64(0)) {
    return u64(0);
  }
  final u8 flagsLow = Pointer<u8>.fromAddress(info).value;
  if ((flagsLow & u8(0x40)) < u8(1)) {
    return u64(0); // no memory map at all
  }
  final u64 mmapLen = mbU32(info + u64(44));
  final u64 mmapAddr = mbU32(info + u64(48));
  if ((mmapAddr & u64(3)) > u64(0)) {
    return u64(0);
  }
  u64 total = u64(0);
  u64 off = u64(0);
  while (off < mmapLen) {
    final u64 entry = mmapAddr + off;
    if ((entry & u64(3)) > u64(0)) {
      return total;
    }
    final u64 size = mbU32(entry);
    if (size < u64(1)) {
      return total; // a zero-size entry would make this walk never advance
    }
    if (mbU32(entry + u64(20)) == u64(1)) {
      final u64 lo = mbU32(entry + u64(12));
      final u64 hi = mbU32(entry + u64(16));
      total = total + lo + (hi << u64(32));
    }
    off = off + size + u64(4);
  }
  return total;
}

/// `mem` -- re-walk the memory map the loader handed us, and total it.
///
/// Reuses `mbReport` unchanged: the same walk the kernel ran at boot, over the
/// same structure, from the pointer `boot.S` stashed. Running it again from a
/// prompt is itself a claim worth testing -- the structure is still there,
/// still parseable, and still says the same thing after interrupts, a fault,
/// and a console have all happened on top of it. The harness asserts the two
/// dumps are identical.
@bare
void shellMem() {
  final u64 info = Pointer<u64>.fromAddress(shell_mbinfo_addr()).value;
  mbReport(info);
  final u64 total = mbUsableTotal(info);
  uartWrite(Rodata.addressOf(shellStrUsable), u64(11));
  uartPutHex(total, u64(16));
  uartNewline();
  uartWrite(Rodata.addressOf(shellStrMib), u64(8));
  uartPutHex(total >> u64(20), u64(8));
  uartNewline();
}

/// How many ticks `ticks` waits for. 0x10 at the PIT's 100 Hz is 160 ms --
/// long enough that a stopped counter cannot fake it, short enough that the
/// shell does not feel wedged.
const int shellTickDelta = 0x10;

/// `ticks` -- prove the PIT counter is still advancing.
///
/// **Why this prints a starting value and a delta rather than the live
/// counter.** A raw live count is a duration, and a duration is not
/// reproducible, so it could never appear in a byte-exact golden. M1 solved
/// exactly this problem the same way and said so: "the COUNT is the trigger,
/// not a duration, so the output is identical regardless of how fast the host
/// is." The evidence here is that ` LIVE` is printed AFTER a loop whose only
/// exit is the counter reaching `start + 0x10`. If the timer is dead the loop
/// never exits and the harness fails on a timeout -- a hard failure, never a
/// wrong number.
///
/// **Why IRQ0 is unmasked here and re-masked afterwards.** M2 left the PIT
/// masked because nothing needed a timer and a 100 Hz interrupt would only add
/// jitter between keystrokes. That is still true, and it has a second benefit:
/// with the PIT masked at rest, `start` is a fixed value (100 -- the count M1
/// stopped at) instead of a function of how long the operator took to type,
/// which is what makes this line assertable at all. The honest statement of
/// the limitation is in docs/known-gaps.md GAP-0058.
///
/// This runs in TASK context with IF set, which is the only reason it works:
/// inside `kbdHandle` the interrupt gate has already cleared IF, no timer
/// interrupt could ever be delivered, and this loop would spin forever.
@bare
void shellTicks() {
  final u64 start = tick_count();
  final u64 target = start + u64(shellTickDelta);
  picUnmaskTimerAndKeyboard();
  u64 now = tick_count();
  while (now < target) {
    now = tick_count();
  }
  picUnmaskKeyboardOnly();
  uartWrite(Rodata.addressOf(shellStrTicksLbl), u64(6));
  uartPutHex(start, u64(16));
  uartWrite(Rodata.addressOf(shellStrPlus), u64(2));
  uartPutHex(u64(shellTickDelta), u64(4));
  uartWrite(Rodata.addressOf(shellStrLive), u64(6));
}

// ---------------------------------------------------------------------------
// M4: `cpu`.
// ---------------------------------------------------------------------------

/// Byte offset of the vendor string inside the CPUID block, and its length.
/// CPUID leaf 0 returns it in EBX, EDX, ECX — twelve bytes, no terminator.
const int cpuVendorOffset = 0;
const int cpuVendorLen = 12;

/// Byte offset of the brand string inside the CPUID block, and its length.
/// Leaves 0x80000002..4 return 48 bytes, NUL-padded on every real CPU.
const int cpuBrandOffset = 16;
const int cpuBrandLen = 48;

/// Returns the index of the first non-space byte in `[base, base+max)`, or
/// [max] if they are all spaces.
///
/// Needed because Intel pads the brand string with LEADING spaces (`"      Intel(R)
/// Core(TM)..."`), and printing them would put a ragged left margin in a
/// byte-exact golden for no information. A separate function rather than an
/// inline loop because DCDart has no `break` out of a `while` and no boolean
/// operators to fold the two conditions into one (GAP-0023) — an early
/// `return` from a helper is the idiom this language leaves.
@bare
u64 cpuSkipSpaces(u64 base, u64 max) {
  u64 i = u64(0);
  while (i < max) {
    if (Pointer<u8>.fromAddress(base + i).value == u8(0x20)) {
      i = i + u64(1);
    } else {
      return i;
    }
  }
  return i;
}

/// Writes up to [max] bytes from [base], skipping leading spaces and stopping
/// at the first non-printable byte.
///
/// The stop condition is what makes this safe to point at CPUID output: the
/// brand string is NUL-padded to a fixed 48 bytes, and writing those NULs to
/// the screen would put 20 glyphs of garbage next to a CPU name. There is no
/// `strlen` to call and nothing to call it on — this IS the string layer.
@bare
void cpuWrite(u64 base, u64 max) {
  u64 i = cpuSkipSpaces(base, max);
  while (i < max) {
    final u8 c = Pointer<u8>.fromAddress(base + i).value;
    if (c < u8(0x20)) {
      return; // NUL padding, or anything else unprintable: the string ends
    }
    if (c > u8(0x7E)) {
      return;
    }
    conPutc(c);
    i = i + u64(1);
  }
}

/// `cpu` — ask the CPU what it is.
///
/// Three lines, and every byte of the first two comes from the hardware rather
/// than from this kernel:
///
///     CPU VENDOR AuthenticAMD
///     CPU BRAND QEMU Virtual CPU version 2.5+
///     CPU LEAF 0000000D EXT 80000008
///
/// The leaf limits are printed because they are the honest bound on everything
/// else CPUID could be asked: a brand string is only readable at all because
/// the extended limit reaches 0x80000004, and `cpu_probe` checks that rather
/// than assuming it.
@bare
void shellCpu() {
  final u64 limits = cpu_probe();
  final u64 info = cpu_info_addr();
  uartWrite(Rodata.addressOf(shellStrCpuVendor), u64(11));
  cpuWrite(info + u64(cpuVendorOffset), u64(cpuVendorLen));
  uartNewline();
  uartWrite(Rodata.addressOf(shellStrCpuBrand), u64(10));
  cpuWrite(info + u64(cpuBrandOffset), u64(cpuBrandLen));
  uartNewline();
  uartWrite(Rodata.addressOf(shellStrCpuLeaf), u64(9));
  uartPutHex(limits & u64(0xFFFFFFFF), u64(8));
  uartWrite(Rodata.addressOf(shellStrCpuExt), u64(5));
  uartPutHex(limits >> u64(32), u64(8));
  uartNewline();
}

// ---------------------------------------------------------------------------
// M4: `crash`. The commands that exist to fail.
// ---------------------------------------------------------------------------

/// `crash ud` — execute an invalid opcode and come back from it.
///
/// The fault is DCDart's OWN overflow trap, not a hand-written `ud2`: adding
/// `0xFFFFFFFFFFFFFFFF` to a non-zero `u64` overflows, DCDart's arithmetic
/// traps on overflow (DCDART_SPEC §4.1), and the trap is a real conditional
/// `ud2` in the emitted code. That makes this the same fault M1 already proved
/// the kernel can *catch*, and the only thing M4 changes is what happens next.
///
/// Spelled with an opaque operand for the reason `kmain()` spells its own
/// deliberate overflow that way: with two constants LLVM would fold the whole
/// expression at compile time, possibly into `unreachable`, and delete the
/// surrounding code instead of trapping at runtime. `tick_count()` is an extern
/// call, so its result is opaque and is >= 100 by the time any command runs.
///
/// **Never returns.** Control leaves this function through the `ud2`, reaches
/// `isrDispatch`, and comes back to the shell through `fault_resume` — on a
/// stack that predates this frame. The frame is not unwound; it is abandoned.
@bare
void shellCrashUd() {
  uartWrite(Rodata.addressOf(shellStrCrashUd), u64(41));
  final u64 opaque = tick_count();
  final u64 boom = opaque + u64(0xFFFFFFFFFFFFFFFF);
  // Not reached. Consuming `boom` keeps the overflowing add from being dead
  // code a future optimizer could drop, exactly as in kmain().
  uartPutHex(boom, u64(16));
}

/// `crash div` — take a real divide error and come back from it.
///
/// **Not a DCDart division, and that is a finding rather than a shortcut.**
/// `a ~/ b` cannot produce a #DE: `dcc` emits `test`/`je` in front of the
/// `div` and traps a zero divisor with `ud2`, so it would land on vector 6
/// like `crash ud` and prove nothing new. The `div` is executed in assembly
/// (`divide_by_zero`, core/boot/isr.S) so the CPU raises a genuine #DE on
/// vector 0 — a different fault class, through the same recovery path.
/// docs/known-gaps.md GAP-0063.
///
/// **Never returns.**
@bare
void shellCrashDiv() {
  uartWrite(Rodata.addressOf(shellStrCrashDiv), u64(30));
  divide_by_zero();
}

/// `crash` with no argument, or with one this shell does not know.
@bare
void shellCrashUsage() {
  uartWrite(Rodata.addressOf(shellStrCrashUsage), u64(35));
}

/// Unknown command: name what was typed. Never fails silently -- a shell that
/// swallows a typo is indistinguishable from one that is broken.
@bare
void shellUnknown() {
  uartWrite(Rodata.addressOf(shellStrUnknown), u64(27));
  shellWriteLineFrom(u64(0));
  uartNewline();
}

// ---------------------------------------------------------------------------
// A KNOWN COMMAND WITH JUNK AFTER IT IS NOT AN UNKNOWN COMMAND.
//
// Every command in this shell that takes NO argument is dispatched by
// whole-line exact match ([shellIsCmd] compares a length as well as bytes), so
// until this was written, `help now` fell all the way through to
// [shellUnknown] and the shell answered
//
//     oscortex: unknown command: help now
//
// -- which names a command nobody has heard of, for a line whose first word is
// the most basic command there is. The refusal was CORRECT (the shell survived
// and did not guess); it was unhelpful, and uniformly so across every
// zero-argument form, which makes it one decision rather than eleven bugs.
//
// **The commands that TAKE arguments already do better**, and they are what
// this is modelled on: `disk`, `frames`, `vmtest`, `user`, `crash`, `proc`,
// `run` and `cat` each keep a trailing PREFIX matcher whose only job is to
// answer a malformed invocation with a usage line -- the "<cmd> IS a command,
// it just needs to be told what to do" path this file names in six places. A
// zero-argument command has no usage line to print, because there is nothing to
// tell it; what it has to say is that the words after it are not its.
//
// So: `oscortex: help takes no argument`, and the eleven names below are
// exactly the exact-match commands with no prefix matcher behind them. The
// others do not reach here at all.
// ---------------------------------------------------------------------------

/// Writes bytes `[from, to)` of the line buffer to both outputs.
///
/// [shellWriteLineFrom] writes to the END of the line, which is what the
/// unknown-command path wants; this writes a RANGE, which is what naming the
/// command at the head of a line wants.
@bare
void shellWriteLineRange(u64 from, u64 to) {
  u64 i = from;
  while (i < to) {
    conPutc(shellLineByte(i));
    i = i + u64(1);
  }
}

/// `oscortex: <the first [n] bytes of the line> takes no argument`
@bare
void shellNoArg(u64 n) {
  uartWrite(Rodata.addressOf(shellStrOscortex), u64(10));
  shellWriteLineRange(u64(0), n);
  uartWrite(Rodata.addressOf(shellStrNoArg), u64(19));
}

/// 1 if the line is the [n]-byte command at [tbl] followed by a SPACE and then
/// something, in which case the refusal has already been printed.
///
/// The space is required, so `lsx` is still an unknown command and `ls -l` is
/// not: a name that merely starts with a command's letters is a different word,
/// and this is the same rule `echo` already applies to `echonow`.
@bare
u64 shellNoArgTry(u64 tbl, u64 n) {
  if (shellLen() <= n) {
    return u64(0);
  }
  if (shellLineByte(n) != u8(0x20)) {
    return u64(0);
  }
  if (shellStartsWith(tbl, n) < u64(1)) {
    return u64(0);
  }
  shellNoArg(n);
  return u64(1);
}

/// The eleven zero-argument commands, tried in the order [shellExecute]
/// dispatches them. A chain of `if`s for [shellExecute]'s own reason: DCDart has
/// no function pointers, so a table of names is not expressible.
@bare
u64 shellNoArgRefused() {
  if (shellNoArgTry(Rodata.addressOf(shellCmdHelp), u64(4)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(shellCmdClear), u64(5)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(shellCmdMem), u64(3)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(shellCmdTicks), u64(5)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(shellCmdCpu), u64(3)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(shellCmdPci), u64(3)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(fbStrCmd), u64(2)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(pmmCmdAlloc), u64(5)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(vmCmdVm), u64(2)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(fatCmdFs), u64(2)) > u64(0)) {
    return u64(1);
  }
  if (shellNoArgTry(Rodata.addressOf(fatCmdLs), u64(2)) > u64(0)) {
    return u64(1);
  }
  return u64(0);
}

/// Dispatches the line buffer.
///
/// A chain of `if`s, not a table: DCDart has no function pointers and no
/// dynamic dispatch of ANY kind, so a `{name, handler}` table is not
/// expressible in this language. The chain is the honest shape, and it is the
/// same reason `isrDispatch` branches on the vector instead of indexing.
///
/// An empty line is not an error -- it prints a fresh prompt and nothing else,
/// which is what every shell does.
@bare
void shellExecute() {
  if (shellLen() < u64(1)) {
    return;
  }
  if (shellIsCmd(Rodata.addressOf(shellCmdHelp), u64(4)) > u64(0)) {
    shellHelp();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(shellCmdClear), u64(5)) > u64(0)) {
    shellClear();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(shellCmdMem), u64(3)) > u64(0)) {
    shellMem();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(shellCmdTicks), u64(5)) > u64(0)) {
    shellTicks();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(shellCmdCpu), u64(3)) > u64(0)) {
    shellCpu();
    return;
  }
  // M5. Enumerating the PCI bus is the first thing this shell does that
  // DISCOVERS hardware rather than addressing hardware it was compiled to
  // know about -- see core/kernel/pci.dart's header.
  if (shellIsCmd(Rodata.addressOf(shellCmdPci), u64(3)) > u64(0)) {
    shellPci();
    return;
  }
  // M5 part 2. The framebuffer console: find the display controller by class,
  // read BAR0, set a graphics mode, and draw into it -- core/kernel/fb.dart.
  if (shellIsCmd(Rodata.addressOf(fbStrCmd), u64(2)) > u64(0)) {
    shellFb();
    return;
  }
  // M6. `disk id` and `disk read <lba>` -- the first command in this shell
  // that reads bytes off a storage device, over ATA PIO
  // (core/kernel/ata.dart). `disk read` is a PREFIX match because it takes a
  // real argument, and the argument is parsed out of the line buffer rather
  // than being part of the name the way `crash ud` is: an LBA is a number, and
  // there are 2^28 of them.
  if (shellIsCmd(Rodata.addressOf(ataCmdIdName), u64(7)) > u64(0)) {
    shellDiskId();
    return;
  }
  if (shellStartsWith(Rodata.addressOf(ataCmdReadName), u64(10)) > u64(0)) {
    shellDiskReadCmd();
    return;
  }
  // `disk` alone, `disk read` with no argument (nine bytes, so it does not
  // match the ten-byte prefix above), and `disk anything-else` all land on the
  // usage line rather than on the unknown-command path -- `disk` IS a command,
  // it just needs to be told what to do.
  if (shellStartsWith(Rodata.addressOf(ataCmdName), u64(4)) > u64(0)) {
    shellDiskUsage();
    return;
  }
  // M7. The physical frame allocator (core/kernel/pmm.dart). The three
  // sub-commands are matched as WHOLE LINES, argument included, for the reason
  // `crash ud` is: there is still no tokenizer (GAP-0057 item 3). They come
  // BEFORE the bare `frames` match so `frames test` is not read as `frames`
  // with something after it, and `frames` alone comes before the prefix match
  // so an unknown argument lands on the usage line rather than on the
  // unknown-command path -- `frames` IS a command, it just needs to be told
  // what to do.
  if (shellIsCmd(Rodata.addressOf(pmmCmdTest), u64(11)) > u64(0)) {
    shellFramesTest();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(pmmCmdDrain), u64(12)) > u64(0)) {
    shellFramesDrain();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(pmmCmdRefill), u64(13)) > u64(0)) {
    shellFramesRefill();
    return;
  }
  // `frames leave <n>` — a PARTIAL drain. A prefix including its trailing
  // space, so `frames leave` alone is twelve bytes, does not match, and falls
  // to the usage line below. See [shellFramesLeave] for why a partial drain
  // exists at all.
  if (shellStartsWith(Rodata.addressOf(pmmCmdLeaveSp), u64(13)) > u64(0)) {
    shellFramesLeave(u64(13));
    return;
  }
  if (shellIsCmd(Rodata.addressOf(pmmCmdFrames), u64(6)) > u64(0)) {
    shellFrames();
    return;
  }
  if (shellStartsWith(Rodata.addressOf(pmmCmdFrames), u64(6)) > u64(0)) {
    shellFramesUsage();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(pmmCmdAlloc), u64(5)) > u64(0)) {
    shellAlloc();
    return;
  }
  // `free ` is a PREFIX including the space, so a physical address follows it.
  // `free` alone is four bytes and does not match, so it falls through to the
  // unknown-command path -- which is right: `free` with nothing to free is not
  // a command that needs telling what to do, it is a command missing its only
  // argument, and `free: usage:` is printed by shellFreeCmd for a malformed
  // one.
  if (shellStartsWith(Rodata.addressOf(pmmCmdFree), u64(5)) > u64(0)) {
    shellFreeCmd();
    return;
  }
  // M8. The address space (core/kernel/vm.dart). `vm` is an EXACT match and
  // comes first so it cannot swallow `vmtest ...`; the four `vmtest` forms are
  // exact matches for the reason `crash ud` is (there is still no tokenizer,
  // GAP-0057 item 3); and the bare `vmtest` prefix comes last so an unknown
  // argument lands on the usage line rather than on the unknown-command path --
  // `vmtest` IS a command, it just needs to be told which property to prove.
  if (shellIsCmd(Rodata.addressOf(vmCmdVm), u64(2)) > u64(0)) {
    vmReport();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(vmCmdTestRo), u64(9)) > u64(0)) {
    vmTestRo(); // faults on purpose; comes back through fault_resume
    return;
  }
  if (shellIsCmd(Rodata.addressOf(vmCmdTestNx), u64(9)) > u64(0)) {
    vmTestNx(); // faults on purpose; comes back through fault_resume
    return;
  }
  if (shellIsCmd(Rodata.addressOf(vmCmdTestRw), u64(9)) > u64(0)) {
    vmTestRw();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(vmCmdTestX), u64(8)) > u64(0)) {
    vmTestX();
    return;
  }
  if (shellStartsWith(Rodata.addressOf(vmCmdTest), u64(6)) > u64(0)) {
    vmTestUsage();
    return;
  }
  // M9. Ring 3 (core/kernel/user.dart). Same shape as `frames` and `vmtest`:
  // whole-line exact matches for every sub-command, in longest-first order so
  // `user` alone cannot swallow `user gp`, and the bare `user` prefix LAST so an
  // unknown argument lands on the usage line rather than on the unknown-command
  // path. There is still no tokenizer (GAP-0057 item 3).
  //
  // Four of the six deliberately end in a fault or a refusal, which is the only
  // way to demonstrate that a privilege boundary exists: `user` is the control
  // that proves ring 3 can run at all.
  if (shellIsCmd(Rodata.addressOf(userCmdUser), u64(4)) > u64(0)) {
    shellUser(u64(userModeRun));
    return;
  }
  if (shellIsCmd(Rodata.addressOf(userCmdGp), u64(7)) > u64(0)) {
    shellUser(u64(userModeGp)); // faults on purpose; comes back through fault_resume
    return;
  }
  if (shellIsCmd(Rodata.addressOf(userCmdPf), u64(7)) > u64(0)) {
    shellUser(u64(userModePf)); // faults on purpose; comes back through fault_resume
    return;
  }
  if (shellIsCmd(Rodata.addressOf(userCmdBadint), u64(11)) > u64(0)) {
    shellUser(u64(userModeBadint)); // faults on purpose
    return;
  }
  if (shellIsCmd(Rodata.addressOf(userCmdBadptr), u64(11)) > u64(0)) {
    shellUser(u64(userModeBadptr));
    return;
  }
  if (shellIsCmd(Rodata.addressOf(userCmdPages), u64(10)) > u64(0)) {
    shellUserPages();
    return;
  }
  // `user hold` NEVER RETURNS: its payload spins in ring 3 forever and this
  // kernel has no way to stop it (no scheduler, no preemption -- GAP-0085). It
  // exists so the page tables can be dumped out of guest memory WHILE a payload
  // is live, which is the only moment at which the U/S bits are set on anything.
  if (shellIsCmd(Rodata.addressOf(userCmdHold), u64(9)) > u64(0)) {
    shellUser(u64(userModeHold)); // never returns
    return;
  }
  if (shellStartsWith(Rodata.addressOf(userCmdUser), u64(4)) > u64(0)) {
    shellUserUsage();
    return;
  }
  // M10. The ELF loader (core/kernel/elf.dart). `run ` is a PREFIX including
  // the space, so a hex LBA follows it; `run` alone is three bytes and matches
  // the exact form below, which prints the usage line -- `run` IS a command, it
  // just needs to be told which sector to load from. There is still no
  // tokenizer (GAP-0057 item 3).
  //
  // The prefix comes FIRST so `run 2A` is not read as an unknown command, and
  // the bare form second so `run` alone lands on the usage line.
  if (shellStartsWith(Rodata.addressOf(elfCmdRunSp), u64(4)) > u64(0)) {
    shellElfRunCmd();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(elfCmdRun), u64(3)) > u64(0)) {
    shellElfUsage();
    return;
  }
  // M14. The filesystem (core/kernel/fat.dart). `cat ` is a PREFIX including
  // its trailing space so a name follows it; `cat` alone is three bytes and
  // matches the exact form after it, which prints the usage line -- `cat` IS a
  // command, it just needs to be told which file. There is still no tokenizer
  // (GAP-0057 item 3), so the name is "the rest of the line".
  //
  // `fs` and `ls` take no argument at all and are matched as whole lines. They
  // are two bytes each, which is shorter than any other command in this shell;
  // that is safe only because [shellIsCmd] compares a LENGTH as well as bytes,
  // so `lsx` does not match `ls`.
  if (shellIsCmd(Rodata.addressOf(fatCmdFs), u64(2)) > u64(0)) {
    shellFatFs();
    return;
  }
  if (shellIsCmd(Rodata.addressOf(fatCmdLs), u64(2)) > u64(0)) {
    shellFatLs();
    return;
  }
  if (shellStartsWith(Rodata.addressOf(fatCmdCatSp), u64(4)) > u64(0)) {
    shellFatCat(u64(4));
    return;
  }
  if (shellIsCmd(Rodata.addressOf(fatCmdCat), u64(3)) > u64(0)) {
    shellFatCatUsage();
    return;
  }
  // M11. Processes (core/kernel/proc.dart). The two PREFIXES come first, each
  // including its trailing space so two hex LBAs follow, and the bare form last
  // so `proc` alone lands on the report rather than on the unknown-command path.
  // `proc cross` is matched before `proc run` for no reason but that neither is
  // a prefix of the other; the order between them is arbitrary and the order
  // relative to the bare form is not.
  //
  // Still no tokenizer (GAP-0057 item 3): `proc` is the first command in this
  // shell to take two arguments, and it finds them by scanning for the space
  // between them.
  if (shellStartsWith(Rodata.addressOf(procCmdCrossSp), u64(11)) > u64(0)) {
    shellProcArgs(u64(11), u64(1), u64(procPolicyPreempt));
    return;
  }
  if (shellStartsWith(Rodata.addressOf(procCmdRunSp), u64(9)) > u64(0)) {
    shellProcArgs(u64(9), u64(0), u64(procPolicyPreempt));
    return;
  }
  // M18's three. `proc sched` is matched as a WHOLE LINE and before the two
  // prefixes, for the same reason the bare `proc` is matched before the
  // unknown-command path: it takes no arguments and a trailing space would
  // otherwise make it a malformed `proc <something>`.
  if (shellIsCmd(Rodata.addressOf(procCmdSched), u64(10)) > u64(0)) {
    shellProcSched();
    return;
  }
  if (shellStartsWith(Rodata.addressOf(procCmdSpinSp), u64(10)) > u64(0)) {
    shellProcSpinArgs(u64(10));
    return;
  }
  // `proc coop` — THE ONLY COOPERATIVE SESSION LEFT, and it exists so that
  // `m11-proc`'s hold boot can still park a non-yielding process at its entry
  // point while the harness walks two live address spaces out of guest RAM.
  // Under `proc run` that process is now preempted after one quantum, which is
  // the milestone working; that boot needs it not to be.
  if (shellStartsWith(Rodata.addressOf(procCmdCoopSp), u64(10)) > u64(0)) {
    shellProcArgs(u64(10), u64(0), u64(procPolicyCoop));
    return;
  }
  if (shellIsCmd(Rodata.addressOf(procCmdProc), u64(4)) > u64(0)) {
    procReport();
    return;
  }
  if (shellStartsWith(Rodata.addressOf(procCmdProc), u64(4)) > u64(0)) {
    shellProcUsage();
    return;
  }
  // M4. `crash ud` and `crash div` are matched as WHOLE LINES, argument
  // included, because there is no tokenizer and nowhere to put the result of
  // splitting one (GAP-0057 item 3). The exact matches come first so `crash`
  // alone, and `crash <anything else>`, fall through to the usage line rather
  // than to the unknown-command path -- `crash` IS a command, it just needs to
  // be told which fault to take.
  if (shellIsCmd(Rodata.addressOf(shellCmdCrashUd), u64(8)) > u64(0)) {
    shellCrashUd(); // never returns; comes back through fault_resume
    return;
  }
  if (shellIsCmd(Rodata.addressOf(shellCmdCrashDiv), u64(9)) > u64(0)) {
    shellCrashDiv(); // never returns; comes back through fault_resume
    return;
  }
  if (shellStartsWith(Rodata.addressOf(shellCmdCrash), u64(5)) > u64(0)) {
    shellCrashUsage();
    return;
  }
  // `echo` alone prints an empty line; `echo <rest>` prints the rest. The
  // space is required, so `echonow` falls through to the unknown-command path
  // rather than being silently treated as `echo now`.
  if (shellStartsWith(Rodata.addressOf(shellCmdEcho), u64(4)) > u64(0)) {
    if (shellLen() == u64(4)) {
      uartNewline();
      return;
    }
    if (shellLineByte(u64(4)) == u8(0x20)) {
      shellEcho(u64(5));
      return;
    }
  }
  // LAST, and only after every real dispatch has declined: a command this shell
  // DOES know, with words after it that are not its. See the block above
  // [shellWriteLineRange].
  if (shellNoArgRefused() > u64(0)) {
    return;
  }
  shellUnknown();
}

// ---------------------------------------------------------------------------
// The main loop. TASK context -- this is the kernel's steady state now.
// ---------------------------------------------------------------------------

/// Re-establishes a usable shell after a fault, on the recovered stack.
/// **Called only from `fault_resume` in `core/boot/isr.S`.**
///
/// By the time this runs, RSP has already been set back to the value
/// `shell_run_forever` recorded, so every frame the faulting command was
/// standing on is gone. Nothing is unwound and nothing is repaired: this
/// function's job is to make the *shell's own* state consistent again, which
/// is three words and a prompt.
///
/// Three things get reset, and each one is a real bug if it is not:
///
///   * `shell_len` — the faulting command was walking the line buffer. Leaving
///     the length as it was would make the next Enter re-run the command that
///     just faulted, on the same bytes, forever.
///   * `shell_state` — it is 2 (a command is running) at the moment of the
///     fault, and `kbdHandle` drops every keystroke unless it is 0. Not
///     clearing it would leave a shell that prints a prompt and then ignores
///     the keyboard, which looks exactly like a hang.
///   * `kbd_prefix` — a fault between an `0xE0` and its follower would
///     otherwise leave the flag set and swallow the next real key.
///
/// The `FAULT RECOVERED` line is printed HERE rather than in the handler, on
/// purpose: it is the first thing printed after the stack switch, so its
/// presence in the capture is evidence that the switch happened and that
/// ordinary DCDart code is running again. A diagnostic printed inside the
/// handler could not say that about itself.
///
/// Interrupts are still disabled on entry (`fault_resume` does `cli`, and the
/// gate had already cleared IF). [shellMain] re-enables them one loop iteration
/// later, in `idle_once`.
@bare
void shellRecover() {
  shellSetLen(u64(0));
  shellSetState(u64(0));
  kbdSetPrefix(u64(0));
  // The 8259 may still hold an in-service bit if the fault was taken inside an
  // IRQ handler, and the handler's own EOI is one of the things being
  // abandoned. Without this, that line would be dead for the rest of the boot
  // -- a shell that comes back with no keyboard is not a recovered shell. It
  // is a NON-SPECIFIC EOI to the master only, so it clears at most one level;
  // the slave is fully masked in this kernel, and nested levels do not arise.
  // Harmless when nothing is in service. docs/known-gaps.md GAP-0062.
  picEoiMaster();
  uartWrite(Rodata.addressOf(shellStrRecovered), u64(16));
  uartPutHex(faultCount(), u64(4));
  uartWrite(Rodata.addressOf(shellStrAbandoned), u64(50));
  shellPrompt();
}

/// Runs the shell forever. **Never returns.**
///
/// Reached from `m2Enter()` through `shell_run_forever` (which records the
/// stack pointer fault recovery resumes on), and again from `fault_resume`
/// after a fault. `m2Enter()` is itself reached from the fault path of
/// `isrDispatch` (ADR-0005 §3 explains why, and none of that changed).
///
/// The `cli` / test / `sti; hlt` shape is load-bearing -- see this file's
/// header. The state word is written only with interrupts disabled on this
/// side, and only from the IRQ1 handler on the other, so the two never
/// interleave.
@bare
void shellMain() {
  while (u64(1) > u64(0)) {
    interrupts_disable();
    if (shellState() == u64(1)) {
      // Claim the line: state 2 makes kbdHandle drop keys, so the buffer
      // cannot change underneath shellExecute.
      shellSetState(u64(2));
      interrupts_enable();
      shellExecute();
      shellSetLen(u64(0));
      shellPrompt();
      interrupts_disable();
      shellSetState(u64(0));
      interrupts_enable();
    } else {
      idle_once(); // sti; hlt -- adjacent, so the wake-up cannot be missed
    }
  }
}
