#!/bin/bash

# Reject a payload that accidentally picked up a macOS platform stamp, an SDK
# deployment target newer than the supported range, or a strong import absent
# from the selected oldest iPadOS shared cache.

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
            in_build && /minos/ && !printed {
                print platform " " $2
                printed=1
            }
        ')"
        [[ "$build_version" == "2 $VZ_IPADOS_MIN_VERSION" ]] ||
            die "unsupported platform/minimum OS ($build_version): $candidate"
        checked=$((checked + 1))
    done < <(find "$root" -type f -print0)
done

(( checked > 0 )) || die "no built iPad Mach-O files found"
echo "iPadOS $VZ_IPADOS_MIN_VERSION deployment stamps verified: $checked Mach-O files"

read -r -a host_versions <<< \
    "${VZ_AUDIT_HOST_VERSIONS:-$VZ_IPADOS_MIN_VERSION}"
(( ${#host_versions[@]} > 0 )) || die "no iPadOS host versions selected"

need_command dyld_info
ipsw_tool="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
need_file "$ipsw_tool"

for host_version in "${host_versions[@]}"; do
    case "$host_version" in
        14.5) host_major=14; build=18E199 ;;
        15.0) host_major=15; build=19A346 ;;
        15.7) host_major=15; build=19H12 ;;
        16.1) host_major=16; build=20B82 ;;
        16.3.1) host_major=16; build=20D67 ;;
        *) die "unsupported ABI-audit host version: $host_version" ;;
    esac
    compat_output="$VZ_BUILD_ROOT/compat/ipados-$host_version"
    default_compat="$(find "$compat_output" -type f \
        -path "*/${build}__*/dyld_shared_cache_arm64e" -print -quit \
        2>/dev/null || true)"
    # prepare-inputs already extracts the optional 16.3.1 cache for kernel
    # and ABI analysis. Reuse it instead of storing a second multi-gigabyte
    # copy under compat/.
    if [[ -z "$default_compat" && "$host_version" == 16.3.1 ]]; then
        default_compat="$(find "$VZ_BUILD_ROOT/inputs/ipados" -type f \
            -path "*/${build}__*/dyld_shared_cache_arm64e" -print -quit \
            2>/dev/null || true)"
    fi
    compat_dsc="$default_compat"
    if (( ${#host_versions[@]} == 1 )) && \
       [[ -n "${VZ_IPADOS_COMPAT_DSC:-}" ]]; then
        compat_dsc="$VZ_IPADOS_COMPAT_DSC"
    fi
    if [[ -f "$compat_dsc" ]]; then
        VZ_IPSW_TOOL="$ipsw_tool" python3 \
            "$SCRIPT_DIR/audit-ipados-dsc.py" \
            --host-major "$host_major" \
            "$compat_dsc" "$compat_output" "${roots[@]}"
    elif [[ "${VZ_REQUIRE_IPADOS_COMPAT_DSC:-0}" == 1 ]]; then
        die "iPadOS $host_version cache missing; run fetch-ipados-compat-cache.sh --version $host_version"
    else
        echo "note: iPadOS $host_version ABI audit skipped; run fetch-ipados-compat-cache.sh --version $host_version"
    fi
done
