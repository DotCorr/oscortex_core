# Porting `libdrm` — the measurement

**Status: MEASURED, and partly LANDED.** Everything with a number in it was produced by
`core/tests/conformance/drm-abi/run.sh` against libdrm `773536b1e5dde694dd743815528aff8bb2cf2cc3`
(2.4.134, 2026-08-13) on 2026-08-26, and is re-produced on every run of that harness. The decisions
this document is downstream of are **ADR-0031**; the decision *it* is downstream of is **ADR-0029**.

This is the answer to `drm-abi.md` §8.3 — *"`libdrm` is the right first C library, and it is on the
critical path anyway"* — carried out rather than estimated. `drm-abi.md` marked its own size claim
⚠ *"(not measured — V0 measures it)"*. This is that measurement, and it arrived earlier than V0
because it needed no Mesa and no Linux host.

---

### The findings, for a reader in a hurry

| | finding | where |
|---|---|---|
| **It compiles** | libdrm's five core sources build for `x86_64-unknown-none-elf`, **unmodified**, against `core/user/libc` plus a 28-header shim that declares names and implements nothing. 7,801 lines of somebody else's C, no patch | §1 |
| **43 symbols, and here they are** | The objects need **53** symbols from outside themselves. `core/user/libc` defines **10**. **43 are missing** and they are checked into the repo, diffed on every run | §2 |
| **Four of the ten are the wrong function** | `open`, `read`, `close` and `printf` bind BY NAME and are **not the same functions**. `open` takes one argument here and libdrm passes two or three. **The link is clean.** And `drmIoctl`'s retry loop is written in terms of `errno`, which this OS decided not to have | §3 |
| **The encoding was one line from being silently wrong** | `drm.h` takes its BSD branch on this target. Serving BSD's `_IOC` changes **29 of 121** request numbers, including `GEM_CLOSE`, `SET_CLIENT_CAP`, `SET_MASTER` and `DROP_MASTER` — and leaves the 92 `_IOWR` ones alone, so a ladder would have climbed four rungs before finding out | §4 |
| **A request number is a version, and we watched one move** | `struct drm_syncobj_handle` grew a `__u64` after Linux 6.12, so `DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD` is `0xc018…` in libdrm 2.4.134 and `0xc010…` in 6.12. **A kernel must dispatch on `_IOC_NR` and check `_IOC_SIZE`, never switch on the request word** | §5 |
| **libdrm cannot find a GPU here, whatever the kernel does** | Eight `drmParse*` functions are `#warning` stubs returning `-EINVAL` on any platform libdrm does not know, so `drmGetDevices2()` — how Mesa finds a GPU — fails before the kernel is consulted. **Fixing it means modifying libdrm** | §6 |
| **`modetest` is a much bigger ask than libdrm** | The independently-authored conformance suite needs **76** missing symbols against libdrm's 43, and the extra ones are **pthreads, `poll`, `select` and libm**. libdrm links after a tier-C libc; `modetest` runs only after threads | §7 |
| **libdrm alone does NOT force the substrate** | No threads, no TLS, no futexes, no dynamic linking, no C++. Its 43 are ordinary hosted-libc work. **This is the good news in the report and it is the narrow kind** | §7 |

---

## 0. Method, so the numbers can be re-derived or disbelieved

```
core/user/ports/libdrm/fetch.sh <dir>            # the pinned commit, never vendored
core/user/ports/libdrm/build.sh <dir> <out>      # compile, then count
core/tests/conformance/drm-abi/run.sh            # all of it, plus a boot
```

`build.sh` compiles libdrm's `.c` files with **m19-argv's flags** — the flags every program this OS
has ever built used — minus three, and each subtraction is itself a finding:

* **`-Wall -Wextra -Werror` is dropped.** libdrm does not build clean under it and it is not libdrm's
  job to. `xf86drm.c` alone produces fourteen `-Werror` diagnostics: unused parameters, one
  sign-compare, and **eight `#warning "Missing implementation of drmParse*"`** (§6).
* **`-std=c11` is added.** libdrm's meson sets it.
* **`-D…` is added.** libdrm has no `config.h` in-tree; meson passes the whole configuration on the
  command line and so must we.

