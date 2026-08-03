#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
RAW_DIR="$VZ_BUILD_ROOT/frameworks/raw"
MAC_DIR="$VZ_BUILD_ROOT/frameworks/macos"
IOS_DIR="$VZ_BUILD_ROOT/frameworks/ios"
BUNDLE_DIR="$VZ_BUILD_ROOT/frameworks/bundles"
MANIFEST="$VZ_BUILD_ROOT/frameworks/manifest.txt"
FRAMEWORK_ROOT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/Frameworks"
PRIVATE_FRAMEWORK_ROOT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/PrivateFrameworks"

need_file "$DSC"
need_file "$DSC.01"
need_file "$PYTHON"
need_file "$DYLDEX"
need_file "$IPSW"
need_command codesign
need_command ditto
need_command dwarfdump
need_command otool

mkdir -p "$RAW_DIR" "$MAC_DIR" "$IOS_DIR" "$BUNDLE_DIR/macos" "$BUNDLE_DIR/ios"

images=(
    "Hypervisor.framework/Versions/A/Hypervisor|Hypervisor|1B1E116F-81FD-3FD6-B424-52D4FA96E9AB"
    "ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics|ParavirtualizedGraphics|732073AB-34E5-38C9-A919-53B628977BDB"
    "Virtualization.framework/Versions/A/Virtualization|Virtualization|DCFC0A79-7728-3089-94D7-1508E71F38E5"
)

