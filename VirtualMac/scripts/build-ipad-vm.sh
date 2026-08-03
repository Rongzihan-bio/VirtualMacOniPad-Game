#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-vm"
PAYLOAD="$OUT/payload"
BIN="$PAYLOAD/bin"
FRAMEWORKS="$PAYLOAD/Frameworks"
VMM="$PAYLOAD/VirtualMachine.xpc"
VMM_BIN="$VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
# The host and VMM are separate processes, but dyld can load both from this
# shared runtime directory. Keep XPC-private compatibility dylibs here too so
# the package has one authoritative framework location.
VMM_FRAMEWORKS="$FRAMEWORKS"
SOURCE_VZ="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/Frameworks/Virtualization.framework/Versions/A"
SOURCE_VMM="$SOURCE_VZ/XPCServices/com.apple.Virtualization.VirtualMachine.xpc"
IOS_FRAMEWORKS="$VZ_BUILD_ROOT/frameworks/bundles/ios"
ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"
VMM_ENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"
VMM_OPTIONAL_DEVICES_PATCH="$VZ_REPO_ROOT/vz/patches/patch_vmm_optional_devices.py"
VMM_PCI_ADDRESS_PATCH="$VZ_REPO_ROOT/vz/patches/patch_vmm_pci_address.py"
PVG_EXCEPTION_LOG_PATCH="$VZ_REPO_ROOT/vz/patches/patch_pvg_exception_log.py"
MACHO_CSTRING_PATCH="$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py"
METAL_SERIALIZER_FRAMEWORK="$IOS_FRAMEWORKS/MetalSerializer.framework"
VMNET_FRAMEWORK="$VZ_BUILD_ROOT/ipad-vmnet/vmnet.framework"
NETRB_FRAMEWORK="$VZ_BUILD_ROOT/ipad-netrb/Netrb.framework"
VIDEOTOOLBOX_FRAMEWORK="$VZ_BUILD_ROOT/ipad-videotoolbox/VideoToolbox.framework"
ENTITLEMENT_AUDIT="$VZ_REPO_ROOT/scripts/audit-entitlements.py"

need_command codesign
need_command ditto
need_command install_name_tool
need_command ldid
need_command lipo
need_command otool
need_command xcrun
need_file "$SOURCE_VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
need_file "$SOURCE_VZ/Resources/AVPBooter.vmapple2.bin"
need_file "$ENTS"
need_file "$VMM_ENTS"
need_file "$VMM_OPTIONAL_DEVICES_PATCH"
need_file "$VMM_PCI_ADDRESS_PATCH"
need_file "$PVG_EXCEPTION_LOG_PATCH"
need_file "$MACHO_CSTRING_PATCH"
need_file "$ENTITLEMENT_AUDIT"
need_file "$METAL_SERIALIZER_FRAMEWORK/Versions/A/MetalSerializer"
need_file "$VZ_REPO_ROOT/vz/host/pvg_trace.m"
need_file "$VZ_REPO_ROOT/vz/shaders/pvg_display.metal"
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    need_file "$IOS_FRAMEWORKS/$name.framework/Versions/A/$name"
done

"$SCRIPT_DIR/build-ipad-vmnet.sh"
"$SCRIPT_DIR/build-ipad-netrb.sh"
"$SCRIPT_DIR/build-ipad-videotoolbox.sh"
need_file "$VMNET_FRAMEWORK/vmnet"
need_file "$NETRB_FRAMEWORK/Netrb"
need_file "$VIDEOTOOLBOX_FRAMEWORK/VideoToolbox"

rm -rf "$PAYLOAD"
mkdir -p "$BIN" "$FRAMEWORKS"
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    ditto "$IOS_FRAMEWORKS/$name.framework" \
        "$FRAMEWORKS/$name.framework"
done
ditto "$VMNET_FRAMEWORK" "$FRAMEWORKS/vmnet.framework"
HOST_VZ_BINARY="$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" "$HOST_VZ_BINARY" \
    /System/Library/Frameworks/vmnet.framework/vmnet \
    @loader_path/../../../vmnet.framework/vmnet
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$FRAMEWORKS/Virtualization.framework"
ditto "$SOURCE_VMM" "$VMM"
rm -rf "$VMM/Contents/_CodeSignature" "$VMM/Contents/Frameworks"
/usr/libexec/PlistBuddy -c \
    "Add :NSMicrophoneUsageDescription string Virtual Mac microphone input" \
    "$VMM/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c \
        "Set :NSMicrophoneUsageDescription Virtual Mac microphone input" \
        "$VMM/Contents/Info.plist"
mkdir -p "$VMM_FRAMEWORKS"
lipo -thin arm64e \
    "$SOURCE_VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine" \
    -output "$VMM_BIN"
