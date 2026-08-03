#!/bin/bash

# Verify that the virtual RTC advances independently of guest network time.
# The prior Network Time setting is restored before the script exits.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_GUEST_HOST:?set VZ_GUEST_HOST to the guest address}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER to the guest SSH user}"
GUEST_HOST="$VZ_GUEST_HOST"
GUEST_USER="$VZ_GUEST_USER"
GUEST_PORT="${VZ_GUEST_USB_PORT:-2208}"
: "${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD in .env or the environment}"

need_command lsof
need_command ssh
need_command sshpass
ensure_ipad_usb

sshpass -p "$VZ_IPAD_PASSWORD" ssh "${IPAD_SSH_ARGS[@]}" \
    -o ControlMaster=no -o ControlPath=none \
    -N -L "127.0.0.1:$GUEST_PORT:$GUEST_HOST:22" "$IPAD_TARGET" &
tunnel_pid=$!
cleanup() {
    listener_pids="$(lsof -t -iTCP:"$GUEST_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$listener_pids" ]]; then
        # shellcheck disable=SC2086
        kill $listener_pids 2>/dev/null || true
    fi
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..40}; do
    lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.25
done

guest_ssh() {
    sshpass -p "$VZ_GUEST_PASSWORD" ssh -p "$GUEST_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
        "$GUEST_USER@127.0.0.1" "$@"
}

guest_ssh "printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S systemsetup -setusingnetworktime off >/dev/null 2>&1 || true"
start_host="$(date +%s)"
start_guest="$(guest_ssh 'date +%s')"
sleep 5
end_host="$(date +%s)"
end_guest="$(guest_ssh 'date +%s')"
guest_ssh "printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S systemsetup -setusingnetworktime on >/dev/null 2>&1 || true"

host_delta=$((end_host - start_host))
guest_delta=$((end_guest - start_guest))
skew=$((start_guest - start_host))
(( skew < 0 )) && skew=$((-skew))
echo "host delta: $host_delta seconds"
echo "guest RTC delta with Network Time off: $guest_delta seconds"
echo "host/guest initial skew: $skew seconds"
(( guest_delta >= 4 && guest_delta <= 8 )) ||
    die "guest RTC did not advance at wall-clock speed"
(( skew <= 5 )) || die "guest RTC differs from host by more than five seconds"
