#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SOURCE="$VZ_REPO_ROOT/vz/development/probes/amfi_entitlement_probe.c"
LIBJAILBREAK="$VZ_BUILD_ROOT/analysis/libjailbreak.dylib"
DOPAMINE_HEADERS="$VZ_BUILD_ROOT/toolchain/Dopamine-src/BaseBin/libjailbreak/src"
DOPAMINE_COMMIT="e89072adc591881146c9513a616fa68b7323d6a7"
OUT="$VZ_BUILD_ROOT/probes/amfi-entitlement-probe"
REMOTE="/var/jb/usr/local/bin/amfi-entitlement-probe"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

need_command ldid
need_command xcrun
need_command git
need_file "$SOURCE"
mkdir -p "$(dirname "$OUT")"

if [[ ! -f "$DOPAMINE_HEADERS/info.h" ]]; then
    git clone https://github.com/opa334/Dopamine.git \
        "$VZ_BUILD_ROOT/toolchain/Dopamine-src"
    git -C "$VZ_BUILD_ROOT/toolchain/Dopamine-src" checkout --detach \
        "$DOPAMINE_COMMIT"
fi
if [[ ! -f "$LIBJAILBREAK" ]]; then
    ensure_ipad_usb
    mkdir -p "$(dirname "$LIBJAILBREAK")"
    ipad_scp \
        "$IPAD_TARGET:/var/jb/basebin/libjailbreak.dylib" \
        "$LIBJAILBREAK"
fi
need_file "$LIBJAILBREAK"
need_file "$DOPAMINE_HEADERS/info.h"

xcrun --sdk iphoneos clang -arch arm64e \
    -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -I"$DOPAMINE_HEADERS" \
    "$SOURCE" "$LIBJAILBREAK" -o "$OUT"
install_name_tool -change @loader_path/libjailbreak.dylib \
    /var/jb/basebin/libjailbreak.dylib "$OUT"
ldid -S"$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements" "$OUT"

ensure_ipad_usb
ipad_scp "$OUT" "$IPAD_TARGET:/tmp/amfi-entitlement-probe"
ipad_ssh "
set -eu
mkdir -p /var/jb/usr/local/bin
install -o root -g wheel -m 755 /tmp/amfi-entitlement-probe '$REMOTE'
rm -f /tmp/amfi-entitlement-probe
jbctl trustcache add '$(ldid -h "$OUT" | sed -n 's/^CDHash=//p')'
/var/jb/usr/bin/launchctl kickstart -k \
    user/501/com.apple.NetworkSharing
pid=\$(/var/jb/usr/bin/launchctl print user/501/com.apple.NetworkSharing | \
    sed -n 's/^[[:space:]]*pid = \\([0-9][0-9]*\\)\$/\\1/p' | head -1)
test -n \"\$pid\"
'$REMOTE' \"\$pid\"
"
