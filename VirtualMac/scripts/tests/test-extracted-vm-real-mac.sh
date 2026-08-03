#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK on the reference Mac}"
: "${VZ_REAL_MAC_VM:?set VZ_REAL_MAC_VM to the VM bundle on the reference Mac}"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
LOCAL_FRAMEWORKS="$VZ_BUILD_ROOT/frameworks/bundles/macos"
LOCAL_SHIM="$VZ_REPO_ROOT/vz/shims/pvg_metallib_shim.m"
REMOTE_FRAMEWORKS="$REMOTE_ROOT/frameworks"
REMOTE_TEST_ROOT="$REMOTE_ROOT/ExtractedFrameworkTest"
BUILT_APP="$REMOTE_ROOT/DerivedData/Build/Products/Debug/macOSVirtualMachineSampleApp-Objective-C.app"
TEST_APP="$REMOTE_TEST_ROOT/macOSVirtualMachineSampleApp-Objective-C.app"
APP_EXECUTABLE="$TEST_APP/Contents/MacOS/macOSVirtualMachineSampleApp-Objective-C"
VMM="$TEST_APP/Contents/XPCServices/com.apple.Virtualization.VirtualMachine.xpc"
APP_LOG="$REMOTE_ROOT/extracted-framework-app.log"
HOST_DYLD_LOG="$REMOTE_ROOT/host-dyld.log"
VMM_DYLD_LOG="$REMOTE_ROOT/vmm-dyld.log"
RESULT_DIR="$VZ_BUILD_ROOT/validation"
RESULT="$RESULT_DIR/extracted-vm-real-mac.txt"
FRAMEWORK_ARCHIVE="$(mktemp -t apple-vz-frameworks.XXXXXX.tar.gz)"
trap 'rm -f "$FRAMEWORK_ARCHIVE"' EXIT

need_command sshpass
need_command tar
need_file "$LOCAL_SHIM"
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    need_file "$LOCAL_FRAMEWORKS/$name.framework/Versions/A/$name"
done
need_file \
    "$LOCAL_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/Resources/default.metallib"
need_file \
    "$LOCAL_FRAMEWORKS/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.EventTap.xpc/Contents/MacOS/com.apple.Virtualization.EventTap"
need_file \
    "$LOCAL_FRAMEWORKS/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

mkdir -p "$RESULT_DIR"
tar -C "$LOCAL_FRAMEWORKS" -czf "$FRAMEWORK_ARCHIVE" \
    Hypervisor.framework \
    ParavirtualizedGraphics.framework \
    Virtualization.framework

active="$(real_mac_ssh \
    "pgrep -f '$APP_EXECUTABLE|$VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine' || true")"
[[ -z "$active" ]] ||
    die "the extracted-framework test VM is already active on the real Mac (PIDs: $active)"

real_mac_ssh \
    "mkdir -p '$REMOTE_ROOT' '$REMOTE_FRAMEWORKS'; rm -rf \
    '$REMOTE_FRAMEWORKS/Hypervisor.framework' \
    '$REMOTE_FRAMEWORKS/ParavirtualizedGraphics.framework' \
    '$REMOTE_FRAMEWORKS/Virtualization.framework' \
    '$REMOTE_TEST_ROOT'"
real_mac_ssh_args
real_mac_scp "$FRAMEWORK_ARCHIVE" \
    "$REAL_MAC_TARGET:$REMOTE_ROOT/frameworks.tar.gz"
real_mac_scp "$LOCAL_SHIM" \
    "$REAL_MAC_TARGET:$REMOTE_ROOT/pvg_metallib_shim.m"

prepare_script="$(cat <<EOF
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
test -d '$VZ_REAL_MAC_VM'
test -d '$BUILT_APP'
test -x '$BUILT_APP/Contents/MacOS/macOSVirtualMachineSampleApp-Objective-C'
test "\$(xcodebuild -version | head -1)" = "Xcode 14.2"

tar -xzf '$REMOTE_ROOT/frameworks.tar.gz' -C '$REMOTE_FRAMEWORKS'
rm -f '$REMOTE_ROOT/frameworks.tar.gz'
codesign --verify --deep --strict '$REMOTE_FRAMEWORKS/Virtualization.framework'

