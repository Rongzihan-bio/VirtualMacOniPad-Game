#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command ldid
need_command codesign
need_command xcrun
ensure_ipad_usb

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-videotoolbox-probe"
BIN="$OUT/vt-pv-probe"
REMOTE=/var/root/VirtualMac/vt-pv-probe
REMOTE_VT=/var/root/VirtualMac/VideoToolbox.probe
mkdir -p "$OUT"

cdhash() {
    local candidate="$1"
    local hash
    hash="$(ldid -h "$candidate" 2>/dev/null | sed -n 's/^CDHash=//p')"
    if [[ -z "$hash" ]]; then
        hash="$(codesign -dvv "$candidate" 2>&1 |
            sed -n 's/^CDHash=//p' | head -1)"
    fi
    printf '%s' "$hash"
}

xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 \
    -isysroot "$SDK" "$VZ_REPO_ROOT/vz/development/probes/vt_pv_probe.c" \
    -o "$BIN"
ldid -S"$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements" "$BIN"
hash="$(cdhash "$BIN")"
[[ -n "$hash" ]] || die "could not read probe CDHash"

ipad_scp "$BIN" "$IPAD_TARGET:$REMOTE"
argument=""
if [[ -n "${VZ_VIDEO_TOOLBOX_PATH:-}" ]]; then
    need_file "$VZ_VIDEO_TOOLBOX_PATH"
    vt_hash="$(cdhash "$VZ_VIDEO_TOOLBOX_PATH")"
    [[ -n "$vt_hash" ]] || die "could not read VideoToolbox CDHash"
    ipad_scp "$VZ_VIDEO_TOOLBOX_PATH" "$IPAD_TARGET:$REMOTE_VT"
    argument="'$REMOTE_VT'"
    ipad_ssh "chmod 755 '$REMOTE_VT'; jbctl trustcache add '$vt_hash'"
fi
ipad_ssh "chmod 755 '$REMOTE'; jbctl trustcache add '$hash'; '$REMOTE' $argument"