The symbol count is `(undefined across all objects) − (defined across all objects)`, so libdrm's own
internal cross-references do not inflate it, minus what `core/user/libc` actually exports — read out
of the compiled `.o` files with `nm`, not out of `oslibc.h`.

**libdrm's build system is not used and cannot be.** `meson.build` line 36:
`if ['windows','darwin'].contains(host_machine.system()) error('unsupported OS')`. A cross build to
this OS would need a meson cross file, a working `pkg-config` and a `dependency('threads')` that
resolves; `build.sh` is 60 lines of `clang` instead. That is a legitimate difference from "how libdrm
is built everywhere else" and it is the reason `gen_table_fourcc.py` is **run** rather than its output
transcribed.

---

## 1. It compiles

| file | lines | compiles for `x86_64-unknown-none-elf` |
|---|---:|---|
| `xf86drm.c` | 5,297 | yes |
| `xf86drmMode.c` | 1,865 | yes |
| `xf86drmHash.c` | 222 | yes |
| `xf86drmRandom.c` | 118 | yes |
| `xf86drmSL.c` | 299 | yes |
| **total** | **7,801** | |

Three of the five compiled on the **first** attempt with nothing but clang's own freestanding
`stdint.h`/`stddef.h`/`stdarg.h`/`limits.h` and a set of stub POSIX headers. The whole of the shim is
**28 headers, none of which contains a function body**:

```
assert ctype dirent errno fcntl inttypes libgen limits math poll pthread
signal stdio stdlib string strings time unistd
sys/{ioccom,ioctl,mman,param,stat,sysmacros,time,types}
linux/types  asm/ioctl
```

`limits.h` is the only one that is not purely additive — it `#include_next`s clang's and adds
`PATH_MAX` (256) and `NAME_MAX`, because clang's freestanding `limits.h` has neither and `xf86drm.c`
declares `char buf[PATH_MAX + 1]` in four places. **`PATH_MAX` is a number this port chose**, and
choosing 256 rather than Linux's 4096 is a decision about stack frames in a 2 MiB address space, not a
transcription. It is recorded in the header.

**What "unmodified" means here, precisely.** `build-progs.sh` refuses to build if `git status` in the
libdrm checkout is non-empty or if `HEAD` is not `PIN.txt`'s commit. So "unmodified" is checked, not
claimed. §6 is where the word will have to be qualified.

---

## 2. The 43

`core/user/ports/libdrm/expected-missing-core.txt`, in full, tiered by **what actually has to work**
rather than by what has to exist. The third column is the libdrm functions that reference the symbol,
attributed by scope from the source.

### Tier 1 — must WORK before an R0–R3 client can do anything (16)

| symbol | why | reached from |
|---|---|---|
| `ioctl` | **the ABI.** GAP-0158. Syscall 12 is reserved for it (ADR-0031 §4) | `drmIoctl`, `drmDMA`, `drmWaitVBlank` |
| `__errno_location` | `drmIoctl` retries `while (ret == -1 && (errno == EINTR \|\| errno == EAGAIN))`. **There is no `errno` on this OS** (GAP-0113) | every `drm*` error path |
| `calloc` | `drmMalloc` is `calloc(1, n)`; every `drmModeGet*` allocates through it | `drmMalloc`, `drmAllocCpy`, `drmDeviceAlloc`, … |
| `realloc` | the atomic request grows | `drmModeAtomicAddProperty`, `drmModeAtomicMerge` |
| `memcmp` | | `drmDevicesEqual` |
| `memmove` | overlapping copy inside the atomic request | `drmModeAtomicCommit` |
| `qsort` | the atomic property list is sorted before it is committed | `drmModeAtomicCommit` |
| `getpagesize` | the atomic request grows by a page's worth of items at a time | `drmModeAtomicAddProperty`, `drmMap` |
| `snprintf` | device paths, sysfs paths, everything | ~12 functions |
| `sprintf` | `drmOpenByName`, `drmOpenMinor` build `/dev/dri/card%d` with it | `drmOpenByName`, `drmOpenMinor`, `drmOpenDevice` |
| `strdup` | `drmGetVersion` copies the driver's name/date/desc out of the ioctl reply | `drmCopyVersion`, `drmGetDeviceNameFromFd2`, … |
| `strncpy` | | `drmModeGetProperty` |
| `strncmp` | | `drmGetNodeType`, `drmNodeIsDRM`, … |
| `strerror` | every diagnostic | `drmError`, `drmGetVersion`, `drmWaitVBlank` |
| `clock_gettime(CLOCK_MONOTONIC)` | vblank and fence timeouts. GAP-0164 | `drmWaitVBlank` |
| `stat` / `fstat` | `drmGetNodeTypeFromFd` needs the device's major/minor to know whether it holds a primary or a render node | `drmGetDevice2`, `drmGetNodeTypeFromFd`, … |

