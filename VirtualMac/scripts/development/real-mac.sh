#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command sshpass

case "${1:-}" in
    ssh)
        shift
        real_mac_ssh "$@"
        ;;
    scp)
        shift
        real_mac_scp "$@"
        ;;
    *)
        echo "usage: scripts/development/real-mac.sh ssh '<command>'" >&2
        echo "       scripts/development/real-mac.sh scp <source> <destination>" >&2
        exit 2
        ;;
esac

