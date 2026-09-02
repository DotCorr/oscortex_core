# The oscortex C library — a roadmap, not yet a decision

**Status:** design. Nothing here is accepted; no ADR number is claimed. Written 2026-08-23 against
`core/user/libc/` at M19, `docs/decisions/0017-a-minimal-c-library.md`, and
`docs/design/display-protocol.md` §5.2.

**Companion document.** `display-protocol.md` §5.2 costed the libc gap from the *display* side and
put one number on it: *"this OS's library exports roughly twenty symbols. A hand-written Wayland
client needs 80–120 … Cairo … 250–350 … GTK 800+."* This document is that paragraph expanded into an
inventory, five tiers, and a recommendation. It **reproduces §5.2's numbers and revises one of them**
— see §2.6.

### The findings, for a reader in a hurry

1. **The library exports 41 symbols and 9 of them are C89 functions.** Measured, not estimated:
   `x86_64-elf-nm` on the six objects built with the harnesses' exact flags. C89 declares about 139
   functions across 15 headers; **8 of them are present and conforming, 1 more is present under the
   right name with the wrong behaviour, and 130 are absent.** All 15 C89 headers are absent *as
   headers*. §1.
2. **There is no software-floating-point problem on this target, and that is measured.** SSE2 is
   enabled in CR4 at boot, `fxsave`/`fxrstor` run on every context switch, and clang compiles
   `double` add/mul/div, `long double`, and every integer↔float conversion to instructions with **no
   library call at all**. The only compiler-rt symbols a float-heavy translation unit needs are
   `__divti3` and `__floattidf` — both `__int128`, neither floating-point arithmetic. "Software
   floating point" is the wrong name for what is missing. §3.1.
3. **What *is* missing is binary↔decimal conversion and a libm**, and DCDart has nothing to donate:
   `dcc` emits integer code only, DCDart's prelude says in as many words that *"DCDart has no
   floating point"*, and `m11-proc` disassembles the whole linked kernel to assert there is not one
   SSE instruction in it. There is no `dtoa`, no `strtod` and no transcendental anywhere in either
   repo. §3.5.
4. **ffmpeg's libc surface is smaller than expected and its kernel surface is enormous.** About
   220–260 distinct libc/libm symbols — the same order as a Cairo client, not an order above it.
   What blocks ffmpeg is not the library. It is a **2 MiB address space, a 4 KiB stack, four file
   descriptors, a 512-byte `read` cap, an append-only write path, no subdirectories and no 64-bit
   file offsets.** §2.4.
5. **The recommendation is: build tiers A and B, port at tier C, and the port is picolibc or newlib
   — never musl.** musl's OS coupling is not in a layer; it is in TLS-based `errno`, futex locks
   inside every `FILE`, and an `mmap`-based allocator. Porting musl means forking musl. newlib and
   picolibc were designed around an OS seam of ~19 stub functions and **this kernel already
   implements 7 of the 19 with matching semantics.** Separately and immediately: **vendor musl's or
   openlibm's libm and float-conversion code file by file** — MIT/ISC, zero OS dependency, the
   highest value-per-line import available anywhere in this project. §5.
6. **One measured change unblocks the whole ladder and costs nothing.** Compiling the library with
   `-ffunction-sections -fdata-sections` and linking with `--gc-sections` takes a printf-only
   program from **4386 bytes of text and 1296 of .bss to 1826 and 128**. More importantly it means
   *adding a file to the library costs a program that does not call it exactly zero bytes* — which
   is the only way to grow this library without moving five harnesses' byte-exact goldens on every
   commit. There is one gotcha and it is measured too: `--gc-sections` deletes `mallocHdrBytes`,
   `printfMax` and `libcFreeEnabled`, the words `derive.py` reads out of the ELF. §6, L1.

---

## 0. What this has to be true of

Everything below is constrained by things this kernel already decided. They are restated here
because a libc roadmap that ignores them is fiction.

| constraint | value | source |
|---|---|---|
| program address space | **2 MiB**, `[0x10000000, 0x10200000)`, fixed, identical for every process | `prog.ld`, ADR-0014 §3 |
| stack | **one 4 KiB page**, at `0x101FF000`, cannot grow | `prog.ld`, ADR-0014 |
| processes | **two**; a third cannot be created | GAP-0101 |
| file descriptors | **four per program** | `fileMaxFds`, `oslibc.h` |
| largest single `read` | **512 bytes** | `fileReadMax` |
| largest single console `write` | **128 bytes**, refused above | `userWriteMax`, `elfOwns` |
| largest single file `fdwrite` | **512 bytes** | `fileWriteMax` |
| file names | **8.3, root directory only**; no path, no subdirectory | `fileNameMax`, GAP-0127 item 9 |
| write mode | **create + truncate + append-only**; no write at an offset, no unlink, no rename | GAP-0127 |
| `seek` | **absolute only**; no `SEEK_CUR`, no `SEEK_END`, no `tell` | GAP-0122 items 3–4 |
| blocking | **nothing blocks and nothing can** | GAP-0097, narrowed at M18 to preemptive-but-not-blocking |
| environment | **none**; `envp[0]` is the NULL terminator | GAP-0146 |
| dynamic linking | **refused by name** in `elf.dart` | GAP-0096 |
| threads, signals, TLS | **none**; `%fs` is whatever the kernel left | GAP-0148 |
| `sbrk` | **monotone, page-granular, cannot shrink** | ADR-0016 §4, GAP-0107 item 1 |
| syscalls | **eleven**, numbers 0–10 | `user.dart`, `proc.dart`, `heap.dart`, `file.dart` |
| SSE2 | **enabled**, `CR4.OSFXSR|OSXMMEXCPT`, 512 bytes saved per switch | ADR-0015 |

And one that is about the *repo* rather than the kernel, and which shapes the ladder more than any
of the above:

**Five conformance harnesses compile `core/user/libc/` from source into their own programs** —
`m13-libc`, `m14-fat`, `m15-fileio`, `m16-filewrite`, `m19-argv` — and every one of them asserts a
byte-exact serial capture. `m13-libc` additionally *derives* all six `malloc` addresses from the
program's `.text` size. **Adding one byte to the library today moves five goldens.** §6 L1 is
entirely about making that stop being true.

---

## 1. An honest inventory

### 1.1 Every exported symbol, measured

Built with the harnesses' exact flags (`-target x86_64-unknown-none-elf -ffreestanding -nostdlib
-fno-pic -fno-pie -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin
-O2 -Wall -Wextra -Werror`) and read with `x86_64-elf-nm -g --defined-only`:

**41 exported symbols: 35 functions (`T`) and 6 read-only words (`R`). 4341 bytes of `.text`,
1288 bytes of `.bss`, across six objects.**

| group | symbols | count |
|---|---|---|
| entry | `_start`, `libcStart` | 2 |
| raw syscall | `sys_call`, `sys_call3` | 2 |
| checked syscall wrappers | `write`, `exit`, `yield`, `who`, `sbrk`, `sbrk_last_error` | 6 |
| file I/O (M15/M16) | `open`, `openmode`, `create`, `read`, `close`, `seek`, `fdwrite` | 7 |
| buffered read (M15) | `rfopen`, `rfread`, `rfgets`, `rftell`, `rfseek`, `rfeof`, `rfclose`, `rf_last_error` | 8 |
| allocator | `malloc`, `free`, `malloc_bytes_from_kernel`, `malloc_free_blocks` | 4 |
| strings | `memcpy`, `memset`, `strlen`, `strcmp`, `strcpy` | 5 |
| output | `printf` | 1 |
| exported constants (`.rodata`) | `mallocHdrBytes`, `mallocAlign`, `mallocMinSplit`, `printfMax`, `libcWriteMax`, `libcFreeEnabled` | 6 |

Classified by *whose name it is*:

* **9 are C89 function names:** `memcpy`, `memset`, `strlen`, `strcmp`, `strcpy`, `malloc`, `free`,
  `printf`, `exit`.
* **7 are POSIX/ABI names:** `_start`, `open`, `read`, `close`, `write`, `seek` (≈ `lseek`), `sbrk`.
* **19 are oscortex's own:** `create`, `fdwrite`, `openmode`, `libcStart`, `who`, `yield`,
  `sys_call`, `sys_call3`, `sbrk_last_error`, the eight `rf*`, `malloc_bytes_from_kernel`,
  `malloc_free_blocks`.

The library also references, but does not define, `main` — which is correct: `start.c` is deliberate
about `main` belonging to the program.

### 1.2 What C89 requires, and how much of it is here

C89 declares roughly **139 functions** (plus `assert`, which is a macro) across **15 headers**.

| C89 header | functions | present here | conforming |
|---|---|---|---|
| `assert.h` | 1 macro | 0 | — |
| `ctype.h` | 13 | 0 | — |
| `errno.h` | 0 (macros) | 0 | — |
| `float.h` | 0 (macros) | **compiler-provided** | ✓ (§1.3) |
| `limits.h` | 0 (macros) | **compiler-provided** | ✓ (§1.3) |
| `locale.h` | 2 | 0 | — |
| `math.h` | 22 | 0 | — |
| `setjmp.h` | 2 | 0 | — |
| `signal.h` | 2 | 0 | — |
| `stdarg.h` | 4 macros | **compiler-provided**, used raw in `printf.c` | ✓ |
| `stddef.h` | 0 (types) | `size_t` + `NULL` re-typedef'd in `oslibc.h`; no `ptrdiff_t`, no `offsetof`, no `wchar_t` | partial |
| `stdio.h` | 41 | **1** (`printf`) | ✗ |
| `stdlib.h` | 26 | **3** (`malloc`, `free`, `exit`) | 2 of 3 |
| `string.h` | 22 | **5** (`memcpy`, `memset`, `strlen`, `strcmp`, `strcpy`) | ✓ |
| `time.h` | 9 | 0 | — |

**The score, stated plainly: 9 of ~139 C89 functions are present by name; 8 of those 9 are
conforming; 130 are absent.**

The eight that conform do so genuinely, including two places where it would have been easy not to:

* `strcmp` compares as `unsigned char`, which C requires and which a plain `char` on this target
  would get wrong for bytes ≥ 0x80. `m13-libc` mutation-tests exactly that.
* `malloc(0)` returns `NULL`, which C89 explicitly permits ("either a null pointer or a unique
  pointer that can be successfully passed to `free`").

The one that does not conform is `printf`, and it does not conform loudly — which is the design, not
a defect. See §1.4.

`exit` is the borderline case and is worth naming: its signature is `void exit(unsigned long)`, not
`void exit(int)`. `exit(1)` and `exit(EXIT_FAILURE)` behave correctly; `exit(-1)` passes
`0xFFFFFFFFFFFFFFFF` where C would pass `-1`. It also runs no `atexit` handlers and flushes nothing
(GAP-0148), which today means nothing because there is nothing to flush, and which becomes a real
bug the day `stdio` has buffers.

### 1.3 The headers — and nine of them are already free

**Measured.** Compiled for this exact target with `-ffreestanding -nostdlib -Wall -Wextra -Werror`,
these headers are **available today, from clang, at zero cost, and nothing in this repo uses them**:

```
stdarg.h  stddef.h  stdint.h  stdbool.h  float.h
limits.h  iso646.h  stdalign.h  stdnoreturn.h  stdatomic.h
```

`uint64_t`, `INT64_MIN`, `bool`, `offsetof`, `max_align_t`, `intptr_t`, `int_fast16_t`, `DBL_MAX`,
`ULLONG_MAX` and the whole C11 atomics API all compile clean and — for atomics — link with **no
undefined symbols at all**. That last one matters at tier D: ffmpeg's `libavutil` wants
`stdatomic.h` and it is already here.

These are the **freestanding** headers, which the standard requires a freestanding implementation to
provide and which the *compiler* provides. Eleven **hosted** headers are absent and are the
library's problem:

```
assert.h  ctype.h  errno.h  locale.h  math.h  setjmp.h
signal.h  stdio.h  stdlib.h  string.h  time.h
```

plus, from C99, `complex.h`, `fenv.h`, `inttypes.h`, `tgmath.h`, `wchar.h`, `wctype.h`.

**The actionable finding:** `oslibc.h` typedefs `size_t` and `uintptr_t` itself rather than including
`stddef.h`/`stdint.h`. Verified to be a compatible redefinition today (the typedefs are identical and
clang accepts it even under `-std=c89 -Werror`), so this is not a bug. It is a **missed
simplification**: `#include <stddef.h>` and `#include <stdint.h>` are free, are correct by
construction, and remove two hand-written typedefs that would silently be wrong the day this target
were not LP64.

