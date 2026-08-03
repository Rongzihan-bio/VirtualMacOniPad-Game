#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_VM:?set VZ_REAL_MAC_VM to the VM bundle on the reference Mac}"
REMOTE_VM="$VZ_REAL_MAC_VM"
OUT="$VZ_BUILD_ROOT/ipad-vm/VM.bundle"

need_command sshpass
mkdir -p "$OUT"
real_mac_ssh "test -f '$REMOTE_VM/HardwareModel'; test -f '$REMOTE_VM/MachineIdentifier'"
real_mac_ssh_args
real_mac_scp \
    "$REAL_MAC_TARGET:$REMOTE_VM/HardwareModel" \
    "$OUT/HardwareModel"
real_mac_scp \
    "$REAL_MAC_TARGET:$REMOTE_VM/MachineIdentifier" \
    "$OUT/MachineIdentifier"

{
    printf 'VM_METADATA\t1\n'
    for file in HardwareModel MachineIdentifier; do
        printf '%s\t%s\t%s\n' \
            "$file" \
            "$(stat -f %z "$OUT/$file")" \
            "$(shasum -a 256 "$OUT/$file" | awk '{print $1}')"
    done
} >"$OUT/manifest.txt"

echo "matching-Mac VM metadata prepared: $OUT"
