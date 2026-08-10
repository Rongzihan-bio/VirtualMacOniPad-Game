#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
IMAGE="VideoToolbox.framework/Versions/A/VideoToolbox"
EXPECTED_UUID="3CDCD75D-0D43-3B00-8F86-8F3DCED33F5D"
PV_IMAGE="VideoToolboxParavirtualizationSupport.framework/Versions/A/VideoToolboxParavirtualizationSupport"
PV_EXPECTED_UUID="E13E3D99-0D6A-3C9B-A1FB-2B76E247A7B6"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
OUT="$VZ_BUILD_ROOT/ipad-videotoolbox"
RAW="$OUT/VideoToolbox.raw"
PROTO="$OUT/VideoToolbox.proto"
FRAMEWORK="$OUT/VideoToolbox.framework"
BIN="$FRAMEWORK/VideoToolbox"
PV_RAW="$OUT/VideoToolboxParavirtualizationSupport.raw"
PV_PROTO="$OUT/VideoToolboxParavirtualizationSupport.proto"
PV_FRAMEWORK="$OUT/VideoToolboxParavirtualizationSupport.framework"
PV_BIN="$PV_FRAMEWORK/VideoToolboxParavirtualizationSupport"

need_file "$DSC"
need_file "$DSC.01"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_command codesign
need_command dyld_info
need_command dwarfdump
need_command otool
mkdir -p "$OUT" "$FRAMEWORK" "$PV_FRAMEWORK"

if [[ ! -f "$RAW" ]]; then
    "$DYLDEX" -e "$IMAGE" -o "$RAW" "$DSC"
fi
if [[ ! -f "$PV_RAW" ]]; then
    "$DYLDEX" -e "$PV_IMAGE" -o "$PV_RAW" "$DSC"
fi

# AppleVA is not present on iPadOS, and ColorSync.framework was only added to
# iPadOS after 15.  Both dependencies are optional for the paravirtualization
# host endpoint used by the VMM; when present on iPadOS 16, weak loading still
# resolves and uses them normally.
VZ_IPSW="$IPSW" VZ_WEAKEN=AppleVA,ColorSync \
    "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$IMAGE" "$RAW" "$PROTO" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PROTO" "$BIN" \
    "$VZ_IPADOS_MIN_VERSION"
chmod 755 "$BIN"

# iPadOS 16 already contains this private support framework, but iPadOS 15
# does not.  Ventura's VideoToolbox host endpoint weak-links it and silently
# leaves the AVP transport unavailable when dyld cannot find it.  Bundle the
# matching Ventura implementation so the legacy runtime can expose the actual
# paravirtualized video device to the guest.
VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$PV_IMAGE" "$PV_RAW" "$PV_PROTO" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PV_PROTO" "$PV_BIN" \
    "$VZ_IPADOS_MIN_VERSION"
chmod 755 "$PV_BIN"

uuid="$(dwarfdump --uuid "$BIN" | awk '{print $2}')"
[[ "$uuid" == "$EXPECTED_UUID" ]] ||
    die "VideoToolbox UUID mismatch: expected $EXPECTED_UUID, got $uuid"
codesign --verify "$BIN"
pv_uuid="$(dwarfdump --uuid "$PV_BIN" | awk '{print $2}')"
[[ "$pv_uuid" == "$PV_EXPECTED_UUID" ]] ||
    die "VideoToolbox PV support UUID mismatch: expected $PV_EXPECTED_UUID, got $pv_uuid"
codesign --force --sign - "$PV_BIN"
codesign --verify "$PV_BIN"
otool -l "$BIN" >"$OUT/load-commands.txt"
grep -A5 LC_LOAD_WEAK_DYLIB "$OUT/load-commands.txt" |
    grep -F /System/Library/PrivateFrameworks/AppleVA.framework/AppleVA \
        >/dev/null ||
    die "VideoToolbox AppleVA dependency is not weak"
grep -A5 LC_LOAD_WEAK_DYLIB "$OUT/load-commands.txt" |
    grep -F /System/Library/Frameworks/ColorSync.framework/ColorSync \
        >/dev/null ||
    die "VideoToolbox ColorSync dependency is not weak"
dyld_info -exports "$BIN" >"$OUT/exports.txt"
for symbol in \
    _VTParavirtualizationHostSessionCreate \
    _VTParavirtualizationHostSessionDeliverMessageFromGuest \
    _VTParavirtualizationHostSessionInvalidate; do
    grep -F "$symbol" "$OUT/exports.txt" >/dev/null ||
        die "VideoToolbox is missing export: $symbol"
done

for symbol in \
    _VTParavirtualizationGuestSupportRegisterGuestUUID \
    _VTParavirtualizationGuestSupportSendRawMessageToHost \
    _VTParavirtualizationGuestSupportSetUpWithHandlers; do
    dyld_info -exports "$PV_BIN" | grep -F "$symbol" >/dev/null ||
        die "VideoToolbox PV support is missing export: $symbol"
done

echo "matching Ventura VideoToolbox host endpoint built: $FRAMEWORK and $PV_FRAMEWORK"
