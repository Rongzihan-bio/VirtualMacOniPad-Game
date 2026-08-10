#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="${VZ_MACOS_DSC:-$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e}"
OUT="${VZ_NETRB_OUTPUT:-$VZ_BUILD_ROOT/ipad-netrb/Netrb.framework}"
WORK="${VZ_NETRB_WORK_DIR:-$(dirname "$OUT")}"
RAW="$WORK/Netrb.macos.raw"
PROTO="$WORK/Netrb.proto"
BIN="$OUT/Netrb"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
PATCH="$VZ_REPO_ROOT/vz/patches/patch_netrb_lookup.py"
PATCH_LOOKUP="${VZ_NETRB_PATCH_LOOKUP:-1}"
ENTITLEMENT_AUDIT="$VZ_REPO_ROOT/scripts/audit-entitlements.py"
IMAGE="Netrb.framework/Versions/A/Netrb"

need_command codesign
need_file "$DSC"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_file "$PATCH"
need_file "$ENTITLEMENT_AUDIT"
need_file "$VZ_REPO_ROOT/vz/stamp_ios.py"
[[ "$PATCH_LOOKUP" == 0 || "$PATCH_LOOKUP" == 1 ]] ||
    die "VZ_NETRB_PATCH_LOOKUP must be 0 or 1"
mkdir -p "$OUT" "$(dirname "$RAW")"

if [[ ! -f "$RAW" ]]; then
    "$PYTHON" "$DYLDEX" -e "$IMAGE" -o "$RAW" "$DSC"
fi
VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$IMAGE" "$RAW" "$PROTO" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PROTO" "$BIN" \
    "$VZ_IPADOS_MIN_VERSION"
if [[ "$PATCH_LOOKUP" == 1 ]]; then
    "$PYTHON" "$PATCH" "$BIN"
fi
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime "$BIN"
codesign --verify "$BIN"
"$PYTHON" "$ENTITLEMENT_AUDIT" - "$BIN"
otool -l "$BIN" |
    awk '/LC_BUILD_VERSION/{show=1; left=7} show && left-- > 0 {print}' |
    grep -q "platform 2" || die "Netrb is not stamped for iOS"
echo "iPad Netrb framework built from matching macOS 13.2.1 DSC: $OUT"
