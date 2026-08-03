#!/bin/bash

# Boot Ventura-hosted VM with macOS VirtioFS automount tag and
# prove that a host sentinel is visible inside the guest.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
: "${VZ_REAL_MAC_SHARED_VM:?set VZ_REAL_MAC_SHARED_VM to the test VM bundle}"
: "${VZ_REAL_MAC_GUEST_USER:?set VZ_REAL_MAC_GUEST_USER}"
: "${VZ_REAL_MAC_GUEST_PASSWORD:?set VZ_REAL_MAC_GUEST_PASSWORD}"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
REMOTE_VM="$VZ_REAL_MAC_SHARED_VM"
REMOTE_SHARE="$REMOTE_ROOT/shared-folder-oracle"
REMOTE_PROBE="$REMOTE_ROOT/vzmacboot-shared"
REMOTE_LOG="$REMOTE_ROOT/shared-folder-oracle-vm.log"
GUEST_USER="$VZ_REAL_MAC_GUEST_USER"
GUEST_PASSWORD="$VZ_REAL_MAC_GUEST_PASSWORD"
GUEST_PORT="${VZ_REAL_MAC_GUEST_PORT:-2211}"
GUEST_MAC="d6:a7:58:8e:78:d6"

need_command lsof
need_command sshpass
real_mac_ssh_args

local_source="$VZ_REPO_ROOT/vz/development/probes/vzmacboot.m"
local_entitlements="$VZ_REPO_ROOT/vz/development/probes/vz-macos.entitlements"
need_file "$local_source"
need_file "$local_entitlements"

runner_pid=
tunnel_pid=
cleanup() {
    if [[ -n "$tunnel_pid" ]]; then
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
    if [[ -n "$runner_pid" ]]; then
        real_mac_ssh "kill '$runner_pid' 2>/dev/null || true" || true
    fi
}
trap cleanup EXIT

[[ -z "$(real_mac_ssh "pgrep -f 'vzmacboot-shared|com.apple.Virtualization.VirtualMachine' || true")" ]] ||
    die "a real-Mac virtualization process is already running"
if lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "local guest SSH port $GUEST_PORT is already in use"
fi

real_mac_scp "$local_source" "$local_entitlements" \
    "$REAL_MAC_TARGET:$REMOTE_ROOT/"
runner_pid="$(real_mac_ssh "
set -eu
test -f '$REMOTE_VM/Disk.img'
mkdir -p '$REMOTE_SHARE'
printf 'ventura-virtiofs-oracle\n' >'$REMOTE_SHARE/host-sentinel.txt'
xcrun clang -fobjc-arc -framework AppKit -framework Virtualization \
  '$REMOTE_ROOT/vzmacboot.m' -o '$REMOTE_PROBE'
codesign --force --sign - --entitlements \
  '$REMOTE_ROOT/vz-macos.entitlements' '$REMOTE_PROBE' >/dev/null
VZ_SHARED_DIRECTORY='$REMOTE_SHARE' VZ_RUN_SECONDS=300 \
VZ_LOG_PATH='$REMOTE_LOG' nohup '$REMOTE_PROBE' '$REMOTE_VM' \
  >/dev/null 2>&1 &
echo \$!
")"

guest_ip=
for _ in {1..60}; do
    guest_ip="$(real_mac_ssh "arp -an | awk '
      / on bridge100 / && tolower(\$4) == \"$GUEST_MAC\" {
        gsub(/[()]/, \"\", \$2); print \$2; exit
      }'")"
    [[ -n "$guest_ip" ]] && break
    sleep 2
done
[[ -n "$guest_ip" ]] || die "could not discover the Ventura guest address"

sshpass -p "$VZ_REAL_MAC_PASSWORD" ssh "${REAL_MAC_SSH_ARGS[@]}" \
    -o ControlMaster=no -o ControlPath=none \
    -N -L "127.0.0.1:$GUEST_PORT:$guest_ip:22" \
    "$REAL_MAC_TARGET" &
tunnel_pid=$!
for _ in {1..60}; do
    if sshpass -p "$GUEST_PASSWORD" ssh -p "$GUEST_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=2 -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password \
        "$GUEST_USER@127.0.0.1" true 2>/dev/null; then
        break
    fi
    sleep 2
done

guest_ssh=(sshpass -p "$GUEST_PASSWORD" ssh -p "$GUEST_PORT"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5 -o PubkeyAuthentication=no
    -o PreferredAuthentications=password "$GUEST_USER@127.0.0.1")
"${guest_ssh[@]}" "
set -eu
mount | grep -F '/Volumes/My Shared Files (AppleVirtIOFS'
test \"\$(cat '/Volumes/My Shared Files/Host Share/host-sentinel.txt')\" = \
  ventura-virtiofs-oracle
"
"${guest_ssh[@]}" "
printf '%s\n' '$GUEST_PASSWORD' | sudo -S -p '' shutdown -h now
" || true

for _ in {1..30}; do
    if ! real_mac_ssh "kill -0 '$runner_pid' 2>/dev/null"; then
        runner_pid=
        break
    fi
    sleep 1
done

echo "Ventura guest automatically mounted the real-Mac shared folder"
