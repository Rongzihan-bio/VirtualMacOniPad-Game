#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-tweak"
DYLIB="$OUT/VZKeyboardPassthrough.dylib"
PLIST="$OUT/VZKeyboardPassthrough.plist"

need_command ldid
need_command xcrun
need_file "$VZ_REPO_ROOT/vz/tweak/VZKeyboardPassthrough.m"
need_file "$VZ_REPO_ROOT/vz/tweak/VZKeyboardPassthrough.plist"

mkdir -p "$OUT"
xcrun --sdk iphoneos clang -arch arm64e \
    -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" \
    -isysroot "$SDK" -dynamiclib -fblocks -framework Foundation \
    -Wl,-undefined,dynamic_lookup \
    -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.dylib \
    "$VZ_REPO_ROOT/vz/tweak/VZKeyboardPassthrough.m" -o "$DYLIB"
cp "$VZ_REPO_ROOT/vz/tweak/VZKeyboardPassthrough.plist" "$PLIST"
ldid -S "$DYLIB"
echo "SpringBoard keyboard passthrough tweak built: $OUT"
