#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command clang
need_command sshpass
need_command shasum

OUT_DIR="$VZ_BUILD_ROOT/oracle"
PROBE="$OUT_DIR/oracle-images"
REPORT="$OUT_DIR/real-mac.txt"
mkdir -p "$OUT_DIR"

clang \
    -arch arm64 \
    -mmacosx-version-min=13.0 \
    -fobjc-arc \
    -framework Foundation \
    "$VZ_REPO_ROOT/vz/development/probes/oracle_images.m" \
    -o "$PROBE"

REMOTE_DIR="/tmp/VirtualMac-oracle-${UID}"
real_mac_ssh "mkdir -p '$REMOTE_DIR'"
real_mac_scp "$PROBE" "$REAL_MAC_TARGET:$REMOTE_DIR/oracle-images" >/dev/null

real_mac_ssh "set -e
export LC_ALL=C
export LANG=C
VMM=/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
RES=/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources
THIN=\$(mktemp /tmp/apple-vz-vmm-arm64e.XXXXXX)
trap 'rm -f \"\$THIN\"; rm -rf \"$REMOTE_DIR\"' EXIT
lipo \"\$VMM\" -thin arm64e -output \"\$THIN\"
echo 'ORACLE_FORMAT	1'
echo 'OS'
sw_vers
uname -a
echo 'HARDWARE'
/usr/sbin/sysctl -n hw.model hw.memsize hw.ncpu kern.osversion
echo 'SIP'
csrutil status 2>/dev/null || true
echo 'VMM'
file \"\$VMM\"
lipo -info \"\$VMM\"
dwarfdump --uuid \"\$VMM\"
printf 'arm64e-size	'; stat -f %z \"\$THIN\"
printf 'arm64e-sha256	'; shasum -a 256 \"\$THIN\" | awk '{print \$1}'
codesign -d --entitlements :- \"\$VMM\" 2>&1
echo 'RESOURCES'
for f in AVPBooter.vmapple2.bin VZG11.fd VZG21.fd; do
    printf '%s	' \"\$f\"
    stat -f %z \"\$RES/\$f\"
    shasum -a 256 \"\$RES/\$f\" | awk '{print \$1}'
done
echo 'LOADED_IMAGES'
\"$REMOTE_DIR/oracle-images\"
" | tee "$REPORT"

echo "wrote $REPORT"
