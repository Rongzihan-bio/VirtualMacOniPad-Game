#!/bin/bash

# Build a loadable iOS arm64e image and dlopen-test it on-device.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
PY="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
IMG="$1"; MODE="${2:-compact}"
NAME="$(basename "$IMG")"
OUTPUT_ROOT="$VZ_BUILD_ROOT/manual-load-test"
RE="$OUTPUT_ROOT/$NAME"
OUT="$OUTPUT_ROOT/$NAME.$MODE"
IOS="$OUT.ios"                         # stamped+signed
mkdir -p "$OUTPUT_ROOT"
need_file "$DSC"
need_file "$PY"
ensure_ipad_usb

[ -f "$RE" ] || "$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex" -e "$IMG" -o "$RE" "$DSC" >/dev/null 2>&1
"$PY" "$VZ_REPO_ROOT/vz/uncache.py" "$DSC" "$IMG" "$RE" "$OUT" "$MODE" 2>&1 | grep -E 'rebases,|ADRP|objc relative|wrote'
cp "$OUT" "$IOS"
$PY - "$IOS" <<'PY'
import struct,sys
b=bytearray(open(sys.argv[1],"rb").read()); n=struct.unpack_from("<I",b,16)[0]; o=32
for _ in range(n):
    c,s=struct.unpack_from("<II",b,o)
    if c==0x32: struct.pack_into("<III",b,o+8,2,16<<16,16<<16|2); break
    o+=s
open(sys.argv[1],"wb").write(b)
PY
codesign -f -s - "$IOS" 2>/dev/null
HV=$(ldid -h "$IOS" 2>/dev/null | sed -n 's/^CDHash=//p')
ipad_scp "$IOS" "$IPAD_TARGET:/var/root/$NAME.test" >/dev/null 2>&1
ipad_ssh "jbctl trustcache add $HV >/dev/null; /var/root/hvload_e /var/root/$NAME.test; echo exit=\$?" 2>&1 | tail -8
