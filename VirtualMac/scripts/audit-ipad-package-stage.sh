#!/bin/bash

set -euo pipefail

STAGE="${1:-}"
[[ -n "$STAGE" && -d "$STAGE" ]] || {
    echo "usage: $0 <deb-stage-directory>" >&2
    exit 2
}

RUNTIME="$STAGE/var/root/VirtualMac"
PAYLOAD="$RUNTIME/payload"
FRAMEWORKS="$PAYLOAD/Frameworks"
VMM="$PAYLOAD/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

die() {
    echo "package audit failed: $*" >&2
    exit 1
}

for binary in \
    "$FRAMEWORKS/Hypervisor.framework/Hypervisor" \
    "$FRAMEWORKS/ParavirtualizedGraphics.framework/ParavirtualizedGraphics" \
    "$FRAMEWORKS/Virtualization.framework/Virtualization" \
    "$FRAMEWORKS/vmnet.framework/vmnet" \
    "$FRAMEWORKS/Netrb.framework/Netrb" \
    "$FRAMEWORKS/VideoToolbox.framework/VideoToolbox" \
    "$FRAMEWORKS/MetalSerializer.framework/MetalSerializer" \
    "$FRAMEWORKS/MetalCompat.dylib" \
    "$FRAMEWORKS/LaunchServicesCompat.dylib" \
    "$FRAMEWORKS/Virtualization.framework/Resources/AVPBooter.vmapple2.bin" \
    "$VMM"; do
    [[ -f "$binary" ]] || die "missing runtime file: ${binary#"$STAGE/"}"
done

[[ ! -e "$PAYLOAD/VirtualMachine.xpc/Contents/Frameworks" ]] ||
    die "VirtualMachine.xpc contains a second framework tree"
[[ ! -e "$PAYLOAD/AVPBooter.vmapple2.bin" ]] ||
    die "AVPBooter duplicates the Virtualization framework resource"

for development_file in \
    "$PAYLOAD/bin" \
    "$PAYLOAD/trustcache.txt" \
    "$RUNTIME/install/restore-image-probe" \
    "$RUNTIME/install/usb-bridge-probe" \
    "$STAGE/var/jb/usr/share/VirtualMac/VM-LIBRARY-README.md"; do
    [[ ! -e "$development_file" ]] ||
        die "development-only file was packaged: ${development_file#"$STAGE/"}"
done

metadata="$(find "$STAGE" -type f \( -name .DS_Store -o -name '._*' \) -print -quit)"
[[ -z "$metadata" ]] || die "host metadata was packaged: ${metadata#"$STAGE/"}"
extended_attribute="$(xattr -lr "$STAGE" 2>/dev/null | head -1)"
[[ -z "$extended_attribute" ]] ||
    die "extended attribute was packaged: $extended_attribute"
bridge_support="$(find "$FRAMEWORKS" -type d -name BridgeSupport -print -quit)"
[[ -z "$bridge_support" ]] ||
    die "developer-only BridgeSupport metadata was packaged: ${bridge_support#"$STAGE/"}"

broken_link="$(find -L "$STAGE" -type l -print -quit)"
[[ -z "$broken_link" ]] || die "broken symlink: ${broken_link#"$STAGE/"}"

unexpected_framework=""
while IFS= read -r framework; do
    case "$framework" in
        "$FRAMEWORKS"/*|"$PAYLOAD/Installation.xpc/Contents/Frameworks"/*) ;;
        *) unexpected_framework="$framework"; break ;;
    esac
done < <(find "$PAYLOAD" -type d -name '*.framework' -print)
[[ -z "$unexpected_framework" ]] ||
    die "framework outside an authoritative dependency directory: ${unexpected_framework#"$STAGE/"}"

if otool -L "$VMM" | grep -Fq '@loader_path/../Frameworks/'; then
    die "VMM still references its removed nested framework directory"
fi
for dependency in \
    '@loader_path/../../../Frameworks/Hypervisor.framework/Hypervisor' \
    '@loader_path/../../../Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics' \
    '@loader_path/../../../Frameworks/MetalCompat.dylib' \
    '@loader_path/../../../Frameworks/LaunchServicesCompat.dylib' \
    '@loader_path/../../../Frameworks/vmnet.framework/vmnet' \
    '@loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox'; do
    otool -L "$VMM" | grep -Fq "$dependency" ||
        die "VMM is missing shared dependency: $dependency"
done

echo "package stage audit passed: one shared VM framework tree, XPC installs dependencies only"
