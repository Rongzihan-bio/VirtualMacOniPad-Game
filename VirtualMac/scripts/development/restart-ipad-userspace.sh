#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TIMEOUT="${VZ_IPAD_RESTART_TIMEOUT:-60}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] ||
    die "VZ_IPAD_RESTART_TIMEOUT must be a non-negative integer"

VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"
echo "requesting iPad userspace reboot"
ipad_ssh '/var/jb/usr/bin/launchctl reboot userspace' >/dev/null 2>&1 || true

remaining="$TIMEOUT"
while ((remaining > 0)); do
    if ipad_ssh 'test -x /var/jb/usr/bin/launchctl' >/dev/null 2>&1; then
        echo "iPad userspace is reachable"
        exit 0
    fi
    sleep 2
    ((remaining = remaining >= 2 ? remaining - 2 : 0))
done

die "iPad did not return over USB SSH within ${TIMEOUT}s"