mkdir -p '$REMOTE_TEST_ROOT'
ditto '$BUILT_APP' '$TEST_APP'
mkdir -p '$TEST_APP/Contents/XPCServices'
ditto \
  '$REMOTE_FRAMEWORKS/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.EventTap.xpc' \
  '$TEST_APP/Contents/XPCServices/com.apple.Virtualization.EventTap.xpc'
ditto \
  '$REMOTE_FRAMEWORKS/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc' \
  '$VMM'

mkdir -p '$VMM/Contents/Frameworks' '$VMM/Contents/Resources'
ditto '$REMOTE_FRAMEWORKS/Hypervisor.framework' \
  '$VMM/Contents/Frameworks/Hypervisor.framework'
ditto '$REMOTE_FRAMEWORKS/ParavirtualizedGraphics.framework' \
  '$VMM/Contents/Frameworks/ParavirtualizedGraphics.framework'
cp \
  '$REMOTE_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/Resources/default.metallib' \
  '$VMM/Contents/Resources/default.metallib'

xcrun clang -arch arm64e -fobjc-arc -dynamiclib \
  -framework Foundation -framework Metal \
  '$REMOTE_ROOT/pvg_metallib_shim.m' \
  -o '$VMM/Contents/Frameworks/PVGMetallibShim.dylib'
codesign --force --sign - \
  '$VMM/Contents/Frameworks/PVGMetallibShim.dylib'
for framework in \
  '$VMM/Contents/Frameworks/Hypervisor.framework' \
  '$VMM/Contents/Frameworks/ParavirtualizedGraphics.framework'; do
  codesign --force --sign - "\$framework"
done

PLIST='$VMM/Contents/Info.plist'
/usr/libexec/PlistBuddy \
  -c 'Delete :XPCService:EnvironmentVariables' "\$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
  -c 'Add :XPCService:EnvironmentVariables dict' "\$PLIST"
/usr/libexec/PlistBuddy \
  -c 'Add :XPCService:EnvironmentVariables:DYLD_FRAMEWORK_PATH string $VMM/Contents/Frameworks' "\$PLIST"
/usr/libexec/PlistBuddy \
  -c 'Add :XPCService:EnvironmentVariables:DYLD_INSERT_LIBRARIES string $VMM/Contents/Frameworks/PVGMetallibShim.dylib' "\$PLIST"
/usr/libexec/PlistBuddy \
  -c 'Add :XPCService:EnvironmentVariables:DYLD_PRINT_LIBRARIES string 1' "\$PLIST"
/usr/libexec/PlistBuddy \
  -c 'Add :XPCService:EnvironmentVariables:DYLD_PRINT_TO_FILE string $VMM_DYLD_LOG' "\$PLIST"
/usr/libexec/PlistBuddy \
  -c 'Add :XPCService:EnvironmentVariables:NSUnbufferedIO string YES' "\$PLIST"

codesign --force --sign - --deep \
  --preserve-metadata=entitlements,flags,runtime '$VMM'
codesign --force --sign - --deep \
  --preserve-metadata=entitlements,flags,runtime '$TEST_APP'
codesign --verify --deep --strict '$TEST_APP'
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f '$TEST_APP'
rm -f '$APP_LOG' '$HOST_DYLD_LOG' '$VMM_DYLD_LOG'
EOF
)"
real_mac_ssh "$prepare_script"

launch_script="$(cat <<EOF
set -eu
DYLD_FRAMEWORK_PATH='$REMOTE_FRAMEWORKS' \
DYLD_PRINT_LIBRARIES=1 \
DYLD_PRINT_TO_FILE='$HOST_DYLD_LOG' \
nohup '$APP_EXECUTABLE' >'$APP_LOG' 2>&1 </dev/null &
launched_pid=\$!
i=0
app_pid=
while test "\$i" -lt 30; do
  app_pid=\$(pgrep -n -f '$APP_EXECUTABLE' || true)
  test -n "\$app_pid" && break
  sleep 1
  i=\$((i + 1))
