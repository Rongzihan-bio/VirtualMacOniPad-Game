#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SOURCE_DIRECTORY="${1:-}"
if [[ -z "$SOURCE_DIRECTORY" || ! -d "$SOURCE_DIRECTORY" ]]; then
    echo "usage: $0 /path/to/macOS-wallpapers" >&2
    exit 2
fi

OUTPUT_DIRECTORY="$VZ_REPO_ROOT/assets/wallpapers"
mkdir -p "$OUTPUT_DIRECTORY"

render() {
    local pattern="$1" output="$2" source
    source="$(find "$SOURCE_DIRECTORY" -maxdepth 1 -type f -iname "$pattern" -print -quit)"
    [[ -n "$source" ]] || { echo "missing wallpaper matching $pattern" >&2; exit 1; }
    sips -Z 1280 -s format jpeg -s formatOptions 72 "$source" \
        --out "$OUTPUT_DIRECTORY/$output.jpg" >/dev/null
}

render '*Monterey*' monterey
render '*Ventura*' ventura
render '*Sonoma*' sonoma
render '*Sequoia*' sequoia
render '*Tahoe*' tahoe
render '*Golden*Gate*' golden-gate
render '*Tiger*' tiger

du -h "$OUTPUT_DIRECTORY"/*.jpg
