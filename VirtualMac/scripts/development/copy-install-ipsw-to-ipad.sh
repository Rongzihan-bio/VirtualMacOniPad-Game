#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_INSTALL_IPSW:?set VZ_INSTALL_IPSW to the restore image to copy}"
LOCAL_IPSW="$VZ_INSTALL_IPSW"
REMOTE_DIR="${VZ_IPAD_RESTORE_IMAGES:-/var/mobile/Media/VirtualMac/Restore Images}"
NAME="$(basename "$LOCAL_IPSW")"
REMOTE_IPSW="$REMOTE_DIR/$NAME"
REMOTE_PARTIAL="$REMOTE_IPSW.partial"

need_command shasum
need_file "$LOCAL_IPSW"
local_size="$(stat -f %z "$LOCAL_IPSW")"
local_hash="$(shasum -a 256 "$LOCAL_IPSW" | awk '{print $1}')"

ensure_ipad_usb
ipad_ssh "mkdir -p '$REMOTE_DIR'; chown mobile:mobile '$REMOTE_DIR'"
remote_size="$(ipad_ssh "stat -c %s '$REMOTE_IPSW' 2>/dev/null || echo 0")"
if [[ "$remote_size" != "$local_size" ]]; then
    partial_size="$(ipad_ssh "stat -c %s '$REMOTE_PARTIAL' 2>/dev/null || echo 0")"
    if [[ "$partial_size" != "$local_size" ]]; then
        ipad_scp "$LOCAL_IPSW" "$IPAD_TARGET:$REMOTE_PARTIAL"
    fi
    ipad_ssh "test \$(stat -c %s '$REMOTE_PARTIAL') = '$local_size'; \
      mv '$REMOTE_PARTIAL' '$REMOTE_IPSW'; chown mobile:mobile '$REMOTE_IPSW'"
fi

remote_hash="$(ipad_ssh "sha256sum '$REMOTE_IPSW' | sed 's/ .*//'")"
[[ "$remote_hash" == "$local_hash" ]] ||
    die "iPad IPSW hash mismatch: local=$local_hash remote=$remote_hash"
printf 'IPSW_READY\t%s\t%s\t%s\n' \
    "$local_size" "$local_hash" "$REMOTE_IPSW"
