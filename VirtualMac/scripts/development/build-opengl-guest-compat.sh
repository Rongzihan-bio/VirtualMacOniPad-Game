#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command xcrun
need_command codesign

OUT="${VZ_OPENGL_GUEST_BUILD:-$VZ_BUILD_ROOT/guest-opengl}"
SOURCE="$VZ_REPO_ROOT/vz/guest/OpenGLPVGCompat.m"
PROBE_SOURCE="$VZ_REPO_ROOT/vz/development/probes/opengl-renderer.c"
mkdir -p "$OUT"

for architecture in x86_64 arm64 arm64e; do
    xcrun --sdk macosx clang \
        -arch "$architecture" \
        -dynamiclib -fobjc-arc -fblocks \
        -mmacosx-version-min=12.0 \
        -framework CoreFoundation -framework Foundation \
        -framework IOKit -framework Metal \
        "$SOURCE" \
        -o "$OUT/OpenGLPVGCompat.$architecture.dylib"
done

xcrun lipo -create \
    "$OUT/OpenGLPVGCompat.x86_64.dylib" \
    "$OUT/OpenGLPVGCompat.arm64.dylib" \
    "$OUT/OpenGLPVGCompat.arm64e.dylib" \
    -output "$OUT/OpenGLPVGCompat.dylib"
codesign --force --sign - "$OUT/OpenGLPVGCompat.dylib"

for architecture in arm64 x86_64; do
    xcrun --sdk macosx clang \
        -arch "$architecture" -DGL_SILENCE_DEPRECATION \
        -mmacosx-version-min=12.0 -framework OpenGL \
        "$PROBE_SOURCE" -o "$OUT/opengl-renderer.$architecture"
    codesign --force --sign - "$OUT/opengl-renderer.$architecture"
done

echo "Built $OUT/OpenGLPVGCompat.dylib"
xcrun lipo -archs "$OUT/OpenGLPVGCompat.dylib"
