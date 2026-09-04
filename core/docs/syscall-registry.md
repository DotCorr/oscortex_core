# The syscall number registry

**This file is the allocator.** A syscall number is taken by adding a row here, in the same commit as
the code that uses it. `core/scripts/verify-syscall-registry.sh` reads this table and the kernel and
`core/user/libc/oslibc.h` and fails if any of the three disagree.

`design/README.md` fix #2 asked for this and `design/drm-abi.md` §9 said to build it with `ioctl`.
It exists because the numbers live as bare `const int` declarations in five different files —
`user.dart`, `proc.dart`, `heap.dart`, `file.dart` — with nothing between two subsystems and the same
number. `design/hot-files.md` §5.1 records that **two agents both claimed 11 in two different files**,
and that a duplicate merges clean, builds clean, boots clean, and mis-dispatches.

---

## Allocated — implemented, in the kernel today

| # | name | kernel constant | file | oslibc.h | ADR |
|--:|---|---|---|---|---|
| 0 | `exit` | `userSysExitNo` | `core/kernel/user.dart` | `SYS_EXIT` | 0013 |
| 1 | `write` | `userSysWriteNo` | `core/kernel/user.dart` | `SYS_WRITE` | 0013 |
| 2 | `who` | `userSysWhoNo` | `core/kernel/user.dart` | `SYS_WHO` | 0015 |
| 3 | `yield` | `procSysYieldNo` | `core/kernel/proc.dart` | `SYS_YIELD` | 0015 |
| 4 | `sbrk` | `heapSysSbrkNo` | `core/kernel/heap.dart` | `SYS_SBRK` | 0016 |
| 5 | `open` | `fileSysOpenNo` | `core/kernel/file.dart` | `SYS_OPEN` | 0019 |
| 6 | `read` | `fileSysReadNo` | `core/kernel/file.dart` | `SYS_READ` | 0019 |
| 7 | `close` | `fileSysCloseNo` | `core/kernel/file.dart` | `SYS_CLOSE` | 0019 |
| 8 | `seek` | `fileSysSeekNo` | `core/kernel/file.dart` | `SYS_SEEK` | 0019 |
| 9 | `fdwrite` | `fileSysWriteNo` | `core/kernel/file.dart` | `SYS_FDWRITE` | 0020 |
| 10 | `preempts` | `procSysPreemptsNo` | `core/kernel/proc.dart` | *(none)* | 0022 |
| 12 | `ioctl` | `ioctlSysNo` | `core/kernel/ioctl.dart` | `SYS_IOCTL` | 0032 |
| 13 | `chanopen` | `chanSysOpenNo` | `core/kernel/chan.dart` | *(none)* | 0027 |
| 14 | `chansend` | `chanSysSendNo` | `core/kernel/chan.dart` | *(none)* | 0027 |
| 15 | `chanrecv` | `chanSysRecvNo` | `core/kernel/chan.dart` | *(none)* | 0027 |
| 16 | `shmcreate` | `shmSysCreateNo` | `core/kernel/shm.dart` | *(none)* | 0041 |
| 17 | `shmgrant` | `shmSysGrantNo` | `core/kernel/shm.dart` | *(none)* | 0041 |
| 18 | `shmmap` | `shmSysMapNo` | `core/kernel/shm.dart` | *(none)* | 0041 |
| 19 | `shmdrop` | `shmSysDropNo` | `core/kernel/shm.dart` | *(none)* | 0041 |
| 20 | `mouse` | `mouseSysNo` | `core/kernel/mouse.dart` | *(none)* | 0042 |
| 23 | `wmsurface` | `wmSysSurfaceNo` | `core/kernel/wm.dart` | *(none)* | 0051 |
| 24 | `kbdevent` | `kbdqSysNo` | `core/kernel/kbdq.dart` | *(none)* | 0054 |
| 25 | `wmevent` | `wmeventSysNo` | `core/kernel/wmevent.dart` | *(none)* | 0055 |
| 26 | `spawn` | `procSysSpawnNo` | `core/kernel/proc.dart` | *(none)* | 0078 |
| 27 | `mmap` | `heapSysMmapNo` | `core/kernel/heap.dart` | *(none)* | 0128 |
| 28 | `clone` | `procSysCloneNo` | `core/kernel/proc.dart` | *(none)* | 0130 |
| 29 | `dlopen` | `elfSysDlopenNo` | `core/kernel/elf.dart` | *(none)* | 0144 |
| 30 | `futex` | `procSysFutexNo` | `core/kernel/proc.dart` | *(none)* | 0146 |
| 31 | `unlink` | `fileSysUnlinkNo` | `core/kernel/file.dart` | `SYS_UNLINK` | 0147 |
| 32 | `rename` | `fileSysRenameNo` | `core/kernel/file.dart` | `SYS_RENAME` | 0147 |
| 33 | `setfs` | `procSysSetfsNo` | `core/kernel/proc.dart` | *(none)* | 0148 |
| 34 | `shmgrow` | `shmSysGrowNo` | `core/kernel/shm.dart` | *(none)* | 0150 |
| 35 | `shmshrink` | `shmSysShrinkNo` | `core/kernel/shm.dart` | *(none)* | 0156 |
| 36 | `mprotect` | `shmSysMprotectNo` | `core/kernel/shm.dart` | *(none)* | 0163 |
| 37 | `shmfile` | `shmSysFileNo` | `core/kernel/shm.dart` | *(none)* | 0164 |
| 38 | `mkdir` | `fileSysMkdirNo` | `core/kernel/file.dart` | `SYS_MKDIR` | 0199 |

