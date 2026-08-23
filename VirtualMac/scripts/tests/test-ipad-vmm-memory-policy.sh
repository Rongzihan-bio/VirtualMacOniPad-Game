#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/memorystatus-probe"
BIN="$OUT/memorystatus-probe"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}/memorystatus-probe"

need_command ldid
need_command xcrun
need_file "$VZ_REPO_ROOT/vz/development/probes/memorystatus_probe.c"
need_file "$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"
mkdir -p "$OUT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" \
    -isysroot "$SDK" \
    "$VZ_REPO_ROOT/vz/development/probes/memorystatus_probe.c" -o "$BIN"
ldid -S"$VZ_REPO_ROOT/vz/patches/vmm.ents.xml" "$BIN"
hash="$(ldid -h "$BIN" | sed -n 's/^CDHash=//p')"
test -n "$hash"

ensure_ipad_usb
ipad_scp "$BIN" "$IPAD_TARGET:$REMOTE"
ipad_ssh "PATH=/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin; export PATH; \
    chmod 755 '$REMOTE'; jbctl trustcache add '$hash'; \
    pid=\$(ps ax -o pid= -o command= | awk \
        '/com\\.apple\\.Virtualization\\.VirtualMachine/ { print \$1; exit }'); \
    app_pid=\$(ps ax -o pid= -o command= | awk \
        '/VirtualMac\\.app\\/VirtualMac/ { print \$1; exit }'); \
    test -n \"\$pid\" || { echo 'error: no running Virtual Mac VMM' >&2; exit 1; }; \
    test -n \"\$app_pid\" || { echo 'error: no running Virtual Mac app' >&2; exit 1; }; \
    expected=\$((\$(sysctl -n hw.memsize) / 524288)); \
    output=\$('$REMOTE' \"\$pid\"); printf '%s\\n' \"\$output\"; \
    printf '%s\\n' \"\$output\" | grep -Fq \
        \"active=\$expected/0x0 inactive=\$expected/0x0\" || { \
        echo \"error: expected non-fatal VMM limit \$expected MiB\" >&2; \
        exit 1; \
    }; \
    vmm_priority=\$(printf '%s\\n' \"\$output\" | sed -n \
        's/.* priority=\\([0-9][0-9]*\\) .*/\\1/p' | tail -1); \
    app_output=\$('$REMOTE' \"\$app_pid\"); printf '%s\\n' \"\$app_output\"; \
    app_priority=\$(printf '%s\\n' \"\$app_output\" | sed -n \
        's/.* priority=\\([0-9][0-9]*\\) .*/\\1/p' | tail -1); \
    test -n \"\$vmm_priority\" -a -n \"\$app_priority\" || { \
        echo 'error: could not read app/VMM jetsam priorities' >&2; exit 1; \
    }; \
    test \"\$app_priority\" -gt \"\$vmm_priority\" || { \
        echo \"error: app jetsam priority \$app_priority must exceed VMM \$vmm_priority\" >&2; \
        exit 1; \
    }"
