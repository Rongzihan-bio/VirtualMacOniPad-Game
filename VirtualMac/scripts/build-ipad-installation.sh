#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SOURCE_VZ="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/Frameworks/Virtualization.framework/Versions/A"
SOURCE_XPC="$SOURCE_VZ/XPCServices/com.apple.Virtualization.Installation.xpc"
OUT="$VZ_BUILD_ROOT/ipad-installation"
PAYLOAD="$OUT/payload"
VMM_COMPAT_SOURCE="$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/LaunchServicesCompat.dylib"
VMM_COMPAT="$PAYLOAD/Frameworks/LaunchServicesCompat.dylib"
INSTALL_ROOT="$OUT/install"
XPC="$PAYLOAD/Installation.xpc"
INSTALLER="$XPC/Contents/MacOS/com.apple.Virtualization.Installation"
XPC_FRAMEWORKS="$XPC/Contents/Frameworks"
COMPAT="$XPC_FRAMEWORKS/InstallationCompat.dylib"
MOBILE_DEVICE_FRAMEWORK="$XPC_FRAMEWORKS/MobileDevice.framework"
MOBILE_DEVICE="$MOBILE_DEVICE_FRAMEWORK/Versions/A/MobileDevice"
USBMUXD="$MOBILE_DEVICE_FRAMEWORK/Versions/A/Resources/usbmuxd"
CRYPTO="$XPC_FRAMEWORKS/crypto.dylib"
SSL="$XPC_FRAMEWORKS/ssl.dylib"
TRUST_EVALUATION_FRAMEWORK="$XPC_FRAMEWORKS/TrustEvaluationAgent.framework"
TRUST_EVALUATION="$TRUST_EVALUATION_FRAMEWORK/TrustEvaluationAgent"
COREUTILS_COMPAT="$XPC_FRAMEWORKS/CoreUtilsCompat.dylib"
CRASHREPORTER_COMPAT="$XPC_FRAMEWORKS/CrashReporterCompat.dylib"
DISKIMAGES_COMPAT="$XPC_FRAMEWORKS/DiskImagesCompat.dylib"
CORESERVICES_COMPAT="$XPC_FRAMEWORKS/CoreServicesCompat.dylib"
SECURITY_COMPAT="$XPC_FRAMEWORKS/SecurityCompat.dylib"
HOST_HOOK="$INSTALL_ROOT/VZHostCompat.dylib"
PROBE="$INSTALL_ROOT/restore-image-probe"
INSTALL_TOOL="$INSTALL_ROOT/install-macos"
USB_BRIDGE_PROBE="$INSTALL_ROOT/usb-bridge-probe"
INSTALL_LAUNCHER="$INSTALL_ROOT/install-launcher"
ENTS="$VZ_REPO_ROOT/vz/patches/installation.ents.xml"
HOST_ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"
DA_TBD="$VZ_REPO_ROOT/vz/host/DiskArbitration-iOS.tbd"
COREUTILS_TBD="$VZ_REPO_ROOT/vz/host/CoreUtils-iOS.tbd"
DISKIMAGES_TBD="$VZ_REPO_ROOT/vz/host/DiskImages-iOS.tbd"
SECURITY_TBD="$VZ_REPO_ROOT/vz/host/Security-iOS.tbd"
DEVICE_SUPPORT_ROOT="$VZ_BUILD_ROOT/analysis/device-support-27/expanded/Payload"
SOURCE_MOBILE_DEVICE="$DEVICE_SUPPORT_ROOT/System/Library/PrivateFrameworks/MobileDevice.framework"
DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW_TOOL="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
CACHE="$VZ_BUILD_ROOT/cache/device-support-runtime"

