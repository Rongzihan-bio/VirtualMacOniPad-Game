#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUT="$VZ_BUILD_ROOT/ipad-installation"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
ARCHIVE="$(mktemp -t VirtualMac-installation.XXXXXX.tar.gz)"
trap 'rm -f "$ARCHIVE"' EXIT

need_command ldid
need_command tar
need_file "$OUT/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
need_file "$OUT/install/VZHostCompat.dylib"
need_file "$OUT/install/restore-image-probe"
need_file "$OUT/install/install-macos"
need_file "$OUT/install/start-install.sh"
need_file "$OUT/install/install-launcher"
need_file "$OUT/install/usb-bridge-probe"
need_file "$OUT/payload/Frameworks/LaunchServicesCompat.dylib"
need_file "$OUT/trustcache.txt"

tar -C "$OUT" -czf "$ARCHIVE" payload install trustcache.txt manifest.txt
ensure_ipad_usb
ipad_scp "$ARCHIVE" "$IPAD_TARGET:/tmp/vz-installation.tar.gz"

ipad_ssh "
set -eu
killall restore-image-probe 2>/dev/null || true
ps -axo pid=,command= | while read -r stale_pid stale_command; do
  case "\$stale_command" in
    '$REMOTE/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation')
      kill -9 "\$stale_pid" 2>/dev/null || true
      ;;
  esac
done
launchctl bootout system/com.mac.virtual.installer 2>/dev/null || true
rm -f /var/jb/Library/LaunchDaemons/com.mac.virtual.installer.plist
rm -rf '$REMOTE/payload/Installation.xpc' '$REMOTE/install'
mkdir -p '$REMOTE'
tar -xzf /tmp/vz-installation.tar.gz -C '$REMOTE'
rm -f /tmp/vz-installation.tar.gz
chmod 755 \
  '$REMOTE/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation' \
  '$REMOTE/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib' \
  '$REMOTE/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd' \
  '$REMOTE/payload/Frameworks/LaunchServicesCompat.dylib' \
  '$REMOTE/install/VZHostCompat.dylib' \
  '$REMOTE/install/restore-image-probe' \
  '$REMOTE/install/install-macos' \
  '$REMOTE/install/usb-bridge-probe'
chmod 755 '$REMOTE/install/start-install.sh'
chown root:wheel '$REMOTE/install/install-launcher'
chmod 4755 '$REMOTE/install/install-launcher'
PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
for utility in cat rm killall grep sleep touch ln; do
  command -v "\$utility" >/dev/null
done
while IFS=\$(printf '\\t') read -r hash file; do
  test -n \"\$hash\"
  test -f '$REMOTE/'\"\$file\"
  jbctl trustcache add \"\$hash\"
done <'$REMOTE/trustcache.txt'
rm -f /tmp/installation_ep.txt /tmp/installation.stderr.log \
  /tmp/restore-vmm.stderr.log \
  /tmp/installationhook.log /tmp/restore-image-probe.log
echo INSTALLATION_DEPLOYED
cat '$REMOTE/manifest.txt'
"
