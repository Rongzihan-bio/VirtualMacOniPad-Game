#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SOURCE_ROOT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS"
SOURCE_BIN="$SOURCE_ROOT/usr/libexec/InternetSharing"
SOURCE_PLIST="$SOURCE_ROOT/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
BIG_SUR_SOURCE_ROOT="$VZ_BUILD_ROOT/inputs/macos11/20G165__MacOS"
BIG_SUR_SOURCE_BIN="$BIG_SUR_SOURCE_ROOT/usr/libexec/InternetSharing"
DSC="${VZ_MACOS_DSC:-$SOURCE_ROOT/dyld_shared_cache_arm64e}"
ENTS="$VZ_REPO_ROOT/vz/patches/internet-sharing.ents.xml"
COMPAT_PATCH="$VZ_REPO_ROOT/vz/patches/patch_internet_sharing.py"
IPADOS14_PATCH="$VZ_REPO_ROOT/vz/patches/patch_ipados14_internet_sharing.py"
OUT="$VZ_BUILD_ROOT/ipad-network-sharing"
BIN="$OUT/InternetSharing"
PLIST="$OUT/com.apple.NetworkSharing.plist"
AUTH_COMPAT="$OUT/AuthorizationCompat.dylib"
LIBMRC="$OUT/libmrc.dylib"
LIBMRC_IPADOS15_AUTH="$OUT/libmrc.ipados15-auth.dylib"
LIBMRC_CACHE="$VZ_BUILD_ROOT/cache/network-sharing"
LIBMRC_RAW="$LIBMRC_CACHE/libmrc.raw"
LIBMRC_PROTO="$LIBMRC_CACHE/libmrc.proto"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

need_command codesign
need_command ldid
need_command install_name_tool
need_command lipo
need_command plutil
need_command xcrun
need_file "$SOURCE_BIN"
need_file "$SOURCE_PLIST"
need_file "$BIG_SUR_SOURCE_BIN"
need_file "$DSC"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_file "$ENTS"
need_file "$COMPAT_PATCH"
need_file "$IPADOS14_PATCH"

rm -rf "$OUT"
mkdir -p "$OUT"
mkdir -p "$LIBMRC_CACHE"
lipo -thin arm64e "$SOURCE_BIN" -output "$BIN.macos"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -framework CoreFoundation -framework Security \
    -framework SystemConfiguration \
    -Wl,-reexport_framework,Security \
    -Wl,-undefined,dynamic_lookup \
    -install_name @rpath/AuthorizationCompat.dylib \
    "$VZ_REPO_ROOT/vz/host/authorization_compat.c" \
    -o "$AUTH_COMPAT"

install_name_tool \
    -change /System/Library/PrivateFrameworks/PacketFilter.framework/Versions/A/PacketFilter \
    /System/Library/PrivateFrameworks/PacketFilter.framework/PacketFilter \
    -change /System/Library/Frameworks/Security.framework/Versions/A/Security \
    @loader_path/../lib/AuthorizationCompat.dylib \
    -change /System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement \
    /System/Library/PrivateFrameworks/ServiceManagement.framework/ServiceManagement \
    -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    /System/Library/Frameworks/Foundation.framework/Foundation \
    -change /System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration \
    /System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration \
    -change /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    "$BIN.macos"

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/stamp_ios.py" "$BIN.macos" "$BIN" \
    "$VZ_IPADOS_MIN_VERSION"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" "$COMPAT_PATCH" "$BIN"
# Use Apple's signer so the entitlements are encoded in both the XML and DER
# slots consumed by iOS 16 AMFI, with a valid modern ad-hoc CodeDirectory.
codesign --force --sign - --entitlements "$ENTS" \
    --generate-entitlement-der "$BIN"

# Ventura InternetSharing uses libmrc for its DNS proxy. It does not exist on
# iPadOS 15. Extract the exact companion library from the already-required
# Ventura cache, adapt its arm64e Objective-C metadata, and select it only on
# pre-16 hosts. iPadOS 16 continues to use its native system libmrc.
if [[ ! -f "$LIBMRC_RAW" ]]; then
    "$PYTHON" "$DYLDEX" -e /usr/lib/libmrc.dylib \
        -o "$LIBMRC_RAW" "$DSC"
fi
VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" /usr/lib/libmrc.dylib "$LIBMRC_RAW" "$LIBMRC_PROTO" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$LIBMRC_PROTO" "$LIBMRC_IPADOS15_AUTH" "$VZ_IPADOS_MIN_VERSION"
"$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_ipados15_objc_imports.py" \
    "$LIBMRC_IPADOS15_AUTH"
