#!/bin/bash

set -euo pipefail

VZ_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VZ_BUILD_ROOT="${VZ_BUILD_ROOT:-$VZ_REPO_ROOT/build}"

if [[ "${VZ_IGNORE_ENV_FILE:-0}" != 1 && -f "$VZ_REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$VZ_REPO_ROOT/.env"
    set +a
fi

die() {
    echo "error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

need_file() {
    [[ -f "$1" ]] || die "missing file: $1"
}

real_mac_ssh_args() {
    : "${VZ_REAL_MAC_HOST:?set VZ_REAL_MAC_HOST in .env or the environment}"
    VZ_REAL_MAC_PORT="${VZ_REAL_MAC_PORT:-22}"
    : "${VZ_REAL_MAC_USER:?set VZ_REAL_MAC_USER in .env or the environment}"
    : "${VZ_REAL_MAC_PASSWORD:?set VZ_REAL_MAC_PASSWORD in .env or the environment}"

    REAL_MAC_SSH_ARGS=(
        -p "$VZ_REAL_MAC_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
    )
    REAL_MAC_SCP_ARGS=(
        -P "$VZ_REAL_MAC_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
    )
    REAL_MAC_TARGET="$VZ_REAL_MAC_USER@$VZ_REAL_MAC_HOST"
}

real_mac_ssh() {
    real_mac_ssh_args
    sshpass -p "$VZ_REAL_MAC_PASSWORD" ssh "${REAL_MAC_SSH_ARGS[@]}" "$REAL_MAC_TARGET" "$@"
}

real_mac_scp() {
    real_mac_ssh_args
    sshpass -p "$VZ_REAL_MAC_PASSWORD" scp "${REAL_MAC_SCP_ARGS[@]}" "$@"
}

ipad_ssh_args() {
    if [[ -z "${VZ_IPAD_UDID:-}" ]]; then
        need_command idevice_id
        local devices count
        devices="$(idevice_id -l)"
        count="$(printf '%s\n' "$devices" | awk 'NF { count++ } END { print count+0 }')"
        [[ "$count" == 1 ]] ||
            die "attach exactly one iPad or set VZ_IPAD_UDID"
        VZ_IPAD_UDID="$devices"
    fi
    VZ_IPAD_PORT="${VZ_IPAD_PORT:-2221}"
    # Package installation, trust-cache updates, and userspace restart are
    # privileged operations. The supported Dopamine deployment is root-only.
    VZ_IPAD_USER=root
    : "${VZ_IPAD_PASSWORD:?set VZ_IPAD_PASSWORD in .env or the environment}"
    local control_path="/tmp/VirtualMac-ssh-%C"

    IPAD_SSH_ARGS=(
        -p "$VZ_IPAD_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
        -o ControlMaster=auto
        -o ControlPersist=60
        -o "ControlPath=$control_path"
    )
    IPAD_SCP_ARGS=(
        -P "$VZ_IPAD_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
        -o ControlMaster=auto
        -o ControlPersist=60
        -o "ControlPath=$control_path"
    )
    IPAD_TARGET="$VZ_IPAD_USER@127.0.0.1"
}

ensure_ipad_usb() {
    ipad_ssh_args
    need_command iproxy
    mkdir -p "$VZ_BUILD_ROOT"
    if lsof -nP -iTCP:"$VZ_IPAD_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        return
    fi

    nohup iproxy -u "$VZ_IPAD_UDID" -l -s 127.0.0.1 \
        "$VZ_IPAD_PORT:22" >"$VZ_BUILD_ROOT/iproxy.log" 2>&1 </dev/null &
    for _ in {1..20}; do
        lsof -nP -iTCP:"$VZ_IPAD_PORT" -sTCP:LISTEN >/dev/null 2>&1 &&
            return
        sleep 0.25
    done
    die "iproxy did not open USB SSH port $VZ_IPAD_PORT"
}

ipad_ssh() {
    ensure_ipad_usb
    sshpass -p "$VZ_IPAD_PASSWORD" ssh \
        "${IPAD_SSH_ARGS[@]}" "$IPAD_TARGET" "$@"
}

ipad_scp() {
    ensure_ipad_usb
    sshpass -p "$VZ_IPAD_PASSWORD" scp "${IPAD_SCP_ARGS[@]}" "$@"
}