### Tier 2 — must LINK, and is never reached on a render or KMS path (20)

| symbols | reached from | note |
|---|---|---|
| `mknod`, `chmod`, `chown`, `mkdir`, `remove`, `geteuid`, `access` | `drmOpenDevice`, `chown_check_return` | the **X-server** path, where libdrm creates `/dev/dri` and the node itself if root. oscortex will never take it |
| `major`, `minor`, `makedev` | `drmNodeIsDRM`, `drmGetMinorNameForFD`, … | device-number arithmetic. A `dev_t` scheme this OS does not have |
| `opendir`, `readdir`, `closedir` | `drmGetDevices2`, `drmCheckModesettingSupported` | directory enumeration of `/dev/dri` and of sysfs. **Already dead on this platform** — §6 |
| `fopen`, `fclose`, `sscanf`, `getenv` | `drmParse*`, `drmMsg` | sysfs parsing |
| `open_memstream`, `asprintf` | `drmGetFormatModifierName*` | pretty-printing a modifier's name. A `FILE*` that writes into a growing heap buffer — the single most awkward thing on the list to implement, and it is used only by a diagnostic |
| `fprintf`, `vfprintf`, `stderr` | `drmMsg`, `drmError` | libdrm's whole diagnostic channel is `vfprintf(stderr, …)`. `core/user/libc` has no streams (GAP-0113: `RFILE` is read-only and deliberately not called `FILE`) |
| `strcasecmp`, `strncasecmp` | `drmMatchBusID` | |
| `mmap`, `munmap` | `drmMap`, `drmUnmap`, `drmMapBufs` | **the LEGACY DRM map path**, not GEM. A GEM buffer is mapped by the *client* calling `mmap` on the DRM fd at the offset `MAP_DUMB` returned — libdrm does not do it for you. So `mmap` is tier 2 *for libdrm* and tier 1 for anything that uses it (GAP-0159) |

**Tier 2 is 20 symbols that must exist and may `abort`.** That is a real and useful shortcut: a first
link can satisfy them with honest stubs that fail loudly, exactly as
`blocking-and-threads.md` B6's `pthread_create → EAGAIN` does, and nothing on the R0–R3 path will call
them. **It is not a shortcut for `drmGetDevices2`**, because §6 shows that call is broken for a
different reason.

### The seven that are neither, because they are already wrong (§3)

`open`, `read`, `close`, `printf` bind to `core/user/libc`'s and are the wrong function. `malloc`,
`free`, `memcpy`, `memset`, `strcmp`, `strlen` bind and **are** the right function. That is 10 bound,
4 of them wrong.

---

## 3. The four that link and would be wrong

**This is the finding that generalises past libdrm**, and it is the one a symbol count does not
contain.

```
$ x86_64-elf-ld -o /dev/null port/obj/*.o port/libcobj/*.o
  … undefined reference to `ioctl'
  … undefined reference to `__errno_location'
  …  (43 of them, and `main')
