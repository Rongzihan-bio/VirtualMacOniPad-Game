#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DESTINATION="${1:-library}"
case "$DESTINATION" in
    library|new|settings|keyboard-show|keyboard-hide) ;;
    *) die "usage: $0 library | new | settings | keyboard-show | keyboard-hide" ;;
esac

ensure_ipad_usb
ipad_ssh "/var/jb/usr/bin/uiopen 'virtualmac://$DESTINATION'"
echo "opened visible Virtual Mac $DESTINATION UI on the iPad"
