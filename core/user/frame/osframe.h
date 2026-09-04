/* OSFRAME 1
 * core/user/frame/osframe.h — the FRAME ABI, written down once.
 *
 * WHAT THIS IS
 * ---------------------------------------------------------------------------
 * A host-side header a freestanding program includes instead of copying
 * SYS_* into each prog.c. The numbers are a structural subset of
 * docs/syscall-registry.md. A copy of these bytes ships on the volume as
 * the 8.3 name FRAME.H so a ring-3 program can open and read the same
 * table it compiled against.
 *
 * WHAT THIS IS NOT
 * ---------------------------------------------------------------------------
 * It is not oslibc.h and it does not grow the C library. mouse / wmsurface /
 * kbdevent / wmevent have no oslibc.h names (syscall-registry.md); those
 * SYS_* live here only. verify-syscall-registry.sh reads oslibc.h, not
 * this file. No syscall is invented here. fdwait (11) is reserved and is
 * not named.
 *
 * The first line's tag `OSFRAME 1` is the magic/version a guest program
 * prints after it reads this file. OSFRAME_MAGIC is 'FRM1'.
 */

#ifndef OSFRAME_H
#define OSFRAME_H

#define OSFRAME_MAGIC 0x46524D31UL
#define OSFRAME_VERSION 1

/* ---------------------------------------------------------------------------
 * Syscall numbers a FRAME client needs. Each #ifndef so a program that
 * already included oslibc.h does not fight these spellings. The four
 * that oslibc.h refuses to name have no #ifndef twin there.
 * ------------------------------------------------------------------------- */

#ifndef SYS_EXIT
#define SYS_EXIT 0
#endif
#ifndef SYS_WRITE
#define SYS_WRITE 1
#endif
#ifndef SYS_YIELD
#define SYS_YIELD 3
#endif
#ifndef SYS_SBRK
#define SYS_SBRK 4
#endif
#ifndef SYS_OPEN
#define SYS_OPEN 5
#endif
#ifndef SYS_READ
#define SYS_READ 6
#endif
#ifndef SYS_CLOSE
#define SYS_CLOSE 7
#endif
#ifndef SYS_SEEK
#define SYS_SEEK 8
#endif
#ifndef SYS_FDWRITE
#define SYS_FDWRITE 9
#endif

#ifndef SYS_UNLINK
#define SYS_UNLINK 31
#endif
#ifndef SYS_RENAME
#define SYS_RENAME 32
#endif

#ifndef SYS_SHMCREATE
#define SYS_SHMCREATE 16
#endif
#ifndef SYS_SHMGRANT
#define SYS_SHMGRANT 17
#endif
#ifndef SYS_SHMMAP
#define SYS_SHMMAP 18
#endif
#ifndef SYS_SHMDROP
#define SYS_SHMDROP 19
#endif
#ifndef SYS_SHMGROW
#define SYS_SHMGROW 34
#endif
#ifndef SYS_SHMSHRINK
#define SYS_SHMSHRINK 35
#endif

/* No oslibc.h name. Packed u64: x | y<<16 | buttons<<32 | packets<<40. */
#define SYS_MOUSE 20

/* No oslibc.h name. 64-byte descriptor, op in word 0. */
#define SYS_WMSURFACE 23

/* No oslibc.h name. rdi = 0 pop / 1 dropped / 2 count. */
#define SYS_KBDEVENT 24

/* No oslibc.h name. Same ops as kbdevent, per-window click queue. */
#define SYS_WMEVENT 25

/* No oslibc.h name. spawn(namePtr, nameLen) -> slot. 11/21/22 stay off. */
#define SYS_SPAWN 26

/* ---------------------------------------------------------------------------
 * wmsurface — ADR-0051 eight-word overlay. No address in the descriptor.
 * word 6 is stride (0 => w*4) on attach and is also D_SEQ in some clients.
 * word 7 is the byte offset of pixel (0,0) in the region.
 * ------------------------------------------------------------------------- */
#define WM_OP_ATTACH 1UL
#define WM_OP_COMMIT 2UL
#define WM_OP_OFFER 3UL
#define WM_OP_TAKE 4UL
#define WM_CLIP_MAX 4096UL

/* ADR-0192. SCREEN answers `(w << 32) | h` for the LIVE scanout, so a client
 * stops having to freeze 800x600 into itself. PAINT hands one osgfx.h draw --
 * the same antialiased Skia the compositor paints chrome with -- at a surface
 * this client attached. Neither is a new syscall: 23 stays wmsurface and 11
 * stays fdwait. Word 2 is the paint kind; see WM_PAINT_* below. */
