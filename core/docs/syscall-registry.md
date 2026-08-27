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
| 16 | `mouse` | `mouseSysNo` | `core/kernel/mouse.dart` | *(none)* | 0035 |

**Sixteen syscalls, and the numbers are not contiguous.** 11 is `fdwait`'s and `fdwait` is not built,
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

**16 has no `oslibc.h` name for the channel's reason and one of its own.** The libc has no pointer
binding, and D1 (ADR-0042) deliberately did not invent one: a `mouse()` in `oslibc.h` would be a
public interface to a packed `u64` whose sixteen-bit coordinate fields stop being wide enough the
moment this kernel can set a mode wider than 800x600 (GAP-0252). `d1-mouse`'s program declares
`SYS_MOUSE` itself, the way `m20-ipc`'s declares its three, so the number lives in exactly two
places — `core/kernel/mouse.dart` and that harness — and both are listed here. When the pointer gets
a real ring-3 interface it will be an `ioctl` on a device node or a `read` of an event queue
(`docs/design/display-protocol.md` D2), not a wider version of this.

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