**Thirty-five syscalls, and the numbers are not contiguous.** 11 is `fdwait`'s and `fdwait` is not built,
so the allocated set is 0-10 and 12-16. **That gap is the registry working, not a bug in it**:
`ioctl` was implemented after `fdwait` was named and took the next free number rather than the next
number, and M20's three channel calls did the same thing again on the next merge -- they had claimed
11, 12 and 13 on a branch that forked before this file existed, and moved to 13, 14 and 15 rather
than displace a reservation. GAP-0213 records that second case, which is exactly the one
`design/hot-files.md` S5.1 warned about: a duplicate number merges clean, builds clean, boots clean,
and mis-dispatches.

**Eleven syscalls before S0.** Number 10 has no `oslibc.h` name: it is a diagnostic the preempt harness reads,
not something a program is meant to call, and the registry records that asymmetry rather than tidying
it away. **13, 14 and 15 have no `oslibc.h` name either, for a different reason**: the libc has no
channel binding yet. `m20-ipc`'s program declares `SYS_CHANOPEN`/`SYS_CHANSEND`/`SYS_CHANRECV` itself,
the way it declares `SYS_EXIT` and `SYS_WRITE`, so those numbers live in exactly two places — the
kernel and that harness — and both are listed here.

**Why `mouse` is 20 and not 16 - the same thing happening a second time.** `d1-ps2-mouse` and
`m21-shared-frame` both forked from `71cf08f`, when 15 was the highest allocated number, and both
took the next one: D1 gave `mouse` 16 and M21 gave `shmcreate` 16, `shmgrant` 17, `shmmap` 18 and
`shmdrop` 19. Neither branch could see the other and neither was wrong on its own line. **The two
kernel constants merged CLEAN** - they live in different files, so git had nothing to report; only
this table conflicted, and only because both branches edited it. That is exactly the shape
`docs/design/hot-files.md` 5.1 records, and `verify-syscall-registry.sh` is what caught it. On the
merge M21's contiguous block of four kept 16-19 and D1's single call moved to 20, for the reason
M20's three moved rather than displacing `fdwait`: **the cheaper move is the correct one, and the
number is not the interface.** `mouseSysNo`, `prog.c`'s private `SYS_MOUSE`, `d1-mouse/run.sh`'s two
assertions, ADR-0042 7 and GAP-0252 all moved with it, and `verify-syscall-registry.sh` is what
proves they moved together. GAP-0264 records the collision itself.

**20 has no `oslibc.h` name for the channel's reason and one of its own.** The libc has no pointer
binding, and D1 (ADR-0042) deliberately did not invent one: a `mouse()` in `oslibc.h` would be a
public interface to a packed `u64` whose sixteen-bit coordinate fields stop being wide enough the
moment this kernel can set a mode wider than 800x600 (GAP-0252). `d1-mouse`'s program declares
`SYS_MOUSE` itself, the way `m20-ipc`'s declares its three, so the number lives in exactly two
places — `core/kernel/mouse.dart` and that harness — and both are listed here. When the pointer gets
a real ring-3 interface it will be an `ioctl` on a device node or a `read` of an event queue
(`docs/design/display-protocol.md` D2), not a wider version of this.

