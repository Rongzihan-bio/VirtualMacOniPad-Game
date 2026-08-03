#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUT="$VZ_BUILD_ROOT/ipad-network-sharing"
BIN="$OUT/InternetSharing"
PLIST="$OUT/com.apple.NetworkSharing.plist"
AUTH_COMPAT="$OUT/AuthorizationCompat.dylib"
HELPERS="$VZ_BUILD_ROOT/ipad-network-helpers"
BOOTPD="$HELPERS/bootpd"
RTADVD="$HELPERS/rtadvd"
OD_COMPAT="$HELPERS/OpenDirectoryCompat.dylib"
BOOTPD_PLIST="$HELPERS/com.apple.bootpd.plist"
LAUNCH_DOMAIN="${VZ_NETWORK_SHARING_DOMAIN:-user/501}"
BOOTPD_DOMAIN="${VZ_BOOTPD_DOMAIN:-$LAUNCH_DOMAIN}"

need_command ldid
need_file "$BIN"
need_file "$PLIST"
need_file "$AUTH_COMPAT"
need_file "$BOOTPD"
need_file "$RTADVD"
need_file "$OD_COMPAT"
need_file "$BOOTPD_PLIST"
ensure_ipad_usb
ipad_scp "$BIN" "$IPAD_TARGET:/tmp/InternetSharing"
ipad_scp "$PLIST" "$IPAD_TARGET:/tmp/com.apple.NetworkSharing.plist"
ipad_scp "$AUTH_COMPAT" "$IPAD_TARGET:/tmp/AuthorizationCompat.dylib"
ipad_scp "$BOOTPD" "$IPAD_TARGET:/tmp/bootpd"
ipad_scp "$RTADVD" "$IPAD_TARGET:/tmp/rtadvd"
ipad_scp "$OD_COMPAT" "$IPAD_TARGET:/tmp/OpenDirectoryCompat.dylib"
ipad_scp "$BOOTPD_PLIST" "$IPAD_TARGET:/tmp/com.apple.bootpd.plist"

hash="$(ldid -h "$BIN" | sed -n 's/^CDHash=//p')"
compat_hash="$(ldid -h "$AUTH_COMPAT" | sed -n 's/^CDHash=//p')"
bootpd_hash="$(ldid -h "$BOOTPD" | sed -n 's/^CDHash=//p')"
rtadvd_hash="$(ldid -h "$RTADVD" | sed -n 's/^CDHash=//p')"
od_compat_hash="$(ldid -h "$OD_COMPAT" | sed -n 's/^CDHash=//p')"
ipad_ssh "
set -eu
mkdir -p /var/jb/usr/lib /var/jb/usr/libexec /var/jb/usr/sbin \
  /var/jb/Library/LaunchDaemons /var/jb/basebin/LaunchDaemons
/var/jb/usr/bin/launchctl bootout system/com.apple.bootpd \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout user/501/com.apple.bootpd \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout system/vzi.apple.bootpd \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout user/501/vzi.apple.bootpd \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout system/com.apple.NetworkSharing \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout user/501/com.apple.NetworkSharing \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout system/com.mac.virtual.NetworkSharing \
  2>/dev/null || true
/var/jb/usr/bin/launchctl bootout user/501/com.mac.virtual.NetworkSharing \
  2>/dev/null || true
install -o root -g wheel -m 755 /tmp/InternetSharing \
  /var/jb/usr/libexec/InternetSharing
install -o root -g wheel -m 755 /tmp/AuthorizationCompat.dylib \
  /var/jb/usr/lib/AuthorizationCompat.dylib
install -o root -g wheel -m 755 /tmp/bootpd \
  /var/jb/usr/libexec/bootpd
install -o root -g wheel -m 755 /tmp/rtadvd \
  /var/jb/usr/sbin/rtadvd
install -o root -g wheel -m 755 /tmp/OpenDirectoryCompat.dylib \
  /var/jb/usr/lib/OpenDirectoryCompat.dylib
install -o root -g wheel -m 644 /tmp/com.apple.bootpd.plist \
  /var/jb/Library/LaunchDaemons/com.apple.bootpd.plist
# Ventura bootpd creates and updates this file but expects its parent and the
# initial file to be writable. The iPad data volume provides /var/db; seed the
# file without truncating an existing lease database.
touch /var/db/dhcpd_leases
chown root:wheel /var/db/dhcpd_leases
chmod 644 /var/db/dhcpd_leases
install -o root -g wheel -m 644 /tmp/com.apple.NetworkSharing.plist \
  /var/jb/Library/LaunchDaemons/com.apple.NetworkSharing.plist
install -o root -g wheel -m 644 /tmp/com.apple.NetworkSharing.plist \
  /var/jb/basebin/LaunchDaemons/com.apple.NetworkSharing.plist
rm -f /tmp/InternetSharing /tmp/AuthorizationCompat.dylib /tmp/bootpd \
  /tmp/rtadvd /tmp/OpenDirectoryCompat.dylib /tmp/com.apple.bootpd.plist \
  /tmp/com.apple.NetworkSharing.plist
jbctl trustcache add '$hash'
jbctl trustcache add '$compat_hash'
jbctl trustcache add '$bootpd_hash'
jbctl trustcache add '$rtadvd_hash'
jbctl trustcache add '$od_compat_hash'
/var/jb/usr/bin/launchctl enable '$BOOTPD_DOMAIN/vzi.apple.bootpd'
/var/jb/usr/bin/launchctl bootstrap '$BOOTPD_DOMAIN' \
  /var/jb/Library/LaunchDaemons/com.apple.bootpd.plist
/var/jb/usr/bin/launchctl bootstrap '$LAUNCH_DOMAIN' \
  /var/jb/Library/LaunchDaemons/com.apple.NetworkSharing.plist
/var/jb/usr/bin/launchctl kickstart -k \
  '$LAUNCH_DOMAIN/com.apple.NetworkSharing'
/var/jb/usr/bin/launchctl print '$LAUNCH_DOMAIN/com.apple.NetworkSharing'
"
