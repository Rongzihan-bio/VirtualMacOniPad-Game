#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

BUNDLE="${1:-/var/mobile/Media/VirtualMac/Sequoia.bundle}"
TIMEOUT="${VZ_IPAD_BOOT_TIMEOUT:-120}"
REMOTE_APP_PATTERN="/VirtualMac.app/VirtualMac"

[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
    die "VZ_IPAD_BOOT_TIMEOUT must be a positive integer"
printf -v bundle_quoted '%q' "$BUNDLE"

VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"
ipad_ssh "
set -eu
bundle=$bundle_quoted
for name in Disk.img AuxiliaryStorage HardwareModel MachineIdentifier; do
  test -f \"\$bundle/\$name\"
done
killall VirtualMac 2>/dev/null || true
killall com.apple.Virtualization.Installation 2>/dev/null || true
killall usbmuxd 2>/dev/null || true
rm -f /var/run/usbmuxd /tmp/vzusbmuxd /tmp/vz-usbmuxd-enable
rm -f /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
touch /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
chown mobile:mobile /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
printf '%s\\n' \"\$bundle\" >/tmp/vz-autoboot-path
chown mobile:mobile /tmp/vz-autoboot-path
/var/jb/usr/bin/uiopen --bundleid com.mac.virtual
"

for ((elapsed = 0; elapsed < TIMEOUT; elapsed++)); do
    result="$(ipad_ssh "
if grep -Fq '[VirtualMac] VM STARTED state=1' /tmp/VirtualMac.log; then
  echo started
elif grep -q 'VM start failed:' /tmp/VirtualMac.log; then
  echo failed
elif test '$elapsed' -ge 10 &&
     ! ps ax | grep -F '$REMOTE_APP_PATTERN' | grep -v grep >/dev/null 2>&1; then
  echo stopped
else
  echo pending
fi
")"
    case "$result" in
        started)
            ipad_ssh "tail -n 20 /tmp/VirtualMac.log"
            printf 'IPAD_VM_BUNDLE_STARTED\t%s\n' "$BUNDLE"
            exit 0
            ;;
        failed|stopped)
            ipad_ssh "tail -n 60 /tmp/VirtualMac.log; tail -n 60 /tmp/vmmhook.log"
            die "iPad VM $result while booting $BUNDLE"
            ;;
    esac
    sleep 1
done

ipad_ssh "tail -n 60 /tmp/VirtualMac.log; tail -n 60 /tmp/vmmhook.log"
die "iPad VM did not start within ${TIMEOUT}s: $BUNDLE"
