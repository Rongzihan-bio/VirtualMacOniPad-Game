#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

PROBE="$VZ_BUILD_ROOT/probes/vmnet-probe"
REMOTE="/var/jb/usr/local/bin/vmnet-probe"
RUNTIME="$VZ_BUILD_ROOT/probes/vmnet-runtime"
PLIST="$VZ_REPO_ROOT/vz/development/probes/vmnet-probe-launchd.plist"
DEPLOY_PLIST="$VZ_BUILD_ROOT/probes/vmnet-probe-launchd.plist"
need_command ldid
need_command plutil
need_file "$PROBE"
need_file "$RUNTIME/vmnet.framework/vmnet"
need_file "$RUNTIME/Netrb.framework/Netrb"
need_file "$PLIST"
cp "$PLIST" "$DEPLOY_PLIST"
if [[ "${VZ_VMNET_PROBE_WAIT_FOR_DEBUGGER:-0}" == 1 ]]; then
    plutil -insert WaitForDebugger -bool YES "$DEPLOY_PLIST"
fi
ensure_ipad_usb
ipad_scp "$PROBE" "$IPAD_TARGET:/tmp/vmnet-probe"
ipad_scp "$RUNTIME/vmnet.framework/vmnet" "$IPAD_TARGET:/tmp/vmnet"
ipad_scp "$RUNTIME/Netrb.framework/Netrb" "$IPAD_TARGET:/tmp/Netrb"
ipad_scp "$DEPLOY_PLIST" "$IPAD_TARGET:/tmp/vmnet-probe.plist"
hash="$(ldid -h "$PROBE" | sed -n 's/^CDHash=//p')"
vmnet_hash="$(ldid -h "$RUNTIME/vmnet.framework/vmnet" | sed -n 's/^CDHash=//p')"
netrb_hash="$(ldid -h "$RUNTIME/Netrb.framework/Netrb" | sed -n 's/^CDHash=//p')"
ipad_ssh "
set -eu
mkdir -p /var/jb/usr/local/bin /var/jb/usr/local/lib/vmnet.framework \
  /var/jb/usr/local/lib/Netrb.framework /var/jb/Library/LaunchDaemons
/var/jb/usr/bin/launchctl bootout \
  user/501/com.mac.virtual.vmnet-probe 2>/dev/null || true
/var/jb/usr/bin/launchctl bootout \
  system/com.mac.virtual.vmnet-probe 2>/dev/null || true
install -o root -g wheel -m 755 /tmp/vmnet-probe '$REMOTE'
install -o root -g wheel -m 755 /tmp/vmnet \
  /var/jb/usr/local/lib/vmnet.framework/vmnet
install -o root -g wheel -m 755 /tmp/Netrb \
  /var/jb/usr/local/lib/Netrb.framework/Netrb
install -o root -g wheel -m 644 /tmp/vmnet-probe.plist \
  /var/jb/Library/LaunchDaemons/com.mac.virtual.vmnet-probe.plist
rm -f /tmp/vmnet-probe /tmp/vmnet /tmp/Netrb /tmp/vmnet-probe.plist \
  /tmp/vmnet-probe-launchd.log
jbctl trustcache add '$hash'
jbctl trustcache add '$vmnet_hash'
jbctl trustcache add '$netrb_hash'
/var/jb/usr/bin/launchctl bootstrap user/501 \
  /var/jb/Library/LaunchDaemons/com.mac.virtual.vmnet-probe.plist
/var/jb/usr/bin/launchctl kickstart -k \
  user/501/com.mac.virtual.vmnet-probe
i=0
probe_status=
while [ x\$probe_status = x ]; do
  i=\$((i + 1))
  if [ "\$i" -ge 130 ]; then
    echo 'vmnet probe: launchd job timed out' >&2
    exit 124
  fi
  probe_status=\$(/var/jb/usr/bin/launchctl print \
    user/501/com.mac.virtual.vmnet-probe 2>/dev/null | \
    sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\)$/\1/p' | \
    tail -1 || true)
  if [ x\$probe_status != x ]; then
    break
  fi
  sleep 1
done
cat /tmp/vmnet-probe-launchd.log 2>/dev/null || true
exit "\${probe_status:-1}"
"
