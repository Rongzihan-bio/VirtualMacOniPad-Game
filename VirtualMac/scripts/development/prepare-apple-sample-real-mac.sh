#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SAMPLE_COMMIT="d7c5d919a3ff1364f9114ad48f71b6b63a8a23f2"
: "${VZ_APPLE_SAMPLE_SOURCE:?set VZ_APPLE_SAMPLE_SOURCE to the Apple sample checkout}"
: "${VZ_REAL_MAC_WORK:?set VZ_REAL_MAC_WORK to an absolute work directory on the reference Mac}"
LOCAL_SAMPLE="$VZ_APPLE_SAMPLE_SOURCE"
REMOTE_ROOT="$VZ_REAL_MAC_WORK"
REMOTE_SOURCE="$REMOTE_ROOT/RunningMacOSInAVirtualMachineOnAppleSilicon"
REMOTE_DERIVED_DATA="$REMOTE_ROOT/DerivedData"
ARCHIVE="$(mktemp -t apple-vz-sample.XXXXXX.tar)"
trap 'rm -f "$ARCHIVE"' EXIT

need_command git
need_command sshpass
[[ -d "$LOCAL_SAMPLE/.git" ]] || die "missing Apple sample repository: $LOCAL_SAMPLE"
[[ "$(git -C "$LOCAL_SAMPLE" rev-parse "$SAMPLE_COMMIT")" == "$SAMPLE_COMMIT" ]] ||
    die "Apple sample commit is not available locally: $SAMPLE_COMMIT"

git -C "$LOCAL_SAMPLE" archive --format=tar -o "$ARCHIVE" "$SAMPLE_COMMIT"
real_mac_ssh "mkdir -p '$REMOTE_ROOT' '$REMOTE_SOURCE'"
real_mac_ssh_args
real_mac_scp "$ARCHIVE" "$REAL_MAC_TARGET:$REMOTE_ROOT/apple-vz-sample.tar"

remote_script="$(cat <<EOF
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
test "\$(xcodebuild -version | head -1)" = "Xcode 14.2"
rm -rf '$REMOTE_SOURCE'
mkdir -p '$REMOTE_SOURCE'
tar -xf '$REMOTE_ROOT/apple-vz-sample.tar' -C '$REMOTE_SOURCE'
rm -f '$REMOTE_ROOT/apple-vz-sample.tar'
grep -Fq '64ull * 1024ull * 1024ull * 1024ull' \
  '$REMOTE_SOURCE/Objective-C/InstallationTool/MacOSVirtualMachineInstaller.m'
xcodebuild -project '$REMOTE_SOURCE/macOSVirtualMachineSampleApp.xcodeproj' \
  -scheme InstallationTool-Objective-C -configuration Debug \
  -derivedDataPath '$REMOTE_DERIVED_DATA' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
xcodebuild -project '$REMOTE_SOURCE/macOSVirtualMachineSampleApp.xcodeproj' \
  -scheme macOSVirtualMachineSampleApp-Objective-C -configuration Debug \
  -derivedDataPath '$REMOTE_DERIVED_DATA' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
APP='$REMOTE_DERIVED_DATA/Build/Products/Debug/macOSVirtualMachineSampleApp-Objective-C.app'
INSTALLER='$REMOTE_DERIVED_DATA/Build/Products/Debug/InstallationTool-Objective-C'
file "\$APP/Contents/MacOS/macOSVirtualMachineSampleApp-Objective-C"
file "\$INSTALLER"
codesign --verify --strict "\$APP"
codesign --verify --strict "\$INSTALLER"
EOF
)"

real_mac_ssh "$remote_script"
echo "built pinned Objective-C Apple sample on the real Mac"
echo "source commit: $SAMPLE_COMMIT"
echo "disk size in pinned installer: 64 GiB"
