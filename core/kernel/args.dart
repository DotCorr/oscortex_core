// core/kernel/args.dart
//
// M19: `main(argc, argv)`. THE INITIAL PROCESS STACK, BUILT BY THE KERNEL IN
// THE PROGRAM'S OWN ADDRESS SPACE.
//
// A `part` of `kmain.dart`'s library rather than an import, for the reason every
// other file here is: `dcc` lowers exactly ONE library per object file, so a
// `@bare` function in an imported library is not compiled at all
// (docs/known-gaps.md GAP-0004 item 4).
//
// The architecture is docs/decisions/0023-argv-and-the-initial-process-stack.md;
// the binary exit criterion is ROADMAP.md's M19 and
// tests/conformance/m19-argv/run.sh.
//
// ---------------------------------------------------------------------------
// WHAT THIS CLOSES: GAP-0113's LAST ITEM AND GAP-0122 ITEM 8
// ---------------------------------------------------------------------------
// Until this file, a program on this operating system entered at `_start` with
// NOTHING. Every test program had its inputs compiled into it -- m15-fileio's
// program has the string `"DATA.BIN"` in its own `.rodata` -- because there was
// no way to tell a program anything from outside it. That is the wall every C
// program is on the wrong side of, because every C program begins
// `int main(int argc, char **argv)`.
//
// This file builds the System V x86-64 initial process stack. After it, `run
// WC.ELF DATA.BIN lines` runs a program that was not compiled to know either
// word.
//
// ---------------------------------------------------------------------------
// THE LAYOUT, AND IT IS THE ABI's
// ---------------------------------------------------------------------------
// At `_start`, with RSP the value this file computes:
//
//   RSP + 0x00           argc                       (8 bytes)
//   RSP + 0x08           argv[0]                    (8 bytes)
//   ...                  ...
//   RSP + 8*argc         argv[argc-1]
//   RSP + 8*(argc+1)     NULL                       -- terminates argv
//   RSP + 8*(argc+2)     NULL                       -- terminates envp, WHICH
//                                                      IS EMPTY. There is no
//                                                      environment on this
//                                                      operating system and no
//                                                      `setenv`; `envp[0]` IS
//                                                      the terminator and
//                                                      `environ` is a vector of
//                                                      length zero. GAP-0146.
//   RSP + 8*(argc+3)     0  \_ one Elf64_auxv_t whose a_type is AT_NULL, which
//   RSP + 8*(argc+4)     0  /  is what terminates an auxiliary vector that has
//                              no entries. There is no AT_PHDR, no AT_PAGESZ
//                              and no AT_RANDOM. GAP-0147.
//   ... zero padding ...
//   the argument strings, NUL-terminated, in argv order, ending at or just
//   below `vmProgStackTop`.
//
// **RSP IS 16-BYTE ALIGNED**, which is what the ABI requires at process entry
// and is NOT the same rule as at a `call` (where the callee sees RSP+8 aligned
// because the return address is on the stack). A `_start` that immediately
// `call`s `main` therefore does the right thing without touching RSP: the
// `call` pushes eight bytes and `main` sees exactly what any other function
// sees. m19-argv reads RSP out of guest memory and requires `RSP & 15 == 0`.
//
// **THE STRINGS ARE IN THE PROGRAM'S OWN ADDRESS SPACE**, on the stack page the
// loader mapped for it -- user-readable, writable, NX -- and nowhere else. They
// are written through the stack frame's PHYSICAL address, which the kernel's
// identity map covers, before `enter_user`; the kernel never hands ring 3 a
// pointer into `.bss`, and `argsStore` below is not reachable from ring 3 at
// all. When the program exits, `elfTeardown` frees that frame like any other
// and the strings go with it: nothing in `argv` outlives the address space.
//
// ---------------------------------------------------------------------------
// TWO BOUNDS, AND A REFUSAL FOR EACH
// ---------------------------------------------------------------------------
// [argsMaxCount] arguments INCLUDING argv[0], and [argsMaxBytes] bytes of text
// INCLUDING one NUL per argument. Both are refused BEFORE a single frame is
// allocated -- the refusal happens in the shell's parse, so a rejected command
// line costs the machine nothing and leaves the shell alive. There is no
// truncation anywhere: a ninth argument is not dropped, it is a refusal, for
// [fatParseAt]'s reason (a truncated name looks up a different file, and a
// truncated argument runs a different program).

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The message tables. @rodata for ADR-0004's reason: a table in .rodata is
// mapped read-only and cannot be corrupted by a stray kernel write.
// ---------------------------------------------------------------------------

