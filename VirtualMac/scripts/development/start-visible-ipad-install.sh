#!/bin/bash

# Launch a restore through Virtual Mac's real, visible UIKit installation flow.
# This is intended for repeatable end-to-end validation of the same path a
# person triggers with Add -> Install from IPSW, including its progress UI.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_IPAD_INSTALL_IPSW:?set VZ_IPAD_INSTALL_IPSW to an on-device restore image}"
: "${VZ_IPAD_INSTALL_NAME:?set VZ_IPAD_INSTALL_NAME to the VM display name}"
IPSW="$VZ_IPAD_INSTALL_IPSW"
NAME="$VZ_IPAD_INSTALL_NAME"
LIBRARY="/var/mobile/Media/VirtualMac"
SUPPORT="$LIBRARY"
REQUEST="$SUPPORT/.visible-install-request"
BUNDLE="$LIBRARY/$NAME.bundle"

[[ "$IPSW" == "$SUPPORT/Restore Images/"* ]] ||
    die "VZ_IPAD_INSTALL_IPSW must be in $SUPPORT/Restore Images"
[[ "$NAME" =~ ^[A-Za-z0-9._\ -]+$ ]] ||
    die "VZ_IPAD_INSTALL_NAME contains unsupported characters"

ensure_ipad_usb
ipad_ssh "
set -eu
test -f '$IPSW'
test ! -e '$BUNDLE'
mkdir -p '$SUPPORT'
printf '%s\\n%s\\n' '$NAME' '$IPSW' >'$REQUEST'
chown mobile:mobile '$REQUEST'
chmod 600 '$REQUEST'
killall VirtualMac 2>/dev/null || true
sleep 1
uiopen_path=/var/jb/usr/bin/uiopen
test -x "\$uiopen_path" || uiopen_path=/usr/bin/uiopen
"\$uiopen_path" --bundleid com.mac.virtual
"

for _ in {1..20}; do
    log="$(ipad_ssh "cat /tmp/VirtualMac.log 2>/dev/null || true")"
    if [[ "$log" == *"visible installation request name=$NAME"* ]]; then
        echo "VISIBLE_INSTALL_STARTED name=$NAME ipsw=$IPSW"
        exit 0
    fi
    sleep 0.25
done

die "Virtual Mac did not consume the visible installation request"