**Why `wmsurface` is 23 and not 21, and this table settling the same collision a fourth time.**
ADR-0051. `wmsurface(descPtr)` is the compositor's whole ring-3 surface: `op = wmOpAttach` gets a
window and **returns the address the caller's own address space has its region at**, and
`op = wmOpCommit` says the frame is ready and returns when the compositor is done reading it.

20 is `mouse`. 21 and 22 were free on this branch's fork point and are not free in this repo: 21 is
`shmaddr` (ADR-0045) and 22 is `shmpublish` (ADR-0046), on `integrate-shmaddr` and
`m21-writable-grants` respectively — two lines that had not merged when this one forked, and which
this one can see only because it went and looked. **The kernel constants would have merged clean
again**, because `wmSysSurfaceNo` lives in a file neither of those branches has; only this table
would have conflicted. Taking 23 up front is the same move the registry has now recorded four times,
for the same reason: *the cheaper move is the correct one, and the number is not the interface.*

**Ops 9 and 10 on 23, and why they are not syscalls 35 and 36.** ADR-0192. `op = wmOpScreen` (9)
answers the LIVE scanout as `(w << 32) | h`, or the window table as four packed bytes, in `rax`; `op =
wmOpPaint` (10) applies ONE `osgfx.h` primitive — AA rrect, vertical gradient, blur elevation, a
Roboto outline run, or a measure — to a surface the caller already owns. Both are things a client asks
about *its own compositor session*, which is what 23 already is: `wmOpAttach` returns an address and
`wmOpCommit` returns a frame count through the same eight-word descriptor. A separate number would
have meant a second capability check against the same window table for no new authority. **The
descriptor words are reinterpreted per op** and `core/user/frame/osxui_app.h` names them
(`OSXUI_APP_KIND`, `OSXUI_APP_XY`, `OSXUI_APP_SHAPE`, …) so a reader is not mapping "H" onto "run
length" unaided. 11 stays `fdwait`; no row was added to the table above, because no number was taken.

**23 has no `oslibc.h` name**, for the channel's reason and one of its own. The libc has no binding
for a pointer-to-descriptor call, and a `wmsurface()` in `oslibc.h` would be a public interface to
an eight-word struct whose damage-rectangle words D6 now honours (ADR-0052).
`d2-compositor/prog.c` declares `SYS_WMSURFACE` itself, the way `m20-ipc`'s program
declares its three and `d1-mouse`'s declares `SYS_MOUSE`, so the number lives in exactly two places
— `core/kernel/wm.dart` and that harness — and both are listed here.

**Why `kbdevent` is 24.** D2 (ADR-0054). `kbdevent(op)` pops one raw keyboard event
(`op = 0`), or returns the overflow counter (`op = 1`), or the queued count (`op = 2`).
20 is `mouse`, 23 is `wmsurface`, 21 and 22 are taken on other lines, 11 is still
`fdwait`. Same collision rule, applied a fifth time.

**24 has no `oslibc.h` name**, for the channel's reason and `mouse`'s: a `kbdevent()`
in the libc would be a public interface to a packed `u64` whose bit layout is the
queue's, and D2 deliberately did not invent one. `d2-input` and `d9-focus` declare
`SYS_KBDEVENT` themselves. D9 (ADR-0062) gates the pop: when `wmMetaFocus` is
live, only the focused window's owner reads the queue; everyone else pops 0.
No new number. 11, 21 and 22 stay reserved.

**Why `wmevent` is 25.** D7 (ADR-0055). `wmevent(op)` pops one pointer event
for the calling process's window (`op = 0`), or returns that window's
overflow counter (`op = 1`), or its queued count (`op = 2`). 20 is `mouse`,
23 is `wmsurface`, 24 is `kbdevent`, 21 and 22 are taken on other lines, 11
is still `fdwait`. Same collision rule, applied a sixth time.

