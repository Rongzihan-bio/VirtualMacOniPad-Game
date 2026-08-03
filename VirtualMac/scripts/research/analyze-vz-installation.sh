#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GHIDRA_HOME="${VZ_GHIDRA_HOME:-/Applications/ghidra_12.1.2_PUBLIC}"
HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
SOURCE_VZ="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/Frameworks/Virtualization.framework/Versions/A"
INSTALLATION_XPC="$SOURCE_VZ/XPCServices/com.apple.Virtualization.Installation.xpc"
INSTALLATION_BINARY="$INSTALLATION_XPC/Contents/MacOS/com.apple.Virtualization.Installation"
OUTPUT="$VZ_BUILD_ROOT/analysis/vz-installation"
PROJECT_DIR="$VZ_BUILD_ROOT/ghidra-installation"
PROJECT_NAME="VZInstallation"
THIN_BINARY="$OUTPUT/com.apple.Virtualization.Installation.arm64e"
PROGRAM_NAME="$(basename "$THIN_BINARY")"

need_command codesign
need_command lipo
need_command otool
need_command plutil
need_file "$HEADLESS"
need_file "$INSTALLATION_BINARY"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpStringReferenceFunctions.java"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpTargetFunctions.java"
mkdir -p "$OUTPUT" "$PROJECT_DIR"

lipo "$INSTALLATION_BINARY" -thin arm64e -output "$THIN_BINARY"
plutil -p "$INSTALLATION_XPC/Contents/Info.plist" \
    >"$OUTPUT/info-plist.txt"
otool -L "$INSTALLATION_BINARY" >"$OUTPUT/linked-images.txt"
codesign -d --entitlements :- "$INSTALLATION_XPC" \
    >"$OUTPUT/entitlements.plist" 2>/dev/null || true
strings -a "$INSTALLATION_BINARY" | sort -u \
    >"$OUTPUT/strings.txt"

if [[ ! -f "$PROJECT_DIR/$PROJECT_NAME.gpr" ]]; then
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -import "$THIN_BINARY" -overwrite \
        -analysisTimeoutPerFile 1800 -max-cpu 8
fi

"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process "$PROGRAM_NAME" -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpTargetFunctions.java "$OUTPUT"

"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process "$PROGRAM_NAME" -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpStringReferenceFunctions.java \
        "$OUTPUT/string-reference-functions.c" \
        start_install load_restore_image request_mobile_device_update \
        AMRestorableDeviceRestoreWithError RestoreBundlePath IPSWExtractPath \
        CatalogV2URLs HostMobileDeviceVersion

echo "Virtualization installation analysis: $OUTPUT"
