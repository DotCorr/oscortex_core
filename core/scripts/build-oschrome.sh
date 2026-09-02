#!/usr/bin/env bash
# Platform clang++ + official CEF. Not an app ELF. Not Flutter. Not osgfx.
set -euo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$CORE/plat/chrome"
OUT="$CORE/build"
mkdir -p "$OUT"

bash "$CORE/scripts/fetch-cef.sh"
STAMP="$OUT/cef/READY"
[[ -f "$STAMP" ]] || { echo "build-oschrome: no $STAMP" >&2; exit 2; }
# shellcheck disable=SC1090
CEF_ROOT="$(awk -F= '/^CEF_ROOT=/{print substr($0,10)}' "$STAMP")"
[[ -d "$CEF_ROOT/include" ]] || { echo "build-oschrome: no CEF_ROOT" >&2; exit 2; }

WRAP_DIR="$OUT/cef/wrapper"
WRAP_LIB="$WRAP_DIR/libcef_dll_wrapper/libcef_dll_wrapper.a"
if [[ ! -f "$WRAP_LIB" ]]; then
  mkdir -p "$WRAP_DIR"
  (
    cd "$WRAP_DIR"
    cmake -G Ninja \
      -DPROJECT_ARCH=arm64 \
      -DCMAKE_BUILD_TYPE=Release \
      -DUSE_SANDBOX=OFF \
      -DCEF_ROOT="$CEF_ROOT" \
      "$CEF_ROOT"
    ninja libcef_dll_wrapper
  )
fi
[[ -f "$WRAP_LIB" ]] || { echo "build-oschrome: no libcef_dll_wrapper.a" >&2; exit 2; }

# Compile flags match the CEF wrapper (no RTTI / no exceptions).
clang++ -std=c++17 -O2 -Wall -Wextra \
  -Wno-unused-parameter -Wno-missing-field-initializers \
  -fno-rtti -fno-exceptions \
  -I "$SRC" -I "$CEF_ROOT" \
  -c -o "$OUT/oschrome.o" "$SRC/oschrome.mm"

clang -O2 -Wall -Wextra \
  -I "$SRC" \
  -c -o "$OUT/oschrome_headless_main.o" "$SRC/headless_main.c"

# Do not link the CEF framework: helpers resolve it via LoadInHelper
# (dlopen of ../../../Chromium Embedded Framework.framework). Linking
# with @executable_path/../Frameworks makes dyld kill every helper
# before main(). -undefined dynamic_lookup is the official CEF macOS
# path (sandbox / helper split).
clang++ -O2 \
  -o "$OUT/oschrome-headless" \
  "$OUT/oschrome.o" "$OUT/oschrome_headless_main.o" \
  "$WRAP_LIB" \
  -framework AppKit -framework Cocoa -framework CoreFoundation \
  -framework Foundation -framework IOKit -framework Security \
  -framework OpenGL \
  -Wl,-undefined,dynamic_lookup \
  -lc++

echo "built $OUT/oschrome-headless"

# CEF on macOS finds helpers next to the framework inside an .app.
APP="$OUT/oschrome-headless.app"
rm -rf "$APP"
MAC="$APP/Contents/MacOS"
FW="$APP/Contents/Frameworks"
mkdir -p "$MAC" "$FW"
cp "$OUT/oschrome-headless" "$MAC/oschrome-headless"

cat >"$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>oschrome-headless</string>
  <key>CFBundleIdentifier</key>
  <string>org.oscortex.oschrome</string>
  <key>CFBundleName</key>
  <string>oschrome-headless</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "$FW/"

pack_helper() {
  local name="$1"
  local hid="$2"
  local happ="$FW/${name}.app"
  mkdir -p "$happ/Contents/MacOS"
  cp "$OUT/oschrome-headless" "$happ/Contents/MacOS/${name}"
  mkdir -p "$happ/Contents/Frameworks"
  ln -sfn "../../../Chromium Embedded Framework.framework" \
    "$happ/Contents/Frameworks/Chromium Embedded Framework.framework"
  cat >"$happ/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${name}</string>
  <key>CFBundleIdentifier</key>
  <string>org.oscortex.oschrome.helper${hid}</string>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
}

pack_helper "oschrome-headless Helper" ""
pack_helper "oschrome-headless Helper (GPU)" ".gpu"
pack_helper "oschrome-headless Helper (Plugin)" ".plugin"
pack_helper "oschrome-headless Helper (Renderer)" ".renderer"
pack_helper "oschrome-headless Helper (Alerts)" ".alerts"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s - "$APP" >/dev/null

# Convenience symlink so nm/file can see the Mach-O at the old path.
ln -sf "$MAC/oschrome-headless" "$OUT/oschrome-headless"
echo "built $APP"

# --- DCDart @extern FFI (CMOD-CHROME1). Same CEF, second binary. ---
if [[ "${1:-}" == "--headless" ]]; then
  exit 0
