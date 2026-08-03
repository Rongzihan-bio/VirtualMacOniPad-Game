#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_VM:?set VZ_REAL_MAC_VM to the VM bundle on the reference Mac}"
REMOTE_VM="$VZ_REAL_MAC_VM"
LOCAL_PARENT="$VZ_BUILD_ROOT/good-guest"
LOCAL_VM="$LOCAL_PARENT/VM.bundle"
IPAD_RUNTIME="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
IPAD_ROOT="/var/mobile/Media/VirtualMac"
IPAD_STAGE="$IPAD_ROOT/Transfers/good-guest-stage"
IPAD_INCOMING="$IPAD_STAGE/VM.bundle"
IPAD_VM="$IPAD_ROOT/GoodVM.bundle"
IPAD_BASELINE="$IPAD_ROOT/Baselines/GoodVM.bundle"

need_command rsync
need_command sshpass
GNU_TAR="${VZ_GNU_TAR:-$(command -v gtar || true)}"
[[ -n "$GNU_TAR" ]] ||
    die "GNU tar is required for sparse transfer (brew install gnu-tar)"

if [[ "${VZ_SKIP_REAL_MAC_SYNC:-0}" != 1 ]]; then
    active="$(real_mac_ssh \
        "ps ax | grep -E 'macOSVirtualMachineSampleApp|com.apple.Virtualization.VirtualMachine' | grep -v grep || true")"
    [[ -z "$active" ]] ||
        die "the matching-Mac VM must be shut down before copying"
fi
active_ipad="$(ipad_ssh \
    "ps ax | grep -E '$IPAD_RUNTIME/payload/bin/vzboot|$IPAD_RUNTIME/payload/VirtualMachine.xpc' | grep -v grep || true")"
[[ -z "$active_ipad" ]] ||
    die "the native iPad VM must be stopped before replacing its guest"

mkdir -p "$LOCAL_VM"
if [[ "${VZ_SKIP_REAL_MAC_SYNC:-0}" != 1 ]]; then
    real_mac_ssh_args
    sshpass -p "$VZ_REAL_MAC_PASSWORD" rsync \
        -aSzh --partial --progress \
        -e "ssh -p $VZ_REAL_MAC_PORT \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password" \
        "$REAL_MAC_TARGET:$REMOTE_VM/" "$LOCAL_VM/"
else
    echo "using completed local staging bundle: $LOCAL_VM"
fi

for file in Disk.img AuxiliaryStorage HardwareModel MachineIdentifier; do
    need_file "$LOCAL_VM/$file"
done
disk_size="$(stat -f %z "$LOCAL_VM/Disk.img")"
[[ "$disk_size" == 68719476736 ]] ||
    die "expected a 64 GiB good-guest disk, got $disk_size bytes"

ipad_ssh "rm -rf '$IPAD_STAGE'; mkdir -p '$IPAD_STAGE' '$IPAD_ROOT/Baselines'"
ensure_ipad_usb
"$GNU_TAR" --sparse -C "$LOCAL_PARENT" -cf - VM.bundle |
    sshpass -p "$VZ_IPAD_PASSWORD" ssh \
        "${IPAD_SSH_ARGS[@]}" "$IPAD_TARGET" \
        "tar --sparse -xf - -C '$IPAD_STAGE'"

ipad_ssh \
    "test \"\$(stat -c %s '$IPAD_INCOMING/Disk.img')\" = '$disk_size'; \
    rm -rf '$IPAD_VM'; mv '$IPAD_INCOMING' '$IPAD_VM'; \
    rmdir '$IPAD_STAGE'; \
    rm -rf '$IPAD_BASELINE'; \
    /var/jb/usr/bin/cp -a --reflink=always '$IPAD_VM' '$IPAD_BASELINE'; \
    stat -c '%s %n' '$IPAD_VM/'*"

echo "known-good matching-Mac guest copied to: $IPAD_VM"
echo "clean on-device recovery baseline: $IPAD_BASELINE"
