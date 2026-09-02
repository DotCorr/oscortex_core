/* oscortex libdrm port — shim header: <unistd.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_UNISTD_H
#define _SHIM_UNISTD_H
#include <stddef.h>
#include <sys/types.h>
#define F_OK 0
#define R_OK 4
#define W_OK 2
#define X_OK 1
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
extern char *optarg;
extern int optind, opterr, optopt;
int getopt(int, char * const [], const char *);
int close(int);
int chown(const char *, uid_t, gid_t);
int fchown(int, uid_t, gid_t);
int getpagesize(void);
int rmdir(const char *);

ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
off_t lseek(int, off_t, int);
int access(const char *, int);
int unlink(const char *);
int dup(int);
unsigned int sleep(unsigned int);
int usleep(unsigned int);
pid_t getpid(void);
uid_t geteuid(void);
ssize_t readlink(const char *, char *, size_t);
int isatty(int);
#endif
