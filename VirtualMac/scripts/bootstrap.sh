#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command brew
need_command git
need_command patch
need_command python3

install_formula() {
    local formula="$1"
    local command_name="${2:-$1}"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        brew install "$formula"
    fi
}

install_formula ldid
install_formula libimobiledevice idevice_id
install_formula go
if ! command -v sshpass >/dev/null 2>&1; then
    brew install hudochenkov/sshpass/sshpass
fi

TOOLCHAIN="$VZ_BUILD_ROOT/toolchain"
VENV="$TOOLCHAIN/venv"
BIN="$TOOLCHAIN/bin"
IPSW_SRC="$TOOLCHAIN/ipsw-src"
IPSW_COMMIT="b7229017247457d7cf310c942dd9910e485624b3"
mkdir -p "$TOOLCHAIN" "$BIN"

if [[ ! -x "$VENV/bin/python3" ]]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/python3" -m pip install --disable-pip-version-check \
    --requirement "$VZ_REPO_ROOT/requirements.lock.txt"

SITE_PACKAGES="$("$VENV/bin/python3" -c \
    'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
OBJC_FIXER="$SITE_PACKAGES/DyldExtractor/converter/objc_fixer.py"
need_file "$OBJC_FIXER"
if ! grep -q '_buildLocalProtocolMap' "$OBJC_FIXER"; then
    patch --batch --forward -p1 -d "$SITE_PACKAGES" \
        < "$VZ_REPO_ROOT/patches/dyldextractor-2.2.2-arm64e.patch"
fi
grep -q 'relativeMethodSelectorBaseAddressOffset' "$OBJC_FIXER" ||
    die "DyldExtractor relative-selector patch is missing"
grep -q '_buildLocalProtocolMap' "$OBJC_FIXER" ||
    die "DyldExtractor protocol-localization patch is missing"

if [[ ! -d "$IPSW_SRC/.git" ]]; then
    git clone https://github.com/blacktop/ipsw.git "$IPSW_SRC"
fi
git -C "$IPSW_SRC" fetch --quiet origin "$IPSW_COMMIT"
git -C "$IPSW_SRC" checkout --detach --quiet "$IPSW_COMMIT"
install -m 0644 \
    "$VZ_REPO_ROOT/vz/ipsw_patches/dyld_a2sb.go" \
    "$IPSW_SRC/cmd/ipsw/cmd/dyld/dyld_a2sb.go"
(
    cd "$IPSW_SRC"
    CGO_ENABLED=1 go build -o "$BIN/ipsw-a2sb" ./cmd/ipsw
)
"$BIN/ipsw-a2sb" dyld a2sb --help >/dev/null

cat <<EOF
toolchain ready:
  Python: $VENV/bin/python3
  dyldex: $VENV/bin/dyldex
  ipsw-a2sb: $BIN/ipsw-a2sb
  ipsw source: $IPSW_COMMIT
EOF
