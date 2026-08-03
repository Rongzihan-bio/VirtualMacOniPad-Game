#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
: "${VZ_IPAD_INSTALL_IPSW:?set VZ_IPAD_INSTALL_IPSW to an on-device restore image}"
: "${VZ_IPAD_INSTALL_BUNDLE:?set VZ_IPAD_INSTALL_BUNDLE to an on-device staging bundle}"
: "${VZ_IPAD_INSTALL_FINAL_BUNDLE:?set VZ_IPAD_INSTALL_FINAL_BUNDLE to the final on-device VM bundle}"
: "${VZ_IPAD_INSTALL_LOG:?set VZ_IPAD_INSTALL_LOG to an on-device log path}"
IPSW="$VZ_IPAD_INSTALL_IPSW"
STAGING="$VZ_IPAD_INSTALL_BUNDLE"
FINAL="$VZ_IPAD_INSTALL_FINAL_BUNDLE"
LOG="$VZ_IPAD_INSTALL_LOG"
TRACE_USB="${VZ_IPAD_INSTALL_TRACE_USB:-0}"
TRACE_IOKIT="${VZ_IPAD_INSTALL_TRACE_IOKIT:-1}"
TRACE_XPC_LIMIT="${VZ_IPAD_INSTALL_TRACE_XPC_LIMIT:-200}"
FAKE_USB="${VZ_IPAD_INSTALL_FAKE_USB:-1}"
USB_DEBUG_DELAY_MS="${VZ_IPAD_INSTALL_USB_DEBUG_DELAY_MS:-}"
USB_HANDSHAKE_PROBE="${VZ_IPAD_INSTALL_USB_HANDSHAKE_PROBE:-0}"
CPU_COUNT="${VZ_IPAD_INSTALL_CPU_COUNT:-4}"
MEMORY_SIZE="${VZ_IPAD_INSTALL_MEMORY_SIZE:-4294967296}"
STORAGE_SIZE="${VZ_IPAD_INSTALL_STORAGE_SIZE:-68719476736}"

ipad_ssh "
set -eu
VMMHOOK_TRACE_USB='$TRACE_USB' \
VMMHOOK_TRACE_IOKIT='$TRACE_IOKIT' \
VMMHOOK_TRACE_XPC_LIMIT='$TRACE_XPC_LIMIT' \
VMMHOOK_FAKE_USB='$FAKE_USB' \
INSTALL_USB_DEBUG_DELAY_MS='$USB_DEBUG_DELAY_MS' \
INSTALL_USB_TRACE_TRANSFERS='$TRACE_USB' \
  '$REMOTE/install/start-install.sh' '$IPSW' '$STAGING' '$FINAL' '$LOG' \
  '$CPU_COUNT' '$MEMORY_SIZE' '$STORAGE_SIZE'
"

for _ in {1..30}; do
    output="$(ipad_ssh "cat '$LOG' 2>/dev/null || true")"
    printf '%s\n' "$output"
    if [[ "$output" == *INSTALL_BEGIN* ||
          "$output" == *INSTALL_FAILED* ||
          "$output" == *INSTALL_SUCCEEDED* ]]; then
        exit
    fi
    sleep 1
done

die "installer did not reach its initial start marker"