```

`open`, `read`, `close` and `printf` are **not** in that list. They resolved.

| | `core/user/libc` | what libdrm calls |
|---|---|---|
| `open` | `unsigned long open(const char *name)` — **one argument**; an 8.3 name in a FAT16 **root directory**; refusals **at or above `FILE_ERR_FLOOR`**; `O_WRITE` means create+truncate+append-only | `open(buf, O_RDWR \| O_CLOEXEC)`, `open(buf, O_RDWR, 0)` — a **path**, two or three arguments, `-1` on failure, `errno` set |
| `read` | `unsigned long read(unsigned long, void *, size_t)`; refusal floor; **`READ_MAX` is 512** | `ssize_t read(int, void *, size_t)`; `-1` on failure |
| `close` | `unsigned long close(unsigned long)` | `int close(int)` |
| `printf` | **five conversions**, 120-byte cap, and one call is one line on the console | libdrm never calls `printf` directly — it is pulled in transitively, and libdrm's real diagnostic path is `vfprintf(stderr, …)`, which does not exist |

**The accidental near-miss is worth naming**, because it is what would make this hard to find:
`core/user/libc`'s refusals are `0xFFFFFFFFFFFFFFF9` and friends, and *as an `int`* those are small
negative numbers. So libdrm's `if (fd < 0)` would appear to work. What would not work is everything
after it: a successful `open` returns 0..3 and the `O_RDWR` argument is silently discarded, so
`drmOpenDevice("/dev/dri/card0", …)` would try to open a FAT16 file whose name is a path, get
`FILE_EBADNAME`, and report it as a plausible-looking negative errno.

**And there is no `errno` at all.** GAP-0113 decided that deliberately — *"the refusal IS the return
value"* — and it is a good decision that `drmIoctl`'s three-line body is incompatible with. This is
not something a bigger libc fixes by accident; somebody has to decide (ADR-0031 §9).

---

## 4. The encoding: one file, 29 request numbers

`include/drm/drm.h`:

```c
#if   defined(__linux__)
#include <linux/types.h>
#include <asm/ioctl.h>
typedef unsigned int drm_handle_t;
#else /* One of the BSDs */
#include <stdint.h>
#include <sys/ioccom.h>
…
typedef unsigned long drm_handle_t;
#endif
```

`__linux__` is not defined for `x86_64-unknown-none-elf` and **this port does not pretend otherwise**,
so the BSD branch is taken and `<sys/ioccom.h>` is ours to write. Writing BSD's real encoding there
compiles, produces identical structs, and changes:

| | |
|---|---|
| requests unchanged | **92** — every `_IOWR`, because `IOC_INOUT` and `_IOC_READ\|_IOC_WRITE` are both `0xC0000000` and the size field starts at bit 16 in both schemes |
| requests changed | **29** |
| `_IOR`/`_IOW` | direction bits **swapped**: BSD `IOC_OUT` = `0x40000000`, Linux `_IOC_READ` = `0x80000000` |
| `_IO` | BSD stamps `IOC_VOID` = `0x20000000`; Linux stamps **zero** |
| struct sizes | **unchanged** — `drm_handle_t` is 4 bytes on one branch and 8 on the other and padding absorbs it in every ioctl struct. Measured |

**The 29 include `GEM_CLOSE` (one of the five core render ioctls), `SET_CLIENT_CAP` (half the whole
negotiation surface), and `SET_MASTER`/`DROP_MASTER`.** The rest are legacy. So the failure mode is:
R0 (`VERSION`) works, `GET_CAP` works, `CREATE_DUMB`/`MAP_DUMB`/`ADDFB2`/`SETCRTC` all work, and then
`GEM_CLOSE` is refused by a kernel that has never heard of `0x80086409`.

`core/tests/conformance/drm-abi/neg-shim/sys/ioccom.h` is that mistake, kept, and the harness runs it
as a negative control on the same boot.

**`xf86drm.h` needs the same treatment and it is easy to miss.** Its non-`__linux__` branch spells the
direction bits `IOC_VOID`/`IOC_OUT`/`IOC_IN`/`IOC_INOUT`, which BSD's header defines and Linux's does
not; `drmCommandRead`/`drmCommandWrite`/`drmCommandWriteRead` — **the entry point for every
per-driver ioctl, which is all eleven virtio-gpu ones** — build their request through those names. Our
`sys/ioccom.h` maps all four onto Linux's three.

---

## 5. A request number is a version, observed

Compiled from Linux 6.12's **own** `include/uapi/drm/*.h` with Linux's **own** `asm-generic/ioctl.h`,
no part of this port involved, and compared against what libdrm 2.4.134's headers produce here:

| | |
|---|---|
| identical | **119 of 121** |
| absent from 6.12 | `DRM_IOCTL_SET_CLIENT_NAME`, `DRM_IOCTL_GEM_CHANGE_HANDLE` |
| **different** | `DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD` `0xc018 64c1` vs `0xc010 64c1`, and `…FD_TO_HANDLE` likewise |

```c
/* libdrm 2.4.134 */                 /* Linux 6.12 */
struct drm_syncobj_handle {          struct drm_syncobj_handle {
    __u32 handle;  __u32 flags;          __u32 handle;  __u32 flags;
    __s32 fd;      __u32 pad;            __s32 fd;      __u32 pad;
    __u64 point;                     };
};
```

**24 bytes instead of 16, and `_IOC_SIZE` carries the size, so the request number moved.** This is
`drm-abi.md` §2.1's warning — *"a mismatch in one struct's size changes the request number silently"* —
happening between two real releases of two real projects, and it is the strongest argument available
for the dispatcher rule in ADR-0031 §4.2: **decode `_IOC_NR`, then check `_IOC_SIZE`. Never
`switch (request)`.** A kernel written as a switch over 32-bit constants would stop recognising
`SYNCOBJ_HANDLE_TO_FD` the day somebody upgrades libdrm, with no compile error anywhere.

**The corollary for the descriptor generator** (`drm-abi.md` §4.2): a descriptor cannot carry *one*
size per request. It has to carry the set of sizes the kernel is prepared to accept, and a policy for
what to do with a short one. Linux's policy is to zero-extend; ours should be to refuse until a
request is deliberately given a second legal size, because zero-extending by default is how a caller's
uninitialised field becomes a kernel default nobody chose.

---

## 6. libdrm cannot enumerate a device here, and that is not the kernel's fault

Eight functions in `xf86drm.c` end in:

```c
#else
#warning "Missing implementation of drmParseSubsystemType"
    return -EINVAL;
