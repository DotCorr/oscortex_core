# ADR-0031 — `libdrm` is the first C library this OS is pointed at, it is built from unmodified source against a shim header set, it serves **Linux's** `_IOC` encoding, and `ioctl` is syscall **12**

**Status:** **DECIDED and PARTLY IMPLEMENTED.** The port scaffolding, the encoding choice, the syscall
registry and the conformance harness are built and green. **`ioctl` itself is designed here and is not
implemented** — §4 is a specification, not a description. Nothing in `core/kernel/` was changed by this
unit.
**Date:** 2026-08-26
**Ratifies:** `design/drm-abi.md` §8.3 and its **Q4** ("Is `libdrm` accepted as the first C library
this OS links, ahead of Mesa?" — **yes**), under ADR-0029.
**Design:** `design/libdrm-port.md` — the measurement, symbol by symbol.
**Builds:** `design/README.md` fix #2 and `design/drm-abi.md` §9's "a syscall-number registry —
**build it in S0**" → `docs/syscall-registry.md` + `scripts/verify-syscall-registry.sh`.
**Corrects:** `design/drm-abi.md` S1's `:DRI0` device name — see §6.
**Records:** GAP-0169 … GAP-0175.
**Verified by:** `tests/conformance/drm-abi/run.sh` — fifteen checks, one boot, one negative control.

---

## 1. The decision, in full

1. **`libdrm` is the first C library this operating system is pointed at**, ahead of Mesa and ahead of
   ffmpeg. `design/drm-abi.md` §8.3 argued it and this ratifies it.
2. **It is built from unmodified upstream source, fetched at a pinned commit, never vendored.**
   `core/user/ports/libdrm/PIN.txt` is the pin; `fetch.sh` is the only thing that turns it into files;
   a harness that cannot fetch reports a **setup error**, not a failure.
3. **The POSIX surface it compiles against is a SHIM HEADER SET that declares names and implements
   nothing** — `core/user/ports/libdrm/shim/`, 28 headers. **A declaration there is a measurement, not
   a promise**: anything it declares and `core/user/libc` does not define shows up in
   `nm --undefined-only` and is counted.
4. **The `_IOC` encoding this port serves is LINUX's, and it is served from our own
   `sys/ioccom.h` rather than by defining `__linux__`.** §3 is the measurement that forced this.
5. **`ioctl` is syscall 12**, allocated by `docs/syscall-registry.md`, which this unit built.
   `fdwait` keeps 11. §4 specifies the syscall; §5 is why 12.
6. **The device the DRM ABI is reached through is named `/dev/dri/card0` and `/dev/dri/renderD128`,
   literally** — not `design/drm-abi.md` S1's `:DRI0`. §6.
7. **`gen-table.py` is the first instance of `design/drm-abi.md` §4.2's descriptor generator**, and it
   is a build-time table generator **in this repo**, not a DCDart language feature. §7.

---

## 2. What was measured, because this ADR is downstream of a measurement

Everything in this section was produced by `tests/conformance/drm-abi/run.sh` on 2026-08-26 against
libdrm `773536b1` (2.4.134) and is re-produced on every run.

| | measured |
|---|---|
| libdrm's five core sources compile for `x86_64-unknown-none-elf`, **unmodified** | **yes** — `xf86drm.c`, `xf86drmMode.c`, `xf86drmHash.c`, `xf86drmRandom.c`, `xf86drmSL.c`, 7,801 lines |
| external symbols those objects need | **53** |
| of which `core/user/libc` defines (47 exported symbols) | **10** |
| **of which are the WRONG FUNCTION** | **4** — see §2.1 |
| **missing outright** | **43** |
| with `modetest` + `tests/util` (6 more objects, 5,632 lines) | **88 external, 76 missing** |
| `#warning "Missing implementation of drmParse*"` emitted | **8** |
| `DRM_IOCTL_*` requests in `drm.h` + `virtgpu_drm.h` | **121** |
| identical to Linux 6.12's own headers under Linux's own `_IOC` macros | **119** |
| changed by taking BSD's `_IOC` encoding instead | **29** |

**The 43 are in `core/user/ports/libdrm/expected-missing-core.txt` and the harness diffs against it.**
The list is the deliverable. `design/libdrm-port.md` §2 tiers it into *must work*, *must link*, and
*modetest only*.

### 2.1 The four that link and are the wrong function — this is the sharpest finding

`open`, `read`, `close` and `printf` are in **both** sets. libdrm needs them; `core/user/libc` has
them. **They are not the same functions, the link is clean, and the program would be wrong.**

| | `core/user/libc` | what libdrm calls |
|---|---|---|
| `open` | `unsigned long open(const char *name)` — **one argument**, an 8.3 name in a FAT16 root directory, refusals **at or above `FILE_ERR_FLOOR`** | `open(path, O_RDWR \| O_CLOEXEC)` and `open(path, O_RDWR, 0)` — a **path**, **two or three arguments**, `-1` on failure with `errno` set |
| `read` | `unsigned long read(unsigned long fd, void *, size_t)`, refusal floor, `READ_MAX` 512 | `ssize_t read(int, void *, size_t)`, `-1` on failure |
| `close` | `unsigned long close(unsigned long fd)` | `int close(int)` |
| `printf` | **five conversions**, 120-byte cap, one call is one line on the console | libdrm's own `drmMsg` goes through `vfprintf(stderr, ...)`, which does not exist here at all |

**And there is no `errno`.** `drmIoctl` is
`do { ret = ioctl(...); } while (ret == -1 && (errno == EINTR || errno == EAGAIN));` — the retry loop
at the very centre of the DRM ABI is written in terms of a variable this OS decided not to have
(GAP-0113: *"the refusal IS the return value"*). **`__errno_location` is in the missing 43 and it is
not a formality.**

This is recorded as GAP-0170 and the harness asserts the hazard exists rather than leaving it to be
discovered by a wrong answer at run time.

---

## 3. The encoding, and why it is not the default

**`include/drm/drm.h` line 38 is `#if defined(__linux__)`.** On `x86_64-unknown-none-elf` that is
false, so the header takes its **"one of the BSDs"** branch, which reaches for `<sys/ioccom.h>` and
uses whatever `_IOWR` it finds there. **The encoding is therefore entirely ours to choose, and
choosing wrong is silent**: the header compiles, every struct is byte-identical, and the request
numbers are different.

Measured, across all 121 requests:

| | BSD vs Linux |
|---|---|
| `_IOWR` (both directions) | **identical**, all 92 of them |
| `_IOR` / `_IOW` | **the direction bits are swapped** — BSD `IOC_OUT` is `0x40000000` where Linux `_IOC_READ` is `0x80000000` |
| `_IO` (no payload) | BSD stamps `IOC_VOID` (`0x20000000`); Linux stamps **zero** |
| the size field | 13 bits on BSD, 14 on Linux — **no DRM struct is large enough for that to show** |
| struct sizes | **unchanged**. `drm_handle_t` is `unsigned int` on the Linux branch and `unsigned long` on the BSD one, and padding absorbs the difference in every ioctl struct |

**29 of 121 differ, and they are not all legacy:**

```
GEM_CLOSE  SET_CLIENT_CAP  SET_MASTER  DROP_MASTER  GET_MAGIC  AUTH_MAGIC
SET_UNIQUE  MODESET_CTL  GET_STATS  CONTROL  LOCK  UNLOCK  FINISH  MOD_CTX
NEW_CTX  SWITCH_CTX  SET_SAREA_CTX  MARK_BUFS  FREE_BUFS  RM_MAP  SG_FREE
UPDATE_DRAW  AGP_ACQUIRE  AGP_RELEASE  AGP_ENABLE  AGP_INFO  AGP_FREE
AGP_BIND  AGP_UNBIND
```

**`GEM_CLOSE` is one of the five core render ioctls** (`design/drm-abi.md` §2.2). `SET_CLIENT_CAP` is
half of the whole negotiation surface. `SET_MASTER`/`DROP_MASTER` are how a compositor takes the
primary node. Serving BSD numbers would have failed exactly there and nowhere else — the 92 `_IOWR`
requests, which is most of what a rung-by-rung ladder tries first, would all have worked.

### 3.1 Two ways to fix it, and why the second

| | | verdict |
|---|---|---|
| **A** | compile with `-D__linux__=1` so `drm.h` takes its Linux branch | **REJECTED.** It is a lie about the platform with a blast radius: `xf86drm.c` has dozens of `#ifdef __linux__` blocks, and they turn on sysfs walking, `/sys/dev/char/%d:%d/device`, `realpath`, udev and `/proc`. We would be claiming a Linux personality to get four bits right — the exact thing ADR-0029 §3 rejected by name |
| **B** | supply our own `<sys/ioccom.h>` that implements **Linux's** `_IOC` | **CHOSEN.** Six lines. `drm.h` keeps its non-Linux branch, so all the sysfs code stays compiled out, and the encoding is stated in one file we own. `xf86drm.h`'s non-Linux branch spells the direction bits `IOC_VOID`/`IOC_OUT`/`IOC_IN`/`IOC_INOUT`, so that file maps those four onto Linux's three as well |

**`core/tests/conformance/drm-abi/neg-shim/sys/ioccom.h` is BSD's real encoding, kept as the negative
control.** The control build is the same `prog.c` with that directory first on the include path; it
must produce the same request *count* and a different *hash*, and the harness requires the
disagreement to be exactly the 29 above.

### 3.2 The version-skew finding, which is the reason §4's dispatcher rule exists

Of the 121, **119 are byte-identical** to what Linux 6.12's own `include/uapi/drm/*.h` produce under
Linux's own `asm-generic/ioctl.h`. Two are not:

```
DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD   libdrm 2.4.134: 0xc01864c1    Linux 6.12: 0xc01064c1
DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE   libdrm 2.4.134: 0xc01864c2    Linux 6.12: 0xc01064c2
```

`struct drm_syncobj_handle` **grew a `__u64 point` field** after 6.12: 16 bytes became 24, and
`_IOC_SIZE` carries the size, **so the request number changed**. Two more requests
(`DRM_IOCTL_SET_CLIENT_NAME`, `DRM_IOCTL_GEM_CHANGE_HANDLE`) do not exist in 6.12 at all.

**This is `design/drm-abi.md` §2.1's warning happening in the wild, between two real releases, and it
settles a design question:** a kernel serving this ABI **must dispatch on `_IOC_NR` and inspect
`_IOC_SIZE`**, never switch on the whole 32-bit request word. A `switch (request)` written against
today's libdrm would stop recognising `SYNCOBJ_HANDLE_TO_FD` the day somebody upgrades it.

---

## 4. `ioctl` — the specification. **This is not implemented.**

### 4.1 The call

```
    ioctl(fd, request, argp) -> 0 or a refusal at or above ioctlRetFloor
       RAX = 12        RDI = fd        RSI = request       RDX = argp
```

`sys_call3` already exists and already carries three arguments; **`ioctl` adds no new instruction to
`core/user/libc`** (m13-libc requires exactly one `int $0x80` in the whole library and this keeps it).

The return convention is `file.dart`'s, not POSIX's: **one comparison against a floor separates a
result from a refusal**, exactly as `FILE_ERR_FLOOR` and `SBRK_ERR_FLOOR` do, and for the reason
ADR-0016 gave. A libc `ioctl()` shim that presents libdrm's expected `-1`-and-`errno` face is a
**libc** problem (GAP-0170), not a kernel one, and it must not be solved by making the kernel return
`-1`: this kernel's whole refusal discipline is that a refusal is a distinct value carrying a reason.

### 4.2 The decode — four fields, and the direction is from **userspace's** point of view

```
   bit  31 30 | 29 ............ 16 | 15 ...... 8 | 7 ...... 0
        dir   |       size         |    type     |     nr
        (2)   |       (14)         |     (8)     |     (8)
```

* `_IOC_DIR`  — `0` none, `1` `_IOC_WRITE`, `2` `_IOC_READ`, `3` both.
  **`_IOC_WRITE` means userspace writes the payload and the kernel reads it; `_IOC_READ` means the
  kernel writes and userspace reads.** Getting this backwards is the classic bug and it is
  *invisible* on an `_IOWR` — which is 92 of the 121 requests. The harness's negative control targets
  it.
* `_IOC_SIZE` — 14 bits, so **16383 is a hard ceiling** and the kernel needs no other bound to be
  safe from a wrapped length. Measured: the largest DRM payload is **248 bytes**
  (`DRM_IOCTL_GET_STATS`), and **4 of 121 requests carry no payload at all** —
  `SET_MASTER`, `DROP_MASTER`, `AGP_ACQUIRE`, `AGP_RELEASE`.
* `_IOC_TYPE` — `'d'` (0x64) for every DRM request. A request of another type is not ours.
* `_IOC_NR`   — the command number. `0x00`–`0x3F` core, `0x40`–`0x9F` per-driver, `0xA0`–`0xBC` KMS,
  `0xBF`–`0xCD` syncobj.

### 4.3 What is validated, and why each one

**The kernel already enforces W^X, NX, SMEP and a ring-3 boundary. An unvalidated pointer or length
from ring 3 hands all of that back**, because the kernel copies with kernel privilege: a `memcpy` into
an address ring 3 named is a write ring 3 could not have performed itself. So:

1. **`_IOC_TYPE` must be a type this kernel serves.** Anything else is refused before any other field
   is looked at. A kernel that decoded size and direction first would be doing arithmetic on a word it
   has not established is for it.
2. **`_IOC_SIZE` must be non-zero for any direction other than `_IOC_NONE`, and at most
   `ioctlMaxPayload`.** `ioctlMaxPayload` is a *kernel* constant well below 16383 — one page is the
   natural first value — and a request above it is **REFUSED, NEVER TRUNCATED**. Truncating turns a
   too-large request into a *successful* one that read the wrong number of bytes, and the caller has
   no way to notice.
3. **`_IOC_SIZE` must equal the size the descriptor for that `(type, nr)` records** — for the requests
   the kernel serves. This is the §3.2 finding made into a rule: the size is *in* the request number,
   so checking it is checking that both sides agree about the struct. Where a request has more than
   one legal size across uAPI versions, the descriptor carries the set, and a size not in it is
   refused. **It is refused, not accepted-and-zero-extended**: Linux's own extension rule is the
   kernel's to implement deliberately, per request, not a blanket "shorter is fine".
4. **`argp` must pass the *existing* mutation-tested validators.** M16 has two — a read-side and a
   write-side — and `elfOwns` walks **every page** of the range, not the first (GAP-0124 is why:
   m15-fileio aims a read at a range that straddles the last mapped page and the unmapped one after
   it, on purpose). `ioctl` uses them unchanged:
   * `_IOC_WRITE` ⇒ the read-side validator over `[argp, argp + size)`;
   * `_IOC_READ` ⇒ the **write**-side validator over the same range — the stricter one, because the
     kernel is about to write there;
   * `_IOWR` ⇒ **both**, and both before either copy.
5. **The copy goes through a bounce buffer in the kernel's own `.bss`, never in place.** Two reasons,
   and the second is the load-bearing one:
   * the validated range must not be re-read after validation from a page another CPU or another
     process could have changed — this kernel is uniprocessor today and will not always be;
   * **the driver must never hold a pointer into ring 3's address space.** A driver that dereferences
     `argp` directly is one page-table switch away from reading somebody else's memory, and the
     compiler will not stop it. The bounce buffer makes that structurally impossible rather than
     merely discouraged. It is `ioctlMaxPayload` bytes, one block, and — per ADR-0021 — it goes
     **last** in `.bss` so that every existing harness's "bytes from my block to the end" arithmetic
     is unchanged.
6. **The out-copy happens only on success.** A refused request must not write anything into the
   caller's buffer: a program that reads its `argp` after a refusal must find what it put there, not
   half a kernel structure.
7. **A descriptor that is not a device is `ENOTTY`'s equivalent.** `ioctl` on a FAT16 file is a
   distinct refusal from every `file.dart` refusal, so `m15-fileio` and `m16-filewrite` keep meaning
   what they meant.

### 4.4 The binary exit criterion, when it is built

Restating `design/drm-abi.md` S0 with what this unit learned:

*A C program issues an `_IOWR('d', 0x00, struct drm_version)`-shaped call against a test device. The
kernel prints the decoded direction, size, type and number, and the harness requires all four to equal
values **computed by the harness from the `_IOC` macros transcribed from
`include/uapi/asm-generic/ioctl.h`**, not read back out of the kernel.*
**Add:** the harness already has that oracle — `tests/conformance/drm-abi/oracle.py` produces it from
Linux's own headers today, and the program that prints the decode already exists and already boots.
*Anti-vacuity:* the printed size must not be zero, and the in- and out-direction byte counts must
differ for a `_IOC_WRITE`-only call.
*Negative controls, all four of which must fail the suite:* a build that ignores `_IOC_DIR` and copies
both ways; a build that trusts `argp` without validation (re-run `m9-ring3`'s kernel-pointer payload
against `ioctl`); a build that truncates an oversize payload instead of refusing it; **and a build that
switches on the whole request word rather than on `_IOC_NR`** — which `drm-abi`'s own two
`SYNCOBJ_*` numbers already falsify.

---

## 5. Why `ioctl` is 12

`docs/syscall-registry.md` is the allocator and this unit built it, because `ioctl` could not be given
a number honestly without one. `design/hot-files.md` §5.1 records that **two agents both claimed 11**,
in two different files, and that a duplicate merges clean, builds clean, boots clean and mis-dispatches.

`fdwait` was named as 11 first and in **three** designs (`blocking-and-threads.md` §3,
`display-protocol.md` §2.4, `time-and-power.md` §5). Moving it would break three documents to save one
number. So `ioctl` is **12**, and both rows are in the registry as *reserved* —
**a reserved number is as taken as an allocated one**, which is the whole point.

`scripts/verify-syscall-registry.sh` fails on a number claimed twice, on a kernel constant that
disagrees with its row, and on an `oslibc.h` `#define` that disagrees with its row. It was
mutation-tested against both a duplicated row and a wrong `SYS_SEEK`, and killed both.

---

## 6. The device name — `/dev/dri/card0`, correcting `drm-abi.md` S1

`design/drm-abi.md` S1 proposed `open(":DRI0")`, with the `:` sigil that `fatNameByteBad` already
forbids in disk names, and marked it ⚠ *"whether Mesa can be told those names… is the second thing V0
must check."*

**Checked, and the answer is no.** `xf86drm.h` hardcodes the paths:

```c
#define DRM_DIR_NAME          "/dev/dri"          /* __linux__ */
#define DRM_DEV_NAME          "%s/" "card" "%d"
#define DRM_RENDER_DEV_NAME   "%s/" "renderD" "%d"
```

and on the non-`__linux__` branch it is `"/dev"` + `"drm%d"`. Either way it is a **path**, built with
`sprintf` and handed to `open`, and `drmOpenByName` additionally `stat`s it and compares
`major()`/`minor()` against `DRM_MAJOR` 226. **Telling libdrm a name of our own means editing libdrm,
which is the one thing this port exists not to do.**

**So the device namespace serves the literal strings `/dev/dri/card0` and `/dev/dri/renderD128`.**
The disjointness argument S1 made survives intact: `fatNameByteBad` forbids `/` in an 8.3 name exactly
as it forbids `:`, so **`/` is as good a sigil as `:` and it is the one libdrm already emits.** The
placement rule S1 gave is unchanged and is the important half: the branch goes in **`fileSysOpen`**,
after the pointer-validated bounce-buffer copy and before `fatParseAt` — **not in `fatLookup`**, where
`display-protocol.md` §2.1 caught a ring-3-reachable volume corruption.

Recorded as GAP-0174.

---

## 7. The membrane — what this unit actually built of `drm-abi.md` §4.2

`design/drm-abi.md` §4.2 proposed a build-time generator that reads the uAPI headers and emits a
descriptor per request, and said it must be **a table generator in this repo, not a DCDart language
feature** (CLAUDE.md rule 3 in the negative). **`tests/conformance/drm-abi/gen-table.py` is the first
instance of it**, and one property of it is worth stating because it is the difference between a
generator and a second implementation:

> **The generator emits names, never numbers.** It writes `(unsigned int)DRM_IOCTL_VERSION` and lets
> the compiler do the `_IOC` arithmetic. A generator that parsed `_IOWR(...)` and computed the request
> itself would be a second implementation of the encoding, and a harness whose expectation is its own
> second implementation proves nothing.

The full §4.2 descriptor — direction, size, field list, offsets, widths — is **not built**, because
nothing yet consumes one: the dispatcher it would validate does not exist. GAP-0175 records that, and
`drm-abi.md` Q6's warning stands: it gets expensive to retrofit once several ioctls are served by hand.

---

## 8. Consequences

### 8.1 What is true now that was not

* **This OS has compiled somebody else's C library.** 7,801 lines, unmodified, for
  `x86_64-unknown-none-elf`. That capability was zero this morning and is the thing every future port
  inherits.
* **The gap to a linked libdrm is a list, not an estimate**: 43 symbols, checked into the repo, diffed
  on every run.
* **A program built against Linux's unmodified DRM uAPI runs in ring 3 on this kernel** and agrees
  with Linux 6.12 on 119 of 121 request numbers.
* **The syscall-number collision hazard is closed** by an allocator with a check.

### 8.2 What this does not claim

* **libdrm cannot be linked**, only compiled. 43 symbols short.
* **No ioctl was issued.** There is no `ioctl` (GAP-0158), no device node (GAP-0158), no `mmap`
  (GAP-0159).
* **`drmGetDevices2()` cannot work on this OS at all**, whatever the kernel does, until libdrm gains
  an oscortex platform branch: eight `drmParse*` functions are `#warning` stubs returning `-EINVAL`
  (GAP-0171). Mesa uses that call to find a GPU. **This is a change to libdrm — i.e. an upstream port
  — and ADR-0029's reading B ("unmodified source") does not cover it.** It is the first place the
  word "unmodified" will have to be qualified, and it should be qualified deliberately rather than
  discovered.

### 8.3 The honest size statement, which the brief asked for early rather than at rung four

**`libdrm` alone does not force threads, TLS, futexes, dynamic linking or a C++ runtime.** Its 43
symbols are ordinary hosted-libc work: `str*`, `snprintf`, `sscanf`, `qsort`, `malloc` family, `stat`,
`opendir`, `mmap`, `clock_gettime`, `errno`. That is `libc-roadmap.md` tiers A–C, and it is real but it
is not the substrate.

**`modetest` does.** The independently-authored conformance suite `drm-abi.md` §8.3 wanted libdrm for
needs, measured: **`pthread_create`/`pthread_join`** (`tests/modetest/cursor.c` runs the cursor on its
own thread), **`poll`** and **`select`** (`modetest.c` waits for DRM events both ways), **libm**
(`fabs`, `roundf`), `getopt`, `strtod`/`strtof`, `gettimeofday`, `usleep`. **76 missing symbols against
libdrm's 43.**

So the schedule fact, stated plainly and early: **libdrm links after a tier-C libc; `modetest` runs
only after threads.** `blocking-and-threads.md` §4.2's `pthread_create → EAGAIN` stub — honest and
sufficient for ffmpeg — is **insufficient here too**, and for a smaller program than Mesa than anyone
expected. GAP-0173.

`drm-abi.md` §8.1's conclusion is unchanged and this unit is evidence for it rather than against it:
**the GPU work is not the long pole; the POSIX substrate is.**

### 8.4 Reversibility

**High.** Nothing in `core/kernel/` changed. The port is a fetch script, 28 header files that
implement nothing, three checked-in symbol lists and a harness. Deleting
`core/user/ports/libdrm/` and `core/tests/conformance/drm-abi/` reverses it completely. The two
things that would survive a reversal and are independently justified are the **syscall registry** and
the **§4 `ioctl` specification**.

---

## 9. What this ADR does not decide

* **Whether to upstream an oscortex platform branch to libdrm** (§8.2). It is the only way
  `drmGetDevices2()` works, and it is a modification to libdrm. Somebody should decide whether that
  counts as "unmodified".
* **`ioctlMaxPayload`'s value.** §4.3 says "one page is the natural first value" and does not fix it;
  the measured maximum DRM payload is 248 bytes and the encoding's ceiling is 16383.
* **Whether the libc grows a POSIX face or libdrm gets an oscortex face.** §2.1's four clashing
  symbols can be resolved either by giving `core/user/libc` a `posix_open`-shaped second surface or by
  keeping the clash and refusing to link the two together. GAP-0170 states the problem and takes no
  position, because it is a `libc-roadmap.md` decision and not this unit's.