ditto "$NETRB_FRAMEWORK" "$VMM_FRAMEWORKS/Netrb.framework"
ditto "$VIDEOTOOLBOX_FRAMEWORK" \
    "$VMM_FRAMEWORKS/VideoToolbox.framework"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" \
    "$VMM_FRAMEWORKS/vmnet.framework/vmnet" \
    /System/Library/PrivateFrameworks/Netrb.framework/Netrb \
    @loader_path/../Netrb.framework/Netrb
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$VMM_FRAMEWORKS/vmnet.framework/vmnet"
ditto "$METAL_SERIALIZER_FRAMEWORK" \
    "$VMM_FRAMEWORKS/MetalSerializer.framework"
METAL_SERIALIZER_FRAMEWORK="$VMM_FRAMEWORKS/MetalSerializer.framework"
METAL_SERIALIZER_BINARY="$METAL_SERIALIZER_FRAMEWORK/Versions/A/MetalSerializer"

PVG_BINARY="$VMM_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" "$PVG_BINARY" \
    /System/Library/PrivateFrameworks/MetalSerializer.framework/MetalSerializer \
    @loader_path/../../../MetalSerializer.framework/MetalSerializer
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$PVG_EXCEPTION_LOG_PATCH" "$PVG_BINARY"

PVG_RESOURCES="$VMM_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/Resources"
cp "$PVG_RESOURCES/default.metallib" \
    "$PVG_RESOURCES/default.macos.metallib"
xcrun --sdk iphoneos metal \
    -std=metal3.0 -mios-version-min=16.0 -ffast-math \
    -c "$VZ_REPO_ROOT/vz/shaders/pvg_display.metal" \
    -o "$OUT/pvg_display.air"
xcrun --sdk iphoneos metallib \
    "$OUT/pvg_display.air" \
    -o "$PVG_RESOURCES/default.metallib"

xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" -fblocks \
    -framework Foundation \
    "$VZ_REPO_ROOT/vz/host/vzboot.m" \
    -o "$BIN/vzboot"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -framework Foundation -framework Metal -framework UIKit \
    -Wl,-export_dynamic \
    "$VZ_REPO_ROOT/vz/host/NSViewShim.m" \
    "$VZ_REPO_ROOT/vz/development/probes/objc_methods.m" \
    -o "$BIN/objc-methods"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -install_name "@rpath/VZHostCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/vzxpchook.m" \
    -o "$BIN/VZHostCompat.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib \
    -framework Foundation -framework Metal \
    -Wl,-reexport_framework,Metal \
    -install_name "@rpath/MetalCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/metalshim.m" \
    -o "$VMM_FRAMEWORKS/MetalCompat.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework AVFAudio \
    -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name "@rpath/LaunchServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/lsshim.m" \
    "$VZ_REPO_ROOT/vz/host/vmmhook.m" \
    "$VZ_REPO_ROOT/vz/host/pvg_trace.m" \
    -o "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib"

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/stamp_ios.py" "$VMM_BIN" "$VMM_BIN.ios" 16.0
mv -f "$VMM_BIN.ios" "$VMM_BIN"

install_name_tool \
    -change \
    /System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia \
    /System/Library/Frameworks/CoreMedia.framework/CoreMedia \
    -change \
    /System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor \
    @loader_path/../../../Frameworks/Hypervisor.framework/Hypervisor \
    -change \
    /System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics \
    @loader_path/../../../Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics \
    -change \
    /System/Library/Frameworks/Metal.framework/Versions/A/Metal \
    @loader_path/../../../Frameworks/MetalCompat.dylib \
    -change \
    /System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices \
    @loader_path/../../../Frameworks/LaunchServicesCompat.dylib \
    -change \
    /System/Library/Frameworks/vmnet.framework/Versions/A/vmnet \
    @loader_path/../../../Frameworks/vmnet.framework/vmnet \
    -change \
    /System/Library/PrivateFrameworks/ParavirtualizedANE.framework/Versions/A/ParavirtualizedANE \
    /System/Library/PrivateFrameworks/ParavirtualizedANE.framework/ParavirtualizedANE \
    -change \
    /System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/ExtensionFoundation \
    /System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation \
    -change \
    /System/Library/Frameworks/Security.framework/Versions/A/Security \
    /System/Library/Frameworks/Security.framework/Security \
    -change \
    /System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox \
    @loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox \
    -change \
    /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    /System/Library/Frameworks/Foundation.framework/Foundation \
    -change \
    /System/Library/Frameworks/AudioToolbox.framework/Versions/A/AudioToolbox \
    /System/Library/Frameworks/AudioToolbox.framework/AudioToolbox \
    -change \
    /System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio \
    /System/Library/Frameworks/CoreAudio.framework/CoreAudio \
    -change \
    /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change \
    /System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics \
    /System/Library/Frameworks/CoreGraphics.framework/CoreGraphics \
    -change \
    /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    -change \
    /System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface \
    /System/Library/Frameworks/IOSurface.framework/IOSurface \
    -change \
    /System/Library/Frameworks/IOUSBHost.framework/Versions/A/IOUSBHost \
    /System/Library/PrivateFrameworks/IOUSBHost.framework/IOUSBHost \
    -change \
    /System/Library/PrivateFrameworks/DiskImages2.framework/Versions/A/DiskImages2 \
    /System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2 \
    "$VMM_BIN"

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VMM_OPTIONAL_DEVICES_PATCH" "$VMM_BIN"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VMM_PCI_ADDRESS_PATCH" "$VMM_BIN"