fi

REPO="$(cd "$CORE/.." && pwd)"
DCDART_HOME="${DCDART_HOME:-$REPO/../DCDart}"
if [[ ! -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]]; then
  echo "build-oschrome: no DCDart at $DCDART_HOME (set DCDART_HOME)" >&2
  exit 2
fi
HOST_DART="$OUT/host-dart/dart-sdk/bin/dart"
if [[ -x "$HOST_DART" ]]; then
  DART="$HOST_DART"
elif command -v dart >/dev/null 2>&1; then
  DART="$(command -v dart)"
else
  echo "build-oschrome: dart not on PATH (source env.sh)" >&2
  exit 2
fi

DCDART_LINK="$OUT/dcdart"
if [[ -L "$DCDART_LINK" ]]; then
  rm -f "$DCDART_LINK"
elif [[ -e "$DCDART_LINK" ]]; then
  echo "build-oschrome: $DCDART_LINK exists and is not a symlink" >&2
  exit 2
fi
ln -s "$DCDART_HOME" "$DCDART_LINK"
PRELUDE="$DCDART_LINK/core/runtime/dc-core-bare/prelude.dart"
EXPECTED="import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';"
if ! grep -qxF -- "$EXPECTED" "$SRC/oschrome.dart"; then
  echo "build-oschrome: oschrome.dart prelude import is not ADR-0043" >&2
  exit 2
fi

if ! ( cd "$SRC" && "$DART" "$DCDART_HOME/core/dcc/bin/dcc.dart" build --mode bare --target host \
    --prelude "$PRELUDE" oschrome.dart -o "$OUT/oschrome_ffi.o" ); then
  if [[ -f "$OUT/oschrome_ffi.o" ]]; then
    echo "build-oschrome: dcc failed; reusing $OUT/oschrome_ffi.o"
  else
    echo "build-oschrome: dcc failed and no oschrome_ffi.o to reuse" >&2
    exit 2
  fi
fi

clang -O2 -Wall -Wextra -I "$SRC" -c -o "$OUT/oschrome_ffi_abi.o" "$SRC/oschrome_ffi.c"
clang -O2 -Wall -Wextra -I "$SRC" -c -o "$OUT/oschrome_ffi_main.o" "$SRC/ffi_main.c"
clang++ -O2 \
  -o "$OUT/oschrome-ffi" \
  "$OUT/oschrome.o" "$OUT/oschrome_ffi_abi.o" "$OUT/oschrome_ffi_main.o" \
  "$OUT/oschrome_ffi.o" \
  "$WRAP_LIB" \
  -framework AppKit -framework Cocoa -framework CoreFoundation \
  -framework Foundation -framework IOKit -framework Security \
  -framework OpenGL \
  -Wl,-undefined,dynamic_lookup \
  -lc++
echo "built $OUT/oschrome-ffi"

FFI_APP="$OUT/oschrome-ffi.app"
rm -rf "$FFI_APP"
FFI_MAC="$FFI_APP/Contents/MacOS"
FFI_FW="$FFI_APP/Contents/Frameworks"
mkdir -p "$FFI_MAC" "$FFI_FW"
cp "$OUT/oschrome-ffi" "$FFI_MAC/oschrome-ffi"

cat >"$FFI_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>oschrome-ffi</string>
  <key>CFBundleIdentifier</key>
  <string>org.oscortex.oschrome.ffi</string>
  <key>CFBundleName</key>
  <string>oschrome-ffi</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "$FFI_FW/"

pack_ffi_helper() {
  local name="$1"
  local hid="$2"
  local happ="$FFI_FW/${name}.app"
  mkdir -p "$happ/Contents/MacOS"
  cp "$OUT/oschrome-ffi" "$happ/Contents/MacOS/${name}"
  mkdir -p "$happ/Contents/Frameworks"
  ln -sfn "../../../Chromium Embedded Framework.framework" \
    "$happ/Contents/Frameworks/Chromium Embedded Framework.framework"
  cat >"$happ/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${name}</string>
  <key>CFBundleIdentifier</key>
  <string>org.oscortex.oschrome.ffi.helper${hid}</string>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
}

pack_ffi_helper "oschrome-ffi Helper" ""
pack_ffi_helper "oschrome-ffi Helper (GPU)" ".gpu"
pack_ffi_helper "oschrome-ffi Helper (Plugin)" ".plugin"
pack_ffi_helper "oschrome-ffi Helper (Renderer)" ".renderer"
pack_ffi_helper "oschrome-ffi Helper (Alerts)" ".alerts"

xattr -cr "$FFI_APP" 2>/dev/null || true
codesign --force --deep -s - "$FFI_APP" >/dev/null
ln -sf "$FFI_MAC/oschrome-ffi" "$OUT/oschrome-ffi"
echo "built $FFI_APP"