/// Label.
///
/// `'ELF ARGS N '` -- 11 bytes.
@rodata
final List<u8> argsStrArgs = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x41), u8(0x52), u8(0x47), u8(0x53), u8(0x20), u8(0x4E), u8(0x20),
];

/// Label.
///
/// `' BYTES '` -- 7 bytes.
@rodata
final List<u8> argsStrBytes = const [
  u8(0x20), u8(0x42), u8(0x59), u8(0x54), u8(0x45), u8(0x53), u8(0x20),
];

/// Label.
///
/// `' VEC '` -- 5 bytes.
@rodata
final List<u8> argsStrVec = const [
  u8(0x20), u8(0x56), u8(0x45), u8(0x43), u8(0x20),
];

/// Label.
///
/// `' STR '` -- 5 bytes.
@rodata
final List<u8> argsStrStr = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x52), u8(0x20),
];

/// Label.
///
/// `'ELF ARG '` -- 8 bytes.
@rodata
final List<u8> argsStrArg = const [
  u8(0x45), u8(0x4C), u8(0x46), u8(0x20), u8(0x41), u8(0x52), u8(0x47), u8(0x20),
];

/// Label.
///
/// `' AT '` -- 4 bytes.
@rodata
final List<u8> argsStrAt = const [
  u8(0x20), u8(0x41), u8(0x54), u8(0x20),
];

/// One space, between an argument's length and its bytes.
///
/// `' '` -- 1 bytes.
@rodata
final List<u8> argsStrSp = const [
  u8(0x20),
];

/// Complete line.
///
/// `'run: too many arguments; this shell passes at most 8, including the program name\n'` -- 81 bytes.
@rodata
final List<u8> argsStrE01 = const [
  u8(0x72), u8(0x75), u8(0x6E), u8(0x3A), u8(0x20), u8(0x74), u8(0x6F), u8(0x6F), u8(0x20), u8(0x6D), u8(0x61), u8(0x6E),
  u8(0x79), u8(0x20), u8(0x61), u8(0x72), u8(0x67), u8(0x75), u8(0x6D), u8(0x65), u8(0x6E), u8(0x74), u8(0x73), u8(0x3B),
  u8(0x20), u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x73), u8(0x68), u8(0x65), u8(0x6C), u8(0x6C), u8(0x20),
  u8(0x70), u8(0x61), u8(0x73), u8(0x73), u8(0x65), u8(0x73), u8(0x20), u8(0x61), u8(0x74), u8(0x20), u8(0x6D), u8(0x6F),
  u8(0x73), u8(0x74), u8(0x20), u8(0x38), u8(0x2C), u8(0x20), u8(0x69), u8(0x6E), u8(0x63), u8(0x6C), u8(0x75), u8(0x64),
  u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67),
  u8(0x72), u8(0x61), u8(0x6D), u8(0x20), u8(0x6E), u8(0x61), u8(0x6D), u8(0x65), u8(0x0A),
];

