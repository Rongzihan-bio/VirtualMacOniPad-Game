#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

result="$(ipad_ssh '
set -eu
host_pattern=/VirtualMac.app/VirtualMac
vmm_pattern=/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
ps ax | grep -F "$host_pattern" | grep -v grep >/dev/null
ps ax | grep -F "$vmm_pattern" | grep -v grep >/dev/null
health=$(grep "health state=" /tmp/VirtualMac.log | tail -1)
test -n "$health"
echo "$health" | grep -q "state=1"
test "$(grep -c "TASK_LOOKUP_MISS" /tmp/pvg-trace.log || true)" = 0
test "$(grep "TASK_RESERVE" /tmp/pvg-trace.log | grep -c "result=0x0" || true)" = 0
test "$(grep "TASK_MAP" /tmp/pvg-trace.log | grep -c "result=0" || true)" = 0
if grep "TASK_MAP" /tmp/pvg-trace.log | grep -q "within=0"; then
  grep -q "TASK_OVERFLOW_RESERVE" /tmp/pvg-trace.log
fi
test "$(grep -Ec "task map failed|mapping cannot fit one reservation|overflow reservation failed|graphics address space exhausted" /tmp/vmm.stderr.log || true)" = 0
test "$(grep -c "METAL_COMMAND_BUFFER.*error=" /tmp/pvg-trace.log || true)" = 0
echo "$health"
grep "METAL_HEALTH" /tmp/pvg-trace.log | tail -1
printf "tasks=%s managed-textures=%s\n" \
  "$(grep -c "TASK_RESERVE" /tmp/pvg-trace.log || true)" \
  "$(grep -c "METAL_TEXTURE.*managed-to-shared" /tmp/pvg-trace.log || true)"
')"

printf '%s\n' "$result"
echo "native iPad VM health checks passed"
