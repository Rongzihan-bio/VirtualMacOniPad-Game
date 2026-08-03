#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

LAST="${1:-10m}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${2:-$VZ_BUILD_ROOT/analysis/ipad-logs/network-$STAMP.logarchive}"
REPORT="${OUT%.logarchive}.txt"
mkdir -p "$(dirname "$OUT")"

if [[ "$EUID" -ne 0 ]]; then
    exec sudo "$0" "$LAST" "$OUT"
fi

/usr/bin/log collect --device --last "$LAST" --output "$OUT"
/usr/bin/log show --archive "$OUT" --style compact --last "$LAST" \
    --predicate 'process == "InternetSharing" OR eventMessage CONTAINS[c] "vmnet" OR eventMessage CONTAINS[c] "IOUserEthernet" OR eventMessage CONTAINS[c] "Netrb"' \
    >"$REPORT"
echo "iPad network log report: $REPORT"
