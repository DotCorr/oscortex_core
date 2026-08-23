// core/kernel/user.dart
//
// oscortex_core M9: RING 3, AND A WAY BACK. The first code this kernel has ever
// run that is not allowed to do everything -- a hand-written machine-code
// payload executing at CPL 3, on two pages the page tables let CPL 3 touch, able
// to reach the kernel only through one IDT gate.
//
// The architecture is docs/decisions/0013-ring-3-and-the-syscall-boundary.md;
// the binary exit criterion is ROADMAP.md's M9 and
// tests/conformance/m9-ring3/run.sh.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS NARROWS: GAP-0081 ITEM 1
// ---------------------------------------------------------------------------
// Until this milestone every page in this kernel was mapped supervisor-only
// (U/S = 0), there was no TSS, there were no ring-3 segment descriptors and
// there was no syscall path. The consequence was not that the kernel was
// insecure -- it was that the word "privilege" did not describe anything about
// it. The `USER`/`SUPER` field in the page-fault report had only ever printed
// `SUPER`, and the U bit of a page-fault error code had never been observed set
// on this machine, ever.
//
// **The proof of a boundary is a refusal, not a report.** So this file's shell
// command has seven sub-commands and four of them are designed to fail:
//
//   `user`         a payload that behaves: it asks the kernel who it is, asks
//                  the kernel to print something, and exits.
//   `user gp`      a payload that executes `mov %cr3,%rax`. #GP, vector 13.
//   `user pf`      a payload that stores one byte into KERNEL memory. #PF with
//                  the USER bit set in the error code -- the bit that had never
//                  been seen -- and the target word is checked afterwards and
//                  must be unchanged.
//   `user badint`  a payload that executes `int $3`, whose gate is DPL 0. #GP
//                  with error code 0x1A, which decodes as "IDT entry 3".
//   `user badptr`  a payload that hands the `write` syscall a KERNEL pointer.
//                  The kernel refuses it and hands back -1, and the payload
//                  reports what it got -- so the refusal is observed from ring
//                  3 rather than only from the kernel's side of the boundary.
//   `user hold`    a payload that reports its CS and then spins in ring 3
//                  FOREVER, so a harness can stop the machine mid-payload and
//                  read the U/S bits out of the live tables while they are set.
//                  It never exits and nothing here can stop it (GAP-0085), so
//                  it is the last command any session can run.
//   `user pages`   no ring 3 at all: the TSS, the task register, the two gate
//                  DPLs, and how many pages ring 3 can currently reach.
//
// The first one is the control. Without a payload that runs to completion,
// "ring 3 faulted" would be equally consistent with "nothing can execute in
// ring 3 at all", which would say nothing about privilege.
//
// ---------------------------------------------------------------------------
// THE PAYLOAD IS A @rodata BYTE TABLE, AND THAT IS THE SCOPE DECISION
// ---------------------------------------------------------------------------
// There is no ELF loader here, no linker, no relocation, no `fork` and no
// `exec`. A payload is a run of machine-code bytes in this kernel's own
// `.rodata`, copied into a frame from the M7 allocator and jumped to. Every one
// of them is under sixty bytes and every byte is accounted for in the comment
// above its table.
//
// That is deliberate and it is the honest boundary of this milestone: what is
// being proved is that the CPU enforces a privilege level and that the kernel
// can be re-entered from one, NOT that this kernel can load a program. Building
// a loader to prove a privilege boundary would have made the loader the thing
// under test.
//
// ---------------------------------------------------------------------------
// THE STORAGE SEAM -- ONE ACCESSOR, ONE CALL SITE
// ---------------------------------------------------------------------------
// DCDart still has no mutable static data of any kind (docs/known-gaps.md
// GAP-0053), so this subsystem's state is assembly-donated `.bss` exactly as the
// allocator's and the address space's are: 128 bytes in ONE symbol
// (`user_store`, core/boot/kdata.S) behind ONE accessor (`user_store_addr`)
// reached through exactly ONE function ([userMetaBase]). ADR-0011 §0 is the
// pattern and ADR-0012 §3 is the precedent; `tests/conformance/m9-ring3/run.sh`
// counts the call site the same way m8-paging counts vm.dart's.
//
// The two words `enter_user` and `user_return` need are NOT in that block and
// are not behind that seam. They hold a stack pointer, DCDart cannot read or
// write a stack pointer, and they will still be assembly-owned on the day
// DCDart grows mutable statics -- exactly like M4's `shell_resume_rsp`.
//
// ---------------------------------------------------------------------------
// WHAT IS STILL NOT HERE -- docs/known-gaps.md GAP-0085
// ---------------------------------------------------------------------------
// One address space, still the kernel's: the payload runs on the kernel's own
// PML4 with two pages temporarily marked user-accessible, not in an address
// space of its own. No scheduler, no processes, no preemption, no `fork`, no
// `exec`, no ELF, no file descriptors, no memory the payload can ask for. The
// payload is not a process; it is a privilege level with two pages.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// GENERATED, not hand-typed: a `@rodata` table carries no length (GAP-0060), so
// every byte count below is repeated at its call site by hand, and getting one
// wrong prints the wrong number of bytes. `tests/conformance/m9-ring3/run.sh`
// reads every symbol's real size out of `kmain.o` and compares it against what
// the call site passes.
// ---------------------------------------------------------------------------

/// Line label.
///
/// `'USER TSS '` -- 9 bytes.
@rodata
final List<u8> userStrTss = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x54), u8(0x53), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' RSP0 '` -- 6 bytes.
@rodata
final List<u8> userStrRsp0 = const [
  u8(0x20), u8(0x52), u8(0x53), u8(0x50), u8(0x30), u8(0x20),
];

/// Field separator.
///
/// `' GDT '` -- 5 bytes.
@rodata
final List<u8> userStrGdt = const [
  u8(0x20), u8(0x47), u8(0x44), u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'USER MAP CODE '` -- 14 bytes.
@rodata
final List<u8> userStrMap = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x4D), u8(0x41), u8(0x50), u8(0x20), u8(0x43), u8(0x4F), u8(0x44),
  u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' STACK '` -- 7 bytes.
@rodata
final List<u8> userStrStack = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x43), u8(0x4B), u8(0x20),
];

/// Line label.
///
/// `'USER PAGE CODE '` -- 15 bytes.
@rodata
final List<u8> userStrPageCode = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x20), u8(0x43), u8(0x4F),
  u8(0x44), u8(0x45), u8(0x20),
];

/// Line label.
///
/// `'USER PAGE STACK '` -- 16 bytes.
@rodata
final List<u8> userStrPageStack = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x20), u8(0x53), u8(0x54),
  u8(0x41), u8(0x43), u8(0x4B), u8(0x20),
];

/// Field separator: the U/S bit.
///
/// `' U '` -- 3 bytes.
@rodata
final List<u8> userStrU = const [
  u8(0x20), u8(0x55), u8(0x20),
];

/// Line label.
///
/// `'USER WINDOW PAGES '` -- 18 bytes.
@rodata
final List<u8> userStrWindow = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x57), u8(0x49), u8(0x4E), u8(0x44), u8(0x4F), u8(0x57), u8(0x20),
  u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' USER '` -- 6 bytes.
@rodata
final List<u8> userStrUserFld = const [
  u8(0x20), u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20),
];

/// Line label.
///
/// `'USER ENTER RIP '` -- 15 bytes.
@rodata
final List<u8> userStrEnter = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x45), u8(0x4E), u8(0x54), u8(0x45), u8(0x52), u8(0x20), u8(0x52),
  u8(0x49), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' RSP '` -- 5 bytes.
@rodata
final List<u8> userStrRsp = const [
  u8(0x20), u8(0x52), u8(0x53), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' ARG '` -- 5 bytes.
@rodata
final List<u8> userStrArg = const [
  u8(0x20), u8(0x41), u8(0x52), u8(0x47), u8(0x20),
];

/// Line label.
///
/// `'USER CS '` -- 8 bytes.
@rodata
final List<u8> userStrCs = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x43), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' SS '` -- 4 bytes.
@rodata
final List<u8> userStrSs = const [
  u8(0x20), u8(0x53), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' RFLAGS '` -- 8 bytes.
@rodata
final List<u8> userStrRflags = const [
  u8(0x20), u8(0x52), u8(0x46), u8(0x4C), u8(0x41), u8(0x47), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' CPL '` -- 5 bytes.
@rodata
final List<u8> userStrCpl = const [
  u8(0x20), u8(0x43), u8(0x50), u8(0x4C), u8(0x20),
];

/// Line label: the payload's own bytes follow.
///
/// `'USER WRITE '` -- 11 bytes.
@rodata
final List<u8> userStrWrite = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x57), u8(0x52), u8(0x49), u8(0x54), u8(0x45), u8(0x20),
];

/// Line label.
///
/// `'USER EXIT CODE '` -- 15 bytes.
@rodata
final List<u8> userStrExit = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x45), u8(0x58), u8(0x49), u8(0x54), u8(0x20), u8(0x43), u8(0x4F),
  u8(0x44), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' SYSCALLS '` -- 10 bytes.
@rodata
final List<u8> userStrSyscalls = const [
  u8(0x20), u8(0x53), u8(0x59), u8(0x53), u8(0x43), u8(0x41), u8(0x4C), u8(0x4C), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' REFUSALS '` -- 10 bytes.
@rodata
final List<u8> userStrRefusals = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x41), u8(0x4C), u8(0x53), u8(0x20),
];

/// Line label.
///
/// `'USER DONE ENTRIES '` -- 18 bytes.
@rodata
final List<u8> userStrDone = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x44), u8(0x4F), u8(0x4E), u8(0x45), u8(0x20), u8(0x45), u8(0x4E),
  u8(0x54), u8(0x52), u8(0x49), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' ABORTS '` -- 8 bytes.
@rodata
final List<u8> userStrAborts = const [
  u8(0x20), u8(0x41), u8(0x42), u8(0x4F), u8(0x52), u8(0x54), u8(0x53), u8(0x20),
];

/// Line label.
///
/// `'USER FAULT VEC '` -- 15 bytes.
@rodata
final List<u8> userStrFault = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x46), u8(0x41), u8(0x55), u8(0x4C), u8(0x54), u8(0x20), u8(0x56),
  u8(0x45), u8(0x43), u8(0x20),
];

