#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
: "${VZ_IPAD_INSTALL_IPSW:?set VZ_IPAD_INSTALL_IPSW to an on-device restore image}"
IPSW="$VZ_IPAD_INSTALL_IPSW"

ipad_ssh "
set -eu
test -f '$IPSW'
killall restore-image-probe 2>/dev/null || true
killall com.apple.Virtualization.Installation 2>/dev/null || true
rm -f /tmp/installation_ep.txt /tmp/installation.stderr.log \
  /tmp/restore-vmm.stderr.log \
  /tmp/installationhook.log /tmp/vzxpchook.log
'$REMOTE/install/restore-image-probe' '$IPSW' \
  > /tmp/restore-image-probe.log 2>&1 &
echo \$! >/tmp/restore-image-probe.pid
"

for _ in {1..180}; do
    result="$(ipad_ssh "
      if ! kill -0 \$(cat /tmp/restore-image-probe.pid) 2>/dev/null; then
        cat /tmp/restore-image-probe.log
        echo PROBE_FINISHED
      else
        tail -20 /tmp/restore-image-probe.log
      fi
    ")"
    if [[ "$result" == *PROBE_FINISHED* ]]; then
        printf '%s\n' "$result"
        [[ "$result" == *RESTORE_LOAD_OK* ]]
        exit
    fi
    sleep 1
done

ipad_ssh "cat /tmp/restore-image-probe.log; cat /tmp/vzxpchook.log; \
  cat /tmp/installationhook.log; cat /tmp/installation.stderr.log"
die "restore-image probe timed out"