/// Complete line.
///
/// `'run: argument text too long; at most 128 bytes including one terminator each\n'` -- 77 bytes.
@rodata
final List<u8> argsStrE02 = const [
  u8(0x72), u8(0x75), u8(0x6E), u8(0x3A), u8(0x20), u8(0x61), u8(0x72), u8(0x67), u8(0x75), u8(0x6D), u8(0x65), u8(0x6E),
  u8(0x74), u8(0x20), u8(0x74), u8(0x65), u8(0x78), u8(0x74), u8(0x20), u8(0x74), u8(0x6F), u8(0x6F), u8(0x20), u8(0x6C),
  u8(0x6F), u8(0x6E), u8(0x67), u8(0x3B), u8(0x20), u8(0x61), u8(0x74), u8(0x20), u8(0x6D), u8(0x6F), u8(0x73), u8(0x74),
  u8(0x20), u8(0x31), u8(0x32), u8(0x38), u8(0x20), u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x73), u8(0x20), u8(0x69),
  u8(0x6E), u8(0x63), u8(0x6C), u8(0x75), u8(0x64), u8(0x69), u8(0x6E), u8(0x67), u8(0x20), u8(0x6F), u8(0x6E), u8(0x65),
  u8(0x20), u8(0x74), u8(0x65), u8(0x72), u8(0x6D), u8(0x69), u8(0x6E), u8(0x61), u8(0x74), u8(0x6F), u8(0x72), u8(0x20),
  u8(0x65), u8(0x61), u8(0x63), u8(0x68), u8(0x0A),
];

/// Complete line.
///
/// `'run: an argument holds a byte outside the printable range 0x21..0x7E\n'` -- 69 bytes.
@rodata
final List<u8> argsStrE03 = const [
  u8(0x72), u8(0x75), u8(0x6E), u8(0x3A), u8(0x20), u8(0x61), u8(0x6E), u8(0x20), u8(0x61), u8(0x72), u8(0x67), u8(0x75),
  u8(0x6D), u8(0x65), u8(0x6E), u8(0x74), u8(0x20), u8(0x68), u8(0x6F), u8(0x6C), u8(0x64), u8(0x73), u8(0x20), u8(0x61),
  u8(0x20), u8(0x62), u8(0x79), u8(0x74), u8(0x65), u8(0x20), u8(0x6F), u8(0x75), u8(0x74), u8(0x73), u8(0x69), u8(0x64),
  u8(0x65), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x69), u8(0x6E), u8(0x74), u8(0x61),
  u8(0x62), u8(0x6C), u8(0x65), u8(0x20), u8(0x72), u8(0x61), u8(0x6E), u8(0x67), u8(0x65), u8(0x20), u8(0x30), u8(0x78),
  u8(0x32), u8(0x31), u8(0x2E), u8(0x2E), u8(0x30), u8(0x78), u8(0x37), u8(0x45), u8(0x0A),
];

/// Complete line.
///
/// `'run: no room on the program's one stack page for the arguments it was given\n'` -- 76 bytes.
@rodata
final List<u8> argsStrE04 = const [
  u8(0x72), u8(0x75), u8(0x6E), u8(0x3A), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x72), u8(0x6F), u8(0x6F), u8(0x6D),
  u8(0x20), u8(0x6F), u8(0x6E), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67),
  u8(0x72), u8(0x61), u8(0x6D), u8(0x27), u8(0x73), u8(0x20), u8(0x6F), u8(0x6E), u8(0x65), u8(0x20), u8(0x73), u8(0x74),
  u8(0x61), u8(0x63), u8(0x6B), u8(0x20), u8(0x70), u8(0x61), u8(0x67), u8(0x65), u8(0x20), u8(0x66), u8(0x6F), u8(0x72),
  u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x61), u8(0x72), u8(0x67), u8(0x75), u8(0x6D), u8(0x65), u8(0x6E),
  u8(0x74), u8(0x73), u8(0x20), u8(0x69), u8(0x74), u8(0x20), u8(0x77), u8(0x61), u8(0x73), u8(0x20), u8(0x67), u8(0x69),
  u8(0x76), u8(0x65), u8(0x6E), u8(0x0A),
];



// ---------------------------------------------------------------------------
// The bounds. Both are read back out of this file by
// tests/conformance/m19-argv/run.sh and by the C library's own header.
// ---------------------------------------------------------------------------

/// The most arguments one command line may carry, **argv[0] included**.
///
/// Eight, and the number is here rather than in the shell because it is a
/// property of the operating system's process-creation path: it bounds the
/// pointer array this file writes onto a program's stack, and the C library
/// declares the same number so that a program can say what it will refuse
/// before it is refused.
const int argsMaxCount = 8;