/// Field separator.
///
/// `' RIP '` -- 5 bytes.
@rodata
final List<u8> userStrRip = const [
  u8(0x20), u8(0x52), u8(0x49), u8(0x50), u8(0x20),
];

/// Line label.
///
/// `'USER ABORT FREED '` -- 17 bytes.
@rodata
final List<u8> userStrAbort = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x41), u8(0x42), u8(0x4F), u8(0x52), u8(0x54), u8(0x20), u8(0x46),
  u8(0x52), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// Line label.
///
/// `'USER CANARY '` -- 12 bytes.
@rodata
final List<u8> userStrCanary = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x43), u8(0x41), u8(0x4E), u8(0x41), u8(0x52), u8(0x59), u8(0x20),
];

/// Line label.
///
/// `'USER REFUSE NO '` -- 15 bytes.
@rodata
final List<u8> userStrRefuse = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x45), u8(0x20),
  u8(0x4E), u8(0x4F), u8(0x20),
];

/// Field separator.
///
/// `' PTR '` -- 5 bytes.
@rodata
final List<u8> userStrPtr = const [
  u8(0x20), u8(0x50), u8(0x54), u8(0x52), u8(0x20),
];

/// Field separator.
///
/// `' LEN '` -- 5 bytes.
@rodata
final List<u8> userStrLen = const [
  u8(0x20), u8(0x4C), u8(0x45), u8(0x4E), u8(0x20),
];

/// Complete line.
///
/// `'user: usage: user | user gp | user pf | user badint | user badptr | user hold | user pages\n'` -- 91 bytes.
@rodata
final List<u8> userStrUsage = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A),
  u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x7C), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72),
  u8(0x20), u8(0x67), u8(0x70), u8(0x20), u8(0x7C), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x70),
  u8(0x66), u8(0x20), u8(0x7C), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x62), u8(0x61), u8(0x64),
  u8(0x69), u8(0x6E), u8(0x74), u8(0x20), u8(0x7C), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x62),
  u8(0x61), u8(0x64), u8(0x70), u8(0x74), u8(0x72), u8(0x20), u8(0x7C), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72),
  u8(0x20), u8(0x68), u8(0x6F), u8(0x6C), u8(0x64), u8(0x20), u8(0x7C), u8(0x20), u8(0x75), u8(0x73), u8(0x65), u8(0x72),
  u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x73), u8(0x0A),
];

/// Complete line.
///
/// `'user: no free frame for the payload\\n'` -- 36 bytes.
@rodata
final List<u8> userStrNoFrames = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x3A), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x66), u8(0x72), u8(0x65),
  u8(0x65), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x20), u8(0x66), u8(0x6F), u8(0x72), u8(0x20),
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x61), u8(0x79), u8(0x6C), u8(0x6F), u8(0x61), u8(0x64), u8(0x0A),
];

/// Line label.
///
/// `'user: could not map the payload pages, vm status '` -- 49 bytes.
@rodata
final List<u8> userStrNoMap = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x3A), u8(0x20), u8(0x63), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20),
  u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x6D), u8(0x61), u8(0x70), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20),
  u8(0x70), u8(0x61), u8(0x79), u8(0x6C), u8(0x6F), u8(0x61), u8(0x64), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65),
  u8(0x73), u8(0x2C), u8(0x20), u8(0x76), u8(0x6D), u8(0x20), u8(0x73), u8(0x74), u8(0x61), u8(0x74), u8(0x75), u8(0x73),
  u8(0x20),
];

/// Complete line.
///
/// `'user: the address space is not installed, vm READY 0\\n'` -- 53 bytes.
@rodata
final List<u8> userStrNotReady = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x3A), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x61), u8(0x64),
  u8(0x64), u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x20), u8(0x73), u8(0x70), u8(0x61), u8(0x63), u8(0x65), u8(0x20),
  u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x69), u8(0x6E), u8(0x73), u8(0x74), u8(0x61),
  u8(0x6C), u8(0x6C), u8(0x65), u8(0x64), u8(0x2C), u8(0x20), u8(0x76), u8(0x6D), u8(0x20), u8(0x52), u8(0x45), u8(0x41),
  u8(0x44), u8(0x59), u8(0x20), u8(0x30), u8(0x0A),
];

/// Whole-line command name.
///
/// `'user'` -- 4 bytes.
@rodata
final List<u8> userCmdUser = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72),
];

/// Whole-line command name.
///
/// `'user gp'` -- 7 bytes.
@rodata
final List<u8> userCmdGp = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x67), u8(0x70),
];

/// Whole-line command name.
///
/// `'user pf'` -- 7 bytes.
@rodata
final List<u8> userCmdPf = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x70), u8(0x66),
];

/// Whole-line command name.
///
/// `'user badint'` -- 11 bytes.
@rodata
final List<u8> userCmdBadint = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x62), u8(0x61), u8(0x64), u8(0x69), u8(0x6E), u8(0x74),
];

/// Whole-line command name.
///
/// `'user badptr'` -- 11 bytes.
@rodata
final List<u8> userCmdBadptr = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x62), u8(0x61), u8(0x64), u8(0x70), u8(0x74), u8(0x72),
];

/// Whole-line command name.
///
/// `'user hold'` -- 9 bytes.
@rodata
final List<u8> userCmdHold = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x68), u8(0x6F), u8(0x6C), u8(0x64),
];

/// Whole-line command name.
///
/// `'user pages'` -- 10 bytes.
@rodata
final List<u8> userCmdPages = const [
  u8(0x75), u8(0x73), u8(0x65), u8(0x72), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x73),
];
/// **THE PAYLOAD THAT BEHAVES.** 38 bytes of x86-64 machine code, plus the
/// seventeen bytes of text it asks the kernel to print.
///
/// Hand-assembled and disassembled back (`objdump -D -b binary -m i386:x86-64`)
/// rather than trusted; `tests/conformance/m9-ring3/run.sh` disassembles this
/// table out of `kmain.o` and asserts the mnemonics, so the bytes below cannot
/// drift into something that merely still runs.
///
/// ```
///   0:  6a 11                 push $17              ; onto the USER stack
///   2:  b8 02 00 00 00        mov  $2,%eax          ; whoami
///   7:  cd 80                 int  $0x80
///   9:  48 8d 3d 16 00 00 00  lea  0x16(%rip),%rdi  ; -> offset 38, the text
///  10:  5e                    pop  %rsi             ; off the USER stack again
///  11:  b8 01 00 00 00        mov  $1,%eax          ; write
///  16:  cd 80                 int  $0x80
///  18:  bf 00 00 00 00        mov  $0,%edi
///  1d:  b8 00 00 00 00        mov  $0,%eax          ; exit(0)
///  22:  cd 80                 int  $0x80
///  24:  eb fe                 jmp  .                ; not reached
///  26:  "HELLO FROM RING 3"
/// ```
///
/// **The push and the pop are the stack page's behavioural test, and they
/// straddle a syscall on purpose.** Without them the payload never touches its
/// own stack at all -- an `int 0x80` from ring 3 switches to RSP0 and pushes
/// there, so the user stack would be mapped, reported, and never used, and
/// `USER PAGE STACK ... U 1 W 1` would be a claim nothing tested. With them, a
/// stack page that were not user-accessible faults on the very first
/// instruction, one that were not writable faults on the push, and one whose
/// contents did not survive the `whoami` syscall in between produces the wrong
/// `write` length. The value pushed is the message length, so getting it back
/// wrong is visible in the output rather than only in a counter.
///
/// **The `jmp .` is not dead code and must stay.** `exit` does not return, but
/// on a kernel where it did -- or where the gate were wrong and the `int`
/// silently did nothing -- the next bytes executed would be the message text,
/// which disassembles to REX prefixes and a store through `%r14`. A payload
/// that wanders into its own data on a machine whose privilege boundary has
/// just been shown not to work is the least useful possible failure. This spins
/// instead, and the harness's `wait:` expires with the payload visibly stuck,
/// which is a diagnosis.
///
/// **The text is addressed RIP-relatively** because the payload does not know
/// where it will be loaded: it is copied into whatever frame `allocFrame()`
/// hands out, which moves with the kernel's own size. There is no relocation
/// step here and there is deliberately no loader to perform one (see this
/// file's header), so position-independence is the payload's job.
///
/// 55 bytes.
@rodata
final List<u8> userCodeRun = const [
  u8(0x6A), u8(0x11), u8(0xB8), u8(0x02), u8(0x00), u8(0x00), u8(0x00), u8(0xCD), u8(0x80), u8(0x48), u8(0x8D), u8(0x3D),
  u8(0x16), u8(0x00), u8(0x00), u8(0x00), u8(0x5E), u8(0xB8), u8(0x01), u8(0x00), u8(0x00), u8(0x00), u8(0xCD), u8(0x80),
  u8(0xBF), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0xB8), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0xCD), u8(0x80),
  u8(0xEB), u8(0xFE), u8(0x48), u8(0x45), u8(0x4C), u8(0x4C), u8(0x4F), u8(0x20), u8(0x46), u8(0x52), u8(0x4F), u8(0x4D),
  u8(0x20), u8(0x52), u8(0x49), u8(0x4E), u8(0x47), u8(0x20), u8(0x33),
];

