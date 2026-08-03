#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SOURCE_ROOT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS"
SOURCE_BOOTPD="$SOURCE_ROOT/usr/libexec/bootpd"
SOURCE_RTADVD="$SOURCE_ROOT/usr/sbin/rtadvd"
SOURCE_BOOTPD_PLIST="$SOURCE_ROOT/System/Library/LaunchDaemons/bootps.plist"
ENTS="$VZ_REPO_ROOT/vz/patches/network-helper.ents.xml"
COMPAT_PATCH="$VZ_REPO_ROOT/vz/patches/patch_network_helper.py"
OUT="$VZ_BUILD_ROOT/ipad-network-helpers"
BOOTPD="$OUT/bootpd"
RTADVD="$OUT/rtadvd"
OD_COMPAT="$OUT/OpenDirectoryCompat.dylib"
BOOTPD_PLIST="$OUT/com.apple.bootpd.plist"

need_command codesign
need_command install_name_tool
need_command ldid
need_command lipo
need_command plutil
need_file "$SOURCE_BOOTPD"
need_file "$SOURCE_RTADVD"
need_file "$SOURCE_BOOTPD_PLIST"
need_file "$ENTS"
need_file "$COMPAT_PATCH"

rm -rf "$OUT"
mkdir -p "$OUT"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -dynamiclib -framework CoreFoundation \
    -install_name @loader_path/../lib/OpenDirectoryCompat.dylib \
    "$VZ_REPO_ROOT/vz/host/open_directory_compat.c" \
    -o "$OD_COMPAT"
codesign --force --sign - "$OD_COMPAT"

for source in "$SOURCE_BOOTPD" "$SOURCE_RTADVD"; do
    name="$(basename "$source")"
    lipo -thin arm64e "$source" -output "$OUT/$name.macos"
done

install_name_tool \
    -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change /System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration \
    /System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration \
    -change /System/Library/Frameworks/OpenDirectory.framework/Versions/A/OpenDirectory \
    @loader_path/../lib/OpenDirectoryCompat.dylib \
    -change /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    "$OUT/bootpd.macos"

for name in bootpd rtadvd; do
    "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
        "$VZ_REPO_ROOT/vz/stamp_ios.py" "$OUT/$name.macos" "$OUT/$name" 16.0
    codesign --force --sign - --entitlements "$ENTS" \
        --generate-entitlement-der "$OUT/$name"
    codesign --verify --strict "$OUT/$name"
    rm -f "$OUT/$name.macos"
done

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" "$COMPAT_PATCH" "$BOOTPD"
codesign --force --sign - --entitlements "$ENTS" \
    --generate-entitlement-der "$BOOTPD"
codesign --verify --strict "$BOOTPD"
codesign --verify --strict "$OD_COMPAT"
python3 "$VZ_REPO_ROOT/scripts/audit-entitlements.py" \
    "$ENTS" "$BOOTPD" \
    "$ENTS" "$RTADVD" \
    - "$OD_COMPAT"

cp "$SOURCE_BOOTPD_PLIST" "$BOOTPD_PLIST"
plutil -replace Label -string vzi.apple.bootpd "$BOOTPD_PLIST"
plutil -replace ProgramArguments -json \
    '["/var/jb/usr/libexec/bootpd"]' "$BOOTPD_PLIST"
plutil -insert Program -string /var/jb/usr/libexec/bootpd "$BOOTPD_PLIST"
plutil -replace Disabled -bool NO "$BOOTPD_PLIST"
plutil -insert UserName -string root "$BOOTPD_PLIST"
plutil -insert POSIXSpawnType -string Interactive "$BOOTPD_PLIST"
plutil -insert ProcessType -string Interactive "$BOOTPD_PLIST"
plutil -insert ExecuteAllowed -bool YES "$BOOTPD_PLIST"
plutil -insert StandardOutPath -string /tmp/bootpd.out "$BOOTPD_PLIST"
plutil -insert StandardErrorPath -string /tmp/bootpd.err "$BOOTPD_PLIST"
plutil -lint "$BOOTPD_PLIST"

echo "iPad NetworkSharing helpers built: $OUT"
