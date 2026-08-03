#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SOURCE="$VZ_REPO_ROOT/vz/development/probes/netrb_native_interface_probe.c"
PLIST="$VZ_REPO_ROOT/vz/development/probes/netrb-native-probe-launchd.plist"
ENTS="$VZ_REPO_ROOT/vz/development/probes/netrb-native-probe.ents.xml"
OUT="$VZ_BUILD_ROOT/probes/netrb-native-interface-probe"
need_command ldid
need_command xcrun
need_file "$SOURCE"
need_file "$PLIST"
need_file "$ENTS"
mkdir -p "$(dirname "$OUT")"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 \
    -isysroot "$SDK" -fblocks -Wl,-undefined,dynamic_lookup \
    "$SOURCE" -o "$OUT"
ldid -S"$ENTS" "$OUT"
ensure_ipad_usb
ipad_scp "$OUT" "$IPAD_TARGET:/tmp/netrb-native-interface-probe"
ipad_scp "$PLIST" "$IPAD_TARGET:/tmp/netrb-native-probe.plist"
hash="$(ldid -h "$OUT" | sed -n 's/^CDHash=//p')"
ipad_ssh "
set -eu
mkdir -p /var/jb/usr/local/bin /var/jb/Library/LaunchDaemons
/var/jb/usr/bin/launchctl bootout \
  user/501/com.mac.virtual.netrb-native-probe 2>/dev/null || true
install -o root -g wheel -m 755 /tmp/netrb-native-interface-probe \
  /var/jb/usr/local/bin/netrb-native-interface-probe
install -o root -g wheel -m 644 /tmp/netrb-native-probe.plist \
  /var/jb/Library/LaunchDaemons/netrb-native-probe.plist
rm -f /tmp/netrb-native-interface-probe /tmp/netrb-native-probe.plist \
  /tmp/netrb-native-interface-probe.log
jbctl trustcache add '$hash'
/var/jb/usr/bin/launchctl bootstrap user/501 \
  /var/jb/Library/LaunchDaemons/netrb-native-probe.plist
i=0
probe_status=
while test "\$i" -lt 20; do
  job_output=\$(/var/jb/usr/bin/launchctl print \
    user/501/com.mac.virtual.netrb-native-probe 2>/dev/null || true)
  probe_status=\$(printf '%s\n' "\$job_output" | \
    sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\)$/\1/p' | \
    tail -1)
  test -z "\$probe_status" || break
  i=\$((i + 1))
  sleep 1
done
cat /tmp/netrb-native-interface-probe.log 2>/dev/null || true
test -n "\$probe_status" || exit 124
exit "\$probe_status"
"