need_command codesign
need_command ditto
need_command dwarfdump
need_command install_name_tool
need_command ldid
need_command lipo
need_command otool
need_command plutil
need_command shasum
need_command xcrun
"$SCRIPT_DIR/analyze-device-support.sh" >/dev/null
need_file "$SOURCE_XPC/Contents/MacOS/com.apple.Virtualization.Installation"
need_file "$SOURCE_MOBILE_DEVICE/Versions/A/MobileDevice"
need_file "$SOURCE_MOBILE_DEVICE/Versions/A/Resources/usbmuxd"
need_file "$DSC"
need_file "$DSC.01"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW_TOOL"
need_file "$VZ_REPO_ROOT/vz/host/installationhook.m"
need_file "$VZ_REPO_ROOT/vz/host/installation_usb_shim.m"
need_file "$VZ_REPO_ROOT/vz/host/NSViewShim.m"
need_file "$VZ_REPO_ROOT/vz/host/vzxpchook.m"
need_file "$VZ_REPO_ROOT/vz/development/probes/restore_image_probe.m"
need_file "$VZ_REPO_ROOT/vz/install/install_macos.m"
need_file "$VZ_REPO_ROOT/vz/install/start-install.sh"
need_file "$VZ_REPO_ROOT/vz/install/install_launcher.c"
need_file "$VZ_REPO_ROOT/vz/development/probes/usb_bridge_probe.c"
need_file "$VZ_REPO_ROOT/vz/stamp_ios.py"
need_file "$VZ_REPO_ROOT/vz/uncache.py"
need_file "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py"
need_file "$ENTS"
need_file "$HOST_ENTS"
need_file "$DA_TBD"
need_file "$COREUTILS_TBD"
need_file "$DISKIMAGES_TBD"
need_file "$SECURITY_TBD"
need_file "$VZ_REPO_ROOT/vz/host/coreutils_compat.c"
need_file "$VZ_REPO_ROOT/vz/host/crashreporter_compat.c"
need_file "$VZ_REPO_ROOT/vz/host/diskimages_compat.c"
need_file "$VZ_REPO_ROOT/vz/host/coreservices_compat.c"
need_file "$VZ_REPO_ROOT/vz/host/security_compat.c"

# Installation launches the same VirtualMachine.xpc used by ordinary boots.
# Rebuild and package its compatibility library too so USB-controller bridge
# changes are never accidentally tested against a stale iPad deployment.
"$SCRIPT_DIR/build-vmm-compat.sh" >/dev/null
need_file "$VMM_COMPAT_SOURCE"

rm -rf "$OUT"
mkdir -p "$PAYLOAD" "$INSTALL_ROOT" "$CACHE"
cp "$VZ_REPO_ROOT/vz/install/start-install.sh" \
    "$INSTALL_ROOT/"
chmod 755 "$INSTALL_ROOT/start-install.sh"
mkdir -p "$(dirname "$VMM_COMPAT")"
ditto "$VMM_COMPAT_SOURCE" "$VMM_COMPAT"
ditto "$SOURCE_XPC" "$XPC"
rm -rf "$XPC/Contents/_CodeSignature"
mkdir -p "$XPC_FRAMEWORKS"

lipo -thin arm64e \
    "$SOURCE_XPC/Contents/MacOS/com.apple.Virtualization.Installation" \
    -output "$INSTALLER.macos"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$INSTALLER.macos" "$INSTALLER" 16.0
rm -f "$INSTALLER.macos"

# Installation.xpc soft-loads the installed DeviceSupport MobileDevice. Keep
# that contract but point both Ventura search paths at the framework embedded
# beside this helper.
"$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" \
    "$INSTALLER" \
    softlink:r:path:/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice \
    softlink:r:path:@loader_path/../Frameworks/MobileDevice.framework/MobileDevice \
    3
"$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" \
    "$INSTALLER" \
    /System/Library/PrivateFrameworks/MobileDevice.framework/Contents/MacOS/MobileDevice \
    @loader_path/../Frameworks/MobileDevice.framework/MobileDevice

