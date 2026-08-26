# ADR-0033 — `ioctl` is syscall **12** and it is implemented; the libc's four wrong bindings are closed by renaming the native surface to `os_*`; and the POSIX face is a **separate, opt-in translation unit** that is the only place `errno` exists

**Status:** **DECIDED and IMPLEMENTED.** ADR-0031 §4 was a specification; this is that specification
carried out, plus the decision ADR-0031 §9 declined to take.
**Date:** 2026-08-26
**Implements:** ADR-0031 §4 (the `ioctl` specification), §6 (the device name), and `design/drm-abi.md` S0.
**Decides:** ADR-0031 §9's two open questions — `ioctlMaxPayload`'s value (**256**), and *"whether the
libc grows a POSIX face or libdrm gets an oscortex face"* (**a separate, opt-in POSIX face**).
**Closes:** GAP-0158, GAP-0169, GAP-0170. **Narrows:** GAP-0174.
**Records:** GAP-0177 … GAP-0183.
**Verified by:** `tests/conformance/drm-abi/run.sh` — **nineteen checks** (0–17, with a 2b), one boot, one negative
control build, **four mandatory negative controls**, and **four mutations, all killed**.

---

## 1. What is true now that was not

| | before | after |
|---|---|---|
| `ioctl` | does not exist (GAP-0158) | **syscall 12, implemented**, 15 calls issued from ring 3 in the harness |
| a device to call it on | none — every `open` goes to FAT16 | **`/dev/dri/card0` and `/dev/dri/renderD128`**, served from `fileSysOpen` |
| libdrm's missing symbols | **43** | **0.** libdrm's five core objects link completely; `main` is the only undefined symbol left |
| `modetest`'s missing symbols | 76 | **32**, and the remainder is exactly the expensive set: pthreads, `poll`, `select`, libm |
| `open`/`read`/`close`/`printf` | **bind by name and are the wrong functions** (GAP-0170) | the native surface is `os_*`; linking a port against it alone leaves all four **undefined** |
| `errno` | does not exist, and `drmIoctl` is written in terms of it | **exists in `posix.c` and nowhere else** |

**And one thing that is deliberately NOT true: no DRM semantics are implemented.** §5 and GAP-0177.

---

## 2. The libc's four wrong bindings, and the `errno` call

### 2.1 What was wrong

`libdrm` needs `open`, `read`, `close` and `printf`. `core/user/libc` defined all four, under those
exact names, with different signatures and a different error convention. **`x86_64-elf-ld` resolved
all four without a word.** The near-miss is what made it dangerous: our refusals are
`0xFFFFFFFFFFFFFFF9` and friends, which *as an `int`* are small negative numbers, so libdrm's
`if (fd < 0)` would appear to work — and then a successful `open` returns 0..3, the `O_RDWR` argument
is silently discarded, and `drmOpenDevice("/dev/dri/card0", …)` opens a FAT16 file whose name is a
path.

### 2.2 The decision

**THE NATIVE SURFACE IS RENAMED TO `os_*`. THE POSIX FACE IS A SEPARATE, OPT-IN TRANSLATION UNIT.**

* `core/user/libc/oslibc.h` exports `os_open`, `os_read`, `os_close`, `os_printf`, `os_write`, and
  keeps the short spellings for its own callers as four `#define`s stated in the header rather than
  hidden. **No existing program changed by one character.**
* A port that does **not** include `oslibc.h` — which is every port, because ported C includes
  `<fcntl.h>` and `<unistd.h>` — now gets an **undefined reference** and cannot link.
* `core/user/libc/posix.h` + `posix.c` is the POSIX-shaped surface a port links **on purpose**:
  `open(path, flags, …)`, `read`, `write`, `close`, `lseek`, `ioctl`, and `errno`.
* `core/user/libc/port.c` is the tier-1 C functions with no kernel behind them.

**A mismatch that used to link silently is now a link error, and the harness requires it:** CHECK 2
links libdrm against the *native objects alone* and fails if `open`, `read`, `close` or `printf`
resolves.

### 2.3 `write` was a fifth, and the compiler found it, not a reviewer

