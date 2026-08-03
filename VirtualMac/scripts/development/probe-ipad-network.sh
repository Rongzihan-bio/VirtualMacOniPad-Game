#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/probes/net-interfaces"
ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"

need_command ldid
need_command xcrun
need_file "$ENTS"
need_file "$VZ_REPO_ROOT/vz/development/probes/net_interfaces.c"
mkdir -p "$(dirname "$OUT")"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 \
    -isysroot "$SDK" "$VZ_REPO_ROOT/vz/development/probes/net_interfaces.c" -o "$OUT"
ldid -S"$ENTS" "$OUT"

ipad_ssh_args
ipad_scp "$OUT" "$IPAD_TARGET:/tmp/vz-net-interfaces"
ipad_ssh "chmod 755 /tmp/vz-net-interfaces && /tmp/vz-net-interfaces"
