#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
: "${VZ_REAL_MAC_VM:?set VZ_REAL_MAC_VM to the restore destination bundle}"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
REMOTE_IPSW="${VZ_REAL_MAC_IPSW:-$REMOTE_ROOT/input/UniversalMac_13.2.1_22D68_Restore.ipsw}"
REMOTE_VM="$VZ_REAL_MAC_VM"
INSTALLER="$REMOTE_ROOT/DerivedData/Build/Products/Debug/InstallationTool-Objective-C"

need_command sshpass

remote_script="$(cat <<EOF
set -eu
test -x '$INSTALLER'
test -f '$REMOTE_IPSW'
if test -e '$REMOTE_VM'; then
  echo 'refusing to overwrite existing VM: $REMOTE_VM' >&2
  exit 1
fi
if test "$(basename "$REMOTE_VM")" != VM.bundle; then
  echo 'the pinned Apple sample requires a destination named VM.bundle' >&2
  exit 1
fi
cd '$(dirname "$REMOTE_VM")'
NSUnbufferedIO=YES '$INSTALLER' '$REMOTE_IPSW'
EOF
)"

echo "Installing a fresh 64 GiB VM. The sparse image will consume less physical space."
real_mac_ssh "$remote_script"