# MobileDevice 1857 is an ordinary arm64e Mach-O in the supplied
# DeviceSupport package, so it needs no dyld-cache extraction.
mkdir -p "$MOBILE_DEVICE_FRAMEWORK/Versions/A"
lipo -thin arm64e "$SOURCE_MOBILE_DEVICE/Versions/A/MobileDevice" \
    -output "$CACHE/MobileDevice.macos"
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$CACHE/MobileDevice.macos" "$MOBILE_DEVICE" 16.0
if [[ -d "$SOURCE_MOBILE_DEVICE/Versions/A/Resources" ]]; then
    ditto "$SOURCE_MOBILE_DEVICE/Versions/A/Resources" \
        "$MOBILE_DEVICE_FRAMEWORK/Versions/A/Resources"
fi
# DeviceSupport also ships a standalone macOS updater app. Installation.xpc
# needs its matching usbmuxd resources, not an AppKit executable that cannot
# run on iPadOS and would invalidate the payload-wide platform audit.
rm -rf "$MOBILE_DEVICE_FRAMEWORK/Versions/A/Resources/MobileDeviceUpdater.app"
ln -sfn A "$MOBILE_DEVICE_FRAMEWORK/Versions/Current"
ln -sfn Versions/Current/MobileDevice "$MOBILE_DEVICE_FRAMEWORK/MobileDevice"
ln -sfn Versions/Current/Resources "$MOBILE_DEVICE_FRAMEWORK/Resources"

# Run DeviceSupport's genuine host-side usbmuxd beside its matching
# MobileDevice framework.  This daemon owns Apple's USBMux wire protocol;
# InstallationCompat supplies only the IORegistry/IOUSBLib façade that routes
# its transfers to VMM's real AVP USB controller.
lipo -thin arm64e "$SOURCE_MOBILE_DEVICE/Versions/A/Resources/usbmuxd" \
    -output "$CACHE/usbmuxd.macos"
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$CACHE/usbmuxd.macos" "$USBMUXD" 16.0
install_name_tool \
    -change /System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/MobileDevice \
    @loader_path/../MobileDevice \
    -change /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    "$USBMUXD"
"$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" \
    "$USBMUXD" /var/run/usbmuxd /tmp/vzusbmuxd

install_name_tool \
    -change /System/Library/PrivateFrameworks/CoreUtils.framework/Versions/A/CoreUtils \
    @loader_path/../../../CoreUtilsCompat.dylib \
    -change /System/Library/PrivateFrameworks/DiskImages2.framework/Versions/A/DiskImages2 \
    /System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2 \
    -change /System/Library/PrivateFrameworks/RemoteXPC.framework/Versions/A/RemoteXPC \
    /System/Library/PrivateFrameworks/RemoteXPC.framework/RemoteXPC \
    -change /System/Library/PrivateFrameworks/RemoteServiceDiscovery.framework/Versions/A/RemoteServiceDiscovery \
    /System/Library/PrivateFrameworks/RemoteServiceDiscovery.framework/RemoteServiceDiscovery \
    -change /System/Library/PrivateFrameworks/CrashReporterSupport.framework/Versions/A/CrashReporterSupport \
    @loader_path/../../../CrashReporterCompat.dylib \
    -change /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    /System/Library/Frameworks/Foundation.framework/Foundation \
    -change /usr/lib/libcrypto.35.dylib \
    @loader_path/../../../crypto.dylib \
    -change /System/Library/PrivateFrameworks/DiskImages.framework/Versions/A/DiskImages \
    @loader_path/../../../DiskImagesCompat.dylib \
    -change /System/Library/Frameworks/DiskArbitration.framework/Versions/A/DiskArbitration \
    /System/Library/PrivateFrameworks/DiskArbitration.framework/DiskArbitration \
    -change /System/Library/PrivateFrameworks/Bom.framework/Versions/A/Bom \
    /System/Library/PrivateFrameworks/Bom.framework/Bom \
    -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change /System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices \
    @loader_path/../../../CoreServicesCompat.dylib \
    -change /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    -change /System/Library/Frameworks/Security.framework/Versions/A/Security \
    @loader_path/../../../SecurityCompat.dylib \
    -change /System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration \
    /System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration \
    -change /usr/lib/libssl.35.dylib \
    @loader_path/../../../ssl.dylib \
    -change /System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork \
    /System/Library/Frameworks/CFNetwork.framework/CFNetwork \
    "$MOBILE_DEVICE"

