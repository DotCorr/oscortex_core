#!/usr/bin/env python3
"""Generate ADR-0180 four-hundred-face UND batch artifacts."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

CORE = Path(__file__).resolve().parents[3]
CEF = (
    CORE
    / "build/cef-linux64/cef_binary_144.0.34+g8fc21c8+chromium-144.0.7559.261_linux64_minimal/Release/libcef.so"
)
HERE = Path(__file__).resolve().parent

BOUND_200 = """
memset memcpy memmove strlen memcmp bcmp memchr strncmp strcpy strcmp
strnlen strncpy strchr strrchr strstr strcat strspn strcspn strncat strcasecmp
strncasecmp wcsncmp wcslen wmemchr wcscmp wmemcmp wcschr iswdigit iswalnum wcspbrk
wcscpy towupper towlower strtol strtoul strtoll strtoull sched_yield getpid getpagesize
nanf nan getenv getauxval time usleep getuid isatty rand geteuid floorf ceilf truncf roundf
floor ceil trunc round putchar puts srand getppid sleep write read abort exit _exit unlink rename
mkdir rmdir access chmod fileno feof ferror fflush gethostname munmap mprotect alarm pause kill
dup dup2 pipe getpriority setpriority sinf cosf tanf expf logf powf fmodf socket sysconf hypotf
nearbyintf sin cos tan asin acos atan atan2 exp log exp2 log2 pow hypot sinh cosh tanh
asinf acosf atanf atan2f sinhf coshf tanhf exp2f log2f log10 log10f rint rintf nearbyint fma fmaf
modf modff frexp frexpf ldexp ldexpf cbrt cbrtf nextafter nextafterf acosh acoshf asinh asinhf
atanh atanhf scalbn remainder ilogbf erf erff log1p expm1f fread fwrite fseek ftell fgets fclose
fputs printf snprintf vsnprintf fprintf sprintf fputc getc ungetc setvbuf rewind setbuf
sigaction raise nanosleep clock_gettime signal strerror strerror_r uname opendir closedir madvise
tzset fork chdir poll qsort bind listen shutdown connect accept writev setsockopt getsockopt gmtime
gmtime_r mktime
""".split()

NEW_200 = """
select ioctl strdup strtod strftime fcntl prctl
sigemptyset sigfillset sigaddset sigdelset sigprocmask sigaltstack
sem_init sem_wait sem_post sem_destroy sem_timedwait
mmap64 open64 openat64 fopen64 fdopen lseek64 pread64 pwrite64
ftruncate64 fseeko64 ftello64 mkstemp64 mkostemp64 mkdtemp
readdir64 getgrnam getgrgid getpwuid
eventfd timerfd_create timerfd_settime
sched_setscheduler sched_getscheduler sched_getparam sched_getaffinity
newlocale freelocale uselocale strtod_l setlocale localeconv
setenv unsetenv setsid readlink setpgid execvp execlp execv system clone
vfprintf fchmod freeaddrinfo socketpair getsockname getpeername
inet_ntop inet_pton sendmsg recvmsg sendto
gai_strerror getifaddrs freeifaddrs mremap ppoll open_memstream
epoll_create1 epoll_create epoll_ctl epoll_wait msync
posix_fallocate64 posix_fadvise64 fallocate64 sendfile64
fdatasync utimensat futimens getrlimit64 setrlimit64
inotify_init inotify_add_watch inotify_rm_watch tcflush tcdrain
syscall remove pathconf fsync link symlink unlinkat getcwd realpath
gettimeofday difftime timegm wcstol swprintf vswprintf vasprintf
fmod log1pf lround lroundf llround llroundf
getopt_long waitpid waitid pipe2 flock lchown umask
mincore dirfd openlog syslog closelog
statvfs64 statfs64 fstatfs64 fnmatch creat64 fdopendir
wcrtomb mbrtowc wcsftime strndup
rand_r initstate_r random_r longjmp _setjmp
pthread_self pthread_once
pthread_mutex_init pthread_mutex_lock pthread_mutex_unlock
pthread_mutex_destroy pthread_mutex_trylock
pthread_mutexattr_init pthread_mutexattr_destroy
pthread_cond_init pthread_cond_wait pthread_cond_timedwait
pthread_cond_signal pthread_cond_broadcast pthread_cond_destroy
pthread_condattr_init pthread_condattr_setclock pthread_condattr_destroy
pthread_key_create pthread_key_delete pthread_getspecific pthread_setspecific
pthread_attr_init pthread_attr_destroy pthread_attr_setstacksize
pthread_attr_setdetachstate pthread_attr_getstack pthread_attr_getstacksize
pthread_create pthread_join pthread_detach
pthread_sigmask pthread_getschedparam pthread_setname_np
pthread_getname_np pthread_kill pthread_getattr_np
pkey_mprotect pkey_alloc pkey_set
send recv perror div shmdt shmctl shmget shmat
__cxa_finalize __cxa_atexit __errno_location
__ctype_b_loc __ctype_tolower_loc __ctype_toupper_loc __xpg_strerror_r if_indextoname
""".split()


def camel(name: str) -> str:
    if name.startswith("__"):
        return "X" + "".join(p.capitalize() for p in name[2:].split("_") if p)
    if name.startswith("_"):
        return "U" + "".join(p.capitalize() for p in name[1:].split("_") if p)
    return "".join(p.capitalize() for p in name.split("_") if p)


def str_bytes(name: str) -> list[int]:
    return [ord(c) for c in name] + [0]


def stub_c(name: str, *, tiny: bool = False) -> str:
    if tiny:
        return (
            f"__attribute__((naked)) int {name}(void) "
            f'{{ __asm__("mov $-1, %eax\\; ret"); }}'
        )
    ptr = {
        "strdup",
        "strndup",
        "gai_strerror",
        "getcwd",
        "realpath",
        "inet_ntop",
        "inet_pton",
        "localeconv",
        "open_memstream",
        "tmpfile64",
        "fdopen",
        "fopen64",
        "readdir64",
        "getgrnam",
        "getpwuid",
        "getgrgid",
        "getifaddrs",
        "newlocale",
        "uselocale",
        "setlocale",
        "mallinfo",
        "freelocale",
        "fdopendir",
        "pthread_getspecific",
        "__errno_location",
        "__ctype_b_loc",
        "__ctype_tolower_loc",
        "__ctype_toupper_loc",
    }
    if name in {"fmod", "difftime"}:
        return f"double {name}(double a, double b) {{ (void)a; (void)b; return 0.0; }}"
    if name == "log1pf":
        return f"float {name}(float x) {{ (void)x; return 0.0f; }}"
    if name == "lround":
        return f"long {name}(double x) {{ (void)x; return 0; }}"
    if name == "lroundf":
        return f"long {name}(float x) {{ (void)x; return 0; }}"
    if name == "llround":
        return f"long long {name}(double x) {{ (void)x; return 0; }}"
    if name == "llroundf":
        return f"long long {name}(float x) {{ (void)x; return 0; }}"
    if name == "wcstol":
        return (
            f"long {name}(const void *s, void *e, int b) "
            f"{{ (void)s; (void)e; (void)b; return 0; }}"
        )
    if name in {"strtod", "strtod_l"}:
        return (
            f"double {name}(const char *s, void *e) "
            f"{{ (void)s; (void)e; return 0.0; }}"
        )
    if name in {"strftime", "wcsftime"}:
        return (
            f"unsigned long {name}(void *s, unsigned long nmax, const void *fmt, "
            f"const void *tm) {{ (void)s; (void)nmax; (void)fmt; (void)tm; return 0; }}"
        )
    if name in {"pthread_self", "wcrtomb", "mbrtowc"}:
        return f"unsigned long {name}(void) {{ return 0; }}"
    if name in ptr:
        return f"void *{name}(void) {{ return (void *)0; }}"
    if name in {"freeaddrinfo", "freeifaddrs", "closelog", "openlog"}:
        return f"void {name}(void) {{}}"
    if name == "syslog":
        return f"void {name}(int p, const char *fmt) {{ (void)p; (void)fmt; }}"
    return f"int {name}(void) {{ return -1; }}"


def load_stubs() -> dict[str, int]:
    out = subprocess.check_output(
        ["x86_64-elf-objdump", "-d", "-j", ".plt", str(CEF)],
        text=True,
        errors="replace",
    )
    stubs: dict[str, int] = {}
    for m in re.finditer(r"^([0-9a-f]+)\s+<([^>]+)@plt>:", out, re.M):
        stubs[m.group(2)] = int(m.group(1), 16)
    return stubs


def main() -> None:
    bound = set(BOUND_200)
    assert len(bound) == 200, len(bound)
    names = []
    seen: set[str] = set()
    for n in NEW_200:
        if not n or n in seen:
            continue
        seen.add(n)
        names.append(n)
    assert len(names) == 200, len(names)

    stubs = load_stubs()
    face_start = 0xDCF7DD0
    face_max = 8192
    rows = []
    rejected = []
    for n in names:
        assert n not in bound, n
        assert n in stubs, n
        va = stubs[n]
        if face_start <= va < face_start + face_max:
            rejected.append(n)
            continue
        rows.append(
            {
                "name": n,
                "va": va,
                "off": va - 0x1000,
                "sym": camel(n),
                "stub": stub_c(n),
            }
        )
    if len(rows) < 200:
        deny = re.compile(
            r"^(cef_|OPENSSL|PK11|NSS_|SSL_|PR_|SEC_|CERT_|PORT_|ZSTD_|gbm_|snd_|"
            r"g_|gdk_|gtk_|atk_|pango|cairo|xkb_|udev_|drm_|wl_|wayland|vulkan|"
            r"Vk|EGL|GL|gl[A-Z]|_Z|__gcov|__res|__isoc|__fxstat|__xstat|__lxstat|"
            r"__memcpy|__libc|xcb_|X[A-Z]|_X|atspi_)"
        )
        have = {r["name"] for r in rows} | bound
        for n, va in sorted(stubs.items(), key=lambda x: x[0]):
            if len(rows) >= 200:
                break
            if n in have:
                continue
            if face_start <= va < face_start + face_max:
                continue
            if deny.match(n):
                continue
            if not re.match(r"^[a-z_][a-z0-9_]*$", n):
                continue
            rows.append(
                {
                    "name": n,
                    "va": va,
                    "off": va - 0x1000,
                    "sym": camel(n),
                    "stub": stub_c(n),
                }
            )
            have.add(n)
    assert len(rows) == 200, (len(rows), rejected[:20])

    (HERE / "faces400.json").write_text(json.dumps({"faces": rows}, indent=2) + "\n")

    # --- libc.c append ---
    libc = (HERE / "libc.c").read_text()
    head, tail = libc.split("/* Keep the final UND face body", 1)
    new_stubs = "\n".join(r["stub"] for r in rows) + "\n\n"
    libc_new = head + new_stubs + "/* Keep the final UND face body" + tail
    (HERE / "libc.c").write_text(libc_new)

    str_block = []
    plt_block = []
    phase_block = []
    for i, r in enumerate(rows):
        phase = 200 + i
        sym = r["sym"]
        name = r["name"]
        b = ", ".join(f"u8({x})" for x in str_bytes(name))
        str_block.append(
            f"/// ADR-0180 expanded UND batch (face {phase}).\n"
            f"@rodata\nfinal List<u8> elfStr{sym} = const [\n  {b},\n];"
        )
        plt_block.append(
            f"const int elfCef{sym}PltVaddr = 0x{r['va']:X};\n"
            f"const int elfCef{sym}PltOff = 0x{r['off']:X};"
        )
        phase_block.append(
            f"    if (phase == u64({phase})) {{\n"
            f"      namePtr = Rodata.addressOf(elfStr{sym});\n"
            f"      nameLen = u64({len(name)});\n"
            f"      pltOff = u64(elfCef{sym}PltOff);\n"
            f"      pltVa = u64(elfCef{sym}PltVaddr);\n"
            f"    }}"
        )

    patch = {
        "str_block": "\n".join(str_block),
        "plt_block": "\n".join(plt_block),
        "phase_block": "\n".join(phase_block),
        "last_face": rows[-1]["name"],
        "bound_list": ",".join(BOUND_200 + [r["name"] for r in rows]),
    }
    (HERE / "und400.patch.json").write_text(json.dumps(patch, indent=2) + "\n")
    print(f"gen-und400: wrote faces400.json + und400.patch.json; last={rows[-1]['name']}")


if __name__ == "__main__":
    main()
