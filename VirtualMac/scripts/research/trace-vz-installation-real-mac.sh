#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
: "${VZ_REAL_MAC_VM:?set VZ_REAL_MAC_VM to the reference restore destination}"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
REMOTE_IPSW="${VZ_REAL_MAC_INSTALL_IPSW:-$REMOTE_ROOT/input/UniversalMac_13.6_22G120_Restore.ipsw}"
REMOTE_TOOL="$REMOTE_ROOT/DerivedData/Build/Products/Debug/InstallationTool-Objective-C"
LOCAL_LLDB="$VZ_REPO_ROOT/vz/development/probes/trace_vz_installation_real_mac.lldb"
REMOTE_LLDB="$REMOTE_ROOT/trace_vz_installation_real_mac.lldb"
LOCAL_LLDB_PY="$VZ_REPO_ROOT/vz/development/probes/trace_vz_installation_lldb.py"
REMOTE_LLDB_PY="$REMOTE_ROOT/trace_vz_installation_lldb.py"

need_command sshpass
need_file "$LOCAL_LLDB"
need_file "$LOCAL_LLDB_PY"
real_mac_ssh_args

case "${1:-}" in
    start)
        trace_id="$(date -u +%Y%m%dT%H%M%SZ)"
        remote_trace="$REMOTE_ROOT/traces/install-$trace_id"
        real_mac_scp "$LOCAL_LLDB" "$REAL_MAC_TARGET:$REMOTE_LLDB"
        real_mac_scp "$LOCAL_LLDB_PY" "$REAL_MAC_TARGET:$REMOTE_LLDB_PY"
        real_mac_ssh "test -f '$REMOTE_IPSW' && test -x '$REMOTE_TOOL'"
        real_mac_ssh "if test -d '$VZ_REAL_MAC_VM'; then rmdir '$VZ_REAL_MAC_VM'; fi; mkdir -p '$remote_trace'"

        real_mac_ssh "printf '%s\\n' '$VZ_REAL_MAC_PASSWORD' | sudo -S -b fs_usage -w -f pathname -t 7200 InstallationTool-Objective-C com.apple.Virtualization.Installation com.apple.Virtualization.VirtualMachine >'$remote_trace/fs-usage.log' 2>&1"
        real_mac_ssh "cd '$REMOTE_ROOT' && printf '%s\\n' '$VZ_REAL_MAC_PASSWORD' | sudo -S -b lldb -s '$REMOTE_LLDB' >'$remote_trace/lldb.log' 2>&1"
        real_mac_ssh "nohup /usr/bin/log stream --style compact --level debug --predicate '(process == \"InstallationTool-Objective-C\") || (process == \"com.apple.Virtualization.Installation\") || (process == \"com.apple.Virtualization.VirtualMachine\") || (subsystem BEGINSWITH \"com.apple.Virtualization\")' >'$remote_trace/unified.log' 2>&1 </dev/null & echo \$! >'$remote_trace/log-stream.pid'"
        sleep 3
        remote_vm_parent="$(dirname "$VZ_REAL_MAC_VM")"
        real_mac_ssh "cd '$remote_vm_parent' && nohup '$REMOTE_TOOL' '$REMOTE_IPSW' >'$remote_trace/installer.log' 2>&1 </dev/null & echo \$! >'$remote_trace/installer.pid'; printf '%s\\n' '$remote_trace' >'$REMOTE_ROOT/current-install-trace'"
        echo "Started Ventura reference restore trace: $remote_trace"
        ;;
    status)
        remote_vm_parent="$(dirname "$VZ_REAL_MAC_VM")"
        real_mac_ssh "trace=\$(cat '$REMOTE_ROOT/current-install-trace'); echo \"trace=\$trace\"; ls -lh '$REMOTE_IPSW'; pgrep -fl 'InstallationTool-Objective-C|com.apple.Virtualization.Installation|com.apple.Virtualization.VirtualMachine|lldb.*trace_vz_installation' || true; tail -30 \"\$trace/installer.log\" 2>/dev/null || true; df -h '$remote_vm_parent' | tail -1; du -sh '$VZ_REAL_MAC_VM' 2>/dev/null || true"
        ;;
    stop-trace)
        real_mac_ssh "trace=\$(cat '$REMOTE_ROOT/current-install-trace'); if test -f \"\$trace/log-stream.pid\"; then kill \$(cat \"\$trace/log-stream.pid\") 2>/dev/null || true; fi; printf '%s\\n' '$VZ_REAL_MAC_PASSWORD' | sudo -S pkill -f 'lldb.*trace_vz_installation_real_mac' 2>/dev/null || true; pids=\$(pgrep -f '^fs_usage .*InstallationTool-Objective-C' || true); if test -n \"\$pids\"; then printf '%s\\n' '$VZ_REAL_MAC_PASSWORD' | sudo -S kill \$pids 2>/dev/null || true; fi; echo \"Trace files: \$trace\""
        ;;
    *)
        echo "usage: $0 start | status | stop-trace" >&2
        exit 2
        ;;
esac