**25 has no `oslibc.h` name**, for the channel's reason and `kbdevent`'s: a
`wmevent()` in the libc would be a public interface to a packed `u64` whose
bit layout is the click queue's, and D7 deliberately did not invent one.
`d7-click`'s program declares `SYS_WMEVENT` itself, so the number lives in
exactly two places — `core/kernel/wmevent.dart` and that harness — and both
are listed here. ADR-0142 adds types 2/3/4 (configure / enter / leave)
on the same syscall. 11 stays `fdwait`. No new number.

**Why `spawn` is 26.** STUDIO2 (ADR-0078). A live process starts another
process by 8.3 name: `spawn(namePtr, nameLen) -> slot`. 20 is `mouse`,
23 is `wmsurface`, 24 is `kbdevent`, 25 is `wmevent`, 11 is still
`fdwait`, 21 and 22 are taken on other lines. Same collision rule,
applied a seventh time.

**26 has no `oslibc.h` name**, for the channel's reason and because a
`spawn()` in the libc would be APP7's full `spawn(name, argv)` and this
call is the name-only minimum a FRAME launcher needs. `osframe.h` names
`SYS_SPAWN`; `studio.c` includes that header. The number lives in the
kernel, the registry, and the FRAME header.

**Why `mmap` is 27.** ADR-0128. A named platform process maps anonymous
pages of a requested length: `mmap(len) -> va`. 11 stays `fdwait`. 21
and 22 stay reserved on other lines. 26 is `spawn`. Same collision
rule, applied an eighth time. This is not POSIX `mmap` (no fd, no
`munmap`, no `MAP_SHARED`) and it is not TAP/FILES — `ASK.ELF` of the
same bytes is `heapRetBadArg`.

**27 has no `oslibc.h` name**, for the channel's reason and because a
`mmap()` in the libc would be the POSIX six-argument call. The number
lives in the kernel, the registry, and `plat-map/`'s program.

**Why `clone` is 28.** ADR-0130. A named platform process starts a
sibling on its own page tables: `clone(fn, stack) -> slot`. 11 stays
`fdwait`. 21 and 22 stay reserved on other lines. 26 is `spawn`, 27
is `mmap`. Same collision rule, applied a ninth time. This is not
Linux `clone` (no flags, no TLS, no `CLONE_CHILD_CLEARTID`) and it
is not TAP/FILES — `ASK.ELF` of the same bytes is `cloneRetBadArg`.
ADR-0129 is Graphite MakeVulkan on another line.

**28 has no `oslibc.h` name**, for the channel's reason and because a
`clone()` in the libc would be the Linux flags call. The number lives
in the kernel, the registry, and `plat-clone/`'s program.

**Why `dlopen` is 29.** ADR-0144. `dlopen(namePtr, nameLen) -> va`
maps our FAT-resident tiny ET_DYN for a named platform process and
returns the VA of `so_mark`. 11 stays `fdwait`. 21 and 22 stay
reserved on other lines. 26 is `spawn`, 27 is `mmap`, 28 is `clone`.
Same collision rule, applied a tenth time. This is not glibc
`dlopen` (no `RTLD_*`, no constructor, one symbol) and it is not
TAP/FILES — `ASK.ELF` of the same bytes is `elfDlopenRetBadArg`.

**29 has no `oslibc.h` name**, for the channel's reason and because a
`dlopen()` in the libc would be glibc's. The number lives in the
kernel, the registry, and `plat-dl/`'s program.

**Why `futex` is 30.** ADR-0146. `futex(op, addr, val)` waits
while `*addr == val` (op 0) or wakes up to `val` waiters on
`addr` (op 1). 11 stays `fdwait`. 21 and 22 stay reserved on
other lines. 26 is `spawn`, 27 is `mmap`, 28 is `clone`, 29 is
`dlopen`. Same collision rule, applied an eleventh time. This
is not Linux `futex` (no `FUTEX_*` flags, no timeout, VA token
for CLONE_VM siblings) and it is not TAP/FILES — `ASK.ELF` of
the same bytes is `futexRetBadArg`. ADR-0145 is VirtIO-net on
another line.

