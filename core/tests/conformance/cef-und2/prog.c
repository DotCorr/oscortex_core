/* core/tests/conformance/cef-und2/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 *
 *   PLAT.ELF — dlopen("CEF.SO") maps official LOADs; kernel opens
 *              LIBC.SO and binds ≥400 measured high-traffic UND faces
 *              through OUR trampolines. Call each official @plt;
 *              derived LINE folds every face. Unbound PLT → #PF.
 *   ASK.ELF  — same bytes; dlopen is BadArg.
 *
 * Measured: official libcef PLT has no allocator JUMP_SLOT.
 * Not OnPaint. Not real libdl.so.2. Syscall 29. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define MIX 0x0000000000000180UL
#define CEF_INIT_VA 0x2CE7700UL
#define MEMSET_PLT_VA 0xDCFB1E0UL
#define MEMCPY_PLT_VA 0xDCFB030UL
#define MEMMOVE_PLT_VA 0xDCFB1F0UL
#define STRLEN_PLT_VA 0xDCF5E20UL
#define MEMCMP_PLT_VA 0xDCF5E60UL
#define BCMP_PLT_VA 0xDCF5FA0UL
#define MEMCHR_PLT_VA 0xDCF6090UL
#define STRNCMP_PLT_VA 0xDCF60D0UL
#define STRCPY_PLT_VA 0xDCF63A0UL
#define STRCMP_PLT_VA 0xDCF6450UL
#define STRNLEN_PLT_VA 0xDCF64A0UL
#define STRNCPY_PLT_VA 0xDCF64B0UL
#define STRCHR_PLT_VA 0xDCF66D0UL
#define STRRCHR_PLT_VA 0xDCF6960UL
#define STRSTR_PLT_VA 0xDCF6CA0UL
#define STRCAT_PLT_VA 0xDCF7870UL
#define STRSPN_PLT_VA 0xDCF6C80UL
#define STRCSPN_PLT_VA 0xDCF6C90UL
#define STRNCAT_PLT_VA 0xDCF7DC0UL
#define STRCASECMP_PLT_VA 0xDCF6530UL
#define STRNCASECMP_PLT_VA 0xDCF7580UL
#define WCSNCMP_PLT_VA 0xDCF60C0UL
#define WCSLEN_PLT_VA 0xDCF62B0UL
#define WMEMCHR_PLT_VA 0xDCF62C0UL
#define WCSCMP_PLT_VA 0xDCF7810UL
#define WMEMCMP_PLT_VA 0xDCF7820UL
#define WCSCHR_PLT_VA 0xDCF7880UL
#define ISWDIGIT_PLT_VA 0xDCF77F0UL
#define ISWALNUM_PLT_VA 0xDCF78A0UL
#define WCSPBRK_PLT_VA 0xDCFAA20UL
#define WCSCPY_PLT_VA 0xDCFAA30UL
#define TOWUPPER_PLT_VA 0xDCFAA60UL
#define TOWLOWER_PLT_VA 0xDCFAA70UL
#define STRTOL_PLT_VA 0xDCF61D0UL
#define STRTOUL_PLT_VA 0xDCF6690UL
#define STRTOLL_PLT_VA 0xDCF6410UL
#define STRTOULL_PLT_VA 0xDCF6920UL
#define SCHED_YIELD_PLT_VA 0xDCF6390UL
#define GETPID_PLT_VA 0xDCF6190UL
#define GETPAGESIZE_PLT_VA 0xDCF6470UL
#define NANF_PLT_VA 0xDCF6290UL
#define NAN_PLT_VA 0xDCF6280UL
#define GETENV_PLT_VA 0xDCF6440UL
#define GETAUXVAL_PLT_VA 0xDCF6480UL
#define TIME_PLT_VA 0xDCF6520UL
#define USLEEP_PLT_VA 0xDCF67C0UL
#define GETUID_PLT_VA 0xDCF7680UL
#define ISATTY_PLT_VA 0xDCF68D0UL
#define RAND_PLT_VA 0xDCF7650UL
#define GETEUID_PLT_VA 0xDCF66A0UL
#define FLOORF_PLT_VA 0xDCF6CB0UL
#define CEILF_PLT_VA 0xDCF7610UL
#define TRUNCF_PLT_VA 0xDCF7620UL
#define ROUNDF_PLT_VA 0xDCF6CC0UL
#define FLOOR_PLT_VA 0xDCFB070UL
#define CEIL_PLT_VA 0xDCFB0E0UL
#define TRUNC_PLT_VA 0xDCFB110UL
#define ROUND_PLT_VA 0xDCFB060UL
#define PUTCHAR_PLT_VA 0xDCF78F0UL
#define PUTS_PLT_VA 0xDCF6130UL
#define SRAND_PLT_VA 0xDCF7640UL
#define GETPPID_PLT_VA 0xDCF68B0UL
#define SLEEP_PLT_VA 0xDCFA490UL
#define WRITE_PLT_VA 0xDCF65D0UL
#define READ_PLT_VA 0xDCF61C0UL
#define ABORT_PLT_VA 0xDCF6250UL
#define EXIT_PLT_VA 0xDCF6590UL
#define _EXIT_PLT_VA 0xDCF6560UL
#define UNLINK_PLT_VA 0xDCF67A0UL
#define RENAME_PLT_VA 0xDCF6170UL
#define MKDIR_PLT_VA 0xDCF6600UL
#define RMDIR_PLT_VA 0xDCF6610UL
#define ACCESS_PLT_VA 0xDCF6620UL
#define CHMOD_PLT_VA 0xDCF66B0UL
#define FILENO_PLT_VA 0xDCF65E0UL
#define FEOF_PLT_VA 0xDCF6010UL
#define FERROR_PLT_VA 0xDCF62E0UL
#define FFLUSH_PLT_VA 0xDCF6030UL
#define GETHOSTNAME_PLT_VA 0xDCF7660UL
#define MUNMAP_PLT_VA 0xDCF63D0UL
#define MPROTECT_PLT_VA 0xDCF66E0UL
#define ALARM_PLT_VA 0xDCF6500UL
#define PAUSE_PLT_VA 0xDCF7590UL
#define KILL_PLT_VA 0xDCF6890UL
#define DUP_PLT_VA 0xDCF68E0UL
#define DUP2_PLT_VA 0xDCF6840UL
#define PIPE_PLT_VA 0xDCF6720UL
#define GETPRIORITY_PLT_VA 0xDCF6770UL
#define SETPRIORITY_PLT_VA 0xDCF6740UL
#define SINF_PLT_VA 0xDCFA4A0UL
#define COSF_PLT_VA 0xDCFA4B0UL
#define TANF_PLT_VA 0xDCFA4C0UL
#define EXPF_PLT_VA 0xDCFA530UL
#define LOGF_PLT_VA 0xDCFA540UL
#define POWF_PLT_VA 0xDCFB190UL
#define FMODF_PLT_VA 0xDCFB1B0UL
#define SOCKET_PLT_VA 0xDCF6A00UL
#define SYSCONF_PLT_VA 0xDCF63E0UL
#define HYPOTF_PLT_VA 0xDCF7790UL
#define NEARBYINTF_PLT_VA 0xDCF7630UL
#define SIN_PLT_VA 0xDCF9620UL
#define COS_PLT_VA 0xDCF9630UL
#define TAN_PLT_VA 0xDCF9640UL
#define ASIN_PLT_VA 0xDCF9650UL
#define ACOS_PLT_VA 0xDCF9660UL
#define ATAN_PLT_VA 0xDCF9670UL
#define ATAN2_PLT_VA 0xDCF96C0UL
#define EXP_PLT_VA 0xDCF9680UL
#define LOG_PLT_VA 0xDCF9690UL
#define EXP2_PLT_VA 0xDCF96A0UL
#define LOG2_PLT_VA 0xDCF96B0UL
#define POW_PLT_VA 0xDCF96D0UL
#define HYPOT_PLT_VA 0xDCF96E0UL
#define SINH_PLT_VA 0xDCF9700UL
#define COSH_PLT_VA 0xDCF9710UL
#define TANH_PLT_VA 0xDCF9720UL
#define ASINF_PLT_VA 0xDCFA4D0UL
#define ACOSF_PLT_VA 0xDCFA4E0UL
#define ATANF_PLT_VA 0xDCFA4F0UL
#define ATAN2F_PLT_VA 0xDCFB0A0UL
#define SINHF_PLT_VA 0xDCFA500UL
#define COSHF_PLT_VA 0xDCFA510UL
#define TANHF_PLT_VA 0xDCFA520UL
#define EXP2F_PLT_VA 0xDCFA550UL
#define LOG2F_PLT_VA 0xDCFB0B0UL
#define LOG10_PLT_VA 0xDCFB090UL
#define LOG10F_PLT_VA 0xDCFB040UL
#define RINT_PLT_VA 0xDCFB0C0UL
#define RINTF_PLT_VA 0xDCFB100UL
#define NEARBYINT_PLT_VA 0xDCFB130UL
#define FMA_PLT_VA 0xDCFB120UL
#define FMAF_PLT_VA 0xDCFB0D0UL
#define MODF_PLT_VA 0xDCFB170UL
#define MODFF_PLT_VA 0xDCFB140UL
#define FREXP_PLT_VA 0xDCF62A0UL
#define FREXPF_PLT_VA 0xDCFB150UL
#define LDEXP_PLT_VA 0xDCF6270UL
#define LDEXPF_PLT_VA 0xDCF7AA0UL
#define CBRT_PLT_VA 0xDCF6C50UL
#define CBRTF_PLT_VA 0xDCF6BE0UL
#define NEXTAFTER_PLT_VA 0xDCF6A60UL
#define NEXTAFTERF_PLT_VA 0xDCF6C70UL
#define ACOSH_PLT_VA 0xDCF74F0UL
#define ACOSHF_PLT_VA 0xDCF7500UL
#define ASINH_PLT_VA 0xDCF7510UL
#define ASINHF_PLT_VA 0xDCF7520UL
#define ATANH_PLT_VA 0xDCF7530UL
#define ATANHF_PLT_VA 0xDCF7540UL
#define SCALBN_PLT_VA 0xDCF7720UL
#define REMAINDER_PLT_VA 0xDCF9040UL
#define ILOGBF_PLT_VA 0xDCF9100UL
#define ERF_PLT_VA 0xDCF6BD0UL
#define ERFF_PLT_VA 0xDCF9110UL
#define LOG1P_PLT_VA 0xDCF7710UL
#define EXPM1F_PLT_VA 0xDCF6BC0UL
#define FREAD_PLT_VA 0xDCF5FE0UL
#define FWRITE_PLT_VA 0xDCF6020UL
#define FSEEK_PLT_VA 0xDCF5FF0UL
#define FTELL_PLT_VA 0xDCF6000UL
#define FGETS_PLT_VA 0xDCF6070UL
#define FCLOSE_PLT_VA 0xDCF6080UL
#define FPUTS_PLT_VA 0xDCF6160UL
#define PRINTF_PLT_VA 0xDCF60E0UL
#define SNPRINTF_PLT_VA 0xDCF62D0UL
#define VSNPRINTF_PLT_VA 0xDCF6260UL
#define FPRINTF_PLT_VA 0xDCF6580UL
#define SPRINTF_PLT_VA 0xDCF7910UL
#define FPUTC_PLT_VA 0xDCF6BF0UL
#define GETC_PLT_VA 0xDCF9780UL
#define UNGETC_PLT_VA 0xDCFAEA0UL
#define SETVBUF_PLT_VA 0xDCF75A0UL
#define REWIND_PLT_VA 0xDCF75B0UL
#define SETBUF_PLT_VA 0xDCFAE90UL
#define SIGACTION_PLT_VA 0xDCF6110UL
#define RAISE_PLT_VA 0xDCF6120UL
#define NANOSLEEP_PLT_VA 0xDCF61E0UL
#define CLOCK_GETTIME_PLT_VA 0xDCF61F0UL
#define SIGNAL_PLT_VA 0xDCF6510UL
#define STRERROR_PLT_VA 0xDCF65A0UL
#define STRERROR_R_PLT_VA 0xDCF6570UL
#define UNAME_PLT_VA 0xDCF65B0UL
#define OPENDIR_PLT_VA 0xDCF6630UL
#define CLOSEDIR_PLT_VA 0xDCF66C0UL
#define MADVISE_PLT_VA 0xDCF66F0UL
#define TZSET_PLT_VA 0xDCF67D0UL
#define FORK_PLT_VA 0xDCF6810UL
#define CHDIR_PLT_VA 0xDCF6830UL
#define POLL_PLT_VA 0xDCF6860UL
#define QSORT_PLT_VA 0xDCF6B90UL
#define BIND_PLT_VA 0xDCF69A0UL
#define LISTEN_PLT_VA 0xDCF69B0UL
#define SHUTDOWN_PLT_VA 0xDCF69C0UL
#define CONNECT_PLT_VA 0xDCF6A10UL
#define ACCEPT_PLT_VA 0xDCF6A40UL
#define WRITEV_PLT_VA 0xDCF6940UL
#define SETSOCKOPT_PLT_VA 0xDCF6990UL
#define GETSOCKOPT_PLT_VA 0xDCF69F0UL
#define GMTIME_PLT_VA 0xDCF6A50UL
#define GMTIME_R_PLT_VA 0xDCF6460UL
#define MKTIME_PLT_VA 0xDCF6040UL
#define FILL 0xA5UL
#define FILL_N 64UL
#define BATCH 400UL

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call progMain\n"
    "1:\n"
    "  pause\n"
    "  jmp 1b\n"
    ".size _start, . - _start\n");

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

typedef void *(*memset_fn)(void *dst, int c, unsigned long n);
typedef void *(*memcpy_fn)(void *dst, const void *src, unsigned long n);
typedef void *(*memmove_fn)(void *dst, const void *src, unsigned long n);
typedef unsigned long (*strlen_fn)(const char *s);
typedef int (*memcmp_fn)(const void *a, const void *b, unsigned long n);
typedef int (*bcmp_fn)(const void *a, const void *b, unsigned long n);
typedef void *(*memchr_fn)(const void *s, int c, unsigned long n);
typedef int (*strncmp_fn)(const char *a, const char *b, unsigned long n);
typedef char *(*strcpy_fn)(char *dst, const char *src);
typedef int (*strcmp_fn)(const char *a, const char *b);
typedef unsigned long (*strnlen_fn)(const char *s, unsigned long n);
typedef char *(*strncpy_fn)(char *dst, const char *src, unsigned long n);
typedef char *(*strchr_fn)(const char *s, int c);
typedef char *(*strrchr_fn)(const char *s, int c);
typedef char *(*strstr_fn)(const char *hay, const char *ndl);
typedef char *(*strcat_fn)(char *dst, const char *src);
typedef unsigned long (*strspn_fn)(const char *s, const char *accept);
typedef unsigned long (*strcspn_fn)(const char *s, const char *reject);
typedef char *(*strncat_fn)(char *dst, const char *src, unsigned long n);
typedef int (*strcasecmp_fn)(const char *a, const char *b);
typedef int (*strncasecmp_fn)(const char *a, const char *b, unsigned long n);
typedef int (*wcsncmp_fn)(const int *a, const int *b, unsigned long n);
typedef unsigned long (*wcslen_fn)(const int *s);
typedef int *(*wmemchr_fn)(const int *s, int c, unsigned long n);
typedef int (*wcscmp_fn)(const int *a, const int *b);
typedef int (*wmemcmp_fn)(const int *a, const int *b, unsigned long n);
typedef int *(*wcschr_fn)(const int *s, int c);
typedef int (*iswdigit_fn)(int c);
typedef int (*iswalnum_fn)(int c);
typedef int *(*wcspbrk_fn)(const int *s, const int *accept);
typedef int *(*wcscpy_fn)(int *dst, const int *src);
typedef int (*towupper_fn)(int c);
typedef int (*towlower_fn)(int c);
typedef long (*strtol_fn)(const char *s, char **end, int base);
typedef unsigned long (*strtoul_fn)(const char *s, char **end, int base);
typedef long long (*strtoll_fn)(const char *s, char **end, int base);
typedef unsigned long long (*strtoull_fn)(const char *s, char **end, int base);
typedef int (*sched_yield_fn)(void);
typedef int (*getpid_fn)(void);
typedef int (*getpagesize_fn)(void);
typedef float (*nanf_fn)(const char *tag);
typedef double (*nan_fn)(const char *tag);
typedef char *(*getenv_fn)(const char *name);
typedef unsigned long (*getauxval_fn)(unsigned long type);
typedef long (*time_fn)(long *t);
typedef int (*usleep_fn)(unsigned int usec);
typedef unsigned (*getuid_fn)(void);
typedef int (*isatty_fn)(int fd);
typedef int (*rand_fn)(void);
typedef unsigned (*geteuid_fn)(void);

typedef float (*floorf_fn)(float);
typedef float (*ceilf_fn)(float);
typedef float (*truncf_fn)(float);
typedef float (*roundf_fn)(float);
typedef double (*floor_fn)(double);
typedef double (*ceil_fn)(double);
typedef double (*trunc_fn)(double);
typedef double (*round_fn)(double);
typedef int (*putchar_fn)(int);
typedef int (*puts_fn)(const char *);
typedef void (*srand_fn)(unsigned);
typedef int (*getppid_fn)(void);
typedef unsigned (*sleep_fn)(unsigned);
typedef long (*write_fn)(int, const void *, unsigned long);
typedef long (*read_fn)(int, void *, unsigned long);
typedef void (*abort_fn)(void);
typedef void (*exit_fn)(int);
typedef void (*_exit_fn)(int);
typedef int (*unlink_fn)(const char *);
typedef int (*rename_fn)(const char *, const char *);
typedef int (*mkdir_fn)(const char *, int);
typedef int (*rmdir_fn)(const char *);
typedef int (*access_fn)(const char *, int);
typedef int (*chmod_fn)(const char *, int);
typedef int (*fileno_fn)(void *);
typedef int (*feof_fn)(void *);
typedef int (*ferror_fn)(void *);
typedef int (*fflush_fn)(void *);
typedef int (*gethostname_fn)(char *, unsigned long);
typedef int (*munmap_fn)(void *, unsigned long);
typedef int (*mprotect_fn)(void *, unsigned long, int);
typedef unsigned (*alarm_fn)(unsigned);
typedef int (*pause_fn)(void);
typedef int (*kill_fn)(int, int);
typedef int (*dup_fn)(int);
typedef int (*dup2_fn)(int, int);
typedef int (*pipe_fn)(int *);
typedef int (*getpriority_fn)(int, int);
typedef int (*setpriority_fn)(int, int, int);
typedef float (*sinf_fn)(float);
typedef float (*cosf_fn)(float);
typedef float (*tanf_fn)(float);
typedef float (*expf_fn)(float);
typedef float (*logf_fn)(float);
typedef float (*powf_fn)(float, float);
typedef float (*fmodf_fn)(float, float);
typedef int (*socket_fn)(int, int, int);
typedef long (*sysconf_fn)(int);
typedef float (*hypotf_fn)(float, float);
typedef float (*nearbyintf_fn)(float);
typedef double (*sin_fn)(double);
typedef double (*cos_fn)(double);
typedef double (*tan_fn)(double);
typedef double (*asin_fn)(double);
typedef double (*acos_fn)(double);
typedef double (*atan_fn)(double);
typedef double (*atan2_fn)(double, double);
typedef double (*exp_fn)(double);
typedef double (*log_fn)(double);
typedef double (*exp2_fn)(double);
typedef double (*log2_fn)(double);
typedef double (*pow_fn)(double, double);
typedef double (*hypot_fn)(double, double);
typedef double (*sinh_fn)(double);
typedef double (*cosh_fn)(double);
typedef double (*tanh_fn)(double);
typedef float (*asinf_fn)(float);
typedef float (*acosf_fn)(float);
typedef float (*atanf_fn)(float);
typedef float (*atan2f_fn)(float, float);
typedef float (*sinhf_fn)(float);
typedef float (*coshf_fn)(float);
typedef float (*tanhf_fn)(float);
typedef float (*exp2f_fn)(float);
typedef float (*log2f_fn)(float);
typedef double (*log10_fn)(double);
typedef float (*log10f_fn)(float);
typedef double (*rint_fn)(double);
typedef float (*rintf_fn)(float);
typedef double (*nearbyint_fn)(double);
typedef double (*fma_fn)(double, double, double);
typedef float (*fmaf_fn)(float, float, float);
typedef double (*modf_fn)(double, double *);
typedef float (*modff_fn)(float, float *);
typedef double (*frexp_fn)(double, int *);
typedef float (*frexpf_fn)(float, int *);
typedef double (*ldexp_fn)(double, int);
typedef float (*ldexpf_fn)(float, int);
typedef double (*cbrt_fn)(double);
typedef float (*cbrtf_fn)(float);
typedef double (*nextafter_fn)(double, double);
typedef float (*nextafterf_fn)(float, float);
typedef double (*acosh_fn)(double);
typedef float (*acoshf_fn)(float);
typedef double (*asinh_fn)(double);
typedef float (*asinhf_fn)(float);
typedef double (*atanh_fn)(double);
typedef float (*atanhf_fn)(float);
typedef double (*scalbn_fn)(double, int);
typedef double (*remainder_fn)(double, double);
typedef int (*ilogbf_fn)(float);
typedef double (*erf_fn)(double);
typedef float (*erff_fn)(float);
typedef double (*log1p_fn)(double);
typedef float (*expm1f_fn)(float);
typedef unsigned long (*fread_fn)(void *, unsigned long, unsigned long, void *);
typedef unsigned long (*fwrite_fn)(void *, unsigned long, unsigned long, void *);
typedef int (*fseek_fn)(void *, long, int);
typedef long (*ftell_fn)(void *);
typedef char *(*fgets_fn)(char *, int, void *);
typedef int (*fclose_fn)(void *);
typedef int (*fputs_fn)(const char *, void *);
typedef int (*printf_fn)(const char *, ...);
typedef int (*snprintf_fn)(char *, unsigned long, const char *, ...);
typedef int (*vsnprintf_fn)(char *, unsigned long, const char *, void *);
typedef int (*fprintf_fn)(void *, const char *, ...);
typedef int (*sprintf_fn)(char *, const char *, ...);
typedef int (*fputc_fn)(int, void *);
typedef int (*getc_fn)(void *);
typedef int (*ungetc_fn)(int, void *);
typedef int (*setvbuf_fn)(void *, char *, int, unsigned long);
typedef void (*rewind_fn)(void *);
typedef void (*setbuf_fn)(void *, char *);
typedef int (*sigaction_fn)(int, const void *, void *);
typedef int (*raise_fn)(int);
typedef int (*nanosleep_fn)(const void *, void *);
typedef int (*clock_gettime_fn)(int, void *);
typedef void *(*signal_fn)(int, void *);
typedef char *(*strerror_fn)(int);
typedef int (*strerror_r_fn)(int, char *, unsigned long);
typedef int (*uname_fn)(void *);
typedef void *(*opendir_fn)(const char *);
typedef int (*closedir_fn)(void *);
typedef int (*madvise_fn)(void *, unsigned long, int);
typedef void (*tzset_fn)(void);
typedef int (*fork_fn)(void);
typedef int (*chdir_fn)(const char *);
typedef int (*poll_fn)(void *, unsigned long, int);
typedef void (*qsort_fn)(void *, unsigned long, unsigned long, void *);
typedef int (*bind_fn)(int, const void *, unsigned);
typedef int (*listen_fn)(int, int);
typedef int (*shutdown_fn)(int, int);
typedef int (*connect_fn)(int, const void *, unsigned);
typedef int (*accept_fn)(int, void *, void *);
typedef long (*writev_fn)(int, const void *, int);
typedef int (*setsockopt_fn)(int, int, int, void *, void *);
typedef int (*getsockopt_fn)(int, int, int, void *, void *);
typedef void *(*gmtime_fn)(const long *);
typedef void *(*gmtime_r_fn)(const long *, void *);
typedef long (*mktime_fn)(void *);

const char msgStart[] = "CEFUND2 START";
const char nameCef[] = "CEF.SO";

char out[160];
unsigned char buf[64];
unsigned char src[64];
unsigned char dst[64];
char zstr[] = "oscortex";
char scratch[80];
char needle[] = "cor";
char accept[] = "oscrtex";
char reject[] = "XYZ";
char caseA[] = "AbC";
char caseB[] = "aBc";
int wz[] = {'o', 's', 'c', 'o', 'r', 't', 'e', 'x', 0};
int wacc[] = {'o', 's', 'c', 0};
char num[] = "42";

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

static unsigned long put64(unsigned long at, unsigned long v) {
  unsigned long j;
  for (j = 0; j < 16; j++) {
    out[at + j] = hex(v >> (60 - 4 * j));
  }
  return at + 16;
}

static unsigned long putstr(unsigned long at, const char *s) {
  while (*s) {
    out[at++] = *s++;
  }
  return at;
}

static void say(const char *tag, unsigned long v) {
  unsigned long n = 0;
  n = putstr(n, tag);
  out[n++] = ' ';
  n = put64(n, v);
  sys(SYS_WRITE, (unsigned long)out, n);
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long cef, bad, bias, i, sig, got, n, fold;
  long lv;
  char *p;
  int *wp;
  int wscratch[16];
  float ff;
  double dd;
  unsigned u;
  long long ll;
  unsigned long long ull;

  (void)probe;
  bad = 0;
  fold = 0;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  cef = sys(SYS_DLOPEN, (unsigned long)nameCef, sizeof(nameCef) - 1);
  say("CEF", cef);

  if (cef > ERR_FLOOR) {
    if (cef != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    bias = cef - CEF_INIT_VA;
    say("PLT", bias + MEMSET_PLT_VA);
    say("BATCH", BATCH);

    /* memset */
    i = 0;
    while (i < FILL_N) {
      buf[i] = 0;
      i++;
    }
    got = (unsigned long)((memset_fn)(bias + MEMSET_PLT_VA))(buf, (int)FILL,
                                                             FILL_N);
    if (got != (unsigned long)buf) {
      bad++;
    }
    i = 0;
    while (i < FILL_N) {
      if (buf[i] != (unsigned char)FILL) {
        bad++;
      }
      i++;
    }

    /* memcpy */
    i = 0;
    while (i < FILL_N) {
      src[i] = (unsigned char)(0x40 + (i & 0x1F));
      dst[i] = 0;
      i++;
    }
    got = (unsigned long)((memcpy_fn)(bias + MEMCPY_PLT_VA))(dst, src, FILL_N);
    if (got != (unsigned long)dst) {
      bad++;
    }
    i = 0;
    while (i < FILL_N) {
      if (dst[i] != src[i]) {
        bad++;
      }
      i++;
    }

    /* memmove overlap */
    i = 0;
    while (i < FILL_N) {
      buf[i] = (unsigned char)(0x10 + i);
      i++;
    }
    got = (unsigned long)((memmove_fn)(bias + MEMMOVE_PLT_VA))(buf + 4, buf,
                                                               32);
    if (got != (unsigned long)(buf + 4)) {
      bad++;
    }
    i = 0;
    while (i < 32) {
      if (buf[4 + i] != (unsigned char)(0x10 + i)) {
        bad++;
      }
      i++;
    }

    /* strlen */
    n = ((strlen_fn)(bias + STRLEN_PLT_VA))(zstr);
    if (n != 8UL) {
      bad++;
    }
    fold = (fold << 1) ^ n;

    /* memcmp */
    if (((memcmp_fn)(bias + MEMCMP_PLT_VA))(src, src, FILL_N) != 0) {
      bad++;
    }
    src[0] = (unsigned char)(src[0] + 1);
    if (((memcmp_fn)(bias + MEMCMP_PLT_VA))(src, dst, 1) == 0) {
      bad++;
    }
    src[0] = (unsigned char)(src[0] - 1);

    /* bcmp */
    if (((bcmp_fn)(bias + BCMP_PLT_VA))(dst, dst, 8) != 0) {
      bad++;
    }
    if (((bcmp_fn)(bias + BCMP_PLT_VA))(src, dst, 1) == 0) {
      /* equal first byte */
    } else {
      bad++;
    }

    /* memchr */
    p = (char *)((memchr_fn)(bias + MEMCHR_PLT_VA))(zstr, (int)'c', 8);
    if (p != zstr + 2) {
      bad++;
    }
    fold = (fold << 1) ^ (unsigned long)(p - zstr);

    /* strncmp */
    if (((strncmp_fn)(bias + STRNCMP_PLT_VA))(zstr, "oscortex", 8) != 0) {
      bad++;
    }
    if (((strncmp_fn)(bias + STRNCMP_PLT_VA))(zstr, "oscox", 5) == 0) {
      bad++;
    }

    /* strcpy */
    scratch[0] = 'Z';
    scratch[1] = 0;
    p = ((strcpy_fn)(bias + STRCPY_PLT_VA))(scratch, zstr);
    if (p != scratch) {
      bad++;
    }
    if (((strcmp_fn)(bias + STRCMP_PLT_VA))(scratch, zstr) != 0) {
      bad++;
    }

    /* strnlen */
    n = ((strnlen_fn)(bias + STRNLEN_PLT_VA))(zstr, 3);
    if (n != 3UL) {
      bad++;
    }
    fold = (fold << 1) ^ n;

    /* strncpy */
    i = 0;
    while (i < 16) {
      scratch[i] = (char)0x55;
      i++;
    }
    p = ((strncpy_fn)(bias + STRNCPY_PLT_VA))(scratch, "ab", 8);
    if (p != scratch) {
      bad++;
    }
    if (scratch[0] != 'a' || scratch[1] != 'b' || scratch[2] != 0) {
      bad++;
    }
    if (scratch[7] != 0) {
      bad++;
    }

    /* strchr / strrchr */
    p = ((strchr_fn)(bias + STRCHR_PLT_VA))(zstr, (int)'o');
    if (p != zstr) {
      bad++;
    }
    p = ((strrchr_fn)(bias + STRRCHR_PLT_VA))(zstr, (int)'o');
    if (p != zstr + 4) {
      bad++;
    }
    fold = (fold << 1) ^ (unsigned long)(p - zstr);

    /* strstr */
    p = ((strstr_fn)(bias + STRSTR_PLT_VA))(zstr, needle);
    if (p != zstr + 2) {
      bad++;
    }
    fold = (fold << 1) ^ (unsigned long)(p - zstr);

    /* strcat */
    scratch[0] = 'x';
    scratch[1] = 0;
    p = ((strcat_fn)(bias + STRCAT_PLT_VA))(scratch, "yz");
    if (p != scratch) {
      bad++;
    }
    if (scratch[0] != 'x' || scratch[1] != 'y' || scratch[2] != 'z' ||
        scratch[3] != 0) {
      bad++;
    }

    /* strspn / strcspn */
    n = ((strspn_fn)(bias + STRSPN_PLT_VA))(zstr, accept);
    if (n != 8UL) {
      bad++;
    }
    fold = (fold << 1) ^ n;
    n = ((strcspn_fn)(bias + STRCSPN_PLT_VA))(zstr, reject);
    if (n != 8UL) {
      bad++;
    }
    fold = (fold << 1) ^ n;

    /* strncat */
    scratch[0] = 'A';
    scratch[1] = 0;
    p = ((strncat_fn)(bias + STRNCAT_PLT_VA))(scratch, "BCDE", 2);
    if (p != scratch) {
      bad++;
    }
    if (scratch[0] != 'A' || scratch[1] != 'B' || scratch[2] != 'C' ||
        scratch[3] != 0) {
      bad++;
    }

    /* strcasecmp */
    if (((strcasecmp_fn)(bias + STRCASECMP_PLT_VA))(caseA, caseB) != 0) {
      bad++;
    }
    if (((strcasecmp_fn)(bias + STRCASECMP_PLT_VA))(caseA, "abd") == 0) {
      bad++;
    }

    /* strncasecmp */
    if (((strncasecmp_fn)(bias + STRNCASECMP_PLT_VA))(caseA, caseB, 3) != 0) {
      bad++;
    }
    fold = (fold << 1) ^ 3UL;

    /* wide faces */
    if (((wcsncmp_fn)(bias + WCSNCMP_PLT_VA))(wz, wz, 8) != 0) {
      bad++;
    }
    n = ((wcslen_fn)(bias + WCSLEN_PLT_VA))(wz);
    if (n != 8UL) {
      bad++;
    }
    fold = (fold << 1) ^ n;
    wp = ((wmemchr_fn)(bias + WMEMCHR_PLT_VA))(wz, (int)'c', 8);
    if (wp != wz + 2) {
      bad++;
    }
    if (((wcscmp_fn)(bias + WCSCMP_PLT_VA))(wz, wz) != 0) {
      bad++;
    }
    if (((wmemcmp_fn)(bias + WMEMCMP_PLT_VA))(wz, wz, 8) != 0) {
      bad++;
    }
    wp = ((wcschr_fn)(bias + WCSCHR_PLT_VA))(wz, (int)'r');
    if (wp != wz + 4) {
      bad++;
    }
    fold = (fold << 1) ^ (unsigned long)(wp - wz);
    if (((iswdigit_fn)(bias + ISWDIGIT_PLT_VA))(0x35) != 1) {
      bad++;
    }
    if (((iswalnum_fn)(bias + ISWALNUM_PLT_VA))(0x41) != 1) {
      bad++;
    }
    wp = ((wcspbrk_fn)(bias + WCSPBRK_PLT_VA))(wz, wacc);
    if (wp != wz) {
      bad++;
    }
    wp = ((wcscpy_fn)(bias + WCSCPY_PLT_VA))(wscratch, wz);
    if (wp != wscratch) {
      bad++;
    }
    if (((towupper_fn)(bias + TOWUPPER_PLT_VA))(0x61) != 0x41) {
      bad++;
    }
    if (((towlower_fn)(bias + TOWLOWER_PLT_VA))(0x41) != 0x61) {
      bad++;
    }
    fold = (fold << 1) ^ 0x41UL;

    /* strto* */
    lv = ((strtol_fn)(bias + STRTOL_PLT_VA))(num, 0, 10);
    if (lv != 42) {
      bad++;
    }
    fold = (fold << 1) ^ (unsigned long)lv;
    n = ((strtoul_fn)(bias + STRTOUL_PLT_VA))(num, 0, 10);
    if (n != 42UL) {
      bad++;
    }
    ll = ((strtoll_fn)(bias + STRTOLL_PLT_VA))(num, 0, 10);
    if (ll != 42) {
      bad++;
    }
    ull = ((strtoull_fn)(bias + STRTOULL_PLT_VA))(num, 0, 10);
    if (ull != 42ULL) {
      bad++;
    }

    /* tiny stubs */
    if (((sched_yield_fn)(bias + SCHED_YIELD_PLT_VA))() != 0) {
      bad++;
    }
    if (((getpid_fn)(bias + GETPID_PLT_VA))() != 1) {
      bad++;
    }
    if (((getpagesize_fn)(bias + GETPAGESIZE_PLT_VA))() != 4096) {
      bad++;
    }
    fold = (fold << 1) ^ 4096UL;
    ff = ((nanf_fn)(bias + NANF_PLT_VA))("");
    dd = ((nan_fn)(bias + NAN_PLT_VA))("");
    (void)ff;
    (void)dd;
    if (((getenv_fn)(bias + GETENV_PLT_VA))("PATH") != 0) {
      bad++;
    }
    if (((getauxval_fn)(bias + GETAUXVAL_PLT_VA))(0) != 0) {
      bad++;
    }
    if (((time_fn)(bias + TIME_PLT_VA))(0) != 0) {
      bad++;
    }
    if (((usleep_fn)(bias + USLEEP_PLT_VA))(0) != 0) {
      bad++;
    }
    u = ((getuid_fn)(bias + GETUID_PLT_VA))();
    if (u != 0) {
      bad++;
    }
    if (((isatty_fn)(bias + ISATTY_PLT_VA))(0) != 0) {
      bad++;
    }
    if (((rand_fn)(bias + RAND_PLT_VA))() != 4) {
      bad++;
    }
    fold = (fold << 1) ^ 4UL;
    u = ((geteuid_fn)(bias + GETEUID_PLT_VA))();
    if (u != 0) {
      bad++;
    }


    /* ADR-0179 faces 50..99 */
    {
      float fx;
      double dx;
      int fds[2];
      char host[4];
      fx = ((floorf_fn)(bias + FLOORF_PLT_VA))(3.25f);
      fold = (fold << 1) ^ (unsigned long)(long)fx;
      fx = ((ceilf_fn)(bias + CEILF_PLT_VA))(3.25f);
      fx = ((truncf_fn)(bias + TRUNCF_PLT_VA))(3.25f);
      fx = ((roundf_fn)(bias + ROUNDF_PLT_VA))(3.25f);
      dx = ((floor_fn)(bias + FLOOR_PLT_VA))(3.25);
      dx = ((ceil_fn)(bias + CEIL_PLT_VA))(3.25);
      dx = ((trunc_fn)(bias + TRUNC_PLT_VA))(3.25);
      dx = ((round_fn)(bias + ROUND_PLT_VA))(3.25);
      (void)dx;
      if (((putchar_fn)(bias + PUTCHAR_PLT_VA))(65) != 65) {
        bad++;
      }
      if (((puts_fn)(bias + PUTS_PLT_VA))(zstr) != 0) {
        bad++;
      }
      ((srand_fn)(bias + SRAND_PLT_VA))(1);
      if (((getppid_fn)(bias + GETPPID_PLT_VA))() != 1) {
        bad++;
      }
      fold = (fold << 1) ^ 1UL;
      if (((sleep_fn)(bias + SLEEP_PLT_VA))(0) != 0) {
        bad++;
      }
      if (((write_fn)(bias + WRITE_PLT_VA))(1, zstr, 1) != -1) {
        bad++;
      }
      if (((read_fn)(bias + READ_PLT_VA))(0, buf, 1) != -1) {
        bad++;
      }
      ((abort_fn)(bias + ABORT_PLT_VA))();
      ((exit_fn)(bias + EXIT_PLT_VA))(0);
      ((_exit_fn)(bias + _EXIT_PLT_VA))(0);
      if (((unlink_fn)(bias + UNLINK_PLT_VA))(zstr) != -1) {
        bad++;
      }
      if (((rename_fn)(bias + RENAME_PLT_VA))(zstr, zstr) != -1) {
        bad++;
      }
      if (((mkdir_fn)(bias + MKDIR_PLT_VA))(zstr, 0) != -1) {
        bad++;
      }
      if (((rmdir_fn)(bias + RMDIR_PLT_VA))(zstr) != -1) {
        bad++;
      }
      if (((access_fn)(bias + ACCESS_PLT_VA))(zstr, 0) != -1) {
        bad++;
      }
      if (((chmod_fn)(bias + CHMOD_PLT_VA))(zstr, 0) != -1) {
        bad++;
      }
      if (((fileno_fn)(bias + FILENO_PLT_VA))(0) != 0) {
        bad++;
      }
      if (((feof_fn)(bias + FEOF_PLT_VA))(0) != 0) {
        bad++;
      }
      if (((ferror_fn)(bias + FERROR_PLT_VA))(0) != 0) {
        bad++;
      }
      if (((fflush_fn)(bias + FFLUSH_PLT_VA))(0) != 0) {
        bad++;
      }
      if (((gethostname_fn)(bias + GETHOSTNAME_PLT_VA))(host, 4) != -1) {
        bad++;
      }
      if (((munmap_fn)(bias + MUNMAP_PLT_VA))(buf, 1) != -1) {
        bad++;
      }
      if (((mprotect_fn)(bias + MPROTECT_PLT_VA))(buf, 1, 0) != -1) {
        bad++;
      }
      if (((alarm_fn)(bias + ALARM_PLT_VA))(0) != 0) {
        bad++;
      }
      if (((pause_fn)(bias + PAUSE_PLT_VA))() != -1) {
        bad++;
      }
      if (((kill_fn)(bias + KILL_PLT_VA))(1, 0) != -1) {
        bad++;
      }
      if (((dup_fn)(bias + DUP_PLT_VA))(0) != -1) {
        bad++;
      }
      if (((dup2_fn)(bias + DUP2_PLT_VA))(0, 1) != -1) {
        bad++;
      }
      if (((pipe_fn)(bias + PIPE_PLT_VA))(fds) != -1) {
        bad++;
      }
      if (((getpriority_fn)(bias + GETPRIORITY_PLT_VA))(0, 0) != 0) {
        bad++;
      }
      if (((setpriority_fn)(bias + SETPRIORITY_PLT_VA))(0, 0, 0) != -1) {
        bad++;
      }
      fx = ((sinf_fn)(bias + SINF_PLT_VA))(0.0f);
      fx = ((cosf_fn)(bias + COSF_PLT_VA))(0.0f);
      fx = ((tanf_fn)(bias + TANF_PLT_VA))(0.0f);
      fx = ((expf_fn)(bias + EXPF_PLT_VA))(0.0f);
      fx = ((logf_fn)(bias + LOGF_PLT_VA))(0.0f);
      fx = ((powf_fn)(bias + POWF_PLT_VA))(0.0f, 0.0f);
      fx = ((fmodf_fn)(bias + FMODF_PLT_VA))(0.0f, 1.0f);
      if (((socket_fn)(bias + SOCKET_PLT_VA))(0, 0, 0) != -1) {
        bad++;
      }
      if (((sysconf_fn)(bias + SYSCONF_PLT_VA))(0) != -1) {
        bad++;
      }
      fx = ((hypotf_fn)(bias + HYPOTF_PLT_VA))(0.0f, 0.0f);
      fx = ((nearbyintf_fn)(bias + NEARBYINTF_PLT_VA))(3.25f);
      fold = (fold << 1) ^ (unsigned long)(long)fx;
      (void)fx;

      /* ADR-0179 faces 100..199 — call every official @plt; unbound → #PF. */
      {
        double dx2;
        float fx2;
        int iexp;
        double ipart;
        float fipart;
        long lt;
        char tb[8];
        dx2 = ((sin_fn)(bias + SIN_PLT_VA))(0.0);
        dx2 = ((cos_fn)(bias + COS_PLT_VA))(0.0);
        dx2 = ((tan_fn)(bias + TAN_PLT_VA))(0.0);
        dx2 = ((asin_fn)(bias + ASIN_PLT_VA))(0.0);
        dx2 = ((acos_fn)(bias + ACOS_PLT_VA))(0.0);
        dx2 = ((atan_fn)(bias + ATAN_PLT_VA))(0.0);
        dx2 = ((atan2_fn)(bias + ATAN2_PLT_VA))(0.0, 1.0);
        dx2 = ((exp_fn)(bias + EXP_PLT_VA))(0.0);
        dx2 = ((log_fn)(bias + LOG_PLT_VA))(1.0);
        dx2 = ((exp2_fn)(bias + EXP2_PLT_VA))(0.0);
        dx2 = ((log2_fn)(bias + LOG2_PLT_VA))(1.0);
        dx2 = ((pow_fn)(bias + POW_PLT_VA))(1.0, 0.0);
        dx2 = ((hypot_fn)(bias + HYPOT_PLT_VA))(0.0, 0.0);
        dx2 = ((sinh_fn)(bias + SINH_PLT_VA))(0.0);
        dx2 = ((cosh_fn)(bias + COSH_PLT_VA))(0.0);
        dx2 = ((tanh_fn)(bias + TANH_PLT_VA))(0.0);
        fx2 = ((asinf_fn)(bias + ASINF_PLT_VA))(0.0f);
        fx2 = ((acosf_fn)(bias + ACOSF_PLT_VA))(0.0f);
        fx2 = ((atanf_fn)(bias + ATANF_PLT_VA))(0.0f);
        fx2 = ((atan2f_fn)(bias + ATAN2F_PLT_VA))(0.0f, 1.0f);
        fx2 = ((sinhf_fn)(bias + SINHF_PLT_VA))(0.0f);
        fx2 = ((coshf_fn)(bias + COSHF_PLT_VA))(0.0f);
        fx2 = ((tanhf_fn)(bias + TANHF_PLT_VA))(0.0f);
        fx2 = ((exp2f_fn)(bias + EXP2F_PLT_VA))(0.0f);
        fx2 = ((log2f_fn)(bias + LOG2F_PLT_VA))(1.0f);
        dx2 = ((log10_fn)(bias + LOG10_PLT_VA))(1.0);
        fx2 = ((log10f_fn)(bias + LOG10F_PLT_VA))(1.0f);
        dx2 = ((rint_fn)(bias + RINT_PLT_VA))(0.0);
        fx2 = ((rintf_fn)(bias + RINTF_PLT_VA))(0.0f);
        dx2 = ((nearbyint_fn)(bias + NEARBYINT_PLT_VA))(0.0);
        dx2 = ((fma_fn)(bias + FMA_PLT_VA))(0.0, 0.0, 0.0);
        fx2 = ((fmaf_fn)(bias + FMAF_PLT_VA))(0.0f, 0.0f, 0.0f);
        dx2 = ((modf_fn)(bias + MODF_PLT_VA))(0.0, &ipart);
        fx2 = ((modff_fn)(bias + MODFF_PLT_VA))(0.0f, &fipart);
        dx2 = ((frexp_fn)(bias + FREXP_PLT_VA))(0.0, &iexp);
        fx2 = ((frexpf_fn)(bias + FREXPF_PLT_VA))(0.0f, &iexp);
        dx2 = ((ldexp_fn)(bias + LDEXP_PLT_VA))(0.0, 0);
        fx2 = ((ldexpf_fn)(bias + LDEXPF_PLT_VA))(0.0f, 0);
        dx2 = ((cbrt_fn)(bias + CBRT_PLT_VA))(0.0);
        fx2 = ((cbrtf_fn)(bias + CBRTF_PLT_VA))(0.0f);
        dx2 = ((nextafter_fn)(bias + NEXTAFTER_PLT_VA))(0.0, 1.0);
        fx2 = ((nextafterf_fn)(bias + NEXTAFTERF_PLT_VA))(0.0f, 1.0f);
        dx2 = ((acosh_fn)(bias + ACOSH_PLT_VA))(1.0);
        fx2 = ((acoshf_fn)(bias + ACOSHF_PLT_VA))(1.0f);
        dx2 = ((asinh_fn)(bias + ASINH_PLT_VA))(0.0);
        fx2 = ((asinhf_fn)(bias + ASINHF_PLT_VA))(0.0f);
        dx2 = ((atanh_fn)(bias + ATANH_PLT_VA))(0.0);
        fx2 = ((atanhf_fn)(bias + ATANHF_PLT_VA))(0.0f);
        dx2 = ((scalbn_fn)(bias + SCALBN_PLT_VA))(0.0, 0);
        dx2 = ((remainder_fn)(bias + REMAINDER_PLT_VA))(0.0, 1.0);
        iexp = ((ilogbf_fn)(bias + ILOGBF_PLT_VA))(1.0f);
        dx2 = ((erf_fn)(bias + ERF_PLT_VA))(0.0);
        fx2 = ((erff_fn)(bias + ERFF_PLT_VA))(0.0f);
        dx2 = ((log1p_fn)(bias + LOG1P_PLT_VA))(0.0);
        fx2 = ((expm1f_fn)(bias + EXPM1F_PLT_VA))(0.0f);
        (void)((fread_fn)(bias + FREAD_PLT_VA))(tb, 1, 1, 0);
        (void)((fwrite_fn)(bias + FWRITE_PLT_VA))(tb, 1, 1, 0);
        (void)((fseek_fn)(bias + FSEEK_PLT_VA))(0, 0, 0);
        (void)((ftell_fn)(bias + FTELL_PLT_VA))(0);
        (void)((fgets_fn)(bias + FGETS_PLT_VA))(tb, 4, 0);
        (void)((fclose_fn)(bias + FCLOSE_PLT_VA))(0);
        (void)((fputs_fn)(bias + FPUTS_PLT_VA))(tb, 0);
        (void)((printf_fn)(bias + PRINTF_PLT_VA))(tb);
        (void)((snprintf_fn)(bias + SNPRINTF_PLT_VA))(tb, 4, tb);
        (void)((vsnprintf_fn)(bias + VSNPRINTF_PLT_VA))(tb, 4, tb, 0);
        (void)((fprintf_fn)(bias + FPRINTF_PLT_VA))(0, tb);
        (void)((sprintf_fn)(bias + SPRINTF_PLT_VA))(tb, tb);
        (void)((fputc_fn)(bias + FPUTC_PLT_VA))(0, 0);
        (void)((getc_fn)(bias + GETC_PLT_VA))(0);
        (void)((ungetc_fn)(bias + UNGETC_PLT_VA))(0, 0);
        (void)((setvbuf_fn)(bias + SETVBUF_PLT_VA))(0, tb, 0, 0);
        ((rewind_fn)(bias + REWIND_PLT_VA))(0);
        ((setbuf_fn)(bias + SETBUF_PLT_VA))(0, tb);
        (void)((sigaction_fn)(bias + SIGACTION_PLT_VA))(0, 0, 0);
        (void)((raise_fn)(bias + RAISE_PLT_VA))(0);
        (void)((nanosleep_fn)(bias + NANOSLEEP_PLT_VA))(0, 0);
        (void)((clock_gettime_fn)(bias + CLOCK_GETTIME_PLT_VA))(0, 0);
        (void)((signal_fn)(bias + SIGNAL_PLT_VA))(0, 0);
        (void)((strerror_fn)(bias + STRERROR_PLT_VA))(0);
        (void)((strerror_r_fn)(bias + STRERROR_R_PLT_VA))(0, tb, 4);
        (void)((uname_fn)(bias + UNAME_PLT_VA))(0);
        (void)((opendir_fn)(bias + OPENDIR_PLT_VA))(tb);
        (void)((closedir_fn)(bias + CLOSEDIR_PLT_VA))(0);
        (void)((madvise_fn)(bias + MADVISE_PLT_VA))(tb, 1, 0);
        ((tzset_fn)(bias + TZSET_PLT_VA))();
        (void)((fork_fn)(bias + FORK_PLT_VA))();
        (void)((chdir_fn)(bias + CHDIR_PLT_VA))(tb);
        (void)((poll_fn)(bias + POLL_PLT_VA))(0, 0, 0);
        ((qsort_fn)(bias + QSORT_PLT_VA))(tb, 0, 1, 0);
        (void)((bind_fn)(bias + BIND_PLT_VA))(0, 0, 0);
        (void)((listen_fn)(bias + LISTEN_PLT_VA))(0, 0);
        (void)((shutdown_fn)(bias + SHUTDOWN_PLT_VA))(0, 0);
        (void)((connect_fn)(bias + CONNECT_PLT_VA))(0, 0, 0);
        (void)((accept_fn)(bias + ACCEPT_PLT_VA))(0, 0, 0);
        (void)((writev_fn)(bias + WRITEV_PLT_VA))(0, 0, 0);
        (void)((setsockopt_fn)(bias + SETSOCKOPT_PLT_VA))(0, 0, 0, 0, 0);
        (void)((getsockopt_fn)(bias + GETSOCKOPT_PLT_VA))(0, 0, 0, 0, 0);
        (void)((gmtime_fn)(bias + GMTIME_PLT_VA))(&lt);
        (void)((gmtime_r_fn)(bias + GMTIME_R_PLT_VA))(&lt, tb);
        fold = (fold << 1) ^ (unsigned long)((mktime_fn)(bias + MKTIME_PLT_VA))(tb);
        (void)dx2;
        (void)fx2;
        (void)iexp;
        (void)ipart;
        (void)fipart;
      }
    }

    /* Derived LINE folds memmove buffer + string folds + batch. */
    sig = fold;
    i = 0;
    while (i < FILL_N) {
      sig = (sig << 1) ^ (unsigned long)buf[i];
      i++;
    }
    sig = (sig << 1) ^ BATCH;
    say("LINE", sig ^ MIX);
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1790000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