/// **THE PAYLOAD THAT DOES NOT STOP.** 9 bytes.
///
/// ```
///   0:  b8 02 00 00 00        mov  $2,%eax          ; whoami
///   5:  cd 80                 int  $0x80
///   7:  eb fe                 jmp  .                ; forever
/// ```
///
/// **It exists so that the page tables can be read out of guest memory WHILE
/// RING 3 IS RUNNING.** Every other sub-command has torn its pages down by the
/// time the shell prompt comes back, so a dump taken afterwards can only ever
/// show U/S clear -- which proves the teardown and says nothing about the
/// window in between. This one reports its CS and then spins, so a harness can
/// stop the machine mid-payload, dump the tables at QEMU's own CR3, and assert
/// that exactly two of the 1024 pages in the 4KiB window are user-accessible
/// and that they are the two this command mapped. It is also the boot in which
/// QEMU's own `info registers` shows `CS =0023` and CPL 3, which is a third
/// party's account of the privilege level.
///
/// **The spin is not idle.** RFLAGS has IF set, so the timer and the keyboard
/// keep interrupting it, each one switching to the ring-0 stack the TSS names
/// and `iretq`ing back to CPL 3. A machine that survives thousands of those is
/// making a stronger statement about RSP0 than any single syscall does.
///
/// It never exits, and nothing can make it: this kernel has no scheduler, no
/// preemption and no way to kill a running payload (docs/known-gaps.md
/// GAP-0085). `user hold` is therefore the LAST thing any session can run, and
/// the harness ends that boot by killing QEMU. Saying so here is cheaper than
/// letting someone find out.
///
/// 9 bytes.
@rodata
final List<u8> userCodeHold = const [
  u8(0xB8), u8(0x02), u8(0x00), u8(0x00), u8(0x00), u8(0xCD), u8(0x80), u8(0xEB), u8(0xFE),
];

/// **A PRIVILEGED INSTRUCTION IN RING 3.** 15 bytes.
///
/// ```
///   0:  0f 20 d8              mov  %cr3,%rax        ; #GP(0) at CPL 3
///   3:  48 89 c7              mov  %rax,%rdi
///   6:  b8 00 00 00 00        mov  $0,%eax
///   b:  cd 80                 int  $0x80            ; exit(cr3) -- NOT REACHED
///   d:  eb fe                 jmp  .
/// ```
///
/// **`mov %cr3` rather than `cli` or `hlt`, and the difference matters.** `cli`
/// and `hlt` are privileged *relative to IOPL*: `cli` from CPL 3 is a #GP only
/// because `enter_user` pushes RFLAGS with IOPL = 0, so a test built on it would
/// be measuring this kernel's choice of RFLAGS as much as the CPU's privilege
/// check. Reading CR3 is unconditionally privileged at any CPL above 0. If this
/// faults, it faults because the code is not in ring 0, and for no other reason.
///
/// The exit call is unreachable on a working kernel and is there so that a
/// BROKEN one says so: a payload that really did read CR3 from ring 3 exits with
/// the value it read, and `USER EXIT CODE` prints the kernel's own PML4 address
/// -- which is both an unmistakable failure and the most useful possible
/// evidence about what went wrong.
///
/// 15 bytes.
@rodata
final List<u8> userCodeGp = const [
  u8(0x0F), u8(0x20), u8(0xD8), u8(0x48), u8(0x89), u8(0xC7), u8(0xB8), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0xCD),
  u8(0x80), u8(0xEB), u8(0xFE),
];

/// **A STORE FROM RING 3 INTO KERNEL MEMORY.** 17 bytes.
///
/// ```
///   0:  c6 07 5a              movb $0x5A,(%rdi)     ; #PF, USER bit set
///   3:  bf ad 0b 00 00        mov  $0xBAD,%edi
///   8:  b8 00 00 00 00        mov  $0,%eax
///   d:  cd 80                 int  $0x80            ; exit(0xBAD) -- NOT REACHED
///   f:  eb fe                 jmp  .
/// ```
///
/// RDI holds the target, and it is the ONE value `enter_user` hands the payload
/// -- see [userArgFor]. It points at [userMetaCanary], a `u64` in the donated
/// `.bss` block, i.e. a supervisor page in `.data`/`.bss` that the kernel itself
/// writes on every boot. So the fault must be a PROTECTION violation and not a
/// missing page: error code 7 -- present, write, **user** -- and the U bit in
/// that error code is the thing this whole milestone exists to make observable.
///
/// **A byte store, not a `u64` one**, for the reason `vmtest ro` uses a byte
/// store: it is the smallest access that can prove the page is writable, and the
/// canary word is checked afterwards against the exact value the kernel put
/// there, so "the store did not land" is a comparison rather than the absence of
/// a fault.
///
/// `0xBAD` is the exit code a working kernel never prints.
///
/// 17 bytes.
@rodata
final List<u8> userCodePf = const [
  u8(0xC6), u8(0x07), u8(0x5A), u8(0xBF), u8(0xAD), u8(0x0B), u8(0x00), u8(0x00), u8(0xB8), u8(0x00), u8(0x00), u8(0x00),
  u8(0x00), u8(0xCD), u8(0x80), u8(0xEB), u8(0xFE),
];

/// **A SOFTWARE INTERRUPT THROUGH A DPL-0 GATE.** 16 bytes.
///
/// ```
///   0:  cd 03                 int  $3               ; gate 3 is DPL 0 -> #GP
///   2:  bf ad 0b 00 00        mov  $0xBAD,%edi
///   7:  b8 00 00 00 00        mov  $0,%eax
///   c:  cd 80                 int  $0x80            ; exit(0xBAD) -- NOT REACHED
///   e:  eb fe                 jmp  .
/// ```
///
/// **This is the control for the syscall gate itself.** `int $0x80` works from
/// ring 3 because [idtSetUserGate] gave that one gate DPL 3. Every other gate in
/// this kernel's IDT still has DPL 0, and the CPU checks CPL <= gate DPL for a
/// software interrupt -- so `int $3` from ring 3 is a #GP whose error code names
/// the gate that refused: `(3 << 3) | 2` = 0x1A, where bit 1 says "the selector
/// index is an IDT entry". Without this, "int 0x80 reached the kernel" would be
/// equally consistent with "the DPL field does nothing on this CPU".
///
/// The two-byte `cd 03` encoding is used rather than the one-byte `cc`
/// deliberately: `cc` is the dedicated INT3 breakpoint opcode and is documented
/// as taking a different path, and what is under test here is the DPL check on
/// an ordinary `INT n`.
///
/// 16 bytes.
@rodata
final List<u8> userCodeBadint = const [
  u8(0xCD), u8(0x03), u8(0xBF), u8(0xAD), u8(0x0B), u8(0x00), u8(0x00), u8(0xB8), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
  u8(0xCD), u8(0x80), u8(0xEB), u8(0xFE),
];

/// **A SYSCALL WITH A KERNEL POINTER.** 24 bytes.
///
/// ```
///   0:  be 08 00 00 00        mov  $8,%esi          ; len
///   5:  b8 01 00 00 00        mov  $1,%eax          ; write
///   a:  cd 80                 int  $0x80            ; -> refused, RAX = -1
///   c:  48 89 c7              mov  %rax,%rdi
///   f:  b8 00 00 00 00        mov  $0,%eax
///  14:  cd 80                 int  $0x80            ; exit(what write returned)
///  16:  eb fe                 jmp  .
/// ```
///
/// RDI arrives holding a kernel address (the same word `user pf` aims at), so
/// this asks the kernel to print eight bytes of its own `.bss` -- the classic
/// confused-deputy shape, and the reason a syscall that takes a pointer has to
/// validate it rather than dereference it. [userSysWrite] checks the range and
/// refuses.
///
/// **This is the only sub-command in which the payload SURVIVES its own
/// misbehaviour**, and that is the point: it exits normally with the status the
/// kernel handed back, so `USER EXIT CODE FFFFFFFFFFFFFFFF` is the refusal
/// observed from ring 3. Every other refusal in this file is observed from the
/// kernel's side, where it is much easier to be wrong about what the other side
/// saw.
///
/// 24 bytes.
@rodata
final List<u8> userCodeBadptr = const [
  u8(0xBE), u8(0x08), u8(0x00), u8(0x00), u8(0x00), u8(0xB8), u8(0x01), u8(0x00), u8(0x00), u8(0x00), u8(0xCD), u8(0x80),
  u8(0x48), u8(0x89), u8(0xC7), u8(0xB8), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0xCD), u8(0x80), u8(0xEB), u8(0xFE),
];


// ---------------------------------------------------------------------------
// Constants. Every one that describes the CPU is stated once, here, and the
// conformance harness asserts each of them against `core/boot/boot.S`'s own
// `.set` directives -- a second copy of a selector is the kind of thing that
// stays right until the day the GDT is rearranged.
// ---------------------------------------------------------------------------

/// Ring-3 code selector: GDT entry 4 (`gdt64_user_code`, byte offset 0x20) with
/// RPL 3 in the low two bits.
///
/// **The RPL is not decoration.** `iretq` requires the CS it pops to have
/// RPL > CPL for a privilege change, and a bare `0x20` here is a #GP with an
/// error code naming the selector -- a fault whose cause is invisible in hex
/// unless the |3 is written down somewhere.
const int userCodeSel = 0x23;

/// Ring-3 data selector: GDT entry 3 (`gdt64_user_data`, 0x18) with RPL 3.
/// Loaded into SS by `iretq` and into DS/ES/FS/GS by `enter_user`.
const int userDataSel = 0x1B;

