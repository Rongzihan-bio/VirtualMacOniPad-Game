#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

VZ_IPAD_INPUT_SELF_TEST=1 \
    "$VZ_REPO_ROOT/scripts/launch-ipad-app.sh" "${1:-7}"
sleep 3
ipad_ssh "
echo SELF_TEST
grep -E 'input self-test|input pointer|input key' /tmp/VirtualMac.log || true
echo KEYBOARD_CALLBACKS
grep -F 'process_keyboard_led_update' /tmp/vzxpchook.log \
  /tmp/vmmhook.log 2>/dev/null | tail -8 || true
echo VMM
ps axww | grep com.apple.Virtualization.VirtualMachine | grep -v grep || true
"
