#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PACKAGE="${VZ_DEVICE_SUPPORT_PKG:-}"
DMG="${VZ_DEVICE_SUPPORT_DMG:-}"
IPAD_DSC="${VZ_IPADOS_DSC:-$VZ_BUILD_ROOT/inputs/ipados/20D67__iPad14,3_4_5_6/dyld_shared_cache_arm64e}"
OUT="${VZ_DEVICE_SUPPORT_ANALYSIS:-$VZ_BUILD_ROOT/analysis/device-support-27}"
EXPANDED="$OUT/expanded"
MOUNT_DIR=""

need_command codesign
need_command file
need_command hdiutil
need_command lipo
need_command nm
need_command otool
need_command pkgutil

if [[ -n "$PACKAGE" && -n "$DMG" ]]; then
    die "set only one of VZ_DEVICE_SUPPORT_PKG or VZ_DEVICE_SUPPORT_DMG"
fi
if [[ -z "$PACKAGE" && -z "$DMG" ]]; then
    DMG="$VZ_BUILD_ROOT/downloads/DeviceSupport_macOS_27_beta.dmg"
fi
if [[ -n "$PACKAGE" ]]; then
    need_file "$PACKAGE"
else
    need_file "$DMG"
fi

cleanup() {
    if [[ -n "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$OUT"
if [[ ! -d "$EXPANDED" ]]; then
    if [[ -n "$PACKAGE" ]]; then
        pkgutil --expand-full "$PACKAGE" "$EXPANDED"
    else
        MOUNT_DIR="$(mktemp -d /tmp/apple-vz-device-support.XXXXXX)"
        hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG" -quiet
        package="$(find "$MOUNT_DIR" -maxdepth 2 -name '*.pkg' -print -quit)"
        [[ -n "$package" ]] || die "no package found in $DMG"
        pkgutil --expand-full "$package" "$EXPANDED"
    fi
fi

PAYLOAD="$EXPANDED/Payload"
MOBILE_DEVICE="$PAYLOAD/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/MobileDevice"
USBMUXD="$PAYLOAD/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd"
USBMUXD_PLIST="$PAYLOAD/System/Library/LaunchDaemons/com.apple.usbmuxd.plist"
need_file "$MOBILE_DEVICE"
need_file "$USBMUXD"
need_file "$USBMUXD_PLIST"

expected_mobile_device=ddcfe9a3ca6be0a7f5d2c231eaad086aaecc4aec9ff49f18d6e731aa8d6da89c
expected_usbmuxd=8c3ae325cef26b0f8ba5a4de45d8a2a4ecdbb89a4b87634a85a51eb6d509d47f
actual_mobile_device="$(shasum -a 256 "$MOBILE_DEVICE" | awk '{print $1}')"
actual_usbmuxd="$(shasum -a 256 "$USBMUXD" | awk '{print $1}')"
[[ "$actual_mobile_device" == "$expected_mobile_device" ]] ||
    die "unsupported DeviceSupport MobileDevice: $actual_mobile_device"
[[ "$actual_usbmuxd" == "$expected_usbmuxd" ]] ||
    die "unsupported DeviceSupport usbmuxd: $actual_usbmuxd"

{
    source_input="${PACKAGE:-$DMG}"
    echo "source=$source_input"
    echo "sha256=$(shasum -a 256 "$source_input" | awk '{print $1}')"
    echo "architectures=$(lipo -archs "$MOBILE_DEVICE")"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$PAYLOAD/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/Resources/Info.plist" 2>/dev/null \
        | sed 's/^/bundle_version=/' || true
} >"$OUT/summary.txt"

otool -L -arch arm64e "$MOBILE_DEVICE" >"$OUT/mobiledevice-linked-images.txt"
nm -um -arch arm64e "$MOBILE_DEVICE" >"$OUT/mobiledevice-imports.txt"
nm -gj -arch arm64e "$MOBILE_DEVICE" | sort -u >"$OUT/mobiledevice-exports.txt"
codesign -d --entitlements :- "$MOBILE_DEVICE" \
    >"$OUT/mobiledevice-entitlements.plist" 2>/dev/null || true
otool -L -arch arm64e "$USBMUXD" >"$OUT/usbmuxd-linked-images.txt"
codesign -d --entitlements :- "$USBMUXD" \
    >"$OUT/usbmuxd-entitlements.plist" 2>/dev/null || true
plutil -p "$USBMUXD_PLIST" >"$OUT/usbmuxd-launchd-plist.txt"

if [[ -f "$IPAD_DSC" ]]; then
    IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
    need_file "$IPSW"
    "$IPSW" dyld info -l "$IPAD_DSC" 2>/dev/null \
        | sed $'s/\033\\[[0-9;]*m//g' >"$OUT/ipados-dyld-images.txt"
    awk '/^[[:space:]]*[0-9]+:/ { print $NF }' "$OUT/ipados-dyld-images.txt" \
        | sed -E 's#/Versions/[A-Z]/#/#' | sort -u >"$OUT/ipados-install-names.txt"

    {
        echo "MobileDevice strong dependency coverage in the iPadOS shared cache"
        echo "(weak dependencies are reported separately and are not required to launch)"
        echo
        otool -L -arch arm64e "$MOBILE_DEVICE" | tail -n +2 | while IFS= read -r line; do
            dependency="${line#"${line%%[![:space:]]*}"}"
            dependency="${dependency%% *}"
            normalized="$(printf '%s\n' "$dependency" | sed -E 's#/Versions/[A-Z]/#/#')"
            if [[ "$line" == *", weak)"* ]]; then
                strength="weak"
            else
                strength="strong"
            fi
            if grep -Fxq "$normalized" "$OUT/ipados-install-names.txt"; then
                state="present"
            else
                state="missing"
            fi
            printf '%-7s %-7s %s\n' "$state" "$strength" "$dependency"
        done
    } >"$OUT/mobiledevice-ipados-dependency-coverage.txt"
else
    printf '%s\n' 'iPadOS shared-cache dependency audit not requested' \
        >"$OUT/mobiledevice-ipados-dependency-coverage.txt"
fi

find "$PAYLOAD" -type f -print0 | while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
        printf '%s\t%s\n' "${candidate#"$PAYLOAD"/}" "$(lipo -archs "$candidate" 2>/dev/null || true)"
    fi
done | sort >"$OUT/payload-mach-o-files.txt"

echo "DeviceSupport analysis: $OUT"
