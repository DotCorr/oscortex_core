# Shared by build-skia-graphite.sh / build-preview-ui.sh.
# Prints extra clang++ flags so <cstdarg> resolves from THIS compiler's
# sysroot. Never copies host headers into the tree.
#
# Sourced. Sets SKIA_HOST_CXX_FLAGS (array) and SKIA_HOST_GN_CFLAGS (gn list).

skia_host_cxx_flags() {
  SKIA_HOST_CXX_FLAGS=()
  SKIA_HOST_GN_CFLAGS='[]'
  if [[ "$(uname -s)" != "Linux" ]]; then
    return 0
  fi
  local probe='#include <cstdarg>
int main(){return 0;}'
  if echo "$probe" | clang++ -x c++ -c -o /dev/null - >/dev/null 2>&1; then
    return 0
  fi
  # clang 18 on this image walks gcc-14's include/c++ (no headers) while
  # libstdc++-13-dev and libc++-18-dev are installed. Prefer the compiler's
  # own libc++; otherwise the installed libstdc++ that actually has cstdarg.
  if echo "$probe" | clang++ -stdlib=libc++ -x c++ -c -o /dev/null - >/dev/null 2>&1; then
    SKIA_HOST_CXX_FLAGS=(-stdlib=libc++)
    SKIA_HOST_GN_CFLAGS='["-stdlib=libc++"]'
    return 0
  fi
  local d ver inc
  for d in /usr/include/c++/*; do
    [[ -f "$d/cstdarg" ]] || continue
    ver="$(basename "$d")"
    [[ "$ver" == "v1" ]] && continue
    inc=("$d" "/usr/include/x86_64-linux-gnu/c++/$ver")
    if echo "$probe" | clang++ -I"${inc[0]}" -I"${inc[1]}" -x c++ -c -o /dev/null - >/dev/null 2>&1; then
      SKIA_HOST_CXX_FLAGS=(-I"${inc[0]}" -I"${inc[1]}")
      SKIA_HOST_GN_CFLAGS="[\"-I${inc[0]}\",\"-I${inc[1]}\"]"
      return 0
    fi
  done
  echo "skia-host-cxx-flags: clang++ cannot see <cstdarg> without vendoring headers" >&2
  return 1
}
