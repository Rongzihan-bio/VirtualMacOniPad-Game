#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

IPAD_ROOT="/var/mobile/Media/VirtualMac"
BASELINE="${VZ_IPAD_BASELINE:-$IPAD_ROOT/Baselines/GoodVM.bundle}"
WORKING="$IPAD_ROOT/GoodVM.bundle"
STAGE="$IPAD_ROOT/Transfers/GoodVM-restore-stage.bundle"

VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"
ipad_ssh "
set -eu
test -f '$BASELINE/Disk.img'
test -f '$BASELINE/AuxiliaryStorage'
test \"\$(stat -c %s '$BASELINE/Disk.img')\" = 68719476736
mkdir -p '$IPAD_ROOT/Transfers'
rm -rf '$STAGE'
/var/jb/usr/bin/cp -a --reflink=always '$BASELINE' '$STAGE'
rm -rf '$WORKING'
mv '$STAGE' '$WORKING'
stat -c '%s %n' '$WORKING/'*
"

echo "working iPad guest restored from the clean on-device baseline"