# The two OpenSSL libraries expected by MobileDevice are in Ventura's shared
# cache, not in iPadOS or in the DeviceSupport package. Reconstruct only these
# images with the existing arm64e-safe uncache pipeline.
for spec in 'libcrypto.35.dylib|crypto.dylib' \
            'libssl.35.dylib|ssl.dylib'; do
    IFS='|' read -r library packagedName <<<"$spec"
    image="/usr/lib/$library"
    raw="$CACHE/$library.raw"
    proto="$CACHE/$library.proto"
    output="$XPC_FRAMEWORKS/$packagedName"
    if [[ ! -f "$raw" ]]; then
        "$DYLDEX" -e "$image" -o "$raw" "$DSC"
    fi
    VZ_IPSW="$IPSW_TOOL" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
        "$DSC" "$image" "$raw" "$proto" compact
    "$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" \
        "$proto" \
        /System/Library/PrivateFrameworks/TrustEvaluationAgent.framework/TrustEvaluationAgent \
        @loader_path/TrustEvaluationAgent.framework/TrustEvaluationAgent
    if [[ "$library" == libssl.35.dylib ]]; then
        "$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" \
            "$proto" /usr/lib/libcrypto.35.dylib \
            @loader_path/crypto.dylib
    fi
    "$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
        "$proto" "$output" 16.0
done

trustImage="TrustEvaluationAgent.framework/Versions/A/TrustEvaluationAgent"
trustRaw="$CACHE/TrustEvaluationAgent.raw"
trustProto="$CACHE/TrustEvaluationAgent.proto"
if [[ ! -f "$trustRaw" ]]; then
    "$DYLDEX" -e "$trustImage" -o "$trustRaw" "$DSC"
fi
VZ_IPSW="$IPSW_TOOL" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$trustImage" "$trustRaw" "$trustProto" compact
mkdir -p "$TRUST_EVALUATION_FRAMEWORK"
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$trustProto" "$TRUST_EVALUATION" 16.0

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib \
    -Wl,-reexport_library,"$COREUTILS_TBD" \
    -install_name "@rpath/CoreUtilsCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/coreutils_compat.c" \
    -o "$COREUTILS_COMPAT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib \
    -install_name "@rpath/CrashReporterCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/crashreporter_compat.c" \
    -o "$CRASHREPORTER_COMPAT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib \
    -Wl,-reexport_library,"$DISKIMAGES_TBD" \
    -install_name "@rpath/DiskImagesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/diskimages_compat.c" \
    -o "$DISKIMAGES_COMPAT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib \
    -install_name "@rpath/CoreServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/coreservices_compat.c" \
    -o "$CORESERVICES_COMPAT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib \
    -Wl,-reexport_library,"$SECURITY_TBD" \
    -install_name "@rpath/SecurityCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/security_compat.c" \
    -o "$SECURITY_COMPAT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework CoreFoundation -framework IOKit \
    -Wl,-reexport_library,"$DA_TBD" \
    -install_name "@rpath/InstallationCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/installationhook.m" \
    "$VZ_REPO_ROOT/vz/host/installation_usb_shim.m" \
    -o "$COMPAT"

install_name_tool \
    -change \
    /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    /System/Library/Frameworks/Foundation.framework/Foundation \
    -change \
    /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change \
    /System/Library/Frameworks/DiskArbitration.framework/Versions/A/DiskArbitration \
    @loader_path/../Frameworks/InstallationCompat.dylib \
    -change \
    /System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface \
    /System/Library/Frameworks/IOSurface.framework/IOSurface \
    -change \
    /System/Library/PrivateFrameworks/DiskImages2.framework/Versions/A/DiskImages2 \
    /System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2 \
    -change \
    /System/Library/PrivateFrameworks/SoftLinking.framework/Versions/A/SoftLinking \
    /System/Library/PrivateFrameworks/SoftLinking.framework/SoftLinking \
    "$INSTALLER"

