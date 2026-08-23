#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="${VZ_NATIVE_BC_PROBE_OUT:-$VM_ROOT/build/development/NativeBCProbe.app}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MODULE_CACHE="${VZ_MODULE_CACHE:-$VM_ROOT/build/module-cache}"

rm -rf "$OUT"
mkdir -p "$OUT" "$MODULE_CACHE"
cp "$VM_ROOT/vz/development/probes/NativeBCProbe-Info.plist" "$OUT/Info.plist"
xcrun --sdk iphoneos metal -fmodules-cache-path="$MODULE_CACHE" \
    -std=ios-metal2.4 -mios-version-min=14.5 \
    -c "$VM_ROOT/vz/development/probes/native-bc-probe.metal" \
    -o "$OUT/native-bc-probe.air"
xcrun --sdk iphoneos metallib "$OUT/native-bc-probe.air" \
    -o "$OUT/default.metallib"
rm "$OUT/native-bc-probe.air"
xcrun --sdk iphoneos clang -fblocks -fmodules-cache-path="$MODULE_CACHE" \
    -arch arm64 \
    -miphoneos-version-min=14.5 -isysroot "$SDK" \
    -framework Foundation -framework Metal -framework UIKit \
    "$VM_ROOT/vz/host/native_bc_texture_support.m" \
    "$VM_ROOT/vz/host/metalshim.m" \
    "$VM_ROOT/vz/development/probes/native-bc-probe-app.m" \
    -o "$OUT/NativeBCProbe"
ldid -S"$VM_ROOT/vz/patches/vmm.ents.xml" \
    "$OUT/NativeBCProbe"
echo "$OUT"
