#!/bin/bash

# Reconstruct the XNU-20-aligned Hypervisor runtime used only on iPadOS 14.
# Ventura Virtualization/PVG remain shared with the newer-host configurations.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
PYTHON="$VZ_BUILD_ROOT/toolchain/venv/bin/python3"
DYLDEX="$VZ_BUILD_ROOT/toolchain/venv/bin/dyldex"
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
BIG_SUR_DSC="$VZ_BUILD_ROOT/inputs/macos11/20G165__MacOS/dyld_shared_cache_arm64e"
VENTURA_DSC="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
OUT="$VZ_BUILD_ROOT/ipados14-hypervisor"
CACHE="$VZ_BUILD_ROOT/cache/ipados14-hypervisor"
BIG_SUR_IMAGE=/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor
LIBCXX_IMAGE=/usr/lib/libc++.1.dylib
BIG_SUR_RAW="$CACHE/Hypervisor.raw"
BIG_SUR_PROTO="$CACHE/Hypervisor.proto"
BIG_SUR="$OUT/HypervisorBigSur"
LIBCXX_RAW="$CACHE/libc++.1.dylib.raw"
LIBCXX_PROTO="$CACHE/libc++.1.dylib.proto"
LIBCXX="$OUT/LibCxx.dylib"
LIBSYSTEM14="$OUT/LibSystemCompat.dylib"
FACADE="$OUT/Hypervisor"
VMM_ENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"
PATCH_CSTRING="$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py"

for file in "$PYTHON" "$DYLDEX" "$IPSW" "$BIG_SUR_DSC" \
    "$VENTURA_DSC" "$VMM_ENTS" "$PATCH_CSTRING" \
    "$VZ_REPO_ROOT/vz/uncache.py" \
    "$VZ_REPO_ROOT/vz/host/hypervisor14_compat.c" \
    "$VZ_REPO_ROOT/vz/host/hypervisor14_support.m"; do
    need_file "$file"
done
need_command codesign
need_command ldid
need_command xcrun
mkdir -p "$OUT" "$CACHE"

if [[ ! -f "$BIG_SUR_RAW" ]]; then
    "$PYTHON" "$DYLDEX" -e "$BIG_SUR_IMAGE" -o "$BIG_SUR_RAW" "$BIG_SUR_DSC"
fi
if [[ ! -f "$BIG_SUR" || "$VZ_REPO_ROOT/vz/uncache.py" -nt "$BIG_SUR" ||
      "$BIG_SUR_RAW" -nt "$BIG_SUR" ]]; then
    VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
        "$BIG_SUR_DSC" "$BIG_SUR_IMAGE" "$BIG_SUR_RAW" \
        "$BIG_SUR_PROTO" compact
    "$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
        "$BIG_SUR_PROTO" "$BIG_SUR" 14.5
    "$PYTHON" "$PATCH_CSTRING" "$BIG_SUR" \
        /System/Library/Frameworks/Hypervisor.framework/Hypervisor \
        @loader_path/HypervisorBigSur
    codesign --force --sign - "$BIG_SUR"
fi
if xcrun dyld_info -imports "$BIG_SUR" | grep -q '__got\.'; then
    die "Big Sur Hypervisor contains unresolved shared-cache GOT labels"
fi

# Ventura's VMM uses its matching libc++ ABI. It is selected by the iPadOS 14
# VMM only and does not alter the iPadOS 15/16 images.
if [[ ! -f "$LIBCXX_RAW" ]]; then
    "$PYTHON" "$DYLDEX" -e "$LIBCXX_IMAGE" -o "$LIBCXX_RAW" "$VENTURA_DSC"
fi
if [[ ! -f "$LIBCXX" || "$VZ_REPO_ROOT/vz/uncache.py" -nt "$LIBCXX" ||
      "$LIBCXX_RAW" -nt "$LIBCXX" ]]; then
    VZ_IPSW="$IPSW" "$PYTHON" "$VZ_REPO_ROOT/vz/uncache.py" \
        "$VENTURA_DSC" "$LIBCXX_IMAGE" "$LIBCXX_RAW" \
        "$LIBCXX_PROTO" compact
    "$PYTHON" "$VZ_REPO_ROOT/vz/stamp_ios.py" \
        "$LIBCXX_PROTO" "$LIBCXX" 14.5
    "$PYTHON" "$PATCH_CSTRING" "$LIBCXX" \
        /usr/lib/libc++.1.dylib @rpath/LibCxx.dylib
    codesign --force --sign - "$LIBCXX"
fi

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=14.5 -isysroot "$SDK" \
    -dynamiclib \
    -Wl,-reexport_library,"$SDK/usr/lib/libSystem.B.tbd" \
    -lobjc \
    -install_name @rpath/LibSystem14 \
    "$VZ_REPO_ROOT/vz/host/libsystem15_compat.c" \
    "$VZ_REPO_ROOT/vz/host/hypervisor14_support.m" \
    -o "$LIBSYSTEM14"
ldid -S"$VMM_ENTS" "$LIBSYSTEM14"

xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min=14.5 -isysroot "$SDK" \
    -dynamiclib \
    -Wl,-not_for_dyld_shared_cache \
    -Wl,-reexport_library,"$BIG_SUR" \
    -Wl,-reexport_library,"$LIBSYSTEM14" \
    -Wl,-rpath,@loader_path/../../.. \
    -install_name /System/Library/Frameworks/Hypervisor.framework/Hypervisor \
    "$VZ_REPO_ROOT/vz/host/hypervisor14_compat.c" \
    -o "$FACADE"
ldid -S"$VMM_ENTS" "$FACADE"

otool -L "$FACADE" | grep -Fq '@loader_path/HypervisorBigSur' ||
    die "iPadOS 14 Hypervisor facade is missing Big Sur implementation"
otool -L "$FACADE" | grep -Fq '@rpath/LibSystem14' ||
    die "iPadOS 14 Hypervisor facade is missing libSystem compatibility"

echo "iPadOS 14 Hypervisor runtime built: $OUT"