for spec in "${images[@]}"; do
    IFS='|' read -r image name expected_uuid <<< "$spec"
    raw="$RAW_DIR/$name"
    mac="$MAC_DIR/$name"
    proto="$IOS_DIR/$name.proto"
    ios="$IOS_DIR/$name"

    if [[ ! -f "$raw" ]]; then
        "$DYLDEX" -e "$image" -o "$raw" "$DSC"
    fi

    VZ_MAC=1 VZ_IPSW="$IPSW" \
        "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
        "$DSC" "$image" "$raw" "$mac" compact
    codesign --force --sign - "$mac"

    VZ_IPSW="$IPSW" VZ_WEAKEN="MetalSerializer,vmnet" \
        "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
        "$DSC" "$image" "$raw" "$proto" compact
    "$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" "$proto" "$ios" 16.0
    chmod 755 "$mac" "$ios"

    for output in "$mac" "$ios"; do
        uuid="$(dwarfdump --uuid "$output" | awk '{print $2}')"
        [[ "$uuid" == "$expected_uuid" ]] ||
            die "$name UUID mismatch in $output: expected $expected_uuid, got $uuid"
        codesign --verify "$output"
        otool -l "$output" | grep -q 'LC_DYLD_CHAINED_FIXUPS' ||
            die "$name is missing LC_DYLD_CHAINED_FIXUPS in $output"
    done

    source_resources="$FRAMEWORK_ROOT/$name.framework/Versions/A/Resources"
    need_file "$source_resources/Info.plist"
    for platform in macos ios; do
        bundle="$BUNDLE_DIR/$platform/$name.framework"
        version="$bundle/Versions/A"
        mkdir -p "$version/Resources"
        ditto "$source_resources" "$version/Resources"
        cp "$VZ_BUILD_ROOT/frameworks/$platform/$name" "$version/$name"
        chmod 755 "$version/$name"
        ln -sfn A "$bundle/Versions/Current"
        ln -sfn "Versions/Current/$name" "$bundle/$name"
        ln -sfn Versions/Current/Resources "$bundle/Resources"
    done

    if [[ "$name" == Virtualization ]]; then
        source_xpc="$FRAMEWORK_ROOT/$name.framework/Versions/A/XPCServices"
        need_file "$source_xpc/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        mac_bundle="$BUNDLE_DIR/macos/$name.framework"
        ditto "$source_xpc" "$mac_bundle/Versions/A/XPCServices"
        ln -sfn Versions/Current/XPCServices "$mac_bundle/XPCServices"
        for xpc in "$mac_bundle"/Versions/A/XPCServices/*.xpc; do
            # The IPSW signatures use legacy resource envelopes. Re-sign each
            # copied service while retaining its privileged entitlements, then
            # seal those nested signatures into the completed framework.
            codesign --force --sign - \
                --preserve-metadata=entitlements,flags,runtime "$xpc"
            codesign --verify --strict "$xpc"
        done
    fi

    for platform in macos ios; do
        bundle="$BUNDLE_DIR/$platform/$name.framework"
        codesign --force --sign - "$bundle"
        codesign --verify --deep --strict "$bundle"
    done
done

metal_serializer_image="MetalSerializer.framework/Versions/A/MetalSerializer"
metal_serializer_name="MetalSerializer"
metal_serializer_uuid="9C249FB4-2C87-3099-807B-2A3B063C79FA"
metal_serializer_raw="$RAW_DIR/$metal_serializer_name"
metal_serializer_proto="$IOS_DIR/$metal_serializer_name.proto"
metal_serializer_ios="$IOS_DIR/$metal_serializer_name"

if [[ ! -f "$metal_serializer_raw" ]]; then
    "$DYLDEX" -e "$metal_serializer_image" \
        -o "$metal_serializer_raw" "$DSC"
fi
VZ_IPSW="$IPSW" \
    "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
    "$DSC" "$metal_serializer_image" "$metal_serializer_raw" \
    "$metal_serializer_proto" compact
"$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
    "$metal_serializer_proto" "$metal_serializer_ios" 16.0
chmod 755 "$metal_serializer_ios"
uuid="$(dwarfdump --uuid "$metal_serializer_ios" | awk '{print $2}')"
[[ "$uuid" == "$metal_serializer_uuid" ]] ||
    die "MetalSerializer UUID mismatch: expected $metal_serializer_uuid, got $uuid"
codesign --verify "$metal_serializer_ios"
otool -l "$metal_serializer_ios" | grep -q 'LC_DYLD_CHAINED_FIXUPS' ||
    die "MetalSerializer is missing LC_DYLD_CHAINED_FIXUPS"

metal_serializer_resources="$PRIVATE_FRAMEWORK_ROOT/MetalSerializer.framework/Versions/A/Resources"
need_file "$metal_serializer_resources/Info.plist"
metal_serializer_bundle="$BUNDLE_DIR/ios/MetalSerializer.framework"
metal_serializer_version="$metal_serializer_bundle/Versions/A"
rm -rf "$metal_serializer_bundle"
mkdir -p "$metal_serializer_version/Resources"
ditto "$metal_serializer_resources" "$metal_serializer_version/Resources"
cp "$metal_serializer_ios" "$metal_serializer_version/MetalSerializer"
chmod 755 "$metal_serializer_version/MetalSerializer"
ln -sfn A "$metal_serializer_bundle/Versions/Current"
ln -sfn Versions/Current/MetalSerializer \
    "$metal_serializer_bundle/MetalSerializer"
ln -sfn Versions/Current/Resources "$metal_serializer_bundle/Resources"
codesign --force --sign - "$metal_serializer_bundle"
codesign --verify --deep --strict "$metal_serializer_bundle"

hash_line() {
    local label="$1"
    local file="$2"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$label" \
        "$(stat -f %z "$file")" \
        "$(shasum -a 256 "$file" | awk '{print $1}')" \
        "$(dwarfdump --uuid "$file" | awk '{print $2}')" \
        "$file"
}

{
    printf 'FRAMEWORK_MANIFEST\t1\n'
    printf 'generated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repository_commit\t%s\n' "$(git -C "$VZ_REPO_ROOT" rev-parse HEAD)"
    printf 'dsc_sha256\t%s\n' "$(shasum -a 256 "$DSC" | awk '{print $1}')"
    for spec in "${images[@]}"; do
        IFS='|' read -r _ name _ <<< "$spec"
        hash_line "$name.raw" "$RAW_DIR/$name"
        hash_line "$name.macos" "$MAC_DIR/$name"
        hash_line "$name.ios" "$IOS_DIR/$name"
    done
    hash_line "$metal_serializer_name.raw" "$metal_serializer_raw"
    hash_line "$metal_serializer_name.ios" "$metal_serializer_ios"
    hash_line "$metal_serializer_name.bundle" \
        "$metal_serializer_version/MetalSerializer"
} > "$MANIFEST"

echo "frameworks built and validated: $MANIFEST"
