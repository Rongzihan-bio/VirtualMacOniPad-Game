#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
: "${VZ_REAL_MAC_USB_BUNDLE:?set VZ_REAL_MAC_USB_BUNDLE to the VM bundle}"
REMOTE="$VZ_REAL_MAC_WORK"
BUNDLE="$VZ_REAL_MAC_USB_BUNDLE"
PYTHON_REMOTE="$REMOTE/trace_usb_hci_commands.py"
LLDB_COMMANDS_REMOTE="$REMOTE/trace-usb-hci.lldb"
LOCAL_PYTHON="$VZ_REPO_ROOT/vz/development/lldb/trace_usb_hci_commands.py"

need_file "$LOCAL_PYTHON"
real_mac_ssh_args
real_mac_scp "$LOCAL_PYTHON" "$REAL_MAC_TARGET:$PYTHON_REMOTE"

real_mac_ssh "
set -eu
pkill -f start-force-dfu 2>/dev/null || true
pkill -f com.apple.Virtualization.VirtualMachine 2>/dev/null || true
: >/tmp/vz-usb-command-trace.log
printf '%s\n' \
  'settings set auto-confirm true' \
  'process attach --name com.apple.Virtualization.VirtualMachine --waitfor' \
  'command script import $PYTHON_REMOTE' \
  'vz_usb_trace_install' \
  'continue' >'$LLDB_COMMANDS_REMOTE'
{ printf '%s\n' '$VZ_REAL_MAC_PASSWORD' | \
  sudo -S lldb -s '$LLDB_COMMANDS_REMOTE'; } \
  >'$REMOTE/trace-usb-hci-lldb.log' 2>&1 &
echo \$! >'$REMOTE/trace-usb-hci-lldb.pid'
sleep 1
DYLD_FRAMEWORK_PATH='$REMOTE/usb-oracle-runtime' \
  nohup '$REMOTE/start-force-dfu' '$BUNDLE' \
  >'$REMOTE/trace-usb-hci-vm.log' 2>&1 &
echo \$! >'$REMOTE/trace-usb-hci-vm.pid'
echo TRACE_STARTED
"

for _ in {1..30}; do
    trace="$(real_mac_ssh 'cat /tmp/vz-usb-command-trace.log 2>/dev/null || true')"
    if [[ "$trace" == *"command type="* ]]; then
        printf '%s\n' "$trace"
        exit
    fi
    sleep 1
done

die "real-Mac USB trace did not observe a command"
