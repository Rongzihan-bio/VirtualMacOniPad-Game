#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DSC="$VZ_BUILD_ROOT/inputs/macos11/20G165__MacOS/dyld_shared_cache_arm64e"
VMNET="$VZ_BUILD_ROOT/ipad-vmnet14/vmnet.framework"
NETRB="$VZ_BUILD_ROOT/ipad-netrb14/Netrb.framework"

need_command codesign
need_command otool
need_file "$DSC"
need_file "$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
need_file "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py"

VZ_MACOS_DSC="$DSC" \
VZ_VMNET_OUTPUT="$VMNET" \
VZ_VMNET_WORK_DIR="$VZ_BUILD_ROOT/ipad-vmnet14" \
VZ_IPADOS_MIN_VERSION=14.5 \
    "$SCRIPT_DIR/build-ipad-vmnet.sh"

VZ_MACOS_DSC="$DSC" \
VZ_NETRB_OUTPUT="$NETRB" \
VZ_NETRB_WORK_DIR="$VZ_BUILD_ROOT/ipad-netrb14" \
VZ_NETRB_PATCH_LOOKUP=0 \
VZ_IPADOS_MIN_VERSION=14.5 \
    "$SCRIPT_DIR/build-ipad-netrb.sh"

# Big Sur uses the system private-framework install name. Keep the extracted
# framework next to vmnet so the iPad package remains self-contained.
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py" "$VMNET/vmnet" \
    /System/Library/PrivateFrameworks/Netrb.framework/Netrb \
    @loader_path/../Netrb.framework/Netrb
codesign --force --sign - "$VMNET/vmnet"
codesign --verify --strict "$VMNET/vmnet"
codesign --verify --strict "$NETRB/Netrb"
otool -L "$VMNET/vmnet" | grep -Fq \
    '@loader_path/../Netrb.framework/Netrb' ||
    die "iPadOS 14 vmnet is not linked to its bundled matching Netrb"

echo "iPadOS 14 Big Sur-aligned vmnet stack built"
