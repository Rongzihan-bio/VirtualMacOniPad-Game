#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TIMEOUT="${VZ_GUEST_STOP_TIMEOUT:-12}"
FORCE_TIMEOUT="${VZ_FORCE_STOP_TIMEOUT:-15}"
STOP_HOST="${VZ_STOP_HOST:-0}"
GUEST_HOST="${VZ_GUEST_HOST:-}"
GUEST_USER="${VZ_GUEST_USER:-}"
GUEST_PASSWORD="${VZ_GUEST_PASSWORD:-}"
GUEST_SHUTDOWN_PORT="${VZ_GUEST_SHUTDOWN_PORT:-2218}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] ||
    die "VZ_GUEST_STOP_TIMEOUT must be a non-negative integer"
[[ "$FORCE_TIMEOUT" =~ ^[0-9]+$ ]] ||
    die "VZ_FORCE_STOP_TIMEOUT must be a non-negative integer"
[[ "$STOP_HOST" == 0 || "$STOP_HOST" == 1 ]] ||
    die "VZ_STOP_HOST must be 0 or 1"

# Prefer an OS-level shutdown over Virtualization's virtual power button. The
# latter intentionally presents a macOS confirmation sheet and is not a
# dependable unattended control path. If guest SSH is not ready, continue to
# the VZ request/stop fallback below.
if [[ "$TIMEOUT" -gt 0 && -n "$GUEST_HOST" && -n "$GUEST_USER" &&
      -n "$GUEST_PASSWORD" ]] &&
   ! lsof -nP -iTCP:"$GUEST_SHUTDOWN_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    ensure_ipad_usb
    sshpass -p "$VZ_IPAD_PASSWORD" ssh "${IPAD_SSH_ARGS[@]}" \
        -o ControlMaster=no -o ControlPath=none \
        -N -L "127.0.0.1:$GUEST_SHUTDOWN_PORT:$GUEST_HOST:22" \
        "$IPAD_TARGET" &
    shutdown_tunnel_pid=$!
    for _ in {1..12}; do
        lsof -nP -iTCP:"$GUEST_SHUTDOWN_PORT" -sTCP:LISTEN \
            >/dev/null 2>&1 && break
        sleep 0.25
    done
    if lsof -nP -iTCP:"$GUEST_SHUTDOWN_PORT" -sTCP:LISTEN \
        >/dev/null 2>&1; then
        printf -v guest_password_quoted '%q' "$GUEST_PASSWORD"
        set +e
        shutdown_output="$(sshpass -p "$GUEST_PASSWORD" ssh \
            -p "$GUEST_SHUTDOWN_PORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=4 -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password \
            -o NumberOfPasswordPrompts=1 "$GUEST_USER@127.0.0.1" \
            "printf '%s\\n' $guest_password_quoted | sudo -S -p '' -v && \
             echo VZ_GUEST_SHUTDOWN_REQUESTED && sudo shutdown -h now" 2>&1)"
        set -e
        if [[ "$shutdown_output" == *VZ_GUEST_SHUTDOWN_REQUESTED* ]]; then
            echo "requested guest OS shutdown over SSH"
            # Give launchd/filesystems time to finish, then skip the virtual
            # power-button sheet and go straight to the bounded VZ stop path.
            sleep 8
            TIMEOUT=0
            FORCE_TIMEOUT=3
        fi
    fi
    listener_pids="$(lsof -t -iTCP:"$GUEST_SHUTDOWN_PORT" \
        -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$listener_pids" ]]; then
        # shellcheck disable=SC2086
        kill $listener_pids 2>/dev/null || true
    fi
    kill "$shutdown_tunnel_pid" 2>/dev/null || true
    wait "$shutdown_tunnel_pid" 2>/dev/null || true
fi

ipad_ssh "
set -eu
app=/var/jb/Applications/VirtualMac.app/VirtualMac
host_pattern=/VirtualMac.app/VirtualMac
vmm_pattern=/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
find_pids() {
  target=\$1
  ps -axo pid=,comm= | while read -r pid executable; do
    case "\$executable" in
      *"\$target") echo "\$pid" ;;
    esac
  done
}
host_pids=\$(find_pids "\$host_pattern" || true)
vmm_pids=\$(find_pids "\$vmm_pattern" || true)
if test -z \"\$host_pids\" && test -z \"\$vmm_pids\"; then
  exit 0
