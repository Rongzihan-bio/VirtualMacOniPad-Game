#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
need_file "$IPSW"

URL="${VZ_IPADOS_COMPAT_URL:-https://updates.cdn-apple.com/2022FallFCS/fullrestores/012-92967/0A594653-0CC9-40AF-81A9-822C59BE0AC6/iPad14%2C3%2CiPad14%2C4%2CiPad14%2C5%2CiPad14%2C6_16.1_20B82_Restore.ipsw}"
OUT="${VZ_IPADOS_COMPAT_ROOT:-$VZ_BUILD_ROOT/compat/ipados-16.1}"
CACHE="$OUT/20B82__iPad14,3_4_5_6/dyld_shared_cache_arm64e"

if [[ ! -f "$CACHE" ]]; then
    mkdir -p "$OUT"
    "$IPSW" extract --remote --dyld --dyld-arch arm64e -o "$OUT" "$URL"
fi

need_file "$CACHE"
info="$("$IPSW" dyld info --no-color "$CACHE")"
grep -Fq 'Platform       = iOS' <<<"$info" ||
    die "compatibility cache is not an iOS cache: $CACHE"
grep -Fq 'OS Version     = 16.1' <<<"$info" ||
    die "compatibility cache is not iPadOS 16.1: $CACHE"

cat >"$OUT/source.txt" <<EOF
Build: 20B82
Product: iPad14,3,iPad14,4,iPad14,5,iPad14,6
URL: $URL
IPSW SHA-256: 61bc8a8683bc27bc154bf9e9d3a694f6d6b78f55e9e134af839ed5750f4b14a9
EOF

echo "oldest supported iPadOS shared cache ready: $CACHE"
