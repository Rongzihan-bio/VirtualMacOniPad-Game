#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

ensure_ipad_usb
ipad_ssh \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y network-cmds"