#define WM_OP_MOVE 7UL
#define WM_OP_SCREEN 9UL
#define WM_OP_PAINT 10UL
#define WM_OP_BACKING 11UL
#define WM_SURFACE_RESIZABLE (1UL << 63)
/* SCREEN word 2. RECT is the scanout; TASKS is the live window table, one
 * byte per slot: bit 7 live, bit 6 the surface is the panel, bit 5 seat-0
 * focus, bits 0..4 owner pid, with the listable count in byte 4. That is what
 * a desk shell needs to draw a slot pill and no more — not a handle, not an
 * address. */
#define WM_SCREEN_RECT 0UL
#define WM_SCREEN_TASKS 1UL
#define WM_SCREEN_NAME 2UL
#define WM_SCREEN_POP 3UL
#define WM_SCREEN_LAUNCH 4UL
#define WM_SCREEN_DESK_KEY 5UL
#define WM_SCREEN_TASKS_HI 6UL
#define WM_SCREEN_LAUNCH_Q 7UL
#define WM_SCREEN_LAUNCH_SEL 8UL
#define WM_SCREEN_PREF 9UL
#define WM_SCREEN_SWITCH 10UL
#define WM_TASK_LIVE 0x80UL
#define WM_TASK_PANEL 0x40UL
#define WM_TASK_FOCUS 0x20UL
#define WM_TASK_PID 0x1FUL

/* PAINT kinds. MEASURE touches no pixels and answers the advance of a run,
 * which is what a client needs before it can centre a label. */
#define WM_PAINT_MEASURE 0UL
#define WM_PAINT_RRECT 1UL
#define WM_PAINT_VGRAD 2UL
#define WM_PAINT_TEXT 3UL
#define WM_PAINT_ELEVATE 4UL
/* Frost: sample wallpaper under the surface, blur, tint. c0 = tint;
 * compositor packs window screen origin into the colour bottom word. */
#define WM_PAINT_GLASS 5UL

/* Text weights and the two sizes DE chrome uses, so an app's label and a
 * title bar are the same face at the same size (osgfx.h OSGFX_TEXT_*). */
#define WM_TEXT_REGULAR 0UL
#define WM_TEXT_MEDIUM 1UL
#define WM_TEXT_LABEL_PX 14UL
#define WM_TEXT_TITLE_PX 15UL

/* Longest run one PAINT carries, and the largest size it will accept. */
#define WM_TEXT_MAX 63UL
#define WM_TEXT_SIZE_MAX 64UL

#define WM_DESC_WORDS 8
#define WM_DESC_OP 0
#define WM_DESC_HANDLE 1
#define WM_DESC_X 2
#define WM_DESC_Y 3
#define WM_DESC_W 4
#define WM_DESC_H 5
#define WM_DESC_STRIDE 6
#define WM_DESC_OFFSET 7

#define WM_RET_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_RET_NOPROC 0xFFFFFFFFFFFFFFFEUL
#define WM_RET_OFF 0xFFFFFFFFFFFFFFFDUL
#define WM_RET_BADPTR 0xFFFFFFFFFFFFFFFCUL
#define WM_RET_BADOP 0xFFFFFFFFFFFFFFFBUL
#define WM_RET_BADCAP 0xFFFFFFFFFFFFFFFAUL
#define WM_RET_STALE 0xFFFFFFFFFFFFFFF9UL
#define WM_RET_BADGEOM 0xFFFFFFFFFFFFFFF8UL
#define WM_RET_NOSPACE 0xFFFFFFFFFFFFFFF7UL
#define WM_RET_NOWIN 0xFFFFFFFFFFFFFFF6UL
#define WM_RET_SMALL 0xFFFFFFFFFFFFFFF5UL
#define WM_RET_TWICE 0xFFFFFFFFFFFFFFF4UL

/* ---------------------------------------------------------------------------
 * kbdevent — ADR-0054. Packed event: bits 0-7 scancode, bit 8 break,
 * bit 9 E0 prefix. Empty pop is 0.
 * ------------------------------------------------------------------------- */
#define KBD_OP_POP 0UL
#define KBD_OP_DROPPED 1UL
#define KBD_OP_COUNT 2UL
#define KBD_BIT_BREAK 0x100UL
#define KBD_BIT_EXT 0x200UL
#define KBD_EMPTY 0UL

/* ---------------------------------------------------------------------------
 * wmevent — ADR-0055. Packed press: type in 0-7 (1 = press), window in
 * 8-15, surface-relative x in 16-31, y in 32-47. Empty pop is 0.
 * ------------------------------------------------------------------------- */