**30 has no `oslibc.h` name**, for the channel's reason and because a
`futex()` in the libc would be Linux's. The number lives in the
kernel, the registry, and `plat-futex/`'s program.

**Why `unlink` is 31 and `rename` is 32.** ADR-0147 (APP4).
`unlink(namePtr, nameLen)` marks a root entry 0xE5 and frees its
chain. `rename(oldPtr, oldLen, newPtr, newLen)` rewrites the
source entry's 11 name bytes; an existing dest is freed first.
11 stays `fdwait`. 30 is `futex`. Same collision rule, applied a
twelfth time. Both have `oslibc.h` names because ring-3 file
programs already include that header for `open`/`fdwrite`.

**Why `setfs` is 33.** ADR-0148. `setfs(base)` plants
`IA32_FS_BASE` for a named platform process so a `%fs:` load
or store reaches [base]. 11 stays `fdwait`. 21 and 22 stay
reserved on other lines. 30 is `futex`, 31/32 are
`unlink`/`rename`. Same collision rule, applied a thirteenth
time. This is not Linux `arch_prctl` (no `ARCH_SET_GS`, no
get) and it is not TAP/FILES — `ASK.ELF` of the same bytes is
`setfsRetBadArg`. Without the MSR write a `%fs:0` store faults
at VA 0, so the derived TLS line cannot print.

**33 has no `oslibc.h` name**, for the channel's reason and because a
`arch_prctl()` in the libc would be Linux's. The number lives in the
kernel, the registry, and `plat-tls/`'s program.

**Why `shmgrow` is 34.** ADR-0150. `shmgrow(handle, newPages)`
extends a live region in place up to `shmMaxPages` and maps the new
pages into every address space that currently maps the region
(ADR-0158). Refuses when the caller is not mapped or not RW. 11
stays `fdwait`. 33 is `setfs`. Same collision rule, applied a
fourteenth time. This is the ADR-0142 leftover after configure: a
client that attached a small shm can grow it without a new region.

**34 has no `oslibc.h` name**, for the channel's reason. The number
lives in the kernel, the registry, and `shm-grow/` / `shm-multi/`'s
programs.

**Why `shmshrink` is 35.** ADR-0156. `shmshrink(handle, newPages)`
truncates a live region in place, unmaps the trailing pages from
every mapper (ADR-0158), and returns their frames. 11 stays
`fdwait`. 34 is `shmgrow`. Same collision rule, applied a fifteenth
time. This is the GAP-0234 shrink remainder after grow.

**35 has no `oslibc.h` name**, for the channel's reason. The number
lives in the kernel, the registry, and `shm-shrink/` /
`shm-multi/`'s programs.

**Why `mprotect` is 36.** ADR-0163. `mprotect(handle, perms)` changes
W on an already-mapped shm window (downgrade RW→RO after publish).
`shmmap` also gains `MAP_FIXED` (perms bit `0x100`, `rcx` = VA):
wrong address is `shmRetBadFixed`, overlap stays `shmRetMapped`.
11 stays `fdwait`. 35 is `shmshrink`. Same collision rule, applied
a sixteenth time. Closes the mprotect + MAP_FIXED doors of GAP-0235;
file backing and demand paging closed by ADR-0164.

**36 has no `oslibc.h` name**, for the channel's reason. The number
lives in the kernel, the registry, and `mmap-prot/`'s program.

**Why `shmfile` is 37.** ADR-0164. `shmfile(fd) -> handle` creates a
RO shm region sized to an open FAT file; pages stay not-present until
first touch (`shmDemandTry` on `#PF` NOTPRES fills from the fd and
retries). 11 stays `fdwait`. 36 is `mprotect`. Same collision rule,
applied a seventeenth time. Closes the file-backing and demand-paging
doors of GAP-0235.

**37 has no `oslibc.h` name**, for the channel's reason. The number
lives in the kernel, the registry, and `mmap-file/`'s program.

**ADR-0158 adds no number.** Multi-mapper grow/shrink reuses 34 and
35. 11 stays `fdwait`. Partial / offset map stay GAP-0234.

**ADR-0160 adds no number.** Partial / offset map reuses `shmmap`
(18) with `rdx = (offset << 16) | count` (`count == 0` = whole).
Capability words carry the window. 11 stays `fdwait`. 34/35 stay
`shmgrow`/`shmshrink`. Closes the GAP-0234 map remainder.

