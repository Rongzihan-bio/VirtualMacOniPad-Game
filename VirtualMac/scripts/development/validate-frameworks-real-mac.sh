#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

MAC_DIR="$VZ_BUILD_ROOT/frameworks/macos"
IOS_DIR="$VZ_BUILD_ROOT/frameworks/ios"
BUNDLE_DIR="$VZ_BUILD_ROOT/frameworks/bundles/macos"
RESULT_DIR="$VZ_BUILD_ROOT/validation"
RESULT="$RESULT_DIR/frameworks-real-mac.txt"
REMOTE_DIR="/tmp/VirtualMac-validation"

need_command sshpass
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    need_file "$MAC_DIR/$name"
    need_file "$IOS_DIR/$name"
    need_file "$BUNDLE_DIR/$name.framework/Versions/A/$name"
done

mkdir -p "$RESULT_DIR"

real_mac_ssh "mkdir -p '$REMOTE_DIR'; find '$REMOTE_DIR' -type f -delete"
real_mac_ssh_args
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    real_mac_scp "$MAC_DIR/$name" "$REAL_MAC_TARGET:$REMOTE_DIR/$name.macos"
    real_mac_scp "$IOS_DIR/$name" "$REAL_MAC_TARGET:$REMOTE_DIR/$name.ios"
    real_mac_scp -r "$BUNDLE_DIR/$name.framework" "$REAL_MAC_TARGET:$REMOTE_DIR/"
done
real_mac_scp "$VZ_REPO_ROOT/vz/development/probes/vzcfg.m" "$REAL_MAC_TARGET:$REMOTE_DIR/vzcfg.m"

remote_script="$(cat <<'EOF'
set -eu
cd /tmp/VirtualMac-validation
echo "REAL_MAC_FRAMEWORK_VALIDATION	1"
sw_vers
uname -a
sysctl kern.bootargs
xcrun clang -arch arm64e -mmacosx-version-min=13.0 \
  -framework Foundation vzcfg.m -o vzcfg
printf 'PROBE_HEADER\t'
otool -hv vzcfg | tail -1
for variant in macos ios; do
    for name in Hypervisor ParavirtualizedGraphics Virtualization; do
        file="$name.$variant"
        printf 'FIXUPS\t%s\t' "$file"
        /usr/bin/dyld_info -fixups "$file" > "$file.fixups"
        printf '%s\n' "$(wc -l < "$file.fixups" | tr -d ' ')"
    done
done
echo "SYSTEM_BASELINE"
./vzcfg \
  /System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor \
  /System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics \
  /System/Library/Frameworks/Virtualization.framework/Versions/A/Virtualization
echo "EXTRACTED_MACOS"
./vzcfg \
  ./Hypervisor.framework/Versions/A/Hypervisor \
  ./ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics \
  ./Virtualization.framework/Versions/A/Virtualization
EOF
)"

real_mac_ssh "$remote_script" | tee "$RESULT"
grep -q $'FIXUPS\tHypervisor.macos\t190' "$RESULT" ||
    die "unexpected Hypervisor fixup count on the real Mac"
grep -q $'FIXUPS\tVirtualization.ios\t18437' "$RESULT" ||
    die "unexpected Virtualization fixup count on the real Mac"
[[ "$(grep -c '^ALL RESOLVE$' "$RESULT")" == 2 ]] ||
    die "system or extracted Objective-C dispatch failed"
[[ "$(grep -c '^DISPATCH OK$' "$RESULT")" == 2 ]] ||
    die "system or extracted framework method dispatch failed"

echo "real Mac framework validation passed: $RESULT"