/// The TSS descriptor's selector: GDT entry 5 (`gdt64_tss`, 0x28). Sixteen
/// bytes wide, so it also consumes entry 6.
///
/// Named here for the report and for the harness; the `ltr` that loads it is in
/// `core/boot/boot.S`, because `ltr` WRITES the busy bit into the descriptor and
/// the GDT is on a read-only page from the moment `vmInit` runs. That was
/// measured, not looked up -- see boot.S's own note beside the instruction.
const int userTssSel = 0x28;

/// Offset of RSP0 inside the 64-bit TSS. The only field of it this kernel uses,
/// and the field whose absence is a triple fault -- see `core/boot/boot.S`.
const int userTssRsp0 = 4;

/// The vector `int 0x80` raises, and the one gate in this kernel's IDT with
/// DPL 3.
const int vectorSyscall = 0x80;

/// The vector the CPU raises for a general-protection fault.
const int vectorGeneralProtection = 13;

/// Interrupt-gate attribute byte with **DPL 3**: present (0x80), DPL 3 (0x60),
/// 64-bit interrupt gate (0x0E). The 0x60 is the whole of M9's syscall entry
/// permission -- with the 0x8E every other gate uses, `int 0x80` from ring 3 is
/// a #GP instead of a syscall, which `user badint` demonstrates on gate 3.
const int userGateAttr = 0xEE;

// Syscall numbers. Deliberately tiny and deliberately in this order: `exit` is
// 0 so that a payload whose RAX was never set asks for the one syscall that
// cannot corrupt anything.
const int userSysExitNo = 0;
const int userSysWriteNo = 1;
const int userSysWhoNo = 2;

/// The largest `write` this kernel will perform for ring 3. A length bound is
/// half of a pointer check: without it, a valid pointer with a length of 2^40
/// walks off the payload's page and prints the kernel.
const int userWriteMax = 128;

/// What a refused syscall returns in RAX. `u64` all-ones rather than a signed
/// -1 because `@bare` DCDart has no signed type; the payload compares it as an
/// opaque bit pattern and the report prints it as one.
const int userRefused = 0xFFFFFFFFFFFFFFFF;

// The payload modes, one per sub-command.
const int userModeRun = 0;
const int userModeGp = 1;
const int userModePf = 2;
const int userModeBadint = 3;
const int userModeBadptr = 4;
const int userModeHold = 5;

/// The value written into [userMetaCanary] before every entry into ring 3, and
/// required to still be there afterwards.
///
/// Not zero and not a round number: a byte-store of 0x5A landing anywhere in it
/// changes it, and a word that is accidentally cleared or accidentally left
/// uninitialised does not read back as this.
const int userCanaryValue = 0x4B45524E454C2121;

// Donated storage: sixteen `u64` words. See `core/boot/kdata.S`.
const int userStoreBytes = 128;
const int userStoreWords = 16;

// Metadata word indices. The layout is documented once, in kdata.S.
const int userMetaLive = 0;
const int userMetaMode = 1;
const int userMetaCodeFrame = 2;
const int userMetaStackFrame = 3;
const int userMetaEntries = 4;
const int userMetaSyscalls = 5;
const int userMetaCs = 6;
const int userMetaSs = 7;
const int userMetaFlags = 8;
const int userMetaExit = 9;
const int userMetaRefusals = 10;
const int userMetaWritten = 11;
const int userMetaAborts = 12;
const int userMetaCanary = 13;
const int userMetaRip = 14;
const int userMetaErr = 15;

// Byte offsets into the saved-register frame `isr_common` hands `isrDispatch`.
//
// The frame is fifteen pushes followed by the two the stub made and the five the
// CPU pushed, so these are the offsets from the address in `frame`. They are
// spelled out rather than computed for GAP-0077's reason, and
// `tests/conformance/m9-ring3/run.sh` checks them against the push order in
// `core/boot/isr.S` so the two cannot drift.
//
// **[userFrameCs] is the load-bearing one.** Its low two bits are the CPL the
// interrupted code was running at, written by the CPU itself at the moment of
// the trap. It is the only trustworthy answer to "was that really ring 3" --
// asking the payload to report its own privilege level would be asking the thing
// under test.
const int userFrameRdi = 72;
const int userFrameRsi = 80;
const int userFrameRdx = 88;
const int userFrameRax = 112;
const int userFrameRip = 136;
const int userFrameCs = 144;
const int userFrameFlags = 152;
const int userFrameRsp = 160;
const int userFrameSs = 168;

// ---------------------------------------------------------------------------
// ===========================  THE STORAGE SEAM  ============================
//
// The ONLY function in this kernel that knows where the ring-3 subsystem's
// mutable state lives, and the ONLY call site of `user_store_addr`.
//
// Read this file's header before changing anything here. A second call site, or
// a second `@extern` accessor for ring-3 state, is the change that turns the
// mutable-statics migration from one function into an audit.
// `tests/conformance/m9-ring3/run.sh` counts it.
// ---------------------------------------------------------------------------

/// The 128 bytes this subsystem owns, as a DCDart mutable static.
///
/// Until M17 (ADR-0021) this was `user_store` in core/boot/kdata.S, reached through
/// `@extern u64 user_store_addr()`. DCDart grew `@bss` (its ADR-0051), so the storage is
/// declared here, in the file that owns it, and the assembly and its accessor
/// are gone. The seam function below  is unchanged in name, arity and meaning;
/// only the expression it returns moved. That is the whole of ADR-0011 section
/// 0's claim, tested.
@bss
final Bss userStore = const Bss(bytes: userStoreBytes);

/// Base of the sixteen-word metadata block.
@bare
u64 userMetaBase() {
  return Bss.addressOf(userStore);
}

// ======================  END OF THE STORAGE SEAM  ==========================

/// Address of the assembly-owned "the resume point is real" guard.
///
/// NOT behind the seam and never will be: the word it guards holds a stack
/// pointer, which DCDart cannot read or write at all, so it stays in assembly on
/// the day DCDart grows mutable statics. Exactly the reason
/// `shell_resume_ok_addr` exists beside `shell_resume_rsp` (M4, ADR-0007).
///
/// **That day was M17 and this prediction held.** `userStore` migrated to a
/// DCDart `@bss` block; these two words did not, and could not: `enter_user`
/// and `user_return` in `core/boot/isr.S` write them by name, and a `@bss`
/// symbol is LOCAL to `kmain.o`. ADR-0021 section 4, GAP-0134.
@extern
external u64 user_resume_ok_addr();

/// The address of the 104-byte TSS, from `core/boot/boot.S`.
@extern
external u64 tss_base();

/// The address of the GDT, from `core/boot/boot.S`.
@extern
external u64 gdt_base();

/// `iretq` into ring 3. **Returns only through `user_return`**, i.e. only if the
/// payload calls the `exit` syscall; a payload that faults never comes back here
/// at all, because the fault path abandons this stack (M4, ADR-0007).
@extern
external void enter_user(u64 rip, u64 rsp, u64 arg, u64 cs, u64 ss);

/// Abandons the interrupt stack and returns into [shellUser], immediately after
/// its call to [enter_user]. **Never returns to its caller.**
@extern
external void user_return();

// ---------------------------------------------------------------------------
// Metadata primitives. Everything below goes through the seam.
// ---------------------------------------------------------------------------

/// Reads metadata word [i].
@bare
u64 userMeta(u64 i) {
  return Pointer<u64>.fromAddress(userMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void userSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(userMetaBase() + (i << u64(3))).value = v;
}

/// Adds one to metadata word [i].
@bare
void userBump(u64 i) {
  userSetMeta(i, userMeta(i) + u64(1));
}

/// Reads word [off] of the saved-register frame `isr_common` built.
@bare
u64 userFrame(u64 frame, u64 off) {
  return Pointer<u64>.fromAddress(frame + off).value;
}

/// Writes word [off] of that frame. Used for exactly one thing: the syscall
/// return value, which has to be in the RAX slot so `isr_common`'s `popq %rax`
/// hands it back to ring 3.
@bare
void userSetFrame(u64 frame, u64 off, u64 v) {
  Pointer<u64>.fromAddress(frame + off).value = v;
}

/// Gives every word of the donated block a known value, and clears the
/// assembly-owned resume guard.
///
/// Called from `kmain()` immediately after [vmInit], for the same reason
/// `shellInit` and `fbInit` are called where they are: `.bss` is not zeroed by
/// anything in this kernel, and [userOnFault] reads the live flag on EVERY fault
/// the kernel takes. A garbage flag would make the first fault of the boot try
/// to tear down a payload that does not exist -- unmapping and freeing two
/// frames chosen from `.bss` litter, while diagnosing something else.
///
/// Prints NOTHING, and must keep printing nothing:
/// `tests/conformance/m1-interrupts/run.sh` asserts the entire 544-byte serial
/// capture.
@bare
void userInit() {
  u64 i = u64(0);
  while (i < u64(userStoreWords)) {
    userSetMeta(i, u64(0));
    i = i + u64(1);
  }
  Pointer<u64>.fromAddress(user_resume_ok_addr()).value = u64(0);
}

// ---------------------------------------------------------------------------
// The syscall gate.
// ---------------------------------------------------------------------------

/// Rewrites IDT gate 0x80 with **DPL 3**.
///
/// Called from `kmain()` after [idtInstallAll] has written all 256 gates with
/// DPL 0. It is a second pass rather than a special case inside the loop
/// because the loop's claim is "all 256 gates were installed and the count is
/// what the loop actually did" (`M1 IDT 0100`), and threading an exception
/// through it would make that count mean something slightly different.
///
/// **This one attribute byte is the entire entry permission for userland.** With
/// 0x8E, `int 0x80` from CPL 3 is a #GP; with 0xEE it is a syscall. `user
/// badint` executes `int $3` against a gate that still has 0x8E, so the harness
/// sees both halves of that sentence in one session.
///
/// The gate stays an INTERRUPT gate rather than a trap gate: IF is cleared on
/// entry, so a timer tick cannot interleave with a syscall that is half-way
/// through printing.
@bare
void idtSetUserGate() {
  final u64 idt = idt_base();
  final u64 table = isr_stub_table_addr();
  final u64 handler =
      Pointer<u64>.fromAddress(table + (u64(vectorSyscall) * u64(8))).value;
  final u64 gate = idt + (u64(vectorSyscall) * u64(16));
  final u64 low = (handler & u64(0xFFFF)) |
      (u64(0x08) << u64(16)) |
      (u64(0x00) << u64(32)) |
      (u64(userGateAttr) << u64(40)) |
      (((handler >> u64(16)) & u64(0xFFFF)) << u64(48));
  final u64 high = (handler >> u64(32)) & u64(0xFFFFFFFF);
  Pointer<u64>.fromAddress(gate).value = low;
  Pointer<u64>.fromAddress(gate + u64(8)).value = high;
}

/// The DPL of IDT gate [vector], read back out of the live IDT.
///
/// Reported by `user pages` so the claim "one gate has DPL 3 and the rest have
/// DPL 0" is read out of the table the CPU walks rather than restated from
/// [userGateAttr]. The attribute byte is byte 5 of the gate, and the DPL is bits
/// 6..5 of it.
@bare
u64 userGateDpl(u64 vector) {
  final u64 gate = idt_base() + (vector * u64(16));
  final u64 low = Pointer<u64>.fromAddress(gate).value;
  return (low >> u64(45)) & u64(3);
}

/// Line label.
///
/// `'USER GATE 80 DPL '` -- 17 bytes.
@rodata
final List<u8> userStrGate = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x47), u8(0x41), u8(0x54), u8(0x45), u8(0x20), u8(0x38), u8(0x30),
  u8(0x20), u8(0x44), u8(0x50), u8(0x4C), u8(0x20),
];

