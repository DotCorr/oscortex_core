#!/usr/bin/env python3
"""Host-side expected numbers for cef-und2 (ADR-0179)."""

MIX = 0x0000000000000180
FILL_N = 64
BATCH = 400
UND_TOTAL = 1336
E_BADARG = 0xFFFFFFFFFFFFFFFE
RO = 42593760
RX = 189117488

BOUND_LIST = (
    "memset,memcpy,memmove,strlen,memcmp,bcmp,memchr,strncmp,strcpy,strcmp,strnlen,strncpy,strchr,strrchr,strstr,strcat,strspn,strcspn,strncat,strcasecmp,strncasecmp,wcsncmp,wcslen,wmemchr,wcscmp,wmemcmp,wcschr,iswdigit,iswalnum,wcspbrk,wcscpy,towupper,towlower,strtol,strtoul,strtoll,strtoull,sched_yield,getpid,getpagesize,nanf,nan,getenv,getauxval,time,usleep,getuid,isatty,rand,geteuid,floorf,ceilf,truncf,roundf,floor,ceil,trunc,round,putchar,puts,srand,getppid,sleep,write,read,abort,exit,_exit,unlink,rename,mkdir,rmdir,access,chmod,fileno,feof,ferror,fflush,gethostname,munmap,mprotect,alarm,pause,kill,dup,dup2,pipe,getpriority,setpriority,sinf,cosf,tanf,expf,logf,powf,fmodf,socket,sysconf,hypotf,nearbyintf,sin,cos,tan,asin,acos,atan,atan2,exp,log,exp2,log2,pow,hypot,sinh,cosh,tanh,asinf,acosf,atanf,atan2f,sinhf,coshf,tanhf,exp2f,log2f,log10,log10f,rint,rintf,nearbyint,fma,fmaf,modf,modff,frexp,frexpf,ldexp,ldexpf,cbrt,cbrtf,nextafter,nextafterf,acosh,acoshf,asinh,asinhf,atanh,atanhf,scalbn,remainder,ilogbf,erf,erff,log1p,expm1f,fread,fwrite,fseek,ftell,fgets,fclose,fputs,printf,snprintf,vsnprintf,fprintf,sprintf,fputc,getc,ungetc,setvbuf,rewind,setbuf,sigaction,raise,nanosleep,clock_gettime,signal,strerror,strerror_r,uname,opendir,closedir,madvise,tzset,fork,chdir,poll,qsort,bind,listen,shutdown,connect,accept,writev,setsockopt,getsockopt,gmtime,gmtime_r,mktime,select,ioctl,strdup,strtod,strftime,fcntl,prctl,sigemptyset,sigfillset,sigaddset,sigdelset,sigprocmask,sigaltstack,sem_init,sem_wait,sem_post,sem_destroy,sem_timedwait,mmap64,open64,openat64,fopen64,fdopen,lseek64,pread64,pwrite64,ftruncate64,fseeko64,ftello64,mkstemp64,mkostemp64,mkdtemp,readdir64,getgrnam,getgrgid,getpwuid,eventfd,timerfd_create,timerfd_settime,sched_setscheduler,sched_getscheduler,sched_getparam,sched_getaffinity,newlocale,freelocale,uselocale,strtod_l,setlocale,localeconv,setenv,unsetenv,setsid,readlink,setpgid,execvp,execlp,execv,system,clone,vfprintf,fchmod,freeaddrinfo,socketpair,getsockname,inet_ntop,sendmsg,recvmsg,gai_strerror,getifaddrs,freeifaddrs,mremap,ppoll,open_memstream,epoll_create1,epoll_create,epoll_ctl,epoll_wait,msync,posix_fallocate64,posix_fadvise64,fallocate64,sendfile64,fdatasync,utimensat,futimens,getrlimit64,setrlimit64,inotify_init,inotify_add_watch,inotify_rm_watch,tcflush,tcdrain,syscall,remove,pathconf,fsync,link,symlink,unlinkat,getcwd,realpath,gettimeofday,difftime,timegm,wcstol,swprintf,vswprintf,vasprintf,fmod,log1pf,lround,lroundf,llround,llroundf,getopt_long,waitpid,waitid,pipe2,flock,lchown,umask,mincore,dirfd,openlog,syslog,closelog,statvfs64,statfs64,fstatfs64,fnmatch,creat64,fdopendir,wcrtomb,mbrtowc,wcsftime,strndup,rand_r,initstate_r,random_r,longjmp,_setjmp,pthread_self,pthread_once,pthread_mutex_init,pthread_mutex_lock,pthread_mutex_unlock,pthread_mutex_destroy,pthread_mutex_trylock,pthread_mutexattr_init,pthread_mutexattr_destroy,pthread_cond_init,pthread_cond_wait,pthread_cond_timedwait,pthread_cond_signal,pthread_cond_broadcast,pthread_cond_destroy,pthread_condattr_init,pthread_condattr_setclock,pthread_condattr_destroy,pthread_key_create,pthread_key_delete,pthread_getspecific,pthread_setspecific,pthread_attr_init,pthread_attr_destroy,pthread_attr_setstacksize,pthread_attr_setdetachstate,pthread_attr_getstack,pthread_attr_getstacksize,pthread_create,pthread_join,pthread_detach,pthread_sigmask,pthread_getschedparam,pthread_setname_np,pthread_getname_np,pthread_kill,pthread_getattr_np,pkey_mprotect,pkey_alloc,pkey_set,__cxa_finalize,__cxa_atexit,__errno_location,__ctype_b_loc,__ctype_tolower_loc,__ctype_toupper_loc,__xpg_strerror_r,__ctype_get_mb_cur_max,__cxa_thread_atexit_impl,__getdelim,__longjmp_chk,__mbrlen,__register_atfork,__sched_cpualloc,__sched_cpucount,__sched_cpufree,__stack_chk_fail,__tls_get_addr,__udivti3"
)


