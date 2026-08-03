#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
IMAGE="VideoToolbox.framework/Versions/A/VideoToolbox"
EXPECTED_UUID="3CDCD75D-0D43-3B00-8F86-8F3DCED33F5D"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
OUT="$VZ_BUILD_ROOT/ipad-videotoolbox"
RAW="$OUT/VideoToolbox.raw"
PROTO="$OUT/VideoToolbox.proto"
FRAMEWORK="$OUT/VideoToolbox.framework"
BIN="$FRAMEWORK/VideoToolbox"

need_file "$DSC"
need_file "$DSC.01"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_command codesign
need_command dyld_info
need_command dwarfdump
need_command otool
mkdir -p "$OUT" "$FRAMEWORK"

if [[ ! -f "$RAW" ]]; then
    "$DYLDEX" -e "$IMAGE" -o "$RAW" "$DSC"
fi

VZ_IPSW="$IPSW" VZ_WEAKEN=AppleVA \
    "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$IMAGE" "$RAW" "$PROTO" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PROTO" "$BIN" 16.0
chmod 755 "$BIN"

uuid="$(dwarfdump --uuid "$BIN" | awk '{print $2}')"
[[ "$uuid" == "$EXPECTED_UUID" ]] ||
    die "VideoToolbox UUID mismatch: expected $EXPECTED_UUID, got $uuid"
codesign --verify "$BIN"
otool -l "$BIN" >"$OUT/load-commands.txt"
grep -A5 LC_LOAD_WEAK_DYLIB "$OUT/load-commands.txt" |
    grep -F /System/Library/PrivateFrameworks/AppleVA.framework/AppleVA \
        >/dev/null ||
    die "VideoToolbox AppleVA dependency is not weak"
dyld_info -exports "$BIN" >"$OUT/exports.txt"
for symbol in \
    _VTParavirtualizationHostSessionCreate \
    _VTParavirtualizationHostSessionDeliverMessageFromGuest \
    _VTParavirtualizationHostSessionInvalidate; do
    grep -F "$symbol" "$OUT/exports.txt" >/dev/null ||
        die "VideoToolbox is missing export: $symbol"
done

echo "matching Ventura VideoToolbox host endpoint built: $FRAMEWORK"
