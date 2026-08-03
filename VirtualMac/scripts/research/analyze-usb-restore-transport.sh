#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GHIDRA_HOME="${VZ_GHIDRA_HOME:-/Applications/ghidra_12.1.2_PUBLIC}"
HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
KDK_KEXT="$VZ_BUILD_ROOT/analysis/kdk-22d68/KDK.pkg/Payload/System/Library/Extensions/IOUSBHostFamily.kext/Contents/PlugIns/AppleUSBUserHCI.kext/Contents/MacOS/AppleUSBUserHCI"
IOUSBHOST="$VZ_BUILD_ROOT/analysis/iousbhost/IOUSBHost.macos.raw"
VMM_FAT="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
OUT="$VZ_BUILD_ROOT/analysis/usb-restore-transport"
INPUTS="$OUT/inputs"
REPORTS="$OUT/reports"
PROJECT_DIR="$OUT/ghidra"
PROJECT_NAME="USBRestoreTransport"
KEXT="$INPUTS/AppleUSBUserHCI.arm64e"
VMM="$INPUTS/com.apple.Virtualization.VirtualMachine.arm64e"
if [[ -n "${VZ_LLVM_LIPO:-}" ]]; then
    LIPO="$VZ_LLVM_LIPO"
elif [[ -x /opt/homebrew/opt/llvm/bin/llvm-lipo ]]; then
    LIPO=/opt/homebrew/opt/llvm/bin/llvm-lipo
else
    LIPO="$(command -v llvm-lipo || command -v lipo || true)"
fi

need_command shasum
[[ -x "$LIPO" ]] || die "missing llvm-lipo or lipo"
need_file "$HEADLESS"
need_file "$KDK_KEXT"
need_file "$IOUSBHOST"
need_file "$VMM_FAT"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpNamedFunctions.java"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpAddressFunctions.java"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpStringReferenceFunctions.java"
mkdir -p "$INPUTS" "$REPORTS" "$PROJECT_DIR"

"$LIPO" "$KDK_KEXT" -thin arm64e -output "$KEXT"
"$LIPO" "$VMM_FAT" -thin arm64e -output "$VMM"
shasum -a 256 "$KEXT" "$IOUSBHOST" "$VMM" >"$OUT/sha256.txt"

if [[ ! -f "$PROJECT_DIR/$PROJECT_NAME.gpr" ]]; then
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -import "$KEXT" "$IOUSBHOST" "$VMM" -overwrite \
        -analysisTimeoutPerFile 1800 -max-cpu 8
fi

run_named() {
    local program="$1"
    local report="$2"
    shift 2
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -process "$program" -noanalysis \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpNamedFunctions.java "$REPORTS/$report" "$@"
}

run_strings() {
    local program="$1"
    local report="$2"
    shift 2
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -process "$program" -noanalysis \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpStringReferenceFunctions.java \
            "$REPORTS/$report" "$@"
}

run_named AppleUSBUserHCI.arm64e apple-usb-user-hci.c \
    AppleUSBUserHCIResources AppleUSBUserHCIUserClient \
    AppleUSBUserHCICommandQueue AppleUSBUserHCI::commandWrite \
    AppleUSBUserHCI::doorbellWrite AppleUSBUserHCITransferQueue \
    AppleUSBUserHCIIsochronousTransferQueue

run_named IOUSBHost.macos.raw iousbhost-controller-interface.c \
    IOUSBHostControllerInterface IOUSBHostCIControllerStateMachine \
    IOUSBHostCIPortStateMachine IOUSBHostCIDeviceStateMachine \
    IOUSBHostCIEndpointStateMachine

run_strings com.apple.Virtualization.VirtualMachine.arm64e vmm-usb-xrefs.c \
    IOUSBHostControllerInterfaceUUID com.apple.virtualization.usb.hci \
    com.apple.virtualization.usb.xhci-host-controller \
    get_usb_controller_location_id AppleUSBUserHCIPort

"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process com.apple.Virtualization.VirtualMachine.arm64e -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpAddressFunctions.java "$REPORTS/vmm-usb-handlers.c" \
        usb_controller_create=0x10016aeb0 \
        usb_command_handler=0x100109e88 \
        usb_doorbell_handler=0x100109ef4 \
        usb_interest_handler=0x100109f94 \
        usb_controller_destroy=0x100109dac \
        get_usb_controller_location_id=0x1000306ac

"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process com.apple.Virtualization.VirtualMachine.arm64e -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpAddressFunctions.java "$REPORTS/vmm-usb-processors.c" \
        command_processor=0x10010a61c \
        doorbell_processor=0x100109f98 \
        location_worker=0x1000e0920

echo "USB restore transport analysis: $OUT"