**ADR-0152 adds no number.** The first honest libc door reuses
`dlopen` (29): OUR tiny FAT `LIBC.SO` exports `write`, X LOADs are
remapped R+X, and the call returns MARK for the derived LINE.
11 stays `fdwait`. Not glibc. Not the 32 `DT_NEEDED`. Not 189 MiB.

**ADR-0154 adds no number.** The platform window is raised to
112 MiB (`plat-huge/`); `mmap` (27) plants that fraction of CEF
`.text` under the 128 MiB PMM floor. 11 stays `fdwait`. Not the
remaining 77 MiB. Not glibc. Not `OnPaint`.

**ADR-0155 adds no number.** `MAP_2MIB_PAGES` / `pmmMaxFrames` rise
together to 256 MiB and the platform window to the full **189 MiB**
CEF `.text` plant (`plat-huge/`). 11 stays `fdwait`. Not glibc.
Not the 32 `DT_NEEDED`. Not `OnPaint`.

**ADR-0157 adds no number.** A named `PLAT.ELF` walks two FAT
`DT_NEEDED` (`LIBC.SO` + `LIBM.SO`) through `dlopen` (29); `need_fn`
joins `write` / `so_mark` on the resolve list (`plat-need/`). 11
stays `fdwait`. Satisfies **2 of 32** CEF `DT_NEEDED` stand-ins;
**30 remain**. Not glibc. Not `OnPaint`.

**ADR-0160 adds no number.** A named `PLAT.ELF` walks four FAT
`DT_NEEDED` (`LIBC.SO` + `LIBM.SO` + `LIBDL.SO` + `LIBPT.SO`)
through `dlopen` (29); `dl_fn` / `pt_fn` join the resolve list
(`plat-need2/`). 11 stays `fdwait`. Satisfies **4 of 32** CEF
`DT_NEEDED` stand-ins; **28 remain**. Not glibc. Not `OnPaint`.

**ADR-0162 adds no number.** A named `PLAT.ELF` walks eight FAT
`DT_NEEDED` (`LIBC.SO` + `LIBM.SO` + `LIBDL.SO` + `LIBPT.SO` +
`LIBGB.SO` + `LIBGO.SO` + `LIBNP.SO` + `LIBNS.SO`) through
`dlopen` (29); `gb_fn` / `go_fn` / `np_fn` / `ns_fn` join the
resolve list (`plat-need3/`). 11 stays `fdwait`. Satisfies
**8 of 32** CEF `DT_NEEDED` stand-ins; **24 remain**. Not glibc.
Not `OnPaint`.

**ADR-0163 adds no number.** A named `PLAT.ELF` walks sixteen FAT
`DT_NEEDED` (ADR-0162's eight plus `LIBNU.SO` + `LIBSM.SO` +
`LIBDB.SO` + `LIBGI.SO` + `LIBAT.SO` + `LIBAB.SO` + `LIBCU.SO` +
`LIBX1.SO`) through `dlopen` (29); `nu_fn` / `sm_fn` / `db_fn` /
`gi_fn` / `at_fn` / `ab_fn` / `cu_fn` / `x1_fn` join the resolve
list (`plat-need4/`). 11 stays `fdwait`. Satisfies **16 of 32**
CEF `DT_NEEDED` stand-ins; **16 remain**. Not glibc. Not `OnPaint`.

**ADR-0165 adds no number.** A named `PLAT.ELF` walks thirty-two
FAT `DT_NEEDED` through `dlopen` (29); `xc_fn`..`ld_fn` join the
resolve list (`plat-need5/`). 11 stays `fdwait`. Satisfies
**32 of 32** CEF `DT_NEEDED` stand-ins. Not glibc. Not `OnPaint`.

**ADR-0166 adds no number.** OnPaint-shaped stand-in
(`oschrome_on_paint`, `browse-paint/`) reuses the existing FRAME
path. 11 stays `fdwait`. Not official libcef.

**ADR-0167 adds no number.** A named `PLAT.ELF` `dlopen`s a
measured official `CEF.SO` slice (`cef-wire/`); `cef_initialize`
joins the resolve list. 11 stays `fdwait`. Not full libcef. Not
`OnPaint`.

