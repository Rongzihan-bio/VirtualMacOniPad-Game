#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS"
mkdir -p "$OUT/usr/libexec" "$OUT/usr/sbin" \
    "$OUT/System/Library/LaunchDaemons"

need_command sshpass
real_mac_ssh_args
real_mac_scp \
    "$REAL_MAC_TARGET:/usr/libexec/InternetSharing" \
    "$OUT/usr/libexec/InternetSharing"
real_mac_scp \
    "$REAL_MAC_TARGET:/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist" \
    "$OUT/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
real_mac_scp \
    "$REAL_MAC_TARGET:/usr/libexec/bootpd" \
    "$OUT/usr/libexec/bootpd"
real_mac_scp \
    "$REAL_MAC_TARGET:/usr/sbin/rtadvd" \
    "$OUT/usr/sbin/rtadvd"
real_mac_scp \
    "$REAL_MAC_TARGET:/System/Library/LaunchDaemons/bootps.plist" \
    "$OUT/System/Library/LaunchDaemons/bootps.plist"

echo "Ventura NetworkSharing inputs fetched from $REAL_MAC_TARGET"
