#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
APP="$REMOTE_ROOT/DerivedData/Build/Products/Debug/macOSVirtualMachineSampleApp-Objective-C.app"
TRACE="$VZ_REPO_ROOT/vz/development/probes/trace_network_sharing_real_mac.lldb"
REMOTE_TRACE="$REMOTE_ROOT/trace_network_sharing_real_mac.lldb"

need_command sshpass
need_file "$TRACE"
real_mac_ssh_args
real_mac_scp "$TRACE" "$REAL_MAC_TARGET:$REMOTE_TRACE"

cat <<EOF
The trace fixture is installed on the Ventura Mac.

Terminal 1 (attach before starting the VM):
  ssh -p $VZ_REAL_MAC_PORT $VZ_REAL_MAC_USER@$VZ_REAL_MAC_HOST
  sudo launchctl kickstart -k system/com.apple.NetworkSharing
  sudo lldb -p \$(pgrep -x InternetSharing) -s $REMOTE_TRACE

Terminal 2 (trigger the known-good NAT path):
  ssh -p $VZ_REAL_MAC_PORT $VZ_REAL_MAC_USER@$VZ_REAL_MAC_HOST open -n $APP

At IOServiceOpen, save x3, finish, and inspect the result:
  register read x0 x1 x2 x3
  expr unsigned long long \$connect_out=(unsigned long long)\$x3
  thread backtrace
  finish
  register read x0 w0
  memory read --format x --size 4 --count 1 \$connect_out
EOF
