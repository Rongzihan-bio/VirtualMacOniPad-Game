#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SOURCE="$VZ_REPO_ROOT/vz/development/probes/hid_event_layout.m"
OUT="$VZ_BUILD_ROOT/hid-event-layout"
IOS_BIN="$OUT/hid-event-layout-ios"
MAC_BIN_REMOTE="/tmp/hid-event-layout-macos"
SOURCE_REMOTE="/tmp/hid_event_layout.m"
ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"

need_command ldid
need_command xcrun
need_file "$SOURCE"
need_file "$ENTS"
mkdir -p "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 \
    -isysroot "$SDK" -framework CoreFoundation -framework IOKit \
    "$SOURCE" -o "$IOS_BIN"
ldid -S"$ENTS" "$IOS_BIN"
ios_hash="$(ldid -h "$IOS_BIN" | sed -n 's/^CDHash=//p')"

ensure_ipad_usb
ipad_scp "$IOS_BIN" "$IPAD_TARGET:/tmp/hid-event-layout"
ipad_ssh "chmod 755 /tmp/hid-event-layout; \
    jbctl trustcache add '$ios_hash'; /tmp/hid-event-layout" \
    >"$OUT/ipados.txt" 2>&1

real_mac_ssh_args
real_mac_scp "$SOURCE" "$REAL_MAC_TARGET:$SOURCE_REMOTE"
real_mac_ssh "xcrun clang -arch arm64 -framework CoreFoundation \
    -framework IOKit '$SOURCE_REMOTE' -o '$MAC_BIN_REMOTE'; \
    '$MAC_BIN_REMOTE'" >"$OUT/macos13.txt" 2>&1

echo "iPadOS layout: $OUT/ipados.txt"
echo "macOS 13 layout: $OUT/macos13.txt"
diff -u "$OUT/macos13.txt" "$OUT/ipados.txt" || true