/// Field separator.
///
/// `' GATE 03 DPL '` -- 13 bytes.
@rodata
final List<u8> userStrGate3 = const [
  u8(0x20), u8(0x47), u8(0x41), u8(0x54), u8(0x45), u8(0x20), u8(0x30), u8(0x33), u8(0x20), u8(0x44), u8(0x50), u8(0x4C),
  u8(0x20),
];

/// Field separator.
///
/// Line label, printed only when a cleanup step refuses — which is a state
/// nothing in this kernel can currently produce, and is therefore exactly the
/// kind of thing that must say so out loud rather than be dropped.
///
/// `'USER CLEANUP STATUS '` -- 20 bytes.
@rodata
final List<u8> userStrCleanup = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52), u8(0x20), u8(0x43), u8(0x4C), u8(0x45), u8(0x41), u8(0x4E), u8(0x55), u8(0x50),
  u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x54), u8(0x55), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' IDT '` -- 5 bytes.
@rodata
final List<u8> userStrIdt = const [
  u8(0x20), u8(0x49), u8(0x44), u8(0x54), u8(0x20),
];

/// `' TR '` -- 4 bytes.
@rodata
final List<u8> userStrTr = const [
  u8(0x20), u8(0x54), u8(0x52), u8(0x20),
];


/// `str` — the task register, read back out of the CPU. Zero means `ltr` never
/// ran, which is what the register holds after reset.
@extern
external u64 tr_read();

// ---------------------------------------------------------------------------
// Reporting. Every line is a walk or a register read, never a restatement of
// what this file intended.
// ---------------------------------------------------------------------------

/// `USER TSS <base> RSP0 <rsp0> GDT <base> TR <selector>`
///
/// **RSP0 is read out of the TSS, and TR out of the CPU.** Printing
/// `kstack0_top` and `0x28` would prove that this file can print two constants.
/// What has to be true is that `boot.S`'s zeroing loop wrote the field, that its
/// descriptor arithmetic produced a descriptor `ltr` would accept, and that
/// `ltr` ran -- and the only evidence of all three is in the machine.
///
/// The RSP0 field is at TSS offset 4, which is 4-byte aligned and not 8-byte
/// aligned. It is read as two `u32` loads recombined rather than one `u64` load
/// for the reason `multiboot.dart` reads its 64-bit length that way: DC-IR's
/// `Load` carries no alignment attribute, and depending on x86 tolerating an
/// unaligned access is depending on the target rather than on the language.
@bare
void userTssLine() {
  final u64 tss = tss_base();
  final u64 lo = Pointer<u32>.fromAddress(tss + u64(userTssRsp0)).value.toU64();
  final u64 hi = Pointer<u32>.fromAddress(tss + u64(userTssRsp0) + u64(4)).value.toU64();
  uartWrite(Rodata.addressOf(userStrTss), u64(9));
  uartPutHex(tss, u64(16));
  uartWrite(Rodata.addressOf(userStrRsp0), u64(6));
  uartPutHex((hi << u64(32)) | lo, u64(16));
  uartWrite(Rodata.addressOf(userStrGdt), u64(5));
  uartPutHex(gdt_base(), u64(16));
  uartWrite(Rodata.addressOf(userStrTr), u64(4));
  uartPutHex(tr_read(), u64(4));
  uartNewline();
}

/// `USER GATE 80 DPL <n> GATE 03 DPL <n> IDT <base>`
///
/// The two numbers that decide whether `int 0x80` is a syscall or a fault, read
/// out of the live IDT. Gate 0x80 must be 3 and gate 3 must be 0; `user badint`
/// then executes `int $3` and the #GP that follows is that second number
/// happening.
@bare
void userGateLine() {
  uartWrite(Rodata.addressOf(userStrGate), u64(17));
  uartPutHex(userGateDpl(u64(vectorSyscall)), u64(1));
  uartWrite(Rodata.addressOf(userStrGate3), u64(13));
  uartPutHex(userGateDpl(u64(3)), u64(1));
  // The IDT's base, so the harness can read the gates out of guest physical
  // memory at an address the KERNEL named and then require it to equal the one
  // QEMU's own `info registers` reports. Neither number is load-bearing alone.
  uartWrite(Rodata.addressOf(userStrIdt), u64(5));
  uartPutHex(idt_base(), u64(16));
  uartNewline();
}

/// One page's effective permissions: `<label> <va> P <n> U <n> W <n> X <n>`.
///
/// Every field is the AND (or, for X, the absence of any veto) across all four
/// levels of the live tables — see [vmEffective]. The `U` column is the one this
/// milestone added and the only one that is ever 1 for exactly two pages in the
/// whole address space.
@bare
void userPageLine(u64 label, u64 labelLen, u64 va) {
  final u64 e = vmEffective(va);
  uartWrite(label, labelLen);
  uartPutHex(va, u64(16));
  uartWrite(Rodata.addressOf(vmStrP), u64(3));
  uartPutHex(e & u64(1), u64(1));
  uartWrite(Rodata.addressOf(userStrU), u64(3));
  uartPutHex((e >> u64(1)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(vmStrW), u64(3));
  uartPutHex((e >> u64(2)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(vmStrX), u64(3));
  uartPutHex((e >> u64(3)) & u64(1), u64(1));
  uartNewline();
}

/// `USER WINDOW PAGES <total> USER <count>`
///
/// **The whole-address-space statement, and the reason it is a COUNT rather
/// than a yes/no.** Every 4KiB page in `[0, 4MiB)` is walked and the
/// user-accessible ones are counted. Before a payload is mapped the count must
/// be 0 — not "the pages I checked were supervisor", but *none of the 1024*.
/// While one is running it must be exactly 2. After it exits or dies it must be
/// 0 again.
///
/// The 2MiB pages above 4MiB and the PCI hole are not scanned here because they
/// are leaves this kernel writes without [vmUser] and never edits; the harness
/// walks those out of guest memory anyway, because "we never set the bit" is a
/// claim about the code and not about the table.
@bare
void userWindowLine() {
  uartWrite(Rodata.addressOf(userStrWindow), u64(18));
  uartPutHex(u64(vmFinePages), u64(8));
  uartWrite(Rodata.addressOf(userStrUserFld), u64(6));
  uartPutHex(vmCountUser(u64(0), u64(vmFineBytes)), u64(8));
  uartNewline();
}

/// `USER CANARY <value> OK|FAIL`
///
/// The word `user pf` aims at, read back and compared against the value written
/// before the payload ran. **"The store did not land" is this line**, not the
/// absence of a `USER EXIT` — a fault that was reported and a store that landed
/// anyway are perfectly compatible, and that is not a hypothetical: it is
/// exactly the shape of GAP-0080, where `.rodata` entries said read-only and the
/// write went through because `CR0.WP` was clear.
///
/// Printed on every teardown, not only on `user pf`, so a payload that scribbled
/// on kernel memory by some route nobody predicted is still caught.
@bare
void userCanaryLine() {
  final u64 got = userMeta(u64(userMetaCanary));
  uartWrite(Rodata.addressOf(userStrCanary), u64(12));
  uartPutHex(got, u64(16));
  uartSpace();
  if (got == u64(userCanaryValue)) {
    uartWrite(Rodata.addressOf(pmmStrOk), u64(2));
  } else {
    uartWrite(Rodata.addressOf(pmmStrFail), u64(4));
  }
  uartNewline();
}

// ---------------------------------------------------------------------------
// The payload table, as two functions because `@bare` DCDart has no way to
// return two values and no array of tables to index.
// ---------------------------------------------------------------------------

/// Address of [mode]'s machine code.
@bare
u64 userCodeAddr(u64 mode) {
  if (mode == u64(userModeGp)) {
    return Rodata.addressOf(userCodeGp);
  }
  if (mode == u64(userModePf)) {
    return Rodata.addressOf(userCodePf);
  }
  if (mode == u64(userModeBadint)) {
    return Rodata.addressOf(userCodeBadint);
  }
  if (mode == u64(userModeBadptr)) {
    return Rodata.addressOf(userCodeBadptr);
  }
  if (mode == u64(userModeHold)) {
    return Rodata.addressOf(userCodeHold);
  }
  return Rodata.addressOf(userCodeRun);
}

/// The five payload lengths, indexed by mode.
///
/// **A `@rodata` table rather than a chain of `if`s, and that is a finding
/// rather than a preference.** The first revision spelled this as five
/// comparisons returning five constants, and LLVM recognised the shape and
/// lowered it into a lookup table of its own — `.Lswitch.table.userCodeLen`, in
/// `.rodata.cst32`. That is GAP-0079's phenomenon again (LLVM put `pmmFreeStatus`
/// in `.rodata` at M7) with one difference that mattered: it landed in a
/// MERGEABLE-CONSTANT section rather than in `.rodata`, and
/// `m1-interrupts/run.sh` asserts that every OBJECT symbol `dcc` emits is in
/// `.rodata`'s section index — an assertion whose whole point is that a table
/// which lands elsewhere might be writable or might not be loaded at all.
///
/// The assertion was NOT relaxed to accommodate it (ADR-0012 §8: an assertion a
/// milestone weakens in order to pass is not an assertion). The table LLVM
/// wanted to build is written explicitly instead, which is where it belonged:
/// the five lengths now sit next to each other where a reader can compare them,
/// they are `@rodata` under DCDart's own mechanism rather than the optimizer's,
/// and `tests/conformance/m9-ring3/run.sh` reads all five bytes out of `kmain.o`
/// and requires each to equal the real size of the payload symbol it describes —
/// which is a stronger check than GAP-0060's usual "the call site passes the
/// right number", because there is now only one number and it is data.
///
/// 6 bytes.
@rodata
final List<u8> userCodeSizes = const [
  u8(0x37), u8(0x0F), u8(0x11), u8(0x10), u8(0x18), u8(0x09),
];

/// How many payload modes exist. The bound on [userCodeLen]'s index.
const int userModeCount = 6;

/// Length of [mode]'s machine code, or 0 for a mode that does not exist.
///
/// Zero is a safe refusal rather than a convention: [userCopy] copies exactly
/// this many bytes, so an unknown mode copies nothing and the payload frame stays
/// as [vmZeroFrame] left it — 4096 zero bytes, which decode as `add %al,(%rax)`
/// and fault on the first instruction with the frame's own address in CR2. A
/// wrong length here would copy the wrong number of bytes into a page ring 3 is
/// about to execute.
@bare
u64 userCodeLen(u64 mode) {
  if (mode >= u64(userModeCount)) {
    return u64(0);
  }
  return Pointer<u8>.fromAddress(Rodata.addressOf(userCodeSizes) + mode)
      .value
      .toU64();
}

/// The single value ring 3 is handed, in RDI.
///
/// **One channel, and it is one register.** `user pf` and `user badptr` both
/// need a kernel address to aim at, and giving it to them is what makes them
/// tests of the kernel's refusal rather than tests of the payload's ability to
/// guess an address. Every other mode gets zero, because there is nothing ring 3
/// is entitled to know.
@bare
u64 userArgFor(u64 mode) {
  if (mode == u64(userModePf)) {
    return userMetaBase() + (u64(userMetaCanary) << u64(3));
  }
  if (mode == u64(userModeBadptr)) {
    return userMetaBase() + (u64(userMetaCanary) << u64(3));
  }
  return u64(0);
}

/// Copies [n] bytes from [src] to [dst], one byte at a time.
///
/// Byte-wise deliberately. GAP-0082 recorded that reaching a `@rodata` table
/// through a wider pointer makes the toolchain give that table the wider type's
/// alignment, which opens a hole in front of it and breaks
/// `m1-interrupts/run.sh`'s "elements only, no header" assertion. The payload
/// tables are read here and nowhere else, and they are read as bytes.
@bare
void userCopy(u64 dst, u64 src, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    Pointer<u8>.fromAddress(dst + i).value = Pointer<u8>.fromAddress(src + i).value;
    i = i + u64(1);
  }
}

// ---------------------------------------------------------------------------
// The syscalls.
// ---------------------------------------------------------------------------

/// Refuses one syscall, loudly, and hands ring 3 [userRefused].
///
/// **A refusal is printed and counted, never silent.** `frames`' ERRORS word
/// exists for the same reason (ADR-0011 §4): a subsystem that reports zero
/// refusals is making a claim only if a refusal would have been recorded.
@bare
void userRefuse(u64 frame, u64 no, u64 ptr, u64 len) {
  userBump(u64(userMetaRefusals));
  uartWrite(Rodata.addressOf(userStrRefuse), u64(15));
  uartPutHex(no, u64(16));
  uartWrite(Rodata.addressOf(userStrPtr), u64(5));
  uartPutHex(ptr, u64(16));
  uartWrite(Rodata.addressOf(userStrLen), u64(5));
  uartPutHex(len, u64(16));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), u64(userRefused));
}

/// Syscall 2 — `whoami`. Prints the CPU's own record of who was running.
///
/// `USER CS <cs> SS <ss> RFLAGS <rflags> CPL <n>`
///
/// **This is the milestone's central assertion and it is deliberately made from
/// the wrong side of the boundary.** The payload does not report its privilege
/// level; it asks. The values come out of the frame the CPU pushed when it took
/// the `int 0x80`, so CS is the selector that was in CS at the moment of the
/// trap and its low two bits are the CPL the processor itself believed the code
/// was running at. A payload that read CS with `mov %cs,%ax` and printed it
/// would be the thing under test testing itself.
///
/// The return value is the CPL, so ring 3 can see it too.
@bare
void userSysWho(u64 frame) {
  final u64 cs = userFrame(frame, u64(userFrameCs));
  uartWrite(Rodata.addressOf(userStrCs), u64(8));
  uartPutHex(cs, u64(16));
  uartWrite(Rodata.addressOf(userStrSs), u64(4));
  uartPutHex(userFrame(frame, u64(userFrameSs)), u64(16));
  uartWrite(Rodata.addressOf(userStrRflags), u64(8));
  uartPutHex(userFrame(frame, u64(userFrameFlags)), u64(16));
  uartWrite(Rodata.addressOf(userStrCpl), u64(5));
  uartPutHex(cs & u64(3), u64(1));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), cs & u64(3));
}

/// 1 if `[ptr, ptr+len)` lies wholly inside one of the payload's two pages.
///
/// **The bound on [ptr] comes FIRST, before any arithmetic on it, and that is a
/// correctness requirement rather than an ordering preference.** DCDart's
/// arithmetic traps on overflow (DCDART_SPEC §4.1) by emitting a real `ud2`, and
/// `ptr` is a value ring 3 chose: `write(0xFFFFFFFFFFFFFFFF, 8)` would make
/// `ptr + len` overflow inside this function and take a #UD *in the syscall
/// handler*. A ring-3 program must not be able to choose which instruction the
/// kernel executes next, and the range test that was supposed to stop it would
/// have been the thing it used. Checked against `vmFineBytes` because both
/// payload pages are inside the 4KiB window by construction.
///
/// A zero length is refused too: it is never useful, and accepting it would make
/// "len is inside the page" vacuously true for a pointer that is not.
@bare
u64 userOwns(u64 ptr, u64 len) {
  // M11: a THIRD thing can be in ring 3 -- a process. Its pages are in the same
  // 2MiB window a loaded program's are, so the same per-page walk answers the
  // question; what differs is WHOSE tables the walk reads, and that is settled
  // by CR3 rather than here (`vmProgPd`, ADR-0015 §4). Asked first because a
  // process and an M10 `run` program cannot both be live -- `shellProcRun`
  // refuses -- but the order states which one wins rather than leaving it to the
  // reader.
  if (procLive() > u64(0)) {
    return elfOwns(ptr, len);
  }
  // M10: two different things can be in ring 3 on this machine now -- a payload
  // from this file's `@rodata`, whose two pages are inside the 4KiB identity
  // window, and a program loaded from a disk, whose pages are in the 2MiB
  // program window at an address a linker chose. They have nothing in common
  // except that both are untrusted, so the ownership test is dispatched rather
  // than widened: a single range check spanning both would accept every kernel
  // page in between.
  if (elfLive() > u64(0)) {
    return elfOwns(ptr, len);
  }
  if (ptr >= u64(vmFineBytes)) {
    return u64(0);
  }
  if (len < u64(1)) {
    return u64(0);
  }
  if (len > u64(userWriteMax)) {
    return u64(0);
  }
  final u64 code = userMeta(u64(userMetaCodeFrame));
  final u64 stack = userMeta(u64(userMetaStackFrame));
  if (ptr >= code) {
    if ((ptr + len) <= (code + u64(vmPageBytes))) {
      return u64(1);
    }
  }
  if (ptr >= stack) {
    if ((ptr + len) <= (stack + u64(vmPageBytes))) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Syscall 1 — `write(ptr, len)`. Prints [len] bytes from [ptr] through the
/// existing console, and returns [len].
///
/// The kernel dereferences a pointer ring 3 chose, which is the oldest hole in
/// the business, so [userOwns] decides first. `user badptr` hands this a kernel
/// address on purpose and must get [userRefused] back.
///
/// The bytes go through `uartWrite`, which is the same function every other line
/// in this kernel uses and therefore mirrors to the VGA text console and the
/// framebuffer as well. `USER WRITE ` is printed in front of them so the capture
/// distinguishes what ring 3 said from what the kernel said about it.
@bare
void userSysWrite(u64 frame) {
  final u64 ptr = userFrame(frame, u64(userFrameRdi));
  final u64 len = userFrame(frame, u64(userFrameRsi));
  if (userOwns(ptr, len) < u64(1)) {
    userRefuse(frame, u64(userSysWriteNo), ptr, len);
    return;
  }
  uartWrite(Rodata.addressOf(userStrWrite), u64(11));
  uartWrite(ptr, len);
  uartNewline();
  userSetMeta(u64(userMetaWritten), userMeta(u64(userMetaWritten)) + len);
  userSetFrame(frame, u64(userFrameRax), len);
}

/// Unmaps the payload's two pages, reports the result, gives the frames back,
/// and clears the live flag. Prints four lines.
///
/// **Every exit from ring 3 comes through here** — the `exit` syscall and the
/// fault path both — because the property that matters is not "the pages are
/// unmapped when the payload is polite". A boundary that is open whenever
/// something went wrong is not a boundary, and three of this file's six payload
/// sub-commands end in a fault on purpose.
///
/// The permissions are restored by [vmClearUser] from [vmPageFlags], the same
/// function that wrote them at boot, and then READ BACK by [userPageLine] out of
/// the live tables before the frames are freed. Freeing first would mean
/// reporting the permissions of a page that has already been handed to somebody
/// else.
@bare
void userTeardown() {
  final u64 code = userMeta(u64(userMetaCodeFrame));
  final u64 stack = userMeta(u64(userMetaStackFrame));
  // The statuses are bound rather than dropped because `dcc` requires it, and
  // they are not reported because the two lines below are a STRONGER statement
  // than either status would be: they walk the live tables and print the U bit
  // that is actually there. A `vmClearUser` that returned OK and left the page
  // user-accessible would pass a status check and fail this one.
  final u64 c1 = vmClearUser(code);
  final u64 c2 = vmClearUser(stack);
  if ((c1 | c2) > u64(0)) {
    uartWrite(Rodata.addressOf(userStrCleanup), u64(20));
    uartPutHex(c1 | c2, u64(8));
    uartNewline();
  }
  userPageLine(Rodata.addressOf(userStrPageCode), u64(15), code);
  userPageLine(Rodata.addressOf(userStrPageStack), u64(16), stack);
  userWindowLine();
  userCanaryLine();
  final u64 f1 = freeFrame(code);
  final u64 f2 = freeFrame(stack);
  if ((f1 | f2) > u64(0)) {
    uartWrite(Rodata.addressOf(userStrCleanup), u64(20));
    uartPutHex(f1 | f2, u64(8));
    uartNewline();
  }
  userSetMeta(u64(userMetaCodeFrame), u64(0));
  userSetMeta(u64(userMetaStackFrame), u64(0));
  userSetMeta(u64(userMetaLive), u64(0));
  // The assembly-owned resume guard is deliberately NOT cleared here.
  //
  // On the exit path this function is called BY the `exit` syscall, which then
  // calls `user_return` -- and `user_return` refuses to switch stacks unless the
  // guard reads exactly 1. Clearing it here made the first `user` command halt
  // the machine after a flawless run: every line of the report was printed, the
  // pages were back to supervisor, and then `jne halt_forever` took the branch.
  // The exit path's clear belongs in `user_return`, which does it after the
  // check, and the abort path's belongs in [userOnFault], which is the only
  // caller that reaches this function without one.
}

/// Syscall 0 — `exit(code)`. **Never returns.**
///
/// Reports, tears down, and then leaves through `user_return`, which sets RSP
/// back to the value `enter_user` recorded and returns into [shellUser]. The
/// interrupt frame this handler is standing on, and the whole ring-0 stack under
/// it, are abandoned in that one store — which is fine, because RSP0 is
/// re-loaded from the TSS on the next entry from ring 3 and nothing on that
/// stack outlives a syscall.
///
/// The teardown happens BEFORE the stack switch, deliberately: after it, this
/// function's frame no longer exists and there is nothing to run.
@bare
void userSysExit(u64 frame) {
  final u64 code = userFrame(frame, u64(userFrameRdi));
  // M15: one line about the files this boot's programs read, and NOTHING AT ALL
  // if none of them opened one. Printed here rather than in the teardown paths
  // because this is the one place both things that can be in ring 3 pass
  // through on the way out, and printed BEFORE the process branch below because
  // that branch does not come back.
  fileExitReport();
  // M16: a SECOND line, and only if this boot wrote something. Every harness
  // before M16 boots a kernel that never writes, so on every one of them this
  // prints nothing and no golden moves.
  fileWriteReport();
  // M11: a process's exit is a different event. It may not be the end of
  // anything -- another process can be READY -- so [procSysExit] RETURNS
  // NORMALLY when it switched to somebody else, and never returns when this was
  // the last one. Neither shape fits the three lines below, which assume the
  // machine is going back to a shell.
  if (procLive() > u64(0)) {
    procSysExit(frame, code);
    return;
  }
  userSetMeta(u64(userMetaExit), code);
  uartWrite(Rodata.addressOf(userStrExit), u64(15));
  uartPutHex(code, u64(16));
  uartWrite(Rodata.addressOf(userStrSyscalls), u64(10));
  uartPutHex(userMeta(u64(userMetaSyscalls)), u64(8));
  uartWrite(Rodata.addressOf(userStrRefusals), u64(10));
  uartPutHex(userMeta(u64(userMetaRefusals)), u64(8));
  uartNewline();
  // M10: whichever of the two things that can be in ring 3 called this.
  if (elfLive() > u64(0)) {
    elfSetMeta(u64(elfMetaExit), code);
    elfTeardown();
  } else {
    userTeardown();
  }
  user_return(); // never returns; control reappears in shellUser or shellElfRun
}

/// Vector 0x80. Called from [isrDispatch].
///
/// Runs in ring 0, on the ring-0 stack the TSS named, with interrupts disabled
/// by the gate, and with all fifteen general-purpose registers already saved
/// into [frame] by `isr_common` — which is exactly why `int 0x80` was chosen
/// over `syscall`: the entry path already existed and already produced the data
/// structure a DCDart handler needs (ADR-0013 §4).
///
/// **Two refusals come before any dispatch, and both are about the caller rather
/// than the request:**
///
///   * the saved CS must have CPL 3. Ring-0 code executing `int 0x80` is not a
///     userland program asking for a service, it is the kernel calling itself
///     through an interrupt gate, and the `exit` path would then hand a stack
///     pointer recorded for a different call to `user_return`;
///   * a payload must actually be live. Otherwise the frame numbers this
///     handler validates pointers against are stale.
///
/// Neither is reachable from the six payloads in this file. They are here
/// because the gate is DPL 3, and a DPL-3 gate is reachable by anything that
/// ever runs in ring 3 on this machine, including whatever a later milestone
/// loads.
@bare
void userSyscall(u64 frame) {
  final u64 cs = userFrame(frame, u64(userFrameCs));
  userSetMeta(u64(userMetaCs), cs);
  userSetMeta(u64(userMetaSs), userFrame(frame, u64(userFrameSs)));
  userSetMeta(u64(userMetaFlags), userFrame(frame, u64(userFrameFlags)));
  userBump(u64(userMetaSyscalls));
  final u64 no = userFrame(frame, u64(userFrameRax));
  if ((cs & u64(3)) < u64(3)) {
    userRefuse(frame, no, cs, u64(0));
    return;
  }
  if (userMeta(u64(userMetaLive)) < u64(1)) {
    // M10: or a loaded ELF program, which is the other thing that can be in
    // ring 3. Nested rather than `||` because `@bare` DCDart has no boolean
    // operators at all (GAP-0023).
    if (elfLive() < u64(1)) {
      // M11: or a process, which is the third.
      if (procLive() < u64(1)) {
        userRefuse(frame, no, cs, u64(0));
        return;
      }
    }
  }
  // M11: `yield` (syscall 3). Refused unless a PROCESS is live, and that is not
  // a formality: with no process table entry to save into there is nothing to
  // suspend, and an M9 payload or an M10 `run` program calling it would
  // otherwise reach [procCurrent] with a header word that means "nobody".
  if (no == u64(procSysYieldNo)) {
    if (procLive() < u64(1)) {
      userRefuse(frame, no, cs, u64(0));
      return;
    }
    procYield(frame);
    return;
  }
  // M12: `sbrk` (syscall 4). Refused unless a PROCESS is live, for `yield`'s
  // reason and one more: the heap it grows lives in the CALLING process's slot,
  // and there is no slot to grow without one.
  if (no == u64(heapSysSbrkNo)) {
    if (procLive() < u64(1)) {
      userRefuse(frame, no, cs, u64(0));
      return;
    }
    heapSysSbrk(frame);
    return;
  }
  // M15: `open`, `read`, `close` and `seek` (syscalls 5..8). Unlike `yield` and
  // `sbrk` these do NOT require a process: two different things can be in ring
  // 3 on this machine, and the one `run <name>` produces has an image and a
  // name and no process slot. [fileOwnerRow] is where that is decided, once,
  // and each of the four refuses with [fileRetNoOwner] when the caller is an M9
  // payload -- two pages in the identity window with no program image, which is
  // reachable here because the gate is DPL 3.
  if (no == u64(fileSysOpenNo)) {
    fileSysOpen(frame);
    return;
  }
  if (no == u64(fileSysReadNo)) {
    fileSysRead(frame);
    return;
  }
  if (no == u64(fileSysCloseNo)) {
    fileSysClose(frame);
    return;
  }
  if (no == u64(fileSysSeekNo)) {
    fileSysSeek(frame);
    return;
  }
  // M16: `fdwrite` (syscall 9). The first syscall on this machine that can
  // change a disk, and it sits here rather than anywhere special: the gate, the
  // frame, the owner row and the refusal floor are all the same as the other
  // five. What is different is entirely inside [fileSysWrite].
  if (no == u64(fileSysWriteNo)) {
    fileSysWrite(frame);
    return;
  }
  if (no == u64(userSysWhoNo)) {
    userSysWho(frame);
    return;
  }
  if (no == u64(userSysWriteNo)) {
    userSysWrite(frame);
    return;
  }
  if (no == u64(userSysExitNo)) {
    userSysExit(frame); // never returns
    return;
  }
  userRefuse(frame, no, u64(0), u64(0));
}

/// Called from [isrDispatch]'s fault arm, after the diagnostic and before
/// `fault_resume`. Does nothing at all unless a payload is live.
///
/// **This is what makes a faulting payload a killed program rather than a leak.**
/// The M4 recovery path abandons every frame between the fault and the shell
/// loop, so [shellUser] never runs again and never gets to clean up: without
/// this hook, `user gp` would leave two user-accessible pages mapped and two
/// frames allocated, for the rest of the boot, every time. `user pages` would
/// then report `USER 00000002` with nothing running, which is precisely the
/// state a privilege boundary must not be able to end up in.
///
/// It reports the CPL out of the frame rather than assuming 3. A fault taken in
/// the kernel while a payload was live — inside the syscall handler, say — is a
/// different event and the report says so, but the teardown happens either way,
/// because the payload is not going to run again in either case.
/// `USER FAULT VEC <n> ERR <code> RIP <rip> CPL <n>`
///
/// The CPU's own account of what happened, out of the frame it pushed: the
/// vector, the error code, the address it faulted at, and the privilege level
/// it believed it was running at. Shared by BOTH things that can be in ring 3
/// on this machine — M9's payloads and M10's loaded programs — because it says
/// nothing about either of them, only about the trap.
@bare
void userFaultLine(u64 vector, u64 errorCode, u64 rip, u64 cs) {
  uartWrite(Rodata.addressOf(userStrFault), u64(15));
  uartPutHex(vector, u64(2));
  uartWrite(Rodata.addressOf(vmStrErr), u64(5));
  uartPutHex(errorCode, u64(16));
  uartWrite(Rodata.addressOf(userStrRip), u64(5));
  uartPutHex(rip, u64(16));
  uartWrite(Rodata.addressOf(userStrCpl), u64(5));
  uartPutHex(cs & u64(3), u64(1));
  uartNewline();
}

@bare
void userOnFault(u64 vector, u64 errorCode, u64 rip, u64 frame) {
  // M11: a process is the third thing that can die here, and it is torn down
  // through a third path because it owns a whole address space -- four table
  // frames and its pages -- rather than a window inside somebody else's.
  // Asked FIRST because a process is the only one of the three that requires
  // CR3 to be put back before anything can be freed.
  if (procLive() > u64(0)) {
    procOnFault(vector, errorCode, rip, frame);
    return;
  }
  // M10: a loaded ELF program is the other thing that can die here, and it is
  // torn down through a different path because it owns a different kind of
  // memory — a page table and a window, not two frames in the identity map.
  if (elfLive() > u64(0)) {
    final u64 ecs = userFrame(frame, u64(userFrameCs));
    userFaultLine(vector, errorCode, rip, ecs);
    elfTeardown();
    Pointer<u64>.fromAddress(user_resume_ok_addr()).value = u64(0);
    return;
  }
  if (userMeta(u64(userMetaLive)) < u64(1)) {
    return;
  }
  final u64 cs = userFrame(frame, u64(userFrameCs));
  userBump(u64(userMetaAborts));
  userSetMeta(u64(userMetaRip), rip);
  userSetMeta(u64(userMetaErr), errorCode);
  userSetMeta(u64(userMetaCs), cs);
  userFaultLine(vector, errorCode, rip, cs);
  uartWrite(Rodata.addressOf(userStrAbort), u64(17));
  uartPutHex(userMeta(u64(userMetaCodeFrame)), u64(16));
  uartWrite(Rodata.addressOf(userStrStack), u64(7));
  uartPutHex(userMeta(u64(userMetaStackFrame)), u64(16));
  uartNewline();
  userTeardown();
  // The payload is dead and `user_return` will never run for it, so the resume
  // point it recorded describes a stack frame that is about to be discarded by
  // `fault_resume`. Clearing the guard is what stops a later, unrelated
  // `int 0x80` from returning onto it. See `user_resume_ok` in kdata.S.
  Pointer<u64>.fromAddress(user_resume_ok_addr()).value = u64(0);
}

// ---------------------------------------------------------------------------
// The shell command.
// ---------------------------------------------------------------------------

/// `user pages` — the address space's privilege picture, with nothing running.
///
/// Three lines, no ring-3 entry, no allocation: the TSS and task register, the
/// two gate DPLs, and the count of user-accessible pages in the 4KiB window.
/// Run before and after every other sub-command in the conformance session, so
/// the count returning to zero is asserted rather than assumed.
@bare
void shellUserPages() {
  userTssLine();
  userGateLine();
  userWindowLine();
}

/// `user`, `user gp`, `user pf`, `user badint`, `user badptr` — build a payload,
/// enter ring 3, and report.
///
/// The sequence, and every step is printed so a boot that stops part-way says
/// where:
///
///   1. two frames from the M7 allocator, zeroed. **Zeroing is not hygiene
///      here**: `allocFrame()` returns whatever the frame last contained
///      (GAP-0076 item 5) and both pages are about to become readable by an
///      untrusted program. Handing ring 3 a page of stale kernel data would be
///      an information leak created by this very command.
///   2. the payload's bytes copied into the code frame.
///   3. `vmMapUser` on both — code read+execute, stack read+write, both
///      user-accessible, and W^X applies to ring 3 as well.
///   4. the permissions READ BACK out of the live tables, plus the window count,
///      which must now be exactly 2.
///   5. `enter_user`, which does not return except through the `exit` syscall.
///   6. on return, the final counters.
///
/// **Every refusal before step 5 leaves the machine exactly as it was**: the
/// frames are freed, the mappings are put back, and the live flag is never set.
/// The one that cannot be undone is step 5, which is why everything checkable is
/// checked before it.
@bare
void shellUser(u64 mode) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    uartWrite(Rodata.addressOf(userStrNotReady), u64(53));
    return;
  }
  final u64 code = allocFrame();
  if (code < u64(1)) {
    uartWrite(Rodata.addressOf(userStrNoFrames), u64(36));
    return;
  }
  final u64 stack = allocFrame();
  if (stack < u64(1)) {
    final u64 back = freeFrame(code);
    uartWrite(Rodata.addressOf(userStrCleanup), u64(20));
    uartPutHex(back, u64(8));
    uartNewline();
    uartWrite(Rodata.addressOf(userStrNoFrames), u64(36));
    return;
  }

  userSetMeta(u64(userMetaMode), mode);
  userSetMeta(u64(userMetaCodeFrame), code);
  userSetMeta(u64(userMetaStackFrame), stack);
  userSetMeta(u64(userMetaCanary), u64(userCanaryValue));
  vmZeroFrame(code);
  vmZeroFrame(stack);
  userCopy(code, userCodeAddr(mode), userCodeLen(mode));

  userTssLine();
  userGateLine();
  uartWrite(Rodata.addressOf(userStrMap), u64(14));
  uartPutHex(code, u64(16));
  uartWrite(Rodata.addressOf(userStrStack), u64(7));
  uartPutHex(stack, u64(16));
  uartNewline();

  final u64 s1 = vmMapUser(code, u64(1));
  final u64 s2 = vmMapUser(stack, u64(0));
  if ((s1 | s2) > u64(0)) {
    uartWrite(Rodata.addressOf(userStrNoMap), u64(49));
    uartPutHex(s1 | s2, u64(8));
    uartNewline();
    final u64 c1 = vmClearUser(code);
    final u64 c2 = vmClearUser(stack);
    final u64 f1 = freeFrame(code);
    final u64 f2 = freeFrame(stack);
    uartWrite(Rodata.addressOf(userStrCleanup), u64(20));
    uartPutHex(c1 | c2 | f1 | f2, u64(8));
    uartNewline();
    userSetMeta(u64(userMetaCodeFrame), u64(0));
    userSetMeta(u64(userMetaStackFrame), u64(0));
    return;
  }

  userPageLine(Rodata.addressOf(userStrPageCode), u64(15), code);
  userPageLine(Rodata.addressOf(userStrPageStack), u64(16), stack);
  userWindowLine();

  final u64 arg = userArgFor(mode);
  final u64 top = stack + u64(vmPageBytes);
  uartWrite(Rodata.addressOf(userStrEnter), u64(15));
  uartPutHex(code, u64(16));
  uartWrite(Rodata.addressOf(userStrRsp), u64(5));
  uartPutHex(top, u64(16));
  uartWrite(Rodata.addressOf(userStrArg), u64(5));
  uartPutHex(arg, u64(16));
  uartNewline();

  userBump(u64(userMetaEntries));
  userSetMeta(u64(userMetaLive), u64(1));
  enter_user(code, top, arg, u64(userCodeSel), u64(userDataSel));

  // Reached only through `user_return`, i.e. only if the payload called `exit`.
  // A payload that faulted came back to the shell through `fault_resume` and
  // this frame no longer exists.
  uartWrite(Rodata.addressOf(userStrDone), u64(18));
  uartPutHex(userMeta(u64(userMetaEntries)), u64(8));
  uartWrite(Rodata.addressOf(userStrAborts), u64(8));
  uartPutHex(userMeta(u64(userMetaAborts)), u64(8));
  uartNewline();
}

/// `user` with an argument this shell does not know.
@bare
void shellUserUsage() {
  uartWrite(Rodata.addressOf(userStrUsage), u64(91));
}
