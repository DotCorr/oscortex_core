/* Out-of-line libc++ / Skia port symbols for kernel-linked Skia. */
#define _LIBCPP_BUILDING_LIBRARY
#include <string>
#include <memory>
#include <typeinfo>

#include "include/core/SkPoint.h"
#include "include/private/SkLogPriority.h"
#include "src/core/SkCpu.h"
#include "src/core/SkOSFile.h"
#include "src/sksl/SkSLString.h"
#include "src/sksl/tracing/SkSLDebugTracePriv.h"

#include <cstdarg>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string_view>

extern "C" {
double acosh(double x) { return __builtin_acosh(x); }
double asinh(double x) { return __builtin_asinh(x); }
double atanh(double x) { return __builtin_atanh(x); }
double cosh(double x) { return __builtin_cosh(x); }
double sinh(double x) { return __builtin_sinh(x); }
double tanh(double x) { return __builtin_tanh(x); }
double exp2(double x) { return __builtin_exp2(x); }
double remainder(double x, double y) { return __builtin_remainder(x, y); }
}

namespace std {
inline namespace __1 {

void __libcpp_verbose_abort(char const *, ...) { for (;;) {} }

template string operator+<char, char_traits<char>, allocator<char>>(
    const char *, const string &);

string to_string(int v) {
  char b[32];
  int n = 0;
  int neg = v < 0;
  unsigned u = neg ? (unsigned)-v : (unsigned)v;
  char tmp[16];
  int i = 0;
  do {
    tmp[i++] = (char)('0' + (u % 10));
    u /= 10;
  } while (u);
  if (neg) {
    b[n++] = '-';
  }
  while (i) {
    b[n++] = tmp[--i];
  }
  b[n] = 0;
  return string(b, (size_t)n);
}
string to_string(long v) { return to_string((int)v); }
string to_string(unsigned v) { return to_string((unsigned long)v); }
string to_string(unsigned long v) {
  char b[32];
  int n = 0;
  unsigned long x = v;
  char tmp[24];
  int i = 0;
  do {
    tmp[i++] = (char)('0' + (x % 10));
    x /= 10;
  } while (x);
  while (i) {
    b[n++] = tmp[--i];
  }
  b[n] = 0;
  return string(b, (size_t)n);
}

void __shared_weak_count::__release_weak() noexcept {}
__shared_count::~__shared_count() {}
__shared_weak_count::~__shared_weak_count() {}
const void *__shared_weak_count::__get_deleter(type_info const &) const noexcept {
  return nullptr;
}

template class basic_string<char>;

unsigned long __next_prime(unsigned long n) {
  unsigned long p;
  unsigned long d;
  int ok;
  if (n < 2) {
    return 2;
  }
  p = n;
  if ((p & 1) == 0) {
    p = p + 1;
  }
  for (;;) {
    ok = 1;
    d = 3;
    while (d * d <= p) {
      if ((p % d) == 0) {
        ok = 0;
        break;
      }
      d = d + 2;
    }
    if (ok) {
      return p;
    }
    p = p + 2;
  }
}

void *align(size_t alignment, size_t size, void *&ptr, size_t &space) {
  uintptr_t p;
  uintptr_t a;
  uintptr_t extra;
  if (alignment < 1) {
    alignment = 1;
  }
  p = (uintptr_t)ptr;
  a = (alignment - (p % alignment)) % alignment;
  extra = a + size;
  if (extra > space) {
    return nullptr;
  }
  p = p + a;
  ptr = (void *)p;
  space = space - extra;
  return (void *)p;
}

namespace chrono {
steady_clock::time_point steady_clock::now() noexcept {
  return time_point(duration(0));
}
}  // namespace chrono

}  // namespace __1
}  // namespace std

namespace SkShaderUtils {
std::string BuildShaderErrorMessage(char const *, char const *) {
  return std::string();
}
void VisitLineByLine(std::string const &,
                     std::function<void(int, char const *)> const &) {}
}  // namespace SkShaderUtils

namespace SkSL {

bool stod(std::string_view, SKSL_FLOAT *value) {
  if (value) {
    *value = 0;
  }
  return false;
}
bool stoi(std::string_view, SKSL_INT *value) {
  if (value) {
    *value = 0;
  }
  return false;
}

namespace String {
std::string printf(const char *, ...) { return std::string(); }
void appendf(std::string *, const char *, ...) {}
void vappendf(std::string *, const char *, va_list) {}
}  // namespace String

void DebugTracePriv::setTraceCoord(const SkIPoint &) {}
void DebugTracePriv::setSource(const std::string &) {}
void DebugTracePriv::dump(SkWStream *) const {}
std::string DebugTracePriv::getSlotComponentSuffix(int) const {
  return std::string();
}
std::string DebugTracePriv::getSlotValue(int, int32_t) const {
  return std::string();
}

}  // namespace SkSL

namespace skstd {
std::string to_string(float) { return std::string("0"); }
std::string to_string(double) { return std::string("0"); }
}  // namespace skstd

bool sk_exists(const char *, SkFILE_Flags) { return false; }
void *sk_fmmap(FILE *, size_t *length) {
  if (length) {
    *length = 0;
  }
  return nullptr;
}
void *sk_fdmmap(int, size_t *length) {
  if (length) {
    *length = 0;
  }
  return nullptr;
}
void sk_fmunmap(const void *, size_t) {}
void sk_fsync(FILE *) {}
size_t sk_qread(FILE *, void *, size_t, size_t) { return 0; }

/* qemu64 has no AVX / OSXSAVE. SkCpu::CacheRuntimeFeatures must not
 * xgetbv (CR4 bit 18 is unset; #UD in IRQ0 looks like a hang).
 * These strong symbols keep libskia's SkCpu.cpp / Init_ml3 out. */
uint32_t SkCpu::gCachedFeatures = SkX64::SSE1 | SkX64::SSE2;

void SkCpu::CacheRuntimeFeatures() {
  gCachedFeatures = SkX64::SSE1 | SkX64::SSE2;
}

namespace SkOpts {
void Init_ml3() {}
void Init_ml4() {}
void Init_Memset_avx() {}
}

/* Graphite MakeVulkan logs the empty VkDevice through SkLog →
 * vfprintf(stderr). stderr is a BSS FILE* in the kernel CRT.
 * These strong symbols keep SkLog_stdio.o off the image. */
void SkLog(SkLogPriority, char const *, ...) {}
void SkLogVAList(SkLogPriority, char const *, va_list) {}
