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

**Twelve syscalls, and the numbers are not contiguous.** 11 is `fdwait`'s and
`fdwait` is not built, so the allocated set is 0–10 and 12. **That gap is the
registry working, not a bug in it**: `ioctl` was implemented after `fdwait` was
named and took the next free number rather than the next number, which is
exactly the outcome this file exists to produce.

**Eleven syscalls before S0.** Number 10 has no `oslibc.h` name: it is a diagnostic the preempt harness reads,
not something a program is meant to call, and the registry records that asymmetry rather than tidying
it away.

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
