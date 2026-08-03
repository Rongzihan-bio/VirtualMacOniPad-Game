#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="${VZ_MACOS_DSC:-$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e}"
OUT="$VZ_BUILD_ROOT/ipad-netrb/Netrb.framework"
RAW="$VZ_BUILD_ROOT/ipad-netrb/Netrb.macos.raw"
PROTO="$VZ_BUILD_ROOT/ipad-netrb/Netrb.proto"
BIN="$OUT/Netrb"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
PATCH="$VZ_REPO_ROOT/vz/patches/patch_netrb_lookup.py"
ENTITLEMENT_AUDIT="$VZ_REPO_ROOT/scripts/audit-entitlements.py"
IMAGE="Netrb.framework/Versions/A/Netrb"

need_command codesign
need_file "$DSC"
need_file "$DSC.01"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_file "$PATCH"
need_file "$ENTITLEMENT_AUDIT"
need_file "$VZ_REPO_ROOT/vz/stamp_ios.py"
mkdir -p "$OUT" "$(dirname "$RAW")"

if [[ ! -f "$RAW" ]]; then
    "$DYLDEX" -e "$IMAGE" -o "$RAW" "$DSC"
fi
VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$IMAGE" "$RAW" "$PROTO" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PROTO" "$BIN" 16.0
"$PYTHON" "$PATCH" "$BIN"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime "$BIN"
codesign --verify "$BIN"
"$PYTHON" "$ENTITLEMENT_AUDIT" - "$BIN"
otool -l "$BIN" |
    awk '/LC_BUILD_VERSION/{show=1; left=7} show && left-- > 0 {print}' |
    grep -q "platform 2" || die "Netrb is not stamped for iOS"
echo "iPad Netrb framework built from matching macOS 13.2.1 DSC: $OUT"
