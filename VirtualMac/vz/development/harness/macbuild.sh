#!/bin/bash
# Extract a framework from the 13.2.1 cache, make it loadable (compact), and dlopen
# it on this Mac (deps resolve to host frameworks). Fast iteration + lldb for objc.
# Usage: macbuild.sh <image-path-in-cache> <basename>
set -e
cd "$(dirname "$0")/.."
DSC=build/rootfs_macOS/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
PY=build/vz/venv/bin/python3
IMG="$1"; NAME="$2"
RE="build/vz/loadable/$NAME"
OUT="build/vz/loadable/$NAME.mac"
[ -f "$RE" ] || build/vz/venv/bin/dyldex -e "$IMG" -o "$RE" "$DSC" >/dev/null 2>&1
VZ_MAC=1 $PY build/vz/uncache.py "$DSC" "$IMG" "$RE" "$OUT" compact 2>&1 | grep -viE 'pkg_resources|UserWarning|import pkg|Slide|^[/\\|-]$|building all'
codesign -f -s - "$OUT" 2>/dev/null
echo -n "dlopen on Mac: "
build/vz/macload "$OUT" 2>&1 | tr '\n' ' '; echo
