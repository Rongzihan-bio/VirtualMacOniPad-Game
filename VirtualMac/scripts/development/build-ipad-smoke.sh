#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-smoke"
BIN="$OUT/bin"
FRAMEWORKS="$VZ_BUILD_ROOT/frameworks/bundles/ios"
PAYLOAD_FRAMEWORKS="$OUT/Frameworks"

need_command codesign
need_command ldid
need_command xcrun
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    need_file "$FRAMEWORKS/$name.framework/Versions/A/$name"
done
need_file "$VZ_REPO_ROOT/vz/development/probes/vzload.c"
need_file "$VZ_REPO_ROOT/vz/development/probes/vzcfg.m"
need_file "$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"

rm -rf "$PAYLOAD_FRAMEWORKS"
mkdir -p "$BIN" "$PAYLOAD_FRAMEWORKS"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" \
    "$VZ_REPO_ROOT/vz/development/probes/vzload.c" \
    -lobjc -o "$BIN/vzload"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -framework Foundation \
    "$VZ_REPO_ROOT/vz/development/probes/vzcfg.m" \
    -o "$BIN/vzcfg"

for binary in "$BIN/vzload" "$BIN/vzcfg"; do
    ldid -S"$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements" "$binary"
    file "$binary"
    ldid -e "$binary" | grep -Fq "com.apple.private.hypervisor"
done

for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    ditto "$FRAMEWORKS/$name.framework" \
        "$PAYLOAD_FRAMEWORKS/$name.framework"
    codesign --verify --deep --strict \
        "$PAYLOAD_FRAMEWORKS/$name.framework"
done

{
    for file in \
        "$BIN/vzload" \
        "$BIN/vzcfg" \
        "$PAYLOAD_FRAMEWORKS/Hypervisor.framework/Versions/A/Hypervisor" \
        "$PAYLOAD_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics" \
        "$PAYLOAD_FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization"; do
        printf '%s\t%s\n' \
            "$(ldid -h "$file" | sed -n 's/^CDHash=//p')" \
            "${file#"$OUT/"}"
    done
} >"$OUT/trustcache.txt"

echo "iPad framework smoke payload built: $OUT"
