/* core/tests/conformance/d2-compositor/prog.c
 *
 * D4/D5's test program: A CLIENT OF THE COMPOSITOR. ONE SOURCE, BUILT ONCE,
 * WRITTEN TO TWO DISK SLOTS.
 *
 * WHY IT IS ONE PROGRAM AND NOT TWO
 * ---------------------------------------------------------------------------
 * `make-image.py` writes the SAME BYTES to both slots and refuses to build an
 * image where they differ. Which process becomes window A and which becomes
 * window B is decided ENTIRELY by which one `chanopen` answers first. So "two
 * processes each drew into their own region and the compositor put both on the
 * screen" is a claim about the KERNEL and not about two different programs --
 * M20's discipline, M21's after it, and this is the third milestone to keep it.
 *
 * THIS PROGRAM CONTAINS NO ADDRESS.
 * ---------------------------------------------------------------------------
 * That is the point of it, and it is the ABI decision this milestone was told
 * to respect. `m21-shmem/prog.c` contains the literal `0x10200000` because at
 * the time it was written there was no syscall by which a region's CREATOR
 * could learn where its own region was mapped: `shmcreate` maps the region and
 * returns a HANDLE, and `shmmap` on that handle is then refused as
 * already-mapped. Deriving `vmShmBase + slot * pages * 4096` was the only thing
 * a creator could do -- and a dependency nobody chose still becomes ABI the
 * moment a client ships.
 *
 * `wmsurface(op = WM_ATTACH)` returns the address. Grep this file for `0x10`
 * and there is nothing to find: every pointer it dereferences came out of `rax`
 * of a syscall the kernel answered. `run.sh` greps for it too, and fails if a
 * future edit puts one back.
 *
 * THE TWO ROLES
 * ---------------------------------------------------------------------------
 *   side 0 -- window A, at (A_X, A_Y). Creates a region, ATTACHES it as a
 *             surface, is told where it is, paints it, COMMITS it -- at which
 *             point the compositor composes a frame with one window in it --
 *             and then YIELDS, so that its peer can run while A's region is
 *             still alive and still mapped. It never runs again until B is
 *             finished.
 *   side 1 -- window B, at (B_X, B_Y), OVERLAPPING A. Same four steps. Its
 *             commit composes the frame that has BOTH windows in it, and
 *             because B attached second, B is on top -- which is the whole of
 *             D5 and is what the overlap pixels prove. Then it HOLDS, on a busy
 *             spin, so that the screen the harness photographs is a screen with
 *             two live surfaces on it rather than a leftover.
 *
 * THE HOLD IS A BUSY SPIN AND NOT A YIELD LOOP, for M21's reason exactly:
 * `proc.dart` prints a line on every yield and a hold long enough to be useful
 * would bury the transcript. `build-progs.sh` asserts that the hold neither
 * yields nor loses its `volatile`, because -O2 deletes a loop with no effect.
 *
 * EVERY NUMBER THIS PROGRAM EXITS WITH IS DERIVED FROM PIXELS IT ACTUALLY
 * WROTE. `derive.py` computes the same sum on the host from the same constants.
 * A client that painted the wrong colour, the wrong number of pixels, or into
 * the wrong place produces a different 64-bit number and the harness fails.
 *
 * Freestanding: no libc. `proc coop` enters at e_entry with an EMPTY STACK and
 * no argv (GAP-0149), so this file defines its own entry point.
 */

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned char u8;

/* --- the ABI ------------------------------------------------------------- */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_CHANOPEN 13
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23

/* core/kernel/wm.dart's return values, copied rather than included because this
 * program is freestanding; run.sh reads BOTH copies and requires them to agree,
 * and requires the kernel to declare no refusal this program has not been
 * taught. M21's rule, kept. */
#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_NOPROC 0xFFFFFFFFFFFFFFFEUL
#define WM_OFF 0xFFFFFFFFFFFFFFFDUL
#define WM_BADPTR 0xFFFFFFFFFFFFFFFCUL
#define WM_BADOP 0xFFFFFFFFFFFFFFFBUL
#define WM_BADCAP 0xFFFFFFFFFFFFFFFAUL
#define WM_STALE 0xFFFFFFFFFFFFFFF9UL
#define WM_BADGEOM 0xFFFFFFFFFFFFFFF8UL
#define WM_NOSPACE 0xFFFFFFFFFFFFFFF7UL
#define WM_NOWIN 0xFFFFFFFFFFFFFFF6UL
#define WM_SMALL 0xFFFFFFFFFFFFFFF5UL
#define WM_TWICE 0xFFFFFFFFFFFFFFF4UL

