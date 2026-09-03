/* Host simulator of the Skia bump protocol. Does not compile guest_crt.c
 * (com1 inb/outb). Asserts: no rewind while a live object exists, client
 * reclaim is bounded, chrome seal is not the Graphite watermark. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { HEAP_CAP = 3 * 1024 * 1024 };

static unsigned char heap[HEAP_CAP];
static size_t heap_used;
static size_t heap_watermark;
static size_t heap_chrome_mark;
static size_t heap_high_water;
static int heap_reclaim_armed;
static int live_chrome;
static int live_client;
static int fail_n;

static void fail(const char *m) {
  fprintf(stderr, "de-heap-life: FAIL — %s\n", m);
  fail_n = fail_n + 1;
}

static void *bump(size_t n) {
  size_t aligned;
  void *p;

  if (n == 0) {
    n = 1;
  }
  aligned = (n + 15u) & ~15u;
  if (heap_used + aligned > HEAP_CAP) {
    if (heap_reclaim_armed == 0 || heap_chrome_mark == 0 ||
        heap_used <= heap_chrome_mark ||
        heap_chrome_mark + aligned > HEAP_CAP) {
      return 0;
    }
    if (live_chrome != 0 && heap_chrome_mark < heap_used && live_client != 0) {
      fail("OOM reclaim while a live unique_ptr exists");
      return 0;
    }
    heap_used = heap_chrome_mark;
  }
  p = heap + heap_used;
  heap_used = heap_used + aligned;
  if (heap_used > heap_high_water) {
    heap_high_water = heap_used;
  }
  return p;
}

static void chrome_seal(void) {
  heap_chrome_mark = heap_used;
  heap_reclaim_armed = 0;
}

static void client_begin(void) {
  if (live_client != 0) {
    fail("client_begin while client unique_ptr is live");
  }
  if (heap_chrome_mark == 0) {
    /* Must not fall back to the Graphite watermark. */
    return;
  }
  if (heap_used > heap_chrome_mark) {
    heap_used = heap_chrome_mark;
  }
  heap_reclaim_armed = 1;
}

static void release_client(void) {
  live_client = 0;
  client_begin();
}

static void drop_both_then_rewind(void) {
  live_chrome = 0;
  live_client = 0;
  heap_chrome_mark = 0;
  heap_reclaim_armed = 0;
  if (heap_watermark > 0 && heap_used > heap_watermark) {
    heap_used = heap_watermark;
  }
}

int main(void) {
  int i;
  size_t after_seal;
  void *p;

  memset(heap, 0, sizeof(heap));
  heap_used = 64 * 1024;
  heap_watermark = heap_used;
  heap_high_water = heap_used;

  /* First chrome bind + shaders. Seal AFTER paint, not at bind. */
  p = bump(48 * 1024);
  if (p == 0) {
    fail("chrome canvas alloc");
  }
  live_chrome = 1;
  p = bump(96 * 1024);
  if (p == 0) {
    fail("chrome shader alloc");
  }
  chrome_seal();
  after_seal = heap_used;
  if (heap_chrome_mark != after_seal) {
    fail("seal is not post-paint heap_used");
  }

  for (i = 0; i < 200; i = i + 1) {
    if (live_chrome == 0) {
      fail("g_one dropped during client stress");
      break;
    }
    p = bump(24 * 1024);
    if (p == 0) {
      fail("client alloc");
      break;
    }
    live_client = 1;
    /* Paint records sit above the seal. */
    p = bump(8 * 1024);
    if (p == 0) {
      fail("client record alloc");
      break;
    }
    release_client();
    if (heap_used > after_seal) {
      fail("client rewind did not return to chrome seal");
      break;
    }
    if (live_client != 0) {
      fail("client unique_ptr still live after release");
      break;
    }
  }

  if (heap_high_water > after_seal + 64 * 1024) {
    fail("high-water grew more than one client burst above the seal");
  }
  if (heap_used != after_seal) {
    fail("steady-state heap_used is not the chrome seal");
  }

  /* Full drop then rewind is allowed only after both unique_ptrs die. */
  live_chrome = 1;
  live_client = 1;
  drop_both_then_rewind();
  if (live_chrome != 0 || live_client != 0) {
    fail("full rewind left a live unique_ptr");
  }
  if (heap_used != heap_watermark) {
    fail("full rewind did not return to the Graphite watermark");
  }

  /* client_begin must not use the watermark while chrome is unsealed. */
  heap_chrome_mark = 0;
  heap_used = heap_watermark + 4096;
  live_client = 0;
  client_begin();
  if (heap_used != heap_watermark + 4096) {
    fail("unsealed client_begin rewound to the Graphite watermark");
  }

  if (fail_n != 0) {
    fprintf(stderr, "de-heap-life: %d protocol failure(s)\n", fail_n);
    return 1;
  }
  printf("de-heap-life: host protocol 200 cycles, high-water %zu cap %d seal %zu\n",
         heap_high_water, HEAP_CAP, after_seal);
  return 0;
}
