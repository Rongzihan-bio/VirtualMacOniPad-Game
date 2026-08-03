#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

LOCAL="${VZ_VMM_COMPAT_OUTPUT:-$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/LaunchServicesCompat.dylib}"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}/payload/Frameworks/LaunchServicesCompat.dylib"

need_command ldid
need_file "$LOCAL"
hash="$(ldid -h "$LOCAL" | sed -n 's/^CDHash=//p')"
[[ -n "$hash" ]] || die "could not read VMM hook CDHash"

ensure_ipad_usb
ipad_scp "$LOCAL" "$IPAD_TARGET:/tmp/LaunchServicesCompat.dylib"
VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"
ipad_ssh "
set -eu
install -m 755 /tmp/LaunchServicesCompat.dylib '$REMOTE'
rm -f /tmp/LaunchServicesCompat.dylib
jbctl trustcache add '$hash'
"
# The launchd Mach service can respawn between the pre-copy stop and install.
# Stop once more so the next client cannot reuse a process holding the old
# compatibility image.
VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"

echo "Loaded VMM hook library deployed; launch with scripts/launch-ipad-app.sh"
