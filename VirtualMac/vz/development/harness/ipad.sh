#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

case "$1" in
  ssh) shift; ipad_ssh "$@";;
  scp) shift; ipad_scp "$@";;
  *) echo "usage: ipad.sh ssh '<cmd>' | scp <src> 127.0.0.1:<dst>"; exit 1;;
esac