#endif
```

`drmParseSubsystemType`, `drmParsePciBusInfo`, `drmParsePciDeviceInfo`, `drmParseUsbBusInfo`,
`drmParseUsbDeviceInfo`, `drmParseOFBusInfo`, `drmParseOFDeviceInfo`, `drmParseFauxBusInfo`. The
`#ifdef` chain above each is `__linux__` (sysfs) / `__OpenBSD__ || __DragonFly__ || __FreeBSD__`
(sysctl or `DRM_IOCTL_GET_PCIINFO`) / **nothing**.

`drmGetDevices2()` and `drmGetDevice2()` are built on them. **That is how Mesa finds a GPU.** So on
oscortex those calls return `-EINVAL` before any ioctl is issued, no matter how complete the kernel's
DRM implementation is.

**The fix is a branch in libdrm, i.e. modifying it**, and ADR-0029 §3's reading B — "unmodified
*source*" — does not cover adding a platform. Three ways out, none free:

1. **Add an `#elif defined(__oscortex__)` upstream.** Correct, small (the OpenBSD branch is ~30 lines
   and uses a single `DRM_IOCTL_GET_PCIINFO`-style ioctl), and it is a real upstream contribution with
   a real review cycle.
2. **Carry a patch.** Cheap now, and it makes every later "unmodified" claim need a footnote.
3. **Have the client not call it.** `modetest -D /dev/dri/card0` and Mesa's `VK_DRIVER_FILES`-style
   overrides bypass enumeration. ⚠ *This is an inference from reading `modetest.c`'s `-D` handling; it
   has not been run.*

GAP-0171. **Whichever is chosen, it should be chosen, not discovered at R3.**

---

## 7. What this costs, and the part that is good news

### 7.1 libdrm alone does **not** force the substrate

The 43 contain **no threads, no TLS, no futexes, no dynamic linking, no C++, and no libm.** They are
ordinary hosted-libc work: the `str*` family, `snprintf`/`sscanf`, `qsort`, the `malloc` family,
`stat`/`opendir`, `mmap`, `clock_gettime`, and an `errno`. That is `libc-roadmap.md`'s tiers A–C.

`drm-abi.md` §8.3 guessed libdrm was small and marked the guess ⚠. **The guess was right**, and this
is the one place in the whole DRM programme where the answer came back cheaper than feared.