GAP-0170 named four. When `posix.c` tried to define POSIX's
`ssize_t write(int, const void *, size_t)`, clang refused outright — *"conflicting types for
`write`"*, against oscortex's two-argument `unsigned long write(const void *, size_t)`. **The clash
was not merely latent; it blocked the adapter.** `write` is therefore `os_write` too.

**`exit` and `sbrk` are a sixth and seventh and are deliberately left alone.** Neither is reached by
libdrm, neither blocks `posix.c`, and both are *measured* in GAP-0178 rather than changed by a unit
that was not asked to. **That is where the evidence stopped, not where the work got tiring.**

### 2.4 `errno` — the hard half

GAP-0113 decided this OS has no `errno`, deliberately: *"the refusal IS the return value."* That is a
good decision. It is also one `drmIoctl`'s entire body is written in terms of:

```c
do { ret = ioctl(fd, request, arg); } while (ret == -1 && (errno == EINTR || errno == EAGAIN));
```

**Both are kept.** `errno` is one `int` in `posix.c`'s `.bss`, reached through `__errno_location()`,
written by exactly one function, and derived from the kernel's refusal by one visible mapping
(`posix_errno_for`). **Nothing in `core/kernel/` learned the word.**

**And the retry loop is made provably one-shot rather than emulated.** Nothing on this OS can return
`EINTR` — there is no signal delivery mechanism at all. Nothing can return `EAGAIN` — no descriptor is
non-blocking, because no syscall blocks. So `posix_errno_for` maps **no** oscortex refusal onto either
value, the `while` condition is false on its first evaluation, always, and the loop executes its body
exactly once. That is not a workaround; it is the loop doing what it was written to do on a platform
where the conditions it retries on cannot arise. **GAP-0179 records that this becomes false the day
this OS grows signals or non-blocking descriptors**, because a retry loop that silently starts
spinning is worse than one that never did.

### 2.5 What was rejected

| | | verdict |
|---|---|---|
| **A** | make the **kernel** return `-1` and carry an `errno` | **REJECTED**, and ADR-0031 §4.1 rejects it by name. Eleven `ioctl` refusals and fourteen file refusals would collapse to one number, and every harness that reads a specific refusal out of a transcript would be reading `-1` |
| **B** | give `oslibc.h` a POSIX-shaped second surface under **second names** (`posix_open`) | **REJECTED — it does not solve the problem.** Ported C calls `open`, not `posix_open`, so the clashing symbol would still be `open` and would still bind to the wrong function. A fix that requires editing the port is not a fix for a port we compile unmodified |
| **C** | keep the clash and **refuse to link the two together** | **REJECTED as insufficient rather than wrong.** It is half of what this ADR does, but on its own it leaves the port dead and closes GAP-0170 by abandoning the thing that opened it |
| **D** | an `__asm__("os_open")` **label** on the declaration, keeping the spelling and changing the symbol invisibly | **REJECTED on this repo's own precedent.** M16 named a function `fdwrite` rather than overloading `write`, because *"two functions called `write` distinguished only by how many arguments they have would be the kind of thing that compiles and then does the wrong one."* An assembler label that renames a symbol with no trace at the call site is that same invisibility, pointed at the linker |

---

## 3. `ioctl` — what was built

`core/kernel/ioctl.dart`, one `@bss` block of 512 bytes, **last in `.bss`** — checked against
`kmain.o`'s symbol table, not promised. §6.3(a) records why "last" turned out not to be the whole of
what ADR-0021's arithmetic needed.

ADR-0031 §4.3's seven rules are applied in §4.3's order. Two of those orderings are load-bearing:

* **`_IOC_TYPE` is checked before `_IOC_SIZE` or `_IOC_DIR` are used for anything.** A kernel that
  decoded size and direction first would be doing arithmetic on a word it has not established is for
  it. The harness requires a bad type on a *served* nr to be `ioctlRetBadType`, not `ioctlRetBadNr`.
* **Both validators run before either copy on an `_IOWR`.** Validating the read side, copying in, then
  validating the write side would leave a window in which the kernel has already acted on a request it
  has not finished checking.

