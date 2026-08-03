#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/probes/vmnet-probe"
RUNTIME="$VZ_BUILD_ROOT/probes/vmnet-runtime"
SOURCE="$VZ_REPO_ROOT/vz/development/probes/vmnet_probe.c"
ENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"

need_command ldid
need_command codesign
need_command install_name_tool
need_command xcrun
need_file "$SOURCE"
need_file "$ENTS"
mkdir -p "$(dirname "$OUT")"

"$VZ_REPO_ROOT/scripts/build-ipad-vmnet.sh"
"$VZ_REPO_ROOT/scripts/build-ipad-netrb.sh"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME/vmnet.framework" "$RUNTIME/Netrb.framework"
cp "$VZ_BUILD_ROOT/ipad-vmnet/vmnet.framework/vmnet" \
    "$RUNTIME/vmnet.framework/vmnet"
cp "$VZ_BUILD_ROOT/ipad-netrb/Netrb.framework/Netrb" \
    "$RUNTIME/Netrb.framework/Netrb"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" \
    "$RUNTIME/vmnet.framework/vmnet" \
    /System/Library/PrivateFrameworks/Netrb.framework/Netrb \
    @loader_path/../Netrb.framework/Netrb
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$RUNTIME/vmnet.framework/vmnet"

xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" -fblocks \
    -framework CoreFoundation \
    "$SOURCE" -o "$OUT"
ldid -S"$ENTS" "$OUT"
echo "iPad vmnet probe built: $OUT"