#define WMEVENT_OP_POP 0UL
#define WMEVENT_OP_DROPPED 1UL
#define WMEVENT_OP_COUNT 2UL
#define WMEVENT_TYPE_PRESS 1UL
#define WMEVENT_TYPE_CONFIGURE 2UL
#define WMEVENT_TYPE_ENTER 3UL
#define WMEVENT_TYPE_LEAVE 4UL
#define WMEVENT_TYPE_CONTEXT 5UL
#define WMEVENT_TYPE_SCROLL 6UL
#define WMEVENT_EMPTY 0UL

/* ---------------------------------------------------------------------------
 * mouse — ADR-0042 packed register. Sixteen-bit coordinates; enough for
 * 800x600 and not a promise about a wider mode (GAP-0252).
 * ------------------------------------------------------------------------- */
#define MOUSE_X_MASK 0xFFFFUL
#define MOUSE_Y_SHIFT 16
#define MOUSE_BUTTONS_SHIFT 32
#define MOUSE_PACKETS_SHIFT 40

/* ---------------------------------------------------------------------------
 * OSFRAME_START — THE ENTRY SHIM, AND WHY A FRAME APP NEEDS ONE (GAP-0339)
 *
 * `void _start(void)` compiled by clang is WRONG at the ABI, and it is wrong
 * in a way that is invisible until something in the program uses SSE.
 *
 * System V says RSP is 16-byte aligned at PROCESS ENTRY, and `argsBuild`
 * (core/kernel/args.dart) obeys that to the letter: it masks the value it
 * hands ring 3 with ~0xF. But clang compiles every C function on the
 * assumption it was reached by `call`, i.e. that RSP was 16-aligned BEFORE the
 * return address went on — so `push %rbp` leaves it a frame pointer that is
 * 16-aligned. Entered by `iretq` there is no return address, so `%rbp` comes
 * out 8 mod 16, every frame below it inherits the same 8, and the first
 * `movdqa` to a stack slot in the whole call tree raises #GP(0).
 *
 * That is exactly what killed DESK.ELF: clang vectorised `osxui_scan_button`'s
 * span walk, `movdqa %xmm0,-0xc0(%rbp)` faulted, the process was reaped, and
 * for two ADRs the note in desk.c read "osxui_button_fb HUNG in-ELF". It never
 * hung. It was never even reached twice.
 *
 * The shim is what a libc's `crt1.o` does: zero the frame pointer, hand the
 * entry stack to the C body as its argument, force the alignment, and `call`
 * so the callee sees the 8 it was compiled for. The spin behind the call is
 * unreachable for a body that exits or loops for ever, and is where a body
 * that returned would stop rather than fall off the end of `.text`.
 *
 * Use it as `OSFRAME_START(desk_main)` with `void desk_main(unsigned long sp)`.
 * ------------------------------------------------------------------------- */
#define OSFRAME_START(body)                                                    \
  __asm__(".text\n"                                                            \
          ".globl _start\n"                                                    \
          "_start:\n"                                                          \
          "  xorl %ebp, %ebp\n"                                                \
          "  movq %rsp, %rdi\n"                                                \
          "  andq $-16, %rsp\n"                                                \
          "  call " #body "\n"                                                 \
          "1:\n"                                                               \
          "  jmp 1b\n")

/* One console write and one file read/write, named so a client does not
 * invent 128 or 512. These are user.dart / file.dart, not new ABI. */
#define OSFRAME_WRITE_MAX 128UL
#define OSFRAME_READ_MAX 512UL
#define OSFRAME_FILE_WRITE_MAX 512UL

/* SYS rows the volume copy must keep, listed so a one-row truncate is
 * a different file. exit 0 / write 1 / yield 3 / sbrk 4 / open 5 /
 * read 6 / close 7 / seek 8 / fdwrite 9 / unlink 31 / rename 32 /
 * shmcreate 16 / shmgrant 17 / shmmap 18 / shmdrop 19 / mouse 20 /
 * wmsurface 23 / kbdevent 24 / wmevent 25 / spawn 26. Twenty allocated
 * numbers, not contiguous, 11 reserved. A second author includes this
 * header and does not paste those again. FRAME1 plants these bytes as
 * FRAME.H; ABITST.ELF open/read/checksums them. The tag on line 1 and
 * OSFRAME_VERSION must stay in agreement. Padding comments keep the
 * planted table longer than one 512-byte read so a program that hashes
 * a sector of zeros cannot pass. */

#endif /* OSFRAME_H */
