#!/bin/bash

# Prove that a running iPad-hosted VM is using the bundled Ventura
# VideoToolbox host implementation. This briefly attaches LLDB and immediately
# detaches after listing images; the VM resumes before the command returns.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

ensure_ipad_usb
processes="$(ipad_ssh "ps ax | grep 'VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine' | grep -v grep")"
pid="$(printf '%s\n' "$processes" | awk 'NR == 1 { print $1 }')"
[[ -n "$pid" ]] || die "the iPad VirtualMachine process is not running"

images="$(ipad_ssh "printf 'process attach --pid $pid\\nimage list -b -o -f\\nprocess detach\\nquit\\n' | /var/jb/usr/bin/lldb 2>&1")"
printf '%s\n' "$images" | grep -E 'Process .* (stopped|detached)|VideoToolbox'

bundled='/VirtualMac/payload/Frameworks/VideoToolbox.framework/VideoToolbox'
printf '%s\n' "$images" | grep -F "$bundled" >/dev/null ||
    die "the VMM did not load the bundled macOS VideoToolbox framework"
printf '%s\n' "$images" | grep -F 'VideoToolboxParavirtualizationSupport.framework' >/dev/null ||
    die "the VMM did not load VideoToolboxParavirtualizationSupport"

printf 'IPAD_VIDEOTOOLBOX_RUNTIME_OK\tpid=%s\n' "$pid"
