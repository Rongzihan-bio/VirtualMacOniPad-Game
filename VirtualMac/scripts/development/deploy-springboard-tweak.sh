#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUT="$VZ_BUILD_ROOT/ipad-tweak"
DYLIB="$OUT/VZKeyboardPassthrough.dylib"
PLIST="$OUT/VZKeyboardPassthrough.plist"
need_command ldid
need_file "$DYLIB"
need_file "$PLIST"
hash="$(ldid -h "$DYLIB" | sed -n 's/^CDHash=//p')"

VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"
ensure_ipad_usb
ipad_scp "$DYLIB" "$IPAD_TARGET:/tmp/VZKeyboardPassthrough.dylib"
ipad_scp "$PLIST" "$IPAD_TARGET:/tmp/VZKeyboardPassthrough.plist"
ipad_ssh "
set -eu
if test -x /var/jb/usr/bin/jbctl || test -x /var/jb/basebin/jbctl; then
    remote=/var/jb/Library/MobileSubstrate/DynamicLibraries
    jbctl=/var/jb/usr/bin/jbctl
    test -x \"\$jbctl\" || jbctl=/var/jb/basebin/jbctl
    mkdir -p \"\$remote\"
    install -m 755 /tmp/VZKeyboardPassthrough.dylib \"\$remote/VZKeyboardPassthrough.dylib\"
    install -m 644 /tmp/VZKeyboardPassthrough.plist \"\$remote/VZKeyboardPassthrough.plist\"
    \"\$jbctl\" trustcache add '$hash'
    reload=/var/jb/usr/bin/sbreload
else
    # Taurine/libhooker scans this rootful directory. Preflight the final
    # inode through jbexec because its trust is path dependent on iPadOS 14.
    remote=/usr/lib/TweakInject
    mkdir -p \"\$remote\"
    install -m 755 /tmp/VZKeyboardPassthrough.dylib \"\$remote/VZKeyboardPassthrough.dylib\"
    install -m 644 /tmp/VZKeyboardPassthrough.plist \"\$remote/VZKeyboardPassthrough.plist\"
    PREFLIGHT=1 /bin/bash -c 'exec -a \"\$1\" /taurine/jbexec' _ \
        \"\$remote/VZKeyboardPassthrough.dylib\" >/dev/null 2>&1 || true
    reload=/usr/bin/sbreload
fi
rm -f /tmp/VZKeyboardPassthrough.dylib /tmp/VZKeyboardPassthrough.plist \
  /tmp/vz-springboard-shortcuts.log
touch /tmp/virtual-mac-open-after-respring
chown mobile:mobile /tmp/virtual-mac-open-after-respring
\"\$reload\"
" || true

for _ in {1..30}; do
    if ipad_ssh "test -f /tmp/vz-springboard-shortcuts.log" \
        >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
ipad_ssh "
uiopen=/var/jb/usr/bin/uiopen
test -x \"\$uiopen\" || uiopen=/usr/bin/uiopen
\"\$uiopen\" --bundleid com.mac.virtual || true
cat /tmp/vz-springboard-shortcuts.log 2>/dev/null || true
"
