#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
: "${VZ_REAL_MAC_VM:?set VZ_REAL_MAC_VM to the VM bundle on the reference Mac}"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
APP="$REMOTE_ROOT/DerivedData/Build/Products/Debug/macOSVirtualMachineSampleApp-Objective-C.app"

need_command sshpass

active="$(real_mac_ssh \
    "pgrep -f 'macOSVirtualMachineSampleApp-Objective-C|com.apple.Virtualization.VirtualMachine' || true")"
[[ -z "$active" ]] ||
    die "a Virtualization VM is already active on the real Mac (PIDs: $active)"

real_mac_ssh "test -d '$VZ_REAL_MAC_VM'; test -d '$APP'; open -n '$APP'"
echo "launched the arm64 Objective-C sample with system frameworks"
