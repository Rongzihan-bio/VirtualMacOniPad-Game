#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
IMAGE="DiskImages2.framework/Versions/A/DiskImages2"
RESOURCES="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/PrivateFrameworks/DiskImages2.framework/Versions/A/Resources"
EXPECTED_UUID="35192C78-5415-38BF-B6B7-2175FDDC6FA1"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
OUT="$VZ_BUILD_ROOT/ipad-diskimages2"
RAW="$OUT/DiskImages2.raw"
PROTO="$OUT/DiskImages2.proto"
FRAMEWORK="$OUT/DiskImages2.framework"
VERSION="$FRAMEWORK/Versions/A"
BIN="$VERSION/DiskImages2"

need_file "$DSC"
need_file "$DSC.01"
need_file "$RESOURCES/Info.plist"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_command codesign
need_command ditto
need_command dwarfdump
need_command otool

mkdir -p "$OUT"
if [[ ! -f "$RAW" ]]; then
    # Invoke the entry point with this checkout's Python. Older developer
    # build directories may retain a relocatable venv script shebang.
    "$PYTHON" "$DYLDEX" -e "$IMAGE" -o "$RAW" "$DSC"
fi

# The VMM uses local raw images. Ventura's optional remote-image support links
# libcurl, which is absent on iPadOS 15; leave it weak so that unused feature
# does not prevent the matching DiskImages2 ABI from loading.
VZ_IPSW="$IPSW" VZ_WEAKEN=libcurl "$PYTHON" \
    "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$IMAGE" "$RAW" "$PROTO" compact
rm -rf "$FRAMEWORK"
mkdir -p "$VERSION/Resources"
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PROTO" "$BIN" \
    "$VZ_IPADOS_MIN_VERSION"
codesign --force --sign - "$BIN"
chmod 755 "$BIN"
ditto "$RESOURCES" "$VERSION/Resources"
ln -sfn A "$FRAMEWORK/Versions/Current"
ln -sfn Versions/Current/DiskImages2 "$FRAMEWORK/DiskImages2"
ln -sfn Versions/Current/Resources "$FRAMEWORK/Resources"
codesign --force --sign - "$FRAMEWORK"

uuid="$(dwarfdump --uuid "$BIN" | awk '{print $2}')"
[[ "$uuid" == "$EXPECTED_UUID" ]] ||
    die "DiskImages2 UUID mismatch: expected $EXPECTED_UUID, got $uuid"
codesign --verify --deep --strict "$FRAMEWORK"
otool -l "$BIN" | grep -q LC_DYLD_CHAINED_FIXUPS ||
    die "DiskImages2 is missing LC_DYLD_CHAINED_FIXUPS"

echo "Ventura DiskImages2 compatibility framework built: $FRAMEWORK"