/* The two operations, and the eight descriptor words. wm.dart's names. */
#define WM_ATTACH 1UL
#define WM_COMMIT 2UL
#define D_OP 0
#define D_HANDLE 1
#define D_X 2
#define D_Y 3
#define D_W 4
#define D_H 5
#define D_STRIDE 6
#define D_OFFSET 7
#define D_SEQ 6

/* --- the picture. derive.py reads every one of these out of this file. ---- */

#define WIN_W 240UL
#define WIN_H 160UL
#define A_X 100UL
#define A_Y 120UL
#define B_X 260UL
#define B_Y 220UL
#define A_FILL 0x00C03828UL
#define A_INK 0x00F0C020UL
#define B_FILL 0x001878A8UL
#define B_INK 0x0020E0E0UL

/* The inner block, inset from every edge of the surface. It exists so that a
 * surface is not one flat colour: a compositor that blitted the FIRST pixel of
 * a region over the whole window would pass a solid-colour assertion and fail
 * this one. */
#define INK_INSET 40UL

/* D6: a second commit from side 1, a 16x16 rectangle of a colour that is
 * nowhere else on the surface. derive.py refuses to emit expectations if this
 * patch is empty, if its colour matches what it overwrites, or if it sits on
 * top of another probe -- otherwise "the small count" would be a number with
 * no pixel behind it. Bottom-right of B, outside the overlap and outside the
 * inner block, so the existing fill/ink/border probes stay what they were. */
#define DMG_X 224UL
#define DMG_Y 144UL
#define DMG_W 16UL
#define DMG_H 16UL
#define DMG_INK 0x00E040C0UL

/* ceil(240 * 160 * 4 / 4096) = ceil(37.5). Stated as a literal and checked by
 * derive.py against the geometry above, because a page count that silently
 * disagreed with the geometry would be refused by the kernel as WM_SMALL and
 * the harness should say which of the two numbers is wrong. */
#define WIN_PAGES 38UL

/* The hold: how long side 1 spins with both surfaces composed and both regions
 * alive, before it exits. Bounded, so a broken kernel produces a diagnosis
 * rather than a hung harness, and long enough that the harness's memory dump
 * and screenshot land inside it. run.sh reads this constant out of this file. */
#define HOLDSPIN 900000000UL

/* --- syscalls ------------------------------------------------------------ */

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

/* --- state --------------------------------------------------------------- */

/* The descriptor. `.data` rather than a stack local, and initialised, so that
 * the RW PT_LOAD segment has a non-zero p_filesz -- m11's segment shape, which
 * build-progs.sh asserts. It is 8 x u64 = 64 bytes = chanMsgBytes, aligned so a
 * u64 store to any word is aligned. */
static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};

/* NON-ZERO, and that is the only reason it exists. An all-zero `desc` is put in
 * `.bss` by the compiler, the RW PT_LOAD segment then has p_filesz 0, and m10's
 * zero-tail handling is not exercised at all -- which is m11's segment shape and
 * is what build-progs.sh asserts. One initialised word is the cheapest honest
 * way to have a `.data` at all. It is also read back at exit, so -O2 cannot
 * decide it is dead. */
static volatile u64 marker = 0x00D2C0DE00D2C0DEUL;

/* .bss, so the RW segment also has a zero tail (p_memsz > p_filesz). */
static u64 scratch[8];

static const char msg_attach[] = "D2 ATTACH\n";
static const char msg_paint[] = "D2 PAINT\n";
static const char msg_commit[] = "D2 COMMIT\n";

/* --- the picture, written one pixel at a time ---------------------------- */

/* Returns the colour of surface pixel (px, py) for this side. The inner block
 * is a rectangle inset INK_INSET from every edge. */
static u32 pixel_of(u64 side, u64 px, u64 py) {
  u64 ink = (px >= INK_INSET) && (px < WIN_W - INK_INSET) && (py >= INK_INSET) &&
            (py < WIN_H - INK_INSET);
  if (side == 0) {
    return (u32)(ink ? A_INK : A_FILL);
  }
  return (u32)(ink ? B_INK : B_FILL);
}

/* Overwrites the D6 damage rectangle and returns the net change to the
 * surface sum: new words minus the words that were there. Adding this to
 * `paint`'s sum is what the host recomputes, so a client that skipped the
 * patch, painted the wrong colour, or painted it in the wrong place exits
 * with a different number. */
static u64 paint_damage(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 delta = 0;
  u64 py = 0;
  while (py < DMG_H) {
    u64 px = 0;
    while (px < DMG_W) {
      u64 i = (DMG_Y + py) * WIN_W + (DMG_X + px);
      u32 old = p[i];
      u32 c = (u32)DMG_INK;
      p[i] = c;
      delta += (u64)c;
      delta -= (u64)old;
      px++;
    }
    py++;
  }
  return delta;
}