### 1.4 The names that are C's names and are not C's functions

This is the part of the inventory a porter has to read. The library uses six C/POSIX names for
functions that do not have C/POSIX semantics. **In four of the six the divergence is a compile
error, which is the good kind:**

| name | oscortex signature | C/POSIX signature | what happens to ported code |
|---|---|---|---|
| `write` | `write(const void*, size_t)` | `write(int, const void*, size_t)` | **compile error** — arity |
| `open` | `open(const char*)` | `open(const char*, int, ...)` | **compile error** — arity |
| `seek` | — | `lseek(int, off_t, int)` | different name; no collision |
| `read` | `read(unsigned long, void*, size_t)` → refusal ≥ floor | `read(int, void*, size_t)` → `-1`/`errno` | **compiles, links, mostly works** |
| `exit` | `exit(unsigned long)` | `exit(int)` | **compiles, links, works** |
| `printf` | 5 conversions, 120-byte cap | ~20 conversions, unbounded | **compiles, links, prints `%!`** |

`read` is the interesting row and the news is good. Every file refusal is at or above
`FILE_ERR_FLOOR` = `0xFFFFFFFFFFFFFF00`, so `(ssize_t)read(...) < 0` is true for **every one of the
thirteen refusals**. Code written against POSIX's `-1` convention detects failure correctly by
accident of the encoding. It cannot then ask *which* failure, because there is no `errno` — but it
does not silently treat a refusal as a byte count, which is the failure that would matter.

`printf` is the row ADR-0017 §5 was written about, and the design works exactly as intended: a
ported library that calls `printf("%5.2f", x)` compiles, links, runs, and prints `%!`. That is a
diff in a serial capture and a five-second diagnosis, not a wrong number. **Nothing in this document
recommends changing that behaviour.** §6 L5 recommends *adding* the conversions, and keeping the
marker for whatever is still unimplemented afterwards.

### 1.5 What `RFILE` is and is not

`rfile.c` is the closest thing here to `stdio`, and its header is careful to say it is not. It is
worth restating as an inventory item because it is a genuine asset:

**Present:** one 512-byte buffer per open file, filled by one `read` syscall, drained by `rfgets` a
line at a time and `rfread` a request at a time; absolute seek that discards the buffer; an EOF flag;
a last-error word. Two of them, in `.bss`, because `sbrk` is refused unless a *process* is live and
`run <name>` does not create one.

**Absent:** writing, `stdin`/`stdout`/`stderr`, a separate error indicator, flushing, `freopen`,
`ungetc`, `setvbuf`, unbuffered mode, `fprintf`, and any use of `malloc`.

The buffering logic in `rfread`/`rfgets`/`rfill` is **directly reusable** as the read half of a real
`FILE`. §4.2 sizes what has to be built around it.

---

## 2. Five tiers

### 2.0 How the counts were arrived at, so they can be argued with

Each count below is **distinct libc/libm symbols referenced by the application and its statically
linked dependencies**. It is not a count of lines, and it is not a count of what a *complete* libc
has. Two consequences worth stating before the numbers:

* **Symbol count is a poor proxy for work.** 70 libm symbols are perhaps 60% of the effort of a
  tier-C libc; 33 `stdio.h` symbols are perhaps 20%; the other 150 are perhaps 20%. §4 sizes the
  expensive ones individually.
* **Symbol count says nothing about the kernel.** Tier D's libc list is barely longer than tier C's
  and tier D is far harder, because the difficulty is in §0's table.

Syscall counts are *additional* syscalls beyond the eleven that exist.

### 2.1 Tier A — self-hosted tools: a shell, `cat`, `ls`, a text editor

**Unlocks:** the machine becomes usable without the ring-0 shell. Programs that read what you type,
list what is on the volume, and save a file back.

**libc: ~90–120 symbols.**

| what | symbols |
|---|---|
| all of `string.h` | 22 |
| all of `ctype.h` | 13 |
| `stdlib.h` core: `atoi`, `strtol`, `strtoul`, `abs`, `qsort`, `bsearch`, `calloc`, `realloc`, `abort`, `atexit`, `getenv` (stub) | ~15 |
| `stdio.h` with a real `FILE`: the 33 that are not `scanf`-family or `tmpfile` | ~33 |
| `errno` + `strerror` + ~25 `E` constants | 2 |
| `assert` | 1 |
| POSIX: `opendir`/`readdir`/`closedir`, `stat`, `unlink`, `rename`, `isatty`, `getcwd`, `chdir`, `spawn`/`wait` | ~12 |
| `setjmp`/`longjmp` (an editor wants it for its error path) | 2 |

**Syscalls: +8 → 19.** Console input (the largest single item — and it needs a scheduler that can
block, GAP-0097); directory enumeration; `unlink`; `rename`; `stat`/size; a write path that can seek
(today `O_WRITE` is create+truncate+append-only, so an editor **cannot save over a file** — it can
only write a new one); `spawn`; `wait`.