**The dispatch is on `_IOC_NR`, never on the request word.** `ioctlDescFind` takes `(type, nr)` and is
never handed the request — the API is the argument. The descriptor carries a **set** of legal sizes,
and the harness serves both `0xc01864c1` (libdrm's 24-byte `drm_syncobj_handle`) and `0xc01064c1`
(Linux 6.12's 16-byte one) through **one row**. A `switch (request)` kernel serves exactly one.

**The driver is handed an offset into the bounce buffer and a length, and is never handed `argp`.**
That is ADR-0031 §4.3 rule 5 enforced by the signature rather than by discipline: there is no ring-3
address in scope in `ioctlDevServe` or anything it calls.

### 3.1 `ioctlMaxPayload` is **256**, and here is the argument

ADR-0031 §9 left it open, saying *"one page is the natural first value"*. The measured largest DRM
payload across all 121 requests is **248 bytes**, so 256 is the smallest power of two that serves the
whole measured ABI. A page would be 4096 bytes of `.bss` no measured request can fill — and, because
of §4 below, 32 validator calls where 2 suffice. It is well under the encoding's 14-bit ceiling of
16383, and the harness requires `ioctlMaxPayload < ioctlEncMaxSize` and `ioctlMaxPayload >= 248`.

### 3.2 The refusals occupy a band of their own

`0xE0..0xEF`, below `file.dart`'s `0xF1..0xFE`. ADR-0031 §4.3 rule 7 asks for `ioctl` on a FAT16 file
to be a *distinct* refusal; a band makes that mechanical rather than promised, and the harness parses
both files and fails on any value in both sets.

### 3.3 The device namespace

`/dev/dri/card0` and `/dev/dri/renderD128`, **literally**, per ADR-0031 §6. The branch is in
`fileSysOpen`, **after** the pointer-validated bounce-buffer copy and **before** `fatParseAt` — never
in `fatLookup`, where `fileMakeEmpty` would treat the device name as a directory entry and truncate
and rewrite it. **That is a ring-3-reachable volume corruption** and it is avoided by *where the block
sits*.

`fileSysOpen`'s outer length bound moved from `fileNameMax` (12) to `ioctlDevNameMax` (24), because
`/dev/dri/renderD128` is nineteen characters. **The FAT bound was not relaxed** — it moved down into
the non-device arm, and `fatParseAt` is reached only through that arm.

A `/`-name that is not a served device is `fileRetNotFound` and is **never retried as a FAT name**;
falling through would turn a missing device into a plausible 8.3 parse failure. The harness checks
that specific refusal.

---

## 4. Where this DEPARTS from ADR-0031 §4, and it is one place

**ADR-0031 §4.3 rule 4 says `ioctl` uses M16's two validators "unchanged". It cannot, quite, and this
is the honest statement of why.**

`elfOwns` refuses any length above `userWriteMax` (**128**); `fileOwnsWrite` refuses any above
`fileReadMax` (**512**). Those numbers are the **policy bounds of their original callers** —
`write`'s console limit and `read`'s per-call limit — folded into the validators years before `ioctl`
existed. They are not properties of the page walk, which is the part `ioctl` needs and the part
GAP-0124 mutation-tested.

So a 248-byte `DRM_IOCTL_GET_STATS` — the measured largest DRM payload — passes rule 2's
`ioctlMaxPayload` check and is then refused by `elfOwns` **for being longer than a console write**.
Reporting that as `ioctlRetBadPtr` would be a length problem wearing a pointer problem's name, which
is precisely the class of silent wrongness this unit exists to close.

| | | verdict |
|---|---|---|
| **A** | raise `elfOwns`' cap | **REJECTED.** `userSysWrite` relies on that cap to enforce `userWriteMax`; raising it would silently let `write` print more than 128 bytes, and would weaken a mutation-tested validator to serve a caller it knows nothing about |
| **B** | write `ioctl`'s own page walk | **REJECTED, and it is the tempting one.** Twenty lines, and a **second implementation** of the check GAP-0124 exists to keep correct — a third silent-wrongness path in a unit whose brief was not to leave one |
| **C** | **window the range and call the unchanged validator on each window** | **CHOSEN.** `elfOwns([p, p+128))` walks every page of that sub-range; consecutive sub-ranges covering `[argp, argp+size)` walk every page of the union, which is exactly what a whole-range call would have walked. The validators are not touched, not copied and not weakened, and ioctl's own bound is re-imposed by rule 2 first |

---

## 5. What this does NOT claim

**There is no GPU, no DRM driver, and no DRM semantics whatsoever.** `ioctlDevServe` fills the
read-side payload with a deterministic pattern derived from the descriptor and device indices, which
the harness predicts from outside the kernel. **What works is the MEMBRANE** — decode, validate,
bounce, dispatch on `_IOC_NR`, refuse on skew — and the membrane is the rung `design/drm-abi.md` S0
asked for. GAP-0177 states that so that nobody reads "ioctl works" as "DRM works".

**The descriptor table is six rows, hand-written.** `design/drm-abi.md` §4.2 wants a generator;
ADR-0031 §7 built the name-table half and GAP-0175 recorded that the descriptor half was not built
because nothing consumed a descriptor. Something does now. Six rows exercise every direction, both the
single-size and the multiple-size cases, and the version-skew case — and **six rows written by hand
produced one wrong number**: `struct drm_auth` is 4 bytes on this branch, not 8, and this table said 8
until the value was read out of a compiled object. That is the argument for the generator, made by
this unit against itself. GAP-0177.

**`mmap` still does not exist** (GAP-0159), **`drmGetDevices2()` still cannot work** whatever the
kernel does (GAP-0171), and **`modetest` still needs threads** (GAP-0173).

---

## 6. The evidence

### 6.1 The four mandatory negative controls, with the observed value

| control | expected | **observed** |
|---|---|---|
| oversized payload (`_IOWR('d',0x00,4096)`) — **refused, not truncated** | `ioctlRetBadSize` | **`ffffffec`**, and **no `IOCTL OK` line** |
| wrong-size request (`_IOWR('d',0x00,48)`, served only at 64) — **refused, not zero-extended** | `ioctlRetSizeSkew` | **`ffffffe8`**, and no `IOCTL OK` line |
| `argp` outside the process (a kernel address, and a range straddling an unmapped page) | `ioctlRetBadPtr` | **`ffffffea`** for both |
| write-side violation on `_IOC_READ` (`GET_MAGIC` at `.rodata`) | `ioctlRetBadPtr` | **`ffffffea`**, with the writable-memory **positive** control returning **0** beside it |

Plus: `_IOWR` at `.rodata` → `ffffffea`; bad type → `ffffffed` (before bad nr); bad nr → `ffffffe9`;
`ioctl` on a FAT16 file → `ffffffee`; closed descriptor → `ffffffef`.

**Anti-vacuity:** the `_IOC_WRITE`-only `GEM_CLOSE` printed `IOCTL OK IN 0008 OUT 0000` — the in- and
out- counts **differ**, which ADR-0031 §4.4 asks for by name. A kernel ignoring `_IOC_DIR` would print
the same number twice.

### 6.2 Four mutations, all killed — **and the third one found a hole in the tests**

| mutation | result |
|---|---|
| truncate an oversize payload instead of refusing | **killed** |
| accept a short struct and zero-extend it | **killed** — `NEG WRONGSIZE ret=0` |
| **drop the write-side validator from the `_IOWR` arm** | **SURVIVED at first.** The whole suite stayed green |
| swap the direction validators on `_IOC_READ` | **killed** |

**The third mutation is the most useful result in this unit.** Both existing `argp` controls aimed at
memory that fails the *read*-side validator too, so a kernel running only the read side refused them
and looked correct. The discriminator is an `_IOWR` aimed at `.rodata`: ring 3 may read it, so the
read side passes, and only the write side can refuse. That control now exists, and with it the
mutation is killed. **It was found by mutation and not by reading, which is the whole argument for
mutating rather than admiring.**

### 6.3 Two places where ADR-0031's own text was imprecise, found by the suite

**Neither is a defect in the specification's intent. Both are recorded because the next person to
read §4 should not have to rediscover them.**

**(a) "It goes LAST in `.bss` so that every existing harness's 'bytes from my block to the end'
arithmetic is unchanged" (§4.3 rule 5) is not quite true.** Last is **necessary but not sufficient**.
The block that *was* last has a to-the-end measurement of its own, and a new block after it changes
exactly that number — `argsStore`'s went **256 → 768**, and **twelve harnesses** said so. The
established remedy was already in the repo and this unit followed it: each new block adds its own
subtraction step *first*, exactly as M14, M15, M16 and M19 each did in turn. The rule should read
*"…so that every EARLIER block's arithmetic is unchanged, and the previously-last block gets a new
subtraction step."*

**(b) §4.3 rule 2 does not say what to do with `_IOC_NONE` and a non-zero size.** It specifies
"non-zero for any direction other than `_IOC_NONE`, and at most `ioctlMaxPayload`", which leaves the
combination undefined. **This kernel refuses it** (`ioctlRetBadSize`), because there is no direction
to copy such a payload in and treating it as "no payload after all" would be a silent
reinterpretation of what the caller asked for. It is not hypothetical: BSD's `IOC_VOID` is
`0x20000000`, which lands **inside Linux's size field**, so `SET_MASTER` under the wrong encoding
arrives as dir 0 with size 8192 — and the negative-control build proves the kernel refuses it.

### 6.4 One more thing the suite caught, and it is GAP-0088 exactly

The descriptor accessors were first written keyed on a **dense** index 0..5. LLVM turned all three
`if` chains into **lookup tables in `.rodata`** — 100 bytes of them — and `m1-interrupts` failed:
that harness requires `kmain.o`'s `.rodata` to be *"elements only, no header"* (ADR-0040), every byte
belonging to a declared `@rodata` table. **A compiler-generated table in a section this repo does not
control is GAP-0088**, and writing "a chain of comparisons each ending in `return`" is not by itself
enough — the *keys* must be sparse, which is why `fileFromFat`'s chain over `fatErr*` constants was
never affected.

The fix is that **the descriptor index IS the `_IOC_NR`**: keys `0x00 0x02 0x09 0x0C 0x1E 0xC1`, a
span of 194 for six values. It is also simply truer — the intermediate index was a second name for a
command number. **The sparsity is now load-bearing**, and adding rows until the keys are dense would
bring the tables back; `m1-interrupts` is what would say so.

### 6.5 Freestanding and the suite

`verify-freestanding.sh` passes on `kmain.o`, `kdata.o`, `portio.o` and `kernel.elf`.
`verify-syscall-registry.sh`: 12 allocated, 1 reserved (11 = `fdwait`), no number claimed twice.

**Nineteen goldens moved by ADDRESSES ONLY** — verified with GAP-0095's tokenised method, every run
of six or more hex digits replaced by a token and the results compared, not read by eye.

**Three moved by more than addresses, and all three are the same 48 bytes.** `malloc.c` grew one
function — `malloc_usable`, 19 bytes of code, which `realloc` needs to copy a safe length instead of
over-reading the old block — and with alignment every program that links `malloc.o` grew `0x30`.
`m14-fat`'s and `m16-filewrite`'s test programs each crossed a cluster boundary as a result
(`FS CHAIN LEN 000A → 000B` and `0011 → 0012`), and `m15-fileio`'s and `m16-filewrite`'s self-hash
lengths moved by the same 48. Nothing else in any of the three transcripts changed. GAP-0182 records
it.

`drm-abi`'s golden moved by **pure insertion** — every pre-existing line is byte-identical, checked with
GAP-0095's tokenised method, not by eye.

---

## 7. Consequences and reversibility

**Reversibility is lower than ADR-0031's, and honestly so.** ADR-0031 touched no kernel file; this one
adds `core/kernel/ioctl.dart`, a `part` line, a dispatch arm, an exit-report call, two constants and a
branch in `fileSysOpen`. Reversing it means removing those. The libc rename is the least reversible
part, because it changes symbols five files' worth of programs resolve against — though not one
program's *source*.

**The `os_*` rename is a change every future port inherits**, and it is the thing that makes ports
safe by default rather than by review.

---

## 8. What this ADR does not decide

* **Whether the descriptor table becomes generated.** GAP-0177. It should, and this unit produced the
  evidence, but building the generator was not this unit's scope and doing it badly would be worse
  than the six honest hand-written rows.
* **Whether `exit` and `sbrk` join the `os_*` rename.** GAP-0178.
* **What a real DRM driver behind `ioctlDevServe` looks like.** That is R0 and it needs GAP-0159's
  `mmap`, which needs refcounted frames.
