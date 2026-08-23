#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command xcrun
need_command sshpass

GUEST_HOST="${VZ_GUEST_HOST:-127.0.0.1}"
GUEST_PORT="${VZ_GUEST_PORT:-2224}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER}"
GUEST_USER="$VZ_GUEST_USER"
: "${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD}"
CHUNK_MIB="${PVG_PROBE_CHUNK_MIB:-64}"
MAXIMUM_MIB="${PVG_PROBE_MAXIMUM_MIB:-12288}"
DELAY_USEC="${PVG_PROBE_DELAY_USEC:-100000}"

OUT="$VZ_BUILD_ROOT/development/pvg-memory-probe"
RESULT_DIR="$VZ_BUILD_ROOT/diagnostics/pvg-memory-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$(dirname "$OUT")" "$RESULT_DIR"

xcrun --sdk macosx clang -fno-objc-arc -arch arm64 \
    -mmacosx-version-min=12.0 -framework Foundation -framework Metal \
    "$SCRIPT_DIR/pvg-memory-probe.m" -o "$OUT"

SSH_ARGS=(
    -p "$GUEST_PORT"
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o IdentitiesOnly=yes
)
SCP_ARGS=(
    -P "$GUEST_PORT"
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o IdentitiesOnly=yes
)
TARGET="$GUEST_USER@$GUEST_HOST"

sshpass -p "$VZ_GUEST_PASSWORD" scp "${SCP_ARGS[@]}" \
    "$OUT" "$TARGET:/tmp/pvg-memory-probe"
sshpass -p "$VZ_GUEST_PASSWORD" ssh "${SSH_ARGS[@]}" "$TARGET" \
    "chmod 755 /tmp/pvg-memory-probe; /tmp/pvg-memory-probe \
      '$CHUNK_MIB' '$MAXIMUM_MIB' '$DELAY_USEC'" \
    | tee "$RESULT_DIR/guest-probe.log"

if [[ -n "${VZ_IPAD_PASSWORD:-}" ]]; then
    ensure_ipad_usb
    ipad_scp "$IPAD_TARGET:/tmp/vmm.stderr.log" \
        "$RESULT_DIR/vmm.stderr.log" 2>/dev/null || true
    ipad_scp "$IPAD_TARGET:/tmp/pvg-trace.log" \
        "$RESULT_DIR/pvg-trace.log" 2>/dev/null || true
fi

echo "PVG memory probe evidence: $RESULT_DIR"
