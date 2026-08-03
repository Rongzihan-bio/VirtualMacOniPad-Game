#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command ditto
need_command dpkg-deb
need_command file
need_command ldid
need_command rsync
need_command xattr

if [[ "${VZ_SKIP_REBUILD:-0}" != 1 ]]; then
    "$SCRIPT_DIR/build-ipad-vm.sh"
    "$SCRIPT_DIR/build-ipad-network-helpers.sh"
    "$SCRIPT_DIR/build-ipad-network-sharing.sh"
    "$SCRIPT_DIR/build-ipad-installation.sh"
    "$SCRIPT_DIR/build-ipad-app.sh"
    "$SCRIPT_DIR/build-springboard-tweak.sh"
fi
"$SCRIPT_DIR/audit-ipados-compatibility.sh"

commit_count="$(git -C "$VZ_REPO_ROOT" rev-list --count HEAD)"
commit_hash="$(git -C "$VZ_REPO_ROOT" rev-parse --short=10 HEAD)"
RELEASE_VERSION="${VZ_RELEASE_VERSION:-1.0}"
if [[ -n "${VZ_PACKAGE_VERSION:-}" ]]; then
    VERSION="$VZ_PACKAGE_VERSION"
else
    # Epoch 1 supersedes the early hash-only development packages.  Commit
    # count supplies monotonic Debian ordering; the hash keeps provenance.
    VERSION="1:${RELEASE_VERSION}+git${commit_count}.${commit_hash}"
fi
PACKAGE_NAME="VirtualMac_${RELEASE_VERSION}_${commit_hash}.deb"
RELEASE="$VZ_BUILD_ROOT/release"
STAGE="$(mktemp -d -t VirtualMac-deb.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# mktemp intentionally creates a private 0700 directory.  A package archive
# must not carry that mode on its `./` entry: dpkg may otherwise try to apply
# it to the filesystem root while unpacking.  All payload parents are public
# system directories, so normalize the staging root before creating them.
chmod 755 "$STAGE"

mkdir -p \
    "$STAGE/DEBIAN" \
    "$STAGE/var/root/VirtualMac" \
    "$STAGE/var/jb/Applications" \
    "$STAGE/var/jb/Library/LaunchDaemons" \
    "$STAGE/var/jb/basebin/LaunchDaemons" \
    "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries" \
    "$STAGE/var/jb/usr/lib" \
    "$STAGE/var/jb/usr/libexec" \
    "$STAGE/var/jb/usr/sbin" \
    "$STAGE/var/jb/usr/share/VirtualMac" \
    "$RELEASE"

ditto "$VZ_BUILD_ROOT/ipad-vm/payload" \
    "$STAGE/var/root/VirtualMac/payload"
ditto "$VZ_BUILD_ROOT/ipad-installation/payload" \
    "$STAGE/var/root/VirtualMac/payload"
ditto "$VZ_BUILD_ROOT/ipad-installation/install" \
    "$STAGE/var/root/VirtualMac/install"
ditto "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app" \
    "$STAGE/var/jb/Applications/VirtualMac.app"

# The component builds retain command-line probes for developer iteration.
# They are not used by the app and do not belong in the end-user package.
rm -rf "$STAGE/var/root/VirtualMac/payload/bin"
rm -f \
    "$STAGE/var/root/VirtualMac/payload/trustcache.txt" \
    "$STAGE/var/root/VirtualMac/install/restore-image-probe" \
    "$STAGE/var/root/VirtualMac/install/usb-bridge-probe"

install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing" \
    "$STAGE/var/jb/usr/libexec/InternetSharing"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/AuthorizationCompat.dylib" \
    "$STAGE/var/jb/usr/lib/AuthorizationCompat.dylib"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/bootpd" \
    "$STAGE/var/jb/usr/libexec/bootpd"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/rtadvd" \
    "$STAGE/var/jb/usr/sbin/rtadvd"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/OpenDirectoryCompat.dylib" \
    "$STAGE/var/jb/usr/lib/OpenDirectoryCompat.dylib"
install -m 644 "$VZ_BUILD_ROOT/ipad-network-helpers/com.apple.bootpd.plist" \
    "$STAGE/var/jb/Library/LaunchDaemons/com.apple.bootpd.plist"
# This is an intentional mirror, not a second runtime payload: postinst uses
# Library/LaunchDaemons for the immediate user-domain bootstrap, while
# Dopamine's launchd hook discovers basebin/LaunchDaemons across a userspace
# reboot. Both entries must describe the same daemon.
for destination in \
    "$STAGE/var/jb/Library/LaunchDaemons/com.apple.NetworkSharing.plist" \
    "$STAGE/var/jb/basebin/LaunchDaemons/com.apple.NetworkSharing.plist"; do
    install -m 644 "$VZ_BUILD_ROOT/ipad-network-sharing/com.apple.NetworkSharing.plist" \
        "$destination"
done
install -m 755 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.dylib" \
    "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.dylib"
install -m 644 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.plist" \
    "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.plist"

# Never package host filesystem metadata. Component builders also remove it
# before signing, but this catches metadata from every independently built
# app, XPC, framework, and packaging input.
find "$STAGE" -type f \( -name .DS_Store -o -name '._*' \) -delete
xattr -cr "$STAGE"

trustcache="$STAGE/var/jb/usr/share/VirtualMac/trustcache.txt"
: >"$trustcache"
while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    hash="$(ldid -h "$candidate" | sed -n 's/^CDHash=//p')"
    [[ -n "$hash" ]] || die "could not read CDHash: $candidate"
    printf '%s\t/%s\n' "$hash" "${candidate#"$STAGE/"}" >>"$trustcache"
done < <(find "$STAGE" -type f -print0)

rsync -a "$VZ_REPO_ROOT/packaging/DEBIAN/" "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst" \
    "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 4755 "$STAGE/var/root/VirtualMac/install/install-launcher"
"$SCRIPT_DIR/audit-ipad-package-stage.sh" "$STAGE"
installed_size="$(du -sk "$STAGE" | awk '{print $1}')"
sed -i '' -e "s/@VERSION@/$VERSION/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" "$STAGE/DEBIAN/control"

dpkg-deb --root-owner-group --build "$STAGE" "$RELEASE/$PACKAGE_NAME"
dpkg-deb --info "$RELEASE/$PACKAGE_NAME"
echo "standalone package built: $RELEASE/$PACKAGE_NAME"
