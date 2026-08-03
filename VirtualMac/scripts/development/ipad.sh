#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

case "${1:-}" in
    ssh)
        shift
        ipad_ssh "$@"
        ;;
    scp)
        shift
        ensure_ipad_usb
        ipad_scp "$@"
        ;;
    *)
        die "usage: scripts/development/ipad.sh ssh command | scp source destination"
        ;;
esac