ldid -S"$ENTS" "$BIN/vzboot"
ldid -S"$ENTS" "$BIN/objc-methods"
ldid -S"$ENTS" "$BIN/VZHostCompat.dylib"
for dylib in \
    "$VMM_FRAMEWORKS/MetalCompat.dylib" \
    "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib"; do
    ldid -S"$VMM_ENTS" "$dylib"
done
codesign --verify "$VMM_FRAMEWORKS/vmnet.framework/vmnet"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$METAL_SERIALIZER_FRAMEWORK"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime "$PVG_BINARY"
ldid -S"$VMM_ENTS" "$VMM_BIN"

# Finder and BridgeSupport metadata from the extracted frameworks are not
# used by the Objective-C runtime. Remove them before resealing every
# structured framework whose resource envelope may have referenced them.
find "$PAYLOAD" -type f \( -name .DS_Store -o -name '._*' \) -delete
find "$FRAMEWORKS" -type d -name BridgeSupport -prune \
    -exec rm -rf {} +
for framework in \
    "$FRAMEWORKS/Hypervisor.framework" \
    "$FRAMEWORKS/ParavirtualizedGraphics.framework" \
    "$FRAMEWORKS/Virtualization.framework" \
    "$FRAMEWORKS/MetalSerializer.framework"; do
    codesign --force --sign - \
        --preserve-metadata=entitlements,requirements,flags,runtime \
        "$framework"
    codesign --verify --deep --strict "$framework"
done

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" "$ENTITLEMENT_AUDIT" \
    "$ENTS" "$BIN/vzboot" \
    "$ENTS" "$BIN/objc-methods" \
    "$ENTS" "$BIN/VZHostCompat.dylib" \
    "$VMM_ENTS" "$VMM_BIN" \
    "$VMM_ENTS" "$VMM_FRAMEWORKS/MetalCompat.dylib" \
    "$VMM_ENTS" "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib" \
    - "$FRAMEWORKS/Hypervisor.framework/Versions/A/Hypervisor" \
    - "$FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics" \
    - "$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization" \
    - "$VMM_FRAMEWORKS/vmnet.framework/vmnet" \
    - "$VMM_FRAMEWORKS/Netrb.framework/Netrb" \
    - "$METAL_SERIALIZER_BINARY" \
    - "$VMM_FRAMEWORKS/VideoToolbox.framework/VideoToolbox"

otool -l "$VMM_BIN" | grep -q "LC_DYLD_CHAINED_FIXUPS" ||
    die "VMM lost LC_DYLD_CHAINED_FIXUPS"
otool -l "$VMM_BIN" |
    awk '/LC_BUILD_VERSION/{show=1; left=7} show && left-- > 0 {print}' |
    grep -q "platform 2" ||
    die "VMM is not stamped for iOS"
for dependency in \
    "@loader_path/../../../Frameworks/Hypervisor.framework/Hypervisor" \
    "@loader_path/../../../Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics" \
    "@loader_path/../../../Frameworks/MetalCompat.dylib" \
    "@loader_path/../../../Frameworks/LaunchServicesCompat.dylib" \
    "@loader_path/../../../Frameworks/vmnet.framework/vmnet" \
    "@loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox"; do
    otool -L "$VMM_BIN" | grep -Fq "$dependency" ||
        die "VMM is missing dependency: $dependency"
done
otool -L "$VMM_FRAMEWORKS/vmnet.framework/vmnet" | grep -Fq \
    "@loader_path/../Netrb.framework/Netrb" ||
    die "VMM vmnet is missing its patched Netrb dependency"

{
    files=(
        "$BIN/vzboot"
        "$BIN/objc-methods"
        "$BIN/VZHostCompat.dylib"
        "$VMM_BIN"
        "$VMM_FRAMEWORKS/MetalCompat.dylib"
        "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib"
        "$VMM_FRAMEWORKS/vmnet.framework/vmnet"
        "$VMM_FRAMEWORKS/Netrb.framework/Netrb"
        "$METAL_SERIALIZER_BINARY"
        "$VMM_FRAMEWORKS/VideoToolbox.framework/VideoToolbox"
        "$FRAMEWORKS/Hypervisor.framework/Versions/A/Hypervisor"
        "$FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
        "$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization"
    )
    for file in "${files[@]}"; do
        printf '%s\t%s\n' \
            "$(ldid -h "$file" | sed -n 's/^CDHash=//p')" \
            "${file#"$PAYLOAD/"}"
    done
} >"$PAYLOAD/trustcache.txt"

echo "iPad VM payload built with unavailable host devices optional and without validator/registry/PAC bypasses: $PAYLOAD"
