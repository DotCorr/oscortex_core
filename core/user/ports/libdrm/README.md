# `core/user/ports/` — third-party C, and how this OS is pointed at it

**This directory contains no third-party source and never will.** A port here is a **pin**, a **fetch
script**, a **build script**, a **shim header set**, and **the checked-in list of what is still
missing**. The source itself is fetched at a commit and lives outside the repository.

`libdrm` is the first one. ADR-0031 is why it is first; `docs/design/libdrm-port.md` is the
measurement.

---

## 1. What a port is made of

| | |
|---|---|
| `PIN.txt` | URL, commit, date, version. Four lines. The commit is the whole reproducibility story |
| `fetch.sh` | the only thing that turns the pin into files. **Failure here is a SETUP ERROR (exit 2)**, never a test failure: "this laptop has no network today" is not evidence about this operating system |
| `build.sh` | compiles the library for `x86_64-unknown-none-elf` and **counts what is missing** |
| `shim/` | POSIX headers that **declare names and implement nothing** |
| `expected-*.txt` | the missing-symbol lists, diffed by the conformance harness on every run |

---

## 2. The shim is a measuring instrument, not a libc

Every function declared in `shim/` is either backed by `core/user/libc` — **ten are** — or
**deliberately left undefined**, so that it shows up in `nm --undefined-only` and is counted.

**A declaration in `shim/` is a measurement, not a promise.** `shim/pthread.h` declares
`pthread_create`; there are no threads on this operating system and there is no plan for one in this
directory. What the declaration buys is that `tests/modetest/cursor.c` *compiles*, so that the cost of
`modetest` can be stated as a number (76 missing symbols) instead of as "it needs threads, probably".

The two headers that are **not** pure stubs, because they make a decision:

* **`shim/sys/ioccom.h`** — serves **Linux's** `_IOC` encoding. `include/drm/drm.h` takes its
  "one of the BSDs" branch on this target, so the encoding is ours to choose, and choosing BSD's
  changes **29 of 121** DRM request numbers including `GEM_CLOSE` and `SET_MASTER`. ADR-0031 §3.
  `shim/asm/ioctl.h` is Linux's `asm-generic/ioctl.h`, transcribed.
* **`shim/limits.h`** — `#include_next`s clang's and adds `PATH_MAX` (**256**, not Linux's 4096) and
  `NAME_MAX`. `xf86drm.c` declares `char buf[PATH_MAX + 1]` on the stack in four places and this OS
  gives a process a 2 MiB address space.

---

## 3. The four symbols that make a clean link a lie

`open`, `read`, `close` and `printf` exist in `core/user/libc` **and are not the functions libdrm
means**. `oslibc.h`'s `open` takes **one** argument and returns a refusal at or above
`FILE_ERR_FLOOR`; libdrm passes **two or three** and tests for a negative `int`. The link succeeds.

`core/tests/conformance/drm-abi/run.sh` CHECK 2 asserts this hazard **exists** — it fails if those
four ever come out undefined, and it fails if `oslibc.h`'s declarations change shape — so that the day
somebody adds a POSIX-shaped `open`, the harness makes them look at this.

GAP-0170 states the problem and takes no position on the fix, because it is a `libc-roadmap.md`
decision.

---

## 4. What libdrm says about this platform, eight times

`build.sh` deliberately drops `-Werror`, and the output is worth reading rather than suppressing:

```
xf86drm.c:3626:2: warning: "Missing implementation of drmParseSubsystemType"
xf86drm.c:3758:2: warning: "Missing implementation of drmParsePciBusInfo"
xf86drm.c:3970:2: warning: "Missing implementation of drmParsePciDeviceInfo"
xf86drm.c:4199:2: warning: "Missing implementation of drmParseUsbBusInfo"
xf86drm.c:4230:2: warning: "Missing implementation of drmParseUsbDeviceInfo"
xf86drm.c:4304:2: warning: "Missing implementation of drmParseOFBusInfo"
xf86drm.c:4364:2: warning: "Missing implementation of drmParseOFDeviceInfo"
xf86drm.c:4470:2: warning: "Missing implementation of drmParseFauxBusInfo"
```

Those eight all `return -EINVAL`, and `drmGetDevices2()` is built on them. **That is how Mesa finds a
GPU, and it cannot work here regardless of what the kernel does.** Fixing it means adding an oscortex
branch to libdrm — a modification, which is the one thing this port exists not to do. GAP-0171,
`design/libdrm-port.md` §6.

---

## 5. Running it

```bash
core/user/ports/libdrm/fetch.sh /somewhere/libdrm
core/user/ports/libdrm/build.sh /somewhere/libdrm /tmp/out
core/user/ports/libdrm/build.sh /somewhere/libdrm /tmp/out-mt --with-modetest
cat /tmp/out/missing.txt      # 43
cat /tmp/out-mt/missing.txt   # 76

# all of it, plus a boot:
OSCORTEX_LIBDRM=/somewhere/libdrm core/tests/conformance/drm-abi/run.sh
```
