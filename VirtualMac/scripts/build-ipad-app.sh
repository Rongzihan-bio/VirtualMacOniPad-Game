#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-app"
APP="$OUT/VirtualMac.app"
BIN="$APP/VirtualMac"
HOOK="$APP/VZHostCompat.dylib"
ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"

need_command ldid
need_command sips
need_command xattr
need_command xcrun
need_file "$VZ_REPO_ROOT/vz/host/VirtualMac-Info.plist"
need_file "$VZ_REPO_ROOT/vz/host/VirtualMacLaunchScreen.storyboard"
need_file "$VZ_REPO_ROOT/assets/VirtualMac.png"
need_file "$VZ_REPO_ROOT/vz/host/NSViewShim.m"
need_file "$VZ_REPO_ROOT/vz/host/VZAppSettings.m"
need_file "$VZ_REPO_ROOT/vz/host/VZRestoreCatalog.m"
need_file "$VZ_REPO_ROOT/vz/host/VZNewVMViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZProgressViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZSettingsViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZVMLibraryViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VirtualMacApp.m"
need_file "$VZ_REPO_ROOT/vz/host/vzxpchook.m"
need_file "$ENTS"

rm -rf "$APP"
mkdir -p "$APP"
cp "$VZ_REPO_ROOT/vz/host/VirtualMac-Info.plist" "$APP/Info.plist"
cp "$VZ_REPO_ROOT/vendor/VirtualBuddy/ipsws_v2.json" "$APP/ipsws_v2.json"
if [[ -d "$VZ_REPO_ROOT/assets/wallpapers" ]]; then
    mkdir -p "$APP/Wallpapers"
    cp "$VZ_REPO_ROOT/assets/wallpapers"/*.jpg "$APP/Wallpapers/"
    cp "$VZ_REPO_ROOT/assets/wallpapers"/*.png "$APP/Wallpapers/"
fi
xcrun ibtool --compile "$APP/VirtualMacLaunchScreen.storyboardc" \
    "$VZ_REPO_ROOT/vz/host/VirtualMacLaunchScreen.storyboard" \
    --target-device ipad --minimum-deployment-target 16.0 >/dev/null

# Generate the exact legacy icon filenames consumed by iPadOS 16. The checked
# in 1024-pixel RGB master has no alpha channel, as required for app icons.
cp "$VZ_REPO_ROOT/assets/VirtualMac.png" "$APP/AppIcon1024x1024.png"
for spec in \
    '120 AppIcon60x60@2x.png' \
    '180 AppIcon60x60@3x.png' \
    '152 AppIcon76x76@2x.png' \
    '167 AppIcon83.5x83.5@2x.png'; do
    read -r size name <<<"$spec"
    sips -z "$size" "$size" "$VZ_REPO_ROOT/assets/VirtualMac.png" \
        --out "$APP/$name" >/dev/null
done

xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min=16.0 -isysroot "$SDK" -fblocks \
    -framework AVFAudio -framework Foundation -framework GameController \
    -framework UIKit \
    -framework UniformTypeIdentifiers \
    -Wl,-export_dynamic -Wl,-undefined,dynamic_lookup \
    "$VZ_REPO_ROOT/vz/host/NSViewShim.m" \
    "$VZ_REPO_ROOT/vz/host/VZAppSettings.m" \
    "$VZ_REPO_ROOT/vz/host/VZRestoreCatalog.m" \
    "$VZ_REPO_ROOT/vz/host/VZNewVMViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZProgressViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZSettingsViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZVMLibraryViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VirtualMacApp.m" \
    -o "$BIN"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=16.0 -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -install_name "@executable_path/VZHostCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/vzxpchook.m" \
    -o "$HOOK"

xattr -cr "$APP"
ldid -S"$ENTS" "$BIN"
ldid -S"$ENTS" "$HOOK"
echo "native iPad VM app built: $APP"
