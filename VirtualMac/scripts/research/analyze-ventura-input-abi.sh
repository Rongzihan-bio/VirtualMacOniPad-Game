#!/bin/bash

# Reproduce the input-device boundary analysis against the extracted Ventura
# Virtualization.framework. The generated reports are intentionally kept under
# build/ so they do not make the source tree depend on Ghidra output.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GHIDRA_HOME="${VZ_GHIDRA_HOME:-/Applications/ghidra_12.1.2_PUBLIC}"
HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
PROJECT_DIR="$VZ_BUILD_ROOT/ghidra"
PROJECT_NAME="VirtualMac"
VIRTUALIZATION="$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/Virtualization.framework/Versions/A/Virtualization"
VMM="$VZ_BUILD_ROOT/ipad-vm/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
OUT="$VZ_BUILD_ROOT/analysis/ventura-input-abi"

need_file "$HEADLESS"
need_file "$PROJECT_DIR/$PROJECT_NAME.gpr"
need_file "$VIRTUALIZATION"
need_file "$VMM"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpNamedFunctions.java"
need_command strings
mkdir -p "$OUT"

"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process Virtualization -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpNamedFunctions.java \
    "$OUT/pointing-device.c" \
    '_VZPointingDevice::'

"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process Virtualization -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpNamedFunctions.java \
    "$OUT/device-construction.c" \
    'VZMacTrackpadConfiguration::' \
    '_VZAppleTouchScreenConfiguration::' \
    '_VZMultiTouchDevice::'

strings -a "$VMM" | awk \
    '/^process_(symbolic_hot_key|zoom_toggle|scale|rotation|scroll_wheel)_events$/ { print }' \
    | sort -u >"$OUT/pointing-rpc-names.txt"

grep '^===== _VZPointingDevice::' "$OUT/pointing-device.c" \
    >"$OUT/pointing-methods.txt"

printf 'Ventura input ABI reports:\n'
printf '  %s\n' \
    "$OUT/pointing-methods.txt" \
    "$OUT/pointing-rpc-names.txt" \
    "$OUT/device-construction.c"
cat "$OUT/pointing-methods.txt"
printf '\nVMM pointing RPC names:\n'
cat "$OUT/pointing-rpc-names.txt"
