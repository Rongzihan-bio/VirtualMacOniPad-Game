#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_MACOS_IPSW:?set VZ_MACOS_IPSW to the macOS restore image}"
: "${VZ_SOURCE_VM:?set VZ_SOURCE_VM to the source UTM bundle}"
: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
DISK="$VZ_SOURCE_VM/Data/disk.img"
AUX="$VZ_SOURCE_VM/Data/aux.img"

need_file "$VZ_MACOS_IPSW"
need_file "$DISK"
need_file "$AUX"
need_command sshpass

real_mac_ssh_args
real_mac_ssh "mkdir -p '$VZ_REAL_MAC_WORK/VM.bundle' '$VZ_REAL_MAC_WORK/input'"

copy_if_size_differs() {
    local source="$1"
    local destination="$2"
    local local_size remote_size
    local_size="$(stat -f %z "$source")"
    remote_size="$(real_mac_ssh "stat -f %z '$destination' 2>/dev/null || echo 0")"
    if [[ "$local_size" == "$remote_size" ]]; then
        echo "already transferred: $destination ($local_size bytes)"
        return
    fi
    echo "transferring: $source -> $destination ($local_size bytes)"
    sshpass -p "$VZ_REAL_MAC_PASSWORD" scp -C \
        "${REAL_MAC_SCP_ARGS[@]}" "$source" "$REAL_MAC_TARGET:$destination"
}

copy_if_size_differs "$VZ_MACOS_IPSW" \
    "$VZ_REAL_MAC_WORK/input/UniversalMac_13.2.1_22D68_Restore.ipsw"
copy_if_size_differs "$DISK" "$VZ_REAL_MAC_WORK/VM.bundle/Disk.img"
copy_if_size_differs "$AUX" "$VZ_REAL_MAC_WORK/VM.bundle/AuxiliaryStorage"

echo "real Mac VM inputs transferred: $VZ_REAL_MAC_WORK"
