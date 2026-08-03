#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
COMMANDS="$VZ_REPO_ROOT/vz/development/lldb/trace_installation_restore.lldb"
need_file "$COMMANDS"
ensure_ipad_usb
ipad_ssh "killall lldb 2>/dev/null || true; mkdir -p '$REMOTE/lldb'"
ipad_scp "$COMMANDS" \
    "$IPAD_TARGET:$REMOTE/lldb/trace_installation_restore.lldb"
ipad_ssh "
rm -f /tmp/installation-restore-lldb.log
nohup /var/jb/usr/bin/lldb -b \
  -o 'process attach --name com.apple.Virtualization.Installation --waitfor' \
  -s '$REMOTE/lldb/trace_installation_restore.lldb' \
  -o continue \
  >/tmp/installation-restore-lldb.log 2>&1 </dev/null &
echo LLDB_TRACE_STARTED
echo LOG=/tmp/installation-restore-lldb.log
"
