#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

LOCAL="$VZ_BUILD_ROOT/ipad-smoke"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
ARCHIVE="$(mktemp -t VirtualMac-smoke.XXXXXX.tar.gz)"
RESULT_DIR="$VZ_BUILD_ROOT/validation"
RESULT="$RESULT_DIR/ipad-smoke.txt"
trap 'rm -f "$ARCHIVE"' EXIT

need_command sshpass
need_command tar
for file in \
    "$LOCAL/bin/vzload" \
    "$LOCAL/bin/vzcfg" \
    "$LOCAL/Frameworks/Hypervisor.framework/Versions/A/Hypervisor" \
    "$LOCAL/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics" \
    "$LOCAL/Frameworks/Virtualization.framework/Versions/A/Virtualization" \
    "$LOCAL/trustcache.txt"; do
    need_file "$file"
done

mkdir -p "$RESULT_DIR"
tar -C "$LOCAL" -czf "$ARCHIVE" \
    bin Frameworks trustcache.txt

ipad_ssh "mkdir -p '$REMOTE'; rm -rf '$REMOTE/smoke'"
ipad_scp "$ARCHIVE" "$IPAD_TARGET:$REMOTE/smoke.tar.gz"

remote_script="$(cat <<EOF
set -eu
mkdir -p '$REMOTE/smoke'
tar -xzf '$REMOTE/smoke.tar.gz' -C '$REMOTE/smoke'
rm -f '$REMOTE/smoke.tar.gz'
chmod 755 '$REMOTE/smoke/bin/vzload' '$REMOTE/smoke/bin/vzcfg'
while IFS=\$(printf '\\t') read -r hash file; do
  test -n "\$hash"
  test -f '$REMOTE/smoke/'"\$file"
  jbctl trustcache add "\$hash"
done <'$REMOTE/smoke/trustcache.txt'
echo LOAD_PROBE
'$REMOTE/smoke/bin/vzload' \
  '$REMOTE/smoke/Frameworks/Hypervisor.framework/Hypervisor' \
  '$REMOTE/smoke/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics' \
  '$REMOTE/smoke/Frameworks/Virtualization.framework/Virtualization'
echo DISPATCH_PROBE
'$REMOTE/smoke/bin/vzcfg' \
  '$REMOTE/smoke/Frameworks/Hypervisor.framework/Hypervisor' \
  '$REMOTE/smoke/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics' \
  '$REMOTE/smoke/Frameworks/Virtualization.framework/Virtualization'
EOF
)"

ipad_ssh "$remote_script" | tee "$RESULT"
grep -Fq "class VZVirtualMachineConfiguration" "$RESULT" ||
    die "Virtualization classes did not realize on iPad"
grep -Fq "ALL RESOLVE" "$RESULT" ||
    die "Virtualization selectors did not resolve on iPad"
grep -Fq "DISPATCH OK" "$RESULT" ||
    die "Virtualization method dispatch failed on iPad"

echo "iPad framework smoke validation passed: $RESULT"