**Kernel growth beyond syscalls:** 4 → 16 descriptors; 2 → 8+ processes; a stack that can be more
than one page (an editor's undo stack, a recursive-descent config parser); 8.3 root-only names →
paths and subdirectories, or the shell can never `cd`.

**Honest note.** A text editor also needs a *raw* terminal — no line discipline, no echo — and this
kernel's keyboard belongs to the ring-0 shell entirely. That is a bigger decision than a syscall:
it is deciding who owns the console.

### 2.2 Tier B — a C compiler running ON the OS

**Unlocks:** self-hosting. The OS can build a program without a macOS host in the loop. This is the
tier that changes what the project *is*.

Target should be **chibicc** (~9k lines, no dependencies, generates x86-64 assembly and shells out
to `as`/`ld`) or **tcc** (~60k lines, includes its own assembler *and* linker, so it needs no
`exec`).

**libc: ~120–150 symbols.** Tier A plus:

| what | symbols |
|---|---|
| `stdio.h` completed: `tmpfile`, `fscanf`/`sscanf` family, `setvbuf`, `ungetc`, `fgetpos`/`fsetpos` | ~10 |
| `stdlib.h` completed: `strtod` (a C compiler must parse floating literals), `strtoll`, `strtoull`, `system` (chibicc only), `mkstemp` | ~6 |
| `time.h`: `time`, `localtime`, `strftime` — `__DATE__`/`__TIME__` | 3 |
| `math.h`: only for constant folding; `strtod` is the real requirement | 0–5 |

**Syscalls: +2 → 21** (`getcwd`, `chdir`), **and only if tcc is the target**. chibicc needs `exec` +
`wait`, which tier A already bought.

**The real cost is not the libc.** It is: paths and subdirectories (`#include <sys/types.h>` needs a
directory tree); 32 descriptors (a compiler with 20 nested includes open); several MiB of address
space (tcc's own working set is a few MiB before it compiles anything); an archiver (`ar`) or a
compiler that emits one object; and a linker that can read the objects the compiler emits. **Tier B
is an ELF-and-filesystem milestone wearing a libc costume**, and the honest ordering is that tier B
should be attempted *after* the address space is fixed, not before.

**`strtod` is the first hard floating-point requirement in the ladder** and it arrives here, one
tier earlier than most people expect. §3.3.

### 2.3 Tier C — a Cairo-class graphics client

**Unlocks:** the display protocol has a client worth having. Vector graphics, text, anti-aliasing —
the difference between "pixels reach the screen" and "an application."

Cairo + pixman, statically, with `CAIRO_NO_MUTEX`, image backend only, no fontconfig, no freetype
(or freetype, which adds ~15 symbols and a lot of `stat`).

**libc: ~200–260 symbols.** Tier B plus:

| what | symbols |
|---|---|
| **libm, double:** `sqrt`, `pow`, `fabs`, `floor`, `ceil`, `round`, `trunc`, `fmod`, `fmin`, `fmax`, `hypot`, `atan2`, `atan`, `asin`, `acos`, `sin`, `cos`, `tan`, `exp`, `log`, `log2`, `log10`, `ldexp`, `frexp`, `modf`, `copysign`, `isnan`, `isinf`, `isfinite` | ~30 |
| **libm, float variants** of most of the above | ~25 |
| `printf` with `%f`, `%e`, `%g`, `%a`, widths, flags, precision; `snprintf`, `vsnprintf`, `asprintf` | ~8 (but see §3.3 — this is the expensive row) |
| `locale.h`: `setlocale`, `localeconv` — Cairo formats numbers | 2 |
| `qsort_r`, `memmove` if not already | 2 |

**Syscalls: +2 → 23.** A multi-handle `wait` with a monotonic timeout (`display-protocol.md` §5.3
item 2 argues for it on native grounds independently) and a monotonic clock. The display transport
itself needs **zero** new syscalls — that is `display-protocol.md` §2's revised design, and it holds.

**The blocker is not the libc.** Cairo + pixman is roughly **700 KiB–1.2 MiB of `.text`** at `-O2`,
before the application. The program window is 2 MiB *total*, including heap and a 4 KiB stack. Cairo
also recurses in its path tessellation. **Tier C requires the address space and the stack to be
redesigned. There is no version of this tier that does not.**

### 2.4 Tier D — ffmpeg

**Unlocks:** the owner's stated goal.

Assume the smallest useful build: `--disable-everything --disable-network --disable-pthreads
--disable-iconv --disable-zlib --enable-decoder=… --enable-demuxer=…`, static, no filters.

**libc: ~220–260 symbols.** The breakdown, by header:

| header | symbols ffmpeg references | notes |
|---|---|---|
| `string.h` | ~23 | plus POSIX `strdup`, `strndup`, `strcasecmp`, `strncasecmp`, `strtok_r` |
| `stdlib.h` | ~23 | including `posix_memalign` **or** `memalign` **or** `aligned_alloc` — see below |
| `stdio.h` | ~33 | including `fseeko`/`ftello` with **64-bit offsets**, `setvbuf`, `snprintf`, `vsnprintf`, `sscanf` |
| `ctype.h` | ~10 | |
| `math.h` double | ~42 | |
| `math.h` float | ~26 | ffmpeg's audio codecs are float-heavy: `expf`, `logf`, `powf`, `sinf`, `cosf`, `sqrtf`, `fabsf`, `floorf`, `atan2f` |
| `time.h` | ~11 | `time`, `gmtime(_r)`, `localtime(_r)`, `mktime`, `strftime`, `clock_gettime`, `gettimeofday` |
| `errno.h` | ~35 constants + `strerror` | `av_strerror` maps `errno` values it recognises |
| `locale.h` | 2 | C-locale stub is sufficient |
| `assert.h` | 1 | |
| POSIX file/process | ~15 | `open`, `close`, `read`, `write`, `lseek` (64-bit), `access`, `unlink`, `stat`, `fstat`, `isatty`, `usleep`, `nanosleep`, `getpid` |
| `stdatomic.h` | — | **already available**, §1.3 |
| `setjmp.h` | 2 | only if libpng/libjpeg are in the build; ffmpeg's native decoders do not need it |

**A gift worth knowing about:** `libavutil/libm.h` ships ffmpeg's *own* implementations of about 25
math functions (`cbrt`, `copysign`, `cosh`, `erf`, `exp2`, `hypot`, `isinf`, `isnan`, `ldexpf`,
`llrint`, `log2`, `log10f`, `lrint`, `rint`, `round`, `sinh`, `trunc`, and the `f` variants) that
compile in when `configure` reports them missing. That removes roughly **25 of the 68 libm symbols**
from the critical path, leaving the ~43 that genuinely have to exist. `compat/` similarly supplies
`strtod` and `va_copy` fallbacks.

**Syscalls: +5 → 28.** 64-bit offsets on the existing calls (widening, not new); an anonymous
page-granular memory object or a real `mmap`; `usleep`/`nanosleep`; a wall clock (an RTC driver
behind one syscall); pipes, if `ffmpeg -i -` is ever wanted.

**And now the honest part, which is the whole reason this tier is hard.**

| ffmpeg needs | this kernel has | gap |
|---|---|---|
| 20–60 MiB working set (a 1080p yuv420p frame is 3.1 MiB; a decoder holds several reference frames) | **2 MiB total per process** | **10–30×**, and it is a hard wall |
| 1.5–3 MiB of `.text` for even a minimal build; 10–20 MiB for a general one | 2 MiB *including* heap and stack | **the binary does not fit in the address space** |
| ≥ 256 KiB of stack; several codecs put large arrays in stack frames | **4 KiB, one page, cannot grow** | **60×** |
| 32 KiB read blocks | **512-byte `READ_MAX`** | **64× syscall amplification** |
| 64-bit file offsets; files > 4 GiB | `unsigned long` offsets, FAT16 volume | widening + a filesystem decision |
| `fseek` on a file being written; write at an offset | **append-only** `O_WRITE` | muxing is impossible without it — every container rewrites its header at the end |
| ≥ 16 descriptors | **4** | input, output, and an index is already 3 |
| paths, subdirectories, long names | **8.3, root only** | `-i /media/clip.mkv` cannot be expressed |
| 32- or 64-byte-aligned allocations for SIMD | **16-byte `malloc`** | AVX2 loads misalign; ffmpeg's fallback over-allocates |
| `av_malloc` of tens of MiB | `sbrk` inside a 2 MiB window | see row 1 |

**The single-sentence conclusion of this tier:** *ffmpeg is not blocked on the C library. It is
blocked on the address space, the stack, the write path and the filesystem, and the C library is the
part that can be honestly estimated.* A libc good enough for ffmpeg is perhaps four milestones of
work. A kernel good enough for ffmpeg is a different operating system from the one in §0's table.

### 2.5 Tier E — anything GTK-class

**Unlocks:** nothing this project should want.

**libc: 700–900 symbols**, matching `display-protocol.md` §5.2's "800+", **plus** a dynamic linker,
**plus** threads with futexes and TLS, **plus** Unix domain sockets, **plus** `poll`/`epoll`,
**plus** `mmap` with `MAP_SHARED`, **plus** real signals, **plus** `iconv` and a multibyte locale
(gettext), **plus** `inotify` if you want theme reloading to work.

**Syscalls: +20 → ~48.** `mmap`/`munmap`/`mprotect`/`madvise`; `clone`/`futex`/`set_tid_address`/
`arch_prctl`; `socket`/`bind`/`connect`/`sendmsg`/`recvmsg`/`socketpair` with **`SCM_RIGHTS`**;
`poll`/`epoll_*`; `rt_sigaction`/`rt_sigprocmask`/`rt_sigreturn`/`kill`; `openat`/`getdents64`/
`statx`; `clock_gettime` as a vDSO.

`display-protocol.md` §5.2 already ruled on this and its ruling stands: **that is not a libc port, it
is a Linux personality.** This tier is listed so nobody costs it twice, and the recommendation is to
never attempt it. If Linux binaries are ever wanted, the correct project is a Linux syscall
emulation layer with a real `glibc` underneath — a different, larger, and honestly-named thing.

### 2.6 The tiers in one table

| tier | libc symbols | new syscalls | total syscalls | the thing that actually blocks it |
|---|---|---|---|---|
| **today** | **41** (9 C89) | — | 11 | — |
| **A** shell, `cat`, `ls`, editor | ~90–120 | +8 | 19 | console input, and a scheduler that can block |
| **B** a C compiler on the OS | ~120–150 | +2 | 21 | subdirectories, an archiver, address space |
| **C** a Cairo client | ~200–260 | +2 | 23 | **address space** (1 MiB of `.text` in a 2 MiB window) and libm |
| **D** ffmpeg | ~220–260 | +5 | 28 | **address space, 4 KiB stack, append-only writes, 512-byte reads** |
| **E** GTK-class | 700–900 | +20 | ~48 | a dynamic linker, threads, sockets — *do not attempt* |

**This revises `display-protocol.md` §5.2 in one place, and the revision is good news.** §5.2 put
Cairo at 250–350 and implied ffmpeg would be worse. Counting distinct referenced symbols by the same
method for both, **ffmpeg lands beside Cairo rather than above it** — about 220–260 against about
200–260 — because ffmpeg's `libavutil/libm.h` and `compat/` supply a real fraction of what it would
otherwise need, and because ffmpeg has no toolkit, no theming and no text shaping. §5.2's headline
sentence should therefore read: *the gap between "no client" and "a Cairo client" is one order of
magnitude of libc; ffmpeg is on the same step as Cairo; GTK is another order up and is a
distribution.*

---

## 3. The floating point problem

### 3.1 There is no software-floating-point problem, and that is measured

The premise in the brief — "software floating point plus a libm" — contains an assumption worth
dismantling before anything is costed, because dismantling it removes what most people assume is the
largest item.

**Measured**, compiling a translation unit of `double`, `float`, `long double` and `__int128`
arithmetic for `x86_64-unknown-none-elf` at `-O2` with the harnesses' flags, and reading the
undefined symbols out of the object:

```
U __divti3          __int128 division
U __floattidf       __int128 -> double
U sqrt              only because -fno-builtin is on; see below
```

**That is the entire list.** `a+b`, `a*b`, `a/b` in `double` and `float`; `(double)(uint64_t)x`;
`(uint64_t)(double)x`; `long double` multiply; `double`←`long double` — **every one compiles to
instructions with no library call.** There is no `__adddf3`, no `__muldf3`, no `__floatundidf`, no
`__truncdfsf2`. On x86-64 with SSE2 the compiler-rt floating-point surface is essentially empty, and
the two symbols that do appear are 128-bit *integer* helpers that have nothing to do with floating
point.

And with `-fno-math-errno` added, the undefined list shrinks to two: `dsqrt` compiles to a single
`sqrtsd %xmm0, %xmm0`. `sqrt` only appears as a call because `-fno-builtin` forbids clang from
knowing what `sqrt` means.

**Why this works, and it is this kernel's own doing.** `core/boot/boot.S` probes CPUID leaf 1 for
FXSR and SSE and sets `CR4.OSFXSR | CR4.OSXMMEXCPT` when both are present; `proc.dart` allocates 512
bytes of `fxsave` area per process, restores it on every switch, and initialises a fresh one to
control word `0x037F` and MXCSR `0x1F80`; `m11-proc/build-progs.sh` asserts that a ring-3 function
containing no inline assembly *does* contain an `%xmm` register, and `m11-proc/run.sh` runs a
negative control on `-cpu qemu64,-sse,-fxsr` where `proc run` must refuse by name. ADR-0015 is the
argument and it was already made.

**So the correct statement of the problem is:** the arithmetic works today. Three *other* things do
not, and they are routinely conflated with it.

### 3.2 The three things "floating point support" actually means

| | what it is | is it needed for arithmetic? | cost |
|---|---|---|---|
| **1. soft-float** | `__adddf3` etc. — emulating FP in integer ops | **no, and it is not needed at all here** | **zero** |
| **2. binary↔decimal** | `printf %f/%e/%g/%a`, `strtod`, `snprintf` | no — but nothing can be *printed or parsed* without it | **the hard one** — §3.3 |
| **3. libm** | `sin`, `exp`, `pow`, `log`, `atan2`, … | no — but no real program avoids them | **the bulky one** — §3.4 |

Item 1 being free is the single largest cost reduction available in this whole document. It also
means `__int128` is the only compiler-rt need, and `__divti3` + `__floattidf` are about 200 lines
each from compiler-rt (MIT/Apache-2.0-with-LLVM-exception) or 100 lines each written by hand.

### 3.3 What binary↔decimal costs, and why it is the hard one

This is the item that people underestimate, and the reason to state it separately from libm is that
**it is small in symbol count and large in difficulty**. Six symbols — `printf`'s float path,
`snprintf`, `vsnprintf`, `strtod`, `strtof`, `strtold` — and they are the subtlest code in any C
library.

The requirement is not "print some digits." It is:

* **Round-trip:** `strtod(printf("%.17g", x))` must return `x` bitwise, for every finite double.
* **Correct rounding:** `%.*f` must round the *exact* binary value to the requested number of
  decimal digits, which for a small double can mean producing up to **767 significant decimal
  digits** and rounding at the right one. Doing this with `double` arithmetic is wrong; it needs
  either extended precision or bignum.
* **Subnormals, ±0, ±inf, NaN, and the `%a` hex form.**

| approach | lines | licence | notes |
|---|---|---|---|
| **musl's `vfprintf` float path + `__floatscan`/`strtod`** | ~900 | **MIT** | uses `long double` (x87, which works here) and a 32-bit-limb bignum loop; correct for every case; this is the recommended import |
| **David Gay's `dtoa.c` + `strtod.c`** | ~3400 | permissive (author's own) | the classic; correct; needs configuration macros and is unpleasant to read |
| **Ryū (`d2s`/`s2d`)** | ~1000 + ~10 KiB tables | **Apache-2.0/Boost** | shortest round-trip, very fast; does **not** by itself do `%.*f` with arbitrary precision — you still need a fallback path |
| **Grisu3 + fallback** | ~800 + fallback | BSD | same caveat as Ryū |
| **write it from scratch** | 1200–2000 | — | **do not.** This is the one place in a libc where a subtle bug is invisible until it corrupts data |

**Recommendation: import musl's float-conversion code.** It is MIT, it is self-contained
computation with no OS dependency of any kind, it uses `long double` which this target has in
hardware, and it is the smallest correct thing available. Writing this by hand is the single worst
build-versus-port trade in the whole library.

**Note that `strtod` arrives at tier B**, not tier C: a C compiler running on this OS must parse
floating literals in the source it compiles.

### 3.4 What a libm costs

~43 double functions plus ~26 float variants after ffmpeg's own `libm.h` fallbacks are subtracted;
~55 double plus ~30 float for a general-purpose libm.

| source | lines | licence | fit for this target |
|---|---|---|---|
| **musl libm** | ~15 k across ~450 files | **MIT** | derived from FreeBSD's `msun`; correctly rounded for the common functions; no OS dependency; `x86_64` has hand-written `sqrt`/`fabs`/`rint` that use SSE directly. **Best fit.** |
| **openlibm** | ~30 k | ISC/MIT/BSD mix | the Julia project's fork of `msun`, actively maintained, builds standalone; also a good fit |
| **FDLIBM / Sun** | ~12 k | Sun's permissive licence | the ancestor of all of the above; dated but correct |
| **newlib's libm** | ~40 k | BSD family | comes free if newlib is the chosen port (§5.3) |
| **write it** | 6–10 k for the ffmpeg subset | — | **do not.** `sin` for large arguments needs a 1150-bit π for argument reduction; `pow` needs extended-precision intermediate results; the edge cases are subnormals, ±inf, NaN and the exact-halfway rounding cases, and there is no way to be confident without a reference implementation to differential-test against — at which point you have imported one anyway |

**Recommendation: import, do not write.** libm is 15 000 lines of pure computation with zero OS
dependency, under a licence with no obligations beyond attribution, and every alternative to
importing it is worse. This is not a close call.

**A cheap and correct optimisation this target permits:** `sqrt`, `fabs`, `copysign`, `floor`,
`ceil`, `trunc`, `rint`, `round`, `fmin`, `fmax`, `nearbyint` and the `isnan`/`isinf`/`signbit`
predicates are all **one or two SSE2 instructions** (`sqrtsd`, `andpd`, `roundsd` with SSE4.1, or
bit manipulation). Roughly 15 of the ~43 required double functions are one-liners on this
architecture. Only the transcendentals genuinely need importing.

### 3.5 Does DCDart's runtime have anything reusable? No, and here is the evidence

**It does not, and the evidence is unambiguous.**

* DCDart's own prelude (`core/runtime/dc-core-bare/prelude.dart`) says it twice, in comments
  explaining why `~/` is the only division operator: *"plain `/` in Dart returns a `double`, and
  **DCDart has no floating point**, so `~/` is the honest spelling."*
* ADR-0015 §2: *"`dcc` emits integer code only, and every line of assembly in this repo is
  hand-written."*
* `m11-proc/run.sh` **disassembles the entire linked kernel** and asserts it contains no SSE
  instruction — that assertion is what makes M11's "the kernel enabled SSE for ring 3, not for
  itself" claim testable.
* The kernel's own number formatting is `uartPutHex`/`uartPutNibble` — integer, hexadecimal,
  uppercase. There is no decimal formatter in the kernel at all, let alone a decimal *float*
  formatter.
* The whole DCDart runtime is **one file**, `prelude.dart`, and it is extension types over `int`.

So: **no `dtoa`, no `strtod`, no soft-float, no transcendental, and no `double` type** anywhere in
either repository. The search is complete and the answer is nothing.

**What *is* reusable from the DCDart side is the enablement, and it is already done and tested:** the
CR4 probe and the reserved-bit hazard around it, the 512-byte `fxsave` area, the initial FPU image
(`0x037F` / `0x1F80`), the eager save/restore, and the negative control that proves a no-SSE CPU is
refused rather than crashed. That is the kernel half of floating point and M11 shipped it. The
userland half owes DCDart nothing and can take nothing from it.

**One consequence worth flagging to the DCDart side rather than solving here.** If the kernel ever
wants to print a float — a frame time, a fill rate, a bitrate — it cannot, and adding one would mean
either giving DCDart a floating-point type (a language change, CLAUDE.md rule 3: escalate, do not
work around) or formatting in userland. **Format in userland.** The kernel does not need floats and
this document recommends it never gets them.

---

## 4. The big ones, sized

### 4.1 `malloc` — it exists, and here is exactly how good it is

**What it is:** a first-fit free list over `sbrk` with splitting and address-ordered coalescing, in
187 lines. `free` is a real `free`; a freed block comes back from the next fitting `malloc` at the
same address; two freed neighbours merge. `m13-libc` *measures* all three at runtime against a
second build with `free()` disabled, and requires the real build's checks to **fail** against the
control. The header size, alignment and minimum split are `volatile const` words read out of the ELF
so the harness's arithmetic cannot disagree with the code.

**As allocators go, this is a good small one.** The coalescing is exact (`end == start`, in bytes,
so two free blocks with one byte between them are not merged into one that claims a byte it does not
own), the overflow guard is placed before the round-up rather than after, and the negative control
is a second build of the same source rather than an `#ifdef`. It is better engineered than most
teaching allocators.

**Where it stops being good enough, by tier:**

| limitation | bites at | why |
|---|---|---|
| **O(free blocks) per `malloc`**, linear from the head | **tier C** | Cairo allocates and frees thousands of small objects per frame; the free list grows to thousands of entries; every allocation walks all of them. This is quadratic behaviour in a render loop. |
| **no `realloc`, no `calloc`** | **tier A** | `realloc` is the single most-used allocator function in ported C after `malloc`. Both are ~15 lines on top of what exists. GAP-0111 item 2 declined to add an untested `realloc`; the answer is to add it *with* a test |
| **16-byte alignment only, no `aligned_alloc`/`posix_memalign`** | **tier D** | ffmpeg's `av_malloc` wants 32 or 64 bytes for AVX/AVX-512 loads. Its fallback over-allocates and aligns by hand, which works and wastes memory this OS does not have |
| **never returns memory to the kernel** | **tier D** | GAP-0111 item 1. In a 2 MiB window, peak footprint *is* footprint. A decoder that peaks at 1.8 MiB holds 1.8 MiB forever |
| **no double-free detection, no canary, no consistency check** | **tier B** | a compiler running on the OS will have allocator bugs and there will be no diagnostic; the symptom will be a corrupted free list several thousand instructions later |
| **not thread-safe** | tier E | costs nothing until there are threads, then costs everything |

**Sizing the fix.** `realloc` + `calloc` + `aligned_alloc`: **~60 lines**, one milestone-day, and it
is the highest-value allocator work available. Replacing first-fit with segregated free lists (size
classes for ≤ 512 bytes, first-fit above): **~250 lines**, and it converts the tier-C quadratic into
constant time. Both are cheap. Neither is urgent before tier C.

**What must not be done:** replacing this allocator with an imported one (dlmalloc, mimalloc,
musl's mallocng). All three assume `mmap`. mallocng in particular *requires* it — it has no
`sbrk`-only mode. §5.2.

### 4.2 `stdio` with buffering and `FILE`

**The biggest single item in the library, and about half of it already exists.**

**What has to be built:**

| part | lines | notes |
|---|---|---|
| `struct FILE` + the three standard streams | ~150 | buffer, mode, position, EOF flag, **separate** error flag, `ungetc` slot, buffering mode. `stdin` needs a console-input syscall to exist at all |
| read path | ~150 | **`rfile.c`'s `rfill`/`rfread`/`rfgets` are directly reusable** — this is the half that is done |
| write path with buffering and flushing | ~250 | line-buffered when `isatty`, block-buffered otherwise, unbuffered on request. Flush on `exit`, which means `exit` must learn to run handlers (GAP-0148) |
| positioning: `fseek`/`ftell`/`fseeko`/`ftello`/`rewind`/`fgetpos`/`fsetpos` | ~150 | needs `SEEK_CUR` and `SEEK_END`, which the kernel does not have (GAP-0122 items 3–4) — `SEEK_END` in particular needs a way to ask a file's size, which no syscall provides |
| the `printf` engine: widths, flags, precision, length modifiers, `%u`, `%o`, `%p`, `%n` | ~400 | integer path only |
| the `printf` float path | ~500 | §3.3 — **import** |
| the `scanf` engine | ~400 | tier B onwards; ffmpeg uses `sscanf` |
| `perror`, `clearerr`, `feof`, `ferror`, `setvbuf`, `tmpfile`, `remove`, `rename` | ~150 | `remove`/`rename` need kernel support that does not exist (GAP-0127 items 7–8) |

**Total: ~2100 lines, of which ~500 should be imported.** Call it three milestones.

**Two decisions that must be taken at the start of this work, not during it:**

1. **`FILE` must be an opaque struct behind a pointer**, with the fields reached only through
   accessor functions inside the library, so that adding a lock word later does not change its size
   and break every compiled program. musl and newlib both learned this the expensive way.
2. **`printf` must not lose its `%!` marker.** ADR-0017 §5's argument is correct and survives
   every tier: whatever is *still* unimplemented after L5 must announce itself. The marker moves
   from "everything but five" to "everything but the twenty that work," and it stays.

**And one repo constraint:** `m13-libc/run.sh` reads the implemented conversion set out of
`printf.c` with `re.findall(r"k == '(.)'", body)` and requires it to be **exactly** the five, with a
marking `else` that consumes no argument. Any `printf` growth rewrites that check. That is correct
behaviour by the harness and it must be *rewritten*, not deleted.

### 4.3 `errno` and its threading implications

**The code is trivial. The ABI decision is not, and it must be taken before the first line.**

Today there is no `errno` and GAP-0122 item 6 argues it is a choice: every call returns its own
refusal, all of them at or above one floor, so a caller separates an answer from a refusal with one
comparison. **That design is better than `errno` and this document recommends keeping it as the
library's internal convention forever.** `errno` is a *compatibility shim* for ported code, not a
replacement for the refusal floor.

**The decision to take now:**

```c
/* WRONG, and it is wrong the day threads exist rather than today. */
extern int errno;

/* RIGHT, and it costs one indirection today. */
int *__errno_location(void);
#define errno (*__errno_location())
```

With `extern int errno`, every object compiled against the header **references the symbol directly**,
and the day threads arrive every one of them must be recompiled — including any third-party library
already built and archived. With `__errno_location()`, the day threads arrive is the day
`__errno_location` starts reading `%fs:offset` instead of returning `&global` — **one function
changes and nothing is recompiled.** glibc and musl both settled on this and both got there by
making the mistake first.

**Sizing:** the mechanism is ~20 lines. The work is the ~40 `E`-constant definitions and the
**mapping table from this kernel's thirteen file refusals and three `sbrk` refusals to POSIX
`errno` values**, which is ~60 lines and is a real design task:

| refusal | plausible `errno` |
|---|---|
| `FILE_EBADFD` | `EBADF` |
| `FILE_EBADPTR` | `EFAULT` |
| `FILE_EBADLEN` | `EINVAL` |
| `FILE_ENOSLOT` | `EMFILE` |
| `FILE_EBADNAME` | `ENAMETOOLONG` or `EINVAL` |
| `FILE_ENOTFOUND` | `ENOENT` |
| `FILE_EISDIR` | `EISDIR` |
| `FILE_EEMPTY` | *no POSIX equivalent* — an empty entry is a 0-byte read, not an error |
| `FILE_EIO` | `EIO` |
| `FILE_EBADSEEK` | `EINVAL` |
| `FILE_ENOOWNER` | `EBADF`? — **no honest mapping**; nothing that owns descriptors is running |
| `FILE_EBADMODE` | `EBADF` (POSIX's answer for a write to a read-only fd) |
| `FILE_ENOSPACE` | `ENOSPC` |
| `SBRK_ENOMEM` | `ENOMEM` |
| `SBRK_ENOSPACE` | `ENOMEM` |
| `SBRK_EBADARG` | `EINVAL` |

**Two of the sixteen have no honest mapping**, and the correct handling is to give them an
oscortex-specific value above the POSIX range and let `strerror` name them properly, rather than
flattening them into `EIO` and throwing away the diagnostic ADR-0016 §1 went out of its way to
create.

**Threading implications, stated once:** there are no threads (GAP-0148, no TLS, no `%fs` base).
Everything above is about making the day threads arrive cost one function instead of a rebuild. It
is 20 lines of foresight and this document recommends taking it.

### 4.4 `locale`

**Cheap if you decide "C" is the only locale, and this document recommends deciding that.**

`setlocale(LC_ALL, "C")` returning `"C"` and refusing everything else, plus a static `struct lconv`
with `'.'` as the decimal point: **~60 lines.** `strcoll` = `strcmp`, `strxfrm` = `strcpy`.
`localeconv` returns a pointer to the one struct.

That is sufficient for tiers A through D. ffmpeg is locale-sensitive in exactly one place —
`strtod`'s decimal separator, which is why it ships `av_strtod` — and the C locale is what it wants.

**What "real" locale costs, so nobody is surprised at tier E:** a locale database on disk, `mmap` to
read it, `nl_langinfo`, `iconv` with charset conversion tables, multibyte `mbrtowc`/`wcrtomb`, the
entire `wchar.h` and `wctype.h` headers (~80 symbols), and `gettext`. **~5000 lines plus a data
format.** This is one of the several reasons tier E is not a libc project.

### 4.5 `time`

**Splits cleanly into a free half and a kernel half, and the free half is genuinely free.**

**Pure arithmetic, no kernel involvement, ~400 lines:** `gmtime`, `gmtime_r`, `mktime`, `timegm`,
`difftime`, `asctime`, `ctime`, `strftime`. The civil-calendar conversions are well-understood
closed-form arithmetic (Howard Hinnant's `days_from_civil`/`civil_from_days` are about 20 lines each
and are correct for the whole proleptic Gregorian range). `localtime` is `gmtime` while there is no
timezone database, which there should not be.

**`CLOCK_MONOTONIC`: thin, and `display-protocol.md` §5.2 already said so.** The kernel has a PIT
tick counter (`tick_count`); a monotonic clock is arithmetic over it plus one syscall. **~40 lines
of kernel, 1 syscall.** Worth doing early — it is also what the multi-handle `wait` timeout in
`display-protocol.md` §5.3 item 2 needs.

**Wall clock: a driver.** `time()` needs a real date, which means reading the CMOS RTC at ports
`0x70`/`0x71`, handling the update-in-progress flag, decoding BCD-or-binary and 12-or-24-hour per
register B, and converting to a Unix epoch. **~150 lines of kernel, 1 syscall**, and it is a
well-trodden path. Needed at tier D for container metadata timestamps; not needed before.

**`clock()` / `getrusage`:** per-process CPU time. The scheduler already counts preempts per slot
(M18 added two per-slot counters); accumulating ticks-in-slot is a small extension of state that
already exists.

### 4.6 Signals

**The most expensive item in this document per unit of benefit, and the recommendation is to stub
them until tier D and then think hard.**

**What a real `signal.h` costs the kernel:**

1. A per-process pending mask and a blocked mask — new process state.
2. A per-process disposition table (handler, mask, flags) — 64 entries.
3. **Signal frame construction:** on delivery, push a `sigcontext` (the full interrupted register
   state, including the 512-byte FPU area) onto the *user* stack, redirect RIP to the handler, and
   arrange for its return to enter the kernel. **This does not fit in a 4 KiB stack** — a
   `sigcontext` with FPU state is over 600 bytes and a handler that itself uses the stack needs
   more.
4. **A `sigreturn` syscall** that validates the frame it is handed — a ring-3 pointer into a
   structure that dictates the register state to restore is an obvious privilege-escalation surface,
   and validating it properly is most of the security work in this feature.
5. **`EINTR`:** a syscall interrupted by a signal must return partial progress, which requires
   syscalls that can be interrupted, which requires syscalls that can **block**, which is GAP-0097
   again and is upstream of everything.
6. `sigaction`, `sigprocmask`, `sigsuspend`, `kill`, `raise`, `sigaltstack`, `sigreturn`,
   `alarm`/`setitimer` — **~6 syscalls** and perhaps **800 lines of kernel**.

**What the tiers actually need:**

* Tiers A–C: **nothing.** A `signal()` that records the disposition and never delivers is ~30 lines
  and satisfies every `signal(SIGPIPE, SIG_IGN)` in ported code.
* Tier D: the ffmpeg **CLI** installs `SIGINT`/`SIGTERM` handlers so that Ctrl-C finishes the output
  file cleanly. The ffmpeg **libraries** need nothing. So even at tier D the requirement is not
  "signals" — it is "Ctrl-C can reach a running program," which a console-input path plus a
  cooperative "please stop" flag satisfies at a fraction of the cost.
* Tier E: real signals, no way around it.

**Recommendation:** stub `signal`/`raise` at L8, and do not build real signals until something
demands them that is not solvable with a cancellation flag. If they are ever built, they are a
kernel milestone with their own ADR, not a libc milestone.

### 4.7 `setjmp` / `longjmp`

**The cheapest item in this document and it should be done early.**

On x86-64 SysV: save `rbx`, `rbp`, `r12`–`r15`, `rsp`, and the return address; optionally the MXCSR
and the x87 control word (which a strictly conforming `setjmp` does save). Restore them and jump.
**~40 lines of assembly, no kernel involvement, no syscall.**

`jmp_buf` should be **8 `unsigned long` plus 2 words for MXCSR/x87CW**, sized generously from the
start so that widening it later does not change an ABI.

**What it unlocks:** libpng, libjpeg, zlib's error paths, and the error-handling idiom that a
surprising fraction of portable C uses. It is worth having at tier A purely because it costs almost
nothing.

**The honest caveat:** `longjmp` out of a deep call chain on a **4 KiB stack** is not the risk;
getting deep enough to want it is. `setjmp`/`longjmp` do not make the stack problem better or worse.

### 4.8 The big ones, sized in one table

| item | lines to write | lines to import | new syscalls | needed from |
|---|---|---|---|---|
| `realloc`/`calloc`/`aligned_alloc` | ~60 | — | 0 | tier A |
| allocator size classes | ~250 | — | 0 | tier C |
| `errno` + mapping + `strerror` | ~100 | — | 0 | tier A |
| `setjmp`/`longjmp` | ~40 | — | 0 | tier A (cheap) |
| rest of `string.h` + `ctype.h` | ~350 | — | 0 | tier A |
| `stdlib.h` core (`qsort`, `bsearch`, `strtol` family, `atexit`) | ~450 | — | 0 | tier A |
| **`stdio` + `FILE` + the integer `printf` engine** | **~1600** | — | 1–3 | tier A |
| `scanf` engine | ~400 | — | 0 | tier B |
| **float `printf` + `strtod`** | ~50 glue | **~900 (musl, MIT)** | 0 | **tier B** |
| **libm** | ~200 (SSE one-liners) | **~15 000 (musl/openlibm, MIT/ISC)** | 0 | tier C |
| `locale` (C only) | ~60 | — | 0 | tier C |
| `time` (calendar) | ~400 | — | 0 | tier B |
| `time` (monotonic) | ~20 | — | **1** (+40 kernel) | tier C |
| `time` (wall clock) | ~20 | — | **1** (+150 kernel RTC) | tier D |
| `signal` stubs | ~30 | — | 0 | tier A |
| real signals | ~200 | — | **~6** (+800 kernel) | tier E only |
| `__int128` helpers | ~200 | ~400 (compiler-rt) | 0 | tier D |

**Totals for a tier-D-capable library: roughly 4000 lines written and 16 000 imported.** The written
half is four to six milestones at this project's demonstrated pace. The imported half is one
milestone of vendoring, licence accounting and differential testing.

---

## 5. Build or port

This is the consequential recommendation and it is stated as a decision with its reasons, not as
options.

### 5.1 The question, sharpened

"Build or port" is three questions wearing one coat, and answering them separately produces a
different answer than answering them together:

1. **The OS interface layer** — `sys_call`, the wrappers, the refusal convention, `RFILE`.
2. **The pure-computation layer** — libm, float conversion, `qsort`, `strtol`, calendar arithmetic.
   No OS dependency of any kind.
3. **The stateful C layer** — `FILE`, `errno`, `locale`, `atexit`, the allocator. Depends on 1,
   provides the interface 2 is called through.

**Layer 1 must be built and already is.** No imported libc will ever produce a better fit than the
one written against this kernel's own refusal values and checked against its sources at harness time.

**Layer 2 must be imported.** Every line of it is a solved problem with a permissive licence and a
subtle failure mode.

**Layer 3 is the actual question**, and it is the only one worth arguing about.

### 5.2 musl — **do not port it**

*MIT. ~120 k lines. Actively maintained. The best-written libc there is.*

And the wrong choice here, for reasons that are structural rather than aesthetic:

* **`errno` is TLS.** musl's `errno` is `__pthread_self()->errno_val`, read through `%fs`. There is
  no `%fs` base on this OS (GAP-0148) and no TLS. This is not a `#define` away; it is how musl
  reaches per-thread state everywhere.
* **Every `FILE` has a lock.** `stdio` calls `__lock`/`__unlock` on every operation; they are
  futex-based and check `__libc.threaded`. Single-threaded musl still compiles and executes the lock
  path.
* **The allocator requires `mmap`.** `mallocng` has no `brk`-only mode. The older `oldmalloc` used
  `brk` *and* `mmap` and is no longer the default. This kernel has `sbrk` and nothing else.
* **There is no OS abstraction layer.** musl has `src/internal/syscall.h`, which abstracts *how* a
  Linux syscall is issued — not *whether the OS is Linux*. Linux semantics (`SYS_mmap`,
  `SYS_futex`, `SYS_clone`, `SYS_set_tid_address`, the `/proc` filesystem, `AT_*` auxv entries)
  appear throughout. Every project that has run musl on a non-Linux kernel — Fuchsia most
  prominently — did so by **forking musl and rewriting the threading, TLS and memory layers**, and
  then owned that fork forever.

**What this kernel would have to grow before a musl port could even start:** TLS with an
`arch_prctl`-equivalent, `mmap`/`munmap`/`mprotect`, futexes, `clone`, and a `set_tid_address`. That
is tier E's syscall list. **Porting musl to this OS means building tier E's kernel first, and if
tier E's kernel existed the port would be unnecessary.**

**But take musl's code by the file.** Its libm, its `vfprintf` float path, its `__floatscan`/
`strtod`, its `qsort` (smoothsort, ~200 lines), its `strstr` (two-way, ~150 lines) are all MIT,
OS-independent, and better than anything that would be written here. **Import the files; do not port
the library.**

### 5.3 newlib — **the viable port, and the one that fits**

*A collection of BSD-family licences. Large. Designed since 1994 for exactly this situation.*

**Why it fits: the OS seam is 19 stub functions, and this kernel already implements 7 of them.**

| newlib stub | oscortex today | gap |
|---|---|---|
| `_write` | `fdwrite` (files) / `write` (console) | shape matches; needs an fd 1/2 → console route |
| `_read` | `read` | matches |
| `_open` | `openmode` | matches; flags need translating |
| `_close` | `close` | matches |
| `_lseek` | `seek` | absolute only — needs `SEEK_CUR`/`SEEK_END` |
| `_sbrk` | `sbrk` | **exact match**, including the semantics |
| `_exit` | `exit` | matches |
| `_fstat` | — | must return `S_IFCHR` for fds 0–2 and a size for files; **no syscall gives a file's size** |
| `_isatty` | — | trivial: `fd < 3` |
| `_kill`, `_getpid` | — | stub: `ENOSYS` / return 1 |
| `_link`, `_unlink`, `_stat` | — | stub `ENOSYS`; `_unlink` needs GAP-0127 item 7 |
| `_fork`, `_execve`, `_wait` | — | stub `ENOSYS` |
| `_times`, `_gettimeofday` | — | stub, then §4.5 |

**Twelve of the nineteen are legal `ENOSYS` stubs for a freestanding program.** That is what
`libgloss` is for and it is the whole reason newlib exists.

* **`errno` needs no TLS.** newlib uses `_impure_ptr->_errno` — a global reentrancy struct.
  Single-threaded works out of the box.
* **`stdio` needs no locks.** `--disable-newlib-multithread` is a supported configuration.
* **The allocator uses `_sbrk` only.** newlib's `nano-malloc` is `sbrk`-based by design.
* **libm, full `printf` with `%f`/`%a`/`%g`, `strtod`, C locale, `time`, `setjmp` — all included.**
* **`x86_64-elf` is a supported target triple**, and the homebrew formula `x86_64-elf-gcc` ships
  newlib prebuilt for it. This machine already has `x86_64-elf-binutils` installed; the gcc-plus-
  newlib formula is one `brew install` away.

**Costs, stated:**

* **Size.** newlib is big and its `printf` is famously so. Mitigated the standard way, with
  `-ffunction-sections -fdata-sections -Wl,--gc-sections` — and see L1, where the same mechanism is
  already recommended for the native library. `newlib-nano` (`--enable-newlib-nano-formatted-io`)
  brings a hello-world to tens of KiB.
* **Licence.** newlib is a *collection*: predominantly BSD-2 and BSD-3, plus a Red Hat licence and a
  handful of others; the licence file enumerates roughly forty. **None is GPL** and none is
  incompatible with anything this project would do. The cost is bookkeeping, not freedom.
* **Build.** autotools, cross-configured. This project builds everything with clang and a bash
  script; introducing autotools is a real friction. Building newlib **with clang** works but is not
  its best-tested path.
* **The `_fstat` problem is real.** newlib's `stdio` calls `_fstat` to decide buffering and to
  implement `SEEK_END`. This kernel has **no way to ask a file's size** — GAP-0122 item 4 named it
  and it is unclosed. A newlib port is blocked on one new syscall, and it is a small one.

### 5.4 picolibc — **the modern alternative, and probably the better one**

*BSD-3-Clause predominantly, inherited from newlib and AVR-libc. Meson. Actively maintained.
Designed for bare metal with no OS at all.*

Everything said for newlib, plus:

* **An even smaller seam.** picolibc's console is two hooks; `sbrk` is optional (it has a
  static-heap mode, which is *exactly right* for a 2 MiB window that cannot grow).
* **`errno` is a plain global by default**, with TLS as an opt-in — matching §4.3's recommendation
  without argument.
* **`tinystdio` is small and has real float support**, selectable at build time
  (`-Dio-float-exact=true` gives correctly-rounded conversion; `-Dio-long-double` adds the rest).
  Newlib's full `stdio` is also available as a build option if `tinystdio` proves too thin.
* **Meson, not autotools** — a substantially better cross-compilation story, and clang is a
  first-class compiler for it.
* **Licence is cleaner:** predominantly BSD-3-Clause with some MIT, and the file list is tractable.

**Costs, stated:**

* **x86_64 is not a first-class bare-metal target.** picolibc's flagship architectures are ARM and
  RISC-V; x86-64 exists for native/test builds. There is no x86-64 bare-metal BSP with startup code.
  **This matters less than it sounds**, because the startup code is `start.c` and it already exists
  and is better documented than most BSPs.
* **`tinystdio` is deliberately minimal.** `%n` is absent, `scanf` is reduced, `FILE` is small.
  Tiers A–C are comfortable; ffmpeg's `sscanf` usage would need testing, and the newlib-stdio build
  option is the escape hatch.
* Same `_fstat`-equivalent gap as newlib.

### 5.5 PDCLib — **right for tiers A–B, useless for C–D**

*CC0 — public domain. Genuinely tiny. A `platform/` directory of ~10 functions is the whole OS seam.*

**The best possible licence** (no attribution obligation at all) and the smallest possible port
effort. And:

* **No libm. At all.** PDCLib does not ship one and does not intend to.
* Float support in its `printf` is recent and limited; `strtod` likewise.
* No locale beyond `"C"`; wide-character support is partial.

**So PDCLib solves layer 3 and none of layer 2**, which means at tier C you would be pairing PDCLib
with an imported musl libm and an imported float-conversion path — which is *exactly the shape*
newlib and picolibc arrive in already assembled. PDCLib is the right answer if the goal stops at a
self-hosted shell and a compiler. It is the wrong answer if the goal is ffmpeg.

### 5.6 The licence question, settled quickly

| | licence | obligation | fit |
|---|---|---|---|
| musl | MIT | attribution | ✓ perfect |
| picolibc | BSD-3 + MIT | attribution, no-endorsement | ✓ fine |
| newlib | ~40 BSD-family licences | attribution, bookkeeping | ✓ fine, tedious |
| PDCLib | CC0 | none | ✓ perfect |
| openlibm | ISC/MIT/BSD | attribution | ✓ fine |
| compiler-rt | Apache-2.0 with LLVM exception | attribution, patent grant | ✓ fine |

**Licence is not the deciding factor and should not be allowed to become one.** All six are
compatible with any plausible future for this project, commercial or not. The deciding factor is
§5.7.

### 5.7 The syscall surface, which is the real question

Here is the table that decides it. What each candidate demands **from this kernel** before it can
link and run:

| demand | musl | newlib | picolibc | PDCLib | this kernel today |
|---|---|---|---|---|---|
| `sbrk` | optional | **yes, and that is all** | optional (static heap) | yes | **✓ have it** |
| `mmap` | **required** (mallocng) | no | no | no | ✗ |
| TLS / `%fs` base | **required** (`errno`) | no | optional | no | ✗ |
| futex / `clone` | **required** (stdio locks) | no (`--disable-multithread`) | no | no | ✗ |
| a file's size (`fstat`) | yes | **yes** (stdio buffering, `SEEK_END`) | yes | yes | ✗ **one small syscall** |
| `SEEK_CUR` / `SEEK_END` | yes | **yes** | yes | yes | ✗ **widen `seek`** |
| write at an offset | yes | **yes** | yes | yes | ✗ append-only (GAP-0127) |
| `isatty` | stub-able | stub-able | stub-able | stub-able | ✗ trivial |
| ≥ 3 descriptors before `main` | yes | **yes** (`stdin`/`stdout`/`stderr`) | yes | yes | **4 total** — leaves one |
| Linux syscall *semantics* throughout | **yes** | no | no | no | ✗ |

**Read the last-but-one row twice.** Every hosted libc opens three standard streams before `main`.
This kernel gives a program **four descriptors in total**. A newlib program would have one
descriptor left for its actual file. `fileMaxFds` must rise before any port, and it is a one-constant
change with a table behind it.

And the row above it: **stdout and stderr have to go somewhere.** Today `write` goes to the console
and takes no descriptor; `fdwrite` takes a descriptor and goes to a file. A ported libc calls
`_write(1, buf, n)`. The seam must route fd 1 and 2 to the console `write` and everything else to
`fdwrite` — that is five lines in the glue and it is worth naming because it is the single most
likely place for a port to go quietly wrong.

### 5.8 The recommendation

**Three parts, in this order.**

**(1) Keep `oslibc` as the OS interface layer, permanently, and do not let any port replace it.**
The refusal-floor convention, the harness-checked syscall numbers, the loud `%!`, `RFILE`, and the
`volatile const` words `derive.py` reads out of the ELF are all *better* than their C equivalents and
all of them are load-bearing for existing tests. A ported libc sits **on top** of this, calling it
through a `libgloss`-shaped seam. This is not a compromise; it is the correct architecture and it is
already half-built.

**(2) Import layer 2 now, file by file, starting with libm and float conversion.** musl's `src/math`
and its `vfprintf`/`__floatscan` float paths, under MIT, into a `core/user/libc/vendor/` directory
with the licence text alongside and a `VENDOR.md` recording the upstream commit — the same discipline
`DCDART_PIN.txt` already applies to the toolchain. This is **~16 000 lines of solved problem for the
cost of a vendoring milestone**, and there is no argument for writing it. Do this regardless of what
is decided in part 3.

**(3) Build tiers A and B by hand. Port at tier C. The port is picolibc, with newlib as the
fallback. Never musl.**

The reasoning, stated as the argument rather than the conclusion:

* **Tiers A and B must be hand-built because they are what surfaces the kernel work.** Writing
  `stdio` against this kernel is what makes it obvious that `SEEK_END` is impossible, that a file's
  size cannot be asked for, that `O_WRITE` cannot save a file, and that four descriptors is not
  enough. Importing a libc at tier A would hit all four of those on day one as *link-time
  failures in someone else's code*, which is the worst possible way to discover a kernel gap.
  **Every one of the ten rows in §5.7's table is a kernel milestone that a hand-built libc finds
  gently and an imported one finds all at once.**
* **Tier C is where hand-building stops paying.** libm and correct float conversion are the point at
  which "write it" becomes "write a worse version of a thing that is MIT-licensed and forty years
  debugged." Part 2 already imports those. The remaining question at tier C is whether the
  *stateful* layer — `FILE`, `errno`, `locale`, `atexit` — is worth keeping hand-built, and by then
  it will have been written once and the answer will be known from evidence rather than from this
  document.
* **picolibc over newlib** because of Meson-over-autotools, a cleaner licence file, a smaller seam,
  an `errno` that is a global by default, and a static-heap mode that suits a fixed 2 MiB window
  better than `sbrk` does. **newlib is the fallback** if `tinystdio` proves too thin for ffmpeg,
  and switching between them is cheap because they share ancestry and a seam shape.
* **Never musl** for §5.2's structural reasons, while taking musl's *files* freely.

**The one thing that would change this recommendation:** if the kernel grows `mmap`, TLS and futexes
for reasons of its own — which tier E would require and which a threading milestone might deliver —
then musl becomes viable and becomes the best choice, because it is the best-written of the four.
That is a large "if" and nothing in tiers A–D requires it.

### 5.9 The collision hazard, which must be decided before any port lands

A ported libc defines `printf`, `malloc`, `free`, `memcpy`, `memset`, `strlen`, `strcmp`, `strcpy`
and `exit`. **So does `oslibc`.** Both in the link line is either a duplicate-symbol error (good) or
a silent choice of whichever object the linker reached first (very bad — and with archives, which is
how a ported libc arrives, the archive member is only pulled if the symbol is still undefined, so
**the silent case is the likely one**).

**Decide now, before L9:** the native library's C-named functions get an `os` prefix
(`osPrintf`, `osMalloc`, …) with the plain names provided by a thin compatibility header that a
program includes *or* the ported libc provides — never both. `write`, `open`, `read`, `close` and
`seek` need the same treatment for the same reason, and `write`/`open` are currently protected only
by an arity mismatch that a ported libc's declaration would resolve in its own favour.

This is a renaming with no behavioural content, it touches five harnesses, and it is far cheaper
before a port than during one.

### 5.10 What this document recommends against, so nobody costs it twice

* **Porting musl.** §5.2.
* **Writing a `dtoa` or a `strtod` from scratch.** §3.3.
* **Writing transcendental functions from scratch.** §3.4.
* **Replacing `malloc` with an imported allocator** — all the good ones need `mmap`. §4.1.
* **Building real signals** before something needs them that a cancellation flag cannot serve. §4.6.
* **Giving DCDart a floating-point type so the kernel can print one.** §3.5, and CLAUDE.md rule 3.
* **Attempting tier E.** §2.5, and `display-protocol.md` §5.4 already ruled on the compositor half.

---

## 6. The milestone ladder

**Every criterion below is written to this repo's rules for a derived expectation**, restated from
`display-protocol.md` §6 because they bind here identically:

* compute the expectation from a source the kernel does not control;
* restate the rules in the harness, never import them;
* assert every constant copied from the kernel against the kernel's source;
* **guard against a vacuous pass** — a check that a function exists must fail against a build where
  it does nothing;
* structural checks before boot checks, and **a negative control that must fail**.

And one rule specific to this ladder, which follows from §0's last paragraph:

* **Every milestone must state what happened to the five goldens.** `m13-libc`, `m14-fat`,
  `m15-fileio`, `m16-filewrite` and `m19-argv` all compile this library into their programs and all
  assert byte-exact serial. L1 exists to make the honest answer to that question be "nothing."

---

### L1 — The library can grow without moving five goldens

**Blocked on: work only.** No kernel change. This is the milestone that makes every later one
cheap, and it should be done before any function is added.

**What it adds:** zero symbols. It changes how the library is compiled and linked.

Compile every libc object with `-ffunction-sections -fdata-sections`; link every program with
`--gc-sections`. Adopt clang's freestanding headers (`stddef.h`, `stdint.h`) in `oslibc.h` in place
of the hand-written typedefs (§1.3).

**The measurement that motivates it, taken 2026-08-23** on a program whose `main` calls only
`printf`, linked through `m19-argv/prog.ld`:

| | `.text` | `.bss` |
|---|---|---|
| as built today | **4386** | **1296** |
| with `-ffunction-sections -fdata-sections -Wl,--gc-sections` | **1826** | **128** |

**58% of the library's text and 90% of its `.bss` are dead weight in that program**, and — the point
of the milestone — *a file added to the library costs a program that does not call it exactly zero
bytes.*

**The gotcha, and it is measured too.** `--gc-sections` **deletes** `mallocHdrBytes`, `printfMax`
and `libcFreeEnabled` from the linked ELF — verified with `x86_64-elf-nm` — because nothing
references them. Those are precisely the words `m13-libc/derive.py` reads out of the binary. They
must be marked `__attribute__((used, retain))` or wrapped in `KEEP()` in every `prog.ld`.

**Exit criterion.** `core/tests/conformance/m20-libc-gc/run.sh` exits 0, having established:

1. **The six libc objects each contain one section per function.** `readelf -S` on each object shows
   `.text.<name>` for every `T` symbol in §1.1's table, and **zero** plain `.text` with more than
   one function in it. Structural, before any boot.
2. **A new file costs nothing.** A file `unused.c` defining ten exported functions is added to the
   library and to every harness's `LIBC_SRCS`. **All five existing harnesses' byte-exact goldens are
   reproduced unchanged**, and `size` reports identical `.text` for every program in all five.
   *This is the milestone's whole claim and it is the check that makes it binary.*
3. **The six exported constant words survive.** `x86_64-elf-nm` on every linked program still finds
   `mallocHdrBytes`, `mallocAlign`, `mallocMinSplit`, `printfMax`, `libcWriteMax` and
   `libcFreeEnabled`, and `derive.py` still reads all three allocator words and recomputes all six
   `malloc` addresses.
4. **The negative control:** the same `unused.c` **without** `-ffunction-sections`, which must move
   at least one golden. A harness that passes both ways is measuring nothing.
5. **`m13-libc`'s two byte-identical builds stay byte-identical.** `progL` and `progN` must still
   have identical segment geometry after garbage collection, since both reach the same set.

*Binary:* ten new exported functions enter the library and five byte-exact serial goldens are
reproduced unchanged, while the same ten without section-splitting move at least one.

---

### L2 — `errno` exists, and its ABI survives threads that do not exist yet

**Blocked on: work only.**

**What it adds:** ~40 `E` constants, `errno`, `__errno_location`, `strerror`, `strerror_r`,
`assert`. **~5 symbols, 0 syscalls.**

`errno` is `(*__errno_location())` from the first line (§4.3). A mapping table converts this
kernel's sixteen refusal values; the two with no honest POSIX equivalent get oscortex-specific
values above the POSIX range.

**The refusal-floor convention is not replaced.** Every existing function keeps returning its own
refusal. `errno` is set *in addition*, by the wrappers, for the benefit of ported code.

**Exit criterion.** `core/tests/conformance/m21-errno/run.sh` exits 0:

1. **Structural: `errno` is never a bare `extern int`.** The header is read and required to define
   `errno` as a dereference of a function call. A mutation to `extern int errno` fails this check.
2. **All sixteen refusals map, and the mapping is read out of the kernel.** `derive.py` extracts
   `fileRet*` and `heapRet*` from `file.dart` and `heap.dart` and requires the library's table to
   name **every** one of them — a seventeenth kernel refusal added later fails this check rather
   than silently mapping to zero.
3. **Every mapped `errno` is provoked on a real boot.** The program triggers at least eight distinct
   refusals (bad fd, bad pointer, bad length, no slot, bad name, not found, bad seek, oversized
   `sbrk`) and prints `errno` and `strerror` for each; the harness derives all eight from the kernel
   sources.
4. **`errno` is not clobbered by a successful call.** After a successful `read`, `errno` holds
   whatever the last *failed* call left — C's rule, and the opposite of the intuitive
   implementation. The program asserts it.
5. **Negative control:** a build whose wrappers do not set `errno`. Every check in 3 must fail
   against it.

*Binary:* eight distinct kernel refusals produce eight `errno` values and eight `strerror` strings,
all derived from `file.dart` and `heap.dart`, and a build that never sets `errno` fails all eight.

---

### L3 — `string.h`, `ctype.h` and the rest of `stdlib.h`'s integer half

**Blocked on: work only.** L1 must land first or this moves every golden.

**What it adds:** ~50 symbols, 0 syscalls. All of `string.h` (17 more), all of `ctype.h` (13),
`qsort`, `bsearch`, `atoi`/`atol`/`atoll`, the `strtol`/`strtoul`/`strtoll`/`strtoull` family,
`abs`/`labs`/`llabs`, `div`/`ldiv`, `realloc`, `calloc`, `aligned_alloc`, `abort`, `atexit`.

**Exit criterion.** `core/tests/conformance/m22-libc-str/run.sh` exits 0:

1. **Differential against the host.** `derive.py` runs the *host's* libc over the same inputs and
   the guest must produce identical results for every one of ~50 functions across ~500 cases —
   including `strtol` overflow saturation to `LONG_MAX`/`LONG_MIN` with `ERANGE`, base-0 and base-16
   prefixes, and `qsort` stability-agnostic ordering of a permutation the host sorts too.
2. **`realloc`'s four cases are each exercised and each *measured*, not asserted:** `realloc(NULL,n)`
   equals `malloc(n)`; `realloc(p,0)` frees and returns `NULL`; a shrink returns the same address;
   a grow that fits in place returns the same address and a grow that does not copies the payload
   **byte for byte** — verified by a checksum computed before and after.
3. **`aligned_alloc(64, n)` returns a 64-aligned pointer** and `free` accepts it, for eight
   alignments from 16 to 1024, with the addresses derived from the allocator's exported words.
4. **`atexit` handlers run in reverse order** and run on a `return` from `main`, not only on an
   explicit `exit`.
5. **Negative control:** a build with `realloc`'s copy removed. Check 2's checksum must fail.

*Binary:* ~500 differential cases against the host libc, all identical; `realloc`'s copy is proved
by a checksum that a build without it fails.

---

### L4 — `stdio`: `FILE`, buffering, three streams, and the integer `printf` engine

**Blocked on: the kernel.** This is the first milestone that cannot be completed in userland.

**Needs from the kernel — and finding these is the point of building this by hand (§5.8):**

* **a file's size** — one new syscall; `SEEK_END` and buffering decisions both need it (GAP-0122
  item 4);
* **`SEEK_CUR`/`SEEK_END`** — widen `seek` with a `whence`, or accept size-plus-absolute;
* **more than four descriptors** — three are gone before `main` runs;
* **`stdin`** — a console-input syscall, which needs a scheduler that can block (GAP-0097). *`stdin`
  may be deferred to L4b; `stdout`/`stderr`/files may not.*

**What it adds:** ~35 symbols, ~3 syscalls.

`printf` grows widths, flags, precision, length modifiers, `%u`, `%o`, `%p`, `%i`. `snprintf`,
`vsnprintf`, `fprintf`, `vfprintf`, `puts`, `fputs`, `fgetc`, `fgets`, `fread`, `fwrite`,
`fseek`/`ftell`, `setvbuf`, `feof`/`ferror`/`clearerr`, `fflush`, `perror`. **No floats yet** — `%f`
still prints `%!`, deliberately, so that L5 has something to measure.

`rfile.c`'s buffering becomes `FILE`'s read path. `RFILE` stays as a name and becomes a thin alias,
because five harnesses use it.

**Exit criterion.** `core/tests/conformance/m23-stdio/run.sh` exits 0:

1. **Buffering is counted, not claimed.** A 20 000-byte file read with `fgetc` produces exactly
   `ceil(20000/BUFSIZ)` `read` syscalls, the number derived from `BUFSIZ` read **out of the ELF**,
   and the kernel's own syscall trace is what counts them. `setvbuf(_IONBF)` on the same file
   produces exactly 20 000.
2. **The write path flushes at the right moments and only those:** on buffer-full, on `fflush`, on
   `fclose`, on `exit`, and — for a line-buffered stream — on `\n`. Each is a separate derived
   syscall count. A program that writes 10 000 bytes and calls `abort` must show the buffer *not*
   flushed.
3. **`printf` differential against the host** over ~300 format/argument pairs covering every width,
   flag, precision and length modifier, byte for byte. **`%f` must still produce `%!`**, and the
   harness requires it.
4. **`FILE` is opaque.** Structural: the public header declares `FILE` as an incomplete type and no
   program in the tree reaches a field.
5. **`exit` flushes and `_exit` does not**, both shown on one boot.
6. **Negative control:** a build with the write buffer flushed on every `fputc`. Check 1's derived
   syscall counts must fail.

*Binary:* the kernel's own syscall count for reading a 20 000-byte file matches
`ceil(20000/BUFSIZ)` with `BUFSIZ` read out of the ELF, and 20 000 with buffering off.

---

### L5 — Floats print and parse, correctly

**Blocked on: work only** — L4's engine must exist first. **The code is imported, not written.**

**What it adds:** `%f`, `%e`, `%g`, `%a`, `%F`, `%E`, `%G`, `%A`; `strtod`, `strtof`, `strtold`,
`atof`. **~6 symbols, 0 syscalls.**

Import musl's `vfprintf` float path and `__floatscan`/`strtod` into `core/user/libc/vendor/musl/`
with the licence text and a pinned upstream commit (§5.8 part 2). Glue only.

**Exit criterion.** `core/tests/conformance/m24-float/run.sh` exits 0:

1. **Round-trip over a derived corpus.** 10 000 doubles — chosen by `derive.py` to include ±0,
   subnormals, `DBL_MIN`, `DBL_MAX`, the powers of two either side of every exponent boundary, and
   a seeded pseudo-random sample — are printed with `%.17g` and parsed back, and **every one must
   return bit-identical**. The guest prints the 64-bit pattern of the result; the harness compares
   against the pattern it sent in.
2. **Correct rounding, differential against the host** for `%.0f` through `%.30f` on a corpus
   including the classic hard cases (`0.1`, `2^-1074`, `9007199254740993.0`, values whose exact
   decimal expansion is 700+ digits), byte for byte against the host's `printf`.
3. **±inf, ±nan and `%a`** produce the exact strings C requires.
4. **`strtod` sets `ERANGE`** on overflow and underflow, returns `HUGE_VAL`/`0.0` with the right
   sign, and stops at the right `endptr` for eight malformed inputs.
5. **Structural: no floating-point conversion code was hand-written.** The vendored directory's
   files must match their upstream hashes, recorded in `VENDOR.md`, checked before the build.
6. **Negative control:** the float path replaced by a naive `while (v > 1) v /= 10` formatter. Check
   1 must fail, and the harness requires it to fail **on more than 100 of the 10 000** — a control
   that fails on one case is not a control.

*Binary:* 10 000 doubles survive `%.17g` → `strtod` bit-identically; a naive formatter fails on more
than 100 of them.

---

### L6 — libm

**Blocked on: work only. Imported.**

**What it adds:** ~43 double + ~26 float functions, plus `fenv.h`. **~70 symbols, 0 syscalls.**

Import musl's `src/math` (MIT). Keep the ~15 that are one or two SSE2 instructions on this target
as hand-written intrinsics (`sqrt`, `fabs`, `copysign`, `floor`, `ceil`, `trunc`, `rint`, `round`,
`fmin`, `fmax`, and the classification predicates) — measured to be single instructions in §3.1 —
and take the transcendentals from upstream unmodified.

**Exit criterion.** `core/tests/conformance/m25-libm/run.sh` exits 0:

1. **Differential against the host libm, ULP-bounded.** Every one of the ~70 functions over ≥ 2 000
   arguments each, spanning subnormals, ±0, ±inf, NaN, the argument-reduction boundaries (multiples
   of π/2 up to 2^60 for the trigonometric functions), and a seeded random sample. Required: **≤ 1
   ULP** for the functions musl documents as correctly rounded, **≤ 2 ULP** otherwise, with the
   bound per function stated in the harness rather than inferred.
2. **The SSE one-liners are one-liners.** Structural: `objdump` on the linked program shows
   `sqrtsd` inside `sqrt` and **no `call`** inside any of the fifteen.
3. **`m11-proc`'s claim is re-asserted:** the **kernel** still contains not one SSE instruction, and
   the FPU state of two processes running float code concurrently stays private — the M11 signature
   check, re-run with real libm calls in both.
4. **Vendored files match their upstream hashes.**
5. **Negative control:** `sin` replaced by its 5-term Taylor series. Check 1 must fail, and must
   fail specifically on the large-argument cases rather than only on the random sample.

*Binary:* ~140 000 differential evaluations against the host libm, every one inside its stated ULP
bound, with a Taylor-series `sin` failing on the large-argument set.

---

### L7 — The allocator grows up

**Blocked on: work only.**

**What it adds:** 0 new symbols beyond L3's. Segregated free lists for small sizes; a `malloc` that
is O(1) for the common case (§4.1).

**Exit criterion.** `core/tests/conformance/m26-malloc2/run.sh` exits 0:

1. **The complexity claim is measured, not asserted.** A program allocates and frees 4 000 blocks in
   a pattern that produces a long free list, then times 1 000 allocations using the kernel's tick
   counter. The **ratio** against the same measurement at 400 blocks must be **below 2.0**; the
   first-fit build's ratio must be **above 5.0**, and the harness requires both.
2. **Every reuse, coalescing and round-trip property `m13-libc` established still holds**, with all
   six addresses still derived — the new allocator must satisfy the *old* harness, unmodified.
3. **A fragmentation bound:** a derived allocate/free workload's peak `sbrk` total must not exceed
   the first-fit build's, and the harness computes both.
4. **Negative control:** `m13-libc`'s existing `free()`-disabled control, unchanged and still
   failing everything it fails today.

*Binary:* the allocation-time ratio between a 4 000-block and a 400-block free list is under 2.0 for
the new allocator and over 5.0 for the old one.

---

### L8 — `setjmp`, `time`, `locale`, `signal` stubs

**Blocked on: the kernel, for one item only** — a monotonic clock syscall over the existing PIT tick
counter (§4.5).

**What it adds:** ~25 symbols, 1 syscall. `setjmp`/`longjmp`; `gmtime`/`gmtime_r`/`mktime`/
`timegm`/`difftime`/`asctime`/`ctime`/`strftime`; `clock_gettime(CLOCK_MONOTONIC)`; `setlocale`/
`localeconv` (C only); `signal`/`raise` as recording stubs.

**Exit criterion.** `core/tests/conformance/m27-misc/run.sh` exits 0:

1. **`setjmp`/`longjmp` preserve the callee-saved set.** The program loads a distinct signature into
   `rbx`, `rbp`, `r12`–`r15`, MXCSR and the x87 control word, `longjmp`s from eight frames deep, and
   prints all nine back. All nine derived by the harness.
2. **`longjmp(buf, 0)` returns 1**, which C requires and which a naive implementation gets wrong.
3. **Calendar differential against the host** over 20 000 timestamps spanning 1901–2100, every leap
   year and every leap-year-century rule, `mktime`∘`gmtime` = identity for all of them.
4. **`strftime` differential** over every conversion specifier the implementation claims, byte for
   byte against the host; any specifier **not** implemented must produce a visible marker, in
   `printf`'s tradition, and the harness requires at least one marker to be reachable and observed.
5. **The monotonic clock never goes backwards** across 10 000 reads spanning a preemption — and the
   harness requires at least one preemption to have occurred in the window, read from the kernel's
   own per-slot preempt counter, or the check is vacuous.
6. **`setlocale(LC_ALL, "de_DE")` returns `NULL`** and leaves the decimal point as `'.'`. A stub
   that accepted it silently would make `printf("%f")` locale-dependent later.
7. **Negative control:** a `setjmp` that saves only `rsp` and the return address. Check 1 must fail
   on at least six of the nine registers.

*Binary:* nine register signatures survive a `longjmp` from eight frames deep; 20 000 timestamps
round-trip through `mktime`∘`gmtime`; the monotonic clock is non-decreasing across a preemption the
kernel confirms happened.

---

### L9 — The port decision executes

**Blocked on: L4's kernel work, plus §5.9's renaming.** This is where §5.8's recommendation is
either carried out or abandoned on evidence.

**What it adds:** whatever the chosen libc has, minus what L2–L8 already built. **~0 new syscalls**
if L4 did its job.

Before any code: **execute §5.9's renaming.** The native library's C-named functions become
`os`-prefixed; the plain names come from exactly one place.

**Exit criterion.** `core/tests/conformance/m28-libc-port/run.sh` exits 0:

1. **The seam is complete and every stub is named.** Structural: the glue file defines all nineteen
   `_`-prefixed functions the chosen libc requires; each is either a real implementation or an
   explicit `ENOSYS` stub with a comment naming the GAP that would close it. **A missing one is a
   link error and the harness requires the link to be attempted with `--no-undefined`.**
2. **No symbol is defined twice.** `nm` over every object in the link line finds no C-standard name
   defined in both the native library and the ported one. This is §5.9's check and it is the reason
   the renaming happens first.
3. **A program built against the ported libc runs**, reads a file, formats a float and exits with a
   derived status — and the **same source** built against the native library produces byte-identical
   output. That equivalence is the whole point: two libcs, one program, one transcript.
4. **The size cost is stated as a number, not a feeling.** `size` on both builds, with the delta in
   the harness's own output, so a regression in link-time garbage collection is visible.
5. **The five existing goldens are unchanged.** The port adds a build configuration; it does not
   change the default one.
6. **Negative control:** the port linked **without** `--gc-sections`, which must exceed the 2 MiB
   window and fail to load — proving both that the mechanism is load-bearing and that the kernel
   refuses an oversized program cleanly.

*Binary:* one program source, two libcs, byte-identical transcripts; zero duplicate C-standard
symbols across the link line; five goldens unmoved.

---

### Capstone — ffmpeg decodes one frame

**Blocked on the kernel, and this entry exists to say so precisely rather than to be attempted.**

Everything in §2.4's second table. Restated as the list a milestone would have to close first:

1. **The address space.** 2 MiB → at least 64 MiB, which means the loader, `vmProgBase`, the page
   tables and `m10`/`m11`'s byte-exact goldens all move.
2. **The stack.** One page → a growable region, which means a fault handler that can tell a stack
   growth from a wild pointer.
3. **Writes at an offset.** GAP-0127 items 3 and 7. Without it no container can be muxed, because
   every container rewrites its header after the last frame.
4. **`READ_MAX` 512 → 32 KiB**, or ffmpeg's I/O costs 64 syscalls per block.
5. **64-bit file offsets and a filesystem with subdirectories and long names.**
6. **Sixteen descriptors.**
7. **A wall clock.**

**Only after all seven** is the libc the binding constraint, and by then L1–L9 will have delivered
it. The honest ordering is: **this is a kernel roadmap with a libc dependency, not a libc roadmap
with a kernel dependency**, and §2.4 is where that was established rather than assumed.

A defensible intermediate capstone that needs *none* of items 3–7, and would be a real result:
**`libavcodec` decodes one JPEG from a file on the volume into a framebuffer surface** — one
decoder, no demuxer, no muxer, no container, no time. It needs items 1 and 2 and nothing else.
That is the milestone this document would actually propose.

---

## 7. What I did not decide, and would rather be told

1. **Does `oslibc` keep the C names or give them up?** §5.9 recommends the `os` prefix, and it is a
   renaming that touches five harnesses. It is much cheaper now than after a port. **I would rather
   the owner decided this before L2 than after L8.**
2. **Is self-hosting (tier B) a goal, or is cross-compiling from macOS permanent?** The answer
   changes L3's and L4's priority substantially and changes whether PDCLib is a serious candidate.
3. **`stdin`, and who owns the console.** The keyboard belongs to the ring-0 shell. A program that
   reads a character requires deciding whether the shell hands the console over, and that is a
   design decision above this document's level.
4. **Whether `printf`'s loud `%!` survives contact with a ported libc.** It cannot — a ported
   `printf` implements everything and has nothing to mark. I think the marker should survive **in
   the native library** and that the two should coexist, but that is an argument for whoever writes
   L9's ADR.
5. **Whether the vendored code lives in this repo or is fetched at build time.** `DCDART_PIN.txt`'s
   precedent says pin a hash; the freestanding discipline says depend on nothing at build time. I
   lean toward vendoring the files in-tree with a pinned upstream hash, but the repo has a
   convention for external dependencies and I did not want to invent a second one.

## 8. Notes for the coordinator

* **§6 L1 is separable and should be done immediately**, whatever else is decided. It is measured,
  it is cheap, it has no kernel dependency, and every later milestone is more expensive without it.
  It also fixes a latent hazard: today five programs each carry ~2.5 KiB of libc they never call,
  inside a 2 MiB window.
* **§5.8 part 2 (vendor musl's libm and float conversion) is separable from part 3** and should not
  wait on the port decision. It is useful under every outcome.
* **`display-protocol.md` §5.2 should be amended** with §2.6's revision: ffmpeg's libc surface is
  comparable to Cairo's, not an order above it. The paragraph's conclusion is unchanged; one of its
  three numbers is.
* **The `_fstat` gap (a file's size) is one small syscall and it blocks three separate things** —
  `SEEK_END`, `stdio`'s buffering decisions, and any libc port at all. It is the highest
  value-per-line kernel item in this whole document and it is not currently on any roadmap.
  GAP-0122 item 4 named it; nothing has narrowed it.
* **Nothing in this document proposes changing DCDart.** §3.5's conclusion — that the kernel does
  not need floating point and should never get it — is the opposite of a language request, and it is
  deliberate: CLAUDE.md rule 3.
