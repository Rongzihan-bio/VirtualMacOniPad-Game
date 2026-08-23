#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command sshpass
: "${VZ_GUEST_HOST:?set VZ_GUEST_HOST to the Virtual Mac IP address}"
: "${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER}"
VZ_GUEST_PORT="${VZ_GUEST_PORT:-22}"
GUEST_TARGET="$VZ_GUEST_USER@$VZ_GUEST_HOST"
SSH_OPTIONS=(
    -p "$VZ_GUEST_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
)
SCP_OPTIONS=(
    -P "$VZ_GUEST_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
)

guest_ssh() {
    sshpass -p "$VZ_GUEST_PASSWORD" ssh \
        "${SSH_OPTIONS[@]}" "$GUEST_TARGET" "$@"
}

guest_scp() {
    sshpass -p "$VZ_GUEST_PASSWORD" scp \
        "${SCP_OPTIONS[@]}" "$@"
}

if [[ "${1:-}" == --uninstall ]]; then
    guest_ssh "
        uid=\$(id -u)
        printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S \
            launchctl asuser \"\$uid\" launchctl unsetenv \
            DYLD_INSERT_LIBRARIES || true
        defaults delete com.apple.loginwindow TALLogoutSavesState \
            2>/dev/null || true
        defaults delete com.apple.loginwindow \
            LoginwindowLaunchesRelaunchApps 2>/dev/null || true
        printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S rm -rf \
            /Library/VirtualMac
    "
    echo "Removed OpenGL PVG compatibility from $GUEST_TARGET"
    exit 0
fi

"$SCRIPT_DIR/build-opengl-guest-compat.sh"
DYLIB="${VZ_OPENGL_GUEST_BUILD:-$VZ_BUILD_ROOT/guest-opengl}/OpenGLPVGCompat.dylib"
need_file "$DYLIB"

if ! guest_ssh 'csrutil status' 2>&1 | grep -q 'disabled'; then
    die "disable SIP in the Virtual Mac recovery environment before installing"
fi

guest_scp "$DYLIB" "$GUEST_TARGET:/tmp/"
guest_ssh "
    set -eu
    uid=\$(id -u)
    printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S mkdir -p \
        /Library/VirtualMac
    printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S cp \
        /tmp/OpenGLPVGCompat.dylib \
        /Library/VirtualMac/OpenGLPVGCompat.dylib
    printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S chown root:wheel \
        /Library/VirtualMac/OpenGLPVGCompat.dylib
    printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S chmod 755 \
        /Library/VirtualMac/OpenGLPVGCompat.dylib
    # Sign on the guest. A host-generated ad hoc signature on an arm64e slice
    # verifies on disk but macOS can still reject its pages at process launch.
    printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S codesign \
        --force --sign - /Library/VirtualMac/OpenGLPVGCompat.dylib
    boot_args=\$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//' || true)
    case \" \$boot_args \" in
        *' -arm64e_preview_abi '*) ;;
        *)
            boot_args=\"\${boot_args:+\$boot_args }-arm64e_preview_abi\"
            printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S nvram \
                \"boot-args=\$boot_args\"
            ;;
    esac
    printf '%s\\n' '$VZ_GUEST_PASSWORD' | sudo -S launchctl \
        asuser \"\$uid\" launchctl setenv DYLD_INSERT_LIBRARIES \
        /Library/VirtualMac/OpenGLPVGCompat.dylib
    defaults write com.apple.loginwindow TALLogoutSavesState -bool false
    defaults write com.apple.loginwindow \
        LoginwindowLaunchesRelaunchApps -bool false
"

echo "Installed OpenGL PVG compatibility in $GUEST_TARGET"
echo "Restart the Virtual Mac once if -arm64e_preview_abi was newly added."
