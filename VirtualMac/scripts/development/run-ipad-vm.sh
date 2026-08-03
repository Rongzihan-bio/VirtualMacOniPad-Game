#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
BUNDLE="${VZ_IPAD_VM_BUNDLE:-/var/mobile/Media/VirtualMac/Sequoia.bundle}"
RUN_SECONDS="${VZ_RUN_SECONDS:-120}"
RESULT_DIR="$VZ_BUILD_ROOT/validation"
RESULT="$RESULT_DIR/ipad-vm-start.txt"

mkdir -p "$RESULT_DIR"
active="$(ipad_ssh \
    "ps ax | grep -E '$REMOTE/payload/bin/vzboot|$REMOTE/payload/VirtualMachine.xpc' | grep -v grep || true")"
[[ -z "$active" ]] ||
    die "native VZ processes are already active on the iPad (PIDs: $active)"
ipad_ssh "test -f '$BUNDLE/Disk.img'; test -f '$BUNDLE/AuxiliaryStorage'; \
    test -f '$BUNDLE/HardwareModel'; test -f '$BUNDLE/MachineIdentifier'"

remote_optional_env=""
for name in VZ_NO_GRAPHICS VZ_NO_INPUT VZ_NO_STORAGE VZ_SKIP_VALIDATE \
    VMMHOOK_DEBUG_SLEEP VMMHOOK_TRACE_USB VMMHOOK_TRACE_IOKIT \
    VMMHOOK_TRACE_VCPU; do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
        printf -v quoted_value '%q' "$value"
        remote_optional_env+="export $name=$quoted_value
"
    fi
done

remote_script="$(cat <<EOF
set -eu
rm -f /tmp/vzxpchook.log /tmp/vmmhook.log /tmp/vmm.stderr.log \
  /tmp/vmm_ep.txt '$REMOTE/vzboot.log'
export VZ_VMM_BIN='$REMOTE/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine'
export VZ_AVP_BOOTER='$REMOTE/payload/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin'
export VZ_RUN_SECONDS='$RUN_SECONDS'
export DYLD_INSERT_LIBRARIES='$REMOTE/payload/bin/VZHostCompat.dylib'
$remote_optional_env
'$REMOTE/payload/bin/vzboot' \
  '$REMOTE/payload/Frameworks/Hypervisor.framework/Hypervisor' \
  '$REMOTE/payload/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics' \
  '$REMOTE/payload/Frameworks/Virtualization.framework/Virtualization' \
  '$BUNDLE' \
  >'$REMOTE/vzboot.log' 2>&1 &
host_pid=\$!
printf 'HOST_PID\\t%s\\n' "\$host_pid"
i=0
while kill -0 "\$host_pid" 2>/dev/null && test "\$i" -lt '$RUN_SECONDS'; do
  sleep 1
  i=\$((i + 1))
done
echo HOST_LOG
cat '$REMOTE/vzboot.log' 2>/dev/null || true
echo HOST_HOOK_LOG
cat /tmp/vzxpchook.log 2>/dev/null || true
echo VMM_HOOK_LOG
cat /tmp/vmmhook.log 2>/dev/null || true
echo VMM_STDERR
cat /tmp/vmm.stderr.log 2>/dev/null || true
echo PROCESSES
ps ax | grep -E 'vzboot|com.apple.Virtualization.VirtualMachine' | grep -v grep || true
wait "\$host_pid" || true
EOF
)"

ipad_ssh "$remote_script" | tee "$RESULT"
echo "iPad VM start evidence: $RESULT"
