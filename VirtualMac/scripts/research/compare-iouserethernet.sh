#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

MAC_KERNEL="${VZ_MAC_KERNELCACHE:-$VZ_BUILD_ROOT/inputs/macos/22D68__MacBookAir10,1/kernelcache.release.MacBookAir10,1_MacBookPro17,1_Macmini9,1_iMac21,1_2}"
IPAD_KERNEL="${VZ_IPAD_KERNELCACHE:-$VZ_BUILD_ROOT/inputs/ipados/20D67__iPad14,6/kernelcache.release.iPad14,3_4_5_6}"
OUT="$VZ_BUILD_ROOT/analysis/iouserethernet"
INPUTS="$OUT/inputs"
REPORTS="$OUT/reports"
PROJECT_DIR="$OUT/ghidra"
PROJECT_NAME="IOUserEthernetComparison"
HEADLESS="${VZ_GHIDRA_HOME:-/Applications/ghidra_12.1.2_PUBLIC}/support/analyzeHeadless"
GHIDRA_SCRIPT="$VZ_REPO_ROOT/vz/development/ghidra/DumpIOUserEthernetAuthorization.java"

IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
need_file "$IPSW"
need_file "$MAC_KERNEL"
need_file "$IPAD_KERNEL"
need_file "$HEADLESS"
need_file "$GHIDRA_SCRIPT"
mkdir -p "$OUT/macos" "$OUT/ipados" "$INPUTS" "$REPORTS" "$PROJECT_DIR"

"$IPSW" kernel extract "$MAC_KERNEL" com.apple.iokit.IOUserEthernet \
    --imports --force -o "$OUT/macos"
"$IPSW" kernel extract "$IPAD_KERNEL" com.apple.iokit.IOUserEthernet \
    --imports --force -o "$OUT/ipados"
cp "$OUT/macos/com.apple.iokit.IOUserEthernet" \
    "$INPUTS/IOUserEthernet.macos-22D68"
cp "$OUT/ipados/com.apple.iokit.IOUserEthernet" \
    "$INPUTS/IOUserEthernet.ipados-20D67"

for platform in macos-22D68 ipados-20D67; do
    binary="$INPUTS/IOUserEthernet.$platform"
    {
        echo "file: $binary"
        file "$binary"
        shasum -a 256 "$binary"
        echo "authorization imports and strings:"
        nm -nm "$binary" 2>/dev/null | \
            grep -E 'clientHasPrivilege|AMFIEntitlementGetBool' || true
        strings -a "$binary" | \
            grep -E 'ethernet.user-access|not entitled' || true
    } >"$REPORTS/$platform-summary.txt"
done

if [[ ! -f "$PROJECT_DIR/$PROJECT_NAME.gpr" ]]; then
    "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
        -import "$INPUTS/IOUserEthernet.macos-22D68" \
                "$INPUTS/IOUserEthernet.ipados-20D67" \
        -analysisTimeoutPerFile 1800 -max-cpu 8 \
        -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
        -postScript DumpIOUserEthernetAuthorization.java "$REPORTS"
else
    for program in IOUserEthernet.macos-22D68 \
                   IOUserEthernet.ipados-20D67; do
        "$HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
            -process "$program" -noanalysis \
            -scriptPath "$VZ_REPO_ROOT/vz/development/ghidra" \
            -postScript DumpIOUserEthernetAuthorization.java "$REPORTS"
    done
fi

echo "IOUserEthernet comparison reports: $REPORTS"