/// The most argument TEXT one command line may carry, in bytes, **including one
/// NUL terminator per argument**.
///
/// 128. `run` plus a space is four bytes and the line editor's buffer is 256,
/// so this is a real bound rather than a restatement of the line length: a
/// command line can be typed that this refuses.
const int argsMaxBytes = 128;

/// Bytes of stack that must remain below the block this file builds, or the
/// build is refused. One quarter of the single stack page.
///
/// A program whose arguments left it 40 bytes of stack would fault on its first
/// `call`, and it would fault at an address that says nothing about why. This
/// turns that into a refusal with a sentence, at the shell, before the program
/// is entered.
const int argsMinStack = 1024;

// ---------------------------------------------------------------------------
// The refusals. Distinct small integers, each with its own sentence.
// ---------------------------------------------------------------------------

/// Accepted.
const int argsErrOk = 0;

/// More than [argsMaxCount] arguments, argv[0] included.
const int argsErrTooMany = 1;

/// More than [argsMaxBytes] bytes of text, terminators included.
const int argsErrTooLong = 2;

/// A byte outside `0x21..0x7E`. The same grammar [fatParseAt] enforces for a
/// name, applied to every argument, so that what reaches a program's `argv` is
/// what a serial capture shows and nothing that is not.
const int argsErrBadByte = 3;

/// The block would not fit on the program's one stack page and leave
/// [argsMinStack] bytes below it. Not reachable with the bounds above -- the
/// worst case is 240 bytes -- and checked anyway, because the bounds and the
/// page size are two numbers in two files.
const int argsErrNoRoom = 4;

// ======================  THE STORAGE SEAM  ======================
//
// `argsStore` is 256 bytes of DCDart `@bss` mutable static, declared here in
// the file that owns it (ADR-0021). THREE functions know where it is and they
// are the three below; do not name `argsStore` anywhere else.
// tests/conformance/m19-argv/run.sh counts exactly three
// `return Bss.addressOf(argsStore)` in this file and zero anywhere else in
// core/kernel/.
//
// Three regions, tiled exactly, and the harness multiplies them out against the
// block's own size:
//
//   [0, 64)     eight metadata words
//   [64, 128)   eight offsets, one per argument
//   [128, 256)  128 bytes of NUL-terminated argument text

/// Metadata words in [argsStore].
const int argsMetaWords = 8;

/// Byte offset of the metadata region. First.
const int argsMetaOffset = 0;

/// Byte offset of the per-argument offset array.
const int argsOffOffset = 64;

/// Byte offset of the argument text.
const int argsTextOffset = 128;

/// The whole block.
const int argsStoreBytes = 256;

/// How many arguments the last [argsCollect] accepted.
const int argsMetaCount = 0;

/// How many bytes of text they occupy, terminators included.
const int argsMetaBytes = 1;

/// The last refusal, or [argsErrOk].
const int argsMetaStatus = 2;

/// The RSP the last [argsBuild] computed, or 0.
const int argsMetaRsp = 3;

/// The virtual address of `argv[0]`'s SLOT -- `RSP + 8` -- or 0.
const int argsMetaVec = 4;

/// The virtual address of the first argument's first byte, or 0.
const int argsMetaText = 5;

/// How many command lines this boot has parsed.
const int argsMetaParses = 6;

/// How many of them it refused.
const int argsMetaRefusals = 7;

/// The 256 bytes this subsystem owns, as a DCDart mutable static.
@bss
final Bss argsStore = const Bss(bytes: argsStoreBytes);

/// The eight metadata words.
@bare
u64 argsMetaBase() {
  return Bss.addressOf(argsStore);
}

/// The eight per-argument offsets.
@bare
u64 argsOffBase() {
  return Bss.addressOf(argsStore) + u64(argsOffOffset);
}

