#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GHIDRA_HOME="${VZ_GHIDRA_HOME:-/Applications/ghidra_12.1.2_PUBLIC}"
HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
PROJECT_DIR="$VZ_BUILD_ROOT/ghidra-metalserializer"
PROJECT_NAME="MetalSerializer"
BINARY="$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/MetalSerializer.framework/MetalSerializer"
REPORT="$VZ_BUILD_ROOT/analysis/metalserializer/invalid-buffer-xrefs.c"
FUNCTION_REPORT="$VZ_BUILD_ROOT/analysis/metalserializer/buffer-reference-functions.c"

need_file "$HEADLESS"
need_file "$BINARY"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpStringXrefs.java"
need_file "$VZ_REPO_ROOT/vz/development/ghidra/DumpNamedFunctions.java"
mkdir -p "$PROJECT_DIR" "$(dirname "$REPORT")"

if [[ ! -f "$PROJECT_DIR/$PROJECT_NAME.gpr" ]]; then
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -import "$BINARY" -analysisTimeoutPerFile 1800 -max-cpu 8
fi
"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process MetalSerializer -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpStringXrefs.java "Got invalid buffer" "$REPORT"
"$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process MetalSerializer -noanalysis \
    -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
    -postScript DumpNamedFunctions.java "BufferForReference" "$FUNCTION_REPORT"

echo "MetalSerializer invalid-buffer report: $REPORT"
echo "MetalSerializer buffer-reference functions: $FUNCTION_REPORT"
