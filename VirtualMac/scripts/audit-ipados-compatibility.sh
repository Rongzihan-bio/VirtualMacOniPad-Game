#!/bin/bash

# Reject a payload that accidentally picked up a macOS platform stamp, an SDK
# deployment target newer than the supported range, or a strong import absent
# from the oldest iPadOS 16 shared cache.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command file
need_command otool

roots=(
    "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app"
    "$VZ_BUILD_ROOT/ipad-vm/payload"
    "$VZ_BUILD_ROOT/ipad-installation/payload"
    "$VZ_BUILD_ROOT/ipad-installation/install"
    "$VZ_BUILD_ROOT/ipad-network-sharing"
    "$VZ_BUILD_ROOT/ipad-network-helpers"
    "$VZ_BUILD_ROOT/ipad-tweak"
)

checked=0
for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' candidate; do
        # Original macOS inputs are retained as *.macos only while producing
        # their restamped siblings; no *.macos file is staged in the deb.
        [[ "$candidate" == *.macos ]] && continue
        file "$candidate" | grep -q 'Mach-O' || continue
        build_version="$(otool -l "$candidate" | awk '
            /cmd LC_BUILD_VERSION/ { in_build=1; next }
            in_build && /platform/ { platform=$2 }
            in_build && /minos/ { minos=$2; print platform " " minos; exit }
        ')"
        [[ "$build_version" == "2 16.0" ]] ||
            die "unsupported platform/minimum OS ($build_version): $candidate"
        checked=$((checked + 1))
    done < <(find "$root" -type f -print0)
done

(( checked > 0 )) || die "no built iPad Mach-O files found"
echo "iPadOS 16.0 deployment stamps verified: $checked Mach-O files"

compat_dsc="${VZ_IPADOS_COMPAT_DSC:-$VZ_BUILD_ROOT/compat/ipados-16.1/20B82__iPad14,3_4_5_6/dyld_shared_cache_arm64e}"
if [[ -f "$compat_dsc" ]]; then
    need_command dyld_info
    ipsw_tool="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
    need_file "$ipsw_tool"
    VZ_IPSW_TOOL="$ipsw_tool" python3 "$SCRIPT_DIR/audit-ipados-dsc.py" \
        "$compat_dsc" "$VZ_BUILD_ROOT/compat/ipados-16.1" "${roots[@]}"
elif [[ "${VZ_REQUIRE_IPADOS_COMPAT_DSC:-0}" == 1 ]]; then
    die "oldest-host cache missing; run scripts/fetch-ipados-compat-cache.sh"
else
    echo "note: oldest-host ABI audit skipped; run scripts/fetch-ipados-compat-cache.sh"
fi
