#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUT="$VZ_BUILD_ROOT/ipad-installation"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
ARCHIVE="$(mktemp -t VirtualMac-installation.XXXXXX.tar)"
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
need_file "$OUT/trustcache.txt"

tar -C "$OUT" -cf "$ARCHIVE" payload/Installation.xpc install \
    trustcache.txt manifest.txt
ensure_ipad_usb
ipad_scp "$ARCHIVE" "$IPAD_TARGET:/tmp/vz-installation.tar"

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
tar -xf /tmp/vz-installation.tar -C '$REMOTE'
rm -f /tmp/vz-installation.tar
replace_file() {
  source_path="\$1"
  destination_path="\$2"
  cp "\$source_path" "\$destination_path.virtualmac-new"
  chmod 755 "\$destination_path.virtualmac-new"
  mv -f "\$destination_path.virtualmac-new" "\$destination_path"
}
host_version=\$(sw_vers -productVersion)
installation_macos='$REMOTE/payload/Installation.xpc/Contents/MacOS'
installation_frameworks='$REMOTE/payload/Installation.xpc/Contents/Frameworks'
installation_variant="\$installation_macos/com.apple.Virtualization.Installation.ipados16"
compat_variant="\$installation_frameworks/InstallationCompat.dylib.ipados16"
mobile_device_dir="\$installation_frameworks/MobileDevice.framework/Versions/A"
mobile_device_variant="\$mobile_device_dir/MobileDevice.ipados16"
case "\$host_version" in
  14.*)
    installation_variant="\$installation_macos/com.apple.Virtualization.Installation.ipados14"
    compat_variant="\$installation_frameworks/InstallationCompat.dylib.ipados14"
    mobile_device_variant="\$mobile_device_dir/MobileDevice.ipados14"
    ;;
  15.*)
    installation_variant="\$installation_macos/com.apple.Virtualization.Installation.ipados15"
    compat_variant="\$installation_frameworks/InstallationCompat.dylib.ipados15"
    mobile_device_variant="\$mobile_device_dir/MobileDevice.ipados15"
    ;;
esac
replace_file "\$installation_variant" \
  "\$installation_macos/com.apple.Virtualization.Installation"
replace_file "\$compat_variant" \
  "\$installation_frameworks/InstallationCompat.dylib"
replace_file "\$mobile_device_variant" "\$mobile_device_dir/MobileDevice"
chmod 755 \
  '$REMOTE/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation' \
  '$REMOTE/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib' \
  '$REMOTE/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd' \
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
if command -v jbctl >/dev/null 2>&1; then
  while IFS=\$(printf '\\t') read -r hash file; do
    test -n \"\$hash\"
    test -f '$REMOTE/'\"\$file\"
    jbctl trustcache add \"\$hash\"
  done <'$REMOTE/trustcache.txt'
elif test -x /taurine/jbexec; then
  while IFS=\$(printf '\\t') read -r hash file; do
    target='$REMOTE/'\"\$file\"
    test -f \"\$target\" || continue
    PREFLIGHT=1 /bin/bash -c \
      'exec -a \"\$1\" /taurine/jbexec' _ \"\$target\" >/dev/null || true
  done <'$REMOTE/trustcache.txt'
fi
rm -f /tmp/installation_ep.txt /tmp/installation.stderr.log \
  /tmp/restore-vmm.stderr.log \
  /tmp/installationhook.log /tmp/restore-image-probe.log
echo INSTALLATION_DEPLOYED
cat '$REMOTE/manifest.txt'
"