INFO="$XPC/Contents/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$INFO"
plutil -replace DTPlatformName -string iphoneos "$INFO"
plutil -replace DTPlatformVersion -string 16.0 "$INFO"
plutil -replace DTSDKName -string iphoneos16.0.internal "$INFO"
plutil -remove LSMinimumSystemVersion "$INFO" 2>/dev/null || true
plutil -replace MinimumOSVersion -string 16.0 "$INFO" 2>/dev/null || \
    plutil -insert MinimumOSVersion -string 16.0 "$INFO"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -install_name "@rpath/VZHostCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/vzxpchook.m" \
    -o "$HOST_HOOK"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" -fblocks \
    -framework Foundation -framework Metal -framework UIKit \
    -Wl,-export_dynamic \
    "$VZ_REPO_ROOT/vz/host/NSViewShim.m" \
    "$VZ_REPO_ROOT/vz/development/probes/restore_image_probe.m" \
    -o "$PROBE"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" -fblocks \
    -framework Foundation -framework Metal -framework UIKit \
    -Wl,-export_dynamic \
    "$VZ_REPO_ROOT/vz/host/NSViewShim.m" \
    "$VZ_REPO_ROOT/vz/install/install_macos.m" \
    -o "$INSTALL_TOOL"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" \
    "$VZ_REPO_ROOT/vz/development/probes/usb_bridge_probe.c" \
    -o "$USB_BRIDGE_PROBE"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" \
    "$VZ_REPO_ROOT/vz/install/install_launcher.c" \
    -o "$INSTALL_LAUNCHER"

ldid -S"$ENTS" "$INSTALLER"
ldid -S"$ENTS" "$COMPAT"
ldid -S"$ENTS" "$MOBILE_DEVICE"
ldid -S"$ENTS" "$USBMUXD"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime "$CRYPTO"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime "$SSL"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$TRUST_EVALUATION"
ldid -S"$ENTS" "$COREUTILS_COMPAT"
ldid -S"$ENTS" "$CRASHREPORTER_COMPAT"
ldid -S"$ENTS" "$DISKIMAGES_COMPAT"
ldid -S"$ENTS" "$CORESERVICES_COMPAT"
ldid -S"$ENTS" "$SECURITY_COMPAT"
ldid -S"$HOST_ENTS" "$HOST_HOOK"
ldid -S"$HOST_ENTS" "$PROBE"
ldid -S"$HOST_ENTS" "$INSTALL_TOOL"
ldid -S "$USB_BRIDGE_PROBE"
ldid -S"$HOST_ENTS" "$INSTALL_LAUNCHER"

"$PYTHON" "$VZ_REPO_ROOT/scripts/audit-entitlements.py" \
    "$ENTS" "$INSTALLER" \
    "$ENTS" "$COMPAT" \
    "$ENTS" "$MOBILE_DEVICE" \
    "$ENTS" "$USBMUXD" \
    "$ENTS" "$COREUTILS_COMPAT" \
    "$ENTS" "$CRASHREPORTER_COMPAT" \
    "$ENTS" "$DISKIMAGES_COMPAT" \
    "$ENTS" "$CORESERVICES_COMPAT" \
    "$ENTS" "$SECURITY_COMPAT" \
    "$HOST_ENTS" "$HOST_HOOK" \
    "$HOST_ENTS" "$PROBE" \
    "$HOST_ENTS" "$INSTALL_TOOL" \
    - "$CRYPTO" \
    - "$SSL" \
    - "$TRUST_EVALUATION" \
    - "$USB_BRIDGE_PROBE" \
    "$HOST_ENTS" "$INSTALL_LAUNCHER"

