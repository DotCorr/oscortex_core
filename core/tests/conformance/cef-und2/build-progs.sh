#!/usr/bin/env bash
# PLAT/ASK + LIBC.SO (400 UND faces) + CEF.SO ticket + host plant.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-nm python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror
)

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/plat.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/plat.elf" "$OUT/plat.o" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "no plat.elf"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — app ELF cap is 64 KiB"

SO_CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fPIC -fno-stack-protector -fno-asynchronous-unwind-tables
  -fno-builtin -Os -Wall -Wextra -Werror
)
clang "${SO_CFLAGS[@]}" "$SCRIPT_DIR/libc.c" -o "$OUT/libc.o" \
  || fail "clang could not compile libc.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -T "$SCRIPT_DIR/libc.ld" \
  -o "$OUT/libc.so" "$OUT/libc.o" \
  || fail "x86_64-elf-ld could not link libc.so"
[[ -s "$OUT/libc.so" ]] || fail "no libc.so"
x86_64-elf-readelf -hW "$OUT/libc.so" | grep -q "DYN (Shared object" \
  || fail "libc.so is not ET_DYN"

FACES=(
  memset
  memcpy
  memmove
  strlen
  memcmp
  bcmp
  memchr
  strncmp
  strcpy
  strcmp
  strnlen
  strncpy
  strchr
  strrchr
  strstr
  strcat
  strspn
  strcspn
  strncat
  strcasecmp
  strncasecmp
  wcsncmp
  wcslen
  wmemchr
  wcscmp
  wmemcmp
  wcschr
  iswdigit
  iswalnum
  wcspbrk
  wcscpy
  towupper
  towlower
  strtol
  strtoul
  strtoll
  strtoull
  sched_yield
  getpid
  getpagesize
  nanf
  nan
  getenv
  getauxval
  time
  usleep
  getuid
  isatty
  rand
  geteuid
  floorf
  ceilf
  truncf
  roundf
  floor
  ceil
  trunc
  round
  putchar
  puts
  srand
  getppid
  sleep
  write
  read
  abort
  exit
  _exit
  unlink
  rename
  mkdir
  rmdir
  access
  chmod
  fileno
  feof
  ferror
  fflush
  gethostname
  munmap
  mprotect
  alarm
  pause
  kill
  dup
  dup2
  pipe
  getpriority
  setpriority
  sinf
  cosf
  tanf
  expf
  logf
  powf
  fmodf
  socket
  sysconf
  hypotf
  nearbyintf
  sin
  cos
  tan
  asin
  acos
  atan
  atan2
  exp
  log
  exp2
  log2
  pow
  hypot
  sinh
  cosh
  tanh
  asinf
  acosf
  atanf
  atan2f
  sinhf
  coshf
  tanhf
  exp2f
  log2f
  log10
  log10f
  rint
  rintf
  nearbyint
  fma
  fmaf
  modf
  modff
  frexp
  frexpf
  ldexp
  ldexpf
  cbrt
  cbrtf
  nextafter
  nextafterf
  acosh
  acoshf
  asinh
  asinhf
  atanh
  atanhf
  scalbn
  remainder
  ilogbf
  erf
  erff
  log1p
  expm1f
  fread
  fwrite
  fseek
  ftell
  fgets
  fclose
  fputs
  printf
  snprintf
  vsnprintf
  fprintf
  sprintf
  fputc
  getc
  ungetc
  setvbuf
  rewind
  setbuf
  sigaction
  raise
  nanosleep
  clock_gettime
  signal
  strerror
  strerror_r
  uname
  opendir
  closedir
  madvise
  tzset
  fork
  chdir
  poll
  qsort
  bind
  listen
  shutdown
  connect
  accept
  writev
  setsockopt
  getsockopt
  gmtime
  gmtime_r
  mktime
  select
  ioctl
  strdup
  strtod
  strftime
  fcntl
  prctl
  sigemptyset
  sigfillset
  sigaddset
  sigdelset
  sigprocmask
  sigaltstack
  sem_init
  sem_wait
  sem_post
  sem_destroy
  sem_timedwait
  mmap64
  open64
  openat64
  fopen64
  fdopen
  lseek64
  pread64
  pwrite64
  ftruncate64
  fseeko64
  ftello64
  mkstemp64
  mkostemp64
  mkdtemp
  readdir64
  getgrnam
  getgrgid
  getpwuid
  eventfd
  timerfd_create
  timerfd_settime
  sched_setscheduler
  sched_getscheduler
  sched_getparam
  sched_getaffinity
  newlocale
  freelocale
  uselocale
  strtod_l
  setlocale
  localeconv
  setenv
  unsetenv
  setsid
  readlink
  setpgid
  execvp
  execlp
  execv
  system
  clone
  vfprintf
  fchmod
  freeaddrinfo
  socketpair
  getsockname
  inet_ntop
  sendmsg
  recvmsg
  gai_strerror
  getifaddrs
  freeifaddrs
  mremap
  ppoll
  open_memstream
  epoll_create1
  epoll_create
  epoll_ctl
  epoll_wait
  msync
  posix_fallocate64
  posix_fadvise64
  fallocate64
  sendfile64
  fdatasync
  utimensat
  futimens
  getrlimit64
  setrlimit64
  inotify_init
  inotify_add_watch
  inotify_rm_watch
  tcflush
  tcdrain
  syscall
  remove
  pathconf
  fsync
  link
  symlink
  unlinkat
  getcwd
  realpath
  gettimeofday
  difftime
  timegm
  wcstol
  swprintf
  vswprintf
  vasprintf
  fmod
  log1pf
  lround
  lroundf
  llround
  llroundf
  getopt_long
  waitpid
  waitid
  pipe2
  flock
  lchown
  umask
  mincore
  dirfd
  openlog
  syslog
  closelog
  statvfs64
  statfs64
  fstatfs64
  fnmatch
  creat64
  fdopendir
  wcrtomb
  mbrtowc
  wcsftime
  strndup
  rand_r
  initstate_r
  random_r
  longjmp
  _setjmp
  pthread_self
  pthread_once
  pthread_mutex_init
  pthread_mutex_lock
  pthread_mutex_unlock
  pthread_mutex_destroy
  pthread_mutex_trylock
  pthread_mutexattr_init
  pthread_mutexattr_destroy
  pthread_cond_init
  pthread_cond_wait
  pthread_cond_timedwait
  pthread_cond_signal
  pthread_cond_broadcast
  pthread_cond_destroy
  pthread_condattr_init
  pthread_condattr_setclock
  pthread_condattr_destroy
  pthread_key_create
  pthread_key_delete
  pthread_getspecific
  pthread_setspecific
  pthread_attr_init
  pthread_attr_destroy
  pthread_attr_setstacksize
  pthread_attr_setdetachstate
  pthread_attr_getstack
  pthread_attr_getstacksize
  pthread_create
  pthread_join
  pthread_detach
  pthread_sigmask
  pthread_getschedparam
  pthread_setname_np
  pthread_getname_np
  pthread_kill
  pthread_getattr_np
  pkey_mprotect
  pkey_alloc
  pkey_set
  __cxa_finalize
  __cxa_atexit
  __errno_location
  __ctype_b_loc
  __ctype_tolower_loc
  __ctype_toupper_loc
  __xpg_strerror_r
  __ctype_get_mb_cur_max
  __cxa_thread_atexit_impl
  __getdelim
  __longjmp_chk
  __mbrlen
  __register_atfork
  __sched_cpualloc
  __sched_cpucount
  __sched_cpufree
  __stack_chk_fail
  __tls_get_addr
  __udivti3
)
for face in "${FACES[@]}"; do
  x86_64-elf-nm "$OUT/libc.so" | grep -qE " [Tt] ${face}\$" \
    || fail "libc.so has no exported $face"
