#!/bin/bash

# Exercise macOS VideoToolbox paravirtual device from a guest. It generates a 
# 15-second 1080p H.264 source, converts it to HEVC with macOS avconvert, and 
# verifies that the guest driver remains loaded after the workload.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_GUEST_HOST:?set VZ_GUEST_HOST to the guest address}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER to the guest SSH user}"
: "${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD to the guest SSH password}"
GUEST_HOST="$VZ_GUEST_HOST"
GUEST_USER="$VZ_GUEST_USER"
GUEST_PORT="${VZ_GUEST_USB_PORT:-2208}"
GUEST_PASSWORD="$VZ_GUEST_PASSWORD"
SAMPLE="$VZ_BUILD_ROOT/video-benchmark-1080p.mp4"

need_command ffmpeg
need_command lsof
need_command ssh
need_command sshpass
ensure_ipad_usb
mkdir -p "$VZ_BUILD_ROOT"

if [[ ! -f "$SAMPLE" ]]; then
    ffmpeg -hide_banner -loglevel error \
        -f lavfi -i 'testsrc2=size=1920x1080:rate=30:duration=15' \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p \
        -movflags +faststart -y "$SAMPLE"
fi

owned_tunnel=0
if ! lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    sshpass -p "$VZ_IPAD_PASSWORD" ssh "${IPAD_SSH_ARGS[@]}" \
        -o ControlMaster=no -o ControlPath=none \
        -N -L "127.0.0.1:$GUEST_PORT:$GUEST_HOST:22" "$IPAD_TARGET" &
    tunnel_pid=$!
    owned_tunnel=1
fi
cleanup() {
    if [[ "$owned_tunnel" == 1 ]]; then
        listener_pids="$(lsof -t -iTCP:"$GUEST_PORT" -sTCP:LISTEN 2>/dev/null || true)"
        if [[ -n "$listener_pids" ]]; then
            # shellcheck disable=SC2086
            kill $listener_pids 2>/dev/null || true
        fi
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

for _ in {1..40}; do
    lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.25
done
lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 ||
    die "iPad guest SSH tunnel did not open"

guest_ssh=(sshpass -p "$GUEST_PASSWORD" ssh -p "$GUEST_PORT"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10 -o PubkeyAuthentication=no
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1
    "$GUEST_USER@127.0.0.1")
guest_scp=(sshpass -p "$GUEST_PASSWORD" scp -P "$GUEST_PORT"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10 -o PubkeyAuthentication=no
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)

"${guest_scp[@]}" "$SAMPLE" "$GUEST_USER@127.0.0.1:/tmp/vz-video-input.mp4"
# shellcheck disable=SC2016
"${guest_ssh[@]}" 'set -eu
driver=com.apple.driver.AppleVideoToolboxParavirtualization
kmutil showloaded 2>/dev/null | grep -F "$driver"
rm -f /tmp/vz-video-output.mov
/usr/bin/time -p avconvert --source /tmp/vz-video-input.mp4 \
    --output /tmp/vz-video-output.mov \
    --preset PresetHEVCHighestQuality --replace
test -s /tmp/vz-video-output.mov
kmutil showloaded 2>/dev/null | grep -F "$driver"
ls -lh /tmp/vz-video-input.mp4 /tmp/vz-video-output.mov'