### 7.2 `modetest` does force it, and that is the schedule fact

`drm-abi.md` §8.3's argument for libdrm was partly that *"`libdrm`'s own `modetest` and `drmdevice`
tools are a conformance suite for R0–R3 written by somebody else."* Measured:

| | libdrm core | + `modetest` + `tests/util` |
|---|---:|---:|
| objects | 5 | 11 |
| lines | 7,801 | 13,433 |
| external symbols | 53 | 88 |
| **missing** | **43** | **76** |

The 33 extra are the expensive ones:

* **`pthread_create`, `pthread_join`** — `tests/modetest/cursor.c` runs the cursor animation on its own
  thread. This is not a linking artefact; the program does not work without it.
* **`poll`** and **`select`** — `modetest.c` waits for DRM events both ways, in two different places.
  `blocking-and-threads.md`'s `fdwait` (syscall 11) is the primitive and it is unbuilt (GAP-0141).
* **libm** — `fabs`, `roundf`. Small, and there is no libm at all (`libc-roadmap.md` §3).
* `getopt` with `optarg`/`optind`, `strtod`/`strtof`, `gettimeofday`, `usleep`, `getchar`, `abort`,
  `div`, `rand`/`srand`, `time`, `strpbrk`/`strtok`/`strndup`/`strchr`.

**So the honest sequencing is: `libdrm` links after a tier-C libc; `modetest` runs only after
threads and `fdwait`.** The independently-authored conformance suite is real and it is *behind* the
substrate, not in front of it. Anyone planning R0–R3 against "modetest will tell us" should plan
against a program we write instead, and keep `modetest` as the R3+ acceptance test it can be later.

`blocking-and-threads.md` §4.2 concluded "no threads" on the evidence that ffmpeg and libwayland link
mutexes without needing concurrency. `drm-abi.md` §8.1 named Mesa as the counter-example. **`modetest`
is a second and much smaller counter-example**, and it should be added to that argument: a 2,491-line
test program needs real threads.

### 7.3 What is still true from `drm-abi.md` §8.1

Unchanged, and this unit is evidence for it: **the GPU work is not the long pole; the POSIX substrate
is.** Nothing here shortens `ioctl` → device namespace → `mmap` → bigger address space → refcounted
frames → threads → `fdwait`. What it does is remove the *uncertainty* about the first C library: it
compiles, the gap is a list, and the list is 43 long.

---

## 8. What was landed, and what was not

**Landed:**

* `core/user/ports/libdrm/` — `PIN.txt`, `fetch.sh`, `build.sh`, `shim/` (28 headers), and the three
  checked-in symbol lists.
* `core/tests/conformance/drm-abi/` — the harness: fifteen checks, one QEMU boot, one negative control.
  It compiles libdrm, diffs the symbol lists, asserts the four-symbol clash exists, asserts the eight
  `drmParse` stubs exist, computes the request numbers three ways on the host, boots a program built
  against the unmodified uAPI, and requires the guest's fold of all 121 numbers to equal the host's.
* `core/docs/syscall-registry.md` + `core/scripts/verify-syscall-registry.sh` — the allocator
  `design/README.md` fix #2 and `drm-abi.md` §9 asked for. `ioctl` is 12; `fdwait` keeps 11.
* ADR-0031 §4 — the `ioctl` specification, including what is validated and why.

**Not landed, and named so nobody assumes otherwise:**

* **`ioctl` is not implemented.** No kernel file was touched.
* **libdrm is not linked.** 43 short.
* **`modetest` is not linked.** 76 short, and 3 of those are pthreads and `poll`.
* **The full §4.2 descriptor generator is not built** — only the name-table half of it, because
  nothing consumes a descriptor until the dispatcher exists. GAP-0175.

---

## 9. The next rung, and it is small

**S0 — `ioctl`.** ADR-0031 §4 is the specification and the oracle already exists: this unit's
`oracle.py` produces the expected `_IOC` decode from Linux's own headers, and this unit's `prog.c`
already prints a decode from inside a ring-3 process on this kernel. **What S0 adds is the kernel
half and a device to point it at**, and its harness is this one with two more checks.

Nothing about it needs a GPU, a Linux host, or Mesa.