otool -l "$INSTALLER" |
    awk '/LC_BUILD_VERSION/{show=1; left=7} show && left-- > 0 {print}' |
    grep -q 'platform 2' || die "Installation.xpc is not stamped for iOS"
otool -L "$INSTALLER" | grep -Fq \
    '@loader_path/../Frameworks/InstallationCompat.dylib' ||
    die "Installation.xpc does not load InstallationCompat"
otool -L "$COMPAT" | grep -Fq \
    '/System/Library/PrivateFrameworks/DiskArbitration.framework/DiskArbitration' ||
    die "InstallationCompat does not re-export iPad DiskArbitration"
otool -L "$MOBILE_DEVICE" | grep -Fq \
    '@loader_path/../../../crypto.dylib' ||
    die "MobileDevice does not load bundled libcrypto"
otool -L "$MOBILE_DEVICE" | grep -Fq \
    '@loader_path/../../../ssl.dylib' ||
    die "MobileDevice does not load bundled libssl"
otool -L "$CRYPTO" | grep -Fq \
    '@loader_path/TrustEvaluationAgent.framework/TrustEvaluationAgent' ||
    die "libcrypto does not load bundled TrustEvaluationAgent"
otool -L "$MOBILE_DEVICE" | grep -Fq \
    '@loader_path/../../../CoreUtilsCompat.dylib' ||
    die "MobileDevice does not load CoreUtils compatibility image"
otool -L "$COREUTILS_COMPAT" | grep -Fq \
    '/System/Library/PrivateFrameworks/CoreUtils.framework/CoreUtils' ||
    die "CoreUtils compatibility image does not re-export iPad CoreUtils"
otool -L "$USBMUXD" | grep -Fq '@loader_path/../MobileDevice' ||
    die "usbmuxd does not load bundled MobileDevice"

{
    for file in "$INSTALLER" "$COMPAT" "$MOBILE_DEVICE" "$USBMUXD" \
                "$CRYPTO" "$SSL" "$TRUST_EVALUATION" \
                "$COREUTILS_COMPAT" \
                "$CRASHREPORTER_COMPAT" \
                "$DISKIMAGES_COMPAT" \
                "$CORESERVICES_COMPAT" \
                "$SECURITY_COMPAT" \
                "$VMM_COMPAT" \
                "$HOST_HOOK" "$PROBE" "$INSTALL_TOOL" \
                "$USB_BRIDGE_PROBE" "$INSTALL_LAUNCHER"; do
        printf '%s\t%s\n' \
            "$(ldid -h "$file" | sed -n 's/^CDHash=//p')" \
            "${file#"$OUT"/}"
    done
} >"$OUT/trustcache.txt"

{
    printf 'IPAD_INSTALLATION_MANIFEST\t1\n'
    printf 'generated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repository_commit\t%s\n' "$(git -C "$VZ_REPO_ROOT" rev-parse HEAD)"
    printf 'source_installer_sha256\t%s\n' "$(shasum -a 256 "$SOURCE_XPC/Contents/MacOS/com.apple.Virtualization.Installation" | awk '{print $1}')"
    printf 'source_installer_uuid\t%s\n' "$(dwarfdump --uuid "$SOURCE_XPC/Contents/MacOS/com.apple.Virtualization.Installation" | awk '/arm64e/{print $2}')"
    printf 'installer_sha256\t%s\n' "$(shasum -a 256 "$INSTALLER" | awk '{print $1}')"
    printf 'installer_uuid\t%s\n' "$(dwarfdump --uuid "$INSTALLER" | awk '{print $2}')"
    printf 'mobile_device_version\t1857\n'
    printf 'mobile_device_sha256\t%s\n' "$(shasum -a 256 "$MOBILE_DEVICE" | awk '{print $1}')"
} >"$OUT/manifest.txt"

echo "iPad installation payload built: $OUT"
