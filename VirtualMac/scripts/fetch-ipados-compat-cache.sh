#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IPSW_TOOL="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
need_file "$IPSW_TOOL"

version="$VZ_IPADOS_MIN_VERSION"
local_ipsw="${VZ_IPADOS_COMPAT_IPSW:-}"
url="${VZ_IPADOS_COMPAT_URL:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --ipsw) local_ipsw="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        *) die "unknown compatibility-cache option: $1" ;;
    esac
done

case "$version" in
    14.5) build=18E199 ;;
    15.0) build=19A346 ;;
    16.1)
        build=20B82
        url="${url:-https://updates.cdn-apple.com/2022FallFCS/fullrestores/012-92967/0A594653-0CC9-40AF-81A9-822C59BE0AC6/iPad14%2C3%2CiPad14%2C4%2CiPad14%2C5%2CiPad14%2C6_16.1_20B82_Restore.ipsw}"
        ;;
    16.3.1)
        build=20D67
        url="${url:-https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-50028/ACF197BE-D22C-49EC-94C5-C1B58D7708AC/iPad14%2C3%2CiPad14%2C4%2CiPad14%2C5%2CiPad14%2C6_16.3.1_20D67_Restore.ipsw}"
        ;;
    *) die "unsupported compatibility-cache version: $version" ;;
esac

OUT="${VZ_IPADOS_COMPAT_ROOT:-$VZ_BUILD_ROOT/compat/ipados-$version}"
mkdir -p "$OUT"
CACHE="$(find "$OUT" -type f -path "*/${build}__*/dyld_shared_cache_arm64e" \
    -print -quit 2>/dev/null || true)"
if [[ -z "$CACHE" ]]; then
    if [[ -n "$local_ipsw" ]]; then
        need_file "$local_ipsw"
        "$IPSW_TOOL" extract --dyld --dyld-arch arm64e \
            -o "$OUT" "$local_ipsw"
    elif [[ -n "$url" ]]; then
        "$IPSW_TOOL" extract --remote --dyld --dyld-arch arm64e \
            -o "$OUT" "$url"
    else
        die "pass --ipsw for iPadOS $version (or set VZ_IPADOS_COMPAT_IPSW)"
    fi
    CACHE="$(find "$OUT" -type f -path "*/${build}__*/dyld_shared_cache_arm64e" \
        -print -quit 2>/dev/null || true)"
fi

need_file "$CACHE"
info="$("$IPSW_TOOL" dyld info --no-color "$CACHE")"
grep -Fq 'Platform       = iOS' <<<"$info" ||
    die "compatibility cache is not an iOS cache: $CACHE"

{
    echo "Build: $build"
    echo "iPadOS: $version"
    [[ -n "$local_ipsw" ]] && echo "IPSW: $local_ipsw"
    [[ -n "$url" ]] && echo "URL: $url"
    if [[ -n "$local_ipsw" ]]; then
        echo "IPSW SHA-256: $(shasum -a 256 "$local_ipsw" | awk '{print $1}')"
    fi
} >"$OUT/source.txt"

echo "iPadOS $version shared cache ready: $CACHE"