**ADR-0168 adds no number.** A named `PLAT.ELF` `dlopen`s maps
full official libcef LOADs (RO+RX) from a host-backed plant
(`cef-load/`). 11 stays `fdwait`. Not glibc UND. Not `OnPaint`.

**ADR-0133 adds no number.** Live Start / close / min call
`osxui_button` through the existing compositor path. 11 stays
`fdwait`.

**ADR-0134 adds no number.** Graphite MakeVulkan opens a kernel
ICD when Venus capset 4 is offered. 11 stays `fdwait`.

**ADR-0172 adds no number.** Venus CONTEXT_INIT + blob encodes
retained SPIR-V (`de-graphite6/`). 11 stays `fdwait`.

**ADR-0174 adds no number.** Real-named `libdl.so.2` resolves
through planted `SOMAP.TXT` → FAT `LIBDL.SO` (`cef-dl/`). 11
stays `fdwait`. Not the other 31 sonames. Not OnPaint.

**ADR-0175 adds no number.** Display door (`sit-in-view.sh` /
`view-door/`): cocoa zoom-to-fit + Venus sdl,gl + x11vnc. 11
stays `fdwait`. Not a second hypervisor.

**ADR-0135 adds no number.** A decoded frame commits through
`wmsurface` (23). The hidden media command and Start PLAY.ELF
stay commands. 11 stays `fdwait`.

**ADR-0136 adds no number.** Live hex pids on the reflection
panel call `osxui_hex` / `osxui_label` through the existing
compositor path. 11 stays `fdwait`.

**ADR-0141 adds no number.** Session chrome on the live GOP
aperture is `fb` + `wm on` / `wm chrome` through the existing
scanout fallback. 11 stays `fdwait`.

**ADR-0151 adds no number.** OTA host TCP fetch (`ota get`) is a
shell command over the existing e1000 path. 11 stays `fdwait`.
Not plat-tls. Not HTTPS.

**Why the channel syscalls are 13, 14, 15 and not 11, 12, 13.** They were 11, 12 and 13 in ADR-0027,
chosen on a branch that forked from `d4e768c` — before this file existed. This registry landed in
`79a5a6a` and had already reserved 11 for `fdwait` and 12 for `ioctl`. When the two lines were merged,
`fdwait` and `ioctl` kept their numbers and the channel moved: three design documents and a live
`ioctl` implementation depend on 11 and 12, while the channel's numbers existed in two files and its
harness keeps no golden, so the side that could move at no cost moved. **This is exactly the case
`design/hot-files.md` §5.1 describes** — two agents claiming the same number in two different files,
a duplicate that merges clean, builds clean, boots clean and mis-dispatches — caught here by this
registry and its verifier rather than at runtime. GAP-0213 records it.

---

## Reserved — designed, not implemented, and the number is spoken for

| # | name | claimed by | status |
|--:|---|---|---|
| 11 | `fdwait(mask, timeoutTicks) -> readyMask` | `design/blocking-and-threads.md` §3, `design/display-protocol.md` §2.4, `design/time-and-power.md` §5 | **the only blocking primitive.** Three designs name it and all three say 11. **Still reserved after S0** — `ioctl` went to 12 rather than taking it |

**Why `ioctl` is 12 and not 11.** `fdwait` was named first, in three documents, and moving it would
break three designs to save one number. `design/drm-abi.md` §9 says "take the next number from the
syscall registry"; this is the registry, and the next number is 12.

---

## Rules

1. **A number is taken by a row in this table**, not by a `const int` in a `.dart` file. Add the row
   in the same commit.
2. **A reserved number is as taken as an allocated one.** Reserving costs one row and prevents the
   failure mode this file exists for.
3. **`verify-syscall-registry.sh` is the check**, and it runs from
   `core/tests/conformance/drm-abi/run.sh`. It fails on: a number in two rows, a kernel constant whose
   value does not match its row, an `oslibc.h` `SYS_*` that does not match its row, and a kernel
   `*SysNo` constant with no row at all.
4. **It does not check the reverse direction for reserved numbers** — a reserved row has no kernel
   constant yet, by definition, and requiring one would make reserving impossible.