codesign --force --sign - "$LIBMRC_IPADOS15_AUTH"
cp "$LIBMRC_IPADOS15_AUTH" "$LIBMRC"
"$PYTHON" "$VZ_REPO_ROOT/vz/patches/patch_ipados15_objc_class_data.py" \
    "$LIBMRC"
codesign --force --sign - "$LIBMRC"

cp "$BIN" "$BIN.ipados16"
cp "$BIN" "$BIN.ipados15"
install_name_tool -change /usr/lib/libmrc.dylib \
    @loader_path/../lib/libmrc.dylib "$BIN.ipados15"
codesign --force --sign - --entitlements "$ENTS" \
    --generate-entitlement-der "$BIN.ipados15"
lipo -thin arm64e "$BIG_SUR_SOURCE_BIN" -output "$BIN.ipados14.macos"
install_name_tool \
    -change /System/Library/PrivateFrameworks/PacketFilter.framework/Versions/A/PacketFilter \
    /System/Library/PrivateFrameworks/PacketFilter.framework/PacketFilter \
    -change /System/Library/Frameworks/Security.framework/Versions/A/Security \
    @loader_path/../lib/AuthorizationCompat.dylib \
    -change /System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement \
    /System/Library/PrivateFrameworks/ServiceManagement.framework/ServiceManagement \
    -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    /System/Library/Frameworks/Foundation.framework/Foundation \
    -change /System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration \
    /System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration \
    -change /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    "$BIN.ipados14.macos"
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$BIN.ipados14.macos" "$BIN.ipados14" 14.5
"$PYTHON" "$IPADOS14_PATCH" "$BIN.ipados14"
codesign --force --sign - --entitlements "$ENTS" \
    --generate-entitlement-der "$BIN.ipados14"
rm -f "$BIN.ipados14.macos"
ldid -S "$AUTH_COMPAT"
rm -f "$BIN.macos"

cp "$SOURCE_PLIST" "$PLIST"
plutil -remove ProgramArguments "$PLIST"
plutil -insert ProgramArguments -json \
    '["/var/jb/usr/libexec/InternetSharing"]' "$PLIST"
plutil -insert Program -string /var/jb/usr/libexec/InternetSharing "$PLIST"
plutil -insert UserName -string root "$PLIST"
plutil -insert POSIXSpawnType -string Interactive "$PLIST"
plutil -insert ProcessType -string Interactive "$PLIST"
plutil -insert ExecuteAllowed -bool YES "$PLIST"
if [[ "${VZ_NETWORK_SHARING_DOMAIN:-user/501}" == system ]]; then
    plutil -insert LimitLoadToSessionType -string System "$PLIST"
fi
plutil -insert JetsamProperties -json \
    '{"JetsamMemoryLimit":131072,"JetsamPriority":40}' "$PLIST"
plutil -insert StandardOutPath -string /tmp/InternetSharing.out "$PLIST"
plutil -insert StandardErrorPath -string /tmp/InternetSharing.err "$PLIST"
if [[ "${VZ_NETWORK_SHARING_WAIT_FOR_DEBUGGER:-0}" == 1 ]]; then
    plutil -insert WaitForDebugger -bool YES "$PLIST"
fi
plutil -lint "$PLIST"

otool -L "$BIN" | grep -Fq \
    /System/Library/PrivateFrameworks/ServiceManagement.framework/ServiceManagement
ldid -h "$BIN" >/dev/null
ldid -h "$AUTH_COMPAT" >/dev/null
codesign --verify --strict "$BIN"
codesign --verify --strict "$BIN.ipados14"
codesign --verify --strict "$BIN.ipados15"
codesign --verify --strict "$BIN.ipados16"
codesign --verify --strict "$LIBMRC"
codesign --verify --strict "$LIBMRC_IPADOS15_AUTH"
python3 "$VZ_REPO_ROOT/scripts/audit-entitlements.py" \
    "$ENTS" "$BIN" \
    "$ENTS" "$BIN.ipados14" \
    "$ENTS" "$BIN.ipados15" \
    "$ENTS" "$BIN.ipados16" \
    - "$LIBMRC" \
    - "$LIBMRC_IPADOS15_AUTH" \
    - "$AUTH_COMPAT"
"$SCRIPT_DIR/build-ipad-network-helpers.sh"
echo "iPad NetworkSharing daemon built: $OUT"