/* Paints the whole surface and returns the sum of every word it wrote. The sum
 * is what this program exits with, so "the client painted what it says it
 * painted" is a number derive.py reproduces on the host. */
static u64 paint(u64 side, u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 sum = 0;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      u32 c = pixel_of(side, px, py);
      p[py * WIN_W + px] = c;
      sum += (u64)c;
      px++;
    }
    py++;
  }
  return sum;
}

void _start(void) {
  /* 1. WHICH SIDE AM I. The kernel decides, by answering the first caller with
   *    side 0 and the second with side 1. Nothing in this binary chooses. */
  u64 ep = sys1(SYS_CHANOPEN, 0);
  if (ep >= WM_FLOOR) {
    die(0xD2000001UL);
  }
  u64 side = ep & 1UL;

  /* 2. A REGION OF MY OWN. Read-write, because a client draws into its own
   *    surface; the compositor never maps it at all (it reads the frames). */
  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_FLOOR) {
    die(0xD2000002UL);
  }

  /* 3. ATTACH. **The reply is the address**, and it is the only way this
   *    program learns one. */
  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = h;
  desc[D_X] = (side == 0) ? A_X : B_X;
  desc[D_Y] = (side == 0) ? A_Y : B_Y;
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_STRIDE] = 0; /* no padding: the kernel fills in WIN_W * 4 */
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) {
    die(0xD2000003UL | (va << 32));
  }
  wr(msg_attach, sizeof(msg_attach) - 1);

  /* 4. PAINT. */
  u64 sum = paint(side, va);
  wr(msg_paint, sizeof(msg_paint) - 1);

  /* 5. COMMIT -- "this frame is ready". The first present is the whole
   *    surface, because the whole surface is what changed. D6 then uses that
   *    rectangle: the compositor paints the decorated window and nothing
   *    else. Side 1 follows it with a 16x16 present of a new colour -- that
   *    is the commit whose pixel count must come out SMALL. */
  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = h;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_SEQ] = 1;
  desc[7] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_FLOOR) {
    die(0xD2000004UL | (frames << 32));
  }
  wr(msg_commit, sizeof(msg_commit) - 1);
  scratch[0] = frames;

  if (side == 1) {
    sum += paint_damage(va);
    desc[D_OP] = WM_COMMIT;
    desc[D_HANDLE] = h;
    desc[D_X] = DMG_X;
    desc[D_Y] = DMG_Y;
    desc[D_W] = DMG_W;
    desc[D_H] = DMG_H;
    desc[D_SEQ] = 2;
    desc[7] = 0;
    frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
    if (frames >= WM_FLOOR) {
      die(0xD2000007UL | (frames << 32));
    }
    wr(msg_commit, sizeof(msg_commit) - 1);
    scratch[0] = frames;
  }

  /* 6. THE FORGED HANDLE. A capability this process was never given, asked for
   *    on a surface operation. It must come back WM_BADCAP -- the refusal that
   *    proves the descriptor's authority is a capability the KERNEL installed
   *    and not a number this program invented. Side 0 only, so the transcript
   *    carries exactly one of them. */
  if (side == 0) {
    desc[D_OP] = WM_ATTACH;
    desc[D_HANDLE] = 0x00000003FFFFFFFFUL;
    desc[D_X] = A_X;
    desc[D_Y] = A_Y;
    desc[D_W] = WIN_W;
    desc[D_H] = WIN_H;
    desc[D_STRIDE] = 0;
    desc[D_OFFSET] = 0;
    u64 forged = sys1(SYS_WMSURFACE, (u64)&desc[0]);
    if (forged != WM_BADCAP) {
      die(0xD2000005UL);
    }
    scratch[1] = forged;
  }

  /* 7. THE HANDOVER. Side 0 yields with its region alive and mapped so side 1
   *    can run; it does not run again until side 1 has exited. Side 1 HOLDS, so
   *    that the screen the harness photographs has two live surfaces on it. */
  if (side == 0) {
    sys1(SYS_YIELD, 0);
  } else {
    /* 9. THE HOLD. Busy, not a yield loop -- see this file's header. */
    {
      volatile u64 spin = 0;
      while (spin < HOLDSPIN) {
        spin = spin + 1;
      }
    }
  }

  /* 8. EXIT, with a number derived from the pixels it wrote. */
  if (marker != 0x00D2C0DE00D2C0DEUL) {
    die(0xD2000006UL);
  }
  die((side << 56) | (scratch[0] << 48) | (sum & 0x0000FFFFFFFFFFFFUL));
}
