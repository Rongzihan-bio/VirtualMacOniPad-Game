#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

ATTEMPTS="${VZ_BOOT_ATTEMPTS:-4}"
TIMEOUT="${VZ_BOOT_TIMEOUT:-90}"
STALL_LIMIT="${VZ_BOOT_STALL_LIMIT:-30}"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
    die "VZ_BOOT_ATTEMPTS must be a positive integer"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
    die "VZ_BOOT_TIMEOUT must be a positive integer"
[[ "$STALL_LIMIT" =~ ^[1-9][0-9]*$ ]] ||
    die "VZ_BOOT_STALL_LIMIT must be a positive integer"

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    echo "desktop-qualified boot attempt $attempt/$ATTEMPTS"
    VZ_GUEST_STOP_TIMEOUT=5 "$SCRIPT_DIR/restore-ipad-good-guest.sh"
    VZ_IPAD_BOOT_TIMEOUT="$TIMEOUT" \
        "$SCRIPT_DIR/boot-ipad-vm-bundle.sh" \
        /var/mobile/Media/VirtualMac/GoodVM.bundle

    previous_frames=-1
    unchanged=0
    for ((elapsed = 0; elapsed < TIMEOUT; elapsed += 5)); do
        result="$(ipad_ssh "
if grep -Eq 'PVG cursor=.*image=1 size=[1-9][0-9]*x[1-9][0-9]*' \
     /tmp/VirtualMac.log; then
  echo desktop
elif ! ps ax | grep -F \
     '/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine' | \
     grep -v grep >/dev/null 2>&1; then
  echo stopped
else
  frames=\$(grep 'health state=' /tmp/VirtualMac.log | tail -1 | \
    sed -n 's/.*frames=\([0-9][0-9]*\).*/\1/p')
  echo frames:\${frames:-0}
fi
")"
        if [[ "$result" == desktop ]]; then
            ipad_ssh "tail -20 /tmp/VirtualMac.log; \
                grep '\[vmmhook\] health' /tmp/vmmhook.log | tail -4"
            echo "macOS desktop cursor observed on attempt $attempt"
            exit 0
        fi
        if [[ "$result" == stopped ]]; then
            echo "VMM stopped before the desktop on attempt $attempt"
            break
        fi
        frames="${result#frames:}"
        if [[ "$frames" == "$previous_frames" && "$frames" != 0 ]]; then
            unchanged=$((unchanged + 5))
        else
            previous_frames="$frames"
            unchanged=0
        fi
        if (( unchanged >= STALL_LIMIT )); then
            echo "PVG stalled at frame $frames for ${unchanged}s"
            break
        fi
        sleep 5
    done
done

die "macOS did not reach a desktop cursor after $ATTEMPTS clean attempts"
