#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="${VZ_MACOS_DSC:-$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e}"
OUT="${VZ_VMNET_OUTPUT:-$VZ_BUILD_ROOT/ipad-vmnet/vmnet.framework}"
WORK="${VZ_VMNET_WORK_DIR:-$(dirname "$OUT")}"
RAW="$WORK/vmnet.raw"
PROTO="$WORK/vmnet.proto"
BIN="$OUT/vmnet"
ENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
ENTITLEMENT_AUDIT="$VZ_REPO_ROOT/scripts/audit-entitlements.py"
IMAGE="vmnet.framework/Versions/A/vmnet"

need_command codesign
need_command otool
need_file "$DSC"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_file "$VZ_REPO_ROOT/vz/stamp_ios.py"
need_file "$VZ_REPO_ROOT/vz/uncache.py"
need_file "$ENTITLEMENT_AUDIT"

rm -rf "$OUT"
mkdir -p "$OUT" "$(dirname "$RAW")"
if [[ ! -f "$RAW" ]]; then
    "$PYTHON" "$DYLDEX" -e "$IMAGE" -o "$RAW" "$DSC"
fi
VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$IMAGE" "$RAW" "$PROTO" compact

"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$PROTO" "$BIN" \
    "$VZ_IPADOS_MIN_VERSION"
codesign --verify "$BIN"
"$PYTHON" "$ENTITLEMENT_AUDIT" - "$BIN"

otool -l "$BIN" |
    awk '/LC_BUILD_VERSION/{show=1; left=7} show && left-- > 0 {print}' |
    grep -q "platform 2" || die "vmnet is not stamped for iOS"
otool -L "$BIN" | grep -Eq "/Netrb\.framework/(Versions/A/)?Netrb" ||
    die "vmnet does not use the iPadOS Netrb install name"

# A compact standalone image must not retain ADRP targets in the original
# Ventura shared-cache address range.  Those references may remain latent in
# light start/stop probes but crash as soon as vmnet enables event callbacks or
# packet I/O.
if otool -tvV "$BIN" | grep -Eq 'adrp.*; 0x1[1-9a-fA-F]'; then
    die "vmnet contains stale shared-cache ADRP targets"
fi

echo "iPad vmnet framework built from macOS 13.2.1 DSC: $OUT"