fi
if test -z \"\$vmm_pids\"; then
  if test '$STOP_HOST' = 1; then
    test -z \"\$host_pids\" || kill -9 \$host_pids 2>/dev/null || true
    sleep 1
  else
    echo 'no VM is running; host remains in the library'
  fi
  exit 0
fi
rm -f /tmp/vz-guest-stopped /tmp/vz-guest-stop-failed \
  /tmp/vz-force-stop-failed /tmp/vz-request-guest-stop \
  /tmp/vz-request-force-stop
if test -x \"\$app\"; then
  touch /tmp/vz-request-guest-stop
  chown mobile:mobile /tmp/vz-request-guest-stop
  remaining='$TIMEOUT'
  while test \"\$remaining\" -gt 0 &&
        test ! -f /tmp/vz-guest-stopped &&
        test ! -f /tmp/vz-guest-stop-failed; do
    sleep 1
    remaining=\$((remaining - 1))
  done
fi
if test -f /tmp/vz-guest-stopped; then
  echo 'guest reported a clean stop'
else
  if test -f /tmp/vz-guest-stop-failed; then
    echo 'guest clean stop failed:'
    cat /tmp/vz-guest-stop-failed
  else
    echo 'guest clean stop did not complete; requesting direct VM stop'
  fi
  touch /tmp/vz-request-force-stop
  chown mobile:mobile /tmp/vz-request-force-stop
  remaining='$FORCE_TIMEOUT'
  while test "\$remaining" -gt 0 &&
        test ! -f /tmp/vz-guest-stopped &&
        test ! -f /tmp/vz-force-stop-failed; do
    sleep 1
    remaining=\$((remaining - 1))
  done
  if test -f /tmp/vz-guest-stopped; then
    echo 'direct VM stop completed'
  elif test -f /tmp/vz-force-stop-failed; then
    echo 'direct VM stop failed:'
    cat /tmp/vz-force-stop-failed
  else
    echo 'direct VM stop timed out; terminating host processes'
  fi
fi
if test '$STOP_HOST' = 0; then
  remaining=10
  while test \"\$remaining\" -gt 0; do
    vmm_pids=\$(find_pids \"\$vmm_pattern\" || true)
    test -z \"\$vmm_pids\" && break
    sleep 1
    remaining=\$((remaining - 1))
  done
  vmm_pids=\$(find_pids \"\$vmm_pattern\" || true)
  test -z \"\$vmm_pids\" || kill -9 \$vmm_pids 2>/dev/null || true
  rm -f /tmp/vz-request-guest-stop /tmp/vz-request-force-stop
  echo 'VM stopped; host returned to the library'
  exit 0
fi
test -z \"\$host_pids\" || kill \$host_pids 2>/dev/null || true
test -z \"\$vmm_pids\" || kill \$vmm_pids 2>/dev/null || true
sleep 1
host_pids=\$(find_pids "\$host_pattern" || true)
vmm_pids=\$(find_pids "\$vmm_pattern" || true)
test -z \"\$host_pids\" || kill -9 \$host_pids 2>/dev/null || true
test -z \"\$vmm_pids\" || kill -9 \$vmm_pids 2>/dev/null || true
rm -f /tmp/vz-request-guest-stop /tmp/vz-request-force-stop
remaining=10
while test "\$remaining" -gt 0; do
  host_pids=\$(find_pids "\$host_pattern" || true)
  vmm_pids=\$(find_pids "\$vmm_pattern" || true)
  if test -z \"\$host_pids\" && test -z \"\$vmm_pids\"; then
    break
  fi
  sleep 1
  remaining=\$((remaining - 1))
done
if test -n \"\$host_pids\" || test -n \"\$vmm_pids\"; then
  echo 'error: VM host processes remain after stop' >&2
  exit 1
fi
"