done
# Bodies live in the RX face slab; each body ≤ 160 bytes.
while read -r sz name; do
  [[ -n "$sz" ]] || continue
  SZ=$((16#$sz))
  [[ "$SZ" -le 160 ]] || fail "$name is $SZ bytes — face body max is 160"
done < <(x86_64-elf-nm -S "$OUT/libc.so" | awk '/ [Tt] /{print $2,$4}')

x86_64-elf-readelf -dW "$OUT/libc.so" | grep -q '(HASH)' \
  || fail "libc.so has no DT_HASH"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "libc.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "libc.so has no RX LOAD — call would be NX"
# ADR-0180: RX LOAD may span six pages (kernel copies page0+page1).
FSZ=$(x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD" && /R E|RE/ {print $5; exit}')
FSZ=$((16#${FSZ#0x}))
[[ "$FSZ" -le 24576 ]] || fail "RX LOAD filesz $FSZ exceeds three pages"
SO_BYTES=$(wc -c <"$OUT/libc.so" | tr -d ' ')
[[ "$SO_BYTES" -le 65536 ]] || fail "libc.so is $SO_BYTES bytes"
x86_64-elf-nm "$OUT/libc.so" | grep ' U ' && fail "libc.so has UND refs" || true

READY="$CORE_DIR/build/cef-linux64/READY"
if [[ ! -f "$READY" ]]; then
  bash "$CORE_DIR/scripts/fetch-cef-linux64.sh" \
    || fail "fetch-cef-linux64.sh failed"
fi
CEF_LIB=$(grep -m1 '^CEF_LIB=' "$READY" | cut -d= -f2-)
[[ -f "$CEF_LIB" ]] || fail "CEF_LIB missing: $CEF_LIB"

python3 "$CORE_DIR/scripts/pack-cef-slice.py" "$CEF_LIB" "$OUT/cef.so" \
  || fail "pack-cef-slice.py failed"
CEF_BYTES=$(wc -c <"$OUT/cef.so" | tr -d ' ')
[[ "$CEF_BYTES" -le 65536 ]] || fail "cef.so ticket too big"

python3 "$CORE_DIR/scripts/pack-cef-loads.py" "$CEF_LIB" "$OUT/cef-plant.bin" \
  || fail "pack-cef-loads.py failed"
PLANT_BYTES=$(wc -c <"$OUT/cef-plant.bin" | tr -d ' ')
[[ "$PLANT_BYTES" -eq 231711248 ]] \
  || fail "plant is $PLANT_BYTES, expected 231711248"
[[ "$PLANT_BYTES" -gt 12288 ]] || fail "plant not larger than slice"

python3 - "$OUT/cef-plant.bin" <<'PY' || fail "memset@plt not in plant"
import sys
plant = open(sys.argv[1], "rb").read()
off = 0xDCFA1E0
stub = plant[off:off + 6]
if stub[:2] != bytes([0xFF, 0x25]):
    raise SystemExit("plant memset@plt stub drifted: %r" % stub.hex())
print("plant: memset@plt at off 0x%x ok" % off)
PY

echo "build-progs: PASS — plat.elf ($BYTES) + libc.so ($SO_BYTES) + cef.so ($CEF_BYTES) + plant ($PLANT_BYTES) + 400 faces"
exit 0
