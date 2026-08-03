#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUT="$VZ_BUILD_ROOT/ipad-tweak"
DYLIB="$OUT/VZKeyboardPassthrough.dylib"
PLIST="$OUT/VZKeyboardPassthrough.plist"
REMOTE=/var/jb/Library/MobileSubstrate/DynamicLibraries

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
mkdir -p '$REMOTE'
install -m 755 /tmp/VZKeyboardPassthrough.dylib '$REMOTE/VZKeyboardPassthrough.dylib'
install -m 644 /tmp/VZKeyboardPassthrough.plist '$REMOTE/VZKeyboardPassthrough.plist'
jbctl trustcache add '$hash'
rm -f /tmp/VZKeyboardPassthrough.dylib /tmp/VZKeyboardPassthrough.plist \
  /tmp/vz-springboard-shortcuts.log
touch /tmp/virtual-mac-open-after-respring
chown mobile:mobile /tmp/virtual-mac-open-after-respring
/var/jb/usr/bin/sbreload
" || true

for _ in {1..30}; do
    if ipad_ssh "test -f /tmp/vz-springboard-shortcuts.log" \
        >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
ipad_ssh "
/var/jb/usr/bin/uiopen --bundleid com.mac.virtual || true
cat /tmp/vz-springboard-shortcuts.log 2>/dev/null || true
"
