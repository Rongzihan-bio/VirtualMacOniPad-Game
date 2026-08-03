#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GHIDRA_HOME="${VZ_GHIDRA_HOME:-/Applications/ghidra_12.1.2_PUBLIC}"
HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
PROJECT_DIR="$VZ_BUILD_ROOT/ghidra"
PROJECT_NAME="VirtualMac"
REPORT_DIR="$PROJECT_DIR/reports"
VIRTUALIZATION="$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/Virtualization.framework/Versions/A/Virtualization"
VMM="$VZ_BUILD_ROOT/ipad-vm/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
PVG="$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
VMNET="$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/vmnet.framework/vmnet"
INTERNET_SHARING="$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing"

need_file "$HEADLESS"
need_file "$VIRTUALIZATION"
need_file "$VMM"
need_file "$PVG"
need_file "$VMNET"
need_file "$INTERNET_SHARING"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpTargetFunctions.java"
mkdir -p "$PROJECT_DIR" "$REPORT_DIR"

if [[ -f "$PROJECT_DIR/$PROJECT_NAME.gpr" ]]; then
    if ! "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -process ParavirtualizedGraphics -noanalysis \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpTargetFunctions.java "$REPORT_DIR"; then
        "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
            -import "$PVG" -analysisTimeoutPerFile 1800 -max-cpu 8 \
            -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
            -postScript DumpTargetFunctions.java "$REPORT_DIR"
    fi
    for program in Virtualization com.apple.Virtualization.VirtualMachine; do
        "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
            -process "$program" -noanalysis \
            -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
            -postScript DumpTargetFunctions.java "$REPORT_DIR"
    done
    if ! "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -process vmnet -noanalysis \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpTargetFunctions.java "$REPORT_DIR"; then
        "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
            -import "$VMNET" -analysisTimeoutPerFile 1800 -max-cpu 8 \
            -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
            -postScript DumpTargetFunctions.java "$REPORT_DIR"
    fi
    if ! "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -process InternetSharing -noanalysis \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpTargetFunctions.java "$REPORT_DIR"; then
        "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
            -import "$INTERNET_SHARING" -analysisTimeoutPerFile 1800 -max-cpu 8 \
            -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
            -postScript DumpTargetFunctions.java "$REPORT_DIR"
    fi
else
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -import "$VIRTUALIZATION" "$VMM" "$PVG" "$VMNET" "$INTERNET_SHARING" \
        -overwrite -analysisTimeoutPerFile 1800 -max-cpu 8 \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpTargetFunctions.java "$REPORT_DIR"
fi

echo "Ghidra project: $PROJECT_DIR/$PROJECT_NAME.gpr"
echo "Targeted decompilations: $REPORT_DIR"