done
test -n "\$app_pid"
test "\$app_pid" = "\$launched_pid"
i=0
vmm_pid=
while test "\$i" -lt 60; do
  vmm_pid=\$(pgrep -n -f \
    '$VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine' || true)
  test -n "\$vmm_pid" && break
  test -e '$APP_LOG' && \
    grep -q 'Internal Virtualization error' '$APP_LOG' && exit 1
  sleep 1
  i=\$((i + 1))
done
test -n "\$vmm_pid"
sleep 20
kill -0 "\$app_pid"
kill -0 "\$vmm_pid"
test ! -s '$APP_LOG'
grep -Fq \
  '$REMOTE_FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization' \
  '$HOST_DYLD_LOG'
grep -Fq \
  '$VMM/Contents/Frameworks/Hypervisor.framework/Versions/A/Hypervisor' \
  '$VMM_DYLD_LOG'
grep -Fq \
  '$VMM/Contents/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics' \
  '$VMM_DYLD_LOG'
grep -Fq \
  '$VMM/Contents/Frameworks/PVGMetallibShim.dylib' \
  '$VMM_DYLD_LOG'
printf 'APP_PID\\t%s\\nVMM_PID\\t%s\\n' "\$app_pid" "\$vmm_pid"
EOF
)"

set +e
real_mac_ssh "$launch_script" 2>&1 | tee "$RESULT"
status=${PIPESTATUS[0]}
set -e
[[ "$status" == 0 ]] ||
    die "the extracted-framework VM failed to remain alive"

app_pid="$(awk -F $'\t' '$1 == "APP_PID" { print $2 }' "$RESULT")"
vmm_pid="$(awk -F $'\t' '$1 == "VMM_PID" { print $2 }' "$RESULT")"
[[ -n "$app_pid" && -n "$vmm_pid" ]] ||
    die "failed to record the host and VMM PIDs"

inspect_script="$(cat <<EOF
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun lldb --batch -p '$app_pid' \
  -o 'image list -t -f Virtualization' \
  -o detach
EOF
)"
echo "HOST_IMAGES" | tee -a "$RESULT"
set +e
real_mac_ssh "$inspect_script" 2>&1 | tee -a "$RESULT"
status=${PIPESTATUS[0]}
set -e
[[ "$status" == 0 ]] || die "LLDB inspection of the sample app failed"

echo "VMM_IMAGES" | tee -a "$RESULT"
set +e
printf '%s\n' "$VZ_REAL_MAC_PASSWORD" |
    real_mac_ssh \
        "sudo -S -p '' env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun lldb --batch -p '$vmm_pid' \
        -o 'image list -t -f Hypervisor ParavirtualizedGraphics' \
        -o 'image list -t -f PVGMetallibShim.dylib' \
        -o detach" 2>&1 | tee -a "$RESULT"
status=${PIPESTATUS[1]}
set -e
[[ "$status" == 0 ]] || die "root LLDB inspection of the Apple VMM failed"

grep -Fq "$REMOTE_FRAMEWORKS/Virtualization.framework" "$RESULT" ||
    die "host app did not load the extracted Virtualization framework"
grep -Fq "$VMM/Contents/Frameworks/Hypervisor.framework" "$RESULT" ||
    die "Apple VMM did not load the extracted Hypervisor framework"
grep -Fq "$VMM/Contents/Frameworks/ParavirtualizedGraphics.framework" "$RESULT" ||
    die "Apple VMM did not load the extracted ParavirtualizedGraphics framework"
grep -Fq "$VMM/Contents/Frameworks/PVGMetallibShim.dylib" "$RESULT" ||
    die "Apple VMM did not load the PVG metallib shim"
if grep -Eq \
    '/System/Library/Frameworks/(Virtualization|Hypervisor|ParavirtualizedGraphics)\.framework/' \
    "$RESULT"; then
    die "LLDB reported a system copy of a framework that must be extracted"
fi

real_mac_ssh "kill -0 '$app_pid'; kill -0 '$vmm_pid'"
echo "extracted 22D68 Apple virtualization stack is loaded and running"
echo "the real-Mac GUI was left open for visual confirmation"
echo "evidence: $RESULT"