/// The argument text. **No ring-3 pointer ever names this address**: the bytes
/// are COPIED out of here onto the program's stack page and it is that copy
/// `argv` points at.
@bare
u64 argsTextBase() {
  return Bss.addressOf(argsStore) + u64(argsTextOffset);
}

// ======================  END OF THE STORAGE SEAM  ==========================

/// Reads metadata word [i].
@bare
u64 argsMeta(u64 i) {
  return Pointer<u64>.fromAddress(argsMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void argsSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(argsMetaBase() + (i << u64(3))).value = v;
}

/// The text offset of argument [i].
@bare
u64 argsOff(u64 i) {
  return Pointer<u64>.fromAddress(argsOffBase() + (i << u64(3))).value;
}

/// Sets the text offset of argument [i].
@bare
void argsSetOff(u64 i, u64 v) {
  Pointer<u64>.fromAddress(argsOffBase() + (i << u64(3))).value = v;
}

/// How many arguments are staged. 0 before any command line is parsed.
@bare
u64 argsCount() {
  return argsMeta(u64(argsMetaCount));
}

/// The staged bytes, terminators included.
@bare
u64 argsBytes() {
  return argsMeta(u64(argsMetaBytes));
}

/// Empties the staging area. Called at the start of every parse, so a refused
/// command line cannot leave the previous one's arguments behind for the next
/// `run` to pick up.
@bare
void argsReset() {
  argsSetMeta(u64(argsMetaCount), u64(0));
  argsSetMeta(u64(argsMetaBytes), u64(0));
  argsSetMeta(u64(argsMetaStatus), u64(argsErrOk));
  argsSetMeta(u64(argsMetaRsp), u64(0));
  argsSetMeta(u64(argsMetaVec), u64(0));
  argsSetMeta(u64(argsMetaText), u64(0));
  u64 i = u64(0);
  while (i < u64(argsMaxCount)) {
    argsSetOff(i, u64(0));
    i = i + u64(1);
  }
}

/// Copies the [len] bytes at kernel address [addr] in as one more argument.
///
/// Returns a refusal code. **Checks the count and the length BEFORE it writes a
/// byte**, so a refused push leaves the staging area exactly as it found it and
/// the caller can print a sentence and stop.
@bare
u64 argsPush(u64 addr, u64 len) {
  final u64 n = argsMeta(u64(argsMetaCount));
  if (n >= u64(argsMaxCount)) {
    return u64(argsErrTooMany);
  }
  final u64 used = argsMeta(u64(argsMetaBytes));
  if (used + len + u64(1) > u64(argsMaxBytes)) {
    return u64(argsErrTooLong);
  }
  // The grammar, checked before anything is stored. `fatParseAt`'s range, for
  // `fatParseAt`'s reason.
  u64 k = u64(0);
  while (k < len) {
    final u8 c = Pointer<u8>.fromAddress(addr + k).value;
    if (c < u8(0x21)) {
      return u64(argsErrBadByte);
    }
    if (c > u8(0x7E)) {
      return u64(argsErrBadByte);
    }
    k = k + u64(1);
  }
  argsSetOff(n, used);
  k = u64(0);
  while (k < len) {
    Pointer<u8>.fromAddress(argsTextBase() + used + k).value =
        Pointer<u8>.fromAddress(addr + k).value;
    k = k + u64(1);
  }
  Pointer<u8>.fromAddress(argsTextBase() + used + len).value = u8(0x00);
  argsSetMeta(u64(argsMetaBytes), used + len + u64(1));
  argsSetMeta(u64(argsMetaCount), n + u64(1));
  return u64(argsErrOk);
}

/// The index one past the last byte of the token that begins at [from]: the
/// first space at or after [from], or the end of the line.
///
/// **The only tokeniser in this shell**, and it exists because `run` is the
/// only command that has ever needed one. `cat`, `echo` and every other
/// command still take "the rest of the line" and GAP-0057 item 3 is unchanged
/// for them.
@bare
u64 argsTokenEnd(u64 from) {
  final u64 len = shellLen();
  u64 i = from;
  u64 run = u64(1);
  while (run > u64(0)) {
    if (i >= len) {
      run = u64(0);
    } else {
      if (shellLineByte(i) == u8(0x20)) {
        run = u64(0);
      } else {
        i = i + u64(1);
      }
    }
  }
  return i;
}

/// Splits the typed line from byte [from] to the end into arguments and stages
/// them. Returns a refusal code.
///
/// **Runs of spaces are one separator and leading and trailing spaces are not
/// arguments**, so `run WC.ELF   DATA.BIN ` is argc 2 and not argc 4. That is
/// the only tokenising rule there is: no quoting, no escapes, no globbing and
/// no redirection. GAP-0145.
@bare
u64 argsCollect(u64 from) {
  argsReset();
  argsSetMeta(u64(argsMetaParses), argsMeta(u64(argsMetaParses)) + u64(1));
  final u64 len = shellLen();
  u64 i = from;
  while (i < len) {
    // Skip a run of spaces.
    u64 sp = u64(1);
    while (sp > u64(0)) {
      if (i >= len) {
        sp = u64(0);
      } else {
        if (shellLineByte(i) == u8(0x20)) {
          i = i + u64(1);
        } else {
          sp = u64(0);
        }
      }
    }
    if (i < len) {
      final u64 start = i;
      u64 run = u64(1);
      while (run > u64(0)) {
        if (i >= len) {
          run = u64(0);
        } else {
          if (shellLineByte(i) == u8(0x20)) {
            run = u64(0);
          } else {
            i = i + u64(1);
          }
        }
      }
      final u64 st = argsPush(shellLineBase() + start, i - start);
      if (st > u64(argsErrOk)) {
        argsSetMeta(u64(argsMetaStatus), st);
        argsSetMeta(
            u64(argsMetaRefusals), argsMeta(u64(argsMetaRefusals)) + u64(1));
        return st;
      }
    }
  }
  return u64(argsErrOk);
}

/// Builds the initial process stack in the program's stack frame and returns
/// the RSP to enter ring 3 with. Returns 0 if it will not fit.
///
/// [frame] is the PHYSICAL address of the frame mapped at [vmProgStackPage],
/// which is where every byte written here goes; the kernel's identity map
/// covers it and the program's page tables map the same bytes at
/// `[vmProgStackPage, vmProgStackTop)`. **The two addresses of one byte differ
/// by a constant** and `argsPhys` below is the only place that conversion is
/// written down.
///
/// The frame arrives ZEROED (`elfLoad` zeroes it before mapping it), so the
/// padding between the auxiliary vector and the strings, and the bytes above
/// the last string, are zero without this function writing them -- and
/// m19-argv reads them back out of guest memory to prove it.
@bare
u64 argsBuild(u64 frame) {
  final u64 n = argsMeta(u64(argsMetaCount));
  final u64 bytes = argsMeta(u64(argsMetaBytes));

  // The strings sit at the top, 8-aligned down so the vector below them lands
  // on a word boundary before the 16-byte rounding is applied.
  final u64 strVa = (u64(vmProgStackTop) - bytes) & u64(0xFFFFFFFFFFFFFFF8);
  // argc + argc pointers + argv NULL + envp NULL + two AT_NULL words.
  final u64 words = n + u64(5);
  final u64 rsp = (strVa - (words << u64(3))) & u64(0xFFFFFFFFFFFFFFF0);

  if (rsp < u64(vmProgStackPage) + u64(argsMinStack)) {
    argsSetMeta(u64(argsMetaStatus), u64(argsErrNoRoom));
    return u64(0);
  }

  // The strings, copied verbatim: they are already laid out in argv order with
  // one NUL each, so one loop moves all of them and `argv[i]` is `strVa` plus
  // the offset that was recorded when the argument was staged.
  u64 k = u64(0);
  while (k < bytes) {
    Pointer<u8>.fromAddress(argsPhys(frame, strVa + k)).value =
        Pointer<u8>.fromAddress(argsTextBase() + k).value;
    k = k + u64(1);
  }

  // argc.
  Pointer<u64>.fromAddress(argsPhys(frame, rsp)).value = n;
  // argv[0..n-1].
  u64 i = u64(0);
  while (i < n) {
    Pointer<u64>.fromAddress(argsPhys(frame, rsp + u64(8) + (i << u64(3))))
        .value = strVa + argsOff(i);
    i = i + u64(1);
  }
  // argv[n] = NULL, envp[0] = NULL, auxv[0] = {AT_NULL, 0}.
  u64 w = n + u64(1);
  while (w < words) {
    Pointer<u64>.fromAddress(argsPhys(frame, rsp + (w << u64(3)))).value =
        u64(0);
    w = w + u64(1);
  }

  argsSetMeta(u64(argsMetaRsp), rsp);
  argsSetMeta(u64(argsMetaVec), rsp + u64(8));
  argsSetMeta(u64(argsMetaText), strVa);
  return rsp;
}

/// The physical address of the byte a program sees at virtual address [va],
/// given the physical [frame] mapped at [vmProgStackPage].
///
/// **The one place this conversion is written.** Nothing here validates [va]
/// and nothing here needs to: every caller is [argsBuild], which computed the
/// address itself out of `vmProgStackTop` and checked it against
/// `vmProgStackPage`.
@bare
u64 argsPhys(u64 frame, u64 va) {
  return frame + (va - u64(vmProgStackPage));
}

/// Prints what was built: the count, the byte total, and the three addresses,
/// then one line per argument WITH ITS BYTES.
///
/// The bytes are printed because a serial capture that says `ARGS N 03` and
/// nothing else cannot tell a correct vector from a vector of three copies of
/// the same string. m19-argv compares these lines against the command it typed
/// AND, separately, against the pointers it reads out of guest memory.
@bare
void argsReport() {
  final u64 n = argsMeta(u64(argsMetaCount));
  uartWrite(Rodata.addressOf(argsStrArgs), u64(11));
  uartPutHex(n, u64(2));
  uartWrite(Rodata.addressOf(argsStrBytes), u64(7));
  uartPutHex(argsMeta(u64(argsMetaBytes)), u64(4));
  uartWrite(Rodata.addressOf(userStrRsp), u64(5));
  uartPutHex(argsMeta(u64(argsMetaRsp)), u64(16));
  uartWrite(Rodata.addressOf(argsStrVec), u64(5));
  uartPutHex(argsMeta(u64(argsMetaVec)), u64(16));
  uartWrite(Rodata.addressOf(argsStrStr), u64(5));
  uartPutHex(argsMeta(u64(argsMetaText)), u64(16));
  uartNewline();
  u64 i = u64(0);
  while (i < n) {
    final u64 off = argsOff(i);
    u64 len = u64(0);
    while (Pointer<u8>.fromAddress(argsTextBase() + off + len).value >
        u8(0x00)) {
      len = len + u64(1);
    }
    uartWrite(Rodata.addressOf(argsStrArg), u64(8));
    uartPutHex(i, u64(2));
    uartWrite(Rodata.addressOf(argsStrAt), u64(4));
    uartPutHex(argsMeta(u64(argsMetaText)) + off, u64(16));
    uartWrite(Rodata.addressOf(userStrLen), u64(5));
    uartPutHex(len, u64(2));
    uartWrite(Rodata.addressOf(argsStrSp), u64(1));
    uartWrite(argsTextBase() + off, len);
    uartNewline();
    i = i + u64(1);
  }
}

/// One sentence per refusal, and a distinct one for each.
@bare
void argsReportError(u64 code) {
  if (code == u64(argsErrTooMany)) {
    uartWrite(Rodata.addressOf(argsStrE01), u64(81));
    return;
  }
  if (code == u64(argsErrTooLong)) {
    uartWrite(Rodata.addressOf(argsStrE02), u64(77));
    return;
  }
  if (code == u64(argsErrBadByte)) {
    uartWrite(Rodata.addressOf(argsStrE03), u64(69));
    return;
  }
  uartWrite(Rodata.addressOf(argsStrE04), u64(76));
}
