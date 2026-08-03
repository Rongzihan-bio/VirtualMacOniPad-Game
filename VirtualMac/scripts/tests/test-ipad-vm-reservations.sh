#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/vm-reserve-probe"
BIN="$OUT/vm-reserve-probe"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}/vm-reserve-probe"

need_command ldid
need_command xcrun
need_file "$VZ_REPO_ROOT/vz/development/probes/vm_reserve_probe.c"
need_file "$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"
mkdir -p "$OUT"

xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" \
    "$VZ_REPO_ROOT/vz/development/probes/vm_reserve_probe.c" -o "$BIN"
ldid -S"$VZ_REPO_ROOT/vz/patches/vmm.ents.xml" "$BIN"
hash="$(ldid -h "$BIN" | sed -n 's/^CDHash=//p')"
test -n "$hash"

ensure_ipad_usb
ipad_scp "$BIN" "$IPAD_TARGET:$REMOTE"
ipad_ssh "chmod 755 '$REMOTE'; jbctl trustcache add '$hash'; '$REMOTE'"