def main():
    # Mirror prog.c fold + memmove buffer.
    fold = 0
    # strlen → 8
    fold = ((fold << 1) ^ 8) & ((1 << 64) - 1)
    # memchr 'c' at idx 2
    fold = ((fold << 1) ^ 2) & ((1 << 64) - 1)
    # strnlen(..., 3) → 3
    fold = ((fold << 1) ^ 3) & ((1 << 64) - 1)
    # strrchr 'o' at idx 4
    fold = ((fold << 1) ^ 4) & ((1 << 64) - 1)
    # strstr "cor" at idx 2
    fold = ((fold << 1) ^ 2) & ((1 << 64) - 1)
    # strspn → 8
    fold = ((fold << 1) ^ 8) & ((1 << 64) - 1)
    # strcspn → 8
    fold = ((fold << 1) ^ 8) & ((1 << 64) - 1)
    # strncasecmp fold ^ 3
    fold = ((fold << 1) ^ 3) & ((1 << 64) - 1)
    # wcslen → 8
    fold = ((fold << 1) ^ 8) & ((1 << 64) - 1)
    # wcschr 'r' at idx 4
    fold = ((fold << 1) ^ 4) & ((1 << 64) - 1)
    # towupper fold ^ 0x41
    fold = ((fold << 1) ^ 0x41) & ((1 << 64) - 1)
    # strtol → 42
    fold = ((fold << 1) ^ 42) & ((1 << 64) - 1)
    # getpagesize → 4096
    fold = ((fold << 1) ^ 4096) & ((1 << 64) - 1)
    # rand → 4
    fold = ((fold << 1) ^ 4) & ((1 << 64) - 1)
    # floorf(3.25) identity → 3 when cast to long
    fold = ((fold << 1) ^ 3) & ((1 << 64) - 1)
    # getppid → 1
    fold = ((fold << 1) ^ 1) & ((1 << 64) - 1)
    # nearbyintf(3.25) identity → 3 when cast to long
    fold = ((fold << 1) ^ 3) & ((1 << 64) - 1)
    # mktime stub returns -1
    fold = ((fold << 1) ^ ((1 << 64) - 1)) & ((1 << 64) - 1)

    buf = [0] * FILL_N
    for i in range(FILL_N):
        buf[i] = 0x10 + i
    tmp = buf[:32]
    for i in range(32):
        buf[4 + i] = tmp[i]

    sig = fold
    for i in range(FILL_N):
        sig = ((sig << 1) ^ buf[i]) & ((1 << 64) - 1)
    sig = ((sig << 1) ^ BATCH) & ((1 << 64) - 1)
    derived = (sig ^ MIX) & ((1 << 64) - 1)

    print("mix=%016X" % MIX)
    print("batch=%016X" % BATCH)
    print("und_total=%d" % UND_TOTAL)
    print("und_bound=%d" % BATCH)
    print("und_remain=%d" % (UND_TOTAL - BATCH))
    print("sig=%016X" % sig)
    print("derived=%016X" % derived)
    print("ro=%016X" % RO)
    print("rx=%016X" % RX)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=CEFUND2 START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("line=LINE %016X" % derived)
    print("kernel_ro=CEF LOAD RO %016X" % RO)
    print("kernel_rx=RX %016X" % RX)
    print("plt_line=CEF PLT MEMSET ")
    print("und_line=CEF UND BATCH 0000000000000190")
    print("batch_user=BATCH 0000000000000190")
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")
    print("win=PROC PLAT 00 WIN 000000000DCFC000")
    print("bound_list=%s" % BOUND_LIST)


if __name__ == "__main__":
    main()
