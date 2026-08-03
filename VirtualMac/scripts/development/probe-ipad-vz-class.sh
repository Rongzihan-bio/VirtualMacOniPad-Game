#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
CLASS_NAME="${1:?usage: $0 ClassName}"

ipad_ssh "
export DYLD_INSERT_LIBRARIES='$REMOTE/payload/bin/VZHostCompat.dylib'
export VZ_INSTANTIATE='${VZ_INSTANTIATE:-0}'
'$REMOTE/payload/bin/objc-methods' \
  '$REMOTE/payload/Frameworks/Hypervisor.framework/Hypervisor' \
  '$REMOTE/payload/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics' \
  '$REMOTE/payload/Frameworks/Virtualization.framework/Virtualization' \
  '$CLASS_NAME'
"
