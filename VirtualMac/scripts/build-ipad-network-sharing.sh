#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SOURCE_ROOT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS"
SOURCE_BIN="$SOURCE_ROOT/usr/libexec/InternetSharing"
SOURCE_PLIST="$SOURCE_ROOT/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
ENTS="$VZ_REPO_ROOT/vz/patches/internet-sharing.ents.xml"
COMPAT_PATCH="$VZ_REPO_ROOT/vz/patches/patch_internet_sharing.py"
OUT="$VZ_BUILD_ROOT/ipad-network-sharing"
BIN="$OUT/InternetSharing"
PLIST="$OUT/com.apple.NetworkSharing.plist"
AUTH_COMPAT="$OUT/AuthorizationCompat.dylib"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

need_command codesign
need_command ldid
need_command install_name_tool
need_command lipo
need_command plutil
need_command xcrun
need_file "$SOURCE_BIN"
need_file "$SOURCE_PLIST"
need_file "$ENTS"
need_file "$COMPAT_PATCH"

rm -rf "$OUT"
mkdir -p "$OUT"
lipo -thin arm64e "$SOURCE_BIN" -output "$BIN.macos"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib -framework CoreFoundation -framework Security \
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
    "$VZ_REPO_ROOT/vz/stamp_ios.py" "$BIN.macos" "$BIN" 16.0
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" "$COMPAT_PATCH" "$BIN"
# Use Apple's signer so the entitlements are encoded in both the XML and DER
# slots consumed by iOS 16 AMFI, with a valid modern ad-hoc CodeDirectory.
codesign --force --sign - --entitlements "$ENTS" \
    --generate-entitlement-der "$BIN"
ldid -S "$AUTH_COMPAT"
rm "$BIN.macos"

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
python3 "$VZ_REPO_ROOT/scripts/audit-entitlements.py" \
    "$ENTS" "$BIN" \
    - "$AUTH_COMPAT"
"$SCRIPT_DIR/build-ipad-network-helpers.sh"
echo "iPad NetworkSharing daemon built: $OUT"
